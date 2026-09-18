# MLX Control Room

**MLX Control Room** is a live panel over an MLX-backed model session. It puts the knobs
`SessionOptions` and `MLXModelProvider` expose — sampling, prefill, model pairing, pinning and updating
— in front of you, next to **gauges that prove each knob actually reaches `mlx-swift-lm`** rather than
being silently accepted and ignored. A knob only counts as "exposed" once something here reacts to it.

**What it highlights for SDK developers.**

- **Choosing and onboarding a model**, with the SDK's supply-chain checks made visible: a preflight
  (architecture, trust policy, size, quota), a content-hash-verified download, and a *pin* — the exact
  commit you got, so a later re-download fetches the same content instead of whatever `main` is by then.
- **Two kinds of pin, with different rules for who may move them.** A model *you* choose is pinned to the
  version you first downloaded, and you decide when to update it. A model the *app ships* is pinned by its
  developer, who decides — including moving it to a newer version **without a new app release**.
- **Updating safely**: check what would change before downloading anything, fetch first and switch last so a
  failure changes nothing, pause inference for the switch, roll back instantly, and clean up old versions.
- **Model pairing**: a speed-helper pair and an adapter pair, each with a live on/off switch.

## Getting the SDK & toolchain

Copy-paste each step. Step 1 is one-time machine setup; step 2 sets up your terminal session (re-run it in
every new terminal).

**1. Install Xcode 27.** Get it from the Mac App Store or
[developer.apple.com/xcode](https://developer.apple.com/xcode/). `Package.swift` requires
`platforms: [.macOS("27.0")]`, so an older Xcode fails with `'v27' is unavailable`.

**2. Point `swift` at Xcode 27** for the terminal you'll build from:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`Package.swift` builds against SDK `1.0.0-RC.1` with no further setup — it links **two** binaries,
`LocalLMLabSDKCore.xcframework` and `LocalLMLabSDKInference.xcframework` (the MLX runtime), from that one
GitHub Release. `export LOCALLM_SDK_VERSION=<version>` pins a different published release. **No Metal
Toolchain needed** — the prebuilt Inference xcframework bundles the compiled `default.metallib`.

**3. Compile-check:**

```bash
swift build
```

## Open in Xcode and Run

A committed `MLXControlRoom.xcodeproj` is the lowest-friction way to try it. **Open it in Xcode 27 or
newer**:

```bash
open -a Xcode MLXControlRoom.xcodeproj
```

Pick the **MLXControlRoom** scheme and Run — a real **sandboxed** `.app` with the `network.client`
entitlement (model downloads need it) and the `LocalLMLabSDKInference` (MLX) framework embedded. **The first
model you pick downloads** (the recommended one is about 0.3 GB); after that it's local and offline.

**Signing** is *Automatic* with no hard-coded team, so Xcode signs with your **Apple Development** identity.

| Your Xcode setup | What happens on Run |
|---|---|
| One Apple ID in **Xcode ▸ Settings ▸ Accounts** (**free** is enough) | picked automatically |
| No Apple ID | Run stops with *"requires a development team"* — add a free Apple ID, **or** target ▸ **Signing & Capabilities** ▸ **Sign to Run Locally** |

Generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen) — edit
`project.yml`, not the `.xcodeproj`, then `xcodegen generate`. `packaging/build-and-sign.sh` makes a
distributable `.app`.

You can also run it without an app bundle (`swift run MLXControlRoom`). That build isn't sandboxed and stores
its models in `~/.cache/huggingface/hub`.

## The launch screen

The app opens on a model picker, not the control room:

- **Recommended model** — `Qwen2.5-0.5B-Instruct-4bit`, shipped pinned at a fixed commit. The pin step
  *verifies* the download resolved to exactly that commit.
- **Update test: Gemma 3 270M** — a second built-in model, shipped pinned at an *older* commit on purpose, so
  there is something for the developer's update feed (here a stand-in) to offer. **Test a developer update**
  opens the control room on it; use **Check for updates** there. See
  [Updating a built-in model](#updating-a-built-in-model-without-a-new-app-release).
- **Choose a different model…** — type any `mlx-community/...` repo id. The trust policy allow-lists
  `mlx-community/*`; try another namespace to see it refuse the repo *before any network call*. The first
  download **records the version you got**, so later downloads fetch exactly that version.
- **Model pairing…** — a curated, pinned pair (below).
- **Advanced** — turn content-hash verification off, cap the total cache size (a low cap makes Validate fail
  at the quota stage), or simulate a stale shipped pin (a bogus commit: the model should fail hard, never
  quietly fall back to `main`). It also lists the versions recorded for models you chose, with a **Forget**
  button each.

Each model goes through **Validate → Download → Pin**, one block per model. A failure names its stage and
stops everything after it; **Dismiss** returns you to the picker. **Change model** (top of the control room)
comes back here.

## What each control does (plain-English guide)

Written for someone who wants to understand what they're looking at without needing to know how AI models
work internally. Every gauge is real, measured behavior, not decoration.

### Sampling — how the model picks its next word

Every reply is built one word-piece at a time. At each step the model has a ranked list of candidate next
words with a likelihood attached to each; these controls change how it picks from that list.

- **temperature** — how much randomness to allow. At 0, the model always picks its single most likely word,
  so the same prompt gives the same answer. Turn it up and it varies more (and, past a point, makes less
  sense). *What to expect*: at 0, the **determinism gauge** reads "match" if you run the same prompt twice
  with a fixed seed; above 0, replies vary unless you also fix the seed.
- **topP** and **topK** — two ways of trimming the candidate list before temperature picks from it: `topP`
  keeps enough top candidates to cover a probability share, `topK` keeps a fixed number. They stop an
  occasional bad pick from far down the list. Most people never need to touch these.
- **maxOutputTokens** — a hard budget for one reply, typed as a whole number (1 to 1,000,000; the default is
  1024). Too low and a reply is cut off mid-sentence. An invalid value is flagged and blocks Run rather than
  being silently changed.
- **suppress thinking (effort: .off)** — some models write a visible "let me think…" scratchpad before their
  answer. This skips straight to the answer. *What to expect*: shorter, faster replies with no reasoning
  block — on models that support the toggle at all.
- **fix seed / seed** — makes the model's "dice rolls" reproducible, so the same prompt and settings give
  the same reply. *What to expect*: the **determinism gauge** turns green ("match").
- **repetitionPenalty** (+ **repetitionContextSize**) — the fix for a model stuck repeating itself. Recently
  used words become less likely for a while; the context size is how far back it looks. *What to expect*: the
  **repeat-rate gauge** drops on a prompt that would otherwise loop.
- **prefillStepSize** — affects only how long you wait before the reply *starts* on a long prompt. *What to
  expect*: the **TTFT gauge** shrinks with a bigger chunk size on a long prompt.

### The gauges, in plain terms

- **tokens/sec** — roughly how fast words are arriving. Higher is faster. (An approximation: words divided by
  elapsed time.)
- **repeat rate** — what fraction of the reply is the model repeating itself. Lower is healthier.
- **TTFT** — time-to-first-token: how long before anything appears.
- **determinism** — "match" or "differs" after the same prompt + fixed seed, twice.
- **residency** — a log of which models are loaded in memory, and when they were loaded or evicted.

## Model pairing

**Model pairing…** offers two curated pairs. Every model in a pair is shipped pinned, and goes through the
same Validate → Download → Pin flow. A pair is curated, not free text, because a draft model must be a
same-family sibling of its base, and an adapter must match the architecture it was trained against.

- **Speed pair** — `Qwen3-4B-4bit` with `Qwen3-0.6B-4bit` as a *speed helper*: the small model proposes a
  couple of words ahead and the large one checks them in one cheap pass. The output is the same; it arrives
  sooner. *What to expect*: run a prompt with the helper off, then on, then on again — the first run with it
  on loads the helper, so it's slower; the second shows the steady state. Measured (release build, warmed up,
  greedy): about **30–40% faster**, and the output is byte-identical. It drafts **2** words ahead — with the
  SDK's earlier default of 5 it was *slower*, because a small draft model only agrees with the big one for a
  token or two at a time.
- **Adapter pair** — `Qwen3-0.6B-bf16` with a small LoRA adapter that makes it write haiku-style verse.
  *What to expect*: run a prompt with the adapter off (a factual overview), then on (a short verse).

The switch sits right under the title. A pair's models are updated together, or not at all.

## Pins, updates and old versions

A **pin** is the exact version of a model, so the content you validated is the content you keep using.

**A model you chose** is pinned to the version you first downloaded. In the **Model & pin** panel, **Check
for update** shows what would change (files and sizes) and downloads nothing; **Update** fetches the new
version, and only if that succeeds does the pin move — a failure changes nothing. **Roll back** returns to
the previous version instantly (its files are still cached). To try it, choose **Choose a different
model…**, then **Use gemma-3-270m-4bit** and switch on **Demo: pretend I downloaded this a while ago**: a
model downloaded today is already the newest, so the switch records an older version (about 280 MB) as the
one you got.

### Updating a built-in model without a new app release

A model the app ships is different, because a different party vouches for the version: for a model you
chose, your click is the approval; for a built-in one, **the developer** reviewed one specific version.
So "update to whatever is newest" is never allowed — the SDK moves a shipped pin only to a **full commit hash
the app names**, and where the app learns it (its server, a config push) is the app's business, as is
authenticating it. Here `HostUpdateFeed` stands in for that server. Choose **Test a developer update** on the launch screen and use **Check for
updates**, **Update**, and **Back to the version this app shipped**.

- The update is saved with the version *this build* shipped, so it survives a relaunch — but **a newer app
  build always wins**: with **Advanced ▸ Simulate a newer app build** on, the earlier update is discarded and
  the release's own choice applies.
- **Pausing for the switch.** Downloading doesn't disturb a conversation; switching can. Once the new version
  is downloaded and verified, the app stops accepting new runs (the status reads "switching model
  version…"), lets a run in progress finish, and only then does the SDK switch — so no session can load part
  of a model from the old version and part from the new.

### Cleaning up old versions

An update leaves the previous version on disk, which is what makes rolling back instant. **Nothing is ever
removed automatically** — the app decides when. **Versions on disk** lists every cached version with what
removing it would *actually* free: the cache shares files between versions, so after a one-file update the
old version frees only its own `config.json` (about 1.6 KB), not the ~190 MB it shares with the version in
use. **Remove** deletes one version and only the files no other version uses, and it refuses the version in
use.

## Where things are stored

- **Model weights** land in the Hugging Face cache — in the app's sandbox container when run as the signed
  `.app`, in `~/.cache/huggingface/hub` for `swift run`.
- **Pins** live in two small JSON files in the app's Application Support folder
  (`mlx-pins.json` for versions recorded for models you chose, `mlx-managed-pins.json` for updates to
  built-in models), *outside* the model cache on purpose: removing a model deletes its whole cache directory,
  and a pin kept there would be gone exactly when it's needed.

## Not production

One window, one model at a time, no packaging beyond the sample `.app` — it's a harness for seeing what the
SDK's knobs and safeguards do. The plan is to fold the useful parts into the LocalLM Lab app rather than keep
it a standalone example forever.
