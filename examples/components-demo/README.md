# Components Demo

`LocalLMLabSDKComponents` is a small SwiftUI package shipped alongside the SDK that gives you a
**ready-made UI for MCP server management** — the screen where a user adds an MCP server by URL,
authenticates it (all three MCP auth styles: none, personal access token, OAuth), and turns
individual tools and resources on or off. It's built entirely on the SDK's public API, and it
handles the parts that are genuinely fiddly to get right: the OAuth flow, Keychain-backed token
storage, rendering a server's live schema, and tracking which tools are actually available in the
current session.

This demo is the thin wrapper that shows the payoff: a few lines of glue embed that prebuilt
picker and you have a working "connect your own MCP servers" feature — no MCP UI of your own to
design, build, or maintain. **If your app lets users bring their own MCP servers, start here** and
see how little you write. If you'd rather build that surface yourself against Core's MCP API, the
other examples do it that way.

Beyond the picker, the app has no TCC-gated connectors (no Calendar/Reminders/Location) and no
build-time feature flags — just the "Add a server" screen, per-tool/per-resource enable toggles,
live "Tools available this session" tracking, and a "Save As…" export of what a connected server
offers. See
[`docs/sdk-guide.md` §11](../../docs/sdk-guide.md#11-components-prebuilt-swiftui-for-mcp-server-management)
for what `Components` provides and how it's meant to be dropped into your own app.

Requires macOS 27+ on Apple Silicon (currently the macOS 27 beta; Xcode 27 beta to build).

## Getting the SDK

This branch tracks `1.0.0-beta.3`, which needs macOS 27. Build with the **Xcode 27 beta**
(`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`) — a stable Xcode fails with
`'v27' is unavailable`. Nothing to download by hand — `Package.swift` (both this app's and the
sibling [`Components`](../../Components/) package it depends on) requires an explicit
`LOCALLM_SDK_VERSION` and resolves `LocalLMLabSDKCore` as a binary dependency:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 swift build
```

## Quick dev-loop run

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 swift run
```

Unlike `plate-today`, this app needs no TCC entitlements to function — the MCP server picker
(outbound HTTPS + Keychain-backed OAuth token storage) works the same whether the binary is signed
or not. `swift run` is enough to try the full server-add/connect/tool-enable flow; you only need
the packaged build below to test it as a real, distributable `.app`.

## Real build: `packaging/build-and-sign.sh`

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 \
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_APP=0 \
./packaging/build-and-sign.sh
```

### Environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `LOCALLM_SDK_VERSION` | Yes | — | Read by both this app's `Package.swift` and `Components`' own — `swift build` fails without it. |
| `APP_IDENTITY` | Yes | — | Must match a valid codesigning identity in your keychain (`security find-identity -v -p codesigning`). `SIGN_IDENTITY` also works as a fallback name. |
| `VERSION` | No | `0.1.0` | Stamped into `CFBundleShortVersionString`/`CFBundleVersion`. |
| `NOTARIZE_APP` | No | `1` | Set to `0` to skip Apple notarization for fast local sign-and-test iteration. **The output isn't Gatekeeper-approved without notarization** (`spctl` rejects it) — fine for direct-launch testing, not for distribution. |
| `KEYCHAIN_PROFILE` | Only if `NOTARIZE_APP=1` | — | Created once via `xcrun notarytool store-credentials <profile-name>`. `NOTARY_PROFILE` also works as a fallback name. |
| `TEAM_ID` | No | — | Passed to `notarytool submit` if set; usually unneeded if your `KEYCHAIN_PROFILE` already implies one team. |
| `DEVELOPER_DIR` | Yes (on macOS 27) | `/Applications/Xcode.app/Contents/Developer` | Must point at the Xcode 27 beta — the script does **not** auto-detect it, and a stable Xcode fails with `'v27' is unavailable`. |

There's no MAS-signing script for this app (no equivalent of `plate-today`'s
`build-and-sign-mas.sh`) — the standard `build-and-sign.sh` above is Developer ID / Gatekeeper
distribution only.

## Trying it against a real MCP server

No account needed — [DeepWiki](https://mcp.deepwiki.com/mcp) is a real, no-auth MCP server good
for a first try: launch the app, "Add a server" with that URL and auth type "None," Connect, then
enable a tool to see it show up under "Tools available this session." "Save As…" exports a text
summary of everything the server offers (tools, resources, prompts) and their enabled state.

For a fuller list of real MCP servers to test against — including ones that exercise OAuth and
personal-access-token auth, not just no-auth — see
[thisbrain.ai/locallm/mcp-servers.html](https://thisbrain.ai/locallm/mcp-servers.html).

## More

- [`docs/sdk-guide.md`](../../docs/sdk-guide.md) — the full SDK guide, including all three MCP
  auth types, Keychain storage, and the full API reference.
- [`docs/annotated-examples.md`](../../docs/annotated-examples.md) — this app's full source with
  every SDK/Components touchpoint marked.
- [`Components/`](../../Components/) — the reusable SwiftUI package this app depends on.
