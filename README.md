# LocalLM Lab

LocalLM Lab is a macOS app for running local AI models — it turns your Mac
into a private, offline chatbot with an OpenAI-compatible API, and gives
other apps and scripts a way to call the same local model directly.

Download LocalLM Lab from [its product page at https://thisbrain.ai/locallm](https://thisbrain.ai/locallm)

## What's in this repo

- **[toolkit/](toolkit/)** — Archived `localai-cli` toolkit releases (zip +
  checksum) for the 0.6–0.8 line. From `1.0.0-beta.1` on, the toolkit ships as an
  asset on the same GitHub Release as the SDK. Full CLI reference:
  [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)
- **[examples/](examples/)** — Code samples, split by feature:
  - **api-lab/** — Scripts and a sample chat app for the API Lab feature
    (LocalLM Lab's OpenAI-compatible HTTP endpoint).
  - **localai-cli/** — Python examples calling the `localai-cli` toolkit
    directly (no HTTP server, subprocess + JSON on stdin/stdout).
  - **localai-cli-swift/** — The same examples in Swift.
  - **plate-today/**, **plate-today-tools/**, **repo-qa/**, **workspace-buddy/**,
    **components-demo/**, and **code-buddy/** — reference apps for the LocalLM Lab
    SDK, see below.
- **[Components/](Components/)** — `LocalLMLabSDKComponents`, prebuilt SwiftUI for
  managing MCP servers, built on the SDK's public API.

## LocalLM Lab SDK

> **1.0.0-beta — requires macOS 27** — adds the model layer: offer Apple's on-device model, Claude,
> and locally-run open-weight (MLX) models behind one API. Requires the macOS 27 + Xcode 27
> betas. Coming from `0.8.x`? See **[docs/migrating-to-1.0.md](docs/migrating-to-1.0.md)** —
> it's mostly additive, with one enum-resilience compile caveat.

Building your own native macOS app instead? `LocalLMLabSDKCore` links directly into your app's
binary — Calendar/Reminders/Contacts/Location access, a full MCP client (tool discovery, OAuth,
Keychain-backed token storage), Core's Workspace tools, and (1.0) the model layer — routing +
residency across `SystemModelProvider` / `ClaudeModelProvider` / `MLXModelProvider`. Proven under
App Sandbox with a signed path to both Developer ID distribution and the Mac App Store. It's not
a demo dependency — LocalLM Lab itself runs on this SDK.

Two ways to turn a connector or MCP server into something the on-device model can actually call as
a tool. **Path A**: drop in a ready-made `Tool` Core already ships for it —
`GetUpcomingEventsTool`, `SearchContactsTool`, `MCPTool` (built at runtime from any MCP server's
own schema), and the rest — correctness lessons from real, observed on-device model failures
already baked into their descriptions. **Path B**: hand-write your own adapter directly against
the underlying connector call (`CalendarAccess`, `MCPServerManager`, etc.) for full control over
tool names, schemas, and descriptions. Neither is the "real" one — both ship in Core, and an app
can mix them. See [`docs/sdk-guide.md` §7a](docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own)
for the full framing.

- **[docs/sdk-guide.md](docs/sdk-guide.md)** — the full developer guide: linking Core, the model
  layer (§6a), entitlements, all three MCP auth types, Keychain storage, App Sandbox/MAS signing,
  ready-made vs. hand-written tool-calling (§7a), and a full function/type reference (§12).
- **[docs/migrating-to-1.0.md](docs/migrating-to-1.0.md)** — `0.8.x` → `1.0` (macOS 27).
- **[docs/api-surface.md](docs/api-surface.md)** — machine-generated public API list (the check
  behind §12).
- **[docs/tested-models.md](docs/tested-models.md)** — a point-in-time snapshot of which
  open-weight (MLX) models actually tool-call, and why several don't.
- **[CHANGELOG.md](CHANGELOG.md)** — the public SDK surface, version by version.
- **[examples/plate-today/](examples/plate-today/)** — Calendar + Reminders + the Todoist MCP
  server, Path B: a hand-written `Tool` adapter per connector.
- **[examples/plate-today-tools/](examples/plate-today-tools/)** — the exact same app, rebuilt on
  Core's ready-made Tools (Path A) instead — diff the two to see precisely what changes.
- **[examples/repo-qa/](examples/repo-qa/)** — a minimal command-line tool, Path A for MCP: builds
  a `Tool` for a real no-auth MCP server's (Deepwiki's) own tools straight from their live schema.
- **[examples/workspace-buddy/](examples/workspace-buddy/)** — a local AI-assisted coding example:
  pick a folder, the on-device model reads/creates/edits files in it via Core's `WorkspaceTools`
  (Path A).
- **[examples/components-demo/](examples/components-demo/)** — a reference app built on
  `Components`' prebuilt MCP server picker UI instead of wiring one tool programmatically.
- **[examples/repo-qa-local/](examples/repo-qa-local/)** — `repo-qa` with the answer coming from
  a locally-run open-weight MLX model instead of Apple's on-device one. The smallest model-layer
  + `LocalLMLabSDKInference` example.
- **[examples/code-buddy/](examples/code-buddy/)** — the model layer end to end: a CLI coding
  agent routing `.heavy` / `.light` to locally-run MLX models, with Core's Workspace tools and
  an MCP docs server.
- **[docs/annotated-examples.md](docs/annotated-examples.md)** — every reference app's full
  source, with every SDK touchpoint marked inline.

## Roadmap

If you want to see a new feature in LocalLM Lab, please feel free to do a pull request on ROADMAP.md
