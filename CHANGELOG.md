# Changelog — LocalLM Lab SDK

This tracks the **public SDK surface** (`LocalLMLabSDKCore`, `LocalLMLabSDKInference`,
`LocalLMLabSDKComponents`) as consumed from this repo. Dates are release dates. Each version
maps to a GitHub Release on `ancientcomputing/locallm` (tag `v<version>`); the xcframework
checksums live on the release, not here.

**1.0 requires macOS 27.** The macOS 26 `0.8.x` line (MCP client + connectors, no model layer) continues separately.

## 1.0.0-beta.1 — 2026-08-30

First release requiring macOS 27. **Requires the macOS 27 + Xcode 27 betas.** Coming from
`0.8.x`? See [`docs/migrating-to-1.0.md`](docs/migrating-to-1.0.md) — the jump is mostly
additive.

### Added — the model layer

A new layer for running models, opt-in and orthogonal to the MCP/connector surface that has
been here since `0.7.0`. Full walkthrough: [`docs/sdk-guide.md` §6a](docs/sdk-guide.md).

- **`LocalLMLabSDKInference.xcframework`** — a second binary (the MLX runtime), linked from
  the same release only when you use local open-weight models. See
  [`examples/code-buddy/Package.swift`](examples/code-buddy/Package.swift) for the two-binary
  manifest shape.
- **`LocalLMLab`** — optional front door bundling the model registry, MCP manager, and
  connector/workspace facades behind one object.
- **`ModelProvider`** protocol + built-ins: `SystemModelProvider` / `PCCModelProvider` /
  `ClaudeModelProvider` (Core) and `MLXModelProvider` (Inference). **`PCCModelProvider` is not
  functional in `1.0.0-beta.1`** — a session routed to `pcc` fails; fix targeted for a later
  release. The other three work.
- **`RouteName`** + `lab.models.route(_:to:)` — name a model (`.heavy` / `.light` / …) and
  pick one per session.
- **`lab.makeSession(route:tools:instructions:)`** → `LocalLMLabSession` — a session with
  your tools *and* the enabled MCP tools merged; `.events` for tool-call / compaction
  progress; `contextBudget` + `retryOnContextOverflow` for long sessions.
- **`MLXModelProvider`** — `validate` (preflight, no download) → `download` (streamed) →
  `capabilityProbe`; `residentModelLimit`, `MLXPreflightLimits`, `residencyEventStream` for
  the memory story on a constrained Mac. See [`docs/tested-models.md`](docs/tested-models.md)
  for which open-weight models actually tool-call.
- **`Components`**: `ModelPickerView`, `ClaudeAuthField`.
- New example: [`examples/code-buddy/`](examples/code-buddy/) — a CLI coding agent that
  exercises the entire model layer, plus the host-owned `Process`-tool pattern (git /
  run-tests tools the SDK deliberately doesn't ship).

### Changed

- **Platform floor is `macOS 27`.** Core's model layer builds on FoundationModels'
  `LanguageModel` protocol (macOS 27); a stable Xcode fails with `'v27' is unavailable`.
- **`LocalLMLabSDKVersion.current`** is now stamped from the release version at build time
  (was a hardcoded string). A release xcframework reports its exact tag; a source/path build
  reports the committed in-dev version.

### Source-breaking (one compile change)

- Several enums are now **non-frozen** — an exhaustive `switch` (no `default`) requires
  `@unknown default`:
  - `MCPConnectionStatus`, `MCPServerError` — existed in `0.8.x`; **the only source-break
    for an MCP-only consumer.**
  - `ModelAvailability`, `ResidencyEvent`, `SessionEvent`, `DownloadEvent` — new in 1.0.
- Nothing was renamed or removed. A larger break is a bug — please file it.

### Beta caveats

- Requires the macOS 27 + Xcode 27 betas until both GA.
- `1.0.0-beta.N` makes **no API-stability guarantee** — signatures can move between betas.
- Both xcframeworks are Developer-ID-signed and notarized (SwiftPM still verifies them by
  checksum; a consumer embedding them in a notarized app re-signs as part of its own build).
- The MLX bridge streams model chain-of-thought (`<think>…</think>` etc.) inline in the
  response text — no separate reasoning channel yet.
- LAN cross-machine access is lightly tested.

---

## 0.8.0 — 2026-08-24

- The macOS 26 `0.8.x` line. MCP client + connectors + Keychain storage. `LocalLMLabSDKCore` only.
- Continues for consumers that don't need macOS 27.

## 0.7.1 — 2026-08-16

- Patch release on `LocalLMLabSDKCore`.

## 0.7.0 — 2026-08-14

- First public SDK release: `LocalLMLabSDKCore` as a binary `xcframework`, `knownSDKReleases`
  consumption pattern, `LocalLMLabSDKComponents` (prebuilt MCP SwiftUI), the initial reference
  apps (`plate-today`, `plate-today-tools`, `repo-qa`, `workspace-buddy`, `components-demo`),
  Calendar / Reminders / Contacts connectors, full MCP client (tool discovery, OAuth,
  Keychain-backed token storage), Core Workspace tools.
