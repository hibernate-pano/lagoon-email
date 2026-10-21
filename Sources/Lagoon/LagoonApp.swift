import SwiftUI
import AppKit

@main
struct LagoonApp: App {
    @StateObject private var accounts = AccountStore()
    @StateObject private var serverBoot = EmbeddedServerBoot()
    /// The app-level poller that drives the Dock badge and the new-mail
    /// notification. It lives here rather than in a view because both of
    /// those have to keep working with the window closed.
    @StateObject private var mailbox = MailboxMonitor.shared
    /// The reminders the user set, re-armed from the app's own store on
    /// every launch. A scheduled notification lives in the system's queue
    /// and the system forgets it across a reboot, so the store is the
    /// truth and this rebuilds the delivery.
    @StateObject private var reminders = ReminderScheduler.shared

    var body: some Scene {
        WindowGroup("Lagoon") {
            Group {
                switch serverBoot.phase {
                case .starting:
                    // The embedded server binds in well under a second; this
                    // only exists so no view races a not-yet-listening socket.
                    //
                    // Copy via `L10n.current`, not a literal: `LagoonApp` is
                    // not a View and during boot there is no `RootView` yet to
                    // inject `\.l10n` (RootView is what does it for the rest of
                    // the app), so the startup phase reads the stored
                    // preference the same way non-View code does. Hardcoded
                    // Chinese here was the one systematic localization gap:
                    // English installs booted showing Chinese.
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.current.serverStarting).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Text(L10n.current.serverStartFailed).font(.headline)
                        Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(L10n.current.retry) { serverBoot.retry() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    // The account id is read from the Keychain off the main
                    // thread (see `AccountStore.load`), so the window opens
                    // immediately and the answer arrives a moment later.
                    // Showing the connect screen during that gap would flash
                    // the wrong screen at every launch, so the boot screen
                    // stays up until the answer is in.
                    if !accounts.isLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if accounts.isKeychainBlocked {
                        // The Keychain has the account, but this build is
                        // not allowed to read it.
                        //
                        // This screen exists because the old behaviour was
                        // to show the *connect* form: the user had a
                        // working mailbox, and the app asked them to
                        // re-enter their QQ auth code — and then wrote over
                        // the account that was already there. A hang with
                        // no explanation is the defect; so is a wrong
                        // screen with a destructive next step.
                        KeychainAuthorizationView(
                            onRetry: { Task { await accounts.load() } }
                        )
                    } else if accounts.accountId == nil {
                        ConnectView()
                    } else {
                        // Spec §7.1: the Briefing Feed is the default landing surface.
                        RootView()
                    }
                }
            }
            .environmentObject(accounts)
            // `lagoon://` links. Declared in Support/Info.plist, so the
            // system routes them here; the handler turns them into the same
            // commands the menu bar raises.
            //
            // This is on the *view*, not on the scene: `onOpenURL` is a View
            // modifier, and a Scene has no equivalent.
            .onOpenURL { url in
                LagoonURLHandler.handle(url)
                // A link means the user asked for something: bring the
                // window forward so the answer is visible.
                NSApp.activate(ignoringOtherApps: true)
            }
            .task {
                // The badge and the notification need a poller that outlives
                // the window, so it starts with the app rather than with a
                // view.
                mailbox.start()
            }
            // Brand tint: matches the icon palette so every accent
            // (toggles, links, picker segments, selection highlight)
            // reads as "Lagoon teal", not "system blue".
            .tint(LagoonTheme.brand)
            .task {
                // Read the stored account id before the server finishes
                // booting, so the two are ready at the same time. This runs
                // off the main thread inside `AccountStore` — a Keychain
                // read can block for as long as the user takes to answer
                // the system's authorization dialog, and doing that on the
                // main thread froze the app before it could open a window.
                async let accountLoad: UUID? = accounts.load()
                async let serverStart: Void = serverBoot.run()
                _ = await (accountLoad, serverStart)

                // Re-arm the reminder notifications now that both the
                // account id and the server are ready. The system forgets
                // scheduled notifications across a reboot, so without this
                // the reminders the user set silently stopped firing.
                if let accountId = accounts.accountId {
                    await reminders.armPending(accountId: accountId)
                }
            }
            // When launched as a bare executable (`swift run Lagoon`), macOS
            // treats the process as background and the window never activates.
            // A real .app bundle (M1) makes this unnecessary.
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                // Debug torture: resize storm while the detail toolbar is
                // active — forces toolbar width renegotiation, the overflow
                // (») item path, and the app's own NSWindow Frame
                // defaults writes (the preferencesDidChange in the field
                // crash stack). DEBUG-only *and* env-gated, so neither the
                // code nor its log-writing exists in a release build.
                #if DEBUG
                guard ProcessInfo.processInfo.environment["LAGOON_DEBUG_TORTURE"] == "1" else { return }
                let sizes: [(CGFloat, CGFloat)] = [(720, 480), (1500, 950), (900, 620), (1240, 877)]
                var i = 0
                func resizeCycle() {
                    guard i < 24, let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
                    let (w, h) = sizes[i % sizes.count]
                    window.setContentSize(NSSize(width: w, height: h))
                    BriefingFeedView.debugLog("torture resize \(Int(w))x\(Int(h)) n=\(i)")
                    i += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: resizeCycle)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: resizeCycle)
                #endif
            }
        }
        .windowResizability(.contentMinSize)
        // Wide enough that the full toolbar + segmented control fit; without
        // this macOS opens a narrow window and pushes trailing items into the
        // ">>" overflow menu.
        .defaultSize(width: 1080, height: 760)
        // The app's own menu bar. SwiftUI supplies the standard Edit / Window
        // menus; this adds the app's vocabulary — New Message, Get New Mail,
        // Search, Settings…, the triage panels — so a user's first question
        // ("where is the search?") has an answer that is not "look in the
        // toolbar".
        .commands {
            LagoonAppCommands()
        }

        // The Settings window (⌘,). Declaring it as a *scene* is what puts
        // the item in the application menu and binds ⌘, to it — the app had
        // neither, which is why its preferences were unreachable.
        Settings {
            SettingsView()
        }
    }
}