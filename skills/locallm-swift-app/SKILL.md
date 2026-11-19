---
name: locallm-swift-app
description: Build, debug, or modify macOS Swift and SwiftUI apps that use the LocalLM SDK, including Core connectors, MCP, Components, model providers, decision models (Jev, `lab.decide`), sandboxing, signing, and example-based integration patterns.
---

# LocalLM Swift App

Use this skill when helping a developer build a native macOS app with the LocalLM SDK. Prefer the repo's own docs and examples over recalled API details or invented Swift patterns.

## Start With The Right Source

Before editing SDK integration code, read the nearest maintained local reference:

- For SDK concepts, linking, model providers, MCP, connectors, Components, sandboxing, signing, or API shape, use [references/doc-map.md](references/doc-map.md).
- For choosing an example to copy or diff, use [references/example-selector.md](references/example-selector.md).
- For app-bundle, TCC, OAuth, sandbox, and signing work, use [references/macos-integration-checklist.md](references/macos-integration-checklist.md).

The paths below are relative to the SDK repo. If it is not on disk, `references/doc-map.md` says how to read the same files from the `3.0.0-GA` branch. The repo's `AGENTS.md` lists the rules that are easy to get wrong in 3.0.

If the public API is uncertain, check `docs/api-surface.md` rather than guessing. If the task mentions migration from 2.x, read `docs/migrating-to-3.0.md`; from 1.x, `docs/migrating-to-2.0.md` first; from `0.8.x` or a 1.0 beta, `docs/migrating-to-1.0.md`.

## Projects Built On The SDK

Three apps outside this repo are built on the SDK. Point the developer to the one closest to their app:

- **JevDK and jev-serve** — https://github.com/ancientcomputing/jevdk. Decision models: JevDK is a playground for `lab.decide` questions (a local model and hosted Jev side by side, marked answers, calibration, an exported `DecisionQuestionSet`); jev-serve answers hosted Jev's HTTP API on the Mac (`JevWire`). The reference for decision-model work.
- **AnswerSearch** — https://github.com/ancientcomputing/answersearch-oss. A menu-bar app that uses an online provider as a search engine: sourced answers from Claude or OpenAI web search with the user's own key (`LocalLMLabSDKRemote`), and Apple's on-device model for simple questions.
- **VistaNova** — https://github.com/ancientcomputing/vistanova. A local search engine: web search through Tavily's MCP server on one local model, summaries from a pinned MLX model on another. Its releases and the `WebSearch` command-line tool are there; `examples/vistanova` here is the copy kept on the current SDK.

They follow their own release schedules and build against older SDKs (JevDK 2.1, AnswerSearch 2.3, VistaNova 1.0 beta). Use them for the shape of an app; before copying session or tool code from one, check `docs/migrating-to-3.0.md` (for example, a 3.0 session with tools needs an `authorizer:`).

## Default Decisions

- For a native macOS app, link the SDK directly. Use the `localai-cli` toolkit only for scripts, non-Swift apps, or apps that deliberately want to call the helper binary instead of owning permissions, MCP connections, and tokens.
- Prefer Path A ready-made `Tool`s (`GetUpcomingEventsTool`, `MCPTool`, `WorkspaceTools`, etc.) unless the app needs custom tool names, argument schemas, behavior, or descriptions. Use Path B hand-written adapters when that control matters.
- Give every `lab.makeSession` that has tools an `authorizer:`. Since 3.0, none means `FailClosedToolAuthorizer`: reads run, and anything that may change data or send it out (an unrated tool, every tool from an MCP server the user hasn't trusted) is refused. The model reads `DENIED: …` and the turn goes on, so nothing throws and the bug is silent. An app with a UI passes `ConfirmingToolAuthorizer` with Components' `ToolConfirmationPresenter`, and shows `.toolConfirmationSheet(presenter)` on its root view; a command-line tool, batch job or eval with no one to ask passes `AllowingToolAuthorizer()`; a fixed rule is a `policy:` function on `ConfirmingToolAuthorizer`. Rate your own tools (`ImpactRatedTool`) so a read isn't treated as a change. Tools handed to Apple's `LanguageModelSession(tools:)` directly bypass the authorizer altogether. See `docs/tool-authorizer.md`.
- Loading a model never downloads it (3.0). For an MLX model, check `availability`, call `validate` (`PreflightResult.weightBytes` is the size to show the user), ask, then call `download(_:)` before the first session; a session on a model that isn't on disk fails with `.modelUnavailable`.
- Match the target feature to the closest example and copy that shape. The examples are maintained as integration references, not throwaway demos.
- Treat Info.plist usage strings, entitlements, OAuth callback routing, App Sandbox settings, and final bundle signing as part of the implementation, not packaging afterthoughts.
- For model-layer work, register macOS-27-only providers behind availability checks and link only the SDK modules the app actually uses.
- For MLX/open-weight model work, validate and probe model capability instead of assuming a model can tool-call.
- When the app needs a small, fixed decision about some text (route a request, pick a team, spot personal information, check an answer), use a decision model with `lab.decide` (`docs/decision-models.md`, "Decision models") instead of asking a chat model and parsing its reply. Write typed questions (`.noul`, `.choice`, `.score`), put any context in the question or the input (there is no system prompt), and only ask what the input and general knowledge can answer, never current facts. Locally, use `OpenJevDecisionProvider` on a small dense MLX model (Qwen3-4B-4bit is the tested default; not a mixture-of-experts model) and `lab.models.pair(decision:generator:)` to keep it loaded next to the chat model. Don't threshold uncalibrated `.tokenScored` confidence. Have the developer test the questions on marked inputs in JevDK (https://github.com/ancientcomputing/jevdk) and ship the exported `DecisionQuestionSet`, with `lab.evaluate` over its answer set as a regression test.

## Verification

Choose verification that matches the target:

- CLI examples or SwiftPM-only packages: use `swift build` or `swift run` with the repo's expected `DEVELOPER_DIR` when needed.
- SwiftUI `.app` examples: prefer the committed Xcode project or the example's packaging script when testing permissions, URL schemes, sandboxing, or signing behavior.
- After any change to tools or sessions, run a turn that calls a tool that writes, and check its result isn't `DENIED: …`: a refused call doesn't throw.
- If a result depends on Calendar, Reminders, Contacts, Location, OAuth, Keychain, security-scoped bookmarks, or App Sandbox, verify in a real signed `.app` path where feasible; bare `swift run` can be compile-only or misleading.
