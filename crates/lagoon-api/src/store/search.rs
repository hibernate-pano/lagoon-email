//! Search - the corrected two-pass implementation.
//!
//! v3.2.0's pass B references a.category / a.action inside a query that only
//! LEFT JOINs message_bodies, so SQLite raises "no such column: a.category" and
//! the route always answers 500. That defect is recorded as search.known-defect
//! in the golden fixtures, and it is deliberately **not** reproduced here: the
//! contract is a 200 SearchResponse, and R2 implements it by joining advice in
//! both passes.
//!
//! The shape itself is v3's: pass A matches the columns that cost nothing
//! (subject, sender, the AI's structured verdict); pass B opens the sealed
//! preview/body of the rows pass A did not match, under a budget, so a keystroke
//! cannot decrypt a whole mailbox.

use std::collections::HashSet;

use rusqlite::Connection;

use crate::crypto::BodyKey;
use crate::timefmt::{self, Timestamp};
use crate::uuid::Uuid;

use super::messages::{decode_find_row, like_pattern, StoredMessage};

/// v3 DraftRoutes constants.
pub const BODY_SCAN_LIMIT: i64 = 1000;
pub const BODY_SCAN_BATCH: i64 = 200;
pub const RESULT_LIMIT: i64 = 100;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Account(Uuid),
    All,
}

#[derive(Debug)]
pub struct SearchOutcome {
    pub results: Vec<StoredMessage>,
    pub total_count: i64,
    /// How much of the mailbox the budget did not reach; zero when the mailbox
    /// ended before the budget did.
    pub body_scan_skipped: i64,
}

#[derive(Debug)]
pub enum SearchError {
    Sqlite(rusqlite::Error),
    Cipher(crate::crypto::CipherError),
}

impl std::fmt::Display for SearchError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SearchError::Sqlite(error) => write!(formatter, "sqlite: {error}"),
            SearchError::Cipher(error) => write!(formatter, "sealed value: {error}"),
        }
    }
}

impl From<rusqlite::Error> for SearchError {
    fn from(error: rusqlite::Error) -> Self {
        SearchError::Sqlite(error)
    }
}

impl From<crate::crypto::CipherError> for SearchError {
    fn from(error: crate::crypto::CipherError) -> Self {
        SearchError::Cipher(error)
    }
}

/// Run the two passes. The query is already trimmed and non-empty.
pub fn search(
    connection: &Connection,
    body_key: &BodyKey,
    scope: Scope,
    query: &str,
    sender: Option<&str>,
    since: Option<Timestamp>,
) -> Result<SearchOutcome, SearchError> {
    let pattern = like_pattern(query);
    let cheap_arms = "(m.subject LIKE ? ESCAPE '\\'
                      OR m.from_name LIKE ? ESCAPE '\\'
                      OR m.from_address LIKE ? ESCAPE '\\'
                      OR a.category LIKE ? ESCAPE '\\'
                      OR a.action LIKE ? ESCAPE '\\')";

    // The filters both passes share: a scoped search never even looks at
    // another account's mail.
    let mut filters = String::from("m.is_deleted = FALSE");
    let mut filter_arguments: Vec<rusqlite::types::Value> = Vec::new();
    if let Scope::Account(account_id) = scope {
        filters.push_str(" AND m.account_id = ?");
        filter_arguments.push(rusqlite::types::Value::Blob(account_id.as_bytes().to_vec()));
    }
    if let Some(sender) = sender {
        filters.push_str(" AND m.from_address = ?");
        filter_arguments.push(rusqlite::types::Value::Text(sender.to_owned()));
    }
    if let Some(since) = since {
        filters.push_str(" AND m.received_at >= ?");
        filter_arguments.push(rusqlite::types::Value::Text(timefmt::to_stored(since)));
    }

    let mut cheap_arguments: Vec<rusqlite::types::Value> = Vec::new();
    for _ in 0..5 {
        cheap_arguments.push(rusqlite::types::Value::Text(pattern.clone()));
    }

    // Pass A - the cheap arms, in SQL. Only the newest window is fetched: the
    // merged top-N cannot need a cheap hit older than the newest N, and a
    // broad query (one letter matches most of a mailbox) would otherwise load
    // every matching id into memory just to sort and drop them. `totalCount`
    // comes from the COUNT below, so the window costs no honesty.
    let cheap_sql = format!(
        "SELECT m.id, m.received_at
         FROM message_headers m
         LEFT JOIN advice a
           ON a.account_id = m.account_id AND a.remote_id = m.remote_id
         WHERE {filters} AND {cheap_arms}
         ORDER BY m.received_at DESC, m.id DESC
         LIMIT ?"
    );
    let mut cheap_hits: Vec<(Uuid, Timestamp)> = Vec::new();
    {
        let mut arguments: Vec<rusqlite::types::Value> = filter_arguments.clone();
        arguments.extend(cheap_arguments.iter().cloned());
        arguments.push(rusqlite::types::Value::Integer(RESULT_LIMIT));
        let mut statement = connection.prepare(&cheap_sql)?;
        let mut rows = statement.query(rusqlite::params_from_iter(arguments.iter()))?;
        while let Some(row) = rows.next()? {
            cheap_hits.push((
                crate::db::uuid_column(row, 0)?,
                crate::db::timestamp_column(row, 1)?,
            ));
        }
    }

    // The exact size of pass A's set, which the window above cannot report.
    // Pass B excludes these rows, so the total is a sum, not a union count.
    let cheap_count: i64 = {
        let count_sql = format!(
            "SELECT COUNT(*)
             FROM message_headers m
             LEFT JOIN advice a
               ON a.account_id = m.account_id AND a.remote_id = m.remote_id
             WHERE {filters} AND {cheap_arms}"
        );
        let mut statement = connection.prepare(&count_sql)?;
        statement.query_row(
            rusqlite::params_from_iter(filter_arguments.iter().chain(cheap_arguments.iter())),
            |row| row.get(0),
        )?
    };

    // Pass B - the sealed arms, in Rust, under a budget. The advice join is the
    // fix: without it the cheap arms cannot be evaluated inside this statement.
    let scan_sql = format!(
        "SELECT m.id, m.received_at,
                NULLIF(m.snippet_cipher, '') AS snippet_cipher,
                NULLIF(b.body_cipher, '') AS body_cipher
         FROM message_headers m
         LEFT JOIN message_bodies b
           ON b.account_id = m.account_id AND b.remote_id = m.remote_id
         LEFT JOIN advice a
           ON a.account_id = m.account_id AND a.remote_id = m.remote_id
         WHERE {filters}
           AND COALESCE({cheap_arms}, 0) = 0
           AND (NULLIF(m.snippet_cipher, '') IS NOT NULL
                OR NULLIF(b.body_cipher, '') IS NOT NULL)
         ORDER BY m.received_at DESC, m.id DESC
         LIMIT ? OFFSET ?"
    );

    let mut sealed_hits: Vec<(Uuid, Timestamp)> = Vec::new();
    let mut scanned: i64 = 0;
    let mut reached_the_end = false;
    while scanned < BODY_SCAN_LIMIT {
        let batch_size = BODY_SCAN_BATCH.min(BODY_SCAN_LIMIT - scanned);
        let mut arguments: Vec<rusqlite::types::Value> = filter_arguments.clone();
        arguments.extend(cheap_arguments.iter().cloned());
        arguments.push(rusqlite::types::Value::Integer(batch_size));
        arguments.push(rusqlite::types::Value::Integer(scanned));
        let mut statement = connection.prepare(&scan_sql)?;
        let mut rows = statement.query(rusqlite::params_from_iter(arguments.iter()))?;
        let mut batch = 0i64;
        while let Some(row) = rows.next()? {
            batch += 1;
            let preview: Option<String> = row.get(2)?;
            let body: Option<String> = row.get(3)?;
            if matches_sealed(body_key, preview.as_deref(), body.as_deref(), query)? {
                sealed_hits.push((
                    crate::db::uuid_column(row, 0)?,
                    crate::db::timestamp_column(row, 1)?,
                ));
            }
        }
        scanned += batch;
        if batch < batch_size {
            reached_the_end = true;
            break;
        }
    }

    let mut body_scan_skipped = 0i64;
    if !reached_the_end {
        let candidate_sql = format!(
            "SELECT COUNT(*)
             FROM message_headers m
             LEFT JOIN message_bodies b
               ON b.account_id = m.account_id AND b.remote_id = m.remote_id
             LEFT JOIN advice a
               ON a.account_id = m.account_id AND a.remote_id = m.remote_id
             WHERE {filters}
               AND COALESCE({cheap_arms}, 0) = 0
               AND (NULLIF(m.snippet_cipher, '') IS NOT NULL
                    OR NULLIF(b.body_cipher, '') IS NOT NULL)"
        );
        let mut statement = connection.prepare(&candidate_sql)?;
        let candidates: i64 = statement.query_row(
            rusqlite::params_from_iter(filter_arguments.iter().chain(cheap_arguments.iter())),
            |row| row.get(0),
        )?;
        body_scan_skipped = (candidates - scanned).max(0);
    }

    // The two passes are disjoint by construction (pass B excludes every row
    // pass A matched), so the total is their sum. Pass A is counted, not
    // enumerated, because only its newest window was fetched.
    let sealed_count = sealed_hits.len() as i64;
    let mut ordered: Vec<(Uuid, Timestamp)> = cheap_hits;
    ordered.extend(sealed_hits);
    ordered.sort_by(|left, right| {
        right
            .1
            .cmp(&left.1)
            .then_with(|| right.0.to_wire_string().cmp(&left.0.to_wire_string()))
    });
    let mut seen: HashSet<Uuid> = HashSet::new();
    ordered.retain(|(id, _)| seen.insert(*id));
    let total_count = (cheap_count + sealed_count).max(ordered.len() as i64);
    let top: Vec<Uuid> = ordered
        .into_iter()
        .take(usize::try_from(RESULT_LIMIT).unwrap_or(usize::MAX))
        .map(|(id, _)| id)
        .collect();

    if top.is_empty() {
        return Ok(SearchOutcome {
            results: Vec::new(),
            total_count,
            body_scan_skipped,
        });
    }

    // The rows themselves, in one statement. Only the number of placeholders is
    // built from the id list - no user text reaches the SQL.
    let placeholders = vec!["?"; top.len()].join(", ");
    let header_sql = format!(
        "SELECT m.id, m.account_id, m.remote_id, m.thread_id, m.from_address,
                NULLIF(m.from_name, '') AS from_name,
                NULLIF(m.subject, '') AS subject,
                NULLIF(m.snippet_cipher, '') AS snippet_cipher,
                m.received_at, m.is_read, m.is_archived, m.is_deleted, m.is_sent,
                m.message_id_header, m.in_reply_to, m.references_header
         FROM message_headers m
         WHERE m.id IN ({placeholders})
         ORDER BY m.received_at DESC, m.id DESC"
    );
    let id_arguments: Vec<rusqlite::types::Value> = top
        .iter()
        .map(|id| rusqlite::types::Value::Blob(id.as_bytes().to_vec()))
        .collect();
    let mut statement = connection.prepare(&header_sql)?;
    let mut rows = statement.query(rusqlite::params_from_iter(id_arguments.iter()))?;
    let mut results = Vec::new();
    while let Some(row) = rows.next()? {
        results.push(decode_find_row(row)?);
    }

    Ok(SearchOutcome {
        results,
        total_count,
        body_scan_skipped,
    })
}

fn matches_sealed(
    body_key: &BodyKey,
    preview: Option<&str>,
    body: Option<&str>,
    needle: &str,
) -> Result<bool, SearchError> {
    // The preview is checked first and the body second, so a row the preview
    // already answers never opens its body.
    if let Some(preview) = preview {
        if contains_case_insensitive(&body_key.open(preview)?, needle) {
            return Ok(true);
        }
    }
    if let Some(body) = body {
        if contains_case_insensitive(&body_key.open(body)?, needle) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// v3 BodyCipher.matches: case-insensitive Unicode substring search.
pub fn contains_case_insensitive(haystack: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    haystack.to_lowercase().contains(&needle.to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substring_search_folds_case_and_handles_cjk() {
        assert!(contains_case_insensitive("Hello Lagoon", "lagoon"));
        assert!(contains_case_insensitive("你好，Lagoon", "lagoon"));
        assert!(contains_case_insensitive("中文正文", "正文"));
        assert!(!contains_case_insensitive("hello", "world"));
        assert!(contains_case_insensitive("anything", ""));
    }
}
