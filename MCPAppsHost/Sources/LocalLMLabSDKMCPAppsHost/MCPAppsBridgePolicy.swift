import Foundation
import LocalLMLabSDKCore

/// The server-side of a bridge: what a view's `tools/call` and `resources/read` are proxied to.
/// A backend is bound to ONE MCP server, so a view can never reach another server's tools — the
/// spec's "same server only" rule holds by construction, not by a check.
@MainActor
public protocol MCPAppsBackend {
    func callTool(name: String, arguments: [String: MCPValue]) async -> Result<MCPToolResult, MCPServerError>
    func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError>
}

/// The standard backend: one server of an `MCPServerManager`.
@MainActor
public struct MCPServerManagerBackend: MCPAppsBackend {
    private let manager: MCPServerManager
    private let server: MCPServerID

    public init(manager: MCPServerManager, server: MCPServerID) {
        self.manager = manager
        self.server = server
    }

    public func callTool(name: String, arguments: [String: MCPValue]) async -> Result<MCPToolResult, MCPServerError> {
        // Elicitation stays available: a view-initiated call is still the user's session.
        await manager.callTool(server: server, tool: name, arguments: arguments)
    }

    public func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError> {
        await manager.readResource(server: server, uri: uri)
    }
}

public enum MCPAppsDecision: Sendable, Equatable {
    case allow
    case deny(String)
}

/// The host's say over what a view may do, on top of what the protocol itself enforces (tool
/// visibility, initialization order). A view is untrusted third-party JavaScript: every effect it
/// requests passes through here.
///
/// Defaults are closed except for tool calls the spec already scopes to app-visible tools of the
/// bound server: `ui/message`, `ui/update-model-context`, `ui/open-link` and non-`ui://` resource
/// reads are DENIED unless the host opts in. A host with no model in the loop simply keeps the
/// defaults.
@MainActor
public protocol MCPAppsBridgePolicy {
    /// Called after the protocol checks (known tool, `app` in its visibility). This is where an
    /// enterprise host confirms writes, applies a per-tool allowlist, or rate-limits.
    func authorizeToolCall(name: String, arguments: [String: MCPValue]) async -> MCPAppsDecision
    func authorizeResourceRead(uri: String) async -> MCPAppsDecision
    func authorizeOpenLink(_ url: URL) async -> MCPAppsDecision
    /// `ui/message`: the view asks to put a user message into the conversation. Only meaningful
    /// in a hosted-model shape (B/C).
    func authorizeMessage(text: String) async -> MCPAppsDecision
    /// `ui/update-model-context`: the view asks to change what the model knows.
    func authorizeModelContextUpdate() async -> MCPAppsDecision
}

extension MCPAppsBridgePolicy {
    public func authorizeToolCall(name: String, arguments: [String: MCPValue]) async -> MCPAppsDecision { .allow }
    public func authorizeResourceRead(uri: String) async -> MCPAppsDecision {
        uri.hasPrefix("ui://") ? .allow : .deny("Only ui:// resources may be read by a view")
    }
    public func authorizeOpenLink(_ url: URL) async -> MCPAppsDecision { .deny("Link opening denied by policy") }
    public func authorizeMessage(text: String) async -> MCPAppsDecision { .deny("Message sending denied by policy") }
    public func authorizeModelContextUpdate() async -> MCPAppsDecision { .deny("Context update denied by policy") }
}

/// The closed-by-default policy: exactly the protocol defaults, with an optional tool allowlist.
@MainActor
public struct MCPAppsDefaultPolicy: MCPAppsBridgePolicy {
    /// When non-nil, only these tools may be called by a view (an IT-approved list). `nil` means
    /// every app-visible tool of the bound server.
    public var allowedTools: Set<String>?

    public init(allowedTools: Set<String>? = nil) {
        self.allowedTools = allowedTools
    }

    public func authorizeToolCall(name: String, arguments: [String: MCPValue]) async -> MCPAppsDecision {
        if let allowedTools, !allowedTools.contains(name) { return .deny("Tool \(name) is not approved for apps") }
        return .allow
    }
}

/// One line of the bridge's audit trail. Argument values and tool output are never recorded —
/// only method names, tool names and outcomes — so the log is safe to persist.
public struct MCPAppsAuditEvent: Sendable, Equatable {
    /// `fromView`: a view request/notification and how the host answered it. `toView`: a
    /// host-initiated notification or request.
    public enum Direction: String, Sendable { case fromView, toView }
    public enum Outcome: String, Sendable { case ok, denied, error, dropped }

    public let direction: Direction
    public let method: String
    public let outcome: Outcome
    /// A short, non-sensitive note (tool name, denial reason, error class).
    public let detail: String?

    public init(direction: Direction, method: String, outcome: Outcome, detail: String? = nil) {
        self.direction = direction
        self.method = method
        self.outcome = outcome
        self.detail = detail
    }
}
