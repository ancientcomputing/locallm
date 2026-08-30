# code-buddy

A minimal CLI coding agent built on the **full** LocalLM Lab SDK — the worked example of
**every** model-layer surface (local MLX models through `LocalLMLab`), and of the pattern
where **the host implements process execution itself**, not the SDK.

Requires **macOS 27 + Xcode 27**. Links two SDK binaries: `LocalLMLabSDKCore.xcframework`
and `LocalLMLabSDKInference.xcframework` (the MLX runtime — mlx-swift-lm + Metal statically
linked, ~11 MB zipped, downloaded once).

```bash
LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run CodeBuddy [options] <workspace-dir> <task...>

  --route heavy|light   which model (default: heavy)
  --heavy <hf-repo>     model for .heavy   (default: mlx-community/Qwen3-8B-4bit)
  --light <hf-repo>     model for .light   (default: mlx-community/Qwen2.5-3B-Instruct-4bit)
  --test-cmd "<cmd>"    command for run_tests (default: "swift test")
  --no-mcp             skip the DeepWiki docs-lookup server
```

First run downloads the chosen model. The answer streams to stdout; a tool-call trace goes
to stderr.

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
