// repo-qa-local — repo-qa, but the answer comes from an open-weight model you download and run
// locally (via MLX) instead of Apple's on-device model. The Deepwiki / MCPTool half is a
// verbatim copy of repo-qa's; the only difference is the ~20 lines that set up the 1.0 model
// layer and swap `LanguageModelSession(tools:)` for `lab.makeSession(route:tools:)`.
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
    let mlx = MLXModelProvider(residentModelLimit: 1)
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

    // --- everything below is repo-qa, unchanged ---

    let manager = MCPServerManager()
    note("Connecting to Deepwiki…")
    let connectResult = await manager.addServer(
        url: URL(string: "https://mcp.deepwiki.com/mcp")!,
        displayName: "Deepwiki"
    )
    guard case .success(let state) = connectResult else {
        note("Could not connect to Deepwiki: \(connectResult)"); return
    }

    // Build a Tool for each of Deepwiki's tools from its own live schema. `read_wiki_contents` is
    // skipped by name: it dumps a repo's entire wiki unscoped (~165K tokens for anthropics/
    // claude-code in one call), which `MCPTool` can't know from the schema — that curation is the
    // app's job (see docs/sdk-guide.md §3). A tool whose schema doesn't build is skipped, not fatal.
    var tools: [any Tool] = []
    for descriptor in state.tools {
        guard descriptor.name != "read_wiki_contents" else {
            note("Skipping \(descriptor.name): excluded by this example.")
            continue
        }
        do { tools.append(try MCPTool(descriptor: descriptor, manager: manager)) }
        catch { note("Skipping \(descriptor.name): \(error)") }
    }
    guard !tools.isEmpty else { note("Deepwiki didn't offer any usable tools."); return }
    note("Built \(tools.count) tool(s) from Deepwiki's live schema: \(tools.map(\.name).joined(separator: ", "))")

    // The one line that changes from repo-qa: lab.makeSession(route:tools:) instead of
    // LanguageModelSession(tools:) — same FoundationModels session underneath, just backed by
    // whichever model the route points at.
    let instructions = "You answer questions about GitHub repositories using the documentation tools available to you. Always ground your answer in what the tools actually return — don't answer from general knowledge if a tool call would give a more specific, current answer."
    let session: LocalLMLabSession
    do {
        session = try lab.makeSession(route: .local, tools: tools, instructions: instructions, includeMCPTools: false)
    } catch {
        note("makeSession failed: \(error)"); exit(1)
    }

    let prompt = "Regarding the GitHub repository \"\(repoName)\": \(effectiveQuestion)"
    note("\nAsking: \(prompt)\n")
    do {
        let response = try await session.languageModelSession.respond(to: prompt)
        print(response.content)
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
