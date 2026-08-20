use crate::util::{parse_bool, read_to_string, strip_inline_comment, unquote};
use std::path::{Path, PathBuf};

pub const DEFAULT_ARTIFACT_QUOTA_BYTES: u64 = 512 * 1024 * 1024;
pub const DEFAULT_ARTIFACT_TTL_DAYS: u64 = 30;
pub const DEFAULT_ESTIMATED_BYTES_PER_TOKEN: f64 = 4.0;
pub const DEFAULT_MINIMUM_CLAIM_SAMPLES: u64 = 30;
pub const DEFAULT_CONSULT_LOGS: usize = 20;

#[derive(Clone, Debug)]
pub struct Config {
    pub enabled: bool,
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
    /// Duplicate-result elision (design §5a): byte-identical successful
    /// results within the scope window become references to the earlier view.
    pub dedup_enabled: bool,
    pub dedup_window_hours: u64,
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
            dedup_enabled: true,
            dedup_window_hours: 8,
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
                // Forward-compatible and informational keys are deliberately ignored.
                "version"
                | "ledger.format"
                | "ledger.hourly_rollups"
                | "accounting.print_dollars"
                | "artifacts.content_addressed" => {}
                _ => {}
            }
        }

        if config.mode != "observe" {
            return Err(format!(
                "{}: Stage 1 only supports mode = \"observe\"",
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