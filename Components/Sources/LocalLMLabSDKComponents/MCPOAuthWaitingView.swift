import SwiftUI

// Shown while an OAuth sign-in is in flight — MCPOAuthFlow.authorize(_:) has already opened the
// system browser (via NSWorkspace.shared.open in the host app's own code, since Core deliberately
// has no UI/AppKit dependency of its own beyond what CoreLocation/EventKit require) and is
// awaiting the locallmlab://-style redirect callback. This view is the "consent" half of that
// flow from the host app's side — the actual consent screen is the server's own, in the browser;
// this is what the host app shows in the meantime so the user isn't looking at a frozen UI.
@available(macOS 26.0, *)
public struct MCPOAuthWaitingView: View {
    private let serverName: String
    private let onCancel: () -> Void

    public init(serverName: String, onCancel: @escaping () -> Void) {
        self.serverName = serverName
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Waiting for sign-in")
                .font(.headline)
            Text("Complete sign-in to \(serverName) in your browser, then return here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 320)
    }
}
