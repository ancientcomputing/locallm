import AppKit
import LocalLMLabSDKCore
import SwiftUI

// Security Demo — a frontier model + Calendar + Todoist, where the only UI is the Security
// panel, a Run button, a timer, and an output pane. See Package.swift for the framing and
// README.md for the walkthrough.

// Routes the OAuth redirect (securitydemo://oauth/callback) back into the SDK. Needed when an
// MCP server (Todoist) uses OAuth: MCPServerManager opens the browser on a 401 and suspends
// until this delivers the callback URL. Same shape as examples/components-demo.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "securitydemo" {
            MCPOAuthRedirectListener.shared.handleRedirect(url)
        }
    }
}

@main
struct SecurityDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        MCPOAuthFlow.redirectURI = "securitydemo://oauth/callback"
    }

    var body: some Scene {
        Window("Security Demo", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 520)
                .onAppear { model.startBootstrap() }
        }
        .windowResizability(.contentMinSize)
    }
}
