//! Response construction: one JSON envelope, one error shape.
//!
//! v3's `RouteJSON` (`Sources/LagoonServer/Routes/RouteSupport.swift:27-109`)
//! is the only place a response is shaped, and the reason is in its comment:
//! the macOS client decodes `{"error":"<code>"}` without per-route special
//! cases. This module is the same decision in Rust.

use axum::body::Body;
use axum::http::{header, StatusCode};
use axum::response::Response;
use serde::Serialize;

/// Every JSON response, success or failure.
pub const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";

/// `GET /healthz` only - the probe is read by `curl -f`, not by a JSON client.
pub const TEXT_CONTENT_TYPE: &str = "text/plain; charset=utf-8";

#[derive(Serialize)]
struct ErrorEnvelope<'a> {
    error: &'a str,
}

/// A JSON body with the contract's Content-Type.
pub fn json<T: Serialize>(status: StatusCode, value: &T) -> Response {
    match serde_json::to_vec(value) {
        Ok(body) => build(status, JSON_CONTENT_TYPE, Body::from(body)),
        // v3 answers `encoding-failed` here; it is unreachable for these types,
        // and matching the code costs one string.
        Err(_) => error(StatusCode::INTERNAL_SERVER_ERROR, "encoding-failed"),
    }
}

/// The error envelope: `{"error":"<code>"}` and nothing else.
///
/// Upstream/provider text is never echoed - the code is the whole message, and
/// the server-side detail belongs in the log.
pub fn error(status: StatusCode, code: &str) -> Response {
    let body = serde_json::to_vec(&ErrorEnvelope { error: code })
        .unwrap_or_else(|_| br#"{"error":"error"}"#.to_vec());
    build(status, JSON_CONTENT_TYPE, Body::from(body))
}

/// An empty body with just a status - the 204 routes (v3 returns a bare
/// Response(status:) there, with no Content-Type).
pub fn empty(status: StatusCode) -> Response {
    let mut response = Response::new(Body::empty());
    *response.status_mut() = status;
    response
}

/// A plain-text body (the health probe).
pub fn text(status: StatusCode, value: &'static str) -> Response {
    build(status, TEXT_CONTENT_TYPE, Body::from(value))
}

fn build(status: StatusCode, content_type: &'static str, body: Body) -> Response {
    let mut response = Response::new(body);
    *response.status_mut() = status;
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, header::HeaderValue::from_static(content_type));
    response
}
