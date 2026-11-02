//! The advice queue (v3 AdviceStore.list / acceptedStats).

use rusqlite::Connection;

use crate::db::{optional_timestamp_column, timestamp_column, uuid_column};
use crate::timefmt::Timestamp;
use crate::uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecisionFilter {
    Pending,
    Exactly(&'static str),
    All,
}

#[derive(Debug, Clone)]
pub struct AdviceRow {
    pub id: i64,
    pub account_id: Uuid,
    pub remote_id: String,
    pub action: String,
    pub category: Option<String>,
    pub confidence: String,
    pub rationale: Option<String>,
    pub due_text: Option<String>,
    pub source: String,
    pub model: Option<String>,
    pub decision: String,
    pub created_at: Timestamp,
    pub decided_at: Option<Timestamp>,
}

const COLUMNS: &str = "id, account_id, remote_id, action, category, confidence,
                       rationale, due_text, source, model, decision, created_at, decided_at";

/// The actions the queue knows. A suggestion outside this set cannot be
/// shown, so the classifier normalises to one of these.
pub const ACTIONS: [&str; 7] = [
    "reply",
    "wait",
    "archive",
    "delete",
    "unsubscribe",
    "remind",
    "nothing",
];
/// The categories the queue knows.
pub const CATEGORIES: [&str; 10] = [
    "personal",
    "work",
    "marketing",
    "spam",
    "notification",
    "transactional",
    "financial",
    "logistics",
    "newsletter",
    "other",
];
/// The confidence levels the queue knows.
pub const CONFIDENCES: [&str; 3] = ["high", "medium", "low"];
const SOURCES: [&str; 2] = ["heuristic", "ai"];
const DECISIONS: [&str; 3] = ["pending", "accepted", "dismissed"];

/// v3 AdviceStore.list, with the same row-level tolerance: a row whose enum
/// columns hold values this build does not know is skipped, never rendered with
/// a made-up code.
pub fn list(
    connection: &Connection,
    account_id: Uuid,
    filter: DecisionFilter,
    limit: i64,
) -> rusqlite::Result<Vec<AdviceRow>> {
    let (predicate, mut arguments) = match filter {
        DecisionFilter::Pending => (
            "WHERE account_id = ? AND decision = ?",
            vec![
                rusqlite::types::Value::Blob(account_id.as_bytes().to_vec()),
                rusqlite::types::Value::Text("pending".to_owned()),
            ],
        ),
        DecisionFilter::Exactly(decision) => (
            "WHERE account_id = ? AND decision = ?",
            vec![
                rusqlite::types::Value::Blob(account_id.as_bytes().to_vec()),
                rusqlite::types::Value::Text(decision.to_owned()),
            ],
        ),
        DecisionFilter::All => (
            "WHERE account_id = ?",
            vec![rusqlite::types::Value::Blob(account_id.as_bytes().to_vec())],
        ),
    };
    arguments.push(rusqlite::types::Value::Integer(limit.max(1)));
    let sql = format!(
        "SELECT {COLUMNS} FROM advice
         {predicate}
         ORDER BY created_at DESC, id DESC LIMIT ?"
    );
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query(rusqlite::params_from_iter(arguments.iter()))?;
    let mut records = Vec::new();
    while let Some(row) = rows.next()? {
        if let Some(record) = decode(row)? {
            records.push(record);
        }
    }
    Ok(records)
}

/// One (category, action, count) triple, ordered the way v3 sorts them:
/// frequency first, then "no category" ahead of any category, then by the
/// stable enum spellings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcceptedStat {
    pub category: Option<String>,
    pub action: String,
    pub count: i64,
}

pub fn accepted_stats(
    connection: &Connection,
    account_id: Uuid,
    limit: i64,
) -> rusqlite::Result<Vec<AcceptedStat>> {
    let sql = format!("SELECT {COLUMNS} FROM advice WHERE account_id = ? AND decision = ?");
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query(rusqlite::params![
        account_id.as_bytes().as_slice(),
        "accepted"
    ])?;
    let mut counts: Vec<AcceptedStat> = Vec::new();
    while let Some(row) = rows.next()? {
        let Some(record) = decode(row)? else {
            continue;
        };
        match counts
            .iter_mut()
            .find(|stat| stat.category == record.category && stat.action == record.action)
        {
            Some(stat) => stat.count += 1,
            None => counts.push(AcceptedStat {
                category: record.category,
                action: record.action,
                count: 1,
            }),
        }
    }
    counts.sort_by(|left, right| {
        if left.count != right.count {
            return right.count.cmp(&left.count);
        }
        match (&left.category, &right.category) {
            (None, None) => {}
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (Some(left), Some(right)) if left != right => return left.cmp(right),
            _ => {}
        }
        left.action.cmp(&right.action)
    });
    counts.truncate(usize::try_from(limit.max(1)).unwrap_or(1));
    Ok(counts)
}

fn decode(row: &rusqlite::Row<'_>) -> rusqlite::Result<Option<AdviceRow>> {
    let action: String = row.get(3)?;
    let confidence: String = row.get(5)?;
    let source: String = row.get(8)?;
    let decision: String = row.get(10)?;
    if !ACTIONS.contains(&action.as_str())
        || !CONFIDENCES.contains(&confidence.as_str())
        || !SOURCES.contains(&source.as_str())
        || !DECISIONS.contains(&decision.as_str())
    {
        return Ok(None);
    }
    // v3 logs and skips an unreadable row in the list path, and skips a row
    // whose category is not a known one in the accepted-stats path.
    let category: Option<String> = optional_text(row, 4)?;
    Ok(Some(AdviceRow {
        id: row.get(0)?,
        account_id: uuid_column(row, 1)?,
        remote_id: row.get(2)?,
        action,
        category: category.filter(|raw| CATEGORIES.contains(&raw.as_str())),
        confidence,
        rationale: optional_text(row, 6)?,
        due_text: optional_text(row, 7)?,
        source,
        model: optional_text(row, 9)?,
        decision,
        created_at: timestamp_column(row, 11)?,
        decided_at: optional_timestamp_column(row, 12)?,
    }))
}

/// v3 optionalText: NULL and the empty string are both "no value".
pub(crate) fn optional_text(
    row: &rusqlite::Row<'_>,
    index: usize,
) -> rusqlite::Result<Option<String>> {
    Ok(row
        .get::<_, Option<String>>(index)?
        .filter(|value| !value.is_empty()))
}

/// Whether this message already has a suggestion.
///
/// The classifier asks this before every call: a mail is classified once, and
/// a second call would cost money for the same words.
pub fn has_advice(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
) -> rusqlite::Result<bool> {
    let count: i64 = connection.query_row(
        "SELECT count(*) FROM advice WHERE account_id = ? AND remote_id = ?",
        rusqlite::params![account_id.as_bytes().as_slice(), remote_id],
        |row| row.get(0),
    )?;
    Ok(count > 0)
}

/// One suggestion from the model, as stored in `advice`.
///
/// The queue only knows seven actions, ten categories and three confidence
/// levels; [`upsert_ai`] normalises anything else to what it can show.
#[derive(Debug, Clone, Copy)]
pub struct AiSuggestion<'a> {
    pub action: &'a str,
    pub category: Option<&'a str>,
    pub confidence: &'a str,
    pub rationale: Option<&'a str>,
    pub due_text: Option<&'a str>,
    pub model: &'a str,
}

/// Store the AI's suggestion for one message.
///
/// The suggestion is not an action: it lives in `advice`, never in
/// `ai_actions`, so the undo history never lists something the user never
/// did. A row that already exists is replaced - the model saw the mail again
/// and changed its mind - unless the user already decided, which is the
/// user's call and not the model's to overwrite.
pub fn upsert_ai(
    connection: &Connection,
    account_id: Uuid,
    remote_id: &str,
    suggestion: &AiSuggestion<'_>,
) -> rusqlite::Result<()> {
    let action = if ACTIONS.contains(&suggestion.action) {
        suggestion.action
    } else {
        "nothing"
    };
    let confidence = if CONFIDENCES.contains(&suggestion.confidence) {
        suggestion.confidence
    } else {
        "low"
    };
    let category = suggestion
        .category
        .filter(|value| CATEGORIES.contains(value));
    connection.execute(
        "INSERT INTO advice
            (account_id, remote_id, action, category, confidence, rationale,
             due_text, source, model, decision)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'ai', ?8, 'pending')
         ON CONFLICT (account_id, remote_id) DO UPDATE SET
            action = excluded.action,
            category = excluded.category,
            confidence = excluded.confidence,
            rationale = excluded.rationale,
            due_text = excluded.due_text,
            model = excluded.model,
            source = 'ai'
         WHERE advice.decision = 'pending'",
        rusqlite::params![
            account_id.as_bytes().as_slice(),
            remote_id,
            action,
            category,
            confidence,
            suggestion.rationale,
            suggestion.due_text,
            suggestion.model,
        ],
    )?;
    Ok(())
}
