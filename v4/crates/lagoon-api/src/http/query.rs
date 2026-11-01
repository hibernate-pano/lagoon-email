//! Query-string parsing, with v3's tolerance.
//!
//! `application/x-www-form-urlencoded` semantics: `+` is a space, `%XX` is a
//! byte. A malformed escape leaves the component as the raw text - the same
//! fallback as `String.removingPercentEncoding ?? raw`, which keeps a stray
//! `%` in a sender address from turning a 200 into a 400.

use axum::http::Uri;

/// Decoded `name=value` pairs, in the order the query carried them.
pub fn parse(uri: &Uri) -> Vec<(String, String)> {
    let Some(query) = uri.query() else {
        return Vec::new();
    };
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| match pair.split_once('=') {
            Some((name, value)) => (decode_component(name), decode_component(value)),
            None => (decode_component(pair), String::new()),
        })
        .collect()
}

/// The last value for `name`.
///
/// A dictionary built from an ordered list keeps the last occurrence, and that
/// is what the Swift side does when it folds `queryParameters` into a
/// dictionary.
pub fn get<'a>(pairs: &'a [(String, String)], name: &str) -> Option<&'a str> {
    pairs
        .iter()
        .rev()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

fn decode_component(raw: &str) -> String {
    if !raw.contains('%') && !raw.contains('+') {
        return raw.to_owned();
    }
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => {
                out.push(b' ');
                index += 1;
            }
            b'%' => {
                let decoded = bytes
                    .get(index + 1)
                    .and_then(|high| hex_value(*high))
                    .zip(bytes.get(index + 2).and_then(|low| hex_value(*low)))
                    .map(|(high, low)| (high << 4) | low);
                match decoded {
                    Some(byte) => {
                        out.push(byte);
                        index += 3;
                    }
                    // Not a valid escape: give the caller the raw text, like
                    // `removingPercentEncoding` returning nil and the caller
                    // falling back to the untouched value.
                    None => return raw.to_owned(),
                }
            }
            byte => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8(out).unwrap_or_else(|_| raw.to_owned())
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

    fn uri(raw: &str) -> Uri {
        raw.parse().expect("uri")
    }

    #[test]
    fn decodes_form_encoding() {
        let pairs = parse(&uri("/api/messages?accountId=abc&sender=a%40b.example&q=x+y"));
        assert_eq!(get(&pairs, "accountId"), Some("abc"));
        assert_eq!(get(&pairs, "sender"), Some("a@b.example"));
        assert_eq!(get(&pairs, "q"), Some("x y"));
        assert_eq!(get(&pairs, "missing"), None);
    }

    #[test]
    fn a_malformed_escape_is_left_alone() {
        let pairs = parse(&uri("/api/messages?sender=100%25%zz"));
        assert_eq!(get(&pairs, "sender"), Some("100%25%zz"));
    }

    #[test]
    fn duplicate_names_take_the_last_value() {
        let pairs = parse(&uri("/x?a=1&a=2"));
        assert_eq!(get(&pairs, "a"), Some("2"));
    }

    #[test]
    fn no_query_is_an_empty_list() {
        assert!(parse(&uri("/healthz")).is_empty());
    }
}
