# Workspace Buddy (local model)

**Workspace Buddy (local model)** is the [`workspace-buddy`](../workspace-buddy) app — pick a
folder, type a request, the on-device model reads and edits the files in it — with one change:
instead of Apple's built-in model, it runs an **open-weight model you download from Hugging Face
and run on your Mac's GPU** (`mlx-community/Qwen3-8B-4bit` by default, about 4.5 GB). That's the
same swap [`repo-qa-local`](../repo-qa-local) makes over `repo-qa`, using the SDK's **model
layer**: you name a model, and it checks the model fits in memory, downloads it with a progress
bar, loads it, and hands you a chat session.

**What it highlights for SDK developers.** It's the one example that runs a downloaded model
**inside the App Sandbox** — the combination you need for a Mac App Store app that ships local
inference. Two things follow from that, both shown working here:

- **The model download needs a network entitlement.** A sandboxed app can't make outbound
  connections without `com.apple.security.network.client`; add it, and `MLXModelProvider.download`
  fetches the weights from Hugging Face normally. (`workspace-buddy` needs no network entitlement
  — Apple's model is already on the machine.)
- **The weights land in the app's sandbox container, not `~/.cache`.** swift-huggingface detects
  the sandbox and redirects the cache automatically. The ~4.5 GB counts against this app's
  container and is removed when the app is — details in
  [Where the model is stored](#where-the-model-is-stored).

Verified end to end on a real signed build: the download, the on-disk cache, and the Metal shader
load all work under the sandbox, and the second run starts generating immediately.

> **Want the on-device-model version instead?** [`workspace-buddy`](../workspace-buddy) is this
> exact app with Apple's built-in model — no model layer, no download, no network entitlement.

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

**3. Point `swift` at the Xcode 27 beta** for the terminal you'll build from:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

Leaves your system default alone; lasts only for the current terminal (re-run it in each new one,
or add it to your `~/.zshrc`). `Package.swift` builds against SDK `1.0.0-beta.3` with no further
setup — it links **two** binaries, `LocalLMLabSDKCore.xcframework` and
`LocalLMLabSDKInference.xcframework` (the MLX runtime, which carries its own Metal shaders), from
that one GitHub Release. `export LOCALLM_SDK_VERSION=<version>` to pin a different published release.

**4. Compile-check:**

```bash
swift build
```

This just proves it builds. To *actually run* it: open the Xcode project (next), or make a
signed `.app` with `packaging/build-and-sign.sh` (further below).

## Open in Xcode and Run

A committed `WorkspaceBuddyLocal.xcodeproj` is the lowest-friction way to try it. **Open it in
`Xcode-beta.app`, not a stable Xcode** (the target is macOS 27 → a stable Xcode fails with
`'v27' is unavailable`). Launch `Xcode-beta.app` and **File ▸ Open**, or:

```bash
open -a Xcode-beta WorkspaceBuddyLocal.xcodeproj
```

Pick the **WorkspaceBuddyLocal** scheme and Run — a real sandboxed `.app` with the
`files.user-selected.read-write` and `network.client` entitlements (the model download needs the
latter), the `LocalLMLabSDKInference` (MLX) framework embedded. **First Go downloads the model**
(~4.5 GB for the default); after that it's local and offline.

**Signing.** Set to **Automatic** with no hard-coded team, so Xcode signs with your **Apple
Development** identity. Same reason as `workspace-buddy`: the security-scoped bookmark is bound
to the signing identity and won't survive a rebuild under an ad-hoc one.

| Your Xcode setup | What happens on Run |
|---|---|
| One Apple ID in **Xcode ▸ Settings ▸ Accounts** (**free** is enough) | picked automatically — stable `Apple Development` signing, bookmark persists across rebuilds |
| No Apple ID | Run stops with *"requires a development team"* — add a free Apple ID, **or** target ▸ **Signing & Capabilities** ▸ **Sign to Run Locally** (ad-hoc; runs, but you re-pick the folder each rebuild) |

Only the Xcode Run build is affected. `packaging/build-and-sign.sh` (below) ignores the project
file and signs with whatever `APP_IDENTITY` you pass it.

Generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — edit `project.yml`, not the `.xcodeproj`,
then `xcodegen generate`.

## Running it

Like `workspace-buddy`, a bare `swift run` gets you neither the sandbox nor the
`files.user-selected` entitlement, so it's compile-only. Two ways to get a real, entitled build:

- **The Xcode project above** — the fast path; a locally-signed `.app` to run and iterate on.
- **`packaging/build-and-sign.sh`** — for a `.app` you can hand to another Mac (Developer-ID
  signed and notarizable). It needs a signing identity; a **free "Apple Development"** one is
  enough for a local run (an ad-hoc build won't hold the sandbox grant), a Developer ID for
  distribution. See the
  [signing table in `../README.md`](../README.md#signing-a-app--app_identity).

```bash
APP_IDENTITY="Apple Development: Your Name (TEAMID)" \
NOTARIZE_APP=0 \
  ./packaging/build-and-sign.sh
```

(`DEVELOPER_DIR` and `LOCALLM_SDK_VERSION` come from step 3.) The signed `.app` lands in `dist/`;
open it, click **Choose Folder…**, pick a throwaway directory, type a request, and hit **Go**.
**First Go downloads the model** (~4.5 GB for the default), with a progress bar. After that it's
local and offline — the second run starts generating immediately.

**Prompts to try.** Same tools and instructions as [`workspace-buddy`](../workspace-buddy#about-the-model),
so its prompt list applies here too. Point the app at a throwaway folder with a few small files and
paste one of these — the 8B model handles a bit more per request than Apple's on-device one:

- `Add a triple-slash doc comment above every public function in Sources/, saying what it does.`
- `Rename the type Widget to Gadget everywhere it appears in this folder, including other files that reference it.`
- `In every .swift file, sort the import lines alphabetically.`
- `Read data.json and write a Markdown table of the same rows to data.md.`
- `Find every file containing the string "deprecated" and add a "// TODO: remove" comment on that line.`

Confirm the result with `git diff` — the files on disk are the source of truth, not the model's
summary. Keep to one folder and one clearly-scoped change per request; open-ended "refactor this
project" asks are still beyond a local 8B.

## Where the model is stored

Because this app is sandboxed, the Hugging Face cache is redirected into its container — the
weights do **not** go to `~/.cache/huggingface`:

```
~/Library/Containers/lab.locallm.sdk.reference.workspacebuddylocal/Data/Library/Caches/huggingface/hub/
    models--mlx-community--Qwen3-8B-4bit/
        snapshots/<commit-sha>/        # config.json, *.safetensors, tokenizer…
        blobs/                          # the actual bytes (snapshot files symlink here)
```

swift-huggingface picks this path automatically for a sandboxed app (it keys off
`APP_SANDBOX_CONTAINER_ID`). Consequences:

- The ~4.5 GB counts against **this app's** container, and is deleted when the app is (drag to
  Trash → "move its data too", or `rm -rf` the container path above).
- It is **not shared** with `code-buddy` / `repo-qa-local` (those are unsandboxed and use
  `~/.cache/huggingface/hub/`) — each downloads its own copy.
- To point somewhere else, pass `MLXModelProvider(cacheDirectory:)` or set `HF_HUB_CACHE`.

A non-sandboxed app or CLI using the same model layer stores it at `~/.cache/huggingface/hub/`
instead. See [`docs/sdk-guide.md` §6a](../../docs/sdk-guide.md#6a-the-model-layer-local-models-routing-sessions).

## What the model layer adds (diff against `workspace-buddy`)

The `FolderAccess` enum (folder picker + security-scoped bookmark + `withFolderAccessAsync`) is
copied verbatim. The differences, all in the view model:

| `workspace-buddy` | `workspace-buddy-local` |
|---|---|
| `import LocalLMLabSDKCore` | `+ import LocalLMLabSDKInference` |
| `SystemLanguageModel.default` availability check | `MLXModelProvider` + `LocalLMLab` + `lab.models.route(.local, to: …)` in `init` |
| — | a `.downloadingModel(fraction)` state; `mlx.validate` → `mlx.download` on first run, progress into the UI |
| `LanguageModelSession(tools: tools) { instructions }` | `lab.makeSession(route: .local, tools: tools, instructions:)` |
| `session.respond(to:)` — awaited whole, spinner until done | `session.languageModelSession.streamResponse(to:)` — text streams in, plus a `session.events` loop for the "Reading a file…" activity line |
| `com.apple.security.network.client` — not needed | **required** (the model download) |

The `WorkspaceTools` array, the instructions, the single-turn shape, and the "no delete tool by
default" choice are all unchanged.

### Why stream here and not in `workspace-buddy`

Apple's on-device model answers a small edit in a couple of seconds — a spinner is fine.
`Qwen3-8B-4bit` on the GPU takes long enough (tens of seconds, plus pauses while it reads
files) that a bare "Working…" spinner reads as *stuck*. So this version:

- shows the answer **as it's generated** (`streamResponse` — each snapshot is the whole answer
  so far; shown latest-wins rather than diffed, since a reasoning model drops its `<think>`
  block mid-stream and the snapshot can reset across a tool call — `code-buddy` does the
  careful append-only version because stdout can't un-print);
- shows **which tool is running** during the gaps, from `session.events`
  (`.toolCallStarted` / `.toolCallFinished` → "Reading a file…", "Editing a file…");
- keeps the Qwen `<think>` reasoning visible inline — strip it consumer-side if you want just
  the summary.

`session.events` is the side-channel *around* generation (tool calls, context compaction,
model-load progress); token text always comes from `streamResponse`. See
[`docs/sdk-guide.md` §6a](../../docs/sdk-guide.md#6a-the-model-layer-local-models-routing-sessions),
the `LocalLMLabSession.events` subsection.

> **The download UI is hand-rolled here on purpose.** The `.downloadingModel(fraction)` state and
> the `mlx.validate` → `mlx.download` loop are ~20 lines that show the raw event stream. If you
> want the ready-made version — a model list with availability badges, on-disk sizes, the
> progress bar, and an "Add from Hugging Face" field — `Components`' `ModelPickerView` binds
> straight to `lab.models`; see
> [`docs/sdk-guide.md` §11](../../docs/sdk-guide.md#11-components-prebuilt-swiftui-mcp-servers--the-model-layer).

## Changing the model

Edit `workspaceModelRepo` at the top of
`Sources/WorkspaceBuddyLocal/WorkspaceBuddyLocalApp.swift` — any MLX-format Hugging Face repo.
See [`docs/tested-models.md`](../../docs/tested-models.md) for which open-weight models tool-call
reliably. `MLXModelProvider.validate` refuses a model whose weights exceed ~70% of this Mac's RAM.

## More

- [`workspace-buddy`](../workspace-buddy) — this same app running **Apple's built-in model** (no
  download, no network entitlement).
- [`repo-qa-local`](../repo-qa-local) — the minimal model-layer + MLX example (a CLI): the same
  Apple → open-weight swap, on `repo-qa`.
- [`code-buddy`](../code-buddy) — the model layer end to end (two models, routing between them,
  an agent loop), a CLI.
- [`docs/sdk-guide.md` §6a](../../docs/sdk-guide.md#6a-the-model-layer-local-models-routing-sessions) —
  the model layer, in prose. §8a — `WorkspaceTools`. §10 — App Sandbox.
- [`docs/annotated-examples.md`](../../docs/annotated-examples.md) — this app's full source with
  every SDK touchpoint marked.
