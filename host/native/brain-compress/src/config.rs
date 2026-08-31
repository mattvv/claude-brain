use crate::util::{parse_bool, read_to_string, strip_inline_comment, unquote};
use std::path::{Path, PathBuf};

pub const DEFAULT_ARTIFACT_QUOTA_BYTES: u64 = 512 * 1024 * 1024;
pub const DEFAULT_ARTIFACT_TTL_DAYS: u64 = 30;
pub const DEFAULT_ESTIMATED_BYTES_PER_TOKEN: f64 = 4.0;
pub const DEFAULT_MINIMUM_CLAIM_SAMPLES: u64 = 30;
pub const DEFAULT_CONSULT_LOGS: usize = 20;
/// Below this much output there is no win worth a lossy view: the model would
/// spend more recovering the original than the compaction ever saved.
pub const DEFAULT_COMPRESS_MIN_BYTES: u64 = 2048;
/// Exact, byte-for-byte lines kept at the head of a compacted file read.
pub const DEFAULT_BASH_READ_HEAD_LINES: usize = 60;

#[derive(Clone, Debug)]
pub struct Config {
    pub enabled: bool,
    /// Deprecated and ignored. It never gated anything — compression ran
    /// regardless of its value — so reporting it was actively misleading. Still
    /// parsed so that configs written by older versions keep loading.
    pub mode: String,
    pub artifact_quota_bytes: u64,
    pub artifact_ttl_days: u64,
    pub estimated_bytes_per_token: f64,
    pub minimum_claim_samples: u64,
    pub consult_logs: usize,
    /// `observe` (default): record oversized built-in Reads, change nothing.
    /// `enforce`: deny an oversized unrestricted Read with guidance to use
    /// `brain compress read`. `off`: no Read guard at all.
    pub read_guard: String,
    pub large_file_lines: usize,
    pub large_file_bytes: u64,
    /// Smallest command output worth compacting, in bytes.
    pub compress_min_bytes: u64,
    /// Exact lines kept at the head of a compacted `cat`/`head`/`tail`/`sed -n`.
    pub bash_read_head_lines: usize,
    /// Duplicate-result elision (design §5a): byte-identical successful
    /// results within the scope window become references to the earlier view.
    pub dedup_enabled: bool,
    pub dedup_window_hours: u64,
    /// Cheap-model repository navigation (design §2). An ordered fallback chain:
    /// explore tries each in turn and falls to the next when a model's vendor is
    /// not linked or the call fails. None may be a Claude-family model;
    /// explore.rs enforces that too.
    pub explore_models: Vec<String>,
    pub explore_effort: String,
    pub explore_max_pack_bytes: u64,
    /// Cap on rows printed by `brain compress refs` (full result persisted).
    pub symbols_max_results: u64,
    /// Session-history recall (design §3). OPT-IN and OFF by default: it
    /// searches past Claude Code transcripts, which may contain sensitive
    /// text. The setup wizard offers to enable it.
    pub recall_enabled: bool,
    pub recall_max_files: u64,
    pub recall_half_life_days: u64,
    pub path: PathBuf,
}

impl Config {
    pub fn defaults(state: &Path) -> Self {
        Self {
            enabled: true,
            mode: "observe".to_string(),
            artifact_quota_bytes: DEFAULT_ARTIFACT_QUOTA_BYTES,
            artifact_ttl_days: DEFAULT_ARTIFACT_TTL_DAYS,
            estimated_bytes_per_token: DEFAULT_ESTIMATED_BYTES_PER_TOKEN,
            minimum_claim_samples: DEFAULT_MINIMUM_CLAIM_SAMPLES,
            consult_logs: DEFAULT_CONSULT_LOGS,
            read_guard: "observe".to_string(),
            large_file_lines: 800,
            large_file_bytes: 48 * 1024,
            compress_min_bytes: DEFAULT_COMPRESS_MIN_BYTES,
            bash_read_head_lines: DEFAULT_BASH_READ_HEAD_LINES,
            dedup_enabled: true,
            dedup_window_hours: 8,
            explore_models: vec!["gpt-5.6-luna".to_string(), "grok-4.5".to_string()],
            explore_effort: "low".to_string(),
            explore_max_pack_bytes: 96 * 1024,
            symbols_max_results: 200,
            recall_enabled: false,
            recall_max_files: 40,
            recall_half_life_days: 14,
            path: state.join("compress/compress.toml"),
        }
    }

    pub fn load(state: &Path) -> Result<Self, String> {
        let mut config = Self::defaults(state);
        if !config.path.exists() {
            return Ok(config);
        }

        let source = read_to_string(&config.path)?;
        let mut section = String::new();

        for (line_number, raw_line) in source.lines().enumerate() {
            let line = strip_inline_comment(raw_line).trim();
            if line.is_empty() {
                continue;
            }

            if line.starts_with('[') && line.ends_with(']') {
                section = line[1..line.len() - 1].trim().to_string();
                continue;
            }

            let Some((key, value)) = line.split_once('=') else {
                return Err(format!(
                    "{}:{}: expected key = value",
                    config.path.display(),
                    line_number + 1
                ));
            };

            let key = key.trim();
            let value = value.trim();
            let qualified = if section.is_empty() {
                key.to_string()
            } else {
                format!("{section}.{key}")
            };

            match qualified.as_str() {
                "enabled" => {
                    config.enabled = parse_bool(value).ok_or_else(|| {
                        format!(
                            "{}:{}: invalid boolean for enabled",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "mode" => config.mode = unquote(value),
                "artifacts.quota_bytes" => {
                    config.artifact_quota_bytes = value.parse::<u64>().map_err(|error| {
                        format!(
                            "{}:{}: invalid artifacts.quota_bytes: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "artifacts.default_ttl_days" => {
                    config.artifact_ttl_days = value.parse::<u64>().map_err(|error| {
                        format!(
                            "{}:{}: invalid artifacts.default_ttl_days: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "accounting.estimated_bytes_per_token" => {
                    config.estimated_bytes_per_token =
                        value.parse::<f64>().map_err(|error| {
                            format!(
                                "{}:{}: invalid accounting.estimated_bytes_per_token: {error}",
                                config.path.display(),
                                line_number + 1
                            )
                        })?;
                }
                "accounting.minimum_claim_samples" => {
                    config.minimum_claim_samples =
                        value.parse::<u64>().map_err(|error| {
                            format!(
                                "{}:{}: invalid accounting.minimum_claim_samples: {error}",
                                config.path.display(),
                                line_number + 1
                            )
                        })?;
                }
                "retention.consult_logs" => {
                    config.consult_logs = value.parse::<usize>().map_err(|error| {
                        format!(
                            "{}:{}: invalid retention.consult_logs: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "file_tools.read_guard" => {
                    let value = unquote(value);
                    if !matches!(value.as_str(), "observe" | "enforce" | "off") {
                        return Err(format!(
                            "{}:{}: file_tools.read_guard must be observe|enforce|off",
                            config.path.display(),
                            line_number + 1
                        ));
                    }
                    config.read_guard = value;
                }
                "file_tools.large_file_lines" => {
                    config.large_file_lines = value.parse::<usize>().map_err(|error| {
                        format!(
                            "{}:{}: invalid file_tools.large_file_lines: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                // Ordered fallback chain, comma-separated. `explore.model` is
                // kept as an alias so a single value still works.
                "explore.models" | "explore.model" => {
                    let chain: Vec<String> = unquote(value)
                        .split(',')
                        .map(|m| m.trim().to_string())
                        .filter(|m| !m.is_empty())
                        .collect();
                    if chain.is_empty() {
                        return Err(format!(
                            "{}:{}: explore.models needs at least one model",
                            config.path.display(),
                            line_number + 1
                        ));
                    }
                    config.explore_models = chain;
                }
                "explore.effort" => config.explore_effort = unquote(value),
                "explore.max_pack_bytes" => {
                    config.explore_max_pack_bytes = value.parse::<u64>().map_err(|error| {
                        format!(
                            "{}:{}: invalid explore.max_pack_bytes: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "recall.enabled" => {
                    config.recall_enabled = parse_bool(value).ok_or_else(|| {
                        format!(
                            "{}:{}: invalid boolean for recall.enabled",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "recall.max_files" => {
                    config.recall_max_files = value.parse::<u64>().map_err(|error| {
                        format!(
                            "{}:{}: invalid recall.max_files: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "recall.half_life_days" => {
                    config.recall_half_life_days = value.parse::<u64>().map_err(|error| {
                        format!(
                            "{}:{}: invalid recall.half_life_days: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "symbols.max_results" => {
                    config.symbols_max_results = value.parse::<u64>().map_err(|error| {
                        format!(
                            "{}:{}: invalid symbols.max_results: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "dedup.enabled" => {
                    config.dedup_enabled = parse_bool(value).ok_or_else(|| {
                        format!(
                            "{}:{}: invalid boolean for dedup.enabled",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "dedup.window_hours" => {
                    config.dedup_window_hours = value.parse::<u64>().map_err(|error| {
                        format!(
                            "{}:{}: invalid dedup.window_hours: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "file_tools.large_file_bytes" => {
                    config.large_file_bytes = value.parse::<u64>().map_err(|error| {
                        format!(
                            "{}:{}: invalid file_tools.large_file_bytes: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "file_tools.compress_min_bytes" => {
                    config.compress_min_bytes = value.parse::<u64>().map_err(|error| {
                        format!(
                            "{}:{}: invalid file_tools.compress_min_bytes: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                "file_tools.bash_read_head_lines" => {
                    config.bash_read_head_lines = value.parse::<usize>().map_err(|error| {
                        format!(
                            "{}:{}: invalid file_tools.bash_read_head_lines: {error}",
                            config.path.display(),
                            line_number + 1
                        )
                    })?;
                }
                // Forward-compatible and informational keys are deliberately ignored.
                "version"
                | "ledger.format"
                | "ledger.hourly_rollups"
                | "accounting.print_dollars"
                | "artifacts.content_addressed" => {}
                _ => {}
            }
        }

        // `mode` is deprecated and gates nothing, so it is no longer validated:
        // rejecting a value we then ignore only broke configs for no benefit.

        if config.bash_read_head_lines == 0 {
            return Err(format!(
                "{}: file_tools.bash_read_head_lines must be greater than zero",
                config.path.display()
            ));
        }

        if config.artifact_quota_bytes == 0 {
            return Err(format!(
                "{}: artifacts.quota_bytes must be greater than zero",
                config.path.display()
            ));
        }

        if config.artifact_ttl_days == 0 {
            return Err(format!(
                "{}: artifacts.default_ttl_days must be greater than zero",
                config.path.display()
            ));
        }

        if !config.estimated_bytes_per_token.is_finite()
            || config.estimated_bytes_per_token <= 0.0
        {
            return Err(format!(
                "{}: accounting.estimated_bytes_per_token must be a positive number",
                config.path.display()
            ));
        }

        if config.consult_logs == 0 {
            return Err(format!(
                "{}: retention.consult_logs must be greater than zero",
                config.path.display()
            ));
        }

        Ok(config)
    }
}