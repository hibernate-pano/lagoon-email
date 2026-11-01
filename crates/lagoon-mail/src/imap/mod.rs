//! IMAP: framing, commands, capability negotiation and folder roles.
//!
//! The layer split mirrors v3 (`IMAPConnection` / `IMAPClient` /
//! `IMAPProvider`) because that split earned itself in production:
//!
//! * [`parser`] is pure text → structure, and every byte it sees is
//!   server-controlled. It must never panic.
//! * [`connection`] owns tags, literal framing, timeouts and IDLE.
//! * [`client`] names the commands and turns responses into typed rows.
//! * [`capabilities`] is the tri-state capability model and role discovery.
//! * [`membership`] is the one-session inbox/archive/trash membership walk.
//! * [`provider`] is account-level: connection reuse, roles, the UIDPLUS gate.

pub mod capabilities;
pub mod client;
pub mod connection;
pub mod membership;
pub mod parser;
pub mod provider;
