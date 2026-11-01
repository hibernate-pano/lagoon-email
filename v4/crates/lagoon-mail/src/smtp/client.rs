//! One SMTP delivery.
//!
//! Ported from v3 `SMTPClient.swift`. The retry rule is encoded in [`Phase`]:
//! anything that fails *before* the DATA payload is on the wire may be retried
//! once (a second full session); once the payload has been sent the outcome is
//! terminal, because a retry could deliver the message twice.
//!
//! Two v3 incidents are structural here:
//!
//! * **QUIT can never fail a send.** RFC 5321 makes the server's 250 to the DATA
//!   terminator the point of no return. A server that hangs up instead of
//!   answering 221 does not unsend the mail; reporting it did made the user
//!   press send again and the recipient got two copies. `quit` is therefore
//!   best-effort and its errors are dropped.
//! * **The server's text never reaches an error.** A 5xx explanation can name
//!   the recipient's mailbox; only the numeric status (plus a static code) is
//!   carried by [`MailError`].

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;

use crate::error::{MailError, TransportError};
use crate::mime::builder::{build_new_message, build_reply, OutboundMessage};
use crate::transport::{Transport, DEFAULT_READ_TIMEOUT};

/// EHLO argument. QQ does not verify it, and a fixed name avoids leaking the
/// user's hostname to the server.
pub const CLIENT_NAME: &str = "lagoon.local";

/// Where the failure happened, which decides retryability.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Auth,
    PreData,
    PostData,
}

/// Internal wrapper: the [`MailError`] to surface plus whether a retry is still
/// safe. Never escapes [`SmtpClient::send_raw`].
#[derive(Debug)]
struct SmtpFailure {
    error: MailError,
    retryable: bool,
}

impl SmtpFailure {
    fn new(error: MailError, phase: Phase) -> Self {
        Self {
            error,
            retryable: phase != Phase::PostData,
        }
    }
}

pub struct SmtpClient {
    transport: Box<dyn Transport>,
    read_timeout: Duration,
}

impl SmtpClient {
    pub fn new(transport: Box<dyn Transport>) -> Self {
        Self {
            transport,
            read_timeout: DEFAULT_READ_TIMEOUT,
        }
    }

    pub fn with_read_timeout(transport: Box<dyn Transport>, read_timeout: Duration) -> Self {
        Self {
            transport,
            read_timeout,
        }
    }

    /// Sends one message and returns the locally generated `Message-ID`
    /// (`<hex@lagoon>`) so the caller can record it.
    pub fn send(
        &mut self,
        outbound: &OutboundMessage,
        host: &str,
        port: u16,
        username: &str,
        auth_code: &str,
    ) -> Result<String, MailError> {
        let message_id = generate_message_id();
        let message = if outbound.is_reply {
            build_reply(outbound, &message_id)
        } else {
            build_new_message(outbound, &message_id)
        };
        self.send_raw(&message, outbound, host, port, username, auth_code)?;
        Ok(message_id)
    }

    /// Sends already-built RFC 5322 bytes. IMAP uses this so the exact same
    /// message can be appended to the server's Sent mailbox.
    pub fn send_raw(
        &mut self,
        message: &[u8],
        outbound: &OutboundMessage,
        host: &str,
        port: u16,
        username: &str,
        auth_code: &str,
    ) -> Result<(), MailError> {
        let mut attempt = 0u32;
        loop {
            attempt += 1;
            match self.run_session(outbound, message, host, port, username, auth_code) {
                Ok(()) => {
                    self.transport.close();
                    return Ok(());
                }
                Err(failure) => {
                    // A failed session is never resumed: close first, reconnect
                    // in the next attempt.
                    self.transport.close();
                    if failure.retryable && attempt == 1 {
                        continue;
                    }
                    return Err(failure.error);
                }
            }
        }
    }

    fn run_session(
        &mut self,
        outbound: &OutboundMessage,
        message: &[u8],
        host: &str,
        port: u16,
        username: &str,
        auth_code: &str,
    ) -> Result<(), SmtpFailure> {
        if !is_valid_envelope_address(&outbound.from_email) {
            return Err(SmtpFailure::new(
                MailError::protocol("smtp-invalid-address"),
                Phase::PreData,
            ));
        }
        self.transport
            .connect(host, port)
            .map_err(|error| transport_failure(error, Phase::PreData))?;
        self.expect(220, Phase::PreData)?; // greeting
        self.command(&format!("EHLO {CLIENT_NAME}"), 250, Phase::PreData)?;

        let credentials =
            base64::engine::general_purpose::STANDARD.encode(format!("\0{username}\0{auth_code}"));
        self.command(&format!("AUTH PLAIN {credentials}"), 235, Phase::Auth)?;

        self.command(
            &format!("MAIL FROM:<{}>", outbound.from_email),
            250,
            Phase::PreData,
        )?;
        self.accept_recipients(&outbound.envelope_recipients())?;
        self.command("DATA", 354, Phase::PreData)?;

        self.transport
            .write_all(&dot_stuffed_for_data(message))
            .map_err(|error| transport_failure(error, Phase::PostData))?;
        self.expect(250, Phase::PostData)?;
        // The 250 above is the delivery verdict: the server has taken the
        // message into its queue. Everything after it is housekeeping and must
        // not be able to fail the send.
        self.quit();
        Ok(())
    }

    /// Ends the session politely — and never fails the send.
    fn quit(&mut self) {
        let _ = self.transport.write_all(b"QUIT\r\n");
        let _ = self.read_reply(Phase::PostData);
    }

    fn command(&mut self, line: &str, expected: u16, phase: Phase) -> Result<(), SmtpFailure> {
        let mut bytes = Vec::with_capacity(line.len() + 2);
        bytes.extend_from_slice(line.as_bytes());
        bytes.extend_from_slice(b"\r\n");
        self.transport
            .write_all(&bytes)
            .map_err(|error| transport_failure(error, phase))?;
        self.expect(expected, phase)
    }

    /// RFC 5321: `RCPT TO` carries exactly one forward-path, so a reply-all is
    /// one command per envelope recipient. A 5xx rejects that one mailbox and
    /// the message still goes to everyone the server accepted — that is what the
    /// sender asked for, and aborting would deliver nothing. A 4xx is a verdict
    /// on the session, not on the address, so it aborts and lets the normal
    /// retry rule run. Delivering to nobody is a failure.
    fn accept_recipients(&mut self, addresses: &[String]) -> Result<(), SmtpFailure> {
        if addresses.is_empty() {
            return Err(SmtpFailure {
                error: MailError::protocol("smtp-no-recipient"),
                retryable: false,
            });
        }
        let mut accepted = 0u32;
        let mut last_rejection: Option<u16> = None;
        for address in addresses {
            if !is_valid_envelope_address(address) {
                return Err(SmtpFailure {
                    error: MailError::protocol("smtp-invalid-address"),
                    retryable: false,
                });
            }
            let line = format!("RCPT TO:<{address}>");
            let mut bytes = line.into_bytes();
            bytes.extend_from_slice(b"\r\n");
            self.transport
                .write_all(&bytes)
                .map_err(|error| transport_failure(error, Phase::PreData))?;
            let code = self.read_reply(Phase::PreData)?;
            if code == 250 {
                accepted += 1;
                continue;
            }
            if (400..=499).contains(&code) {
                return Err(failure_for_code(code, Phase::PreData));
            }
            last_rejection = Some(code);
        }
        if accepted == 0 {
            return Err(failure_for_code(
                last_rejection.unwrap_or(550),
                Phase::PreData,
            ));
        }
        Ok(())
    }

    fn expect(&mut self, expected: u16, phase: Phase) -> Result<(), SmtpFailure> {
        let code = self.read_reply(phase)?;
        if code != expected {
            return Err(failure_for_code(code, phase));
        }
        Ok(())
    }

    /// Reads one (possibly multi-line) reply and returns its status code.
    fn read_reply(&mut self, phase: Phase) -> Result<u16, SmtpFailure> {
        loop {
            self.transport
                .set_read_timeout(self.read_timeout)
                .map_err(|error| transport_failure(error, phase))?;
            let line = self
                .transport
                .read_line()
                .map_err(|error| transport_failure(error, phase))?;
            let bytes = line.as_bytes();
            if bytes.len() < 3 || !bytes[..3].iter().all(u8::is_ascii_digit) {
                return Err(SmtpFailure::new(
                    MailError::protocol("smtp-short-line"),
                    phase,
                ));
            }
            let code: u16 = line[..3].parse().unwrap_or(0);
            // `250-...` continues the reply; `250 ...` or a bare `250` ends it.
            if bytes.len() > 3 && bytes[3] == b'-' {
                continue;
            }
            return Ok(code);
        }
    }
}

fn transport_failure(error: TransportError, phase: Phase) -> SmtpFailure {
    SmtpFailure::new(error.to_mail("smtp"), phase)
}

fn failure_for_code(code: u16, phase: Phase) -> SmtpFailure {
    match phase {
        Phase::Auth => {
            if (400..=499).contains(&code) {
                SmtpFailure {
                    error: MailError::unreachable_status("smtp-status", code),
                    retryable: true,
                }
            } else {
                // A rejected AUTH is a credential verdict: stop retrying and ask
                // the user for a fresh authorization code.
                SmtpFailure {
                    error: MailError::auth_failed(),
                    retryable: false,
                }
            }
        }
        Phase::PostData => SmtpFailure {
            error: MailError::protocol_status("smtp-status", code),
            retryable: false,
        },
        Phase::PreData => {
            if (400..=499).contains(&code) {
                SmtpFailure {
                    error: MailError::unreachable_status("smtp-status", code),
                    retryable: true,
                }
            } else {
                SmtpFailure {
                    error: MailError::protocol_status("smtp-status", code),
                    retryable: false,
                }
            }
        }
    }
}

/// Applies RFC 5321 §4.5.2 dot-stuffing and terminates the payload with
/// `<CRLF>.<CRLF>`. A base64 body never starts a line with `.`, so the stuffing
/// is a guard for bodies built by other callers, not a no-op assumption baked
/// into the wire path.
pub fn dot_stuffed_for_data(payload: &[u8]) -> Vec<u8> {
    let mut text = String::from_utf8_lossy(payload).into_owned();
    if !text.ends_with("\r\n") {
        text.push_str("\r\n");
    }
    let stuffed = text
        .split("\r\n")
        .map(|line| {
            if line.starts_with('.') {
                format!(".{line}")
            } else {
                line.to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join("\r\n");
    format!("{stuffed}.\r\n").into_bytes()
}

fn is_valid_envelope_address(address: &str) -> bool {
    !address.is_empty()
        && address.contains('@')
        && !address
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace() || ch == '<' || ch == '>')
}

static MESSAGE_ID_COUNTER: AtomicU64 = AtomicU64::new(1);

fn generate_message_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    let counter = MESSAGE_ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("<{nanos:016x}{counter:08x}@lagoon>")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dot_stuffing_guards_leading_dots() {
        let stuffed = dot_stuffed_for_data(b"a\r\n.b\r\n..c");
        assert_eq!(stuffed, b"a\r\n..b\r\n...c\r\n.\r\n");
    }

    #[test]
    fn dot_stuffing_terminates_payload_without_trailing_crlf() {
        assert_eq!(dot_stuffed_for_data(b"x"), b"x\r\n.\r\n");
        assert_eq!(dot_stuffed_for_data(b"x\r\n"), b"x\r\n.\r\n");
    }

    #[test]
    fn envelope_address_validation_rejects_injection() {
        assert!(is_valid_envelope_address("a@b.example"));
        assert!(!is_valid_envelope_address("a@b.example\r\nBcc: x"));
        assert!(!is_valid_envelope_address(""));
        assert!(!is_valid_envelope_address("not-an-address"));
        assert!(!is_valid_envelope_address("<a@b.example>"));
    }

    #[test]
    fn message_ids_are_unique_and_lagoon_scoped() {
        let first = generate_message_id();
        let second = generate_message_id();
        assert_ne!(first, second);
        assert!(first.starts_with('<'));
        assert!(first.ends_with("@lagoon>"));
    }
}
