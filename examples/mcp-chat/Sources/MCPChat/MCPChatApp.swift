import AppKit
import LocalLMLabSDKCore
import SwiftUI

// OAuth callbacks arrive as a custom-scheme URL. Route them through the AppDelegate, not SwiftUI's
// .onOpenURL — WindowGroup opens an extra window per open-URL event.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { MCPOAuthRedirectListener.shared.handleRedirect(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MCPChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var chat: ChatModel

    init() {
        // Distinct scheme (see Info.plist) so this app's OAuth callback can't reach another app.
        MCPOAuthFlow.redirectURI = "mcpchat://oauth/callback"
        _chat = StateObject(wrappedValue: ChatModel())
    }

    var body: some Scene {
        WindowGroup {
            ChatRootView(chat: chat)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 820, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { chat.newConversation() }.keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
        }
    }
}
