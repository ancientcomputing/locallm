import AppKit
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import LocalLMLabSDKRemote
import OpenJevKit
import SwiftUI

@main
struct JevDKApp: App {
    @State private var model = AppModel()

    init() {
        // Headless checks, both through `lab.decide` like the window:
        // `JevDK --check <preset name> <repo id>` runs a preset's batch on a local model the SDK
        // has downloaded and prints the answers, then exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--check"), args.count > i + 2 {
            HeadlessCheck.run(preset: args[i + 1], modelDir: args[i + 2])
        }
        // `JevDK --check-remote <preset> <featherlessDemo|featherless|openRouter> [model]`: the
        // same, against a hosted Jev. Keys come from the Keychain (saved in Backends) or the
        // environment (FEATHERLESS_API_KEY / OPENROUTER_API_KEY) and are never printed.
        if let i = args.firstIndex(of: "--check-remote"), args.count > i + 2 {
            HeadlessCheck.runRemote(preset: args[i + 1], provider: args[i + 2],
                                    model: args.count > i + 3 && !args[i + 3].hasPrefix("--") ? args[i + 3] : nil)
        }

        // Launched with `swift run` there is no app bundle, so macOS starts this as a
        // background-style process that never becomes active. Claim regular-app status
        // (only if needed; re-setting it logs "Task policy set failed").
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        // The Dock icon, drawn in code: `swift run` has no bundle to hold one.
        NSApplication.shared.applicationIconImage = AppIcon.image()
        DispatchQueue.main.async { NSApplication.shared.activate() }
    }

    var body: some Scene {
        WindowGroup("JevDK") {
            ContentView(model: model)
                .font(.jBody)
                .frame(minWidth: 1060, minHeight: 660)
        }
        .commands {
            // Four kinds of file (README "Files"): the workspace (JevDK's own, everything), the
            // questions for your app (the SDK's DecisionQuestionSet), answers (CSV), and results (CSV).
            CommandGroup(replacing: .appInfo) {
                Button("About JevDK") { AboutPanel.show() }
                Button("Install jev-serve Command…") { JevServeInstaller.install() }
            }
            CommandGroup(replacing: .newItem) {
                Section("Workspace") {
                    Button("Open…") { model.open() }.keyboardShortcut("o")
                }
            }
            CommandGroup(replacing: .saveItem) {
                Section("Workspace") {
                    Button("Save Workspace") { model.save() }.keyboardShortcut("s")
                    Button("Save Workspace As…") { model.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                }
                Section("For your app") {
                    Button("Export Questions…") { model.exportForApp() }.keyboardShortcut("e")
                    Button("Export Server Config…") { model.exportServerConfig() }
                        .disabled(!model.useLocal || model.selectedModel == nil)
                }
                Section("Test data") {
                    Button("Import Answers (CSV)…") { model.importAnswerSet() }
                    Button("Export Answers (CSV)…") { model.exportAnswerSet() }
                    Button("Append Run to Results CSV…") { model.appendResults(choose: model.resultsCSVPath == nil) }
                        .disabled(model.batchRows.isEmpty || model.batchProgress != nil)
                }
            }
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showDownload = false
    @State private var showBackends = false
    /// An example waiting for "replace your work?" confirmation.
    @State private var pendingPreset: Presets.Preset?

    /// The questions panel on the left; hiding it gives the batch grid the whole window.
    @AppStorage("showQuestionsPanel") private var showEditor = true

    var body: some View {
        HSplitView {
            if showEditor {
                EditorView(model: model)
                    .frame(minWidth: 380, idealWidth: 460)
            }
            ResultsView(model: model)
                .frame(minWidth: 480)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    showEditor.toggle()
                } label: {
                    Label(showEditor ? "Hide questions" : "Show questions", systemImage: "sidebar.left")
                }
                .help(showEditor ? "Hide the questions panel to give results the whole window" : "Show the questions panel")
                Menu {
                    ForEach(Presets.all) { p in
                        Button(p.set.name) {
                            if model.workspaceIsPristine { model.loadPreset(p) } else { pendingPreset = p }
                        }
                    }
                } label: {
                    Label("Examples", systemImage: "square.stack")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Model", selection: $model.selectedModelID) {
                    if model.models.isEmpty { Text("No models found").tag(String?.none) }
                    ForEach(model.models) { m in
                        Text("\(m.displayName) · \(m.sizeText)\(m.isMoE ? " · MoE ⚠︎" : "")")
                            .tag(Optional(m.id))
                    }
                }
                .frame(width: 300)
                .help(modelHelp)
                Button {
                    model.refreshModels()
                } label: {
                    Label("Rescan models", systemImage: "arrow.clockwise")
                }
                Button {
                    showDownload = true
                } label: {
                    Label("Models", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Choose, download or remove local models")
                Button {
                    showBackends = true
                } label: {
                    Label("Backends", systemImage: "square.3.layers.3d")
                }
                .help("Compare the local model with hosted Jev (Featherless, OpenRouter · TypeSafe)")
            }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
        .sheet(isPresented: $showDownload) { ModelsSheet(model: model) }
        .confirmationDialog("Replace your current questions with “\(pendingPreset?.set.name ?? "")”?",
                            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } })) {
            Button("Save to a file first…") {
                if let p = pendingPreset, model.save(as: true) { model.loadPreset(p) }
                pendingPreset = nil
            }
            Button("Replace", role: .destructive) {
                if let p = pendingPreset { model.loadPreset(p) }
                pendingPreset = nil
            }
            Button("Cancel", role: .cancel) { pendingPreset = nil }
        } message: {
            Text("Your questions, system instructions, inputs, marked answers and calibration are replaced. JevDK only keeps your latest workspace, so save it to a file (⌘S) if you want it back.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.persistNow()
        }
        .sheet(isPresented: $showBackends) { BackendsSheet(model: model) }
    }

    private var modelHelp: String {
        guard let m = model.selectedModel else { return "No SDK-verified models yet: open Models to choose one." }
        var s = "\(m.repoID)\(m.shortRevision.map { " @ \($0)" } ?? "") · \(m.sizeText) · verified by the SDK"
        if let r = m.revision { s += "\nVersion \(r): exports pin this exact version." }
        if m.isMoE {
            s += "\nMixture-of-experts: not recommended as a decider. Its probabilities can shift with how the prompt is split."
        }
        return s
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if model.useLocal, let m = model.selectedModel {
                Text(m.repoID)
                if let r = m.shortRevision {
                    Text("@ \(r)").foregroundStyle(.secondary).help("The model's version on this Mac (\(m.revision ?? r)). Exports pin it.")
                }
                if m.isMoE {
                    Text("· MoE: not recommended as a decider").foregroundStyle(.orange)
                }
            }
            Spacer()
            let hosted = model.enabledHosted
            if !hosted.isEmpty {
                Label("Inputs are sent to \(hosted.map(\.displayName).joined(separator: ", "))", systemImage: "network")
                    .foregroundStyle(.secondary)
            } else {
                Text("Local only · nothing leaves this Mac").foregroundStyle(.secondary)
            }
            Text("· via lab.decide").foregroundStyle(.tertiary)
        }
        .font(.jCaption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

/// `--check` / `--check-remote`: a preset's batch through `lab.decide`, printed.
@MainActor
enum HeadlessCheck {
    static func runRemote(preset name: String, provider: String, model: String?) -> Never {
        guard let p = preset(name), let backend = HostedBackend(rawValue: provider) else {
            print("unknown preset or provider (have: \(HostedBackend.allCases.map(\.rawValue)))"); exit(1)
        }
        let key = APIKeys.key(for: backend)
        if backend.needsKey { print("key: \(key == nil ? "MISSING" : "found (\(key!.count) chars)")") }
        let lab = LocalLMLab()
        try? lab.models.register(decision: JevDecisionProvider(backend.config(key: key)))
        let modelName = model ?? backend.defaultModel
        lab.models.route(decision: "check", to: backend.modelID(modelName)!)
        print(backend.label(model: modelName))
        run(lab: lab, preset: p, pause: backend.minInterval,
            info: .init(backend: backend.rawValue, model: modelName, revision: nil, sizeBytes: nil, isMoE: nil,
                        wrapperLabel: nil, wrapperSystem: nil))
    }

    static func run(preset name: String, modelDir repo: String) -> Never {
        guard let p = preset(name) else { print("unknown preset \(name)"); exit(1) }
        let mlx = MLXModelProvider()
        let openjev = OpenJevDecisionProvider(mlx: mlx, wrapper: OpenJevWrapper(system: p.set.system, inputLabel: p.set.inputLabel))
        let id = AppModel.openJevID(repo)
        guard openjev.availability(for: id).isAvailable else {
            print("\(repo) isn't available to the SDK (\(openjev.availability(for: id))); download or verify it first."); exit(1)
        }
        print("\(repo)\(openjev.warnings(for: id).isEmpty ? "" : " · \(openjev.warnings(for: id))")")
        let lab = LocalLMLab()
        try? lab.models.register(decision: openjev)
        lab.models.route(decision: "check", to: id)
        let installed = mlx.installed.first { $0.repoID == repo }
        run(lab: lab, preset: p, pause: .zero,
            info: .init(backend: "local", model: repo, revision: installed?.resolvedRevision, sizeBytes: installed?.sizeBytes,
                        isMoE: openjev.warnings(for: id).contains(.mixtureOfExperts),
                        wrapperLabel: p.set.inputLabel, wrapperSystem: p.set.system))
    }

    private static func preset(_ name: String) -> Presets.Preset? {
        Presets.all.first { $0.set.name.lowercased() == name.lowercased() }
    }

    /// `--csv <file>` after either check appends the run to a results CSV, as the window's
    /// Results CSV button does (no marked answers headless, so `expected` / `correct` are empty).
    private static func run(lab: LocalLMLab, preset p: Presets.Preset, pause: Duration, info: ResultsCSV.BackendInfo,
                            setup: @escaping @Sendable () async -> Void = {}) -> Never {
        let args = CommandLine.arguments
        let csv = args.firstIndex(of: "--csv").flatMap { args.count > $0 + 1 ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let started = Date()
        let runInfo = ResultsCSV.RunInfo(runID: ResultsCSV.newRunID(at: started), savedAt: started,
                                         sdkVersion: LocalLMLabSDKVersion.current, machine: ResultsCSV.machine,
                                         questionSet: p.set.name)
        Task { @MainActor in
            await setup()
            var lines: [String] = []
            let questions = p.set.questions.map(\.sdkQuestion)
            for line in p.batch.split(separator: "\n").map(String.init) where !line.isEmpty {
                do {
                    let d = try await lab.decide(route: "check", state: .text(line), questions: questions)
                    let rows = QuestionResult.rows(for: p.set.questions, decision: d)
                    let result = DecisionResult(input: line, results: rows, sharedPrefixTokens: 0,
                                                milliseconds: Double(d.latency.components.seconds) * 1000 + Double(d.latency.components.attoseconds) / 1e15,
                                                backend: info.model)
                    lines += ResultsCSV.rows(run: runInfo, backend: info, result: result, labels: [:],
                                             inputTokens: d.usage?.inputTokens, costUSD: d.usage?.cost)
                    let cells = rows.map { "\($0.question.name)=\($0.answer) \(Int(($0.confidence * 100).rounded()))%" }
                    let ms = Double(d.latency.components.seconds) * 1000 + Double(d.latency.components.attoseconds) / 1e15
                    print(String(format: "%5.0f ms  ", ms) + line.prefix(60) + "\n          " + cells.joined(separator: "  ")
                          + (d.usage?.summary.map { "\n          [\($0)]" } ?? ""))
                } catch {
                    print("error: \(error.localizedDescription)")
                    break
                }
                if pause > .zero { try? await Task.sleep(for: pause) }
            }
            if let csv {
                do {
                    try ResultsCSV.append(lines, to: csv)
                    print("appended \(lines.count) rows to \(csv.path) (run \(runInfo.runID))")
                } catch {
                    print("csv: \(error.localizedDescription)")
                }
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
}

struct BackendsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyDrafts: [HostedBackend: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backends").font(.jHeadline)
            Text("Every backend that's on answers the same questions through lab.decide, shown side by side. Hosted backends receive the input text and the questions.")
                .font(.jCallout).foregroundStyle(.secondary)

            GroupBox {
                Toggle(isOn: $model.useLocal) {
                    VStack(alignment: .leading) {
                        Text("Local").fontWeight(.medium)
                        Text("openjev:\(model.selectedModel?.repoID ?? "no model") · token-scored · on this Mac").font(.jCaption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            ForEach(HostedBackend.allCases) { b in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { model.hostedEnabled[b] ?? false }, set: { model.hostedEnabled[b] = $0 })) {
                            VStack(alignment: .leading) {
                                Text(b.displayName).fontWeight(.medium)
                                Text(b.blurb).font(.jCaption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Text("Model").font(.jCallout)
                            TextField("model id", text: Binding(get: { model.hostedModel[b] ?? b.defaultModel },
                                                                set: { model.hostedModel[b] = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Menu {
                                ForEach(model.hostedModelChoices[b] ?? b.suggestedModels, id: \.self) { m in
                                    Button(m) { model.hostedModel[b] = m }
                                }
                                if b.modelsURL != nil {
                                    Divider()
                                    Button("Refresh list") { Task { await model.refreshHostedModels(b) } }
                                }
                            } label: { Image(systemName: "list.bullet") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        if b.needsKey {
                            HStack {
                                Text("API key").font(.jCallout)
                                SecureField(model.apiKey(b) == nil ? "paste key" : "saved in Keychain",
                                            text: Binding(get: { keyDrafts[b] ?? "" }, set: { keyDrafts[b] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                Button("Save") {
                                    model.setAPIKey(keyDrafts[b]?.trimmingCharacters(in: .whitespacesAndNewlines), b)
                                    keyDrafts[b] = ""
                                }
                                .disabled((keyDrafts[b] ?? "").isEmpty)
                                if model.apiKey(b) != nil {
                                    Button("Forget") { model.setAPIKey(nil, b); keyDrafts[b] = "" }
                                }
                            }
                        }
                    }
                    .padding(4)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .font(.jBody)
    }
}

/// JevDK → Install jev-serve Command…: the released app carries jev-serve (Contents/MacOS), signed
/// and notarized with it. This links it into /usr/local/bin (on the default PATH), asking for an
/// administrator password; if that doesn't work, it shows the command to run instead.
enum JevServeInstaller {
    static let target = "/usr/local/bin/jev-serve"

    static func install() {
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "jev-serve")?.path,
              FileManager.default.isExecutableFile(atPath: tool) else {
            inform("jev-serve isn't in this copy of JevDK",
                   "The JevDK download includes jev-serve; a JevDK built from source doesn't. Build it from the jev-serve folder of the source: swift build -c release.")
            return
        }
        let appPath = Bundle.main.bundlePath
        if appPath.contains("/AppTranslocation/") || appPath.hasPrefix("/Volumes/") {
            inform("Move JevDK to Applications first",
                   "JevDK is running from the disk image or a temporary location, so a command installed now would stop working. Drag JevDK to Applications, open it from there, and choose this again.")
            return
        }
        let command = "mkdir -p /usr/local/bin && ln -sf \(shellQuote(tool)) \(target)"
        let source = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return }   // the user cancelled
            fallback(command)
            return
        }
        inform("jev-serve is installed",
               "Run it in Terminal:\n\n  jev-serve --help\n  jev-serve --config jev-serve.json\n\nIt's a link to the copy inside JevDK, so it updates when JevDK does. Export a config with File → Export Server Config….")
    }

    /// The same, for the user to run: shown with a Copy button.
    static func fallback(_ command: String) {
        let alert = NSAlert()
        alert.messageText = "Install jev-serve from Terminal"
        alert.informativeText = "Run this in Terminal (it asks for your password):\n\nsudo sh -c '\(command.replacingOccurrences(of: "'", with: "'\\''"))'"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("sudo sh -c '\(command.replacingOccurrences(of: "'", with: "'\\''"))'", forType: .string)
        }
    }

    static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// 'path' with single quotes escaped, for sh.
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The text as the inside of an AppleScript string literal.
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// JevDK → About: the icon, the version, and where to read about decision models.
enum AboutPanel {
    static let webPage = URL(string: "https://thisbrain.ai/locallm/jev.html")!

    /// The app's version when it runs as a built app (Xcode, or the DMG's), else "development build"
    /// (`swift run` has no bundle to carry one).
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "development build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { $0 == short ? short : "\(short) (\($0))" } ?? short
    }

    static func show() {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let credits = NSMutableAttributedString(
            string: "A playground for decision-model (Jev) questions.\nBuilt on the LocalLM Lab SDK \(LocalLMLabSDKVersion.current).\n\n",
            attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered])
        credits.append(NSAttributedString(string: "Decision models (Jev) in your app", attributes: [
            .font: body, .link: webPage, .paragraphStyle: centered,
        ]))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationIcon: AppIcon.image(),
            .applicationName: "JevDK",
            .applicationVersion: version,
            .version: "",                     // the build number is already in applicationVersion
            .credits: credits,
        ])
        NSApplication.shared.activate()
    }
}

/// JevDK's Dock icon: "Jdk" in white on LocalLM Lab's blue rounded square (the same design as the
/// LocalLM Lab app icon), with a small "ev" under the J for "Jev". Drawn in code so `swift run`
/// gets it too, with no bundle to hold an image.
enum AppIcon {
    static let blue = NSColor(srgbRed: 0x2f / 255, green: 0x6f / 255, blue: 0xed / 255, alpha: 1)

    static func image(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Full-bleed rounded square, corner radius as in LocalLM Lab's icon (14 of 64).
            blue.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size * 14 / 64, yRadius: size * 14 / 64).fill()

            func text(_ s: String, _ pt: CGFloat, _ weight: NSFont.Weight, alpha: CGFloat = 1) -> NSAttributedString {
                NSAttributedString(string: s, attributes: [
                    .font: NSFont.systemFont(ofSize: size * pt, weight: weight),
                    .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                ])
            }
            func ink(_ t: NSAttributedString) -> NSRect {
                t.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
            }
            let j = text("J", 0.50, .bold), dk = text("dk", 0.30, .semibold), ev = text("ev", 0.19, .semibold, alpha: 0.85)
            let jInk = ink(j), dkInk = ink(dk), evInk = ink(ev)
            let gapX = size * 0.015, gapY = size * 0.025
            // Line 1: J and dk on one baseline. Line 2: ev centred under the J.
            let width = jInk.width + gapX + dkInk.width
            let height = jInk.height + gapY + evInk.height
            let left = rect.midX - width / 2, top = rect.midY + height / 2
            let baselineJ = top - jInk.maxY                       // draw origin y so J's ink top = top
            j.draw(at: NSPoint(x: left - jInk.minX, y: baselineJ))
            dk.draw(at: NSPoint(x: left + jInk.width + gapX - dkInk.minX, y: baselineJ))
            let evTop = top - jInk.height - gapY
            ev.draw(at: NSPoint(x: left + jInk.width / 2 - evInk.midX, y: evTop - evInk.maxY))
            return true
        }
    }
}
