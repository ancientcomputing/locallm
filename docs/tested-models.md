# Tested open-weight (MLX) models

> **Point-in-time, not maintained.** This is a snapshot of what we saw on our hardware,
> our SDK build, and one specific tool-calling prompt, as of **2026-08-27** (SDK
> `1.0.0-beta`, requires macOS 27). Model conversions, chat templates, and the MLX stack all
> move. **Validate your own model with `MLXModelProvider.capabilityProbe` — that result is
> authoritative, this table is a starting point.** Distilled from
> 15+ rounds of real traces. (The Qwen3.8-27B row was confirmed separately on
> **2026-09-27** against SDK `1.0.0-GA`, on a Mac Studio M5 Max / 64 GB — not part of the
> original 15-round rig below.)

Applies to the **model layer** only (`LocalLMLabSDKInference` + `MLXModelProvider` — see
[`sdk-guide.md` §6a](sdk-guide.md#6a-the-model-layer-local-models-routing-sessions)). The
example that exercises all of it is [`code-buddy`](../examples/code-buddy/), which defaults
to `mlx-community/Qwen3-8B-4bit` for exactly the reasons below.

Test rig: Mac (Apple Silicon, 64 GB), `1.0.0-beta` SDK, MLX bridge on `MLXLMCommon.ChatSession`.
The task: a real GitHub-MCP tool-calling prompt requiring two specific tool calls, plus a
built-in `ClockTool` cross-check.

## The short version

| Family | Tool-calling | Notes |
|---|---|---|
| **Qwen 2.5 / 3** (1.5B – 14B, `mlx-community/*-Instruct-4bit`, `Qwen3-*-4bit`) | ✅ reliable | The reference set. 1.5B tool-calls but grounds shallowly; 8B/14B better. Qwen's `<tool_call>{…}</tool_call>` JSON convention is what the bridge is built against. **`code-buddy`'s default.** |
| **Qwen3.8-27B** (4-bit `mlx-community/Qwen3.8-27B-4bit`, 6-bit `lmstudio-community/Qwen3.8-27B-MLX-6bit`, 8-bit `mlx-community/Qwen3.8-27B-8bit`) | ✅ reliable (confirmed 2026-09-27, SDK 1.0.0-GA, Mac Studio M5 Max / 64 GB) | Larger sibling of the Qwen3 family above — same tool-calling convention, tool-calls reliably across all three quantizations. Needs a Mac with enough unified memory to hold the weights (the 8-bit checkpoint's actual file size is ~29.5 GB — see `MLXModelProvider.validate`'s `sizeVsMemory` stage; 4-bit and 6-bit are proportionally smaller/larger). Couldn't be downloaded before the `1.0.0` GA preflight fix below — `usedStorage` overcounted the 8-bit checkpoint as 58.1 GB against its real 29.5 GB and it was rejected as too big for a 64 GB Mac (see the `1.0.0 — GA` entry in [CHANGELOG.md](../CHANGELOG.md)). Not part of the original 15-round eval below — added once confirmed separately. |
| **Granite 4.0** (h-tiny) | ✅ | First non-Qwen to genuinely tool-call. Picked adjacent-but-wrong tools on an unnamed-tool prompt (name your tools explicitly). |
| **Gemma 3 / 4** | ✅ | Best release-date precision of any local model tested, matching Claude — with one fabricated detail. |
| **Ministral-3-3B** | ✅ | Cleanest grounding outside Claude/Gemma; zero fabrication in our run. |
| **DeepSeek** (R1-Distill-Qwen 7B/14B, R1-Distill-Llama 8B, V2-Lite-Chat) | ❌ | 4/4 zero tool calls, across 3 lineages + 2 base architectures. Root cause: chat templates with no working tool-definition/tool-call mechanism the app can drive. Also fabricates confidently. **Check the chat template before downloading any DeepSeek model for tool use.** |
| **Phi-4** (14B, `mlx-community/phi-4-4bit`) | ❌ | Same root cause as DeepSeek despite an "instruction/tool-tuned" reputation. Phi-4-mini untested — different checkpoint, don't assume it carries over. |
| **Phi-4-mini**, **SmolLM3-3B** | ❌ | Fail on the *input* side: templates try to list tools via a convention `swift-transformers` doesn't supply. Structurally unreachable regardless of the model. SmolLM3 then fabricates badly. |
| **gpt-oss-20B** | ⚠️ app-side gap | The model correctly formats a real call — in OpenAI's "Harmony" format, which `mlx-swift-lm` has no parser for, so the call is never recognized. Not a model gap; a known limitation of `mlx-swift-lm`'s parser. |

## Capacity notes (this Mac, this workload)

- **Apple on-device** (`SystemModelProvider` / `.system`): ~8,192-token context window. A
  two-tool-call turn whose results carry real content **hard-fails** with a context-overflow
  error. Use `session.contextBudget` and `retryOnContextOverflow`, or route heavier turns to
  `.pcc` / Claude / a local model with a bigger window.
- Speed does **not** track parameter count predictably here — a 14B run measured *faster*
  than an 8B run on the same prompt (244s vs 360s). Measure, don't assume.
- `MLXModelProvider.validate` flags a model whose weights exceed ~70% of physical RAM
  (`sizeVsMemory`) — the real limit for a local model is unified memory during inference,
  not token count. `residentModelLimit` (see `code-buddy`, `residencyEventStream`) is how a
  constrained Mac keeps only one model warm at a time.

## Fit criteria (what to check before committing to a model)

1. Is it MLX-format (`.safetensors` + `config.json`, not a raw PyTorch/GGUF checkout)?
   → `validate` stage `mlxFormat`.
2. Is the architecture one `MLXLMCommon` implements? → `validate` stage `architectureSupported`.
3. Does it fit memory? → `validate` stage `sizeVsMemory`.
4. Does it *actually* tool-call, not just claim to? → `capabilityProbe`.
5. Does its chat template define a tool-calling convention the bridge can drive? (This is
   what kills DeepSeek / Phi-4.) `capabilityProbe`'s tool round-trip is the empirical check.

## Chain-of-thought in output

Several of these models (Qwen3's `<think>…</think>`, Gemma's `<|channel|>` markers) emit
raw reasoning inline in the response text. The MLX bridge streams that through verbatim — it
does **not** separate a reasoning channel (Apple's `streamResponse` doesn't surface incremental
reasoning). If you want a clean answer, carve the delimiters out consumer-side, as LocalLM Lab's
own Prompt Playground does.
