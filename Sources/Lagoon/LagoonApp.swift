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
            // When launched as a bare executable (`swift run Lagoon`), macOS
            // treats the process as background and the window never activates.
            // A real .app bundle (M1) makes this unnecessary.
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .windowResizability(.contentMinSize)
    }
}