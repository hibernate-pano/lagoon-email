//! A small HTTP/1.1 client, spoken over the mail crate's TLS transport.
//!
//! Why not a full HTTP client: the only HTTP dependency in this project
//! (`reqwest`, in the shell) is built **without TLS** on purpose - the shell
//! only ever talks to `127.0.0.1`. The AI provider is on the public internet,
//! so it needs TLS, and the only verified TLS stack in the tree is
//! lagoon-mail's (rustls + the platform trust store, proven by
//! `crates/lagoon-mail/tests/tls_reject.rs`). So the request leaves over that
//! transport, and this module speaks the little HTTP/1.1 that a chat
//! completion needs.
//!
//! What it supports: one request per connection, `Content-Length` and chunked
//! responses, `Connection: close`. What it does not support: keep-alive,
//! redirects, compression, HTTP/2. A chat completion is a single POST that
//! comes back with JSON; anything more would be a client nobody maintains.

use lagoon_mail::error::TransportError;
use lagoon_mail::transport::Transport;

/// One request. The caller sets every header it needs.
#[derive(Debug, Clone)]
pub struct HttpRequest {
    pub host: String,
    pub port: u16,
    /// The path with its query string, e.g. `/v1/chat/completions`.
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// The response: a status and the body bytes.
#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// Why a request did not produce a response.
#[derive(Debug, Clone, PartialEq)]
pub enum HttpError {
    /// The connection failed: DNS, TCP, TLS, timeout.
    Unreachable(String),
    /// The peer answered with something that is not HTTP/1.1 we can read.
    Malformed(String),
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HttpError::Unreachable(reason) => write!(formatter, "http unreachable: {reason}"),
            HttpError::Malformed(reason) => write!(formatter, "http malformed: {reason}"),
        }
    }
}

impl std::error::Error for HttpError {}

/// The largest response body we accept. A chat completion is kilobytes; a
/// megabyte is already generous, and the bound keeps a hostile or broken
/// server from making the process allocate without limit.
const MAX_BODY_BYTES: usize = 8 * 1024 * 1024;

/// Send one request and read the response.
pub fn send(
    transport: &mut dyn Transport,
    request: &HttpRequest,
) -> Result<HttpResponse, HttpError> {
    transport
        .connect(&request.host, request.port)
        .map_err(map_transport)?;
    let outcome = exchange(transport, request);
    // The connection is ours to close, whatever happened on it.
    transport.close();
    outcome
}

pub(crate) fn exchange(
    transport: &mut dyn Transport,
    request: &HttpRequest,
) -> Result<HttpResponse, HttpError> {
    let mut head = String::new();
    head.push_str(&format!("POST {} HTTP/1.1\r\n", request.path));
    head.push_str(&format!("Host: {}\r\n", request.host));
    for (name, value) in &request.headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str(&format!("Content-Length: {}\r\n", request.body.len()));
    // One request per connection: the provider is a stranger, and a reused
    // socket is a socket we have to trust across two conversations.
    head.push_str("Connection: close\r\n\r\n");

    transport
        .write_all(head.as_bytes())
        .map_err(map_transport)?;
    if !request.body.is_empty() {
        transport.write_all(&request.body).map_err(map_transport)?;
    }

    let status = parse_status(&read_line(transport)?)?;
    let headers = read_headers(transport)?;
    let body = read_body(transport, &headers)?;
    Ok(HttpResponse { status, body })
}

fn map_transport(error: TransportError) -> HttpError {
    HttpError::Unreachable(format!("{error:?}"))
}

fn read_line(transport: &mut dyn Transport) -> Result<String, HttpError> {
    transport.read_line().map_err(map_transport)
}

/// `HTTP/1.1 200 OK` -> 200. A response line that is not HTTP is malformed.
fn parse_status(line: &str) -> Result<u16, HttpError> {
    let mut parts = line.split_whitespace();
    let version = parts.next().unwrap_or_default();
    if !version.starts_with("HTTP/") {
        return Err(HttpError::Malformed(format!(
            "status line is not HTTP: {line:?}"
        )));
    }
    let code = parts
        .next()
        .ok_or_else(|| HttpError::Malformed("status line has no code".to_owned()))?
        .parse::<u16>()
        .map_err(|_| HttpError::Malformed(format!("status code is not a number: {line:?}")))?;
    Ok(code)
}

/// The response headers, lower-cased names, in order.
fn read_headers(transport: &mut dyn Transport) -> Result<Vec<(String, String)>, HttpError> {
    let mut headers = Vec::new();
    loop {
        let line = read_line(transport)?;
        if line.is_empty() {
            return Ok(headers);
        }
        let Some((name, value)) = line.split_once(':') else {
            return Err(HttpError::Malformed(format!(
                "header has no colon: {line:?}"
            )));
        };
        headers.push((name.trim().to_ascii_lowercase(), value.trim().to_owned()));
    }
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

/// The body: by length, by chunk, or until the peer closes.
fn read_body(
    transport: &mut dyn Transport,
    headers: &[(String, String)],
) -> Result<Vec<u8>, HttpError> {
    if let Some(length) = header(headers, "content-length") {
        let length: usize = length.parse().map_err(|_| {
            HttpError::Malformed(format!("content-length is not a number: {length}"))
        })?;
        if length > MAX_BODY_BYTES {
            return Err(HttpError::Malformed(format!("body too large: {length}")));
        }
        return transport.read_exact(length).map_err(map_transport);
    }
    if header(headers, "transfer-encoding")
        .map(|value| value.to_ascii_lowercase().contains("chunked"))
        .unwrap_or(false)
    {
        return read_chunked(transport);
    }
    // No length and no chunking: the body ends when the connection does.
    read_to_end(transport)
}

fn read_chunked(transport: &mut dyn Transport) -> Result<Vec<u8>, HttpError> {
    let mut body = Vec::new();
    loop {
        let line = read_line(transport)?;
        // A chunk size may carry extensions: "1a;name=value".
        let size_text = line.split(';').next().unwrap_or_default().trim();
        let size = usize::from_str_radix(size_text, 16)
            .map_err(|_| HttpError::Malformed(format!("chunk size is not hex: {size_text:?}")))?;
        if size == 0 {
            // Trailers, then the final empty line.
            loop {
                let trailer = read_line(transport)?;
                if trailer.is_empty() {
                    return Ok(body);
                }
            }
        }
        if body.len() + size > MAX_BODY_BYTES {
            return Err(HttpError::Malformed("chunked body too large".to_owned()));
        }
        let chunk = transport.read_exact(size).map_err(map_transport)?;
        body.extend_from_slice(&chunk);
        // The CRLF that ends the chunk.
        let terminator = transport.read_exact(2).map_err(map_transport)?;
        if terminator != b"\r\n" {
            return Err(HttpError::Malformed(
                "chunk is not CRLF terminated".to_owned(),
            ));
        }
    }
}

fn read_to_end(transport: &mut dyn Transport) -> Result<Vec<u8>, HttpError> {
    let mut body = Vec::new();
    loop {
        match transport.read_line() {
            Ok(line) => {
                if body.len() + line.len() > MAX_BODY_BYTES {
                    return Err(HttpError::Malformed("body too large".to_owned()));
                }
                body.extend_from_slice(line.as_bytes());
                body.push(b'\n');
            }
            // The peer closed: that is the end of the body.
            Err(TransportError::Closed) => return Ok(body),
            Err(error) => return Err(map_transport(error)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// A transport that replays a scripted server side.
    struct FakeTransport {
        lines: Vec<String>,
        bytes: Vec<u8>,
        written: Vec<u8>,
        connected: Option<(String, u16)>,
    }

    impl FakeTransport {
        fn with_script(lines: Vec<&str>, bytes: Vec<u8>) -> Self {
            Self {
                lines: lines.into_iter().map(str::to_owned).collect(),
                bytes,
                written: Vec::new(),
                connected: None,
            }
        }
    }

    impl Transport for FakeTransport {
        fn connect(&mut self, host: &str, port: u16) -> Result<(), TransportError> {
            self.connected = Some((host.to_owned(), port));
            Ok(())
        }
        fn write_all(&mut self, bytes: &[u8]) -> Result<(), TransportError> {
            self.written.extend_from_slice(bytes);
            Ok(())
        }
        fn read_line(&mut self) -> Result<String, TransportError> {
            if self.lines.is_empty() {
                return Err(TransportError::Closed);
            }
            Ok(self.lines.remove(0))
        }
        fn read_exact(&mut self, count: usize) -> Result<Vec<u8>, TransportError> {
            if self.bytes.len() < count {
                return Err(TransportError::Closed);
            }
            Ok(self.bytes.drain(..count).collect())
        }
        fn set_read_timeout(&mut self, _timeout: Duration) -> Result<(), TransportError> {
            Ok(())
        }
        fn close(&mut self) {}
        fn is_connected(&self) -> bool {
            self.connected.is_some()
        }
    }

    fn request() -> HttpRequest {
        HttpRequest {
            host: "api.example.test".to_owned(),
            port: 443,
            path: "/v1/chat/completions".to_owned(),
            headers: vec![
                ("Authorization".to_owned(), "Bearer secret".to_owned()),
                ("Content-Type".to_owned(), "application/json".to_owned()),
            ],
            body: b"{\"model\":\"m\"}".to_vec(),
        }
    }

    #[test]
    fn a_content_length_response_is_read_whole() {
        let mut transport = FakeTransport::with_script(
            vec![
                "HTTP/1.1 200 OK",
                "Content-Type: application/json",
                "Content-Length: 11",
                "",
            ],
            b"{\"ok\":true}".to_vec(),
        );
        let response = send(&mut transport, &request()).expect("response");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"{\"ok\":true}");
        let written = String::from_utf8_lossy(&transport.written).to_string();
        assert!(written.starts_with("POST /v1/chat/completions HTTP/1.1\r\n"));
        assert!(written.contains("Host: api.example.test\r\n"));
        assert!(written.contains("Authorization: Bearer secret\r\n"));
        assert!(written.contains("Content-Length: 13\r\n"));
        assert!(written.ends_with("{\"model\":\"m\"}"));
    }

    #[test]
    fn a_chunked_response_is_decoded() {
        // Each chunk is followed by its own CRLF.
        let mut transport = FakeTransport::with_script(
            vec![
                "HTTP/1.1 200 OK",
                "Transfer-Encoding: chunked",
                "",
                "5",
                "6",
                "0",
                "",
            ],
            b"hello\r\n world\r\n".to_vec(),
        );
        let response = send(&mut transport, &request()).expect("response");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"hello world");
    }

    #[test]
    fn a_response_without_a_length_ends_when_the_peer_closes() {
        let mut transport = FakeTransport::with_script(
            vec!["HTTP/1.1 500 Oops", "Content-Type: text/plain", ""],
            vec![],
        );
        let response = send(&mut transport, &request()).expect("response");
        assert_eq!(response.status, 500);
        assert!(response.body.is_empty());
    }

    #[test]
    fn a_non_http_answer_is_malformed_not_a_status() {
        let mut transport = FakeTransport::with_script(vec!["not http at all"], vec![]);
        let error = send(&mut transport, &request()).expect_err("must fail");
        assert!(matches!(error, HttpError::Malformed(_)));
    }

    #[test]
    fn the_request_carries_the_api_key_and_the_body() {
        let mut transport = FakeTransport::with_script(
            vec!["HTTP/1.1 200 OK", "Content-Length: 2", ""],
            b"ok".to_vec(),
        );
        send(&mut transport, &request()).expect("response");
        let written = String::from_utf8_lossy(&transport.written).to_string();
        assert!(written.contains("Content-Type: application/json\r\n"));
        assert!(written.contains("{\"model\":\"m\"}"));
    }
}
