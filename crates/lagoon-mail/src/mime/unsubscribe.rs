//! `List-Unsubscribe` — parse it, do not act on it.
//!
//! Why this module only parses
//! ---------------------------
//! The value of `List-Unsubscribe` comes from the message, which means it comes
//! from whoever sent the message. Following it - issuing an HTTP request to a
//! URL a stranger chose - turns "anybody can email me" into "anybody can make my
//! machine send requests", which is the classic SSRF shape: the attacker picks
//! the host, and `http://127.0.0.1:…` and `http://169.254.169.254/…` are both
//! legal URL values.
//!
//! Doing it safely needs DNS resolution followed by IP checks, redirect
//! refusal, timeouts, response size caps, no credentials, and RFC 8058's
//! one-click POST separation. That is its own project, and the product does not
//! need it to be useful: showing the user the publisher's own unsubscribe page,
//! with its host visible, gets them there in one click with zero new attack
//! surface. The app already decided the same way for links in mail bodies
//! (commit 568dfe3: hand them to the system browser instead of navigating in
//! the app window).
//!
//! So: parse, present, and let the system browser do the walking.
//!
//! What is accepted
//! ----------------
//! Only `https:` and `mailto:`. `http:` is dropped even though RFC 2369 allows
//! it: a publisher that only offers cleartext unsubscribe should be reached by
//! the user typing the host, not by this app vouching for the transport.
//! `javascript:`, `data:` and anything else never leave this function.

/// One unsubscribe destination the mail's publisher offered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnsubscribeLink {
    /// The URL as the header gave it, whitespace-trimmed.
    pub url: String,
    pub kind: UnsubscribeKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnsubscribeKind {
    /// An `https://` page the publisher owns.
    Https,
    /// A `mailto:` address, already stripped of any subject/body query.
    Mailto,
}

impl UnsubscribeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            UnsubscribeKind::Https => "https",
            UnsubscribeKind::Mailto => "mailto",
        }
    }
}

/// What a mailbox actually said about unsubscribing.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UnsubscribeLinks {
    pub links: Vec<UnsubscribeLink>,
    /// `List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058).
    ///
    /// Recorded because it is a real fact about the message, and a future
    /// version may use it once there is a safe design for it. Nothing acts on
    /// it today.
    pub one_click: bool,
}

impl UnsubscribeLinks {
    pub fn is_empty(&self) -> bool {
        self.links.is_empty()
    }

    /// The JSON the store keeps (the `unsubscribe_links` column is TEXT).
    ///
    /// Hand-rolled rather than `serde` because this crate has no serde
    /// dependency and the shape is three literals. The escaping rule is the
    /// JSON minimum: `"` and `\` and control characters. URLs from a mail header
    /// are attacker-controlled text, so escaping is not optional here.
    pub fn to_json(&self) -> String {
        let mut out = String::from("[");
        for (index, link) in self.links.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            out.push_str("{\"url\":\"");
            out.push_str(&json_escape(&link.url));
            out.push_str("\",\"kind\":\"");
            out.push_str(link.kind.as_str());
            out.push_str("\",\"oneClick\":");
            out.push_str(if self.one_click { "true" } else { "false" });
            out.push('}');
        }
        out.push(']');
        out
    }
}

/// Escape the four characters JSON requires plus the control range.
fn json_escape(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            // A raw control character is not legal inside a JSON string; the
            // header should never carry one, but it is attacker-controlled text.
            ch if (ch as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

/// Parse a `List-Unsubscribe` header value.
///
/// Tolerant by contract: a malformed segment is dropped and the rest is kept,
/// because the header is written by strangers and one bad URL must not cost the
/// user the good one next to it. Never panics.
pub fn parse_list_unsubscribe(raw: &str) -> UnsubscribeLinks {
    let mut links = Vec::new();
    for segment in split_segments(raw) {
        let candidate = unwrap_angle_brackets(segment.trim());
        if candidate.is_empty() {
            continue;
        }
        if let Some(kind) = classify(candidate) {
            let url = normalise(candidate, kind);
            if url.is_empty() {
                continue;
            }
            // A header that repeats a URL should not produce two buttons.
            if links.iter().any(|link: &UnsubscribeLink| link.url == url) {
                continue;
            }
            links.push(UnsubscribeLink { url, kind });
        }
    }
    UnsubscribeLinks {
        links,
        one_click: false,
    }
}

/// Parse both headers into the shape the message body route reports.
pub fn parse_unsubscribe_headers(
    list_unsubscribe: Option<&str>,
    list_unsubscribe_post: Option<&str>,
) -> UnsubscribeLinks {
    let mut parsed = match list_unsubscribe {
        Some(raw) => parse_list_unsubscribe(raw),
        None => UnsubscribeLinks::default(),
    };
    parsed.one_click = list_unsubscribe_post.is_some_and(is_one_click);
    parsed
}

/// `List-Unsubscribe-Post: List-Unsubscribe=One-Click`, case- and
/// whitespace-insensitive (`One-Click` is the registered token, but a server
/// that writes `one-click` means the same thing).
pub fn is_one_click(raw: &str) -> bool {
    let normalised: String = raw
        .chars()
        .filter(|ch| !ch.is_whitespace())
        .collect::<String>()
        .to_ascii_lowercase();
    normalised.contains("list-unsubscribe=one-click") || normalised.contains("list-unsubscribe=oneclick")
}

/// Split on commas that are outside angle brackets.
///
/// A naive `split(',')` breaks a `mailto:` with multiple recipients
/// (`<mailto:a@x,b@x>`) into two segments and invents a broken link.
fn split_segments(raw: &str) -> Vec<&str> {
    let mut segments = Vec::new();
    let mut depth = 0usize;
    let mut start = 0usize;
    for (index, ch) in raw.char_indices() {
        match ch {
            '<' => depth += 1,
            '>' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                segments.push(&raw[start..index]);
                start = index + 1;
            }
            _ => {}
        }
    }
    segments.push(&raw[start..]);
    segments
}

/// `<https://x>` → `https://x`; anything without brackets is returned trimmed.
fn unwrap_angle_brackets(raw: &str) -> &str {
    let trimmed = raw.trim();
    if let Some(rest) = trimmed.strip_prefix('<') {
        return rest.strip_suffix('>').unwrap_or(rest).trim();
    }
    trimmed
}

/// The scheme this app is willing to show, or `None`.
///
/// Case-insensitive: `HTTPS://` is the same scheme (RFC 3986 §3.1).
fn classify(raw: &str) -> Option<UnsubscribeKind> {
    let lower = raw.to_ascii_lowercase();
    if lower.starts_with("https://") {
        return Some(UnsubscribeKind::Https);
    }
    if lower.starts_with("mailto:") {
        return Some(UnsubscribeKind::Mailto);
    }
    None
}

/// Trim the parts of a URL that carry no destination.
fn normalise(raw: &str, kind: UnsubscribeKind) -> String {
    match kind {
        UnsubscribeKind::Https => {
            // `?subject=unsubscribe` etc. is fine on an https URL: the publisher
            // reads it. Only the whitespace is noise.
            let trimmed = raw.trim();
            // `<https://>` has a scheme and no host. Showing it would be a
            // button that goes nowhere, which reads as a broken app.
            let rest = &trimmed["https://".len()..];
            let host = rest.split(['/', '?', '#']).next().unwrap_or("");
            if host.is_empty() {
                return String::new();
            }
            trimmed.to_owned()
        }
        UnsubscribeKind::Mailto => {
            // Strip `?subject=…`: the address is what the user needs to see, and
            // a query string on a mailto can only confuse a copy-paste.
            let base = raw.split('?').next().unwrap_or(raw);
            base.trim().to_owned()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_an_https_and_a_mailto() {
        let parsed = parse_list_unsubscribe("<https://a.example/u?id=1>, <mailto:u@a.example>");
        assert_eq!(parsed.links.len(), 2);
        assert_eq!(parsed.links[0].kind, UnsubscribeKind::Https);
        assert_eq!(parsed.links[0].url, "https://a.example/u?id=1");
        assert_eq!(parsed.links[1].kind, UnsubscribeKind::Mailto);
        assert_eq!(parsed.links[1].url, "mailto:u@a.example");
    }

    #[test]
    fn accepts_missing_brackets_and_extra_whitespace() {
        let parsed = parse_list_unsubscribe("  https://a.example/u  ,  mailto:x@a.example  ");
        assert_eq!(parsed.links.len(), 2);
        assert_eq!(parsed.links[0].url, "https://a.example/u");
    }

    #[test]
    fn scheme_matching_is_case_insensitive() {
        let parsed = parse_list_unsubscribe("<HTTPS://A.example/U>, <MAILTO:U@A.example>");
        assert_eq!(parsed.links.len(), 2);
        assert_eq!(parsed.links[0].kind, UnsubscribeKind::Https);
        assert_eq!(parsed.links[1].kind, UnsubscribeKind::Mailto);
    }

    #[test]
    fn drops_everything_that_is_not_https_or_mailto() {
        // Each of these is a legal Header value a stranger can write.
        let parsed = parse_list_unsubscribe(
            "<javascript:alert(1)>, <http://plain.example/u>, <data:text/html,<b>x</b>>, \
             <ftp://files.example/u>, <https://ok.example/u>",
        );
        assert_eq!(parsed.links.len(), 1, "{parsed:?}");
        assert_eq!(parsed.links[0].url, "https://ok.example/u");
    }

    #[test]
    fn keeps_a_mailto_with_several_recipients_whole() {
        // A naive comma split would produce `<mailto:a@x` and `b@x>`.
        let parsed = parse_list_unsubscribe("<mailto:a@x.example,b@x.example>");
        assert_eq!(parsed.links.len(), 1);
        assert_eq!(parsed.links[0].url, "mailto:a@x.example,b@x.example");
    }

    #[test]
    fn strips_a_mailto_query_but_keeps_an_https_query() {
        let parsed = parse_list_unsubscribe(
            "<mailto:u@a.example?subject=unsubscribe>, <https://a.example/u?id=1>",
        );
        assert_eq!(parsed.links[0].url, "mailto:u@a.example");
        assert_eq!(parsed.links[1].url, "https://a.example/u?id=1");
    }

    #[test]
    fn an_empty_or_malformed_header_is_empty_not_a_panic() {
        for raw in ["", "   ", ",,,", "<>", "not a url", "<https://>"] {
            let parsed = parse_list_unsubscribe(raw);
            // `<https://>` has a scheme and no host: it is dropped by the
            // host-less check below, not by panicking.
            assert!(parsed.links.is_empty() || parsed.links[0].url.len() > 8, "{raw:?}");
        }
    }

    #[test]
    fn a_url_without_a_host_is_dropped() {
        let parsed = parse_list_unsubscribe("<https://>");
        assert!(parsed.links.is_empty(), "{parsed:?}");
    }

    #[test]
    fn repeats_collapse_to_one_link() {
        let parsed = parse_list_unsubscribe("<https://a.example/u>, <https://a.example/u>");
        assert_eq!(parsed.links.len(), 1);
    }

    #[test]
    fn one_click_needs_the_registered_token() {
        assert!(is_one_click("List-Unsubscribe=One-Click"));
        assert!(is_one_click("list-unsubscribe=one-click"));
        assert!(is_one_click("List-Unsubscribe = One-Click"));
        assert!(!is_one_click("List-Unsubscribe=Two-Click"));
        assert!(!is_one_click(""));
    }

    #[test]
    fn both_headers_combine_into_the_reported_shape() {
        let parsed = parse_unsubscribe_headers(
            Some("<https://a.example/u>"),
            Some("List-Unsubscribe=One-Click"),
        );
        assert_eq!(parsed.links.len(), 1);
        assert!(parsed.one_click);
    }

    #[test]
    fn the_post_header_without_a_list_header_still_reports_one_click() {
        let parsed = parse_unsubscribe_headers(None, Some("List-Unsubscribe=One-Click"));
        assert!(parsed.links.is_empty());
        assert!(parsed.one_click);
    }

    #[test]
    fn the_json_is_well_formed_even_with_a_hostile_url() {
        // A quote or a backslash in a header value must not break the array the
        // store keeps as TEXT.
        let parsed = parse_list_unsubscribe("<https://a.example/\"weird\\path>");
        let json = parsed.to_json();
        assert!(json.starts_with('['), "{json}");
        assert!(json.ends_with(']'), "{json}");
        // The raw quote must appear escaped, never bare: `\"` is legal inside a
        // JSON string, a lone `"` ends it early and the whole column is corrupt.
        assert!(json.contains("\\\""), "the quote must be escaped: {json}");
        assert!(!json.contains("weird\\path"), "the backslash must be escaped: {json}");
        assert!(json.contains("weird\\\\path"), "the backslash must be escaped: {json}");
    }

    #[test]
    fn an_empty_result_is_an_empty_json_array() {
        assert_eq!(parse_list_unsubscribe("").to_json(), "[]");
    }
}
