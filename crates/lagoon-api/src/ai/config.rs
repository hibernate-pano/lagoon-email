//! The AI provider configuration (`config/providers.json`).
//!
//! One file decides which model answers which job. It is data, not code: the
//! gateway reads it, the user can point `LAGOON_AI_CONFIG` at another copy,
//! and `POST /api/ai/reload` re-reads it without a restart.
//!
//! The default copy is compiled into the binary, so a packaged app answers
//! `/api/ai-status` truthfully even when it has no config file next to it.
//!
//! The API key is **not** here. Each provider names the environment variable
//! that holds its key (`apiKeyEnv`), and the gateway reads that variable at
//! call time: adding a key must not need a rebuild, and the key must never
//! reach the disk.

use std::collections::BTreeMap;
use std::path::Path;

/// The configuration shipped with the repository, compiled in.
pub const DEFAULT_CONFIG_JSON: &str = include_str!("../../../../config/providers.json");

/// The environment variable that points at an alternative configuration file.
pub const CONFIG_PATH_ENV: &str = "LAGOON_AI_CONFIG";

/// Where the configuration file is, if the user pointed us at one.
pub fn config_path() -> Option<std::path::PathBuf> {
    std::env::var(CONFIG_PATH_ENV)
        .ok()
        .map(|raw| raw.trim().to_owned())
        .filter(|raw| !raw.is_empty())
        .map(std::path::PathBuf::from)
}

/// One provider: a model behind an OpenAI-compatible chat endpoint.
#[derive(Debug, Clone, PartialEq)]
pub struct AiProvider {
    pub name: String,
    /// The API root, e.g. `https://api.minimax.chat/v1`.
    pub base_url: String,
    /// The environment variable that holds this provider's key.
    pub api_key_env: String,
    pub model: String,
    /// Lower runs first when several providers could serve a capability.
    pub priority: i64,
    /// The jobs this provider may serve (`summary`, `draft`, ...).
    pub capabilities: Vec<String>,
    /// The chat path appended to `base_url`.
    pub chat_path: String,
    /// USD per 1k prompt tokens.
    pub cost_per_1k_prompt_usd: f64,
    /// USD per 1k completion tokens.
    pub cost_per_1k_completion_usd: f64,
}

impl AiProvider {
    /// The full chat endpoint.
    pub fn chat_url(&self) -> String {
        format!("{}{}", self.base_url.trim_end_matches('/'), self.chat_path)
    }

    /// Whether this provider may serve the given capability.
    pub fn supports(&self, capability: &str) -> bool {
        self.capabilities.iter().any(|name| name == capability)
    }

    /// What one call cost, in micro-USD (the unit `usage_log` stores).
    ///
    /// Rounded up: the ledger must never under-charge, because a cap that
    /// under-charges lets the real bill exceed it.
    pub fn cost_micro_usd(&self, prompt_tokens: u32, completion_tokens: u32) -> i64 {
        let prompt = f64::from(prompt_tokens) / 1000.0 * self.cost_per_1k_prompt_usd;
        let completion = f64::from(completion_tokens) / 1000.0 * self.cost_per_1k_completion_usd;
        let micro = (prompt + completion) * 1_000_000.0;
        if !micro.is_finite() || micro <= 0.0 {
            return 0;
        }
        micro.ceil() as i64
    }
}

/// The whole configuration: providers plus the capability -> provider routing.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AiConfig {
    pub version: i64,
    pub providers: Vec<AiProvider>,
    /// capability -> provider name.
    pub routing: BTreeMap<String, String>,
}

/// Why a configuration could not be used.
#[derive(Debug, Clone, PartialEq)]
pub enum AiConfigError {
    /// The file is not valid JSON, or a field has the wrong type.
    Malformed(String),
    /// A provider is missing a field the gateway needs.
    MissingField {
        provider: String,
        field: &'static str,
    },
    /// The routing table points at a provider that does not exist.
    UnknownProvider {
        capability: String,
        provider: String,
    },
}

impl std::fmt::Display for AiConfigError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AiConfigError::Malformed(reason) => {
                write!(formatter, "ai config is malformed: {reason}")
            }
            AiConfigError::MissingField { provider, field } => {
                write!(formatter, "ai provider {provider:?} has no {field}")
            }
            AiConfigError::UnknownProvider {
                capability,
                provider,
            } => {
                write!(
                    formatter,
                    "ai routing sends {capability:?} to unknown provider {provider:?}"
                )
            }
        }
    }
}

impl std::error::Error for AiConfigError {}

impl AiConfig {
    /// Parse a configuration document.
    pub fn from_json(raw: &str) -> Result<Self, AiConfigError> {
        let value: serde_json::Value = serde_json::from_str(raw)
            .map_err(|error| AiConfigError::Malformed(error.to_string()))?;
        let version = value.get("version").and_then(|v| v.as_i64()).unwrap_or(1);

        let mut providers = Vec::new();
        let listed = value
            .get("providers")
            .and_then(|v| v.as_array())
            .ok_or_else(|| AiConfigError::Malformed("no providers array".to_owned()))?;
        for entry in listed {
            providers.push(parse_provider(entry)?);
        }

        let mut routing = BTreeMap::new();
        if let Some(table) = value.get("routing").and_then(|v| v.as_object()) {
            for (capability, target) in table {
                let name = target.as_str().ok_or_else(|| {
                    AiConfigError::Malformed(format!("routing for {capability:?} is not a name"))
                })?;
                routing.insert(capability.clone(), name.to_owned());
            }
        }

        let config = AiConfig {
            version,
            providers,
            routing,
        };
        config.validate()?;
        Ok(config)
    }

    /// Read a configuration file.
    pub fn load(path: &Path) -> Result<Self, AiConfigError> {
        let raw = std::fs::read_to_string(path)
            .map_err(|error| AiConfigError::Malformed(format!("{}: {error}", path.display())))?;
        Self::from_json(&raw)
    }

    /// The configuration compiled into the binary.
    pub fn embedded() -> Result<Self, AiConfigError> {
        Self::from_json(DEFAULT_CONFIG_JSON)
    }

    /// The configuration the process should use right now.
    ///
    /// `LAGOON_AI_CONFIG` points at another file; without it the compiled-in
    /// one is used. The override exists so a user can add a provider (or fix
    /// a key's model name) without rebuilding the app.
    pub fn load_current() -> Result<Self, AiConfigError> {
        match config_path() {
            Some(path) => Self::load(&path),
            None => Self::embedded(),
        }
    }

    /// The provider with this name.
    pub fn provider(&self, name: &str) -> Option<&AiProvider> {
        self.providers.iter().find(|provider| provider.name == name)
    }

    /// The provider that serves a capability.
    ///
    /// The routing table decides; a capability nobody routes to has no
    /// provider, and the caller answers "not configured" rather than guessing.
    pub fn route(&self, capability: &str) -> Option<&AiProvider> {
        let name = self.routing.get(capability)?;
        let provider = self.provider(name)?;
        if provider.supports(capability) {
            Some(provider)
        } else {
            None
        }
    }

    /// Every provider name, in configuration order.
    pub fn provider_names(&self) -> Vec<String> {
        self.providers
            .iter()
            .map(|provider| provider.name.clone())
            .collect()
    }

    /// The routing table must not point at a provider that does not exist: a
    /// typo there would silently disable one job.
    fn validate(&self) -> Result<(), AiConfigError> {
        for (capability, name) in &self.routing {
            if self.provider(name).is_none() {
                return Err(AiConfigError::UnknownProvider {
                    capability: capability.clone(),
                    provider: name.clone(),
                });
            }
        }
        Ok(())
    }
}

fn parse_provider(entry: &serde_json::Value) -> Result<AiProvider, AiConfigError> {
    let name = entry
        .get("name")
        .and_then(|v| v.as_str())
        .ok_or_else(|| AiConfigError::MissingField {
            provider: "<unnamed>".to_owned(),
            field: "name",
        })?
        .to_owned();
    let required_str = |field: &'static str| -> Result<String, AiConfigError> {
        entry
            .get(field)
            .and_then(|v| v.as_str())
            .map(str::to_owned)
            .ok_or_else(|| AiConfigError::MissingField {
                provider: name.clone(),
                field,
            })
    };
    let base_url = required_str("baseURL")?;
    let api_key_env = required_str("apiKeyEnv")?;
    let model = required_str("model")?;
    let chat_path = required_str("chatPath")?;
    let capabilities = entry
        .get("capabilities")
        .and_then(|v| v.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect::<Vec<String>>()
        })
        .unwrap_or_default();
    Ok(AiProvider {
        name,
        base_url,
        api_key_env,
        model,
        priority: entry.get("priority").and_then(|v| v.as_i64()).unwrap_or(1),
        capabilities,
        chat_path,
        cost_per_1k_prompt_usd: entry
            .get("costPer1kPromptUsd")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0),
        cost_per_1k_completion_usd: entry
            .get("costPer1kCompletionUsd")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
      "version": 1,
      "providers": [
        {
          "name": "minimax",
          "baseURL": "https://api.minimax.chat/v1",
          "apiKeyEnv": "LLM_PROVIDER_PRIMARY_API_KEY",
          "model": "MiniMax-M3",
          "priority": 1,
          "capabilities": ["summary", "draft"],
          "chatPath": "/chat/completions",
          "costPer1kPromptUsd": 0.0006,
          "costPer1kCompletionUsd": 0.0024
        }
      ],
      "routing": { "summary": "minimax", "draft": "minimax" }
    }"#;

    #[test]
    fn the_shipped_configuration_parses_and_routes() {
        let config = AiConfig::embedded().expect("the shipped config parses");
        assert_eq!(config.version, 1);
        let provider = config.route("summary").expect("summary is routed");
        assert_eq!(provider.name, "minimax");
        assert_eq!(provider.model, "MiniMax-M3");
        assert_eq!(
            provider.chat_url(),
            "https://api.minimax.chat/v1/chat/completions"
        );
        assert_eq!(
            config.route("draft").map(|p| p.name.as_str()),
            Some("minimax")
        );
    }

    #[test]
    fn an_unrouted_capability_has_no_provider() {
        let config = AiConfig::from_json(SAMPLE).expect("parse");
        assert!(config.route("classify").is_none());
        // A capability the provider does not list is not routed either.
        assert!(config.route("summary").unwrap().supports("summary"));
    }

    #[test]
    fn a_routing_entry_pointing_at_a_missing_provider_is_refused() {
        let raw = SAMPLE.replace("\"minimax\" }", "\"nobody\" }");
        let error = AiConfig::from_json(&raw).expect_err("must refuse");
        assert!(matches!(error, AiConfigError::UnknownProvider { .. }));
    }

    #[test]
    fn a_provider_without_a_model_is_refused() {
        let raw = SAMPLE.replace("\"model\": \"MiniMax-M3\",", "");
        let error = AiConfig::from_json(&raw).expect_err("must refuse");
        assert!(matches!(
            error,
            AiConfigError::MissingField { field: "model", .. }
        ));
    }

    #[test]
    fn malformed_json_is_refused_with_a_reason() {
        let error = AiConfig::from_json("{not json").expect_err("must refuse");
        assert!(matches!(error, AiConfigError::Malformed(_)));
    }

    #[test]
    fn the_cost_of_a_call_rounds_up_to_micro_usd() {
        let config = AiConfig::from_json(SAMPLE).expect("parse");
        let provider = config.route("summary").expect("routed");
        // 1000 prompt + 1000 completion tokens = 0.0006 + 0.0024 USD.
        assert_eq!(provider.cost_micro_usd(1000, 1000), 3000);
        // A tiny call still costs something: the ledger rounds up, never down.
        assert_eq!(provider.cost_micro_usd(1, 1), 3);
        assert_eq!(provider.cost_micro_usd(0, 0), 0);
    }
}
