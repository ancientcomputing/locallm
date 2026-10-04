# LocalLM Lab

**LocalLM Lab** is about running AI **on your own Mac** instead of renting it
from a hosted provider — no per-token bill, no data leaving your machine, no
dependency on someone else's uptime. It ships two ways to get there: an app,
and an SDK.

The **app** (macOS 26+, Apple Silicon, Apple Intelligence enabled) turns your
Mac into a private chatbot with an OpenAI-compatible API — fully offline with
Apple's on-device model or open-weight models you download and run locally,
or pointed at a hosted provider when you want one — and gives other apps and
scripts a way to call whichever model you've picked.

It's a single Dock app with five panels:

- **Prompt Playground** — a chat window over the model you've selected.
- **AI Models** — add and switch between Apple's on-device model, Private Cloud
  Compute, open-weight models you download and run locally via MLX, and hosted
  providers (Claude, GPT, OpenRouter, or any OpenAI-compatible server, with
  provider-native web search).
- **Connectors** — System Clock, Filesystem, Weather, Calendar, Reminders,
  Contacts, and Location access the model can use as tools, each gated by your
  permission.
- **MCP Servers** — connect Model Context Protocol servers (tool discovery,
  OAuth, Keychain-backed tokens) and hand their tools to the model.
- **API Lab** — an OpenAI-compatible `/v1` endpoint served by the app itself
  (localhost, plus optional LAN HTTPS with a self-signed cert). Point any
  OpenAI-SDK tool at your Mac.

It began local-only — hence the name — and 1.0 added the hosted providers behind
the same interface, so "local" is now the default rather than the only option.
On macOS 26 only Apple's on-device model runs; open-weight (MLX) models and the
hosted providers need macOS 27. **Private Cloud Compute** is wired up but needs
an Apple entitlement that is still pending, so it is currently inert.

**Product page:** [thisbrain.ai/locallm](https://thisbrain.ai/locallm) — or
get the app directly:
[LocalLM Lab 1.0.0-GA (arm64 DMG)](https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-GA/LocalLM.Lab-1.0.0-GA-arm64.dmg).

## LocalLM Lab SDK

The **SDK** is the same engine LocalLM Lab runs on, published as binary
xcframeworks you link into your own native macOS app — so *your* app can run
local AI (Apple's on-device model, or an open-weight model you ship or let the
user download) instead of routing every request through a paid host API,
with hosted providers still available behind the same interface for when you
want one. `LocalLMLabSDKCore` carries the
connectors, a full MCP client, Core's Workspace (filesystem) tools, and the 1.0
model layer — routing and residency across every provider behind one API, with
`SystemModelProvider` (Apple on-device) built in. Add the provider modules you
need: `LocalLMLabSDKInference` (open-weight models via MLX),
`LocalLMLabSDKClaude` (Claude through the Foundation Models interface, via `ClaudeForFoundationModels`),
`LocalLMLabSDKRemote` (hosted providers — GPT, Claude's online API, OpenRouter,
any OpenAI-compatible server), and `LocalLMLabSDKComponents` (prebuilt SwiftUI).
Proven under App Sandbox, with a signed path to both Developer ID distribution
and the Mac App Store — it is not a demo dependency, LocalLM Lab itself runs on
it. Full developer guide:
**[docs/sdk-guide.md](docs/sdk-guide.md)**. Deeper walkthrough of the SDK and its
reference apps is [further down](#building-on-the-sdk).

## About this repo

`ancientcomputing/locallm` is the public home for everything shipped to LocalLM
Lab users and SDK developers. The app and SDK *source* stay closed-source;
what's public here is:

- **[SDK releases](CHANGELOG.md)** — the SwiftPM consumption manifests, binary
  xcframeworks (one GitHub Release per version, tag `v<version>`), the developer
  guide, and a machine-checked [API surface](docs/api-surface.md).
- **[examples/](examples/)** — a dozen small, runnable SDK reference apps (one
  per integration path), plus scripts for the `localai-cli` toolkit and the
  OpenAI-compatible API Lab endpoint. Full list with descriptions in the
  [Building on the SDK](#building-on-the-sdk) section below.
- **[toolkit/](toolkit/)** — the `localai-cli` toolkit (zip + `.sha256`).
  `0.6`–`1.0.0-beta.3` are checked in here; `1.0.0-beta.4` through `1.0.0-RC.1`
  shipped as a release asset on
  [`ancientcomputing/locallm-releases`](https://github.com/ancientcomputing/locallm-releases/releases);
  from **`1.0.0-GA`** on it ships as a release asset on this repo instead,
  alongside the app DMG and the SDK xcframeworks. See that folder's README to
  download and verify; full CLI reference at
  [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html).
- **[Components/](Components/)** — `LocalLMLabSDKComponents`, prebuilt SwiftUI for
  managing MCP servers and models, built on the SDK's public API.
- **[MCPAppsHost/](MCPAppsHost/)** — `LocalLMLabSDKMCPAppsHost` (2.0), host-side support for
  MCP Apps: the sandboxed view for a server's `ui://` widgets, the widget↔host bridge, and the
  widget lifecycle. Source, built on the SDK's public API like `Components`.
- **[skills/locallmlab-swift-app/](skills/locallmlab-swift-app/)** — a repo-local
  Agent Skill for building SDK apps with Claude Code or Codex.

## Building on the SDK

> **The model layer builds for macOS 26 & 27.** `SystemModelProvider` works on
> macOS 26; MLX, `ClaudeForFoundationModels`, the hosted providers, and Private Cloud Compute
> need macOS 27. Coming from 1.x? See **[docs/migrating-to-2.0.md](docs/migrating-to-2.0.md)**:
> 2.0 is a one-time breaking release (mostly tool authorization), then source compatible for every
> 2.x. From `0.8.x`, start with [docs/migrating-to-1.0.md](docs/migrating-to-1.0.md).

Two ways to turn a connector or MCP server into something the on-device model can actually call as
a tool. **Path A**: drop in a ready-made `Tool` Core already ships for it —
`GetUpcomingEventsTool`, `SearchContactsTool`, `MCPTool` (built at runtime from any MCP server's
own schema), and the rest — correctness lessons from real, observed on-device model failures
already baked into their descriptions. **Path B**: hand-write your own adapter directly against
the underlying connector call (`CalendarAccess`, `MCPServerManager`, etc.) for full control over
tool names, schemas, and descriptions. Neither is the "real" one — both ship in Core, and an app
can mix them. See [`docs/sdk-guide.md` §7a](docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own)
for the full framing.

- **Decision models (Jev), new in 2.0** — `lab.decide` asks typed questions (yes / no, one of
  several, a scale) and gets one allowed answer each with probabilities, no text, from TypeSafe's
  Jev, Featherless or **OpenJev** on a local MLX model; a small decider can stay loaded next to
  your chat model. Start with [Decision models (Jev) in your app](https://thisbrain.ai/locallm/jev.html),
  then [`docs/sdk-guide.md` §6c](docs/sdk-guide.md#6c-decision-models-jev--labdecide) and
  [examples/jevdk/](examples/jevdk/).
- **[docs/sdk-guide.md](docs/sdk-guide.md)** — the full developer guide: linking Core, the model
  layer (§6a), entitlements, all three MCP auth types, Keychain storage, App Sandbox/MAS signing,
  ready-made vs. hand-written tool-calling (§7a), and a full function/type reference (§12).
- **[docs/mcp-diagnostics.md](docs/mcp-diagnostics.md)** — the MCP client's logging: one
  verbosity knob, Apple's unified log, and an exportable buffer for user bug reports.
- **[docs/migrating-to-1.0.md](docs/migrating-to-1.0.md)** — `0.8.x` → `1.0` (macOS 27).
- **[docs/api-surface.md](docs/api-surface.md)** — machine-generated public API list (the check
  behind §12).
- **[docs/tested-models.md](docs/tested-models.md)** — a point-in-time snapshot of which
  open-weight (MLX) models actually tool-call, and why several don't.
- **[CHANGELOG.md](CHANGELOG.md)** — the public SDK surface, version by version.
- **[skills/locallmlab-swift-app/](skills/locallmlab-swift-app/)** — a repo-local Agent Skill
  for developers using Codex or Claude Code to build macOS Swift apps with this SDK. Codex
  discovers it through `.agents/skills/locallmlab-swift-app`; Claude Code discovers it through
  `.claude/skills/locallmlab-swift-app`.

### Reference apps

Roughly simplest to fullest — every one runnable, with full annotated source in
[docs/annotated-examples.md](docs/annotated-examples.md):

- **[examples/repo-qa/](examples/repo-qa/)** — a minimal CLI: Apple's on-device model calling a
  real no-auth MCP server's (Deepwiki's) tools, built straight from their live schema (Path A).
- **[examples/os-matrix/](examples/os-matrix/)** — one CLI binary that runs on macOS 26 **and**
  27 with no source `#if`, model families gated by OS at registration
  (`ModelAvailability.requiresOS`).
- **[examples/repo-qa-local/](examples/repo-qa-local/)** — `repo-qa` again, but the answer comes
  from a downloaded open-weight MLX model. The smallest model-layer + `LocalLMLabSDKInference`
  example.
- **[examples/components-demo/](examples/components-demo/)** — a working "add / manage MCP
  servers" screen assembled from prebuilt `Components` views, no MCP UI hand-written.
- **[examples/plate-today-tools/](examples/plate-today-tools/)** — Calendar + Reminders + the
  Todoist (OAuth MCP) server → a spoken-language day summary, on Core's ready-made tools (Path A).
- **[examples/plate-today/](examples/plate-today/)** — the same day summary, built with
  hand-written `Tool` adapters (Path B). Diff the two to see exactly what changes.
- **[examples/workspace-buddy/](examples/workspace-buddy/)** — sandboxed AI edits to a
  user-picked folder via Core's `WorkspaceTools`, on-device model, a security-scoped bookmark
  that survives relaunch.
- **[examples/workspace-buddy-local/](examples/workspace-buddy-local/)** — `workspace-buddy` +
  a downloaded MLX model, running the model layer **inside** the App Sandbox, streaming.
- **[examples/model-switch/](examples/model-switch/)** — GPT / Claude (online API) / OpenRouter
  + on-device behind one chat call site, with provider-run web search and citations. Uses
  `Components`' `AIModelsSettingsView` for the settings panel.
- **[examples/security-demo/](examples/security-demo/)** — a "Security" panel mapping to
  `limited(toMaxImpact:)` (which tools) + `ConfirmingToolAuthorizer` (whether they prompt), a
  frontier model against Calendar + a Todoist MCP server. The runnable companion to the
  tool-authorization docs.
- **[examples/code-buddy/](examples/code-buddy/)** — a CLI coding agent: two models with
  routing, Core's Workspace + host `Process` tools, an MCP docs server, a persistent REPL
  session.
- **[examples/aiql/](examples/aiql/)** — a plain-English request → one read-only SQL `SELECT`
  over an MCP dataset → the CSV you asked for. Sandboxed SwiftUI, a downloaded local model,
  zero fabricated values (the model writes the query, the host runs it read-only).
- **[examples/vistanova/](examples/vistanova/)** — a tiny local search engine: web search through a
  Tavily MCP server, summaries from an MLX model **shipped pinned to an exact commit**, and
  defenses against a small model that skips the tool call. A SwiftUI app.
- **[examples/mcp-chat/](examples/mcp-chat/)** (2.0) — a chat with a local model where a tool call
  that has an MCP App shows the server's interactive widget inline (Todoist's task list, a system
  monitor); the widget's own calls go through the same per-server approval as the model's.
- **[examples/jevdk/](examples/jevdk/)** (2.0) — JevDK, a playground for decision-model (Jev)
  questions: run them on a local MLX model and on hosted Jev side by side, score a batch against
  your marked answers, calibrate, compare models, and export the tested questions for your app.
  [Developer's guide](https://thisbrain.ai/locallm/jdk-guide.html);
  [download the app](https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-dev/JevDK-0.1.0-arm64.dmg)
  (macOS 27, signed and notarized, a preview built on SDK 2.0.0-dev).

Plus **[examples/api-lab/](examples/api-lab/)** (scripts + a chat app for the OpenAI-compatible
endpoint) and **[examples/localai-cli/](examples/localai-cli/)** / **[localai-cli-swift/](examples/localai-cli-swift/)**
(calling the `localai-cli` toolkit directly), which don't link the SDK.

## Roadmap

If you want to see a new feature in LocalLM Lab, please feel free to raise an issue.
