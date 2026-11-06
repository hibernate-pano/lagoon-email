//! The AI routes: the read-only advisor's front door.
//!
//! Three answers live here, and they are the whole product promise of the AI
//! plane (constitution §2):
//!
//! * `GET /api/ai-status` - what the AI can do right now, truthfully.
//! * `GET /api/messages/{id}/summary` - what this mail says.
//! * `POST /api/messages/{id}/draft` - words to start a reply with.
//!
//! None of them writes to the mailbox. The draft is text the user edits and
//! sends with their own click; the summary is a reading aid. That is the
//! whole point of the constitution, and it is why this file has no SMTP
//! import at all.
//!
//! The two configuration routes (`POST /api/ai/reload`, `POST /api/ai/probe`)
//! are the user's "I fixed it, try again" buttons.

use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::{StatusCode, Uri};
use axum::response::Response;

use crate::ai::config::{AiConfig, AiConfigError};
use crate::ai::gateway::{AiError, AiGateway};
use crate::http::query;
use crate::http::respond;
use crate::http::AppState;
use crate::provider::ProviderError;
use crate::store::{self, StoreError};
use crate::uuid::Uuid;
use crate::wire_r2;

/// The system prompt for a summary.
///
/// It states the constitution in one sentence (the AI reads, it does not
/// act), and it pins the output shape: one JSON object, nothing else. The
/// "nothing else" matters - a model that answers with prose plus JSON would
/// otherwise show the user the prose.
const SUMMARY_SYSTEM: &str = "\
你是一个只读的邮件助理。你只能读和解释这封邮件，不能执行任何动作：不能发送邮件、不能归档、不能删除、不能修改邮件状态。
用中文回答，并且只输出一个 JSON 对象，不要有任何多余文字：
{\"summary\": \"不超过 80 个字，说明这封邮件要用户做什么，或不需要做什么\", \"actionItems\": [\"需要用户自己去做的事，最多 3 条，没有就空数组\"]}";

/// The system prompt for a draft.
///
/// The draft is text, not an action: the model must not write as if it had
/// sent anything, and the user edits before sending.
const DRAFT_SYSTEM: &str = "\
你是一个只读的邮件助理，为用户起草回复的**文本草稿**。草稿只是文字，用户会自己修改并亲自发送；你不能发送任何邮件。
用中文回答，并且只输出一个 JSON 数组，不要有任何多余文字：
[\"草稿一\", \"草稿二\", \"草稿三\"]（2 到 3 条，风格不同：直接、委婉、简短各一）";

/// How much of the mail goes into the prompt. A long mail costs tokens and
/// the tail is rarely the point; 6000 characters is several screens.
const MAX_BODY_CHARS: usize = 6000;

/// GET /api/ai-status - the degraded signal.
///
/// The three flags are booleans, not absent keys: v3's AIStatus has no
/// optional field, and the client reads `configured == false` as "the AI
/// features are off". What changed in R4 is that the answer is now real: it
/// says whether a key is really there, whether the provider says there is no
/// credit left, and whether we stopped asking because it keeps failing.
pub async fn ai_status(State(state): State<AppState>) -> Response {
    let status = state.ai.status();
    respond::json(
        StatusCode::OK,
        &wire_r2::AIStatus {
            configured: status.configured,
            credit_exhausted: status.credit_exhausted,
            circuit_open: status.circuit_open,
        },
    )
}

/// GET /api/messages/{remoteId}/summary - the AI summary.
///
/// The order of the gates is the contract's: the mail has to exist, the body
/// has to be readable, and only then does the model get a say. A summary of
/// nothing is not a summary.
pub async fn summary(
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

    let header = match header_lookup(&state, account_id, &remote_id).await {
        HeaderLookup::Found(header) => header,
        HeaderLookup::UnknownAccount => {
            return respond::error(StatusCode::NOT_FOUND, "unknown-account")
        }
        HeaderLookup::UnknownMessage => {
            return respond::error(StatusCode::NOT_FOUND, "unknown-message")
        }
        HeaderLookup::Failed => {
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    };

    // A summary we already paid for is the answer, with or without a model.
    if let Some(cached) = cached_summary(&state, account_id, &remote_id).await {
        return respond::json(
            StatusCode::OK,
            &wire_r2::MessageSummary {
                remote_id: remote_id.clone(),
                summary: cached.summary,
                action_items: cached.action_items,
                provider: cached.model,
            },
        );
    }

    let body = match body_text(&state, account_id, &remote_id).await {
        Ok(text) => text,
        Err(response) => return response,
    };

    let prompt = summary_prompt(&header, &body);
    let completion = match state.ai.complete("summary", SUMMARY_SYSTEM, &prompt).await {
        Ok(completion) => completion,
        Err(error) => return ai_error_response(error),
    };

    let (text, action_items) = parse_summary(&completion.text);
    // The cache write is best effort: a summary the user is looking at must
    // not fail because the disk said no.
    if let Err(error) = save_summary(
        &state,
        account_id,
        &remote_id,
        &text,
        &action_items,
        &completion.model,
    )
    .await
    {
        tracing::warn!(err = %error, "summary.cacheWriteFailed");
    }
    record_usage(
        &state,
        Some(account_id),
        "summary",
        &completion.model,
        completion.prompt_tokens,
        completion.completion_tokens,
        completion.cost_micro_usd,
    )
    .await;

    respond::json(
        StatusCode::OK,
        &wire_r2::MessageSummary {
            remote_id: remote_id.clone(),
            summary: text,
            action_items,
            provider: Some(completion.model),
        },
    )
}

/// POST /api/messages/{remoteId}/draft - generate reply variants.
///
/// The variants are stored (sealed) so the list route can show them again,
/// and the answer is the bare `DraftReply` the contract promises - not an
/// envelope.
pub async fn draft_generate(
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

    let header = match header_lookup(&state, account_id, &remote_id).await {
        HeaderLookup::Found(header) => header,
        HeaderLookup::UnknownAccount => {
            return respond::error(StatusCode::NOT_FOUND, "unknown-account")
        }
        HeaderLookup::UnknownMessage => {
            return respond::error(StatusCode::NOT_FOUND, "unknown-message")
        }
        HeaderLookup::Failed => {
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error")
        }
    };

    let body = match body_text(&state, account_id, &remote_id).await {
        Ok(text) => text,
        Err(response) => return response,
    };

    let prompt = summary_prompt(&header, &body);
    let completion = match state.ai.complete("draft", DRAFT_SYSTEM, &prompt).await {
        Ok(completion) => completion,
        Err(error) => return ai_error_response(error),
    };

    // The call happened, so the money was spent: record it before deciding
    // whether the answer is usable. An answer we throw away is still a bill.
    record_usage(
        &state,
        Some(account_id),
        "draft",
        &completion.model,
        completion.prompt_tokens,
        completion.completion_tokens,
        completion.cost_micro_usd,
    )
    .await;

    let variants = parse_variants(&completion.text);
    if variants.is_empty() {
        // The model answered with something we cannot use. Saying so is
        // better than storing an empty draft the user would read as "the AI
        // had nothing to say".
        return respond::error(StatusCode::BAD_GATEWAY, "ai-error");
    }

    let created = store_draft(&state, account_id, &remote_id, &variants).await;
    let draft = match created {
        Ok(draft) => draft,
        Err(error) => {
            tracing::error!(err = %error, "draft.createFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    };

    respond::json(StatusCode::OK, &draft)
}

/// POST /api/ai/reload - read the configuration again.
///
/// The user's "I fixed it, try again": it re-reads the provider file and
/// forgets the degraded state, so a key that has just been set, or a
/// provider that has just come back, is really tried again.
pub async fn ai_reload(State(state): State<AppState>) -> Response {
    let config = match AiConfig::load_current() {
        Ok(config) => config,
        Err(error) => {
            tracing::error!(err = %error, "ai.reloadFailed");
            return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "internal-error");
        }
    };
    let providers = config.provider_names();
    state.ai.reload(config);
    let status = state.ai.status();
    respond::json(
        StatusCode::OK,
        &wire_r2::AiReloadResponse {
            ok: true,
            configured: status.configured,
            providers,
        },
    )
}

/// POST /api/ai/probe - one tiny call, to find out whether the AI works.
///
/// The cheapest question that gets an honest answer: "are you there?". The
/// user needs to know the difference between "no key" and "the provider is
/// down", and a probe is the only way to tell.
pub async fn ai_probe(State(state): State<AppState>) -> Response {
    match state.ai.probe().await {
        Ok(probe) => {
            // The probe is a model call: the provider bills it, so the ledger
            // has to know or the monthly cap is blind to it.
            record_usage(
                &state,
                None,
                "probe",
                &probe.model,
                probe.prompt_tokens,
                probe.completion_tokens,
                probe.cost_micro_usd,
            )
            .await;
            respond::json(
                StatusCode::OK,
                &wire_r2::AiProbeResponse {
                    ok: true,
                    provider: probe.provider,
                    model: probe.model,
                    latency_ms: probe.latency_ms,
                },
            )
        }
        Err(error) => ai_error_response(error),
    }
}

// ------------------------------------------------------------------ helpers ----

/// The header of the message, if it exists.
///
/// The header is boxed: the success payload is a whole stored row, and the
/// other three variants are exit codes - without the box every `HeaderLookup`
/// on the stack would carry a row's worth of bytes.
enum HeaderLookup {
    Found(Box<crate::store::messages::StoredMessage>),
    UnknownAccount,
    UnknownMessage,
    Failed,
}

async fn header_lookup(state: &AppState, account_id: Uuid, remote_id: &str) -> HeaderLookup {
    let remote_id = remote_id.to_owned();
    let outcome = state
        .db
        .read(move |connection| -> Result<HeaderLookup, StoreError> {
            if !store::accounts::exists(connection, account_id)? {
                return Ok(HeaderLookup::UnknownAccount);
            }
            match store::messages::find(connection, account_id, &remote_id) {
                Ok(Some(header)) => Ok(HeaderLookup::Found(Box::new(header))),
                Ok(None) => Ok(HeaderLookup::UnknownMessage),
                Err(error) => Err(StoreError::Sqlite(error)),
            }
        })
        .await;
    match outcome {
        Ok(found) => found,
        Err(error) => {
            tracing::error!(err = %error, "ai.headerLookupFailed");
            HeaderLookup::Failed
        }
    }
}

/// The cached summary, if this message has one.
async fn cached_summary(
    state: &AppState,
    account_id: Uuid,
    remote_id: &str,
) -> Option<store::summaries::SummaryRow> {
    let body_key = Arc::clone(&state.body_key);
    let remote_id = remote_id.to_owned();
    let outcome = state
        .db
        .read(
            move |connection| -> Result<Option<store::summaries::SummaryRow>, StoreError> {
                match store::summaries::find(connection, &body_key, account_id, &remote_id) {
                    Ok(row) => Ok(row),
                    Err(store::summaries::SummaryError::Sqlite(error)) => {
                        Err(StoreError::Sqlite(error))
                    }
                    // A summary that will not open is a cache miss, not a
                    // failure: the model can write a new one.
                    Err(_) => Ok(None),
                }
            },
        )
        .await;
    match outcome {
        Ok(row) => row,
        Err(error) => {
            tracing::error!(err = %error, "summary.readFailed");
            None
        }
    }
}

/// The mail's text: the cache first, the mailbox second.
///
/// The same order the body route uses, because it is the same question: "give
/// me the text of this mail". A body that is not cached and cannot be
/// fetched answers 503 - the server has no provider for that account.
async fn body_text(
    state: &AppState,
    account_id: Uuid,
    remote_id: &str,
) -> Result<String, Response> {
    let body_key = Arc::clone(&state.body_key);
    let remote_id_for_cache = remote_id.to_owned();
    let cached = state
        .db
        .read(move |connection| -> Result<Option<String>, StoreError> {
            let stored = store::bodies::find(connection, account_id, &remote_id_for_cache)?;
            Ok(match stored {
                Some(stored) => body_key.open(&stored.text_cipher).ok(),
                None => None,
            })
        })
        .await;
    let cached = match cached {
        Ok(text) => text,
        Err(error) => {
            tracing::error!(err = %error, "summary.bodyReadFailed");
            return Err(respond::error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal-error",
            ));
        }
    };
    if let Some(text) = cached {
        return Ok(text);
    }

    let Some(provider) = state.body_provider(account_id) else {
        return Err(respond::error(
            StatusCode::SERVICE_UNAVAILABLE,
            "provider-not-configured",
        ));
    };
    let remote_id_for_uid = remote_id.to_owned();
    let uid_hint = state
        .db
        .read(move |connection| {
            store::messages::inbox_remote_uid(connection, account_id, &remote_id_for_uid)
        })
        .await
        .ok()
        .flatten();
    match provider.fetch_body(remote_id, uid_hint).await {
        Ok(body) => Ok(body.text),
        Err(ProviderError::AuthFailed) => Err(respond::error(
            StatusCode::UNAUTHORIZED,
            "provider-auth-failed",
        )),
        Err(ProviderError::NotConfigured(_)) => Err(respond::error(
            StatusCode::SERVICE_UNAVAILABLE,
            "provider-not-configured",
        )),
        Err(ProviderError::MessageGone) => Err(respond::error(StatusCode::GONE, "message-gone")),
        Err(error) => {
            tracing::error!(err = %error, "summary.bodyFetchFailed");
            Err(respond::error(
                StatusCode::BAD_GATEWAY,
                "provider-unreachable",
            ))
        }
    }
}

/// The prompt: who wrote it, what is it about, what did it say.
fn summary_prompt(header: &crate::store::messages::StoredMessage, body: &str) -> String {
    let mut prompt = String::new();
    prompt.push_str("发件人：");
    match &header.from_name {
        Some(name) => prompt.push_str(&format!("{name} <{}>", header.from_address)),
        None => prompt.push_str(&header.from_address),
    }
    prompt.push_str("\n主题：");
    prompt.push_str(header.subject.as_deref().unwrap_or("（无主题）"));
    prompt.push_str("\n时间：");
    prompt.push_str(&crate::timefmt::to_iso8601(header.received_at));
    prompt.push_str("\n\n正文：\n");
    let body: String = body.chars().take(MAX_BODY_CHARS).collect();
    prompt.push_str(&body);
    if body.chars().count() < MAX_BODY_CHARS {
        // Not truncated; nothing to say.
    } else {
        prompt.push_str("\n（正文已截断）");
    }
    prompt
}

/// Read the model's answer: the summary and the action items.
///
/// A model that answered with prose instead of JSON still said something, and
/// showing it is better than a 502. The JSON path is the one we ask for and
/// the one we get.
fn parse_summary(raw: &str) -> (String, Vec<String>) {
    if let Some(value) = extract_json_object(raw) {
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&value) {
            let summary = parsed
                .get("summary")
                .and_then(|value| value.as_str())
                .map(str::to_owned)
                .unwrap_or_default();
            let action_items = parsed
                .get("actionItems")
                .and_then(|value| value.as_array())
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            if !summary.is_empty() {
                return (summary, action_items);
            }
        }
    }
    (raw.trim().to_owned(), Vec::new())
}

/// Read the model's answer as a list of draft variants.
fn parse_variants(raw: &str) -> Vec<String> {
    if let Some(value) = extract_json_array(raw) {
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&value) {
            if let Some(items) = parsed.as_array() {
                let variants: Vec<String> = items
                    .iter()
                    .filter_map(|item| item.as_str().map(str::to_owned))
                    .map(|item| item.trim().to_owned())
                    .filter(|item| !item.is_empty())
                    .collect();
                if !variants.is_empty() {
                    return variants;
                }
            }
        }
    }
    // Not JSON: one variant, the model's own words.
    let text = raw.trim();
    if text.is_empty() {
        Vec::new()
    } else {
        vec![text.to_owned()]
    }
}

/// The JSON object inside a model's answer (models like to wrap it in a
/// code fence or a sentence).
fn extract_json_object(raw: &str) -> Option<String> {
    let start = raw.find('{')?;
    let end = raw.rfind('}')?;
    if end <= start {
        return None;
    }
    Some(raw[start..=end].to_owned())
}

/// The JSON array inside a model's answer.
fn extract_json_array(raw: &str) -> Option<String> {
    let start = raw.find('[')?;
    let end = raw.rfind(']')?;
    if end <= start {
        return None;
    }
    Some(raw[start..=end].to_owned())
}

/// Store the summary so the next open of this mail is free.
async fn save_summary(
    state: &AppState,
    account_id: Uuid,
    remote_id: &str,
    summary: &str,
    action_items: &[String],
    model: &str,
) -> Result<(), String> {
    let connection = state
        .write_connection()
        .map_err(|error| error.to_string())?;
    let body_key = Arc::clone(&state.body_key);
    let remote_id = remote_id.to_owned();
    let summary = summary.to_owned();
    let action_items = action_items.to_vec();
    let model = model.to_owned();
    store::summaries::save(
        &connection,
        &body_key,
        account_id,
        &remote_id,
        &summary,
        &action_items,
        &model,
    )
    .map_err(|error| error.to_string())
}

/// Store the draft variants and answer the draft the contract promises.
async fn store_draft(
    state: &AppState,
    account_id: Uuid,
    remote_id: &str,
    variants: &[String],
) -> Result<wire_r2::DraftReply, String> {
    let connection = state
        .write_connection()
        .map_err(|error| error.to_string())?;
    let body_key = Arc::clone(&state.body_key);
    let remote_id = remote_id.to_owned();
    let variants = variants.to_vec();
    let id = store::drafts::insert(&connection, &body_key, account_id, &remote_id, &variants)
        .map_err(|error| error.to_string())?;
    let created_at = crate::timefmt::now();
    Ok(wire_r2::DraftReply {
        id,
        account_id,
        remote_id: remote_id.clone(),
        variants,
        chosen_variant: None,
        created_at,
    })
}

/// Write one row into the cost ledger.
///
/// `account_id` is `None` for a call that belongs to no mailbox (the probe).
/// The row is still written: the budget gate reads only this ledger, so an
/// unrecorded call is spend the monthly cap cannot see.
async fn record_usage(
    state: &AppState,
    account_id: Option<Uuid>,
    capability: &str,
    model: &str,
    prompt_tokens: u32,
    completion_tokens: u32,
    cost_micro_usd: i64,
) {
    let month = chrono::Local::now().format("%Y-%m").to_string();
    let email = match account_id {
        Some(account_id) => state
            .db
            .read(move |connection| -> Result<String, StoreError> {
                Ok(store::accounts::find(connection, account_id)?
                    .map(|account| account.email)
                    .unwrap_or_default())
            })
            .await
            .unwrap_or_default(),
        // No mailbox: the probe asks "is the provider there?", not "what is in
        // this inbox". An empty label keeps the sum correct.
        None => String::new(),
    };
    let connection = match state.write_connection() {
        Ok(connection) => connection,
        Err(error) => {
            tracing::error!(err = %error, "usage.writeOpenFailed");
            return;
        }
    };
    if let Err(error) = store::usage::record(
        &connection,
        &store::usage::UsageRecord {
            year_month: &month,
            account_email: &email,
            capability,
            model,
            prompt_tokens,
            completion_tokens,
            cost_micro_usd,
        },
    ) {
        tracing::error!(err = %error, "usage.recordFailed");
    }
}

/// The gateway's failures, in the contract's codes.
fn ai_error_response(error: AiError) -> Response {
    match error {
        AiError::NotConfigured(reason) => {
            tracing::info!(reason = %reason, "ai.notConfigured");
            respond::error(StatusCode::SERVICE_UNAVAILABLE, "ai-not-configured")
        }
        AiError::CreditExhausted => {
            respond::error(StatusCode::SERVICE_UNAVAILABLE, "ai-credit-exhausted")
        }
        AiError::BudgetExceeded => {
            tracing::info!("ai.budgetExceeded");
            respond::error(StatusCode::SERVICE_UNAVAILABLE, "ai-budget-exceeded")
        }
        AiError::CircuitOpen => respond::error(StatusCode::SERVICE_UNAVAILABLE, "ai-circuit-open"),
        AiError::Unreachable(reason) => {
            tracing::error!(reason = %reason, "ai.unreachable");
            respond::error(StatusCode::BAD_GATEWAY, "provider-unreachable")
        }
        AiError::Provider(reason) => {
            tracing::error!(reason = %reason, "ai.providerFailed");
            respond::error(StatusCode::BAD_GATEWAY, "ai-error")
        }
    }
}

/// The gateway the state carries, for the routes that need to reload it.
pub fn gateway(state: &AppState) -> &Arc<AiGateway> {
    &state.ai
}

/// The configuration a reload would read.
pub fn current_config() -> Result<AiConfig, AiConfigError> {
    AiConfig::load_current()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_json_answer_becomes_a_summary_and_its_action_items() {
        let (summary, items) =
            parse_summary(r#"{"summary":"请在周五前确认","actionItems":["回复确认","付账"]}"#);
        assert_eq!(summary, "请在周五前确认");
        assert_eq!(items, vec!["回复确认".to_owned(), "付账".to_owned()]);
    }

    #[test]
    fn a_fenced_answer_is_still_read() {
        let (summary, items) = parse_summary(
            "这是邮件的摘要：\n```json\n{\"summary\":\"需要回复\",\"actionItems\":[]}\n```\n",
        );
        assert_eq!(summary, "需要回复");
        assert!(items.is_empty());
    }

    #[test]
    fn a_prose_answer_is_still_shown() {
        let (summary, items) = parse_summary("这封信是发票。");
        assert_eq!(summary, "这封信是发票。");
        assert!(items.is_empty());
    }

    #[test]
    fn a_json_array_becomes_the_draft_variants() {
        let variants = parse_variants(r#"["好的，谢谢。","收到，我今天处理。"]"#);
        assert_eq!(variants.len(), 2);
        assert_eq!(variants[0], "好的，谢谢。");
    }

    #[test]
    fn a_prose_answer_becomes_one_variant() {
        let variants = parse_variants("好的，谢谢。");
        assert_eq!(variants, vec!["好的，谢谢。".to_owned()]);
    }
}
