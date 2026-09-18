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
| `ModelOnboarding.swift` | **`ModelOnboardingView`** + `ModelOnboardingModel` — a *Validate → Download → Pin* stepper, one block per repo. A failed preflight names its stage and reason (`failed at .trustPolicy — …`) and nothing after it runs; the download shows progress and can be cancelled; the Pin step shows the resolved commit and, when the host passes the pin it ships (`ModelOnboardingRequest.expectedRevision`), **verifies** it matches. Works from `ModelOnboardingSource(provider:)` or `(registry:)` — Core's `DownloadableModelProvider` only. `ModelPickerView`'s "Add from Hugging Face" row now uses it. |
| `ModelUpdates.swift` | **`ModelUpdateView`** (check → what changes → update → roll back, with a *switching* state and a `pauseInference` hook) and **`ModelVersionsView`** (versions on disk, what removing each would *actually* free, a guarded **Remove**). Provider-agnostic: they take plain value types (`ModelUpdateOffer`, `ModelVersionRow`) and closures (`ModelUpdateActions`), so the host adapts its provider in a few lines — see "Adapting `MLXModelProvider`" below. The wording follows who decides: `.userChosen` (you decide), `.developerOffered` (the developer vouches for a version), `.fixed(reason:)`. |

`ModelPickerView` (local models + MLX download) and `AIModelsSettingsView` (online providers) are
separate surfaces today — a full "AI Models" panel composes both. Unifying them is on the list.

### Onboarding, updating and cleaning up a model

`ModelOnboardingView` needs nothing but Core. Give it what to onboard and where the work happens:

```swift
let onboarding = ModelOnboardingModel(
    requests: [ModelOnboardingRequest(repoID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                                      expectedRevision: shippedPin)],     // optional: verify the commit
    source: ModelOnboardingSource(registry: lab.models))                  // or (provider: mlxProvider)
ModelOnboardingView(model: onboarding, onFinished: { installed in … })
```

`ModelUpdateView` and `ModelVersionsView` are **provider-agnostic on purpose**. The SDK's update and cleanup
APIs live on `MLXModelProvider` in Inference (macOS 27), which Components doesn't link, so these views own
presentation and state and call closures you supply. The pause point matters: downloading the new version
doesn't disturb a running conversation, but *switching* can, so `ModelUpdateModel.pauseInference` is awaited
after the download and before the switch, and `state == .switching` tells your UI to refuse new requests.

`examples/components-updates-demo` drives every state of all three views from simulated sources.

#### Adapting `MLXModelProvider`

About forty lines. (Compiled and run against the real Inference module.) `vouchedCommit` is for a **built-in**
model: ask *your own* channel which commit you vouch for — the SDK moves a shipped pin only to a commit hash
you name, never to `main`, and cannot tell whether your channel is authentic. Leave it `nil` for a model the
user chose.

```swift
import LocalLMLabSDKComponents
import LocalLMLabSDKInference

@available(macOS 27.0, *)
extension ModelUpdateActions {
    static func mlx(_ provider: MLXModelProvider, repoID: String,
                    vouchedCommit: (@Sendable () async throws -> String)? = nil) -> ModelUpdateActions {
        ModelUpdateActions(
            check: {
                let check = try await provider.checkPinUpdate(repoID, to: try await vouchedCommit?())
                return ModelUpdateOffer(
                    current: check.pinnedRevision, available: check.latestRevision,
                    changes: check.changes.map { change in
                        let kind: ModelFileChange.Kind
                        switch change.kind {
                        case .added: kind = .added
                        case .removed: kind = .removed
                        case .modified: kind = .modified
                        @unknown default: kind = .modified
                        }
                        return ModelFileChange(path: change.path, kind: kind, oldSize: change.oldSize, newSize: change.newSize)
                    })
            },
            apply: { revision, progress, beforeSwitch in
                for try await event in provider.updatePin(repoID, to: revision, beforeSwitch: beforeSwitch) {
                    if case .progress(_, _, let fraction) = event { progress(fraction) }
                }
            })
    }
}

@available(macOS 27.0, *)
extension ModelVersionsModel {
    convenience init(provider: MLXModelProvider, repoID: String) {
        self.init(
            list: {
                provider.snapshots(for: repoID).map {
                    ModelVersionRow(revision: $0.revision, isCurrent: $0.isCurrent, isComplete: $0.isComplete,
                                    freesBytes: $0.exclusiveBytes, sharedBytes: $0.sharedBytes)
                }
            },
            remove: { try provider.removeSnapshot(repoID, revision: $0.revision) })
    }
}
```

**Requires the SDK release that has these APIs.** `ModelOnboardingView`'s Pin step reads
`InstalledModel.resolvedRevision`, and the adapter above uses `MLXModelProvider`'s pin-update and snapshot
APIs — all added after the first `1.0.0-RC.1` build. Build Components against a Core release that includes
them (`defaultSDKVersion` / `knownSDKReleases` in `Package.swift`).

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
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Set `LOCALLM_SDK_VERSION` in a shell to build against a different published release — see
`Package.swift`'s `defaultSDKVersion` / `knownSDKReleases`. To actually see these views running,
build and run
[`examples/components-demo`](../examples/components-demo/) instead — it depends on this package as
source, so any local change here is picked up immediately.
