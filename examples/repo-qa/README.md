# Repo Q&A

The SDK's third reference app, and its simplest: a plain command-line tool that answers questions
about a GitHub repository's own documentation, using Apple's on-device model and
[Deepwiki](https://deepwiki.com)'s real, no-auth hosted MCP server
(`https://mcp.deepwiki.com/mcp`) — entirely through Core's `MCPTool` (Path A, see
[`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own)).

```
swift run RepoQA anthropics/claude-code "What is the plugin system?"
```

Different narrative from `plate-today`/`plate-today-tools` on purpose: those two demonstrate
Calendar/Reminders/Todoist, all either TCC-gated or OAuth-gated, needing a signed `.app` bundle
with entitlements just to get a permission prompt. MCP itself has none of that — it's a plain
network call, no macOS permission involved — so this app needs no `packaging/` directory, no code
signing, no Info.plist. It's the shortest path from "nothing" to "the on-device model calling a
real, remote MCP tool," and shows `MCPTool` adapting to a server it's never seen before at
runtime: `ask_question` and `read_wiki_structure` get wrapped from their own live JSON Schema in a
loop, nothing hand-coded per tool.

**One deliberate exclusion, not a demo of the general pattern**: Deepwiki's third tool,
`read_wiki_contents`, is skipped by name. It dumps a repo's entire wiki, unscoped — confirmed live
at 541,359 characters (~165,000 tokens) for `anthropics/claude-code` alone, ~40x this model's whole
4096-token context. The on-device model has no way to know that from the tool's name/description,
and picked it for a plain "what is the plugin system?" question in real testing, hard-failing the
session. `MCPTool` can't know a tool's real-world response size from its JSON Schema — that
judgment call is the integrating app's, same as `docs/sdk-guide.md` §3 already warns generally
("don't naively pass all of them... without picking the ones your prompt actually needs"). See the
comment in `Sources/RepoQA/main.swift` for the full writeup.

Requires macOS 26+ on Apple Silicon with Apple Intelligence enabled.

## Requires SDK 0.8.0+

Same situation as `plate-today-tools`, same reason: this app's entire point is `MCPTool`
(`MCPToolAdapter.swift`), which shipped starting with `0.8.0`. Building against `0.7.0`/`0.7.1`
fails to compile — `cannot find 'MCPTool' in scope` — not "runs with less functionality."

## Getting the SDK

```bash
LOCALLM_SDK_VERSION=0.8.0 swift build
```

Same `LOCALLM_SDK_VERSION` mechanism as the other examples — omitting it, or requesting an unknown
version, fails fast with a clear error.

## Running it

No `build-and-sign.sh` step needed — a bare `swift run` is the real, intended way to use this app,
not just a fast dev-loop shortcut like it is for `plate-today`/`plate-today-tools`:

```bash
LOCALLM_SDK_VERSION=0.8.0 swift run RepoQA anthropics/claude-code "What is the plugin system?"
LOCALLM_SDK_VERSION=0.8.0 swift run RepoQA facebook/react   # no question: defaults to "what does this repo do?"
```

## Verified live

```
Connecting to Deepwiki...
Skipping read_wiki_contents: excluded by this example — see the comment above.
Built 2 tool(s) from Deepwiki's live schema: ask_question, read_wiki_structure

Asking: Regarding the GitHub repository "anthropics/claude-code": What is the plugin system?

Based on the GitHub repository "anthropics/claude-code," the plugin system is part of the
"Core Systems" section. It includes features like the Agent System & Subagents, Tool System &
Permissions, Context Window & Compaction, Hook System, MCP Server Integration, and more. [...]
```

A real, unmocked run against the actual published SDK 0.8.0 release (`LOCALLM_SDK_VERSION=0.8.0`)
— Deepwiki's `ask_question` tool answered from the repository's actual documentation, not the
model's own training knowledge. Also confirmed against `facebook/react`, and confirmed
`read_wiki_contents` was the real cause of a live-reported context-overflow failure before this
exclusion (see the tool-building loop's comment in the source for the full numbers).

## More

- [`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own) —
  the prose walkthrough of `MCPTool` and the Path A/Path B framing.
- [`plate-today-tools`](../plate-today-tools) — `MCPTool` again, this time against an OAuth-gated
  server (Todoist), inside a signed GUI app.
- [`components-demo`](../components-demo) — the MCP server picker *UI*, for managing connections
  interactively rather than wiring one tool programmatically like this app does.
