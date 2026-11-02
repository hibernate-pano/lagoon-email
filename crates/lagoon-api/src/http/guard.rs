//! Host guard then bearer auth - in that order, exactly like v3.
//!
//! v3's middleware stack is `LoopbackHostMiddleware` -> `APIAuthMiddleware` ->
//! routes (`Runtime.swift:187-191`), and the order is load-bearing: a request
//! with an evil `Host` must be refused as a *forbidden host* before anyone
//! looks at its credentials, because the Host check is the DNS-rebinding
//! defence and a 401 would leak that the server is there.
//!
//! Both checks are fail-closed, for the reason the long comments in
//! `APIAuth.swift` and `HostGuard.swift` give: a spelling the router can still
//! match must not be able to slip past the gate.

use axum::extract::{Request, State};
use axum::http::{header, StatusCode};
use axum::middleware::Next;
use axum::response::Response;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use super::respond;
use super::AppState;
use crate::config::normalize_host;

/// The only path reachable without a token - an exact match, so `//healthz`
/// (which a router may still normalise) is gated, not skipped.
const UNGATED_PATHS: [&str; 1] = ["/healthz"];

pub async fn enforce(State(state): State<AppState>, request: Request, next: Next) -> Response {
    // 1. Host guard. No `Host` header at all is not a legitimate loopback
    //    client, so absent is refused rather than treated as "no opinion".
    let host = request
        .headers()
        .get(header::HOST)
        .and_then(|value| value.to_str().ok());
    let host_allowed = host
        .map(normalize_host)
        .is_some_and(|host| state.allowed_hosts.contains(&host));
    if !host_allowed {
        return respond::error(StatusCode::FORBIDDEN, "forbidden-host");
    }

    // 2. Bearer auth. Fail closed: no token means "this server cannot
    //    authenticate anyone", and the only safe answer is 401. `Config::load`
    //    refuses to start without one, so this branch is defence in depth
    //    against a `Config` built by hand (tests, future embedders).
    let ungated = UNGATED_PATHS.contains(&request.uri().path());
    if !ungated {
        let Some(token) = state.api_token.as_deref().filter(|token| !token.is_empty()) else {
            return respond::error(StatusCode::UNAUTHORIZED, "api-unauthorized");
        };
        let presented = request
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok());
        let expected = format!("Bearer {token}");
        if !timing_safe_eq(presented, &expected) {
            return respond::error(StatusCode::UNAUTHORIZED, "api-unauthorized");
        }
    }

    next.run(request).await
}

/// Compare two strings without letting the comparison time reveal which prefix
/// matched.
///
/// v3 hashes both sides with SHA-256 first, because a raw byte loop would
/// return early on a length mismatch and leak the token's length. Same shape
/// here: digest both, then compare the fixed-width digests in constant time.
fn timing_safe_eq(presented: Option<&str>, expected: &str) -> bool {
    let Some(presented) = presented else {
        return false;
    };
    let presented = Sha256::digest(presented.as_bytes());
    let expected = Sha256::digest(expected.as_bytes());
    presented.as_slice().ct_eq(expected.as_slice()).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_token_matches_and_nothing_else_does() {
        assert!(timing_safe_eq(Some("Bearer abc123"), "Bearer abc123"));
        assert!(!timing_safe_eq(Some("Bearer abc124"), "Bearer abc123"));
        assert!(!timing_safe_eq(Some("Bearer abc12"), "Bearer abc123"));
        assert!(!timing_safe_eq(Some("abc123"), "Bearer abc123"));
        assert!(!timing_safe_eq(None, "Bearer abc123"));
    }
}
