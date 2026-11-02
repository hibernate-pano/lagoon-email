//! Lagoon v4 Rust backend - the read-only slice (R1) and the local-only read
//! endpoints (R2).
//!
//! This crate is the first block of the v4 backend (Rust shell + Rust backend +
//! web frontend, no Swift in the shipped product). R1 deliberately implements
//! **only reads**: it opens the store the v3 sidecar created, serves five
//! endpoints with v3's exact wire shapes, and never writes, migrates, connects
//! to IMAP or calls a model.
//!
//! Layout mirrors the concern split, not the route list:
//!
//! * [`briefing`] - the feed's grouping/reason rules (v3's heuristic classifier)
//! * [`config`]   - env/flag parsing, bind safety and the Host allow-list
//! * [`db`]       - read-only SQLite pool + schema probe (fail-closed)
//! * [`store`]    - the SQL v3's `MessageStore`/`AccountStore` run, ported
//! * [`wire`]     - the shared `LagoonKit` wire types, field for field
//! * [`crypto`]   - the `lgb1:` AES-256-GCM envelope (`BodyCipher`)
//! * [`timefmt`]  - v3's stored date format and its ISO-8601 wire form
//! * [`uuid`]     - Swift-compatible UUID parsing (strict canonical form)
//! * [`http`]     - axum router, Host guard, bearer auth, error envelope
//! * [`telemetry`]- trace events on stderr (no `tracing-subscriber` needed)

/// The read-only AI plane: routing, the gateway, and the HTTP seam.
pub mod ai;
pub mod briefing;
pub mod config;
pub mod crypto;
pub mod db;
pub mod http;
/// The v3 DDL, generated from Sources/LagoonKit/LagoonDatabase.swift.
pub mod migrations;
pub mod provider;
pub mod store;
pub mod sync;
pub mod telemetry;
pub mod timefmt;
pub mod token;
pub mod uuid;
pub mod wire;
pub mod wire_r2;
