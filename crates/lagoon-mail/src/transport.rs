//! Injectable byte transport.
//!
//! One trait, two implementations:
//!
//! * [`TlsTransport`] — real network. Implicit TLS on 993/465, with the
//!   platform trust store and full verification (see [`crate::tls`]).
//! * A scripted fake in the test suite — no socket, no DNS, no TLS. Every unit
//!   and integration test in this crate uses it; the rule is enforced by the
//!   absence of any test that constructs [`TlsTransport`].
//!
//! The trait is deliberately small and **blocking**: `read_line` (IMAP/SMTP
//! lines are CRLF-framed), `read_exact` (IMAP literals), `write_all`, a
//! timeout setter for IDLE, and `close`. Framing belongs to the protocol
//! layers above, not to the transport, because a fake has to be able to script
//! a literal byte run that is not a line.

use std::io::{BufReader, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use rustls::pki_types::ServerName;
use rustls::{ClientConnection, StreamOwned};

use crate::error::TransportError;
use crate::tls;

/// v3 `IMAPConnection.defaultReadTimeout` / `SMTPClient.defaultReadTimeout`.
pub const DEFAULT_READ_TIMEOUT: Duration = Duration::from_secs(30);
/// v3 `IMAPConnection.connectTimeout`.
pub const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// A single response line is never legitimately 1 MiB. Bounded so a hostile
/// server cannot turn one line into unbounded allocation.
pub const MAX_LINE_BYTES: usize = 1024 * 1024;

/// A duplex byte stream. Implementations are single-session state machines:
/// `connect` may be called again after `close` to start a fresh session
/// (SMTP's one-shot retry depends on that).
pub trait Transport: Send {
    fn connect(&mut self, host: &str, port: u16) -> Result<(), TransportError>;
    fn write_all(&mut self, bytes: &[u8]) -> Result<(), TransportError>;
    /// Reads through `\n`, strips the trailing `\r` (when present) and
    /// returns the line as UTF-8 (lossy: IMAP carries mUTF-7 and raw 8-bit
    /// text in names; the protocol layer treats names as opaque strings).
    fn read_line(&mut self) -> Result<String, TransportError>;
    fn read_exact(&mut self, count: usize) -> Result<Vec<u8>, TransportError>;
    fn set_read_timeout(&mut self, timeout: Duration) -> Result<(), TransportError>;
    fn close(&mut self);
    fn is_connected(&self) -> bool;
}

/// Real transport: TCP + implicit TLS.
///
/// The handshake is performed lazily by rustls on the first read/write, which
/// is also when the server certificate is verified. A certificate failure
/// surfaces as [`TransportError::Io`] (the rustls error is wrapped in an IO
/// error by `StreamOwned`); the connection is not usable and every protocol
/// layer reports it as unreachable. The verification itself is proven at the
/// rustls level in `tests/tls_reject.rs`.
pub struct TlsTransport {
    stream: Option<BufReader<StreamOwned<ClientConnection, TcpStream>>>,
    read_timeout: Duration,
}

impl TlsTransport {
    pub fn new() -> Self {
        Self {
            stream: None,
            read_timeout: DEFAULT_READ_TIMEOUT,
        }
    }

    pub fn with_read_timeout(read_timeout: Duration) -> Self {
        Self {
            stream: None,
            read_timeout,
        }
    }
}

impl Default for TlsTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl Transport for TlsTransport {
    fn connect(&mut self, host: &str, port: u16) -> Result<(), TransportError> {
        let addrs = (host, port)
            .to_socket_addrs()
            .map_err(|error| TransportError::Io(error.kind()))?;
        let mut last_error = std::io::ErrorKind::AddrNotAvailable;
        let mut socket = None;
        for address in addrs {
            match TcpStream::connect_timeout(&address, DEFAULT_CONNECT_TIMEOUT) {
                Ok(stream) => {
                    socket = Some(stream);
                    break;
                }
                Err(error) => last_error = error.kind(),
            }
        }
        let socket = socket.ok_or(TransportError::Io(last_error))?;
        socket.set_nodelay(true).ok();
        socket
            .set_read_timeout(Some(self.read_timeout))
            .map_err(|error| TransportError::Io(error.kind()))?;
        socket
            .set_write_timeout(Some(self.read_timeout))
            .map_err(|error| TransportError::Io(error.kind()))?;

        let config = tls::client_config().map_err(TransportError::Tls)?;
        let server_name = ServerName::try_from(host.to_owned())
            .map_err(|_| TransportError::Malformed("tls-server-name"))?;
        let connection = ClientConnection::new(config, server_name)
            .map_err(|error| TransportError::Tls(tls::static_label(&error)))?;
        self.stream = Some(BufReader::new(StreamOwned::new(connection, socket)));
        Ok(())
    }

    fn write_all(&mut self, bytes: &[u8]) -> Result<(), TransportError> {
        let stream = self.stream.as_mut().ok_or(TransportError::NotConnected)?;
        stream.get_mut().write_all(bytes)?;
        stream.get_mut().flush()?;
        Ok(())
    }

    fn read_line(&mut self) -> Result<String, TransportError> {
        let stream = self.stream.as_mut().ok_or(TransportError::NotConnected)?;
        let mut line = Vec::new();
        loop {
            let mut byte = [0u8; 1];
            match stream.read(&mut byte) {
                Ok(0) => return Err(TransportError::Closed),
                Ok(_) => {
                    if byte[0] == b'\n' {
                        break;
                    }
                    line.push(byte[0]);
                    if line.len() > MAX_LINE_BYTES {
                        return Err(TransportError::Malformed("line-too-long"));
                    }
                }
                Err(error) => return Err(TransportError::from(error)),
            }
        }
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        Ok(String::from_utf8_lossy(&line).into_owned())
    }

    fn read_exact(&mut self, count: usize) -> Result<Vec<u8>, TransportError> {
        let stream = self.stream.as_mut().ok_or(TransportError::NotConnected)?;
        let mut buffer = vec![0u8; count];
        stream.read_exact(&mut buffer)?;
        Ok(buffer)
    }

    fn set_read_timeout(&mut self, timeout: Duration) -> Result<(), TransportError> {
        self.read_timeout = timeout;
        let stream = self.stream.as_ref().ok_or(TransportError::NotConnected)?;
        stream
            .get_ref()
            .sock
            .set_read_timeout(Some(timeout))
            .map_err(|error| TransportError::Io(error.kind()))
    }

    fn close(&mut self) {
        self.stream = None;
    }

    fn is_connected(&self) -> bool {
        self.stream.is_some()
    }
}
