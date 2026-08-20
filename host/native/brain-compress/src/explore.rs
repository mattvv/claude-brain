//! `brain explore "QUESTION"` — cheap-model repository navigation (design §2).
//!
//! The expensive main model never reads files to orient itself: a locally
//! assembled, byte-bounded pack (tree + grep hits + outlines) goes to a cheap
//! model once, and the dense cited `Defs:/Refs:/Flow:` block it returns IS the
//! caller's context.
//!
//! Honesty: the consult's provider usage is recorded by the normal ask path
//! (the real COST of the feature). No compression saving is claimed — "the
//! brain would have read N files" is a counterfactual; the ledger records the
//! pack and answer facts only. The pack is persisted as an artifact before it
//! is sent, and the emitted header carries its recovery handle plus the
//! discovery-only marker: the output is never an edit source.

use crate::artifact::{ArtifactMetadata, ArtifactStore};
use crate::config::Config;
use crate::files::{outline_view, query_view};
use crate::ledger::SURFACE_FILES;
use crate::util::{compression_kill_switch, state_dir, unique_id};
use std::path::{Path, PathBuf};

/// Embedded at build time so the binary and its navigator contract can never
/// drift apart; BRAIN_EXPLORE_SYSTEM overrides for experiments.
const SYSTEM_PROMPT: &str = include_str!("../../../claude/explore-system.md");

pub(crate) const TEXT_EXTENSIONS: &[&str] = &[
    "rs", "py", "ts", "tsx", "js", "jsx", "go", "sh", "bash", "c", "h", "cpp", "hpp",
    "java", "rb", "php", "md", "toml", "yaml", "yml", "json", "sql", "css", "html",
];
pub(crate) const SKIP_DIRS: &[&str] = &[".git", "node_modules", "target", "vendor", "dist", "build", ".venv"];
pub(crate) const MAX_FILES_SCANNED: usize = 2000;
const MAX_SCAN_BYTES: u64 = 256 * 1024;
const SMALL_FILE_WHOLE: usize = 12 * 1024;
pub(crate) const MAX_DEPTH: usize = 6;

pub async fn run(rest: Vec<String>) -> i32 {
    match run_inner(rest).await {
        Ok(code) => code,
        Err(message) => {
            eprintln!("brain explore: {message}");
            2
        }
    }
}

struct ExploreArgs {
    question: String,
    root: PathBuf,
    model: Option<String>,
}

fn parse_args(rest: Vec<String>) -> Result<ExploreArgs, String> {
    let mut question = None;
    let mut root = None;
    let mut model = None;
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--root" => {
                i += 1;
                root = Some(PathBuf::from(rest.get(i).ok_or("--root requires a path")?));
            }
            "--model" => {
                i += 1;
                model = Some(rest.get(i).ok_or("--model requires a model id")?.clone());
            }
            other if other.starts_with("--") => return Err(format!("unknown option {other}")),
            other => {
                if question.is_some() {
                    return Err("give ONE quoted question".to_string());
                }
                question = Some(other.to_string());
            }
        }
        i += 1;
    }
    Ok(ExploreArgs {
        question: question.ok_or("usage: brain explore \"QUESTION\" [--root PATH] [--model M]")?,
        root: root.unwrap_or_else(|| PathBuf::from(".")),
        model,
    })
}

async fn run_inner(rest: Vec<String>) -> Result<i32, String> {
    let args = parse_args(rest)?;
    let state = state_dir()?;
    if compression_kill_switch(&state).is_some() {
        return Err("compression subsystem is disabled (kill switch)".to_string());
    }
    let config = Config::load(&state)?;
    // Model fallback chain: an explicit --model overrides to a single model;
    // otherwise use the configured chain and fall through on failure.
    let models: Vec<String> = match &args.model {
        Some(m) => vec![m.clone()],
        None => config.explore_models.clone(),
    };
    if models.is_empty() {
        return Err("no explore model configured (set [explore] model)".to_string());
    }
    for model in &models {
        let lower = model.to_lowercase();
        if ["claude", "opus", "sonnet", "haiku", "fable"].iter().any(|f| lower.contains(f)) {
            return Err(format!("refusing to explore with a Claude-family model ({model})"));
        }
    }
    let primary = &models[0];

    // 1. Deterministic gather (no model).
    let tokens = identifier_tokens(&args.question);
    if tokens.is_empty() {
        return Err("the question contains no searchable identifiers".to_string());
    }
    let mut candidates = scan(&args.root, &tokens)?;
    candidates.sort_by(|a, b| b.score.cmp(&a.score));

    let budget = config.explore_max_pack_bytes as usize;
    let (pack, included, omitted) = build_pack(&args.root, &candidates, &tokens, budget);
    if included == 0 {
        return Err(format!(
            "nothing under {} matches {:?} — refine the question or --root",
            args.root.display(),
            tokens
        ));
    }

    // 2. Persist the pack before sending (recovery for the lossy projection).
    let store = ArtifactStore::new(&state, config.artifact_ttl_days, config.artifact_quota_bytes)?;
    let metadata = ArtifactMetadata {
        source_event_id: Some(unique_id("explore")),
        model: Some(primary.clone()),
        surface: Some(SURFACE_FILES.to_string()),
        claim_saved_bytes: 0,
    };
    let handle = store
        .put_bytes(pack.as_bytes(), "explore_pack", false, &metadata)
        .map(|m| m.id)
        .map_err(|e| format!("cannot persist explore pack: {e}"))?;

    println!(
        "[brain-explore models={} pack={}B files={included} omitted={omitted} id={handle}]",
        models.join(","),
        pack.len(),
    );
    println!("[discovery only — verify cited lines before editing; pack: brain compress show {handle} --full]");

    // 3. One consult through the normal ask path (its ledger entry carries the
    //    provider ground-truth cost of this feature). Walk the fallback chain:
    //    try each model in order, moving on when a call fails (vendor not linked,
    //    transport/HTTP error). A successful consult short-circuits.
    let system_path = match std::env::var("BRAIN_EXPLORE_SYSTEM") {
        Ok(path) => PathBuf::from(path),
        Err(_) => {
            let tmp = std::env::temp_dir().join(format!("brain-explore-system-{}.md", std::process::id()));
            std::fs::write(&tmp, SYSTEM_PROMPT).map_err(|e| format!("cannot stage system prompt: {e}"))?;
            tmp
        }
    };
    let prompt = format!("QUESTION: {}\n\n{pack}", args.question);
    let mut last_code = 1;
    for (idx, model) in models.iter().enumerate() {
        if idx > 0 {
            eprintln!(
                "brain explore: {} unavailable — falling back to {model}",
                models[idx - 1]
            );
        }
        let ask_args = vec![
            model.clone(),
            "--system".to_string(),
            system_path.display().to_string(),
            "--effort".to_string(),
            config.explore_effort.clone(),
            "--max-tokens".to_string(),
            "2000".to_string(),
            prompt.clone(),
        ];
        let code = crate::ask::run(ask_args).await;
        if code == 0 {
            println!();
            return Ok(0);
        }
        last_code = code;
    }
    eprintln!(
        "brain explore: all configured models failed ({})",
        models.join(", ")
    );
    Ok(last_code)
}

/// Identifier-like tokens from the question (>=3 chars, not stopwords).
fn identifier_tokens(question: &str) -> Vec<String> {
    const STOPWORDS: &[&str] = &[
        "the", "and", "for", "how", "does", "where", "what", "which", "with", "from",
        "into", "this", "that", "are", "can", "why", "when", "who", "its", "use", "used",
        "uses", "get", "set", "all", "any", "one", "two", "not", "but", "has", "have",
        "file", "files", "code", "work", "works",
    ];
    let mut tokens = Vec::new();
    let mut current = String::new();
    for c in question.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            current.push(c);
        } else if !current.is_empty() {
            tokens.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    let mut out: Vec<String> = Vec::new();
    for token in tokens {
        if token.len() < 3 || STOPWORDS.contains(&token.to_lowercase().as_str()) {
            continue;
        }
        if !out.iter().any(|t| t.eq_ignore_ascii_case(&token)) {
            out.push(token);
        }
    }
    out
}

struct Candidate {
    path: PathBuf,
    score: u64,
    bytes: u64,
}

fn scan(root: &Path, tokens: &[String]) -> Result<Vec<Candidate>, String> {
    let mut out = Vec::new();
    let mut scanned = 0usize;
    walk(root, 0, &mut scanned, &mut |path, bytes| {
        let name_bonus: u64 = tokens
            .iter()
            .filter(|t| path.to_string_lossy().to_lowercase().contains(&t.to_lowercase()))
            .count() as u64
            * 5;
        let content = std::fs::read_to_string(path).unwrap_or_default();
        let lower = content.to_lowercase();
        let mut hits: u64 = 0;
        for token in tokens {
            hits += lower.matches(&token.to_lowercase()).count().min(50) as u64;
        }
        if hits + name_bonus > 0 {
            out.push(Candidate { path: path.to_path_buf(), score: hits + name_bonus, bytes });
        }
    });
    Ok(out)
}

pub(crate) fn walk(dir: &Path, depth: usize, scanned: &mut usize, visit: &mut dyn FnMut(&Path, u64)) {
    if depth > MAX_DEPTH || *scanned >= MAX_FILES_SCANNED {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        if *scanned >= MAX_FILES_SCANNED {
            return;
        }
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            if !SKIP_DIRS.contains(&name.as_str()) && !name.starts_with('.') {
                walk(&path, depth + 1, scanned, visit);
            }
            continue;
        }
        let Some(ext) = path.extension().and_then(|e| e.to_str()) else { continue };
        if !TEXT_EXTENSIONS.contains(&ext) {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if meta.len() > MAX_SCAN_BYTES {
            continue;
        }
        *scanned += 1;
        visit(&path, meta.len());
    }
}

/// Assemble the pack: whole small files, outline+matched regions for large
/// ones, until the byte budget; explicit omissions list for the rest.
fn build_pack(root: &Path, candidates: &[Candidate], tokens: &[String], budget: usize) -> (String, usize, usize) {
    let mut pack = String::from("<BRAIN_EXPLORE_PACK v=1>\n");
    pack.push_str("Partial projection of the repository, selected by relevance to the question.\n");
    let mut included = 0usize;
    let mut index = 0usize;
    for candidate in candidates {
        if pack.len() >= budget {
            break;
        }
        index += 1;
        let display = candidate
            .path
            .strip_prefix(root)
            .unwrap_or(&candidate.path)
            .display();
        let Ok(content) = std::fs::read_to_string(&candidate.path) else { continue };
        let lines: Vec<&str> = content.lines().collect();
        let mut section = String::new();
        if content.len() <= SMALL_FILE_WHOLE {
            section.push_str(&format!("\n--- {display} (whole file, {} lines) ---\n", lines.len()));
            section.push_str(&content);
            if !content.ends_with('\n') {
                section.push('\n');
            }
        } else {
            section.push_str(&format!(
                "\n--- {display} (OUTLINE + matched regions of {} lines; partial) ---\n",
                lines.len()
            ));
            section.push_str(&outline_view(&lines));
            for token in tokens.iter().take(4) {
                let (view, _) = query_view(&lines, token, 3);
                if !view.starts_with("(no lines match") {
                    section.push_str(&format!("-- lines matching {token:?} --\n"));
                    section.push_str(&view);
                }
            }
        }
        if pack.len() + section.len() > budget && included > 0 {
            index -= 1;
            break;
        }
        pack.push_str(&section);
        included += 1;
    }
    let omitted = candidates.len().saturating_sub(index);
    if omitted > 0 {
        pack.push_str("\nOMITTED (relevant but over budget):\n");
        for candidate in candidates.iter().skip(index).take(20) {
            let display = candidate.path.strip_prefix(root).unwrap_or(&candidate.path).display();
            pack.push_str(&format!("  {display} ({} B)\n", candidate.bytes));
        }
    }
    pack.push_str("</BRAIN_EXPLORE_PACK>\n");
    (pack, included, omitted)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifier_tokens_filters_stopwords_and_short() {
        let tokens = identifier_tokens("How does the RollupCell merge work with dedup_index?");
        assert!(tokens.contains(&"RollupCell".to_string()));
        assert!(tokens.contains(&"merge".to_string()));
        assert!(tokens.contains(&"dedup_index".to_string()));
        assert!(!tokens.iter().any(|t| t == "How" || t == "the" || t == "does"));
    }

    #[test]
    fn pack_respects_budget_and_lists_omissions() {
        let dir = std::env::temp_dir().join(format!("explore-pack-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for i in 0..4 {
            std::fs::write(dir.join(format!("f{i}.rs")), "fn target() {}\n".repeat(200)).unwrap();
        }
        let tokens = vec!["target".to_string()];
        let candidates = scan(&dir, &tokens).unwrap();
        assert_eq!(candidates.len(), 4);
        let (pack, included, omitted) = build_pack(&dir, &candidates, &tokens, 4000);
        assert!(pack.len() <= 4000 + 600, "pack {} exceeds budget slack", pack.len());
        assert!(included >= 1);
        assert!(omitted >= 1);
        assert!(pack.contains("OMITTED"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
