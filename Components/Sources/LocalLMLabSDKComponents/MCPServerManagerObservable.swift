import LocalLMLabSDKCore
import SwiftUI

// Host-app-side ObservableObject wrapper Core's own MCPServerManager doc comment anticipates —
// Core deliberately isn't an ObservableObject itself (a plain-Swift engine, not SwiftUI-coupled),
// so any host app wanting reactive UI needs exactly this: subscribe to serverChanges, republish as
// @Published. LocalLM Lab hand-wrote its own private copy of this (MCPServerManagerHost.swift)
// before Components existed; this is that same pattern, generalized and made public so no
// consuming app has to write it again.
@available(macOS 26.0, *)
@MainActor
public final class MCPServerManagerObservable: ObservableObject {
    public let core: MCPServerManager

    @Published public private(set) var servers: [MCPServerID: MCPServerState] = [:]

    /// Wraps a caller-owned MCPServerManager rather than constructing one itself — matches
    /// Core's own manager being explicitly non-singleton (see its doc comment: "each host app,
    /// and potentially multiple connections within one app, constructs and owns its own
    /// instance"). Pass the same instance you use elsewhere (e.g. for toolsForSession()) so this
    /// view's UI and your own tool-calling code see the same live state.
    public init(core: MCPServerManager) {
        self.core = core
        Task { [weak self] in
            guard let self else { return }
            for await servers in self.core.serverChanges {
                self.servers = servers
            }
        }
    }

    public var sortedServers: [MCPServerState] {
        servers.values.sorted { $0.displayName < $1.displayName }
    }
}

// MCPServerError doesn't conform to LocalizedError in Core (it's a plain Codable/Sendable enum,
// deliberately not Foundation-coupled) — added here, not there, since human-readable error text
// is a UI concern, not something Core's own callers (which might not even be SwiftUI) all need.
// @retroactive since neither MCPServerError nor LocalizedError is owned by this module.
@available(macOS 26.0, *)
extension MCPServerError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreachable: return "Server unreachable."
        case .malformedResponse: return "Server returned an unexpected response."
        case .protocolMismatch: return "Server speaks an incompatible MCP version."
        case .notConnected: return "Not connected."
        case .toolNotFound: return "Tool not found."
        case .serverError(let message): return message
        case .authorizationRequired: return "Sign-in was not completed."
        case .credentialRejected: return "Token rejected. Check that it's valid and hasn't expired."
        case .httpError(let code): return "Connection failed (HTTP \(code))."
        case .oauthRegistrationNotSupported:
            return "This server requires a pre-registered OAuth app. Switch auth type to \"OAuth (manual client)\" and enter a Client ID from the server's developer console."
        @unknown default:
            return "An unknown error occurred."
        }
    }
}
