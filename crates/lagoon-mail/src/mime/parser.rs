//! Recursive RFC 5322 / MIME reader.
//!
//! Ported from v3 `MIMEParser.swift` (spec §3.6): enough of the format to turn
//! an IMAP `BODY[]` fetch into readable plain text, HTML when present, and
//! attachment metadata — and nothing more. Nothing here returns an error;
//! malformed mail yields a shorter result, never a failed request.
//!
//! The two structural decisions that were expensive to learn in v3:
//! * `BODY.PEEK[HEADER.FIELDS ...]` / preview windows can cut a message at an
//!   arbitrary byte, so a missing blank line means "header only", not "broken";
//! * an LF-only multipart must still split. Searching for `\n--boundary`
//!   instead matches one byte *inside* every real CRLF delimiter and splits each
//!   part in two, so the body is re-framed to CRLF exactly once and only the
//!   CRLF delimiter is ever searched for (`crlf_framed`).

use std::collections::BTreeMap;

use crate::mime::charset::{base64_decode, decode_charset, decode_quoted_printable};
use crate::mime::headers::{
    decode_rfc5987, header_parameter, parse_address_list, parse_header_block, split_head_and_body,
};
use crate::mime::html;

/// Hard caps on extracted content. Generous enough for almost any legitimate
/// message, low enough to bound a hostile one. Truncation surfaces as
/// `has_more = true`.
pub const TEXT_CAP: usize = 200_000; // 200 KB
pub const HTML_CAP: usize = 5_000_000; // 5 MB

/// Hard stop on nesting depth: malformed input can otherwise recurse forever
/// (a part claiming itself as its own child).
const MAX_DEPTH: usize = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentDisposition {
    Attachment,
    Inline,
}

impl AttachmentDisposition {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Attachment => "attachment",
            Self::Inline => "inline",
        }
    }
}

/// One attachment. `id` is the IMAP part path (`1`, `1.2`) so the attachment
/// route can re-fetch a single part with `BODY[1.2]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedAttachment {
    pub id: String,
    pub filename: Option<String>,
    pub mime_type: String,
    /// Decoded size when `decode_attachment_bytes` is on; a close estimate
    /// otherwise (the body route does not pay for the decode).
    pub size: usize,
    pub content_id: Option<String>,
    pub disposition: AttachmentDisposition,
    /// Empty unless `decode_attachment_bytes` was requested.
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedMessage {
    /// Plain text of the preferred body part, or the stripped HTML when there
    /// is no text part at all.
    pub text: String,
    /// HTML body when present, left as-is for the reader.
    pub html: Option<String>,
    pub attachments: Vec<ParsedAttachment>,
    pub has_more: bool,
    /// Recipient addresses from `To:`, addresses only.
    pub to: Vec<String>,
    /// Recipient addresses from `Cc:`, addresses only.
    pub cc: Vec<String>,
}

/// Full parse without attachment bytes (the body route's shape).
pub fn parse(message: &[u8]) -> ParsedMessage {
    parse_with_options(message, false)
}

/// Full parse. `decode_attachment_bytes` defaults to `false` because the body
/// route strips attachment bytes before the wire response; decoding them there
/// was pure waste. The attachment download route passes `true`.
pub fn parse_with_options(message: &[u8], decode_attachment_bytes: bool) -> ParsedMessage {
    let (header, body) = split_head_and_body(message);
    let headers = parse_header_block(header);
    let result = parse_part(&headers, body, 0, "1", decode_attachment_bytes);
    let text = match &result.text {
        Some(text) => text.clone(),
        None => result.html.as_deref().map(html::strip).unwrap_or_default(),
    };
    ParsedMessage {
        text: text.trim().to_owned(),
        html: result.html,
        attachments: result.attachments,
        has_more: result.has_more,
        to: parse_address_list(headers.get("to").map(String::as_str).unwrap_or("")),
        cc: parse_address_list(headers.get("cc").map(String::as_str).unwrap_or("")),
    }
}

/// Plain text of the preferred body part (v3's `plainText(from:)`).
pub fn plain_text(message: &[u8]) -> String {
    parse(message).text
}

#[derive(Default)]
struct ParseResult {
    text: Option<String>,
    html: Option<String>,
    attachments: Vec<ParsedAttachment>,
    has_more: bool,
}

fn parse_part(
    headers: &BTreeMap<String, String>,
    body: &[u8],
    depth: usize,
    part_path: &str,
    decode_attachment_bytes: bool,
) -> ParseResult {
    if depth >= MAX_DEPTH {
        return ParseResult::default();
    }
    let (mime_type, parameters) =
        parse_content_type(headers.get("content-type").map(String::as_str));
    let encoding = headers
        .get("content-transfer-encoding")
        .map(|value| value.trim().to_ascii_lowercase())
        .unwrap_or_default();
    let disposition_raw = headers
        .get("content-disposition")
        .map(|value| value.to_ascii_lowercase())
        .unwrap_or_default();
    let filename = parse_filename(headers);
    let content_id =
        strip_angle_brackets(headers.get("content-id").map(String::as_str).unwrap_or(""));

    if mime_type == "message/rfc822" {
        // A forwarded message arrives in two shapes and only one of them is
        // body text. `Content-Disposition: attachment` means the whole .eml is
        // the attachment: recursing would drop it from the list entirely and
        // let the forwarded text stand in for the real body. Inline is the
        // other shape — read the inner part, but keep the forward itself
        // downloadable.
        if disposition_raw.starts_with("attachment") {
            return attachment_result(
                part_path,
                filename,
                &mime_type,
                body.to_vec(),
                body,
                &encoding,
                decode_attachment_bytes,
                content_id,
                AttachmentDisposition::Attachment,
            );
        }
        let (inner_header, inner_body) = split_head_and_body(body);
        let inner = parse_part(
            &parse_header_block(inner_header),
            inner_body,
            depth + 1,
            // The encapsulated message's own parts are numbered directly under
            // this part, so BODY[1.1.2] is the second part *inside* the forward
            // while BODY[1.1] is the forward itself.
            part_path,
            decode_attachment_bytes,
        );
        // The forwarded text belongs to the body; its HTML does not — the
        // detail view renders html in preference to text, so promoting it would
        // hide the sender's actual message behind the forward.
        let mut result = ParseResult {
            text: inner.text,
            ..Default::default()
        };
        result.attachments.push(forwarded_attachment(
            part_path,
            filename,
            body,
            &encoding,
            decode_attachment_bytes,
            content_id,
        ));
        result.attachments.extend(inner.attachments);
        result.has_more = inner.has_more;
        return result;
    }

    if mime_type.starts_with("multipart/") {
        let Some(boundary) = parameters.get("boundary").filter(|value| !value.is_empty()) else {
            return ParseResult::default();
        };
        let mut result = ParseResult::default();
        for (index, part) in split_parts(body, boundary).iter().enumerate() {
            let child_path = format!("{part_path}.{}", index + 1);
            let child = parse_part(
                &part.headers,
                &part.body,
                depth + 1,
                &child_path,
                decode_attachment_bytes,
            );
            if result.text.is_none() {
                result.text = child.text;
            }
            if result.html.is_none() {
                result.html = child.html;
            }
            result.attachments.extend(child.attachments);
            if child.has_more {
                result.has_more = true;
            }
        }
        // For multipart/alternative keep whichever text candidate was seen
        // first. Recurse order is source order (most clients put plain first),
        // but the spec allows HTML first, so text is also derived from HTML
        // explicitly when there is no text part.
        if mime_type == "multipart/alternative" && result.text.is_none() {
            if let Some(html) = &result.html {
                result.text = Some(html::strip(html));
            }
        }
        return result;
    }

    let decoded = match encoding.as_str() {
        "base64" => base64_decode(&String::from_utf8_lossy(body)).unwrap_or_else(|| body.to_vec()),
        "quoted-printable" => decode_quoted_printable(body),
        _ => body.to_vec(),
    };

    if mime_type.starts_with("text/") {
        // An explicit `Content-Disposition: attachment` on a text part is still
        // an attachment (rare but legal).
        if disposition_raw.starts_with("attachment") {
            return attachment_result(
                part_path,
                filename,
                &mime_type,
                decoded,
                body,
                &encoding,
                decode_attachment_bytes,
                content_id,
                AttachmentDisposition::Attachment,
            );
        }
        return text_result(
            &mime_type,
            parameters.get("charset").map(String::as_str),
            &decoded,
            content_id,
        );
    }

    // Non-text leaf: everything else is an attachment. Images without an
    // explicit disposition default to `.inline` so the HTML renderer can
    // resolve `cid:` references even when the sender forgot the disposition.
    let disposition = if disposition_raw.starts_with("inline") {
        AttachmentDisposition::Inline
    } else if disposition_raw.starts_with("attachment") {
        AttachmentDisposition::Attachment
    } else if mime_type.starts_with("image/") {
        AttachmentDisposition::Inline
    } else {
        AttachmentDisposition::Attachment
    };
    attachment_result(
        part_path,
        filename,
        &mime_type,
        decoded,
        body,
        &encoding,
        decode_attachment_bytes,
        content_id,
        disposition,
    )
}

fn text_result(
    mime_type: &str,
    charset: Option<&str>,
    data: &[u8],
    _content_id: Option<String>,
) -> ParseResult {
    let mut result = ParseResult::default();
    let decoded = decode_charset(data, charset);
    if mime_type == "text/html" {
        if decoded.chars().count() > HTML_CAP {
            result.html = Some(decoded.chars().take(HTML_CAP).collect());
            result.has_more = true;
        } else {
            result.html = Some(decoded);
        }
    } else {
        // text/plain and any other text/* lands here.
        let count = decoded.chars().count();
        if count > TEXT_CAP {
            let mut text: String = decoded.chars().take(TEXT_CAP).collect();
            text.push_str(&format!("\n[…truncated, original {count} bytes]"));
            result.text = Some(text);
            result.has_more = true;
        } else {
            result.text = Some(decoded);
        }
    }
    result
}

#[allow(clippy::too_many_arguments)]
fn attachment_result(
    part_path: &str,
    filename: Option<String>,
    mime_type: &str,
    decoded: Vec<u8>,
    encoded: &[u8],
    encoding: &str,
    decode_bytes: bool,
    content_id: Option<String>,
    disposition: AttachmentDisposition,
) -> ParseResult {
    let mut result = ParseResult::default();
    result.attachments.push(ParsedAttachment {
        id: part_path.to_owned(),
        filename,
        mime_type: mime_type.to_owned(),
        size: if decode_bytes {
            decoded.len()
        } else {
            estimated_size(encoding, encoded)
        },
        content_id,
        disposition,
        data: if decode_bytes { decoded } else { Vec::new() },
    });
    result
}

/// The .eml of an inline `message/rfc822` part, downloadable under this part's
/// own id. The forwarded bytes are stored verbatim, so the wrapper's transfer
/// encoding is irrelevant and `body` is both forms.
fn forwarded_attachment(
    part_path: &str,
    filename: Option<String>,
    body: &[u8],
    encoding: &str,
    decode_bytes: bool,
    content_id: Option<String>,
) -> ParsedAttachment {
    ParsedAttachment {
        id: part_path.to_owned(),
        filename,
        mime_type: "message/rfc822".to_owned(),
        size: if decode_bytes {
            body.len()
        } else {
            estimated_size(encoding, body)
        },
        content_id,
        disposition: AttachmentDisposition::Inline,
        data: if decode_bytes {
            body.to_vec()
        } else {
            Vec::new()
        },
    }
}

/// Decoded byte count without paying for the decode.
///
/// BASE64 is a 4→3 expansion minus padding; QP shrinks by two bytes per
/// `=XX` escape and three per soft line break. v3 called this "close enough
/// for a UI size label"; the scan here is what that comment always intended
/// (v3's loop only inspected every third byte), so reported sizes are exact
/// for well-formed input and still bounded for broken input.
pub fn estimated_size(encoding: &str, encoded: &[u8]) -> usize {
    match encoding {
        "base64" => {
            // Folded base64 carries CRLF between lines; the decoded size is a
            // property of the payload bytes, not the wire text.
            let bytes = encoded
                .iter()
                .filter(|&&byte| !byte.is_ascii_whitespace() && byte != b'=')
                .count();
            bytes * 3 / 4
        }
        "quoted-printable" => {
            let saved = encoded.len();
            let mut removed = 0usize;
            let mut index = 0usize;
            while index < encoded.len() {
                if encoded[index] != b'=' {
                    index += 1;
                    continue;
                }
                if encoded.get(index + 1) == Some(&b'\n') {
                    removed += 2;
                    index += 2;
                } else if encoded.get(index + 1) == Some(&b'\r')
                    && encoded.get(index + 2) == Some(&b'\n')
                {
                    removed += 3;
                    index += 3;
                } else if index + 2 < encoded.len()
                    && crate::mime::charset::hex_value(encoded[index + 1]).is_some()
                    && crate::mime::charset::hex_value(encoded[index + 2]).is_some()
                {
                    removed += 2;
                    index += 3;
                } else {
                    index += 1;
                }
            }
            saved.saturating_sub(removed)
        }
        _ => encoded.len(),
    }
}

/// Filename from `Content-Disposition: attachment; filename=...` or
/// `Content-Type: ...; name=...`. RFC 5987's `filename*` / `name*` is only
/// consulted when the plain form is absent: when a sender supplies both,
/// RFC 6266 §4.3 keeps the plain one.
fn parse_filename(headers: &BTreeMap<String, String>) -> Option<String> {
    let disposition = headers
        .get("content-disposition")
        .map(String::as_str)
        .unwrap_or("");
    if let Some(name) = header_parameter(disposition, "filename") {
        return Some(crate::mime::headers::decode_rfc2047(&name));
    }
    if let Some(extended) = header_parameter(disposition, "filename*") {
        return decode_rfc5987(&extended);
    }
    let content_type = headers
        .get("content-type")
        .map(String::as_str)
        .unwrap_or("");
    if let Some(name) = header_parameter(content_type, "name") {
        return Some(crate::mime::headers::decode_rfc2047(&name));
    }
    if let Some(extended) = header_parameter(content_type, "name*") {
        return decode_rfc5987(&extended);
    }
    None
}

/// `Content-ID: <image001@example.com>` → `image001@example.com`. Angle
/// brackets are required by RFC 2392 but some clients omit them.
fn strip_angle_brackets(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with('<') && trimmed.ends_with('>') && trimmed.len() >= 2 {
        return Some(trimmed[1..trimmed.len() - 1].to_owned());
    }
    Some(trimmed.to_owned())
}

/// `text/plain; charset="utf-8"; boundary=x` → (`text/plain`, params).
/// Parameters are split on `;`, so a quoted value containing a semicolon would
/// be misread — no sender in practice does that, and guessing wrong only costs
/// a charset or a boundary (v3's documented trade-off).
pub fn parse_content_type(value: Option<&str>) -> (String, BTreeMap<String, String>) {
    let Some(value) = value else {
        return ("text/plain".to_owned(), BTreeMap::new());
    };
    if value.trim().is_empty() {
        return ("text/plain".to_owned(), BTreeMap::new());
    }
    let mut segments = value.split(';');
    let mime_type = segments
        .next()
        .unwrap_or("text/plain")
        .trim()
        .to_ascii_lowercase();
    let mut parameters = BTreeMap::new();
    for segment in segments {
        let Some((name, parameter_value)) = segment.split_once('=') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        if name.is_empty() {
            continue;
        }
        let parameter_value = parameter_value
            .trim()
            .trim_matches(|ch| ch == '"' || ch == '\'');
        parameters.insert(name, parameter_value.to_owned());
    }
    (mime_type, parameters)
}

struct RawPart {
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

/// `multipart` body → its parts, split on `--boundary` delimiters. The preamble
/// and epilogue are discarded; a missing closing delimiter is tolerated (the
/// last part is returned as-is).
fn split_parts(body: &[u8], boundary: &str) -> Vec<RawPart> {
    let mut normalized = Vec::with_capacity(body.len() + 2);
    normalized.extend_from_slice(b"\r\n");
    normalized.extend_from_slice(&crlf_framed(body));
    let delimiter = format!("\r\n--{boundary}").into_bytes();

    let mut parts = Vec::new();
    let mut search_start = 0usize;
    let mut part_start: Option<usize> = None;
    while let Some(position) = find_subslice(&normalized, &delimiter, search_start) {
        if let Some(start) = part_start.take() {
            parts.push(make_part(&normalized[start..position]));
        }
        let after = position + delimiter.len();
        // `--boundary--` is the closing delimiter, `--boundary` alone the start
        // of the next part: the two bytes after the match decide.
        if normalized[after..].starts_with(b"--") {
            break;
        }
        let mut content_start = after;
        if normalized[content_start..].starts_with(b"\r\n") {
            content_start += 2;
        } else if normalized[content_start..].starts_with(b"\n") {
            content_start += 1;
        }
        part_start = Some(content_start);
        search_start = content_start;
    }
    if let Some(start) = part_start {
        parts.push(make_part(&normalized[start..]));
    }
    parts
}

fn make_part(data: &[u8]) -> RawPart {
    let (header, body) = split_head_and_body(data);
    RawPart {
        headers: parse_header_block(header),
        body: body.to_vec(),
    }
}

/// Inserts the missing CR in front of every LF that is not already part of a
/// CRLF. A `--boundary` is only recognized after CRLF, and LF-only line
/// endings are accepted everywhere else, so without this an LF-only multipart
/// collapses into a single part and every attachment in it is lost into the
/// body text.
fn crlf_framed(body: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(body.len() + 2);
    for (index, &byte) in body.iter().enumerate() {
        if byte == b'\n' && (index == 0 || body[index - 1] != b'\r') {
            output.push(b'\r');
        }
        output.push(byte);
    }
    output
}

fn find_subslice(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || from > haystack.len() || haystack.len() - from < needle.len() {
        return None;
    }
    haystack[from..]
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|offset| from + offset)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attachment_names(parsed: &ParsedMessage) -> Vec<&str> {
        parsed
            .attachments
            .iter()
            .map(|attachment| attachment.filename.as_deref().unwrap_or("<none>"))
            .collect()
    }

    #[test]
    fn simple_plain_text_message() {
        let raw = b"From: a@example.com\r\nSubject: hi\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nHello\r\nthere";
        let parsed = parse(raw);
        assert_eq!(parsed.text, "Hello\r\nthere");
        assert!(parsed.html.is_none());
        assert!(parsed.attachments.is_empty());
        assert!(!parsed.has_more);
    }

    #[test]
    fn gbk_body_decodes_through_the_charset_header() {
        let mut raw =
            b"Content-Type: text/plain; charset=gb2312\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
                .to_vec();
        raw.extend_from_slice(&[0xD6, 0xD0, 0xCE, 0xC4]);
        let parsed = parse(&raw);
        assert_eq!(parsed.text, "中文");
    }

    #[test]
    fn gb18030_encoded_word_subject_in_headers_is_decoded_on_demand() {
        let raw = b"Subject: =?GBK?B?u+HS6bzN0qo=?=\r\n\r\nbody";
        let headers = crate::mime::headers::decode_headers(raw);
        assert_eq!(headers.get("subject").unwrap(), "会议纪要");
    }

    #[test]
    fn base64_quoted_printable_bodies_decode() {
        let raw = b"Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n5L2g5aW9";
        assert_eq!(parse(raw).text, "你好");
        let raw = b"Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\ncaf=C3=A9";
        assert_eq!(parse(raw).text, "café");
    }

    #[test]
    fn multipart_alternative_prefers_plain_and_keeps_html() {
        let raw = b"Content-Type: multipart/alternative; boundary=\"b\"\r\n\r\n--b\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nplain body\r\n--b\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<p>html body</p>\r\n--b--\r\n";
        let parsed = parse(raw);
        assert_eq!(parsed.text, "plain body");
        assert_eq!(parsed.html.as_deref(), Some("<p>html body</p>"));
    }

    #[test]
    fn html_only_message_falls_back_to_stripped_text() {
        let raw =
            b"Content-Type: text/html; charset=UTF-8\r\n\r\n<p>Hello <b>world</b> &amp; you</p>";
        let parsed = parse(raw);
        assert_eq!(parsed.text, "Hello world & you");
        assert!(parsed.html.as_deref().unwrap().contains("<b>"));
    }

    #[test]
    fn nested_multipart_and_attachment_part_paths() {
        let raw = b"Content-Type: multipart/mixed; boundary=m\r\n\r\n\
--m\r\nContent-Type: multipart/alternative; boundary=a\r\n\r\n\
--a\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nplain\r\n\
--a\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<b>html</b>\r\n--a--\r\n\
--m\r\nContent-Type: application/pdf; name=\"report.pdf\"\r\nContent-Disposition: attachment; filename=\"report.pdf\"\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERg==\r\n--m--\r\n";
        let parsed = parse(raw);
        assert_eq!(parsed.text, "plain");
        assert_eq!(parsed.html.as_deref(), Some("<b>html</b>"));
        assert_eq!(parsed.attachments.len(), 1);
        let attachment = &parsed.attachments[0];
        assert_eq!(attachment.id, "1.2");
        assert_eq!(attachment.filename.as_deref(), Some("report.pdf"));
        assert_eq!(attachment.mime_type, "application/pdf");
        assert_eq!(attachment.size, 4);
        assert!(
            attachment.data.is_empty(),
            "metadata parse must not decode bytes"
        );
    }

    #[test]
    fn attachment_bytes_decode_on_request() {
        let raw = b"Content-Type: multipart/mixed; boundary=m\r\n\r\n\
--m\r\nContent-Type: text/plain\r\n\r\nbody\r\n\
--m\r\nContent-Type: image/png\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: inline; filename=pic.png\r\nContent-ID: <pic1@example.com>\r\n\r\niVBORw0KGgo=\r\n--m--\r\n";
        let parsed = parse_with_options(raw, true);
        assert_eq!(parsed.text, "body");
        let attachment = &parsed.attachments[0];
        assert_eq!(attachment.disposition, AttachmentDisposition::Inline);
        assert_eq!(attachment.content_id.as_deref(), Some("pic1@example.com"));
        assert_eq!(attachment.filename.as_deref(), Some("pic.png"));
        assert_eq!(attachment.data, b"\x89PNG\r\n\x1a\n".to_vec());
    }

    #[test]
    fn inline_image_without_disposition_defaults_to_inline() {
        let raw = b"Content-Type: image/gif\r\nContent-Transfer-Encoding: base64\r\n\r\nR0lGODlhAQABAAAAACw=";
        let parsed = parse_with_options(raw, true);
        assert_eq!(
            parsed.attachments[0].disposition,
            AttachmentDisposition::Inline
        );
        assert_eq!(parsed.attachments[0].id, "1");
    }

    #[test]
    fn text_part_with_attachment_disposition_is_an_attachment() {
        let raw = b"Content-Type: text/plain; charset=UTF-8; name=\"notes.txt\"\r\nContent-Disposition: attachment; filename=\"notes.txt\"\r\n\r\nhello";
        let parsed = parse_with_options(raw, true);
        assert_eq!(parsed.text, "");
        assert_eq!(attachment_names(&parsed), ["notes.txt"]);
        assert_eq!(parsed.attachments[0].data, b"hello");
    }

    #[test]
    fn rfc5987_filename_wins_when_plain_filename_is_absent() {
        let raw = b"Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename*=UTF-8''%E4%BC%9A%E8%AE%AE.pdf\r\n\r\nx";
        let parsed = parse_with_options(raw, false);
        assert_eq!(parsed.attachments[0].filename.as_deref(), Some("会议.pdf"));
    }

    #[test]
    fn lf_only_multipart_still_splits() {
        let raw = b"Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/plain\n\nbody\n--b\nContent-Type: application/zip; name=\"a.zip\"\nContent-Disposition: attachment; filename=\"a.zip\"\n\nPK\n--b--\n";
        let parsed = parse(raw);
        assert_eq!(parsed.text, "body");
        assert_eq!(attachment_names(&parsed), ["a.zip"]);
    }

    #[test]
    fn inline_forwarded_message_keeps_text_and_eml_attachment() {
        let raw = b"Content-Type: message/rfc822\r\n\r\nFrom: orig@example.com\r\nSubject: Original\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nforwarded text";
        let parsed = parse_with_options(raw, true);
        assert_eq!(parsed.text, "forwarded text");
        assert!(parsed.html.is_none(), "forwarded html must not be promoted");
        assert_eq!(parsed.attachments.len(), 1);
        assert_eq!(parsed.attachments[0].mime_type, "message/rfc822");
        assert_eq!(
            parsed.attachments[0].disposition,
            AttachmentDisposition::Inline
        );
        assert_eq!(parsed.attachments[0].data, b"From: orig@example.com\r\nSubject: Original\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nforwarded text");
    }

    #[test]
    fn forwarded_message_with_attachment_disposition_is_not_recursed() {
        let raw = b"Content-Type: message/rfc822\r\nContent-Disposition: attachment; filename=\"fwd.eml\"\r\n\r\nSubject: inner\r\n\r\ninner text";
        let parsed = parse_with_options(raw, true);
        assert_eq!(parsed.text, "");
        assert_eq!(attachment_names(&parsed), ["fwd.eml"]);
        assert_eq!(
            parsed.attachments[0].data,
            b"Subject: inner\r\n\r\ninner text"
        );
    }

    #[test]
    fn text_truncation_sets_has_more_and_marks_the_tail() {
        let body = "x".repeat(TEXT_CAP + 5);
        let raw = format!("Content-Type: text/plain; charset=UTF-8\r\n\r\n{body}");
        let parsed = parse(raw.as_bytes());
        assert!(parsed.has_more);
        assert!(parsed.text.starts_with(&"x".repeat(TEXT_CAP)));
        assert!(parsed.text.contains("truncated, original"));
    }

    #[test]
    fn missing_boundary_yields_empty_result_without_panicking() {
        let parsed = parse(b"Content-Type: multipart/mixed\r\n\r\nanything");
        assert_eq!(parsed.text, "");
        assert!(parsed.attachments.is_empty());
    }

    #[test]
    fn deep_nesting_stops_at_the_depth_cap() {
        let mut raw = String::new();
        let mut closing = String::new();
        for index in 0..9 {
            raw.push_str(&format!(
                "Content-Type: multipart/mixed; boundary=b{index}\r\n\r\n--b{index}\r\n"
            ));
            closing = format!("--b{}--\r\n", index);
        }
        raw.push_str("Content-Type: text/plain\r\n\r\nbottom\r\n");
        raw.push_str(&closing);
        let parsed = parse(raw.as_bytes());
        // No panic, and the bottom is beyond the cap.
        assert_eq!(parsed.text, "");
    }

    #[test]
    fn to_and_cc_headers_are_routable_addresses() {
        let raw = b"To: \"Zhang, Wei\" <wei@example.com>, bob@example.com\r\nCc: carol@example.com (Carol)\r\n\r\nbody";
        let parsed = parse(raw);
        assert_eq!(parsed.to, ["wei@example.com", "bob@example.com"]);
        assert_eq!(parsed.cc, ["carol@example.com"]);
    }

    #[test]
    fn content_type_parameter_parsing() {
        let (mime_type, parameters) =
            parse_content_type(Some(r#"text/plain; charset="UTF-8"; boundary=b1"#));
        assert_eq!(mime_type, "text/plain");
        assert_eq!(parameters.get("charset").unwrap(), "UTF-8");
        assert_eq!(parameters.get("boundary").unwrap(), "b1");
        let (mime_type, parameters) = parse_content_type(None);
        assert_eq!(mime_type, "text/plain");
        assert!(parameters.is_empty());
    }
}
