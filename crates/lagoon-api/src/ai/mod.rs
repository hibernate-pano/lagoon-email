//! The AI plane: a read-only advisor (constitution §2).
//!
//! The rules this module lives by, from
//! `docs/superpowers/specs/2026-10-02-advisory-only-ai-constitution-design.md`:
//!
//! * The AI plane is **read-only**. It reads mail the user already has and
//!   produces text: a summary, a triage suggestion, a draft. It never writes
//!   to the mailbox, and it never sends.
//! * Advice and execution are recorded apart. A suggestion is not an action;
//!   the only thing that changes a mail is a click by the user.
//!
//! The pieces:
//!
//! * [`config`] - `config/providers.json`: which model serves which job.
//! * [`gateway`] - the seam the routes talk to: capability in, text out,
//!   with a circuit breaker and a cost figure.
//! * [`transport`] - how the request leaves the machine. The production one
//!   speaks HTTP/1.1 over the mail crate's TLS transport; the tests use a
//!   scripted one and never touch a socket.
//! * [`http`] - the small HTTP/1.1 client the production transport uses.

pub mod classify;
pub mod config;
/// A scripted transport for tests: no socket, no DNS, no TLS.
pub mod fake;
pub mod gateway;
pub mod http;
pub mod transport;
