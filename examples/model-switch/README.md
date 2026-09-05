# Model Switch

The reference app for [`docs/12-remote-model-providers.md`](../../docs/12-remote-model-providers.md)
(P4) — AnswerSearch-shaped. The user adds an online AI provider with an API key, ticks web
search, and switches freely between **every** configured model from one chat window and one
`lab.makeSession` call site:

- Apple on-device (`system`) — always present
- GPT via `openai:` (Chat Completions or Responses)
- Claude online via `anthropic:` — with native web search + citations
- any OpenRouter model via `openrouter:` — with the model-agnostic web plugin
- any OpenAI-compatible server (LM Studio, vLLM, …) via a custom scheme

MLX would slot in exactly as `code-buddy` links `LocalLMLabSDKInference`; left out here to keep
the build Metal-toolchain-free.

## Run

```bash
cd examples/model-switch
swift run ModelSwitch
```

`⌘,` opens **Providers** — the [`AIModelsSettingsView`](../../Components/Sources/LocalLMLabSDKComponents/AIModelsSettingsView.swift)
from Components: built-in families with live availability, then **Add provider** → paste a
key → the model rows flip to *Ready* and appear in the chat window's picker. Tick **Enable
web search** on a provider that supports it.

In the chat window: pick a model, optionally flip **Web search** for the next turn, send. When
the model runs a provider-native search you see the queries inline and citation links under the
answer.

## What it shows

| piece | file |
|---|---|
| `RemoteProviderDraft` → `RemoteProviderConfig` — the ~30 lines of host glue | [`ProviderGlue.swift`](Sources/ModelSwitch/ProviderGlue.swift) |
| `lab.models.replace(RemoteModelProvider(config))` on every settings change | [`AppModel.applyDraft`](Sources/ModelSwitch/AppModel.swift) |
| one `makeSession(route:options:)` for every tier; `session.events` → search activity; `session.citations` | [`AppModel.send`](Sources/ModelSwitch/AppModel.swift) |
| the assembled settings panel + per-provider section | Components |

## Not production

API keys persist to `UserDefaults` here for brevity. **A real app stores them in the
Keychain** — the SDK persists nothing; key storage is always the host's job. There's no
`packaging/` (no TCC-gated APIs, no URL scheme), so a bare `swift run` is enough.
