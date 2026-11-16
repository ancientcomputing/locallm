# LocalLM SDK

Add a chat assistant that can use tools to your own Mac app, with the model running on the Mac: Apple's
on-device model or an open-weight model, or a hosted model when you want one. No per-token bill for local models,
and no data leaving the machine unless you choose. The SDK is free. Release notes are in the [CHANGELOG](CHANGELOG.md),
and the project site is [thisbrain.ai/locallm](https://thisbrain.ai/locallm/).

> **A new name.** From 3.0 this is the **LocalLM SDK**; it was the LocalLM Lab SDK. LocalLM Lab is the Mac app built on it.
> Nothing in your code changes: the modules, products and release files keep their names (`LocalLMLabSDKCore`,
> `LocalLMLabSDKInference`, …), and so does the API (`LocalLMLab`, `lab.makeSession`).

> **Looking for the LocalLM Lab app** (a Mac app for trying models, tools, MCP servers and prompts before you build with
> them)? That is [a separate page](APP.md). This page is for developers.

## Start here

1. **[Quickstart](docs/quickstart.md)**: a working SwiftUI chat in about 50 lines. Needs macOS 27 with
   Apple Intelligence on, and Xcode 27 to build.
2. **[Examples](examples/README.md)**: complete apps, from a command-line tool to a full chat with servers and
   tool-call rows. `examples/mcp-chat` is the one to read for a chat UI,
   and [answersearch-oss](https://github.com/ancientcomputing/answersearch-oss) shows hosted web search in a menu-bar app.
3. **[The SDK guide](docs/sdk-guide.md)**: the full reference.

## What is in the SDK

| Framework | What it gives you | Form |
|---|---|---|
| `LocalLMLabSDKCore` | The model layer (routes, sessions, Apple's on-device model), tools, an MCP client, the security runtime, connectors | Binary |
| `LocalLMLabSDKInference` | Open-weight models on the Mac through MLX, with a prompt cache | Binary |
| `LocalLMLabSDKRemote` | Hosted models: GPT, Claude's online API, OpenRouter, any OpenAI-compatible server | Binary |
| `LocalLMLabSDKClaude` | Claude through Apple's Foundation Models interface | Binary |
| `LocalLMLabSDKComponents` | Prebuilt SwiftUI: chat views, server and model settings | Source in [Components/](Components/) |
| `LocalLMLabSDKMCPAppsHost` | A server's own interactive views shown in a chat | Source in [MCPAppsHost/](MCPAppsHost/) |

MLX models, hosted models and Private Cloud Compute need macOS 27; Apple's on-device model runs on macOS 26. The
SDK is proven under App Sandbox, with a signed path to both Developer ID distribution and the Mac App Store.
[LocalLM Lab](APP.md) itself runs on it.

## New in 3.0

- **A chat that stays fast with many tools.** Tools are *available*, not *attached*: a small picker chooses the few
  each message needs, and a server is contacted only when one of its tools is used. See
  [MCP in your app](https://thisbrain.ai/locallm/mcp-sdk.html#context).
- **A prompt cache for local models**, on by default, so follow-ups and tool loops don't re-read the whole
  conversation. See [the prompt cache](https://thisbrain.ai/locallm/prompt-cache.html).
- **Every tool call passes an authorizer.** The authorizer is the code that decides whether a call may run. A session
  built without one now refuses anything that could change data; in 2.3 it ran every call unasked. See
  [the tool authorizer](docs/tool-authorizer.md) (it has the upgrade steps).
- **Safe by default with tools you didn't write.** Around the authorizer: a server that changes its tools is held for
  review, outside content is treated as data, programs run in a sandbox, and decisions go to an audit stream. Start with
  [the security overview](docs/security-overview.md), then [the guide for host apps](docs/security-guide-for-hosts.md).
- **Loading a model reads only the disk.** Downloading is a step your app takes.
- **More of MCP:** resources and prompts in chat, richer tool results, paste-a-setup.

Upgrading? 3.0 is a breaking release: read **[docs/migrating-to-3.0.md](docs/migrating-to-3.0.md)**. From 1.x, read
[migrating-to-2.0](docs/migrating-to-2.0.md) first.

## Documentation

- [Quickstart](docs/quickstart.md) and [the glossary](docs/glossary.md) (every term, in plain words)
- [The SDK guide](docs/sdk-guide.md) and [annotated examples](docs/annotated-examples.md)
- [The tool authorizer](docs/tool-authorizer.md)
- Security: [overview](docs/security-overview.md), [guide for host apps](docs/security-guide-for-hosts.md),
  [assurance case](docs/security-model.md)
- [MCP diagnostics](docs/mcp-diagnostics.md) and [tested models](docs/tested-models.md)
- [API surface](docs/api-surface.md) (machine-generated) and [CHANGELOG](CHANGELOG.md)
- Decision models (Jev): [in your app](https://thisbrain.ai/locallm/jev.html). The tools for them, JevDK and
  jev-serve, are their own project: [ancientcomputing/jevdk](https://github.com/ancientcomputing/jevdk).
- An [Agent Skill](skills/locallm-swift-app/) for building SDK apps with Claude Code or Codex.
- Want to try models, tools, MCP servers and prompts before you write code? See [LocalLM Lab, the app](APP.md): the
  download, its panels, and the `localai-cli` toolkit.

## About this repo and support

`ancientcomputing/locallm` is the public home of the SDK's releases, documentation and examples. The SDK's source
is closed; Components and MCPAppsHost ship as source. The 3.0.0-GA release is on the
[3.0.0-GA branch](https://github.com/ancientcomputing/locallm/tree/3.0.0-GA).

The SDK is free. ThisBrainAI also offers support agreements for teams that build on it, including security review
questions: see [thisbrain.ai/locallm](https://thisbrain.ai/locallm/). To suggest a feature, raise an issue.
