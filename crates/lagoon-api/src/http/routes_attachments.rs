//! The read paths that need the mailbox, not the cache: inline images and
//! attachment downloads.
//!
//! Both routes read the same way, and both are reads: nothing here writes to
//! the mailbox, and the "✉读" column in the contract says so.
//!
//! Why one fetch and one parse per route, and not one per image or per
//! attachment: the provider resolves a message by its Message-ID (a search
//! that comes back empty on QQ, then a whole-mailbox scan) or by the UID the
//! sync loop stored. Either way the cost is one message download, and the
//! parser can hand out every part of it in one pass. Asking per picture would
//! download the whole mail for every `cid:` in the body.
//!
//! The answers are facts, not guesses:
//!
//! * the message is gone → 410 `message-gone`;
//! * the message is there and the part is not → 404 `attachment-not-found`;
//! * the part is over the cap → 413 `attachment-too-large`;
//! * the account does not exist → 404 `unknown-account`, before any provider
//!   work;
//! * the account has no readable credentials → 503 `provider-not-configured`.

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, StatusCode};
use axum::response::Response;

use crate::provider::ProviderError;
use crate::store;
use crate::uuid::Uuid;

use super::query;
use super::respond;
use super::AppState;

/// The contract's cap: ≤40 images and ≤8 MB in total.
const MAX_INLINE_IMAGES: usize = 40;
const MAX_INLINE_IMAGE_BYTES: usize = 8 * 1024 * 1024;

/// `GET /api/messages/{remoteId}/attachments/{attachmentId}` - the bytes.
///
/// The response is the file itself: the original MIME type, the original
/// filename, and the bytes. Not JSON, not base64 - a download is a download.
pub async fn attachment(
    State(state): State<AppState>,
    Path((remote_id, attachment_id)): Path<(String, String)>,
    uri: axum::http::Uri,
) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    if remote_id.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-remoteId");
    }
    // The part id reaches an IMAP command (`BODY.PEEK[1.2]`), so it is
    // validated to digits and dots here: a value that can close the bracket
    // can also inject a command.
    if !is_part_path(&attachment_id) {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-attachmentId");
    }
    // The account gate comes before the provider: an account that does not
    // exist is 404, not 503.
    match state.account_exists(account_id).await {
        Some(true) => {}
        Some(false) => return respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        None => return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error"),
    }
    let Some(provider) = state.body_provider(account_id) else {
        return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
    };

    let uid_hint = inbox_uid_hint(&state, account_id, &remote_id).await;
    let fetched = match provider
        .fetch_attachment(&remote_id, uid_hint, &attachment_id)
        .await
    {
        Ok(Some(attachment)) => attachment,
        // The message is there; this part is not.
        Ok(None) => return respond::error(StatusCode::NOT_FOUND, "attachment-not-found"),
        Err(error) => return provider_failure(&error),
    };

    let filename = fetched.filename.unwrap_or_else(|| attachment_id.clone());
    let mut response = Response::new(Body::from(fetched.data));
    *response.status_mut() = StatusCode::OK;
    let headers = response.headers_mut();
    if let Ok(value) = header::HeaderValue::from_str(&fetched.mime_type) {
        headers.insert(header::CONTENT_TYPE, value);
    }
    if let Ok(value) = header::HeaderValue::from_str(&content_disposition(&filename)) {
        headers.insert(header::CONTENT_DISPOSITION, value);
    }
    response
}

/// `GET /api/messages/{remoteId}/inline-images` - the `cid:` pictures.
///
/// The keys are the content ids, lowercased and without the angle brackets,
/// so the reader can look a `cid:` reference up without parsing it.
pub async fn inline_images(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    uri: axum::http::Uri,
) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    if remote_id.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-remoteId");
    }
    match state.account_exists(account_id).await {
        Some(true) => {}
        Some(false) => return respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        None => return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error"),
    }
    let Some(provider) = state.body_provider(account_id) else {
        return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
    };

    let uid_hint = inbox_uid_hint(&state, account_id, &remote_id).await;
    let images = match provider.fetch_inline_images(&remote_id, uid_hint).await {
        Ok(images) => images,
        Err(error) => return provider_failure(&error),
    };

    let mut map = std::collections::BTreeMap::new();
    let mut total = 0usize;
    for image in images {
        if map.len() >= MAX_INLINE_IMAGES {
            break;
        }
        total += image.data.len();
        if total > MAX_INLINE_IMAGE_BYTES {
            break;
        }
        let key = image
            .content_id
            .trim()
            .trim_matches(|ch| ch == '<' || ch == '>')
            .to_lowercase();
        if key.is_empty() {
            continue;
        }
        map.insert(key, base64_string(&image.data));
    }
    respond::json(
        StatusCode::OK,
        &crate::wire_r2::InlineImagesResponse { images: map },
    )
}

/// The provider failure as the contract's answer.
fn provider_failure(error: &ProviderError) -> Response {
    match error {
        ProviderError::AuthFailed => {
            respond::error(StatusCode::UNAUTHORIZED, "provider-auth-failed")
        }
        ProviderError::MessageGone => respond::error(StatusCode::GONE, "message-gone"),
        ProviderError::NotConfigured(_) => {
            respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured")
        }
        ProviderError::NotFound(_) => respond::error(StatusCode::NOT_FOUND, "attachment-not-found"),
        ProviderError::TooLarge(_) => {
            respond::error(StatusCode::PAYLOAD_TOO_LARGE, "attachment-too-large")
        }
        ProviderError::Unreachable(_) | ProviderError::Protocol(_) => {
            respond::error(StatusCode::BAD_GATEWAY, "provider-unreachable")
        }
    }
}

/// A part path: digits and dots only (`1`, `1.2`). Nothing else may reach an
/// IMAP command.
///
/// Every segment must be non-empty digits: `1..2` or `.1` is not a part path a
/// mailbox can have, and letting it through would turn a client bug into a 502
/// from the IMAP server.
fn is_part_path(value: &str) -> bool {
    !value.is_empty()
        && value
            .split('.')
            .all(|segment| !segment.is_empty() && segment.bytes().all(|byte| byte.is_ascii_digit()))
}

/// `Content-Disposition: attachment; filename="…"; filename*=UTF-8''…`
///
/// Both forms, because a Chinese filename has to survive: the plain form for
/// old clients, the RFC 5987 form for the ones that read it.
fn content_disposition(filename: &str) -> String {
    let ascii: String = filename
        .chars()
        .map(|ch| {
            if ch.is_ascii() && ch != '"' && ch != '\\' {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let ascii = if ascii.is_empty() {
        "attachment".to_owned()
    } else {
        ascii
    };
    let mut out = format!("attachment; filename=\"{ascii}\"");
    if filename != ascii {
        out.push_str(&format!(
            "; filename*=UTF-8''{}",
            percent_encode_utf8(filename)
        ));
    }
    out
}

/// Percent-encoding for an RFC 5987 extended value.
fn percent_encode_utf8(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Standard base64, with the padding.
fn base64_string(data: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(data)
}

/// The UID the sync loop stored for this row, if the row is still in the
/// inbox. Best effort: a miss just means the provider resolves by identity.
async fn inbox_uid_hint(state: &AppState, account_id: Uuid, remote_id: &str) -> Option<i64> {
    let remote_id = remote_id.to_owned();
    state
        .db
        .read(move |connection| {
            store::messages::inbox_remote_uid(connection, account_id, &remote_id)
        })
        .await
        .ok()
        .flatten()
}

fn account_id_param(params: &[(String, String)]) -> Option<Uuid> {
    params
        .iter()
        .find(|(name, _)| name == "accountId")
        .and_then(|(_, value)| Uuid::parse_strict(value.trim()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_part_path_is_digits_and_dots() {
        assert!(is_part_path("1"));
        assert!(is_part_path("1.2"));
        assert!(is_part_path("1.2.3"));
        assert!(!is_part_path(""));
        assert!(!is_part_path("1.2]"));
        assert!(!is_part_path("1 2"));
        assert!(!is_part_path("a"));
        assert!(!is_part_path("1.2\r\nX"));
        // A segment is digits, and every segment exists.
        assert!(!is_part_path("1..2"));
        assert!(!is_part_path(".1"));
        assert!(!is_part_path("1."));
    }

    #[test]
    fn a_chinese_filename_keeps_both_forms() {
        let disposition = content_disposition("会议纪要.pdf");
        assert!(disposition.starts_with("attachment; filename=\""));
        assert!(disposition.contains("filename*=UTF-8''%E4%BC%9A%E8%AE%AE%E7%BA%AA%E8%A6%81.pdf"));
    }

    #[test]
    fn an_ascii_filename_needs_no_extended_form() {
        let disposition = content_disposition("report.pdf");
        assert_eq!(disposition, "attachment; filename=\"report.pdf\"");
    }
}
