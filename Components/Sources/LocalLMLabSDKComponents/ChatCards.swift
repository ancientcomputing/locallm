import AppKit
import LocalLMLabSDKCore
import SwiftUI
import UniformTypeIdentifiers

// The inline cards of a chat with dynamic tools: a turn that can't start
// until the user acts ends with one of these instead of an answer. Their text is fixed here; nothing
// the model wrote appears in them. Each card takes what it shows and what its buttons do, so any app
// can drive them; put one inside `ChatCardFrame`. From ChatAgain.

/// The frame every card sits in: a rounded panel, dimmed and disabled once the card is dealt with.
public struct ChatCardFrame<Content: View>: View {
    let resolved: Bool
    let content: Content

    public init(resolved: Bool = false, @ViewBuilder content: () -> Content) {
        self.resolved = resolved
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .opacity(resolved ? 0.55 : 1)
        .disabled(resolved)
        .accessibilityElement(children: .contain)
    }
}

private func cardHeader(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage).font(.headline)
}

/// "list_issues" / "getFileContents" → "list issues" / "get file contents".
public func readableToolName(_ toolName: String) -> String {
    var out = ""
    var previous: Character?
    for character in toolName {
        if character == "_" { out.append(" ") }
        else if character.isUppercase, let previous, previous.isLowercase { out.append(" "); out.append(Character(character.lowercased())) }
        else { out.append(character) }
        previous = character
    }
    return out
}

private func firstSentence(_ text: String) -> String {
    (text.split(separator: ".", maxSplits: 1).first.map(String.init) ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Gate cards (ToolGate)

/// `ToolGate.needsClarification`: which of these tools was meant.
public struct ClarifyCardView: View {
    let options: [SelectableTool]
    let sourceName: (SelectableTool) -> String
    let choose: (SelectableTool) -> Void

    /// `sourceName`: the source shown before each tool ("GitHub", "Calendar").
    public init(options: [SelectableTool], sourceName: @escaping (SelectableTool) -> String,
                choose: @escaping (SelectableTool) -> Void) {
        self.options = options
        self.sourceName = sourceName
        self.choose = choose
    }

    public var body: some View {
        cardHeader("Which one do you mean?", systemImage: "questionmark.bubble")
        ForEach(options, id: \.ref) { option in
            Button { choose(option) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(sourceName(option)) › \(readableToolName(option.ref.name))")  // the server's own name, without the prefix
                    Text(firstSentence(option.description)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
        Text("Or type your answer below.").font(.caption).foregroundStyle(.secondary)
    }
}

/// `ToolGate.needsAuthorization`: a server needs the user to sign in.
public struct SignInCardView: View {
    let name: String
    let domain: String
    let signIn: () -> Void
    let dismiss: () -> Void

    /// `domain`: where the sign-in page is (the server's own), shown so the user knows whose page it is.
    public init(name: String, domain: String, signIn: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.name = name
        self.domain = domain
        self.signIn = signIn
        self.dismiss = dismiss
    }

    public var body: some View {
        cardHeader("Connect \(name) to continue", systemImage: "person.badge.key")
        Text("\(name) needs you to sign in. The sign-in page is \(domain)'s own; your request runs as soon as you're signed in.")
            .font(.callout).foregroundStyle(.secondary)
        HStack {
            Button("Sign In to \(name)", action: signIn).buttonStyle(.borderedProminent)
            Button("Not Now", action: dismiss)
        }
    }
}

/// `ToolGate.needsPermission`: a plug-in needs a macOS permission (calendar, contacts, …).
public struct PermissionCardView: View {
    let name: String
    let missing: Set<PluginPermission>
    let granted: Bool?
    let problem: PermissionProblem?
    let allow: () -> Void
    let openSettings: (() -> Void)?
    let dismiss: () -> Void

    /// `granted`: nil while the card waits for the user; once it's dealt with, whether macOS granted the access
    /// (`ChatController.isGranted(_:)`). A done card says so instead of keeping its buttons. `problem`: why the last
    /// Allow didn't give the access (`ChatCard.problem`); the card then offers Try Again (`allow`) and
    /// `openSettings`.
    public init(name: String, missing: Set<PluginPermission>, granted: Bool? = nil, problem: PermissionProblem? = nil,
                allow: @escaping () -> Void, openSettings: (() -> Void)? = nil, dismiss: @escaping () -> Void) {
        self.name = name
        self.missing = missing
        self.granted = granted
        self.problem = problem
        self.allow = allow
        self.openSettings = openSettings
        self.dismiss = dismiss
    }

    public var body: some View {
        switch granted {
        case true?:
            cardHeader("\(name) access allowed", systemImage: "checkmark.shield")
        case false?:
            cardHeader("\(name) not allowed", systemImage: "lock.shield")
            Text("Your message was sent without \(name).").font(.callout).foregroundStyle(.secondary)
        case nil:
            if let problem {
                cardHeader("\(name) not allowed", systemImage: "lock.shield")
                Text(problem.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if problem.offersTryAgain { Button("Try Again", action: allow).buttonStyle(.borderedProminent) }
                    if problem.offersSystemSettings, let openSettings { Button("Open System Settings", action: openSettings) }
                    Button("Not Now", action: dismiss)
                }
            } else {
                cardHeader("Allow access to \(name)", systemImage: "lock.shield")
                Text("This needs access to your \(missing.map(\.rawValue).sorted().joined(separator: " and ")). macOS asks you next; your request runs once it's allowed.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Allow Access…", action: allow).buttonStyle(.borderedProminent)
                    Button("Not Now", action: dismiss)
                }
            }
        }
    }
}

/// `ToolGate.needsReview`: a server's tools changed since the user last accepted them.
public struct ToolChangesCardView: View {
    let name: String
    let drift: ToolDrift
    let review: (_ accept: Bool) -> Void

    public init(name: String, drift: ToolDrift, review: @escaping (_ accept: Bool) -> Void) {
        self.name = name
        self.drift = drift
        self.review = review
    }

    public var body: some View {
        cardHeader("\(name) changed \(drift.changes.count) tool\(drift.changes.count == 1 ? "" : "s"): review", systemImage: "exclamationmark.shield")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(drift.changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(change.kind.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(change.tool.map { "\($0): " } ?? "").font(.caption.monospaced())
                        + Text(change.detail).font(.caption)
                }
            }
        }
        Text("Accept to keep using \(name) with these changes. Reject turns it off until you review it in Tool Sources.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Accept Changes") { review(true) }.buttonStyle(.borderedProminent)
            Button("Reject", role: .destructive) { review(false) }
        }
    }
}

// MARK: - Cards before a turn (ComposerIntent)

/// What the user entered in `AddToolSourceCardView`. `token` is set only for `.pat`.
public struct NewToolSource: Sendable {
    public var url: URL
    public var name: String
    public var authType: MCPAuthType
    public var token: String?
    public var trusted: Bool
}

/// The add-tool widget: URL, name, and how it signs in. A token goes only in here,
/// then to `add`, which hands it to the SDK and the Keychain; never to the transcript or the model.
public struct AddToolSourceCardView: View {
    let add: (NewToolSource) async -> Void
    let invalidURL: () -> Void
    let cancel: () -> Void
    let sendAsMessage: (() -> Void)?
    @State private var url: String
    @State private var name: String
    @State private var auth: Auth = .automatic
    @State private var token = ""
    @State private var trusted = false
    @State private var adding = false

    enum Auth: String, CaseIterable, Identifiable {
        case automatic = "Sign in if it asks (OAuth)"
        case token = "Access token"
        var id: String { rawValue }
    }

    /// `url` and `name` prefill the form (from a message such as "add https://…/mcp as Brevo").
    /// `invalidURL` runs when Add is pressed with something that isn't an http(s) URL. `sendAsMessage`, for a card made
    /// from a message, sends that message to the model instead (`ChatController.sendAsMessage`).
    public init(url: String = "", name: String = "", add: @escaping (NewToolSource) async -> Void,
                invalidURL: @escaping () -> Void, cancel: @escaping () -> Void, sendAsMessage: (() -> Void)? = nil) {
        _url = State(initialValue: url)
        _name = State(initialValue: name)
        self.add = add
        self.invalidURL = invalidURL
        self.cancel = cancel
        self.sendAsMessage = sendAsMessage
    }

    public var body: some View {
        Label("Add a tool source", systemImage: "plus.app").font(.headline)
        Form {
            TextField("Server URL", text: $url, prompt: Text("https://example.com/mcp"))
            TextField("Name", text: $name, prompt: Text("Brevo"))
            Picker("Sign-in", selection: $auth) {
                ForEach(Auth.allCases) { Text($0.rawValue).tag($0) }
            }
            if auth == .token {
                SecureField("Token", text: $token)
            }
            Toggle("Trusted", isOn: $trusted)
        }
        .formStyle(.columns)
        Text(trusted
             ? "Trusted: you know where this server comes from (an official one, or one you've tested), so its own labels count — tools it says only read run without asking."
             : "Untrusted until you say otherwise: every tool call asks first, since its labels aren't verified. You can allow single tools, or trust it later.")
            .font(.caption).foregroundStyle(.secondary)
        Text("Adding it lists its tools and disconnects; it connects again only for the turns that need it.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button(adding ? "Adding…" : "Add") {
                guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), parsed.scheme?.hasPrefix("http") == true else {
                    invalidURL()
                    return
                }
                adding = true
                Task {
                    await add(NewToolSource(url: parsed, name: name.isEmpty ? (parsed.host() ?? "Server") : name,
                                            authType: auth == .token ? .pat : .none, token: auth == .token ? token : nil,
                                            trusted: trusted))
                    token = ""
                    adding = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(adding || url.isEmpty || (auth == .token && token.isEmpty))
            Button("Cancel", action: cancel)
            if let sendAsMessage {
                Spacer()
                Button("Send as a Message", action: sendAsMessage)
                    .help("Not a server to add: send your message to the assistant as you wrote it")
            }
        }
    }
}

/// "Use ~/Code/project as a workspace?" with its access level.
public struct AddWorkspaceCardView: View {
    let path: String
    let add: (Workspace.Access) -> Void
    let dismiss: () -> Void
    let sendAsMessage: (() -> Void)?
    @State private var access: Workspace.Access = .askBeforeChanges

    /// `path`: the folder as the user should read it (`~/Code/project`). `add` gets the access level
    /// chosen; it typically opens a folder picker there, since a sandboxed app needs the user's pick.
    public init(path: String, add: @escaping (Workspace.Access) -> Void, dismiss: @escaping () -> Void,
                sendAsMessage: (() -> Void)? = nil) {
        self.path = path
        self.add = add
        self.dismiss = dismiss
        self.sendAsMessage = sendAsMessage
    }

    public var body: some View {
        Label("Add a workspace", systemImage: "folder.badge.plus").font(.headline)
        Text("Let the assistant use \(path) in every chat? It can search and read it; secrets such as .env files and keys are never read.")
            .font(.callout).foregroundStyle(.secondary)
        HStack {
            WorkspaceAccessPicker(access: $access)
                .fixedSize()
            Spacer()
            if let sendAsMessage {
                Button("Send as a Message", action: sendAsMessage)
                    .help("Send your message to the assistant as you wrote it, without adding the folder")
            }
            Button("Not Now", action: dismiss)
            Button("Add…") { add(access) }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// A message that looked like an API key: it was kept from the model and the transcript.
public struct PastedKeyCardView: View {
    let sendWithoutIt: () -> Void
    let addToolSource: () -> Void
    let cancel: () -> Void

    public init(sendWithoutIt: @escaping () -> Void, addToolSource: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.sendWithoutIt = sendWithoutIt
        self.addToolSource = addToolSource
        self.cancel = cancel
    }

    public var body: some View {
        cardHeader("That looks like an API key", systemImage: "key")
        Text("It wasn't sent to the model or saved. To use it, add the service it belongs to as a tool source and paste it there; it's stored in your Keychain.")
            .font(.callout).foregroundStyle(.secondary)
        HStack {
            Button("Send Without It", action: sendWithoutIt)
            Button("Add Tool Source…", action: addToolSource)
            Button("Cancel", action: cancel)
        }
    }
}

// MARK: - One-line cards

/// Something done, said inline ("Brevo added: 12 tools").
public struct ChatNoticeView: View {
    let text: String
    let dismiss: () -> Void

    public init(_ text: String, dismiss: @escaping () -> Void) {
        self.text = text
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
            Text(text).font(.callout)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
        }
    }
}

/// Something that went wrong in a turn, said inline instead of in a modal.
public struct ChatWarningView: View {
    let text: String
    let dismiss: () -> Void

    public init(_ text: String, dismiss: @escaping () -> Void) {
        self.text = text
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
        }
    }
}

/// The model stopped without answering (`EmptyReply`): its note, and Retry when the turn can run again.
public struct EmptyReplyCardView: View {
    let text: String
    let retry: (() -> Void)?
    let dismiss: () -> Void

    /// `retry`: nil hides the button (a tool ran in the turn, or a later turn followed).
    public init(_ text: String, retry: (() -> Void)?, dismiss: @escaping () -> Void) {
        self.text = text
        self.retry = retry
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            if let retry { Button("Retry", action: retry).buttonStyle(.bordered) }
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
        }
    }
}

/// After a reply: a server held back that fits the message ("GitHub could help with this").
/// `ToolSelectionExplanation.suggested`.
public struct ServerSuggestionView: View {
    let name: String
    let checking: Bool
    let check: () -> Void
    let dismiss: () -> Void

    /// `checking`: the user tapped Check and the follow-up is running.
    public init(name: String, checking: Bool, check: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.name = name
        self.checking = checking
        self.check = check
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            Text("\(name) could help with this.").font(.callout)
            Spacer()
            if checking {
                Text("Checking \(name)").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Check \(name)", action: check).buttonStyle(.bordered)
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
        }
    }
}

// MARK: - Files

/// A file a tool wrote: Open, Save As…, and for a CSV a preview of its first rows (shown from the
/// file, not from anything the model copied).
public struct FileCardView: View {
    let url: URL
    @State private var preview: [[String]]?

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.callout.weight(.medium))
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Save As…") { saveAs() }
            }
            if let preview, let header = preview.first {
                MarkdownTableBlock(header: header, rows: Array(preview.dropFirst()))
            }
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .task { if url.pathExtension.lowercased() == "csv" { preview = Self.csvPreview(url) } }
    }

    private var size: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        if let type = UTType(filenameExtension: url.pathExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: url, to: target)
    }

    /// Up to 20 rows after the header, quoted fields handled. Lines end in `\n` or `\r\n` (Swift
    /// reads `\r\n` as one character, so splitting on `\n` alone missed every Windows line end).
    static func csvPreview(_ url: URL) -> [[String]]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var rows: [[String]] = []
        for line in text.split(whereSeparator: \.isNewline).prefix(21) {
            var cells: [String] = []
            var cell = ""
            var quoted = false
            for character in line {
                if character == "\"" { quoted.toggle() }
                else if character == ",", !quoted { cells.append(cell); cell = "" }
                else { cell.append(character) }
            }
            cells.append(cell)
            rows.append(cells)
        }
        return rows.isEmpty ? nil : rows
    }
}

// MARK: - A ChatController's cards

/// Any `ChatCard` of `controller`, drawn with the views above and wired to the controller's card
/// actions. The app supplies what needs it: adding a workspace (a folder picker, since
/// a sandboxed app needs the user's pick) and its own `.custom` cards.
public struct ChatCardView<Custom: View>: View {
    let card: ChatCard
    let controller: ChatController
    let addWorkspace: (ChatCard, _ path: String, Workspace.Access) -> Void
    let custom: (ChatCard) -> Custom

    /// `addWorkspace`: open a folder picker at `path`, save the pick, then `controller.complete(card, notice:)`.
    public init(card: ChatCard, controller: ChatController,
                addWorkspace: @escaping (ChatCard, _ path: String, Workspace.Access) -> Void,
                @ViewBuilder custom: @escaping (ChatCard) -> Custom) {
        self.card = card
        self.controller = controller
        self.addWorkspace = addWorkspace
        self.custom = custom
    }

    public var body: some View {
        ChatCardFrame(resolved: card.resolved) {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch card.kind {
        case .clarify(let options, let sources):
            ClarifyCardView(options: options, sourceName: { sources[$0.ref.description] ?? "" }) { controller.choose($0, on: card) }
        case .signIn(_, let name, let domain):
            SignInCardView(name: name, domain: domain, signIn: { Task { await controller.signIn(card) } },
                           dismiss: { controller.decline(card) })
        case .permission(_, let name, let missing):
            PermissionCardView(name: name, missing: missing, granted: card.resolved ? controller.isGranted(card) : nil,
                               problem: card.problem, allow: { Task { await controller.allow(card) } },
                               openSettings: { controller.openSystemSettings(for: card) }, dismiss: { controller.decline(card) })
                // Back from System Settings, where Allow sends the user when macOS won't ask again.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if !card.resolved { controller.refreshPermissionCards() }
                }
        case .review(_, let name, let drift):
            ToolChangesCardView(name: name, drift: drift) { controller.review(card, accept: $0) }
        case .addSource(let url, let name):
            AddToolSourceCardView(url: url, name: name, add: { source in
                await controller.addSource(card, url: source.url, name: source.name, authType: source.authType,
                                           token: source.token, trusted: source.trusted)
            }, invalidURL: { controller.configuration.reportError("That isn't a server URL.") }, cancel: { controller.dismiss(card) },
               sendAsMessage: card.prompt == nil ? nil : { controller.sendAsMessage(card) })
        case .addWorkspace(let path):
            AddWorkspaceCardView(path: SavedWorkspaces.abbreviated(path), add: { addWorkspace(card, path, $0) },
                                 dismiss: { controller.dismiss(card) },
                                 sendAsMessage: card.prompt == nil ? nil : { controller.sendAsMessage(card) })
        case .pastedKey:
            PastedKeyCardView(sendWithoutIt: { controller.sendWithoutKey(card) },
                              addToolSource: { controller.dismiss(card); controller.showAddSource() },
                              cancel: { controller.dismiss(card) })
        case .notice(let text):
            ChatNoticeView(text) { controller.dismiss(card) }
        case .suggestServer(_, let name, _):
            ServerSuggestionView(name: name, checking: card.resolved, check: { controller.checkServer(card) },
                                 dismiss: { controller.dismiss(card) })
        case .warning(let text):
            ChatWarningView(text) { controller.dismiss(card) }
        case .emptyReply(let empty):
            // Says what to do: Retry on the latest message, or the message again on an older one (2026-11-05).
            let canRetry = controller.canRetry(card)
            let hint = empty.changedSomething ? "" : canRetry ? " Retry usually works." : " Send the message again to retry."
            EmptyReplyCardView(empty.note + hint, retry: canRetry ? { controller.retry(card) } : nil) {
                controller.dismiss(card)
            }
        case .custom:
            custom(card)
        @unknown default:
            EmptyView()
        }
    }
}
