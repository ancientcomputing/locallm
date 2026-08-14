# Annotated example source

The full source of both reference apps, with every line that actually touches the SDK marked
`// ← SDK` (Core) or `// ← Components`. Everything else is ordinary SwiftUI/Foundation — the point
of marking it this way is to make obvious just how little of each file is SDK-specific plumbing.

(GitHub-flavored Markdown doesn't apply bold/inline formatting inside fenced code blocks, so a
trailing comment is used instead of `**bold**` — it survives being read as a comment in the real
`.swift` file too, not just rendered here.)

See [`sdk-guide.md`](sdk-guide.md) for the prose walkthrough these annotate — this file is the
companion "show me the whole thing at once" reference.

## `examples/plate-today/Sources/PlateToday/PlateTodayApp.swift`

Demonstrates `Core` directly: Calendar/Reminders connectors, the MCP client, Keychain-backed OAuth
— no `Components` involved.

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
