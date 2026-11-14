//! Interoperability with the store the v3 sidecar actually created.
//!
//! This is the one test that does not use the synthetic schema: it opens
//! .dev/data/lagoon.sqlite - the SQLite file GRDB migrated to lagoon-v10
//! when the Swift sidecar started - and serves the R1 endpoints from it,
//! read-only. If the schema probe, the BLOB UUID decoding or the stored date
//! format drifted from v3, this is where it shows.
//!
//! The store is not modified: every connection is opened READ_ONLY with
//! PRAGMA query_only, and the assertions are read-only requests.
//!
//! Skipped (with a note) when the dev store has not been created yet:
//!     bash scripts/dev.sh
//! The hermetic tests (contract_replay.rs, read_paths.rs) always run.

mod support;

use serde_json::json;

use lagoon_api::db::Db;

use support::http;
use support::server::TestServer;

fn dev_store_path() -> std::path::PathBuf {
    std::path::PathBuf::from(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../.dev/data/lagoon.sqlite"
    ))
}

#[tokio::test]
async fn serves_the_v3_sidecar_store_read_only() {
    let path = dev_store_path();
    if !path.is_file() {
        eprintln!(
            "skip: {} does not exist yet - run: bash scripts/dev.sh",
            path.display()
        );
        return;
    }

    // The schema probe R1 refuses to start without.
    let db = Db::open_read_only(path.clone()).expect("the v3 store must open read-only");
    let report = db
        .validate_schema()
        .expect("the v3 store must satisfy the R1 schema");
    assert!(
        report.migrations.contains(&"lagoon-v10".to_owned()),
        "expected the v3.2.0 migration chain, saw {:?}",
        report.migrations
    );
    assert!(
        db.with_connection(|connection| connection.execute("DELETE FROM accounts", []))
            .is_err(),
        "the service handle must not be able to write the dev store"
    );

    let server = TestServer::spawn_on_store("dev-store", path, Some("dev-store-token")).await;
    let client = http::client();
    let auth = server.auth_headers();

    let health = http::request(&client, "GET", &format!("{}/healthz", server.base_url), &[]).await;
    assert_eq!(health.status, 200);
    assert_eq!(health.content_type, "text/plain; charset=utf-8");
    assert_eq!(health.body, json!("ok"));

    let accounts = http::request(
        &client,
        "GET",
        &format!("{}/api/accounts", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(accounts.status, 200, "{:?}", accounts.body);
    assert!(accounts.body.is_array());

    // A well-formed but unknown account id: the list answers 200 empty (v3 does
    // not check account existence there), folder-counts answers 404.
    let unknown = "99999999-9999-4999-8999-999999999999";
    let list = http::request(
        &client,
        "GET",
        &format!("{}/api/messages?accountId={unknown}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(list.status, 200, "{:?}", list.body);
    assert_eq!(list.body["messages"], json!([]));
    assert_eq!(list.body["cursor"]["accountId"], json!(unknown));
    assert!(list.body["cursor"]["lastFetchedAt"].is_string());
    assert_eq!(list.body["totalCount"], json!(0));

    let counts = http::request(
        &client,
        "GET",
        &format!("{}/api/folder-counts?accountId={unknown}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(counts.status, 404);
    assert_eq!(counts.body, json!({"error": "unknown-account"}));

    let body = http::request(
        &client,
        "GET",
        &format!(
            "{}/api/messages/whatever/body?accountId={unknown}",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(body.status, 404);
    assert_eq!(body.body, json!({"error": "unknown-account"}));
}
