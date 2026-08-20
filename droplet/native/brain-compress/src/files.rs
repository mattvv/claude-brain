//! `brain compress read|grep|tree` — token-lean file inspection for the main
//! brain session. Each reads its source once, persists the exact bytes as a
//! recoverable artifact, then emits a compact view. Agents are pointed at these
//! for large files / discovery; the built-in Read stays best for small files and
//! exact edit preparation.
//!
//! Fidelity: the exact source is always persisted before any lossy view, every
//! lossy view carries a recovery handle, and `--outline` is explicitly marked
//! NOT AN EDIT SOURCE (it is a lexical signature scan, not a parse).

use crate::artifact::{ArtifactMetadata, ArtifactStore};
use crate::config::Config;
use crate::ledger::{Ledger, LedgerEntry, SurfaceDelta, SURFACE_FILES};
use crate::util::{compression_kill_switch, state_dir, unique_id};
use std::path::Path;
use std::process::Stdio;
use tokio::process::Command;

pub async fn run(args: Vec<String>) -> i32 {
    let sub = args.first().cloned().unwrap_or_default();
    let rest: Vec<String> = args.into_iter().skip(1).collect();
    let result = match sub.as_str() {
        "read" => read(rest).await,
        "grep" => grep(rest).await,
        "tree" => tree(rest).await,
        other => Err(format!("unknown file tool '{other}' (use: read|grep|tree)")),
    };
    match result {
        Ok(code) => code,
        Err(message) => {
            eprintln!("brain compress: {message}");
            2
        }
    }
}

struct ReadArgs {
    path: String,
    lines: Option<(usize, usize)>,
    query: Option<String>,
    outline: bool,
    context: usize,
}

fn parse_read(rest: Vec<String>) -> Result<ReadArgs, String> {
    let mut path = None;
    let mut lines = None;
    let mut query = None;
    let mut outline = false;
    let mut context = 2usize;
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--lines" => {
                i += 1;
                let spec = rest.get(i).ok_or("--lines requires A:B")?;
                let (a, b) = spec.split_once(':').ok_or("--lines expects A:B")?;
                let a: usize = a.parse().map_err(|_| "invalid --lines start")?;
                let b: usize = b.parse().map_err(|_| "invalid --lines end")?;
                if a == 0 || b < a {
                    return Err("invalid --lines range".to_string());
                }
                lines = Some((a, b));
            }
            "--query" => {
                i += 1;
                query = Some(rest.get(i).ok_or("--query requires text")?.clone());
            }
            "--context" => {
                i += 1;
                context = rest.get(i).ok_or("--context requires N")?.parse().map_err(|_| "invalid --context")?;
            }
            "--outline" => outline = true,
            other if other.starts_with("--") => return Err(format!("unknown option {other}")),
            other => {
                if path.is_some() {
                    return Err("multiple paths given".to_string());
                }
                path = Some(other.to_string());
            }
        }
        i += 1;
    }
    Ok(ReadArgs {
        path: path.ok_or("usage: brain compress read PATH [--lines A:B] [--query T] [--outline]")?,
        lines,
        query,
        outline,
        context,
    })
}

async fn read(rest: Vec<String>) -> Result<i32, String> {
    let args = parse_read(rest)?;
    let bytes = tokio::fs::read(&args.path)
        .await
        .map_err(|e| format!("cannot read {}: {e}", args.path))?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    let all: Vec<&str> = text.lines().collect();
    let total = all.len();

    let state = state_dir()?;
    let enabled = compression_kill_switch(&state).is_none()
        && Config::load(&state).map(|c| c.enabled).unwrap_or(false);
    let config = Config::load(&state).ok();

    // Persist the exact file bytes before any lossy view.
    let handle = if enabled {
        if let Some(cfg) = &config {
            persist(&state, cfg, &bytes, "file_read", &args.path)
        } else {
            None
        }
    } else {
        None
    };

    let large_lines = config.as_ref().map(|c| c.large_file_lines).unwrap_or(800);

    let (body, lossy) = if let Some((a, b)) = args.lines {
        (range_view(&all, a, b), a > 1 || b < total)
    } else if let Some(q) = &args.query {
        query_view(&all, q, args.context)
    } else if args.outline {
        (outline_view(&all), true)
    } else if total > large_lines && handle.is_some() {
        // Default view of a large file: head + explicit omission.
        let head = large_lines.min(total);
        let mut v = String::new();
        for (idx, line) in all.iter().take(head).enumerate() {
            v.push_str(&format!("{}\t{}\n", idx + 1, line));
        }
        (v, true)
    } else {
        // Small file: numbered full content, no loss.
        let mut v = String::new();
        for (idx, line) in all.iter().enumerate() {
            v.push_str(&format!("{}\t{}\n", idx + 1, line));
        }
        (v, false)
    };

    // Duplicate-result elision (design §5a), lossy discovery views only: a
    // lossless whole-file view can serve as edit preparation and is never
    // elided. The reference recovers through the NEW artifact.
    let view_kind = if let Some((a, b)) = args.lines {
        format!("read:lines:{a}:{b}:{}", args.path)
    } else if let Some(q) = &args.query {
        format!("read:query:{q}:{}", args.path)
    } else if args.outline {
        format!("read:outline:{}", args.path)
    } else {
        format!("read:whole:{}", args.path)
    };
    let mut dedup_hit = None;
    if let (Some(cfg), Some(h)) = (config.as_ref(), handle.as_ref()) {
        if cfg.dedup_enabled && lossy && !bytes.contains(&0u8) {
            let sha = crate::dedup::sha256_hex(&bytes);
            let scope = crate::dedup::current_scope(&state);
            dedup_hit = crate::dedup::check(&state, &sha, &view_kind, &scope, cfg.dedup_window_hours);
            crate::dedup::record(&state, &sha, &view_kind, h, &scope);
        }
    }

    let view = match (&dedup_hit, handle.as_deref()) {
        (Some(hit), Some(h)) => {
            let reference = format!(
                "[brain-compress {} view identical to {} seen {} ago ({} B raw) — recover: brain compress show {h} --full]\n",
                args.path,
                hit.artifact_id,
                crate::dedup::human_age(hit.age_seconds),
                bytes.len(),
            );
            if reference.len() < render(&args.path, total, &body, lossy, Some(h)).len() {
                reference
            } else {
                render(&args.path, total, &body, lossy, Some(h))
            }
        }
        _ => render(&args.path, total, &body, lossy, handle.as_deref()),
    };
    print!("{view}");

    if let (Some(cfg), Some(h)) = (config.as_ref(), handle.as_ref()) {
        record_files(&state, cfg, &args.path, bytes.len() as u64, view.len() as u64, lossy, h);
    }
    Ok(0)
}

fn range_view(all: &[&str], a: usize, b: usize) -> String {
    let mut v = String::new();
    for (idx, line) in all.iter().enumerate() {
        let n = idx + 1;
        if n >= a && n <= b {
            v.push_str(&format!("{n}\t{line}\n"));
        }
    }
    v
}

pub(crate) fn query_view(all: &[&str], query: &str, context: usize) -> (String, bool) {
    let needle = query.to_lowercase();
    let mut keep = vec![false; all.len()];
    let mut any = false;
    for (i, line) in all.iter().enumerate() {
        if line.to_lowercase().contains(&needle) {
            any = true;
            let lo = i.saturating_sub(context);
            let hi = (i + context).min(all.len().saturating_sub(1));
            for k in lo..=hi {
                keep[k] = true;
            }
        }
    }
    if !any {
        return (format!("(no lines match {query:?})\n"), true);
    }
    let mut v = String::new();
    let mut gap = false;
    for (i, line) in all.iter().enumerate() {
        if keep[i] {
            if gap {
                v.push_str("\t…\n");
                gap = false;
            }
            v.push_str(&format!("{}\t{}\n", i + 1, line));
        } else {
            gap = true;
        }
    }
    (v, true)
}

/// Lexical (regex-free) signature scan. NOT a parse — used only for discovery.
pub(crate) fn outline_view(all: &[&str]) -> String {
    const KEYWORDS: &[&str] = &[
        "fn ", "pub fn", "struct ", "enum ", "trait ", "impl ", "mod ", "const ", "static ",
        "type ", "class ", "def ", "function ", "interface ", "func ", "public ", "private ",
        "async ", "export ",
    ];
    let mut v = String::from("OUTLINE (lexical signature scan — NOT AN EDIT SOURCE)\n");
    for (i, line) in all.iter().enumerate() {
        let trimmed = line.trim_start();
        if KEYWORDS.iter().any(|k| trimmed.starts_with(k) || trimmed.contains(&format!(" {k}"))) {
            v.push_str(&format!("{}\t{}\n", i + 1, line.trim_end()));
        }
    }
    v
}

fn render(path: &str, total: usize, body: &str, lossy: bool, handle: Option<&str>) -> String {
    if !lossy {
        return body.to_string();
    }
    let mut out = String::new();
    match handle {
        Some(h) => out.push_str(&format!(
            "[brain-compress {path} total_lines={total} view=partial recover: brain compress show {h} --full]\n"
        )),
        None => out.push_str(&format!("[brain-compress {path} total_lines={total} view=partial]\n")),
    }
    out.push_str(body);
    out
}

async fn grep(rest: Vec<String>) -> Result<i32, String> {
    if rest.is_empty() {
        return Err("usage: brain compress grep PATTERN [PATH …]".to_string());
    }
    // Delegate to the shell wrapper's model: run grep -rn, compact via rtk.
    let mut argv = vec!["grep".to_string(), "-rn".to_string()];
    argv.extend(rest);
    crate::shell::run(std::iter::once("--".to_string()).chain(argv).collect()).await;
    Ok(0)
}

async fn tree(rest: Vec<String>) -> Result<i32, String> {
    let path = rest.into_iter().find(|a| !a.starts_with("--")).unwrap_or_else(|| ".".to_string());
    // Prefer rtk's tree (reads the directory, no side effects). rtk tree needs
    // the system `tree`; if it or rtk is missing, fall back to a plain find.
    if let Some(rtk) = crate::shell::rtk_binary() {
        let output = Command::new(rtk)
            .arg("tree")
            .arg(&path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .await
            .map_err(|e| format!("rtk tree failed: {e}"))?;
        if output.status.success() && !output.stdout.is_empty() {
            use tokio::io::AsyncWriteExt;
            let mut out = tokio::io::stdout();
            let _ = out.write_all(&output.stdout).await;
            let _ = out.flush().await;
            return Ok(0);
        }
        // rtk couldn't produce a tree (e.g. system `tree` absent) → fall through.
    }
    let status = Command::new("find")
        .arg(&path)
        .arg("-maxdepth")
        .arg("2")
        .stdin(Stdio::null())
        .status()
        .await
        .map_err(|e| format!("find failed: {e}"))?;
    Ok(status.code().unwrap_or(0))
}

fn persist(state: &Path, config: &Config, bytes: &[u8], kind: &str, path: &str) -> Option<String> {
    let store = ArtifactStore::new(state, config.artifact_ttl_days, config.artifact_quota_bytes).ok()?;
    let metadata = ArtifactMetadata {
        source_event_id: Some(unique_id("file")),
        model: None,
        surface: Some(SURFACE_FILES.to_string()),
        claim_saved_bytes: 0,
    };
    match store.put_bytes(bytes, kind, false, &metadata) {
        Ok(manifest) => Some(manifest.id),
        Err(error) => {
            eprintln!("brain compress: could not persist {path}: {error}");
            None
        }
    }
}

fn record_files(state: &Path, config: &Config, path: &str, observed: u64, delivered: u64, lossy: bool, handle: &str) {
    let ledger = match Ledger::new(state, config.estimated_bytes_per_token) {
        Ok(ledger) => ledger,
        Err(_) => return,
    };
    let mut entry = LedgerEntry::new_consult(path);
    entry.event_kind = "file".to_string();
    entry.success = true;
    entry.raw_response_bytes = observed;
    entry.answer_bytes = delivered;
    entry.artifacts.insert("raw".to_string(), handle.to_string());
    entry.surfaces.push(SurfaceDelta {
        surface: SURFACE_FILES.to_string(),
        observed_bytes: observed,
        delivered_bytes: if lossy && delivered < observed { delivered } else { observed },
        recovered_bytes: 0,
        compressed: lossy && delivered < observed,
        recovery: false,
        calls: 1,
        provider_calls: 0,
        provider_input_tokens: 0,
        provider_output_tokens: 0,
        proxy_prefix_tokens_estimate: 0,
    });
    let _ = ledger.append(&entry);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_view_selects_inclusive() {
        let all = vec!["a", "b", "c", "d"];
        let v = range_view(&all, 2, 3);
        assert!(v.contains("2\tb"));
        assert!(v.contains("3\tc"));
        assert!(!v.contains("a"));
        assert!(!v.contains("4\td"));
    }

    #[test]
    fn query_view_marks_gaps_and_matches() {
        let all = vec!["nope", "nope", "hit here", "nope", "nope", "nope", "another hit"];
        let (v, lossy) = query_view(&all, "hit", 0);
        assert!(lossy);
        assert!(v.contains("3\thit here"));
        assert!(v.contains("7\tanother hit"));
        assert!(v.contains('…'));
    }

    #[test]
    fn outline_marks_not_an_edit_source() {
        let all = vec!["use x;", "pub fn foo() {", "    body", "}", "struct Bar;"];
        let v = outline_view(&all);
        assert!(v.contains("NOT AN EDIT SOURCE"));
        assert!(v.contains("pub fn foo"));
        assert!(v.contains("struct Bar"));
        assert!(!v.contains("body"));
    }
}
