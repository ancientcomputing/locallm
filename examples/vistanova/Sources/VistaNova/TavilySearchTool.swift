// A hand-written (Path B) wrapper around Tavily's tavily_search, replacing the auto-assembled
// MCPTool this app used to rely on (includeMCPTools: true). Two things Path A can't give us:
//   1. max_results/search_depth pinned in Swift rather than hoped for via prompt instructions —
//      the model only ever chooses `query`.
//   2. Visibility into the actual query string the model sent, via `capture` — used to show what
//      was really searched (e.g. "yahoo early investors funding history") instead of just
//      re-printing the user's literal typed input as if that were the search term.

import Foundation
import FoundationModels
import LocalLMLabSDKCore

/// Records the query argument each `tavily_search` call actually used. One instance per topic
/// thread's session — sequential turns overwrite it in place, always read right after the turn
/// that produced it.
actor SearchQueryCapture {
    private(set) var query: String?
    func record(_ query: String) { self.query = query }
}

struct TavilySearchTool: Tool {
    let name = "tavily_search"
    let description = "Search the web for a query and return ranked results with source URLs."

    @Generable
    struct Arguments {
        @Guide(description: "The web search query")
        let query: String
    }

    let manager: MCPServerManager
    let serverID: MCPServerID
    let capture: SearchQueryCapture

    func call(arguments: Arguments) async throws -> String {
        await capture.record(arguments.query)
        let result = await manager.callTool(
            server: serverID, tool: "tavily_search",
            arguments: [
                "query": .string(arguments.query),
                "max_results": .number(5),
                "search_depth": .string("basic"),
            ])
        switch result {
        case .success(let toolResult): return toolResult.renderedForModel
        case .failure(let error): return "tavily_search failed: \(error)"
        }
    }
}
