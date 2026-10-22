import Foundation

/// The strings the compose flow says.
///
/// They live here rather than in `L10n.swift` so that the file that
/// *defines* the compose sheets and the file that *says* what they do are
/// separate — the same reason `L10n+Drafts.swift` exists. A feature that
/// needs a string of its own gets a file of its own, and two features can
/// then add copy at the same time without both editing the same
/// 2000-line file.
extension L10n {

    // MARK: - Picking an AI draft

    /// The button that takes the chosen AI variant into the composer.
    ///
    /// It used to read 「选这个 → 发送」/「Use this → send」, and the arrow
    /// promised a send that never happened: choosing a variant opens the
    /// reply composer with that text in it. A button that says "send" and
    /// does not send teaches the user that buttons here are unreliable.
    public var useDraftVariant: String {
        pick("用这个版本", "Use this version")
    }

    /// Says what choosing a variant actually does.
    ///
    /// The button used to promise a send and opened a composer instead,
    /// so the sheet says plainly that the text lands in the composer and
    /// the user sends it from there.
    public var useDraftVariantHelp: String {
        pick(
            "选中的版本会放进写信框，你看过之后再发送。",
            "The chosen version goes into the composer — you read it there and send it yourself."
        )
    }

    // MARK: - The draft

    /// The live "the draft is on disk" state.
    ///
    /// Shown for a moment after a write actually lands, so the promise
    /// the sheet makes has a proof next to it.
    public var draftSavedNow: String {
        pick("已保存", "Saved")
    }

    /// Says that the composer brought back a draft from an earlier
    /// session, so the user knows the text they are looking at is theirs
    /// and not a quotation.
    public var draftRestored: String {
        pick("已恢复上次写的草稿", "Your last draft was restored")
    }

    // MARK: - Why a send failed

    /// The sending server rejected the authorization code.
    public var sendFailedAuth: String {
        pick(
            "发信服务器拒绝了授权码，请到设置里重新填写 SMTP 授权码。",
            "The sending server rejected the authorization code. Re-enter the SMTP authorization code in Settings."
        )
    }

    /// The account has no sending server configured.
    public var sendFailedNotConfigured: String {
        pick(
            "这个账号还没有配好发信服务器。",
            "This account has no sending server configured yet."
        )
    }

    /// The message is no longer on the server.
    public var sendFailedMessageGone: String {
        pick(
            "这封邮件已经不在服务器上了。",
            "This message is no longer on the server."
        )
    }

    /// The account is no longer in Lagoon.
    public var sendFailedAccountMissing: String {
        pick(
            "这个账号已经不在 Lagoon 里了。",
            "This account is no longer in Lagoon."
        )
    }

    /// The recipient list did not parse on the server.
    public var sendFailedMalformedRecipient: String {
        pick(
            "服务器无法解析这串收件人地址。",
            "The server could not parse the recipient list."
        )
    }

    /// An attachment did not survive the trip to the server.
    public var sendFailedMalformedAttachment: String {
        pick(
            "有附件没能送到服务器。",
            "An attachment did not reach the server."
        )
    }

    /// The original message is too large to forward.
    public var sendFailedForwardTooLarge: String {
        pick(
            "原邮件太大，转不出去。",
            "The original message is too large to forward."
        )
    }

    /// The same request is already on the wire.
    public var sendFailedInFlight: String {
        pick(
            "这封邮件还在发送中。稍等片刻再试一次，或者到「已发送」里确认。",
            "This mail is still being sent. Try again in a moment, or check Sent."
        )
    }

    /// The server could not reach the mail server.
    public var sendFailedTransport: String {
        pick(
            "服务器暂时发不出去，稍后可以重试。",
            "The server could not reach the mail server just now. You can try again."
        )
    }

    /// The server answered 200 but says it did not send.
    public var sendRejected: String {
        pick(
            "服务器没有接受这封邮件，没有发出去。",
            "The server did not accept this mail, so it was not sent."
        )
    }

    // MARK: - Leaving a mail that is not finished

    /// The prompt's title.
    public var unsavedMailTitle: String {
        pick("这封邮件还没写完", "This mail is not finished")
    }

    /// The prompt's body: what happens to the work, and what the choices
    /// are.
    public var unsavedMailMessage: String {
        pick(
            "草稿会自动保存，关掉之后从这封邮件再打开写信框就能接着写。",
            "The draft saves automatically. Reopen the composer on this message later to pick it up."
        )
    }

    /// Stays in the composer.
    public var keepWriting: String {
        pick("继续写", "Keep writing")
    }

    /// Throws the draft away.
    public var discardDraft: String {
        pick("丢弃草稿", "Discard draft")
    }

    /// Closes the composer and keeps the draft.
    public var closeAndKeepDraft: String {
        pick("保存并关闭", "Save and close")
    }

    // MARK: - Recipients

    /// How many people the whole envelope reaches.
    public func newMessageTotalRecipients(count: Int) -> String {
        pick("共 \(count) 位收件人", "\(count) recipients in total")
    }

    /// Says that the recipients of a reply are not editable here.
    ///
    /// The server derives the envelope from its own row, so the field is
    /// a read-only echo. A field that cannot be edited and does not say
    /// so reads as a broken form.
    public var replyRecipientsFixed: String {
        pick(
            "收件人由原邮件决定，不能在这里修改。",
            "The recipients come from the original message and cannot be changed here."
        )
    }

    /// Why the send button is disabled.
    public var sendNeedsRecipient: String {
        pick(
            "先填收件人才能发送。",
            "Add a recipient before sending."
        )
    }

    // MARK: - Forwarding

    /// The subject field's placeholder when the client does not know the
    /// original's subject and lets the server derive it.
    public var forwardSubjectDefault: String {
        pick(
            "默认：Fwd: 原邮件主题",
            "Default: Fwd: the original's subject"
        )
    }

    // MARK: - Attachments

    /// Says that adding this file would break the total size limit.
    public func newMessageAttachmentTotalTooLarge(name: String) -> String {
        pick(
            "加上「\(name)」一共会超过 100 MB 的总上限，发送不了。",
            "With \"\(name)\" the attachments would exceed the 100 MB total limit."
        )
    }

    /// The size of all the attachments together.
    public func newMessageAttachmentTotalSize(size: String) -> String {
        pick("共 \(size)", "\(size) in total")
    }

    // MARK: - The cheatsheet

    /// The ⌘↩ row: it says where the key works, because a key without a
    /// place is a gesture that silently does nothing.
    public var shortcutSendScope: String {
        pick(
            "在写信框里发送这封邮件",
            "Send this mail from the composer"
        )
    }
}
