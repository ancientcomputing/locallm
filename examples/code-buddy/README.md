# code-buddy

A minimal CLI coding agent built on the **full** LocalLM Lab SDK — the worked example of
**every** model-layer surface (local MLX models through `LocalLMLab`), and of the pattern
where **the host implements process execution itself**, not the SDK.

It's a **plain command-line tool** — no signing, no `.app`, no `packaging/` directory.
`swift run` is the whole build. (It's unsandboxed, which is what lets it own `Process`
execution — see [The host-owned `Process` tools](#the-host-owned-process-tools).)

## Quick start

Do **Getting the SDK & toolchain** below first (Xcode 27 beta + the Metal Toolchain — one-time).
Then, from this directory:

```bash
LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run CodeBuddy . "add a docstring to the main entry point"
```

First run downloads the two xcframeworks, then the chosen model (~4.5 GB for the default
`heavy`). The answer streams to stdout; a tool-call trace goes to stderr.

```
LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run CodeBuddy [options] <workspace-dir> <task...>

  --route heavy|light   which model (default: heavy)
  --heavy <hf-repo>     model for .heavy   (default: mlx-community/Qwen3-8B-4bit)
  --light <hf-repo>     model for .light   (default: mlx-community/Qwen2.5-3B-Instruct-4bit)
  --test-cmd "<cmd>"    command for run_tests (default: "swift test")
  --no-mcp             skip the DeepWiki docs-lookup server
```

## Getting the SDK & toolchain

Copy-paste each step. Steps 1–2 are one-time machine setup; step 3 sets up your terminal session
(re-run it in every new terminal).

**1. Install the Xcode 27 beta.** Download it from
[developer.apple.com/xcode](https://developer.apple.com/xcode/) and drag it to `/Applications`
(it installs as `Xcode-beta.app`, alongside any stable Xcode). A stable Xcode fails with
`'v27' is unavailable` because `Package.swift` requires `platforms: [.macOS("27.0")]`.

**2. Download the Metal Toolchain** — `mlx-swift` compiles Metal shaders and won't build without
it. One-time; safe to re-run:

```bash
xcodebuild -downloadComponent MetalToolchain
```

**3. Set two environment variables** in the terminal you'll build from:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export LOCALLM_SDK_VERSION=1.0.0-beta.1
```

- `DEVELOPER_DIR` makes `swift` use the Xcode 27 beta for this shell. Skip it only if
  `xcode-select -p` already points at `Xcode-beta.app`.
- `LOCALLM_SDK_VERSION` tells `Package.swift` which SDK release to download — this example links
  **two** binaries (`LocalLMLabSDKCore.xcframework` + `LocalLMLabSDKInference.xcframework`, the
  MLX runtime) from that one GitHub Release. Omitting it fails fast with a clear error.

These last only for the current terminal — re-run step 3 in each new terminal (or add both
`export` lines to your `~/.zshrc`).

**4. Build:**

```bash
swift build
```

The first `swift build` downloads the two xcframeworks; the first `swift run` also downloads the
model. Weights land in `~/.cache/huggingface/hub/` — shared with
[`repo-qa-local`](../repo-qa-local/), so a model you already pulled there isn't re-downloaded.

## What it exercises

| SDK surface | Here |
|---|---|
| `LocalLMLab` + `MLXModelProvider` | two routes to locally-run MLX models, `residentModelLimit: 1` |
| `lab.models.route` / `availability` / `validate` / `download` | pre-flight + streamed download on first run |
| `lab.makeSession(route:tools:instructions:)` | resolves route → model, assembles tools |
| Core Workspace tools | `workspaceTree`, `searchWorkspace`, `readWorkspaceFile`, `readFileRange`, `applyPatch`, `editWorkspaceFile`, `writeWorkspaceFile`, `listWorkspaceFiles` |
| `lab.mcp` | one no-auth MCP server (DeepWiki), auto-merged into the session's tools |
| `LocalLMLabSession.events` | the stderr `→ tool` / `✓ tool` trace |
| `session.languageModelSession.streamResponse` | streamed answer |
| `session.contextBudget` | printed at the end |

## Running local models on a memory-constrained Mac

The whole point of `MLXModelProvider` is that a local model competes with everything else for
RAM. code-buddy keeps `residentModelLimit: 1` (one model resident at a time — the SDK evicts
the other on switch) and splits work across `--route heavy` / `--route light`:

- **`--light`** on a tighter machine — `Qwen2.5-3B-4bit` is ~2 GB resident vs `Qwen3-8B-4bit`'s
  ~4.5 GB.
- `lab.models.validate(repoID)` returns a `PreflightResult` with the model's weight + estimated
  resident footprint *before* download — check it against free RAM.
- `MLXModelProvider.residencyEventStream` reports `warmed` / `evicted` / `loadProgress` — wire
  it to a status line to see when the model actually loads vs is reused.

The LocalLM Lab app's AI Models panel surfaces the same signals (a memory-pressure warning per
model, a Compact/Balanced/Full tool-result preset) if you'd rather see it in a UI first.

## The host-owned `Process` tools

`Sources/CodeBuddy/ProcessTools.swift` — **not SDK API**. The SDK deliberately ships no
run-command tool (sandbox + Mac App Store incompatibility). A Developer-ID host implements it:

- **`GitTool`** — runs git in the workspace, but only a read-only subcommand safelist
  (`status` / `diff` / `log` / …). Mutating commands are refused; edits go through `applyPatch`.
  The policy is the host's, not the SDK's.
- **`RunTestsTool`** — runs the host-configured test command (`--test-cmd`), captured with a
  timeout and an output cap.
