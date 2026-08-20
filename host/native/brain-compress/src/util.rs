use libc::{flock, LOCK_EX, LOCK_UN};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static UNIQUE_COUNTER: AtomicU64 = AtomicU64::new(1);

pub fn home_dir() -> Result<PathBuf, String> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set".to_string())
}

pub fn state_dir() -> Result<PathBuf, String> {
    if let Some(value) = env::var_os("BRAIN_STATE_DIR") {
        return Ok(make_absolute(PathBuf::from(value))?);
    }

    Ok(home_dir()?.join(".local/state/brain"))
}

pub fn token_path() -> Result<PathBuf, String> {
    Ok(home_dir()?.join(".config/brain/token"))
}

pub fn make_absolute(path: PathBuf) -> Result<PathBuf, String> {
    if path.is_absolute() {
        return Ok(path);
    }

    env::current_dir()
        .map(|cwd| cwd.join(path))
        .map_err(|error| format!("cannot resolve an absolute path: {error}"))
}

pub fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub fn unix_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

pub fn unique_id(prefix: &str) -> String {
    let counter = UNIQUE_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!(
        "{prefix}_{:x}_{:x}_{:x}",
        unix_millis(),
        std::process::id(),
        counter
    )
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent"))?;
    fs::create_dir_all(parent)?;

    let file_name = path
        .file_name()
        .map(|name| name.to_string_lossy())
        .unwrap_or_default();
    let temp_path = parent.join(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        UNIQUE_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));

    let mut options = OpenOptions::new();
    options
        .write(true)
        .create_new(true)
        .mode(0o600);

    let mut file = options.open(&temp_path)?;
    file.write_all(bytes)?;
    file.flush()?;
    file.sync_all()?;
    drop(file);

    fs::rename(&temp_path, path)?;
    sync_dir(parent)?;
    Ok(())
}

pub fn sync_dir(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}

pub fn read_to_string(path: &Path) -> Result<String, String> {
    fs::read_to_string(path).map_err(|error| format!("cannot read {}: {error}", path.display()))
}

pub fn read_all(path: &Path) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|error| format!("cannot read {}: {error}", path.display()))
}

pub fn stdin_to_string() -> Result<String, String> {
    let mut value = String::new();
    io::stdin()
        .read_to_string(&mut value)
        .map_err(|error| format!("cannot read stdin: {error}"))?;
    Ok(value)
}

pub fn stdin_is_tty() -> bool {
    unsafe { libc::isatty(libc::STDIN_FILENO) == 1 }
}

pub fn compression_kill_switch(state: &Path) -> Option<String> {
    if env::var("BRAIN_COMPRESS")
        .ok()
        .map(|value| value.trim() == "0")
        .unwrap_or(false)
    {
        return Some("BRAIN_COMPRESS=0".to_string());
    }

    let marker = state.join("compress/DISABLED");
    if marker.exists() {
        return Some(marker.display().to_string());
    }

    None
}

pub struct FileLock {
    file: File,
}

impl FileLock {
    pub fn acquire(path: &Path) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("cannot create {}: {error}", parent.display()))?;
        }

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .open(path)
            .map_err(|error| format!("cannot open lock {}: {error}", path.display()))?;

        loop {
            let result = unsafe { flock(file.as_raw_fd(), LOCK_EX) };
            if result == 0 {
                break;
            }

            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(format!("cannot lock {}: {error}", path.display()));
            }
        }

        Ok(Self { file })
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        unsafe {
            flock(self.file.as_raw_fd(), LOCK_UN);
        }
    }
}

pub fn human_bytes(bytes: u64) -> String {
    const KIB: f64 = 1024.0;
    const MIB: f64 = KIB * 1024.0;
    const GIB: f64 = MIB * 1024.0;

    let value = bytes as f64;
    if value >= GIB {
        format!("{:.1} GiB", value / GIB)
    } else if value >= MIB {
        format!("{:.1} MiB", value / MIB)
    } else if value >= KIB {
        format!("{:.1} KiB", value / KIB)
    } else {
        format!("{bytes} B")
    }
}

pub fn grouped_u64(value: u64) -> String {
    let digits = value.to_string();
    let mut output = String::with_capacity(digits.len() + digits.len() / 3);

    for (index, character) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            output.push(',');
        }
        output.push(character);
    }

    output
}

pub fn parse_bool(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => Some(true),
        "false" | "0" | "no" | "off" => Some(false),
        _ => None,
    }
}

pub fn strip_inline_comment(line: &str) -> &str {
    let mut quoted = false;
    let mut escaped = false;

    for (index, character) in line.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }

        match character {
            '\\' if quoted => escaped = true,
            '"' => quoted = !quoted,
            '#' if !quoted => return &line[..index],
            _ => {}
        }
    }

    line
}

pub fn unquote(value: &str) -> String {
    let value = value.trim();
    if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
        value[1..value.len() - 1]
            .replace("\\\"", "\"")
            .replace("\\\\", "\\")
    } else {
        value.to_string()
    }
}

pub fn command_in_path(command: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;

    for directory in env::split_paths(&path) {
        let candidate = directory.join(command);
        if candidate.is_file() {
            return Some(candidate);
        }
    }

    None
}

pub fn write_stderr_body(body: &[u8], secret: &str) {
    let mut rendered = body.to_vec();

    if !secret.is_empty() {
        let secret_bytes = secret.as_bytes();
        if secret_bytes.len() <= rendered.len() {
            let mut index = 0;
            while index + secret_bytes.len() <= rendered.len() {
                if &rendered[index..index + secret_bytes.len()] == secret_bytes {
                    rendered.splice(
                        index..index + secret_bytes.len(),
                        b"[REDACTED]".iter().copied(),
                    );
                    index += b"[REDACTED]".len();
                } else {
                    index += 1;
                }
            }
        }
    }

    let mut stderr = io::stderr().lock();
    let _ = stderr.write_all(&rendered);
    if !rendered.ends_with(b"\n") {
        let _ = stderr.write_all(b"\n");
    }
    let _ = stderr.flush();
}

pub fn file_length(path: &Path) -> Result<u64, String> {
    fs::metadata(path)
        .map(|metadata| metadata.len())
        .map_err(|error| format!("cannot stat {}: {error}", path.display()))
}