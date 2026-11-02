//! The AI ledger read (v3 UsageBudget / BudgetRoutes).

use rusqlite::Connection;

#[derive(Debug, Clone, Copy)]
pub struct MonthSummary {
    pub cost_micro_usd: i64,
    pub call_count: i64,
}

#[derive(Debug, Clone)]
pub struct AccountShare {
    pub account_email: String,
    pub cost_micro_usd: i64,
    pub calls: i64,
}

/// v3 UsageBudget.summary: this month's totals from the one cost ledger.
pub fn month_summary(connection: &Connection, year_month: &str) -> rusqlite::Result<MonthSummary> {
    let mut statement = connection.prepare(
        "SELECT COALESCE(SUM(cost_micro_usd), 0) AS total, COUNT(*) AS calls
         FROM usage_log WHERE year_month = ?",
    )?;
    let mut rows = statement.query([year_month])?;
    let Some(row) = rows.next()? else {
        return Ok(MonthSummary {
            cost_micro_usd: 0,
            call_count: 0,
        });
    };
    Ok(MonthSummary {
        cost_micro_usd: row.get(0)?,
        call_count: row.get(1)?,
    })
}

/// v3 UsageBudget.accountBreakdown: the month split per account, cost first.
pub fn account_breakdown(
    connection: &Connection,
    year_month: &str,
) -> rusqlite::Result<Vec<AccountShare>> {
    let mut statement = connection.prepare(
        "SELECT account_email,
                COALESCE(SUM(cost_micro_usd), 0) AS total,
                COUNT(*) AS calls
         FROM usage_log
         WHERE year_month = ?
         GROUP BY account_email
         ORDER BY total DESC, account_email ASC",
    )?;
    let mut rows = statement.query([year_month])?;
    let mut shares = Vec::new();
    while let Some(row) = rows.next()? {
        shares.push(AccountShare {
            account_email: row.get(0)?,
            cost_micro_usd: row.get(1)?,
            calls: row.get(2)?,
        });
    }
    Ok(shares)
}

/// One line in the cost ledger.
#[derive(Debug, Clone, Copy)]
pub struct UsageRecord<'a> {
    pub year_month: &'a str,
    pub account_email: &'a str,
    pub capability: &'a str,
    pub model: &'a str,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub cost_micro_usd: i64,
}

/// Record one AI call in the cost ledger.
///
/// The ledger is the only place the product knows what the AI cost. A call
/// that is not written here is money the user spent and nobody can see, so
/// the routes write one row per call, including the calls that failed
/// halfway (they cost tokens too).
pub fn record(connection: &Connection, record: &UsageRecord<'_>) -> rusqlite::Result<()> {
    connection.execute(
        "INSERT INTO usage_log
            (year_month, account_email, capability, model,
             prompt_tokens, completion_tokens, cost_micro_usd)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![
            record.year_month,
            record.account_email,
            record.capability,
            record.model,
            i64::from(record.prompt_tokens),
            i64::from(record.completion_tokens),
            record.cost_micro_usd,
        ],
    )?;
    Ok(())
}
