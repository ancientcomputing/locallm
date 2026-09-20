# Annotated example source

The full source of every reference app, with every line that actually touches the SDK marked
`// ← SDK` (Core), `// ← SDK (Inference)` (the MLX runtime — `code-buddy`, `repo-qa-local`,
`workspace-buddy-local`, `os-matrix`, `aiql`, `vistanova`, and `mlx-control-room`), `// ← SDK (Remote)` (online providers —
`model-switch` and `security-demo`), or `// ← Components` (`components-demo` and `components-updates-demo`). Everything else is ordinary SwiftUI/Foundation — the point
of marking it this way is to make obvious just how little of each file is SDK-specific plumbing.
`plate-today` and `plate-today-tools` are a matched pair — the same app twice, "Path B" (hand-
written `Tool` adapters) vs. "Path A" (Core's ready-made ones, `// ← SDK (Path A)`) — meant to be
read back to back; see §7a of `sdk-guide.md` for the framing. `repo-qa` is Path A again, but on
its own, smaller and differently-shaped: a plain CLI tool showing `MCPTool` against a no-auth
server, distinct from `plate-today-tools`' OAuth-gated Todoist case.

(GitHub-flavored Markdown doesn't apply bold/inline formatting inside fenced code blocks, so a
trailing comment is used instead of `**bold**` — it survives being read as a comment in the real
`.swift` file too, not just rendered here.)

See [`sdk-guide.md`](sdk-guide.md) for the prose walkthrough these annotate — this file is the
companion "show me the whole thing at once" reference.

## How much code is this, really?

Every reference app in full — the whole Swift source, not a snippet (except `vistanova`, whose section excerpts just its SDK-facing files and whose count below is the whole app). "Code" is non-blank,
non-comment lines; these examples are commented far more heavily than production code, so the
"with comments" column roughly doubles it.

| Example | Code | With comments | In one line |
|---|--:|--:|---|
| [`repo-qa`](#examplesrepo-qa) | 66 | 115 | Apple's on-device model calling a real MCP server's tools, built from its live schema — no `Arguments` structs |
| [`os-matrix`](#examplesos-matrix) | 74 | 97 | one binary that runs on macOS 26 **and** 27, model families gated by OS at registration |
| [`repo-qa-local`](#examplesrepo-qa-local) | 96 | 134 | `repo-qa` again, but the answer comes from a downloaded open-weight MLX model, **pinned** to a reviewed commit (the model layer) |
| [`components-demo`](#examplescomponents-demo) | 141 | 189 | a working "add / manage MCP servers" screen from prebuilt `Components` views, no MCP UI written |
| [`plate-today-tools`](#examplesplate-today-tools) | 149 | 235 | Calendar + Reminders + Todoist (OAuth MCP) → a spoken-language day summary, on Core's ready-made tools |
| [`workspace-buddy`](#examplesworkspace-buddy) | 172 | 226 | sandboxed AI edits to a user-picked folder, on-device model, a security-scoped bookmark that survives relaunch |
| [`workspace-buddy-local`](#examplesworkspace-buddy-local) | 255 | 332 | `workspace-buddy` + a downloaded MLX model, running **inside** the App Sandbox, streaming its answer |
| [`plate-today`](#examplesplate-today) | 216 | 359 | the same day summary as `plate-today-tools`, built with hand-written `Tool` adapters (Path B) |
| [`model-switch`](#examplesmodel-switch) | 283 | 347 | GPT / Claude online / OpenRouter + on-device, one chat call site, provider-run web search + citations (3 files) |
| [`security-demo`](#examplessecurity-demo) | ~250 | ~490 | a "Security" panel → `limited(toMaxImpact:)` (which tools) + `ConfirmingToolAuthorizer` (whether they ask), a frontier model against Calendar + Todoist MCP (6 files) |
| [`code-buddy`](#examplescode-buddy) | 315 | 413 | a CLI coding agent: two models with routing, workspace + host `Process` tools, MCP, a persistent REPL session (2 files) |
| [`aiql`](#examplesaiql) | 395 | 494 | a plain-English request → one read-only SQL `SELECT` over an MCP dataset → the CSV you asked for, sandboxed SwiftUI, zero fabricated values; a pinned default model and a trust policy for the free-text picker |
| [`vistanova`](#examplesvistanova) | 931 | 1,294 | a tiny local search engine: web search through a Tavily MCP server on one local model, summaries from a **pinned** MLX model on another; defends against a model that skips the tool call (7 files) |
| [`components-updates-demo`](#examplescomponents-updates-demo) | 151 | 170 | the `Components` model **onboarding**, **update** and **versions** views, driven by simulated sources so every state is reachable |
| [`mlx-control-room`](#examplesmlx-control-room) | 1,434 | 1,812 | every MLX knob with a gauge, plus the supply-chain flow made visible: validate, download, **pin**, update, roll back, clean up (excerpted; UI omitted) |

The SDK-specific part of each — the lines carrying a `// ← SDK` marker — is a few dozen at most,
and each section's **Tally** breaks that down. The rest is ordinary SwiftUI, Foundation, and
argument parsing.

## `examples/plate-today`

*`Sources/PlateToday/PlateTodayApp.swift` — 216 lines of code (359 with comments).*

Demonstrates `Core` directly: Calendar/Reminders connectors, the MCP client, Keychain-backed OAuth
— no `Components` involved. This is "Path B" — a hand-written `Tool` adapter per connector; see
[`plate-today-tools`](#examplesplate-today-tools)
below for the same app rebuilt on Core's ready-made "Path A" `Tool`s instead.

```swift
// "What's on my plate today" — v1: Todoist (via Core's MCP client) + Calendar + Reminders (also
// via Core, through CalendarAccess/RemindersAccess — see below). Linear is a planned v2 addition,
// deliberately deferred.
//
// SwiftUI app shape (not a bare CLI): launch -> request Calendar/Reminders/Todoist access on
// first run -> pull + synthesize -> show result -> Done closes the app. Packaged as a real signed
// .app bundle by build-and-sign.sh, with the same signing discipline LocalLM Lab's own release
// tooling uses, since a bare SwiftPM executable can't get TCC grants (no Info.plist/usage-
// description strings, no code signing) -- confirmed the hard way in the CLI-only version of this
// app.

import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import SwiftUI

// MARK: - Calendar tool (via Core's CalendarAccess connector)

struct TodaysEventsTool: Tool {
    let name = "getTodaysCalendarEvents"
    let description = "Retrieve the user's calendar events for today"

    // Zero-property Arguments is valid and correct for a no-input tool (proven by Core's
    // ClockTool) -- an earlier "unused placeholder" field here was a fragile workaround that
    // actively caused decode failures: FoundationModels sometimes calls a tool with genuinely
    // empty generated content when no argument makes sense, and a required-but-unused field then
    // fails to decode from that empty content.
    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let access = await CalendarAccess.requestAccess()             // ← SDK
        guard access.granted else { return access.error ?? "Calendar access not granted." }

        // upcomingEvents(days:) is "from now through the next N days," not "all of today
        // including anything already past" — CalendarAccess's own semantics, shared with
        // LocalLM Lab itself, rather than plate-today inventing its own start-of-day window.
        let events = CalendarAccess.upcomingEvents(days: 1)           // ← SDK
        if events.isEmpty { return "No upcoming calendar events today." }
        return events.map { "- \($0.title) (\($0.start))" }.joined(separator: "\n")
    }
}

// MARK: - Reminders tool (via Core's RemindersAccess connector)

struct TodaysRemindersTool: Tool {
    let name = "getTodaysReminders"
    let description = "Retrieve the user's incomplete reminders due today"

    // Zero-property Arguments is valid and correct for a no-input tool (proven by Core's
    // ClockTool) -- an earlier "unused placeholder" field here was a fragile workaround that
    // actively caused decode failures: FoundationModels sometimes calls a tool with genuinely
    // empty generated content when no argument makes sense, and a required-but-unused field then
    // fails to decode from that empty content.
    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let access = await RemindersAccess.requestAccess()            // ← SDK
        guard access.granted else { return access.error ?? "Reminders access not granted." }

        let reminders = await RemindersAccess.upcomingReminders(days: 1)  // ← SDK
        if reminders.isEmpty { return "No upcoming reminders due today." }
        return reminders.map { "- \($0.title)" }.joined(separator: "\n")
    }
}

// MARK: - Location tool (via Core's LocationAccess connector)

#if PLATETODAY_INCLUDE_LOCATION_WEATHER
// Not shipped as part of Core (unlike ClockTool/WeatherTool) because LocationAccess itself, and
// therefore this wrapper, is a permission-gated connector — same "app decides how to expose it"
// reasoning as TodoistTasksTool below. Mirrors LocalLM Lab's own LocationTool.
//
// Build-time opt-in, default off — see Package.swift's PLATETODAY_INCLUDE_LOCATION_WEATHER
// comment for why (Location Services flakiness + tccutil's Location reset limitation).
struct TodaysLocationTool: Tool {
    let name = "getCurrentLocation"
    let description = "Returns the user's current one-shot location (place name, if available) — useful as input to the weather tool."

    // Zero-property Arguments is valid and correct for a no-input tool (proven by Core's
    // ClockTool) -- an earlier "unused placeholder" field here was a fragile workaround that
    // actively caused decode failures: FoundationModels sometimes calls a tool with genuinely
    // empty generated content when no argument makes sense, and a required-but-unused field then
    // fails to decode from that empty content.
    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let access = await Connectors.requestAccess(.location)        // ← SDK
        guard access.granted else { return access.error ?? "Location access not granted." }

        guard let location = await LocationAccess.shared.currentLocation() else {  // ← SDK
            return "Error: could not get a location fix."
        }
        let place = location.placeName ?? "latitude \(location.latitude), longitude \(location.longitude)"
        // Surface accuracy rather than discarding it — a desktop Mac with no GPS estimates
        // location from network/Wi-Fi positioning, which can be off by tens of kilometers (or
        // land in the wrong city entirely). Silently presenting that as a precise fix is
        // actively misleading; telling the model the margin lets it hedge appropriately
        // ("approximately") instead of stating a wrong city as fact.
        return "\(place) (±\(Int(location.horizontalAccuracyMeters))m accuracy — this is a network-based estimate, not GPS, and may be inaccurate on a desktop Mac)"
    }
}
#endif

// MARK: - Todoist tool (via Core's MCP client)

struct TodoistTasksTool: Tool {
    let name = "getTodoistTasksDueToday"
    let description = "Retrieve the user's Todoist tasks due today"
    let manager: MCPServerManager                                     // ← SDK (type)
    let serverURL: URL

    // Zero-property Arguments is valid and correct for a no-input tool (proven by Core's
    // ClockTool) -- an earlier "unused placeholder" field here was a fragile workaround that
    // actively caused decode failures: FoundationModels sometimes calls a tool with genuinely
    // empty generated content when no argument makes sense, and a required-but-unused field then
    // fails to decode from that empty content.
    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let connectResult = await manager.addServer(url: serverURL, displayName: "Todoist")  // ← SDK
        switch connectResult {
        case .failure(let error):
            return "Could not connect to Todoist MCP server: \(error)"
        case .success(let state):
            guard let tool = state.tools.first(where: { $0.name == "find-tasks-by-date" }) else {
                return "Connected to Todoist, but find-tasks-by-date wasn't found among: \(state.tools.map(\.name).joined(separator: ", "))"
            }
            // exclude-overdue so this tool's output actually matches its name/description
            // ("due today") rather than silently also including overdue tasks, which is
            // find-tasks-by-date's own default (overdueOption: "include-overdue").
            let result = await manager.callTool(                      // ← SDK
                server: state.id, tool: tool.name,
                arguments: ["startDate": .string("today"), "overdueOption": .string("exclude-overdue")]  // ← SDK (MCPValue)
            )
            switch result {
            case .success(let toolResult): return toolResult.renderedForModel   // ← SDK (MCPToolResult, since beta.4)
            case .failure(let error): return "Todoist tool call failed: \(error)"
            }
        }
    }
}

// MARK: - View model driving the launch -> fetch -> show -> Done flow

@available(macOS 26.0, *)
@MainActor
final class PlateTodayModel: ObservableObject {
    enum State {
        case idle
        case fetching
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let manager = MCPServerManager()                          // ← SDK
    private let todoistURL = URL(string: ProcessInfo.processInfo.environment["TODOIST_MCP_URL"] ?? "https://ai.todoist.net/mcp")!

    func start() {
        guard case .idle = state else { return }
        state = .fetching
        Task { await fetch() }
    }

    // Called from the Done button, before the app terminates — this is a dev/demo app, not
    // something meant to accumulate standing Todoist access across runs, so each run's grant is
    // wiped rather than persisted. removeServer(_:) already clears both the OAuth and PAT
    // Keychain entries for a server, so reusing it here covers both without duplicating that logic.
    func cleanUpBeforeQuit() {
        manager.removeServer(MCPServerID(rawValue: todoistURL.absoluteString))  // ← SDK
    }

    private func fetch() async {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            state = .failed("On-device model unavailable: \(model.availability)")
            return
        }

        var tools: [any Tool] = [
            ClockTool(),                                              // ← SDK
            TodaysEventsTool(),
            TodaysRemindersTool(),
        ]
        // What to check and what to summarize both build up from the same set of conditionally
        // included pieces, rather than four separately-written prompt strings for every
        // Todoist x Location/Weather combination — that combinatorial duplication is exactly what
        // the previous two-prompt version (Location/Weather on/off only) was one flag away from
        // needing.
        var checks = ["the current time", "calendar events", "reminders"]
        var summarizeNote = ""
        #if PLATETODAY_INCLUDE_TODOIST
        tools.append(TodoistTasksTool(manager: manager, serverURL: todoistURL))
        checks.append("Todoist tasks")
        #endif
        #if PLATETODAY_INCLUDE_LOCATION_WEATHER
        tools.append(TodaysLocationTool())
        tools.append(WeatherTool())                                   // ← SDK
        checks.append("the user's current location and today's weather there (getCurrentLocation, then getWeather with that place)")
        summarizeNote = ", including the weather"
        #endif
        let prompt = """
        What's on my plate today? Check \(checks.joined(separator: ", ")). Summarize my day in a \
        friendly, concise way\(summarizeNote).
        """
        let session = LanguageModelSession(tools: tools)

        do {
            let response = try await session.respond(to: prompt)
            state = .ready(response.content)
        } catch {
            state = .failed("\(error)")
        }
    }
}

// MARK: - UI

@available(macOS 26.0, *)
struct ContentView: View {
    @ObservedObject var model: PlateTodayModel

    var body: some View {
        VStack(spacing: 20) {
            Text("What's on my plate today?")
                .font(.title2).bold()

            switch model.state {
            case .idle:
                ProgressView()
            case .fetching:
                ProgressView("Checking your calendar, reminders, and Todoist…")
            case .ready(let summary):
                ScrollView {
                    Text(summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .padding()
            }

            Spacer()

            Button("Done") {
                model.cleanUpBeforeQuit()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        // Height only, not width — a full day's summary (calendar + reminders + Todoist,
        // optionally weather) can run well past the original fixed 360pt, and the ScrollView
        // above only helps once the window itself is tall enough to be worth scrolling within.
        // Width stays fixed; this is a single-column text summary, not a layout that benefits
        // from stretching wider.
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 420, minHeight: 360, idealHeight: 360, maxHeight: .infinity)
        .onAppear { model.start() }
    }
}

// Handles platetoday://oauth/callback here rather than via SwiftUI's .onOpenURL —
// WindowGroup treats an open-URL event as a request for a new scene instance and spins up a
// second window for it (confirmed live: signing in to Todoist brought back a second "Plate
// Today" window instead of returning to the original one). NSApplicationDelegate gets the same
// Apple Event without SwiftUI creating anything — same fix LocalLM Lab's own main window
// already uses for this exact problem.
@available(macOS 26.0, *)
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "platetoday" {
            MCPOAuthRedirectListener.shared.handleRedirect(url)        // ← SDK
        }
    }
}

@available(macOS 26.0, *)
@main
struct PlateTodayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PlateTodayModel()

    init() {
        // Distinct from LocalLM Lab's own "locallmlab" scheme so the two apps' OAuth callbacks
        // don't collide if both are installed on the same Mac — see Info.plist's CFBundleURLTypes
        // for the matching registration.
        MCPOAuthFlow.redirectURI = "platetoday://oauth/callback"       // ← SDK
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        // .contentMinSize, not .contentSize: the latter continuously ties the window's size to
        // content's *ideal* size on every re-layout, which fights a user's manual resize — every
        // drag would just get snapped back. .contentMinSize only imposes a floor (from
        // ContentView's own minHeight above), leaving the user's own resize as the real source of
        // truth for how tall the window can grow. Same reasoning as LocalLM Lab's own main
        // windows.
        .windowResizability(.contentMinSize)
        // Without this, WindowGroup matches every external event by default and ALSO opens a new
        // scene for the same platetoday:// callback AppDelegate already handles above — matching
        // nothing here makes AppDelegate the only handler, same as LocalLM Lab's own app.
        .handlesExternalEvents(matching: [])
    }
}
```

**Tally**: of ~230 lines of actual code (excluding comments/blank lines), 17 touch the SDK directly
(marked above) — everything else is ordinary SwiftUI state/view code and FoundationModels session
setup that would look the same regardless of where the tools' data comes from.

## `examples/plate-today-tools`

*`Sources/PlateTodayTools/PlateTodayToolsApp.swift` — 149 lines of code (235 with comments) — ~130 fewer than `plate-today` for the same app.*

The Path A twin of plate-today above — same app, same UI, same connectors, rebuilt on Core's
ready-made FoundationModels Tools (§7a of `sdk-guide.md`) instead of hand-writing a `Tool` struct
per connector. Marked the same way, plus `// ← SDK (Path A)` specifically on lines that only exist
*because* a ready-made Tool replaces what used to be a whole hand-written struct — diff this
against the section above to see the two approaches side by side.

```swift
// "What's on my plate today" — Tools edition. The exact same app as examples/plate-today (same
// UI, same prompt, same connectors), rebuilt on Core's ready-made FoundationModels Tools instead
// of hand-writing a Tool struct per connector. Diff this file against plate-today's
// PlateTodayApp.swift to see the "Path A vs Path B" difference described in
// docs/sdk-guide.md §7a in actual code, not just prose — every place the two files diverge is
// called out below with a `DIFF FROM plate-today:` comment.

import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import SwiftUI

// MARK: - Calendar, Reminders, Location, Contacts tools

// DIFF FROM plate-today: no TodaysEventsTool/TodaysRemindersTool/TodaysLocationTool/
// SearchContactsTool structs here at all — GetUpcomingEventsTool, GetUpcomingRemindersTool,
// GetCurrentLocationTool, and SearchContactsTool are Core types, instantiated directly in
// fetch() below. ~130 fewer lines than the section above, in exchange for one real behavioral
// difference: these ready-made Tools don't call requestAccess() lazily inside call() the way
// plate-today's hand-written ones do, so this app requests access up front instead — see
// requestConnectorAccess() below.

// MARK: - View model driving the launch -> fetch -> show -> Done flow

@available(macOS 26.0, *)
@MainActor
final class PlateTodayToolsModel: ObservableObject {
    enum State {
        case idle
        case fetching
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let manager = MCPServerManager()                          // ← SDK
    private let todoistURL = URL(string: ProcessInfo.processInfo.environment["TODOIST_MCP_URL"] ?? "https://ai.todoist.net/mcp")!

    func start() {
        guard case .idle = state else { return }
        state = .fetching
        Task { await fetch() }
    }

    func cleanUpBeforeQuit() {
        manager.removeServer(MCPServerID(rawValue: todoistURL.absoluteString))  // ← SDK
    }

    // DIFF FROM plate-today: request access up front, before any Tool exists — Path A's
    // ready-made Tools need this instead of requesting lazily inside call().
    private func requestConnectorAccess() async -> String? {
        let calendarAccess = await CalendarAccess.requestAccess()      // ← SDK
        guard calendarAccess.granted else { return calendarAccess.error ?? "Calendar access not granted." }
        let remindersAccess = await RemindersAccess.requestAccess()    // ← SDK
        guard remindersAccess.granted else { return remindersAccess.error ?? "Reminders access not granted." }
        #if PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER
        let locationAccess = await Connectors.requestAccess(.location) // ← SDK
        guard locationAccess.granted else { return locationAccess.error ?? "Location access not granted." }
        #endif
        #if PLATETODAYTOOLS_INCLUDE_CONTACTS
        let contactsAccess = await Connectors.requestAccess(.contacts) // ← SDK
        guard contactsAccess.granted else { return contactsAccess.error ?? "Contacts access not granted." }
        #endif
        return nil
    }

    // DIFF FROM plate-today's TodoistTasksTool: that hand-written tool pinned specific arguments
    // on every call regardless of what the model asked for, and gave the tool its own curated
    // name/description independent of the real server. MCPTool exposes the tool exactly as
    // Todoist's own server defines it — real name, real description, real full argument schema
    // (built at runtime from the server's JSON Schema) — and leaves every argument up to the
    // model. A real tradeoff, not just less code: see the prompt below, which now has to ask
    // explicitly for "excluding anything overdue" to compensate.
    private func buildTodoistTool() async -> (any Tool)? {
        let connectResult = await manager.addServer(url: todoistURL, displayName: "Todoist")  // ← SDK
        guard case .success(let state) = connectResult else { return nil }
        guard let descriptor = state.tools.first(where: { $0.name == "find-tasks-by-date" }) else { return nil }
        return try? MCPTool(descriptor: descriptor, manager: manager)  // ← SDK (Path A)
    }

    private func fetch() async {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            state = .failed("On-device model unavailable: \(model.availability)")
            return
        }

        if let accessError = await requestConnectorAccess() {
            state = .failed(accessError)
            return
        }

        // DIFF FROM plate-today: GetUpcomingEventsTool()/GetUpcomingRemindersTool() straight
        // from Core, no local struct definitions above to instantiate instead.
        var tools: [any Tool] = [
            ClockTool(),                                              // ← SDK
            GetUpcomingEventsTool(),                                  // ← SDK (Path A)
            GetUpcomingRemindersTool(),                               // ← SDK (Path A)
        ]
        var checks = ["the current time", "calendar events", "reminders"]
        var summarizeNote = ""
        #if PLATETODAYTOOLS_INCLUDE_TODOIST
        if let todoistTool = await buildTodoistTool() {
            tools.append(todoistTool)
            checks.append("Todoist tasks due today, excluding anything overdue")
        }
        #endif
        #if PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER
        tools.append(GetCurrentLocationTool())                        // ← SDK (Path A)
        tools.append(WeatherTool())                                   // ← SDK
        checks.append("the user's current location and today's weather there (getCurrentLocation, then getWeather with that place)")
        summarizeNote = ", including the weather"
        #endif
        #if PLATETODAYTOOLS_INCLUDE_CONTACTS
        tools.append(SearchContactsTool())                            // ← SDK (Path A)
        #endif
        let prompt = """
        What's on my plate today? Check \(checks.joined(separator: ", ")). Summarize my day in a \
        friendly, concise way\(summarizeNote).
        """
        let session = LanguageModelSession(tools: tools)

        do {
            let response = try await session.respond(to: prompt)
            state = .ready(response.content)
        } catch {
            state = .failed(await GenerationErrorDescription.describe(error))  // ← SDK
        }
    }
}

// MARK: - UI, AppDelegate, App (identical in shape to plate-today's — nothing here changes
// between Path A and Path B, only the OAuth URL scheme differs: "platetodaytools" instead of
// "platetoday", so both apps' OAuth callbacks can coexist on the same Mac)
```

**Tally**: essentially the same line count as plate-today for UI/plumbing, but roughly 130 fewer
lines overall — every hand-written `Tool` struct plate-today needed for Calendar/Reminders/
Location/Contacts is gone, replaced by a single `Core` type each. The MCP integration keeps the
same line count either way (`MCPTool(descriptor:manager:)` vs. a hand-written `TodoistTasksTool`
struct), but trades pinned arguments for a raw, server-defined tool surface — see the
`buildTodoistTool()` comment above.

## `examples/repo-qa`

*`Sources/RepoQA/main.swift` — 66 lines of code (115 with comments) — the smallest SDK program here.*

A third, deliberately different shape: a plain command-line tool, not a signed GUI `.app` — MCP
touches nothing TCC-gated, so there's no permission prompt to need a real bundle for. Builds an
`MCPTool` for every tool a server offers, in a loop, entirely from that server's own live schema.

```swift
// Repo Q&A — a third reference app, deliberately different in shape from plate-today/
// plate-today-tools: a plain command-line tool, not a signed GUI .app. Where plate-today
// demonstrates Calendar/Reminders (TCC-gated, needs a real bundle + entitlements to get a
// permission prompt at all — see that app's own top-of-file comment), this app touches nothing
// TCC-gated: MCP network calls need no macOS permission, so a bare `swift run` binary works
// end to end, no packaging/ directory, no code signing, no Info.plist. That's the point of this
// example existing separately rather than as a third tool bolted onto plate-today-tools — it
// shows Core's MCPTool (Path A — see docs/sdk-guide.md §7a) in its simplest possible setting.
//
// Narrative: ask a free-form question about any public GitHub repository's own documentation,
// answered by Apple's on-device model calling Deepwiki's real hosted MCP server
// (https://mcp.deepwiki.com/mcp, no auth, no API key) — MCPTool built at runtime directly from
// Deepwiki's own JSON Schema, no hand-written Arguments struct for either tool actually offered
// (see the tool-building loop below for why only two of Deepwiki's three tools are offered).
//
//   swift run RepoQA anthropics/claude-code "What is the plugin system?"
//   swift run RepoQA facebook/react                      # defaults to a general "what is this?" question

import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK

// Status/progress goes to stderr; only the model's final answer goes to stdout, so
// `swift run RepoQA … 2>/dev/null` gives you just the answer. (repo-qa-local does the same.)
func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

@available(macOS 26.0, *)
@MainActor
func run() async {
    let arguments = CommandLine.arguments.dropFirst()
    guard let repoName = arguments.first, !repoName.isEmpty else {
        note("""
        usage: swift run RepoQA <owner/repo> [question]
        example: swift run RepoQA anthropics/claude-code "What is the plugin system?"
        """)
        exit(1)
    }
    let question = arguments.dropFirst().joined(separator: " ")
    let effectiveQuestion = question.isEmpty ? "What does this repository do, in a couple sentences?" : question

    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        note("On-device model unavailable: \(model.availability)")
        return
    }

    // No requestAccess() call anywhere in this file — MCP is the one connector type that was
    // never TCC-gated (see docs/sdk-guide.md's Connectors section vs. its MCP section), so
    // there's no permission step to request before connecting. Contrast with
    // plate-today-tools' requestConnectorAccess(), needed there specifically because Calendar/
    // Reminders are gated and this file's equivalent tools aren't.
    let manager = MCPServerManager()                                  // ← SDK
    note("Connecting to Deepwiki…")
    let connectResult = await manager.addServer(                      // ← SDK
        url: URL(string: "https://mcp.deepwiki.com/mcp")!,
        displayName: "Deepwiki"
    )
    guard case .success(let state) = connectResult else {
        note("Could not connect to Deepwiki: \(connectResult)")
        return
    }

    // Builds a Tool for each of Deepwiki's tools from its own live schema — nothing here knows
    // ask_question's or read_wiki_structure's argument shapes in advance, MCPTool derives both
    // from the server's real JSON Schema at runtime. One deliberate exclusion, not a schema
    // failure: read_wiki_contents dumps a repo's ENTIRE wiki, unscoped, no pagination — confirmed
    // live against anthropics/claude-code at 541,359 characters (~165,000 tokens) for a single
    // call, ~20x this model's whole ~8,000-token context window. The on-device model has no way to
    // know that in advance from the tool's name/description alone, and picked it for a plain
    // "what is the plugin system?" question in real testing, hard-failing the whole session. This
    // is exactly the risk docs/sdk-guide.md §3 already warns about ("don't naively pass all of
    // them into a LanguageModelSession without picking the ones your prompt actually needs") —
    // MCPTool itself has no way to know a tool's real-world response size from its schema, since
    // JSON Schema describes shape, not payload size; that judgment call is the integrating app's
    // to make, same as everywhere else Core hands you a raw capability and leaves the curation to
    // you. A tool whose schema doesn't build (MCPTool's init throws) is still skipped with a
    // warning rather than aborting the whole run.
    var tools: [any Tool] = []
    for descriptor in state.tools {
        guard descriptor.name != "read_wiki_contents" else {
            note("Skipping \(descriptor.name): excluded by this example — see the comment above.")
            continue
        }
        do {
            tools.append(try MCPTool(descriptor: descriptor, manager: manager))  // ← SDK (Path A)
        } catch {
            note("Skipping \(descriptor.name): \(error)")
        }
    }
    guard !tools.isEmpty else {
        note("Deepwiki didn't offer any usable tools.")
        return
    }
    note("Built \(tools.count) tool(s) from Deepwiki's live schema: \(tools.map(\.name).joined(separator: ", "))")

    let session = LanguageModelSession(tools: tools) {
        "You answer questions about GitHub repositories using the documentation tools available to you. Always ground your answer in what the tools actually return — don't answer from general knowledge if a tool call would give a more specific, current answer."
    }

    let prompt = "Regarding the GitHub repository \"\(repoName)\": \(effectiveQuestion)"
    note("\nAsking: \(prompt)\n")

    do {
        let response = try await session.respond(to: prompt)
        print(response.content)
    } catch {
        note("Error: \(await GenerationErrorDescription.describe(error))")  // ← SDK
    }
}

if #available(macOS 26.0, *) {
    await run()
} else {
    print("Requires macOS 26 or later.")
}
```

**Tally**: of the file's 66 non-comment/non-blank lines, five touch the SDK — this is the entire
surface area needed to go from nothing to "the on-device model calling a real, remote MCP tool
it's never seen before." No `Arguments` struct, no `Tool`-conforming type of this app's own —
`ask_question`'s real schema (including a `repoName: string | string[]` union JSON Schema doesn't
have a single Swift equivalent for) converts automatically, degrading the union to a plain string
leaf per `MCPToolAdapter`'s documented behavior for constructs past the common case. Note the
`read_wiki_contents` exclusion above the tool-building loop: it's app-level curation, not an SDK
behavior — `MCPTool` will happily wrap any tool a server advertises, real-world response size and
all; deciding which of a server's tools are actually safe to hand a small on-device model is
entirely this app's judgment call, the same point docs/sdk-guide.md §6 makes about tool selection
generally.

## `examples/workspace-buddy`

*`Sources/WorkspaceBuddy/WorkspaceBuddyApp.swift` — 172 lines of code (226 with comments) — the plain-SwiftUI UI section is elided below.*

A fourth shape again: the first reference app that writes to disk, and the first sandboxed by
default. Pick a folder, describe a change, the on-device model reads/creates/edits files in it via
`WorkspaceTools` (Path A). The folder-picker/bookmark code (`FolderAccess`) is §8's own documented
pattern, extended with one real addition — see the `// ← SDK` markers below and the inline comment
on `withFolderAccessAsync`.

```swift
// Workspace Buddy — pick a folder, type a request, the on-device model reads/creates/edits files
// in it via Core's WorkspaceTools.swift (Path A). Single-turn per request, same minimal shape as
// plate-today/repo-qa.

import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import SwiftUI

// MARK: - Folder picker + security-scoped bookmark (see docs/sdk-guide.md §8)

// Verbatim from §8's documented pattern, with one real addition not covered there: an
// async-aware access wrapper. §8's own withFolderAccess<T>(_:) brackets a SYNCHRONOUS body —
// fine for a single read, but this app's actual file access happens inside
// LanguageModelSession.respond(to:), which can invoke several tool calls over one async call.
// The security-scoped access window has to stay open for that whole call, not just a synchronous
// setup step.
enum FolderAccess {
    private static let bookmarkKey = "workspaceFolderBookmark"

    @MainActor
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return url
    }

    static func resolveBookmarkedFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale {
            if let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
        }
        return url
    }

    // DIFF FROM §8's synchronous withFolderAccess<T>(_:): brackets an ASYNC body, so the access
    // window stays open for a whole LanguageModelSession.respond(to:) call.
    @MainActor
    static func withFolderAccessAsync<T>(_ body: (URL) async throws -> T) async rethrows -> T? {
        guard let url = resolveBookmarkedFolder() else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try await body(url)
    }
}

// MARK: - View model

@available(macOS 26.0, *)
@MainActor
final class WorkspaceBuddyModel: ObservableObject {
    enum State { case idle, working, ready(String), failed(String) }

    @Published private(set) var folderURL: URL?
    @Published private(set) var state: State = .idle

    init() { folderURL = FolderAccess.resolveBookmarkedFolder() }

    func chooseFolder() {
        guard let url = FolderAccess.pickFolder() else { return }
        folderURL = url
    }

    func submit(_ request: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .working = state { return }
        state = .working
        Task { await run(trimmed) }
    }

    private func run(_ request: String) async {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            state = .failed("On-device model unavailable: \(model.availability)")
            return
        }

        let result: String? = await FolderAccess.withFolderAccessAsync { root in
            // No DeleteWorkspaceFileTool here — available in Core (see WorkspaceTools.swift) for
            // a host app that explicitly wants it, just not wired in by default.
            let tools: [any Tool] = [
                ListWorkspaceFilesTool(root: root),                   // ← SDK (Path A)
                ReadWorkspaceFileTool(root: root),                    // ← SDK (Path A)
                WriteWorkspaceFileTool(root: root),                   // ← SDK (Path A)
                EditWorkspaceFileTool(root: root),                    // ← SDK (Path A)
            ]
            let session = LanguageModelSession(tools: tools) {
                """
                You are a coding assistant working in a single project folder. Use \
                listWorkspaceFiles to see what's there and readWorkspaceFile before editing \
                anything — never guess a file's contents. Prefer editWorkspaceFile (a targeted \
                find-and-replace) over writeWorkspaceFile for changes to files that already \
                exist; writeWorkspaceFile only creates brand-new files and fails if the file is \
                already there. Explain what you changed and why, briefly.
                """
            }
            do {
                let response = try await session.respond(to: request)
                return response.content
            } catch {
                return "Error: \(await GenerationErrorDescription.describe(error))"  // ← SDK
            }
        }

        guard let result else {
            state = .failed("Could not access the workspace folder — try choosing it again.")
            return
        }
        state = .ready(result)
    }
}

// MARK: - UI (ordinary SwiftUI — folder path display, a text field, a Go button, a result view)
```

**Tally**: of ~150 lines of actual code (excluding the UI section, which is plain SwiftUI with no
SDK touchpoints), five lines touch the SDK directly — four Tool instantiations and one error
formatter. The folder-picker/bookmark machinery is entirely `FolderAccess`, §8's own documented
pattern rather than Core code — the point being made here isn't "look how much SDK code this
needs," it's the opposite: given a resolved URL, actually reading/writing files safely inside a
sandbox is four one-line Tool instantiations, not a filesystem library to write yourself.

## `examples/components-demo`

*`Sources/ComponentsDemo/ComponentsDemoApp.swift` — 141 lines of code (189 with comments).*

Demonstrates `Components`: the prebuilt server picker, resource/prompt browsing — no hand-written
MCP-management UI at all.

```swift
// Components Demo — the SDK's second reference app. plate-today shows building a real feature on
// Core's API directly; this shows the other half of the pitch: drop in Components' prebuilt
// MCPServerPickerView and get a working "add/manage MCP servers" screen with a few lines of glue
// code, no UI of your own to write.
//
// Packaged as a real signed .app (packaging/build-and-sign.sh) for the same reason plate-today is:
// the OAuth redirect needs a registered URL scheme, which a bare `swift run` binary doesn't have.

import Combine
import LocalLMLabSDKComponents                                        // ← Components
import LocalLMLabSDKCore                                               // ← SDK
import SwiftUI

// MARK: - View model

// Thin glue only — everything interesting (add/reconnect/disconnect/remove, all three auth types,
// the in-flight OAuth overlay) already lives inside MCPServerPickerView itself. This model's only
// job is the one thing that view doesn't do: surface what actually becomes available for a
// FoundationModels tool-calling session once servers are connected, so this app demonstrates the
// whole point of Components (pick servers -> get tools), not just that the picker UI paints.
@available(macOS 26.0, *)
@MainActor
final class ComponentsDemoModel: ObservableObject {
    let manager: MCPServerManagerObservable                           // ← Components (type)
    @Published private(set) var availableTools: [MCPToolDescriptor] = []  // ← SDK (type)
    // What a real host app would do with an attached resource or an expanded prompt is entirely
    // its own business (see MCPResourcesView/MCPPromptsView's doc comment) — this is the simplest
    // possible stand-in for "a text field the model would actually see," just so this app can
    // prove the whole read -> use loop live, the same way the tools panel proves toolsForSession().
    @Published var attachedText = ""
    private var cancellable: AnyCancellable?

    init() {
        let core = MCPServerManager()                                 // ← SDK
        manager = MCPServerManagerObservable(core: core)               // ← Components
        // toolsForSession() itself isn't reactive (it's a plain synchronous query against Core's
        // current state, same shape a real tool-calling call site would use), so re-derive it
        // whenever the picker's own @Published servers dictionary changes, rather than polling.
        // MCPServerState isn't Equatable, so this goes through Combine directly instead of
        // SwiftUI's .onChange (which requires Equatable).
        cancellable = manager.$servers.sink { [weak self] _ in self?.refreshAvailableTools() }  // ← Components ($servers)
    }

    func refreshAvailableTools() {
        availableTools = manager.core.toolsForSession()                // ← SDK
    }

    func attach(_ name: String, _ content: MCPResourceContent) {       // ← SDK (parameter type)
        let text = content.text ?? "(binary content — \(content.mimeType ?? "unknown type"), not shown as text)"
        attachedText += "\n\n[Attached: \(name)]\n\(text)"
    }

    func use(_ prompt: MCPPromptDescriptor, _ messages: [MCPPromptMessage]) {  // ← SDK (parameter types)
        attachedText += "\n\n[Prompt: \(prompt.name)]\n" + messages.map(\.text).joined(separator: "\n\n")
    }
}

// MARK: - UI

@available(macOS 26.0, *)
struct ContentView: View {
    @ObservedObject var model: ComponentsDemoModel
    @State private var showResources = false
    @State private var showPrompts = false

    var body: some View {
        HSplitView {
            MCPServerPickerView(manager: model.manager)                // ← Components
                .frame(minWidth: 480)

            // What a real tool-calling session would actually see right now — makes the
            // add-a-server flow concretely useful to look at, not just a form that saves
            // somewhere invisible.
            VStack(alignment: .leading, spacing: 12) {
                Text("Tools available this session")
                    .font(.headline)
                Text("What LanguageModelSession(tools:) would see right now, from manager.core.toolsForSession() — updates as you add, enable/disable, or remove servers.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Divider()
                if model.availableTools.isEmpty {
                    Text("No tools available yet — add a server and enable some tools.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.availableTools, id: \.name) { tool in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    Text(tool.description)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }

                Divider()
                HStack {
                    Text("Resources & prompts").font(.headline)
                    Spacer()
                    Button("Resources…") { showResources = true }
                    Button("Prompts…") { showPrompts = true }
                }
                Text("Extracting value beyond tool-calling — read an enabled resource's content, or expand an enabled prompt — via MCPResourcesView/MCPPromptsView. What each does with the result is entirely up to this app (below is just a stand-in for \"a text field the model would see\").")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(model.attachedText.isEmpty ? "Nothing attached yet." : model.attachedText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(model.attachedText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                Spacer()
            }
            .padding(20)
            .frame(minWidth: 280)
        }
        .frame(minWidth: 800, minHeight: 480)
        .sheet(isPresented: $showResources) {
            VStack(spacing: 0) {
                HStack {
                    Text("Resources").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Done") { showResources = false }
                }
                .padding(16)
                Divider()
                MCPResourcesView(manager: model.manager, onAttach: { descriptor, content in  // ← Components
                    model.attach(descriptor.name, content)
                })
            }
            .frame(width: 480, height: 480)
        }
        .sheet(isPresented: $showPrompts) {
            VStack(spacing: 0) {
                HStack {
                    Text("Prompts").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Done") { showPrompts = false }
                }
                .padding(16)
                Divider()
                MCPPromptsView(manager: model.manager, onUse: { prompt, messages in  // ← Components
                    model.use(prompt, messages)
                })
            }
            .frame(width: 480, height: 480)
        }
    }
}

// Handles componentsdemo://oauth/callback directly, the same way plate-today's AppDelegate does
// and for the same reason: WindowGroup treats an open-URL event as a request for a new scene
// instance and would otherwise spin up a second window instead of returning to this one. Distinct
// scheme from both plate-today ("platetoday") and LocalLM Lab itself ("locallmlab") so none
// collide if all three are installed on the same Mac.
@available(macOS 26.0, *)
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "componentsdemo" {
            MCPOAuthRedirectListener.shared.handleRedirect(url)        // ← SDK
        }
    }
}

@available(macOS 26.0, *)
@main
struct ComponentsDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ComponentsDemoModel()

    init() {
        MCPOAuthFlow.redirectURI = "componentsdemo://oauth/callback"   // ← SDK
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
    }
}
```

**Tally**: of ~150 lines of actual code, three lines build the manager/wrapper and three more drop
in the prebuilt views (`MCPServerPickerView`, `MCPResourcesView`, `MCPPromptsView`) — the rest is
this app's own UI around them (the tools panel, the attached-text display) and the small amount of
glue (`toolsForSession()`, the OAuth scheme/callback wiring) any Core-linked app needs regardless
of whether it uses `Components` or not.

## `examples/code-buddy`

*315 lines of code across the app's two files, `main.swift` + `ProcessTools.swift` (below).*

The fullest **model-layer** example (see also
[`repo-qa-local`](#examplesrepo-qa-local) for the minimal one, and
[`workspace-buddy-local`](#examplesworkspace-buddy-local)
for the sandboxed one, both annotated below), and one of several linking a second binary, `LocalLMLabSDKInference.xcframework`
(the MLX runtime). Lines that touch it are marked `// ← SDK (Inference)`; `// ← SDK` is Core as
elsewhere. A CLI coding agent: point it at a repo, give it a task (one-shot) or omit the task to
get a `>>` loop over one persistent session, and it downloads an open-weight MLX model on first
run (pinned to the exact commit the example was tried against, so a fresh download never silently
picks up whatever `main` has become), then drives Core's Workspace tools + host `Process` tools + (auto) MCP tools through a routed
`LocalLMLabSession`. Ctrl-C cancels the running turn — reaching the `Process` tools so a child
`swift test` is terminated, not orphaned — and quits from an idle prompt. See
[`sdk-guide.md` §6a](sdk-guide.md#6a-the-model-layer-local-models-routing-sessions) for the prose.

### `Sources/CodeBuddy/main.swift`

*220 lines of code (290 with comments).*

```swift
import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKInference                                         // ← SDK (Inference)

// code-buddy — a minimal coding agent on the LocalLM Lab SDK.
//   code-buddy [--route heavy|light] [--heavy <repo>] [--light <repo>]
//              [--test-cmd "<cmd>"] [--no-mcp] [--no-verbose] <workspace-dir> [task...]
// With a task: run it and stop. Without: a >> loop over one session until `quit` / Ctrl-D.

// The default models are pinned to the exact commits this example was tried against, so a fresh
// download never silently picks up whatever the repo's `main` has become. A model chosen with
// --heavy / --light isn't listed here; it is pinned to the version you first download instead
// (trust on first use), so re-downloading it later gets the same bytes. To change a default:
// review the new version, then update the repo and its commit together.
let shippedPins: [String: String] = [
    "mlx-community/Qwen3-8B-4bit": "545dc4251c05440727734bcd94334791f6ab0192",
    "mlx-community/Qwen2.5-3B-Instruct-4bit": "4f83f8f146fdf28b512a06562b671d7af4fab457",
]

struct Options {
    var route: RouteName = .heavy                                     // ← SDK
    var heavy = "mlx-community/Qwen3-8B-4bit"
    var light = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    var testCommand = ["swift", "test"]
    var useMCP = true
    var verbose = true                        // print the per-tool-call trace
    var workspace = ""
    var task = ""
}

func parseArgs() -> Options {
    var o = Options()
    var rest: [String] = []
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--route": if let v = it.next() { o.route = RouteName(v) }   // ← SDK
        case "--heavy": if let v = it.next() { o.heavy = v }
        case "--light": if let v = it.next() { o.light = v }
        case "--test-cmd": if let v = it.next() { o.testCommand = v.split(separator: " ").map(String.init) }
        case "--no-mcp": o.useMCP = false
        case "--verbose": o.verbose = true
        case "--no-verbose": o.verbose = false
        default: rest.append(a)
        }
    }
    guard rest.count >= 1 else {
        FileHandle.standardError.write(Data("usage: code-buddy [options] <workspace-dir> [task...]\n".utf8))
        exit(2)
    }
    o.workspace = rest[0]
    o.task = rest.dropFirst().joined(separator: " ")   // empty ⇒ interactive
    return o
}

func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// Ctrl-C policy: first press during a turn cancels *that turn* and returns to the prompt;
// a press at an idle prompt — or a second press mid-turn — quits.
final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var turn: Task<Void, Never>?
    private var armed = false
    func begin(_ t: Task<Void, Never>) { lock.lock(); turn = t; armed = false; lock.unlock() }
    func end() { lock.lock(); turn = nil; armed = false; lock.unlock() }
    func fire() -> Bool {   // → true means "quit now"
        lock.lock(); defer { lock.unlock() }
        guard let turn, !armed else { return true }
        turn.cancel(); armed = true; return false
    }
}

@MainActor
func run() async {
    let opts = parseArgs()
    let root = URL(fileURLWithPath: opts.workspace, isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else {
        note("workspace \(root.path) does not exist"); exit(1)
    }

    // The whole model layer, wired in four lines: an MLX provider capped at one resident model
    // (the memory story for a constrained Mac) and pinned to the reviewed commits above, a
    // LocalLMLab bundling it with Apple's on-device provider as fallback, and two named routes.
    let mlx = MLXModelProvider(residentModelLimit: 1, pinnedRevisions: shippedPins, pinStore: MLXFilePinStore())   // ← SDK (Inference)
    let lab = LocalLMLab(configuration: .init(providers: [mlx, SystemModelProvider()]))   // ← SDK
    lab.models.route(.heavy, to: ModelID(scheme: "mlx", rest: opts.heavy)!)   // ← SDK
    lab.models.route(.light, to: ModelID(scheme: "mlx", rest: opts.light)!)   // ← SDK

    let modelID = lab.models.modelID(for: opts.route)!               // ← SDK
    note("SDK \(LocalLMLabSDKVersion.current) · route .\(opts.route) → \(modelID)")   // ← SDK

    // Pre-flight (no download) then a streamed download if the weights aren't local yet.
    if case .notDownloaded = lab.models.availability(for: modelID) {  // ← SDK
        let repo = modelID.rest
        let pre = try? await mlx.validate(repo)                       // ← SDK (Inference)
        if let pre, !pre.passed {
            note("pre-flight failed (\(pre.failedStage!.rawValue)): \(pre.detail ?? "")"); exit(1)
        }
        note("downloading \(repo)…")
        do {
            for try await event in mlx.download(repo) {              // ← SDK (Inference)
                if case .progress(_, _, let f) = event {
                    FileHandle.standardError.write(Data("\u{1B}[2K\r  \(Int(f * 100))%".utf8))
                }
            }
            note("\u{1B}[2K\r  done")
        } catch {
            note("download failed: \(error)"); exit(1)
        }
    }
    if let pin = mlx.effectivePin(for: modelID.rest) {               // ← SDK (Inference)
        note("pinned to \(pin.revision.prefix(7)) (\(pin.source == .shipped ? "shipped with this example" : "first download"))")
    }

    // Tools: Core's ready-made Workspace tools (Path A) …
    let tools: [any Tool] = [
        WorkspaceTreeTool(root: root),                               // ← SDK
        SearchWorkspaceTool(root: root),                             // ← SDK
        ReadWorkspaceFileTool(root: root),                           // ← SDK
        ReadFileRangeTool(root: root),                               // ← SDK
        EditWorkspaceFileTool(root: root),                           // ← SDK
        WriteWorkspaceFileTool(root: root),                          // ← SDK
        ListWorkspaceFilesTool(root: root),                          // ← SDK
        GitTool(root: root),                    // host-owned — see ProcessTools.swift below
        RunTestsTool(root: root, command: opts.testCommand),         // host-owned
    ]

    // … plus (auto) MCP tools: add a no-auth server and its tools merge into the session.
    if opts.useMCP {
        note("connecting DeepWiki (docs lookup)…")
        let result = await lab.mcp.addServer(url: URL(string: "https://mcp.deepwiki.com/mcp")!, displayName: "DeepWiki")   // ← SDK
        if case .success(let state) = result {
            for tool in state.tools where tool.name == "read_wiki_contents" {
                lab.mcp.setToolEnabled(server: state.id, tool: tool.name, enabled: false)   // ← SDK
            }
            note("  \(lab.mcp.toolsForSession().count) MCP tool(s)")   // ← SDK
        } else {
            note("  MCP unavailable — continuing without it")
        }
    }

    let instructions = """
        You are a coding agent working in the user's repository. Use the tools to explore and \
        change the code — workspaceTree / searchWorkspace / readWorkspaceFile / readFileRange to \
        understand it, editWorkspaceFile for changes, git for read-only history, run_tests to \
        check your work, and the DeepWiki tools … Make the smallest change that solves the task.

        Never describe an edit or a test run instead of doing it … the turn is only done once you \
        have actually called editWorkspaceFile and then run_tests … (full prompt in the source —
        the rules about announcing a plan, indentation, and editWorkspaceFile vs. overwrite exist
        because a small model got each of them wrong in real runs)
        """

    // One call: a session on the chosen route, with these tools AND the enabled MCP tools merged.
    let session: LocalLMLabSession                                   // ← SDK
    do {
        session = try lab.makeSession(route: opts.route, tools: tools, instructions: instructions)   // ← SDK
    } catch {
        note("makeSession failed: \(error)"); exit(1)
    }

    // .events is the tool-call / compaction progress stream — this is the whole trace UI.
    let events = Task { @MainActor in
        for await event in session.events {                          // ← SDK
            switch event {
            case .toolCallStarted(_, let name, _): if opts.verbose { note("  → \(name)") }
            case .toolCallFinished(_, let name, let failed, _): if opts.verbose { note("  \(failed ? "✗" : "✓") \(name)") }
            case .contextCompacted(let n): note("  (compacted \(n) transcript entries)")
            @unknown default: break                                  // non-frozen — see sdk-guide §9
            }
        }
    }

    // Ctrl-C: SIG_IGN + a DispatchSource on a background queue, so the handler runs even
    // while the main thread is parked in readLine().
    let interrupt = Interrupt()
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigint.setEventHandler {
        if interrupt.fire() { note("\nquitting…"); exit(130) }   // process exit; no explicit session.cancel() here
        note("\n^C  interrupting this turn — Ctrl-C again to quit")
    }
    sigint.resume()

    // One turn. streamResponse snapshots are *usually* append-only — but not across a tool
    // call, and not when a reasoning model drops its <think> block once the answer begins.
    // So diff against what we actually printed rather than slicing at a running offset.
    func ask(_ prompt: String) async {
        do {
            var shown = ""
            for try await partial in session.languageModelSession.streamResponse(to: prompt) {   // ← SDK
                let content = partial.content
                if content.isEmpty || content == shown { continue }
                if content.hasPrefix(shown) { print(content.dropFirst(shown.count), terminator: "") }
                else if shown.hasPrefix(content) { continue }   // snapshot shrank; already shown
                else { print(shown.isEmpty ? content : "\n" + content, terminator: "") }
                shown = content; fflush(stdout)
            }
            print()
        } catch is CancellationError {
            note("\n(interrupted — nothing further will run)")
        } catch {
            note("\nerror: \(await GenerationErrorDescription.describe(error))")   // ← SDK
        }
    }

    // Run a turn as a cancellable child Task the Ctrl-C handler can reach.
    func turn(_ prompt: String) async {
        let t = Task { await ask(prompt) }
        interrupt.begin(t); await t.value; interrupt.end()
    }

    if !opts.task.isEmpty {
        note("\n--- task: \(opts.task) ---\n")
        await turn(opts.task)
    } else {
        note("\ncode-buddy — interactive. Type a request; `quit`, Ctrl-D, or Ctrl-C at the prompt to exit.\n")
        while true {
            print(">> ", terminator: ""); fflush(stdout)
            guard let line = readLine() else { note(""); break }     // EOF / Ctrl-D
            let task = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if task.isEmpty { continue }
            if task == "quit" || task == "exit" { break }
            print(); await turn(task); print()
        }
    }

    sigint.cancel()
    session.cancel()                                                 // ← SDK
    await events.value
    note("\ncontext: \(session.contextBudget)")                      // ← SDK
}

await run()
```

**Tally**: of the file's 220 non-comment/non-blank lines, 31 touch the SDK directly (marked
above) — and that 31 is the *entire* model layer: pick providers, name routes, preflight/download,
make a session, stream it, watch `.events`, plus the seven ready-made Workspace `Tool`s and the
MCP add-server/tool-disable calls. Everything MLX-specific is a handful of lines (`MLXModelProvider` with its `pinnedRevisions:` /
`pinStore:` pin, `validate`, `download`, `effectivePin(for:)`, and the import); use `ClaudeModelProvider` from `LocalLMLabSDKClaude`
instead (a macOS-27 target — see `sdk-guide.md` §1a) and the rest of the file is unchanged.
`RouteName` is the only new type the caller names by hand. The REPL loop and Ctrl-C handling add
no SDK surface — one persistent `LocalLMLabSession` spans every turn, and `session.cancel()` /
Task cancellation is the whole cancel story.

### `Sources/CodeBuddy/ProcessTools.swift`

*95 lines of code (123 with comments) — host-owned tool code; none of it is SDK API.*

Not SDK code at all — this is the worked example of the **host-owned `Process` tool** pattern
that `sdk-guide.md` §7 calls out: the SDK deliberately does **not** ship shell/git/test-runner
tools (App Sandbox + Mac App Store can't run `Process`), so a Developer-ID CLI like this one
implements them itself, scoped to the workspace, with its own safety policy. Zero `// ← SDK`
marks — it's here to show the boundary, not a touchpoint.

```swift
import Foundation
import FoundationModels                    // only for the `Tool` / `@Generable` protocols

/// Runs `exe args` in `cwd`, capturing stdout+stderr, with a timeout and a truncation cap.
/// Cancellation-aware: if the calling turn is cancelled (Ctrl-C), the child gets SIGTERM
/// rather than being left to run orphaned.
func runProcess(_ exe: String, _ args: [String], cwd: URL, timeout: TimeInterval = 240) async -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    process.currentDirectoryURL = cwd
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() }
    catch { return "Failed to launch \(exe): \(error.localizedDescription)" }

    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    // Read+wait off-thread so task cancellation reaches us; on cancel, terminate the child
    // (which closes the pipe and unblocks the read).
    let data: Data = await withTaskCancellationHandler {
        await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: d)
            }
        }
    } onCancel: { if process.isRunning { process.terminate() } }
    deadline.cancel()

    var output = String(decoding: data, as: UTF8.self)
    let cap = 20_000
    if output.count > cap {
        output = String(output.prefix(cap)) + "\n…[truncated, \(output.count) chars total]"
    }
    let status = process.terminationStatus
    return output.isEmpty ? "(no output; exit \(status))" : "\(output)\n[exit \(status)]"
}

/// Read-only git. Mutating subcommands are refused — the host's policy, not the SDK's.
struct GitTool: Tool {
    let root: URL
    static let readOnlySubcommands: Set<String> = [
        "status", "diff", "log", "show", "branch", "blame", "ls-files", "ls-tree",
        "rev-parse", "describe", "remote", "tag", "shortlog", "grep", "cat-file", "reflog",
    ]
    @Generable struct Arguments {
        @Guide(description: "A read-only git subcommand with its args, e.g. \"status\", \"log --oneline -10\".")
        var command: String
    }
    let name = "git"
    var description: String {
        "Runs a read-only git command in the workspace. Allowed: \(Self.readOnlySubcommands.sorted().joined(separator: ", ")). Mutating commands are refused — make edits with editWorkspaceFile instead."
    }
    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()   // a tool call queued after a Ctrl-C never launches
        let parts = arguments.command
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard let sub = parts.first else { return "No git subcommand given." }
        guard Self.readOnlySubcommands.contains(sub) else {
            return "Refused: '\(sub)' is not an allowed read-only git subcommand."
        }
        return await runProcess("/usr/bin/git", parts, cwd: root)
    }
}

/// Runs the workspace's test command (host-configured — not inferred).
struct RunTestsTool: Tool {
    let root: URL
    let command: [String]                  // e.g. ["swift", "test"] or ["npm", "test", "--silent"]
    @Generable struct Arguments {
        @Guide(description: "Optional substring to pass to the test runner's filter, to run a subset.")
        var filter: String?
    }
    let name = "run_tests"
    var description: String {
        "Runs the project's test suite (`\(command.joined(separator: " "))`) in the workspace and returns the output."
    }
    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard let exe = command.first else { return "No test command configured." }
        var args = Array(command.dropFirst())
        if let filter = arguments.filter, !filter.isEmpty { args += ["--filter", filter] }
        let resolved = exe.hasPrefix("/") ? exe : (which(exe) ?? "/usr/bin/env")
        let finalArgs = resolved == "/usr/bin/env" ? [exe] + args : args
        return await runProcess(resolved, finalArgs, cwd: root)
    }
    private func which(_ name: String) -> String? {
        for dir in ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
```

**Tally**: zero SDK lines. `GitTool` / `RunTestsTool` conform to FoundationModels' `Tool` exactly
like Core's own tools do, and get merged into the session by the same `makeSession(tools:)` call —
the SDK neither knows nor cares that these ones shell out. The safety policy (read-only git
allow-list, workspace-scoped `cwd`, output cap, timeout) is entirely the host's to write — as is
the cancellation behaviour: `withTaskCancellationHandler` + `Task.checkCancellation()` are what
make Ctrl-C in the REPL terminate a running `swift test` instead of orphaning it.

## `examples/repo-qa-local`

*`Sources/RepoQALocal/main.swift` — 96 lines of code (134 with comments) — ~30 more than `repo-qa`, all of it the model layer.*

The **minimal** model-layer example: [`repo-qa`](#examplesrepo-qa) above,
with the ~30 lines that swap Apple's on-device model for an open-weight MLX model you download and
run locally — including the **pin**: the default model is tied to the exact Hugging Face commit the example
was tried against (`pinnedRevisions`), and a model you pick with `--model` is pinned on first download
(`MLXFilePinStore`, trust on first use), so a later fresh download never silently fetches whatever `main`
has become. The Deepwiki / `MCPTool` half is a verbatim copy of `repo-qa`'s — diff the two to see
exactly what adopting the model layer costs. One of several examples linking
`LocalLMLabSDKInference` (`// ← SDK (Inference)`); `// ← SDK` is Core as elsewhere.

```swift
// repo-qa-local — repo-qa, but the answer comes from an open-weight model you download and run
// locally (via MLX) instead of Apple's on-device model. The Deepwiki / MCPTool half is a
// verbatim copy of repo-qa's; the only difference is the ~20 lines that set up the 1.0 model
// layer and swap `LanguageModelSession(tools:)` for `lab.makeSession(route:tools:)`.
//
//   swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
//   swift run RepoQALocal facebook/react                        # default question
//   swift run RepoQALocal --model mlx-community/Qwen2.5-3B-Instruct-4bit apple/swift-nio "..."
//   swift run RepoQALocal --apple anthropics/claude-code "..."  # route to Apple's on-device model instead
//
// First run downloads the model (progress on stderr). Default: mlx-community/Qwen3-8B-4bit —
// see docs/tested-models.md for which open-weight models tool-call reliably.

import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKInference                                         // ← SDK (Inference)

func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

@available(macOS 26.0, *)
@MainActor
func run() async {
    // --- args: [--model <repo>] [--apple] <owner/repo> [question...] ---
    var modelRepo = "mlx-community/Qwen3-8B-4bit"
    var useApple = false
    var rest: [String] = []
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--model": if let v = it.next() { modelRepo = v }
        case "--apple": useApple = true
        default: rest.append(a)
        }
    }
    guard let repoName = rest.first, !repoName.isEmpty else {
        note("""
        usage: swift run RepoQALocal [--model <hf-repo>] [--apple] <owner/repo> [question]
        example: swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
        """)
        exit(1)
    }
    let question = rest.dropFirst().joined(separator: " ")
    let effectiveQuestion = question.isEmpty ? "What does this repository do, in a couple sentences?" : question

    // --- the model layer: one MLX provider, Apple's on-device model as an alternative, one route ---
    // Pin the default model to the commit this example was tried against, so a fresh download never
    // silently picks up whatever `main` has become. A model chosen with --model is pinned to the
    // version you first download instead (trust on first use). To change the default, review the
    // new version, then update the repo and its commit together.
    let shippedPins = ["mlx-community/Qwen3-8B-4bit": "545dc4251c05440727734bcd94334791f6ab0192"]
    let mlx = MLXModelProvider(residentModelLimit: 1, pinnedRevisions: shippedPins, pinStore: MLXFilePinStore())  // ← SDK (Inference)
    let lab = LocalLMLab(configuration: .init(providers: [mlx, SystemModelProvider()]))   // ← SDK
    let modelID = useApple ? ModelID.system : ModelID(scheme: "mlx", rest: modelRepo)!    // ← SDK
    lab.models.route(.local, to: modelID)                            // ← SDK
    note("model: \(modelID)  ·  SDK \(LocalLMLabSDKVersion.current)")   // ← SDK

    // Preflight + download the MLX weights on first run. (Nothing to download for `--apple`.)
    if !useApple, case .notDownloaded = lab.models.availability(for: modelID) {   // ← SDK
        if let pre = try? await mlx.validate(modelRepo), !pre.passed {            // ← SDK (Inference)
            note("pre-flight failed (\(pre.failedStage?.rawValue ?? "?")): \(pre.detail ?? "")")
            exit(1)
        }
        note("downloading \(modelRepo)…")
        do {
            for try await event in mlx.download(modelRepo) {         // ← SDK (Inference)
                if case .progress(_, _, let f) = event {
                    FileHandle.standardError.write(Data("\u{1B}[2K\r  \(Int(f * 100))%".utf8))
                }
            }
            note("\u{1B}[2K\r  done")
        } catch {
            note("download failed: \(error)"); exit(1)
        }
    }
    if !useApple, let pin = mlx.effectivePin(for: modelRepo) {    // ← SDK (Inference)
        note("pinned to \(pin.revision.prefix(7)) (\(pin.source == .shipped ? "shipped with this example" : "first download"))")
    }

    // --- everything below is repo-qa, unchanged ---

    let manager = MCPServerManager()                                 // ← SDK
    note("Connecting to Deepwiki…")
    let connectResult = await manager.addServer(                     // ← SDK
        url: URL(string: "https://mcp.deepwiki.com/mcp")!,
        displayName: "Deepwiki"
    )
    guard case .success(let state) = connectResult else {
        note("Could not connect to Deepwiki: \(connectResult)"); return
    }

    // Build a Tool for each of Deepwiki's tools from its own live schema. `read_wiki_contents` is
    // skipped by name: it dumps a repo's entire wiki unscoped (~165K tokens for anthropics/
    // claude-code in one call), which `MCPTool` can't know from the schema — that curation is the
    // app's job (see docs/sdk-guide.md §3). A tool whose schema doesn't build is skipped, not fatal.
    var tools: [any Tool] = []
    for descriptor in state.tools {
        guard descriptor.name != "read_wiki_contents" else {
            note("Skipping \(descriptor.name): excluded by this example.")
            continue
        }
        do { tools.append(try MCPTool(descriptor: descriptor, manager: manager)) }   // ← SDK (Path A)
        catch { note("Skipping \(descriptor.name): \(error)") }
    }
    guard !tools.isEmpty else { note("Deepwiki didn't offer any usable tools."); return }
    note("Built \(tools.count) tool(s) from Deepwiki's live schema: \(tools.map(\.name).joined(separator: ", "))")

    // The one line that changes from repo-qa: lab.makeSession(route:tools:) instead of
    // LanguageModelSession(tools:) — same FoundationModels session underneath, just backed by
    // whichever model the route points at.
    let instructions = "You answer questions about GitHub repositories using the documentation tools available to you. Always ground your answer in what the tools actually return — don't answer from general knowledge if a tool call would give a more specific, current answer."
    let session: LocalLMLabSession                                   // ← SDK
    do {
        session = try lab.makeSession(route: .local, tools: tools, instructions: instructions, includeMCPTools: false)   // ← SDK
    } catch {
        note("makeSession failed: \(error)"); exit(1)
    }

    let prompt = "Regarding the GitHub repository \"\(repoName)\": \(effectiveQuestion)"
    note("\nAsking: \(prompt)\n")
    do {
        let response = try await session.languageModelSession.respond(to: prompt)   // ← SDK
        print(response.content)
    } catch {
        note("Error: \(await GenerationErrorDescription.describe(error))")   // ← SDK
    }
    session.cancel()                                                 // ← SDK
}

if #available(macOS 26.0, *) {
    await run()
} else {
    print("Requires macOS 26 or later.")
}
```

**Tally**: of the file's 96 non-comment/non-blank lines, 19 touch the SDK directly (marked above)
— and everything below the `--- everything below is repo-qa, unchanged ---` marker is
`repo-qa`'s code (its long comments condensed) except the one `lab.makeSession` line. The model layer itself is
~8 lines (`MLXModelProvider` / `LocalLMLab` / `ModelID` / `route` / `availability` / `validate` /
`download`, plus the diagnostic `note(...)` line that reads `LocalLMLabSDKVersion.current`), and pinning adds
three more: the `shippedPins` dictionary and `pinStore:` argument on `MLXModelProvider`, and an
`effectivePin(for:)` call that reports which version is in use and where the pin came from (`.shipped` vs `.captured`);
`--apple` proves the same route can point at Apple's on-device model with no other change.

## `examples/workspace-buddy-local`

*`Sources/WorkspaceBuddyLocal/WorkspaceBuddyLocalApp.swift` — 255 lines of code (332 with comments) — the verbatim `FolderAccess` enum and the plain-SwiftUI
UI are elided below.*

[`workspace-buddy`](#examplesworkspace-buddy) above —
same folder-picker, same security-scoped bookmark, same `WorkspaceTools` — but the model is an
open-weight MLX model routed through the 1.0 model layer. It is the one example that runs the
model layer **inside App Sandbox**, so it also needs `com.apple.security.network.client` (to fetch
the weights on first run) on top of `workspace-buddy`'s `files.user-selected.read-write`; the
model downloads into this app's own sandbox container. The model is **pinned** to the exact Hugging Face
commit the app was tried against (`pinnedRevisions:`), so a fresh download always gets those bytes rather
than whatever `main` has become. One of several examples linking
`LocalLMLabSDKInference`. The `FolderAccess` enum is verbatim from `workspace-buddy` and is
elided here — see that section above.

Where `workspace-buddy` awaits `respond(to:)` whole behind a spinner, this one **streams**: an
8B model on the GPU is slow enough that a bare spinner reads as stuck, so the answer renders as
it generates (`streamResponse`) and a `session.events` loop names the tool running during each
pause.

```swift
import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKInference                                         // ← SDK (Inference)
import SwiftUI

// The model this app routes to. Any MLX-format Hugging Face repo — see docs/tested-models.md.
let workspaceModelRepo = "mlx-community/Qwen3-8B-4bit"
// The exact commit of that repo this app was built and tried against. A Hugging Face repo's owner can
// change what `main` points to at any time; pinning means a fresh download (first run, or after the
// user clears the cache) always gets these bytes, never whatever `main` is today. To change the
// model, review the new version, then update both lines.
let workspaceModelRevision = "545dc4251c05440727734bcd94334791f6ab0192"

// MARK: - FolderAccess { pickFolder / resolveBookmarkedFolder / withFolderAccessAsync }
//   — verbatim from workspace-buddy (docs/sdk-guide.md §8); see that section above. Elided here.

// MARK: - View model

@available(macOS 26.0, *)
@MainActor
final class WorkspaceBuddyLocalModel: ObservableObject {
    enum State {
        case idle
        case downloadingModel(Double)   // 0…1
        case working(String)            // the answer so far — "" until the first token
        case ready(String)
        case failed(String)
    }

    @Published private(set) var folderURL: URL?
    @Published private(set) var state: State = .idle
    @Published private(set) var activity: String?   // which tool is running during a pause; nil = generating

    // The model layer: an MLX provider (one model resident at a time), Apple's on-device model
    // kept as a fallback, and one named route pointing at the MLX model.
    private let mlx = MLXModelProvider(                               // ← SDK (Inference)
        residentModelLimit: 1,
        pinnedRevisions: [workspaceModelRepo: workspaceModelRevision])
    private lazy var lab = LocalLMLab(configuration: .init(providers: [mlx, SystemModelProvider()]))   // ← SDK
    private lazy var modelID = ModelID(scheme: "mlx", rest: workspaceModelRepo)!   // ← SDK

    init() {
        folderURL = FolderAccess.resolveBookmarkedFolder()
        lab.models.route(.local, to: modelID)                        // ← SDK
    }

    func chooseFolder() {
        guard let url = FolderAccess.pickFolder() else { return }
        folderURL = url
    }

    func submit(_ request: String) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch state {
        case .working, .downloadingModel: return
        default: break
        }
        Task { await run(trimmed) }
    }

    // Tool name → a phrase for the activity line. Not SDK — just presentation.
    private static func activityLabel(for toolName: String) -> String {
        switch toolName {
        case "listWorkspaceFiles": return "Listing the folder…"
        case "readWorkspaceFile":  return "Reading a file…"
        case "editWorkspaceFile":  return "Editing a file…"
        case "writeWorkspaceFile": return "Writing a new file…"
        default:                   return "Working…"
        }
    }

    private func run(_ request: String) async {
        // 1. Download the model on first use (streams progress into the UI).
        if case .notDownloaded = lab.models.availability(for: modelID) {   // ← SDK
            state = .downloadingModel(0)
            if let pre = try? await mlx.validate(workspaceModelRepo), !pre.passed {   // ← SDK (Inference)
                state = .failed("Model pre-flight failed (\(pre.failedStage?.rawValue ?? "?")): \(pre.detail ?? "")")
                return
            }
            do {
                for try await event in mlx.download(workspaceModelRepo) {   // ← SDK (Inference)
                    if case .progress(_, _, let fraction) = event {
                        state = .downloadingModel(fraction)
                    }
                }
            } catch {
                state = .failed("Model download failed: \(error.localizedDescription)")
                return
            }
        }

        // 2. Run the request. Same as workspace-buddy up to makeSession; from there it streams.
        state = .working("")
        activity = nil
        let result: String? = await FolderAccess.withFolderAccessAsync { root in
            let tools: [any Tool] = [
                ListWorkspaceFilesTool(root: root),                  // ← SDK (Path A)
                ReadWorkspaceFileTool(root: root),                   // ← SDK (Path A)
                WriteWorkspaceFileTool(root: root),                  // ← SDK (Path A)
                EditWorkspaceFileTool(root: root),                   // ← SDK (Path A)
            ]
            let instructions = """
                You are a coding assistant working in a single project folder. Use \
                listWorkspaceFiles to see what's there and readWorkspaceFile before editing \
                anything — never guess a file's contents. Prefer editWorkspaceFile (a targeted \
                find-and-replace) over writeWorkspaceFile for changes to files that already \
                exist; writeWorkspaceFile only creates brand-new files and fails if the file is \
                already there. Explain what you changed and why, briefly.
                """
            do {
                let session = try self.lab.makeSession(              // ← SDK
                    route: .local, tools: tools, instructions: instructions, includeMCPTools: false
                )

                // .events is the side-channel around generation — here, the tool running during
                // a pause. Token text stays on streamResponse below.
                let events = Task { @MainActor in
                    for await event in session.events {             // ← SDK
                        switch event {
                        case .toolCallStarted(_, let name, _): self.activity = Self.activityLabel(for: name)
                        case .toolCallFinished:                self.activity = nil
                        default: break
                        }
                    }
                }
                defer { events.cancel() }

                // Each snapshot is the whole answer so far. Usually append-only — but a reasoning
                // model drops its <think> block once the answer starts, and the snapshot can reset
                // across a tool call, so show the latest non-empty one rather than diffing.
                // (code-buddy does the careful append-only version — stdout can't un-print.)
                var text = ""
                for try await snapshot in session.languageModelSession.streamResponse(to: request) {   // ← SDK
                    guard !snapshot.content.isEmpty else { continue }
                    text = snapshot.content
                    self.activity = nil
                    self.state = .working(text)
                }
                return text
            } catch {
                return "Error: \(await GenerationErrorDescription.describe(error))"   // ← SDK
            }
        }

        activity = nil
        guard let result else {
            state = .failed("Could not access the workspace folder — try choosing it again.")
            return
        }
        state = .ready(result)
    }
}

// MARK: - UI (ordinary SwiftUI — model-repo label, folder path, a text field, a Go button, a
// download-progress bar, and a bottom-pinned ScrollView that shows `state`'s streaming text +
// the `activity` line. No SDK touchpoints; elided.)

@available(macOS 26.0, *)
@main
struct WorkspaceBuddyLocalApp: App {
    @StateObject private var model = WorkspaceBuddyLocalModel()
    var body: some Scene {
        WindowGroup { ContentView(model: model) }
            .windowResizability(.contentMinSize)
    }
}
```

**Tally**: of ~110 lines of actual code (the verbatim `FolderAccess` enum and the plain-SwiftUI
UI section both elided), 17 touch the SDK (marked above). Against `workspace-buddy`'s five (four
Tool instantiations + one error formatter), the delta is the model layer (provider/lab/route setup
and the `pinnedRevisions:` pin, the first-run `availability` check, the `validate` + `download` progress loop) plus the streaming
turn — `session.events` for the tool-activity line and `streamResponse` instead of `respond`.
The `makeSession` call and the four `WorkspaceTools` are identical to `workspace-buddy`'s — the
sandbox changes nothing in the code, only the entitlements.

## `examples/os-matrix`

*`Sources/OSMatrix/main.swift` — 74 lines of code (97 with comments) — the whole file is shown below.*

One `.macOS("26.0")` CLI that runs unchanged on macOS 26 and macOS 27 — no source `#if`, a single
`#available` block at provider registration. Everything after that block is identical code on both
OSes; the macOS-27-only model families (`PCCModelProvider`, open-weight via `MLXModelProvider`) are
simply absent on 26, and `ModelAvailability.requiresOS` / `lab.models.schemesRequiringNewerOS` are
what a picker reads to show them as disabled rows. See
[`sdk-guide.md` §1a](sdk-guide.md#1a-targeting-macos-26-and-macos-27-from-one-build). It links
`LocalLMLabSDKInference` for the MLX types but never forces a 27 deployment target — the
`#available` gate is the whole story.

```swift
import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKInference                                         // ← SDK (Inference)

// See Package.swift / README.md for the four scenarios. Run on macOS 26 and macOS 27 — same
// binary, no source `#if`, one `#available` check at provider registration.
//
//   swift run OSMatrix
//   swift run OSMatrix --download mlx-community/Qwen3-4B-4bit   # macOS 27 only; ~2–5 GB

@MainActor
func run() async throws {
    let args = CommandLine.arguments
    let downloadRepo: String? = args.firstIndex(of: "--download").flatMap { i in
        i + 1 < args.count ? args[i + 1] : nil
    }

    // ── Scenario 4: register what the running OS supports ──────────────────────────────────
    // SystemModelProvider works on macOS 26 and 27. The rest need macOS 27, so they go in one
    // #available block. Everything AFTER this line is identical on both OSes.
    var providers: [any ModelProvider] = [SystemModelProvider()]      // ← SDK
    if #available(macOS 27, *) {
        providers.append(PCCModelProvider())                          // ← SDK
        providers.append(MLXModelProvider())                          // ← SDK (Inference)
    }
    let lab = LocalLMLab(configuration: .init(providers: providers))  // ← SDK
    lab.models.route("chat", to: .system)                             // ← SDK

    // ── Model availability table ──────────────────────────────────────────────────────────
    let v = ProcessInfo.processInfo.operatingSystemVersion
    print("Running on macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\n")
    print("Model families:")
    for id in [ModelID.system, .pcc, ModelID("claude:sonnet5")!,      // ← SDK
               ModelID(scheme: "mlx", rest: "mlx-community/Qwen3-4B-4bit")!] {
        let name = id.rawValue.padding(toLength: 42, withPad: " ", startingAt: 0)
        print("  \(name) \(describe(lab.models.availability(for: id)))")   // ← SDK
    }
    if !lab.models.schemesRequiringNewerOS.isEmpty {                   // ← SDK
        print("\n  (\(lab.models.schemesRequiringNewerOS.joined(separator: ", ")) need macOS 27 — a picker shows these as disabled rows)")
    }

    // ── Scenario 2: `--download` — a feature that only exists on macOS 27 ──────────────────
    if let repo = downloadRepo {
        guard #available(macOS 27, *), !lab.models.downloadableProviders.isEmpty else {   // ← SDK
            print("\n--download needs macOS 27 (open-weight models run via MLX, which is macOS 27+).")
            return
        }
        print("\nDownloading \(repo) from Hugging Face — fetches the weights (typically 2–5 GB)…")
        let installed = try await lab.models.startDownload(repo)   // ← SDK (resolves once the weights are on disk)
        let size = installed.sizeBytes.map { " (\($0 / 1_000_000) MB)" } ?? ""
        print("Done: \(installed.id.rawValue)\(size). It's now .available — route a session to it:")
        print("  lab.models.route(\"chat\", to: ModelID(\"\(installed.id.rawValue)\")!)")
        print("  let session = try lab.makeSession(route: \"chat\")")
        return
    }

    // ── Scenario 3: connector tools that work on both OSes ─────────────────────────────────
    let tools: [any Tool] = [ClockTool(), WeatherTool()]              // ← SDK

    // ── Scenario 1: the same call, identical on 26 and 27 ──────────────────────────────────
    let session = try lab.makeSession(route: "chat", tools: tools,    // ← SDK
        instructions: "You have getCurrentTime and getWeather tools. Use them; be concise.")
    print("\nAsking the on-device model (with tools)…")
    let answer = try await session.respond(to: "What time is it, and what's the weather in Tokyo?")   // ← SDK
    print("→ \(answer)")

    // ── Scenario 2 again: the hint, when --download wasn't passed ──────────────────────────
    if #available(macOS 27, *), !lab.models.downloadableProviders.isEmpty {   // ← SDK
        print("")
        print("Open-weight (MLX) models are available on macOS 27. Download and run one with:")
        print("  swift run OSMatrix --download mlx-community/Qwen3-4B-4bit")
        print("In code that's `try await lab.models.startDownload(\"<hugging-face-repo-id>\")` — an async call your app makes (e.g. from a \"Download\" button). There is no CLI for it in the SDK; `lab.models.downloads` is the observable a picker binds to for a progress bar.")
    } else {
        print("\nOpen-weight (MLX) models need macOS 27 — unavailable here.")
    }
}

func describe(_ a: ModelAvailability) -> String {                     // ← SDK (type)
    switch a {
    case .available: return "available"
    case .notDownloaded: return "not downloaded"
    case .needsCredential: return "needs credential"
    case .unavailable(let kind, let detail):
        if case .requiresOS(let os) = kind { return "requires \(os)" }   // ← SDK (.requiresOS)
        return "unavailable — \(detail)"
    @unknown default:
        return "unknown"                                              // non-frozen — see sdk-guide §9
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
```

**Tally**: of the file's 74 non-comment/non-blank lines, 18 touch the SDK directly (marked above)
— and every one of the OS-conditional lines is inside the single `if #available(macOS 27, *)`
block at the top (or, for the download flow, a second `#available` check that reads the same
providers). `describe(_:)` is a plain `switch` over `ModelAvailability`; `.requiresOS` is the one
case a 26-aware app has to handle that a 27-only app never sees. No `#if canImport` anywhere —
`LocalLMLabSDKInference` is linked unconditionally and its 27-only providers just aren't appended
on 26. See [`os-matrix`'s README](../examples/os-matrix/#run) for real output from both OSes —
the macOS 27 output there was captured live on this machine; the macOS 26 output wasn't
independently re-verified in this pass.

## `examples/model-switch`

*283 lines of code across the app's three files — `AppModel.swift`, `ProviderGlue.swift`, and
`ModelSwitchApp.swift` (all below).*

The **online / remote providers** example (`sdk-guide.md`
[§6b](sdk-guide.md#6b-online-providers--gpt-claude-online-openrouter-locallmlabsdkremote)): a chat
window that talks to Apple's on-device model, PCC, Claude-via-Foundation-Models, and any number of
HTTP providers (GPT, Claude online, OpenRouter, OpenAI-compatible) from one `lab.makeSession`
call, with provider-run web search. This is the only example linking a **fourth** binary,
`LocalLMLabSDKRemote.xcframework` — lines that touch it are marked `// ← SDK (Remote)`. It also
uses `Components` for the whole settings panel (`// ← Components`); `Components` itself does *not*
link `Remote`, so the two meet through the `RemoteProviderDraft` / `ProviderTestOutcome` data
types and the `onSave` / `onRemove` / `onTest` closures — see `ModelSwitchApp.swift` and
`ProviderGlue.swift` below.

### `Sources/ModelSwitch/AppModel.swift`

*146 lines of code (180 with comments).*

```swift
import Foundation
import Observation
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKComponents                                        // ← Components
import LocalLMLabSDKRemote                                            // ← SDK (Remote)

@available(macOS 27, *)
@MainActor
@Observable
final class AppModel {
    let lab: LocalLMLab                                               // ← SDK (type)

    // Online-provider drafts, persisted by the app. Demo persistence only — a real app stores
    // the API keys in the Keychain, not UserDefaults.
    var providers: [RemoteProviderDraft] = [] {                       // ← Components (type)
        didSet { persist() }
    }

    var selectedModel: ModelID = .system                             // ← SDK (type)

    var transcript: [ChatLine] = []
    var input: String = ""
    var webSearchThisTurn = false
    var isResponding = false
    var lastError: String?

    struct ChatLine: Identifiable {
        let id = UUID()
        var role: Role
        var text: String
        var searches: [String] = []
        var citations: [Citation] = []                                // ← SDK (type)
        enum Role { case user, assistant }
    }

    init() {
        // Start with just Apple's on-device provider; every HTTP provider is added at runtime
        // by restore() / applyDraft() via lab.models.replace(_:).
        lab = LocalLMLab(configuration: .init(providers: [SystemModelProvider()]))   // ← SDK
        restore()
    }

    var availableModels: [ModelID] {
        lab.models.knownModels.filter { lab.models.availability(for: $0).isAvailable }   // ← SDK
    }

    // MARK: provider config

    func applyDraft(_ draft: RemoteProviderDraft) {
        guard let idx = providers.firstIndex(where: { $0.scheme == draft.scheme }) else { return }
        var updated = draft
        if let config = draft.makeConfig() {                          // makeConfig() → RemoteProviderConfig, see ProviderGlue.swift
            lab.models.replace(RemoteModelProvider(config))           // ← SDK (Remote)  — add/replace at runtime
            updated.configured = true
            updated.statusText = "\(config.models.count) model(s) available."
        } else {
            lab.models.removeProvider(scheme: draft.scheme)           // ← SDK
            updated.configured = false
            updated.statusText = "Enter an API key to enable."
        }
        providers[idx] = updated
    }

    func removeDraft(_ draft: RemoteProviderDraft) {
        lab.models.removeProvider(scheme: draft.scheme)               // ← SDK
        if selectedModel.scheme == draft.scheme { selectedModel = .system }
    }

    // "Test connection" — in-process here since this example links Remote directly. A host split
    // across a macOS 26 app plus a macOS 27 helper would round-trip this call through the helper instead.
    // Every configured model, not just the first — a valid key doesn't mean a second model id the
    // user just typed is real.
    func testDraft(_ draft: RemoteProviderDraft) async -> ProviderTestOutcome {   // ← Components (type)
        guard let config = draft.makeConfig(), !config.models.isEmpty else {
            return .unableToRun("Add a model id and an API key first.")
        }
        let provider = RemoteModelProvider(config)                    // ← SDK (Remote)
        var results: [ProviderTestOutcome.ModelResult] = []
        for model in config.models {
            guard let modelID = ModelID(scheme: config.scheme, rest: model.id) else {   // ← SDK
                results.append(.init(modelId: model.id, ok: false, detail: "isn't a valid model id."))
                continue
            }
            let availability = await provider.probe(for: modelID)     // ← SDK (Remote)  — zero-token key/model/reachability check
            let detail: String
            switch availability {
            case .available: detail = "Available."
            case .needsCredential: detail = "The API key was rejected."
            case .unavailable(_, let d): detail = d
            default: detail = "Unknown status."
            }
            results.append(.init(modelId: model.id, ok: availability.isAvailable, detail: detail))
        }
        return ProviderTestOutcome(results: results)
    }

    // MARK: chat

    func send() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }
        input = ""
        lastError = nil
        transcript.append(.init(role: .user, text: prompt))
        var line = ChatLine(role: .assistant, text: "")
        transcript.append(line)
        let lineID = line.id
        isResponding = true
        defer { isResponding = false }

        do {
            lab.models.route("chat", to: selectedModel)               // ← SDK  — one route, repointed per turn
            let session = try lab.makeSession(                        // ← SDK
                route: "chat",
                instructions: "You are a helpful assistant. Be concise.",
                options: .init(webSearch: webSearchThisTurn))         // ← SDK (SessionOptions) — provider runs the search

            let events = Task { [weak self] in
                for await event in session.events {                   // ← SDK
                    guard let self else { return }
                    if case .serverToolCall(let a) = event, case .webSearch(let q, _) = a.kind {   // ← SDK
                        self.update(lineID) { $0.searches.append(contentsOf: q) }
                    }
                }
            }

            let answer = try await session.respond(to: prompt)       // ← SDK
            events.cancel()
            line.text = answer
            update(lineID) { $0.text = answer; $0.citations = session.citations }   // ← SDK  — web-search sources
        } catch {
            let message = (error as? LocalLMLabError)?.errorDescription ?? "\(error)"   // ← SDK
            lastError = message
            update(lineID) { $0.text = "⚠️ \(message)" }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout ChatLine) -> Void) {
        guard let idx = transcript.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transcript[idx])
    }

    // MARK: persistence (demo only — real apps use the Keychain for keys)

    private static let key = "modelswitch.providers.v1"

    private func persist() {
        let plain = providers.map {
            ["scheme": $0.scheme, "displayName": $0.displayName, "kind": $0.kind.rawValue,
             "baseURL": $0.baseURL, "apiKey": $0.apiKey,
             "models": $0.models.joined(separator: "\n"),
             "webSearchSupported": String($0.webSearchSupported),
             "webSearchEnabled": String($0.webSearchEnabled),
             "maxSearches": String($0.maxSearches)]
        }
        UserDefaults.standard.set(plain, forKey: Self.key)
    }

    private func restore() {
        let rows = UserDefaults.standard.array(forKey: Self.key) as? [[String: String]] ?? []
        providers = rows.compactMap { r in
            guard let scheme = r["scheme"], let kindRaw = r["kind"],
                  let kind = RemoteProviderKind(rawValue: kindRaw) else { return nil }   // ← Components (type)
            var d = RemoteProviderDraft(
                scheme: scheme, displayName: r["displayName"] ?? scheme, kind: kind,
                baseURL: r["baseURL"] ?? "", apiKey: r["apiKey"] ?? "",
                models: (r["models"] ?? "").split(whereSeparator: \.isNewline).map(String.init),
                webSearchSupported: r["webSearchSupported"] == "true",
                webSearchEnabled: r["webSearchEnabled"] == "true",
                maxSearches: Int(r["maxSearches"] ?? "5") ?? 5)
            if let config = d.makeConfig() {
                lab.models.replace(RemoteModelProvider(config))       // ← SDK (Remote)
                d.configured = true
            }
            return d
        }
    }
}
```

### `Sources/ModelSwitch/ProviderGlue.swift`

*35 lines of code — the small provider-config glue `AppModel.swift` and `ModelSwitchApp.swift`
both call into.*

```swift
// examples/model-switch/Sources/ModelSwitch/ProviderGlue.swift
import Foundation
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKComponents                                        // ← Components
import LocalLMLabSDKRemote                                            // ← SDK (Remote)

// RemoteProviderDraft (Components' UI shape) → RemoteProviderConfig (Remote's model-layer shape).
// The SDK ships no default model ids — an empty model list is a real, intentional state (the
// user removed every row), so makeConfig() must round-trip it as zero models, never resurrect
// a default.
extension RemoteProviderDraft {
    func makeConfig() -> RemoteProviderConfig? {                      // ← SDK (Remote) (type)
        let models = self.models.map { RemoteModel(id: $0) }          // ← SDK (Remote)
        var config: RemoteProviderConfig

        switch kind {
        case .openAIChat:
            guard !apiKey.isEmpty else { return nil }
            config = .openAI(apiKey: apiKey, models: models)          // ← SDK (Remote) (preset)
        case .openAIResponses:
            guard !apiKey.isEmpty else { return nil }
            config = .openAIResponses(apiKey: apiKey, models: models) // ← SDK (Remote) (preset)
        case .anthropic:
            guard !apiKey.isEmpty else { return nil }
            config = .anthropic(apiKey: apiKey, models: models)       // ← SDK (Remote) (preset)
        case .openRouter:
            guard !apiKey.isEmpty else { return nil }
            config = .openRouter(apiKey: apiKey, models: models)      // ← SDK (Remote) (preset)
        case .openAICompatible:
            guard let url = URL(string: baseURL), !baseURL.isEmpty else { return nil }
            config = .openAICompatible(                               // ← SDK (Remote) (escape hatch)
                scheme: scheme, displayName: displayName, baseURL: url,
                apiKey: apiKey.isEmpty ? nil : apiKey, models: models)
        }

        // Carry the panel's web-search checkbox into the provider defaults.
        if webSearchSupported {
            config.capabilities.insert(.webSearch)                    // ← SDK (Remote)
            config.defaultOptions.webSearch = webSearchEnabled        // ← SDK (Remote)
            config.defaultOptions.webSearchMaxUses = maxSearches      // ← SDK (Remote)
        }
        return config
    }
}
```

**Tally**: the whole model layer here is `lab.models.replace(_:)` / `.removeProvider(scheme:)` to
reconfigure at runtime, `.route` + `makeSession(options:)` per turn, and `session.events` /
`session.citations` for the web-search side-channel. Everything provider-specific — dialects,
base URLs, auth, presets — is data inside `RemoteProviderConfig`, built once in the 35-line
`ProviderGlue.swift`. `probe(for:)` is the one call that hits the network without spending a
token, and it's what the settings panel's **Test connection** button runs.

### `Sources/ModelSwitch/ModelSwitchApp.swift`

*102 lines of code (112 with comments) — the `ChatView` UI is elided below.*

The `Components` half: `AIModelsSettingsView` is the entire "AI Models" settings panel — add a
provider, key field, per-model rows, a web-search toggle + max-searches stepper, and a **Test
connection** button. The host supplies four things and writes no settings UI of its own.

```swift
import SwiftUI
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKComponents                                        // ← Components

@main
@available(macOS 27, *)
struct ModelSwitchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Model Switch") {
            ChatView(model: model)                                    // ordinary SwiftUI — model picker, transcript, composer; elided
                .frame(minWidth: 520, minHeight: 460)
        }
        Settings {
            SettingsScreen(model: model)
                .frame(width: 560, height: 620)
        }
    }
}

@available(macOS 27, *)
private struct SettingsScreen: View {
    @Bindable var model: AppModel
    var body: some View {
        AIModelsSettingsView(                                         // ← Components  — the whole panel
            registry: model.lab.models,                               // ← SDK  — built-in models come from here
            providers: $model.providers,
            onSave:   { model.applyDraft($0) },                       // draft → lab.models.replace(_:)
            onRemove: { model.removeDraft($0) },                      // draft → lab.models.removeProvider(scheme:)
            onTest:   { await model.testDraft($0) })                  // draft → provider.probe(for:) per model
    }
}
```

**Tally**: three lines. `AIModelsSettingsView(registry:providers:onSave:onRemove:onTest:)` is the
whole settings surface; the `ChatView` (model `Picker` bound to `model.availableModels`, a
web-search `Toggle`, the transcript) is ordinary SwiftUI and is elided here. The closures are the
seam that keeps `Components` free of any dependency on `Remote`.

## `examples/security-demo`

*~250 lines of code across 6 files; the SDK surface is two of them — `DemoSecurity.swift` and `AppModel.swift` (both below). The three view files (`SecurityPane`, `RunPane`, `ContentView`) and `SecurityDemoApp` are ordinary SwiftUI, elided; `Keychain.swift` is ~30 lines of `SecItem*` with no SDK in it (a credential belongs in the Keychain, not `UserDefaults` — that's the only reason it exists).*

### `Sources/SecurityDemo/DemoSecurity.swift`

This file is the whole idea: a "Security panel" is **two SDK levers**, and nothing else. `DemoSecurity` is the observable UI state; `DemoPolicy` is the immutable snapshot a run takes so editing the panel mid-turn can't change a session already built (the same split `SecurityPolicy` uses in LocalLM Lab).

```swift
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import Observation

enum ConnectorLevel: String, CaseIterable, Identifiable, Sendable {
    case readOnly = "Read-only"
    case changes  = "Changes"
    case full     = "Full"
    var id: String { rawValue }

    // A connector "level" is just a ToolImpact ceiling.
    var maxImpact: ToolImpact {                                       // ← SDK  — .read < .mutate < .destructive
        switch self {
        case .readOnly: return .read
        case .changes:  return .mutate
        case .full:     return .destructive
        }
    }
}

@MainActor @Observable
final class DemoSecurity {
    var calendarLevel: ConnectorLevel = .changes
    var calendarConfirm = true
    var todoistConfirm  = true

    func snapshot() -> DemoPolicy {
        DemoPolicy(calendarLevel: calendarLevel, calendarConfirm: calendarConfirm, todoistConfirm: todoistConfirm)
    }
}

struct DemoPolicy: Sendable {
    var calendarLevel: ConnectorLevel
    var calendarConfirm: Bool
    var todoistConfirm: Bool

    // No confirmation wanted anywhere ⇒ makeSession gets no authorizer, runs like a bare session.
    var wantsConfirmation: Bool { calendarConfirm || todoistConfirm }

    // Lever 1 — selection. Drop every Calendar tool above the level's ceiling.
    func limitedCalendarTools(_ tools: [any Tool]) -> [any Tool] {
        tools.limited(toMaxImpact: calendarLevel.maxImpact)           // ← SDK  — Sequence<any Tool> extension
    }

    // Lever 2 — invocation. Per-call: reads always run; a mutating/destructive call is
    // confirmed when its connector's toggle is on.
    func requirement(for call: PendingToolCall) -> ConfirmingToolAuthorizer.Requirement {   // ← SDK (types)
        guard call.impact >= .mutate else { return .allow }           // ← SDK  — call.impact
        switch call.origin {                                          // ← SDK  — .host vs .mcp
        case .host: return calendarConfirm ? .confirm : .allow
        case .mcp:  return todoistConfirm  ? .confirm : .allow
        @unknown default: return .confirm
        }
    }
}
```

### `Sources/SecurityDemo/AppModel.swift`

*130 lines of code (226 with comments).* `bootstrap()` is the host-app setup a real app would give proper UI (register providers, grant Calendar, connect Todoist MCP). `run()` is the payoff — `DemoPolicy` → a tool list + an authorizer → `lab.makeSession`.

```swift
import LocalLMLabSDKComponents                                        // ← Components
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKRemote                                            // ← SDK (Remote)

@MainActor @Observable
final class AppModel {
    let security = DemoSecurity()
    @ObservationIgnored let presenter = ToolConfirmationPresenter()    // ← Components  — the ToolConfirmationChannel
    private(set) var lab: LocalLMLab!                                  // ← SDK

    // MARK: bootstrap  (a real app has UI for all of this)

    private func bootstrap() async {
        lab = LocalLMLab()                                            // ← SDK  — empty; a pasted key is registered live
        for p in FrontierProvider.allCases where hasKey(for: p) {
            registerProvider(p, key: storedKey(for: p))               // ← SDK (Remote)  — see below
            availableProviders.append(p)
        }

        let access = await CalendarAccess.requestAccess()             // ← SDK  — EventKit + the Info.plist-key check
        if !access.granted { appendSetup(access.error ?? "…") }

        // Todoist MCP — connected in-process; OAuth on a 401 opens the browser (redirect wired
        // in SecurityDemoApp via MCPOAuthFlow.redirectURI, same as components-demo).
        switch await lab.mcp.addServer(url: todoistURL, displayName: "todoist",   // ← SDK
                                       authType: auth.type, patToken: auth.token) {
        case .success(let state):
            for tool in todoistTools where state.tools.contains(where: { $0.name == tool }) {
                lab.mcp.setToolEnabled(server: state.id, tool: tool, enabled: true)   // ← SDK
            }
        case .failure(let error): appendSetup("Couldn't connect Todoist MCP: \(error)…")
        }
    }

    // A pasted API key: persist to the Keychain, register the provider now — no relaunch.
    private func registerProvider(_ p: FrontierProvider, key: String) {
        var cfg = p == .anthropic
            ? RemoteProviderConfig.anthropic(apiKey: key)             // ← SDK (Remote) (preset)
            : RemoteProviderConfig.openAI(apiKey: key)                // ← SDK (Remote) (preset)
        cfg.allowArbitraryModelIDs = true                            // ← SDK (Remote)
        lab.models.replace(RemoteModelProvider(cfg))                  // ← SDK  — register-or-swap by scheme
    }

    // MARK: run — DemoPolicy → SDK

    func run() async {
        // …ticker Task for the elapsed timer, elided…
        do {
            guard let modelID = ModelID(scheme: provider.scheme, rest: modelName) else { … }   // ← SDK
            lab.models.route("frontier", to: modelID)                 // ← SDK

            let policy = security.snapshot()

            // Lever 1 — selection. ClockTool is always on (a .read; the model needs "today").
            let hostTools: [any Tool] = [ClockTool()] + policy.limitedCalendarTools([   // ← SDK  — Core's EventKit tools
                GetUpcomingEventsTool(), AddCalendarEventTool(),
                UpdateCalendarEventTool(), DeleteCalendarEventTool(),
            ])

            // Lever 2 — invocation. nil when the panel asks for no confirmation.
            let authorizer: (any ToolCallAuthorizer)? = policy.wantsConfirmation   // ← SDK (type)
                ? ConfirmingToolAuthorizer(channel: presenter,                     // ← SDK
                                           requirement: { call in policy.requirement(for: call) })
                : nil

            let session = try lab.makeSession(                        // ← SDK
                route: "frontier",
                tools: hostTools,
                instructions: "…",
                includeMCPTools: true,      // pulls the enabled Todoist tools, tagged .mcp origin
                authorizer: authorizer)

            for await ev in session.events {                          // ← SDK  — toolCallStarted / toolCallFinished → the "Tool calls" list
                // …append to model.toolLog…
            }

            output = try await session.respond(to: prompt)           // ← SDK
        } catch {
            output = "Error: " + ((error as? LocalLMLabError)?.errorDescription ?? "\(error)")   // ← SDK
        }
    }
}
```

**Tally**: of the file's 130 non-comment/non-blank lines, 21 touch the SDK directly (marked
above, plus 2 more marked `← Components`) — and every SDK one is either setup (`LocalLMLab()`,
`registerProvider`, `addServer` + `setToolEnabled`,
`CalendarAccess.requestAccess`) or the one `run()` call site: `route` → build `hostTools` with
`limited(toMaxImpact:)` → wrap in `ConfirmingToolAuthorizer` → `makeSession(authorizer:)` →
`respond`. `DemoSecurity.swift` adds 6 more, all in `DemoPolicy` — the two levers themselves.
The `ToolConfirmationPresenter` + `.toolConfirmationSheet(_:)` (in `ContentView`, one line) is
the entire confirmation UI. Nothing in the three panel views touches the SDK — they bind to
`DemoSecurity`, and the snapshot does the rest.

## `examples/aiql`

*`Sources/AIQL/AIQLApp.swift` — 395 lines of code (494 with comments) — one file: view model + pipeline + SwiftUI UI. The
`FolderAccess` enum and the `ContentView` UI are elided below.*

The **`FileBackedTool` + `loadTable` + `sqlQuery`** showcase (`sdk-guide.md`
[§8b](sdk-guide.md#8b-filebackedtool--the-aiql-data-verbs-a-mechanical-mcp-dataset--csv-pipeline)):
type a local model, an MCP data source, and a plain-English request; the app pulls the dataset
into a file (so the raw payload never enters the model's context), `loadTable`s it into an
ephemeral SQLite table, and has the model write **one read-only `SELECT`** to a CSV. The model
names a table and describes one query — it never handles a row, and can't drop a step, because
there's only ever one query call. `WHERE` / `BETWEEN` / `ORDER BY … LIMIT` / `JOIN` run inside
SQLite. Links `LocalLMLabSDKInference` for the MLX model. Because the model field is free text, the app can't pin
everything ahead of time, so it layers three supply-chain controls: the default model is **pinned** to a
reviewed commit (`pinnedRevisions:`), any other model is pinned on first download (`MLXFilePinStore`), and a
**trust policy** (`MlxCommunityOnly`) limits which repos can be fetched at all; downloads are hash-verified by
default. `FolderAccess` is verbatim from
`workspace-buddy-local` (`sdk-guide.md` §8) and elided.

```swift
import AppKit
import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKInference                                         // ← SDK (Inference)
import SwiftUI

// MARK: - FolderAccess { pickFolder / resolveBookmarkedFolder / withFolderAccessAsync }
//   — verbatim from workspace-buddy-local (docs/sdk-guide.md §8); elided here.

// MARK: - Trust policy

/// Which repos this app will fetch. The SDK ships no allow-list (that's the host's call); this app
/// allows one namespace. Widen it here if you want other publishers — each one is a party whose
/// uploads your users will run.
struct MlxCommunityOnly: MLXModelTrustPolicy {                       // ← SDK (Inference)
    func evaluate(repoID: String) async -> MLXModelTrustDecision {   // ← SDK (Inference)
        repoID.hasPrefix("mlx-community/") ? .allow : .deny(reason: "only mlx-community models are allowed in this app")
    }
}

@available(macOS 27.0, *)
@MainActor
final class AIQLModel: ObservableObject {
    enum Stage: Equatable {
        case idle, connecting
        case downloadingModel(Double)      // 0…1
        case running
        case done(fileName: String, csv: String, folder: URL)
        case failed(String)
    }

    static let defaultModelRepo = "mlx-community/Qwen3-14B-4bit"
    // Commit of the default model this app was tried against. Update after reviewing a new version.
    static let defaultModelRevision = "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4"
    @Published var modelRepo = AIQLModel.defaultModelRepo
    @Published var serverURLString = "https://econ-index.mcp.claude.com/mcp"
    @Published var request = ""
    @Published private(set) var folderURL: URL?
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var steps: [String] = []

    private let manager = MCPServerManager()                          // ← SDK
    // The field is free text, so this app can't pin everything ahead of time. Two layers instead:
    //  - the default model is pinned to a commit this app shipped with (developer-vouched);
    //  - any other model is pinned on first download (`MLXFilePinStore`, kept outside the model
    //    cache), so re-downloading later fetches the same version the user first got.
    // A trust policy limits which repos can be fetched at all; downloads are hash-verified by default.
    private let mlx = MLXModelProvider(                               // ← SDK (Inference)
        residentModelLimit: 1,
        pinnedRevisions: [AIQLModel.defaultModelRepo: AIQLModel.defaultModelRevision],   // ← SDK (Inference)
        supplyChainPolicy: MLXSupplyChainPolicy(trustPolicy: MlxCommunityOnly()),        // ← SDK (Inference)
        pinStore: MLXFilePinStore())                                 // ← SDK (Inference)
    private lazy var lab = LocalLMLab(configuration: .init(providers: [mlx, SystemModelProvider()]))   // ← SDK

    init() { folderURL = FolderAccess.resolveBookmarkedFolder() }

    // canGo / isBusy / chooseFolder / go() — plain view-model plumbing, elided.

    private func run() async {
        steps = []
        let prompt = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)), serverURL.scheme != nil else {
            stage = .failed("That MCP server address doesn't look like a web link."); return
        }
        guard let modelID = ModelID(scheme: "mlx", rest: modelRepo.trimmingCharacters(in: .whitespaces)) else {   // ← SDK
            stage = .failed("The model name should look like mlx-community/Qwen3-8B-4bit."); return
        }
        lab.models.route(.local, to: modelID)                        // ← SDK

        // 1 — connect (triggers an OAuth browser sign-in automatically if the server needs one)
        stage = .connecting
        let connection = await manager.addServer(url: serverURL, displayName: serverURL.host ?? "MCP server")   // ← SDK
        guard case .success(let server) = connection else {
            if case .failure(let error) = connection {
                stage = .failed("Couldn't connect to that MCP server — \(Self.describe(error))")
            } else {
                stage = .failed("Couldn't connect to that MCP server.")
            }
            return
        }
        guard !server.tools.isEmpty else {
            stage = .failed("Connected, but that server didn't offer any tools to get data from."); return
        }
        step("Connected — \(server.tools.count) data tool(s) available.")

        // 2 — download the model on first use
        if case .notDownloaded = lab.models.availability(for: modelID) {   // ← SDK
            stage = .downloadingModel(0)
            if let preflight = try? await mlx.validate(modelRepo.trimmingCharacters(in: .whitespaces)), !preflight.passed {   // ← SDK (Inference)
                stage = .failed("That model didn't pass its check: \(preflight.detail ?? "unknown reason")."); return
            }
            do {
                for try await event in mlx.download(modelRepo.trimmingCharacters(in: .whitespaces)) {   // ← SDK (Inference)
                    if case .progress(_, _, let fraction) = event { stage = .downloadingModel(fraction) }
                }
                if let pin = mlx.effectivePin(for: modelRepo.trimmingCharacters(in: .whitespaces)) {   // ← SDK (Inference)
                    step("Pinned to version \(pin.revision.prefix(7)) (\(pin.source == .shipped ? "shipped with this app" : "the version you just downloaded")).")
                }
            } catch {
                stage = .failed("The model download failed: \(error.localizedDescription)"); return
            }
        }

        // 3 — run the pipeline inside the security-scoped access window
        stage = .running
        let outcome = await FolderAccess.withFolderAccessAsync { root in
            await self.runPipeline(prompt: prompt, root: root, serverTools: server.tools, serverID: server.id, modelID: modelID)
        }
        stage = outcome ?? .failed("Couldn't open the folder you chose — pick it again.")
    }

    private func runPipeline(prompt: String, root: URL, serverTools: [MCPToolDescriptor],   // ← SDK (type)
                             serverID: MCPServerID, modelID: ModelID) async -> Stage {       // ← SDK (types)
        // Wrap the server's tools as file-backed so the model can `saveAs` any of them. Cap the
        // count — a small model degrades past ~8 tools; prefer names that look like "get a dataset".
        let ranked = serverTools.sorted { Self.dataLikelihood($0.name) > Self.dataLikelihood($1.name) }
        let dataTools: [any Tool] = ranked.prefix(4).compactMap {
            try? FileBackedTool.mcp(descriptor: $0, manager: manager, root: root, inlineCharacterLimit: 8_000,   // ← SDK  — payload → file, receipt → model
                                    followUp: "load it into a table with loadTable, then query it with one sqlQuery")
        }
        guard !dataTools.isEmpty else { return .failed("Couldn't read that server's tools — its data format isn't supported yet.") }

        // loadTable stages a JSON records file into an ephemeral SQLite table (auto-detects the
        // records array, sniffs column types, explodes a nested array into a child table) and
        // returns its CREATE TABLE. sqlQuery runs ONE read-only SELECT to a CSV. describeJson /
        // csvInfo are for discovery + verification. The row data never reaches the model.
        var tools: [any Tool] = dataTools
        tools.append(LoadTableTool(root: root))                      // ← SDK
        tools.append(SQLQueryTool(root: root))                       // ← SDK
        tools.append(DescribeJSONTool(root: root))                   // ← SDK
        tools.append(CSVInfoTool(root: root))                        // ← SDK

        let dataToolNames = dataTools.map(\.name).joined(separator: ", ")
        let instructions = """
        You answer a data question by loading the pulled data into tables and running ONE SQL \
        query. You never write row data yourself …
        1. Pick the ONE data tool whose result answers the question — from: \(dataToolNames) — \
           and call it with `saveAs` set to "raw/data.json" (a second dataset → "raw/data2.json"; \
           `saveAsAppend: true` for each further page).
        2. loadTable  jsonPath "raw/data.json", a short tableName, recordsAt "". Read the \
           CREATE TABLE it returns — use ONLY those column names. A nested array is a child \
           table "<table>__<field>"; join it with "<child>.<table>_id = <table>.id".
        3. sqlQuery — ONE call: one SELECT, outputPath "out.csv". A numeric range → BETWEEN; \
           "top N" → ORDER BY … LIMIT N; "highest <X> first" → ORDER BY <X> DESC (never a rank \
           column). The moment it succeeds you are done.
        4. csvInfo  path "out.csv", then reply in one sentence with the column names and row \
           count. Do not print the rows.
        """  // (full prompt in the source)

        let session: LocalLMLabSession                               // ← SDK
        do {
            // effort: .off — skip the model's <think> pass. The Qwen3 family has the template
            // toggle; the pipeline is mechanical, so the reasoning trace buys nothing but latency.
            session = try lab.makeSession(route: .local, tools: tools, instructions: instructions,   // ← SDK
                                          includeMCPTools: false, options: SessionOptions(effort: .off))   // ← SDK
        } catch {
            return .failed("Couldn't start the model: \(error.localizedDescription)")
        }
        defer { session.cancel() }                                   // ← SDK

        // Friendly progress from the session's tool-call side-channel.
        let stepTask = Task { @MainActor in
            for await event in session.events {                      // ← SDK
                switch event {
                case .toolCallStarted(_, let name, _):
                    self.step(Self.friendlyStep(for: name))
                case .toolCallFinished(_, let name, let failed, _) where failed:
                    self.step("  · \(Self.friendlyStep(for: name)) hit a snag — retrying")
                default: break
                }
            }
        }
        defer { stepTask.cancel() }

        do {
            _ = try await session.languageModelSession.respond(to: "Question: \(prompt)\n\nBegin with step 1 now.")   // ← SDK
        } catch {
            return .failed(await GenerationErrorDescription.describe(error))   // ← SDK
        }

        // The result CSV. Instructions ask for "out.csv"; fall back to the newest .csv if a weak
        // model left it in the last stage file.
        var name = "out.csv"
        if case .failure = WorkspaceAccess.readFile(in: root, path: "out.csv"),               // ← SDK
           case .success(let entries) = WorkspaceAccess.listFiles(in: root, subpath: nil) {   // ← SDK
            if let newest = entries
                .filter({ !$0.isDirectory && $0.name.hasSuffix(".csv") })
                .max(by: { ($0.modifiedDate ?? .distantPast) < ($1.modifiedDate ?? .distantPast) }) {
                name = newest.name
            }
        }
        guard case .success(let csv) = WorkspaceAccess.readFile(in: root, path: name) else {   // ← SDK
            return .failed("The model finished but didn't write a spreadsheet. Try rephrasing, or a larger model.")
        }
        step("Saved \(name).")
        return .done(fileName: name, csv: csv, folder: root)
    }

    // describe(_:) over MCPServerError, dataLikelihood / friendlyStep string helpers — elided.
}

// MARK: - ContentView — ordinary SwiftUI (four text fields, a Go button, a status area). Elided.

// Handle aiql://oauth/callback through the AppDelegate, not SwiftUI's .onOpenURL — WindowGroup
// treats an open-URL event as a request for a new window. Same fix plate-today / components-demo use.
@available(macOS 27.0, *)
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "aiql" {
            MCPOAuthRedirectListener.shared.handleRedirect(url)       // ← SDK
        }
    }
}

@available(macOS 27.0, *)
@main
struct AIQLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AIQLModel()

    init() {
        MCPOAuthFlow.redirectURI = "aiql://oauth/callback"           // ← SDK
    }

    var body: some Scene {
        WindowGroup { ContentView(model: model) }
            .windowResizability(.contentMinSize)
            .handlesExternalEvents(matching: [])
    }
}
```

**Tally**: the model layer is the same ~7 lines as `repo-qa-local` (`MLXModelProvider` / `LocalLMLab`
/ `route` / `availability` / `validate` / `download` / `makeSession`), plus the supply-chain controls above:
an `MLXModelTrustPolicy` conformance (~5 lines), and the `pinnedRevisions:` / `supplyChainPolicy:` / `pinStore:`
arguments on `MLXModelProvider`, and an `effectivePin(for:)` call that tells the user which version they got. Everything new here is the
pipeline: `FileBackedTool.mcp(descriptor:manager:root:)` wraps each MCP data tool so its payload
lands in a file instead of the model's context, and four data-verb `Tool`s
(`LoadTableTool` / `SQLQueryTool` / `DescribeJSONTool` / `CSVInfoTool`, marked above) do the
mechanical work: `loadTable` stages a JSON records file into an ephemeral SQLite table,
`sqlQuery` runs exactly one read-only `SELECT` to a CSV, and `describeJson`/`csvInfo` are for
discovery and verification — the row data itself never passes through the model. The
`instructions` string doing the orchestration is the real work of this example — the SDK surface
it drives is the four data-verb `Tool`s plus up to four `FileBackedTool.mcp`-wrapped MCP tools
(`ranked.prefix(4)`, marked above), eight one-line `Tool` instantiations at most, plus
`WorkspaceAccess` to read the result back.

## `examples/vistanova`

*`Sources/VistaNova/AppModel.swift`, `TavilySearchTool.swift`, and `ModelStateStore` from
`Persistence.swift` — the app's SDK-facing code, 931 lines of code in the whole app (1,294 with
comments), of which `AppModel` is 361. The SwiftUI views, theme, settings screen
are plain SwiftUI/Foundation and omitted; elisions are marked
`// …`.*

A search engine whose two jobs use **two different local models**, because they carry different
risk: *search* needs a model that reliably calls a tool (Apple's on-device model by default);
*summarize* is pure text synthesis with no tool call, so it defaults to a downloaded MLX model,
`mlx-community/Qwen3-4B-4bit`, **shipped pinned to an exact commit** (`sdk-guide.md`
[Pinning, updating and cleaning up model versions](sdk-guide.md#pinning-updating-and-cleaning-up-model-versions)).
The search runs through Tavily's hosted MCP server with a static API key (`authType: .pat`), via a
hand-written Path B `Tool`. Most of the interesting code is defensive: it never trusts a small
model to have actually called the tool, or to have produced a usable shape. Links both
`LocalLMLabSDKCore` and `LocalLMLabSDKInference`. Sandbox-free, ad-hoc signed (no entitlements).

```swift
// TavilySearchTool.swift — Path B: a hand-written Tool over one MCP tool, instead of Core's
// auto-assembled MCPTool. Two things Path A can't give: max_results/search_depth pinned in
// Swift (the model only ever chooses `query`), and the query the model actually sent.

import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK

/// Records the query argument each `tavily_search` call actually used, so the UI can show what was
/// really searched rather than re-printing the user's input. (Since 1.0.0-RC.1 `session.events`'
/// `.toolCallStarted` also carries the call's `arguments`; this app predates that and still records it here.)
actor SearchQueryCapture {
    private(set) var query: String?
    func record(_ query: String) { self.query = query }
}

struct TavilySearchTool: Tool {                                       // FoundationModels' Tool protocol
    let name = "tavily_search"
    let description = "Search the web for a query and return ranked results with source URLs."

    @Generable
    struct Arguments {
        @Guide(description: "The web search query")
        let query: String
    }

    let manager: MCPServerManager                                     // ← SDK
    let serverID: MCPServerID                                         // ← SDK
    let capture: SearchQueryCapture

    func call(arguments: Arguments) async throws -> String {
        await capture.record(arguments.query)
        let result = await manager.callTool(                          // ← SDK
            server: serverID, tool: "tavily_search",
            arguments: [
                "query": .string(arguments.query),
                "max_results": .number(5),                            // pinned here, not in a prompt
                "search_depth": .string("basic"),
            ])
        switch result {
        case .success(let toolResult): return toolResult.renderedForModel   // ← SDK
        case .failure(let error): return "tavily_search failed: \(error)"
        }
    }
}
```

```swift
// Persistence.swift — the SDK's own snapshot type is Codable: routes, residency and installed
// records round-trip through one JSON file. The app keeps no model-choice setting of its own.

enum ModelStateStore {
    static func load() -> LocalLMLabState? {                          // ← SDK
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalLMLabState.self, from: data)   // ← SDK
    }

    static func save(_ state: LocalLMLabState) {                      // ← SDK
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
    // …
}
```

```swift
// AppModel.swift
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKInference                                         // ← SDK (Inference)

@Generable
struct SearchResults {                                                // structured output, when the model can
    @Guide(description: "Exactly 5 distinct web pages that cover the topic")
    let pages: [WebPage]
}

@available(macOS 27, *)
@MainActor
@Observable
final class AppModel {
    let lab: LocalLMLab                                               // ← SDK

    // THE PIN. Without `pinnedRevisions` a fresh download tracks the repo's `main`, so its owner can
    // change the weights behind the same name and change what Summarize does with no app release.
    // A shipped pin beats any captured one and, if it can't be fetched, fails the download — it never
    // falls back to `main`. Only a commit this app names can move it: review a newer one, then change
    // the hash and ship.
    private let mlxProvider = MLXModelProvider(pinnedRevisions: [    // ← SDK (Inference)
        AppModel.summaryModelRepo: AppModel.summaryModelRevision,
    ])

    static let summaryModelRepo = "mlx-community/Qwen3-4B-4bit"
    static let summaryModelRevision = "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25"   // full commit hash, not a branch
    static let defaultSummaryModel = ModelID(scheme: "mlx", rest: summaryModelRepo)!   // ← SDK

    // Two independent model choices — two routes, not one model: search needs reliable
    // tool-calling, summarize doesn't.
    var searchModel: ModelID = .system                                // ← SDK
    var summaryModel: ModelID = AppModel.defaultSummaryModel

    init() {
        // …
        lab = LocalLMLab(configuration: .init(                        // ← SDK
            providers: [SystemModelProvider(), mlxProvider]))         // ← SDK / ← SDK (Inference)
        if let modelState = ModelStateStore.load() {
            lab.restore(from: modelState)                             // ← SDK — routes + installed records back
        }
        searchModel = lab.models.modelID(for: "search") ?? .system    // ← SDK
        summaryModel = lab.models.modelID(for: "summary") ?? Self.defaultSummaryModel   // ← SDK
        // …
    }

    /// Only models actually ready to use — Apple's plus whatever MLX weights are already on disk.
    var availableModels: [ModelID] {
        lab.models.knownModels.filter { lab.models.availability(for: $0).isAvailable }   // ← SDK
    }

    func selectSummaryModel(_ id: ModelID) {
        // …
        lab.models.route("summary", to: id)                           // ← SDK
        ModelStateStore.save(lab.snapshot())                          // ← SDK
    }

    // MARK: - Tavily (MCP)

    func connectTavily(apiKey: String) async -> String? {
        let result = await lab.mcp.addServer(                         // ← SDK
            url: tavilyURL, displayName: "Tavily", authType: .pat, patToken: apiKey)   // static key → Keychain
        // …persist only the server's non-secret shape; the key itself is in MCPPATStore
    }

    private func reconnectTavily(shape: PersistedTavilyServer) async {
        lab.mcp.restore(from: [(                                      // ← SDK — no network, no key prompt
            id: tavilyServerID, url: tavilyURL, displayName: shape.displayName,
            tools: [], estimatedTokens: shape.estimatedTokens, enabled: true,
            authType: .pat, manualClientID: nil, resources: []
        )])
        let result = await lab.mcp.reconnect(tavilyServerID)          // ← SDK — pulls the key from the Keychain
        // …
    }

    // MARK: - Search

    // Whether an MLX model reliably calls a tool, and whether it supports @Generable structured
    // output, both vary by model (confirmed live: Qwen3-8B, Gemma and Granite answered "who founded
    // Yahoo" from training data instead of calling the tool). One real probe, cached per model.
    private func searchCapability(_ id: ModelID) async -> ModelSearchCapability {
        guard id.scheme == "mlx" else { return ModelSearchCapability(toolCalling: true, guidedGeneration: true) }
        if let cached = capabilityCache[id] { return cached }
        let report = await mlxProvider.capabilityProbe(id)            // ← SDK (Inference)
        let capability = ModelSearchCapability(
            toolCalling: report.capabilities.contains(.toolCalling),          // ← SDK
            guidedGeneration: report.capabilities.contains(.guidedGeneration))   // ← SDK
        capabilityCache[id] = capability
        return capability
    }

    // A fresh, stateless session per search — refinement happens in the composer, not the model.
    private func makeSearchSession(supportsGuidedGeneration: Bool) throws -> (LocalLMLabSession, SearchQueryCapture) {
        lab.models.route("search", to: searchModel)                   // ← SDK
        let capture = SearchQueryCapture()
        let tool = TavilySearchTool(manager: lab.mcp, serverID: tavilyServerID, capture: capture)   // ← SDK — lab.mcp IS an MCPServerManager
        let session = try makeSessionSuppressingThinking(
            route: "search", tools: [tool], instructions: /* … */, includeMCPTools: false)
        return (session, capture)
    }

    // `effort: .off` suppresses a Qwen3-family model's <think> block (a documented no-throw
    // preference: a model that always reasons just keeps reasoning instead of failing the turn).
    private func makeSessionSuppressingThinking(route: RouteName, tools: [any Tool] = [], instructions: String, includeMCPTools: Bool) throws -> LocalLMLabSession {
        try lab.makeSession(route: route, tools: tools, instructions: instructions,   // ← SDK
                            includeMCPTools: includeMCPTools, options: .init(effort: .off))   // ← SDK
    }

    private func attemptSearch(query: String, using session: LocalLMLabSession, supportsGuidedGeneration: Bool) async throws -> [SearchResultLink] {
        // A plausible-looking answer proves nothing: a model can answer from its own training data
        // and never call the tool. Watch the session's event stream for the tool actually starting.
        var toolWasCalled = false
        let watcher = Task {
            for await event in session.events {                       // ← SDK
                if case .toolCallStarted(_, let name, _) = event, name == "tavily_search" {   // ← SDK
                    toolWasCalled = true
                }
            }
        }
        defer { watcher.cancel() }

        if supportsGuidedGeneration {
            do {
                let response = try await session.languageModelSession.respond(   // ← SDK — a plain FoundationModels session
                    to: query, generating: SearchResults.self)
                guard toolWasCalled else { throw SearchParseError.toolNotCalled }
                return response.content.pages.map { /* … */ }
            } catch {
                // Apple's on-device guardrail can decline a turn about a public figure AFTER the model
                // produced a valid payload; the JSON survives in the error's own description.
                if let recovered = await Self.recoverPages(from: error) { return recovered }
                throw error
            }
        } else {
            // No guided generation on this model: plain text, parsed leniently for (title, url).
            let response = try await session.languageModelSession.respond(to: query)   // ← SDK
            // …
        }
    }

    private static func recoverPages(from error: Error) async -> [SearchResultLink]? {
        let description = await GenerationErrorDescription.describe(error)   // ← SDK — unwraps the underlying error
        // …strict JSON decode, then a lenient regex when the decline path drops quote characters
    }

    // MARK: - Summarize

    func summarize(turnID: UUID) async {
        // …
        // `mlxProvider.installed` alone isn't trustworthy right after a cancelled download (a few MB
        // of metadata is on disk and `installed` already lists the repo), so the app also keeps its
        // own record of "the last attempt didn't finish" and always re-runs the tracked download.
        if summaryModel.scheme == "mlx",
           !mlxProvider.installed.contains(where: { $0.id == summaryModel })   // ← SDK (Inference)
            || incompleteDownloadRepoIDs.contains(summaryModel.rest) {
            guard await downloadSummaryModel() else { return }
        }
        // …
    }

    private func downloadSummaryModel() async -> Bool {
        // …
        for try await event in mlxProvider.download(repoID) {         // ← SDK (Inference) — downloads the PINNED commit
            if case .progress(_, _, let fraction) = event {           // ← SDK
                pendingDownload?.fraction = fraction
            } else if case .completed = event {                       // ← SDK
                incompleteDownloadRepoIDs.remove(repoID)
                return true
            }
        }
        // …
    }

    func cancelPendingDownload() {
        isUserCancelledDownload = true
        mlxProvider.cancelDownload(summaryModel.rest)                 // ← SDK (Inference) — aborts the real transfer
    }
}
```

**Tally**: of `AppModel`'s 361 lines of code, 34 touch the SDK directly (marked above; another 8 in
`TavilySearchTool` and `ModelStateStore`) — the rest is search-result parsing, thread bookkeeping
and state. **The pin is one parameter**
(`pinnedRevisions:` on `MLXModelProvider`) **plus two constants** — everything downstream
(`download`, `installed`, availability) then resolves the pinned commit without further code. What
the app *doesn't* need is as instructive: no `MLXFilePinStore` (captured pins record the commit of a
user's own first download, and this app only ever downloads the one model it pins), and no
`managedPinStore` (updating that model means shipping a new build). Compare `mlx-control-room`,
which shows both. The parts with no SDK line but the most hard-won behavior are the defensive
ones: the `session.events` watcher that rejects a turn where the tool was never called, the
capability probe that decides between `@Generable` output and a text parser, and the guardrail-
decline recovery. Path B (`TavilySearchTool`) costs 33 lines against `MCPTool`'s zero, and buys a
pinned `max_results` and the captured query.

## `examples/components-updates-demo`

*`Sources/UpdatesDemo/UpdatesDemoApp.swift` — 151 lines of code (170 with comments) — the whole file is shown below.*

The `LocalLMLabSDKComponents` views for **onboarding, updating and cleaning up** a downloaded model
([`sdk-guide.md` §11](sdk-guide.md#11-components-prebuilt-swiftui-mcp-servers--the-model-layer)), driven by
**simulated** sources: short sleeps stand in for the network and for MLX, so every state of every view can be
reached on demand — a denied preflight, a download that fails part-way, a download that resolves to a different
commit than the app ships, an update with the host's pause point, a failed update, a fixed model that can't be
updated, and a versions list with a guarded Remove. It links only `Components` (and through it `Core`); it never
touches `MLXModelProvider`, which lives in `LocalLMLabSDKInference` and needs no import here.

That is the point of the design: these views are **provider-agnostic**. They own presentation and state and take plain
value types (`PreflightResult`, `InstalledModel`, `ModelUpdateOffer`, `ModelVersionRow`) and closures
(`ModelOnboardingSource`, `ModelUpdateActions`, the `list` / `remove` pair) that *you* supply. Here the closures fake
the work; in a real host they call `MLXModelProvider` — `validate`, `download`, `checkPinUpdate`,
`updatePin(_:to:beforeSwitch:)`, `snapshots(for:)`, `removeSnapshot(_:revision:)` — and
[`mlx-control-room`](#examplesmlx-control-room) is the companion that does exactly that.
`Components/README.md` has the ~40-line adapter.

```swift
import LocalLMLabSDKComponents                                    // ← Components
import LocalLMLabSDKCore                                          // ← SDK
import SwiftUI

// Every source here is simulated with short sleeps, so each state of each view can be reached on demand.

private let shippedCommit = "9eba008f65cdc8aee60201be10dcd0e7858455ce"
private let newerCommit = "ff1143e3a10547c9f2129e94ca37059b096b23f4"

@main
@available(macOS 27, *)
struct UpdatesDemoApp: App {
    var body: some Scene {
        WindowGroup("Components: onboarding, updates, versions") {
            DemoView().frame(minWidth: 640, minHeight: 720)
        }
    }
}

// MARK: - Simulated sources

/// Onboarding source with switches for each way a flow can go wrong.
private struct Faults: Sendable {
    var denyPreflight = false
    var resolveDifferentCommit = false
    var failDownload = false
}

private func simulatedOnboardingSource(_ faults: Faults) -> ModelOnboardingSource {  // ← Components
    ModelOnboardingSource(                                        // ← Components
        validate: { repo in
            try await Task.sleep(for: .milliseconds(500))
            if faults.denyPreflight {
                return PreflightResult(failedStage: .trustPolicy, detail: "\(repo) isn't on this app's allow-list")  // ← SDK
            }
            return PreflightResult(detail: "qwen2 · ≈ 278 MB")    // ← SDK
        },
        download: { repo, report in
            for step in 0...10 {
                try await Task.sleep(for: .milliseconds(180))
                report(DownloadProgress(bytesReceived: Int64(step) * 27_800_000, totalBytes: 278_000_000, fraction: Double(step) / 10))  // ← SDK
                if faults.failDownload && step == 6 { throw LocalLMLabError.download(stage: "verify", underlying: nil) }  // ← SDK
            }
            return InstalledModel(                                // ← SDK
                id: ModelID(scheme: "mlx", rest: repo)!, repoID: repo,  // ← SDK
                resolvedRevision: faults.resolveDifferentCommit ? newerCommit : shippedCommit)
        })
}

/// A model that is on `shippedCommit`, with `newerCommit` on offer; failures switchable.
private final class SimulatedModel: @unchecked Sendable {
    private let lock = NSLock()
    private var _current = shippedCommit
    var failNextUpdate = false
    var current: String { lock.lock(); defer { lock.unlock() }; return _current }
    func set(_ commit: String) { lock.lock(); _current = commit; lock.unlock() }
}

private func simulatedActions(_ sim: SimulatedModel) -> ModelUpdateActions {  // ← Components
    ModelUpdateActions(                                           // ← Components
        check: {
            try await Task.sleep(for: .milliseconds(600))
            let current = sim.current
            return ModelUpdateOffer(                              // ← Components
                current: current, available: newerCommit,
                changes: current == newerCommit ? [] : [
                    ModelFileChange(path: "config.json", kind: .modified, oldSize: 1648, newSize: 1653),  // ← Components
                ])
        },
        apply: { revision, progress, beforeSwitch in
            for step in 0...10 {
                try await Task.sleep(for: .milliseconds(150))
                progress(Double(step) / 10)
            }
            if sim.failNextUpdate { sim.failNextUpdate = false; throw LocalLMLabError.download(stage: "cacheQuota", underlying: nil) }  // ← SDK
            try await beforeSwitch()          // the host's pause point, before anything changes
            try await Task.sleep(for: .milliseconds(300))
            sim.set(revision)
        })
}

// MARK: - Demo

@available(macOS 27, *)
private struct DemoView: View {
    @State private var faults = Faults()
    @State private var onboarding: ModelOnboardingModel?          // ← Components

    @State private var sim = SimulatedModel()
    @State private var userChosen: ModelUpdateModel               // ← Components
    @State private var builtIn: ModelUpdateModel                  // ← Components
    @State private var versions: ModelVersionsModel               // ← Components
    @State private var pauseNote = "idle"

    init() {
        let userSim = SimulatedModel()
        let builtInSim = SimulatedModel()
        _sim = State(initialValue: builtInSim)
        _userChosen = State(initialValue: ModelUpdateModel(       // ← Components
            actions: simulatedActions(userSim), ownership: .userChosen, currentRevision: shippedCommit))  // ← Components
        let built = ModelUpdateModel(                             // ← Components
            actions: simulatedActions(builtInSim), ownership: .developerOffered, currentRevision: shippedCommit)  // ← Components
        built.shippedRevision = shippedCommit                     // ← Components
        _builtIn = State(initialValue: built)
        _versions = State(initialValue: ModelVersionsModel(       // ← Components
            list: { [
                ModelVersionRow(revision: shippedCommit, isCurrent: false, freesBytes: 1_648, sharedBytes: 190_208_261),  // ← Components
                ModelVersionRow(revision: newerCommit, isCurrent: true, freesBytes: 1_653, sharedBytes: 190_208_261),  // ← Components
            ] },
            remove: { row in row.freesBytes }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("1 · Onboarding a model") {
                    Text("Validate → Download → Pin. Try the switches, then Add.").font(.caption).foregroundStyle(.secondary)
                    Toggle("preflight denies the repo (trust policy)", isOn: $faults.denyPreflight)
                    Toggle("download resolves a different commit than the app ships", isOn: $faults.resolveDifferentCommit)
                    Toggle("download fails part-way", isOn: $faults.failDownload)
                    Button("Add mlx-community/gemma-3-270m-it-4bit") {
                        onboarding = ModelOnboardingModel(        // ← Components
                            requests: [ModelOnboardingRequest(    // ← Components
                                repoID: "mlx-community/gemma-3-270m-it-4bit", expectedRevision: shippedCommit)],
                            source: simulatedOnboardingSource(faults))
                        onboarding?.start()                       // ← Components
                    }
                    .disabled(onboarding?.isRunning == true)      // ← Components
                    if let onboarding {
                        ModelOnboardingView(model: onboarding, onFinished: { _ in self.onboarding = nil }, onDismiss: { self.onboarding = nil })  // ← Components
                    }
                }
                Divider()
                section("2 · A model you chose — you decide when to update") {
                    ModelUpdateView(model: userChosen)            // ← Components
                }
                Divider()
                section("3 · A built-in model — the developer's offer") {
                    Text("Pause point: \(pauseNote)").font(.caption).foregroundStyle(.secondary)
                    ModelUpdateView(model: builtIn)               // ← Components
                        .task {
                            builtIn.pauseInference = {            // ← Components
                                await MainActor.run { pauseNote = "waiting for in-flight requests to finish…" }
                                try await Task.sleep(for: .milliseconds(900))
                                await MainActor.run { pauseNote = "quiet — switching" }
                            }
                        }
                }
                Divider()
                section("4 · Something that can't be updated here") {
                    ModelUpdateView(model: ModelUpdateModel(      // ← Components
                        actions: simulatedActions(SimulatedModel()),
                        ownership: .fixed(reason: "Shipped with this app. It changes only with a new app version.")))  // ← Components
                }
                Divider()
                section("5 · Cleaning up old versions") {
                    ModelVersionsView(model: versions)            // ← Components
                }
            }
            .padding(24)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}
```

**Tally**: of the file's 151 non-comment/non-blank lines, 38 touch the SDK (marked above), and every one of them is a
`Components` type or a Core value type handed to one. Almost all of the rest is the *simulation* — the sleeps, the
fault switches, the state for each demo section. The seams to notice:

- **`ModelOnboardingSource(validate:download:)`** is where a real host plugs in the provider: `validate` returns a
  `PreflightResult` (a failure names its `.stage`, and nothing after it runs), `download` reports `DownloadProgress`
  and returns the `InstalledModel` whose `resolvedRevision` the **Pin** step checks against
  `ModelOnboardingRequest.expectedRevision`. Section 1's second switch makes the download resolve a different commit
  to show that check refusing.
- **`ModelUpdateActions(check:apply:)`**: `apply` has exactly the shape of `MLXModelProvider.updatePin(_:to:beforeSwitch:)`
  — download and verify, call `beforeSwitch` **once, before anything changes**, then switch, and a throw must leave the
  old version in place (section 2's failure switch).
- **`pauseInference`** is the host's half of that contract. The SDK moves the pin only after `beforeSwitch` returns, so
  the host uses the pause to stop new requests and wait for the in-flight one (`builtIn.pauseInference` above);
  `state == .switching` tells the UI to refuse new work.
- **`ModelUpdateOwnership`** (`.userChosen`, `.developerOffered`, `.fixed(reason:)`) changes what the view offers: a
  user's own model updates when they say so; a built-in one only to a commit the developer vouches for (and can be
  reverted to the shipped version); a fixed one shows the reason instead of a button.
- **`ModelVersionsModel(list:remove:)`** takes the versions on disk and a `remove` that returns the bytes freed. Note
  `freesBytes` versus `sharedBytes`: removing a version frees only the files no other version uses, which is what the
  SDK's `MLXCachedSnapshot` reports.

## `examples/mlx-control-room`

*`Sources/MLXControlRoom/MLXControlRoomApp.swift` — the view-model half (`ControlRoomModel` and the constants above
it), excerpted: 1,434 lines of code in the whole file (1,812 with comments), of which the SwiftUI views (`// MARK: - UI`,
about 863 lines) are plain SwiftUI and omitted. Elisions are marked `// …`.*

The example that shows how a host app can **deploy models from Hugging Face without a "just download anything"
approach**, and exposes the MLX knobs with a gauge beside each. Read it as one tour of `MLXModelProvider`'s
supply-chain and lifecycle surface ([`sdk-guide.md` §6a](sdk-guide.md#pinning-updating-and-cleaning-up-model-versions)):

1. **Check before you fetch.** `validate(_:)` runs the preflight (`trustPolicy`, `repoReachable`, `mlxFormat`,
   `architectureSupported`, `sizeVsMemory`, `diskSpace`, `cacheQuota`) and names the stage that failed.
   `MLXSupplyChainPolicy` carries the host's `MLXModelTrustPolicy` (here a toy allow-list), the hash-verification
   switch, and an `MLXCacheLimits` cap.
2. **Pin every model to one exact version.** Three kinds of pin meet in `makeProvider`: `pinnedRevisions:` is the
   developer's **shipped** pin (code, never stored, always wins); `pinStore: MLXFilePinStore()` **captures** the commit
   of a user's own first download; `managedPinStore:` records a developer-vouched **runtime move** of a shipped pin.
   `effectivePin(for:)` says which is in force.
3. **Update deliberately.** `checkPinUpdate(_:to:)` previews what would change and downloads nothing;
   `updatePin(_:to:beforeSwitch:)` downloads and verifies the new commit, awaits the host's `beforeSwitch` (the pause
   point), moves the pin, and evicts — all or nothing. Rolling back is `updatePin(to: oldCommit)`. For a shipped model
   the target is a commit the developer's feed names (`HostUpdateFeed`), **never `main`**; the SDK has no feed and
   authenticating the answer is the host's job.
4. **Clean up.** `snapshots(for:)` lists every cached version with what removing it would actually free;
   `removeSnapshot(_:revision:)` refuses the current one. The SDK never prunes on its own.
5. **Tune and pair.** `SessionOptions` carries every knob into a real `GenerateParameters`;
   `pairDraftModel(_:with:)` / `pairAdapter(_:with:)` add a speed helper or a LoRA adapter, re-applied on each Run.
6. **Observe.** `residencyEventStream` is the residency log; the tokens/sec, repeat-rate and time-to-first-token
   gauges are measured off the live stream.

Links `LocalLMLabSDKCore` and `LocalLMLabSDKInference`. The README has a section per risk: what it is, what the
SDK does about it, and where to watch it happen.

```swift
import Foundation
import FoundationModels
import LocalLMLabSDKCore                                          // ← SDK
import LocalLMLabSDKInference                                     // ← SDK (Inference)
import SwiftUI

let controlRoomModelRepo = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

/// A model the "host developer" ships pinned at build time. In a real app this is a
/// compile-time constant chosen at curation time (does the fork support the architecture; does
/// it pass our own trust check); here it's the default model at the commit `main` resolved to
/// on 2026-09-18. Shipped pins live in code, never in the pin store, and always beat a captured
/// (captured) pin for the same repo.
struct ShippedModel {
    let repoID: String
    let revision: String
}

let shippedModel = ShippedModel(
    repoID: controlRoomModelRepo, revision: "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3")

/// A second built-in model, shipped pinned at the version **this build** of the app was released with
/// — deliberately *not* the newest: its developer has since reviewed a newer commit and offers it
/// through an update feed (below), so the app can move to it **without a new app release**
/// (host-managed pin updates). `gemma-3-270m-it-4bit`'s last two
/// commits differ only in `config.json` (1648 -> 1653 bytes).
let smallModel = ShippedModel(
    repoID: "mlx-community/gemma-3-270m-it-4bit", revision: "9eba008f65cdc8aee60201be10dcd0e7858455ce")

/// What a *later* build of the app would ship for `smallModel` — used by "Simulate a newer app build".
let smallModelNextBuildRevision = "ff1143e3a10547c9f2129e94ca37059b096b23f4"

/// Stand-in for the **developer's update feed**: which commit of each built-in model the developer has
/// reviewed and vouches for. In a real app this is an authenticated request to the developer's server
/// (or an MDM push); the SDK has no feed and takes no view on where the commit comes from — the host
/// names an explicit commit hash, and *authenticating that answer is the host's job*. It is never
/// "latest main": an unreviewed version must not replace the vetted one.
enum HostUpdateFeed {
    static let vouchedCommits: [String: String] = [
        smallModel.repoID: "ff1143e3a10547c9f2129e94ca37059b096b23f4",
    ]

    static func latest() async throws -> [String: String] {
        try await Task.sleep(for: .milliseconds(400))   // "the network"
        return vouchedCommits
    }
}

@available(macOS 27.0, *)
@MainActor
final class ControlRoomModel: ObservableObject {
    // …knob state (@Published temperature, topP, seed, topK, minP, repetition…), gauges…

    private var mlx: MLXModelProvider?                            // ← SDK (Inference)
    private var lab: LocalLMLab?                                  // ← SDK
    private var residencyTask: Task<Void, Never>?

    private func log(_ event: ResidencyEvent) {                   // ← SDK (Inference)
        let stamp = Date().formatted(date: .omitted, time: .standard)
        switch event {
        case .warmed(let id):
            residencyLog.append("\(stamp)  ⬤ warmed  \(id)")
        case .evicted(let id, let reason):
            residencyLog.append("\(stamp)  ○ evicted \(id) (\(reason))")
        case .loadProgress(let id, let fraction):
            residencyLog.append("\(stamp)  ↻ load \(id) \(Int(fraction * 100))%")
        @unknown default:
            residencyLog.append("\(stamp)  ? unrecognized residency event")
        }
    }

    var options: SessionOptions {                                 // ← SDK
        SessionOptions(                                           // ← SDK
            effort: suppressThinking ? .off : nil,
            temperature: temperature,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            seed: useFixedSeed ? UInt64(seed) : nil,
            topK: topK > 0 ? Int(topK) : nil,
            minP: minP > 0 ? minP : nil,
            repetitionPenalty: useRepetitionPenalty ? repetitionPenalty : nil,
            repetitionContextSize: useRepetitionPenalty ? Int(repetitionContextSize) : nil,
            prefillStepSize: usePrefillStepSize ? Int(prefillStepSize) : nil)
    }

    private func run(_ prompt: String) async {
        guard let lab else { return }
        applyPairing()
        let pairedThisRun = pairingEnabled
        state = .working
        do {
            let currentOptions = options
            let session = try lab.makeSession(route: .local, options: currentOptions)  // ← SDK
            let start = Date()
            var firstChunkAt: Date?
            var wordCount = 0
            for try await partial in session.languageModelSession.streamResponse(to: prompt) {  // ← SDK
                if firstChunkAt == nil, !partial.content.isEmpty { firstChunkAt = Date() }
                lastOutput = partial.content
                wordCount = partial.content.split(separator: " ").count
            }
            let elapsed = Date().timeIntervalSince(start)
            tokensPerSecond = elapsed > 0 ? Double(wordCount) / elapsed : nil
            if activePreset != nil, let rate = tokensPerSecond {
                if pairedThisRun { lastRateWithPairing = rate } else { lastRateWithoutPairing = rate }
            }
            repeatRate = Self.trigramRepeatRate(lastOutput)
            timeToFirstTokenMS = firstChunkAt.map { $0.timeIntervalSince(start) * 1000 }

            if let fixedSeed = currentOptions.seed {
                if let previous = previousRun, previous.prompt == prompt, previous.seed == fixedSeed {
                    deterministic = previous.output == lastOutput
                } else {
                    deterministic = nil
                }
                previousRun = (prompt: prompt, seed: fixedSeed, output: lastOutput)
            } else {
                previousRun = nil
                deterministic = nil
            }
            state = .ready
        } catch {
            state = .failed("Generation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Model selection & onboarding (excerpt)

    /// Captured pins live in the SDK's `MLXFilePinStore` — a JSON file in Application
    /// Support, outside the Hugging Face cache (whose `remove(_:)` wipes a repo's whole directory,
    /// `refs/` included). The provider reads it at download time and captures into it on first
    /// sight; this app does none of that by hand.
    private let pinStore = MLXFilePinStore()                      // ← SDK (Inference)
    /// Runtime advances of *shipped* pins (an update from the developer's feed) live here, each saved with
    /// the build-time pin it was made against — so an update survives a relaunch, but a newer app build
    /// (a different build-time pin) discards it and the developer's newer choice wins.
    private let managedPinStore = MLXFileManagedPinStore()        // ← SDK (Inference)

    // …
    /// Which kind of pin the active single model is on, if it can be updated here at all:
    /// - `.captured` — the user's own choice; the user decides, and the target is whatever `main` is now;
    /// - `.shipped` — a built-in model **the developer's feed vouches for**: the target is the commit
    ///   the feed names, never `main`. A shipped model the feed doesn't mention can't be updated here
    ///   (the recommended model and both pairs: a new app version moves them).
    var updatablePinSource: MLXPinSource? {                       // ← SDK (Inference)
        guard case .single(let repo) = activeLaunch, let pin = mlx?.effectivePin(for: repo) else { return nil }  // ← SDK (Inference)
        switch pin.source {
        case .captured: return .captured
        case .shipped: return HostUpdateFeed.vouchedCommits[repo] != nil ? .shipped : nil
        @unknown default: return nil
        }
    }

    /// A built-in model the developer's feed has already moved past what this build shipped.
    var activeIsRuntimeOverride: Bool {
        guard case .single(let repo) = activeLaunch else { return false }
        return mlx?.effectivePin(for: repo)?.isRuntimeOverride ?? false  // ← SDK (Inference)
    }

    /// What this app build shipped for the active model — the "back to the version this app shipped" target.
    var activeBuildTimeRevision: String? {
        guard case .single(let repo) = activeLaunch else { return nil }
        return mlx?.buildTimePin(for: repo)                       // ← SDK (Inference)
    }

    /// The `beforeSwitch` hook: the SDK has downloaded and verified the new version and is about to
    /// move the pin. Stop new runs, let the one in flight finish, then return.
    private func pauseInferenceForSwitch() async throws {
        inferencePaused = true
        onboardingLogLine("update downloaded and verified — pausing inference to switch")
        while state == .working { try await Task.sleep(for: .milliseconds(100)) }
    }

    func checkForPinUpdate() {
        guard pinUpdatable, !isPinUpdateBusy, let mlx, case .single(let repo) = activeLaunch else { return }
        pinUpdate = .checking
        let source = updatablePinSource
        Task {
            do {
                // A shipped model is only ever checked against a commit the developer's feed names —
                // the user's click triggers the check, the developer vouches for the version.
                let target: String? = source == .shipped ? try await HostUpdateFeed.latest()[repo] : nil
                let check = try await mlx.checkPinUpdate(repo, to: target)  // ← SDK (Inference)
                pinUpdate = check.isUpToDate ? .upToDate : .available(check)
                onboardingLogLine("update check \(repo): " + (check.isUpToDate ? "up to date" : "\(check.changes.count) file(s) differ"))
            } catch {
                pinUpdate = .failed(error.localizedDescription)
            }
        }
    }

    /// Moves the pin to `revision` (the checked-for latest, or the rollback target).
    private func movePin(to revision: String?, previous: String) {
        guard pinUpdatable, !isPinUpdateBusy, let mlx, case .single(let repo) = activeLaunch else { return }
        pinUpdate = .updating(0)
        Task {
            defer { inferencePaused = false }
            do {
                for try await event in mlx.updatePin(repo, to: revision, beforeSwitch: {  // ← SDK (Inference)
                    // Strong on purpose: this runs inside the update's own Task, which already holds the
                    // model, and the update is short-lived.
                    try await self.pauseInferenceForSwitch()
                }) {
                    switch event {
                    case .progress(_, _, let fraction): pinUpdate = .updating(fraction)
                    case .completed(let model):
                        activePins = [ActivePin(repo: repo, revision: model.resolvedRevision)]  // ← SDK
                        rollbackRevision = model.resolvedRevision == previous ? nil : previous  // ← SDK
                        onboardingLogLine("pin for \(repo): \(previous.prefix(12))… → \(model.resolvedRevision.prefix(12))…")  // ← SDK
                    @unknown default: break
                    }
                }
                refreshCapturedPins()
                refreshSnapshots()
                pinUpdate = .upToDate
            } catch {
                // Atomic: a failed update left the old pin and the old files exactly as they were.
                pinUpdate = .failed("\(error.localizedDescription) — still pinned to \(previous.prefix(12))…")
            }
        }
    }

    func refreshSnapshots() {
        guard let mlx else { snapshots = []; return }
        snapshots = activeRepos.flatMap { mlx.snapshots(for: $0) }  // ← SDK (Inference)
    }

    func removeSnapshot(_ snapshot: MLXCachedSnapshot) {          // ← SDK (Inference)
        guard let mlx else { return }
        do {
            let freed = try mlx.removeSnapshot(snapshot.repoID, revision: snapshot.revision)  // ← SDK (Inference)
            onboardingLogLine("removed \(snapshot.repoID)@\(snapshot.revision.prefix(12))… — freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        } catch {
            onboardingLogLine("could not remove that version: \(error.localizedDescription)")
        }
        refreshSnapshots()
    }

    /// Toy `MLXModelTrustPolicy`: the free-text picker is limited to
    /// mlx-community/*, plus the exact artifacts this app itself ships (a curated adapter lives
    /// in another namespace — a real host's allow-list would name it too).
    private struct AllowMLXCommunityOrShipped: MLXModelTrustPolicy {  // ← SDK (Inference)
        let shippedRepoIDs: Set<String>
        func evaluate(repoID: String) async -> MLXModelTrustDecision {
            repoID.hasPrefix("mlx-community/") || shippedRepoIDs.contains(repoID)
                ? .allow
                : .deny(reason: "this demo only allow-lists mlx-community/* and this app's shipped artifacts — try a different namespace to see it denied")
        }
    }

    /// A fresh provider every call, seeded from the persisted pin store exactly as it would be
    /// after an app relaunch. A speed pair's base and draft are one resident unit in the SDK, so the
    /// default `residentModelLimit` is enough — this used to pass 2 for a speed pair as a workaround.
    private func makeProvider(for launch: Launch) -> MLXModelProvider {  // ← SDK (Inference)
        return MLXModelProvider(                                  // ← SDK (Inference)
            pinnedRevisions: shippedPins(for: launch),            // ← SDK (Inference)
            supplyChainPolicy: MLXSupplyChainPolicy(              // ← SDK (Inference)
                verification: verificationEnabled ? .enabled : .disabled,
                trustPolicy: AllowMLXCommunityOrShipped(shippedRepoIDs: Set(allShipped.map(\.repoID))),
                cacheLimits: cacheCapEnabled
                    ? MLXCacheLimits(maxTotalCacheBytes: Int64(cacheCapMB * 1_000_000))  // ← SDK (Inference)
                    : .default),
            pinStore: pinStore,                                   // ← SDK (Inference)
            managedPinStore: managedPinStore)                     // ← SDK (Inference)
    }

    private func prepare(_ launch: Launch) async {
        let holdForAcknowledgement = isRedownloadFlow
        preps = launch.artifacts
        let provider = makeProvider(for: launch)
        var pins: [ActivePin] = []
        var source: PinSource = .shipped

        for index in preps.indices {
            let repo = preps[index].repoID
            guard ModelID(scheme: "mlx", rest: repo) != nil else {  // ← SDK
                preps[index].validate = .failed("\"\(repo)\" isn't a valid repo id — expected namespace/name")
                return
            }

            // 1. validate — an adapter repo has no model config.json, so the architecture check
            // doesn't apply; the trust policy still runs, at download.
            if preps[index].isAdapter {
                preps[index].validate = .done("adapter repo — no architecture check; trust policy applies at download")
            } else {
                preps[index].validate = .running
                do {
                    let result = try await provider.validate(repo)  // ← SDK (Inference)
                    if let stage = result.failedStage {           // ← SDK
                        preps[index].validate = .failed("failed at .\(stage.rawValue) — \(result.detail ?? "")")
                        onboardingLogLine("validate \(repo): failed at .\(stage.rawValue)")
                        return
                    }
                    preps[index].validate = .done(result.detail ?? "passed")
                    onboardingLogLine("validate \(repo): passed")
                } catch {
                    preps[index].validate = .failed(error.localizedDescription)
                    return
                }
            }

            // 2. download (a cache hit completes immediately)
            // Where a pin stands *before* this download: a captured pin means this is a reuse, none
            // means the download itself is about to capture one.
            let priorPin = provider.effectivePin(for: repo)       // ← SDK (Inference)
            preps[index].download = .running
            preps[index].progress = 0
            var revision: String?
            do {
                for try await event in provider.download(repo) {  // ← SDK (Inference)
                    switch event {
                    case .progress(_, _, let fraction):
                        preps[index].progress = fraction
                    case .completed(let model):
                        revision = model.resolvedRevision         // ← SDK
                    @unknown default:
                        break
                    }
                }
            } catch {
                preps[index].progress = nil
                preps[index].download = .failed(error.localizedDescription)
                onboardingLogLine("download \(repo) failed: \(error.localizedDescription)")
                return
            }
            preps[index].progress = nil
            guard let revision else {
                preps[index].download = .failed("download finished without a resolved revision")
                return
            }
            preps[index].download = .done("verified" + (verificationEnabled ? "" : " (hash check off)"))

            // 3. pin — the provider applied and (for an unpinned repo) captured it during the
            // download; here we just confirm what landed matches, and say where it came from.
            preps[index].pin = .running
            guard let pin = provider.effectivePin(for: repo) else {  // ← SDK (Inference)
                preps[index].pin = .failed("no pin was recorded for \(repo) — refusing to continue")
                onboardingLogLine("no pin for \(repo) after download")
                return
            }
            guard revision == pin.revision else {
                preps[index].pin = .failed(
                    "resolved \(revision.prefix(12))… but pinned \(pin.revision.prefix(12))…")
                onboardingLogLine("pin mismatch for \(repo) — refusing to continue")
                return
            }
            switch pin.source {
            case .shipped:
                preps[index].pin = .done("verified against shipped pin \(revision.prefix(12))…")
                onboardingLogLine("pinned \(repo)@\(revision.prefix(12))… (shipped pin verified)")
            case .captured:
                let isNew = priorPin == nil
                source = isNew ? .captured : .reused
                preps[index].pin = .done(
                    isNew ? "captured \(revision.prefix(12))… → pin store" : "reused pin \(revision.prefix(12))…")
                onboardingLogLine(
                    "pinned \(repo)@\(revision.prefix(12))… (\(isNew ? "new pin captured" : "existing pin honored"))")
            @unknown default:
                preps[index].pin = .done("pinned at \(revision.prefix(12))…")
            }
            pins.append(ActivePin(repo: repo, revision: revision))
        }

        refreshCapturedPins()
        if holdForAcknowledgement {
            pendingActivation = PendingActivation(provider: provider, launch: launch, pins: pins, source: source)
        } else {
            activate(provider: provider, launch: launch, pins: pins, source: source)
        }
    }

    private func activate(provider: MLXModelProvider, launch: Launch, pins: [ActivePin], source: PinSource) {  // ← SDK (Inference)
        guard let id = ModelID(scheme: "mlx", rest: launch.baseRepo) else { return }  // ← SDK
        residencyTask?.cancel()
        residencyLog.removeAll()
        resetGauges()
        mlx = provider
        let newLab = LocalLMLab(configuration: .init(providers: [provider]))  // ← SDK
        newLab.models.route(.local, to: id)                       // ← SDK
        lab = newLab
        activeLaunch = launch
        activeRepo = launch.baseRepo
        activePins = pins
        pinSource = source
        let stream = provider.residencyEventStream                // ← SDK (Inference)
        residencyTask = Task { [weak self] in
            guard let stream else { return }
            for await event in stream {
                self?.log(event)
            }
        }
        switch launch {
        case .single:
            activePreset = nil
            suggestedPrompt = nil
        case .pairing(let preset):
            activePreset = preset
            applyPresetDefaults(preset)
        }
        pinUpdate = .idle
        rollbackRevision = nil
        refreshSnapshots()
        pairingEnabled = false
        lastRateWithoutPairing = nil
        lastRateWithPairing = nil
        applyPairing()
        state = .idle
        phase = .ready
    }

    /// Re-applied on every Run — the live on/off switch.
    private func applyPairing() {
        guard let mlx, let preset = activePreset else { return }
        switch preset.kind {
        case .speedHelper(let numDraftTokens):
            mlx.pairDraftModel(                                   // ← SDK (Inference)
                pairingEnabled
                    ? SpeculativeDecodingSpec(draftRepoID: preset.companion.repoID, numDraftTokens: numDraftTokens)  // ← SDK (Inference)
                    : nil,
                with: preset.base.repoID)
        case .adapter:
            mlx.pairAdapter(                                      // ← SDK (Inference)
                pairingEnabled ? AdapterSpec(source: .huggingFace(repoID: preset.companion.repoID)) : nil,  // ← SDK (Inference)
                with: preset.base.repoID)
        }
    }
    // …
}
```

**Tally**: of the excerpt's SDK-facing lines, 47 carry a marker — and the *shape* is more useful than the count. The
supply-chain policy is **one argument** to `MLXModelProvider` (`supplyChainPolicy:`) plus a small protocol
conformance; pinning is **three** (`pinnedRevisions:`, `pinStore:`, `managedPinStore:`); an update is **one** call
(`updatePin`) whose `beforeSwitch` closure is the only thing the host writes to keep it safe; cleanup is **two**
(`snapshots`, `removeSnapshot`); a pairing is **one** call per kind. Everything else is the host's own: the update feed
and how it is authenticated, the pause loop (`pauseInferenceForSwitch` refuses new runs and waits for the running one),
the allow-list, the knob state, and the gauges. Compare [`components-updates-demo`](#examplescomponents-updates-demo),
which puts a ready-made `Components` UI on the same flows, and [`vistanova`](#examplesvistanova), which shows the
minimal end (one `pinnedRevisions:` and nothing else). The one thing worth copying verbatim is
`AllowMLXCommunityOrShipped`: an allow-list keyed on `mlx-community/` plus the exact artifacts the app itself ships,
because a curated adapter lives in a different namespace.
