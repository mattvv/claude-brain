//! `brain compress ...` CLI: status, stats, savings, show, gc, doctor.
//!
//! All accounting output separates the three honesty classes and never sums them
//! into a single headline number:
//!   * ground_truth  — provider-reported usage. Only a real saving once we have a
//!     control-vs-guarded comparison; Stage 1 has no guarded arm, so it reports
//!     "n/a" with the reason.
//!   * measured_bytes — exact raw-in vs delivered-out for compacted surfaces.
//!     Stage 1 compresses nothing, so this is 0 of N observed.
//!   * estimated_tokens — derived from bytes; always labelled, always shows the
//!     divisor.
//! Dollar figures are never printed (subscriptions are flat-rate).

use crate::artifact::ArtifactStore;
use crate::config::Config;
use crate::http;
use crate::ledger::{Ledger, RollupCell, Snapshot, Window};
use crate::util::{compression_kill_switch, grouped_u64, human_bytes, state_dir, token_path, read_to_string};
use std::env;
use std::path::Path;
use std::time::Duration;

pub async fn run(args: Vec<String>) -> i32 {
    let command = args.first().map(String::as_str).unwrap_or("status");
    let rest = if args.is_empty() { &[][..] } else { &args[1..] };
    let result = match command {
        "status" => cmd_status().await,
        "stats" => cmd_stats(rest),
        "savings" => cmd_savings(rest),
        "show" => cmd_show(rest),
        "gc" => cmd_gc(rest),
        "discover" => cmd_discover(rest),
        "json" => return crate::structured::run(rest.to_vec()).await,
        "explore" => return crate::explore::run(rest.to_vec()).await,
        "read" | "grep" | "tree" => {
            let mut passthrough = vec![command.to_string()];
            passthrough.extend(rest.iter().cloned());
            return crate::files::run(passthrough).await;
        }
        // `shell` and `hook` are primarily invoked as `brain-compress shell …`
        // (by the hook) but are routed here too so `brain compress shell …`
        // works for manual use.
        "shell" => return crate::shell::run(rest.to_vec()).await,
        "hook" => return crate::hook::run(rest.to_vec()).await,
        "doctor" => cmd_doctor().await,
        "help" | "--help" | "-h" => {
            print_help();
            Ok(())
        }
        other => Err(format!("unknown command: {other}\n\n{}", help_text())),
    };
    match result {
        Ok(()) => 0,
        Err(message) => {
            eprintln!("brain compress: {message}");
            1
        }
    }
}

fn open_config_and_state() -> Result<(Config, std::path::PathBuf), String> {
    let state = state_dir()?;
    let config = Config::load(&state)?;
    Ok((config, state))
}

// --- status --------------------------------------------------------------------

async fn cmd_status() -> Result<(), String> {
    let (config, state) = open_config_and_state()?;
    println!("claude-brain compression (Stage 1 — observe-only)");
    match compression_kill_switch(&state) {
        Some(reason) => println!("  state:        DISABLED ({reason})"),
        None => println!("  state:        {}", if config.enabled { "enabled" } else { "disabled" }),
    }
    println!("  mode:         {}", config.mode);
    println!("  config:       {}", config.path.display());

    let store = ArtifactStore::new(&state, config.artifact_ttl_days, config.artifact_quota_bytes)?;
    let status = store.status()?;
    println!(
        "  artifacts:    {} objects, {} / {} ({} pinned{})",
        grouped_u64(status.artifacts),
        human_bytes(status.bytes),
        human_bytes(config.artifact_quota_bytes),
        grouped_u64(status.pinned),
        if status.corrupt_manifests > 0 {
            format!(", {} corrupt", status.corrupt_manifests)
        } else {
            String::new()
        }
    );

    let capabilities_path = state.join("compress/capabilities.json");
    if let Ok(text) = read_to_string(&capabilities_path) {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) {
            let flag = |k: &str| value.get(k).and_then(serde_json::Value::as_bool).unwrap_or(false);
            println!(
                "  last probe:   usage={} cache={} reasoning={}",
                yesno(flag("usage_fields_present")),
                yesno(flag("cache_fields_present")),
                yesno(flag("reasoning_token_field_present")),
            );
        }
    } else {
        println!("  last probe:   (none yet — run a consultation or `brain compress doctor`)");
    }
    Ok(())
}

// --- stats / savings -----------------------------------------------------------

fn parse_window(rest: &[String]) -> Window {
    let mut window = Window::Hours24;
    let mut index = 0;
    while index < rest.len() {
        if rest[index] == "--since" {
            if let Some(value) = rest.get(index + 1) {
                window = match value.as_str() {
                    "24h" => Window::Hours24,
                    "7d" => Window::Days7,
                    "30d" => Window::Days30,
                    "lifetime" | "all" => Window::Lifetime,
                    _ => window,
                };
                index += 1;
            }
        }
        index += 1;
    }
    window
}

fn json_requested(rest: &[String]) -> bool {
    rest.iter().any(|a| a == "--json")
}

fn cmd_stats(rest: &[String]) -> Result<(), String> {
    let (config, state) = open_config_and_state()?;
    let ledger = Ledger::new(&state, config.estimated_bytes_per_token)?;
    let window = parse_window(rest);
    let snapshot = ledger.snapshot(window)?;

    if json_requested(rest) {
        print!("{}", snapshot_json(&snapshot, window, &config));
        return Ok(());
    }

    let totals = Totals::from(&snapshot);
    println!("Compression stats — {} (Stage 1, observe-only)", window.name());
    println!();
    println!("CONSULT — provider ground truth");
    println!("  provider calls:        {}", grouped_u64(totals.provider_calls));
    println!("  input tokens sent:     {}", grouped_u64(totals.provider_input_tokens));
    println!("  output tokens gen'd:   {}", grouped_u64(totals.provider_output_tokens));
    println!("  est. fixed proxy prefix: ~{} tokens (irreducible, estimate)", grouped_u64(totals.proxy_prefix_tokens_estimate));
    println!();
    println!("BASELINE — bytes observed (nothing compressed yet)");
    println!("  prompt surface:        {}", human_bytes(totals.prompt_observed));
    println!("  response surface:      {}", human_bytes(totals.response_observed));
    println!();
    println!("Tokens saved");
    print_savings_block(&totals, &config);
    Ok(())
}

fn cmd_savings(rest: &[String]) -> Result<(), String> {
    let (config, state) = open_config_and_state()?;
    let ledger = Ledger::new(&state, config.estimated_bytes_per_token)?;
    let window = parse_window(if rest.is_empty() { &[] } else { rest });
    let effective_window = if rest.iter().any(|a| a == "--since") { window } else { Window::Lifetime };
    let snapshot = ledger.snapshot(effective_window)?;
    let totals = Totals::from(&snapshot);

    if json_requested(rest) {
        print!("{}", snapshot_json(&snapshot, effective_window, &config));
        return Ok(());
    }

    println!("Tokens saved ({})", effective_window.name());
    print_savings_block(&totals, &config);
    println!();
    println!("Baseline observed ({})", effective_window.name());
    println!(
        "  consult prompts        {} tokens provider-reported over {} calls",
        grouped_u64(totals.provider_input_tokens),
        grouped_u64(totals.provider_calls),
    );
    println!(
        "  consult responses      {} raw -> {} delivered",
        human_bytes(totals.response_observed),
        human_bytes(totals.response_delivered),
    );
    println!(
        "  proxy fixed prefix     ~{} tokens across {} calls  (irreducible)",
        grouped_u64(totals.proxy_prefix_tokens_estimate),
        grouped_u64(totals.provider_calls),
    );
    Ok(())
}

fn print_savings_block(totals: &Totals, config: &Config) {
    // ground truth — provider-reported tokens, split per experiment arm. The
    // arms are compared, never merged; the delta only prints once both arms
    // clear the minimum sample size. Means come from rollup sums; for medians
    // and confidence intervals use the paired A/B harness (tests/compress/ab).
    if totals.guarded_calls == 0 {
        println!("  ground truth      n/a — needs control/guarded arms (0 guarded calls so far)");
    } else if totals.control_calls == 0 {
        println!(
            "  ground truth      n/a — {} guarded calls but 0 control calls to compare against",
            grouped_u64(totals.guarded_calls),
        );
    } else {
        let per_call = |tokens: u64, calls: u64| tokens as f64 / calls as f64;
        let control_out = per_call(totals.control_output_tokens, totals.control_calls);
        let guarded_out = per_call(totals.guarded_output_tokens, totals.guarded_calls);
        let control_in = per_call(totals.control_input_tokens, totals.control_calls);
        let guarded_in = per_call(totals.guarded_input_tokens, totals.guarded_calls);
        println!(
            "  ground truth      control {} calls: mean {:.0} in / {:.0} out tok — guarded {} calls: mean {:.0} in / {:.0} out tok",
            grouped_u64(totals.control_calls),
            control_in,
            control_out,
            grouped_u64(totals.guarded_calls),
            guarded_in,
            guarded_out,
        );
        let smallest_arm = totals.control_calls.min(totals.guarded_calls);
        if smallest_arm < config.minimum_claim_samples {
            println!(
                "                    delta suppressed (smallest arm {}<{} calls)",
                grouped_u64(smallest_arm),
                grouped_u64(config.minimum_claim_samples),
            );
        } else {
            let delta = |control: f64, guarded: f64| {
                if control > 0.0 { (guarded - control) / control * 100.0 } else { 0.0 }
            };
            println!(
                "                    guarded vs control per call: output {:+.1}%, input {:+.1}% (means; medians via tests/compress/ab)",
                delta(control_out, guarded_out),
                delta(control_in, guarded_in),
            );
        }
    }
    // measured bytes
    let observed = totals.compressed_raw;
    let saved = totals.measured_saved_bytes();
    let pct = if observed > 0 { (saved as f64 / observed as f64) * 100.0 } else { 0.0 };
    if totals.compressed_events < config.minimum_claim_samples {
        println!(
            "  measured bytes    {} saved of {} observed  (sample {}<{}: % suppressed)",
            human_bytes(saved),
            human_bytes(observed),
            grouped_u64(totals.compressed_events),
            grouped_u64(config.minimum_claim_samples),
        );
    } else {
        println!(
            "  measured bytes    {} saved of {} observed  ({:.1}%)",
            human_bytes(saved),
            human_bytes(observed),
            pct,
        );
    }
    // estimated tokens
    let est = (saved as f64 / config.estimated_bytes_per_token).round() as u64;
    println!(
        "  estimated tokens  ~{} saved (est. bytes/{})",
        grouped_u64(est),
        config.estimated_bytes_per_token,
    );
}

#[derive(Default)]
struct Totals {
    provider_calls: u64,
    control_calls: u64,
    guarded_calls: u64,
    provider_input_tokens: u64,
    provider_output_tokens: u64,
    control_input_tokens: u64,
    control_output_tokens: u64,
    guarded_input_tokens: u64,
    guarded_output_tokens: u64,
    proxy_prefix_tokens_estimate: u64,
    prompt_observed: u64,
    response_observed: u64,
    response_delivered: u64,
    compressed_events: u64,
    compressed_raw: u64,
    compressed_delivered: u64,
    recovered_bytes: u64,
}

impl Totals {
    fn from(snapshot: &Snapshot) -> Self {
        let mut totals = Totals::default();
        for cell in &snapshot.cells {
            totals.provider_calls += cell.provider_calls;
            totals.control_calls += cell.control_calls;
            totals.guarded_calls += cell.guarded_calls;
            totals.provider_input_tokens += cell.provider_input_tokens;
            totals.provider_output_tokens += cell.provider_output_tokens;
            totals.control_input_tokens += cell.control_input_tokens;
            totals.control_output_tokens += cell.control_output_tokens;
            totals.guarded_input_tokens += cell.guarded_input_tokens;
            totals.guarded_output_tokens += cell.guarded_output_tokens;
            totals.proxy_prefix_tokens_estimate += cell.proxy_prefix_tokens_estimate;
            totals.compressed_events += cell.compressed_events;
            totals.compressed_raw += cell.compressed_raw_bytes;
            totals.compressed_delivered += cell.compressed_delivered_bytes;
            totals.recovered_bytes += cell.recovered_bytes;
            match cell.surface.as_str() {
                "consult-prompt" => totals.prompt_observed += cell.observed_bytes,
                "consult-response" => {
                    totals.response_observed += cell.observed_bytes;
                    totals.response_delivered += cell.delivered_bytes;
                }
                _ => {}
            }
        }
        totals
    }

    fn measured_saved_bytes(&self) -> u64 {
        self.compressed_raw
            .saturating_sub(self.compressed_delivered)
            .saturating_sub(self.recovered_bytes)
    }
}

fn snapshot_json(snapshot: &Snapshot, window: Window, config: &Config) -> String {
    let totals = Totals::from(snapshot);
    let cells: Vec<serde_json::Value> = snapshot
        .cells
        .iter()
        .map(cell_json)
        .collect();
    let value = serde_json::json!({
        "window": window.name(),
        "estimated_bytes_per_token": config.estimated_bytes_per_token,
        "minimum_claim_samples": config.minimum_claim_samples,
        "ground_truth": {
            "provider_calls": totals.provider_calls,
            "control_calls": totals.control_calls,
            "guarded_calls": totals.guarded_calls,
            "provider_input_tokens": totals.provider_input_tokens,
            "provider_output_tokens": totals.provider_output_tokens,
            "control_input_tokens": totals.control_input_tokens,
            "control_output_tokens": totals.control_output_tokens,
            "guarded_input_tokens": totals.guarded_input_tokens,
            "guarded_output_tokens": totals.guarded_output_tokens,
            "comparable": totals.guarded_calls > 0,
            "claimable": totals.control_calls.min(totals.guarded_calls) >= config.minimum_claim_samples,
            "proxy_prefix_tokens_estimate": totals.proxy_prefix_tokens_estimate
        },
        "measured_bytes": {
            "compressed_events": totals.compressed_events,
            "observed_bytes": totals.compressed_raw,
            "delivered_bytes": totals.compressed_delivered,
            "recovered_bytes": totals.recovered_bytes,
            "saved_bytes": totals.measured_saved_bytes()
        },
        "estimated_tokens": {
            "divisor": config.estimated_bytes_per_token,
            "saved_tokens_estimate": (totals.measured_saved_bytes() as f64 / config.estimated_bytes_per_token).round() as u64
        },
        "baseline": {
            "prompt_observed_bytes": totals.prompt_observed,
            "response_observed_bytes": totals.response_observed,
            "response_delivered_bytes": totals.response_delivered
        },
        "cells": cells
    });
    format!("{}\n", serde_json::to_string_pretty(&value).unwrap_or_default())
}

fn cell_json(cell: &RollupCell) -> serde_json::Value {
    serde_json::json!({
        "model": cell.model,
        "surface": cell.surface,
        "events": cell.events,
        "provider_calls": cell.provider_calls,
        "observed_bytes": cell.observed_bytes,
        "delivered_bytes": cell.delivered_bytes,
        "compressed_events": cell.compressed_events,
        "saved_bytes": cell.saved_bytes(),
        "provider_input_tokens": cell.provider_input_tokens,
        "provider_output_tokens": cell.provider_output_tokens,
        "control_input_tokens": cell.control_input_tokens,
        "control_output_tokens": cell.control_output_tokens,
        "guarded_input_tokens": cell.guarded_input_tokens,
        "guarded_output_tokens": cell.guarded_output_tokens,
        "proxy_prefix_tokens_estimate": cell.proxy_prefix_tokens_estimate
    })
}

// --- show ----------------------------------------------------------------------

fn cmd_show(rest: &[String]) -> Result<(), String> {
    let (config, state) = open_config_and_state()?;
    // The id is the first positional token: skip flags and the value that
    // follows --lines.
    let mut id = None;
    let mut skip_next = false;
    for arg in rest {
        if skip_next {
            skip_next = false;
            continue;
        }
        if arg == "--lines" {
            skip_next = true;
            continue;
        }
        if arg.starts_with("--") {
            continue;
        }
        id = Some(arg.clone());
        break;
    }
    let id = id
        .ok_or_else(|| "usage: brain compress show <artifact-id> [--full] [--lines A:B]".to_string())?;
    let full = rest.iter().any(|a| a == "--full");
    let lines = rest
        .iter()
        .position(|a| a == "--lines")
        .and_then(|i| rest.get(i + 1))
        .cloned();

    let store = ArtifactStore::new(&state, config.artifact_ttl_days, config.artifact_quota_bytes)?;
    let manifest = store.manifest(&id)?;

    if !full && lines.is_none() {
        // Metadata only — do not dump the whole artifact by default.
        println!("artifact {}", manifest.id);
        println!("  sha256:     {}", manifest.sha256);
        println!("  bytes:      {}", human_bytes(manifest.byte_length));
        println!("  kind:       {}", manifest.kind);
        println!("  surface:    {}", manifest.surface.as_deref().unwrap_or("-"));
        println!("  model:      {}", manifest.model.as_deref().unwrap_or("-"));
        println!("  pinned:     {}", manifest.pinned);
        println!("  created_at: {}", manifest.created_at);
        println!("  expires_at: {}", manifest.expires_at);
        println!();
        println!("  full:  brain compress show {} --full", manifest.id);
        println!("  range: brain compress show {} --lines 1:80", manifest.id);
        return Ok(());
    }

    let bytes = store.read(&id)?;
    let text = String::from_utf8_lossy(&bytes);
    match lines {
        Some(spec) => {
            let (start, end) = parse_line_range(&spec)?;
            for (number, line) in text.lines().enumerate() {
                let n = number + 1;
                if n >= start && n <= end {
                    println!("{line}");
                }
            }
        }
        None => print!("{text}"),
    }
    Ok(())
}

fn parse_line_range(spec: &str) -> Result<(usize, usize), String> {
    let (start, end) = spec
        .split_once(':')
        .ok_or_else(|| format!("invalid --lines range: {spec} (expected A:B)"))?;
    let start = start.parse::<usize>().map_err(|_| format!("invalid start line: {start}"))?;
    let end = end.parse::<usize>().map_err(|_| format!("invalid end line: {end}"))?;
    if start == 0 || end < start {
        return Err(format!("invalid --lines range: {spec}"));
    }
    Ok((start, end))
}

// --- gc ------------------------------------------------------------------------

fn cmd_gc(rest: &[String]) -> Result<(), String> {
    let (config, state) = open_config_and_state()?;
    let dry_run = rest.iter().any(|a| a == "--dry-run");
    let store = ArtifactStore::new(&state, config.artifact_ttl_days, config.artifact_quota_bytes)?;
    if dry_run {
        let status = store.status()?;
        println!("gc --dry-run: {} objects, {} on disk", grouped_u64(status.artifacts), human_bytes(status.bytes));
        println!("(dry-run does not evict; run without --dry-run to collect expired/over-quota unpinned artifacts)");
        return Ok(());
    }
    let report = store.gc()?;
    println!(
        "gc: removed {} artifacts ({}), retained {} ({}), {} pinned{}",
        grouped_u64(report.removed_artifacts),
        human_bytes(report.removed_bytes),
        grouped_u64(report.retained_artifacts),
        human_bytes(report.retained_bytes),
        grouped_u64(report.pinned_artifacts),
        if report.corrupt_manifests > 0 {
            format!(", {} corrupt manifests skipped", report.corrupt_manifests)
        } else {
            String::new()
        }
    );
    Ok(())
}

// --- discover ------------------------------------------------------------------

fn cmd_discover(_rest: &[String]) -> Result<(), String> {
    let (_config, state) = open_config_and_state()?;
    let path = state.join("compress/discover.log");
    let text = match read_to_string(&path) {
        Ok(text) => text,
        Err(_) => {
            println!("No missed compression opportunities recorded yet.");
            return Ok(());
        }
    };
    // Aggregate by the leading tool + subcommand so the report is compact.
    let mut counts: std::collections::BTreeMap<String, u64> = std::collections::BTreeMap::new();
    for line in text.lines() {
        let command = line.splitn(2, '\t').nth(1).unwrap_or(line);
        let mut parts = command.split_whitespace();
        let key = match (parts.next(), parts.next()) {
            (Some(a), Some(b)) => format!("{a} {b}"),
            (Some(a), None) => a.to_string(),
            _ => continue,
        };
        *counts.entry(key).or_insert(0) += 1;
    }
    if counts.is_empty() {
        println!("No missed compression opportunities recorded yet.");
        return Ok(());
    }
    println!("Missed compression opportunities (compressible tool inside a complex command):");
    let mut rows: Vec<(String, u64)> = counts.into_iter().collect();
    rows.sort_by(|a, b| b.1.cmp(&a.1));
    for (key, count) in rows {
        println!("  {:>5}x  {key}", count);
    }
    println!();
    println!("These ran through a pipe/redirect/quoting, so the hook did not rewrite them.");
    println!("Run the core command on its own to get a compacted, recoverable view.");
    Ok(())
}

// --- doctor --------------------------------------------------------------------

async fn cmd_doctor() -> Result<(), String> {
    let (config, state) = open_config_and_state()?;
    println!("brain compress doctor");
    println!("  config:       {}", config.path.display());
    println!("  state dir:    {}", state.display());
    match compression_kill_switch(&state) {
        Some(reason) => println!("  kill switch:  ACTIVE ({reason})"),
        None => println!("  kill switch:  inactive"),
    }

    // Proxy reachability (async GET to /v1/models).
    let proxy_base = env::var("BRAIN_PROXY_URL").unwrap_or_else(|_| "http://127.0.0.1:8317".to_string());
    let models_url = http::join_url(&proxy_base, "/v1/models");
    let headers = match token_path().and_then(|p| read_to_string(&p)) {
        Ok(token) => vec![("Authorization".to_string(), format!("Bearer {}", token.trim()))],
        Err(_) => Vec::new(),
    };
    match http::get_status(&models_url, &headers, Duration::from_secs(10)).await {
        Ok(status) => println!("  proxy:        reachable at {proxy_base} (HTTP {status})"),
        Err(error) => println!("  proxy:        UNREACHABLE ({error})"),
    }

    // Re-report the last observed provider capability facts.
    let capabilities_path = state.join("compress/capabilities.json");
    match read_to_string(&capabilities_path) {
        Ok(text) => match serde_json::from_str::<serde_json::Value>(&text) {
            Ok(value) => {
                let flag = |k: &str| value.get(k).and_then(serde_json::Value::as_bool).unwrap_or(false);
                println!("  usage fields:     {}", yesno(flag("usage_fields_present")));
                println!("  cache fields:     {} (H4: expected absent on this proxy)", yesno(flag("cache_fields_present")));
                println!("  reasoning tokens: {}", yesno(flag("reasoning_token_field_present")));
            }
            Err(error) => println!("  capabilities:  unreadable ({error})"),
        },
        Err(_) => println!("  capabilities:  none recorded yet (run a consultation)"),
    }

    // RTK presence (informational; used from Stage 2 onward).
    let rtk = rtk_path(&state);
    match rtk {
        Some(path) => println!("  rtk:          present ({})", path.display()),
        None => println!("  rtk:          not installed (Stage 2 dependency)"),
    }
    Ok(())
}

fn rtk_path(_state: &Path) -> Option<std::path::PathBuf> {
    let home = env::var("HOME").ok()?;
    let base = Path::new(&home).join(".local/share/brain/vendor/rtk");
    let entries = std::fs::read_dir(&base).ok()?;
    let mut newest: Option<std::path::PathBuf> = None;
    for entry in entries.flatten() {
        let candidate = entry.path().join("rtk");
        if candidate.exists() {
            newest = Some(candidate);
        }
    }
    newest
}

// --- help ----------------------------------------------------------------------

fn yesno(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn print_help() {
    println!("{}", help_text());
}

fn help_text() -> String {
    "brain compress — token accounting and artifacts (Stage 1: observe-only)\n\
\n\
  brain compress status                 subsystem + artifact store state\n\
  brain compress stats [--since W] [--json]   per-window accounting (W: 24h|7d|30d|lifetime)\n\
  brain compress savings [--since W] [--json] tokens saved, three honest classes\n\
  brain compress show <id> [--full] [--lines A:B]   inspect/recover an artifact\n\
  brain compress gc [--dry-run]         collect expired/over-quota unpinned artifacts\n\
  brain compress json [FILE|-] [--table] [--fields a,b.c]   structured projection (raw persisted)\n\
  brain explore QUESTION [--root P]     cheap-model repo navigation (discovery only)\n\
  brain compress discover               commands that could compress but were too complex\n\
  brain compress doctor                 probe proxy + re-report capability facts"
        .to_string()
}
