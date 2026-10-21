import XCTest
import Foundation
@testable import Lagoon
@testable import LagoonKit

/// Covers the runtime language switch: every localized string must exist in
/// both languages, and non-View code must follow the stored preference.
final class LocalizationTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LanguagePreference.defaultsKey)
        super.tearDown()
    }

    func test_groupTitles_existInBothLanguagesAndDiffer() {
        for group in BriefingGroup.allCases {
            let chinese = zh.groupTitle(group)
            let english = en.groupTitle(group)
            XCTAssertFalse(chinese.isEmpty, "missing zh title for \(group.rawValue)")
            XCTAssertFalse(english.isEmpty, "missing en title for \(group.rawValue)")
            XCTAssertNotEqual(chinese, english, "untranslated title for \(group.rawValue)")
        }
    }

    func test_reasonText_coversEveryCodeInBothLanguages() {
        for reason in BriefingReason.allCases {
            let chinese = zh.reasonText(reason.rawValue)
            let english = en.reasonText(reason.rawValue)
            XCTAssertNotNil(chinese, "missing zh text for \(reason.rawValue)")
            XCTAssertNotNil(english, "missing en text for \(reason.rawValue)")
            XCTAssertNotEqual(chinese, english, "untranslated reason \(reason.rawValue)")
        }
    }

    /// A code from a newer server must not crash or leak into the UI.
    func test_reasonText_unknownCode_returnsNil() {
        XCTAssertNil(zh.reasonText("something-new"))
        XCTAssertNil(zh.reasonText(nil))
        XCTAssertNil(zh.reasonText(""))
    }

    /// Structured strings that carry arguments must interpolate in both.
    func test_interpolatedStrings_useTheArgument() {
        XCTAssertEqual(zh.expandGroup("需要回复"), "展开 需要回复")
        XCTAssertEqual(en.expandGroup("Needs reply"), "Expand Needs reply")
        XCTAssertEqual(zh.viaProvider("MiniMax-M3"), "由 MiniMax-M3 生成")
        XCTAssertEqual(en.viaProvider("MiniMax-M3"), "via MiniMax-M3")
        XCTAssertEqual(zh.recipient("a@b.com"), "收件人 a@b.com")
        XCTAssertEqual(en.httpStatus(502), "Server returned HTTP 502: ")
        XCTAssertEqual(zh.httpStatus(502), "服务器返回 HTTP 502：")
    }

    func test_languagePreference_roundTripsThroughUserDefaults() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(LanguagePreference.stored, .english)
        XCTAssertEqual(L10n.current.retry, "Retry")

        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(LanguagePreference.stored, .zhHans)
        XCTAssertEqual(L10n.current.retry, "重试")
    }

    func test_languagePreference_defaultsToChineseWhenUnset() {
        UserDefaults.standard.removeObject(forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(LanguagePreference.stored, .zhHans)
    }

    /// Errors thrown by non-View code follow the stored preference.
    func test_apiErrorMessages_followStoredLanguage() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(
            APIError.invalidResponse.localizedDescription,
            "The server returned a non-HTTP response."
        )
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(APIError.invalidResponse.localizedDescription, "服务器返回了非 HTTP 响应。")
    }

    // MARK: - T9: connect (QQ / IMAP), account directory, sync health

    func test_qqConnectStrings_existInBothLanguages() {
        let zhStrings = [
            zh.connectQQTab, zh.connectQQTitle, zh.qqEmailPlaceholder, zh.qqAuthCodePlaceholder,
            zh.qqHelp, zh.qqConnectButton, zh.qqMissingFields, zh.qqAuthFailed,
            zh.qqUnreachable, zh.qqAccountExists, zh.connectFailed,
            zh.useThisAccount, zh.qqProviderNotConfigured, zh.qqInternalError,
            zh.serverTimedOut, zh.serverUnreachable,
        ]
        let enStrings = [
            en.connectQQTab, en.connectQQTitle, en.qqEmailPlaceholder, en.qqAuthCodePlaceholder,
            en.qqHelp, en.qqConnectButton, en.qqMissingFields, en.qqAuthFailed,
            en.qqUnreachable, en.qqAccountExists, en.connectFailed,
            en.useThisAccount, en.qqProviderNotConfigured, en.qqInternalError,
            en.serverTimedOut, en.serverUnreachable,
        ]
        for value in zhStrings + enStrings {
            XCTAssertFalse(value.isEmpty)
        }
        for (chinese, english) in zip(zhStrings, enStrings) {
            XCTAssertNotEqual(chinese, english, "untranslated string pair: \(chinese)")
        }
    }

    func test_accountDirectoryStrings_existInBothLanguages() {
        XCTAssertEqual(zh.addAccount, "添加账号")
        XCTAssertEqual(en.addAccount, "Add account")
        XCTAssertEqual(zh.activateAccount, "切换到这个账号")
        XCTAssertEqual(en.activateAccount, "Switch to this account")
        XCTAssertEqual(zh.activateAccountFailed, "切换账号失败：")
        XCTAssertEqual(en.activateAccountFailed, "Could not switch account: ")
        XCTAssertEqual(zh.sleepingAccount, "休眠")
        XCTAssertEqual(en.sleepingAccount, "Sleeping")
        XCTAssertEqual(zh.deleteAccountFailed, "删除这个账号失败：")
        XCTAssertEqual(en.deleteAccountFailed, "Could not remove this account: ")
        XCTAssertFalse(zh.accountsMenuHelp.isEmpty)
        XCTAssertFalse(en.accountsMenuHelp.isEmpty)
    }

    func test_providerNames_existInBothLanguages() {
        for kind in MailProviderKind.allCases {
            let chinese = zh.providerName(kind)
            let english = en.providerName(kind)
            XCTAssertFalse(chinese.isEmpty, "missing zh name for \(kind.rawValue)")
            XCTAssertFalse(english.isEmpty, "missing en name for \(kind.rawValue)")
        }
        XCTAssertEqual(zh.providerName(.qq), "QQ 邮箱")
        XCTAssertEqual(en.providerName(.qq), "QQ Mail")
    }

    func test_syncHealthStrings_coverEveryStatusInBothLanguages() {
        let statuses: [SyncHealth.Status] = [.ok, .degraded, .needsReconnect, .error]
        for status in statuses {
            let chinese = zh.healthStatusText(status)
            let english = en.healthStatusText(status)
            XCTAssertFalse(chinese.isEmpty, "missing zh text for \(status.rawValue)")
            XCTAssertFalse(english.isEmpty, "missing en text for \(status.rawValue)")
        }
        XCTAssertEqual(zh.reconnect, "重新连接")
        XCTAssertEqual(en.reconnect, "Reconnect")
        XCTAssertEqual(zh.healthDegradedTitle, "同步不稳定")
        XCTAssertEqual(en.healthDegradedTitle, "Sync is unstable")
        XCTAssertEqual(zh.healthErrorTitle, "同步失败")
        XCTAssertEqual(en.healthErrorTitle, "Sync failed")
        XCTAssertFalse(zh.healthNeedsReconnect.isEmpty)
        XCTAssertFalse(en.healthNeedsReconnect.isEmpty)
        XCTAssertFalse(zh.archiveUnavailable.isEmpty)
        XCTAssertFalse(en.archiveUnavailable.isEmpty)
        XCTAssertFalse(zh.archiveFailed.isEmpty)
        XCTAssertFalse(en.archiveFailed.isEmpty)
    }

    /// Every label the server can record must have a human sentence in both
    /// languages. A missing translation would silently degrade to the generic
    /// fallback, hiding the specific cause from the user.
    func test_everySyncFailureLabel_hasAHumanSentence() {
        let labels = [
            "auth-failed", "unreachable", "protocol-error", "message-gone",
            "archive-unavailable", "trash-unavailable", "sent-unavailable",
            "not-configured", "no-provider",
        ]
        for label in labels {
            XCTAssertNotNil(
                SyncErrorReason.humanReadable(label, l10n: zh),
                "missing zh sentence for \(label)"
            )
            XCTAssertNotNil(
                SyncErrorReason.humanReadable(label, l10n: en),
                "missing en sentence for \(label)"
            )
        }
    }

    /// The whole point of the translation layer: a label must never reach the
    /// user, and an unknown label must not leak either.
    func test_unknownLabels_neverReachTheUser() {
        let raw = "some-internal-code"
        let zhSentence = SyncErrorReason.sentence(for: raw, l10n: zh)
        XCTAssertFalse(zhSentence.contains(raw), "the raw label leaked into the sentence")
        XCTAssertEqual(zhSentence, zh.reasonUnknown)
        XCTAssertEqual(SyncErrorReason.sentence(for: nil, l10n: zh), zh.reasonUnknown)
        XCTAssertEqual(SyncErrorReason.sentence(for: "", l10n: zh), zh.reasonUnknown)
    }

    /// A known label becomes its own sentence, not the generic fallback.
    func test_knownLabel_becomesItsOwnSentence() {
        let sentence = SyncErrorReason.sentence(for: "auth-failed", l10n: zh)
        XCTAssertEqual(sentence, zh.reasonAuthFailed)
        XCTAssertFalse(sentence.contains("auth-failed"))
    }

    // MARK: - T11: reply composer

    func test_composerStrings_existInBothLanguages() {
        let zhStrings = [
            zh.reply, zh.replyHelp, zh.replyTitle, zh.replyTo, zh.replyBodyPlaceholder,
            zh.send, zh.sending, zh.sendFailed, zh.sent, zh.emptyReply, zh.cancel,
            zh.shortcutSend, zh.sentTo("a@b.com"),
        ]
        let enStrings = [
            en.reply, en.replyHelp, en.replyTitle, en.replyTo, en.replyBodyPlaceholder,
            en.send, en.sending, en.sendFailed, en.sent, en.emptyReply, en.cancel,
            en.shortcutSend, en.sentTo("a@b.com"),
        ]
        for value in zhStrings + enStrings {
            XCTAssertFalse(value.isEmpty)
        }
        for (chinese, english) in zip(zhStrings, enStrings) {
            XCTAssertNotEqual(chinese, english, "untranslated string pair: \(chinese)")
        }
        XCTAssertEqual(zh.send, "发送")
        XCTAssertEqual(en.send, "Send")
        XCTAssertEqual(zh.sentTo("a@b.com"), "已发送给 a@b.com")
        XCTAssertEqual(en.sentTo("a@b.com"), "Sent to a@b.com")
    }

    func test_newMessageStrings_existInBothLanguages() {
        let zhStrings = [
            zh.newMessage, zh.newMessageHelp, zh.newMessageTitle,
            zh.newMessageToPlaceholder,
            zh.newMessageBodyPlaceholder, zh.emptyRecipient, zh.emptyMessage,
        ]
        let enStrings = [
            en.newMessage, en.newMessageHelp, en.newMessageTitle,
            en.newMessageToPlaceholder,
            en.newMessageBodyPlaceholder, en.emptyRecipient, en.emptyMessage,
        ]
        for value in zhStrings + enStrings {
            XCTAssertFalse(value.isEmpty)
        }
        for (chinese, english) in zip(zhStrings, enStrings) {
            XCTAssertNotEqual(chinese, english, "untranslated string pair: \(chinese)")
        }
    }

    // MARK: - Audit batch: startup / body / bulk-delete copy

    /// The boot screen, the embedded server's two errors, the body container's
    /// VoiceOver label and the bulk-delete failure title — every string the
    /// UX-06/07/08 batch introduced, in both languages.
    func test_bootBodyAndBulkDeleteStrings_existInBothLanguages() {
        let zhStrings = [
            zh.serverStarting, zh.serverStartFailed,
            zh.keyGenerationFailed, zh.embeddedServerStartFailed,
            zh.messageBody, zh.bulkDeleteFailed,
        ]
        let enStrings = [
            en.serverStarting, en.serverStartFailed,
            en.keyGenerationFailed, en.embeddedServerStartFailed,
            en.messageBody, en.bulkDeleteFailed,
        ]
        for value in zhStrings + enStrings {
            XCTAssertFalse(value.isEmpty)
        }
        for (chinese, english) in zip(zhStrings, enStrings) {
            XCTAssertNotEqual(chinese, english, "untranslated string pair: \(chinese)")
        }
    }

    /// The embedded server's errors are what the boot-failure screen renders,
    /// and they are non-View code — so they must follow the stored preference,
    /// not a hardcoded language.
    func test_embeddedServerErrors_followTheStoredLanguage() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(
            EmbeddedServerError.startFailed.errorDescription,
            "The embedded server couldn't start"
        )
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(EmbeddedServerError.startFailed.errorDescription, "内嵌服务启动失败")
    }
}
