//! Seals or opens one credential blob, for the cross-implementation check.
//!
//!     token_tool seal <base64-key> <plaintext>   -> base64(combined)
//!     token_tool open <base64-key> <base64-blob> -> plaintext
//!
//! The other side of the check is scripts/token-tool.swift, which uses the
//! exact CryptoKit call v3's AccessTokenCipher uses.

use std::process::ExitCode;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;

use lagoon_api::token::TokenKey;

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.len() != 3 {
        eprintln!("usage: token_tool seal|open <base64-key> <value>");
        return ExitCode::FAILURE;
    }
    let Ok(key) = TokenKey::from_base64(&arguments[1]) else {
        eprintln!("malformed key");
        return ExitCode::FAILURE;
    };
    match arguments[0].as_str() {
        "seal" => match key.seal(&arguments[2]) {
            Ok(blob) => {
                println!("{}", BASE64.encode(blob));
                ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("{error}");
                ExitCode::FAILURE
            }
        },
        "open" => {
            let Ok(blob) = BASE64.decode(arguments[2].trim()) else {
                eprintln!("blob is not base64");
                return ExitCode::FAILURE;
            };
            match key.open(&blob) {
                Ok(plaintext) => {
                    println!("{plaintext}");
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("{error}");
                    ExitCode::FAILURE
                }
            }
        }
        other => {
            eprintln!("unknown mode {other}");
            ExitCode::FAILURE
        }
    }
}
