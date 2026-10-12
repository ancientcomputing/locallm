import AppKit
import LocalLMLabSDKCore
import LocalLMLabSDKMCPAppsHost
import SwiftUI

// A tool call's MCP App widget, inline under the call in the conversation.
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

struct WidgetSlot: View {
    let record: ToolCallRecord
    @ObservedObject var chat: ChatModel
    @ObservedObject var pool: MCPAppViewPool

    enum Phase {
        case idle
        case loading
        case live(MCPAppViewController, viewOnly: Bool, changed: Bool)
        case needsRefresh(automatic: Bool)
        case unavailable(String)
    }

    @State private var phase: Phase = .idle
    @State private var refreshing = false

    var body: some View {
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
        let background = chat.session?.hostTranscript.appOnlyCallCount(for: record.id) ?? 0
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

    // MARK: lifecycle

    private func activate() async {
        if case .loading = phase { return }
        guard let session = chat.session, let server = chat.serverID(of: record), let uri = record.app?.resourceURI,
              record.mcpResult != nil else { return }
        phase = .loading
        let resource: MCPAppResource
        var viewOnly = false
        var changed = false
        if chat.widgetCache.sha256(forRecord: record.id) == nil {
            // First showing of this call: the server's current widget, kept and bound to the call.
            do {
                resource = try await chat.widgetCache.fetch(resourceURI: uri, server: server, manager: chat.manager, recordID: record.id)
            } catch {
                phase = .unavailable("Couldn't load the view (\(error.localizedDescription)).")
                return
            }
        } else {
            let check = await MCPAppRecreation.revalidate(
                record, source: MCPServerManagerWidgetSource(manager: chat.manager, server: server), cache: chat.widgetCache)
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

        let instance = record.id
        let controller = pool.controller(for: instance) {
            var actions = MCPAppsHostActions.session(session, instance: instance, openLink: { NSWorkspace.shared.open($0) })
            // Route widget messages through the chat so the turn shows as running and is saved.
            actions.sendMessage = { [weak chat] text in chat?.sendFromWidget(text, instance: instance) }
            return MCPAppViewController(
                resource: resource,
                tools: chat.manager.servers[server]?.tools ?? record.toolDescriptor.map { [$0] } ?? [],
                backend: viewOnly ? OfflineBackend() as any MCPAppsBackend
                    : MCPAppsSessionBackend(session: session, manager: chat.manager, server: server, instance: instance),
                configuration: MCPAppsBridgeConfiguration(
                    hostName: "MCP Chat", hostVersion: "0.1",
                    hostContext: ["displayMode": .string("inline"), "locale": .string(Locale.current.identifier(.bcp47))]),
                bridgePolicy: ChatWidgetPolicy(viewOnly: viewOnly),
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
        guard let session = chat.session, let server = chat.serverID(of: record), case .mcp(_, let tool) = record.tool else { return }
        refreshing = true
        defer { refreshing = false }
        let arguments = MCPAppRecreation.toolInput(from: record.arguments)
        if case .failure(let error) = await session.callMCPTool(server: server, tool: tool, arguments: arguments, initiator: .host) {
            chat.errorMessage = "Refresh failed: \(error)"
        }
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

/// What a widget may ask the host for, on top of the protocol's own rules. Tool calls are allowed
/// here because the session's authorizer asks the user; messages and model context follow Settings.
struct ChatWidgetPolicy: MCPAppsBridgePolicy {
    let viewOnly: Bool

    func authorizeToolCall(name: String, arguments: [String: MCPValue]) async -> MCPAppsDecision {
        viewOnly ? .deny("Offline: this view is view-only") : .allow
    }

    func authorizeOpenLink(_ url: URL) async -> MCPAppsDecision {
        url.scheme?.lowercased() == "https" ? .allow : .deny("Only https links may be opened")
    }

    func authorizeMessage(text: String) async -> MCPAppsDecision {
        ChatSettings.allowWidgetMessages ? .allow : .deny("Widget messages are off in Settings")
    }

    func authorizeModelContextUpdate() async -> MCPAppsDecision {
        ChatSettings.allowWidgetContext ? .allow : .deny("Widget context is off in Settings")
    }
}

/// The backend for a view-only (offline) widget: nothing reaches the server.
struct OfflineBackend: MCPAppsBackend {
    func callTool(name: String, arguments: [String: MCPValue]) async -> Result<MCPToolResult, MCPServerError> { .failure(.notConnected) }
    func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError> { .failure(.notConnected) }
}
