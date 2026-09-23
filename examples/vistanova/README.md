# VistaNova

*The new AltaVista. A brighter web ahead.*

A tiny local-first search engine, built on the [LocalLM Lab SDK](../../README.md). Give it a topic,
get back 5 web pages about it, and refine it yourself — no AI guessing at your intent. As an SDK
example it shows how to build something useful with **local models and an MCP client**: web search
through a hosted MCP server (Tavily), run by one local model, summarized by another.

A SwiftUI `.app` with a chat-style scrolling history (last 100 topic threads), Tavily's key in
the Keychain (via the SDK's own MCP PAT store), and two independent local model choices — a search
model (tool-calling reliability matters most, so Apple on-device by default) and a summary model
(pure text synthesis, no tool call at all, so it defaults to a downloaded MLX model instead — see
below). No cloud model providers by design: the goal is on-device inference with online *search*
(Tavily today; a user-configurable choice of search backend — Brave, Exa, etc. — is not built).

**Reading the source:** [`docs/annotated-examples.md`](../../docs/annotated-examples.md#examplesvistanova)
marks every line of the app's SDK-facing code (`// ← SDK`) and explains the parts worth studying:
the pinned model, the Path B `Tool`, and the defenses against a small model that skips its tool
call.

Requires **Apple Silicon**, **macOS 27** and the **Xcode 27** toolchain. See
[`../README.md`](../README.md) for how the examples resolve the SDK binaries.

## VistaNova (the SwiftUI app)

```bash
brew install xcodegen   # once; only needed to regenerate the .xcodeproj after editing project.yml
open VistaNova.xcodeproj    # Run
```

The committed `VistaNova.xcodeproj` is ad-hoc signed with no sandbox and no entitlements, so no
Apple ID or team is needed. Regenerate it with `xcodegen generate` after editing `project.yml`,
never by hand.

**Building a signed, notarized release DMG:**

```bash
VERSION=1.0.0 APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TEAM_ID=TEAMID \
KEYCHAIN_PROFILE=<notarytool-profile-name> \
  packaging/build-and-sign.sh
```

Produces `dist/VistaNova-<version>.dmg`, signed, notarized, and stapled. See
[`packaging/build-and-sign.sh`](packaging/build-and-sign.sh)'s header comment for one-time
notarytool credential setup. Run it with no env vars for an ad-hoc local build (skips
notarization; the app only runs on the Mac that built it).

First launch shows a blocking "Connect Tavily" sheet — get a key at
[app.tavily.com](https://app.tavily.com) (`tvly-...`) and paste it in. It's stored via
`MCPServerManager`'s own Keychain-backed PAT store, not in a file — the app only persists the
server's shape (URL, which tool is enabled) so it can reconnect next launch without asking again.

**Two model choices, in Settings only** (no picker in the main window): "Web search" (default:
Apple on-device — reliable tool-calling matters most here) and "Summary" (default:
`mlx-community/Qwen3-4B-4bit`, not downloaded until first use). The first time you click
Summarize with an undownloaded summary model, a progress sheet appears; Cancel aborts the
transfer (`MLXModelProvider.cancelDownload(_:)`) and skips that one summary.

### The summary model is pinned

VistaNova has an opinion about its summary model, so it ships it **pinned** rather than tracking
whatever the Hugging Face repo's `main` becomes:

```swift
private let mlxProvider = MLXModelProvider(pinnedRevisions: [
    AppModel.summaryModelRepo: AppModel.summaryModelRevision,   // "mlx-community/Qwen3-4B-4bit" @ 4dcb3d10…
])
```

Without the pin, a repo owner moving `main` to different weights would silently change what a
user's next fresh download fetches — same repo name, different model, no app release. With it:

- Every download resolves to that exact commit, whichever version `main` has become.
- It is a **shipped pin**, so it wins over any pin captured on a user's machine, and if the commit
  can't be fetched the download fails — it never falls back to `main`.
- Moving to a newer version is a code change: review the new commit, try Summarize against it,
  then edit `summaryModelRevision` in [`AppModel.swift`](Sources/VistaNova/AppModel.swift) and
  ship a build. Nothing at runtime can move it.

Only this one model is pinned. VistaNova never downloads any other MLX model itself (the Settings
pickers list what is already on disk), so there is no first download to capture a pin from and
no `MLXFilePinStore`. For the full pin / update / roll-back / clean-up flow, see
[`mlx-control-room`](../mlx-control-room/) and the SDK guide's
[Pinning, updating and cleaning up model versions](../../docs/sdk-guide.md#pinning-updating-and-cleaning-up-model-versions).

**Search is user-refined, not AI-refined.** Type a topic, get 5 links plus the actual query the
model sent to `tavily_search` (shown as a subtitle — it can legitimately differ from what you
typed). The box keeps your text after results land instead of clearing it: edit it in place to
narrow the search ("last ceo" → "yahoo last ceo") and it stays in the same topic thread, or hit
the clear (×) button to start a genuinely new one. An earlier version had the model itself guess
whether a new query continued the topic, silently expanding ambiguous follow-ups using thread
context — confirmed live that this fails exactly where it matters ("last ceo" inside a Yahoo
thread got grounded to Tim Cook), so there's no automatic grounding or classification anymore.

**Summarize.** Below a turn's links, a "Summarize" button asks the model for a 2-3 sentence
paragraph over the snippets `tavily_search` already returned (no extra tool call — Tavily returns
a snippet per result that the search step already captures).

Links are plain `Link`s — clicking one opens your default browser.

## How it works

- The app connects to Tavily's MCP server (`https://mcp.tavily.com/mcp/`) with `authType:
  .pat` — a static Bearer API key, no OAuth round-trip.
- `VistaNova` uses a hand-written `TavilySearchTool` (Path B — see
  [`sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own)),
  not the SDK's auto-assembled `MCPTool` — this pins `max_results`/`search_depth` in Swift (the
  model only ever chooses `query`) and lets an actor (`SearchQueryCapture`) record the query
  argument actually used. (Since 1.0.0-RC.1, `session.events`' `.toolCallStarted` also carries the
  call's `arguments`, so that recording could now be read from the event stream instead.)
- Output is structured (`@Generable SearchResults`) when the model supports guided generation;
  otherwise a plain-text fallback parses `(title, url)` pairs out of unstructured output —
  verified via `searchCapability(_:)`, since not every MLX model supports either guided
  generation or reliable tool-calling.
- `search(...)` watches `session.events` for `.toolCallStarted("tavily_search")` and rejects a
  turn where the model answered from its own training data instead of calling the tool — confirmed
  live that several MLX models will do exactly that despite explicit instructions not to.
- Apple's on-device guardrail can intercept a turn about a real person/sensitive topic even after
  producing a fully valid result; `search(...)` recovers the embedded payload when there's
  something to recover (strict JSON decode, then a lenient regex fallback for cases where the
  decline path drops quote characters) rather than surfacing a dead end for a turn that actually
  worked.
- `VistaNova` drives everything through `LocalLMLab` (`LocalLMLabSDKCore` + `LocalLMLabSDKInference`):
  `lab.mcp` is an `MCPServerManager`, `lab.models` handles routing
  between `SystemModelProvider` and `MLXModelProvider`, and both model choices persist through the
  SDK's own `lab.snapshot()`/`lab.restore(from:)`, not a hand-rolled setting.

## Layout

- `Package.swift` — vends the two SDK binaries (`LocalLMLabSDKCore`, and `LocalLMLabSDKInference` for the MLX model) from the GitHub Release.
- `Sources/VistaNova/`, `project.yml`, `VistaNova.xcodeproj/`, `xcodeproj/` — the SwiftUI app.
- `packaging/build-and-sign.sh` — signed, notarized DMG (drives `xcodebuild archive`).
