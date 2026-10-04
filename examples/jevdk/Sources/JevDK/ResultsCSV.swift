import Foundation
import OpenJevKit

// "Append results to CSV" for a batch run: one row per input × question × backend, appended to an
// existing results CSV so runs of different models, quantizations, wrappers or question wordings
// line up in one spreadsheet. Same conventions as the LocalLM Lab benchmark CSV: fixed header,
// append only to a file with exactly this header, never touch any other file, an unmeasured value
// is an empty cell. Average `correct` (yes = 1) by `model` and `question` for per-question accuracy.

enum ResultsCSV {
    static let columns = [
        "run_id", "saved_at", "app", "sdk_version", "machine", "question_set",
        "backend", "model", "model_revision", "model_size_gb", "moe", "wrapper_label", "wrapper_system", "calibrated",
        "input", "question", "question_kind", "question_text",
        "expected", "answer", "correct", "confidence", "probabilities", "label_mass",
        "question_ms", "decision_ms", "input_tokens", "cost_usd",
    ]

    static var header: String { columns.joined(separator: ",") }

    /// A run id: the local date and time the batch started, plus a short suffix so two runs in the
    /// same second stay apart, e.g. "2026-10-03 14:32:05 · a1b2".
    static func newRunID(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(f.string(from: date)) · \(String(UUID().uuidString.prefix(4)).lowercased())"
    }

    /// How many characters of an input, question text or system prompt a row keeps.
    static let previewLength = 200

    /// What a run had in common, stamped on every row.
    struct RunInfo {
        let runID: String
        let savedAt: Date
        let sdkVersion: String
        let machine: String
        let questionSet: String
    }

    /// What one backend was, for its rows.
    struct BackendInfo {
        let backend: String
        let model: String
        let revision: String?
        let sizeBytes: Int64?
        let isMoE: Bool?
        let wrapperLabel: String?
        let wrapperSystem: String?
    }

    static func rows(run: RunInfo, backend: BackendInfo, result: DecisionResult, labels: [String: String],
                     inputTokens: Int?, costUSD: Double?) -> [String] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        return result.results.map { r in
            let expected = labels[r.question.name]
            let calibrated = r.fidelity == .tokenScored(calibrated: true)
            let cells: [String] = [
                run.runID, iso.string(from: run.savedAt), "JevDK", run.sdkVersion, run.machine, run.questionSet,
                backend.backend, backend.model, backend.revision ?? "",
                backend.sizeBytes.map { String(format: "%.2f", Double($0) / 1e9) } ?? "",
                backend.isMoE.map { $0 ? "yes" : "no" } ?? "",
                backend.wrapperLabel ?? "", backend.wrapperSystem.map(preview) ?? "", calibrated ? "yes" : "no",
                preview(result.input), r.question.name, r.question.kind.rawValue, preview(r.question.text),
                expected ?? "", r.answer, expected.map { $0 == r.answer ? "yes" : "no" } ?? "",
                String(format: "%.4f", r.confidence),
                zip(r.keys, r.probabilities).map { "\($0)=\(String(format: "%.4f", $1))" }.joined(separator: "; "),
                backend.wrapperLabel == nil ? "" : String(format: "%.4f", r.labelMass),
                String(format: "%.1f", r.milliseconds), String(format: "%.1f", result.milliseconds),
                inputTokens.map(String.init) ?? "", costUSD.map { String(format: "%.6f", $0) } ?? "",
            ]
            return cells.map(escape).joined(separator: ",")
        }
    }

    static func preview(_ s: String) -> String {
        String(s.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(previewLength))
    }

    /// RFC 4180: quote a cell that holds a comma, quote or line break; double any quotes inside.
    static func escape(_ cell: String) -> String {
        guard cell.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    enum WritePlan: Equatable {
        /// No file, or an empty one: write the header, then the rows.
        case newFile
        /// A JevDK results CSV: append (after a line break, if the file lacks a final one).
        case append(needsLineBreak: Bool)
        /// Some other CSV, or one with different columns: don't touch it.
        case mismatch
    }

    static func plan(existing contents: String?) -> WritePlan {
        guard let contents, !contents.isEmpty else { return .newFile }
        // Up to any line break: "\r\n" (how Excel saves CSV) is one Character in Swift.
        let firstLine = String(contents.prefix { !$0.isNewline })
        guard firstLine == header else { return .mismatch }
        return .append(needsLineBreak: !(contents.last?.isNewline ?? false))
    }

    /// Append `lines` to `url` (creating it with the header), or throw if it's some other file.
    static func append(_ lines: [String], to url: URL) throws {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        var text: String
        switch plan(existing: existing) {
        case .newFile:
            text = header + "\n"
        case .append(let needsLineBreak):
            text = needsLineBreak ? "\n" : ""
        case .mismatch:
            throw CSVError.mismatch(url.lastPathComponent)
        }
        text += lines.joined(separator: "\n") + "\n"
        if existing == nil || existing?.isEmpty == true {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
    }

    enum CSVError: LocalizedError {
        case mismatch(String)
        var errorDescription: String? {
            switch self {
            case .mismatch(let name):
                "\(name) isn't a JevDK results file (its header is different), so it was left untouched. Choose another file or a new one."
            }
        }
    }

    /// e.g. "Mac17,14 · 64 GB".
    static var machine: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(cString: buf)
        let ram = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return "\(model) · \(ram) GB"
    }
}
