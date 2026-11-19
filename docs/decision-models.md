# Decision models (Jev) — `lab.decide`

Decision models answer typed questions (yes or no, one of several, a scale) instead of writing text. A separate feature of the SDK, used with `lab.decide`.


> **Reach for this when** your app needs a small, fixed decision about some text — which route,
> which team, does this need the web, is this sensitive — and you'd otherwise ask a chat model and
> parse its reply.
>
> **New to decision models?** They behave nothing like a chatbot. Read
> [Decision models (Jev) in your app](https://thisbrain.ai/locallm/jev.html) first (what they
> are, for people who know chatbots, with links to TypeSafe's and others' docs), then
> [JevDK's developer's guide](https://github.com/ancientcomputing/jevdk) for the workflow.
>
> **Examples that use it:** [JevDK](https://github.com/ancientcomputing/jevdk).

A **decision model** (a *decider*) takes one input and a few typed questions, and answers each
with one of the options you allowed plus a probability for every option. It writes no text.
TypeSafe's **Jev** is the original; the SDK uses Jev's vocabulary and asks the same questions of
four backends:

| Decider | Runs | Module | OS | `Decision.fidelity` |
|---|---|---|---|---|
| **OpenJev** (`OpenJevDecisionProvider`) | On the Mac, on an MLX model | Inference | macOS 27 | `.tokenScored(calibrated:)` |
| **TypeSafe Jev** via OpenRouter (`JevDecisionProvider(.openRouter(key:))`) | Hosted | Remote | macOS 26+ | `.native` |
| **Featherless Simple Jev** (`.featherless(key:)`, `.featherlessDemo()`) | Hosted | Remote | macOS 26+ | `.tokenScored(calibrated: false)` |
| **OpenAI Decisions** (`JevDecisionProvider(.openAI(key:))`, `openai:gpt-6-luna`; since SDK 2.3) | Hosted | Remote | macOS 26+ | `.native` |

`lab.decide` and the decision types are in Core and work on macOS 26. The deciders live where the
table says: OpenJev in Inference, the hosted ones in Remote.

## Register a decider and route to it

Deciders are registered and routed separately from chat models (they never appear in a chat
model picker), with their own scheme namespace:

```swift
import LocalLMLabSDKInference   // OpenJev
import LocalLMLabSDKRemote      // hosted Jev

try lab.models.register(decision: OpenJevDecisionProvider(mlx: mlx))        // the MLXModelProvider you already use
lab.models.route(decision: "support", to: ModelID("openjev:mlx-community/Qwen3-4B-4bit")!)

// or hosted — off until you register one; questions and input are then sent to that service
try lab.models.register(decision: JevDecisionProvider(.openRouter(key: key)))
lab.models.route(decision: "support", to: ModelID("openrouter:typesafe/jev-1.13")!)
```

`ModelRegistry` also has `replace(decision:)`, `removeDecisionProvider(scheme:)`,
`modelID(forDecision:)`, `decisionProvider(for:)` and `decisionAvailability(for:)` (a
`ModelAvailability`, e.g. not downloaded or needs a key). Decision routes are saved by
`lab.snapshot()` like chat routes.

## Ask

```swift
let d = try await lab.decide(route: "support", state: .text(message), questions: [
    .choice("team", "Which team should handle this message?", criteria: [
        "billing": "payments, invoices and refunds",
        "technical": "bugs, outages and product errors",
        "account": "profile, login and subscription changes",
    ]),
    .noul("refund", "Does the customer explicitly ask for money back?"),
    .score("urgency", "How urgent is it?", criteria: ["can wait", "soon", "now"]),
])

d.choice("team")      // ChoiceAnswer: .choice "technical", .confidence, .probabilities ["billing": …, …]
d.noul("refund")      // Double: probability of yes
d.score("urgency")    // ScoreAnswer: .score 1.6 (expected level, 0-based), .level, .probabilities, .legend
d.fidelity            // .native or .tokenScored(calibrated:)
d.modelID, d.latency, d.usage   // usage: tokens and cost, from hosted backends
d.isRefused("refund")  // true if the backend declined that question (OpenAI Decisions only)
```

- **A backend can decline a question** (since SDK 2.3). Only OpenAI's Decisions API does this today. A
  refused id is in `d.refusals` and has no answer, so check `d.isRefused(id)` before reading it
  and take the cautious path. `lab.evaluate` counts a refusal as a miss.

- **Question kinds** use Jev's names: `noul` (yes / no; the answer is P(yes)), `choice` (one of
  several, each with an optional description), `score` (an ordered scale described in words).
  Ids are what your code reads; `instructions` is what the model reads.
- **The input** is `state`: `.text(String)`, or `try .encoding(someEncodable)` to send JSON. For
  a conversation, send the last few turns, not the whole history.
- **There is no system prompt.** Hosted Jev has none, so context there never reaches it; put
  anything a question needs in `state` or in the question. Then the same questions behave the same
  on every backend.
- **Validated before anything is sent** (unique ids, at least two options, the backend's
  `DecisionLimits`) and checked after (every question answered, the right kind, probabilities in
  0–1). Errors are `DecisionError`: `.invalidRequest`, `.noRoute`, `.unavailable`,
  `.malformedAnswer`, `.backend` (a hosted service's own message), `.pairing`.
- **Input size.** `DecisionLimits.maxStateCharacters` makes an over-long input fail before it's
  sent, telling you to shorten it. The Featherless demo preset sets 6,000 characters.
- **One route per call.** To ask some questions locally and others hosted, make two calls; the
  split (and the order: a local privacy question first, say) is your app's policy.

## Confidence, fidelity and calibration

`.native` probabilities come from a model trained to make decisions (TypeSafe). `.tokenScored`
ones are read off an ordinary language model — how likely it was to say each option's label —
and on a small model they're often 100% even when it's wrong. Don't put tight thresholds on
uncalibrated `.tokenScored` answers.

For a local decider you fit a **calibration** on your own marked answers and pass it in;
`fidelity` then says `.tokenScored(calibrated: true)`. It holds for one model, revision, wrapper
and kind of question, so the SDK ships no fitted values. **The usual way is to fit it in JevDK
and use the result in your app**, with no fitting code of your own:

```swift
// 1. In JevDK: mark answers, Calibrate… → Fit calibration, then File → Export Questions….
//    The .decisions.json carries the calibration with the questions it was fitted for.
let set = try DecisionQuestionSet(contentsOf: url)
let openjev = OpenJevDecisionProvider(mlx: mlx, tunedWith: set)       // applies set.tuning?.calibration

// 2. Or copy the snippet (Calibrate window → Copy code): the values plus the system instructions
//    they were fitted with — the calibration only holds with the same wrapper.
let openjev2 = OpenJevDecisionProvider(mlx: mlx,
    wrapper: OpenJevWrapper(system: "…", inputLabel: "…"),
    calibration: DecisionCalibration(noulTemperature: X, choiceTemperature: Y, scoreTemperature: Z))
// X, Y, Z: the Temperature column of JevDK's Calibrate window (yes/no, choice, score; 1.0 = no change).
```

To fit in code instead (for example from `lab.evaluate`'s `samples`):

```swift
let cal = DecisionCalibration.fit(samples)            // [DecisionCalibration.Sample], from marked answers
cal.measure(samples)                                   // accuracy, expectedCalibrationError, logLoss
```

Calibration is temperature scaling per question kind: it never changes which answer wins, only
how sure it says it is.

## OpenJev: the local decider

- **How it decides:** one forward pass per question, no generation. Each option gets a
  single-token label (`A`–`Z`, `0`–`9`, `Yes`/`No`) and OpenJev reads the probability of each
  label. The input is processed once and shared by all the questions, so four questions on Qwen3
  4B take about 150 ms. That's also why its limits are smaller than hosted Jev's: up to 26 choice
  options, 10 score levels, 64 questions a call.
- **The wrapper.** Each question goes to the model inside a fixed prompt (`OpenJevWrapper.default`:
  *"You answer questions about a piece of text…"*, the input labelled `Text`), chosen with the
  SDK's evaluation set. You can pass your own `OpenJevWrapper`, but the wording moves answers as
  much as your questions do, so change it only with your answer set to check against.
- **Which model.** A small **dense** instruct model: Qwen3-4B-4bit is the tested default (2.3 GB).
  Qwen3-1.7B is too weak. **Not a mixture-of-experts model**: an MoE model's probabilities
  shifted with how the prompt was split. `openjev.warnings(for:)` returns
  `.mixtureOfExperts` for one (a warning, not a block).
- **Only models the SDK downloaded count.** Availability follows `MLXModelProvider`: a copy
  another tool put in the Hugging Face cache reads as not downloaded until the SDK has verified it.
- **Debugging:** `decideWithDiagnostics(_:using:)` also returns each question's exact prompt,
  how much probability fell on the allowed labels (`labelMass`; low means the model wanted to
  answer something else, so reword the question) and its timing.

## Hosted Jev

`JevProviderConfig` presets set the endpoint, scheme, fidelity, limits and model list:
`.openRouter(key:)` (TypeSafe's `typesafe/jev-1.13`; `typesafe/jev-router` picks a model for
you), `.featherless(key:)` and `.featherlessDemo()` (free, rate-limited, no key).
`validated()` applies the chat providers' checks (https, no line breaks in keys). Questions and
choice options keep your order on the wire, JSON `state` is sent as JSON, and `d.usage` carries
the tokens and cost. Like other remote providers, it's off by default and your UI should say
where inputs are sent.

**OpenAI's Decisions API (since SDK 2.3)** uses the same provider with a different wire format,
`JevProviderConfig`'s `wire: .openAIDecisions` (the other presets use `.jev`):

```swift
try lab.models.register(decision: JevDecisionProvider(.openAI(key: key)))
lab.models.route(decision: "support", to: ModelID("openai:gpt-6-luna")!)
```

- `.openAI(key:)` offers `openai:gpt-6-luna` only, with `.native` fidelity: the probabilities are
  OpenAI's own. Its limits are `DecisionLimits.openAIDecisions` (400 questions, 255 choice
  options, 10 score levels), checked before anything is sent.
- `.openAICompatibleDecisions(baseURL:auth:models:)` is for any other server that speaks the same
  API (Fireworks, Vercel AI Gateway, LocalAI): requests go to `baseURL` + `/decisions`. For a
  server that token-scores a general model, pass `fidelity: .tokenScored(calibrated: false)`.
- `probe(for:timeout:)` checks the key and model with one `GET …/models`, never a decision:
  `.needsCredential` for a rejected key, `.unsupportedModel` for a model the server doesn't list,
  `.providerError` when it's unreachable or slow (8 seconds by default). On the Jev wire it
  returns the local check only.
- It's the one backend that can decline a question: check `d.isRefused(id)` (above).

## A decider and your chat model: one model or two

The pattern the SDK is built for is two models per feature: a decider for the typed choices (does
this need the web, which tool, is it sensitive) and a chat model for the text, both on the Mac.

- **Share one model.** Route OpenJev and the chat route to the same dense MLX model: one copy in
  memory. The low-memory option; a big chat model makes a slower decider than a small one.
- **Two models resident.** `MLXModelProvider` keeps one local model loaded by default
  (`residentModelLimit: 1`), so a decider asked every turn would evict the chat model. Pair them:

  ```swift
  lab.models.route(decision: "triage", to: ModelID("openjev:mlx-community/Qwen3-4B-4bit")!)
  lab.models.route("writer", to: ModelID("mlx:mlx-community/Qwen3.8-27B-4bit")!)
  let pairing = try await lab.models.pair(decision: "triage", generator: "writer")
  // DecisionPairing: deciderBytes, generatorBytes, budgetBytes, residentModels, note
  ```

  `pair(decision:generator:)` checks the two models' weights together against the memory budget
  (`maxWeightFractionOfRAM`, 70% of RAM by default), raises the model cache's capacity to hold
  both (never lowers it) and loads them. Doesn't fit: `DecisionError.pairing` with the numbers,
  and nothing changes. A shared model counts once (and is refused if it's MoE); a hosted decider
  or a non-MLX chat model (Apple's on-device model) needs only one. On a 64 GB Mac, pairing a
  Qwen3 4B decider with Qwen3.8 27B took 2.3 s, and the next decision ran in 63 ms with no reload.

- **Still in progress:** keeping the pair loaded under memory pressure (the cache can still
  unload all but the most recent model then); a measured pair on a 16 GB Mac; and loading
  text-only uses of vision-capable models with the faster text implementation.

## From JevDK to your app: question sets, answer sets, `lab.evaluate`

Questions are the work, so the SDK carries them from testing to shipping intact:

```swift
// The questions exactly as tested in JevDK (File → Export Questions…), with the model, revision,
// wrapper and calibration they were tested with.
let set = try DecisionQuestionSet(contentsOf: Bundle.main.url(forResource: "support.decisions", withExtension: "json")!)
let openjev = OpenJevDecisionProvider(mlx: mlx, tunedWith: set)     // the tested wrapper + calibration
try lab.models.register(decision: openjev)
let decider = set.tuning?.model ?? ModelID("openjev:mlx-community/Qwen3-4B-4bit")!
lab.models.route(decision: "support", to: decider)
if let why = openjev.tuningMismatch(for: decider) { log(why) }      // a different model or revision on this Mac
let d = try await lab.decide(route: "support", state: .text(message), questions: set.questions)

// In CI: score any decider against your answer set (CSV: input, then one column per question id).
let answers = try DecisionAnswerSet(csv: String(contentsOf: answersURL, encoding: .utf8))
let result = try await lab.evaluate(route: "support", questions: set.questions, answerSet: answers)
#expect(result.score("refund")!.accuracy >= 0.95)
```

- `DecisionQuestionSet` is JSON in Jev's question shape (`{id, type, instructions, criteria}`);
  a file from a newer SDK, or with questions that couldn't be asked, is refused.
- `DecisionAnswerSet` matches answers leniently (yes/no as Yes, No, true, false, 1, 0; a choice
  by key; a score by level number or text); `problems(for:)` lists cells that don't fit, and
  `evaluate` refuses such a set rather than skipping rows.
- `DecisionEvaluation` gives accuracy per question, the misses, mean confidence when right and
  when wrong (a big gap means a threshold can catch the misses), calibration error, and
  `samples` for `DecisionCalibration.fit`.

## Serving decisions over HTTP: `jev-serve`

To use a local decider from another process or language, run the
[jev-serve](https://github.com/ancientcomputing/jevdk) example. It answers hosted Jev's API, OpenRouter's
`POST /api/alpha/decisions` and Featherless's `POST /v1/classifier`, with OpenJev on this Mac, so
existing hosted-Jev client code switches by changing its base URL. It serves the setup you tested
in JevDK (**File → Export Server Config…**): each model pinned to its tested revision (downloaded
if missing), with its wrapper and calibration; loopback by default, an optional bearer token.
Responses add `"fidelity": "tokenScored"` and `"calibrated"`, which `JevDecisionProvider` reads.

The wire format is `JevWire` (Core), used by both the client (`JevDecisionProvider`) and the
server:

```swift
let wire = try JevWire.decodeRequest(body)                          // model?, DecisionRequest (order kept)
try wire.request.validate(against: provider.limits)
let decision = try await provider.decide(wire.request, using: id)
let response = try JevWire.encodeResponse(decision, model: repo, request: wire.request)
```

## Decisions that need your product's knowledge

A decider sees only `state` and the questions (there's no system prompt), so knowledge it needs,
such as which part of your software a bug report concerns and who owns it, has to come through
those, or stay in your code:

- **Classify, then map in code** (usually best): ask which *component* the input is about, with the
  product knowledge in each option's description, and map component → team with an ordinary table.
  Ownership changes then touch the table, not the questions or the calibration.
- **Knowledge in the options:** describe each team by what it owns (`"payments": "billing,
  invoices, the Checkout module"`). Up to 26 options locally; hosted limits vary by backend (255 on OpenAI's Decisions API).
- **Knowledge in the input:** send the context your app already has as JSON alongside the input,
  `try .encoding(Ticket(report:screen:stackTraceModules:))`. Keep it short (`maxStateCharacters`
  on hosted backends; longer inputs are slower locally).
- **Retrieve first:** for a large knowledge base, select the relevant passages in your app (or with
  your chat model) and send only those.

Don't put the knowledge in an `OpenJevWrapper`'s system text: hosted backends never see it, and a
calibration only holds for the wrapper it was fitted with. Full walkthrough with code:
[JevDK's guide](https://github.com/ancientcomputing/jevdk).

## Writing questions that work

- Only ask what a model can judge from the input and general knowledge — **never current
  facts**. "Does this user query need live data?" is fine; "has this changed recently?" isn't.
- Ask about **what the text says**: "Does the customer *explicitly* ask for money back?" beats
  "Does the customer want a refund?"
- Prefer noul and choice; small local models are weakest on score scales.
- Give choice options short descriptions, not just names.
- Check every wording on the model you'll ship, against your answer set. Different models
  prefer different wordings.
