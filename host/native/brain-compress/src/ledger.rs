use crate::util::{atomic_write, sync_dir, unique_id, unix_seconds, FileLock};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

pub const SURFACE_CONSULT_PROMPT: &str = "consult-prompt";
pub const SURFACE_CONSULT_RESPONSE: &str = "consult-response";
pub const SURFACE_SHELL: &str = "shell";
pub const SURFACE_FILES: &str = "files";

#[derive(Clone, Debug, Default)]
pub struct Usage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub cache_creation_input_tokens: Option<u64>,
    pub cache_read_input_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
}

impl Usage {
    pub fn provider_fields_present(&self) -> bool {
        self.input_tokens.is_some() || self.output_tokens.is_some()
    }

    fn to_value(&self) -> Value {
        json!({
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cache_creation_input_tokens": self.cache_creation_input_tokens,
            "cache_read_input_tokens": self.cache_read_input_tokens,
            "reasoning_tokens": self.reasoning_tokens,
        })
    }
}

#[derive(Clone, Debug)]
pub struct ContextFile {
    pub path: String,
    pub bytes: u64,
}

#[derive(Clone, Debug)]
pub struct SurfaceDelta {
    pub surface: String,
    pub observed_bytes: u64,
    pub delivered_bytes: u64,
    pub recovered_bytes: u64,
    pub compressed: bool,
    pub recovery: bool,
    pub calls: u64,
    pub provider_calls: u64,
    pub provider_input_tokens: u64,
    pub provider_output_tokens: u64,
    pub proxy_prefix_tokens_estimate: u64,
}

impl SurfaceDelta {
    fn to_value(&self) -> Value {
        json!({
            "surface": self.surface,
            "observed_bytes": self.observed_bytes,
            "delivered_bytes": self.delivered_bytes,
            "recovered_bytes": self.recovered_bytes,
            "compressed": self.compressed,
            "recovery": self.recovery,
            "calls": self.calls,
            "provider_calls": self.provider_calls,
            "provider_input_tokens": self.provider_input_tokens,
            "provider_output_tokens": self.provider_output_tokens,
            "proxy_prefix_tokens_estimate": self.proxy_prefix_tokens_estimate,
        })
    }
}

#[derive(Clone, Debug)]
pub struct LedgerEntry {
    pub event_id: String,
    pub timestamp: u64,
    pub event_kind: String,
    pub arm: String,
    pub model: String,
    pub provider_model: Option<String>,
    pub provider_request_id: Option<String>,
    pub stop_reason: Option<String>,
    pub success: bool,
    pub http_status: Option<u16>,
    pub latency_ms: u64,
    pub usage: Usage,
    pub prompt_bytes: u64,
    pub context_bytes: u64,
    pub request_body_bytes: u64,
    pub raw_response_bytes: u64,
    pub thinking_bytes: u64,
    pub answer_bytes: u64,
    pub proxy_prefix_tokens_estimate: Option<u64>,
    pub context_files: Vec<ContextFile>,
    pub artifacts: BTreeMap<String, String>,
    pub surfaces: Vec<SurfaceDelta>,
}

impl LedgerEntry {
    pub fn new_consult(model: &str) -> Self {
        Self {
            event_id: unique_id("evt"),
            timestamp: unix_seconds(),
            event_kind: "consult".to_string(),
            arm: "control".to_string(),
            model: model.to_string(),
            provider_model: None,
            provider_request_id: None,
            stop_reason: None,
            success: false,
            http_status: None,
            latency_ms: 0,
            usage: Usage::default(),
            prompt_bytes: 0,
            context_bytes: 0,
            request_body_bytes: 0,
            raw_response_bytes: 0,
            thinking_bytes: 0,
            answer_bytes: 0,
            proxy_prefix_tokens_estimate: None,
            context_files: Vec::new(),
            artifacts: BTreeMap::new(),
            surfaces: Vec::new(),
        }
    }

    pub fn new_recovery(
        model: &str,
        surface: &str,
        recovered_bytes: u64,
        artifact_id: &str,
    ) -> Self {
        let mut artifacts = BTreeMap::new();
        artifacts.insert("recovered".to_string(), artifact_id.to_string());

        Self {
            event_id: unique_id("recovery"),
            timestamp: unix_seconds(),
            event_kind: "recovery".to_string(),
            arm: "control".to_string(),
            model: model.to_string(),
            provider_model: None,
            provider_request_id: None,
            stop_reason: None,
            success: true,
            http_status: None,
            latency_ms: 0,
            usage: Usage::default(),
            prompt_bytes: 0,
            context_bytes: 0,
            request_body_bytes: 0,
            raw_response_bytes: 0,
            thinking_bytes: 0,
            answer_bytes: 0,
            proxy_prefix_tokens_estimate: None,
            context_files: Vec::new(),
            artifacts,
            surfaces: vec![SurfaceDelta {
                surface: surface.to_string(),
                observed_bytes: 0,
                delivered_bytes: 0,
                recovered_bytes,
                compressed: false,
                recovery: true,
                calls: 0,
                provider_calls: 0,
                provider_input_tokens: 0,
                provider_output_tokens: 0,
                proxy_prefix_tokens_estimate: 0,
            }],
        }
    }

    fn validate(&self) -> Result<(), String> {
        if self.arm != "control" && self.arm != "guarded" {
            return Err(format!("invalid experiment arm: {}", self.arm));
        }

        for delta in &self.surfaces {
            if !matches!(
                delta.surface.as_str(),
                SURFACE_CONSULT_PROMPT
                    | SURFACE_CONSULT_RESPONSE
                    | SURFACE_SHELL
                    | SURFACE_FILES
            ) {
                return Err(format!("invalid accounting surface: {}", delta.surface));
            }

            if delta.recovery {
                if delta.compressed
                    || delta.observed_bytes != 0
                    || delta.delivered_bytes != 0
                    || delta.recovered_bytes == 0
                {
                    return Err(
                        "recovery deltas must contain only non-zero recovered_bytes".to_string(),
                    );
                }
            } else if !delta.compressed && delta.observed_bytes != delta.delivered_bytes {
                return Err(format!(
                    "honesty invariant failed for {}: an uncompressed surface cannot report different observed and delivered bytes",
                    delta.surface
                ));
            } else if delta.compressed && delta.delivered_bytes > delta.observed_bytes {
                return Err(format!(
                    "compressed delivered bytes exceed observed bytes for {}",
                    delta.surface
                ));
            }
        }

        Ok(())
    }

    fn to_value(&self, sequence: u64) -> Value {
        let context_files: Vec<Value> = self
            .context_files
            .iter()
            .map(|file| {
                json!({
                    "path": file.path,
                    "bytes": file.bytes,
                })
            })
            .collect();

        let surfaces: Vec<Value> = self.surfaces.iter().map(SurfaceDelta::to_value).collect();

        json!({
            "version": 1,
            "sequence": sequence,
            "event_id": self.event_id,
            "timestamp": self.timestamp,
            "event_kind": self.event_kind,
            "arm": self.arm,
            "model": self.model,
            "provider_model": self.provider_model,
            "provider_request_id": self.provider_request_id,
            "stop_reason": self.stop_reason,
            "success": self.success,
            "http_status": self.http_status,
            "latency_ms": self.latency_ms,
            "usage": self.usage.to_value(),
            "counterfactual": {
                "prompt_bytes": self.prompt_bytes,
                "context_bytes": self.context_bytes,
                "request_body_bytes": self.request_body_bytes,
                "raw_response_bytes": self.raw_response_bytes,
                "thinking_bytes": self.thinking_bytes,
                "answer_bytes": self.answer_bytes,
                "proxy_prefix_tokens_estimate": self.proxy_prefix_tokens_estimate,
                "proxy_prefix_estimate_source": if self.proxy_prefix_tokens_estimate.is_some() {
                    Value::String("stage0-live-droplet-2026-08-19".to_string())
                } else {
                    Value::Null
                },
                "context_files": context_files,
            },
            "artifacts": self.artifacts,
            "surfaces": surfaces,
        })
    }
}

#[derive(Clone, Debug, Default)]
pub struct RollupCell {
    pub model: String,
    pub surface: String,
    pub events: u64,
    pub calls: u64,
    pub provider_calls: u64,
    pub control_calls: u64,
    pub guarded_calls: u64,
    pub observed_bytes: u64,
    pub delivered_bytes: u64,
    pub compressed_raw_bytes: u64,
    pub compressed_delivered_bytes: u64,
    pub recovered_bytes: u64,
    pub compressed_events: u64,
    pub provider_input_tokens: u64,
    pub provider_output_tokens: u64,
    // Per-arm provider token splits. The all-arm totals above stay authoritative
    // for the observe-only accounting; these exist so the ground-truth class can
    // compare `control` against `guarded` without mixing the arms into one
    // number. Ground truth only: never populated from byte estimates.
    pub control_input_tokens: u64,
    pub control_output_tokens: u64,
    pub guarded_input_tokens: u64,
    pub guarded_output_tokens: u64,
    pub proxy_prefix_tokens_estimate: u64,
}

impl RollupCell {
    pub fn saved_bytes(&self) -> u64 {
        self.compressed_raw_bytes
            .saturating_sub(self.compressed_delivered_bytes)
            .saturating_sub(self.recovered_bytes)
    }

    fn to_value(&self) -> Value {
        json!({
            "model": self.model,
            "surface": self.surface,
            "events": self.events,
            "calls": self.calls,
            "provider_calls": self.provider_calls,
            "control_calls": self.control_calls,
            "guarded_calls": self.guarded_calls,
            "observed_bytes": self.observed_bytes,
            "delivered_bytes": self.delivered_bytes,
            "compressed_raw_bytes": self.compressed_raw_bytes,
            "compressed_delivered_bytes": self.compressed_delivered_bytes,
            "recovered_bytes": self.recovered_bytes,
            "compressed_events": self.compressed_events,
            "provider_input_tokens": self.provider_input_tokens,
            "provider_output_tokens": self.provider_output_tokens,
            "control_input_tokens": self.control_input_tokens,
            "control_output_tokens": self.control_output_tokens,
            "guarded_input_tokens": self.guarded_input_tokens,
            "guarded_output_tokens": self.guarded_output_tokens,
            "proxy_prefix_tokens_estimate": self.proxy_prefix_tokens_estimate,
        })
    }

    fn from_value(value: &Value) -> Result<Self, String> {
        Ok(Self {
            model: required_string(value, "model")?,
            surface: required_string(value, "surface")?,
            events: number(value, "events"),
            calls: number(value, "calls"),
            provider_calls: number(value, "provider_calls"),
            control_calls: number(value, "control_calls"),
            guarded_calls: number(value, "guarded_calls"),
            observed_bytes: number(value, "observed_bytes"),
            delivered_bytes: number(value, "delivered_bytes"),
            compressed_raw_bytes: number(value, "compressed_raw_bytes"),
            compressed_delivered_bytes: number(value, "compressed_delivered_bytes"),
            recovered_bytes: number(value, "recovered_bytes"),
            compressed_events: number(value, "compressed_events"),
            provider_input_tokens: number(value, "provider_input_tokens"),
            provider_output_tokens: number(value, "provider_output_tokens"),
            control_input_tokens: number(value, "control_input_tokens"),
            control_output_tokens: number(value, "control_output_tokens"),
            guarded_input_tokens: number(value, "guarded_input_tokens"),
            guarded_output_tokens: number(value, "guarded_output_tokens"),
            proxy_prefix_tokens_estimate: number(value, "proxy_prefix_tokens_estimate"),
        })
    }

    fn merge(&mut self, other: &RollupCell) {
        self.events = self.events.saturating_add(other.events);
        self.calls = self.calls.saturating_add(other.calls);
        self.provider_calls = self.provider_calls.saturating_add(other.provider_calls);
        self.control_calls = self.control_calls.saturating_add(other.control_calls);
        self.guarded_calls = self.guarded_calls.saturating_add(other.guarded_calls);
        self.observed_bytes = self.observed_bytes.saturating_add(other.observed_bytes);
        self.delivered_bytes = self.delivered_bytes.saturating_add(other.delivered_bytes);
        self.compressed_raw_bytes = self
            .compressed_raw_bytes
            .saturating_add(other.compressed_raw_bytes);
        self.compressed_delivered_bytes = self
            .compressed_delivered_bytes
            .saturating_add(other.compressed_delivered_bytes);
        self.recovered_bytes = self.recovered_bytes.saturating_add(other.recovered_bytes);
        self.compressed_events = self
            .compressed_events
            .saturating_add(other.compressed_events);
        self.provider_input_tokens = self
            .provider_input_tokens
            .saturating_add(other.provider_input_tokens);
        self.provider_output_tokens = self
            .provider_output_tokens
            .saturating_add(other.provider_output_tokens);
        self.control_input_tokens = self
            .control_input_tokens
            .saturating_add(other.control_input_tokens);
        self.control_output_tokens = self
            .control_output_tokens
            .saturating_add(other.control_output_tokens);
        self.guarded_input_tokens = self
            .guarded_input_tokens
            .saturating_add(other.guarded_input_tokens);
        self.guarded_output_tokens = self
            .guarded_output_tokens
            .saturating_add(other.guarded_output_tokens);
        self.proxy_prefix_tokens_estimate = self
            .proxy_prefix_tokens_estimate
            .saturating_add(other.proxy_prefix_tokens_estimate);
    }
}

#[derive(Clone, Debug, Default)]
struct Aggregate {
    hour_start: u64,
    last_sequence: u64,
    cells: Vec<RollupCell>,
}

impl Aggregate {
    fn apply(&mut self, entry: &Value) -> Result<(), String> {
        let sequence = entry
            .get("sequence")
            .and_then(Value::as_u64)
            .ok_or_else(|| "ledger entry has no sequence".to_string())?;

        if sequence <= self.last_sequence {
            return Ok(());
        }

        let model = entry
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let arm = entry
            .get("arm")
            .and_then(Value::as_str)
            .unwrap_or("control");

        let surfaces = entry
            .get("surfaces")
            .and_then(Value::as_array)
            .ok_or_else(|| "ledger entry has no surfaces array".to_string())?;

        for surface in surfaces {
            let surface_name = required_string(surface, "surface")?;
            let cell = self.cell_mut(model, &surface_name);
            let calls = number(surface, "calls");
            let provider_calls = number(surface, "provider_calls");
            let observed = number(surface, "observed_bytes");
            let delivered = number(surface, "delivered_bytes");
            let recovered = number(surface, "recovered_bytes");
            let compressed = surface
                .get("compressed")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let recovery = surface
                .get("recovery")
                .and_then(Value::as_bool)
                .unwrap_or(false);

            let input_tokens = number(surface, "provider_input_tokens");
            let output_tokens = number(surface, "provider_output_tokens");

            cell.events = cell.events.saturating_add(1);
            cell.calls = cell.calls.saturating_add(calls);
            cell.provider_calls = cell.provider_calls.saturating_add(provider_calls);
            cell.observed_bytes = cell.observed_bytes.saturating_add(observed);
            cell.delivered_bytes = cell.delivered_bytes.saturating_add(delivered);
            cell.provider_input_tokens =
                cell.provider_input_tokens.saturating_add(input_tokens);
            cell.provider_output_tokens =
                cell.provider_output_tokens.saturating_add(output_tokens);
            cell.proxy_prefix_tokens_estimate = cell
                .proxy_prefix_tokens_estimate
                .saturating_add(number(surface, "proxy_prefix_tokens_estimate"));

            if arm == "guarded" {
                cell.guarded_calls = cell.guarded_calls.saturating_add(provider_calls);
                cell.guarded_input_tokens =
                    cell.guarded_input_tokens.saturating_add(input_tokens);
                cell.guarded_output_tokens =
                    cell.guarded_output_tokens.saturating_add(output_tokens);
            } else {
                cell.control_calls = cell.control_calls.saturating_add(provider_calls);
                cell.control_input_tokens =
                    cell.control_input_tokens.saturating_add(input_tokens);
                cell.control_output_tokens =
                    cell.control_output_tokens.saturating_add(output_tokens);
            }

            if compressed {
                cell.compressed_events = cell.compressed_events.saturating_add(1);
                cell.compressed_raw_bytes =
                    cell.compressed_raw_bytes.saturating_add(observed);
                cell.compressed_delivered_bytes = cell
                    .compressed_delivered_bytes
                    .saturating_add(delivered);
            }

            if recovery {
                cell.recovered_bytes = cell.recovered_bytes.saturating_add(recovered);
            }
        }

        self.last_sequence = sequence;
        Ok(())
    }

    fn cell_mut(&mut self, model: &str, surface: &str) -> &mut RollupCell {
        if let Some(index) = self
            .cells
            .iter()
            .position(|cell| cell.model == model && cell.surface == surface)
        {
            return &mut self.cells[index];
        }

        self.cells.push(RollupCell {
            model: model.to_string(),
            surface: surface.to_string(),
            ..RollupCell::default()
        });
        self.cells.last_mut().expect("cell was just inserted")
    }

    fn to_value(&self) -> Value {
        let cells: Vec<Value> = self.cells.iter().map(RollupCell::to_value).collect();
        json!({
            "version": 1,
            "hour_start": self.hour_start,
            "last_sequence": self.last_sequence,
            "cells": cells,
        })
    }

    fn from_value(value: &Value) -> Result<Self, String> {
        let cells = value
            .get("cells")
            .and_then(Value::as_array)
            .ok_or_else(|| "rollup has no cells array".to_string())?
            .iter()
            .map(RollupCell::from_value)
            .collect::<Result<Vec<_>, _>>()?;

        Ok(Self {
            hour_start: value
                .get("hour_start")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            last_sequence: value
                .get("last_sequence")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            cells,
        })
    }
}

#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub cells: Vec<RollupCell>,
}

impl Snapshot {
    fn merge_aggregate(&mut self, aggregate: &Aggregate) {
        for incoming in &aggregate.cells {
            if let Some(existing) = self
                .cells
                .iter_mut()
                .find(|cell| cell.model == incoming.model && cell.surface == incoming.surface)
            {
                existing.merge(incoming);
            } else {
                self.cells.push(incoming.clone());
            }
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum Window {
    Hours24,
    Days7,
    Days30,
    Lifetime,
}

impl Window {
    pub fn name(self) -> &'static str {
        match self {
            Self::Hours24 => "24h",
            Self::Days7 => "7d",
            Self::Days30 => "30d",
            Self::Lifetime => "lifetime",
        }
    }

    fn seconds(self) -> Option<u64> {
        match self {
            Self::Hours24 => Some(24 * 60 * 60),
            Self::Days7 => Some(7 * 24 * 60 * 60),
            Self::Days30 => Some(30 * 24 * 60 * 60),
            Self::Lifetime => None,
        }
    }
}

pub struct Ledger {
    root: PathBuf,
    estimated_bytes_per_token: f64,
}

impl Ledger {
    pub fn new(state: &Path, estimated_bytes_per_token: f64) -> Result<Self, String> {
        let root = state.join("compress");
        fs::create_dir_all(root.join("rollups/hourly"))
            .map_err(|error| format!("cannot create ledger rollup directory: {error}"))?;

        Ok(Self {
            root,
            estimated_bytes_per_token,
        })
    }

    pub fn append(&self, entry: &LedgerEntry) -> Result<(), String> {
        entry.validate()?;

        // JSONL is deliberate here instead of SQLite. Stage 1 runs on a 1-vCPU,
        // memory-constrained droplet and needs a small pure-Rust dependency tree.
        // A process-wide flock protects the append, while a one-record pending WAL
        // makes ledger+hourly+lifetime rollup updates crash-recoverable.
        let _lock = FileLock::acquire(&self.root.join("ledger.lock"))?;
        self.recover_pending_locked()?;

        let lifetime = self.load_aggregate(&self.lifetime_path(), 0)?;
        let sequence = lifetime.last_sequence.saturating_add(1);
        let entry_value = entry.to_value(sequence);
        let ledger_offset = fs::metadata(self.ledger_path())
            .map(|metadata| metadata.len())
            .unwrap_or(0);

        let pending = json!({
            "version": 1,
            "ledger_offset": ledger_offset,
            "entry": entry_value,
        });
        let pending_bytes = serde_json::to_vec_pretty(&pending)
            .map_err(|error| format!("cannot encode pending ledger transaction: {error}"))?;
        atomic_write(&self.pending_path(), &pending_bytes)
            .map_err(|error| format!("cannot persist pending ledger transaction: {error}"))?;

        self.recover_pending_locked()
    }

    pub fn prepare(&self) -> Result<(), String> {
        let _lock = FileLock::acquire(&self.root.join("ledger.lock"))?;
        self.recover_pending_locked()
    }

    pub fn snapshot(&self, window: Window) -> Result<Snapshot, String> {
        self.prepare()?;

        if matches!(window, Window::Lifetime) {
            let aggregate = self.load_aggregate(&self.lifetime_path(), 0)?;
            let mut snapshot = Snapshot::default();
            snapshot.merge_aggregate(&aggregate);
            return Ok(snapshot);
        }

        let cutoff = unix_seconds().saturating_sub(window.seconds().unwrap_or(0));
        let directory = self.root.join("rollups/hourly");
        let mut snapshot = Snapshot::default();

        for entry in fs::read_dir(&directory)
            .map_err(|error| format!("cannot read {}: {error}", directory.display()))?
        {
            let entry =
                entry.map_err(|error| format!("cannot read hourly rollup entry: {error}"))?;
            let path = entry.path();

            if path.extension().and_then(|extension| extension.to_str()) != Some("json") {
                continue;
            }

            let hour = path
                .file_stem()
                .and_then(|name| name.to_str())
                .and_then(|name| name.parse::<u64>().ok())
                .unwrap_or(0);

            // Hourly buckets bound work without rescanning the raw JSONL. The edge
            // bucket is included when any portion overlaps the requested window.
            if hour.saturating_add(3600) <= cutoff {
                continue;
            }

            let aggregate = self.load_aggregate(&path, hour)?;
            snapshot.merge_aggregate(&aggregate);
        }

        Ok(snapshot)
    }

    pub fn summary_path(&self) -> PathBuf {
        self.root.join("summary.txt")
    }

    pub fn ledger_path(&self) -> PathBuf {
        self.root.join("ledger.jsonl")
    }

    fn recover_pending_locked(&self) -> Result<(), String> {
        let pending_path = self.pending_path();
        if !pending_path.exists() {
            return Ok(());
        }

        let pending_bytes = fs::read(&pending_path)
            .map_err(|error| format!("cannot read pending ledger transaction: {error}"))?;
        let pending: Value = serde_json::from_slice(&pending_bytes)
            .map_err(|error| format!("cannot parse pending ledger transaction: {error}"))?;
        let offset = pending
            .get("ledger_offset")
            .and_then(Value::as_u64)
            .ok_or_else(|| "pending ledger transaction has no offset".to_string())?;
        let entry = pending
            .get("entry")
            .ok_or_else(|| "pending ledger transaction has no entry".to_string())?;

        let mut line = serde_json::to_vec(entry)
            .map_err(|error| format!("cannot encode ledger entry: {error}"))?;
        line.push(b'\n');

        self.ensure_ledger_line(offset, &line)?;

        let timestamp = entry
            .get("timestamp")
            .and_then(Value::as_u64)
            .ok_or_else(|| "ledger entry has no timestamp".to_string())?;
        let hour = timestamp - (timestamp % 3600);
        let hourly_path = self.hourly_path(hour);

        let mut hourly = self.load_aggregate(&hourly_path, hour)?;
        hourly.apply(entry)?;
        self.write_aggregate(&hourly_path, &hourly)?;

        let mut lifetime = self.load_aggregate(&self.lifetime_path(), 0)?;
        lifetime.apply(entry)?;
        self.write_aggregate(&self.lifetime_path(), &lifetime)?;
        self.write_summary(&lifetime)?;

        fs::remove_file(&pending_path)
            .map_err(|error| format!("cannot remove pending ledger transaction: {error}"))?;
        sync_dir(&self.root)
            .map_err(|error| format!("cannot sync ledger directory: {error}"))?;

        Ok(())
    }

    fn ensure_ledger_line(&self, offset: u64, expected: &[u8]) -> Result<(), String> {
        let ledger_path = self.ledger_path();
        if let Some(parent) = ledger_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("cannot create ledger directory: {error}"))?;
        }

        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .open(&ledger_path)
            .map_err(|error| format!("cannot open ledger: {error}"))?;

        let length = file
            .metadata()
            .map_err(|error| format!("cannot stat ledger: {error}"))?
            .len();

        if length < offset {
            return Err(format!(
                "ledger is shorter than pending transaction offset: {length} < {offset}"
            ));
        }

        let mut matches = false;
        if length >= offset.saturating_add(expected.len() as u64) {
            file.seek(SeekFrom::Start(offset))
                .map_err(|error| format!("cannot seek ledger: {error}"))?;
            let mut existing = vec![0_u8; expected.len()];
            file.read_exact(&mut existing)
                .map_err(|error| format!("cannot verify pending ledger append: {error}"))?;
            matches = existing == expected;
        }

        if !matches {
            file.set_len(offset)
                .map_err(|error| format!("cannot truncate partial ledger append: {error}"))?;
            file.seek(SeekFrom::Start(offset))
                .map_err(|error| format!("cannot seek ledger for append: {error}"))?;
            file.write_all(expected)
                .map_err(|error| format!("cannot append ledger entry: {error}"))?;
            file.flush()
                .map_err(|error| format!("cannot flush ledger entry: {error}"))?;
            file.sync_all()
                .map_err(|error| format!("cannot sync ledger entry: {error}"))?;
        }

        Ok(())
    }

    fn write_summary(&self, lifetime: &Aggregate) -> Result<(), String> {
        let saved_bytes: u64 = lifetime.cells.iter().map(RollupCell::saved_bytes).sum();
        let compressed_samples: u64 = lifetime
            .cells
            .iter()
            .map(|cell| cell.compressed_events)
            .sum();
        let guarded_calls: u64 = lifetime
            .cells
            .iter()
            .filter(|cell| cell.surface == SURFACE_CONSULT_PROMPT)
            .map(|cell| cell.guarded_calls)
            .sum();
        let estimated_tokens =
            (saved_bytes as f64 / self.estimated_bytes_per_token).round() as u64;

        let summary = format!(
            "saved_bytes={saved_bytes} estimated_tokens={estimated_tokens} divisor={} compressed_samples={compressed_samples} guarded_calls={guarded_calls} updated_at={}\n",
            self.estimated_bytes_per_token,
            unix_seconds()
        );
        atomic_write(&self.summary_path(), summary.as_bytes())
            .map_err(|error| format!("cannot update statusline summary: {error}"))
    }

    fn write_aggregate(&self, path: &Path, aggregate: &Aggregate) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(&aggregate.to_value())
            .map_err(|error| format!("cannot encode rollup {}: {error}", path.display()))?;
        atomic_write(path, &bytes)
            .map_err(|error| format!("cannot persist rollup {}: {error}", path.display()))
    }

    fn load_aggregate(&self, path: &Path, hour_start: u64) -> Result<Aggregate, String> {
        if !path.exists() {
            return Ok(Aggregate {
                hour_start,
                ..Aggregate::default()
            });
        }

        let bytes = fs::read(path)
            .map_err(|error| format!("cannot read rollup {}: {error}", path.display()))?;
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|error| format!("cannot parse rollup {}: {error}", path.display()))?;
        let mut aggregate = Aggregate::from_value(&value)?;
        if aggregate.hour_start == 0 {
            aggregate.hour_start = hour_start;
        }
        Ok(aggregate)
    }

    fn pending_path(&self) -> PathBuf {
        self.root.join("rollups/pending.json")
    }

    fn hourly_path(&self, hour: u64) -> PathBuf {
        self.root.join("rollups/hourly").join(format!("{hour}.json"))
    }

    fn lifetime_path(&self) -> PathBuf {
        self.root.join("rollups/lifetime.json")
    }
}

fn number(value: &Value, field: &str) -> u64 {
    value.get(field).and_then(Value::as_u64).unwrap_or(0)
}

fn required_string(value: &Value, field: &str) -> Result<String, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| format!("field {field} is missing or invalid"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_state(name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "brain-compress-ledger-test-{name}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn recovery_subtracts_from_future_measured_saving() {
        let state = temporary_state("recovery");
        let ledger = Ledger::new(&state, 4.0).unwrap();

        let mut compacted = LedgerEntry::new_consult("future-model");
        compacted.success = true;
        compacted.surfaces.push(SurfaceDelta {
            surface: SURFACE_CONSULT_RESPONSE.to_string(),
            observed_bytes: 100,
            delivered_bytes: 40,
            recovered_bytes: 0,
            compressed: true,
            recovery: false,
            calls: 1,
            provider_calls: 0,
            provider_input_tokens: 0,
            provider_output_tokens: 0,
            proxy_prefix_tokens_estimate: 0,
        });
        ledger.append(&compacted).unwrap();

        let recovery = LedgerEntry::new_recovery(
            "future-model",
            SURFACE_CONSULT_RESPONSE,
            20,
            "bc_2345",
        );
        ledger.append(&recovery).unwrap();

        let snapshot = ledger.snapshot(Window::Lifetime).unwrap();
        let cell = snapshot
            .cells
            .iter()
            .find(|cell| {
                cell.model == "future-model" && cell.surface == SURFACE_CONSULT_RESPONSE
            })
            .unwrap();

        assert_eq!(cell.compressed_raw_bytes, 100);
        assert_eq!(cell.compressed_delivered_bytes, 40);
        assert_eq!(cell.recovered_bytes, 20);
        assert_eq!(cell.saved_bytes(), 40);

        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn provider_tokens_split_per_arm() {
        let state = temporary_state("arms");
        let ledger = Ledger::new(&state, 4.0).unwrap();

        let response_surface = |input, output| SurfaceDelta {
            surface: SURFACE_CONSULT_RESPONSE.to_string(),
            observed_bytes: 10,
            delivered_bytes: 10,
            recovered_bytes: 0,
            compressed: false,
            recovery: false,
            calls: 1,
            provider_calls: 1,
            provider_input_tokens: input,
            provider_output_tokens: output,
            proxy_prefix_tokens_estimate: 0,
        };

        let mut control = LedgerEntry::new_consult("arm-model");
        control.success = true;
        control.surfaces.push(response_surface(500, 200));
        ledger.append(&control).unwrap();

        let mut guarded = LedgerEntry::new_consult("arm-model");
        guarded.arm = "guarded".to_string();
        guarded.success = true;
        guarded.surfaces.push(response_surface(510, 80));
        ledger.append(&guarded).unwrap();

        let snapshot = ledger.snapshot(Window::Lifetime).unwrap();
        let cell = snapshot
            .cells
            .iter()
            .find(|cell| cell.model == "arm-model" && cell.surface == SURFACE_CONSULT_RESPONSE)
            .unwrap();

        // Per-arm splits are exact, and the all-arm totals remain their sum:
        // the arms are separable without ever being merged into one class.
        assert_eq!(cell.control_calls, 1);
        assert_eq!(cell.guarded_calls, 1);
        assert_eq!(cell.control_input_tokens, 500);
        assert_eq!(cell.control_output_tokens, 200);
        assert_eq!(cell.guarded_input_tokens, 510);
        assert_eq!(cell.guarded_output_tokens, 80);
        assert_eq!(cell.provider_input_tokens, 1010);
        assert_eq!(cell.provider_output_tokens, 280);

        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn uncompressed_mismatch_is_rejected() {
        let state = temporary_state("honesty");
        let ledger = Ledger::new(&state, 4.0).unwrap();

        let mut entry = LedgerEntry::new_consult("model");
        entry.surfaces.push(SurfaceDelta {
            surface: SURFACE_CONSULT_RESPONSE.to_string(),
            observed_bytes: 100,
            delivered_bytes: 50,
            recovered_bytes: 0,
            compressed: false,
            recovery: false,
            calls: 1,
            provider_calls: 0,
            provider_input_tokens: 0,
            provider_output_tokens: 0,
            proxy_prefix_tokens_estimate: 0,
        });

        assert!(ledger.append(&entry).is_err());
        fs::remove_dir_all(state).unwrap();
    }
}