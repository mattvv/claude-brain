//! `brain-ask` applet — a drop-in async replacement for the Bash `brain-ask`.
//!
//! Contract preserved from the Bash implementation (bridge agents and the
//! statusline depend on it byte-for-byte):
//!   * usage: `brain-ask <model> [--system F] [--max-tokens N] [--effort L]
//!     [--raw] [--stream] [prompt|-]`; prompt from argv, or stdin on `-`/non-tty.
//!   * POSTs `{model,max_tokens,messages:[{role:user,content:PROMPT}]}` (+system,
//!     +output_config.effort, +stream) to `$BRAIN_PROXY_URL/v1/messages` with a
//!     bearer token read from the token file — never placed in argv.
//!   * answer log:    `$BRAIN_STATE_DIR/consult/<model>-<unix>.log`
//!     reasoning log: `<answer-log>.thinking`
//!     `$BRAIN_STATE_DIR/consult/current` — absolute symlink to the answer log.
//!   * streaming text deltas go to stdout AND the answer log, flushed
//!     immediately; reasoning deltas go only to `.thinking`.
//!   * newest 20 logs retained; orphaned `.thinking` sidecars removed.
//!   * non-zero exit with the body on stderr for HTTP errors; `max_tokens`
//!     truncation announced on stderr.
//!
//! Stage 1 additions are observe-only: the raw response, reasoning, prompt, and
//! system context are persisted as artifacts and a ledger entry records real
//! provider usage. Persistence failures never break the consult — observe mode
//! changes nothing for the user.
//!
//! Everything network-facing is async (reqwest); the answer/reasoning logs and
//! stdout are written through tokio and flushed per delta. The artifact store and
//! ledger use short synchronous local-disk writes: they are ordered before any
//! (future) lossy view is emitted, so they are intentionally inline rather than
//! offloaded. On a busy machine they can move to `spawn_blocking`; soak first.

use crate::artifact::{ArtifactMetadata, ArtifactStore, StagedArtifact};
use crate::config::Config;
use crate::http;
use crate::ledger::{
    Ledger, LedgerEntry, SurfaceDelta, Usage, SURFACE_CONSULT_PROMPT, SURFACE_CONSULT_RESPONSE,
    SURFACE_FILES,
};
use crate::util::{
    compression_kill_switch, file_length, read_to_string, state_dir, stdin_is_tty,
    stdin_to_string, token_path, unique_id, unix_seconds, write_stderr_body,
};
use futures_util::StreamExt;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::io::{AsyncWriteExt, Stdout};

const DEFAULT_MAX_TOKENS: u64 = 4096;
const INCOMPLETE_MARKER: &str = "brain-ask: incomplete response (max_tokens)";

enum AskFailure {
    Message(String),
    Reported(i32),
}

pub async fn run(args: Vec<String>) -> i32 {
    match run_inner(args).await {
        Ok(()) => 0,
        Err(AskFailure::Message(message)) => {
            eprintln!("brain-ask: {message}");
            2
        }
        Err(AskFailure::Reported(code)) => code,
    }
}

#[derive(Debug, Clone)]
struct AskArgs {
    model: String,
    system_path: Option<PathBuf>,
    max_tokens: u64,
    effort: Option<String>,
    raw: bool,
    stream: bool,
    /// Response profile: appends a concise-output instruction to the system
    /// prompt so the consultant generates fewer tokens. Lossless (the model just
    /// writes tersely); reduces real vendor output tokens. Marks the call as the
    /// `guarded` experiment arm so ground-truth savings become computable.
    response_profile: Option<String>,
    /// Context files/ranges the bridge wants sent to the consultant. Native code
    /// reads them directly and folds them into the prompt, so the file bytes
    /// never enter the bridge's own (Claude) transcript — the biggest bridge-side
    /// saving. `--context-file PATH` (whole file) or `--context-range PATH@A:B`.
    context: Vec<ContextSpec>,
    prompt: String,
}

#[derive(Debug, Clone)]
struct ContextSpec {
    path: PathBuf,
    range: Option<(usize, usize)>,
}

/// Read the context specs, build an explicit context pack to append to the
/// prompt, and return it with the per-file byte counts for the ledger.
fn build_context_pack(specs: &[ContextSpec]) -> Result<(String, Vec<crate::ledger::ContextFile>), String> {
    if specs.is_empty() {
        return Ok((String::new(), Vec::new()));
    }
    let mut pack = String::from("<BRAIN_CONTEXT_PACK v=1>\n");
    pack.push_str("Files provided for this question. Omissions are marked explicitly.\n\nPATHS\n");
    let mut files = Vec::new();
    let mut bodies = String::new();
    for (i, spec) in specs.iter().enumerate() {
        let label = format!("P{}", i + 1);
        let display = spec.path.display().to_string();
        pack.push_str(&format!("{label} = {display}\n"));

        let text = read_to_string(&spec.path)?;
        let all: Vec<&str> = text.lines().collect();
        let total = all.len();
        let (a, b) = spec.range.unwrap_or((1, total));
        let a = a.max(1);
        let b = b.min(total);
        let mut body = String::new();
        for (idx, line) in all.iter().enumerate() {
            let n = idx + 1;
            if n >= a && n <= b {
                body.push_str(&format!("{n}\t{line}\n"));
            }
        }
        let sent_bytes = body.len() as u64;
        if spec.range.is_some() && (a > 1 || b < total) {
            bodies.push_str(&format!("\n--- {label} @{a}:{b} of {total} lines ---\n"));
        } else {
            bodies.push_str(&format!("\n--- {label} ({total} lines) ---\n"));
        }
        bodies.push_str(&body);
        files.push(crate::ledger::ContextFile { path: display, bytes: sent_bytes });
    }
    pack.push_str("\nFILES\n");
    pack.push_str(&bodies);
    pack.push_str("\n</BRAIN_CONTEXT_PACK>\n");
    Ok((pack, files))
}

/// Concise-output instruction for a response profile, or None if the profile is
/// unknown (unknown profiles are ignored rather than erroring).
fn profile_instruction(profile: &str) -> Option<&'static str> {
    let text = match profile {
        "concise" => "Answer as concisely as correctness allows. Do not restate the question or quote back provided code unchanged; cite file:line instead. Omit preamble and summary.",
        "review" => "Report only findings. For each: `file:line` — the issue in one line — why it is wrong. Do not restate the reviewed code. No preamble, no closing summary.",
        "debug" => "State the root cause, then the fix (as a minimal diff or file:line change). Do not narrate what you considered or ruled out.",
        "implementation" => "Return only the changed code as a unified diff or minimal snippets tagged with file:line. Explain only what is non-obvious, in one line each.",
        "architecture" => "Give the recommendation first in one sentence, then the key tradeoffs as bullets. No essay, no restating the prompt.",
        _ => return None,
    };
    Some(text)
}

async fn run_inner(args: Vec<String>) -> Result<(), AskFailure> {
    let parsed = parse_args(args).map_err(AskFailure::Message)?;
    let state = state_dir().map_err(AskFailure::Message)?;

    // The kill switch is evaluated before config/artifact/ledger access, so a
    // corrupt ledger cannot prevent disabling the observe-only subsystem.
    let kill_reason = compression_kill_switch(&state);
    let config = if kill_reason.is_none() {
        Some(Config::load(&state).map_err(AskFailure::Message)?)
    } else {
        None
    };
    let observing = config.as_ref().map(|config| config.enabled).unwrap_or(false);
    let retain_count = config.as_ref().map(|c| c.consult_logs).unwrap_or(20);

    let mut system_text = match &parsed.system_path {
        Some(path) => Some(read_to_string(path).map_err(AskFailure::Message)?),
        None => None,
    };

    // Response profile (Stage 3): append a concise-output instruction to the
    // system prompt. This reduces real vendor output tokens and marks the call as
    // the `guarded` arm so ground-truth savings become computable (see
    // build_ledger_entry). Unknown profiles are ignored.
    if let Some(instruction) = parsed.response_profile.as_deref().and_then(profile_instruction) {
        let base = system_text.take().unwrap_or_default();
        system_text = Some(if base.is_empty() {
            instruction.to_string()
        } else {
            format!("{base}\n\n{instruction}")
        });
    }

    let token_file = token_path().map_err(AskFailure::Message)?;
    let token = read_to_string(&token_file)
        .map_err(AskFailure::Message)?
        .trim()
        .to_string();
    if token.is_empty() {
        return Err(AskFailure::Message(format!(
            "token file {} is empty",
            token_file.display()
        )));
    }
    if token.contains(['\r', '\n']) {
        return Err(AskFailure::Message(
            "bearer token contains a newline".to_string(),
        ));
    }

    let proxy_base =
        env::var("BRAIN_PROXY_URL").unwrap_or_else(|_| "http://127.0.0.1:8317".to_string());
    let endpoint = http::join_url(&proxy_base, "/v1/messages");

    let mut logs = ConsultLogs::create(&state, &parsed.model)
        .await
        .map_err(AskFailure::Message)?;
    let event_id = unique_id("consult");

    let mut observer = if observing {
        let config = config.as_ref().expect("observing requires config");
        let store = ArtifactStore::new(&state, config.artifact_ttl_days, config.artifact_quota_bytes)
            .map_err(AskFailure::Message)?;
        let ledger = Ledger::new(&state, config.estimated_bytes_per_token)
            .map_err(AskFailure::Message)?;
        Some(Observer {
            store,
            ledger,
            event_id: event_id.clone(),
            model: parsed.model.clone(),
            estimated_bytes_per_token: config.estimated_bytes_per_token,
            artifacts: BTreeMap::new(),
            context_files: Vec::new(),
        })
    } else {
        None
    };

    // Stage 4A: read any --context-file/--context-range specs natively and fold
    // them into the prompt. The bridge passes paths, so the file bytes never
    // enter its own transcript.
    let (context_pack, context_files) =
        build_context_pack(&parsed.context).map_err(AskFailure::Message)?;
    let full_prompt = if context_pack.is_empty() {
        parsed.prompt.clone()
    } else {
        format!("{}\n\n{}", parsed.prompt, context_pack)
    };

    let context_bytes = system_text.as_ref().map(|s| s.len() as u64).unwrap_or(0)
        + context_pack.len() as u64;

    if let Some(observer) = observer.as_mut() {
        observer.persist_bytes("prompt", parsed.prompt.as_bytes(), "prompt", SURFACE_CONSULT_PROMPT);
        if let Some(system) = &system_text {
            observer.persist_bytes("system", system.as_bytes(), "system_context", SURFACE_FILES);
        }
        if !context_pack.is_empty() {
            observer.persist_bytes("context_pack", context_pack.as_bytes(), "context_pack", SURFACE_FILES);
        }
        observer.context_files = context_files.clone();
    }

    let mut request = json!({
        "model": parsed.model,
        "max_tokens": parsed.max_tokens,
        "messages": [{ "role": "user", "content": full_prompt }],
    });
    if let Some(system) = &system_text {
        request["system"] = Value::String(system.clone());
    }
    if let Some(effort) = &parsed.effort {
        request["output_config"] = json!({ "effort": effort });
    }
    if parsed.stream {
        request["stream"] = Value::Bool(true);
    }

    let request_body = serde_json::to_vec(&request)
        .map_err(|error| AskFailure::Message(format!("cannot encode request: {error}")))?;

    let timeout = env::var("BRAIN_PROXY_TIMEOUT_SECS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or_else(|| Duration::from_secs(3600));

    let headers = vec![
        ("Authorization".to_string(), format!("Bearer {token}")),
        ("anthropic-version".to_string(), "2023-06-01".to_string()),
    ];

    if parsed.stream {
        eprintln!(
            "brain-ask: streaming — watch live: tail -f {}",
            logs.answer_path.display()
        );
    }

    let started = Instant::now();
    let response = match http::post_json(&endpoint, &headers, request_body.clone(), timeout).await {
        Ok(response) => response,
        Err(error) => {
            let latency_ms = elapsed_millis(started);
            if let Some(observer) = observer.as_mut() {
                let entry = build_ledger_entry(
                    &parsed, context_bytes, &request_body, 0, 0, 0, None, None, None,
                    Usage::default(), false, None, latency_ms, observer,
                );
                observer.append(entry);
            }
            let _ = retain_logs(&state, retain_count);
            return Err(AskFailure::Message(error));
        }
    };

    let status = response.status().as_u16();

    if parsed.stream {
        handle_streaming(
            parsed, context_bytes, &request_body, response, status, &mut logs, observer.as_mut(),
            &token, started, &state, retain_count,
        )
        .await
    } else {
        handle_non_streaming(
            parsed, context_bytes, &request_body, response, status, &mut logs, observer.as_mut(),
            &token, started, &state, retain_count,
        )
        .await
    }
}

#[allow(clippy::too_many_arguments)]
async fn handle_non_streaming(
    parsed: AskArgs,
    context_bytes: u64,
    request_body: &[u8],
    response: reqwest::Response,
    status: u16,
    logs: &mut ConsultLogs,
    mut observer: Option<&mut Observer>,
    token: &str,
    started: Instant,
    state: &Path,
    retain_count: usize,
) -> Result<(), AskFailure> {
    let body = response
        .bytes()
        .await
        .map_err(|error| AskFailure::Message(format!("cannot read proxy response: {error}")))?
        .to_vec();
    let latency_ms = elapsed_millis(started);

    if let Some(observer) = observer.as_deref_mut() {
        observer.persist_bytes("raw_response", &body, "raw_response_json", SURFACE_CONSULT_RESPONSE);
    }

    if !(200..300).contains(&status) {
        if let Some(observer) = observer {
            let entry = build_ledger_entry(
                &parsed, context_bytes, request_body, body.len() as u64, 0, 0, None, None, None,
                Usage::default(), false, Some(status), latency_ms, observer,
            );
            observer.append(entry);
        }
        let _ = retain_logs(state, retain_count);
        write_stderr_body(&body, token);
        return Err(AskFailure::Reported(1));
    }

    let value: Value = serde_json::from_slice(&body)
        .map_err(|error| AskFailure::Message(format!("proxy returned invalid JSON: {error}")))?;

    let provider_request_id = value.get("id").and_then(Value::as_str).map(str::to_string);
    let provider_model = value.get("model").and_then(Value::as_str).map(str::to_string);
    let stop_reason = value.get("stop_reason").and_then(Value::as_str).map(str::to_string);
    let usage = parse_usage(value.get("usage"));

    let mut answer = Vec::new();
    let mut thinking = Vec::new();
    if let Some(content) = value.get("content").and_then(Value::as_array) {
        for block in content {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => {
                    if let Some(text) = block.get("text").and_then(Value::as_str) {
                        answer.extend_from_slice(text.as_bytes());
                    }
                }
                Some("thinking") => {
                    if let Some(text) = block.get("thinking").and_then(Value::as_str) {
                        thinking.extend_from_slice(text.as_bytes());
                    }
                }
                _ => {}
            }
        }
    }

    logs.append_answer(&answer).await.map_err(AskFailure::Message)?;
    logs.append_thinking(&thinking).await.map_err(AskFailure::Message)?;

    if let Some(observer) = observer {
        observer.persist_file("answer", &logs.answer_path, "answer_log", SURFACE_CONSULT_RESPONSE);
        if !thinking.is_empty() {
            observer.persist_file("thinking", &logs.thinking_path, "thinking", SURFACE_CONSULT_RESPONSE);
        }
        let entry = build_ledger_entry(
            &parsed, context_bytes, request_body, body.len() as u64, thinking.len() as u64,
            answer.len() as u64, provider_request_id, provider_model, stop_reason.clone(),
            usage.clone(), true, Some(status), latency_ms, observer,
        );
        observer.append(entry);
    }

    write_capabilities(
        state, false, usage.provider_fields_present(),
        usage_has_cache_fields(value.get("usage")),
        usage_has_reasoning_field(value.get("usage")),
    );

    let mut stdout = tokio::io::stdout();
    let to_write: &[u8] = if parsed.raw { &body } else { &answer };
    stdout
        .write_all(to_write)
        .await
        .map_err(|error| AskFailure::Message(format!("cannot write stdout: {error}")))?;
    stdout
        .flush()
        .await
        .map_err(|error| AskFailure::Message(format!("cannot write stdout: {error}")))?;

    if stop_reason.as_deref() == Some("max_tokens") {
        eprintln!("{INCOMPLETE_MARKER}");
    }

    retain_logs(state, retain_count).map_err(AskFailure::Message)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn handle_streaming(
    parsed: AskArgs,
    context_bytes: u64,
    request_body: &[u8],
    response: reqwest::Response,
    status: u16,
    logs: &mut ConsultLogs,
    observer: Option<&mut Observer>,
    token: &str,
    started: Instant,
    state: &Path,
    retain_count: usize,
) -> Result<(), AskFailure> {
    if !(200..300).contains(&status) {
        let body = response
            .bytes()
            .await
            .map_err(|error| AskFailure::Message(format!("cannot read proxy error body: {error}")))?
            .to_vec();
        let latency_ms = elapsed_millis(started);
        if let Some(observer) = observer {
            observer.persist_bytes("raw_response", &body, "raw_response_error", SURFACE_CONSULT_RESPONSE);
            let entry = build_ledger_entry(
                &parsed, context_bytes, request_body, body.len() as u64, 0, 0, None, None, None,
                Usage::default(), false, Some(status), latency_ms, observer,
            );
            observer.append(entry);
        }
        let _ = retain_logs(state, retain_count);
        write_stderr_body(&body, token);
        return Err(AskFailure::Reported(1));
    }

    // Spool the raw SSE stream to its own artifact so the exact bytes are durable
    // before any delta is surfaced. If spooling fails we warn once and continue —
    // observe mode must never break the user's consult.
    let mut staged: Option<StagedArtifact> = match observer.as_deref() {
        Some(observer) => match observer.store.begin_stream(&observer.event_id, "raw_response_sse") {
            Ok(staged) => Some(staged),
            Err(error) => {
                eprintln!("brain-ask: raw-response spooling disabled: {error}");
                None
            }
        },
        None => None,
    };

    let mut accumulator = StreamAccumulator::default();
    let mut raw_bytes: u64 = 0;
    let mut line = Vec::new();
    let mut event = Vec::new();
    let mut stream = response.bytes_stream();

    while let Some(chunk) = stream.next().await {
        let chunk = chunk
            .map_err(|error| AskFailure::Message(format!("cannot read SSE stream: {error}")))?;
        for &byte in chunk.iter() {
            line.push(byte);
            if byte != b'\n' {
                continue;
            }
            raw_bytes = raw_bytes.saturating_add(line.len() as u64);
            spool_line(&mut staged, &line, raw_bytes);

            let is_blank = line == b"\n" || line == b"\r\n";
            if is_blank {
                process_sse_event(&event, &mut accumulator, logs)
                    .await
                    .map_err(AskFailure::Message)?;
                event.clear();
            } else {
                event.extend_from_slice(&line);
            }
            line.clear();
        }
    }
    // A final event not terminated by a blank line.
    if !line.is_empty() {
        raw_bytes = raw_bytes.saturating_add(line.len() as u64);
        spool_line(&mut staged, &line, raw_bytes);
        event.extend_from_slice(&line);
    }
    if !event.is_empty() {
        process_sse_event(&event, &mut accumulator, logs)
            .await
            .map_err(AskFailure::Message)?;
    }

    logs.flush_all().await.map_err(AskFailure::Message)?;
    let latency_ms = elapsed_millis(started);

    let answer_bytes = file_length(&logs.answer_path).unwrap_or(0);
    let thinking_bytes = file_length(&logs.thinking_path).unwrap_or(0);

    if let Some(observer) = observer {
        if let Some(staged) = staged.take() {
            let metadata = observer.metadata(SURFACE_CONSULT_RESPONSE);
            match observer
                .store
                .finalize_stream(staged, "raw_response_sse", true, &metadata)
            {
                Ok(manifest) => {
                    observer.artifacts.insert("raw_response".to_string(), manifest.id);
                }
                Err(error) => eprintln!("brain-ask: raw-response finalize failed: {error}"),
            }
        }
        observer.persist_file("answer", &logs.answer_path, "answer_log", SURFACE_CONSULT_RESPONSE);
        if thinking_bytes > 0 {
            observer.persist_file("thinking", &logs.thinking_path, "thinking", SURFACE_CONSULT_RESPONSE);
        }
        let entry = build_ledger_entry(
            &parsed, context_bytes, request_body, raw_bytes, thinking_bytes, answer_bytes,
            accumulator.provider_request_id.clone(), accumulator.provider_model.clone(),
            accumulator.stop_reason.clone(), accumulator.usage.clone(), true, Some(status),
            latency_ms, observer,
        );
        observer.append(entry);
    }

    write_capabilities(
        state, true, accumulator.usage.provider_fields_present(),
        accumulator.cache_fields_present, accumulator.reasoning_usage_field_present,
    );

    // Match the Bash brain-ask: a trailing newline after the streamed answer.
    let mut stdout = tokio::io::stdout();
    let _ = stdout.write_all(b"\n").await;
    let _ = stdout.flush().await;

    if accumulator.stop_reason.as_deref() == Some("max_tokens") {
        eprintln!("{INCOMPLETE_MARKER}");
    }

    retain_logs(state, retain_count).map_err(AskFailure::Message)?;
    Ok(())
}

fn spool_line(staged: &mut Option<StagedArtifact>, line: &[u8], raw_bytes: u64) {
    // Persist, then assert durability before the caller acts on the parsed delta
    // — the fidelity invariant, active even though Stage 1 emits nothing lossy. A
    // spool failure disables further spooling but never aborts the consult.
    let failed = match staged.as_mut() {
        Some(active) => {
            active.append_persisted(line).is_err()
                || active.assert_persisted_at_least(raw_bytes).is_err()
        }
        None => false,
    };
    if failed {
        eprintln!("brain-ask: raw-response spooling stopped (write failed)");
        *staged = None;
    }
}

// --- SSE parsing ---------------------------------------------------------------

#[derive(Default)]
struct StreamAccumulator {
    usage: Usage,
    stop_reason: Option<String>,
    provider_request_id: Option<String>,
    provider_model: Option<String>,
    cache_fields_present: bool,
    reasoning_usage_field_present: bool,
}

async fn process_sse_event(
    event: &[u8],
    accumulator: &mut StreamAccumulator,
    logs: &mut ConsultLogs,
) -> Result<(), String> {
    // An SSE event is a run of lines; we only care about `data:` payloads, each a
    // JSON object with a `.type` we can dispatch on.
    for raw_line in event.split(|&b| b == b'\n') {
        let text = String::from_utf8_lossy(raw_line);
        let trimmed = text.trim_end_matches('\r');
        let Some(payload) = trimmed.strip_prefix("data:") else {
            continue;
        };
        let payload = payload.trim_start();
        if payload.is_empty() || payload == "[DONE]" {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(payload) else {
            continue;
        };
        dispatch_event(&value, accumulator, logs).await?;
    }
    Ok(())
}

async fn dispatch_event(
    value: &Value,
    accumulator: &mut StreamAccumulator,
    logs: &mut ConsultLogs,
) -> Result<(), String> {
    match value.get("type").and_then(Value::as_str) {
        Some("content_block_delta") => {
            let delta = value.get("delta");
            match delta.and_then(|d| d.get("type")).and_then(Value::as_str) {
                Some("text_delta") => {
                    if let Some(text) = delta.and_then(|d| d.get("text")).and_then(Value::as_str) {
                        logs.write_text_delta(text).await?;
                    }
                }
                Some("thinking_delta") => {
                    if let Some(text) = delta.and_then(|d| d.get("thinking")).and_then(Value::as_str)
                    {
                        logs.write_thinking_delta(text).await?;
                    }
                }
                _ => {}
            }
        }
        Some("message_start") => {
            if let Some(message) = value.get("message") {
                if let Some(id) = message.get("id").and_then(Value::as_str) {
                    accumulator.provider_request_id = Some(id.to_string());
                }
                if let Some(model) = message.get("model").and_then(Value::as_str) {
                    accumulator.provider_model = Some(model.to_string());
                }
                merge_usage(message.get("usage"), accumulator);
            }
        }
        Some("message_delta") => {
            if let Some(stop) = value
                .get("delta")
                .and_then(|d| d.get("stop_reason"))
                .and_then(Value::as_str)
            {
                accumulator.stop_reason = Some(stop.to_string());
            }
            merge_usage(value.get("usage"), accumulator);
        }
        Some("error") => {
            let message = value
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(Value::as_str)
                .unwrap_or("unknown stream error");
            logs.write_text_delta(&format!("\n[stream error] {message}\n")).await?;
        }
        _ => {}
    }
    Ok(())
}

fn merge_usage(usage: Option<&Value>, accumulator: &mut StreamAccumulator) {
    let Some(usage) = usage else { return };
    let parsed = parse_usage(Some(usage));
    if parsed.input_tokens.is_some() {
        accumulator.usage.input_tokens = parsed.input_tokens;
    }
    if parsed.output_tokens.is_some() {
        accumulator.usage.output_tokens = parsed.output_tokens;
    }
    if parsed.cache_creation_input_tokens.is_some() {
        accumulator.usage.cache_creation_input_tokens = parsed.cache_creation_input_tokens;
    }
    if parsed.cache_read_input_tokens.is_some() {
        accumulator.usage.cache_read_input_tokens = parsed.cache_read_input_tokens;
    }
    if parsed.reasoning_tokens.is_some() {
        accumulator.usage.reasoning_tokens = parsed.reasoning_tokens;
    }
    if usage_has_cache_fields(Some(usage)) {
        accumulator.cache_fields_present = true;
    }
    if usage_has_reasoning_field(Some(usage)) {
        accumulator.reasoning_usage_field_present = true;
    }
}

fn parse_usage(value: Option<&Value>) -> Usage {
    let Some(value) = value else {
        return Usage::default();
    };
    let field = |name: &str| value.get(name).and_then(Value::as_u64);
    Usage {
        input_tokens: field("input_tokens"),
        output_tokens: field("output_tokens"),
        cache_creation_input_tokens: field("cache_creation_input_tokens"),
        cache_read_input_tokens: field("cache_read_input_tokens"),
        reasoning_tokens: field("reasoning_tokens")
            .or_else(|| value.get("reasoning_output_tokens").and_then(Value::as_u64)),
    }
}

fn usage_has_cache_fields(value: Option<&Value>) -> bool {
    value
        .map(|v| v.get("cache_creation_input_tokens").is_some() || v.get("cache_read_input_tokens").is_some())
        .unwrap_or(false)
}

fn usage_has_reasoning_field(value: Option<&Value>) -> bool {
    value
        .map(|v| v.get("reasoning_tokens").is_some() || v.get("reasoning_output_tokens").is_some())
        .unwrap_or(false)
}

// --- Consultation logs (async) -------------------------------------------------

struct ConsultLogs {
    answer_path: PathBuf,
    thinking_path: PathBuf,
    answer: tokio::fs::File,
    thinking: tokio::fs::File,
    stdout: Stdout,
}

impl ConsultLogs {
    async fn create(state: &Path, model: &str) -> Result<Self, String> {
        let dir = state.join("consult");
        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|error| format!("cannot create {}: {error}", dir.display()))?;

        let stamp = unix_seconds();
        let safe_model: String = model
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '.' || c == '_' { c } else { '_' })
            .collect();
        let answer_path = dir.join(format!("{safe_model}-{stamp}.log"));
        let thinking_path = dir.join(format!("{}.thinking", answer_path.display()));

        let answer = tokio::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&answer_path)
            .await
            .map_err(|error| format!("cannot open {}: {error}", answer_path.display()))?;
        let thinking = tokio::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&thinking_path)
            .await
            .map_err(|error| format!("cannot open {}: {error}", thinking_path.display()))?;

        // `current` is an absolute symlink to the answer log (statusline + tail -f).
        let current = dir.join("current");
        let absolute = if answer_path.is_absolute() {
            answer_path.clone()
        } else {
            std::env::current_dir()
                .map_err(|error| format!("cannot resolve cwd: {error}"))?
                .join(&answer_path)
        };
        let _ = std::fs::remove_file(&current);
        std::os::unix::fs::symlink(&absolute, &current)
            .map_err(|error| format!("cannot link {}: {error}", current.display()))?;

        Ok(Self { answer_path, thinking_path, answer, thinking, stdout: tokio::io::stdout() })
    }

    async fn write_text_delta(&mut self, text: &str) -> Result<(), String> {
        let bytes = text.as_bytes();
        self.stdout.write_all(bytes).await.map_err(|e| format!("stdout: {e}"))?;
        self.stdout.flush().await.map_err(|e| format!("stdout: {e}"))?;
        self.answer.write_all(bytes).await.map_err(|e| format!("answer log: {e}"))?;
        self.answer.flush().await.map_err(|e| format!("answer log: {e}"))?;
        Ok(())
    }

    async fn write_thinking_delta(&mut self, text: &str) -> Result<(), String> {
        self.thinking.write_all(text.as_bytes()).await.map_err(|e| format!("thinking log: {e}"))?;
        self.thinking.flush().await.map_err(|e| format!("thinking log: {e}"))?;
        Ok(())
    }

    async fn append_answer(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.answer.write_all(bytes).await.map_err(|e| format!("answer log: {e}"))?;
        self.answer.flush().await.map_err(|e| format!("answer log: {e}"))
    }

    async fn append_thinking(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.thinking.write_all(bytes).await.map_err(|e| format!("thinking log: {e}"))?;
        self.thinking.flush().await.map_err(|e| format!("thinking log: {e}"))
    }

    async fn flush_all(&mut self) -> Result<(), String> {
        self.answer.flush().await.map_err(|e| format!("answer log: {e}"))?;
        self.thinking.flush().await.map_err(|e| format!("thinking log: {e}"))?;
        self.stdout.flush().await.map_err(|e| format!("stdout: {e}"))
    }
}

// --- Observer (artifacts + ledger) --------------------------------------------

struct Observer {
    store: ArtifactStore,
    ledger: Ledger,
    event_id: String,
    model: String,
    estimated_bytes_per_token: f64,
    artifacts: BTreeMap<String, String>,
    context_files: Vec<crate::ledger::ContextFile>,
}

impl Observer {
    fn metadata(&self, surface: &str) -> ArtifactMetadata {
        ArtifactMetadata {
            source_event_id: Some(self.event_id.clone()),
            model: Some(self.model.clone()),
            surface: Some(surface.to_string()),
            claim_saved_bytes: 0,
        }
    }

    fn persist_bytes(&mut self, key: &str, bytes: &[u8], kind: &str, surface: &str) {
        let metadata = self.metadata(surface);
        match self.store.put_bytes(bytes, kind, true, &metadata) {
            Ok(manifest) => {
                self.artifacts.insert(key.to_string(), manifest.id);
            }
            Err(error) => eprintln!("brain-ask: could not persist {key} artifact: {error}"),
        }
    }

    fn persist_file(&mut self, key: &str, path: &Path, kind: &str, surface: &str) {
        let metadata = self.metadata(surface);
        match self.store.put_file(path, kind, true, &metadata) {
            Ok(manifest) => {
                self.artifacts.insert(key.to_string(), manifest.id);
            }
            Err(error) => eprintln!("brain-ask: could not persist {key} artifact: {error}"),
        }
    }

    fn append(&self, entry: LedgerEntry) {
        if let Err(error) = self.ledger.append(&entry) {
            eprintln!("brain-ask: ledger append failed (non-fatal): {error}");
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn build_ledger_entry(
    parsed: &AskArgs,
    context_bytes: u64,
    request_body: &[u8],
    raw_response_bytes: u64,
    thinking_bytes: u64,
    answer_bytes: u64,
    provider_request_id: Option<String>,
    provider_model: Option<String>,
    stop_reason: Option<String>,
    usage: Usage,
    success: bool,
    http_status: Option<u16>,
    latency_ms: u64,
    observer: &Observer,
) -> LedgerEntry {
    let mut entry = LedgerEntry::new_consult(&parsed.model);
    entry.event_id = observer.event_id.clone();
    // A response profile places this call in the `guarded` experiment arm; its
    // provider output tokens become comparable against `control` calls.
    if parsed.response_profile.as_deref().and_then(profile_instruction).is_some() {
        entry.arm = "guarded".to_string();
    }
    entry.provider_model = provider_model;
    entry.provider_request_id = provider_request_id;
    entry.stop_reason = stop_reason;
    entry.success = success;
    entry.http_status = http_status;
    entry.latency_ms = latency_ms;
    entry.prompt_bytes = parsed.prompt.len() as u64;
    entry.context_bytes = context_bytes;
    entry.request_body_bytes = request_body.len() as u64;
    entry.raw_response_bytes = raw_response_bytes;
    entry.thinking_bytes = thinking_bytes;
    entry.answer_bytes = answer_bytes;
    entry.artifacts = observer.artifacts.clone();
    entry.context_files = observer.context_files.clone();

    let input_tokens = usage.input_tokens.unwrap_or(0);
    let output_tokens = usage.output_tokens.unwrap_or(0);
    // Rough estimate of the fixed proxy/system prefix: provider input tokens
    // minus an estimate of the prompt+context body. Labelled an estimate
    // everywhere it surfaces. Never negative.
    let body_token_estimate =
        ((entry.prompt_bytes + entry.context_bytes) as f64 / observer.estimated_bytes_per_token) as u64;
    let proxy_prefix_estimate = input_tokens.saturating_sub(body_token_estimate);
    entry.proxy_prefix_tokens_estimate = Some(proxy_prefix_estimate);
    entry.usage = usage;

    let provider_calls = if success { 1 } else { 0 };

    // Prompt-side baseline surface: bytes we sent. Uncompressed, so observed ==
    // delivered (the ledger's honesty invariant).
    let prompt_observed = entry.prompt_bytes + entry.context_bytes;
    entry.surfaces.push(SurfaceDelta {
        surface: SURFACE_CONSULT_PROMPT.to_string(),
        observed_bytes: prompt_observed,
        delivered_bytes: prompt_observed,
        recovered_bytes: 0,
        compressed: false,
        recovery: false,
        calls: 1,
        provider_calls: 0,
        provider_input_tokens: 0,
        provider_output_tokens: 0,
        proxy_prefix_tokens_estimate: 0,
    });

    // Response-side baseline surface: raw bytes received. Carries the provider
    // call accounting so per-cell totals are not double-counted.
    entry.surfaces.push(SurfaceDelta {
        surface: SURFACE_CONSULT_RESPONSE.to_string(),
        observed_bytes: raw_response_bytes,
        delivered_bytes: raw_response_bytes,
        recovered_bytes: 0,
        compressed: false,
        recovery: false,
        calls: 1,
        provider_calls,
        provider_input_tokens: input_tokens,
        provider_output_tokens: output_tokens,
        proxy_prefix_tokens_estimate: proxy_prefix_estimate,
    });

    entry
}

// --- capabilities + retention + misc ------------------------------------------

fn write_capabilities(
    state: &Path,
    streaming: bool,
    usage_present: bool,
    cache_present: bool,
    reasoning_present: bool,
) {
    let dir = state.join("compress");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let value = json!({
        "observed_at": unix_seconds(),
        "proxy_reachable": true,
        "streaming": streaming,
        "usage_fields_present": usage_present,
        "cache_fields_present": cache_present,
        "reasoning_token_field_present": reasoning_present,
    });
    if let Ok(bytes) = serde_json::to_vec_pretty(&value) {
        let _ = crate::util::atomic_write(&dir.join("capabilities.json"), &bytes);
    }
}

fn retain_logs(state: &Path, keep: usize) -> Result<(), String> {
    let dir = state.join("consult");
    let mut logs: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(_) => return Ok(()),
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(name) => name,
            None => continue,
        };
        if name.ends_with(".log") {
            let mtime = entry
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            logs.push((mtime, path));
        }
    }
    logs.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, path) in logs.into_iter().skip(keep) {
        let _ = std::fs::remove_file(&path);
    }
    // Remove orphaned `.thinking` sidecars whose answer log is gone.
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let name = match path.file_name().and_then(|n| n.to_str()) {
                Some(name) => name,
                None => continue,
            };
            if let Some(base) = name.strip_suffix(".thinking") {
                if !dir.join(base).exists() {
                    let _ = std::fs::remove_file(&path);
                }
            }
        }
    }
    Ok(())
}

fn elapsed_millis(started: Instant) -> u64 {
    started.elapsed().as_millis() as u64
}

fn usage() -> String {
    "usage: brain-ask <model> [--system FILE] [--max-tokens N] [--effort LEVEL] [--raw] [--stream] [--response PROFILE] [--context-file PATH] [--context-range PATH@A:B] [prompt|-]"
        .to_string()
}

fn parse_args(args: Vec<String>) -> Result<AskArgs, String> {
    if args.is_empty() {
        return Err(usage());
    }

    let model = args[0].clone();
    if model.is_empty() || model.starts_with('-') {
        return Err(usage());
    }

    let mut system_path = None;
    let mut max_tokens = DEFAULT_MAX_TOKENS;
    let mut effort = None;
    let mut raw = false;
    let mut stream = false;
    let mut response_profile = None;
    let mut context: Vec<ContextSpec> = Vec::new();
    let mut prompt: Option<String> = None;
    let mut read_stdin = false;

    let mut index = 1;
    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--system" => {
                index += 1;
                let value = args.get(index).ok_or_else(|| "--system requires a file".to_string())?;
                system_path = Some(PathBuf::from(value));
            }
            "--max-tokens" => {
                index += 1;
                let value = args.get(index).ok_or_else(|| "--max-tokens requires a number".to_string())?;
                max_tokens = value
                    .parse::<u64>()
                    .map_err(|_| format!("invalid --max-tokens: {value}"))?;
                if max_tokens == 0 {
                    return Err("--max-tokens must be greater than zero".to_string());
                }
            }
            "--effort" => {
                index += 1;
                let value = args.get(index).ok_or_else(|| "--effort requires a level".to_string())?;
                effort = Some(value.clone());
            }
            "--raw" => raw = true,
            "--stream" => stream = true,
            "--response" => {
                index += 1;
                let value = args.get(index).ok_or_else(|| "--response requires a profile".to_string())?;
                response_profile = Some(value.clone());
            }
            "--context-file" => {
                index += 1;
                let value = args.get(index).ok_or_else(|| "--context-file requires a path".to_string())?;
                context.push(ContextSpec { path: PathBuf::from(value), range: None });
            }
            "--context-range" => {
                index += 1;
                let value = args.get(index).ok_or_else(|| "--context-range requires PATH@A:B".to_string())?;
                let (path, span) = value
                    .rsplit_once('@')
                    .ok_or_else(|| format!("invalid --context-range (expected PATH@A:B): {value}"))?;
                let (a, b) = span
                    .split_once(':')
                    .ok_or_else(|| format!("invalid --context-range span (expected A:B): {span}"))?;
                let a: usize = a.parse().map_err(|_| format!("invalid range start: {a}"))?;
                let b: usize = b.parse().map_err(|_| format!("invalid range end: {b}"))?;
                if a == 0 || b < a {
                    return Err(format!("invalid --context-range span: {span}"));
                }
                context.push(ContextSpec { path: PathBuf::from(path), range: Some((a, b)) });
            }
            "-" => read_stdin = true,
            other if other.starts_with("--") => {
                return Err(format!("unknown option: {other}"));
            }
            other => {
                if prompt.is_some() {
                    return Err("multiple prompts given".to_string());
                }
                prompt = Some(other.to_string());
            }
        }
        index += 1;
    }

    if raw && stream {
        return Err("--raw and --stream cannot be combined".to_string());
    }

    let prompt = if read_stdin || prompt.is_none() {
        if prompt.is_some() {
            return Err("give a prompt argument or '-', not both".to_string());
        }
        if !read_stdin && stdin_is_tty() {
            return Err("no prompt given (pass as argument, or pipe with '-')".to_string());
        }
        stdin_to_string()?
    } else {
        prompt.unwrap()
    };

    if prompt.trim().is_empty() {
        return Err("empty prompt".to_string());
    }

    Ok(AskArgs { model, system_path, max_tokens, effort, raw, stream, response_profile, context, prompt })
}

#[cfg(test)]
mod tests {
    use super::profile_instruction;

    #[test]
    fn known_profiles_have_instructions() {
        for p in ["concise", "review", "debug", "implementation", "architecture"] {
            assert!(profile_instruction(p).is_some(), "profile {p} missing");
        }
    }

    #[test]
    fn unknown_profile_is_ignored() {
        assert!(profile_instruction("bogus").is_none());
        assert!(profile_instruction("").is_none());
    }
}
