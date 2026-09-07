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
import LocalLMLabSDKCore
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
        let access = await CalendarAccess.requestAccess()
        guard access.granted else { return access.error ?? "Calendar access not granted." }

        // upcomingEvents(days:) is "from now through the next N days," not "all of today
        // including anything already past" — CalendarAccess's own semantics, shared with
        // LocalLM Lab itself, rather than plate-today inventing its own start-of-day window.
        let events = CalendarAccess.upcomingEvents(days: 1)
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
        let access = await RemindersAccess.requestAccess()
        guard access.granted else { return access.error ?? "Reminders access not granted." }

        let reminders = await RemindersAccess.upcomingReminders(days: 1)
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
        let access = await Connectors.requestAccess(.location)
        guard access.granted else { return access.error ?? "Location access not granted." }

        guard let location = await LocationAccess.shared.currentLocation() else {
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

// MARK: - Contacts tool (via Core's ContactsAccess connector)

#if PLATETODAY_INCLUDE_CONTACTS
// Same "not shipped as part of Core, permission-gated so the app decides how to expose it"
// reasoning as TodaysLocationTool above. Mirrors LocalLM Lab's own SearchContactsTool — same
// name, description, and read-only guarantee, minus that tool's socket round-trip to a separate
// process (plate-today is single-process, so it calls ContactsAccess directly).
//
// Build-time opt-in, default off — unlike Calendar/Reminders, Contacts isn't part of plate-
// today's actual "what's on my plate today" narrative (there's no daily contacts digest), so it
// only makes sense as an on-demand lookup the model reaches for if a person's name comes up
// (e.g. enriching a calendar event's attendee) — not something to prompt for unconditionally.
// Also avoids an extra TCC prompt for anyone just trying the default build.
struct SearchContactsTool: Tool {
    let name = "searchContacts"
    let description = "Searches the user's Contacts by name and returns matching contacts — name, organization, phone numbers, and email addresses. Only call this when the user is explicitly asking to look up, find, or search for a person in their Contacts, or when enriching a calendar/reminder item that names a specific person. Read-only; cannot create, modify, or delete contacts."

    @Generable
    struct Arguments {
        @Guide(description: "The name (or partial name) to search for, e.g. \"Jane\" or \"Jane Smith\".")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let access = await Connectors.requestAccess(.contacts)
        guard access.granted else { return access.error ?? "Contacts access not granted." }

        let matches = ContactsAccess.search(query: arguments.query, limit: 10)
        if matches.isEmpty { return "No contacts found matching \"\(arguments.query)\"." }
        return matches.map { contact in
            var line = "- \(contact.name)"
            if let org = contact.organization, !org.isEmpty { line += " (\(org))" }
            if !contact.phoneNumbers.isEmpty { line += " — phone: \(contact.phoneNumbers.joined(separator: ", "))" }
            if !contact.emails.isEmpty { line += " — email: \(contact.emails.joined(separator: ", "))" }
            return line
        }.joined(separator: "\n")
    }
}
#endif

// MARK: - Todoist tool (via Core's MCP client)

struct TodoistTasksTool: Tool {
    let name = "getTodoistTasksDueToday"
    let description = "Retrieve the user's Todoist tasks due today"
    let manager: MCPServerManager
    let serverURL: URL

    // Zero-property Arguments is valid and correct for a no-input tool (proven by Core's
    // ClockTool) -- an earlier "unused placeholder" field here was a fragile workaround that
    // actively caused decode failures: FoundationModels sometimes calls a tool with genuinely
    // empty generated content when no argument makes sense, and a required-but-unused field then
    // fails to decode from that empty content.
    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let connectResult = await manager.addServer(url: serverURL, displayName: "Todoist")
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
            let result = await manager.callTool(
                server: state.id, tool: tool.name,
                arguments: ["startDate": .string("today"), "overdueOption": .string("exclude-overdue")]
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

    private let manager = MCPServerManager()
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
        manager.removeServer(MCPServerID(rawValue: todoistURL.absoluteString))
    }

    private func fetch() async {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            state = .failed("On-device model unavailable: \(model.availability)")
            return
        }

        var tools: [any Tool] = [
            ClockTool(),
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
        tools.append(WeatherTool())
        checks.append("the user's current location and today's weather there (getCurrentLocation, then getWeather with that place)")
        summarizeNote = ", including the weather"
        #endif
        #if PLATETODAY_INCLUDE_CONTACTS
        // Deliberately not added to `checks` — this is an on-demand enrichment tool (see
        // SearchContactsTool's own description), not a fourth thing to unconditionally check
        // every run the way calendar/reminders/Todoist are.
        tools.append(SearchContactsTool())
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
            state = .failed(await GenerationErrorDescription.describe(error))
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
            MCPOAuthRedirectListener.shared.handleRedirect(url)
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
        MCPOAuthFlow.redirectURI = "platetoday://oauth/callback"
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
