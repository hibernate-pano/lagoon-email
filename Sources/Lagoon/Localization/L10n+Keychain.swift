import Foundation

/// The strings for the Keychain-authorization path.
///
/// They live in their own file so that the feature that needs them does
/// not have to edit the 2000-line `L10n.swift` while another agent is
/// working in it — the same split `L10n+Backup.swift` already uses.
extension L10n {
    /// The title of the "the Keychain needs your attention" screen.
    ///
    /// It says **钥匙串** rather than "Keychain" on purpose: the user's
    /// next action is to open a *pane* called 钥匙串访问, and naming the
    /// thing they are looking for is the difference between an
    /// instruction and a hint.
    public var keychainAuthorizationTitle: String {
        pick("钥匙串需要你的授权", "The Keychain needs your authorization")
    }

    /// What is happening, in one sentence.
    ///
    /// The old behaviour was a spinner that never stopped. This says
    /// three things the spinner could not: the Keychain is waiting, the
    /// reason is a rebuild's new signature, and the data is safe.
    public var keychainAuthorizationDetail: String {
        pick(
            "Lagoon 需要读取你的钥匙串里的账号与加密密钥。系统弹出的授权窗口可能没有显示——请在「钥匙串访问」中允许 Lagoon 访问。你的账号和邮件都还在，钥匙串里的内容也没有被改动。",
            "Lagoon needs to read the account and encryption keys in your Keychain. The system authorization window may not have appeared — allow Lagoon in Keychain Access. Your account and mail are still there, and nothing in the Keychain was changed."
        )
    }

    /// The button that opens Keychain Access.
    ///
    /// "打开钥匙串访问" is the real name of the app, so the button and
    /// the app it opens read as one thing.
    public var keychainOpenAccess: String {
        pick("打开钥匙串访问", "Open Keychain Access")
    }




    /// The "the Keychain is waiting for your authorization" explanation,
    /// appended to the account-read error.
    public var keychainAuthorizationRequired: String {
        pick(
            "钥匙串在等待授权。数据没有丢失，但这个版本暂时读不到它。",
            "The Keychain is waiting for authorization. Nothing was lost, but this build cannot read it yet."
        )
    }

    /// The failure text when a secret could not be resolved in time.
    ///
    /// Used by `DeferredSecretError` — the error the runtime raises when a
    /// key is still a placeholder, so a route can answer "not ready yet"
    /// instead of a decryption error that reads as data corruption.
    public var secretResolutionTimedOut: String {
        pick("钥匙串读取超时", "The Keychain read timed out")
    }
}
