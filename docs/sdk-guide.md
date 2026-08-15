# Using the LocalLM Lab SDK

Audience: a Swift developer linking `LocalLMLabSDKCore` into their own macOS app to add local-AI
tool-calling — system connectors (Calendar, Reminders, Contacts, Location), an MCP client, and
(via `Components`) prebuilt SwiftUI for managing MCP server connections. Everything here has been
exercised against real signed apps and real live MCP servers, not just written from the API
surface — see [`examples/plate-today`](../examples/plate-today) and
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
  (Developer ID + notarization, or Mac App Store).

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

For every connector you use (Calendar/Reminders shown here — see section 7 for the full connector
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

Adding an MCP server involves one of three auth types, exposed as `MCPAuthType`. `Components`'
`MCPServerPickerView` (see section 11) already builds a UI over all three if you'd rather not build
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
own scheme** (`yourapp://oauth/callback`, from section 2c). Copying another app's setup
instructions verbatim into your own documentation would silently misconfigure every user who
follows it — their server-side app would try to redirect back into the wrong app (or nowhere)
instead of yours.

## 4. Keychain storage — automatic isolation, native API, sandbox-safe

`MCPOAuthTokenStore`/`MCPPATStore` scope their Keychain storage to `Bundle.main.bundleIdentifier`
automatically — you don't need to do anything for isolation between your app and any other app
linking Core on the same Mac.

Both stores also use the native Keychain Services API (`SecItemAdd`/`SecItemCopyMatching`/etc.)
directly, not a shell-out to a system command-line tool — safe to use from a sandboxed app
(including one distributed through the Mac App Store), where shelling out to system binaries is
unreliable or outright unavailable. Confirmed live under App Sandbox, not just by code review — see
section 10.

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

### Step 1 — user double-clicks the app icon

Your app's `init()` should run, before any window exists, as early as possible:

```swift
init() {
    MCPOAuthFlow.redirectURI = "yourapp://oauth/callback"
}
```

This is the single most important line to copy correctly into your own app — the OAuth scheme
override from section 2c, set before any `connect`/`addServer` call could possibly need it. Your
`@NSApplicationDelegateAdaptor` also installs the OAuth-callback handler (section 2d) at this
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

### Step 4 — the model calls your Calendar tool, which is where the TCC prompt actually happens

The permission prompt is triggered by exactly one line inside that tool's `call(arguments:)`:

```swift
let access = await Connectors.requestAccess(.calendar)
```

Core's `Connectors.requestAccess` (see section 7) handles the no-Info.plist-key and
previously-denied cases with clearer errors than calling EventKit directly yourself. The system
prompt macOS shows here is only possible because of the entitlement + Info.plist usage string from
section 2a/2b; without those, this call fails silently rather than prompting (see section 2's
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
for this app (see section 4 — checked under `Bundle.main.bundleIdentifier`-scoped Keychain
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
// this wrapper — MCPServerManagerObservable, see section 11 — so you don't need to write it
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
`Components`' `MCPServerPickerView` (section 11), which already builds a per-tool enable/disable UI
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

**On extracting more than just tools**: a connected server can also expose **resources** (readable
content, e.g. a document or dataset) and **prompts** (server-defined templates). `manager.
resourcesForSession()`/`.promptsForSession()` list what's currently enabled;
`manager.readResource(server:uri:)`/`manager.getPrompt(server:name:arguments:)` fetch the real
content. `Components`' `MCPResourcesView`/`MCPPromptsView` (section 11) already build a UI over
both if you don't want to write your own.

## 7. Connectors: Calendar, Reminders, Contacts, Location

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

Each connector requires its own Info.plist usage-description key and entitlement, same pattern as
section 2a/2b — see that section for Calendar/Reminders; Contacts needs
`NSContactsUsageDescription` + `com.apple.security.personal-information.addressbook`, Location
needs `NSLocationUsageDescription` + `com.apple.security.personal-information.location`.
`examples/plate-today`'s `SearchContactsTool` and (build-time opt-in) location/weather tools are
working examples of each, including the exact packaging-script changes each one needs.

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

## 8. Filesystem access: security-scoped bookmarks (example, not in Core)

Unlike the four connectors above, filesystem access to a user-picked file or folder is **not**
part of Core, and isn't planned to be. The reason is structural, not an oversight: the actual
picker UI (`NSOpenPanel`) has to live in your app — Core has no UI of its own, by design, same as
the MCP server connect/auth UI in section 3. There's no meaningful "unified API" to offer here the
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

## 9. What's NOT in Core yet

- **No filesystem connector.** See section 8 — deliberately, not planned, since the picker UI has
  to live in the host app anyway.
- **No public API stability guarantee.** Access levels have been fixed reactively, as real usage
  surfaced gaps. If you hit a "X is inaccessible due to internal protection level" error on
  something that looks like it should obviously be public, it probably should be — that's a real
  gap, not a step you're missing. File an issue.

## 10. App Sandbox — building for the Mac App Store

Core has been tested under App Sandbox — confirmed via a real sandboxed, Developer-ID-signed,
notarized build (not just code review), not through the actual MAS submission pipeline itself yet.
Here's exactly what's needed and what was actually verified.

### 10a. Entitlements

Add `com.apple.security.app-sandbox` alongside whichever connector entitlements from section 2b
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
  OAuth redirect is a URL-scheme handoff (section 2c/2d), not a local HTTP listener, so
  `com.apple.security.network.server` is not needed for this.
- **Keychain token storage** (`MCPOAuthTokenStore`/`MCPPATStore`, section 4) — round-tripped
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
tccutil reset All <your-bundle-id>   # Location can't be reset individually, see section 7
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

See [`annotated-examples.md`](annotated-examples.md) for `components-demo`'s full source with
every `Components`/`Core` touchpoint marked.

Everything above is `Core` — a plain Swift engine with no UI dependency. `Components` is a
separate, optional package built on top of Core's public API, for when you don't want to write
your own MCP-server-management UI from scratch. See [`examples/components-demo`](../examples/components-demo)
for a working reference app using all of it.

- **`MCPServerManagerObservable`** — an `ObservableObject` wrapper around `MCPServerManager`, for
  SwiftUI apps that want `@Published`-style reactivity without writing the wrapper themselves (see
  section 6's note).
- **`MCPServerPickerView`** — add/list/reconnect/disconnect/remove MCP servers, all three auth
  types from section 3, per-tool and per-resource enable/disable, and a "Save As…" action that
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

Everything public in `LocalLMLabSDKCore` and `LocalLMLabSDKComponents`, grouped by area. This is
the flat list; sections 1–11 above are the narrative version with context and gotchas — use this
one when you just need to check a signature.

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
    static let store: EKEventStore  // the raw EventKit store, for anything the wrapper below doesn't cover
    static var authorizationStatus: EKAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct EventSummary: Codable { var title: String; var start: String; var end: String; var calendar: String; var location: String?; var isAllDay: Bool }
    static func upcomingEvents(days: Int) -> [EventSummary]
    struct AddEventResult { var success: Bool; var error: String? }
    static func addEvent(title: String, start: Date, end: Date) -> AddEventResult
}

// RemindersAccess — same shape as CalendarAccess, also backed by EventKit (EKEventStore
// handles both calendar events and reminders)
enum RemindersAccess {
    static let store: EKEventStore
    static var authorizationStatus: EKAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct ReminderSummary: Codable, Sendable { var title: String; var dueDate: String?; var list: String; var isCompleted: Bool; var priority: Int }
    static func upcomingReminders(days: Int) async -> [ReminderSummary]
    struct AddReminderResult { var success: Bool; var error: String? }
    static func addReminder(title: String, dueDateComponents: DateComponents?) -> AddReminderResult
}

// ContactsAccess
enum ContactsAccess {
    static let store: CNContactStore  // the raw Contacts store, for anything the wrapper below doesn't cover
    static var authorizationStatus: CNAuthorizationStatus { get }
    static var isAuthorized: Bool { get }
    struct AccessResult { var granted: Bool; var error: String?; var needsSystemSettings: Bool }
    static func requestAccess() async -> AccessResult
    static func openSystemSettings()
    struct ContactSummary: Codable { var name: String; var organization: String?; var phoneNumbers: [String]; var emails: [String] }
    static func search(query: String, limit: Int) -> [ContactSummary]
    static func list(limit: Int) -> [ContactSummary]
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

**OAuth setup** (section 2c/2d):

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
```
