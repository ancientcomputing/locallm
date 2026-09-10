import Foundation
import FoundationModels
import LocalLMLabSDKComponents
import LocalLMLabSDKCore
import LocalLMLabSDKRemote
import Observation

// Owns the SDK objects and the run loop. The host-app responsibilities the example takes on
// itself (a real app would have polished UI for these):
//   - register the frontier providers it has API keys for (env var, or pasted into the UI)
//   - grant Calendar access
//   - connect the Todoist MCP server and enable the two tools this demo uses
//
// `run(prompt:)` is the part worth reading: it turns `DemoSecurity` into a tool list + an
// authorizer and hands them to `lab.makeSession`.

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum FrontierProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    var id: String { rawValue }
    var label: String { self == .anthropic ? "Anthropic" : "OpenAI" }
    var scheme: String { rawValue }

    /// Env var holding the API key, and the default model id (override with
    /// SECURITYDEMO_ANTHROPIC_MODEL / SECURITYDEMO_OPENAI_MODEL).
    var keyEnv: String { self == .anthropic ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY" }
    var modelEnv: String { self == .anthropic ? "SECURITYDEMO_ANTHROPIC_MODEL" : "SECURITYDEMO_OPENAI_MODEL" }
    var defaultModel: String { self == .anthropic ? "claude-sonnet-4-5" : "gpt-4o" }

    /// UserDefaults key for a pasted API key. **Demo persistence only** — a real app stores
    /// API keys in the Keychain, not UserDefaults (same note as examples/model-switch).
    var defaultsKey: String { "securitydemo.apiKey.\(rawValue)" }
}

@MainActor
@Observable
final class AppModel {
    let security = DemoSecurity()

    /// The SwiftUI-facing confirmation channel. `ConfirmingToolAuthorizer` calls into this; the
    /// view renders its queue via `.toolConfirmationSheet(presenter)`.
    @ObservationIgnored let presenter = ToolConfirmationPresenter()

    private(set) var lab: LocalLMLab!
    private(set) var availableProviders: [FrontierProvider] = []
    var provider: FrontierProvider = .anthropic

    // run state
    var prompt = "Add a 'Dentist' event tomorrow at 3pm, and add a 'Buy milk' task to Todoist."
    var output = ""
    var toolLog: [String] = []
    var isRunning = false
    var elapsed: TimeInterval = 0

    /// Shown above the output. Provider status, then any Calendar / Todoist setup problem.
    var providerNote: String?
    private var connectorNotes: [String] = []
    var setupNote: String? {
        ([providerNote].compactMap { $0 } + connectorNotes).joined(separator: "\n").nilIfEmpty
    }

    private let todoistURL = URL(string: "https://ai.todoist.net/mcp")!
    // find-tasks lets the model resolve "Buy milk" -> a task id, which complete-tasks needs
    // (MCP tools are 1:1 passthroughs — no name lookup like the Calendar connector has).
    private let todoistTools = ["find-tasks", "add-tasks", "complete-tasks"]

    // MARK: bootstrap

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

    /// Kicked off from `.onAppear`, not `.task` — the MCP OAuth flow bounces through the
    /// browser and back via `securitydemo://`, and `.task` cancels its work on the scene
    /// churn that round-trip causes (observed: the token exchange failing with -999).
    func startBootstrap() {
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { await bootstrap() }
    }

    /// An API key for `p`: environment first (set when launched from a terminal or the Xcode
    /// scheme), then one pasted into the UI on a previous launch.
    func storedKey(for p: FrontierProvider) -> String {
        if let env = ProcessInfo.processInfo.environment[p.keyEnv], !env.isEmpty { return env }
        return UserDefaults.standard.string(forKey: p.defaultsKey) ?? ""
    }

    func hasKey(for p: FrontierProvider) -> Bool { !storedKey(for: p).isEmpty }

    /// Persist a pasted key and register (or replace) that provider live — no relaunch.
    func saveKey(_ raw: String, for p: FrontierProvider) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        UserDefaults.standard.set(key, forKey: p.defaultsKey)
        registerProvider(p, key: key)
        if !availableProviders.contains(p) { availableProviders.append(p) }
        if availableProviders.count == 1 { provider = p }
        providerNote = availableProviders.isEmpty ? providerNote : nil
    }

    private func registerProvider(_ p: FrontierProvider, key: String) {
        var cfg = p == .anthropic
            ? RemoteProviderConfig.anthropic(apiKey: key)
            : RemoteProviderConfig.openAI(apiKey: key)
        cfg.allowArbitraryModelIDs = true
        lab.models.replace(RemoteModelProvider(cfg))   // register-or-swap by scheme
    }

    private func bootstrap() async {
        // `lab` exists from the start (possibly with no providers) so a key pasted into the UI
        // can be registered live.
        lab = LocalLMLab()
        for p in FrontierProvider.allCases where hasKey(for: p) {
            registerProvider(p, key: storedKey(for: p))
            availableProviders.append(p)
        }
        if let first = availableProviders.first { provider = first }
        if availableProviders.isEmpty {
            providerNote = "Paste an Anthropic or OpenAI API key below to run."
        }

        // Calendar — a real app has its own permission screen; here we just ask on launch.
        let access = await CalendarAccess.requestAccess()
        if !access.granted {
            appendSetup(access.error ?? "Calendar access not granted — Calendar tools will fail.")
        }

        // Todoist MCP — connect in-process and enable the two tools the demo drives.
        let auth: (type: MCPAuthType, token: String?) = {
            if let t = ProcessInfo.processInfo.environment["TODOIST_MCP_TOKEN"], !t.isEmpty { return (.pat, t) }
            return (.none, nil)
        }()
        switch await lab.mcp.addServer(url: todoistURL, displayName: "todoist",
                                       authType: auth.type, patToken: auth.token) {
        case .success(let state):
            for tool in todoistTools where state.tools.contains(where: { $0.name == tool }) {
                lab.mcp.setToolEnabled(server: state.id, tool: tool, enabled: true)
            }
            let missing = todoistTools.filter { name in !state.tools.contains { $0.name == name } }
            if !missing.isEmpty { appendSetup("Todoist server is missing expected tools: \(missing.joined(separator: ", "))") }
        case .failure(let error):
            appendSetup("Couldn't connect Todoist MCP: \(error). Set TODOIST_MCP_TOKEN if it needs auth. Calendar-only demo still works.")
        }
    }

    private func appendSetup(_ line: String) { connectorNotes.append(line) }

    // MARK: run — DemoSecurity → SDK

    func run() async {
        guard !isRunning, lab != nil, !availableProviders.isEmpty else { return }
        isRunning = true
        output = ""
        toolLog = []
        elapsed = 0
        defer { isRunning = false }

        let start = Date()
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await MainActor.run { self?.elapsed = Date().timeIntervalSince(start) }
            }
        }
        defer { ticker.cancel() }

        do {
            // Route the "frontier" alias at the selected provider's model.
            let modelName = ProcessInfo.processInfo.environment[provider.modelEnv] ?? provider.defaultModel
            guard let modelID = ModelID(scheme: provider.scheme, rest: modelName) else {
                output = "Bad model id: \(provider.scheme):\(modelName)"; return
            }
            lab.models.route("frontier", to: modelID)

            // Snapshot the panel now — the rest of this run uses a fixed policy.
            let policy = security.snapshot()

            // Lever 1 — selection. Build the full Calendar tool set, then filter to the level.
            // ClockTool is always on — the model needs "today" to reason about "tomorrow", and
            // it's `.read`, so it survives every level.
            let hostTools: [any Tool] = [ClockTool()] + policy.limitedCalendarTools([
                GetUpcomingEventsTool(),
                AddCalendarEventTool(),
                UpdateCalendarEventTool(),
                DeleteCalendarEventTool(),
            ])

            // Lever 2 — invocation. No authorizer at all when nothing is set to confirm.
            let authorizer: (any ToolCallAuthorizer)? = policy.wantsConfirmation
                ? ConfirmingToolAuthorizer(
                    channel: presenter,
                    requirement: { call in policy.requirement(for: call) })
                : nil

            let session = try lab.makeSession(
                route: "frontier",
                tools: hostTools,
                instructions: "You are a helpful assistant with access to the user's Calendar and Todoist. "
                    + "Use the tools to carry out the request. If a tool isn't available or a call is "
                    + "denied, say so plainly and continue.",
                includeMCPTools: true,          // pulls the enabled Todoist tools, tagged .mcp
                authorizer: authorizer)

            let events = Task { [weak self] in
                for await ev in session.events {
                    guard let self else { return }
                    switch ev {
                    case .toolCallStarted(_, let name):
                        await MainActor.run { self.toolLog.append("→ \(name)") }
                    case .toolCallFinished(_, let name, let failed):
                        await MainActor.run { self.toolLog.append("   \(name) \(failed ? "✗ denied/failed" : "✓")") }
                    default:
                        break
                    }
                }
            }
            defer { events.cancel() }

            output = try await session.respond(to: prompt)
        } catch {
            output = "Error: " + ((error as? LocalLMLabError)?.errorDescription ?? "\(error)")
        }
    }
}
