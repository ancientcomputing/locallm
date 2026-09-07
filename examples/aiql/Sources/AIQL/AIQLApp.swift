// AIQL — "ask your data". A SwiftUI app aimed at someone who lives in a marketing tool, not a
// terminal: type a local model, an MCP data source, and a plain-English request; press Go.
//
//   Go  →  (1) connect to the MCP server (public, or an OAuth sign-in in the browser)
//          (2) download the local model if it isn't cached yet
//          (3) run the pipeline: pull the dataset into a file (FileBackedTool — the raw payload
//              never enters the model's context), then describeJson → jsonToCsv → sort/filter/
//              select (the Core data verbs) → a CSV in the folder you chose.
//
// The model only names the operations and the columns; the SDK primitives do every row-level
// step, so there is nothing for the model to fabricate. See docs/sdk-guide.md §8b.
//
// Structure borrowed from: workspace-buddy-local (SwiftUI + App Sandbox + MLX model + folder
// picker + security-scoped bookmark), plate-today (MCP client + OAuth redirect via AppDelegate),
// repo-qa (MCPTool / FileBackedTool.mcp from a live schema).

import AppKit
import Foundation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import SwiftUI

// MARK: - Folder picker + security-scoped bookmark (docs/sdk-guide.md §8) — verbatim from workspace-buddy-local

enum FolderAccess {
    private static let bookmarkKey = "aiqlOutputFolderBookmark"

    @MainActor
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for AIQL to write the spreadsheet into."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return url
    }

    static func resolveBookmarkedFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
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

@available(macOS 27.0, *)
@MainActor
final class AIQLModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case connecting
        case downloadingModel(Double)      // 0…1
        case running
        case done(fileName: String, csv: String, folder: URL)
        case failed(String)
    }

    @Published var modelRepo = "mlx-community/Qwen3-14B-4bit"
    @Published var serverURLString = "https://econ-index.mcp.claude.com/mcp"
    @Published var request = ""
    @Published private(set) var folderURL: URL?
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var steps: [String] = []   // friendly progress lines

    private let manager = MCPServerManager()
    private let mlx = MLXModelProvider(residentModelLimit: 1)
    private lazy var lab = LocalLMLab(configuration: .init(providers: [mlx, SystemModelProvider()]))

    init() {
        folderURL = FolderAccess.resolveBookmarkedFolder()
    }

    var isBusy: Bool {
        switch stage {
        case .connecting, .downloadingModel, .running: return true
        default: return false
        }
    }

    var canGo: Bool {
        folderURL != nil
            && !modelRepo.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: serverURLString.trimmingCharacters(in: .whitespaces))?.scheme != nil
            && !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
    }

    func chooseFolder() {
        if let url = FolderAccess.pickFolder() { folderURL = url }
    }

    func go() {
        guard canGo else { return }
        Task { await run() }
    }

    private func step(_ line: String) { steps.append(line) }

    private func run() async {
        steps = []
        let prompt = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)), serverURL.scheme != nil else {
            stage = .failed("That MCP server address doesn't look like a web link."); return
        }
        guard let modelID = ModelID(scheme: "mlx", rest: modelRepo.trimmingCharacters(in: .whitespaces)) else {
            stage = .failed("The model name should look like mlx-community/Qwen3-8B-4bit."); return
        }
        lab.models.route(.local, to: modelID)

        // 1 — connect (triggers an OAuth browser sign-in automatically if the server needs one)
        stage = .connecting
        step("Connecting to \(serverURL.host ?? serverURL.absoluteString)…")
        let connection = await manager.addServer(url: serverURL, displayName: serverURL.host ?? "MCP server")
        guard case .success(let server) = connection else {
            if case .failure(let error) = connection {
                stage = .failed("Couldn't connect to that MCP server — \(Self.describe(error))")
            } else {
                stage = .failed("Couldn't connect to that MCP server.")
            }
            return
        }
        guard !server.tools.isEmpty else {
            stage = .failed("Connected, but that server didn't offer any tools to get data from."); return
        }
        step("Connected — \(server.tools.count) data tool(s) available.")

        // 2 — download the model on first use
        if case .notDownloaded = lab.models.availability(for: modelID) {
            stage = .downloadingModel(0)
            step("Downloading \(modelRepo) (first run only)…")
            if let preflight = try? await mlx.validate(modelRepo.trimmingCharacters(in: .whitespaces)), !preflight.passed {
                stage = .failed("That model didn't pass its check: \(preflight.detail ?? "unknown reason")."); return
            }
            do {
                for try await event in mlx.download(modelRepo.trimmingCharacters(in: .whitespaces)) {
                    if case .progress(_, _, let fraction) = event { stage = .downloadingModel(fraction) }
                }
            } catch {
                stage = .failed("The model download failed: \(error.localizedDescription)"); return
            }
        }

        // 3 — run the pipeline inside the security-scoped access window
        stage = .running
        step("Working… this takes a few minutes.")
        let outcome = await FolderAccess.withFolderAccessAsync { root in
            await self.runPipeline(prompt: prompt, root: root, serverTools: server.tools, serverID: server.id, modelID: modelID)
        }
        stage = outcome ?? .failed("Couldn't open the folder you chose — pick it again.")
    }

    private func runPipeline(prompt: String, root: URL, serverTools: [MCPToolDescriptor], serverID: MCPServerID, modelID: ModelID) async -> Stage {
        // Wrap the server's tools as file-backed so the model can `saveAs` any of them. Cap the
        // count — a small model degrades past ~8 tools; prefer names that look like "get a
        // dataset" over admin/overview tools.
        let ranked = serverTools.sorted { lhs, rhs in Self.dataLikelihood(lhs.name) > Self.dataLikelihood(rhs.name) }
        let dataTools: [any Tool] = ranked.prefix(4).compactMap {
            try? FileBackedTool.mcp(descriptor: $0, manager: manager, root: root, inlineCharacterLimit: 8_000)
        }
        guard !dataTools.isEmpty else { return .failed("Couldn't read that server's tools — its data format isn't supported yet.") }

        var tools: [any Tool] = dataTools
        tools.append(DescribeJSONTool(root: root))
        tools.append(CSVInfoTool(root: root))
        tools.append(JSONToCSVTool(root: root))
        tools.append(SelectColumnsTool(root: root))
        tools.append(FilterRowsTool(root: root))
        tools.append(SortRowsTool(root: root))
        tools.append(ConcatRowsTool(root: root))

        let dataToolNames = dataTools.map(\.name).joined(separator: ", ")
        let instructions = """
        You turn a data question into a fixed sequence of tool calls that ends with a CSV file. \
        You never write row data yourself — every tool does the mechanical work and the file is \
        built for you.

        Run these steps in order, one tool call each, without asking for confirmation:

        1. Pick the ONE data tool whose result answers the question — from: \(dataToolNames) — and \
           call it with its `saveAs` argument set to "raw/data.json". Never call a data tool \
           without `saveAs`; the result is large. If the result covers only part of the data and \
           the tool has a page / offset / cursor argument, call it again for each page with the \
           same `saveAs` path plus `saveAsAppend: true` until you have it all — jsonToCsv reads \
           every appended page.
        2. describeJson  path "raw/data.json". Its output has lines like `items[0].name  string`. \
           The array's path is the part before `[0]` (here: `items`); the record fields are the \
           parts after `[0].` (here: `name`).
        3. jsonToCsv  inputPath "raw/data.json", outputPath "all.csv": rowsAt = the array path \
           from step 2 (no "[0]"); columns = for each field the question asks for, {header: a \
           name you choose, path: the field name from step 2}. If unsure of the field names, \
           omit `columns` to get every field, then use selectColumns.
        4. Apply ONLY the refinements the question explicitly asks for, each reading the previous \
           file, writing "stage1.csv", "stage2.csv", …:
             - "top N" / "highest" / "largest" / "most"  => sortRows with `limit`
             - "only …" / "without …" / "where …"        => filterRows
           Do NOT add a filter or a sort the question did not ask for.
        5. LAST call before csvInfo is always selectColumns: input = the last stage file (or \
           "all.csv" if step 4 did nothing), outputPath = "out.csv", columns = exactly the \
           fields the question named, in order, renamed to what the question calls them.
        6. csvInfo  path "out.csv"  — then reply in one sentence with the column names and the \
           row count. Do not print the rows.

        If a tool returns text starting with "Error:", read it, fix that one call, and retry it.
        """

        let session: LocalLMLabSession
        do {
            session = try lab.makeSession(route: .local, tools: tools, instructions: instructions, includeMCPTools: false)
        } catch {
            return .failed("Couldn't start the model: \(error.localizedDescription)")
        }
        defer { session.cancel() }

        // Friendly progress from the session's tool-call side-channel.
        let stepTask = Task { @MainActor in
            for await event in session.events {
                switch event {
                case .toolCallStarted(_, let name):
                    self.step(Self.friendlyStep(for: name))
                case .toolCallFinished(_, let name, let failed) where failed:
                    self.step("  · \(Self.friendlyStep(for: name)) hit a snag — retrying")
                default:
                    break
                }
            }
        }
        defer { stepTask.cancel() }

        do {
            _ = try await session.languageModelSession.respond(to: "Question: \(prompt)\n\nBegin with step 1 now.")
        } catch {
            return .failed(await GenerationErrorDescription.describe(error))
        }

        // The result CSV. Instructions ask for "out.csv"; if a weak model left it in the last
        // stage file, fall back to the most recently written .csv.
        var name = "out.csv"
        if case .failure = WorkspaceAccess.readFile(in: root, path: "out.csv"),
           case .success(let entries) = WorkspaceAccess.listFiles(in: root, subpath: nil) {
            if let newest = entries
                .filter({ !$0.isDirectory && $0.name.hasSuffix(".csv") })
                .max(by: { ($0.modifiedDate ?? .distantPast) < ($1.modifiedDate ?? .distantPast) }) {
                name = newest.name
            }
        }
        guard case .success(let csv) = WorkspaceAccess.readFile(in: root, path: name) else {
            return .failed("The model finished but didn't write a spreadsheet. Try rephrasing the request, or a larger model.")
        }
        step("Saved \(name).")
        return .done(fileName: name, csv: csv, folder: root)
    }

    // MARK: helpers

    static func describe(_ error: MCPServerError) -> String {
        switch error {
        case .unreachable: return "the server could not be reached."
        case .malformedResponse: return "the server returned something unexpected."
        case .protocolMismatch: return "the server speaks a different MCP version."
        case .notConnected: return "not connected."
        case .toolNotFound: return "a tool went missing."
        case .serverError(let message): return message
        case .authorizationRequired: return "it needs you to sign in."
        case .credentialRejected: return "it rejected the saved sign-in."
        case .httpError(let status): return "it returned HTTP \(status)."
        case .oauthRegistrationNotSupported: return "it needs a manually configured OAuth client."
        @unknown default: return "\(error)"
        }
    }

    static func dataLikelihood(_ name: String) -> Int {
        let lower = name.lowercased()
        var score = 0
        for keyword in ["list", "search", "get_all", "contacts", "records", "rows", "dataset", "export", "find", "query", "items", "results", "countries", "people"] where lower.contains(keyword) {
            score += 2
        }
        for keyword in ["overview", "schema", "help", "meta", "config", "auth", "whoami", "status", "count"] where lower.contains(keyword) {
            score -= 2
        }
        return score
    }

    static func friendlyStep(for toolName: String) -> String {
        switch toolName {
        case "describeJson": return "Looking at how the data is organised…"
        case "jsonToCsv": return "Building the spreadsheet…"
        case "selectColumns": return "Keeping just the columns you asked for…"
        case "filterRows": return "Filtering the rows…"
        case "sortRows": return "Sorting…"
        case "csvInfo": return "Checking the result…"
        default: return "Fetching the data…"
        }
    }
}

// MARK: - UI

@available(macOS 27.0, *)
struct ContentView: View {
    @ObservedObject var model: AIQLModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AIQL — ask your data")
                .font(.title2).bold()
            Text("Pull a dataset from an MCP server and get a spreadsheet back. The data is read by a model running on this Mac — nothing is sent to an online AI provider.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Local model").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("mlx-community/…", text: $model.modelRepo)
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        .disabled(model.isBusy)
                }
                GridRow {
                    Text("MCP data source").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("https://…/mcp", text: $model.serverURLString)
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        .disabled(model.isBusy)
                }
                GridRow {
                    Text("Save into").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack {
                        Text(model.folderURL?.path ?? "No folder chosen")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(model.folderURL == nil ? .secondary : .primary)
                        Spacer()
                        Button(model.folderURL == nil ? "Choose…" : "Change…") { model.chooseFolder() }
                            .disabled(model.isBusy)
                    }
                }
                GridRow {
                    Text("Request").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("e.g. every country and its usage index, highest first, top 10", text: $model.request, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5)
                        .disabled(model.isBusy)
                }
            }

            Button {
                model.go()
            } label: {
                Text(model.isBusy ? "Working…" : "Go").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canGo)

            Divider()

            statusArea
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 620, maxWidth: .infinity, minHeight: 460, idealHeight: 560, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusArea: some View {
        switch model.stage {
        case .idle:
            Text("Choose a folder, fill in the three fields, and press Go. The first run downloads the model.")
                .foregroundStyle(.secondary)
        case .connecting:
            progressBlock(indeterminate: true, label: "Connecting…")
        case .downloadingModel(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fraction) {
                    Text("Downloading the model — \(Int(fraction * 100))% (first run only)")
                }
                stepList
            }
        case .running:
            progressBlock(indeterminate: true, label: "Working…")
        case .done(let fileName, let csv, let folder):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Done — \(fileName)").font(.headline)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(fileName)])
                    }
                }
                ScrollView {
                    Text(csv)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                stepList
            }
        }
    }

    private func progressBlock(indeterminate: Bool, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(label).progressViewStyle(.linear)
            stepList
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.steps.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// Handle aiql://oauth/callback through the AppDelegate, not SwiftUI's .onOpenURL — WindowGroup
// treats an open-URL event as a request for a new window (confirmed in plate-today: signing in
// brought back a second window). Same fix LocalLM Lab's own Chooser uses.
@available(macOS 27.0, *)
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "aiql" {
            MCPOAuthRedirectListener.shared.handleRedirect(url)
        }
    }
}

@available(macOS 27.0, *)
@main
struct AIQLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AIQLModel()

    init() {
        // Distinct from LocalLM Lab's "locallmlab" and plate-today's "platetoday" schemes so the
        // callbacks don't collide if more than one is installed — matches Info.plist's
        // CFBundleURLTypes.
        MCPOAuthFlow.redirectURI = "aiql://oauth/callback"
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
    }
}
