//! Builds the RFC 5322 message the SMTP path sends verbatim.
//!
//! Ported from v3 `MIMEBuilder.swift`. Everything is CRLF-framed and the body
//! is base64, so no line can ever need dot-stuffing or folding.
//!
//! The header-safety rule is an incident fix, not decoration: every value
//! interpolated below is remote-controlled on at least one path (a reply's
//! subject, Message-ID and References are copied out of the message being
//! answered, and RFC 2047 decoding there can turn `=0D=0A` back into a real
//! CRLF). RFC 5322 §2.2.3 admits no CR, LF or NUL in a field value, so they are
//! dropped here — the one place every header of every outgoing message is
//! assembled. A subject carrying `\r\nBcc: victim@…` must not mint a header.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;

use crate::mime::headers::{parse_address_list, split_address_list};
use crate::mime::html;
use crate::mime::parser::AttachmentDisposition;
use crate::timefmt::{format_rfc5322_date, now_unix};

/// Largest single attachment, in bytes (aligned with the 25 MB providers cap).
pub const MAX_ATTACHMENT_BYTES: usize = 25 * 1024 * 1024;

/// A file the user picked to send, or a whole message being forwarded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboundAttachment {
    pub filename: String,
    pub mime_type: String,
    pub data: Vec<u8>,
    /// A forwarded message is `inline`: the recipient's client renders the
    /// original rather than offering it as a file to save.
    pub disposition: AttachmentDisposition,
}

impl OutboundAttachment {
    pub fn new(filename: impl Into<String>, mime_type: impl Into<String>, data: Vec<u8>) -> Self {
        Self {
            filename: filename.into(),
            mime_type: mime_type.into(),
            data,
            disposition: AttachmentDisposition::Attachment,
        }
    }

    pub fn inline(
        filename: impl Into<String>,
        mime_type: impl Into<String>,
        data: Vec<u8>,
    ) -> Self {
        Self {
            filename: filename.into(),
            mime_type: mime_type.into(),
            data,
            disposition: AttachmentDisposition::Inline,
        }
    }

    /// Whether this attachment may be sent.
    pub fn is_sendable(&self) -> bool {
        !self.data.is_empty() && self.data.len() <= MAX_ATTACHMENT_BYTES
    }
}

/// A message to send. `in_reply_to`/`references` are the RFC 5322 header values
/// (already bracketed) threaded from the message being replied to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboundMessage {
    pub from_email: String,
    pub from_name: Option<String>,
    /// Primary recipients, comma-joined into a single `To:` header.
    pub to: String,
    /// Carbon-copy recipients. Empty means the `Cc:` header is omitted
    /// entirely rather than emitted blank.
    pub cc: Vec<String>,
    /// Blind carbon-copy recipients: in the **envelope**, never in a header.
    pub bcc: Vec<String>,
    pub subject: String,
    pub body: String,
    pub in_reply_to: Option<String>,
    pub references: Option<String>,
    /// Replies add the de-duplicated `Re:` prefix and carry thread headers;
    /// new messages keep the subject exactly as typed.
    pub is_reply: bool,
    pub attachments: Vec<OutboundAttachment>,
}

impl OutboundMessage {
    /// The `To:` line split into routable addresses.
    pub fn recipient_addresses(&self) -> Vec<String> {
        parse_address_list(&self.to)
    }

    /// The envelope recipient list: every `To` address plus every `Cc` and
    /// `Bcc`, one forward-path per entry, duplicates dropped
    /// case-insensitively. Bcc is here because the *headers* must never name
    /// it, while the *envelope* must, or the blind copy would never be
    /// delivered at all.
    pub fn envelope_recipients(&self) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        let mut result = Vec::new();
        for raw in self
            .recipient_addresses()
            .into_iter()
            .chain(self.cc.iter().flat_map(|value| parse_address_list(value)))
            .chain(self.bcc.iter().flat_map(|value| parse_address_list(value)))
        {
            let address = raw.trim_matches(|ch| ch == '<' || ch == '>').trim();
            if address.is_empty() {
                continue;
            }
            if seen.insert(address.to_ascii_lowercase()) {
                result.push(address.to_owned());
            }
        }
        result
    }
}

/// A reply: `Re:` prefix, thread headers when present.
pub fn build_reply(outbound: &OutboundMessage, message_id: &str) -> Vec<u8> {
    build(outbound, message_id, now_unix(), true)
}

/// A new message: subject exactly as typed, no thread headers.
pub fn build_new_message(outbound: &OutboundMessage, message_id: &str) -> Vec<u8> {
    build(outbound, message_id, now_unix(), false)
}

/// Deterministic variants for tests and for callers that already know "now".
pub fn build_reply_at(outbound: &OutboundMessage, message_id: &str, now: i64) -> Vec<u8> {
    build(outbound, message_id, now, true)
}

pub fn build_new_message_at(outbound: &OutboundMessage, message_id: &str, now: i64) -> Vec<u8> {
    build(outbound, message_id, now, false)
}

fn build(outbound: &OutboundMessage, message_id: &str, now: i64, reply: bool) -> Vec<u8> {
    let subject = subject_header(&outbound.subject, reply);
    let mut lines: Vec<String> = Vec::new();
    lines.push(format!(
        "From: {}",
        address(&outbound.from_email, outbound.from_name.as_deref())
    ));
    lines.push(format!("To: {}", address_list(&outbound.to)));
    // Cc is omitted entirely when empty — a bare Cc: is legal but many spam
    // filters score it.
    if !outbound.cc.is_empty() {
        lines.push(format!("Cc: {}", address_list(&outbound.cc.join(", "))));
    }
    // Bcc is **never** written. That is what makes it blind.
    lines.push(format!("Subject: {}", header_safe(&subject)));
    lines.push(format!("Date: {}", format_rfc5322_date(now)));
    lines.push(format!("Message-ID: {}", header_safe(message_id)));
    if reply {
        if let Some(in_reply_to) = outbound
            .in_reply_to
            .as_deref()
            .filter(|value| !value.is_empty())
        {
            lines.push(format!("In-Reply-To: {}", header_safe(in_reply_to)));
        }
        if let Some(references) = outbound
            .references
            .as_deref()
            .filter(|value| !value.is_empty())
        {
            lines.push(format!("References: {}", header_safe(references)));
        }
    }
    lines.push("MIME-Version: 1.0".to_owned());
    let headers = lines.join("\r\n");

    if outbound.attachments.is_empty() {
        return plain_text_body(&headers, &outbound.body);
    }
    multipart_mixed(&headers, outbound, message_id)
}

/// The single-part case: `text/plain`, base64, CRLF-framed.
fn plain_text_body(headers: &str, body: &str) -> Vec<u8> {
    let mut message = String::new();
    message.push_str(headers);
    message.push_str("\r\nContent-Type: text/plain; charset=UTF-8");
    message.push_str("\r\nContent-Transfer-Encoding: base64");
    message.push_str("\r\n\r\n");
    message.push_str(&base64_lines(body.as_bytes()));
    message.push_str("\r\n");
    message.into_bytes()
}

/// `multipart/mixed` (RFC 2046 §5.1.4): the body the user typed first, then one
/// part per attachment. `multipart/alternative` would be wrong — it means "the
/// same content in several forms", not "the body plus files".
fn multipart_mixed(headers: &str, outbound: &OutboundMessage, message_id: &str) -> Vec<u8> {
    let boundary = format!("lagoon-{}", boundary_token(outbound, message_id));
    let mut message = String::new();
    message.push_str(headers);
    message.push_str(&format!(
        "\r\nContent-Type: multipart/mixed; boundary=\"{boundary}\""
    ));
    message.push_str("\r\n\r\n");

    // The body part.
    message.push_str(&format!("--{boundary}\r\n"));
    message.push_str("Content-Type: text/plain; charset=UTF-8\r\n");
    message.push_str("Content-Transfer-Encoding: base64\r\n\r\n");
    message.push_str(&base64_lines(outbound.body.as_bytes()));
    message.push_str("\r\n");

    // One part per attachment.
    for attachment in &outbound.attachments {
        message.push_str(&format!("--{boundary}\r\n"));
        message.push_str(&format!(
            "Content-Type: {}\r\n",
            content_type(&attachment.mime_type)
        ));
        message.push_str("Content-Transfer-Encoding: base64\r\n");
        message.push_str(&format!(
            "Content-Disposition: {}\r\n\r\n",
            content_disposition(attachment)
        ));
        message.push_str(&base64_lines(&attachment.data));
        message.push_str("\r\n");
    }

    // The closing delimiter, preceded by CRLF as RFC 2046 requires.
    message.push_str(&format!("--{boundary}--\r\n"));
    message.into_bytes()
}

/// A boundary token with no character that could be mistaken for a separator:
/// letters, digits and dashes only. It is derived from the Message-ID (unique
/// per message) and a process-wide counter, so two messages built in the same
/// process can never share one.
fn boundary_token(outbound: &OutboundMessage, message_id: &str) -> String {
    let seed: String = outbound
        .from_email
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .take(8)
        .collect();
    let seed = if seed.is_empty() {
        "lagoon".to_owned()
    } else {
        seed
    };
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    use std::hash::{Hash, Hasher};
    message_id.hash(&mut hasher);
    outbound.from_email.hash(&mut hasher);
    let digest = hasher.finish();
    let counter = BOUNDARY_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    format!("{seed}-{:012x}", digest ^ counter ^ nanos)
}

static BOUNDARY_COUNTER: AtomicU64 = AtomicU64::new(1);

/// A safe `Content-Type` for an attachment.
///
/// The MIME type comes from the client, which read it off the user's file — but
/// it is still remote-controlled as far as this process is concerned, and a
/// CRLF in it would forge a header line. Anything that is not a plain token
/// falls back to `application/octet-stream`.
fn content_type(raw: &str) -> String {
    let trimmed = header_safe(raw).trim().to_owned();
    let allowed = |ch: char| ch.is_ascii_alphanumeric() || "/-+.=;".contains(ch);
    if !trimmed.is_empty()
        && trimmed.chars().count() <= 128
        && trimmed.contains('/')
        && trimmed.chars().all(allowed)
    {
        trimmed
    } else {
        "application/octet-stream".to_owned()
    }
}

/// A safe file name for `Content-Disposition`. It goes into a header, so it must
/// not carry a newline (which would forge a header line) or a quote (which would
/// end the parameter early).
fn filename(raw: &str) -> String {
    let sanitized: String = raw
        .chars()
        .filter(|ch| *ch != '\r' && *ch != '\n')
        .map(|ch| if ch == '"' { '\'' } else { ch })
        .collect();
    let sanitized = sanitized.trim().to_owned();
    if sanitized.is_empty() {
        "attachment".to_owned()
    } else {
        sanitized
    }
}

/// The `Content-Disposition` line for an attachment.
///
/// RFC 6266 §4.1 wants both forms: `filename` for old clients and `filename*`
/// (RFC 5987 percent-encoded UTF-8) for the ones that understand it. Without
/// `filename*`, a Chinese file name arrives as mojibake — the attachment is
/// there, and it is unusable.
fn content_disposition(attachment: &OutboundAttachment) -> String {
    let safe = filename(&attachment.filename);
    let encoded = percent_encode(&safe);
    format!(
        "{}; filename=\"{safe}\"; filename*=UTF-8''{encoded}",
        attachment.disposition.as_str()
    )
}

fn percent_encode(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for &byte in value.as_bytes() {
        let allowed = byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~');
        if allowed {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

/// Ensures exactly one `Re:` prefix. An existing prefix is kept as the sender
/// wrote it, so `re:` is not silently normalized.
pub fn subject_header_value(value: &str, add_reply_prefix: bool) -> String {
    let prefixed = if add_reply_prefix && !value.to_ascii_lowercase().starts_with("re:") {
        format!("Re: {value}")
    } else {
        value.to_owned()
    };
    subject_header(&prefixed, false)
}

/// The `Re:` prefix is ASCII, so only the run from the first non-ASCII
/// character onward becomes an encoded word — `Re: =?UTF-8?B?…?=`, which a
/// receiving client renders as `Re: 会议纪要`.
fn subject_header(value: &str, add_reply_prefix: bool) -> String {
    let prefixed = if add_reply_prefix {
        if value.to_ascii_lowercase().starts_with("re:") {
            value.to_owned()
        } else {
            format!("Re: {value}")
        }
    } else {
        value.to_owned()
    };
    let Some((index, _)) = prefixed.char_indices().find(|(_, ch)| !ch.is_ascii()) else {
        return prefixed;
    };
    let head = &prefixed[..index];
    let tail = &prefixed[index..];
    format!(
        "{head}=?UTF-8?B?{}?=",
        base64::engine::general_purpose::STANDARD.encode(tail.as_bytes())
    )
}

/// `"Name" <addr>` with RFC 2047 for a non-ASCII name, else `<addr>`.
fn address(email: &str, name: Option<&str>) -> String {
    let email = header_safe(email);
    let Some(name) = name.map(header_safe).filter(|name| !name.is_empty()) else {
        return format!("<{email}>");
    };
    if name.is_ascii() {
        format!("\"{name}\" <{email}>")
    } else {
        format!(
            "=?UTF-8?B?{}?= <{email}>",
            base64::engine::general_purpose::STANDARD.encode(name.as_bytes())
        )
    }
}

/// Comma-separated address list → the bracketed form the headers use. The split
/// is RFC 5322's, not a plain `split(',')`: a comma inside a quoted display
/// name belongs to the name. Already-bracketed input passes through unchanged.
fn address_list(raw: &str) -> String {
    split_address_list(&header_safe(raw))
        .into_iter()
        .map(|value| {
            if value.contains('<') {
                value
            } else {
                format!("<{value}>")
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// Every value interpolated above is remote-controlled on at least one path.
/// RFC 5322 admits no CR, LF or NUL in a field value, so they are dropped here
/// rather than folded: folding uses SP/TAB only, so a bare CRLF has to
/// disappear instead of becoming a legal-looking wrap.
fn header_safe(value: &str) -> String {
    value
        .chars()
        .filter(|ch| *ch != '\n' && *ch != '\r' && *ch != '\u{0}')
        .collect()
}

fn base64_lines(data: &[u8]) -> String {
    let encoded = base64::engine::general_purpose::STANDARD.encode(data);
    let bytes = encoded.as_bytes();
    let mut lines = Vec::with_capacity(bytes.len() / 76 + 1);
    let mut index = 0usize;
    while index < bytes.len() {
        let end = (index + 76).min(bytes.len());
        lines.push(&encoded[index..end]);
        index = end;
    }
    lines.join("\r\n")
}

/// HTML → text convenience re-export for providers that only get HTML.
pub fn strip_html(value: &str) -> String {
    html::strip(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outbound() -> OutboundMessage {
        OutboundMessage {
            from_email: "me@example.com".to_owned(),
            from_name: Some("Me".to_owned()),
            to: "alice@example.com".to_owned(),
            cc: Vec::new(),
            bcc: Vec::new(),
            subject: "Hello".to_owned(),
            body: "Plain text body".to_owned(),
            in_reply_to: None,
            references: None,
            is_reply: true,
            attachments: Vec::new(),
        }
    }

    fn parts(message: &[u8]) -> (Vec<(String, String)>, String) {
        let text = String::from_utf8_lossy(message);
        let separator = text.find("\r\n\r\n").expect("header/body separator");
        let header_block = &text[..separator];
        let body = text[separator + 4..].to_owned();
        let mut headers = Vec::new();
        for line in header_block.split("\r\n") {
            if let Some((name, value)) = line.split_once(':') {
                headers.push((name.to_ascii_lowercase(), value.trim().to_owned()));
            }
        }
        (headers, body)
    }

    fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
        headers
            .iter()
            .find(|(field, _)| field == name)
            .map(|(_, value)| value.as_str())
    }

    fn decode_encoded_words(value: &str) -> String {
        let mut result = String::new();
        let mut rest = value;
        while let Some(start) = rest.find("=?UTF-8?B?") {
            result.push_str(&rest[..start]);
            let payload_start = start + "=?UTF-8?B?".len();
            let Some(end) = rest[payload_start..].find("?=") else {
                break;
            };
            let payload = &rest[payload_start..payload_start + end];
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(payload)
                .unwrap_or_default();
            result.push_str(&String::from_utf8_lossy(&bytes));
            rest = &rest[payload_start + end + 2..];
        }
        result.push_str(rest);
        result
    }

    #[test]
    fn reply_uses_crlf_everywhere_and_ends_with_crlf() {
        let message = build_reply(&outbound(), "<m1@lagoon>");
        let text = String::from_utf8_lossy(&message);
        assert!(text.contains("\r\n"));
        assert!(!text.replace("\r\n", "").contains('\n'), "bare LF found");
        assert!(text.ends_with("\r\n"));
    }

    #[test]
    fn reply_ascii_subject_gets_the_re_prefix_once() {
        let (headers, _) = parts(&build_reply(&outbound(), "<m1@lagoon>"));
        assert_eq!(header(&headers, "subject"), Some("Re: Hello"));
        let mut lower = outbound();
        lower.subject = "re: Lunch?".to_owned();
        let (headers, _) = parts(&build_reply(&lower, "<m1@lagoon>"));
        assert_eq!(header(&headers, "subject"), Some("re: Lunch?"));
    }

    #[test]
    fn reply_non_ascii_subject_is_rfc2047_encoded_and_round_trips() {
        let mut message = outbound();
        message.subject = "会议纪要".to_owned();
        let (headers, _) = parts(&build_reply(&message, "<m1@lagoon>"));
        let subject = header(&headers, "subject").unwrap();
        assert!(subject.contains("=?UTF-8?B?"), "{subject}");
        assert!(!subject.contains("会议纪要"), "{subject}");
        assert_eq!(decode_encoded_words(subject), "Re: 会议纪要");
    }

    #[test]
    fn new_message_keeps_subject_and_omits_threading_headers() {
        let mut message = outbound();
        message.subject = "Project kickoff".to_owned();
        message.in_reply_to = Some("<ignored@example.com>".to_owned());
        message.references = Some("<ignored@example.com>".to_owned());
        let (headers, _) = parts(&build_new_message(&message, "<new@lagoon>"));
        assert_eq!(header(&headers, "subject"), Some("Project kickoff"));
        assert_eq!(header(&headers, "in-reply-to"), None);
        assert_eq!(header(&headers, "references"), None);
    }

    #[test]
    fn reply_thread_headers_pass_through_when_present() {
        let mut message = outbound();
        message.in_reply_to = Some("<a@example.com>".to_owned());
        message.references = Some("<root@example.com> <a@example.com>".to_owned());
        let (headers, _) = parts(&build_reply(&message, "<m1@lagoon>"));
        assert_eq!(header(&headers, "in-reply-to"), Some("<a@example.com>"));
        assert_eq!(
            header(&headers, "references"),
            Some("<root@example.com> <a@example.com>")
        );
    }

    #[test]
    fn reply_has_valid_date_and_message_id() {
        let (headers, _) = parts(&build_reply_at(&outbound(), "<m1@lagoon>", 1_789_119_368));
        assert_eq!(header(&headers, "message-id"), Some("<m1@lagoon>"));
        assert_eq!(header(&headers, "mime-version"), Some("1.0"));
        assert_eq!(
            header(&headers, "date"),
            Some("Fri, 11 Sep 2026 09:36:08 +0000")
        );
    }

    #[test]
    fn addresses_carry_the_from_name_and_quote_ascii_names() {
        let (headers, _) = parts(&build_reply(&outbound(), "<m1@lagoon>"));
        assert_eq!(header(&headers, "from"), Some("\"Me\" <me@example.com>"));
        assert_eq!(header(&headers, "to"), Some("<alice@example.com>"));
        let mut bare = outbound();
        bare.from_name = None;
        let (headers, _) = parts(&build_reply(&bare, "<m1@lagoon>"));
        assert_eq!(header(&headers, "from"), Some("<me@example.com>"));
    }

    #[test]
    fn non_ascii_display_name_is_rfc2047_encoded() {
        let mut message = outbound();
        message.from_name = Some("陈其".to_owned());
        let (headers, _) = parts(&build_reply(&message, "<m1@lagoon>"));
        let from = header(&headers, "from").unwrap();
        assert!(!from.contains("陈其"), "{from}");
        assert!(from.contains("=?UTF-8?B?"), "{from}");
        assert_eq!(decode_encoded_words(from), "陈其 <me@example.com>");
    }

    #[test]
    fn body_is_base64_with_short_lines() {
        let mut message = outbound();
        message.body = "这是一段中文回复。".repeat(40);
        let (headers, raw_body) = parts(&build_reply(&message, "<m1@lagoon>"));
        assert_eq!(
            header(&headers, "content-type"),
            Some("text/plain; charset=UTF-8")
        );
        assert_eq!(
            header(&headers, "content-transfer-encoding"),
            Some("base64")
        );
        let lines: Vec<&str> = raw_body
            .split("\r\n")
            .filter(|line| !line.is_empty())
            .collect();
        assert!(!lines.is_empty());
        for line in &lines {
            assert!(line.len() <= 76, "base64 line too long: {}", line.len());
        }
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(lines.join("").as_bytes())
            .unwrap();
        assert_eq!(String::from_utf8(decoded).unwrap(), message.body);
    }

    // ---- Header injection ----------------------------------------------

    fn header_lines(message: &[u8]) -> Vec<String> {
        let text = String::from_utf8_lossy(message);
        let separator = text.find("\r\n\r\n").expect("header/body separator");
        text[..separator].split("\r\n").map(str::to_owned).collect()
    }

    #[test]
    fn subject_crlf_cannot_forge_a_bcc_header_line() {
        let mut message = outbound();
        message.subject = "Lunch?\r\nBcc: victim@evil.example".to_owned();
        let (headers, _) = parts(&build_reply(&message, "<m1@lagoon>"));
        assert!(!header_lines(&build_reply(&message, "<m1@lagoon>"))
            .iter()
            .any(|line| line.to_ascii_lowercase().starts_with("bcc:")));
        assert_eq!(
            header(&headers, "subject"),
            Some("Re: Lunch?Bcc: victim@evil.example")
        );
    }

    #[test]
    fn thread_headers_cannot_forge_header_lines() {
        let mut message = outbound();
        message.in_reply_to = Some("<a@evil.example>\r\nBcc: victim@evil.example".to_owned());
        message.references = Some("<a@evil.example>\nBcc: second@evil.example".to_owned());
        let built = build_reply(&message, "<m1@lagoon>");
        assert!(!header_lines(&built)
            .iter()
            .any(|line| line.to_ascii_lowercase().starts_with("bcc:")));
        let (headers, _) = parts(&built);
        assert_eq!(
            header(&headers, "in-reply-to"),
            Some("<a@evil.example>Bcc: victim@evil.example")
        );
        assert_eq!(
            header(&headers, "references"),
            Some("<a@evil.example>Bcc: second@evil.example")
        );
    }

    #[test]
    fn bare_cr_lf_and_nul_are_removed_from_subject() {
        for injected in [
            "Hi\rBcc: a@evil.example",
            "Hi\nBcc: b@evil.example",
            "Hi\u{0}Bcc: c@evil.example",
        ] {
            let mut message = outbound();
            message.subject = injected.to_owned();
            let built = build_reply(&message, "<m1@lagoon>");
            assert!(!header_lines(&built)
                .iter()
                .any(|line| line.to_ascii_lowercase().starts_with("bcc:")));
        }
    }

    #[test]
    fn to_with_crlf_cannot_forge_a_header_line() {
        let mut message = outbound();
        message.to = "alice@example.com\r\nBcc: victim@evil.example".to_owned();
        let built = build_reply(&message, "<m1@lagoon>");
        assert!(!header_lines(&built)
            .iter()
            .any(|line| line.to_ascii_lowercase().starts_with("bcc:")));
    }

    #[test]
    fn ordinary_values_are_unchanged() {
        let mut message = outbound();
        message.to = "alice@example.com, Bob <bob@example.com>".to_owned();
        message.subject = "Re: 会议纪要".to_owned();
        message.in_reply_to = Some("<a@example.com>".to_owned());
        message.references = Some("<root@example.com> <a@example.com>".to_owned());
        let (headers, _) = parts(&build_reply(&message, "<m1@lagoon>"));
        assert_eq!(
            header(&headers, "to"),
            Some("<alice@example.com>, Bob <bob@example.com>")
        );
        assert_eq!(
            decode_encoded_words(header(&headers, "subject").unwrap()),
            "Re: 会议纪要"
        );
    }

    // ---- Attachments ----------------------------------------------------

    #[test]
    fn attachments_produce_multipart_mixed_with_rfc5987_names() {
        let mut message = outbound();
        message.attachments = vec![
            OutboundAttachment::new("会议.pdf", "application/pdf", b"%PDF-1.4".to_vec()),
            OutboundAttachment::inline(
                "forwarded.eml",
                "message/rfc822",
                b"Subject: x\r\n\r\ny".to_vec(),
            ),
        ];
        let built = build_reply(&message, "<m1@lagoon>");
        let (headers, _) = parts(&built);
        let content_type = header(&headers, "content-type").unwrap();
        assert!(
            content_type.starts_with("multipart/mixed; boundary=\"lagoon-"),
            "{content_type}"
        );

        let parsed = crate::mime::parser::parse_with_options(&built, true);
        assert_eq!(parsed.text, message.body);
        assert_eq!(parsed.attachments.len(), 2);
        assert_eq!(parsed.attachments[0].filename.as_deref(), Some("会议.pdf"));
        assert_eq!(parsed.attachments[0].data, b"%PDF-1.4");
        assert_eq!(
            parsed.attachments[0].disposition,
            AttachmentDisposition::Attachment
        );
        assert_eq!(
            parsed.attachments[1].filename.as_deref(),
            Some("forwarded.eml")
        );
        assert_eq!(
            parsed.attachments[1].disposition,
            AttachmentDisposition::Inline
        );

        let text = String::from_utf8_lossy(&built);
        assert!(
            text.contains("filename*=UTF-8''%E4%BC%9A%E8%AE%AE.pdf"),
            "{text}"
        );
        assert!(text.ends_with("--\r\n") || text.contains("--\r\n"));
    }

    #[test]
    fn hostile_mime_type_falls_back_to_octet_stream() {
        let mut message = outbound();
        message.attachments = vec![OutboundAttachment::new(
            "a\"b\r\nc.bin",
            "application/pdf\r\nBcc: victim@evil.example",
            vec![1, 2, 3],
        )];
        let built = build_reply(&message, "<m1@lagoon>");
        let text = String::from_utf8_lossy(&built);
        assert!(
            text.contains("Content-Type: application/octet-stream"),
            "{text}"
        );
        assert!(!text.to_ascii_lowercase().contains("\r\nbcc:"), "{text}");
        assert!(text.contains("filename=\"a'bc.bin\""), "{text}");
    }

    #[test]
    fn bcc_is_in_the_envelope_but_never_in_the_headers() {
        let mut message = outbound();
        message.cc = vec!["carol@example.com".to_owned()];
        message.bcc = vec!["dave@example.com".to_owned()];
        let built = build_reply(&message, "<m1@lagoon>");
        let (headers, _) = parts(&built);
        assert_eq!(header(&headers, "bcc"), None);
        assert_eq!(header(&headers, "cc"), Some("<carol@example.com>"));
        assert_eq!(
            message.envelope_recipients(),
            ["alice@example.com", "carol@example.com", "dave@example.com"]
        );
    }

    #[test]
    fn envelope_recipients_dedupe_case_insensitively_and_strip_brackets() {
        let mut message = outbound();
        message.to = "Alice@example.com, <alice@EXAMPLE.com>".to_owned();
        message.cc = vec!["ALICE@example.com".to_owned()];
        message.bcc = vec!["bob@example.com".to_owned()];
        assert_eq!(
            message.envelope_recipients(),
            ["Alice@example.com", "bob@example.com"]
        );
    }

    #[test]
    fn quoted_display_name_with_comma_stays_one_recipient() {
        let mut message = outbound();
        message.to = "\"Zhang, Wei\" <wei@example.com>, bob@example.com".to_owned();
        let (headers, _) = parts(&build_reply(&message, "<m1@lagoon>"));
        assert_eq!(
            header(&headers, "to"),
            Some("\"Zhang, Wei\" <wei@example.com>, <bob@example.com>")
        );
        assert_eq!(
            message.recipient_addresses(),
            ["wei@example.com", "bob@example.com"]
        );
    }

    #[test]
    fn message_id_is_header_safe() {
        let built = build_reply(&outbound(), "<m1@lagoon>\r\nBcc: x@evil.example");
        assert!(!header_lines(&built)
            .iter()
            .any(|line| line.to_ascii_lowercase().starts_with("bcc:")));
    }

    #[test]
    fn attachment_limits() {
        assert!(OutboundAttachment::new("a", "text/plain", b"x".to_vec()).is_sendable());
        assert!(!OutboundAttachment::new("a", "text/plain", Vec::new()).is_sendable());
        assert!(
            !OutboundAttachment::new("a", "text/plain", vec![0u8; MAX_ATTACHMENT_BYTES + 1])
                .is_sendable()
        );
    }
}
