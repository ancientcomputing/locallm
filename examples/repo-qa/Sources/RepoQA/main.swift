// Repo Q&A — a third reference app, deliberately different in shape from plate-today/
// plate-today-tools: a plain command-line tool, not a signed GUI .app. Where plate-today
// demonstrates Calendar/Reminders (TCC-gated, needs a real bundle + entitlements to get a
// permission prompt at all — see that app's own top-of-file comment), this app touches nothing
// TCC-gated: MCP network calls need no macOS permission, so a bare `swift run` binary works
// end to end, no packaging/ directory, no code signing, no Info.plist. That's the point of this
// example existing separately rather than as a third tool bolted onto plate-today-tools — it
// shows Core's MCPTool (Path A — see docs/sdk-guide.md §7a) in its simplest possible setting.
//
// Narrative: ask a free-form question about any public GitHub repository's own documentation,
// answered by Apple's on-device model calling Deepwiki's real hosted MCP server
// (https://mcp.deepwiki.com/mcp, no auth, no API key) — MCPTool built at runtime directly from
// Deepwiki's own JSON Schema, no hand-written Arguments struct for any of its three tools.
//
//   swift run RepoQA anthropics/claude-code "What is the plugin system?"
//   swift run RepoQA facebook/react                      # defaults to a general "what is this?" question

import Foundation
import FoundationModels
import LocalLMLabSDKCore

@available(macOS 26.0, *)
@MainActor
func run() async {
    let arguments = CommandLine.arguments.dropFirst()
    guard let repoName = arguments.first, !repoName.isEmpty else {
        FileHandle.standardError.write(Data("""
        usage: swift run RepoQA <owner/repo> [question]
        example: swift run RepoQA anthropics/claude-code "What is the plugin system?"

        """.utf8))
        exit(1)
    }
    let question = arguments.dropFirst().joined(separator: " ")
    let effectiveQuestion = question.isEmpty ? "What does this repository do, in a couple sentences?" : question

    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        print("On-device model unavailable: \(model.availability)")
        return
    }

    // No requestAccess() call anywhere in this file — MCP is the one connector type that was
    // never TCC-gated (see docs/sdk-guide.md's Connectors section vs. its MCP section), so
    // there's no permission step to request before connecting. Contrast with
    // plate-today-tools' requestConnectorAccess(), needed there specifically because Calendar/
    // Reminders are gated and this file's equivalent tools aren't.
    let manager = MCPServerManager()
    print("Connecting to Deepwiki...")
    let connectResult = await manager.addServer(
        url: URL(string: "https://mcp.deepwiki.com/mcp")!,
        displayName: "Deepwiki"
    )
    guard case .success(let state) = connectResult else {
        print("Could not connect to Deepwiki: \(connectResult)")
        return
    }

    // Builds a Tool for every tool Deepwiki actually offers, from its own live schema — nothing
    // here names "ask_question" or "read_wiki_structure" specifically, or knows their argument
    // shapes in advance. Deepwiki happens to expose three tools today (ask_question,
    // read_wiki_contents, read_wiki_structure); this loop would adapt to two or ten just as well.
    // A tool whose schema doesn't build (MCPTool's init throws) is skipped with a warning rather
    // than aborting the whole run — see docs/sdk-guide.md §7a's note on why that's the right
    // default for a loop like this.
    var tools: [any Tool] = []
    for descriptor in state.tools {
        do {
            tools.append(try MCPTool(descriptor: descriptor, manager: manager))
        } catch {
            print("Skipping \(descriptor.name): \(error)")
        }
    }
    guard !tools.isEmpty else {
        print("Deepwiki didn't offer any usable tools.")
        return
    }
    print("Built \(tools.count) tool(s) from Deepwiki's live schema: \(tools.map(\.name).joined(separator: ", "))")

    let session = LanguageModelSession(tools: tools) {
        "You answer questions about GitHub repositories using the documentation tools available to you. Always ground your answer in what the tools actually return — don't answer from general knowledge if a tool call would give a more specific, current answer."
    }

    let prompt = "Regarding the GitHub repository \"\(repoName)\": \(effectiveQuestion)"
    print("\nAsking: \(prompt)\n")

    do {
        let response = try await session.respond(to: prompt)
        print(response.content)
    } catch {
        print("Error: \(await GenerationErrorDescription.describe(error))")
    }
}

if #available(macOS 26.0, *) {
    await run()
} else {
    print("Requires macOS 26 or later.")
}
