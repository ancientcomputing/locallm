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
// Deepwiki's own JSON Schema, no hand-written Arguments struct for either tool actually offered
// (see the tool-building loop below for why only two of Deepwiki's three tools are offered).
//
//   swift run RepoQA anthropics/claude-code "What is the plugin system?"
//   swift run RepoQA facebook/react                      # defaults to a general "what is this?" question

import Foundation
import FoundationModels
import LocalLMLabSDKCore

// Status/progress goes to stderr; only the model's final answer goes to stdout, so
// `swift run RepoQA … 2>/dev/null` gives you just the answer. (repo-qa-local does the same.)
func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

@available(macOS 26.0, *)
@MainActor
func run() async {
    let arguments = CommandLine.arguments.dropFirst()
    guard let repoName = arguments.first, !repoName.isEmpty else {
        note("""
        usage: swift run RepoQA <owner/repo> [question]
        example: swift run RepoQA anthropics/claude-code "What is the plugin system?"
        """)
        exit(1)
    }
    let question = arguments.dropFirst().joined(separator: " ")
    let effectiveQuestion = question.isEmpty ? "What does this repository do, in a couple sentences?" : question

    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        note("On-device model unavailable: \(model.availability)")
        return
    }

    // No requestAccess() call anywhere in this file — MCP is the one connector type that was
    // never TCC-gated (see docs/sdk-guide.md's Connectors section vs. its MCP section), so
    // there's no permission step to request before connecting. Contrast with
    // plate-today-tools' requestConnectorAccess(), needed there specifically because Calendar/
    // Reminders are gated and this file's equivalent tools aren't.
    let manager = MCPServerManager()
    note("Connecting to Deepwiki…")
    let connectResult = await manager.addServer(
        url: URL(string: "https://mcp.deepwiki.com/mcp")!,
        displayName: "Deepwiki"
    )
    guard case .success(let state) = connectResult else {
        note("Could not connect to Deepwiki: \(connectResult)")
        return
    }

    // Builds a Tool for each of Deepwiki's tools from its own live schema — nothing here knows
    // ask_question's or read_wiki_structure's argument shapes in advance, MCPTool derives both
    // from the server's real JSON Schema at runtime. One deliberate exclusion, not a schema
    // failure: read_wiki_contents dumps a repo's ENTIRE wiki, unscoped, no pagination — confirmed
    // live against anthropics/claude-code at 541,359 characters (~165,000 tokens) for a single
    // call, ~20x this model's whole ~8,000-token context window. The on-device model has no way to
    // know that in advance from the tool's name/description alone, and picked it for a plain
    // "what is the plugin system?" question in real testing, hard-failing the whole session. This
    // is exactly the risk docs/sdk-guide.md §3 already warns about ("don't naively pass all of
    // them into a LanguageModelSession without picking the ones your prompt actually needs") —
    // MCPTool itself has no way to know a tool's real-world response size from its schema, since
    // JSON Schema describes shape, not payload size; that judgment call is the integrating app's
    // to make, same as everywhere else Core hands you a raw capability and leaves the curation to
    // you. A tool whose schema doesn't build (MCPTool's init throws) is still skipped with a
    // warning rather than aborting the whole run.
    var tools: [any Tool] = []
    for descriptor in state.tools {
        guard descriptor.name != "read_wiki_contents" else {
            note("Skipping \(descriptor.name): excluded by this example — see the comment above.")
            continue
        }
        do {
            tools.append(try MCPTool(descriptor: descriptor, manager: manager))
        } catch {
            note("Skipping \(descriptor.name): \(error)")
        }
    }
    guard !tools.isEmpty else {
        note("Deepwiki didn't offer any usable tools.")
        return
    }
    note("Built \(tools.count) tool(s) from Deepwiki's live schema: \(tools.map(\.name).joined(separator: ", "))")

    let session = LanguageModelSession(tools: tools) {
        "You answer questions about GitHub repositories using the documentation tools available to you. Always ground your answer in what the tools actually return — don't answer from general knowledge if a tool call would give a more specific, current answer."
    }

    let prompt = "Regarding the GitHub repository \"\(repoName)\": \(effectiveQuestion)"
    note("\nAsking: \(prompt)\n")

    do {
        let response = try await session.respond(to: prompt)
        print(response.content)
    } catch {
        note("Error: \(await GenerationErrorDescription.describe(error))")
    }
}

if #available(macOS 26.0, *) {
    await run()
} else {
    print("Requires macOS 26 or later.")
}
