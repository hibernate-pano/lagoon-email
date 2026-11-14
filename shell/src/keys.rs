//! The key file from contract §2 (under .dev in dev; the app data directory
//! in the product, mode 0600).
//!
//! Shape: `{ "tokenKey": "<base64 32B>", "bodyKey": "<base64 32B>", "apiToken": "<hex>", "llmApiKey"?: "<provider key>" }`
//! Generated once, mode 0600, never overwritten, never printed.
//!
//! The two base64 keys are passed straight to the sidecar as `LAGOON_TOKEN_KEY`
//! and `LAGOON_BODY_KEY`; the v1 CLI refuses a key that is not base64 of
//! exactly 32 bytes (Sources/LagoonServerCLI/main.swift:21-48), so this module
//! validates the same thing *before* spawning — a malformed key is a `keys`
//! failure, not a mysterious sidecar crash.
//!
//! `llmApiKey` is optional and is passed as `LLM_PROVIDER_PRIMARY_API_KEY` —
//! the name `config/providers.json` declares in `apiKeyEnv`. A packaged app
//! launched from Finder gets launchd's environment, not the shell's, so this
//! file is how a real user gives the AI its key without a terminal.

use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};

pub struct Keys {
    pub token_key: String,
    pub body_key: String,
    pub api_token: String,
    /// The LLM provider key, when the user put one in `keys.json`.
    pub llm_api_key: Option<String>,
}

/// Deliberately opaque: a `{:?}` on this struct must not leak key material.
impl std::fmt::Debug for Keys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(
            "Keys { token_key: <redacted>, body_key: <redacted>, api_token: <redacted>, llm_api_key: <redacted> }",
        )
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
    /// Optional: an install that never uses the AI has no such field.
    #[serde(rename = "llmApiKey", default)]
    llm_api_key: Option<String>,
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
        // An empty string is the same as no field: "not configured" must not
        // turn into "configured with nothing".
        llm_api_key: keys
            .llm_api_key
            .map(|key| key.trim().to_owned())
            .filter(|key| !key.is_empty()),
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
        // The generator never invents an AI key; the user adds `llmApiKey`
        // by hand when they want the advisor.
        llm_api_key: None,
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

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(label: &str) -> std::path::PathBuf {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "lagoon-keys-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&directory).expect("temp dir");
        directory
    }

    /// A key file as every install written before the AI existed has it:
    /// three fields, no `llmApiKey`. It must keep loading.
    #[test]
    fn a_key_file_without_an_ai_key_still_loads() {
        let directory = scratch("no-ai");
        let path = directory.join("keys.json");
        let json = format!(
            "{{\"tokenKey\":\"{}\",\"bodyKey\":\"{}\",\"apiToken\":\"abcd\"}}",
            B64.encode([7u8; 32]),
            B64.encode([9u8; 32]),
        );
        fs::write(&path, json).expect("write");
        let keys = load_or_generate(&path).expect("loads");
        assert_eq!(keys.api_token, "abcd");
        assert!(keys.llm_api_key.is_none(), "no field is no key");
        let _ = fs::remove_dir_all(&directory);
    }

    /// The AI key is read from the same 0600 file the other secrets live in,
    /// and surrounding whitespace (a pasted newline) is not part of the key.
    #[test]
    fn an_ai_key_is_read_and_trimmed() {
        let directory = scratch("ai");
        let path = directory.join("keys.json");
        let json = format!(
            "{{\"tokenKey\":\"{}\",\"bodyKey\":\"{}\",\"apiToken\":\"abcd\",\"llmApiKey\":\"  sk-test  \"}}",
            B64.encode([7u8; 32]),
            B64.encode([9u8; 32]),
        );
        fs::write(&path, json).expect("write");
        let keys = load_or_generate(&path).expect("loads");
        assert_eq!(keys.llm_api_key.as_deref(), Some("sk-test"));
        let _ = fs::remove_dir_all(&directory);
    }

    /// An empty value is "not set", never "configured with nothing": the
    /// backend must keep answering `configured:false` in that case.
    #[test]
    fn an_empty_ai_key_is_no_key() {
        let directory = scratch("empty-ai");
        let path = directory.join("keys.json");
        let json = format!(
            "{{\"tokenKey\":\"{}\",\"bodyKey\":\"{}\",\"apiToken\":\"abcd\",\"llmApiKey\":\"   \"}}",
            B64.encode([7u8; 32]),
            B64.encode([9u8; 32]),
        );
        fs::write(&path, json).expect("write");
        let keys = load_or_generate(&path).expect("loads");
        assert!(keys.llm_api_key.is_none());
        let _ = fs::remove_dir_all(&directory);
    }

    /// The Debug output must never carry key material, including the LLM key.
    #[test]
    fn debug_never_prints_a_key() {
        let keys = Keys {
            token_key: "token-secret".into(),
            body_key: "body-secret".into(),
            api_token: "api-secret".into(),
            llm_api_key: Some("llm-secret".into()),
        };
        let printed = format!("{keys:?}");
        assert!(!printed.contains("secret"));
        assert!(printed.contains("<redacted>"));
    }
}
