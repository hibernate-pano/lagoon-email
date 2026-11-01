//! R3.5a: the write paths - message actions, bulk, audit and undo.
//!
//! Ordering rules carried over from v3, each one load-bearing:
//! * capability gates run BEFORE any write, so a 409 leaves remote and local
//!   state untouched;
//! * archive/trash/restore run REMOTE first, then flip the local flag - a
//!   local success must not hide a failed remote write;
//! * mark-read flips LOCAL first and treats the remote STORE as best-effort
//!   (v3 logs a failed STORE and still answers) - the local flag is the
//!   source of truth for the triage state;
//! * undo claims single-use inside one transaction: find -> expired? ->
//!   already-undone? -> undo row, and the claim is retracted when the
//!   inverse write fails (a failed undo must not read as done);
//! * pin is local-only and always audited; purge is never undoable.
//!
//! The sync engine never sees this file: the write verbs live on
//! MailWriteProvider, a trait MailProvider does not have.

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::Response;
use serde::Deserialize;
use serde_json::json;

use crate::provider::{MailWriteProvider, ProviderError};
use crate::store::{self, write, StoreError};
use crate::token::ImapCredentials;
use crate::uuid::Uuid;
use crate::wire::MailCapabilities;

use super::respond;
use super::AppState;

fn map_write_error(error: write::WriteError) -> StoreError {
    match error {
        write::WriteError::Sqlite(error) => StoreError::Sqlite(error),
        other => StoreError::Sqlite(rusqlite::Error::ToSqlConversionFailure(Box::new(other))),
    }
}

fn capability_allowed(value: Option<bool>) -> bool {
    // Tri-state: None means "never negotiated" and reads as allowed; only a
    // settled false closes the gate. The server still answers 409 when the
    // folder is really missing (MailCapabilities.swift:121-156).
    value != Some(false)
}

/// The stored credentials, opened with the token key. A missing token key or
/// an undecryptable blob is the 503 path (v3 makeProvider returning nil).
fn write_provider(
    state: &AppState,
    connection: &rusqlite::Connection,
    account_id: Uuid,
) -> Result<Option<Arc<dyn MailWriteProvider>>, Response> {
    let Some(token_key) = state.token_key.as_ref() else {
        return Ok(None);
    };
    let blob = match write::credentials(connection, account_id) {
        Ok(blob) => blob,
        Err(error) => {
            tracing::error!(err = %error, "actions.credentialReadFailed");
            return Err(respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error"));
        }
    };
    let Some(blob) = blob else {
        return Ok(None);
    };
    let credentials = match ImapCredentials::open(token_key, &blob) {
        Ok(credentials) => credentials,
        Err(_) => return Ok(None),
    };
    Ok(state.provider_factory.make_write(&credentials))
}

struct ActionContext {
    account_id: Uuid,
    connection: rusqlite::Connection,
    capabilities: MailCapabilities,
    write: Option<Arc<dyn MailWriteProvider>>,
}

/// Load the account, its capabilities and its write provider, or answer the
/// error v3 would answer. Shared by every action route.
async fn action_context(state: &AppState, account_id: Uuid) -> Result<ActionContext, Response> {
    let account = {
        let outcome = state
            .db
            .read(move |connection| store::accounts::find(connection, account_id))
            .await;
        match outcome {
            Ok(Some(account)) => account,
            _ => {
                return Err(respond::error(StatusCode::NOT_FOUND, "unknown-account"));
            }
        }
    };
    let connection = match state.write_connection() {
        Ok(connection) => connection,
        Err(error) => {
            tracing::error!(err = %error, "actions.writeOpenFailed");
            return Err(respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error"));
        }
    };
    let write = write_provider(state, &connection, account_id)?;
    Ok(ActionContext { account_id, connection, capabilities: account.capabilities, write })
}

#[derive(Debug, Clone, Copy)]
enum WriteVerb {
    Archive,
    Unarchive,
    Trash,
    Restore,
    PermanentDelete,
    SetRead(bool),
    SetPinned(bool),
    EmptyTrash,
}

impl WriteVerb {
    fn gate(&self, capabilities: &MailCapabilities) -> Option<(StatusCode, &'static str)> {
        match self {
            WriteVerb::Archive | WriteVerb::Unarchive
                if !capability_allowed(capabilities.archive_folder) =>
            {
                Some((StatusCode::CONFLICT, "archive-unavailable"))
            }
            WriteVerb::Trash | WriteVerb::Restore
                if !capability_allowed(capabilities.trash_folder) =>
            {
                Some((StatusCode::CONFLICT, "delete-unavailable"))
            }
            WriteVerb::PermanentDelete | WriteVerb::EmptyTrash
                if !capability_allowed(capabilities.uidplus) =>
            {
                Some((StatusCode::CONFLICT, "uidplus-missing"))
            }
            _ => None,
        }
    }

    fn audit_kind(&self) -> Option<&'static str> {
        match self {
            WriteVerb::Archive | WriteVerb::Unarchive => Some("archive"),
            WriteVerb::Trash | WriteVerb::Restore => Some("delete"),
            WriteVerb::SetRead(_) => Some("markRead"),
            // pin/unpin audit as their own kinds at the call site; the undo
            // row is written by the undo route itself.
            WriteVerb::SetPinned(_) | WriteVerb::PermanentDelete | WriteVerb::EmptyTrash => None,
        }
    }

    fn audit_payload(
        &self,
        remote_id: &str,
        remote_write: bool,
        previous_is_read: Option<bool>,
    ) -> String {
        // v3's payload is [String: String] - the undo compares
        // payload["remoteWrite"] == "true", so a JSON bool would never match.
        let mut payload = json!({
            "remoteId": remote_id,
            "remoteWrite": remote_write.to_string(),
        });
        if let (WriteVerb::SetRead(_), Some(previous)) = (self, previous_is_read) {
            payload["previousIsRead"] = json!(previous.to_string());
        }
        payload.to_string()
    }

    /// Whether the inverse of this verb must go back over the wire.
    fn touches_remote(&self) -> bool {
        !matches!(self, WriteVerb::SetPinned(_))
    }

    async fn remote(
        &self,
        provider: &dyn MailWriteProvider,
        remote_id: &str,
    ) -> Result<(), ProviderError> {
        match self {
            WriteVerb::Archive => provider.archive(remote_id).await,
            WriteVerb::Unarchive => provider.unarchive(remote_id).await,
            WriteVerb::Trash => provider.trash(remote_id).await,
            WriteVerb::Restore => provider.restore_from_trash(remote_id).await,
            WriteVerb::PermanentDelete => provider.permanently_delete(remote_id).await,
            WriteVerb::SetRead(is_read) => provider.set_read(remote_id, *is_read).await,
            WriteVerb::SetPinned(_) | WriteVerb::EmptyTrash => Ok(()),
        }
    }

    fn local(
        &self,
        connection: &rusqlite::Connection,
        account_id: Uuid,
        remote_id: &str,
    ) -> Result<Option<bool>, write::WriteError> {
        match self {
            WriteVerb::Archive => {
                write::set_archived(connection, account_id, remote_id, true).map(|_| None)
            }
            WriteVerb::Unarchive => {
                write::set_archived(connection, account_id, remote_id, false).map(|_| None)
            }
            WriteVerb::Trash => {
                write::set_deleted(connection, account_id, remote_id, true).map(|_| None)
            }
            WriteVerb::Restore => {
                write::set_deleted(connection, account_id, remote_id, false).map(|_| None)
            }
            WriteVerb::SetRead(is_read) => {
                write::set_read_flag(connection, account_id, remote_id, *is_read)
            }
            WriteVerb::SetPinned(pinned) => {
                write::set_pinned(connection, account_id, remote_id, *pinned).map(|_| None)
            }
            WriteVerb::PermanentDelete => {
                write::delete_message_row(connection, account_id, remote_id).map(|_| None)
            }
            WriteVerb::EmptyTrash => Ok(None),
        }
    }

    /// The verb that undoes this one.
    fn inverse(self) -> WriteVerb {
        match self {
            WriteVerb::Archive => WriteVerb::Unarchive,
            WriteVerb::Unarchive => WriteVerb::Archive,
            WriteVerb::Trash => WriteVerb::Restore,
            WriteVerb::Restore => WriteVerb::Trash,
            WriteVerb::SetRead(is_read) => WriteVerb::SetRead(!is_read),
            WriteVerb::SetPinned(pinned) => WriteVerb::SetPinned(!pinned),
            other => other,
        }
    }
}

fn provider_error_response(error: ProviderError, remote_id: &str) -> Response {
    let label = error.to_string();
    tracing::warn!(remoteId = %remote_id, label = %label, "actions.remoteFailed");
    match error {
        ProviderError::AuthFailed => respond::error(StatusCode::UNAUTHORIZED, "imap-auth-failed"),
        ProviderError::NotConfigured(_) => {
            respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured")
        }
        _ => respond::error(StatusCode::BAD_GATEWAY, "provider-unreachable"),
    }
}

async fn run_message_action(
    state: AppState,
    account_id: Uuid,
    remote_id: String,
    verb: WriteVerb,
) -> Response {
    let context = match action_context(&state, account_id).await {
        Ok(context) => context,
        Err(response) => return response,
    };
    if let Some((status, code)) = verb.gate(&context.capabilities) {
        return respond::error(status, code);
    }
    let Some(write) = context.write.as_ref() else {
        return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
    };
    if verb.touches_remote() {
        if let Err(error) = verb.remote(write.as_ref(), &remote_id).await {
            return provider_error_response(error, &remote_id);
        }
    }
    let action_id: Option<i64>;
    match verb.local(&context.connection, context.account_id, &remote_id) {
        Ok(previous) => {
            let payload = verb.audit_payload(&remote_id, verb.touches_remote(), previous);
            action_id = match verb.audit_kind() {
                Some(kind) => {
                    match write::record_action(&context.connection, context.account_id, kind, &payload)
                    {
                        Ok(id) => Some(id),
                        Err(error) => {
                            tracing::error!(err = %error, "actions.auditFailed");
                            return respond::error(
                                StatusCode::INTERNAL_SERVER_ERROR,
                                "internal-error",
                            );
                        }
                    }
                }
                None => None,
            };
        }
        Err(error) => {
            tracing::error!(err = %error, "actions.localFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    }
    respond::json(
        StatusCode::OK,
        &json!({ "ok": true, "remoteId": remote_id, "remote": true, "actionId": action_id }),
    )
}

#[derive(Debug, Deserialize)]
pub struct AccountQuery {
    #[serde(rename = "accountId")]
    account_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UndoParams {
    #[serde(rename = "accountId")]
    account_id: Option<String>,
}

fn query_account_id(account_id: Option<&str>) -> Result<Uuid, Response> {
    account_id
        .and_then(Uuid::parse_strict)
        .ok_or_else(|| respond::error(StatusCode::BAD_REQUEST, "malformed-accountId"))
}

macro_rules! message_action_route {
    ($name:ident, $verb:expr) => {
        pub async fn $name(
            State(state): State<AppState>,
            Path(remote_id): Path<String>,
            Query(params): Query<AccountQuery>,
        ) -> Response {
            let account_id = match query_account_id(params.account_id.as_deref()) {
                Ok(account_id) => account_id,
                Err(response) => return response,
            };
            run_message_action(state, account_id, remote_id, $verb).await
        }
    };
}

message_action_route!(archive, WriteVerb::Archive);
message_action_route!(unarchive, WriteVerb::Unarchive);
message_action_route!(delete, WriteVerb::Trash);
message_action_route!(restore, WriteVerb::Restore);
message_action_route!(purge, WriteVerb::PermanentDelete);

#[derive(Debug, Deserialize)]
pub struct ReadParams {
    #[serde(rename = "accountId")]
    account_id: Option<String>,
    #[serde(rename = "isRead")]
    is_read: Option<bool>,
    record: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct PinParams {
    #[serde(rename = "accountId")]
    account_id: Option<String>,
    pinned: Option<bool>,
}

/// POST /api/messages/{remoteId}/read - local first, remote STORE best-effort.
pub async fn mark_read(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    Query(params): Query<ReadParams>,
) -> Response {
    let account_id = match query_account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let is_read = params.is_read.unwrap_or(true);
    let record = params.record.unwrap_or(false);
    let context = match action_context(&state, account_id).await {
        Ok(context) => context,
        Err(response) => return response,
    };
    let action_id: Option<i64>;
    match WriteVerb::SetRead(is_read).local(&context.connection, account_id, &remote_id) {
        Ok(previous) => {
            action_id = if record && previous.is_some() {
                let payload =
                    WriteVerb::SetRead(is_read).audit_payload(&remote_id, true, previous);
                match write::record_action(&context.connection, account_id, "markRead", &payload) {
                    Ok(id) => Some(id),
                    Err(error) => {
                        tracing::error!(err = %error, "read.auditFailed");
                        return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
                    }
                }
            } else {
                None
            };
        }
        Err(error) => {
            tracing::error!(err = %error, "read.localFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    }
    if let Some(write) = context.write.as_ref() {
        if let Err(error) = write.set_read(&remote_id, is_read).await {
            // Best-effort by contract: a failed STORE is logged, never surfaced.
            tracing::warn!(remoteId = %remote_id, label = %error, "read.remoteFailed");
        }
    }
    match action_id {
        None => respond::empty(StatusCode::NO_CONTENT),
        Some(action_id) => respond::json(
            StatusCode::OK,
            &json!({ "ok": true, "remoteId": remote_id, "actionId": action_id }),
        ),
    }
}

/// POST /api/messages/{remoteId}/pin - local only, always audited.
pub async fn pin(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    Query(params): Query<PinParams>,
) -> Response {
    let account_id = match query_account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let Some(pinned) = params.pinned else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-pinned");
    };
    let context = match action_context(&state, account_id).await {
        Ok(context) => context,
        Err(response) => return response,
    };
    let action_id =
        match write::set_pinned(&context.connection, account_id, &remote_id, pinned) {
            Ok(_) => match write::record_action(
                &context.connection,
                account_id,
                if pinned { "pin" } else { "unpin" },
                &json!({ "remoteId": remote_id }).to_string(),
            ) {
                Ok(id) => id,
                Err(error) => {
                    tracing::error!(err = %error, "pin.auditFailed");
                    return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
                }
            },
            Err(error) => {
                tracing::error!(err = %error, "pin.failed");
                return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
            }
        };
    respond::json(
        StatusCode::OK,
        &json!({ "ok": true, "remoteId": remote_id, "actionId": action_id }),
    )
}

/// POST /api/trash/empty - EXPUNGE every trashed message (UIDPLUS gate).
pub async fn empty_trash(
    State(state): State<AppState>,
    Query(params): Query<AccountQuery>,
) -> Response {
    let account_id = match query_account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let context = match action_context(&state, account_id).await {
        Ok(context) => context,
        Err(response) => return response,
    };
    if let Some((status, code)) = WriteVerb::EmptyTrash.gate(&context.capabilities) {
        return respond::error(status, code);
    }
    let purged = match write::trashed_count(&context.connection, account_id) {
        Ok(count) => count,
        Err(error) => {
            tracing::error!(err = %error, "emptyTrash.countFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    };
    let Some(write) = context.write.as_ref() else {
        return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
    };
    if let Err(error) = write.empty_trash().await {
        return provider_error_response(error, "");
    }
    if let Err(error) = write::delete_trashed_rows(&context.connection, account_id) {
        tracing::error!(err = %error, "emptyTrash.localFailed");
        return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
    }
    respond::json(
        StatusCode::OK,
        &json!({ "ok": true, "remoteId": "", "purged": purged }),
    )
}

/* ------------------------------------------------------------------ bulk --- */

#[derive(Debug, Deserialize)]
pub struct BulkBody {
    #[serde(rename = "remoteIds")]
    remote_ids: Option<Vec<String>>,
}

fn parse_bulk(body: &[u8]) -> Result<Vec<String>, Response> {
    if body.is_empty() {
        return Err(respond::error(StatusCode::BAD_REQUEST, "missing-body"));
    }
    let value: serde_json::Value = match serde_json::from_slice(body) {
        Ok(value) => value,
        Err(_) => return Err(respond::error(StatusCode::BAD_REQUEST, "invalid-body")),
    };
    let Some(ids) = value.get("remoteIds").and_then(|ids| ids.as_array()) else {
        return Err(respond::error(StatusCode::BAD_REQUEST, "invalid-body"));
    };
    let ids: Vec<String> = ids
        .iter()
        .filter_map(|id| id.as_str().map(str::to_owned))
        .collect();
    if ids.is_empty() {
        return Err(respond::error(StatusCode::BAD_REQUEST, "empty-remoteIds"));
    }
    Ok(ids)
}

/// One bulk endpoint: gate once, then per-item remote -> local -> audit.
/// A failed item is recorded per-item; the other items keep going.
async fn run_bulk(
    state: AppState,
    account_id: Uuid,
    remote_ids: Vec<String>,
    verb: WriteVerb,
) -> Response {
    let context = match action_context(&state, account_id).await {
        Ok(context) => context,
        Err(response) => return response,
    };
    if let Some((status, code)) = verb.gate(&context.capabilities) {
        return respond::error(status, code);
    }
    let Some(write) = context.write.as_ref() else {
        return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
    };
    let mut items = Vec::with_capacity(remote_ids.len());
    for remote_id in &remote_ids {
        if let Err(error) = verb.remote(write.as_ref(), remote_id).await {
            let label = error.to_string();
            tracing::warn!(remoteId = %remote_id, label = %label, "bulk.remoteFailed");
            items.push(json!({
                "remoteId": remote_id,
                "ok": false,
                "errorCode": match error {
                    ProviderError::AuthFailed => "imap-auth-failed",
                    _ => "provider-unreachable",
                }
            }));
            continue;
        }
        let mut item = json!({ "remoteId": remote_id, "ok": true });
        match verb.local(&context.connection, account_id, remote_id) {
            Ok(previous) => {
                if let Some(kind) = verb.audit_kind() {
                    let payload = verb.audit_payload(remote_id, true, previous);
                    match write::record_action(&context.connection, account_id, kind, &payload) {
                        Ok(action_id) => {
                            item["actionId"] = json!(action_id);
                        }
                        Err(error) => {
                            tracing::error!(err = %error, "bulk.auditFailed");
                            return respond::error(
                                StatusCode::INTERNAL_SERVER_ERROR,
                                "internal-error",
                            );
                        }
                    }
                }
            }
            Err(error) => {
                tracing::error!(err = %error, "bulk.localFailed");
                return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
            }
        }
        items.push(item);
    }
    respond::json(StatusCode::OK, &json!({ "items": items }))
}

/// POST /api/archive-bulk
pub async fn archive_bulk(
    State(state): State<AppState>,
    Query(params): Query<AccountQuery>,
    body: Bytes,
) -> Response {
    let account_id = match query_account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let remote_ids = match parse_bulk(&body) {
        Ok(ids) => ids,
        Err(response) => return response,
    };
    run_bulk(state, account_id, remote_ids, WriteVerb::Archive).await
}

/// POST /api/delete-bulk
pub async fn delete_bulk(
    State(state): State<AppState>,
    Query(params): Query<AccountQuery>,
    body: Bytes,
) -> Response {
    let account_id = match query_account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let remote_ids = match parse_bulk(&body) {
        Ok(ids) => ids,
        Err(response) => return response,
    };
    run_bulk(state, account_id, remote_ids, WriteVerb::Trash).await
}

/* ------------------------------------------------------------- history ---- */

fn action_wire(account_id: Uuid, record: &write::ActionRecord) -> serde_json::Value {
    let payload: serde_json::Value =
        serde_json::from_str(&record.payload).unwrap_or_else(|_| json!({}));
    let mut action = json!({
        "id": record.id,
        "accountId": account_id.to_string(),
        "kind": record.kind,
        "payload": payload,
        "createdAt": record
            .created_at
            .parse::<i64>()
            .is_err()
            .then(|| ())
            .and_then(|_| crate::timefmt::parse_stored(&record.created_at))
            .map(crate::timefmt::to_iso8601)
            .unwrap_or_else(|| record.created_at.clone()),
    });
    if let Some(expires_at) = record
        .expires_at
        .as_deref()
        .and_then(crate::timefmt::parse_stored)
    {
        action["expiresAt"] = json!(crate::timefmt::to_iso8601(expires_at));
    }
    action
}

#[derive(Debug, Deserialize)]
pub struct ListParams {
    #[serde(rename = "accountId")]
    account_id: Option<String>,
    since: Option<String>,
    limit: Option<String>,
    before: Option<String>,
}

/// GET /api/actions - one history page, undone rows excluded.
pub async fn list_actions(
    State(state): State<AppState>,
    Query(params): Query<ListParams>,
) -> Response {
    let account_id = match query_account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let limit = match params.limit.as_deref() {
        None => 100,
        Some(raw) => match raw.parse::<i64>() {
            Ok(value) if value >= 1 => value.min(500),
            _ => 100,
        },
    };
    let before = match params.before.as_deref() {
        None => None,
        Some(raw) => match raw.parse::<i64>() {
            Ok(id) if id > 0 => {
                let outcome = state
                    .db
                    .read(move |connection| {
                        write::action_cursor(connection, account_id, id)
                            .map_err(map_write_error)
                    })
                    .await;
                match outcome {
                    Ok(Some(cursor)) => Some(cursor),
                    _ => return respond::error(StatusCode::BAD_REQUEST, "unknown-before"),
                }
            }
            _ => return respond::error(StatusCode::BAD_REQUEST, "malformed-before"),
        },
    };
    let since = params.since.clone();
    let page = match state
        .db
        .read(move |connection| {
            write::actions_page(
                connection,
                account_id,
                since.as_deref(),
                before.as_ref(),
                limit,
            )
            .map_err(map_write_error)
        })
        .await
    {
        Ok(page) => page,
        _ => return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error"),
    };
    let actions: Vec<serde_json::Value> = page
        .actions
        .iter()
        .map(|record| action_wire(account_id, record))
        .collect();
    respond::json(
        StatusCode::OK,
        &json!({
            "actions": actions,
            "totalCount": page.total_count,
            "hasMore": page.has_more,
        }),
    )
}

/* --------------------------------------------------------------- undo ----- */

enum UndoOutcome {
    Undone,
    NotUndoable,
    Rejected(StatusCode, &'static str),
    Failed(String),
}

/// v3 undoOne: claim single-use in one transaction (find -> expired? ->
/// already-undone? -> undo row), then invert remote-first. The claim is
/// retracted when the inverse fails, because an action that reads as undone
/// after a failed undo is the one state single-use undo must never leave
/// behind.
async fn undo_one(state: &AppState, account_id: Uuid, action_id: i64) -> UndoOutcome {
    let mut connection = match state.write_connection() {
        Ok(connection) => connection,
        Err(error) => return UndoOutcome::Failed(error.to_string()),
    };
    let (verb, remote_write, remote_id, claim_row) = {
        let transaction = match connection.transaction() {
            Ok(transaction) => transaction,
            Err(error) => return UndoOutcome::Failed(error.to_string()),
        };
        let action = match write::find_action(&transaction, account_id, action_id) {
            Ok(Some(action)) => action,
            Ok(None) => return UndoOutcome::Rejected(StatusCode::NOT_FOUND, "unknown-action"),
            Err(error) => return UndoOutcome::Failed(error.to_string()),
        };
        if let Some(expires_at) = &action.expires_at {
            let now = crate::timefmt::to_stored(crate::timefmt::now());
            if expires_at.as_str() <= now.as_str() {
                return UndoOutcome::Rejected(StatusCode::GONE, "action-expired");
            }
        }
        match write::is_undone(&transaction, account_id, action_id) {
            Ok(true) => return UndoOutcome::Rejected(StatusCode::CONFLICT, "already-undone"),
            Ok(false) => {}
            Err(error) => return UndoOutcome::Failed(error.to_string()),
        }
        let payload: serde_json::Value =
            serde_json::from_str(&action.payload).unwrap_or_else(|_| json!({}));
        let verb = match action.kind.as_str() {
            "archive" => WriteVerb::Archive,
            "delete" => WriteVerb::Trash,
            "markRead" => WriteVerb::SetRead(
                payload
                    .get("previousIsRead")
                    .and_then(|value| value.as_str())
                    .map(|raw| raw == "true")
                    .unwrap_or(false),
            ),
            "pin" => WriteVerb::SetPinned(false),
            "unpin" => WriteVerb::SetPinned(true),
            _ => return UndoOutcome::NotUndoable,
        };
        let remote_write =
            payload.get("remoteWrite").and_then(|value| value.as_str()) == Some("true");
        let remote_id = payload
            .get("remoteId")
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_owned();
        if let Err(error) = write::record_undo(
            &transaction,
            account_id,
            action_id,
            &json!({ "undoOf": action_id }).to_string(),
        ) {
            return UndoOutcome::Failed(error.to_string());
        }
        let claim_row = transaction.last_insert_rowid();
        if let Err(error) = transaction.commit() {
            return UndoOutcome::Failed(error.to_string());
        }
        (verb, remote_write, remote_id, claim_row)
    };
    // The inverse write provider, from the stored credentials. Missing here is
    // a hard failure (500) exactly like v3 throwing notConfigured.
    let write = match write_provider(state, &connection, account_id) {
        Ok(Some(write)) => write,
        Ok(None) => {
            let _ = write::delete_action_row(&connection, claim_row);
            return UndoOutcome::Failed("provider missing during undo".to_owned());
        }
        Err(response) => {
            let _ = write::delete_action_row(&connection, claim_row);
            return UndoOutcome::Failed(format!("provider error: {response:?}"));
        }
    };
    let outcome = if remote_write && verb.touches_remote() {
        match verb.remote(write.as_ref(), &remote_id).await {
            Ok(()) => verb
                .local(&connection, account_id, &remote_id)
                .map(|_| ())
                .map_err(|error| error.to_string()),
            Err(error) => Err(error.to_string()),
        }
    } else {
        verb
            .local(&connection, account_id, &remote_id)
            .map(|_| ())
            .map_err(|error| error.to_string())
    };
    match outcome {
        Ok(()) => UndoOutcome::Undone,
        Err(message) => {
            let _ = write::delete_action_row(&connection, claim_row);
            UndoOutcome::Failed(message)
        }
    }
}

/// POST /api/actions/{id}/undo
pub async fn undo_action(
    State(state): State<AppState>,
    Path(action_id_raw): Path<String>,
    Query(params): Query<UndoParams>,
) -> Response {
    let account_id = match query_account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let Ok(action_id) = action_id_raw.parse::<i64>() else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-action-id");
    };
    if action_id <= 0 {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-action-id");
    }
    match undo_one(&state, account_id, action_id).await {
        UndoOutcome::Undone => {
            respond::json(StatusCode::OK, &json!({ "ok": true, "undone": action_id }))
        }
        UndoOutcome::NotUndoable => {
            respond::error(StatusCode::BAD_REQUEST, "not-undoable")
        }
        UndoOutcome::Rejected(status, code) => respond::error(status, code),
        UndoOutcome::Failed(message) => {
            tracing::error!(label = %message, "undo.failed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "undo-failed")
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct UndoBulkBody {
    #[serde(rename = "actionIds")]
    action_ids: Option<Vec<i64>>,
}

/// POST /api/actions/undo-bulk - per-item undo, items[] partial success.
pub async fn undo_bulk(
    State(state): State<AppState>,
    Query(params): Query<UndoParams>,
    body: Bytes,
) -> Response {
    let account_id = match query_account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    if body.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "missing-body");
    }
    let parsed: UndoBulkBody = match serde_json::from_slice(&body) {
        Ok(parsed) => parsed,
        Err(_) => return respond::error(StatusCode::BAD_REQUEST, "invalid-body"),
    };
    let ids: Vec<i64> = match parsed.action_ids {
        Some(ids) => {
            let unique: std::collections::HashSet<i64> = ids.into_iter().collect();
            unique.into_iter().take(500).collect()
        }
        None => return respond::error(StatusCode::BAD_REQUEST, "empty-actionIds"),
    };
    if ids.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "empty-actionIds");
    }
    let mut items = Vec::with_capacity(ids.len());
    let mut undone = 0;
    for action_id in ids {
        let outcome = undo_one(&state, account_id, action_id).await;
        match outcome {
            UndoOutcome::Undone => {
                undone += 1;
                items.push(json!({ "actionId": action_id, "ok": true }));
            }
            UndoOutcome::NotUndoable => {
                items.push(json!({ "actionId": action_id, "ok": false, "errorCode": "not-undoable" }));
            }
            UndoOutcome::Rejected(_, code) => {
                items.push(json!({ "actionId": action_id, "ok": false, "errorCode": code }));
            }
            UndoOutcome::Failed(message) => {
                tracing::error!(actionId = action_id, label = %message, "undoBulk.itemFailed");
                items.push(json!({ "actionId": action_id, "ok": false, "errorCode": "undo-failed" }));
            }
        }
    }
    respond::json(StatusCode::OK, &json!({ "items": items, "undone": undone }))
}
