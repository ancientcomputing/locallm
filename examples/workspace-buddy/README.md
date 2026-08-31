# Workspace Buddy

**Workspace Buddy** is a small Mac app for AI-assisted edits to a folder of files. You pick a
folder, type a request in plain English — "add a header comment to every file", "rename `oldName`
to `newName` throughout" — and the on-device model reads the files and makes the changes. It's a
modest, entirely-local take on AI-assisted coding: not Claude Code, but everything runs on your
Mac, and the model can only touch the one folder you chose.

**What it highlights for SDK developers:**

- **Giving a model safe, scoped access to files.** Core's `WorkspaceTools` — list, read, create,
  and edit files — are ready-made tools you drop into the model's tool array; you write no file
  I/O and no per-tool code. Every path they touch is confined to the folder the user picked
  ("Path A" — see [`docs/sdk-guide.md` §8a](../../docs/sdk-guide.md#8a-workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url)).
- **A user-picked folder that survives relaunch, under App Sandbox.** The app is always sandboxed
  (the Mac App Store requires it). A sandboxed app can't simply reopen a folder the user chose
  last time — it has to save a *security-scoped bookmark*. This app shows that pattern end to
  end: `NSOpenPanel` → bookmark → the same folder still accessible on the next launch. One
  entitlement, no permission dialog.
- **Choosing which tools to expose.** Core also ships a delete tool; this app deliberately leaves
  it out — a coding assistant that can delete files unprompted is a bigger risk than one that
  only reads, creates, and edits. (More in
  [*What this app does, and doesn't, do*](#what-this-app-does-and-doesnt-do) below.)

## What you'll see

Run the signed build (`packaging/build-and-sign.sh`, below — a plain `swift run` is compile-only
here). Open the `.app`, click **Choose Folder…**, pick a throwaway directory, type a request, hit
**Go**. The model works for a few seconds, then the files in that folder change on disk — check
with `git diff` or your editor.

Requires macOS 27 on Apple Silicon with Apple Intelligence enabled.

## About the model

This app uses **Apple's on-device Foundation model** — the small language model built into macOS,
the same one Apple Intelligence features use. It runs locally with zero setup, but it's modest:
a few billion parameters, tuned for short well-scoped tasks, with a context window of only
~8,000 tokens (so it can't hold a large file, let alone a whole project, at once).

Realistic asks: "rename `oldName` to `newName` in this file", "add a doc comment to each
function", "convert this JSON to YAML". It will struggle with big files, many files in one
request, or open-ended refactors, and it tool-calls less reliably than a larger model.

For more capability while staying local, [`workspace-buddy-local`](../workspace-buddy-local) is
this same app running a downloadable open-weight model (e.g. an 8B). The SDK can also route to
Claude if a cloud model is acceptable — see [`docs/sdk-guide.md` §6a](../../docs/sdk-guide.md#6a-the-model-layer-local-models-routing-sessions).

## Getting the SDK & toolchain

Copy-paste each step. Step 1 is one-time machine setup; step 2 sets up your terminal session
(re-run it in every new terminal).

**1. Install the Xcode 27 beta.** Download it from
[developer.apple.com/xcode](https://developer.apple.com/xcode/) and drag it to `/Applications`
(it installs as `Xcode-beta.app`, alongside any stable Xcode). This example needs it — a stable
Xcode fails with `'v27' is unavailable` because `Package.swift` requires `platforms: [.macOS("27.0")]`.

**2. Set two environment variables** in the terminal you'll build from:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export LOCALLM_SDK_VERSION=1.0.0-beta.1
```

- `DEVELOPER_DIR` makes `swift` use the Xcode 27 beta for this shell (leaves your system default
  alone).
- `LOCALLM_SDK_VERSION` tells `Package.swift` which SDK release to download
  `LocalLMLabSDKCore.xcframework` from. Omitting it fails fast with a clear error. (`WorkspaceAccess`/
  `WorkspaceTools`, this app's whole point, first shipped in SDK `0.8.0`, but on macOS 27 you use
  `1.0.0-beta.1+`.)

These last only for the current terminal — re-run step 2 in each new terminal (or add both
`export` lines to your `~/.zshrc`).

**3. Compile-check:**

```bash
swift build
```

This just proves it builds. To *actually run* it you need a signed `.app` — see below.

## Running it

Unlike the CLI examples, this is a sandboxed SwiftUI `.app`, and the whole point — a
security-scoped bookmark surviving relaunch — only means anything with the sandbox on and the
`com.apple.security.files.user-selected.read-write` entitlement in place. A bare `swift run`
gets neither, so it's compile-only. The real build is `packaging/build-and-sign.sh`, which needs
a **Developer ID Application** signing identity in your keychain
(`security find-identity -v -p codesigning`):

```bash
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_APP=0 \
  ./packaging/build-and-sign.sh
```

(`NOTARIZE_APP=0` skips the Apple notarization round-trip — fine for launching the result
yourself, not for handing it to another Mac. `DEVELOPER_DIR` and `LOCALLM_SDK_VERSION` come from
step 2.) The signed `.app` lands in `dist/`; open it, click **Choose Folder…**, pick a throwaway
directory, type a request in the box, and hit **Go**.

Sandboxing here is **not** a build-time opt-in the way it is for `plate-today` — this app is
always sandboxed. No `NS*UsageDescription` key or TCC prompt is involved; `NSOpenPanel` plus that
one entitlement is the whole story.

## What this app does, and doesn't, do

- **Read** (`listWorkspaceFiles`/`readWorkspaceFile`), **create** (`writeWorkspaceFile` — fails if
  the file already exists), and **edit** (`editWorkspaceFile` — search-and-replace, not a
  unified-diff format) are all wired in.
- **Delete is not wired in by default** — `DeleteWorkspaceFileTool` exists in Core, but a coding
  assistant that can delete files unprompted is a meaningfully bigger risk than one that can only
  read/create/edit. Add it to the `tools` array in `WorkspaceBuddyApp.swift` yourself if you want
  it. Asked to delete a file without it, the model correctly refuses — but confirmed live, its
  stated *reason* can be a little confused (e.g. claiming the file "already exists" as the reason
  it can't delete it, apparently reaching for `writeWorkspaceFile`'s create-only error since
  that's the closest tool it actually has). The refusal itself is reliable; don't read too much
  into its explanation of why.
- **Single-turn per request** — type a request, get a response, type another. Not a full
  multi-turn chat with conversation history; a straightforward extension if you want one.

## Verified live

Built, Developer-ID signed, launched as a real sandboxed `.app`; picked a throwaway scratch folder
via the actual `NSOpenPanel`; asked it, in plain English, to change one string in an existing file
— the on-device model called `readWorkspaceFile` then `editWorkspaceFile`, and the change landed
correctly on disk (verified byte-for-byte afterward). A separate request to create a new file also
worked, and a follow-up read reflected the earlier edit — no stale-cache issues.

## More

- [`workspace-buddy-local`](../workspace-buddy-local) — this same app running a **downloadable
  open-weight model** (e.g. an 8B) instead of Apple's, inside App Sandbox.
- [`plate-today-tools`](../plate-today-tools) — another Path-A app (ready-made Tools), also
  sandbox-capable, also a GUI.
- [`docs/sdk-guide.md` §8a](../../docs/sdk-guide.md#8a-workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url) —
  `WorkspaceAccess` / `WorkspaceTools`, and why `editFile` is search-and-replace, not a diff
  format. §10 — App Sandbox.
- [`docs/annotated-examples.md`](../../docs/annotated-examples.md) — this app's full source with
  every SDK touchpoint marked.
