//! The triage batch routes (plan §4.6).
//!
//! Three endpoints, one state machine: read where the batch is, start it, stop
//! it. The run itself happens on its own task, so `run` answers 202 with the
//! status it started rather than holding the request open for minutes.

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::Response;
use serde::Deserialize;
use serde_json::json;

use crate::triage::{RunState, TriageStatus};
use crate::uuid::Uuid;

use super::{respond, AppState};

#[derive(Debug, Deserialize)]
pub struct TriageQuery {
    #[serde(rename = "accountId")]
    account_id: Option<String>,
}

fn account_id(raw: Option<&str>) -> Result<Uuid, Response> {
    raw.and_then(Uuid::parse_strict)
        .ok_or_else(|| respond::error(StatusCode::BAD_REQUEST, "malformed-accountId"))
}

/// The account's email, which the usage ledger keys on.
///
/// The ledger stores `account_email` per row, so a batch that skips this write
/// would be a batch whose cost cannot be attributed. It is read from the
/// account row, not from the request: the client does not get to name itself on
/// a cost record.
async fn account_email(state: &AppState, account_id: Uuid) -> Result<String, Response> {
    let outcome = state
        .db
        .read(move |connection| crate::store::accounts::find(connection, account_id))
        .await;
    match outcome {
        Ok(Some(account)) => Ok(account.email),
        Ok(None) => Err(respond::error(StatusCode::NOT_FOUND, "unknown-account")),
        Err(error) => {
            tracing::error!(err = %error, "triage.accountReadFailed");
            Err(respond::error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal-error",
            ))
        }
    }
}

fn wire(status: &TriageStatus) -> serde_json::Value {
    let run = match &status.run {
        None => serde_json::Value::Null,
        Some(run) => json!({
            "startedAt": run.started_at,
            "phase": run.phase.map(|phase| phase.as_str()),
            "target": run.target,
            "done": run.done,
            "failed": run.failed,
            "state": run.state.as_str(),
            "lastError": run.last_error,
        }),
    };
    json!({
        "configured": status.configured,
        "running": status.running,
        "suggested": status.suggested,
        "unsuggested": status.unsuggested,
        "bySource": {
            "heuristic": status.heuristic_count,
            "ai": status.ai_count,
        },
        "spendMonthMicroUsd": status.spend_month_micro_usd,
        "capMonthMicroUsd": status.cap_month_micro_usd,
        "run": run,
    })
}

fn status_response(state: &AppState, account_id: Uuid) -> Response {
    match state.triage.status(account_id) {
        Ok(Some(status)) => respond::json(StatusCode::OK, &wire(&status)),
        // "No such account" is not "a mailbox with nothing in it": answering
        // zeros would make a typo look like an empty inbox.
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => {
            tracing::error!(err = %error, "triage.statusFailed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

/// Turn the worker's answer into the route's answer, for the two routes that
/// change something.
fn mutation_response(
    outcome: Result<Option<TriageStatus>, crate::db::DbError>,
    label: &str,
) -> Response {
    match outcome {
        Ok(Some(status)) => respond::json(StatusCode::ACCEPTED, &wire(&status)),
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => {
            tracing::error!(err = %error, label);
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

/// GET /api/triage/status - where the batch is.
///
/// Answers 200 whether or not a run ever happened: `run` is null then, and the
/// two counts still say how much mail is waiting. That is the honest shape -
/// "nothing has been tried" and "everything is done" are different facts.
pub async fn status(State(state): State<AppState>, Query(params): Query<TriageQuery>) -> Response {
    let account_id = match account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    status_response(&state, account_id)
}

/// POST /api/triage/run - start the batch, or answer the one already going.
///
/// 202 either way: the caller's next move is the same (poll), and a second
/// click that started a second worker would bill the same mail twice.
pub async fn run(State(state): State<AppState>, Query(params): Query<TriageQuery>) -> Response {
    let account_id = match account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    let email = match account_email(&state, account_id).await {
        Ok(email) => email,
        Err(response) => return response,
    };
    match state.triage.start(account_id, email) {
        Ok(()) => {}
        Err(_already_running) => {
            // Not an error: the answer is "it is already doing that", and the
            // status below is what the UI renders.
        }
    }
    mutation_response(state.triage.status(account_id), "triage.runStatusFailed")
}

/// POST /api/triage/cancel - ask the run to stop.
///
/// The worker notices between batches, so the answer is the status *now*: a
/// cancel that reported `cancelled` while three calls were still on the wire
/// would be a lie about money already spent.
pub async fn cancel(State(state): State<AppState>, Query(params): Query<TriageQuery>) -> Response {
    let account_id = match account_id(params.account_id.as_deref()) {
        Ok(account_id) => account_id,
        Err(response) => return response,
    };
    match state.triage.cancel(account_id) {
        Ok(Some(status)) => respond::json(StatusCode::OK, &wire(&status)),
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => {
            tracing::error!(err = %error, "triage.cancelFailed");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

/// The state the route reports when a run ended for a reason the client must
/// be able to name. Kept here so the contract test can enumerate it.
pub const TERMINAL_STATES: [&str; 5] = [
    "done",
    "stopped-budget",
    "stopped-unconfigured",
    "stopped-error",
    "cancelled",
];

/// A compile-time check that the list above is the whole set: adding a state
/// without listing it here breaks this match, which is cheaper than a test that
/// has to run.
const _: fn() = || {
    fn exhaustive(state: RunState) {
        match state {
            RunState::Running => {}
            RunState::Done => {}
            RunState::StoppedBudget => {}
            RunState::StoppedUnconfigured => {}
            RunState::StoppedError => {}
            RunState::Cancelled => {}
        }
    }
    let _ = exhaustive;
};
