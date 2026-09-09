import SwiftUI

@main
struct LagoonApp: App {
    @StateObject private var accounts = AccountStore()

    var body: some Scene {
        WindowGroup("Lagoon") {
            Group {
                if accounts.accountId == nil {
                    ConnectGmailView()
                } else {
                    MessageListView()
                }
            }
            .environmentObject(accounts)
        }
        .windowResizability(.contentMinSize)
    }
}