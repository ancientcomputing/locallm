# Migrating to the LocalLM Lab SDK 3.0

3.0 is a **breaking release in behavior, not in source**. Nothing you compiled against 2.3 stops compiling:
every changed signature gained only parameters with defaults, and the one type whose coding changed
(`ToolImpact`) is still `Codable`. What changes is what the SDK does when you call it the same way. Three of
those changes can stop an app that worked: a session with no authorizer now refuses anything that writes (§3),
loading a model no longer downloads it (§4), and MCP tools reach the model under new names (§5). Every 3.x
release after 3.0 is source compatible with `3.0.0`.

Most apps change a few lines. What you edit: tell a session who may approve a tool call (§3), and add an
explicit download step before a local model loads (§4). What behaves differently is in §5. What's new, all opt in,
is in §7.

## 1. Platform: unchanged

`platforms: [.macOS("26.0")]`, Xcode 27 to build, macOS-27-only providers behind `if #available(macOS 27, *)`,
as in 2.0 ([`sdk-guide.md`, "Targeting macOS 26 and 27"](sdk-guide.md)).

## 2. Point your manifest at the new release

Add `3.0.0-GA` to your manifest's `knownSDKReleases` with the checksums from the release's `.sha256` assets
(tag `v3.0.0-GA`), and build with:

```sh
LOCALLM_SDK_VERSION=3.0.0-GA swift build
```

The new public types are in `LocalLMLabSDKCore` (the plug-ins, dynamic tools, workspaces, chat core and security
types), `LocalLMLabSDKInference` (the prompt cache), `LocalLMLabSDKComponents` (chat views) and
`LocalLMLabSDKMCPAppsHost`. Rebuild your app against the new xcframeworks; nothing guarantees an app built against
2.3 keeps working if a 3.0 xcframework is dropped in without recompiling.

## 3. A session with no authorizer is fail-closed

*Short version, with all three authorizers side by side: [the tool authorizer](tool-authorizer.md).*

Every tool call passes through the session's `ToolCallAuthorizer`: the model's own calls, an MCP App widget's calls,
and your code calling `callMCPTool`. In 2.3, `makeSession(route:…)` with `authorizer: nil` (the default) ran every
call unasked. In 3.0 `nil` means `FailClosedToolAuthorizer`: calls rated `.read` run; anything that may change
data or send it out is denied, with a result the model reads (`DENIED: <reason>`) so the turn goes on. An unrated
tool counts as `.mutate`.

If your app made a session without an authorizer and its tools write, they now get denied. Say what you mean:

```swift
// An app with a UI: ask the user (the normal choice).
let authorizer = ConfirmingToolAuthorizer(channel: presenter,
                                          hostTools: .ask(atOrAbove: .mutate, by: .user))
let session = try lab.makeSession(route: .chat, tools: tools, authorizer: authorizer)

// A batch job or an eval with no one to ask, whose tools you accept running unasked: the 2.3 behavior.
let session = try lab.makeSession(route: .chat, tools: tools, authorizer: AllowingToolAuthorizer())
```

`ConfirmingToolAuthorizer`, the per-server trust and approval settings (`lab.mcp.setTrust`, `setToolApproval`) and
`DriftPolicy` work as in 2.x, with two additions: a tool the user declined isn't asked about again in the same turn
(one ask per tool per turn), and a tool waiting for the user's review of a change is left out of the turn, with the
model told it's waiting.

## 4. Loading never downloads

Downloading is now its own step, taken by your app. A session, `capabilityProbe`, `prewarm`, the prompt-cache
self-test, a paired speed helper or a paired adapter on a repo that isn't downloaded (at its pinned revision, if
pinned) fails with `LocalLMLabError.modelUnavailable(reason:)` naming the model. Before 3.0 a load fetched missing
weights itself. A model already on disk keeps loading offline.

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

Because loading no longer touches the network, four things moved from load time to download time:

- **The trust policy applies at download.** A model, speed helper or adapter that's already downloaded keeps
  loading after your policy changes. To revoke one, remove it (`remove(_:)`) or unpair it
  (`pairDraftModel(nil, with:)` / `pairAdapter(nil, with:)`). Sessions no longer throw
  `.validation(stage: .trustPolicy, …)`; that error now comes only from `download` and `validate`.
- **Unpinned models don't update themselves.** Before 3.0, loading an unpinned model asked Hugging Face for the
  current `main` and fetched it if it had moved. Now the version you downloaded stays until you call `download`
  again. The old snapshot stays on disk until you remove it (`snapshots(for:)`, `removeSnapshot(_:revision:)`).
  Pin a revision (`pinnedRevisions`) to control updates, as recommended for production.
- **A damaged download isn't repaired on load.** A file deleted or corrupted inside a downloaded model fails the
  load. Remove the model and download it again.
- **A speed helper that isn't downloaded fails the session** instead of running without it.

Full detail: [`sdk-guide.md`, "The model layer"](sdk-guide.md).

## 5. What behaves differently

- **MCP tools reach the model as `<prefix>_<tool>`** (`github_list_issues`), and each description starts with a
  header naming the service ("GitHub (you call it GH): …"). The prefix comes from the server's domain, package
  or display name (`MCPToolNaming`); read or change it with `MCPServerState.toolPrefix` and
  `setToolPrefix(_:server:)`. A tool's own name stays in refs, approvals and `ToolCallRecord`s. If your tests or
  code match the names the model sees, expect the prefix. Two tools never share a name, and a prefix that
  would clash with another server's gets a number.
- **The prompt cache is on by default** for local (MLX) models: memory only, within a budget sized to the Mac
  (about 14 GB on a 64 GB Mac, about 3 GB on a 24 GB one), for the verified families (Qwen3.5/3.8, Qwen3, Qwen3
  MoE, Llama, Nemotron 3.5) and for any model that passes a one-time self-test (1–4 seconds, once per model
  version per Mac). Turn it off for the provider with `MLXModelProvider(promptCache: .off)`, or for one session
  with `SessionOptions(bypassPromptCache: true)` (a benchmark, say). The on-disk tier is opt in and encrypted.
  Read what it's doing with `promptCacheStatus(for:)`. Answers can differ in wording from a cache-off run by
  rounding; a restore itself is bit-identical to a fresh read.
- **Stop, then wait.** A reply ends only once its generation has stopped. Before quitting mid-reply, call
  `await MLXModelProvider.stopGenerating()`, or the process can exit while the GPU is still working. A turn begun
  right after a Stop waits for the provider's call to return.
- **MCP tool results are capped for the model** at 20,000 characters, with a note saying how much was cut and
  how to get less. Raise it for a model with a much bigger window, or send results whole with `0`:
  `MCPResponseLimits(maxModelResultCharacters:)`. Content a server shares for attaching is capped separately
  (`maxAttachedContentBytes`, 32 KB by default).
- **`ToolImpact` encodes as its name.** It's still `Codable`, but writes `"read"`, `"mutate"` or `"destructive"`
  where it wrote `0`, `1`, `2`, so an audit log or a saved approval says what it means. Saved numbers still
  decode. Code that reads that JSON itself, or compares the integer, must read names.
- **The `LOCALLMLAB_*` developer overrides are debug-only.** `MLXDeveloperOverride` compiles them out of release
  builds; a release build ignores the environment variables.
- **Wording the model sees changed.** A tool's description is sent once; `writeFile` takes `contents`;
  `readImageText` is rated a read. If you evaluated a model against 2.3's tool text, run the eval again.
- **A model-service failure reads in plain words** and names the app's model, and a turn that failed is marked
  unanswered. A tool whose arguments don't fit fails that call, not the turn.
- **Local MCP servers and commands are direct-download builds only.** A sandboxed (Mac App Store) app can't run a
  program: `ExternalPrograms.isSupported` is false there, and `MCPServerPickerView` offers "Local program" only where
  one can run.

## 6. Source changes

None are required, but you may notice these. Every changed signature only gained parameters with defaults:

| Where | Gained |
|---|---|
| `respond`, `streamResponse` | `attachments: [URL] = []` |
| `makeSession(route:…)` | `includePlugins: Bool = true`, `dynamicTools: DynamicTools? = nil` |
| `addServer` | `stayConnected`, `initialTools`, `interactiveSignIn` |
| Calendar `updateEvent` / `deleteEvent` | `atTime` |
| Contacts `addContact`, `updateContact`, `deleteContact` | addresses, `card`, `pinned`, and `add…` parameters |
| `MLXModelProvider.init` | `promptCache: MLXPromptCache = .automatic` |
| `MCPServerPickerView.init` | `toolsMode`, `allowsLocalPrograms`, `detail` |

`makeSession(route:…)` with `includePlugins: true` offers the tools of every plug-in that's on in `lab.tools`.
The catalog starts empty, so an app that adds no plug-in sees no change. `MCPTool` is now an `OriginTaggedTool` and
`MCPResourceContent` is `Equatable`. `docs/api-surface.md` has the full list.

## 7. What's new (opt in when you want it)

- **Dynamic tools** (`makeSession(…, dynamicTools:)`): tools are available, not attached; a picker you supply
  (`SystemToolMatcher`, `DecisionToolMatcher`, `KeywordToolMatcher`, or your own selector) picks the few each message
  needs; a service is contacted only when one of its tools is called. A chat can have hundreds of tools and send a
  local model three. Without `dynamicTools:` your session is static, as in 2.x.
- **Built-in plug-ins** (`lab.tools`): Clock, Weather, Calendar, Reminders, Contacts, Location, Documents (text,
  Markdown, PDF, slide decks, RTF, HTML, Word), Tables, Images (OCR and the on-device model looking at photos),
  Web, and Files over **workspaces** (the user's folders, with access levels).
- **Local programs** in direct-download builds: registered commands and local MCP servers over stdio, under a
  Seatbelt sandbox, with the "External programs" switch.
- **Security you can read:** `lab.audit` (a `SecurityAudit` stream), `ToolCallVerdict` (who decided),
  injection defenses (outside content framed as data, links confirmed, a call copied out of content always asks),
  and [a guide for hosts](security-guide-for-hosts.md).
- **MCP resources and prompts**, paste-a-JSON-setup in the add-server form, per-app OAuth client names.
- **The chat core and views:** `ChatController`, `ConversationStore`, compaction, and Components' Markdown view,
  composer and cards, so a chat app is mostly configuration.
- **A prompt cache you can see:** `promptCacheStatus(for:)`, `MLXPromptCacheStats`, an optional encrypted disk tier.
- **Nemotron 3.5** (from 2.2), **OpenAI's Decisions API and refusals** (2.3) and the `decisionformer` JevDK backend
  (2.4) are all in 3.0.

The [CHANGELOG](../CHANGELOG.md) has every addition by module.

## 8. A checklist

1. Build with `LOCALLM_SDK_VERSION=3.0.0-GA`; fix nothing, expect it to compile.
2. Search for `makeSession(` without `authorizer:`. Give each an authorizer, or `AllowingToolAuthorizer()` where no
   one is there to ask.
3. Find every place a local model first loads. Put `availability`, `validate` and `download` ahead of it, and show
   the size.
4. If you persist or compare `ToolImpact` JSON, accept names. If you match MCP tool names, expect the prefix.
5. If you quit while a reply is streaming, `await MLXModelProvider.stopGenerating()` first.
6. Decide the prompt cache: leave it on, or `promptCache: .off`.
7. If an MCP server returns more than 20,000 characters a result and you need all of it, raise
   `maxModelResultCharacters`.
