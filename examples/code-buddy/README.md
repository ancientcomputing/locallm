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
- **Keeping one session alive across turns** — omit the task argument and it drops into an
  interactive `>>` loop: the transcript, the warm model, and context compaction all persist
  from one request to the next.

It is **not a product**: even the interactive loop has no history, no editing, no slash
commands. It's the SDK pattern, not an assistant you'd live in.

Mechanically it's a **plain command-line tool** — no signing, no `.app`, no `packaging/`
directory; `swift run` is the whole build. Being an ordinary unsandboxed CLI is also what lets it
run `git` and your test command — see
[The `git` and `run_tests` tools](#the-git-and-run_tests-tools-this-example-provides-them-not-the-sdk).

## How you use it

You run it with a **directory** and, optionally, a **task in plain English**.

```
swift run CodeBuddy <directory> "<task>"     # one-shot: run the task, stop
swift run CodeBuddy <directory>              # interactive: a >> prompt per turn
```

The model may only read and edit files *inside that directory*, using a fixed set of tools —
list / search / read files, apply a patch, write a file, run read-only `git`, run your test
command. Given a task, it works it, narrating as it goes, and stops on its own when it's done.

With no task it enters an interactive loop: type a request at `>>`, watch it work, get the
prompt back, type the next request. One `LocalLMLabSession` spans the whole loop, so later
turns can refer to earlier ones ("now do the same for the other file"). Type `quit` (or press
Ctrl-D) to exit; the final context budget prints on the way out.

**Ctrl-C is graceful, not a kill.** Pressing it while a turn is running cancels *that turn* —
the model stops, a running `run_tests` / `git` child is sent `SIGTERM` rather than left
orphaned, and you drop back to `>>` with the session intact. Pressing it at an idle prompt (or
a second time during a turn) quits. It's wired with `SIG_IGN` + a `DispatchSource` signal
handler; the per-turn cancel reaches the process tools through `withTaskCancellationHandler` in
[`ProcessTools.swift`](Sources/CodeBuddy/ProcessTools.swift).

It **edits files in place.** Always point it at a directory that's committed to git (the
walkthrough below uses a throwaway copy) so you can see the changes with `git diff` and undo them
with `git checkout .`.

## Walkthrough

Do **Getting the SDK & toolchain** below first (install Xcode 27 — one-time).

**About `swift run`:** it must be run from **this package directory**
(`locallm/examples/code-buddy/`, the one with `Package.swift`) — that's how SwiftPM finds and
builds the `CodeBuddy` executable. `CodeBuddy` is the *target name*, not a path. The workspace
you want it to work on is a separate argument and can be anywhere. Every command below shows its
directory as a `# in …` comment.

**1. Copy the sample workspace out of this repo and put it under its own git.** The repo ships a
[`sample-workspace/`](sample-workspace/) — a tiny SwiftPM package (`Geometry`: `Rectangle` +
`area` / `perimeter` / `isSquare` / `scaled`, four passing tests, no doc comments). code-buddy
edits files in place, so a fresh local git repo is how you'll see exactly what it changed.

```bash
# in locallm/examples/code-buddy/
rm -rf /tmp/cb-demo                       # start clean (safe: /tmp is throwaway)
cp -R sample-workspace /tmp/cb-demo
cd /tmp/cb-demo
git init -q && git add -A && git commit -qm "Geometry: initial implementation, tests passing"

# Introduce one regression as a second commit, for the run_tests / git task in step 5:
sed -i '' 's/height: rectangle.height \* factor/height: rectangle.height/' Sources/Geometry/Geometry.swift
git commit -aqm "scaled(): drop a redundant-looking multiply"
cd -                                     # back to locallm/examples/code-buddy/
```

What that does, and doesn't do:

- **`rm -rf /tmp/cb-demo`** clears any leftover from a previous run. `/tmp` is scratch space the
  OS wipes on reboot — nothing you care about lives there.
- **`cp -R`** makes a plain copy of `sample-workspace/` at `/tmp/cb-demo`. Your checkout of
  `locallm` is untouched from here on; the walkthrough only ever writes to `/tmp/cb-demo`.
- **`git init`** creates a `.git/` folder *inside `/tmp/cb-demo`* and nothing else — a brand-new,
  entirely local repo. It doesn't contact a server, doesn't touch the `locallm` repo (a
  different directory tree), and can't "clobber" another repo.
- **The first commit** is the green baseline. **The `sed` + second commit** makes `scaled(_:by:)`
  forget to scale the height — one test (`testScaledScalesBothDimensions`) now fails. That commit
  is what code-buddy hunts down in step 5.

**2. Look at what you're starting with** — `/tmp/cb-demo/Sources/Geometry/Geometry.swift` has
`Rectangle` plus a few `public` declarations, none with doc comments; and after step 1,
`swift test` in `/tmp/cb-demo` reports one failure.

**3. From the package directory, run code-buddy, pointing it at that copy:**

```bash
# in locallm/examples/code-buddy/
swift run CodeBuddy /tmp/cb-demo "In Sources/Geometry/Geometry.swift, add a /// doc comment line above every public declaration (the struct, each stored property, the initializer, both computed properties, and both top-level functions). Each comment should briefly say what that declaration is. Keep every existing line's indentation exactly as it is. Change nothing else."
```

- `CodeBuddy` — the executable target (`swift run` builds it from `Package.swift`).
- `/tmp/cb-demo` — the **workspace**: the only directory the model can read or edit.
- the quoted string — the **task**. One shot: it reads `Geometry.swift` and edits it in place.
  (It won't touch the planted bug — this task is only about comments.)

> **Spell the task out.** A vague ask like *"add doc comments to every public declaration"* sends
> an 8B model into a spiral — *which files? how do I find them? can I bulk-edit?* — and it
> sometimes concludes there's nothing to do. Naming the file, listing what counts, and pinning
> down the mechanics (*"keep the indentation", "change nothing else"*) is the difference between
> a reliable one-shot and a coin flip. Even then a local 8B may write terse comments or nudge a
> line's whitespace — **step 4 is where you check and keep or discard**. This prompt discipline
> is a property of small local models, not a code-buddy quirk; it pays off in `workspace-buddy-local`
> and `aiql` too.

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

**5. Now watch it use `run_tests` and `git`.** First undo step 3's edits so the diff at the end
is just the bug fix:

```bash
git -C /tmp/cb-demo checkout .
```

Then hand code-buddy a task that needs all three tool kinds in one shot — the file tools,
`run_tests`, and `git`:

```bash
# in locallm/examples/code-buddy/
swift run CodeBuddy /tmp/cb-demo \
  "The last commit introduced a one-line bug. Run 'git show HEAD' to see what it changed, run the tests to confirm the failure, fix that one line in Sources/Geometry/Geometry.swift, re-run the tests to confirm all four pass, then run 'git diff' to show the fix."
```

The stderr trace of a successful run (default `--route heavy` — the 8B model; verified):

```
→ git                 git show HEAD  — the "scaled(): drop a redundant-looking multiply" commit
→ run_tests           testScaledScalesBothDimensions … failed  ("3.0" is not equal to "6.0")
→ readWorkspaceFile   Sources/Geometry/Geometry.swift
→ editWorkspaceFile   puts "* factor" back on the height
→ run_tests           Executed 4 tests, with 0 failures
→ git                 git diff  — the one-line fix
```

Confirm it yourself — the workspace is the source of truth, not the model's summary:

```bash
git -C /tmp/cb-demo diff             # the model's uncommitted fix — one line in scaled(_:by:)
( cd /tmp/cb-demo && swift test )    # Executed 4 tests, with 0 failures
```

`git` here is **read-only** — code-buddy exposes `status`, `diff`, `log`, `show`, `blame` and a
few more; `commit` / `checkout` / `reset` are refused (it changes files through `applyPatch` /
`editWorkspaceFile`, never git). `run_tests` runs exactly the `--test-cmd` you pass (default
`swift test`) in the workspace, with a 4-minute timeout. Both are this example's own code, not
the SDK's — see
[The `git` and `run_tests` tools](#the-git-and-run_tests-tools-this-example-provides-them-not-the-sdk).

> The tools are deterministic; the model's ability to chain them is not. The default `heavy`
> (8B) route handles this reliably; `--route light` (3B) is faster but often mangles a multi-step
> edit. If a run stalls or the model narrates instead of acting, Ctrl-C and re-run.

### All options

```
swift run CodeBuddy [options] <workspace-dir> [task...]

  --route heavy|light   which model (default: heavy)
  --heavy <hf-repo>     model for .heavy   (default: mlx-community/Qwen3-8B-4bit)
  --light <hf-repo>     model for .light   (default: mlx-community/Qwen2.5-3B-Instruct-4bit)
  --test-cmd "<cmd>"    command for run_tests (default: "swift test")
  --no-mcp             skip the DeepWiki docs-lookup server
  --no-verbose         hide the per-tool-call trace (shown by default)
```

Omit `[task...]` to enter the interactive `>>` loop instead of running one shot.

`--route light` uses a smaller ~2 GB model instead of ~4.5 GB — start there on a tighter Mac.

## In Xcode

A command-line tool, so there's no `.xcodeproj` to ship (unlike the SwiftUI examples):
**File ▸ Open → `Package.swift`**, pick the **CodeBuddy** scheme, Run — in **Xcode 27 or newer** (macOS 27 target → an older Xcode fails with `'v27' is unavailable`). It
works, with three caveats:

- **Set the arguments in the scheme**: **Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments** —
  the workspace dir and each task word as separate entries.
- **Use an absolute path for `<workspace-dir>`.** Xcode's default working directory is a
  DerivedData folder, not this package, so a relative path resolves to the wrong place. (Or set
  **Edit Scheme ▸ Options ▸ Working Directory**.)
- **The interactive `>>` loop reads stdin** — it works in the Xcode console's input line, but a
  terminal is the more natural home for it. One-shot runs (with a task) are unaffected.

No signing setup — a plain CLI tool signs ad-hoc automatically.

## Getting the SDK & toolchain

Copy-paste each step. Step 1 is one-time machine setup; step 2 sets up your terminal session
(re-run it in every new terminal).

**1. Install Xcode 27.** Get it from the Mac App Store or
[developer.apple.com/xcode](https://developer.apple.com/xcode/).
`Package.swift` requires `platforms: [.macOS("27.0")]`, so an older Xcode fails with `'v27' is unavailable`.

**2. Point `swift` at Xcode 27** for the terminal you'll build from:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Skip it only if `xcode-select -p` already points at Xcode 27; it lasts only for the
current terminal. `Package.swift` builds against SDK `1.0.0-beta.3` with no further setup — it
links **two** binaries (`LocalLMLabSDKCore.xcframework` + `LocalLMLabSDKInference.xcframework`,
the MLX runtime) from that one GitHub Release. `export LOCALLM_SDK_VERSION=<version>` to pin a
different published release. **No Metal Toolchain needed** — the prebuilt Inference xcframework
bundles the compiled `default.metallib`; you only need it if you build the SDK from source.

These last only for the current terminal — re-run step 2 in each new terminal (or add both
`export` lines to your `~/.zshrc`).

**3. Build:**

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
| Host-owned `Process` tools (not from the SDK) | `git` (read-only allow-list) and `run_tests` (`--test-cmd`) in [`ProcessTools.swift`](Sources/CodeBuddy/ProcessTools.swift) — exercised by walkthrough step 5 |
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

code-buddy prints its download progress to stderr by hand to show the raw `mlx.download` stream.
In a SwiftUI app, `Components`' `ModelPickerView` renders the model list, availability badges,
on-disk sizes, the progress bar, and an "Add from Hugging Face" field from `lab.models` directly
— see [`docs/sdk-guide.md` §11](../../docs/sdk-guide.md#11-components-prebuilt-swiftui-mcp-servers--the-model-layer).

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
