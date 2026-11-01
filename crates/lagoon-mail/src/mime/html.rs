//! HTML → text, for messages whose only body is `text/html`.
//!
//! Ported from v3 `HTMLText.swift`: drop `<script>`/`<style>` blocks, strip
//! every remaining tag, decode named and numeric entities, collapse whitespace.
//! Deliberately not a DOM parser: the output is a preview/fallback, and the
//! original HTML is preserved separately for the reader.

/// Named entities v3 knows. Compared case-insensitively.
const NAMED_ENTITIES: [(&str, &str); 25] = [
    ("&nbsp;", " "),
    ("&amp;", "&"),
    ("&lt;", "<"),
    ("&gt;", ">"),
    ("&quot;", "\""),
    ("&apos;", "'"),
    ("&#39;", "'"),
    ("&mdash;", "\u{2014}"),
    ("&ndash;", "\u{2013}"),
    ("&hellip;", "\u{2026}"),
    ("&rsquo;", "\u{2019}"),
    ("&lsquo;", "\u{2018}"),
    ("&ldquo;", "\u{201C}"),
    ("&rdquo;", "\u{201D}"),
    ("&bull;", "\u{2022}"),
    ("&middot;", "\u{00B7}"),
    ("&copy;", "\u{00A9}"),
    ("&reg;", "\u{00AE}"),
    ("&trade;", "\u{2122}"),
    ("&euro;", "\u{20AC}"),
    ("&pound;", "\u{00A3}"),
    ("&yen;", "\u{00A5}"),
    ("&deg;", "\u{00B0}"),
    ("&#39;", "'"),
    ("&nbsp;", " "),
];

/// Remove scripts/styles/tags, decode entities, collapse whitespace.
pub fn strip(html: &str) -> String {
    let without_blocks = remove_blocks(html, "script");
    let without_blocks = remove_blocks(&without_blocks, "style");
    let text = remove_tags(&without_blocks);
    let decoded = decode_entities(&text);
    collapse_whitespace(&decoded)
}

/// Removes `<tag ...> ... </tag>` blocks case-insensitively. An unclosed block
/// is not removed (v3's regex did not match it either); the opening tag is then
/// handled by the generic tag stripper.
fn remove_blocks(html: &str, tag: &str) -> String {
    let bytes = html.as_bytes();
    let open_prefix = format!("<{tag}");
    let close_tag = format!("</{tag}");
    let mut output = String::with_capacity(html.len());
    let mut cursor = 0usize;
    while let Some(relative) = find_ascii_ci(bytes, open_prefix.as_bytes(), cursor) {
        let Some(open_end) = find_byte(bytes, b'>', relative) else {
            break;
        };
        let Some(close) = find_ascii_ci(bytes, close_tag.as_bytes(), open_end + 1) else {
            break;
        };
        let Some(close_end) = find_byte(bytes, b'>', close) else {
            break;
        };
        output.push_str(&html[cursor..relative]);
        output.push(' ');
        cursor = close_end + 1;
    }
    output.push_str(&html[cursor..]);
    output
}

/// Drops every `<...>` run, replacing it with a space so words on either side
/// stay separated. A `<` with no closing `>` keeps the remainder verbatim,
/// matching the `<[^>]+>` regex that left it alone.
fn remove_tags(html: &str) -> String {
    let bytes = html.as_bytes();
    let mut output = String::with_capacity(html.len());
    let mut cursor = 0usize;
    while cursor < bytes.len() {
        if bytes[cursor] == b'<' {
            if let Some(end) = find_byte(bytes, b'>', cursor) {
                output.push(' ');
                cursor = end + 1;
                continue;
            }
            output.push_str(&html[cursor..]);
            break;
        }
        let ch = html[cursor..].chars().next().unwrap();
        output.push(ch);
        cursor += ch.len_utf8();
    }
    output
}

/// Named entities plus numeric `&#123;` / `&#x1F600;` forms. Unknown entities
/// are left untouched. Two passes (named, then numeric) so `&amp;#60;` becomes
/// `<` exactly as v3's implementation did.
pub fn decode_entities(value: &str) -> String {
    let mut text = value.to_owned();
    for (entity, replacement) in NAMED_ENTITIES {
        text = replace_ascii_ci(&text, entity, replacement);
    }
    decode_numeric_entities(&text)
}

fn decode_numeric_entities(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = String::with_capacity(value.len());
    let mut cursor = 0usize;
    while cursor < bytes.len() {
        if bytes[cursor] != b'&' || bytes.get(cursor + 1) != Some(&b'#') {
            let ch = value[cursor..].chars().next().unwrap();
            output.push(ch);
            cursor += ch.len_utf8();
            continue;
        }
        let Some(semicolon) = find_byte(bytes, b';', cursor + 2) else {
            output.push('&');
            cursor += 1;
            continue;
        };
        let digits = &value[cursor + 2..semicolon];
        let parsed = if let Some(hex) = digits
            .strip_prefix('x')
            .or_else(|| digits.strip_prefix('X'))
        {
            u32::from_str_radix(hex, 16).ok()
        } else {
            digits.parse::<u32>().ok()
        };
        match parsed.and_then(char::from_u32) {
            Some(ch) => {
                output.push(ch);
                cursor = semicolon + 1;
            }
            None => {
                output.push('&');
                cursor += 1;
            }
        }
    }
    output
}

pub fn collapse_whitespace(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn replace_ascii_ci(haystack: &str, needle: &str, replacement: &str) -> String {
    let bytes = haystack.as_bytes();
    let needle_bytes = needle.as_bytes();
    let mut output = String::with_capacity(haystack.len());
    let mut cursor = 0usize;
    while let Some(relative) = find_ascii_ci(bytes, needle_bytes, cursor) {
        output.push_str(&haystack[cursor..relative]);
        output.push_str(replacement);
        cursor = relative + needle_bytes.len();
    }
    output.push_str(&haystack[cursor..]);
    output
}

fn find_byte(haystack: &[u8], needle: u8, from: usize) -> Option<usize> {
    haystack
        .get(from..)?
        .iter()
        .position(|&byte| byte == needle)
        .map(|offset| from + offset)
}

pub(crate) fn find_ascii_ci(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || from > haystack.len() || needle.len() > haystack.len() {
        return None;
    }
    let end = haystack.len() - needle.len();
    if from > end {
        return None;
    }
    for start in from..=end {
        if haystack[start..start + needle.len()]
            .iter()
            .zip(needle)
            .all(|(left, right)| left.eq_ignore_ascii_case(right))
        {
            return Some(start);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_tags_and_scripts() {
        let html = "<html><head><style>p { color: red }</style><script>alert('x')</script></head>\
                    <body><p>Hello <b>world</b></p><p>第二段</p></body></html>";
        assert_eq!(strip(html), "Hello world 第二段");
    }

    #[test]
    fn decodes_named_and_numeric_entities() {
        assert_eq!(
            strip("<p>a&nbsp;b &amp; c &lt;d&gt; &#20320;&#x597D; &mdash; &unknown;</p>"),
            "a b & c <d> 你好 — &unknown;"
        );
    }

    #[test]
    fn decodes_double_escaped_numeric_entity_like_v3() {
        assert_eq!(decode_entities("&amp;#60;"), "<");
    }

    #[test]
    fn unclosed_script_is_not_a_block() {
        let html = "<script>alert(1)<p>body</p>";
        let stripped = strip(html);
        assert!(stripped.contains("alert(1)"), "{stripped}");
        assert!(stripped.contains("body"), "{stripped}");
        assert!(!stripped.contains('<'), "{stripped}");
    }

    #[test]
    fn collapses_whitespace_and_trims() {
        assert_eq!(collapse_whitespace("  a\n\tb   c  "), "a b c");
    }

    #[test]
    fn preserves_non_ascii_through_tag_removal() {
        assert_eq!(strip("<div>收件箱 <span>x</span></div>"), "收件箱 x");
    }
}
