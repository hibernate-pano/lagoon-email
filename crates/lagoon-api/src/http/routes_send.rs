//! R3.5b: the three send paths - reply, compose, forward.
//!
//! The rules that decide whether a send is trustworthy:
//! * **one requestId, one delivery.** The unique index on
//!   `ai_actions(account_id, requestId)` is the lock: the request that wins
//!   the INSERT is the only one allowed to talk to SMTP.
//! * **a replay answers the first result.** A repeated requestId returns the
//!   provider id it produced, and a failed attempt replays its own error
//!   instead of sending again.
//! * **the request is checked before SMTP.** An invalid recipient, an
//!   unreadable attachment, a malformed requestId - all refused with 400
//!   before a byte reaches the server. A recipient is never dropped on the
//!   way, and an attachment is never silently lost.
//! * **the sent copy is local.** The message that left is stored with its
//!   body, so "已发送" lists it and opening it never asks the server.
//! * **forwarding carries the original.** The whole RFC 5322 message goes as
//!   a `message/rfc822` part; the recipient sees the original, not a quote.

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::Response;
use base64::Engine as _;
use serde_json::Value;

use crate::provider::{OutgoingAttachment, OutgoingMail, ProviderError};
use crate::store::messages::StoredMessage;
use crate::store::{self, write, StoreError};
use crate::uuid::Uuid;
use crate::wire_r2::SendResponse;

use super::query;
use super::respond;
use super::AppState;

/// One attachment: 25 MB, the same ceiling the download route uses.
const MAX_ATTACHMENT_BYTES: usize = 25 * 1024 * 1024;
/// All attachments together: 48 MB.
const MAX_TOTAL_ATTACHMENT_BYTES: usize = 48 * 1024 * 1024;
/// The snippet kept for the sent row.
const SNIPPET_CHARS: usize = 200;

#[derive(Clone, Copy, PartialEq, Eq)]
enum SendKind {
    Reply,
    Compose,
    Forward,
}

impl SendKind {
    /// The code for a body that is not the shape this route accepts.
    fn malformed_shape(&self) -> &'static str {
        match self {
            SendKind::Reply => "malformed-body",
            SendKind::Compose => "malformed-compose",
            SendKind::Forward => "malformed-forward",
        }
    }
}

fn internal_error(label: &'static str, error: impl std::fmt::Display) -> Response {
    tracing::error!(label, err = %error, "send.queryFailed");
    respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
}

/// POST /api/messages/{remoteId}/send - reply to a message.
pub async fn reply(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    uri: axum::http::Uri,
    body: Bytes,
) -> Response {
    let account_id = match account_id_param(&uri) {
        Some(account_id) => account_id,
        None => return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId"),
    };
    if remote_id.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-remoteId");
    }
    let request = match parse_request(SendKind::Reply, &body) {
        Ok(request) => request,
        Err(response) => return response,
    };
    deliver(
        &state,
        account_id,
        SendKind::Reply,
        Some(remote_id),
        request,
    )
    .await
}

/// POST /api/compose/send - a new message.
pub async fn compose(State(state): State<AppState>, uri: axum::http::Uri, body: Bytes) -> Response {
    let account_id = match account_id_param(&uri) {
        Some(account_id) => account_id,
        None => return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId"),
    };
    let request = match parse_request(SendKind::Compose, &body) {
        Ok(request) => request,
        Err(response) => return response,
    };
    deliver(&state, account_id, SendKind::Compose, None, request).await
}

/// POST /api/messages/{remoteId}/forward - the original, forwarded as itself.
pub async fn forward(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    uri: axum::http::Uri,
    body: Bytes,
) -> Response {
    let account_id = match account_id_param(&uri) {
        Some(account_id) => account_id,
        None => return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId"),
    };
    if remote_id.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-remoteId");
    }
    let request = match parse_request(SendKind::Forward, &body) {
        Ok(request) => request,
        Err(response) => return response,
    };
    deliver(
        &state,
        account_id,
        SendKind::Forward,
        Some(remote_id),
        request,
    )
    .await
}

// ---------------------------------------------------------------- parsing --

/// The parsed body of a send request. Every field the route needs, already
/// validated: an invalid recipient or attachment never reaches SMTP.
struct SendRequest {
    to: Option<Vec<String>>,
    cc: Vec<String>,
    bcc: Vec<String>,
    subject: Option<String>,
    body: Option<String>,
    request_id: Option<String>,
    attachments: Vec<OutgoingAttachment>,
}

fn parse_request(kind: SendKind, raw: &[u8]) -> Result<SendRequest, Response> {
    let value: Value = serde_json::from_slice(raw)
        .map_err(|_| respond::error(StatusCode::BAD_REQUEST, kind.malformed_shape()))?;
    let Some(object) = value.as_object() else {
        return Err(respond::error(
            StatusCode::BAD_REQUEST,
            kind.malformed_shape(),
        ));
    };

    let body = match kind {
        SendKind::Reply => match object.get("body") {
            Some(Value::String(body)) if !body.trim().is_empty() => Some(body.clone()),
            _ => return Err(respond::error(StatusCode::BAD_REQUEST, "malformed-body")),
        },
        SendKind::Compose => match object.get("body") {
            Some(Value::String(body)) => Some(body.clone()),
            _ => return Err(respond::error(StatusCode::BAD_REQUEST, "malformed-compose")),
        },
        SendKind::Forward => match object.get("body") {
            Some(Value::String(body)) => Some(body.clone()),
            None => Some(String::new()),
            _ => return Err(respond::error(StatusCode::BAD_REQUEST, "malformed-forward")),
        },
    };

    let to = match kind {
        // Compose carries one string; the other two carry a list.
        SendKind::Compose => match object.get("to") {
            Some(Value::String(raw)) => Some(addresses_from_string(raw)?),
            _ => return Err(respond::error(StatusCode::BAD_REQUEST, "malformed-compose")),
        },
        SendKind::Reply => match object.get("to") {
            None => None,
            Some(Value::Array(items)) => Some(addresses_from_list(items)?),
            _ => {
                return Err(respond::error(
                    StatusCode::BAD_REQUEST,
                    "malformed-recipient",
                ))
            }
        },
        SendKind::Forward => match object.get("to") {
            Some(Value::Array(items)) => Some(addresses_from_list(items)?),
            _ => return Err(respond::error(StatusCode::BAD_REQUEST, "malformed-forward")),
        },
    };
    if matches!(kind, SendKind::Compose | SendKind::Forward)
        && to.as_ref().is_some_and(Vec::is_empty)
    {
        return Err(respond::error(
            StatusCode::BAD_REQUEST,
            "malformed-recipient",
        ));
    }

    let subject = match object.get("subject") {
        None => None,
        Some(Value::String(subject)) => Some(subject.clone()),
        Some(_) => {
            return Err(respond::error(
                StatusCode::BAD_REQUEST,
                kind.malformed_shape(),
            ))
        }
    };

    let cc = optional_addresses(object.get("cc"), kind)?;
    let bcc = optional_addresses(object.get("bcc"), kind)?;

    let request_id = match object.get("requestId") {
        None | Some(Value::Null) => None,
        Some(Value::String(raw)) => match Uuid::parse_strict(raw) {
            Some(uuid) => Some(uuid.to_wire_string()),
            None => {
                return Err(respond::error(
                    StatusCode::BAD_REQUEST,
                    "malformed-request-id",
                ))
            }
        },
        Some(_) => {
            return Err(respond::error(
                StatusCode::BAD_REQUEST,
                "malformed-request-id",
            ))
        }
    };

    let attachments = match object.get("attachments") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => parse_attachments(items)?,
        Some(_) => {
            return Err(respond::error(
                StatusCode::BAD_REQUEST,
                "malformed-attachment",
            ))
        }
    };

    Ok(SendRequest {
        to,
        cc,
        bcc,
        subject,
        body,
        request_id,
        attachments,
    })
}

fn optional_addresses(value: Option<&Value>, kind: SendKind) -> Result<Vec<String>, Response> {
    match value {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => addresses_from_list(items),
        Some(Value::String(raw)) => addresses_from_string(raw),
        Some(_) => Err(respond::error(
            StatusCode::BAD_REQUEST,
            kind.malformed_shape(),
        )),
    }
}

/// Split a recipient string into addresses, honouring quotes and angle
/// brackets: `"Zhang, Wei" <wei@example.com>` is one address, not two.
fn addresses_from_string(raw: &str) -> Result<Vec<String>, Response> {
    let mut addresses = Vec::new();
    for piece in split_addresses(raw) {
        addresses.push(validate_address(&piece)?);
    }
    Ok(addresses)
}

fn addresses_from_list(items: &[Value]) -> Result<Vec<String>, Response> {
    let mut addresses = Vec::new();
    for item in items {
        let Some(raw) = item.as_str() else {
            return Err(respond::error(
                StatusCode::BAD_REQUEST,
                "malformed-recipient",
            ));
        };
        addresses.extend(addresses_from_string(raw)?);
    }
    Ok(addresses)
}

/// Split on commas that are not inside quotes or angle brackets.
fn split_addresses(raw: &str) -> Vec<String> {
    let mut pieces = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;
    let mut angle_depth = 0i32;
    for ch in raw.chars() {
        match ch {
            '"' => {
                in_quotes = !in_quotes;
                current.push(ch);
            }
            '<' if !in_quotes => {
                angle_depth += 1;
                current.push(ch);
            }
            '>' if !in_quotes => {
                angle_depth = (angle_depth - 1).max(0);
                current.push(ch);
            }
            ',' if !in_quotes && angle_depth == 0 => {
                pieces.push(std::mem::take(&mut current));
            }
            _ => current.push(ch),
        }
    }
    pieces.push(current);
    pieces
        .into_iter()
        .map(|piece| piece.trim().to_owned())
        .filter(|piece| !piece.is_empty())
        .collect()
}

/// The routable address: the part inside `<...>` when there is one, the whole
/// piece otherwise. A display name is allowed; the address is what SMTP
/// needs.
fn validate_address(piece: &str) -> Result<String, Response> {
    let candidate = match (piece.rfind('<'), piece.rfind('>')) {
        (Some(open), Some(close)) if open < close => piece[open + 1..close].trim(),
        _ => piece.trim(),
    };
    let valid = !candidate.is_empty()
        && candidate.contains('@')
        && !candidate
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace() || ch == '<' || ch == '>');
    if !valid {
        return Err(respond::error(
            StatusCode::BAD_REQUEST,
            "malformed-recipient",
        ));
    }
    Ok(candidate.to_owned())
}

fn parse_attachments(items: &[Value]) -> Result<Vec<OutgoingAttachment>, Response> {
    let mut attachments = Vec::new();
    let mut total = 0usize;
    for item in items {
        let Some(object) = item.as_object() else {
            return Err(respond::error(
                StatusCode::BAD_REQUEST,
                "malformed-attachment",
            ));
        };
        let filename = object
            .get("filename")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mime_type = object
            .get("mimeType")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let data_base64 = object
            .get("dataBase64")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if filename.trim().is_empty()
            || mime_type.trim().is_empty()
            || filename.contains(['\r', '\n'])
            || mime_type.contains(['\r', '\n'])
        {
            return Err(respond::error(
                StatusCode::BAD_REQUEST,
                "malformed-attachment",
            ));
        }
        // A file that will not decode is refused whole: a mail with one
        // missing attachment is worse than no mail.
        let Ok(data) = base64::engine::general_purpose::STANDARD.decode(data_base64) else {
            return Err(respond::error(
                StatusCode::BAD_REQUEST,
                "malformed-attachment",
            ));
        };
        if data.len() > MAX_ATTACHMENT_BYTES {
            return Err(respond::error(
                StatusCode::PAYLOAD_TOO_LARGE,
                "attachment-too-large",
            ));
        }
        total += data.len();
        if total > MAX_TOTAL_ATTACHMENT_BYTES {
            return Err(respond::error(
                StatusCode::PAYLOAD_TOO_LARGE,
                "attachment-too-large",
            ));
        }
        attachments.push(OutgoingAttachment {
            filename: filename.to_owned(),
            mime_type: mime_type.to_owned(),
            data,
            inline: false,
        });
    }
    Ok(attachments)
}

// ---------------------------------------------------------------- delivery --

/// The whole send path, shared by the three routes.
async fn deliver(
    state: &AppState,
    account_id: Uuid,
    kind: SendKind,
    remote_id: Option<String>,
    request: SendRequest,
) -> Response {
    let account = match state
        .db
        .read(move |connection| store::accounts::find(connection, account_id))
        .await
    {
        Ok(Some(account)) => account,
        Ok(None) => return respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => return internal_error("send.accountReadFailed", error),
    };

    let original = match &remote_id {
        Some(remote_id) => {
            let lookup = remote_id.clone();
            let found = match state
                .db
                .read(move |connection| store::messages::find(connection, account_id, &lookup))
                .await
            {
                Ok(found) => found,
                Err(error) => return internal_error("send.messageReadFailed", error),
            };
            match found {
                Some(message) => Some(message),
                None => return respond::error(StatusCode::NOT_FOUND, "unknown-message"),
            }
        }
        None => None,
    };

    let (mail, subject, body_text) = match build_mail(kind, &request, original.as_ref()) {
        Ok(built) => built,
        Err(response) => return response,
    };

    // The sender is the account: the mailbox this server is authenticated as.
    let mut mail = mail;
    mail.from_email = account.email.clone();
    if kind == SendKind::Forward {
        let Some(remote_id) = remote_id.as_deref() else {
            return respond::error(StatusCode::BAD_REQUEST, "malformed-remoteId");
        };
        let original_message = original.as_ref();
        match fetch_original(state, account_id, remote_id, original_message).await {
            Ok(raw) => {
                mail.attachments.push(OutgoingAttachment {
                    filename: forward_filename(original_message),
                    mime_type: "message/rfc822".to_owned(),
                    data: raw,
                    inline: true,
                });
            }
            Err(response) => return response,
        }
    }

    let Some(send) = state.send_provider(account_id) else {
        return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
    };

    // One requestId, one delivery: the store decides who owns this send.
    let connection = match state.write_connection() {
        Ok(connection) => connection,
        Err(error) => return internal_error("send.writeOpenFailed", error),
    };
    let action_id = match &request.request_id {
        None => None,
        Some(request_id) => match write::claim_send(&connection, account_id, request_id) {
            Ok(write::SendClaim::Claimed(action_id)) => Some(action_id),
            Ok(write::SendClaim::Completed(provider_message_id)) => {
                return respond::json(
                    StatusCode::OK,
                    &SendResponse {
                        ok: true,
                        provider_message_id,
                    },
                )
            }
            Ok(write::SendClaim::InFlight) => {
                return respond::error(StatusCode::CONFLICT, "send-in-flight")
            }
            Ok(write::SendClaim::Failed(code)) => return failed_response(&code),
            Err(error) => return internal_error("send.claimFailed", error),
        },
    };

    let sent = match send.send(mail).await {
        Ok(sent) => sent,
        Err(error) => {
            let (status, code) = send_error(&error);
            if let Some(action_id) = action_id {
                let _ = write::fail_send(&connection, action_id, code);
            }
            return respond::error(status, code);
        }
    };

    // The mail is gone. A local write that fails afterwards must not turn the
    // answer into a failure the user would retry: that would send twice.
    if let Err(error) = store_sent_copy(
        state,
        account_id,
        &account.email,
        sent.provider_message_id.as_deref(),
        &subject,
        &body_text,
        &request,
    ) {
        tracing::error!(err = %error, "send.storeFailed: the message was delivered");
    }
    if let (Some(action_id), Some(provider_message_id)) =
        (action_id, sent.provider_message_id.as_deref())
    {
        // `remote_id` is the message this send answers (reply/forward), which
        // is what the "already replied" signal matches against the inbox row;
        // a brand-new mail answers nothing and passes None.
        if let Err(error) = write::complete_send(
            &connection,
            action_id,
            Some(provider_message_id),
            remote_id.as_deref(),
        ) {
            tracing::error!(err = %error, "send.auditFailed: the message was delivered");
        }
    }

    respond::json(
        StatusCode::OK,
        &SendResponse {
            ok: true,
            provider_message_id: sent.provider_message_id,
        },
    )
}

/// The outgoing message, the subject that goes with it and the body text the
/// sent copy stores.
fn build_mail(
    kind: SendKind,
    request: &SendRequest,
    original: Option<&StoredMessage>,
) -> Result<(OutgoingMail, String, String), Response> {
    let body = request.body.clone().unwrap_or_default();
    match kind {
        SendKind::Compose => {
            let to = request.to.clone().unwrap_or_default();
            if to.is_empty() {
                return Err(respond::error(
                    StatusCode::BAD_REQUEST,
                    "malformed-recipient",
                ));
            }
            let subject = request.subject.clone().unwrap_or_default();
            Ok((
                OutgoingMail {
                    to,
                    cc: request.cc.clone(),
                    bcc: request.bcc.clone(),
                    subject: subject.clone(),
                    body: body.clone(),
                    is_reply: false,
                    attachments: request.attachments.clone(),
                    ..OutgoingMail::default()
                },
                subject,
                body,
            ))
        }
        SendKind::Reply => {
            let Some(original) = original else {
                return Err(respond::error(StatusCode::NOT_FOUND, "unknown-message"));
            };
            let to = match &request.to {
                Some(to) if !to.is_empty() => to.clone(),
                _ => vec![original.from_address.clone()],
            };
            let subject = request
                .subject
                .clone()
                .unwrap_or_else(|| original.subject.clone().unwrap_or_default());
            let in_reply_to = original
                .message_id_header
                .clone()
                .filter(|value| !value.is_empty())
                .or_else(|| {
                    let remote_id = &original.remote_id;
                    (remote_id.starts_with('<') && remote_id.ends_with('>'))
                        .then(|| remote_id.clone())
                });
            let references = match (&original.references, &in_reply_to) {
                (Some(references), Some(in_reply_to)) => {
                    let references = references.trim();
                    if references.is_empty() {
                        Some(in_reply_to.clone())
                    } else if references.contains(in_reply_to) {
                        Some(references.to_owned())
                    } else {
                        Some(format!("{references} {in_reply_to}"))
                    }
                }
                (None, Some(in_reply_to)) => Some(in_reply_to.clone()),
                (Some(references), None) => Some(references.clone()),
                (None, None) => None,
            };
            Ok((
                OutgoingMail {
                    to,
                    cc: request.cc.clone(),
                    bcc: request.bcc.clone(),
                    subject: subject.clone(),
                    body: body.clone(),
                    in_reply_to,
                    references,
                    is_reply: true,
                    attachments: request.attachments.clone(),
                    ..OutgoingMail::default()
                },
                subject,
                body,
            ))
        }
        SendKind::Forward => {
            let Some(original) = original else {
                return Err(respond::error(StatusCode::NOT_FOUND, "unknown-message"));
            };
            let to = request.to.clone().unwrap_or_default();
            if to.is_empty() {
                return Err(respond::error(
                    StatusCode::BAD_REQUEST,
                    "malformed-recipient",
                ));
            }
            // A forwarded mail IS the attachment. A second file would make two
            // different things out of one message, and v3 refused it too.
            if !request.attachments.is_empty() {
                return Err(respond::error(StatusCode::BAD_REQUEST, "malformed-forward"));
            }
            let subject = request.subject.clone().unwrap_or_else(|| {
                let original = original.subject.clone().unwrap_or_default();
                if original.trim().is_empty() {
                    "Fwd:".to_owned()
                } else if original.to_ascii_lowercase().starts_with("fwd:") {
                    original
                } else {
                    format!("Fwd: {original}")
                }
            });
            Ok((
                OutgoingMail {
                    to,
                    cc: request.cc.clone(),
                    bcc: request.bcc.clone(),
                    subject: subject.clone(),
                    body: body.clone(),
                    is_reply: false,
                    ..OutgoingMail::default()
                },
                subject,
                body,
            ))
        }
    }
}

/// The original's bytes, for the forwarded `message/rfc822` part.
async fn fetch_original(
    state: &AppState,
    account_id: Uuid,
    remote_id: &str,
    _original: Option<&StoredMessage>,
) -> Result<Vec<u8>, Response> {
    let Some(provider) = state.body_provider(account_id) else {
        return Err(respond::error(
            StatusCode::SERVICE_UNAVAILABLE,
            "provider-not-configured",
        ));
    };
    // The UID the store recorded is only a hint: the provider verifies the
    // Message-ID and falls back to resolving by identity.
    let hint_remote_id = remote_id.to_owned();
    let uid_hint = state
        .db
        .read(move |connection| {
            store::messages::inbox_remote_uid(connection, account_id, &hint_remote_id)
        })
        .await
        .ok()
        .flatten();
    match provider.fetch_raw(remote_id, uid_hint).await {
        Ok(raw) => {
            if raw.len() > MAX_ATTACHMENT_BYTES {
                return Err(respond::error(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "attachment-too-large",
                ));
            }
            Ok(raw)
        }
        Err(ProviderError::MessageGone) => Err(respond::error(StatusCode::GONE, "message-gone")),
        Err(ProviderError::AuthFailed) => {
            Err(respond::error(StatusCode::UNAUTHORIZED, "smtp-auth-failed"))
        }
        Err(_) => Err(respond::error(
            StatusCode::BAD_GATEWAY,
            "forward-original-unavailable",
        )),
    }
}

fn forward_filename(original: Option<&StoredMessage>) -> String {
    let subject = original
        .and_then(|message| message.subject.clone())
        .unwrap_or_default();
    let stem: String = subject
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .take(60)
        .collect();
    if stem.is_empty() {
        "forwarded.eml".to_owned()
    } else {
        format!("{stem}.eml")
    }
}

/// Store the sent copy: the header the sent list shows and the body it opens.
fn store_sent_copy(
    state: &AppState,
    account_id: Uuid,
    from_email: &str,
    provider_message_id: Option<&str>,
    subject: &str,
    body: &str,
    request: &SendRequest,
) -> Result<(), StoreError> {
    let remote_id = match provider_message_id {
        Some(message_id) => message_id.to_owned(),
        None => format!("sent:{}", Uuid::new_v4().to_wire_string()),
    };
    let connection = state.write_connection().map_err(|error| {
        StoreError::Sqlite(rusqlite::Error::ToSqlConversionFailure(Box::new(error)))
    })?;
    let snippet: String = body.chars().take(SNIPPET_CHARS).collect();
    let received_at = crate::timefmt::to_stored(crate::timefmt::now());
    let header = write::NewHeader {
        id: Uuid::new_v4(),
        account_id,
        remote_id: &remote_id,
        thread_id: &remote_id,
        from_address: from_email,
        from_name: None,
        subject: Some(subject),
        snippet: Some(&snippet),
        received_at: &received_at,
        list_unsubscribe: false,
        message_id_header: provider_message_id,
        in_reply_to: None,
        references: None,
        unsubscribe_links: "[]",
        remote_uid: None,
    };
    let to_json = serde_json::to_string(request.to.as_deref().unwrap_or(&[]))
        .unwrap_or_else(|_| "[]".to_owned());
    let cc_json = serde_json::to_string(&request.cc).unwrap_or_else(|_| "[]".to_owned());
    let body_row = write::NewBody {
        account_id,
        remote_id: &remote_id,
        text: body,
        html: None,
        has_more: false,
        attachments: "[]",
        to_addresses: &to_json,
        cc_addresses: &cc_json,
    };
    write::save_sent_message(&connection, &header, &body_row, state.body_key.as_ref()).map_err(
        |error| StoreError::Sqlite(rusqlite::Error::ToSqlConversionFailure(Box::new(error))),
    )
}

/// The HTTP shape of a provider failure. The code is the contract's, and it
/// is also what a replay of the same requestId answers with.
fn send_error(error: &ProviderError) -> (StatusCode, &'static str) {
    match error {
        ProviderError::AuthFailed => (StatusCode::UNAUTHORIZED, "smtp-auth-failed"),
        ProviderError::MessageGone => (StatusCode::GONE, "message-gone"),
        ProviderError::NotConfigured(_) => {
            (StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured")
        }
        // A part that is not in the message and a body that is too big are
        // facts about the mail, not delivery failures. SMTP never sees them.
        ProviderError::NotFound(_) => (StatusCode::NOT_FOUND, "attachment-not-found"),
        ProviderError::TooLarge(_) => (StatusCode::PAYLOAD_TOO_LARGE, "attachment-too-large"),
        ProviderError::Unreachable(_) | ProviderError::Protocol(_) => {
            (StatusCode::BAD_GATEWAY, "smtp-send-failed")
        }
    }
}

/// A replay of a send that already failed answers the same thing.
fn failed_response(code: &str) -> Response {
    let (status, code) = match code {
        "smtp-auth-failed" => (StatusCode::UNAUTHORIZED, "smtp-auth-failed"),
        "message-gone" => (StatusCode::GONE, "message-gone"),
        "provider-not-configured" => (StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured"),
        _ => (StatusCode::BAD_GATEWAY, "smtp-send-failed"),
    };
    respond::error(status, code)
}

fn account_id_param(uri: &axum::http::Uri) -> Option<Uuid> {
    let params = query::parse(uri);
    params
        .iter()
        .find(|(name, _)| name == "accountId")
        .and_then(|(_, value)| Uuid::parse_strict(value.trim()))
}
