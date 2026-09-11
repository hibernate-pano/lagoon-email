import Foundation

/// Mail provider identity. `gmail` uses the Gmail REST API; `qq` uses IMAP+SMTP
/// with a QQ 授权码. Adding a provider = new case here + a CHECK migration +
/// a `ProviderPresets` entry + a `MailProvider` implementation.
public enum MailProviderKind: String, Codable, Sendable, CaseIterable {
    case gmail
    case qq
}
