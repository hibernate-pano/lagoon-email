#![allow(dead_code)]

//! Shared scaffolding for the integration tests.
//!
//! The contract tests replay the golden HTTP fixtures in
//! v4/tests/contract/fixtures/fixtures.json - the same file
//! v4/scripts/contract-check.sh replays against the Swift sidecar.

pub mod fixtures;
pub mod http;
pub mod schema;
pub mod seed;
pub mod server;

use std::path::{Path, PathBuf};

/// A directory under the system temp dir, removed on drop.
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(label: &str) -> Self {
        let unique = format!(
            "lagoon-api-{label}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        );
        let path = std::env::temp_dir().join(unique);
        std::fs::create_dir_all(&path).expect("create temp dir");
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn join(&self, name: &str) -> PathBuf {
        self.path.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
pub mod scripted_transport;
