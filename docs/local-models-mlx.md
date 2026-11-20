# Running MLX models in code

Running open-weight models on the Mac through `LocalLMLabSDKInference`: loading, measuring a turn, and pinning versions. Part of [the model layer](sdk-guide.md#the-model-layer-models-routing-and-sessions).

> **This page is about the code, not the list of models.** It shows how an app loads and runs any MLX model;
> it doesn't say which models to use. For that, see [MLX models](https://thisbrain.ai/locallm/mlx-models.html),
> the maintained list of open-weight models we've tested (Qwen, Gemma, Mistral, Granite, GLM and more), sized for
> a 24 GB MacBook Air and a 64 GB Mac Studio, with tool-calling results. Whatever the list says, check your own
> model with `capabilityProbe` (below).

The prompt cache, which is on by default for these models in 3.0, is described in [the SDK guide](sdk-guide.md#the-prompt-cache-30).

## `MLXModelProvider` — run open-weight models locally (`LocalLMLabSDKInference`)

> **Use it when** you want the model to run entirely on the user's Mac with no API key and no
> network at inference time. It's a `DownloadableModelProvider`, so on top of the provider basics
> it adds the runtime lifecycle (validate → download → capability-probe → remove) shown below.
>
> **Examples that use it:** [`code-buddy`](../examples/code-buddy/) calls `validate` before its
> first run, streams `download` progress, and prints `residencyEventStream` transitions to
> stderr (its README has the small-RAM-Mac walkthrough);
> [`workspace-buddy-local`](../examples/workspace-buddy-local/) runs the whole model layer
> inside App Sandbox.

```swift
let mlx = MLXModelProvider(residentModelLimit: 1)   // 1 model resident at a time

// Loading never downloads (3.0): a model that isn't on disk fails a session with .modelUnavailable.
// So ask first. `lab.models.availability(for:)` says whether it's on disk; if not:

// Before you download: is this model sane for this machine? (no weights pulled)
let check = try await mlx.validate("mlx-community/Qwen3-8B-4bit")   // PreflightResult
//   check.weightBytes is the download size: show it and ask the user before you call download.
//   → repo reachable? MLX format? architecture supported? weight size vs this Mac's RAM?
//     each failure names its stage.

// Download, tracking progress
for try await event in mlx.download("mlx-community/Qwen3-8B-4bit") {
    if case .progress(_, _, let fraction) = event { updateBar(fraction) }
    if case .completed(let installed) = event { /* InstalledModel */ }
}

// A "Cancel" button: aborts the real transfer, not just this loop's iteration — the stream
// finishes by throwing (typically CancellationError) instead of yielding .completed. Equivalent
// to cancelling the Task driving the `for try await` above, for callers not structured that way.
mlx.cancelDownload("mlx-community/Qwen3-8B-4bit")

// Post-download smoke test — a real prompt + a trivial tool call. Authoritative for
// that model's ModelCapabilities (some downloaded models can't reliably tool-call).
let report = await mlx.capabilityProbe(installed.id)   // ModelCapabilityReport
// report.capabilities: .toolCalling, .guidedGeneration (respond(to:generating:) — run on
// languageModelSession, see "Running a turn"), .reasoningToggle
// This is authoritative. For a starting shortlist of what tool-calls and what doesn't,
// see the MLX models list (thisbrain.ai/locallm/mlx-models.html) — but always confirm your
// own model with capabilityProbe.

mlx.installed        // [InstalledModel] — what's on disk now
mlx.storageUsed      // total bytes of weights
try mlx.remove(id)   // delete weights
```

**Tool calls on a local model.** The MLX runtime parses the model's tool-call markup into calls to
your tools. A call it can't accept fails the turn instead of reaching the user: an
unparseable payload, a tool the session doesn't declare, or arguments that break the tool's schema
throw `LocalLMLabError.generation(underlying:)`, whose message names the reason (for example
`malformed_syntax`) and never includes the raw model output. Before 2.1 the call markup came back as
the model's answer and nothing ran, so if you showed that text, or retried on it, catch the error
instead; running the turn again is often enough for a small model. A call written inside the model's
reasoning (`<think>…</think>`) stays inert, since a model rehearsing a call hasn't decided to make
it. The exception is a `<think>` block that opens directly on the call and never closes, which
Qwen3 sometimes writes: that call runs. Since 2.1 the runtime also handles Gemma 4's array and object
arguments and gpt-oss (Harmony) and Muse Glimmer tool calls; the
[CHANGELOG](../CHANGELOG.md) has the details.

**Where the weights land** — a standard Hugging Face cache
(`models--<org>--<name>/snapshots/<sha>/`, deduped `blobs/` underneath):

| Context | Default location |
|---|---|
| CLI / non-sandboxed app | `~/.cache/huggingface/hub/` |
| **Sandboxed app** (`com.apple.security.app-sandbox`) | `~/Library/Containers/<bundle-id>/Data/Library/Caches/huggingface/hub/` |

The sandbox redirect is automatic. An 8B-4bit model is ≈4.5 GB and, for a sandboxed app, counts
against the app's container. Relocate with `MLXModelProvider(cacheDirectory:)` or the
`HF_HUB_CACHE` / `HF_HOME` env vars. A sandboxed app also needs `com.apple.security.network.client`
for the download — [`examples/workspace-buddy-local`](../examples/workspace-buddy-local/) runs the
whole model layer inside App Sandbox and is the worked example.

**The memory story** — the whole reason `MLXModelProvider` isn't just "load and go":

- `residentModelLimit` caps how many models stay in RAM. Switching routes evicts the other.
- `MLXPreflightLimits(maxWeightFractionOfRAM: 0.7)` — `validate` fails a model whose weights
  would exceed this fraction of physical memory, *before* the download.
- `mlx.residencyEventStream` (also forwarded onto `lab.models.events`) emits
  `.warmed` / `.evicted(reason:)` / `.loadProgress` — **use it when** you want a status line
  that shows "loading 45%" vs "reusing warm model", or to tell the user the OS evicted the
  model under memory pressure.
- `unloadResident(_:)` / `unloadAllResident()` — drop weights explicitly (e.g. before a
  memory-heavy operation elsewhere in your app).
- `lab.models.residency` — `.lastUsedOnly` (default) evicts opportunistically under
  `residentModelLimit`; `.keepWarm([.heavy, .light])` prewarms those specific routes' models
  immediately (setting it triggers the load) instead of waiting for the first turn to pay the
  load cost. `residentModelLimit` still caps how many can actually stay loaded together, so
  `.keepWarm` on two routes needs the limit raised to at least 2 or the second prewarm evicts
  the first — same LRU cache either way.

**For a production build, pin the repos you ship against**: `MLXModelProvider(pinnedRevisions:
["mlx-community/Qwen3-8B-4bit": "abc1234…"])` downloads that exact commit instead of tracking
`main`. Without a pin, a repo owner moving `main` to different weights silently changes what your
app fetches on a user's next fresh download — the same file path, a different model. A repo not
listed in `pinnedRevisions` still tracks `main` as before; pin only the ones your app's behavior
depends on being stable.

**Supply-chain hardening for a free-text model picker** — if your app lets the *user* type any
repo id (rather than shipping a fixed list you've already pinned), `pinnedRevisions` can't help on
its own: there's nothing to pin ahead of time. Three more pieces cover that case, all grouped into
one `MLXModelProvider.init` parameter:

```swift
struct MyTrustPolicy: MLXModelTrustPolicy {
    func evaluate(repoID: String) async -> MLXModelTrustDecision {
        repoID.hasPrefix("mlx-community/") ? .allow : .deny(reason: "not on the allow-list")
    }
}

let mlx = MLXModelProvider(supplyChainPolicy: MLXSupplyChainPolicy(
    verification: .enabled,                              // default — see below
    trustPolicy: MyTrustPolicy(),                         // your allow/deny logic; nil = accept anything
    cacheLimits: MLXCacheLimits(maxTotalCacheBytes: 20_000_000_000)))   // refuse past 20GB
```

- **`trustPolicy`** gates which repo ids can be validated/downloaded at all — checked before any
  network call in `validate`, and re-checked in `download` (the policy might be dynamic, or
  `download` might be called without a prior `validate`). The SDK ships no built-in allow-list;
  that curation call is yours to make.
- **`verification`** (`.enabled` by default) hashes every downloaded file against the ETag Hugging
  Face reports for it before it's cached. A verification failure surfaces as
  `LocalLMLabError.download(stage: "verify", underlying: MLXWeightVerificationError)`. Set
  `.disabled` only for a non-standard HF-compatible mirror whose ETags don't follow a recognized
  shape.
- **`cacheLimits`** caps the MLX weight cache's total on-disk size — **this checks the whole cache
  directory** (`MLXModelProvider(cacheDirectory:)`'s target, or the shared default), not just
  weights your app itself downloaded. A generous-looking cap can trip immediately if the user's
  Mac already has other MLX models cached from elsewhere. Give your app its own `cacheDirectory` if
  you want the cap scoped to just its own footprint.

**Self-pinning after a free-text download**: every `InstalledModel` (from `.completed` or
`mlx.installed`) carries `resolvedRevision`, the immutable commit hash the download actually
resolved to, whether that came from a pin or from tracking `main`. Pass an `MLXFilePinStore` as
`pinStore:` and the SDK persists it for you, outside the Hugging Face cache; see
[Pinning, updating and cleaning up model versions](#pinning-updating-and-cleaning-up-model-versions).
If you would rather store it yourself, persist `(repoID, resolvedRevision)` anywhere that is **not**
under the Hugging Face cache directory (`remove(_:)` deletes that whole directory, refs and all), and
pass it back in `pinnedRevisions` before redownloading.

## Measuring and guarding a local model's turn — usage, speed, memory, limits

> **Use it when** you want to show how a local model performed on a turn (tokens, prompt and
> generation speed, memory), say why nothing has appeared yet on a long prompt, or decide how many
> tool rounds one turn may take. MLX models only — other providers don't report these.
>
> **Reference implementation:** LocalLM Lab's Playground **Benchmark** panel reads all of it.

**Usage and speed, per turn.** Each turn's response carries the model's real token counts and an
`mlx.*` metadata dictionary of turn totals — read it from the response's `usage`, or the last stream
snapshot's. `session.streamResponse` yields only the reply text, so to read `usage` run the turn on
`languageModelSession` directly (which skips the SDK's retry and tool refresh; see
[Running a turn](sdk-guide.md#running-a-turn-and-when-to-use-languagemodelsession)):

```swift
var last: LanguageModelSession.Usage?
for try await snapshot in session.languageModelSession.streamResponse(to: prompt) { last = snapshot.usage }
let meta = last?.metadata ?? [:]
func number(_ key: String) -> Double? { meta[key].flatMap { Double("\($0)") } }

let tg = number(MLXUsageMetadataKey.tokensPerSecond)          // generation, t/s
let pp = number(MLXUsageMetadataKey.promptTokensPerSecond)    // prompt processing, t/s
let calls = number(MLXUsageMetadataKey.rounds)                // 1 + one per tool round
```

| `MLXUsageMetadataKey` | Value (turn total) |
|---|---|
| `promptTokens`, `generatedTokens` | Tokens read and written, summed over the turn's model calls |
| `promptSeconds`, `generateSeconds` | Time in each phase |
| `promptTokensPerSecond` (pp), `tokensPerSecond` (tg) | Σ tokens ÷ Σ seconds — absent if no time was measured |
| `rounds` | Model calls: the first, plus one per round after tool calls |
| `stopReason` | `stop`, `length` or `cancelled` |
| `draftTokensProposed`, `draftTokensAccepted`, `speculativeRounds` | With a speed helper (`pairDraftModel`) only |
| `residentMemoryBytes`, `peakMemoryBytes`, `gpuMemoryLimitBytes` | MLX memory when the turn began (the loaded weights), its peak during the turn, and how much the GPU may use |

Three things to know when reading usage:

- **`languageModelSession.usage` is the whole session**, summed over every model call — it grows
  each turn. One turn's figures are on that turn's response, as above.
- **A tool round re-reads the whole conversation.** Each model call in a turn processes everything
  before it again, so `promptTokens` for a tool turn is roughly *calls × conversation*, and one tool
  call can double a long prompt's reading time. Prefer giving the model facts directly over a tool
  it must call each turn — e.g. the date through [`turnContext`](sdk-guide.md#building-a-chat-app--hosttranscript-streamresponse-turncontext), not a clock tool.
- **pp from a short prompt is mostly overhead.** Measure prefill speed on a prompt of a few
  thousand tokens.

**What is it reading right now?** A long prompt can take tens of seconds before the first token.
`MLXPrefillMonitor.active` lists prompts being processed in this process — exact tokens, which model
call of the turn, and since when — from the moment prefill starts until the first output:

```swift
if let reading = MLXPrefillMonitor.active.last(where: { $0.repoID == repoID }),
   Date().timeIntervalSince(reading.startedAt) > 3 {
    status = "Reading a \(reading.promptTokens.formatted())-token prompt (model call \(reading.modelCall))"
}
```

Poll it while a turn has produced no output (once a second is plenty); it's a cheap read.

**Guards the SDK applies before every model call.**

- **A prompt that can't be processed is refused up front** — over the model's context window
  (`max_position_embeddings`), or one whose cache wouldn't fit in the GPU memory left — with
  `LocalLMLabError.context` and a plain message, instead of starting a prefill that would fail or
  crawl. `respond` / `streamResponse` treat it as a context overflow, so
  [`retryOnContextOverflow`](sdk-guide.md#contextbudget--retrypolicy--surviving-a-long-session) compacts and
  retries it.
- **A turn that keeps calling tools stops** after `maxModelCallsPerTurn` model calls (default
  `MLXModelProvider.defaultMaxModelCallsPerTurn`, 16: the first plus 15 tool rounds), with an error
  saying the model kept calling tools without answering. Set your app's default on the provider, or
  per session:

```swift
let mlx = MLXModelProvider(maxModelCallsPerTurn: 40)                        // this app's default
let agent = try lab.makeSession(route: .local, tools: tools,
                                options: .init(maxModelCallsPerTurn: .max))  // this session: no limit
```

  Session beats provider beats 16; values below 1 count as 1.

## Pinning, updating and cleaning up model versions

*Part of [supply-chain hardening](#mlxmodelprovider--run-open-weight-models-locally-locallmlabsdkinference) for model downloads: the trust policy and verification above decide whether to fetch; pins decide which version you keep.*

**Why this matters.** A Hugging Face repo is not a fixed, vetted artifact. Its owner can change the
files behind the same name at any time, anyone can publish a repo with a look-alike name, and a
download can be corrupted, oversized, or not runnable on the user's Mac. An app that pulls models at
runtime inherits all of that. The pieces above (trust policy, preflight, hash verification, the cache
cap) decide *whether* to fetch a model. Pinning decides *which version* you keep using, so that the
content you validated is the content that runs. `examples/mlx-control-room` walks through each of
these end to end.

A **pin** is one exact Hugging Face commit hash for a repo. There are two kinds, and they differ in who
vouches for the version:

| | Where it comes from | Who approved it | May move to |
|---|---|---|---|
| **Shipped pin** | `pinnedRevisions` in your code (build time) | You, the developer | Only a full commit hash you name |
| **Captured pin** | `MLXPinStore`, written after a user's first successful download | The user's own choice (trust on first use) | `main` or a commit hash |

A shipped pin always beats a captured one. A shipped pin that can't be fetched (a mismatch, or the
commit is gone) **fails hard and never falls back to `main`**.

**Persist captured pins with `MLXFilePinStore`.** Pass a pin store to the provider and the SDK records
`(repoID, commit)` after each successful download, then uses it on later downloads:

```swift
let pins = MLXFilePinStore()   // default file: mlx-pins.json, outside the HF cache
let mlx = MLXModelProvider(
    pinnedRevisions: ["mlx-community/gemma-3-270m-it-4bit": "abc1234…"],   // shipped pins
    pinStore: pins)                                                        // captured pins
```

Keep the pin file outside the Hugging Face cache. `remove(_:)` deletes the whole repo directory in
the cache, so a pin stored there would vanish along with the weights it exists to protect. Pins are
resolved per download, so one captured after `init` is honored by the same provider instance.
`effectivePin(for:)` reports the pin in force and its source; `buildTimePin(for:)` reports the shipped
one.

**Update a pin atomically.** Checking costs nothing; updating fetches first and switches last:

```swift
// What would change? Downloads nothing.
let check = try await mlx.checkPinUpdate("owner/model", to: nil)   // nil = main (captured pins only)

// Fetch and verify the new commit, then run beforeSwitch, then move the pin, then evict.
for try await event in mlx.updatePin("owner/model", to: newCommit, beforeSwitch: {
    await inference.pauseAndDrain()        // your code: stop new runs, let the current one finish
}) { /* DownloadEvent progress */ }

// Roll back: the old version is still cached, so this is instant.
for try await _ in mlx.updatePin("owner/model", to: oldCommit) {}
```

The order is preflight at the new commit, fetch and verify, `beforeSwitch`, move the pin, evict the
resident model. If any step fails, the pin does not move and nothing changes. `beforeSwitch` is where
the host pauses inference, because the SDK cannot know what else your app has running against the
model. `updatePins(_:beforeSwitch:)` moves several repos together (a base model and its draft, say)
and is all-or-nothing.

**Ship a shipped-pin update without a new app release.** Only a commit the developer names may move a
shipped pin. The SDK never fetches a feed or decides what is "newest"; where your app learns the new
commit, and how it authenticates it, is yours. Give the provider `managedPinStore: MLXFileManagedPinStore()`, then call
`updatePin(_:to:)` with the commit your feed names. The saved override records the shipped pin it was
based on, and applies only while that still equals this build's shipped pin. A newer app release
therefore always wins over an older runtime update, and the stale override is discarded.

**Clean up old versions.** An update leaves the previous version on disk, which is what makes rollback
instant. The SDK never prunes on its own. It gives the host the inventory:

```swift
for snap in mlx.snapshots(for: "owner/model") {
    // snap.revision, snap.isCurrent, exclusive bytes vs bytes shared with other versions
}
let freed = try mlx.removeSnapshot("owner/model", revision: oldCommit)   // refuses the current version
```

The cache stores each file once and shares it between versions, so `removeSnapshot` deletes only the
files no other version uses. Exclusive bytes is what removing a version would actually free.

**Pairing a second model — speed helper and specialization patch** (verified live in
`examples/mlx-control-room`, which has a Speed pair and an Adapter pair with a live on/off switch). Two ways to attach a smaller second model to a base
model, both set on the provider (not `SessionOptions`) so they can be flipped on/off at runtime
without rebuilding a session:

```swift
// Speed helper: base model verifies a small draft model's guesses in bulk instead of
// generating token-by-token. No change in output quality when it helps.
mlx.pairDraftModel(SpeculativeDecodingSpec(draftRepoID: "mlx-community/Qwen3-0.6B-4bit"),
                    with: "mlx-community/Qwen3-8B-4bit")

// Specialization patch: snaps a small LoRA/DoRA adapter onto the base model to specialize its
// style/tone/skill, instead of shipping a whole separate multi-gigabyte model.
mlx.pairAdapter(AdapterSpec(source: .huggingFace(repoID: "stbenjam/qwen3-0.6b-haiku-mlx-lora")),
                 with: "mlx-community/Qwen3-0.6B-bf16")

// Either call with `nil` clears the pairing. Both take effect on the *next* session built for
// that base repo id — safe to call at any time, including mid-run, for live A/B testing.
mlx.pairDraftModel(nil, with: "mlx-community/Qwen3-8B-4bit")
```

- **Speed helper** must share the base model's tokenizer — in practice, the same model family at
  a much smaller size. The combined base+draft weight size is checked against the same
  `preflightLimits.maxWeightFractionOfRAM` (70% by default) the single-model download warning
  already uses. **`numDraftTokens` matters more than you'd expect, so measure.** It is how many
  tokens the draft model proposes per round (default **2**). A small draft only agrees with the big
  model for a token or two at a time, so a long draft mostly wastes work. Measured on one Mac with
  a `Qwen3-0.6B` draft (release build, warmed up, greedy, thinking off, one prompt — treat as
  directional): 1–2 draft tokens were **27–39% faster** than the base model alone on `Qwen3-8B` and
  `Qwen3-4B` bases, 3 was about break-even, and **5 was 17–29% *slower***. With greedy decoding the
  output is byte-identical with the helper on or off. The first run with it on is slower (it loads
  the draft model), so compare the second. Your model, task and Mac will differ — measure before
  turning it on for users.
- **Specialization patch** needs an adapter trained against the *same* base model (or a
  close-enough sibling in the same family/size) to produce sane output. Applying it mutates the
  model's layers in place, so a paired session gets its own dedicated loaded copy — a real memory
  cost if an adapted and unadapted session to the same base run concurrently, traded for adapter
  state never leaking into an unrelated session. Verified live against both an unquantized and a
  4-bit-quantized base with a real published haiku-style adapter — both worked; quantization
  doesn't block LoRA (`QuantizedLinear` is a `Linear` subclass in `mlx-swift`, not a separate
  type).
