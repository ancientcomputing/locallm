import Foundation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKInference

// code-buddy — a minimal coding agent on the LocalLM Lab SDK (R17).
//
//   code-buddy [options] <workspace-dir> <task...>
//
//   --route heavy|light   which model to use (default: heavy)
//   --heavy <hf-repo>     model for .heavy  (default below)
//   --light <hf-repo>     model for .light
//   --test-cmd "<cmd>"    the run_tests command (default: "swift test")
//   --no-mcp             skip the docs-lookup MCP server
//
// First run downloads the chosen model. Tool-call trace goes to stderr; the model's
// answer streams to stdout.

struct Options {
    var route: RouteName = .heavy
    var heavy = "mlx-community/Qwen3-8B-4bit"
    var light = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    var testCommand = ["swift", "test"]
    var useMCP = true
    var workspace = ""
    var task = ""
}

func parseArgs() -> Options {
    var o = Options()
    var rest: [String] = []
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--route": if let v = it.next() { o.route = RouteName(v) }
        case "--heavy": if let v = it.next() { o.heavy = v }
        case "--light": if let v = it.next() { o.light = v }
        case "--test-cmd": if let v = it.next() { o.testCommand = v.split(separator: " ").map(String.init) }
        case "--no-mcp": o.useMCP = false
        default: rest.append(a)
        }
    }
    guard rest.count >= 2 else {
        FileHandle.standardError.write(Data("usage: code-buddy [options] <workspace-dir> <task...>\n".utf8))
        exit(2)
    }
    o.workspace = rest[0]
    o.task = rest.dropFirst().joined(separator: " ")
    return o
}

func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

@MainActor
func run() async {
    let opts = parseArgs()
    let root = URL(fileURLWithPath: opts.workspace, isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else {
        note("workspace \(root.path) does not exist"); exit(1)
    }

    let mlx = MLXModelProvider(residentModelLimit: 1)
    let lab = LocalLMLab(configuration: .init(providers: [mlx, SystemModelProvider()]))
    lab.models.route(.heavy, to: ModelID(scheme: "mlx", rest: opts.heavy)!)
    lab.models.route(.light, to: ModelID(scheme: "mlx", rest: opts.light)!)

    let modelID = lab.models.modelID(for: opts.route)!
    note("SDK \(LocalLMLabSDKVersion.current) · route .\(opts.route) → \(modelID)")

    // Pre-flight + download if needed.
    if case .notDownloaded = lab.models.availability(for: modelID) {
        let repo = modelID.rest
        let pre = try? await mlx.validate(repo)
        if let pre, !pre.passed {
            note("pre-flight failed (\(pre.failedStage!.rawValue)): \(pre.detail ?? "")"); exit(1)
        }
        note("downloading \(repo)…")
        do {
            for try await event in mlx.download(repo) {
                if case .progress(_, _, let f) = event {
                    FileHandle.standardError.write(Data("\u{1B}[2K\r  \(Int(f * 100))%".utf8))
                }
            }
            note("\u{1B}[2K\r  done")
        } catch {
            note("download failed: \(error)"); exit(1)
        }
    }

    // Tools: Core Workspace tools + host Process tools + (auto) MCP session tools.
    var tools: [any Tool] = [
        WorkspaceTreeTool(root: root),
        SearchWorkspaceTool(root: root),
        ReadWorkspaceFileTool(root: root),
        ReadFileRangeTool(root: root),
        ApplyPatchTool(root: root),
        EditWorkspaceFileTool(root: root),
        WriteWorkspaceFileTool(root: root),
        ListWorkspaceFilesTool(root: root),
        GitTool(root: root),
        RunTestsTool(root: root, command: opts.testCommand),
    ]

    if opts.useMCP {
        note("connecting DeepWiki (docs lookup)…")
        let result = await lab.mcp.addServer(url: URL(string: "https://mcp.deepwiki.com/mcp")!, displayName: "DeepWiki")
        if case .success(let state) = result {
            // read_wiki_contents dumps an entire wiki unscoped — see repo-qa's note.
            for tool in state.tools where tool.name == "read_wiki_contents" {
                lab.mcp.setToolEnabled(server: state.id, tool: tool.name, enabled: false)
            }
            note("  \(lab.mcp.toolsForSession().count) MCP tool(s)")
        } else {
            note("  MCP unavailable — continuing without it")
        }
    }

    let instructions = """
        You are a coding agent working in the user's repository. Use the tools to explore and \
        change the code — workspaceTree / searchWorkspace / readWorkspaceFile / readFileRange to \
        understand it, applyPatch (a unified diff) or editWorkspaceFile for changes, git for \
        read-only history, run_tests to check your work, and the DeepWiki tools to look up how a \
        library is meant to be used. Make the smallest change that solves the task. After editing, \
        run the tests. Explain what you changed and why.
        """

    let session: LocalLMLabSession
    do {
        session = try lab.makeSession(route: opts.route, tools: tools, instructions: instructions)
    } catch {
        note("makeSession failed: \(error)"); exit(1)
    }

    let events = Task { @MainActor in
        for await event in session.events {
            switch event {
            case .toolCallStarted(_, let name): note("  → \(name)")
            case .toolCallFinished(_, let name, let failed): note("  \(failed ? "✗" : "✓") \(name)")
            case .contextCompacted(let n): note("  (compacted \(n) transcript entries)")
            default: break
            }
        }
    }

    note("\n--- task: \(opts.task) ---\n")
    do {
        var printed = 0
        for try await partial in session.languageModelSession.streamResponse(to: opts.task) {
            // streamResponse yields cumulative snapshots — print only the new suffix.
            let content = partial.content
            if content.count > printed {
                let start = content.index(content.startIndex, offsetBy: printed)
                print(content[start...], terminator: "")
                fflush(stdout)
                printed = content.count
            }
        }
        print()
    } catch {
        note("\nerror: \(await GenerationErrorDescription.describe(error))")
    }

    session.cancel()
    await events.value
    note("\ncontext: \(session.contextBudget)")
}

await run()
