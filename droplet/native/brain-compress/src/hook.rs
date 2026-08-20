//! `brain-compress hook pre-bash` — PreToolUse (Bash) rewrite decision.
//!
//! Reads the hook JSON on stdin. If the command is a single, simple, eligible
//! command (one the shell wrapper knows how to compress via `filter_for`), it
//! prints a `updatedInput` payload that reroutes it through
//! `brain-compress shell -- …`; otherwise it prints nothing and exits 0
//! (allow unchanged).
//!
//! This hook only ever MUTATES input — it never denies. The existing
//! consult-poll-guard hook is the only DENY hook, so the two compose without the
//! "two mutating hooks" hazard: at most one hook changes the command.
//!
//! Eligibility is deliberately conservative: the command must contain no shell
//! metacharacters (pipes, redirects, sequencing, substitution, globbing,
//! quoting). Anything else passes through untouched. Commands that start with a
//! compressible tool but are too complex to rewrite are recorded for
//! `brain compress discover`.

use crate::config::Config;
use crate::shell::filter_for;
use crate::util::{compression_kill_switch, state_dir, unix_seconds};
use serde_json::{json, Value};
use std::io::Read;

pub async fn run(args: Vec<String>) -> i32 {
    match args.first().map(String::as_str) {
        Some("pre-bash") => pre_bash(),
        Some("pre-read") => pre_read(),
        Some(other) => {
            eprintln!("brain-compress hook: unknown hook '{other}'");
            2
        }
        None => {
            eprintln!("brain-compress hook: usage: brain-compress hook pre-bash|pre-read");
            2
        }
    }
}

fn pre_bash() -> i32 {
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return 0; // never break dispatch
    }
    let value: Value = match serde_json::from_str(&input) {
        Ok(value) => value,
        Err(_) => return 0,
    };

    if value.get("tool_name").and_then(Value::as_str) != Some("Bash") {
        return 0;
    }
    let tool_input = value.get("tool_input").cloned().unwrap_or(Value::Null);
    if background_flag(&value) || background_flag(&tool_input) {
        return 0;
    }
    let command = match tool_input.get("command").and_then(Value::as_str) {
        Some(command) => command.trim(),
        None => return 0,
    };
    if command.is_empty() || command.starts_with("brain-compress") {
        return 0; // re-entrancy guard
    }

    let state = match state_dir() {
        Ok(state) => state,
        Err(_) => return 0,
    };
    if compression_kill_switch(&state).is_some() {
        return 0;
    }
    if !Config::load(&state).map(|c| c.enabled).unwrap_or(false) {
        return 0;
    }

    let tokens: Vec<String> = command.split_whitespace().map(str::to_string).collect();
    let eligible = is_simple(command) && filter_for(&tokens).is_some();

    if !eligible {
        // Record a missed opportunity when a compressible tool is present but the
        // command was too complex (pipes, redirects, quoting) to rewrite safely.
        if let Some(first) = tokens.first() {
            if is_compressible_tool(first) && !is_simple(command) {
                record_discovery(&state, command);
            }
        }
        return 0;
    }

    // Rewrite: reroute through the shell wrapper. The command is known to contain
    // only safe characters, so the real shell will tokenize it into the same argv
    // the wrapper runs directly.
    let mut new_input = tool_input.clone();
    if let Value::Object(map) = &mut new_input {
        map.insert(
            "command".to_string(),
            Value::String(format!("brain-compress shell -- {command}")),
        );
    } else {
        return 0;
    }

    let payload = json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "brain-compress: compacting verbose output (recoverable)",
            "updatedInput": new_input
        }
    });
    println!("{payload}");
    0
}

/// PreToolUse (Read) guard. `observe` (default): record oversized unrestricted
/// reads, allow unchanged. `enforce`: DENY them with guidance (deny shows the
/// reason to the model — never a silent truncation). `off`: do nothing.
///
/// We deliberately do NOT clamp the Read via updatedInput: clamping would hand
/// the model a truncated file with no signal that content was dropped, which is
/// exactly the silent-loss failure the fidelity contract forbids.
fn pre_read() -> i32 {
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return 0;
    }
    let value: Value = match serde_json::from_str(&input) {
        Ok(value) => value,
        Err(_) => return 0,
    };
    if value.get("tool_name").and_then(Value::as_str) != Some("Read") {
        return 0;
    }
    let tool_input = value.get("tool_input").cloned().unwrap_or(Value::Null);
    // Already range-limited reads are fine.
    if tool_input.get("offset").is_some() || tool_input.get("limit").is_some() {
        return 0;
    }
    let path = match tool_input.get("file_path").and_then(Value::as_str) {
        Some(path) => path,
        None => return 0,
    };
    let state = match state_dir() {
        Ok(state) => state,
        Err(_) => return 0,
    };
    if compression_kill_switch(&state).is_some() {
        return 0;
    }
    let config = match Config::load(&state) {
        Ok(config) if config.enabled => config,
        _ => return 0,
    };
    if config.read_guard == "off" {
        return 0;
    }
    let meta = match std::fs::metadata(path) {
        Ok(meta) => meta,
        Err(_) => return 0, // let the real Read surface the error
    };
    let lines = std::fs::read_to_string(path)
        .map(|t| t.lines().count())
        .unwrap_or(0);
    let oversized = meta.len() > config.large_file_bytes || lines > config.large_file_lines;
    if !oversized {
        return 0;
    }

    record_oversized_read(&state, path, meta.len(), lines);

    if config.read_guard != "enforce" {
        return 0; // observe: recorded, allow unchanged
    }

    // enforce: deny with guidance (shown to the model).
    eprintln!(
        "brain-compress: {path} is {lines} lines ({} bytes) — too large to read whole. Use one of:\n  \
         brain compress read {path} --outline        # signatures + line numbers\n  \
         brain compress read {path} --query '<goal>'  # matching regions with context\n  \
         brain compress read {path} --lines A:B        # an exact range\n  \
         or re-run Read with an explicit offset/limit.",
        meta.len()
    );
    2
}

fn record_oversized_read(state: &std::path::Path, path: &str, bytes: u64, lines: usize) {
    let dir = state.join("compress");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let line = format!("{}\tREAD\t{bytes}\t{lines}\t{path}\n", unix_seconds());
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("discover.log"))
    {
        let _ = file.write_all(line.as_bytes());
    }
}

fn background_flag(value: &Value) -> bool {
    value
        .get("run_in_background")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// A command is "simple" if it contains no shell metacharacters at all: no
/// pipes, redirects, sequencing, subshells, substitution, globbing, or quoting.
/// Only then is whitespace tokenization equivalent to the shell's own parsing.
fn is_simple(command: &str) -> bool {
    if command.contains(['\n', '\r', '\t']) {
        return false;
    }
    command.chars().all(|c| {
        c.is_ascii_alphanumeric()
            || matches!(c, ' ' | '.' | '_' | '/' | '-' | '=' | '+' | '@' | ':' | ',' | '%')
    })
}

fn is_compressible_tool(first: &str) -> bool {
    matches!(first, "git" | "cargo" | "pytest" | "py.test" | "go" | "grep" | "rg" | "find" | "vitest" | "tsc")
}

fn record_discovery(state: &std::path::Path, command: &str) {
    let dir = state.join("compress");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let line = format!("{}\t{}\n", unix_seconds(), command);
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("discover.log"))
    {
        let _ = file.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::is_simple;

    #[test]
    fn simple_commands_are_eligible() {
        assert!(is_simple("git log -20"));
        assert!(is_simple("cargo test"));
        assert!(is_simple("grep -rn foo src/dir"));
        assert!(is_simple("go test ./..."));
    }

    #[test]
    fn shell_metacharacters_disqualify() {
        assert!(!is_simple("git log | head"));
        assert!(!is_simple("git log > out.txt"));
        assert!(!is_simple("git log && echo done"));
        assert!(!is_simple("echo $(whoami)"));
        assert!(!is_simple("grep 'foo bar' src"));
        assert!(!is_simple("ls *.rs"));
        assert!(!is_simple("cat a; cat b"));
        assert!(!is_simple("git log\nrm -rf /"));
    }
}
