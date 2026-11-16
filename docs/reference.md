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

The front door, the model registry, the providers and the session, as types. Everything here is in
`LocalLMLabSDKCore` unless a subsection names another module: `MLXModelProvider` and its supply-chain types are in
**`LocalLMLabSDKInference`**, `ClaudeModelProvider` in **`LocalLMLabSDKClaude`**, and `RemoteModelProvider` in
**`LocalLMLabSDKRemote`** (each a separate xcframework on the same release —
[Targeting macOS 26 and 27](sdk-guide.md#targeting-macos-26-and-macos-27-from-one-build)). The walkthrough is
[The model layer](sdk-guide.md#the-model-layer-models-routing-and-sessions). The prompt cache has its own section,
[Prompt cache and memory](#prompt-cache-and-memory-locallmlabsdkinference).

**In 3.0, loading never downloads.** A session, `capabilityProbe`, `prewarm`, the prompt-cache self-test, a paired
speed helper or a paired adapter on a repo that isn't downloaded (at its pinned revision, if pinned) fails with
`LocalLMLabError.modelUnavailable(reason:)`. Check `availability`, then `validate` and the size, then call
`download(_:)` (or `lab.models.startDownload(_:)`) yourself —
[Loading never downloads](sdk-guide.md#loading-never-downloads-30).

### `LocalLMLab` — the front door

The optional object that bundles the registry, the MCP manager, the tool catalog, the audit stream and the
connector and workspace facades. Every type behind it is usable without it.

```swift
@MainActor final class LocalLMLab {
    struct Configuration {
        var providers: [any ModelProvider]   // two claiming one scheme is a configuration error (traps)
        var state: LocalLMLabState?          // a saved snapshot to restore at construction
        var mcp: MCPSettings                 // how lab.mcp is set up
        init(providers: [any ModelProvider] = [], state: LocalLMLabState? = nil, mcp: MCPSettings = MCPSettings())
    }
    init(configuration: LocalLMLab.Configuration = .init())
    let models: ModelRegistry                 // the observable model surface (below)
    let mcp: MCPServerManager                 // the one MCP manager, made from Configuration.mcp — [MCP client](#mcp-client)
    let audit: SecurityAudit                  // every tool call at the gate, trust and approval changes, drift
    let tools: ToolCatalog                    // the app's plug-ins and tool sources — [Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker)
    let connectors: ConnectorsFacade          // Calendar / Reminders / Contacts / Location permission lifecycle
    let workspace: WorkspaceFacade
    let externalPrograms: ExternalProgramsSwitch   // shared by everything that runs a program
    var externalProgramsEnabled: Bool         // off by default; no effect in a sandboxed process
    var commandRunner: ProcessCommandRunner { get }  // runs programs under the switch
    func snapshot() -> LocalLMLabState        // routes, decision routes, residency, installed records — NOT weights
    func restore(from state: LocalLMLabState) // a newer snapshot version than this build understands is rejected

    // LocalLMLab+makeSession
    func makeSession(route: RouteName, tools: [any Tool] = [], instructions: String? = nil,
                     restoring transcript: Transcript? = nil,  // continue a saved conversation (instructions nil)
                     includeMCPTools: Bool = true,              // offer lab.mcp's enabled tools, and keep following it
                     includePlugins: Bool = true,               // offer every on plug-in's tools — [Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker)
                     dynamicTools: DynamicTools? = nil,         // nil: static tools; else picked per message — [Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker)
                     mcpAppHints: Bool = false,                 // [MCP Apps](mcp-guide.md#mcp-apps-showing-a-servers-interactive-views)
                     options: SessionOptions = .init(),         // merged onto the provider's defaults
                     authorizer: (any ToolCallAuthorizer)? = nil) throws -> LocalLMLabSession
                     // authorizer nil = FailClosedToolAuthorizer: .read calls run, the rest are denied —
                     // [Tool authorization](sdk-guide.md#tool-authorization-two-levers--which-tools-and-whether-they-ask-first)
}

struct MCPSettings {                    // how the lab sets up lab.mcp — MCPServerManager's own defaults
    var handlers: MCPClientHandlers      // incl. extensions, e.g. .advertisingMCPApps() (LocalLMLabSDKMCPAppsHost)
    var responseLimits: MCPResponseLimits
    var versionNegotiation: MCPVersionNegotiation   // .auto
    var liveUpdates: Bool                            // true
    init(handlers: MCPClientHandlers = MCPClientHandlers(), responseLimits: MCPResponseLimits = .default,
         versionNegotiation: MCPVersionNegotiation = .auto, liveUpdates: Bool = true)
}

struct LocalLMLabState: Codable, Sendable, Equatable {   // what lab.snapshot() returns; persist it yourself
    static let currentVersion: Int
    var version: Int
    var routes: [RouteName: ModelID]
    var residency: ModelResidency
    var installedModels: [InstalledModel]          // downloaded-model records; empty without a downloadable provider
    var decisionRoutes: [RouteName: ModelID]        // absent from older snapshots; those restore with none
    init(version: Int = LocalLMLabState.currentVersion, routes: [RouteName: ModelID] = [:],
         residency: ModelResidency = .lastUsedOnly, installedModels: [InstalledModel] = [],
         decisionRoutes: [RouteName: ModelID] = [:])
}

// ConnectorsFacade (lab.connectors): see Connectors. WorkspaceFacade (lab.workspace): see Filesystem workspace.

enum LocalLMLabSDKVersion { static let current: String }   // the release, e.g. "3.0.0"
```

`lab.tools`, `dynamicTools:` and `includePlugins:` are covered in [Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker); `lab.audit` in [Tool authority](#tool-authority-toolcallauthorizer-toolimpact-confirmation);
external programs in [Local programs](#local-programs-direct-download-builds-only).

### `ModelRegistry` — routes, residency, downloads

`lab.models`: the registered providers, the route map, the residency policy and in-flight downloads. Components and
the host bind to it; a provider pushes changes into it. Routing guide:
[`RouteName` + routing](sdk-guide.md#routename--routing--pick-a-model-without-hardcoding-one).

```swift
@MainActor final class ModelRegistry {
    init()
    var providers: [any ModelProvider] { get }          // registration order
    var routes: [RouteName: ModelID] { get }
    var residency: ModelResidency                       // setting it re-runs applyResidency()
    let events: AsyncStream<ResidencyEvent>             // residency changes outside a session
    func applyResidency() async                         // prewarm each .keepWarm route's model; no-op for .lastUsedOnly
    func route(_ route: RouteName, to id: ModelID)      // overwrites
    func modelID(for route: RouteName) -> ModelID?
    func register(_ provider: any ModelProvider) throws // throws ModelRegistryError.schemeAlreadyRegistered
    func replace(_ provider: any ModelProvider)         // register, or replace the provider with that scheme (a new API key)
    func removeProvider(scheme: String)                 // its routes then resolve .unavailable(kind: .noProvider)
    func provider(for id: ModelID) -> (any ModelProvider)?
    func availability(for id: ModelID) -> ModelAvailability
    static let macOS27OnlySchemes: Set<String>          // ["pcc", "claude", "mlx"]
    var schemesRequiringNewerOS: [String] { get }       // those with no provider on this OS; empty on macOS 27
    var downloadableProviders: [any DownloadableModelProvider] { get }   // Components shows download UI when non-empty
    var installedModels: [InstalledModel] { get }       // across all downloadable providers
    var knownModels: [ModelID] { get }                  // providers' advertisedModels, de-duplicated
    var downloads: [ModelID: DownloadProgress] { get }  // in-flight, from startDownload
    func startDownload(_ repoID: String) async throws -> InstalledModel   // throws .noDownloadableProvider, a download
                                                                          // error, or CancellationError after cancelDownload
    func cancelDownload(_ repoID: String)               // no-op if repoID has no in-flight download
    // decision providers and routes: see Decision models
    var decisionProviders: [any DecisionProvider] { get }
    var decisionRoutes: [RouteName: ModelID] { get }
}
struct DownloadProgress: Sendable, Equatable {
    var bytesReceived: Int64
    var totalBytes: Int64
    var fraction: Double          // bytesReceived / totalBytes when totalBytes > 0, else 0
    init(bytesReceived: Int64, totalBytes: Int64, fraction: Double)
}
enum ModelRegistryError: Error, Equatable, CustomStringConvertible {
    case schemeAlreadyRegistered(String)
    case noDownloadableProvider    // link LocalLMLabSDKInference and register MLXModelProvider
}

struct RouteName: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    let rawValue: String
    init(_ rawValue: String); init(stringLiteral value: String)   // "triage" works wherever a RouteName goes
    static let heavy: RouteName   // "heavy"
    static let light: RouteName   // "light"
    static let local: RouteName   // "local"
}
enum ModelResidency: Sendable, Equatable, Codable {
    case lastUsedOnly             // default: keep only the most recently used model warm
    case keepWarm([RouteName])    // prewarm these routes' models and hold them (MLX: raise residentModelLimit)
}
enum ResidencyEvent: Sendable {
    case warmed(ModelID)
    case evicted(ModelID, reason: String)   // "capacity", "memoryPressure", "idleTimeout", "removed", …
    case loadProgress(ModelID, Double)      // 0...1, for a load not tied to a session
}
```

### Model identity, availability and capability

A `ModelID` is `scheme:rest` (`mlx:mlx-community/Qwen3-4B-4bit`, `system`). `ModelAvailability` says whether it can
back a session now and why not —
[`ModelAvailability`](sdk-guide.md#modelavailability--gray-out-a-model-and-say-why).

```swift
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
    case notDownloaded            // a downloadable model not on disk: call download(_:)
    case needsCredential          // e.g. ClaudeModelProvider with no key
    case unavailable(kind: UnavailableKind, detail: String)
    enum UnavailableKind: Sendable, Equatable {
        case ineligibleHardware   // Apple-Intelligence-ineligible Mac, no Metal GPU
        case notEnabled           // Apple Intelligence not switched on
        case modelNotReady        // still downloading on Apple's side, PCC session not established
        case unsupportedModel     // an id or architecture this provider doesn't implement
        case providerError        // an outage, a metadata fetch that failed
        case noProvider           // no registered provider owns the scheme
        case requiresOS(String)   // .requiresOS("macOS 27") on macOS 26 for pcc/claude/mlx — show disabled, don't hide
        case quotaReached(resets: Date?)   // PCC quota used up until resets (nil: Apple didn't say) — not a broken model
    }
    var isAvailable: Bool { get }
}
struct ModelCapabilities: OptionSet, Sendable, Hashable, Codable {
    static let toolCalling: ModelCapabilities
    static let guidedGeneration: ModelCapabilities
    static let reasoningToggle: ModelCapabilities    // effort: .off actually suppresses this model's thinking
}
struct InstalledModel: Sendable, Hashable, Codable, Identifiable {   // weights on disk
    var id: ModelID
    var repoID: String
    var resolvedRevision: String   // the commit this download resolved to; with no build-time pin, persist it
                                   // (outside the HF cache) and pass it back as pinnedRevisions to redownload the same
    var capabilities: ModelCapabilities       // empty until capabilityProbe
    var sizeBytes: Int64?
    var contextTokens: Int?                   // the config's rated window, if it declares one
    init(id: ModelID, repoID: String, resolvedRevision: String, capabilities: ModelCapabilities = [],
         sizeBytes: Int64? = nil, contextTokens: Int? = nil)
}
enum DownloadEvent: Sendable {
    case progress(bytesReceived: Int64, totalBytes: Int64, fraction: Double)
    case completed(InstalledModel)            // exactly once, just before the stream finishes on success
}
struct PreflightResult: Sendable, Equatable {  // validate(_:) — no weights pulled
    enum Stage: String, Sendable, Codable {
        case trustPolicy, repoReachable, mlxFormat, architectureSupported, sizeVsMemory, diskSpace, cacheQuota
    }
    var failedStage: Stage?       // nil = passed; else the first stage that failed
    var detail: String?
    var weightBytes: Int64?       // set once sizeVsMemory runs, pass or fail — apply your own size policy
    var ramBytes: Int64?          // this Mac's physical memory
    var freeDiskBytes: Int64?     // free space on the cache volume
    var passed: Bool { get }
    init(failedStage: Stage? = nil, detail: String? = nil, weightBytes: Int64? = nil, ramBytes: Int64? = nil,
         freeDiskBytes: Int64? = nil)
    static let ok: PreflightResult
}
struct ModelCapabilityReport: Sendable, Equatable {   // capabilityProbe(_:) — authoritative for that model
    var id: ModelID
    var capabilities: ModelCapabilities
    var notes: [String]           // one line per check, pass or fail (MLX adds the prompt cache's status)
    var blocked: String?          // non-nil: can't run at all (no GPU, load error, empty output) — don't route to it
    var isUsable: Bool { get }    // blocked == nil; says nothing about capabilities
    init(id: ModelID, capabilities: ModelCapabilities = [], notes: [String] = [], blocked: String? = nil)
}
```

### Providers — `ModelProvider`, `DownloadableModelProvider`, the built-ins

A provider makes `LanguageModelSession`s for the ids of its scheme. Write one to add a backend; most apps register
the built-ins — [`ModelProvider` and the built-in providers](sdk-guide.md#modelprovider-and-the-built-in-providers).

```swift
protocol ModelProvider: Sendable {
    static var scheme: String { get }
    var scheme: String { get }                          // default: Self.scheme (RemoteModelProvider: the app's)
    func owns(_ id: ModelID) -> Bool                    // default: id.scheme == scheme
    func makeSession(for id: ModelID, tools: [any Tool], instructions: String?,
                     transcript: Transcript?) throws -> LanguageModelSession   // transcript != nil: rebuild after compaction
    func makeSession(for id: ModelID, tools: [any Tool], instructions: String?,
                     transcript: Transcript?, options: SessionOptions) throws -> LanguageModelSession
                                                        // default: ignores options, calls the four-argument one
    func availability(for id: ModelID) -> ModelAvailability
    func prewarm(_ id: ModelID) async                   // default: no-op
    var advertisedModels: [ModelID] { get }             // for a picker; default []
    func turnArtifacts(in transcript: Transcript) -> TurnArtifacts   // server-tool activity + citations; default .none
    func waitUntilCallsEnd(conversation: String) async  // returns once its calls for that conversation have returned;
                                                        // default: at once
    func contextWindow(for id: ModelID) async -> Int?   // for the turn budget; default nil (ContextBudget.windowHint)
}
protocol DownloadableModelProvider: ModelProvider {
    var installed: [InstalledModel] { get }
    func download(_ repoID: String) -> AsyncThrowingStream<DownloadEvent, any Error>  // 0+ .progress, then one .completed,
                                                                                      // or throws; resume/retry internal
    func cancelDownload(_ repoID: String)   // the stream throws CancellationError; stops the real transfer
    func validate(_ repoID: String) async throws -> PreflightResult                   // no weights pulled
    func capabilityProbe(_ id: ModelID) async -> ModelCapabilityReport                 // a real prompt + tool-call round trip
    func remove(_ id: ModelID) throws
    var storageUsed: Int64 { get }
    var residencyEventStream: AsyncStream<ResidencyEvent>? { get }                      // forwarded into registry.events; default nil
}
struct TurnArtifacts: Sendable, Equatable {   // most callers read session.citations / events instead
    var serverToolActivities: [ServerToolActivity]
    var citations: [Citation]
    init(serverToolActivities: [ServerToolActivity] = [], citations: [Citation] = [])
    static let none: TurnArtifacts
}

struct SystemModelProvider: ModelProvider {      // Apple's on-device model, "system"
    init()
    var advertisedModels: [ModelID] { get }
    func contextWindow(for id: ModelID) async -> Int?
}
@available(macOS 27, *) struct PCCModelProvider: ModelProvider {   // Private Cloud Compute, "pcc"
    init()
    var advertisedModels: [ModelID] { get }
    func contextWindow(for id: ModelID) async -> Int?
    func probe(timeout: Duration = .seconds(8)) async -> ModelAvailability   // authoritative PCC liveness check
}
```

#### `ClaudeModelProvider` — `LocalLMLabSDKClaude` (macOS 27)

Claude through Apple's Foundation Models framework, scheme `claude` (`claude:sonnet5`, `claude:opus5`, …). The app
supplies the credential; the SDK stores nothing.

```swift
struct ClaudeModelProvider: ModelProvider {
    static var scheme: String { get }   // "claude"
    enum Auth: Sendable { case apiKey(String); case appAttest(clientID: String) }
    init(auth: ClaudeModelProvider.Auth, extraModels: [String: ClaudeModelSpec] = [:])   // keyed by the id after "claude:";
                                                                                          // overrides a built-in of that key
    var advertisedModels: [ModelID] { get }    // the current Claude ids plus extraModels' keys
    func makeSession(for id: ModelID, tools: [any Tool], instructions: String?, transcript: Transcript?,
                     options: SessionOptions) throws -> LanguageModelSession   // honours effort, sampling, web search
    func turnArtifacts(in transcript: Transcript) -> TurnArtifacts   // server-tool activity; citations stay empty here
}
struct ClaudeModelSpec: Sendable, Hashable {   // a Claude model not in the built-in table; values from Anthropic's docs
    var id: String                    // the API model id, e.g. "claude-opus-5"
    var effortLevels: Set<String>     // "low", "medium", "high", "xhigh", "max" it accepts; unknown values dropped
    var samplingParams: Bool          // accepts temperature / top_p / top_k
    var adaptiveThinking: Bool        // accepts adaptive extended thinking
    var structuredOutput: Bool        // accepts constrained-decoding structured output
    var imageInput: Bool              // accepts image content blocks
    init(id: String, effortLevels: Set<String> = [], samplingParams: Bool = false, adaptiveThinking: Bool = false,
         structuredOutput: Bool = false, imageInput: Bool = false)
}
```

#### `RemoteModelProvider` — `LocalLMLabSDKRemote`

OpenAI, Anthropic's Messages API, OpenRouter and any OpenAI-compatible server, all one provider differing by config.
The module's manifest floor is macOS 26, like Core; the provider reports `.requiresOS("macOS 27")` at runtime on 26.
Guide: [Online providers](remote-providers.md).

```swift
@available(macOS 27, *)
struct RemoteModelProvider: ModelProvider {
    init(_ config: RemoteProviderConfig) throws          // runs config.validated() — the only unchecked-free spelling
    init(unchecked config: RemoteProviderConfig)         // explicit bypass, for configs your own code wrote
    var scheme: String { get }                           // config.scheme
    var advertisedModels: [ModelID] { get }              // config.models
    func probe(for id: ModelID, timeout: Duration = .seconds(8)) async -> ModelAvailability   // zero-token key/model/reachability check
    func turnArtifacts(in transcript: Transcript) -> TurnArtifacts   // server-tool activity + citations for the last turn
    // + both makeSession variants; options are merged onto config.defaultOptions
}
struct RemoteProviderConfig: Sendable, Equatable {
    var scheme: String                          // the app names it — "openai", "groq", …; not privileged
    var displayName: String
    var dialect: Dialect
    var baseURL: URL                            // API root; paths are appended
    var auth: Auth                              // never persisted by the SDK
    var models: [RemoteModel]                   // the SDK ships no defaults
    var capabilities: Set<Capability>
    var defaultOptions: SessionOptions          // merged under each call's options — where "Enable web search" lives
    var allowArbitraryModelIDs: Bool            // true: any "scheme:<string>" routes (OpenRouter)
    var responseLimits: RemoteResponseLimits
    init(scheme: String, displayName: String, dialect: RemoteProviderConfig.Dialect, baseURL: URL,
         auth: RemoteProviderConfig.Auth, models: [RemoteModel] = [], capabilities: Set<RemoteProviderConfig.Capability> = [],
         defaultOptions: SessionOptions = .init(), allowArbitraryModelIDs: Bool = false,
         responseLimits: RemoteResponseLimits = .default)

    enum Dialect: String, Sendable, Hashable, Codable {
        case openAIChat           // POST {base}/chat/completions — OpenRouter, Groq, LM Studio, vLLM, Ollama
        case openAIResponses      // POST {base}/responses — OpenAI's native web_search
        case anthropicMessages    // POST {base}/messages
    }
    enum Auth: Sendable, Hashable {
        case apiKey(String)                        // Authorization: Bearer <key>
        case header(name: String, value: String)   // a custom header, e.g. x-api-key
        case none                                  // a local server, or a proxy that injects credentials
    }
    enum Capability: String, Sendable, Hashable, Codable {
        case webSearch           // provider-native web search
        case structuredOutput    // response_format json_schema
        case imageInput          // image content blocks
    }

    // Presets — conveniences with no privilege; model lists are empty unless you pass them
    static func openAI(apiKey: String, models: [RemoteModel] = []) -> RemoteProviderConfig            // chat/completions
    static func openAIResponses(apiKey: String, models: [RemoteModel] = []) -> RemoteProviderConfig   // Responses API
    static func anthropic(apiKey: String, models: [RemoteModel] = []) -> RemoteProviderConfig         // Messages API
    static func openRouter(apiKey: String, models: [RemoteModel] = []) -> RemoteProviderConfig        // allowArbitraryModelIDs
    static func openAICompatible(scheme: String, displayName: String, baseURL: URL, apiKey: String?,
                                 models: [RemoteModel] = [], allowArbitraryModelIDs: Bool = true) -> RemoteProviderConfig

    // Run on any config whose baseURL or auth came from outside your code. A syntax check, not a trust check.
    func validated() throws -> RemoteProviderConfig   // https (http only to a local host), valid header name, no CR/LF
    static func isLoopbackOrLocalHost(_ host: String) -> Bool    // localhost, loopback IPs, .local / .localhost
    static func isValidHeaderFieldName(_ name: String) -> Bool   // an RFC 7230 token
    enum ValidationIssue: Error, LocalizedError, Equatable {
        case insecureBaseURL(host: String)      // non-HTTPS to a non-local host
        case unsupportedURLScheme(String)       // not http(s)
        case missingHost
        case malformedHeaderName(String)
        case controlCharactersInCredential      // CR/LF in a credential — header injection
    }
}
struct RemoteModel: Sendable, Hashable, Codable, Identifiable {
    var id: String              // the id after the scheme — "gpt-5.5", "anthropic/claude-sonnet-4.6"
    var displayName: String     // defaults to id
    var contextWindow: Int?     // feeds ContextBudget
    init(id: String, displayName: String? = nil, contextWindow: Int? = nil)
}
struct RemoteResponseLimits: Sendable, Hashable {   // a custom endpoint is as untrusted as an MCP server
    var maxResponseBytes: Int             // one non-streaming response body — default 8 MB
    var maxStreamedBytes: Int             // a whole SSE stream — 16 MB
    var maxSSELineBytes: Int              // one SSE line / data: frame — 1 MB
    var maxEmittedTextBytes: Int          // assistant text for one turn — 4 MB
    var maxToolCallArgumentBytes: Int     // one tool call's streamed arguments — 1 MB
    var maxErrorBodyBytes: Int            // a non-2xx body — 64 KB
    init(maxResponseBytes: Int = 8 * 1024 * 1024, maxStreamedBytes: Int = 16 * 1024 * 1024,
         maxSSELineBytes: Int = 1 * 1024 * 1024, maxEmittedTextBytes: Int = 4 * 1024 * 1024,
         maxToolCallArgumentBytes: Int = 1 * 1024 * 1024, maxErrorBodyBytes: Int = 64 * 1024)
    static let `default`: RemoteResponseLimits
}
```

`RemoteError` is under [Error handling](#error-handling).

#### `MLXModelProvider` — `LocalLMLabSDKInference` (macOS 27)

Open-weight models run on the Mac, scheme `mlx`, ids `mlx:<hugging-face-repo-id>`. Register one per `LocalLMLab`:
the resident-model cache and the prompt cache are process-wide, and the last provider built wins. Guide:
[`MLXModelProvider`](local-models-mlx.md#mlxmodelprovider--run-open-weight-models-locally-locallmlabsdkinference).

```swift
@available(macOS 27, *)
struct MLXModelProvider: DownloadableModelProvider {
    static var scheme: String { get }   // "mlx"
    init(cacheDirectory: URL? = nil,                       // default: the Hugging Face cache
         residentModelLimit: Int = 1,                      // loaded models kept at once; a base + its speed helper count as one
         preflightLimits: MLXPreflightLimits = MLXPreflightLimits(),
         pinnedRevisions: [String: String] = [:],          // repo id -> commit: shipped pins, for reproducible downloads
         supplyChainPolicy: MLXSupplyChainPolicy = .default,   // hash verification, trust policy, cache cap
         pinStore: (any MLXPinStore)? = nil,               // captured pins (trust on first use); MLXFilePinStore()
         managedPinStore: (any MLXManagedPinStore)? = nil, // runtime advances of shipped pins; MLXFileManagedPinStore()
         maxModelCallsPerTurn: Int = MLXModelProvider.defaultMaxModelCallsPerTurn,   // runaway tool-loop stop
         promptCache: MLXPromptCache = .automatic)         // [Prompt cache and memory](#prompt-cache-and-memory-locallmlabsdkinference)
    let maxModelCallsPerTurn: Int         // Int.max: no limit; below 1 counts as 1; SessionOptions can override
    static let defaultMaxModelCallsPerTurn: Int   // 16: the first call plus 15 rounds after tool calls
    let promptCache: MLXPromptCache

    var advertisedModels: [ModelID] { get }   // the installed ids
    var installed: [InstalledModel] { get }
    var storageUsed: Int64 { get }
    var residencyEventStream: AsyncStream<ResidencyEvent>? { get }
    func availability(for id: ModelID) -> ModelAvailability   // .available only when on disk at the effective pin
    func makeSession(for id: ModelID, tools: [any Tool], instructions: String?,
                     transcript: Transcript?) throws -> LanguageModelSession
    func makeSession(for id: ModelID, tools: [any Tool], instructions: String?,
                     transcript: Transcript?, options: SessionOptions) throws -> LanguageModelSession
                     // uses effort == .off, the sampling knobs, prefillStepSize, maxModelCallsPerTurn, bypassPromptCache;
                     // throws .modelUnavailable if the model, its helper or its adapter isn't downloaded
    func prewarm(_ id: ModelID) async     // loads from disk only; skipped when an adapter is paired
    func waitUntilCallsEnd(conversation: String) async   // after a Stop: generation stopped, prompt cache committed

    // downloading is its own step
    func download(_ repoID: String) -> AsyncThrowingStream<DownloadEvent, any Error>   // throws LocalLMLabError on failure
    func cancelDownload(_ repoID: String)
    func validate(_ repoID: String) async throws -> PreflightResult
    func capabilityProbe(_ id: ModelID) async -> ModelCapabilityReport   // also runs the prompt-cache self-test if due
    func remove(_ id: ModelID) throws                    // deletes the weights and evicts the resident copy
    func unloadResident(_ id: ModelID, reason: String = "idleTimeout") async   // frees memory, keeps the download
    func unloadAllResident(reason: String = "idleTimeout") async
    static func stopGenerating() async    // stops every MLX reply in the process and returns once the GPU is idle —
                                          // call it before quitting mid-reply ([Stopping a reply](sdk-guide.md#stopping-a-reply-30))
    static var bufferCacheLimitBytes: Int64?       // cap on freed GPU buffers MLX keeps, process-wide; nil = MLX's default
    static let defaultBufferCacheLimitBytes: Int64 // 2 GB

    // pairing — re-applied on the next makeSession for the base repo; a running session keeps its pairing
    func pairDraftModel(_ spec: SpeculativeDecodingSpec?, with baseRepoID: String)   // speed helper; nil clears
    func pairAdapter(_ spec: AdapterSpec?, with baseRepoID: String)                  // specialization patch; nil clears

    // pins, updates, cleanup — [Pinning, updating and cleaning up](local-models-mlx.md#pinning-updating-and-cleaning-up-model-versions)
    func effectivePin(for repoID: String) -> MLXPin?          // the pin a download would use now, and its source; nil = tracks main
    func buildTimePin(for repoID: String) -> String?          // what this build shipped in pinnedRevisions
    func checkPinUpdate(_ repoID: String, to revision: String? = nil) async throws -> MLXPinUpdateCheck   // downloads nothing
    func updatePin(_ repoID: String, to revision: String? = nil,
                   beforeSwitch: (@Sendable () async throws -> Void)? = nil) -> AsyncThrowingStream<DownloadEvent, any Error>
                   // atomic: fetch + verify first, then await beforeSwitch, then move the pin; a throw vetoes
    func updatePins(_ updates: [String: String],
                    beforeSwitch: (@Sendable () async throws -> Void)? = nil) -> AsyncThrowingStream<DownloadEvent, any Error>
                    // all or nothing, for a base and its helper or adapter; one .completed per repo
    func snapshots(for repoID: String) -> [MLXCachedSnapshot]                     // read-only
    @discardableResult
    func removeSnapshot(_ repoID: String, revision: String) throws -> Int64       // refuses the current version; bytes freed

    // prompt cache: promptCapacity(for:), promptCacheStatus(for:), checkPromptCache(for:),
    // recordPromptCacheVerification(for:passed:note:), promptCacheStats, clearPromptCache(), flushPromptCache(),
    // memoryStatus() — see Prompt cache and memory
}
struct MLXPreflightLimits: Sendable, Equatable {
    var maxWeightFractionOfRAM: Double     // default 0.7 — also the base + draft ceiling for a speed-helper pairing
    init(maxWeightFractionOfRAM: Double = 0.7)
}
```

A shipped pin moves only to a full commit hash you pass (`checkPinUpdate` and `updatePin` throw
`.download(stage: "commitRequired", …)` otherwise); a repo with no pin throws `.download(stage: "noCapturedPin", …)`.
Rolling back is `updatePin(repoID, to: oldCommit)`; the old snapshot is normally still cached.

**Model pairing** (`LocalLMLabSDKInference`). A *speed helper* pairs a base model with a smaller draft model of the
same family that proposes tokens for the base to verify in bulk: same output, faster when the draft agrees often. A
*specialization patch* pairs a base with a LoRA/DoRA adapter; it changes the model in place, so a paired session gets
its own loaded copy of the base weights. Both must be downloaded first.

```swift
struct SpeculativeDecodingSpec: Sendable, Equatable {
    var draftRepoID: String    // must share the base model's tokenizer — same family, much smaller
    var numDraftTokens: Int    // tokens proposed per round; default 2 (a long draft mostly wastes work — measure your pair)
    init(draftRepoID: String, numDraftTokens: Int = 2)
}
enum AdapterSource: Sendable, Equatable {
    case huggingFace(repoID: String)   // adapter_config.json + adapters.safetensors; download it with download(_:)
    case directory(URL)                // the same two files already on disk
}
struct AdapterSpec: Sendable, Equatable {
    var source: AdapterSource
    init(source: AdapterSource)
}
```

**Pins and the supply chain** (`LocalLMLabSDKInference`). Precedence per download: `pinnedRevisions` (shipped) beats
the pin store (captured) beats tracking `main`. Stores keep only full commit hashes and must live outside the Hugging
Face cache, which `remove(_:)` deletes. The trust policy applies at download: a downloaded model keeps loading after
the policy changes; revoke it with `remove(_:)`.

```swift
enum MLXPinSource: Sendable, Equatable {
    case shipped     // from MLXModelProvider(pinnedRevisions:)
    case captured    // recorded on first download in an MLXPinStore
}
struct MLXPin: Sendable, Equatable {
    var revision: String
    var source: MLXPinSource
    var buildTimeRevision: String?   // set only for a shipped pin advanced at runtime: what this build shipped
    var isRuntimeOverride: Bool { get }
    init(revision: String, source: MLXPinSource, buildTimeRevision: String? = nil)
}
protocol MLXPinStore: Sendable {            // captured pins
    func pin(for repoID: String) -> String?
    func setPin(_ revision: String, for repoID: String)   // ignore anything that isn't a full commit hash
    func removePin(for repoID: String)
    func removeAllPins()
}
final class MLXFilePinStore: MLXPinStore, @unchecked Sendable {   // mlx-pins.json; atomic writes; a corrupt file reads empty
    static var defaultDirectory: URL        // ~/Library/Application Support/<bundle id>/LocalLMLab
    let fileURL: URL
    init(directory: URL? = nil, fileName: String = "mlx-pins.json")
    var lastWriteError: (any Error)? { get }   // setPin/removePin can't throw; check this
    var allPins: [String: String] { get }
    // + pin(for:), setPin(_:for:), removePin(for:), removeAllPins()
}
struct MLXPinOverride: Sendable, Equatable {   // a runtime advance of a shipped pin
    var base: String        // the pin the build shipped when the override was made
    var revision: String    // the commit it moved to
    init(base: String, revision: String)
}
protocol MLXManagedPinStore: Sendable {     // applied only while base is still this build's pin — a newer build wins
    func override(for repoID: String) -> MLXPinOverride?
    func setOverride(_ override: MLXPinOverride, for repoID: String)
    func removeOverride(for repoID: String)
    func removeAllOverrides()
}
final class MLXFileManagedPinStore: MLXManagedPinStore, @unchecked Sendable {   // mlx-managed-pins.json, same location
    let fileURL: URL
    init(directory: URL? = nil, fileName: String = "mlx-managed-pins.json")
    var lastWriteError: (any Error)? { get }
    var allOverrides: [String: MLXPinOverride] { get }
    // + override(for:), setOverride(_:for:), removeOverride(for:), removeAllOverrides()
}
struct MLXPinUpdateCheck: Sendable, Equatable {   // checkPinUpdate's answer; nothing downloaded
    var repoID: String
    var pinnedRevision: String     // the pin now — keep it to roll back
    var latestRevision: String     // what the requested ref resolves to now
    var changes: [MLXFileChange]   // sorted by path; empty when up to date
    var isUpToDate: Bool { get }
    init(repoID: String, pinnedRevision: String, latestRevision: String, changes: [MLXFileChange] = [])
}
struct MLXFileChange: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case added, removed, modified }
    var path: String
    var kind: Kind
    var oldSize: Int64?    // nil for an added file
    var newSize: Int64?    // nil for a removed file
    init(path: String, kind: MLXFileChange.Kind, oldSize: Int64? = nil, newSize: Int64? = nil)
}
struct MLXCachedSnapshot: Sendable, Equatable {   // one cached version (commit) of a model
    var repoID: String
    var revision: String
    var isComplete: Bool       // false: half-downloaded (listed so it can be cleaned up)
    var isCurrent: Bool        // the one that loads today — removeSnapshot refuses it
    var exclusiveBytes: Int64  // what removeSnapshot frees
    var sharedBytes: Int64     // shared with other snapshots; not freed
    var lastModified: Date?
    init(repoID: String, revision: String, isComplete: Bool, isCurrent: Bool, exclusiveBytes: Int64,
         sharedBytes: Int64, lastModified: Date? = nil)
}

struct MLXSupplyChainPolicy: Sendable {
    var verification: MLXWeightVerification
    var trustPolicy: (any MLXModelTrustPolicy)?   // the SDK ships no list; nil = allow all
    var cacheLimits: MLXCacheLimits
    init(verification: MLXWeightVerification = .default, trustPolicy: (any MLXModelTrustPolicy)? = nil,
         cacheLimits: MLXCacheLimits = .default)
    static let `default`: MLXSupplyChainPolicy    // verification on, no trust policy, no cap
}
protocol MLXModelTrustPolicy: Sendable {
    func evaluate(repoID: String) async -> MLXModelTrustDecision
}
enum MLXModelTrustDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)    // shown in PreflightResult.detail / the download error
}
enum MLXWeightVerification: Sendable, Equatable {
    case enabled     // default — hash every file against its ETag before caching; an unknown ETag shape fails
    case disabled    // for a mirror whose ETags don't match a recognized shape
    static let `default`: MLXWeightVerification
}
struct MLXCacheLimits: Sendable, Equatable {
    var maxTotalCacheBytes: Int64?   // nil (default) = unlimited; counts the WHOLE cache dir; past it: .cacheQuota
    init(maxTotalCacheBytes: Int64? = nil)
    static let `default`: MLXCacheLimits
}
```

**Measuring a turn** (`LocalLMLabSDKInference`). MLX sessions put real token counts, speed and memory on
`LanguageModelSession.Usage.metadata`, as turn-so-far totals across the turn's model calls. Read them from the
turn's `response.usage` or its last stream snapshot's `usage` (`languageModelSession.usage.metadata` is empty).
Other providers don't set them —
[Measuring and guarding a local model's turn](local-models-mlx.md#measuring-and-guarding-a-local-models-turn--usage-speed-memory-limits).

```swift
enum MLXUsageMetadataKey {
    static let promptTokens: String           // Int — prompt tokens processed, summed over rounds
    static let generatedTokens: String        // Int
    static let promptSeconds: String          // Double
    static let generateSeconds: String        // Double
    static let promptTokensPerSecond: String  // Double — "pp"; absent with no prompt time
    static let tokensPerSecond: String        // Double — "tg"
    static let cachedPromptTokens: String     // Int — restored from the prompt cache instead of prefilled
    static let reducedPrefillWindow: String   // Int — smallest prefill chunk a too-big prompt was read in; else absent
    static let promptCache: String            // String — what the cache did and why ("on", "off: bypassed", …)
    static let rounds: String                 // Int — model calls this turn
    static let stopReason: String             // String — "stop", "length" or "cancelled"
    static let draftTokensProposed: String    // Int — speculative decoding only
    static let draftTokensAccepted: String
    static let speculativeRounds: String
    static let residentMemoryBytes: String    // Int — MLX active memory as the turn's first round began
    static let peakMemoryBytes: String        // Int — peak during the turn; peak − resident = what the run needed
    static let gpuMemoryLimitBytes: String    // Int — what macOS lets the GPU use
}
struct MLXPrefillActivity: Sendable, Equatable {   // a prompt being read (prefilled) right now
    let repoID: String
    let promptTokens: Int      // the whole conversation so far, tools and results included
    let modelCall: Int         // 1 for the first call of the turn, higher after each tool round
    let startedAt: Date
    init(repoID: String, promptTokens: Int, modelCall: Int, startedAt: Date)
}
enum MLXPrefillMonitor {
    static var active: [MLXPrefillActivity] { get }   // oldest first; poll it while a turn shows no output
}
```

A rejected tool call (the model wrote one that couldn't be used) is under [Error handling](#error-handling).

### `LocalLMLabSession` — the model-layer members

What `makeSession` returns. These are the members about the model, the turn and its side channel; the members for
[dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker), empty replies, framing and the rest are in [Chat core](#chat-core-chatcontroller-chatsetup-conversations). Guides:
[Running a turn](sdk-guide.md#running-a-turn-and-when-to-use-languagemodelsession),
[Building a chat app](sdk-guide.md#building-a-chat-app--hosttranscript-streamresponse-turncontext).

```swift
struct LocalLMLabSession: Sendable {
    let route: RouteName
    let modelID: ModelID
    var retryOnContextOverflow: RetryPolicy         // .disabled by default; set before respond()
    var turnContext: (@Sendable () -> String?)?    // sent ahead of every prompt (the date, say); not in hostTranscript
    var hostTranscript: HostTranscript { get }      // the conversation as a UI shows it (below)
    var languageModelSession: LanguageModelSession { get }   // Apple's session — the escape hatch; a turn run on it
                                                             // skips the SDK's turn handling
    var events: AsyncStream<SessionEvent> { get }
    var citations: [Citation] { get }               // web-search sources accumulated this session
    func reconcileServerToolArtifacts()             // re-derive citations/events after a turn run on languageModelSession
    var contextBudget: ContextBudget { get }
    func cancel()
    func waitUntilCallsEnd() async                  // the provider's calls have returned; respond/streamResponse wait on
                                                    // it themselves — call it before sending on languageModelSession
    @discardableResult
    func respond(to prompt: String, attachments: [URL] = [], options: SessionOptions = SessionOptions(),
                 fromAppInstance instance: String? = nil) async throws -> String
                 // per-call options: Apple's on-device model only (others throw .perCallOptionsUnsupported);
                 // instance: a message an MCP App view sent
    func streamResponse(to prompt: String, attachments: [URL] = [], options: SessionOptions = SessionOptions(),
                        fromAppInstance instance: String? = nil) -> AsyncThrowingStream<String, any Error>   // the reply so far
    // outside the model's loop (MCP App views, your app): same authorizer, recorded in hostTranscript
    @MainActor func callMCPTool(server: MCPServerID, tool: String, arguments: [String: MCPValue],
                                initiator: ToolCallInitiator) async -> Result<MCPToolResult, MCPServerError>
    @MainActor func updateModelContext(_ text: String, fromAppInstance instance: String)   // sent with the next turn
    static let maxModelContextCharacters: Int       // 8,000 — the most of one widget update that reaches the model
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
    struct ReplyInProgress: Sendable, Equatable { var reasoning: String?; var text: String; var isReasoning: Bool }   // init: [Chat core](#chat-core-chatcontroller-chatsetup-conversations)
    enum ArchiveError: Error, Equatable { case notEmpty, unsupportedFormat(String) }
}
struct ToolCallRecord: Identifiable, Sendable {
    let id: String                       // same as the SessionEvent id
    var modelCallID: String?             // the model's own call id, when the model made the call
    let tool: ToolReference              // .mcp(server:tool:) | .host(name:) | .plugin(id:tool:) | .provider(ServerToolActivity)
    let initiator: ToolCallInitiator     // .model | .app(instance:) | .host
    let arguments: GeneratedContent?; let argumentsDescription: String
    var state: State                     // .awaitingApproval | .running | .finished | .failed(reason:) | .denied(reason:)
    var output: String?                  // what the model saw
    var mcpResult: MCPToolResult? { get }   // the full result (read back from disk if spilled)
    let app: MCPAppLink?                 // the tool's MCP App view, if any
    let toolDescriptor: MCPToolDescriptor?
    let startedAt: Date; var finishedAt: Date?
    // + stillRunningSeconds, sourceName, impact, serverTrusted — see [Chat core](#chat-core-chatcontroller-chatsetup-conversations)
}
enum ToolReference: Sendable, Equatable {
    case mcp(server: MCPServerID, tool: String)
    case host(name: String)              // a tool passed to makeSession(tools:)
    case plugin(id: PluginID, tool: String)   // a tool from a ToolPlugin in lab.tools
    case provider(ServerToolActivity)
    var name: String { get }
}
// ToolCallInitiator (.model / .app(instance:) / .host): see Tool authority

enum SessionEvent: Sendable {            // what's around generation; tokens stay on streamResponse
    case modelLoadProgress(Double)       // 0...1
    case routeSwitched(from: ModelID, to: ModelID)   // reserved for future dynamic routing
    case contextCompacted(removedEntries: Int)
    case toolCallStarted(id: String, name: String, arguments: String)   // arguments: a best-effort rendering
    case toolCallFinished(id: String, name: String, failed: Bool, resultSummary: String?)   // failed: threw or denied
    case serverToolCall(ServerToolActivity)         // provider-run web search/fetch — [Online providers](remote-providers.md)
    case toolCallStillRunning(id: String, name: String, seconds: Int)   // at 15 s, then every 15 s: "still waiting on Orders…"
    case emptyReply(EmptyReply, retrying: Bool)   // retrying: the session runs the turn once more; its outcome follows (EmptyReply: Chat core)
    case toolsRequested(ToolRequest)              // the model asked for tools and the picker found some: the turn runs again with them
}

struct RetryPolicy: Sendable {
    var maxRetries: Int                                          // 0 disables
    var compact: (@Sendable (Transcript) -> Transcript)?
    init(maxRetries: Int = 0, compact: (@Sendable (Transcript) -> Transcript)? = nil)
    static let disabled: RetryPolicy
}
struct ContextBudget: Sendable, Equatable {   // a best-effort gauge — [ContextBudget + RetryPolicy](sdk-guide.md#contextbudget--retrypolicy--surviving-a-long-session)
    let windowTokens: Int?          // nil when the SDK has no estimate (arbitrary downloaded weights)
    let lastInputTokens: Int        // the latest turn's last model call; 0 before the first turn
    let lastOutputTokens: Int
    var fractionUsed: Double?       // lastInputTokens / windowTokens; nil when the window is unknown
    static func windowHint(for id: ModelID) -> Int?
}
```

### `SessionOptions`, effort and the web-search side channel

Per-session (and, for Apple's on-device model, per-call) knobs. A provider uses what it supports and ignores the
rest; `options` passed to `makeSession` are merged onto a provider's configured defaults.

```swift
struct SessionOptions: Sendable, Equatable {
    var webSearch: Bool                  // provider-native web search (remote, Claude)
    var webSearchMaxUses: Int?
    var webSearchAllowedDomains: [String]
    var webSearchBlockedDomains: [String]
    var effort: Effort?                  // reasoning level; nil = provider default
    var temperature: Double?             // MLX, Apple on-device (0 = greedy), remote; not PCC
    var topP: Double?                    // MLX, Apple on-device (exclusive with topK there), remote
    var maxOutputTokens: Int?            // cap on the reply's tokens
    var userLocation: UserLocation?      // for web-search localisation
    var seed: UInt64?                    // MLX + Apple on-device (needs topK/topP there); best-effort on Apple
    var topK: Int?                       // MLX + Apple on-device (exclusive with topP there)
    var minP: Double?                    // MLX only
    var repetitionPenalty: Double?       // MLX only; nil = disabled — the loop/repeat fix
    var repetitionContextSize: Int?      // MLX only — how far back repetitionPenalty looks
    var prefillStepSize: Int?            // MLX only — prefill chunk size; time-to-first-token, not output text
    var maxModelCallsPerTurn: Int?       // MLX only — nil: the provider's (16); Int.max: no limit
    var bypassPromptCache: Bool          // read every prompt in full and keep nothing (a benchmark); default false
    init(webSearch: Bool = false, webSearchMaxUses: Int? = nil, webSearchAllowedDomains: [String] = [],
         webSearchBlockedDomains: [String] = [], effort: Effort? = nil, temperature: Double? = nil,
         topP: Double? = nil, maxOutputTokens: Int? = nil, userLocation: UserLocation? = nil,
         seed: UInt64? = nil, topK: Int? = nil, minP: Double? = nil, repetitionPenalty: Double? = nil,
         repetitionContextSize: Int? = nil, prefillStepSize: Int? = nil, maxModelCallsPerTurn: Int? = nil,
         bypassPromptCache: Bool = false)
    var serverTools: Set<ServerTool> { get }        // derived from the webSearch fields
    func merged(onto base: SessionOptions) -> SessionOptions   // the override wins field by field; webSearch and
                                                               // bypassPromptCache are ORed
    func appleGenerationOptions() throws -> GenerationOptions  // the Apple on-device mapping; throws SessionOptionsError
}
enum SessionOptionsError: Error, LocalizedError, Equatable {   // instead of dropping a knob silently
    case topKAndTopPBothSet                         // Apple's sampler takes top-K or top-P, not both
    case seedRequiresTopKOrTopP                     // a seed only exists inside a random sampling mode
    case invalidValue(field: String, detail: String)
    case perCallOptionsUnsupported(model: String)   // non-default per-call options on a non-`system` session
}
/// Reasoning effort, ordered off → max. `.off` is a real guarantee only on MLX, for toggle-capable chat templates
/// (Qwen3 and its siblings; check ModelCapabilities.reasoningToggle). A model that always reasons keeps reasoning —
/// `.off` never throws. Remote providers, Apple on-device and PCC treat `.off` as nil; pass `.low` to minimize there.
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
    init(id: String = UUID().uuidString, kind: ServerToolActivity.Kind)
}
struct WebHit: Sendable, Equatable, Codable {
    var url: String; var title: String; var snippet: String?
    init(url: String, title: String, snippet: String? = nil)
}
struct Citation: Sendable, Equatable, Codable, Identifiable {
    var id: String; var url: String; var title: String; var citedText: String?
    init(url: String, title: String, citedText: String? = nil)
}
```

`ModelPickerView`, `ClaudeAuthField` and `AIModelsSettingsView` are in **`LocalLMLabSDKComponents`**
([Components](sdk-guide.md#components-prebuilt-swiftui-mcp-servers--the-model-layer)).

## Prompt cache and memory (`LocalLMLabSDKInference`)

A local model rereads the whole conversation on every request; the prompt cache saves what it already read, so a
follow-up reads only what is new. In 3.0 it is on by default for MLX models: memory only, within a budget sized to
the Mac, for verified families straight away and for any other supported model after a one-time self-test. A miss
costs a re-read, never a wrong answer. Everything here is `@available(macOS 27, *)` in `LocalLMLabSDKInference`.
Guides: [The prompt cache](sdk-guide.md#the-prompt-cache-30),
[Open-weight models on the Mac](local-models-mlx.md).

### The `promptCache:` setting

Pass an `MLXPromptCache` as `MLXModelProvider(promptCache:)`. The setting is process-wide, like the resident-model
cache: the last provider's applies. A session skips the cache with `SessionOptions(bypassPromptCache: true)`.

```swift
struct MLXPromptCache: Sendable, Equatable {
    let isEnabled: Bool
    let memoryBudgetBytes: Int64?          // nil: the default, worked out at each call
    let disk: MLXPromptCacheDisk?          // the SSD tier, or nil for memory only
    let storage: MLXPromptCacheStorage     // how saved KV is kept, in memory and on disk
    let verifiedModelsOnly: Bool           // true only for .automatic
    static let off: MLXPromptCache         // 2.x behavior
    static let automatic: MLXPromptCache   // the 3.0 default: memory only, exact, verified families (others after a self-test)
    static func memory(budgetBytes: Int64? = nil, storage: MLXPromptCacheStorage = .exact) -> MLXPromptCache
                                           // memory tier for any supported model
    static func tiered(memoryBudgetBytes: Int64? = nil, disk: MLXPromptCacheDisk = .init(),
                       storage: MLXPromptCacheStorage = .exact) -> MLXPromptCache
                                           // memory + SSD: survives eviction and relaunch; only for models whose exact
                                           // revision is known (pinned, or one downloaded snapshot)
    static let verifiedModelTypes: Set<String>   // config.json model_types checked live: qwen3_5, qwen3, qwen3_moe,
                                                 // llama, nemotron_h, nemotron_h_puzzle
    static let defaultBudgetFraction: Double     // 0.25 of the GPU limit, capped at half the headroom the weights leave
}
enum MLXPromptCacheStorage: Sendable, Equatable {
    case exact              // default: a restore continues exactly as a fresh read
    case compact(bits: Int) // KV quantized to 8 or 4 bits (smaller entries; answers can differ); hybrid state stays exact
}
struct MLXPromptCacheDisk: Sendable, Equatable {   // the SSD tier
    let directory: URL?          // nil: defaultDirectory
    let budgetBytes: Int64       // least-recently-used entries deleted past it
    let sensitive: Bool          // default true: AES-GCM, key in the Keychain; false writes plaintext
    init(directory: URL? = nil, budgetBytes: Int64 = defaultBudgetBytes, sensitive: Bool = true)
    static var defaultBudgetBytes: Int64 { get }   // a fifth of free disk, between 8 and 64 GB (16 GB if unknown)
    static var defaultDirectory: URL { get }       // ~/Library/Caches/<bundle id>/LocalLMLabSDK/PromptCache
    func clear()                 // deletes this directory and the app's prompt-cache key, used or not; memory untouched
    var storedBytes: Int64 { get }   // bytes in the directory now; 0 when it doesn't exist
}
```

The disk tier holds working state from your users' conversations: offer a way to clear it (`MLXPromptCacheDisk.clear()`
or `MLXModelProvider.clearPromptCache()`).

### Per-model status and capacity

Whether the cache works with a given model, and how long a prompt the model can take on this Mac. Both status calls
on `MLXModelProvider` are instant except `checkPromptCache`, which loads the model to run the self-test.

```swift
extension MLXModelProvider {
    func promptCacheStatus(for id: ModelID) -> MLXPromptCacheModelStatus          // instant; never loads the model
    func checkPromptCache(for id: ModelID) async -> MLXPromptCacheModelStatus     // runs the self-test if not yet run for
                                                                                  // this model and SDK version; saves it
    func recordPromptCacheVerification(for id: ModelID, passed: Bool, note: String = "")
                                     // your app's own deep check: a pass shows as verified (.local) and turns the cache
                                     // on for it under .automatic; a failure turns it off
    func promptCapacity(for id: ModelID) -> MLXPromptCapacity?   // nil when not downloaded or the config doesn't say
}
struct MLXPromptCacheModelStatus: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case notSupported(reason: String)   // memory can't be saved and rewound (e.g. sliding-window layers)
        case untested                       // .automatic runs the self-test on first use
        case selfTested(passed: Bool)
        case verified(MLXPromptCacheModelStatus.Source)
    }
    enum Source: String, Sendable, Equatable {
        case sdk      // a family in MLXPromptCache.verifiedModelTypes
        case local    // recorded with recordPromptCacheVerification
    }
    struct Check: Sendable, Equatable, Codable {   // one check's record
        let passed: Bool; let date: Date; let seconds: Double
        let modelRevision: String; let sdkVersion: String   // what it ran against
        let detail: String                                  // what it measured, or why it failed
    }
    let model: ModelID
    let state: State
    let cacheOn: Bool                  // whether this provider's setting uses the cache for this model now
    let selfTest: Check?
    let localVerification: Check?
    let summary: String                // a plain sentence to show as-is
}
struct MLXPromptCapacity: Sendable, Equatable {    // the prompt guard's arithmetic
    let contextWindow: Int?            // the model's rated window, if its config says
    let gpuLimitBytes: Int             // what macOS lets the GPU use
    let weightsBytes: Int
    let bytesPerToken: [Int: Int]      // GPU memory per prompt token (KV + prefill scratch), by prefill chunk size
    let maxTokensAtDefaultChunk: Int?  // the longest prompt in 512-token chunks — all 2.x accepted
    let maxTokens: Int?                // the longest in 3.0, which reads a too-big prompt in smaller chunks (down to 128)
    let kvBytesPerToken: Int?          // KV only: what a kept conversation holds per token
    let maxKeptTokens: Int?            // the longest latest conversation the memory tier keeps between turns
    var memoryBound: Bool { get }      // memory, not the context window, limits prompts here
    static func from(config: [String: Any], gpuLimitBytes: Int, weightsBytes: Int,
                     defaultChunk: Int = 512) -> MLXPromptCapacity   // a "what if" for another Mac or model
}
```

### Stats, memory and housekeeping

Process-wide gauges for a status display, and the calls that empty or flush the cache.

```swift
extension MLXModelProvider {
    static var promptCacheStats: MLXPromptCacheStats { get }   // contents and counters, both tiers
    static func clearPromptCache()      // drops the memory tier and every SSD directory this process used (files + key)
    func clearPromptCache()             // the same, plus this provider's SSD directory even if unused since relaunch
    static func flushPromptCache()      // waits until the SSD tier has written everything queued — before quitting
    static func memoryStatus() async -> MLXMemoryStatus   // cheap; poll every second or two
}
struct MLXPromptCacheStats: Sendable, Equatable {
    var entries: Int; var bytes: Int64; var budgetBytes: Int64   // memory tier: saved sequences and their bytes
    var lookups: Int                   // model calls that looked
    var hits: Int                      // and those that restored something
    var restoredTokens: Int            // prompt tokens restored instead of prefilled
    var processedTokens: Int           // and prefilled
    var evictions: Int                 // dropped for the budget or memory pressure
    var overBudget: Int                // calls too big for the memory tier (only the SSD tier keeps them)
    var memoryPressureReleases: Int    // times memory pressure emptied the memory tier
    var pausedForMemoryPressure: Bool  // true unless memoryPressure is .normal
    var memoryPressure: MLXMemoryPressure
    var diskEntries: Int; var diskBytes: Int64; var diskBudgetBytes: Int64
    var diskLoads: Int                 // entries read back into memory
    var diskWrites: Int
    init()
    var tokenHitRate: Double { get }   // restored ÷ (restored + processed)
}
enum MLXMemoryPressure: String, Sendable, Equatable, Codable {   // macOS's level, as the cache follows it
    case normal      // both tiers work
    case warning     // memory tier released and keeps nothing new; the SSD tier carries on
    case critical    // both tiers pause until it clears
}
struct MLXMemoryStatus: Sendable, Equatable {   // facts only; thresholds and colors are the app's call
    var activeBytes: Int64             // arrays in use: weights, KV caches (the prompt cache's too), working memory
    var bufferCacheBytes: Int64        // freed buffers kept for reuse (capped by MLXModelProvider.bufferCacheLimitBytes)
    var peakBytes: Int64               // most in use since the current or last model call began
    var gpuLimitBytes: Int64
    var promptCacheBytes: Int64        // the memory tier holds…
    var promptCacheBudgetBytes: Int64  // …and may hold
    var memoryPressure: MLXMemoryPressure   // .normal until a provider with the cache on exists
    var loadedModels: [String]         // repos with a copy loaded
    var usedFraction: Double { get }   // (active + bufferCache) / gpuLimit
    init(activeBytes: Int64, bufferCacheBytes: Int64, peakBytes: Int64, gpuLimitBytes: Int64,
         promptCacheBytes: Int64, promptCacheBudgetBytes: Int64, memoryPressure: MLXMemoryPressure,
         loadedModels: [String])
}
```

What the cache did on a turn is in its usage metadata (`MLXUsageMetadataKey.promptCache`, `.cachedPromptTokens`).
`MLXCachedSnapshot` (in the model layer) is a cached *model version* on disk, not a cached prompt.

## Decision models (`lab.decide`, OpenJev, hosted Jev)

A decision model answers fixed questions about a piece of state (yes/no, pick one, score on a scale) with
probabilities, instead of writing text. Reach for it to route, triage or gate. Walkthrough:
[Decision models](decision-models.md). Core unless marked: `OpenJev*` is **`LocalLMLabSDKInference`** (macOS 27),
`Jev*Provider*` is **`LocalLMLabSDKRemote`**. `SystemDecisionProvider` (Apple's on-device model, scheme `system`,
`.generated` fidelity) is declared under
[Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker), where it backs `DecisionToolMatcher`.

### Asking

`lab.decide` validates the request against the provider's `limits`, calls it, and checks every question got an
answer of its kind. [Ask](decision-models.md#ask).

```swift
extension LocalLMLab {
    func decide(route: RouteName, state: DecisionState, questions: [DecisionQuestion]) async throws -> Decision
    func evaluate(route: RouteName, questions: [DecisionQuestion], answerSet: DecisionAnswerSet,
                  progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async throws -> DecisionEvaluation
}
struct DecisionQuestion: Sendable, Hashable, Codable {     // Codable as Jev's {id, type, instructions, criteria}
    enum Kind: Sendable, Hashable, Codable {
        case noul                                    // yes/no: P(yes)
        case choice(criteria: [DecisionQuestion.Criterion])
        case score(levels: [String])                 // ordered levels, low to high
    }
    struct Criterion: Sendable, Hashable, Codable {
        var key: String; var description: String?
        init(_ key: String, _ description: String? = nil)
    }
    var id: String; var instructions: String; var kind: DecisionQuestion.Kind
    init(id: String, instructions: String, kind: DecisionQuestion.Kind)
    static func noul(_ id: String, _ instructions: String) -> DecisionQuestion
    static func choice(_ id: String, _ instructions: String, criteria: KeyValuePairs<String, String>) -> DecisionQuestion
    static func choice(_ id: String, _ instructions: String, criteria: [String]) -> DecisionQuestion
    static func score(_ id: String, _ instructions: String, criteria: [String]) -> DecisionQuestion
}
enum DecisionState: Sendable, Hashable, Codable {   // what the questions are about
    case text(String)
    case json(String)
    static func encoding<T>(_ value: T) throws -> DecisionState where T: Encodable   // .json from a value
    var rendered: String { get }                     // the state as text, the way a local model reads it
}
struct DecisionRequest: Sendable, Hashable {
    var state: DecisionState; var questions: [DecisionQuestion]
    init(state: DecisionState, questions: [DecisionQuestion])
    func validate(against limits: DecisionLimits = .jev) throws   // DecisionError.invalidRequest naming the first problem
}
struct DecisionLimits: Sendable, Hashable {
    var maxQuestions: Int; var maxChoiceCriteria: Int; var maxScoreLevels: Int
    var maxStateCharacters: Int?
    init(maxQuestions: Int, maxChoiceCriteria: Int, maxScoreLevels: Int, maxStateCharacters: Int? = nil)
    static let jev: DecisionLimits               // hosted Jev's documented limits; the DecisionProvider default
    static let openAIDecisions: DecisionLimits   // OpenAI's Decisions API: 400 questions, 255 options, 10 levels
    static let system: DecisionLimits            // SystemDecisionProvider: 64 / 26 / 10, state ≤ 4,000 characters
}
```

### Answers

[Confidence, fidelity and calibration](decision-models.md#confidence-fidelity-and-calibration) explains how far to
trust the numbers.

```swift
struct Decision: Sendable, Hashable, Codable {
    var answers: [String: DecisionAnswer]    // by question id
    var modelID: ModelID
    var fidelity: DecisionFidelity
    var latency: Duration
    var usage: DecisionUsage?                // hosted backends only
    var refusals: Set<String>                // ids the backend declined (only OpenAI's Decisions API today); no answer entry
    init(answers: [String: DecisionAnswer], modelID: ModelID, fidelity: DecisionFidelity, latency: Duration,
         usage: DecisionUsage? = nil)
    init(answers: [String: DecisionAnswer], modelID: ModelID, fidelity: DecisionFidelity, latency: Duration,
         usage: DecisionUsage? = nil, refusals: Set<String>)
    func noul(_ id: String) -> Double?       // P(yes); nil if missing or refused
    func choice(_ id: String) -> ChoiceAnswer?
    func score(_ id: String) -> ScoreAnswer?
    func isRefused(_ id: String) -> Bool     // check before reading; take the cautious path
}
enum DecisionAnswer: Sendable, Hashable, Codable { case noul(Double), choice(ChoiceAnswer), score(ScoreAnswer) }
struct ChoiceAnswer: Sendable, Hashable, Codable {
    var choice: String; var confidence: Double; var probabilities: [String: Double]
    init(choice: String, confidence: Double, probabilities: [String: Double])
}
struct ScoreAnswer: Sendable, Hashable, Codable {
    var score: Double; var confidence: Double; var probabilities: [Double]; var legend: [String]
    var level: Int { get }                   // the most likely level's index
    init(score: Double, confidence: Double, probabilities: [Double], legend: [String])
}
enum DecisionFidelity: Sendable, Hashable, Codable {   // where the probabilities come from
    case native                       // reported by the service itself (TypeSafe's Jev, OpenAI's Decisions API)
    case tokenScored(calibrated: Bool)   // next-token probabilities over the labels (OpenJev, Featherless);
                                         // uncalibrated ones are often 100% even when wrong
    case generated                    // a label the model wrote (SystemDecisionProvider): all-or-nothing, 1 or 0
}
struct DecisionUsage: Sendable, Hashable, Codable {
    var inputTokens: Int?; var outputTokens: Int?; var cost: Double?
    init(inputTokens: Int? = nil, outputTokens: Int? = nil, cost: Double? = nil)
}
enum DecisionError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)       // failed validation, or invalid JSON state
    case noRoute(RouteName)           // the decision route isn't mapped
    case unavailable(ModelID, ModelAvailability)
    case malformedAnswer(String)      // a provider's answers didn't match the questions
    case backend(String)
    case pairing(String)              // ModelRegistry.pair: the pair doesn't fit
}
```

### Providers and routes

Decision providers are a separate list from chat providers, with their own routes, so a scheme can mean one thing
for chat and another for decisions (`openrouter:` is both).

```swift
protocol DecisionProvider: Sendable {               // implement your own backend
    var scheme: String { get }
    func owns(_ id: ModelID) -> Bool                 // default: id.scheme == scheme
    func availability(for id: ModelID) -> ModelAvailability
    var limits: DecisionLimits { get }               // default: .jev
    func fidelity(for id: ModelID) -> DecisionFidelity
    func decide(_ request: DecisionRequest, using id: ModelID) async throws -> Decision   // every question answered
    func prewarm(_ id: ModelID) async                // default: no-op
}
protocol PairableDecisionProvider: DecisionProvider {   // a local decider that can stay resident with a generator
    @MainActor func pair(decider: ModelID, generator: ModelID, registry: ModelRegistry) async throws -> DecisionPairing
}
extension ModelRegistry {
    var decisionProviders: [any DecisionProvider] { get }
    var decisionRoutes: [RouteName: ModelID] { get }   // saved in LocalLMLabState.decisionRoutes
    func register(decision provider: any DecisionProvider) throws
    func replace(decision provider: any DecisionProvider)
    func removeDecisionProvider(scheme: String)
    func route(decision route: RouteName, to id: ModelID)
    func modelID(forDecision route: RouteName) -> ModelID?
    func decisionProvider(for id: ModelID) -> (any DecisionProvider)?
    func decisionAvailability(for id: ModelID) -> ModelAvailability
    func pair(decision: RouteName, generator: RouteName) async throws -> DecisionPairing
        // checks the pair fits, makes room and loads both; throws .noRoute / .pairing and changes nothing then
}
struct DecisionPairing: Sendable, Equatable {   // what pair(decision:generator:) set up —
                                                // [One model or two](decision-models.md#a-decider-and-your-chat-model-one-model-or-two)
    var decider: ModelID
    var generator: ModelID
    var deciderBytes: Int64?       // the decider's weights, when it runs on this Mac
    var generatorBytes: Int64?     // the generator's, when local and not the decider's own model
    var budgetBytes: Int64?        // the memory budget the pair was checked against
    var residentModels: Int        // 0 for hosted; 1 when they share a model or the generator isn't local MLX
    var note: String?
    init(decider: ModelID, generator: ModelID, deciderBytes: Int64? = nil, generatorBytes: Int64? = nil,
         budgetBytes: Int64? = nil, residentModels: Int, note: String? = nil)
}
```

### OpenJev — the local decider (`LocalLMLabSDKInference`, macOS 27)

Runs a decision on a downloaded MLX model by scoring the answer labels' next-token probabilities. `openjev:X` is
available exactly when `mlx:X` is; downloads and pins are `mlx`'s.
[OpenJev](decision-models.md#openjev-the-local-decider).

```swift
struct OpenJevDecisionProvider: PairableDecisionProvider {   // scheme "openjev"; limits 64 questions, 26 options, 10 levels
    init(mlx: MLXModelProvider, wrapper: OpenJevWrapper = .default, calibration: DecisionCalibration? = nil,
         scheme: String = "openjev")
    init(mlx: MLXModelProvider, tunedWith set: DecisionQuestionSet, scheme: String = "openjev")   // as the set was tested
    let scheme: String
    let mlx: MLXModelProvider
    let wrapper: OpenJevWrapper
    let calibration: DecisionCalibration?   // applies to every model it serves: one provider per calibrated model
    let tuning: DecisionQuestionSet.Tuning? // from init(mlx:tunedWith:)
    func warnings(for id: ModelID) -> [OpenJevWarning]
    func tuningMismatch(for id: ModelID) -> String?   // not the model / revision the set was tested with
    func decideWithDiagnostics(_ request: DecisionRequest, using id: ModelID) async throws
        -> (decision: Decision, diagnostics: OpenJevDiagnostics)
}
struct OpenJevWrapper: Sendable, Hashable {   // how a question is put to the model; wording changes answers
    var system: String        // the system turn
    var inputLabel: String    // what the input is called in the prompt
    init(system: String, inputLabel: String)
    static let `default`: OpenJevWrapper
}
enum OpenJevWarning: Sendable, Hashable {
    case mixtureOfExperts     // probabilities shift with how the prompt is split — use it as a generator, not a decider
}
struct OpenJevDiagnostics: Sendable {   // for playgrounds and debugging, not app logic
    struct Question: Sendable {
        let labels: [String]      // the single-token labels asked for, in answer order
        let prompt: String        // the exact text the model received
        let labelMass: Double     // probability on the allowed labels before normalising; low = reword the question
        let latency: Duration
    }
    let questions: [String: OpenJevDiagnostics.Question]   // by question id
    let sharedPrefixTokens: Int   // prompt tokens shared by every question, computed once
}
```

### Hosted deciders (`LocalLMLabSDKRemote`)

TypeSafe's Jev on OpenRouter, Featherless, OpenAI's Decisions API, and any server that copies it.
[Hosted Jev](decision-models.md#hosted-jev).

```swift
struct JevDecisionProvider: DecisionProvider {
    init(_ config: JevProviderConfig)
    let config: JevProviderConfig
    var scheme: String { get }; var limits: DecisionLimits { get }   // config's
    func probe(for id: ModelID, timeout: Duration = .seconds(8)) async -> ModelAvailability
        // one GET …/models, never a decision; OpenAI's wire only (for .jev, the local verdict)
    static func requestBody(model: String, request: DecisionRequest) throws -> Data   // the exact Jev body decide POSTs
    static func requestBody(model: String, request: DecisionRequest, wire: DecisionWireFormat) throws -> Data
}
struct JevProviderConfig: Sendable, Equatable {
    var scheme: String                  // a decision scheme: openrouter, featherless, …
    var displayName: String
    var endpoint: URL                   // the full URL requests are POSTed to
    var auth: RemoteProviderConfig.Auth
    var models: [String]                // ids for a picker, e.g. typesafe/jev-1.13
    var allowArbitraryModelIDs: Bool    // false: only ids in models are available
    var fidelity: DecisionFidelity
    var limits: DecisionLimits
    var responseLimits: RemoteResponseLimits
    var timeout: TimeInterval           // inter-packet; the whole call is capped at three times this
    var wire: DecisionWireFormat        // .jev or .openAIDecisions
    init(scheme: String, displayName: String, endpoint: URL, auth: RemoteProviderConfig.Auth, models: [String] = [],
         allowArbitraryModelIDs: Bool = true, fidelity: DecisionFidelity, limits: DecisionLimits = .jev,
         responseLimits: RemoteResponseLimits = .default, timeout: TimeInterval = 60)
    init(scheme: String, displayName: String, endpoint: URL, auth: RemoteProviderConfig.Auth, models: [String] = [],
         allowArbitraryModelIDs: Bool = true, fidelity: DecisionFidelity, limits: DecisionLimits = .jev,
         responseLimits: RemoteResponseLimits = .default, timeout: TimeInterval = 60, wire: DecisionWireFormat)
    static func openRouter(key: String) -> JevProviderConfig     // TypeSafe Jev, .native — openrouter:typesafe/jev-1.13
    static func featherless(key: String) -> JevProviderConfig    // .tokenScored(calibrated: false)
    static func featherlessDemo() -> JevProviderConfig           // no key, rate-limited — for trying, not shipping
    static func openAI(key: String) -> JevProviderConfig         // OpenAI's Decisions API, .native — openai:gpt-6-luna
    static func openAICompatibleDecisions(baseURL: URL, auth: RemoteProviderConfig.Auth, models: [String],
                                          limits: DecisionLimits = .openAIDecisions, scheme: String = "openaicompat",
                                          fidelity: DecisionFidelity = .native) -> JevProviderConfig
                                          // Fireworks, Vercel AI Gateway, LocalAI…; POSTs to baseURL + /decisions
    func validated() throws -> JevProviderConfig   // https (http only to a local host), valid header, no CR/LF;
                                                   // throws RemoteProviderConfig.ValidationIssue
}
```

### Wire formats (both directions; a server can answer the same API)

`JevWire` is hosted Jev's JSON; `OpenAIDecisionWire` is OpenAI's Decisions API (`POST /v1/decisions`). Both decode
into the same types, so a client and a server on this Mac share code. Answers are matched to questions by id, never
by position.

```swift
enum DecisionWireFormat: String, Sendable, Hashable, Codable {
    case jev               // TypeSafe on OpenRouter, Featherless — JevWire
    case openAIDecisions   // OpenAI and servers that copy it — OpenAIDecisionWire
}
enum JevWire {
    struct Request: Sendable, Hashable {
        var model: String?; var request: DecisionRequest
        init(model: String?, request: DecisionRequest)
    }
    struct Response: Sendable {
        var model: String?; var answers: [String: DecisionAnswer]; var usage: DecisionUsage?
        var fidelity: DecisionFidelity?; var errorMessage: String?
        var refusals: Set<String>       // the {"type":"refusal"} marker
    }
    static func encodeRequest(_ request: DecisionRequest, model: String) throws -> Data
    static func decodeRequest(_ data: Data) throws -> JevWire.Request             // order-preserving
    static func encodeResponse(_ decision: Decision, model: String, request: DecisionRequest) throws -> Data
    static func decodeResponse(_ data: Data, request: DecisionRequest) throws -> JevWire.Response
    static func encodeError(message: String, type: String, code: Int) -> Data
    static func errorMessage(in data: Data) -> String?
}
enum OpenAIDecisionWire {   // .noul is "predicate", a question id is "name", a criterion key is "value"
    static let maxTextCharacters: Int   // OpenAI's limit on any one text field
    static let maxJSONDepth: Int        // input_json limits: nesting depth (32),
    static let maxJSONValues: Int       // number of values (10,000),
    static let maxJSONBytes: Int        // compact UTF-8 size (256 KB)
    static func encodeRequest(_ request: DecisionRequest, model: String) throws -> Data
        // object (or array of objects) JSON state goes as input_json; throws .invalidRequest over OpenAI's input limits
    static func decodeRequest(_ data: Data) throws -> JevWire.Request   // text, or messages with text or one input_json
    static func encodeResponse(_ decision: Decision, model: String, request: DecisionRequest) throws -> Data
        // refusals in place, plus the fidelity / calibrated extensions
    static func decodeResponse(_ data: Data, request: DecisionRequest) throws -> JevWire.Response
    static func errorMessage(in data: Data) -> String?
}
```

### Calibration, question sets, answer sets, evaluation

Fit a correction for token-scored probabilities on your own questions, load a question set exported from JevDK, and
measure a decider against labelled examples.
[From JevDK to your app](decision-models.md#from-jevdk-to-your-app-question-sets-answer-sets-labevaluate).

```swift
struct DecisionCalibration: Sendable, Hashable, Codable {   // a temperature per question kind
    var noulTemperature: Double; var choiceTemperature: Double; var scoreTemperature: Double
    init(noulTemperature: Double, choiceTemperature: Double, scoreTemperature: Double)
    static let none: DecisionCalibration
    struct Sample: Sendable, Hashable, Codable {
        enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
            case noul, choice, score
            init(_ kind: DecisionQuestion.Kind)
        }
        var kind: Kind; var probabilities: [Double]; var correct: [Int]
        init(kind: DecisionCalibration.Sample.Kind, probabilities: [Double], correct: [Int])
    }
    struct Measurement: Sendable, Hashable {
        var count: Int; var accuracy: Double; var expectedCalibrationError: Double; var logLoss: Double
    }
    static func fit(_ samples: [DecisionCalibration.Sample]) -> DecisionCalibration
    func measure(_ samples: [DecisionCalibration.Sample]) -> DecisionCalibration.Measurement
    func temperature(for kind: DecisionCalibration.Sample.Kind) -> Double
    func apply(_ probabilities: [Double], kind: DecisionCalibration.Sample.Kind) -> [Double]
    static func apply(_ p: [Double], temperature t: Double) -> [Double]
}
struct DecisionQuestionSet: Sendable, Hashable, Codable {   // JevDK's "Export Questions…"
    static let currentFormat: Int
    var format: Int; var name: String; var questions: [DecisionQuestion]; var tuning: DecisionQuestionSet.Tuning?
    struct Tuning: Sendable, Hashable, Codable {   // what the set was tested with
        var model: ModelID?; var revision: String?; var system: String?; var inputLabel: String?
        var calibration: DecisionCalibration?; var testedAt: Date?
        init(model: ModelID? = nil, revision: String? = nil, system: String? = nil, inputLabel: String? = nil,
             calibration: DecisionCalibration? = nil, testedAt: Date? = nil)
    }
    init(name: String, questions: [DecisionQuestion], tuning: DecisionQuestionSet.Tuning? = nil)
    init(contentsOf url: URL) throws
    init(json data: Data) throws
    func jsonData() throws -> Data
}
struct DecisionAnswerSet: Sendable, Hashable, Codable {     // CSV: input, then one column per question id
    struct Example: Sendable, Hashable, Codable {
        var input: String; var answers: [String: String]
        init(input: String, answers: [String: String])
    }
    var examples: [DecisionAnswerSet.Example]
    init(examples: [DecisionAnswerSet.Example])
    init(csv text: String) throws
    func csv(questionIDs: [String]) -> String
    func problems(for questions: [DecisionQuestion]) -> [String]
    static func answerKey(_ raw: String, for q: DecisionQuestion) -> String?
}
struct DecisionEvaluation: Sendable {   // lab.evaluate's result; a refusal counts as a miss
    struct QuestionScore: Sendable, Hashable {
        var id: String; var kind: DecisionCalibration.Sample.Kind
        var marked: Int; var correct: Int; var refused: Int; var accuracy: Double
        var meanConfidenceWhenRight: Double?; var meanConfidenceWhenWrong: Double?
    }
    struct Miss: Sendable, Hashable {
        var input: String; var questionID: String; var expected: String
        var answer: String          // the top answer's key, or "refused"
        var confidence: Double
    }
    var modelID: ModelID; var fidelity: DecisionFidelity
    var questions: [DecisionEvaluation.QuestionScore]; var misses: [DecisionEvaluation.Miss]
    var samples: [DecisionCalibration.Sample]       // feed DecisionCalibration.fit
    var decisions: Int; var totalLatency: Duration
    var accuracy: Double; var calibration: DecisionCalibration.Measurement
    func score(_ questionID: String) -> DecisionEvaluation.QuestionScore?
}
```

## Tool authority (`ToolCallAuthorizer`, `ToolImpact`, confirmation)

The security runtime around tool calls: which tools a session may see, the gate every call passes before it runs, how
the user or a policy is asked, how outside content is kept as data, how changed MCP tools are held for review, and the
audit stream that records all of it. Start with [The tool authorizer](tool-authorizer.md) (the 3.0 change in one page)
and [Security in the SDK 3.0: the guide for host apps](security-guide-for-hosts.md); the settings tables are in
[Tool authorization](sdk-guide.md#tool-authorization-two-levers--which-tools-and-whether-they-ask-first).
Everything here is in `LocalLMLabSDKCore` except the confirmation sheet, in `LocalLMLabSDKComponents`.

### Lever 1: which tools the model sees

A plain filter you apply before building the session. It works on any runtime, including one with no one to ask.

```swift
extension Sequence where Element == any Tool {
    func limited(toMaxImpact ceiling: ToolImpact) -> [any Tool]   // keeps tools at or below ceiling; an unrated tool counts as .mutate
}
enum ToolImpact: Int, Sendable, Codable, Comparable, CaseIterable {
    case read          // reads, or transforms what the model was handed
    case mutate        // creates or changes something, recoverably
    case destructive   // deletes, or overwrites so data is lost
    var name: String   // "read" / "mutate" / "destructive"
}
// 3.0: ToolImpact encodes as its name ("read", "mutate", "destructive"), so a log or a saved approval says what it
// means. The numbers 0, 1, 2 that 2.x wrote still decode.

protocol ImpactRatedTool: Tool { var impact: ToolImpact { get } }   // every ready-made SDK tool conforms; unrated = .mutate
protocol CallImpactRatedTool: ImpactRatedTool {                     // a call can raise its rating from its arguments, never lower it
    func callImpact(for arguments: GeneratedContent) -> CallImpact? // nil: the usual `impact` applies
}
struct CallImpact: Sendable, Equatable {
    let impact: ToolImpact
    let reason: String                    // short, for the sheet: "overwrites notes.md", "deletes files: rm -rf build"
    init(_ impact: ToolImpact, _ reason: String)
}
protocol OutboundTool: Tool { var sendsDataOut: Bool { get } }   // can send data off the Mac (MCP tools always count)
protocol ArgumentCheckedTool: Tool {                             // refuses impossible arguments before anyone is asked
    func argumentRefusal(for arguments: GeneratedContent) -> String?   // what to tell the model instead; nil = fine
}
protocol OriginTaggedTool: Tool { var toolOrigin: ToolOrigin { get } }   // your own MCP-backed Tool keeps .mcp origin and MCP policy
```

`OutboundTool`: when a call to such a tool carries a long run of text from something the model read, the confirmation
says so; with `asksBeforeSendingReadContent` on (below) the call always asks. `ArgumentCheckedTool`: the refusal is
counted as a failed call, not a denial.

### Lever 2: the gate

`makeSession(..., authorizer:)` (see [The model layer](#the-model-layer-locallmlab-routing-providers-sessions)) installs
the gate on every tool the session can call, and the same gate sees calls from an MCP App view and your own
`callMCPTool`. **3.0: passing no authorizer gives the session `FailClosedToolAuthorizer`**, not "no gate". A denied
call returns `DENIED: <reason>` to the model as the tool result (for `String`-output tools); for any other `Output` the
call throws and the turn ends as `LocalLMLabError.generation`.

```swift
protocol ToolCallAuthorizer: Sendable {
    func authorize(_ call: PendingToolCall) async -> ToolCallDecision
    func verdict(for call: PendingToolCall) async -> ToolCallVerdict   // what the SDK calls; default wraps authorize as .authorizer
}
enum ToolCallDecision: Sendable { case allow; case deny(reason: String) }
struct ToolCallVerdict: Sendable {           // a decision and who made it, for the audit stream
    let decision: ToolCallDecision
    let decidedBy: ToolCallDecider
    init(_ decision: ToolCallDecision, by decidedBy: ToolCallDecider)
}
enum ToolCallDecider: String, Sendable, Codable {
    case approval     // a standing approval let it run (an "Always allow", a read under "ask before changes"); AllowingToolAuthorizer
    case user         // the user answered (or an earlier answer for this view was applied)
    case policy       // your ToolPolicy answered
    case failClosed   // no one could decide: no channel, no policy, a timeout, or FailClosedToolAuthorizer
    case authorizer   // a host-written authorizer that doesn't implement verdict(for:)
    case noGate       // no gate at all (a session not built with makeSession)
}

struct FailClosedToolAuthorizer: ToolCallAuthorizer {   // what a session gets when you pass no authorizer
    init()   // a .read call runs (unless requiresUser); anything else is denied, with a reason naming the fix, and no one is asked
}
struct AllowingToolAuthorizer: ToolCallAuthorizer {     // runs every call: say so on purpose (a batch job, a read-only session)
    init()   // the audit stream still records each call, decidedBy .approval
}
struct ConfirmingToolAuthorizer: ToolCallAuthorizer {   // the normal choice for an app with a UI
    init(channel: (any ToolConfirmationChannel)?,       // how the user is asked; nil = calls that need the user are denied
         policy: ToolPolicy? = nil,                     // answers approvals `by: .policy`
         hostTools: ToolApproval = .ask(atOrAbove: .mutate, by: .user),   // your own tools, and a plug-in call whose approval is unknown
         timeout: Duration = .seconds(120))             // backstop over the channel's and the policy's own liveness
}
```

`ConfirmingToolAuthorizer`, per call: a call with `requiresUser` asks the user whatever the approval. Otherwise it takes
the approval that applies (an MCP call's `serverApproval`, or `.default(for: .untrusted)` when that is nil; a plug-in
call's `serverApproval`, or `hostTools`; your own tools' `hostTools`). Below the threshold, or `.allow`: runs. `.ask(by:
.user)`: asks `channel`. `.ask(by: .policy)`: asks `policy`, which may allow, deny, or hand it to the user. No channel,
no policy, a timeout or a declined question all deny. An MCP App view's calls (`initiator: .app`) remember the user's
answer per view, server and tool, so a polling view asks once; `.destructive` calls, timeouts and policy decisions
are not remembered. Copies of one authorizer share those answers.

A custom authorizer should implement `verdict(for:)` so the trail says who decided, and should ask the user when
`requiresUser` is true.

### What the gate is handed

```swift
struct PendingToolCall: Sendable {
    let toolName: String                   // the model-facing name
    let arguments: GeneratedContent?       // structured; nil only for a rare third-party Arguments that can't convert
    let argumentsDescription: String       // always present; for a sheet's raw view
    let origin: ToolOrigin
    let impact: ToolImpact                 // as of this call: the tool's (or server's) rating, raised by CallImpactRatedTool;
                                           //   an untrusted MCP server's tools are .mutate whatever their labels say
    let initiator: ToolCallInitiator
    let serverApproval: ToolApproval?      // filled by the SDK, read live: the MCP server's or the plug-in's approval; nil for your own tools
    let impactReason: String?              // why this call is rated as it is ("deletes files: rm -rf build"), and any
                                           //   content-check notes; nil when the usual rating applies
    let requiresUser: Bool                 // ask the user whatever the approval: the call copies a tool call found in
                                           //   content the model read, an image isn't read yet, or (with
                                           //   asksBeforeSendingReadContent) it would send read text out
    init(toolName: String, arguments: GeneratedContent?, argumentsDescription: String, origin: ToolOrigin, impact: ToolImpact,
         initiator: ToolCallInitiator = .model, serverApproval: ToolApproval? = nil, impactReason: String? = nil,
         requiresUser: Bool = false)       // public so you can build one in tests of your own authorizer
    var summary: PendingToolCallSummary    // the Codable projection, for an authorizer in another process
}
struct PendingToolCallSummary: Codable, Sendable, Equatable {   // everything but `arguments`
    let toolName: String
    let argumentsDescription: String       // JSON of the arguments when they are structured
    let origin: ToolOrigin
    let impact: ToolImpact
    let initiator: ToolCallInitiator       // decodes as .model when missing
    let serverApproval: ToolApproval?
    let impactReason: String?
    let requiresUser: Bool                 // encoded under the key "mustAskUser"; "requiresUser" and a missing key (false) still decode
    init(toolName: String, argumentsDescription: String, origin: ToolOrigin, impact: ToolImpact,
         initiator: ToolCallInitiator = .model, serverApproval: ToolApproval? = nil, impactReason: String? = nil,
         requiresUser: Bool = false)
}
enum ToolOrigin: Sendable, Codable, Equatable {
    case host                                            // a tool you passed to makeSession(tools:)
    case mcp(server: MCPServerID, displayName: String)   // a tool from an MCP server
    case plugin(id: PluginID, displayName: String)       // new in 3.0: a tool from a ToolPlugin in lab.tools
}
enum ToolCallInitiator: Sendable, Hashable, Codable {
    case model                    // the model, during a turn
    case app(instance: String)    // an MCP App view, acting on what the user clicked
    case host                     // your own code (callMCPTool)
}
```

### Approvals and policy

Approvals are set per MCP server and per tool on `lab.mcp` (`setTrust(_:server:)`, `setToolApproval(_:server:)`,
`setToolApproval(_:server:tool:)`; see [MCP client](#mcp-client)) and per plug-in on `lab.tools`
(`setToolApproval(_:plugin:)`). They are read on every call, so a change applies to the next call in a running session.

```swift
enum MCPServerTrust: String, Sendable, Codable, CaseIterable {
    case untrusted   // the default: the server's readOnly/destructive labels are ignored, every tool counts as .mutate
    case trusted     // its labels set each tool's ToolImpact
}
enum ToolApprover: String, Sendable, Codable {
    case user        // the end user, through the authorizer's ToolConfirmationChannel
    case policy      // your ToolPolicy (a policy service, an MDM rule set, a rule over the arguments)
}
enum ToolApproval: Sendable, Codable, Equatable {
    case allow                                            // every call runs
    case ask(atOrAbove: ToolImpact, by: ToolApprover)     // calls at or above the impact need `by`; lower ones run
    static func `default`(for trust: MCPServerTrust) -> ToolApproval   // untrusted: .ask(.mutate, .user); trusted: .ask(.destructive, .user)
}
typealias ToolPolicy = @Sendable (PendingToolCall) async -> ToolPolicyDecision   // gets the whole call; a timeout counts as deny
enum ToolPolicyDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
    case askUser     // hand it to the user (denied when the authorizer has no channel)
}
```

### Asking the user

`ConfirmingToolAuthorizer` asks through a `ToolConfirmationChannel`. In one SwiftUI process, use Components'
`ToolConfirmationPresenter`; when the user is in another process, write a channel that sends `call.summary` there and
awaits the reply.

```swift
protocol ToolConfirmationChannel: Sendable {
    func requestDecision(for call: PendingToolCall) async -> Bool   // may wait as long as it likes; false also means "gave up";
}                                                                   //   honour cancellation (stop showing it, return false)
final class DecisionGate: @unchecked Sendable {   // resume-once guard for a channel's continuation (the answer vs. a timeout)
    init()
    func attach(_ continuation: CheckedContinuation<Bool, Never>)
    func resume(_ value: Bool)                    // extra calls are ignored
}

// --- LocalLMLabSDKComponents: the ready-made channel and sheet -------------------------------------------------
// ToolConfirmationPresenter (a ToolConfirmationChannel that drives a sheet), ToolConfirmationRequest, ToolConfirmationExtras
// and View.toolConfirmationSheet(_:): see Components, "Asking the user".
```

`useStandardMCPExtras` offers neither "Always allow" nor "Trust" on a call with `requiresUser`, since neither would stop
that question.

### Content the model read

Checks on what the model has read, from [Content is content](security-guide-for-hosts.md#5-content-is-content). The
session runs them for you; the types are public so a tool of yours can apply the same checks.

```swift
struct ToolCallContext: Sendable {           // the conversation, for the duration of one call the model makes
    static var current: ToolCallContext? { get }   // nil when a tool is called outside a session; only the session sets it
    let userText: String                     // the user's messages (with context the app sent with them)
    let toolResultText: String               // earlier tool results, and the text inside images sent to the model
    let imageText: String                    // the images' text alone (also in toolResultText)
    let imagesUnread: Bool                   // an image wasn't read in time: a call that changes or sends something asks
    init(userText: String, toolResultText: String, imageText: String = "", imagesUnread: Bool = false)
    func isSourced(_ text: String) -> Bool   // appears in the user's messages or an earlier tool result
    func echoesToolCall(names: [String], arguments: GeneratedContent?) -> Bool   // copies a call written in a tool result
                                                                                 //   (not when the user's own messages hold it)
    func carriedContent(in arguments: GeneratedContent?, minimumLength: Int = 40) -> String?   // a run of read text carried
}                                                                                              //   into the arguments, or nil
enum ContentFrame {                          // outside content framed as data for the model
    static func wrap(_ text: String, source: String) -> String   // a line before (where it came from, don't follow it), a line after
    static func neutralize(_ text: String) -> String              // escapes lines that would read as the SDK's own markers
}
enum LinkSource: String, Sendable, Codable, Equatable {
    case user        // the user's own messages hold its host
    case content     // only content the model read holds it (a file, a page, a tool result)
    case unsourced   // nowhere in the conversation: the model wrote it
}
enum ReplyLinks {   // http(s) links in a reply, in order, once each, with where each came from
    static func sources(in text: String, context: ToolCallContext) -> [(url: URL, source: LinkSource)]
}

// Session switches (LocalLMLabSession; ChatSetup has the same two for a ChatController's sessions)
var framesUntrustedContent: Bool          // results from files, pages, programs and MCP servers reach the model inside a
                                          //   ContentFrame (about 40 tokens each); your transcript keeps the plain result. Off by default
var asksBeforeSendingReadContent: Bool    // a call that can send data out and carries read text asks the user, even on a
                                          //   trusted server or "Always allow". Off by default: it's a note on the sheet and trust decides
```

### Tool drift

The SDK keeps the tool list the user last accepted for each MCP server and classifies every change against it; your
`DriftPolicy` says what each kind of change means. Set it as `lab.mcp.driftPolicy` (default `.standard`); a held change
waits in `MCPServerState.pendingDrift` for `acceptDrift(server:)` or `rejectDrift(server:)` (see [MCP client](#mcp-client)).
Background: [Servers: trust, approval and drift](security-guide-for-hosts.md#4-servers-trust-approval-and-drift).

```swift
struct ToolChange: Sendable, Equatable, Codable {
    enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case toolAdded, toolRemoved
        case descriptionChanged, parameterDescriptionChanged     // model-read text: where injected text hides
        case optionalParameterAdded, requiredParameterAdded, parameterRemoved, parameterTypeChanged
        case enumNarrowed, enumWidened                           // a widened enum can be a new power
        case impactEscalated, impactLowered                      // the tool's hints got worse / safer
        case outputSchemaChanged
        case serverIdentityChanged                               // the server reports a different name
        case shadowing                                           // a new tool has the same name as another server's tool
    }
    let kind: Kind
    let tool: String?          // nil for a change to the server itself
    let detail: String         // for a review sheet or a log
    let action: DriftAction    // the policy's action, resolved when the drift was found
    init(kind: Kind, tool: String?, detail: String, action: DriftAction = .askNow)
}
enum DriftAction: Int, Sendable, Codable, Comparable, CaseIterable {   // mildest to strongest (raw values are fixed, not the order)
    case accept                 // take it silently
    case acceptAndLog           // take it, and log it
    case acceptPendingReview    // use it, report it for review; calls are rated by the accepted form until the user accepts
    case disableUntilApproved   // hold the tool (offered in no session) until accepted; the rest of the server works
    case askNow                 // hold it, and the next turn that needs this server asks the user to review
    case blockServer            // disconnect the server until reviewed
}
struct ToolDrift: Sendable, Equatable, Codable {   // the changes waiting for the user (accepted ones aren't in it)
    let server: MCPServerID
    let changes: [ToolChange]
    let foundAt: Date
    var needsReview: Bool       // a change is .askNow or stronger: the next turn that needs the server stops for the user
    var blocksServer: Bool      // a change is .blockServer
}
struct DriftPolicy: Sendable, Equatable {          // a kind with no action asks (.askNow)
    var actions: [ToolChange.Kind: DriftAction]
    var serverOverrides: [MCPServerID: [ToolChange.Kind: DriftAction]]   // over `actions`, per server
    var toolOverrides: [ToolRef: DriftAction]                            // one action for every change to a tool, over the rest
    init(actions: [ToolChange.Kind: DriftAction], serverOverrides: [MCPServerID: [ToolChange.Kind: DriftAction]] = [:],
         toolOverrides: [ToolRef: DriftAction] = [:])
    func action(for kind: ToolChange.Kind, server: MCPServerID, tool: String?) -> DriftAction
    static let standard: DriftPolicy     // text changes and worse impact ask; new tools, shadowing, wider enums held;
                                         //   call-breaking changes taken and logged; a new server name blocks
    static let strict: DriftPolicy       // everything asks except a removed tool; a new name or shadowing blocks
    static let permissive: DriftPolicy   // text changes taken and logged; new tools still held, worse impact still asks,
}                                        //   a safer label still waits, a new name still blocks
enum DriftCause: String, Sendable, Codable { case connect, liveUpdate, restore, policyChange }   // what brought the new list
```

### The audit stream

One ledger of everything security-relevant: each tool call as it reaches the gate, the decision and who made it, how
it ended, every change to trust, approvals and exclusions, servers added and removed, drift, and MCP App views shown.
Subscribe once and persist it; `recent` is only an in-memory tail. It is separate from `SessionEvent` (the UI feed) and
`MCPDiagnostics` (the debug log). See [The audit stream](security-guide-for-hosts.md#9-the-audit-stream).

```swift
// lab.audit: SecurityAudit (also MCPServerManager.audit — the lab's, or its own for a manager used alone)
final class SecurityAudit: @unchecked Sendable {
    init()
    func events() -> AsyncStream<SecurityAuditEntry>    // every entry from now on; each call is its own subscription
    @discardableResult
    func observe(_ handler: @escaping @Sendable (SecurityAuditEntry) -> Void) -> UUID   // runs on the recording thread: hand off slow work
    func stopObserving(_ id: UUID)
    var recent: [SecurityAuditEntry] { get }            // the last entries, oldest first
    var recentCapacity: Int                             // default 256
    func record(_ event: SecurityEvent, conversation: String? = nil)   // the SDK calls it; you may, for your own events
}
struct SecurityAuditEntry: Sendable, Equatable, Codable {
    let sequence: UInt64        // strictly increasing within a process: for order, and to spot a gap
    let at: Date
    let event: SecurityEvent
    let conversation: String?   // LocalLMLabSession.auditConversation (ChatController sets its chat's ID); nil outside a conversation
}
enum SecurityEvent: Sendable, Equatable, Codable {   // a stable Codable shape, for logs read back years later
    // tool calls, from every entrance; callID is the ToolCallRecord.id and SessionEvent.toolCallStarted's id
    case toolCallRequested(callID: String, call: PendingToolCallSummary)
    case toolCallDecided(callID: String, toolName: String, allowed: Bool, reason: String?, decidedBy: ToolCallDecider)
    case toolCallFinished(callID: String, toolName: String, failed: Bool, summary: String?)   // a denied call finishes failed
    case toolCallRefused(toolName: String, origin: ToolOrigin, initiator: ToolCallInitiator, reason: String)
                         // before any authorizer: held by drift, excluded, server off or unreachable, a missing permission,
                         //   arguments an ArgumentCheckedTool refused
    // trust, approvals and exclusions
    case trustChanged(server: MCPServerID, from: MCPServerTrust, to: MCPServerTrust)
    case serverApprovalChanged(server: MCPServerID, approval: ToolApproval?)          // nil: back to the trust level's default
    case toolApprovalChanged(server: MCPServerID, tool: String, approval: ToolApproval?)   // nil: back to the server's
    case toolApprovalDropped(server: MCPServerID, tool: String, why: String)          // the tool was removed, or a change to it reviewed
    case toolExclusionChanged(server: MCPServerID, tool: String, excluded: Bool)
    // servers
    case serverAdded(server: MCPServerID, displayName: String, local: Bool)
    case serverRemoved(server: MCPServerID)
    // drift
    case driftFound(server: MCPServerID, cause: DriftCause, changes: [ToolChange], held: [String], blocksServer: Bool)
    case driftAccepted(server: MCPServerID, changes: [ToolChange])
    case driftRejected(server: MCPServerID, changes: [ToolChange])
    // MCP App views (reported by an MCP Apps host)
    case widgetShown(instance: String, server: MCPServerID, sha256: String, changedSinceApproved: Bool)
                     // changedSinceApproved: a new version; it gets a new instance, so earlier answers don't carry over
}
```

### A call the provider refused

Not a gate decision: a model provider's parser refused a call to a tool it wasn't offered this turn. The session treats
it as the model asking for that tool and runs the turn again with it.

```swift
// RefusedToolCall: see Error handling.
```

## Dynamic tools (`DynamicTools`, plug-ins, the tool picker)

New in 3.0, all in `LocalLMLabSDKCore`. The tools your app has are *available*, and a picker chooses the few each
message needs; only those enter the prompt. Reach for this when a chat has more tools than the model's context can
carry, or when MCP servers should connect only when one of their tools is used. The walkthrough is
[Tools: available, not attached](sdk-guide.md#tools-available-not-attached-30); the measurements and how each picker
behaves are on [Choosing tools per turn](https://thisbrain.ai/locallm/tool-picker.html).

### Turning it on: `DynamicTools` and `makeSession`

A session is dynamic only when you pass `dynamicTools:`; there is no default picker. Without it a session is static,
as in 2.x: every tool that's on (MCP `enabled`, plug-ins on) is in every prompt, from connected servers only. A
session can't switch modes; `updateDynamicTools` swaps the picker of a session that is already dynamic.

```swift
struct DynamicTools: Sendable {
    var selector: ToolSelector                     // picks each turn's tools
    init(selector: @escaping ToolSelector)         // your own selector
    static func matching(_ matcher: some ToolMatcher,
                         options: ToolMatchingOptions = ToolMatchingOptions()) -> DynamicTools   // = ToolSelectors.matching
    // a line for your system instructions: what to do when no tool fits (say what's missing, ask; never make up results)
    static let missingToolGuidance: String
    static let missingToolGuidanceWithRequests: String   // the same for a session with requestsTools: call requestTools first
}

extension LocalLMLab {
    let tools: ToolCatalog                         // the app's plug-ins, and every tool source next to lab.mcp's servers
    func makeSession(route: RouteName, tools: [any Tool] = [], instructions: String? = nil,
                     restoring transcript: Transcript? = nil, includeMCPTools: Bool = true,
                     includePlugins: Bool = true,   // offer the tools of every plug-in that's on in lab.tools (after `tools`, before MCP)
                     dynamicTools: DynamicTools? = nil,   // nil: static tools, as in 2.x
                     mcpAppHints: Bool = false, options: SessionOptions = .init(),
                     authorizer: (any ToolCallAuthorizer)? = nil) throws -> LocalLMLabSession
}

// ChatSetup (see Chat core) builds a chat's session with the standard notes wired in:
extension ChatSetup {
    func makeSession(lab: LocalLMLab, restoring memory: Transcript?, dynamicTools: DynamicTools) throws -> LocalLMLabSession
    static func dynamicTools(matcher: any ToolMatcher, maxTools: Int) -> DynamicTools   // .matching(matcher, options: .init(maxTools:))
}
```

```swift
let session = try lab.makeSession(route: .chat, dynamicTools: .matching(SystemToolMatcher()),
                                  authorizer: authorizer)
session.toolContext = { $0.heldBackNote }   // tell the model what it wasn't given, so it asks instead of guessing
```

In a dynamic session every tool of the plug-ins that are on and of the MCP servers the user added is available, minus
the user's exclusions and what drift holds. Chosen tools of disconnected servers are connected for the turn; a needed
sign-in, permission, review or clarification ends the turn with a `ToolGate` (below).
`ChatSetup.makeSession(lab:restoring:dynamicTools:)` also sets `toolContext` to the workspace, new-tool, changed-tool,
held-for-review, held-back and no-tools notes, and copies `permissionAsking`, `requestsTools` and
`standingInstructions` from the setup. The rest of `ChatSetup` and `ChatController` are in [Chat core](#chat-core-chatcontroller-chatsetup-conversations).

### The session's dynamic-tool members

These are the `LocalLMLabSession` members that drive or report the picker. The session's other 3.0 members are in
[Chat core](#chat-core-chatcontroller-chatsetup-conversations).

```swift
extension LocalLMLabSession {
    var usesDynamicTools: Bool { get }                     // made with dynamicTools:
    @discardableResult
    func updateDynamicTools(_ dynamicTools: DynamicTools) -> Bool   // new selector from the next turn; false (no change) for a static session
    var standingInstructions: (@Sendable () -> String)?    // what the user asks on every message (custom instructions); an MCP server named there is offered every turn
    var toolContext: (@Sendable (ToolPreparation) -> String?)?   // text sent after the tool block, ahead of the message, once the tools are chosen; nil by default
    var permissionAsking: PermissionAsking                 // when a plug-in missing a system permission asks; default .onCall
    var requestsTools: Bool                                // each dynamic turn also offers requestTools; off here, on in ChatSetup

    // per turn
    func pinTools(_ refs: Set<ToolRef>)                    // offer these next turn whatever the selector picks (a clarify answer); gates still apply
    func skipForNextTurn(permissions: Set<PluginPermission> = [], servers: Set<MCPServerID> = [])   // leave these out next turn (after a declined card)
    func markPromptCacheCold()                             // next selection: the prompt isn't cached, so a stale guess can be dropped for free

    // continuing a conversation in a new session (relaunch, model switch, edit, regenerate)
    func carryOverTools(_ refs: [ToolRef], history: ToolHistory? = nil)   // call after makeSession(restoring:); refs no longer available are dropped
    var offeredTools: [ToolRef] { get }                    // the latest turn's tools, in the order the model sees them
    var toolHistory: ToolHistory { get }                   // save with offeredTools; pass both back to carryOverTools

    // what happened
    var lastToolPreparation: ToolPreparation? { get }      // nil before the first turn
    var gatesAfterTurn: [ToolGate] { get }                 // sign-ins and reviews a server asked for during the finished turn; cleared next turn
    var lastTurnRoom: TurnRoomReport? { get }              // how the turn's tool calls fit the model's window; nil when the window is unknown
}
```

`pinTools`, `skipForNextTurn` and `carryOverTools` apply to dynamic sessions only; `pinTools` and `skipForNextTurn`
are cleared once a turn's tools are prepared. To reopen a chat with the same tools, save `offeredTools` and
`toolHistory`, then call `carryOverTools(_:history:)` on the new session: with `growOnly` the tools stay offered in the
same order and the prompt cache keeps matching.

### Plug-ins and the catalog: `ToolPlugin`, `ToolCatalog`

A plug-in is a group of related tools with one capability card, compiled into the app (never downloaded or loaded at
runtime). Only the app adds plug-ins or turns them on, never the model. The built-in plug-ins (`ClockPlugin`,
`CalendarPlugin`, `WebPlugin`, …) are in their own section; write your own by conforming to `ToolPlugin`.

```swift
protocol ToolPlugin: Sendable {
    var id: PluginID { get }                               // stable, reverse-DNS: "com.example.notes"
    var displayName: String { get }
    var card: CapabilityCard { get }                       // what the picker reads
    func makeTools() -> [any Tool]                         // in the order the model should see them; called when a session is made and when the plug-ins that are on change
    var requiredPermissions: Set<PluginPermission> { get } // default []; checked when a tool is chosen or called, never asked by the plug-in
    var defaultApproval: ToolApproval { get }              // default .ask(atOrAbove: .mutate, by: .user)
    var runsExternalPrograms: Bool { get }                 // default false; true: offered only while the app allows external programs
    var returnsUntrustedContent: Bool { get }              // default false; true: results framed as data when framesUntrustedContent is on
}

struct PluginID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String); init(stringLiteral value: String)
}

enum PluginPermission: String, Hashable, Codable, Sendable, CaseIterable {
    case calendar, reminders, contacts, location
    var userData: String { get }                           // "your reminders", as a card says it
    var settingsPane: String { get }                       // its pane under System Settings › Privacy & Security
    var connector: Connector { get }                       // the lab.connectors connector that grants it
}

struct CapabilityCard: Sendable, Equatable {
    var summary: String                                    // one line: what the plug-in does
    var fileTypes: [UTType]                                // an attachment of one of these picks it, no matcher
    var keywords: [String]                                 // for KeywordToolMatcher, and "the message names it"
    var handlesWebLinks: Bool                              // an http(s) link in the message picks it
    var essentialTools: [String]                           // offered together whenever any tool of it is picked
    var names: [String]                                    // words that name it ("files", a workspace's name): picked without asking the matcher
    var nameFolders: [URL]                                 // file names in these folders name it too ("what's in inventory.py")
    var namedByRequests: Bool                              // the user's words show when it's needed: dropped sooner when unused
    init(summary: String, fileTypes: [UTType] = [], keywords: [String] = [], handlesWebLinks: Bool = false,
         essentialTools: [String] = [], names: [String] = [], nameFolders: [URL] = [], namedByRequests: Bool = false)
    static func mostSpecific(_ cards: [CapabilityCard], for type: UTType) -> [Int]   // indices of the cards that handle `type`, most specific only
}

@MainActor final class ToolCatalog {                       // lab.tools
    convenience init()                                     // no MCP servers beside it (tests, an app without lab.mcp)
    func add(_ plugin: any ToolPlugin, enabled: Bool)      // replaces one with the same id; leave personal-data plug-ins off until the user turns them on
    func remove(_ id: PluginID)
    func setEnabled(_ enabled: Bool, plugin: PluginID)     // from the next turn
    func isEnabled(plugin: PluginID) -> Bool
    func setToolExcluded(_ excluded: Bool, plugin: PluginID, tool: String)   // one tool unavailable, both modes; not persisted
    func isToolExcluded(plugin: PluginID, tool: String) -> Bool
    func excludedTools(plugin: PluginID) -> Set<String>    // save it, set it again at launch
    func setToolApproval(_ approval: ToolApproval?, plugin: PluginID)   // nil: back to defaultApproval; read on each call
    func toolApproval(plugin: PluginID) -> ToolApproval
    var plugins: [any ToolPlugin] { get }                  // every plug-in added, by id
    var enabledPlugins: [any ToolPlugin] { get }           // those on, by id: the order their tools reach the model
    func plugins(handling type: UTType) -> [any ToolPlugin]   // whose card lists `type` (most specific), off ones included
    var sources: [ToolSource] { get }                      // plug-ins, then lab.mcp's servers by id
}

struct ToolSource: Sendable, Identifiable {                // one source as the catalog lists it, for a settings view
    enum Kind: Hashable, Sendable { case plugin(PluginID); case mcp(MCPServerID) }
    struct ToolSummary: Sendable, Equatable { let name: String; let description: String }   // a tool, without building it
    var id: Kind { get }
    let kind: Kind
    let displayName: String
    let card: CapabilityCard?                              // nil for an MCP server
    let tools: [ToolSummary]                               // an MCP server's as last fetched (it may be disconnected)
    let isEnabled: Bool                                    // plug-in on, or MCP server enabled
    let requiredPermissions: Set<PluginPermission>
    let isConnected: Bool                                  // always true for a plug-in
    let toolsListedAt: Date?                               // nil for a plug-in
}
```

A plug-in's tool descriptions are your own text, so unlike an MCP server's they are trusted. Tools that conform to
`ImpactRatedTool` keep their rating; others count as `.mutate`. A plug-in's permission is never requested by the SDK on
its own: the turn stops with `ToolGate.needsPermission` and your app asks through `lab.connectors`.

```swift
struct NotesPlugin: ToolPlugin {
    let id: PluginID = "com.example.notes"
    let displayName = "Notes"
    let card = CapabilityCard(summary: "Search and read the user's saved notes.",
                              keywords: ["note", "notes"], names: ["notes"], namedByRequests: true)
    func makeTools() -> [any Tool] { [SearchNotesTool(), ReadNoteTool()] }
}
lab.tools.add(NotesPlugin(), enabled: true)
```

### What a selector sees: `ToolRef`, `SelectableTool`, `SelectableSource`, `ToolSelectionRequest`

```swift
struct ToolRef: Hashable, Codable, Sendable, CustomStringConvertible {   // a tool's identity across turns
    enum Source: Hashable, Codable, Sendable {
        case host                                          // passed to makeSession(tools:)
        case mcp(MCPServerID)
        case plugin(PluginID)
    }
    let source: Source
    let name: String                                       // the source's own name (an MCP tool's without its prefix)
    init(source: Source, name: String)
    var description: String { get }                        // "name", "serverID/name" or "pluginID/name"
}

struct SelectableTool: Sendable, Equatable {
    let ref: ToolRef
    let name: String                                       // the name the model sees: github_list_issues
    let description: String                                // the tool's own, without the server's name in front
    let origin: ToolOrigin
    let estimatedTokens: Int?                              // prompt cost where known (MCP tools); nil for host tools
    let needsConnection: Bool                              // a cached tool of a disconnected server: choosing it connects the server
    init(ref: ToolRef, name: String, description: String, origin: ToolOrigin,
         estimatedTokens: Int? = nil, needsConnection: Bool = false)   // for building a request by hand (tests, replays)
}

struct SelectableSource: Sendable, Equatable {             // one source with its tools, as a matcher sees it
    let source: ToolRef.Source
    let displayName: String                                // "This app", a plug-in's name or a server's
    let card: CapabilityCard?                              // nil for the app's own tools and MCP servers
    let tools: [SelectableTool]
    var aliases: [String]                                  // an MCP server's tool prefix and its own reported name
    func summary(compactingAbove limit: Int?) -> String    // card summary, or name + first sentences; past `limit`, name + tool names
    var summary: String { get }                            // summary(compactingAbove: 800)
    var detailedSummary: String { get }                    // never compacted; boundedSummary for a big source
    static let boundedAbove: Int                           // 100
    var isBig: Bool { get }                                // no card and more than boundedAbove tools
    func boundedSummary(limit: Int = 400) -> String        // name, tool count, and a sample of what they do
}

struct ToolSelectionRequest: Sendable {
    let prompt: String                                     // the user's message, without turnContext
    let available: [SelectableTool]                        // every tool the session could offer now, in model order
    let offered: [ToolRef]                                 // last turn's (every ready tool before the first selection)
    let sources: [SelectableSource]                        // `available` grouped by source, with cards
    let isFirstSelection: Bool                             // `offered` is every ready tool, not an earlier choice
    let calledBefore: [ToolRef]                            // tools the model called in this conversation (from the transcript)
    let pinned: [ToolRef]                                  // LocalLMLabSession.pinTools
    let standingInstructions: String                       // LocalLMLabSession.standingInstructions; "" for none
    let explain: @Sendable (ToolSelectionExplanation) -> Void   // report why; ToolSelectors.matching calls it
    let attachments: [URL]                                 // files attached to this message
    let earlierPrompts: [String]                           // the user's earlier messages, oldest first
    let offeredFor: [ToolRef: Int]                         // turns each offered tool has been offered
    let turnsIdle: [ToolRef: Int]                          // turns since the model last ran it
    let droppedIdle: Set<ToolRef>                          // dropped as idle and not offered since
    let guessed: Set<ToolRef>                              // offered because the matcher guessed them
    let conversationTokens: Int?                           // last turn's input tokens, when known
    let cacheIsCold: Bool                                  // markPromptCacheCold
    let idle: Duration?                                    // since the last turn ended
    var links: [URL] { get }                               // http(s) links in the message and attachments
    var attachmentTypes: [UTType] { get }                  // from the attachments' extensions
    init(prompt: String, available: [SelectableTool], offered: [ToolRef],
         cards: [ToolRef.Source: CapabilityCard] = [:], aliases: [ToolRef.Source: [String]] = [:],
         isFirstSelection: Bool = false, calledBefore: [ToolRef] = [], pinned: [ToolRef] = [],
         attachments: [URL] = [], earlierPrompts: [String] = [], offeredFor: [ToolRef: Int] = [:],
         guessed: Set<ToolRef> = [], conversationTokens: Int? = nil, cacheIsCold: Bool = false,
         idle: Duration? = nil, turnsIdle: [ToolRef: Int] = [:], droppedIdle: Set<ToolRef> = [],
         standingInstructions: String = "",
         explain: @escaping @Sendable (ToolSelectionExplanation) -> Void = { _ in })   // for tests and replays
}
```

### Choosing: `ToolSelector`, `ToolSelection`, `ToolSelectors.matching`

A selector is a function from a request to a selection, called as each turn starts, after MCP tool changes are picked
up. Write one for full control, or hand a `ToolMatcher` to `ToolSelectors.matching` (which is what
`DynamicTools.matching` does).

```swift
typealias ToolSelector = @Sendable (ToolSelectionRequest) async -> ToolSelection

enum ToolSelection: Sendable, Equatable {
    case all                                               // every ready tool, as a static session: no connecting, no permission check
    case only(Set<ToolRef>)                                // these; unavailable refs ignored, order stays canonical
    case clarify([ToolRef])                                // ask the user instead: respond throws ToolGate.needsClarification
}

enum ToolSelectors {
    static func matching(_ matcher: some ToolMatcher, options: ToolMatchingOptions = ToolMatchingOptions()) -> ToolSelector
}
```

Each turn, `matching` offers in this order: the app's own tools (`alwaysOfferAppTools`), pinned tools, servers named in
the standing instructions (`offersServersNamedInInstructions`), tools kept from earlier turns (`growOnly`), tools
already called (`keepCalledTools`), plug-ins chosen by an attachment's type or a link, then sources scoring at least `sourceThreshold` and, within each, tools scoring at
least `toolThreshold`, best first, up to the budget. A source whose tools don't fit is dropped. When the top source's
best tools are too close to call, the turn asks the user (`.clarify`). If the matcher fails, the turn keeps what it had.

### Matchers: `ToolMatcher` and the three ready-made ones

```swift
protocol ToolMatcher: Sendable {
    func scoreSources(_ need: String, sources: [SelectableSource]) async throws -> [ToolRef.Source: Double]   // 0…1: does `need` call for this source?
    func scoreTools(_ need: String, sources: [SelectableSource]) async throws -> [ToolRef.Source: ToolScores] // which of its tools fit, or none
    var name: String { get }                               // for "why these tools" views; default: the type's name
    // mid-conversation: does `need`, read after the earlier messages, call for this source on top of `inUse`?
    // nil (the default): no opinion, the additions stand
    func scoreAdditions(_ need: String, earlierPrompts: [String], inUse: [SelectableSource],
                        sources: [SelectableSource]) async throws -> [ToolRef.Source: Double]?
}

struct ToolScores: Sendable, Equatable {
    var tools: [ToolRef: Double]                           // 0…1 per tool
    var noneFit: Double                                    // 0…1 that none of the source's tools fit
    init(tools: [ToolRef: Double], noneFit: Double)
}

struct SystemToolMatcher: ToolMatcher {                    // Apple's on-device model, asked for lists: two small generations a turn
    let maxSources: Int                                    // sources per request
    let maxTools: Int                                      // tools per request, across sources
    let compactSummaryAbove: Int?                          // see SelectableSource.summary(compactingAbove:)
    var name: String { get }                               // "system (lists)"
    init(maxSources: Int = 3, maxTools: Int = 4, compactSummaryAbove: Int? = 800)
    // scoreSources, scoreTools, scoreAdditions: first listed scores 1, each later one 0.05 less, unlisted 0
}

struct DecisionToolMatcher: ToolMatcher {                  // a decision model through lab.decide: yes/no per source, then a choice per source
    typealias Decide = @Sendable (DecisionState, [DecisionQuestion]) async throws -> Decision
    let name: String                                       // "decision", or "decision (<model>)" on a lab route
    init(limits: DecisionLimits = DecisionLimits(maxQuestions: 64, maxChoiceCriteria: 26, maxScoreLevels: 10),
         keywordAgreement: Double? = 0.7,                  // keyword score at which the decider's "none of these tools" is overruled; nil: off
         compactSummaryAbove: Int? = 800, name: String = "decision", decide: @escaping Decide)
    @MainActor init(lab: LocalLMLab, route: RouteName, keywordAgreement: Double? = 0.7, compactSummaryAbove: Int? = 800)   // that route's limits
}

struct KeywordToolMatcher: ToolMatcher {                   // no model: a source named in the message scores 1, then card keywords, summary, tool names
    init()
    var name: String { get }                               // "keyword"
}
```

`SystemToolMatcher` needs nothing downloaded. `DecisionToolMatcher` sends the message and your tool descriptions to
whatever backs the route, so a hosted decider sees them. `KeywordToolMatcher` is fast and predictable but misses
paraphrases. Matcher questions are about the request, never about current facts.

To run `DecisionToolMatcher` on Apple's on-device model, register `SystemDecisionProvider`. It answers by guided
generation, so its answers are all or nothing (`DecisionFidelity.generated`); questions are batched to fit the model's
small context.

```swift
struct SystemDecisionProvider: DecisionProvider {          // scheme "system"; owns ModelID.system
    enum Batching: Sendable, Hashable {
        case combined                                      // as many questions per generation as fit (default)
        case perQuestion                                   // one generation per question (slower; for comparing accuracy)
    }
    let batching: Batching
    let limits: DecisionLimits
    init(batching: Batching = .combined, limits: DecisionLimits = .system)
}
extension DecisionLimits { static let system: DecisionLimits }   // state kept to about a third of the context

try lab.models.register(decision: SystemDecisionProvider())
lab.models.route(decision: "tools", to: .system)
let matcher = DecisionToolMatcher(lab: lab, route: "tools")
```

### The picker's policy: `ToolMatchingOptions`

```swift
struct ToolMatchingOptions: Sendable {
    var maxTools: Int                       // new picks per turn, counting the app's own (5); kept, called and attachment tools are on top
    var maxTokens: Int?                     // optional cap on estimated tokens of app tools plus new picks (nil)
    var wholePlugins: Bool                  // a picked plug-in comes with all its tools, outside maxTools (true); MCP servers stay per tool
    var namesFromFolders: Bool              // a file in a card's nameFolders, or a file-like word, names the plug-in (true)
    var sourceThreshold: Double             // a source needs this score (0.7)
    var toolThreshold: Double               // a tool needs this score (0.3)
    var offerBestToolOfFittingSource: Bool  // offer a fitting source's best tool under toolThreshold if it beats "none" (true)
    var clarifyBelow: Double                // ask the user when the best tool scores below this… (0.6)
    var clarifyMargin: Double               // …and the runner-up is within this of it (0.15)
    var growOnly: Bool                      // keep every tool offered earlier, so the prompt cache keeps matching (true)
    var alwaysOfferAppTools: Bool           // always offer makeSession(tools:) (true)
    var keepCalledTools: Bool               // keep tools the model already called, even in a rebuilt session (true)
    var attachments: @Sendable (String) -> [UTType]   // more attachment types read from the message text ({ _ in [] })
    var followLinks: Bool                   // a web link picks plug-ins whose card handlesWebLinks (true)
    var additionThreshold: Double?          // mid-conversation, a new source needs this from scoreAdditions (0.5); nil: no check
    var serversNeedNamingMidConversation: Bool   // mid-conversation, an MCP server is added only once the conversation names it or called it (true)
    var dropUnusedAfter: Int?               // drop a guessed tool unused for this many turns, when the drop is free (6); nil: never
    var dropFreelyBelowTokens: Int          // a conversation this small makes a drop free (8_000)
    var dropAfterIdle: Duration             // idle this long, the prompt counts as cold (600 s)
    var dropIdleNamedAfter: Int?            // a namedByRequests plug-in unused this many turns is dropped any time (2)
    var offersServersNamedInInstructions: Bool   // a server named in standingInstructions is offered every message (true)
    static let wholeNamedServerLimit: Int   // 12: a named server with at most this many tools comes whole, outside the budget
    init(maxTools: Int = 5, maxTokens: Int? = nil, sourceThreshold: Double = 0.7, toolThreshold: Double = 0.3,
         clarifyBelow: Double = 0.6, clarifyMargin: Double = 0.15, growOnly: Bool = true,
         alwaysOfferAppTools: Bool = true, keepCalledTools: Bool = true, offerBestToolOfFittingSource: Bool = true,
         followLinks: Bool = true, additionThreshold: Double? = 0.5, serversNeedNamingMidConversation: Bool = true,
         dropUnusedAfter: Int? = 6, dropFreelyBelowTokens: Int = 8_000, dropAfterIdle: Duration = .seconds(600),
         dropIdleNamedAfter: Int? = 2, wholePlugins: Bool = true, namesFromFolders: Bool = true,
         attachments: @escaping @Sendable (String) -> [UTType] = { _ in [] })
}
```

A drop is free when the turn adds a tool anyway, the prompt isn't cached (`cacheIsCold`, or idle for `dropAfterIdle`),
or the conversation is at most `dropFreelyBelowTokens`. App tools, pins, attachment and link choices and called tools
are never dropped. `offersServersNamedInInstructions` is not an `init` parameter; set it on the value
(`var o = ToolMatchingOptions(); o.offersServersNamedInInstructions = false`). A named server with more than
`wholeNamedServerLimit` tools counts as named in the message: it fits, and the matcher picks among its tools.

### What a turn got: `ToolPreparation`, `ToolSelectionExplanation`, `ToolHistory`

`lastToolPreparation` and the `toolContext` closure receive a `ToolPreparation`. Its `…Note` properties are ready-made
text for the model; return the ones you want from `toolContext` (as `ChatSetup` does), and put
`DynamicTools.missingToolGuidance` in your instructions so the model says what's missing instead of guessing.

```swift
struct ToolPreparation: Sendable, Equatable {
    let offered: [ToolRef]                                 // in the order the model sees them
    let connected: [MCPServerID]                           // servers connected for this turn
    let unavailable: [MCPServerID: String]                 // chosen but unreachable, with why; the selector was asked again without them
    let explanation: ToolSelectionExplanation?             // nil in a static session
    var attachments: [URL]
    var calledLastTurn: Set<String>                        // tool names the previous turn called
    var canRequestTools: Bool                              // the turn offers requestTools
    var toolRequests: [ToolRequest]                        // this turn's requestTools calls so far
    var addedMidChat: [String]                             // new this turn, mid-conversation, by model-visible name
    var changedMidChat: [String]                           // offered both turns, description changed
    var heldForReview: [String]                            // left out pending drift review, as "tool on Server"
    var workspacesNow: [String]?                           // the user's workspaces now; nil if the chat never had one
    // notes for the model, nil when there is nothing to say:
    var workspacesNote: String? { get }                    // the current workspaces, every turn
    var newToolsNote: String? { get }                      // which tools are new, and that an earlier "I can't" is out of date
    var changedToolsNote: String? { get }                  // a tool it had changed mid-conversation
    var heldForReviewNote: String? { get }                 // a tool waits for the user's review
    var heldBackNote: String? { get }                      // a fitting service was held back because it wasn't named: ask, don't guess
    var noToolsNote: String? { get }                       // no tools at all: say plainly what can't be done
}

struct ToolSelectionExplanation: Sendable, Equatable {     // why these tools, as the selector reported it
    enum Reason: Sendable, Equatable {
        case appTool                                       // makeSession(tools:)
        case pinned                                        // pinTools
        case kept                                          // offered earlier, kept (growOnly)
        case calledBefore                                  // the model called it earlier
        case attachment                                    // an attached file's type chose its plug-in
        case link                                          // a web link chose its plug-in
        case namedInInstructions                           // its MCP server is named in the standing instructions
        case matched(Double)                               // the matcher picked it: tool score × source score
    }
    struct SourceScore: Sendable, Equatable {
        let source: ToolRef.Source; let displayName: String; let score: Double
        init(source: ToolRef.Source, displayName: String, score: Double)
    }
    enum DropMoment: String, Sendable, Equatable, Codable {   // why a stale tool's drop was free
        case piggyback                                     // the turn changed the tool block anyway
        case cold                                          // the prompt wasn't cached
        case cheap                                         // the conversation was still small
        case idle                                          // a namedByRequests plug-in that went unused
    }
    var matcher: String?                                   // ToolMatcher.name
    var elapsed: Duration                                  // set by the SDK
    var sources: [SourceScore]                             // every source scored, best first
    var toolScores: [ToolRef.Source: ToolScores]
    var reasons: [ToolRef: Reason]                         // why each offered tool is offered
    var matcherError: String?                              // the matcher failed; the turn kept what it had
    var additionScores: [ToolRef.Source: Double]           // mid-conversation scoreAdditions results
    var serversNotNamed: [ToolRef.Source]                  // would have added tools but weren't named in the conversation
    var suggested: [ToolRef]                               // held-back tools worth offering after the reply ("Check GitHub for this?")
    var dropped: [ToolRef: DropMoment]                     // guessed tools dropped this turn
    var asked: Set<ToolRef>                                // offered tools whose plug-in this message asks for
    var sameName: [ToolRef]                                // left out: another offered tool has the same name (set by the SDK)
    var withoutPermission: [ToolRef]                       // left out under .bestMatch: plug-in lacks a permission (set by the SDK)
    init(matcher: String? = nil, elapsed: Duration = .zero, sources: [SourceScore] = [],
         toolScores: [ToolRef.Source: ToolScores] = [:], reasons: [ToolRef: Reason] = [:],
         matcherError: String? = nil, additionScores: [ToolRef.Source: Double] = [:])
}

struct ToolHistory: Codable, Sendable, Equatable {         // what a conversation's tools have been through; save it with offeredTools
    var turnsOffered: [ToolRef: Int]                       // turns offered since added
    var guessed: Set<ToolRef>                              // offered because the matcher guessed
    var called: Set<ToolRef>                               // ever called; survives compaction
    var turnsIdle: [ToolRef: Int]                          // finished turns since last run
    var droppedIdle: Set<ToolRef>                          // dropped as idle; back only when a message uses its words, or requestTools
    init(turnsOffered: [ToolRef: Int] = [:], guessed: Set<ToolRef> = [], called: Set<ToolRef> = [],
         turnsIdle: [ToolRef: Int] = [:], droppedIdle: Set<ToolRef> = [])
    mutating func record(offered: [ToolRef], reasons: [ToolRef: ToolSelectionExplanation.Reason],
                         droppedIdle dropped: Set<ToolRef> = [], asked: Set<ToolRef> = [])   // one more turn; for a custom loop
    mutating func noteRan(_ ran: Set<ToolRef>)             // the tools the turn ran: idle again from zero
}

struct ToolRequest: Sendable, Equatable, Codable {         // one requestTools call
    var need: String                                       // what the model asked for
    var added: [ToolRef]                                   // tools it added; empty: nothing fit
    var forNextMessage: Bool                               // the turn had already changed something, so the tools come with the next message
    init(need: String, added: [ToolRef], forNextMessage: Bool = false)
}

struct TurnRoomReport: Sendable, Equatable, Codable {      // LocalLMLabSession.lastTurnRoom
    var callsRun: Int
    var callsNotRun: Int                                   // not run: out of room; the model answered with what it had
    var resultsShortened: Int                              // cut to fit the room left
    var toolsStopped: [String]?                            // not run again this turn after failing repeatedly
    init(callsRun: Int = 0, callsNotRun: Int = 0, resultsShortened: Int = 0)
    var stoppedEarly: Bool { get }                         // any of the above
    func note(assistant: String?) -> String?               // the line under the reply when stoppedEarly; assistant nil: "the model"
}
```

With `requestsTools` on, each dynamic turn offers `requestTools`: the model describes a task it has no tool for, the
picker runs on that description, and when it finds tools the turn runs again with them. A reply that says a tool is
missing, when the model didn't call `requestTools`, makes the session ask for it on the model's behalf (English
wording only, once a turn). Chats saved by `ConversationStore` keep each turn's picker result in `TurnInfo` (see
[Chat core](#chat-core-chatcontroller-chatsetup-conversations)); its scores use `TurnInfo.Scored`:

```swift
extension TurnInfo {
    struct Scored: Codable, Equatable, Sendable { var name: String; var score: Double; init(name: String, score: Double) }
}
```

### When a turn needs the user: `ToolGate`, `PermissionAsking`, `PermissionProblem`

`respond` / `streamResponse` throw a `ToolGate` before the user's message is shown or anything is generated. Show a
card (its text is your app's, never the model's) and, once the user has acted, send the same message again. Gates a
server raised during a turn that finished are in `gatesAfterTurn` instead.

```swift
enum ToolGate: Error, Sendable, Equatable, CustomStringConvertible {
    case needsAuthorization(server: MCPServerID, displayName: String, reason: String)   // sign in: lab.mcp.reconnect; `reason` is for logs
    case needsPermission(plugin: PluginID, displayName: String, missing: Set<PluginPermission>)   // lab.connectors.requestAccess; several plug-ins share one card
    case needsReview(server: MCPServerID, displayName: String, drift: ToolDrift)   // lab.mcp.acceptDrift(server:) or rejectDrift(server:)
    case needsClarification(options: [SelectableTool])     // ask which one; pinTools the answer and send again
}

enum PermissionAsking: Sendable, Equatable {               // LocalLMLabSession.permissionAsking
    case onCall              // default: only when the model calls a tool missing a permission; the gate comes after the turn (gatesAfterTurn)
    case bestMatch           // before the message, for the plug-ins it is about; a paired-in plug-in is left out (withoutPermission)
    case everyChosenPlugin   // before the message, for every chosen plug-in (the 2.x behaviour)
}

struct PermissionProblem: Equatable, Sendable {            // ChatCard.problem: why Allow Access… didn't give working access
    var text: String
    var offersTryAgain: Bool                               // Try Again asks macOS again
    var offersSystemSettings: Bool                         // open the Privacy & Security pane
    init(text: String, offersTryAgain: Bool = true, offersSystemSettings: Bool = true)
}
```

If the user declines a permission or sign-in card, call `skipForNextTurn(permissions:servers:)` and send the message
again: it gets an answer without those tools instead of the same card.

`needsReview` carries a `ToolDrift`; each change in it is a `ToolChange` (both in [Tool authority](#tool-authority-toolcallauthorizer-toolimpact-confirmation), "Tool drift").

```swift
// ToolChange and ToolChange.Kind: see Tool authority, "Tool drift".
```

## Local programs (direct-download builds only)

Running programs on the user's Mac: registered commands the model can call, and local MCP servers over stdio. All of it
is in `LocalLMLabSDKCore`, off by default, and works only in a build without the App Sandbox (a Developer ID,
direct-download build). In a Mac App Store build `ExternalPrograms.isSupported` is false and every run is refused. Each
run is confined by a deny-by-default Seatbelt profile with no network unless allowed. Background and what your app must
do: [Programs on the Mac](security-guide-for-hosts.md#6-programs-on-the-mac).

### The switch

```swift
enum ExternalPrograms {
    static var isSupported: Bool { get }      // false in a sandboxed process (a child would inherit the sandbox), even with the switch on
    static let unsupportedMCPNote: String     // what to tell the user where it's false: run the server behind a localhost bridge
}                                             //   and add its web address
final class ExternalProgramsSwitch: @unchecked Sendable {   // shared by everything that runs a program
    init(isOn: Bool = false)
    var isOn: Bool
    var allowsRunning: Bool { get }           // isOn and supported in this process
    var maxConcurrentRuns: Int                // default 4, across runners sharing this switch; one past the cap is refused, not queued
}

@MainActor final class LocalLMLab {           // (these members; the rest under "The model layer")
    let externalPrograms: ExternalProgramsSwitch
    var externalProgramsEnabled: Bool         // the host's switch, off by default; turning it off stops every local MCP server
    var commandRunner: ProcessCommandRunner { get }   // a runner over externalPrograms
}
```

Turn the switch on only after the user opts in. In a Mac App Store build the switch has no effect; show it disabled.

### Running one program

A `CommandSpec` is an argv, never a shell line. `ProcessCommandRunner` starts it with `posix_spawn` in its own process
group (stopping a run stops everything it started: SIGTERM, then SIGKILL after 2 s), stdin `/dev/null`, a hard and an
idle timeout, output capped with the rest spilled to a file, and the spec's sandbox under `/usr/bin/sandbox-exec`.
Cancelling the calling task stops the run.

```swift
protocol CommandRunner: Sendable {
    func run(_ spec: CommandSpec) async throws -> CommandResult   // throws CommandError
}
struct ProcessCommandRunner: CommandRunner {  // refuses everything while the switch is off or unsupported
    let programs: ExternalProgramsSwitch
    init(programs: ExternalProgramsSwitch)
    func run(_ spec: CommandSpec) async throws -> CommandResult
}
struct CommandSpec: Sendable {
    var executable: URL                       // an absolute path
    var arguments: [String]                   // one element per argument; nothing is split or interpreted by a shell
    var workingDirectory: URL
    var environment: [String: String]         // added to the base PATH, HOME, LANG, TMPDIR; secrets only from the Keychain
    var limits: CommandLimits
    var sandbox: SandboxProfile?              // nil runs it unconfined: only on the user's explicit choice
    init(executable: URL, arguments: [String] = [], workingDirectory: URL, environment: [String: String] = [:],
         limits: CommandLimits = CommandLimits(), sandbox: SandboxProfile?)
    var displayLine: String { get }           // as the model and the user see it: "swift test --filter Foo"
}
struct CommandLimits: Sendable, Equatable {
    var timeout: Duration                     // the longest a run may take
    var idleTimeout: Duration?                // stop a run that prints nothing this long; nil: only `timeout`
    var inlineBytes: Int                      // output kept in CommandResult.output
    var spillBytes: Int                       // output written to the spill file past inlineBytes
    init(timeout: Duration = .seconds(600), idleTimeout: Duration? = .seconds(120),
         inlineBytes: Int = 64_000, spillBytes: Int = 4_000_000)
}
struct CommandResult: Sendable {
    let exitStatus: Int32?                    // nil when it ended on a signal
    let signal: Int32?                        // a timeout's SIGTERM/SIGKILL, or the program's own
    let output: String                        // stdout and stderr together, up to inlineBytes
    let outputBytes: Int                      // all output's size
    let spilled: URL?                         // the full output (up to spillBytes) in a private temporary file; delete it once read
    let timedOut: CommandTimeout?
    let sandboxDenialSuspected: Bool          // the output looks like the sandbox refused something
    let duration: Duration
    let displayLine: String
    var summary: String { get }               // "Ran: swift test (exit 1, 3.2 KB)": a non-zero exit is reported, not a failure
    var notes: [String] { get }               // what to tell the model after the output (an idle stop, a spill, a sandbox refusal)
}
enum CommandTimeout: Sendable, Equatable { case absolute, idle }   // which limit stopped the run
enum CommandError: Error, Sendable, Equatable, CustomStringConvertible {
    case disabled                             // the switch is off
    case unsupported                          // this process is sandboxed
    case notExecutable(String)
    case workingDirectoryMissing(String)
    case spawnFailed(Int32)                   // errno
    case tooManyRunning(Int)                  // maxConcurrentRuns are already running
    var description: String { get }           // a sentence for the user or the model
}
```

### The sandbox

```swift
struct SandboxProfile: Sendable, Equatable {  // deny by default
    enum Network: String, Sendable, Equatable, Codable {
        case none
        case localhost                        // only this Mac, optionally limited to localPorts
        case any                              // the whole network: Seatbelt filters by localhost and port only, never by host name
    }
    var writable: [URL]                       // more places it may write
    var readable: [URL]                       // more places it may read (an interpreter, a virtual environment)
    var network: Network
    var protectsRepositoryHooks: Bool         // refuse writes to .git/hooks, .git/config, .envrc, editor/agent task folders, .husky
    var workingDirectory: URL                 // the folder the rules are relative to
    var writesWorkingFolder: Bool             // false for a read-only workspace: it writes only temporary files
    var localPorts: [Int]?                    // with .localhost, the ports it may reach; nil: any port
    init(workingDirectory: URL, writable: [URL] = [], readable: [URL] = [], network: Network = .none,
         protectsRepositoryHooks: Bool = true, writesWorkingFolder: Bool = true, localPorts: [Int]? = nil)
    static func workingFolder(_ folder: URL, executable: URL? = nil, network: Network = .none, writesFolder: Bool = true,
                              localPorts: [Int]? = nil) -> SandboxProfile   // the default for a run in `folder`, able to read
                                                                            //   the executable's folder (or its virtual environment)
    func source(temporaryDirectory: URL) -> String   // the profile in Seatbelt's language
}
```

A program may write only its working folder (unless `writesWorkingFolder` is false), its own temporary folder, the
app's cache folder and `writable`. It may read installed software (`/usr`, `/System`, `/Library`, `/opt`,
`/Applications`, `/etc`), the working folder, the caches and `readable`, but never the rest of the home folder, other
users, other volumes or the user's temporary folder.

### Registered commands

A command the user sets up once ("run the tests" is `swift test --filter {filter?}` in a folder), offered to the model
as a tool with typed arguments. Commands are grouped into a plug-in (`CommandsPlugin`, a `ToolPlugin` with
`runsExternalPrograms` true), so selection, approvals and cards treat them like any plug-in; see
[Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker). A command rated `.read` runs without asking; one
that changes things asks. A command whose script or user-owned program changed since it was accepted is not run until
the user accepts the change.

```swift
struct RegisteredCommand: Codable, Sendable, Equatable, Identifiable {   // save it; it's Codable
    struct Parameter: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case string, integer, number, boolean }
        var name: String
        var description: String
        var kind: Kind
        var optional: Bool
        var allowsOptionValues: Bool?         // nil/false: a value filling a whole argv element ({name}) can't start with "-"
        init(name: String, description: String = "", kind: Kind = .string, optional: Bool = false,
             allowsOptionValues: Bool? = nil)
    }
    var name: String                          // the tool's name: letters, digits, _ ("run_tests")
    var description: String                   // for the model and the decider
    var executable: String                    // an absolute path
    var arguments: [String]                   // "{name}" becomes that parameter's value as one argument; a left-out optional
                                              //   parameter's element is dropped, with the flag before it
    var parameters: [Parameter]
    var workingDirectory: String              // where it runs: the only place it may write
    var impact: ToolImpact                    // the user's rating: .read (no ask by default), .mutate, .destructive
    var network: SandboxProfile.Network
    var localPorts: [Int]?
    var timeoutSeconds: Int
    var idleTimeoutSeconds: Int?
    var fingerprints: [String: String]        // SHA-256 of its files in the working or home folder, as last accepted
    var id: String { get }                    // workingDirectory + "|" + name
    init(name: String, description: String, executable: String, arguments: [String] = [], parameters: [Parameter] = [],
         workingDirectory: String, impact: ToolImpact = .mutate, network: SandboxProfile.Network = .none,
         timeoutSeconds: Int = 600, idleTimeoutSeconds: Int? = 120, fingerprints: [String: String]? = nil)
    static func parse(commandLine: String, name: String, description: String, folder: URL, impact: ToolImpact = .mutate,
                      network: SandboxProfile.Network = .none) -> Result<RegisteredCommand, CommandSetupError>
                      // from what the user typed: {name} a parameter, {name?} an optional one; a bare program is found
                      //   on PATH, ./x in `folder`
    func filledArguments(_ values: [String: String]) throws -> [String]   // the argv; throws CommandSetupError
    var displayLine: String { get }           // the command as the user typed it
    func currentFingerprints() -> [String: String]
    var changedFiles: [String] { get }        // files changed, gone or new since it was added or last accepted
    func acceptingChanges() -> RegisteredCommand   // the command with its current files as the new baseline
    static func splitCommandLine(_ line: String) -> [String]   // splits on spaces, keeps quoted parts, expands a leading ~
}
enum CommandSetupError: Error, Sendable, Equatable, CustomStringConvertible {
    case empty
    case badName(String)
    case notExecutable(String)
    case missingArgument(String)              // a required parameter has no value
    case optionLikeValue(String, String)      // (parameter, value): the value starts with "-" and would read as an option
    var description: String { get }
}
struct RegisteredCommandTool: Tool, CallImpactRatedTool, OutboundTool {   // one command as a tool; Output is String
    let name: String
    let description: String                   // the command's, plus "(runs: …)"
    let parameters: GenerationSchema          // from the command's parameters
    let command: RegisteredCommand
    let writesFolder: Bool                    // false in a read-only workspace
    init(command: RegisteredCommand, runner: ProcessCommandRunner, name: String? = nil, writesFolder: Bool = true,
         place: String? = nil) throws
    func call(arguments: GeneratedContent) async throws -> String   // "Ran: … (exit N, size)", the output, any notes;
                                                                     //   values that look like keys are removed
    var impact: ToolImpact { get }            // command.impact
    func callImpact(for arguments: GeneratedContent) -> CallImpact?  // the filled-in argv through CommandRisk: raises the rating
    var sendsDataOut: Bool { get }            // network isn't .none
}
struct CommandsPlugin: ToolPlugin {
    let id: PluginID
    let displayName: String                   // "Commands in foo", or "Commands"
    let card: CapabilityCard                  // lists the commands, so the decider can pick it for "run the tests"
    let commands: [RegisteredCommand]
    let workspaces: [Workspace]?              // set by init(commands:workspaces:runner:)
    var runsExternalPrograms: Bool { get }    // true
    var returnsUntrustedContent: Bool { get } // true: program output is outside content
    var defaultApproval: ToolApproval { get } // .ask(atOrAbove: .mutate, by: .user)
    init(folder: String, commands: [RegisteredCommand], runner: ProcessCommandRunner)   // the commands in one folder
    init(commands: [RegisteredCommand], workspaces: [Workspace], runner: ProcessCommandRunner)
                                              // all commands as one plug-in, each in the workspace holding its folder;
                                              //   same-named commands become one tool with a workspace argument
    var excludedCommands: [(command: RegisteredCommand, reason: String)] { get }   // left out, and why (e.g. a changing
                                                                                   //   command in a read-only workspace)
    func makeTools() -> [any Tool]
    static func grouped(_ commands: [RegisteredCommand], runner: ProcessCommandRunner) -> [CommandsPlugin]   // one per folder
}
```

### Rating a command line

```swift
enum CommandRisk {                            // rules over an argv, and over the commands in an `sh -c` script
    struct Finding: Sendable, Equatable { let impact: ToolImpact; let reason: String }
    static func callImpact(argv: [String]) -> CallImpact?        // the highest finding, or nil
    static func findings(argv: [String]) -> [Finding]            // over-detects: deleting, publishing, sending out, changing the system
    static func findings(script: String) -> [Finding]            // split on ; && || | newlines and $(…); a redirect to a file writes it
    static func isProvablyReadOnly(argv: [String]) -> Bool       // under-allows: true only for programs and arguments known to
}                                                                //   change nothing; scripts and redirects never qualify
```

`findings` and `callImpact` err toward asking; `isProvablyReadOnly` errs toward not trusting, for a harness that wants
to run inspection without asking.

### Local MCP servers (stdio)

A local MCP server is a program the SDK starts and talks to over stdin and stdout, under the same switch and a Seatbelt
profile. The server-management calls are on `lab.mcp` (see [MCP client](#mcp-client)); the types that describe a launch
are here.

```swift
struct MCPStdioLaunch: Codable, Sendable, Equatable {
    var executable: String                    // an absolute path (resolve(_:) finds "npx" on PATH)
    var arguments: [String]
    var environment: [String: String]         // plain settings, saved with the server
    var secretNames: [String]                 // names of variables whose values are in the Keychain
    var workingDirectory: String?             // default: its own folder in ~/Library/Caches/LocalLMLab/mcp
    var network: SandboxProfile.Network       // none by default; many servers need it
    var readable: [String]                    // more paths it may read in the home folder
    var localPorts: [Int]?                    // with .localhost, the ports it may reach; nil: any
    init(executable: String, arguments: [String] = [], environment: [String: String] = [:], secretNames: [String] = [],
         workingDirectory: String? = nil, network: SandboxProfile.Network = .none, readable: [String] = [],
         localPorts: [Int]? = nil)
    var secretInClearRefusal: String? { get } // an argument or plain setting that looks like a key: put it in secrets instead
    var environmentRefusal: String? { get }   // a setting or secret that changes what code runs (see below)
    static func environmentRefusal(names: [String]) -> String?   // PATH, HOME, TMPDIR, NODE_OPTIONS, npm_config_*, PYTHON*,
                                                                 //   PIP_*, UV_*, DYLD_*, LD_* and a few more
    var installerRefusal: String? { get }     // npx, bunx, pnpm dlx, uvx, pipx run without a pinned version (pkg@1.2.3)
    var environmentNames: [String] { get }    // its settings' and secrets' names, sorted (values stay hidden)
    var url: URL { get }                      // its address in the manager: mcp-stdio:<program>?arg=…
    var id: MCPServerID { get }               // url's string
    var displayLine: String { get }           // "npx -y @scope/server@1.2.3"; a key-like argument shows as [key removed]
    var resolvedWorkingDirectory: URL { get }
    static func resolve(_ name: String) -> String?   // as is with a slash, else the first match on the base PATH
}
struct MCPLocalServerStart: Sendable {        // handed to lab.mcp.localServerStartApproval before every start
    enum Reason: Sendable, Equatable {
        case adding                           // the user is adding it (its tools are listed, then it stops)
        case reconnecting                     // the user asked to reconnect it
        case forTurn                          // a turn calls one of its tools and it isn't running
        case afterCrash                       // it stopped unexpectedly and a turn calls it again
    }
    let server: MCPServerID
    let displayName: String
    let launch: MCPStdioLaunch
    let reason: Reason
    let recentCrashes: Int                    // unexpected stops within the crash window
}

// On lab.mcp (MCPServerManager), for reference:
//   addStdioServer(_:displayName:secrets:stayConnected:)  adds one; fails while the switch is off, in a sandboxed process,
//                                                         and for an installer, environment or secret-in-clear refusal
//   externalPrograms: ExternalProgramsSwitch?             the lab's switch; a manager made alone has none, so its local servers never start
//   localServerStartApproval                              asked before every start; without one, adding and reconnecting
//                                                         start it, and a start for a turn or after a crash doesn't
//   localServerCrashLimit / localServerCrashWindow        3 unexpected stops in 300 s and it isn't started again until reconnected
//   stopLocalServers()                                    stops every local server now (their cached tools stay)
```

## Connectors (Calendar, Reminders, Contacts, Location)

The data layer behind the Calendar, Reminders, Contacts and Location tools and plug-ins, all in `LocalLMLabSDKCore`.
Use `Connectors` (or `lab.connectors`) for the permission lifecycle, and each connector's own type for its data.
Reach for these directly only when you write your own tools (Path B); the ready-made tools and plug-ins below already
call them. Setup (usage strings, entitlements) and the permission flow are in
[Connectors](sdk-guide.md#connectors-calendar-reminders-contacts-location) and
[Setup for Calendar and Reminders](sdk-guide.md#setup-for-calendar-and-reminders).

### The permission facade: `Connectors`, `lab.connectors`

The same three calls for all four connectors. `restricted` (new in 3.0) means the Mac's administrator or Screen Time
turned the access off: the user can't turn it on in System Settings, so don't send them there.

```swift
enum Connector: String, CaseIterable, Sendable { case calendar, reminders, contacts, location }
struct ConnectorAccessResult: Sendable {
    var granted: Bool
    var error: String?
    var needsSystemSettings: Bool   // denied before: only System Settings can grant it now
    var restricted: Bool            // turned off by a management profile or Screen Time; default false
}
enum Connectors {
    static func isAuthorized(_ connector: Connector) -> Bool
    // On "granted", returns only once isAuthorized(connector) agrees (the system can report the old status for a moment)
    static func requestAccess(_ connector: Connector) async -> ConnectorAccessResult
    static func isRestricted(_ connector: Connector) -> Bool
    static func openSystemSettings(for connector: Connector)
}

// lab.connectors: the same calls, forwarded to Connectors
@MainActor struct ConnectorsFacade {
    func isAuthorized(_ connector: Connector) -> Bool
    func requestAccess(_ connector: Connector) async -> ConnectorAccessResult
    func openSystemSettings(for connector: Connector)
}
```

### `CalendarAccess`

EventKit events. Changes find an event by its title and the day it is on, not by `eventIdentifier`: some calendar
backends return identifiers long enough to fill a small model's context, and a model copies a title more reliably
than an opaque token.

```swift
enum CalendarAccess {
    nonisolated(unsafe) static var store: EKEventStore { get }   // the raw EventKit store, for anything below doesn't cover; renewed after a fresh grant
    static var authorizationStatus: EKAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> CalendarAccess.AccessResult
    static func openSystemSettings()

    struct EventSummary: Codable {
        var eventIdentifier: String
        var title: String
        var start: String
        var end: String
        var calendar: String
        var location: String?
        var isAllDay: Bool
    }
    static func upcomingEvents(days: Int) -> [CalendarAccess.EventSummary]            // from now; days clamped to 1...30
    static func events(from start: Date, to end: Date) -> [CalendarAccess.EventSummary] // every event overlapping the range, every calendar, earliest first; EventKit answers at most four years per query

    struct AddEventResult { var success: Bool; var error: String? }
    static func addEvent(title: String, start: Date, end: Date) -> CalendarAccess.AddEventResult
    // Whether an event with this title (case-insensitive) is already on `day`: addCalendarEvent mentions it,
    // so "move it to 2pm" asked with only the add tool doesn't silently make a duplicate
    static func hasEvent(titled title: String, on day: Date) -> Bool

    struct MutateEventResult { var success: Bool; var error: String? }
    // Finds the one event with this title on `onDate`; `atTime` (hour and minute, new in 3.0) picks among
    // same-titled events that day by their start. Nil new* parameters leave that field as it is; a new date or
    // a new time alone keeps the event's other component.
    static func updateEvent(title: String, onDate: DateComponents, atTime: DateComponents? = nil, newTitle: String?,
                            newDate: DateComponents?, newTime: DateComponents?, durationMinutes: Int?) -> CalendarAccess.MutateEventResult
    static func deleteEvent(title: String, onDate: DateComponents, atTime: DateComponents? = nil) -> CalendarAccess.MutateEventResult
}
```

### `RemindersAccess`

The same shape as `CalendarAccess`, also on EventKit. A reminder is found by its title, narrowed by its current due
date when several share the title. 3.0 adds open versus completed listings and a `timing` on each summary.

```swift
enum RemindersAccess {
    nonisolated(unsafe) static var store: EKEventStore { get }
    static var authorizationStatus: EKAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> RemindersAccess.AccessResult
    static func openSystemSettings()

    struct ReminderSummary: Codable, Sendable {
        var calendarItemIdentifier: String
        var title: String
        var dueDate: String?
        var list: String
        var isCompleted: Bool
        var priority: Int
        var timing: RemindersAccess.Timing?   // overdue, upcoming or no due date; nil from code that predates it
        var completed: String?                // when it was completed, for a completed reminder
    }
    enum Timing: String, Codable, Sendable { case overdue, upcoming, noDueDate }   // a date-only reminder due today is still upcoming all day

    static func upcomingReminders(days: Int) async -> [RemindersAccess.ReminderSummary]   // openReminders(days: min(days, 30))
    // Overdue (at most 15, most recent first), due in the next `days` (1...366), and undated (at most 15)
    static func openReminders(days: Int) async -> [RemindersAccess.ReminderSummary]
    static func completedReminders(days: Int) async -> [RemindersAccess.ReminderSummary]  // completed in the last `days` (1...366), most recent first
    // The due dates of open reminders with this title (nil for one with no due date): addReminder mentions them
    static func openReminders(titled title: String) async -> [String?]

    struct AddReminderResult { var success: Bool; var error: String? }
    static func addReminder(title: String, dueDateComponents: DateComponents?) -> RemindersAccess.AddReminderResult

    struct MutateReminderResult {
        var success: Bool
        var error: String?
        var note: String?   // something to pass on although the change applied (a due date filled in because it had none)
        init(success: Bool, error: String? = nil, note: String? = nil)
    }
    // Finds the reminder by title, narrowed by its current due date; nil new* parameters leave that field as it is,
    // and a new date or time alone keeps the other component. isCompleted marks it done or open again.
    static func updateReminder(title: String, dueDate: DateComponents?, newTitle: String?, newDate: DateComponents?,
                               newTime: DateComponents?, isCompleted: Bool?) async -> RemindersAccess.MutateReminderResult
    static func deleteReminder(title: String, dueDate: DateComponents?) async -> RemindersAccess.MutateReminderResult
}
```

### `ContactsAccess`

A contact is found by its given name, narrowed by its family name. 3.0 adds postal addresses and handles people who
share a name: each such contact is a numbered card ("card 1 of 2", counted the same way on every call), `card` picks
one, `allCards` changes all of them, and `pinned` holds the identifiers of the cards the user's confirmation named,
so those are the ones changed even if another card with the name appeared while the user decided.

```swift
enum ContactsAccess {
    nonisolated(unsafe) static var store: CNContactStore { get }   // the raw Contacts store; renewed after a fresh grant
    static var authorizationStatus: CNAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> ContactsAccess.AccessResult
    static func openSystemSettings()

    struct ContactSummary: Codable {
        var identifier: String
        var name: String
        var givenName: String
        var familyName: String?
        var organization: String?
        var phoneNumbers: [String]
        var emails: [String]
        var addresses: [String]?   // postal addresses, one line each; nil from code that predates them
        var card: Int?             // this contact's number among those with exactly its name; nil when the name is unique
        var cardsWithName: Int?    // how many share the name; only in what the tools say, nothing is written to Contacts
    }
    // A name (accents and letters such as Ø read as plain Latin when Contacts' own search finds nothing),
    // a whole phone number, or an email address
    static func search(query: String, limit: Int) -> [ContactsAccess.ContactSummary]
    static func list(limit: Int) -> [ContactsAccess.ContactSummary]
    static func countContacts(givenName: String, familyName: String?) -> Int   // how many already have exactly this name (addContact says so)
    static func cardNumber(of identifier: String, givenName: String, familyName: String?) -> (card: Int, of: Int)?   // nil when the name is unique or not found

    struct MutateContactResult {
        var success: Bool
        var error: String?
        var changed: Int          // contacts changed: more than 1 when allCards changed every card with the name
        var identifier: String?   // the new contact's, from addContact
    }
    // Each address on one line ("12 Elm Street, Springfield, IL 62701"), split into its parts where the system recognizes them
    static func addContact(givenName: String, familyName: String, organization: String?, phoneNumbers: [String],
                           emails: [String], addresses: [String] = []) -> ContactsAccess.MutateContactResult
    // Nil new* parameters leave that field as it is; a non-nil new* list replaces the contact's whole list, and
    // add* lists go alongside what it has (an entry it already has isn't added twice). `card` picks one of several
    // contacts with the name, `allCards` takes them all; without either, the error lists each card's details.
    static func updateContact(givenName: String, familyName: String?, newGivenName: String?, newFamilyName: String?,
                              newOrganization: String?, newPhoneNumbers: [String]?, newEmails: [String]?,
                              newAddresses: [String]? = nil, addPhoneNumbers: [String] = [], addEmails: [String] = [],
                              addAddresses: [String] = [], card: Int? = nil, allCards: Bool = false,
                              pinned: [String]? = nil) -> ContactsAccess.MutateContactResult
    static func deleteContact(givenName: String, familyName: String?, card: Int? = nil,
                              pinned: [String]? = nil) -> ContactsAccess.MutateContactResult   // one card at a time
}
```

### `LocationAccess`

A class with a shared instance, not a static enum, because it holds `CLLocationManagerDelegate` state.

```swift
final class LocationAccess: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared: LocationAccess
    var authorizationStatus: CLAuthorizationStatus { get }
    var isAuthorized: Bool { get }
    var lastFetchFailureReason: String? { get }   // why the last currentLocation() returned nil
    struct AccessResult: Sendable { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    @MainActor func requestAccess() async -> LocationAccess.AccessResult
    static func openSystemSettings()
    struct LocationSummary: Codable {
        var latitude: Double
        var longitude: Double
        var horizontalAccuracyMeters: Double
        var timestamp: String
        var placeName: String?
    }
    func currentLocation() async -> LocationAccess.LocationSummary?
}
```

## Ready-made connector Tools (Path A)

Thin `Tool` wrappers around the connectors above, in `LocalLMLabSDKCore`. Pass them to `makeSession(tools:)` one by
one, or add the plug-in that groups them (`CalendarPlugin`, `RemindersPlugin`, `ContactsPlugin`, `LocationPlugin`, in
[Built-in plug-ins](#built-in-plug-ins)) so the tool picker offers them only when a message needs them. See
[Two paths to tool-calling](sdk-guide.md#two-paths-to-tool-calling-ready-made-tools-or-write-your-own) for Path A
versus Path B.

Every tool here has the same shape: `static let defaultDescription: String`, `let name: String`,
`let description: String` (yours when you pass one, else the default) and `init(description: String? = nil)`. Each is
an `ImpactRatedTool`; the rating is in the comment on its declaration. Dates are `yyyy-MM-dd` and times 24-hour `HH:mm`.
A tool that can't do what was asked returns an error the model can read rather than throwing.

```swift
// Calendar ---------------------------------------------------------------
struct GetUpcomingEventsTool: Tool {                // impact .read
    let name = "getUpcomingEvents"
    struct Arguments {
        var days: Int?     // default 7; more than 366 is cut to 366 and said; at most 100 events listed, the rest counted
        var from: String?  // first day to look from (may be in the past); omit to start now
        init(days: Int? = nil, from: String? = nil)
    }
}
struct AddCalendarEventTool: Tool {                 // impact .mutate; says so when an event with the title is already on that day
    let name = "addCalendarEvent"
    struct Arguments {
        var title: String
        var date: String
        var time: String
        var durationMinutes: Int?   // default 60; none, negative or past a week is refused, not clamped
        init(title: String, date: String, time: String, durationMinutes: Int? = nil)
    }
}
struct UpdateCalendarEventTool: Tool {              // impact .mutate
    let name = "updateCalendarEvent"
    struct Arguments {
        var title: String           // exactly as getUpcomingEvents showed it
        var currentDate: String     // the day the event is on now: finds it, never the destination
        var currentTime: String?    // its start now; only when two events with the title are on that day
        var newTitle: String?
        var newDate: String?
        var newTime: String?
        var durationMinutes: Int?   // each new* field is independently optional; omitted ones stay as they are
        init(title: String, currentDate: String, currentTime: String? = nil, newTitle: String? = nil,
             newDate: String? = nil, newTime: String? = nil, durationMinutes: Int? = nil)
    }
}
struct DeleteCalendarEventTool: Tool {              // impact .destructive
    let name = "deleteCalendarEvent"
    struct Arguments {
        var title: String
        var currentDate: String
        var currentTime: String?    // as in updateCalendarEvent
        init(title: String, currentDate: String, currentTime: String? = nil)
    }
}

// Reminders: the same title / currentDate / new* shape; currentDate is optional (a reminder may have no due date)
struct GetUpcomingRemindersTool: Tool {             // impact .read
    let name = "getUpcomingReminders"
    struct Arguments {
        var days: Int?      // default 7, at most 366: ahead for open reminders, back for completed ones
        var status: String? // "open" (default: overdue, upcoming and undated) or "completed"
        init(days: Int? = nil, status: String? = nil)
    }
}
struct AddReminderTool: Tool {                      // impact .mutate; mentions an open reminder that already has the title
    let name = "addReminder"
    struct Arguments {
        var title: String
        var date: String?   // omit for no due date
        var time: String?   // omit for a date-only reminder
        init(title: String, date: String? = nil, time: String? = nil)
    }
}
struct UpdateReminderTool: Tool {                   // impact .mutate
    let name = "updateReminder"
    struct Arguments {
        var title: String
        var currentDate: String?   // only to tell same-titled reminders apart
        var newTitle: String?
        var newDate: String?
        var newTime: String?
        var isCompleted: Bool?     // true marks it done, false open again
        init(title: String, currentDate: String? = nil, newTitle: String? = nil, newDate: String? = nil,
             newTime: String? = nil, isCompleted: Bool? = nil)
    }
}
struct DeleteReminderTool: Tool {                   // impact .destructive
    let name = "deleteReminder"
    struct Arguments {
        var title: String
        var currentDate: String?
        init(title: String, currentDate: String? = nil)
    }
}

// Contacts: currentGivenName / currentFamilyName find the contact; `card` picks one of several with that name
// ("card N of M" in search and list results)
struct SearchContactsTool: Tool {                   // impact .read
    let name = "searchContacts"
    struct Arguments {
        var query: String   // a name or part of one, or a whole phone number or email address
        var limit: Int?     // default 10, capped at 50
        init(query: String, limit: Int? = nil)
    }
}
struct ListContactsTool: Tool {                     // impact .read
    let name = "listContacts"
    struct Arguments {
        var limit: Int?     // default 50, capped at 200
        init(limit: Int? = nil)
    }
}
struct AddContactTool: Tool {                       // impact .mutate; says when the name is already taken, with the new card's number
    let name = "addContact"
    struct Arguments {
        var givenName: String
        var familyName: String?
        var organization: String?
        var phoneNumbers: [String]?
        var emails: [String]?
        var addresses: [String]?   // postal addresses, one line each
        init(givenName: String, familyName: String? = nil, organization: String? = nil, phoneNumbers: [String]? = nil,
             emails: [String]? = nil, addresses: [String]? = nil)
    }
}
// impact .mutate; also a CallImpactRatedTool: .destructive when a new* list would take something off a card,
// and the confirmation names the card(s) it changes, which are then the ones changed
struct UpdateContactTool: Tool {
    let name = "updateContact"
    struct Arguments {
        var currentGivenName: String     // the "given:" value from search/list output, not the display name
        var currentFamilyName: String?
        var newGivenName: String?
        var newFamilyName: String?
        var newOrganization: String?
        var newPhoneNumbers: [String]?   // new* lists replace the contact's whole list
        var newEmails: [String]?
        var newAddresses: [String]?
        var addPhoneNumbers: [String]?   // add* lists go alongside what it has
        var addEmails: [String]?
        var addAddresses: [String]?
        var card: Int?                   // which of several contacts with this name
        var allCards: Bool?              // true: the same change to every contact with this name
        init(currentGivenName: String, currentFamilyName: String? = nil, newGivenName: String? = nil,
             newFamilyName: String? = nil, newOrganization: String? = nil, newPhoneNumbers: [String]? = nil,
             newEmails: [String]? = nil, newAddresses: [String]? = nil, addPhoneNumbers: [String]? = nil,
             addEmails: [String]? = nil, addAddresses: [String]? = nil, card: Int? = nil, allCards: Bool? = nil)
    }
}
struct DeleteContactTool: Tool {                    // impact .destructive; the confirmation names the card and its details
    let name = "deleteContact"
    struct Arguments {
        var currentGivenName: String
        var currentFamilyName: String?
        var card: Int?
        init(currentGivenName: String, currentFamilyName: String? = nil, card: Int? = nil)
    }
}

// Location: the one connector tool with no writable counterpart
struct GetCurrentLocationTool: Tool {               // impact .read
    let name = "getCurrentLocation"
    struct Arguments { init() }
}
```

## Built-in plug-ins

New in 3.0, in `LocalLMLabSDKCore`. Each plug-in is a `ToolPlugin` that groups a few of the SDK's ready-made tools
under one card, so the tool picker chooses "Calendar" for a message rather than one of four calendar tools by name.
Add them to the catalog with `lab.tools.add(_:enabled:)`; the protocol and the catalog are in
[Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker), and the guide's
[Tools: available, not attached](sdk-guide.md#tools-available-not-attached-30) explains the model. The tools are the
same types as when you pass them one by one.

Every plug-in has `let id: PluginID`, `let displayName: String`, a `card: CapabilityCard` (what the picker reads) and
`func makeTools() -> [any Tool]`. The members below are the ones that differ. A plug-in with
`requiredPermissions` never asks for them itself: the permission is checked when one of its tools is chosen or called.
`returnsUntrustedContent` is true for the plug-ins that bring in outside content (files, pages, images): with
`LocalLMLabSession.framesUntrustedContent` on, their results reach the model framed as data
([Content is content](security-guide-for-hosts.md#5-content-is-content)). Where a plug-in sets no `defaultApproval`,
the protocol's default applies: ask the user at `.mutate` and above.

```swift
// --- no permission -------------------------------------------------------
struct ClockPlugin: ToolPlugin {        // id "locallmlab.clock", "Clock"
    init()                              // tools: getCurrentTime (ClockTool), which takes an optional timeZone
}
struct WeatherPlugin: ToolPlugin {      // id "locallmlab.weather", "Weather"; the model names the place, no location permission
    init()                              // tools: getWeather (WeatherTool); sends the place name to Open-Meteo
}

// --- connectors: one system permission each --------------------------------
struct CalendarPlugin: ToolPlugin {     // id "locallmlab.calendar", "Calendar"
    let requiredPermissions: Set<PluginPermission>   // [.calendar]
    init()                              // tools: getUpcomingEvents, addCalendarEvent, updateCalendarEvent, deleteCalendarEvent
}                                       // all four always offered together, so a change can't become a second event
struct RemindersPlugin: ToolPlugin {    // id "locallmlab.reminders", "Reminders"
    let requiredPermissions: Set<PluginPermission>   // [.reminders]
    // listNames: the user's reminder lists, each naming the plug-in as "<list> list" ("Groceries list"), so
    // "add milk to my Groceries list" selects it. nil: read from Reminders when access is already granted (never asks).
    init(listNames: [String]? = nil)    // tools: getUpcomingReminders, addReminder, updateReminder, deleteReminder (always together)
}
struct ContactsPlugin: ToolPlugin {     // id "locallmlab.contacts", "Contacts"
    let requiredPermissions: Set<PluginPermission>   // [.contacts]
    init()                              // tools: searchContacts, listContacts, addContact, updateContact, deleteContact (always together)
}
struct LocationPlugin: ToolPlugin {     // id "locallmlab.location", "Location": the Mac's location, for "where I am", "near me"
    let requiredPermissions: Set<PluginPermission>   // [.location]
    init()                              // tools: getCurrentLocation
}

// --- files ---------------------------------------------------------------
// Files over the user's workspaces and a chat's own folder (scratch). The plug-in for a chat app.
struct WorkspacesPlugin: ToolPlugin {   // id "locallmlab.files", "Files"; returnsUntrustedContent
    let defaultApproval: ToolApproval   // .ask(atOrAbove: .destructive, by: .user): the calls each workspace's access raises
    let workspaces: [Workspace]         // scratch first (when given), then yours in order; a repeated id is dropped
    let limits: WorkspaceAccess.WorkspaceLimits
    let offLimits: [String]             // never listed, read or written in any workspace
    let defaultWorkspace: String?       // where a read or search looks when no place is named; writes still go to scratch
    init(scratch: URL?, workspaces: [Workspace], defaultWorkspace: String? = nil,
         limits: WorkspaceAccess.WorkspaceLimits = .default, offLimits: [String] = WorkspaceAccess.defaultOffLimits)
    func workspace(named name: String) -> Workspace?   // the workspace a call names, for a confirmation sheet
}
// Its tools take the place as an argument limited to names that exist ("what first, then where"):
//   listFiles(workspace?, path?, depth?)              .read: a place, or the places themselves when none is named
//   searchFiles(query, workspace?, include?)          .read: contents and names, across every place unless one is named
//   readFile(workspace, path, fromLine?, lineCount?)  .read
//   writeFile, editFile, deleteFile, copyFile         offered only when some place can be changed, and only for those places
// Access is enforced by the tools, not the prompt (see Saved workspaces): a write to a read-only workspace is refused;
// scratch never asks; .askBeforeChanges asks for every change; .readWrite runs creates, edits and deletes (deleteFile
// moves the file to the Trash) and asks only for an overwrite whose old version can't be kept. An overwrite in a
// user's workspace first copies the old version into scratch, and replaces only a file read in full since it changed.

// One folder, the older single-root shape (the tools in "Filesystem workspace" below)
struct WorkspacePlugin: ToolPlugin {    // id "locallmlab.workspace", "Files"; returnsUntrustedContent
    enum Access: Sendable, Equatable { case readOnly, readWrite }
    let root: URL
    let access: WorkspacePlugin.Access
    let limits: WorkspaceAccess.WorkspaceLimits
    init(root: URL, access: WorkspacePlugin.Access = .readOnly, limits: WorkspaceAccess.WorkspaceLimits = .default)
    // tools: listWorkspaceFiles, workspaceTree, searchWorkspace, readWorkspaceFile, readFileRange;
    // .readWrite adds writeWorkspaceFile, editWorkspaceFile, applyPatch, deleteWorkspaceFile
}

// --- content: documents, tables, images, web pages -------------------------
// `root` is the chat's files folder (attachments, saved pages, results). Paths may start with a workspace's name
// ("project/notes.md"); a path not in root is looked for in defaultWorkspace, then in the one workspace that has it.
struct DocumentsPlugin: ToolPlugin {    // id "locallmlab.documents", "Documents"; returnsUntrustedContent
    let root: URL
    let canWrite: Bool                  // false leaves out writeDocument (and changes the card's summary)
    let limits: WorkspaceAccess.WorkspaceLimits
    let pdf: PDFReading                 // how PDFs are read, including whether scanned or tabular pages go to Vision
    var defaultApproval: ToolApproval { get }   // .ask(atOrAbove: .destructive, by: .user): asks only to overwrite, or in an ask-before-changes workspace
    let workspaces: [Workspace]         // writing follows each workspace's access
    let defaultWorkspace: String?
    var card: CapabilityCard { get }    // text, Markdown, PDF, HTML, RTF and .docx attachments select it
    init(root: URL, canWrite: Bool = true, limits: WorkspaceAccess.WorkspaceLimits = .default, pdf: PDFReading = .default,
         workspaces: [Workspace] = [], defaultWorkspace: String? = nil)
    // tools: documentOutline, readDocument, searchDocument, writeDocument (create-only unless overwrite)
}
struct TablesPlugin: ToolPlugin {       // id "locallmlab.tables", "Tables"; returnsUntrustedContent
    let root: URL                       // holds the SQLite file and the result CSVs
    let includeDataVerbs: Bool          // true adds the step-by-step verbs, for models that do better without SQL
    var defaultApproval: ToolApproval { get }   // .ask(atOrAbove: .destructive, by: .user): it writes only in root and has no delete
    let workspaces: [Workspace]         // loadTable reads "workspace/path"; tables and results stay in root
    let defaultWorkspace: String?
    init(root: URL, includeDataVerbs: Bool = false, workspaces: [Workspace] = [], defaultWorkspace: String? = nil)
    // tools: loadTable, sqlQuery (always together); with includeDataVerbs also csvInfo, describeJson, jsonToCsv,
    // selectColumns, filterRows, sortRows, dedupeRows, concatRows, aggregateRows. CSV, TSV and JSON attachments select it.
}
struct ImagesPlugin: ToolPlugin {       // id "locallmlab.images", "Images"; returnsUntrustedContent; an attached image selects it
    let root: URL
    let workspaces: [Workspace]
    let defaultWorkspace: String?
    let looker: (any ImageLooking)?     // a model that also looks at photos; nil (default) reads text only
    var defaultApproval: ToolApproval { get }   // .ask(atOrAbove: .destructive, by: .user): it only reads
    init(root: URL, workspaces: [Workspace] = [], defaultWorkspace: String? = nil, looker: (any ImageLooking)? = nil)
    static func onDeviceLooker() -> (any ImageLooking)?   // OnDeviceImageLooker when Apple's on-device model can see here, else nil
    // tools: readImageText
}
struct WebPlugin: ToolPlugin {          // id "locallmlab.web", "Web"; returnsUntrustedContent; a link in the message selects it
    let root: URL                       // where fetched pages are saved as Markdown
    let options: WebReadingOptions
    var defaultApproval: ToolApproval { get }   // .ask(atOrAbove: .destructive, by: .user): reading changes nothing, saving stays in root
    init(root: URL, options: WebReadingOptions = WebReadingOptions())
    // tools: fetchWebPage, searchWebPage, readWebPage (sharing one rate limit and page cache)
}
```

The content plug-ins' tools and types are in [Web, documents, images and tables](#web-documents-images-and-tables);
`Workspace` and the saved list behind `WorkspacesPlugin` are in [Saved workspaces](#saved-workspaces).

## Web, documents, images and tables

The tools and building blocks behind `WebPlugin`, `DocumentsPlugin`, `ImagesPlugin` and `TablesPlugin`, all in
`LocalLMLabSDKCore`. Most apps add the plug-in and never touch these; reach for them to read a page, a document or an
image in your own code, or to pass a single tool to a static session. Every result that carries outside content is
content, not instructions: see [Content is content](security-guide-for-hosts.md#5-content-is-content) and the limits
in [Limits](security-guide-for-hosts.md#7-limits).

### Web pages: `WebFetcher`, `WebPageExtractor`, `WebAddressPolicy`

`WebPlugin`'s pipeline: fetch one page under fixed limits, turn its HTML into Markdown, save it in the plug-in's
folder and return the start of it. The model reads the rest with `searchWebPage` and `readWebPage`, so a long page
never has to fit in the prompt. Plain HTML only: a page built by JavaScript comes back nearly empty.

```swift
// Which addresses a fetch may reach. Refused: loopback, private and carrier-grade NAT ranges, link-local (cloud
// metadata included), multicast and reserved ranges, their IPv6 forms, and localhost / .local names. IP literals
// are read in any spelling the network stack accepts; a name is checked by resolving it.
enum WebAddressPolicy {
    // Why `url` may not be fetched, or nil when it may. allowPrivate: the user typed this URL and the app
    // lets typed URLs reach private addresses (a router page, a local dev server). Only http and https.
    static func refusal(for url: URL, allowPrivate: Bool = false) -> String?
    static func isPublicAddress(_ text: String) -> Bool   // a numeric address, as the connection reports it
}

// GET only; no cookies, stored credentials or shared cache; redirects followed by hand, each hop checked against
// WebAddressPolicy; the address actually connected to checked again after the fetch; text types only.
struct WebFetcher: Sendable {
    var timeout: Duration                 // default 15 s
    var maxBytes: Int                     // default 10,000,000; a longer page is read up to it and marked truncated
    var maxRedirects: Int                 // default 5
    var userAgent: String
    static let textTypes: Set<String>     // text/html, application/xhtml+xml, text/plain, text/markdown
    init()
    // allowPrivate applies to the first address only, never to a redirect
    func fetch(_ url: URL, allowPrivate: Bool = false) async throws -> WebFetchResult   // throws WebFetchError
}
struct WebFetchResult: Sendable {
    let url: URL                          // after redirects
    let contentType: String               // MIME type, lowercased, without parameters
    let encoding: String.Encoding
    let data: Data
    var truncated: Bool                   // longer than WebFetcher.maxBytes and cut there
    init(url: URL, contentType: String, encoding: String.Encoding, data: Data, truncated: Bool = false)
}
enum WebFetchError: Error, Sendable, Equatable, CustomStringConvertible {   // description is worded for the model and the user
    case refused(String)                  // WebAddressPolicy said no
    case tooManyRedirects
    case notText(contentType: String)
    case tooLarge(limit: Int)
    case http(status: Int)
    case failed(String)
    var description: String { get }
}

// A page's readable text as Markdown
struct WebPage: Sendable, Equatable {
    let url: URL
    let title: String?
    let markdown: String
    var links: [WebPage.Link]             // every link, navigation included, in page order; no fragments, mailto:, javascript: or tracking redirects
    struct Link: Sendable, Equatable { let text: String; let url: URL }
    init(url: URL, title: String?, markdown: String, links: [WebPage.Link] = [])
}
// Drops scripts, styles, navigation, headers, footers, asides, forms and visually hidden text; picks the main
// content (an article, main, or the element with the most paragraph text); converts headings, paragraphs, lists,
// links, code, quotes and tables.
enum WebPageExtractor {
    static func page(from result: WebFetchResult) -> WebPage
}

// The Web plug-in's limits, all the host's
struct WebReadingOptions: Sendable {
    var inlineCharacters: Int             // page text a fetch returns (default 8,000); the whole page is always saved
    var maxFetchesPerMinute: Int          // default 10, across the plug-in's tools
    var maxPagesPerTurn: Int              // new pages one turn may read (default 8; cached pages don't count)
    var fullPagesPerTurn: Int             // new pages of a turn that return their text (default 3); later ones return an outline
    var maxLinksListed: Int               // links listed after the text, same site first (default 40)
    var allowPrivateAddressesTypedByUser: Bool   // default false: a typed link to 192.168.1.1 is refused like any other
    var cacheFor: Duration                // how long a fetched page is reused (default 600 s)
    var fetcher: WebFetcher
    init()
}
```

The three tools are made only by `WebPlugin` (no public initializer), so they share its rate limit, page cache and
per-turn count. All three are rated `.read`.

```swift
struct FetchWebPageTool: Tool {
    let name = "fetchWebPage"
    struct Arguments { var url: String }   // the page's full URL
}
// Refused without fetching: a URL nobody gave the model that carries data in it (it could send information out);
// a link found on a page that goes to another site (the user must type it); a consent wall instead of the content.
struct SearchWebPageTool: Tool {
    let name = "searchWebPage"
    struct Arguments { var file: String; var query: String }   // file: the saved page's name, as fetchWebPage gave it
}
struct ReadWebPageTool: Tool {
    let name = "readWebPage"
    struct Arguments { var file: String; var section: String?; var fromLine: Int?; var toLine: Int? }   // a section by heading, or lines
}
```

Which links in a reply came from the user, from content or from nowhere (`LinkSource`, `ReplyLinks`) is in
[Tool authority](#tool-authority-toolcallauthorizer-toolimpact-confirmation).

### Documents: `Documents`, `DocumentContent`, `PDFReading`

`DocumentsPlugin` reads text, Markdown, PDF, HTML, RTF and Word `.docx` files behind four tools. A document is read
once into lines with an outline (Markdown headings or a PDF's bookmarks), so the model asks for its outline first and
then reads only the part it needs. HTML, RTF and `.docx` are converted to Markdown. A PDF page whose text layer is
empty, too short for what is on the page, or tabular goes to Vision's document recognition.

```swift
struct DocumentContent: Sendable, Equatable {
    enum Format: String, Sendable { case markdown, text, pdf, html, rtf, docx }   // html, rtf, docx: converted to Markdown
    struct Page: Sendable, Equatable {    // a PDF page's lines, from its <!-- page N --> marker; 1-based
        enum Source: String, Sendable {
            case textLayer                // PDFKit's text layer
            case vision                   // Vision's document recognition (or OCR): a scanned, sparse or tabular page
            case unread                   // no text could be read
        }
        let number: Int
        let startLine: Int
        let endLine: Int
        let source: DocumentContent.Page.Source
    }
    struct Section: Sendable, Equatable { // a heading through the line before the next of the same or higher level
        let level: Int
        let title: String
        let startLine: Int                // 1-based
        let endLine: Int
    }
    let format: DocumentContent.Format
    let lines: [String]
    let sections: [DocumentContent.Section]   // Markdown headings, or a PDF's bookmarks
    let pages: [DocumentContent.Page]         // a PDF's pages; empty for other formats
    var notes: [String]                       // what a conversion left out or simplified
    var pagesInFile: Int?                     // a PDF's page count when it has more than were read (PDFReading.maxPages)
    var pagesNotRead: String? { get }         // what the outline and a search say about those pages
    var text: String { get }                  // lines joined with "\n"
    var estimatedTokens: Int { get }          // characters / 4: whether to put it in the prompt whole or read it through the tools
}

enum Documents {
    static let markdownExtensions: Set<String>   // md, markdown, mdown, mkd, mkdn; other UTF-8, UTF-16 or Windows-1252 text reads as plain text
    static let writableExtensions: Set<String>   // what writeDocument can produce: md, markdown, txt
    // Where `path` is: in a workspace when it starts with that workspace's name and root has nothing by that name,
    // else under root; an absolute path in the workspace that holds it; a path not in root is looked for in
    // defaultWorkspace, then in the one workspace that has it
    static func locate(_ path: String, root: URL, workspaces: [Workspace], defaultWorkspace: String? = nil) -> (root: URL, path: String)
    // Reads and parses one file with the workspace tools' confined access. Refused: larger than limits.maxFileBytes,
    // or neither text nor a PDF. PDFs are cached by file identity and modification time.
    static func load(in root: URL, path: String, limits: WorkspaceAccess.WorkspaceLimits = .default,
                     pdf reading: PDFReading = .default) async throws -> DocumentContent
    static func parse(_ text: String, format: DocumentContent.Format) -> DocumentContent   // lines, and Markdown's headings
}

struct PDFReading: Sendable, Equatable {
    var useVision: Bool                   // send scanned, sparse or tabular pages to Vision; off: the text layer as is
    var maxVisionPages: Int               // per document; pages past it keep their text layer and are marked
    var renderDPI: CGFloat                // resolution pages are rendered at for Vision
    var maxPages: Int                     // pages read from one document; the rest skipped and said
    init(useVision: Bool = true, maxVisionPages: Int = 60, renderDPI: CGFloat = 200, maxPages: Int = 500)
    static let `default`: PDFReading
    // Loads Vision's text-recognition models so the first scanned page isn't the one that waits (the first call
    // after login can take many seconds). Call it off the critical path, at launch.
    static func prewarmTextRecognition() async
}
```

The tools share one initializer:
`init(root: URL, description: String? = nil, limits: WorkspaceAccess.WorkspaceLimits = .default, pdf: PDFReading = .default, workspaces: [Workspace] = [], defaultWorkspace: String? = nil)`,
with `static let defaultDescription`, `let name` and `let description` as the connector tools have. Paths are
resolved with `Documents.locate`, and off-limits paths (`WorkspaceAccess.defaultOffLimits`) are refused.

```swift
struct DocumentOutlineTool: Tool {        // impact .read; a document one read would return whole comes back whole
    let name = "documentOutline"
    struct Arguments { var path: String; init(path: String) }
}
struct ReadDocumentTool: Tool {           // impact .read
    let name = "readDocument"
    static let maxLines: Int              // 400: one read returns at most this many lines...
    static let maxCharacters: Int         // ...or 8,000 characters, whichever comes first
    struct Arguments {
        var path: String
        var section: String?              // a heading from documentOutline, or for a PDF "page 3" / "pages 3-5"
        var fromLine: Int?                // ignored when section is set
        var toLine: Int?                  // inclusive
        init(path: String, section: String? = nil, fromLine: Int? = nil, toLine: Int? = nil)
    }
}
struct SearchDocumentTool: Tool {         // impact .read; ignores case; hits with line, section and a snippet
    let name = "searchDocument"
    struct Arguments { var path: String; var query: String; var maxResults: Int?   // default 20
                       init(path: String, query: String, maxResults: Int? = nil) }
}
// impact .mutate; also a CallImpactRatedTool: .destructive to overwrite an existing document, or for any write in an
// ask-before-changes workspace. Writes where the read tools would read the same path, and says where.
struct WriteDocumentTool: Tool {
    let name = "writeDocument"
    struct Arguments {
        var path: String                  // ending in .md or .txt; a workspace's name first to write in that folder
        var content: String
        var overwrite: Bool?              // default false: fails if the file exists
        init(path: String, content: String, overwrite: Bool? = nil)
    }
}
```

### Images: `ImageText`, `ImageLooking`, `ReadImageTextTool`

`ImagesPlugin` reads the text in photos, screenshots and slides with Vision. A photo keeps only the subject in the
middle and marks uncertain lines; a screenshot or slide is read as a document; a terminal or editor is read line by
line. With a `looker`, a model that sees also describes a photo, or lays out a diagram, chart or screenshot whose
words still come from text recognition. Without one, every result says the picture itself wasn't seen.

```swift
enum ImageText {                          // Vision text recognition
    struct Line: Sendable, Equatable {
        var text: String
        var box: CGRect                   // normalized, origin at the bottom left
        var confidence: Float
        init(text: String, box: CGRect, confidence: Float)
    }
    enum Kind: String, Sendable {
        case photo                        // a camera photo: only the subject in the middle is kept
        case document                     // a screenshot, a slide or a scan
        case code                         // a terminal or an editor, read line by line
    }
    struct Reading: Sendable, Equatable {
        var kind: ImageText.Kind
        var text: String                  // in reading order; empty when none was found
        var leftOut: Int                  // a photo's lines left out: cut off at its edges, or spanning several items
        var lines: Int                    // lines found in the whole image
        var worthALook: Bool { get }      // a photo, or an image with almost no text: worth asking a looker about
    }
    static func read(_ data: Data) async throws -> ImageText.Reading   // an image file's bytes; orientation applied, large photos scaled down
    static func decode(_ data: Data) throws -> (image: SendableImage, fromCamera: Bool)   // decoded once, for reading and for a looker
}

// Something that looks at an image for a model that can't see
protocol ImageLooking: Sendable {
    // What the image says and shows (.read) or how it's laid out (.layout); `question`, when given, is answered from the image alone
    func look(at image: SendableImage, question: String?, purpose: ImageLookPurpose) async throws -> ImageLookResult
    var name: String { get }              // a short name for the reader, in the tool's result ("the on-device model")
}
enum ImageLookPurpose: Sendable, Equatable {
    case read                             // a photo or a scene: its text line by line, and what it shows
    case layout                           // a diagram, chart, slide or screenshot: shapes, groups, lines and arrows only
}
struct ImageLookResult: Sendable, Equatable {
    var text: [String]
    var picture: String
    var answer: String?
    init(text: [String], picture: String, answer: String? = nil)
}
struct SendableImage: @unchecked Sendable { let image: CGImage; init(_ image: CGImage) }   // a CGImage is immutable
struct ImageLookingError: Error, CustomStringConvertible { let description: String }   // the tool says so and returns text recognition alone

// Apple's on-device model, one image per session of its own: no tools, a capped reply, a slow look abandoned
struct OnDeviceImageLooker: ImageLooking {
    let name: String                      // "the on-device model"
    var timeout: Duration
    var maximumResponseTokens: Int
    init(timeout: Duration = .seconds(20), maximumResponseTokens: Int = 400)
    static var isAvailable: Bool { get }  // the on-device model is available here and sees images (Apple Intelligence on, macOS 27)
    func look(at image: SendableImage, question: String?, purpose: ImageLookPurpose) async throws -> ImageLookResult
}

struct ReadImageTextTool: ImpactRatedTool {   // impact .read
    var impact: ToolImpact { get }
    let name: String                      // "readImageText"
    var description: String { get }       // says whether the picture is seen, by whether there is a looker
    init(root: URL, workspaces: [Workspace] = [], defaultWorkspace: String? = nil, looker: (any ImageLooking)? = nil)
    struct Arguments {
        var path: String                  // an attachment's name, or a path in a workspace
        var question: String?             // a detail to ask about; empty to read it
        init(path: String, question: String? = nil)
    }
}
```

### Tables: `loadTable`, `sqlQuery`, the data verbs, `CSVCodec`

`TablesPlugin`'s two-tool path: `loadTable` turns a JSON (or CSV/TSV) file of records into an SQLite table in
`<root>/aiql.sqlite` and returns its `CREATE TABLE`; `sqlQuery` runs one read-only `SELECT` and writes the result to a
CSV. The model sees schemas and a receipt (columns, row count, first rows), never the rows. The data verbs do the same
work step by step, each reading one file and writing a CSV. See
[`FileBackedTool` and the data verbs](sdk-guide.md#filebackedtool--the-aiql-data-verbs-a-mechanical-mcp-dataset--csv-pipeline)
for the pipeline, which starts with an MCP tool's `saveAs` (`FileBackedTool`, under the filesystem workspace below).
Every tool here has `static let defaultDescription`, `let name` and `let description`; an output path is checked
against `SaveAsPolicy.dataOutput` (data extensions only, no hidden paths).

```swift
struct LoadTableTool: Tool {              // impact .mutate (writes aiql.sqlite)
    let name = "loadTable"
    init(root: URL, description: String? = nil, workspaces: [Workspace] = [], defaultWorkspace: String? = nil)   // "workspace/path" reads there; the table stays in root
    struct Arguments {
        var jsonPath: String              // the JSON or CSV file, relative to the workspace root
        var tableName: String             // letters, digits, underscore; starts with a letter
        var recordsAt: String             // path to the records array ("data.items"); "" auto-detects (ignored for a CSV)
        init(jsonPath: String, tableName: String, recordsAt: String = "")
    }
}
struct SQLQueryTool: Tool {               // impact .mutate (writes the CSV); the database is opened read-only, anything but SELECT is blocked
    let name = "sqlQuery"
    init(root: URL, description: String? = nil)
    struct Arguments {
        var sql: String                   // one SELECT; a leading WITH is fine
        var outputPath: String            // the result CSV, overwritten if it exists
        init(sql: String, outputPath: String)
    }
}

// The data verbs: each init(root: URL, description: String? = nil); all .mutate except describeJson and csvInfo (.read)
struct JSONToCSVTool: Tool {              // "jsonToCsv": SELECT cols FROM json_array
    struct Arguments { var inputPath: String; var outputPath: String; var rowsAt: String; var columns: [JSONColumnSpec]?
                       init(inputPath: String, outputPath: String, rowsAt: String = "", columns: [JSONColumnSpec]? = nil) }
}
struct SelectColumnsTool: Tool {          // "selectColumns": SELECT a AS x, b
    struct Arguments { var inputPath: String; var outputPath: String; var columns: [ColumnRenameSpec]
                       init(inputPath: String, outputPath: String, columns: [ColumnRenameSpec]) }
}
struct FilterRowsTool: Tool {             // "filterRows": WHERE
    struct Arguments { var inputPath: String; var outputPath: String; var conditions: [FilterConditionSpec]; var matchAny: Bool?
                       init(inputPath: String, outputPath: String, conditions: [FilterConditionSpec], matchAny: Bool? = nil) }
}
struct SortRowsTool: Tool {               // "sortRows": ORDER BY ... LIMIT (the mechanical "top N")
    struct Arguments { var inputPath: String; var outputPath: String; var by: String; var descending: Bool?; var limit: Int?
                       init(inputPath: String, outputPath: String, by: String, descending: Bool? = nil, limit: Int? = nil) }
}
struct DedupeRowsTool: Tool {             // "dedupeRows": SELECT DISTINCT
    struct Arguments { var inputPath: String; var outputPath: String; var on: [String]?
                       init(inputPath: String, outputPath: String, on: [String]? = nil) }
}
struct ConcatRowsTool: Tool {             // "concatRows": UNION ALL
    struct Arguments { var inputPaths: [String]; var outputPath: String; init(inputPaths: [String], outputPath: String) }
}
struct AggregateRowsTool: Tool {          // "aggregateRows": GROUP BY
    struct Arguments { var inputPath: String; var outputPath: String; var groupBy: [String]?; var aggregates: [AggregateSpec]
                       init(inputPath: String, outputPath: String, groupBy: [String]? = nil, aggregates: [AggregateSpec]) }
}
struct DescribeJSONTool: Tool {           // "describeJson": a structure summary
    struct Arguments { var path: String; init(path: String) }
}
struct CSVInfoTool: Tool {                // "csvInfo": row and column counts, and samples
    struct Arguments { var path: String; var sampleRows: Int?; init(path: String, sampleRows: Int? = nil) }
}

// The verbs' argument parts (@Generable)
struct JSONColumnSpec { var header: String; var path: String; init(header: String, path: String) }   // path: "name", "attributes.EMAIL", "regions[0].code"
struct ColumnRenameSpec { var from: String; var to: String; init(from: String, to: String = "") }      // "" keeps the name
struct FilterConditionSpec {
    var column: String
    var op: String      // eq, ne, contains, notContains, startsWith, endsWith, matches (regex), gt, gte, lt, lte, isEmpty, notEmpty
    var value: String   // ignored for isEmpty / notEmpty
    init(column: String, op: String, value: String = "")
}
struct AggregateSpec {
    var fn: String      // count, sum, avg, min, max
    var column: String  // omit for count
    var name: String    // the result column; "" for an automatic name such as sum_amount
    init(fn: String, column: String = "", name: String = "")
}

// Building blocks
enum CSVCodec {
    struct CSVError: Error, Equatable { var message: String }
    static func encode(_ rows: [[String]]) -> String           // CRLF rows (RFC 4180), quoting only when needed; no trailing newline
    static func decode(_ text: String) throws -> [[String]]    // LF or CRLF, quoted or bare fields, doubled "" quotes; a leading BOM dropped
    struct Table {                                             // a header and rows padded or trimmed to its width
        var header: [String]
        var rows: [[String]]
        init(header: [String], rows: [[String]])
        func index(of column: String) -> Int?
        func value(_ row: [String], _ column: String) -> String   // "" for an unknown column
        func encoded() -> String
    }
    static func decodeTable(_ text: String) throws -> CSVCodec.Table
}
enum JSONPath {
    // "a.b[0].c"; a bracketed non-integer (["First Name"]) is a key. nil when a segment doesn't resolve; NSNull comes back as is
    static func value(at path: String, in root: Any) -> Any?
    static func stringify(_ value: Any?) -> String   // a CSV cell: null or missing "", bools "true"/"false", integers without ".0", containers as compact JSON
}
```

## Filesystem workspace (`WorkspaceAccess`/`WorkspaceTools`)

Not a connector: no `requestAccess()`, no system permission dialog. Everything here works inside a root `URL` your
app already resolved, usually from a security-scoped bookmark the user granted with a folder picker
([Filesystem access](sdk-guide.md#filesystem-access-security-scoped-bookmarks-example-not-in-core)); the picker is the
one-time consent. `WorkspaceAccess` is the data layer, and the workspace tools are the matching Path A `Tool`s, each
taking the root at init ([what Core gives you](sdk-guide.md#workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url)).
All in `LocalLMLabSDKCore`. For several folders with access levels and a chat's own folder, use `WorkspacesPlugin`
and the types in [Saved workspaces](#saved-workspaces) instead; `WorkspacePlugin` groups the tools below for one folder.

### `WorkspaceAccess`

A path is resolved once, relative to `root` or absolute inside it, and `..` and symlink escapes are refused. After
that every file is reached through file descriptors that never follow a symlink, so a symlink swapped in later makes
the call fail instead of leaving the workspace. Every operation is `async throws` and `@concurrent` (the blocking I/O
never runs on the caller's actor): it throws a `WorkspaceError` for anything the model or user should see, or
`CancellationError` when the task is cancelled. `limits` bounds how much work one call may do.

```swift
enum WorkspaceAccess {
    struct WorkspaceError: Error, LocalizedError { var message: String; var errorDescription: String? { get } }   // errorDescription is message
    struct WorkspaceEntry: Codable, Sendable { var name: String; var isDirectory: Bool; var modifiedDate: Date?; var size: Int? }
    static var maxReadCharacters: Int { get }   // WorkspaceLimits.default.maxReturnedCharacters; pass limits to change it per call

    @concurrent static func listFiles(in root: URL, subpath: String?) async throws -> [WorkspaceAccess.WorkspaceEntry]
    // Reads only limits.maxReadBytes off disk; a larger file returns its head with a notice pointing at readFileRange.
    // Text that isn't UTF-8 is read as Windows-1252; a file with a NUL byte is refused as binary.
    @concurrent static func readFile(in root: URL, path: String, limits: WorkspaceAccess.WorkspaceLimits = .default) async throws -> String
    // Create-only by default: fails on an existing file unless overwrite (replace it) or append (add to the end,
    // creating it if absent); passing both is an error. Create and overwrite stage to a temp file and rename it in,
    // so a reader never sees half a file.
    @concurrent static func writeFile(in root: URL, path: String, contents: String, overwrite: Bool = false, append: Bool = false,
                                      limits: WorkspaceAccess.WorkspaceLimits = .default) async throws
    // Search and replace, not a diff: oldString must match exactly once unless replaceAll. A quote across lines of a
    // "\r\n" file is tried with that file's line endings. The file is replaced only if unchanged since it was opened.
    @concurrent static func editFile(in root: URL, path: String, oldString: String, newString: String, replaceAll: Bool,
                                     limits: WorkspaceAccess.WorkspaceLimits = .default) async throws
    // Several replacements in one file, all or nothing: each applies to the text the ones before it left, and the
    // file is written once. If one fails, nothing is written and the error names it.
    static func editFile(in root: URL, path: String, edits: [WorkspaceAccess.TextEdit],
                         limits: WorkspaceAccess.WorkspaceLimits = .default) async throws
    struct TextEdit: Sendable, Equatable {
        var oldString: String
        var newString: String
        var replaceAll: Bool
        init(oldString: String, newString: String, replaceAll: Bool = false)
    }
    // Files only: a directory is refused, a symlink at the leaf is removed itself (never its target). Permanent.
    @concurrent static func deleteFile(in root: URL, path: String) async throws
    // The same checks, but moves the file to the user's Trash, where they can put it back; returns where it went
    @discardableResult @concurrent static func trashFile(in root: URL, path: String) async throws -> URL?

    // A unified diff over any number of files, applied whole or not at all. The @@ line numbers are ignored: each
    // hunk is placed by its context and removed lines, exactly first, then ignoring whitespace. Behind ApplyPatchTool.
    @concurrent static func applyPatch(in root: URL, diff: String, limits: WorkspaceAccess.WorkspaceLimits = .default) async throws -> WorkspaceAccess.PatchResult
    struct PatchResult: Codable, Sendable, Equatable {
        var changed: [String]
        var created: [String]
        var deleted: [String]
        var hunksApplied: Int
    }

    // Literal by default (ignoringCase for a case-blind literal); isRegex: an NSRegularExpression per line, each line
    // capped at limits.maxRegexInputBytes. include: an fnmatch glob on the relative path ("*.swift", "Sources/**").
    // Hidden entries, noise folders (build output, dependencies), symlinks and binary files are skipped.
    @concurrent static func search(in root: URL, query: String, isRegex: Bool = false, ignoringCase: Bool = false,
                                   include: String? = nil, maxResults: Int = 200,
                                   limits: WorkspaceAccess.WorkspaceLimits = .default) async throws -> WorkspaceAccess.SearchResult
    struct SearchMatch: Codable, Sendable, Equatable {
        var path: String                  // relative to root
        var line: Int                     // 1-based
        var text: String                  // the line, capped; for a long line, the part around the match
    }
    // What search found, and what it did not look at, so "no matches" is never confused with "didn't search there"
    struct SearchResult: Codable, Sendable, Equatable {
        var matches: [WorkspaceAccess.SearchMatch]
        var skippedTooLarge: [String]     // files over limits.maxFileBytes
        var scanBudgetExhausted: Bool     // limits.maxScanBytes ran out before every file was read
        var hitResultCap: Bool            // the count reached maxResults
    }
    // An indented listing; maxDepth 1 lists the immediate children, deeper levels are elided with "…".
    // Symlinked folders are listed, not descended into. Behind WorkspaceTreeTool.
    @concurrent static func tree(in root: URL, subpath: String? = nil, maxDepth: Int = 2) async throws -> String
    // offset: a 0-based line index; limit: a line count. Lines come back with an "N\t" gutter. Behind ReadFileRangeTool.
    @concurrent static func readFileRange(in root: URL, path: String, offset: Int, limit: Int,
                                          limits: WorkspaceAccess.WorkspaceLimits = .default) async throws -> String

    // Bounds on one call's work. Pass a custom value to any entry point or workspace tool; the defaults suit a
    // coding assistant on a typical project.
    struct WorkspaceLimits: Sendable, Equatable {
        var maxReadBytes: Int             // bytes readFile reads off disk; a larger file returns its head
        var maxReturnedCharacters: Int    // characters one read hands back (50,000, near MCP's per-result cap)
        var maxFileBytes: Int             // the largest file editFile, applyPatch and search process; larger ones refused or skipped and reported
        var maxRegexInputBytes: Int       // bytes of each line fed to a regular expression
        var maxScanBytes: Int             // total bytes one streaming call (search, readFileRange) may read
        var maxWriteBytes: Int            // the largest content writeFile accepts
        init(maxReadBytes: Int = 8 << 20, maxReturnedCharacters: Int = 50_000, maxFileBytes: Int = 64 << 20,
             maxRegexInputBytes: Int = 8 << 10, maxScanBytes: Int = 256 << 20, maxWriteBytes: Int = 64 << 20)
        static let `default`: WorkspaceAccess.WorkspaceLimits
    }
    // A file name with every Unicode space separator (U+202F, U+00A0) as a plain space, in NFC: the name a model types back
    static func plainName(_ name: String) -> String
}

// lab.workspace
@MainActor struct WorkspaceFacade {
    var maxReadCharacters: Int { get }    // WorkspaceAccess.maxReadCharacters
}
```

`WorkspaceAccess.defaultOffLimits` and `isOffLimits(_:root:patterns:)` (secrets and repository internals no
workspace tool touches) are in [Saved workspaces](#saved-workspaces).

### The workspace tools

Each has `static let defaultDescription`, `let name` and `let description`, and takes the resolved root. Each is an
`ImpactRatedTool`, rated in its comment. `limits` is the same `WorkspaceLimits` as above.

```swift
struct ListWorkspaceFilesTool: Tool {     // .read
    let name = "listWorkspaceFiles"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String?; init(path: String? = nil) }
}
struct ReadWorkspaceFileTool: Tool {      // .read
    let name = "readWorkspaceFile"
    init(root: URL, description: String? = nil, limits: WorkspaceAccess.WorkspaceLimits = .default)
    struct Arguments { var path: String; init(path: String) }
}
// .mutate; also a CallImpactRatedTool: .destructive when overwrite is true and the file exists
struct WriteWorkspaceFileTool: Tool {
    let name = "writeWorkspaceFile"
    init(root: URL, description: String? = nil, limits: WorkspaceAccess.WorkspaceLimits = .default)
    struct Arguments {
        var path: String
        var contents: String
        var overwrite: Bool?
        var append: Bool?
        init(path: String, contents: String, overwrite: Bool? = nil, append: Bool? = nil)
    }
}
struct EditWorkspaceFileTool: Tool {      // .mutate
    let name = "editWorkspaceFile"
    init(root: URL, description: String? = nil, limits: WorkspaceAccess.WorkspaceLimits = .default)
    struct Arguments {
        var path: String
        var oldString: String
        var newString: String
        var replaceAll: Bool?
        init(path: String, oldString: String, newString: String, replaceAll: Bool? = nil)
    }
}
// .destructive; deletes permanently (deleteFile, not the Trash). Left out of the examples' default tool lists:
// for a host that deliberately wants a delete-capable assistant.
struct DeleteWorkspaceFileTool: Tool {
    let name = "deleteWorkspaceFile"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String; init(path: String) }
}
struct SearchWorkspaceTool: Tool {        // .read
    let name = "searchWorkspace"
    init(root: URL, description: String? = nil, limits: WorkspaceAccess.WorkspaceLimits = .default)
    struct Arguments { var query: String; var isRegex: Bool?; var include: String?
                       init(query: String, isRegex: Bool? = nil, include: String? = nil) }
}
struct WorkspaceTreeTool: Tool {          // .read
    let name = "workspaceTree"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String?; var maxDepth: Int?; init(path: String? = nil, maxDepth: Int? = nil) }
}
// .mutate; also a CallImpactRatedTool: .destructive when the patch deletes a file
struct ApplyPatchTool: Tool {
    let name = "applyPatch"
    init(root: URL, description: String? = nil, limits: WorkspaceAccess.WorkspaceLimits = .default)
    struct Arguments { var diff: String; init(diff: String) }
}
struct ReadFileRangeTool: Tool {          // .read
    let name = "readFileRange"
    init(root: URL, description: String? = nil, limits: WorkspaceAccess.WorkspaceLimits = .default)
    struct Arguments { var path: String; var offset: Int; var limit: Int; init(path: String, offset: Int, limit: Int) }
}
```

The data tools that also work in a workspace folder (`loadTable`, `sqlQuery` and the data verbs, with `CSVCodec` and
`JSONPath`) are under Tables in [Web, documents, images and tables](#web-documents-images-and-tables).

### `FileBackedTool` and `SaveAsPolicy`

A decorator the host applies when building its tool list: it wraps a dynamic-schema tool (an MCP tool is the usual
one) and adds a root-level `saveAs` argument. When the model passes a path, the wrapped tool's whole raw result is
written there and only a receipt (size and a short preview) comes back, so a bulk payload never enters the model's
context. Without `saveAs` the tool behaves as before. See
[File-backed tools](sdk-guide.md#filebackedtool--the-aiql-data-verbs-a-mechanical-mcp-dataset--csv-pipeline).

```swift
struct FileBackedTool: Tool {             // impact .mutate; an OriginTaggedTool, so a wrapped MCP tool keeps its .mcp origin
    typealias Arguments = GeneratedContent
    let name: String                      // usually the wrapped tool's own
    let description: String               // the wrapped tool's, with a sentence about saveAs appended
    let parameters: GenerationSchema      // the wrapped schema's properties, plus saveAs at the root
    let toolOrigin: ToolOrigin
    // previewCharacters: how much of a saved result the receipt shows. inlineCharacterLimit: without saveAs, a
    // longer raw result is cut with a notice to use saveAs (nil: never cut). followUp: how the model should process
    // the saved file, woven into the description and the notice (a host with the SQL tools passes e.g. "load it with
    // loadTable and query it with sqlQuery"). invoke: runs the wrapped tool with the saveAs-stripped arguments and
    // returns its full, untruncated result.
    init(name: String, description: String, argumentsJSONSchema: Data, root: URL, previewCharacters: Int = 600,
         inlineCharacterLimit: Int? = nil, origin: ToolOrigin = .host,
         followUp: String = "read it back a window at a time with readFileRange", saveAsPolicy: SaveAsPolicy = .default,
         invoke: @escaping @Sendable (GeneratedContent) async -> String) throws
    func call(arguments: GeneratedContent) async throws -> String
    // An MCP tool wrapped this way (MCPFileBackedOutput, in the MCP client section, does the same per server)
    static func mcp(descriptor: MCPToolDescriptor, manager: MCPServerManager, root: URL, previewCharacters: Int = 600,
                    inlineCharacterLimit: Int? = nil, followUp: String = "read it back a window at a time with readFileRange",
                    saveAsPolicy: SaveAsPolicy = .default, serverDisplayName: String? = nil) throws -> FileBackedTool
}

// Where a saveAs path may go. The write lands inside `directory` after symlinks are resolved.
struct SaveAsPolicy: Sendable, Equatable {
    var directory: String?                // workspace-relative folder every path goes under (a leading "raw/" isn't doubled); nil: anywhere
    var allowedExtensions: Set<String>?   // lower-case, no dot; nil: any
    var allowsHiddenPaths: Bool           // allow components starting with "." in the model's part of the path
    init(directory: String? = "raw", allowedExtensions: Set<String>? = SaveAsPolicy.dataExtensions, allowsHiddenPaths: Bool = false)
    static let dataExtensions: Set<String>   // json, jsonl, ndjson, geojson, csv, tsv, txt, md, xml, yaml, yml, log
    static let `default`: SaveAsPolicy       // raw/, data extensions, no hidden paths
    static let dataOutput: SaveAsPolicy      // anywhere in the workspace, data extensions, no hidden paths: what sqlQuery and the data verbs use
    static let unrestricted: SaveAsPolicy    // any path: only for a workspace holding nothing a tool result could subvert
}
```

## Saved workspaces

New in 3.0, in `LocalLMLabSDKCore`. A workspace is a folder the model may work in, with a name the model uses and an
access level the tools enforce. `WorkspacesPlugin` (in [Built-in plug-ins](#built-in-plug-ins)) offers one set of file
tools over all of them plus each chat's own folder, scratch; `DocumentsPlugin`, `TablesPlugin` and `ImagesPlugin` take
the same list so their paths can name a workspace. `SavedWorkspaces` keeps the user's list between launches, with a
security-scoped bookmark for each folder so a sandboxed app reaches it after a relaunch. Picking the folder (an open
panel) is the app's: pass the URL the user chose to `add`.

### `Workspace` and its access levels

```swift
struct Workspace: Sendable, Codable, Equatable, Hashable {
    enum Access: String, Sendable, Codable, CaseIterable {
        case readOnly            // list, search and read; nothing can be changed (a write is refused)
        case askBeforeChanges    // read freely; every change asks first (rated .destructive, naming the workspace)
        case readWrite           // creates, edits and deletes (to the Trash) run; an overwrite runs once the old version
                                 // is kept in scratch, and asks when it can't be
        var label: String { get }   // "read-only", "ask before changes", "read-write": how the model and the user see it
    }
    var id: String               // the name the model uses ("notes"): letters, digits, -, _ and .; unique
    var displayName: String      // defaults to id
    var description: String      // one line for the card and the tools: "Swift SDK source, docs and examples"
    var root: URL                // already resolved, and for a bookmark already being accessed, by the host
    var access: Workspace.Access
    init(id: String, displayName: String? = nil, description: String, root: URL, access: Workspace.Access)

    static let scratchID: String                  // "scratch"
    static func scratch(_ root: URL) -> Workspace // a chat's own folder: always writable, never asks
    var isScratch: Bool { get }
    var isWritable: Bool { get }                  // access != .readOnly
}
```

### Off-limits paths

Paths no workspace tool lists, reads or writes, in any workspace: secrets and repository internals. The Files,
Documents, Tables and Images tools all check them; pass your own list to `WorkspacesPlugin(offLimits:)`.

```swift
extension WorkspaceAccess {
    // fnmatch patterns matched against each path component: .env, .env.*, *.pem, *.key, *.p12, *.pfx, SSH keys,
    // .ssh, .aws, .gnupg, .kube, keychains, .netrc, .npmrc, .pypirc, .git, .docker, cloud credential files,
    // Terraform state, *.ovpn, *.kdbx, *.sqlite, *.sqlite3 (the Tables plug-in's own database included)
    static let defaultOffLimits: [String]
    // Whether `path` (relative to root, or absolute inside it) is off-limits under `patterns`
    static func isOffLimits(_ path: String, root: URL? = nil, patterns: [String] = defaultOffLimits) -> Bool
}
```

### `SavedWorkspace` and `SavedWorkspaces`

A workspace's identity is its volume's UUID and its inode, recorded when it is added. A folder that was deleted and
replaced at the same path, or one in the Trash, isn't taken for the one the user granted, and the identity survives a
restart. Lists saved by earlier builds hold "device:inode"; the device number changes when the Mac restarts, so
those match by inode alone and are rewritten with the new identity the first time the folder resolves.

```swift
struct SavedWorkspace: Codable, Identifiable, Equatable, Sendable {
    var id: String               // the name the model uses ("code", "notes")
    var description: String
    var access: Workspace.Access
    var bookmark: Data           // security-scoped
    var path: String             // where it was when added, to show when the bookmark no longer resolves
    var isDefault: Bool?         // the workspace reads and searches mean when none is named
    var fileID: String?          // "<volume UUID>:<inode>" when added; nil in an older list, filled in the first time it resolves
    init(id: String, description: String, access: Workspace.Access, bookmark: Data, path: String,
         isDefault: Bool? = nil, fileID: String? = nil)
}

@MainActor final class SavedWorkspaces {
    let defaults: UserDefaults
    let key: String
    init(defaults: UserDefaults = .standard, key: String)   // the list saved in `defaults` under `key`
    var saved: [SavedWorkspace]  // every saved workspace, reachable or not (get and set)
    func resolved() -> [Workspace]                          // those whose folders can be reached, for WorkspacesPlugin
    // The folder behind `entry`, kept open (security-scoped access started) while the app runs; nil when it's gone,
    // in the Trash, or another folder now at that path. A stale bookmark is renewed.
    func url(of entry: SavedWorkspace) -> URL?
    // Adds a folder the user picked. Picked again: the existing entry gets the new bookmark and identity (how a
    // workspace that couldn't be opened is chosen again). nil if no bookmark could be made.
    @discardableResult func add(_ url: URL, access: Workspace.Access = .askBeforeChanges, description: String? = nil) -> SavedWorkspace?
    // Letters, digits, -, _ and . (up to 40, starting with a letter or digit); unique; never "scratch".
    // Returns why not, or nil on success. The model sees the new name from the next message.
    func rename(_ id: String, to proposed: String) -> String?
    var defaultID: String? { get }                          // the one marked default, or the only one there is
    func setDefault(_ id: String?)                          // nil: none (unless there's only one)
    func remove(_ id: String)                               // also stops accessing its folder
    func update(_ id: String, _ change: (inout SavedWorkspace) -> Void)

    nonisolated static func fileIdentifier(of url: URL) -> String?        // "<volume UUID>:<inode>" ("device-<n>:<inode>" without a volume UUID), or nil when it can't be read
    nonisolated static func sameFolder(saved: String, now: String) -> Bool // equal, or an older "device:inode" whose inode matches
    static func uniqueID(for url: URL, among list: [SavedWorkspace]) -> String   // "My Notes" -> "my-notes"; "-2" on a clash; never "scratch"
    static func abbreviated(_ path: String) -> String       // the home folder as "~", for showing
}
```

```swift
// A chat app's Files plug-in over the user's saved folders and the chat's own folder (chatFolder: a URL your app owns)
let saved = SavedWorkspaces(key: "workspaces.v1")
let files = WorkspacesPlugin(scratch: chatFolder, workspaces: saved.resolved(), defaultWorkspace: saved.defaultID)
lab.tools.add(files, enabled: true)
```

## No-permission tools

Two tools that need no permission or entitlement, in `LocalLMLabSDKCore`: drop them into a session's tools, or add
`ClockPlugin` / `WeatherPlugin` ([Built-in plug-ins](#built-in-plug-ins)) to let the picker offer them. See
[Clock and Weather](sdk-guide.md#clock-and-weather-no-permission-needed-just-drop-them-in). Both are rated `.read`.

```swift
struct ClockTool: Tool {
    static let defaultDescription: String
    let name: String              // "getCurrentTime"
    let description: String
    init(description: String? = nil)
    struct Arguments {
        // New in 3.0: a place's local time, converted by the tool rather than the model. An IANA identifier
        // ("Asia/Tokyo"), a city ("Tokyo", "new york") or an abbreviation ("JST", "UTC"), any case. nil or empty: this Mac's time.
        var timeZone: String?
        init(timeZone: String? = nil)
    }
}

struct WeatherTool: Tool {
    static let defaultDescription: String
    let name: String              // "getWeather"
    let description: String
    init(description: String? = nil)
    struct Arguments {
        var location: String      // a place the model names: "San Francisco", "Paris, France"
        init(location: String)
    }
    // Current conditions and a 7-day forecast from Open-Meteo (a keyless third-party service, over HTTPS): the
    // place name leaves the Mac. Units follow the Mac's region.
}
```

## Error handling

The model layer throws one error type, `LocalLMLabError`; a provider's own error (Remote's `RemoteError`, an MLX
weight-verification failure, FoundationModels' errors) arrives wrapped inside it. `GenerationErrorDescription` turns
any of them into words a user can act on. Errors specific to one area (`SessionOptionsError`, `DecisionError`,
`ModelRegistryError`, `RemoteProviderConfig.ValidationIssue`) are declared with their types above.

### `LocalLMLabError` (`LocalLMLabSDKCore`)

```swift
enum LocalLMLabError: Error, LocalizedError {
    case modelUnavailable(reason: String)   // no provider, or something the host must supply — 3.0: weights (or a paired
                                            // helper/adapter) not downloaded at the pinned revision; loading never downloads
    case download(stage: String, underlying: (any Error)?)   // a download or pin update failed; stage names where —
                                            // MLX: "verify", "currentVersion", "commitRequired", "noCapturedPin", "vetoed", …
    case validation(stage: PreflightResult.Stage, detail: String)   // a pre-flight check rejected a repo
    case generation(underlying: any Error)  // generation failed; errorDescription unwraps the real cause
    case context(detail: String)            // past the context window or past GPU memory, after the retry policy
    case mcp(detail: String)
    case connector(detail: String)          // Calendar / Reminders / Contacts / Location
    var errorDescription: String? { get }
    // LocalLMLabSDKInference:
    var isRejectedToolCall: Bool { get }    // the model wrote a tool call that couldn't be used (below)
}
```

A hosted endpoint's "prompt is too long" comes back as `.context`, which the session answers by compacting and
retrying (`RemoteError.forStatus`). Sessions no longer throw `.validation(stage: .trustPolicy, …)`: the trust policy
applies at download.

### Describing an error to the user (`LocalLMLabSDKCore`)

```swift
enum GenerationErrorDescription {
    static func describe(_ error: any Error) async -> String   // per-case explanation; async because a refusal's
                                                               // explanation is computed by FoundationModels
    static func describeSync(_ error: any Error) -> String     // best effort where you can't await (refusal: debug text)
    static func contextOverflowMessage(_ error: any Error, assistant: String?) -> String?
        // an overflow trimming couldn't fix, in plain words with a next step; assistant: your model's name; nil otherwise
    static func isModelServiceFailure(_ error: any Error) -> Bool   // Apple's model service failing (ModelManagerError),
                                                                    // not a refusal, guardrail, overflow or network error
    static func modelServiceMessage(_ error: any Error, assistant: String?, repeated: Bool) -> String?
        // that failure in plain words; repeated: the same query failed again, so it doesn't suggest retrying
    static func quotaLimit(in error: any Error) -> GenerationErrorDescription.QuotaLimit?   // PCC quota used up; nil otherwise
    static func quotaMessage(resets: Date?, now: Date = Date(), calendar: Calendar = .current) -> String
        // "You've reached your Private Cloud Compute limit. You can send messages again at about 3:40 PM."
    static func estimatedTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String
        // "at about 3:40 PM", "tomorrow at about 9:00 AM", or the date
    static let quotaNotAnsweredNote: String   // the note under a message not answered because of the quota
    struct QuotaLimit: Sendable, Equatable { var resets: Date? }   // nil: Apple didn't say
}
```

`ModelAvailability.UnavailableKind.quotaReached(resets:)` is the same condition seen before a turn.

### Rejected and refused tool calls

A small local model sometimes writes a tool call that can't be used: malformed, for a tool it wasn't offered, or
with arguments that don't fit the schema. The MLX bridge fails the turn rather than let the markup reach the reply;
the session retries a rejected or undeclared call once, and an app may retry the turn once more before telling the
user.

```swift
// LocalLMLabSDKCore
struct RefusedToolCall: Error {          // a provider refused a call; the session treats a call to a tool it has
    let toolName: String                 // as a request for it and reruns the turn
    let underlying: any Error
    init(toolName: String, underlying: any Error)
    static func find(in error: any Error) -> RefusedToolCall?   // through LocalLMLabError and NSError wrapping
}

// LocalLMLabSDKInference
func isRejectedToolCall(_ error: any Error) -> Bool                                // however it was wrapped
func rejectedToolCallDiagnostics(in error: any Error) -> RejectedToolCallDiagnostics?
struct RejectedToolCallDiagnostics: Sendable, Equatable {   // for a developer; rawTextPreview can hold argument values —
                                                            // show on request, never log or persist automatically
    let reason: String           // malformed_syntax, incomplete_output, missing_tool_name, undeclared_tool,
                                 // invalid_arguments or resource_limit_exceeded
    let format: String           // the tool-call protocol the parser used for this model
    let toolName: String?
    let apparentToolName: String?   // the name read from the raw text when the parser recovered none
    let detail: String?          // the parser's summary; never raw output
    let rawTextPreview: String   // a bounded preview (both ends kept if long)
    let rawTextByteCount: Int
    let isPreviewTruncated: Bool
}
```

### Provider errors

```swift
// LocalLMLabSDKRemote — wrapped in LocalLMLabError.generation
enum RemoteError: Error, LocalizedError {
    case http(status: Int, message: String)       // non-2xx; message is the provider's text when parseable
    case transport(any Error)                     // offline, DNS, TLS, timeout
    case dialectNotImplemented(String)
    case responseTooLarge(String)                 // a RemoteResponseLimits bound was exceeded — misbehaving or hostile
    case cutOffInToolCall(tool: String, limit: Int)   // the output limit hit mid tool call; the call didn't run
    case undeclaredTool(String)                   // a call to a tool this request didn't declare
    var errorDescription: String? { get }
    static func forStatus(_ status: Int, message: String) -> any Error
        // a context overflow (400/413 "prompt is too long", "context_length_exceeded") → LocalLMLabError.context; else .http
}

// LocalLMLabSDKInference — wrapped in LocalLMLabError.download(stage: "verify", underlying:)
struct MLXWeightVerificationError: Error, LocalizedError, Sendable {
    enum Reason: Sendable, Equatable {
        case hashMismatch(expected: String, computed: String)   // the file's hash didn't match its ETag
        case unrecognizedETagShape(String)                      // neither SHA-256 (LFS) nor git-blob SHA-1
    }
    var filename: String
    var reason: MLXWeightVerificationError.Reason
    init(filename: String, reason: MLXWeightVerificationError.Reason)
    var errorDescription: String? { get }
}
```

**A note on what's not listed above**: `@Generable` (Apple's FoundationModels macro, applied to every `Arguments` struct in this SDK and in your own tools) synthesizes additional public members on each one — a `PartiallyGenerated` nested type, `generationSchema`, `generatedContent`, and a few others. These are FoundationModels' own machinery for incremental/streaming generation, not SDK API — you'll never call them directly, only `@Generable`/`LanguageModelSession` do. Left out here deliberately, the same way compiler-synthesized `Codable`/`Hashable` methods (`init(from:)`, `encode(to:)`, `hash(into:)`) are left out of the reference types above — real public symbols, but noise for this list's purpose. If you inspect the compiled binary directly and see these, that's expected, not a sign this reference is out of date.

## Chat core (`ChatController`, `ChatSetup`, conversations)

New in 3.0, all in **`LocalLMLabSDKCore`**. `ChatController` runs one whole conversation for you: the turn loop,
attachments, tool choice, the cards a turn can end with, saving, and compaction. `ConversationStore` keeps every
conversation on disk. `ChatSetup` builds a chat session the way every SDK chat app does. Components' chat views
([Components](#components-locallmlabsdkcomponents)) draw all of it. The walkthrough is
[Building a chat app](sdk-guide.md#building-a-chat-app--hosttranscript-streamresponse-turncontext). Start from
[`mcp-chat`](../examples/mcp-chat/) to see the pieces by hand, then use the controller once you want them put together.

### `ChatController` — one open conversation

One conversation, made from a `LocalLMLab`, a `ConversationStore`, a conversation ID and a `ChatConfiguration`.
SwiftUI views observe it directly. A message a check catches (a server URL, a folder, a pasted key) becomes a card,
not a turn. A gate that stops a turn also becomes a card. Each card's action sends the message again once the user
has dealt with it.

```swift
@MainActor @Observable final class ChatController {
    let lab: LocalLMLab
    let store: ConversationStore
    let conversation: UUID
    var configuration: ChatConfiguration
    private(set) var status: ChatStatus                // .ready | .responding
    private(set) var session: LocalLMLabSession?       // nil until the first turn when opened with openSession: false
    private(set) var cards: [ChatCard]                 // the inline cards, each placed after a transcript entry
    var editingLastMessage: String?                    // the message being edited (the composer shows it); sending replaces the last turn
    private(set) var isCompacting: Bool                // earlier messages are being summarized; a message sent meanwhile waits
    // openSession: build the session now from the saved transcripts and the tools it last offered (else on the
    // first turn). cacheIsCold: nothing of this chat is in the prompt cache, so the next turn reads it all anyway.
    init(lab: LocalLMLab, store: ConversationStore, conversation: UUID, configuration: ChatConfiguration,
         openSession: Bool = true, cacheIsCold: Bool = false)
    var filesFolder: URL { get }                       // the chat's own folder: attachments, saved pages, files the tools write
    var canRegenerate: Bool { get }                    // ready, and there is a last turn to run again

    // --- turns ---
    func send(_ text: String, attachments: [URL])      // the composer's send: a caught message becomes a card; else attachments are copied in and the turn runs
    func run(_ prompt: String, retryRejected: Bool = true)   // runs prompt as the next turn; retryRejected: an unusable tool call → run once more from before it
    func sendFromWidget(_ text: String, instance: String)    // an MCP App view's ui/message, as the next turn
    func stop()                                        // Stop: cancels the turn; its cancellation is the user's, not a fault
    func regenerate()                                  // the last message again, from the conversation as it was before it
    func editLast()                                    // puts the last message back in the composer
    func rebuildSession(cacheIsCold: Bool = false)     // a new session takes over both transcripts and the offered tools (a model switch)
    func save()                                        // saves both transcripts and the offered tools
    static let setAsideNotice: String                  // shown under a message the model service failed on, when earlier results were set aside
    static func fileActivity(in entries: [HostTranscript.Entry]) -> [String]?   // what the Files plug-in did: "read code/README.md"

    // --- cards (Components' ChatCardView calls these) ---
    func canRetry(_ card: ChatCard) -> Bool            // an empty-reply card offers Retry: last turn, no tool ran, no turn running
    func retry(_ card: ChatCard)                       // Retry on an empty-reply card: the turn again, from before it
    func resolve(_ card: ChatCard, resend: Bool)       // marks it dealt with; resend runs its message again (after a running turn)
    func complete(_ card: ChatCard, notice: String?)   // an app-handled card done (an added workspace), with a notice after it
    func dismiss(_ card: ChatCard)                     // removes it
    func decline(_ card: ChatCard)                     // Don't Allow / Not Now: a card that stopped its message sends it without what it asked for
    func sendAsMessage(_ card: ChatCard)               // add-source / add-workspace card made from a message: send that message as written
    func choose(_ option: SelectableTool, on card: ChatCard)   // clarify: the pick is offered on the next turn (same message)
    func checkServer(_ card: ChatCard)                 // suggest-server: a follow-up turn with the server's suggested tools pinned
    func signIn(_ card: ChatCard) async                // the server's own sign-in; the message runs again once signed in
    func allow(_ card: ChatCard) async                 // permission: the system prompt; resends only once the access works, else sets card.problem
    func isGranted(_ card: ChatCard) -> Bool           // macOS has granted everything a permission card asks for
    func refreshPermissionCards(resend: Bool = true)   // marks granted cards done (call when the app becomes active); waits for a running turn
    func openSystemSettings(for card: ChatCard)        // the Privacy & Security pane of the first access still missing
    func review(_ card: ChatCard, accept: Bool)        // a server's changed tools accepted or rejected; the message runs again
    // The add-tool card submitted (submitting is the approval): sign in if asked, list and keep its tools, disconnect.
    func addSource(_ card: ChatCard, url: URL, name: String, authType: MCPAuthType, token: String?, trusted: Bool = false) async
    func showAddSource(url: String = "", name: String = "") -> ChatCard   // an add-tool card, empty or prefilled (a toolbar button)
    func sendWithoutKey(_ card: ChatCard)              // the pasted-key card's Send Without It

    // --- compaction ---
    nonisolated static let compactionWindowShare: Double   // 0.6: at most this share of the window is read before compacting
    nonisolated static func compactionThreshold(_ configured: Int, window: Int?) -> Int   // compactsAbove, lowered for a small window
    func cancelCompaction()                            // stop a running compaction, chat unchanged (call before quitting)

    // --- labels ---
    func sourceName(_ source: ToolRef.Source) -> String   // "This app", a plug-in's name, or an MCP server's
    func toolLabel(_ ref: ToolRef) -> String              // "Calendar › getUpcomingEvents"
}

enum ChatStatus: Sendable, Equatable { case ready, responding }
```

The controller sets `session.auditConversation` to the conversation's ID, so audit entries name the chat. A turn
that runs out of room or ends with nothing to show is recorded in `ConversationMeta`, and the chat shows it.

### `ChatConfiguration` — what the controller needs from the app

What a second app might choose differently comes in here. `makeSession` builds the session (the
`ChatConfiguration.standard` factory builds it from a `ChatSetup`). The rest are checks and hooks around a turn.

```swift
@MainActor struct ChatConfiguration {
    var makeSession: (_ restoring: Transcript?) throws -> LocalLMLabSession   // restoring: the saved model transcript, nil for a new chat
    var dynamicTools: () -> DynamicTools               // the next turn's tools (the matcher and budget can change between turns)
    var reportError: (String) -> Void                  // something to tell the user ("Couldn't sign in: …")
    var intents: Set<ComposerIntent.Kind>              // checks run on a message before it's a turn; default all
    var compactsAbove: Int?                            // 32_000: summarize earlier messages once the model reads more; nil never
    var compactionKeepsLast: Int                       // 3: messages kept word for word after a compaction
    var isWorkspaceSaved: ((_ path: String) -> Bool)?  // a saved folder named in a message is a turn, not an add-workspace card
    var interceptMessage: ((String) -> ChatCard.Kind?)?   // the app's own check after intents: a card instead of a turn
    var saveModelTranscript: () -> Bool                // default true: a reopened chat continues where it left off
    var isRejectedToolCall: ((any Error) -> Bool)?     // an unusable tool call: the turn runs once more if no tool ran; nil never
    var rejectedToolCallDetail: ((any Error, LocalLMLabSession) -> String?)?   // more for the warning card (developer mode)
    var restoredTokens: (() -> Int)?                   // running count of prompt tokens restored from a cache
    var suggestServerLimit: Int                        // 2: times a held-back server is suggested per chat
    var longMessageCharacters: Int                     // 10_000: a longer message is sent as "Pasted text.txt" with its opening kept
    var turnStarted: (() -> Void)?
    var turnFinished: (() -> Void)?                    // however it ended
    var turnFailed: ((any Error) -> Void)?             // the error, just before reportError gets its message
    var turnCancelled: ((_ error: any Error, _ taskCancelled: Bool) -> String?)?   // a cancellation the user didn't ask for; returns detail for the warning
    var sessionReplaced: (() -> Void)?                 // a model switch: views holding the old session should let go
    var assistantName: String?                         // the model's name in failure messages; nil: "Apple's model"
    init(makeSession: @escaping (_ restoring: Transcript?) throws -> LocalLMLabSession,
         dynamicTools: @escaping () -> DynamicTools, reportError: @escaping (String) -> Void)
    // Sessions built the standard way: setup() per new session, dynamicTools() before each turn.
    static func standard(lab: LocalLMLab, setup: @escaping () -> ChatSetup, dynamicTools: @escaping () -> DynamicTools,
                         reportError: @escaping (String) -> Void) -> ChatConfiguration
}
```

`turnFailed` is where a host reads the kind of failure, for example Private Cloud Compute's limit with
`GenerationErrorDescription.quotaLimit(in:)`, to show it as a status rather than an alert.

### `ChatSetup` — a chat session, built the standard way

One chat session as every SDK chat app builds it. Build one per session, because settings can change between
sessions, then call `makeSession(lab:restoring:dynamicTools:)` or hand it to `ChatConfiguration.standard`. It sets the
session's `turnContext` (the clock, then `turnNotes`) and `toolContext` (the standard notes about the turn's tools, the
image rule when an image is in play, then `toolNotes`). It also copies each property below onto the session member of the
same name ([`LocalLMLabSession` in a chat](#locallmlabsession-in-a-chat-30-members), and [Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker) for the tool-choice ones).

```swift
struct ChatSetup {
    var route: RouteName
    var instructions: String                           // the app's own, for a new chat; newChatInstructions adds the standard guidance
    var authorizer: (any ToolCallAuthorizer)?          // nil is fail-closed (reads run, anything else denied), not "no gate"
    var options: SessionOptions                        // SessionOptions()
    var images: ChatImageHandling                      // .automatic
    var imagesLook: Bool                               // false; true when ImagesPlugin has a looker, so the image rule covers both readings
    var turnNotes: (@Sendable () -> [String])?         // the app's notes for each turn, after the clock; called off the main actor
    var toolNotes: (@Sendable (ToolPreparation) -> [String])?   // the app's notes once the turn's tools are chosen
    var missingToolGuidance: Bool                      // true: DynamicTools' missing-tool guidance + held-back / no-tools notes
    var framesUntrustedContent: Bool                   // true: outside content reaches the model framed as data
    var asksBeforeSendingReadContent: Bool             // false: trust decides; true: sending read text out always asks
    var permissionAsking: PermissionAsking             // .onCall
    var requestsTools: Bool                            // true: each turn also offers requestTools
    var standingInstructions: (@Sendable () -> String)?   // the user's custom instructions, read on every message
    var retryOnContextOverflow: RetryPolicy            // RetryPolicy(maxRetries: 3, compact: ChatSetup.trimOldThenDropOldestHalf)
    var mcpAppHints: Bool                              // true: tool descriptions say when a tool shows an MCP App view
    var now: @Sendable () -> Date                      // the turn's clock (tests set it)
    var retriesEmptyReply: Bool                        // true (the session's own default is false)
    var trimsOldResults: Bool                          // true (the session's own default is false)
    init(route: RouteName, instructions: String, authorizer: (any ToolCallAuthorizer)? = nil)

    var newChatInstructions: String { get }            // instructions + the standard missing-tool guidance (when on)
    func sendsImages(to model: ModelID) -> Bool        // whether attached images go to model as pictures, per `images`
    // makeSession(lab:restoring:dynamicTools:) builds the session: see the Dynamic tools section

    // The pieces, for apps and tests
    // dynamicTools(matcher:maxTools:): see the Dynamic tools section
    static func modelSeesImages(_ id: ModelID) -> Bool // FoundationModels' .vision; asks PCC only for .pcc (needs the PCC entitlement)
    static func clock(_ now: Date, timeZone: TimeZone = .current) -> String   // the turn's date and time, time zone labeled
    // Before the last keepingLast messages: each tool result over longerThan characters, and each attached image,
    // becomes a one-line note. Messages, answers and tool calls stay. Nil when there's nothing to trim.
    static func trimOldContent(_ transcript: Transcript, keepingLast: Int = 2, longerThan: Int = 400) -> Transcript?
    @Sendable static func trimOldThenDropOldestHalf(_ transcript: Transcript) -> Transcript   // trimOldContent first; then dropOldestHalf
    @Sendable static func dropOldestHalf(_ transcript: Transcript) -> Transcript   // keeps the instructions and the newer half
    static func imageInPlay(_ preparation: ToolPreparation) -> Bool   // readImageText offered, and an image attached or just read
    static func imageTextRule(looks: Bool) -> String   // how to answer from what was read in an image
}

enum ChatImageHandling: Sendable, Equatable {
    case automatic     // to the model as pictures when it reports vision; otherwise ImagesPlugin's readImageText
    case toModel       // always to the model (it must report vision)
    case readText      // always by readImageText
}

// The built-in plug-ins a chat app offers.
enum ChatPlugins {
    static var webOptions: WebReadingOptions { get }   // a private address (127.0.0.1, the LAN, .local) only when the user typed it
    static let standardIDs: [PluginID]                 // every id `standard` can return, for settings lists
    // Clock, Weather, Calendar, Reminders, Contacts, Location, Documents, Tables, Web over `files` (the chat's
    // folder) and `workspaces`; + Images (readsImages, with looker for photos); + Files (filesPlugin).
    static func standard(files: URL, workspaces: [Workspace], defaultWorkspace: String?,
                         filesPlugin: Bool, readsImages: Bool, looker: (any ImageLooking)? = nil) -> [any ToolPlugin]
}
extension ImagesPlugin { static let pluginID: PluginID }      // "locallmlab.images"
extension WorkspacesPlugin { static let pluginID: PluginID }  // "locallmlab.files"
```

Keep `filesPlugin` on once any workspace is saved, even for a chat with none, because its history may call it.

### `ChatCard` — what a turn can end with

A card in a chat: a turn that ended with one instead of an answer (a `ToolGate`), or one the chat shows on its own.
Card text comes from fixed templates, never from the model. `ChatCardView` draws any of them.

```swift
struct ChatCard: Identifiable {
    enum Kind {
        case clarify(options: [SelectableTool], sources: [String: String])   // which tool was meant; sources: source name by tool ref
        case signIn(server: MCPServerID, name: String, domain: String)       // a server needs the user to sign in
        case permission(plugin: PluginID, name: String, missing: Set<PluginPermission>)   // a plug-in needs a macOS permission
        case review(server: MCPServerID, name: String, drift: ToolDrift)     // a server's tools changed since they were accepted
        case addSource(url: String, name: String)       // the add-tool card, prefilled from a message or empty
        case addWorkspace(path: String)                 // "My code is in ~/Code/project"
        case pastedKey(cleaned: String)                 // the message held a key; cleaned is it without the key
        case notice(String)                             // something done ("Brevo added: 12 tools")
        case suggestServer(server: MCPServerID, name: String, tools: [ToolRef])   // after a reply: a held-back server that fits
        case warning(String)                            // something went wrong in a turn, said inline
        case emptyReply(EmptyReply)                     // the model stopped without answering
        case custom(id: String, payload: [String: String])   // the app's own card, drawn by the app
    }
    let id: UUID
    var kind: Kind
    var prompt: String?                // the message the turn was for, sent again once the card is dealt with
    var resolved: Bool                 // false
    var beforeMessage: Bool            // the card stopped the message before it reached the chat: declining sends it without what was asked
    var after: Int                     // placed after this many transcript entries
    var problem: PermissionProblem?    // a permission card whose Allow didn't give working access: what to do
    init(kind: ChatCard.Kind, prompt: String? = nil, after: Int)
}
// PermissionProblem: see the Dynamic tools section
```

### `ComposerIntent` and `ChatAttachments` — reading a message before it's a turn

`ComposerIntent` is what a message asks for before it becomes a turn: add a server, add a folder, or a pasted key the
model must not see. `ChatAttachments` is how a message names its files: one `[Attached: name]` line per file after the
text. The files sit in the chat's folder. The model reads the lines and the views hide them.

```swift
enum ComposerIntent: Equatable, Sendable {
    case addSource(url: String, name: String)   // "Here's the Brevo MCP server: https://…/mcp"
    case addWorkspace(path: String)             // a folder that exists, in a message about using it
    case pastedKey(cleaned: String)             // an API key or token; cleaned: the message without it
    enum Kind: Sendable, Hashable, CaseIterable { case addSource, addWorkspace, pastedKey }   // ChatConfiguration.intents
    var kind: Kind { get }
    // The first of kinds that text asks for, in order: server, folder, key. Server and folder only without attachments.
    static func detect(_ text: String, hasAttachments: Bool = false, kinds: Set<Kind> = Set(Kind.allCases)) -> ComposerIntent?
    static func addSource(in text: String) -> (url: String, name: String)?   // URL + a name for it; without a URL needs "add"/"connect"/"install"
    static func workspacePath(in text: String) -> String?   // the folder's standardized path, or nil
    static func withoutKeys(_ text: String) -> String?      // keys replaced by "[key removed]"; nil when there's none
    static func withoutKeys(_ text: String, includingBareTokens: Bool) -> String?   // false for saved transcripts (commit hashes are text)
}

enum ChatAttachments {
    static let prefix: String                          // "[Attached: "
    static func line(_ name: String) -> String         // "[Attached: name]"
    static func names(in prompt: String) -> [String]
    static func types(in prompt: String) -> [UTType]   // by file extension
    static func text(of prompt: String) -> String      // the message without its attachment lines (and prompt line), for showing
    static func unreadable(_ url: URL, accepted: [UTType]) -> String?   // why url can't be attached, or nil (text under any name is fine)
    static func savePasted(_ text: String, in folder: URL) -> String?   // "Pasted text.txt", "Pasted text 2.txt"…; the file's name
    static func lineBroken(_ text: String, width: Int = 500) -> String  // one long line broken near sentence ends, for line-range reads
    static func opening(of text: String, limit: Int = 300) -> String    // what's kept in the message when the rest is attached
    static let promptPrefix: String                    // "[From "
    static func promptLine(source: String, prompt: String) -> String    // "[From Hugging Face: Summarize a model]"
    static func promptSource(in message: String) -> String?            // "Hugging Face: Summarize a model", or nil
}
```

### `ConversationStore`, `ConversationMeta`, `TurnInfo` — saved conversations

`ConversationStore` keeps every conversation in one directory, one folder each, newest first. Each folder holds both
transcripts (what the user saw and the model's memory), a `meta.json`, and the files the tools read and write.
SwiftUI views observe it directly.

```swift
@MainActor @Observable final class ConversationStore {
    private(set) var conversations: [ConversationMeta] // newest first
    let root: URL                                      // the directory holding one folder per conversation
    init(directory: URL)                               // reads every conversation, creating the directory if needed
    func folder(_ id: UUID) -> URL                     // the conversation's folder
    func files(_ id: UUID) -> URL                      // where plug-ins read and write: attachments, documents the model writes
    func create() -> ConversationMeta
    func meta(_ id: UUID) -> ConversationMeta?
    func update(_ id: UUID, touch: Bool = true, _ change: (inout ConversationMeta) -> Void)   // touch: bump `updated`
    func rename(_ id: UUID, to title: String)          // sets titleIsCustom
    func delete(_ id: UUID)
    func deleteAll()
    func loadShown(_ id: UUID) -> Data?                // the HostTranscript archive
    func loadModel(_ id: UUID) -> Transcript?          // the model's transcript
    func save(_ id: UUID, shown: Data?, model: Transcript?)
    func search(_ query: String) -> [ConversationMeta] // titles and what was said
}

struct ConversationMeta: Codable, Identifiable, Equatable, Sendable {   // meta.json
    var id: UUID; var title: String; var created: Date; var updated: Date
    var titleIsCustom: Bool                    // set by a rename: never replaced by the first message
    var turns: [Int: TurnInfo]                 // per turn: why these tools
    var files: [Int: [String]]                 // per turn: files the tools wrote into the folder (file cards)
    var offeredTools: [ToolRef]?               // the latest turn's tools, carried into a reopened chat's session
    var suggestedServers: [String: Int]?       // times each server (by URL) was suggested after a reply
    var toolHistory: ToolHistory?              // saved with offeredTools; pass both to carryOverTools(_:history:)
    var unanswered: Set<Int>?                  // turns the model service failed on; left out of what the picker reads
    var unansweredNotes: [Int: String]?        // why, when the chat can say better than the default note
    var compactions: [Int: ChatCompaction]?    // by the first turn kept word for word after each (a divider there)
    var extra: [String: String]?               // the app's own fields
    init(id: UUID, title: String, created: Date, updated: Date)
    func isContentLink(_ url: URL) -> Bool     // url's host was linked only from content the model read: confirm before opening
}

struct TurnInfo: Codable, Equatable, Sendable {   // what preparing one turn's tools did, for the "why these tools" chip
    var matcher: String                    // "keyword" or "decider (Qwen3-4B-4bit)"
    var milliseconds: Double
    var sources: [Scored]                  // sources the matcher scored highest, best first
    var offered: [String]                  // "Source › tool"
    var connected: [String]; var unavailable: [String]
    var byAttachment: [String]             // chosen by an attachment's file type, with no matcher
    var heldBack: [String]?                // MCP servers held back because nothing in the chat named them
    var inContext: [Scored]?               // mid-chat: each source that would add tools, scored against earlier messages
    var dropped: [String]?                 // guessed tools dropped after going unused
    var requested: [String]?               // the model's requestTools calls: "copy guide.md → Files › copyFile, …"
    var contentLinks: [String]?            // links in the reply that came only from content the model read
    var fileActivity: [String]?            // "read code/README.md", "wrote scratch/notes.md"
    var room: TurnRoomReport?              // the turn ran out of room for tool calls
    var firstTokenMilliseconds: Double?    // developer mode, with restoredTokens and toolBlockTokens
    var totalMilliseconds: Double?         // sending the message to the reply's last word
    var restoredTokens: Int?
    var toolBlockTokens: Int?
    // struct Scored (name + score): see the Dynamic tools section
    init(matcher: String, milliseconds: Double, sources: [Scored], offered: [String], connected: [String] = [],
         unavailable: [String] = [], byAttachment: [String] = [])
}
```

Optional fields decode as nil from conversations saved before they existed.

### Compaction and empty replies

When a chat grows long, `compactIfLong` folds its earlier messages into a summary that the model writes. The session
then continues from the summary and the last few messages. The host transcript, which is what the user sees, doesn't
change. `ChatController` runs it after a reply, past `ChatConfiguration.compactsAbove`. A turn whose model stops with
no answer and no tool call is reported as an `EmptyReply`, not thrown.

```swift
extension LocalLMLabSession {
    var conversationSize: Int { get }   // tokens the model reads for this chat now (estimate, or the last turn's count if larger)
    // Over `tokens`: everything before the last keepingLast messages becomes a summary. aimingBelow: keep fewer
    // (down to one) while the result would still read more. Nil when not that long, nothing to fold, or a turn started.
    // Run it between turns. If the summary can't be written, the earlier messages go without one.
    func compactIfLong(above tokens: Int, keepingLast: Int = 3, aimingBelow target: Int? = nil) async -> ChatCompaction?
    var lastTurnEmptyReply: EmptyReply? { get }   // set as a turn ends; cleared when the next starts; nil for a thrown or stopped turn
}
struct ChatCompaction: Sendable, Codable, Equatable {
    var summary: String?               // what this compaction added to the summary; nil when it couldn't be written
    var keptExchanges: Int             // exchanges kept word for word after it
    var date: Date
    init(summary: String?, keptExchanges: Int, date: Date = Date())
}
struct EmptyReply: Sendable, Equatable {
    var reasoned: Bool                 // the model wrote reasoning before it stopped
    var toolCalls: Int                 // calls the turn made first; running it again would run them again
    var retried: Bool                  // run once more, and it stopped again
    var changedSomething: Bool         // a call changed something or sent data out (read-only calls don't count)
    var announced: Bool                // a short line ending in a colon, announcing a step it didn't take
    var attempts: Int                  // times the turn was run, counting the first
    var repeated: Bool                 // the reply started repeating itself and was stopped
    init(reasoned: Bool, toolCalls: Int, retried: Bool = false, changedSomething: Bool? = nil,
         announced: Bool = false, attempts: Int? = nil, repeated: Bool = false)
    var note: String { get }           // what the chat says (ChatCard.Kind.emptyReply)
}
```

### `LocalLMLabSession` in a chat (3.0 members)

The members 3.0 adds to `LocalLMLabSession` for a chat. The rest of the session (`respond`, `hostTranscript`, `events`,
`contextBudget`…) is in [the model layer section](#the-model-layer-locallmlab-routing-providers-sessions). Set these
before the first turn. `ChatSetup.makeSession` sets most of them for you. The members that steer tool choice (`standingInstructions`,
`permissionAsking`, `requestsTools`, `toolContext`, `usesDynamicTools`, `updateDynamicTools(_:)`, `pinTools(_:)`,
`skipForNextTurn(permissions:servers:)`, `markPromptCacheCold()`, `carryOverTools(_:history:)`, `toolHistory`,
`offeredTools`, `lastToolPreparation`, `gatesAfterTurn`, `lastTurnRoom`) are in [Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker).

```swift
extension LocalLMLabSession {
    // A turn with attachments: with dynamic tools, an attached file's type picks the plug-in whose card lists it.
    func respond(to prompt: String, attachments: [URL] = [], options: SessionOptions = SessionOptions(),
                 fromAppInstance instance: String? = nil) async throws -> String
    func streamResponse(to prompt: String, attachments: [URL] = [], options: SessionOptions = SessionOptions(),
                        fromAppInstance instance: String? = nil) -> AsyncThrowingStream<String, any Error>

    var retriesEmptyReply: Bool                        // false: an EmptyReply turn is run again up to emptyReplyRetries times
    static let emptyReplyRetries: Int                  // 2
    var trimsOldResults: Bool                          // false: past half the window (or 64,000 tokens), older long results become notes, last 3 exchanges whole
    var sendsImagesToModel: Bool                       // false: image attachments go in the prompt (vision models only; others throw)
    var framesUntrustedContent: Bool                   // false: outside content reaches the model framed as data (ContentFrame)
    var asksBeforeSendingReadContent: Bool             // false: a call sending out text the assistant read asks even on a trusted server
    var auditConversation: String?                     // the conversation audit entries name; ChatController sets its chat's ID

    func linkSources(in text: String) async -> [(url: URL, source: LinkSource)]   // each link in a reply and where it came from; reads images (≤1 s each)
    func linkSources(in text: String) -> [(url: URL, source: LinkSource)]         // without waiting: a link only in an image is .unsourced
    func setUnansweredTurns(_ turns: Set<Int>)         // ConversationMeta.unanswered: left out of what the picker reads
    @discardableResult func setAsideToolResults() -> Bool   // after a model-service failure: earlier results and images become notes
    func waitUntilCallsEnd() async                     // returns once the provider's calls have; respond/streamResponse wait on it themselves
}

// PermissionAsking (.onCall / .bestMatch / .everyChosenPlugin): see Dynamic tools.
// LinkSource and ReplyLinks (where each link in a reply came from): see Tool authority, "Content the model read".
// SessionEvent, including 3.0's toolCallStillRunning, emptyReply and toolsRequested: see The model layer.

// ToolCallRecord fields added in 3.0, so a drawn row doesn't change after the fact
extension ToolCallRecord {
    var stillRunningSeconds: Int? { get }   // past 15 s, updated every 15 s; stays set once the call ends, so check `state`
    var sourceName: String? { get }         // the source's name when the call was made; nil in older chats
    var impact: ToolImpact? { get }         // a plug-in tool's own rating when the call was made
    var serverTrusted: Bool? { get }        // an MCP tool: whether its server was trusted at the time
}

extension ModelProvider {   // provider hooks the session calls; defaults shown
    func waitUntilCallsEnd(conversation: String) async   // returns at once; override when a cancelled call takes a moment to end
    func contextWindow(for id: ModelID) async -> Int?    // nil: falls back to ContextBudget.windowHint
}
```

A session's image attachments are outside content too. Their text is read with Vision and counts as content for the
injection checks. Text that OCR can't read stays unseen, so still tell the model in your instructions to treat what
images say as data ([Content is content](security-guide-for-hosts.md#5-content-is-content)).

## MCP client

`LocalLMLabSDKCore`'s MCP client: `MCPServerManager` holds the servers, and every other type here describes what
it holds, what a call returns, or how it talks to a server. In an app built on `LocalLMLab`, `lab.mcp` is the
manager, set up from `MCPSettings`. The guide is [the MCP client guide](mcp-guide.md); the 3.0 additions are
summarized under [MCP servers](sdk-guide.md#mcp-servers), and how trust, approval and drift protect the user is in
[the security guide](security-guide-for-hosts.md#4-servers-trust-approval-and-drift).

### `MCPServerManager`

One manager per app (it is not a singleton). Servers are connected only when needed: add a server with
`stayConnected: false` to list its tools and disconnect, and a session connects it (`activate`) when a turn picks one
of its tools. The manager saves nothing to disk: save `snapshot()` and pass it to `restore(from:)` at the next launch.
Trust, approval and drift types (`MCPServerTrust`, `ToolApproval`, `DriftPolicy`, `DriftAction`, `DriftCause`,
`ToolDrift`, `SecurityAudit`) are in [Tool authority](#tool-authority-toolcallauthorizer-toolimpact-confirmation), the
kinds of tool change (`ToolChange`) under [Dynamic tools](#dynamic-tools-dynamictools-plug-ins-the-tool-picker), and
`ExternalProgramsSwitch`, `MCPStdioLaunch` and `MCPLocalServerStart` under
[Local programs](#local-programs-direct-download-builds-only).

```swift
@MainActor final class MCPServerManager {
    init(responseLimits: MCPResponseLimits = .default, handlers: MCPClientHandlers = MCPClientHandlers(),
         versionNegotiation: MCPVersionNegotiation = .auto, liveUpdates: Bool = true)   // liveUpdates: false ⇒ no subscriptions/listen
    private(set) var servers: [MCPServerID: MCPServerState] { get }
    var serverChanges: AsyncStream<[MCPServerID: MCPServerState]> { get }   // the whole dictionary on every change, current value first
    var estimatedTotalTokens: Int { get }   // tool tokens of every connected, enabled server (toolsForSession's filter)
    var audit: SecurityAudit { get }        // the lab's audit stream when it belongs to one, else its own

    // --- adding, connecting, removing -------------------------------------------------
    // stayConnected: false ⇒ sign in, list tools/resources/prompts, keep them, disconnect (state .disconnected, toolsListedAt set).
    // initialTools: whether a first listing's tools start enabled (static tools); later tools always start off.
    // interactiveSignIn: false ⇒ never opens a browser; a server that needs a sign-in fails with .authorizationRequired.
    func addServer(url: URL, displayName: String, authType: MCPAuthType = .none, patToken: String? = nil,
                   manualClientID: String? = nil, stayConnected: Bool = true,
                   initialTools: MCPInitialTools = .none, interactiveSignIn: Bool = true) async -> Result<MCPServerState, MCPServerError>
    func reconnect(_ id: MCPServerID) async -> Result<MCPServerState, MCPServerError>   // the user's reconnect; may sign in interactively
    // Connects a known server for a turn, never opening a browser. Already connected: returns at once.
    // No stored PAT ⇒ .credentialRejected; needs an OAuth sign-in ⇒ .authorizationRequired. Ask the user, then reconnect.
    func activate(_ id: MCPServerID) async -> Result<MCPServerState, MCPServerError>
    func isLive(_ id: MCPServerID) -> Bool   // connected, and the connection can still carry calls (a crashed local server's can't)
    func disconnect(_ id: MCPServerID)       // closes the connection; the entry and its cached tools stay (.disconnected)
    func removeServer(_ id: MCPServerID)     // forgets the server and clears its Keychain OAuth/PAT token
    func removeAllKeepingCredentials()       // drops every server but leaves Keychain tokens — pair with restore(from:) for a profile load

    // --- servers connected for a turn ---------------------------------------------------
    var idleTimeout: Duration?               // disconnect a turn-connected server after this long without a call; nil (default) = never
    var serversConnectedForTurns: Set<MCPServerID> { get }   // connected by activate and still connected
    @discardableResult func disconnectIdle(after idle: Duration) -> [MCPServerID]   // sweep now; returns what it disconnected

    // --- local (stdio) servers ----------------------------------------------------------
    // Starts the program, lists its tools, and (stayConnected: false) stops it. secrets go to the Keychain and reach
    // the program as environment variables. Fails with .serverError while externalPrograms is off, in a sandboxed
    // process, for an unpinned package runner, or for an environment name that changes what runs.
    func addStdioServer(_ launch: MCPStdioLaunch, displayName: String, secrets: [String: String] = [:],
                        stayConnected: Bool = false) async -> Result<MCPServerState, MCPServerError>
    func stopLocalServers()                  // stop every local server now (the switch went off); cached tools stay
    var externalPrograms: ExternalProgramsSwitch?   // local servers start only while it's on; LocalLMLab sets lab.externalPrograms
    // Asked before every start (adding, reconnecting, for a turn, after a crash). false ⇒ not started.
    // nil: adding and reconnecting start it; a start for a turn or after a crash doesn't.
    var localServerStartApproval: (@MainActor @Sendable (MCPLocalServerStart) async -> Bool)?
    var localServerCrashLimit: Int           // default 3 unexpected stops within localServerCrashWindow ⇒ not restarted until reconnect
    var localServerCrashWindow: Double       // seconds, default 300

    // --- tools ----------------------------------------------------------------------------
    func toolsForSession() -> [MCPToolDescriptor]   // static tools: enabled, model-visible tools of connected, enabled servers; drift-held tools left out
    func setToolEnabled(_ enabled: Bool, server: MCPServerID, tool: String)   // static tools: in every prompt or not
    func setToolExcluded(_ excluded: Bool, server: MCPServerID, tool: String) // dynamic tools: never offer this tool (the user's opt-out)
    func isToolExcluded(server: MCPServerID, tool: String) -> Bool
    // The tool-name prefix the model sees (gh ⇒ gh_list_issues), sanitized first. Returns the prefix in use, or nil
    // when nothing changed (unknown server, nothing left after sanitizing, or another server has it).
    @discardableResult func setToolPrefix(_ prefix: String, server: MCPServerID) -> String?
    // Offer this server's tools to LocalLMLab sessions as FileBackedTools writing under output.root; nil (default) = plain tools.
    // Not in snapshot(): set it again at launch. Widget calls (callMCPTool) are unaffected.
    func setFileBackedOutput(_ output: MCPFileBackedOutput?, server: MCPServerID)
    func fileBackedOutput(server: MCPServerID) -> MCPFileBackedOutput?
    // -> MCPToolResult, not a String. A tool that ran but failed is .success with isError == true.
    // Needs a live connection (.notConnected otherwise; a session activates the servers it picks).
    // Empty optional arguments are stripped (MCPValue.strippingEmpty); structuredContent is checked against outputSchema.
    // allowElicitation: false on a path that can't show a prompt (headless / background): the server gets a decline.
    func callTool(server: MCPServerID, tool: String, arguments: [String: MCPValue],
                  allowElicitation: Bool = true) async -> Result<MCPToolResult, MCPServerError>

    // --- trust and approval (Tool authorization) -------------------------------------------
    func setTrust(_ trust: MCPServerTrust, server: MCPServerID)            // .trusted ⇒ its annotations set each tool's impact
    func setToolApproval(_ approval: ToolApproval?, server: MCPServerID)   // nil ⇒ ToolApproval.default(for: trust)
    func setToolApproval(_ approval: ToolApproval?, server: MCPServerID, tool: String)  // one tool, over the server's; nil ⇒ the server's
    func toolApproval(server: MCPServerID) -> ToolApproval                 // the server's effective approval
    func toolApproval(server: MCPServerID, tool: String) -> ToolApproval   // the tool's own, else the server's; read on every call

    // --- drift: tool changes since the accepted list ----------------------------------------
    var driftPolicy: DriftPolicy             // default .standard; setting it re-judges pending drift (reevaluateDrift())
    func reevaluateDrift()                   // re-judge every server's pending drift from the lists held, no reconnect
    func acceptDrift(server: MCPServerID)    // current tools become the accepted list; held tools are offered again
    func rejectDrift(server: MCPServerID)    // disconnects and turns the server off; the drift stays on record
    // The baseline drift is measured against (e.g. a list the app ships), from the next connect or refresh.
    func setAcceptedTools(_ tools: [MCPToolDescriptor], serverName: String? = nil, server: MCPServerID)

    // --- resources and prompts -------------------------------------------------------------
    func resourcesForSession() -> [MCPResourceDescriptor]                 // enabled resources of connected, enabled servers; ui:// left out
    func resourceTemplatesForSession() -> [MCPResourceTemplateDescriptor] // every template; ui:// left out
    func setResourceEnabled(server: MCPServerID, uri: String, enabled: Bool)   // visibility / attachability in your UI
    func setResourceExcluded(_ excluded: Bool, server: MCPServerID, uri: String)  // dynamic tools: the assistant may not read it
    func returnedResource(server: MCPServerID, uri: String) -> Bool       // a tool of this server returned uri in this run
    func readResource(server: MCPServerID, uri: String) async -> Result<MCPResourceContent, MCPServerError>   // on demand only
    func promptsForSession() -> [MCPPromptDescriptor]                     // list-only; prompts are the user's to pick
    func getPrompt(server: MCPServerID, name: String, arguments: [String: String]) async -> Result<[MCPPromptMessage], MCPServerError>
    // Suggestions for an argument as the user types (completion/complete): up to 100, or [] when the server offers
    // none or fails. Never connects a server.
    func complete(server: MCPServerID, _ reference: MCPCompletionReference, argument: String, value: String,
                  context: [String: String] = [:]) async -> [String]

    // --- saving and restoring ---------------------------------------------------------------
    func snapshot() -> [MCPServerSnapshot]   // every server, in ID order: cached tools, trust, approvals, exclusions, drift
    func restore(from snapshots: [MCPServerSnapshot])   // as disconnected entries with those settings; an ID already present is left alone

    @available(*, deprecated, renamed: "setToolEnabled(_:server:tool:)")
    func setToolEnabled(server: MCPServerID, tool: String, enabled: Bool)
    @available(*, deprecated, message: "Save snapshot() and use restore(from: [MCPServerSnapshot])")
    func restore(_ states: [MCPServerState])            // drops trust, approvals and exclusions
    @available(*, deprecated, message: "Save snapshot() and use restore(from: [MCPServerSnapshot])")
    func restore(from persisted: [(id: MCPServerID, url: URL, displayName: String, tools: [MCPToolDescriptor], estimatedTokens: Int,
                                  enabled: Bool, authType: MCPAuthType, manualClientID: String?,
                                  resources: [(uri: String, name: String, enabled: Bool)])])   // loses settings and pending drift
}

// Whether a server's tools start enabled on its first listing (static tools). Dynamic sessions ignore `enabled`.
enum MCPInitialTools: Sendable, Equatable {
    case none   // default: every tool off until the user turns it on
    case all    // every tool on — for a host whose user has just approved the server
}
```

Static tools (`makeSession(tools:)` with `toolsForSession()`) follow each tool's `enabled` flag. Dynamic tools
(`makeSession(dynamicTools:)`) ignore it: every model-visible tool of an enabled server is offered when relevant
unless the user excluded it or drift holds it, plus one read tool per server for its resources (`MCPContentReader`).

### Saving servers: `MCPServerSnapshot`

What a relaunch needs for one server. No secrets: PAT and OAuth tokens stay in the Keychain. Restoring keeps the
accepted list and pending drift, so tools held for review are still held after the app restarts.

```swift
struct MCPServerSnapshot: Codable, Sendable {
    static let currentVersion: Int   // 1
    var version: Int
    var id: MCPServerID; var url: URL; var displayName: String
    var authType: MCPAuthType; var manualClientID: String?
    var enabled: Bool                // off when the user (or rejectDrift) turned the server off
    var tools: [MCPToolDescriptor]; var resources: [MCPResourceDescriptor]
    var resourceTemplates: [MCPResourceTemplateDescriptor]; var prompts: [MCPPromptDescriptor]
    var serverName: String?          // the name the server reports, for drift's identity check
    var toolsListedAt: Date?
    var trust: MCPServerTrust; var trustedToolsDigest: String?
    var toolApproval: ToolApproval?; var toolApprovals: [String: ToolApproval]
    var excludedTools: Set<String>; var excludedResources: Set<String>
    var acceptedTools: [MCPToolDescriptor]?; var acceptedServerName: String?; var pendingDrift: ToolDrift?
    var stdio: MCPStdioLaunch?       // a local server's launch (secrets stay in the Keychain)
    var toolPrefix: String?          // nil in an older snapshot: restoring derives one
    var addedAt: Date?
    init(_ state: MCPServerState)
    // For a host moving from its own saved format; with no accepted list, the tools become the baseline on restore.
    init(id: MCPServerID, url: URL, displayName: String, authType: MCPAuthType = .none, manualClientID: String? = nil,
         enabled: Bool = true, tools: [MCPToolDescriptor] = [], resources: [MCPResourceDescriptor] = [],
         trust: MCPServerTrust = .untrusted, toolApproval: ToolApproval? = nil, toolApprovals: [String: ToolApproval] = [:],
         excludedTools: Set<String> = [], acceptedTools: [MCPToolDescriptor]? = nil, pendingDrift: ToolDrift? = nil)
}
```

### Server state and descriptors

```swift
struct MCPServerID: Hashable, Codable, Sendable {   // the server's URL string; encodes as a bare JSON string
    let rawValue: String
    init(rawValue: String)
}

struct MCPServerState: Codable, Sendable {
    var id: MCPServerID
    var url: URL                          // a local server's is mcp-stdio:… (MCPStdioLaunch.url)
    var displayName: String
    var connectionStatus: MCPConnectionStatus
    var tools: [MCPToolDescriptor]
    var estimatedTokens: Int
    var enabled: Bool
    var authType: MCPAuthType
    var patTokenLastFour: String?         // masked display only, never the real token; nil until connected this launch
    var manualClientID: String?
    var resources: [MCPResourceDescriptor]
    var resourceTemplates: [MCPResourceTemplateDescriptor]
    var prompts: [MCPPromptDescriptor]
    var negotiatedProtocolVersion: MCPProtocolVersion?   // nil until connected
    var serverInstructions: String?       // the server's own usage note
    var liveUpdates: MCPLiveUpdates?      // nil when not listening
    var trust: MCPServerTrust             // setTrust (default .untrusted)
    var toolApproval: ToolApproval?       // nil = default for the trust level
    var toolApprovals: [String: ToolApproval]   // per-tool approvals, by tool name
    var excludedTools: Set<String>        // dynamic tools the user said never to offer
    var excludedResources: Set<String>    // resources the assistant may not read, by URI
    var heldTools: Set<String>            // tools drift holds until acceptDrift: offered in no session
    var acceptedTools: [MCPToolDescriptor]?   // the baseline drift is measured against (first listing, acceptDrift, setAcceptedTools)
    var acceptedServerName: String?       // the server's name when its tools were accepted
    var serverName: String?               // the name it reports now
    var pendingDrift: ToolDrift?          // changes the drift policy didn't accept — show for review, then acceptDrift(server:)
    var trustedToolsDigest: String?       // the tool list when last trusted
    var toolPrefix: String?               // prefix of this server's tool names for the model (setToolPrefix)
    var stdio: MCPStdioLaunch?            // a local server's launch; nil over HTTP
    var addedAt: Date?                    // when it was added (newest first); nil from an older snapshot
    var toolsListedAt: Date?              // when tools were last fetched; kept across a disconnect
    @available(*, deprecated, message: "Use pendingDrift and acceptDrift(server:)")
    var toolsChangedSinceTrusted: Bool { get }
    func exportSummary() -> String        // plain-text listing of tools/resources/prompts, enabled state, token cost
}

enum MCPAuthType: String, Codable, Sendable { case none, pat, oauthManual }   // OAuth is discovered from a 401, not declared
// Non-frozen, like MCPServerError: an exhaustive switch needs `@unknown default`.
enum MCPConnectionStatus: String, Codable, Sendable { case connected, disconnected, connecting, failed }

struct MCPToolDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var name: String             // the server's tool name; sessions show the model <prefix>_<name>
    var description: String
    var rawSchema: Data          // the tool's real JSON schema — inspect before assuming params
    var estimatedTokens: Int
    var enabled: Bool            // static tools; addServer starts new tools off (see initialTools)
    var title: String?           // human display name (2025-06-18+); fall back to name
    var outputSchema: Data?      // declared shape of structuredContent, if any
    var meta: MCPValue?          // the tool's _meta
    var annotations: MCPToolAnnotations?   // nil ⇒ spec defaults: not read-only, destructive
    var app: MCPAppLink? { get }           // its MCP App view (_meta.ui.resourceUri), if any
    var appVisibility: Set<MCPAppVisibility> { get }   // _meta.ui.visibility; [.model, .app] when absent, [] when malformed
    var isModelVisible: Bool { get }       // false for app-only tools: never offered to a model
    init(serverID: MCPServerID, name: String, description: String, rawSchema: Data, estimatedTokens: Int, enabled: Bool = true,
         title: String? = nil, outputSchema: Data? = nil, meta: MCPValue? = nil, annotations: MCPToolAnnotations? = nil)
}
// Hints from the server, not guarantees: believed only for a trusted server.
struct MCPToolAnnotations: Codable, Sendable, Equatable {
    var title: String?; var readOnlyHint: Bool?; var destructiveHint: Bool?; var idempotentHint: Bool?; var openWorldHint: Bool?
    init(title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil, openWorldHint: Bool? = nil)
    var isReadOnly: Bool { get }      // readOnlyHint ?? false
    var isDestructive: Bool { get }   // !isReadOnly && (destructiveHint ?? true)
}
struct MCPAppLink: Sendable, Equatable, Hashable {   // a tool's link to its MCP App view
    var resourceURI: String                  // the ui:// resource to render its result in
    var visibility: Set<MCPAppVisibility>    // who may call the tool
    init(resourceURI: String, visibility: Set<MCPAppVisibility>)
}
enum MCPAppVisibility: String, Sendable, Codable, Hashable, CaseIterable { case model, app }

struct MCPResourceDescriptor: Codable, Sendable {
    var serverID: MCPServerID; var uri: String; var name: String; var description: String; var mimeType: String?
    var enabled: Bool            // defaults to true
    var title: String?
    var meta: MCPValue?          // _meta from resources/list (MCP Apps: _meta.ui)
    var isMCPAppResource: Bool { get }   // a ui:// view's HTML: left out of model-facing resource lists
    init(serverID: MCPServerID, uri: String, name: String, description: String, mimeType: String? = nil,
         enabled: Bool = true, title: String? = nil, meta: MCPValue? = nil)
}
struct MCPResourceTemplateDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var uriTemplate: String      // e.g. "res://{id}" — fill it with MCPContentReader.fill(_:with:)
    var name: String; var description: String; var mimeType: String?; var title: String?
    var isMCPAppResource: Bool { get }
}
struct MCPResourceContent: Codable, Sendable, Equatable {   // exactly one of text/blob is non-nil
    var uri: String; var mimeType: String?
    var text: String?
    var blob: String?            // base64
    var meta: MCPValue?          // the entry's _meta (an MCP App's CSP / permissions)
    var decodedText: String? { get }   // text, or a text-typed blob (text/*, JSON, XML) decoded as UTF-8; nil for other binary
    init(uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil, meta: MCPValue? = nil)
}

struct MCPPromptArgument: Codable, Sendable { var name: String; var description: String; var required: Bool }
struct MCPPromptDescriptor: Codable, Sendable {
    var serverID: MCPServerID; var name: String; var description: String; var arguments: [MCPPromptArgument]; var title: String?
}
// One message of prompts/get: text, an image, an embedded resource, or a resource link.
struct MCPPromptMessage: Codable, Sendable {
    var role: String
    var text: String                     // empty for a message that carries something else
    var image: MCPPromptImage?
    var resource: MCPResourceContent?
    var resourceLink: MCPResourceLink?
    var unsupported: String?             // a content type the app can't use ("audio"), named instead of dropped
    init(role: String, text: String = "", image: MCPPromptImage? = nil, resource: MCPResourceContent? = nil,
         resourceLink: MCPResourceLink? = nil, unsupported: String? = nil)
}
struct MCPPromptImage: Codable, Sendable, Equatable {   // also a tool result's image
    var data: String             // base64
    var mimeType: String
    init(data: String, mimeType: String)
}
// What completion/complete is asked about.
enum MCPCompletionReference: Sendable, Equatable {
    case prompt(name: String)                    // a prompt's argument
    case resourceTemplate(uriTemplate: String)   // a part of a template's address
}

indirect enum MCPValue: Codable, Sendable, Equatable {   // any JSON value; encodes as plain JSON
    case string(String), number(Double), bool(Bool), array([MCPValue]), object([String: MCPValue]), null
    func strippingEmpty() -> MCPValue?      // drop ""/[]/null and objects that collapse — the
                                            // "did the user/model actually supply this?" rule
}

enum MCPServerError: Error, Codable, Sendable {   // non-frozen
    case unreachable
    case malformedResponse
    case protocolMismatch                    // the server negotiated below MCPProtocolVersion.minimumSupported
    case notConnected
    case toolNotFound
    case serverError(String)                 // includes real HTTP status/URL/body where available; local-server refusals
    case authorizationRequired               // OAuth sign-in needed and didn't complete (or interactiveSignIn: false)
    case credentialRejected                  // PAT rejected or missing — no retry path but a new token
    case httpError(Int)
    case oauthRegistrationNotSupported       // no DCR — retry with .oauthManual + manualClientID
    case responseTooLarge(String)            // a response exceeded MCPResponseLimits
}
```

### Tool names and labels

Every tool of a server reaches the model as `<prefix>_<tool>` (`github_list_issues`), with a header on its
description naming the service; the tool's own name is kept in records, approvals and refs. The manager assigns each
server a prefix (`MCPServerState.toolPrefix`); `setToolPrefix(_:server:)` changes it. `MCPToolLabels` sums up what a
server says its tools do, for an "added" notice or a "trust this server" confirmation.

```swift
enum MCPToolNaming {
    static let exceptions: [String: (prefix: String, name: String)]   // hosts whose domain doesn't say the service (api.githubcopilot.com ⇒ github)
    // From the domain (gitmcp.io ⇒ gitmcp, api.brevo.com ⇒ brevo), an exception, or a local server's package or program;
    // else fallback (the display name), else "mcp". Before clashes.
    static func derivedPrefix(for url: URL, fallback: String = "") -> String
    static func sanitized(_ prefix: String) -> String?   // lowercase letters and digits, starting with a letter, ≤ 16 chars; nil if nothing is left
    static func unique(_ base: String, taken: Set<String>) -> String   // base, base2, base3… — the first not taken
    static func toolName(_ tool: String, prefix: String) -> String     // "github_list_issues"
    static func serviceName(prefix: String, url: URL) -> String        // an exception's name ("GitHub"), else the prefix
    static func descriptionHeader(serviceName: String, displayName: String) -> String   // "GitHub (you call it GH): " or "GitHub: "
}

struct MCPToolLabels: Sendable {      // from the tools' annotations
    var reads: [String]; var changes: [String]; var deletes: [String]; var unlabelled: [String]   // tool names
    init(_ tools: [MCPToolDescriptor])
    var trustEffect: String { get }   // what trusting the server means: which tools would run without asking
    var summary: String { get }       // "15 only read, 6 change data, 2 can delete, 1 unlabelled"
    static func addedSummary(name: String, tools: [MCPToolDescriptor], trusted: Bool) -> String   // "Brevo added (untrusted): 23 tools. …"
}
```

### Tool results and limits

What `callTool` returns ([MCP tool results](mcp-guide.md#what-a-tool-call-gives-you-back-mcptoolresult)), and the
caps on what a server may send. A large dataset can go to a file instead of the model's context: see
`MCPFileBackedOutput` and [`FileBackedTool`](sdk-guide.md#filebackedtool--the-aiql-data-verbs-a-mechanical-mcp-dataset--csv-pipeline).

```swift
struct MCPToolResult: Sendable, Codable, Equatable {
    var text: String                         // joined text content
    var structuredContent: MCPValue?         // validated against outputSchema
    var resourceLinks: [MCPResourceLink]
    var isError: Bool                        // the tool ran and reported failure — the model should see it and correct
    var truncated: Bool                      // the client cut an over-budget result
    var meta: MCPValue?                      // the result's _meta (view-only data for an MCP App)
    var images: [MCPPromptImage]?            // shown to the user; the model gets a note
    var embeddedResources: [MCPResourceContent]?   // text goes to the model; binary gets a note
    var unsupportedContent: [String]?        // content types the app can't use ("audio"), named
    init(text: String = "", structuredContent: MCPValue? = nil, resourceLinks: [MCPResourceLink] = [], isError: Bool = false,
         truncated: Bool = false, meta: MCPValue? = nil, images: [MCPPromptImage]? = nil,
         embeddedResources: [MCPResourceContent]? = nil, unsupportedContent: [String]? = nil)
    var renderedForModel: String { get }     // compact rendering folding in all of the above
    func renderedForModel(maxCharacters: Int) -> String   // at most maxCharacters (0: all), with a note saying how much was cut
    var rawPayload: String { get }           // as close to raw as possible (the server's text, else structuredContent as JSON) — for saveAs
}
struct MCPResourceLink: Sendable, Codable, Equatable {   // a pointer to a resource, not its content
    var uri: String; var name: String?; var title: String?; var description: String?; var mimeType: String?
    init(uri: String, name: String? = nil, title: String? = nil, description: String? = nil, mimeType: String? = nil)
}

// Upper bounds applied to untrusted server responses.
struct MCPResponseLimits: Sendable, Equatable {
    var maxResponseBytes: Int           // one JSON-RPC HTTP response body (8 MB)
    var maxDescriptorCount: Int         // tools / resources / templates / prompts in one */list (512)
    var maxSchemaBytes: Int             // one tool's inputSchema (128 KB)
    var maxTextFieldLength: Int         // a name or description, in characters (16 K)
    var maxInlineContentBytes: Int      // inline tools/call or resources/read content (1 MB)
    var maxUIResourceBytes: Int         // one ui:// view's HTML (4 MB); maxResponseBytes applies first
    var maxModelResultCharacters: Int   // one tool result as the model sees it (20,000, about 5,000 tokens); 0 = whole
    var maxAttachedContentBytes: Int    // one shared resource saved for attaching, decoded (32 MB)
    init(maxResponseBytes: Int = 8 * 1024 * 1024, maxDescriptorCount: Int = 512, maxSchemaBytes: Int = 128 * 1024,
         maxTextFieldLength: Int = 16 * 1024, maxInlineContentBytes: Int = 1 * 1024 * 1024,
         maxUIResourceBytes: Int = 4 * 1024 * 1024, maxModelResultCharacters: Int = 20_000,
         maxAttachedContentBytes: Int = 32 * 1024 * 1024)
    static let `default`: MCPResponseLimits
}

// How a LocalLMLab session offers one server's tools file-backed (MCPServerManager.setFileBackedOutput(_:server:)).
struct MCPFileBackedOutput: Sendable, Equatable {
    var root: URL                    // the folder saveAs paths resolve under; the host must already have access to it
    var previewCharacters: Int       // how much of a saved result the receipt echoes back
    var inlineCharacterLimit: Int?   // without saveAs, truncate past this; nil = never
    var followUp: String             // how the model should process the file, woven into each description
    var saveAsPolicy: SaveAsPolicy   // where saveAs may write (default: raw/, data-file extensions, no hidden paths)
    init(root: URL, previewCharacters: Int = 600, inlineCharacterLimit: Int? = nil,
         followUp: String = "read it back a window at a time with readFileRange", saveAsPolicy: SaveAsPolicy = .default)
}
```

### Resources and prompts in chat: `MCPContentReader`

Resources are the app's to use: with dynamic tools, each server that shares content gets one read tool
(`<prefix>_read_shared_content`), read-only whatever the server's trust, listing what the user allows it to read.
The user can also attach a resource, and pick a server's prompt to fill the message box. A prompt is never sent on
its own, and the model never picks one.

```swift
enum MCPContentReader {
    static let toolName: String   // "read_shared_content"; a server whose own tools use the name gets no read tool
    // What a user can attach: each server with content the assistant may read, its allowed resources and templates.
    // Servers the user added, connected or not (reading connects).
    @MainActor static func attachable(in manager: MCPServerManager) -> [(server: MCPServerState, resources: [MCPResourceDescriptor],
                                                                       templates: [MCPResourceTemplateDescriptor])]
    static func parts(of template: String) -> [String]                    // "hf://models/{repo}/README.md" ⇒ ["repo"]
    static func fill(_ template: String, with values: [String: String]) -> String
    // Reads uri and saves it as a file to attach (text as text, binary decoded); folder: a new temporary one by default.
    @MainActor static func saveForAttaching(_ uri: String, server: MCPServerID, manager: MCPServerManager, name: String? = nil,
                                            folder: URL? = nil) async -> Result<URL, MCPContentReader.AttachError>
    // The prompts a user can pick: each enabled server's, as last fetched.
    @MainActor static func prompts(in manager: MCPServerManager) -> [(server: MCPServerState, prompts: [MCPPromptDescriptor])]
    // Gets the prompt (connecting an idle server first) and turns it into message-box content.
    @MainActor static func fill(prompt: String, server: MCPServerID, arguments: [String: String], manager: MCPServerManager,
                                folder: URL? = nil) async -> Result<MCPContentReader.PromptFill, MCPContentReader.AttachError>

    struct PromptFill: Sendable {   // for the user to read, edit and send
        var text: String            // the messages' text
        var files: [URL]            // its images and embedded resources, saved to attach
        var notes: [String]         // plain notes for anything left out
    }
    struct AttachError: Error, Sendable { let message: String }   // a plain reason
}
```

### Local (stdio) servers

A local server is a program the app starts and talks MCP to over stdin and stdout, in a sandbox. It runs only while
`lab.externalPrograms` is on and never in an App Sandbox build. Add one with
`MCPServerManager.addStdioServer(_:displayName:secrets:stayConnected:)`; the manager asks
`localServerStartApproval` before every start. `MCPStdioLaunch` (how it's started) and `MCPLocalServerStart` (what
the approver is asked, with its `Reason`) are documented under
[Local programs](#local-programs-direct-download-builds-only), with `ExternalProgramsSwitch` and `SandboxProfile`;
the rules are in [Programs on the Mac](security-guide-for-hosts.md#6-programs-on-the-mac). A local server's
`MCPServerState.url` is `MCPStdioLaunch.url` (`mcp-stdio:…`), its `stdio` holds the launch, and its tool prefix comes
from its package or program name.

### Pasting a server setup: `MCPServerConfigPaste`

Reads a pasted JSON setup (Claude Desktop's `mcpServers`, VS Code's `servers`, one `"name": { … }` entry, or a bare
`command` and `args`) to fill an add-server form.

```swift
enum MCPServerConfigPaste {
    static func looksLikeConfiguration(_ text: String) -> Bool   // JSON rather than an address or a command line
    static func parse(_ text: String) throws -> [MCPServerConfigEntry]   // in the order written; throws Problem
    struct Problem: Error, LocalizedError, Equatable { let reason: String; var errorDescription: String? { get } }   // a plain reason
}
struct MCPServerConfigEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case local(command: String, arguments: [String], environment: [String: String])   // command, args, env
        case web(url: URL, bearerToken: String?)   // url, with a bearer token when its headers carry one
    }
    var name: String
    var kind: Kind
    var commandLine: String? { get }   // "npx -y @playwright/mcp@1.2.3", arguments with spaces quoted; nil for .web
}
```

### Protocol revisions and live updates

([MCP revisions](mcp-guide.md#which-mcp-revision-the-client-speaks--and-why-you-mostly-dont-have-to-care))

```swift
enum MCPProtocolVersion: String, CaseIterable, Comparable, Sendable, Codable {   // Comparable in release order
    @available(*, deprecated, message: "2024-11-05 is no longer negotiated; see minimumSupported")
    case v2024_11_05 = "2024-11-05"   // kept so stored values decode
    case v2025_03_26 = "2025-03-26", v2025_06_18 = "2025-06-18"
    case v2025_11_25 = "2025-11-25", v2026_07_28 = "2026-07-28"
    static let clientPreferred: MCPProtocolVersion       // .v2025_11_25, offered at initialize
    static let statelessPreferred: MCPProtocolVersion    // .v2026_07_28, probed with server/discover
    static let minimumSupported: MCPProtocolVersion      // .v2025_03_26; lower ⇒ .protocolMismatch
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

// Live updates (2026-07-28 subscriptions/listen): the manager runs them and refreshes lists on a change.
// Read MCPServerState.liveUpdates; opt out with MCPServerManager(liveUpdates: false).
enum MCPLiveUpdates: Sendable, Codable, Equatable {
    case active(MCPSubscriptionFilter)   // listening; what the server granted
    case reconnecting                    // stream dropped, retrying with backoff
    case unavailable(String)             // refused or sign-in expired; resumes on next connect
}
struct MCPSubscriptionFilter: Sendable, Codable, Equatable {   // what to ask for, or what was granted
    var toolsListChanged: Bool; var promptsListChanged: Bool; var resourcesListChanged: Bool
    init(toolsListChanged: Bool = false, promptsListChanged: Bool = false, resourcesListChanged: Bool = false)
    var isEmpty: Bool { get }
}
```

### Server-initiated requests

([Server-initiated requests](mcp-guide.md#server-initiated-requests-elicitation-and-the-sampling--roots-seams)) All
optional; a capability is advertised to a server only when its handler is non-nil. Components ships
`MCPElicitationPresenter`, a ready-made elicitation handler.

```swift
struct MCPClientHandlers: Sendable {
    var elicitation: (any MCPElicitationHandler)?
    var sampling: (any MCPSamplingHandler)?
    var roots: (any MCPRootsProvider)?
    var logging: (any MCPLoggingSink)?
    var extensions: [String: MCPValue]   // client capability extensions declared at initialize, by extension id
    init(elicitation: (any MCPElicitationHandler)? = nil, sampling: (any MCPSamplingHandler)? = nil,
         roots: (any MCPRootsProvider)? = nil, logging: (any MCPLoggingSink)? = nil, extensions: [String: MCPValue] = [:])
}
// LocalLMLabSDKMCPAppsHost: MCPClientHandlers().advertisingMCPApps() declares MCP Apps support
// (extensions["io.modelcontextprotocol/ui"]), which servers check before offering views.

protocol MCPElicitationHandler: Sendable {
    func handleElicitation(_ request: MCPElicitationRequest) async -> MCPElicitationResponse
}
struct MCPElicitationRequest: Sendable, Equatable {
    var message: String
    var rawSchema: Data                       // the raw requestedSchema, for custom rendering
    var fields: [MCPElicitationField]         // requestedSchema flattened, in declaration order
    var url: URL?                             // URL-mode elicitation (2025-11-25): complete an interaction at this URL
    var serverName: String?                   // which server is asking — show this
    var serverURL: URL?
    init(message: String, rawSchema: Data, fields: [MCPElicitationField], url: URL? = nil,
         serverName: String? = nil, serverURL: URL? = nil)
    // Why the request is declined before anyone sees it: a field asks for a password, key, token or card number,
    // or a URL-mode request would open something other than a web address. nil = show it.
    var refusal: String? { get }
}
struct MCPElicitationField: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case string(format: String?)          // "email" / "uri" / "date" / nil
        case number(minimum: Double?, maximum: Double?)
        case integer(minimum: Double?, maximum: Double?)
        case boolean
        case enumeration(options: [String], optionTitles: [String]?, multiSelect: Bool)   // optionTitles: display labels
    }
    var name: String; var title: String?; var description: String?
    var required: Bool; var defaultValue: MCPValue?; var kind: Kind
    init(name: String, title: String?, description: String?, required: Bool, defaultValue: MCPValue?, kind: Kind)
    var looksLikeSecret: Bool { get }         // a text field whose name, title, description or format wants a secret
}
enum MCPElicitationResponse: Sendable, Equatable {
    case accept([String: MCPValue])   // keys match the field names
    case decline                      // the user said no
    case cancel                       // dismissed without deciding
}

// Sampling and roots: seams only (deprecated in 2026-07-28).
protocol MCPSamplingHandler: Sendable {      // your handler owns the human-in-the-loop approval
    func handleSampling(_ request: MCPSamplingRequest) async -> MCPSamplingResponse?   // nil = decline
}
struct MCPSamplingRequest: Sendable, Equatable { var rawParams: Data }   // raw sampling/createMessage params, for your own model
struct MCPSamplingResponse: Sendable, Equatable {
    var role: String; var text: String; var model: String; var stopReason: String?
    init(role: String = "assistant", text: String, model: String, stopReason: String? = nil)
}
protocol MCPRootsProvider: Sendable { func roots() async -> [MCPRoot] }
struct MCPRoot: Sendable, Equatable, Codable { var uri: String; var name: String?; init(uri: String, name: String? = nil) }

protocol MCPLoggingSink: Sendable { func receive(_ message: MCPLogMessage) }
struct MCPLogMessage: Sendable, Equatable { var level: String; var logger: String?; var data: MCPValue }   // a server's notifications/message
```

### Diagnostics

([MCP diagnostics](mcp-guide.md#diagnostics-when-a-user-reports-an-mcp-problem), [mcp-diagnostics.md](mcp-diagnostics.md))
Off-content (never prompt or response text), secrets redacted.

```swift
enum MCPDiagnostics {
    static var logLevel: MCPLogLevel { get set }     // default .info; governs os.Logger output and the buffer
    static func setEnabled(_ enabled: Bool)          // in-memory ring buffer, default off
    static var isEnabled: Bool { get }
    static var capacity: Int { get set }             // default 500
    static var observer: (@Sendable (MCPDiagnosticEvent) -> Void)? { get set }   // every event, whether or not the buffer is on
    static func exportText() -> String               // for a "Copy diagnostics" action
    static func exportJSON() -> Data
    static func snapshot() -> [MCPDiagnosticEvent]   // captured events, oldest first
    static func clear()
}
enum MCPLogLevel: Int, Sendable, Comparable, Codable { case debug, info, notice, error, off }
struct MCPDiagnosticEvent: Sendable, Codable {
    enum Level: String, Sendable, Codable { case debug, info, notice, error }
    var timestamp: Date; var level: Level
    var area: String                 // connection / manager / oauth / stream
    var message: String
    var fields: [String: String]     // already redacted
    func line() -> String
}
```

### OAuth setup

([the OAuth redirect URI + AppDelegate wiring sections](mcp-guide.md#oauth-redirect-uri--must-set-this-yourself-if-your-server-uses-oauth))
Set these once at startup, before any `addServer` call.

```swift
enum MCPOAuthFlow {
    static var redirectURI: String { get set }       // MUST be your own scheme (default "locallmlab://oauth/callback")
    static var clientName: String { get set }        // the name a sign-in page shows; default: the app's display name
    static var clientMetadataURL: URL? { get set }   // optional — CIMD instead of DCR ([Client ID Metadata Documents](mcp-guide.md#cimd-skipping-dynamic-client-registration))
    // Why a server may refuse uri as a redirect, or nil: a private-use scheme should be your reverse domain
    // ("com.example.app:/oauth/callback"); https and loopback http are fine.
    static func redirectProblem(_ uri: String) -> String?
}

@MainActor final class MCPOAuthRedirectListener {
    static let shared: MCPOAuthRedirectListener
    func handleRedirect(_ url: URL)   // call from your AppDelegate's open-URL handler; a stale redirect is ignored
    func cancelAll()                  // cancel every in-flight wait (the app quits, or the user backs out)
}
```

### Credential presence, without a Keychain prompt

A host that swaps the whole server list in one shot (a configuration-profile load) needs to know which restored
servers will need a fresh sign-in. A server that signs in with auto-discovered OAuth carries `MCPAuthType.none`, so
the only way to tell is whether a token exists, checked without decrypting it (which would raise the Keychain's
consent prompt on a build not yet trusted for the item).

```swift
enum MCPStoredCredentialKind: String, Sendable, Equatable { case oauth, pat }
enum MCPCredentialProbe {
    static func storedKind(for server: URL) -> MCPStoredCredentialKind?   // presence-only query; never decrypts
    static func requiresAuth(declared authType: MCPAuthType, server: URL) -> Bool   // declares up-front auth, or a token is stored
}
```

Pair it with `removeAllKeepingCredentials()` and `restore(from:)`: a server that reappears in the new list
reconnects without a fresh sign-in.

### Advanced: the transport

`MCPConnection` is the transport `MCPServerManager` drives (Streamable HTTP and stdio ship). You need it only to
replace the transport itself. `connect()` returns what the server said about itself.

```swift
protocol MCPConnection: Sendable {
    func connect() async -> Result<MCPServerIdentity, MCPServerError>   // initialize or server/discover
    func listTools() async -> Result<[MCPToolDescriptor], MCPServerError>
    func callTool(name: String, arguments: [String: MCPValue], allowElicitation: Bool) async -> Result<MCPToolResult, MCPServerError>
    func listResources() async -> Result<[MCPResourceDescriptor], MCPServerError>
    func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError>
    func listResourceTemplates() async -> Result<[MCPResourceTemplateDescriptor], MCPServerError>
    func listPrompts() async -> Result<[MCPPromptDescriptor], MCPServerError>
    func getPrompt(name: String, arguments: [String: String]) async -> Result<[MCPPromptMessage], MCPServerError>
    func complete(_ reference: MCPCompletionReference, argument: String, value: String,
                  context: [String: String]) async -> Result<[String], MCPServerError>   // default: no suggestions
    func close()
    var isAlive: Bool { get }                                   // default true; false once a local server's program exited
    func listen(filter: MCPSubscriptionFilter) -> AsyncStream<MCPChangeEvent>   // default: ends at once as .refused
    func refreshAuthorizationSilently() async -> Bool          // refresh the token, never a browser; default false
    var authorizationGeneration: Int { get }                   // grows with each new credential; default 0
}

struct MCPServerIdentity: Sendable, Codable, Equatable {
    var protocolVersion: MCPProtocolVersion
    var serverName: String
    var serverTitle: String              // display name (2025-06-18+); falls back to serverName
    var serverVersion: String?
    var instructions: String?            // free-text usage guidance some servers return
    var capabilities: MCPServerCapabilities
    init(protocolVersion: MCPProtocolVersion, serverName: String, serverTitle: String? = nil, serverVersion: String? = nil,
         instructions: String? = nil, capabilities: MCPServerCapabilities = MCPServerCapabilities())
}
// What the server advertised; absent means "not supported", so a tools-only server never gets a resources/list call.
struct MCPServerCapabilities: Sendable, Codable, Equatable {
    var tools: Bool; var toolsListChanged: Bool
    var resources: Bool; var resourcesListChanged: Bool; var resourcesSubscribe: Bool
    var prompts: Bool; var promptsListChanged: Bool
    var logging: Bool; var completions: Bool
    var hasExperimental: Bool            // the server declared something in `experimental`, kept opaque
    init(tools: Bool = false, toolsListChanged: Bool = false, resources: Bool = false, resourcesListChanged: Bool = false,
         resourcesSubscribe: Bool = false, prompts: Bool = false, promptsListChanged: Bool = false, logging: Bool = false,
         completions: Bool = false, hasExperimental: Bool = false)
    init(from raw: [String: Any])        // parses an initialize result's capabilities object
    var summary: String { get }          // one line, for diagnostics
}
// initialize + session (through 2025-11-25), or 2026-07-28's stateless model. Callers of the manager never see the difference.
enum MCPConnectionMode: Sendable, Equatable {
    case handshake(MCPProtocolVersion)
    case stateless(MCPProtocolVersion)
    var negotiatedVersion: MCPProtocolVersion { get }
    var isStateless: Bool { get }
}

enum MCPChangeEvent: Sendable, Equatable {   // one event of a listen stream
    case acknowledged(MCPSubscriptionFilter) // first: what the server will send (may be narrower than asked)
    case toolsChanged, promptsChanged, resourcesChanged
    case ended(MCPListenEnd)                 // always last
}
enum MCPListenEnd: Sendable, Equatable {
    case closed               // ended cleanly: reconnect
    case failed(String)       // transport or server failure: reconnect with backoff
    case refused(String)      // the server won't send notifications: don't retry on this connection
    case unauthorized         // 401/403: the manager tries a silent refresh, never a browser
}
```

## `MCPTool` (Path A for MCP)

Builds a `Tool` at runtime from an `MCPToolDescriptor`'s real JSON Schema, with no hand-written `Arguments` struct.
Reach for it when you build your own tool list or `LanguageModelSession`; a `LocalLMLab` session already offers
`lab.mcp`'s tools for you. `Arguments` is `GeneratedContent`, and `parameters` is built from the tool's schema. The
initializer throws: skip a tool whose schema doesn't build rather than failing the whole list. See
[Two paths to tool-calling](sdk-guide.md#two-paths-to-tool-calling-ready-made-tools-or-write-your-own) for the loop.

`MCPTool` is an `OriginTaggedTool`: its `toolOrigin` is `.mcp(server:displayName:)`, so passed to
`makeSession(tools:)` it is still gated by that server's trust and approval, not treated as one of the app's own
tools ([Tool authority](#tool-authority-toolcallauthorizer-toolimpact-confirmation)). Its `name` is the server's own
tool name, without the prefix a `LocalLMLab` session adds (`MCPToolNaming`).

```swift
struct MCPTool: Tool, OriginTaggedTool {
    let name: String                   // descriptor.name
    let description: String
    let parameters: GenerationSchema   // built from descriptor.rawSchema, not from Arguments
    var toolOrigin: ToolOrigin { get } // .mcp(server: descriptor.serverID, displayName: …)
    // Arguments == GeneratedContent, Output == String

    // serverDisplayName: the server's name as the user knows it, for records and confirmations. Default: the server's host.
    init(descriptor: MCPToolDescriptor, manager: MCPServerManager, serverDisplayName: String? = nil) throws
    func call(arguments: GeneratedContent) async throws -> String   // manager.callTool, rendered with renderedForModel(maxCharacters: maxModelResultCharacters); a failure returns "Error: …"
}

enum MCPToolAdapterError: Error, CustomStringConvertible {
    case invalidRawSchema           // rawSchema wasn't valid JSON
    case unbuildableSchema(String)  // FoundationModels rejected the resulting GenerationSchema
}

extension FileBackedTool {
    // An MCP data tool whose raw result the model can send to a workspace file with saveAs, so only a short receipt
    // enters its context. For your own LanguageModelSession; with LocalLMLab, use lab.mcp.setFileBackedOutput(_:server:).
    // Tagged with its server (toolOrigin), like MCPTool.
    static func mcp(descriptor: MCPToolDescriptor, manager: MCPServerManager, root: URL, previewCharacters: Int = 600,
                    inlineCharacterLimit: Int? = nil, followUp: String = "read it back a window at a time with readFileRange",
                    saveAsPolicy: SaveAsPolicy = .default, serverDisplayName: String? = nil) throws -> FileBackedTool
}
```

Common JSON Schema shapes (object/properties/required, array/items, string/number/integer/
boolean, string enums) convert cleanly. Anything past that — `oneOf`/`anyOf` unions, `$ref`,
`const`, regex `pattern` — degrades to a free-form string leaf rather than failing the whole tool,
since the remote server is still the real source of argument validation.

## MCP Apps (`LocalLMLabSDKMCPAppsHost`)

Shows a server's interactive views (`ui://` resources, `text/html;profile=mcp-app`) in a sandboxed web view. Open
source and shipped as source, like `Components`, built on Core's public API only; `MCPAppsHost/Sources/` is the
reference for anything below. Walkthrough: [MCP Apps](mcp-guide.md#mcp-apps-showing-a-servers-interactive-views).

The quickest path in a chat is `MCPAppWidgetSlot`: give it a tool-call record with an MCP App link, and it fetches,
caches, revalidates and shows the widget, with its calls going through the session's authorizer. The lower layers
(`MCPAppViewController`, `MCPAppsBridge`, policies, the cache and pool) are there for a host that lays widgets out
itself.

### In a chat: `MCPAppWidgetSlot`

```swift
struct MCPAppWidgetSlot: View {   // the widget for one call (record.app): loading, offline, refresh and snapshot states
    init(record: ToolCallRecord, context: MCPAppWidgetContext, pool: MCPAppViewPool)
    // The widget instance for a call: the record's id for the version first shown with it, else id@<hash prefix>,
    // so the authorizer's remembered answers don't carry over to a widget version the user hasn't seen.
    static func instanceID(record: String, widget sha256: String, bound: String?) -> String
}
@MainActor struct MCPAppWidgetContext {   // what the slot needs from the app
    var session: LocalLMLabSession?      // widget calls go through it, so its authorizer asks the user
    var manager: MCPServerManager
    var cache: MCPAppWidgetCache
    var hostName: String; var hostVersion: String
    var allowMessages: () -> Bool        // may a widget send a message into the chat (ui/message)? asked each time
    var allowModelContext: () -> Bool    // may a widget update the model's context? asked each time
    var sendMessage: (_ text: String, _ instance: String) -> Void   // a widget's message, sent as the next turn
    var reportError: (String) -> Void    // a failure to tell the user ("Refresh failed: …")
    init(session: LocalLMLabSession?, manager: MCPServerManager, cache: MCPAppWidgetCache, hostName: String, hostVersion: String,
         allowMessages: @escaping () -> Bool, allowModelContext: @escaping () -> Bool,
         sendMessage: @escaping (_ text: String, _ instance: String) -> Void, reportError: @escaping (String) -> Void)
}
// The slot's policy: tool calls allowed (the session's authorizer asks; denied when view-only), links over https only,
// messages and model context as allowMessages / allowModelContext say.
struct MCPAppsInlinePolicy: MCPAppsBridgePolicy {
    init(viewOnly: Bool, allowMessages: @escaping () -> Bool, allowModelContext: @escaping () -> Bool)
}
struct MCPAppsOfflineBackend: MCPAppsBackend { init() }   // view-only widget: every call and read fails .notConnected
```

### Declare support, fetch and check a view

```swift
extension MCPClientHandlers {
    func advertisingMCPApps() -> MCPClientHandlers     // pass in MCPSettings(handlers:) — servers check it before offering views
    static let mcpAppsExtensionKey: String             // "io.modelcontextprotocol/ui"
}
struct MCPAppResource: Sendable, Equatable {            // a validated view, size-capped by MCPResponseLimits.maxUIResourceBytes
    static let mimeType: String                         // "text/html;profile=mcp-app"
    let uri: String; let html: String
    let info: MCPAppResourceInfo                        // what it declared in _meta.ui
    let sha256: String                                  // lowercase hex of the HTML — pin / compare versions by this
    // listedMeta: the _meta from resources/list; the read result's own _meta wins.
    init(content: MCPResourceContent, requestedURI: String, listedMeta: MCPValue? = nil) throws   // throws MCPAppResourceError
}
enum MCPAppResourceError: Error, Equatable, CustomStringConvertible {
    case notAUIResource(String), wrongMimeType(String?), noBody, invalidBase64
}
// A server's requests in _meta.ui; the host decides what to grant (intersect, never widen).
struct MCPAppResourceInfo: Sendable, Equatable {
    var csp: MCPAppCSP; var permissions: MCPAppPermissions
    var domain: String?; var prefersBorder: Bool?
    init(csp: MCPAppCSP = MCPAppCSP(), permissions: MCPAppPermissions = MCPAppPermissions(), domain: String? = nil, prefersBorder: Bool? = nil)
    init(meta: MCPValue?)                               // nil or malformed ⇒ the empty, most restrictive declaration
}
struct MCPAppCSP: Sendable, Equatable {                 // origins a view asks for (_meta.ui.csp)
    var connectDomains: [String]; var resourceDomains: [String]; var frameDomains: [String]; var baseUriDomains: [String]
    init(connectDomains: [String] = [], resourceDomains: [String] = [], frameDomains: [String] = [], baseUriDomains: [String] = [])
    var isEmpty: Bool { get }
}
struct MCPAppPermissions: Sendable, Equatable {         // device permissions a view asks for (_meta.ui.permissions)
    var camera: Bool; var microphone: Bool; var geolocation: Bool; var clipboardWrite: Bool
    init(camera: Bool = false, microphone: Bool = false, geolocation: Bool = false, clipboardWrite: Bool = false)
    var isEmpty: Bool { get }
}

// Views on disk by hash — shown again after scrolling back, a relaunch, or offline — and which version each call used.
@MainActor final class MCPAppWidgetCache {
    init(directory: URL? = nil, maxBytes: Int = 64 * 1024 * 1024)   // default: Caches/LocalLMLab/MCPAppWidgets; LRU past maxBytes
    let directory: URL
    var maxBytes: Int
    func fetch(resourceURI: String, server: MCPServerID, manager: MCPServerManager, recordID: String? = nil) async throws -> MCPAppResource
    func store(_ content: MCPResourceContent, requestedURI: String) throws -> MCPAppResource
    func resource(sha256: String) -> MCPAppResource?             // nil if missing or tampered
    func bind(recordID: String, sha256: String)                  // call recordID was rendered with this version
    func sha256(forRecord recordID: String) -> String?
    var storedBytes: Int { get }; var storedVersions: Set<String> { get }
}
```

### Render: `MCPAppViewController`

The controller owns one widget's `WKWebView` (non-persistent data store) and the bridge behind it. Containment,
outermost first: the effective CSP served as a header; a content-rule list blocking every load outside the effective
origins; a sandboxed iframe with an opaque origin; navigation pinned to the view's own documents, with new windows,
file pickers and media capture refused; and only main-frame messages accepted, each through the bridge's policy.

```swift
@MainActor final class MCPAppViewController: NSObject, ObservableObject {
    // Pin / verify resource.sha256 BEFORE creating the controller: it renders whatever it is given.
    init(resource: MCPAppResource, tools: [MCPToolDescriptor], backend: any MCPAppsBackend,
         configuration: MCPAppsBridgeConfiguration,
         bridgePolicy: any MCPAppsBridgePolicy = MCPAppsDefaultPolicy(),   // tool calls allowed; messages, context, links denied
         sandboxPolicy: MCPAppsSandboxPolicy = .closed,                   // no network unless allowed
         actions: MCPAppsHostActions = MCPAppsHostActions(),
         supportedDisplayModes: [String] = ["inline"],                     // list "fullscreen" only if your UI follows displayMode
         audit: @escaping @MainActor (MCPAppsAuditEvent) -> Void = { _ in })
    enum LoadState: Equatable { case idle, loading, loaded; case failed(String) }
    let webView: WKWebView
    private(set) var bridge: MCPAppsBridge!   // deliver tool-input / tool-result through it; queued until the view is ready
    let effectiveCSP: MCPAppCSP               // what is actually enforced
    let resource: MCPAppResource
    let supportedDisplayModes: [String]
    @Published private(set) var loadState: LoadState
    @Published private(set) var contentHeight: CGFloat?   // the view's reported height
    @Published private(set) var displayMode: String        // "inline" or "fullscreen"
    func load() async                         // compiles the block list, starts loading; loadState reports completion
    func exitFullscreen()                     // the host's Esc / close button; tells the view
    func close() async                        // then release the controller: its process ends only when the web view is freed
}
struct MCPAppView: NSViewRepresentable { init(controller: MCPAppViewController) }   // you keep the controller; load() once, close() when done

// What the HOST allows a view to reach; the effective CSP is the declaration intersected with this.
struct MCPAppsSandboxPolicy: Sendable, Equatable {
    var allowedConnectOrigins: [String]   // fetch / WebSocket: exact https://host[:port] / wss://…, or https://*.example.com
    var allowedResourceOrigins: [String]  // scripts, styles, images, fonts, media
    var allowedFrameOrigins: [String]
    var allowsSameOrigin: Bool            // adds allow-same-origin (storage, cookies) — only for a trusted view
    var isInspectable: Bool               // Safari's Develop menu; debug builds only
    init(allowedConnectOrigins: [String] = [], allowedResourceOrigins: [String] = [], allowedFrameOrigins: [String] = [],
         allowsSameOrigin: Bool = false, isInspectable: Bool = false)
    static let closed: MCPAppsSandboxPolicy   // no network, no frames, no storage
}
enum MCPAppsSandbox {                     // the pure functions behind the sandbox
    static func isSafeOrigin(_ origin: String) -> Bool   // https:// or wss:// + DNS host (optionally *.) + optional port, nothing else
    static func effectiveCSP(declared: MCPAppCSP, policy: MCPAppsSandboxPolicy) -> MCPAppCSP   // baseUriDomains never granted
    static func headerValue(for csp: MCPAppCSP) -> String           // the Content-Security-Policy header
    static func contentRuleListJSON(for csp: MCPAppCSP) -> String   // WKContentRuleList blocking loads outside csp
}
```

### The bridge and its policy

`MCPAppsBridge` is the JSON-RPC state machine between one view and the host, with no WebKit (the controller makes one
for you). Nothing reaches the view before it reports `ui/notifications/initialized`; a view may call only tools the
bound server declared with `app` in their visibility, that the policy allows; malformed, oversized or unknown input is
dropped or answered with an error; every message leaves an audit event without argument values or output.

```swift
@MainActor final class MCPAppsBridge {
    static let protocolVersion: String   // "2026-01-26", the MCP Apps revision it speaks
    enum State: Sendable, Equatable { case awaitingInitialize, awaitingInitialized, ready, tornDown }
    private(set) var state: State
    private(set) var displayMode: String
    // tools: the bound server's tools (MCPServerState.tools); send: delivers one serialized message to the view.
    init(configuration: MCPAppsBridgeConfiguration, tools: [MCPToolDescriptor], backend: any MCPAppsBackend,
         policy: any MCPAppsBridgePolicy = MCPAppsDefaultPolicy(), send: @escaping @MainActor (Data) -> Void,
         audit: @escaping @MainActor (MCPAppsAuditEvent) -> Void = { _ in },
         onSizeChanged: @escaping @MainActor (_ width: Double?, _ height: Double?) -> Void = { _, _ in },
         actions: MCPAppsHostActions = MCPAppsHostActions())
    func deliverToolInput(arguments: [String: MCPValue])     // ui/notifications/tool-input
    func deliverToolResult(_ result: MCPToolResult)          // ui/notifications/tool-result (structuredContent and _meta)
    func deliverToolCancelled(reason: String? = nil)
    func deliverHostContextChange(_ partial: [String: MCPValue])   // only the fields that changed
    func setDisplayMode(_ mode: String)                      // the host changed it; ignored for a mode not advertised
    func teardown(reason: String = "host closing") async     // ui/resource-teardown, waits up to teardownTimeout, then closes
    func receive(_ data: Data) async                         // one raw message from the view
}
struct MCPAppsBridgeConfiguration: Sendable {   // reported to the view at ui/initialize
    var hostName: String; var hostVersion: String
    var hostContext: [String: MCPValue]         // theme, locale, …; displayMode, availableDisplayModes, platform get defaults
    var effectiveCSP: MCPAppCSP; var effectivePermissions: MCPAppPermissions   // what the host enforces
    var availableDisplayModes: [String]         // "inline" always included
    var maxMessageBytes: Int                    // larger incoming messages are dropped, unparsed
    var teardownTimeout: Duration
    var maxToolCallsPerMinute: Int; var maxConcurrentToolCalls: Int   // past these a call is refused, not queued
    init(hostName: String, hostVersion: String, hostContext: [String: MCPValue] = [:], effectiveCSP: MCPAppCSP = MCPAppCSP(),
         effectivePermissions: MCPAppPermissions = MCPAppPermissions(), availableDisplayModes: [String] = ["inline"],
         maxMessageBytes: Int = 4 * 1024 * 1024, teardownTimeout: Duration = .seconds(2),
         maxToolCallsPerMinute: Int = 60, maxConcurrentToolCalls: Int = 4)
}
struct MCPAppsAuditEvent: Sendable, Equatable {   // method names, tool names and outcomes only — safe to persist
    enum Direction: String, Sendable { case fromView, toView }
    enum Outcome: String, Sendable { case ok, denied, error, dropped }
    let direction: Direction; let method: String; let outcome: Outcome
    let detail: String?                           // a short, non-sensitive note
    init(direction: Direction, method: String, outcome: Outcome, detail: String? = nil)
}

// What a view may do, after the protocol's own checks. Defaults: tool calls and ui:// reads allowed;
// other reads, ui/open-link, ui/message and ui/update-model-context denied.
@MainActor protocol MCPAppsBridgePolicy {
    func authorizeToolCall(name: String, arguments: [String: MCPValue]) async -> MCPAppsDecision
    func authorizeResourceRead(uri: String) async -> MCPAppsDecision
    func authorizeOpenLink(_ url: URL) async -> MCPAppsDecision
    func authorizeMessage(text: String) async -> MCPAppsDecision
    func authorizeModelContextUpdate() async -> MCPAppsDecision
}
enum MCPAppsDecision: Sendable, Equatable { case allow; case deny(String) }
@MainActor struct MCPAppsDefaultPolicy: MCPAppsBridgePolicy {   // the protocol defaults, with an optional tool allowlist
    var allowedTools: Set<String>?   // nil = every app-visible tool of the bound server
    init(allowedTools: Set<String>? = nil)
}
// What the host DOES once the policy allowed a request. All no-ops by default.
struct MCPAppsHostActions {
    var openLink: @MainActor (URL) -> Void
    var sendMessage: @MainActor (String) -> Void   // ui/message
    var updateModelContext: @MainActor (_ content: [MCPValue], _ structuredContent: MCPValue?) -> Void
    var requestDisplayMode: @MainActor (_ mode: String) -> Bool   // true if the host UI switched
    init(openLink: @escaping @MainActor (URL) -> Void = { _ in }, sendMessage: @escaping @MainActor (String) -> Void = { _ in },
         updateModelContext: @escaping @MainActor (_ content: [MCPValue], _ structuredContent: MCPValue?) -> Void = { _, _ in },
         requestDisplayMode: @escaping @MainActor (_ mode: String) -> Bool = { _ in false })
}
extension MCPAppsHostActions {   // ui/message ⇒ a session turn; ui/update-model-context ⇒ model context (when the policy allows)
    static func session(_ session: LocalLMLabSession, instance: String, openLink: @escaping @MainActor (URL) -> Void = { _ in },
                        onReply: @escaping @MainActor (Result<String, any Error>) -> Void = { _ in },
                        requestDisplayMode: @escaping @MainActor (_ mode: String) -> Bool = { _ in false }) -> MCPAppsHostActions
}
```

### Where a view's calls go: backends

A backend is bound to one server, so a view can never reach another server's tools.

```swift
protocol MCPAppsBackend {
    func callTool(name: String, arguments: [String: MCPValue]) async -> Result<MCPToolResult, MCPServerError>
    func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError>
}
// tools/call ⇒ session.callMCPTool(…, initiator: .app(instance:)): the session's authorizer decides. Reads go to the server.
@MainActor struct MCPAppsSessionBackend: MCPAppsBackend {
    let session: LocalLMLabSession; let manager: MCPServerManager; let server: MCPServerID
    let instance: String   // the widget in records and the authorizer; usually the tool-call record's id
    init(session: LocalLMLabSession, manager: MCPServerManager, server: MCPServerID, instance: String)
}
@MainActor struct MCPServerManagerBackend: MCPAppsBackend {   // straight to the manager — no session, no authorizer
    init(manager: MCPServerManager, server: MCPServerID)
}
```

### Many views in one conversation, and re-creating them

Each live view is its own WebContent process (about 100 MB). The pool keeps at most `limit` live and snapshots the
rest. `MCPAppRecreation` decides what to show for a stored call when it is shown again.

```swift
@MainActor final class MCPAppViewPool: ObservableObject {
    init(limit: Int = 3)
    var limit: Int                                   // lowering it releases views right away
    @Published private(set) var liveKeys: [String]
    func controller(for key: String, make: () throws -> MCPAppViewController) rethrows -> MCPAppViewController   // make only if not live
    func touch(_ key: String)                        // most recently used (scrolled into view)
    func isLive(_ key: String) -> Bool
    func snapshot(for key: String) -> NSImage?       // a released view's picture; nil while live
    func release(_ key: String) async; func releaseAll() async
    func discardSnapshot(for key: String)
}

enum MCPAppRecreation {
    struct Revalidation: Sendable {
        var decision: MCPAppRecreationDecision
        var resource: MCPAppResource?    // the version to show for .render
        var widgetChanged: Bool          // the server serves a different version than the call used
    }
    // Same version ⇒ current; newer with an unchanged output schema ⇒ current; newer or unknown with a changed schema
    // ⇒ refresh; server unreachable ⇒ cached, view-only (or .unavailable); a pin that excludes it ⇒ .notApproved.
    static func decide(cachedSHA256: String?, currentSHA256: String?, outputSchemaUnchanged: Bool, toolIsReadOnly: Bool,
                       approvedSHA256: Set<String>? = nil) -> MCPAppRecreationDecision
    @MainActor static func cachedResource(recordID: String, cache: MCPAppWidgetCache) -> MCPAppResource?   // show at once, before revalidating
    @MainActor static func revalidate(recordID: String, resourceURI: String, callDescriptor: MCPToolDescriptor?,
                                      source: any MCPAppWidgetSource, cache: MCPAppWidgetCache,
                                      approvedSHA256: Set<String>? = nil) async -> Revalidation
    @MainActor static func revalidate(_ record: ToolCallRecord, source: any MCPAppWidgetSource, cache: MCPAppWidgetCache,
                                      approvedSHA256: Set<String>? = nil) async -> Revalidation?   // nil: no app link or no stored result
    // The stored arguments and result, as the view got them the first time — no call to the server.
    @MainActor static func deliver(arguments: GeneratedContent?, result: MCPToolResult, to controller: MCPAppViewController)
    @MainActor static func deliver(_ record: ToolCallRecord, to controller: MCPAppViewController) -> Bool   // false: no stored result
    static func toolInput(from arguments: GeneratedContent?) -> [String: MCPValue]
}
enum MCPAppRecreationDecision: Sendable, Equatable {
    case render(viewOnly: Bool)                         // viewOnly: server unreachable, its calls would fail
    case needsRefresh(mayRefreshAutomatically: Bool)    // output changed shape; true when the tool is read-only
    case notApproved                                    // a hash pin doesn't approve this version
    case unavailable                                    // nothing cached and the server unreachable
}
@MainActor protocol MCPAppWidgetSource {               // where re-creation reads the current view and tool
    func currentResource(uri: String) async -> Result<MCPResourceContent, MCPServerError>
    func currentDescriptor(tool: String) -> MCPToolDescriptor?
}
@MainActor struct MCPServerManagerWidgetSource: MCPAppWidgetSource { init(manager: MCPServerManager, server: MCPServerID) }   // .notConnected unless connected
```

### A form for a tool's inputs: `MCPToolInputForm`

Turns a tool's `inputSchema` into form fields and the user's text back into arguments, for launching an app tool by
hand. Pure logic, no UI; the server still validates.

```swift
struct MCPToolInputForm: Sendable, Equatable {
    init(schema: Data)
    let fields: [MCPToolInputField]
    var isEmpty: Bool { get }             // the tool takes no inputs
    var hasRequiredFields: Bool { get }
    // values: field name ⇒ text (booleans "true"/"false"). Blank optional fields omitted; a blank required field or
    // text that doesn't fit the type is an error.
    func arguments(from values: [String: String]) -> Result<[String: MCPValue], MCPToolInputError>
}
struct MCPToolInputField: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case string, integer, number, boolean
        case choice([String])             // a string restricted to these values
        case list(element: ListElement)   // simple values, entered comma-separated
        case json                         // anything else (objects, unions, nested arrays): raw JSON text
    }
    enum ListElement: Sendable, Equatable { case string, integer, number }
    let name: String; let summary: String; let isRequired: Bool; let kind: Kind
    let defaultText: String?              // the schema default, for prefilling
}
enum MCPToolInputError: Error, Equatable, CustomStringConvertible {
    case missingRequired(String)
    case invalid(field: String, reason: String)
}
```

## Components (`LocalLMLabSDKComponents`)

Prebuilt SwiftUI on top of Core's public API, all optional. It ships as source, so
`Components/Sources/LocalLMLabSDKComponents/` is the last word on these signatures. Walkthrough:
[Components](sdk-guide.md#components-prebuilt-swiftui-mcp-servers--the-model-layer). The chat views are new in 3.0. They
draw a Core `ChatController` ([Chat core](#chat-core-chatcontroller-chatsetup-conversations)), and an app fills slots
for what it does differently.

### MCP servers, resources and prompts

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
    enum ToolsMode: Sendable {
        case `static`   // a tool is offered when it's ticked and its server is connected
        case dynamic    // makeSession(dynamicTools:): the checkboxes mark a tool available or not (all by default); held tools marked
    }
    // allowsLocalPrograms: offer "Local program" (MCP over stdio) beside "Web address"; always off where
    // ExternalPrograms.isSupported is false (a sandboxed build). detail: .plain hides tool names, prefixes,
    // token counts and export.
    init(manager: MCPServerManagerObservable, toolsMode: ToolsMode = .static,
         allowsLocalPrograms: Bool = ExternalPrograms.isSupported, detail: ChatToolDetail = .detailed)
    // Add (a URL, or a pasted JSON setup that fills the form) / list / reconnect / disconnect / remove, all
    // three auth types, per-tool and per-resource enable/disable, prompts listing (read-only), a "Save As…"
    // text export per server, trust + approval controls (setTrust / setToolApproval), and Accept for a
    // server whose tools changed (pendingDrift).
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

// Server elicitation (a form a server asks the user to fill), the single-process SwiftUI MCPElicitationHandler.
// Hand it to MCPClientHandlers(elicitation:); with no handler, Core never advertises elicitation.
@MainActor
final class MCPElicitationPresenter: ObservableObject, MCPElicitationHandler {
    @Published private(set) var pending: [MCPElicitationPrompt]   // oldest first; the sheet shows `first`
    init(fallbackTimeout: Duration = .seconds(120))   // an unanswered prompt auto-cancels after this
    func handleElicitation(_ request: MCPElicitationRequest) async -> MCPElicitationResponse
    func resolve(_ id: MCPElicitationPrompt.ID, _ response: MCPElicitationResponse)   // no-op for an unknown id
}
struct MCPElicitationPrompt: Identifiable, Sendable { let id: UUID; let request: MCPElicitationRequest }
extension View {
    func mcpElicitationSheet(_ presenter: MCPElicitationPresenter) -> some View   // attach once, near the root; dismissing cancels
}
```

### Tool confirmation

The reference `ToolConfirmationChannel` for a single-process SwiftUI app: `ConfirmingToolAuthorizer(channel:)` routes
each call that must ask to this presenter, and the sheet shows one at a time
([Tool authorization](sdk-guide.md#tool-authorization-two-levers--which-tools-and-whether-they-ask-first)).

```swift
@MainActor
final class ToolConfirmationPresenter: ObservableObject, ToolConfirmationChannel {
    @Published private(set) var pending: [ToolConfirmationRequest]   // oldest first; the sheet shows `first`
    var extras: (@MainActor (PendingToolCall) -> ToolConfirmationExtras)?   // per call; nil: the plain Allow / Deny sheet
    init(fallbackTimeout: Duration = .seconds(120))   // an unanswered sheet auto-denies (ConfirmingToolAuthorizer has its own timeout too)
    nonisolated func requestDecision(for call: PendingToolCall) async -> Bool
    func resolve(_ id: ToolConfirmationRequest.ID, allow: Bool)   // the sheet's buttons, or your own UI; no-op for an unknown id
    // The standard extras for an MCP call: why it asks, "Always allow this tool", and for an untrusted
    // server "Trust this server…" with what that unlocks. appName goes in the note.
    func useStandardMCPExtras(manager: MCPServerManager, appName: String)
}
struct ToolConfirmationRequest: Identifiable, Sendable { let id: UUID; let call: PendingToolCall }
struct ToolConfirmationExtras {   // each action runs, then the call is allowed
    var note: String?                          // why it's asking
    var alwaysAllow: (@MainActor () -> Void)?  // "Always allow this tool", e.g. a per-tool .allow approval
    var trustSummary: String?                  // what trusting the source would unlock
    var trust: (@MainActor () -> Void)?        // "Trust this server…", then "Trust and allow"
    init(note: String? = nil, alwaysAllow: (@MainActor () -> Void)? = nil,
         trustSummary: String? = nil, trust: (@MainActor () -> Void)? = nil)
}
extension View {
    func toolConfirmationSheet(_ presenter: ToolConfirmationPresenter) -> some View   // attach once, near the root; dismissing denies
}
```

### Chat views

A chat window is `ChatSidebar` beside a `ChatTranscriptView` and a `ChatComposer`, all over one `ChatController`. Each
view takes the controller and calls its actions. What an app adds goes in a `@ViewBuilder` slot.

```swift
struct ChatTranscriptView<Empty: View, ReplyExtras: View, Widget: View, CustomCard: View>: View {
    // Replies (Markdown), reasoning, tool calls with source and impact, the inline cards, files the tools wrote,
    // compaction dividers, Copy / Retry / Edit under the last reply, the "why these tools" chip (.detailed), and
    // links from content confirmed before they open.
    init(controller: ChatController, developer: Bool = false,   // developer: the chip's developer details
         toolDetail: ChatToolDetail = .plain,
         addWorkspace: @escaping (ChatCard, _ path: String, Workspace.Access) -> Void,   // folder picker at path, save, then controller.complete(card, notice:)
         @ViewBuilder empty: @escaping () -> Empty,                                // no messages yet (ChatStarterView)
         @ViewBuilder replyExtras: @escaping (ChatReplyContext) -> ReplyExtras,    // the app's controls after Copy, Retry, Edit and the chip
         @ViewBuilder widget: @escaping (ToolCallRecord) -> Widget,                // inline view for a finished call that has one (MCPAppWidgetSlot)
         @ViewBuilder customCard: @escaping (ChatCard) -> CustomCard)              // the app's .custom cards
}
enum ChatToolDetail: Sendable {
    case plain      // one line per step in everyday words ("Read contract.pdf"), repeated steps merged
    case detailed   // each call's tool, source, rating, arguments and result, plus the tools chip
}
struct ChatReplyContext {   // what the reply-extras slot gets for one turn
    let turn: Int
    let isLast: Bool
    let text: String        // the reply as Copy copies it: assistant text, no reasoning or tool calls
    let info: TurnInfo?     // why the turn got its tools, when recorded
    static func replyText(turn: Int, in entries: [HostTranscript.Entry]) -> String
}
struct ChatStarterView: View {   // an empty chat: icon, heading, what the app can do, messages to try
    init(systemImage: String? = "bubble.left.and.text.bubble.right", title: String = "What can I help with?",
         message: String, suggestions: [String], send: @escaping (String) -> Void)
}

struct ChatComposer<Banner: View, Leading: View, ModelLabel: View>: View {
    // The message box: text, attachments (picked, dropped, pasted, imported from an iPhone), editing the last
    // message, Send and Stop. A long paste becomes an attachment.
    static var standardTypes: [UTType] { get }   // text, PDF, CSV, TSV, JSON, Markdown, HTML, RTF, Word (.docx), images
    init(controller: ChatController, isEnabled: Bool = true,   // isEnabled: sending allowed now, besides a turn running
         acceptedTypes: [UTType] = Self.standardTypes,
         send: ((String, [URL]) -> Void)? = nil,               // the app's send (it may start a chat first); controller.send by default
         addSource: (() -> Void)? = nil,                       // no longer used; kept so existing callers build
         @ViewBuilder banner: @escaping () -> Banner,          // above the box
         @ViewBuilder leading: @escaping () -> Leading,        // under the box, on the left
         @ViewBuilder modelLabel: @escaping () -> ModelLabel)  // under the box, on the right (ChatModelLabel)
}
extension ChatComposer where Banner == EmptyView, Leading == EmptyView {
    init(controller: ChatController, isEnabled: Bool = true, acceptedTypes: [UTType] = Self.standardTypes,
         send: ((String, [URL]) -> Void)? = nil, addSource: (() -> Void)? = nil,
         @ViewBuilder modelLabel: @escaping () -> ModelLabel)
}
extension View {
    func chatComposerPlaceholder(_ text: String?) -> some View   // why sending is off ("You can send again at about 3:40 PM"); nil: "Message"
}
struct ChatModelLabel: View {   // the model that answers: its name and a detail such as its quantization
    init(_ name: String, detail: String? = nil, help: String? = nil)
}
struct ChatAttachmentThumbnail: View {   // an attached image, decoded off the main thread at the size shown; fixed height
    init(url: URL, height: CGFloat)
    static func isImage(_ name: String) -> Bool
}
enum ChatPastedAttachments {   // files and images from the clipboard or a drop, as attachments
    static func fromPasteboard(_ pasteboard: NSPasteboard, images: Bool = true) -> [URL]   // file URLs, else (images) a PNG of a copied image
    static func longInsertion(from old: String, to new: String, limit: Int) -> (inserted: String, remaining: String)?   // a paste longer than limit
    static func saveText(_ text: String) -> URL?           // "Pasted text.txt" in a temporary folder; the chat copies it from there
    static func savePNG(_ data: Data) -> URL?              // "Pasted image <time>.png"
    static func savePDF(_ data: Data) -> URL?              // "Scanned document <time>.pdf" (scanned on an iPhone)
    static func saveImported(_ data: Data, filename: String) -> URL?   // File › Import from iPhone: a PDF, or a photo in its own format; nil otherwise
}

struct ChatSidebar<Footer: View>: View {   // the chat list: search, rename, delete
    init(store: ConversationStore, selection: UUID?, open: @escaping (UUID) -> Void, delete: @escaping (UUID) -> Void,
         conversations: ((String) -> [ConversationMeta])? = nil,   // the chats for a search; store.search by default
         responding: Bool = false,      // the open chat is replying: a click still goes to `open`, but its row isn't left highlighted
         notice: String? = nil,         // a line under the list ("Wait for this reply…")
         @ViewBuilder footer: @escaping () -> Footer)
}
extension ChatSidebar where Footer == EmptyView {
    init(store: ConversationStore, selection: UUID?, open: @escaping (UUID) -> Void, delete: @escaping (UUID) -> Void,
         conversations: ((String) -> [ConversationMeta])? = nil, responding: Bool = false, notice: String? = nil)
}
struct ChatEmptyStateView: View {   // no chat open: the app's name, what it does, and New Chat
    init(title: String, message: String, newChat: @escaping () -> Void)
}

struct ToolChoiceChip: View {   // "why these tools" under a reply; tapped, the whole TurnInfo
    init(info: TurnInfo, developer: Bool = false)   // developer: timings, tokens restored from the cache, tool block size
    static func seconds(_ milliseconds: Double) -> String   // "850 ms", "4.2 s"
}
```

The widget slot takes `MCPAppWidgetSlot` from `LocalLMLabSDKMCPAppsHost`, which Components doesn't link
([MCP Apps](#mcp-apps-locallmlabsdkmcpappshost)). The composer also offers MCP prompts (a `/` menu) and content the user's
servers share (the paperclip menu). Those pickers are internal to it.

### Chat cards

`ChatCardView` draws any `ChatCard` and wires its buttons to the controller. `ChatTranscriptView` uses it for you. The
single card views take what they show and what their buttons do, for an app that lays out cards itself. Their text is
fixed: nothing the model wrote appears in them.

```swift
struct ChatCardView<Custom: View>: View {
    init(card: ChatCard, controller: ChatController,
         addWorkspace: @escaping (ChatCard, _ path: String, Workspace.Access) -> Void,   // folder picker, then controller.complete(card, notice:)
         @ViewBuilder custom: @escaping (ChatCard) -> Custom)                            // .custom cards
}
struct ChatCardFrame<Content: View>: View {   // the rounded panel every card sits in; dimmed and disabled once resolved
    init(resolved: Bool = false, @ViewBuilder content: () -> Content)
}
func readableToolName(_ toolName: String) -> String   // "list_issues" / "getFileContents" → "list issues" / "get file contents"

struct ClarifyCardView: View {        // .clarify: which of these tools was meant
    init(options: [SelectableTool], sourceName: @escaping (SelectableTool) -> String, choose: @escaping (SelectableTool) -> Void)
}
struct SignInCardView: View {         // .signIn; domain: whose sign-in page it is (the server's own)
    init(name: String, domain: String, signIn: @escaping () -> Void, dismiss: @escaping () -> Void)
}
struct PermissionCardView: View {     // .permission. granted: nil while waiting, then whether macOS granted it;
                                      // problem: why Allow didn't work, with Try Again (allow) and openSettings
    init(name: String, missing: Set<PluginPermission>, granted: Bool? = nil, problem: PermissionProblem? = nil,
         allow: @escaping () -> Void, openSettings: (() -> Void)? = nil, dismiss: @escaping () -> Void)
}
struct ToolChangesCardView: View {    // .review: a server's tools changed since the user accepted them
    init(name: String, drift: ToolDrift, review: @escaping (_ accept: Bool) -> Void)
}
struct AddToolSourceCardView: View {  // .addSource: URL, name, sign-in type; a token goes only to `add` (then the Keychain)
    init(url: String = "", name: String = "", add: @escaping (NewToolSource) async -> Void,
         invalidURL: @escaping () -> Void, cancel: @escaping () -> Void,
         sendAsMessage: (() -> Void)? = nil)   // for a card made from a message: send it to the model instead
}
struct NewToolSource: Sendable {      // what the user entered; token set only for .pat
    var url: URL; var name: String; var authType: MCPAuthType; var token: String?; var trusted: Bool
}
struct AddWorkspaceCardView: View {   // .addWorkspace: "Use ~/Code/project as a workspace?" with its access level
    init(path: String, add: @escaping (Workspace.Access) -> Void, dismiss: @escaping () -> Void,
         sendAsMessage: (() -> Void)? = nil)
}
struct PastedKeyCardView: View {      // .pastedKey: the key was kept from the model and the transcript
    init(sendWithoutIt: @escaping () -> Void, addToolSource: @escaping () -> Void, cancel: @escaping () -> Void)
}
struct ServerSuggestionView: View {   // .suggestServer: "GitHub could help with this"; checking: the follow-up is running
    init(name: String, checking: Bool, check: @escaping () -> Void, dismiss: @escaping () -> Void)
}
struct EmptyReplyCardView: View {     // .emptyReply: its note; retry nil hides Retry
    init(_ text: String, retry: (() -> Void)?, dismiss: @escaping () -> Void)
}
struct ChatNoticeView: View {         // .notice: something done ("Brevo added: 12 tools")
    init(_ text: String, dismiss: @escaping () -> Void)
}
struct ChatWarningView: View {        // .warning: something went wrong in a turn, said inline
    init(_ text: String, dismiss: @escaping () -> Void)
}
struct FileCardView: View {           // a file a tool wrote: Open, Save As…, and a CSV's first rows (read from the file)
    init(url: URL)
}
```

### Markdown

`MarkdownView` draws a chat reply block by block. It suits a reply that is still streaming, because each update
parses the text again.

```swift
struct MarkdownView: View {
    init(text: String, limit: Int? = nil)   // limit: past this many characters, show the start until the user asks; nil: all
}
enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(items: [String])
    case numbered(start: Int, items: [String])
    case quote(String)
    case code(language: String, text: String)
    case table(header: [String], rows: [[String]])
    case rule
}
enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock]   // never fails: anything unrecognised is a paragraph
    static func inline(_ text: String, style: MarkdownStyle = .standard) -> AttributedString   // bold, italic, code, links
}
struct MarkdownCodeBlock: View { init(language: String, text: String) }   // fenced code with its language and Copy
struct MarkdownTableBlock: View { init(header: [String], rows: [[String]]) }   // bold header row, cells' inline Markdown rendered
struct MarkdownStyle: Sendable {
    var body: Font
    var text: Color                     // set on the text, so buttons among it keep their tint
    var lineSpacing: CGFloat            // extra space between wrapped lines
    var listSpacing: CGFloat            // between list items
    var inlineCode: Font
    var inlineCodeBackground: Color
    var code: Font
    var table: Font
    var headingSizes: (CGFloat, CGFloat, CGFloat)   // levels 1, 2, and 3 and below; headings are semibold
    init(body: Font, text: Color, lineSpacing: CGFloat, listSpacing: CGFloat, inlineCode: Font,
         inlineCodeBackground: Color, code: Font, table: Font, headingSizes: (CGFloat, CGFloat, CGFloat))
    func heading(_ level: Int) -> Font
    static let standard: MarkdownStyle  // 16 pt light body, near-black / near-white text, about 1.6 line height
}
extension EnvironmentValues { var markdownStyle: MarkdownStyle }
extension View { func markdownStyle(_ style: MarkdownStyle) -> some View }   // the style MarkdownViews below use
```

### Workspace settings

```swift
struct WorkspaceAccessPicker: View {   // the three access levels, worded as the user reads them (Settings row and add-workspace card)
    init(access: Binding<Workspace.Access>)
    static func title(_ access: Workspace.Access) -> String
}
struct WorkspaceSettingsRow: View {    // name, folder, Default folder, access level, description, Show in Finder, Remove
    init(workspace: SavedWorkspace, isDefault: Bool, isAvailable: Bool, actions: WorkspaceSettingsActions)
    // Default and access apply when changed; an edited name or description shows Apply and Revert.
}
struct WorkspaceSettingsActions {      // what the row asks the host to do; the host keeps its SavedWorkspaces and refreshes tools
    var rename: (String) -> String?    // returns why the name can't be used, or nil when renamed
    var setDescription: (String) -> Void
    var setAccess: (Workspace.Access) -> Void
    var setDefault: (Bool) -> Void
    var showInFinder: () -> Void
    var remove: () -> Void
    init(rename: @escaping (String) -> String?, setDescription: @escaping (String) -> Void,
         setAccess: @escaping (Workspace.Access) -> Void, setDefault: @escaping (Bool) -> Void,
         showInFinder: @escaping () -> Void, remove: @escaping () -> Void)
}
```

### The model layer

```swift
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

// Model onboarding, updates and cleanup — Components/README.md has the adapter for MLXModelProvider.
struct ModelOnboardingRequest: Sendable, Equatable, Identifiable {
    var role: String; var repoID: String; var expectedRevision: String?; var validates: Bool
    init(role: String = "Model", repoID: String, expectedRevision: String? = nil, validates: Bool = true)
}
struct ModelOnboardingSource: Sendable {
    var validate: @Sendable (String) async throws -> PreflightResult?
    var download: @Sendable (String, @escaping @Sendable (DownloadProgress) -> Void) async throws -> InstalledModel
    var cancel: @Sendable (String) -> Void
    init(validate: @escaping @Sendable (String) async throws -> PreflightResult?,
         download: @escaping @Sendable (String, @escaping @Sendable (DownloadProgress) -> Void) async throws -> InstalledModel,
         cancel: @escaping @Sendable (String) -> Void = { _ in })
    init(provider: any DownloadableModelProvider)
    init(registry: ModelRegistry)
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
    private(set) var items: [ModelOnboardingItem]; private(set) var isRunning: Bool
    private(set) var completed: [InstalledModel]   // completed all three steps, in request order
    var isFinished: Bool { get }; var hasFailed: Bool { get }; var hasStarted: Bool { get }
}
struct ModelOnboardingView: View {
    init(model: ModelOnboardingModel, showsDownloadProgress: Bool = true,
         showsCancel: Bool = true,   // false: the host offers its own way to stop (model.cancel())
         onFinished: (([InstalledModel]) -> Void)? = nil, onDismiss: (() -> Void)? = nil)
}
struct ModelFileChange: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable { case added, removed, modified }
    var id: String { path }
    var path: String; var kind: Kind; var oldSize: Int64?; var newSize: Int64?
    init(path: String, kind: Kind, oldSize: Int64? = nil, newSize: Int64? = nil)
}
struct ModelUpdateOffer: Sendable, Equatable {
    var current: String       // the version the model is on now
    var available: String     // the version on offer
    var changes: [ModelFileChange]
    var isUpToDate: Bool { current == available }
    var summary: String { get }   // "3 files changed, 291 MB"
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
    enum State: Equatable {
        case idle, checking, upToDate, available(ModelUpdateOffer)
        case updating(Double)   // downloading the new version; the current one keeps working
        case switching          // pauseInference is running and the switch is next: refuse new requests
        case failed(String)
    }
    init(actions: ModelUpdateActions, ownership: ModelUpdateOwnership, currentRevision: String? = nil,
         pauseInference: (@Sendable () async throws -> Void)? = nil)   // awaited before the switch; throwing cancels the update
    private(set) var state: State
    private(set) var currentRevision: String?
    private(set) var rollbackRevision: String?   // what Roll back returns to
    var shippedRevision: String?                 // a built-in model's shipped version, offered as Back to the shipped version
    var ownership: ModelUpdateOwnership
    var pauseInference: (@Sendable () async throws -> Void)?
    var isBusy: Bool { get }; var isSwitching: Bool { get }; var canUpdate: Bool { get }
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
    private(set) var versions: [ModelVersionRow]; private(set) var isLoading: Bool
    private(set) var message: String?   // the last outcome ("Freed 1.6 KB", or why a removal failed)
    func refresh() async; func remove(_ row: ModelVersionRow) async
}
struct ModelVersionsView: View { init(model: ModelVersionsModel) }

// Online providers — the "AI Models" settings panel. Host owns [RemoteProviderDraft]
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
    var id: String { scheme }
    var scheme, displayName, baseURL, apiKey: String
    var kind: RemoteProviderKind
    var models: [String]                 // .new(_:) leaves this empty — host prefills
    var webSearchSupported, webSearchEnabled, configured: Bool
    var maxSearches: Int
    var statusText: String?
    init(scheme: String, displayName: String, kind: RemoteProviderKind, baseURL: String = "", apiKey: String = "",
         models: [String] = [], webSearchSupported: Bool = false, webSearchEnabled: Bool = false,
         maxSearches: Int = 5, configured: Bool = false, statusText: String? = nil)
    static func new(_ kind: RemoteProviderKind) -> RemoteProviderDraft
}
enum RemoteProviderKind: String, Sendable, Hashable, CaseIterable {   // openAIChat, openAIResponses, anthropic, openRouter, openAICompatible
    var addMenuLabel: String { get }
}
struct ProviderTestOutcome: Sendable, Equatable {
    struct ModelResult: Sendable, Equatable, Identifiable {
        var modelId: String; var ok: Bool; var detail: String
        init(modelId: String, ok: Bool, detail: String)
    }
    var results: [ModelResult]           // one per configured model, in order
    var message: String?                 // set instead of results when the check couldn't run
    init(results: [ModelResult], message: String? = nil)
    static func unableToRun(_ message: String) -> ProviderTestOutcome
}
```
