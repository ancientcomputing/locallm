# LocalLMLabSDKComponents

Reusable SwiftUI pieces for the two things a LocalLM Lab app usually needs a settings screen for
— **MCP servers** and **the model layer** — built entirely on `LocalLMLabSDKCore`'s public API,
no private access to Core's internals. Apache 2.0 licensed, same as the rest of this repo.

### MCP-server views

| File | What it provides |
|---|---|
| `MCPServerManagerObservable.swift` | An `ObservableObject` wrapper around Core's `MCPServerManager`, so SwiftUI views can observe connection/tool state changes. Also adds `LocalizedError` conformance to Core's `MCPServerError` — human-readable error text is a UI concern Core deliberately doesn't own. |
| `MCPServerPickerView.swift` | The main "add/list/reconnect/disconnect/remove" screen, all three MCP auth types (none, personal access token, OAuth). Lists each server's tools and resources with enable/disable checkboxes, prompts read-only, plus a "Save As…" export (`NSSavePanel` — the one AppKit-specific piece, kept out of Core) built on Core's `MCPServerState.exportSummary()`. |
| `MCPOAuthWaitingView.swift` | A waiting/spinner view shown while an OAuth sign-in is in flight in the system browser. |
| `MCPResourcesPromptsView.swift` | Read-only browsing of a session's enabled resources/resource templates/prompts, with an "Attach"/"Use" action per item that calls Core's `readResource`/`getPrompt` and hands the raw result to a host-supplied callback — no opinion on what "attach" means, same no-persistence-of-its-own precedent as the server picker. Exports `MCPResourcesView` and `MCPPromptsView`. |

### Model-layer views

All bind directly to `lab.models` (an `@Observable` `ModelRegistry`) — availability, install
state, and live download progress are observable properties, never polled.

| File | What it provides |
|---|---|
| `ModelPickerView.swift` | The local-model surface: `registry.knownModels` with an availability badge each (*Ready* / *Not downloaded* / *Needs credential* / *Requires macOS 27*), bound to a `Binding<ModelID?>`. When `LocalLMLabSDKInference` is linked, also a **"Downloaded models"** section — installed models + on-disk size, a **live progress bar** per in-flight download (`registry.downloads`), and an **"Add from Hugging Face"** field wired to `registry.startDownload(_:)`. This is the ready-made version of the hand-rolled download-progress loop in the model-layer examples. Also exports `ClaudeAuthField` (a secure field for the Claude API key, handed to the host, not persisted). |
| `AIModelsSettingsView.swift` | The assembled "AI Models" panel: built-in families with live availability, then one `ProviderSettingsSection` per configured **online** provider, then an **Add provider** menu. Host owns `[RemoteProviderDraft]` (keys → Keychain) and the `onSave` / `onRemove` / `onTest` closures that map a draft to a `RemoteModelProvider` and call `lab.models.replace(_:)`. **No dependency on `LocalLMLabSDKRemote`** — the closures are the seam. |
| `ProviderSettingsSection.swift` | One online-provider block — API-key field, **Configured ✓** badge, per-model row editor, **Enable web search** toggle + **Max searches** stepper, **Test connection** button (one result per model). Usable standalone. |
| `RemoteProviderDraft.swift` | `RemoteProviderDraft` + `RemoteProviderKind` — the UI-facing shape the host maps to `RemoteProviderConfig` (~20 lines; see `examples/model-switch`'s `ProviderGlue.swift`). `.new(_:)` deliberately ships **no default model ids** — the host prefills them. |
| `ProviderTestOutcome.swift` | The result type for **Test connection**: one `ModelResult` (`modelId` / `ok` / `detail`) per configured model, or a `message` when the check couldn't run. |

`ModelPickerView` (local models + MLX download) and `AIModelsSettingsView` (online providers) are
separate surfaces today — a full "AI Models" panel composes both. Unifying them is on the list.

None of these views persist anything themselves. MCP state goes through the
`MCPServerManagerObservable` you own (`manager.core.restore(from:)` at launch); model-layer state
goes through `lab.snapshot()` / `lab.restore(from:)` plus your own Keychain for provider keys.

See [`docs/sdk-guide.md` §11](../docs/sdk-guide.md#11-components-prebuilt-swiftui-mcp-servers--the-model-layer)
for the narrative walkthrough, [`examples/components-demo/`](../examples/components-demo/) for the
MCP views in a full app, and [`examples/model-switch/`](../examples/model-switch/) for
`AIModelsSettingsView`.

## Building

This is a library, not an app — there's nothing to sign or package, just `swift build`/`swift
test`. `Package.swift` builds against SDK `1.0.0-beta.3` by default, same as the example apps:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
```

Set `LOCALLM_SDK_VERSION` in a shell to build against a different published release — see
`Package.swift`'s `defaultSDKVersion` / `knownSDKReleases`. To actually see these views running,
build and run
[`examples/components-demo`](../examples/components-demo/) instead — it depends on this package as
source, so any local change here is picked up immediately.
