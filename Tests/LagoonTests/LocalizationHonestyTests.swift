import XCTest
import SwiftUI
import Foundation
import LagoonKit
@testable import Lagoon

/// Guards for the localization and copy batch (C-02…C-11) and for the
/// round-two micro-copy items.
///
/// ## The class of bug these guard
///
/// A string is a claim about what the product does. Three ways that claim
/// breaks, and all three are silent:
///
/// 1. **The wrong language.** A scene that cannot inherit the main
///    window's environment reads the environment's *default* — so the
///    menu bar, the settings window and the first-run screen speak
///    Chinese whatever the user picked.
/// 2. **The wrong shape.** A date format is not a localized resource, so
///    an English window shows 「10月8日 09:00」 next to English labels.
/// 3. **The wrong claim.** The copy says "add an account" in the state
///    that means "everything is handled", or names a surface the product
///    does not have, or asks for emphasis with `**` that a plain `Text`
///    prints as asterisks.
///
/// A user who is told one thing and gets another does not conclude "that
/// label is wrong" — they conclude "this app does not tell the truth",
/// and then they stop trusting every other thing it says.
final class LocalizationHonestyTests: XCTestCase {
    private let zh = L10n(language: .zhHans)
    private let en = L10n(language: .english)

    /// CJK ideographs and full-width punctuation.
    ///
    /// An English string that contains any of these is a string the
    /// translation did not reach — the bug in its most visible form.
    private let cjk = CharacterSet(charactersIn: "\u{4E00}-\u{9FFF}")
        .union(CharacterSet(charactersIn: "\u{3000}-\u{303F}"))
        .union(CharacterSet(charactersIn: "\u{FF00}-\u{FFEF}"))

    // MARK: - C-02: the scenes that cannot inherit the environment

    /// The default localizer follows the stored language.
    ///
    /// The main window injects its own localizer, so the main window was
    /// never the problem. The problem was the *other* scenes: the menu
    /// bar, the settings window and the first-run screen are siblings of
    /// the window, not children, so they read the environment's default —
    /// and the default was hardcoded Chinese.
    func test_theDefaultLocalizerFollowsTheStoredLanguage() {
        let key = LanguagePreference.defaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: key)
        XCTAssertEqual(
            EnvironmentValues().l10n.language,
            .english,
            "a scene that inherits no localizer must still start in the user's language"
        )

        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: key)
        XCTAssertEqual(EnvironmentValues().l10n.language, .zhHans)
    }

    /// The stored tag becomes a localizer the same way everywhere.
    func test_aStoredTagBecomesALocalizerTheSameWayEverywhere() {
        XCTAssertEqual(L10n.forStoredTag(AppLanguage.english.rawValue).language, .english)
        XCTAssertEqual(L10n.forStoredTag(AppLanguage.zhHans.rawValue).language, .zhHans)
        XCTAssertEqual(
            L10n.forStoredTag("klingon").language,
            .zhHans,
            "an unreadable tag must fall back to the product's first language, not crash"
        )
        XCTAssertEqual(L10n.forStoredTag("").language, .zhHans)
    }

    /// The two windows that cannot inherit the environment build their own.
    func test_theSiblingScenesBuildTheirOwnLocalizer() throws {
        for name in ["SettingsView", "ConnectView"] {
            let source = try Self.source("Views", name)
            XCTAssertFalse(
                source.contains("@Environment(\\.l10n)"),
                "\(name) is a sibling scene: the main window's environment never "
                    + "reaches it, so reading the environment's default is what "
                    + "left it in Chinese"
            )
            XCTAssertTrue(
                source.contains("L10n.forStoredTag(languageTag)"),
                "\(name) must build its localizer from the stored preference"
            )
        }
    }

    // MARK: - C-11: the first run offers the language

    /// The onboarding screen is the one screen a new user cannot leave
    /// without reading, and the settings window — where the picker
    /// normally lives — cannot be reached until an account is connected.
    func test_theFirstRunScreenOffersTheLanguage() throws {
        let source = try Self.source("Views", "ConnectView")
        XCTAssertTrue(
            source.contains("Picker(l10n.languageLabel, selection: $languageTag)"),
            "the first-run screen must offer the language switch"
        )
        XCTAssertTrue(
            source.contains("LanguagePreference.defaultsKey"),
            "the picker must write the preference the whole app reads"
        )
    }

    // MARK: - C-03: the reminder's date

    /// A date format is not a localized resource.
    ///
    /// `M月d日 HH:mm` prints 「月」 and 「日」 under every locale, and
    /// `locale = .current` does not change that — the pattern is read
    /// literally. So the English window showed 「10月8日 09:00」 next to
    /// English labels, and a Chinese window on an English Mac showed the
    /// same. The format has to follow the language the user picked.
    func test_theReminderTimeFollowsTheAppLanguage() {
        let date = Self.noonOnATenEighthOfOctober()

        let english = en.reminderDueAt(date)
        XCTAssertNil(
            english.rangeOfCharacter(from: cjk),
            "the English reminder time must not contain Chinese: \(english)"
        )
        XCTAssertTrue(
            english.contains("12:00"),
            "the English reminder time must carry the time: \(english)"
        )

        let chinese = zh.reminderDueAt(date)
        XCTAssertTrue(chinese.contains("月"), "the Chinese reminder time must read as a date: \(chinese)")
        XCTAssertTrue(chinese.contains("日"), "the Chinese reminder time must read as a date: \(chinese)")
    }

    /// The same rule in the confirmation the sheet shows.
    func test_theReminderConfirmationFollowsTheAppLanguage() {
        let date = Self.noonOnATenEighthOfOctober()
        XCTAssertNil(
            en.reminderSetConfirmation(date).rangeOfCharacter(from: cjk),
            "the English confirmation must not contain Chinese: \(en.reminderSetConfirmation(date))"
        )
        XCTAssertTrue(zh.reminderSetConfirmation(date).contains("月"))
    }

    // MARK: - C-04: emphasis that is emphasis, not asterisks

    /// The word the user has to read before agreeing is bold.
    ///
    /// `Text` does not read `**` as emphasis — it prints the asterisks.
    /// The confirmation about an irreversible unsubscribe used to show
    /// 「退订是**不可撤销**的」 with the markers visible.
    func test_theEmphasisRendersAsEmphasisAndNotAsAsterisks() {
        for (body, marker) in [(en.adviceAcceptConfirmBody, "cannot be undone"), (zh.adviceAcceptConfirmBody, "不可撤销")] {
            let text = String(body)
            XCTAssertFalse(
                text.contains("**"),
                "the user must not read the markdown markers: \(text)"
            )
            XCTAssertTrue(
                text.contains(marker),
                "the emphasized phrase must survive the rendering: \(text)"
            )
            XCTAssertTrue(
                body.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
                "the phrase must be bold, not merely unmarked: \(text)"
            )
        }
    }

    /// No other string may ask for emphasis it does not get.
    ///
    /// Only two strings are allowed to carry `**`, and both are rendered
    /// as Markdown: this one (an `AttributedString`) and the forward
    /// sheet's line, which `ForwardSheet` renders through
    /// `AttributedString(markdown:)`. A third one would be asterisks on
    /// screen.
    func test_onlyTheMarkdownRenderedStringsCarryEmphasisMarkers() throws {
        var offenders: [String] = []
        for (name, declaration, literal) in try Self.emphasisMarkers() {
            if declaration != "adviceAcceptConfirmBody" && declaration != "forwardKeepsOriginal" {
                offenders.append("\(name) → \(declaration): \(literal)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            These strings ask for emphasis with '**' and are shown as plain text:
            \(offenders.joined(separator: "\n"))

            Either render them as Markdown — `AttributedString(markdown:)` — or
            write the emphasis into the words.
            """
        )
    }

    /// The account-removal confirmation states the reassurance without
    /// markers.
    func test_theAccountRemovalConfirmationHasNoMarkers() {
        XCTAssertFalse(zh.removeAccountConfirmMessage.contains("**"))
        XCTAssertFalse(en.removeAccountConfirmMessage.contains("**"))
        XCTAssertTrue(
            zh.removeAccountConfirmMessage.contains("服务器上的邮件不会被删除"),
            "the reassurance is the reason the dialog can be trusted"
        )
    }

    // MARK: - C-05: the back key

    /// The cheatsheet taught ⌘[ as 「返回上一级」.
    ///
    /// In the two mail-list surfaces ⌘[ clears the selection — it is
    /// Mail.app's "back" muscle memory re-pointed at the one thing it
    /// can mean there. A cheatsheet that teaches the key as "back"
    /// teaches a gesture the surface cannot perform, and the user
    /// concludes the key is broken.
    @MainActor
    func test_theCheatsheetDescribesWhatTheBackKeyActuallyDoes() {
        let row = ShortcutsSheet().entries.first { $0.id == "back" }
        XCTAssertEqual(
            row?.description,
            zh.deselectHelp,
            "the ⌘[ row must describe the selection, not a level of navigation"
        )
        XCTAssertEqual(
            row?.scope,
            .lists,
            "⌘[ is bound in the two list surfaces, and the row must say where"
        )
    }

    // MARK: - C-06: the hint that pointed at a screen that was not there

    /// The hint must point at a control that exists.
    ///
    /// It used to say 「先在侧边栏连接一个邮箱账号」 — and the sidebar has
    /// no connect entry, and disappears entirely when no account is
    /// connected. The connect entry is in the toolbar's account menu.
    func test_theNotConnectedHintPointsAtAControlThatExists() {
        XCTAssertFalse(
            zh.notConnectedHint.contains("侧边栏"),
            "the sidebar has no connect entry: \(zh.notConnectedHint)"
        )
        XCTAssertFalse(
            en.notConnectedHint.lowercased().contains("sidebar"),
            "the sidebar has no connect entry: \(en.notConnectedHint)"
        )
        XCTAssertTrue(zh.notConnectedHint.contains("菜单"), "the account menu is where accounts are added")
        XCTAssertTrue(en.notConnectedHint.lowercased().contains("menu"))
    }

    // MARK: - C-07: the empty inbox

    /// The empty state that means "everything is handled" must not ask for
    /// an account.
    func test_theEmptyInboxDoesNotAskForAnAccount() {
        XCTAssertFalse(
            zh.tapToSync.contains("添加"),
            "every message is already handled in this state: \(zh.tapToSync)"
        )
        XCTAssertFalse(
            en.tapToSync.lowercased().contains("add an email account"),
            "every message is already handled in this state: \(en.tapToSync)"
        )
        XCTAssertTrue(zh.tapToSync.contains("同步"), "the state is about syncing: \(zh.tapToSync)")
    }

    // MARK: - C-08: the two languages must say the same thing

    /// A confirmation in two languages that means two different things.
    ///
    /// 中文 said the mail had been filed into a group; English said a
    /// group had been created. What happens is the second one: the
    /// sender becomes a group. The first promised a filing that never
    /// happens.
    func test_theGroupConfirmationMeansTheSameThingInBothLanguages() {
        XCTAssertTrue(zh.senderFiled.contains("创建"), "the group is created: \(zh.senderFiled)")
        XCTAssertTrue(en.senderFiled.lowercased().contains("created"), "the group is created: \(en.senderFiled)")
        XCTAssertFalse(
            zh.senderFiled.contains("归入"),
            "the completion is a created group, not filed mail: \(zh.senderFiled)"
        )
    }

    // MARK: - C-10: one name per state

    /// The same state had two names.
    ///
    /// The account menu said 「同步正常」 and the health panel said
    /// "Syncing" — and "Syncing" names a movement, so a healthy account
    /// looked busy at rest.
    func test_oneNamePerSyncState() {
        XCTAssertEqual(zh.healthStatusText(.ok), zh.syncStatusOk)
        XCTAssertEqual(en.healthStatusText(.ok), en.syncStatusOk)

        let states: [SyncHealth.Status] = [.ok, .degraded, .needsReconnect, .accountMissing, .error]
        let names = Set(states.map { en.healthStatusText($0) })
        XCTAssertEqual(
            names.count,
            states.count,
            "two states must not share a name: \(states.map { en.healthStatusText($0) })"
        )
    }

    // MARK: - ③: an action and its completion are different words

    /// 「归档」 is what the button does; 「已归档」 is what happened.
    ///
    /// One string used to be both, so a right-click menu offered
    /// 「已归档」 — a past-tense word where a verb belongs.
    func test_theArchiveActionAndItsCompletionAreDifferentWords() {
        XCTAssertEqual(zh.archiveAction, "归档")
        XCTAssertEqual(zh.archivedToast, "已归档")
        XCTAssertEqual(en.archiveAction, "Archive")
        XCTAssertEqual(en.archivedToast, "Archived")
    }

    // MARK: - ⑩ / ⑫: the cheatsheet's rows must be bound where they are live

    /// ⌘0 is the app menu's surface toggle, so the row is honest.
    ///
    /// A `keyboardShortcut` on a button inside a toolbar `Menu` is only
    /// live while that menu is open — the cheatsheet taught keys that
    /// did nothing. The app menu's items are always live, and ⌘0 is one
    /// of them.
    func test_theSurfaceKeyIsBoundInTheAppMenu() throws {
        let commands = try Self.source("Platform", "LagoonAppCommands")
        XCTAssertTrue(
            commands.contains(".keyboardShortcut(\"0\", modifiers: .command)"),
            "⌘0 must be bound in the app menu, where the shortcut is always live"
        )
        XCTAssertTrue(
            commands.contains("AppCommandRouter.shared.send(.toggleSurface)"),
            "⌘0 must switch surfaces"
        )
        @MainActor
        let row = ShortcutsSheet().entries.first { $0.id == "briefing" }
        XCTAssertEqual(row?.description, zh.surfaceHelp)
    }

    /// ⌘B and ⇧⌘A are app-menu items, so they work everywhere.
    func test_theBudgetAndAdviceKeysAreBoundInTheAppMenu() throws {
        let commands = try Self.source("Platform", "LagoonAppCommands")
        XCTAssertTrue(
            commands.contains(".keyboardShortcut(\"b\", modifiers: [.command])"),
            "⌘B must be bound in the app menu, where the shortcut is always live"
        )
        XCTAssertTrue(
            commands.contains(".keyboardShortcut(\"a\", modifiers: [.command, .shift])"),
            "⇧⌘A must be bound in the app menu, where the shortcut is always live"
        )
    }

    // MARK: - The orphan rule

    /// A string nobody reaches is a promise nobody keeps.
    ///
    /// The dead-key test next door counts a mention in a *test* as a use,
    /// which is right for a copy assertion and wrong for a string that
    /// only ever appears in a test. This one asks the harder question:
    /// does the product show it?
    ///
    /// The pending list is a subset, not an equality: a key that gets
    /// wired stays on the list harmlessly, and only a *new* orphan fails.
    /// That is the direction that matters — the point is to catch a
    /// string nobody reaches, not to police a snapshot of the tree.
    func test_everyStringTheProductDeclaresIsOneTheProductShows() throws {
        let orphans = try Self.productOrphans()
        let unexpected = orphans.filter { Self.pendingOrphans[$0] == nil }
        XCTAssertTrue(
            unexpected.isEmpty,
            """
            These strings are declared and never shown:
            \(unexpected.sorted().joined(separator: ", "))

            Delete them, or wire them up. If another domain is mid-flight
            with one of them, add it to `pendingOrphans` with the owner.
            """
        )
    }

    /// Strings that are declared but not yet reachable, each with the
    /// owner of the work that will wire them up.
    private static let pendingOrphans: [String: String] = [
        "senderAllReadDone": "domain E — SenderSheet shows the toast when a bulk mark-read finishes",
        "soundOn": "domain E — the panels file, the sound toggle in the triage panels",
        "soundOff": "domain E — the panels file, the sound toggle in the triage panels",
    ]

    // MARK: - Helpers

    /// A source file, by directory and name.
    private static func source(_ directory: String, _ name: String) throws -> String {
        try String(contentsOf: ViewSource.url(under: directory, name), encoding: .utf8)
    }

    /// A date at noon, so that no time zone can move it to another day.
    private static func noonOnATenEighthOfOctober() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 8
        components.hour = 12
        return Calendar.current.date(from: components)!
    }

    /// Every `public var` / `public func` the localization files declare.
    private static func declaredKeys(in source: String) -> [String] {
        var keys: [String] = []
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("public var ") || trimmed.hasPrefix("public func ") else {
                continue
            }
            let afterKeyword = trimmed.dropFirst(trimmed.hasPrefix("public var ") ? 11 : 12)
            let name = afterKeyword.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { keys.append(String(name)) }
        }
        return keys
    }

    /// Every identifier that appears after a dot, in one pass.
    private static func memberNames(in source: String) -> Set<String> {
        var names = Set<String>()
        var current = ""
        var afterDot = false
        for character in source {
            if afterDot {
                if character.isLetter || character.isNumber || character == "_" {
                    current.append(character)
                    continue
                }
                if !current.isEmpty { names.insert(current) }
                current = ""
                afterDot = false
            }
            if character == "." {
                afterDot = true
                current = ""
            }
        }
        if !current.isEmpty { names.insert(current) }
        return names
    }

    /// Every identifier in the source, with how often it appears.
    private static func identifierCounts(in source: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        var current = ""
        func flush() {
            if !current.isEmpty { counts[current, default: 0] += 1 }
            current = ""
        }
        for character in source {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return counts
    }

    /// Every localization file.
    private static func localizationSources() throws -> [URL] {
        let root = ViewSource.url(under: "Localization", "L10n")
            .deletingLastPathComponent()
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL) }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path } ?? []
        XCTAssertFalse(urls.isEmpty, "no localization files found under \(root.path)")
        return urls
    }

    /// Every source file of the app — the module that owns the strings.
    ///
    /// `LagoonKit` and `LagoonServer` are separate modules and cannot see
    /// `L10n`, so a member named `archived` over there says nothing about
    /// whether the app shows the string.
    private static func productSources() throws -> [URL] {
        let root = ViewSource.url(under: "Views", "RootView")
            .deletingLastPathComponent()          // Views
            .deletingLastPathComponent()          // Lagoon
        let localization = root.appendingPathComponent("Localization")
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { ($0 as? URL) }
            .filter { $0.pathExtension == "swift" }
            .filter { $0.deletingLastPathComponent().path != localization.path } ?? []
        XCTAssertFalse(urls.isEmpty, "no product sources found under \(root.path)")
        return urls
    }

    /// The strings the product declares and never shows.
    private static func productOrphans() throws -> [String] {
        var declared: [String] = []
        var used = Set<String>()

        for url in try localizationSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let keys = declaredKeys(in: text)
            declared.append(contentsOf: keys)
            // A localization file may compose one string from another by
            // bare name; that is a use.
            let counts = identifierCounts(in: text)
            for key in keys where (counts[key] ?? 0) > 1 {
                used.insert(key)
            }
            // A declaration in one localization file is a use of a string
            // another file declares.
            used.formUnion(memberNames(in: text))
        }

        for url in try productSources() {
            used.formUnion(memberNames(try String(contentsOf: url, encoding: .utf8)))
        }

        return Array(Set(declared)).subtracting(used).sorted()
    }

    /// Every string literal that carries the `**` emphasis marker, with
    /// the declaration it belongs to.
    ///
    /// The scan is over *literals*, not lines: these files are full of
    /// comments that write `**` while talking about `**`, and a line-based
    /// scan would read the documentation as if it were copy.
    private static func emphasisMarkers() throws -> [(file: String, declaration: String, literal: String)] {
        let pattern = try NSRegularExpression(pattern: "\"([^\"]*\\*\\*[^\"]*)\"")
        var found: [(file: String, declaration: String, literal: String)] = []
        for url in try localizationSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            var declaration = ""
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("public var ") || trimmed.hasPrefix("public func ") {
                    let afterKeyword = trimmed.dropFirst(trimmed.hasPrefix("public var ") ? 11 : 12)
                    declaration = String(afterKeyword.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                }
                guard !trimmed.hasPrefix("//") else { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                for match in pattern.matches(in: line, range: range) {
                    guard let swiftRange = Range(match.range, in: line) else { continue }
                    found.append((url.lastPathComponent, declaration, String(line[swiftRange])))
                }
            }
        }
        return found
    }
}
