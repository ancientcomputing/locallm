# os-matrix — one SDK build for macOS 26 and macOS 27

`swift run OSMatrix` on a macOS 26 machine and a macOS 27 machine. Same binary, different
behaviour — no `#if os` / no separate build, just `#available` at provider registration.

```
$ swift run OSMatrix          # on macOS 26
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

On macOS 27 the same binary prints `system` + `pcc` as `available`, `mlx` as `not
downloaded`, and offers the MLX download path.

## The four scenarios, and where each shows up here

| # | Scenario | In this example |
|---|---|---|
| 1 | **Same code, both OSes** | `lab.makeSession(route:) → session.respond(to:)` — identical on 26 and 27. |
| 2 | **A macOS-27-only feature** | The MLX open-weight-model download, gated by `if #available(macOS 27, *)`. |
| 3 | **A feature that works on both** | `ClockTool()` + `WeatherTool()` — Core's ready-made connector tools are all `@available(macOS 26)`. |
| 4 | **More on 27 than on 26** | `SystemModelProvider` is registered always; `PCCModelProvider` + `MLXModelProvider` only inside the one `#available` block. `lab.models.availability(for:)` reports the rest `.requiresOS("macOS 27")`. |

The `#available` check appears **once**, at registration. Everything downstream —
`makeSession`, `respond`, `events`, `contextBudget`, the connector tools — is the same code.

## Adding Claude (scenario 4, the LocalLM Lab app situation)

`LocalLMLabSDKClaude` depends on `ClaudeForFoundationModels`, which is hard-pinned to a
macOS 27 platform floor. Linking it forces a **27 deployment target** on whatever target
links it — so you can't add it to this `.macOS("26.0")` package directly.

Two ways to offer Claude anyway:

1. **Your whole app is macOS 27+.** Add the `Claude` package, register
   `ClaudeModelProvider(auth: .apiKey(key))` alongside the others. Done.

2. **Your app runs on macOS 26 too** (this example's situation). Put the Claude path in a
   separate macOS-27-only executable — a helper the main app spawns, or an
   `@available(macOS 27)`-gated plugin bundle it `dlopen`s. The main app stays `.macOS("26.0")`;
   `Core`'s public API (`ModelProvider`, `makeSession`, `LocalLMLabSession`) is identical on
   both sides of that boundary, so only the *registration* differs. The LocalLM Lab app does
   exactly this: its `--serve` helper is a 27 binary (system/PCC/Claude/MLX) and a 26 binary
   (system only), chosen at launch.
