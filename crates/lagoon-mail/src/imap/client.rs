//! Semantic IMAP command layer.
//!
//! Ported from v3 `IMAPClient.swift`: names the commands and parses their
//! responses so no caller touches wire text. The provider above it never sees
//! an atom list; the sync engine above that only sees
//! [`crate::sync::MailSyncReading`].
//!
//! Deliberate omissions, each an invariant rather than a gap:
//!
//! * **No plain `EXPUNGE`.** RFC 3501's EXPUNGE is folder-wide: it removes
//!   every `\\Deleted` message, including ones another client flagged. v3
//!   carried an `expunge()` and used it as a fallback; R3 must never degrade
//!   to it, so the command does not exist in this API at all.
//! * **No `LOGIN` as the first choice.** `AUTHENTICATE PLAIN` with SASL-IR is
//!   tried first; `LOGIN` is the fallback, and both only ever travel inside
//!   TLS.
//! * **No writes to fetched mail.** Header sync uses `BODY.PEEK`, never
//!   `BODY`, so syncing never sets `\\Seen`.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use base64::Engine as _;

use crate::error::MailError;
use crate::imap::connection::ImapConnection;
use crate::imap::parser::{self, ImapResponse};
use crate::mime::headers::parse_header_block;
use crate::timefmt::parse_imap_internal_date;
use crate::transport::Transport;

/// One mailbox as `LIST` reports it. Names are opaque server strings (possibly
/// mUTF-7): they are echoed back verbatim, never translated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImapMailbox {
    pub name: String,
    pub attributes: Vec<String>,
}

/// The state `SELECT` pins down. When `uid_validity` changes, every stored UID
/// in this mailbox is meaningless and the caller must reset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImapSelected {
    pub mailbox: String,
    pub exists: usize,
    pub uid_validity: i64,
    pub uid_next: i64,
}

/// One FETCHed header block. `raw_headers` keys are lowercased and
/// continuation lines are unfolded; values stay RFC 2047-encoded — decoding
/// belongs to the provider, which decides what to do with broken input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImapFetchedHeader {
    pub uid: i64,
    pub flags: Vec<String>,
    /// `INTERNALDATE` as epoch seconds (v3 carried a `Date`).
    pub internal_date: Option<i64>,
    pub raw_headers: BTreeMap<String, String>,
}

/// One mailbox's flags-only row (`UID FETCH ... (UID FLAGS)`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImapFlagRow {
    pub uid: i64,
    pub flags: Vec<String>,
}

pub const DEFAULT_HEADER_FIELDS: [&str; 8] = [
    "FROM",
    "SUBJECT",
    "DATE",
    "MESSAGE-ID",
    "IN-REPLY-TO",
    "REFERENCES",
    "LIST-UNSUBSCRIBE",
    // RFC 8058's companion header. Fetched so the one-click fact can be
    // recorded; nothing acts on it (see mime::unsubscribe for why).
    "LIST-UNSUBSCRIBE-POST",
];

/// v3 `IMAPClient.uidsPerCommand`: the session is strictly serial, so a bulk
/// read must not ask for one message at a time.
const UIDS_PER_COMMAND: usize = 100;

/// v3 `IMAPClient.snippetOctets`.
pub const SNIPPET_OCTETS: usize = 32_768;

pub struct ImapClient {
    connection: ImapConnection,
    /// Populated by the first `capability()`; cleared on login because the
    /// authenticated set is a superset of the anonymous one on most servers.
    cached_capabilities: Option<BTreeSet<String>>,
}

impl ImapClient {
    pub fn new(transport: Box<dyn Transport>) -> Self {
        Self {
            connection: ImapConnection::new(transport),
            cached_capabilities: None,
        }
    }

    pub fn connection(&mut self) -> &mut ImapConnection {
        &mut self.connection
    }

    pub fn connect(&mut self, host: &str, port: u16) -> Result<(), MailError> {
        self.connection.connect(host, port)
    }

    pub fn is_connected(&self) -> bool {
        self.connection.is_connected()
    }

    /// Capability names, uppercased (they are case-insensitive per RFC 3501).
    ///
    /// A tagged OK with no untagged `* CAPABILITY` line is **not** an answer:
    /// the result is cached only when a line was seen, so the next call retries
    /// instead of latching "no MOVE" from a truncated reply.
    pub fn capability(&mut self) -> Result<BTreeSet<String>, MailError> {
        if let Some(cached) = &self.cached_capabilities {
            return Ok(cached.clone());
        }
        let responses = self.connection.execute("CAPABILITY")?;
        let mut capabilities = BTreeSet::new();
        let mut saw_line = false;
        for response in &responses {
            if !response.is_untagged() {
                continue;
            }
            if response.atom_at(1).as_deref() != Some("CAPABILITY") {
                continue;
            }
            saw_line = true;
            for atom in response.atoms.iter().skip(2) {
                capabilities.insert(atom.to_ascii_uppercase());
            }
        }
        if saw_line {
            self.cached_capabilities = Some(capabilities.clone());
        }
        Ok(capabilities)
    }

    /// `AUTHENTICATE PLAIN` + SASL-IR, falling back to `LOGIN`.
    ///
    /// An explicit credential rejection (`AUTHENTICATIONFAILED`, or a bare NO
    /// to LOGIN) is final: retrying it would spend a second failed attempt on
    /// exactly the rate-limited accounts that must not be hammered.
    pub fn login(&mut self, username: &str, auth_code: &str) -> Result<(), MailError> {
        let quoted_user = Self::quoted(username)?;
        let quoted_secret = Self::quoted(auth_code)?;
        let payload =
            base64::engine::general_purpose::STANDARD.encode(format!("\0{username}\0{auth_code}"));

        match self
            .connection
            .execute(&format!("AUTHENTICATE PLAIN {payload}"))
        {
            Ok(_) => {}
            Err(error) if error.is_auth_failed() => return Err(error),
            Err(_) => {
                match self
                    .connection
                    .execute(&format!("LOGIN {quoted_user} {quoted_secret}"))
                {
                    Ok(_) => {}
                    Err(error) if error.code() == "tagged-NO" => {
                        return Err(MailError::auth_failed());
                    }
                    Err(error) => return Err(error),
                }
            }
        }
        // Credentials are never logged; only the failure category above.
        self.cached_capabilities = None;
        Ok(())
    }

    /// RFC 2971 client identity; a no-op when the server has no `ID`.
    pub fn send_id(&mut self) -> Result<(), MailError> {
        if !self.capability()?.contains("ID") {
            return Ok(());
        }
        self.connection
            .execute("ID (\"name\" \"Lagoon\" \"version\" \"1.0\")")?;
        Ok(())
    }

    pub fn list_mailboxes(&mut self) -> Result<Vec<ImapMailbox>, MailError> {
        let responses = self.connection.execute("LIST \"\" \"*\"")?;
        let mut mailboxes = Vec::new();
        for response in &responses {
            if !response.is_untagged() {
                continue;
            }
            if response.atom_at(1).as_deref() != Some("LIST") {
                continue;
            }
            let Some(name) = response.atoms.last() else {
                continue;
            };
            if name.is_empty() {
                continue;
            }
            let attributes = parser::parenthesized(&response.raw)
                .unwrap_or_default()
                .into_iter()
                .flat_map(|group| {
                    group
                        .split_whitespace()
                        .map(str::to_owned)
                        .collect::<Vec<_>>()
                })
                .collect();
            mailboxes.push(ImapMailbox {
                name: name.clone(),
                attributes,
            });
        }
        Ok(mailboxes)
    }

    pub fn select(&mut self, mailbox: &str) -> Result<ImapSelected, MailError> {
        let quoted = Self::quoted(mailbox)?;
        let responses = self.connection.execute(&format!("SELECT {quoted}"))?;
        let mut selected = ImapSelected {
            mailbox: mailbox.to_owned(),
            exists: 0,
            uid_validity: 0,
            uid_next: 0,
        };
        for response in &responses {
            if !response.is_untagged() {
                continue;
            }
            if response.atoms.len() >= 3 && response.atom_at(2).as_deref() == Some("EXISTS") {
                if let Ok(exists) = response.atoms[1].parse::<usize>() {
                    selected.exists = exists;
                }
            }
            if let Some(value) = number_after("UIDVALIDITY", &response.raw) {
                selected.uid_validity = value;
            }
            if let Some(value) = number_after("UIDNEXT", &response.raw) {
                selected.uid_next = value;
            }
        }
        Ok(selected)
    }

    /// Headers for every message from `from_uid` to the mailbox end. The fetch
    /// is `BODY.PEEK` on purpose: syncing must never mark mail as read.
    pub fn fetch_headers_from_uid(
        &mut self,
        from_uid: i64,
        fields: &[&str],
    ) -> Result<Vec<ImapFetchedHeader>, MailError> {
        let field_list = fields.join(" ");
        let command = format!(
            "UID FETCH {from_uid}:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS ({field_list})])"
        );
        self.fetch_headers_command(&command)
    }

    /// Headers for the newest `count` messages, addressed by *sequence number*.
    /// Sequence numbers are dense while UIDs are not, so a bounded history
    /// window measured in messages must use this form.
    pub fn fetch_newest_headers(
        &mut self,
        count: usize,
        exists: usize,
        fields: &[&str],
    ) -> Result<Vec<ImapFetchedHeader>, MailError> {
        if exists == 0 || count == 0 {
            return Ok(Vec::new());
        }
        let first = (exists as i64 - count as i64 + 1).max(1);
        let field_list = fields.join(" ");
        let command = format!(
            "FETCH {first}:* (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS ({field_list})])"
        );
        self.fetch_headers_command(&command)
    }

    /// The same header block for one known UID.
    pub fn fetch_header(
        &mut self,
        uid: i64,
        fields: &[&str],
    ) -> Result<Vec<ImapFetchedHeader>, MailError> {
        let field_list = fields.join(" ");
        let command = format!(
            "UID FETCH {uid} (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS ({field_list})])"
        );
        self.fetch_headers_command(&command)
    }

    /// The same header block for a known set of UIDs, chunked so one command
    /// answers for up to [`UIDS_PER_COMMAND`] messages.
    pub fn fetch_headers_for_uids(
        &mut self,
        uids: &[i64],
        fields: &[&str],
    ) -> Result<Vec<ImapFetchedHeader>, MailError> {
        let field_list = fields.join(" ");
        let mut headers = Vec::new();
        for chunk in uids.chunks(UIDS_PER_COMMAND) {
            let set = chunk
                .iter()
                .map(i64::to_string)
                .collect::<Vec<_>>()
                .join(",");
            let command = format!(
                "UID FETCH {set} (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS ({field_list})])"
            );
            headers.extend(self.fetch_headers_command(&command)?);
        }
        Ok(headers)
    }

    fn fetch_headers_command(
        &mut self,
        command: &str,
    ) -> Result<Vec<ImapFetchedHeader>, MailError> {
        let responses = self.connection.execute(command)?;
        Ok(parse_headers(&responses))
    }

    /// Flag rescan over a bounded UID window — how the read/unread state of
    /// already-known mail is refreshed.
    pub fn fetch_flags(
        &mut self,
        from_uid: i64,
        to_uid: i64,
    ) -> Result<Vec<ImapFlagRow>, MailError> {
        let responses = self
            .connection
            .execute(&format!("UID FETCH {from_uid}:{to_uid} (UID FLAGS)"))?;
        let mut rows = Vec::new();
        for response in &responses {
            if !response.is_untagged() {
                continue;
            }
            let Some(items) = parser::parenthesized(&response.raw) else {
                continue;
            };
            let Some(uid) = number_value_after("UID", &items) else {
                continue;
            };
            rows.push(ImapFlagRow {
                uid,
                flags: flag_list(&items),
            });
        }
        Ok(rows)
    }

    /// Finds one message by its RFC 5322 `Message-ID`.
    ///
    /// QQ accepts `HEADER SEARCH` but can answer empty even when the header is
    /// present (v3 `resolveUID` comment), so callers must keep a fallback scan;
    /// this method reports only what the server said.
    pub fn search_uid_by_message_id(&mut self, message_id: &str) -> Result<Option<i64>, MailError> {
        let quoted = Self::quoted(message_id)?;
        let responses = self
            .connection
            .execute(&format!("UID SEARCH HEADER Message-ID {quoted}"))?;
        for response in &responses {
            if !response.is_untagged() {
                continue;
            }
            if response.atoms.len() >= 3
                && response.atoms[0] == "*"
                && response.atom_at(1).as_deref() == Some("SEARCH")
            {
                return Ok(response
                    .atoms
                    .iter()
                    .skip(2)
                    .filter_map(|atom| atom.parse::<i64>().ok())
                    .max());
            }
        }
        Ok(None)
    }

    /// Every UID currently present in the selected mailbox. Used to reconcile
    /// messages another client moved or deleted out of INBOX.
    pub fn all_uids(&mut self) -> Result<BTreeSet<i64>, MailError> {
        let responses = self.connection.execute("UID SEARCH ALL")?;
        for response in &responses {
            if !response.is_untagged() {
                continue;
            }
            if response.atoms.len() >= 2
                && response.atoms[0] == "*"
                && response.atom_at(1).as_deref() == Some("SEARCH")
            {
                return Ok(response
                    .atoms
                    .iter()
                    .skip(2)
                    .filter_map(|atom| atom.parse::<i64>().ok())
                    .collect());
            }
        }
        Ok(BTreeSet::new())
    }

    /// Text-prefix bytes for the given UIDs, keyed by UID: the first `octets`
    /// bytes of each message — headers included so the MIME decoder can tell
    /// what the body is — still transfer-encoded.
    ///
    /// A refused chunk costs its own previews, not the ones already collected:
    /// the cursor is about to move past these messages, so dropping the whole
    /// window would blank every preview in it for good. A transport failure is
    /// deliberately not caught here — it must tear the session down.
    pub fn fetch_text_snippets(
        &mut self,
        uids: &[i64],
        octets: usize,
    ) -> Result<HashMap<i64, Vec<u8>>, MailError> {
        let mut snippets = HashMap::new();
        for chunk in uids.chunks(UIDS_PER_COMMAND) {
            let set = chunk
                .iter()
                .map(i64::to_string)
                .collect::<Vec<_>>()
                .join(",");
            let command = format!("UID FETCH {set} (UID BODY.PEEK[]<0.{octets}>)");
            match self.connection.execute(&command) {
                Ok(responses) => {
                    for response in &responses {
                        if !response.is_untagged() {
                            continue;
                        }
                        let (Some(literal), Some(items)) = (
                            response.literal.as_ref(),
                            parser::parenthesized(&response.raw),
                        ) else {
                            continue;
                        };
                        let Some(uid) = number_value_after("UID", &items) else {
                            continue;
                        };
                        snippets.insert(uid, literal.clone());
                    }
                }
                Err(error) if error.is_message_verdict() => continue,
                Err(error) => return Err(error),
            }
        }
        Ok(snippets)
    }

    /// Full RFC 822 bytes. An empty result means the UID is gone from the
    /// server (expunged): the caller maps it to "message gone".
    pub fn fetch_full_body(&mut self, uid: i64) -> Result<Vec<u8>, MailError> {
        let responses = self
            .connection
            .execute(&format!("UID FETCH {uid} (BODY.PEEK[])"))?;
        responses
            .iter()
            .filter_map(|response| response.literal.as_ref())
            .find(|literal| !literal.is_empty())
            .cloned()
            .ok_or_else(MailError::message_gone)
    }

    /// One MIME part's bytes by IMAP part path (`1.2`), for attachment
    /// downloads. The path is validated to digits and dots before it is put in
    /// the command: attachment ids come from our own parser, but a value that
    /// can close the bracket can also inject a command.
    pub fn fetch_part(&mut self, uid: i64, part: &str) -> Result<Vec<u8>, MailError> {
        if part.is_empty()
            || !part
                .bytes()
                .all(|byte| byte.is_ascii_digit() || byte == b'.')
        {
            return Err(MailError::protocol("bad-part-path"));
        }
        let responses = self
            .connection
            .execute(&format!("UID FETCH {uid} (BODY.PEEK[{part}])"))?;
        responses
            .iter()
            .find_map(|response| response.literal.clone())
            .ok_or_else(MailError::message_gone)
    }

    pub fn store(&mut self, uid: i64, add: &[&str], remove: &[&str]) -> Result<(), MailError> {
        if !add.is_empty() {
            self.connection
                .execute(&format!("UID STORE {uid} +FLAGS ({})", add.join(" ")))?;
        }
        if !remove.is_empty() {
            self.connection
                .execute(&format!("UID STORE {uid} -FLAGS ({})", remove.join(" ")))?;
        }
        Ok(())
    }

    /// `UID MOVE`, which requires the server-advertised MOVE capability. The
    /// provider falls back to COPY + UID STORE + UID EXPUNGE (never a plain
    /// EXPUNGE) when this is missing.
    pub fn move_to(&mut self, uid: i64, mailbox: &str) -> Result<(), MailError> {
        if !self.capability()?.contains("MOVE") {
            return Err(MailError::missing_capability("move-missing"));
        }
        let quoted = Self::quoted(mailbox)?;
        self.connection
            .execute(&format!("UID MOVE {uid} {quoted}"))?;
        Ok(())
    }

    pub fn copy(&mut self, uid: i64, mailbox: &str) -> Result<(), MailError> {
        let quoted = Self::quoted(mailbox)?;
        self.connection
            .execute(&format!("UID COPY {uid} {quoted}"))?;
        Ok(())
    }

    /// RFC 4315 UID EXPUNGE: removes exactly this message, which must already
    /// carry `\\Deleted`.
    ///
    /// This is the **only** expunge this crate knows how to issue. See the
    /// module docs for why plain `EXPUNGE` is absent.
    pub fn uid_expunge(&mut self, uid: i64) -> Result<(), MailError> {
        self.connection.execute(&format!("UID EXPUNGE {uid}"))?;
        Ok(())
    }

    /// Removes a set of messages in one round trip (RFC 4315 sequence form).
    pub fn uid_expunge_many(&mut self, uids: &[i64]) -> Result<(), MailError> {
        if uids.is_empty() {
            return Ok(());
        }
        let list = uids
            .iter()
            .map(i64::to_string)
            .collect::<Vec<_>>()
            .join(",");
        self.connection.execute(&format!("UID EXPUNGE {list}"))?;
        Ok(())
    }

    pub fn create_mailbox(&mut self, name: &str) -> Result<(), MailError> {
        let quoted = Self::quoted(name)?;
        self.connection.execute(&format!("CREATE {quoted}"))?;
        Ok(())
    }

    pub fn append(&mut self, mailbox: &str, message: &[u8]) -> Result<(), MailError> {
        let quoted = Self::quoted(mailbox)?;
        self.connection.append(&quoted, message)
    }

    pub fn idle(
        &mut self,
        wait_up_to: std::time::Duration,
    ) -> Result<Vec<ImapResponse>, MailError> {
        self.connection.idle(wait_up_to)
    }

    /// LOGOUT then close. A server that hangs up mid-LOGOUT has still ended the
    /// session, so the error is not surfaced.
    pub fn logout(&mut self) {
        let _ = self.connection.execute("LOGOUT");
        self.cached_capabilities = None;
        self.connection.close();
    }

    /// Close without the LOGOUT courtesy round trip. Used when the session is
    /// already presumed dead: otherwise the client would block for the full
    /// read timeout waiting for a reply that is never coming.
    pub fn disconnect(&mut self) {
        self.cached_capabilities = None;
        self.connection.close();
    }

    /// RFC 3501 quoted-string. Control characters are refused rather than
    /// escaped: a value that can end the line can also inject a command.
    pub fn quoted(value: &str) -> Result<String, MailError> {
        if value
            .chars()
            .any(|ch| (ch as u32) < 0x20 || ch as u32 == 0x7F)
        {
            return Err(MailError::protocol("control-char-in-argument"));
        }
        let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
        Ok(format!("\"{escaped}\""))
    }
}

fn parse_headers(responses: &[ImapResponse]) -> Vec<ImapFetchedHeader> {
    let mut headers = Vec::new();
    for response in responses {
        if !response.is_untagged() {
            continue;
        }
        let (Some(literal), Some(items)) = (
            response.literal.as_ref(),
            parser::parenthesized(&response.raw),
        ) else {
            continue;
        };
        let Some(uid) = number_value_after("UID", &items) else {
            continue;
        };
        headers.push(ImapFetchedHeader {
            uid,
            flags: flag_list(&items),
            internal_date: internal_date(&items),
            raw_headers: parse_header_block(literal),
        });
    }
    headers
}

/// First integer following `keyword` in a raw line, e.g. `UIDNEXT` in
/// `* OK [UIDNEXT 100] Predicted next UID`.
pub(crate) fn number_after(keyword: &str, raw: &str) -> Option<i64> {
    let upper = raw.to_ascii_uppercase();
    let key = keyword.to_ascii_uppercase();
    let index = upper.find(&key)?;
    let rest = raw[index + keyword.len()..].trim_start_matches(' ');
    let digits: String = rest.chars().take_while(|ch| ch.is_ascii_digit()).collect();
    if digits.is_empty() {
        None
    } else {
        digits.parse().ok()
    }
}

/// Integer in the atom following `keyword` within one FETCH item list.
pub(crate) fn number_value_after(keyword: &str, atoms: &[String]) -> Option<i64> {
    let index = atoms
        .iter()
        .position(|atom| atom.eq_ignore_ascii_case(keyword))?;
    atoms.get(index + 1)?.parse().ok()
}

pub(crate) fn flag_list(items: &[String]) -> Vec<String> {
    let Some(index) = items
        .iter()
        .position(|atom| atom.eq_ignore_ascii_case("FLAGS"))
    else {
        return Vec::new();
    };
    let Some(atom) = items.get(index + 1) else {
        return Vec::new();
    };
    atom.trim_start_matches('(')
        .trim_end_matches(')')
        .split_whitespace()
        .map(str::to_owned)
        .collect()
}

fn internal_date(items: &[String]) -> Option<i64> {
    let index = items
        .iter()
        .position(|atom| atom.eq_ignore_ascii_case("INTERNALDATE"))?;
    parse_imap_internal_date(items.get(index + 1)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoted_refuses_control_characters() {
        assert_eq!(
            ImapClient::quoted("INBOX\r\nA1 DELETE INBOX"),
            Err(MailError::protocol("control-char-in-argument"))
        );
        assert_eq!(ImapClient::quoted("INBOX").unwrap(), "\"INBOX\"");
        assert_eq!(
            ImapClient::quoted(r#"Sent "Box"\x"#).unwrap(),
            r#""Sent \"Box\"\\x""#
        );
    }

    #[test]
    fn number_after_reads_response_codes() {
        assert_eq!(
            number_after("UIDVALIDITY", "* OK [UIDVALIDITY 42] ready"),
            Some(42)
        );
        assert_eq!(number_after("UIDNEXT", "* OK [UIDNEXT 100] x"), Some(100));
        assert_eq!(number_after("UIDNEXT", "* 3 EXISTS"), None);
    }

    #[test]
    fn number_value_after_reads_fetch_items() {
        let atoms = vec![
            "UID".to_string(),
            "42".to_string(),
            "FLAGS".to_string(),
            "(\\Seen)".to_string(),
        ];
        assert_eq!(number_value_after("uid", &atoms), Some(42));
        assert_eq!(number_value_after("INTERNALDATE", &atoms), None);
    }

    #[test]
    fn flag_list_handles_nested_group_atom() {
        let atoms = vec![
            "UID".to_string(),
            "42".to_string(),
            "FLAGS".to_string(),
            "(\\Seen \\Deleted)".to_string(),
        ];
        assert_eq!(flag_list(&atoms), ["\\Seen", "\\Deleted"]);
        assert!(flag_list(&["UID".to_string()]).is_empty());
    }
}
