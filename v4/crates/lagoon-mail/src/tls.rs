//! Implicit-TLS client configuration.
//!
//! v3's transport was NIO SSL with the system trust roots; the rule that
//! matters is unchanged and is the one thing this module exists to guarantee:
//! **the certificate chain is fully verified against the operating system's
//! trust store, and the server name is checked.** There is no "accept
//! self-signed" switch, no custom verifier, no way to disable it.
//!
//! The reference crate named in the R3 plan is `rustls-native-certs`. That
//! crate is not available in this environment's offline registry, so the port
//! uses `rustls-platform-verifier` instead: on macOS it evaluates the chain
//! with Security.framework, on Windows with the platform verifier, and on
//! Linux with the distro trust store — the same authority `rustls-native-certs`
//! would supply, without shipping a frozen copy of the Mozilla root set. The
//! rest of the stack (rustls itself, TLS 1.2 + 1.3) matches the plan.

use std::sync::{Arc, OnceLock};

use rustls::{CertificateError, ClientConfig, Error as RustlsError};
use rustls_platform_verifier::ConfigVerifierExt;

/// Process-wide client configuration: one root store, one crypto provider.
///
/// Building it can fail (the platform verifier is unavailable on some
/// sandboxed targets); that is surfaced rather than silently replaced with
/// "no verify". The configuration installs the platform verifier, so a
/// self-signed or incomplete chain fails the handshake — the test suite proves
/// this with an in-memory rustls handshake (no socket).
pub fn client_config() -> Result<Arc<ClientConfig>, &'static str> {
    static CONFIG: OnceLock<Result<Arc<ClientConfig>, &'static str>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            ClientConfig::with_platform_verifier()
                .map(Arc::new)
                .map_err(|error| static_label(&error))
        })
        .clone()
}

/// Static label for a TLS failure. No certificate subject, host name or remote
/// text is carried.
pub fn static_label(error: &RustlsError) -> &'static str {
    match error {
        RustlsError::InvalidCertificate(certificate) => match certificate {
            CertificateError::UnknownIssuer => "tls-unknown-issuer",
            CertificateError::Expired => "tls-certificate-expired",
            CertificateError::NotValidYet => "tls-certificate-not-yet-valid",
            CertificateError::Revoked => "tls-certificate-revoked",
            CertificateError::NotValidForName => "tls-wrong-host",
            CertificateError::BadSignature => "tls-bad-signature",
            CertificateError::BadEncoding => "tls-bad-encoding",
            _ => "tls-certificate-rejected",
        },
        RustlsError::NoCertificatesPresented => "tls-no-certificate",
        RustlsError::PeerIncompatible(_) => "tls-incompatible",
        RustlsError::PeerMisbehaved(_) => "tls-peer-misbehaved",
        _ => "tls-handshake-failed",
    }
}
