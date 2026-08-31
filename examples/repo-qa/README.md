# Repo Q&A

**Repo Q&A** is a tiny command-line program: you give it a GitHub repository and a question, and
it answers *from that repo's own documentation* — not from whatever the model happened to pick up
in training.

It does this by connecting to **[Deepwiki](https://deepwiki.com)**, a public service that has
already read and indexed thousands of GitHub repos. Deepwiki exposes that as an **MCP server** —
a standard way for an online service to offer an AI model a set of callable "tools" (here: "look
up this repo's structure", "ask a question about this repo"). Repo Q&A hands your question to
Apple's on-device model and lets it call those tools to look things up. The model runs entirely
on your Mac; only the Deepwiki lookups go over the network, and Deepwiki needs no account or API
key.

**What it highlights for SDK developers:**

- **The smallest possible SDK program.** No `packaging/` directory, no code signing, no
  `Info.plist`, no macOS permission prompt — talking to a public MCP server is just a network
  call, so a bare `swift run` runs it end to end. (Compare [`plate-today`](../plate-today), which
  needs a signed `.app` just to ask for Calendar access.)
- **`MCPTool` — using a server you didn't build.** You write no per-tool code. The SDK reads the
  server's own live description of its tools and builds a callable tool for each one, in a loop —
  point the same code at a different MCP server and it adapts. (This is "Path A" — ready-made
  tools from Core; see [`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own).)
- **Why you still choose which tools to expose.** Deepwiki offers three tools; this app
  deliberately wires up only two. The third returns an entire repo wiki in one go — far more
  text than the model can hold — and nothing in the tool's description says so. Deciding which
  tools your prompt actually needs is the app's job, not the SDK's (details in
  [*Why only two of Deepwiki's three tools*](#why-only-two-of-deepwikis-three-tools) below).

The answer comes from Apple's on-device model — no model download, works offline apart from the
Deepwiki calls.

> **Want the answer to come from a model you download and run locally instead?**
> [`repo-qa-local`](../repo-qa-local) is this exact tool with an open-weight MLX model
> (`mlx-community/Qwen3-8B-4bit` by default) routed through the 1.0 model layer — the smallest
> possible model-layer + MLX example. Diff the two `main.swift`s to see what the model layer adds.

## Quick start

Do **Getting the SDK & toolchain** below first (you need the Xcode 27 beta — one-time). Then,
from this directory:

```bash
swift run RepoQA anthropics/claude-code "What is the plugin system?"
```

## Getting the SDK & toolchain

Copy-paste each step. Step 1 is one-time machine setup; step 2 sets up your terminal session
(re-run it in every new terminal).

**1. Install the Xcode 27 beta.** Download it from
[developer.apple.com/xcode](https://developer.apple.com/xcode/) and drag it to `/Applications`
(it installs as `Xcode-beta.app`, alongside any stable Xcode). This example needs it — a stable
Xcode fails with `'v27' is unavailable` because `Package.swift` requires `platforms: [.macOS("27.0")]`.

**2. Set two environment variables** in the terminal you'll build from:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export LOCALLM_SDK_VERSION=1.0.0-beta.1
```

- `DEVELOPER_DIR` makes `swift` use the Xcode 27 beta for this shell (leaves your system default
  alone).
- `LOCALLM_SDK_VERSION` tells `Package.swift` which SDK release to download `LocalLMLabSDKCore.xcframework`
  from. Omitting it fails fast with a clear error listing what it knows. (`MCPTool`, this app's
  whole point, first shipped in SDK `0.8.0`, but on macOS 27 you use `1.0.0-beta.1+`.)

These last only for the current terminal — re-run step 2 in each new terminal (or add both
`export` lines to your `~/.zshrc`).

**3. Build:**

```bash
swift build
```

The first `swift build` (or `swift run`) downloads the xcframework.

## Running it

Assumes the two `export`s from step 2 are set in this terminal. A bare `swift run` is the real,
intended way to use this app — not a dev-loop shortcut.

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
