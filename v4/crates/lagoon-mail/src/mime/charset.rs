//! Charset, transfer-encoding and escape decoding.
//!
//! Ported from v3 `MIMEParser`'s decoder section, with the same fallbacks:
//!
//! * `utf-8` (and no charset at all) is tried strictly first. If that fails,
//!   the bytes are decoded leniently and the result is kept only when almost
//!   nothing was replaced — a `BODY[]<0.N>` window ends mid-sequence often
//!   enough that dropping straight to Latin-1 would mojibake every CJK body,
//!   while genuine 8-bit text replaces every byte.
//! * `gbk` / `gb2312` / `gb18030` all go through **GB18030**, which is a
//!   superset of the other two. This is the QQ branch.
//! * everything else goes through `encoding_rs`'s IANA label table, then
//!   Latin-1. The final fallback never fails, so a caller always gets
//!   something printable.

use base64::Engine as _;

/// Decode bytes according to a declared charset. Never fails.
pub fn decode_charset(data: &[u8], charset: Option<&str>) -> String {
    let name = charset.unwrap_or("").trim().to_ascii_lowercase();
    match name.as_str() {
        "" | "utf-8" | "utf8" => {
            if let Ok(text) = std::str::from_utf8(data) {
                return text.to_owned();
            }
            // Lenient decode; keep it only when the replacement rate is tiny.
            let lenient = String::from_utf8_lossy(data);
            let scalar_count = lenient.chars().count();
            let replacement_count = lenient.chars().filter(|&ch| ch == '\u{FFFD}').count();
            if scalar_count > 0 && replacement_count * 100 <= scalar_count {
                return lenient.into_owned();
            }
        }
        "gbk" | "gb2312" | "gb-2312" | "gb_2312" | "x-gbk" | "cp936" | "ms936" | "gb18030" => {
            let (text, _, had_errors) = encoding_rs::GB18030.decode(data);
            if !had_errors {
                return text.into_owned();
            }
        }
        "iso-8859-1" | "iso8859-1" | "latin-1" | "latin1" | "us-ascii" | "ascii"
        | "windows-1252" => {
            // v3 deliberately maps windows-1252 onto Latin-1 as well; keep that
            // so the two ports produce the same bytes for the same labels.
            return latin1(data);
        }
        _ => {
            if let Some(encoding) = encoding_rs::Encoding::for_label(name.as_bytes()) {
                let (text, _, had_errors) = encoding.decode(data);
                if !had_errors {
                    return text.into_owned();
                }
            }
        }
    }
    latin1(data)
}

/// Byte-preserving Latin-1: every input byte becomes one scalar. Used both as
/// an explicit charset and as the final fallback.
pub fn latin1(data: &[u8]) -> String {
    data.iter().map(|&byte| char::from(byte)).collect()
}

/// Tolerant base64: whitespace (including folded lines) is ignored and missing
/// padding is added. Returns `None` for padding-only input, which a strict
/// decoder would otherwise turn into a NUL byte.
pub fn base64_decode(value: &str) -> Option<Vec<u8>> {
    let mut normalized = String::with_capacity(value.len());
    for ch in value.chars() {
        if !ch.is_ascii_whitespace() {
            normalized.push(ch);
        }
    }
    if normalized.is_empty() || normalized.chars().all(|ch| ch == '=') {
        return None;
    }
    let remainder = normalized.len() % 4;
    if remainder > 0 {
        for _ in 0..(4 - remainder) {
            normalized.push('=');
        }
    }
    base64::engine::general_purpose::STANDARD
        .decode(normalized.as_bytes())
        .ok()
}

/// `=XX` hex escapes and soft line breaks (`=` at end of line). Invalid
/// escapes pass through as literal text, exactly as v3's decoder does.
pub fn decode_quoted_printable(data: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(data.len());
    let mut index = 0usize;
    while index < data.len() {
        let byte = data[index];
        if byte != b'=' {
            output.push(byte);
            index += 1;
            continue;
        }
        let next = index + 1;
        if next >= data.len() {
            output.push(byte);
            index = next;
            continue;
        }
        if data[next] == b'\n' {
            index = next + 1;
            continue;
        }
        if data[next] == b'\r' {
            let after_cr = next + 1;
            if after_cr < data.len() && data[after_cr] == b'\n' {
                index = after_cr + 1;
                continue;
            }
        }
        let high = next + 1;
        if high < data.len() {
            if let (Some(first), Some(second)) = (hex_value(data[next]), hex_value(data[high])) {
                output.push((first << 4) | second);
                index = high + 1;
                continue;
            }
        }
        output.push(byte);
        index = next;
    }
    output
}

pub(crate) fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(text: &str) -> Vec<u8> {
        text.split_whitespace()
            .map(|pair| u8::from_str_radix(pair, 16).unwrap())
            .collect()
    }

    #[test]
    fn utf8_decodes_strictly() {
        assert_eq!(
            decode_charset("会议纪要".as_bytes(), Some("UTF-8")),
            "会议纪要"
        );
        assert_eq!(decode_charset(b"plain", None), "plain");
    }

    #[test]
    fn truncated_utf8_keeps_chinese_instead_of_mojibake() {
        // A 600-byte body cut one byte inside its last scalar: one replacement
        // scalar out of 200, i.e. 0.5% — under v3's 1% cut, so the lenient
        // result wins over the Latin-1 fallback.
        let mut bytes = "中".repeat(200).into_bytes();
        bytes.truncate(bytes.len() - 1);
        let decoded = decode_charset(&bytes, Some("utf-8"));
        assert!(decoded.starts_with('中'), "{decoded:?}");
        assert!(decoded.contains('\u{FFFD}'), "{decoded:?}");
        assert_eq!(decoded.chars().count(), 200);

        // The v3 threshold is intentionally strict: a tiny buffer where half
        // the scalars are replacements falls through to byte-preserving
        // Latin-1 rather than guessing.
        let short = decode_charset(&[0xE4, 0xB8, 0xAD, 0xE6], Some("utf-8"));
        assert_eq!(short, "ä¸\u{AD}æ");
    }

    #[test]
    fn gbk_label_variants_decode_as_gb18030() {
        let bytes = hex("D6 D0 CE C4");
        for label in ["gbk", "GB2312", "gb_2312", "x-gbk", "cp936", "GB18030"] {
            assert_eq!(decode_charset(&bytes, Some(label)), "中文", "{label}");
        }
    }

    #[test]
    fn shift_jis_decodes_through_the_iana_table() {
        let bytes = hex("93 FA 96 7B 8C EA");
        assert_eq!(decode_charset(&bytes, Some("shift_jis")), "日本語");
        assert_eq!(decode_charset(&bytes, Some("Shift-JIS")), "日本語");
    }

    #[test]
    fn windows_1252_maps_to_latin1_like_v3() {
        let bytes = hex("63 61 66 E9");
        assert_eq!(decode_charset(&bytes, Some("windows-1252")), "café");
        assert_eq!(decode_charset(&bytes, Some("iso-8859-1")), "café");
    }

    #[test]
    fn unknown_charset_falls_back_to_byte_preserving_latin1() {
        assert_eq!(
            decode_charset(&[0x80, 0xFF], Some("x-made-up")),
            "\u{80}\u{FF}"
        );
    }

    #[test]
    fn quoted_printable_decodes_escapes_and_soft_breaks() {
        assert_eq!(
            decode_quoted_printable(b"caf=C3=A9=\r\nnext"),
            "cafénext".as_bytes()
        );
        // Invalid escape stays literal.
        assert_eq!(decode_quoted_printable(b"a=ZZb"), b"a=ZZb");
        // A trailing '=' is kept.
        assert_eq!(decode_quoted_printable(b"tail="), b"tail=");
    }

    #[test]
    fn base64_tolerates_whitespace_and_missing_padding() {
        assert_eq!(base64_decode("5L2g5aW9").unwrap(), "你好".as_bytes());
        assert_eq!(base64_decode("5L2g\r\n5aW9").unwrap(), "你好".as_bytes());
        assert_eq!(base64_decode("="), None);
        assert_eq!(base64_decode(""), None);
        assert_eq!(base64_decode("!!!"), None);
    }
}
