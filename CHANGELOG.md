# Changelog — LocalLM Lab SDK

This tracks the **public SDK surface** (`LocalLMLabSDKCore`, `LocalLMLabSDKClaude`,
`LocalLMLabSDKInference`, `LocalLMLabSDKRemote`, `LocalLMLabSDKComponents`) as consumed from
this repo. Dates are release dates. Each version maps to a GitHub Release on
`ancientcomputing/locallm` (tag `v<version>`); the xcframework checksums live on the release,
not here.

**As of `1.0.0-beta.2`, the whole SDK builds for macOS 26** — the model layer works on
macOS 26 with `SystemModelProvider` only; Private Cloud Compute / Claude / open-weight (MLX)
models still need macOS 27. See the `1.0.0-beta.2` notes below and
[`docs/sdk-guide.md`, "Targeting macOS 26 and 27"](docs/sdk-guide.md).

**Compatibility policy from `1.0.0-RC.1` onward:** every release after RC.1 — later release candidates,
`1.0.0` GA, and all 1.x minors — is **source compatible**: code that builds against RC.1 keeps building
unmodified against any of them.
New capability lands as additive surface only: new optional parameters with defaults, new protocol
methods shipped with a default implementation, new cases on the non-frozen enums noted below (build
with `@unknown default`, not an exhaustive `switch`). A change that would require editing working
code just to keep building is a major-version bump, not a minor one. This is a promise about
source, not about binary compatibility — you pin an exact version and rebuild against it; nothing
guarantees an already-built app keeps working if a newer xcframework is dropped in without
recompiling. A breaking change waits for 2.0. (Before RC.1, `1.0.0-beta.N` and earlier, none of this applies; the
beta.4 → RC.1 changes that can break a build are listed under *Changed — breaking (pre-GA)* in the
RC.1 entry, and each entry's own "Beta caveats" apply to the betas.)

## 3.0.0 — GA — 2026-11-09 (binaries re-published 2026-11-14 and 2026-11-15)

A major release. Four things change how an app uses the SDK:

- **Dynamic tools.** Tools are *available*, not *attached*: an app makes plug-ins, MCP servers, commands and
  workspaces available, and a small decider picks the few each message needs. A service is contacted only when one
  of its tools is called. A chat can have hundreds of tools available and send a local model three.
- **A prompt cache on by default** for local (MLX) models, with an optional encrypted disk tier.
- **A gate that is always there.** Every tool call passes through a `ToolCallAuthorizer`. A session built without
  one is now fail-closed, and the SDK ships injection defences, a sandbox for programs and an audit stream.
- **Downloading is its own step.** Loading a model reads only the disk.

3.0 also folds in everything from 2.2.0, 2.3.0 and the unreleased 2.4.0 line (see the last section).

### Changed — breaking

Code that builds against 2.3.0 may need edits for these.

- **A session with no authorizer is fail-closed.** `makeSession(route:…)`'s `authorizer:` still defaults to `nil`,
  but `nil` now means `FailClosedToolAuthorizer`: calls rated `.read` run, and anything that may change data or send
  it out is denied with a result that says so. In 2.3 a session with no authorizer ran every call unasked. For the
  old behavior, say so with `AllowingToolAuthorizer()` (a batch job, an eval); for an app with a UI, pass a
  `ConfirmingToolAuthorizer`. An unrated tool counts as `.mutate`.
- **Loading never downloads.** A session, `capabilityProbe`, `prewarm`, the prompt-cache self-test, a paired speed
  helper or a paired adapter on a repo that isn't downloaded (at its pinned revision, if pinned) fails with
  `.modelUnavailable(reason:)`. Call `download(_:)` first; check `availability`, size and `validate` before you do.
  Because loading no longer touches the network, some things moved from load time to download time:
  - The trust policy applies at download. A downloaded model, helper or adapter keeps loading after the policy
    changes; revoke one with `remove(_:)` or `pairDraftModel(nil, with:)` / `pairAdapter(nil, with:)`. Sessions no
    longer throw `.validation(stage: .trustPolicy, …)`.
  - An unpinned model no longer updates itself on load. It stays at the snapshot `main` named at its last download
    until you call `download` again. Pin a revision (`pinnedRevisions`) to control updates.
  - A file deleted or corrupted inside a downloaded model fails the load; it is not re-fetched. Remove the model and
    download it again.
  - A speed helper that isn't downloaded fails the session instead of running without it.
- **`ToolImpact` encodes as its name.** It is still `Codable`, but writes `"read"`, `"mutate"` or `"destructive"`
  instead of `0`, `1`, `2`. Saved numbers still decode. Code that reads the JSON itself, or compares the integer,
  must read names.
- **MCP tools reach the model under prefixed names**, `<prefix>_<tool>` (`github_list_issues`), with a header on
  each description naming the service. `MCPToolNaming` derives the prefix from the server's domain, package or
  display name; `MCPServerState.toolPrefix` and `setToolPrefix(_:server:)` change it. A tool's own name is kept in
  refs, approvals and records. A host that matched the names the model sees, in tests or in saved transcripts,
  must expect the prefix.
- **Developer overrides are debug-only.** The `LOCALLMLAB_*` environment variables (`MLXDeveloperOverride`) are
  compiled out of release builds.
- **The prompt cache is on by default** for verified model families and for any model that passes its self-test
  (memory only, within a budget sized to the Mac). Turn it off with `promptCache: .off`, or per session with
  `bypassPromptCache`.
- **A reply ends only once its generation has stopped.** Call `MLXModelProvider.stopGenerating()` and wait for it
  before quitting mid-reply.
- **Wording and ratings.** Several built-in tools changed their descriptions, argument names or ratings, which can
  change what a model does with them: `writeFile` takes `contents`; `readImageText` is rated a read; a tool's
  description is sent once; two tools never share a name.

### Added

**Dynamic tools** (`LocalLMLabSDKCore`)
- `DynamicTools`, passed as `makeSession(lab:restoring:dynamicTools:)` or `makeSession(route:…, dynamicTools:)`. It
  needs a picker, with no default: `DynamicTools.matching(_:)` over a `ToolMatcher`, or your own `ToolSelector`;
  `ToolCatalog` (`lab.tools`), `ToolPlugin`, `PluginID`, `PluginPermission`, `CapabilityCard`, `ToolSource`,
  `ToolSummary`, `SelectableTool`, `SelectableSource`, `ToolSelectionRequest`, `ToolSelection`, `ToolSelectors`.
- Picking per message: `ToolMatcher`, `KeywordToolMatcher`, `DecisionToolMatcher`, `ToolMatchingOptions`,
  `ToolScores`; `SystemDecisionProvider` and `SystemToolMatcher` run the picker on the on-device model.
- Per-turn results: `ToolPreparation`, `ToolSelectionExplanation` (with `suggested`, for a held-back server worth
  offering after the reply), `ToolGate`, `PermissionAsking`, `ToolHistory`, `TurnRoomReport`; `updateDynamicTools`,
  `pinTools`, `carryOverTools`, and `DynamicTools.missingToolGuidance` / `heldBackNote` / `toolContext` so the model
  is told what is missing instead of guessing.
- Rules the picker follows: a stricter bar for adding tools mid-conversation; a server must be named before it's
  added; unused guessed tools are dropped after six turns; a tool called earlier and no longer offered answers that
  it's gone; a tool that fails three times is stopped for the turn; one ask per tool per turn.
- `MCPServerSnapshot`: held tools and the user's settings survive a relaunch. `MCPInitialTools`,
  `MCPToolNaming`, `MCPToolLabels`. An MCP server is contacted only when one of its tools is called.
- `LocalLMLabError.isRejectedToolCall`; a rejected or undeclared call is retried once.

**Built-in plug-ins** (`LocalLMLabSDKCore`): `ClockPlugin` (`timeZone`), `WeatherPlugin`, `CalendarPlugin`,
`RemindersPlugin`, `ContactsPlugin` (changes no longer create duplicates; postal addresses), `LocationPlugin` (the
user's current location), `TablesPlugin` (`loadTable` reads CSV, TSV and JSON records), `DocumentsPlugin` (text,
Markdown, PDF with a Vision fallback, slide decks with titles, RTF, HTML and Word `.docx`), `ImagesPlugin`
(`readImageText`: OCR plus Apple's on-device model looking at photos, with layout looks for diagrams, charts and
screenshots), `WebPlugin` (read a page, save it as Markdown, search; links, consent walls and an address policy,
`WebAddressPolicy`), `WorkspacePlugin` and `WorkspacesPlugin` (Files over scratch space and the user's folders; copy,
Trash on delete, kept old versions on overwrite, several edits per call).

**Workspaces** (`LocalLMLabSDKCore`): `Workspace`, `SavedWorkspace`, `SavedWorkspaces`; access levels, off-limits
paths, a default workspace, one workspace per chat, commands that follow the chat's workspace.

**Local programs — direct-download builds only** (`LocalLMLabSDKCore`): `ExternalPrograms` and
`ExternalProgramsSwitch` (off in sandboxed apps), `ProcessCommandRunner` with `SandboxProfile` (Seatbelt, no
network unless allowed), `CommandSpec`, `CommandRunner`, `RegisteredCommand`, `CommandsPlugin`, `CommandRisk`; local
MCP servers over stdio (`MCPStdioLaunch`, `MCPLocalServerStart`). A local server asks before every start (`localServerStartApproval`),
and one that died is started again on the next call, with approval, up to 3 times in 5 minutes.

**Security** (`LocalLMLabSDKCore`): `FailClosedToolAuthorizer`, `AllowingToolAuthorizer`, `ToolCallDecider`,
`ToolCallVerdict` (who decided), `CallImpact`, `CallImpactRatedTool`, `ArgumentCheckedTool`, `OutboundTool`,
`DriftPolicy`, `DriftAction`, `ToolDrift`, `ContentFrame`, `ReplyLinks` / `LinkSource`, and the audit stream
`lab.audit` (`SecurityAudit`, `SecurityEvent`, `SecurityAuditEntry`). Defences: a call copied out of content always
asks; page text a reader can't see is dropped; outside content reaches the model framed as data; control-token text
in content is made inert; links from content are marked and confirmed; a call that would send read content off the
Mac is noted, and the user's trust decides. What the SDK does and what your app must do: `docs/security-guide-for-hosts.md`.

**MCP** (`LocalLMLabSDKCore`, `LocalLMLabSDKComponents`)
- Resources and prompts: `MCPResourceContent`, `MCPContentReader`, `PromptFill`, `MCPCompletionReference`,
  `MCPPromptImage`. The assistant can read a server's shared content when a question needs it; attach shared content
  from the paperclip menu; a `/` menu for the server's prompts, with an argument form and the server's suggestions.
- Tool results can carry images, embedded resources and returned links.
- Paste a server's JSON setup (Claude Desktop `mcpServers`, VS Code `servers`, one entry or a bare `command` and
  `args`) into the add-server form: `MCPServerConfigPaste`, `MCPServerConfigEntry`.
- `MCPServerPickerView` takes `toolsMode` (`.static` or `.dynamic`), `allowsLocalPrograms` and `detail`
  (`ChatToolDetail.plain` or `.detailed`); the Tool Sources sheet has Tools, Content and Prompts sections and
  "Check connection" in place of Reconnect.

**Prompt cache and memory** (`LocalLMLabSDKInference`): `MLXPromptCache`, `MLXPromptCacheStorage`,
`MLXPromptCacheDisk`, `MLXPromptCacheStats`, `MLXPromptCacheModelStatus`, `promptCacheStatus(for:)`,
`MLXMemoryStatus`, `MLXMemoryPressure`, `MLXPromptCapacity`. A memory tier and an encrypted SSD tier (key in the
Keychain, excluded from backups); a saved conversation is segments plus restore points, written once per turn.
Verified families: Qwen3.5/3.8, Qwen3, Qwen3 MoE, Llama, Nemotron 3.5; any other model gets a one-time self-test.
MLX's buffer cache is capped, prompts too big for memory are read in smaller pieces before being refused, and the
cache gives memory back before it would cause a refusal. `MLXModelProvider.stopGenerating()`;
`MLXPromptCacheDisk.clear()` and `storedBytes`; `RejectedToolCallDiagnostics`.

**Chat core and views** (`LocalLMLabSDKCore`, `LocalLMLabSDKComponents`): `ChatController`, `ChatCard`,
`ChatConfiguration` (`turnFinished`, `turnFailed`), `ChatSetup`, `ChatPlugins`, `ChatCompaction`, `ChatStatus`,
`ComposerIntent`, `ConversationStore`, `ChatAttachments`; Components' `MarkdownView`, `ChatComposerBanner`,
`ChatCardView`, `ToolChoiceChip`, permission, sign-in, clarify and server-suggestion cards,
`WorkspaceSettingsRow`, `ModelOnboardingView(showsCancel:)`. A chat compacts into a summary the model writes when it
fills up; an unknown context window gets an assumed room.

**MCP Apps** (`LocalLMLabSDKMCPAppsHost`): `MCPAppWidgetSlot`, `MCPAppWidgetContext`, `MCPAppsInlinePolicy`,
`MCPAppsOfflineBackend`. A changed widget is a new instance, so remembered answers don't carry over to code the user
hasn't seen.

**Remote providers** (`LocalLMLabSDKRemote`): Anthropic requests default to a 64K output limit and a cut-off tool
call fails with that reason; tool input is sent whole and a call with no arguments sends `{}`; every tool schema is
sent as an object.

**Examples and tools:** `examples/chatbot` (ChatAgain), `examples/mlx-cache-lab`, `examples/tool-matcher-eval`,
`qualify/` (the pre-release harness: scenarios, a soak run, robustness and leak checks) and
`scripts/chat-cache-replay`.

### Changed

- Additive signatures (source-compatible): `respond` and `streamResponse` take `attachments: [URL] = []`;
  `addServer` takes `stayConnected`, `initialTools` and `interactiveSignIn`; Calendar `updateEvent` and `deleteEvent`
  take `atTime`; Contacts `addContact`, `updateContact` and `deleteContact` take addresses, `card` and `pinned`.
  `MCPTool` is an `OriginTaggedTool`; `MCPResourceContent` is `Equatable`.
- **LFM3 models load** (`lfm3`). `LocalLMLabSDKInference`'s MLX runtime pin moves from `dea880a` to `cf22d79`:
  `dea880a` plus upstream mlx-swift-lm's LFM3 support (#750) and nothing else. Before, `LiquidAI/LFM3-*` failed with
  "Unsupported model type: lfm3". `LFM3-1.7B-MLX-bf16` passes `capabilityProbe` (prompt, tool call, reasoning off);
  it has no prompt cache, because it has sliding-window layers.
- **PrismML Bonsai 2 loads** (`prism_hadamard_qwen35`). The pin moves on to `82c3ce3`, which adds upstream
  mlx-swift-lm PR #630 (not merged upstream yet): Qwen3.8-27B with ternary weights stored as MLX 2-bit in a
  Hadamard-rotated basis, with the activations rotated using stock MLX ops. `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`
  (8.6 GB) passes `capabilityProbe` and the prompt-cache self-test. Text only.
- Apple's model-service failures read in plain words, name the app's model, and a failed turn is marked unanswered.
- **Tools named in a chat's custom instructions are offered** (binaries re-published 2026-11-14).
  `ToolSelectionRequest.standingInstructions`, set from `LocalLMLabSession` and `ChatSetup.standingInstructions`, is
  what the user asks for on every message. An MCP server named there is offered on every message, whole up to
  `ToolMatchingOptions.wholeNamedServerLimit` (12) tools (`offersServersNamedInInstructions`, on by default), with
  the new reason `ToolSelectionExplanation.Reason.namedInInstructions`; a `switch` over `Reason` needs
  `@unknown default`. A reply saying a tool is missing, when the model didn't call `requestTools`, makes the session
  ask for it and run the turn again with what it finds (once a turn, with `requestsTools` on).
- **Saved workspaces stay available after a restart** (binaries re-published 2026-11-14). A workspace's identity is
  its volume's UUID and inode; it was the device number, which macOS assigns at each mount, so after a restart every
  saved workspace was refused. A list saved before matches by inode and is rewritten.
  `SavedWorkspace.sameFolder(saved:now:)` compares two identities.
- **Examples say how tool calls are decided.** Every example whose tools write, or call an MCP server's tools,
  passes an authorizer, since a 3.0 session without one refuses those calls: `AllowingToolAuthorizer()` in
  `code-buddy`, `repo-qa-local` and `aiql`; a `ConfirmingToolAuthorizer` in `workspace-buddy-local` (an alert before
  writes and edits), `security-demo`, `mcp-chat` and `vistanova` (a policy that allows only `tavily_search`). The
  [annotated examples](docs/annotated-examples.md) list them. JevDK and jev-serve are their own project
  ([ancientcomputing/jevdk](https://github.com/ancientcomputing/jevdk)); their folders here point to it.
- `JevWire`'s response extensions are `fidelity` (`native`, `tokenScored`, `generated`), `calibrated`, and a refusal
  marker `{"type":"refusal"}`.

### Folded in from 2.2.0, 2.3.0 and the 2.4.0 line

- **2.2.0:** Nemotron 3.5 support, with `mlx-swift-lm` pinned at `dea880a`; balanced primed `<think>` tags.
- **2.3.0:** OpenAI's Decisions API as a fourth decider, with refusals in `Decision` (see the 2.3.0 entry below).
- **2.4.0 (never released on its own):** the `decisionformer` backend in JevDK; each app registers its OAuth client
  under its own name, with a redirect form check; a sign-in reply on this Mac when a server refuses the app's
  scheme; reverse-domain redirect schemes.

### Checksums (SHA-256)

```
LocalLMLabSDKCore-3.0.0-GA.xcframework.zip       c4b84b270e2a7131ce438ebdec6fca6488fc68800ea900f8b0b344799750fa07
LocalLMLabSDKClaude-3.0.0-GA.xcframework.zip     073847b37116b991d66ce25b545efd074c98eb5c37a33a00b4c31ce7fe300788
LocalLMLabSDKInference-3.0.0-GA.xcframework.zip  f4c937ac18db0a67c1c5467f06c5aa674b1f34801f73fc7fa1c628ac206713d6
LocalLMLabSDKRemote-3.0.0-GA.xcframework.zip     c617f8120f0c94e4be3f620ce1f093f9bf9326f93f94a44467d1a928136d4fb7
```

---

## 2.3.0 — GA — 2026-10-27

OpenAI's Decisions API as a fourth decider, and refusals in `Decision`. Additive only: code that
builds against 2.2.0 builds unchanged, and `LocalLMLabSDKInference` and `LocalLMLabSDKClaude` have
no source changes.

### Added

- **OpenAI Decisions in `LocalLMLabSDKRemote`.** `JevDecisionProvider` now speaks OpenAI's
  `/v1/decisions` as well as Jev's wire format, chosen by `JevProviderConfig`'s new `wire`
  (`DecisionWireFormat`: `.jev`, `.openAIDecisions`). The `.openAI(key:)` preset registers
  `openai:gpt-6-luna` (fidelity `.native`). `.openAICompatibleDecisions(baseURL:auth:models:…)` is for
  any other server that speaks the same API, such as Fireworks, Vercel AI Gateway or LocalAI. For a
  server that token-scores a general model, pass `fidelity: .tokenScored(calibrated: false)`.
  `probe(for:timeout:)` checks the key and model with `GET /v1/models`.
- **`OpenAIDecisionWire` in `LocalLMLabSDKCore`**, the codec for both directions, with OpenAI's
  input limits (`DecisionLimits.openAIDecisions`) checked before anything is sent.
- **Refusals.** A backend can now decline a question: `Decision.refusals` lists the refused ids, and
  `isRefused(_:)` checks one. A refused id has no entry in `answers`. Only OpenAI's Decisions API
  refuses today; every other backend leaves `refusals` empty. `lab.decide` accepts a decision in
  which each question is either answered or refused. `lab.evaluate` counts a refusal as a miss
  (`QuestionScore.refused`) that adds no calibration sample. The Jev wire carries refusals as
  `{"type":"refusal"}`.

### Changed

- **`Decision`'s JSON** gains `refusals`. JSON written by 2.2 and earlier still decodes, and a
  decision without refusals encodes exactly as it did before. The new `Decision` and
  `JevProviderConfig` initializers are overloads, not added defaulted parameters, so the existing
  initializers are unchanged.

### Checksums (SHA-256)

```
LocalLMLabSDKCore-2.3.0-GA.xcframework.zip       7821197d0cf5b4c92e36af5c537295e594afbb55d60d2f98b0773a3625403575
LocalLMLabSDKClaude-2.3.0-GA.xcframework.zip     80e143412d0bd0538091b59ea050015d28828855809203ea51c1cd49675e8449
LocalLMLabSDKInference-2.3.0-GA.xcframework.zip  63dc8bcba5e91e1324809ca412a23ebb0b9e04386361436eacc0be9fe6d4a8e0
LocalLMLabSDKRemote-2.3.0-GA.xcframework.zip     dae65d45bea196f6cd2538328fad1a0e33eceae5fac5ee965183706ac942daaf
```

---

## 2.2.0 — GA — 2026-10-22

Nemotron 3.5 support in `LocalLMLabSDKInference`; no API change (the public surface is identical to
2.1.0's).

### Added

- **Nemotron 3.5 runs locally.** The MLX runtime reads Nemotron 3.5's configuration
  (`layers_block_type` / `block_configs` instead of a `hybrid_override_pattern` string), adds its latent
  MoE layers, registers `nemotron_h_puzzle` (the Bolt models), and skips the multi-token-prediction
  weights it doesn't use. Before, `NVIDIA-Nemotron-3.5-Lightning-30B-A3B` failed to load. Tested with
  tools, including the GitHub MCP server:
  - `mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit` and `-8bit`
  - `rapid-mlx/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-MLX-3bit`
  - `rapid-mlx/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-MLX-3bit` (text only, despite the name)

  Bolt builds that take images (`nemotron_h_omni`, `nemotron_h_nano_omni`) still don't load, and
  neither does a conversion with per-layer quantization settings (`hermitdave/…-mixed36`).

### Fixed

- **`SessionOptions(effort: .off)` turns Nemotron's thinking off.** Before, Nemotron ignored it and
  always reasoned. The model now declares its reasoning toggle (`enable_thinking`), so
  `ModelCapabilities.reasoningToggle` reports it too.
- **A reply from a model whose prompt opens `<think>` now has a balanced reasoning block.** Nemotron
  3.5's and Qwen3.5's chat templates open `<think>` in the prompt, so the model's reply streamed only
  `…</think>answer`, and the reasoning landed in the answer. The SDK now detects this on each model
  call from the end of the rendered prompt and restores the opening `<think>`, so `hostTranscript`
  splits the reasoning from the reply with no model-specific handling. A tool call made while that
  block is still open gets a `</think>` first. Tool-call parsing is unchanged.

### Changed

- **`LocalLMLabSDKInference`'s MLX runtime pin moves from `30d755c` to `dea880a`**: 2.1.0's runtime plus
  two Nemotron 3.5 commits of ours, on the `nemotron-3.5-support` branch of our mirror fork,
  `ancientcomputing/mlx-swift-lm`. Nothing else in the runtime changes.

### Known issues

- **Qwen3.5-9B's tool calls are often rejected as malformed.** This predates 2.2.0.
- **Nemotron 3.5 can run a tool call it writes inside its reasoning.** Seen only when the prompt asks
  for call markup while thinking.

### Checksums (SHA-256)

```
LocalLMLabSDKCore-2.2.0-GA.xcframework.zip       5efc40cae9f8a1bf53bfe03195c5365398bc9501b3e6b0feee3e5c67385537f4
LocalLMLabSDKClaude-2.2.0-GA.xcframework.zip     07e2ff01accf582f71fecab254bdae2e8fb46acc8296ef6ab1c8d84cd9e97a04
LocalLMLabSDKInference-2.2.0-GA.xcframework.zip  afd427fb741a820f55bc0a384850ae6404608f5ad73d185a583a89e8f0d61a61
LocalLMLabSDKRemote-2.2.0-GA.xcframework.zip     1c9af025c700bc0c41c80387c1d6a59ba2f2ab6203eb8ffd8548d61c6ac1fe38
```

---

## 2.1.0 — GA — 2026-10-15

Fixes and a newer MLX runtime; no API change (the public surface is identical to 2.0.0's).

### Fixed

- **An app embedding `LocalLMLabSDKInference` was rejected by App Store Connect** (error 90277: not a
  valid bundle identifier). The framework's bundle ID was `mlx-swift_Cmlx`, and bundle IDs can't contain
  underscores. It is now `lab.locallm.sdk.inference`, like Core's `lab.locallm.sdk.core`. MLX still finds
  its Metal library: it loads `Resources/default.metallib` next to the framework's own binary, in a
  `swift build` executable and in an app Xcode embeds it in alike. An app that copied
  `mlx-swift_Cmlx.bundle` into its own Resources to work around this can stop doing so.
- **Downloading a model whose Hugging Face repo has a subfolder failed** within seconds with
  "Could not fetch metadata for 'optiq'": the downloader treated the folder itself as a file. This hit
  every mlx-community OptiQ conversion (e.g. `gemma-4-12B-it-OptiQ-4bit`). Folders are now skipped and
  the files inside them are downloaded, so the snapshot matches the repo.
- **More MLX models can use tools.** Before each render, the SDK now fits the conversation to what
  the model's chat template can actually show. It decides from the template and the vocabulary, not
  from the model's name.
  - **GLM-4-0414** (`GLM-4-9B-0414`, `GLM-4-32B-0414`) never saw a tool's result. Its template shows
    results only under the `observation` role. The model kept repeating the same call (`echo` 3–4
    times, `hub_repo_details` 4–5 times) and then answered without the result. Results now reach it,
    and it answers from them.
  - **Llama 3.1** failed a turn that made more than one tool call, with `Jinja.TemplateException`.
    Its template allows only one call per assistant message. Such a turn is now replayed one call at a
    time, each followed by its result. Llama 3.2 had the same problem.
  - **Mistral-Small-3.2-24B-Instruct-2506** (mlx-community 4-bit and 8-bit) never called a tool. Its
    conversions ship no chat template that renders tools, so when tools are requested the SDK now
    uses a built-in one in Mistral's own format. The 4-bit passes all four of our tool tests; the
    8-bit passes three and partly answers the fourth.
  - When a model ships two chat templates and tools are requested, the one that renders tools is
    used. Before, `chat_template.jinja` always won, even when only `tokenizer_config.json`'s template
    supported tools.
- **Adding a model could hang in its capability check.** `MLXModelProvider.capabilityProbe` now caps
  each check's output length and stops any check that runs over 3 minutes. A check that times out is
  listed in the report's `notes` and doesn't set `blocked`, so the model still gets added. Before,
  adding `Mistral-Small-3.2-24B-Instruct-2506-8bit` was still generating after 30 minutes.

### Changed

- **`LocalLMLabSDKInference`'s MLX runtime moves to current `mlx-swift-lm`.** The pin goes from
  `45693f6` (2026-07-27) to `30d755c`: upstream `8ec6a2c` (2026-10-15) plus one fix of ours, below.
  `mlx-swift` goes from 0.31.6 to 0.32.3. It's still served from our mirror fork,
  `ancientcomputing/mlx-swift-lm`. The update fixes several tool-call problems:
  - **Gemma 4** keeps array and object arguments intact. Before, a call such as `hub_repo_details`
    with a `repo_ids` list reached the tool garbled with `<|"|>` tokens.
  - **gpt-oss** tool calls work. The runtime now parses OpenAI's Harmony format; before, the call
    came back as raw text.
  - **Muse Glimmer** (`muse_glimmer`, with its ATEM tool-call format) loads and calls tools. Checked
    with `mlx-community/Muse-Glimmer-30B-4bit`.
  - **Older Mistral checkpoints** (`model_type` `mistral`) now get Mistral's tool-call parser, chosen
    from their chat template. Mistral 7B v0.3 still can't call tools: it writes the older
    `[TOOL_CALLS] [{…}]` list form, and the parser rejects it.
  - **Qwen3 calls that open a `<think>` block run.** Qwen3 sometimes opens `<think>` and goes straight
    to the call without closing the block. Upstream treats everything in a reasoning block as inert,
    so the call came back as text and never ran. A `<think>` block whose first content is a tool call
    and that never closes now dispatches the call. A call after any reasoning text, or inside a closed
    block, stays inert.
- **A malformed tool call now fails the turn instead of showing up as text.** This covers an
  unparseable payload, a call to a tool the session doesn't declare, and arguments that break the
  tool's schema. The error is `LocalLMLabError.generation(underlying:)`, and its message names the reason (for
  example `malformed_syntax`). The raw model output is never included. Before, the raw call markup came back as the model's answer, and nothing ran.
  Generation finishes before the error is thrown, so nothing keeps running on the GPU after the turn
  fails (a command-line tool that exited on the error could otherwise crash).

### Checksums (SHA-256)

```
LocalLMLabSDKCore-2.1.0-GA.xcframework.zip       8d541e06f81d1586c959d6159a259c759853c88b2c68385ab28de493af6c5776
LocalLMLabSDKClaude-2.1.0-GA.xcframework.zip     f54472c25063f7c6d6d5a49a91992beb1300d9b6d986ee83d41e682ac2a2c172
LocalLMLabSDKInference-2.1.0-GA.xcframework.zip  77d3d1a1bae9df6de5955dfa945242c177cb129b4896c95befb81db6c923656f
LocalLMLabSDKRemote-2.1.0-GA.xcframework.zip     347257172a6da7104b7081602e9dbfc853ed5d038b5e30831aad8dfa2753ae92
```

---

## 2.0.0 — GA — 2026-10-07 (binaries re-published 2026-10-08 and 2026-10-09)

**A one-time breaking release.** From `2.0.0`, every 2.x release is source compatible with it
(additive changes only, the same policy 1.x followed). Upgrading: [`docs/migrating-to-2.0.md`](docs/migrating-to-2.0.md).

### Changed — breaking

- **Tool authorization is decided per MCP server, by one authorizer.** `RuleBasedToolAuthorizer`
  is removed; so are `ConfirmingToolAuthorizer.Requirement` and
  `init(channel:timeout:requirement:)` — use `init(channel:policy:hostTools:timeout:)` with a
  `ToolPolicy`. `MCPServerManager.setTrustsToolAnnotations(_:server:)` /
  `trustsToolAnnotations(server:)` are replaced by `setTrust(_:server:)`. Mappings in the
  migration guide §3.
- **`WorkspaceAccess` operations are `async throws`** (`listFiles`, `readFile`, `writeFile`,
  `editFile`, `deleteFile`, `search`, `tree`, `readFileRange`, `applyPatch`), not
  `Result`-returning; they throw `WorkspaceError` or `CancellationError`. `search` returns
  `SearchResult` (read `.matches`). The ready-made workspace tools are unchanged at the call site.
  Migration guide §4a.
- **New cases** on `MCPProtocolVersion` (`.v2026_07_28`) and `MCPConnectionMode`
  (`.stateless(_:)`); a `switch` needs `@unknown default` (Swift 6 already requires it).
- **`MCPServerState`** gained fields (`trust`, `toolApproval`, `trustedToolsDigest`,
  `liveUpdates`, …): a state JSON encoded under 1.0 no longer decodes. Restore servers with
  `restore(from:)`.
- **Defaulted parameters added**: `SessionOptions.init` and `MLXModelProvider.init` gain
  `maxModelCallsPerTurn:`; `LocalLMLabState.init` gains `decisionRoutes:` (usual call sites
  compile unchanged; snapshots saved by 1.0 still decode, with no decision routes).
- **One declaration each** where 1.x had kept two (usual call sites compile unchanged):
  `makeSession` (now with `restoring:` and `mcpAppHints:`), `respond` / `streamResponse` (with
  `options:` and `fromAppInstance:`), `LocalLMLab.Configuration.init` (with `mcp: MCPSettings`),
  `PendingToolCall` / `PendingToolCallSummary` initializers (with `initiator:` and
  `serverApproval:`).

### Changed — behavior

- A session's MCP tools follow `lab.mcp` between turns (1.0: fixed at `makeSession`). For a fixed
  set, pass the tools in `tools:` with `includeMCPTools: false`.
- A trusted server asks only before destructive tools by default (1.0 asked before every change).
- MCP tools marked app-only (`_meta.ui.visibility` without `"model"`) are no longer given to
  models; `ui://` resources are left out of model-facing resource lists.
- `languageModelSession` is documented as the escape hatch: run turns with `respond` /
  `streamResponse`.
- **Workspace file access is hardened.** Files are reached by descriptor from the granted folder
  and no symlink is followed out of it — including mid-operation (1.x `search` followed a symlink
  inside the folder to a file outside it). Reads, searches and edits are bounded by
  `WorkspaceLimits` and stream instead of loading whole files; `search` reports files it skipped.
  `deleteFile` removes single files only (1.x deleted folders recursively) and deletes a symlink
  itself, not its target. `editFile` keeps file permissions. Writes are temp-then-rename.
- **`FileBackedTool` `saveAs` writes under `raw/` by default**, data-file extensions only, no
  hidden paths (`SaveAsPolicy`; `.unrestricted` restores 1.x). The receipt gives the real path.
- **Local (MLX) models report real usage**: input and output token counts are the model's own (input was always
  0). `languageModelSession.usage` sums every model call in the session; one turn's figures are on its response's
  `usage`, with `mlx.*` metadata (`MLXUsageMetadataKey`).
- **An MLX turn stops after 16 model calls** — a model that keeps calling tools without answering — with an error
  saying so. Raise or remove the limit with `MLXModelProvider(maxModelCallsPerTurn:)` or
  `SessionOptions.maxModelCallsPerTurn` (`Int.max` = no limit).
- **An MLX prompt too long for the model's context window, or for the GPU memory left, is refused before it runs**
  (`LocalLMLabError.context`). `respond` / `streamResponse` treat it as a context overflow, so
  `retryOnContextOverflow` compacts and retries.

- MCP servers that only speak `2024-11-05`, or use the old HTTP+SSE transport, fail `addServer`
  with `.protocolMismatch` (1.x connected to the former and failed on the latter with "HTTP 404").
  `MCPProtocolVersion.v2024_11_05` is deprecated and kept so stored values decode.
- Each connect first probes `server/discover` (`versionNegotiation: .auto`, the default) and falls
  back to `initialize` when a server rejects it. `.legacy` skips the probe.
- Elicitation is declared as `{"form":{},"url":{}}` from `2025-11-25` (was `{}`, which strict
  servers read as form-only).
- `MCP-Protocol-Version` is sent only when the negotiated revision is `2025-06-18` or later, and
  an inbound `elicitation/create` is refused below `2025-06-18`.

### Added — building a chat app (`LocalLMLabSDKCore`)

- `LocalLMLabSession.hostTranscript` (`HostTranscript`): the conversation as a UI shows it — the
  user's message at turn start, tool calls as live `ToolCallRecord`s with their full MCP result
  and app link, the reply and the model's reasoning (an inline `<think>` block is split out), in
  model order, never shortened by compaction; `replyInProgress` while streaming;
  `archive()` / `restore(from:)`; a memory budget with spill to disk.
- `streamResponse(to:options:fromAppInstance:)`; `turnContext` (host text sent with every turn,
  e.g. the date); `makeSession(…, restoring:)` to continue a saved conversation.
- `LocalLMLab.Configuration.mcp: MCPSettings` — how the lab sets up `lab.mcp`, the one MCP
  manager.

### Added — MCP Apps (`LocalLMLabSDKMCPAppsHost`, new, open source)

- Shows an MCP server's interactive view (`ui://`, MCP Apps) when the model calls its tool:
  `MCPAppViewController` / `MCPAppView` (sandboxed `WKWebView`), the host↔view bridge with an
  explicit policy, `MCPAppsSessionBackend` (a view's tool calls go through the session's
  authorizer, `ToolCallInitiator.app`), `MCPAppWidgetCache`, `MCPAppViewPool`,
  `MCPAppRecreation`; `MCPClientHandlers.advertisingMCPApps()`.
- Core MCP client: `_meta` on tool, resource and result types (`MCPToolDescriptor.meta`,
  `MCPResourceDescriptor.meta`, `MCPToolResult.meta`), `MCPToolAnnotations`, and
  `MCPResponseLimits.maxUIResourceBytes` (cap on a view's HTML, default 4 MB).
- Core: `MCPAppLink`, `MCPAppVisibility`, `MCPToolDescriptor.app`, `isMCPAppResource`;
  `LocalLMLabSession.callMCPTool(server:tool:arguments:initiator:)`,
  `updateModelContext(_:fromAppInstance:)`; `makeSession(…, mcpAppHints:)`.
- `ConfirmingToolAuthorizer` remembers a view's answer per tool (a polling dashboard asks once).

### Added — per-server trust and tool approval

- `MCPServerTrust`, `ToolApproval` (+ `default(for:)`), `ToolApprover`, `ToolPolicy`,
  `ToolPolicyDecision`; `MCPServerManager.setTrust(_:server:)`, `setToolApproval(_:server:)`,
  `toolApproval(server:)`; `MCPServerState.trust` / `toolApproval` / `toolsChangedSinceTrusted`.
- `Components`: `MCPServerPickerView` shows each server's trust and approval, a notice when none of
  a server's tools are on, and one when a trusted server's tools changed; the auth type is chosen
  with a radio group.

### Added — MCP protocol `2026-07-28`

- The MCP client speaks `2026-07-28`, the current revision, and negotiates down to `2025-03-26`
  (`MCPProtocolVersion.v2026_07_28`, `.statelessPreferred`, `.minimumSupported`, `.isStateless`).
- **Stateless mode** (`MCPConnectionMode.stateless(_:)`): `server/discover` instead of
  `initialize`, no session, the per-request `_meta` envelope, and `Mcp-Method` / `Mcp-Name` /
  `Mcp-Param-*` headers. A tool whose `x-mcp-header` declarations break the rules (including one
  on a `number` parameter; only `string` / `integer` / `boolean` are allowed) is left out.
- **`MCPVersionNegotiation`** (`.auto` / `.legacy` / `.pin(_:)`), set with
  `MCPSettings(versionNegotiation:)` or `MCPServerManager(versionNegotiation:)`.
- **Multi-round-trip requests (MRTR).** A request that comes back `input_required` is answered
  through the existing `MCPClientHandlers` (elicitation in form or URL mode, sampling, roots) and
  re-sent with the answers, for up to 8 rounds. No handler API changes. A user's Cancel ends the
  call without re-sending; after a Decline, a server that asks again is declined without
  prompting the user a second time. Both come back as a `tools/call` tool error
  (`isError`) the model can read, not a transport failure.
- **Live updates** (`subscriptions/listen`). One stream per stateless server that announces list
  changes; tools, prompts and resources are re-listed on change with enabled flags kept.
  `MCPServerState.liveUpdates: MCPLiveUpdates?` (`.active` / `.reconnecting` / `.unavailable`).
  Opt out with `MCPSettings(liveUpdates: false)` or `MCPServerManager(liveUpdates: false)`. Custom
  transports: `MCPConnection.listen(filter:)` with `MCPSubscriptionFilter`, `MCPChangeEvent`,
  `MCPListenEnd` (default implementation ends as refused).
- `MCPProtocolVersion.supportsURLElicitation` and `.sendsProtocolVersionHeader` feature gates.
- Diagnostics: the `server/discover` probe and fallback, live-update status, and MRTR rounds
  (new category `MCP.mrtr`) are logged ([`docs/mcp-diagnostics.md`](docs/mcp-diagnostics.md)).
- Authorization fixes found by the official MCP conformance suite: protected-resource metadata
  at the path-suffixed then root well-known URL; `resource` must cover the server URL and is sent
  exactly as the metadata publishes it (RFC 8707); metadata
  `issuer` and redirect `iss` are checked (RFC 8414, RFC 9207); a changed authorization server
  mid-connection drops the old credentials and signs in again.

### Added — local (MLX) models: usage, speed and memory per turn (`LocalLMLabSDKInference`)

- **`MLXUsageMetadataKey`**: real prompt and generated token counts, prompt (pp) and generation (tg) speed,
  seconds, model calls, stop reason, speculative-decoding draft stats, and MLX memory (resident, turn peak, GPU
  limit) — turn totals on the response's `usage.metadata`.
- **`MLXPrefillMonitor` / `MLXPrefillActivity`**: the prompt a local model is reading right now — exact tokens,
  which model call of the turn, since when — so an app can say why nothing has appeared yet.
- **`maxModelCallsPerTurn`** on `MLXModelProvider` and `SessionOptions`: the tool-loop limit, 16 by default.

### Added — decision models (Jev)

A **decision model** answers a few typed questions about one input — yes / no, one of several
options, a point on a scale — with a probability for every option, and writes no text. One API
asks them of TypeSafe's Jev, Featherless's Simple Jev, or **OpenJev**, the SDK's own decider on a
local MLX model. Introduction: [Decision models (Jev) in your app](https://thisbrain.ai/locallm/jev.html);
API: [`docs/decision-models.md`, "Decision models"](docs/decision-models.md).

- **Core:** `LocalLMLab.decide(route:state:questions:)`; questions in Jev's vocabulary
  (`DecisionQuestion.noul` / `.choice` / `.score`, `DecisionState`, `DecisionRequest`,
  `DecisionLimits` incl. `maxStateCharacters`); answers (`Decision`, `DecisionAnswer`,
  `ChoiceAnswer`, `ScoreAnswer`, `DecisionFidelity`, `DecisionUsage`); `DecisionError`;
  `DecisionProvider` for custom backends. Decision routes and providers are separate from chat:
  `ModelRegistry.register(decision:)`, `replace(decision:)`, `removeDecisionProvider(scheme:)`,
  `route(decision:to:)`, `modelID(forDecision:)`, `decisionProvider(for:)`,
  `decisionAvailability(for:)`; saved by `lab.snapshot()`.
- **A decider next to your chat model:** `ModelRegistry.pair(decision:generator:)` checks both
  models fit the memory budget and keeps them loaded together (or shares one model);
  `DecisionPairing`, `PairableDecisionProvider`, `DecisionError.pairing`.
- **From testing to shipping:** `DecisionQuestionSet` (the tested questions as a JSON file, with
  the model, revision, wrapper and calibration they were tested with); `DecisionAnswerSet`
  (inputs with the correct answers, as CSV); `LocalLMLab.evaluate(route:questions:answerSet:)`
  → `DecisionEvaluation` (accuracy per question, misses, confidence when right and wrong) for
  regression tests in CI; `DecisionCalibration` (temperature scaling per question kind: `fit`,
  `measure`, `apply`).
- **`JevWire`** (Core): hosted Jev's JSON both ways (requests and responses, order kept), for
  serving decisions over HTTP as well as calling hosted Jev; `JevDecisionProvider` is built on it.
- **`LocalLMLabSDKInference` (macOS 27):** `OpenJevDecisionProvider` — answers each question in
  one forward pass over the allowed labels' probabilities, no generation, the input read once for
  all questions (about 150 ms for four questions on Qwen3 4B). `OpenJevWrapper` (+ `.default`),
  `calibration:`, `init(mlx:tunedWith:)`, `tuningMismatch(for:)`, `warnings(for:)`
  (`OpenJevWarning.mixtureOfExperts`: use a dense model as the decider),
  `decideWithDiagnostics(_:using:)` (`OpenJevDiagnostics`: exact prompts, label mass, timing).
- **`LocalLMLabSDKRemote`:** `JevDecisionProvider` with `JevProviderConfig.openRouter(key:)`
  (TypeSafe's Jev via OpenRouter), `.featherless(key:)` and `.featherlessDemo()` (no key,
  rate-limited); `validated()`, `requestBody(model:request:)`. Off until registered; the
  questions and input are then sent to that service.

### Fixed

- **`contextBudget`** reported the whole session's cumulative usage as the last turn's, so `fractionUsed` grew
  every turn. It now reports the latest turn's last model call (the conversation as the model last read it).
- **`loadTable` let a model guess `recordsAt` until the tool-loop limit stopped it** (`LocalLMLabSDKCore`).
  A `recordsAt` that isn't an array in the JSON was an error that didn't say which path would work, so a
  small model guessed again (`"data"`, `"data.items"`, …). 2.0's 16-call limit on a local model's turn
  then stopped about half the runs of the [`aiql`](examples/aiql/) walkthrough; without the limit (1.0)
  they succeeded after 10–42 calls. `loadTable` now falls back to auto-detection when `recordsAt` misses
  and says so in its reply; when that's ambiguous the error lists the candidate arrays. The walkthrough
  now takes three model calls.
- **A streamed Anthropic Messages turn crashed the process** (`LocalLMLabSDKRemote`, `.anthropicMessages`).
  Anthropic reports input tokens at the start of a reply and output tokens at the end; the second usage
  update sent input as 0, and FoundationModels traps when a streamed turn's input count goes down — so
  the process stopped right after the reply's text. A non-streamed turn didn't crash but reported 0 input
  tokens. Input is now carried forward. The OpenAI dialects weren't affected. Also present in 1.0.0.

### Added — examples

- [`jev-serve`](https://github.com/ancientcomputing/jevdk): hosted Jev's HTTP API (`/api/alpha/decisions`,
  `/v1/classifier`) answered by OpenJev on this Mac, from a config JevDK exports (**File → Export
  Server Config…**: the model pinned to its tested version, the system instructions, the
  calibration, an optional token). Downloads the model if needed; loopback by default.
- [`jevdk`](https://github.com/ancientcomputing/jevdk): JevDK, a playground for decision-model questions — run them on a
  local MLX model and on hosted Jev side by side, score a batch against your marked answers,
  calibrate, compare models in a results CSV, and export the tested questions for your app. With a
  plain-English [developer's guide](https://github.com/ancientcomputing/jevdk) ([on the web](https://thisbrain.ai/locallm/jdk-guide.html)).
- [`mcp-chat`](examples/mcp-chat/): a chat with a local model (Qwen3 8B via MLX, or Apple's
  on-device model) that shows MCP Apps views inline, with streaming, per-server trust and
  approval, the date every turn, and conversations that reopen.

### Checksums (SHA-256)

```
LocalLMLabSDKCore-2.0.0-GA.xcframework.zip       5f9418a6879b22227afdf867cf474d426b93ae36d783d5a958efaae1e347681b
LocalLMLabSDKClaude-2.0.0-GA.xcframework.zip     f235480fd4842e91c0c17b416eb4048b7abe6b3c2d41f332984c5e7af368092e
LocalLMLabSDKInference-2.0.0-GA.xcframework.zip  d2ed4a02686aceab0edf4231ede55c924ea3ab273c7c5cab0bb02f4bda40a185
LocalLMLabSDKRemote-2.0.0-GA.xcframework.zip     1e809cff19a7d232cd82fd36eb3ba7d79a93b55f71b6694041c9d9e3f6261be9
```

---

## 1.0.0 — GA — 2026-09-27

Fixes only; no API change.

### Fixed

- **Preflight rejected models that fit in memory** (`MLXModelProvider.validate(_:)`, stages
  `sizeVsMemory` and `diskSpace`). The download size came from the Hub's repo-level `usedStorage`, which
  counts blobs from every revision, so a re-uploaded repo reported about twice its real size —
  `mlx-community/Qwen3.8-27B-8bit` read as 58.1 GB against 29.5 GB of actual files and failed on a 64 GB
  Mac. The SDK now sums the current revision's file sizes and uses `usedStorage` only when no file reports
  a size. `PreflightResult.weightBytes` reports the corrected figure, and the free-disk requirement drops
  with it.

## 1.0.0-RC.1 — 2026-09-15 (binaries re-published 2026-09-18 and 2026-09-19)

Everything below is in `LocalLMLabSDKInference` unless noted (the 2026-09-19 re-publish also adds the
`LocalLMLabSDKCore` items under *Added — sampling options on Apple's on-device model*); apart from
*Changed — breaking (pre-GA)*, all of it is additive. **RC.1 is the source-compatibility baseline:** from
here to GA, changes are additive or fixes only. The narrative is
[`docs/sdk-guide.md`, "The model layer"](docs/local-models-mlx.md#mlxmodelprovider--run-open-weight-models-locally-locallmlabsdkinference)
and [Pinning, updating and cleaning up model versions](docs/local-models-mlx.md#pinning-updating-and-cleaning-up-model-versions).
`docs/api-surface.md` is regenerated for this release; the lines in its diff against beta.4 that can
break a build are the ones under *Changed — breaking (pre-GA)*.

### Added — supply-chain hardening for models downloaded at runtime

- **`MLXSupplyChainPolicy`** (`MLXModelProvider(supplyChainPolicy:)`): a host-supplied
  **`MLXModelTrustPolicy`** checked before any network call, **content-hash verification** of every
  downloaded file (on by default), and an **`MLXCacheLimits`** cap over the whole cache directory.
- **Preflight** stages: `trustPolicy`, `repoReachable`, `mlxFormat`, `architectureSupported` (backed by the
  real architecture registry), `sizeVsMemory`, `diskSpace`, `cacheQuota`.
- **`InstalledModel.resolvedRevision`** (Core): the immutable commit a download actually resolved to.
- **Adapter, draft model and base-model fetches are governed** by the same trust policy, pins, cache cap and
  verification as `download(_:)`. If one is denied or fails, the run fails instead of quietly using the plain model.

### Added — sampling options on Apple's on-device model (`LocalLMLabSDKCore`, 2026-09-19 re-publish)

- `SessionOptions` `temperature`, `maxOutputTokens`, `topK` / `topP` and `seed` now take effect on the
  `system` model (they were ignored). `temperature: 0` selects greedy decoding.
- **`SessionOptionsError`** (`topKAndTopPBothSet`, `seedRequiresTopKOrTopP`, `invalidValue`,
  `perCallOptionsUnsupported`) reports combinations Apple's sampler can't honour, from `makeSession`.
  **Behaviour change:** on the on-device model, `topK` together with `topP`, or a `seed` with neither,
  now throws where it was previously ignored.
- `SessionOptions.appleGenerationOptions()` (the mapping, for hosts calling `languageModelSession`
  directly) and `LocalLMLabSession.respond(to:options:)` (per-call override).
- A seed is best-effort on this model: reproducible within a process, but the first request after launch
  can differ. See [`docs/sdk-guide.md`, "The model layer"](docs/sdk-guide.md).

### Added — model pinning, updates and cleanup

- **Pins:** `MLXPin`, `MLXPinSource` (`.shipped` / `.captured`), `MLXPinStore`, `MLXFilePinStore`
  (`MLXModelProvider(pinStore:)`), `effectivePin(for:)`, `buildTimePin(for:)`. A shipped pin
  (`pinnedRevisions`) beats a captured one and never falls back to `main` on failure.
- **Updates:** `checkPinUpdate(_:to:)` (downloads nothing), `updatePin(_:to:beforeSwitch:)` and
  `updatePins(_:beforeSwitch:)` (all-or-nothing). Atomic: preflight, fetch and verify, `beforeSwitch`, move
  the pin, evict. Rollback is `updatePin(to: oldCommit)`.
- **Developer-moved shipped pins:** `MLXManagedPinStore`, `MLXFileManagedPinStore`, `MLXPinOverride`
  (`MLXModelProvider(managedPinStore:)`). A saved override applies only while it matches this build's
  shipped pin, so a newer app release always wins.
- **Cleanup:** `snapshots(for:)` and `removeSnapshot(_:revision:)` with `MLXCachedSnapshot` (exclusive vs
  shared bytes). The SDK never prunes on its own.
- **`Components`:** `ModelOnboardingView` and `ModelUpdateView` / `ModelVersionsView` (provider-agnostic,
  closure-driven), with `examples/components-updates-demo`.

### Changed — breaking (pre-GA)

These can stop existing code compiling. They landed before the compatibility baseline above, so they do not
count against it. Most apps are unaffected; each item says who is.

- **`SessionEvent.toolCallStarted` and `.toolCallFinished` carry more.** They are now
  `toolCallStarted(id:name:arguments:)` and `toolCallFinished(id:name:failed:resultSummary:)`: the call's real
  arguments, and a short result summary. A `switch` that matches them with the old element count needs a
  placeholder, `case .toolCallStarted(_, let name, _):`. A `default:` or a bare `case .toolCallFinished:` is
  unaffected. *Affects:* code that reads `session.events`.
- **`InstalledModel.init` requires `resolvedRevision`**, the commit a download actually resolved to.
  *Affects:* custom `DownloadableModelProvider`s and tests that construct one by hand.
- **`DownloadableModelProvider` gains a required `cancelDownload(_:)`**. *Affects:* custom conformers only;
  `MLXModelProvider` and `ModelRegistry` already have it.
- **`RemoteModelProvider.init(_:)` now `throws`** (it validates the config). Add `try`, or use the new
  `RemoteModelProvider(unchecked:)` to skip validation. *Affects:* callers of `RemoteModelProvider(config)`.
- **New cases on non-frozen enums:** `PreflightResult.Stage` (`.trustPolicy`, `.cacheQuota`) and
  `RemoteError.responseTooLarge`. Source-compatible if you write `@unknown default`; an exhaustive `switch`
  needs the new cases.

### Added — tool calls, reasoning, downloads

- **`effort: .off` is best-effort**: it no longer throws for a model that always reasons (DeepSeek-R1), and
  `ModelCapabilities.reasoningToggle` lets a host check ahead of time whether suppression will take effect.
- **Downloads can be cancelled**: `cancelDownload(_:)` on `MLXModelProvider` and `ModelRegistry`. This also fixes
  a cancelled download's `URLSession` task carrying on in the background. `Components`' download UI now shows
  byte-formatted progress and a Cancel button.
- **`LocalLMLabSDKRemote` hardened**: `RemoteProviderConfig.responseLimits` (`RemoteResponseLimits`, defaulted)
  bounds response sizes, and provider construction validates its configuration (the `throws` above).

### Changed

- **`SpeculativeDecodingSpec.numDraftTokens` default is now 2** (was 5). Measured on a Mac with a Qwen3-0.6B
  draft, 1–2 draft tokens were 27–39% faster and 5 was 17–29% slower. Source-compatible; pass a value to keep 5.

### Fixed

- **Sandboxed apps could not download an MLX model** (`LocalLMLabError.download(stage: "verify")`). The SDK
  looked for downloaded files under `~/.cache/huggingface/hub` while a sandboxed app's downloader writes to
  `Library/Caches/huggingface/hub`. The SDK now asks the downloader where its cache is. Affected the first
  RC.1 binaries; fixed in the re-publish.

### Added — examples

- **`examples/mlx-control-room`**: the MLX sampling, prefill, reasoning and pairing knobs with a gauge for
  each, plus the validate, download, pin, update, roll back and clean up flow made visible. Sandboxed `.app`.
- `workspace-buddy-local`, `aiql`, `code-buddy` and `repo-qa-local` now pin the models they use (`aiql` adds a
  trust policy). `workspace-buddy-local` and `repo-qa-local` build against RC.1 by default.

### Checksums (SHA-256)

```
LocalLMLabSDKCore-1.0.0-RC.1.xcframework.zip       397e7b5f7efd1076293a3d5d06c41d75043bffa23cffdb821d71d21ee41e68de
LocalLMLabSDKClaude-1.0.0-RC.1.xcframework.zip     9678077c47f257ed8165e653d0e322501e7d79459e1bf76ca1bfcf1850f6f55e
LocalLMLabSDKInference-1.0.0-RC.1.xcframework.zip  e24cb0581807d37a7b595f0b198b9a9eeecc1c5c36fb59f61429b8a7b42dc169
LocalLMLabSDKRemote-1.0.0-RC.1.xcframework.zip     3e763c2fb542f7cc8493cf8e4ba2effcc98adae9c7d9991b60e6a92be8ee88c6
```

## 1.0.0-beta.4 — 2026-09-10

### Added — MCP client: protocol revision `2025-11-25` (`docs/mcp-guide.md`, "MCP revisions")

The client now negotiates MCP `2025-11-25` (down to `2024-11-05`); every server that worked
before still works. `MCPServerState.negotiatedProtocolVersion` reports where each connection
landed. New public surface:

- **`MCPToolResult`** — `callTool` returns this instead of a `String` (**breaking**, see below):
  `text`, `structuredContent` (validated against the tool's `outputSchema`), `resourceLinks`,
  `isError`, `truncated`, and `renderedForModel` for a context-sized rendering.
  `MCPResourceLink`.
- **Server-initiated requests** — `MCPClientHandlers` plus `MCPElicitationHandler` /
  `MCPSamplingHandler` / `MCPRootsProvider` / `MCPLoggingSink` and their value types. A
  capability is advertised to a server only when its handler is registered.
  `MCPServerManager.init(responseLimits:handlers:)`. `callTool(…, allowElicitation:)`.
- **`Components`** ships the elicitation UI — `MCPElicitationPresenter` (a ready-made
  `MCPElicitationHandler`) and `View.mcpElicitationSheet(_:)`.
- **CIMD** — `MCPOAuthFlow.clientMetadataURL`, an alternative to Dynamic Client Registration.
- **`MCPDiagnostics`** — `logLevel`, an opt-in exportable event buffer, and an `observer` hook
  for MCP connection / auth / stream troubleshooting. Off-content; secrets redacted.
  `docs/mcp-diagnostics.md`.
- `MCPProtocolVersion`, `MCPServerCapabilities`, `MCPServerIdentity`;
  `MCPServerState.serverInstructions`; `MCPToolDescriptor.title` / `.outputSchema`;
  `MCPResourceDescriptor.title`; `MCPServerError.responseTooLarge`; `MCPValue.strippingEmpty()`.

### Changed — `LocalLMLabSDKCore` (breaking)

- **`MCPServerManager.callTool` returns `Result<MCPToolResult, MCPServerError>`**, was
  `Result<String, MCPServerError>`. Direct callers: use `result.renderedForModel` for the same
  string you had. A tool that ran but reported failure is now `.success` with
  `result.isError == true`. The `MCPTool` / `FileBackedTool` adapters absorb this — no change if
  you go through them. See [`docs/migrating-to-1.0.md`](docs/migrating-to-1.0.md).

### Added — `LocalLMLabSDKCore`: AIQL SQL layer (`loadTable` + `sqlQuery`)

- **`LoadTableTool`** (`loadTable`) — stages a JSON records file into an ephemeral SQLite table
  at `<root>/aiql.sqlite`. Auto-detects the records array (ambiguity → a listing error), sniffs
  `INTEGER`/`REAL`/`TEXT` per column (numeric strings included), flattens one level of nested
  objects to dotted columns, and **splits any nested array into a `<table>__<field>` child
  table** (`<table>_id` link + `idx` + the element's fields; a scalar element → a `value`
  column) so a small model writes a `JOIN` instead of `json_each`. Returns the `CREATE TABLE`(s)
  plus sample rows.
- **`SQLQueryTool`** (`sqlQuery`) — runs one read-only `SELECT` → CSV. Opened
  `SQLITE_OPEN_READONLY` behind a `sqlite3_set_authorizer` allowlist (SELECT/READ/FUNCTION only —
  no DML, DDL, `ATTACH`, writing `PRAGMA`s), single statement enforced, 15 s timeout, 100k-row
  output cap. A "no such column" error appends the loaded tables + their columns so the model's
  retry stops guessing. Two loaded tables `JOIN` in one `SELECT` — the cross-dataset case.
- No package dependency — `import SQLite3` is the system library; `Core`'s `dependencies` stays
  `[]`.
- Replaces `BuildSpreadsheetTool` (added earlier in this cycle, never published): `sqlQuery`
  stops orchestration drift the same way — one call — while closing every gap (joins,
  aggregates, computed columns), validated end to end on `mlx-community/Qwen3-8B-4bit` and
  `Qwen3-14B-4bit` (`examples/aiql-eval` in the SDK dev repo). The individual verbs
  (`jsonToCsv` / `filterRows` / …) stay as pure-Swift primitives.
- [`examples/aiql`](examples/aiql/) uses `loadTable` + `sqlQuery`; its default model is
  `mlx-community/Qwen3-14B-4bit`.

### Checksums (SHA-256)

```
LocalLMLabSDKCore-1.0.0-beta.4.xcframework.zip       3ed0e79b6914e6b48b7ae27f3fdda139f71e3d60f603daf54901716c8c972cb3
LocalLMLabSDKClaude-1.0.0-beta.4.xcframework.zip     e9c618eaa543f8f78952b91149e873d027fac27ca02c4bc42f0cfd4f3cb45449
LocalLMLabSDKInference-1.0.0-beta.4.xcframework.zip  fa8feb19883f9a465a69f39d756f1b41b515c8298c891b06fef5da5b81b2a03c
LocalLMLabSDKRemote-1.0.0-beta.4.xcframework.zip     a73a06bf04a2dd3b1a15b40770f12c0565f8cbf1a97eaa604317b09e3a860454
```

## 1.0.0-beta.3 — 2026-09-06

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
  host app can present the panel and hand the work to a 27-only helper.

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

### Added — `Core` workspace: file-backed tools + the "AIQL" data verbs (`docs/sdk-guide.md`, "File-backed tools")

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
LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip       a49b8bfcde340d8b86bf106d2af2cb9d84f3839a3bc1695016f3952a3fcdfb92
LocalLMLabSDKClaude-1.0.0-beta.3.xcframework.zip     cd312701e764c408d51efb1dd7cbb8c71c3392aab02fbec98a0a1f3dd584506a
LocalLMLabSDKInference-1.0.0-beta.3.xcframework.zip  0e2b3cc522291dd6c0afdede6ee4516d272ed20b5c22adad68b80893c266800d
LocalLMLabSDKRemote-1.0.0-beta.3.xcframework.zip     2b1e401a606c2c34d3e086cf9a2edad9d2c9ca730a3c3840b964f88d9e2e446b
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
  target (the LocalLM Lab app splits its background helper this way).
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
been here since `0.7.0`. Full walkthrough: [`docs/sdk-guide.md`, "The model layer"](docs/sdk-guide.md).

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
  `LanguageModel` protocol (macOS 27); an older Xcode fails with `'v27' is unavailable`.
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
