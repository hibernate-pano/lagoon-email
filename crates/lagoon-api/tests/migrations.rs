//! R3.2: the migration chain and the writable store.
//!
//! The schema test compares a store this crate creates against a checked-in
//! golden dump of a fresh v3.2.0 store (tests/golden/v3-schema.json). The golden
//! file is the output of the real sidecar, not of this crate: if the two ever
//! diverge, this test says which object and which line.

mod support;

use serde_json::Value;

use lagoon_api::crypto::BodyKey;
use lagoon_api::db;
use lagoon_api::store::migrate::{migrate, seal_legacy_bodies};
use lagoon_api::store::write::{self, NewAccount, NewBody, NewHeader};
use lagoon_api::uuid::Uuid;
use support::TempDir;

fn test_key() -> BodyKey {
    use base64::Engine as _;
    let encoded =
        base64::engine::general_purpose::STANDARD.encode(b"0123456789abcdef0123456789abcdef");
    BodyKey::from_base64(&encoded).expect("test key")
}

struct SchemaObject {
    kind: String,
    name: String,
    table: String,
    sql: Option<String>,
}

fn dump_schema(path: &std::path::Path) -> (Vec<SchemaObject>, Vec<String>) {
    let connection = rusqlite::Connection::open(path).expect("open");
    let mut statement = connection
        .prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
        .expect("prepare");
    let rows = statement
        .query_map([], |row| {
            Ok(SchemaObject {
                kind: row.get(0)?,
                name: row.get(1)?,
                table: row.get(2)?,
                sql: row.get(3)?,
            })
        })
        .expect("query");
    let mut objects = Vec::new();
    for row in rows {
        let object = row.expect("row");
        // The implicit indexes are named by SQLite itself; the task allows
        // normalising them away, and their names carry no product meaning.
        if object.kind == "index" && object.name.starts_with("sqlite_autoindex") {
            continue;
        }
        objects.push(object);
    }
    let migrations: Vec<String> = connection
        .prepare("SELECT identifier FROM grdb_migrations ORDER BY rowid")
        .expect("prepare")
        .query_map([], |row| row.get(0))
        .expect("query")
        .map(|row| row.expect("row"))
        .collect();
    (objects, migrations)
}

#[test]
fn rust_schema_matches_the_v3_golden() {
    let temp = TempDir::new("r3-schema");
    let path = temp.join("rust.sqlite");
    let connection = db::open_writable(&path).expect("open writable");
    let report = migrate(&connection, Some(&test_key())).expect("migrate");
    assert_eq!(report.applied.len(), 11);
    drop(connection);

    let golden_path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/v3-schema.json");
    let golden: Value =
        serde_json::from_str(&std::fs::read_to_string(&golden_path).expect("read golden"))
            .expect("parse golden");

    let (objects, migrations) = dump_schema(&path);
    let golden_objects = golden["objects"].as_array().expect("golden objects");
    assert_eq!(
        objects.len(),
        golden_objects.len(),
        "object count differs from v3 (v3 has {}, this build has {})",
        golden_objects.len(),
        objects.len()
    );
    for (index, golden_object) in golden_objects.iter().enumerate() {
        let ours = &objects[index];
        assert_eq!(
            ours.kind,
            golden_object["type"].as_str().unwrap(),
            "type at {index}"
        );
        assert_eq!(
            ours.name,
            golden_object["name"].as_str().unwrap(),
            "name at {index}"
        );
        assert_eq!(
            ours.table,
            golden_object["table"].as_str().unwrap(),
            "table at {index}"
        );
        assert_eq!(
            ours.sql.as_deref().unwrap_or(""),
            golden_object["sql"].as_str().unwrap_or(""),
            "SQL differs for {} {}",
            ours.kind,
            ours.name
        );
    }
    let golden_migrations: Vec<String> = golden["migrations"]
        .as_array()
        .expect("golden migrations")
        .iter()
        .map(|value| value.as_str().expect("migration name").to_owned())
        .collect();
    assert_eq!(
        migrations, golden_migrations,
        "grdb_migrations rows differ from v3"
    );
}

#[test]
fn migration_is_idempotent_and_keeps_data() {
    let temp = TempDir::new("r3-idempotent");
    let path = temp.join("rust.sqlite");
    let connection = db::open_writable(&path).expect("open writable");
    let key = test_key();
    migrate(&connection, Some(&key)).expect("first");
    let account = account_id();
    write::upsert_account(&connection, &new_account(account)).expect("account");
    let second = migrate(&connection, Some(&key)).expect("second");
    assert!(second.is_noop());
    assert_eq!(second.already_present, 11);
    let found = lagoon_api::store::accounts::find(&connection, account)
        .expect("find")
        .expect("account still there");
    assert_eq!(found.email, "r3@example.invalid");
}

fn account_id() -> Uuid {
    Uuid::parse_strict("11111111-1111-4111-8111-111111111111").expect("uuid")
}

fn new_account(id: Uuid) -> NewAccount<'static> {
    NewAccount {
        id,
        provider: "qq",
        oauth_user: "r3@example.invalid",
        email: "r3@example.invalid",
        credentials: Some(b"credential"),
        capabilities: r#"{"archiveFolder":false,"idle":false,"move":false,"serverSnippet":false,"uidplus":false,"sentFolder":false}"#,
        sync_state: "{}",
    }
}

fn new_header() -> NewHeader<'static> {
    NewHeader {
        id: Uuid::parse_strict("22222222-2222-4222-8222-222222222221").expect("uuid"),
        account_id: account_id(),
        remote_id: "r3-msg-1",
        thread_id: "r3-thread-1",
        from_address: "sender@example.invalid",
        from_name: Some("Sender"),
        subject: Some("Subject"),
        snippet: Some("a plain snippet"),
        received_at: "2025-03-01 09:00:00.000",
        list_unsubscribe: false,
        message_id_header: Some("<r3-msg-1@example.invalid>"),
        in_reply_to: None,
        references: None,
        unsubscribe_links: "[]",
    }
}

#[test]
fn write_paths_round_trip_through_the_read_store() {
    let temp = TempDir::new("r3-writes");
    let path = temp.join("rust.sqlite");
    let connection = db::open_writable(&path).expect("open writable");
    let key = test_key();
    migrate(&connection, Some(&key)).expect("migrate");

    // Account: a second upsert with the same (provider, oauth_user) must keep
    // the stored id, so a re-authorisation does not orphan the mailbox.
    let stored = write::upsert_account(&connection, &new_account(account_id())).expect("account");
    assert_eq!(stored, account_id());
    let mut changed =
        new_account(Uuid::parse_strict("99999999-9999-4999-8999-999999999999").unwrap());
    changed.email = "r3-renamed@example.invalid";
    let again = write::upsert_account(&connection, &changed).expect("second upsert");
    assert_eq!(again, account_id(), "stored id wins on conflict");
    let found = lagoon_api::store::accounts::find(&connection, account_id())
        .expect("find")
        .expect("account");
    assert_eq!(found.email, "r3-renamed@example.invalid");

    write::set_account_active(&connection, account_id(), true).expect("activate");
    write::set_folder_role(&connection, account_id(), "archiveFolder", Some(true)).expect("role");
    let found = lagoon_api::store::accounts::find(&connection, account_id())
        .expect("find")
        .expect("account");
    assert_eq!(found.capabilities.archive_folder, Some(true));
    write::set_folder_role(&connection, account_id(), "archiveFolder", None).expect("role clear");
    let found = lagoon_api::store::accounts::find(&connection, account_id())
        .expect("find")
        .expect("account");
    assert_eq!(found.capabilities.archive_folder, None);

    write::update_sync_state(
        &connection,
        account_id(),
        r#"{"cursor":"abc"}"#,
        "needsReconnect",
        Some("2025-03-01 10:00:00.000"),
        Some("authorization expired"),
    )
    .expect("sync state");

    // Header: the snippet must be sealed, and the read side must decrypt it.
    write::upsert_header(&connection, &new_header(), Some(&key)).expect("header");
    let header = lagoon_api::store::messages::find(&connection, account_id(), "r3-msg-1")
        .expect("find header")
        .expect("header exists");
    assert_eq!(header.subject.as_deref(), Some("Subject"));

    // Body: sealed with the same key the read path uses.
    write::save_body(
        &connection,
        &NewBody {
            account_id: account_id(),
            remote_id: "r3-msg-1",
            text: "hello from the writable store",
            html: Some("<p>hello</p>"),
            has_more: false,
            attachments: "[]",
            to_addresses: r#"["r3@example.invalid"]"#,
            cc_addresses: "[]",
        },
        &key,
    )
    .expect("body");
    let body = lagoon_api::store::bodies::find(&connection, account_id(), "r3-msg-1")
        .expect("get body")
        .expect("body exists");
    assert_eq!(
        key.open(&body.text_cipher).expect("open body"),
        "hello from the writable store"
    );

    // Pins.
    write::set_pinned(&connection, account_id(), "r3-msg-1", true).expect("pin");
    let pinned = lagoon_api::store::briefing::pinned_ids(&connection, account_id()).expect("pins");
    assert!(pinned.contains("r3-msg-1"));
    write::set_pinned(&connection, account_id(), "r3-msg-1", false).expect("unpin");
    let pinned = lagoon_api::store::briefing::pinned_ids(&connection, account_id()).expect("pins");
    assert!(!pinned.contains("r3-msg-1"));

    // Audit log: an action and its undo row, both visible to the read side.
    let action = write::record_action(
        &connection,
        account_id(),
        "pin",
        r#"{"remoteId":"r3-msg-1"}"#,
    )
    .expect("action");
    assert!(action > 0);
    let undo =
        write::record_undo(&connection, account_id(), action, r#"{"ok":true}"#).expect("undo");
    assert!(undo > action);
    let actions = lagoon_api::store::actions::page(&connection, account_id(), None, None, 10)
        .expect("actions page");
    // v3 hides an action once its undo exists: the log reads as the latest
    // intent, not as a history of both halves.
    assert_eq!(actions.total_count, 1);
    assert_eq!(actions.actions[0].kind, "undo");

    // Draft: sealed as one array envelope; the read store opens it.
    write::save_draft(
        &connection,
        account_id(),
        "r3-msg-1",
        &["one".to_owned(), "two".to_owned()],
        Some(0),
        &key,
    )
    .expect("draft");
    let drafts = lagoon_api::store::drafts::list(&connection, &key, account_id(), "r3-msg-1")
        .expect("drafts");
    assert_eq!(drafts[0].variants, vec!["one".to_owned(), "two".to_owned()]);

    // Deleting the account cascades: no header, body, draft, action or pin left.
    write::delete_account(&connection, account_id()).expect("delete");
    let headers: i64 = connection
        .query_row("SELECT COUNT(*) FROM message_headers", [], |row| row.get(0))
        .expect("count");
    assert_eq!(headers, 0);
    for table in [
        "message_bodies",
        "draft_replies",
        "ai_actions",
        "message_pins",
    ] {
        let count: i64 = connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .expect("count");
        assert_eq!(count, 0, "{table} should cascade");
    }
}

#[test]
fn legacy_plaintext_bodies_are_sealed_by_the_v6_step() {
    let temp = TempDir::new("r3-legacy");
    let path = temp.join("rust.sqlite");
    let connection = db::open_writable(&path).expect("open writable");
    let key = test_key();
    migrate(&connection, Some(&key)).expect("migrate");
    write::upsert_account(&connection, &new_account(account_id())).expect("account");
    let mut header = new_header();
    header.snippet = None;
    write::upsert_header(&connection, &header, None).expect("header without snippet");
    connection
        .execute_batch(
            "INSERT INTO message_bodies (account_id, remote_id, body_cipher)
             VALUES (x'11111111111141118111111111111111', 'r3-msg-1', 'plaintext body')",
        )
        .expect("legacy body");
    seal_legacy_bodies(&connection, Some(&key)).expect("seal");
    let sealed: String = connection
        .query_row("SELECT body_cipher FROM message_bodies", [], |row| {
            row.get(0)
        })
        .expect("body");
    assert!(sealed.starts_with("lgb1:"));
    assert_eq!(key.open(&sealed).expect("open"), "plaintext body");
}

#[test]
fn folder_roles_merge_instead_of_replacing_the_blob() {
    let temp = TempDir::new("r3-roles");
    let path = temp.join("rust.sqlite");
    let connection = db::open_writable(&path).expect("open writable");
    migrate(&connection, Some(&test_key())).expect("migrate");
    write::upsert_account(&connection, &new_account(account_id())).expect("account");
    write::set_folder_role(&connection, account_id(), "archiveFolder", Some(false)).expect("one");
    write::set_folder_role(&connection, account_id(), "sentFolder", Some(true)).expect("two");
    let found = lagoon_api::store::accounts::find(&connection, account_id())
        .expect("find")
        .expect("account");
    assert_eq!(found.capabilities.archive_folder, Some(false));
    assert_eq!(found.capabilities.sent_folder, Some(true));
    assert!(!found.capabilities.idle);
}
