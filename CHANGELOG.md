# Changelog — LocalLM Lab SDK

This tracks the **public SDK surface** (`LocalLMLabSDKCore`, `LocalLMLabSDKInference`,
`LocalLMLabSDKComponents`) as consumed from this repo. Dates are release dates. Each version
maps to a GitHub Release on `ancientcomputing/locallm` (tag `v<version>`); the xcframework
checksums live on the release, not here.

**As of `1.0.0-beta.2`, the whole SDK builds for macOS 26** — the model layer works on
macOS 26 with `SystemModelProvider` only; Private Cloud Compute / Claude / open-weight (MLX)
models still need macOS 27. See the `1.0.0-beta.2` notes below and
[`docs/sdk-guide.md` §1a](docs/sdk-guide.md).

## 1.0.0-beta.2 — 2026-09-02

**The SDK now builds one app for macOS 26 and macOS 27.** `LocalLMLabSDKCore`,
`LocalLMLabSDKInference`, and `LocalLMLabSDKComponents` all have a **macOS 26 deployment
floor**. Register `SystemModelProvider()` always and the macOS-27-only providers inside one
`if #available(macOS 27, *)` block; `makeSession`, `respond`, `events`, connectors, MCP, and
the pickers are identical code on both OSes.

### Breaking

- **`ClaudeModelProvider` moved to a new `LocalLMLabSDKClaude.xcframework`** — a third binary
  on the release. It can't live in the macOS-26-floored Core because
  `ClaudeForFoundationModels` is hard-pinned to macOS 27. If you use Claude: add the
  `LocalLMLabSDKClaude` binaryTarget (keyed off the same `LOCALLM_SDK_VERSION`), `import
  LocalLMLabSDKClaude`, and accept a **macOS 27** deployment target on the target that links
  it. To ship a macOS 26 app *and* offer Claude, put the Claude path in a separate 27-only
  target (the LocalLM Lab app splits its `--serve` helper this way).
- **`ModelProvider` protocol**: `languageModel(for:) -> any LanguageModel` →
  `makeSession(for:tools:instructions:transcript:) -> LanguageModelSession`. Apple's
  `LanguageModel` protocol is macOS 27; having the provider build its own session is what
  lets the model layer run on macOS 26. Only affects custom `ModelProvider` conformances —
  `lab.makeSession(route:…)` is unchanged.

### Added

- **`ModelAvailability.UnavailableKind.requiresOS(String)`** + **`ModelRegistry.schemesRequiringNewerOS`**.
  On macOS 26, `lab.models.availability(for: .pcc)` returns `.requiresOS("macOS 27")`.
- **`ModelPickerView`** shows PCC / Claude / MLX as disabled "Requires macOS 27" rows on
  macOS 26. New `init(registry:selection:show27OnlyModels: Bool = true)` to hide them.
- **`examples/os-matrix`** — one `.macOS("26.0")` CLI that runs on both OSes, no source `#if`.

### Fixed

- FoundationModels errors that surfaced as *"The operation couldn't be completed. (…error -1.)"*
  now decode to the real cause (context overflow / guardrail / assets unavailable / …) on
  both macOS 26 and macOS 27.
- `plate-today`, `plate-today-tools`, `repo-qa`, `workspace-buddy` had a `.macOS("27.0")`
  platform floor but use only the on-device system model — they now build with a
  `.macOS("26.0")` floor and launch on macOS 26. The `*-local` examples and `code-buddy`
  stay macOS 27 (they run open-weight models via MLX).

### Checksums (SHA-256)

```
LocalLMLabSDKCore-1.0.0-beta.2.xcframework.zip       e3e687e503d3c563e6548b472dc8eb415475f0402845e9b4a56c58c15105c974
LocalLMLabSDKClaude-1.0.0-beta.2.xcframework.zip     fd0489be28f6c1dc589161d978ef39718605c01483eebd0efc29e206e406525f
LocalLMLabSDKInference-1.0.0-beta.2.xcframework.zip  728bc399a96a851f1e46c6f709684133f40dc09b067a0717e1898ab11156e8a8
```

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

- The macOS 26 `0.8.x` series. MCP client + connectors + Keychain storage. `LocalLMLabSDKCore` only.
- Continues for consumers that don't want the model layer.

## 0.7.1 — 2026-08-16

- Patch release on `LocalLMLabSDKCore`.

## 0.7.0 — 2026-08-14

- First public SDK release: `LocalLMLabSDKCore` as a binary `xcframework`, `knownSDKReleases`
  consumption pattern, `LocalLMLabSDKComponents` (prebuilt MCP SwiftUI), the initial reference
  apps (`plate-today`, `plate-today-tools`, `repo-qa`, `workspace-buddy`, `components-demo`),
  Calendar / Reminders / Contacts connectors, full MCP client (tool discovery, OAuth,
  Keychain-backed token storage), Core Workspace tools.
