//! The advice decision routes (plan §5.2).
//!
//! A suggestion becoming a decision is not the same act as a mail being
//! archived, and the two are kept apart on purpose:
//!
//! * `POST /api/advice/{id}/decision` records what the user decided about a
//!   suggestion. It changes no mail.
//! * The client executes first (`archive-bulk` / `delete-bulk`, which are
//!   already covered by the undo tests) and only then records the decision. A
//!   failed archive leaves the suggestion `pending`, so the queue never claims
//!   something happened that did not.
//!
//! Why not one "accept and execute" endpoint: the contract declared `decision`
//! (docs/api-contract.md §4.8), and execution already has a tested path. A
//! second write path would be a second thing to keep correct, with no undo.
//!
//! `pending` is not an accepted input. Letting a caller un-decide would break
//! `upsert_ai`'s `WHERE decision = 'pending'` guard and let the worker
//! overwrite a choice the user made.

use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::Response;
use serde::Deserialize;
use serde_json::json;

use crate::store::{self, StoreError};
use crate::uuid::Uuid;

use super::{respond, AppState};

/// The most ids one bulk decision may carry. Same ceiling as the mail bulk
/// routes, so "how much can one request touch" has one answer.
const MAX_BULK_IDS: usize = 500;

#[derive(Debug, Deserialize)]
pub struct AccountQuery {
    #[serde(rename = "accountId")]
    account_id: Option<String>,
}

fn account_id(raw: Option<&str>) -> Result<Uuid, Response> {
    raw.and_then(Uuid::parse_strict)
        .ok_or_else(|| respond::error(StatusCode::BAD_REQUEST, "malformed-accountId"))
}

/// The two decisions a user can record. `pending` is deliberately absent.
fn parse_decision(raw: Option<&str>) -> Option<&'static str> {
    match raw {
        Some("accepted") => Some("accepted"),
        Some("dismissed") => Some("dismissed"),
        _ => None,
    }
}

/// What the route answers for one row: the wire shape the contract names.
fn decided(id: i64, decision: &str) -> serde_json::Value {
    json!({ "id": id, "decision": decision })
}

/// POST /api/advice/{id}/decision - record the user's decision.
///
/// Idempotent: deciding twice keeps the first `decided_at` and answers 200 both
/// times. A batch retry must not turn into a 409 the UI has to special-case.
pub async fn decision(
    State(state): State<AppState>,
    Path(raw_id): Path<String>,
    Query(params): Query<AccountQuery>,
    body: Bytes,
) -> Response {
    let account_id = match account_from(&params, &state).await {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let id: i64 = match raw_id.parse() {
        Ok(id) => id,
        Err(_) => return respond::error(StatusCode::BAD_REQUEST, "malformed-advice-id"),
    };
    let value: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(value) => value,
        Err(_) => return respond::error(StatusCode::BAD_REQUEST, "invalid-body"),
    };
    let Some(decision) = parse_decision(value.get("decision").and_then(|raw| raw.as_str())) else {
        return respond::error(StatusCode::BAD_REQUEST, "invalid-decision");
    };

    let outcome = state
        .write(move |connection| {
            store::advice::decide(connection, account_id, id, decision)
                .map_err(|error| StoreError::Sqlite(error))
        })
        .await;
    match outcome {
        Ok(true) => respond::json(StatusCode::OK, &decided(id, decision)),
        Ok(false) => respond::error(StatusCode::NOT_FOUND, "unknown-advice"),
        Err(error) => {
            tracing::error!(err = %error, "advice.decideFailed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct BulkBody {
    ids: Option<Vec<i64>>,
    decision: Option<String>,
}

/// POST /api/advice/decisions-bulk - record many decisions in one request.
///
/// Per-row results, like the mail bulk routes: a partial success is a normal
/// outcome, not an error. The UI has to know which rows landed.
pub async fn decisions_bulk(
    State(state): State<AppState>,
    Query(params): Query<AccountQuery>,
    body: Bytes,
) -> Response {
    let account_id = match account_from(&params, &state).await {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let parsed: BulkBody = match serde_json::from_slice(&body) {
        Ok(parsed) => parsed,
        Err(_) => return respond::error(StatusCode::BAD_REQUEST, "invalid-body"),
    };
    let Some(decision) = parse_decision(parsed.decision.as_deref()) else {
        return respond::error(StatusCode::BAD_REQUEST, "invalid-decision");
    };
    let Some(ids) = parsed.ids else {
        return respond::error(StatusCode::BAD_REQUEST, "invalid-body");
    };
    if ids.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "empty-ids");
    }
    if ids.len() > MAX_BULK_IDS {
        return respond::error(StatusCode::BAD_REQUEST, "too-many-ids");
    }

    let outcome = state
        .write(move |connection| {
            let mut items = Vec::with_capacity(ids.len());
            for id in ids {
                match store::advice::decide(connection, account_id, id, decision) {
                    Ok(true) => items.push(json!({ "id": id, "ok": true, "decision": decision })),
                    Ok(false) => items.push(
                        json!({ "id": id, "ok": false, "errorCode": "unknown-advice" }),
                    ),
                    Err(error) => {
                        tracing::error!(err = %error, "advice.bulkDecideFailed");
                        items.push(
                            json!({ "id": id, "ok": false, "errorCode": "internal-error" }),
                        );
                    }
                }
            }
            Ok::<_, StoreError>(items)
        })
        .await;
    match outcome {
        Ok(items) => {
            let decided = items
                .iter()
                .filter(|item| item.get("ok").and_then(|ok| ok.as_bool()) == Some(true))
                .count();
            respond::json(
                StatusCode::OK,
                &json!({ "items": items, "decided": decided }),
            )
        }
        Err(error) => {
            tracing::error!(err = %error, "advice.bulkDecideOpenFailed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

/// Shared by the two routes above: the account id must name a real account
/// before anything is written.
///
/// Kept here rather than in each route because "the store said no because the
/// account is not there" and "the store failed" are different answers, and a
/// route that guessed would tell the user the wrong thing.
pub async fn ensure_account(state: &AppState, account_id: Uuid) -> Result<(), Response> {
    let outcome = state
        .db
        .read(move |connection| store::accounts::exists(connection, account_id))
        .await;
    match outcome {
        Ok(true) => Ok(()),
        Ok(false) => Err(respond::error(StatusCode::NOT_FOUND, "unknown-account")),
        Err(error) => {
            tracing::error!(err = %error, "advice.accountReadFailed");
            Err(respond::error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal-error",
            ))
        }
    }
}

/// The account id, checked against the store. Both routes need it first.
pub async fn account_from(params: &AccountQuery, state: &AppState) -> Result<Uuid, Response> {
    let account_id = account_id(params.account_id.as_deref())?;
    ensure_account(state, account_id).await?;
    Ok(account_id)
}
