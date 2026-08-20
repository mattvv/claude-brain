//! `brain-compress shell -- <argv…>` — run a command once, persist its exact raw
//! output as a recoverable artifact, then emit a compact view produced by piping
//! that raw output through an `rtk pipe --filter` (RTK is used as a filter
//! library only; we never let it re-run the command, and we never rely on its
//! tee — see docs/compression-capabilities.md H6).
//!
//! Fidelity contract (Stage 2):
//!   * The exact raw output is persisted BEFORE any compact view is emitted.
//!     Recover with `brain compress show <id> --full`.
//!   * The command's exit status is preserved.
//!   * stderr is passed through verbatim — errors are never compressed.
//!   * If compression does not actually shrink the output, or RTK is missing, or
//!     compression is disabled, the raw output is emitted unchanged.
//!
//! The hook only ever rewrites commands for which `filter_for` returns Some, so
//! the wrapper and the hook agree on exactly what is eligible.

use crate::artifact::{ArtifactMetadata, ArtifactStore};
use crate::config::Config;
use crate::ledger::{Ledger, LedgerEntry, SurfaceDelta, SURFACE_SHELL};
use crate::util::{compression_kill_switch, state_dir, unique_id};
use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

/// The set of RTK pipe filters we trust to compress real command output. Only
/// filters verified to genuinely shrink text (not RTK subcommands that re-run
/// the command with different flags) are listed. Keep this in sync with the
/// hook's rewrite decision — both call `filter_for`.
pub fn filter_for(argv: &[String]) -> Option<&'static str> {
    let first = argv.first().map(String::as_str)?;
    let second = argv.get(1).map(String::as_str);
    match (first, second) {
        ("git", Some("log")) => Some("git-log"),
        ("git", Some("diff")) => Some("git-diff"),
        ("git", Some("show")) => Some("git-diff"),
        ("cargo", Some("test")) => Some("cargo-test"),
        ("pytest", _) => Some("pytest"),
        ("py.test", _) => Some("pytest"),
        ("go", Some("test")) => Some("go-test"),
        ("grep", _) => Some("grep"),
        ("rg", _) => Some("grep"),
        ("find", _) => Some("find"),
        ("vitest", _) => Some("vitest"),
        ("tsc", _) => Some("tsc"),
        _ => None,
    }
}

pub async fn run(args: Vec<String>) -> i32 {
    // args is everything after "shell". Expect a leading "--" then the command.
    let mut iter = args.into_iter();
    let mut command: Vec<String> = Vec::new();
    let mut seen_sep = false;
    for arg in iter.by_ref() {
        if !seen_sep && arg == "--" {
            seen_sep = true;
            continue;
        }
        if !seen_sep && arg.starts_with("--") {
            // No options defined yet; ignore unknown leading flags defensively.
            continue;
        }
        command.push(arg);
    }
    if command.is_empty() {
        eprintln!("brain-compress shell: usage: brain-compress shell -- <command> [args…]");
        return 2;
    }

    match run_inner(command).await {
        Ok(code) => code,
        Err(message) => {
            eprintln!("brain-compress shell: {message}");
            // Fall through with a generic failure code; the raw path already ran
            // when possible.
            1
        }
    }
}

async fn run_inner(command: Vec<String>) -> Result<i32, String> {
    let state = state_dir()?;

    // Execute the command exactly once, capturing stdout/stderr/exit.
    let output = Command::new(&command[0])
        .args(&command[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|error| format!("cannot run {}: {error}", command[0]))?;

    let code = output.status.code().unwrap_or(if output.status.success() { 0 } else { 1 });
    let stdout = output.stdout;
    let stderr = output.stderr;

    // If compression is off, behave transparently: stdout then stderr, same code.
    let kill = compression_kill_switch(&state).is_some();
    let config = if kill { None } else { Config::load(&state).ok() };
    let enabled = config.as_ref().map(|c| c.enabled).unwrap_or(false);

    if !enabled {
        return passthrough(&stdout, &stderr, code).await;
    }
    let config = config.expect("enabled requires config");

    // Persist the exact raw output BEFORE emitting any compact view.
    let raw = combined_raw(&stdout, &stderr);
    let store = ArtifactStore::new(&state, config.artifact_ttl_days, config.artifact_quota_bytes)?;
    let event_id = unique_id("shell");
    let metadata = ArtifactMetadata {
        source_event_id: Some(event_id.clone()),
        model: None,
        surface: Some(SURFACE_SHELL.to_string()),
        claim_saved_bytes: 0,
    };
    let handle = match store.put_bytes(&raw, "shell_raw", false, &metadata) {
        Ok(manifest) => Some(manifest.id),
        Err(error) => {
            // Fidelity invariant: no lossy view without a persisted source.
            eprintln!("brain-compress shell: raw persist failed, passing through: {error}");
            return passthrough(&stdout, &stderr, code).await;
        }
    };
    let handle = handle.expect("handle present after successful put");

    // Duplicate-result elision (design §5a): a byte-identical successful
    // stdout already delivered in this scope becomes a one-line reference.
    // Recovery goes through the NEW artifact, so gc of the older one can never
    // strand it. Only successful, non-empty, NUL-free output is eligible —
    // errors are never compressed, and the check runs before record so a
    // result never matches itself.
    let mut dedup_hit: Option<crate::dedup::PriorHit> = None;
    if config.dedup_enabled
        && output.status.success()
        && !stdout.is_empty()
        && !stdout.contains(&0u8)
    {
        let sha = crate::dedup::sha256_hex(&stdout);
        let scope = crate::dedup::current_scope(&state);
        dedup_hit = crate::dedup::check(&state, &sha, "shell", &scope, config.dedup_window_hours);
        crate::dedup::record(&state, &sha, "shell", &handle, &scope);
    }

    let (view, compressed, delivered_len) = if let Some(hit) = dedup_hit
        .filter(|hit| reference_view(&handle, &hit.artifact_id, &stdout, hit.age_seconds).len() < stdout.len())
    {
        let rendered = reference_view(&handle, &hit.artifact_id, &stdout, hit.age_seconds);
        let len = rendered.len() as u64;
        (rendered, true, len)
    } else {
        let filter = filter_for(&command);
        let compact = match filter {
            Some(name) => rtk_pipe(name, &stdout).await,
            None => None,
        };

        // Only compress if RTK produced a strictly smaller stdout view.
        match compact {
            Some(view) if view.len() < stdout.len() => {
                let omitted = count_lines(&stdout).saturating_sub(count_lines(&view));
                let rendered = render_view(&handle, &stdout, &view, omitted);
                let len = rendered.len() as u64;
                (rendered, true, len)
            }
            _ => (stdout.clone(), false, stdout.len() as u64),
        }
    };

    // Emit: compact (or raw) stdout view, then verbatim stderr; preserve code.
    let mut out = tokio::io::stdout();
    out.write_all(&view).await.map_err(|e| format!("stdout: {e}"))?;
    out.flush().await.map_err(|e| format!("stdout: {e}"))?;
    if !stderr.is_empty() {
        let mut err = tokio::io::stderr();
        err.write_all(&stderr).await.map_err(|e| format!("stderr: {e}"))?;
        err.flush().await.map_err(|e| format!("stderr: {e}"))?;
    }

    // Record the shell surface. observed == delivered when not compressed, so the
    // ledger's honesty invariant holds.
    if let Ok(ledger) = Ledger::new(&state, config.estimated_bytes_per_token) {
        let observed = stdout.len() as u64;
        let mut entry = LedgerEntry::new_consult(&command[0]);
        entry.event_id = event_id;
        entry.event_kind = "shell".to_string();
        entry.success = output.status.success();
        entry.raw_response_bytes = observed;
        entry.answer_bytes = delivered_len;
        entry.artifacts.insert("raw".to_string(), handle);
        entry.surfaces.push(SurfaceDelta {
            surface: SURFACE_SHELL.to_string(),
            observed_bytes: observed,
            delivered_bytes: if compressed { delivered_len } else { observed },
            recovered_bytes: 0,
            compressed,
            recovery: false,
            calls: 1,
            provider_calls: 0,
            provider_input_tokens: 0,
            provider_output_tokens: 0,
            proxy_prefix_tokens_estimate: 0,
        });
        if let Err(error) = ledger.append(&entry) {
            eprintln!("brain-compress shell: ledger append failed (non-fatal): {error}");
        }
    }

    Ok(code)
}

async fn passthrough(stdout: &[u8], stderr: &[u8], code: i32) -> Result<i32, String> {
    let mut out = tokio::io::stdout();
    out.write_all(stdout).await.map_err(|e| format!("stdout: {e}"))?;
    out.flush().await.map_err(|e| format!("stdout: {e}"))?;
    if !stderr.is_empty() {
        let mut err = tokio::io::stderr();
        err.write_all(stderr).await.map_err(|e| format!("stderr: {e}"))?;
        err.flush().await.map_err(|e| format!("stderr: {e}"))?;
    }
    Ok(code)
}

fn combined_raw(stdout: &[u8], stderr: &[u8]) -> Vec<u8> {
    if stderr.is_empty() {
        return stdout.to_vec();
    }
    let mut raw = Vec::with_capacity(stdout.len() + stderr.len() + 32);
    raw.extend_from_slice(stdout);
    raw.extend_from_slice(b"\n--- stderr ---\n");
    raw.extend_from_slice(stderr);
    raw
}

/// One-line view for a duplicate result: cites the earlier artifact the model
/// already saw, recovers through the new one.
fn reference_view(new_handle: &str, prior_handle: &str, raw_stdout: &[u8], age_seconds: u64) -> Vec<u8> {
    format!(
        "[brain-compress id={new_handle} output identical to {prior_handle} seen {} ago ({} B) — recover: brain compress show {new_handle} --full]\n",
        crate::dedup::human_age(age_seconds),
        raw_stdout.len(),
    )
    .into_bytes()
}

fn render_view(handle: &str, raw_stdout: &[u8], compact: &[u8], omitted: usize) -> Vec<u8> {
    let header = format!(
        "[brain-compress id={handle} raw_bytes={} view_bytes={} lossy=yes]\n",
        raw_stdout.len(),
        compact.len(),
    );
    let footer = format!(
        "\n[omitted ~{omitted} lines; recover: brain compress show {handle} --full]\n"
    );
    let mut view = Vec::with_capacity(header.len() + compact.len() + footer.len());
    view.extend_from_slice(header.as_bytes());
    view.extend_from_slice(compact);
    view.extend_from_slice(footer.as_bytes());
    view
}

fn count_lines(bytes: &[u8]) -> usize {
    if bytes.is_empty() {
        return 0;
    }
    let newlines = bytes.iter().filter(|&&b| b == b'\n').count();
    // A trailing newline terminates the last line rather than starting an empty
    // one, so only add a line for content after the final newline.
    if bytes.last() == Some(&b'\n') {
        newlines
    } else {
        newlines + 1
    }
}

/// Locate the pinned RTK binary. Returns None if not installed.
pub fn rtk_binary() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let base = std::path::Path::new(&home).join(".local/share/brain/vendor/rtk");
    let mut newest: Option<PathBuf> = None;
    for entry in std::fs::read_dir(&base).ok()?.flatten() {
        let candidate = entry.path().join("rtk");
        if candidate.exists() {
            newest = Some(candidate);
        }
    }
    newest
}

async fn rtk_pipe(filter: &str, stdout: &[u8]) -> Option<Vec<u8>> {
    let rtk = rtk_binary()?;
    let mut child = Command::new(&rtk)
        .arg("pipe")
        .arg("--filter")
        .arg(filter)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    if let Some(mut stdin) = child.stdin.take() {
        // Ignore write errors (e.g. broken pipe if rtk exits early); we validate
        // the result below.
        let _ = stdin.write_all(stdout).await;
        let _ = stdin.shutdown().await;
    }
    let output = child.wait_with_output().await.ok()?;
    if !output.status.success() {
        return None;
    }
    Some(output.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn filter_map_covers_high_value_commands() {
        assert_eq!(filter_for(&v(&["git", "log", "-20"])), Some("git-log"));
        assert_eq!(filter_for(&v(&["git", "diff"])), Some("git-diff"));
        assert_eq!(filter_for(&v(&["cargo", "test"])), Some("cargo-test"));
        assert_eq!(filter_for(&v(&["pytest", "tests/"])), Some("pytest"));
        assert_eq!(filter_for(&v(&["go", "test", "./..."])), Some("go-test"));
        assert_eq!(filter_for(&v(&["grep", "-rn", "x", "src"])), Some("grep"));
        assert_eq!(filter_for(&v(&["rg", "x"])), Some("grep"));
        assert_eq!(filter_for(&v(&["find", ".", "-name", "x"])), Some("find"));
    }

    #[test]
    fn filter_map_rejects_unmapped_and_side_effecting() {
        assert_eq!(filter_for(&v(&["ls", "-la"])), None);
        assert_eq!(filter_for(&v(&["cargo", "build"])), None);
        assert_eq!(filter_for(&v(&["git", "push"])), None);
        assert_eq!(filter_for(&v(&["rm", "-rf", "x"])), None);
        assert_eq!(filter_for(&v(&["echo", "hi"])), None);
        assert_eq!(filter_for(&[]), None);
    }

    #[test]
    fn line_counting_matches_expectations() {
        assert_eq!(count_lines(b""), 0);
        assert_eq!(count_lines(b"one"), 1);
        assert_eq!(count_lines(b"one\ntwo\n"), 2);
        assert_eq!(count_lines(b"one\ntwo\nthree"), 3);
    }

    #[test]
    fn render_view_has_recoverable_header_and_footer() {
        let raw = b"a\nb\nc\nd\ne\n";
        let compact = b"a\n";
        let view = render_view("bc_TEST", raw, compact, 4);
        let text = String::from_utf8(view).unwrap();
        assert!(text.starts_with("[brain-compress id=bc_TEST raw_bytes=10 view_bytes=2 lossy=yes]\n"));
        assert!(text.contains("recover: brain compress show bc_TEST --full"));
    }

    #[test]
    fn combined_raw_marks_stderr_only_when_present() {
        assert_eq!(combined_raw(b"out", b""), b"out".to_vec());
        let both = combined_raw(b"out", b"err");
        assert!(String::from_utf8(both).unwrap().contains("--- stderr ---"));
    }
}
