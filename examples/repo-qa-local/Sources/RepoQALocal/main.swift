// repo-qa-local — repo-qa, but the answer comes from an open-weight model you download and run
// locally (via MLX) instead of Apple's on-device model. The Deepwiki half follows repo-qa's, with
// one change: the MCP server goes into `lab.mcp` (the lab's manager — an app that uses LocalLMLab
// never makes an `MCPServerManager` of its own), and `lab.makeSession(route:)` builds the MCP tools
// from it, instead of repo-qa's own manager + `MCPTool`s + `LanguageModelSession(tools:)`.
//
//   swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
//   swift run RepoQALocal facebook/react                        # default question
//   swift run RepoQALocal --model mlx-community/Qwen2.5-3B-Instruct-4bit apple/swift-nio "..."
//   swift run RepoQALocal --apple anthropics/claude-code "..."  # route to Apple's on-device model instead
//
// First run downloads the model (progress on stderr). Default: mlx-community/Qwen3-8B-4bit —
// see docs/tested-models.md for which open-weight models tool-call reliably.

import Foundation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKInference

func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

@available(macOS 26.0, *)
@MainActor
func run() async {
    // --- args: [--model <repo>] [--apple] <owner/repo> [question...] ---
    var modelRepo = "mlx-community/Qwen3-8B-4bit"
    var useApple = false
    var rest: [String] = []
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--model": if let v = it.next() { modelRepo = v }
        case "--apple": useApple = true
        default: rest.append(a)
        }
    }
    guard let repoName = rest.first, !repoName.isEmpty else {
        note("""
        usage: swift run RepoQALocal [--model <hf-repo>] [--apple] <owner/repo> [question]
        example: swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
        """)
        exit(1)
    }
    let question = rest.dropFirst().joined(separator: " ")
    let effectiveQuestion = question.isEmpty ? "What does this repository do, in a couple sentences?" : question

    // --- the model layer: one MLX provider, Apple's on-device model as an alternative, one route ---
    // Pin the default model to the commit this example was tried against, so a fresh download never
    // silently picks up whatever `main` has become. A model chosen with --model is pinned to the
    // version you first download instead (trust on first use). To change the default, review the
    // new version, then update the repo and its commit together.
    let shippedPins = ["mlx-community/Qwen3-8B-4bit": "545dc4251c05440727734bcd94334791f6ab0192"]
    let mlx = MLXModelProvider(residentModelLimit: 1, pinnedRevisions: shippedPins, pinStore: MLXFilePinStore())
    let lab = LocalLMLab(configuration: .init(providers: [mlx, SystemModelProvider()]))
    let modelID = useApple ? ModelID.system : ModelID(scheme: "mlx", rest: modelRepo)!
    lab.models.route(.local, to: modelID)
    note("model: \(modelID)  ·  SDK \(LocalLMLabSDKVersion.current)")

    // Preflight + download the MLX weights on first run. (Nothing to download for `--apple`.)
    if !useApple, case .notDownloaded = lab.models.availability(for: modelID) {
        if let pre = try? await mlx.validate(modelRepo), !pre.passed {
            note("pre-flight failed (\(pre.failedStage?.rawValue ?? "?")): \(pre.detail ?? "")")
            exit(1)
        }
        note("downloading \(modelRepo)…")
        do {
            for try await event in mlx.download(modelRepo) {
                if case .progress(_, _, let f) = event {
                    FileHandle.standardError.write(Data("\u{1B}[2K\r  \(Int(f * 100))%".utf8))
                }
            }
            note("\u{1B}[2K\r  done")
        } catch {
            note("download failed: \(error)"); exit(1)
        }
    }
    if !useApple, let pin = mlx.effectivePin(for: modelRepo) {
        note("pinned to \(pin.revision.prefix(7)) (\(pin.source == .shipped ? "shipped with this example" : "first download"))")
    }

    // --- the Deepwiki half: repo-qa's, with the server in lab.mcp ---

    note("Connecting to Deepwiki…")
    let connectResult = await lab.mcp.addServer(
        url: URL(string: "https://mcp.deepwiki.com/mcp")!,
        displayName: "Deepwiki"
    )
    guard case .success(let state) = connectResult else {
        note("Could not connect to Deepwiki: \(connectResult)"); return
    }

    // A new server's tools start disabled (a security default: nothing reaches the model until the
    // host opts in), so enable the ones this example uses. `read_wiki_contents` stays off: it dumps
    // a repo's entire wiki unscoped (~165K tokens for anthropics/claude-code in one call), which
    // `MCPTool` can't know from the schema — that curation is the app's job (see
    // docs/sdk-guide.md §3). A tool whose schema doesn't build is skipped, not fatal (makeSession
    // would otherwise fail on it).
    var enabled: [String] = []
    for descriptor in state.tools {
        guard descriptor.name != "read_wiki_contents" else {
            note("Skipping \(descriptor.name): excluded by this example.")
            continue
        }
        do { _ = try MCPTool(descriptor: descriptor, manager: lab.mcp) }
        catch { note("Skipping \(descriptor.name): \(error)"); continue }
        lab.mcp.setToolEnabled(server: state.id, tool: descriptor.name, enabled: true)
        enabled.append(descriptor.name)
    }
    guard !enabled.isEmpty else { note("Deepwiki didn't offer any usable tools."); return }
    note("Enabled \(enabled.count) tool(s) from Deepwiki's live schema: \(enabled.joined(separator: ", "))")

    // Where repo-qa makes `LanguageModelSession(tools:)`, this calls lab.makeSession(route:) — same
    // FoundationModels session underneath, backed by whichever model the route points at, with
    // lab.mcp's enabled tools included (`includeMCPTools`, on by default).
    let instructions = "You answer questions about GitHub repositories using the documentation tools available to you. Always ground your answer in what the tools actually return — don't answer from general knowledge if a tool call would give a more specific, current answer."
    let session: LocalLMLabSession
    do {
        session = try lab.makeSession(route: .local, instructions: instructions, includeMCPTools: true)
    } catch {
        note("makeSession failed: \(error)"); exit(1)
    }

    let prompt = "Regarding the GitHub repository \"\(repoName)\": \(effectiveQuestion)"
    note("\nAsking: \(prompt)\n")
    // The session's own turn method (repo-qa calls `session.respond(to:)` on its
    // LanguageModelSession). Not `session.languageModelSession.respond`: that escape hatch skips
    // the context-overflow retry and the per-turn MCP tool refresh.
    do {
        print(try await session.respond(to: prompt))
    } catch {
        note("Error: \(await GenerationErrorDescription.describe(error))")
    }
    session.cancel()
}

if #available(macOS 26.0, *) {
    await run()
} else {
    print("Requires macOS 26 or later.")
}
