//! AES-256-GCM interop probe: mirrors Swift `BodyCipher`
//! (Sources/LagoonKit/BodyCipher.swift:71-95).
//!
//! Envelope: "lgb1:" + base64( combined ), where
//! combined = 12B nonce || ciphertext || 16B tag  (== AES.GCM.SealedBox.combined).
//!
//! Usage:
//!   cipher-interop encrypt <key-b64> <plaintext>   -> prints envelope + nonce(hex)
//!   cipher-interop decrypt <key-b64> <envelope>    -> prints plaintext

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;

const PREFIX: &str = "lgb1:";

fn key_from_b64(s: &str) -> Vec<u8> {
    let k = B64.decode(s.trim()).expect("key must be base64");
    assert_eq!(k.len(), 32, "key must be 32 bytes, got {}", k.len());
    k
}

fn nonce12() -> [u8; 12] {
    let mut n = [0u8; 12];
    use std::io::Read;
    std::fs::File::open("/dev/urandom")
        .expect("/dev/urandom")
        .read_exact(&mut n)
        .expect("urandom");
    n
}

fn encrypt(key_b64: &str, plaintext: &str) -> (String, [u8; 12]) {
    let key = Key::<Aes256Gcm>::from_slice(&key_from_b64(key_b64)).clone();
    let cipher = Aes256Gcm::new(&key);
    let nonce_bytes = nonce12();
    let nonce = Nonce::from_slice(&nonce_bytes);
    // aes-gcm's encrypt() returns ciphertext || tag (same tail order as CryptoKit).
    let ct_and_tag = cipher.encrypt(nonce, plaintext.as_bytes()).expect("encrypt");
    let mut combined = Vec::with_capacity(12 + ct_and_tag.len());
    combined.extend_from_slice(&nonce_bytes);
    combined.extend_from_slice(&ct_and_tag);
    (format!("{}{}", PREFIX, B64.encode(&combined)), nonce_bytes)
}

fn decrypt(key_b64: &str, envelope: &str) -> Result<String, String> {
    let body = envelope
        .strip_prefix(PREFIX)
        .ok_or_else(|| "not an lgb1: envelope".to_string())?;
    let combined = B64.decode(body).map_err(|e| format!("base64: {e}"))?;
    if combined.len() < 12 + 16 {
        return Err(format!("combined too short: {}", combined.len()));
    }
    let (nonce_bytes, ct_and_tag) = combined.split_at(12);
    let key = Key::<Aes256Gcm>::from_slice(&key_from_b64(key_b64)).clone();
    let cipher = Aes256Gcm::new(&key);
    let pt = cipher
        .decrypt(Nonce::from_slice(nonce_bytes), ct_and_tag)
        .map_err(|e| format!("decrypt failed: {e}"))?;
    String::from_utf8(pt).map_err(|e| format!("utf8: {e}"))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [cmd, key, payload] if cmd == "encrypt" => {
            let (env, nonce) = encrypt(key, payload);
            let hex: String = nonce.iter().map(|b| format!("{:02x}", b)).collect();
            println!("NONCE_HEX={hex}");
            println!("ENVELOPE={env}");
        }
        [cmd, key, payload] if cmd == "decrypt" => match decrypt(key, payload) {
            Ok(pt) => println!("PLAINTEXT={pt}"),
            Err(e) => {
                println!("ERROR={e}");
                std::process::exit(1);
            }
        },
        _ => {
            eprintln!("usage: cipher-interop encrypt|decrypt <key-b64> <payload>");
            std::process::exit(2);
        }
    }
}
