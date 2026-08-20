use crate::util::{atomic_write, sync_dir, unique_id, unix_seconds};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default)]
pub struct ArtifactMetadata {
    pub source_event_id: Option<String>,
    pub model: Option<String>,
    pub surface: Option<String>,
    pub claim_saved_bytes: u64,
}

#[derive(Clone, Debug)]
pub struct ArtifactManifest {
    pub id: String,
    pub sha256: String,
    pub byte_length: u64,
    pub created_at: u64,
    pub kind: String,
    pub expires_at: u64,
    pub pinned: bool,
    pub source_event_id: Option<String>,
    pub model: Option<String>,
    pub surface: Option<String>,
    pub claim_saved_bytes: u64,
}

impl ArtifactManifest {
    pub fn to_value(&self) -> Value {
        json!({
            "version": 1,
            "id": self.id,
            "sha256": self.sha256,
            "byte_length": self.byte_length,
            "created_at": self.created_at,
            "kind": self.kind,
            "expires_at": self.expires_at,
            "pinned": self.pinned,
            "source_event_id": self.source_event_id,
            "model": self.model,
            "surface": self.surface,
            "claim_saved_bytes": self.claim_saved_bytes,
        })
    }

    pub fn from_value(value: &Value) -> Result<Self, String> {
        Ok(Self {
            id: required_string(value, "id")?,
            sha256: required_string(value, "sha256")?,
            byte_length: required_u64(value, "byte_length")?,
            created_at: required_u64(value, "created_at")?,
            kind: required_string(value, "kind")?,
            expires_at: required_u64(value, "expires_at")?,
            pinned: value
                .get("pinned")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            source_event_id: optional_string(value, "source_event_id"),
            model: optional_string(value, "model"),
            surface: optional_string(value, "surface"),
            claim_saved_bytes: value
                .get("claim_saved_bytes")
                .and_then(Value::as_u64)
                .unwrap_or(0),
        })
    }
}

pub struct ArtifactStore {
    root: PathBuf,
    ttl_days: u64,
    quota_bytes: u64,
}

pub struct StagedArtifact {
    path: PathBuf,
    marker_path: PathBuf,
    file: File,
    persisted_bytes: u64,
}

#[derive(Clone, Debug, Default)]
pub struct GcReport {
    pub removed_artifacts: u64,
    pub removed_bytes: u64,
    pub removed_incoming: u64,
    pub retained_artifacts: u64,
    pub retained_bytes: u64,
    pub pinned_artifacts: u64,
    pub corrupt_manifests: u64,
}

#[derive(Clone, Debug, Default)]
pub struct StoreStatus {
    pub artifacts: u64,
    pub bytes: u64,
    pub pinned: u64,
    pub corrupt_manifests: u64,
}

impl ArtifactStore {
    pub fn new(state: &Path, ttl_days: u64, quota_bytes: u64) -> Result<Self, String> {
        let root = state.join("compress/artifacts");
        fs::create_dir_all(root.join("objects"))
            .map_err(|error| format!("cannot create artifact objects directory: {error}"))?;
        fs::create_dir_all(root.join("manifests"))
            .map_err(|error| format!("cannot create artifact manifests directory: {error}"))?;
        fs::create_dir_all(root.join("incoming"))
            .map_err(|error| format!("cannot create artifact incoming directory: {error}"))?;

        Ok(Self {
            root,
            ttl_days,
            quota_bytes,
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn put_bytes(
        &self,
        bytes: &[u8],
        kind: &str,
        pinned: bool,
        metadata: &ArtifactMetadata,
    ) -> Result<ArtifactManifest, String> {
        let temporary = self
            .root
            .join("incoming")
            .join(format!("{}.put", unique_id("put")));

        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|error| format!("cannot create artifact staging file: {error}"))?;

        file.write_all(bytes)
            .map_err(|error| format!("cannot stage artifact: {error}"))?;
        file.flush()
            .map_err(|error| format!("cannot flush artifact staging file: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("cannot sync artifact staging file: {error}"))?;
        drop(file);

        let result = self.put_file(&temporary, kind, pinned, metadata);
        let _ = fs::remove_file(&temporary);
        result
    }

    pub fn put_file(
        &self,
        source: &Path,
        kind: &str,
        pinned: bool,
        metadata: &ArtifactMetadata,
    ) -> Result<ArtifactManifest, String> {
        let (hash_bytes, hash_hex, byte_length) = hash_file(source)?;
        let handle = self.select_handle(&hash_bytes, &hash_hex)?;
        let object_path = self.object_path(&hash_hex);

        if let Some(parent) = object_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("cannot create artifact object directory: {error}"))?;
        }

        if !object_path.exists() {
            copy_atomic(source, &object_path)?;
        }

        let manifest_path = self.manifest_path(&handle);
        if manifest_path.exists() {
            let existing = self.load_manifest_path(&manifest_path)?;
            if existing.sha256 != hash_hex {
                return Err(format!(
                    "artifact handle collision for {handle}: hashes differ"
                ));
            }
            return Ok(existing);
        }

        let created_at = unix_seconds();
        let expires_at = created_at.saturating_add(self.ttl_days.saturating_mul(86_400));
        let manifest = ArtifactManifest {
            id: handle,
            sha256: hash_hex,
            byte_length,
            created_at,
            kind: kind.to_string(),
            expires_at,
            pinned,
            source_event_id: metadata.source_event_id.clone(),
            model: metadata.model.clone(),
            surface: metadata.surface.clone(),
            claim_saved_bytes: metadata.claim_saved_bytes,
        };

        let encoded = serde_json::to_vec_pretty(&manifest.to_value())
            .map_err(|error| format!("cannot encode artifact manifest: {error}"))?;
        atomic_write(&manifest_path, &encoded)
            .map_err(|error| format!("cannot persist artifact manifest: {error}"))?;

        Ok(manifest)
    }

    pub fn begin_stream(
        &self,
        event_id: &str,
        kind: &str,
    ) -> Result<StagedArtifact, String> {
        let safe_event_id: String = event_id
            .chars()
            .map(|character| {
                if character.is_ascii_alphanumeric() || matches!(character, '_' | '-') {
                    character
                } else {
                    '_'
                }
            })
            .collect();

        let path = self
            .root
            .join("incoming")
            .join(format!("{safe_event_id}.stream"));
        let marker_path = self
            .root
            .join("incoming")
            .join(format!("{safe_event_id}.manifest.json"));

        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .map_err(|error| format!("cannot create streaming artifact spool: {error}"))?;

        let marker = json!({
            "version": 1,
            "state": "in_progress",
            "event_id": event_id,
            "kind": kind,
            "created_at": unix_seconds(),
            "path": path,
        });
        let marker_bytes = serde_json::to_vec_pretty(&marker)
            .map_err(|error| format!("cannot encode streaming artifact marker: {error}"))?;
        atomic_write(&marker_path, &marker_bytes)
            .map_err(|error| format!("cannot persist streaming artifact marker: {error}"))?;

        Ok(StagedArtifact {
            path,
            marker_path,
            file,
            persisted_bytes: 0,
        })
    }

    pub fn finalize_stream(
        &self,
        mut staged: StagedArtifact,
        kind: &str,
        pinned: bool,
        metadata: &ArtifactMetadata,
    ) -> Result<ArtifactManifest, String> {
        staged
            .file
            .flush()
            .map_err(|error| format!("cannot flush streaming artifact: {error}"))?;
        staged
            .file
            .sync_all()
            .map_err(|error| format!("cannot sync streaming artifact: {error}"))?;
        drop(staged.file);

        let manifest = self.put_file(&staged.path, kind, pinned, metadata)?;
        fs::remove_file(&staged.path)
            .map_err(|error| format!("cannot remove finalized stream spool: {error}"))?;
        let _ = fs::remove_file(&staged.marker_path);
        sync_dir(&self.root.join("incoming"))
            .map_err(|error| format!("cannot sync incoming artifact directory: {error}"))?;

        Ok(manifest)
    }

    pub fn manifest(&self, id: &str) -> Result<ArtifactManifest, String> {
        validate_handle(id)?;
        self.load_manifest_path(&self.manifest_path(id))
    }

    pub fn read(&self, id: &str) -> Result<Vec<u8>, String> {
        let manifest = self.manifest(id)?;
        let bytes = fs::read(self.object_path(&manifest.sha256))
            .map_err(|error| format!("cannot read artifact {id}: {error}"))?;

        let actual = sha256_hex(&bytes);
        if actual != manifest.sha256 {
            return Err(format!(
                "artifact {id} failed hash verification: expected {}, got {actual}",
                manifest.sha256
            ));
        }

        if bytes.len() as u64 != manifest.byte_length {
            return Err(format!(
                "artifact {id} failed length verification: expected {}, got {}",
                manifest.byte_length,
                bytes.len()
            ));
        }

        Ok(bytes)
    }

    pub fn status(&self) -> Result<StoreStatus, String> {
        let mut status = StoreStatus::default();

        for path in manifest_paths(&self.root)? {
            match self.load_manifest_path(&path) {
                Ok(manifest) => {
                    status.artifacts = status.artifacts.saturating_add(1);
                    status.bytes = status.bytes.saturating_add(manifest.byte_length);
                    if manifest.pinned {
                        status.pinned = status.pinned.saturating_add(1);
                    }
                }
                Err(_) => status.corrupt_manifests = status.corrupt_manifests.saturating_add(1),
            }
        }

        Ok(status)
    }

    pub fn gc(&self) -> Result<GcReport, String> {
        let now = unix_seconds();
        let mut report = GcReport::default();
        let mut retained = Vec::new();

        for path in manifest_paths(&self.root)? {
            match self.load_manifest_path(&path) {
                Ok(manifest) => {
                    if !manifest.pinned && manifest.expires_at <= now {
                        self.remove_manifest_and_object(&manifest)?;
                        report.removed_artifacts =
                            report.removed_artifacts.saturating_add(1);
                        report.removed_bytes =
                            report.removed_bytes.saturating_add(manifest.byte_length);
                    } else {
                        retained.push(manifest);
                    }
                }
                Err(_) => report.corrupt_manifests =
                    report.corrupt_manifests.saturating_add(1),
            }
        }

        retained.sort_by_key(|manifest| manifest.created_at);
        let mut total: u64 = retained.iter().map(|manifest| manifest.byte_length).sum();

        for manifest in &retained {
            if total <= self.quota_bytes {
                break;
            }
            if manifest.pinned {
                continue;
            }

            self.remove_manifest_and_object(manifest)?;
            total = total.saturating_sub(manifest.byte_length);
            report.removed_artifacts = report.removed_artifacts.saturating_add(1);
            report.removed_bytes = report.removed_bytes.saturating_add(manifest.byte_length);
        }

        let incoming = self.root.join("incoming");
        if let Ok(entries) = fs::read_dir(&incoming) {
            for entry in entries.flatten() {
                let path = entry.path();
                let age = entry
                    .metadata()
                    .ok()
                    .and_then(|metadata| metadata.modified().ok())
                    .and_then(|modified| modified.elapsed().ok())
                    .map(|duration| duration.as_secs())
                    .unwrap_or(0);

                if age >= self.ttl_days.saturating_mul(86_400) {
                    if fs::remove_file(&path).is_ok() {
                        report.removed_incoming =
                            report.removed_incoming.saturating_add(1);
                    }
                }
            }
        }

        let status = self.status()?;
        report.retained_artifacts = status.artifacts;
        report.retained_bytes = status.bytes;
        report.pinned_artifacts = status.pinned;
        report.corrupt_manifests =
            report.corrupt_manifests.saturating_add(status.corrupt_manifests);

        Ok(report)
    }

    fn remove_manifest_and_object(&self, manifest: &ArtifactManifest) -> Result<(), String> {
        let object_path = self.object_path(&manifest.sha256);
        let manifest_path = self.manifest_path(&manifest.id);

        if object_path.exists() {
            fs::remove_file(&object_path).map_err(|error| {
                format!("cannot remove artifact object {}: {error}", object_path.display())
            })?;
        }

        if manifest_path.exists() {
            fs::remove_file(&manifest_path).map_err(|error| {
                format!(
                    "cannot remove artifact manifest {}: {error}",
                    manifest_path.display()
                )
            })?;
        }

        Ok(())
    }

    fn select_handle(&self, hash: &[u8; 32], hash_hex: &str) -> Result<String, String> {
        let encoded = base32(hash);

        for length in (4..=encoded.len()).step_by(2) {
            let handle = format!("bc_{}", &encoded[..length]);
            let manifest_path = self.manifest_path(&handle);

            if !manifest_path.exists() {
                return Ok(handle);
            }

            let manifest = self.load_manifest_path(&manifest_path)?;
            if manifest.sha256 == hash_hex {
                return Ok(handle);
            }
        }

        Err("could not allocate a collision-free artifact handle".to_string())
    }

    fn object_path(&self, hash: &str) -> PathBuf {
        let prefix = hash.get(..2).unwrap_or("00");
        self.root
            .join("objects")
            .join(prefix)
            .join(format!("{hash}.blob"))
    }

    fn manifest_path(&self, id: &str) -> PathBuf {
        self.root.join("manifests").join(format!("{id}.json"))
    }

    fn load_manifest_path(&self, path: &Path) -> Result<ArtifactManifest, String> {
        let bytes = fs::read(path)
            .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|error| format!("cannot parse {}: {error}", path.display()))?;
        ArtifactManifest::from_value(&value)
    }
}

impl StagedArtifact {
    pub fn append_persisted(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.file
            .write_all(bytes)
            .map_err(|error| format!("cannot append streaming artifact: {error}"))?;
        self.file
            .flush()
            .map_err(|error| format!("cannot flush streaming artifact: {error}"))?;
        self.file
            .sync_data()
            .map_err(|error| format!("cannot sync streaming artifact: {error}"))?;
        self.persisted_bytes = self.persisted_bytes.saturating_add(bytes.len() as u64);
        Ok(())
    }

    pub fn assert_persisted_at_least(&self, expected: u64) -> Result<(), String> {
        if self.persisted_bytes < expected {
            return Err(format!(
                "lossy-view ordering invariant failed: only {} of {expected} source bytes are durable",
                self.persisted_bytes
            ));
        }

        let disk_length = fs::metadata(&self.path)
            .map_err(|error| format!("cannot stat streaming artifact: {error}"))?
            .len();

        if disk_length < expected {
            return Err(format!(
                "lossy-view ordering invariant failed: disk contains only {disk_length} of {expected} source bytes"
            ));
        }

        Ok(())
    }
}

fn validate_handle(id: &str) -> Result<(), String> {
    // Handles are the literal lowercase prefix `bc_` followed by a base32
    // (Crockford, uppercase + digits) body. Validate only the body: the prefix
    // is a fixed literal, so folding it into the all-uppercase check would
    // reject every handle this module generates.
    let body = match id.strip_prefix("bc_") {
        Some(body) => body,
        None => return Err(format!("invalid artifact handle: {id}")),
    };
    if id.len() < 7
        || body.is_empty()
        || !body
            .chars()
            .all(|character| character.is_ascii_uppercase() || character.is_ascii_digit())
    {
        return Err(format!("invalid artifact handle: {id}"));
    }
    Ok(())
}

fn manifest_paths(root: &Path) -> Result<Vec<PathBuf>, String> {
    let directory = root.join("manifests");
    let mut paths = Vec::new();

    let entries = fs::read_dir(&directory)
        .map_err(|error| format!("cannot read {}: {error}", directory.display()))?;

    for entry in entries {
        let entry = entry
            .map_err(|error| format!("cannot read artifact manifest directory entry: {error}"))?;
        let path = entry.path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("json") {
            paths.push(path);
        }
    }

    Ok(paths)
}

fn copy_atomic(source: &Path, destination: &Path) -> Result<(), String> {
    let parent = destination
        .parent()
        .ok_or_else(|| "artifact destination has no parent".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("cannot create {}: {error}", parent.display()))?;

    let temporary = parent.join(format!(
        ".object.tmp-{}-{}",
        std::process::id(),
        crate::util::unix_millis()
    ));

    let mut input = File::open(source)
        .map_err(|error| format!("cannot open {}: {error}", source.display()))?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| format!("cannot create {}: {error}", temporary.display()))?;

    std::io::copy(&mut input, &mut output)
        .map_err(|error| format!("cannot copy artifact object: {error}"))?;
    output
        .flush()
        .map_err(|error| format!("cannot flush artifact object: {error}"))?;
    output
        .sync_all()
        .map_err(|error| format!("cannot sync artifact object: {error}"))?;
    drop(output);

    match fs::rename(&temporary, destination) {
        Ok(()) => {}
        Err(error) if destination.exists() => {
            let _ = fs::remove_file(&temporary);
            if !destination.exists() {
                return Err(format!(
                    "artifact object disappeared after rename conflict: {error}"
                ));
            }
        }
        Err(error) => {
            let _ = fs::remove_file(&temporary);
            return Err(format!("cannot install artifact object: {error}"));
        }
    }

    sync_dir(parent).map_err(|error| format!("cannot sync artifact object directory: {error}"))
}

fn hash_file(path: &Path) -> Result<([u8; 32], String, u64), String> {
    let mut file = File::open(path)
        .map_err(|error| format!("cannot open {} for hashing: {error}", path.display()))?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| format!("cannot seek {}: {error}", path.display()))?;

    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    let mut length = 0_u64;

    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|error| format!("cannot hash {}: {error}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
        length = length.saturating_add(count as u64);
    }

    let digest = hasher.finalize();
    let mut bytes = [0_u8; 32];
    bytes.copy_from_slice(&digest);
    let hex = hex_encode(&bytes);
    Ok((bytes, hex, length))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    hex_encode(&digest)
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);

    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }

    output
}

fn base32(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 32] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
    let mut output = String::new();
    let mut accumulator = 0_u32;
    let mut bits = 0_u8;

    for byte in bytes {
        accumulator = (accumulator << 8) | u32::from(*byte);
        bits += 8;

        while bits >= 5 {
            bits -= 5;
            let index = ((accumulator >> bits) & 0x1f) as usize;
            output.push(ALPHABET[index] as char);
        }
    }

    if bits > 0 {
        let index = ((accumulator << (5 - bits)) & 0x1f) as usize;
        output.push(ALPHABET[index] as char);
    }

    output
}

fn required_string(value: &Value, field: &str) -> Result<String, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| format!("artifact manifest field {field} is missing or invalid"))
}

fn optional_string(value: &Value, field: &str) -> Option<String> {
    value.get(field).and_then(Value::as_str).map(str::to_string)
}

fn required_u64(value: &Value, field: &str) -> Result<u64, String> {
    value
        .get(field)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("artifact manifest field {field} is missing or invalid"))
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
            "brain-compress-artifact-test-{name}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn artifact_round_trip_verifies_hash_and_length() {
        let state = temporary_state("round-trip");
        let store = ArtifactStore::new(&state, 30, 1024 * 1024).unwrap();
        let manifest = store
            .put_bytes(
                b"exact source bytes",
                "test",
                false,
                &ArtifactMetadata::default(),
            )
            .unwrap();

        assert!(manifest.id.starts_with("bc_"));
        assert_eq!(manifest.byte_length, 18);
        assert_eq!(store.read(&manifest.id).unwrap(), b"exact source bytes");

        let manifest_again = store.manifest(&manifest.id).unwrap();
        assert_eq!(manifest.sha256, manifest_again.sha256);
        assert_eq!(manifest.byte_length, manifest_again.byte_length);

        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn quota_gc_evicts_unpinned_but_keeps_pinned() {
        let state = temporary_state("quota");
        let store = ArtifactStore::new(&state, 30, 10).unwrap();

        let pinned = store
            .put_bytes(
                b"12345678",
                "pinned-test",
                true,
                &ArtifactMetadata::default(),
            )
            .unwrap();
        let unpinned = store
            .put_bytes(
                b"abcdefgh",
                "unpinned-test",
                false,
                &ArtifactMetadata::default(),
            )
            .unwrap();

        let report = store.gc().unwrap();
        assert_eq!(report.removed_artifacts, 1);
        assert_eq!(store.read(&pinned.id).unwrap(), b"12345678");
        assert!(store.read(&unpinned.id).is_err());

        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn streaming_spool_is_durable_before_view_is_allowed() {
        let state = temporary_state("stream");
        let store = ArtifactStore::new(&state, 30, 1024).unwrap();
        let mut staged = store.begin_stream("event-1", "raw_sse").unwrap();

        staged.append_persisted(b"event: message\n").unwrap();
        staged.assert_persisted_at_least(15).unwrap();

        let manifest = store
            .finalize_stream(
                staged,
                "raw_sse",
                false,
                &ArtifactMetadata::default(),
            )
            .unwrap();
        assert_eq!(store.read(&manifest.id).unwrap(), b"event: message\n");

        fs::remove_dir_all(state).unwrap();
    }
}