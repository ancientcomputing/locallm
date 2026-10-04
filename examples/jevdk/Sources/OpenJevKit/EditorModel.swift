import Foundation
import LocalLMLabSDKCore

// What JevDK's editor edits and its results show. The decision API itself is the SDK's
// (`DecisionQuestion`, `lab.decide`, `Decision`); these types add what a playground needs on top:
// stable identities for editing, a saved-file format, and per-answer display rows.

/// What kind of answer a question takes. Jev's names.
public enum QuestionKind: String, Codable, CaseIterable, Sendable {
    /// True or false; the answer is the probability it's true.
    case noul
    /// One of several named options.
    case choice
    /// An ordered scale, low to high. Small local models do worst on these.
    case score

    public var displayName: String {
        switch self {
        case .noul: "Noul (yes / no)"
        case .choice: "Choice"
        case .score: "Score"
        }
    }

    // Files saved before the rename used yesNo / choice / scale.
    public init(from decoder: Swift.Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "noul", "yesNo": self = .noul
        case "choice": self = .choice
        case "score", "scale": self = .score
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown question kind \(raw)"))
        }
    }
}

/// One option of a choice question, or one level of a score question.
public struct AnswerOption: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// What the app reads back (choice only; a score's levels are `0`, `1`, …).
    public var key: String
    /// What the model reads next to the option.
    public var description: String

    public init(id: UUID = UUID(), key: String, description: String) {
        self.id = id; self.key = key; self.description = description
    }

    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decode(String.self, forKey: .key)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

/// A question as the editor holds it.
public struct EditableQuestion: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The id the app reads the answer by, e.g. `needsLiveData`.
    public var name: String
    public var kind: QuestionKind
    /// The question as the model reads it (Jev's `instructions`).
    public var text: String
    /// Choice options or score levels. Ignored for noul.
    public var options: [AnswerOption]

    public init(id: UUID = UUID(), name: String, kind: QuestionKind, text: String, options: [AnswerOption] = []) {
        self.id = id; self.name = name; self.kind = kind; self.text = text; self.options = options
    }

    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(QuestionKind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        options = try c.decodeIfPresent([AnswerOption].self, forKey: .options) ?? []
    }

    /// The SDK question this becomes.
    public var sdkQuestion: DecisionQuestion {
        switch kind {
        case .noul:
            return .noul(name, text)
        case .choice:
            return DecisionQuestion(id: name, instructions: text, kind: .choice(criteria: options.map {
                .init($0.key.isEmpty ? $0.description : $0.key, $0.description.isEmpty ? nil : $0.description)
            }))
        case .score:
            return .score(name, text, criteria: options.map(\.description))
        }
    }

    /// Editor-side problems, shown under the card. `lab.decide` validates again before sending.
    public var problems: [String] {
        var p: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { p.append("needs a name") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.append("question text is empty") }
        if kind != .noul {
            if options.count < 2 { p.append("needs at least 2 options") }
            if options.contains(where: { $0.description.trimmingCharacters(in: .whitespaces).isEmpty }) {
                p.append("an option has no description")
            }
            if kind == .choice {
                let keys = options.map { $0.key.isEmpty ? $0.description : $0.key }
                if Set(keys).count != keys.count { p.append("option keys must be unique") }
            }
        }
        return p
    }
}

/// A named set of questions plus the local wrapper they're tuned with. What JevDK saves.
public struct QuestionSet: Codable, Hashable, Sendable {
    /// The SDK's `OpenJevWrapper.default` (chosen with the eval, D1b), mirrored here so this
    /// module needs only Core. JevDK checks they match at launch.
    public static let defaultSystem = "You answer questions about a piece of text. Read the text, then answer the question about it. Reply with only the label of the correct answer."
    public static let defaultInputLabel = "Text"

    public var name: String
    /// Local OpenJev's wrapper instructions. Hosted Jev never sees them.
    public var system: String
    /// What the input is called in the local prompt ("Input", "Request", …).
    public var inputLabel: String
    public var questions: [EditableQuestion]

    public init(name: String, system: String = QuestionSet.defaultSystem, inputLabel: String = QuestionSet.defaultInputLabel,
                questions: [EditableQuestion]) {
        self.name = name; self.system = system; self.inputLabel = inputLabel; self.questions = questions
    }

    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        system = try c.decodeIfPresent(String.self, forKey: .system) ?? QuestionSet.defaultSystem
        inputLabel = try c.decodeIfPresent(String.self, forKey: .inputLabel) ?? QuestionSet.defaultInputLabel
        questions = try c.decode([EditableQuestion].self, forKey: .questions)
    }

}

// MARK: - Display

/// What a local run measured per question beyond the `Decision` (from the SDK's
/// `OpenJevDiagnostics`).
public struct QuestionDiagnostics: Sendable {
    /// The single-token labels the model was asked for.
    public let labels: [String]
    /// The exact text the model received.
    public let prompt: String
    /// Probability on the allowed labels before normalising.
    public let labelMass: Double
    public let milliseconds: Double

    public init(labels: [String], prompt: String, labelMass: Double, milliseconds: Double) {
        self.labels = labels; self.prompt = prompt; self.labelMass = labelMass; self.milliseconds = milliseconds
    }
}

/// One question's answer as a row of bars: the SDK `Decision` plus, for local runs, the
/// OpenJev diagnostics the SDK API doesn't carry.
public struct QuestionResult: Identifiable, Sendable {
    public var id: UUID { question.id }
    public let question: EditableQuestion
    public let keys: [String]
    /// The labels the local model was asked for (`A`, `0`, `Yes`); keys for hosted runs.
    public let labels: [String]
    public let descriptions: [String]
    /// As shown: calibrated when JevDK is applying a calibration, raw otherwise.
    public let probabilities: [Double]
    /// As the backend returned them, before any calibration JevDK applies. What calibration is
    /// fitted on.
    public let rawProbabilities: [Double]
    /// The answer's confidence as the backend reports it.
    public let confidence: Double
    /// Local only: probability on the allowed labels before normalising. 1 for hosted runs.
    public let labelMass: Double
    /// Local: the exact prompt. Hosted: the exact request JSON.
    public let prompt: String
    public let milliseconds: Double
    public let fidelity: DecisionFidelity

    public var topIndex: Int { probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0 }
    public var answer: String { keys[topIndex] }

    /// This answer with `probabilities` shown instead (a calibration applied to the raw ones).
    public func showing(_ probabilities: [Double], calibrated: Bool) -> QuestionResult {
        let top = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
        return QuestionResult(question: question, keys: keys, labels: labels, descriptions: descriptions,
                              probabilities: probabilities, rawProbabilities: rawProbabilities,
                              confidence: probabilities.isEmpty ? 0 : probabilities[top], labelMass: labelMass,
                              prompt: prompt, milliseconds: milliseconds,
                              fidelity: .tokenScored(calibrated: calibrated))
    }

    /// Build display rows from an SDK decision. `diagnostics` (local) supplies labels, prompts and
    /// label mass; `prompt` is used for every row otherwise (hosted: the request JSON).
    public static func rows(for questions: [EditableQuestion], decision d: Decision,
                            diagnostics: [String: QuestionDiagnostics] = [:], prompt: String = "") -> [QuestionResult] {
        let perQuestionMS = Double(d.latency.components.seconds) * 1000 / Double(max(questions.count, 1))
            + Double(d.latency.components.attoseconds) / 1e15 / Double(max(questions.count, 1))
        return questions.compactMap { q in
            let diag = diagnostics[q.name]
            let keys: [String], descs: [String], probs: [Double], conf: Double
            switch d.answers[q.name] {
            case .noul(let p)?:
                keys = ["Yes", "No"]; descs = ["", ""]; probs = [p, 1 - p]; conf = max(p, 1 - p)
            case .choice(let c)?:
                let sq = q.sdkQuestion
                guard case .choice(let criteria) = sq.kind else { return nil }
                keys = criteria.map(\.key); descs = criteria.map { $0.description ?? "" }
                probs = keys.map { c.probabilities[$0] ?? 0 }; conf = c.confidence
            case .score(let s)?:
                keys = s.legend.indices.map(String.init); descs = s.legend; probs = s.probabilities; conf = s.confidence
            default:
                return nil
            }
            return QuestionResult(
                question: q, keys: keys, labels: diag?.labels ?? keys, descriptions: descs, probabilities: probs,
                rawProbabilities: probs, confidence: conf, labelMass: diag?.labelMass ?? 1, prompt: diag?.prompt ?? prompt,
                milliseconds: diag?.milliseconds ?? perQuestionMS, fidelity: d.fidelity)
        }
    }
}

/// All the questions' answers for one input from one backend.
public struct DecisionResult: Sendable {
    public let input: String
    public let results: [QuestionResult]
    /// Local only: prompt tokens shared by every question and computed once.
    public let sharedPrefixTokens: Int
    public let milliseconds: Double
    public let backend: String
    /// Hosted only: tokens and cost.
    public var usage: String?

    public init(input: String, results: [QuestionResult], sharedPrefixTokens: Int, milliseconds: Double,
                backend: String, usage: String? = nil) {
        self.input = input; self.results = results; self.sharedPrefixTokens = sharedPrefixTokens
        self.milliseconds = milliseconds; self.backend = backend; self.usage = usage
    }
}

extension DecisionUsage {
    /// "532 in / 105 out tokens · $0.000022"
    public var summary: String? {
        var parts: [String] = []
        if let i = inputTokens, let o = outputTokens { parts.append("\(i) in / \(o) out tokens") }
        if let c = cost { parts.append(String(format: "$%.6f", c)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
