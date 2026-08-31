# code-buddy

A minimal CLI coding agent built on the **full** LocalLM Lab SDK — the worked example of
**every** model-layer surface (local MLX models through `LocalLMLab`), and of the pattern
where **the host implements process execution itself**, not the SDK.

It's a **plain command-line tool** — no signing, no `.app`, no `packaging/` directory.
`swift run` is the whole build. Being unsandboxed is also what lets it run `git` and your test
command — see [The `git` and `run_tests` tools](#the-git-and-run_tests-tools-this-example-provides-them-not-the-sdk).

## What it does

You give it a **directory** and a **task in plain English**. It loads a local open-weight model
(nothing leaves your Mac), lets that model explore the directory and edit files in it through a
fixed set of tools — list/search/read files, apply a patch, write a file, run `git status`/`diff`,
run your test command — and stops when the model says the task is done. Think "one focused coding
task, run to completion," not an interactive chat.

It **edits files in place.** Point it at a directory that's committed to git (or a throwaway
copy) so you can `git diff` the result and `git checkout .` if you don't like it.

## Quick start

Do **Getting the SDK & toolchain** below first (Xcode 27 beta + the Metal Toolchain — one-time).
Then, from a directory you don't mind it changing:

```bash
# in some scratch git repo — e.g. a fresh `swift package init`
LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run CodeBuddy . "add a doc comment to every public function"
```

- `.` — the **workspace**: the directory the model may read and edit. It can't touch anything
  outside it.
- `"add a doc comment…"` — the **task**. One shot; it plans, calls tools, and reports back.

While it runs, the model's answer streams to **stdout** and a live tool-call trace
(`→ readWorkspaceFile`, `✓ applyPatch`, …) goes to **stderr**. When it finishes, inspect what it
did with `git diff`.

First run downloads the two xcframeworks, then the model (~4.5 GB for the default `heavy` route).

### All options

```
LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run CodeBuddy [options] <workspace-dir> <task...>

  --route heavy|light   which model (default: heavy)
  --heavy <hf-repo>     model for .heavy   (default: mlx-community/Qwen3-8B-4bit)
  --light <hf-repo>     model for .light   (default: mlx-community/Qwen2.5-3B-Instruct-4bit)
  --test-cmd "<cmd>"    command for run_tests (default: "swift test")
  --no-mcp             skip the DeepWiki docs-lookup server
```

`--route light` uses a smaller ~2 GB model instead of ~4.5 GB — start there on a tighter Mac.

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

## The `git` and `run_tests` tools (this example provides them, not the SDK)

**Background.** A "tool" here is a small Swift type conforming to `Tool` that you put in the
`tools:` array you hand to `lab.makeSession(...)`. The model never runs code itself — when it
wants to use a tool it emits a structured request ("call `git` with `status`"), *your program*
runs it, and the result goes back to the model. code-buddy's `tools:` array (see
`Sources/CodeBuddy/main.swift`) has three kinds:

1. **Workspace file tools from the SDK** — `ReadWorkspaceFileTool`, `ApplyPatchTool`,
   `SearchWorkspaceTool`, and the rest. These only touch files (via `FileManager`), scoped to
   the workspace directory. The SDK ships them because they're safe to run anywhere, including
   inside the App Sandbox and the Mac App Store.
2. **`git` and `run_tests`** — these *launch other programs* (`/usr/bin/git`, `swift test`)
   using Swift's `Process`. The SDK does **not** ship these, for two reasons:
   - **The App Sandbox forbids launching subprocesses.** Any app shipped through the Mac App
     Store must run in the sandbox, and a sandboxed app calling `Process` to run `git` is
     blocked by the OS. If the SDK shipped a "run a command" tool it would be broken code for
     every App Store app — so it leaves that to you.
   - **It's a safety decision that should be yours.** Letting an LLM run commands on your
     machine needs limits, and those limits depend on your app. The SDK doesn't hand you one
     and imply it's blessed.
3. **MCP tools** — added automatically from the DeepWiki server (unless `--no-mcp`).

**So `git` and `run_tests` are implemented in this example's own source**, not in the SDK.
`Sources/CodeBuddy/ProcessTools.swift` (~100 lines) defines two ordinary structs, `GitTool` and
`RunTestsTool`, that conform to `Tool` and call `Process`. `main.swift` creates one of each and
puts them in the `tools:` array. Nothing is generated at runtime and the model has no say in
what they do — the behaviour is fixed Swift code compiled into the `CodeBuddy` binary. When the
docs say *"the policy is the host's,"* "the host" means **the application that links the SDK**
(here, this example), and "the policy" means **rules written into that application's source by
whoever builds it** — for instance, in `ProcessTools.swift`:

- **`git`** — the allowed subcommands are a hardcoded `Set<String>` (`status`, `diff`, `log`,
  `show`, `blame`, …). If the model asks to run `commit`, `push`, `checkout`, or `reset`, the
  `call(...)` method checks that set, doesn't run git, and returns the string *"Refused: not an
  allowed read-only git subcommand."* The model can only pick a subcommand and its arguments; it
  can't add to the set. It changes files through `ApplyPatchTool`, never through git, so your
  commit history is never touched.
- **`run_tests`** — runs *exactly* the command you passed as `--test-cmd` (default `swift test`),
  in the workspace directory, with a 4-minute timeout and output truncated at 20 000 characters,
  all set as constants in that struct. The model can pass an optional test-name filter and
  nothing else.
- Both set the subprocess's working directory to the workspace path; neither builds a command
  from a free-form string the model supplied.

Want different rules — more git subcommands, a longer timeout, an extra `swiftformat` tool? You
(the developer) edit `ProcessTools.swift` and rebuild. The SDK is not involved either way.

**Building a Mac App Store app?** You can't ship `git` / `run_tests` this way — the sandbox
blocks it. Drop those two from the `tools:` array; the model keeps every workspace file tool and
can still read, search, and patch. Running tests or git from a sandboxed app needs a separate
design (a helper process outside the sandbox), which is beyond this example.
