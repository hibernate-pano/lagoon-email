//! The `lgb1:` body envelope - v3's `BodyCipher` (Sources/LagoonKit/BodyCipher.swift).
//!
//! Sealed values are stored as `lgb1:` + base64(`AES.GCM.SealedBox.combined`),
//! where `combined` is the 12-byte nonce followed by ciphertext and the
//! 16-byte authentication tag. There is **no AAD**, the key is AES-256, and
//! the format is versioned by its prefix so a future format can be told apart
//! from this one.
//!
//! Only the body key is needed for R1: `message_bodies.body_cipher`,
//! `body_html_cipher` and `message_headers.snippet_cipher` are sealed with it.
//! Credentials are sealed with a *different* key (`lagoon.tokenKey`) and are
//! never read here - their encryption is irrelevant to a read-only API.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;

/// Prefix of a sealed value. Versioned; the reader refuses anything else.
pub const ENVELOPE_PREFIX: &str = "lgb1:";

const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;

/// Why a stored value could not be opened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CipherError {
    /// The value does not start with `lgb1:` - v3's `BodyCipherError.notSealed`.
    NotSealed,
    /// The base64 body (or the key) is not decodable.
    Base64,
    /// Fewer bytes than one nonce plus one tag.
    TooShort(usize),
    /// AES-GCM authentication failed: wrong key or tampered bytes.
    Decrypt,
    /// The plaintext is not valid UTF-8.
    NotUtf8,
    /// The key is not 32 bytes.
    BadKey(usize),
}

impl std::fmt::Display for CipherError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CipherError::NotSealed => formatter.write_str("not an lgb1: envelope"),
            CipherError::Base64 => formatter.write_str("envelope is not base64"),
            CipherError::TooShort(length) => {
                write!(formatter, "envelope is too short ({length} bytes)")
            }
            CipherError::Decrypt => formatter.write_str("AES-GCM authentication failed"),
            CipherError::NotUtf8 => formatter.write_str("sealed value is not valid UTF-8"),
            CipherError::BadKey(length) => write!(formatter, "body key is {length} bytes, need 32"),
        }
    }
}

impl std::error::Error for CipherError {}

/// A 32-byte AES-256-GCM key. Debug is redacted so a key cannot reach a log line.
/// `PartialEq` exists for the tests (it is not used to gate anything).
#[derive(Clone, PartialEq, Eq)]
pub struct BodyKey([u8; KEY_LEN]);

impl BodyKey {
    /// Decode the base64 form the environment carries (`LAGOON_BODY_KEY`).
    pub fn from_base64(raw: &str) -> Result<Self, CipherError> {
        let bytes = BASE64
            .decode(raw.trim())
            .map_err(|_| CipherError::Base64)?;
        if bytes.len() != KEY_LEN {
            return Err(CipherError::BadKey(bytes.len()));
        }
        let mut key = [0u8; KEY_LEN];
        key.copy_from_slice(&bytes);
        Ok(Self(key))
    }

    fn cipher(&self) -> Aes256Gcm {
        let key = Key::<Aes256Gcm>::from_slice(&self.0);
        Aes256Gcm::new(key)
    }

    /// Open a stored envelope back into text.
    ///
    /// Refuses a value that is not an envelope, exactly like v3: a reader that
    /// silently accepted plaintext would turn a migration bug into a quiet
    /// downgrade instead of a loud failure.
    pub fn open(&self, envelope: &str) -> Result<String, CipherError> {
        let body = envelope
            .strip_prefix(ENVELOPE_PREFIX)
            .ok_or(CipherError::NotSealed)?;
        let combined = BASE64.decode(body).map_err(|_| CipherError::Base64)?;
        if combined.len() < NONCE_LEN + TAG_LEN {
            return Err(CipherError::TooShort(combined.len()));
        }
        let (nonce, ciphertext_and_tag) = combined.split_at(NONCE_LEN);
        let plaintext = self
            .cipher()
            .decrypt(
                Nonce::from_slice(nonce),
                Payload {
                    msg: ciphertext_and_tag,
                    aad: b"",
                },
            )
            .map_err(|_| CipherError::Decrypt)?;
        String::from_utf8(plaintext).map_err(|_| CipherError::NotUtf8)
    }

    /// Seal a value into the stored envelope.
    ///
    /// R1 never writes to the store; this exists because it is the mirror of
    /// `BodyCipher.seal` and because the tests need it to build a store whose
    /// cached bodies are in v3's format (including a Swift-produced vector).
    pub fn seal(&self, plaintext: &str) -> Result<String, CipherError> {
        let mut nonce_bytes = [0u8; NONCE_LEN];
        random_bytes(&mut nonce_bytes);
        let ciphertext_and_tag = self
            .cipher()
            .encrypt(
                Nonce::from_slice(&nonce_bytes),
                Payload {
                    msg: plaintext.as_bytes(),
                    aad: b"",
                },
            )
            .map_err(|_| CipherError::Decrypt)?;
        let mut combined = Vec::with_capacity(NONCE_LEN + ciphertext_and_tag.len());
        combined.extend_from_slice(&nonce_bytes);
        combined.extend_from_slice(&ciphertext_and_tag);
        Ok(format!("{ENVELOPE_PREFIX}{}", BASE64.encode(combined)))
    }
}

impl std::fmt::Debug for BodyKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("BodyKey(<redacted 32 bytes>)")
    }
}

/// A fresh nonce. `/dev/urandom` keeps the crate free of a RNG dependency; the
/// target is macOS only (there is no iOS or Linux v4 target yet), and the seal
/// path is used by tests and by the future write milestone.
pub(crate) fn random_bytes(buffer: &mut [u8]) {
    use std::io::Read as _;
    let mut file = std::fs::File::open("/dev/urandom").expect("open /dev/urandom");
    file.read_exact(buffer).expect("read /dev/urandom");
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The test-vector key from v4/spike/cipher-interop/run-interop.sh: the
    /// base64 of this ASCII seed. Never a real Keychain key.
    const TEST_KEY_SEED: &str = "0123456789abcdef0123456789abcdef";

    fn key() -> BodyKey {
        BodyKey::from_base64(&BASE64.encode(TEST_KEY_SEED)).expect("vector key")
    }

    #[test]
    fn opens_envelopes_produced_by_swift_cryptokit() {
        // Copied verbatim from v4/spike/cipher-interop/interop-transcript.log
        // (its "swift envelope" lines). CryptoKit produced these, not this
        // crate, which is what makes the test interop rather than a round trip.
        let vectors = [
            (
                "lgb1:LcH/xenkpJ44fimid/VyxqwwgOEm4wv8f5/7vMOkie7hqmxlSt88+qX1Xw==",
                "hello lagoon v4",
            ),
            (
                "lgb1:dKrEO5zqBGoWq5IG8Iqz7OlIBH5zFRK3CKZoYHucsQsEjaTyk+miq8X/wGv9FM0IP8IwmPWgZLv1w9E0Ro1imbMjIZvhIX/qdM8LN9WRHhJOld8Q",
                "你好，Lagoon —— 中文正文 🚀 with ascii tail",
            ),
            ("lgb1:P53bXkWJA/BgGfhmCCUDL374zUhmY0Ggy6b0Pw==", ""),
        ];
        for (envelope, plaintext) in vectors {
            assert_eq!(key().open(envelope).unwrap(), plaintext);
        }
    }

    #[test]
    fn seal_then_open_round_trips_unicode() {
        let plaintext = "你好，Lagoon —— 中文正文 🚀 with ascii tail";
        let envelope = key().seal(plaintext).unwrap();
        assert!(envelope.starts_with(ENVELOPE_PREFIX));
        assert_eq!(key().open(&envelope).unwrap(), plaintext);
    }

    #[test]
    fn every_seal_uses_a_fresh_nonce() {
        let first = key().seal("same input").unwrap();
        let second = key().seal("same input").unwrap();
        assert_ne!(first, second);
        assert_eq!(key().open(&first).unwrap(), key().open(&second).unwrap());
    }

    #[test]
    fn rejects_tampering_and_foreign_values() {
        let envelope = key().seal("tamper me").unwrap();
        let mut raw = BASE64.decode(&envelope[ENVELOPE_PREFIX.len()..]).unwrap();
        raw[20] ^= 0x01;
        let tampered = format!("{ENVELOPE_PREFIX}{}", BASE64.encode(raw));
        assert_eq!(key().open(&tampered), Err(CipherError::Decrypt));

        assert_eq!(key().open("not-an-envelope"), Err(CipherError::NotSealed));
        assert_eq!(key().open("lgb1:***"), Err(CipherError::Base64));
        assert_eq!(key().open("lgb1:AAAA"), Err(CipherError::TooShort(3)));
    }

    #[test]
    fn a_different_key_cannot_open_the_envelope() {
        let other = BodyKey::from_base64(&BASE64.encode([7u8; 32])).unwrap();
        let envelope = key().seal("secret").unwrap();
        assert_eq!(other.open(&envelope), Err(CipherError::Decrypt));
    }

    #[test]
    fn malformed_keys_are_refused() {
        assert_eq!(BodyKey::from_base64("not base64"), Err(CipherError::Base64));
        assert_eq!(BodyKey::from_base64("AAAA"), Err(CipherError::BadKey(3)));
    }
}
