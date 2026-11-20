# Using the LocalLM SDK

For a Swift developer adding an AI assistant that can use tools to their own macOS app. This guide covers the
model layer (which model answers and how a conversation runs), tools (system connectors, files, MCP servers),
how to keep tool use safe, and shipping. It has been exercised against real signed apps and live MCP servers,
not just written from the API surface.

Targets macOS 27 on Apple Silicon, with Xcode 27 (Swift 6 tools) to build. Apple's on-device model also runs on macOS 26 (see [Targeting macOS 26 and 27](#targeting-macos-26-and-macos-27-from-one-build)).

**New to the SDK?** Start with [the quickstart](quickstart.md), then read this guide from the top. **Upgrading?**
Read [migrating to 3.0](migrating-to-3.0.md) first.

## How this guide is organized

1. **[Linking the SDK](#linking-the-sdk)** and the macOS 26/27 split.
2. **[The model layer](#the-model-layer-models-routing-and-sessions):** models, routes, sessions and building a chat.
3. **[Tools](#tools-available-not-attached-30):** available tools and the picker, connectors, ready-made tools, files and workspaces.
4. **[Tool safety](#tool-authorization-two-levers--which-tools-and-whether-they-ask-first):** who may run what.
5. **[MCP servers](#mcp-servers)**, with the full story in [the MCP client guide](mcp-guide.md).
6. **[Shipping](#scope-and-boundaries-what-core-doesnt-do)** and **[Components](#components-prebuilt-swiftui-mcp-servers--the-model-layer)**.

Separate guides, so this one stays readable: [open-weight models on the Mac](local-models-mlx.md),
[online providers](remote-providers.md), [decision models](decision-models.md),
[the reference-app walkthrough](walkthrough-plate-today.md) and [the reference](reference.md).

## What is new in 3.0

- **A chat that stays fast with many tools.** Tools are *available*, not *attached*, and a picker chooses the few
  each message needs: [Tools: available, not attached](#tools-available-not-attached-30).
- **A prompt cache for local models**, on by default: [The prompt cache](#the-prompt-cache-30).
- **Loading a model never downloads it.** Your app takes the download step: [Loading never downloads](#loading-never-downloads-30).
- **A gate around every tool call, fail-closed by default**, with trust and review for servers, outside content
  treated as data, a sandbox for programs and an audit stream: [Tool authorization](#tool-authorization-two-levers--which-tools-and-whether-they-ask-first).
- **More of MCP:** resources and prompts in chat, richer tool results, paste-a-setup, per-app sign-in names:
  [MCP servers](#mcp-servers).
- **A chat core and views:** `ChatController`, `ConversationStore` and Components' chat views, so a chat app is mostly
  configuration: [Building a chat app](#building-a-chat-app--hosttranscript-streamresponse-turncontext).

Upgrading from 2.x? [Migrating to 3.0](migrating-to-3.0.md) lists what to change.

## Linking the SDK

> **Reach for this when** you start any SDK project — this is the one
> required step before any other code in this guide will compile.
>
> **Examples that use it:** every example under [`examples/`](../examples/) links `Core` this
> way — [`plate-today`](../examples/plate-today/)'s `Package.swift` is the simplest single-binary
> case to copy from; [`code-buddy`](../examples/code-buddy/) and
> [`model-switch`](../examples/model-switch/) show the multi-binary shapes below.

The simplest way to add the SDK is by URL: the [locallm repo](https://github.com/ancientcomputing/locallm) is a Swift package. In Xcode choose
File → Add Package Dependencies, paste the repo URL, set the rule to **Branch** `3.0.0-GA`, and pick the libraries you use; in a
`Package.swift`, add `.package(url: "https://github.com/ancientcomputing/locallm", branch: "3.0.0-GA")` and
`.product(name: "LocalLMLabSDKCore", package: "locallm")`. [The quickstart](quickstart.md#1-add-the-sdk) has the steps and explains why it is a branch.

To pin the exact files yourself instead: `LocalLMLabSDKCore` ships as a `Core.xcframework` binary, published as a GitHub Release asset on
the repo. Add it to your own `Package.swift` as a `binaryTarget`, pointing at the exact release
you want:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YourApp",
    platforms: [.macOS("26.0")],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: "https://github.com/ancientcomputing/locallm/releases/download/vX.Y.Z/LocalLMLabSDKCore-X.Y.Z.xcframework.zip",
            checksum: "..."  // the .sha256 file alongside the asset on that release
        ),
        .executableTarget(
            name: "YourApp",
            dependencies: ["LocalLMLabSDKCore"],
            // Needed for a Swift package program: without it, it builds but dies at launch with "Library not loaded: @rpath/...".
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        )
    ]
)
```

Get the exact `url` and `checksum` for the version you want from the locallm GitHub repo's
[Releases page](https://github.com/ancientcomputing/locallm/releases) — each release's assets include both the `.xcframework.zip`
and a matching `.sha256` file. `examples/plate-today/Package.swift` is a real, working example of
this same pattern if you want something to copy from directly.

```swift
import LocalLMLabSDKCore
```

If you also want the prebuilt SwiftUI pieces (MCP server picker, OAuth waiting view, resource/
prompt browsing, model picker, AI Models settings panel), add `Components` the same way — see
[`examples/components-demo`](../examples/components-demo) for a working example of using it.

The release carries **four xcframeworks** plus `Components` and `MCPAppsHost` as source, all keyed off the same
`LOCALLM_SDK_VERSION`; link only the ones you use: **`Core`** (always), **`Claude`** (Claude via
Foundation Models — forces a macOS 27 target), **`Inference`** (local open-weight / MLX models),
**`Remote`** (online providers — GPT / Claude online / OpenRouter, see [Online providers](remote-providers.md)), and **`Components`**
(SwiftUI, consumed as source, not an xcframework), and **`MCPAppsHost`** (a server's own interactive
views shown in a chat, also source). `examples/code-buddy` (Core + Inference) and `examples/model-switch`
(Remote + Components) are the multi-binary manifest shapes to copy from.

### Targeting macOS 26 and macOS 27 from one build

> **Reach for this when** you want one shipping binary to run on both macOS 26 and macOS 27,
> with the 27-only model families (PCC, open-weight/MLX, online providers) simply absent on 26.
> Skip this if you're only ever targeting macOS 27.
>
> **Examples that use it:** [`os-matrix`](../examples/os-matrix/) is exactly this pattern, built
> to run unchanged on both OS versions — read it end to end for the live version of the snippet
> below.

`LocalLMLabSDKCore`, `LocalLMLabSDKInference`, and `LocalLMLabSDKComponents`
all have a **macOS 26 deployment floor**, and `LocalLMLabSDKRemote`
has a macOS 26 *manifest* floor too, though `RemoteModelProvider` itself is 27-only (see [Online providers](remote-providers.md)).
One app, one link, runs on both — with the model families that need macOS 27 (Private Cloud
Compute, open-weight / MLX, online providers) simply absent on 26. The
`#available` check is one block, at provider registration; everything after it is identical code.

```swift
import LocalLMLabSDKCore
#if canImport(LocalLMLabSDKInference)
import LocalLMLabSDKInference
#endif

@MainActor
func makeLab() -> LocalLMLab {
    var providers: [any ModelProvider] = [SystemModelProvider()]   // Apple on-device — 26 + 27
    if #available(macOS 27, *) {
        providers.append(PCCModelProvider())                       // Private Cloud Compute
        #if canImport(LocalLMLabSDKInference)
        providers.append(MLXModelProvider())                       // open-weight / MLX
        #endif
    }
    return LocalLMLab(configuration: .init(providers: providers))
}

// identical on 26 and 27:
let lab = makeLab()
lab.models.route("chat", to: .system)
let session = try lab.makeSession(route: "chat", tools: myTools, instructions: "…")
let answer = try await session.respond(to: prompt)
```

- On macOS 26, `lab.models.availability(for: .pcc)` returns
  `.unavailable(kind: .requiresOS("macOS 27"), …)`, and `lab.models.schemesRequiringNewerOS`
  lists the schemes (`pcc`, `claude`, `mlx`) that would work on 27. `Components`'
  `ModelPickerView` renders those as disabled "Requires macOS 27" rows automatically — pass
  `show27OnlyModels: false` to hide them instead.
- Linking `LocalLMLabSDKInference` on macOS 26 is fine; you just can't register
  `MLXModelProvider` there (guard it behind `#available(macOS 27, *)`).
- **Claude is the exception.** `LocalLMLabSDKClaude` (a separate binaryTarget on the same
  release — see [The model layer](#the-model-layer-models-routing-and-sessions)) depends on `ClaudeForFoundationModels`, which is hard-pinned to macOS 27,
  so linking it forces a **macOS 27 deployment target** on whatever links it. To ship a macOS 26
  app *and* offer Claude, put the Claude path in a separate macOS-27-only executable/helper the
  way the LocalLM Lab app does (its background helper is split into a 27 binary and a 26 binary,
  chosen at launch). `Core`'s public API is identical on both sides of that boundary.

## The model layer: models, routing and sessions

> **Reach for this when** "which model" becomes a real question in your app: you want to offer a
> locally-run open-weight model *and* Apple's on-device model *and* Claude behind one API, let
> the user (or your own logic) switch between them, keep one warm between turns, and show
> download/memory state in your UI — without hand-rolling a provider abstraction. If your app
> only ever uses Apple's on-device model, you don't need any of this — construct a
> `LanguageModelSession` directly and pass it Core's tools; the rest of this section is for apps
> that want more than one model.
>
> **Examples that use it:** [`code-buddy`](../examples/code-buddy/) exercises all of it — a CLI
> coding agent with a `.heavy` and a `.light` route to locally-run MLX models, Core's Workspace
> tools, an MCP docs server, and streamed output; run it with a task for one shot, or without one
> for a `>>` loop over one persistent `LocalLMLabSession` (where `contextBudget` and
> `.contextCompacted` earn their place). Each subsection below names which example uses that
> specific piece.

The MCP client ([MCP servers](#mcp-servers), below) is usable on its own with Apple's
`SystemLanguageModel` and nothing else. The model layer builds on a **macOS 26** floor; Private
Cloud Compute and open-weight (MLX) models need macOS 27, and Claude needs a macOS-27 target
(see [Targeting macOS 26 and 27](#targeting-macos-26-and-macos-27-from-one-build)).

### `LocalLMLab` — the front door (optional)

> **Use it when** you want one object that wires the model registry, the MCP manager, and the
> connector/workspace facades together, and hands you a ready session. It's entirely optional —
> every bare type (`MCPServerManager`, `Connectors`, `WorkspaceAccess`, the providers) stays
> public and usable without it.
>
> **Examples that use it:** [`code-buddy`](../examples/code-buddy/) builds `LocalLMLab` with two
> providers and maps `.heavy`/`.light` before the first turn.

```swift
let lab = LocalLMLab(configuration: .init(providers: [
    SystemModelProvider(),
    ClaudeModelProvider(auth: .apiKey(myKeyFromKeychain)),   // from LocalLMLabSDKClaude (macOS 27 target)
    MLXModelProvider(),                                      // from LocalLMLabSDKInference — see below
]))
// To also run on macOS 26, register only SystemModelProvider() unconditionally and the
// rest inside `if #available(macOS 27, *)` — see Targeting macOS 26 and 27, below.

lab.models      // the @Observable ModelRegistry — providers, routes, residency, downloads
lab.mcp         // the app's one MCPServerManager — set up via Configuration(…, mcp: MCPSettings(…)); see the MCP guide's revisions section
lab.workspace   // security-scoped workspace access + ready-made tools
lab.connectors  // Calendar / Reminders / Contacts / Location
```

An app that uses `LocalLMLab` uses `lab.mcp` and never makes an `MCPServerManager` of its own:
`makeSession` takes MCP tools from `lab.mcp`, and a second manager would be invisible to it.
Configure it with `MCPSettings` (handlers, response limits, version negotiation, live updates —
the same settings `MCPServerManager`'s initializer takes, same defaults); making an
`MCPServerManager` directly is for apps that don't use `LocalLMLab`.

`lab.snapshot() -> LocalLMLabState` gives you a `Codable` snapshot of the route map + residency
policy + installed-model records to persist wherever you like (the SDK writes nothing to disk);
`lab.restore(from:)` re-applies one. Use it when you want the user's model choices to survive a
relaunch.

### `ModelProvider` and the built-in providers

> **Use a provider when** you're deciding *what models your app can offer at all.* A provider is
> "a source of language models" — you register the ones you want, and the registry resolves a
> `ModelID` to whichever provider owns its `scheme`. Online models aren't a separate mechanism —
> `RemoteModelProvider` is a `ModelProvider` like any other; it just gets its `scheme` from data
> you supply instead of owning one fixed name (below, and [Online providers](remote-providers.md)).
>
> **Examples that use it:** [`os-matrix`](../examples/os-matrix/) registers `System`, `PCC`, and
> `MLX` behind one `#available(macOS 27, *)` check (the pattern for supporting both OS floors);
> [`code-buddy`](../examples/code-buddy/) registers `MLXModelProvider` + `SystemModelProvider` as
> a fallback; [`model-switch`](../examples/model-switch/) starts with just
> `SystemModelProvider` and registers a `RemoteModelProvider` per configured service at runtime
> via `lab.models.replace(_:)`, as the user adds each one in Settings.

| Provider | Ships in | `scheme` | macOS | For |
|---|---|---|---|---|
| `SystemModelProvider` | Core | `system` | 26+ | Apple's on-device model — always there on an Apple-Intelligence Mac |
| `PCCModelProvider` | Core | `pcc` | 27 | Apple's Private Cloud Compute model (Apple's own models, not your weights). Needs an Apple entitlement; see the note below the table |
| `ClaudeModelProvider(auth:)` | **`LocalLMLabSDKClaude`** | `claude` | 27 | Claude, via a host-supplied API key or App Attest client id — the SDK stores neither |
| `MLXModelProvider` | **Inference** | `mlx` | 27 | Locally-run open-weight models (Qwen, Llama, …) via MLX |
| `try RemoteModelProvider(_:)` | **Remote** | *host-chosen* — set in `RemoteProviderConfig.scheme`, one instance per provider you configure | 27 | Hosted APIs — OpenAI, Anthropic's Messages API, OpenRouter, any OpenAI-compatible server. The one provider here that's data-driven rather than a fixed named type; details in [Online providers](remote-providers.md) |

**About `PCCModelProvider`.** It needs Apple's managed PCC entitlement, which works only in your app's main executable, signed with a provisioning profile that grants it ([Shipping the model layer](#shipping-the-model-layer-through-app-store-connect)). There is no paid tier. The provider maps availability, quota and typed errors, and adds `probe(timeout:)`, an async liveness check (`availability(for:)` can say `.available` while turns still fail). Neither tells you whether you have the entitlement: without it, FoundationModels traps on the first PCC call, so check your own entitlement first.

`LocalLMLabSDKClaude` is a third binaryTarget on the SDK release (`ClaudeForFoundationModels` is
macOS-27-pinned, so it can't live in the macOS-26-floored Core); `LocalLMLabSDKRemote` is a
fourth, with no such pin — its manifest floor stays macOS 26, so linking it never forces a 27
deployment target, even though `RemoteModelProvider` itself only registers successfully on 27.

Within a single macOS-26-floor target, register every 27-only provider you're able to link there —
`PCC`, `MLX`, `Remote` alike — inside `if #available(macOS 27, *)`
([Targeting macOS 26 and 27](#targeting-macos-26-and-macos-27-from-one-build)). **Claude can't join that group at
all**: linking `LocalLMLabSDKClaude` forces a macOS 27 *deployment target* on whatever target links
it, so it can't even be conditionally imported into a macOS-26-floor target the way `Inference` and
`Remote` can — an `#available` runtime check doesn't help, because the problem is at link/build
time, not run time. Registering `ClaudeModelProvider` at all means doing it in a separate,
macOS-27-only target ([Targeting macOS 26 and 27](#targeting-macos-26-and-macos-27-from-one-build) and
[`os-matrix`'s README, "Adding Claude"](../examples/os-matrix/#adding-claude)).

On macOS 26, `lab.models.availability(for:)` reports `pcc`, `claude`, and `mlx` as
`.unavailable(kind: .requiresOS("macOS 27"), …)` and `lab.models.schemesRequiringNewerOS` lists
them — this is true for `claude` even in an app that, like `os-matrix`, never links
`LocalLMLabSDKClaude` at all (see the `ModelAvailability` section below for what that scheme
reports once the OS floor is actually met but no provider was ever registered for it).

`ModelProvider` is a protocol — **implement it yourself when** you have a model source the SDK
doesn't ship (a remote inference endpoint, a different local runtime). Its one core requirement
is `makeSession(for:tools:instructions:transcript:) -> LanguageModelSession` — the provider
builds the Apple session for its model (this is what lets the model layer run on macOS 26,
where Apple's `LanguageModel` protocol doesn't exist). The registry only ever talks to the
protocol.

### `RouteName` + routing — pick a model without hardcoding one

> **Use routes when** you don't want `"mlx:mlx-community/Qwen3-8B-4bit"` sprinkled through your
> code. A `RouteName` (`.heavy`, `.light`, `.local`, or any string you like) is a name your app
> maps to a `ModelID`; you pick a route per session. **The SDK owns model residency, never
> routing policy** — your app decides which route a given task uses.
>
> **Examples that use it:** [`code-buddy`](../examples/code-buddy/)'s `--route heavy|light` flag
> flips exactly this; `--heavy`/`--light` override the model each route points at.

```swift
lab.models.route(.heavy, to: ModelID("mlx:mlx-community/Qwen3-8B-4bit")!)
lab.models.route(.light, to: .system)
// later, per task:
let session = try lab.makeSession(route: heavyTask ? .heavy : .light, tools: myTools, instructions: sys)
```

### `makeSession` + `LocalLMLabSession` — a session with your tools + MCP tools merged

> **Use it instead of constructing `LanguageModelSession` yourself when** you want the SDK to
> resolve the route → model, build the model, and assemble the tool list (your `tools` **plus**
> the enabled MCP session tools from `lab.mcp`, unless `includeMCPTools: false`).
>
> **Examples that use it:** [`code-buddy`](../examples/code-buddy/)'s whole
> `makeSession(route:tools:instructions:)` call, tools = Workspace tools + its host-owned
> `GitTool`/`RunTestsTool`.

```swift
let session = try lab.makeSession(
    route: .heavy,
    tools: [SearchWorkspaceTool(), ApplyPatchTool(), myGitTool],
    instructions: "You are a coding assistant.",
)
// Run a turn — nothing here runs an agent loop:
let answer = try await session.respond(to: task)
// or stream it (each element is the reply so far):
for try await partial in session.streamResponse(to: task) { … }
```

`session.route` / `session.modelID` tell you what actually backs it. `makeSession` is one
function, `makeSession(route:tools:instructions:restoring:includeMCPTools:includePlugins:dynamicTools:mcpAppHints:options:authorizer:)`
(`includePlugins:` and `dynamicTools:` are new in 3.0: see [Tools: available, not attached](#tools-available-not-attached-30)):

- **MCP tools follow `lab.mcp`.** With `includeMCPTools` (the default) the session offers the
  enabled MCP tools and keeps following `lab.mcp`: turn a tool on or off, add a server, or change
  a server's trust, and the model has it on its next `respond` / `streamResponse` — same session.
  (A turn run on `languageModelSession` directly doesn't pick changes up — [Running a turn](#running-a-turn-and-when-to-use-languagemodelsession).)
  For a fixed, per-session set of MCP tools, pass them in `tools:` with `includeMCPTools: false`.
- **`restoring:`** continues a saved conversation (see [Building a chat app](#building-a-chat-app--hosttranscript-streamresponse-turncontext));
  leave `instructions` nil then — the saved transcript carries its own (passing both traps).
- **`mcpAppHints: true`** adds one line to the description of each MCP tool that has an MCP App
  view, so a model can prefer it when the user asks to *see* something ([MCP Apps](mcp-guide.md#mcp-apps-showing-a-servers-interactive-views)).

**Run every turn with `respond` / `streamResponse`.** They are what make the rest of this
section work — the MCP tool refresh above, the sampling options below, `turnContext`, the chat
history, the overflow retry. `languageModelSession` is Apple's session underneath, and a turn run
on it directly skips all of that; what it costs, and when it's still the right call (guided
generation, reading the raw transcript), is in [Running a turn](#running-a-turn-and-when-to-use-languagemodelsession).

**`options: SessionOptions`** carries per-call knobs — provider-native web search, sampling
(`temperature` / `topP` / `topK` / `seed` / `maxOutputTokens`), and `effort`. `effort: .off` asks the model **not
to think**: on the MLX tier it flips the chat template's thinking toggle for models that have
one (the Qwen3 family). It's a *preference*, not a requirement — **`.off` never throws**: a
model whose reasoning can't be suppressed (e.g. DeepSeek-R1, which always reasons) just keeps
reasoning instead of failing the turn, same as a model with no thinking toggle at all, which is
a no-op either way. If you need to know ahead of time whether `.off` will actually take effect
(to gray out a "hide thinking" toggle in your own UI, say), check
`ModelCapabilities.reasoningToggle` from `capabilityProbe(_:)` rather than trying `.off` and
inspecting the result — there's no error to inspect, by design. On the remote providers `.off`
maps to the provider default — there is no true "reasoning off" on those APIs, so pass `.low` to
minimise it. `aiql` uses `.off` ([File-backed tools](#filebackedtool--the-aiql-data-verbs-a-mechanical-mcp-dataset--csv-pipeline)). `.low`…`.max` don't reach MLX.

**Sampling on Apple's on-device model (`system`).** The SDK maps `temperature`, `maxOutputTokens`,
`topK` / `topP` and `seed` onto Apple's `GenerationOptions` and applies them on every
`session.respond(...)`. A few rules come from how Apple's API is shaped, and the SDK reports a
combination it can't honour with a `SessionOptionsError` — thrown from `makeSession`, not
discovered on the first turn — instead of quietly dropping a knob:

- **`temperature: 0` means greedy decoding.** `topK`, `topP` and `seed` are then irrelevant (not
  an error), as on MLX.
- **`topK` or `topP`, not both.** Apple's sampler takes one or the other; setting both throws
  `.topKAndTopPBothSet`. MLX still accepts both.
- **A `seed` needs `topK` or `topP`** (unless `temperature` is 0), because Apple only takes a seed
  inside a random sampling mode; otherwise `.seedRequiresTopKOrTopP`.
- **Values are range-checked** (`temperature` ≥ 0, `topK` ≥ 1, `topP` in (0, 1], `maxOutputTokens`
  ≥ 1) → `.invalidValue`.
- `minP`, the repetition knobs and `prefillStepSize` don't exist on Apple's model and are ignored,
  like `effort` and web search. Private Cloud Compute ignores all of these.

You can override per turn with `session.respond(to: task, options: SessionOptions(temperature: 0))`.
Per-call values win field by field, and setting `topK` or `topP` on the call replaces the
session's choice of either. `respond(to:options:)` is for the on-device model only — every other
provider fixes its options at `makeSession`, so passing non-default options to one throws
`.perCallOptionsUnsupported` rather than being silently ignored.

**A seed is best-effort on Apple's model, not a guarantee.** In testing, the same seed (and greedy
decoding) gave the same text on every call within a running process, but the first request after a
process launch occasionally differed, and the model itself can change with an OS update. Treat "same
seed → usually the same text" as the contract; don't build tests or caching on exact matches.
(On MLX, where the weights are pinned, a seed is a stronger tool for replay and golden-output tests.)

These options are applied by `respond` / `streamResponse`. A turn run on
`session.languageModelSession` directly does **not** get them — pass
`try options.appleGenerationOptions()` yourself ([Running a turn](#running-a-turn-and-when-to-use-languagemodelsession)).

### Running a turn, and when to use `languageModelSession`

> **Use `respond` / `streamResponse` for every turn.** Reach for `languageModelSession` only for
> what the SDK has no method for — guided generation, or reading the raw transcript.
>
> **Examples that use it:** every example built on `LocalLMLab` runs its turns this way;
> [`vistanova`](../examples/vistanova/) also shows the one escape-hatch case, guided generation.
> (The small examples that don't use `LocalLMLab` — `repo-qa`, `plate-today`, `workspace-buddy` —
> make Apple's `LanguageModelSession` themselves; with no SDK session there is nothing to skip.)

```swift
let answer = try await session.respond(to: prompt)                  // the whole reply, a String
for try await soFar in session.streamResponse(to: prompt) {         // the reply so far, a String
    show(soFar)
}
```

`session.languageModelSession` is Apple's `LanguageModelSession` underneath, and you can call
`respond` / `streamResponse` on it directly. The tools still run through the SDK — so tool
approval, tool-call records and tool events work either way — but everything the SDK does *around*
a turn doesn't happen:

| | `session.respond` / `streamResponse` | `session.languageModelSession.respond` / `.streamResponse` |
|---|---|---|
| Tool approval (`authorizer:`), tool-call records in `hostTranscript`, `.toolCallStarted` / `.toolCallFinished` | yes | yes — these live in the tools themselves |
| The user's message in `hostTranscript` as the turn starts; reply and reasoning when it ends; `replyInProgress` while streaming | yes | no message at turn start, no `replyInProgress`; text only after you call `reconcileServerToolArtifacts()` |
| `turnContext` (e.g. the date) and context an MCP App view shared, sent with the prompt | yes | no — the model never sees them |
| MCP tools turned on, or servers added, since the last turn | offered | not offered — the model session keeps the tools it had |
| `retryOnContextOverflow` | applied (`.contextCompacted`) | no — the overflow error reaches you |
| `SessionOptions` sampling on Apple's on-device model | applied | no — pass `try options.appleGenerationOptions()` yourself |
| `session.citations`, `.serverToolCall` (provider web search) | updated | only after `reconcileServerToolArtifacts()` |
| `session.cancel()` | stops the turn | doesn't — cancel your own `Task` |

**When the escape hatch is the right call:**

- **Guided generation** — `respond(to:generating:)` with a `@Generable` result type. The SDK has no
  turn method for it, so call it on `languageModelSession`, then `session.reconcileServerToolArtifacts()`
  so `hostTranscript` and `citations` catch up. For a downloaded model, check
  `ModelCapabilities.guidedGeneration` (`capabilityProbe`) first. [`vistanova`](../examples/vistanova/)'s
  structured search does exactly this, and uses `respond` for its plain-text fallback.
- **Reading the raw transcript** — `languageModelSession.transcript`, to save the model's memory
  ([Building a chat app](#building-a-chat-app--hosttranscript-streamresponse-turncontext)) or to see
  what it was given. Reading is fine; it's *running a turn* there that skips the SDK.
- **Any other Apple session API** the SDK doesn't wrap.

**Coming from Apple's methods:** `respond` returns the reply as a `String` (Apple: a `Response`, read
`.content`); `streamResponse` yields `String`s, the reply so far — *usually* append-only, not across a
tool call or when a reasoning model's `<think>` block gives way to the answer (Apple: snapshots,
`.content`). Failures arrive as `LocalLMLabError.generation(underlying:)`, cancellation as
`CancellationError`; `GenerationErrorDescription.describe(_:)` reads either. Per-call options are
`respond(to:options:)` — on-device model only, as above.

### Building a chat app — `hostTranscript`, `streamResponse`, `turnContext`

> **Use it when** you're drawing a conversation: user bubbles, tool-call rows, the streaming
> reply, the model's reasoning — and want it to survive a relaunch.
>
> **Examples that use it:** [`mcp-chat`](../examples/mcp-chat/) — the whole chat UI is
> `session.hostTranscript` plus `streamResponse`.

Apple's transcript is the model's context: it can be compacted, and it keeps only what the model
saw of a tool result. `session.hostTranscript` is the conversation as your UI shows it —
append-only, in the order the model worked, and `@Observable`, so a SwiftUI view that reads it
redraws as it changes:

```swift
session.turnContext = { "[Current date and time: \(Date().formatted())]" }  // sent with every turn,
                                                                         // not shown in the transcript
for try await _ in session.streamResponse(to: text) {}   // the view reads hostTranscript

ForEach(session.hostTranscript.entries) { entry in
    switch entry.content {
    case .user(let text):            UserBubble(text)               // appears as the turn starts
    case .assistant(let text):       Reply(text)                    // the answer only
    case .reasoning(let text):       ReasoningDisclosure(text)      // incl. Qwen3's <think> block, split out
    case .toolCall(let record):      ToolCallRow(record)            // live: .running → .finished
    case .appContext(_, let text):   ViewSharedContext(text)        // an MCP App view told the model this
    @unknown default:                EmptyView()
    }
}
if let reply = session.hostTranscript.replyInProgress { StreamingReply(reply) }  // .reasoning / .text / .isReasoning
```

- **When it updates.** The user's message is added as the turn starts; each tool call appears
  when it starts and changes in place as it finishes; the reply and reasoning land when the turn
  ends (`replyInProgress` until then — cleared in the same update, so a view never shows both).
  A turn run on `languageModelSession` directly gets text only after
  `reconcileServerToolArtifacts()` ([Running a turn](#running-a-turn-and-when-to-use-languagemodelsession)).
- **Tool calls are full records** (`ToolCallRecord`): state, arguments, the output the model saw,
  the full `MCPToolResult` (`mcpResult` — kept under a memory budget, spilled to disk past it),
  the tool's MCP App link (`app`), who made the call (`initiator`: the model, an MCP App view, or
  your app), and timestamps.
- **A model has no clock.** `turnContext` is called as each `respond` / `streamResponse` turn starts and its text goes ahead of
  the user's message — current even in a restored conversation, whose instructions were written
  long ago. (The ready-made `ClockTool` lets the model ask too, but a small model may not.)
- **In a static session, tools of a newly added MCP server start off** (a session with `dynamicTools:` makes them all available). Show the user that, or the model gets no tools
  — and may claim to have used one anyway.

**Less to write in 3.0.** `ChatController` runs a whole chat for you: turns, attachments, tool choice, permission and
sign-in cards, saved conversations (`ConversationStore`), and a summary the model writes when the chat fills up
(`ChatCompaction`). Components' `MarkdownView`, composer and card views draw it, so a chat app is mostly configuration
(`ChatConfiguration`, `ChatSetup`, `ChatPlugins`). Start from `examples/mcp-chat` to see the pieces by hand, and use
the controller when you want them assembled. `hostTranscript` stays the source for what is on screen.

**Reopening a conversation.** Save both halves and restore both:

```swift
let shown  = try session.hostTranscript.archive()                         // what the user saw
let memory = try JSONEncoder().encode(session.languageModelSession.transcript)   // the model's memory
// next launch:
let saved   = try JSONDecoder().decode(Transcript.self, from: memory)
let session = try lab.makeSession(route: .chat, restoring: saved)
try session.hostTranscript.restore(from: shown)
```

Restore only `shown` to show an old conversation while the model starts fresh. The restored
transcript's entries are history: never added to `hostTranscript` again.

### `LocalLMLabSession.events` — the side-channel Apple's streaming doesn't give you

> **Use it when** your UI needs to show what's happening *around* generation — a spinner per
> tool call, a "compacting context…" notice. Token streaming stays on
> `session.streamResponse`; `events` carries only the rest. (A chat UI can also read tool calls
> live from `hostTranscript` — next section.)
>
> **Examples that use it:** [`code-buddy`](../examples/code-buddy/)'s `→ tool` / `✓ tool` stderr
> trace is this stream.

```swift
for await event in session.events {
    switch event {
    case .toolCallStarted(let id, let name, let arguments):
        showRunning(name, arguments)   // what the model actually sent — can differ from the user's own wording
    case .toolCallFinished(let id, let name, let failed, let resultSummary):
        clearRunning(name, failed: failed, resultSummary: resultSummary)
    case .contextCompacted(let removed):       toast("Trimmed \(removed) old messages")
    case .modelLoadProgress(let fraction):     updateBar(fraction)   // with a local model
    case .routeSwitched(let modelID):          statusLine = "Now on \(modelID)"
    case .serverToolCall(let activity):        showActivity(activity)   // provider-run web search — see Online providers
    @unknown default: break
    }
}
```

All six cases, in one place: `.toolCallStarted`/`.toolCallFinished` (client tool calls — carrying
the tool's real `arguments` and a best-effort `resultSummary`/error text, not just id/name/failed,
so you can show what the model actually sent a tool without hand-rolling your own wrapper around
it), `.contextCompacted` (the retry-and-trim above), `.modelLoadProgress` (a local model's first
load), `.routeSwitched` (the route this session was on just repointed to a different model —
rare, but real if your app calls `lab.models.route(_:to:)` mid-session), and
`.serverToolCall` (a provider running web search/fetch on its own infrastructure — [Online providers](remote-providers.md)).
`.toolCallStarted` / `.toolCallFinished` arrive however you run the turn; `.contextCompacted` only
from `respond` / `streamResponse` (it's their retry), and `.serverToolCall` once
`reconcileServerToolArtifacts()` has run — which they do for you ([Running a turn](#running-a-turn-and-when-to-use-languagemodelsession)).

### `ContextBudget` + `RetryPolicy` — surviving a long session

> **Use these when** your app has long-running sessions (a coding agent, a chat that goes for
> hours) that will eventually fill the model's context window.
>
> **Examples that use it:** [`code-buddy`](../examples/code-buddy/) prints `contextBudget` after
> each run.

- `session.contextBudget` — `windowTokens`, `lastInputTokens`, `fractionUsed` (best-effort).
  Show a "context 78% full" gauge; decide when to start a fresh session. It reflects the latest
  turn's last model call — the conversation as the model last read it — recorded by `respond` /
  `streamResponse` (a turn run on `languageModelSession` directly isn't seen). Not
  `languageModelSession.usage`, which sums every call in the session. `windowTokens` is a per-model
  estimate, `nil` for downloaded models; for those, take the window from the model's
  `config.json` (`InstalledModel.contextTokens`).
- `session.retryOnContextOverflow = RetryPolicy(maxRetries: 2, compact: { transcript in
  myTrim(transcript) })` — when a turn throws `contextSizeExceeded`, the SDK calls your
  `compact` hook, rebuilds the session with the smaller transcript, emits `.contextCompacted`,
  and retries. A local model's up-front refusal of a too-long prompt (`LocalLMLabError.context`,
  [above](local-models-mlx.md#measuring-and-guarding-a-local-models-turn--usage-speed-memory-limits)) is retried the
  same way. Applies to turns run with `respond` / `streamResponse`; a turn run on
  `languageModelSession` directly isn't retried ([Running a turn](#running-a-turn-and-when-to-use-languagemodelsession)). With no `compact` hook it
  just rethrows.

### `ModelAvailability` — gray out a model and say why

> **Use it when** you're building a model picker and need to disable an entry with a reason.
>
> **Examples that use it:** [`os-matrix`](../examples/os-matrix/)'s `describe(_:)` switches over
> every `ModelAvailability` case to print a status line per model family.

`lab.models.availability(for: id)` (or `provider.availability(for:)`) returns:
`.available` · `.notDownloaded` (offer a download button) · `.needsCredential` (prompt for the
API key) · `.unavailable(kind:detail:)` where `kind` is machine-readable
(`.ineligibleHardware`, `.notEnabled`, `.modelNotReady`, `.unsupportedModel`, `.providerError`,
`.noProvider`, `.requiresOS(String)`) so you can branch without parsing `detail`.
`.requiresOS("macOS 27")` is what `pcc` / `claude` / `mlx` return on macOS 26. Components'
`ModelPickerView` binds to this directly (disabled "Requires macOS 27" rows).

**This works even for a scheme whose provider your app never links or registers at all.**
`availability(for:)` recognizes `pcc`, `claude`, and `mlx` as known scheme names and reports their
OS requirement from that name alone — it does not require a matching `ModelProvider` to be
registered (or even linked) first. `os-matrix` shows this concretely: its `Package.swift` never
links `LocalLMLabSDKClaude`, and its code never constructs a `ClaudeModelProvider`, yet its
availability table still queries `claude:sonnet5` and correctly prints `requires macOS 27` for it
when run on macOS 26 — see the "Why the `claude:sonnet5` row appears" note in
[`os-matrix`'s README](../examples/os-matrix/#on-macos-26).

**Once the OS gate is satisfied, the `.requiresOS` reason goes away — and a different one can take
its place.** Run that same never-registered `claude:sonnet5` query on macOS 27 (confirmed live) and
it no longer reports `.requiresOS`; it reports `.unavailable(kind: .noProvider, detail: "No model
provider registered for scheme 'claude'")` instead — a `ModelAvailability.Kind` case, not a
`.requiresOS`. `.requiresOS` only ever means "this scheme's OS floor isn't met **yet**"; it says
nothing about whether a provider for that scheme is actually registered once the floor is met. See
the "On macOS 27" section of [`os-matrix`'s README](../examples/os-matrix/#on-macos-27) for the
side-by-side output.

### Loading never downloads (3.0)

Downloading is its own step, taken by your app. A session, `capabilityProbe`, `prewarm`, the prompt-cache self-test, a
paired speed helper or a paired adapter on a repo that isn't downloaded fails with
`LocalLMLabError.modelUnavailable(reason:)` naming the model. A model already on disk loads offline.

```swift
if case .notDownloaded = lab.models.availability(for: id) {
    let check = try await mlx.validate(repoID)           // fast pre-flight, no weights pulled
    guard check.passed else { return }                   // check.weightBytes: show the size, ask the user
    for try await event in mlx.download(repoID) {        // or: try await lab.models.startDownload(repoID)
        if case .progress(_, _, let fraction) = event { updateBar(fraction) }
    }
}
let session = try lab.makeSession(route: .chat)          // now it loads from disk only
```

Because loading no longer touches the network, the trust policy applies at download, an unpinned model stays at the
version you downloaded until you download again, and a damaged download is not repaired on load (remove it and
download again). [Migrating to 3.0](migrating-to-3.0.md#4-loading-never-downloads) has the details.

### The prompt cache (3.0)

A model has no memory between requests. To answer a follow-up, a chat sends the whole conversation again and the
model reads all of it before it writes a word. For a model running on the Mac that reading is the wait before the
first word, and it grows with every turn and every tool call. The prompt cache saves what the model already read, so
a follow-up reads only what is new. A 12-step tool loop over a 14,000-token document went from about 4½ minutes to
under a minute on a 64 GB Mac Studio (Qwen3.8-27B); switching back to an earlier conversation took about 2 seconds
instead of 15.

- **On by default** for local (MLX) models, memory only, within a budget sized to the Mac (about 14 GB on a 64 GB
  Mac, about 3 GB on a 24 GB one). Verified families (Qwen3.5/3.8, Qwen3, Qwen3 MoE, Llama, Nemotron 3.5) are on
  straight away. Any other model gets a one-time self-test (1 to 4 seconds, once per model version per Mac), and a
  model whose memory can't be saved and rewound is reported as not supported and runs normally.
- **It doesn't change answer quality.** A restore is bit-identical to a fresh read. Against a cache-off run, wording
  can differ slightly by rounding.
- **It keeps memory in check.** It caps the memory MLX keeps for reuse, reads an oversized prompt in smaller pieces
  before refusing it, and gives back its own memory before it would cause a refusal.
- **Smaller entries, if you want them.** `storage: .compact(bits: 8)` (or `4`) stores the saved state quantized, so
  more fits in the budget; answers can then differ slightly. The default, `.exact`, keeps it as read.
- **It fails safe.** A damaged, missing or half-written cache file means no reuse this time, never a wrong answer.

```swift
let provider = MLXModelProvider()                          // on, memory only
let off = MLXModelProvider(promptCache: .off)              // off for the provider
let options = SessionOptions(bypassPromptCache: true)      // skip it for one session (a benchmark, say)
let persistent = MLXModelProvider(promptCache: .tiered())  // opt in: also keep it on disk across relaunches
let status = provider.promptCacheStatus(for: modelID)      // a state and a plain sentence to show your users
```

The disk tier is encrypted (the key is in the Keychain), excluded from backups and wiped by `clear()` on its
`MLXPromptCacheDisk` (or `MLXModelProvider.clearPromptCache()`); the disk's `storedBytes` says how much it holds. It holds a model's working state from your users' conversations, so offer a way
to clear it. `MLXPromptCacheStats` and `MLXMemoryPressure` report what the cache did.

**In a chat app.** A turn gets slower, though never different, when the app uses a speed-helper model (it turns the
cache off), changes the tool set, trims old messages, sends images, or the previous answer was very long. Short
one-off requests also take memory now (about 330 MB each on Qwen3.8) and can evict a long chat sooner.
[The prompt cache page](https://thisbrain.ai/locallm/prompt-cache.html) has the measurements.

### Stopping a reply (3.0)

A reply ends only once its generation has stopped. Before quitting while a reply is streaming, call
`await MLXModelProvider.stopGenerating()`, or the process can exit while the GPU is still working.

## Tools: available, not attached (3.0)

Every tool a model can use costs context: its name, description and parameters go into the prompt on every message.
Apple's on-device model has about 4,000 tokens in all, and one GitHub MCP server's tool definitions took about 7,000
tokens of every call. In 2.x the fix was manual: switch on one or two tools for what you were about to ask.

In 3.0 the tools your app has are *available*, and a *picker* chooses the few each message needs. Only those enter
the prompt. A chat can have hundreds of tools and send a local model three. A service is connected only when one of
its tools is used, and disconnects when idle.

A session needs a picker to do this; there is no default. Three come ready-made, and you can write your own
(`ToolSelector`):

| Picker | How it chooses | Cost |
|---|---|---|
| `SystemToolMatcher` | Apple's on-device model lists which sources and tools fit the message | Two small generations a turn; nothing to download. About 1.6 s at the median in ChatAgain (see [Choosing tools per turn](https://thisbrain.ai/locallm/tool-picker.html#chatagain)) |
| `DecisionToolMatcher` | A decision model, through `lab.decide` (for example OpenJev on Qwen3-4B). A hosted decider works, but then the message and your tool descriptions go to that provider | About half a second a turn with a small local decider, in our turns evaluation |
| `KeywordToolMatcher` | No model: words in the message against server names, keywords and tool names | Fast and predictable; misses paraphrases |

```swift
let session = try lab.makeSession(route: .chat, dynamicTools: .matching(SystemToolMatcher()),
                                  authorizer: authorizer)
```

Without `dynamicTools:` a session is static, as in 2.x: it offers the tools you pass and the MCP tools that are switched on.

- **Plug-ins** are bundles of built-in tools you add to the catalog with `lab.tools.add(_:enabled:)`: Clock, Weather,
  Calendar, Reminders, Contacts, Location, Documents, Tables, Images, Web and Files over workspaces (folders the
  user chooses, with access levels). MCP servers, commands and workspaces are sources too. A plug-in's system
  permission is asked only when a tool of it is called.
- **Rules the picker follows:** a stricter bar for adding tools mid-conversation; a server must be named before it is
  added; guessed tools that go unused are dropped after six turns; a tool called earlier and no longer offered
  answers that it is gone; a tool that fails three times is stopped for the turn. `ToolSelectionExplanation` says what
  was chosen and why, and `suggested` names a held-back server worth offering after the reply.
- **The model is told what is missing** (`DynamicTools.missingToolGuidance`, `heldBackNote`), so it says so instead of
  guessing. With `requestsTools` on (the default in `ChatSetup`), each turn also offers `requestTools`; and a reply that
  says a tool is missing, when the model didn't call it, makes the session ask for that tool and run the turn again
  with what it finds (once a turn).
- **A server named in the user's custom instructions is offered on every message.** The picker reads only the
  message, so "Use exa to search the web" in a chat's custom instructions would otherwise be forgotten on a message
  that doesn't mention it. Set `LocalLMLabSession.standingInstructions` (or `ChatSetup.standingInstructions`) to a
  closure that returns those instructions: a server they name is offered whatever the message says, whole if it has at
  most `ToolMatchingOptions.wholeNamedServerLimit` (12) tools, otherwise as if the message had named it. The
  explanation's reason is `.namedInInstructions`; `offersServersNamedInInstructions = false` turns it off.
- **A tool reaches the model as `<prefix>_<tool>`** (`github_list_issues`), so two servers never clash.
  `MCPServerManager.snapshot()` and `restore(from:)` keep the cached tools, trust, approvals and the accepted list across a relaunch.
- In the Tool Sources sheet and `MCPServerPickerView`, `toolsMode: .dynamic` shows servers as available; the tool
  checkboxes mean "available" and all are on by default.

The measurements: over twenty turns on Qwen3-8B the tool description sent each turn was about nine times smaller (394
tokens against 3,386) and the first turn took 2.2 seconds against 4.8. With only a few tools, sending them all stays in
the prompt cache, so time to first token is not lower. The gain is the context you keep for the conversation and
documents, and tools that scale without a checklist. See [MCP in your app](https://thisbrain.ai/locallm/mcp-sdk.html#context).

## Setup for Calendar and Reminders

> **Reach for this when** your app will touch Calendar or Reminders. Skip this whole section if
> you're not using either connector — Contacts and Location have their own, separate setup (see
> [Connectors](#connectors-calendar-reminders-contacts-location)), and MCP OAuth's setup moved to
> [Connecting to an MCP server](mcp-guide.md#connecting-to-an-mcp-server-three-auth-options-and-how-to-pick-between-them), where it
> belongs alongside the rest of MCP auth.
>
> **Examples that use it:** [`plate-today`](../examples/plate-today/) and
> [`plate-today-tools`](../examples/plate-today-tools/) need both subsections below (Calendar +
> Reminders).

Two things are **required**, not optional extras — skipping either one produces a confusing
failure (a silent TCC denial, or a crash on a missing entitlement) rather than a clear error.

### Info.plist usage-description strings (if using Calendar/Reminders)

> **Reach for this when** you're about to request Calendar or Reminders access for the first
> time — add these before your first `CalendarAccess`/`RemindersAccess` call, not after a
> TCC denial.
>
> **Examples that use it:** [`plate-today`](../examples/plate-today/) /
> [`plate-today-tools`](../examples/plate-today-tools/).

For every connector you use (Calendar/Reminders shown here — see [Connectors](#connectors-calendar-reminders-contacts-location) for the full connector
list and its Info.plist/entitlement requirements):

```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Your own explanation of why your app needs this.</string>
<key>NSRemindersFullAccessUsageDescription</key>
<string>Your own explanation of why your app needs this.</string>
```

### Entitlements (if using Calendar/Reminders)

> **Reach for this when** you're preparing your app's entitlements file for the first
> Calendar/Reminders build — required alongside the [Info.plist strings](#infoplist-usage-description-strings-if-using-calendarreminders), not instead of them.
>
> **Examples that use it:** [`plate-today`](../examples/plate-today/) /
> [`plate-today-tools`](../examples/plate-today-tools/).

```xml
<key>com.apple.security.personal-information.calendars</key>
<true/>
```

There is no separate "reminders" sandbox entitlement — Reminders access (EventKit) is covered by
this same `calendars` entitlement; only the Info.plist `NSRemindersFullAccessUsageDescription` key
and the TCC prompt itself are Reminders-specific. A
`com.apple.security.personal-information.reminders` key isn't a real Apple entitlement — local
`codesign`/`pkgutil --check-signature` don't catch this, but a real App Store Connect
validation (Transporter upload) rejects it outright with "Invalid Code Signing Entitlements."
Confirmed live, 2026-08-14.

**The Info.plist strings and the entitlement are required together, on your final signed bundle, or TCC fails in confusing
ways.** The specific failure sequence (confirmed live, more than once):
1. Entitlement missing → "Policy disallows prompt" (no dialog appears at all).
2. Entitlement present, Info.plist key missing → "Refusing authorization request ... without
   NSCalendarsUsageDescription key".
3. Both present, but your **final** `codesign` call on the outer `.app` bundle omitted
   `--entitlements` → entitlements applied to the inner binary are silently stripped, because
   signing the outer bundle re-signs its own main executable regardless of any earlier per-binary
   sign. Sign the binary, then sign the whole bundle **with `--entitlements` again** — that second
   pass is the one that actually matters.

## Connectors: Calendar, Reminders, Contacts, Location

> **Reach for these when** your app's value is "the model can see — or change — my calendar,
> reminders, contacts, or where I am," and you don't want to hand-roll the EventKit /
> Contacts / CoreLocation permission dance and its error/settings-redirect edge cases. Core
> gives you one uniform request/status/error lifecycle (`Connectors`) across all four, plus
> per-connector read *and* write methods. **Exposing the write methods to a model is entirely
> your decision** — Core enforces nothing beyond the OS's own TCC grant (see the "no built-in
> gate" note below).
>
> **Examples that use them:** [`plate-today`](../examples/plate-today/) reads Calendar +
> Reminders + Contacts via hand-written `Tool` adapters (Path B);
> [`plate-today-tools`](../examples/plate-today-tools/) is the identical app rebuilt on
> Core's ready-made connector `Tool`s (Path A) — diff the two. Neither wires the write
> methods; those ship but aren't demonstrated in an example yet.

Core ships four permission-gated connectors, each wrapping the relevant system framework
(EventKit for Calendar/Reminders, Contacts, CoreLocation) with the request/status/error handling
already worked out. A unified `Connectors` facade covers the permission lifecycle (identical in
shape across all four); each connector's own type covers its actual data-fetching, which differs
per connector.

```swift
// Unified: check/request/manage permission for any connector the same way
if !Connectors.isAuthorized(.calendar) {
    let result = await Connectors.requestAccess(.calendar)
    if !result.granted {
        print(result.error ?? "Calendar access denied")
        if result.needsSystemSettings { Connectors.openSystemSettings(for: .calendar) }
        return
    }
}

// Per-connector: actual data, since each connector's data shape is different
let events = CalendarAccess.upcomingEvents(days: 7)
let reminders = await RemindersAccess.upcomingReminders(days: 7)
let contacts = ContactsAccess.search(query: "Jane", limit: 10)
let location = await LocationAccess.shared.currentLocation()
```

**Calendar, Reminders, and Contacts also have write methods.** `CalendarAccess.addEvent(title:
start:end:)` creates a new event; `.updateEvent`/`.deleteEvent` locate an *existing* one by its
exact title plus the day it's currently on — not an identifier. `RemindersAccess.addReminder`
creates a new reminder; `.updateReminder`/`.deleteReminder` (both `async`) locate an existing one
by title, with an optional current due date to disambiguate reminders sharing a title (a reminder
may have no due date at all, unlike an event's date, which is required). `ContactsAccess.
addContact` creates a new contact; `.updateContact`/`.deleteContact` locate an existing one by
given name, with an optional current family name to disambiguate. `newPhoneNumbers`/`newEmails`
on `updateContact`, when provided, replace that contact's entire existing list rather than adding
to it. Full signatures are in [the SDK reference](reference.md).

**Why name-based lookup, not an identifier** (`EventSummary`/`ReminderSummary`/`ContactSummary`
still carry `eventIdentifier`/`calendarItemIdentifier`/`identifier` for any consumer that wants
the raw token, but `update*`/`delete*` no longer take it): two real problems with identifier-based
lookup, found the hard way. Some calendar backends (Exchange/Outlook-synced calendars especially)
return identifiers long enough to meaningfully bloat an LLM's context just by appearing in a
listing; and, separately, a small on-device model calling these as tools proved unreliable at
faithfully copying an opaque identifier string across two tool calls. Locating by the same
title/name a person actually thinks in terms of fixed both. The one honest cost: for Contacts,
name collisions are common enough in a real address book that the "found more than one match"
error fires more often than it would for Calendar/Reminders (same-titled events on the same day
are rare) — an accepted tradeoff, not a bug; the error tells the caller to add a family name or
search first.

**If you're building your own model-callable tools on Core**, carry forward one naming lesson:
keep lookup parameters (`onDate`, `dueDate`, `familyName`, …) and change parameters
(`newDate`, `newTime`, `newFamilyName`, …) under clearly distinct names — never a bare
`date`/`familyName` serving double duty as both "search by" and "change to." A bare shared name
was tried first here and shipped a real bug: asked to "change the date," the model put the *new*
date into the field literally named `date` instead of a separate change field, so the lookup
searched on the wrong date and failed.

**There is no built-in gate on any of this beyond the TCC grant itself.** Unlike LocalLM Lab the
product, which has per-connector levels in its Security panel (Read-only, Changes, Full) deciding
whether a given session exposes add/update/delete as tools the model can call at all, Core has no
built-in level setting — that's UI/IPC behavior specific to that app, not something this SDK provides or enforces. The moment a
user grants Calendar/Reminders/Contacts access, every method above (read and write) is callable
unconditionally. Whether and how to expose update/delete to a model — as a `Tool` at all, behind
your own confirmation UI, restricted by your own app-level setting — is entirely your design
decision as the integrating developer.

Each connector requires its own Info.plist usage-description key and entitlement, same pattern as
[Info.plist strings](#infoplist-usage-description-strings-if-using-calendarreminders) and [Entitlements](#entitlements-if-using-calendarreminders) — see there for Calendar/Reminders; Contacts needs
`NSContactsUsageDescription` + `com.apple.security.personal-information.addressbook`, Location
needs `NSLocationUsageDescription` + `com.apple.security.personal-information.location`.
`examples/plate-today`'s `SearchContactsTool` and (build-time opt-in) location/weather tools are
working examples of each, including the exact packaging-script changes each one needs — note that
the reference app only wires up the read methods; the write methods above are equally available
but not currently demonstrated there.

**One real side effect worth knowing about**: requesting Location access briefly switches your
app's own `NSApplication.ActivationPolicy` to `.regular` for the duration of the fetch, then
restores it — required on-platform for CoreLocation to actually deliver a location fix to a
background-style (`.accessory`) app. If your app deliberately runs with no Dock icon, you'll see
that policy flip, briefly, while a location request is in flight. This isn't a bug to work around;
it's what makes Location work at all in that configuration.

**`tccutil reset Location <bundle-id>` doesn't work** — a real macOS limitation, not specific to
this SDK. It fails with "Failed to reset Location approval status." `tccutil reset All <bundle-id>`
is the one command confirmed to actually clear Location along with everything else; to reset
*only* Location, System Settings → Privacy & Security → Location Services → remove the app from
the list is the only reliable path found so far. Calendar/Reminders/Contacts all reset
individually fine.

### Clock and Weather: no permission needed, just drop them in

> **Reach for `ClockTool` specifically** whenever a session deals in relative dates ("tomorrow",
> "next week") — no local model has a built-in notion of "now", and pairing it with the
> Calendar/Reminders tools is the practical fix for their date-grounding caveat above.
> `WeatherTool` is the smallest example of a tool needing a network call but no permission grant.
>
> **Examples that use them:** `ClockTool` is used by nearly every example;
> [`code-buddy`](../examples/code-buddy/) and [`repo-qa`](../examples/repo-qa/) include it as a
> cross-check that tool-calling works at all.

Two more tools ship in Core that aren't part of the `Connectors` facade above, because they're not
permission-gated at all — no entitlement, no Info.plist key, nothing to request:

```swift
let tools: [any Tool] = [ClockTool(), WeatherTool(), /* ... */]
let session = try lab.makeSession(route: .chat, tools: tools)   // both only read, so they run with no authorizer
```

- **`ClockTool`** returns the current wall-clock date/time — fully local, no network.
- **`WeatherTool`** takes a place name and returns current conditions + a 7-day forecast, via
  Open-Meteo (keyless, no API key to manage). The one network call among these two.

Both accept an optional custom `description` in their initializer (`ClockTool(description:
"...")`) if you want to override how the model sees the tool — otherwise each falls back to its own
`defaultDescription`.

### Two paths to tool-calling: ready-made Tools, or write your own

> **3.0:** the ready-made connector tools are also offered as *plug-ins* (`lab.tools`), which a picker can choose per message; see [Tools: available, not attached](#tools-available-not-attached-30). The two paths below still work as written.

> **This is the decision you hit** the moment you want a `LanguageModelSession` to actually
> *call* a connector or MCP tool. **Path A** (Core's ready-made `Tool`s / `MCPTool`) is the
> default — drop them in an array, done, with hard-won on-device-model guidance baked into
> their descriptions. **Path B** (hand-write the adapter) is for when you need control over a
> tool's name, schema, or description. They mix freely.
>
> **Examples per path:** Path A — [`plate-today-tools`](../examples/plate-today-tools/)
> (connectors), [`repo-qa`](../examples/repo-qa/) (`MCPTool`),
> [`workspace-buddy`](../examples/workspace-buddy/) / [`code-buddy`](../examples/code-buddy/)
> (Workspace tools). Path B — [`plate-today`](../examples/plate-today/) (connectors) and [The reference-app walkthrough](walkthrough-plate-today.md)
> Step 5 (MCP, by hand).

Everything above (`CalendarAccess`, `RemindersAccess`, `ContactsAccess`, `LocationAccess`,
`MCPServerManager`) is a plain data-access layer — calling `CalendarAccess.updateEvent(...)`
doesn't require FoundationModels at all. Turning one into something a `LanguageModelSession` can
call is a separate decision, and Core gives you two ways to make it:

**Path A — ready-made `Tool`s (recommended default).** Every connector above also has a
ready-to-use `Tool`-conforming wrapper in Core, same one-line drop-in as `ClockTool`/`WeatherTool`:

```swift
let tools: [any Tool] = [
    ClockTool(),
    GetUpcomingEventsTool(), AddCalendarEventTool(),
    GetUpcomingRemindersTool(), AddReminderTool(),
    SearchContactsTool(), ListContactsTool(),
    GetCurrentLocationTool(),
]
// Pass an authorizer: AddCalendarEventTool and AddReminderTool change data, and a 3.0 session with none refuses them.
let session = try lab.makeSession(route: .chat, tools: tools, authorizer: authorizer)
```

The ones that change data — `AddCalendarEventTool` and `UpdateCalendarEventTool` (rated `.mutate`), `DeleteCalendarEventTool`
(`.destructive`), and the Reminders and Contacts add, update and delete tools — carry no per-connector level of their own.
What gates them is the session's authorizer ([Tool authorization](#tool-authorization-two-levers--which-tools-and-whether-they-ask-first)): a 3.0 session with none refuses them,
and `ConfirmingToolAuthorizer` asks the user first. Whether to expose them at all is still a plain array-membership choice:
include them in `tools` when your UI is ready to let the model delete something, don't when it isn't. Hand these tools to
`lab.makeSession`, not to Apple's `LanguageModelSession(tools:)`, which has no authorizer and runs them unasked.

These wrappers exist because real, observed on-device model failures shaped their design, and
that guidance is baked in verbatim rather than left for you to rediscover independently:
- **Lookup by title/name + date, never by identifier.** Some calendar backends' identifiers are
  long enough to blow the model's context window just by appearing in a listing, and the model
  proved unreliable at copying one faithfully across two tool calls. A human thinks "the Birthday
  event on Aug 25," not a per-backend token — so do these tools.
- **`current*` vs `new*` are always distinct field names, never shared.** A single field doing
  double duty as both "find by" and "change to" (e.g. a bare `date`) invites the model to put a
  *new* date where the *lookup* date belongs — confirmed as a real, reproduced bug before the
  split existed.
- **Contacts' `search`/`list` output shows `givenName`/`familyName` as separate labeled fields.**
  A caller only ever seeing a composed display name has no reliable way to know where to split it
  for `updateContact`/`deleteContact`'s separate name fields.
- **`RemindersTools`' date handling carries a caveat, not a fix**: the model has no built-in
  notion of "today" — Core stays raw in/raw out and doesn't inject anything into your session on
  its own — so a relative phrase like "tomorrow" can resolve to the wrong day, or the wrong year
  entirely, unless your app's system prompt/session state grounds it (pairing these with
  `ClockTool` is the practical mitigation, not a guarantee).

**Path B — write your own adapter**, exactly as [The reference-app walkthrough](walkthrough-plate-today.md) Step 4 walks through by hand: call
`CalendarAccess`/`RemindersAccess`/`ContactsAccess`/`LocationAccess` directly, choose your own
tool names, schemas, and descriptions. Full control, but you're on your own for the pitfalls
above. Both paths coexist — Path A is a thin wrapper over Path B, not a replacement for it, so
mixing (ready-made Calendar tools alongside a hand-written Contacts adapter, say) is fine.

**MCP gets the same two paths.** [The reference-app walkthrough](walkthrough-plate-today.md) Step 5 is Path B for MCP: match a tool by name out of
`state.tools`, inspect its `rawSchema` yourself, hand-write a matching `@Generable` `Arguments`
struct. `MCPTool` is Path A — it builds a `Tool` at runtime directly from an `MCPToolDescriptor`,
no `Arguments` struct required:

```swift
let descriptor = state.tools.first { $0.name == "search_issues" }!
let tool = try MCPTool(descriptor: descriptor, manager: manager)
let session = try lab.makeSession(route: .chat, tools: [tool], authorizer: authorizer)   // an MCP tool is untrusted: it asks
```

It works by turning the tool's real JSON Schema (`rawSchema`) into a FoundationModels
`DynamicGenerationSchema` at init time — the common, well-behaved subset real MCP servers emit
(object/properties/required, array/items, string/number/integer/boolean, string enums) converts
cleanly; anything past that (`oneOf`/`anyOf` unions, `$ref`, `const`, regex `pattern`) degrades to
a free-form string leaf rather than failing the whole tool, since the remote server is still the
real source of argument validation. `MCPTool(descriptor:manager:)` is a throwing initializer —
call it per-tool inside a loop and skip (or fall back to a hand-written Path B adapter for) any
tool whose schema doesn't build, rather than letting one malformed tool take down your whole list.

## Filesystem access: security-scoped bookmarks (example, not in Core)

> **You hit this when** you want the model to read or edit files in a folder the user picks —
> a coding assistant, a "summarize this project" tool, a notes agent. Two halves: getting a
> usable URL that survives relaunch under sandboxing (this section — **copy-paste example
> code, not a Core API**) and then acting on it ([Workspace tools](#workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url) — that half *is* Core:
> `WorkspaceAccess` + the Workspace `Tool`s).
>
> **Examples:** [`workspace-buddy`](../examples/workspace-buddy/) is the sandboxed folder
> picker + `WorkspaceTools` end to end; [`code-buddy`](../examples/code-buddy/) skips the
> picker (a CLI passes a path) and goes straight to the Workspace tools.

Unlike the four connectors above, filesystem access to a user-picked file or folder is **not**
part of Core, and isn't planned to be. The reason is structural, not an oversight: the actual
picker UI (`NSOpenPanel`) has to live in your app — Core has no UI of its own, by design, same as
the MCP server connect/auth UI in [Connecting to an MCP server](mcp-guide.md#connecting-to-an-mcp-server-three-auth-options-and-how-to-pick-between-them). There's no meaningful "unified API" to offer here the
way there is for the four TCC-gated connectors, since the picker itself is host-app UI, not
something a library call can produce.

What Core *can't* help you avoid is the trickier part once a folder is picked: under sandboxing, a
plain absolute path stops being usable the moment your app restarts — you need a **security-scoped
bookmark**, resolved and re-accessed explicitly on every launch. Below is a complete, working
example (not shipped as SDK code — copy what you need):

```swift
import AppKit
import Foundation

enum FolderAccess {
    // Call from a "Choose Folder…" button. Persists a security-scoped bookmark to UserDefaults so
    // access survives app relaunches — plain path strings don't, once your app is sandboxed.
    @MainActor
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        UserDefaults.standard.set(bookmark, forKey: "folderBookmark")
        return url
    }

    // Call before every use of the folder, including right after pickFolder() — resolving a
    // bookmark doesn't grant access by itself; you must bracket actual use between
    // startAccessingSecurityScopedResource() and stopAccessingSecurityScopedResource().
    static func resolveBookmarkedFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: "folderBookmark") else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            // The bookmark still resolves, but macOS wants a fresh one recorded (e.g. the
            // volume was renamed) — re-derive and persist it now rather than letting it go
            // stale again on the next launch.
            if let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: "folderBookmark")
            }
        }
        return url
    }

    // Bracket every actual read/write with this, even immediately after pickFolder() — holding
    // scoped access open longer than needed is the usual mistake; grab it, do the work, release.
    static func withFolderAccess<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url = resolveBookmarkedFolder() else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }
}
```

Required entitlements for this to work under App Sandbox:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

### WorkspaceAccess/WorkspaceTools: what Core gives you once you have that URL

> **Reach for this once you have a resolved root `URL`** from the bookmark pattern above — this
> is the actual read/write API, the Core half of filesystem access.
>
> **Examples that use it:** [`workspace-buddy`](../examples/workspace-buddy/) and
> [`code-buddy`](../examples/code-buddy/) both use these tools; `workspace-buddy`'s
> `withFolderAccessAsync<T>(_:)` is the async-aware access wrapper the gotcha below points to.

Once you have a resolved, access-bracketed root `URL` from the pattern above,
`WorkspaceAccess` — an ordinary Core type, not a permission-gated connector — is what actually
reads and writes inside it: `listFiles`/`readFile`/`writeFile`/`editFile`/`deleteFile` (plus
`search`, `tree`, `readFileRange`, `applyPatch`). No `requestAccess()` here — there's no OS dialog
for this, the picker *is* the consent, entirely on your side.

Every operation is `async throws` (since 2.0): it throws `WorkspaceAccess.WorkspaceError` (its `message`
is written for the model) or `CancellationError`, and runs off your actor, so calling it from the
main actor doesn't block the UI:

```swift
do {
    let text = try await WorkspaceAccess.readFile(in: root, path: "README.md")
    try await WorkspaceAccess.editFile(in: root, path: "README.md",
                                       oldString: "v1.0", newString: "v2.0", replaceAll: false)
} catch let error as WorkspaceAccess.WorkspaceError {
    print(error.message)
}
```

**How it stays inside the folder.** A path is resolved once, to real (symlink-free) components
under the root. From there every file is reached by descriptor: the root is opened, each folder
below it is opened with `openat(… O_NOFOLLOW)`, and the file is checked through its own descriptor.
A symlink that points outside the folder is refused, and so is one swapped in mid-operation —
the race the 1.x path-based checks left open. A symlink whose target stays inside the folder still
works for `readFile`/`writeFile`/`editFile`; `search`, `tree` and `listFiles` never follow symlinks.
Writes go to a temp file that is renamed into place (a create never overwrites a file that
appeared in the meantime), `editFile` keeps the file's permissions and refuses to commit if the
file changed while it was being edited, and `deleteFile` removes single files only — never a
folder, and for a symlink, the link rather than its target. What this can't stop: another local
process that can write to the folder changing a file's *contents* between two of your calls. Treat
the folder as a trust boundary shared with everything that can write to it.

**How much work one call can do.** `WorkspaceLimits` bounds it; every operation and every
workspace tool takes `limits:`. Defaults: `readFile` reads at most 8 MiB off disk (`maxReadBytes`)
and returns at most 2,000,000 characters (`maxReturnedCharacters`), cutting at a character
boundary and pointing the model at `readFileRange`; `editFile`, `applyPatch` and `search` won't
process a file over 64 MiB (`maxFileBytes`) — search skips it and says so in
`SearchResult.skippedTooLarge`; one `search` or `readFileRange` reads at most 256 MiB in total
(`maxScanBytes`, `SearchResult.scanBudgetExhausted`); each line given to a regular expression is
capped at 8 KiB (`maxRegexInputBytes` — `NSRegularExpression` can't be cancelled, so bounding its
input is the only thing that bounds its work); `writeFile` accepts at most 64 MiB (`maxWriteBytes`).

`editFile` — the one write operation actually meant for AI-assisted modification of an existing
file — is search-and-replace, not a unified-diff/patch format: `oldString`/`newString`, and it
fails loudly if `oldString` isn't found or isn't unique in the file (pass `replaceAll` if you
really mean every occurrence). This was a deliberate choice, not an obvious one: a small on-device
model reliably producing correct line numbers and context lines for a real diff format is a much
harder ask than quoting one exact, minimal, uniquely-identifying snippet — and it's a much simpler,
safer thing for Core to validate and apply. `writeFile` is create-by-default — it fails on an
existing file unless you pass `overwrite: true`, the deliberate opt-in for regenerating a
wholly-derived file (a CSV/JSON data export, a report), or `append: true` to add to the end of
one (accumulating a result that arrives in pages). Use `editFile` for a targeted change to
an existing file, same add-vs-update split Calendar/Reminders/Contacts already use.

Path A ready-made Tools ship too, same shape as everywhere else in Core: `ListWorkspaceFilesTool`,
`ReadWorkspaceFileTool`, `WriteWorkspaceFileTool`, `EditWorkspaceFileTool`, `DeleteWorkspaceFileTool`,
`SearchWorkspaceTool` (plain-text or regex), `WorkspaceTreeTool` (an indented directory listing),
`ApplyPatchTool` (a unified-diff patch, potentially touching several files in one call), and
`ReadFileRangeTool` (a byte/line window into a large file without reading it whole) — each takes
the root `URL` at init. `DeleteWorkspaceFileTool` isn't wired into `examples/workspace-buddy`'s
default tool list — a coding assistant that can delete files unprompted is a meaningfully bigger
risk than one that can only read/create/edit — but it's there if your own app wants it.
[`code-buddy`](../examples/code-buddy/) is the example that uses the full set, including
`SearchWorkspaceTool` and `ApplyPatchTool` for its coding-agent workflow.

**One real gotcha, not covered by [Filesystem access](#filesystem-access-security-scoped-bookmarks-example-not-in-core)'s own example**: that section's `withFolderAccess<T>(_:)` is
synchronous, bracketing a single, quick access. If you're handing these tools to a
`LanguageModelSession` — which can invoke several of them over the course of one
`respond(to:)` call — the security-scoped access window has to stay open for that *whole* async
call, not just a synchronous setup step. `examples/workspace-buddy` shows the async-aware version
(`withFolderAccessAsync<T>(_:)`) this actually requires.

### `FileBackedTool` + the "AIQL" data verbs: a mechanical MCP-dataset → CSV pipeline

> **Reach for this when** a data-source tool (an MCP dataset, an API, a big query) can return
> more than fits in a small model's context, and you'd rather have the model describe one
> transform than copy rows through itself. Skip it if your data tools already return small,
> bounded results.
>
> **Examples that use it:** [`aiql`](../examples/aiql/) is the end-to-end pipeline — a
> plain-English request over an MCP dataset → `FileBackedTool` → `loadTable`/`sqlQuery` → a CSV
> in a folder you chose, with a local MLX model.

The problem: a data-source tool (an MCP server tool for a dataset, an API, a big query) can
return far more than fits in a small model's context — after the host truncates it the model
sees a fraction, and it will paper over the gap rather than stop. Routing a bulk payload
*through* the model is the wrong shape: the model is good at deciding *what* to extract and
*how*, bad at being a copy buffer. Ask an 8–14B model to copy 80 records into a CSV and it
invents the ones it didn't see.

**`FileBackedTool`** wraps a dynamic-schema tool (an MCP tool adapter is the motivating case)
and adds one root-level argument, `saveAs`. When the model supplies a path, the wrapped tool's
raw result is written to `<workspace>/raw/<saveAs>` (the default `SaveAsPolicy`) and only a short receipt — byte/line count and a
bounded head preview — returns. The model then works from the file (`readFileRange` a window →
the verbs below), and the payload never enters its context. It's not a `Tool` that calls
another `Tool` (the model can't invoke that) — it's a **decorator the host applies** when
building the tool array. `FileBackedTool.mcp(descriptor:manager:root:)` wraps an
`MCPToolDescriptor` in one call; `saveAsAppend` accumulates paginated pages into one file.

**The data verbs** — ready-made `Tool`s, each takes the root `URL` at init, reads one workspace
file, does one mechanical transform, writes a CSV back, and returns a one-line receipt (so the
row data never reaches the model):

| Tool | SQL analogue | what it does |
|---|---|---|
| `JSONToCSVTool` (`jsonToCsv`) | `SELECT cols FROM json_array` | point `rowsAt` at the records array (use `describeJson` first), list `{header, path}` columns — `path` is a `JSONPath` (`attributes.EMAIL`, `regions[0].code`) into each record; omit `columns` to flatten every scalar field |
| `SelectColumnsTool` (`selectColumns`) | `SELECT a AS x, b` | project a CSV to chosen columns, reorder, rename |
| `FilterRowsTool` (`filterRows`) | `WHERE` | keep rows matching conditions (`eq`/`ne`/`contains`/`notContains`/`startsWith`/`endsWith`/`matches`/`gt`/`gte`/`lt`/`lte`/`isEmpty`/`notEmpty`), ALL or `matchAny` |
| `SortRowsTool` (`sortRows`) | `ORDER BY … LIMIT` | sort by a column (numeric if it's all-numeric), optional `limit` — **the mechanical answer to "top N", which is exactly where a small model fabricates** |
| `DedupeRowsTool` (`dedupeRows`) | `SELECT DISTINCT` | drop duplicate rows, whole-row or by `on:` columns |
| `AggregateRowsTool` (`aggregateRows`) | `GROUP BY` | `count`/`sum`/`avg`/`min`/`max` per group |
| `ConcatRowsTool` (`concatRows`) | `UNION ALL` | stack CSV files, columns matched by name — for paginated pulls or separate exports |
| `DescribeJSONTool` (`describeJson`) | — | compact structure summary (key paths, types, array lengths) — call before `jsonToCsv`; read-only |
| `CSVInfoTool` (`csvInfo`) | — | row count, columns, sample rows — check a stage produced what you expected; read-only |

The intended shape is a chain: `raw.json → describeJson → jsonToCsv → filterRows → sortRows →
out.csv`. The building blocks under them — `CSVCodec` (RFC 4180 encode/decode + a header-keyed
`Table`) and `JSONPath` (a read-only `a.b[0].c` resolver over a `JSONSerialization` value) — are
`public` for writing your own verbs. **Pagination:** the model calls the data tool once per page
with the same `saveAs` path plus `saveAsAppend: true`, and `jsonToCsv` / `describeJson` read the
resulting file of concatenated JSON values (`{…}{…}{…}`) as one dataset.

**`loadTable` + `sqlQuery` — real SQL over the pulled data.** Chaining the verbs asks the model to emit a correct
multi-call sequence, and small models drift — most often dropping the filter when it is the
third refinement. The answer is not another verb: it is to stop the model *orchestrating* and
have it *describe one query*. `loadTable(jsonPath, tableName)` stages a JSON records file into an
ephemeral SQLite table at `<root>/aiql.sqlite` — auto-detects the records array, sniffs
`INTEGER`/`REAL`/`TEXT`, splits a nested array into a `<table>__<field>` child table — and
returns the `CREATE TABLE`. `sqlQuery(sql, outputPath)` runs one read-only `SELECT`, opened
`SQLITE_OPEN_READONLY` behind a `sqlite3_set_authorizer` allowlist (SELECT/READ/FUNCTION only; no
DML, DDL, `ATTACH`), one statement, a 15 s timeout, a 100k-row cap, and writes the CSV. The model
never sees a row; only the schema and a result receipt. Two `loadTable` calls → a `JOIN` in one
`SELECT` (the cross-dataset case). Ranges, `GROUP BY`/`HAVING`, computed columns, sub-queries all
come for free. Validated end to end with Qwen3-8B and Qwen3-14B. This is what the `aiql` example
uses; the individual verbs stay as pure-Swift primitives for a pipeline that wants per-stage
control or no SQLite link.

[`examples/aiql`](../examples/aiql/) is the end-to-end SwiftUI app — a plain-English request
over an MCP dataset → this pipeline → a CSV in a folder you chose, with a local MLX model. It
builds the session with `SessionOptions(effort: .off)` so the Qwen3 model skips its `<think>`
pass — the pipeline is mechanical enough that the reasoning trace only adds latency ([The model layer](#the-model-layer-models-routing-and-sessions)).

### `WorkspaceAccess` + the Workspace tools — let the model touch files

> **Use it when** the model needs to read or edit files in a folder the user picked.
> Your app picks the folder and holds its security-scoped access open
> ([Filesystem access](#filesystem-access-security-scoped-bookmarks-example-not-in-core)); `WorkspaceAccess`
> keeps every read and write inside that folder. The ready-made tools (`SearchWorkspaceTool`,
> `WorkspaceTreeTool`, `ReadWorkspaceFileTool`, `ReadFileRangeTool`, `ListWorkspaceFilesTool`,
> `ApplyPatchTool`, `EditWorkspaceFileTool`, `WriteWorkspaceFileTool`, `DeleteWorkspaceFileTool`)
> are part of Core, not Apple's: they conform to FoundationModels' `Tool` protocol, so you pass
> them straight into `makeSession`.
>
> **Examples that use it:** [`code-buddy`](../examples/code-buddy/) offers seven of them (all but
> `ApplyPatchTool` and `DeleteWorkspaceFileTool`); [`workspace-buddy`](../examples/workspace-buddy/)
> (Core only, no MLX) and [`workspace-buddy-local`](../examples/workspace-buddy-local/) (a local MLX
> model) offer four: list, read, write and edit.

## Tool authorization: two levers — which tools, and whether they ask first

> **Reach for this when** a session has any mutating tool and you want a real answer to "could
> this call happen by mistake" — a model mistake, a prompt-injection string in a document it's
> summarizing, or an MCP server whose tools you didn't write. Skip it if every tool in your
> session is read-only, or your app has no untrusted input path into the model at all.
>
> **Examples that use it:** [`security-demo`](../examples/security-demo/) is the runnable
> version of everything below — a "Security" panel wiring both levers against Calendar +
> Todoist MCP.

A model with a mutating tool will sometimes call it wrongly: a model mistake, a prompt-injection
string in a document it's summarizing, or an MCP server whose tools you didn't write. Core gives
you two independent levers over that.

**Lever 1 — selection.** Which tools are in the session at all. Not just on/off: `ToolImpact`
(`.read` < `.mutate` < `.destructive`) is a ceiling.

```swift
let tools = (calendarTools + workspaceTools).limited(toMaxImpact: .mutate)   // no delete tools
```

`Sequence<any Tool>.limited(toMaxImpact:)` drops every tool above the ceiling (an unrated tool
counts as `.mutate` — never `.read`). It's a plain filter you apply before `makeSession`, so it
works on **any** runtime — a bare `LanguageModelSession`, a headless service, macOS 26. This is
how you offer a "Read-only / Changes / Full" choice per capability. Every ready-made SDK tool
declares its impact (`ImpactRatedTool`).

**Lever 2 — invocation.** Whether an in-list tool actually *runs* this call. (A short version of this lever, with the 3.0 change, is [The tool authorizer](tool-authorizer.md).) `ToolCallAuthorizer`
is the checkpoint between "the model chose to call this" and "the side effect happens." If you
pass no `authorizer:`, `makeSession` installs `FailClosedToolAuthorizer` (since 3.0).
Reads run; anything that could change data or send it out is denied, with no confirmation. Pass a
`ConfirmingToolAuthorizer` to ask the user, or `AllowingToolAuthorizer()` to say on purpose that every
call may run. Before 3.0 a session with no authorizer ran every call immediately, so a 2.x app
that relied on that must now pass one (see [migrating to 3.0](migrating-to-3.0.md)).

The authorizer for apps with a UI is **`ConfirmingToolAuthorizer`**. You say **who may approve what**
where the tools come from — per MCP server on `lab.mcp`, and for your own tools on the
authorizer — and it applies that on every call:

```swift
// Per MCP server, on lab.mcp. The server is the unit of trust.
lab.mcp.setTrust(.trusted, server: companyServer)        // believe its read-only / destructive labels
lab.mcp.setToolApproval(.allow, server: companyServer)   // its tools run without asking
// An untrusted server (the default) asks the user before every call.

let session = try lab.makeSession(
    route: "chat",
    tools: tools,                                         // your own tools
    authorizer: ConfirmingToolAuthorizer(
        channel: presenter,                               // how the user is asked
        policy: { call in await myPolicyService.decide(call) },   // optional external function
        hostTools: .ask(atOrAbove: .mutate, by: .user)))  // your own tools' approval (the default)
```

**The settings at a glance** (per server, with per-tool overrides):

| Level | Setting | Options | What it decides |
|---|---|---|---|
| Server | **Trust** — `setTrust(_:server:)` | `.untrusted` (default) · `.trusted` | Whether the server's own labels (`readOnlyHint`, `destructiveHint`) are believed. Untrusted: every tool counts as one that may change data (`.mutate`). |
| Server | **Approval** — `setToolApproval(_:server:)` | `.allow` — nothing asks<br>`.ask(atOrAbove: .mutate, …)` — reads run, changes and deletions ask<br>`.ask(atOrAbove: .destructive, …)` — only deletions ask<br>`.ask(atOrAbove: .read, …)` — every call asks<br>`nil` — the default for the trust level: untrusted asks before changes, trusted before deletions | Which calls need authorization before they run. |
| Server | ↳ **who answers** an ask — the `by:` of `.ask` | `.user` — the confirmation channel · `.policy` — your `ToolPolicy` (allow / deny / ask the user) | Who authorizes the calls that need it. |
| Tool | **On / Off** — `setToolEnabled(_:server:tool:)` | on · off (new tools start off in a static session; with `dynamicTools:` all are available) | Whether the model is offered the tool at all. |
| Tool | **Approval** — `setToolApproval(_:server:tool:)` | its own `.allow` / `.ask`, overriding the server's; `nil` goes back to the server's | e.g. allow `find-tasks` on an untrusted server, or always ask before `delete-object` on a trusted one. |

- **Trust is only ever yours or the user's to give** — never anything the server says.
  When a server's tools change against the list the user accepted, trusted or not, the changes the
  drift policy doesn't accept wait in `MCPServerState.pendingDrift` and the changed tools are held;
  the user reviews them and the app calls `acceptDrift(server:)`. Trust isn't dropped automatically.
- **The policy** (`ToolPolicy`) is your external authorization function — a policy service, an
  IT rule set, a rule over the arguments. It returns `.allow`, `.deny(reason:)` or `.askUser`.
  Use it for anything the per-server settings can't say (a per-tool allow list, a
  per-connector rule).
- **Fails closed.** No channel when the user must answer (a headless host: pass
  `channel: nil`), no policy when the policy must, a timeout (default 120s), or a declined
  question all deny.
- **Read live.** Settings are read on every call, so a change applies to a running session's
  next call — the model's and an MCP App view's alike. A view's answer is remembered per view
  and tool, so a polling dashboard asks once; deletions are asked each time.
- **Persisted by the snapshot.** `MCPServerManager.snapshot()` and `restore(from:)` keep each server's trust,
  approvals and accepted tool list (3.0). Store the snapshot with your server list.
- **To stop being asked about deletions** on a server you rely on, set `.allow`, or route them
  to your policy with `.ask(atOrAbove: .destructive, by: .policy)` so a rule decides and no one
  is interrupted.
- In a single-process SwiftUI app the channel is `ToolConfirmationPresenter` (Components) plus
  `.toolConfirmationSheet(presenter)` on a root view — no sheet UI of your own. Components'
  `MCPServerPickerView` shows each server's trust and approval.
- A denied call comes back to the model as the tool result `"DENIED: <reason>"` (for
  `String`-returning tools — all the SDK's and `MCPTool`), so the model adapts rather than the
  turn failing. A policy denial reads `"denied by policy: <reason>"`.

The authorizer is a floor, not a ceiling: it can't grant access to a tool that isn't in the
list, and it doesn't restrain your own code calling `CalendarAccess.deleteEvent(...)` or
`lab.mcp.callTool(...)` directly. It gates every call that goes through the session: the model's,
an MCP App view's, and your own `session.callMCPTool(...)`.

**Across processes.** If your app runs the session in a headless helper and the UI in another
process, implement `ToolConfirmationChannel` with your transport — that's the *only* security
code you write. `PendingToolCall.summary` is a `Codable` `PendingToolCallSummary` (`toolName` /
`argumentsDescription` / `origin` / `impact` / `initiator` / `serverApproval`; drops the
non-serializable `arguments`) built for exactly that hop; `DecisionGate` (Core) handles the
resume-once race between the reply and a cancellation. If the MCP connections live in the other
process, record each server's approval on the helper's `lab.mcp` before `makeSession` —
approvals are keyed by server id and need no connection.

**What the SDK can see inside an MCP tool.** It didn't write the tool, so on an untrusted server
every call is `.mutate`: `limited(toMaxImpact:)` can only include or exclude a whole server,
and the default approval asks even before a read-shaped call. Trust the server and its own
`readOnlyHint` / `destructiveHint` set each tool's impact. With `makeSession(includeMCPTools:
true)` the SDK tags the tools with their server (`.mcp` origin), which is how the server's
approval applies. A host that builds its own MCP-backed `Tool` type (e.g. one proxying to a
connection in another process) conforms it to `OriginTaggedTool` to keep that origin.

**Coming from 1.x.** `RuleBasedToolAuthorizer`, `ConfirmingToolAuthorizer`'s `requirement:`
closure and `setTrustsToolAnnotations` were removed in 2.0 — see
[Migrating to 2.0](migrating-to-2.0.md) for the mapping.

### What 3.0 adds to tool safety

The two levers above are the base. 3.0 adds the rest of a runtime around the model, on the idea that *the model
proposes and the runtime decides*. [The security guide](security-guide-for-hosts.md) explains each, in plain words,
and what your app must do; [MCP security in your app](https://thisbrain.ai/locallm/mcp-security.html) is the same story for servers.

- **Fail-closed by default.** With no authorizer, reads run and anything that could change data is denied (`FailClosedToolAuthorizer`).
  `AllowingToolAuthorizer()` says on purpose that every call may run. `ToolCallVerdict` records who decided.
- **Trust, per server.** A server is untrusted until you or the user say otherwise, and its own read-only and
  destructive labels are ignored (`lab.mcp.setTrust`, `setToolApproval`). One ask per tool per turn.
- **Drift review.** The SDK keeps the last tool list the user accepted and compares every new list against it. A
  rewritten description, a riskier tool, a new tool, or a different server name is held, asked about or blocked by the policy
  (`lab.mcp.driftPolicy = .standard`, `.strict` or `.permissive`). A held change waits in `MCPServerState.pendingDrift`
  and is resolved with `acceptDrift(server:)` or `rejectDrift(server:)`; Components' `ToolChangesCardView` draws the card.
- **Content is data.** Outside content reaches the model inside a frame that says where it came from. A tool call
  written out as JSON in a result always asks; text a reader can't see is dropped; control-token text is made inert;
  links from content are marked and confirmed. `session.asksBeforeSendingReadContent = true` makes any call that carries
  read text ask first. It is off by default; we recommend it for any app whose tools can send data out.
- **Programs run in a sandbox**, in direct-download builds only (`ExternalPrograms`, `MCPStdioLaunch`): deny-by-default
  Seatbelt, no network unless allowed, and an ask before every start. A launch that downloads and runs code unpinned is refused.
- **An audit stream.** `lab.audit.events()` yields a `SecurityAuditEntry` for each request, decision and outcome, which
  your app keeps. It is separate from `MCPDiagnostics`, which never records content.

## MCP servers

MCP, the Model Context Protocol, is how an app finds tools on a server someone else runs. In an app built on
`LocalLMLab`, `lab.mcp` holds the servers, and the session offers their tools to the model. Servers are untrusted
until the user says otherwise: see [Tool authorization](#tool-authorization-two-levers--which-tools-and-whether-they-ask-first)
above and [the security guide](security-guide-for-hosts.md).

New in 3.0:

- **Resources and prompts in chat.** Resources are the app's to use (the assistant reads one when a question needs it,
  through one read tool per server, or the user attaches one from the paperclip menu); prompts are the user's to pick
  (a `/` menu, an argument form with the server's own suggestions). The model never picks a prompt.
- **Richer tool results.** Images and embedded resources are kept; the model sees at most 20,000 characters of a result
  (`MCPResponseLimits.maxModelResultCharacters`).
- **Paste a setup.** A server's JSON setup (Claude Desktop's `mcpServers`, VS Code's `servers`, or one entry) fills the add form
  (`MCPServerConfigPaste`).
- **Per-app sign-in.** Each app registers under its own name, and a loopback fallback takes the sign-in reply on
  `127.0.0.1` when a server refuses the app's URL scheme (a sandboxed app needs `com.apple.security.network.server`).
- **Safer requests.** An elicitation that asks for a password, key, token or card number is declined before any dialog.

The details (connecting, the three sign-in types, what a tool call returns, server requests, MCP Apps, diagnostics)
are in [the MCP client guide](mcp-guide.md). For a safe first setup, see [MCP in your app](https://thisbrain.ai/locallm/mcp-sdk.html).

## Scope and boundaries: what Core doesn't do

**Source compatibility holds within a major version.** Every 3.x release keeps existing
code compiling unmodified against a later one. New capability shows up as additive surface
(new optional/defaulted parameters, new protocol methods with a default implementation, new
enum cases per the `@unknown default` point below); anything that would force you to edit
working code just to keep building waits for the next major version. If you hit "X is inaccessible due to
internal protection level" on something that looks like it should be public, file it — that's
a bug against the guarantee, not expected churn. This covers source compatibility, not binary
— you rebuild against whatever version you pin, there's no supported "drop in a newer
xcframework without recompiling" path.

The following are deliberate boundaries, not gaps waiting on a future release:

- **No filesystem picker/bookmark UI in Core** — a folder picker is host-app
  UI and Core ships no UI at all. But you're not writing it from scratch: [Filesystem access](#filesystem-access-security-scoped-bookmarks-example-not-in-core) has a complete, copy-pasteable `FolderAccess`
  (`NSOpenPanel` + security-scoped bookmark persistence + the async-aware access window a
  `LanguageModelSession` needs), and
  [`workspace-buddy`](../examples/workspace-buddy/) is a full reference app that does exactly
  this. What *is* in Core: `WorkspaceAccess`/`WorkspaceTools` ([Workspace tools](#workspaceaccessworkspacetools-what-core-gives-you-once-you-have-that-url)) — the read/write/edit logic
  for once you have a resolved folder URL.
- **`ModelAvailability` is a non-frozen `enum`.** If you `switch` over it exhaustively you need
  an `@unknown default` — new cases can land in a minor version. (Same for `ResidencyEvent` /
  `SessionEvent` / `DownloadEvent` / `MCPConnectionStatus` / `MCPServerError`.)
- **No logging of prompts, responses, or tool calls.** The MCP client has `MCPDiagnostics`
  ([MCP diagnostics](mcp-guide.md#diagnostics-when-a-user-reports-an-mcp-problem)) for connection / auth / stream troubleshooting — `os.Logger` plus an opt-in event buffer
  — but it is strictly off-content (never prompt or response text; tokens redacted). Core writes
  no persisted trace of what the model saw or said. If your app wants that, you build and own it
  on two streams the SDK gives you: the session's `session.events` and the security audit stream
  `lab.audit.events()` (each request, decision and outcome as a `SecurityAuditEntry`).

## App Sandbox — building for the Mac App Store

> **Reach for this when** you're distributing (or considering distributing) via the Mac App
> Store, or you just want App Sandbox for its own sake. Skip this whole section if you're only
> shipping Developer ID + notarization — that path needs none of this.
>
> **A real app that does this:** [JevDK](https://github.com/ancientcomputing/jevdk), built on the SDK and
> [available on the Mac App Store](https://apps.apple.com/app/jevdk-decision-lab/id6823207361), is the one to read for a sandboxed, App Store-signed build. For the signing
> scripts, [`plate-today`](../examples/plate-today/)'s `packaging/` folder has both signing paths — see the closing
> paragraph of [Mac App Store signing setup](#one-time-apple-developer-portal-setup-for-mas-signing) below for which is which.

Core has been tested under App Sandbox — confirmed via a real sandboxed, Developer-ID-signed,
notarized build (not just code review). Two apps built on the SDK, LocalLM Lab (with
Private Cloud Compute and local MLX models) and JevDK, have also gone through App Store Connect's
upload validation into TestFlight; [Shipping the model layer](#shipping-the-model-layer-through-app-store-connect)
has what that turned up. Here's exactly what's needed and what was actually verified.

> **Related, for model downloads:** the sandbox is one half of the security story for an app that
> fetches models at runtime. The other half is what it fetches: the trust policy, preflight, hash
> verification and cache cap under [supply-chain hardening](local-models-mlx.md#mlxmodelprovider--run-open-weight-models-locally-locallmlabsdkinference),
> and [pinning, updating and cleaning up model versions](local-models-mlx.md#pinning-updating-and-cleaning-up-model-versions).
> A sandboxed app also relocates the Hugging Face cache into its container; the SDK follows it.

### Entitlements

Add `com.apple.security.app-sandbox` alongside whichever connector entitlements from [Entitlements](#entitlements-if-using-calendarreminders)
you're already using:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

**`com.apple.security.network.client` is easy to miss and fails silently, not loudly.** Under
sandbox, any outbound network connection is blocked without it — no crash, no error dialog, just
a request that hangs or times out. This bit a real reference app during testing: Weather failed
with a generic "connectivity issues" message and the MCP client's server connections never
completed, both traced back to this one missing key. If you're using the MCP client, `WeatherTool`,
or anything else that reaches the network, you need this entitlement — it's not optional the way
the Calendar/Reminders/Location entitlements are (those are only needed if you're using that
specific connector).

### What's confirmed working under sandbox, live-tested

- **Calendar, Reminders** — including the actual first-time TCC grant prompt (not just a
  pre-existing grant carried over from testing an unsandboxed build under the same bundle ID —
  see the caution below).
- **The MCP client, end-to-end**, including OAuth: connect, sign in via the system browser,
  redirect back into the app, tool calls. The usual OAuth redirect is a URL-scheme handoff
  ([the OAuth redirect/callback setup](mcp-guide.md#oauth-redirect-uri--must-set-this-yourself-if-your-server-uses-oauth)), not a local HTTP listener, so it needs nothing beyond
  `network.client`. Only the loopback fallback (since 3.0, for a server that refuses your app's URL scheme)
  listens on `127.0.0.1`, and for that a sandboxed app also needs `com.apple.security.network.server`.
- **Keychain token storage** (`MCPOAuthTokenStore`/`MCPPATStore`, [Keychain storage](mcp-guide.md#keychain-storage--automatic-isolation-native-api-sandbox-safe)) — round-tripped
  correctly under the sandboxed per-app-container Keychain access group.

**Outside the scope of sandbox testing to date**: Contacts, and Location's accuracy/reverse-geocoding
behavior beyond "it returns something" (a real, pre-existing, non-sandbox-specific bug in reverse
geocoding was hit during testing, unrelated to sandboxing itself).

### A testing caution: reset TCC before you trust a "no prompt" result

If you add the sandbox entitlement to an app you've already tested unsandboxed under the same
bundle identifier, TCC may silently honor grants from that earlier testing — you'll see no
permission prompt at all, and it's genuinely ambiguous whether that means "already granted" (fine)
or "the prompt is broken under sandbox" (not fine) until you check. Before trusting a "worked with
no prompt" result while testing a newly-sandboxed build, reset first:

```bash
tccutil reset Calendar <your-bundle-id>
tccutil reset Reminders <your-bundle-id>
tccutil reset AddressBook <your-bundle-id>
tccutil reset All <your-bundle-id>   # Location can't be reset individually (see Connectors)
```

### One-time Apple Developer Portal setup for MAS signing

Three artifacts, each depending on the previous one, all created at
[developer.apple.com/account](https://developer.apple.com/account) — a real membership required,
and this is genuinely portal/GUI work, not something scriptable. Done once per app; the
certificate can be reused across apps, the App ID and profile are per-app.

**1. An Apple Distribution certificate** (covers both app and installer signing in the modern
single-certificate flow — some older accounts may still use the separate "3rd Party Mac Developer
Application"/"3rd Party Mac Developer Installer" pair instead, which works the same way).

- Easiest: **Xcode → Settings (⌘,) → Accounts → select your team → Manage Certificates… → + →
  Apple Distribution.** Xcode generates the CSR and installs the certificate automatically.
- Manual alternative: generate a CSR yourself first (**Keychain Access → Certificate Assistant →
  Request a Certificate From a Certificate Authority…**, save to disk), then **Certificates,
  Identifiers & Profiles → Certificates → + → Apple Distribution**, upload the CSR, download the
  resulting `.cer`, double-click to install.
- Verify: `security find-identity -v -p codesigning` should list `"Apple Distribution: <your
  name> (<TEAMID>)"`.

**2. An App ID**, explicit (not wildcard), matching your app's real bundle identifier.

**Starting from `plate-today` or `components-demo`? Change `CFBundleIdentifier` in `Info.plist`
first.** App ID registration is global across Apple's entire Developer Portal, not scoped per
team. `plate-today`'s bundle ID (`lab.locallm.sdk.reference.platetoday`) is already registered
under this project's own team (it has a real MAS provisioning profile — see the walkthrough
below), so no other developer's account can register it. `components-demo` has no MAS path today
and its bundle ID (`lab.locallm.sdk.reference.componentsdemo`) isn't currently registered as an
App ID at all — but don't build a real product under it regardless: it's this project's own
reverse-DNS namespace, and if a MAS path is ever added for `components-demo` later, this project
would register it too. Building and running either example locally works fine unmodified —
`CFBundleIdentifier` doesn't need to be globally unique for Developer ID/ad-hoc signing — but MAS
submission of your own app needs your own bundle ID from the start.

- **Identifiers → + → App IDs → App → Explicit Bundle ID** (e.g. `com.yourcompany.yourapp`).
- Leave every Capability unchecked unless something you're using genuinely needs an App
  ID-level capability (iCloud, Push Notifications, etc.) — App Sandbox, network client, and the
  Calendar/Reminders/Contacts/Location entitlements are all declared directly in the entitlements
  file (see [Entitlements](#entitlements), above), not toggled here. The exception is Private Cloud Compute: once Apple grants it to
  your account, turn it on here ([Shipping the model layer](#shipping-the-model-layer-through-app-store-connect)).

**3. A Mac App Store distribution provisioning profile**, tying the App ID to the certificate.

- **Profiles → + →** the Distribution-section option for App Store (labeled "Mac App Store
  Connect" or "Mac App Store" depending on the portal's current wording — not Development, not
  Developer ID) **→** select the App ID from step 2 **→** select the certificate from step 1 **→**
  name it **→ Generate → Download**.
- **Install it** — double-click the downloaded `.provisionprofile`, or drag it onto Xcode's Dock
  icon, or **Xcode → Settings → Accounts → select team → Download Manual Profiles** (pulls
  everything associated with the account, not just this one file).
- **Where it actually lands matters**: modern Xcode installs profiles to `~/Library/Developer/
  Xcode/UserData/Provisioning Profiles/`, **not** the older `~/Library/MobileDevice/Provisioning
  Profiles/` path that's still commonly referenced in older docs/scripts online — check the
  right location if a script can't find it. Verify and read its contents with:
  ```bash
  ls ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
  security cms -D -i <path-to-file> | plutil -p - | grep -E "Name|application-identifier|TeamIdentifier|UUID|ExpirationDate"
  ```
  Confirm `application-identifier` matches `<TEAMID>.<your-bundle-id>` and `Name` is what you'd
  expect before assuming it's the right one.

`examples/plate-today/packaging/build-and-sign-mas.sh` is a complete, working example of the
Apple-Distribution-signed, sandboxed `.pkg` build this setup enables — Developer ID signing +
notarization is the other supported path (`build-and-sign.sh`), for distributing outside the Mac
App Store.

### Shipping the model layer through App Store Connect

What uploading LocalLM Lab and JevDK to App Store Connect turned up. None of it needed an SDK API
change.

**Embedding `LocalLMLabSDKInference` (local MLX models).** Since 2.1 the framework's bundle ID is
`lab.locallm.sdk.inference` (in 2.0 it was `mlx-swift_Cmlx`, and App Store Connect rejects a bundle
ID with an underscore: error 90277, not a valid bundle identifier), and the xcframework embeds as is: no renaming, and no copying
`mlx-swift_Cmlx.bundle` into your app's Resources. If you did that for 2.0, remove it when you
upgrade: the copy and the framework's own copy share the bundle ID `mlx-swift.Cmlx.resources`, and a
duplicate bundle ID can fail validation too (90685). MLX loads its Metal library from the framework's
own `Versions/A/Resources/default.metallib`, so don't strip the framework's Resources. Before an
upload, check that every bundle ID in the app is only letters, digits, hyphens and dots:

```bash
find "MyApp.app" -name Info.plist -exec /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' {} \; 2>/dev/null \
  | grep -vE '^[A-Za-z0-9.-]+$' || echo "all bundle IDs valid"
```

**Private Cloud Compute.** `com.apple.developer.private-cloud-compute` is a managed capability:

- Apple grants it to your developer account ("Access to models on Private Cloud Compute"). Then turn
  it on for your App ID ([Mac App Store signing setup](#one-time-apple-developer-portal-setup-for-mas-signing)) and
  regenerate your provisioning profiles.
- Sign the entitlement only when the embedded profile grants it. An entitlement the profile doesn't
  cover stops the app from launching.
- Run PCC in the profile-covered executable: your app's main executable. A helper tool your app
  launches has no App ID or profile of its own, so the entitlement can't work there, and a sandboxed
  helper signed with `com.apple.security.inherit` may carry no other entitlement. Register
  `PCCModelProvider` in the app's own `LocalLMLab`, not in a spawned process.
- Check the entitlement before touching PCC. Without it FoundationModels traps on the first PCC call,
  `availability(for:)` and `probe(timeout:)` included, so read the running process's own entitlement
  first and register the provider only when it's there:

```swift
import Security

let pccEntitled: Bool = {
    guard let task = SecTaskCreateFromSelf(nil),
          let value = SecTaskCopyValueForEntitlement(
              task, "com.apple.developer.private-cloud-compute" as CFString, nil) else { return false }
    return (value as? Bool) ?? true
}()
if pccEntitled { providers.append(PCCModelProvider()) }
```

LocalLM Lab's own Developer ID build (the DMG) doesn't carry the PCC entitlement, so it has no PCC;
its Mac App Store build does. Whether a Developer ID provisioning profile can grant it hasn't been
tested.

## Components: prebuilt SwiftUI (MCP servers + the model layer)

> **Reach for this when** you want a working settings surface — for **MCP servers** (add /
> remove / reconnect, all three auth types from [Connecting to an MCP server](mcp-guide.md#connecting-to-an-mcp-server-three-auth-options-and-how-to-pick-between-them), per-tool and per-resource enable/disable,
> resource + prompt browsing) **or the model layer** (pick a model, download an open-weight
> one from Hugging Face with a progress bar, see on-disk size, configure an online provider +
> key + web search) — without building that UI yourself. It's SwiftUI, entirely optional, and
> layered strictly on Core's public API (nothing here you couldn't write). **Skip it if** your
> app has no user-facing configuration, or your design is too bespoke to reuse these views —
> go straight to `MCPServerManager` ([The MCP client API](mcp-guide.md#the-mcp-client-api)) or `lab.models` ([The model layer](#the-model-layer-models-routing-and-sessions)).
>
> **Examples that use it:** [`components-demo`](../examples/components-demo/) — essentially
> the whole app is the MCP views; [`model-switch`](../examples/model-switch/) — the online-provider
> panel (`AIModelsSettingsView`); [`components-updates-demo`](../examples/components-updates-demo/) —
> the model onboarding, update and cleanup views, driven from simulated data (and
> [`mlx-control-room`](../examples/mlx-control-room/) runs the same flows against a real `MLXModelProvider`).

See [the annotated examples](annotated-examples.md) for both apps' full source with every
`Components`/`Core` touchpoint marked.

Everything above is `Core` — a plain Swift engine with no UI dependency. `Components` is a
separate, optional package built on top of Core's public API. It ships one binary-artifact
dependency on `Core.xcframework` and no source access to Core's internals.

**MCP-server views:**

- **`MCPServerManagerObservable`** — an `ObservableObject` wrapper around `MCPServerManager`, for
  SwiftUI apps that want `@Published`-style reactivity without writing the wrapper themselves (see
  [The MCP client API](mcp-guide.md#the-mcp-client-api)'s note).
- **`MCPServerPickerView`** — add/list/reconnect/disconnect/remove MCP servers, all three auth
  types from [Connecting to an MCP server](mcp-guide.md#connecting-to-an-mcp-server-three-auth-options-and-how-to-pick-between-them) (picked with a radio group), per-tool and per-resource enable/disable, and a "Save As…" action that
  exports a server's tools/resources/prompts to a text file. Each server row has its
  **Trust** and **"Before a tool runs"** approval ([Tool authorization](#tool-authorization-two-levers--which-tools-and-whether-they-ask-first)) — an approval your app routes to its
  policy shows as "Decided by the app's policy" and isn't editable there — plus a notice when none
  of a server's tools are on (so a model can't use it yet) and one when a trusted server's tools
  changed since it was trusted ("Trust Again").
- **`MCPOAuthWaitingView`** — shown while an OAuth sign-in is in flight in the system browser;
  `MCPServerPickerView` already uses this internally during its own add-server flow.
- **`MCPResourcesView`** / **`MCPPromptsView`** — browse a session's enabled resources/prompts and
  read/expand one, via callbacks (`onAttach`/`onUse`) so your app decides what to actually do with
  the result — append it to a text field, feed a session, save it, whatever fits your UI.
- **`MCPElicitationPresenter`** + **`View.mcpElicitationSheet(_:)`** — the ready-made handler for
  server-initiated elicitation ([Server-initiated requests](mcp-guide.md#server-initiated-requests-elicitation-and-the-sampling--roots-seams)). `MCPElicitationPresenter()` conforms to
  `MCPElicitationHandler`; pass it to `MCPClientHandlers(elicitation:)` and attach the sheet once
  near your root. When a server asks for input mid-tool-call, a sheet appears naming the server
  and renders a typed, validated form (text / date / number-with-bounds / toggle / single- and
  multi-select), plus a URL-mode variant. Nothing to build; see
  [the elicitation UI page](https://thisbrain.ai/locallm/mcp-elicitation.html).

**Model-layer views** (all bind directly to `lab.models`, an `@Observable` `ModelRegistry` — no
polling):

- **`ModelPickerView`** — the local-model surface. Lists `registry.knownModels` with an
  availability badge each (*Ready* / *Not downloaded* / *Needs credential* / *Requires macOS 27*),
  bound to a `Binding<ModelID?>` for the current choice. When `LocalLMLabSDKInference` is linked it
  also renders a **"Downloaded models"** section: each installed model with its on-disk size, a
  **live download progress bar** per in-flight download (`registry.downloads`), and an **"Add from
  Hugging Face"** field wired to `registry.startDownload(_:)`. On macOS 26, `show27OnlyModels: true`
  (the default) shows `pcc` / `claude` / `mlx` as disabled "Requires macOS 27" rows. This is the
  ready-made version of the hand-rolled `.downloadingModel(fraction)` progress loop in the
  model-layer examples ([`repo-qa-local`](../examples/repo-qa-local/),
  [`workspace-buddy-local`](../examples/workspace-buddy-local/), [`aiql`](../examples/aiql/),
  [`code-buddy`](../examples/code-buddy/)) — those roll their own to show the raw `mlx.download`
  event stream; a real settings panel uses this.
- **`AIModelsSettingsView`** — the whole "AI Models" panel: the built-in families with live
  availability, then one `ProviderSettingsSection` per configured **online** provider, then an
  **Add provider** menu (OpenAI / Anthropic / OpenRouter / custom OpenAI-compatible). The host owns
  `[RemoteProviderDraft]` (persist keys to the Keychain) and the `onSave` / `onRemove` / `onTest`
  closures that turn a draft into a `RemoteModelProvider` and call `lab.models.replace(_:)`.
  `Components` has **no dependency on `LocalLMLabSDKRemote`** — the closures are the seam, so a
  macOS-26 host app can present the panel and hand the 27-only work to a helper. See [Online providers](remote-providers.md).
- **`ProviderSettingsSection`** — one provider block: API-key field, a **Configured ✓** badge, a
  per-model row editor (add / trash), an **Enable web search** toggle + **Max searches** stepper
  once configured, and a **Test connection** button (one result per model, via the host's
  `probe(for:)`). Usable on its own if you don't want the whole `AIModelsSettingsView`.
- **`RemoteProviderDraft`** / **`RemoteProviderKind`** / **`ProviderTestOutcome`** — the plain data
  types the host maps to `RemoteProviderConfig` in ~20 lines (see
  [`examples/model-switch`](../examples/model-switch/)'s `ProviderGlue.swift`).
- **`ClaudeAuthField`** — a ready-made secure field for the Anthropic API key that
  `ClaudeModelProvider(auth: .apiKey(_:))` needs for prototyping (a shipped app uses App Attest).
  The value is handed to the host via the binding; `Components` never persists it.
- **`ModelOnboardingView`** + `ModelOnboardingModel` — a *Validate → Download → Pin* stepper, one block
  per repo. A failed preflight names its stage and reason and nothing after it runs; the download shows
  progress and can be cancelled; the Pin step shows the resolved commit (and can check it against the
  commit you ship, `ModelOnboardingRequest.expectedRevision`). Needs only Core: `ModelOnboardingSource`
  adapts `lab.models` (`init(registry:)`) or an `MLXModelProvider` (`init(provider:)`). See
  [Pinning, updating and cleaning up model versions](local-models-mlx.md#pinning-updating-and-cleaning-up-model-versions).
- **`ModelUpdateView`** + `ModelUpdateModel` — check → what changes → update → roll back, with a
  *switching* state and a `pauseInference` hook the host awaits after the download and before the pin
  moves. **`ModelVersionsView`** + `ModelVersionsModel` — the versions on disk, what removing each would
  actually free, and a guarded **Remove**. Both are **provider-agnostic**: `MLXModelProvider`'s update and
  cleanup APIs live in Inference (macOS 27), which Components doesn't link, so the views take plain value
  types (`ModelUpdateOffer`, `ModelVersionRow`) and closures (`ModelUpdateActions`, `list` / `remove`) that
  you adapt from your provider — about forty lines; `Components/README.md` has the adapter.

`ModelPickerView` (local models + MLX download) and `AIModelsSettingsView` (online providers) are
two separate surfaces by design — compose a full "AI Models" panel by presenting whichever your
app needs, or stacking both.

None of these views hold persistence of their own — the MCP views go through
`manager.core.restore(from:)`, the model views through `lab.snapshot()` / `lab.restore(from:)`
and your own Keychain, at launch, with whatever you've saved.


## More guides

- [The quickstart](quickstart.md) and [the glossary](glossary.md)
- [The MCP client guide](mcp-guide.md)
- [Open-weight models on the Mac (MLX)](local-models-mlx.md), [online providers](remote-providers.md) and
  [decision models (Jev)](decision-models.md)
- [The reference-app walkthrough](walkthrough-plate-today.md) and [annotated examples](annotated-examples.md)
- [The reference](reference.md) and [the API surface](api-surface.md)
- [Migrating to 3.0](migrating-to-3.0.md), [the security guide](security-guide-for-hosts.md), [the CHANGELOG](../CHANGELOG.md)
