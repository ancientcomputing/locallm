import Foundation
import LocalLMLabSDKCore
import Testing

import LocalLMLabSDKMCPAppsHost

// The session-backed adapter for model-present hosts. Public API only; the session behavior
// itself is tested in the SDK.

@MainActor
@Suite struct MCPAppsSessionBackendTests {
    private func session() throws -> (LocalLMLab, LocalLMLabSession) {
        let lab = LocalLMLab(configuration: .init(providers: [SystemModelProvider()]))
        lab.models.route(.light, to: .system)
        return (lab, try lab.makeSession(route: .light))
    }

    @Test func widgetContextReachesTheSessionAsText() throws {
        let (_, s) = try session()
        let actions = MCPAppsHostActions.session(s, instance: "w1")
        actions.updateModelContext(
            [.object(["type": .string("text"), "text": .string("Selected 2 tasks")])],
            .object(["ids": .array([.string("a"), .string("b")])]))
        let entry = try #require(s.hostTranscript.entries.first)
        #expect(entry.appInstance == "w1")
        guard case .appContext(let instance, let text) = entry.content else { Issue.record("expected an app-context entry"); return }
        #expect(instance == "w1")
        #expect(text == "Selected 2 tasks\n{\"ids\":[\"a\",\"b\"]}")
    }

    @Test func handlersCanDeclareMCPAppsSupport() {
        let handlers = MCPClientHandlers(extensions: ["other": .bool(true)]).advertisingMCPApps()
        #expect(handlers.extensions["other"] == .bool(true))
        #expect(handlers.extensions[MCPClientHandlers.mcpAppsExtensionKey]
                == .object(["mimeTypes": .array([.string(MCPAppResource.mimeType)])]))
    }

    @Test func aCallToAServerTheSessionDoesNotKnowIsNotFound() async throws {
        let (lab, s) = try session()
        let backend = MCPAppsSessionBackend(session: s, manager: lab.mcp, server: MCPServerID(rawValue: "https://nowhere.invalid/mcp"), instance: "w1")
        let result = await backend.callTool(name: "find", arguments: [:])
        guard case .failure(.toolNotFound) = result else { Issue.record("expected .toolNotFound, got \(result)"); return }
        #expect(s.hostTranscript.entries.isEmpty)
    }
}
