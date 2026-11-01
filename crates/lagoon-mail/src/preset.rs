//! Fixed provider endpoints.
//!
//! v3 `ProviderPresets.swift`: hosts come from this table, never from user
//! input, which keeps "connect to an arbitrary host" out of the attack surface.
//! The struct's fields are public but the only constructors are the presets, so
//! a caller cannot invent an endpoint by accident.
//!
//! The ports are the implicit-TLS pair (993 / 465) and nothing else.

/// The supported mail providers. QQ is the only one v3 shipped (spec §5.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderKind {
    Qq,
}

impl ProviderKind {
    pub const fn id(self) -> &'static str {
        match self {
            Self::Qq => "qq",
        }
    }
}

/// One provider's IMAP and SMTP endpoints.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderPreset {
    pub kind: ProviderKind,
    pub imap_host: &'static str,
    pub imap_port: u16,
    pub smtp_host: &'static str,
    pub smtp_port: u16,
}

impl ProviderPreset {
    /// The IMAP/SMTP endpoints for the one supported provider.
    pub const fn qq() -> Self {
        Self {
            kind: ProviderKind::Qq,
            imap_host: "imap.qq.com",
            imap_port: 993,
            smtp_host: "smtp.qq.com",
            smtp_port: 465,
        }
    }

    pub const fn for_kind(kind: ProviderKind) -> Self {
        match kind {
            ProviderKind::Qq => Self::qq(),
        }
    }

    pub const fn imap_endpoint(&self) -> (&'static str, u16) {
        (self.imap_host, self.imap_port)
    }

    pub const fn smtp_endpoint(&self) -> (&'static str, u16) {
        (self.smtp_host, self.smtp_port)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qq_uses_implicit_tls_ports_only() {
        let preset = ProviderPreset::qq();
        assert_eq!(preset.imap_endpoint(), ("imap.qq.com", 993));
        assert_eq!(preset.smtp_endpoint(), ("smtp.qq.com", 465));
        assert_eq!(ProviderPreset::for_kind(ProviderKind::Qq), preset);
        assert_eq!(ProviderKind::Qq.id(), "qq");
    }
}
