//! The AI gateway: the one door between the routes and a model.
//!
//! What it adds on top of "send a request":
//!
//! * **Routing.** A job (`summary`, `draft`, ...) goes to the provider the
//!   configuration routes it to. A job nobody routes to has no provider.
//! * **Keys.** The key lives in an environment variable, read at call time.
//!   A missing key is "not configured", not a crash.
//! * **A circuit breaker.** When the provider keeps failing, stop asking: the
//!   user gets "the AI is cooling down" instead of a ten-second hang per
//!   click.
//! * **A cost figure.** Every call reports what it cost, so the ledger in
//!   `usage_log` can be real instead of an estimate.

use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use super::config::{AiConfig, AiProvider};
use super::transport::{AiRequest, AiTransport, AiTransportError};

/// How many consecutive failures open the circuit.
pub const FAILURE_THRESHOLD: u32 = 3;
/// How long the circuit stays open before one call is allowed through.
pub const BREAKER_COOLDOWN: Duration = Duration::from_secs(60);

/// Reads an environment variable. Injectable so tests never touch the real
/// environment.
pub type KeySource = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// This month's spend, and the user's cap for it (both in micro-USD).
///
/// A cap of zero means "no cap", which is what an unset
/// `LAGOON_BUDGET_USD_PER_MONTH` means to v3. The spend is read from the same
/// ledger `/api/usage` shows, so the number the user sees and the number the
/// gate uses can never disagree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Budget {
    pub spent_micro_usd: i64,
    pub cap_micro_usd: i64,
}

impl Budget {
    /// Is the cap reached? A zero cap is never reached.
    pub fn is_spent(&self) -> bool {
        self.cap_micro_usd > 0 && self.spent_micro_usd >= self.cap_micro_usd
    }
}

/// Reads the month's spend. Injectable, like [`KeySource`], so the gateway
/// stays free of the store.
pub type BudgetSource = Arc<dyn Fn() -> Budget + Send + Sync>;

/// Why no answer came back.
#[derive(Debug, Clone, PartialEq)]
pub enum AiError {
    /// No provider for this job, or the provider's key is missing.
    NotConfigured(String),
    /// The provider says the account has no credit left.
    CreditExhausted,
    /// The month's own budget cap is reached. The provider is fine; the user
    /// said "not more than this".
    BudgetExceeded,
    /// The circuit is open: the provider is failing and we stopped asking.
    CircuitOpen,
    /// The provider could not be reached.
    Unreachable(String),
    /// The provider answered, but not with anything usable.
    Provider(String),
}

impl std::fmt::Display for AiError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AiError::NotConfigured(reason) => {
                write!(formatter, "ai not configured: {reason}")
            }
            AiError::CreditExhausted => formatter.write_str("ai credit exhausted"),
            AiError::BudgetExceeded => formatter.write_str("ai monthly budget exhausted"),
            AiError::CircuitOpen => formatter.write_str("ai circuit open"),
            AiError::Unreachable(reason) => write!(formatter, "ai unreachable: {reason}"),
            AiError::Provider(reason) => write!(formatter, "ai provider error: {reason}"),
        }
    }
}

impl std::error::Error for AiError {}

/// One answer, with what it cost.
#[derive(Debug, Clone, PartialEq)]
pub struct AiCompletion {
    pub text: String,
    pub provider: String,
    pub model: String,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub cost_micro_usd: i64,
}

/// The degraded signal `/api/ai-status` reports.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AiStatus {
    pub configured: bool,
    pub credit_exhausted: bool,
    pub circuit_open: bool,
}

#[derive(Debug, Default)]
struct GatewayState {
    failures: u32,
    opened_at: Option<Instant>,
    credit_exhausted: bool,
}

pub struct AiGateway {
    config: RwLock<AiConfig>,
    transport: Arc<dyn AiTransport>,
    keys: KeySource,
    budget: BudgetSource,
    state: Mutex<GatewayState>,
}

impl AiGateway {
    pub fn new(config: AiConfig, transport: Arc<dyn AiTransport>) -> Self {
        Self {
            config: RwLock::new(config),
            transport,
            keys: Arc::new(|name| std::env::var(name).ok()),
            // No budget source means no cap: the routes without a store (and
            // every unit test) keep working, and "no ledger" is not "zero
            // allowed".
            budget: Arc::new(|| Budget {
                spent_micro_usd: 0,
                cap_micro_usd: 0,
            }),
            state: Mutex::new(GatewayState::default()),
        }
    }

    /// Replace the key source (tests).
    pub fn with_keys(mut self, keys: KeySource) -> Self {
        self.keys = keys;
        self
    }

    /// Replace the budget source: the month's spend and the user's cap.
    pub fn with_budget(mut self, budget: BudgetSource) -> Self {
        self.budget = budget;
        self
    }

    /// The configuration in force.
    pub fn config(&self) -> AiConfig {
        self.config.read().expect("ai config lock").clone()
    }

    /// Swap in a new configuration and forget the degraded state.
    ///
    /// A reload is the user saying "I fixed it, try again" - so the credit
    /// flag and the open circuit are cleared. Keeping them would make the
    /// button do nothing, which is the one thing a "try again" button must
    /// never do.
    pub fn reload(&self, config: AiConfig) {
        *self.config.write().expect("ai config lock") = config;
        let mut state = self.state.lock().expect("ai state lock");
        state.failures = 0;
        state.opened_at = None;
        state.credit_exhausted = false;
    }

    /// The degraded signal.
    pub fn status(&self) -> AiStatus {
        let config = self.config.read().expect("ai config lock");
        let configured = config
            .providers
            .iter()
            .filter(|provider| self.key_for(provider).is_some())
            .any(|provider| config.routing.values().any(|name| name == &provider.name));
        let state = self.state.lock().expect("ai state lock");
        AiStatus {
            configured,
            credit_exhausted: state.credit_exhausted,
            circuit_open: circuit_open(&state),
        }
    }

    /// Ask the model to do a job.
    pub async fn complete(
        &self,
        capability: &str,
        system: &str,
        user: &str,
    ) -> Result<AiCompletion, AiError> {
        let provider = {
            let config = self.config.read().expect("ai config lock");
            config.route(capability).cloned()
        };
        let Some(provider) = provider else {
            return Err(AiError::NotConfigured(format!(
                "no provider serves {capability}"
            )));
        };
        let Some(api_key) = self.key_for(&provider) else {
            return Err(AiError::NotConfigured(format!(
                "{} is not set",
                provider.api_key_env
            )));
        };

        // The hard stop comes before the breaker: "this month is spent" is a
        // fact the user must act on, while "the provider is cooling down"
        // passes by itself.
        if (self.budget)().is_spent() {
            return Err(AiError::BudgetExceeded);
        }

        {
            let state = self.state.lock().expect("ai state lock");
            if circuit_open(&state) {
                return Err(AiError::CircuitOpen);
            }
        }

        let request = AiRequest {
            url: provider.chat_url(),
            api_key,
            model: provider.model.clone(),
            system: system.to_owned(),
            user: user.to_owned(),
            max_tokens: Some(MAX_TOKENS),
        };
        let reply = match self.transport.chat(request).await {
            Ok(reply) => reply,
            Err(error) => return Err(self.record_failure(&provider, error)),
        };
        self.record_success();
        Ok(AiCompletion {
            text: reply.content,
            provider: provider.name.clone(),
            model: provider.model.clone(),
            prompt_tokens: reply.prompt_tokens,
            completion_tokens: reply.completion_tokens,
            cost_micro_usd: provider.cost_micro_usd(reply.prompt_tokens, reply.completion_tokens),
        })
    }

    /// The key for a provider, if the environment has one.
    fn key_for(&self, provider: &AiProvider) -> Option<String> {
        (self.keys)(&provider.api_key_env)
            .map(|key| key.trim().to_owned())
            .filter(|key| !key.is_empty())
    }

    /// A failed call: count it, maybe open the circuit, and say what happened.
    fn record_failure(&self, provider: &AiProvider, error: AiTransportError) -> AiError {
        let mut state = self.state.lock().expect("ai state lock");
        match &error {
            AiTransportError::Rejected { status, body } if is_credit_problem(*status, body) => {
                // Out of credit is not a broken provider: it is a fact about
                // the account, and it must not open the circuit (the provider
                // is fine; the wallet is empty).
                state.credit_exhausted = true;
                AiError::CreditExhausted
            }
            AiTransportError::Unreachable(reason) => {
                state.failures += 1;
                if state.failures >= FAILURE_THRESHOLD && state.opened_at.is_none() {
                    state.opened_at = Some(Instant::now());
                    tracing::warn!(
                        provider = %provider.name,
                        "ai.circuitOpen: the provider keeps failing"
                    );
                }
                AiError::Unreachable(reason.clone())
            }
            AiTransportError::Rejected { status, .. } => {
                state.failures += 1;
                AiError::Provider(format!("provider answered {status}"))
            }
            AiTransportError::Malformed(reason) => {
                state.failures += 1;
                AiError::Provider(reason.clone())
            }
        }
    }

    /// A good call: the provider is healthy again.
    fn record_success(&self) {
        let mut state = self.state.lock().expect("ai state lock");
        state.failures = 0;
        state.opened_at = None;
        state.credit_exhausted = false;
    }
}

/// The default answer length. Long enough for a summary plus action items,
/// short enough that a runaway prompt cannot cost a fortune.
const MAX_TOKENS: u32 = 800;

/// Is the circuit open right now?
fn circuit_open(state: &GatewayState) -> bool {
    match state.opened_at {
        Some(opened) => opened.elapsed() < BREAKER_COOLDOWN,
        None => false,
    }
}

/// Does this rejection mean "no credit left"?
///
/// The providers answer that in two ways: a status (402/429) and, for some, a
/// body that says the balance is short. Both are checked, because the status
/// alone would miss the Chinese-language providers' habit of answering 200
/// with an error object.
fn is_credit_problem(status: u16, body: &str) -> bool {
    if status == 402 || status == 429 {
        return true;
    }
    let lowered = body.to_lowercase();
    lowered.contains("insufficient balance")
        || lowered.contains("insufficient_quota")
        || lowered.contains("quota")
        || body.contains("余额不足")
        || body.contains("额度不足")
}

/// What the probe found: the model answered.
#[derive(Debug, Clone, PartialEq)]
pub struct AiProbe {
    pub provider: String,
    pub model: String,
    pub latency_ms: u128,
}

impl AiGateway {
    /// The cheapest question that gets an honest answer: "are you there?".
    ///
    /// The probe goes to the primary provider (the one with the lowest
    /// priority that has a key), not to whatever a capability happens to
    /// route to: the user wants to know whether the AI works at all.
    pub async fn probe(&self) -> Result<AiProbe, AiError> {
        let provider = {
            let config = self.config.read().expect("ai config lock");
            let mut candidates: Vec<&AiProvider> = config
                .providers
                .iter()
                .filter(|provider| self.key_for(provider).is_some())
                .collect();
            candidates.sort_by_key(|provider| provider.priority);
            candidates.first().map(|provider| (*provider).clone())
        };
        let Some(provider) = provider else {
            return Err(AiError::NotConfigured("no provider has a key".to_owned()));
        };
        // A probe costs money too: it is a model call. When the month's cap is
        // reached, the honest answer to "does the AI work?" is "no, the
        // budget is gone".
        if (self.budget)().is_spent() {
            return Err(AiError::BudgetExceeded);
        }
        let api_key = self.key_for(&provider).unwrap_or_default();
        let started = Instant::now();
        let reply = self
            .transport
            .chat(AiRequest {
                url: provider.chat_url(),
                api_key,
                model: provider.model.clone(),
                system: "只回答 OK。".to_owned(),
                user: "ping".to_owned(),
                max_tokens: Some(16),
            })
            .await;
        let latency_ms = started.elapsed().as_millis();
        match reply {
            Ok(_) => {
                self.record_success();
                Ok(AiProbe {
                    provider: provider.name.clone(),
                    model: provider.model.clone(),
                    latency_ms,
                })
            }
            Err(error) => Err(self.record_failure(&provider, error)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::fake::ScriptedTransport;
    use crate::ai::transport::AiReply;

    const CONFIG: &str = r#"{
      "version": 1,
      "providers": [
        {
          "name": "minimax",
          "baseURL": "https://api.example.test/v1",
          "apiKeyEnv": "TEST_LLM_KEY",
          "model": "M3",
          "priority": 1,
          "capabilities": ["summary", "draft"],
          "chatPath": "/chat/completions",
          "costPer1kPromptUsd": 0.0006,
          "costPer1kCompletionUsd": 0.0024
        }
      ],
      "routing": { "summary": "minimax", "draft": "minimax" }
    }"#;

    fn gateway_with_key(key: Option<&str>) -> (AiGateway, Arc<ScriptedTransport>) {
        let transport = Arc::new(ScriptedTransport::new());
        let owned_key = key.map(str::to_owned);
        let gateway = AiGateway::new(
            AiConfig::from_json(CONFIG).expect("config"),
            Arc::clone(&transport) as Arc<dyn AiTransport>,
        )
        .with_keys(Arc::new(move |name| {
            if name == "TEST_LLM_KEY" {
                owned_key.clone()
            } else {
                None
            }
        }));
        (gateway, transport)
    }

    #[tokio::test]
    async fn a_configured_gateway_answers_and_reports_the_cost() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        transport.script(vec![Ok(AiReply {
            content: "a summary".to_owned(),
            prompt_tokens: 1000,
            completion_tokens: 1000,
        })]);
        let completion = gateway
            .complete("summary", "system", "user")
            .await
            .expect("answered");
        assert_eq!(completion.text, "a summary");
        assert_eq!(completion.model, "M3");
        assert_eq!(completion.cost_micro_usd, 3000);
        let calls = transport.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].api_key, "secret");
        assert_eq!(calls[0].url, "https://api.example.test/v1/chat/completions");
    }

    #[tokio::test]
    async fn a_missing_key_is_not_configured_and_never_calls_out() {
        let (gateway, transport) = gateway_with_key(None);
        let error = gateway
            .complete("summary", "system", "user")
            .await
            .expect_err("must fail");
        assert!(matches!(error, AiError::NotConfigured(_)));
        assert!(transport.calls().is_empty());
        assert!(!gateway.status().configured);
    }

    #[tokio::test]
    async fn an_unrouted_job_has_no_provider() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        let error = gateway
            .complete("classify", "system", "user")
            .await
            .expect_err("must fail");
        assert!(matches!(error, AiError::NotConfigured(_)));
        assert!(transport.calls().is_empty());
    }

    #[tokio::test]
    async fn three_failures_open_the_circuit_and_stop_the_calls() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        transport.script(vec![
            Err(AiTransportError::Unreachable("boom".to_owned())),
            Err(AiTransportError::Unreachable("boom".to_owned())),
            Err(AiTransportError::Unreachable("boom".to_owned())),
        ]);
        for _ in 0..3 {
            let error = gateway
                .complete("summary", "system", "user")
                .await
                .expect_err("must fail");
            assert!(matches!(error, AiError::Unreachable(_)));
        }
        assert!(gateway.status().circuit_open);
        // The fourth call never leaves the machine.
        let error = gateway
            .complete("summary", "system", "user")
            .await
            .expect_err("must fail");
        assert!(matches!(error, AiError::CircuitOpen));
        assert_eq!(transport.calls().len(), 3);
    }

    #[tokio::test]
    async fn a_good_call_closes_the_circuit_again() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        transport.script(vec![
            Err(AiTransportError::Unreachable("boom".to_owned())),
            Err(AiTransportError::Unreachable("boom".to_owned())),
            Err(AiTransportError::Unreachable("boom".to_owned())),
            Ok(AiReply {
                content: "back".to_owned(),
                prompt_tokens: 1,
                completion_tokens: 1,
            }),
        ]);
        for _ in 0..3 {
            let _ = gateway.complete("summary", "system", "user").await;
        }
        assert!(gateway.status().circuit_open);
        // The cooldown has not passed, so the call is refused - until a
        // reload, which is the user's "try again".
        gateway.reload(AiConfig::from_json(CONFIG).expect("config"));
        assert!(!gateway.status().circuit_open);
        let completion = gateway
            .complete("summary", "system", "user")
            .await
            .expect("answered");
        assert_eq!(completion.text, "back");
    }

    #[tokio::test]
    async fn a_quota_answer_is_credit_exhausted_and_not_a_circuit_breaker() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        transport.script(vec![Err(AiTransportError::Rejected {
            status: 429,
            body: "insufficient balance".to_owned(),
        })]);
        let error = gateway
            .complete("summary", "system", "user")
            .await
            .expect_err("must fail");
        assert!(matches!(error, AiError::CreditExhausted));
        let status = gateway.status();
        assert!(status.credit_exhausted);
        assert!(!status.circuit_open);
        assert!(status.configured);
    }

    #[tokio::test]
    async fn a_reload_clears_the_credit_flag() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        transport.script(vec![Err(AiTransportError::Rejected {
            status: 429,
            body: "余额不足".to_owned(),
        })]);
        let _ = gateway.complete("summary", "system", "user").await;
        assert!(gateway.status().credit_exhausted);
        gateway.reload(AiConfig::from_json(CONFIG).expect("config"));
        assert!(!gateway.status().credit_exhausted);
    }

    #[tokio::test]
    async fn the_status_says_configured_only_when_a_key_exists() {
        let (gateway, _transport) = gateway_with_key(Some("secret"));
        assert!(gateway.status().configured);
    }

    #[tokio::test]
    async fn a_month_at_the_cap_refuses_the_call_before_the_network() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        let gateway = gateway.with_budget(Arc::new(|| Budget {
            spent_micro_usd: 5_000_000,
            cap_micro_usd: 5_000_000,
        }));
        let error = gateway
            .complete("summary", "system", "user")
            .await
            .expect_err("must fail");
        assert!(matches!(error, AiError::BudgetExceeded));
        assert!(
            transport.calls().is_empty(),
            "the cap is checked before anything leaves the machine"
        );
    }

    #[tokio::test]
    async fn the_last_cent_below_the_cap_still_buys_one_call() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        let gateway = gateway.with_budget(Arc::new(|| Budget {
            spent_micro_usd: 4_999_999,
            cap_micro_usd: 5_000_000,
        }));
        transport.script(vec![Ok(AiReply {
            content: "ok".to_owned(),
            prompt_tokens: 1,
            completion_tokens: 1,
        })]);
        let completion = gateway
            .complete("summary", "system", "user")
            .await
            .expect("answered");
        assert_eq!(completion.text, "ok");
    }

    #[tokio::test]
    async fn a_zero_cap_means_no_cap() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        let gateway = gateway.with_budget(Arc::new(|| Budget {
            spent_micro_usd: 1_000_000_000,
            cap_micro_usd: 0,
        }));
        transport.script(vec![Ok(AiReply {
            content: "ok".to_owned(),
            prompt_tokens: 1,
            completion_tokens: 1,
        })]);
        gateway
            .complete("summary", "system", "user")
            .await
            .expect("a budget of zero is not a budget");
    }

    #[tokio::test]
    async fn a_probe_is_also_refused_when_the_budget_is_gone() {
        let (gateway, transport) = gateway_with_key(Some("secret"));
        let gateway = gateway.with_budget(Arc::new(|| Budget {
            spent_micro_usd: 6_000_000,
            cap_micro_usd: 5_000_000,
        }));
        let error = gateway.probe().await.expect_err("must fail");
        assert!(matches!(error, AiError::BudgetExceeded));
        assert!(transport.calls().is_empty());
    }
}
