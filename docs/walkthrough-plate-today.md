# Walking through a reference app's user experience, step by step

A step-by-step account of what a reference app does when it runs, from the user double-clicking it to the answer on screen. It is a worked example, not required reading.


> **Reach for this when** you want the shape of a whole app's flow — launch → request access →
> fetch/synthesize via the model → show the result → clean up — not just one API's signature.
> Skip ahead to [The MCP client API](mcp-guide.md#the-mcp-client-api) if you already know the shape and just want the
> reference.
>
> **Examples that use it:** [`plate-today`](../examples/plate-today/) is the app this walkthrough
> traces line by line; see [the annotated examples](annotated-examples.md) for its full source
> with every SDK touchpoint marked, if you'd rather see it all at once than in prose.

This section traces `examples/plate-today`'s "what's on my plate today" flow end to end — launch →
request Calendar/Reminders/MCP-server access → fetch and synthesize via an on-device model → show
the result → clean up. Use this as the template for wiring your own app; the shape is generic, only
the tools differ. The actual source is in [examples/plate-today on GitHub](../examples/plate-today/) if you want to read or run it
directly rather than following along in prose.

> **This is your first look at tools + connectors — and there's a shortcut.** Core gives a model
> a tool two ways ([Two paths to tool-calling](sdk-guide.md#two-paths-to-tool-calling-ready-made-tools-or-write-your-own)):
> **Path A** — drop a ready-made `Tool` into the array (`GetUpcomingEventsTool()`,
> `SearchContactsTool()`, `MCPTool(descriptor:)`, …), one line each, with hard-won
> on-device-model correctness lessons already baked into their descriptions; or **Path B** —
> hand-write a `Tool` struct per connector for full control over its name/schema/description.
> `plate-today` (and this walkthrough) is Path B, deliberately: doing it by hand once makes the
> `requestAccess` → fetch → return-a-string shape visible. **For your own app, reach for Path A
> first** — it's the same permission timing and the same TCC prompts below, with far less code.
> The matched example [`plate-today-tools`](../examples/plate-today-tools/) is this exact app
> rebuilt on Path A — diff the two.

## Step 1 — user double-clicks the app icon

Your app's `init()` should run, before any window exists, as early as possible:

```swift
init() {
    MCPOAuthFlow.redirectURI = "yourapp://oauth/callback"
}
```

This is the single most important line to copy correctly into your own app — the OAuth scheme
override from [the OAuth redirect URI section](mcp-guide.md#oauth-redirect-uri--must-set-this-yourself-if-your-server-uses-oauth), set before any `connect`/`addServer` call could possibly need it. Your
`@NSApplicationDelegateAdaptor` also installs the OAuth-callback handler ([the section right after it](mcp-guide.md#wire-the-oauth-callback-through-your-appdelegate-not-swiftuis-onopenurl-if-your-server-uses-oauth)) at this
point, and `.handlesExternalEvents(matching: [])` is declared as part of the `Scene` body that
follows — both need to be in place *before* the window is shown, not bolted on reactively later.

## Step 2 — the window appears, showing a spinner

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

## Step 3 — `fetch()` builds the tool list and starts the model session

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

## Step 4 — the model calls your Calendar tool, which is where the TCC prompt actually happens

The permission prompt is triggered by exactly one line — inside your hand-written tool's
`call(arguments:)` on Path B, or inside `GetUpcomingEventsTool`'s own `call()` on Path A (you
don't write it, but it fires at the same moment — the first time the model invokes the tool):

```swift
let access = await Connectors.requestAccess(.calendar)
```

Core's `Connectors.requestAccess` (see [Connectors](sdk-guide.md#connectors-calendar-reminders-contacts-location)) handles the no-Info.plist-key and
previously-denied cases with clearer errors than calling EventKit directly yourself. The system
prompt macOS shows here is only possible because of the entitlement + Info.plist usage string from
[Info.plist strings](sdk-guide.md#infoplist-usage-description-strings-if-using-calendarreminders) and [Entitlements](sdk-guide.md#entitlements-if-using-calendarreminders) setup; without those, this call fails silently rather than prompting (see [Setup for Calendar and Reminders](sdk-guide.md#setup-for-calendar-and-reminders)'s
failure-sequence writeup). If the user denies, a well-behaved tool returns a plain string like
`"Calendar access not granted."` — not an error/throw — so the model receives that as the tool's
result and can reason about it in its final summary, rather than the whole request failing. A
Reminders tool works identically, one call (`.reminders`) triggering that separate TCC prompt.

## Step 5 — the model calls your MCP tool, which is where the OAuth browser flow happens

This is the one tool that goes through Core instead of a system framework:

```swift
let connectResult = await manager.addServer(url: serverURL, displayName: "My Server")
```

This single call does capability negotiation *and* auth. If the server has no valid cached token
for this app (see [Keychain storage](mcp-guide.md#keychain-storage--automatic-isolation-native-api-sandbox-safe) — tokens are checked under `Bundle.main.bundleIdentifier`-scoped
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
struct of your own. [`repo-qa`](../examples/repo-qa/) is that in ~70 lines; see [Two paths to tool-calling](sdk-guide.md#two-paths-to-tool-calling-ready-made-tools-or-write-your-own).

`callTool` hands back an `MCPToolResult` ([MCP tool results](mcp-guide.md#what-a-tool-call-gives-you-back-mcptoolresult)) — `renderedForModel` is the string you feed the
model; both adapters call it for you. If your target server pauses a tool call to ask the user
something, that's elicitation — wire the one-line Components handler ([Server-initiated requests](mcp-guide.md#server-initiated-requests-elicitation-and-the-sampling--roots-seams)).

## Step 6 — the model synthesizes a summary, the UI shows it

`session.respond(to:)`'s result becomes your "ready" state, rendered in a scrollable text view. If
anything upstream threw instead, show the error — deliberately unpolished in the reference app,
since it's meant to be read by developers, not imitated verbatim as production error handling.

## Step 7 — user clicks Done

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
