//! SMTP: implicit TLS (465), `AUTH PLAIN`, one `RCPT TO` per envelope
//! recipient, RFC 5321 dot-stuffing, and the v3 status-code mapping.

pub mod client;

pub use client::SmtpClient;
