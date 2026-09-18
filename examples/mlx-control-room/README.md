# MLX Control Room

**MLX Control Room exposes the model configuration and tuning knobs of the MLX layer.** Sampling, prefill,
reasoning, output length, and model pairing are controls over a model running on your Mac's GPU, and beside each
one is a gauge that shows it changed something. A knob only counts as exposed once something in the app reacts to
it: set temperature to zero and the determinism gauge reads "match"; turn on the repetition penalty and the
repeat-rate gauge drops; pair a small "speed helper" model and tokens per second goes up.

**It also shows how a host app built on the SDK can deploy models from Hugging Face without a "just download
anything" approach.** A Hugging Face repo is not a fixed, vetted artifact: its owner can change the files behind
the same name at any time, anyone can publish a repo with a look-alike name, and a download can be corrupted,
oversized, or simply not runnable on your machine. An app that pulls models at runtime inherits all of that. So
this app checks a model before it downloads, verifies what it downloaded, pins every model to one exact version,
and updates and cleans up versions deliberately. [Security and reliability](#security-and-reliability-what-this-app-does-and-why)
lists each risk, what the SDK does about it, and where you can see it happen.

## Requirements

- **macOS 27 and Xcode 27. macOS 26 is not supported.** The MLX model layer is built on FoundationModels features
  that exist only on macOS 27, and this package declares `platforms: [.macOS("27.0")]`.
- **An Apple-silicon Mac with a Metal GPU** (the model runs there).
- **Network access** the first time you pick a model (it downloads from Hugging Face); after that it runs offline.
  The recommended model is about 0.3 GB.

## Getting the SDK & toolchain

Copy-paste each step. Step 1 is one-time machine setup; step 2 sets up your terminal session (re-run it in
every new terminal).

**1. Install Xcode 27** and run on **macOS 27**. Get Xcode from the Mac App Store or
[developer.apple.com/xcode](https://developer.apple.com/xcode/). `Package.swift` requires
`platforms: [.macOS("27.0")]`, so an older Xcode fails with `'v27' is unavailable`. macOS 26 is not supported (see
[Requirements](#requirements)).

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

The app opens on a model picker, not the control room. Nothing runs until you pick something.

**The main screen**

- **Recommended model** card — `Qwen2.5-0.5B-Instruct-4bit`, shipped pinned at a fixed commit. **Use this model**
   downloads it, and the Pin step *verifies* the download resolved to exactly
  that commit.
- **Update test** card — Gemma 3 270M, a second built-in model shipped pinned at an *older* commit on purpose, so
  there is something for the developer's update feed (here a stand-in) to offer. **Test a developer update** opens
  the control room on it; use **Check for updates** there and you can test the update process. It is also a normal small model you can just use. See  [Updating a built-in model](#updating-a-built-in-model-without-a-new-app-release).
- **Choose a different model…** — type your own repo id (below).
- **Model pairing…** — pick a curated pair (below).
- **Advanced — supply-chain policy** — a collapsed section of security options (below).
- **Quit** — top right, on every screen.

**Choose a different model…**

- A text box for any `mlx-community/...` repo id. Return, or **OK**, starts the checks. The trust policy in this
  demo allow-lists `mlx-community/*` (plus the app's own shipped models), so try another namespace such as
  `meta-llama/Llama-3.2-1B` to watch it be refused *before any network call*.
- The first download **records the version you got** (a "pin"), so later downloads fetch exactly that version.
- **Want to try updating a model? Use gemma-3-270m-4bit** fills the box with a model that has a newer version
  available. When that repo is in the box, **Demo: pretend I downloaded this a while ago** appears — a model
  downloaded today is already the newest, so the switch records an *older* version (about 280 MB) as the one you
  got. Untick it to download the newest instead.
- **Back** returns to the main screen. **Forget pins** clears every version recorded for models you chose, so the
  next download of each records a fresh one.

**Model pairing…** — two cards, **Speed pair** and **Adapter pair** (see [Model pairing](#model-pairing)), each with
**Use this pair**, plus **Back**.

**Advanced — supply-chain policy**

- **verify content hash** (on by default) — verifies every downloaded file against Hugging Face's hash. Turn it off
  to see a download skip verification.
- **cap total cache size** and a slider (10 MB to 20 GB) — refuses to download once the model cache reaches the cap.
  Set a small cap and the Validate step fails at the quota stage.
- **simulate stale shipped pin** (main screen and pairing screen only) — swaps a shipped pin for a bogus commit. The
  model should **fail hard**, never quietly fall back to `main`. It applies to the recommended or update-test model,
  or to a pair's companion (draft model or adapter); a hint beside it says which button to press next.
- **Simulate a newer app build** (main screen only) — pretends the developer released a new version of the app whose
  built-in Gemma is the newer one, to show that a new release beats an older runtime update. The note beneath it
  says exactly what to click next. See [the walk-through](#updating-a-built-in-model-without-a-new-app-release).
- **Versions recorded for models you chose** — every pin recorded from the free-text screen, each with **Forget**,
  and the file they live in.

Verification and the cap only matter on a *fresh transfer*: a model already on disk is skipped file by file.

**While a model is being prepared**

Each model goes through **Validate → Download → Pin**, one block per model (a pair has two). **Validate** runs the
preflight, in this order: trust policy, reachability, model format, architecture support, size against this Mac's
memory, free disk space, and cache quota (an adapter repo isn't a model, so it shows "not applicable"). **Download** shows a progress bar and hash verification. **Pin** shows the commit and, for a
shipped model, checks it against the shipped pin. A failure names its stage and reason and stops everything after
it; **Dismiss** returns you to the picker. A running log sits below. When all steps pass, the control room opens.

## The control room

- **Left column, top:** the model name(s), **Change model** (back to the launch screen) and **Quit**. In pairing
  mode the model's on/off switch is right here under the title.
- **Left column, knobs:** Sampling, Sampling extras, Prefill (each explained [below](#every-knob-explained-no-mlx-background-needed)),
  then **Model & pin** (version, update and cleanup controls) and a **KV cache — roadmap** group of knobs that are
  not implemented yet.
- **Right column:** a prompt box and **Run**, the reply, and the **gauges** (tokens/sec, repeat rate, time to first
  token, determinism) with a residency log of which models are loaded.
- **Model & pin** panel: where the pin came from (shipped, or the version you got), **Check for update / Update /
  Roll back**, **Simulate external deletion + redownload** (deletes the model's files and runs the launch flow
  again, to prove the pin makes the re-download fetch the same version), and **Versions on disk**.

## Every knob explained (no MLX background needed)

### First, the background

- **MLX** is Apple's open-source machine-learning framework for Apple-silicon Macs. This app uses it to run a
  language model on your Mac's GPU instead of calling a cloud service.
- **A model** is a large file of numbers (its *weights*) that has learned to predict text. **Hugging Face** is the
  public site where people publish models. Each lives in a *repo* named like
  `mlx-community/Qwen2.5-0.5B-Instruct-4bit`: `Qwen2.5` is the model family, `0.5B` its size (half a billion
  parameters), `Instruct` means it was tuned to follow instructions, and `4bit` means it was compressed
  ("quantized") to use less memory.
- **A token** is a word-piece — models read and write text in tokens, roughly three-quarters of a word each. A reply
  is produced by repeatedly picking the next token.
- Answering has two phases: **prefill** (the model reads your prompt) and **generation** (it writes the reply one
  token at a time). Some knobs affect one phase, some the other.
- A **commit** is one exact snapshot of a repo. A **pin** is the commit a model is fixed to.

### Sampling: how the model picks its next word

At each step the model has a ranked list of candidate next tokens, each with a probability. These controls change
how it picks from that list.

- **temperature** (0 to 2) — how much randomness to allow. At 0 it always takes its single most likely token, so
  the same prompt gives the same reply. Higher values pick less-likely tokens more often: more varied, and past a
  point less coherent. *Try:* set it to 0, turn on **fix seed**, run the same prompt twice — the **determinism**
  gauge reads "match".
- **topP** (0 to 1) — keeps only the most likely candidates whose probabilities add up to this share (0.95 = the top
  95%), and discards the long tail of unlikely ones. It stops an occasional bad pick from far down the list.
- **topK** (0 = off) — keeps only the K most likely candidates.
- **minP** (0 = off) — drops any candidate whose probability is less than this fraction of the top candidate's. It
  adapts: when the model is confident it trims hard, when it's unsure it keeps more options.
- **seed** (with **fix seed**) — makes the random picks reproducible. Same prompt, same settings, same seed: same
  reply. Useful for comparing changes fairly.

Most people leave topP, topK and minP alone; they exist to tidy up what temperature produces.

### Length

- **maxOutputTokens** — the most tokens one reply may contain, as a whole number from 1 to 1,000,000 (default 1024).
  Set it too low and the reply is cut off mid-sentence. An invalid value is flagged and blocks **Run** instead of
  being silently changed.

### Reasoning

- **suppress thinking** — some models write a visible "let me think…" scratchpad before their answer. This asks the
  model to skip straight to the answer. You get shorter, faster replies with no reasoning block — on models that
  have such a switch at all; some always reason and some never do.

### Repetition

- **repetitionPenalty** (with **penalty** and **contextSize**) — the fix for a model stuck repeating itself ("the
  the the…", or looping one sentence). Tokens used recently become less likely to be picked again; **penalty** is how
  strong the effect is (1 = none), and **contextSize** is how many recent tokens it looks back over. *Try:* a prompt
  that loops, with the penalty off and then on — the **repeat rate** gauge should drop.

### Prefill

- **prefillStepSize** (with **chunk size**) — the model reads a long prompt in chunks; this is the chunk size. It
  changes how long you wait before the reply *starts*, not the reply itself. *Try:* a long prompt with a small and a
  large chunk size and watch **time to first token**.

### Pairing: a second model

Pairing attaches a second, small model to the main one. It is set on the model provider, not per request, so the
switch takes effect on the next run with no restart. Two kinds (the [two curated pairs](#model-pairing) are described below):

- **Speed helper** — a much smaller sibling model proposes a couple of tokens ahead and the big model checks them in
  one cheap pass instead of generating them one at a time. The output is unchanged; it can arrive faster.
- **Specialization adapter** — a small file of adjustments (a "LoRA") applied to the base model to change its style
  or skill — here, to write haiku-style verse — without downloading a whole second model.

### KV cache — roadmap

**maxKVSize** and **compressionAlgorithm** are shown disabled: the SDK doesn't expose them yet. The KV cache is the
memory the model keeps of the conversation so far; these knobs would limit or compress it.

### The gauges

- **tokens/sec** — roughly how fast words are arriving; higher is faster. An approximation: words divided by elapsed
  time.
- **repeat rate** — what fraction of the reply repeats itself; lower is healthier.
- **TTFT** — time to first token: how long before anything appears.
- **determinism** — "match" or "differs" after the same prompt and fixed seed, run twice.
- **residency** — a log of which models are loaded in memory, and when they're loaded or evicted.

## Model pairing

**Model pairing…** offers two curated pairs. Every model in a pair is shipped pinned, and goes through the
same Validate → Download → Pin flow. A pair is curated, not free text, because a draft model must be a
same-family sibling of its base, and an adapter must match the architecture it was trained against.

- **Speed pair** — `Qwen3-4B-4bit` with `Qwen3-0.6B-4bit` as a *speed helper*: the small model proposes a
  couple of words ahead and the large one checks them in one cheap pass. The output is the same; it arrives
  sooner. *What to expect*: run a prompt with the helper off, then on, then on again — the first run with it
  on loads the helper, so it's slower; the second shows the steady state. Measured (release build, warmed up,
  greedy): about **30–40% faster**, and the output is byte-identical. It drafts **2** words ahead. Using a larger number may end up being *slower*, because a small draft model only agrees with the big one for a
  token or two at a time.
- **Adapter pair** — `Qwen3-0.6B-bf16` with a small LoRA adapter that makes it write haiku-style verse.
  *What to expect*: run a prompt with the adapter off (a factual overview), then on (a short verse).

The on/off switch sits right under the title in the control room. A pair's models are updated together, or not at all.

## Security and reliability: what this app does and why

| Risk | What the SDK does | Where to see it |
|---|---|---|
| **A repo you didn't mean to trust** — a look-alike namespace, or one nobody vetted | A **trust policy** the host supplies decides which repos may be fetched. It is checked *before any network call*, so a refused repo costs nothing. | *Choose a different model…*, type `meta-llama/Llama-3.2-1B` → Validate fails at the trust policy |
| **A model that can't run here** — not an MLX model, an unsupported architecture, weights too big for this Mac's memory, no free disk | A **preflight** runs before anything downloads: model format, architecture support, size against RAM, free disk space. | The **Validate** step of any launch |
| **Corrupted or substituted bytes** in transit | Every downloaded file is **verified against Hugging Face's content hash**. | **Advanced ▸ verify content hash** |
| **A repo changing under you** — the owner re-uploads or fixes it, or an attacker compromises it, after you validated it | Every model is **pinned to one exact commit**. A re-download fetches that commit, never whatever `main` is now. A shipped model's pin is verified; a mismatch or a missing commit **fails hard and never falls back to `main`**. | **Pin** step; **Advanced ▸ simulate stale shipped pin**; **Simulate external deletion + redownload** |
| **Downloads filling the disk** — a huge model, or many of them | A **cache cap** refuses further downloads once the model cache has reached the limit. (It measures the whole model cache folder, not just this app's downloads.) | **Advanced ▸ cap total cache size** |
| **Losing the pin when the model is deleted** | Pins are stored *outside* the model cache, so they survive the very deletion they protect against. | **Simulate external deletion + redownload** |
| **An unreviewed version replacing a vetted one on update** | A model *you* chose updates only when *you* say so. A model the *developer* shipped moves only to a commit the developer names — never "latest". Either way the new version is fetched and verified first and switched to last, so a failure changes nothing; inference pauses for the switch; and you can roll back. A newer app release always wins over an older runtime update. | **Model & pin** panel; **Simulate a newer app build** |
| **A paired adapter or helper model slipping past the checks** | The adapter and draft model are governed by the same policy, pins and verification as the main model. If one is denied or fails, the run **fails** instead of quietly using the plain model. | **Model pairing…** with **simulate stale shipped pin** on |
| **Deleting the wrong files** during cleanup | Removal refuses the version in use and deletes only files no other version uses. | **Versions on disk** |
| **An app that can do more than it needs** | The `.app` is sandboxed and asks for one entitlement beyond that: outbound network. It has no file access. | The signed `.app` (Xcode Run) |

## Pins, updates and old versions

A **pin** is the exact version of a model, so the content you validated is the content you keep using.

**A model you chose** is pinned to the version you first downloaded. In the **Model & pin** panel, **Check for
update** shows what would change (files and sizes) and downloads nothing; **Update** fetches the new version, and
only if that succeeds does the pin move — a failure changes nothing. **Roll back** returns to the previous version
instantly (its files are still cached). To try it, use the demo on the [launch screen](#the-launch-screen)
(**Choose a different model… ▸ Use gemma-3-270m-4bit ▸ Demo: pretend I downloaded this a while ago**).

### Updating a built-in model without a new app release

A model the app ships is different, because a different party vouches for the version: for a model you
chose, your click is the approval; for a built-in one, **the app developer** reviewed one specific version.
So "update to whatever is newest" is never allowed — the SDK moves a shipped pin only to a **full commit hash
the app names**, and where the app learns it (its server, a config push) is the app's business, as is
authenticating it. Here `HostUpdateFeed` stands in for that server. Choose **Test a developer update** on the launch screen and use **Check for
updates**, **Update**, and **Back to the version this app shipped**.

- The update is saved with the version *this build* shipped, so it survives a relaunch — but **a newer app
  build always wins**. To see that: (1) choose **Test a developer update**, then **Check for updates → Update**;
  (2) click **Change model**; (3) open **Advanced**, tick **Simulate a newer app build** (it pretends the
  developer released a new app version whose built-in Gemma is the newer one), and click **Test a developer
  update** again. The update from step 1 was made under the older build, so it is discarded; Gemma opens as
  "shipped with this app" at the newer version, with nothing left to update. (The Advanced note spells out the
  next step, and adapts if you haven't applied an update yet.)
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
