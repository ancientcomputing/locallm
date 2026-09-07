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

### Added — `Core` workspace: file-backed tools + the "AIQL" data verbs (`docs/sdk-guide.md` §8b)

The building blocks for a "plain-English query over an MCP-fronted dataset → a CSV file"
pipeline where the row data never passes through the model, so it can't be fabricated.

- **`FileBackedTool`** — a host-applied decorator around a dynamic-schema tool (an MCP tool is
  the motivating case). Adds a root-level `saveAs` argument; when the model supplies it, the
  wrapped tool's raw result is written to `<workspace>/<saveAs>` and only a short receipt
  (byte/line count + a bounded preview) returns — the payload never enters the model's
  context. `saveAsAppend` accumulates paginated results. `FileBackedTool.mcp(descriptor:manager:root:)`
  wraps an `MCPToolDescriptor` in one call.
- **The data verbs** — ready-made `Tool`s, each reads a workspace file, does one mechanical
  transform, writes a CSV, returns a one-line receipt: `jsonToCsv` (project a JSON array to
  CSV), `selectColumns`, `filterRows` (`eq`/`contains`/`matches`/`gt`/… , AND or ANY),
  `sortRows` (with `limit` — the mechanical "top N"), `dedupeRows`, `aggregateRows`
  (`count`/`sum`/`avg`/`min`/`max`), `concatRows` (`UNION ALL`), plus `describeJson` /
  `csvInfo` for discovery and per-stage verification. `jsonToCsv` / `describeJson` read a file
  of concatenated JSON values (appended paginated pages).
- **`CSVCodec`** (RFC 4180 encode/decode + a header-keyed `Table`) and **`JSONPath`** (a
  read-only `a.b[0].c` resolver over a `JSONSerialization` value) are `public` for building
  your own verbs.
- **`WorkspaceAccess.writeFile` / `WriteWorkspaceFileTool`** gain `overwrite:` (create-only by
  default) and `append:`.

### Fixed — `Core` workspace

- **`resolveScopedPath`** dropped the workspace root's last path component during relative
  resolution when the root `URL` had no trailing slash (`someURL.appendingPathComponent("ws")`,
  `URL(fileURLWithPath: aString)`), so every nested write (`raw/data.json`) was rejected as an
  escape. Also handles `resolvingSymlinksInPath` rewriting `/private/tmp` → `/tmp` on
  not-yet-existing paths.

### Added — examples

- **[`examples/model-switch/`](examples/model-switch/)** — the reference app for the online
  providers: add a provider + key, tick web search, and switch between every configured model
  (Apple on-device, PCC, Claude-4-FM, GPT, Claude online, any OpenRouter model) from one chat
  window, one `lab.makeSession` call site. Links `Remote` as a binaryTarget and Core +
  `Components` from the `Components` package.
- **[`examples/aiql/`](examples/aiql/)** — "ask your data": a SwiftUI app (Core + Inference,
  sandboxed) that pulls an MCP-fronted dataset and writes the spreadsheet you asked for, via
  `FileBackedTool` + the data verbs. MCP OAuth through the `aiql://` URL scheme; the progress
  panel is driven by `session.events`.

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
LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip       2600da14b13e3bfcf8d33491a5f4a8fb7406fc5d314a20ba491348a029898d8c
LocalLMLabSDKClaude-1.0.0-beta.3.xcframework.zip     248e23d3c4836fb4d7018afdd8001cb8c7a3f207c4569bf98bd1738422150982
LocalLMLabSDKInference-1.0.0-beta.3.xcframework.zip  5ce9b4481f6509fffb460d45cf230d3e2711a01082ca779525363141c2e2646b
LocalLMLabSDKRemote-1.0.0-beta.3.xcframework.zip     71edcf700058a1ca60f7aa101894e6219ef9a6e0d7f3a8ff1539f5e446e5d9dd
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
