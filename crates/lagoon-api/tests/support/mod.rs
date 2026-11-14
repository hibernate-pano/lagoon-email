#![allow(dead_code)]

//! Shared scaffolding for the integration tests.
//!
//! The contract tests replay the golden HTTP fixtures in
//! tests/contract/fixtures/fixtures.json - the same file
//! scripts/contract-check.sh replays against the Swift sidecar.

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
        // A counter, not just the clock: tests inside one binary run on several
        // threads, and two calls in the same clock tick produced the same path.
        // One test then finished, dropped its guard and removed the directory
        // the other was still using — which surfaces as "disk I/O error" in
        // whichever test lost the race, not as a temp-dir bug.
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = format!(
            "lagoon-api-{label}-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos(),
            COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
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
