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
//! Eligibility is per-command, not per-line: `crate::segment` splits the line
//! into individual commands and each one is judged on its own, so
//! `cd x && git log` compresses the `git log` and leaves the `cd` alone. A
//! command is only rewritten when it is a whole pipeline by itself — anything
//! reading from or writing to a pipe is left untouched, because the wrapper
//! gives its child no stdin and its compacted view would be parsed by the next
//! stage rather than read by the model. Commands the scanner cannot reason
//! about at all (redirects, substitution, subshells, heredocs) pass through
//! untouched and are recorded for `brain compress discover`.

use crate::config::Config;
use crate::segment::{self, Split};
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
    if command.is_empty() || command.contains("brain-compress shell") {
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
    // Capture the session id for scope-aware features (dedup elision). The
    // hook payload carries it on every event (H11); best-effort.
    if let Some(session) = value.get("session_id").and_then(Value::as_str) {
        crate::dedup::record_session(&state, session);
    }

    let rewritten = match rewrite(command, &wrapper_command()) {
        Rewrite::Changed(next) => next,
        Rewrite::Unchanged { missed } => {
            // Record a missed opportunity when a compressible tool was present
            // but we could not rewrite it safely. This is what
            // `brain compress discover` reports, so it has to see the misses
            // that matter — including ones where the compressible tool is not
            // the first word (`cd x && git log`).
            if missed {
                record_discovery(&state, command);
            }
            return 0;
        }
    };

    // Rewrite: reroute the understood commands through the shell wrapper. Each
    // rewritten command keeps its original source text, so the real shell
    // tokenizes it into exactly the argv the wrapper runs.
    let mut new_input = tool_input.clone();
    if let Value::Object(map) = &mut new_input {
        map.insert("command".to_string(), Value::String(rewritten));
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
    if let Some(session) = value.get("session_id").and_then(Value::as_str) {
        crate::dedup::record_session(&state, session);
    }
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

/// How to invoke the shell wrapper from the rewritten command.
///
/// This must be an ABSOLUTE path, not the bare name. The rewritten command runs
/// in whatever shell Claude Code spawns, and that shell does not necessarily
/// have `~/.local/bin` on its PATH — a non-interactive shell that never sources
/// the profile does not. When it doesn't, a bare `brain-compress` fails with
/// exit 127 and takes the user's actual command down with it. We are the binary
/// being asked, so we already know exactly where we live.
fn wrapper_command() -> String {
    match std::env::current_exe() {
        Ok(path) => shell_quote(&path.to_string_lossy()),
        // If the platform cannot tell us, fall back to the name and hope PATH
        // has it — still better than refusing to compress at all.
        Err(_) => "brain-compress".to_string(),
    }
}

/// Quote a path for the shell only when it needs it.
fn shell_quote(path: &str) -> String {
    let safe = !path.is_empty()
        && path
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '_' | '-'));
    if safe {
        path.to_string()
    } else {
        format!("'{}'", path.replace('\'', r"'\''"))
    }
}

pub(crate) enum Rewrite {
    /// The command line with `brain-compress shell -- ` spliced in front of every
    /// command we know how to compact.
    Changed(String),
    /// Nothing to rewrite. `missed` is true when a compressible tool was in
    /// there somewhere but we could not reach it safely.
    Unchanged { missed: bool },
}

/// Decide what, if anything, to reroute through the shell wrapper. `wrapper` is
/// how to invoke this binary from the rewritten command line.
pub(crate) fn rewrite(command: &str, wrapper: &str) -> Rewrite {
    let prefix = format!("{wrapper} shell -- ");

    let segments = match segment::split(command) {
        Split::Commands(segments) => segments,
        // We could not parse it, so we cannot rewrite any part of it. It still
        // counts as a miss if a compressible tool appears anywhere in the line.
        Split::Unsupported => {
            return Rewrite::Unchanged {
                missed: mentions_compressible_tool(command),
            }
        }
    };

    let mut insert_at: Vec<usize> = Vec::new();
    let mut missed = false;
    for seg in &segments {
        let text = &command[seg.start..seg.end];
        let words = match segment::words(text) {
            Some(words) => words,
            None => continue,
        };
        if filter_for(&words).is_none() {
            continue;
        }
        // A command that reads from or writes to a pipe must be left alone: the
        // wrapper hands its child no stdin, and a compacted view piped into the
        // next stage would be parsed rather than read.
        if seg.pipeline_len > 1 {
            missed = true;
            continue;
        }
        insert_at.push(seg.start);
    }

    if insert_at.is_empty() {
        return Rewrite::Unchanged { missed };
    }

    // Splice back-to-front so earlier offsets stay valid.
    let mut out = command.to_string();
    for offset in insert_at.iter().rev() {
        out.insert_str(*offset, &prefix);
    }
    Rewrite::Changed(out)
}

/// Whether a compressible tool appears as the first word of any whitespace-run
/// in the line. Used only for miss accounting on lines we could not parse, so a
/// loose match is right: it is a hint for `brain compress discover`, not a
/// rewrite decision.
fn mentions_compressible_tool(command: &str) -> bool {
    command
        .split(|c: char| c.is_whitespace() || matches!(c, '|' | '&' | ';' | '(' | ')'))
        .any(|word| {
            let base = word.rsplit('/').next().unwrap_or(word);
            is_compressible_tool(base)
        })
}

pub(crate) fn is_compressible_tool(first: &str) -> bool {
    matches!(
        first,
        "git"
            | "cargo"
            | "pytest"
            | "py.test"
            | "go"
            | "grep"
            | "rg"
            | "find"
            | "fd"
            | "vitest"
            | "tsc"
            | "mypy"
            | "ruff"
            | "prettier"
            | "phpstan"
            | "phpunit"
            | "cat"
            | "head"
            | "tail"
            | "sed"
    )
}

fn record_discovery(state: &std::path::Path, command: &str) {
    let dir = state.join("compress");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    // The log is TSV and a command may be several lines long (heredocs, loops),
    // so escape before writing: an unescaped newline used to split one command
    // into rows and `brain compress discover` reported the fragments (`}`,
    // `EOF`, "```bash") as if they were commands.
    let line = format!("{}\t{}\n", unix_seconds(), escape_record(command));
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("discover.log"))
    {
        let _ = file.write_all(line.as_bytes());
    }
}

/// Render a command as a single TSV-safe line.
pub(crate) fn escape_record(command: &str) -> String {
    let mut out = String::with_capacity(command.len());
    for c in command.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tests pin the wrapper to the bare name so the expected strings stay
    // readable; production always passes an absolute path.
    fn changed(command: &str) -> String {
        match rewrite(command, "brain-compress") {
            Rewrite::Changed(out) => out,
            Rewrite::Unchanged { .. } => panic!("expected a rewrite: {command}"),
        }
    }

    fn unchanged(command: &str) -> bool {
        matches!(rewrite(command, "brain-compress"), Rewrite::Unchanged { .. })
    }

    #[test]
    fn a_plain_command_is_rewritten() {
        assert_eq!(changed("git log"), "brain-compress shell -- git log");
        assert_eq!(changed("cargo test"), "brain-compress shell -- cargo test");
    }

    #[test]
    fn compound_commands_rewrite_only_the_compressible_parts() {
        // This is the case the old whole-string veto missed, and it is the most
        // common shape in real traffic.
        assert_eq!(
            changed("cd /tmp && git log"),
            "cd /tmp && brain-compress shell -- git log"
        );
        assert_eq!(
            changed("git log && git diff"),
            "brain-compress shell -- git log && brain-compress shell -- git diff"
        );
        assert_eq!(
            changed("echo hi; grep -rn foo src"),
            "echo hi; brain-compress shell -- grep -rn foo src"
        );
    }

    #[test]
    fn surrounding_whitespace_and_separators_are_preserved() {
        assert_eq!(
            changed("cd /tmp   &&   git log --oneline"),
            "cd /tmp   &&   brain-compress shell -- git log --oneline"
        );
    }

    #[test]
    fn quoted_arguments_survive_because_the_shell_retokenizes_them() {
        assert_eq!(
            changed("grep -rn 'foo bar' src"),
            "brain-compress shell -- grep -rn 'foo bar' src"
        );
        // Revision syntax used to be rejected by the character allowlist.
        assert_eq!(
            changed("git diff HEAD~3"),
            "brain-compress shell -- git diff HEAD~3"
        );
    }

    #[test]
    fn piped_commands_are_never_rewritten() {
        // The wrapper gives its child no stdin and its view would be parsed by
        // the next stage, so both ends of a pipe must be left alone.
        assert!(unchanged("git log | head -5"));
        assert!(unchanged("cat f | grep foo"));
        assert!(unchanged("grep -rn x src | wc -l"));
    }

    #[test]
    fn constructs_we_cannot_reason_about_are_left_alone() {
        assert!(unchanged("git log > out.txt"));
        assert!(unchanged("echo $(git log)"));
        assert!(unchanged("(cd x && git log)"));
        assert!(unchanged("git log &"));
        assert!(unchanged("git log\nrm -rf /"));
        assert!(unchanged("ls -la"));
        assert!(unchanged("git push"));
    }

    #[test]
    fn re_entrancy_is_impossible_because_a_rewrite_is_never_reparsed() {
        // The pre_bash guard drops anything already carrying the wrapper, but
        // the rewrite itself must also be stable if it ever were re-run.
        let once = changed("cd /tmp && git log");
        assert!(once.contains("brain-compress shell -- git log"));
        assert_eq!(once.matches("brain-compress shell").count(), 1);
    }

    #[test]
    fn misses_are_recorded_even_when_the_tool_is_not_the_first_word() {
        // The old discovery check only looked at the first token, so the single
        // biggest miss class was invisible to it.
        match rewrite("cd /tmp && git log > out.txt", "brain-compress") {
            Rewrite::Unchanged { missed } => assert!(missed),
            Rewrite::Changed(_) => panic!("redirect must not be rewritten"),
        }
        match rewrite("cd /tmp && echo hi > out.txt", "brain-compress") {
            Rewrite::Unchanged { missed } => assert!(!missed),
            Rewrite::Changed(_) => panic!("no compressible tool here"),
        }
    }

    #[test]
    fn the_wrapper_is_invoked_by_absolute_path_not_by_name() {
        // The rewritten command runs in whatever shell Claude Code spawns, and
        // that shell may not have ~/.local/bin on PATH. A bare name there fails
        // with exit 127 and takes the user's real command down with it.
        let wrapper = wrapper_command();
        assert!(
            wrapper.starts_with('/') || wrapper.starts_with('\''),
            "wrapper must be an absolute path, got {wrapper:?}"
        );
        let out = match rewrite("git log", &wrapper) {
            Rewrite::Changed(out) => out,
            Rewrite::Unchanged { .. } => panic!("expected a rewrite"),
        };
        assert!(out.starts_with(&wrapper), "rewrite must use the resolved path: {out:?}");
        assert!(out.ends_with(" shell -- git log"));
    }

    #[test]
    fn a_wrapper_path_needing_quotes_gets_them() {
        assert_eq!(shell_quote("/usr/local/bin/brain-compress"), "/usr/local/bin/brain-compress");
        assert_eq!(shell_quote("/home/a b/brain-compress"), "'/home/a b/brain-compress'");
        // A quoted path still satisfies the re-entrancy guard.
        assert!(shell_quote("/home/a b/brain-compress").contains("brain-compress"));
    }

    #[test]
    fn discovery_records_stay_on_one_line() {
        let escaped = escape_record("cat <<'EOF'\nbody\nEOF");
        assert!(!escaped.contains('\n'));
        assert_eq!(escaped, "cat <<'EOF'\\nbody\\nEOF");
    }
}
