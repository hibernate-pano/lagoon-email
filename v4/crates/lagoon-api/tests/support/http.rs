//! A minimal HTTP/1.1 client, so the tests exercise the real router.

use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;

pub type HttpClient = Client<HttpConnector, Full<Bytes>>;

pub fn client() -> HttpClient {
    Client::builder(TokioExecutor::new()).build_http()
}

/// One observed response, in the shape the fixtures record.
#[derive(Debug, Clone, PartialEq)]
pub struct Observed {
    pub status: u16,
    pub content_type: String,
    pub body_kind: &'static str,
    pub body: serde_json::Value,
}

pub async fn request(
    client: &HttpClient,
    method: &str,
    url: &str,
    headers: &[(String, String)],
) -> Observed {
    request_with_body(client, method, url, headers, &[]).await
}

/// Same, with a request body (the account routes take JSON).
pub async fn request_with_body(
    client: &HttpClient,
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: &[u8],
) -> Observed {
    let method = hyper::Method::from_bytes(method.as_bytes()).expect("method");
    let mut builder = hyper::Request::builder().method(method).uri(url);
    for (name, value) in headers {
        builder = builder.header(name.as_str(), value.as_str());
    }
    let request = builder
        .body(Full::new(Bytes::copy_from_slice(body)))
        .expect("build request");
    let response = client.request(request).await.expect("send request");
    let status = response.status().as_u16();
    let content_type = response
        .headers()
        .get(hyper::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .to_owned();
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("read body")
        .to_bytes();
    let (body_kind, body) = if bytes.is_empty() {
        ("empty", serde_json::Value::Null)
    } else if content_type.to_ascii_lowercase().contains("application/json") {
        match serde_json::from_slice::<serde_json::Value>(&bytes) {
            Ok(value) => ("json", value),
            Err(_) => (
                "text",
                serde_json::Value::String(String::from_utf8_lossy(&bytes).into()),
            ),
        }
    } else {
        (
            "text",
            serde_json::Value::String(String::from_utf8_lossy(&bytes).into()),
        )
    };
    Observed {
        status,
        content_type,
        body_kind,
        body,
    }
}
