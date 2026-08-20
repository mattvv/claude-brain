//! Symbol-aware code search (design §1, upgrades deferred Stage 4B).
//!
//! Backed by the stateless `brain-symbols` helper (tree-sitter, built in CI
//! per H7, installed under ~/.local/share/brain/vendor/brain-symbols/<ver>/).
//! brain-compress owns persistence, recovery, capping, and accounting; the
//! helper only turns file content into JSON symbol facts. Helper absent or
//! failing ⇒ honest lexical fallback, explicitly marked — never silently
//! classified.
//!
//! Views are discovery aids (NOT AN EDIT SOURCE); the full untruncated result
//! is persisted as an artifact before the capped view is printed.

use crate::artifact::{ArtifactMetadata, ArtifactStore};
use crate::config::Config;
use crate::explore::walk;
use crate::ledger::{Ledger, LedgerEntry, SurfaceDelta, SURFACE_FILES};
use crate::util::{compression_kill_switch, state_dir, unique_id};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

pub const MAX_RESULTS_DEFAULT: usize = 200;

/// Locate the pinned helper: $BRAIN_SYMBOLS_BIN override (tests/dev), else the
/// newest vendored install (same pattern as rtk).
pub fn helper_binary() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("BRAIN_SYMBOLS_BIN") {
        let path = PathBuf::from(path);
        return path.exists().then_some(path);
    }
    let home = std::env::var("HOME").ok()?;
    let base = Path::new(&home).join(".local/share/brain/vendor/brain-symbols");
    let mut newest = None;
    for entry in std::fs::read_dir(&base).ok()?.flatten() {
        let candidate = entry.path().join("brain-symbols");
        if candidate.exists() {
            newest = Some(candidate);
        }
    }
    newest
}

pub fn lang_for(path: &Path) -> Option<&'static str> {
    match path.extension().and_then(|e| e.to_str())? {
        "rs" => Some("rust"),
        "py" => Some("python"),
        "ts" => Some("typescript"),
        "tsx" | "jsx" | "js" => Some("tsx"),
        "go" => Some("go"),
        "sh" | "bash" => Some("bash"),
        _ => None,
    }
}

async fn helper(command: &str, lang: &str, symbol: Option<&str>, content: &[u8]) -> Option<Vec<Value>> {
    let bin = helper_binary()?;
    let mut invocation = Command::new(&bin);
    invocation.arg(command).arg("--lang").arg(lang);
    if let Some(symbol) = symbol {
        invocation.arg("--symbol").arg(symbol);
    }
    let mut child = invocation
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(content).await;
        let _ = stdin.shutdown().await;
    }
    let output = child.wait_with_output().await.ok()?;
    if !output.status.success() {
        return None;
    }
    serde_json::from_slice::<Vec<Value>>(&output.stdout).ok()
}

/// `brain compress read FILE --symbols` body: structural outline via the
/// helper, or the lexical outline with an explicit fallback marker.
pub async fn symbols_view(path: &Path, content: &str) -> (String, bool) {
    let structural = match lang_for(path) {
        Some(lang) => helper("defs", lang, None, content.as_bytes()).await,
        None => None,
    };
    match structural {
        Some(defs) => {
            let mut view = String::from("SYMBOLS (tree-sitter parse — NOT AN EDIT SOURCE)\n");
            for def in defs {
                let get = |k: &str| def.get(k).and_then(Value::as_str).unwrap_or("").to_string();
                let line_start = def.get("line_start").and_then(Value::as_u64).unwrap_or(0);
                let line_end = def.get("line_end").and_then(Value::as_u64).unwrap_or(line_start);
                view.push_str(&format!(
                    "{:<18} {:<28} L{}-{}  {}\n",
                    get("kind"),
                    get("name"),
                    line_start,
                    line_end,
                    get("signature"),
                ));
            }
            (view, true)
        }
        None => {
            let lines: Vec<&str> = content.lines().collect();
            let mut view = String::from("[lexical fallback: brain-symbols unavailable or parse failed]\n");
            view.push_str(&crate::files::outline_view(&lines));
            (view, true)
        }
    }
}

struct RefsArgs {
    symbol: String,
    root: PathBuf,
    kind: Option<String>,
    json: bool,
}

fn parse_refs(rest: Vec<String>) -> Result<RefsArgs, String> {
    let mut symbol = None;
    let mut root = None;
    let mut kind = None;
    let mut json = false;
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--kind" => {
                i += 1;
                let value = rest.get(i).ok_or("--kind requires def|ref|call")?.clone();
                if !matches!(value.as_str(), "def" | "ref" | "call") {
                    return Err("--kind must be def|ref|call".to_string());
                }
                kind = Some(value);
            }
            "--json" => json = true,
            other if other.starts_with("--") => return Err(format!("unknown option {other}")),
            other => {
                if symbol.is_none() {
                    symbol = Some(other.to_string());
                } else if root.is_none() {
                    root = Some(PathBuf::from(other));
                } else {
                    return Err("too many arguments".to_string());
                }
            }
        }
        i += 1;
    }
    Ok(RefsArgs {
        symbol: symbol.ok_or("usage: brain compress refs SYMBOL [PATH] [--kind def|ref|call] [--json]")?,
        root: root.unwrap_or_else(|| PathBuf::from(".")),
        kind,
        json,
    })
}

pub async fn refs(rest: Vec<String>) -> i32 {
    match refs_inner(rest).await {
        Ok(code) => code,
        Err(message) => {
            eprintln!("brain compress refs: {message}");
            2
        }
    }
}

async fn refs_inner(rest: Vec<String>) -> Result<i32, String> {
    let args = parse_refs(rest)?;
    let state = state_dir()?;
    let enabled = compression_kill_switch(&state).is_none()
        && Config::load(&state).map(|c| c.enabled).unwrap_or(false);
    let config = Config::load(&state)?;
    let structural = helper_binary().is_some();

    // Lexical prefilter: bounded walk collecting files that mention the symbol.
    let mut candidates: Vec<PathBuf> = Vec::new();
    let mut scanned = 0usize;
    walk(&args.root, 0, &mut scanned, &mut |path, _bytes| {
        if let Ok(content) = std::fs::read_to_string(path) {
            if content.contains(&args.symbol) {
                candidates.push(path.to_path_buf());
            }
        }
    });
    candidates.sort();

    // Classify per file (structural when possible, lexical rows otherwise).
    let mut rows: Vec<(String, u64, String, String, bool)> = Vec::new(); // kind, line, path, context, structural
    for path in &candidates {
        let Ok(content) = std::fs::read_to_string(path) else { continue };
        let display = path.strip_prefix(&args.root).unwrap_or(path).display().to_string();
        let classified = match lang_for(path) {
            Some(lang) if structural => helper("classify", lang, Some(&args.symbol), content.as_bytes()).await,
            _ => None,
        };
        match classified {
            Some(hits) => {
                for hit in hits {
                    let kind = hit.get("kind").and_then(Value::as_str).unwrap_or("ref").to_string();
                    let line = hit.get("line").and_then(Value::as_u64).unwrap_or(0);
                    let context = hit.get("context").and_then(Value::as_str).unwrap_or("").to_string();
                    rows.push((kind, line, display.clone(), context, true));
                }
            }
            None => {
                // Lexical fallback rows: marked approximate, never classified.
                for (index, line) in content.lines().enumerate() {
                    if line.contains(&args.symbol) {
                        rows.push((
                            "~text".to_string(),
                            (index + 1) as u64,
                            display.clone(),
                            line.trim_end().to_string(),
                            false,
                        ));
                    }
                }
            }
        }
    }

    if let Some(filter) = &args.kind {
        rows.retain(|(kind, ..)| kind == filter);
    }

    if rows.is_empty() {
        println!("no results for {:?} under {}", args.symbol, args.root.display());
        return Ok(0);
    }

    // Persist the FULL result before capping the view.
    let full = render_rows(&rows, args.json);
    let mut handle = None;
    if enabled {
        if let Ok(store) = ArtifactStore::new(&state, config.artifact_ttl_days, config.artifact_quota_bytes) {
            let metadata = ArtifactMetadata {
                source_event_id: Some(unique_id("refs")),
                model: None,
                surface: Some(SURFACE_FILES.to_string()),
                claim_saved_bytes: 0,
            };
            handle = store.put_bytes(full.as_bytes(), "refs_result", false, &metadata).ok().map(|m| m.id);
        }
    }

    let cap = config.symbols_max_results as usize;
    let capped: Vec<_> = rows.iter().take(cap).cloned().collect();
    let omitted = rows.len().saturating_sub(capped.len());
    let counts = |k: &str| rows.iter().filter(|(kind, ..)| kind == k).count();
    let mode = if structural { "tree-sitter" } else { "LEXICAL FALLBACK (~approximate)" };

    println!(
        "[brain-compress refs {:?} {} defs={} calls={} refs={} lexical={} files={}{}]",
        args.symbol,
        mode,
        counts("def"),
        counts("call"),
        counts("ref"),
        counts("~text"),
        candidates.len(),
        match &handle {
            Some(h) => format!(" id={h}"),
            None => String::new(),
        },
    );
    print!("{}", render_rows(&capped, args.json));
    if omitted > 0 {
        match &handle {
            Some(h) => println!("[+{omitted} results omitted — recover: brain compress show {h} --full]"),
            None => println!("[+{omitted} results omitted]"),
        }
    }

    if let (true, Some(h)) = (enabled, handle.as_ref()) {
        let delivered = render_rows(&capped, args.json).len() as u64;
        record(&state, &config, h, full.len() as u64, delivered, omitted > 0);
    }
    Ok(0)
}

fn render_rows(rows: &[(String, u64, String, String, bool)], json: bool) -> String {
    if json {
        let values: Vec<Value> = rows
            .iter()
            .map(|(kind, line, path, context, structural)| {
                serde_json::json!({
                    "kind": kind, "line": line, "path": path,
                    "context": context, "structural": structural,
                })
            })
            .collect();
        format!("{}\n", serde_json::to_string_pretty(&values).unwrap_or_default())
    } else {
        let mut out = String::new();
        for (kind, line, path, context, _) in rows {
            out.push_str(&format!("{kind:<5} {path}:{line}  {context}\n"));
        }
        out
    }
}

fn record(state: &Path, config: &Config, handle: &str, observed: u64, delivered: u64, compressed: bool) {
    let Ok(ledger) = Ledger::new(state, config.estimated_bytes_per_token) else { return };
    let mut entry = LedgerEntry::new_consult("refs");
    entry.event_kind = "file".to_string();
    entry.success = true;
    entry.raw_response_bytes = observed;
    entry.answer_bytes = delivered;
    entry.artifacts.insert("raw".to_string(), handle.to_string());
    entry.surfaces.push(SurfaceDelta {
        surface: SURFACE_FILES.to_string(),
        observed_bytes: observed,
        delivered_bytes: if compressed && delivered < observed { delivered } else { observed },
        recovered_bytes: 0,
        compressed: compressed && delivered < observed,
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
    fn lang_detection_covers_grammar_budget() {
        assert_eq!(lang_for(Path::new("a.rs")), Some("rust"));
        assert_eq!(lang_for(Path::new("a.py")), Some("python"));
        assert_eq!(lang_for(Path::new("a.ts")), Some("typescript"));
        assert_eq!(lang_for(Path::new("a.tsx")), Some("tsx"));
        assert_eq!(lang_for(Path::new("a.go")), Some("go"));
        assert_eq!(lang_for(Path::new("a.sh")), Some("bash"));
        assert_eq!(lang_for(Path::new("a.txt")), None);
    }

    #[test]
    fn refs_args_validate_kind() {
        assert!(parse_refs(vec!["x".into(), "--kind".into(), "def".into()]).is_ok());
        assert!(parse_refs(vec!["x".into(), "--kind".into(), "bogus".into()]).is_err());
        assert!(parse_refs(vec![]).is_err());
    }
}
