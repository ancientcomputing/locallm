# Migrating to the LocalLM Lab SDK 1.0

1.0 (`1.0.0-beta.N`, `1.0.0` at GA) has a **macOS 26 deployment floor** as of `1.0.0-beta.2`.
One app runs on macOS 26 and macOS 27 from a single build — Private Cloud Compute, Claude, and
open-weight (MLX) models are simply absent on 26. (The `0.8.x` SDK series — MCP client and
connectors, no model layer — continues separately for consumers that don't want it.)

The jump from `0.8.x` is **mostly additive**: the connectors and Keychain storage are unchanged,
and every MCP server that worked still works. What's new is the model layer and a batch of MCP
spec-2025-11-25 capabilities (`sdk-guide.md` §3a–§3e); what can break your build is one
enum-resilience change, one MCP return-type change, and — if you wrote a custom `ModelProvider`
— one protocol change.

## 1. Platform: macOS 26 floor, Xcode 27 to build

```diff
  platforms: [.macOS("26.0")],
```

No platform bump — `1.0.0-beta.2` keeps the `0.8.x` floor. You still need the **Xcode 27 beta**
to build: the xcframeworks are compiled with the macOS 27 SDK (27-only symbols weak-linked), and
a stable Xcode fails with `'v27' is unavailable`. Register the macOS-27-only providers behind
`if #available(macOS 27, *)` — see [`sdk-guide.md` §1a](sdk-guide.md).

## 2. Point your manifest at the new release

The `examples/*/Package.swift` files resolve each SDK module as a `binaryTarget` off a URL +
checksum, keyed by version. A newer version is a new entry:

```swift
"1.0.0-beta.3": SDKRelease(
    url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
    checksum: "<the .sha256 asset next to the zip on that release>"
),
```

The example manifests build against `defaultSDKVersion` with no environment variable (so
"clone, open in Xcode, Run" works); `LOCALLM_SDK_VERSION` overrides it from a shell. Your own
app's manifest can do the same, or just hardcode one `binaryTarget(url:checksum:)`.

The release carries **four** xcframeworks (all on the one tag):

| xcframework | link it when | floor |
|---|---|---|
| `LocalLMLabSDKCore` | always | macOS 26 |
| `LocalLMLabSDKInference` | you run open-weight / MLX models | macOS 26 (register `MLXModelProvider` only on 27) |
| `LocalLMLabSDKClaude` | you offer Claude via Foundation Models | **macOS 27** — forces a 27 deployment target on whatever links it |
| `LocalLMLabSDKRemote` | you offer online providers (GPT / Claude online / OpenRouter) | macOS 26 manifest floor; `RemoteModelProvider` is `@available(macOS 27)` |

`ClaudeModelProvider` moved out of Core into `LocalLMLabSDKClaude` (its dependency
`ClaudeForFoundationModels` is macOS-27-pinned). See
[`examples/code-buddy/Package.swift`](../examples/code-buddy/Package.swift) (Core + Inference)
and [`examples/model-switch/Package.swift`](../examples/model-switch/Package.swift) (Remote +
`Components`) for the multi-binary manifest shapes.

## 3. The one thing that can break your build: non-frozen enums

Several enums are now **non-frozen** — a minor version can add a case. If your code `switch`es
over one of these *exhaustively* (no `default`), the compiler now requires `@unknown default`:

- `MCPConnectionStatus`, `MCPServerError` — existed in `0.8.x`; **this is the only source-break
  if you use just the MCP client.**
- `ModelAvailability`, `ResidencyEvent`, `SessionEvent`, `DownloadEvent` — new in 1.0.
  (`ModelAvailability.UnavailableKind` gained a `.requiresOS(String)` case in `1.0.0-beta.2`;
  `@unknown default` already covers it.)

### `MCPServerManager.callTool` now returns `MCPToolResult`, not `String`

`callTool(server:tool:arguments:)` was `-> Result<String, MCPServerError>`; it's now
`-> Result<MCPToolResult, MCPServerError>` (§3b), and takes an `allowElicitation: Bool = true`.
If you call it directly:

```diff
- case .success(let text):
-     feedToModel(text)
+ case .success(let result):
+     feedToModel(result.renderedForModel)   // same string you had before, plus structured/link/error folding
```

A tool that *ran* but reported failure is now `.success` with `result.isError == true` (it used
to be `.failure(.serverError(...))` in some cases). The `MCPTool` / `FileBackedTool` adapters
absorb all of this — no change if you go through them.

### Custom `ModelProvider` conformances (only if you wrote one)

The protocol requirement changed from `languageModel(for:) -> any LanguageModel` (Apple's
`LanguageModel` protocol is macOS 27) to:

```swift
func makeSession(for id: ModelID, tools: [any Tool], instructions: String?,
                 transcript: Transcript?) throws -> LanguageModelSession
```

Your provider now builds the Apple `LanguageModelSession` for its model — which is what lets the
model layer run on macOS 26. `lab.makeSession(route:…)` and every built-in provider are
unchanged.

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
- `ModelProvider` + `SystemModelProvider` (Core), `PCCModelProvider` (Core, macOS 27),
  `ClaudeModelProvider` (`LocalLMLabSDKClaude`, macOS 27), `MLXModelProvider` (Inference,
  macOS 27). On macOS 26 `lab.models.availability(for:)` reports the 27-only schemes as
  `.requiresOS("macOS 27")` and `lab.models.schemesRequiringNewerOS` lists them.
- `RouteName` + `lab.models.route(_:to:)` — name a model (`.heavy` / `.light` / …), pick one
  per session.
- `lab.makeSession(route:tools:instructions:)` → `LocalLMLabSession` — a session with your
  tools **and** the enabled MCP tools merged; `.events` for tool-call / compaction progress;
  `contextBudget` + `retryOnContextOverflow` for long sessions.
- `MLXModelProvider` — `validate` (preflight, no download) → `download` (streamed) →
  `capabilityProbe`; `residentModelLimit`, `MLXPreflightLimits`, `residencyEventStream` for
  the memory story on a constrained Mac.

Since `1.0.0-beta.3`, also **online providers** (`sdk-guide.md` §6b) — GPT, Claude's online
Messages API, OpenRouter, or any OpenAI-compatible server, with provider-native web search,
behind the same `lab.makeSession(route:)`. Add the `LocalLMLabSDKRemote` binaryTarget,
`import LocalLMLabSDKRemote`, register `RemoteModelProvider(config)`. Nothing about the
existing model layer changes.

Also since `1.0.0-beta.3`, **`FileBackedTool` + the "AIQL" data verbs** in Core (`sdk-guide.md`
§8b) — `jsonToCsv` / `filterRows` / `sortRows` / `concatRows` / `describeJson` / `csvInfo` and
friends, for an MCP-dataset → CSV pipeline where the row data never passes through the model.
Purely additive: new `Tool` structs plus `CSVCodec` / `JSONPath` building blocks and an
`append:` option on `WorkspaceAccess.writeFile`. [`examples/aiql`](../examples/aiql/) is the
worked app.

Also new on the **MCP client** (`sdk-guide.md` §3a–§3e), all backward compatible:

- The client negotiates **MCP `2025-11-25`** (down to `2024-11-05`). Older servers are
  unaffected; `MCPServerState.negotiatedProtocolVersion` reports where each landed.
- **Structured tool results** — `MCPToolResult.structuredContent` / `resourceLinks` / `isError`
  / `truncated`, validated against the tool's `outputSchema`.
- **Elicitation** — servers can pause a tool call to ask the user for input. Register
  `MCPClientHandlers(elicitation:)`; `LocalLMLabSDKComponents` ships the SwiftUI form
  (`MCPElicitationPresenter` + `.mcpElicitationSheet`). Sampling / roots have handler seams too.
- **CIMD** — `MCPOAuthFlow.clientMetadataURL` as an alternative to Dynamic Client Registration.
- **`MCPDiagnostics`** — off-content connection/auth/stream logging for support.

None of this is required — a `LanguageModelSession` you build yourself with Core's tools still
works exactly as in `0.8.x`, and an app that never touches elicitation or `clientMetadataURL`
needs no code changes beyond the `callTool` return type above.

## Beta caveats

- The built app runs on **macOS 26 or 27**; building the SDK against `1.0` needs the **Xcode 27
  beta** until it GAs.
- `1.0.0-beta.N` makes **no API-stability guarantee** — signatures can move between betas.
- All xcframeworks (`Core`, `Claude`, `Inference`, `Remote`) are Developer-ID-signed and
  notarized. SwiftPM still verifies them by checksum; a consumer embedding them in a notarized
  app re-signs as part of its own build.
