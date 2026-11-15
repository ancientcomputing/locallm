# LocalLMLabSDKComponents

Reusable SwiftUI pieces for what a LocalLM Lab app usually builds screens for — **MCP servers**,
**the model layer**, and, new in 3.0, **a chat** (transcript, message box, chat list, cards,
Markdown) — built entirely on `LocalLMLabSDKCore`'s public API, no private access to Core's
internals. Apache 2.0 licensed, same as the rest of this repo.

### MCP-server views

| File | What it provides |
|---|---|
| `MCPServerManagerObservable.swift` | An `ObservableObject` wrapper around Core's `MCPServerManager`, so SwiftUI views can observe connection/tool state changes. Also adds `LocalizedError` conformance to Core's `MCPServerError` — human-readable error text is a UI concern Core deliberately doesn't own. |
| `MCPServerPickerView.swift` | The main "add/list/check/remove" screen, all three MCP auth types (none, personal access token, OAuth). In 3.0 it is the **Tool Sources** sheet: each server's Tools, Content and Prompts sections (collapsible, in everyday words), enable/disable checkboxes, a **Check connection** action, pending-drift rows with an Accept button, and a "Save As…" export (`NSSavePanel` — the one AppKit-specific piece, kept out of Core) built on Core's `MCPServerState.exportSummary()`. Paste a server's JSON setup (Claude Desktop's `mcpServers`, VS Code's `servers`, one entry, or a bare `command`/`args`) into the address field and it fills the form. Init options: `toolsMode` (`.static`, or `.dynamic` for `makeSession(dynamicTools:)`), `allowsLocalPrograms` (offers **Local program** beside **Web address** where `ExternalPrograms.isSupported`, so never in a sandboxed build), and `detail` (`ChatToolDetail.plain` or `.detailed`). |
| `MCPOAuthWaitingView.swift` | A waiting/spinner view shown while an OAuth sign-in is in flight in the system browser. |
| `MCPElicitationPresenter.swift`, `ToolConfirmationPresenter.swift` | The single-process SwiftUI implementations of Core's `MCPElicitationHandler` (a server asking the user for input) and `ToolConfirmationChannel` (the user approving a tool call). Install once, render with `.mcpElicitationSheet(_:)` / the confirmation sheet, hand to Core. In 3.0 the confirmation sheet's note follows the call's impact, and a call that must be checked offers no "Always Allow". |
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

### Chat views (new in 3.0)

The parts of a chat app that every SDK chat app writes the same way. They sit over Core's `ChatController`
(a conversation: the turn loop, tool selection, cards, compaction) and `ConversationStore`; what an app does
differently comes in through slots — an empty chat, a banner above the message box, a row under it, extra
controls under a reply, the app's own cards, and the inline widget for an MCP App's view.

| File | What it provides |
|---|---|
| `ChatTranscriptView.swift` | **`ChatTranscriptView`** — the transcript: replies, reasoning, tool calls with their source and impact, the inline cards a turn can end with, files the tools wrote, the "why these tools" chip, Copy / Retry / Edit, and links from content confirmed before they open. `ChatToolDetail` (`.plain`: tool calls as everyday steps; `.detailed`: names, arguments, ratings), `ChatStarterView`, `ChatReplyActionButton`, `ChatReplyContext`. The widget slot takes `LocalLMLabSDKMCPAppsHost`'s `MCPAppWidgetSlot`, which Components doesn't link. |
| `ChatComposer.swift` | **`ChatComposer`** — the message box: text, attachments (picked, dropped, pasted, imported from an iPhone), editing the last message, Send and Stop; a long paste becomes an attachment (`ChatPastedAttachments`). Slots for a banner above and a row under the box (`ChatModelLabel`, status lights). |
| `ChatCards.swift` | The inline cards for a turn that can't start until the user acts, each taking what it shows and what its buttons do: `ClarifyCardView` ("Which one?"), `SignInCardView`, `PermissionCardView`, `ToolChangesCardView` (a server's tools changed), `AddToolSourceCardView`, `AddWorkspaceCardView`, `PastedKeyCardView`, `EmptyReplyCardView`, plus `ChatNoticeView`, `ChatWarningView` and the `ChatCardFrame` they sit in. Their text is fixed; nothing the model wrote appears in them. |
| `ChatSidebar.swift` | **`ChatSidebar`** — the chat list: search, rename, delete, and a footer slot; `ChatEmptyStateView`. |
| `ChatPromptPicker.swift`, `ChatSharedContentPicker.swift` | MCP prompts from a `/` menu or "Use a Prompt…" (arguments in a small form, the source's suggestions offered, the result put in the box to read and edit; the model never picks prompts), and "Attach Shared Content…" in the paperclip menu (content the user's servers share, searchable; what is attached is what the model sees). |
| `ToolChoiceChip.swift` | **`ToolChoiceChip`** — "why these tools" under each reply: which sources were picked, how sure the matcher was, how long it took; tapped, the whole record (`TurnInfo`). |
| `WorkspaceSettingsRow.swift` | `WorkspaceAccessPicker` (read-only / ask before changes / read and write, worded as the user reads them), `WorkspaceSettingsRow` and `WorkspaceSettingsActions` for a Settings screen. |
| `Markdown.swift` | **`MarkdownView`** — a chat reply's Markdown, block by block: headings, lists, quotes, fenced code with Copy (`MarkdownCodeBlock`), pipe tables (`MarkdownTableBlock`); inline syntax through `AttributedString`. `MarkdownParser`, `MarkdownBlock`, `MarkdownStyle`. Streaming text re-parses on each update. |

The shape of a chat window, from a reference chat app built on these (the app supplies the controller, its
status row and its own settings):

```swift
NavigationSplitView {
    ChatSidebar(store: library, selection: currentID, open: { open($0) }, delete: { delete($0) },
                responding: isResponding, notice: busyNote)
} detail: {
    VStack(spacing: 0) {
        ChatTranscriptView(controller: controller, toolDetail: .plain,
                           addWorkspace: { addWorkspace(from: $0, path: $1, access: $2) }) {
            ChatStarterView(message: "Ask anything.", suggestions: [...]) { send($0, attachments: []) }
        } replyExtras: { _ in EmptyView() }
        ChatComposer(controller: controller, isEnabled: hasModel,
                     send: { send($0, attachments: $1) }, addSource: { showAddSource() }) {
            EmptyView()          // a banner above the box
        } leading: {
            EmptyView()          // the row under it: the model's name, status lights
        }
    }
}
```

Core's `ChatSetup` and `ChatConfiguration.standard(lab:setup:dynamicTools:reportError:)` give the standard
wiring of a chat to a `LocalLMLab` with dynamic tools.

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

[`examples/components-updates-demo`](../examples/components-updates-demo/) drives every state of all three views from
simulated sources. [`examples/mlx-control-room`](../examples/mlx-control-room/) shows the same flows against a real
`MLXModelProvider`: pin capture, check / update / roll back, a developer-moved built-in model, and cleanup of old
versions, with the download, pin and verification steps visible as they happen.

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

**Requires an SDK build that has these APIs.** `ModelOnboardingView`'s Pin step reads
`InstalledModel.resolvedRevision`, and the adapter above uses `MLXModelProvider`'s pin-update and snapshot
APIs; every release from `1.0.0-RC.1` (as re-published on 2026-09-18) on has them. If a build fails with a
checksum mismatch or reads like old SDK code, the release assets were replaced in place — run
`scripts/flush-sdk-cache.sh` (SwiftPM caches binary artifacts by URL, not by content).

**Loading never downloads (3.0).** `ModelOnboardingView` is the download step: a model that isn't downloaded
fails to load with `.modelUnavailable`, so run the onboarding stepper (or your own `validate` → `download`) first.

None of these views persist anything themselves. MCP state goes through the
`MCPServerManagerObservable` you own (`manager.core.restore(from:)` at launch); model-layer state
goes through `lab.snapshot()` / `lab.restore(from:)` plus your own Keychain for provider keys.

See [`docs/sdk-guide.md`, "Components"](../docs/sdk-guide.md#components-prebuilt-swiftui-mcp-servers--the-model-layer)
for the narrative walkthrough, [`examples/components-demo/`](../examples/components-demo/) for the
MCP views in a full app, and [`examples/model-switch/`](../examples/model-switch/) for
`AIModelsSettingsView`.

## Building

This is a library, not an app — there's nothing to sign or package, just `swift build`/`swift
test`. `Package.swift` builds against the SDK release named by its `defaultSDKVersion` (3.0.0-GA for
this release), same as the example apps:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Set `LOCALLM_SDK_VERSION` in a shell to build against a different published release — see
`Package.swift`'s `defaultSDKVersion` / `knownSDKReleases`. To actually see these views running,
build and run
[`examples/components-demo`](../examples/components-demo/) instead — it depends on this package as
source, so any local change here is picked up immediately.
