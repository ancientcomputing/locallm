import AppKit
import LocalLMLabSDKCore
import SwiftUI

// A tool call's MCP App widget, inline under the call in a chat.
// From mcp-chat by way of ChatAgain.
//
// - First showing: the widget is fetched from the server, cached by hash and bound to the call.
// - Live widgets are capped (`MCPAppViewPool`, Settings → Live widgets). A widget released past the
//   cap shows its snapshot until it scrolls back into view or is clicked, then it is re-created.
// - Re-creating (after the cap, after a relaunch, or after the session was rebuilt) checks the
//   server first (`MCPAppRecreation.revalidate`): the current widget gets the stored result when the
//   tool's output still has the same shape; otherwise the user is offered a refresh. Offline, the
//   cached version is shown view-only.
// - Calls a widget makes go through the session (`MCPAppsSessionBackend`), so the session's
//   authorizer asks the user exactly as it does for the model's calls, and they are recorded.

/// What `MCPAppWidgetSlot` needs from the app: the chat's session and server manager, where widgets
/// are cached, how it names itself to widgets, and what widgets may do.
@MainActor
public struct MCPAppWidgetContext {
    /// The conversation's session; widget calls go through it, so its authorizer asks the user.
    public var session: LocalLMLabSession?
    public var manager: MCPServerManager
    public var cache: MCPAppWidgetCache
    public var hostName: String
    public var hostVersion: String
    /// Whether a widget may send a message into the chat (`ui/message`). Asked each time.
    public var allowMessages: () -> Bool
    /// Whether a widget may update the model's context. Asked each time.
    public var allowModelContext: () -> Bool
    /// A widget's message, sent as the next turn (shown as running, then saved).
    public var sendMessage: (_ text: String, _ instance: String) -> Void
    /// A failure to tell the user about ("Refresh failed: …").
    public var reportError: (String) -> Void

    public init(session: LocalLMLabSession?, manager: MCPServerManager, cache: MCPAppWidgetCache,
                hostName: String, hostVersion: String,
                allowMessages: @escaping () -> Bool, allowModelContext: @escaping () -> Bool,
                sendMessage: @escaping (_ text: String, _ instance: String) -> Void,
                reportError: @escaping (String) -> Void) {
        self.session = session
        self.manager = manager
        self.cache = cache
        self.hostName = hostName
        self.hostVersion = hostVersion
        self.allowMessages = allowMessages
        self.allowModelContext = allowModelContext
        self.sendMessage = sendMessage
        self.reportError = reportError
    }
}

/// The widget for one tool call (`record.app`), with its loading, offline, refresh and snapshot states.
public struct MCPAppWidgetSlot: View {
    let record: ToolCallRecord
    let context: MCPAppWidgetContext
    @ObservedObject var pool: MCPAppViewPool

    public init(record: ToolCallRecord, context: MCPAppWidgetContext, pool: MCPAppViewPool) {
        self.record = record
        self.context = context
        self.pool = pool
    }

    enum Phase {
        case idle
        case loading
        case live(MCPAppViewController, viewOnly: Bool, changed: Bool)
        case needsRefresh(automatic: Bool)
        case unavailable(String)
    }

    @State private var phase: Phase = .idle
    @State private var refreshing = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            footer
        }
        .onAppear { if !pool.isLive(record.id) { Task { await activate() } } }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .live(let controller, _, _) where pool.isLive(record.id):
            LiveWidget(controller: controller)
                .onTapGesture { pool.touch(record.id) }
        case .live, .idle:
            if let snapshot = pool.snapshot(for: record.id) {
                Image(nsImage: snapshot)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .opacity(0.6)
                    .overlay { Label("Click to reactivate", systemImage: "play.circle").padding(8).background(.regularMaterial, in: Capsule()) }
                    .onTapGesture { Task { await activate() } }
            } else {
                placeholder("Interactive view", systemImage: "rectangle.on.rectangle") {
                    Button("Show") { Task { await activate() } }
                }
            }
        case .loading:
            placeholder("Loading view…", systemImage: nil) { ProgressView().controlSize(.small) }
        case .needsRefresh(let automatic):
            placeholder("This view changed since this answer. The saved result may not fit it.",
                        systemImage: "arrow.triangle.2.circlepath") {
                Button(automatic ? "Refresh" : "Re-run tool…") { Task { await refresh() } }
                    .disabled(refreshing)
            }
        case .unavailable(let reason):
            placeholder(reason, systemImage: "wifi.slash") {
                Button("Retry") { Task { await activate() } }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let background = context.session?.hostTranscript.appOnlyCallCount(for: record.id) ?? 0
        HStack(spacing: 10) {
            if case .live(_, let viewOnly, let changed) = phase {
                if viewOnly { Label("Offline — view only", systemImage: "wifi.slash") }
                if changed { Label("Updated view", systemImage: "sparkles") }
            }
            if background > 0 { Label("\(background) background update\(background == 1 ? "" : "s")", systemImage: "arrow.clockwise") }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func placeholder(_ text: String, systemImage: String?, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
            Text(text).foregroundStyle(.secondary)
            Spacer()
            action()
        }
        .font(.callout)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The widget instance for a call: the call's id for the version the call was first shown with (bound to it in
    /// the cache), and the id plus the version's hash for any other version the server serves later — so the
    /// session's authorizer, which remembers a widget's answers per instance, asks the new version again.
    public static func instanceID(record: String, widget sha256: String, bound: String?) -> String {
        bound == nil || bound == sha256 ? record : record + "@" + String(sha256.prefix(12))
    }

    // MARK: lifecycle

    private func activate() async {
        if case .loading = phase { return }
        guard let session = context.session, let server = serverID, let uri = record.app?.resourceURI,
              record.mcpResult != nil else { return }
        phase = .loading
        let resource: MCPAppResource
        var viewOnly = false
        var changed = false
        if context.cache.sha256(forRecord: record.id) == nil {
            // First showing of this call: the server's current widget, kept and bound to the call.
            do {
                resource = try await context.cache.fetch(resourceURI: uri, server: server, manager: context.manager, recordID: record.id)
            } catch {
                phase = .unavailable("Couldn't load the view (\(error.localizedDescription)).")
                return
            }
        } else {
            let check = await MCPAppRecreation.revalidate(
                record, source: MCPServerManagerWidgetSource(manager: context.manager, server: server), cache: context.cache)
            switch check?.decision {
            case .render(let offline)?:
                guard let current = check?.resource else { phase = .unavailable("The view is no longer available."); return }
                resource = current
                viewOnly = offline
                changed = check?.widgetChanged ?? false
            case .needsRefresh(let automatic)?:
                phase = .needsRefresh(automatic: automatic)
                return
            case .notApproved?:
                phase = .unavailable("This version of the view isn't approved.")
                return
            case .unavailable?, nil:
                phase = .unavailable("The server can't be reached and this view isn't saved.")
                return
            }
        }

        // A widget the server has changed since this call was first shown is a different instance: the user's
        // earlier answers to its calls don't carry over to code they haven't seen (security review 2026-10-28, C26).
        let instance = Self.instanceID(record: record.id, widget: resource.sha256, bound: context.cache.sha256(forRecord: record.id))
        context.manager.audit.record(.widgetShown(instance: instance, server: server, sha256: resource.sha256,
                                                  changedSinceApproved: instance != record.id))
        let controller = pool.controller(for: instance) {
            var actions = MCPAppsHostActions.session(session, instance: instance, openLink: { NSWorkspace.shared.open($0) })
            // Route widget messages through the chat so the turn shows as running and is saved.
            let send = context.sendMessage
            actions.sendMessage = { text in send(text, instance) }
            return MCPAppViewController(
                resource: resource,
                tools: context.manager.servers[server]?.tools ?? record.toolDescriptor.map { [$0] } ?? [],
                backend: viewOnly ? MCPAppsOfflineBackend() as any MCPAppsBackend
                    : MCPAppsSessionBackend(session: session, manager: context.manager, server: server, instance: instance),
                configuration: MCPAppsBridgeConfiguration(
                    hostName: context.hostName, hostVersion: context.hostVersion,
                    hostContext: ["displayMode": .string("inline"), "locale": .string(Locale.current.identifier(.bcp47))]),
                bridgePolicy: MCPAppsInlinePolicy(viewOnly: viewOnly, allowMessages: context.allowMessages,
                                                  allowModelContext: context.allowModelContext),
                sandboxPolicy: .closed,
                actions: actions)
        }
        MCPAppRecreation.deliver(record, to: controller)
        phase = .live(controller, viewOnly: viewOnly, changed: changed)
        await controller.load()
    }

    /// Re-runs the call (as the host, through the session's authorizer). The fresh result arrives
    /// as a new call at the end of the conversation, with the current view.
    private func refresh() async {
        guard let session = context.session, let server = serverID, case .mcp(_, let tool) = record.tool else { return }
        refreshing = true
        defer { refreshing = false }
        let arguments = MCPAppRecreation.toolInput(from: record.arguments)
        if case .failure(let error) = await session.callMCPTool(server: server, tool: tool, arguments: arguments, initiator: .host) {
            context.reportError("Refresh failed: \(error)")
        }
    }

    private var serverID: MCPServerID? {
        if case .mcp(let server, _) = record.tool { return server }
        return nil
    }
}

/// Observes the controller so the slot follows the widget's reported height.
private struct LiveWidget: View {
    @ObservedObject var controller: MCPAppViewController

    var body: some View {
        MCPAppView(controller: controller)
            .frame(height: max(80, controller.contentHeight ?? 360))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

/// What an inline chat widget may ask the host for, on top of the protocol's own rules. Tool calls
/// are allowed because the session's authorizer asks the user (none when view-only); links only
/// over https; messages and model context as the app's settings say.
public struct MCPAppsInlinePolicy: MCPAppsBridgePolicy {
    let viewOnly: Bool
    let allowMessages: () -> Bool
    let allowModelContext: () -> Bool

    public init(viewOnly: Bool, allowMessages: @escaping () -> Bool, allowModelContext: @escaping () -> Bool) {
        self.viewOnly = viewOnly
        self.allowMessages = allowMessages
        self.allowModelContext = allowModelContext
    }

    public func authorizeToolCall(name: String, arguments: [String: MCPValue]) async -> MCPAppsDecision {
        viewOnly ? .deny("Offline: this view is view-only") : .allow
    }

    public func authorizeOpenLink(_ url: URL) async -> MCPAppsDecision {
        url.scheme?.lowercased() == "https" ? .allow : .deny("Only https links may be opened")
    }

    public func authorizeMessage(text: String) async -> MCPAppsDecision {
        allowMessages() ? .allow : .deny("Widget messages are off in Settings")
    }

    public func authorizeModelContextUpdate() async -> MCPAppsDecision {
        allowModelContext() ? .allow : .deny("Widget context is off in Settings")
    }
}

/// The backend for a view-only (offline) widget: nothing reaches the server.
public struct MCPAppsOfflineBackend: MCPAppsBackend {
    public init() {}
    public func callTool(name: String, arguments: [String: MCPValue]) async -> Result<MCPToolResult, MCPServerError> { .failure(.notConnected) }
    public func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError> { .failure(.notConnected) }
}
