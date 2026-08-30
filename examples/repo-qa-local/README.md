# Repo Q&A (local model)

[`repo-qa`](../repo-qa)'s exact setup — a CLI that answers questions about a GitHub repo's docs
through [Deepwiki](https://deepwiki.com)'s no-auth MCP server and Core's `MCPTool` — but the
answer comes from an **open-weight model you download and run locally** (via MLX), routed through
the 1.0 **model layer**, instead of Apple's on-device model.

It's the smallest possible model-layer + MLX example. For the full version (routing between
models, Workspace tools, streamed output, a real agent loop) see [`code-buddy`](../code-buddy).

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.1 \
  swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
```

First run downloads the model (progress on stderr); after that it's local and offline. Default:
`mlx-community/Qwen3-8B-4bit` — see [`docs/tested-models.md`](../../docs/tested-models.md) for
which open-weight models tool-call reliably.

```bash
swift run RepoQALocal facebook/react                                   # default question
swift run RepoQALocal --model mlx-community/Qwen2.5-3B-Instruct-4bit apple/swift-nio "..."
swift run RepoQALocal --apple anthropics/claude-code "..."             # route to Apple's on-device model instead
```

## What the model layer adds (diff against `repo-qa`)

The Deepwiki / `MCPTool` half of `main.swift` is a verbatim copy of `repo-qa`. The only
differences:

| `repo-qa` | `repo-qa-local` |
|---|---|
| `import LocalLMLabSDKCore` | `+ import LocalLMLabSDKInference` |
| `SystemLanguageModel.default` availability check | `MLXModelProvider` + `LocalLMLab` + `lab.models.route(.local, to: …)` |
| — | `mlx.validate` → `mlx.download` (streamed) if the weights aren't local yet |
| `LanguageModelSession(tools: tools) { instructions }` | `lab.makeSession(route: .local, tools: tools, instructions:)` |
| `session.respond(to:)` | `session.languageModelSession.respond(to:)` — same FoundationModels session underneath |

Everything else — connecting to Deepwiki, building an `MCPTool` per tool from its live schema,
excluding `read_wiki_contents` — is identical. That's the point: the model layer is a swap-in,
not a rewrite.

## Requirements

- **macOS 27 + Xcode 27 beta** (the model layer is built on FoundationModels' `LanguageModel`
  protocol) — `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- **Metal Toolchain** (`xcodebuild -downloadComponent MetalToolchain`) — `mlx-swift` compiles
  Metal shaders. One-time.
- Links **two** SDK binaries: `LocalLMLabSDKCore.xcframework` + `LocalLMLabSDKInference.xcframework`
  (the MLX runtime), both from the same GitHub Release — see `Package.swift`.
- Disk + RAM for the model: `Qwen3-8B-4bit` is ~4.5 GB on disk. `MLXModelProvider.validate`
  flags a model whose weights exceed ~70% of physical RAM.

## More

- [`repo-qa`](../repo-qa) — the on-device-model original this is a twin of.
- [`code-buddy`](../code-buddy) — the model layer end to end.
- [`docs/sdk-guide.md` §6a](../../docs/sdk-guide.md#6a-the-model-layer-local-models-routing-sessions) —
  the model layer, prose.
- [`docs/tested-models.md`](../../docs/tested-models.md) — which open-weight models tool-call.
