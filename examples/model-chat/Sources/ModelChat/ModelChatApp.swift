import SwiftUI
import LocalLMLabSDKCore
import LocalLMLabSDKInference

// A route is a name for "the model for this job". The app asks for `.chat`; which model answers is
// set in one place (`Chat.newSession`).
extension RouteName { static let chat: RouteName = "chat" }

@main
struct ModelChatApp: App {
    var body: some Scene {
        WindowGroup("Model Chat") { ChatView().frame(minWidth: 560, minHeight: 520) }
            .defaultSize(width: 640, height: 640)
    }
}

/// The models this app offers. Each is one line: where the `chat` route points.
enum Choice: String, CaseIterable, Identifiable {
    case apple, qwen
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple on-device" : "Qwen3 4B (on this Mac)" }
    var repo: String? { self == .qwen ? "mlx-community/Qwen3-4B-4bit" : nil }
    var model: ModelID {
        if let repo { return ModelID(scheme: "mlx", rest: repo)! }
        return .system
    }
}

@MainActor @Observable
final class Chat {
    let mlx = MLXModelProvider()
    let lab: LocalLMLab
    var session: LocalLMLabSession?
    var choice: Choice = .apple { didSet { newSession() } }
    var error: String?

    /// Set while the open-weight model is not on disk: what it will take, and the progress once started.
    var offer: String?
    var progress: Double?

    init() {
        lab = LocalLMLab(configuration: .init(providers: [SystemModelProvider(), mlx]))
        newSession()
    }

    func newSession() {
        error = nil
        offer = nil
        lab.models.route(.chat, to: choice.model)
        // Loading a model never downloads it. If it isn't on disk, say so and offer the download.
        switch lab.models.availability(for: choice.model) {
        case .available:
            break
        case .notDownloaded:
            session = nil
            Task { await prepareOffer() }
            return
        default:
            session = nil
            error = "\(choice.title) is not available on this Mac."
            return
        }
        // Read-only tools run as they are. A tool that changes data would need an `authorizer:` here
        // (see docs/tool-authorizer.md); these two only read.
        session = try? lab.makeSession(route: .chat, tools: [ClockTool(), WeatherTool()],
                                       instructions: "Be brief. Use a tool when it helps.")
    }

    /// Check the download first (`validate` reads the size without downloading), then ask.
    private func prepareOffer() async {
        guard let repo = choice.repo else { return }
        do {
            let check = try await mlx.validate(repo)
            guard check.passed else { error = check.detail ?? "This model can't be downloaded here."; return }
            let size = check.weightBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "several GB"
            offer = "\(choice.title) is not on this Mac yet. Download it (\(size))?"
        } catch {
            self.error = "\(error)"
        }
    }

    func download() async {
        guard let repo = choice.repo else { return }
        progress = 0
        defer { progress = nil }
        do {
            for try await event in mlx.download(repo) {
                if case .progress(_, _, let fraction) = event { progress = fraction }
            }
            newSession()
        } catch {
            self.error = "\(error)"
        }
    }

    func send(_ text: String) async {
        guard let session else { return }
        // Streaming the reply fills session.hostTranscript, which the view reads and redraws.
        do { for try await _ in session.streamResponse(to: text) {} }
        catch { self.error = "\(error)" }
    }
}

struct ChatView: View {
    @State private var chat = Chat()
    @State private var draft = ""

    private func send() { let t = draft; draft = ""; Task { await chat.send(t) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Model", selection: $chat.choice) {
                    ForEach(Choice.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 300)
                Spacer()
                Label("Clock · Weather", systemImage: "wrench.and.screwdriver")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            if let offer = chat.offer {
                HStack {
                    Text(offer).font(.callout)
                    Spacer()
                    if let p = chat.progress { ProgressView(value: p).frame(width: 120) }
                    else { Button("Download") { Task { await chat.download() } } }
                }
                .padding(10).background(.yellow.opacity(0.15))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let t = chat.session?.hostTranscript {
                        ForEach(t.entries) { entry in
                            switch entry.content {
                            case .user(let text):
                                Text(text).padding(8).background(.blue.opacity(0.15), in: .rect(cornerRadius: 10))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            case .assistant(let text):
                                Text(text).textSelection(.enabled)
                            case .toolCall(let call):
                                ToolRow(call: call)
                            default:
                                EmptyView()
                            }
                        }
                        if let r = t.replyInProgress, !r.text.isEmpty { Text(r.text).foregroundStyle(.secondary) }
                    }
                    if let e = chat.error { Text(e).foregroundStyle(.red).font(.caption) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            Divider()
            HStack {
                TextField("Ask anything", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).disabled(draft.isEmpty || chat.session == nil)
            }
            .padding(10)
        }
    }
}

/// One tool call: its name, arguments, result and state.
struct ToolRow: View {
    let call: ToolCallRecord
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
            VStack(alignment: .leading, spacing: 2) {
                Text(call.tool.name).font(.caption.bold())
                if !call.argumentsDescription.isEmpty {
                    Text(call.argumentsDescription).font(.caption2).foregroundStyle(.secondary)
                }
                if let out = call.output {
                    Text(out).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            switch call.state {
            case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .running, .awaitingApproval: ProgressView().controlSize(.small)
            case .failed, .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            @unknown default: EmptyView()
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
