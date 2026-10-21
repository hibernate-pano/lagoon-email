import SwiftUI
import AppKit

/// The app's menu bar.
///
/// ## Why a menu bar at all
///
/// A macOS app that has only a window and a toolbar is a web page in a
/// window. The menu bar is the operating system's own navigation surface,
/// and it is where a user looks for "New Message", "Search", "Get New Mail",
/// "Settings" and the keyboard shortcuts. Before this existed, the app's
/// most-used verbs were reachable **only** through toolbar icons and
/// hidden zero-width buttons — a user who never guessed ⌘K never found the
/// command palette.
///
/// ## Why the app's items go into the *system* menus
///
/// The first version of this file declared its own "File" and "View"
/// menus. The result was a menu bar that read
///
///     Lagoon  文件  编辑  显示  文件  显示  邮件  窗口  帮助
///
/// — two File menus and two View menus, side by side, with no way for a
/// user to tell which one was the real one. SwiftUI already supplies
/// File, Edit, View, Window and Help; an app that adds a second one has
/// stopped designing and started stacking.
///
/// So the app's own verbs now live *inside* the system menus, in the
/// groups the system already reserves for them:
///
/// - **Lagoon** — About, Settings… (⌘,).
/// - **文件 File** — New Message (⌘N), Get New Mail (⇧⌘N).
/// - **显示 View** — Toggle surface (⌘0), list density.
/// - **邮件 Mail** — the app's own namespace: Search (⌘F), Refresh
///   (⌥⌘R), the triage panels, and the command palette (⌘K).
/// - **帮助 Help** — the keyboard-shortcut sheet (⌘/).
///
/// ## One owner per key
///
/// Every key is claimed by exactly one place. A key claimed twice is a key
/// that runs its action twice — which for a *toggle* means it cancels
/// itself out, and the user concludes the app is broken.
///
/// ## The routing
///
/// The menu cannot reach the window's state, so every item sends an
/// `AppCommandRouter.Command`; the window picks it up. See that type for
/// why the seam exists.
struct LagoonAppCommands: Commands {
    @Environment(\.l10n) private var l10n

    var body: some Commands {
        // The application menu: About and Settings… live here on macOS, and
        // "Settings" is a `Settings` scene's job — declaring the scene is
        // what puts the item in this menu and binds ⌘, to it.
        CommandGroup(replacing: .appInfo) {
            Button(l10n.aboutTitle) {
                AppCommandRouter.shared.send(.showAbout)
            }
        }

        CommandGroup(replacing: .appSettings) {
            // macOS binds ⌘, to the Settings scene automatically; this
            // replacement exists only so the item says "Settings…" in the
            // app's own language instead of the system's.
            SettingsLink {
                Text(l10n.settingsTitle)
            }
        }

        // The system File menu. `.newItem` is the group the system's own
        // "New" lives in; for a non-document app it is empty, so the app's
        // two file-shaped verbs fill it.
        CommandGroup(after: .newItem) {
            Button(l10n.menuNewMessage) {
                AppCommandRouter.shared.send(.newMessage)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(l10n.menuGetNewMail) {
                AppCommandRouter.shared.send(.getNewMail)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // The system View menu. `.toolbar` is the group that holds the
        // system's own "Show Toolbar"; the app's surface and density
        // controls belong next to it, because that is the group a user
        // opens when they want to change *how the window looks*.
        CommandGroup(after: .toolbar) {
            Button(l10n.menuToggleSurface) {
                AppCommandRouter.shared.send(.toggleSurface)
            }
            .keyboardShortcut("0", modifiers: .command)

            Button(l10n.menuCycleDensity) {
                AppCommandRouter.shared.send(.cycleDensity)
            }
        }

        // The app's own menu. A mail client's own namespace: everything
        // that acts on the mailbox rather than on the window.
        CommandMenu(l10n.mailMenu) {
            Button(l10n.menuSearch) {
                AppCommandRouter.shared.send(.search(query: nil))
            }
            .keyboardShortcut("f", modifiers: .command)

            Button(l10n.menuRefresh) {
                AppCommandRouter.shared.send(.refresh)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Divider()

            Button(l10n.menuAdvice) {
                AppCommandRouter.shared.send(.showAdvice)
            }
            // ⇧⌘A used to live on a button *inside* the toolbar's ⋯ menu,
            // where a `keyboardShortcut` is only live while that menu is
            // open — so the cheatsheet taught a key that did nothing. A
            // menu-bar item is always live, so the key works everywhere.
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button(l10n.menuActionHistory) {
                AppCommandRouter.shared.send(.showActionHistory)
            }
            // Next to the advice queue for the same reason it sits next to
            // it in the toolbar: the advice queue is what the AI suggests,
            // and the reminder list is what the *user* set. Both are
            // "look before you act", and both must be reachable.
            Button(l10n.menuReminders) {
                AppCommandRouter.shared.send(.showReminders)
            }
            Button(l10n.menuSenderRanking) {
                AppCommandRouter.shared.send(.showSenderRanking)
            }
            Divider()
            Button(l10n.menuUsage) {
                AppCommandRouter.shared.send(.showUsage)
            }
            .keyboardShortcut("b", modifiers: [.command])

            Button(l10n.menuAISettings) {
                AppCommandRouter.shared.send(.showAISettings)
            }
            Divider()
            Button(l10n.menuCommandPalette) {
                AppCommandRouter.shared.send(.showCommandPalette)
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button(l10n.menuKeyboardShortcuts) {
                AppCommandRouter.shared.send(.showShortcuts)
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }
}
