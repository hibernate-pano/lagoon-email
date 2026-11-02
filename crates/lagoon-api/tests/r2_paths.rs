//! R2 read paths with real data, without the python contract harness.
//!
//! The fixture replay in contract_replay.rs needs python3 (the seed is the
//! harness'); these tests build the same rows from Rust so the handlers stay
//! covered on a machine that only has cargo - and so the shapes that fixtures
//! cannot express (paging, a sealed draft that will not open, a sender override)
//! have somewhere to live.
//!
//! Every case seeds on the R1 base store (three messages on account A) and adds
//! only the rows it is about.

mod support;

use serde_json::json;

use lagoon_api::timefmt;
use lagoon_api::uuid::Uuid;

use support::fixtures::Fixtures;
use support::http;
use support::seed::Seed;
use support::server::{open_read_write, TestServer};

fn uuid_bytes(raw: &str) -> Vec<u8> {
    Uuid::parse_strict(raw).expect("uuid").as_bytes().to_vec()
}

async fn get(client: &http::HttpClient, url: &str, headers: &[(String, String)]) -> http::Observed {
    http::request(client, "GET", url, headers).await
}

async fn post(
    client: &http::HttpClient,
    url: &str,
    headers: &[(String, String)],
) -> http::Observed {
    http::request(client, "POST", url, headers).await
}

fn seeded(fixtures: &Fixtures) -> Seed {
    Seed::from_fixtures(fixtures)
}

#[tokio::test]
async fn advice_queue_and_accepted_stats() {
    let (server, fixtures) = TestServer::spawn("r2-advice").await;
    let seed = seeded(&fixtures);
    let account = seed.account_id.clone();
    let remote1 = seed.messages[0].remote_id.clone();
    let remote2 = seed.messages[1].remote_id.clone();
    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO advice (account_id, remote_id, action, category, confidence,
                                     rationale, source, model, decision, created_at)
                 VALUES (?, ?, 'archive', 'marketing', 'high', 'not opened in months',
                         'ai', 'contract-fixture-model', 'pending', '2025-02-01 09:00:00.000')",
                rusqlite::params![uuid_bytes(&account), remote1],
            )
            .expect("pending advice");
        connection
            .execute(
                "INSERT INTO advice (account_id, remote_id, action, category, confidence,
                                     rationale, due_text, source, decision, created_at, decided_at)
                 VALUES (?, ?, 'reply', 'work', 'medium', 'a colleague is waiting',
                         '2025-02-10', 'heuristic', 'accepted', '2025-02-02 09:00:00.000',
                         '2025-02-03 09:00:00.000')",
                rusqlite::params![uuid_bytes(&account), remote2],
            )
            .expect("accepted advice");
    }

    let client = http::client();
    let auth = server.auth_headers();
    let pending = get(
        &client,
        &format!("{}/api/advice?accountId={account}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(pending.status, 200, "{:?}", pending.body);
    let entries = pending.body["advice"].as_array().expect("advice");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["decision"], json!("pending"));
    assert_eq!(entries[0]["advice"]["action"], json!("archive"));
    assert_eq!(entries[0]["advice"]["category"], json!("marketing"));
    assert_eq!(entries[0]["model"], json!("contract-fixture-model"));

    let all = get(
        &client,
        &format!(
            "{}/api/advice?accountId={account}&decision=any",
            server.base_url
        ),
        &auth,
    )
    .await;
    let entries = all.body["advice"].as_array().expect("advice");
    assert_eq!(entries.len(), 2);
    // Newest first: the accepted row was created later.
    assert_eq!(entries[0]["decision"], json!("accepted"));
    assert_eq!(entries[0]["advice"]["dueText"], json!("2025-02-10"));
    assert_eq!(entries[1]["decision"], json!("pending"));

    let stats = get(
        &client,
        &format!(
            "{}/api/advice/accepted-stats?accountId={account}",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(stats.status, 200);
    assert_eq!(
        stats.body["stats"],
        json!([{ "action": "reply", "category": "work", "count": 1 }])
    );

    let malformed = get(
        &client,
        &format!("{}/api/advice?accountId=not-a-uuid", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(malformed.status, 400);
    assert_eq!(malformed.body, json!({ "error": "malformed-accountId" }));
}

#[tokio::test]
async fn stacks_reminders_and_notices() {
    let (server, fixtures) = TestServer::spawn("r2-lists").await;
    let seed = seeded(&fixtures);
    let account = seed.account_id.clone();
    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO stack_rules (id, account_id, name, kind, value, created_at)
                 VALUES (?, ?, 'Sender to archive', 'sender', 'alice.fixture@example.invalid',
                         '2025-02-05 09:00:00.000')",
                rusqlite::params![
                    uuid_bytes("55555555-5555-4555-8555-555555555551"),
                    uuid_bytes(&account)
                ],
            )
            .expect("sender rule");
        connection
            .execute(
                "INSERT INTO stack_rules (id, account_id, name, kind, value, created_at)
                 VALUES (?, ?, 'Subject keyword', 'keyword', 'fixture',
                         '2025-02-05 09:01:00.000')",
                rusqlite::params![
                    uuid_bytes("55555555-5555-4555-8555-555555555552"),
                    uuid_bytes(&account)
                ],
            )
            .expect("keyword rule");
        connection
            .execute(
                "INSERT INTO reminders (account_id, remote_id, due_at, note, created_at,
                                        dismissed_at)
                 VALUES (?, ?, '2025-03-01 09:00:00.000', 'follow up',
                         '2025-02-06 09:00:00.000', NULL)",
                rusqlite::params![uuid_bytes(&account), seed.messages[0].remote_id],
            )
            .expect("pending reminder");
        connection
            .execute(
                "INSERT INTO reminders (account_id, remote_id, due_at, created_at, dismissed_at)
                 VALUES (?, ?, '2025-03-02 09:00:00.000', '2025-02-06 09:01:00.000',
                         '2025-02-07 09:00:00.000')",
                rusqlite::params![uuid_bytes(&account), seed.messages[1].remote_id],
            )
            .expect("dismissed reminder");
        connection
            .execute(
                "INSERT INTO store_notices (id, detail, created_at)
                 VALUES ('fixture-notice-1', '1', '2025-02-08 09:00:00.000')",
                [],
            )
            .expect("notice");
    }

    let client = http::client();
    let auth = server.auth_headers();

    let stacks = get(
        &client,
        &format!("{}/api/stacks?accountId={account}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(stacks.status, 200, "{:?}", stacks.body);
    let stacks = stacks.body["stacks"].as_array().expect("stacks");
    assert_eq!(stacks.len(), 2);
    assert_eq!(stacks[0]["rule"]["kind"], json!("sender"));
    assert_eq!(stacks[0]["count"], json!(2));
    assert_eq!(stacks[1]["rule"]["kind"], json!("keyword"));
    assert_eq!(stacks[1]["count"], json!(2));

    let pending = get(
        &client,
        &format!("{}/api/reminders?accountId={account}", server.base_url),
        &auth,
    )
    .await;
    let reminders = pending.body["reminders"].as_array().expect("reminders");
    assert_eq!(reminders.len(), 1);
    assert_eq!(reminders[0]["note"], json!("follow up"));
    assert!(reminders[0].get("dismissedAt").is_none());

    let with_dismissed = get(
        &client,
        &format!(
            "{}/api/reminders?accountId={account}&includeDismissed=true",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(
        with_dismissed.body["reminders"]
            .as_array()
            .expect("reminders")
            .len(),
        2
    );

    let notices = get(
        &client,
        &format!("{}/api/store-notices", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(notices.status, 200);
    assert_eq!(notices.body["notices"][0]["id"], json!("fixture-notice-1"));
    assert_eq!(notices.body["notices"][0]["detail"], json!("1"));

    // /api/stacks does not check the account (v3 does not either): empty list.
    let unknown = "99999999-9999-4999-8999-999999999999";
    let empty_stacks = get(
        &client,
        &format!("{}/api/stacks?accountId={unknown}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(empty_stacks.status, 200);
    assert_eq!(empty_stacks.body["stacks"], json!([]));

    let unknown_reminders = get(
        &client,
        &format!("{}/api/reminders?accountId={unknown}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(unknown_reminders.status, 404);
}

#[tokio::test]
async fn drafts_actions_time_saved_and_usage() {
    let (server, fixtures) = TestServer::spawn("r2-audit").await;
    let seed = seeded(&fixtures);
    let account = seed.account_id.clone();
    let remote = seed.messages[0].remote_id.clone();
    let sealed_variants = server
        .body_key
        .seal(&json!(["Short reply", "Longer reply"]).to_string())
        .expect("seal variants");
    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO draft_replies (account_id, remote_id, variants, chosen_variant, created_at)
                 VALUES (?, ?, '', 1, '2025-02-07 09:00:00.000')",
                rusqlite::params![uuid_bytes(&account), remote],
            )
            .expect("draft without sealed variants");
        connection
            .execute(
                "UPDATE draft_replies SET variants = ? WHERE remote_id = ?",
                rusqlite::params![sealed_variants, remote],
            )
            .expect("seal the draft");
        let today = timefmt::to_stored(timefmt::now());
        connection
            .execute(
                "INSERT INTO ai_actions (account_id, kind, payload, created_at)
                 VALUES (?, 'send', ?, ?)",
                rusqlite::params![
                    uuid_bytes(&account),
                    json!({"remoteId": remote}).to_string(),
                    today
                ],
            )
            .expect("send action");
        connection
            .execute(
                "INSERT INTO ai_actions (account_id, kind, payload, created_at)
                 VALUES (?, 'pin', ?, ?)",
                rusqlite::params![
                    uuid_bytes(&account),
                    json!({"remoteId": remote}).to_string(),
                    today
                ],
            )
            .expect("pin action");
        let month = chrono::Local::now().format("%Y-%m").to_string();
        connection
            .execute(
                "INSERT INTO usage_log (year_month, account_email, capability, model,
                                        prompt_tokens, completion_tokens, cost_micro_usd)
                 VALUES (?, 'me@example.invalid', 'briefing', 'fixture-model', 100, 50, 250000)",
                rusqlite::params![month],
            )
            .expect("usage row");
    }

    let client = http::client();
    let auth = server.auth_headers();

    let drafts = get(
        &client,
        &format!(
            "{}/api/messages/{remote}/drafts?accountId={account}",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(drafts.status, 200, "{:?}", drafts.body);
    assert_eq!(
        drafts.body["drafts"][0]["variants"],
        json!(["Short reply", "Longer reply"])
    );
    assert_eq!(drafts.body["drafts"][0]["chosenVariant"], json!(1));

    let actions = get(
        &client,
        &format!("{}/api/actions?accountId={account}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(actions.status, 200, "{:?}", actions.body);
    let entries = actions.body["actions"].as_array().expect("actions");
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0]["kind"], json!("pin"));
    assert_eq!(entries[1]["kind"], json!("send"));
    assert_eq!(entries[0]["payload"]["remoteId"], json!(remote));
    assert_eq!(actions.body["totalCount"], json!(2));
    assert_eq!(actions.body["hasMore"], json!(false));

    // Keyset paging: asking for the rows before the newest one yields the rest.
    let newest = entries[0]["id"].as_i64().expect("id");
    let page_two = get(
        &client,
        &format!(
            "{}/api/actions?accountId={account}&before={newest}",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(page_two.status, 200, "{:?}", page_two.body);
    assert_eq!(
        page_two.body["actions"].as_array().expect("actions").len(),
        1
    );
    assert_eq!(page_two.body["hasMore"], json!(false));

    let unknown_before = get(
        &client,
        &format!(
            "{}/api/actions?accountId={account}&before=999999",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(unknown_before.status, 400);
    assert_eq!(unknown_before.body, json!({ "error": "unknown-before" }));

    let time_saved = get(
        &client,
        &format!("{}/api/time-saved?accountId={account}", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(time_saved.status, 200, "{:?}", time_saved.body);
    assert_eq!(time_saved.body["today"]["minutesSaved"], json!(2));
    assert_eq!(time_saved.body["today"]["messagesHandled"], json!(1));
    assert_eq!(time_saved.body["today"]["draftsSent"], json!(1));
    assert_eq!(
        time_saved.body["week"]["byDay"]
            .as_array()
            .expect("byDay")
            .len(),
        1
    );

    let usage = get(&client, &format!("{}/api/usage", server.base_url), &auth).await;
    assert_eq!(usage.status, 200, "{:?}", usage.body);
    assert_eq!(usage.body["monthUSD"], json!(0.25));
    assert_eq!(usage.body["callCount"], json!(1));
    assert_eq!(usage.body["capUSD"], json!(0));
    assert_eq!(usage.body["costTrackingAvailable"], json!(false));
    assert_eq!(
        usage.body["accounts"],
        json!([{ "accountEmail": "me@example.invalid", "monthUSD": 0.25, "callCount": 1 }])
    );

    let status = get(
        &client,
        &format!("{}/api/ai-status", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(
        status.body,
        json!({ "configured": false, "creditExhausted": false, "circuitOpen": false })
    );
}

#[tokio::test]
async fn search_reaches_the_sealed_body_and_the_structured_verdict() {
    let (server, fixtures) = TestServer::spawn("r2-search").await;
    let seed = seeded(&fixtures);
    let account = seed.account_id.clone();
    let remote = seed.messages[0].remote_id.clone();
    let sealed_body = server
        .body_key
        .seal("the quarterly number is sealedneedle")
        .expect("seal body");
    {
        let connection = open_read_write(&server.db_path);
        connection
            .execute(
                "INSERT INTO message_bodies (account_id, remote_id, body_cipher, has_more)
                 VALUES (?, ?, ?, 0)",
                rusqlite::params![uuid_bytes(&account), remote, sealed_body],
            )
            .expect("cached body");
        connection
            .execute(
                "INSERT INTO advice (account_id, remote_id, action, category, confidence,
                                     source, decision, created_at)
                 VALUES (?, ?, 'archive', 'marketing', 'high', 'heuristic', 'pending',
                         '2025-02-01 09:00:00.000')",
                rusqlite::params![uuid_bytes(&account), remote],
            )
            .expect("advice for the structured arm");
    }

    let client = http::client();
    let auth = server.auth_headers();

    let subject_hit = get(
        &client,
        &format!(
            "{}/api/search?accountId={account}&q=fixture",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(subject_hit.status, 200, "{:?}", subject_hit.body);
    assert_eq!(subject_hit.body["totalCount"], json!(3));
    assert_eq!(subject_hit.body["truncated"], json!(false));
    assert_eq!(subject_hit.body["bodyScanLimit"], json!(1000));
    assert_eq!(
        subject_hit.body["results"]
            .as_array()
            .expect("results")
            .len(),
        3
    );

    // The sealed arm: no column matches sealedneedle, the body does.
    let sealed_hit = get(
        &client,
        &format!(
            "{}/api/search?accountId={account}&q=sealedneedle",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(sealed_hit.status, 200, "{:?}", sealed_hit.body);
    assert_eq!(sealed_hit.body["totalCount"], json!(1));
    assert_eq!(sealed_hit.body["results"][0]["remoteId"], json!(remote));
    assert_eq!(sealed_hit.body["bodyScanSkipped"], json!(0));

    // The structured arm: the AI's category is matchable without a model call.
    let verdict_hit = get(
        &client,
        &format!(
            "{}/api/search?accountId={account}&q=marketing",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(verdict_hit.status, 200, "{:?}", verdict_hit.body);
    assert_eq!(verdict_hit.body["totalCount"], json!(1));

    let empty = get(
        &client,
        &format!("{}/api/search?accountId={account}&q=", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(empty.status, 200);
    assert_eq!(empty.body["results"], json!([]));
    assert_eq!(empty.body["totalCount"], json!(0));

    let malformed = get(
        &client,
        &format!("{}/api/search?accountId=nope&q=x", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(malformed.status, 400);
    assert_eq!(malformed.body, json!({ "error": "malformed-accountId" }));

    let cross_account = get(
        &client,
        &format!("{}/api/search?accountId=all&q=fixture", server.base_url),
        &auth,
    )
    .await;
    assert_eq!(cross_account.status, 200);
    assert_eq!(cross_account.body["totalCount"], json!(3));
}

#[tokio::test]
async fn provider_backed_routes_stop_at_the_same_gate_as_v3() {
    let (server, fixtures) = TestServer::spawn("r2-gates").await;
    let seed = seeded(&fixtures);
    let account = seed.account_id.clone();
    let remote = seed.messages[0].remote_id.clone();
    let unknown = "99999999-9999-4999-8999-999999999999";
    let client = http::client();
    let auth = server.auth_headers();

    for path in ["summary", "inline-images", "raw.eml"] {
        let hit = get(
            &client,
            &format!(
                "{}/api/messages/{remote}/{path}?accountId={account}",
                server.base_url
            ),
            &auth,
        )
        .await;
        assert_eq!(hit.status, 503, "{path}: {:?}", hit.body);
        assert_eq!(hit.body, json!({ "error": "provider-not-configured" }));
    }

    for path in ["summary", "inline-images", "raw.eml"] {
        let hit = get(
            &client,
            &format!(
                "{}/api/messages/{remote}/{path}?accountId={unknown}",
                server.base_url
            ),
            &auth,
        )
        .await;
        assert_eq!(hit.status, 404, "{path}: {:?}", hit.body);
        assert_eq!(hit.body, json!({ "error": "unknown-account" }));
    }

    let draft = post(
        &client,
        &format!(
            "{}/api/messages/{remote}/draft?accountId={account}",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(draft.status, 503, "{:?}", draft.body);
    assert_eq!(draft.body, json!({ "error": "provider-not-configured" }));

    // The capability gate answers before any provider work: the seeded account
    // has archiveFolder = false, so the client is told "this server cannot
    // archive" rather than "the network failed".
    let archive = post(
        &client,
        &format!(
            "{}/api/messages/{remote}/archive?accountId={account}",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(archive.status, 409);
    assert_eq!(archive.body, json!({ "error": "archive-unavailable" }));

    let malformed = post(
        &client,
        &format!(
            "{}/api/messages/{remote}/archive?accountId=not-a-uuid",
            server.base_url
        ),
        &auth,
    )
    .await;
    assert_eq!(malformed.status, 400);
    assert_eq!(malformed.body, json!({ "error": "malformed-accountId" }));
}
