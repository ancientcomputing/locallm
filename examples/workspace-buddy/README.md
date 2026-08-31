# Workspace Buddy

The SDK's fourth reference app, and its first that writes to disk: pick a folder, describe a
change, the on-device model reads/creates/edits files in it via Core's `WorkspaceTools` (Path A,
see [`docs/sdk-guide.md` §8a](../../docs/sdk-guide.md#8a-workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url)).
A local, more modest take on AI-assisted coding — not Claude Code, but a real demonstration of
what's possible entirely on-device.

Requires macOS 27+ on Apple Silicon with Apple Intelligence enabled (currently the macOS 27 beta; Xcode 27 beta to build).

## Requires macOS 27 + the Xcode 27 beta

This branch tracks `1.0.0-beta.1`. `Package.swift` is
`platforms: [.macOS("27.0")]`. Build with the **Xcode 27 beta**
(`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`); a stable Xcode fails with
`'v27' is unavailable`. (`WorkspaceAccess`/`WorkspaceTools`, this app's whole point, first
shipped in `0.8.0`, but on macOS 27 you use `1.0.0-beta.1+`.)

## Getting the SDK

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.1 swift build
```

## Real build: `packaging/build-and-sign.sh`

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.1 \
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_APP=0 \
./packaging/build-and-sign.sh
```

Unlike `plate-today`, sandboxing here is **not** a build-time opt-in — this app is sandboxed
unconditionally. That's what actually makes the security-scoped bookmark pattern in §8 (Filesystem access) necessary
to demonstrate: unsandboxed, a plainly-remembered folder path would just keep working across
relaunches, and the example wouldn't prove anything about the SDK's real guidance. No
`NS*UsageDescription` key or TCC prompt is involved — `NSOpenPanel` plus the
`com.apple.security.files.user-selected.read-write` entitlement is the whole story.

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

## Verified live (private repo, source dependency)

Built, Developer-ID signed, launched as a real sandboxed `.app`; picked a real throwaway scratch
folder via the actual `NSOpenPanel`; asked it, in plain English, to change one string in an
existing file — the on-device model called `readWorkspaceFile` then `editWorkspaceFile`, and the
change landed correctly on disk (verified byte-for-byte afterward). A separate request asking it
to create a new file with specific content also worked, and a follow-up read of the earlier-edited
file correctly reflected the change, confirming no stale-cache issues.

## More

- [`docs/sdk-guide.md` §8a](../../docs/sdk-guide.md#8a-workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url) —
  the prose walkthrough of `WorkspaceAccess`/`WorkspaceTools` and why `editFile` is
  search-and-replace rather than a diff format.
- [`docs/annotated-examples.md`](../../docs/annotated-examples.md) — this app's full source with
  every SDK touchpoint marked.
- [`plate-today-tools`](../plate-today-tools) — the other sandboxed-by-default-capable example, for
  comparison (there, sandboxing is opt-in).
