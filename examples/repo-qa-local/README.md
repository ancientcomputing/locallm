# Repo Q&A (local model)

[`repo-qa`](../repo-qa)'s exact setup — a command-line tool that answers questions about a GitHub
repository's own documentation, through [Deepwiki](https://deepwiki.com)'s real, no-auth hosted
MCP server (`https://mcp.deepwiki.com/mcp`) and Core's `MCPTool` (Path A — see
[`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own)).
The one difference: the answer comes from an **open-weight model you download and run locally**
(via MLX), routed through the 1.0 **model layer**, instead of Apple's on-device model.

It's the smallest possible model-layer + MLX example. For the full version — routing between
models, Workspace tools, streamed output, a real agent loop — see [`code-buddy`](../code-buddy).

> **Want the on-device-model version instead?** [`repo-qa`](../repo-qa) is this exact tool with
> `SystemLanguageModel.default` and no model layer. Diff the two `main.swift`s to see what the
> model layer adds — it's about 20 lines.

## Quick start

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.1 \
  swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
```

First run downloads the model (~4.5 GB for the default, `mlx-community/Qwen3-8B-4bit`); after that
it's local and offline.

## Getting the SDK & toolchain

- **macOS 27 + the Xcode 27 beta.** `Package.swift` is `platforms: [.macOS("27.0")]`; a stable
  Xcode fails with `'v27' is unavailable`. Point `DEVELOPER_DIR` at the beta:
  `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- **`LOCALLM_SDK_VERSION`** — `Package.swift` resolves the SDK xcframeworks from a GitHub Release
  keyed on this env var. Set it to `1.0.0-beta.1` (this branch's version); omitting it, or an
  unknown value, fails fast with a clear error.
- **Two SDK binaries.** Unlike `repo-qa` (Core only), this links `LocalLMLabSDKCore.xcframework`
  **and** `LocalLMLabSDKInference.xcframework` (the MLX runtime), both from the same Release —
  see `Package.swift`.
- **Metal Toolchain** — `mlx-swift` compiles Metal shaders. One-time:
  `xcodebuild -downloadComponent MetalToolchain`.
- **Disk + RAM for the model.** `Qwen3-8B-4bit` is ~4.5 GB on disk;
  `MLXModelProvider.validate` refuses a model whose weights exceed ~70% of physical RAM. See
  [`docs/tested-models.md`](../../docs/tested-models.md) for which open-weight models tool-call
  reliably.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.1 swift build
```

## Running it

```bash
swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
swift run RepoQALocal facebook/react                 # no question → "what does this repo do?"
swift run RepoQALocal --model mlx-community/Qwen2.5-3B-Instruct-4bit apple/swift-nio "..."
swift run RepoQALocal --apple anthropics/claude-code "..."   # route to Apple's on-device model instead
```

## Output — answer on stdout, everything else on stderr

Run it in a terminal and you see everything; nothing to enable. The streams are split on purpose:

- **stdout** — *only* the model's final answer.
- **stderr** — `model: …`, download `%`, `Connecting to Deepwiki…`, the tool list, `Asking: …`,
  errors.

So you can keep just the answer:

```bash
swift run RepoQALocal facebook/react 2>/dev/null           # just the answer to the terminal
swift run RepoQALocal facebook/react > answer.md            # save the answer, watch progress live
swift run RepoQALocal facebook/react 2>&1 | tee run.log     # capture the whole run
```

(`2>/dev/null` = throw away stderr; `>` redirects stdout; `2>&1` merges stderr into stdout.)

## What the model layer adds (diff against `repo-qa`)

The Deepwiki / `MCPTool` half of `main.swift` is a verbatim copy of `repo-qa` — connecting,
building an `MCPTool` per tool from its live schema, excluding `read_wiki_contents` (same
reasons; see `repo-qa`'s README). The only differences:

| `repo-qa` | `repo-qa-local` |
|---|---|
| `import LocalLMLabSDKCore` | `+ import LocalLMLabSDKInference` |
| `SystemLanguageModel.default` availability check | `MLXModelProvider` + `LocalLMLab` + `lab.models.route(.local, to: …)` |
| — | `mlx.validate` → `mlx.download` (streamed) if the weights aren't local yet |
| `LanguageModelSession(tools: tools) { instructions }` | `lab.makeSession(route: .local, tools: tools, instructions:)` |
| `session.respond(to:)` | `session.languageModelSession.respond(to:)` — same FoundationModels session underneath |

That's the point: the model layer is a swap-in, not a rewrite.

## Verified live

```
model: mlx:mlx-community/Qwen3-8B-4bit  ·  SDK 1.0.0-beta.1
Connecting to Deepwiki…
Skipping read_wiki_contents: excluded by this example.
Built 2 tool(s) from Deepwiki's live schema: ask_question, read_wiki_structure

Asking: Regarding the GitHub repository "facebook/react": What does this repo do?

<think>… the response provided a detailed breakdown of the React monorepo structure … </think>

The **facebook/react** repository is the **monorepo for React**, a JavaScript library for
building user interfaces. [...]
```

A real, unmocked run — Qwen3-8B-4bit called Deepwiki's `ask_question` and answered from the
repo's actual docs. (The `<think>…</think>` block is the model's own reasoning; the 1.0-beta MLX
bridge streams it through inline — carve it out consumer-side if you want a clean answer.) The
`--apple` path was confirmed the same way against the on-device model.

## More

- [`repo-qa`](../repo-qa) — the on-device-model original this is a twin of.
- [`code-buddy`](../code-buddy) — the model layer end to end.
- [`docs/sdk-guide.md` §6a](../../docs/sdk-guide.md#6a-the-model-layer-local-models-routing-sessions) —
  the model layer, in prose.
- [`docs/tested-models.md`](../../docs/tested-models.md) — which open-weight models tool-call.
