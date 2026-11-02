//! R3: a parked account must come back to life when the user re-authenticates.
//!
//! The regression this pins: the supervisor kept its JoinHandle forever, so a
//! loop that had ended (auth failure -> parked) still looked "already
//! running". Re-connecting the mailbox replaced the credentials and answered
//! 201 with syncHealth "ok", but no sync round ever ran again - the inbox
//! silently stopped updating until the whole backend restarted.

mod support;

use std::sync::Arc;
use std::time::Duration;

use serde_json::json;

use lagoon_api::provider::fake::{FakeOutcome, FakeProviderFactory};
use lagoon_api::provider::{MailChangeSet, ProviderError};

use support::http;
use support::server::TestServer;

async fn connect(
    client: &http::HttpClient,
    server: &TestServer,
    email: &str,
    auth_code: &str,
) -> http::Observed {
    let body = json!({"provider": "qq", "email": email, "authCode": auth_code});
    http::request_with_body(
        client,
        "POST",
        &format!("{}/api/accounts/imap", server.base_url),
        &server.auth_headers(),
        body.to_string().as_bytes(),
    )
    .await
}

async fn wait_for_rounds(factory: &FakeProviderFactory, at_least: usize) {
    for _ in 0..200 {
        if factory.cursors().len() >= at_least {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

#[tokio::test]
async fn re_authenticating_a_parked_account_restarts_its_sync_loop() {
    let factory = Arc::new(FakeProviderFactory::new(FakeOutcome::succeeds()));
    // Round 1 fails auth -> the account parks and its loop ends.
    // Round 2 would succeed if the loop ever restarted.
    factory.pull_rounds(vec![
        Err(ProviderError::AuthFailed),
        Ok(MailChangeSet::default()),
        Ok(MailChangeSet::default()),
    ]);
    let (server, _fixtures) =
        TestServer::spawn_with_provider("r3-reconnect", factory.clone()).await;
    let client = http::client();

    let observed = connect(&client, &server, "reconnect@example.invalid", "code-1").await;
    assert_eq!(observed.status, 201, "{:?}", observed.body);

    // The first round ran and failed auth.
    wait_for_rounds(&factory, 1).await;
    assert_eq!(factory.cursors().len(), 1);

    // The user re-authenticates: the account is not healthy, so the route
    // replaces the code instead of answering 409.
    let observed = connect(&client, &server, "reconnect@example.invalid", "code-2").await;
    assert_eq!(observed.status, 201, "{:?}", observed.body);

    // A second round runs: the loop restarted.
    wait_for_rounds(&factory, 2).await;
    assert!(
        factory.cursors().len() >= 2,
        "the sync loop never restarted after re-auth: {} round(s)",
        factory.cursors().len()
    );
}
