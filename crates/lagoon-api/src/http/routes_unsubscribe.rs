//! `POST /api/messages/{remoteId}/unsubscribe` and its bulk form.
//!
//! The one route that talks to a third party. Everything that makes that
//! acceptable lives in [`crate::unsubscribe`]; this file only sequences:
//! look up the stored target -> ask -> archive the mail locally and on the
//! server -> audit.
//!
//! Two audit rows, on purpose:
//!   * `unsubscribe` (payload: url, httpStatus) - the irreversible fact;
//!   * `archive` (payload: remoteId, remoteWrite) - the undoable side effect.
//!
//! Undoing the archive restores the mail; nothing can restore the subscription,
//! which is why the UI asks first.

use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::Response;
use serde::Deserialize;
use serde_json::json;

use super::routes_r5::{action_context, ActionContext};
use std::sync::Arc;

use super::{respond, AppState};
use crate::store::{self, write};
use crate::unsubscribe::{self, Refusal, Reply};
use crate::uuid::Uuid;

/// The most mails one bulk unsubscribe may carry, matching the other bulk verbs.
const BULK_LIMIT: usize = 500;

#[derive(Debug, Deserialize)]
pub struct AccountQuery {
    #[serde(rename = "accountId")]
    account_id: Option<String>,
}

fn account_of(raw: Option<&str>) -> Result<Uuid, Response> {
    let raw = raw.unwrap_or_default();
    Uuid::parse_strict(raw)
        .ok_or_else(|| respond::error(StatusCode::BAD_REQUEST, "malformed-accountId"))
}

/// What `unsubscribe` needs to know about one mail.
struct Plan {
    remote_id: String,
    target: Result<String, Refusal>,
}

fn plan_for(context: &ActionContext, account_id: Uuid, remote_id: &str) -> Result<Plan, Response> {
    let links = match store::messages::unsubscribe_links(&context.connection, account_id, remote_id)
    {
        Ok(Some(links)) => links,
        Ok(None) => {
            return Err(respond::error(StatusCode::NOT_FOUND, "message-not-found"));
        }
        Err(error) => {
            tracing::error!(err = %error, "unsubscribe.linksFailed");
            return Err(respond::error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal-error",
            ));
        }
    };
    Ok(Plan {
        remote_id: remote_id.to_owned(),
        target: unsubscribe::one_click_target(&links),
    })
}

/// Ask the publisher, then settle the mail locally.
///
/// The archive is best-effort on the server (like `markRead`): a mailbox that
/// refuses the move must not turn a completed unsubscribe into an error the
/// user retries - the subscription is already gone.
fn settle(
    context: &ActionContext,
    account_id: Uuid,
    remote_id: &str,
    url: &str,
    status: u16,
) -> Result<i64, Response> {
    let _ = write::set_archived(&context.connection, account_id, remote_id, true);
    let _ = write::set_read_flag(&context.connection, account_id, remote_id, true);
    let payload = json!({
        "remoteId": remote_id,
        "remoteWrite": "true",
    })
    .to_string();
    let archive_id = write::record_action(&context.connection, account_id, "archive", &payload)
        .map_err(|error| {
            tracing::error!(err = %error, "unsubscribe.archiveAuditFailed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        })?;
    let audit = json!({
        "remoteId": remote_id,
        "url": url,
        "httpStatus": status,
        "ok": "true",
    })
    .to_string();
    // The response names the unsubscribe row (the fact the user asked for);
    // the archive row stays in the history as the undoable half.
    let action_id =
        match write::record_action(&context.connection, account_id, "unsubscribe", &audit) {
            Ok(id) => id,
            Err(error) => {
                tracing::warn!(err = %error, "unsubscribe.auditFailed");
                archive_id
            }
        };
    let _ = store::advice::accept_pending_for_message(&context.connection, account_id, remote_id);
    Ok(action_id)
}

async fn run(state: AppState, account_id: Uuid, remote_id: String) -> Response {
    let context = match action_context(&state, account_id).await {
        Ok(context) => context,
        Err(response) => return response,
    };
    let plan = match plan_for(&context, account_id, &remote_id) {
        Ok(plan) => plan,
        Err(response) => return response,
    };
    let url = match plan.target {
        Ok(url) => url,
        Err(refusal) => {
            tracing::info!(
                remoteId = %plan.remote_id,
                label = refusal.label(),
                "unsubscribe.refused"
            );
            return respond::error(StatusCode::UNPROCESSABLE_ENTITY, refusal.code());
        }
    };
    let target = match unsubscribe::parse_target(&url) {
        Ok(target) => target,
        Err(refusal) => {
            return respond::error(StatusCode::UNPROCESSABLE_ENTITY, refusal.code());
        }
    };
    let firer = Arc::clone(&state.unsubscribe);
    let reply = tokio::task::spawn_blocking(move || firer.fire(&target))
        .await
        .unwrap_or_else(|_| Reply::Failed {
            reason: "join".to_owned(),
        });
    match reply {
        Reply::Unsubscribed { status, publisher } => {
            let action_id = match settle(&context, account_id, &remote_id, &url, status) {
                Ok(id) => id,
                Err(response) => return response,
            };
            // The server-side move is best-effort: the subscription is gone
            // either way, and a failed move is a local-state detail.
            if let Some(write) = context.write.as_ref() {
                if let Err(error) = write.archive(&remote_id).await {
                    tracing::warn!(remoteId = %remote_id, label = %error, "unsubscribe.remoteArchiveFailed");
                }
            }
            respond::json(
                StatusCode::OK,
                &json!({
                    "ok": true,
                    "unsubscribed": true,
                    "publisher": publisher,
                    "actionId": action_id,
                }),
            )
        }
        Reply::Failed { reason } => {
            tracing::warn!(remoteId = %remote_id, label = %reason, "unsubscribe.failed");
            respond::error(StatusCode::BAD_GATEWAY, "unsubscribe-failed")
        }
    }
}

/// POST /api/messages/{remoteId}/unsubscribe
pub async fn unsubscribe(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    Query(params): Query<AccountQuery>,
) -> Response {
    let account_id = match account_of(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    run(state, account_id, remote_id).await
}

/// POST /api/unsubscribe-bulk - `{ "remoteIds": [...] }`
///
/// One request per **publisher URL**, not per mail: a newsletter that sent
/// nine mails is one subscription. Per-mail results are still reported, so the
/// board can settle exactly the rows that left.
pub async fn unsubscribe_bulk(
    State(state): State<AppState>,
    Query(params): Query<AccountQuery>,
    body: Bytes,
) -> Response {
    let account_id = match account_of(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let remote_ids = match parse_bulk(&body) {
        Ok(ids) => ids,
        Err(response) => return response,
    };
    let context = match action_context(&state, account_id).await {
        Ok(context) => context,
        Err(response) => return response,
    };
    let mut items = Vec::with_capacity(remote_ids.len());
    // url -> what the publisher answered, so one subscription is asked once.
    let mut answered: std::collections::HashMap<String, Reply> = std::collections::HashMap::new();
    for remote_id in remote_ids {
        let plan = match plan_for(&context, account_id, &remote_id) {
            Ok(plan) => plan,
            Err(response) => return response,
        };
        let url = match plan.target {
            Ok(url) => url,
            Err(refusal) => {
                items.push(json!({
                    "remoteId": plan.remote_id,
                    "ok": false,
                    "errorCode": refusal.code(),
                }));
                continue;
            }
        };
        let reply = match answered.get(&url) {
            Some(reply) => reply.clone(),
            None => {
                let target = match unsubscribe::parse_target(&url) {
                    Ok(target) => target,
                    Err(refusal) => {
                        items.push(json!({
                            "remoteId": plan.remote_id,
                            "ok": false,
                            "errorCode": refusal.code(),
                        }));
                        continue;
                    }
                };
                let firer = Arc::clone(&state.unsubscribe);
                let fired = tokio::task::spawn_blocking(move || firer.fire(&target))
                    .await
                    .unwrap_or_else(|_| Reply::Failed {
                        reason: "join".to_owned(),
                    });
                answered.insert(url.clone(), fired.clone());
                fired
            }
        };
        match reply {
            Reply::Unsubscribed { status, .. } => {
                if let Some(write) = context.write.as_ref() {
                    if let Err(error) = write.archive(&remote_id).await {
                        tracing::warn!(remoteId = %remote_id, label = %error, "unsubscribe.remoteArchiveFailed");
                    }
                }
                match settle(&context, account_id, &remote_id, &url, status) {
                    Ok(action_id) => items.push(json!({
                        "remoteId": remote_id,
                        "ok": true,
                        "actionId": action_id,
                    })),
                    Err(response) => return response,
                }
            }
            Reply::Failed { reason } => {
                tracing::warn!(remoteId = %remote_id, label = %reason, "unsubscribe.failed");
                items.push(json!({
                    "remoteId": remote_id,
                    "ok": false,
                    "errorCode": "unsubscribe-failed",
                }));
            }
        }
    }
    respond::json(StatusCode::OK, &json!({ "items": items }))
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
        .take(BULK_LIMIT)
        .collect();
    if ids.is_empty() {
        return Err(respond::error(StatusCode::BAD_REQUEST, "empty-remoteIds"));
    }
    Ok(ids)
}
