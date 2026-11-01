//! One IMAP session: tag allocation, literal framing, timeouts and IDLE.
//!
//! Ported from v3 `IMAPConnection.swift`. The wire rules that matter:
//!
//! * the server speaks first (RFC 3501 §7.1.1), so anything but an untagged OK
//!   greeting is a protocol error;
//! * a response is a **logical** line: a trailing `{N}` declares N literal
//!   bytes that are read exactly and then merged back with the tail that
//!   follows them, so a FETCH body split by the server still parses as one
//!   response;
//! * literals are capped. The cap is 40 MB, not 32 MB: a 25 MB attachment
//!   arrives base64-encoded (~33.3 MB) plus headers, and the old 32 MB ceiling
//!   rejected mail the product had already promised to accept
//!   (`IMAPConnection.maxLiteralBytes` and its comment);
//! * a tagged NO/BAD consumes the whole response set, so the session is still
//!   aligned afterwards. A transport failure is not a verdict and tears the
//!   session down at the provider level.
//!
//! IDLE uses the read timeout as its budget: one blocking read with the
//! remaining budget, then `DONE`. A timeout is the normal exit, not an error.

use std::time::{Duration, Instant};

use crate::error::{MailError, TransportError};
use crate::imap::parser::{self, ImapResponse, ImapStatus, ResponseKind};
use crate::transport::Transport;

/// Ceiling on the bytes a single response may declare across its literals.
pub const MAX_LITERAL_BYTES: usize = 40 * 1024 * 1024;

/// Internal read failure: a transport problem to be mapped, or a size verdict
/// that is already a stable code.
enum ReadFailure {
    Transport(TransportError),
    /// A size verdict, not a broken server: the routes map this onto a
    /// "too large" response (the v3 `oversizeLiteralLabel` distinction).
    TooLarge,
}

impl ReadFailure {
    fn into_mail(self) -> MailError {
        match self {
            Self::Transport(error) => error.to_mail("imap"),
            Self::TooLarge => MailError::too_large("literal-too-large"),
        }
    }
}

/// A strictly serial IMAP session. QQ caps concurrent sessions per account,
/// so there is exactly one connection and no pipelining (v3 spec §3.1).
pub struct ImapConnection {
    transport: Box<dyn Transport>,
    connected: bool,
    command_counter: u32,
    read_timeout: Duration,
    connect_timeout: Duration,
}

impl ImapConnection {
    pub fn new(transport: Box<dyn Transport>) -> Self {
        Self {
            transport,
            connected: false,
            command_counter: 0,
            read_timeout: crate::transport::DEFAULT_READ_TIMEOUT,
            connect_timeout: crate::transport::DEFAULT_CONNECT_TIMEOUT,
        }
    }

    pub fn with_timeouts(
        transport: Box<dyn Transport>,
        read_timeout: Duration,
        connect_timeout: Duration,
    ) -> Self {
        Self {
            transport,
            connected: false,
            command_counter: 0,
            read_timeout,
            connect_timeout,
        }
    }

    pub fn is_connected(&self) -> bool {
        self.connected
    }

    /// Connects and consumes the greeting. The server must speak first, so
    /// anything but an untagged OK is a protocol error.
    pub fn connect(&mut self, host: &str, port: u16) -> Result<(), MailError> {
        if let Err(error) = self.transport.connect(host, port) {
            self.transport.close();
            return Err(error.to_mail("imap"));
        }
        let greeting = match self.read_response(self.connect_timeout) {
            Ok(Some(response)) => response,
            Ok(None) => {
                self.transport.close();
                return Err(MailError::protocol("empty-greeting"));
            }
            Err(failure) => {
                self.transport.close();
                return Err(failure.into_mail());
            }
        };
        let is_ok_greeting = matches!(greeting.kind, ResponseKind::Untagged)
            && greeting.raw.to_ascii_uppercase().starts_with("* OK");
        if !is_ok_greeting {
            self.transport.close();
            return Err(MailError::protocol("unexpected-greeting"));
        }
        if let Err(error) = self.transport.set_read_timeout(self.read_timeout) {
            self.transport.close();
            return Err(error.to_mail("imap"));
        }
        self.connected = true;
        Ok(())
    }

    /// Sends one command under a freshly minted tag and collects every response
    /// up to (and including) the tagged completion. `.no`/`.bad` completions
    /// surface as [`MailError`]; a rejected login is typed
    /// [`MailErrorKind::AuthFailed`](crate::error::MailErrorKind::AuthFailed)
    /// so the sync loop can stop retrying.
    pub fn execute(&mut self, command: &str) -> Result<Vec<ImapResponse>, MailError> {
        if !self.connected {
            return Err(MailError::unreachable("imap-not-connected"));
        }
        let tag = self.next_tag();
        self.write_line(&format!("{tag} {command}"))?;

        let mut responses: Vec<ImapResponse> = Vec::new();
        loop {
            let response = match self.read_response(self.read_timeout) {
                Ok(Some(response)) => response,
                Ok(None) => continue,
                Err(failure) => return Err(failure.into_mail()),
            };
            match &response.kind {
                ResponseKind::Tagged {
                    tag: received,
                    status,
                } if received == &tag => {
                    return match status {
                        ImapStatus::Ok => {
                            responses.push(response);
                            Ok(responses)
                        }
                        _ => Err(status_error(*status, &response.raw)),
                    };
                }
                ResponseKind::Tagged { .. } => {
                    // A tag we never minted: keep it for diagnostics, do not
                    // treat it as this command's completion.
                    responses.push(response);
                }
                ResponseKind::Continuation => {
                    // No command at this layer sends a payload after a
                    // continuation; answer with a bare CRLF so the server does
                    // not stall waiting for one (RFC 3501 §7.5).
                    self.transport
                        .write_all(b"\r\n")
                        .map_err(|error| error.to_mail("imap"))?;
                }
                ResponseKind::Untagged => responses.push(response),
            }
        }
    }

    /// APPEND one literal message to a mailbox. The command uses a
    /// synchronizing literal: wait for `+`, write the exact bytes, then send
    /// the CRLF that terminates the client command.
    pub fn append(&mut self, quoted_mailbox: &str, message: &[u8]) -> Result<(), MailError> {
        if !self.connected {
            return Err(MailError::unreachable("imap-not-connected"));
        }
        let tag = self.next_tag();
        self.write_line(&format!(
            "{tag} APPEND {quoted_mailbox} (\\Seen) {{{}}}",
            message.len()
        ))?;

        loop {
            let response = match self.read_response(self.read_timeout) {
                Ok(Some(response)) => response,
                Ok(None) => continue,
                Err(failure) => return Err(failure.into_mail()),
            };
            match &response.kind {
                ResponseKind::Continuation => {
                    self.transport
                        .write_all(message)
                        .map_err(|error| error.to_mail("imap"))?;
                    self.transport
                        .write_all(b"\r\n")
                        .map_err(|error| error.to_mail("imap"))?;
                    return self.await_tagged_completion(&tag);
                }
                ResponseKind::Tagged { status, .. } => {
                    return Err(status_error(*status, &response.raw));
                }
                ResponseKind::Untagged => continue,
            }
        }
    }

    /// Enters IDLE, waits up to `wait_up_to` for a mailbox event, then sends
    /// DONE and drains the tagged completion. Returns as soon as one
    /// EXISTS / EXPUNGE / FETCH arrives, so new mail is not delayed by the rest
    /// of the budget; keep-alive noise (`* OK still here`) is not an event.
    pub fn idle(&mut self, wait_up_to: Duration) -> Result<Vec<ImapResponse>, MailError> {
        if !self.connected {
            return Err(MailError::unreachable("imap-not-connected"));
        }
        let tag = self.next_tag();
        self.write_line(&format!("{tag} IDLE"))?;

        // The server acknowledges with `+ idling`; untagged chatter may
        // precede it.
        loop {
            let ack = match self.read_response(self.read_timeout) {
                Ok(Some(response)) => response,
                Ok(None) => continue,
                Err(failure) => return Err(failure.into_mail()),
            };
            match ack.kind {
                ResponseKind::Continuation => break,
                ResponseKind::Tagged { .. } => {
                    return Err(MailError::protocol("idle-refused"));
                }
                ResponseKind::Untagged => continue,
            }
        }

        let mut events: Vec<ImapResponse> = Vec::new();
        let deadline = Instant::now() + wait_up_to;
        loop {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            let remaining = deadline - now;
            match self.read_response(remaining) {
                Ok(Some(response)) => match &response.kind {
                    ResponseKind::Untagged if is_sync_event(&response) => {
                        events.push(response);
                        break;
                    }
                    ResponseKind::Tagged { .. } => {
                        return Err(MailError::protocol("idle-terminated-early"));
                    }
                    _ => continue,
                },
                Ok(None) => continue,
                Err(ReadFailure::Transport(error)) if error.is_timed_out() => break,
                Err(failure) => return Err(failure.into_mail()),
            }
        }

        self.transport
            .set_read_timeout(self.read_timeout)
            .map_err(|error| error.to_mail("imap"))?;
        self.write_line("DONE")?;
        self.drain_until_tagged(&tag)?;
        Ok(events)
    }

    /// Closes the socket without a LOGOUT round trip. Used when the session is
    /// already presumed dead.
    pub fn close(&mut self) {
        self.connected = false;
        self.transport.close();
    }

    // ---- Framing --------------------------------------------------------

    /// Reads one logical response. When the line declares a `{N}` literal the
    /// bytes are read exactly and the tail that follows them (usually `)`) is
    /// merged back in, so a split FETCH response comes out whole.
    fn read_response(&mut self, timeout: Duration) -> Result<Option<ImapResponse>, ReadFailure> {
        self.transport
            .set_read_timeout(timeout)
            .map_err(ReadFailure::Transport)?;
        let mut line = self.transport.read_line().map_err(ReadFailure::Transport)?;
        let mut literal: Option<Vec<u8>> = None;
        let mut literal_bytes: usize = 0;

        while let Some(length) = parser::literal_length(&line) {
            // The length is whatever the server printed. The subtraction form
            // matters: accumulating first would overflow before the guard and
            // trap, which is exactly what the cap exists to prevent.
            if length > MAX_LITERAL_BYTES.saturating_sub(literal_bytes) {
                return Err(ReadFailure::TooLarge);
            }
            literal_bytes += length;
            let chunk = self
                .transport
                .read_exact(length)
                .map_err(ReadFailure::Transport)?;
            match literal.as_mut() {
                Some(existing) => existing.extend_from_slice(&chunk),
                None => literal = Some(chunk),
            }
            let tail = self.transport.read_line().map_err(ReadFailure::Transport)?;
            line.push_str(&tail);
        }

        Ok(parser::parse(&line, literal))
    }

    fn drain_until_tagged(&mut self, tag: &str) -> Result<(), MailError> {
        loop {
            let response = match self.read_response(self.read_timeout) {
                Ok(Some(response)) => response,
                Ok(None) => continue,
                Err(failure) => return Err(failure.into_mail()),
            };
            if let ResponseKind::Tagged {
                tag: received,
                status,
            } = &response.kind
            {
                if received == tag {
                    return match status {
                        ImapStatus::Ok => Ok(()),
                        _ => Err(MailError::protocol("idle-done-refused")),
                    };
                }
            }
        }
    }

    fn await_tagged_completion(&mut self, tag: &str) -> Result<(), MailError> {
        loop {
            let response = match self.read_response(self.read_timeout) {
                Ok(Some(response)) => response,
                Ok(None) => continue,
                Err(failure) => return Err(failure.into_mail()),
            };
            if let ResponseKind::Tagged {
                tag: received,
                status,
            } = &response.kind
            {
                if received == tag {
                    return match status {
                        ImapStatus::Ok => Ok(()),
                        _ => Err(status_error(*status, &response.raw)),
                    };
                }
            }
        }
    }

    fn write_line(&mut self, line: &str) -> Result<(), MailError> {
        let mut bytes = Vec::with_capacity(line.len() + 2);
        bytes.extend_from_slice(line.as_bytes());
        bytes.extend_from_slice(b"\r\n");
        self.transport
            .write_all(&bytes)
            .map_err(|error| error.to_mail("imap"))
    }

    fn next_tag(&mut self) -> String {
        self.command_counter += 1;
        format!("A{:04}", self.command_counter)
    }
}

fn status_error(status: ImapStatus, raw: &str) -> MailError {
    match status {
        ImapStatus::Ok => MailError::protocol("unexpected-tagged-ok"),
        ImapStatus::No => {
            if raw.to_ascii_uppercase().contains("AUTHENTICATIONFAILED") {
                MailError::auth_failed()
            } else {
                MailError::protocol("tagged-NO")
            }
        }
        ImapStatus::Bad => MailError::protocol("tagged-BAD"),
    }
}

/// Whether an untagged response is a mailbox event IDLE should stop for.
fn is_sync_event(response: &ImapResponse) -> bool {
    match response.atom_at(2) {
        Some(keyword) => matches!(keyword.as_str(), "EXISTS" | "EXPUNGE" | "FETCH"),
        None => false,
    }
}
