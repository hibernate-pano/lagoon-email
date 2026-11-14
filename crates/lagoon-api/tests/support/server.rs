//! A real server on an ephemeral port, backed by a throwaway store.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine as _;
use rusqlite::Connection;

use lagoon_api::config::Config;
use lagoon_api::crypto::BodyKey;
use lagoon_api::db::Db;
use lagoon_api::http::{self, AppState};

use super::fixtures::Fixtures;
use super::schema;
use super::seed::Seed;
use super::TempDir;

/// The spike's test-vector key: base64 of this ASCII seed. Never a real key.
pub const TEST_KEY_SEED: &str = "0123456789abcdef0123456789abcdef";

pub const TEST_API_TOKEN: &str = "contract-test-token";

pub fn body_key() -> BodyKey {
    let encoded = base64::engine::general_purpose::STANDARD.encode(TEST_KEY_SEED);
    BodyKey::from_base64(&encoded).expect("test body key")
}

/// The token key for the account routes: a different seed from the body key,
/// so a test that mixes them up fails loudly.
pub fn token_key() -> lagoon_api::token::TokenKey {
    let encoded =
        base64::engine::general_purpose::STANDARD.encode(b"fedcba9876543210fedcba9876543210");
    lagoon_api::token::TokenKey::from_base64(&encoded).expect("test token key")
}

/// Open a store read-write. Only the tests and the seed helpers do this.
pub fn open_read_write(path: &Path) -> Connection {
    let connection = Connection::open(path).expect("open store read-write");
    connection
        .execute_batch("PRAGMA foreign_keys = ON;")
        .expect("foreign keys");
    connection
}

/// The AI gateway the tests get when they do not bring their own: the real
/// configuration, but a key source that never finds a key.
pub fn no_key_gateway() -> Arc<lagoon_api::ai::gateway::AiGateway> {
    Arc::new(
        lagoon_api::ai::gateway::AiGateway::new(
            lagoon_api::ai::config::AiConfig::embedded().expect("the shipped config parses"),
            Arc::new(lagoon_api::ai::transport::HttpChatTransport::new()),
        )
        .with_keys(Arc::new(|_name| None)),
    )
}

pub struct TestServer {
    pub base_url: String,
    pub token: String,
    pub db_path: PathBuf,
    pub body_key: BodyKey,
    temp: TempDir,
    handle: tokio::task::JoinHandle<()>,
}

impl TestServer {
    /// Start from a seed derived from the golden fixtures.
    pub async fn spawn(label: &str) -> (Self, Fixtures) {
        let fixtures = Fixtures::load();
        let seed = Seed::from_fixtures(&fixtures);
        (Self::spawn_with_seed(label, &seed).await, fixtures)
    }

    pub async fn spawn_with_seed(label: &str, seed: &Seed) -> Self {
        Self::spawn_with(label, seed, Some(TEST_API_TOKEN)).await
    }

    pub async fn spawn_with(label: &str, seed: &Seed, token: Option<&str>) -> Self {
        let temp = TempDir::new(label);
        let db_path = temp.join("lagoon.sqlite");
        {
            let connection = open_read_write(&db_path);
            schema::create(&connection).expect("schema");
            seed.apply(&connection).expect("seed");
        }
        Self::start(db_path, token, temp).await
    }

    /// Start with a scripted provider factory (R3.3 account routes).
    pub async fn spawn_with_provider(
        label: &str,
        factory: Arc<dyn lagoon_api::provider::ProviderFactory>,
    ) -> (Self, Fixtures) {
        let fixtures = Fixtures::load();
        let seed = Seed::from_fixtures(&fixtures);
        let temp = TempDir::new(label);
        let db_path = temp.join("lagoon.sqlite");
        {
            let connection = open_read_write(&db_path);
            schema::create(&connection).expect("schema");
            seed.apply(&connection).expect("seed");
        }
        (
            Self::start_with(db_path, Some(TEST_API_TOKEN), temp, Some(factory), None).await,
            fixtures,
        )
    }

    /// Start with a scripted provider factory and a scripted AI gateway.
    ///
    /// R4: the AI routes need a gateway whose transport answers from a
    /// script, so the tests never reach the internet.
    pub async fn spawn_with_provider_and_ai(
        label: &str,
        factory: Arc<dyn lagoon_api::provider::ProviderFactory>,
        ai: Arc<lagoon_api::ai::gateway::AiGateway>,
    ) -> (Self, Fixtures) {
        let fixtures = Fixtures::load();
        let seed = Seed::from_fixtures(&fixtures);
        let temp = TempDir::new(label);
        let db_path = temp.join("lagoon.sqlite");
        {
            let connection = open_read_write(&db_path);
            schema::create(&connection).expect("schema");
            seed.apply(&connection).expect("seed");
        }
        (
            Self::start_with(db_path, Some(TEST_API_TOKEN), temp, Some(factory), Some(ai)).await,
            fixtures,
        )
    }

    /// Start with a scripted unsubscribe firer, so the route can be tested
    /// without a socket and without unsubscribing anyone for real.
    pub async fn spawn_with_unsubscribe_firer(
        label: &str,
        firer: Arc<dyn lagoon_api::unsubscribe::Firer>,
    ) -> (Self, Fixtures) {
        let fixtures = Fixtures::load();
        let seed = Seed::from_fixtures(&fixtures);
        let temp = TempDir::new(label);
        let db_path = temp.join("lagoon.sqlite");
        {
            let connection = open_read_write(&db_path);
            schema::create(&connection).expect("schema");
            seed.apply(&connection).expect("seed");
        }
        (
            Self::start_with_firer(db_path, Some(TEST_API_TOKEN), temp, firer).await,
            fixtures,
        )
    }

    /// Serve an *existing* store read-only - the mode R1 runs in.
    pub async fn spawn_on_store(label: &str, db_path: PathBuf, token: Option<&str>) -> Self {
        // The temp dir is unused here, but keeping one field means the type does
        // not need two shapes; it is removed on drop like every other.
        let temp = TempDir::new(label);
        Self::start(db_path, token, temp).await
    }

    async fn start(db_path: PathBuf, token: Option<&str>, temp: TempDir) -> Self {
        Self::start_with(db_path, token, temp, None, None).await
    }

    async fn start_with_firer(
        db_path: PathBuf,
        token: Option<&str>,
        temp: TempDir,
        firer: Arc<dyn lagoon_api::unsubscribe::Firer>,
    ) -> Self {
        Self::serve(db_path, token, temp, None, None, Some(firer)).await
    }

    async fn start_with(
        db_path: PathBuf,
        token: Option<&str>,
        temp: TempDir,
        factory: Option<Arc<dyn lagoon_api::provider::ProviderFactory>>,
        ai: Option<Arc<lagoon_api::ai::gateway::AiGateway>>,
    ) -> Self {
        Self::serve(db_path, token, temp, factory, ai, None).await
    }

    async fn serve(
        db_path: PathBuf,
        token: Option<&str>,
        temp: TempDir,
        factory: Option<Arc<dyn lagoon_api::provider::ProviderFactory>>,
        ai: Option<Arc<lagoon_api::ai::gateway::AiGateway>>,
        firer: Option<Arc<dyn lagoon_api::unsubscribe::Firer>>,
    ) -> Self {
        let db = Db::open_read_only(db_path.clone()).expect("open the store read-only");
        let body_key = body_key();
        let config = Config {
            db_path: db_path.clone(),
            host: "127.0.0.1".to_owned(),
            port: 0,
            api_token: token.map(str::to_owned),
            body_key: body_key.clone(),
            budget_cap_usd: 0.0,
            token_key: Some(token_key()),
        };
        let mut state = AppState::new(Arc::new(db), &config);
        if let Some(factory) = factory {
            state = state.with_provider_factory(factory);
        }
        if let Some(firer) = firer {
            state = state.with_unsubscribe_firer(firer);
        }
        match ai {
            Some(ai) => state = state.with_ai_gateway(ai),
            // A gateway with no keys, so the suite never depends on the
            // environment it happens to run in: the contract fixtures pin
            // `configured:false`, and a developer with a real key exported
            // would otherwise fail them.
            None => state = state.with_ai_gateway(no_key_gateway()),
        }

        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind an ephemeral port");
        let port = listener.local_addr().expect("local addr").port();
        let handle = tokio::spawn(async move {
            let _ = axum::serve(listener, http::router(state)).await;
        });

        Self {
            base_url: format!("http://127.0.0.1:{port}"),
            token: token.unwrap_or_default().to_owned(),
            db_path,
            body_key,
            temp,
            handle,
        }
    }

    pub fn temp_path(&self) -> &Path {
        self.temp.path()
    }

    /// Bearer header for this server, as the fixtures the harness sends it.
    pub fn auth_headers(&self) -> Vec<(String, String)> {
        vec![("Authorization".to_owned(), format!("Bearer {}", self.token))]
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.handle.abort();
    }
}
