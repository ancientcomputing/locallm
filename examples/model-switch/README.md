# Model Switch

The reference app for [`docs/12-remote-model-providers.md`](../../docs/12-remote-model-providers.md)
— AnswerSearch-shaped. Add an online AI provider with an API key, tick web search, and switch
freely between **every** configured model from one chat window and one `lab.makeSession` call site:

- Apple on-device (`system`) — always present, no key
- GPT via `openai:` (Chat Completions or Responses)
- Claude online via `anthropic:` — with native web search + citations
- any OpenRouter model via `openrouter:` — with the model-agnostic web plugin
- any OpenAI-compatible server (LM Studio, vLLM, …) via a custom scheme

It links `LocalLMLabSDKRemote` (the online-providers layer) as a binary and `LocalLMLabSDKCore`
+ `LocalLMLabSDKComponents` from the sibling [`Components`](../../Components/) package. MLX would
slot in exactly as `code-buddy` links `LocalLMLabSDKInference`; left out here to keep the build
Metal-toolchain-free.

Requires macOS 27+ on Apple Silicon (currently the macOS 27 beta; Xcode 27 beta to build) —
`RemoteModelProvider` is `@available(macOS 27)`.

## What you'll see

Running a packaged build (`packaging/build-and-sign.sh`, below):

1. **Launch** — a chat window with a model picker (just **system** at first), a **Web search**
   toggle, and a **Providers** button.
2. **Click Providers** (or `⌘,`) — the [`AIModelsSettingsView`](../../Components/Sources/LocalLMLabSDKComponents/AIModelsSettingsView.swift)
   from `Components`: built-in families with live availability, then **Add provider** → pick
   OpenAI / Anthropic / OpenRouter / a custom server → paste a key → add a model id. The model
   rows flip to **Ready** and appear in the chat window's picker. Tick **Enable web search** on a
   provider that supports it.
3. **Back in the chat window** — pick any model, optionally flip **Web search** for the next
   turn, send. When the model runs a provider-native search you see the queries inline and
   citation links under the answer.
4. **Switch models mid-conversation** — the picker changes which provider the *next* turn routes
   to; the transcript carries over.

## Getting the SDK

Nothing to download by hand — `Package.swift` (both this app's and the sibling
[`Components`](../../Components/) package it depends on) resolves `LocalLMLabSDKCore` /
`LocalLMLabSDKRemote` as binary dependencies, building against `1.0.0-beta.3` by default:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
```

Set `LOCALLM_SDK_VERSION` in a shell (not Xcode) to pin another published release — see
[`../README.md`](../README.md#building--running-an-sdk-example). A stable Xcode fails with
`'v27' is unavailable`; use the Xcode 27 beta.

## Open in Xcode and Run

A committed `ModelSwitch.xcodeproj` gives you the fastest look:

```bash
open ModelSwitch.xcodeproj
```

Pick the **ModelSwitch** scheme and hit Run. It builds a real `.app` (proper menu bar, Dock
icon, `⌘,` Providers screen), ad-hoc signed for this Mac — the same local-run tier as
`packaging/build-and-sign.sh` with `APP_IDENTITY` unset. Needs the Xcode 27 beta selected
(Xcode ▸ Settings ▸ Locations ▸ Command Line Tools, or launch Xcode-beta directly).

The project is generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen && xcodegen generate`)
— edit `project.yml`, not the `.xcodeproj`, and regenerate. To pin a different SDK release for
the Xcode build, edit `defaultSDKVersion` in `Package.swift` and `../../Components/Package.swift`
(Xcode's package resolution ignores `LOCALLM_SDK_VERSION`).

## Quick dev-loop run

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run ModelSwitch
```

Useful for compiler-level iteration. Run it as a real app from the packaged build below — a bare
executable has no `Info.plist`, so the app menu, the Dock icon, and window activation are all
rough, and `⌘,` for the Providers screen may not register (use the toolbar button).

## Distributable build: `packaging/build-and-sign.sh`

For just trying the app, the Xcode project above is enough. Use this script to produce a
`Model Switch.app` you can hand to another Mac. No entitlements, no system-permission prompts —
the app only makes outbound HTTPS calls — so with no `APP_IDENTITY` it signs **ad-hoc** (this Mac
only); set one for a distributable build:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./packaging/build-and-sign.sh
```

To sign it for wider use, set `APP_IDENTITY` — see the
[signing table in `../README.md`](../README.md#signing-a-app--app_identity).

### Environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `LOCALLM_SDK_VERSION` | No | `1.0.0-beta.3` | Read by this app's `Package.swift` and `Components`' own — set it to build against a different published release. |
| `APP_IDENTITY` | No | ad-hoc | Any codesigning identity, or unset for a local ad-hoc build. See the [signing table](../README.md#signing-a-app--app_identity). |
| `VERSION` | No | `0.1.0` | Stamped into `CFBundleShortVersionString`/`CFBundleVersion`. |
| `NOTARIZE_APP` | No | `1` | `0` skips Apple notarization for fast local sign-and-test. The output isn't Gatekeeper-approved without it (`spctl` rejects it) — fine for direct-launch testing, not distribution. |
| `KEYCHAIN_PROFILE` | Only if `NOTARIZE_APP=1` | — | Created once via `xcrun notarytool store-credentials <profile-name>`. `NOTARY_PROFILE` also works. |
| `TEAM_ID` | No | — | Passed to `notarytool submit` if set. |
| `DEVELOPER_DIR` | Yes (on macOS 27) | `/Applications/Xcode.app/Contents/Developer` | Must point at the Xcode 27 beta; not auto-detected. |

Same script shape and env-var names as [`plate-today`](../plate-today/) and
[`components-demo`](../components-demo/) — see `plate-today`'s script for the full codesign /
notarize failure-mode writeups this mirrors.

## What it shows

| piece | file |
|---|---|
| `RemoteProviderDraft` → `RemoteProviderConfig` — the ~30 lines of host glue | [`ProviderGlue.swift`](Sources/ModelSwitch/ProviderGlue.swift) |
| `lab.models.replace(RemoteModelProvider(config))` on every settings change | [`AppModel.applyDraft`](Sources/ModelSwitch/AppModel.swift) |
| one `makeSession(route:options:)` for every tier; `session.events` → search activity; `session.citations` | [`AppModel.send`](Sources/ModelSwitch/AppModel.swift) |
| `RemoteModelProvider.probe(for:)` behind the settings panel's **Test connection** | [`AppModel.testDraft`](Sources/ModelSwitch/AppModel.swift) |
| the assembled settings panel + per-provider section | `Components` |

## Not production

API keys persist to `UserDefaults` here for brevity — **a real app stores them in the
Keychain.** The SDK persists nothing; key storage is always the host's job.
