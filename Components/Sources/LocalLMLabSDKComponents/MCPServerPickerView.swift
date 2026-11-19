import AppKit
import LocalLMLabSDKCore
import SwiftUI

// Prebuilt "MCP Servers" screen — add/list/reconnect/disconnect/remove, across all three auth
// types (none, PAT, manual-OAuth). Modeled on LocalLM Lab's own hand-written MCPServersView, but
// with the host-app-specific pieces stripped out: no Go-config persistence (that's a LocalLM
// Lab-specific sync concern, not something every consumer has), no window-chrome assumptions.
// Consumers wanting persistence across launches save `manager.core.snapshot()` and call
// `manager.core.restore(from:)` with it at launch: that keeps cached tools, trust, approvals,
// exclusions and pending drift.
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
    /// Dynamic tools: the last "Check connection" result per server, in words, and whether it failed.
    @State private var checks: [MCPServerID: (text: String, failed: Bool)] = [:]
    /// A server at a web address, or a local program speaking MCP over stdio.
    @State private var newServerIsLocal = false
    @State private var newServerCommand = ""
    @State private var newServerSecret = ""
    @State private var newServerNetwork = false
    /// Settings from a pasted configuration's `env`, kept in the Keychain when the server is added.
    @State private var pastedEnvironment: [String: String] = [:]
    /// What a pasted configuration filled in, when it held more than one server.
    @State private var pasteNote: String?
    /// Servers the user opened or closed, by id ("1"/"0"), kept across launches; the rest follow `isOpen`'s default.
    @AppStorage("LocalLMLabSDK.MCPServerPickerView.open") private var openChoices = ""
    private let toolsMode: ToolsMode
    private let allowsLocalPrograms: Bool
    /// `.plain`: everyday words for people who aren't developers (no tool names, prefixes, token counts or export);
    /// `.detailed` (the default): everything. Both chat apps keep the sheet detailed whatever their chat's
    /// switch: whoever opens Tool Sources wants the details; Plain is for the chat stream.
    private let detail: ChatToolDetail

    /// Which of the SDK's two tool systems the app uses.
    public enum ToolsMode: Sendable {
        /// Static tools: a tool is offered when it's ticked and its server is connected.
        case `static`
        /// Dynamic tools (`makeSession(dynamicTools:)`): every tool of every added server can be
        /// picked per message, connected or not. The checkboxes mark a tool available or not
        /// (all available by default), and tools held back by a change are marked.
        case dynamic
    }

    /// `allowsLocalPrograms`: offer "Local program" beside "Web address". Off by default in a sandboxed app
    /// (a Mac App Store build), which can't run one (`ExternalPrograms.isSupported`); a host can turn it off anywhere.
    public init(manager: MCPServerManagerObservable, toolsMode: ToolsMode = .static,
                allowsLocalPrograms: Bool = ExternalPrograms.isSupported, detail: ChatToolDetail = .detailed) {
        self.manager = manager
        self.toolsMode = toolsMode
        self.detail = detail
        self.allowsLocalPrograms = allowsLocalPrograms && ExternalPrograms.isSupported
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

            if allowsLocalPrograms {
                Picker("Server", selection: $newServerIsLocal) {
                    Text("Web address").tag(false)
                    Text("Local program").tag(true)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
            }

            if allowsLocalPrograms && newServerIsLocal {
                localServerFields
            } else {
            HStack {
                TextField("Server URL, or paste its JSON setup", text: $newServerURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Display name", text: $newServerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }

            // Radio group, not a segmented control. A segmented `Picker` with 3 long labels
            // flips between "hug content" and "fill the frame" distribution across layout passes
            // (an empty vs. filled `TextField` reports a different ideal width, and any keystroke
            // re-runs layout), so it visibly resized and its label vanished as you typed in the URL
            // field. A radio group has no width ambiguity and shows all three options at once.
            // Same control as LocalLM Lab's MCP Servers view.
            Picker("Auth type", selection: $newServerAuthType) {
                Text("None").tag(MCPAuthType.none)
                Text("Personal Access Token").tag(MCPAuthType.pat)
                Text("OAuth (manual client)").tag(MCPAuthType.oauthManual)
            }
            .pickerStyle(.radioGroup)
            Text("A server that uses OAuth with dynamic client registration (most hosted servers) needs None: you sign in in your browser when you click Add.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if newServerAuthType == .pat {
                SecureField("Personal access token", text: $newServerPATToken)
                    .textFieldStyle(.roundedBorder)
                Text("The token's own permissions are what the server gets — this app doesn't narrow them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if newServerAuthType == .oauthManual {
                TextField("Client ID (from the server's developer console)", text: $newServerManualClientID)
                    .textFieldStyle(.roundedBorder)
                Text("For servers with no dynamic client registration (e.g. Slack). Create an app in the server's developer console, opt into PKCE if offered, register \(MCPOAuthFlow.redirectURI) as a redirect URL, then paste the Client ID here — no client secret needed. You'll still sign in in your browser when you click Add.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button(adding ? "Adding…" : "Add") {
                Task { await addServer() }
            }
            .disabled(adding || newServerURL.trimmingCharacters(in: .whitespaces).isEmpty
                || (newServerAuthType == .pat && newServerPATToken.trimmingCharacters(in: .whitespaces).isEmpty)
                || (newServerAuthType == .oauthManual && newServerManualClientID.trimmingCharacters(in: .whitespaces).isEmpty))

            }

            if let pasteNote {
                Text(pasteNote).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let addError {
                Text("⚠ \(addError)")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        }
        // A server's JSON setup pasted into either field fills the form.
        .onChange(of: newServerURL) { _, text in if MCPServerConfigPaste.looksLikeConfiguration(text) { applyPaste(text) } }
        .onChange(of: newServerCommand) { _, text in if MCPServerConfigPaste.looksLikeConfiguration(text) { applyPaste(text) } }
    }

    /// Fills the form from a pasted configuration: its first server, with a note when there are more. A launch the
    /// app would refuse (an unpinned npx, a local program where none can run) says why now, not after Add.
    private func applyPaste(_ text: String) {
        addError = nil
        pasteNote = nil
        newServerURL = ""
        newServerCommand = ""
        pastedEnvironment = [:]
        let entries: [MCPServerConfigEntry]
        do { entries = try MCPServerConfigPaste.parse(text) } catch {
            addError = error.localizedDescription
            return
        }
        let entry = entries[0]
        newServerName = entry.name
        if entries.count > 1 {
            let others = entries.dropFirst().map { "\u{201C}\($0.name)\u{201D}" }.joined(separator: ", ")
            pasteNote = "Filled in \u{201C}\(entry.name)\u{201D}. What you pasted also has \(others): add them one at a time."
        }
        switch entry.kind {
        case .web(let url, let token):
            newServerIsLocal = false
            newServerURL = url.absoluteString
            if let token {
                newServerAuthType = .pat
                newServerPATToken = token
            }
        case .local(let command, let arguments, let environment):
            guard allowsLocalPrograms else {
                let what = "\u{201C}\(entry.name.isEmpty ? command : entry.name)\u{201D} is a program to run on this Mac (\(entry.commandLine ?? command))."
                addError = ExternalPrograms.isSupported ? "\(what) This app doesn't add local programs." : "\(what) \(ExternalPrograms.unsupportedMCPNote)"
                return
            }
            newServerIsLocal = true
            newServerCommand = entry.commandLine ?? command
            pastedEnvironment = environment
            if let refusal = MCPStdioLaunch(executable: command, arguments: arguments).installerRefusal
                ?? MCPStdioLaunch.environmentRefusal(names: Array(environment.keys)) { addError = refusal }
        @unknown default:
            addError = "This app can't add that kind of server."
        }
    }

    private func serverRow(_ server: MCPServerState) -> some View {
        let busy = busyServerIDs.contains(server.id)
        let open = isOpen(server)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Collapsed: everything down to the trust controls, with a one-line count of the rest.
                Button { setOpen(!open, server.id) } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 12)
                }
                .buttonStyle(.borderless)
                .disabled(server.pendingDrift != nil)
                .help(server.pendingDrift != nil ? "Open while a change waits for you"
                      : open ? "Hide this server's tools, content and prompts" : "Show this server's tools, content and prompts")
                statusDot(server.connectionStatus)
                Text(server.displayName).bold()
                Text(ConnectionWording.status(server.connectionStatus, toolsMode: toolsMode))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if toolsMode == .dynamic {
                    // Servers connect when a message needs them; connecting here tests the address, signs in again
                    // if needed and refreshes the lists. Nothing to disconnect: an idle server costs nothing.
                    Button(busy ? "Checking…" : "Check connection") {
                        Task { await check(server.id) }
                    }
                    .disabled(busy)
                } else if server.connectionStatus != .connected {
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
                if detail == .detailed {
                    Button("Save As…") { saveSummaryToFile(server) }
                        .disabled(server.tools.isEmpty && server.resources.isEmpty && server.prompts.isEmpty)
                }
                Button("Remove") { removeServer(server.id) }
                    .disabled(busy)
            }
            if let stdio = server.stdio {
                Text("Local program: \(stdio.displayLine) · network \(stdio.network == .none ? "off" : stdio.network.rawValue)"
                     + (stdio.environmentNames.isEmpty ? "" : " · sets \(stdio.environmentNames.joined(separator: ", "))"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(server.url.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let check = checks[server.id] {
                Text(check.text)
                    .font(.system(size: 12))
                    .foregroundStyle(check.failed ? .red : .green)
            }
            if detail == .detailed { ToolPrefixField(server: server, manager: manager.core) }

            trustControls(server)

            if !open {
                Text(ServerSummary.line(server, toolsMode: toolsMode))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
            if !server.tools.isEmpty {
                switch toolsMode {
                case .static: staticToolList(server)
                case .dynamic: dynamicToolList(server)
                }
            }

            if toolsMode == .dynamic {
                dynamicContentList(server)
            } else if !server.resources.isEmpty {
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
                // Prompts are the user's to pick: listed, nothing to switch on.
                VStack(alignment: .leading, spacing: 6) {
                    // "Prompts", not "Commands": ChatAgain's Commands tab is its shell commands.
                    Text("Prompts").font(.system(size: 13, weight: .semibold))
                    Text("Ready-made requests from this source. Type / in the message box, or use the paperclip menu, to use one.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(server.prompts, id: \.name) { prompt in
                        let name = detail == .detailed || prompt.title == nil ? prompt.title.map { "\($0) (\(prompt.name))" } ?? prompt.name
                            : prompt.title!
                        Text(prompt.description.isEmpty ? name : "\(name) — \(prompt.description)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 4)
            }
            }
        }
    }

    /// Open unless the user closed it; by default open when it's the only server, closed among several. A pending change
    /// keeps it open: the drift card asks for a decision.
    private func isOpen(_ server: MCPServerState) -> Bool {
        if server.pendingDrift != nil { return true }
        if let choice = ServerSummary.choices(openChoices)[server.id.rawValue] { return choice }
        return manager.sortedServers.count <= 1
    }

    private func setOpen(_ open: Bool, _ id: MCPServerID) {
        var choices = ServerSummary.choices(openChoices)
        choices[id.rawValue] = open
        openChoices = ServerSummary.encode(choices)
    }

    /// Dynamic tools: content the server shares, which the assistant can read when a question needs it.
    /// Checked unless the user unchecks it, like a tool; MCP Apps views aren't listed.
    @ViewBuilder private func dynamicContentList(_ server: MCPServerState) -> some View {
        let shared = server.resources.filter { !$0.isMCPAppResource }
        if !shared.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Content").font(.system(size: 13, weight: .semibold))
                Text("The assistant can read checked content when a question needs it. Uncheck to keep it from reading something.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(shared, id: \.uri) { resource in
                    Toggle(isOn: Binding(
                        get: { !server.excludedResources.contains(resource.uri) },
                        set: { manager.core.setResourceExcluded(!$0, server: server.id, uri: resource.uri) }
                    )) {
                        Text("\(resource.title ?? resource.name) — \(resource.description.isEmpty ? resource.uri : resource.description)"
                             + (detail == .detailed && !resource.description.isEmpty ? " (\(resource.uri))" : ""))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
    }

    private func staticToolList(_ server: MCPServerState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(server.tools.filter(\.enabled).count) of \(server.tools.count) tools enabled — ~\(server.estimatedTokens) tokens")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ForEach(server.tools, id: \.name) { tool in
                Toggle(isOn: Binding(
                    get: { tool.enabled },
                    set: { manager.core.setToolEnabled($0, server: server.id, tool: tool.name) }
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
    }

    /// Dynamic tools: nothing to switch on. A tool can be picked for any message unless the user
    /// opts it out here, or a change to it is waiting for review. Works while disconnected: the
    /// server is connected for the turns that pick its tools.
    private func dynamicToolList(_ server: MCPServerState) -> some View {
        let visible = server.tools.filter(\.isModelVisible)
        let available = visible.filter { !server.excludedTools.contains($0.name) && !server.heldTools.contains($0.name) }
        return VStack(alignment: .leading, spacing: 6) {
            // In primary, apart from the list: someone used to ticking tools one by one (static
            // tools, e.g. Playground) needs to see that here there's nothing to turn on.
            VStack(alignment: .leading, spacing: 2) {
                Text("Tools: \(available.count) of \(visible.count) available").font(.system(size: 13, weight: .semibold))
                Text(detail == .plain
                     ? "You don't need to turn tools on: for each message, the assistant gets only the ones it needs. Uncheck a tool to never use it."
                     : "You don't need to turn tools on. For each message, only the tools it needs are selected and given to the model. Uncheck a tool to disable it.")
                    .font(.system(size: 12))
                if detail == .detailed {
                    Text("All \(available.count) together would take about \(available.map(\.estimatedTokens).reduce(0, +)) tokens; a message usually gets only a few.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
            ForEach(visible, id: \.name) { tool in
                let held = server.heldTools.contains(tool.name)
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { !server.excludedTools.contains(tool.name) },
                        set: { manager.core.setToolExcluded(!$0, server: server.id, tool: tool.name) }
                    )) {
                        Text(detail == .plain
                             ? "\(tool.title ?? readableToolName(tool.name).capitalizedFirst) — \(tool.description)"
                             : "\(tool.name) — \(tool.description) (~\(tool.estimatedTokens) tokens)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Available: can be chosen for a message")
                    if held {
                        Text(detail == .plain ? "Changed: check it before it's used" : "Held: changed, waiting for review")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: trust and approval

    /// The approvals offered here. An approval decided by the app's policy (`by: .policy`) is the
    /// app's setting, shown but not offered.
    /// What trusting would mean under the trusted default (ask only before deletes): " Trusting it,
    /// 9 tools would run without asking, including 2 it says nothing about; 1 that can delete would
    /// still ask."
    private func trustUnlocks(_ server: MCPServerState) -> String {
        guard !server.tools.isEmpty else { return "" }
        let deletes = server.tools.filter { ($0.annotations.map { !$0.isReadOnly && $0.isDestructive }) ?? false }.count
        let unlabelled = server.tools.filter { $0.annotations == nil }.count
        let free = server.tools.count - deletes
        var text = " Trusting it, \(free) tool\(free == 1 ? "" : "s") would run without asking"
        if unlabelled > 0 { text += ", including \(unlabelled) it says nothing about" }
        text += deletes > 0 ? "; \(deletes) that can delete would still ask." : "; none says it can delete, so none would ask."
        return text
    }

    private enum ApprovalChoice: Hashable {
        case automatic, allow, askChanges, askDeletions, askEverything, appPolicy

        init(_ approval: ToolApproval?) {
            switch approval {
            case nil: self = .automatic
            case .allow?: self = .allow
            case .ask(_, .policy)?: self = .appPolicy
            case .ask(.read, .user)?: self = .askEverything
            case .ask(.mutate, .user)?: self = .askChanges
            case .ask(.destructive, .user)?: self = .askDeletions
            case .ask?: self = .askChanges
            @unknown default: self = .askChanges
            }
        }

        var approval: ToolApproval? {
            switch self {
            case .automatic: nil
            case .allow: .allow
            case .askChanges: .ask(atOrAbove: .mutate, by: .user)
            case .askDeletions: .ask(atOrAbove: .destructive, by: .user)
            case .askEverything: .ask(atOrAbove: .read, by: .user)
            case .appPolicy: nil
            }
        }
    }

    @ViewBuilder
    private func trustControls(_ server: MCPServerState) -> some View {
        let id = server.id
        HStack(spacing: 16) {
            Picker("Trust", selection: Binding(
                get: { server.trust },
                set: { manager.core.setTrust($0, server: id) }
            )) {
                Text("Untrusted").tag(MCPServerTrust.untrusted)
                Text("Trusted").tag(MCPServerTrust.trusted)
            }
            .fixedSize()
            Picker("Before a tool runs", selection: Binding(
                get: { ApprovalChoice(server.toolApproval) },
                set: { manager.core.setToolApproval($0.approval, server: id) }
            )) {
                Text(server.trust == .trusted ? "Default: ask only before deleting" : "Default: always ask")
                    .tag(ApprovalChoice.automatic)
                Text("Always ask").tag(ApprovalChoice.askChanges)
                // An untrusted server's labels are ignored, so none of its calls counts as a delete:
                // "only before deleting" would never ask. Offered once it's trusted.
                if server.trust == .trusted || ApprovalChoice(server.toolApproval) == .askDeletions {
                    Text("Ask only before deleting").tag(ApprovalChoice.askDeletions)
                }
                Text("Don't ask").tag(ApprovalChoice.allow)
                Text("Ask before every call, reads too").tag(ApprovalChoice.askEverything)
                if ApprovalChoice(server.toolApproval) == .appPolicy {
                    Text("Decided by the app's policy").tag(ApprovalChoice.appPolicy)
                }
            }
            .fixedSize()
            .disabled(ApprovalChoice(server.toolApproval) == .appPolicy)
        }
        .controlSize(.small)
        Text(server.trust == .trusted
             ? "Trusted: the server's own labels decide which tools only read and which delete. Trust only servers you know — an official one, or one you've tested; a server can label anything."
             : "Untrusted: the server's labels are ignored, so every tool counts as one that may change data." + trustUnlocks(server))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        if server.trust != .trusted, ApprovalChoice(server.toolApproval) == .askDeletions {
            Text("\"Ask only before deleting\" never asks for an untrusted server: none of its calls can be recognised as a delete. Trust it, or choose Always ask.")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }

        // Drift, in both modes: what changed since the user last accepted the tools.
        // Accepting is the confirmation; it replaces the old "changed since you trusted it" banner.
        if let drift = server.pendingDrift {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(DriftWording.summary(drift))
                    Button("Accept") { manager.core.acceptDrift(server: id) }
                }
                ForEach(Array(drift.changes.enumerated()), id: \.offset) { _, change in
                    Text("• \(DriftWording.line(change, among: drift))").foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .font(.system(size: 12))
        }
        if toolsMode == .static, server.connectionStatus == .connected, !server.tools.isEmpty,
           !server.tools.contains(where: { $0.enabled && $0.isModelVisible }) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text("None of this server's tools are on, so a model can't use it yet. Turn on the ones you want below.")
            }
            .font(.system(size: 12))
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

    /// The fields for a local program: its command line, a secret it needs, and network access.
    private var localServerFields: some View {
        let allowed = manager.core.externalPrograms?.allowsRunning == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Command, e.g. npx -y @modelcontextprotocol/server-filesystem@1.0.0 ~/Notes", text: $newServerCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                TextField("Display name", text: $newServerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            SecureField("Secret it needs, as NAME=value (optional; kept in the Keychain)", text: $newServerSecret)
                .textFieldStyle(.roundedBorder)
            Toggle("Allow network (many servers need it, e.g. to download themselves or call an online service)", isOn: $newServerNetwork)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            // Not beside the refusal of a name that changes what runs: "kept" read as accepted (2026-11-01).
            if !pastedEnvironment.isEmpty, MCPStdioLaunch.environmentRefusal(names: Array(pastedEnvironment.keys)) == nil {
                Text("From what you pasted: \(pastedEnvironment.keys.sorted().joined(separator: ", ")), kept in the Keychain.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(allowed
                 ? "Paste a server's JSON setup (\"mcpServers\") to fill this in. The program runs in a sandbox: it writes only in its own folder and temporary files, can't read the rest of your home folder, and has no network unless allowed. npx and uvx need a pinned version (package@1.2.3)."
                 : "Turn on External programs in Settings to add a local server.")
                .font(.system(size: 12))
                .foregroundStyle(allowed ? Color.secondary : Color.orange)
            Button(adding ? "Adding…" : "Add") { Task { await addLocalServer() } }
                .disabled(adding || !allowed || newServerCommand.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addLocalServer() async {
        let words = Self.splitCommand(newServerCommand)
        guard let program = words.first else { return }
        adding = true
        addError = nil
        defer { adding = false }
        var secrets = pastedEnvironment
        let secret = newServerSecret.trimmingCharacters(in: .whitespaces)
        if let equals = secret.firstIndex(of: "="), equals != secret.startIndex {
            secrets[String(secret[..<equals])] = String(secret[secret.index(after: equals)...])
        }
        let launch = MCPStdioLaunch(executable: program, arguments: Array(words.dropFirst()), network: newServerNetwork ? .any : .none)
        let typedName = newServerName.trimmingCharacters(in: .whitespaces)
        let name = typedName.isEmpty ? (words.dropFirst().last { !$0.hasPrefix("-") && !$0.hasPrefix("/") } ?? program) : typedName
        switch await manager.core.addStdioServer(launch, displayName: name, secrets: secrets) {
        case .failure(let error):
            addError = error.errorDescription
        case .success:
            newServerCommand = ""
            newServerName = ""
            newServerSecret = ""
            newServerNetwork = false
            pastedEnvironment = [:]
            pasteNote = nil
        }
    }

    /// Splits a command line on spaces, keeping quoted parts together and expanding a leading `~`.
    public static func splitCommand(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character == " " {
                if started || !current.isEmpty { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
            }
        }
        if started || !current.isEmpty { words.append(current) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return words.map { $0 == "~" ? home : ($0.hasPrefix("~/") ? home + $0.dropFirst() : $0) }
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

    private func check(_ id: MCPServerID) async {
        busyServerIDs.insert(id)
        defer { busyServerIDs.remove(id) }
        checks[id] = nil
        switch await manager.core.reconnect(id) {
        case .success(let server): checks[id] = (ConnectionWording.connected(server), false)
        case .failure(let error): checks[id] = ("Couldn't connect: \(error.localizedDescription)", true)
        }
    }

    private func disconnect(_ id: MCPServerID) {
        manager.core.disconnect(id)
    }

    private func removeServer(_ id: MCPServerID) {
        manager.core.removeServer(id)
    }
}

/// The server's tool-name prefix: what the model sees before each of its tools'
/// names (`github_list_issues`). Applied on Return; a prefix another server has is refused.
private struct ToolPrefixField: View {
    let server: MCPServerState
    let manager: MCPServerManager
    @State private var draft: String?
    @State private var refused = false

    var body: some View {
        let current = server.toolPrefix ?? ""
        HStack(spacing: 6) {
            Text("Tool prefix").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("prefix", text: Binding(get: { draft ?? current }, set: { draft = $0; refused = false }))
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit {
                    guard let draft, draft != current else { return }
                    refused = manager.setToolPrefix(draft, server: server.id) == nil
                    if !refused { self.draft = nil }
                }
            if refused {
                Text("Already used by another server, or empty")
                    .font(.system(size: 11)).foregroundStyle(.red)
            } else if let example = server.tools.first?.name, !current.isEmpty {
                Text("The model sees \(current)_\(example)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The connection's words. With dynamic tools a server connects when a message needs it, so not being connected is
/// the resting state, not a problem.
enum ConnectionWording {
    static func status(_ status: MCPConnectionStatus, toolsMode: MCPServerPickerView.ToolsMode) -> String {
        guard toolsMode == .dynamic else { return status.rawValue }
        switch status {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .failed: return "couldn't connect"
        case .disconnected: return "connects when needed"
        @unknown default: return status.rawValue
        }
    }

    /// "Connected: 15 tools, 7 content items, 4 prompts".
    static func connected(_ server: MCPServerState) -> String {
        let tools = server.tools.filter(\.isModelVisible).count
        var parts = [tools == 1 ? "1 tool" : "\(tools) tools"]
        let content = server.resources.filter { !$0.isMCPAppResource }.count
        if content > 0 { parts.append(content == 1 ? "1 content item" : "\(content) content items") }
        if !server.prompts.isEmpty { parts.append(server.prompts.count == 1 ? "1 prompt" : "\(server.prompts.count) prompts") }
        return "Connected: " + parts.joined(separator: ", ")
    }
}

/// A collapsed server's one line, and the stored open/closed choices.
enum ServerSummary {
    /// "3 of 4 tools available · 10 content items · 2 prompts"; parts with nothing are left out.
    static func line(_ server: MCPServerState, toolsMode: MCPServerPickerView.ToolsMode) -> String {
        var parts: [String] = []
        switch toolsMode {
        case .dynamic:
            let visible = server.tools.filter(\.isModelVisible)
            let available = visible.filter { !server.excludedTools.contains($0.name) && !server.heldTools.contains($0.name) }
            if !visible.isEmpty { parts.append("\(available.count) of \(visible.count) tools available") }
        case .static:
            if !server.tools.isEmpty { parts.append("\(server.tools.filter(\.enabled).count) of \(server.tools.count) tools enabled") }
        }
        let content = server.resources.filter { !$0.isMCPAppResource }.count
        if content > 0 { parts.append(content == 1 ? "1 content item" : "\(content) content items") }
        if !server.prompts.isEmpty { parts.append(server.prompts.count == 1 ? "1 prompt" : "\(server.prompts.count) prompts") }
        return parts.isEmpty ? "No tools, content or prompts yet" : parts.joined(separator: " · ")
    }

    static func choices(_ stored: String) -> [String: Bool] {
        (try? JSONDecoder().decode([String: Bool].self, from: Data(stored.utf8))) ?? [:]
    }

    static func encode(_ choices: [String: Bool]) -> String {
        (try? JSONEncoder().encode(choices)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// The drift card's words, by what the pending changes do (`ToolChange.action`): a held tool isn't used until accepted;
/// one kept at its accepted rating (`acceptPendingReview`, a label that got safer) still works and asks as before.
enum DriftWording {
    static func summary(_ drift: ToolDrift) -> String {
        if drift.blocksServer {
            return "This server's tools changed. The server stays disconnected until you accept the change."
        }
        if drift.changes.contains(where: \.isHeld) {
            return "This server's tools changed. Changed tools aren't used until you accept the change."
        }
        return "This server's tools changed. They still work, and you're asked before them as you were, until you accept the change."
    }

    /// A change's line; when the card mixes held tools with ones still in use, those in use say so.
    static func line(_ change: ToolChange, among drift: ToolDrift) -> String {
        guard change.action == .acceptPendingReview, drift.changes.contains(where: \.isHeld) || drift.blocksServer else {
            return change.detail
        }
        return change.detail + " (still in use, asked about as before)"
    }
}

private extension ToolChange {
    /// The change keeps its tool out of use until accepted.
    var isHeld: Bool { action >= .disableUntilApproved }
}

private extension String {
    /// "list issues" → "List issues".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
