# LocalLM Lab, the app

**LocalLM Lab** is a Mac app for trying models, tools, MCP servers and prompts before you build with them. Pick a model, give
it the tools you want it to have, and watch exactly what it does: every call, tool result and raw response is visible,
not hidden behind a chat bubble. It is built on the [LocalLM SDK](README.md), and it is where we test what the SDK
does.

It is a lab, not a chat app. If you want a chat, [ChatAgain](https://thisbrain.ai/locallm/) (coming soon to the Mac App
Store) is built on the SDK's chat core.

The app (macOS 26 or later, Apple Silicon, Apple Intelligence enabled) runs Apple's on-device model, open-weight
models you download and run on the Mac, or a hosted provider when you want a bigger one, side by side in the same
app. It is one Dock app with six panels:

- **Prompt Playground**: write a system prompt and an input, press Run, and see the answer, the tool calls and the
  timing. Turn on Benchmark to time a run in detail.
- **AI Models**: add and switch between Apple's on-device model, open-weight models (through MLX) and hosted providers
  (Claude, GPT, OpenRouter, or any OpenAI-compatible server). It shows what the prompt cache is doing.
- **Connectors**: Calendar, Reminders, Contacts, Location, files and more as tools, each gated by your permission.
- **MCP Servers**: connect Model Context Protocol servers, choose their tools, and review a server that changes
  its tools.
- **Security**: decide how much each tool can do without asking, and try the SDK's injection defenses on and off to
  see what each one changes. **API Lab: tool access** (Everything, Reads and changes, Reads only) sets what runs when
  no one is there to approve a call: in API Lab and in the `localai-cli` toolkit. At Reads only, every MCP tool call is
  refused.
- **API Lab**: an OpenAI-compatible `/v1` endpoint served by the app (localhost, plus optional LAN HTTPS with a
  self-signed certificate), so other apps and scripts can call the model you picked.

Configuration profiles save a combination of connectors, servers, tool descriptions and policy, so you can switch
between setups and compare them.

On macOS 26 only Apple's on-device model runs; open-weight (MLX) models and hosted providers need macOS 27.

**Product page:** [thisbrain.ai/locallm/app.html](https://thisbrain.ai/locallm/app.html), and the
[user guide](https://thisbrain.ai/locallm/guide3.html). Download:
[LocalLM Lab 3.0.0-GA (arm64 DMG)](https://github.com/ancientcomputing/locallm/releases/download/v3.0.0-GA/LocalLM.Lab-3.0.0-GA-arm64.dmg).

## Also in this repository

- **[toolkit/](toolkit/)**: the `localai-cli` toolkit (zip + `.sha256`). `0.6` to `1.0.0-beta.3` are checked in here;
  `1.0.0-beta.4` through `1.0.0-RC.1` shipped as a release asset on
  [`ancientcomputing/locallm-releases`](https://github.com/ancientcomputing/locallm-releases/releases); from
  `1.0.0-GA` on it ships as a release asset on this repo, alongside the app DMG. See that folder's README to
  download and verify; the full CLI reference is at [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html).
  Toolkit calls follow the Security panel's API Lab tool access. A 3.0.0-GA toolkit downloaded before November 16, 2026
  ignores that setting; download it again.
- **[examples/api-lab/](examples/api-lab/)**: scripts and a chat app for the OpenAI-compatible endpoint, and
  **[examples/localai-cli/](examples/localai-cli/)** / **[localai-cli-swift/](examples/localai-cli-swift/)**: calling the
  `localai-cli` toolkit directly. None of these link the SDK.

Building your own app? The SDK is the same engine, and the app is a good place to see what it does before you write code: see the [README](README.md).

## Roadmap

If you want to see a new feature in LocalLM Lab, please feel free to raise an issue.
