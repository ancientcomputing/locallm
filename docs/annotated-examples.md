# Annotated example source

The full source of every reference app, with every line that actually touches the SDK marked
`// ← SDK` (Core), `// ← SDK (Inference)` (the MLX runtime — `code-buddy`, `repo-qa-local`,
`workspace-buddy-local`, `os-matrix`, and `aiql`), `// ← SDK (Remote)` (online providers —
`model-switch`), or `// ← Components`. Everything else is ordinary SwiftUI/Foundation — the point
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

## `examples/plate-today/Sources/PlateToday/PlateTodayApp.swift`

Demonstrates `Core` directly: Calendar/Reminders connectors, the MCP client, Keychain-backed OAuth
— no `Components` involved. This is "Path B" — a hand-written `Tool` adapter per connector; see
[`plate-today-tools`](#examplesplate-today-toolssourcesplatetodaytoolsplatetodaytoolsappswift)
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
            case .success(let text): return text
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
// Apple Event without SwiftUI creating anything — same fix LocalLM Lab's own chooser window
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
        // truth for how tall the window can grow. Same reasoning as LocalLM Lab's own chooser
        // windows.
        .windowResizability(.contentMinSize)
        // Without this, WindowGroup matches every external event by default and ALSO opens a new
        // scene for the same platetoday:// callback AppDelegate already handles above — matching
        // nothing here makes AppDelegate the only handler, same as LocalLM Lab's own chooser app.
        .handlesExternalEvents(matching: [])
    }
}
```

**Tally**: of ~230 lines of actual code (excluding comments/blank lines), roughly a dozen touch the
SDK directly — everything else is ordinary SwiftUI state/view code and FoundationModels session
setup that would look the same regardless of where the tools' data comes from.

## `examples/plate-today-tools/Sources/PlateTodayTools/PlateTodayToolsApp.swift`

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

    let manager = MCPServerManager()                                  // ← SDK
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

## `examples/repo-qa/Sources/RepoQA/main.swift`

A third, deliberately different shape: a plain command-line tool, not a signed GUI `.app` — MCP
touches nothing TCC-gated, so there's no permission prompt to need a real bundle for. Builds an
`MCPTool` for every tool a server offers, in a loop, entirely from that server's own live schema.

```swift
// Repo Q&A — a third reference app, deliberately different in shape from plate-today/
// plate-today-tools: a plain command-line tool, not a signed GUI .app. MCP network calls need no
// macOS permission, so a bare `swift run` binary works end to end.
//
// Narrative: ask a free-form question about any public GitHub repository's own documentation,
// answered by Apple's on-device model calling Deepwiki's real hosted MCP server, no auth, no API
// key — MCPTool built at runtime directly from Deepwiki's own JSON Schema, no hand-written
// Arguments struct for any of its three tools.

import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK

@available(macOS 26.0, *)
@MainActor
func run() async {
    let arguments = CommandLine.arguments.dropFirst()
    guard let repoName = arguments.first, !repoName.isEmpty else {
        FileHandle.standardError.write(Data("usage: swift run RepoQA <owner/repo> [question]\n".utf8))
        exit(1)
    }
    let question = arguments.dropFirst().joined(separator: " ")
    let effectiveQuestion = question.isEmpty ? "What does this repository do, in a couple sentences?" : question

    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        print("On-device model unavailable: \(model.availability)")
        return
    }

    // No requestAccess() call anywhere in this file — MCP is the one connector type that was
    // never TCC-gated, so there's no permission step to request before connecting. Contrast with
    // plate-today-tools' requestConnectorAccess(), needed there specifically because Calendar/
    // Reminders are gated and this file's equivalent tools aren't.
    let manager = MCPServerManager()                                  // ← SDK
    let connectResult = await manager.addServer(                      // ← SDK
        url: URL(string: "https://mcp.deepwiki.com/mcp")!,
        displayName: "Deepwiki"
    )
    guard case .success(let state) = connectResult else {
        print("Could not connect to Deepwiki: \(connectResult)")
        return
    }

    // Builds a Tool for every tool Deepwiki actually offers, from its own live schema — nothing
    // here names "ask_question" specifically, or knows its argument shapes in advance. A tool
    // whose schema doesn't build (MCPTool's init throws) is skipped rather than aborting the
    // whole run.
    var tools: [any Tool] = []
    for descriptor in state.tools {
        do {
            tools.append(try MCPTool(descriptor: descriptor, manager: manager))  // ← SDK (Path A)
        } catch {
            print("Skipping \(descriptor.name): \(error)")
        }
    }
    guard !tools.isEmpty else {
        print("Deepwiki didn't offer any usable tools.")
        return
    }

    let session = LanguageModelSession(tools: tools) {
        "You answer questions about GitHub repositories using the documentation tools available to you. Always ground your answer in what the tools actually return — don't answer from general knowledge if a tool call would give a more specific, current answer."
    }

    let prompt = "Regarding the GitHub repository \"\(repoName)\": \(effectiveQuestion)"
    do {
        let response = try await session.respond(to: prompt)
        print(response.content)
    } catch {
        print("Error: \(await GenerationErrorDescription.describe(error))")  // ← SDK
    }
}

if #available(macOS 26.0, *) {
    await run()
} else {
    print("Requires macOS 26 or later.")
}
```

**Tally**: of ~70 lines of actual code, five touch the SDK — this is the entire surface area
needed to go from nothing to "the on-device model calling a real, remote MCP tool it's never seen
before." No `Arguments` struct, no `Tool`-conforming type of this app's own — `ask_question`'s
real schema (including a `repoName: string | string[]` union JSON Schema doesn't have a single
Swift equivalent for) converts automatically, degrading the union to a plain string leaf per
`MCPToolAdapter`'s documented behavior for constructs past the common case.

## `examples/workspace-buddy/Sources/WorkspaceBuddy/WorkspaceBuddyApp.swift`

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

## `examples/components-demo/Sources/ComponentsDemo/ComponentsDemoApp.swift`

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

## `examples/code-buddy/Sources/CodeBuddy/main.swift`

The fullest **model-layer** example (see also
[`repo-qa-local`](#examplesrepo-qa-localsourcesrepoqalocalmainswift) for the minimal one, and
[`workspace-buddy-local`](#examplesworkspace-buddy-localsourcesworkspacebuddylocalworkspacebuddylocalappswift)
for the sandboxed one, both annotated below), and one of several linking a second binary, `LocalLMLabSDKInference.xcframework`
(the MLX runtime). Lines that touch it are marked `// ← SDK (Inference)`; `// ← SDK` is Core as
elsewhere. A CLI coding agent: point it at a repo, give it a task (one-shot) or omit the task to
get a `>>` loop over one persistent session, and it downloads an open-weight MLX model on first
run, then drives Core's Workspace tools + host `Process` tools + (auto) MCP tools through a routed
`LocalLMLabSession`. Ctrl-C cancels the running turn — reaching the `Process` tools so a child
`swift test` is terminated, not orphaned — and quits from an idle prompt. See
[`sdk-guide.md` §6a](sdk-guide.md#6a-the-model-layer-local-models-routing-sessions) for the prose.

```swift
import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKInference                                         // ← SDK (Inference)

// code-buddy — a minimal coding agent on the LocalLM Lab SDK.
//   code-buddy [--route heavy|light] [--heavy <repo>] [--light <repo>]
//              [--test-cmd "<cmd>"] [--no-mcp] [--no-verbose] <workspace-dir> [task...]
// With a task: run it and stop. Without: a >> loop over one session until `quit` / Ctrl-D.

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
    // (the memory story for a constrained Mac), a LocalLMLab bundling it with Apple's on-device
    // provider as fallback, and two named routes.
    let mlx = MLXModelProvider(residentModelLimit: 1)                 // ← SDK (Inference)
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

    // Tools: Core's ready-made Workspace tools (Path A) …
    var tools: [any Tool] = [
        WorkspaceTreeTool(root: root),                               // ← SDK
        SearchWorkspaceTool(root: root),                             // ← SDK
        ReadWorkspaceFileTool(root: root),                           // ← SDK
        ReadFileRangeTool(root: root),                               // ← SDK
        ApplyPatchTool(root: root),                                  // ← SDK
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
        change the code … Make the smallest change that solves the task. After editing, run the \
        tests. Explain what you changed and why.
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
            case .toolCallStarted(_, let name): if opts.verbose { note("  → \(name)") }
            case .toolCallFinished(_, let name, let failed): if opts.verbose { note("  \(failed ? "✗" : "✓") \(name)") }
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
        if interrupt.fire() { note("\nquitting…"); session.cancel(); exit(130) }   // ← SDK
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

**Tally**: of ~160 lines of actual code, ~22 touch the SDK — and that ~22 is the *entire* model
layer: pick providers, name routes, preflight/download, make a session, stream it, watch
`.events`. Everything MLX-specific is four lines (`MLXModelProvider`, `validate`, `download`,
and the import); use `ClaudeModelProvider` from `LocalLMLabSDKClaude` instead (a macOS-27
target — see `sdk-guide.md` §1a) and the rest of the file is unchanged.
`RouteName` is the only new type the caller names by hand. The REPL loop and Ctrl-C handling add
no SDK surface — one persistent `LocalLMLabSession` spans every turn, and `session.cancel()` /
Task cancellation is the whole cancel story.

## `examples/code-buddy/Sources/CodeBuddy/ProcessTools.swift`

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
        "Runs a read-only git command in the workspace. Allowed: \(Self.readOnlySubcommands.sorted().joined(separator: ", ")). Mutating commands are refused — make edits with applyPatch instead."
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

## `examples/repo-qa-local/Sources/RepoQALocal/main.swift`

The **minimal** model-layer example: [`repo-qa`](#examplesrepo-qasourcesrepoqamainswift) above,
with the ~20 lines that swap Apple's on-device model for an open-weight MLX model you download and
run locally. The Deepwiki / `MCPTool` half is a verbatim copy of `repo-qa`'s — diff the two to see
exactly what adopting the model layer costs. One of several examples linking
`LocalLMLabSDKInference` (`// ← SDK (Inference)`); `// ← SDK` is Core as elsewhere.

```swift
// repo-qa-local — repo-qa, but the answer comes from an open-weight model you download and run
// locally (via MLX) instead of Apple's on-device model. The Deepwiki / MCPTool half is a
// verbatim copy of repo-qa's; the only difference is the ~20 lines that set up the 1.0 model
// layer and swap `LanguageModelSession(tools:)` for `lab.makeSession(route:tools:)`.
//
//   swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
//   swift run RepoQALocal --model mlx-community/Qwen2.5-3B-Instruct-4bit apple/swift-nio "..."
//   swift run RepoQALocal --apple anthropics/claude-code "..."  # route to Apple's on-device model instead

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
        note("usage: swift run RepoQALocal [--model <hf-repo>] [--apple] <owner/repo> [question]")
        exit(1)
    }
    let question = rest.dropFirst().joined(separator: " ")
    let effectiveQuestion = question.isEmpty ? "What does this repository do, in a couple sentences?" : question

    // --- the model layer: one MLX provider, Apple's on-device model as an alternative, one route ---
    let mlx = MLXModelProvider(residentModelLimit: 1)                 // ← SDK (Inference)
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
    // claude-code in one call), which MCPTool can't know from the schema — that curation is the
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

    // The one line that changes from repo-qa: lab.makeSession(route:tools:) instead of
    // LanguageModelSession(tools:) — same FoundationModels session underneath, just backed by
    // whichever model the route points at. includeMCPTools: false because this app passes its
    // MCPTools in by hand above rather than going through lab.mcp.
    let instructions = "You answer questions about GitHub repositories using the documentation tools available to you. Always ground your answer in what the tools actually return — don't answer from general knowledge if a tool call would give a more specific, current answer."
    let session: LocalLMLabSession                                   // ← SDK
    do {
        session = try lab.makeSession(route: .local, tools: tools, instructions: instructions, includeMCPTools: false)   // ← SDK
    } catch {
        note("makeSession failed: \(error)"); exit(1)
    }

    let prompt = "Regarding the GitHub repository \"\(repoName)\": \(effectiveQuestion)"
    do {
        // Plain FoundationModels LanguageModelSession underneath — respond/streamResponse as usual.
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

**Tally**: of ~75 lines of actual code, ~14 touch the SDK — and everything below the
`--- everything below is repo-qa, unchanged ---` marker is character-for-character `repo-qa`
except the one `lab.makeSession` line. The model layer itself is ~7 lines
(`MLXModelProvider` / `LocalLMLab` / `ModelID` / `route` / `availability` / `validate` /
`download`); `--apple` proves the same route can point at Apple's on-device model with no other
change.

## `examples/workspace-buddy-local/Sources/WorkspaceBuddyLocal/WorkspaceBuddyLocalApp.swift`

[`workspace-buddy`](#examplesworkspace-buddysourcesworkspacebuddyworkspacebuddyappswift) above —
same folder-picker, same security-scoped bookmark, same `WorkspaceTools` — but the model is an
open-weight MLX model routed through the 1.0 model layer. It is the one example that runs the
model layer **inside App Sandbox**, so it also needs `com.apple.security.network.client` (to fetch
the weights on first run) on top of `workspace-buddy`'s `files.user-selected.read-write`; the
model downloads into this app's own sandbox container. One of several examples linking
`LocalLMLabSDKInference`. The `FolderAccess` enum is verbatim from `workspace-buddy` and is
elided here — see that section above.

```swift
import Foundation
import FoundationModels
import LocalLMLabSDKCore                                              // ← SDK
import LocalLMLabSDKInference                                         // ← SDK (Inference)
import SwiftUI

// The model this app routes to. Any MLX-format Hugging Face repo — see docs/tested-models.md.
let workspaceModelRepo = "mlx-community/Qwen3-8B-4bit"

// MARK: - FolderAccess { pickFolder / resolveBookmarkedFolder / withFolderAccessAsync }
//   — verbatim from workspace-buddy (docs/sdk-guide.md §8); see that section above. Elided here.

// MARK: - View model

@available(macOS 26.0, *)
@MainActor
final class WorkspaceBuddyLocalModel: ObservableObject {
    enum State {
        case idle
        case downloadingModel(Double)   // 0…1
        case working
        case ready(String)
        case failed(String)
    }

    @Published private(set) var folderURL: URL?
    @Published private(set) var state: State = .idle

    // The model layer: an MLX provider (one model resident at a time), Apple's on-device model
    // kept as a fallback, and one named route pointing at the MLX model.
    private let mlx = MLXModelProvider(residentModelLimit: 1)         // ← SDK (Inference)
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

        // 2. Run the request, exactly as workspace-buddy does — only the session-creation line differs.
        state = .working
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
                // The only line that differs from workspace-buddy: lab.makeSession(route:) instead
                // of LanguageModelSession(tools:). includeMCPTools: false — this app has no MCP.
                let session = try self.lab.makeSession(              // ← SDK
                    route: .local, tools: tools, instructions: instructions, includeMCPTools: false
                )
                let response = try await session.languageModelSession.respond(to: request)   // ← SDK
                return response.content
            } catch {
                return "Error: \(await GenerationErrorDescription.describe(error))"   // ← SDK
            }
        }

        guard let result else {
            state = .failed("Could not access the workspace folder — try choosing it again.")
            return
        }
        state = .ready(result)
    }
}

// MARK: - UI (ordinary SwiftUI — model-repo label, folder path, a text field, a Go button, a
// download-progress bar, a result view. No SDK touchpoints; elided.)

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

**Tally**: of ~90 lines of actual code (the verbatim `FolderAccess` enum and the plain-SwiftUI UI
section both elided), ~13 touch the SDK. Against `workspace-buddy`'s four (four Tool
instantiations + one error formatter), the delta is entirely the model layer: the provider/lab/
route setup, the first-run `availability` check, and the `validate` + `download` progress loop.
The `makeSession` call and the four `WorkspaceTools` are identical to `workspace-buddy`'s — the
sandbox changes nothing in the code, only the entitlements.

## `examples/os-matrix/Sources/OSMatrix/main.swift`

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
//   swift run OSMatrix
//   swift run OSMatrix --download mlx-community/Qwen3-4B-4bit   # macOS 27 only; ~2–5 GB

@MainActor
func run() async throws {
    let args = CommandLine.arguments
    let downloadRepo: String? = args.firstIndex(of: "--download").flatMap { i in
        i + 1 < args.count ? args[i + 1] : nil
    }

    // ── register what the running OS supports ──
    // SystemModelProvider works on macOS 26 and 27. The rest need macOS 27, so they go in one
    // #available block. Everything AFTER this line is identical on both OSes.
    var providers: [any ModelProvider] = [SystemModelProvider()]      // ← SDK
    if #available(macOS 27, *) {
        providers.append(PCCModelProvider())                          // ← SDK
        providers.append(MLXModelProvider())                          // ← SDK (Inference)
    }
    let lab = LocalLMLab(configuration: .init(providers: providers))  // ← SDK
    lab.models.route("chat", to: .system)                             // ← SDK

    // ── model availability table ──
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

    // ── `--download` — a feature that only exists on macOS 27 ──
    if let repo = downloadRepo {
        guard #available(macOS 27, *), !lab.models.downloadableProviders.isEmpty else {   // ← SDK
            print("\n--download needs macOS 27 (open-weight models run via MLX, which is macOS 27+).")
            return
        }
        print("\nDownloading \(repo) from Hugging Face — fetches the weights (typically 2–5 GB)…")
        let installed = try await lab.models.startDownload(repo)      // ← SDK  (resolves once weights are on disk)
        let size = installed.sizeBytes.map { " (\($0 / 1_000_000) MB)" } ?? ""
        print("Done: \(installed.id.rawValue)\(size). It's now .available — route a session to it:")
        print("  lab.models.route(\"chat\", to: ModelID(\"\(installed.id.rawValue)\")!)")
        print("  let session = try lab.makeSession(route: \"chat\")")
        return
    }

    // ── connector tools that work on both OSes ──
    let tools: [any Tool] = [ClockTool(), WeatherTool()]              // ← SDK

    // ── the same call, identical on 26 and 27 ──
    let session = try lab.makeSession(route: "chat", tools: tools,    // ← SDK
        instructions: "You have getCurrentTime and getWeather tools. Use them; be concise.")
    print("\nAsking the on-device model (with tools)…")
    let answer = try await session.respond(to: "What time is it, and what's the weather in Tokyo?")   // ← SDK
    print("→ \(answer)")

    if #available(macOS 27, *), !lab.models.downloadableProviders.isEmpty {   // ← SDK
        print("\nOpen-weight (MLX) models are available on macOS 27. Download one with:")
        print("  swift run OSMatrix --download mlx-community/Qwen3-4B-4bit")
        print("In code that's `try await lab.models.startDownload(\"<hf-repo-id>\")`; `lab.models.downloads` is the observable a picker binds to for a progress bar.")
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

**Tally**: of ~90 lines of actual code, ~15 touch the SDK — and every one of the OS-conditional
lines is inside the single `if #available(macOS 27, *)` block at the top. `describe(_:)` is a
plain `switch` over `ModelAvailability`; `.requiresOS` is the one case a 26-aware app has to
handle that a 27-only app never sees. No `#if canImport` anywhere — `LocalLMLabSDKInference` is
linked unconditionally and its 27-only providers just aren't appended on 26.

## `examples/model-switch/Sources/ModelSwitch/AppModel.swift`

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
    // across a macOS-26 chooser + a 27-only helper round-trips this through a serve op instead.
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

The `~30 lines of glue` the section above keeps referring to is one file:

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
base URLs, auth, presets — is data inside `RemoteProviderConfig`, built once in the ~40-line
`ProviderGlue.swift`. `probe(for:)` is the one call that hits the network without spending a
token, and it's what the settings panel's **Test connection** button runs.

## `examples/model-switch/Sources/ModelSwitch/ModelSwitchApp.swift`

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

## `examples/aiql/Sources/AIQL/AIQLApp.swift`

The **`FileBackedTool` + "AIQL" data-verb** showcase (`sdk-guide.md`
[§8b](sdk-guide.md#8b-filebackedtool--the-aiql-data-verbs-a-mechanical-mcp-dataset--csv-pipeline)):
type a local model, an MCP data source, and a plain-English request; the app pulls the dataset
into a file (so the raw payload never enters the model's context) and runs it through
`describeJson → jsonToCsv → filter/sort/select` to a CSV. The model only names the operations and
the columns — every row-level step is an SDK primitive, so there's nothing for an 8–14B model to
fabricate. Links `LocalLMLabSDKInference` for the MLX model; `FolderAccess` is verbatim from
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

    @Published var modelRepo = "mlx-community/Qwen3-8B-4bit"
    @Published var serverURLString = "https://econ-index.mcp.claude.com/mcp"
    @Published var request = ""
    @Published private(set) var folderURL: URL?
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var steps: [String] = []

    private let manager = MCPServerManager()                          // ← SDK
    private let mlx = MLXModelProvider(residentModelLimit: 1)         // ← SDK (Inference)
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
            try? FileBackedTool.mcp(descriptor: $0, manager: manager, root: root, inlineCharacterLimit: 8_000)   // ← SDK  — payload → file, receipt → model
        }
        guard !dataTools.isEmpty else { return .failed("Couldn't read that server's tools — its data format isn't supported yet.") }

        // The data verbs: each takes root at init, reads one workspace file, writes a CSV, returns
        // a one-line receipt — the row data never reaches the model.
        var tools: [any Tool] = dataTools
        tools.append(DescribeJSONTool(root: root))                   // ← SDK
        tools.append(CSVInfoTool(root: root))                        // ← SDK
        tools.append(JSONToCSVTool(root: root))                      // ← SDK
        tools.append(SelectColumnsTool(root: root))                  // ← SDK
        tools.append(FilterRowsTool(root: root))                     // ← SDK
        tools.append(SortRowsTool(root: root))                       // ← SDK
        tools.append(ConcatRowsTool(root: root))                     // ← SDK

        let instructions = """
        You turn a data question into a fixed sequence of tool calls that ends with a CSV file. \
        You never write row data yourself …
        1. Pick the ONE data tool whose result answers the question and call it with `saveAs` set \
           to "raw/data.json". … use `saveAsAppend: true` for each further page.
        2. describeJson  path "raw/data.json".
        3. jsonToCsv  inputPath "raw/data.json", outputPath "all.csv": rowsAt = the array path, \
           columns = {header, path} per field.
        4. Apply ONLY the refinements the question asks for → sortRows with `limit` for "top N", \
           filterRows for "only/without/where". Do NOT add a filter or sort it didn't ask for.
        5. selectColumns → "out.csv", exactly the fields the question named.
        6. csvInfo  path "out.csv", then reply with the column names and row count. Don't print rows.
        """  // (full prompt in the source)

        let session: LocalLMLabSession                               // ← SDK
        do {
            session = try lab.makeSession(route: .local, tools: tools, instructions: instructions, includeMCPTools: false)   // ← SDK
        } catch {
            return .failed("Couldn't start the model: \(error.localizedDescription)")
        }
        defer { session.cancel() }                                   // ← SDK

        // Friendly progress from the session's tool-call side-channel.
        let stepTask = Task { @MainActor in
            for await event in session.events {                      // ← SDK
                switch event {
                case .toolCallStarted(_, let name):
                    self.step(Self.friendlyStep(for: name))
                case .toolCallFinished(_, let name, let failed) where failed:
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
/ `route` / `availability` / `validate` / `download` / `makeSession`). Everything new here is the
pipeline: `FileBackedTool.mcp(descriptor:manager:root:)` wraps each MCP data tool so its payload
lands in a file instead of the model's context, and the eight data-verb `Tool`s
(`describeJson` / `jsonToCsv` / `selectColumns` / `filterRows` / `sortRows` / `concatRows` /
`csvInfo`) each do one mechanical CSV transform and return only a receipt. The `instructions`
string doing the orchestration is the real work of this example — the SDK surface it drives is
about a dozen one-line `Tool` instantiations plus `WorkspaceAccess` to read the result back.
