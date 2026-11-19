# Online providers — GPT, Claude online, OpenRouter (`LocalLMLabSDKRemote`)

Using hosted models through `LocalLMLabSDKRemote`. Part of [the model layer](sdk-guide.md#the-model-layer-models-routing-and-sessions).


> **Reach for this when** you want a hosted model API — OpenAI, Anthropic's Messages API,
> OpenRouter, or any OpenAI-compatible server — behind the *same* `lab.makeSession(route:)` call
> site as the on-device and local models, ideally with the provider running web search for you.
>
> **Examples that use it:** [`model-switch`](../examples/model-switch/) is the reference app —
> add a provider, tick web search, switch models mid-conversation, streamed search activity +
> citation links, all through `Components`' `AIModelsSettingsView`.

`LocalLMLabSDKRemote.xcframework` is a **4th binary** on the release, added the same way as
`Inference` / `Claude` — a `binaryTarget` keyed off `LOCALLM_SDK_VERSION`. It has **no
third-party dependencies** (pure `URLSession`). Its manifest floor is macOS 26, so linking it
does **not** force a macOS 27 deployment target; `RemoteModelProvider` itself is
`@available(macOS 27)` and reports `.requiresOS("macOS 27")` on 26 — so a macOS-26 app can link
it and just not register it below 27.

```swift
import LocalLMLabSDKRemote

// One data-driven config per provider. A preset fills in the dialect + base URL + auth shape;
// YOU supply the model ids — the SDK ships none (which id is current/good is your call).
var openai = RemoteProviderConfig.openAI(apiKey: key, models: [RemoteModel(id: "gpt-…")])
openai.capabilities.insert(.webSearch)
openai.defaultOptions.webSearch = true              // provider runs the search; no MCP needed

lab.models.replace(try RemoteModelProvider(openai)) // validates, then registers / re-registers
lab.models.route("chat", to: ModelID(scheme: "openai", rest: "gpt-…")!)
let answer = try await lab.makeSession(route: "chat").respond(to: prompt)
```

- **`RemoteProviderConfig`** — `scheme`, `dialect` (`.openAIChat` / `.openAIResponses` /
  `.anthropicMessages` — three, not four; a custom OpenAI-compatible server still speaks
  `.openAIChat`, just at a different `baseURL`), `baseURL`, `auth` (`.apiKey(_:)` for the common
  case; `.header(name:value:)` for a server that wants its key in a non-standard header instead
  of `Authorization`; `.none` for a server with no auth at all), `models`, `capabilities`,
  `defaultOptions`. No vendor is privileged — Claude-over-HTTP is just `dialect:
  .anthropicMessages`. Presets: `.openAI`, `.openAIResponses`, `.anthropic`, `.openRouter`,
  `.openAICompatible` (the last one sets `.openAIChat` under the hood).
- **`RemoteModelProvider.probe(for:timeout:)`** — a **zero-token** check of key + model +
  reachability. Returns `.available` / `.needsCredential` (401/403) / `.unsupportedModel`
  (404 or absent from `GET /models`) / `.providerError` (429 / 5xx / timeout). Call it before
  offering a provider — a hosted API has far more failure modes than a local model.
- **`ModelRegistry.replace(_:)` / `.removeProvider(scheme:)`** — add, swap, or drop a provider
  between sessions without rebuilding `LocalLMLab`.
- **Transport hardening + `RemoteProviderConfig.responseLimits`** — every
  request runs over a hardened ephemeral session (explicit request *and* resource timeouts, no
  cache, no cookies), and streamed/response bytes, a single SSE frame, emitted text, and
  accumulated tool-call arguments are all capped — a misbehaving or hostile endpoint throws
  `RemoteError.responseTooLarge(_:)` instead of growing memory/context/latency unbounded. The
  defaults suit a normal provider; override `responseLimits` per-config for an endpoint you trust
  less, or one you know returns unusually large payloads.
- **Web search** — set `capabilities.insert(.webSearch)` + `defaultOptions.webSearch = true`
  (per-provider), or `SessionOptions(webSearch: true)` per turn. Works on OpenAI, Anthropic
  Messages, OpenRouter, and `ClaudeModelProvider` (Foundation Models). `session.events` yields
  `.serverToolCall(ServerToolActivity)` — its `.kind` is `.webSearch(queries:hits:)`, `hits`
  being `[WebHit]` (`url`/`title`/`snippet`) — so a "Searched: …" activity line doesn't need to
  wait for the final answer. `session.citations: [Citation]` (`url`/`title`/`citedText`) carries
  the sources once the turn finishes (filled in by `respond` / `streamResponse`; after a turn on
  `languageModelSession`, call `reconcileServerToolArtifacts()` first — [Running a turn](sdk-guide.md#running-a-turn-and-when-to-use-languagemodelsession)) — render these as footnotes, since a provider's web-search
  answer without visible sources reads as an unverifiable claim. `SessionOptions.userLocation`
  (`city`/`region`/`country`/`timezone`) localizes results when the provider supports it — set
  it if your search-heavy queries are location-sensitive ("restaurants near me").

**`RemoteModelProvider.init(_:)` always validates `config` for you** —
`baseURL` and `auth` are just data, and if your UI lets a user type or import them (a custom
`.openAICompatible` endpoint, an imported settings file), that string is an SSRF-shaped primitive
inside your app's sandbox that decides where a real API key gets sent. `init(_:)` runs
`RemoteProviderConfig.validated()` internally and throws `RemoteProviderConfig.ValidationIssue`
for a non-HTTPS `baseURL` to a non-local host (the key would go over the wire in clear text), a
non-`http(s)` scheme (`file:`, `ftp:`, …), a malformed custom header name, or a CR/LF in a
credential (header injection) — catch it and reject the input rather than registering the
provider anyway. This is a **syntax check, not a trust check**: it doesn't confirm the host is
the one the user meant to talk to, so still warn before sending an existing key to a *changed*
host, and tell users a remote request carries the full prompt, transcript, and tool definitions
to that endpoint. If you're certain a config needs to skip this (e.g. a hardcoded corporate-proxy
profile where `validated()`'s rules are known to be wrong for it), use the non-throwing
`RemoteModelProvider(unchecked:)` escape hatch instead — never for anything user-supplied.

**Settings UI:** `Components`' `AIModelsSettingsView` renders the whole "AI Models" panel
(add provider + key, per-model rows, web-search toggle, Test connection). `Components` does
**not** link `Remote` — it calls back through `onSave` / `onRemove` / `onTest` closures with
plain `RemoteProviderDraft` / `ProviderTestOutcome` values, so a macOS-26 host app can host the
panel and hand the actual `RemoteModelProvider` work to a 27-only helper. → *the full pattern
is [`examples/model-switch`](../examples/model-switch/).*
