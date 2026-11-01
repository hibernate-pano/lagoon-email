//! UUID handling that matches what the v3 server accepts.
//!
//! v3 validates `accountId` with Foundation's `UUID(uuidString:)`. Probed on
//! this machine (Swift 6, macOS 26): it accepts **only** the canonical
//! 8-4-4-4-12 hyphenated form, in either case, and rejects the 32-hex form,
//! braces, `urn:uuid:` prefixes and any surrounding whitespace. A lenient
//! parser here would answer 200 where v3 answers 400 `malformed-accountId`,
//! so the parser is deliberately strict.
//!
//! The 16 raw bytes are also the store's BLOB encoding (GRDB writes a Swift
//! `UUID` as 16 bytes), which is why this type converts to bytes rather than
//! to a hyphenated string for binding.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Uuid([u8; 16]);

impl Uuid {
    /// Parse Foundation's accepted spelling. `None` for anything else.
    pub fn parse_strict(raw: &str) -> Option<Self> {
        let bytes = raw.as_bytes();
        if bytes.len() != 36 {
            return None;
        }
        let mut out = [0u8; 16];
        let mut nibbles = 0usize;
        for (index, byte) in bytes.iter().enumerate() {
            match index {
                8 | 13 | 18 | 23 => {
                    if *byte != b'-' {
                        return None;
                    }
                }
                _ => {
                    let value = hex_value(*byte)?;
                    let slot = nibbles / 2;
                    if nibbles % 2 == 0 {
                        out[slot] = value << 4;
                    } else {
                        out[slot] |= value;
                    }
                    nibbles += 1;
                }
            }
        }
        if nibbles != 32 {
            return None;
        }
        Some(Self(out))
    }

    /// The store's BLOB encoding.
    /// A fresh random (version 4) UUID.
    ///
    /// v3 mints a UUID per new account row (UUID()); this is the same shape,
    /// with the version and variant bits set so the canonical string is valid
    /// to Foundation's parser as well as this crate's.
    pub fn new_v4() -> Self {
        let mut bytes = [0u8; 16];
        crate::crypto::random_bytes(&mut bytes);
        bytes[6] = (bytes[6] & 0x0F) | 0x40;
        bytes[8] = (bytes[8] & 0x3F) | 0x80;
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }

    /// What the wire carries: lowercase, hyphenated.
    pub fn to_wire_string(&self) -> String {
        let mut out = String::with_capacity(36);
        for (index, byte) in self.0.iter().enumerate() {
            if matches!(index, 4 | 6 | 8 | 10) {
                out.push('-');
            }
            out.push_str(&format!("{byte:02x}"));
        }
        out
    }

    /// Tolerate a row whose id was stored as text instead of a BLOB.
    ///
    /// v3 carries the same tolerance (`AccountStore.findToleratingIDEncoding`)
    /// for a store repaired by migration `lagoon-v5b`: under normal operation
    /// this never triggers, but a row the server cannot address by id is a
    /// mailbox the user cannot open.
    pub fn from_stored(raw: &[u8]) -> Option<Self> {
        if raw.len() == 16 {
            let mut bytes = [0u8; 16];
            bytes.copy_from_slice(raw);
            return Some(Self(bytes));
        }
        let text = std::str::from_utf8(raw).ok()?.trim();
        Self::parse_strict(text.trim_matches(['{', '}']))
    }
}

impl fmt::Display for Uuid {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.to_wire_string())
    }
}

impl serde::Serialize for Uuid {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_wire_string())
    }
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_the_canonical_form_in_either_case() {
        let lower = Uuid::parse_strict("11111111-1111-4111-8111-111111111111").unwrap();
        let upper = Uuid::parse_strict("11111111-1111-4111-8111-11111111111A").unwrap();
        assert_eq!(lower.to_wire_string(), "11111111-1111-4111-8111-111111111111");
        assert_eq!(upper.to_wire_string(), "11111111-1111-4111-8111-11111111111a");
    }

    #[test]
    fn rejects_everything_foundation_rejects() {
        // The exact strings from the Swift probe.
        for raw in [
            "11111111111141118111111111111111",
            "{11111111-1111-4111-8111-111111111111}",
            "urn:uuid:11111111-1111-4111-8111-111111111111",
            "1111-1111-1111-1111-111111111111",
            "not-a-uuid",
            "11111111-1111-4111-8111-111111111111 ",
            "11111111-1111-4111-8111-11111111111",
            "11111111-1111-4111-8111-1111111111111",
        ] {
            assert!(Uuid::parse_strict(raw).is_none(), "accepted {raw:?}");
        }
    }

    #[test]
    fn stored_blob_and_stored_text_both_decode() {
        let blob: Vec<u8> = (0u8..16).collect();
        assert_eq!(Uuid::from_stored(&blob).unwrap().as_bytes(), &blob[..]);
        let text = Uuid::parse_strict("11111111-1111-4111-8111-111111111111")
            .unwrap()
            .to_wire_string();
        assert_eq!(
            Uuid::from_stored(text.as_bytes()).unwrap().to_wire_string(),
            text
        );
    }
}
