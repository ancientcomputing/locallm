// "What's on my plate today" — Tools edition. The exact same app as examples/plate-today (same
// UI, same prompt, same connectors), rebuilt on Core's ready-made FoundationModels Tools instead
// of hand-writing a Tool struct per connector. Diff this file against plate-today's
// PlateTodayApp.swift to see the "Path A vs Path B" difference described in
// docs/02-sdk-developer-guide.md §7a in actual code, not just prose — every place the two files
// diverge is called out below with a `DIFF FROM plate-today:` comment.
//
// SwiftUI app shape (not a bare CLI): launch -> request Calendar/Reminders/Todoist access on
// first run -> pull + synthesize -> show result -> Done closes the app. Packaged as a real signed
// .app bundle by build-and-sign.sh, same signing discipline as plate-today, for the same reason:
// a bare SwiftPM executable can't get TCC grants (no Info.plist/usage-description strings, no
// code signing).

import Foundation
import FoundationModels
import LocalLMLabSDKCore
import SwiftUI

// MARK: - Calendar, Reminders, Location, Contacts tools

// DIFF FROM plate-today: no TodaysEventsTool/TodaysRemindersTool/TodaysLocationTool/
// SearchContactsTool structs here at all. GetUpcomingEventsTool, GetUpcomingRemindersTool,
// GetCurrentLocationTool, and SearchContactsTool are Core types (CalendarTools.swift/
// RemindersTools.swift/LocationTools.swift/ContactsTools.swift) — instantiate them directly in
// fetch() below, same as ClockTool/WeatherTool always worked. That's the entire point of Path A:
// four fewer hand-written Tool structs, ~130 fewer lines, and the tool descriptions/argument
// names are the same ones LocalLM Lab's own app ships (title/date lookup, current*/new* naming,
// the Contacts given/family-name split) rather than this app's own, independently-written
// versions of the same ideas.
//
// One real behavioral difference this trades away, not just less code: plate-today's
// hand-written tools each call CalendarAccess.requestAccess()/RemindersAccess.requestAccess()/
// Connectors.requestAccess(...) LAZILY, the first time the model actually invokes that tool.
// Core's ready-made Tools don't — GetUpcomingEventsTool.call() goes straight to
// CalendarAccess.upcomingEvents(days:), no access check first, on the reasoning that Path A
// tools are meant to be composed into apps that already have their own permission-request flow
// (a settings screen, an onboarding step) rather than assuming "request on first use" is always
// the right UX. That means THIS app has to request access up front, before the tools are even
// built — see fetch() below.

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

    private let manager = MCPServerManager()
    private let todoistURL = URL(string: ProcessInfo.processInfo.environment["TODOIST_MCP_URL"] ?? "https://ai.todoist.net/mcp")!

    func start() {
        guard case .idle = state else { return }
        state = .fetching
        Task { await fetch() }
    }

    // Identical to plate-today's cleanUpBeforeQuit() — MCPServerManager/removeServer(_:) don't
    // change between Path A and Path B, only how the resulting tool gets built (see
    // buildTodoistTool below).
    func cleanUpBeforeQuit() {
        manager.removeServer(MCPServerID(rawValue: todoistURL.absoluteString))
    }

    // DIFF FROM plate-today: request access up front, before any Tool exists — see this file's
    // top-of-file comment for why Path A's ready-made Tools need this instead of requesting
    // lazily inside call(). Connectors.requestAccess(_:) is the same unified facade
    // docs/02-sdk-developer-guide.md §7's first example uses; CalendarAccess/RemindersAccess also
    // expose their own .requestAccess() directly, used interchangeably here just to show both
    // spellings work.
    private func requestConnectorAccess() async -> String? {
        let calendarAccess = await CalendarAccess.requestAccess()
        guard calendarAccess.granted else { return calendarAccess.error ?? "Calendar access not granted." }
        let remindersAccess = await RemindersAccess.requestAccess()
        guard remindersAccess.granted else { return remindersAccess.error ?? "Reminders access not granted." }
        #if PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER
        let locationAccess = await Connectors.requestAccess(.location)
        guard locationAccess.granted else { return locationAccess.error ?? "Location access not granted." }
        #endif
        #if PLATETODAYTOOLS_INCLUDE_CONTACTS
        let contactsAccess = await Connectors.requestAccess(.contacts)
        guard contactsAccess.granted else { return contactsAccess.error ?? "Contacts access not granted." }
        #endif
        return nil
    }

    // DIFF FROM plate-today's TodoistTasksTool: that hand-written tool pinned specific
    // arguments on every call (startDate: "today", overdueOption: "exclude-overdue") regardless
    // of what the model asked for, and gave the tool its own curated name/description
    // ("getTodoistTasksDueToday") independent of the real server. MCPTool exposes the tool
    // exactly as Todoist's own server defines it — real name ("find-tasks-by-date"), real
    // description, real full argument schema (built at runtime from the server's JSON Schema via
    // FoundationModels' DynamicGenerationSchema) — and leaves every argument, including
    // overdueOption, up to the model. That's a real tradeoff, not just less code: Path A here
    // gives up the "always exclude overdue" guarantee plate-today pins by construction, in
    // exchange for zero hand-maintained argument-shaping code. The prompt below asks explicitly
    // for "excluding anything overdue" to compensate — a instructions-level fix, not a
    // code-level one, since nothing here can force the model's argument choice the way pinning
    // it in Swift did.
    private func buildTodoistTool() async -> (any Tool)? {
        let connectResult = await manager.addServer(url: todoistURL, displayName: "Todoist")
        guard case .success(let state) = connectResult else { return nil }
        guard let descriptor = state.tools.first(where: { $0.name == "find-tasks-by-date" }) else { return nil }
        return try? MCPTool(descriptor: descriptor, manager: manager)
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

        // DIFF FROM plate-today: GetUpcomingEventsTool()/GetUpcomingRemindersTool() straight from
        // Core, no local struct definitions above to instantiate instead.
        var tools: [any Tool] = [
            ClockTool(),
            GetUpcomingEventsTool(),
            GetUpcomingRemindersTool(),
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
        tools.append(GetCurrentLocationTool())
        tools.append(WeatherTool())
        checks.append("the user's current location and today's weather there (getCurrentLocation, then getWeather with that place)")
        summarizeNote = ", including the weather"
        #endif
        #if PLATETODAYTOOLS_INCLUDE_CONTACTS
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

// MARK: - UI (identical to plate-today — this part has nothing to do with Path A vs Path B)

@available(macOS 26.0, *)
struct ContentView: View {
    @ObservedObject var model: PlateTodayToolsModel

    var body: some View {
        VStack(spacing: 20) {
            Text("What's on my plate today? (Tools edition)")
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
        .frame(minWidth: 420, idealWidth: 420, maxWidth: 420, minHeight: 360, idealHeight: 360, maxHeight: .infinity)
        .onAppear { model.start() }
    }
}

// Distinct "platetodaytools" scheme (see Info.plist) so this app's OAuth callback doesn't
// collide with plate-today's "platetoday" or LocalLM Lab's own "locallmlab" if all three are
// installed at once.
@available(macOS 26.0, *)
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "platetodaytools" {
            MCPOAuthRedirectListener.shared.handleRedirect(url)
        }
    }
}

@available(macOS 26.0, *)
@main
struct PlateTodayToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PlateTodayToolsModel()

    init() {
        MCPOAuthFlow.redirectURI = "platetodaytools://oauth/callback"
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
    }
}
