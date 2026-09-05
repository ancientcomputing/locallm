# Changelog — LocalLM Lab SDK

This tracks the **public SDK surface** (`LocalLMLabSDKCore`, `LocalLMLabSDKClaude`,
`LocalLMLabSDKInference`, `LocalLMLabSDKRemote`, `LocalLMLabSDKComponents`) as consumed from
this repo. Dates are release dates. Each version maps to a GitHub Release on
`ancientcomputing/locallm` (tag `v<version>`); the xcframework checksums live on the release,
not here.

**As of `1.0.0-beta.2`, the whole SDK builds for macOS 26** — the model layer works on
macOS 26 with `SystemModelProvider` only; Private Cloud Compute / Claude / open-weight (MLX)
models still need macOS 27. See the `1.0.0-beta.2` notes below and
[`docs/sdk-guide.md` §1a](docs/sdk-guide.md).

## 1.0.0-beta.3 — 2026-09-05

Two headline additions: **online providers** (a new `LocalLMLabSDKRemote.xcframework` — GPT /
Claude / OpenRouter / any OpenAI-compatible server, over HTTP, with provider-native web
search) and a **rebuilt Private Cloud Compute provider**.

### Added — online / remote providers (`LocalLMLabSDKRemote.xcframework`, new — a 4th binary)

- **`RemoteModelProvider`** — one `ModelProvider` for any HTTP model API. Pure `URLSession`,
  no third-party dependencies, no bundle resources. macOS 26 *manifest* floor (linking it
  does **not** force a macOS 27 deployment target); `RemoteModelProvider` itself is
  `@available(macOS 27)` and reports `.requiresOS("macOS 27")` on 26. Add the
  `LocalLMLabSDKRemote` binaryTarget keyed off the same `LOCALLM_SDK_VERSION`.
- **`RemoteProviderConfig`** — a data-driven provider description (scheme, dialect, base URL,
  auth, models, capabilities, per-provider default `SessionOptions`). Dialects:
  `.openAIChat`, `.openAIResponses`, `.anthropicMessages`, and `.openAICompatible` as an
  escape hatch. No vendor is privileged — Claude-via-HTTP is just another config. Presets:
  `.openAI`, `.openAIResponses`, `.anthropic`, `.openRouter`, `.openAICompatible`.
- **The SDK ships no default model ids.** Every preset defaults `models: []`; which model id
  is current and good enough is the host app's call, on its own release cadence — see
  [`examples/model-switch`](examples/model-switch/) for the pattern.
- **`RemoteModelProvider.probe(for:timeout:)`** — a zero-token connectivity / key / model
  check. `GET {base}/models` (OpenAI-style list) or `GET {base}/v1/models/{id}`
  (Anthropic-style); maps the outcome to `.available` / `.needsCredential` (401/403) /
  `.unsupportedModel` (404 or absent from the list) / `.providerError` (429 / 5xx / timeout).
  Run it before offering a provider — remote models have far more failure modes than local.
- **Provider-native web search** via `SessionOptions(webSearch:webSearchMaxUses:)` on OpenAI,
  Anthropic Messages, and OpenRouter — and, new this release, on **`ClaudeModelProvider`**
  (Claude-via-Foundation-Models). `LocalLMLabSession.events` surfaces `.serverToolCall`
  (query + result count) and `session.citations` carries the sources.
- **`ServerTool`** — the abstraction for provider-executed tools (web search is the first).
- **`ModelRegistry.replace(_:)` / `.removeProvider(scheme:)`** — reconfigure the registry at
  runtime (add/replace/drop a provider between sessions) without rebuilding `LocalLMLab`.

### Added — `Components` (the AI Models settings surface)

- **`AIModelsSettingsView`** — the whole panel: built-in models + one `ProviderSettingsSection`
  per configured online provider + an "Add provider" menu.
- **`ProviderSettingsSection`** — one provider: API-key field, a **Configured ✓** badge, a
  per-model list (add / remove rows), an **Enable web search** toggle + **Max searches**
  stepper once configured, and a **Test connection** button (one result per configured model,
  via the host's `probe(for:)`).
- **`RemoteProviderDraft`** / **`ProviderTestOutcome`** — plain data types the host maps to
  `RemoteProviderConfig` in ~30 lines. `Components` has **no dependency on `Remote`** —
  coordination is via optional closures (`onSave` / `onRemove` / `onTest`), so a macOS-26
  chooser can present the panel and hand the work to a 27-only helper.

### Added — Private Cloud Compute

**`PCCModelProvider` rebuilt** on the real `FoundationModels.PrivateCloudComputeLanguageModel`
surface (macOS 27) — availability, quota, and typed errors map to clean `ModelAvailability`
values instead of an opaque "routed to `pcc` fails" reaching the host (roadmap items 10/14).

> **On PCC access:** Apple's PCC tier is free but gated — your shipping app needs the
> **Private Cloud Compute entitlement**, enrollment in the **App Store Small Business
> Program**, and fewer than 2M first-time downloads. There is no paid tier. See
> [`developer.apple.com/private-cloud-compute`](https://developer.apple.com/private-cloud-compute/).

- **`PCCModelProvider.probe(timeout:)`** — an `async` liveness check. `availability(for:)`
  reads only the synchronous `PrivateCloudComputeLanguageModel.availability`, which on some
  Developer-ID builds reports `.available` while every turn still throws at request time.
  `probe()` runs one minimal request and maps the outcome — a typed
  `PrivateCloudComputeLanguageModel.Error` **or** the opaque `ModelManagerError` 1046
  ("The model service failed") — to a `ModelAvailability`. Hosts that gate a `pcc` route
  should call this and cache the verdict.
- **`availability(for: .pcc)`** now folds in `PrivateCloudComputeLanguageModel.quotaUsage`:
  a spent free-tier quota reports `.unavailable(kind: .providerError)` with the reset date
  rather than `.available`.

### Added — example

- **[`examples/model-switch/`](examples/model-switch/)** — the reference app for the online
  providers: add a provider + key, tick web search, and switch between every configured model
  (Apple on-device, PCC, Claude-4-FM, GPT, Claude online, any OpenRouter model) from one chat
  window, one `lab.makeSession` call site. Links `Remote` as a binaryTarget and Core +
  `Components` from the `Components` package.

### Changed

- **`SessionOptions`** — new per-query knobs, threaded through `makeSession` /
  `session.respond`: `webSearch`, `webSearchMaxUses`, plus sampling overrides. A provider that
  can't honor a knob ignores it.
- **`GenerationErrorDescription`** gains a dedicated arm for
  `PrivateCloudComputeLanguageModel.Error`: a spent-quota failure now names its reset date
  and the Small Business Program gate instead of rendering as a thin `LocalizedError`.
- **`Components/Package.swift`** re-vends `LocalLMLabSDKCore` as a `.library` product so an
  app that consumes `Components` *and* declares its own `Remote` binaryTarget doesn't hit a
  duplicate-`LocalLMLabSDKCore`-target collision (`model-switch` needs this).

### Checksums (SHA-256)

```
LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip       a276ab7bdbdaa2be64ccfda45e66eabeb22c33be3246a1bea53be8f5c8998592
LocalLMLabSDKClaude-1.0.0-beta.3.xcframework.zip     75f446bbaf449f6dcee300f1d30637c384017ee84e1f5d62cf0167b2c382c2e9
LocalLMLabSDKInference-1.0.0-beta.3.xcframework.zip  d99aaa9fd703afe51bf9b6f5636819527ae001c5e07efe4e07159b824681dda2
LocalLMLabSDKRemote-1.0.0-beta.3.xcframework.zip     12bb263dc4ffd5d05101d422fed0dbb67086412370d665f8c2427edd0aadd142
```

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
