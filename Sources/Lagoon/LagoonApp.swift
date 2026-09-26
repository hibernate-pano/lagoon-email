import SwiftUI
import AppKit

@main
struct LagoonApp: App {
    @StateObject private var accounts = AccountStore()

    var body: some Scene {
        WindowGroup("Lagoon") {
            Group {
                if accounts.accountId == nil {
                    ConnectView()
                } else {
                    // Spec §7.1: the Briefing Feed is the default landing surface.
                    RootView()
                }
            }
            .environmentObject(accounts)
            // Brand tint: matches the icon palette so every accent
            // (toggles, links, picker segments, selection highlight)
            // reads as "Lagoon teal", not "system blue".
            .tint(LagoonTheme.brand)
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
    }
}