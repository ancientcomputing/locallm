import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import OpenJevKit

/// A calibration the developer fitted in JevDK, with what it's valid for. Calibration is the app's:
/// it holds for this model revision, wrapper and kind of question only, so JevDK records all three
/// and flags the calibration when any changes.
struct FittedCalibration: Codable, Hashable {
    var noulTemperature: Double
    var choiceTemperature: Double
    var scoreTemperature: Double
    /// What it was fitted for.
    var repoID: String
    var revision: String
    var system: String
    var inputLabel: String
    var fittedAt: Date
    /// Marked answers per kind it was fitted on.
    var samples: [String: Int]

    var sdk: DecisionCalibration {
        DecisionCalibration(noulTemperature: noulTemperature, choiceTemperature: choiceTemperature, scoreTemperature: scoreTemperature)
    }

    /// Why it may not hold for the current setup, or nil if it matches.
    func mismatch(repoID: String?, revision: String?, system: String, inputLabel: String) -> String? {
        var reasons: [String] = []
        if repoID != self.repoID { reasons.append("it was fitted on \(self.repoID)") }
        else if let revision, revision != self.revision { reasons.append("the model has been updated since") }
        if system != self.system || inputLabel != self.inputLabel { reasons.append("the system instructions changed since") }
        return reasons.isEmpty ? nil : reasons.joined(separator: ", ")
    }

    /// What the developer pastes into their app. The questions, wrapper and this calibration travel
    /// in the exported question set (File → Export for App…), so the code only loads it.
    var swiftSnippet: String {
        """
        // Export the question set from JevDK (File → Export for App…) and bundle it with your app.
        // It holds the questions, the wrapper and this calibration, fitted on \(samples.values.reduce(0, +)) marked answers
        // for \(repoID) @ \(revision.prefix(12)) (\(fittedAt.formatted(date: .abbreviated, time: .omitted))).
        let set = try DecisionQuestionSet(contentsOf: Bundle.main.url(forResource: "questions.decisions", withExtension: "json")!)
        let openjev = OpenJevDecisionProvider(mlx: mlx, tunedWith: set)
        try lab.models.register(decision: openjev)
        lab.models.route(decision: "decide", to: ModelID("openjev:\(repoID)")!)
        let d = try await lab.decide(route: "decide", state: .text(input), questions: set.questions)

        // Or, without the file:
        // OpenJevDecisionProvider(mlx: mlx,
        //     wrapper: OpenJevWrapper(system: \(Self.literal(system)), inputLabel: \(Self.literal(inputLabel))),
        //     calibration: DecisionCalibration(noulTemperature: \(noulTemperature), choiceTemperature: \(choiceTemperature), scoreTemperature: \(scoreTemperature)))
        """
    }

    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Before → after on the marked answers, per kind.
struct CalibrationReport {
    struct Row: Identifiable {
        var id: String { kind.rawValue }
        let kind: DecisionCalibration.Sample.Kind
        let temperature: Double
        let before: DecisionCalibration.Measurement
        let after: DecisionCalibration.Measurement
    }
    let rows: [Row]
}

extension DecisionCalibration.Sample.Kind {
    init(_ k: QuestionKind) {
        switch k {
        case .noul: self = .noul
        case .choice: self = .choice
        case .score: self = .score
        }
    }

    var displayName: String {
        switch self {
        case .noul: "Noul (yes / no)"
        case .choice: "Choice"
        case .score: "Score"
        }
    }
}

enum Calibrator {
    /// Calibration samples from the local backend's raw answers in `rows`, for every question whose
    /// correct answer the developer marked.
    static func samples(rows: [BatchRow], labels: [String: [String: String]], localLabelPrefix: String = "Local")
        -> [DecisionCalibration.Sample]
    {
        rows.flatMap { row -> [DecisionCalibration.Sample] in
            guard let marks = labels[row.input],
                  let local = row.runs.first(where: { $0.label.hasPrefix(localLabelPrefix) })?.result else { return [] }
            return local.results.compactMap { r in
                guard let key = marks[r.question.name], let i = r.keys.firstIndex(of: key) else { return nil }
                return .init(kind: .init(r.question.kind), probabilities: r.rawProbabilities, correct: [i])
            }
        }
    }

    static func report(_ samples: [DecisionCalibration.Sample], _ calibration: DecisionCalibration) -> CalibrationReport {
        CalibrationReport(rows: DecisionCalibration.Sample.Kind.allCases.compactMap { k in
            let s = samples.filter { $0.kind == k }
            guard !s.isEmpty else { return nil }
            return .init(kind: k, temperature: calibration.temperature(for: k),
                         before: DecisionCalibration.none.measure(s), after: calibration.measure(s))
        })
    }

    /// `result`'s local answers as `calibration` reports them.
    static func applying(_ calibration: DecisionCalibration, to result: DecisionResult) -> DecisionResult {
        let rows = result.results.map { r in
            r.showing(calibration.apply(r.rawProbabilities, kind: .init(r.question.kind)), calibrated: true)
        }
        return DecisionResult(input: result.input, results: rows, sharedPrefixTokens: result.sharedPrefixTokens,
                              milliseconds: result.milliseconds, backend: result.backend, usage: result.usage)
    }
}
