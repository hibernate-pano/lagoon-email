//! The credential cipher: v3's AccessTokenCipher.
//!
//! This is **not** the body envelope. v3 stores credentials as bare
//! AES.GCM.SealedBox.combined bytes (12-byte nonce || ciphertext || 16-byte tag,
//! no prefix, no base64) under a *different* key, LAGOON_TOKEN_KEY. Reusing
//! BodyKey here would produce an lgb1: string where v3 expects a BLOB and a
//! different key, which no amount of testing of the body path would catch.
//!
//! The plaintext is the JSON of AccountCredentials:
//! {"kind":"imap","username":"...","authCode":"..."}.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;

const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenCipherError {
    /// The key is not base64 or not exactly 32 bytes.
    BadKey(usize),
    /// Fewer bytes than a nonce plus a tag: cannot be a sealed box.
    TooShort(usize),
    /// AES-GCM authentication failed: wrong key or tampered blob.
    Decrypt,
    /// The plaintext is not valid UTF-8.
    NotUtf8,
}

impl std::fmt::Display for TokenCipherError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TokenCipherError::BadKey(length) => {
                write!(formatter, "token key is {length} bytes, need 32")
            }
            TokenCipherError::TooShort(length) => {
                write!(formatter, "sealed credential is too short ({length} bytes)")
            }
            TokenCipherError::Decrypt => formatter.write_str("AES-GCM authentication failed"),
            TokenCipherError::NotUtf8 => formatter.write_str("sealed credential is not UTF-8"),
        }
    }
}

impl std::error::Error for TokenCipherError {}

/// A 32-byte AES-256-GCM key for credential blobs. Debug is redacted.
#[derive(Clone, PartialEq, Eq)]
pub struct TokenKey([u8; KEY_LEN]);

impl TokenKey {
    /// Decode LAGOON_TOKEN_KEY (base64 of exactly 32 bytes).
    pub fn from_base64(raw: &str) -> Result<Self, TokenCipherError> {
        let bytes = BASE64
            .decode(raw.trim())
            .map_err(|_| TokenCipherError::BadKey(0))?;
        if bytes.len() != KEY_LEN {
            return Err(TokenCipherError::BadKey(bytes.len()));
        }
        let mut key = [0u8; KEY_LEN];
        key.copy_from_slice(&bytes);
        Ok(Self(key))
    }

    fn cipher(&self) -> Aes256Gcm {
        Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&self.0))
    }

    /// Seal a credential JSON string into the stored blob.
    ///
    /// The shape matches CryptoKit's SealedBox.combined: nonce first, then the
    /// ciphertext with its tag appended, in one buffer. No text encoding: the
    /// column is a BLOB.
    pub fn seal(&self, plaintext: &str) -> Result<Vec<u8>, TokenCipherError> {
        let mut nonce_bytes = [0u8; NONCE_LEN];
        crate::crypto::random_bytes(&mut nonce_bytes);
        let ciphertext_and_tag = self
            .cipher()
            .encrypt(
                Nonce::from_slice(&nonce_bytes),
                Payload {
                    msg: plaintext.as_bytes(),
                    aad: b"",
                },
            )
            .map_err(|_| TokenCipherError::Decrypt)?;
        let mut combined = Vec::with_capacity(NONCE_LEN + ciphertext_and_tag.len());
        combined.extend_from_slice(&nonce_bytes);
        combined.extend_from_slice(&ciphertext_and_tag);
        Ok(combined)
    }

    /// Open a stored credential blob back into its JSON text.
    pub fn open(&self, blob: &[u8]) -> Result<String, TokenCipherError> {
        if blob.len() < NONCE_LEN + TAG_LEN {
            return Err(TokenCipherError::TooShort(blob.len()));
        }
        let (nonce_bytes, ciphertext_and_tag) = blob.split_at(NONCE_LEN);
        let plaintext = self
            .cipher()
            .decrypt(
                Nonce::from_slice(nonce_bytes),
                Payload {
                    msg: ciphertext_and_tag,
                    aad: b"",
                },
            )
            .map_err(|_| TokenCipherError::Decrypt)?;
        String::from_utf8(plaintext).map_err(|_| TokenCipherError::NotUtf8)
    }
}

impl std::fmt::Debug for TokenKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("TokenKey(<redacted 32 bytes>)")
    }
}

/// The plaintext v3 keeps in accounts.credentials.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImapCredentials {
    pub username: String,
    pub auth_code: String,
}

impl ImapCredentials {
    pub fn new(username: impl Into<String>, auth_code: impl Into<String>) -> Self {
        Self {
            username: username.into(),
            auth_code: auth_code.into(),
        }
    }

    /// Serialize exactly the keys v3's AccountCredentials encodes.
    ///
    /// JSONEncoder emits the enum as a flat object with a kind tag; order is
    /// not significant to Codable, and a decoder that required an order would
    /// be broken against v3 itself.
    pub fn to_json(&self) -> String {
        serde_json::json!({
            "kind": "imap",
            "username": self.username,
            "authCode": self.auth_code,
        })
        .to_string()
    }

    pub fn from_json(raw: &str) -> Option<Self> {
        let value: serde_json::Value = serde_json::from_str(raw).ok()?;
        if value.get("kind")?.as_str()? != "imap" {
            return None;
        }
        Some(Self {
            username: value.get("username")?.as_str()?.to_owned(),
            auth_code: value.get("authCode")?.as_str()?.to_owned(),
        })
    }

    /// Seal with the token key, the one writer path v3 uses.
    pub fn seal(&self, key: &TokenKey) -> Result<Vec<u8>, TokenCipherError> {
        key.seal(&self.to_json())
    }

    pub fn open(key: &TokenKey, blob: &[u8]) -> Result<Self, TokenCipherError> {
        let raw = key.open(blob)?;
        Self::from_json(&raw).ok_or(TokenCipherError::NotUtf8)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Base64 of the ASCII seed "fedcba9876543210fedcba9876543210" - a test
    /// vector, never a real Keychain value.
    fn key() -> TokenKey {
        TokenKey::from_base64(&BASE64.encode(b"fedcba9876543210fedcba9876543210"))
            .expect("vector key")
    }

    /// Produced by CryptoKit with the exact primitive v3's AccessTokenCipher
    /// uses, on 2026-10-29 via scripts/token-tool.swift:
    ///
    ///     scripts/token-tool.swift seal <key> <plaintext>
    ///
    /// The plaintext is the JSON below. The point of embedding it is that the
    /// test proves interoperability with the other implementation, not that
    /// this crate can open its own output.
    const CRYPTOKIT_BLOB: &str = "nbBlyaHYSW+z9xIULWVVcODx42BuzPec+7e49bBSkA2ZZD2IjRej7cthT6ZmV6ykSzBNZ3qfUhqDyc6MGk7etJUBxydOZXaoMzSKztFXKW2YF1uArVL6JfQ4ocyo89DxltvuaOVBmDRl4c4e7mec0yYfAg==";

    #[test]
    fn opens_a_blob_produced_by_cryptokit() {
        let blob = BASE64.decode(CRYPTOKIT_BLOB).expect("fixture base64");
        assert_eq!(blob.len(), 12 + 87 + 16, "combined layout: nonce || ct || tag");
        let plaintext = key().open(&blob).expect("open CryptoKit blob");
        assert_eq!(
            plaintext,
            r#"{"kind":"imap","username":"v3-blob@example.invalid","authCode":"v3-produced-auth-code"}"#
        );
        let credentials = ImapCredentials::open(&key(), &blob).expect("decode credentials");
        assert_eq!(credentials.username, "v3-blob@example.invalid");
        assert_eq!(credentials.auth_code, "v3-produced-auth-code");
    }

    #[test]
    fn round_trips_credential_json_and_rejects_tampering() {
        let key = key();
        let credentials = ImapCredentials::new("a@b", "code");
        let blob = credentials.seal(&key).expect("seal");
        assert_eq!(blob.len(), 12 + credentials.to_json().len() + 16);
        assert_eq!(ImapCredentials::open(&key, &blob).expect("open"), credentials);
        let mut tampered = blob.clone();
        tampered[12] ^= 0xFF;
        assert_eq!(key.open(&tampered), Err(TokenCipherError::Decrypt));
        assert_eq!(key.open(&blob[..27]), Err(TokenCipherError::TooShort(27)));
    }

    #[test]
    fn the_body_key_is_not_the_token_key() {
        // Same base64 seed, different type: the two keys must not be
        // interchangeable, because one seals text envelopes and the other
        // seals binary credential blobs.
        let body = crate::crypto::BodyKey::from_base64(&BASE64.encode(b"fedcba9876543210fedcba9876543210"))
            .expect("body key");
        let envelope = body.seal("{\"kind\":\"imap\"}").expect("seal body");
        assert!(envelope.starts_with("lgb1:"));
        // A credential blob is not an lgb1: envelope and has no text prefix.
        let credential = key().seal("{\"kind\":\"imap\"}").expect("seal credential");
        assert!(!credential.starts_with(b"lgb1:"));
    }
}
