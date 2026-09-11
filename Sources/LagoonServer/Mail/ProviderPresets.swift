import Foundation
import LagoonKit

/// Fixed IMAP/SMTP endpoints for one provider. Hosts come from this table,
/// never from user input — that keeps "connect to an arbitrary host" out of the
/// attack surface (spec §5.2).
public struct IMAPPreset: Sendable, Equatable {
    public let imapHost: String
    public let imapPort: Int
    public let smtpHost: String
    public let smtpPort: Int

    public init(imapHost: String, imapPort: Int, smtpHost: String, smtpPort: Int) {
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
    }
}

public enum ProviderPresets {
    /// Constants are provider contracts, not configuration: both ports are the
    /// implicit-TLS ones the spec restricts us to (993 / 465).
    public static func imap(for kind: MailProviderKind) -> IMAPPreset? {
        switch kind {
        case .qq:
            return IMAPPreset(
                imapHost: "imap.qq.com",
                imapPort: 993,
                smtpHost: "smtp.qq.com",
                smtpPort: 465
            )
        case .gmail:
            return nil  // Gmail goes through the REST API, not IMAP.
        }
    }
}
