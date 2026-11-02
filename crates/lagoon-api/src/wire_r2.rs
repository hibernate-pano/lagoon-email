//! Wire types for R2, field for field.
//!
//! Same rules as crate::wire: v3's synthesized Foundation encoders omit a nil
//! optional (an absent key means "unknown"), and dates are ISO-8601 text with
//! second precision. The two additions here are consequences of those rules
//! rather than exceptions to them:
//!
//! * A Double field (money, minutes) encodes as 0, not 0.0, when the value is
//!   whole - Foundation's JSONEncoder writes 0, and the golden fixtures record 0.
//! * Payload dictionaries keep the key order they arrive in; they are opaque to
//!   this server.

use serde::{Serialize, Serializer};

use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

/// Foundation writes a whole Double without a fractional part; serde writes
/// 0.0. One decimal formatter for every money/minute field keeps a diff against
/// v3 free of noise.
pub(crate) fn serialize_double<S: Serializer>(
    value: &f64,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    if value.fract() == 0.0 && value.is_finite() && value.abs() < 9.0e15 {
        serializer.serialize_i64(*value as i64)
    } else {
        serializer.serialize_f64(*value)
    }
}

// ---------------------------------------------------------------- advice ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Advice {
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    pub confidence: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rationale: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_text: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdviceRecord {
    pub id: i64,
    pub account_id: Uuid,
    pub remote_id: String,
    pub advice: Advice,
    pub source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    pub decision: String,
    pub created_at: Timestamp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub decided_at: Option<Timestamp>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AdviceListResponse {
    pub advice: Vec<AdviceRecord>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AcceptedAdviceStat {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    pub action: String,
    pub count: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct AcceptedAdviceStatsResponse {
    pub stats: Vec<AcceptedAdviceStat>,
}

// --------------------------------------------------------------- senders ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SenderSummary {
    pub address: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    pub total_count: i64,
    pub unread_count: i64,
    pub latest_at: Timestamp,
}

#[derive(Debug, Clone, Serialize)]
pub struct SenderListResponse {
    pub senders: Vec<SenderSummary>,
}

// --------------------------------------------------------- store notices ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreNotice {
    pub id: String,
    pub created_at: Timestamp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct StoreNoticeListResponse {
    pub notices: Vec<StoreNotice>,
}

// ------------------------------------------------------------ time saved ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeSavedDay {
    pub date: Timestamp,
    #[serde(serialize_with = "serialize_double")]
    pub minutes_saved: f64,
    pub messages_handled: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeSavedWindow {
    #[serde(serialize_with = "serialize_double")]
    pub minutes_saved: f64,
    pub messages_handled: i64,
    pub drafts_sent: i64,
    pub unsubscribed: i64,
    pub by_day: Vec<TimeSavedDay>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TimeSavedReport {
    pub today: TimeSavedWindow,
    pub week: TimeSavedWindow,
}

// ---------------------------------------------------------------- stacks ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StackRule {
    pub id: Uuid,
    pub account_id: Uuid,
    pub name: String,
    pub kind: String,
    pub value: String,
    pub created_at: Timestamp,
}

#[derive(Debug, Clone, Serialize)]
pub struct StackSummary {
    pub rule: StackRule,
    pub count: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct StackRuleListResponse {
    pub stacks: Vec<StackSummary>,
}

// ------------------------------------------------------------- reminders ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reminder {
    pub id: i64,
    pub account_id: Uuid,
    pub remote_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    pub due_at: Timestamp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    pub created_at: Timestamp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dismissed_at: Option<Timestamp>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReminderListResponse {
    pub reminders: Vec<Reminder>,
}

// --------------------------------------------------------------- actions ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AIAction {
    pub id: i64,
    pub account_id: Uuid,
    pub kind: String,
    pub payload: std::collections::BTreeMap<String, String>,
    pub created_at: Timestamp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<Timestamp>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AIActionListResponse {
    pub actions: Vec<AIAction>,
    pub total_count: i64,
    pub has_more: bool,
}

// ---------------------------------------------------------------- drafts ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftReply {
    pub id: i64,
    pub account_id: Uuid,
    pub remote_id: String,
    pub variants: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chosen_variant: Option<i64>,
    pub created_at: Timestamp,
}

#[derive(Debug, Clone, Serialize)]
pub struct DraftListResponse {
    pub drafts: Vec<DraftReply>,
}

// ------------------------------------------------------------------ send ----

/// `SendResponse` (the contract): ok plus the Message-ID the sender minted.
///
/// The id is what a replay of the same requestId answers with, so it has to
/// be the real one and not a per-request placeholder.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SendResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_message_id: Option<String>,
}

// ---------------------------------------------------------------- search ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResponse {
    pub results: Vec<crate::wire::MessageHeader>,
    pub query: String,
    pub total_count: i64,
    pub truncated: bool,
    pub body_scan_skipped: i64,
    pub body_scan_limit: i64,
}

// ------------------------------------------------------------ ai / usage ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AIStatus {
    pub configured: bool,
    pub credit_exhausted: bool,
    pub circuit_open: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageAccountShare {
    pub account_email: String,
    // v3 keeps the Swift property spelling, as UsageReport does.
    #[serde(rename = "monthUSD", serialize_with = "serialize_double")]
    pub month_usd: f64,
    pub call_count: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageReport {
    // v3 spells these monthUSD/capUSD: the wire key is the Swift property name,
    // not a lower-camel rendition of it.
    #[serde(rename = "monthUSD", serialize_with = "serialize_double")]
    pub month_usd: f64,
    #[serde(rename = "capUSD", serialize_with = "serialize_double")]
    pub cap_usd: f64,
    pub call_count: i64,
    pub cost_tracking_available: bool,
    pub accounts: Vec<UsageAccountShare>,
}

// -------------------------------------------------------------- briefing ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BriefingItem {
    pub message: crate::wire::MessageHeader,
    pub group: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason_code: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BriefingResponse {
    pub items: Vec<BriefingItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub omitted_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backlog_count: Option<i64>,
}

// ------------------------------------------------------------------ sent ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SentResponse {
    pub messages: Vec<crate::wire::MessageHeader>,
    pub total_count: i64,
    pub refreshed_from_server: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stale_reason: Option<String>,
}

// ---------------------------------------------------------- export index ----

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportIndexResponse {
    pub messages: Vec<crate::wire::MessageHeader>,
    pub total_count: i64,
    pub deleted_count: i64,
    pub sent_count: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_doubles_encode_like_foundation() {
        let report = TimeSavedReport {
            today: TimeSavedWindow {
                minutes_saved: 0.0,
                messages_handled: 0,
                drafts_sent: 0,
                unsubscribed: 0,
                by_day: vec![],
            },
            week: TimeSavedWindow {
                minutes_saved: 2.5,
                messages_handled: 1,
                drafts_sent: 0,
                unsubscribed: 0,
                by_day: vec![],
            },
        };
        let text = serde_json::to_string(&report).expect("json");
        assert!(text.contains("\"minutesSaved\":0,"), "{text}");
        assert!(text.contains("\"minutesSaved\":2.5,"), "{text}");
    }

    #[test]
    fn nil_optionals_are_absent_keys() {
        let response = BriefingResponse {
            items: vec![],
            omitted_count: None,
            backlog_count: Some(3),
        };
        let value: serde_json::Value = serde_json::to_value(&response).expect("json");
        assert!(value.get("omittedCount").is_none());
        assert_eq!(value["backlogCount"], serde_json::json!(3));
    }
}
