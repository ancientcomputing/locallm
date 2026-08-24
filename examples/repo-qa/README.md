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
runtime: every tool Deepwiki offers gets wrapped from its own live JSON Schema in a loop, nothing
hand-coded per tool.

Requires macOS 26+ on Apple Silicon with Apple Intelligence enabled.

## Before you build: this needs an SDK version that isn't released yet

Same situation as `plate-today-tools`, same reason: this app's entire point is `MCPTool`
(`MCPToolAdapter.swift`), which postdates the latest published release (`0.7.1`). Building against
`0.7.0`/`0.7.1` fails to compile — `cannot find 'MCPTool' in scope` — not "runs with less
functionality." Published now so the source is readable and diffable immediately; once a release
containing `MCPToolAdapter.swift` ships, add its entry to `Package.swift`'s `knownSDKReleases` and
this builds like any other example. Until then, clone
[`locallmlab-sdk`](https://github.com/ancientcomputing/locallmlab-sdk) privately and build
`examples/repo-qa` there against Core as a source dependency instead — that's exactly how this
example was actually verified live (see below).

## Getting the SDK

```bash
LOCALLM_SDK_VERSION=0.7.1 swift build
```

Same `LOCALLM_SDK_VERSION` mechanism as the other examples — omitting it, or requesting an unknown
version, fails fast with a clear error.

## Running it

No `build-and-sign.sh` step needed — a bare `swift run` is the real, intended way to use this app,
not just a fast dev-loop shortcut like it is for `plate-today`/`plate-today-tools`:

```bash
LOCALLM_SDK_VERSION=0.7.1 swift run RepoQA anthropics/claude-code "What is the plugin system?"
LOCALLM_SDK_VERSION=0.7.1 swift run RepoQA facebook/react   # no question: defaults to "what does this repo do?"
```

## Verified live (private repo, source dependency)

```
Connecting to Deepwiki...
Built 3 tool(s) from Deepwiki's live schema: ask_question, read_wiki_contents, read_wiki_structure

Asking: Regarding the GitHub repository "anthropics/claude-code": What is the plugin system, briefly?

The plugin system in Claude Code allows you to extend its functionality with custom commands,
agents, hooks, and MCP servers. [...]
```

A real, unmocked run — Deepwiki's `ask_question` tool answered from the repository's actual
documentation, not the model's own training knowledge.

## More

- [`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own) —
  the prose walkthrough of `MCPTool` and the Path A/Path B framing.
- [`plate-today-tools`](../plate-today-tools) — `MCPTool` again, this time against an OAuth-gated
  server (Todoist), inside a signed GUI app.
- [`components-demo`](../components-demo) — the MCP server picker *UI*, for managing connections
  interactively rather than wiring one tool programmatically like this app does.
