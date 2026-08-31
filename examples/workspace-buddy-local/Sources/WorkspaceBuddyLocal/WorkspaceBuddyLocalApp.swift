// Workspace Buddy (local model) — workspace-buddy's exact folder-picker + security-scoped
// bookmark + WorkspaceTools setup, but the model is an open-weight MLX model you download and
// run locally, routed through the 1.0 model layer, instead of Apple's on-device model.
//
// It is the one example that runs the model layer *inside App Sandbox* — so it also needs the
// `com.apple.security.network.client` entitlement (to fetch the model from Hugging Face on first
// run), on top of workspace-buddy's `files.user-selected.read-write`. The model downloads into
// this app's own sandbox container.
//
// The FolderAccess section below is copied verbatim from workspace-buddy. The differences are all
// in WorkspaceBuddyLocalModel: a LocalLMLab + MLXModelProvider, a download step with progress,
// and `lab.makeSession(route:tools:)` instead of `LanguageModelSession(tools:)`.

import Foundation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import SwiftUI

// The model this app routes to. Any MLX-format Hugging Face repo — see docs/tested-models.md.
let workspaceModelRepo = "mlx-community/Qwen3-8B-4bit"

// MARK: - Folder picker + security-scoped bookmark (see docs/sdk-guide.md §8) — verbatim from workspace-buddy

enum FolderAccess {
    private static let bookmarkKey = "workspaceFolderBookmark"

    @MainActor
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return url
    }

    static func resolveBookmarkedFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            if let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
        }
        return url
    }

    @MainActor
    static func withFolderAccessAsync<T>(_ body: (URL) async throws -> T) async rethrows -> T? {
        guard let url = resolveBookmarkedFolder() else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try await body(url)
    }
}

// MARK: - View model

@available(macOS 26.0, *)
@MainActor
final class WorkspaceBuddyLocalModel: ObservableObject {
    enum State {
        case idle
        case downloadingModel(Double)   // 0…1
        case working
        case ready(String)
        case failed(String)
    }

    @Published private(set) var folderURL: URL?
    @Published private(set) var state: State = .idle

    // The model layer: an MLX provider (one model resident at a time), Apple's on-device model
    // kept as a fallback, and one named route pointing at the MLX model.
    private let mlx = MLXModelProvider(residentModelLimit: 1)
    private lazy var lab = LocalLMLab(configuration: .init(providers: [mlx, SystemModelProvider()]))
    private lazy var modelID = ModelID(scheme: "mlx", rest: workspaceModelRepo)!

    init() {
        folderURL = FolderAccess.resolveBookmarkedFolder()
        lab.models.route(.local, to: modelID)
    }

    func chooseFolder() {
        guard let url = FolderAccess.pickFolder() else { return }
        folderURL = url
    }

    func submit(_ request: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch state {
        case .working, .downloadingModel: return
        default: break
        }
        Task { await run(trimmed) }
    }

    private func run(_ request: String) async {
        // 1. Download the model on first use (streams progress into the UI).
        if case .notDownloaded = lab.models.availability(for: modelID) {
            state = .downloadingModel(0)
            if let pre = try? await mlx.validate(workspaceModelRepo), !pre.passed {
                state = .failed("Model pre-flight failed (\(pre.failedStage?.rawValue ?? "?")): \(pre.detail ?? "")")
                return
            }
            do {
                for try await event in mlx.download(workspaceModelRepo) {
                    if case .progress(_, _, let fraction) = event {
                        state = .downloadingModel(fraction)
                    }
                }
            } catch {
                state = .failed("Model download failed: \(error.localizedDescription)")
                return
            }
        }

        // 2. Run the request, exactly as workspace-buddy does — only the session-creation line differs.
        state = .working
        let result: String? = await FolderAccess.withFolderAccessAsync { root in
            let tools: [any Tool] = [
                ListWorkspaceFilesTool(root: root),
                ReadWorkspaceFileTool(root: root),
                WriteWorkspaceFileTool(root: root),
                EditWorkspaceFileTool(root: root),
            ]
            let instructions = """
                You are a coding assistant working in a single project folder. Use \
                listWorkspaceFiles to see what's there and readWorkspaceFile before editing \
                anything — never guess a file's contents. Prefer editWorkspaceFile (a targeted \
                find-and-replace) over writeWorkspaceFile for changes to files that already \
                exist; writeWorkspaceFile only creates brand-new files and fails if the file is \
                already there. Explain what you changed and why, briefly.
                """
            do {
                let session = try self.lab.makeSession(
                    route: .local, tools: tools, instructions: instructions, includeMCPTools: false
                )
                let response = try await session.languageModelSession.respond(to: request)
                return response.content
            } catch {
                return "Error: \(await GenerationErrorDescription.describe(error))"
            }
        }

        guard let result else {
            state = .failed("Could not access the workspace folder — try choosing it again.")
            return
        }
        state = .ready(result)
    }
}

// MARK: - UI

@available(macOS 26.0, *)
struct ContentView: View {
    @ObservedObject var model: WorkspaceBuddyLocalModel
    @State private var request = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workspace Buddy — local model")
                .font(.title2).bold()
            Text(workspaceModelRepo)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            HStack {
                if let folderURL = model.folderURL {
                    Text(folderURL.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("No folder chosen yet.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.folderURL == nil ? "Choose Folder…" : "Change…") {
                    model.chooseFolder()
                }
            }

            TextField("What do you want done in this folder?", text: $request, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .disabled(model.folderURL == nil)
                .onSubmit { model.submit(request) }

            Button("Go") { model.submit(request) }
                .disabled(model.folderURL == nil || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)

            Divider()

            switch model.state {
            case .idle:
                Text("Pick a folder, then describe what you want changed. First Go downloads the model.")
                    .foregroundStyle(.secondary)
            case .downloadingModel(let fraction):
                ProgressView(value: fraction) {
                    Text("Downloading \(workspaceModelRepo) — \(Int(fraction * 100))%")
                }
            case .working:
                ProgressView("Working…")
            case .ready(let summary):
                ScrollView {
                    Text(summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: .infinity, minHeight: 360, idealHeight: 440, maxHeight: .infinity)
    }
}

@available(macOS 26.0, *)
@main
struct WorkspaceBuddyLocalApp: App {
    @StateObject private var model = WorkspaceBuddyLocalModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}
