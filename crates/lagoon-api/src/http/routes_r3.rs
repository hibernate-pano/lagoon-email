//! R3.3: the account lifecycle routes.
//!
//! POST /api/accounts/imap   connect or re-authenticate a mailbox
//! POST /api/accounts/{id}/activate   select the account the client shows
//! DELETE /api/accounts/{id}  remove it (foreign keys cascade)
//!
//! Status-code order follows v3 AccountsRoutes. The provider seam is asked
//! exactly once, after the identity check and before anything is persisted, so
//! a rejected authorization code never leaves a row behind.

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::Response;

use crate::provider::{ProviderError};
use crate::store::{self, write, StoreError, write::NewAccount};
use crate::token::ImapCredentials;
use crate::uuid::Uuid;
use crate::wire;

use super::respond;
use super::AppState;

fn malformed_fields() -> Response {
    respond::error(StatusCode::BAD_REQUEST, "missing-field")
}

/// The body of POST /api/accounts/imap.
struct ConnectRequest {
    provider: String,
    email: String,
    auth_code: String,
}

fn parse_body(body: &[u8]) -> Result<ConnectRequest, Response> {
    // v3 answers missing-field, not missing-body, for an empty body: its
    // collectBody succeeds with zero bytes and the decoder is what fails.
    // missing-body is reserved for a body-stream failure, which cannot happen
    // through this extractor and is therefore not invented here.
    let value: serde_json::Value = serde_json::from_slice(body).map_err(|_| malformed_fields())?;
    let provider = value.get("provider").and_then(|item| item.as_str());
    let email = value.get("email").and_then(|item| item.as_str());
    let auth_code = value.get("authCode").and_then(|item| item.as_str());
    let (Some(provider), Some(email), Some(auth_code)) = (provider, email, auth_code) else {
        return Err(malformed_fields());
    };
    // Clipboard copies of a QQ authorization code routinely carry a trailing
    // newline; v3 trims it, and so must this server or a valid code 401s.
    let email = email.trim().to_owned();
    let auth_code = auth_code.trim().to_owned();
    if email.is_empty() || auth_code.is_empty() || provider != "qq" {
        return Err(malformed_fields());
    }
    Ok(ConnectRequest {
        provider: provider.to_owned(),
        email,
        auth_code,
    })
}

/// v3 MailCapabilities JSON for the accounts.capabilities column.
fn capabilities_json(capabilities: &wire::MailCapabilities) -> String {
    serde_json::to_string(capabilities).unwrap_or_else(|_| "{}".to_owned())
}

/// Merge the resolved archive folder into the stored sync cursor.
fn merge_archive_folder(existing: Option<&str>, archive_folder: Option<&str>) -> String {
    let mut value: serde_json::Value = existing
        .and_then(|raw| serde_json::from_str(raw).ok())
        .unwrap_or_else(|| serde_json::json!({}));
    if !value.is_object() {
        value = serde_json::json!({});
    }
    if let Some(folder) = archive_folder {
        value["archiveFolder"] = serde_json::Value::String(folder.to_owned());
    }
    value.to_string()
}

fn connected_account(
    connection: &rusqlite::Connection,
    account_id: Uuid,
) -> Result<Option<wire::ConnectedAccount>, StoreError> {
    let Some(account) = store::accounts::find(connection, account_id)? else {
        return Ok(None);
    };
    let unread = store::messages::count(
        connection,
        &store::messages::MessageFilter {
            unread: true,
            ..store::messages::MessageFilter::inbox(account_id)
        },
    )
    .unwrap_or(0);
    Ok(Some(wire::ConnectedAccount {
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
    }))
}

/// POST /api/accounts/imap - connect, or re-authenticate, one mailbox.
pub async fn connect_imap(State(state): State<AppState>, body: Bytes) -> Response {
    let connect = match parse_body(&body) {
        Ok(connect) => connect,
        Err(response) => return response,
    };
    let Some(token_key) = state.token_key.clone() else {
        // Fail closed: without the credential key the alternative is storing a
        // plaintext authorization code, which is the one thing this column
        // exists to prevent.
        // Same verdict v3 gives when credentials cannot be read: the account
        // cannot be configured, not "the server broke".
        tracing::error!("accounts.tokenKeyMissing");
        return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
    };

    let connection = match state.write_connection() {
        Ok(connection) => connection,
        Err(error) => {
            tracing::error!(err = %error, "accounts.writeOpenFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    };

    let existing = match store::accounts::find_by_oauth_user(&connection, &connect.provider, &connect.email) {
        Ok(existing) => existing,
        Err(error) => {
            tracing::error!(err = %error, "accounts.lookupFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    };
    // Rule 1: a healthy account is reported before any network work.
    if let Some(account) = &existing {
        if wire::SyncHealth::status_or_ok(&account.sync_status) == "ok" {
            return respond::error(StatusCode::CONFLICT, "account-exists");
        }
    }

    let credentials = ImapCredentials::new(connect.email.clone(), connect.auth_code.clone());
    let sealed = match credentials.seal(&token_key) {
        Ok(sealed) => sealed,
        Err(error) => {
            tracing::error!(err = %error, "accounts.sealFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    };

    // The probe provider must use the submitted code, never the stored blob of
    // a row being re-authenticated: the user is proving *this* code today.
    let Some(provider) = state.provider_factory.make(&credentials) else {
        return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
    };
    let outcome = match provider.probe().await {
        Ok(outcome) => outcome,
        Err(ProviderError::AuthFailed) => {
            tracing::warn!("imap.probeFailed label=auth-failed");
            return respond::error(StatusCode::UNAUTHORIZED, "imap-auth-failed");
        }
        Err(ProviderError::NotConfigured(message)) => {
            tracing::warn!(label = %message, "imap.probeFailed");
            return respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured");
        }
        Err(error) => {
            tracing::warn!(err = %error, "imap.probeFailed");
            return respond::error(StatusCode::BAD_GATEWAY, "imap-unreachable");
        }
    };

    let account_id = existing
        .as_ref()
        .map(|account| account.id)
        .unwrap_or_else(Uuid::new_v4);

    let persist = (|| -> Result<(), StoreError> {
        if let Some(account) = &existing {
            // Re-authentication in place: only the code, capabilities, archive
            // folder and health move; id, cursor and read state stay put.
            write::update_credentials(&connection, account.id, &sealed)
                .map_err(store_error)?;
            if let Some(capabilities) = &outcome.capabilities {
                write::update_capabilities(&connection, account.id, &capabilities_json(capabilities))
                    .map_err(store_error)?;
            }
            let current = store::accounts::sync_state_json(&connection, account.id)?
                .unwrap_or_else(|| "{}".to_owned());
            let merged = merge_archive_folder(Some(&current), outcome.archive_folder.as_deref());
            write::update_sync_state(
                &connection,
                account.id,
                &merged,
                &wire::SyncHealth::status_or_ok(&account.sync_status),
                account.last_sync_at.map(|value| crate::timefmt::to_stored(value)).as_deref(),
                None,
            )
            .map_err(store_error)?;
            // lastError = nil clears the client's red reconnect banner.
            write::update_health(&connection, account.id, "ok", None, None).map_err(store_error)?;
        } else {
            let capabilities = outcome
                .capabilities
                .clone()
                .unwrap_or_else(wire::MailCapabilities::unknown);
            write::upsert_account(
                &connection,
                &NewAccount {
                    id: account_id,
                    provider: "qq",
                    oauth_user: &connect.email,
                    email: &connect.email,
                    credentials: Some(&sealed),
                    capabilities: &capabilities_json(&capabilities),
                    sync_state: &merge_archive_folder(None, outcome.archive_folder.as_deref()),
                },
            )
            .map_err(store_error)?;
        }
        // Connecting or re-authenticating a mailbox selects it; every other
        // account goes dormant.
        write::set_active(&connection, account_id).map_err(store_error)?;
        Ok(())
    })();
    if let Err(error) = persist {
        tracing::error!(err = %error, "accounts.imapPersistFailed");
        return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
    }

    // The account exists now, but start_all ran before it did: without this,
    // no sync loop ever pulls for it and the inbox stays empty forever (v3
    // triggers the first sync from the connect flow as well).
    // Fire-and-forget: the response reflects connect-time state; the loop's
    // first pull happens right after and updates health/cursor as it goes.
    let sync = Arc::clone(&state.sync);
    tokio::spawn(async move { sync.start_one(account_id).await });

    match connected_account(&connection, account_id) {
        Ok(Some(account)) => respond::json(StatusCode::CREATED, &account),
        Ok(None) => respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error"),
        Err(error) => {
            tracing::error!(err = %error, "accounts.readbackFailed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

fn store_error(error: write::WriteError) -> StoreError {
    match error {
        write::WriteError::Sqlite(error) => StoreError::Sqlite(error),
        other => StoreError::Sqlite(rusqlite::Error::InvalidParameterName(other.to_string())),
    }
}

/// POST /api/accounts/{id}/activate - selects the mailbox the client shows.
pub async fn activate(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    // v3 treats an unparseable id as 404, not 400: the route is "does this
    // account exist", and a malformed uuid cannot.
    let Some(account_id) = Uuid::parse_strict(&id) else {
        return respond::error(StatusCode::NOT_FOUND, "unknown-account");
    };
    let connection = match state.write_connection() {
        Ok(connection) => connection,
        Err(error) => {
            tracing::error!(err = %error, "accounts.writeOpenFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    };
    match store::accounts::exists(&connection, account_id) {
        Ok(false) | Err(_) => return respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Ok(true) => {}
    }
    if let Err(error) = write::set_active(&connection, account_id) {
        tracing::error!(err = %error, "accounts.activateFailed");
        return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
    }
    respond::empty(StatusCode::NO_CONTENT)
}

/// DELETE /api/accounts/{id} - removes the account; foreign keys cascade.
pub async fn delete_account(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let Some(account_id) = Uuid::parse_strict(&id) else {
        return respond::error(StatusCode::NOT_FOUND, "unknown-account");
    };
    let connection = match state.write_connection() {
        Ok(connection) => connection,
        Err(error) => {
            tracing::error!(err = %error, "accounts.writeOpenFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    };
    match store::accounts::exists(&connection, account_id) {
        Ok(false) | Err(_) => return respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Ok(true) => {}
    }
    if let Err(error) = write::delete_account(&connection, account_id) {
        tracing::error!(err = %error, "accounts.deleteFailed");
        return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
    }
    if let Err(error) = write::reconcile_active(&connection) {
        tracing::error!(err = %error, "accounts.reconcileFailed");
        return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
    }
    respond::empty(StatusCode::NO_CONTENT)
}

/// POST /api/sync - ask every account to pull now; answer 204 without waiting.
///
/// v3's requestImmediateSync restarts the loops and returns; the client polls
/// /api/accounts for health. Holding the request open for a mailbox backfill
/// would turn a UI button into a timeout.
pub async fn sync_now(State(state): State<AppState>) -> Response {
    let supervisor = Arc::clone(&state.sync);
    tokio::spawn(async move {
        supervisor.trigger_all().await;
    });
    respond::empty(StatusCode::NO_CONTENT)
}
