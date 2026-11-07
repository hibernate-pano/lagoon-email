//! R3.5: write-path concurrency.
//!
//! The server keeps a single read-only pool and hands every write route its own
//! writable connection. Two of those can meet — the sync round finishing while
//! the user clicks undo — and the failure that matters is not the ordinary
//! "database is locked" (the busy handler queues that one). It is
//! SQLITE_BUSY_SNAPSHOT: a deferred transaction that reads, then writes after
//! someone else committed, is refused at once and the busy timeout is never
//! consulted. The fix is to begin those transactions IMMEDIATE.
//!
//! These tests pin both halves: the failure exists and is not a timeout
//! problem, and IMMEDIATE is what prevents it.

mod support;

use std::time::Duration;

use lagoon_api::db;
use support::TempDir;

/// rusqlite surfaces SQLITE_BUSY_SNAPSHOT as DatabaseBusy with this code.
const SQLITE_BUSY_SNAPSHOT: i32 = 517;

fn schema(path: &std::path::Path) {
    let connection = db::open_writable(path).expect("open writable");
    connection
        .execute_batch(
            "CREATE TABLE counter (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);
             INSERT INTO counter (id, value) VALUES (1, 0);",
        )
        .expect("schema");
}

#[test]
fn a_deferred_read_then_write_is_refused_with_busy_snapshot() {
    // This is the failure the fix exists for. If it stops reproducing, the
    // guard below has nothing left to protect and should be revisited rather
    // than silently kept.
    let dir = TempDir::new("conflict");
    let path = dir.path().join("store.sqlite");
    schema(&path);

    let mut reader = db::open_writable(&path).expect("reader");
    let writer = db::open_writable(&path).expect("writer");
    // A generous timeout changes nothing: this error is not a waited-on lock.
    reader
        .busy_timeout(Duration::from_secs(5))
        .expect("timeout");
    writer
        .busy_timeout(Duration::from_secs(5))
        .expect("timeout");

    let transaction = reader.transaction().expect("begin deferred");
    let _: i64 = transaction
        .query_row("SELECT value FROM counter WHERE id = 1", [], |row| {
            row.get(0)
        })
        .expect("read");
    writer
        .execute("UPDATE counter SET value = value + 1 WHERE id = 1", [])
        .expect("the other connection commits");

    let error = transaction
        .execute("UPDATE counter SET value = value + 1 WHERE id = 1", [])
        .expect_err("a stale snapshot must not be allowed to write");
    match error {
        rusqlite::Error::SqliteFailure(failure, _) => assert_eq!(
            failure.extended_code, SQLITE_BUSY_SNAPSHOT,
            "expected BUSY_SNAPSHOT, got {failure:?}"
        ),
        other => panic!("expected a sqlite failure, got {other:?}"),
    }
}

#[test]
fn an_immediate_transaction_reads_and_writes_under_contention() {
    // The same read-then-write, but IMMEDIATE takes the write lock before the
    // read, so there is no snapshot that can go stale.
    let dir = TempDir::new("immediate");
    let path = dir.path().join("store.sqlite");
    schema(&path);

    let mut reader = db::open_writable(&path).expect("reader");
    let writer = db::open_writable(&path).expect("writer");
    reader
        .busy_timeout(Duration::from_secs(5))
        .expect("timeout");
    writer
        .busy_timeout(Duration::from_secs(5))
        .expect("timeout");

    let transaction = reader
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .expect("begin immediate");

    // The competing writer cannot commit while we hold the write lock. It may
    // block until our timeout or fail; either way it must not invalidate us.
    let competing = std::thread::spawn(move || {
        writer.execute("UPDATE counter SET value = value + 1 WHERE id = 1", [])
    });

    let value: i64 = transaction
        .query_row("SELECT value FROM counter WHERE id = 1", [], |row| {
            row.get(0)
        })
        .expect("read");
    transaction
        .execute(
            "UPDATE counter SET value = ?1 WHERE id = 1",
            rusqlite::params![value + 1],
        )
        .expect("an immediate transaction must be able to write");
    transaction.commit().expect("commit");
    let _ = competing.join();
}

#[test]
fn the_write_transactions_begin_immediate() {
    // A source-level guard for the three read-then-write transactions. A
    // behaviour test would have to win a race to prove this, and a lost race
    // is the failure we are preventing; reading the call sites is honest about
    // what is being asserted.
    let cases: [(&str, &str); 4] = [
        ("src/http/routes_r5.rs", "async fn undo_one"),
        ("src/store/write.rs", "pub fn set_active"),
        ("src/store/write.rs", "pub fn reconcile_active"),
        // A sync round is one transaction: a UIDVALIDITY reset that fails
        // half-way must not leave the reader with an empty inbox.
        ("src/sync/mod.rs", "    fn apply("),
    ];
    for (file, anchor) in cases {
        let source = std::fs::read_to_string(format!("{}/{}", env!("CARGO_MANIFEST_DIR"), file))
            .unwrap_or_else(|error| panic!("read {file}: {error}"));
        let after = source
            .split(anchor)
            .nth(1)
            .unwrap_or_else(|| panic!("{file} has no {anchor}"));
        // Look at this function only: cut at the next top-level item.
        let body = after
            .split("\npub fn ")
            .next()
            .expect("function body")
            .split("\npub async fn ")
            .next()
            .expect("function body")
            .split("\nimpl ")
            .next()
            .expect("function body");
        assert!(
            body.contains("TransactionBehavior::Immediate"),
            "{file}::{anchor} must begin its write transaction IMMEDIATE; a deferred \
             read-then-write is refused with SQLITE_BUSY_SNAPSHOT and the busy timeout \
             does not retry it"
        );
    }
}

#[test]
fn open_writable_sets_the_busy_timeout_explicitly() {
    // The bundled SQLite defaults to five seconds today, but that is a
    // compile-time option of the build rather than something this code states.
    // Passing tests above prove the wait exists; this one proves we asked for
    // it instead of inheriting it.
    let source = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/db.rs"))
        .expect("read db.rs");
    let writable = source
        .split("pub fn open_writable")
        .nth(1)
        .expect("open_writable exists");
    let body = writable.split("\nimpl Db").next().expect("function body");
    assert!(
        body.contains("busy_timeout(BUSY_TIMEOUT)"),
        "open_writable must set the busy timeout explicitly"
    );
}
