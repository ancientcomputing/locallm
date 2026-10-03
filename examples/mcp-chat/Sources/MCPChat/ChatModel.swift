import AppKit
import Combine
import Foundation
import FoundationModels
import LocalLMLabSDKComponents
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import LocalLMLabSDKMCPAppsHost

// The model this app routes to by default, pinned to the commit it was tried against (see
// workspace-buddy-local for why a revision is pinned).
let qwenRepo = "mlx-community/Qwen3-8B-4bit"
let qwenRevision = "545dc4251c05440727734bcd94334791f6ab0192"

extension RouteName {
    static let chat: RouteName = "chat"
}

enum ChatModelChoice: String, CaseIterable, Identifiable {
    case qwen3
    case apple

    var id: String { rawValue }
    var title: String {
        switch self {
        case .qwen3: "Qwen3 8B (MLX, local)"
        case .apple: "Apple on-device model"
        }
    }
    var modelID: ModelID {
        switch self {
        case .qwen3: ModelID(scheme: "mlx", rest: qwenRepo)!
        case .apple: .system
        }
    }
}

/// App settings (Settings window). Read where they are used, so a change applies from the next
/// turn without restarting.
enum ChatSettings {
    static let modelKey = "model"
    /// Whether a reopened conversation continues with the model's memory of it. Off: the user still
    /// sees the earlier conversation, but the model starts fresh (and nothing the model saw is
    /// written to disk).
    static let rememberKey = "rememberConversation"
    static let widgetMessagesKey = "allowWidgetMessages"
    static let widgetContextKey = "allowWidgetContext"
    static let liveWidgetsKey = "liveWidgetLimit"
    static let clockToolKey = "clockTool"

    static func register() {
        UserDefaults.standard.register(defaults: [
            modelKey: ChatModelChoice.qwen3.rawValue,
            rememberKey: true,
            widgetMessagesKey: false,
            widgetContextKey: true,
            liveWidgetsKey: 3,
            clockToolKey: true,
        ])
    }

    static var model: ChatModelChoice {
        ChatModelChoice(rawValue: UserDefaults.standard.string(forKey: modelKey) ?? "") ?? .qwen3
    }
    static var remember: Bool { UserDefaults.standard.bool(forKey: rememberKey) }
    static var allowWidgetMessages: Bool { UserDefaults.standard.bool(forKey: widgetMessagesKey) }
    static var allowWidgetContext: Bool { UserDefaults.standard.bool(forKey: widgetContextKey) }
    static var liveWidgets: Int { max(1, UserDefaults.standard.integer(forKey: liveWidgetsKey)) }
    static var clockTool: Bool { UserDefaults.standard.bool(forKey: clockToolKey) }
}

@MainActor
final class ChatModel: ObservableObject {
    enum Status: Equatable {
        /// The chosen model is not ready (e.g. Qwen3 is not downloaded yet).
        case needsModel
        case downloading(Double)
        case ready
        case responding
    }

    let manager: MCPServerManager
    let servers: MCPServerManagerObservable
    let toolConfirm = ToolConfirmationPresenter()
    let widgetCache = MCPAppWidgetCache()
    let pool = MCPAppViewPool(limit: ChatSettings.liveWidgets)

    @Published private(set) var session: LocalLMLabSession?
    @Published private(set) var status: Status = .needsModel
    @Published private(set) var modelChoice = ChatSettings.model
    /// Set when a conversation was reopened without the model's memory: turns up to this one were
    /// not given to the model.
    @Published private(set) var memoryBoundaryTurn: Int?
    @Published var errorMessage: String?
    @Published var showServers = false
    /// One authorizer for every session. It follows each server's trust and tool approval, which
    /// the user sets per server in the server list (Components' picker), and remembers a widget's
    /// answers; a session made after a model switch keeps them.
    private let authorizer: ConfirmingToolAuthorizer

    // Development only: MCPCHAT_MODEL_CACHE points at an existing Hugging Face cache, so a build
    // without App Sandbox (SANDBOX=0 packaging/build-and-sign.sh) can skip the download. A
    // sandboxed build can't read outside its container and downloads into it.
    private let mlx = MLXModelProvider(
        cacheDirectory: ProcessInfo.processInfo.environment["MCPCHAT_MODEL_CACHE"].map { URL(fileURLWithPath: $0) },
        residentModelLimit: 1, pinnedRevisions: [qwenRepo: qwenRevision])
    private let lab: LocalLMLab
    private let store = ConversationStore()
    private var sessionSignature: String?
    private var cancellables: Set<AnyCancellable> = []

    static let instructions = """
        You are a helpful assistant in a chat app. Use the tools you have when the user asks about \
        their data or asks you to change it. Some tools also show the user an interactive view of \
        the result; when one does, keep your reply short and do not repeat what the view shows.
        """

    init() {
        ChatSettings.register()
        // The lab makes the one MCP manager (`lab.mcp`). Declare MCP Apps support so servers that
        // gate their widgets on it offer them.
        let lab = LocalLMLab(configuration: .init(
            providers: [mlx, SystemModelProvider()],
            mcp: MCPSettings(handlers: MCPClientHandlers().advertisingMCPApps())))
        self.lab = lab
        self.manager = lab.mcp
        self.servers = MCPServerManagerObservable(core: lab.mcp)
        authorizer = ConfirmingToolAuthorizer(channel: toolConfirm)
        modelChoice = ChatSettings.model
        lab.models.route(.chat, to: modelChoice.modelID)
    }

    // MARK: launch

    func start() async {
        await restoreServers()
        refreshModelStatus()
        if status == .ready { openSavedConversation() }

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.save() } }
            .store(in: &cancellables)
    }

    private func refreshModelStatus() {
        switch lab.models.availability(for: modelChoice.modelID) {
        case .available: if status != .responding { status = .ready }
        default: status = .needsModel
        }
    }

    var modelUnavailableReason: String? {
        switch lab.models.availability(for: modelChoice.modelID) {
        case .available, .notDownloaded: nil
        case .needsCredential: "This model needs a credential."
        case .unavailable(_, let detail): detail
        @unknown default: "This model is not available."
        }
    }

    func downloadModel() async {
        guard modelChoice == .qwen3, status == .needsModel else { return }
        status = .downloading(0)
        do {
            if let preflight = try? await mlx.validate(qwenRepo), !preflight.passed {
                throw ChatError("This Mac can't run \(qwenRepo): \(preflight.detail ?? "pre-flight failed").")
            }
            for try await event in mlx.download(qwenRepo) {
                if case .progress(_, _, let fraction) = event { status = .downloading(fraction) }
            }
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
        status = .needsModel
        refreshModelStatus()
        if status == .ready, session == nil { openSavedConversation() }
    }

    private func settingsChanged() {
        pool.limit = ChatSettings.liveWidgets
        if !ChatSettings.remember { store.forgetModelMemory() }
        guard ChatSettings.model != modelChoice, status != .responding else { return }
        modelChoice = ChatSettings.model
        lab.models.route(.chat, to: modelChoice.modelID)
        refreshModelStatus()
        // The session is rebuilt on the next turn, carrying the conversation over to the new model.
        if status == .ready, session == nil { openSavedConversation() }
    }

    // MARK: conversation

    /// Reopens the saved conversation: always what the user saw; the model's memory of it only
    /// when "Remember conversations" is on.
    private func openSavedConversation() {
        let saved = store.load()
        let memory = ChatSettings.remember ? saved?.model : nil
        do {
            let session = try makeSession(restoring: memory)
            if let shown = saved?.shown { try session.hostTranscript.restore(from: shown) }
            if memory == nil, let last = session.hostTranscript.entries.last?.turn { memoryBoundaryTurn = last }
            install(session)
        } catch {
            errorMessage = "Couldn't open the saved conversation: \(error.localizedDescription)"
            if let fresh = try? makeSession(restoring: nil) { install(fresh) }
        }
    }

    func newConversation() {
        guard status != .responding else { return }
        Task { await pool.releaseAll() }
        store.clear()
        memoryBoundaryTurn = nil
        session = nil
        sessionSignature = nil
        if status == .ready, let fresh = try? makeSession(restoring: nil) { install(fresh) }
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        Task { await respond { $0.streamResponse(to: prompt) } }
    }

    /// A widget's `ui/message` — only reached when Settings allows widget messages.
    func sendFromWidget(_ text: String, instance: String) {
        Task { await respond { $0.streamResponse(to: text, fromAppInstance: instance) } }
    }

    /// Runs a streamed turn. The view draws the reply as it arrives from
    /// `hostTranscript.replyInProgress`, so the stream only needs draining here.
    private func respond(_ turn: (LocalLMLabSession) -> AsyncThrowingStream<String, any Error>) async {
        guard status == .ready else { return }
        let session: LocalLMLabSession
        do {
            session = try currentSession()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        status = .responding
        defer {
            status = .ready
            save()
        }
        do {
            for try await _ in turn(session) {}
        } catch {
            errorMessage = await GenerationErrorDescription.describe(error)
        }
    }

    /// The session for the next turn. A session follows `lab.mcp` by itself (tools turned on or
    /// off, servers added, trust changed: picked up on its next turn). What it can't follow is a
    /// different model or a change to the app's own tools; then a new session takes over the
    /// conversation: the model's memory (its transcript) and what the user sees (the archive).
    private func currentSession() throws -> LocalLMLabSession {
        if let session, sessionSignature == signature() { return session }
        guard let old = session else {
            let fresh = try makeSession(restoring: nil)
            install(fresh)
            return fresh
        }
        let fresh = try makeSession(restoring: old.languageModelSession.transcript)
        try fresh.hostTranscript.restore(from: old.hostTranscript.archive())
        // Live widgets call through the session they were made with: re-create them on the new one.
        Task { await pool.releaseAll() }
        install(fresh)
        return fresh
    }

    private func makeSession(restoring memory: Transcript?) throws -> LocalLMLabSession {
        // A saved conversation carries its own instructions; a new one gets the app's.
        var session = try lab.makeSession(
            route: .chat, tools: builtInTools, instructions: memory == nil ? Self.instructions : nil,
            restoring: memory, mcpAppHints: true, authorizer: authorizer)
        session.retryOnContextOverflow = RetryPolicy(maxRetries: 2, compact: Self.dropOldestHalf)
        session.turnContext = { Self.clock(Date()) }
        sessionSignature = signature()
        return session
    }

    /// The app's own tools, alongside the MCP servers'. The SDK's clock (`getCurrentTime`, rated
    /// read-only, so it never asks) lets the model check the date when it needs to — e.g. to turn
    /// "tomorrow" into a date for Todoist. It is in addition to the date sent with each turn.
    private var builtInTools: [any Tool] {
        ChatSettings.clockTool ? [ClockTool()] : []
    }

    var builtInToolNames: [String] { builtInTools.map(\.name) }

    private func install(_ session: LocalLMLabSession) {
        self.session = session
    }

    /// What a session can't change by itself: the model and the app's own tools.
    private func signature() -> String {
        ([modelChoice.rawValue] + builtInToolNames).joined(separator: "\n")
    }

    /// The current date and time, sent with every turn: a model has no clock, so without it
    /// "what's due tomorrow?" resolves against a date from its training data.
    nonisolated static func clock(_ now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let weekday = calendar.weekdaySymbols[(parts.weekday ?? 1) - 1]
        let offset = timeZone.secondsFromGMT(for: now) / 60
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let utc = String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
        return "[Current date and time: \(weekday) \(date) \(time), \(timeZone.identifier) (\(utc)). "
            + "Use it for relative dates such as today, tomorrow or next week.]"
    }

    /// Context overflow (e.g. a long conversation moved to the smaller on-device model): keep the
    /// instructions and the newer half of the conversation, starting at a user turn.
    nonisolated static func dropOldestHalf(_ transcript: Transcript) -> Transcript {
        let entries = Array(transcript)
        let prompts = entries.indices.filter { if case .prompt = entries[$0] { true } else { false } }
        guard prompts.count > 1 else { return transcript }
        let keepFrom = prompts[prompts.count / 2]
        var kept: [Transcript.Entry] = []
        if let first = entries.first, case .instructions = first { kept.append(first) }
        kept.append(contentsOf: entries[keepFrom...])
        return Transcript(entries: kept)
    }

    private func save() {
        guard let session else { return }
        store.save(shown: try? session.hostTranscript.archive(),
                   model: ChatSettings.remember ? session.languageModelSession.transcript : nil)
    }

    // MARK: servers (saved list; quiet reconnect)

    private struct SavedServer: Codable {
        var url: URL
        var name: String
        var authType: MCPAuthType
        var manualClientID: String?
        var noAuth: Bool
        /// The server's tools as last seen, with the user's on/off choice for each. New tools from
        /// a server start off (the SDK's default); restoring these keeps the user's choices.
        var tools: [MCPToolDescriptor]?
        /// The user's trust and tool approval for the server (server list). The manager doesn't
        /// persist them; they are set again after restore.
        var trust: MCPServerTrust?
        var toolApproval: ToolApproval?
    }

    private let savedServersKey = "servers.v1"

    private func restoreServers() async {
        let saved = (UserDefaults.standard.data(forKey: savedServersKey)
            .flatMap { try? JSONDecoder().decode([SavedServer].self, from: $0) }) ?? []
        manager.restore(from: saved.map {
            (id: MCPServerID(rawValue: $0.url.absoluteString), url: $0.url, displayName: $0.name, tools: $0.tools ?? [], estimatedTokens: 0,
             enabled: true, authType: $0.authType, manualClientID: $0.manualClientID, resources: [])
        })
        // Trust before reconnecting: trusting records the saved tool list, so a server whose tools
        // changed while the app was closed shows "tools changed since trusted".
        for server in saved {
            let id = MCPServerID(rawValue: server.url.absoluteString)
            if let trust = server.trust { manager.setTrust(trust, server: id) }
            manager.setToolApproval(server.toolApproval, server: id)
        }
        // Only servers that need no sign-in, or have a stored credential, reconnect at launch: this
        // app never opens a browser unprompted.
        for server in saved where server.noAuth || MCPCredentialProbe.storedKind(for: server.url) != nil {
            _ = await manager.reconnect(MCPServerID(rawValue: server.url.absoluteString))
        }
        servers.$servers.dropFirst().sink { [weak self] in self?.persist($0) }.store(in: &cancellables)
    }

    private func persist(_ states: [MCPServerID: MCPServerState]) {
        let previous = (UserDefaults.standard.data(forKey: savedServersKey)
            .flatMap { try? JSONDecoder().decode([SavedServer].self, from: $0) }) ?? []
        let saved = states.values.map { state in
            SavedServer(url: state.url, name: state.displayName, authType: state.authType, manualClientID: state.manualClientID,
                        noAuth: state.connectionStatus == .connected
                            ? MCPCredentialProbe.storedKind(for: state.url) == nil
                            : previous.first { $0.url == state.url }?.noAuth ?? false,
                        tools: state.tools.isEmpty ? previous.first { $0.url == state.url }?.tools : state.tools,
                        trust: state.trust, toolApproval: state.toolApproval)
        }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: savedServersKey) }
    }

    /// The MCP tools the model is given on its next turn.
    var modelTools: [MCPToolDescriptor] { manager.toolsForSession() }

    /// Connected servers none of whose tools are on: the model can't use them yet. (New tools start
    /// off; the user turns on the ones they want in the server list.)
    var serversWithNoToolsOn: [MCPServerState] {
        servers.sortedServers.filter { state in
            state.connectionStatus == .connected && !state.tools.isEmpty
                && !state.tools.contains { $0.enabled && $0.isModelVisible }
        }
    }

    /// The server a tool call went to, for its widget.
    func serverID(of record: ToolCallRecord) -> MCPServerID? {
        if case .mcp(let server, _) = record.tool { return server }
        return nil
    }
}

struct ChatError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The open conversation on disk (Application Support/MCPChat): what the user saw
/// (`HostTranscript.archive()`) and, when "Remember conversations" is on, the model's transcript.
struct ConversationStore {
    struct Saved {
        var shown: Data?
        var model: Transcript?
    }

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MCPChat/Conversation", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private var shownFile: URL { directory.appendingPathComponent("shown.json") }
    private var modelFile: URL { directory.appendingPathComponent("model.json") }

    func load() -> Saved? {
        let shown = try? Data(contentsOf: shownFile)
        let model = (try? Data(contentsOf: modelFile)).flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
        return shown == nil && model == nil ? nil : Saved(shown: shown, model: model)
    }

    func save(shown: Data?, model: Transcript?) {
        if let shown { try? shown.write(to: shownFile, options: .atomic) }
        if let model, let data = try? JSONEncoder().encode(model) {
            try? data.write(to: modelFile, options: .atomic)
        } else {
            forgetModelMemory()
        }
    }

    func forgetModelMemory() {
        try? FileManager.default.removeItem(at: modelFile)
    }

    func clear() {
        try? FileManager.default.removeItem(at: shownFile)
        forgetModelMemory()
    }
}
