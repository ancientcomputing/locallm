# os-matrix — one SDK build for macOS 26 and macOS 27

**What this example is for:** showing how little OS-version branching your app actually needs in
order to support both macOS 26 and macOS 27 from a single shipped binary. It is deliberately *not*
a tour of what the SDK can do with a model — it does almost nothing with the models themselves (one
tool-calling turn) so that the 26/27 pattern isn't buried under unrelated feature code. Almost every other
example in this repo targets macOS 27 only; this is the one example that targets both.

Run it on a macOS 26 machine and a macOS 27 machine. Same binary, different behaviour — no
`#if os`, no separate build, just **one** `#available` check, made **once**, at provider
registration. Everything downstream of that check — `makeSession`, `respond`, `events`,
`contextBudget`, the connector tools — is identical code that runs the same way regardless of
which OS it's actually on.

## Requirements

- **Apple Silicon**, macOS **26 or 27**.
- **Xcode 27 to build** — `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
  The binary *runs* on macOS 26, but it's compiled with the macOS 27 SDK (the macOS-27-only
  symbols are weak-linked). An older Xcode fails with `'v27' is unavailable`.
- **Apple Intelligence enabled** (System Settings → *Apple Intelligence & Siri*). Without it,
  `system` reports unavailable and the prompt step errors — the availability table still prints.
- **Network** for the `getWeather` tool (it calls Open-Meteo, a public API — no key). Offline,
  the tool returns an error and the run continues.
- No code signing or permission prompts — `ClockTool` and `WeatherTool` need no TCC access.

## Run

`Package.swift` resolves the SDK as a binary dependency, building against `1.0.0-beta.4` by
default (set `LOCALLM_SDK_VERSION` in a shell to pin another release — see
[`../README.md`](../README.md#building--running-an-sdk-example)):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run OSMatrix
```

> **`error: package … tools version 6.4.0 … installed version is 6.3.3`** — your Swift
> toolchain is older than the one this manifest was cut with. The tools version tracks the
> toolchain (Xcode / swift.org), not macOS. The manifest uses no 6.4-only features, so the
> quick fix is to edit line 1 of `Package.swift` down to your installed version
> (`// swift-tools-version: 6.3`). The alternative is a newer toolchain — a standalone Swift
> 6.4 toolchain from swift.org runs fine on macOS 26; no OS upgrade needed.

### In Xcode

A command-line tool, so there's no `.xcodeproj` to ship (unlike the SwiftUI examples):
**File ▸ Open → `Package.swift`**, pick the **OSMatrix** scheme, Run — in **Xcode 27 or newer** (macOS 27 target → an older Xcode fails with `'v27' is unavailable`). Output
goes to the Xcode console. No arguments needed for the default run; for `--download <hf-repo>` add both entries
under **Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments**. No signing setup — a plain CLI tool
signs ad-hoc automatically. The point of the example is running the *same* build on a macOS 26
and a macOS 27 machine, so you'll still want a terminal (or two Macs) to see the contrast.

### On macOS 26

```
Running on macOS 26.x.x

Model families:
  system                                     available
  pcc                                        requires macOS 27
  claude:sonnet5                              requires macOS 27
  mlx:mlx-community/Qwen3-4B-4bit             requires macOS 27

  (claude, mlx, pcc need macOS 27 — a picker shows these as disabled rows)

Asking the on-device model (with tools) …
→ It's 3:42 PM. Tokyo is 18°C and clear.

macOS 26: open-weight (MLX) model download is unavailable — needs macOS 27.
```

**Why the `claude:sonnet5` row appears even though this example never adds Claude:** it's included
on purpose, as a deliberate fourth data point. The table queries `lab.models.availability(for:)`
for four model IDs, but this package never links `LocalLMLabSDKClaude` and never registers a
`ClaudeModelProvider` anywhere (see "Adding Claude" below — that section is the *first* place
Claude actually gets added to anything, in a different, macOS-27-only target). On macOS 26 that
shows up as `requires macOS 27` — the same thing `pcc` shows, since it also isn't registered on 26.
The **On macOS 27** section right below shows what happens once that OS gate is satisfied: the
`claude` row keeps failing, but the real, now-visible reason turns out to be different from `pcc`'s.

### On macOS 27

Same binary, no rebuild — this is a real run on the same Mac, same `swift run OSMatrix`:

```
Running on macOS 27.0.0

Model families:
  system                                     available
  pcc                                        available
  claude:sonnet5                             unavailable — No model provider registered for scheme 'claude'
  mlx:mlx-community/Qwen3-4B-4bit            not downloaded

Asking the on-device model (with tools)…
→ It's 9:18 AM PDT on Saturday, September 12, 2026. In Tokyo, the weather is partly cloudy with
  71°F (feels like 77°F), 90% humidity, and a 2 mph wind. The 7-day forecast includes drizzle,
  mainly clear skies, thunderstorms, and rain showers.

Open-weight (MLX) models are available on macOS 27. Download and run one with:
  swift run OSMatrix --download mlx-community/Qwen3-4B-4bit
In code that's `try await lab.models.startDownload("<hugging-face-repo-id>")` — an async call
your app makes (e.g. from a "Download" button). There is no CLI for it in the SDK;
`lab.models.downloads` is the observable a picker binds to for a progress bar.
```

Compare this directly against the macOS 26 block above — same four-row table, same code path,
different rows:

- **`system`** — `available` on both. The one row that never changes.
- **`pcc`** — `requires macOS 27` on 26, `available` on 27. `PCCModelProvider` is registered
  on 27 (inside the `#available` block) and not registered at all on 26.
- **`mlx`** — `requires macOS 27` on 26 (not registered there either), `not downloaded` on 27
  (registered, but this specific machine hadn't fetched `Qwen3-4B-4bit` yet — a machine that
  already has it cached would show `available` here instead, same as `pcc`/`system`).
- **`claude`** — `requires macOS 27` on 26, but **not** `available` on 27 — it's
  `unavailable — No model provider registered for scheme 'claude'`. This is the concrete payoff
  of the note above: on macOS 26 the `claude` scheme is OS-gated (`.requiresOS`); once that gate
  is satisfied on macOS 27, `availability(for:)` reveals the *other* reason it's unusable — no
  `ClaudeModelProvider` was ever registered, because this example never links
  `LocalLMLabSDKClaude` at all. Two different `.unavailable` reasons, same scheme, depending on
  which one the OS check still leaves standing — see "Adding Claude" below for what registering
  it for real would take.

The model's weather/time answer will read differently on your own run (different day, different
weather) — the table above it is the part worth comparing run to run.

### `--download` — pull an open-weight model (macOS 27 only)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift run OSMatrix --download mlx-community/Qwen3-4B-4bit
```

This calls `try await lab.models.startDownload("mlx-community/Qwen3-4B-4bit")` — an `async`
method on `lab.models` (`ModelRegistry`). **There is no CLI for it in the SDK**; you call it
from Swift (this example runs it when you pass `--download`; a real app calls it from a
"Download" button). It fetches the MLX-format weights from Hugging Face (2–5 GB) into the
local cache. After it resolves, that `mlx:` id reports `.available` and you can route a
session to it:

```swift
lab.models.route("chat", to: ModelID("mlx:mlx-community/Qwen3-4B-4bit")!)
let session = try lab.makeSession(route: "chat")
```

`lab.models.downloads` (`[ModelID: Double]`, observable) is what a picker binds to for a
progress bar. On macOS 26, `--download` prints "needs macOS 27" and exits.

The availability table this CLI prints — and the `--download` progress — are exactly what
`Components`' `ModelPickerView` renders as a real settings screen (badges, on-disk sizes,
progress bar, "Add from Hugging Face"); see
[`docs/sdk-guide.md` §11](../../docs/sdk-guide.md#11-components-prebuilt-swiftui-mcp-servers--the-model-layer).

## The four scenarios, and where each shows up here

| # | Scenario | In this example |
|---|---|---|
| 1 | **Same code, both OSes** | `lab.makeSession(route:) → session.respond(to:)` — identical on 26 and 27. |
| 2 | **A macOS-27-only feature** | The open-weight (MLX) model download, gated by `if #available(macOS 27, *)`. |
| 3 | **A feature that works on both** | `ClockTool()` + `WeatherTool()` — the ready-made connector tools are all `@available(macOS 26)`. |
| 4 | **More on 27 than on 26** | `SystemModelProvider` is registered always; `PCCModelProvider` + `MLXModelProvider` only inside the one `#available` block. `lab.models.availability(for:)` reports the rest `.requiresOS("macOS 27")`. |

The `#available` check appears **once**, at registration. Everything downstream —
`makeSession`, `respond`, `events`, `contextBudget`, the connector tools — is the same code.

## Adding Claude

`LocalLMLabSDKClaude` depends on `ClaudeForFoundationModels`, which requires macOS 27. Linking
it forces a **27 deployment target** on whatever target links it — so you can't add it to
this `.macOS("26.0")` package directly.

Two ways to offer Claude:

1. **Your whole app is macOS 27+.** Add the `LocalLMLabSDKClaude` binary target (from the same
   SDK release), `import LocalLMLabSDKClaude`, and register
   `ClaudeModelProvider(auth: .apiKey(key))` alongside the others.

2. **Your app runs on macOS 26 too** (this example's situation). Put the Claude path in a
   separate macOS-27-only executable — a background helper the main app runs, or a 27-gated
   bundle it loads at runtime. The main app stays `.macOS("26.0")`; the SDK's public API
   (`ModelProvider`, `makeSession`, `LocalLMLabSession`) is identical on both sides of that
   boundary, so only the *registration* differs.
