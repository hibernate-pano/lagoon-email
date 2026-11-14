//! Process configuration: where the store is, what to bind, and who may call.
//!
//! The env-var contract is v3's (`Sources/LagoonServer/Config.swift` and
//! `Sources/LagoonServerCLI/main.swift`), because `scripts/dev.sh` and the
//! shell supervisor already speak it:
//!
//! | 变量 | 作用 |
//! |---|---|
//! | `LAGOON_DB_PATH` | SQLite file (v3 spelling) |
//! | `LAGOON_V4_DATA_DIR` | v4's data dir; used when `LAGOON_DB_PATH` is unset |
//! | `LAGOON_SERVER_HOST` / `--host` | bind address (default `127.0.0.1`) |
//! | `LAGOON_SERVER_PORT` / `--port` | bind port (default 8080, `0` = ephemeral) |
//! | `LAGOON_API_TOKEN` | bearer token; **required** - no token, no server |
//! | `LAGOON_BODY_KEY` | base64 of the 32-byte body key; **required** |
//!
//! Deliberate refusals, copied from v3 rather than reinvented:
//!
//! * A missing `LAGOON_API_TOKEN` refuses to start. The shell always sets one
//!   (it generates `keys.json`); a server that starts without it would answer
//!   every local request unauthenticated, so there is no "auth disabled" mode
//!   to fall into by forgetting an env var. v3 only refused for non-loopback
//!   binds - this is deliberately stricter, because the threat model includes
//!   other local processes, not just the network.
//! * A missing or malformed `LAGOON_BODY_KEY` refuses to start (v3 CLI). It is
//!   the key that makes cached bodies readable; serving a store whose bodies
//!   cannot be opened would answer 503 for every message with no explanation.
//! * An unknown command-line flag refuses to start. v3's CLI learned this the
//!   hard way: `--db /tmp/copy.sqlite` used to be ignored, and the run silently
//!   migrated the user's real store instead.

use std::collections::HashSet;
use std::path::PathBuf;

use crate::crypto::BodyKey;

/// Host names `Host:` may carry before the allow-list is widened to the bind
/// address - v3 `LoopbackHost.allowedNames`.
pub const LOOPBACK_HOSTS: [&str; 3] = ["127.0.0.1", "localhost", "::1"];

/// The development store, relative to this crate at build time.
///
/// A published build always receives `--db` or `LAGOON_DB_PATH` from the shell;
/// this default exists so `cargo run` in a checkout does the obvious thing.
const DEFAULT_DB_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../.dev/data/lagoon.sqlite");

const DEFAULT_PORT: u16 = 8080;

#[derive(Debug)]
pub enum ConfigError {
    UnknownArgument(String),
    MissingValue(String),
    MissingBodyKey,
    MalformedBodyKey(crate::crypto::CipherError),
    MalformedTokenKey(crate::token::TokenCipherError),
    MissingApiToken,
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigError::UnknownArgument(argument) => write!(
                formatter,
                "unknown argument {argument:?}: this process refuses to start rather than ignore it"
            ),
            ConfigError::MissingValue(flag) => write!(formatter, "{flag} needs a value"),
            ConfigError::MissingBodyKey => formatter.write_str(
                "refusing to start: LAGOON_BODY_KEY is missing.\n\
                 It must be base64 of exactly 32 random bytes - the same value the\n\
                 v3 sidecar and the app's Keychain item 'lagoon.bodyKey' hold.",
            ),
            ConfigError::MalformedBodyKey(cause) => write!(
                formatter,
                "refusing to start: LAGOON_BODY_KEY is malformed ({cause})"
            ),
            ConfigError::MalformedTokenKey(cause) => write!(
                formatter,
                "refusing to start: LAGOON_TOKEN_KEY is malformed ({cause})"
            ),
            ConfigError::MissingApiToken => formatter.write_str(
                "refusing to start: LAGOON_API_TOKEN is missing.\n\
                 This server has no unauthenticated mode: without a token every local\n\
                 request would be accepted. The shell generates one in keys.json and\n\
                 always passes it; a manual run must set it too.",
            ),
        }
    }
}

impl std::error::Error for ConfigError {}

#[derive(Debug)]
pub struct Config {
    pub db_path: PathBuf,
    pub host: String,
    pub port: u16,
    pub api_token: Option<String>,
    pub body_key: BodyKey,
    /// `LAGOON_BUDGET_USD_PER_MONTH` - the monthly AI cap /api/usage reports.
    /// Zero when unset or unparseable, which is what "no cap" means to v3.
    pub budget_cap_usd: f64,
    /// `LAGOON_TOKEN_KEY` - seals credential blobs (v3 AccessTokenCipher).
    /// Optional so read-only deployments keep working; the account write
    /// routes refuse to seal without it rather than store a plaintext secret.
    pub token_key: Option<crate::token::TokenKey>,
}

impl Config {
    /// Read the real environment and command line.
    pub fn load(args: &[String]) -> Result<Self, ConfigError> {
        Self::load_with(args, &|name| std::env::var(name).ok())
    }

    /// Same, with the environment injected so precedence is testable.
    pub fn load_with(
        args: &[String],
        env: &dyn Fn(&str) -> Option<String>,
    ) -> Result<Self, ConfigError> {
        let mut db_override = None;
        let mut host_override = None;
        let mut port_override = None;
        let mut index = 0;
        while index < args.len() {
            let argument = args[index].as_str();
            match argument {
                "--db" | "--host" | "--port" => {
                    let value = args
                        .get(index + 1)
                        .cloned()
                        .ok_or_else(|| ConfigError::MissingValue(argument.to_owned()))?;
                    match argument {
                        "--db" => db_override = Some(PathBuf::from(value)),
                        "--host" => host_override = Some(value),
                        _ => port_override = Some(value),
                    }
                    index += 2;
                }
                other => return Err(ConfigError::UnknownArgument(other.to_owned())),
            }
        }

        let db_path = db_override
            .or_else(|| non_empty(env("LAGOON_DB_PATH")).map(PathBuf::from))
            .or_else(|| {
                non_empty(env("LAGOON_V4_DATA_DIR"))
                    .map(|dir| PathBuf::from(dir).join("lagoon.sqlite"))
            })
            .unwrap_or_else(|| PathBuf::from(DEFAULT_DB_PATH));

        let host = host_override
            .or_else(|| non_empty(env("LAGOON_SERVER_HOST")))
            .unwrap_or_else(|| "127.0.0.1".to_owned());

        // v3: `Int(env["LAGOON_SERVER_PORT"] ?? "8080") ?? 8080` - an
        // unparseable port falls back to the default instead of failing.
        let port = port_override
            .or_else(|| env("LAGOON_SERVER_PORT"))
            .and_then(|raw| raw.trim().parse::<u16>().ok())
            .unwrap_or(DEFAULT_PORT);

        let raw_key = non_empty(env("LAGOON_BODY_KEY")).ok_or(ConfigError::MissingBodyKey)?;
        let body_key = BodyKey::from_base64(&raw_key).map_err(ConfigError::MalformedBodyKey)?;

        // Required for every bind, loopback included. A missing token is a
        // broken deployment, never "auth disabled" (see the module doc).
        let api_token = non_empty(env("LAGOON_API_TOKEN")).ok_or(ConfigError::MissingApiToken)?;

        // v3 reads the cap the same way and treats an unusable value as "no
        // cap"; a non-finite cap must not reach the JSON encoder.
        let token_key = match non_empty(env("LAGOON_TOKEN_KEY")) {
            None => None,
            Some(raw) => Some(
                crate::token::TokenKey::from_base64(&raw)
                    .map_err(ConfigError::MalformedTokenKey)?,
            ),
        };

        let budget_cap_usd = env("LAGOON_BUDGET_USD_PER_MONTH")
            .and_then(|raw| raw.trim().parse::<f64>().ok())
            .filter(|value| value.is_finite() && *value > 0.0)
            .unwrap_or(0.0);

        Ok(Self {
            db_path: collapse_dots(&db_path),
            host,
            port,
            api_token: Some(api_token),
            body_key,
            budget_cap_usd,
            token_key,
        })
    }

    /// v3 `ServerConfig.isLoopback`.
    pub fn is_loopback(&self) -> bool {
        is_loopback(&self.host)
    }

    /// v3 `ServerConfig.isWildcardBind` - a wildcard names no single host, so it
    /// cannot widen the allow-list.
    pub fn is_wildcard_bind(&self) -> bool {
        matches!(
            self.host.trim().to_lowercase().as_str(),
            "0.0.0.0" | "::" | "*" | ""
        )
    }

    /// Host names a request may address - v3 `ServerConfig.allowedHostNames`.
    pub fn allowed_host_names(&self) -> HashSet<String> {
        let mut names: HashSet<String> = LOOPBACK_HOSTS
            .iter()
            .map(|name| (*name).to_owned())
            .collect();
        if self.api_token.is_some() && !self.is_wildcard_bind() {
            let bound = normalize_host(&self.host);
            if !bound.is_empty() {
                names.insert(bound);
            }
        }
        names
    }
}

/// v3 `LoopbackHost.normalize`: strip a port and IPv6 brackets, lowercase.
///
/// A bare IPv6 literal carries several colons, so only a single colon means
/// `host:port`.
pub fn normalize_host(raw: &str) -> String {
    let value = raw.trim().to_lowercase();
    if let Some(rest) = value.strip_prefix('[') {
        return match rest.split_once(']') {
            Some((inside, _)) => inside.to_owned(),
            None => value,
        };
    }
    if value.matches(':').count() == 1 {
        if let Some((host, _port)) = value.split_once(':') {
            return host.to_owned();
        }
    }
    value
}

/// Collapse `.` and `..` lexically so a log line names the file it read.
///
/// No filesystem access: the path is allowed not to exist yet at this point
/// (`open_read_only` is what reports a missing store), and a relative path that
/// starts with `..` keeps it.
fn collapse_dots(path: &std::path::Path) -> std::path::PathBuf {
    let mut out = std::path::PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            std::path::Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn is_loopback(host: &str) -> bool {
    matches!(
        host.trim().to_lowercase().as_str(),
        "127.0.0.1" | "::1" | "localhost"
    )
}

/// Trimmed, or `None` when the variable is unset or blank (§“unset/empty” is the
/// same state for every env var in the v3 contract).
fn non_empty(value: Option<String>) -> Option<String> {
    value
        .map(|raw| raw.trim().to_owned())
        .filter(|raw| !raw.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// base64 of the spike's test-vector seed (never a real Keychain key).
    fn key_b64() -> String {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode("0123456789abcdef0123456789abcdef")
    }

    fn env_of(pairs: Vec<(&str, String)>) -> impl Fn(&str) -> Option<String> {
        let map: std::collections::HashMap<String, String> = pairs
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect();
        move |name| map.get(name).cloned()
    }

    fn args(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_owned()).collect()
    }

    #[test]
    fn db_path_precedence_is_flag_then_db_path_then_data_dir() {
        let env = env_of(vec![
            ("LAGOON_DB_PATH", "/tmp/from-db-path.sqlite".to_owned()),
            ("LAGOON_V4_DATA_DIR", "/tmp/data-dir".to_owned()),
            ("LAGOON_BODY_KEY", key_b64()),
            ("LAGOON_API_TOKEN", "token".to_owned()),
        ]);
        let config = Config::load_with(&args(&["--db", "/tmp/flag.sqlite"]), &env).unwrap();
        assert_eq!(config.db_path, PathBuf::from("/tmp/flag.sqlite"));

        let config = Config::load_with(&args(&[]), &env).unwrap();
        assert_eq!(config.db_path, PathBuf::from("/tmp/from-db-path.sqlite"));

        let env = env_of(vec![
            ("LAGOON_V4_DATA_DIR", "/tmp/data-dir".to_owned()),
            ("LAGOON_BODY_KEY", key_b64()),
            ("LAGOON_API_TOKEN", "token".to_owned()),
        ]);
        let config = Config::load_with(&args(&[]), &env).unwrap();
        assert_eq!(config.db_path, PathBuf::from("/tmp/data-dir/lagoon.sqlite"));
    }

    #[test]
    fn unknown_flags_refuse_instead_of_being_ignored() {
        let env = env_of(vec![
            ("LAGOON_BODY_KEY", key_b64()),
            ("LAGOON_API_TOKEN", "token".to_owned()),
        ]);
        let error = Config::load_with(&args(&["--dbb", "/tmp/x"]), &env).unwrap_err();
        assert!(matches!(error, ConfigError::UnknownArgument(_)));
    }

    #[test]
    fn a_token_is_required_for_every_bind() {
        // Non-loopback without a token: refused (this was v3's rule).
        let env = env_of(vec![("LAGOON_BODY_KEY", key_b64())]);
        let error = Config::load_with(&args(&["--host", "192.168.1.5"]), &env).unwrap_err();
        assert!(matches!(error, ConfigError::MissingApiToken));

        // Loopback without a token: also refused. There is no unauthenticated
        // mode to fall into by forgetting the variable.
        let error = Config::load_with(&args(&[]), &env).unwrap_err();
        assert!(matches!(error, ConfigError::MissingApiToken));

        // Blank is the same state as unset.
        let blank = env_of(vec![
            ("LAGOON_BODY_KEY", key_b64()),
            ("LAGOON_API_TOKEN", "   ".to_owned()),
        ]);
        let error = Config::load_with(&args(&[]), &blank).unwrap_err();
        assert!(matches!(error, ConfigError::MissingApiToken));

        let env = env_of(vec![
            ("LAGOON_BODY_KEY", key_b64()),
            ("LAGOON_API_TOKEN", "token".to_owned()),
        ]);
        let config = Config::load_with(&args(&["--host", "192.168.1.5"]), &env).unwrap();
        assert!(config.allowed_host_names().contains("192.168.1.5"));
    }

    #[test]
    fn wildcard_bind_never_widens_the_host_allow_list() {
        let env = env_of(vec![
            ("LAGOON_BODY_KEY", key_b64()),
            ("LAGOON_API_TOKEN", "token".to_owned()),
        ]);
        let config = Config::load_with(&args(&["--host", "0.0.0.0"]), &env).unwrap();
        let names = config.allowed_host_names();
        assert_eq!(names.len(), 3);
        assert!(!names.contains("0.0.0.0"));
    }

    #[test]
    fn body_key_is_required_and_validated() {
        let env = env_of(vec![]);
        assert!(matches!(
            Config::load_with(&args(&[]), &env).unwrap_err(),
            ConfigError::MissingBodyKey
        ));
        let env = env_of(vec![("LAGOON_BODY_KEY", "AAAA".to_owned())]);
        assert!(matches!(
            Config::load_with(&args(&[]), &env).unwrap_err(),
            ConfigError::MalformedBodyKey(_)
        ));
    }

    #[test]
    fn port_parsing_matches_v3_fallback() {
        let env = env_of(vec![
            ("LAGOON_BODY_KEY", key_b64()),
            ("LAGOON_API_TOKEN", "token".to_owned()),
            ("LAGOON_SERVER_PORT", "nonsense".to_owned()),
        ]);
        assert_eq!(Config::load_with(&args(&[]), &env).unwrap().port, 8080);
        let env = env_of(vec![
            ("LAGOON_BODY_KEY", key_b64()),
            ("LAGOON_API_TOKEN", "token".to_owned()),
            ("LAGOON_SERVER_PORT", "18099".to_owned()),
        ]);
        assert_eq!(Config::load_with(&args(&[]), &env).unwrap().port, 18099);
    }

    #[test]
    fn host_normalisation_matches_v3() {
        assert_eq!(normalize_host("EVIL.example"), "evil.example");
        assert_eq!(normalize_host("evil.example:8080"), "evil.example");
        assert_eq!(normalize_host("[::1]:8080"), "::1");
        assert_eq!(normalize_host("::1"), "::1");
        assert_eq!(normalize_host("127.0.0.1"), "127.0.0.1");
    }
}
