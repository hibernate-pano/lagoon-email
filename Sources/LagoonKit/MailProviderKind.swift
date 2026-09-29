import Foundation

/// Mail provider identity. QQ Mail uses IMAP+SMTP with a 授权码.
///
/// Single provider on purpose: a QQ-only MVP carries no provider abstraction
/// cost. Adding one back means a case here, a `ProviderPresets` entry, a
/// `MailProvider` implementation and — for any provider whose credential
/// payload differs — a case in `AccountCredentials`.
public enum MailProviderKind: String, Codable, Sendable, CaseIterable {
    case qq
}
