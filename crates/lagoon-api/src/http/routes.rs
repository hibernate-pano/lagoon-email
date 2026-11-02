//! The five R1 endpoints.
//!
//! Each handler answers exactly the status codes `recon/server-contract.md` §3
//! lists for its route, including the ones that look wrong but are v3's:
//!
//! * `GET /api/messages` never checks that the account exists - an unknown but
//!   well-formed id gets 200 with an empty list (`m1-checklist.md` §1).
//! * `GET /api/folder-counts` **does** check, so the same id gets 404
//!   `unknown-account`.
//! * `GET /api/messages/{remoteId}/body` checks the account first (404), then
//!   needs a provider for a cache miss (503).

use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::{StatusCode, Uri};
use axum::response::Response;

use crate::provider::{MailBody, ProviderError};
use crate::store::{self, messages::MessageFilter, StoreError};
use crate::timefmt;
use crate::uuid::Uuid;
use crate::wire;

use super::query;
use super::respond;
use super::AppState;

/// v3 `SyncRoutes.maxListRows`: a ceiling, not a page size, so one conversation
/// is never split across two responses.
const MAX_LIST_ROWS: i64 = 1000;

const DEFAULT_LIST_ROWS: i64 = 500;

/// `GET /healthz` - pure text `ok`, the only ungated path.
pub async fn healthz() -> Response {
    respond::text(StatusCode::OK, "ok")
}

/// `GET /api/accounts` - `ConnectedAccount[]` sorted by email.
pub async fn accounts(State(state): State<AppState>) -> Response {
    let outcome = state
        .db
        .read(
            move |connection| -> Result<Vec<wire::ConnectedAccount>, StoreError> {
                let accounts = store::accounts::all(connection)?;
                Ok::<_, StoreError>(
                    accounts
                        .into_iter()
                        .map(|account| {
                            // v3: a count failure must not break the whole
                            // directory, so it degrades to 0.
                            let unread =
                                store::messages::unread_count(connection, account.id).unwrap_or(0);
                            wire::ConnectedAccount {
                                id: account.id,
                                provider: account.provider,
                                email: account.email,
                                is_active: account.is_active,
                                unread_count: unread,
                                sync_health: wire::SyncHealth {
                                    status: wire::SyncHealth::status_or_ok(&account.sync_status),
                                    last_sync_at: account.last_sync_at,
                                    last_error: account.last_sync_error,
                                },
                                capabilities: account.capabilities,
                            }
                        })
                        .collect::<Vec<_>>(),
                )
            },
        )
        .await;

    match outcome {
        Ok(accounts) => respond::json(StatusCode::OK, &accounts),
        Err(error) => {
            tracing::error!(err = %error, "accounts.listFailed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

/// `GET /api/messages?accountId=...` - the list, its lenses and its total.
pub async fn messages(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = query::get(&params, "accountId").and_then(Uuid::parse_strict) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };

    // v3: `max(1, min(Int(...) ?? 500, 1000))` - an unparseable limit is the
    // default, not an error.
    let limit = query::get(&params, "limit")
        .and_then(|raw| raw.parse::<i64>().ok())
        .unwrap_or(DEFAULT_LIST_ROWS)
        .clamp(1, MAX_LIST_ROWS);

    let mut filter = MessageFilter::inbox(account_id);
    filter.sender = query::get(&params, "sender")
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    filter.archived = query::get(&params, "archived") == Some("true");
    filter.deleted = query::get(&params, "deleted") == Some("true");
    filter.pinned = query::get(&params, "pinned") == Some("true");
    filter.unread = query::get(&params, "unread") == Some("true");
    // A `stackId` that is not a UUID is ignored, not rejected - v3 wraps the
    // lookup in `if let raw = ..., let ruleId = UUID(uuidString: raw)`.
    let stack_rule_id = query::get(&params, "stackId").and_then(Uuid::parse_strict);

    let outcome = state
        .db
        .read(move |connection| -> Result<ListOutcome, StoreError> {
            if let Some(rule_id) = stack_rule_id {
                match store::messages::find_stack_rule(connection, rule_id, account_id)? {
                    Some(rule) => filter.stack = Some(rule),
                    None => return Ok(ListOutcome::UnknownStack),
                }
            }
            let messages = store::messages::recent(connection, &filter, limit)?;
            let total_unread = store::messages::unread_count(connection, account_id)?;
            let total = store::messages::count(connection, &filter)?;
            Ok(ListOutcome::List {
                messages,
                total_unread,
                total,
            })
        })
        .await;

    match outcome {
        Ok(ListOutcome::UnknownStack) => respond::error(StatusCode::NOT_FOUND, "unknown-stack"),
        Ok(ListOutcome::List {
            messages,
            total_unread,
            total,
        }) => {
            let body_key = Arc::clone(&state.body_key);
            let headers: Vec<wire::MessageHeader> = messages
                .into_iter()
                .map(|message| to_wire_header(&body_key, message))
                .collect();
            respond::json(
                StatusCode::OK,
                &wire::SyncResponse {
                    cursor: wire::SyncCursor {
                        account_id,
                        last_fetched_at: timefmt::now(),
                        total_unread,
                    },
                    messages: headers,
                    total_count: total,
                },
            )
        }
        Err(error) => {
            // v3 logs this one: the list view polls every 30s, and before the
            // log line a store failure was completely invisible.
            tracing::error!(accountId = %account_id, err = %error, "messages.listFailed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

/// `GET /api/folder-counts?accountId=...` - the six sidebar tallies.
pub async fn folder_counts(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = query::get(&params, "accountId").and_then(Uuid::parse_strict) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };

    let outcome = state
        .db
        .read(
            move |connection| -> Result<FolderCountsOutcome, StoreError> {
                if !store::accounts::exists(connection, account_id)? {
                    return Ok(FolderCountsOutcome::UnknownAccount);
                }
                Ok(FolderCountsOutcome::Counts(
                    store::messages::FolderTallies {
                        live: store::messages::live_count(connection, account_id)?,
                        unread: store::messages::unread_count(connection, account_id)?,
                        archived: store::messages::archived_count(connection, account_id)?,
                        pinned: store::messages::pinned_count(connection, account_id)?,
                        deleted: store::messages::deleted_count(connection, account_id)?,
                        sent: store::messages::sent_count(connection, account_id)?,
                    },
                ))
            },
        )
        .await;

    match outcome {
        Ok(FolderCountsOutcome::UnknownAccount) => {
            respond::error(StatusCode::NOT_FOUND, "unknown-account")
        }
        Ok(FolderCountsOutcome::Counts(tallies)) => respond::json(
            StatusCode::OK,
            &wire::FolderCountsResponse::new(
                tallies.live,
                tallies.unread,
                tallies.archived,
                tallies.pinned,
                tallies.deleted,
                tallies.sent,
            ),
        ),
        Err(error) => {
            tracing::error!(accountId = %account_id, err = %error, "folder-counts.error");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

/// `GET /api/messages/{remoteId}/body?accountId=...` - the cached body.
pub async fn message_body(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    uri: Uri,
) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = query::get(&params, "accountId").and_then(Uuid::parse_strict) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    if remote_id.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-remoteId");
    }

    let body_key = Arc::clone(&state.body_key);
    // The closure owns its copy: the handler still needs `remote_id` for the
    // failure log line below.
    let remote_id_for_read = remote_id.clone();
    let outcome = state
        .db
        .read(move |connection| -> Result<BodyOutcome, StoreError> {
            if !store::accounts::exists(connection, account_id)? {
                return Ok(BodyOutcome::UnknownAccount);
            }
            let header = store::messages::find(connection, account_id, &remote_id_for_read)?;
            let Some(stored) = store::bodies::find(connection, account_id, &remote_id_for_read)?
            else {
                return Ok(BodyOutcome::CacheMiss);
            };
            // A value that will not open is a cache miss, not an error: v3's
            // `try? await BodyStore.get(...)` swallows the throw and falls
            // through to the provider.
            let Ok(text) = body_key.open(&stored.text_cipher) else {
                return Ok(BodyOutcome::CacheMiss);
            };
            let html = match stored.html_cipher.as_deref() {
                Some(cipher) => match body_key.open(cipher) {
                    Ok(html) => Some(html),
                    Err(_) => return Ok(BodyOutcome::CacheMiss),
                },
                None => None,
            };
            Ok(BodyOutcome::Found(wire::MessageBody {
                remote_id: remote_id_for_read.clone(),
                subject: header.as_ref().and_then(|row| row.subject.clone()),
                from_address: header
                    .as_ref()
                    .map(|row| row.from_address.clone())
                    .unwrap_or_default(),
                from_name: header.as_ref().and_then(|row| row.from_name.clone()),
                to_address: None,
                received_at: header
                    .as_ref()
                    .map(|row| row.received_at)
                    .unwrap_or_else(timefmt::now),
                text,
                html,
                attachments: stored.attachments,
                has_more: stored.has_more,
                to: stored.to,
                cc: stored.cc,
            }))
        })
        .await;

    match outcome {
        Ok(BodyOutcome::Found(body)) => respond::json(StatusCode::OK, &body),
        Ok(BodyOutcome::CacheMiss) => fetch_and_answer(&state, account_id, &remote_id).await,
        Ok(BodyOutcome::UnknownAccount) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => {
            tracing::error!(accountId = %account_id, remoteId = %remote_id, err = %error, "body.readFailed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

/// The cold path: fetch the body from the mailbox, cache it, answer.
///
/// v3 `MessageRoutes.fetchBody`: a persisted body is never stale, so the cache
/// is the fast path and this runs at most once per message. Persisting is
/// best-effort - a store failure must not fail the read the user is looking at
/// - and the header row is metadata only: a message the sync loop never listed
///   still yields its body text.
async fn fetch_and_answer(state: &AppState, account_id: Uuid, remote_id: &str) -> Response {
    let Some(provider) = state.body_provider(account_id) else {
        return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
    };
    // The UID sync recorded for this row lets the provider fetch the body
    // directly; without it the 419-message QQ mailbox measured 2.2s per open
    // because the Message-ID search comes back empty and the provider falls
    // back to scanning every UID. Best effort: a miss just means the provider
    // resolves by identity, which is what it did before the column existed.
    let remote_id_for_uid = remote_id.to_owned();
    let uid_hint = state
        .db
        .read(move |connection| {
            store::messages::inbox_remote_uid(connection, account_id, &remote_id_for_uid)
        })
        .await
        .ok()
        .flatten();
    let fetched = match provider.fetch_body(remote_id, uid_hint).await {
        Ok(body) => body,
        Err(ProviderError::AuthFailed) => {
            tracing::error!(accountId = %account_id, remoteId = %remote_id, "body.authFailed");
            return respond::error(StatusCode::UNAUTHORIZED, "provider-auth-failed");
        }
        Err(ProviderError::NotConfigured(reason)) => {
            tracing::error!(accountId = %account_id, remoteId = %remote_id, reason = %reason, "body.notConfigured");
            return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
        }
        // A deleted message is not an outage: the contract promises 410, and
        // the reader has copy for exactly this code.
        Err(ProviderError::MessageGone) => {
            tracing::info!(accountId = %account_id, remoteId = %remote_id, "body.gone");
            return respond::error(StatusCode::GONE, "message-gone");
        }
        Err(error) => {
            tracing::error!(accountId = %account_id, remoteId = %remote_id, err = %error, "body.fetchFailed");
            return respond::error(StatusCode::BAD_GATEWAY, "provider-unreachable");
        }
    };

    persist_body(state, account_id, remote_id, &fetched).await;

    // Metadata comes from the synced row, best effort: v3 answers the body
    // even when the row has since been reconciled away.
    let remote_id_for_header = remote_id.to_owned();
    let header = state
        .db
        .read(move |connection| {
            store::messages::find(connection, account_id, &remote_id_for_header)
        })
        .await
        .ok()
        .flatten();

    respond::json(
        StatusCode::OK,
        &wire::MessageBody {
            remote_id: remote_id.to_owned(),
            subject: header.as_ref().and_then(|row| row.subject.clone()),
            from_address: header
                .as_ref()
                .map(|row| row.from_address.clone())
                .unwrap_or_default(),
            from_name: header.as_ref().and_then(|row| row.from_name.clone()),
            to_address: None,
            received_at: header
                .as_ref()
                .map(|row| row.received_at)
                .unwrap_or_else(timefmt::now),
            text: fetched.text,
            html: fetched.html,
            attachments: fetched.attachments,
            has_more: fetched.has_more,
            to: fetched.to,
            cc: fetched.cc,
        },
    )
}

/// Write-through, best effort (v3 `body.persistFailed` / `body.persistSkipped`).
async fn persist_body(state: &AppState, account_id: Uuid, remote_id: &str, body: &MailBody) {
    let Ok(attachments) = serde_json::to_string(&body.attachments) else {
        return;
    };
    let to = serde_json::to_string(&body.to).unwrap_or_else(|_| "[]".to_owned());
    let cc = serde_json::to_string(&body.cc).unwrap_or_else(|_| "[]".to_owned());
    let connection = match state.write_connection() {
        Ok(connection) => connection,
        Err(error) => {
            tracing::warn!(accountId = %account_id, remoteId = %remote_id, err = %error, "body.persistFailed");
            return;
        }
    };
    let new_body = store::write::NewBody {
        account_id,
        remote_id,
        text: &body.text,
        html: body.html.as_deref(),
        has_more: body.has_more,
        attachments: &attachments,
        to_addresses: &to,
        cc_addresses: &cc,
    };
    if let Err(error) = store::write::save_body(&connection, &new_body, &state.body_key) {
        // Most often this is the `message_headers` foreign key: a body for a
        // message the sync loop never listed is simply not cacheable.
        tracing::warn!(accountId = %account_id, remoteId = %remote_id, err = %error, "body.persistFailed");
    }
}

/// Anything the router does not know: Hummingbird's bare 404 - empty body, no
/// JSON envelope. `m1-checklist.md` §1 pins this, because a client that reads
/// the envelope would render "协议错误" as a business error.
pub async fn not_found() -> StatusCode {
    StatusCode::NOT_FOUND
}

enum ListOutcome {
    List {
        messages: Vec<store::messages::StoredMessage>,
        total_unread: i64,
        total: i64,
    },
    UnknownStack,
}

enum FolderCountsOutcome {
    Counts(store::messages::FolderTallies),
    UnknownAccount,
}

// 256 bytes once per body read; boxing would add an allocation to save stack
// space that is not scarce here.
#[allow(clippy::large_enum_variant)]
enum BodyOutcome {
    Found(wire::MessageBody),
    /// No stored body, or a stored value that will not open.
    CacheMiss,
    UnknownAccount,
}

/// Map a stored header to the wire shape, decrypting the preview.
///
/// Shared with the R2 routes so the list, the briefing feed and search cannot
/// disagree about which fields exist.
pub(crate) fn to_wire_header(
    body_key: &crate::crypto::BodyKey,
    message: store::messages::StoredMessage,
) -> wire::MessageHeader {
    wire::MessageHeader {
        id: message.id,
        account_id: message.account_id,
        remote_id: message.remote_id,
        thread_id: message.thread_id,
        from_address: message.from_address,
        from_name: message.from_name,
        subject: message.subject,
        // v3 `MessageStore.openSnippet`: the preview is cosmetic, so a value
        // that will not open answers `nil` instead of failing the list.
        snippet: message
            .snippet_cipher
            .as_deref()
            .filter(|cipher| !cipher.is_empty())
            .and_then(|cipher| body_key.open(cipher).ok()),
        received_at: message.received_at,
        is_read: message.is_read,
        is_archived: message.is_archived,
        is_deleted: message.is_deleted,
        is_pinned: message.is_pinned,
        is_sent: message.is_sent,
        message_id_header: message.message_id_header,
        in_reply_to: message.in_reply_to,
        references: message.references,
    }
}
