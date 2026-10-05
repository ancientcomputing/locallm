import OpenJevKit
import SwiftUI

/// Right pane: one input with full detail, or many inputs as a grid. Every enabled backend
/// (local, Featherless, OpenRouter · TypeSafe) answers the same questions, shown together.
struct ResultsView: View {
    @Bindable var model: AppModel
    @State private var mode = Mode.single
    @State private var showCalibration = false

    enum Mode: String, CaseIterable { case single = "Single input", batch = "Batch" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            if let msg = model.errorMessage {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.jCallout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            } else if let msg = model.notice {
                HStack(alignment: .top) {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.jCallout)
                        .textSelection(.enabled)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            switch mode {
            case .single: single
            case .batch: batch
            }
        }
    }

    // MARK: Single

    private var single: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Input").font(.jCallout.weight(.medium))
                    Spacer()
                    ForEach(model.samples.indices, id: \.self) { i in
                        Button(model.samples[i].0) {
                            model.input = model.samples[i].1
                            Task { await model.run() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(model.input == model.samples[i].1 ? .accentColor : nil)
                    }
                }
                TextEditor(text: $model.input)
                    .font(.jBody)
                    .frame(minHeight: 70, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button {
                        Task { await model.run() }
                    } label: {
                        Label("Ask", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning || model.set.questions.isEmpty)
                    if model.isRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(model.activeBackendLabels.joined(separator: " · ")).font(.jCaption).foregroundStyle(.secondary)
                }

                if model.results.isEmpty {
                    HowItWorks()
                        .padding(.top, 12)
                } else {
                    let shown = model.results.map(model.display)
                    if let first = shown.first(where: { $0.result != nil })?.result, first.input != model.input {
                        Text("Results are for the previous input.").font(.jCaption).foregroundStyle(.secondary)
                    }
                    RunSummary(runs: shown)
                    ForEach(questionIDs, id: \.self) { qid in
                        QuestionCompareCard(entries: shown.map { run in
                            (run.label, run.result?.results.first { $0.question.id == qid }, run.error)
                        })
                    }
                }
            }
            .padding()
        }
    }

    /// Question ids in the order the first successful backend answered them.
    private var questionIDs: [UUID] {
        model.results.first { $0.result != nil }?.result?.results.map(\.question.id) ?? []
    }

    // MARK: Batch

    private var batch: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inputs, one per line").font(.jCallout.weight(.medium))
            TextEditor(text: $model.batchText)
                .font(.jCallout)
                .frame(minHeight: 90, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                if model.batchProgress != nil {
                    Button("Stop") { model.stopBatch() }
                } else {
                    Button {
                        model.runBatch()
                    } label: {
                        Label("Ask all \(model.batchInputs.count)", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning || model.batchInputs.isEmpty || model.set.questions.isEmpty)
                }
                if let p = model.batchProgress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 140)
                    Text("\(p.done)/\(p.total)").font(.jCaption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.markedCount > 0 {
                    Text("\(model.markedCount) correct answers marked").font(.jCaption).foregroundStyle(.secondary)
                }
                if model.applyCalibration, model.calibration != nil, model.calibrationMismatch == nil {
                    Label("calibrated", systemImage: "dial.medium").font(.jCaption).foregroundStyle(.tint)
                }
                Menu {
                    Button("Import Answers (CSV)…") { model.importAnswerSet() }
                    Button("Export Answers (CSV)…") { model.exportAnswerSet() }
                } label: {
                    Label("Answers", systemImage: "checklist")
                }
                .fixedSize()
                .help("Load inputs with their correct answers from a CSV (input column, then one column per question), or save yours")
                Button("Calibrate…") { showCalibration = true }
                    .help("Mark correct answers in the grid, then fit a calibration for the local model")
                Menu {
                    if let path = model.resultsCSVPath {
                        Button("Append to \(URL(fileURLWithPath: path).lastPathComponent)") { model.appendResults(choose: false) }
                    }
                    Button("Append to another CSV…") { model.appendResults(choose: true) }
                } label: {
                    Label("Results CSV", systemImage: "tablecells")
                } primaryAction: {
                    model.appendResults(choose: model.resultsCSVPath == nil)
                }
                .fixedSize()
                .disabled(model.batchRows.isEmpty || model.batchProgress != nil)
                .help("Append this run to a results CSV: one row per input × question × backend, with the model, your marked answer, the answer, confidence and timing. Later runs append, so models line up in one spreadsheet.")
            }
            if let a = model.lastAppend {
                Text("Appended \(a.rows) rows to \(a.file).").font(.jCaption).foregroundStyle(.secondary)
            }
            BatchGrid(model: model)
        }
        .padding()
        .sheet(isPresented: $showCalibration) { CalibrationSheet(model: model) }
    }
}

/// Per backend: time, tokens/cost, or the error.
struct RunSummary: View {
    let runs: [BackendRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(runs) { run in
                HStack(spacing: 6) {
                    Text(run.label).fontWeight(.medium)
                    if let r = run.result {
                        Text("\(Int(r.milliseconds)) ms").foregroundStyle(.secondary)
                        if let u = r.usage { Text("· \(u)").foregroundStyle(.secondary) }
                        if r.sharedPrefixTokens > 0 { Text("· \(r.sharedPrefixTokens) shared prompt tokens").foregroundStyle(.secondary) }
                    } else if let e = run.error {
                        Text(e).foregroundStyle(.orange).lineLimit(2)
                    }
                }
            }
        }
        .font(.jCaption)
    }
}

/// One question, answered by each backend.
struct QuestionCompareCard: View {
    let entries: [(label: String, result: QuestionResult?, error: String?)]
    @State private var showPrompt: String?

    private var question: EditableQuestion? { entries.compactMap(\.result).first?.question }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let q = question {
                    HStack(alignment: .firstTextBaseline) {
                        Text(q.name).font(.system(size: 14, design: .monospaced).weight(.semibold))
                        Text(q.kind.displayName).font(.jCaption).foregroundStyle(.secondary)
                        Spacer()
                        if agreement == false {
                            Label("Backends disagree", systemImage: "arrow.triangle.branch")
                                .font(.jCaption).foregroundStyle(.orange)
                        }
                    }
                    Text(q.text).font(.jCaption).foregroundStyle(.secondary)
                }
                ForEach(entries.indices, id: \.self) { i in
                    let e = entries[i]
                    if let r = e.result {
                        BackendAnswer(label: e.label, result: r, showPrompt: showPrompt == e.label) {
                            showPrompt = showPrompt == e.label ? nil : e.label
                        }
                    } else if let err = e.error {
                        Text("\(e.label): \(err)").font(.jCaption).foregroundStyle(.orange)
                    }
                    if i < entries.count - 1 { Divider() }
                }
            }
            .padding(4)
        }
    }

    /// nil when fewer than two backends answered.
    private var agreement: Bool? {
        let answers = entries.compactMap(\.result).map(\.answer)
        return answers.count < 2 ? nil : Set(answers).count == 1
    }
}

/// One backend's bars for one question.
struct BackendAnswer: View {
    let label: String
    let result: QuestionResult
    let showPrompt: Bool
    let togglePrompt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.jCaption.weight(.semibold))
                Text(fidelityText).font(.jCaption2).foregroundStyle(.secondary)
                Spacer()
                Text(result.answer).font(.jHeadline)
                Text(percent(result.confidence))
                    .font(.jHeadline.monospacedDigit())
                    .foregroundStyle(confidenceColor(result.confidence))
            }
            ForEach(result.keys.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text(result.labels[i])
                        .font(.system(size: 12, design: .monospaced).weight(.bold))
                        .lineLimit(1)
                        .frame(width: 28, alignment: .leading)
                    Text(optionText(i))
                        .font(.jCaption)
                        .lineLimit(1)
                        .frame(width: 175, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(i == result.topIndex ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.5)))
                                .frame(width: max(2, g.size.width * result.probabilities[i]))
                        }
                    }
                    .frame(height: 8)
                    Text(percent(result.probabilities[i]))
                        .font(.jCaption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
            }
            HStack {
                if result.labelMass < 0.9 {
                    Label("Off format: only \(percent(result.labelMass)) of the probability was on the allowed answers.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(showPrompt ? "Hide" : (label.hasPrefix("Local") ? "Show prompt" : "Show request"), action: togglePrompt)
                    .buttonStyle(.link)
            }
            .font(.jCaption)
            if showPrompt {
                Text(result.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var fidelityText: String {
        switch result.fidelity {
        case .native: "decision model"
        case .tokenScored(let calibrated): calibrated ? "token-scored, calibrated" : "token-scored"
        @unknown default: ""
        }
    }

    private func optionText(_ i: Int) -> String {
        switch result.question.kind {
        case .noul: ""
        case .choice: result.keys[i]
        case .score: result.descriptions[i]
        }
    }
}

/// Inputs × questions; each cell has one line per backend, and a "mark…" menu to record the
/// correct answer (for calibration and per-backend accuracy).
struct BatchGrid: View {
    let model: AppModel

    var body: some View {
        let rows = model.batchRows.map { BatchRow(input: $0.input, runs: $0.runs.map(model.display)) }
        if let first = rows.first, let template = first.runs.first(where: { $0.result != nil })?.result {
            Text("\(template.results.count) questions × \(rows.count) inputs\(first.runs.count > 1 ? " × \(first.runs.count) backends" : "") · one column per question; scroll sideways if they don't all fit, or hide the questions panel (toolbar) for more room")
                .font(.jCaption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Input").font(.jCaption.weight(.semibold))
                        ForEach(template.results) { r in
                            QuestionHeader(result: r)
                        }
                    }
                    if first.runs.count > 1 {
                        GridRow {
                            Text(first.runs.enumerated().map { "\(tag($0.offset)) \($0.element.label)" }.joined(separator: "   "))
                                .font(.jCaption2).foregroundStyle(.secondary)
                                .gridCellColumns(template.results.count + 1)
                        }
                    }
                    Divider()
                    ForEach(rows) { row in
                        GridRow(alignment: .top) {
                            Text(row.input)
                                .font(.jCaption)
                                .lineLimit(4)
                                .frame(width: 220, alignment: .leading)
                                .help(row.input)
                            ForEach(template.results.indices, id: \.self) { qi in
                                let q = template.results[qi]
                                let mark = model.label(input: row.input, question: q.question.name)
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(row.runs.indices, id: \.self) { bi in
                                        cell(row.runs[bi], qi, tag: row.runs.count > 1 ? tag(bi) : nil, mark: mark)
                                    }
                                    markMenu(row.input, q, mark)
                                }
                                .padding(3)
                                .frame(minWidth: 150, alignment: .leading)
                                .background(disagrees(row, qi) ? Color.orange.opacity(0.08) : .clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
        } else if let err = rows.first?.runs.first?.error {
            Text(err).foregroundStyle(.orange).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Batch asks the same questions about every input above, like a spreadsheet: one row per input, one column per question, each cell an answer. Hover a cell for every option's probability. Use “mark…” under a cell to record the correct answer: each backend then shows ✓ or ✗, and Calibrate… fits the local model's confidence to your marks.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func tag(_ i: Int) -> String { ["①", "②", "③", "④"][min(i, 3)] }

    @ViewBuilder
    private func cell(_ run: BackendRun, _ qi: Int, tag: String?, mark: String?) -> some View {
        if let results = run.result?.results, results.indices.contains(qi) {
            let r = results[qi]
            let verdict = mark.map { $0 == r.answer ? "✓ " : "✗ " } ?? ""
            Text("\(tag.map { $0 + " " } ?? "")\(verdict)\(r.answer) \(percent(r.confidence))")
                .font(.jCaption.monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(confidenceColor(r.confidence).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                .help("\(run.label)\(r.fidelity == .tokenScored(calibrated: true) ? " (calibrated)" : "")\n"
                      + zip(r.keys, r.probabilities).map { "\($0): \(percent($1))" }.joined(separator: "\n"))
        } else {
            Text("\(tag.map { $0 + " " } ?? "")error").font(.jCaption).foregroundStyle(.orange).help(run.error ?? "")
        }
    }

    private func markMenu(_ input: String, _ q: QuestionResult, _ mark: String?) -> some View {
        Menu {
            ForEach(q.keys, id: \.self) { key in
                Button(key) { model.setLabel(key, input: input, question: q.question.name) }
            }
            if mark != nil {
                Divider()
                Button("Clear") { model.setLabel(nil, input: input, question: q.question.name) }
            }
        } label: {
            Text(mark.map { "correct: \($0)" } ?? "mark…")
                .font(.jCaption2)
                .foregroundStyle(mark == nil ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The correct answer for this input")
    }

    private func disagrees(_ row: BatchRow, _ qi: Int) -> Bool {
        let answers = row.runs.compactMap { $0.result?.results }.filter { $0.indices.contains(qi) }.map { $0[qi].answer }
        return answers.count > 1 && Set(answers).count > 1
    }
}

/// A batch-grid column header: the question's name, then the answers it allows. Hover for the
/// question text and each option's description.
struct QuestionHeader: View {
    let result: QuestionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(result.question.name).font(.system(size: 12, design: .monospaced).weight(.semibold))
            Text(options).font(.jCaption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: 200, alignment: .leading)
        .help(detail)
    }

    private var options: String {
        switch result.question.kind {
        case .noul: "Yes / No"
        case .choice: result.keys.joined(separator: " / ")
        case .score: zip(result.keys, result.descriptions).map { "\($0) \($1)" }.joined(separator: " · ")
        }
    }

    private var detail: String {
        var s = "\(result.question.text)\n\n\(result.question.kind.displayName)"
        if result.question.kind != .noul {
            s += "\n" + zip(result.keys, result.descriptions)
                .map { k, d in d.isEmpty || d == k ? "• \(k)" : "• \(k): \(d)" }.joined(separator: "\n")
        }
        return s
    }
}

func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

func confidenceColor(_ p: Double) -> Color {
    p >= 0.9 ? .green : p >= 0.6 ? .yellow : .orange
}

/// Shown before the first Ask: what a decider does, in three lines.
struct HowItWorks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How this works").font(.jCallout.weight(.semibold))
            row("1", "One input", "a message, a query, a review: whatever your app needs to decide about.")
            row("2", "A few fixed questions", "on the left. Each allows only certain answers: yes / no, one of several options, or a point on a scale.")
            row("3", "One answer per question", "with how sure the model is. No text is written; your app acts on the answers in code.")
            Text("Try Examples → Customer support, then click a sample message above the input box. Batch runs the same questions over many inputs at once.")
                .font(.jCaption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(n)
                .font(.jCaption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(.tint.opacity(0.18), in: Circle())
            (Text(title).fontWeight(.medium) + Text(": ") + Text(detail).foregroundStyle(.secondary))
                .font(.jCallout)
        }
    }
}
