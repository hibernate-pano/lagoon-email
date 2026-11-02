//! Which business backend this run talks to (contract v0.2 §4.1).
//!
//! * rust  - v4/crates lagoon-api, the product backend since R3.4: reads,
//!   accounts, sync. Endpoints it has not implemented answer 404
//!   with an empty body, which the shell must pass through as
//!   ok:true (not as a transport failure).
//! * swift - the v3 LagoonServerCLI sidecar, kept as a development-time
//!   reference implementation; a packaged app never needs it.
//!
//! Selection: --backend swift|rust, else LAGOON_V4_BACKEND, else rust.
//! The front end never chooses; it only reads boot_status.backend.

use std::path::{Path, PathBuf};

use crate::state::BootError;

pub const DEFAULT_BACKEND: Backend = Backend::Rust;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Swift,
    Rust,
}

impl Backend {
    pub fn as_str(self) -> &'static str {
        match self {
            Backend::Swift => "swift",
            Backend::Rust => "rust",
        }
    }

    pub fn parse(raw: &str) -> Result<Self, String> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "swift" => Ok(Backend::Swift),
            "rust" => Ok(Backend::Rust),
            other => Err(format!(
                "unknown backend {other:?}: use --backend swift or --backend rust"
            )),
        }
    }

    /// Command line wins over the environment; both are optional.
    /// Only --backend is looked at, so unrelated flags stay ignored.
    pub fn from_args_and_env(args: &[String]) -> Result<Self, String> {
        let mut from_args: Option<&str> = None;
        let mut index = 0;
        while index < args.len() {
            let argument = args[index].as_str();
            if let Some(value) = argument.strip_prefix("--backend=") {
                from_args = Some(value);
            } else if argument == "--backend" {
                let Some(value) = args.get(index + 1) else {
                    return Err("--backend needs a value: swift or rust".to_string());
                };
                from_args = Some(value.as_str());
                index += 1;
            }
            index += 1;
        }
        if let Some(raw) = from_args {
            return Self::parse(raw);
        }
        match std::env::var("LAGOON_V4_BACKEND") {
            Ok(raw) if !raw.trim().is_empty() => Self::parse(&raw),
            _ => Ok(DEFAULT_BACKEND),
        }
    }

    /// Path to the backend binary. Each backend has its own override variable
    /// so both can coexist during the R3 transition.
    pub fn binary(self, root: &Path) -> Result<PathBuf, BootError> {
        match self {
            Backend::Swift => {
                if let Some(path) = override_path("LAGOON_V4_SIDECAR") {
                    return path;
                }
                for candidate in [
                    root.join(".build/release/LagoonServerCLI"),
                    root.join(".build/debug/LagoonServerCLI"),
                ] {
                    if candidate.is_file() {
                        return Ok(candidate);
                    }
                }
                Err(BootError {
                    code: "spawn",
                    message: format!(
                        "LagoonServerCLI not found under {}; build it with: swift build --product LagoonServerCLI",
                        root.join(".build").display()
                    ),
                })
            }
            Backend::Rust => {
                if let Some(path) = override_path("LAGOON_V4_RUST_API") {
                    return path;
                }
                // Packaged app: the backend sits next to the shell under
                // Contents/Resources (assembled by v4/scripts/build-product.sh).
                if let Ok(exe) = std::env::current_exe() {
                    let resources = exe
                        .parent()
                        .and_then(|macos| macos.parent())
                        .map(|contents| contents.join("Resources"));
                    if let Some(bundled) = resources.map(|dir| dir.join("lagoon-api")) {
                        if bundled.is_file() {
                            return Ok(bundled);
                        }
                    }
                }
                for candidate in [
                    root.join("crates/target/release/lagoon-api"),
                    root.join("crates/target/debug/lagoon-api"),
                ] {
                    if candidate.is_file() {
                        return Ok(candidate);
                    }
                }
                Err(BootError {
                    code: "spawn",
                    message: format!(
                        "lagoon-api not found (dev: {}, packaged: Contents/Resources/lagoon-api); build it with: bash v4/scripts/build-product.sh",
                        root.join("crates/target/release/lagoon-api").display()
                    ),
                })
            }
        }
    }
}

fn override_path(variable: &str) -> Option<Result<PathBuf, BootError>> {
    let raw = std::env::var(variable).ok()?;
    if raw.trim().is_empty() {
        return None;
    }
    let path = PathBuf::from(raw);
    Some(if path.is_file() {
        Ok(path)
    } else {
        Err(BootError {
            code: "spawn",
            message: format!("{variable}={} is not a file", path.display()),
        })
    })
}
