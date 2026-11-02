//! Scripted transport for every protocol test in this crate.
//!
//! Ported from v3 `ScriptedTransport.swift`: the whole wire conversation is
//! queued up front, so tests assert exact command bytes and exact framing with
//! no socket, DNS, TLS or runtime.
//!
//! * `new()` (default): reads past the end of the script fail as `Closed`,
//!   mimicking a server that hung up.
//! * `blocking()`: an empty script reads as `TimedOut` instead of hanging —
//!   the blocking stand-in for "nothing arrived yet" (the v3 actor slept until
//!   more was enqueued; sleeping forever in a test suite is not useful).
//! * `DeferredLine` is delivered only once the client has written `min_writes`
//!   commands: that expresses "the server answers after DONE" without sleeps.
//! * `connect` may be called again after `close` on the same script, which is
//!   what SMTP's one-shot retry needs.

#![allow(dead_code)]

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use lagoon_mail::error::TransportError;
use lagoon_mail::transport::Transport;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureKind {
    Closed,
    Io,
    Malformed,
}

#[derive(Debug, Clone)]
pub enum Event {
    Line(String),
    Literal(Vec<u8>),
    DeferredLine(String, usize),
    Timeout,
    FailNextRead(FailureKind),
}

#[derive(Debug, Default)]
struct Core {
    script: VecDeque<Event>,
    close_after_script: bool,
    writes: Vec<Vec<u8>>,
    connects: Vec<(String, u16)>,
    close_count: usize,
    is_closed: bool,
    read_timeout: Duration,
}

/// A handle onto one shared script. Clones share the script, the writes and the
/// connection state — so a provider's transport factory can hand the same
/// conversation to a reconnect, exactly like v3's single actor.
#[derive(Clone, Debug)]
pub struct ScriptedTransport {
    core: Arc<Mutex<Core>>,
}

impl ScriptedTransport {
    pub fn new() -> Self {
        Self::with_close_after_script(true)
    }

    pub fn blocking() -> Self {
        Self::with_close_after_script(false)
    }

    fn with_close_after_script(close_after_script: bool) -> Self {
        Self {
            core: Arc::new(Mutex::new(Core {
                script: VecDeque::new(),
                close_after_script,
                writes: Vec::new(),
                connects: Vec::new(),
                close_count: 0,
                is_closed: false,
                read_timeout: Duration::from_secs(30),
            })),
        }
    }

    pub fn handle(&self) -> Self {
        self.clone()
    }

    pub fn enqueue_line(&self, line: impl Into<String>) {
        self.core
            .lock()
            .expect("script lock")
            .script
            .push_back(Event::Line(line.into()));
    }

    pub fn enqueue_lines(&self, lines: &[&str]) {
        for line in lines {
            self.enqueue_line(*line);
        }
    }

    pub fn enqueue_literal(&self, bytes: impl Into<Vec<u8>>) {
        self.core
            .lock()
            .expect("script lock")
            .script
            .push_back(Event::Literal(bytes.into()));
    }

    pub fn enqueue_deferred_line(&self, line: impl Into<String>, min_writes: usize) {
        self.core
            .lock()
            .expect("script lock")
            .script
            .push_back(Event::DeferredLine(line.into(), min_writes));
    }

    pub fn enqueue_timeout(&self) {
        self.core
            .lock()
            .expect("script lock")
            .script
            .push_back(Event::Timeout);
    }

    /// Make the next read fail once, before consuming the script.
    pub fn fail_next_read(&self, kind: FailureKind) {
        self.core
            .lock()
            .expect("script lock")
            .script
            .push_front(Event::FailNextRead(kind));
    }

    pub fn writes(&self) -> Vec<Vec<u8>> {
        self.core.lock().expect("script lock").writes.clone()
    }

    pub fn writes_text(&self) -> String {
        self.writes()
            .iter()
            .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
            .collect::<Vec<_>>()
            .join("")
    }

    pub fn command_lines(&self) -> Vec<String> {
        self.writes_text()
            .split("\r\n")
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect()
    }

    pub fn connect_count(&self) -> usize {
        self.core.lock().expect("script lock").connects.len()
    }

    pub fn connects(&self) -> Vec<(String, u16)> {
        self.core.lock().expect("script lock").connects.clone()
    }

    pub fn close_count(&self) -> usize {
        self.core.lock().expect("script lock").close_count
    }

    pub fn remaining_events(&self) -> usize {
        self.core.lock().expect("script lock").script.len()
    }
}

impl Default for ScriptedTransport {
    fn default() -> Self {
        Self::new()
    }
}

fn failure(kind: FailureKind) -> TransportError {
    match kind {
        FailureKind::Closed => TransportError::Closed,
        FailureKind::Io => TransportError::Io(std::io::ErrorKind::Other),
        FailureKind::Malformed => TransportError::Malformed("scripted"),
    }
}

impl Transport for ScriptedTransport {
    fn connect(&mut self, host: &str, port: u16) -> Result<(), TransportError> {
        let mut core = self.core.lock().expect("script lock");
        core.connects.push((host.to_owned(), port));
        // A fresh connect is a fresh session: a client that reconnects after
        // close() must be able to write again, and the script continues.
        core.is_closed = false;
        Ok(())
    }

    fn write_all(&mut self, bytes: &[u8]) -> Result<(), TransportError> {
        let mut core = self.core.lock().expect("script lock");
        if core.is_closed {
            return Err(TransportError::Closed);
        }
        core.writes.push(bytes.to_vec());
        Ok(())
    }

    fn read_line(&mut self) -> Result<String, TransportError> {
        let started = Instant::now();
        loop {
            let mut core = self.core.lock().expect("script lock");
            if core.is_closed {
                return Err(TransportError::Closed);
            }
            match core.script.front().cloned() {
                None => {
                    return if core.close_after_script {
                        Err(TransportError::Closed)
                    } else {
                        Err(TransportError::TimedOut)
                    };
                }
                Some(Event::Line(line)) => {
                    core.script.pop_front();
                    return Ok(line);
                }
                Some(Event::DeferredLine(line, min_writes)) => {
                    if core.writes.len() >= min_writes {
                        core.script.pop_front();
                        return Ok(line);
                    }
                }
                Some(Event::Timeout) => {
                    core.script.pop_front();
                    return Err(TransportError::TimedOut);
                }
                Some(Event::FailNextRead(kind)) => {
                    core.script.pop_front();
                    return Err(failure(kind));
                }
                Some(Event::Literal(_)) => {
                    return Err(TransportError::Malformed("line-expected"));
                }
            }
            drop(core);
            if started.elapsed() > Duration::from_secs(2) {
                return Err(TransportError::TimedOut);
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    fn read_exact(&mut self, count: usize) -> Result<Vec<u8>, TransportError> {
        let started = Instant::now();
        loop {
            let mut core = self.core.lock().expect("script lock");
            if core.is_closed {
                return Err(TransportError::Closed);
            }
            match core.script.front().cloned() {
                None => {
                    return if core.close_after_script {
                        Err(TransportError::Closed)
                    } else {
                        Err(TransportError::TimedOut)
                    };
                }
                Some(Event::Literal(bytes)) => {
                    core.script.pop_front();
                    if bytes.len() != count {
                        return Err(TransportError::Malformed("literal-length"));
                    }
                    return Ok(bytes);
                }
                Some(Event::DeferredLine(_, min_writes)) => {
                    if core.writes.len() >= min_writes {
                        return Err(TransportError::Malformed("literal-expected"));
                    }
                }
                Some(Event::Timeout) => {
                    core.script.pop_front();
                    return Err(TransportError::TimedOut);
                }
                Some(Event::FailNextRead(kind)) => {
                    core.script.pop_front();
                    return Err(failure(kind));
                }
                Some(Event::Line(_)) => {
                    return Err(TransportError::Malformed("literal-expected"));
                }
            }
            drop(core);
            if started.elapsed() > Duration::from_secs(2) {
                return Err(TransportError::TimedOut);
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    fn set_read_timeout(&mut self, timeout: Duration) -> Result<(), TransportError> {
        self.core.lock().expect("script lock").read_timeout = timeout;
        Ok(())
    }

    fn close(&mut self) {
        let mut core = self.core.lock().expect("script lock");
        core.is_closed = true;
        core.close_count += 1;
    }

    fn is_connected(&self) -> bool {
        !self.core.lock().expect("script lock").is_closed
    }
}

/// The baseline IMAP session script every provider test starts with:
/// greeting, AUTHENTICATE OK, and the authenticated CAPABILITY (which also
/// serves `send_id`'s capability check).
pub fn imap_session_script(transport: &ScriptedTransport, capabilities: &str) {
    transport.enqueue_line("* OK [CAPABILITY IMAP4rev1] ready");
    transport.enqueue_line("A0001 OK AUTHENTICATE completed");
    transport.enqueue_line(format!("* CAPABILITY {capabilities}"));
    transport.enqueue_line("A0002 OK CAPABILITY completed");
}

/// SELECT reply for a mailbox with the given EXISTS / UIDVALIDITY / UIDNEXT.
pub fn select_script(
    transport: &ScriptedTransport,
    tag: &str,
    exists: usize,
    uid_validity: i64,
    uid_next: i64,
) {
    transport.enqueue_line(format!("* {exists} EXISTS"));
    transport.enqueue_line(format!("* OK [UIDVALIDITY {uid_validity}] UIDs valid"));
    transport.enqueue_line(format!("* OK [UIDNEXT {uid_next}] predicted next UID"));
    transport.enqueue_line("* OK [PERMANENTFLAGS (\\Seen \\Deleted \\Flagged)] flags");
    transport.enqueue_line(format!("{tag} OK [READ-WRITE] SELECT completed"));
}
