//! `brain compress json` — schema-aware JSON/NDJSON projection (design §5b).
//!
//! Explicit-invocation v1: standard syntax only (minified JSON or a Markdown
//! table for homogeneous arrays of scalar records) — no custom encodings, no
//! query language, no auto-detection in the shell path.
//!
//! Fidelity:
//!   * exact raw bytes persisted BEFORE any view; header carries recovery.
//!   * every scalar VALUE is preserved exactly — numbers round-trip through
//!     serde_json's arbitrary-precision representation, never through f64.
//!     (String escapes may be re-encoded; the decoded value is unchanged.)
//!   * `--fields` is an explicit allowlist with a mandatory omission marker.
//!   * malformed input, binary input, or a view that isn't smaller ⇒ honest
//!     passthrough with a note on stderr.
//!   * table mode refuses rows it cannot render losslessly (nested values,
//!     strings containing newlines) and falls back to minify.

use crate::artifact::{ArtifactMetadata, ArtifactStore};
use crate::config::Config;
use crate::ledger::{Ledger, LedgerEntry, SurfaceDelta, SURFACE_FILES};
use crate::util::{compression_kill_switch, state_dir, stdin_is_tty, unique_id};
use serde_json::Value;
use std::io::Read;

pub async fn run(rest: Vec<String>) -> i32 {
    match run_inner(rest) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("brain compress json: {message}");
            2
        }
    }
}

struct JsonArgs {
    source: Option<String>,
    table: bool,
    fields: Option<Vec<String>>,
}

fn parse_args(rest: Vec<String>) -> Result<JsonArgs, String> {
    let mut source = None;
    let mut table = false;
    let mut fields = None;
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--table" => table = true,
            "--fields" => {
                i += 1;
                let spec = rest.get(i).ok_or("--fields requires a comma-separated list")?;
                fields = Some(spec.split(',').map(|f| f.trim().to_string()).filter(|f| !f.is_empty()).collect());
            }
            "-" => source = None,
            other if other.starts_with("--") => return Err(format!("unknown option {other}")),
            other => {
                if source.is_some() {
                    return Err("multiple input files given".to_string());
                }
                source = Some(other.to_string());
            }
        }
        i += 1;
    }
    Ok(JsonArgs { source, table, fields })
}

fn run_inner(rest: Vec<String>) -> Result<i32, String> {
    let args = parse_args(rest)?;

    let raw: Vec<u8> = match &args.source {
        Some(path) => std::fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?,
        None => {
            if stdin_is_tty() {
                return Err("usage: brain compress json [FILE|-] [--table] [--fields a,b.c] (pipe input or give a file)".to_string());
            }
            let mut buffer = Vec::new();
            std::io::stdin().read_to_end(&mut buffer).map_err(|e| format!("stdin: {e}"))?;
            buffer
        }
    };

    if raw.contains(&0u8) {
        eprintln!("brain compress json: binary input — passing through unchanged");
        passthrough(&raw);
        return Ok(0);
    }

    let state = state_dir()?;
    let enabled = compression_kill_switch(&state).is_none()
        && Config::load(&state).map(|c| c.enabled).unwrap_or(false);
    if !enabled {
        passthrough(&raw);
        return Ok(0);
    }
    let config = Config::load(&state)?;

    // Parse as one JSON document, else as NDJSON. Malformed ⇒ passthrough.
    let parsed = parse_json_or_ndjson(&raw);
    let Some(documents) = parsed else {
        eprintln!("brain compress json: input is not valid JSON/NDJSON — passing through unchanged");
        passthrough(&raw);
        return Ok(0);
    };

    // Persist exact raw bytes before emitting any view.
    let store = ArtifactStore::new(&state, config.artifact_ttl_days, config.artifact_quota_bytes)?;
    let metadata = ArtifactMetadata {
        source_event_id: Some(unique_id("json")),
        model: None,
        surface: Some(SURFACE_FILES.to_string()),
        claim_saved_bytes: 0,
    };
    let handle = match store.put_bytes(&raw, "json_raw", false, &metadata) {
        Ok(manifest) => manifest.id,
        Err(error) => {
            eprintln!("brain compress json: raw persist failed, passing through: {error}");
            passthrough(&raw);
            return Ok(0);
        }
    };

    // Apply the field allowlist (explicit, marked) then choose the projection.
    let (documents, dropped_fields) = match &args.fields {
        Some(fields) => project_fields(documents, fields),
        None => (documents, 0),
    };

    let mut mode = "minify";
    let body = if args.table {
        match table_view(&documents) {
            Some(table) => {
                mode = "table";
                table
            }
            None => {
                eprintln!("brain compress json: not a homogeneous array of scalar records — using minify");
                minify_view(&documents)
            }
        }
    } else {
        minify_view(&documents)
    };

    let fields_note = match (&args.fields, dropped_fields) {
        (Some(fields), n) if n > 0 => {
            format!(" fields={} [other fields omitted: {n} occurrences]", fields.join(","))
        }
        (Some(fields), _) => format!(" fields={}", fields.join(",")),
        _ => String::new(),
    };
    let header = format!(
        "[brain-compress json id={handle} raw_bytes={} view_bytes={} mode={mode}{fields_note} recover: brain compress show {handle} --full]\n",
        raw.len(),
        body.len(),
    );
    let view_len = header.len() + body.len() + 1;

    // Honest passthrough when the view (with framing) is not smaller.
    if view_len >= raw.len() {
        eprintln!("brain compress json: no byte gain — passing through unchanged");
        passthrough(&raw);
        record(&state, &config, &handle, raw.len() as u64, raw.len() as u64, false);
        return Ok(0);
    }

    print!("{header}{body}\n");
    record(&state, &config, &handle, raw.len() as u64, view_len as u64, true);
    Ok(0)
}

fn passthrough(raw: &[u8]) {
    use std::io::Write;
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    let _ = lock.write_all(raw);
    let _ = lock.flush();
}

/// One document, or one per NDJSON line. Returns None when neither parses.
fn parse_json_or_ndjson(raw: &[u8]) -> Option<Vec<Value>> {
    let text = std::str::from_utf8(raw).ok()?;
    if let Ok(value) = serde_json::from_str::<Value>(text) {
        return Some(vec![value]);
    }
    let mut documents = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(line) {
            Ok(value) => documents.push(value),
            Err(_) => return None,
        }
    }
    if documents.is_empty() { None } else { Some(documents) }
}

fn minify_view(documents: &[Value]) -> String {
    documents
        .iter()
        .map(|d| serde_json::to_string(d).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Keep only the allowlisted dot-paths in every object (applied to each array
/// element of top-level arrays, and to top-level objects). Returns the count of
/// dropped key occurrences for the mandatory omission marker.
fn project_fields(documents: Vec<Value>, fields: &[String]) -> (Vec<Value>, usize) {
    let mut dropped = 0usize;
    let projected = documents
        .into_iter()
        .map(|document| match document {
            Value::Array(items) => Value::Array(
                items.into_iter().map(|item| project_one(item, fields, &mut dropped)).collect(),
            ),
            other => project_one(other, fields, &mut dropped),
        })
        .collect();
    (projected, dropped)
}

fn project_one(value: Value, fields: &[String], dropped: &mut usize) -> Value {
    let Value::Object(map) = value else { return value };
    let mut out = serde_json::Map::new();
    for (key, item) in map {
        // A field spec matches the key itself or a dotted prefix (a.b keeps
        // only b under a).
        let sub: Vec<String> = fields
            .iter()
            .filter_map(|f| f.strip_prefix(&format!("{key}.")).map(str::to_string))
            .collect();
        if fields.iter().any(|f| f == &key) {
            out.insert(key, item);
        } else if !sub.is_empty() {
            out.insert(key, project_one(item, &sub, dropped));
        } else {
            *dropped += 1;
        }
    }
    Value::Object(out)
}

/// Markdown table for a homogeneous array of scalar records; None when any row
/// cannot be rendered losslessly (non-object rows, nested values, strings with
/// newlines or pipes needing more than trivial escaping).
fn table_view(documents: &[Value]) -> Option<String> {
    // Accept either one top-level array, or NDJSON objects (one per document).
    let rows: Vec<&Value> = if documents.len() == 1 {
        match &documents[0] {
            Value::Array(items) => items.iter().collect(),
            _ => return None,
        }
    } else {
        documents.iter().collect()
    };
    if rows.is_empty() {
        return None;
    }

    let mut columns: Vec<String> = Vec::new();
    for row in &rows {
        let Value::Object(map) = row else { return None };
        for (key, value) in map {
            match value {
                Value::Array(_) | Value::Object(_) => return None,
                Value::String(text) if text.contains('\n') || text.contains('\r') => return None,
                _ => {}
            }
            if !columns.contains(key) {
                columns.push(key.clone());
            }
        }
    }

    let cell = |value: Option<&Value>| -> String {
        match value {
            None | Some(Value::Null) => String::new(),
            Some(Value::String(text)) => text.replace('|', "\\|"),
            Some(other) => serde_json::to_string(other).unwrap_or_default(),
        }
    };

    let mut out = String::new();
    out.push_str(&format!("| {} |\n", columns.join(" | ")));
    out.push_str(&format!("|{}|\n", columns.iter().map(|_| "---").collect::<Vec<_>>().join("|")));
    for row in rows {
        let Value::Object(map) = row else { return None };
        let cells: Vec<String> = columns.iter().map(|c| cell(map.get(c))).collect();
        out.push_str(&format!("| {} |\n", cells.join(" | ")));
    }
    Some(out)
}

fn record(state: &std::path::Path, config: &Config, handle: &str, observed: u64, delivered: u64, compressed: bool) {
    let Ok(ledger) = Ledger::new(state, config.estimated_bytes_per_token) else { return };
    let mut entry = LedgerEntry::new_consult("json");
    entry.event_kind = "json".to_string();
    entry.success = true;
    entry.raw_response_bytes = observed;
    entry.answer_bytes = delivered;
    entry.artifacts.insert("raw".to_string(), handle.to_string());
    entry.surfaces.push(SurfaceDelta {
        surface: SURFACE_FILES.to_string(),
        observed_bytes: observed,
        delivered_bytes: if compressed { delivered } else { observed },
        recovered_bytes: 0,
        compressed,
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
    fn numbers_round_trip_exactly() {
        // arbitrary_precision: a number f64 cannot represent stays byte-exact.
        let documents = parse_json_or_ndjson(br#"{"n": 1.230000000000000001, "b": 90071992547409923}"#).unwrap();
        let minified = minify_view(&documents);
        assert!(minified.contains("1.230000000000000001"), "{minified}");
        assert!(minified.contains("90071992547409923"), "{minified}");
    }

    #[test]
    fn ndjson_parses_line_wise() {
        let documents = parse_json_or_ndjson(b"{\"a\":1}\n{\"a\":2}\n").unwrap();
        assert_eq!(documents.len(), 2);
        assert!(parse_json_or_ndjson(b"{\"a\":1}\nnot json\n").is_none());
    }

    #[test]
    fn table_requires_homogeneous_scalars() {
        let flat = parse_json_or_ndjson(br#"[{"a":1,"b":"x"},{"a":2,"b":"y|z"}]"#).unwrap();
        let table = table_view(&flat).unwrap();
        assert!(table.contains("| a | b |"));
        assert!(table.contains("y\\|z"));
        let nested = parse_json_or_ndjson(br#"[{"a":{"deep":1}}]"#).unwrap();
        assert!(table_view(&nested).is_none());
        let newline = parse_json_or_ndjson(br#"[{"a":"two\nlines"}]"#).unwrap();
        assert!(table_view(&newline).is_none());
    }

    #[test]
    fn field_projection_marks_drops() {
        let documents = parse_json_or_ndjson(br#"[{"keep":1,"drop":2,"nest":{"in":3,"out":4}}]"#).unwrap();
        let (projected, dropped) = project_fields(documents, &["keep".to_string(), "nest.in".to_string()]);
        let minified = minify_view(&projected);
        assert!(minified.contains("\"keep\":1"));
        assert!(minified.contains("\"in\":3"));
        assert!(!minified.contains("drop"));
        assert!(!minified.contains("out"));
        assert_eq!(dropped, 2);
    }
}
