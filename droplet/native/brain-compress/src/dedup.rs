//! Content-addressed duplicate-result elision (design §5a).
//!
//! When a `shell`/`read` result is byte-identical to one already delivered in
//! the same scope recently, the emitted view becomes a one-line reference to
//! the earlier artifact instead of repeating the bytes.
//!
//! Fidelity: the raw output of the CURRENT invocation is still persisted first
//! (the fidelity invariant is untouched), and the reference's recovery handle
//! points at the NEW artifact — so recovery can never be stranded by garbage
//! collection of the older one; the older id is cited only to anchor what the
//! model already saw. Eligibility is decided by the callers (successful text
//! output only; never errors, never edit sources).
//!
//! Scope: prefer the Claude Code session id (captured by the PreToolUse hooks
//! into `compress/current-session`; the hook payload carries `session_id` —
//! see docs/compression-capabilities.md H11). When no session id is available,
//! fall back to same-cwd within the time window. Global elision is deliberately
//! not implemented: a reference to content the model never saw forces
//! recoveries that erase the saving.

use crate::util::{atomic_write, unix_seconds};
use sha2::{Digest, Sha256};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// Newest-session marker is considered stale after this long.
const SESSION_STALE_SECONDS: u64 = 24 * 3600;
/// Rotate the index once it exceeds this many bytes, keeping the newest lines.
const INDEX_ROTATE_BYTES: u64 = 512 * 1024;
const INDEX_KEEP_LINES: usize = 2000;

#[derive(Clone, Debug)]
pub struct Scope {
    pub session: Option<String>,
    pub cwd: String,
}

#[derive(Clone, Debug)]
pub struct PriorHit {
    pub artifact_id: String,
    pub age_seconds: u64,
}

fn index_path(state: &Path) -> PathBuf {
    state.join("compress/dedup-index.jsonl")
}

fn session_path(state: &Path) -> PathBuf {
    state.join("compress/current-session")
}

/// Record the active Claude Code session id (called from the PreToolUse hooks,
/// which receive it in the hook payload). Best-effort; never fails the hook.
pub fn record_session(state: &Path, session_id: &str) {
    if session_id.is_empty() || session_id.len() > 128 {
        return;
    }
    let _ = std::fs::create_dir_all(state.join("compress"));
    let _ = atomic_write(&session_path(state), session_id.as_bytes());
}

/// The current elision scope: the freshest known session id (if recent), plus
/// the working directory as the fallback discriminator.
pub fn current_scope(state: &Path) -> Scope {
    let cwd = std::env::current_dir()
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    let path = session_path(state);
    let session = match (std::fs::read_to_string(&path), std::fs::metadata(&path)) {
        (Ok(text), Ok(meta)) => {
            let fresh = meta
                .modified()
                .ok()
                .and_then(|m| m.elapsed().ok())
                .map(|e| e.as_secs() < SESSION_STALE_SECONDS)
                .unwrap_or(false);
            let trimmed = text.trim().to_string();
            if fresh && !trimmed.is_empty() {
                Some(trimmed)
            } else {
                None
            }
        }
        _ => None,
    };
    Scope { session, cwd }
}

/// Look for a prior identical delivery in scope. `kind` distinguishes view
/// shapes (e.g. `shell` vs `read:outline`) so a reference is only ever made to
/// a view the model actually saw in the same form.
pub fn check(
    state: &Path,
    sha256: &str,
    kind: &str,
    scope: &Scope,
    window_hours: u64,
) -> Option<PriorHit> {
    let text = std::fs::read_to_string(index_path(state)).ok()?;
    let now = unix_seconds();
    let window = window_hours.saturating_mul(3600);
    let mut best: Option<PriorHit> = None;
    for line in text.lines() {
        let Ok(row) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if row.get("sha256").and_then(Value::as_str) != Some(sha256) {
            continue;
        }
        if row.get("kind").and_then(Value::as_str) != Some(kind) {
            continue;
        }
        let ts = row.get("ts").and_then(Value::as_u64).unwrap_or(0);
        if now.saturating_sub(ts) > window {
            continue;
        }
        let row_session = row.get("session").and_then(Value::as_str);
        let in_scope = match (&scope.session, row_session) {
            (Some(current), Some(prior)) => current == prior,
            // Without session identity on both sides, fall back to same-cwd.
            _ => row.get("cwd").and_then(Value::as_str) == Some(scope.cwd.as_str()),
        };
        if !in_scope {
            continue;
        }
        let Some(artifact) = row.get("artifact").and_then(Value::as_str) else {
            continue;
        };
        // Newest match wins (later lines are newer; keep overwriting).
        best = Some(PriorHit {
            artifact_id: artifact.to_string(),
            age_seconds: now.saturating_sub(ts),
        });
    }
    best
}

/// Record a delivery so future identical results can reference it.
pub fn record(state: &Path, sha256: &str, kind: &str, artifact_id: &str, scope: &Scope) {
    let dir = state.join("compress");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let row = json!({
        "sha256": sha256,
        "kind": kind,
        "artifact": artifact_id,
        "session": scope.session,
        "cwd": scope.cwd,
        "ts": unix_seconds(),
    });
    let mut line = row.to_string();
    line.push('\n');
    use std::io::Write;
    let path = index_path(state);
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = file.write_all(line.as_bytes());
    }
    rotate_if_needed(&path);
}

fn rotate_if_needed(path: &Path) {
    let Ok(meta) = std::fs::metadata(path) else { return };
    if meta.len() <= INDEX_ROTATE_BYTES {
        return;
    }
    let Ok(text) = std::fs::read_to_string(path) else { return };
    let lines: Vec<&str> = text.lines().collect();
    let keep = lines.len().saturating_sub(INDEX_KEEP_LINES);
    let mut out = String::new();
    for line in &lines[keep..] {
        out.push_str(line);
        out.push('\n');
    }
    let _ = atomic_write(path, out.as_bytes());
}

/// Hex sha256 of a byte slice (identity for elision decisions).
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

/// Human-readable age for the reference marker.
pub fn human_age(seconds: u64) -> String {
    if seconds < 60 {
        format!("{seconds}s")
    } else if seconds < 3600 {
        format!("{}m", seconds / 60)
    } else {
        format!("{}h{:02}m", seconds / 3600, (seconds % 3600) / 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_state(name: &str) -> PathBuf {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir().join(format!(
            "brain-compress-dedup-{name}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn record_then_check_hits_in_scope() {
        let state = temp_state("hit");
        let scope = Scope { session: Some("s1".into()), cwd: "/w".into() };
        record(&state, "abc", "shell", "bc_1", &scope);
        let hit = check(&state, "abc", "shell", &scope, 8).unwrap();
        assert_eq!(hit.artifact_id, "bc_1");
        // Different kind never matches (an outline is not a whole-file view).
        assert!(check(&state, "abc", "read:outline", &scope, 8).is_none());
        // Different sha never matches.
        assert!(check(&state, "zzz", "shell", &scope, 8).is_none());
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn scope_mismatch_misses() {
        let state = temp_state("scope");
        let scope_a = Scope { session: Some("s1".into()), cwd: "/w".into() };
        record(&state, "abc", "shell", "bc_1", &scope_a);
        // Different session: miss.
        let scope_b = Scope { session: Some("s2".into()), cwd: "/w".into() };
        assert!(check(&state, "abc", "shell", &scope_b, 8).is_none());
        // No session on the query side: cwd fallback still matches.
        let scope_c = Scope { session: None, cwd: "/w".into() };
        assert!(check(&state, "abc", "shell", &scope_c, 8).is_some());
        // Different cwd without session: miss.
        let scope_d = Scope { session: None, cwd: "/elsewhere".into() };
        assert!(check(&state, "abc", "shell", &scope_d, 8).is_none());
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn newest_match_wins_and_session_capture_roundtrips() {
        let state = temp_state("newest");
        let scope = Scope { session: Some("s1".into()), cwd: "/w".into() };
        record(&state, "abc", "shell", "bc_old", &scope);
        record(&state, "abc", "shell", "bc_new", &scope);
        assert_eq!(check(&state, "abc", "shell", &scope, 8).unwrap().artifact_id, "bc_new");

        record_session(&state, "sess-123");
        assert_eq!(current_scope(&state).session.as_deref(), Some("sess-123"));
        std::fs::remove_dir_all(state).unwrap();
    }
}
