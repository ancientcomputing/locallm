# os-matrix — one SDK build for macOS 26 and macOS 27

Run it on a macOS 26 machine and a macOS 27 machine. Same binary, different behaviour — no
`#if os`, no separate build, just one `#available` check at provider registration.

## Requirements

- **Apple Silicon**, macOS **26 or 27**.
- **Xcode 27 beta to build** — `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
  The binary *runs* on macOS 26, but it's compiled with the macOS 27 SDK (the macOS-27-only
  symbols are weak-linked). A stable Xcode fails with `'v27' is unavailable`.
- **Apple Intelligence enabled** (System Settings → *Apple Intelligence & Siri*). Without it,
  `system` reports unavailable and the prompt step errors — the availability table still prints.
- **Network** for the `getWeather` tool (it calls Open-Meteo, a public API — no key). Offline,
  the tool returns an error and the run continues.
- No code signing or permission prompts — `ClockTool` and `WeatherTool` need no TCC access.

## Run

`Package.swift` resolves the SDK as a binary dependency and **requires an explicit
`LOCALLM_SDK_VERSION`** (it fails fast otherwise, listing the versions this copy knows about):

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.2 swift run OSMatrix
```

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

### On macOS 27

Same binary: `system` and `pcc` report `available`, `mlx` reports `not downloaded`, and the
run ends by pointing at `--download`.

### `--download` — pull an open-weight model (macOS 27 only)

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.2 swift run OSMatrix --download mlx-community/Qwen3-4B-4bit
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
