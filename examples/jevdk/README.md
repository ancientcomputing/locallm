# JevDK

A playground for **decision questions**: try out the questions your app will ask a decision
model (a "decider"), and see how it answers before you put them in code.

```bash
swift build -c release
.build/release/JevDK
```

Needs an Apple-silicon Mac, macOS 27 and Xcode 27 (Swift 6.4). `Package.swift` builds against SDK
`2.0.0-dev` with no further setup (the decision API is new in 2.0): `LocalLMLabSDKCore`,
`LocalLMLabSDKRemote` and `LocalLMLabSDKInference` (the MLX runtime) come from that GitHub Release.
No Metal Toolchain needed; the prebuilt Inference xcframework bundles the compiled shaders. To
build against another release, set `LOCALLM_SDK_VERSION` (see [the examples README](../README.md)).

**New to decision models?** Read [the developer's guide](GUIDE.md) first: what a decider is,
when to use one, and the workflow from writing questions to shipping them, with a worked example.

## The idea

A chat model takes one prompt and writes one reply.

A decider takes **one input** (a customer message, a user query, a review) and answers **a few
fixed questions** about it. Each answer is one of the options you allowed, plus how sure the model
is. It writes no text.

| Input | Question | Answer |
|---|---|---|
| "Nothing loads since this morning, my whole team is stuck." | Which team should handle this? (billing / technical / account) | **technical** 100% |
| | Is the customer blocked from using the product right now? | **Yes** 96% |
| | Does the customer explicitly ask for money back? | **No** 97% |

Your app then acts on the answers in plain code: send it to the technical team, mark it urgent,
don't open a refund.

**Batch** asks the same questions about many inputs at once. Think of a spreadsheet: one row per
input, one column per question, each cell an answer. That's where you see the pattern: the
question that's right on nine messages and wrong on the tenth, or the wording that works better
than another.

## Two-minute walkthrough

1. **Examples → Customer support.** The left side fills with four questions. The right side
   has an input box with sample messages above it.
2. **Click a sample** ("Double charge", "App outage", …). It runs straight away; each question
   shows its answer, how sure the model is, and a bar for every option.
3. **Change a question** on the left, e.g. reword "Is the customer blocked…", and click the
   same sample again to see if the answer moves.
4. **Switch to Batch** and press **Ask all**. Every sample runs; the grid shows all the answers
   at once. Hover a cell to see every option's probability.
5. **Backends** (toolbar) turns on hosted deciders next to the local model, so each cell shows
   one answer per decider, tinted where they disagree.

**JevDK remembers your workspace**, like Prompt Playground keeps your last prompt: the
questions and system instructions, the input and batch list, your marked answers, calibration
and the selected model come back on the next launch. Switch the model or a backend, press
**Ask** or **Ask all**, and you're re-testing the exact same scenario. Results aren't kept; run
again. **Examples** asks before replacing work you've changed, and can save it to a file first.

Your own questions: **Add question** on the left. Pick **Noul** (yes / no), **Choice** (one of
several options) or **Score** (a scale). Give it a short name (what your app reads), the
question text (what the model reads), and for Choice / Score the options. **Duplicate** a question
to try a second wording side by side. **⌘S / ⌘O** saves and opens a question set with its inputs.

## Comparing models: the results CSV

JevDK doesn't tell you which model to use; your questions and your answers do. After a batch,
**Results CSV** appends the run to a CSV file: one row per input × question × backend. Run the
same batch with another model (or quantization, wrapper or question wording) and append again;
the runs line up in one spreadsheet. The first click asks for a file; later clicks append to it
(**Append to another CSV…** to switch). A file with a different header is never touched.

| Columns | |
|---|---|
| Run | `run_id` (date and time the batch started, plus a short suffix), `saved_at`, `app`, `sdk_version`, `machine`, `question_set` |
| Model | `backend` (local / featherlessDemo / featherless / openRouter), `model`, `model_revision`, `model_size_gb`, `moe`, `wrapper_label`, `wrapper_system`, `calibrated` |
| Item | `input`, `question`, `question_kind`, `question_text` |
| Result | `expected` (your marked answer), `answer`, `correct` (yes / no), `confidence`, `probabilities`, `label_mass` |
| Cost | `question_ms`, `decision_ms`, `input_tokens`, `cost_usd` (hosted, per decision) |

Mark correct answers before saving so `expected` and `correct` are filled; then a pivot table
of `correct` by `model` and `question` is your per-question accuracy, and `question_ms` /
`decision_ms` your speed. Headless: add `--csv <file>` to `--check` or `--check-remote`.

## Calibrating for your app

A small local model often says 100% even when it's wrong. Calibration softens its confidence so
"80% sure" means right about 80% of the time; it never changes which answer wins. It depends on
the model, its version, the system instructions and your kind of questions, so you fit it here,
for your app:

1. **Batch** with the local backend on: paste a few dozen inputs like the ones your app will see,
   **Ask all**.
2. Under each cell, **mark…** the correct answer. Every backend's line then shows ✓ or ✗, so
   you also get each backend's accuracy on your own questions.
3. **Calibrate…** → **Fit calibration**. It shows the calibration error and log-loss before →
   after for each kind of question (aim for 30+ marks per kind).
4. Turn on **Show local results calibrated** to see what your app will see. It's saved with
   the question set (⌘S). If you change the model or the system instructions, JevDK flags the
   calibration until you refit.

## Taking it to your app

- **File → Export for App…** writes a `DecisionQuestionSet` JSON file: the questions plus the
  model, revision, wrapper and calibration you tested. Bundle it and load it with
  `DecisionQuestionSet(contentsOf:)`; `OpenJevDecisionProvider(mlx:tunedWith:)` applies the
  wrapper and calibration.
- **Answer set → Export** (Batch toolbar, or the File menu) saves your inputs and marks as CSV:
  an `input` column and one column per question. **Import** loads one, e.g. from a spreadsheet.
  In your app's tests, `lab.evaluate(route:questions:answerSet:)` scores a backend against it.

See [GUIDE.md](GUIDE.md) step 8.

## Reading the results

- **The percentage** is how sure the model is, not how likely it is to be right. Small local
  models often say 100% when they're wrong. TypeSafe's hosted Jev is the only decider so far
  whose numbers behave like real probabilities.
- **"Off format"** means the model wanted to answer something other than the options you
  allowed. The question probably needs rewording.
- **Show prompt / Show request** shows exactly what the decider received.
- **Timing** per input is roughly what a router would add to each user turn.

## Writing questions that work

From the SDK's own OpenJev evaluation (a labelled test set scored on several local models):

- Prefer **Noul** and **Choice**. Small models are much worse on **Score** scales.
- Give choice options a **short description**, not just a name.
- Plain, direct questions work well ("Does this user query need live data?").
- Ask about **what the text says**: "Does the customer *explicitly* ask for money back?" beats
  "Does the customer want a refund?"
- Only ask what a model can judge from the input and **general knowledge**: nothing that
  depends on current events.
- **Put context in the question.** Hosted deciders don't see the system instructions, so "This
  post was made on a gardening forum. Which problem does it have?", not a forum description in
  the instructions.
- Check a wording on the model you'll ship. Different models prefer different wordings.

## Choosing a decider

- **Local** (toolbar picker; **Models** to change): MLX models the SDK has downloaded and
  verified. **Models** has three tabs: **Installed** (use or remove), **Recommended** (small
  dense instruct models, which ones were tested as deciders) and **Search Hugging Face** (MLX
  models, most downloaded first). Select one, **Check** (the SDK confirms the repo is reachable,
  MLX format, a supported architecture, and fits this Mac's memory and disk), then **Download**:
  the SDK downloads and verifies it. Copies another tool put in the cache are offered with
  **Verify** instead. `Qwen3-4B-4bit` is the current pick: about 150 ms for four questions,
  2.6 GB. Mixture-of-experts models are flagged; use them for chat, not for deciding.
- **Hosted** (Backends): the **Featherless demo** is free and needs no key (rate-limited);
  **Featherless** and **OpenRouter · TypeSafe** take a key, stored in the Keychain. When any is
  on, the status bar says where inputs are sent.

## For SDK developers

JevDK is built only on the SDK's public decision API, so it's also a reference client for it:

- **Local:** LocalLMLabSDKInference's `OpenJevDecisionProvider`, wrapping `MLXModelProvider`
  (which also lists, checks and downloads models). JevDK builds it with the editor's wrapper
  (**System instructions** and what the input is called), so the wrapper stays editable here;
  apps get `OpenJevWrapper.default`, chosen with the SDK's evaluation. Local runs call
  `decideWithDiagnostics` for **Show prompt** and the off-format warning, after validating
  against the provider's limits as `lab.decide` would.
- **Hosted:** LocalLMLabSDKRemote's `JevDecisionProvider` through `lab.decide`.
- `OpenJevKit` holds only the playground's own types: the editor model, saved files (earlier
  yes/no / scale names still open), and result rows.

Headless checks:

```bash
.build/release/JevDK --check "Customer support" mlx-community/Qwen3-4B-4bit
.build/release/JevDK --check-remote "Customer support" openRouter
```

`--check` needs a model the SDK has downloaded (or verified). `--check-remote` takes
`featherlessDemo`, `featherless` or `openRouter`, with keys from the environment or a
git-ignored `./.env` (`OPENROUTER_API_KEY`, `FEATHERLESS_API_KEY`), never printed. The window
hasn't been driven by a test.
