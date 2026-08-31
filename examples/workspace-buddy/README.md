# Workspace Buddy

The SDK's fourth reference app, and its first that writes to disk: pick a folder, describe a
change, the on-device model reads/creates/edits files in it via Core's `WorkspaceTools` (Path A,
see [`docs/sdk-guide.md` §8a](../../docs/sdk-guide.md#8a-workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url)).
A local, more modest take on AI-assisted coding — not Claude Code, but a real demonstration of
what's possible entirely on-device.

Requires macOS 27 on Apple Silicon with Apple Intelligence enabled.

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

- [`docs/sdk-guide.md` §8a](../../docs/sdk-guide.md#8a-workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url) —
  the prose walkthrough of `WorkspaceAccess`/`WorkspaceTools` and why `editFile` is
  search-and-replace rather than a diff format.
- [`docs/annotated-examples.md`](../../docs/annotated-examples.md) — this app's full source with
  every SDK touchpoint marked.
- [`plate-today-tools`](../plate-today-tools) — the other sandboxed-by-default-capable example, for
  comparison (there, sandboxing is opt-in).
