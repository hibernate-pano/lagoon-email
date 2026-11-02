//! The dev-time key file from contract §2 (under v4/.dev, mode 0600).
//!
//! Shape: `{ "tokenKey": "<base64 32B>", "bodyKey": "<base64 32B>", "apiToken": "<hex>" }`
//! Generated once, mode 0600, never overwritten, never printed.
//!
//! The two base64 keys are passed straight to the sidecar as `LAGOON_TOKEN_KEY`
//! and `LAGOON_BODY_KEY`; the v1 CLI refuses a key that is not base64 of
//! exactly 32 bytes (Sources/LagoonServerCLI/main.swift:21-48), so this module
//! validates the same thing *before* spawning — a malformed key is a `keys`
//! failure, not a mysterious sidecar crash.

use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};

pub struct Keys {
    pub token_key: String,
    pub body_key: String,
    pub api_token: String,
}

/// Deliberately opaque: a `{:?}` on this struct must not leak key material.
impl std::fmt::Debug for Keys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Keys { token_key: <redacted>, body_key: <redacted>, api_token: <redacted> }")
    }
}

#[derive(serde::Deserialize)]
struct KeysFile {
    #[serde(rename = "tokenKey")]
    token_key: String,
    #[serde(rename = "bodyKey")]
    body_key: String,
    #[serde(rename = "apiToken")]
    api_token: String,
}

fn random_bytes(n: usize) -> Result<Vec<u8>, String> {
    let mut file = fs::File::open("/dev/urandom").map_err(|e| format!("open /dev/urandom: {e}"))?;
    let mut buf = vec![0u8; n];
    file.read_exact(&mut buf)
        .map_err(|e| format!("read /dev/urandom: {e}"))?;
    Ok(buf)
}

fn is_32_byte_b64(value: &str) -> bool {
    B64.decode(value).map(|d| d.len() == 32).unwrap_or(false)
}

fn validate(keys: KeysFile) -> Result<Keys, String> {
    if !is_32_byte_b64(&keys.token_key) {
        return Err("keys.json: tokenKey is not base64 of 32 bytes".into());
    }
    if !is_32_byte_b64(&keys.body_key) {
        return Err("keys.json: bodyKey is not base64 of 32 bytes".into());
    }
    if keys.api_token.trim().is_empty() {
        return Err("keys.json: apiToken is empty".into());
    }
    Ok(Keys {
        token_key: keys.token_key,
        body_key: keys.body_key,
        api_token: keys.api_token,
    })
}

/// Read `path`, or create it once with mode 0600. Never overwrites.
pub fn load_or_generate(path: &Path) -> Result<Keys, String> {
    if path.exists() {
        let text = fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))?;
        let parsed: KeysFile =
            serde_json::from_str(&text).map_err(|e| format!("parse {}: {e}", path.display()))?;
        return validate(parsed);
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
        let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
    }

    let keys = KeysFile {
        token_key: B64.encode(random_bytes(32)?),
        body_key: B64.encode(random_bytes(32)?),
        api_token: random_bytes(24)?
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
    };
    let json = format!(
        "{{\"tokenKey\":\"{}\",\"bodyKey\":\"{}\",\"apiToken\":\"{}\"}}\n",
        keys.token_key, keys.body_key, keys.api_token
    );
    // create_new + mode(0o600): never clobber an existing file, never let the
    // window between "does it exist" and "write it" produce a world-readable key.
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("create {}: {e}", path.display()))?;
    file.write_all(json.as_bytes())
        .map_err(|e| format!("write {}: {e}", path.display()))?;
    file.sync_all().ok();
    eprintln!("[keys] generated {} (mode 0600)", path.display());
    validate(keys)
}
