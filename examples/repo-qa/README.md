# Repo Q&A

The SDK's simplest reference app: a plain command-line tool that answers questions about a GitHub
repository's own documentation, through [Deepwiki](https://deepwiki.com)'s real, no-auth hosted
MCP server (`https://mcp.deepwiki.com/mcp`) and Core's `MCPTool` (Path A — see
[`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own)).
The answer comes from **Apple's on-device model** (`SystemLanguageModel.default` + a plain
`LanguageModelSession` — no model layer).

No `packaging/` directory, no code signing, no Info.plist — MCP is a plain network call, no macOS
permission involved, so a bare `swift run` works end to end. (Contrast `plate-today`, whose
Calendar/Reminders access needs a signed `.app` just to get a permission prompt.) It shows
`MCPTool` adapting to a server it's never seen before: `ask_question` and `read_wiki_structure`
are wrapped from Deepwiki's own live JSON Schema in a loop, nothing hand-coded per tool.

> **Want the answer to come from a model you download and run locally instead?**
> [`repo-qa-local`](../repo-qa-local) is this exact tool with an open-weight MLX model
> (`mlx-community/Qwen3-8B-4bit` by default) routed through the 1.0 model layer — the smallest
> possible model-layer + MLX example. Diff the two `main.swift`s to see what the model layer adds.

## Quick start

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.1 \
  swift run RepoQA anthropics/claude-code "What is the plugin system?"
```

## Getting the SDK & toolchain

- **macOS 27 + the Xcode 27 beta.** `Package.swift` is `platforms: [.macOS("27.0")]`; a stable
  Xcode fails with `'v27' is unavailable`. Point `DEVELOPER_DIR` at the beta:
  `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- **`LOCALLM_SDK_VERSION`** — `Package.swift` resolves `LocalLMLabSDKCore.xcframework` from a
  GitHub Release keyed on this env var. Set it to `1.0.0-beta.1`;
  omitting it, or an unknown value, fails fast with a clear error listing what it knows.
  (`MCPTool`, this app's whole point, first shipped in SDK `0.8.0`, but on macOS 27 you use
  `1.0.0-beta.1+`.)

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.1 swift build
```

## Running it

A bare `swift run` is the real, intended way to use this app — not just a dev-loop shortcut.

```bash
swift run RepoQA anthropics/claude-code "What is the plugin system?"
swift run RepoQA facebook/react                 # no question → "what does this repo do?"
```

## Output — answer on stdout, everything else on stderr

Run it in a terminal and you see everything; nothing to enable. The streams are split on purpose:

- **stdout** — *only* the model's final answer.
- **stderr** — `Connecting to Deepwiki…`, the tool list, `Asking: …`, errors.

So you can keep just the answer:

```bash
swift run RepoQA facebook/react 2>/dev/null           # just the answer to the terminal
swift run RepoQA facebook/react > answer.md            # save the answer, watch progress live
swift run RepoQA facebook/react 2>&1 | tee run.log     # capture the whole run
```

(`2>/dev/null` = throw away stderr; `>` redirects stdout; `2>&1` merges stderr into stdout.)

## Why only two of Deepwiki's three tools

`read_wiki_contents` is skipped by name. It dumps a repo's entire wiki, unscoped — confirmed live
at 541,359 characters (~165,000 tokens) for `anthropics/claude-code` alone, **~20x** Apple's
on-device model's whole ~8,000-token context. The model has no way to know that from the tool's
name/description, and picked it for a plain "what is the plugin system?" question in testing,
hard-failing the session.

`MCPTool` can't know a tool's real-world response size from its JSON Schema (schema describes
shape, not payload size) — that curation is the integrating app's job, exactly as
[`docs/sdk-guide.md` §3](../../docs/sdk-guide.md#3-connecting-to-an-mcp-server-three-auth-options-and-how-to-pick-between-them)
warns ("don't naively pass all of them… without picking the ones your prompt actually needs").
The full writeup is in the tool-building loop's comment in `Sources/RepoQA/main.swift`. A tool
whose schema doesn't build is skipped with a warning, not fatal.

## Verified live

```
Connecting to Deepwiki…
Skipping read_wiki_contents: excluded by this example — see the comment above.
Built 2 tool(s) from Deepwiki's live schema: ask_question, read_wiki_structure

Asking: Regarding the GitHub repository "anthropics/claude-code": What is the plugin system?

Based on the GitHub repository "anthropics/claude-code," the plugin system is part of the
"Core Systems" section. It includes features like the Agent System & Subagents, Tool System &
Permissions, Context Window & Compaction, Hook System, MCP Server Integration, and more. [...]
```

A real, unmocked run against a published SDK release — Deepwiki's `ask_question` answered from
the repo's actual documentation, not the model's training knowledge. Also confirmed against
`facebook/react`, and confirmed `read_wiki_contents` was the real cause of a live context-overflow
failure before it was excluded.

## More

- [`repo-qa-local`](../repo-qa-local) — this tool with a locally-run MLX model instead of the
  on-device one (the model layer).
- [`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own) —
  `MCPTool` and the Path A / Path B framing, in prose.
- [`plate-today-tools`](../plate-today-tools) — `MCPTool` again, against an OAuth-gated server
  (Todoist), inside a signed GUI app.
- [`components-demo`](../components-demo) — the MCP server picker *UI*, for managing connections
  interactively.
