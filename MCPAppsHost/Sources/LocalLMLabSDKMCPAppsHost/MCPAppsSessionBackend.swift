import Foundation
import LocalLMLabSDKCore

// For hosts with a model in the loop: route a
// widget's calls and messages through the LocalLMLabSession, so they pass the session's
// ToolCallAuthorizer (which sees `initiator: .app(instance:)`) and land in its HostTranscript.
// Model-less hosts (a widget browser, say) keep using MCPServerManagerBackend and the bridge policy.

/// An `MCPAppsBackend` whose `tools/call` goes through `session.callMCPTool(…, initiator: .app)`.
///
/// The bridge still enforces its own rules first (the tool must be app-callable, and
/// `MCPAppsBridgePolicy.authorizeToolCall` must allow it; the default policy does); then the
/// session's authorizer decides. Resource reads go to the server directly.
@MainActor
public struct MCPAppsSessionBackend: MCPAppsBackend {
    public let session: LocalLMLabSession
    public let manager: MCPServerManager
    public let server: MCPServerID
    /// Identifies this widget in records, the authorizer and `HostTranscript.appOnlyCallCount`.
    /// Conventionally the id of the tool-call record the widget was opened from.
    public let instance: String

    public init(session: LocalLMLabSession, manager: MCPServerManager, server: MCPServerID, instance: String) {
        self.session = session
        self.manager = manager
        self.server = server
        self.instance = instance
    }

    public func callTool(name: String, arguments: [String: MCPValue]) async -> Result<MCPToolResult, MCPServerError> {
        await session.callMCPTool(server: server, tool: name, arguments: arguments, initiator: .app(instance: instance))
    }

    public func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError> {
        await manager.readResource(server: server, uri: uri)
    }
}

extension MCPAppsHostActions {
    /// Actions that send a widget's `ui/message` into `session` as a user turn and its
    /// `ui/update-model-context` as model context — **only reached when the bridge policy allows
    /// them** (`authorizeMessage` / `authorizeModelContextUpdate` deny by default).
    ///
    /// - Parameters:
    ///   - onReply: called with the model's reply to a widget-sent message (or the error).
    public static func session(
        _ session: LocalLMLabSession,
        instance: String,
        openLink: @escaping @MainActor (URL) -> Void = { _ in },
        onReply: @escaping @MainActor (Result<String, any Error>) -> Void = { _ in },
        requestDisplayMode: @escaping @MainActor (_ mode: String) -> Bool = { _ in false }
    ) -> MCPAppsHostActions {
        MCPAppsHostActions(
            openLink: openLink,
            sendMessage: { text in
                Task { @MainActor in
                    do { onReply(.success(try await session.respond(to: text, fromAppInstance: instance))) } catch { onReply(.failure(error)) }
                }
            },
            updateModelContext: { content, structured in
                session.updateModelContext(contextText(content: content, structured: structured), fromAppInstance: instance)
            },
            requestDisplayMode: requestDisplayMode)
    }

    /// The text a model gets for `ui/update-model-context`: the text items, then the structured
    /// content as JSON.
    static func contextText(content: [MCPValue], structured: MCPValue?) -> String {
        var parts: [String] = content.compactMap { item in
            guard case .object(let object) = item else { return nil }
            if case .string(let text)? = object["text"] { return text }
            return nil
        }
        if let structured {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(structured) { parts.append(String(decoding: data, as: UTF8.self)) }
        }
        return parts.joined(separator: "\n")
    }
}
