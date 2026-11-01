//! Pure text → structure parsing for the IMAP wire format (RFC 3501).
//!
//! Ported from v3 `IMAPResponseParser.swift` together with its test suite. No
//! I/O and no state: every byte here is server-controlled input, and the
//! contract is that no input may panic.
//!
//! Two properties are load-bearing for every layer above:
//! * a quoted string is unquoted and unescaped before it becomes an atom, so a
//!   mailbox named `Sent "Box"` round-trips;
//! * `parenthesized` keeps nested groups and bracketed sections as **one**
//!   atom, which is what makes `FLAGS (\Seen)` and
//!   `BODY[HEADER.FIELDS (SUBJECT)]` survive a single pass.

/// One parsed IMAP response line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImapResponse {
    pub kind: ResponseKind,
    /// Tokenized form: runs of space/tab split atoms, quoted strings are
    /// unquoted and unescaped, everything else passes through untouched.
    pub atoms: Vec<String>,
    /// Bytes the framing layer read after a `{N}` declaration.
    pub literal: Option<Vec<u8>>,
    /// The logical line, including any tail merged after a literal.
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResponseKind {
    Tagged { tag: String, status: ImapStatus },
    Untagged,
    Continuation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImapStatus {
    Ok,
    No,
    Bad,
}

impl ImapStatus {
    fn parse(atom: &str) -> Option<Self> {
        match atom.to_ascii_uppercase().as_str() {
            "OK" => Some(Self::Ok),
            "NO" => Some(Self::No),
            "BAD" => Some(Self::Bad),
            _ => None,
        }
    }
}

impl ImapResponse {
    /// The status of an untagged response code, e.g. `[READ-ONLY]` — used by
    /// diagnostics only.
    pub fn is_untagged(&self) -> bool {
        matches!(self.kind, ResponseKind::Untagged)
    }

    /// Case-insensitive atom match, for callers that read response keywords.
    pub fn atom_at(&self, index: usize) -> Option<String> {
        self.atoms.get(index).map(|atom| atom.to_ascii_uppercase())
    }
}

/// Parses one line (CRLF already stripped) plus an optional literal whose bytes
/// the caller read after a `{N}` declaration. Returns `None` for a blank line.
pub fn parse(line: &str, literal: Option<Vec<u8>>) -> Option<ImapResponse> {
    if line.trim().is_empty() {
        return None;
    }
    let atoms = tokenize(line);
    let first = atoms.first()?;
    let kind = if first == "*" {
        ResponseKind::Untagged
    } else if first == "+" {
        ResponseKind::Continuation
    } else {
        // The status is the token after the tag; scanning the rest is strictly
        // more forgiving and cannot misfire on untagged lines.
        let status = atoms
            .iter()
            .skip(1)
            .find_map(|atom| ImapStatus::parse(atom))
            .unwrap_or(ImapStatus::Bad);
        ResponseKind::Tagged {
            tag: first.clone(),
            status,
        }
    };
    Some(ImapResponse {
        kind,
        atoms,
        literal,
        raw: line.to_owned(),
    })
}

/// Length declared by a trailing `{N}` / `{N+}` marker, or `None` when the
/// line does not end in one.
pub fn literal_length(line: &str) -> Option<usize> {
    if !line.ends_with('}') {
        return None;
    }
    let open = line.rfind('{')?;
    let mut digits = &line[open + 1..line.len() - 1];
    if let Some(stripped) = digits.strip_suffix('+') {
        digits = stripped;
    }
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// Splits the contents of the first `( ... )` group into atoms. Nested groups
/// stay one atom (parens included) so `FLAGS (\Seen)` and
/// `BODY[HEADER.FIELDS (SUBJECT)]` both survive a single pass — a bracketed
/// section is itself an atom, so nothing inside `[ ]` splits.
///
/// `None` when the line has no group; an unterminated group returns what was
/// parsed rather than nothing.
pub fn parenthesized(line: &str) -> Option<Vec<String>> {
    let open = line.find('(')?;
    let mut atoms: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut has_current = false;
    let mut depth: i32 = 1;
    let mut bracket_depth: i32 = 0;
    let mut in_quote = false;
    let mut pending_escape = false;

    for ch in line[open + 1..].chars() {
        if in_quote {
            if pending_escape {
                current.push(ch);
                pending_escape = false;
            } else if ch == '\\' {
                pending_escape = true;
            } else if ch == '"' {
                in_quote = false;
            } else {
                current.push(ch);
            }
            continue;
        }

        match ch {
            '"' => {
                in_quote = true;
                has_current = true;
            }
            '[' => {
                bracket_depth += 1;
                current.push(ch);
                has_current = true;
            }
            ']' => {
                if bracket_depth > 0 {
                    bracket_depth -= 1;
                }
                current.push(ch);
                has_current = true;
            }
            '(' if bracket_depth == 0 => {
                depth += 1;
                current.push(ch);
                has_current = true;
            }
            ')' if bracket_depth == 0 => {
                depth -= 1;
                if depth == 0 {
                    if has_current {
                        atoms.push(current);
                    }
                    return Some(atoms);
                }
                current.push(ch);
            }
            ' ' | '\t' => {
                if bracket_depth > 0 {
                    current.push(ch);
                    has_current = true;
                } else if depth == 1 {
                    if has_current {
                        atoms.push(std::mem::take(&mut current));
                        has_current = false;
                    }
                } else {
                    current.push(ch);
                }
            }
            _ => {
                current.push(ch);
                has_current = true;
            }
        }
    }

    // Unterminated group: hand back what was parsed rather than nothing.
    if has_current {
        atoms.push(current);
    }
    Some(atoms)
}

fn tokenize(line: &str) -> Vec<String> {
    let mut atoms: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut has_current = false;
    let mut in_quote = false;
    let mut pending_escape = false;

    for ch in line.chars() {
        if in_quote {
            if pending_escape {
                current.push(ch);
                pending_escape = false;
            } else if ch == '\\' {
                pending_escape = true;
            } else if ch == '"' {
                in_quote = false;
            } else {
                current.push(ch);
            }
            continue;
        }
        match ch {
            '"' => {
                in_quote = true;
                has_current = true;
            }
            ' ' | '\t' => {
                if has_current {
                    atoms.push(std::mem::take(&mut current));
                    has_current = false;
                }
            }
            _ => {
                current.push(ch);
                has_current = true;
            }
        }
    }
    if pending_escape {
        current.push('\\');
    }
    if has_current {
        atoms.push(current);
    }
    atoms
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- Line kinds -----------------------------------------------------

    #[test]
    fn tagged_ok_captures_tag_and_status() {
        let response = parse("A0004 OK FETCH completed", None).unwrap();
        assert_eq!(
            response.kind,
            ResponseKind::Tagged {
                tag: "A0004".into(),
                status: ImapStatus::Ok
            }
        );
        assert_eq!(response.atoms, ["A0004", "OK", "FETCH", "completed"]);
        assert_eq!(response.raw, "A0004 OK FETCH completed");
    }

    #[test]
    fn tagged_no_captures_tag_and_status() {
        let response = parse("A1 NO [AUTHENTICATIONFAILED] Authentication failed", None).unwrap();
        assert_eq!(
            response.kind,
            ResponseKind::Tagged {
                tag: "A1".into(),
                status: ImapStatus::No
            }
        );
    }

    #[test]
    fn tagged_bad_is_case_insensitive() {
        let response = parse("a2 bad command error", None).unwrap();
        assert_eq!(
            response.kind,
            ResponseKind::Tagged {
                tag: "a2".into(),
                status: ImapStatus::Bad
            }
        );
    }

    #[test]
    fn untagged_exists() {
        let response = parse("* 12 EXISTS", None).unwrap();
        assert_eq!(response.kind, ResponseKind::Untagged);
        assert_eq!(response.atoms, ["*", "12", "EXISTS"]);
    }

    #[test]
    fn continuation() {
        let response = parse("+ Ready for literal data", None).unwrap();
        assert_eq!(response.kind, ResponseKind::Continuation);
    }

    #[test]
    fn empty_and_whitespace_only_return_none() {
        assert!(parse("", None).is_none());
        assert!(parse("   ", None).is_none());
        assert!(parse("\t", None).is_none());
    }

    // ---- Literals -------------------------------------------------------

    #[test]
    fn literal_is_attached_verbatim() {
        let body = "hello 世界".as_bytes().to_vec();
        let response = parse("* 1 FETCH (BODY[TEXT] {12}", Some(body.clone())).unwrap();
        assert_eq!(response.literal, Some(body));
        assert_eq!(response.kind, ResponseKind::Untagged);
    }

    #[test]
    fn literal_length_synchronizing_form() {
        assert_eq!(literal_length("* 1 FETCH (BODY[TEXT] {256}"), Some(256));
    }

    #[test]
    fn literal_length_accepts_non_synchronizing_form() {
        assert_eq!(literal_length("* 1 FETCH (BODY[TEXT] {256+}"), Some(256));
        assert_eq!(literal_length("A2 NO"), None);
    }

    #[test]
    fn literal_length_zero_and_non_numeric() {
        assert_eq!(literal_length("A1 OK {0}"), Some(0));
        assert_eq!(literal_length("A1 OK {abc}"), None);
        assert_eq!(literal_length("A1 OK {12} trailing"), None);
        assert_eq!(literal_length("A1 OK {}"), None);
    }

    // ---- Atoms ----------------------------------------------------------

    #[test]
    fn quoted_string_unescapes_backslash_and_quote() {
        let response = parse(r#"* LIST (\HasNoChildren) "/" "Sent \"Box\""#, None).unwrap();
        assert_eq!(
            response.atoms,
            ["*", "LIST", r#"(\HasNoChildren)"#, "/", r#"Sent "Box""#]
        );
    }

    #[test]
    fn backslash_escape_keeps_following_char() {
        let response = parse(r#"A1 OK "back\\slash""#, None).unwrap();
        assert_eq!(response.atoms.last().unwrap(), r"back\slash");
    }

    #[test]
    fn unterminated_quote_consumes_rest_of_line() {
        let response = parse(r#"A1 OK "never closed"#, None).unwrap();
        assert_eq!(response.atoms.last().unwrap(), "never closed");
    }

    #[test]
    fn non_ascii_passes_through_untouched() {
        let line = r#"* LIST () "/" "收件箱""#;
        let response = parse(line, None).unwrap();
        assert_eq!(response.atoms.last().unwrap(), "收件箱");
        assert_eq!(response.raw, line);
    }

    // ---- Parenthesized lists -------------------------------------------

    #[test]
    fn parenthesized_flags_list() {
        assert_eq!(
            parenthesized(r"* FLAGS (Answered Flagged)").unwrap(),
            [r"Answered", r"Flagged"]
        );
    }

    #[test]
    fn parenthesized_no_parens_is_none() {
        assert_eq!(parenthesized(r"* OK \HasNoChildren"), None);
        assert_eq!(parenthesized("A1 OK done"), None);
    }

    #[test]
    fn parenthesized_nested_group_stays_one_atom() {
        assert_eq!(
            parenthesized(r"* 1 FETCH (UID 42 FLAGS (\Seen))").unwrap(),
            ["UID", "42", "FLAGS", r"(\Seen)"]
        );
    }

    #[test]
    fn parenthesized_quoted_and_nested_section() {
        assert_eq!(
            parenthesized(r#"* 1 FETCH (BODY[HEADER.FIELDS (SUBJECT)] "收件箱")"#).unwrap(),
            ["BODY[HEADER.FIELDS (SUBJECT)]", "收件箱"]
        );
    }

    #[test]
    fn parenthesized_empty_group() {
        assert_eq!(parenthesized("* LIST ()").unwrap(), Vec::<String>::new());
    }

    #[test]
    fn parenthesized_unterminated_group_returns_partial() {
        assert_eq!(
            parenthesized(r"* 1 FETCH (UID 42 FLAGS (\Seen)").unwrap(),
            ["UID", "42", "FLAGS", r"(\Seen)"]
        );
    }

    #[test]
    fn parser_never_panics_on_fuzzish_input() {
        let samples = [
            "{",
            "}",
            "{{{}}}",
            "\"",
            r#""\""#,
            "* FETCH (BODY[] {999999999999999999999999})",
            "\u{0}",
            "+",
        ];
        for sample in samples {
            let _ = parse(sample, None);
            let _ = literal_length(sample);
            let _ = parenthesized(sample);
        }
    }
}
