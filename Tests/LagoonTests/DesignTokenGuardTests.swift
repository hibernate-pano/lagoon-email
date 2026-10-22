import XCTest
import SwiftUI
import AppKit
@testable import Lagoon

/// The token files are a specification, and this file is what makes them
/// one.
///
/// ## Why this exists
///
/// The audit counted **36 token declarations** across `LagoonSheetSize`,
/// `LagoonMetrics`, `LagoonTypography` and `LagoonTheme`, and found **27 of
/// them dead**: `LagoonTypography` had *zero* references, `LagoonMetrics` had
/// two, and the sheet sizes were used by half the sheets. A design system
/// that nothing reads is worse than no design system — it teaches the next
/// person that the tokens are there, and they go on writing literals. That
/// is exactly how the app ended up with nine sheet widths, three date
/// formats and an unread marker in three sizes.
///
/// So the adoption is asserted, not hoped for. These tests fail when a
/// panel grows its own width again, when a token file stops being read, or
/// when a mail row goes back to spelling out its own typography.
final class DesignTokenGuardTests: XCTestCase {
    // MARK: - The ladder

    /// The panels this domain owns. Every one of them takes its size from
    /// the ladder — that is the whole point of a ladder.
    private static let sizedPanels = [
        "ActionHistorySheet",
        "AdviceSheet",
        "CommandPaletteView",
        "OverrideScopeSheet",
        "RemindersSheet",
        "SenderRankingSheet",
        "SenderSheet",
        "StackSheets",
    ]

    /// The files in the view layer that still spell out a width of their
    /// own.
    ///
    /// This is a **ratchet**, not a verdict. The list records what the
    /// other domains have not converted yet (and two surfaces that are not
    /// sheets at all — a hover card and a status bar). A domain that
    /// converts its panel removes its entry, and the list can only get
    /// shorter. A *new* hardcoded width anywhere in the view layer fails
    /// the build, which is what stops the spread from starting again.
    private static let pendingWidths: [String: Int] = [
        "AISettingsSheet": 460,
        "ComposerSheet": 560,
        "ConnectView": 460,
        "DraftPickerSheet": 560,
        "ListDensity": 300,
        "NewMessageSheet": 620,
        "SettingsView": 460,
        "SyncHealthDetailSheet": 420,
        "TimeSavedBar": 240,
        "UsageSheet": 420,
    ]

    /// Every source file the view layer is built from.
    private func viewSources() throws -> [URL] {
        let root = ViewSource.url(under: "Views", "RootView")
            .deletingLastPathComponent()   // Views
        let urls = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "no view sources found under \(root.path)")
        return urls
    }

    /// The widths a file spells out for itself.
    ///
    /// A sheet's width is three digits or more; the smaller frames inside
    /// a panel (an icon's column, a text field's width) are not sheet
    /// sizes, and pretending they are would make this test cry wolf.
    private static func hardcodedWidths(in source: String) -> [Int] {
        var found: [Int] = []
        var rest = Substring(source)
        while let range = rest.range(of: ".frame(width: ") {
            let after = rest[range.upperBound...]
            let digits = after.prefix { $0.isNumber }
            if let value = Int(digits), value >= 100 {
                found.append(value)
            }
            rest = after
        }
        return found
    }

    /// Every panel this domain owns takes its size from the ladder.
    ///
    /// The audit's sharpest example was the two panels that used exactly
    /// the right size and did not say so: they would have stayed on the old
    /// width the day the `wide` step changed, which is the drift the file
    /// was created to stop.
    func test_everyPanelTakesItsSizeFromTheLadder() throws {
        for panel in Self.sizedPanels {
            let source = try ViewSource.read(panel)
            XCTAssertTrue(
                source.contains("LagoonSheetSize"),
                "\(panel) must take its size from LagoonSheetSize"
            )
            let widths = Self.hardcodedWidths(in: source)
            XCTAssertTrue(
                widths.isEmpty,
                "\(panel) writes its own width(s) \(widths); use a LagoonSheetSize step"
            )
        }
    }

    /// No *new* hardcoded width in the view layer.
    ///
    /// The offenders are recorded rather than forbidden, because the panels
    /// that still have one belong to other domains — but the list only ever
    /// gets shorter, and a file that is not on it has invented a width.
    func test_noNewSheetWidthIsWrittenOutsideTheLadder() throws {
        var offenders: [String: Int] = [:]
        for url in try viewSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            if let width = Self.hardcodedWidths(in: text).first {
                offenders[url.lastPathComponent] = width
            }
        }
        let unexpected = offenders.filter { Self.pendingWidths[$0.key] != $0.value }
        XCTAssertTrue(
            unexpected.isEmpty,
            """
            These files write a width of their own. Use a LagoonSheetSize step, \
            or record the file in the ratchet while its domain has not converted it: \
            \(unexpected.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: ", "))
            """
        )
    }

    /// The ladder is a ladder: distinct steps, and no dead one.
    ///
    /// A step nobody uses is a number in a file that means nothing, and two
    /// steps with the same width are one step wearing two names.
    func test_everyStepOfTheLadderIsDistinctAndUsed() throws {
        let source = try String(
            contentsOf: ViewSource.url(under: "Theme", "LagoonSheetSize"),
            encoding: .utf8
        )
        let steps = ["compact", "standard", "composer", "wide"]
        var widths: [String: Int] = [:]
        for step in steps {
            let declaration = try XCTUnwrap(
                source.range(of: "static let \(step) = CGSize(width: "),
                "the '\(step)' step moved"
            )
            let digits = source[declaration.upperBound...].prefix { $0.isNumber }
            widths[step] = try XCTUnwrap(
                Int(digits), "the '\(step)' step has no width"
            )
        }
        XCTAssertEqual(
            Set(widths.values).count, widths.count,
            "two steps share a width: \(widths)"
        )
        for step in steps {
            var users: [String] = []
            for url in try viewSources() {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("LagoonSheetSize.\(step)") {
                    users.append(url.lastPathComponent)
                }
            }
            XCTAssertFalse(
                users.isEmpty,
                "the '\(step)' step of the ladder is used by nobody — it is a dead token"
            )
        }
    }

    // MARK: - The gaps

    /// The panels this domain owns, plus the marker they share.
    private static let gappedPanels = sizedPanels + ["UnreadMarker"]

    /// Every gap value written as a literal.
    ///
    /// A gap is a `spacing:` or a `padding(…)`. Zero is not a gap — it is
    /// the explicit "no gap" of a stack that a divider separates — so it is
    /// allowed to stay a literal.
    private static func rawGaps(in source: String) -> [String] {
        let pattern = try? NSRegularExpression(
            pattern: #"spacing:\s*(\d+)|\.padding\(\s*(\d+)\s*\)|\.padding\(\s*\.\w+\s*,\s*(\d+)\s*\)"#
        )
        guard let pattern else { return [] }
        let ns = source as NSString
        var found: [String] = []
        pattern.enumerateMatches(
            in: source,
            range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match, match.numberOfRanges >= 4 else { return }
            for index in 1..<4 {
                let range = match.range(at: index)
                guard range.location != NSNotFound else { continue }
                let value = ns.substring(with: range)
                if value != "0" { found.append(value) }
            }
        }
        return found
    }

    /// Every gap in these panels is a rung of the one scale.
    ///
    /// The panels used fourteen different gap values — 2, 3, 4, 6, 8, 10,
    /// 12, 14, 16, 18, 20, 30 — for one scale with six rungs. A row's lines
    /// were 2pt apart in one panel and 4pt in another; a header's padding
    /// was 12 in one panel and 18 in another; the same loading spinner was
    /// padded by 20 in one sheet and 30 in another. Nothing about those
    /// differences was a decision, and all of them were visible.
    ///
    /// This is the "one concept, one spacing" half of the token contract,
    /// and it is the half a reader of the code cannot check by eye — so it
    /// is checked mechanically.
    func test_thePanelsTakeTheirGapsFromTheScale() throws {
        for panel in Self.gappedPanels {
            let source = try ViewSource.read(panel)
            let literals = Self.rawGaps(in: source)
            XCTAssertTrue(
                literals.isEmpty,
                """
                \(panel) writes the gap(s) \(literals) instead of a LagoonMetrics rung. \
                The scale is 4 / 8 / 12 / 16 / 24 / 32 — pick the rung, do not invent a number.
                """
            )
        }
    }

    /// And the column a row's leading icon occupies is one column.
    ///
    /// The action history and the reminders used 20pt, the command palette
    /// 22pt — so the same icon sat in a slightly wider column in one panel
    /// than in another, and the text after it did not line up.
    func test_thePanelsDoNotWriteTheirOwnIconColumn() throws {
        for panel in Self.gappedPanels {
            let source = try ViewSource.read(panel)
            let pattern = #"\.frame\(width:\s*(\d+)"#
            let regex = try NSRegularExpression(pattern: pattern)
            let ns = source as NSString
            let matches = regex.matches(
                in: source,
                range: NSRange(location: 0, length: ns.length)
            )
            XCTAssertTrue(
                matches.isEmpty,
                "\(panel) writes its own icon-column width; use LagoonMetrics.iconColumnWidth"
            )
        }
    }

    // MARK: - The token files are alive

    /// The two token files the audit called dead have to be *read*.
    ///
    /// A token file nobody reads is a document about a design system the
    /// app does not have — and the next person to add a literal will point
    /// at it and say "there is a token for that" when there is not.
    func test_theMetricsAndTypographyTokensAreReadByTheViewLayer() throws {
        for token in ["LagoonMetrics", "LagoonTypography"] {
            var readers: [String] = []
            for url in try viewSources() {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("\(token).") {
                    readers.append(url.lastPathComponent)
                }
            }
            XCTAssertGreaterThanOrEqual(
                readers.count, 2,
                "\(token) is read by \(readers.count) file(s) — the token file is dead again"
            )
        }
    }

    /// The mail rows share one typography and one timestamp rule.
    ///
    /// The audit found the same mailbox rendered with three date formats and
    /// two row spacings. The token file that describes the shared rule was
    /// written for exactly this and had zero references.
    func test_theMailRowsShareOneTypographyAndOneTimestamp() throws {
        for panel in ["SenderSheet", "StackSheets"] {
            let source = try ViewSource.read(panel)
            XCTAssertTrue(
                source.contains("LagoonTypography.rowSubject"),
                "\(panel) must typeset its subject from LagoonTypography"
            )
            XCTAssertTrue(
                source.contains("LagoonTypography.rowTimestamp("),
                "\(panel) must use the shared timestamp rule"
            )
            XCTAssertFalse(
                source.contains(".formatted(date: .abbreviated"),
                "\(panel) writes its own date format"
            )
            XCTAssertFalse(
                source.contains(".formatted(date: .omitted"),
                "\(panel) writes its own date format"
            )
        }
    }

    /// The unread marker is drawn once, in one place, at one size.
    ///
    /// The audit found the same marker at 6pt, 7pt and 8pt, in the system
    /// accent colour in one surface and a fixed teal in another. A marker
    /// that each surface draws differently is the same defect one level
    /// down from the row itself.
    func test_theUnreadMarkerIsDrawnByTheSharedView() throws {
        for panel in ["SenderSheet", "StackSheets"] {
            let source = try ViewSource.read(panel)
            XCTAssertTrue(
                source.contains("UnreadMarker(isUnread:"),
                "\(panel) must draw the shared UnreadMarker"
            )
            XCTAssertFalse(
                source.contains("Circle()"),
                "\(panel) draws its own dot — the marker must be one view"
            )
        }
    }

    // MARK: - The unread marker survives the dark appearance

    /// The colour of a colour, resolved for one appearance.
    private func resolved(_ color: NSColor, _ appearance: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            result = color
        }
        return result.usingColorSpace(.sRGB) ?? color
    }

    /// The relative luminance of a colour, per WCAG.
    private func luminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }

    /// The contrast ratio between two colours, per WCAG.
    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The unread marker must be visible on a dark row.
    ///
    /// It used to be a fixed deep teal whose own comment claimed it "holds
    /// its contrast in both appearances" — on a near-black row it is
    /// invisible, so the one thing that says "unread" was the thing a
    /// dark-mode user could not see. The comment was the only thing saying
    /// otherwise, and it was wrong.
    func test_theUnreadMarkerSurvivesTheDarkAppearance() {
        let lightRow = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let darkRow = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)

        let lightMarker = resolved(LagoonTheme.unreadMarkerColor, .aqua)
        let darkMarker = resolved(LagoonTheme.unreadMarkerColor, .darkAqua)

        XCTAssertNotEqual(
            lightMarker, darkMarker,
            "the unread marker must follow the appearance"
        )
        XCTAssertGreaterThan(
            contrast(lightMarker, lightRow), 3.0,
            "the unread marker must be visible on a light row"
        )
        XCTAssertGreaterThan(
            contrast(darkMarker, darkRow), 3.0,
            "the unread marker must be visible on a dark row"
        )
    }
}
