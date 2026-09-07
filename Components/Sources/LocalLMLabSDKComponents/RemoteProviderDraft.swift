import Foundation

/// The editable state of one online provider in an "AI Models" settings panel
/// (docs/12-remote-model-providers.md §5). Components owns this UI-facing shape; the **host**
/// maps it to a `RemoteProviderConfig` (from `LocalLMLabSDKRemote`, which Components does not
/// depend on) and calls `lab.models.replace(RemoteModelProvider(config))`, persisting the key
/// to its own Keychain. `RemoteProviderDraft.applied(to:)` in the example app shows the ~20
/// lines of mapping.
public struct RemoteProviderDraft: Identifiable, Hashable, Sendable {
    public var id: String { scheme }

    /// `ModelID` scheme this provider owns — `"openai"`, `"anthropic"`, `"openrouter"`, …
    public var scheme: String
    /// Name for the section header.
    public var displayName: String
    /// Which preset / wire the host should build. `.openAICompatible` also uses `baseURL`.
    public var kind: RemoteProviderKind
    /// Base URL, only meaningful for `.openAICompatible`.
    public var baseURL: String
    /// The API key. Components never persists it — it round-trips through the host.
    public var apiKey: String
    /// Model ids to expose, one per line in the editor (`"gpt-6-astra"`, `"anthropic/claude-…"`).
    /// `RemoteProviderDraft.new(_:)` leaves this empty — Components has no opinion on which
    /// model id is current, cheap, or good for a given app; the host prefills it (docs/12 §10).
    public var models: [String]
    /// Whether this provider/wire can do provider-native web search (drives the checkbox).
    public var webSearchSupported: Bool
    /// The checkbox state.
    public var webSearchEnabled: Bool
    /// Max provider-native searches per turn.
    public var maxSearches: Int
    /// `true` once a key is entered and the host has registered the provider.
    public var configured: Bool
    /// A short status/error line under the header (`nil` = nothing to say).
    public var statusText: String?

    public init(
        scheme: String,
        displayName: String,
        kind: RemoteProviderKind,
        baseURL: String = "",
        apiKey: String = "",
        models: [String] = [],
        webSearchSupported: Bool = false,
        webSearchEnabled: Bool = false,
        maxSearches: Int = 5,
        configured: Bool = false,
        statusText: String? = nil
    ) {
        self.scheme = scheme
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
        self.webSearchSupported = webSearchSupported
        self.webSearchEnabled = webSearchEnabled
        self.maxSearches = maxSearches
        self.configured = configured
        self.statusText = statusText
    }
}

/// Which preset / wire a `RemoteProviderDraft` maps to. `.openAICompatible` is the escape
/// hatch for a self-hosted or third-party OpenAI-compatible endpoint.
public enum RemoteProviderKind: String, Sendable, Hashable, CaseIterable {
    case openAIChat
    case openAIResponses
    case anthropic
    case openRouter
    case openAICompatible

    /// Menu-item wording: recognizable to anyone who follows AI generally (model family names,
    /// "web search"), not OpenAI's own internal API names ("Chat Completions" / "Responses").
    public var addMenuLabel: String {
        switch self {
        case .openAIChat: return "OpenAI (GPT)"
        case .openAIResponses: return "OpenAI (GPT + Web Search)"
        case .anthropic: return "Anthropic / Claude"
        case .openRouter: return "OpenRouter"
        case .openAICompatible: return "Custom (OpenAI-compatible)"
        }
    }
}

public extension RemoteProviderDraft {
    /// A blank draft for `kind`, prefilled with the usual scheme / name / capability hints —
    /// but deliberately **no default `models`** (docs/12 §10). Components has no opinion on
    /// which model id is current, cheap, or good for a given app's users, and a hardcoded
    /// guess here goes stale the moment a provider retires that model (that's exactly how
    /// "anthropic/claude-3.7-sonnet" 404ed for everyone using it, 2026-09). The host — who has
    /// current information and its own product judgment ("gpt-4o is good enough" vs. chasing
    /// the newest release) — is expected to set `models` right after calling this, e.g.:
    ///
    /// ```swift
    /// var draft = RemoteProviderDraft.new(.openAIChat)
    /// draft.models = MyAppsCurrentModelPicks.openAI   // the app's own table, its own opinion
    /// ```
    static func new(_ kind: RemoteProviderKind) -> RemoteProviderDraft {
        switch kind {
        case .openAIChat:
            return .init(scheme: "openai", displayName: "OpenAI", kind: kind, models: [])
        case .openAIResponses:
            return .init(scheme: "openai", displayName: "OpenAI (Web Search)", kind: kind,
                         models: [], webSearchSupported: true)
        case .anthropic:
            return .init(scheme: "anthropic", displayName: "Anthropic", kind: kind,
                         models: [], webSearchSupported: true)
        case .openRouter:
            return .init(scheme: "openrouter", displayName: "OpenRouter", kind: kind,
                         models: [], webSearchSupported: true)
        case .openAICompatible:
            return .init(scheme: "custom", displayName: "Custom", kind: kind,
                         baseURL: "http://localhost:1234/v1", models: [])
        }
    }
}
