import Foundation

/// The strings for the inline (`cid:`) image path.
///
/// They live in their own file so that the feature that needs them does not
/// have to edit the 2000-line `L10n.swift` while another agent is working
/// in it — the same split `L10n+AI.swift` already uses.
extension L10n {
    /// Shown when an inline image could not be fetched.
    ///
    /// The user needs to know two things: the message itself is fine, and
    /// the picture is missing. Without that, a broken image reads as "the
    /// sender sent a broken mail", which is the wrong conclusion and sends
    /// the user looking for a problem that is not there.
    public var inlineImageFailedTitle: String {
        pick("部分内嵌图片加载失败", "Some inline images could not be loaded")
    }

    /// The detail line under the title: what failed, and that the rest of
    /// the message is unaffected.
    public var inlineImageFailedDetail: String {
        pick(
            "邮件正文不受影响；可以重新打开这封邮件再试一次。",
            "The message itself is unaffected. Reopen it to try again."
        )
    }

    /// The retry button on that banner.
    public var inlineImageRetry: String {
        pick("重新加载图片", "Reload images")
    }
}
