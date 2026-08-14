import AppKit
import LocalLMLabSDKCore
import SwiftUI

// Prebuilt "MCP Servers" screen — add/list/reconnect/disconnect/remove, across all three auth
// types (none, PAT, manual-OAuth). Modeled on LocalLM Lab's own hand-written MCPServersView, but
// with the host-app-specific pieces stripped out: no Go-config persistence (that's a LocalLM
// Lab-specific sync concern, not something every consumer has), no window-chrome assumptions.
// Consumers wanting persistence across launches call `manager.core.restore(from:)` themselves at
// launch with whatever they've saved, the same shape Core's own doc comment on `restore(from:)`
// describes.
@available(macOS 26.0, *)
public struct MCPServerPickerView: View {
    @ObservedObject private var manager: MCPServerManagerObservable

    @State private var newServerURL = ""
    @State private var newServerName = ""
    @State private var newServerAuthType: MCPAuthType = .none
    @State private var newServerPATToken = ""
    @State private var newServerManualClientID = ""
    @State private var addError: String?
    @State private var adding = false
    @State private var busyServerIDs: Set<MCPServerID> = []

    public init(manager: MCPServerManagerObservable) {
        self.manager = manager
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                addServerSection
                if manager.sortedServers.isEmpty {
                    Text("No MCP servers added yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else {
                    Divider()
                    ForEach(manager.sortedServers, id: \.id) { server in
                        serverRow(server)
                        Divider()
                    }
                }
            }
            .padding(24)
        }
        // Waiting-for-browser-sign-in overlay — shown for the duration of an OAuth add attempt,
        // same MCPOAuthWaitingView the consuming app would otherwise have to build itself.
        .overlay {
            if adding && newServerAuthType != .none && !newServerURL.isEmpty {
                Color.black.opacity(0.15)
                MCPOAuthWaitingView(
                    serverName: newServerName.isEmpty ? newServerURL : newServerName,
                    onCancel: { adding = false }
                )
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 20)
            }
        }
    }

    private var addServerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a server").font(.headline)

            HStack {
                TextField("Server URL", text: $newServerURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Display name", text: $newServerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }

            Picker("Auth type", selection: $newServerAuthType) {
                Text("None").tag(MCPAuthType.none)
                Text("Personal Access Token").tag(MCPAuthType.pat)
                Text("OAuth (manual client)").tag(MCPAuthType.oauthManual)
            }
            .pickerStyle(.segmented)
            .frame(width: 420)

            if newServerAuthType == .pat {
                SecureField("Personal access token", text: $newServerPATToken)
                    .textFieldStyle(.roundedBorder)
            }
            if newServerAuthType == .oauthManual {
                TextField("Client ID (from the server's developer console)", text: $newServerManualClientID)
                    .textFieldStyle(.roundedBorder)
            }

            Button(adding ? "Adding…" : "Add") {
                Task { await addServer() }
            }
            .disabled(adding || newServerURL.trimmingCharacters(in: .whitespaces).isEmpty
                || (newServerAuthType == .pat && newServerPATToken.trimmingCharacters(in: .whitespaces).isEmpty)
                || (newServerAuthType == .oauthManual && newServerManualClientID.trimmingCharacters(in: .whitespaces).isEmpty))

            if let addError {
                Text("⚠ \(addError)")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        }
    }

    private func serverRow(_ server: MCPServerState) -> some View {
        let busy = busyServerIDs.contains(server.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusDot(server.connectionStatus)
                Text(server.displayName).bold()
                Text(server.connectionStatus.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if server.connectionStatus != .connected {
                    Button(busy ? "Reconnecting…" : "Reconnect") {
                        Task { await reconnect(server.id) }
                    }
                    .disabled(busy)
                } else {
                    Button("Disconnect") { disconnect(server.id) }
                        .disabled(busy)
                }
                // Exports server.exportSummary() (Core) to a text file via NSSavePanel — the
                // AppKit/file-I/O half lives here since Core deliberately stays UI/host-agnostic;
                // the actual "what's on this server and is it enabled" extraction is Core's, not
                // reinvented here. Modeled directly on LocalLM Lab's own MCPServersView.saveToolListToFile.
                Button("Save As…") { saveSummaryToFile(server) }
                    .disabled(server.tools.isEmpty && server.resources.isEmpty && server.prompts.isEmpty)
                Button("Remove") { removeServer(server.id) }
                    .disabled(busy)
            }
            Text(server.url.absoluteString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            if !server.tools.isEmpty {
                Text("\(server.tools.filter(\.enabled).count) of \(server.tools.count) tools enabled — ~\(server.estimatedTokens) tokens")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ForEach(server.tools, id: \.name) { tool in
                    Toggle(isOn: Binding(
                        get: { tool.enabled },
                        set: { manager.core.setToolEnabled(server: server.id, tool: tool.name, enabled: $0) }
                    )) {
                        Text("\(tool.name) — \(tool.description) (~\(tool.estimatedTokens) tokens)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    // Greyed out while disconnected, same as LocalLM Lab's own MCPServersView —
                    // the toggle still stores and is honored on the next connect (Core carries
                    // enabled-by-name across reconnects), it just doesn't read as "live" right now.
                    .disabled(server.connectionStatus != .connected)
                    .opacity(server.connectionStatus == .connected ? 1 : 0.5)
                }
            }

            if !server.resources.isEmpty {
                Text("Resources").font(.system(size: 12)).bold().foregroundStyle(.secondary)
                ForEach(server.resources, id: \.uri) { resource in
                    Toggle(isOn: Binding(
                        get: { resource.enabled },
                        set: { manager.core.setResourceEnabled(server: server.id, uri: resource.uri, enabled: $0) }
                    )) {
                        Text("\(resource.name) — \(resource.description.isEmpty ? resource.uri : resource.description)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(server.connectionStatus != .connected)
                    .opacity(server.connectionStatus == .connected ? 1 : 0.5)
                }
                Text("Resources are never auto-attached — enabling one only makes it available for a host app to attach explicitly.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !server.prompts.isEmpty {
                Text("Prompts").font(.system(size: 12)).bold().foregroundStyle(.secondary)
                ForEach(server.prompts, id: \.name) { prompt in
                    Text("\(prompt.name) — \(prompt.description)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func saveSummaryToFile(_ server: MCPServerState) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(server.displayName)-mcp-tools.txt"
        panel.title = "Save \(server.displayName) Tool List"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? server.exportSummary().write(to: destination, atomically: true, encoding: .utf8)
    }

    private func statusDot(_ status: MCPConnectionStatus) -> some View {
        Circle()
            .fill(color(for: status))
            .frame(width: 8, height: 8)
    }

    private func color(for status: MCPConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .secondary
        case .failed: return .red
        @unknown default: return .secondary
        }
    }

    private func addServer() async {
        guard let url = URL(string: newServerURL.trimmingCharacters(in: .whitespaces)) else {
            addError = "That doesn't look like a valid URL."
            return
        }
        adding = true
        addError = nil
        defer { adding = false }

        let name = newServerName.trimmingCharacters(in: .whitespaces).isEmpty
            ? url.host ?? url.absoluteString
            : newServerName.trimmingCharacters(in: .whitespaces)

        let result = await manager.core.addServer(
            url: url,
            displayName: name,
            authType: newServerAuthType,
            patToken: newServerAuthType == .pat ? newServerPATToken : nil,
            manualClientID: newServerAuthType == .oauthManual ? newServerManualClientID : nil
        )
        switch result {
        case .failure(let error):
            addError = error.errorDescription
        case .success:
            newServerURL = ""
            newServerName = ""
            newServerPATToken = ""
            newServerManualClientID = ""
            newServerAuthType = .none
        }
    }

    private func reconnect(_ id: MCPServerID) async {
        busyServerIDs.insert(id)
        defer { busyServerIDs.remove(id) }
        _ = await manager.core.reconnect(id)
    }

    private func disconnect(_ id: MCPServerID) {
        manager.core.disconnect(id)
    }

    private func removeServer(_ id: MCPServerID) {
        manager.core.removeServer(id)
    }
}
