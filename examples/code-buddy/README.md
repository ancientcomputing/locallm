# code-buddy

**code-buddy is a small command-line coding assistant that runs entirely on your Mac.** A local
open-weight model — downloaded once from Hugging Face — reads and edits files in a project
directory you point it at. No cloud service, no API key, nothing leaves the machine.

It exists as a **reference example for the LocalLM Lab SDK**. If you're thinking about building
your own Mac app where a local model does real work — not just chat, but calling tools, editing
files, running commands — this is that whole pattern end to end, in a few hundred lines of Swift
you can read in one sitting. Concretely it shows:

- **Running an open-weight model locally** through the SDK's *model layer* — you name a Hugging
  Face repo, the SDK checks it against this Mac's memory, downloads it with a progress bar, and
  runs it. Swappable per run (`--route heavy` / `--route light`).
- **Giving the model tools it can call** — the file tools the SDK ships (read, search, patch,
  write a file), *plus* two more (`git`, `run_tests`) that are just extra Swift files in this
  example's source, to show how you add abilities the SDK deliberately doesn't include.
- **Driving one task to completion** — stream the model's output, print a trace of every tool
  call, stop when the model says it's finished.

It is **not a product and not an interactive chatbot**: you give it one task, it runs, it stops.

Mechanically it's a **plain command-line tool** — no signing, no `.app`, no `packaging/`
directory; `swift run` is the whole build. Being an ordinary unsandboxed CLI is also what lets it
run `git` and your test command — see
[The `git` and `run_tests` tools](#the-git-and-run_tests-tools-this-example-provides-them-not-the-sdk).

## How you use it

You run it with two arguments: a **directory** and a **task in plain English**.

```
swift run CodeBuddy <directory> "<task>"
```

The model may only read and edit files *inside that directory*, using a fixed set of tools —
list / search / read files, apply a patch, write a file, run read-only `git`, run your test
command. It works the task, narrating as it goes, and stops on its own when it's done.

It **edits files in place.** Always point it at a directory that's committed to git (the
walkthrough below uses a throwaway copy) so you can see the changes with `git diff` and undo them
with `git checkout .`.

## Walkthrough

Do **Getting the SDK & toolchain** below first (Xcode 27 beta + the Metal Toolchain — one-time).

**About `swift run`:** it must be run from **this package directory**
(`locallm/examples/code-buddy/`, the one with `Package.swift`) — that's how SwiftPM finds and
builds the `CodeBuddy` executable. `CodeBuddy` is the *target name*, not a path. The workspace
you want it to work on is a separate argument and can be anywhere. Every command below shows its
directory as a `# in …` comment.

**1. Copy the sample workspace out of this repo and put it under its own git.** The repo ships a
[`sample-workspace/`](sample-workspace/) with one undocumented Swift file. code-buddy edits files
in place, and a fresh one-commit git repo is how you'll see exactly what it changed (step 4).

```bash
# in locallm/examples/code-buddy/
rm -rf /tmp/cb-demo                       # start clean (safe: /tmp is throwaway)
cp -R sample-workspace /tmp/cb-demo
git -C /tmp/cb-demo init -q && git -C /tmp/cb-demo add -A && git -C /tmp/cb-demo commit -qm "before code-buddy"
```

What those three lines do, and don't do:

- **`rm -rf /tmp/cb-demo`** clears any leftover from a previous run. `/tmp` is scratch space the
  OS wipes on reboot — nothing you care about lives there.
- **`cp -R`** makes a plain copy of `sample-workspace/` at `/tmp/cb-demo`. Your checkout of
  `locallm` is untouched from here on; the walkthrough only ever writes to `/tmp/cb-demo`.
- **`git -C /tmp/cb-demo init`** creates a `.git/` folder *inside `/tmp/cb-demo`* and nothing
  else — it's a brand-new, empty, entirely local repo. It doesn't contact a server, doesn't
  touch the `locallm` repo (that's a different directory tree), and can't "clobber" another repo.
  If you somehow re-ran it on a dir that already had a `.git/`, git would just say
  "Reinitialized" and leave your history intact — but the `rm -rf` above means you always get a
  clean one here.
- **`git add -A` + `git commit`** record the copied file as commit #1. That baseline is the
  before-picture `git diff` compares against in step 4.

**2. Look at what you're starting with** — `/tmp/cb-demo/Geometry.swift` has `Rectangle` plus a
few `public` functions, none with doc comments.

**3. From the package directory, run code-buddy, pointing it at that copy:**

```bash
# in locallm/examples/code-buddy/
LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run CodeBuddy /tmp/cb-demo "add a /// doc comment to every public declaration"
```

- `CodeBuddy` — the executable target (`swift run` builds it from `Package.swift`).
- `/tmp/cb-demo` — the **workspace**: the only directory the model can read or edit.
- the quoted string — the **task**. One shot: it lists files, reads `Geometry.swift`, applies a
  patch, and reports back.

While it runs, its narration (including a lot of visible "thinking" — these small models are
verbose) streams to **stdout**, and a tool-call trace (`→ readWorkspaceFile`, `✓ applyPatch`, …)
goes to **stderr**. First run also downloads the two xcframeworks and the model (~4.5 GB for the
default `heavy` route).

**4. Review what it did** in the workspace — this is the real result, not the model's summary:

```bash
# anywhere
git -C /tmp/cb-demo diff
```

You should see `///` lines added above `area`, `perimeter`, `isSquare(_:)`, `scaled(_:by:)`, etc.
Keep it (`git -C /tmp/cb-demo commit -am kept`), tweak it, or throw it away
(`git -C /tmp/cb-demo checkout .`). Re-run step 3 with a different task to keep experimenting.

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
