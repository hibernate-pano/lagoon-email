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
    /// The IMAP/SMTP endpoints for the one supported provider. Ports are the
    /// implicit-TLS pair the spec restricts us to (993 / 465).
    ///
    /// Non-optional: every caller already holds an `IMAPProvider`, so there is
    /// no state in which this could fail to resolve.
    public static func imap() -> IMAPPreset {
        IMAPPreset(
            imapHost: "imap.qq.com",
            imapPort: 993,
            smtpHost: "smtp.qq.com",
            smtpPort: 465
        )
    }
}
