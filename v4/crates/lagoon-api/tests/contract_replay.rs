//! Replay every fixture this build is expected to answer, over real HTTP.
//!
//! The store is the harness' own seed (v4/tests/contract/harness.py) on a schema
//! this crate creates, so the data - including the sealed body and the sealed
//! draft - is identical to what the fixtures were captured from, and the sealed
//! values open because the seed and this server share one test-vector body key.
//!
//! Fixtures marked r2_skip cover write routes; R2 is read-only, so they are not
//! replayed (the shell harness skips the same entries). Fixtures marked
//! contract_expected are the two 200 SearchResponses v3 could not produce; this
//! server is expected to produce them.
//!
//! If python3 or the harness is missing the test prints a skip line instead of
//! failing: the reason is environmental, not a regression, and the hermetic
//! tests in r2_paths.rs still cover the same handlers.

mod support;

use support::fixtures::{compare, Fixtures, RequestSpec};
use support::http;
use support::schema;
use support::seed;
use support::server::{open_read_write, TestServer, TEST_API_TOKEN};
use support::TempDir;

#[tokio::test]
async fn replays_every_read_only_fixture() {
    let fixtures = Fixtures::load();
    let temp = TempDir::new("contract");
    let db_path = temp.join("lagoon.sqlite");
    {
        let connection = open_read_write(&db_path);
        schema::create(&connection).expect("create the test schema");
    }
    let keep_accounts: Vec<String> = ["accountId", "accountIdB", "accountIdC"]
        .iter()
        .filter_map(|key| fixtures.seed_block().get(*key))
        .filter_map(|value| value.as_str().map(str::to_owned))
        .collect();
    if let Err(reason) =
        seed::seed_via_harness(&db_path, &seed::test_body_key_base64(), &keep_accounts)
    {
        eprintln!("skip: contract fixtures need the python harness: {reason}");
        return;
    }

    let server = TestServer::spawn_on_store("contract", db_path.clone(), Some(TEST_API_TOKEN)).await;
    let client = http::client();
    let replayable = fixtures.replayable();
    let contract_expected = fixtures.contract_expected_count();
    let mut failures: Vec<String> = Vec::new();

    for fixture in &replayable {
        let name = fixture["name"].as_str().expect("fixture name");
        let spec = RequestSpec::from_fixture(fixture);
        // The fixture may need its subject restored to healthy right before
        // the request (the 409 account-exists fixture: v3 answers 409 only
        // while the account is healthy, and the startup sync flips it).
        if let Some(hook) = &spec.pre {
            if let Err(reason) = seed::run_pre_hook(&db_path, hook) {
                eprintln!("skip: pre-request hook {hook} unavailable: {reason}");
                continue;
            }
        }
        let observed = http::request_with_body(
            &client,
            &spec.method,
            &spec.url(&server.base_url),
            &spec.headers(&server.token),
            &spec.body,
        )
        .await;
        for problem in compare(fixture, &observed) {
            failures.push(format!("{name}: {problem}"));
        }
    }

    assert!(
        !replayable.is_empty(),
        "no fixtures were replayed - the fixtures file is empty or filtered away"
    );
    assert!(
        failures.is_empty(),
        "{} divergence(s) across {} fixtures:\n{}",
        failures.len(),
        replayable.len(),
        failures.join("\n")
    );
    eprintln!(
        "replayed {} fixtures ({} of them contract_expected)",
        replayable.len(),
        contract_expected
    );
}
