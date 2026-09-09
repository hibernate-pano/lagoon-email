import SwiftUI
import AppKit

struct ConnectGmailView: View {
    @EnvironmentObject var accounts: AccountStore

    var body: some View {
        VStack(spacing: 16) {
            Text("Lagoon")
                .font(.largeTitle)
                .bold()
            Text("Connect your Gmail to begin.")
                .foregroundStyle(.secondary)
            Button("Connect Gmail") {
                if let url = URL(string: "http://127.0.0.1:8080/oauth/gmail/start") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("After approving in the browser, return here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 260)
    }
}