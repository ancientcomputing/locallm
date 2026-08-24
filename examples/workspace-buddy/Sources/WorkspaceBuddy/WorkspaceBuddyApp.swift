// Workspace Buddy — the SDK's fourth reference app, and its first that writes to disk. Pick a
// folder, type a request, the on-device model reads/creates/edits files in it via Core's
// WorkspaceTools.swift (Path A). Single-turn per request, same minimal-reference-app shape as
// plate-today/repo-qa — not a full multi-turn chat, deliberately, to keep this focused on the
// filesystem-access story rather than session/history management.
//
// Sandboxed unconditionally (see packaging/WorkspaceBuddy.entitlements) — see this file's
// FolderAccess section for what that actually requires: a security-scoped bookmark, not a plain
// remembered path.

import Foundation
import FoundationModels
import LocalLMLabSDKCore
import SwiftUI

// MARK: - Folder picker + security-scoped bookmark (see docs/sdk-guide.md §8)

// Verbatim from §8's documented pattern, with one real addition not covered there: an
// async-aware access wrapper. §8's own withFolderAccess<T>(_:) brackets a SYNCHRONOUS body —
// fine for a single read, but this app's actual file access happens inside
// LanguageModelSession.respond(to:), which can invoke several tool calls over the course of one
// async call. The security-scoped access window has to stay open for that whole call, not just a
// synchronous setup step — see withFolderAccessAsync(_:) below, which is what this app actually
// uses.
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

    // DIFF FROM §8's synchronous withFolderAccess<T>(_:): this brackets an ASYNC body, so the
    // access window stays open for a whole LanguageModelSession.respond(to:) call — including
    // every WorkspaceTools call the model makes along the way — not just one synchronous read.
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
final class WorkspaceBuddyModel: ObservableObject {
    enum State {
        case idle
        case working
        case ready(String)
        case failed(String)
    }

    @Published private(set) var folderURL: URL?
    @Published private(set) var state: State = .idle

    init() {
        folderURL = FolderAccess.resolveBookmarkedFolder()
    }

    func chooseFolder() {
        guard let url = FolderAccess.pickFolder() else { return }
        folderURL = url
    }

    func submit(_ request: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .working = state { return }
        state = .working
        Task { await run(trimmed) }
    }

    private func run(_ request: String) async {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            state = .failed("On-device model unavailable: \(model.availability)")
            return
        }

        let result: String? = await FolderAccess.withFolderAccessAsync { root in
            // No DeleteWorkspaceFileTool here — a coding assistant that can delete files
            // unprompted is a meaningfully bigger risk than one that can only read/create/edit;
            // it's still available in Core (see WorkspaceTools.swift) for a host app that
            // explicitly wants it, just not wired in by default here.
            let tools: [any Tool] = [
                ListWorkspaceFilesTool(root: root),
                ReadWorkspaceFileTool(root: root),
                WriteWorkspaceFileTool(root: root),
                EditWorkspaceFileTool(root: root),
            ]
            let session = LanguageModelSession(tools: tools) {
                """
                You are a coding assistant working in a single project folder. Use \
                listWorkspaceFiles to see what's there and readWorkspaceFile before editing \
                anything — never guess a file's contents. Prefer editWorkspaceFile (a targeted \
                find-and-replace) over writeWorkspaceFile for changes to files that already \
                exist; writeWorkspaceFile only creates brand-new files and fails if the file is \
                already there. Explain what you changed and why, briefly.
                """
            }
            do {
                let response = try await session.respond(to: request)
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
    @ObservedObject var model: WorkspaceBuddyModel
    @State private var request = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workspace Buddy")
                .font(.title2).bold()

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
                Text("Pick a folder, then describe what you want changed.")
                    .foregroundStyle(.secondary)
            case .working:
                ProgressView("Working…")
            case .ready(let summary):
                ScrollView {
                    Text(summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: .infinity, minHeight: 360, idealHeight: 420, maxHeight: .infinity)
    }
}

@available(macOS 26.0, *)
@main
struct WorkspaceBuddyApp: App {
    @StateObject private var model = WorkspaceBuddyModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}
