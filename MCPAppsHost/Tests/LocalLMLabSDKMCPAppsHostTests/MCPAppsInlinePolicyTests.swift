import Foundation
import Testing
import LocalLMLabSDKCore
@testable import LocalLMLabSDKMCPAppsHost

// The inline chat widget's policy and offline backend, moved from ChatAgain.

@MainActor @Suite struct MCPAppsInlinePolicyTests {
    @Test func toolCallsAllowedUnlessViewOnly() async {
        let live = MCPAppsInlinePolicy(viewOnly: false, allowMessages: { false }, allowModelContext: { false })
        #expect(await live.authorizeToolCall(name: "get_forecast", arguments: [:]) == .allow)
        let offline = MCPAppsInlinePolicy(viewOnly: true, allowMessages: { true }, allowModelContext: { true })
        #expect(await offline.authorizeToolCall(name: "get_forecast", arguments: [:]) == .deny("Offline: this view is view-only"))
    }

    @Test func linksOnlyOverHTTPS() async {
        let policy = MCPAppsInlinePolicy(viewOnly: false, allowMessages: { true }, allowModelContext: { true })
        #expect(await policy.authorizeOpenLink(URL(string: "https://example.com")!) == .allow)
        #expect(await policy.authorizeOpenLink(URL(string: "http://example.com")!) != .allow)
        #expect(await policy.authorizeOpenLink(URL(string: "file:///etc/hosts")!) != .allow)
    }

    @Test func messagesAndContextFollowTheAppEachTime() async {
        final class Switch: @unchecked Sendable { var on = false }
        let messages = Switch(), context = Switch()
        let policy = MCPAppsInlinePolicy(viewOnly: false, allowMessages: { messages.on }, allowModelContext: { context.on })
        #expect(await policy.authorizeMessage(text: "hi") != .allow)
        #expect(await policy.authorizeModelContextUpdate() != .allow)
        messages.on = true
        context.on = true
        #expect(await policy.authorizeMessage(text: "hi") == .allow)
        #expect(await policy.authorizeModelContextUpdate() == .allow)
    }

    @Test func offlineBackendReachesNothing() async {
        let backend = MCPAppsOfflineBackend()
        if case .success = await backend.callTool(name: "x", arguments: [:]) { Issue.record("an offline call succeeded") }
        if case .success = await backend.readResource(uri: "ui://x") { Issue.record("an offline read succeeded") }
    }
}
