//! How a chat completion leaves the machine.
//!
//! The seam exists for the same reason the mail provider seam does: the
//! routes must be testable without a network. The production transport
//! speaks HTTP/1.1 over lagoon-mail's TLS transport; the tests use a scripted
//! one that answers from a queue.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use lagoon_mail::transport::{TlsTransport, Transport};

use super::http;

/// Builds transports. Production is implicit TLS; tests inject their script.
pub type TransportFactory = Arc<dyn Fn() -> Box<dyn Transport> + Send + Sync>;

/// One chat completion request, in the seam's own shape.
#[derive(Debug, Clone, PartialEq)]
pub struct AiRequest {
    /// The full endpoint, e.g. `https://api.minimax.chat/v1/chat/completions`.
    pub url: String,
    pub api_key: String,
    pub model: String,
    /// The system prompt (the constitution, the job, the output format).
    pub system: String,
    /// The user prompt (the mail, the question).
    pub user: String,
    /// An upper bound on the answer's length.
    pub max_tokens: Option<u32>,
}

/// What the model answered.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AiReply {
    pub content: String,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
}

/// Why no answer came back.
#[derive(Debug, Clone, PartialEq)]
pub enum AiTransportError {
    /// The provider could not be reached (DNS, TCP, TLS, timeout).
    Unreachable(String),
    /// The provider answered with an error status.
    Rejected {
        status: u16,
        /// The provider's own words. Never shown to the user: the routes map
        /// this to a fixed code.
        body: String,
    },
    /// The answer was not the JSON we asked for.
    Malformed(String),
}

impl std::fmt::Display for AiTransportError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AiTransportError::Unreachable(reason) => {
                write!(formatter, "ai provider unreachable: {reason}")
            }
            AiTransportError::Rejected { status, .. } => {
                write!(formatter, "ai provider rejected the request: {status}")
            }
            AiTransportError::Malformed(reason) => {
                write!(
                    formatter,
                    "ai provider answered something unusable: {reason}"
                )
            }
        }
    }
}

impl std::error::Error for AiTransportError {}

pub type AiFuture<'a> =
    Pin<Box<dyn Future<Output = Result<AiReply, AiTransportError>> + Send + 'a>>;

/// One way to ask a model something.
pub trait AiTransport: Send + Sync {
    fn chat(&self, request: AiRequest) -> AiFuture<'_>;
}

/// The production transport: HTTPS to an OpenAI-compatible endpoint.
///
/// Blocking under the hood (the mail transport is), so the call runs on a
/// blocking thread.
pub struct HttpChatTransport {
    transport: TransportFactory,
    /// How long one answer may take. A long prompt on a slow model needs
    /// more than the mail protocol's 30 seconds.
    pub timeout: std::time::Duration,
}

impl HttpChatTransport {
    pub fn new() -> Self {
        Self {
            transport: Arc::new(|| Box::new(TlsTransport::new())),
            timeout: std::time::Duration::from_secs(120),
        }
    }

    pub fn with_transport(transport: TransportFactory) -> Self {
        Self {
            transport,
            ..Self::new()
        }
    }

    pub fn with_timeout(mut self, timeout: std::time::Duration) -> Self {
        self.timeout = timeout;
        self
    }
}

impl Default for HttpChatTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl AiTransport for HttpChatTransport {
    fn chat(&self, request: AiRequest) -> AiFuture<'_> {
        let transport = Arc::clone(&self.transport);
        let timeout = self.timeout;
        Box::pin(async move {
            let factory = Arc::clone(&transport);
            tokio::task::spawn_blocking(move || {
                let mut stream = (factory)();
                let _ = stream.set_read_timeout(timeout);
                chat_over(&mut *stream, request)
            })
            .await
            .map_err(|_| AiTransportError::Malformed("join".to_owned()))?
        })
    }
}

/// One request/response round trip over an open transport.
fn chat_over(stream: &mut dyn Transport, request: AiRequest) -> Result<AiReply, AiTransportError> {
    let (host, port, path) = split_url(&request.url)?;
    let payload = serde_json::json!({
        "model": request.model,
        "messages": [
            {"role": "system", "content": request.system},
            {"role": "user", "content": request.user},
        ],
        "stream": false,
        "temperature": 0.2,
        "max_tokens": request.max_tokens,
    });
    let http_request = http::HttpRequest {
        host: host.clone(),
        port,
        path,
        headers: vec![
            (
                "Authorization".to_owned(),
                format!("Bearer {}", request.api_key),
            ),
            ("Content-Type".to_owned(), "application/json".to_owned()),
            ("Accept".to_owned(), "application/json".to_owned()),
        ],
        body: serde_json::to_vec(&payload)
            .map_err(|error| AiTransportError::Malformed(format!("request body: {error}")))?,
    };
    let response = http::send(stream, &http_request).map_err(|error| match error {
        http::HttpError::Unreachable(reason) => AiTransportError::Unreachable(reason),
        http::HttpError::Malformed(reason) => AiTransportError::Malformed(reason),
    })?;
    if !(200..300).contains(&response.status) {
        return Err(AiTransportError::Rejected {
            status: response.status,
            body: String::from_utf8_lossy(&response.body)
                .chars()
                .take(2000)
                .collect(),
        });
    }
    parse_reply(&response.body)
}

/// Split `https://host:port/path` into its parts. Only https is accepted: an
/// API key must never travel in clear.
fn split_url(url: &str) -> Result<(String, u16, String), AiTransportError> {
    let rest = url
        .strip_prefix("https://")
        .ok_or_else(|| AiTransportError::Malformed("only https is allowed".to_owned()))?;
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => {
            let port = port
                .parse::<u16>()
                .map_err(|_| AiTransportError::Malformed("port is not a number".to_owned()))?;
            (host.to_owned(), port)
        }
        None => (authority.to_owned(), 443),
    };
    if host.is_empty() {
        return Err(AiTransportError::Malformed("no host in url".to_owned()));
    }
    Ok((host, port, path.to_owned()))
}

/// Read the answer out of an OpenAI-compatible response.
fn parse_reply(body: &[u8]) -> Result<AiReply, AiTransportError> {
    let value: serde_json::Value = serde_json::from_slice(body)
        .map_err(|error| AiTransportError::Malformed(format!("response json: {error}")))?;
    let content = value
        .get("choices")
        .and_then(|choices| choices.get(0))
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(|content| content.as_str())
        .ok_or_else(|| {
            AiTransportError::Malformed("response has no choices[0].message.content".to_owned())
        })?;
    let usage = value.get("usage");
    Ok(AiReply {
        content: content.to_owned(),
        prompt_tokens: usage
            .and_then(|usage| usage.get("prompt_tokens"))
            .and_then(|tokens| tokens.as_u64())
            .unwrap_or(0) as u32,
        completion_tokens: usage
            .and_then(|usage| usage.get("completion_tokens"))
            .and_then(|tokens| tokens.as_u64())
            .unwrap_or(0) as u32,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_url_is_split_into_host_port_and_path() {
        let (host, port, path) =
            split_url("https://api.minimax.chat/v1/chat/completions").expect("split");
        assert_eq!(host, "api.minimax.chat");
        assert_eq!(port, 443);
        assert_eq!(path, "/v1/chat/completions");
    }

    #[test]
    fn a_plain_http_url_is_refused() {
        let error = split_url("http://api.example.test/chat").expect_err("must refuse");
        assert!(matches!(error, AiTransportError::Malformed(_)));
    }

    #[test]
    fn a_reply_is_read_out_of_the_response_json() {
        let reply = parse_reply(
            br#"{"choices":[{"message":{"content":"hello"}}],
                 "usage":{"prompt_tokens":120,"completion_tokens":30}}"#,
        )
        .expect("reply");
        assert_eq!(reply.content, "hello");
        assert_eq!(reply.prompt_tokens, 120);
        assert_eq!(reply.completion_tokens, 30);
    }

    #[test]
    fn a_response_without_content_is_malformed() {
        let error = parse_reply(br#"{"choices":[]}"#).expect_err("must fail");
        assert!(matches!(error, AiTransportError::Malformed(_)));
    }
}
