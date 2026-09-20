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
            }
        }
        .windowResizability(.contentMinSize)
        // Wide enough that the full toolbar + segmented control fit; without
        // this macOS opens a narrow window and pushes trailing items into the
        // ">>" overflow menu.
        .defaultSize(width: 1080, height: 760)
    }
}