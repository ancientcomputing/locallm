---
name: locallmlab-swift-app
description: Build, debug, or modify macOS Swift and SwiftUI apps that use the LocalLM Lab SDK, including Core connectors, MCP, Components, model providers, sandboxing, signing, and example-based integration patterns.
---

# LocalLM Lab Swift App

Use this skill when helping a developer build a native macOS app with the LocalLM Lab SDK. Prefer the repo's own docs and examples over recalled API details or invented Swift patterns.

## Start With The Right Source

Before editing SDK integration code, read the nearest maintained local reference:

- For SDK concepts, linking, model providers, MCP, connectors, Components, sandboxing, signing, or API shape, use [references/doc-map.md](references/doc-map.md).
- For choosing an example to copy or diff, use [references/example-selector.md](references/example-selector.md).
- For app-bundle, TCC, OAuth, sandbox, and signing work, use [references/macos-integration-checklist.md](references/macos-integration-checklist.md).

If the public API is uncertain, check `docs/api-surface.md` rather than guessing. If the task mentions migration from `0.8.x` or a prior beta, read `docs/migrating-to-1.0.md`.

## Default Decisions

- For a native macOS app, link the SDK directly. Use the `localai-cli` toolkit only for scripts, non-Swift apps, or apps that deliberately want to call the helper binary instead of owning permissions, MCP connections, and tokens.
- Prefer Path A ready-made `Tool`s (`GetUpcomingEventsTool`, `MCPTool`, `WorkspaceTools`, etc.) unless the app needs custom tool names, argument schemas, behavior, or descriptions. Use Path B hand-written adapters when that control matters.
- Match the target feature to the closest example and copy that shape. The examples are maintained as integration references, not throwaway demos.
- Treat Info.plist usage strings, entitlements, OAuth callback routing, App Sandbox settings, and final bundle signing as part of the implementation, not packaging afterthoughts.
- For model-layer work, register macOS-27-only providers behind availability checks and link only the SDK modules the app actually uses.
- For MLX/open-weight model work, validate and probe model capability instead of assuming a model can tool-call.

## Verification

Choose verification that matches the target:

- CLI examples or SwiftPM-only packages: use `swift build` or `swift run` with the repo's expected `DEVELOPER_DIR` when needed.
- SwiftUI `.app` examples: prefer the committed Xcode project or the example's packaging script when testing permissions, URL schemes, sandboxing, or signing behavior.
- If a result depends on Calendar, Reminders, Contacts, Location, OAuth, Keychain, security-scoped bookmarks, or App Sandbox, verify in a real signed `.app` path where feasible; bare `swift run` can be compile-only or misleading.
