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

**3. Set two environment variables** in the terminal you'll build from:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export LOCALLM_SDK_VERSION=1.0.0-beta.3
```

- `DEVELOPER_DIR` makes `swift` use the Xcode 27 beta for this shell (leaves your system default
  alone).
- `LOCALLM_SDK_VERSION` tells `Package.swift` which SDK release to download. This example links
  **two** binaries — `LocalLMLabSDKCore.xcframework` and `LocalLMLabSDKInference.xcframework` (the
  MLX runtime, which carries its own Metal shaders) — from that one GitHub Release.

These last only for the current terminal — re-run step 3 in each new terminal (or add both
`export` lines to your `~/.zshrc`).

**4. Compile-check:**

```bash
swift build
```

This just proves it builds. To *actually run* it you need a signed, sandboxed `.app` — see below.

## Running it

Like `workspace-buddy`, a bare `swift run` gets you neither the sandbox nor the
`files.user-selected` entitlement, so it's compile-only. The real build is
`packaging/build-and-sign.sh`, which needs a **Developer ID Application** signing identity in your
keychain (`security find-identity -v -p codesigning`):

```bash
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_APP=0 \
  ./packaging/build-and-sign.sh
```

(`DEVELOPER_DIR` and `LOCALLM_SDK_VERSION` come from step 3.) The signed `.app` lands in `dist/`;
open it, click **Choose Folder…**, pick a throwaway directory, type a request, and hit **Go**.
**First Go downloads the model** (~4.5 GB for the default), with a progress bar. After that it's
local and offline — the second run starts generating immediately.

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
| `session.respond(to:)` | `session.languageModelSession.respond(to:)` |
| `com.apple.security.network.client` — not needed | **required** (the model download) |

The `WorkspaceTools` array, the instructions, the single-turn shape, and the "no delete tool by
default" choice are all unchanged.

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
