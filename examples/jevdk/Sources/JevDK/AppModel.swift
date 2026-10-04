import AppKit
import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import LocalLMLabSDKRemote
import Observation
import OpenJevKit
import UniformTypeIdentifiers

/// One backend's answer (or error) for one input.
struct BackendRun: Identifiable {
    var id: String { label }
    let label: String
    var result: DecisionResult?
    var error: String?
    /// What the backend was, for the results CSV.
    var info: ResultsCSV.BackendInfo? = nil
    /// Hosted only, as the provider reported them.
    var inputTokens: Int? = nil
    var costUSD: Double? = nil
}

/// One batch input with every backend's answers.
struct BatchRow: Identifiable {
    let id = UUID()
    let input: String
    let runs: [BackendRun]
}

/// A local model the SDK has downloaded and verified, as the picker shows it.
struct LocalChoice: Identifiable, Hashable {
    var id: String { repoID }
    let repoID: String
    let sizeBytes: Int64?
    let isMoE: Bool

    var displayName: String { repoID.split(separator: "/").last.map(String.init) ?? repoID }
    var sizeText: String { sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?" }
}

/// Everything runs on the SDK's decision API: hosted Jev through `lab.decide`
/// with `JevDecisionProvider`; local OpenJev through `OpenJevDecisionProvider` (with the editor's
/// wrapper, and `decideWithDiagnostics` for the prompt view); models listed, checked and
/// downloaded by `MLXModelProvider`.
@MainActor
@Observable
final class AppModel {
    // Local models
    var models: [LocalChoice] = []
    /// In the Hugging Face cache but not downloaded through the SDK, so not usable until verified.
    var unverifiedRepos: [String] = []
    var selectedModelID: String? { didSet { persistSoon() } }

    // What the developer is editing
    var set: QuestionSet = Presets.triage { didSet { persistSoon() } }
    var input = Presets.triageInput { didSet { persistSoon() } }
    var batchText = Presets.triageBatch { didSet { persistSoon() } }
    var samples: [(String, String)] = [] { didSet { persistSoon() } }

    // Results: one run per backend, in backend order.
    var results: [BackendRun] = []
    var batchRows: [BatchRow] = []
    var batchProgress: (done: Int, total: Int)?
    /// Groups one batch's rows in the results CSV.
    var batchRunID: String?
    var batchStartedAt: Date?
    /// Where "Append results to CSV" last wrote.
    var resultsCSVPath: String? = UserDefaults.standard.string(forKey: "resultsCSVPath") {
        didSet { UserDefaults.standard.set(resultsCSVPath, forKey: "resultsCSVPath") }
    }
    /// Rows appended by the last write, for the status line.
    var lastAppend: (rows: Int, file: String)?
    var isRunning = false
    var errorMessage: String?

    // Backends
    var useLocal = true { didSet { UserDefaults.standard.set(useLocal, forKey: "useLocal") } }
    var hostedEnabled: [HostedBackend: Bool] = [:] { didSet { saveHostedSettings() } }
    var hostedModel: [HostedBackend: String] = [:] { didSet { saveHostedSettings() } }
    var hostedModelChoices: [HostedBackend: [String]] = [:]

    // Calibration (the developer's: fitted on answers they mark correct in the batch grid)
    /// Input → question name → the correct answer's key.
    var labels: [String: [String: String]] = [:] { didSet { persistSoon() } }
    var calibration: FittedCalibration? { didSet { persistSoon() } }
    /// Show local answers with `calibration` applied, as `OpenJevDecisionProvider(calibration:)` would.
    var applyCalibration = false { didSet { persistSoon() } }

    // Download / verify
    var downloadRepo = ""
    var preflight: PreflightResult?
    var downloadProgress: Double?

    /// The SDK front door hosted runs go through.
    let lab = LocalLMLab()
    /// Local models: listing, preflight, download, and the weights OpenJev scores on.
    let mlx = MLXModelProvider()
    private var batchTask: Task<Void, Never>?
    private var fileURL: URL?

    var selectedModel: LocalChoice? { models.first { $0.id == selectedModelID } }

    init() {
        assert(QuestionSet.defaultSystem == OpenJevWrapper.default.system
               && QuestionSet.defaultInputLabel == OpenJevWrapper.default.inputLabel,
               "OpenJevKit's mirrored default wrapper drifted from the SDK's")
        restoreWorkspace()
        refreshModels()
        let d = UserDefaults.standard
        if d.object(forKey: "useLocal") != nil { useLocal = d.bool(forKey: "useLocal") }
        for b in HostedBackend.allCases {
            hostedEnabled[b] = d.bool(forKey: "remote.\(b.rawValue).on")
            hostedModel[b] = d.string(forKey: "remote.\(b.rawValue).model") ?? b.defaultModel
            hostedModelChoices[b] = b.suggestedModels
        }
    }

    func refreshModels() {
        let probe = OpenJevDecisionProvider(mlx: mlx)
        models = mlx.installed.map { m in
            LocalChoice(repoID: m.repoID, sizeBytes: m.sizeBytes,
                        isMoE: probe.warnings(for: Self.openJevID(m.repoID)).contains(.mixtureOfExperts))
        }.sorted { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }
        let verified = Set(models.map(\.repoID))
        unverifiedRepos = ModelCatalog.cachedRepoIDs().filter { !verified.contains($0) }
        if selectedModelID == nil || selectedModel == nil {
            // Default to the smallest non-MoE model of at least ~2 GB (Qwen3-4B-class, the eval's
            // pick), else the smallest non-MoE one.
            let dense = models.filter { !$0.isMoE }
            selectedModelID = (dense.first { ($0.sizeBytes ?? 0) >= 2_000_000_000 } ?? dense.first ?? models.first)?.id
        }
    }

    static func openJevID(_ repo: String) -> ModelID { ModelID(scheme: "openjev", rest: repo)! }

    // MARK: Backends

    private func saveHostedSettings() {
        let d = UserDefaults.standard
        for b in HostedBackend.allCases {
            d.set(hostedEnabled[b] ?? false, forKey: "remote.\(b.rawValue).on")
            d.set(hostedModel[b], forKey: "remote.\(b.rawValue).model")
        }
    }

    func apiKey(_ b: HostedBackend) -> String? { Keychain.get("key.\(b.rawValue)") }
    func setAPIKey(_ key: String?, _ b: HostedBackend) { Keychain.set(key, for: "key.\(b.rawValue)") }

    var enabledHosted: [HostedBackend] { HostedBackend.allCases.filter { hostedEnabled[$0] == true } }

    var localLabel: String { "Local · \(selectedModel?.displayName ?? "no model")" }

    func hostedLabel(_ b: HostedBackend) -> String { b.label(model: hostedModel[b] ?? b.defaultModel) }

    /// Labels of the backends a run will use, in display order.
    var activeBackendLabels: [String] {
        (useLocal ? [localLabel] : []) + enabledHosted.map(hostedLabel)
    }

    func refreshHostedModels(_ b: HostedBackend) async {
        hostedModelChoices[b] = await b.listModels()
    }

    private struct HostedPlan {
        let route: RouteName
        let label: String
        let requestPreview: String
        let info: ResultsCSV.BackendInfo
    }

    /// Register the enabled hosted backends and point a decision route at each. Re-registered every
    /// run so a changed key or model takes effect.
    private func hostedPlans(for request: DecisionRequest) -> [HostedPlan] {
        enabledHosted.compactMap { b in
            let model = hostedModel[b] ?? b.defaultModel
            guard let id = b.modelID(model) else { return nil }
            lab.models.replace(decision: JevDecisionProvider(b.config(key: b.needsKey ? apiKey(b) : nil)))
            let route = RouteName("hosted.\(b.rawValue)")
            lab.models.route(decision: route, to: id)
            let body = (try? JevDecisionProvider.requestBody(model: model, request: request))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            return HostedPlan(route: route, label: hostedLabel(b),
                              requestPreview: "POST \(b.config(key: nil).endpoint.absoluteString)\n\(body)",
                              info: .init(backend: b.rawValue, model: model, revision: nil, sizeBytes: nil, isMoE: nil,
                                          wrapperLabel: nil, wrapperSystem: nil))
        }
    }

    /// Run `input` on every enabled backend, concurrently.
    private func runAll(_ input: String) async -> [BackendRun] {
        let questions = set.questions
        let request = DecisionRequest(state: .text(input), questions: questions.map(\.sdkQuestion))
        let plans = hostedPlans(for: request)
        let local: (LocalChoice, OpenJevDecisionProvider)? = useLocal ? selectedModel.map { m in
            (m, OpenJevDecisionProvider(mlx: mlx, wrapper: OpenJevWrapper(system: set.system, inputLabel: set.inputLabel)))
        } : nil
        let localLabel = self.localLabel
        let localInfo = local.map { m, openjev in
            ResultsCSV.BackendInfo(backend: "local", model: m.repoID,
                                   revision: mlx.installed.first { $0.repoID == m.repoID }?.resolvedRevision,
                                   sizeBytes: m.sizeBytes, isMoE: m.isMoE,
                                   wrapperLabel: openjev.wrapper.inputLabel, wrapperSystem: openjev.wrapper.system)
        }

        return await withTaskGroup(of: (Int, BackendRun).self) { group in
            if let (m, openjev) = local {
                // Local runs call the provider directly for its diagnostics (exact prompts, label
                // mass), validating against its limits first as lab.decide would.
                group.addTask {
                    do {
                        try request.validate(against: openjev.limits)
                        let (d, diag) = try await openjev.decideWithDiagnostics(request, using: Self.openJevID(m.repoID))
                        let qd = diag.questions.mapValues {
                            QuestionDiagnostics(labels: $0.labels, prompt: $0.prompt, labelMass: $0.labelMass,
                                                milliseconds: Self.ms($0.latency))
                        }
                        let rows = QuestionResult.rows(for: questions, decision: d, diagnostics: qd)
                        return (0, BackendRun(label: localLabel, result: DecisionResult(
                            input: input, results: rows, sharedPrefixTokens: diag.sharedPrefixTokens,
                            milliseconds: Self.ms(d.latency), backend: localLabel), info: localInfo))
                    } catch {
                        return (0, BackendRun(label: localLabel, error: error.localizedDescription, info: localInfo))
                    }
                }
            }
            for (i, plan) in plans.enumerated() {
                group.addTask { @MainActor in
                    do {
                        let d = try await self.lab.decide(route: plan.route, state: .text(input), questions: request.questions)
                        let rows = QuestionResult.rows(for: questions, decision: d, prompt: plan.requestPreview)
                        return (i + 1, BackendRun(label: plan.label, result: DecisionResult(
                            input: input, results: rows, sharedPrefixTokens: 0, milliseconds: Self.ms(d.latency),
                            backend: plan.label, usage: d.usage?.summary), info: plan.info,
                            inputTokens: d.usage?.inputTokens, costUSD: d.usage?.cost))
                    } catch {
                        return (i + 1, BackendRun(label: plan.label, error: error.localizedDescription, info: plan.info))
                    }
                }
            }
            var out: [(Int, BackendRun)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    nonisolated private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    // MARK: Running

    private func validationProblem() -> String? {
        if activeBackendLabels.isEmpty { return "Turn on at least one backend." }
        if useLocal && selectedModel == nil { return "Pick a local model (Models in the toolbar), or turn Local off in Backends." }
        if set.questions.isEmpty { return "Add at least one question." }
        if let q = set.questions.first(where: { !$0.problems.isEmpty }) {
            return "“\(q.name)”: \(q.problems.joined(separator: "; "))."
        }
        return nil
    }

    func run() async {
        guard !isRunning else { return }
        if let problem = validationProblem() { errorMessage = problem; return }
        errorMessage = nil
        isRunning = true
        defer { isRunning = false }
        results = await runAll(input)
    }

    var batchInputs: [String] {
        batchText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func runBatch() {
        guard !isRunning else { return }
        if let problem = validationProblem() { errorMessage = problem; return }
        errorMessage = nil
        let inputs = batchInputs
        let pause = enabledHosted.map(\.minInterval).max() ?? .zero
        batchRows = []
        let started = Date()
        batchRunID = ResultsCSV.newRunID(at: started)
        batchStartedAt = started
        lastAppend = nil
        batchTask = Task {
            isRunning = true
            defer { isRunning = false; batchProgress = nil }
            batchProgress = (0, inputs.count)
            for (i, line) in inputs.enumerated() {
                if Task.isCancelled { break }
                batchRows.append(BatchRow(input: line, runs: await runAll(line)))
                batchProgress = (i + 1, inputs.count)
                if pause > .zero { try? await Task.sleep(for: pause) }
            }
        }
    }

    func stopBatch() { batchTask?.cancel() }

    // MARK: Calibration

    func label(input: String, question: String) -> String? { labels[input]?[question] }

    func setLabel(_ key: String?, input: String, question: String) {
        var row = labels[input] ?? [:]
        row[question] = key
        labels[input] = row.isEmpty ? nil : row
    }

    var markedCount: Int { labels.values.map(\.count).reduce(0, +) }

    var calibrationSamples: [DecisionCalibration.Sample] { Calibrator.samples(rows: batchRows, labels: labels) }

    var selectedRevision: String? {
        mlx.installed.first { $0.repoID == selectedModel?.repoID }?.resolvedRevision
    }

    /// Why the current calibration may not hold for the current model and wrapper; nil if it does.
    var calibrationMismatch: String? {
        calibration?.mismatch(repoID: selectedModel?.repoID, revision: selectedRevision,
                              system: set.system, inputLabel: set.inputLabel)
    }

    /// Fit on the marked answers with the SDK's `DecisionCalibration.fit`.
    func fitCalibration() {
        guard let m = selectedModel else { errorMessage = "Pick a local model first."; return }
        let samples = calibrationSamples
        guard !samples.isEmpty else { errorMessage = "Mark some correct answers in the batch grid first."; return }
        let fitted = DecisionCalibration.fit(samples)
        calibration = FittedCalibration(
            noulTemperature: fitted.noulTemperature, choiceTemperature: fitted.choiceTemperature,
            scoreTemperature: fitted.scoreTemperature, repoID: m.repoID, revision: selectedRevision ?? "?",
            system: set.system, inputLabel: set.inputLabel, fittedAt: Date(),
            samples: Dictionary(grouping: samples, by: \.kind.rawValue).mapValues(\.count))
        applyCalibration = true
    }

    /// `run` as JevDK shows it: local answers calibrated when a matching calibration is applied.
    func display(_ run: BackendRun) -> BackendRun {
        guard applyCalibration, let c = calibration, calibrationMismatch == nil,
              run.label.hasPrefix("Local"), let r = run.result else { return run }
        return BackendRun(label: run.label, result: Calibrator.applying(c.sdk, to: r), error: run.error,
                          info: run.info, inputTokens: run.inputTokens, costUSD: run.costUSD)
    }

    /// Per backend: answers matching the marked correct answer, out of those marked.
    var markedAccuracy: [(label: String, right: Int, total: Int)] {
        var tally: [String: (Int, Int)] = [:]
        var order: [String] = []
        for row in batchRows {
            guard let marks = labels[row.input] else { continue }
            for run in row.runs {
                guard let r = run.result else { continue }
                if tally[run.label] == nil { order.append(run.label); tally[run.label] = (0, 0) }
                for q in r.results {
                    guard let key = marks[q.question.name] else { continue }
                    tally[run.label]!.1 += 1
                    if q.answer == key { tally[run.label]!.0 += 1 }
                }
            }
        }
        return order.map { ($0, tally[$0]!.0, tally[$0]!.1) }
    }

    // MARK: Question set for the app, answer sets

    /// What the questions are being tested with, for the exported question set: the local model,
    /// its revision, the wrapper and (when it matches) the calibration. Nil with Local off.
    var exportTuning: DecisionQuestionSet.Tuning? {
        guard useLocal, let m = selectedModel else { return nil }
        let cal = calibrationMismatch == nil ? calibration?.sdk : nil
        return .init(model: Self.openJevID(m.repoID), revision: selectedRevision, system: set.system,
                     inputLabel: set.inputLabel, calibration: cal, testedAt: Date())
    }

    /// The questions as the SDK's `DecisionQuestionSet` JSON, for the app to bundle and load, so
    /// the shipped questions are exactly the tested ones.
    func exportForApp() {
        if let q = set.questions.first(where: { !$0.problems.isEmpty }) {
            errorMessage = "Fix “\(q.name)” first: \(q.problems.joined(separator: "; "))."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let base = set.name.isEmpty ? "questions" : set.name.lowercased().replacingOccurrences(of: " ", with: "-")
        panel.nameFieldStringValue = "\(base).decisions.json"
        panel.message = "A question set for your app: bundle it and load it with DecisionQuestionSet(contentsOf:)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = DecisionQuestionSet(name: set.name, questions: set.questions.map(\.sdkQuestion), tuning: exportTuning)
            try file.jsonData().write(to: url)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }

    /// Load an answer set (CSV: `input`, then a column per question with the correct answer) into
    /// the batch list and the marks. Inputs with line breaks are joined onto one line, since the
    /// batch list is one input per line.
    func importAnswerSet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "An answer set: a CSV with an input column and one column per question, holding the correct answer."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let answers = try DecisionAnswerSet(csv: String(contentsOf: url, encoding: .utf8))
            let questions = set.questions.map(\.sdkQuestion)
            let problems = answers.problems(for: questions)
            guard problems.isEmpty else {
                errorMessage = "\(url.lastPathComponent) doesn't fit these questions: " + problems.prefix(3).joined(separator: " ")
                    + (problems.count > 3 ? " (and \(problems.count - 3) more)" : "")
                return
            }
            var newLabels: [String: [String: String]] = [:]
            var inputs: [String] = []
            var joined = 0
            for e in answers.examples {
                let one = e.input.split(whereSeparator: \.isNewline).joined(separator: " ")
                if one != e.input { joined += 1 }
                inputs.append(one)
                var marks: [String: String] = [:]
                for q in questions {
                    if let raw = e.answers[q.id], let key = DecisionAnswerSet.answerKey(raw, for: q) { marks[q.id] = key }
                }
                if !marks.isEmpty { newLabels[one] = marks }
            }
            batchText = inputs.joined(separator: "\n")
            labels = newLabels
            batchRows = []
            errorMessage = joined > 0 ? "Imported \(inputs.count) inputs; \(joined) had line breaks and were joined onto one line." : nil
        } catch {
            errorMessage = "Couldn't import: \(error.localizedDescription)"
        }
    }

    /// The batch inputs and their marks as an answer-set CSV.
    func exportAnswerSet() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(set.name.isEmpty ? "answers" : set.name.lowercased().replacingOccurrences(of: " ", with: "-")).answers.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let answers = DecisionAnswerSet(examples: batchInputs.map { .init(input: $0, answers: labels[$0] ?? [:]) })
        do {
            try answers.csv(questionIDs: set.questions.map(\.name)).write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }

    // MARK: Results CSV

    /// Append the last batch's results (as shown: calibrated if a calibration is applied) to a
    /// results CSV, one row per input × question × backend. `choose` asks for a file; otherwise the
    /// last one is used.
    func appendResults(choose: Bool) {
        guard !batchRows.isEmpty, let runID = batchRunID else { errorMessage = "Run a batch first."; return }
        var url = resultsCSVPath.map { URL(fileURLWithPath: $0) }
        if choose || url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = url?.lastPathComponent ?? "jevdk-results.csv"
            panel.message = "Choose a results CSV to append to, or name a new one."
            if let dir = url?.deletingLastPathComponent() { panel.directoryURL = dir }
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }
        guard let url else { return }
        let run = ResultsCSV.RunInfo(runID: runID, savedAt: batchStartedAt ?? Date(), sdkVersion: LocalLMLabSDKVersion.current,
                                     machine: ResultsCSV.machine, questionSet: set.name)
        var lines: [String] = []
        for row in batchRows {
            for r in row.runs.map(display) {
                guard let result = r.result, let info = r.info else { continue }
                lines += ResultsCSV.rows(run: run, backend: info, result: result, labels: labels[row.input] ?? [:],
                                         inputTokens: r.inputTokens, costUSD: r.costUSD)
            }
        }
        do {
            try ResultsCSV.append(lines, to: url)
            resultsCSVPath = url.path
            lastAppend = (lines.count, url.lastPathComponent)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Models

    /// Text models tried as deciders or worth trying; all MLX 4-bit builds on Hugging Face.
    static let recommended: [(repo: String, note: String)] = [
        ("mlx-community/Qwen3-4B-4bit", "2.3 GB · tested as a decider: the current pick"),
        ("mlx-community/Qwen3-1.7B-4bit", "1.0 GB · tested: fast, but weaker on yes/no and answer checks"),
        ("mlx-community/Qwen3-8B-4bit", "4.6 GB · untested here; a bigger Qwen3"),
        ("mlx-community/Llama-3.2-3B-Instruct-4bit", "1.8 GB · untested here"),
        ("mlx-community/Phi-4-mini-instruct-4bit", "2.2 GB · untested here"),
        ("mlx-community/Qwen2.5-3B-Instruct-4bit", "1.8 GB · untested here"),
    ]

    struct HubModel: Identifiable, Decodable {
        let id: String
        let downloads: Int?
        let pipeline_tag: String?
    }

    /// MLX models on Hugging Face matching `query`, most downloaded first.
    func searchHub(_ query: String) async -> [HubModel] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        c.queryItems = [.init(name: "filter", value: "mlx"), .init(name: "search", value: query),
                        .init(name: "sort", value: "downloads"), .init(name: "limit", value: "25")]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let models = try? JSONDecoder().decode([HubModel].self, from: data) else {
            errorMessage = "Couldn't search Hugging Face."
            return []
        }
        return models
    }

    func remove(_ repo: String) {
        do {
            try mlx.remove(ModelID(scheme: "mlx", rest: repo)!)
            if selectedModelID == repo { selectedModelID = nil }
            refreshModels()
        } catch {
            errorMessage = "Couldn't remove \(repo): \(error.localizedDescription)"
        }
    }

    // MARK: Download / verify (through the SDK)

    /// The SDK's no-download checks: repo reachable, MLX format, supported architecture, size vs
    /// this Mac's memory and disk.
    func checkRepo() async {
        preflight = nil
        let repo = downloadRepo.trimmingCharacters(in: .whitespaces)
        guard repo.contains("/") else { return }
        do {
            preflight = try await mlx.validate(repo)
        } catch {
            errorMessage = "Couldn't check \(repo): \(error.localizedDescription)"
        }
    }

    /// Download `repo` (or `downloadRepo`) through the SDK, which verifies the weights. Files
    /// already in the cache are verified rather than fetched again.
    func download(_ repo: String? = nil) async {
        let repo = (repo ?? downloadRepo).trimmingCharacters(in: .whitespaces)
        guard repo.contains("/") else { errorMessage = "Enter a repo id like mlx-community/Qwen3-4B-4bit."; return }
        errorMessage = nil
        downloadProgress = 0
        defer { downloadProgress = nil }
        do {
            for try await event in mlx.download(repo) {
                if case .progress(_, _, let f) = event { downloadProgress = f }
            }
            refreshModels()
            selectedModelID = repo
            downloadRepo = ""
            preflight = nil
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    // MARK: Question editing

    func addQuestion(_ kind: QuestionKind) {
        let n = set.questions.count + 1
        switch kind {
        case .noul:
            set.questions.append(EditableQuestion(name: "question\(n)", kind: .noul, text: ""))
        case .choice:
            set.questions.append(EditableQuestion(name: "question\(n)", kind: .choice, text: "", options: [
                AnswerOption(key: "first", description: ""), AnswerOption(key: "second", description: ""),
            ]))
        case .score:
            set.questions.append(EditableQuestion(name: "question\(n)", kind: .score, text: "", options: [
                AnswerOption(key: "0", description: "low"), AnswerOption(key: "1", description: "medium"),
                AnswerOption(key: "2", description: "high"),
            ]))
        }
    }

    func duplicate(_ q: EditableQuestion) {
        guard let i = set.questions.firstIndex(where: { $0.id == q.id }) else { return }
        var copy = q
        copy.id = UUID()
        copy.name = q.name + "2"
        copy.options = q.options.map { AnswerOption(key: $0.key, description: $0.description) }
        set.questions.insert(copy, at: i + 1)
    }

    func remove(_ q: EditableQuestion) { set.questions.removeAll { $0.id == q.id } }

    func move(_ q: EditableQuestion, by offset: Int) {
        guard let i = set.questions.firstIndex(where: { $0.id == q.id }) else { return }
        let j = i + offset
        guard set.questions.indices.contains(j) else { return }
        set.questions.swapAt(i, j)
    }

    // MARK: Workspace (implicit save and restore)

    /// What JevDK brings back on the next launch, like Prompt Playground keeps its last prompt: the
    /// questions and wrapper, the inputs, marks, calibration and the selected model. Results aren't
    /// kept; run again. Saved to UserDefaults shortly after each change.
    struct Workspace: Codable {
        var set: QuestionSet
        var input: String
        var batch: String
        var samples: [[String]]
        var labels: [String: [String: String]]
        var calibration: FittedCalibration?
        var applyCalibration: Bool
        var selectedModelID: String?
    }

    private static let workspaceKey = "jevdk.workspace"
    private var persistTask: Task<Void, Never>?
    private var restoring = false

    private func persistSoon() {
        guard !restoring else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.persistNow()
        }
    }

    func persistNow() {
        let w = Workspace(set: set, input: input, batch: batchText, samples: samples.map { [$0.0, $0.1] },
                          labels: labels, calibration: calibration, applyCalibration: applyCalibration,
                          selectedModelID: selectedModelID)
        if let data = try? JSONEncoder().encode(w) { UserDefaults.standard.set(data, forKey: Self.workspaceKey) }
    }

    private func restoreWorkspace() {
        guard let data = UserDefaults.standard.data(forKey: Self.workspaceKey),
              let w = try? JSONDecoder().decode(Workspace.self, from: data) else {
            samples = Presets.all.first { $0.set.name == set.name }?.samples ?? []
            return
        }
        restoring = true
        defer { restoring = false }
        set = w.set
        input = w.input
        batchText = w.batch
        samples = w.samples.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        labels = w.labels
        calibration = w.calibration
        applyCalibration = w.applyCalibration
        selectedModelID = w.selectedModelID   // refreshModels keeps it if still installed
    }

    /// Nothing to lose by replacing the workspace: it's an unedited example with no marks or
    /// calibration.
    var workspaceIsPristine: Bool {
        labels.isEmpty && calibration == nil
            && Presets.all.contains { $0.set == set && $0.batch == batchText }
    }

    func loadPreset(_ p: Presets.Preset) {
        set = p.set
        input = p.input
        batchText = p.batch
        samples = p.samples
        labels = [:]
        calibration = nil
        applyCalibration = false
        results = []
        batchRows = []
        fileURL = nil
    }

    // MARK: Files

    /// Save the question set, inputs, marks and calibration to a JSON file. Returns whether it saved
    /// (false if the panel was cancelled or the write failed).
    @discardableResult
    func save(as: Bool = false) -> Bool {
        var url = fileURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = set.name.isEmpty ? "questions.json" : "\(set.name).json"
            guard panel.runModal() == .OK, let picked = panel.url else { return false }
            url = picked
        }
        guard let url else { return false }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(SavedSet(set: set, input: input, batch: batchText, labels: labels, calibration: calibration)).write(to: url)
            fileURL = url
            return true
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if let saved = try? JSONDecoder().decode(SavedSet.self, from: data) {
                set = saved.set
                input = saved.input ?? input
                batchText = saved.batch ?? batchText
                labels = saved.labels ?? [:]
                calibration = saved.calibration
                applyCalibration = saved.calibration != nil
            } else {
                set = try JSONDecoder().decode(QuestionSet.self, from: data)
            }
            results = []
            batchRows = []
            samples = []
            fileURL = url
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

/// What JevDK writes to disk: the question set plus the inputs being tried.
struct SavedSet: Codable {
    var set: QuestionSet
    var input: String?
    var batch: String?
    /// Input → question name → the correct answer's key, as marked in the batch grid.
    var labels: [String: [String: String]]?
    var calibration: FittedCalibration?
}
