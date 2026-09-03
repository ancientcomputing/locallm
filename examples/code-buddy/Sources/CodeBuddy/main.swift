import Foundation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKInference

// code-buddy — a minimal coding agent on the LocalLM Lab SDK (R17).
//
//   code-buddy [options] <workspace-dir> [task...]
//
//   --route heavy|light   which model to use (default: heavy)
//   --heavy <hf-repo>     model for .heavy  (default below)
//   --light <hf-repo>     model for .light
//   --test-cmd "<cmd>"    the run_tests command (default: "swift test")
//   --no-mcp             skip the docs-lookup MCP server
//   --no-verbose         hide the per-tool-call trace (default: verbose)
//
// Give a task on the command line and it runs that one task and stops. Omit the task
// and it drops into an interactive `>>` loop over one persistent session — type a
// request, watch it work, get the prompt back; `quit` (or Ctrl-D) exits.
//
// First run downloads the chosen model. Tool-call trace goes to stderr; the model's
// answer streams to stdout.

struct Options {
    var route: RouteName = .heavy
    var heavy = "mlx-community/Qwen3-8B-4bit"
    var light = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    var testCommand = ["swift", "test"]
    var useMCP = true
    var verbose = true
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
        case "--verbose": o.verbose = true
        case "--no-verbose": o.verbose = false
        default: rest.append(a)
        }
    }
    guard rest.count >= 1 else {
        FileHandle.standardError.write(Data("usage: code-buddy [options] <workspace-dir> [task...]\n".utf8))
        exit(2)
    }
    o.workspace = rest[0]
    o.task = rest.dropFirst().joined(separator: " ")
    return o
}

func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// Watch SIGINT on a background dispatch queue so the handler fires even while the main
/// thread is parked in `readLine()`. Built in a *non-isolated* function on purpose: a
/// closure formed in `@MainActor` scope gets inferred as main-actor-isolated, and the
/// Dispatch runtime then asserts it runs on the main queue — it doesn't, so the process
/// traps in `_dispatch_assert_queue_fail`. Keeping this here makes the handler plainly
/// `@Sendable`. It only touches `Interrupt` (Sendable), `note`, and `exit`.
func startSigintWatch(_ interrupt: Interrupt) -> any DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    src.setEventHandler {
        if interrupt.fire() {
            note("\nquitting…")
            exit(130)  // process is going away; no @MainActor cleanup to do
        }
        note("\n^C  interrupting this turn — Ctrl-C again to quit")
    }
    src.resume()
    return src
}

/// Ctrl-C policy: the first press during a turn cancels *that turn* and drops back to the
/// prompt; a press at an idle prompt — or a second press during a turn — quits.
final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var turn: Task<Void, Never>?
    private var armed = false  // a turn was already interrupted; next Ctrl-C quits

    func begin(_ t: Task<Void, Never>) { lock.lock(); turn = t; armed = false; lock.unlock() }
    func end() { lock.lock(); turn = nil; armed = false; lock.unlock() }

    /// Handle one Ctrl-C. Returns true if the process should quit now.
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let turn, !armed else { return true }
        turn.cancel()
        armed = true
        return false
    }
}

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
    let tools: [any Tool] = [
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
            case .toolCallStarted(_, let name): if opts.verbose { note("  → \(name)") }
            case .toolCallFinished(_, let name, let failed): if opts.verbose { note("  \(failed ? "✗" : "✓") \(name)") }
            case .contextCompacted(let n): note("  (compacted \(n) transcript entries)")
            default: break
            }
        }
    }

    // Ctrl-C: first press cancels the running turn, a press at an idle prompt quits.
    let interrupt = Interrupt()
    let sigint = startSigintWatch(interrupt)

    // One turn: stream the model's answer to stdout. streamResponse yields snapshots that
    // are *usually* append-only — but not across a tool call, and not when a reasoning
    // model drops its <think> block once the answer proper begins. So diff against what we
    // actually printed: extend it when the snapshot grows, and when a snapshot diverges
    // (new segment) print it whole rather than slicing off its head.
    func ask(_ prompt: String) async {
        do {
            var shown = ""
            for try await partial in session.languageModelSession.streamResponse(to: prompt) {
                let content = partial.content
                if content.isEmpty || content == shown { continue }
                if content.hasPrefix(shown) {
                    print(content.dropFirst(shown.count), terminator: "")
                } else if shown.hasPrefix(content) {
                    continue  // snapshot shrank but we've already shown it
                } else {
                    print(shown.isEmpty ? content : "\n" + content, terminator: "")
                }
                shown = content
                fflush(stdout)
            }
            print()
        } catch is CancellationError {
            note("\n(interrupted — nothing further will run)")
        } catch {
            if Task.isCancelled {
                note("\n(interrupted — nothing further will run)")
            } else {
                note("\nerror: \(await GenerationErrorDescription.describe(error))")
            }
        }
    }

    // Run one turn as a cancellable child Task so the Ctrl-C handler can reach it.
    func turn(_ prompt: String) async {
        let t = Task { await ask(prompt) }
        interrupt.begin(t)
        await t.value
        interrupt.end()
    }

    if !opts.task.isEmpty {
        // One-shot: run the task given on the command line and stop.
        note("\n--- task: \(opts.task) ---\n")
        await turn(opts.task)
    } else {
        // Interactive: one persistent session, a >> prompt per turn, until `quit`/Ctrl-D.
        note("\ncode-buddy — interactive. Type a request; `quit`, Ctrl-D, or Ctrl-C at the prompt to exit.\n")
        while true {
            print(">> ", terminator: "")
            fflush(stdout)
            guard let line = readLine() else { note(""); break }  // EOF / Ctrl-D
            let task = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if task.isEmpty { continue }
            if task == "quit" || task == "exit" { break }
            print()
            await turn(task)
            print()
        }
    }

    sigint.cancel()
    session.cancel()
    await events.value
    note("\ncontext: \(session.contextBudget)")
}

await run()
