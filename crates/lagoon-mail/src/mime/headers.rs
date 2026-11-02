//! RFC 5322 header block handling: unfolding, lowercasing, RFC 2047 encoded
//! words, RFC 5987 extended parameters and address lists.
//!
//! Ported from v3 `MIMEParser` + `AddressList` + `FromHeader`. The address
//! splitter is shared by the inbound parser and the outbound builder on
//! purpose: three independent comma-splitters disagreeing put a comma inside a
//! quoted display name into two recipients, and the send failed with a server
//! error that had nothing to do with the user's mistake.

use std::collections::BTreeMap;

use crate::mime::charset::{base64_decode, decode_charset, decode_quoted_printable};

/// First blank line splits headers from body; LF-only messages are accepted
/// alongside CRLF ones. When data has no blank line at all it is all header
/// (v3 behaviour: a truncated window must not turn into a body-less error).
pub fn split_head_and_body(data: &[u8]) -> (&[u8], &[u8]) {
    if let Some(index) = find_subslice(data, b"\r\n\r\n") {
        return (&data[..index], &data[index + 4..]);
    }
    if let Some(index) = find_subslice(data, b"\n\n") {
        return (&data[..index], &data[index + 2..]);
    }
    (data, &[])
}

/// Header bytes → text without ever losing bytes: UTF-8 when it is valid (raw
/// 8-bit UTF-8 headers are common), otherwise byte-preserving Latin-1.
pub fn header_text(data: &[u8]) -> String {
    match std::str::from_utf8(data) {
        Ok(text) => text.to_owned(),
        Err(_) => data.iter().map(|&byte| char::from(byte)).collect(),
    }
}

/// Header block → lowercase name → raw (unfolded, not RFC 2047 decoded) value.
/// Repeated headers collapse to the last occurrence, like v3. Structural
/// headers (Content-Type, boundary) must be read from here.
pub fn parse_header_block(data: &[u8]) -> BTreeMap<String, String> {
    let text = header_text(data);
    let mut headers: BTreeMap<String, String> = BTreeMap::new();
    let mut name: Option<String> = None;
    let mut value = String::new();

    for raw_line in text.split('\n') {
        let line = raw_line.strip_suffix('\r').unwrap_or(raw_line);
        if line.starts_with(' ') || line.starts_with('\t') {
            if name.is_some() {
                value.push(' ');
                value.push_str(line.trim());
            }
            continue;
        }
        if let Some(field) = name.take() {
            headers.insert(field, value.trim().to_owned());
        }
        value.clear();
        let Some(colon) = line.find(':') else {
            continue;
        };
        let field = line[..colon].trim().to_ascii_lowercase();
        if field.is_empty() {
            continue;
        }
        name = Some(field);
        value.push_str(&line[colon + 1..]);
    }
    if let Some(field) = name {
        headers.insert(field, value.trim().to_owned());
    }
    headers
}

/// Header block → decoded values. RFC 2047 encoded words are decoded; keys stay
/// lowercase and continuation lines unfolded.
pub fn decode_headers(raw: &[u8]) -> BTreeMap<String, String> {
    let (header, _) = split_head_and_body(raw);
    parse_header_block(header)
        .into_iter()
        .map(|(name, value)| (name, decode_rfc2047(&value)))
        .collect()
}

/// RFC 2047 `=?charset?B|Q?...?=` words: decoded in place, with the whitespace
/// between two adjacent encoded words dropped (RFC 2047 §6.2).
///
/// A word that cannot be parsed or decoded is left exactly as it arrived; mail
/// is not worth losing over one broken word.
pub fn decode_rfc2047(value: &str) -> String {
    if !value.contains("=?") {
        return value.to_owned();
    }
    let mut result = String::with_capacity(value.len());
    let mut cursor = 0usize;
    let mut previous_was_encoded = false;
    let mut search = 0usize;
    while let Some(relative) = value[search..].find("=?") {
        let start = search + relative;
        let parsed = parse_encoded_word(value, start + 2);
        let Some((charset, encoding, payload, end)) = parsed else {
            search = start + 2;
            continue;
        };
        let gap = &value[cursor..start];
        let is_folding_gap = previous_was_encoded && gap.trim().is_empty();
        if !is_folding_gap {
            result.push_str(gap);
        }
        match decode_encoded_payload(payload, encoding, charset) {
            Some(text) => result.push_str(&text),
            None => result.push_str(&value[start..end]),
        }
        cursor = end;
        previous_was_encoded = true;
        search = end;
    }
    result.push_str(&value[cursor..]);
    result
}

/// Parse `charset?encoding?payload?=` starting after the `=?\ prefix.
fn parse_encoded_word(value: &str, mut index: usize) -> Option<(&str, u8, &str, usize)> {
    let bytes = value.as_bytes();
    let charset_start = index;
    while index < bytes.len() {
        let byte = bytes[index];
        if byte == b'?' {
            break;
        }
        if byte.is_ascii_whitespace() {
            return None;
        }
        index += 1;
    }
    if index >= bytes.len() || index == charset_start {
        return None;
    }
    let charset = &value[charset_start..index];
    index += 1; // '?'
    let encoding = *bytes.get(index)?;
    if !matches!(encoding, b'B' | b'b' | b'Q' | b'q') {
        return None;
    }
    index += 1;
    if bytes.get(index) != Some(&b'?') {
        return None;
    }
    index += 1;
    let payload_start = index;
    let question = value[payload_start..].find('?')?;
    let payload_end = payload_start + question;
    if bytes.get(payload_end + 1) != Some(&b'=') {
        return None;
    }
    Some((
        charset,
        encoding,
        &value[payload_start..payload_end],
        payload_end + 2,
    ))
}

fn decode_encoded_payload(payload: &str, encoding: u8, charset: &str) -> Option<String> {
    let bytes = match encoding {
        b'B' | b'b' => base64_decode(payload)?,
        b'Q' | b'q' => {
            // In Q-encoding `_` stands for a space; anything literal is `=5F`.
            let spaced = payload.replace('_', " ");
            decode_quoted_printable(spaced.as_bytes())
        }
        _ => return None,
    };
    Some(decode_charset(&bytes, Some(charset)))
}

/// `name="value"` / `name=value` / `name*=RFC 5987 encoded` — the value may be
/// quoted (with backslash-escaped chars) or bare. Common forms only; anything
/// odd returns `None` rather than guessing.
pub fn header_parameter(header: &str, name: &str) -> Option<String> {
    let prefix = format!("{name}=");
    for segment in header.split(';') {
        let trimmed = segment.trim();
        if !trimmed
            .to_ascii_lowercase()
            .starts_with(&prefix.to_ascii_lowercase())
        {
            continue;
        }
        let mut value = trimmed[prefix.len()..].trim().to_owned();
        if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
            value = value[1..value.len() - 1].to_owned();
        }
        return if value.is_empty() { None } else { Some(value) };
    }
    None
}

/// RFC 5987 extended parameter: `charset'language'percent-encoded-value`.
/// The escapes must be resolved here — [`decode_rfc2047`] returns its input
/// untouched for a value with no `=?`, which is exactly what this looks like.
pub fn decode_rfc5987(value: &str) -> Option<String> {
    let pieces: Vec<&str> = value.splitn(3, '\'').collect();
    if pieces.len() != 3 || pieces[2].is_empty() {
        return None;
    }
    Some(decode_charset(
        &percent_decode(pieces[2]),
        if pieces[0].is_empty() {
            None
        } else {
            Some(pieces[0])
        },
    ))
}

/// `%XX` → byte. A malformed escape is kept as the literal characters it is,
/// so a filename is never silently shortened by a typo in a header.
pub fn percent_decode(value: &str) -> Vec<u8> {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0usize;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) = (
                crate::mime::charset::hex_value(bytes[index + 1]),
                crate::mime::charset::hex_value(bytes[index + 2]),
            ) {
                output.push((high << 4) | low);
                index += 3;
                continue;
            }
        }
        output.push(bytes[index]);
        index += 1;
    }
    output
}

/// Splits an RFC 5322 address list into its top-level pieces, display names
/// included. Only a comma outside quotes and angle brackets separates two
/// addresses.
pub fn split_address_list(raw: &str) -> Vec<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let mut pieces = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;
    let mut angle_depth = 0i32;
    let mut escaped = false;

    for ch in trimmed.chars() {
        if escaped {
            current.push(ch);
            escaped = false;
            continue;
        }
        match ch {
            '\\' if in_quotes => {
                escaped = true;
                current.push(ch);
            }
            '"' => {
                in_quotes = !in_quotes;
                current.push(ch);
            }
            '<' => {
                angle_depth += 1;
                current.push(ch);
            }
            '>' => {
                angle_depth = (angle_depth - 1).max(0);
                current.push(ch);
            }
            ',' if !in_quotes && angle_depth == 0 => {
                pieces.push(std::mem::take(&mut current));
            }
            _ => current.push(ch),
        }
    }
    if !current.is_empty() {
        pieces.push(current);
    }
    pieces
        .into_iter()
        .map(|piece| piece.trim().to_owned())
        .filter(|piece| !piece.is_empty())
        .collect()
}

/// The bare `addr@host` of every address in the list.
///
/// The display name is dropped: a forward-path (RFC 5321 RCPT TO) and a
/// deliverable recipient list both need routable addresses, not labels. A piece
/// whose shape is unparseable — a display name with no address — is skipped
/// rather than emitted as a junk recipient.
///
/// `bob@example.com (Bob)` is stripped to its address. v3's helper only removed
/// an *empty* trailing comment, so that form was silently dropped; that is a
/// deliberate (documented) fix here, since the alternative is a recipient who
/// never receives the mail.
pub fn parse_address_list(raw: &str) -> Vec<String> {
    split_address_list(raw)
        .into_iter()
        .filter_map(|value| {
            if let (Some(open), Some(close)) = (value.rfind('<'), value.rfind('>')) {
                if open < close {
                    let address = value[open + 1..close].trim();
                    return if address.is_empty() {
                        None
                    } else {
                        Some(address.to_owned())
                    };
                }
            }
            let bare = strip_trailing_comment(&value);
            if bare.contains('@') && !bare.contains(' ') {
                Some(bare)
            } else {
                None
            }
        })
        .collect()
}

/// Removes one trailing RFC 5322 comment: `bob@example.com (Bob)` →
/// `bob@example.com`. Only a comment at the end is removed; a parenthesis
/// inside an address is not a comment.
fn strip_trailing_comment(value: &str) -> String {
    let trimmed = value.trim();
    if !trimmed.ends_with(')') {
        return trimmed.to_owned();
    }
    let Some(open) = trimmed.rfind('(') else {
        return trimmed.to_owned();
    };
    let comment = &trimmed[open..];
    if comment[1..comment.len() - 1].contains('(') {
        return trimmed.to_owned();
    }
    trimmed[..open].trim().to_owned()
}

/// `From:` header → (address, display name). Deliberately forgiving: a
/// malformed header yields the raw text as the address instead of dropping the
/// message (v3 `FromHeader.parse`).
pub fn parse_from_header(raw: &str) -> (String, Option<String>) {
    if raw.contains('<') && raw.contains('>') {
        let name_part = raw
            .split('<')
            .next()
            .map(|part| part.trim().trim_matches('"').trim())
            .filter(|part| !part.is_empty())
            .map(str::to_owned);
        let address = raw
            .split('<')
            .next_back()
            .unwrap_or(raw)
            .replace('>', "")
            .trim()
            .to_owned();
        return (address, name_part);
    }
    (raw.trim().to_owned(), None)
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_crlf_and_lf_messages() {
        let (head, body) = split_head_and_body(b"Subject: a\r\n\r\nbody");
        assert_eq!(head, b"Subject: a");
        assert_eq!(body, b"body");
        let (head, body) = split_head_and_body(b"Subject: a\n\nbody");
        assert_eq!(head, b"Subject: a");
        assert_eq!(body, b"body");
        let (head, body) = split_head_and_body(b"Subject: only headers");
        assert_eq!(head, b"Subject: only headers");
        assert!(body.is_empty());
    }

    #[test]
    fn unfolds_and_lowercases_headers_and_last_occurrence_wins() {
        let raw =
            b"Subject: Hello\r\n\tWorld\r\nX-Test: one\r\nSubject: Second\r\nBad-No-Colon\r\n";
        let headers = parse_header_block(raw);
        assert_eq!(headers.get("subject").unwrap(), "Second");
        assert_eq!(headers.get("x-test").unwrap(), "one");
        assert!(!headers.contains_key("bad-no-colon"));
    }

    #[test]
    fn invalid_utf8_headers_keep_their_bytes() {
        let raw = b"Subject: caf\xE9\r\n\r\n";
        let headers = parse_header_block(raw);
        assert_eq!(headers.get("subject").unwrap(), "caf\u{E9}");
    }

    #[test]
    fn rfc2047_base64_words_decode_with_charsets() {
        assert_eq!(decode_rfc2047("Re: =?UTF-8?B?5L2g5aW9?="), "Re: 你好");
        assert_eq!(decode_rfc2047("=?GBK?B?u+HS6bzN0qo=?="), "会议纪要");
        assert_eq!(decode_rfc2047("=?Shift_JIS?B?k/qWe4zq?="), "日本語");
        assert_eq!(decode_rfc2047("plain text"), "plain text");
    }

    #[test]
    fn rfc2047_quoted_printable_words_decode() {
        assert_eq!(decode_rfc2047("=?UTF-8?Q?caf=C3=A9?="), "café");
        assert_eq!(decode_rfc2047("=?UTF-8?Q?a_b?="), "a b");
    }

    #[test]
    fn adjacent_encoded_words_drop_the_folding_whitespace() {
        assert_eq!(decode_rfc2047("=?UTF-8?B?5L2g?= =?UTF-8?B?5aW9?="), "你好");
    }

    #[test]
    fn gap_between_non_encoded_text_is_preserved() {
        assert_eq!(
            decode_rfc2047("=?UTF-8?B?5L2g?= x =?UTF-8?B?5aW9?="),
            "你 x 好"
        );
    }

    #[test]
    fn broken_encoded_words_pass_through_verbatim() {
        assert_eq!(
            decode_rfc2047("=?UTF-8?B?not-base64!?="),
            "=?UTF-8?B?not-base64!?="
        );
        assert_eq!(decode_rfc2047("=?UTF-8?X?abc?="), "=?UTF-8?X?abc?=");
        assert_eq!(decode_rfc2047("=??B?abc?="), "=??B?abc?=");
    }

    #[test]
    fn address_list_splits_only_top_level_commas() {
        assert_eq!(
            split_address_list(
                "\"Zhang, Wei\" <wei@example.com>, bob@example.com, \"Li, Jane\" <jane@example.com>"
            ),
            [
                "\"Zhang, Wei\" <wei@example.com>",
                "bob@example.com",
                "\"Li, Jane\" <jane@example.com>"
            ]
        );
        assert!(split_address_list("  ").is_empty());
    }

    #[test]
    fn bare_addresses_drop_display_names_and_junk() {
        assert_eq!(
            parse_address_list("\"Zhang, Wei\" <wei@example.com>, bob@example.com, Just A Name"),
            ["wei@example.com", "bob@example.com"]
        );
        assert_eq!(
            parse_address_list("bob@example.com (Bob), carol@example.com"),
            ["bob@example.com", "carol@example.com"]
        );
        assert_eq!(parse_address_list("<>"), Vec::<String>::new());
    }

    #[test]
    fn from_header_yields_address_and_name() {
        assert_eq!(
            parse_from_header("\"Chen, Qi\" <chen@example.com>"),
            ("chen@example.com".to_owned(), Some("Chen, Qi".to_owned()))
        );
        assert_eq!(
            parse_from_header("plain@example.com"),
            ("plain@example.com".to_owned(), None)
        );
        assert_eq!(
            parse_from_header("Mailer Daemon"),
            ("Mailer Daemon".to_owned(), None)
        );
    }

    #[test]
    fn rfc5987_extended_parameter_decodes_percent_escapes() {
        assert_eq!(
            decode_rfc5987("UTF-8''%E4%BC%9A%E8%AE%AE.txt").unwrap(),
            "会议.txt"
        );
        assert_eq!(decode_rfc5987("GBK''%BB%E1%D2%E9").unwrap(), "会议");
        assert_eq!(decode_rfc5987("UTF-8''"), None);
        assert_eq!(decode_rfc5987("broken"), None);
    }

    #[test]
    fn header_parameter_handles_quoted_bare_and_extended_names() {
        assert_eq!(
            header_parameter(r#"attachment; filename="report final.pdf""#, "filename").unwrap(),
            "report final.pdf"
        );
        assert_eq!(
            header_parameter("attachment; filename=report.pdf", "filename").unwrap(),
            "report.pdf"
        );
        assert_eq!(
            header_parameter("attachment; filename*=UTF-8''%E4%BC%9A.txt", "filename*").unwrap(),
            "UTF-8''%E4%BC%9A.txt"
        );
        assert_eq!(header_parameter("attachment", "filename"), None);
    }

    #[test]
    fn percent_decode_keeps_malformed_escapes() {
        assert_eq!(percent_decode("%41%zz%"), b"A%zz%");
    }
}
