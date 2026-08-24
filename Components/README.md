# LocalLMLabSDKComponents

Reusable SwiftUI pieces for managing MCP servers, built entirely on `LocalLMLabSDKCore`'s public
API — no private access to Core's internals. Apache 2.0 licensed, same as the rest of this repo.

| File | What it provides |
|---|---|
| `MCPServerManagerObservable.swift` | An `ObservableObject` wrapper around Core's `MCPServerManager`, so SwiftUI views can observe connection/tool state changes. Also adds `LocalizedError` conformance to Core's `MCPServerError` — human-readable error text is a UI concern Core deliberately doesn't own. |
| `MCPServerPickerView.swift` | The main "add/list/reconnect/disconnect/remove" screen, all three MCP auth types (none, personal access token, OAuth). Lists each server's tools and resources with enable/disable checkboxes, prompts read-only, plus a "Save As…" export (`NSSavePanel` — the one AppKit-specific piece, kept out of Core) built on Core's `MCPServerState.exportSummary()`. |
| `MCPOAuthWaitingView.swift` | A waiting/spinner view shown while an OAuth sign-in is in flight in the system browser. |
| `MCPResourcesPromptsView.swift` | Read-only browsing of a session's enabled resources/resource templates/prompts, with an "Attach"/"Use" action per item that calls Core's `readResource`/`getPrompt` and hands the raw result to a host-supplied callback — no opinion on what "attach" means, same no-persistence-of-its-own precedent as the server picker. |

None of these views persist anything themselves — connecting to a server, enabling a tool, or
resolving a resource all go through the `MCPServerManagerObservable` you own; your app decides
when to call `manager.core.restore(from:)` at launch, same shape Core's own doc comment on that
method describes.

See [`docs/sdk-guide.md` §11](../docs/sdk-guide.md#11-components-prebuilt-swiftui-for-mcp-server-management)
for the narrative walkthrough of wiring these into your own app, and
[`examples/components-demo/`](../examples/components-demo/) for a full working app built on top
of them.

## Building

This is a library, not an app — there's nothing to sign or package, just `swift build`/`swift
test`. `Package.swift` requires an explicit SDK version, same as the example apps:

```bash
LOCALLM_SDK_VERSION=0.8.0 swift build
```

Omitting it, or setting an unknown version, fails fast with a clear error listing the versions
this copy knows about — see `Package.swift`'s `knownSDKReleases` table for the current list. To
actually see these views running, build and run
[`examples/components-demo`](../examples/components-demo/) instead — it depends on this package as
source, so any local change here is picked up immediately.
