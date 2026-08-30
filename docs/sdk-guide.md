# Using the LocalLM Lab SDK

Audience: a Swift developer linking `LocalLMLabSDKCore` into their own macOS app to add local-AI
tool-calling — system connectors (Calendar, Reminders, Contacts, Location), an MCP client, and
(via `Components`) prebuilt SwiftUI for managing MCP server connections. Everything here has been
exercised against real signed apps and real live MCP servers, not just written from the API
surface — see [`examples/plate-today`](../examples/plate-today) (and its Path A twin,
[`examples/plate-today-tools`](../examples/plate-today-tools) — same app, built on Core's
ready-made Tools instead of hand-written ones, see §7a), [`examples/repo-qa`](../examples/repo-qa)
(a minimal command-line `MCPTool` example against a no-auth server),
[`examples/workspace-buddy`](../examples/workspace-buddy) (a local AI-assisted coding example —
pick a folder, the model reads/creates/edits files in it via `WorkspaceTools`, §8a — WorkspaceAccess/WorkspaceTools), and
[`examples/components-demo`](../examples/components-demo) for the working reference apps this
guide is drawn from.

Requires macOS 26+ on Apple Silicon, Swift 6 tools.

**Status note**: this SDK is early — this guide describes the API as it exists today, and it will
change. `Components` in particular is newer and smaller than `Core`.

## Which integration path should I use — this SDK, or the toolkit?

Both are supported, and neither supersedes the other — they solve different problems:

- **The toolkit** (`localai-cli`/`localai-playground-run`, see [`examples/localai-cli`](../examples/localai-cli)
  and [`examples/localai-cli-swift`](../examples/localai-cli-swift)) calls a small helper binary as
  a subprocess with JSON on stdin/stdout. It requires LocalLM Lab to be running (it relays
  connector/MCP calls through LocalLM Lab's own process) and reads permissions from LocalLM Lab's
  own config — no macOS entitlements or TCC setup of your own to manage. Good fit for scripts,
  non-Swift apps, or anything that doesn't want to link a Swift framework directly.
- **This SDK** links `LocalLMLabSDKCore` directly into your own app. No LocalLM Lab dependency at
  runtime — your app owns its own TCC grants, its own MCP connections, its own Keychain-stored
  tokens. More setup (entitlements, Info.plist keys, your own OAuth redirect scheme — see below),
  but no external process to depend on, and full control over the resulting `.app`'s distribution
  (Developer ID + notarization, or Mac App Store). The 1.0 line also adds the **model layer**
  ([§6a](#6a-the-model-layer-local-models-routing-sessions)) — offer Apple's on-device model,
  Claude, and locally-run open-weight (MLX) models behind one API, with routing and residency
  the SDK owns. Add `LocalLMLabSDKInference` too for the MLX runtime.

If you're not sure which fits, `examples/localai-cli/plate_today.py` and this SDK's
`examples/plate-today` are the same "what's on my plate today" feature built both ways — a direct,
concrete comparison of what each path actually requires.

## 1. Linking Core

`LocalLMLabSDKCore` ships as a `Core.xcframework` binary, published as a GitHub Release asset on
this repo. Add it to your own `Package.swift` as a `binaryTarget`, pointing at the exact release
you want:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YourApp",
    platforms: [.macOS("26.0")],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: "https://github.com/ancientcomputing/locallm/releases/download/vX.Y.Z/LocalLMLabSDKCore-X.Y.Z.xcframework.zip",
            checksum: "..."  // the .sha256 file alongside the asset on that release
        ),
        .executableTarget(
            name: "YourApp",
            dependencies: ["LocalLMLabSDKCore"]
        )
    ]
)
```

Get the exact `url` and `checksum` for the version you want from this repo's
[Releases page](https://github.com/ancientcomputing/locallm/releases) — each release's assets include both the `.xcframework.zip`
and a matching `.sha256` file. `examples/plate-today/Package.swift` is a real, working example of
this same pattern if you want something to copy from directly.

```swift
import LocalLMLabSDKCore
```

If you also want the prebuilt SwiftUI pieces (MCP server picker, OAuth waiting view, resource/
prompt browsing), add `Components` the same way — see [`examples/components-demo`](../examples/components-demo)
for a working example of using it.

## 2. Required setup before you can use Calendar/Reminders or MCP OAuth

Three things are **required**, not optional extras — skipping any one of them produces a confusing
failure (a silent TCC denial, or a crash on a missing entitlement) rather than a clear error.

### 2a. Info.plist usage-description strings

For every connector you use (Calendar/Reminders shown here — see §7 (Connectors) for the full connector
list and its Info.plist/entitlement requirements):

```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Your own explanation of why your app needs this.</string>
<key>NSRemindersFullAccessUsageDescription</key>
<string>Your own explanation of why your app needs this.</string>
```

### 2b. Entitlements

```xml
<key>com.apple.security.personal-information.calendars</key>
<true/>
```

There is no separate "reminders" sandbox entitlement — Reminders access (EventKit) is covered by
this same `calendars` entitlement; only the Info.plist `NSRemindersFullAccessUsageDescription` key
and the TCC prompt itself are Reminders-specific. A
`com.apple.security.personal-information.reminders` key isn't a real Apple entitlement — local
`codesign`/`pkgutil --check-signature` don't catch this, but a real App Store Connect
validation (Transporter upload) rejects it outright with "Invalid Code Signing Entitlements."
Confirmed live, 2026-08-14.

**Both 2a and 2b are required together, on your final signed bundle, or TCC fails in confusing
ways.** The specific failure sequence (confirmed live, more than once):
1. Entitlement missing → "Policy disallows prompt" (no dialog appears at all).
2. Entitlement present, Info.plist key missing → "Refusing authorization request ... without
   NSCalendarsUsageDescription key".
3. Both present, but your **final** `codesign` call on the outer `.app` bundle omitted
   `--entitlements` → entitlements applied to the inner binary are silently stripped, because
   signing the outer bundle re-signs its own main executable regardless of any earlier per-binary
   sign. Sign the binary, then sign the whole bundle **with `--entitlements` again** — that second
   pass is the one that actually matters.

### 2c. OAuth redirect URI — MUST set this yourself

If you connect to any MCP server that uses OAuth (most hosted MCP servers do — e.g. Todoist), you
**must** set `MCPOAuthFlow.redirectURI` to your own app's URL scheme before calling `connect`:

```swift
MCPOAuthFlow.redirectURI = "yourapp://oauth/callback"
```

And register that scheme in your Info.plist:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key><string>com.yourcompany.yourapp.oauth</string>
    <key>CFBundleURLSchemes</key>
    <array><string>yourapp</string></array>
  </dict>
</array>
```

**Do not skip this or reuse the SDK's own default scheme.** `redirectURI` defaults to a
placeholder value for source compatibility — if you don't override it, your app's OAuth callback
either silently collides with any other app on the same Mac that also failed to override it (macOS
resolves a claimed URL scheme to exactly one app, arbitrarily, when more than one registers it), or
simply won't route back to your app at all.

### 2d. Wire the OAuth callback through your AppDelegate, not SwiftUI's `.onOpenURL`

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "yourapp" {
            MCPOAuthRedirectListener.shared.handleRedirect(url)
        }
    }
}

@main
struct YourApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
            // Without this, WindowGroup ALSO opens a new scene for the same open-URL event
            // AppDelegate already handled above — you'll see a second window pop up when the
            // OAuth browser redirects back. Confirmed live, more than once.
            .handlesExternalEvents(matching: [])
    }
}
```

If you use SwiftUI's `.onOpenURL` instead, you will get a second window/scene spawned every time a
user completes an OAuth sign-in — `WindowGroup` treats any open-URL event as a request for a new
scene instance unless told otherwise.

## 3. Connecting to an MCP server: three auth options, and how to pick between them

> **Reach for this when** your app's pitch is "connect your own tools" — Todoist, GitHub,
> Linear, an internal MCP server — rather than you hardcoding every integration one by one.
> `MCPServerManager.addServer` discovers a server's tools at connect time and hands you back
> plain descriptors; *you* decide which become model tools (§6, §7a). The auth handling below
> is the entire reason connecting isn't a one-liner: a server needs no auth, a static token,
> or a browser OAuth round-trip, and you usually can't tell which up front.
>
> **Examples that use it:** [`plate-today`](../examples/plate-today/) /
> [`plate-today-tools`](../examples/plate-today-tools/) (Todoist over OAuth),
> [`repo-qa`](../examples/repo-qa/) (DeepWiki, `.none`),
> [`components-demo`](../examples/components-demo/) (all three auth types, via
> `Components`' `MCPServerPickerView`).

Adding an MCP server involves one of three auth types, exposed as `MCPAuthType`. `Components`'
`MCPServerPickerView` (see §11, the Components package) already builds a UI over all three if you'd rather not build
your own — this section explains what each requires, either way.

| `MCPAuthType` | Real-world example | What your UI must collect |
|---|---|---|
| `.none` | Notion, Todoist, Linear-shaped servers | Nothing — just the server URL |
| `.pat` | Static-bearer-token servers (e.g. GitHub-shaped) | A text field for the user's token |
| `.oauthManual` | Servers with no Dynamic Client Registration (e.g. Slack-shaped) | A text field for a pre-registered OAuth client ID |

### It's not "figure out which of the three your target server needs and hardcode it"

`.none` is a safe **default first attempt for any server**, not a guess specific to no-auth
servers:

- If the server needs no auth at all, connecting with `.none` just succeeds.
- If the server supports OAuth (with *or* without Dynamic Client Registration), Core detects the
  401's `WWW-Authenticate: Bearer resource_metadata="..."` header itself and drives the entire
  browser-based flow — no prior knowledge required, no different code path from what the API
  reference below already shows.
- If DCR specifically isn't supported, Core doesn't fail generically — it surfaces the distinct
  `MCPServerError.oauthRegistrationNotSupported` case (deliberately not collapsed into a generic
  error), which is your app's cue to prompt for a manual client ID and retry the exact same
  `addServer` call with `authType: .oauthManual, manualClientID: "..."`.

So `.none` → `.oauthRegistrationNotSupported` → retry with `.oauthManual` is one reactive flow,
not two auth types you have to distinguish up front.

**The one case that genuinely can't be auto-detected: PAT.** A server that wants a static bearer
token and doesn't support OAuth at all just returns a bare 401 with no `resource_metadata`
param — which surfaces as the generic `MCPServerError.authorizationRequired`, indistinguishable
from "this server's OAuth is broken" or any other auth failure. There is no signal in the response
that says "I want a PAT." This is real prior knowledge only the target server's own documentation
can supply — your app (or your app's user) has to already know this before adding that particular
server.

**If an OAuth connection fails for a real, unexpected reason** (not one of the cases above),
`MCPServerError.serverError(_:)`'s message includes the real HTTP status code, URL, and response
body from whichever call in the flow actually failed — e.g. a live rate-limit response comes
through as `"HTTP 429 from https://.../oauth/register: {\"error\":\"Too many requests...\"}"`, not
an opaque failure with no way to tell what went wrong. Don't swallow or re-wrap this message in
your own UI; it's already the most specific information available.

### Recommended default strategy for your own "add server" flow

1. Always attempt `addServer(url:displayName:)` with `authType: .none` first, regardless of what
   the server is.
2. On `.failure(.oauthRegistrationNotSupported)`, prompt for a manual OAuth client ID and retry
   with `authType: .oauthManual, manualClientID:`.
3. Only offer a PAT text field as a fallback the user opts into deliberately (e.g. "this server
   needs an access token instead" as a manually-triggered alternative), not as something you try
   automatically — there's no failure signal that tells you to.

### The manual-OAuth-client gotcha: setup instructions must reference *your* redirect URI

If you write user-facing setup instructions for a Slack-shaped (`.oauthManual`) server — registering
an app and setting a redirect URL on the *server's* side — that redirect URL must be **your app's
own scheme** (`yourapp://oauth/callback`, from §2c — the OAuth redirect URI). Copying another app's setup
instructions verbatim into your own documentation would silently misconfigure every user who
follows it — their server-side app would try to redirect back into the wrong app (or nowhere)
instead of yours.

## 4. Keychain storage — automatic isolation, native API, sandbox-safe

> **You don't reach for this — you get it for free.** There is no "set up credential storage"
> step: `MCPServerManager` persists OAuth tokens and PATs to the Keychain for you, scoped to
> your bundle ID, through the native Security API (so it works under App Sandbox and on the
> Mac App Store). **Read this section only if** you're auditing what lands in the Keychain,
> shipping an unbundled CLI (isolation degrades — see the last paragraph), or want to confirm
> you really don't need to write this yourself.
>
> **Examples that rely on it:** every MCP example; `plate-today`'s Todoist OAuth is the one
> that exercises the token round-trip end to end.

`MCPOAuthTokenStore`/`MCPPATStore` scope their Keychain storage to `Bundle.main.bundleIdentifier`
automatically — you don't need to do anything for isolation between your app and any other app
linking Core on the same Mac.

Both stores also use the native Keychain Services API (`SecItemAdd`/`SecItemCopyMatching`/etc.)
directly, not a shell-out to a system command-line tool — safe to use from a sandboxed app
(including one distributed through the Mac App Store), where shelling out to system binaries is
unreliable or outright unavailable. Confirmed live under App Sandbox, not just by code review —
see §10 (App Sandbox — building for the Mac App Store).

The one thing to know: if `Bundle.main.bundleIdentifier` is `nil` (an unbundled CLI/test target,
not a real `.app`), storage falls back to a fixed, non-isolating string — this is expected and fine
for a dev-only CLI, but means a bare unbundled binary shares storage with any other bare binary.
Package as a real signed `.app` before relying on isolation.

## 5. Walking through a reference app's user experience, step by step

See [`annotated-examples.md`](annotated-examples.md) for this file's full source with every SDK
touchpoint marked, if you'd rather see it all at once than in prose.

This section traces `examples/plate-today`'s "what's on my plate today" flow end to end — launch →
request Calendar/Reminders/MCP-server access → fetch and synthesize via an on-device model → show
the result → clean up. Use this as the template for wiring your own app; the shape is generic, only
the tools differ. The actual source is right there in this repo if you want to read or run it
directly rather than following along in prose.

> **This is your first look at tools + connectors — and there's a shortcut.** Core gives a model
> a tool two ways ([§7a](#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own)):
> **Path A** — drop a ready-made `Tool` into the array (`GetUpcomingEventsTool()`,
> `SearchContactsTool()`, `MCPTool(descriptor:)`, …), one line each, with hard-won
> on-device-model correctness lessons already baked into their descriptions; or **Path B** —
> hand-write a `Tool` struct per connector for full control over its name/schema/description.
> `plate-today` (and this walkthrough) is Path B, deliberately: doing it by hand once makes the
> `requestAccess` → fetch → return-a-string shape visible. **For your own app, reach for Path A
> first** — it's the same permission timing and the same TCC prompts below, with far less code.
> The matched example [`plate-today-tools`](../examples/plate-today-tools/) is this exact app
> rebuilt on Path A — diff the two.

### Step 1 — user double-clicks the app icon

Your app's `init()` should run, before any window exists, as early as possible:

```swift
init() {
    MCPOAuthFlow.redirectURI = "yourapp://oauth/callback"
}
```

This is the single most important line to copy correctly into your own app — the OAuth scheme
override from §2c (the OAuth redirect URI), set before any `connect`/`addServer` call could possibly need it. Your
`@NSApplicationDelegateAdaptor` also installs the OAuth-callback handler (§2d — wiring the OAuth callback) at this
point, and `.handlesExternalEvents(matching: [])` is declared as part of the `Scene` body that
follows — both need to be in place *before* the window is shown, not bolted on reactively later.

### Step 2 — the window appears, showing a spinner

An `.onAppear { model.start() }` on your root view fires once it appears. A minimal view model's
`start()`:

```swift
func start() {
    guard case .idle = state else { return }
    state = .fetching
    Task { await fetch() }
}
```

If `state` is `@Published`, the view re-renders immediately to a `.fetching` case — a
`ProgressView` with something like "Checking your calendar, reminders, and your MCP server…". This
is the *only* user-visible thing that happens synchronously; everything else runs inside the
`Task` kicked off here.

### Step 3 — `fetch()` builds the tool list and starts the model session

First, a hard gate on model availability — if FoundationModels isn't available on this Mac, the
flow should end immediately with a failure state, never reaching any permission prompt at all.
Assuming it's available, your `Tool`-conforming structs are instantiated and handed to a
`LanguageModelSession`. **No permission has been requested and no network call has been made
yet** — FoundationModels doesn't invoke a tool's `call()` until it decides, during generation,
that it needs that tool's output.

`plate-today` builds this list from its own hand-written structs (Path B). The Path A equivalent
is `let tools: [any Tool] = [GetUpcomingEventsTool(), GetUpcomingRemindersTool(), /* … */]` —
Core's ready-made tools, no structs of your own to write; everything below (the availability
gate, the deferred `call()`, the permission timing) is identical.

### Step 4 — the model calls your Calendar tool, which is where the TCC prompt actually happens

The permission prompt is triggered by exactly one line — inside your hand-written tool's
`call(arguments:)` on Path B, or inside `GetUpcomingEventsTool`'s own `call()` on Path A (you
don't write it, but it fires at the same moment — the first time the model invokes the tool):

```swift
let access = await Connectors.requestAccess(.calendar)
```

Core's `Connectors.requestAccess` (see §7) handles the no-Info.plist-key and
previously-denied cases with clearer errors than calling EventKit directly yourself. The system
prompt macOS shows here is only possible because of the entitlement + Info.plist usage string from
§2a/2b; without those, this call fails silently rather than prompting (see §2's
failure-sequence writeup). If the user denies, a well-behaved tool returns a plain string like
`"Calendar access not granted."` — not an error/throw — so the model receives that as the tool's
result and can reason about it in its final summary, rather than the whole request failing. A
Reminders tool works identically, one call (`.reminders`) triggering that separate TCC prompt.

### Step 5 — the model calls your MCP tool, which is where the OAuth browser flow happens

This is the one tool that goes through Core instead of a system framework:

```swift
let connectResult = await manager.addServer(url: serverURL, displayName: "My Server")
```

This single call does capability negotiation *and* auth. If the server has no valid cached token
for this app (see §4, Keychain storage — checked under `Bundle.main.bundleIdentifier`-scoped
storage), `addServer` internally triggers the OAuth authorize flow, which opens the system browser
— this is the moment a real browser window appears on the user's screen. The call suspends until
either the user completes sign-in (the browser redirects back to your app's own scheme, which your
`AppDelegate` from step 1 catches and forwards to `MCPOAuthRedirectListener`, resuming this
suspended call) or the flow times out.

Once connected, search `state.tools` for the specific tool your app wants — real servers can expose
dozens of tools with similar-sounding names (Todoist's real server exposes 47), so match on the
exact tool name, not a loose substring guess. Before calling it, inspect that tool's real JSON
schema (`tool.rawSchema`) rather than assuming its parameters — some tools have defaults that don't
match what their name/description implies (e.g. a "due today" query tool whose own default
silently also includes overdue items unless you explicitly opt out).

That hand-matching + schema-inspection is Path B for MCP. Path A is `MCPTool(descriptor:manager:)` —
hand it one of `state.tools` and it builds a working `Tool` from the live schema, no `Arguments`
struct of your own. [`repo-qa`](../examples/repo-qa/) is that in ~70 lines; see [§7a](#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own).

### Step 6 — the model synthesizes a summary, the UI shows it

`session.respond(to:)`'s result becomes your "ready" state, rendered in a scrollable text view. If
anything upstream threw instead, show the error — deliberately unpolished in the reference app,
since it's meant to be read by developers, not imitated verbatim as production error handling.

### Step 7 — user clicks Done

```swift
Button("Done") {
    model.cleanUpBeforeQuit()
    NSApplication.shared.terminate(nil)
}
```

The reference app's `cleanUpBeforeQuit()` calls `manager.removeServer(_:)` for any server it
connected to — this clears that server's Keychain-stored OAuth token (and any PAT) via the same
code path `MCPServerManager` uses for any server removal, so the next launch starts from a real,
un-cached flow again. This is a deliberate choice appropriate for a dev/demo app — a production app
would very likely *not* want to do this, and would instead leave `manager.disconnect(_:)` or
nothing at all, letting the cached token persist across launches the way a normal app's "stay
signed in" behavior works.

## 6. General API reference

> **This is the MCP client's mechanics** — connect, list tools, call a tool, observe state
> changes, tear down, plus resources and prompts. Use `MCPServerManager` directly when you're
> building your own server-management UI or a headless/CLI integration; if you want a
> ready-made UI over exactly this, `Components` (§11) wraps all of it. The **resources /
> prompts** methods at the end matter only for servers that expose readable content or
> prompt templates, not just tools.
>
> **Examples that use it:** [`repo-qa`](../examples/repo-qa/) is the smallest end-to-end use
> (connect → build tools → run a turn); [`components-demo`](../examples/components-demo/)
> additionally exercises resources and prompts.

```swift
let manager = MCPServerManager()  // NOT a singleton — you own the instance

// Connect (discovery happens as part of this call)
let result = await manager.addServer(url: serverURL, displayName: "My Server")
switch result {
case .success(let state):
    print(state.tools.map(\.name))  // what's actually available
case .failure(let error):
    // .authorizationRequired, .oauthRegistrationNotSupported, .httpError(_), etc. — see
    // MCPServerError for the full set and what each implies about whether retrying makes sense.
}

// Call a tool
let callResult = await manager.callTool(
    server: state.id, tool: "find-tasks-by-date",
    arguments: ["startDate": .string("today")]
)

// React to state changes (servers dict) without SwiftUI/Combine — Core has no UI-framework
// dependency at all
for await servers in manager.serverChanges {
    // ...
}

// Or, if you're in a SwiftUI app and want @Published-style reactivity, Components already ships
// this wrapper — MCPServerManagerObservable, see §11 (Components) — so you don't need to write it
// yourself unless you want to.

// Post-use
manager.disconnect(state.id)   // keep cached tool list, drop the live connection
manager.removeServer(state.id) // forget it entirely, clear its Keychain entries too
```

**On tool selection**: `manager.addServer` returns everything the server exposes; deciding which
tools to actually pass to your AI engine (context-budget management) is entirely up to you — the
SDK doesn't filter this for you. Real servers can expose 40+ tools; don't naively pass all of them
into a `LanguageModelSession` without picking the ones your prompt actually needs. See
`MCPToolDescriptor.estimatedTokens` if you want to reason about this quantitatively, or use
`Components`' `MCPServerPickerView` (§11 — Components), which already builds a per-tool enable/disable UI
over exactly this.

**On tool-calling from FoundationModels**: Core's tools are plain data (`MCPToolDescriptor`,
`callTool`), not FoundationModels `Tool`-conforming types — you write a thin adapter per tool, same
as step 5 above walks through. This is a design choice, not a limitation: it means your app decides
exactly which MCP tool maps to which FoundationModels `Tool`, with whatever argument-shaping logic
that tool's real schema needs — always inspect `MCPToolDescriptor.rawSchema` for a tool before
assuming its parameters.

**A real gotcha when writing a `Tool` that takes no meaningful input**: an empty, zero-property
`@Generable struct Arguments {}` is valid and correct — `ClockTool` in Core is a working example.
Don't add a required-but-unused placeholder field as a workaround for "the framework needs some
schema." FoundationModels sometimes calls a no-input tool with genuinely empty generated content,
and a required field with nothing to satisfy it fails to decode — confirmed live: this produced a
`GenerationError.decodingFailure` in a real tool call, not a hypothetical concern.

**On reading `GenerationError` failures**: `LanguageModelSession.GenerationError`'s default
`NSError` bridging is useless — `error.localizedDescription` (and string-interpolating the error
directly) always prints a generic wrapper like `"The operation couldn't be completed.
(...GenerationError error -1.)"` regardless of which case actually fired, and on-device failures
sometimes surface an opaque nested `com.apple.tokengeneration` error with no further detail either.
Core's `GenerationErrorDescription.describe(_:) async -> String` switches on the real case
(`.guardrailViolation`, `.decodingFailure`, `.exceededContextWindowSize`, `.refusal`, etc.) and
returns its `Context.debugDescription` instead, so a guardrail violation reads differently from a
context-window overflow instead of both looking identical:

```swift
do {
    let response = try await session.respond(to: prompt)
} catch {
    state = .failed(await GenerationErrorDescription.describe(error))
}
```

Also worth knowing: this generic `error -1` sometimes fires as a transient, prompt-independent
on-device hiccup — retrying the exact same request can succeed with no other change (see
`examples/plate-today/README.md`'s Troubleshooting section for a confirmed live instance). If it
persists across several retries, that's no longer this known transient case — use the description
above to find out which real `GenerationError` case is actually firing.

**On extracting more than just tools**: a connected server can also expose **resources** (readable
content, e.g. a document or dataset) and **prompts** (server-defined templates). `manager.
resourcesForSession()`/`.promptsForSession()` list what's currently enabled;
`manager.readResource(server:uri:)`/`manager.getPrompt(server:name:arguments:)` fetch the real
content. `Components`' `MCPResourcesView`/`MCPPromptsView` (§11 — Components) already build a UI over
both if you don't want to write your own.

## 6a. The model layer: local models, routing, sessions

New in the 1.0 (macOS 27) line. Everything above is the MCP client — usable on its own with
Apple's `SystemLanguageModel` and nothing else. The **model layer** is what you reach for when
"which model" becomes a real question in your app: you want to offer a locally-run open-weight
model *and* Apple's on-device model *and* Claude behind one API, let the user (or your own
logic) switch between them, keep one warm between turns, and show download / memory state in
your UI — without your app hand-rolling a provider abstraction.

If your app only ever uses Apple's on-device model, you don't need any of this — construct a
`LanguageModelSession` directly and pass it Core's tools. The rest of this section is for apps
that want more than one model.

> **The one example that exercises all of it: [`code-buddy`](../examples/code-buddy/).** A CLI
> coding agent with a `.heavy` and a `.light` route to locally-run MLX models, Core's Workspace
> tools, an MCP docs server, and streamed output. Every API below has a "→ code-buddy" pointer
> to where it's used for real.

### `LocalLMLab` — the front door (optional)

**Use it when** you want one object that wires the model registry, the MCP manager, and the
connector/workspace facades together, and hands you a ready session. It's entirely optional —
every bare type (`MCPServerManager`, `Connectors`, `WorkspaceAccess`, the providers) stays
public and usable without it.

```swift
let lab = LocalLMLab(configuration: .init(providers: [
    SystemModelProvider(),
    ClaudeModelProvider(auth: .apiKey(myKeyFromKeychain)),
    MLXModelProvider(),                     // from LocalLMLabSDKInference — see below
]))

lab.models      // the @Observable ModelRegistry — providers, routes, residency, downloads
lab.mcp         // MCPServerManager, unchanged from the MCP-only line
lab.workspace   // security-scoped workspace access + ready-made tools
lab.connectors  // Calendar / Reminders / Contacts / Location
```

`lab.snapshot() -> LocalLMLabState` gives you a `Codable` snapshot of the route map + residency
policy + installed-model records to persist wherever you like (the SDK writes nothing to disk);
`lab.restore(from:)` re-applies one. **Use it when** you want the user's model choices to
survive a relaunch. → *code-buddy builds `LocalLMLab` with two providers and maps `.heavy` /
`.light` before the first turn.*

### `ModelProvider` and the built-in providers

**Use a provider when** you're deciding *what models your app can offer at all.* A provider is
"a source of language models" — you register the ones you want, and the registry resolves a
`ModelID` to whichever provider owns its `scheme`:

| Provider | Ships in | `scheme` | For |
|---|---|---|---|
| `SystemModelProvider` | Core | `system` | Apple's on-device model — always there on an Apple-Intelligence Mac |
| `PCCModelProvider` | Core | `pcc` | Apple's Private Cloud Compute model |
| `ClaudeModelProvider(auth:)` | Core | `claude` | Claude, via a host-supplied API key or App Attest client id — the SDK stores neither |
| `MLXModelProvider` | **Inference** | `mlx` | Locally-run open-weight models (Qwen, Llama, …) via MLX |

`ModelProvider` is a protocol — **implement it yourself when** you have a model source the SDK
doesn't ship (a remote inference endpoint, a different local runtime). The registry only ever
talks to the protocol.

### `RouteName` + routing — pick a model without hardcoding one

**Use routes when** you don't want `"mlx:mlx-community/Qwen3-8B-4bit"` sprinkled through your
code. A `RouteName` (`.heavy`, `.light`, `.draft`, or any string you like) is a name your app
maps to a `ModelID`; you pick a route per session. **The SDK owns model residency, never
routing policy** — your app decides which route a given task uses.

```swift
lab.models.route(.heavy, to: ModelID("mlx:mlx-community/Qwen3-8B-4bit")!)
lab.models.route(.light, to: .system)
// later, per task:
let session = try lab.makeSession(route: heavyTask ? .heavy : .light, tools: myTools, instructions: sys)
```

→ *code-buddy's `--route heavy|light` flag flips exactly this; `--heavy` / `--light` override
the model each route points at.*

### `MLXModelProvider` — run open-weight models locally (`LocalLMLabSDKInference`)

**Use it when** you want the model to run entirely on the user's Mac with no API key and no
network at inference time. It's a `DownloadableModelProvider`, so on top of the provider basics
it adds the runtime lifecycle:

```swift
let mlx = MLXModelProvider(residentModelLimit: 1)   // 1 model resident at a time

// Before you download: is this model sane for this machine? (no weights pulled)
let check = try await mlx.validate("mlx-community/Qwen3-8B-4bit")   // PreflightResult
//   → repo reachable? MLX format? architecture supported? weight size vs this Mac's RAM?
//     each failure names its stage.

// Download, tracking progress
for try await event in mlx.download("mlx-community/Qwen3-8B-4bit") {
    if case .progress(_, _, let fraction) = event { updateBar(fraction) }
    if case .completed(let installed) = event { /* InstalledModel */ }
}

// Post-download smoke test — a real prompt + a trivial tool call. Authoritative for
// that model's ModelCapabilities (some downloaded models can't reliably tool-call).
let report = await mlx.capabilityProbe(installed.id)   // ModelCapabilityReport
// This is authoritative. For a starting shortlist of what tool-calls and what doesn't,
// see docs/tested-models.md — but always confirm your own model with capabilityProbe.

mlx.installed        // [InstalledModel] — what's on disk now
mlx.storageUsed      // total bytes of weights
try mlx.remove(id)   // delete weights
```

**The memory story** — the whole reason `MLXModelProvider` isn't just "load and go":

- `residentModelLimit` caps how many models stay in RAM. Switching routes evicts the other.
- `MLXPreflightLimits(maxWeightFractionOfRAM: 0.7)` — `validate` fails a model whose weights
  would exceed this fraction of physical memory, *before* the download.
- `mlx.residencyEventStream` (also forwarded onto `lab.models.events`) emits
  `.warmed` / `.evicted(reason:)` / `.loadProgress` — **use it when** you want a status line
  that shows "loading 45%" vs "reusing warm model", or to tell the user the OS evicted the
  model under memory pressure.
- `unloadResident(_:)` / `unloadAllResident()` — drop weights explicitly (e.g. before a
  memory-heavy operation elsewhere in your app).

→ *code-buddy calls `validate` before its first run, streams `download` progress, and prints
`residencyEventStream` transitions to stderr. Its README has the small-RAM-Mac walkthrough.*

### `makeSession` + `LocalLMLabSession` — a session with your tools + MCP tools merged

**Use it instead of constructing `LanguageModelSession` yourself when** you want the SDK to:
resolve the route → model, build the model, and assemble the tool list (your `tools` **plus**
the enabled MCP session tools from `lab.mcp`, unless `includeMCPTools: false`).

```swift
let session = try lab.makeSession(
    route: .heavy,
    tools: [SearchWorkspaceTool(), ApplyPatchTool(), myGitTool],
    instructions: "You are a coding assistant.",
)
// Drive the tool loop yourself — nothing here runs an agent loop:
let answer = try await session.respond(to: task)
// or opt out of the SDK's retry wrapper and use Apple's session directly:
for try await snapshot in session.languageModelSession.streamResponse(to: task) { … }
```

`session.route` / `session.modelID` tell you what actually backs it. → *code-buddy's whole
`makeSession(route:tools:instructions:)` call, tools = Workspace tools + its host-owned
`GitTool` / `RunTestsTool`.*

### `LocalLMLabSession.events` — the side-channel Apple's streaming doesn't give you

**Use it when** your UI needs to show what's happening *around* generation — a spinner per
tool call, a "compacting context…" notice. Token streaming stays on
`languageModelSession.streamResponse`; `events` carries only the rest:

```swift
for await event in session.events {
    switch event {
    case .toolCallStarted(let id, let name):   showRunning(name)
    case .toolCallFinished(let id, let name, let failed): clearRunning(name, failed: failed)
    case .contextCompacted(let removed):       toast("Trimmed \(removed) old messages")
    case .modelLoadProgress(let fraction):     updateBar(fraction)   // with a local model
    @unknown default: break
    }
}
```

→ *code-buddy's `→ tool` / `✓ tool` stderr trace is this stream.*

### `ContextBudget` + `RetryPolicy` — surviving a long session

**Use these when** your app has long-running sessions (a coding agent, a chat that goes for
hours) that will eventually fill the model's context window.

- `session.contextBudget` — `windowTokens`, `lastInputTokens`, `fractionUsed` (best-effort).
  Show a "context 78% full" gauge; decide when to start a fresh session.
- `session.retryOnContextOverflow = RetryPolicy(maxRetries: 2, compact: { transcript in
  myTrim(transcript) })` — when a turn throws `contextSizeExceeded`, the SDK calls your
  `compact` hook, rebuilds the session with the smaller transcript, emits `.contextCompacted`,
  and retries. Only applies to the SDK's `respond` wrappers; with no `compact` hook it just
  rethrows. → *code-buddy prints `contextBudget` after each run.*

### `ModelAvailability` — gray out a model and say why

**Use it when** you're building a model picker and need to disable an entry with a reason.
`lab.models.availability(for: id)` (or `provider.availability(for:)`) returns:
`.available` · `.notDownloaded` (offer a download button) · `.needsCredential` (prompt for the
API key) · `.unavailable(kind:detail:)` where `kind` is machine-readable
(`.ineligibleHardware`, `.notEnabled`, `.modelNotReady`, `.unsupportedModel`, `.providerError`,
`.noProvider`) so you can branch without parsing `detail`. Components' `ModelPickerView` binds
to this directly.

### `WorkspaceAccess` + the Workspace tools — let the model touch files

**Use it when** the model needs to read or edit files in a folder the user picked. `WorkspaceAccess`
owns the security-scoped-bookmark bracket; the ready-made tools (`SearchWorkspaceTool`,
`WorkspaceTreeTool`, `ReadWorkspaceFileTool`, `ReadFileRangeTool`, `ListWorkspaceFilesTool`,
`ApplyPatchTool`, `EditWorkspaceFileTool`, `WriteWorkspaceFileTool`, `DeleteWorkspaceFileTool`)
are FoundationModels `Tool`s you drop straight into `makeSession`. → *`code-buddy` and
[`workspace-buddy`](../examples/workspace-buddy/) (the Core-only, no-MLX version) both use these.*

## 7. Connectors: Calendar, Reminders, Contacts, Location

> **Reach for these when** your app's value is "the model can see — or change — my calendar,
> reminders, contacts, or where I am," and you don't want to hand-roll the EventKit /
> Contacts / CoreLocation permission dance and its error/settings-redirect edge cases. Core
> gives you one uniform request/status/error lifecycle (`Connectors`) across all four, plus
> per-connector read *and* write methods. **Exposing the write methods to a model is entirely
> your decision** — Core enforces nothing beyond the OS's own TCC grant (see the "no built-in
> gate" note below).
>
> **Examples that use them:** [`plate-today`](../examples/plate-today/) reads Calendar +
> Reminders + Contacts via hand-written `Tool` adapters (Path B);
> [`plate-today-tools`](../examples/plate-today-tools/) is the identical app rebuilt on
> Core's ready-made connector `Tool`s (Path A) — diff the two. Neither wires the write
> methods; those ship but aren't demonstrated in an example yet.

Core ships four permission-gated connectors, each wrapping the relevant system framework
(EventKit for Calendar/Reminders, Contacts, CoreLocation) with the request/status/error handling
already worked out. A unified `Connectors` facade covers the permission lifecycle (identical in
shape across all four); each connector's own type covers its actual data-fetching, which differs
per connector.

```swift
// Unified: check/request/manage permission for any connector the same way
if !Connectors.isAuthorized(.calendar) {
    let result = await Connectors.requestAccess(.calendar)
    if !result.granted {
        print(result.error ?? "Calendar access denied")
        if result.needsSystemSettings { Connectors.openSystemSettings(for: .calendar) }
        return
    }
}

// Per-connector: actual data, since each connector's data shape is different
let events = CalendarAccess.upcomingEvents(days: 7)
let reminders = await RemindersAccess.upcomingReminders(days: 7)
let contacts = ContactsAccess.search(query: "Jane", limit: 10)
let location = await LocationAccess.shared.currentLocation()
```

**Calendar, Reminders, and Contacts also have write methods.** `CalendarAccess.addEvent(title:
start:end:)` creates a new event; `.updateEvent`/`.deleteEvent` locate an *existing* one by its
exact title plus the day it's currently on — not an identifier. `RemindersAccess.addReminder`
creates a new reminder; `.updateReminder`/`.deleteReminder` (both `async`) locate an existing one
by title, with an optional current due date to disambiguate reminders sharing a title (a reminder
may have no due date at all, unlike an event's date, which is required). `ContactsAccess.
addContact` creates a new contact; `.updateContact`/`.deleteContact` locate an existing one by
given name, with an optional current family name to disambiguate. `newPhoneNumbers`/`newEmails`
on `updateContact`, when provided, replace that contact's entire existing list rather than adding
to it. Full signatures are in §12 (the full function/type reference) below.

**Why name-based lookup, not an identifier** (`EventSummary`/`ReminderSummary`/`ContactSummary`
still carry `eventIdentifier`/`calendarItemIdentifier`/`identifier` for any consumer that wants
the raw token, but `update*`/`delete*` no longer take it): two real problems with identifier-based
lookup, found the hard way. Some calendar backends (Exchange/Outlook-synced calendars especially)
return identifiers long enough to meaningfully bloat an LLM's context just by appearing in a
listing; and, separately, a small on-device model calling these as tools proved unreliable at
faithfully copying an opaque identifier string across two tool calls. Locating by the same
title/name a person actually thinks in terms of fixed both. The one honest cost: for Contacts,
name collisions are common enough in a real address book that the "found more than one match"
error fires more often than it would for Calendar/Reminders (same-titled events on the same day
are rare) — an accepted tradeoff, not a bug; the error tells the caller to add a family name or
search first.

**If you're building your own model-callable tools on Core**, carry forward one naming lesson:
keep lookup parameters (`onDate`, `dueDate`, `familyName`, …) and change parameters
(`newDate`, `newTime`, `newFamilyName`, …) under clearly distinct names — never a bare
`date`/`familyName` serving double duty as both "search by" and "change to." A bare shared name
was tried first here and shipped a real bug: asked to "change the date," the model put the *new*
date into the field literally named `date` instead of a separate change field, so the lookup
searched on the wrong date and failed.

**There is no built-in gate on any of this beyond the TCC grant itself.** Unlike LocalLM Lab the
product, which has its own app-specific "Full Access" toggle deciding whether a given session
exposes update/delete as tools the model can call at all, Core has no equivalent concept — that's
UI/IPC behavior specific to that app, not something this SDK provides or enforces. The moment a
user grants Calendar/Reminders/Contacts access, every method above (read and write) is callable
unconditionally. Whether and how to expose update/delete to a model — as a `Tool` at all, behind
your own confirmation UI, restricted by your own app-level setting — is entirely your design
decision as the integrating developer.

Each connector requires its own Info.plist usage-description key and entitlement, same pattern as
§2a/2b — see there for Calendar/Reminders; Contacts needs
`NSContactsUsageDescription` + `com.apple.security.personal-information.addressbook`, Location
needs `NSLocationUsageDescription` + `com.apple.security.personal-information.location`.
`examples/plate-today`'s `SearchContactsTool` and (build-time opt-in) location/weather tools are
working examples of each, including the exact packaging-script changes each one needs — note that
the reference app only wires up the read methods; the write methods above are equally available
but not currently demonstrated there.

**One real side effect worth knowing about**: requesting Location access briefly switches your
app's own `NSApplication.ActivationPolicy` to `.regular` for the duration of the fetch, then
restores it — required on-platform for CoreLocation to actually deliver a location fix to a
background-style (`.accessory`) app. If your app deliberately runs with no Dock icon, you'll see
that policy flip, briefly, while a location request is in flight. This isn't a bug to work around;
it's what makes Location work at all in that configuration.

**`tccutil reset Location <bundle-id>` doesn't work** — a real macOS limitation, not specific to
this SDK. It fails with "Failed to reset Location approval status." `tccutil reset All <bundle-id>`
is the one command confirmed to actually clear Location along with everything else; to reset
*only* Location, System Settings → Privacy & Security → Location Services → remove the app from
the list is the only reliable path found so far. Calendar/Reminders/Contacts all reset
individually fine.

### Clock and Weather: no permission needed, just drop them in

Two more tools ship in Core that aren't part of the `Connectors` facade above, because they're not
permission-gated at all — no entitlement, no Info.plist key, nothing to request:

```swift
let tools: [any Tool] = [ClockTool(), WeatherTool(), /* ... */]
let session = LanguageModelSession(tools: tools)
```

- **`ClockTool`** returns the current wall-clock date/time — fully local, no network.
- **`WeatherTool`** takes a place name and returns current conditions + a 7-day forecast, via
  Open-Meteo (keyless, no API key to manage). The one network call among these two.

Both accept an optional custom `description` in their initializer (`ClockTool(description:
"...")`) if you want to override how the model sees the tool — otherwise each falls back to its own
`defaultDescription`.

**Reach for `ClockTool` specifically** whenever a session deals in relative dates ("tomorrow",
"next week") — no local model has a built-in notion of "now", and pairing it with the
Calendar/Reminders tools is the practical fix for their date-grounding caveat above.
`ClockTool` is used by nearly every example; `code-buddy` and `repo-qa` include it as a
cross-check that tool-calling works at all.

### 7a. Two paths to tool-calling: ready-made Tools, or write your own

> **This is the decision you hit** the moment you want a `LanguageModelSession` to actually
> *call* a connector or MCP tool. **Path A** (Core's ready-made `Tool`s / `MCPTool`) is the
> default — drop them in an array, done, with hard-won on-device-model guidance baked into
> their descriptions. **Path B** (hand-write the adapter) is for when you need control over a
> tool's name, schema, or description. They mix freely.
>
> **Examples per path:** Path A — [`plate-today-tools`](../examples/plate-today-tools/)
> (connectors), [`repo-qa`](../examples/repo-qa/) (`MCPTool`),
> [`workspace-buddy`](../examples/workspace-buddy/) / [`code-buddy`](../examples/code-buddy/)
> (Workspace tools). Path B — [`plate-today`](../examples/plate-today/) (connectors) and §5
> Step 5 (MCP, by hand).

Everything above (`CalendarAccess`, `RemindersAccess`, `ContactsAccess`, `LocationAccess`,
`MCPServerManager`) is a plain data-access layer — calling `CalendarAccess.updateEvent(...)`
doesn't require FoundationModels at all. Turning one into something a `LanguageModelSession` can
call is a separate decision, and Core gives you two ways to make it:

**Path A — ready-made `Tool`s (recommended default).** Every connector above also has a
ready-to-use `Tool`-conforming wrapper in Core, same one-line drop-in as `ClockTool`/`WeatherTool`:

```swift
let tools: [any Tool] = [
    ClockTool(),
    GetUpcomingEventsTool(), AddCalendarEventTool(),
    GetUpcomingRemindersTool(), AddReminderTool(),
    SearchContactsTool(), ListContactsTool(),
    GetCurrentLocationTool(),
]
let session = LanguageModelSession(tools: tools)
```

The mutating ones — `UpdateCalendarEventTool`/`DeleteCalendarEventTool`,
`UpdateReminderTool`/`DeleteReminderTool`, `AddContactTool`/`UpdateContactTool`/
`DeleteContactTool` — take no permission gate of their own (no "Full Access" flag, matching this
section's already-stated SDK philosophy: that decision is entirely yours). Whether to expose them
at all is a plain array-membership choice — include them in `tools` when your UI is ready to let
the model delete something, don't when it isn't.

These wrappers exist because real, observed on-device model failures shaped their design, and
that guidance is baked in verbatim rather than left for you to rediscover independently:
- **Lookup by title/name + date, never by identifier.** Some calendar backends' identifiers are
  long enough to blow the model's context window just by appearing in a listing, and the model
  proved unreliable at copying one faithfully across two tool calls. A human thinks "the Birthday
  event on Aug 25," not a per-backend token — so do these tools.
- **`current*` vs `new*` are always distinct field names, never shared.** A single field doing
  double duty as both "find by" and "change to" (e.g. a bare `date`) invites the model to put a
  *new* date where the *lookup* date belongs — confirmed as a real, reproduced bug before the
  split existed.
- **Contacts' `search`/`list` output shows `givenName`/`familyName` as separate labeled fields.**
  A caller only ever seeing a composed display name has no reliable way to know where to split it
  for `updateContact`/`deleteContact`'s separate name fields.
- **`RemindersTools`' date handling carries a caveat, not a fix**: the model has no built-in
  notion of "today" — Core stays raw in/raw out and doesn't inject anything into your session on
  its own — so a relative phrase like "tomorrow" can resolve to the wrong day, or the wrong year
  entirely, unless your app's system prompt/session state grounds it (pairing these with
  `ClockTool` is the practical mitigation, not a guarantee).

**Path B — write your own adapter**, exactly as §5 Step 4 walks through by hand: call
`CalendarAccess`/`RemindersAccess`/`ContactsAccess`/`LocationAccess` directly, choose your own
tool names, schemas, and descriptions. Full control, but you're on your own for the pitfalls
above. Both paths coexist — Path A is a thin wrapper over Path B, not a replacement for it, so
mixing (ready-made Calendar tools alongside a hand-written Contacts adapter, say) is fine.

**MCP gets the same two paths.** §5 Step 5 is Path B for MCP: match a tool by name out of
`state.tools`, inspect its `rawSchema` yourself, hand-write a matching `@Generable` `Arguments`
struct. `MCPTool` is Path A — it builds a `Tool` at runtime directly from an `MCPToolDescriptor`,
no `Arguments` struct required:

```swift
let descriptor = state.tools.first { $0.name == "search_issues" }!
let tool = try MCPTool(descriptor: descriptor, manager: manager)
let session = LanguageModelSession(tools: [tool])
```

It works by turning the tool's real JSON Schema (`rawSchema`) into a FoundationModels
`DynamicGenerationSchema` at init time — the common, well-behaved subset real MCP servers emit
(object/properties/required, array/items, string/number/integer/boolean, string enums) converts
cleanly; anything past that (`oneOf`/`anyOf` unions, `$ref`, `const`, regex `pattern`) degrades to
a free-form string leaf rather than failing the whole tool, since the remote server is still the
real source of argument validation. `MCPTool(descriptor:manager:)` is a throwing initializer —
call it per-tool inside a loop and skip (or fall back to a hand-written Path B adapter for) any
tool whose schema doesn't build, rather than letting one malformed tool take down your whole list.

## 8. Filesystem access: security-scoped bookmarks (example, not in Core)

> **You hit this when** you want the model to read or edit files in a folder the user picks —
> a coding assistant, a "summarize this project" tool, a notes agent. Two halves: getting a
> usable URL that survives relaunch under sandboxing (this section — **copy-paste example
> code, not a Core API**) and then acting on it (§8a — that half *is* Core:
> `WorkspaceAccess` + the Workspace `Tool`s).
>
> **Examples:** [`workspace-buddy`](../examples/workspace-buddy/) is the sandboxed folder
> picker + `WorkspaceTools` end to end; [`code-buddy`](../examples/code-buddy/) skips the
> picker (a CLI passes a path) and goes straight to the Workspace tools.

Unlike the four connectors above, filesystem access to a user-picked file or folder is **not**
part of Core, and isn't planned to be. The reason is structural, not an oversight: the actual
picker UI (`NSOpenPanel`) has to live in your app — Core has no UI of its own, by design, same as
the MCP server connect/auth UI in §3 (MCP auth options). There's no meaningful "unified API" to offer here the
way there is for the four TCC-gated connectors, since the picker itself is host-app UI, not
something a library call can produce.

What Core *can't* help you avoid is the trickier part once a folder is picked: under sandboxing, a
plain absolute path stops being usable the moment your app restarts — you need a **security-scoped
bookmark**, resolved and re-accessed explicitly on every launch. Below is a complete, working
example (not shipped as SDK code — copy what you need):

```swift
import AppKit
import Foundation

enum FolderAccess {
    // Call from a "Choose Folder…" button. Persists a security-scoped bookmark to UserDefaults so
    // access survives app relaunches — plain path strings don't, once your app is sandboxed.
    @MainActor
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        UserDefaults.standard.set(bookmark, forKey: "folderBookmark")
        return url
    }

    // Call before every use of the folder, including right after pickFolder() — resolving a
    // bookmark doesn't grant access by itself; you must bracket actual use between
    // startAccessingSecurityScopedResource() and stopAccessingSecurityScopedResource().
    static func resolveBookmarkedFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: "folderBookmark") else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            // The bookmark still resolves, but macOS wants a fresh one recorded (e.g. the
            // volume was renamed) — re-derive and persist it now rather than letting it go
            // stale again on the next launch.
            if let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: "folderBookmark")
            }
        }
        return url
    }

    // Bracket every actual read/write with this, even immediately after pickFolder() — holding
    // scoped access open longer than needed is the usual mistake; grab it, do the work, release.
    static func withFolderAccess<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url = resolveBookmarkedFolder() else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }
}
```

Required entitlements for this to work under App Sandbox:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

### 8a. WorkspaceAccess/WorkspaceTools: what Core gives you once you have that URL

Once you have a resolved, access-bracketed root `URL` from the pattern above,
`WorkspaceAccess` — an ordinary Core type, not a permission-gated connector — is what actually
reads and writes inside it: `listFiles`/`readFile`/`writeFile`/`editFile`/`deleteFile`, each
scoped to the root with the same symlink-escape check the picker pattern itself doesn't need to
worry about. No `requestAccess()` here — there's no OS dialog for this, the picker *is* the
consent, entirely on your side.

`editFile` — the one write operation actually meant for AI-assisted modification of an existing
file — is search-and-replace, not a unified-diff/patch format: `oldString`/`newString`, and it
fails loudly if `oldString` isn't found or isn't unique in the file (pass `replaceAll` if you
really mean every occurrence). This was a deliberate choice, not an obvious one: a small on-device
model reliably producing correct line numbers and context lines for a real diff format is a much
harder ask than quoting one exact, minimal, uniquely-identifying snippet — and it's a much simpler,
safer thing for Core to validate and apply. `writeFile` is create-only (fails if the file already
exists) — use `editFile` to modify something that's already there, same add-vs-update split
Calendar/Reminders/Contacts already use.

Path A ready-made Tools ship too, same shape as everywhere else in Core: `ListWorkspaceFilesTool`,
`ReadWorkspaceFileTool`, `WriteWorkspaceFileTool`, `EditWorkspaceFileTool`, `DeleteWorkspaceFileTool`
— each takes the root `URL` at init. `DeleteWorkspaceFileTool` isn't wired into
`examples/workspace-buddy`'s default tool list — a coding assistant that can delete files
unprompted is a meaningfully bigger risk than one that can only read/create/edit — but it's there
if your own app wants it.

**One real gotcha, not covered by §8's own example**: that section's `withFolderAccess<T>(_:)` is
synchronous, bracketing a single, quick access. If you're handing these tools to a
`LanguageModelSession` — which can invoke several of them over the course of one
`respond(to:)` call — the security-scoped access window has to stay open for that *whole* async
call, not just a synchronous setup step. `examples/workspace-buddy` shows the async-aware version
(`withFolderAccessAsync<T>(_:)`) this actually requires.

## 9. What's NOT in Core yet

- **No filesystem picker/bookmark UI in Core, and not planned** — a folder picker is host-app
  UI and Core ships no UI at all. But you're not writing it from scratch: §8 (Filesystem
  access — security-scoped bookmarks) has a complete, copy-pasteable `FolderAccess`
  (`NSOpenPanel` + security-scoped bookmark persistence + the async-aware access window a
  `LanguageModelSession` needs), and
  [`workspace-buddy`](../examples/workspace-buddy/) is a full reference app that does exactly
  this. What *is* in Core: `WorkspaceAccess`/`WorkspaceTools` (§8a — Workspace tools) — the read/write/edit logic
  for once you have a resolved folder URL.
- ~~No ready-made `Tool` wrappers for the connectors, no MCP-to-`Tool` bridge.~~ Both now exist —
  see §7a (ready-made vs. hand-written tools).
- ~~No model abstraction — you construct a `LanguageModelSession` yourself.~~ The 1.0 line adds
  the model layer (§6a): `LocalLMLab` / `ModelRegistry` / providers / `MLXModelProvider` (in
  `LocalLMLabSDKInference`) / `makeSession`. Still optional — the MCP-only path is unchanged.
- **`ModelAvailability` is a non-frozen `enum`.** If you `switch` over it exhaustively you need
  an `@unknown default` — new cases can land in a minor version. (Same for `ResidencyEvent` /
  `SessionEvent` / `DownloadEvent` / `MCPConnectionStatus` / `MCPServerError`.)
- **No public API stability guarantee.** `1.0.0-beta.N` makes none. Access levels have been fixed
  reactively as real usage surfaced gaps — if you hit "X is inaccessible due to internal
  protection level" on something that looks like it should be public, it probably should. File it.
- **No logging of prompts, responses, or tool calls, on by default or otherwise.** Core doesn't
  write a persisted trace of what the model saw or said anywhere, and gives you nothing to opt out
  of — there's simply nothing there. If your app wants that kind of record, you build and own it
  yourself.

## 10. App Sandbox — building for the Mac App Store

Core has been tested under App Sandbox — confirmed via a real sandboxed, Developer-ID-signed,
notarized build (not just code review), not through the actual MAS submission pipeline itself yet.
Here's exactly what's needed and what was actually verified.

### 10a. Entitlements

Add `com.apple.security.app-sandbox` alongside whichever connector entitlements from §2b
you're already using:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

**`com.apple.security.network.client` is easy to miss and fails silently, not loudly.** Under
sandbox, any outbound network connection is blocked without it — no crash, no error dialog, just
a request that hangs or times out. This bit a real reference app during testing: Weather failed
with a generic "connectivity issues" message and the MCP client's server connections never
completed, both traced back to this one missing key. If you're using the MCP client, `WeatherTool`,
or anything else that reaches the network, you need this entitlement — it's not optional the way
the Calendar/Reminders/Location entitlements are (those are only needed if you're using that
specific connector).

### 10b. What's confirmed working under sandbox, live-tested

- **Calendar, Reminders** — including the actual first-time TCC grant prompt (not just a
  pre-existing grant carried over from testing an unsandboxed build under the same bundle ID —
  see the caution below).
- **The MCP client, end-to-end**, including OAuth: connect, sign in via the system browser,
  redirect back into the app, tool calls. No entitlement needed beyond `network.client` — the
  OAuth redirect is a URL-scheme handoff (§2c–2d, the OAuth redirect/callback), not a local HTTP listener, so
  `com.apple.security.network.server` is not needed for this.
- **Keychain token storage** (`MCPOAuthTokenStore`/`MCPPATStore`, §4) — round-tripped
  correctly under the sandboxed per-app-container Keychain access group.

**Not yet tested under sandbox**: Contacts, Location's accuracy/reverse-geocoding behavior beyond
"it returns something" (a real, pre-existing, non-sandbox-specific bug in reverse geocoding was
hit during testing, unrelated to sandboxing itself).

### 10c. A testing caution: reset TCC before you trust a "no prompt" result

If you add the sandbox entitlement to an app you've already tested unsandboxed under the same
bundle identifier, TCC may silently honor grants from that earlier testing — you'll see no
permission prompt at all, and it's genuinely ambiguous whether that means "already granted" (fine)
or "the prompt is broken under sandbox" (not fine) until you check. Before trusting a "worked with
no prompt" result while testing a newly-sandboxed build, reset first:

```bash
tccutil reset Calendar <your-bundle-id>
tccutil reset Reminders <your-bundle-id>
tccutil reset AddressBook <your-bundle-id>
tccutil reset All <your-bundle-id>   # Location can't be reset individually, see §7 (Connectors)
```

### 10d. One-time Apple Developer Portal setup for MAS signing

Three artifacts, each depending on the previous one, all created at
[developer.apple.com/account](https://developer.apple.com/account) — a real membership required,
and this is genuinely portal/GUI work, not something scriptable. Done once per app; the
certificate can be reused across apps, the App ID and profile are per-app.

**1. An Apple Distribution certificate** (covers both app and installer signing in the modern
single-certificate flow — some older accounts may still use the separate "3rd Party Mac Developer
Application"/"3rd Party Mac Developer Installer" pair instead, which works the same way).

- Easiest: **Xcode → Settings (⌘,) → Accounts → select your team → Manage Certificates… → + →
  Apple Distribution.** Xcode generates the CSR and installs the certificate automatically.
- Manual alternative: generate a CSR yourself first (**Keychain Access → Certificate Assistant →
  Request a Certificate From a Certificate Authority…**, save to disk), then **Certificates,
  Identifiers & Profiles → Certificates → + → Apple Distribution**, upload the CSR, download the
  resulting `.cer`, double-click to install.
- Verify: `security find-identity -v -p codesigning` should list `"Apple Distribution: <your
  name> (<TEAMID>)"`.

**2. An App ID**, explicit (not wildcard), matching your app's real bundle identifier.

**Starting from `plate-today` or `components-demo`? Change `CFBundleIdentifier` in `Info.plist`
first.** App ID registration is global across Apple's entire Developer Portal, not scoped per
team. `plate-today`'s bundle ID (`lab.locallm.sdk.reference.platetoday`) is already registered
under this project's own team (it has a real MAS provisioning profile — see the walkthrough
below), so no other developer's account can register it. `components-demo` has no MAS path today
and its bundle ID (`lab.locallm.sdk.reference.componentsdemo`) isn't currently registered as an
App ID at all — but don't build a real product under it regardless: it's this project's own
reverse-DNS namespace, and if a MAS path is ever added for `components-demo` later, this project
would register it too. Building and running either example locally works fine unmodified —
`CFBundleIdentifier` doesn't need to be globally unique for Developer ID/ad-hoc signing — but MAS
submission of your own app needs your own bundle ID from the start.

- **Identifiers → + → App IDs → App → Explicit Bundle ID** (e.g. `com.yourcompany.yourapp`).
- Leave every Capability unchecked unless something you're using genuinely needs an App
  ID-level capability (iCloud, Push Notifications, etc.) — App Sandbox, network client, and the
  Calendar/Reminders/Contacts/Location entitlements are all declared directly in the entitlements
  file (10a), not toggled here.

**3. A Mac App Store distribution provisioning profile**, tying the App ID to the certificate.

- **Profiles → + →** the Distribution-section option for App Store (labeled "Mac App Store
  Connect" or "Mac App Store" depending on the portal's current wording — not Development, not
  Developer ID) **→** select the App ID from step 2 **→** select the certificate from step 1 **→**
  name it **→ Generate → Download**.
- **Install it** — double-click the downloaded `.provisionprofile`, or drag it onto Xcode's Dock
  icon, or **Xcode → Settings → Accounts → select team → Download Manual Profiles** (pulls
  everything associated with the account, not just this one file).
- **Where it actually lands matters**: modern Xcode installs profiles to `~/Library/Developer/
  Xcode/UserData/Provisioning Profiles/`, **not** the older `~/Library/MobileDevice/Provisioning
  Profiles/` path that's still commonly referenced in older docs/scripts online — check the
  right location if a script can't find it. Verify and read its contents with:
  ```bash
  ls ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
  security cms -D -i <path-to-file> | plutil -p - | grep -E "Name|application-identifier|TeamIdentifier|UUID|ExpirationDate"
  ```
  Confirm `application-identifier` matches `<TEAMID>.<your-bundle-id>` and `Name` is what you'd
  expect before assuming it's the right one.

`examples/plate-today/packaging/build-and-sign-mas.sh` is a complete, working example of the
Apple-Distribution-signed, sandboxed `.pkg` build this setup enables — Developer ID signing +
notarization is the other supported path (`build-and-sign.sh`), for distributing outside the Mac
App Store.

## 11. Components: prebuilt SwiftUI for MCP server management

> **Reach for this when** you want a working "manage MCP servers" screen — add / remove /
> reconnect, all three auth types from §3, per-tool and per-resource enable/disable,
> resource + prompt browsing — without building that UI yourself. It's SwiftUI, entirely
> optional, and layered strictly on Core's public API (nothing here you couldn't write). Also
> ships `ModelPickerView` / `ClaudeAuthField` for the model layer (§6a). **Skip it if** your
> app has no user-facing server management, or your design is too bespoke to reuse these views
> — go straight to `MCPServerManager` (§6 — the MCP client API).
>
> **Example that uses it:** [`components-demo`](../examples/components-demo/) — essentially
> the whole app is these views.

See [`annotated-examples.md`](annotated-examples.md) for `components-demo`'s full source with
every `Components`/`Core` touchpoint marked.

Everything above is `Core` — a plain Swift engine with no UI dependency. `Components` is a
separate, optional package built on top of Core's public API, for when you don't want to write
your own MCP-server-management UI from scratch. See [`examples/components-demo`](../examples/components-demo)
for a working reference app using all of it.

- **`MCPServerManagerObservable`** — an `ObservableObject` wrapper around `MCPServerManager`, for
  SwiftUI apps that want `@Published`-style reactivity without writing the wrapper themselves (see
  §6's note).
- **`MCPServerPickerView`** — add/list/reconnect/disconnect/remove MCP servers, all three auth
  types from §3, per-tool and per-resource enable/disable, and a "Save As…" action that
  exports a server's tools/resources/prompts to a text file.
- **`MCPOAuthWaitingView`** — shown while an OAuth sign-in is in flight in the system browser;
  `MCPServerPickerView` already uses this internally during its own add-server flow.
- **`MCPResourcesView`** / **`MCPPromptsView`** — browse a session's enabled resources/prompts and
  read/expand one, via callbacks (`onAttach`/`onUse`) so your app decides what to actually do with
  the result — append it to a text field, feed a session, save it, whatever fits your UI.

None of these views hold persistence of their own — call `manager.core.restore(from:)` yourself at
launch with whatever you've saved, the same shape `MCPServerManager`'s own doc comment on that
method describes.

## 12. Full function/type reference

Everything public in `LocalLMLabSDKCore`, `LocalLMLabSDKInference`, and `LocalLMLabSDKComponents`,
grouped by area. This is the flat list; sections 1–11 above are the narrative version with context
and gotchas — use this one when you just need to check a signature.

> The machine-checked source of truth is [`api-surface.md`](api-surface.md) (regenerated from the
> compiled `.swiftinterface`s). If this section and that one disagree, that one is right — file it.

**Which example shows each area** (source you can read + run):

| API area | Example | Path |
|---|---|---|
| The model layer — `LocalLMLab`, routing, `MLXModelProvider`, sessions, residency, `ContextBudget` | [`code-buddy`](../examples/code-buddy/) | — |
| Workspace tools (`WorkspaceAccess` / `SearchWorkspaceTool` / `ApplyPatchTool` / …) | [`workspace-buddy`](../examples/workspace-buddy/) (Core-only) · `code-buddy` | A |
| Connectors + ready-made connector `Tool`s | [`plate-today-tools`](../examples/plate-today-tools/) | A |
| Connectors via hand-written `Tool` adapters | [`plate-today`](../examples/plate-today/) | B |
| MCP client + OAuth (Todoist) + Keychain | `plate-today` / `plate-today-tools` | — |
| `MCPTool` built from a live server schema (no hand-written `Arguments`) | [`repo-qa`](../examples/repo-qa/) | A |
| `Components` — `MCPServerPickerView` / `MCPServerManagerObservable` / resources / prompts | [`components-demo`](../examples/components-demo/) | — |

### The model layer (`LocalLMLab`, routing, providers, sessions)

```swift
// --- front door ---------------------------------------------------------------
@MainActor final class LocalLMLab {
    struct Configuration { var providers: [any ModelProvider]; var state: LocalLMLabState? ; init(providers: [any ModelProvider] = [], state: LocalLMLabState? = nil) }
    let models: ModelRegistry
    let mcp: MCPServerManager
    let connectors: ConnectorsFacade    // .calendar/.reminders/.contacts/.location permission lifecycle
    let workspace: WorkspaceFacade
    init(configuration: Configuration = .init())
    func snapshot() -> LocalLMLabState                 // route map + residency + installed records; NOT weights
    func restore(from state: LocalLMLabState)
    // from LocalLMLab+makeSession:
    func makeSession(route: RouteName, tools: [any Tool] = [], instructions: String? = nil, includeMCPTools: Bool = true) throws -> LocalLMLabSession
}

struct LocalLMLabState: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var version: Int
    var routes: [RouteName: ModelID]
    var residency: ModelResidency
    // + installed-model records
}

// --- registry ----------------------------------------------------------------
@MainActor final class ModelRegistry {
    var providers: [any ModelProvider] { get }
    var routes: [RouteName: ModelID] { get }
    var residency: ModelResidency                       // set .keepWarm(routes) to prewarm + hold
    let events: AsyncStream<ResidencyEvent>
    func applyResidency() async
    func route(_ route: RouteName, to id: ModelID)
    func modelID(for route: RouteName) -> ModelID?
    func register(_ provider: any ModelProvider) throws  // throws .schemeAlreadyRegistered
    func provider(for id: ModelID) -> (any ModelProvider)?
    func availability(for id: ModelID) -> ModelAvailability
    var downloadableProviders: [any DownloadableModelProvider] { get }
    var installedModels: [InstalledModel] { get }
    var knownModels: [ModelID] { get }                  // union of providers' advertisedModels
    var downloads: [ModelID: Double] { get }            // in-flight, fraction 0...1
    func startDownload(_ repoID: String) async throws -> InstalledModel
}
enum ModelRegistryError: Error, Equatable, CustomStringConvertible { case schemeAlreadyRegistered(String); case noDownloadableProvider }

// --- providers -------------------------------------------------------------
protocol ModelProvider: Sendable {
    static var scheme: String { get }
    func owns(_ id: ModelID) -> Bool                    // default: id.scheme == Self.scheme
    func languageModel(for id: ModelID) throws -> any LanguageModel
    func availability(for id: ModelID) -> ModelAvailability
    func prewarm(_ id: ModelID) async                   // no-op default
    var advertisedModels: [ModelID] { get }             // [] default
}
protocol DownloadableModelProvider: ModelProvider {
    var installed: [InstalledModel] { get }
    func download(_ repoID: String) -> AsyncThrowingStream<DownloadEvent, any Error>   // 0+ .progress, then exactly one .completed, or throws
    func validate(_ repoID: String) async throws -> PreflightResult                    // no weights pulled
    func capabilityProbe(_ id: ModelID) async -> ModelCapabilityReport                 // authoritative for that model's ModelCapabilities
    func remove(_ id: ModelID) throws
    var storageUsed: Int64 { get }
    var residencyEventStream: AsyncStream<ResidencyEvent>? { get }                      // nil default
}
struct SystemModelProvider: ModelProvider { init() }
struct PCCModelProvider: ModelProvider { init() }
struct ClaudeModelProvider: ModelProvider {
    enum Auth: Sendable { case apiKey(String); case appAttest(clientID: String) }
    init(auth: ClaudeModelProvider.Auth, extraModels: [String: ClaudeModelSpec] = [:])
}
struct ClaudeModelSpec: Sendable, Hashable { /* one Claude model — id, display name, context window */ }

// --- MLXModelProvider — LocalLMLabSDKInference (separate xcframework) ---------
struct MLXModelProvider: DownloadableModelProvider {
    static var scheme: String { "mlx" }
    init(cacheDirectory: URL? = nil, residentModelLimit: Int = 1, preflightLimits: MLXPreflightLimits = .init())
    var residencyEventStream: AsyncStream<ResidencyEvent>?
    var advertisedModels: [ModelID] { get }
    var installed: [InstalledModel] { get }
    var storageUsed: Int64 { get }
    func languageModel(for id: ModelID) throws -> any LanguageModel
    func availability(for id: ModelID) -> ModelAvailability
    func prewarm(_ id: ModelID) async
    func download(_ repoID: String) -> AsyncThrowingStream<DownloadEvent, any Error>
    func validate(_ repoID: String) async throws -> PreflightResult
    func capabilityProbe(_ id: ModelID) async -> ModelCapabilityReport
    func remove(_ id: ModelID) throws
    func unloadResident(_ id: ModelID, reason: String = "idleTimeout") async
    func unloadAllResident(reason: String = "idleTimeout") async
}
struct MLXPreflightLimits: Sendable, Equatable {
    var maxWeightFractionOfRAM: Double     // default 0.7
    init(maxWeightFractionOfRAM: Double = 0.7)
}

// --- model identity + capability ------------------------------------------
struct ModelID: Hashable, Sendable, Codable, CustomStringConvertible, LosslessStringConvertible {
    let scheme: String        // token before the first ':' — [a-z][a-z0-9]*
    let rest: String          // after the first ':'; empty for bare ids
    var rawValue: String      // "scheme" or "scheme:rest"
    init?(_ raw: String)
    init?(scheme: String, rest: String = "")
    static let system: ModelID    // "system"
    static let pcc: ModelID       // "pcc"
}
enum ModelAvailability: Sendable, Equatable {
    case available
    case notDownloaded
    case needsCredential
    case unavailable(kind: UnavailableKind, detail: String)
    enum UnavailableKind: Sendable, Equatable {
        case ineligibleHardware, notEnabled, modelNotReady, unsupportedModel, providerError, noProvider
    }
    var isAvailable: Bool { get }
}
struct ModelCapabilities: OptionSet, Sendable, Hashable, Codable {
    static let toolCalling: ModelCapabilities        // 1 << 0
    static let guidedGeneration: ModelCapabilities   // 1 << 1
}
struct ModelCapabilityReport: Sendable, Equatable {
    var id: ModelID
    var capabilities: ModelCapabilities
    var notes: [String]
    var blocked: String?          // non-nil = the model downloaded but can't run at all (load error, image-required VLM, empty output)
    var isUsable: Bool { get }
}
struct InstalledModel: Sendable, Hashable, Codable, Identifiable {
    var id: ModelID
    var repoID: String
    var capabilities: ModelCapabilities       // empty until capabilityProbe
    var sizeBytes: Int64?
    var contextTokens: Int?
    init(id: ModelID, repoID: String, capabilities: ModelCapabilities = [], sizeBytes: Int64? = nil, contextTokens: Int? = nil)
}
struct PreflightResult: Sendable, Equatable {
    enum Stage: String, Sendable, Codable { /* repoReachable / mlxFormat / architecture / size / … */ }
    var failedStage: Stage?       // nil = passed
    var detail: String?
    var weightBytes: Int64?
    var ramBytes: Int64?          // this Mac's physical memory, for the size check
    var passed: Bool { get }
    static let ok: PreflightResult
}

// --- routing + residency + events ----------------------------------------
struct RouteName: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    let rawValue: String
    init(_ rawValue: String); init(stringLiteral: String)
    static let heavy: RouteName   // "heavy"
    static let light: RouteName   // "light"
    static let local: RouteName   // "local"
}
enum ModelResidency: Sendable, Equatable, Codable { case lastUsedOnly; case keepWarm([RouteName]) }
enum ResidencyEvent: Sendable {
    case warmed(ModelID)
    case evicted(ModelID, reason: String)          // "capacity", "memoryPressure", …
    case loadProgress(ModelID, fraction: Double)
}

// --- session -------------------------------------------------------------
struct LocalLMLabSession: Sendable {
    let route: RouteName
    let modelID: ModelID
    var retryOnContextOverflow: RetryPolicy         // .disabled by default; set before respond()
    var languageModelSession: LanguageModelSession { get }   // Apple's session — use directly to opt out of the retry wrapper
    var events: AsyncStream<SessionEvent> { get }
    var contextBudget: ContextBudget { get }
    func cancel()
    // + respond(...) / streamResponse(...) wrappers (LocalLMLabSession+respond) that apply retryOnContextOverflow
}
enum SessionEvent: Sendable {
    case modelLoadProgress(fraction: Double)
    case routeSwitched(ModelID)
    case contextCompacted(removedEntries: Int)
    case toolCallStarted(id: String, name: String)
    case toolCallFinished(id: String, name: String, failed: Bool)
}
struct RetryPolicy: Sendable {
    var maxRetries: Int                                          // 0 disables
    var compact: (@Sendable (Transcript) -> Transcript)?
    init(maxRetries: Int = 0, compact: (@Sendable (Transcript) -> Transcript)? = nil)
    static let disabled: RetryPolicy
}
struct ContextBudget: Sendable, Equatable {
    let windowTokens: Int?          // nil for arbitrary downloaded weights
    let lastInputTokens: Int
    let lastOutputTokens: Int
    var fractionUsed: Double?
    static func windowHint(for id: ModelID) -> Int?
}
enum LocalLMLabError: Error, LocalizedError {   // the one public error type the model layer throws
    case modelUnavailable(reason: String)
    case download(stage: String, underlying: (any Error)?)
    case validation(stage: PreflightResult.Stage, detail: String)
    case generation(underlying: any Error)      // wrap; use GenerationErrorDescription.describe for the message
    case context(detail: String)
    case mcp(detail: String)
    case connector(detail: String)
}
enum LocalLMLabSDKVersion { static let current: String }   // "1.0.0-beta.N", "1.0.0" at GA
```

`MLXModelProvider` / `MLXPreflightLimits` are in **`LocalLMLabSDKInference`** (a separate
xcframework — §1); `ModelPickerView` / `ClaudeAuthField` are in **`LocalLMLabSDKComponents`** (§11).

### Connectors (Calendar, Reminders, Contacts, Location)

```swift
// Unified facade — permission lifecycle only, identical shape across all four
enum Connector: String, CaseIterable, Sendable { case calendar, reminders, contacts, location }
struct ConnectorAccessResult: Sendable { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
enum Connectors {
    static func isAuthorized(_ connector: Connector) -> Bool
    static func requestAccess(_ connector: Connector) async -> ConnectorAccessResult
    static func openSystemSettings(for connector: Connector)
}

// CalendarAccess
enum CalendarAccess {
    static var store: EKEventStore { get }  // raw EventKit store, for anything the wrapper below doesn't cover; refreshed internally after a fresh grant
    static var authorizationStatus: EKAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct EventSummary: Codable { var eventIdentifier: String; var title: String; var start: String; var end: String; var calendar: String; var location: String?; var isAllDay: Bool }
    static func upcomingEvents(days: Int) -> [EventSummary]
    struct AddEventResult { var success: Bool; var error: String? }
    static func addEvent(title: String, start: Date, end: Date) -> AddEventResult
    struct MutateEventResult { var success: Bool; var error: String? }
    // locates the event by title + the day it's currently on, not eventIdentifier; nil new* parameters leave that field unchanged
    static func updateEvent(title: String, onDate: DateComponents, newTitle: String?, newDate: DateComponents?, newTime: DateComponents?, durationMinutes: Int?) -> MutateEventResult
    static func deleteEvent(title: String, onDate: DateComponents) -> MutateEventResult
}

// RemindersAccess — same shape as CalendarAccess, also backed by EventKit (EKEventStore
// handles both calendar events and reminders)
enum RemindersAccess {
    static var store: EKEventStore { get }
    static var authorizationStatus: EKAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct ReminderSummary: Codable, Sendable { var calendarItemIdentifier: String; var title: String; var dueDate: String?; var list: String; var isCompleted: Bool; var priority: Int }
    static func upcomingReminders(days: Int) async -> [ReminderSummary]
    struct AddReminderResult { var success: Bool; var error: String? }
    static func addReminder(title: String, dueDateComponents: DateComponents?) -> AddReminderResult
    struct MutateReminderResult { var success: Bool; var error: String? }
    // locates the reminder by title, optionally narrowed by its current due date; nil new* parameters leave that field unchanged
    static func updateReminder(title: String, dueDate: DateComponents?, newTitle: String?, newDate: DateComponents?, newTime: DateComponents?, isCompleted: Bool?) async -> MutateReminderResult
    static func deleteReminder(title: String, dueDate: DateComponents?) async -> MutateReminderResult
}

// ContactsAccess
enum ContactsAccess {
    static var store: CNContactStore { get }  // raw Contacts store, for anything the wrapper below doesn't cover; refreshed internally after a fresh grant
    static var authorizationStatus: CNAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct ContactSummary: Codable { var identifier: String; var name: String; var givenName: String; var familyName: String?; var organization: String?; var phoneNumbers: [String]; var emails: [String] }
    static func search(query: String, limit: Int) -> [ContactSummary]
    static func list(limit: Int) -> [ContactSummary]
    struct MutateContactResult { var success: Bool; var error: String? }
    static func addContact(givenName: String, familyName: String, organization: String?, phoneNumbers: [String], emails: [String]) -> MutateContactResult
    // locates the contact by givenName, optionally narrowed by its current familyName; nil new* parameters leave that field unchanged, non-nil newPhoneNumbers/newEmails replace the contact's entire existing list
    static func updateContact(givenName: String, familyName: String?, newGivenName: String?, newFamilyName: String?, newOrganization: String?, newPhoneNumbers: [String]?, newEmails: [String]?) -> MutateContactResult
    static func deleteContact(givenName: String, familyName: String?) -> MutateContactResult
}

// LocationAccess — a class (LocationAccess.shared), not a static enum, since it holds
// CLLocationManagerDelegate state
final class LocationAccess {
    static let shared: LocationAccess
    var authorizationStatus: CLAuthorizationStatus { get }
    var isAuthorized: Bool { get }
    var lastFetchFailureReason: String? { get }
    struct AccessResult: Sendable { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct LocationSummary: Codable { var latitude: Double; var longitude: Double; var horizontalAccuracyMeters: Double; var timestamp: String; var placeName: String? }
    func currentLocation() async -> LocationSummary?
}
```

### Ready-made connector Tools (Path A)

Thin `Tool`-conforming wrappers around the connectors above — see §7a (Path A vs Path B) for the framing. Each takes
an optional custom `description` at init, same pattern as `ClockTool`/`WeatherTool` below.

```swift
// Calendar
struct GetUpcomingEventsTool: Tool {
    let name = "getUpcomingEvents"
    init(description: String? = nil)
    struct Arguments { var days: Int? }             // defaults to 7, capped at 30
}
struct AddCalendarEventTool: Tool {
    let name = "addCalendarEvent"
    init(description: String? = nil)
    struct Arguments { var title: String; var date: String; var time: String; var durationMinutes: Int? }
}
struct UpdateCalendarEventTool: Tool {
    let name = "updateCalendarEvent"
    init(description: String? = nil)
    // currentDate locates the event; each new* field is independently optional
    struct Arguments { var title: String; var currentDate: String; var newTitle: String?; var newDate: String?; var newTime: String?; var durationMinutes: Int? }
}
struct DeleteCalendarEventTool: Tool {
    let name = "deleteCalendarEvent"
    init(description: String? = nil)
    struct Arguments { var title: String; var currentDate: String }
}

// Reminders — same title/currentDate/new* shape as Calendar; currentDate is optional here
// (a reminder may have no due date, unlike a Calendar event)
struct GetUpcomingRemindersTool: Tool {
    let name = "getUpcomingReminders"
    init(description: String? = nil)
    struct Arguments { var days: Int? }
}
struct AddReminderTool: Tool {
    let name = "addReminder"
    init(description: String? = nil)
    struct Arguments { var title: String; var date: String?; var time: String? }
}
struct UpdateReminderTool: Tool {
    let name = "updateReminder"
    init(description: String? = nil)
    struct Arguments { var title: String; var currentDate: String?; var newTitle: String?; var newDate: String?; var newTime: String?; var isCompleted: Bool? }
}
struct DeleteReminderTool: Tool {
    let name = "deleteReminder"
    init(description: String? = nil)
    struct Arguments { var title: String; var currentDate: String? }
}

// Contacts — currentGivenName/currentFamilyName locate the contact; each new* field is
// independently optional. newPhoneNumbers/newEmails, when provided, replace the entire list.
struct SearchContactsTool: Tool {
    let name = "searchContacts"
    init(description: String? = nil)
    struct Arguments { var query: String; var limit: Int? }  // defaults to 10, capped at 50
}
struct ListContactsTool: Tool {
    let name = "listContacts"
    init(description: String? = nil)
    struct Arguments { var limit: Int? }                     // defaults to 50, capped at 200
}
struct AddContactTool: Tool {
    let name = "addContact"
    init(description: String? = nil)
    struct Arguments { var givenName: String; var familyName: String?; var organization: String?; var phoneNumbers: [String]?; var emails: [String]? }
}
struct UpdateContactTool: Tool {
    let name = "updateContact"
    init(description: String? = nil)
    struct Arguments { var currentGivenName: String; var currentFamilyName: String?; var newGivenName: String?; var newFamilyName: String?; var newOrganization: String?; var newPhoneNumbers: [String]?; var newEmails: [String]? }
}
struct DeleteContactTool: Tool {
    let name = "deleteContact"
    init(description: String? = nil)
    struct Arguments { var currentGivenName: String; var currentFamilyName: String? }
}

// Location — the one connector Tool with no writable counterpart
struct GetCurrentLocationTool: Tool {
    let name = "getCurrentLocation"
    init(description: String? = nil)
    struct Arguments {}
}
```

### Filesystem workspace (`WorkspaceAccess`/`WorkspaceTools`)

Not a connector — no `requestAccess()`, no OS permission dialog. Operates on a root `URL` your
app already resolved via a security-scoped bookmark (§8 — Filesystem access); the picker itself is the one-time
consent. `WorkspaceAccess` is the raw data layer; `WorkspaceTools` are the matching Path A `Tool`s,
each taking the resolved root `URL` at init.

```swift
enum WorkspaceAccess {
    struct WorkspaceError: Error { var message: String }
    struct WorkspaceEntry: Codable, Sendable { var name: String; var isDirectory: Bool; var modifiedDate: Date?; var size: Int? }

    static func listFiles(in root: URL, subpath: String?) -> Result<[WorkspaceEntry], WorkspaceError>
    static func readFile(in root: URL, path: String) -> Result<String, WorkspaceError>
    // create-only — fails if the file already exists; use editFile to modify an existing one
    static func writeFile(in root: URL, path: String, contents: String) -> Result<Void, WorkspaceError>
    // search-and-replace, not a unified-diff format — oldString must match exactly once unless replaceAll
    static func editFile(in root: URL, path: String, oldString: String, newString: String, replaceAll: Bool) -> Result<Void, WorkspaceError>
    static func deleteFile(in root: URL, path: String) -> Result<Void, WorkspaceError>
}

struct ListWorkspaceFilesTool: Tool {
    let name = "listWorkspaceFiles"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String? }
}
struct ReadWorkspaceFileTool: Tool {
    let name = "readWorkspaceFile"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String }
}
struct WriteWorkspaceFileTool: Tool {
    let name = "writeWorkspaceFile"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String; var contents: String }
}
struct EditWorkspaceFileTool: Tool {
    let name = "editWorkspaceFile"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String; var oldString: String; var newString: String; var replaceAll: Bool? }
}
// Not included in workspace-buddy's default tool list — see that example's README. Available
// here for a host app that explicitly wants a delete-capable coding assistant.
struct DeleteWorkspaceFileTool: Tool {
    let name = "deleteWorkspaceFile"
    init(root: URL, description: String? = nil)
    struct Arguments { var path: String }
}
```

### No-permission tools

```swift
struct ClockTool: Tool {
    static let defaultDescription: String
    init(description: String? = nil)
    // Arguments: zero properties — call() returns the current date/time as text
}

struct WeatherTool: Tool {
    static let defaultDescription: String
    init(description: String? = nil)
    struct Arguments { var location: String }
    // call() returns current conditions + 7-day forecast via Open-Meteo
}
```

### Error handling

```swift
enum GenerationErrorDescription {
    // Turns a LanguageModelSession.GenerationError into a readable, per-case explanation
    // (falls back to error.localizedDescription for any other error type). async because
    // .refusal's explanation is itself computed asynchronously by FoundationModels.
    static func describe(_ error: Error) async -> String
}
```

**A note on what's not listed above**: `@Generable` (Apple's FoundationModels macro, applied to every `Arguments` struct in this SDK and in your own tools) synthesizes additional public members on each one — a `PartiallyGenerated` nested type, `generationSchema`, `generatedContent`, and a few others. These are FoundationModels' own machinery for incremental/streaming generation, not SDK API — you'll never call them directly, only `@Generable`/`LanguageModelSession` do. Left out here deliberately, the same way compiler-synthesized `Codable`/`Hashable` methods (`init(from:)`, `encode(to:)`, `hash(into:)`) are left out of the reference types above — real public symbols, but noise for this list's purpose. If you inspect the compiled binary directly and see these, that's expected, not a sign this reference is out of date.

### MCP client

```swift
final class MCPServerManager {
    init()  // NOT a singleton — you own the instance
    private(set) var servers: [MCPServerID: MCPServerState] { get }
    var serverChanges: AsyncStream<[MCPServerID: MCPServerState]> { get }
    var estimatedTotalTokens: Int { get }

    func addServer(url: URL, displayName: String, authType: MCPAuthType = .none, patToken: String? = nil, manualClientID: String? = nil) async -> Result<MCPServerState, MCPServerError>
    func reconnect(_ id: MCPServerID) async -> Result<MCPServerState, MCPServerError>
    func disconnect(_ id: MCPServerID)
    func removeServer(_ id: MCPServerID)
    func restore(from persisted: [(id: MCPServerID, url: URL, displayName: String, tools: [MCPToolDescriptor], estimatedTokens: Int, enabled: Bool, authType: MCPAuthType, manualClientID: String?)])

    func toolsForSession() -> [MCPToolDescriptor]
    func setToolEnabled(server: MCPServerID, tool: String, enabled: Bool)
    func callTool(server: MCPServerID, tool: String, arguments: [String: MCPValue]) async -> Result<String, MCPServerError>

    func resourcesForSession() -> [MCPResourceDescriptor]
    func resourceTemplatesForSession() -> [MCPResourceTemplateDescriptor]
    func setResourceEnabled(server: MCPServerID, uri: String, enabled: Bool)
    func readResource(server: MCPServerID, uri: String) async -> Result<MCPResourceContent, MCPServerError>

    func promptsForSession() -> [MCPPromptDescriptor]
    func getPrompt(server: MCPServerID, name: String, arguments: [String: String]) async -> Result<[MCPPromptMessage], MCPServerError>
}

struct MCPServerID: Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String)
}

struct MCPServerState: Codable, Sendable {
    var id: MCPServerID
    var url: URL
    var displayName: String
    var connectionStatus: MCPConnectionStatus
    var tools: [MCPToolDescriptor]
    var estimatedTokens: Int
    var enabled: Bool
    var authType: MCPAuthType
    var patTokenLastFour: String?       // masked display only, never the real token
    var manualClientID: String?
    var resources: [MCPResourceDescriptor]
    var resourceTemplates: [MCPResourceTemplateDescriptor]
    var prompts: [MCPPromptDescriptor]
    func exportSummary() -> String      // plain-text listing of tools/resources/prompts, enabled state, token cost
}

enum MCPAuthType: String, Codable, Sendable { case none, pat, oauthManual }
enum MCPConnectionStatus: String, Codable, Sendable { case connected, disconnected, connecting, failed }
// MCPConnectionStatus and MCPServerError are non-frozen (1.0) — an exhaustive switch needs
// `@unknown default`. This is the only source-break for an MCP-only 0.8.x consumer; see
// migrating-to-1.0.md.

struct MCPToolDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var name: String
    var description: String
    var rawSchema: Data          // the tool's real JSON schema — inspect before assuming params
    var estimatedTokens: Int
    var enabled: Bool            // defaults to false for newly-discovered tools
}

struct MCPResourceDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var uri: String
    var name: String
    var description: String
    var mimeType: String?
    var enabled: Bool            // defaults to true
}

struct MCPResourceTemplateDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var uriTemplate: String      // e.g. "res://{id}" — resolve placeholders yourself before reading
    var name: String
    var description: String
    var mimeType: String?
}

struct MCPResourceContent: Codable, Sendable {
    var uri: String
    var mimeType: String?
    var text: String?            // exactly one of text/blob is non-nil, per MCP spec
    var blob: String?
}

struct MCPPromptArgument: Codable, Sendable { var name: String; var description: String; var required: Bool }
struct MCPPromptDescriptor: Codable, Sendable {
    var serverID: MCPServerID
    var name: String
    var description: String
    var arguments: [MCPPromptArgument]
}
struct MCPPromptMessage: Codable, Sendable { var role: String; var text: String }

indirect enum MCPValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), array([MCPValue]), object([String: MCPValue]), null
}

enum MCPServerError: Error, Codable, Sendable {
    case unreachable
    case malformedResponse
    case protocolMismatch
    case notConnected
    case toolNotFound
    case serverError(String)                // includes real HTTP status/URL/body where available
    case authorizationRequired               // OAuth flow needed and didn't complete
    case credentialRejected                  // PAT rejected — no retry path but a new token
    case httpError(Int)
    case oauthRegistrationNotSupported       // no DCR — retry with .oauthManual + manualClientID
}
```

**OAuth setup** (§2c–2d):

```swift
enum MCPOAuthFlow {
    static var redirectURI: String { get set }  // MUST override before any connect/addServer call
}

final class MCPOAuthRedirectListener {
    static let shared: MCPOAuthRedirectListener
    func handleRedirect(_ url: URL)             // call from your AppDelegate's open-URL handler
}
```

**Advanced**: `protocol MCPConnection` is the transport abstraction `MCPServerManager` drives
internally (`initialize()`, `listTools()`, `callTool(name:arguments:)`, resource/prompt
equivalents, `close()`). You won't need this unless you're replacing the transport layer itself —
everything above already goes through it for you.

### `MCPTool` (Path A for MCP)

Builds a `Tool` at runtime directly from an `MCPToolDescriptor`'s real JSON Schema — no
hand-written `Arguments` struct. `Arguments` is `GeneratedContent` (not a static type), and
`parameters` is computed from the tool's schema rather than derived from `Arguments` the usual
way. The initializer is throwing — a tool whose schema doesn't build should be skipped, not let
crash your whole tool list; see §7a (the two tool-calling paths) for the recommended loop shape.

```swift
struct MCPTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema   // built from descriptor.rawSchema, not from Arguments
    // Arguments == GeneratedContent

    init(descriptor: MCPToolDescriptor, manager: MCPServerManager) throws
    func call(arguments: GeneratedContent) async throws -> String
}

enum MCPToolAdapterError: Error, CustomStringConvertible {
    case invalidRawSchema           // rawSchema wasn't valid JSON
    case unbuildableSchema(String)  // FoundationModels rejected the resulting GenerationSchema
}
```

Common JSON Schema shapes (object/properties/required, array/items, string/number/integer/
boolean, string enums) convert cleanly. Anything past that — `oneOf`/`anyOf` unions, `$ref`,
`const`, regex `pattern` — degrades to a free-form string leaf rather than failing the whole tool,
since the remote server is still the real source of argument validation.

### Components (`LocalLMLabSDKComponents`)

```swift
@MainActor
final class MCPServerManagerObservable: ObservableObject {
    let core: MCPServerManager
    @Published private(set) var servers: [MCPServerID: MCPServerState]
    var sortedServers: [MCPServerState] { get }
    init(core: MCPServerManager)
}
// MCPServerError also gets LocalizedError conformance here, for human-readable error text in UI.

struct MCPServerPickerView: View {
    init(manager: MCPServerManagerObservable)
    // Add/list/reconnect/disconnect/remove, all three auth types, per-tool and per-resource
    // enable/disable, prompts listing (read-only), and a "Save As…" text export per server.
}

struct MCPOAuthWaitingView: View {
    init(serverName: String, onCancel: @escaping () -> Void)
}

struct MCPResourcesView: View {
    init(manager: MCPServerManagerObservable, onAttach: @escaping (MCPResourceDescriptor, MCPResourceContent) -> Void)
}

struct MCPPromptsView: View {
    init(manager: MCPServerManagerObservable, onUse: @escaping (MCPPromptDescriptor, [MCPPromptMessage]) -> Void)
}

// Model layer (1.0)
struct ModelPickerView: View {
    init(registry: ModelRegistry, selection: Binding<ModelID?>)
    // Lists registry.knownModels; each row shows availability (grayed + reason for .unavailable),
    // a download button + progress for .notDownloaded, storage size. Binds to the @Observable
    // registry directly — no polling.
}
struct ClaudeAuthField: View {
    init(apiKey: Binding<String>, onCommit: @escaping () -> Void = {})
    // A ready-made secure field for the Claude API key that ClaudeModelProvider(auth: .apiKey(_:)) needs.
}
```
