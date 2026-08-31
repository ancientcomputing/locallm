# Migrating to the LocalLM Lab SDK 1.0

1.0 (`1.0.0-beta.N`, `1.0.0` at GA) **requires macOS 27**. The macOS 26, MCP-only `0.8.x`
releases continue separately — if you don't need macOS 27, stay there.

The jump from `0.8.x` is **mostly additive**: the MCP client, the connectors, and Keychain
storage work the same. What's new is the model layer; what can break your build is one
enum-resilience change and the platform bump.

## 1. Platform: macOS 27 + Xcode 27

```diff
- platforms: [.macOS("26.0")],
+ platforms: [.macOS("27.0")],
```

Core's model layer is built on FoundationModels' `LanguageModel` protocol, which is macOS 27.
Building against a stable Xcode fails with `'v27' is unavailable` — you need Xcode 27.

## 2. Point `knownSDKReleases` at the new release

```swift
"1.0.0-beta.1": SDKRelease(
    url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.1/LocalLMLabSDKCore-1.0.0-beta.1.xcframework.zip",
    checksum: "<from the release's .sha256 asset>"
),
```

If you use the model layer you also link a **second** binary,
`LocalLMLabSDKInference.xcframework` (the MLX runtime), from the same release — see
[`examples/code-buddy/Package.swift`](../examples/code-buddy/Package.swift) for the two-binary
manifest shape.

## 3. The one thing that can break your build: non-frozen enums

Several enums are now **non-frozen** — a minor version can add a case. If your code `switch`es
over one of these *exhaustively* (no `default`), the compiler now requires `@unknown default`:

- `MCPConnectionStatus`, `MCPServerError` — existed in `0.8.x`; **this is the only source-break
  for an MCP-only consumer.**
- `ModelAvailability`, `ResidencyEvent`, `SessionEvent`, `DownloadEvent` — new in 1.0.

```diff
  switch server.connectionStatus {
  case .connected:    …
  case .connecting:   …
  case .disconnected: …
  case .failed:       …
+ @unknown default:   …   // pick a sensible fallback
  }
```

Nothing was renamed or removed. If a build error looks like more than this, it's a bug — file it.

## 4. `LocalLMLabSDKVersion.current`

Now stamped from the release version at build time (was a hardcoded string). A release
xcframework reports its exact tag; a source/path build reports the committed in-dev version.
No API change — just accurate now.

## 5. What's new (opt in when you want it)

The **model layer** (`sdk-guide.md` §6a) — offer Apple's on-device model, Claude, and
locally-run open-weight (MLX) models behind one API, with routing and residency the SDK owns:

- `LocalLMLab` — the optional front door bundling the model registry, MCP manager, and
  connector/workspace facades.
- `ModelProvider` + `SystemModelProvider` / `PCCModelProvider` / `ClaudeModelProvider` (Core)
  and `MLXModelProvider` (Inference).
- `RouteName` + `lab.models.route(_:to:)` — name a model (`.heavy` / `.light` / …), pick one
  per session.
- `lab.makeSession(route:tools:instructions:)` → `LocalLMLabSession` — a session with your
  tools **and** the enabled MCP tools merged; `.events` for tool-call / compaction progress;
  `contextBudget` + `retryOnContextOverflow` for long sessions.
- `MLXModelProvider` — `validate` (preflight, no download) → `download` (streamed) →
  `capabilityProbe`; `residentModelLimit`, `MLXPreflightLimits`, `residencyEventStream` for
  the memory story on a constrained Mac.

None of this is required — a `LanguageModelSession` you build yourself with Core's tools still
works exactly as in `0.8.x`.

## Beta caveats

- **Requires the macOS 27 beta** (and Xcode 27 beta) until both GA.
- `1.0.0-beta.N` makes **no API-stability guarantee** — signatures can move between betas.
- Both xcframeworks are Developer-ID-signed and notarized. SwiftPM still verifies them by
  checksum; a consumer embedding them in a notarized app re-signs as part of its own build.
