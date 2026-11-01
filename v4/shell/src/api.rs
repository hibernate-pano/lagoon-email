//! The `api` command — the only business channel (contract §4.2).
//!
//! Shape, verbatim from the contract:
//!
//! ```ts
//! type ApiResponse =
//!   | { ok: true;  status: number; body: unknown }
//!   | { ok: false; status: 0; error: { code: "not-ready" | "transport" |
//!                                             "timeout" | "bad-path" | "bad-request";
//!                                       message: string } };
//! ```
//!
//! The transparency rule (§1.2, §4.2): a 4xx/5xx from the server is
//! `ok: true` with the server's status and body untouched. Only "there was no
//! answer" is `ok: false`. Nothing here rewrites a body, retries a write, or
//! leaks the Bearer token.

use std::collections::HashMap;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::state::Shared;

/// Contract §4.2 `ApiRequest`.
#[derive(Debug, Clone, Deserialize)]
pub struct ApiRequest {
    pub method: String,
    /// Must start with "/api/" (or be "/healthz").
    pub path: String,
    /// Values may arrive as string / number / boolean / null from JS.
    /// They are stringified here: rejecting `limit: 500` with `bad-request`
    /// would be a contract violation the web side cannot see coming.
    #[serde(default, deserialize_with = "stringify_query")]
    pub query: Option<HashMap<String, String>>,
    #[serde(default)]
    pub body: Option<Value>,
}

#[derive(Serialize, Clone, Debug)]
pub struct ApiError {
    pub code: &'static str,
    pub message: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct ApiResponse {
    pub ok: bool,
    pub status: u16,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ApiError>,
}

impl ApiResponse {
    pub fn fail(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            status: 0,
            body: None,
            error: Some(ApiError { code, message: message.into() }),
        }
    }

    pub fn answered(status: u16, body: Value) -> Self {
        Self { ok: true, status, body: Some(body), error: None }
    }
}

/// Deserialize `query` from a map of JSON values into a map of strings.
fn stringify_query<'de, D>(deserializer: D) -> Result<Option<HashMap<String, String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw: Option<HashMap<String, Value>> = Option::deserialize(deserializer)?;
    Ok(raw.map(|map| {
        map.into_iter()
            .map(|(key, value)| {
                let text = match value {
                    Value::String(text) => text,
                    Value::Number(number) => number.to_string(),
                    Value::Bool(flag) => flag.to_string(),
                    Value::Null => String::new(),
                    other => other.to_string(),
                };
                (key, text)
            })
            .collect()
    }))
}

/// Both `invoke("api", { request })` and `invoke("api", request)` are accepted:
/// the contract pins the *types*, not the argument wrapper, and guessing wrong
/// would break the web side on day one. Everything else is `bad-request`.
pub fn parse_request(raw: Value) -> Result<ApiRequest, ApiResponse> {
    let Value::Object(map) = raw else {
        return Err(ApiResponse::fail("bad-request", "request must be a JSON object"));
    };
    let candidate = match map.get("request") {
        Some(Value::Object(inner)) if !map.contains_key("method") => Value::Object(inner.clone()),
        _ => Value::Object(map),
    };
    serde_json::from_value::<ApiRequest>(candidate)
        .map_err(|e| ApiResponse::fail("bad-request", format!("invalid ApiRequest: {e}")))
}

fn method_of(method: &str) -> Option<reqwest::Method> {
    match method {
        "GET" => Some(reqwest::Method::GET),
        "POST" => Some(reqwest::Method::POST),
        "PATCH" => Some(reqwest::Method::PATCH),
        "DELETE" => Some(reqwest::Method::DELETE),
        _ => None,
    }
}

/// §4.2 path whitelist. Anything that is not a plain path under /api/ (or
/// /healthz) is refused before a socket is opened — this is the SSRF guard.
pub fn validate(req: &ApiRequest) -> Result<reqwest::Method, ApiResponse> {
    let Some(method) = method_of(&req.method) else {
        return Err(ApiResponse::fail(
            "bad-request",
            format!("unsupported method {:?}; use GET, POST, PATCH or DELETE", req.method),
        ));
    };
    let path = req.path.as_str();
    let allowed = path == "/healthz" || path.starts_with("/api/");
    if !allowed {
        return Err(ApiResponse::fail(
            "bad-path",
            format!("path {path:?} is not under /api/ (or /healthz)"),
        ));
    }
    if path.starts_with("//")
        || path.contains("://")
        || path.chars().any(|c| c.is_control() || c == ' ' || c == '\t')
    {
        return Err(ApiResponse::fail("bad-path", format!("path {path:?} is not a plain path")));
    }
    Ok(method)
}

/// An empty body is `null`; a non-JSON body is passed through as a string.
/// Both are documented limits (README §"已知限制"), never silent rewrites.
fn body_value(bytes: &[u8]) -> Value {
    if bytes.is_empty() {
        return Value::Null;
    }
    match serde_json::from_slice::<Value>(bytes) {
        Ok(value) => value,
        Err(_) => Value::String(String::from_utf8_lossy(bytes).into_owned()),
    }
}

/// Percent-encoding for query values (RFC 3986 unreserved set kept literal).
/// Done by hand so the crate does not depend on a reqwest feature flag that
/// only some builds enable: the proxy must not silently drop a query string.
fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Path plus the encoded query. Pairs are sorted so a retry sends the same
/// URL, which makes server-side logs comparable.
fn with_query(path: &str, query: &Option<HashMap<String, String>>) -> String {
    let Some(query) = query else { return path.to_string() };
    if query.is_empty() {
        return path.to_string();
    }
    let mut pairs: Vec<String> = query
        .iter()
        .map(|(key, value)| format!("{}={}", percent_encode(key), percent_encode(value)))
        .collect();
    pairs.sort();
    let separator = if path.contains('?') { '&' } else { '?' };
    format!("{path}{separator}{}", pairs.join("&"))
}

fn classify(err: &reqwest::Error) -> ApiResponse {
    if err.is_timeout() {
        ApiResponse::fail("timeout", format!("sidecar did not answer in time: {err}"))
    } else {
        ApiResponse::fail("transport", format!("could not reach the sidecar: {err}"))
    }
}

/// Every proxied call is logged once (method, path, status only — never the
/// query values, never the token). This is what makes "the WebView really
/// talked to the sidecar" observable from a terminal.
pub async fn forward(shared: &Shared, req: ApiRequest) -> ApiResponse {
    let method = req.method.clone();
    let path = req.path.clone();
    let response = forward_inner(shared, req).await;
    eprintln!("[ipc] api {method} {path} -> {}", response.status);
    response
}

async fn forward_inner(shared: &Shared, req: ApiRequest) -> ApiResponse {
    let method = match validate(&req) {
        Ok(method) => method,
        Err(response) => return response,
    };
    let Some((base, token)) = shared.ready_endpoint() else {
        let status = shared.status();
        return ApiResponse::fail(
            "not-ready",
            format!("sidecar is {:?}{}", status.phase.as_str(), match &status.error {
                Some(error) => format!(" ({})", error.code),
                None => String::new(),
            }),
        );
    };

    let url = format!("{base}{}", with_query(&req.path, &req.query));
    // GET may be retried once, and only on a transport failure (§4.2).
    let attempts = if method == reqwest::Method::GET { 2 } else { 1 };
    let mut last: Option<ApiResponse> = None;

    for attempt in 0..attempts {
        let mut builder = shared
            .http
            .request(method.clone(), &url)
            .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
            .header(reqwest::header::ACCEPT, "application/json");
        if let Some(body) = &req.body {
            builder = builder.json(body);
        }

        match builder.send().await {
            Ok(response) => {
                let status = response.status().as_u16();
                match response.bytes().await {
                    Ok(bytes) => return ApiResponse::answered(status, body_value(&bytes)),
                    Err(e) => {
                        last = Some(classify(&e));
                        break;
                    }
                }
            }
            Err(e) => {
                let response = classify(&e);
                let retryable = response.error.as_ref().map(|e| e.code == "transport").unwrap_or(false);
                if retryable && attempt + 1 < attempts {
                    last = Some(response);
                    tokio::time::sleep(Duration::from_millis(120)).await;
                    continue;
                }
                return response;
            }
        }
    }

    last.unwrap_or_else(|| ApiResponse::fail("transport", "request failed without an error"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(method: &str, path: &str) -> ApiRequest {
        ApiRequest { method: method.into(), path: path.into(), query: None, body: None }
    }

    #[test]
    fn whitelist_accepts_api_and_healthz_only() {
        assert!(validate(&request("GET", "/healthz")).is_ok());
        assert!(validate(&request("GET", "/api/accounts")).is_ok());
        assert!(validate(&request("DELETE", "/api/messages/1")).is_ok());
        let refused = validate(&request("GET", "/")).unwrap_err();
        assert_eq!(refused.error.unwrap().code, "bad-path");
        let refused = validate(&request("GET", "/api")).unwrap_err();
        assert_eq!(refused.error.unwrap().code, "bad-path");
        let refused = validate(&request("GET", "http://127.0.0.1:1/api/x")).unwrap_err();
        assert_eq!(refused.error.unwrap().code, "bad-path");
        let refused = validate(&request("GET", "/api/x\r\nHost: evil")).unwrap_err();
        assert_eq!(refused.error.unwrap().code, "bad-path");
    }

    #[test]
    fn unknown_method_is_bad_request() {
        let refused = validate(&request("TRACE", "/api/accounts")).unwrap_err();
        assert_eq!(refused.error.unwrap().code, "bad-request");
    }

    #[test]
    fn parse_accepts_wrapped_and_flat_shapes() {
        let flat = serde_json::json!({"method":"GET","path":"/api/accounts"});
        assert_eq!(parse_request(flat).unwrap().path, "/api/accounts");
        let wrapped = serde_json::json!({"request":{"method":"GET","path":"/healthz"}});
        assert_eq!(parse_request(wrapped).unwrap().path, "/healthz");
        let broken = serde_json::json!({"method":"GET"});
        assert_eq!(parse_request(broken).unwrap_err().error.unwrap().code, "bad-request");
    }

    #[test]
    fn query_is_encoded_not_dropped() {
        let mut query = HashMap::new();
        query.insert("q".to_string(), "中文 a&b".to_string());
        query.insert("limit".to_string(), "20".to_string());
        assert_eq!(
            with_query("/api/search", &Some(query)),
            "/api/search?limit=20&q=%E4%B8%AD%E6%96%87%20a%26b"
        );
        assert_eq!(with_query("/api/search", &None), "/api/search");
    }

    #[test]
    fn body_mapping_is_documented_shape() {
        assert_eq!(body_value(b""), Value::Null);
        assert_eq!(body_value(br#"{"a":1}"#), serde_json::json!({"a":1}));
        assert_eq!(body_value(b"not json"), Value::String("not json".into()));
    }
}
