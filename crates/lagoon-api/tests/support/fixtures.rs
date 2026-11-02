//! Golden fixtures: load, project a request, normalise, diff.
//!
//! The rules are the ones v4/tests/contract/README.md states, because this
//! module has to agree with the shell harness that replays the same file:
//!
//! * only authority-side wall-clock fields are normalised, and only by key name;
//! * every other value - including receivedAt, UUIDs, counts and error codes -
//!   must match exactly;
//! * object keys are compared as sets, so Foundation's random key order does not
//!   matter.

use std::path::{Path, PathBuf};

use serde_json::Value;

use super::http::Observed;

/// Where v4 keeps the captured fixtures, relative to this crate at build time.
pub const DEFAULT_FIXTURES_DIR: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../tests/contract/fixtures");

/// The wall-clock keys the harness normalises.
pub const TIMESTAMP_KEYS: [&str; 11] = [
    // byDay entries carry a local-midnight date; the harness normalises it too.
    "date",
    "lastFetchedAt",
    "fetchedAt",
    "lastSyncAt",
    "createdAt",
    "updatedAt",
    "decidedAt",
    "dueAt",
    "expiresAt",
    "lastErrorAt",
    "startedAt",
];

pub const NORMALIZED_VALUE: &str = "<timestamp>";

/// The fixtures R1 implements. The other endpoints of the v3 contract are out
/// of scope on purpose and are not replayed here.
pub const R1_FIXTURES: [&str; 18] = [
    "healthz",
    "accounts.list",
    "auth.missing-token",
    "auth.bad-token",
    "host.forbidden",
    "messages.list",
    "messages.list.limit",
    "messages.list.archived",
    "messages.list.pinned",
    "messages.list.unread",
    "messages.list.sender",
    "messages.list.malformed-account",
    "messages.list.missing-account",
    "folder-counts",
    "body.provider-unconfigured",
    "unknown-account",
    "unknown-route",
    "unknown-route.v2",
];

pub struct Fixtures {
    pub payload: Value,
}

impl Fixtures {
    pub fn path() -> PathBuf {
        let dir = std::env::var("LAGOON_CONTRACT_FIXTURES")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from(DEFAULT_FIXTURES_DIR));
        dir.join("fixtures.json")
    }

    pub fn load() -> Self {
        Self::load_from(&Self::path())
    }

    pub fn load_from(path: &Path) -> Self {
        let text = std::fs::read_to_string(path)
            .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
        let payload: Value = serde_json::from_str(&text)
            .unwrap_or_else(|error| panic!("{} is not JSON: {error}", path.display()));
        // v2 added the optional r2_skip / contract_expected / defect_evidence
        // fields; the reader only has to know how to skip and how to count.
        let version = payload.get("version").and_then(Value::as_u64);
        assert!(
            matches!(version, Some(1) | Some(2)),
            "unsupported fixtures version: {version:?}"
        );
        Self { payload }
    }

    pub fn by_name(&self, name: &str) -> &Value {
        self.payload["fixtures"]
            .as_array()
            .expect("fixtures array")
            .iter()
            .find(|fixture| fixture["name"] == name)
            .unwrap_or_else(|| panic!("fixture {name} is missing"))
    }

    /// Every fixture this build is expected to answer.
    ///
    /// An entry marked r2_skip covers a route R2 does not implement (a write
    /// path); the shell harness skips it too, unless it is asked to include
    /// write routes explicitly.
    pub fn replayable(&self) -> Vec<&Value> {
        self.payload["fixtures"]
            .as_array()
            .expect("fixtures array")
            .iter()
            .filter(|fixture| fixture.get("r2_skip").is_none())
            .collect()
    }

    /// Entries the contract asserts but v3 could not produce (search's 200).
    pub fn contract_expected_count(&self) -> usize {
        self.payload["fixtures"]
            .as_array()
            .expect("fixtures array")
            .iter()
            .filter(|fixture| fixture.get("contract_expected").is_some())
            .count()
    }

    pub fn seed_block(&self) -> &Value {
        &self.payload["seed"]
    }
}

/// One request as the fixture records it.
pub struct RequestSpec {
    pub method: String,
    pub path: String,
    pub query: Vec<(String, String)>,
    pub headers: Vec<(String, String)>,
    pub auth: String,
    /// The body the fixture sends. The shell harness sends `raw_body`
    /// verbatim when present (that is how "empty body" is expressed) and
    /// `json` otherwise; the Rust replay has to do the same, or a fixture
    /// that asserts a 400 on a malformed body is answered with a different
    /// request entirely (observed 2026-10-29: accounts.imap.exists replayed
    /// as an empty POST and got missing-field instead of account-exists).
    pub body: Vec<u8>,
    /// A pre-request hook NAME (harness.py PRE_HOOKS). The fixture needs its
    /// account restored to healthy right before the request, because v3's
    /// startup sync flips it to needsReconnect otherwise.
    pub pre: Option<String>,
}

impl RequestSpec {
    pub fn from_fixture(fixture: &Value) -> Self {
        let request = &fixture["request"];
        let query = request["query"]
            .as_object()
            .map(|object| {
                object
                    .iter()
                    .map(|(name, value)| (name.clone(), value.as_str().unwrap_or("").to_owned()))
                    .collect()
            })
            .unwrap_or_default();
        let headers = request["headers"]
            .as_object()
            .map(|object| {
                object
                    .iter()
                    .map(|(name, value)| (name.clone(), value.as_str().unwrap_or("").to_owned()))
                    .collect()
            })
            .unwrap_or_default();
        let body = if let Some(raw) = request["raw_body"].as_str() {
            raw.as_bytes().to_vec()
        } else if let Some(json) = request.get("json") {
            if json.is_null() {
                Vec::new()
            } else {
                serde_json::to_vec(json).expect("fixture json body")
            }
        } else {
            Vec::new()
        };
        Self {
            method: request["method"].as_str().expect("method").to_owned(),
            path: request["path"].as_str().expect("path").to_owned(),
            query,
            headers,
            auth: request["auth"].as_str().unwrap_or("token").to_owned(),
            body,
            pre: fixture["pre"].as_str().map(str::to_owned),
        }
    }

    pub fn url(&self, base_url: &str) -> String {
        if self.query.is_empty() {
            return format!("{base_url}{}", self.path);
        }
        let query: Vec<String> = self
            .query
            .iter()
            .map(|(name, value)| format!("{}={}", encode(name), encode(value)))
            .collect();
        format!("{base_url}{}?{}", self.path, query.join("&"))
    }

    pub fn headers(&self, token: &str) -> Vec<(String, String)> {
        let mut headers: Vec<(String, String)> = Vec::new();
        match self.auth.as_str() {
            "token" => headers.push(("Authorization".to_owned(), format!("Bearer {token}"))),
            "bad-token" => headers.push((
                "Authorization".to_owned(),
                "Bearer definitely-not-the-token".to_owned(),
            )),
            _ => {}
        }
        headers.extend(self.headers.iter().cloned());
        headers
    }
}

/// Everything except the unreserved characters, like urlencode.
fn encode(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for byte in raw.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

/// Replace wall-clock values with a marker, by key name only.
pub fn normalize(value: &Value) -> Value {
    match value {
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, item)| {
                    let normalized = if TIMESTAMP_KEYS.contains(&key.as_str())
                        && item.as_str().is_some_and(looks_like_a_timestamp)
                    {
                        Value::String(NORMALIZED_VALUE.to_owned())
                    } else {
                        normalize(item)
                    };
                    (key.clone(), normalized)
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(normalize).collect()),
        other => other.clone(),
    }
}

fn looks_like_a_timestamp(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() >= 20
        && bytes.get(4) == Some(&b'-')
        && bytes.get(7) == Some(&b'-')
        && matches!(bytes.get(10), Some(b'T') | Some(b' '))
}

/// Compare one observed response with one fixture; the harness's rules.
pub fn compare(fixture: &Value, observed: &Observed) -> Vec<String> {
    let expected = &fixture["response"];
    let mut problems = Vec::new();

    if expected["status"].as_u64() != Some(observed.status as u64) {
        problems.push(format!(
            "status: expected {}, actual {}",
            expected["status"], observed.status
        ));
    }

    let expected_type = expected["content_type"]
        .as_str()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let actual_type = observed.content_type.trim().to_ascii_lowercase();
    if expected_type != actual_type {
        problems.push(format!(
            "content_type: expected {expected_type:?}, actual {actual_type:?}"
        ));
    }

    if expected["body_kind"].as_str() != Some(observed.body_kind) {
        problems.push(format!(
            "body_kind: expected {:?}, actual {:?}",
            expected["body_kind"], observed.body_kind
        ));
    }

    // Both sides are normalised: the fixture was captured from a live process and
    // the harness normalises what it reads back, so the marker has to be applied
    // to the observed payload too.
    diff(
        &normalize(&expected["body"]),
        &normalize(&observed.body),
        "$.body",
        &mut problems,
    );
    problems
}

fn diff(expected: &Value, actual: &Value, path: &str, out: &mut Vec<String>) {
    if type_name(expected) != type_name(actual) {
        out.push(format!(
            "{path}: expected {}, actual {}",
            type_name(expected),
            type_name(actual)
        ));
        return;
    }
    match expected {
        Value::Object(expected_object) => {
            let actual_object = actual.as_object().expect("type checked");
            for (key, value) in expected_object {
                match actual_object.get(key) {
                    Some(other) => diff(value, other, &format!("{path}.{key}"), out),
                    None => out.push(format!("{path}.{key}: missing in actual (fixture has it)")),
                }
            }
            for key in actual_object.keys() {
                if !expected_object.contains_key(key) {
                    out.push(format!(
                        "{path}.{key}: unexpected in actual (not in fixture)"
                    ));
                }
            }
        }
        Value::Array(expected_items) => {
            let actual_items = actual.as_array().expect("type checked");
            if expected_items.len() != actual_items.len() {
                out.push(format!(
                    "{path}: expected {} items, actual {}",
                    expected_items.len(),
                    actual_items.len()
                ));
            }
            for (index, (left, right)) in expected_items.iter().zip(actual_items.iter()).enumerate()
            {
                diff(left, right, &format!("{path}[{index}]"), out);
            }
        }
        other => {
            if other != actual {
                out.push(format!("{path}: expected {other}, actual {actual}"));
            }
        }
    }
}

fn type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Object(_) => "object",
        Value::Array(_) => "array",
        Value::Number(_) => "number",
        Value::String(_) => "string",
    }
}
