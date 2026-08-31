# Workspace Buddy (local model)

[`workspace-buddy`](../workspace-buddy)'s exact setup — a sandboxed SwiftUI `.app`: pick a folder
(via `NSOpenPanel` + a security-scoped bookmark), describe a change, the model reads/creates/edits
files in it via Core's `WorkspaceTools` (Path A, see
[`docs/sdk-guide.md` §8a](../../docs/sdk-guide.md#8a-workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url)).
The one difference: the model is an **open-weight MLX model you download and run locally**
(`mlx-community/Qwen3-8B-4bit` by default), routed through the 1.0 **model layer**, instead of
Apple's on-device model.

> **This is the one example running the model layer inside App Sandbox.** It needs the
> `com.apple.security.network.client` entitlement (to fetch the model from Hugging Face on first
> run) on top of workspace-buddy's `files.user-selected.read-write`, and the model downloads into
> this app's sandbox container. **That combination is not yet verified end to end** — if the
> download or the Metal shader load fails under sandbox, that's a real finding worth reporting.

> **Want the on-device-model version instead?** [`workspace-buddy`](../workspace-buddy) is this
> exact app with `SystemLanguageModel.default` and no model layer, no network entitlement.

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
**First Go downloads the model** (~4.5 GB for the default — into
`~/Library/Containers/lab.locallm.sdk.reference.workspacebuddylocal/Data/`), with a progress bar.
After that it's local and offline.

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

- [`workspace-buddy`](../workspace-buddy) — the on-device-model original this is a twin of.
- [`code-buddy`](../code-buddy) — the model layer end to end, as a CLI (unsandboxed).
- [`repo-qa-local`](../repo-qa-local) — the minimal model-layer + MLX example (a CLI).
- [`docs/sdk-guide.md` §6a](../../docs/sdk-guide.md#6a-the-model-layer-local-models-routing-sessions) —
  the model layer, in prose. §10 — App Sandbox.
