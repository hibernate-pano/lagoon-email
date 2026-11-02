//! The R2 route handlers: every read endpoint that needs no IMAP session and no
//! model call.
//!
//! Status-code order per route follows v3's handler, including the places where
//! that order is surprising: /api/advice answers 404 for an unknown account but
//! /api/stacks answers 200 with an empty list, because v3's handler simply does
//! not check. Routes that would need a provider stop at the same gate v3 does
//! (503 provider-not-configured), which is what the golden fixtures pin for a
//! store whose sealed credentials cannot be opened.

use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::{StatusCode, Uri};
use axum::response::Response;
use chrono::TimeZone;

use crate::briefing;
use crate::store::{self, actions::Cursor, advice::DecisionFilter, search::Scope, StoreError};
use crate::timefmt::{self, Timestamp};
use crate::uuid::Uuid;
use crate::wire_r2;

use super::query;
use super::respond;
use super::routes;
use super::AppState;

/// v3 route limits, kept as named constants so a diff reads as a rule change.
const SENDERS_DEFAULT_LIMIT: i64 = 60;
const SENDERS_MAX_LIMIT: i64 = 300;
const ADVICE_DEFAULT_LIMIT: i64 = 200;
const ADVICE_MAX_LIMIT: i64 = 500;
const ADVICE_STATS_LIMIT: i64 = 5;
const ACTIONS_DEFAULT_LIMIT: i64 = 100;
const ACTIONS_MAX_LIMIT: i64 = 500;
const BRIEFING_MAX: i64 = 500;
const SENT_MAX_ROWS: i64 = 1000;

/// The accountId every account-scoped route parses the same way.
fn account_id_param(params: &[(String, String)]) -> Option<Uuid> {
    query::get(params, "accountId").and_then(Uuid::parse_strict)
}

/// v3's limit idiom: parse, fall back to the default, clamp to [1, max].
fn limit_param(params: &[(String, String)], default: i64, max: i64) -> i64 {
    query::get(params, "limit")
        .and_then(|raw| raw.trim().parse::<i64>().ok())
        .unwrap_or(default)
        .clamp(1, max)
}

/// v3 parses a ?since= with ISO8601DateFormatter (fractional first, then plain);
/// anything unparseable is ignored rather than rejected.
fn since_param(params: &[(String, String)]) -> Option<Timestamp> {
    query::get(params, "since").and_then(|raw| {
        if raw.is_empty() {
            return None;
        }
        timefmt::parse_iso8601(raw)
    })
}

fn internal_error(label: &'static str, error: impl std::fmt::Display) -> Response {
    tracing::error!(label, err = %error, "r2.queryFailed");
    eprintln!("{label}: {error}");
    respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
}

/// GET /api/senders - the sender ranking.
pub async fn senders(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    let limit = limit_param(&params, SENDERS_DEFAULT_LIMIT, SENDERS_MAX_LIMIT);
    let query_text = query::get(&params, "q")
        .map(|raw| raw.trim().to_owned())
        .filter(|raw| !raw.is_empty());

    let outcome = state
        .db
        .read(
            move |connection| -> Result<Option<Vec<wire_r2::SenderSummary>>, StoreError> {
                if !store::accounts::exists(connection, account_id)? {
                    return Ok(None);
                }
                let rows =
                    store::senders::ranking(connection, account_id, limit, query_text.as_deref())?;
                Ok(Some(
                    rows.into_iter()
                        .map(|row| wire_r2::SenderSummary {
                            address: row.address,
                            display_name: row.display_name,
                            total_count: row.total_count,
                            unread_count: row.unread_count,
                            latest_at: row.latest_at,
                        })
                        .collect(),
                ))
            },
        )
        .await;

    match outcome {
        Ok(Some(senders)) => {
            respond::json(StatusCode::OK, &wire_r2::SenderListResponse { senders })
        }
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => internal_error("senders.error", error),
    }
}

/// GET /api/advice - the decision queue.
pub async fn advice(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    let filter = match query::get(&params, "decision") {
        None | Some("") => DecisionFilter::Pending,
        Some("any") => DecisionFilter::All,
        Some("pending") => DecisionFilter::Exactly("pending"),
        Some("accepted") => DecisionFilter::Exactly("accepted"),
        Some("dismissed") => DecisionFilter::Exactly("dismissed"),
        Some(_) => return respond::error(StatusCode::BAD_REQUEST, "malformed-decision"),
    };
    let limit = limit_param(&params, ADVICE_DEFAULT_LIMIT, ADVICE_MAX_LIMIT);

    let outcome = state
        .db
        .read(
            move |connection| -> Result<Option<Vec<wire_r2::AdviceRecord>>, StoreError> {
                if !store::accounts::exists(connection, account_id)? {
                    return Ok(None);
                }
                let rows = store::advice::list(connection, account_id, filter, limit)?;
                Ok(Some(
                    rows.into_iter()
                        .map(|row| wire_r2::AdviceRecord {
                            id: row.id,
                            account_id: row.account_id,
                            remote_id: row.remote_id,
                            advice: wire_r2::Advice {
                                action: row.action,
                                category: row.category,
                                confidence: row.confidence,
                                rationale: row.rationale,
                                due_text: row.due_text,
                            },
                            source: row.source,
                            model: row.model,
                            decision: row.decision,
                            created_at: row.created_at,
                            decided_at: row.decided_at,
                        })
                        .collect(),
                ))
            },
        )
        .await;

    match outcome {
        Ok(Some(advice)) => respond::json(StatusCode::OK, &wire_r2::AdviceListResponse { advice }),
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => internal_error("advice.error", error),
    }
}

/// GET /api/advice/accepted-stats - the user's accepted-advice preferences.
pub async fn accepted_stats(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };

    let outcome = state
        .db
        .read(
            move |connection| -> Result<Option<Vec<wire_r2::AcceptedAdviceStat>>, StoreError> {
                if !store::accounts::exists(connection, account_id)? {
                    return Ok(None);
                }
                let stats =
                    store::advice::accepted_stats(connection, account_id, ADVICE_STATS_LIMIT)?;
                Ok(Some(
                    stats
                        .into_iter()
                        .map(|stat| wire_r2::AcceptedAdviceStat {
                            category: stat.category,
                            action: stat.action,
                            count: stat.count,
                        })
                        .collect(),
                ))
            },
        )
        .await;

    match outcome {
        Ok(Some(stats)) => respond::json(
            StatusCode::OK,
            &wire_r2::AcceptedAdviceStatsResponse { stats },
        ),
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => internal_error("advice.stats.error", error),
    }
}

/// GET /api/stacks - the user's filing rules with their row counts.
///
/// No account existence check, on purpose: v3's handler does not have one, and
/// an unknown-but-well-formed id therefore answers an empty list rather than 404.
pub async fn stacks(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };

    let outcome = state
        .db
        .read(
            move |connection| -> Result<Vec<wire_r2::StackSummary>, StoreError> {
                let rules = store::stacks::list(connection, account_id)?;
                let mut summaries = Vec::with_capacity(rules.len());
                for rule in rules {
                    let count = store::stacks::message_count(connection, &rule)?;
                    summaries.push(wire_r2::StackSummary {
                        rule: wire_r2::StackRule {
                            id: rule.id,
                            account_id: rule.account_id,
                            name: rule.name,
                            kind: rule.kind,
                            value: rule.value,
                            created_at: rule.created_at,
                        },
                        count,
                    });
                }
                Ok(summaries)
            },
        )
        .await;

    match outcome {
        Ok(stacks) => respond::json(StatusCode::OK, &wire_r2::StackRuleListResponse { stacks }),
        Err(error) => internal_error("stacks.error", error),
    }
}

/// GET /api/sent - the local sent list.
///
/// v3 refreshes from the IMAP Sent folder first and, when that fails, still
/// answers the local list with a staleReason. R2 has no provider at all, so the
/// refresh always fails the same way the fixture records: zero rows refreshed,
/// staleReason "not-configured", HTTP 200.
pub async fn sent(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    let limit = limit_param(&params, SENT_MAX_ROWS, SENT_MAX_ROWS);
    let body_key = Arc::clone(&state.body_key);

    let outcome = state
        .db
        .read(move |connection| -> Result<Option<(Vec<crate::wire::MessageHeader>, i64)>, StoreError> {
            if !store::accounts::exists(connection, account_id)? {
                return Ok(None);
            }
            let filter = store::messages::MessageFilter {
                sent: true,
                ..store::messages::MessageFilter::inbox(account_id)
            };
            let messages = store::messages::recent(connection, &filter, limit)?;
            let total = store::messages::count(connection, &filter)?;
            Ok(Some((
                messages
                    .into_iter()
                    .map(|message| routes::to_wire_header(&body_key, message))
                    .collect(),
                total,
            )))
        })
        .await;

    match outcome {
        Ok(Some((messages, total_count))) => respond::json(
            StatusCode::OK,
            &wire_r2::SentResponse {
                messages,
                total_count,
                refreshed_from_server: 0,
                stale_reason: Some("not-configured".to_owned()),
            },
        ),
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => internal_error("sent.error", error),
    }
}

/// GET /api/store-notices - one-shot notices about the local store.
///
/// v3 writes a body-key-lost notice here when it holds sealed bodies but no key.
/// R2 cannot write, and it cannot even reach that state: the binary refuses to
/// start without LAGOON_BODY_KEY, so the notice-raising branch is unreachable
/// rather than skipped.
pub async fn store_notices(State(state): State<AppState>) -> Response {
    let outcome = state
        .db
        .read(
            |connection| -> Result<Vec<wire_r2::StoreNotice>, StoreError> {
                Ok(store::notices::list(connection)?
                    .into_iter()
                    .map(|row| wire_r2::StoreNotice {
                        id: row.id,
                        created_at: row.created_at,
                        detail: row.detail,
                    })
                    .collect())
            },
        )
        .await;

    match outcome {
        Ok(notices) => respond::json(
            StatusCode::OK,
            &wire_r2::StoreNoticeListResponse { notices },
        ),
        Err(error) => internal_error("store-notices.error", error),
    }
}

/// Local midnight as an instant, the way Calendar.startOfDay means it.
fn local_midnight(date: chrono::NaiveDate) -> Timestamp {
    let naive = date
        .and_hms_opt(0, 0, 0)
        .expect("midnight is always a valid time");
    match chrono::Local.from_local_datetime(&naive).earliest() {
        Some(datetime) => Timestamp::from_millis(datetime.timestamp_millis()),
        // A DST jump can delete local midnight; fall back to reading the
        // wall-clock value as UTC rather than failing the report.
        None => Timestamp::from_millis(naive.and_utc().timestamp_millis()),
    }
}

fn local_date(timestamp: Timestamp) -> chrono::NaiveDate {
    chrono::Local
        .timestamp_millis_opt(timestamp.millis())
        .single()
        .map(|datetime| datetime.date_naive())
        .unwrap_or_else(|| {
            chrono::Utc
                .timestamp_millis_opt(timestamp.millis())
                .single()
                .map(|datetime| datetime.date_naive())
                .unwrap_or_else(|| chrono::NaiveDate::from_ymd_opt(1970, 1, 1).expect("epoch"))
        })
}

/// v3 TimeSavedEstimates.minutesPerAction.
fn minutes_per_action(kind: &str) -> f64 {
    match kind {
        "archive" => 0.5,
        "unsubscribe" | "send" => 2.0,
        _ => 0.0,
    }
}

fn is_handled(kind: &str) -> bool {
    matches!(kind, "archive" | "unsubscribe" | "send")
}

#[derive(Default)]
struct WindowAccumulator {
    minutes: f64,
    handled: i64,
    sent: i64,
    unsubscribed: i64,
}

impl WindowAccumulator {
    fn add(&mut self, kind: &str) {
        self.minutes += minutes_per_action(kind);
        if is_handled(kind) {
            self.handled += 1;
        }
        if kind == "send" {
            self.sent += 1;
        }
        if kind == "unsubscribe" {
            self.unsubscribed += 1;
        }
    }

    fn finish(self, by_day: Vec<wire_r2::TimeSavedDay>) -> wire_r2::TimeSavedWindow {
        wire_r2::TimeSavedWindow {
            // v3 rounds to one decimal so the badge never shows float noise.
            minutes_saved: (self.minutes * 10.0).round() / 10.0,
            messages_handled: self.handled,
            drafts_sent: self.sent,
            unsubscribed: self.unsubscribed,
            by_day,
        }
    }
}

/// GET /api/time-saved - minutes saved, derived entirely from the audit log.
pub async fn time_saved(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };

    let today_date = chrono::Local::now().date_naive();
    let today_start = local_midnight(today_date);
    let week_start = local_midnight(today_date - chrono::Days::new(6));

    let outcome = state
        .db
        .read(
            move |connection| -> Result<wire_r2::TimeSavedReport, StoreError> {
                let events = store::actions::time_saved_events(connection, account_id, week_start)?;
                let mut today = WindowAccumulator::default();
                let mut week = WindowAccumulator::default();
                let mut by_day: std::collections::BTreeMap<chrono::NaiveDate, WindowAccumulator> =
                    std::collections::BTreeMap::new();
                for (kind, created_at) in events {
                    week.add(&kind);
                    if created_at.millis() >= today_start.millis() {
                        today.add(&kind);
                    }
                    // v3 creates a by-day entry for every event, even one whose kind
                    // saves no time (a pin shows up as a 0-minute day).
                    by_day.entry(local_date(created_at)).or_default().add(&kind);
                }
                let by_day: Vec<wire_r2::TimeSavedDay> = by_day
                    .into_iter()
                    .map(|(date, accumulator)| wire_r2::TimeSavedDay {
                        date: local_midnight(date),
                        minutes_saved: (accumulator.minutes * 10.0).round() / 10.0,
                        messages_handled: accumulator.handled,
                    })
                    .collect();
                Ok(wire_r2::TimeSavedReport {
                    today: today.finish(Vec::new()),
                    week: week.finish(by_day),
                })
            },
        )
        .await;

    match outcome {
        Ok(report) => respond::json(StatusCode::OK, &report),
        Err(error) => internal_error("time-saved.error", error),
    }
}

/// GET /api/usage - the AI ledger for this calendar month.
pub async fn usage(State(state): State<AppState>) -> Response {
    let month = chrono::Local::now().format("%Y-%m").to_string();
    let cap_usd = state.budget_cap_usd;
    let outcome = state
        .db
        .read(
            move |connection| -> Result<wire_r2::UsageReport, StoreError> {
                let summary = store::usage::month_summary(connection, &month)?;
                // v3 degrades a failed breakdown to an empty list: the headline total
                // is what the cap is about, and it is already in hand.
                let breakdown =
                    store::usage::account_breakdown(connection, &month).unwrap_or_default();
                Ok(wire_r2::UsageReport {
                    month_usd: summary.cost_micro_usd as f64 / 1_000_000.0,
                    cap_usd,
                    call_count: summary.call_count,
                    cost_tracking_available: false,
                    accounts: breakdown
                        .into_iter()
                        .map(|share| wire_r2::UsageAccountShare {
                            account_email: share.account_email,
                            month_usd: share.cost_micro_usd as f64 / 1_000_000.0,
                            call_count: share.calls,
                        })
                        .collect(),
                })
            },
        )
        .await;

    match outcome {
        Ok(report) => respond::json(StatusCode::OK, &report),
        Err(error) => internal_error("usage.error", error),
    }
}

/// GET /api/actions - the audit log, newest first, with keyset paging.
pub async fn actions(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    let since = since_param(&params);
    let limit = limit_param(&params, ACTIONS_DEFAULT_LIMIT, ACTIONS_MAX_LIMIT);

    let before = match query::get(&params, "before") {
        Some(raw) => match raw.trim().parse::<i64>() {
            Ok(id) if id > 0 => Some(id),
            _ => return respond::error(StatusCode::BAD_REQUEST, "malformed-before"),
        },
        None => None,
    };

    let outcome = state
        .db
        .read(move |connection| -> Result<ActionsOutcome, StoreError> {
            let cursor: Option<Cursor> = match before {
                Some(id) => match store::actions::cursor(connection, id, account_id)? {
                    Some(cursor) => Some(cursor),
                    None => return Ok(ActionsOutcome::UnknownBefore),
                },
                None => None,
            };
            let page = store::actions::page(connection, account_id, since, cursor.as_ref(), limit)?;
            Ok(ActionsOutcome::Page(page))
        })
        .await;

    match outcome {
        Ok(ActionsOutcome::UnknownBefore) => {
            respond::error(StatusCode::BAD_REQUEST, "unknown-before")
        }
        Ok(ActionsOutcome::Page(page)) => respond::json(
            StatusCode::OK,
            &wire_r2::AIActionListResponse {
                actions: page
                    .actions
                    .into_iter()
                    .map(|row| wire_r2::AIAction {
                        id: row.id,
                        account_id: row.account_id,
                        kind: row.kind,
                        payload: row.payload,
                        created_at: row.created_at,
                        expires_at: row.expires_at,
                    })
                    .collect(),
                total_count: page.total_count,
                has_more: page.has_more,
            },
        ),
        Err(error) => internal_error("actions.error", error),
    }
}

enum ActionsOutcome {
    Page(store::actions::Page),
    UnknownBefore,
}

/// GET /api/reminders - active reminders by default, all of them on request.
pub async fn reminders(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    let include_dismissed = query::get(&params, "includeDismissed") == Some("true");

    let outcome = state
        .db
        .read(
            move |connection| -> Result<Option<Vec<wire_r2::Reminder>>, StoreError> {
                if !store::accounts::exists(connection, account_id)? {
                    return Ok(None);
                }
                let rows = if include_dismissed {
                    store::reminders::all(connection, account_id)?
                } else {
                    store::reminders::pending(connection, account_id)?
                };
                Ok(Some(
                    rows.into_iter()
                        .map(|row| wire_r2::Reminder {
                            id: row.id,
                            account_id: row.account_id,
                            remote_id: row.remote_id,
                            subject: row.subject,
                            due_at: row.due_at,
                            note: row.note,
                            created_at: row.created_at,
                            dismissed_at: row.dismissed_at,
                        })
                        .collect(),
                ))
            },
        )
        .await;

    match outcome {
        Ok(Some(reminders)) => {
            respond::json(StatusCode::OK, &wire_r2::ReminderListResponse { reminders })
        }
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => internal_error("reminders.error", error),
    }
}

/// GET /api/export/index - every header, oldest first, for the export bundle.
pub async fn export_index(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    let body_key = Arc::clone(&state.body_key);

    let outcome = state
        .db
        .read(
            move |connection| -> Result<Option<wire_r2::ExportIndexResponse>, StoreError> {
                if !store::accounts::exists(connection, account_id)? {
                    return Ok(None);
                }
                let rows = store::messages::export_index(connection, account_id)?;
                let total_count = rows.len() as i64;
                let (deleted_count, sent_count) =
                    store::messages::deleted_and_sent_counts(connection, account_id)?;
                Ok(Some(wire_r2::ExportIndexResponse {
                    messages: rows
                        .into_iter()
                        .map(|message| routes::to_wire_header(&body_key, message))
                        .collect(),
                    total_count,
                    deleted_count,
                    sent_count,
                }))
            },
        )
        .await;

    match outcome {
        Ok(Some(index)) => respond::json(StatusCode::OK, &index),
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Err(error) => internal_error("export.index.error", error),
    }
}

/// GET /api/search - the corrected two-pass search.
pub async fn search(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let scope = match query::get(&params, "accountId") {
        None | Some("") => return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId"),
        Some("all") => Scope::All,
        Some(raw) => match Uuid::parse_strict(raw) {
            Some(account_id) => Scope::Account(account_id),
            None => return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId"),
        },
    };
    let needle = query::get(&params, "q").unwrap_or("").trim().to_owned();
    if needle.is_empty() {
        // v3 answers an empty result set for an empty query instead of scanning.
        return respond::json(
            StatusCode::OK,
            &wire_r2::SearchResponse {
                results: Vec::new(),
                query: needle,
                total_count: 0,
                truncated: false,
                body_scan_skipped: 0,
                body_scan_limit: store::search::BODY_SCAN_LIMIT,
            },
        );
    }
    let sender = query::get(&params, "sender").map(str::to_owned);
    let since = since_param(&params);
    let body_key = Arc::clone(&state.body_key);
    let reported_query = needle.clone();

    let key_for_read = Arc::clone(&body_key);
    let outcome = state
        .db
        .read(move |connection| {
            store::search::search(
                connection,
                &key_for_read,
                scope,
                &needle,
                sender.as_deref(),
                since,
            )
        })
        .await;

    match outcome {
        Ok(outcome) => {
            let results: Vec<crate::wire::MessageHeader> = outcome
                .results
                .into_iter()
                .map(|message| routes::to_wire_header(&body_key, message))
                .collect();
            respond::json(
                StatusCode::OK,
                &wire_r2::SearchResponse {
                    truncated: outcome.total_count > results.len() as i64,
                    total_count: outcome.total_count,
                    body_scan_skipped: outcome.body_scan_skipped,
                    body_scan_limit: store::search::BODY_SCAN_LIMIT,
                    query: reported_query,
                    results,
                },
            )
        }
        Err(error) => {
            // Searching the sealed arms needs the body key: a store sealed with
            // a different key makes the query unanswerable, and the honest
            // answer is a server error rather than "no matches".
            tracing::error!(err = %error, "search.error");
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    }
}

/// GET /api/messages/{remoteId}/drafts - the stored reply variants.
pub async fn drafts(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    uri: Uri,
) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    if remote_id.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-remoteId");
    }
    let body_key = Arc::clone(&state.body_key);
    let outcome = state
        .db
        .read(move |connection| -> Result<DraftsOutcome, StoreError> {
            match store::drafts::list(connection, &body_key, account_id, &remote_id) {
                Ok(rows) => Ok(DraftsOutcome::List(rows)),
                Err(store::drafts::DraftError::Unreadable(error)) => {
                    tracing::error!(err = %error, "drafts.unreadable");
                    Ok(DraftsOutcome::Unreadable)
                }
                Err(store::drafts::DraftError::Malformed) => {
                    tracing::error!("drafts.malformed");
                    Ok(DraftsOutcome::Unreadable)
                }
                Err(store::drafts::DraftError::Sqlite(error)) => Err(StoreError::Sqlite(error)),
            }
        })
        .await;

    match outcome {
        Ok(DraftsOutcome::List(rows)) => respond::json(
            StatusCode::OK,
            &wire_r2::DraftListResponse {
                drafts: rows
                    .into_iter()
                    .map(|row| wire_r2::DraftReply {
                        id: row.id,
                        account_id: row.account_id,
                        remote_id: row.remote_id,
                        variants: row.variants,
                        chosen_variant: row.chosen_variant,
                        created_at: row.created_at,
                    })
                    .collect(),
            },
        ),
        // v3 refuses the list rather than dropping the unreadable row: "three
        // drafts, one broken" must not look like "two drafts".
        Ok(DraftsOutcome::Unreadable) => {
            respond::error(StatusCode::INTERNAL_SERVER_ERROR, "draft-unreadable")
        }
        Err(error) => internal_error("drafts.error", error),
    }
}

enum DraftsOutcome {
    List(Vec<store::drafts::DraftRow>),
    Unreadable,
}

/// The account-existence gate every provider-backed route runs before it needs
/// a provider. Some(Response) means "answer this and stop".
async fn provider_gate(
    state: &AppState,
    account_id: Uuid,
    label: &'static str,
) -> Option<Response> {
    let outcome = state
        .db
        .read(move |connection| -> Result<bool, StoreError> {
            store::accounts::exists(connection, account_id)
        })
        .await;
    match outcome {
        Ok(true) => None,
        Ok(false) => Some(respond::error(StatusCode::NOT_FOUND, "unknown-account")),
        Err(error) => Some(internal_error(label, error)),
    }
}

fn parse_remote_id(remote_id: &str) -> Option<Response> {
    if remote_id.is_empty() {
        Some(respond::error(
            StatusCode::BAD_REQUEST,
            "malformed-remoteId",
        ))
    } else {
        None
    }
}

/// GET /api/messages/{remoteId}/inline-images - cid images as data URLs.
pub async fn inline_images(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    uri: Uri,
) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    if let Some(response) = parse_remote_id(&remote_id) {
        return response;
    }
    if let Some(response) = provider_gate(&state, account_id, "inline-images.error").await {
        return response;
    }
    respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured")
}

/// GET /api/messages/{remoteId}/raw.eml - the original message bytes.
pub async fn raw_eml(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    uri: Uri,
) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    if let Some(response) = parse_remote_id(&remote_id) {
        return response;
    }
    if let Some(response) = provider_gate(&state, account_id, "raw-eml.error").await {
        return response;
    }
    respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured")
}

/// POST /api/messages/{remoteId}/archive - the capability gate, then the write.
///
/// The capability check happens **before** any provider work, so a server that
/// has no archive folder answers 409 archive-unavailable on a read-only
/// deployment: the client must say "this server cannot archive", not "the
/// network failed". Only after the gate would the remote move begin, and R2 has
/// no provider to perform it.
pub async fn archive(
    State(state): State<AppState>,
    Path(remote_id): Path<String>,
    uri: Uri,
) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    if let Some(response) = parse_remote_id(&remote_id) {
        return response;
    }

    let outcome = state
        .db
        .read(move |connection| -> Result<Option<bool>, StoreError> {
            match store::accounts::find(connection, account_id)? {
                None => Ok(None),
                Some(account) => {
                    // Three-state read: only a confirmed false closes the gate
                    // (recon/server-contract.md §2).
                    Ok(Some(account.capabilities.archive_folder != Some(false)))
                }
            }
        })
        .await;

    match outcome {
        Ok(None) => respond::error(StatusCode::NOT_FOUND, "unknown-account"),
        Ok(Some(false)) => respond::error(StatusCode::CONFLICT, "archive-unavailable"),
        Ok(Some(true)) => {
            respond::error(StatusCode::SERVICE_UNAVAILABLE, "provider-not-configured")
        }
        Err(error) => internal_error("archive.error", error),
    }
}

enum BriefingOutcome {
    Feed {
        items: Vec<wire_r2::BriefingItem>,
        omitted: i64,
        backlog_total: i64,
    },
    UnknownAccount,
}

/// GET /api/briefing - the feed: window rows plus the unread backlog.
///
/// v3 also prunes dismissed advice older than 30 days on this route. R2 is
/// read-only, so the prune is the one difference: it deletes stored rows, and a
/// process without a write path cannot.
pub async fn briefing(State(state): State<AppState>, uri: Uri) -> Response {
    let params = query::parse(&uri);
    let Some(account_id) = account_id_param(&params) else {
        return respond::error(StatusCode::BAD_REQUEST, "malformed-accountId");
    };
    let requested = query::get(&params, "limit")
        .and_then(|raw| raw.trim().parse::<i64>().ok())
        .unwrap_or(BRIEFING_MAX);
    let limit = requested.clamp(1, BRIEFING_MAX);
    let now = timefmt::now();
    let window_start =
        Timestamp::from_millis(now.millis() - store::briefing::WINDOW_DAYS * 24 * 60 * 60 * 1000);
    let body_key = Arc::clone(&state.body_key);

    let outcome = state
        .db
        .read(move |connection| -> Result<BriefingOutcome, StoreError> {
            let Some(account) = store::accounts::find(connection, account_id)? else {
                return Ok(BriefingOutcome::UnknownAccount);
            };
            let snapshot = store::briefing::snapshot(connection, account_id, window_start, limit)?;
            let pinned = store::briefing::pinned_ids(connection, account_id)?;
            let list_unsubscribe = store::briefing::list_unsubscribe_ids(connection, account_id)?;
            let replied = store::actions::replied_remote_ids(connection, account_id)?;
            let message_pairs = store::actions::overrides_by_message(connection, account_id)?;
            let sender_pairs = store::actions::overrides_by_sender(connection, account_id)?;

            let resolver =
                briefing::Resolver::from_store(&message_pairs, &sender_pairs, pinned.clone());
            let signals = briefing::Signals {
                pinned_remote_ids: pinned,
                list_unsubscribe_remote_ids: list_unsubscribe,
                replied_remote_ids: replied,
            };

            let mut items = Vec::with_capacity(snapshot.messages.len() + snapshot.backlog.len());
            for message in snapshot.messages.iter().chain(snapshot.backlog.iter()) {
                let fallback = briefing::classify(message, &account.email, &signals, now);
                let (group, reason) = resolver.resolve(message, fallback);
                items.push(wire_r2::BriefingItem {
                    message: routes::to_wire_header(&body_key, message.clone()),
                    group: group.as_str().to_owned(),
                    reason_code: Some(reason.as_str().to_owned()),
                });
            }

            Ok(BriefingOutcome::Feed {
                items,
                omitted: snapshot.omitted(),
                backlog_total: snapshot.backlog_total,
            })
        })
        .await;

    match outcome {
        Ok(BriefingOutcome::Feed {
            items,
            omitted,
            backlog_total,
        }) => respond::json(
            StatusCode::OK,
            &wire_r2::BriefingResponse {
                // v3 omits both counters at zero: an absent key means "nothing
                // withheld", and the client renders no line for it.
                omitted_count: if omitted == 0 { None } else { Some(omitted) },
                backlog_count: if backlog_total == 0 {
                    None
                } else {
                    Some(backlog_total)
                },
                items,
            },
        ),
        Ok(BriefingOutcome::UnknownAccount) => {
            respond::error(StatusCode::NOT_FOUND, "unknown-account")
        }
        Err(error) => internal_error("briefing.error", error),
    }
}
