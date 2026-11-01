//! Store notices (v3 StoreNoticeStore.list).

use rusqlite::Connection;

use crate::timefmt;
use crate::timefmt::Timestamp;

#[derive(Debug, Clone)]
pub struct NoticeRow {
    pub id: String,
    pub created_at: Timestamp,
    pub detail: Option<String>,
}

/// Oldest first, exactly like v3.
pub fn list(connection: &Connection) -> rusqlite::Result<Vec<NoticeRow>> {
    let mut statement = connection
        .prepare("SELECT id, detail, created_at FROM store_notices ORDER BY created_at ASC")?;
    let mut rows = statement.query([])?;
    let mut notices = Vec::new();
    while let Some(row) = rows.next()? {
        let created_at: Option<String> = row.get(2)?;
        notices.push(NoticeRow {
            id: row.get(0)?,
            // v3: StoredDate.date(from:) ?? Date() - an unreadable timestamp
            // becomes "now" rather than dropping the notice.
            created_at: timefmt::parse(created_at.as_deref()).unwrap_or_else(timefmt::now),
            detail: row.get(1)?,
        });
    }
    Ok(notices)
}
