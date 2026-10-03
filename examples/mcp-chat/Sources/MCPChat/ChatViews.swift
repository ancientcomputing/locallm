import LocalLMLabSDKComponents
import LocalLMLabSDKCore
import LocalLMLabSDKMCPAppsHost
import SwiftUI

struct ChatRootView: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        VStack(spacing: 0) {
            if let session = chat.session {
                ConversationView(chat: chat, transcript: session.hostTranscript)
            } else {
                ModelSetupView(chat: chat)
            }
            ForEach(chat.serversWithNoToolsOn, id: \.id) { server in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("\(server.displayName) is connected, but none of its tools are on, so the model can't use it.")
                    Spacer()
                    Button("Choose Tools…") { chat.showServers = true }
                }
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.orange.opacity(0.1))
            }
            Divider()
            Composer(chat: chat)
        }
        .frame(minWidth: 640, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(chat.modelChoice.title).font(.callout).foregroundStyle(.secondary)
            }
            ToolbarItemGroup {
                ToolsBadge(chat: chat)
                Button { chat.showServers = true } label: { Label("MCP Servers", systemImage: "server.rack") }
                Button { chat.newConversation() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .disabled(chat.status == .responding)
            }
        }
        .sheet(isPresented: $chat.showServers) {
            VStack(alignment: .trailing) {
                MCPServerPickerView(manager: chat.servers)
                Button("Done") { chat.showServers = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
            .frame(minWidth: 560, minHeight: 480)
        }
        .toolConfirmationSheet(chat.toolConfirm)
        .alert("Something went wrong", isPresented: Binding(get: { chat.errorMessage != nil }, set: { if !$0 { chat.errorMessage = nil } })) {
            Button("OK") { chat.errorMessage = nil }
        } message: {
            Text(chat.errorMessage ?? "")
        }
        .task { await chat.start() }
    }
}

private struct ModelSetupView: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 40)).foregroundStyle(.tint)
            Text("MCP Chat").font(.title.weight(.semibold))
            switch chat.status {
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading \(qwenRepo) — \(Int(fraction * 100))%") }
                    .frame(maxWidth: 360)
            default:
                if let reason = chat.modelUnavailableReason {
                    Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Text("Choose another model in Settings.").font(.callout).foregroundStyle(.secondary)
                } else if chat.modelChoice == .qwen3 {
                    Text("Qwen3 8B runs on this Mac. It needs a one-time download of about 4.6 GB.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button("Download Model") { Task { await chat.downloadModel() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            Text("Add MCP servers with the server button in the toolbar. When a tool has an interactive view, it appears in the conversation.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversationView: View {
    @ObservedObject var chat: ChatModel
    let transcript: HostTranscript
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if transcript.entries.isEmpty {
                    Text("Ask something. Try “What's due today?” with Todoist connected.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(transcript.entries) { entry in
                    EntryView(entry: entry, chat: chat)
                        .id(entry.id)
                    if let boundary = chat.memoryBoundaryTurn, entry.id == lastID(ofTurn: boundary) {
                        MemoryDivider()
                    }
                }
                if let reply = transcript.replyInProgress {
                    ReplyInProgressView(reply: reply)
                } else if chat.status == .responding {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            // Room below the newest item, so it never sits against the message box.
            .padding(.bottom, 72)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        // Follow the conversation while the user is at the bottom: whatever makes it taller — a new
        // message, the spinner, streaming text, a widget loading or resizing — scrolls it into view.
        // Someone who scrolled up to read stays where they are.
        .onScrollGeometryChange(for: Layout.self) { geometry in
            Layout(contentHeight: geometry.contentSize.height,
                   distanceFromBottom: geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height)
        } action: { old, new in
            if new.contentHeight != old.contentHeight, old.distanceFromBottom < 120 {
                position.scrollTo(edge: .bottom)
            }
        }
        // Sending a message always brings the bottom into view.
        .onChange(of: chat.status) { _, status in
            if status == .responding { withAnimation { position.scrollTo(edge: .bottom) } }
        }
    }

    private struct Layout: Equatable {
        var contentHeight: CGFloat
        var distanceFromBottom: CGFloat
    }

    private func lastID(ofTurn turn: Int) -> String? {
        transcript.entries.last { $0.turn == turn }?.id
    }
}

private struct MemoryDivider: View {
    var body: some View {
        HStack {
            VStack { Divider() }
            Text("The model doesn't remember the messages above").font(.caption).foregroundStyle(.secondary).fixedSize()
            VStack { Divider() }
        }
        .help("“Remember conversations” was off when this conversation was saved or reopened. Turn it on in Settings to keep the model's memory across relaunches.")
    }
}

private struct EntryView: View {
    let entry: HostTranscript.Entry
    @ObservedObject var chat: ChatModel

    var body: some View {
        switch entry.content {
        case .user(let text):
            UserBubble(text: text, fromWidget: entry.appInstance != nil)
        case .assistant(let text):
            AssistantMessage(text: text)
        case .reasoning(let text):
            ReasoningDisclosure(text: text)
        case .toolCall(let record):
            ToolCallView(record: record, chat: chat)
        case .appContext(_, let text):
            DisclosureGroup {
                Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("A view shared context with the model", systemImage: "rectangle.and.text.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
        @unknown default:
            EmptyView()
        }
    }
}

private struct UserBubble: View {
    let text: String
    let fromWidget: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 3) {
                if fromWidget {
                    Label("Sent by a view", systemImage: "rectangle.on.rectangle").font(.caption2).foregroundStyle(.secondary)
                }
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(fromWidget ? 0.08 : 0.15), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

/// The answer. Reasoning arrives as its own `.reasoning` entry: the SDK splits Qwen3's inline
/// `<think>` block out of the reply.
private struct AssistantMessage: View {
    let text: String

    var body: some View {
        Text(Self.markdown(text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The streaming reply (`hostTranscript.replyInProgress`, reasoning already split out).
private struct ReplyInProgressView: View {
    let reply: HostTranscript.ReplyInProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reasoning = reply.reasoning { ReasoningDisclosure(text: reasoning, thinking: reply.isReasoning) }
            if reply.text.isEmpty {
                if reply.reasoning == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                }
            } else {
                AssistantMessage(text: reply.text)
            }
        }
    }
}

/// The model's reasoning, collapsed by default.
private struct ReasoningDisclosure: View {
    let text: String
    var thinking = false

    var body: some View {
        DisclosureGroup {
            Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Label(thinking ? "Thinking…" : "Reasoning", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                if thinking { ProgressView().controlSize(.mini) }
            }
        }
    }
}

private struct ToolCallView: View {
    let record: ToolCallRecord
    @ObservedObject var chat: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments").font(.caption2).foregroundStyle(.secondary)
                    Text(record.argumentsDescription).font(.caption.monospaced()).textSelection(.enabled)
                    if let output = record.output {
                        Text("Result").font(.caption2).foregroundStyle(.secondary)
                        Text(output.prefix(2000)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 6) {
                    stateIcon
                    Text(record.tool.name).font(.callout.monospaced())
                    if let by = initiatorLabel { Text(by).font(.caption2).foregroundStyle(.secondary) }
                    if case .denied(let reason) = record.state { Text("Not allowed: \(reason)").font(.caption).foregroundStyle(.secondary) }
                    if case .failed(let reason) = record.state { Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1) }
                }
            }
            if record.app != nil, record.state == .finished, record.mcpResult.map({ !$0.isError }) ?? false {
                WidgetSlot(record: record, chat: chat, pool: chat.pool)
            }
        }
    }

    private var initiatorLabel: String? {
        switch record.initiator {
        case .model: nil
        case .app: "by a view"
        case .host: "refresh"
        @unknown default: nil
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch record.state {
        case .awaitingApproval: Image(systemName: "hand.raised").foregroundStyle(.orange)
        case .running: ProgressView().controlSize(.mini)
        case .finished: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        case .denied: Image(systemName: "nosign").foregroundStyle(.secondary)
        @unknown default: Image(systemName: "questionmark.circle")
        }
    }
}

struct Composer: View {
    @ObservedObject var chat: ChatModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private var canSend: Bool {
        chat.status == .ready && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        chat.send(text)
        text = ""
    }
}

struct SettingsView: View {
    @AppStorage(ChatSettings.modelKey) private var model = ChatModelChoice.qwen3.rawValue
    @AppStorage(ChatSettings.rememberKey) private var remember = true
    @AppStorage(ChatSettings.widgetMessagesKey) private var widgetMessages = false
    @AppStorage(ChatSettings.widgetContextKey) private var widgetContext = true
    @AppStorage(ChatSettings.liveWidgetsKey) private var liveWidgets = 3
    @AppStorage(ChatSettings.clockToolKey) private var clockTool = true

    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $model) {
                    ForEach(ChatModelChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Remember conversations", isOn: $remember)
                Text("When on, a reopened conversation continues with the model's memory of it, and what the model saw — including tool results — is saved on this Mac. When off, you still see the earlier conversation, but the model starts fresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tools") {
                Toggle("Clock tool (getCurrentTime)", isOn: $clockTool)
                Text("Lets the model check the current date and time, e.g. for “what's due tomorrow?”. The date is also sent with every message.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Whether a server's tools ask before they run is set per server in the server list: its trust level and tool approval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Interactive views") {
                Toggle("Views may share context with the model", isOn: $widgetContext)
                Toggle("Views may send messages as you", isOn: $widgetMessages)
                Stepper("Live views: \(liveWidgets)", value: $liveWidgets, in: 1...8)
                Text("Each live view uses about 100 MB. Older views are shown as pictures until you scroll back to them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}

/// How many MCP tools the model has, with the list on click.
private struct ToolsBadge: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject private var servers: MCPServerManagerObservable
    @State private var showList = false

    init(chat: ChatModel) {
        self.chat = chat
        self.servers = chat.servers
    }

    var body: some View {
        let tools = chat.modelTools
        let builtIn = chat.builtInToolNames
        let count = tools.count + builtIn.count
        Button { showList.toggle() } label: {
            Label("\(count) tool\(count == 1 ? "" : "s")", systemImage: "wrench.and.screwdriver")
                .labelStyle(.titleAndIcon)
        }
        .help("MCP tools the model can use")
        .popover(isPresented: $showList) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tools the model can use").font(.headline)
                ForEach(builtIn, id: \.self) { name in
                    HStack(spacing: 6) {
                        Text(name).font(.callout.monospaced())
                        Text("built in").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if tools.isEmpty {
                    Text("No MCP tools. Turn tools on in the server list.").foregroundStyle(.secondary)
                }
                ForEach(tools, id: \.name) { tool in
                    HStack(spacing: 6) {
                        Text(tool.name).font(.callout.monospaced())
                        if tool.app != nil { Image(systemName: "rectangle.on.rectangle").help("Shows an interactive view") }
                    }
                }
                Button("Server List…") { showList = false; chat.showServers = true }.padding(.top, 4)
            }
            .padding(14).frame(minWidth: 260, alignment: .leading)
        }
    }
}

