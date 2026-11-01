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
