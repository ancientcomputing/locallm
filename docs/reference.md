# Full function/type reference

The LocalLM SDK's function and type reference: everything public in `LocalLMLabSDKCore`, `LocalLMLabSDKInference`,
`LocalLMLabSDKRemote`, `LocalLMLabSDKClaude`, `LocalLMLabSDKComponents` and `LocalLMLabSDKMCPAppsHost`, grouped by area,
with what each piece is for. The [SDK guide](sdk-guide.md) is the narrative version, with context and gotchas; the
topic guides go deeper ([MCP](mcp-guide.md), [open-weight models](local-models-mlx.md),
[online providers](remote-providers.md), [decision models](decision-models.md), [the tool authorizer](tool-authorizer.md)).

**You don't need to read this in order.** Jump to the area you need and check the signature.

> The machine-checked source of truth is [`api-surface.md`](api-surface.md), regenerated from the compiled
> `.swiftinterface`s of each release. If this file and that one disagree, that one is right: please file an issue.

**Which example shows each area** (source you can read + run):

| API area | Example | Path |
|---|---|---|
| The model layer — `LocalLMLab`, routing, `MLXModelProvider`, sessions, residency, `ContextBudget` | [`code-buddy`](../examples/code-buddy/) (full) · [`repo-qa-local`](../examples/repo-qa-local/) (minimal) | — |
| Workspace tools (`WorkspaceAccess` / `SearchWorkspaceTool` / `ApplyPatchTool` / …) | [`workspace-buddy`](../examples/workspace-buddy/) (on-device) · [`workspace-buddy-local`](../examples/workspace-buddy-local/) (MLX, sandboxed) · `code-buddy` | A |
| Connectors + ready-made connector `Tool`s | [`plate-today-tools`](../examples/plate-today-tools/) | A |
| Connectors via hand-written `Tool` adapters | [`plate-today`](../examples/plate-today/) | B |
| MCP client + OAuth (Todoist) + Keychain | `plate-today` / `plate-today-tools` | — |
| `MCPTool` built from a live server schema (no hand-written `Arguments`) | [`repo-qa`](../examples/repo-qa/) · [`repo-qa-local`](../examples/repo-qa-local/) | A |
| `Components` — `MCPServerPickerView` / `MCPServerManagerObservable` / resources / prompts | [`components-demo`](../examples/components-demo/) | — |
| `Components` — model layer (`ModelPickerView` / `AIModelsSettingsView` / `ProviderSettingsSection`) | [`model-switch`](../examples/model-switch/) (`AIModelsSettingsView`) | — |
| Tool authorization — `ConfirmingToolAuthorizer`, `ToolConfirmationPresenter`, `limited(toMaxImpact:)`, per-server trust and approval | [`security-demo`](../examples/security-demo/) · [`mcp-chat`](../examples/mcp-chat/) | — |
| A chat with MCP servers and MCP Apps — `hostTranscript`, `MCPAppWidgetSlot`, the confirmation sheet | [`mcp-chat`](../examples/mcp-chat/) | — |
| `FileBackedTool` and the data verbs (`loadTable`, `sqlQuery`) | [`aiql`](../examples/aiql/) | A |
| MLX pins, downloads, validation, updates and the prompt cache | [`mlx-control-room`](../examples/mlx-control-room/) | — |
| `Components` — model onboarding, update and versions views | [`components-updates-demo`](../examples/components-updates-demo/) | — |
| Online providers, web search and citations (`LocalLMLabSDKRemote`) | [`model-switch`](../examples/model-switch/) | — |

## The model layer (`LocalLMLab`, routing, providers, sessions)

```swift
// --- front door ---------------------------------------------------------------
@MainActor final class LocalLMLab {
    struct Configuration {
        var providers: [any ModelProvider]; var state: LocalLMLabState?; var mcp: MCPSettings
        init(providers: [any ModelProvider] = [], state: LocalLMLabState? = nil, mcp: MCPSettings = MCPSettings())
    }
    let models: ModelRegistry
    let mcp: MCPServerManager           // the one manager, made from Configuration.mcp
    let connectors: ConnectorsFacade    // .calendar/.reminders/.contacts/.location permission lifecycle
    let workspace: WorkspaceFacade
    init(configuration: Configuration = .init())
    func snapshot() -> LocalLMLabState                 // route map + residency + installed records; NOT weights
    func restore(from state: LocalLMLabState)
    // from LocalLMLab+makeSession:
    func makeSession(route: RouteName, tools: [any Tool] = [], instructions: String? = nil,
                     restoring transcript: Transcript? = nil,      // continue a saved conversation (instructions nil)
                     includeMCPTools: Bool = true,                  // and keep following lab.mcp between turns
                     mcpAppHints: Bool = false,                     // [MCP Apps](mcp-guide.md#mcp-apps-showing-a-servers-interactive-views)
                     options: SessionOptions = .init(),
                     authorizer: (any ToolCallAuthorizer)? = nil) throws -> LocalLMLabSession   // authorizer: [Tool authorization](sdk-guide.md#tool-authorization-two-levers--which-tools-and-whether-they-ask-first)
}

struct MCPSettings {                    // how the lab sets up lab.mcp — MCPServerManager's own defaults
    var handlers: MCPClientHandlers      // incl. extensions, e.g. .advertisingMCPApps() (LocalLMLabSDKMCPAppsHost)
    var responseLimits: MCPResponseLimits
    var versionNegotiation: MCPVersionNegotiation   // .auto
    var liveUpdates: Bool                            // true
    init(handlers: MCPClientHandlers = MCPClientHandlers(), responseLimits: MCPResponseLimits = .default,
         versionNegotiation: MCPVersionNegotiation = .auto, liveUpdates: Bool = true)
}

struct LocalLMLabState: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var version: Int
    var routes: [RouteName: ModelID]
    var residency: ModelResidency
    // + installed-model records
}

// --- registry ----------------------------------------------------------------
@MainActor final class ModelRegistry {
    var providers: [any ModelProvider] { get }
    var routes: [RouteName: ModelID] { get }
    var residency: ModelResidency                       // set .keepWarm(routes) to prewarm + hold
    let events: AsyncStream<ResidencyEvent>
    func applyResidency() async
    func route(_ route: RouteName, to id: ModelID)
    func modelID(for route: RouteName) -> ModelID?
    func register(_ provider: any ModelProvider) throws  // throws .schemeAlreadyRegistered
    func provider(for id: ModelID) -> (any ModelProvider)?
    func availability(for id: ModelID) -> ModelAvailability
    static let macOS27OnlySchemes: Set<String>          // ["pcc", "claude", "mlx"]
    var schemesRequiringNewerOS: [String] { get }       // on macOS 26: the above, minus any registered
    var downloadableProviders: [any DownloadableModelProvider] { get }
    var installedModels: [InstalledModel] { get }
    var knownModels: [ModelID] { get }                  // union of providers' advertisedModels
    var downloads: [ModelID: DownloadProgress] { get }  // in-flight — bytesReceived/totalBytes/fraction
    func startDownload(_ repoID: String) async throws -> InstalledModel
    func cancelDownload(_ repoID: String)               // no-op if repoID has no in-flight download
}
struct DownloadProgress: Sendable, Equatable {
    var bytesReceived: Int64
    var totalBytes: Int64
    var fraction: Double
}
enum ModelRegistryError: Error, Equatable, CustomStringConvertible { case schemeAlreadyRegistered(String); case noDownloadableProvider }

// --- providers -------------------------------------------------------------
protocol ModelProvider: Sendable {
    static var scheme: String { get }
    func owns(_ id: ModelID) -> Bool                    // default: id.scheme == Self.scheme
    func makeSession(for id: ModelID, tools: [any Tool], instructions: String?,
                     transcript: Transcript?) throws -> LanguageModelSession
    func availability(for id: ModelID) -> ModelAvailability
    func prewarm(_ id: ModelID) async                   // no-op default
    var advertisedModels: [ModelID] { get }             // [] default
}
protocol DownloadableModelProvider: ModelProvider {
    var installed: [InstalledModel] { get }
    func download(_ repoID: String) -> AsyncThrowingStream<DownloadEvent, any Error>   // 0+ .progress, then exactly one .completed, or throws
    func cancelDownload(_ repoID: String)   // aborts the real transfer, not just local consumption of the stream
    func validate(_ repoID: String) async throws -> PreflightResult                    // no weights pulled
    func capabilityProbe(_ id: ModelID) async -> ModelCapabilityReport                 // authoritative for that model's ModelCapabilities
    func remove(_ id: ModelID) throws
    var storageUsed: Int64 { get }
    var residencyEventStream: AsyncStream<ResidencyEvent>? { get }                      // nil default
}
struct SystemModelProvider: ModelProvider { init() }                    // Core
@available(macOS 27, *) struct PCCModelProvider: ModelProvider {           // Core
    init()
    func probe(timeout: Duration = .seconds(8)) async -> ModelAvailability // authoritative PCC liveness check (beta.3+)
}

// --- ClaudeModelProvider — LocalLMLabSDKClaude (separate xcframework, macOS 27) ---
struct ClaudeModelProvider: ModelProvider {
    enum Auth: Sendable { case apiKey(String); case appAttest(clientID: String) }
    init(auth: ClaudeModelProvider.Auth, extraModels: [String: ClaudeModelSpec] = [:])
}
struct ClaudeModelSpec: Sendable, Hashable { /* one Claude model — id, display name, context window */ }

// --- RemoteModelProvider — LocalLMLabSDKRemote (separate xcframework; manifest floor macOS 26,
// like Core — linking it never forces a 27 deployment target; the provider itself reports
// .requiresOS("macOS 27") at runtime on 26, same as pcc) — [Online providers](remote-providers.md) ---
@available(macOS 27, *)
struct RemoteModelProvider: ModelProvider {
    // Always validates — the only initializer without "unchecked" in its
    // name, so there's no shorter unvalidated spelling to reach for by mistake.
    init(_ config: RemoteProviderConfig) throws                 // runs config.validated()
    init(unchecked config: RemoteProviderConfig)                // explicit bypass — trusted configs only
    func probe(for id: ModelID, timeout: Duration = .seconds(8)) async -> ModelAvailability   // zero-token key/model/reachability check
    func turnArtifacts(in transcript: Transcript) -> TurnArtifacts   // server-tool activity + citations for the last turn
}
struct RemoteProviderConfig: Sendable, Equatable {
    var scheme: String                          // the app names it — not privileged like "claude"
    var displayName: String
    var dialect: Dialect
    var baseURL: URL
    var auth: Auth
    var models: [RemoteModel]                   // SDK ships no defaults — see [Online providers](remote-providers.md)
    var capabilities: Set<Capability>            // .webSearch, …
    var defaultOptions: SessionOptions
    var allowArbitraryModelIDs: Bool = false     // true → any "scheme:<string>" routes (OpenRouter)
    var responseLimits: RemoteResponseLimits = .default   // see below
    init(scheme: String, displayName: String, dialect: Dialect, baseURL: URL, auth: Auth,
         models: [RemoteModel] = [], capabilities: Set<Capability> = [],
         defaultOptions: SessionOptions = .init(), allowArbitraryModelIDs: Bool = false,
         responseLimits: RemoteResponseLimits = .default)
}
struct RemoteModel: Sendable, Hashable, Codable, Identifiable {
    var id: String; var displayName: String; var contextWindow: Int?
    init(id: String, displayName: String? = nil, contextWindow: Int? = nil)
}
extension RemoteProviderConfig {
    enum Dialect: String, Sendable, Hashable, Codable { case openAIChat, openAIResponses, anthropicMessages }
    enum Auth: Sendable, Hashable { case apiKey(String); case header(name: String, value: String); case none }
    enum Capability: String, Sendable, Hashable, Codable { case webSearch, structuredOutput, imageInput }

    // Presets — conveniences, zero privilege. Model lists are empty by default (the SDK ships no
    // model ids the host didn't ask for — a hardcoded default drifts and 404s; [Online providers](remote-providers.md)).
    static func openAI(apiKey: String, models: [RemoteModel] = []) -> Self
    static func anthropic(apiKey: String, models: [RemoteModel] = []) -> Self
    static func openRouter(apiKey: String, models: [RemoteModel] = []) -> Self   // allowArbitraryModelIDs = true
    static func openAICompatible(scheme: String, displayName: String, baseURL: URL, apiKey: String?) -> Self

    // Run this on any config whose baseURL/auth came from outside your own
    // code (a pasted URL, an imported profile) — throws ValidationIssue rather than silently
    // sending a key to an untrusted or non-HTTPS host. Syntax check, not a trust check.
    func validated() throws -> RemoteProviderConfig
    enum ValidationIssue: Error, LocalizedError, Equatable {
        case insecureBaseURL(host: String)      // non-HTTPS to a non-local host
        case unsupportedURLScheme(String)       // not http(s)
        case missingHost
        case malformedHeaderName(String)
        case controlCharactersInCredential       // CR/LF in a credential — header injection
    }
}
enum RemoteError: Error, LocalizedError {   // wrapped in LocalLMLabError.generation
    case http(status: Int, message: String)
    case transport(Error)
    case dialectNotImplemented(String)
    case responseTooLarge(String)           // a RemoteResponseLimits bound was exceeded
}

// A custom OpenAI-compatible endpoint is exactly as untrusted as an MCP
// server — this is the Remote-side equivalent of MCPResponseLimits. Applied per-provider via
// RemoteProviderConfig.responseLimits; defaults suit a well-behaved provider.
struct RemoteResponseLimits: Sendable, Hashable {
    var maxResponseBytes: Int             // one non-streaming response body (OpenAI Responses)
    var maxStreamedBytes: Int             // total bytes across an entire SSE stream
    var maxSSELineBytes: Int              // one SSE line / `data:` frame
    var maxEmittedTextBytes: Int          // total assistant text emitted for one turn
    var maxToolCallArgumentBytes: Int     // one tool call's accumulated streamed arguments
    var maxErrorBodyBytes: Int            // a non-2xx error body, before deriving a message
    static let `default`: Self
}

// --- MLXModelProvider — LocalLMLabSDKInference (separate xcframework, macOS 27) ---
@available(macOS 27, *)
struct MLXModelProvider: DownloadableModelProvider {
    static var scheme: String { "mlx" }
    init(cacheDirectory: URL? = nil, residentModelLimit: Int = 1, preflightLimits: MLXPreflightLimits = .init(),
         pinnedRevisions: [String: String] = [:],   // repo id -> HF revision/commit, for reproducible downloads
         supplyChainPolicy: MLXSupplyChainPolicy = .default,   // trust policy + hash verification + cache cap
         pinStore: (any MLXPinStore)? = nil,                   // captured pins (trust on first use); MLXFilePinStore()
         managedPinStore: (any MLXManagedPinStore)? = nil)     // developer-named updates to shipped pins
    var residencyEventStream: AsyncStream<ResidencyEvent>?
    var advertisedModels: [ModelID] { get }
    var installed: [InstalledModel] { get }
    var storageUsed: Int64 { get }
    func makeSession(for id: ModelID, tools: [any Tool], instructions: String?,
                     transcript: Transcript?, options: SessionOptions) throws -> LanguageModelSession
    func availability(for id: ModelID) -> ModelAvailability
    func prewarm(_ id: ModelID) async
    func download(_ repoID: String) -> AsyncThrowingStream<DownloadEvent, any Error>
    func cancelDownload(_ repoID: String)
    func validate(_ repoID: String) async throws -> PreflightResult
    func capabilityProbe(_ id: ModelID) async -> ModelCapabilityReport
    func remove(_ id: ModelID) throws
    func unloadResident(_ id: ModelID, reason: String = "idleTimeout") async
    func unloadAllResident(reason: String = "idleTimeout") async
    // model pairing — runtime-changeable, re-applied on
    // every makeSession call for the paired base repo id
    func pairDraftModel(_ spec: SpeculativeDecodingSpec?, with baseRepoID: String)   // speed helper; nil clears
    func pairAdapter(_ spec: AdapterSpec?, with baseRepoID: String)                  // specialization patch; nil clears
    // pins, updates, cleanup
    func effectivePin(for repoID: String) -> MLXPin?          // pin in force + its source
    func buildTimePin(for repoID: String) -> String?          // the pin this build shipped, if any
    func checkPinUpdate(_ repoID: String, to revision: String? = nil) async throws -> MLXPinUpdateCheck   // downloads nothing
    func updatePin(_ repoID: String, to revision: String? = nil,
                   beforeSwitch: (@Sendable () async throws -> Void)? = nil) -> AsyncThrowingStream<DownloadEvent, any Error>
    func updatePins(_ updates: [String: String],
                    beforeSwitch: (@Sendable () async throws -> Void)? = nil) -> AsyncThrowingStream<DownloadEvent, any Error>   // all-or-nothing
    func snapshots(for repoID: String) -> [MLXCachedSnapshot]                     // cached versions, exclusive vs shared bytes
    func removeSnapshot(_ repoID: String, revision: String) throws -> Int64       // refuses the current version; returns bytes freed
}
struct MLXPreflightLimits: Sendable, Equatable {
    var maxWeightFractionOfRAM: Double     // default 0.7 — also the combined base+draft ceiling for a speed-helper pairing
    init(maxWeightFractionOfRAM: Double = 0.7)
}

// --- model pairing (LocalLMLabSDKInference) ---------
// "Speed helper": pairs a base model with a smaller, faster draft model that proposes several
// tokens ahead per round for the base model to verify in bulk — no change in output quality
// when it works. Measured on mlx-control-room: faster with a short draft (the default, 2), slower
// with a long one (5) — see the pairing notes above, and verify on your own setup.
struct SpeculativeDecodingSpec: Sendable, Equatable {
    var draftRepoID: String    // must share the base model's tokenizer/family, just much smaller
    var numDraftTokens: Int    // tokens proposed per round; default 2
    init(draftRepoID: String, numDraftTokens: Int = 2)
}
// "Specialization patch": pairs a base model with a LoRA/DoRA adapter that nudges its behavior
// (tone, vocabulary, a skill) without a whole second model. Applying an adapter mutates the
// model in place, so a paired session gets its own loaded copy of the base weights — separate
// from, and not evicted by, a plain unadapted session to the same repo.
enum AdapterSource: Sendable, Equatable {
    case huggingFace(repoID: String)   // repo with adapter_config.json + adapters.safetensors
    case directory(URL)                // same two files already on disk — no download
}
struct AdapterSpec: Sendable, Equatable {
    var source: AdapterSource
    init(source: AdapterSource)
}

// --- supply-chain hardening (LocalLMLabSDKInference) ----------------------
struct MLXSupplyChainPolicy: Sendable {
    var verification: MLXWeightVerification
    var trustPolicy: (any MLXModelTrustPolicy)?
    var cacheLimits: MLXCacheLimits
    init(verification: MLXWeightVerification = .default, trustPolicy: (any MLXModelTrustPolicy)? = nil,
         cacheLimits: MLXCacheLimits = .default)
    static let `default`: MLXSupplyChainPolicy
}
protocol MLXModelTrustPolicy: Sendable {
    func evaluate(repoID: String) async -> MLXModelTrustDecision
}
enum MLXModelTrustDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
}
enum MLXWeightVerification: Sendable, Equatable {
    case enabled     // default — verify every file's hash before caching it
    case disabled    // for a non-standard mirror whose ETags don't match a recognized shape
    static let `default`: MLXWeightVerification
}
struct MLXWeightVerificationError: Error, LocalizedError, Sendable {
    enum Reason: Sendable, Equatable {
        case hashMismatch(expected: String, computed: String)
        case unrecognizedETagShape(String)
    }
    var filename: String
    var reason: Reason
}
struct MLXCacheLimits: Sendable, Equatable {
    var maxTotalCacheBytes: Int64?   // nil (default) = unlimited; checks the WHOLE cache dir, not just this app's downloads
    init(maxTotalCacheBytes: Int64? = nil)
    static let `default`: MLXCacheLimits
}

// --- model identity + capability ------------------------------------------
struct ModelID: Hashable, Sendable, Codable, CustomStringConvertible, LosslessStringConvertible {
    let scheme: String        // token before the first ':' — [a-z][a-z0-9]*
    let rest: String          // after the first ':'; empty for bare ids
    var rawValue: String      // "scheme" or "scheme:rest"
    init?(_ raw: String)
    init?(scheme: String, rest: String = "")
    static let system: ModelID    // "system"
    static let pcc: ModelID       // "pcc"
}
enum ModelAvailability: Sendable, Equatable {
    case available
    case notDownloaded
    case needsCredential
    case unavailable(kind: UnavailableKind, detail: String)
    enum UnavailableKind: Sendable, Equatable {
        case ineligibleHardware, notEnabled, modelNotReady, unsupportedModel, providerError, noProvider
        case requiresOS(String)   // e.g. .requiresOS("macOS 27") — returned on macOS 26 for pcc/claude/mlx
    }
    var isAvailable: Bool { get }
}
struct ModelCapabilities: OptionSet, Sendable, Hashable, Codable {
    static let toolCalling: ModelCapabilities        // 1 << 0
    static let guidedGeneration: ModelCapabilities   // 1 << 1
    static let reasoningToggle: ModelCapabilities    // 1 << 2 — effort: .off actually suppresses this model's thinking
}
struct ModelCapabilityReport: Sendable, Equatable {
    var id: ModelID
    var capabilities: ModelCapabilities
    var notes: [String]
    var blocked: String?          // non-nil = the model downloaded but can't run at all (load error, image-required VLM, empty output)
    var isUsable: Bool { get }
}
struct InstalledModel: Sendable, Hashable, Codable, Identifiable {
    var id: ModelID
    var repoID: String
    var resolvedRevision: String   // the immutable commit this download actually resolved to — persist it
                                    // yourself (not under the HF cache dir) to redownload the same content
                                    // later, e.g. after remove(_:) or the OS reclaiming space
    var capabilities: ModelCapabilities       // empty until capabilityProbe
    var sizeBytes: Int64?
    var contextTokens: Int?
    init(id: ModelID, repoID: String, resolvedRevision: String, capabilities: ModelCapabilities = [],
         sizeBytes: Int64? = nil, contextTokens: Int? = nil)
}
struct PreflightResult: Sendable, Equatable {
    enum Stage: String, Sendable, Codable { /* trustPolicy / repoReachable / mlxFormat / architectureSupported / sizeVsMemory / diskSpace / cacheQuota */ }
    var failedStage: Stage?       // nil = passed
    var detail: String?
    var weightBytes: Int64?
    var ramBytes: Int64?          // this Mac's physical memory, for the size check
    var passed: Bool { get }
    static let ok: PreflightResult
}

// --- routing + residency + events ----------------------------------------
struct RouteName: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    let rawValue: String
    init(_ rawValue: String); init(stringLiteral: String)
    static let heavy: RouteName   // "heavy"
    static let light: RouteName   // "light"
    static let local: RouteName   // "local"
}
enum ModelResidency: Sendable, Equatable, Codable { case lastUsedOnly; case keepWarm([RouteName]) }
enum ResidencyEvent: Sendable {
    case warmed(ModelID)
    case evicted(ModelID, reason: String)          // "capacity", "memoryPressure", …
    case loadProgress(ModelID, fraction: Double)
}

// --- session -------------------------------------------------------------
struct LocalLMLabSession: Sendable {
    let route: RouteName
    let modelID: ModelID
    var retryOnContextOverflow: RetryPolicy         // .disabled by default; set before respond()
    var turnContext: (@Sendable () -> String?)?    // sent ahead of every prompt (e.g. the date); not shown in hostTranscript
    var hostTranscript: HostTranscript { get }      // the conversation as a UI shows it (below)
    var languageModelSession: LanguageModelSession { get }   // Apple's session — the escape hatch; a turn run on it skips the SDK's turn handling ([Running a turn](sdk-guide.md#running-a-turn-and-when-to-use-languagemodelsession))
    var events: AsyncStream<SessionEvent> { get }
    var citations: [Citation] { get }               // web-search sources accumulated this session ([Online providers](remote-providers.md))
    func reconcileServerToolArtifacts()             // re-derive citations/events from the transcript after a manual edit
    var contextBudget: ContextBudget { get }
    func cancel()
    // Running a turn: hostTranscript, turnContext, widget context, MCP tool refresh, retryOnContextOverflow
    @discardableResult
    func respond(to prompt: String, options: SessionOptions = .init(),      // per-call options: on-device model only
                 fromAppInstance instance: String? = nil) async throws -> String   // instance: a message an MCP App view sent
    func streamResponse(to prompt: String, options: SessionOptions = .init(),
                        fromAppInstance instance: String? = nil) -> AsyncThrowingStream<String, any Error>   // the reply so far
    // Outside the model's loop (MCP App views, your app): same authorizer, recorded in hostTranscript
    @MainActor func callMCPTool(server: MCPServerID, tool: String, arguments: [String: MCPValue],
                                initiator: ToolCallInitiator) async -> Result<MCPToolResult, MCPServerError>
    @MainActor func updateModelContext(_ text: String, fromAppInstance instance: String)   // sent with the next turn
}

@MainActor @Observable final class HostTranscript {
    var entries: [Entry] { get }                    // in model order; append-only
    var replyInProgress: ReplyInProgress? { get }   // while streamResponse runs
    var toolCalls: [ToolCallRecord] { get }
    func toolCall(id: String) -> ToolCallRecord?
    func appOnlyCallCount(for instance: String) -> Int   // an MCP App view's calls to app-only tools (not recorded)
    var resultMemoryBudget: Int                     // bytes of full MCP results kept in memory (8 MB); the rest spill to disk
    var spillDirectory: URL?                        // nil: a temp directory the SDK deletes
    func archive() throws -> Data                   // what the user saw, incl. full results
    func restore(from data: Data) throws            // into an empty transcript; ArchiveError otherwise
    struct Entry: Identifiable, Sendable {
        let id: String; var content: Content; let turn: Int
        var appInstance: String?                     // set when an MCP App view sent it
        enum Content: Sendable {                     // non-frozen: switch with @unknown default
            case user(String), assistant(String), reasoning(String)   // an inline <think> block becomes .reasoning
            case toolCall(ToolCallRecord)
            case appContext(instance: String, text: String)
        }
    }
    struct ReplyInProgress: Sendable, Equatable { var reasoning: String?; var text: String; var isReasoning: Bool }
    enum ArchiveError: Error, Equatable { case notEmpty, unsupportedFormat(String) }
}
struct ToolCallRecord: Identifiable, Sendable {
    let id: String                       // same as the SessionEvent id
    var modelCallID: String?             // the model's own call id, when the model made the call
    let tool: ToolReference              // .mcp(server:tool:) | .host(name:) | .provider(ServerToolActivity)
    let initiator: ToolCallInitiator     // .model | .app(instance:) | .host
    let arguments: GeneratedContent?; let argumentsDescription: String
    var state: State                     // .awaitingApproval | .running | .finished | .failed(reason:) | .denied(reason:)
    var output: String?                  // what the model saw
    var mcpResult: MCPToolResult? { get }   // the full result (read back from disk if spilled)
    let app: MCPAppLink?                 // the tool's MCP App view, if any
    let toolDescriptor: MCPToolDescriptor?
    let startedAt: Date; var finishedAt: Date?
}
enum SessionEvent: Sendable {
    case modelLoadProgress(fraction: Double)
    case routeSwitched(ModelID)
    case contextCompacted(removedEntries: Int)
    case toolCallStarted(id: String, name: String, arguments: String)
    case toolCallFinished(id: String, name: String, failed: Bool, resultSummary: String?)
    case serverToolCall(ServerToolActivity)         // provider-run web search/fetch — [Online providers](remote-providers.md)
}

// --- per-query options + the web-search side channel ([Online providers](remote-providers.md)) ---------------
struct SessionOptions: Sendable, Equatable {
    var webSearch: Bool = false
    var webSearchMaxUses: Int? = nil
    var webSearchAllowedDomains: [String] = []
    var webSearchBlockedDomains: [String] = []
    var effort: Effort? = nil            // reasoning level; nil = provider default ([The model layer](sdk-guide.md#the-model-layer-models-routing-and-sessions) "options: SessionOptions")
    var temperature: Double? = nil       // MLX, Apple on-device (0 = greedy), remote; not PCC
    var topP: Double? = nil              // MLX, Apple on-device (exclusive with topK there), remote
    var maxOutputTokens: Int? = nil
    var userLocation: UserLocation? = nil   // for web-search localisation
    var seed: UInt64? = nil              // MLX + Apple on-device (needs topK/topP there) — sampler seed; best-effort on Apple
    var topK: Int? = nil                 // MLX + Apple on-device (exclusive with topP there) — top-k sampling
    var minP: Double? = nil              // MLX only — min-p sampling threshold
    var repetitionPenalty: Double? = nil // MLX only — nil = disabled; the loop/repeat fix
    var repetitionContextSize: Int? = nil  // MLX only — how far back repetitionPenalty looks
    var prefillStepSize: Int? = nil      // MLX only — prompt-prefill chunk size; affects time-to-first-token, not output text
    init(webSearch: Bool = false, webSearchMaxUses: Int? = nil, webSearchAllowedDomains: [String] = [],
         webSearchBlockedDomains: [String] = [], effort: Effort? = nil, temperature: Double? = nil,
         topP: Double? = nil, maxOutputTokens: Int? = nil, userLocation: UserLocation? = nil,
         seed: UInt64? = nil, topK: Int? = nil, minP: Double? = nil, repetitionPenalty: Double? = nil,
         repetitionContextSize: Int? = nil, prefillStepSize: Int? = nil)
    var serverTools: Set<ServerTool> { get }        // derived from webSearch/webSearchMaxUses/etc.
    func merged(onto base: SessionOptions) -> SessionOptions   // per-call wins; nil falls through to base
    func appleGenerationOptions() throws -> GenerationOptions  // the Apple on-device mapping; throws SessionOptionsError
}
/// Thrown by `makeSession` / `respond` / `appleGenerationOptions()` for an option combination Apple's
/// on-device model can't honour, instead of dropping a knob silently.
enum SessionOptionsError: Error, LocalizedError, Equatable {
    case topKAndTopPBothSet                         // Apple's sampler takes top-K or top-P, not both
    case seedRequiresTopKOrTopP                     // a seed only exists inside a random sampling mode
    case invalidValue(field: String, detail: String)
    case perCallOptionsUnsupported(model: String)   // respond(to:options:) on a non-`system` session
}
/// Reasoning/thinking effort, ordered off → max. `.off` is a real guarantee only on the local MLX
/// tier — it suppresses the `<think>` block for toggle-capable chat templates (Qwen3 and its
/// siblings). `.off` never throws: a model that always reasons (DeepSeek-R1 and its distills)
/// just keeps reasoning instead of failing the turn — it's a best-effort preference, not a
/// requirement. Check `ModelCapabilities.reasoningToggle` (from `capabilityProbe(_:)`) ahead of
/// time if you need to know whether `.off` will actually suppress a given model's output. Remote
/// providers (OpenAI/Claude online/OpenRouter) and Apple on-device/PCC have no true "off" switch
/// and treat `.off` as `nil` (provider default) — to minimize reasoning on those, pass `.low`.
enum Effort: String, Sendable, Hashable, CaseIterable, Codable { case off, low, medium, high, xhigh, max }
struct UserLocation: Sendable, Equatable, Codable {
    var city: String?; var region: String?; var country: String?; var timezone: String?
    init(city: String? = nil, region: String? = nil, country: String? = nil, timezone: String? = nil)
}
enum ServerTool: Sendable, Hashable {     // provider-executed, distinct from a client Tool
    case webSearch(maxUses: Int? = nil, allowedDomains: [String] = [], blockedDomains: [String] = [])
    case webFetch
}
struct ServerToolActivity: Sendable, Equatable, Identifiable {
    let id: String
    var kind: Kind
    enum Kind: Sendable, Equatable {
        case webSearch(queries: [String], hits: [WebHit])
        case webFetch(url: String)
    }
}
struct WebHit: Sendable, Equatable, Codable { var url: String; var title: String; var snippet: String? }
struct Citation: Sendable, Equatable, Codable, Identifiable {
    var id: String; var url: String; var title: String; var citedText: String?
}
/// What `RemoteModelProvider.turnArtifacts(in:)` (and Claude's provider) extract from a turn's
/// transcript metadata — how `session.citations` and `.serverToolCall` events get populated.
/// Most callers read `session.citations` / the event stream instead of this directly.
struct TurnArtifacts: Sendable, Equatable {
    var serverToolActivities: [ServerToolActivity] = []
    var citations: [Citation] = []
    static let none: TurnArtifacts
}
struct RetryPolicy: Sendable {
    var maxRetries: Int                                          // 0 disables
    var compact: (@Sendable (Transcript) -> Transcript)?
    init(maxRetries: Int = 0, compact: (@Sendable (Transcript) -> Transcript)? = nil)
    static let disabled: RetryPolicy
}
struct ContextBudget: Sendable, Equatable {
    let windowTokens: Int?          // nil for arbitrary downloaded weights
    let lastInputTokens: Int
    let lastOutputTokens: Int
    var fractionUsed: Double?
    static func windowHint(for id: ModelID) -> Int?
}
enum LocalLMLabError: Error, LocalizedError {   // the one public error type the model layer throws
    case modelUnavailable(reason: String)
    case download(stage: String, underlying: (any Error)?)
    case validation(stage: PreflightResult.Stage, detail: String)
    case generation(underlying: any Error)      // wrap; use GenerationErrorDescription.describe for the message
    case context(detail: String)
    case mcp(detail: String)
    case connector(detail: String)
}
enum LocalLMLabSDKVersion { static let current: String }   // "1.0.0-beta.N", "1.0.0" at GA
```

`MLXModelProvider` / `MLXPreflightLimits` are in **`LocalLMLabSDKInference`**,
`ClaudeModelProvider` / `ClaudeModelSpec` in **`LocalLMLabSDKClaude`**, and
`RemoteModelProvider` / `RemoteProviderConfig` / `RemoteError` in **`LocalLMLabSDKRemote`** (each
a separate xcframework on the same release — [Targeting macOS 26 and 27](sdk-guide.md#targeting-macos-26-and-macos-27-from-one-build), [Online providers](remote-providers.md)); `ModelPickerView` / `ClaudeAuthField` /
`AIModelsSettingsView` are in **`LocalLMLabSDKComponents`** ([Components](sdk-guide.md#components-prebuilt-swiftui-mcp-servers--the-model-layer)).

## Decision models (`lab.decide`, OpenJev, hosted Jev)

Walkthrough: [Decision models](decision-models.md). Core unless marked; `OpenJev*` is
**`LocalLMLabSDKInference`** (macOS 27), `Jev*` is **`LocalLMLabSDKRemote`**.

```swift
// --- asking -----------------------------------------------------------------
extension LocalLMLab {
    func decide(route: RouteName, state: DecisionState, questions: [DecisionQuestion]) async throws -> Decision
    func evaluate(route: RouteName, questions: [DecisionQuestion], answerSet: DecisionAnswerSet,
                  progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> DecisionEvaluation
}
struct DecisionQuestion: Sendable, Hashable, Codable {     // Codable as Jev's {id, type, instructions, criteria}
    enum Kind { case noul, choice(criteria: [Criterion]), score(levels: [String]) }
    struct Criterion { var key: String; var description: String?; init(_ key: String, _ description: String? = nil) }
    var id: String; var instructions: String; var kind: Kind
    static func noul(_ id: String, _ instructions: String) -> DecisionQuestion
    static func choice(_ id: String, _ instructions: String, criteria: KeyValuePairs<String, String>) -> DecisionQuestion
    static func choice(_ id: String, _ instructions: String, criteria: [String]) -> DecisionQuestion
    static func score(_ id: String, _ instructions: String, criteria: [String]) -> DecisionQuestion
}
enum DecisionState { case text(String), json(String); static func encoding<T: Encodable>(_ value: T) throws -> DecisionState }
struct DecisionRequest { var state: DecisionState; var questions: [DecisionQuestion]; func validate(against: DecisionLimits = .jev) throws }
struct DecisionLimits { var maxQuestions, maxChoiceCriteria, maxScoreLevels: Int; var maxStateCharacters: Int?; static let jev }

// --- answers ----------------------------------------------------------------
struct Decision: Sendable, Hashable, Codable {
    var answers: [String: DecisionAnswer]
    var modelID: ModelID; var fidelity: DecisionFidelity; var latency: Duration; var usage: DecisionUsage?
    func noul(_ id: String) -> Double?            // P(yes)
    func choice(_ id: String) -> ChoiceAnswer?
    func score(_ id: String) -> ScoreAnswer?
}
enum DecisionAnswer { case noul(Double), choice(ChoiceAnswer), score(ScoreAnswer) }
struct ChoiceAnswer { var choice: String; var confidence: Double; var probabilities: [String: Double] }
struct ScoreAnswer { var score: Double; var confidence: Double; var probabilities: [Double]; var legend: [String]; var level: Int }
enum DecisionFidelity { case native, tokenScored(calibrated: Bool) }
struct DecisionUsage { var inputTokens: Int?; var outputTokens: Int?; var cost: Double? }
enum DecisionError: Error { case invalidRequest(String), noRoute(RouteName), unavailable(ModelID, ModelAvailability),
                            malformedAnswer(String), backend(String), pairing(String) }

// --- providers and routes ---------------------------------------------------
protocol DecisionProvider: Sendable {               // implement your own backend
    var scheme: String { get }
    var limits: DecisionLimits { get }               // default: .jev
    func fidelity(for id: ModelID) -> DecisionFidelity
    func availability(for id: ModelID) -> ModelAvailability
    func decide(_ request: DecisionRequest, using id: ModelID) async throws -> Decision
    func owns(_ id: ModelID) -> Bool                 // default: id.scheme == scheme
    func prewarm(_ id: ModelID) async                // default: nothing
}
extension ModelRegistry {
    func register(decision: any DecisionProvider) throws; func replace(decision: any DecisionProvider)
    func removeDecisionProvider(scheme: String)
    func route(decision: RouteName, to: ModelID); func modelID(forDecision: RouteName) -> ModelID?
    func decisionProvider(for: ModelID) -> (any DecisionProvider)?; func decisionAvailability(for: ModelID) -> ModelAvailability
    func pair(decision: RouteName, generator: RouteName) async throws -> DecisionPairing
}
struct DecisionPairing { var decider, generator: ModelID; var deciderBytes, generatorBytes, budgetBytes: Int64?
                         var residentModels: Int; var note: String? }
protocol PairableDecisionProvider: DecisionProvider { /* a local decider that can stay resident with a generator */ }

// --- OpenJev (LocalLMLabSDKInference, macOS 27) --------------------------------
struct OpenJevDecisionProvider: PairableDecisionProvider {     // scheme "openjev"; limits 64 questions, 26 options, 10 levels
    init(mlx: MLXModelProvider, wrapper: OpenJevWrapper = .default, calibration: DecisionCalibration? = nil, scheme: String = "openjev")
    init(mlx: MLXModelProvider, tunedWith set: DecisionQuestionSet, scheme: String = "openjev")
    let wrapper: OpenJevWrapper; let calibration: DecisionCalibration?; let tuning: DecisionQuestionSet.Tuning?
    func warnings(for id: ModelID) -> [OpenJevWarning]          // .mixtureOfExperts
    func tuningMismatch(for id: ModelID) -> String?             // not the model / revision the set was tested with
    func decideWithDiagnostics(_ request: DecisionRequest, using id: ModelID) async throws -> (decision: Decision, diagnostics: OpenJevDiagnostics)
}
struct OpenJevWrapper { var system: String; var inputLabel: String; static let `default` }
struct OpenJevDiagnostics { let questions: [String: Question]; let sharedPrefixTokens: Int }   // Question: labels, prompt, labelMass, latency

// --- hosted Jev (LocalLMLabSDKRemote) -------------------------------------------
struct JevDecisionProvider: DecisionProvider { init(_ config: JevProviderConfig) }
struct JevProviderConfig {   // scheme, displayName, endpoint, auth, models, allowArbitraryModelIDs, fidelity, limits, responseLimits, timeout
    static func openRouter(key: String) -> JevProviderConfig     // TypeSafe Jev, .native
    static func featherless(key: String) -> JevProviderConfig    // .tokenScored(calibrated: false)
    static func featherlessDemo() -> JevProviderConfig           // no key, rate-limited, maxStateCharacters 6000
    func validated() throws -> JevProviderConfig
}

// --- hosted Jev's wire format (both directions; a server can answer the same API) ---
enum JevWire {
    struct Request { var model: String?; var request: DecisionRequest }
    struct Response { var model: String?; var answers: [String: DecisionAnswer]; var usage: DecisionUsage?
                      var fidelity: DecisionFidelity?; var errorMessage: String? }
    static func encodeRequest(_ request: DecisionRequest, model: String) throws -> Data
    static func decodeRequest(_ data: Data) throws -> Request            // order-preserving
    static func encodeResponse(_ decision: Decision, model: String, request: DecisionRequest) throws -> Data
    static func decodeResponse(_ data: Data, request: DecisionRequest) throws -> Response
    static func encodeError(message: String, type: String, code: Int) -> Data
    static func errorMessage(in data: Data) -> String?
}

// --- calibration, question sets, answer sets, evaluation ---------------------------
struct DecisionCalibration: Codable {
    var noulTemperature, choiceTemperature, scoreTemperature: Double; static let none
    struct Sample { var kind: Kind; var probabilities: [Double]; var correct: [Int] }   // Kind: .noul, .choice, .score
    struct Measurement { var count: Int; var accuracy, expectedCalibrationError, logLoss: Double }
    static func fit(_ samples: [Sample]) -> DecisionCalibration
    func measure(_ samples: [Sample]) -> Measurement
    func apply(_ probabilities: [Double], kind: Sample.Kind) -> [Double]
}
struct DecisionQuestionSet: Codable {                   // JevDK's "Export Questions…"
    static let currentFormat: Int
    var format: Int; var name: String; var questions: [DecisionQuestion]; var tuning: Tuning?
    struct Tuning { var model: ModelID?; var revision, system, inputLabel: String?; var calibration: DecisionCalibration?; var testedAt: Date? }
    init(name: String, questions: [DecisionQuestion], tuning: Tuning? = nil)
    init(contentsOf url: URL) throws; init(json: Data) throws; func jsonData() throws -> Data
}
struct DecisionAnswerSet: Codable {                     // CSV: input, then one column per question id
    struct Example { var input: String; var answers: [String: String] }
    var examples: [Example]
    init(csv: String) throws; func csv(questionIDs: [String]) -> String
    func problems(for questions: [DecisionQuestion]) -> [String]
    static func answerKey(_ raw: String, for q: DecisionQuestion) -> String?
}
struct DecisionEvaluation {
    var modelID: ModelID; var fidelity: DecisionFidelity; var questions: [QuestionScore]; var misses: [Miss]
    var samples: [DecisionCalibration.Sample]; var decisions: Int; var totalLatency: Duration
    var accuracy: Double; var calibration: DecisionCalibration.Measurement
    func score(_ questionID: String) -> QuestionScore?   // marked, correct, accuracy, meanConfidenceWhenRight / WhenWrong
}
```

## Tool authority (`ToolCallAuthorizer`, `ToolImpact`, confirmation)

The two levers from [Tool authorization](sdk-guide.md#tool-authorization-two-levers--which-tools-and-whether-they-ask-first), as types. Everything here is in `LocalLMLabSDKCore` except the last
two, in `LocalLMLabSDKComponents`.

```swift
// --- lever 1: selection --------------------------------------------------
extension Sequence where Element == any Tool {
    func limited(toMaxImpact ceiling: ToolImpact) -> [any Tool]   // drops tools above ceiling; unrated = .mutate
}
protocol ImpactRatedTool: Tool { var impact: ToolImpact { get } }   // every ready-made SDK tool conforms
enum ToolImpact: Int, Sendable, Codable, Comparable, CaseIterable { case read, mutate, destructive }
protocol OriginTaggedTool: Tool { var toolOrigin: ToolOrigin { get } }   // a host's own MCP-backed Tool conforms to keep .mcp origin

// --- lever 2: invocation --------------------------------------------------
protocol ToolCallAuthorizer: Sendable {
    func authorize(_ call: PendingToolCall) async -> ToolCallDecision
}
enum ToolCallDecision: Sendable {
    case allow
    case deny(reason: String)   // -> the model sees tool result "DENIED: <reason>" (String-output tools)
}
struct PendingToolCall: Sendable {
    let toolName: String
    let arguments: GeneratedContent?       // structured; nil only for a rare third-party From-only Arguments
    let argumentsDescription: String       // always present
    let origin: ToolOrigin                 // .host | .mcp(server:displayName:)
    let impact: ToolImpact                 // MCP: .mutate unless the server is trusted (then its annotations)
    let initiator: ToolCallInitiator       // .model | .app(instance:) (an MCP App view) | .host
    let serverApproval: ToolApproval?      // MCP: the server's approval at call time, filled by the SDK; nil for your own tools
    init(toolName: String, arguments: GeneratedContent?, argumentsDescription: String, origin: ToolOrigin, impact: ToolImpact,
         initiator: ToolCallInitiator = .model, serverApproval: ToolApproval? = nil)
    var summary: PendingToolCallSummary { get }   // the Codable projection, for crossing a process boundary
}
struct PendingToolCallSummary: Codable, Sendable, Equatable {   // a missing initiator decodes as .model, serverApproval as nil
    let toolName: String; let argumentsDescription: String; let origin: ToolOrigin; let impact: ToolImpact
    let initiator: ToolCallInitiator; let serverApproval: ToolApproval?
    init(toolName: String, argumentsDescription: String, origin: ToolOrigin, impact: ToolImpact,
         initiator: ToolCallInitiator = .model, serverApproval: ToolApproval? = nil)
}
enum ToolOrigin: Sendable, Codable, Equatable { case host; case mcp(server: MCPServerID, displayName: String) }
enum ToolCallInitiator: Sendable, Hashable, Codable { case model; case app(instance: String); case host }

// --- per-server trust and approval (new in 2.0; set on lab.mcp — see "MCP client" below) ---
enum MCPServerTrust: String, Sendable, Codable, CaseIterable { case untrusted, trusted }   // trusted ⇒ annotations set impact
enum ToolApprover: String, Sendable, Codable { case user, policy }
enum ToolApproval: Sendable, Codable, Equatable {
    case allow                                            // every call runs
    case ask(atOrAbove: ToolImpact, by: ToolApprover)     // calls at/above the impact need authorization by `by`
    static func `default`(for trust: MCPServerTrust) -> ToolApproval   // untrusted: .ask(.mutate, .user); trusted: .ask(.destructive, .user)
}
typealias ToolPolicy = @Sendable (PendingToolCall) async -> ToolPolicyDecision   // your external authorization function
enum ToolPolicyDecision: Sendable, Equatable { case allow; case deny(reason: String); case askUser }

// makeSession(..., authorizer:) — [The reference](#full-functiontype-reference) "The model layer" — installs the gate; nil = unchanged, no gate.

protocol ToolConfirmationChannel: Sendable {   // the transport an "ask the user" decision suspends on
    func requestDecision(for call: PendingToolCall) async -> Bool
}
struct ConfirmingToolAuthorizer: ToolCallAuthorizer {   // the SDK's one authorizer
    // Per call: the MCP server's approval (call.serverApproval; nil ⇒ the untrusted default) or `hostTools`
    // for your own tools; below the threshold runs, .ask(by: .user) asks `channel`, .ask(by: .policy) asks
    // `policy` (which may hand it to the user). Fails closed: no channel / no policy / timeout / declined ⇒ deny.
    // A view's (initiator .app) answer is remembered per view, server and tool; .destructive and timeouts aren't.
    init(channel: (any ToolConfirmationChannel)?, policy: ToolPolicy? = nil,
         hostTools: ToolApproval = .ask(atOrAbove: .mutate, by: .user), timeout: Duration = .seconds(120))
}
final class DecisionGate: @unchecked Sendable {   // guards the resume-once race between a reply and the timeout
    init()
    func attach(_ continuation: CheckedContinuation<Bool, Never>)
    func resume(_ value: Bool)
}

// --- LocalLMLabSDKComponents: the reference ToolConfirmationChannel + SwiftUI sheet ---
final class ToolConfirmationPresenter: ObservableObject, ToolConfirmationChannel {
    init(fallbackTimeout: Duration = .seconds(120))
    func resolve(_ id: ToolConfirmationRequest.ID, allow: Bool)
}
struct ToolConfirmationRequest: Identifiable, Sendable { let id: UUID; let call: PendingToolCall }
// View.toolConfirmationSheet(_ presenter: ToolConfirmationPresenter) — attach once, near the root
```

## Connectors (Calendar, Reminders, Contacts, Location)

```swift
// Unified facade — permission lifecycle only, identical shape across all four
enum Connector: String, CaseIterable, Sendable { case calendar, reminders, contacts, location }
struct ConnectorAccessResult: Sendable { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
enum Connectors {
    static func isAuthorized(_ connector: Connector) -> Bool
    static func requestAccess(_ connector: Connector) async -> ConnectorAccessResult
    static func openSystemSettings(for connector: Connector)
}

// CalendarAccess
enum CalendarAccess {
    static var store: EKEventStore { get }  // raw EventKit store, for anything the wrapper below doesn't cover; refreshed internally after a fresh grant
    static var authorizationStatus: EKAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct EventSummary: Codable { var eventIdentifier: String; var title: String; var start: String; var end: String; var calendar: String; var location: String?; var isAllDay: Bool }
    static func upcomingEvents(days: Int) -> [EventSummary]
    struct AddEventResult { var success: Bool; var error: String? }
    static func addEvent(title: String, start: Date, end: Date) -> AddEventResult
    struct MutateEventResult { var success: Bool; var error: String? }
    // locates the event by title + the day it's currently on, not eventIdentifier; nil new* parameters leave that field unchanged
    static func updateEvent(title: String, onDate: DateComponents, newTitle: String?, newDate: DateComponents?, newTime: DateComponents?, durationMinutes: Int?) -> MutateEventResult
    static func deleteEvent(title: String, onDate: DateComponents) -> MutateEventResult
}

// RemindersAccess — same shape as CalendarAccess, also backed by EventKit (EKEventStore
// handles both calendar events and reminders)
enum RemindersAccess {
    static var store: EKEventStore { get }
    static var authorizationStatus: EKAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct ReminderSummary: Codable, Sendable { var calendarItemIdentifier: String; var title: String; var dueDate: String?; var list: String; var isCompleted: Bool; var priority: Int }
    static func upcomingReminders(days: Int) async -> [ReminderSummary]
    struct AddReminderResult { var success: Bool; var error: String? }
    static func addReminder(title: String, dueDateComponents: DateComponents?) -> AddReminderResult
    struct MutateReminderResult { var success: Bool; var error: String? }
    // locates the reminder by title, optionally narrowed by its current due date; nil new* parameters leave that field unchanged
    static func updateReminder(title: String, dueDate: DateComponents?, newTitle: String?, newDate: DateComponents?, newTime: DateComponents?, isCompleted: Bool?) async -> MutateReminderResult
    static func deleteReminder(title: String, dueDate: DateComponents?) async -> MutateReminderResult
}

// ContactsAccess
enum ContactsAccess {
    static var store: CNContactStore { get }  // raw Contacts store, for anything the wrapper below doesn't cover; refreshed internally after a fresh grant
    static var authorizationStatus: CNAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct ContactSummary: Codable { var identifier: String; var name: String; var givenName: String; var familyName: String?; var organization: String?; var phoneNumbers: [String]; var emails: [String] }
    static func search(query: String, limit: Int) -> [ContactSummary]
    static func list(limit: Int) -> [ContactSummary]
    struct MutateContactResult { var success: Bool; var error: String? }
    static func addContact(givenName: String, familyName: String, organization: String?, phoneNumbers: [String], emails: [String]) -> MutateContactResult
    // locates the contact by givenName, optionally narrowed by its current familyName; nil new* parameters leave that field unchanged, non-nil newPhoneNumbers/newEmails replace the contact's entire existing list
    static func updateContact(givenName: String, familyName: String?, newGivenName: String?, newFamilyName: String?, newOrganization: String?, newPhoneNumbers: [String]?, newEmails: [String]?) -> MutateContactResult
    static func deleteContact(givenName: String, familyName: String?) -> MutateContactResult
}

// LocationAccess — a class (LocationAccess.shared), not a static enum, since it holds
// CLLocationManagerDelegate state
final class LocationAccess {
    static let shared: LocationAccess
    var authorizationStatus: CLAuthorizationStatus { get }
    var isAuthorized: Bool { get }
    var lastFetchFailureReason: String? { get }
    struct AccessResult: Sendable { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct LocationSummary: Codable { var latitude: Double; var longitude: Double; var horizontalAccuracyMeters: Double; var timestamp: String; var placeName: String? }
    func currentLocation() async -> LocationSummary?
}
```

## Ready-made connector Tools (Path A)

Thin `Tool`-conforming wrappers around the connectors above — see [Two paths to tool-calling](sdk-guide.md#two-paths-to-tool-calling-ready-made-tools-or-write-your-own) (Path A vs Path B) for the framing. Each takes
an optional custom `description` at init, same pattern as `ClockTool`/`WeatherTool` below.

```swift
// Calendar
struct GetUpcomingEventsTool: Tool {
    let name = "getUpcomingEvents"
    init(description: String? = nil)
    struct Arguments { var days: Int? }             // defaults to 7, capped at 30
}
struct AddCalendarEventTool: Tool {
    let name = "addCalendarEvent"
    init(description: String? = nil)
    struct Arguments { var title: String; var date: String; var time: String; var durationMinutes: Int? }
}
struct UpdateCalendarEventTool: Tool {
    let name = "updateCalendarEvent"
    init(description: String? = nil)
    // currentDate locates the event; each new* field is independently optional
    struct Arguments { var title: String; var currentDate: String; var newTitle: String?; var newDate: String?; var newTime: String?; var durationMinutes: Int? }
}
struct DeleteCalendarEventTool: Tool {
    let name = "deleteCalendarEvent"
    init(description: String? = nil)
    struct Arguments { var title: String; var currentDate: String }
}

// Reminders — same title/currentDate/new* shape as Calendar; currentDate is optional here
// (a reminder may have no due date, unlike a Calendar event)
struct GetUpcomingRemindersTool: Tool {
    let name = "getUpcomingReminders"
    init(description: String? = nil)
    struct Arguments { var days: Int? }
}
struct AddReminderTool: Tool {
    let name = "addReminder"
    init(description: String? = nil)
    struct Arguments { var title: String; var date: String?; var time: String? }
}
struct UpdateReminderTool: Tool {
    let name = "updateReminder"
    init(description: String? = nil)
    struct Arguments { var title: String; var currentDate: String?; var newTitle: String?; var newDate: String?; var newTime: String?; var isCompleted: Bool? }
}
struct DeleteReminderTool: Tool {
    let name = "deleteReminder"
    init(description: String? = nil)
    struct Arguments { var title: String; var currentDate: String? }
}

// Contacts — currentGivenName/currentFamilyName locate the contact; each new* field is
// independently optional. newPhoneNumbers/newEmails, when provided, replace the entire list.
struct SearchContactsTool: Tool {
    let name = "searchContacts"
    init(description: String? = nil)
    struct Arguments { var query: String; var limit: Int? }  // defaults to 10, capped at 50
}
struct ListContactsTool: Tool {
    let name = "listContacts"
    init(description: String? = nil)
    struct Arguments { var limit: Int? }                     // defaults to 50, capped at 200
}
struct AddContactTool: Tool {
    let name = "addContact"
    init(description: String? = nil)
    struct Arguments { var givenName: String; var familyName: String?; var organization: String?; var phoneNumbers: [String]?; var emails: [String]? }
}
struct UpdateContactTool: Tool {
    let name = "updateContact"
    init(description: String? = nil)
    struct Arguments { var currentGivenName: String; var currentFamilyName: String?; var newGivenName: String?; var newFamilyName: String?; var newOrganization: String?; var newPhoneNumbers: [String]?; var newEmails: [String]? }
}
struct DeleteContactTool: Tool {
    let name = "deleteContact"
    init(description: String? = nil)
    struct Arguments { var currentGivenName: String; var currentFamilyName: String? }
}

// Location — the one connector Tool with no writable counterpart
struct GetCurrentLocationTool: Tool {
    let name = "getCurrentLocation"
    init(description: String? = nil)
    struct Arguments {}
}
```

## Filesystem workspace (`WorkspaceAccess`/`WorkspaceTools`)

Not a connector — no `requestAccess()`, no OS permission dialog. Operates on a root `URL` your
app already resolved via a security-scoped bookmark ([Filesystem access](sdk-guide.md#filesystem-access-security-scoped-bookmarks-example-not-in-core) — Filesystem access); the picker itself is the one-time
consent. `WorkspaceAccess` is the raw data layer; `WorkspaceTools` are the matching Path A `Tool`s,
each taking the resolved root `URL` at init.

```swift
enum WorkspaceAccess {
    struct WorkspaceError: Error { var message: String }
    struct WorkspaceEntry: Codable, Sendable { var name: String; var isDirectory: Bool; var modifiedDate: Date?; var size: Int? }
    struct SearchMatch: Codable, Sendable, Equatable { var path: String; var line: Int; var text: String }
    struct PatchResult: Codable, Sendable, Equatable {
        var changed: [String]; var created: [String]; var deleted: [String]; var hunksApplied: Int
    }

    static func listFiles(in root: URL, subpath: String?) -> Result<[WorkspaceEntry], WorkspaceError>
    static func readFile(in root: URL, path: String) -> Result<String, WorkspaceError>
    // create-by-default — fails on an existing file unless overwrite:true (or append:true to add to the end); use editFile for a partial change
    static func writeFile(in root: URL, path: String, contents: String, overwrite: Bool = false, append: Bool = false) -> Result<Void, WorkspaceError>
    // search-and-replace, not a unified-diff format — oldString must match exactly once unless replaceAll
    static func editFile(in root: URL, path: String, oldString: String, newString: String, replaceAll: Bool) -> Result<Void, WorkspaceError>
    static func deleteFile(in root: URL, path: String) -> Result<Void, WorkspaceError>
    // unified-diff patch, potentially touching several files under root in one call — behind ApplyPatchTool
    static func applyPatch(in root: URL, diff: String) -> Result<PatchResult, WorkspaceError>
    // plain-text or regex; behind SearchWorkspaceTool
    static func search(in root: URL, query: String, isRegex: Bool = false, include: String? = nil, maxResults: Int = 200) -> Result<[SearchMatch], WorkspaceError>
    // an indented directory listing; behind WorkspaceTreeTool
    static func tree(in root: URL, subpath: String? = nil, maxDepth: Int = 2) -> Result<String, WorkspaceError>
    // a byte/line window into a large file without reading it whole; behind ReadFileRangeTool
    static func readFileRange(in root: URL, path: String, offset: Int, limit: Int) -> Result<String, WorkspaceError>
}

struct ListWorkspaceFilesTool: Tool {
    let name = "listWorkspaceFiles"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String? }
}
struct ReadWorkspaceFileTool: Tool {
    let name = "readWorkspaceFile"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String }
}
struct WriteWorkspaceFileTool: Tool {
    let name = "writeWorkspaceFile"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String; var contents: String; var overwrite: Bool?; var append: Bool? }
}
struct EditWorkspaceFileTool: Tool {
    let name = "editWorkspaceFile"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String; var oldString: String; var newString: String; var replaceAll: Bool? }
}
// Not included in workspace-buddy's default tool list — see that example's README. Available
// here for a host app that explicitly wants a delete-capable coding assistant.
struct DeleteWorkspaceFileTool: Tool {
    let name = "deleteWorkspaceFile"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String }
}
struct SearchWorkspaceTool: Tool {
    let name = "searchWorkspace"
    init(root: URL, description: String? = nil)
    struct Arguments { var query: String; var isRegex: Bool?; var include: String? }
}
struct WorkspaceTreeTool: Tool {
    let name = "workspaceTree"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String?; var maxDepth: Int? }
}
struct ApplyPatchTool: Tool {
    let name = "applyPatch"
    init(root: URL, description: String? = nil)
    struct Arguments { var diff: String }
}
struct ReadFileRangeTool: Tool {
    let name = "readFileRange"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String; var offset: Int; var limit: Int }
}

// The "AIQL" data verbs — each init(root:description:), reads one workspace file, writes a CSV
// (see [File-backed tools](sdk-guide.md#filebackedtool--the-aiql-data-verbs-a-mechanical-mcp-dataset--csv-pipeline) for the full table and pipeline shape). CSVCodec + JSONPath are public building blocks.
struct JSONToCSVTool: Tool     { let name = "jsonToCsv" }      // SELECT cols FROM json_array
struct SelectColumnsTool: Tool { let name = "selectColumns" }  // SELECT a AS x, b
struct FilterRowsTool: Tool    { let name = "filterRows" }     // WHERE
struct SortRowsTool: Tool      { let name = "sortRows" }       // ORDER BY … LIMIT  (the mechanical "top N")
struct DedupeRowsTool: Tool    { let name = "dedupeRows" }     // SELECT DISTINCT
struct AggregateRowsTool: Tool { let name = "aggregateRows" }  // GROUP BY
struct ConcatRowsTool: Tool    { let name = "concatRows" }     // UNION ALL
struct DescribeJSONTool: Tool  { let name = "describeJson" }   // structure summary (read-only)
struct CSVInfoTool: Tool       { let name = "csvInfo" }        // row/column counts + samples (read-only)
struct LoadTableTool: Tool     { let name = "loadTable" }     // JSON records -> an ephemeral SQLite table
struct SQLQueryTool: Tool      { let name = "sqlQuery" }      // one read-only SELECT -> CSV

// Host-applied decorator: wraps a dynamic-schema tool, adds a root-level `saveAs` that writes the
// wrapped tool's raw result to a workspace file instead of returning it. [File-backed tools](sdk-guide.md#filebackedtool--the-aiql-data-verbs-a-mechanical-mcp-dataset--csv-pipeline).
struct FileBackedTool: Tool {
    typealias Arguments = GeneratedContent
    init(name: String, description: String, argumentsJSONSchema: Data, root: URL,
         previewCharacters: Int = 600, inlineCharacterLimit: Int? = nil,
         invoke: @escaping @Sendable (GeneratedContent) async -> String) throws
    static func mcp(descriptor: MCPToolDescriptor, manager: MCPServerManager, root: URL,
                    previewCharacters: Int = 600, inlineCharacterLimit: Int? = nil) throws -> FileBackedTool
}
```

## No-permission tools

```swift
struct ClockTool: Tool {
    static let defaultDescription: String
    init(description: String? = nil)
    // Arguments: zero properties — call() returns the current date/time as text
}

struct WeatherTool: Tool {
    static let defaultDescription: String
    init(description: String? = nil)
    struct Arguments { var location: String }
    // call() returns current conditions + 7-day forecast via Open-Meteo
}
```

## Error handling

```swift
enum GenerationErrorDescription {
    // Turns a LanguageModelSession.GenerationError into a readable, per-case explanation
    // (falls back to error.localizedDescription for any other error type). async because
    // .refusal's explanation is itself computed asynchronously by FoundationModels.
    static func describe(_ error: Error) async -> String
}
```

**A note on what's not listed above**: `@Generable` (Apple's FoundationModels macro, applied to every `Arguments` struct in this SDK and in your own tools) synthesizes additional public members on each one — a `PartiallyGenerated` nested type, `generationSchema`, `generatedContent`, and a few others. These are FoundationModels' own machinery for incremental/streaming generation, not SDK API — you'll never call them directly, only `@Generable`/`LanguageModelSession` do. Left out here deliberately, the same way compiler-synthesized `Codable`/`Hashable` methods (`init(from:)`, `encode(to:)`, `hash(into:)`) are left out of the reference types above — real public symbols, but noise for this list's purpose. If you inspect the compiled binary directly and see these, that's expected, not a sign this reference is out of date.

## MCP client

```swift
final class MCPServerManager {
    init(responseLimits: MCPResponseLimits = .default, handlers: MCPClientHandlers = .init(),
         versionNegotiation: MCPVersionNegotiation = .auto, liveUpdates: Bool = true)  // NOT a singleton
    private(set) var servers: [MCPServerID: MCPServerState] { get }
    var serverChanges: AsyncStream<[MCPServerID: MCPServerState]> { get }
    var estimatedTotalTokens: Int { get }

    func addServer(url: URL, displayName: String, authType: MCPAuthType = .none, patToken: String? = nil, manualClientID: String? = nil) async -> Result<MCPServerState, MCPServerError>
    func reconnect(_ id: MCPServerID) async -> Result<MCPServerState, MCPServerError>
    func disconnect(_ id: MCPServerID)
    func removeServer(_ id: MCPServerID)
    // drops every in-memory server without touching Keychain tokens — pair with restore(from:)
    // for a config-profile Load, where removeServer's per-server credential clear is the wrong call
    func removeAllKeepingCredentials()
    func acceptDrift(server: MCPServerID)   // the server's current tools become the accepted list; held tools are offered again
    func snapshot() -> [MCPServerSnapshot]   // every server, to save (Codable): cached tools, trust, approvals, exclusions, drift
    func restore(from snapshots: [MCPServerSnapshot])   // at the next launch, as disconnected entries with those settings; an ID already present is left alone

    func toolsForSession() -> [MCPToolDescriptor]
    func setToolEnabled(_ enabled: Bool, server: MCPServerID, tool: String)
    // Per-server trust and approval ([Tool authorization](sdk-guide.md#tool-authorization-two-levers--which-tools-and-whether-they-ask-first), new in 2.0).
    // Kept across reconnects, cleared by removeServer; not persisted — save the state's trust / toolApproval and set them again after restore.
    func setTrust(_ trust: MCPServerTrust, server: MCPServerID)                // .trusted ⇒ its annotations set each tool's impact
    func setToolApproval(_ approval: ToolApproval?, server: MCPServerID)       // nil ⇒ ToolApproval.default(for: trust)
    func setToolApproval(_ approval: ToolApproval?, server: MCPServerID, tool: String)  // one tool, over the server's approval; nil ⇒ the server's
    func toolApproval(server: MCPServerID) -> ToolApproval                     // the effective approval, read on every call
    // -> MCPToolResult ([MCP tool results](mcp-guide.md#what-a-tool-call-gives-you-back-mcptoolresult)), not a String. A tool that ran but failed is .success with isError == true.
    // allowElicitation: false on a code path that can't show a prompt (headless / background).
    func callTool(server: MCPServerID, tool: String, arguments: [String: MCPValue], allowElicitation: Bool = true) async -> Result<MCPToolResult, MCPServerError>

    func resourcesForSession() -> [MCPResourceDescriptor]
    func resourceTemplatesForSession() -> [MCPResourceTemplateDescriptor]
    func setResourceEnabled(server: MCPServerID, uri: String, enabled: Bool)
    func readResource(server: MCPServerID, uri: String) async -> Result<MCPResourceContent, MCPServerError>

    func promptsForSession() -> [MCPPromptDescriptor]
    func getPrompt(server: MCPServerID, name: String, arguments: [String: String]) async -> Result<[MCPPromptMessage], MCPServerError>
}

struct MCPServerID: Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String)
}

struct MCPServerState: Codable, Sendable {
    var id: MCPServerID
    var url: URL
    var displayName: String
    var connectionStatus: MCPConnectionStatus
    var tools: [MCPToolDescriptor]
    var estimatedTokens: Int
    var enabled: Bool
    var authType: MCPAuthType
    var patTokenLastFour: String?       // masked display only, never the real token
    var manualClientID: String?
    var resources: [MCPResourceDescriptor]
    var resourceTemplates: [MCPResourceTemplateDescriptor]
    var prompts: [MCPPromptDescriptor]
    var negotiatedProtocolVersion: MCPProtocolVersion?   // nil until connected ([MCP revisions](mcp-guide.md#which-mcp-revision-the-client-speaks--and-why-you-mostly-dont-have-to-care))
    var serverInstructions: String?                       // server's own usage note (initialize or server/discover)
    var liveUpdates: MCPLiveUpdates?                      // stateless servers only; nil otherwise ([MCP revisions](mcp-guide.md#which-mcp-revision-the-client-speaks--and-why-you-mostly-dont-have-to-care))
    var trust: MCPServerTrust                             // setTrust (default .untrusted)
    var toolApproval: ToolApproval?                       // setToolApproval's value; nil = default for the trust level
    var trustedToolsDigest: String?                       // the tool list when last trusted
    var pendingDrift: ToolDrift?                          // tool changes since the accepted list that the drift policy didn't accept — show for review, then acceptDrift(server:)
    func exportSummary() -> String      // plain-text listing of tools/resources/prompts, enabled state, token cost
}

enum MCPProtocolVersion: String, CaseIterable, Comparable, Sendable, Codable {
    @available(*, deprecated) case v2024_11_05 = "2024-11-05"   // no longer negotiated; kept so stored values decode
    case v2025_03_26 = "2025-03-26", v2025_06_18 = "2025-06-18"
    case v2025_11_25 = "2025-11-25", v2026_07_28 = "2026-07-28"
    static let clientPreferred: MCPProtocolVersion = .v2025_11_25      // offered at initialize (handshake era)
    static let statelessPreferred: MCPProtocolVersion = .v2026_07_28   // probed with server/discover
    static let minimumSupported: MCPProtocolVersion = .v2025_03_26     // lower → .protocolMismatch
    var isStateless: Bool { get }                         // >= 2026-07-28
    var supportsStructuredContent: Bool { get }           // >= 2025-06-18
    var supportsElicitation: Bool { get }                 // >= 2025-06-18
    var supportsIconsAndRicherElicitation: Bool { get }   // >= 2025-11-25
    var supportsURLElicitation: Bool { get }              // >= 2025-11-25
    var sendsProtocolVersionHeader: Bool { get }          // >= 2025-06-18
}

// How connect() chooses between the stateless and handshake models (mirrors the TS SDK's option).
enum MCPVersionNegotiation: Sendable, Equatable {
    case auto                       // default: server/discover, fall back to initialize
    case legacy                     // initialize only
    case pin(MCPProtocolVersion)    // stateless at this revision, no fallback
}

// Live updates (2026-07-28 subscriptions/listen). The manager runs these for you; read
// MCPServerState.liveUpdates for status. Opt out with MCPServerManager(liveUpdates: false).
enum MCPLiveUpdates: Sendable, Codable, Equatable {
    case active(MCPSubscriptionFilter)   // listening; what the server granted
    case reconnecting                    // stream dropped, retrying with backoff
    case unavailable(String)             // refused or sign-in expired; resumes on next connect
}
struct MCPSubscriptionFilter: Sendable, Codable, Equatable {
    var toolsListChanged: Bool; var promptsListChanged: Bool; var resourcesListChanged: Bool
}

enum MCPAuthType: String, Codable, Sendable { case none, pat, oauthManual }
enum MCPConnectionStatus: String, Codable, Sendable { case connected, disconnected, connecting, failed }
// MCPConnectionStatus and MCPServerError are non-frozen (1.0) — an exhaustive switch needs
// `@unknown default`. This is the only source-break for an MCP-only 0.8.x consumer; see
// migrating-to-1.0.md.

struct MCPToolDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var name: String             // model-facing identifier
    var description: String
    var rawSchema: Data          // the tool's real JSON schema — inspect before assuming params
    var estimatedTokens: Int
    var enabled: Bool            // defaults to false for newly-discovered tools
    var title: String?           // human display name for UI (2025-06-18+); fall back to name
    var outputSchema: Data?      // declared shape of structuredContent, if any (2025-06-18+)
    var meta: MCPValue?          // the tool's _meta
    var annotations: MCPToolAnnotations?   // readOnlyHint / destructiveHint …: the server's claim (believed only for a trusted server)
    var app: MCPAppLink? { get }           // its MCP App view (_meta.ui.resourceUri), if any
    var isModelVisible: Bool { get }       // false for app-only tools: never offered to a model
}
struct MCPAppLink: Sendable, Equatable, Hashable { var resourceURI: String; var visibility: Set<MCPAppVisibility> }
enum MCPAppVisibility: String, Sendable, Codable, CaseIterable { case model, app }
struct MCPToolAnnotations: Codable, Sendable, Equatable {
    var title: String?; var readOnlyHint: Bool?; var destructiveHint: Bool?; var idempotentHint: Bool?; var openWorldHint: Bool?
}

struct MCPResourceDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var uri: String
    var name: String
    var description: String
    var mimeType: String?
    var enabled: Bool            // defaults to true
    var meta: MCPValue?
    var isMCPAppResource: Bool { get }   // a ui:// view's HTML: left out of model-facing resource lists
}

struct MCPResourceTemplateDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var uriTemplate: String      // e.g. "res://{id}" — resolve placeholders yourself before reading
    var name: String
    var description: String
    var mimeType: String?
}

struct MCPResourceContent: Codable, Sendable {
    var uri: String
    var mimeType: String?
    var text: String?            // exactly one of text/blob is non-nil, per MCP spec
    var blob: String?
}

struct MCPPromptArgument: Codable, Sendable { var name: String; var description: String; var required: Bool }
struct MCPPromptDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var name: String
    var description: String
    var arguments: [MCPPromptArgument]
}
struct MCPPromptMessage: Codable, Sendable { var role: String; var text: String }

indirect enum MCPValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), array([MCPValue]), object([String: MCPValue]), null
    func strippingEmpty() -> MCPValue?      // drop ""/[]/null and objects that collapse — the
                                            // "did the user/model actually supply this?" rule
}

// What callTool gives you back ([MCP tool results](mcp-guide.md#what-a-tool-call-gives-you-back-mcptoolresult)).
struct MCPToolResult: Sendable, Codable, Equatable {
    var text: String
    var structuredContent: MCPValue?        // JSON the server marked structured; validated vs outputSchema
    var resourceLinks: [MCPResourceLink]
    var isError: Bool                        // the tool ran and reported failure
    var truncated: Bool                      // response hit MCPResponseLimits
    var meta: MCPValue?                      // the result's _meta
    var renderedForModel: String { get }     // compact, context-sized rendering folding in all of the above
}
struct MCPResourceLink: Sendable, Codable, Equatable {
    var uri: String; var name: String?; var title: String?; var description: String?; var mimeType: String?
}

enum MCPServerError: Error, Codable, Sendable {
    case unreachable
    case malformedResponse
    case protocolMismatch
    case notConnected
    case toolNotFound
    case serverError(String)                // includes real HTTP status/URL/body where available
    case authorizationRequired               // OAuth flow needed and didn't complete
    case credentialRejected                  // PAT rejected — no retry path but a new token
    case httpError(Int)
    case oauthRegistrationNotSupported       // no DCR — retry with .oauthManual + manualClientID
    case responseTooLarge(String)            // server response exceeded MCPResponseLimits
}
```

**Server-initiated request handlers** ([Server-initiated requests](mcp-guide.md#server-initiated-requests-elicitation-and-the-sampling--roots-seams)) — all optional; a capability is advertised to a
server only when its handler is non-nil:

```swift
struct MCPClientHandlers: Sendable {
    init(elicitation: (any MCPElicitationHandler)? = nil,
         sampling:    (any MCPSamplingHandler)?    = nil,
         roots:       (any MCPRootsProvider)?      = nil,
         logging:     (any MCPLoggingSink)?        = nil,
         extensions:  [String: MCPValue]           = [:])   // client capability extensions declared at initialize
    var extensions: [String: MCPValue]
}
// LocalLMLabSDKMCPAppsHost: MCPClientHandlers().advertisingMCPApps() — declares MCP Apps support
// (extensions["io.modelcontextprotocol/ui"]), which servers check before offering views.

protocol MCPElicitationHandler: Sendable {
    func handleElicitation(_ request: MCPElicitationRequest) async -> MCPElicitationResponse
}
struct MCPElicitationRequest: Sendable, Equatable {
    var message: String
    var rawSchema: Data                       // the raw requestedSchema, for custom rendering
    var fields: [MCPElicitationField]         // flattened: string(format)/number/integer/boolean/enum
    var url: URL?                             // URL-mode elicitation (2025-11-25)
    var serverName: String?                   // which server is asking — show this
    var serverURL: URL?
}
enum MCPElicitationResponse: Sendable, Equatable { case accept([String: MCPValue]), decline, cancel }

protocol MCPSamplingHandler: Sendable {      // your handler owns the human-in-the-loop approval
    func handleSampling(_ request: MCPSamplingRequest) async -> MCPSamplingResponse?
}
protocol MCPRootsProvider: Sendable { func roots() async -> [MCPRoot] }
protocol MCPLoggingSink: Sendable { func receive(_ message: MCPLogMessage) }
```

**Diagnostics** ([MCP diagnostics](mcp-guide.md#diagnostics-when-a-user-reports-an-mcp-problem)) — off-content, secrets redacted:

```swift
enum MCPDiagnostics {
    static var logLevel: MCPLogLevel { get set }     // default .info
    static func setEnabled(_ enabled: Bool)          // in-memory ring buffer, default off
    static var capacity: Int { get set }             // default 500
    static var observer: (@Sendable (MCPDiagnosticEvent) -> Void)? { get set }
    static func exportText() -> String
    static func exportJSON() -> Data
    static func clear()
}
enum MCPLogLevel: Int, Sendable, Comparable, Codable { case debug, info, notice, error, off }
```

**OAuth setup** ([the OAuth redirect URI + AppDelegate wiring sections](mcp-guide.md#oauth-redirect-uri--must-set-this-yourself-if-your-server-uses-oauth)):

```swift
enum MCPOAuthFlow {
    static var redirectURI: String { get set }        // MUST override before any connect/addServer call
    static var clientMetadataURL: URL? { get set }     // optional — CIMD instead of DCR ([Client ID Metadata Documents](mcp-guide.md#cimd-skipping-dynamic-client-registration))
}

final class MCPOAuthRedirectListener {
    static let shared: MCPOAuthRedirectListener
    func handleRedirect(_ url: URL)             // call from your AppDelegate's open-URL handler
}
```

**Advanced**: `protocol MCPConnection` is the transport abstraction `MCPServerManager` drives
internally (`connect() async -> Result<MCPServerIdentity, MCPServerError>`, `listTools()`,
`callTool(name:arguments:allowElicitation:)`, resource/prompt equivalents, `close()`). You won't
need this unless you're replacing the transport layer itself — everything above already goes
through it for you. `connect()`'s result is what a fresh handshake actually told you:

```swift
struct MCPServerIdentity: Sendable, Codable, Equatable {
    var protocolVersion: MCPProtocolVersion
    var serverName: String
    var serverTitle: String              // display name (BaseMetadata `title`, 2025-06-18+); falls back to serverName
    var serverVersion: String?
    var instructions: String?            // free-text usage guidance some servers return
    var capabilities: MCPServerCapabilities
}
// Which optional round-trips are worth firing — absent means "not supported," so a tools-only
// server never gets an unnecessary resources/list call and its method-not-found error.
struct MCPServerCapabilities: Sendable, Codable, Equatable {
    var tools: Bool; var toolsListChanged: Bool
    var resources: Bool; var resourcesListChanged: Bool; var resourcesSubscribe: Bool
    var prompts: Bool; var promptsListChanged: Bool
    var logging: Bool; var completions: Bool
    var hasExperimental: Bool            // server declared something in `experimental`, kept opaque
}
// How the connection talks to the server: initialize + session (through 2025-11-25), or
// 2026-07-28's stateless model (server/discover, per-request _meta, MRTR). Callers of
// MCPServerManager never see the difference.
enum MCPConnectionMode: Sendable, Equatable {
    case handshake(MCPProtocolVersion)
    case stateless(MCPProtocolVersion)
    var negotiatedVersion: MCPProtocolVersion { get }
    var isStateless: Bool { get }
}
```

A custom `MCPConnection` also inherits `listen(filter:) -> AsyncStream<MCPChangeEvent>` with a
default that ends at once as `.refused`. Override it only if your transport supports change
notifications. `MCPChangeEvent` is `.acknowledged(filter)`, `.toolsChanged`, `.promptsChanged`,
`.resourcesChanged`, then a final `.ended(MCPListenEnd)`, where `MCPListenEnd` is `.closed`,
`.failed(String)`, `.refused(String)` or `.unauthorized`.

**Credential presence, without a Keychain prompt.** A host that lets a user swap the entire MCP
server list in one shot — a config-profile Load — needs to know, for each server about to be
restored, whether reconnecting will need a fresh sign-in. A server that authenticates via
reactive/auto-discovered OAuth carries `MCPAuthType.none` in its persisted entry (only `.pat` and
`.oauthManual` are declared up front), so the only way to tell is to check whether a token
already exists — without decrypting it, which would trigger the Keychain's user-consent prompt
even on a build that isn't yet trusted for the item (e.g. a fresh ad-hoc-signed dev build):

```swift
enum MCPStoredCredentialKind: String, Sendable, Equatable { case oauth, pat }
enum MCPCredentialProbe {
    // presence-only SecItem query (kSecReturnData false) — never decrypts the secret
    static func storedKind(for server: URL) -> MCPStoredCredentialKind?
    // true when a sign-in would be needed to use `server` — i.e. it declares up-front auth, or a
    // token for it is already stored
    static func requiresAuth(declared authType: MCPAuthType, server: URL) -> Bool
}
```

Pair this with `removeAllKeepingCredentials()` + `restore(from:)` above: clear every in-memory
server without touching Keychain tokens, then restore the new list — a server that reappears in
it reconnects without a fresh sign-in, and `MCPCredentialProbe` is what your Save/Load UI uses to
tell the user which servers will need one.

## `MCPTool` (Path A for MCP)

Builds a `Tool` at runtime directly from an `MCPToolDescriptor`'s real JSON Schema — no
hand-written `Arguments` struct. `Arguments` is `GeneratedContent` (not a static type), and
`parameters` is computed from the tool's schema rather than derived from `Arguments` the usual
way. The initializer is throwing — a tool whose schema doesn't build should be skipped, not let
crash your whole tool list; see [Two paths to tool-calling](sdk-guide.md#two-paths-to-tool-calling-ready-made-tools-or-write-your-own) (the two tool-calling paths) for the recommended loop shape.

```swift
struct MCPTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema   // built from descriptor.rawSchema, not from Arguments
    // Arguments == GeneratedContent

    init(descriptor: MCPToolDescriptor, manager: MCPServerManager) throws
    func call(arguments: GeneratedContent) async throws -> String
}

enum MCPToolAdapterError: Error, CustomStringConvertible {
    case invalidRawSchema           // rawSchema wasn't valid JSON
    case unbuildableSchema(String)  // FoundationModels rejected the resulting GenerationSchema
}
```

Common JSON Schema shapes (object/properties/required, array/items, string/number/integer/
boolean, string enums) convert cleanly. Anything past that — `oneOf`/`anyOf` unions, `$ref`,
`const`, regex `pattern` — degrades to a free-form string leaf rather than failing the whole tool,
since the remote server is still the real source of argument validation.

## MCP Apps (`LocalLMLabSDKMCPAppsHost`)

Open source, shipped as source like `Components`, on Core's public API only. Walkthrough:
[MCP Apps](mcp-guide.md#mcp-apps-showing-a-servers-interactive-views).

```swift
// --- declare support, fetch and check a view ----------------------------------
extension MCPClientHandlers { func advertisingMCPApps() -> MCPClientHandlers; static let mcpAppsExtensionKey: String }
struct MCPAppResource: Sendable {           // a validated view: text/html;profile=mcp-app, size-capped
    static let mimeType = "text/html;profile=mcp-app"
    let html: String; let sha256: String     // pin / compare versions by sha256
    init(content: MCPResourceContent, requestedURI: String, listedMeta: MCPValue? = nil) throws
}
@MainActor final class MCPAppWidgetCache {   // views on disk by hash; LRU past maxBytes (64 MB)
    init(directory: URL? = nil, maxBytes: Int = 64 * 1024 * 1024)
    func fetch(resourceURI: String, server: MCPServerID, manager: MCPServerManager, recordID: String? = nil) async throws -> MCPAppResource
    func store(_ content: MCPResourceContent, requestedURI: String) throws -> MCPAppResource
    func resource(sha256: String) -> MCPAppResource?             // nil if missing or tampered
    func bind(recordID: String, sha256: String); func sha256(forRecord recordID: String) -> String?
}

// --- render ---------------------------------------------------------------------
@MainActor final class MCPAppViewController: NSObject, ObservableObject {
    init(resource: MCPAppResource, tools: [MCPToolDescriptor], backend: any MCPAppsBackend,
         configuration: MCPAppsBridgeConfiguration,
         bridgePolicy: any MCPAppsBridgePolicy = MCPAppsDefaultPolicy(),   // tool calls allowed; messages, context, links denied
         sandboxPolicy: MCPAppsSandboxPolicy = .closed,                   // no network unless allowed
         actions: MCPAppsHostActions = MCPAppsHostActions(),
         supportedDisplayModes: [String] = ["inline"],
         audit: @escaping @MainActor (MCPAppsAuditEvent) -> Void = { _ in })
    let webView: WKWebView; let bridge: MCPAppsBridge; let resource: MCPAppResource
    var contentHeight: CGFloat? { get }      // the view's reported height
    func load() async; func close() async    // after close(), release the controller to end its process
}
struct MCPAppView: NSViewRepresentable { init(controller: MCPAppViewController) }

// --- a view's calls go through the session ----------------------------------------
struct MCPAppsSessionBackend: MCPAppsBackend {     // tools/call → session.callMCPTool(…, initiator: .app(instance:))
    init(session: LocalLMLabSession, manager: MCPServerManager, server: MCPServerID, instance: String)
}
extension MCPAppsHostActions {                     // ui/message → a turn; ui/update-model-context → model context
    static func session(_ session: LocalLMLabSession, instance: String, openLink: … = { _ in },
                        onReply: … = { _ in }, requestDisplayMode: … = { _ in false }) -> MCPAppsHostActions
}

// --- many views in one conversation -------------------------------------------------
@MainActor final class MCPAppViewPool: ObservableObject {
    init(limit: Int = 3); var limit: Int; var liveKeys: [String] { get }
    func controller(for key: String, make: () throws -> MCPAppViewController) rethrows -> MCPAppViewController
    func touch(_ key: String); func isLive(_ key: String) -> Bool; func snapshot(for key: String) -> NSImage?
    func release(_ key: String) async; func releaseAll() async
}
enum MCPAppRecreation {
    static func revalidate(_ record: ToolCallRecord, source: any MCPAppWidgetSource, cache: MCPAppWidgetCache,
                           approvedSHA256: Set<String>? = nil) async -> Revalidation?
    static func deliver(_ record: ToolCallRecord, to controller: MCPAppViewController) -> Bool   // stored arguments + result
    struct Revalidation { var decision: MCPAppRecreationDecision; var resource: MCPAppResource?; var widgetChanged: Bool }
}
enum MCPAppRecreationDecision { case render(viewOnly: Bool), needsRefresh(mayRefreshAutomatically: Bool), notApproved, unavailable }
struct MCPServerManagerWidgetSource: MCPAppWidgetSource { init(manager: MCPServerManager, server: MCPServerID) }
// MCPResponseLimits.maxUIResourceBytes (Core) caps a view's HTML (4 MB).
```

## Components (`LocalLMLabSDKComponents`)

```swift
@MainActor
final class MCPServerManagerObservable: ObservableObject {
    let core: MCPServerManager
    @Published private(set) var servers: [MCPServerID: MCPServerState]
    var sortedServers: [MCPServerState] { get }
    init(core: MCPServerManager)
}
// MCPServerError also gets LocalizedError conformance here, for human-readable error text in UI.

struct MCPServerPickerView: View {
    init(manager: MCPServerManagerObservable)
    // Add/list/reconnect/disconnect/remove, all three auth types, per-tool and per-resource
    // enable/disable, prompts listing (read-only), and a "Save As…" text export per server.
    // Per server (2.0): trust + approval controls (setTrust / setToolApproval), a "no tools on" notice,
    // and a "tools changed since trusted" notice with Trust Again.
}

struct MCPOAuthWaitingView: View {
    init(serverName: String, onCancel: @escaping () -> Void)
}

struct MCPResourcesView: View {
    init(manager: MCPServerManagerObservable, onAttach: @escaping (MCPResourceDescriptor, MCPResourceContent) -> Void)
}

struct MCPPromptsView: View {
    init(manager: MCPServerManagerObservable, onUse: @escaping (MCPPromptDescriptor, [MCPPromptMessage]) -> Void)
}

// Model layer (1.0)
struct ModelPickerView: View {
    init(registry: ModelRegistry, selection: Binding<ModelID?>, show27OnlyModels: Bool = true)
    // Lists registry.knownModels with an availability badge each (Ready / Not downloaded /
    // Needs credential / Requires macOS 27). When LocalLMLabSDKInference is linked, also a
    // "Downloaded models" section: installed models + on-disk size, a byte-formatted progress
    // bar + Cancel button per registry.downloads entry (bytesReceived/totalBytes, not just a
    // fraction), and an "Add from Hugging Face" field → registry.startDownload(_:). Binds to
    // the @Observable registry directly — no polling. On macOS 26, show27OnlyModels: true adds
    // disabled "Requires macOS 27" rows for pcc/claude/mlx; false hides them.
}
struct ClaudeAuthField: View {
    init(apiKey: Binding<String>, onCommit: @escaping () -> Void = {})
    // A ready-made secure field for the Claude API key that ClaudeModelProvider(auth: .apiKey(_:)) needs.
}

// Model onboarding, updates and cleanup (1.0.0-RC.1) — Components/README.md has the adapter for MLXModelProvider.
struct ModelOnboardingRequest: Sendable, Equatable, Identifiable {
    init(role: String = "Model", repoID: String, expectedRevision: String? = nil, validates: Bool = true)
}
struct ModelOnboardingSource: Sendable {
    init(provider: any DownloadableModelProvider)     // or init(registry: ModelRegistry)
}
enum ModelOnboardingStepState: Sendable, Equatable {
    case pending, running, done(String), failed(String)
}
struct ModelOnboardingItem: Sendable, Equatable, Identifiable {   // one repo's progress through the flow
    var id: String { request.repoID }
    var request: ModelOnboardingRequest
    var validate: ModelOnboardingStepState = .pending
    var download: ModelOnboardingStepState = .pending
    var pin: ModelOnboardingStepState = .pending
    var downloadFraction: Double?    // 0...1 while downloading, nil otherwise
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var hasFailed: Bool { get }; var isComplete: Bool { get }     // true once `pin` is .done
}
@MainActor @Observable final class ModelOnboardingModel {
    init(requests: [ModelOnboardingRequest], source: ModelOnboardingSource)
    func start(); func cancel(); func reset()
    var items: [ModelOnboardingItem] { get }; var isFinished: Bool { get }; var hasFailed: Bool { get }
}
struct ModelOnboardingView: View {
    init(model: ModelOnboardingModel, showsDownloadProgress: Bool = true,
         onFinished: (([InstalledModel]) -> Void)? = nil, onDismiss: (() -> Void)? = nil)
}
struct ModelFileChange: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable { case added, removed, modified }
    var id: String { path }
    init(path: String, kind: Kind, oldSize: Int64? = nil, newSize: Int64? = nil)
}
struct ModelUpdateOffer: Sendable, Equatable {
    var current: String       // the version the model is on now
    var available: String     // the version on offer
    var changes: [ModelFileChange]
    var isUpToDate: Bool { current == available }
    init(current: String, available: String, changes: [ModelFileChange] = [])
}
enum ModelUpdateOwnership: Sendable, Equatable {
    case userChosen             // the user picked this model, so the user decides; the offer is whatever is newest
    case developerOffered       // built into the app — the developer vets versions; the offer is one they vouch for
    case fixed(reason: String)  // can't be updated here; `reason` is shown as-is
}
struct ModelUpdateActions: Sendable {
    init(check: @escaping @Sendable () async throws -> ModelUpdateOffer,
         apply: @escaping @Sendable (_ revision: String, _ progress: @escaping @Sendable (Double) -> Void,
                                     _ beforeSwitch: @escaping @Sendable () async throws -> Void) async throws -> Void)
    // apply has exactly the shape of MLXModelProvider.updatePin(_:to:beforeSwitch:)
}
@MainActor @Observable final class ModelUpdateModel {
    init(actions: ModelUpdateActions, ownership: ModelUpdateOwnership, currentRevision: String? = nil,
         pauseInference: (@Sendable () async throws -> Void)? = nil)
    func checkForUpdate() async; func update() async; func rollBack() async; func revertToShippedVersion() async
}
struct ModelUpdateView: View { init(model: ModelUpdateModel) }
struct ModelVersionRow: Sendable, Equatable, Identifiable {   // one cached version of a model, for the cleanup list
    var id: String { revision }
    var revision: String
    var isCurrent: Bool     // the version in use; cannot be removed
    var isComplete: Bool    // false for a half-downloaded version
    var freesBytes: Int64   // what removing this version would actually free — its own files, not ones it shares
    var sharedBytes: Int64  // bytes shared with other versions, which removing this one does NOT free
    init(revision: String, isCurrent: Bool, isComplete: Bool = true, freesBytes: Int64, sharedBytes: Int64 = 0)
}
@MainActor @Observable final class ModelVersionsModel {
    init(list: @escaping @Sendable () async -> [ModelVersionRow],
         remove: @escaping @Sendable (ModelVersionRow) async throws -> Int64)   // returns bytes freed; must refuse the current version
    func refresh() async; func remove(_ row: ModelVersionRow) async
}
struct ModelVersionsView: View { init(model: ModelVersionsModel) }

// Online providers (1.0.0-beta.3) — the "AI Models" settings panel. Host owns [RemoteProviderDraft]
// (keys → Keychain) and maps a draft → RemoteProviderConfig in the closures. Components does not
// link LocalLMLabSDKRemote; see [Online providers](remote-providers.md) and examples/model-switch/ProviderGlue.swift.
struct AIModelsSettingsView: View {
    init(registry: ModelRegistry, providers: Binding<[RemoteProviderDraft]>,
         onSave: @escaping (RemoteProviderDraft) -> Void,
         onRemove: @escaping (RemoteProviderDraft) -> Void,
         onTest: ((RemoteProviderDraft) async -> ProviderTestOutcome)? = nil)
    // Built-in families + one ProviderSettingsSection per online provider + an "Add provider" menu.
}
struct ProviderSettingsSection: View {
    init(draft: Binding<RemoteProviderDraft>,
         onSave: @escaping (RemoteProviderDraft) -> Void,
         onRemove: (() -> Void)? = nil,
         onTest: ((RemoteProviderDraft) async -> ProviderTestOutcome)? = nil)
    // One provider: key field, Configured badge, per-model rows, web-search toggle + max-searches
    // stepper, "Test connection" (one result per model). Usable standalone.
}
struct RemoteProviderDraft: Identifiable, Hashable, Sendable {
    var scheme, displayName, baseURL, apiKey: String
    var kind: RemoteProviderKind
    var models: [String]                 // .new(_:) leaves this empty — host prefills
    var webSearchSupported, webSearchEnabled, configured: Bool
    var maxSearches: Int
    var statusText: String?
    static func new(_ kind: RemoteProviderKind) -> RemoteProviderDraft
}
enum RemoteProviderKind: String, CaseIterable {   // openAIChat, openAIResponses, anthropic, openRouter, openAICompatible
    var addMenuLabel: String { get }
}
struct ProviderTestOutcome: Sendable, Equatable {
    struct ModelResult: Identifiable { var modelId: String; var ok: Bool; var detail: String }
    var results: [ModelResult]           // one per configured model, in order
    var message: String?                 // set instead of results when the check couldn't run
    static func unableToRun(_ message: String) -> ProviderTestOutcome
}
```
