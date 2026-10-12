import AppKit
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import OpenJevKit
import SwiftUI

/// Fit the local model's confidence to the answers the developer marked correct, see the
/// before → after, preview it, and copy the code for the app.
struct CalibrationSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let samples = model.calibrationSamples
        let byKind = Dictionary(grouping: samples, by: \.kind)
        VStack(alignment: .leading, spacing: 14) {
            Text("Calibrate the local model").font(.jHeadline)
            Text("""
                A small local model often says 100% even when it's wrong. Calibration softens its \
                confidence so that "80% sure" means right about 80% of the time. It never changes which \
                answer wins. It's fitted on answers you mark correct in the batch grid, for this model, \
                these system instructions and your kind of questions, so your app uses the result you \
                fit here.
                """)
                .font(.jCallout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Your marked answers") {
                VStack(alignment: .leading, spacing: 6) {
                    if samples.isEmpty {
                        Text("None yet. Run a batch with the local backend on, then use “mark…” under each cell to record the correct answer.")
                            .font(.jCallout).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 16) {
                            ForEach(DecisionCalibration.Sample.Kind.allCases, id: \.self) { k in
                                kindCount(k, byKind[k]?.count ?? 0)
                            }
                        }
                        .font(.jCallout)
                        if (byKind.values.map(\.count).min() ?? 0) < 30 {
                            Text("Aim for 30 or more marked answers per kind you use; with fewer, the fit follows these examples too closely to carry over.")
                                .font(.jCaption).foregroundStyle(.orange)
                        }
                    }
                    let acc = model.markedAccuracy
                    if !acc.isEmpty {
                        Divider()
                        Text("Right answers on your marks").font(.jCaption.weight(.semibold))
                        ForEach(acc, id: \.label) { a in
                            Text("\(a.label): \(a.right)/\(a.total) (\(percent(Double(a.right) / Double(max(a.total, 1)))))")
                                .font(.jCaption.monospacedDigit())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button("Fit calibration") { model.fitCalibration() }
                    .buttonStyle(.borderedProminent)
                    .disabled(samples.isEmpty || model.selectedModel == nil)
                if let m = model.selectedModel {
                    Text("for \(m.repoID)\(m.shortRevision.map { " @ \($0)" } ?? "")").font(.jCaption).foregroundStyle(.secondary)
                }
            }

            if let c = model.calibration {
                result(c, samples: samples)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
        .font(.jBody)
    }

    private func kindCount(_ k: DecisionCalibration.Sample.Kind, _ n: Int) -> some View {
        let color: Color = n == 0 ? .secondary : (n >= 30 ? .primary : .orange)
        return Label("\(k.displayName): \(n)", systemImage: n >= 30 ? "checkmark.circle" : "circle.dotted")
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func result(_ c: FittedCalibration, samples: [DecisionCalibration.Sample]) -> some View {
        GroupBox("Fitted") {
            VStack(alignment: .leading, spacing: 8) {
                if let why = model.calibrationMismatch {
                    Label("Doesn't match the current setup: \(why). Refit, or switch back.", systemImage: "exclamationmark.triangle")
                        .font(.jCallout).foregroundStyle(.orange)
                }
                let report = Calibrator.report(samples, c.sdk)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Kind"); Text("Temperature"); Text("Marked"); Text("Calibration error"); Text("Log-loss")
                    }
                    .font(.jCaption.weight(.semibold))
                    ForEach(report.rows) { r in
                        GridRow {
                            Text(r.kind.displayName)
                            Text(String(format: "%.2f", r.temperature))
                            Text("\(r.before.count)")
                            Text(String(format: "%.3f → %.3f", r.before.expectedCalibrationError, r.after.expectedCalibrationError))
                            Text(String(format: "%.2f → %.2f", r.before.logLoss, r.after.logLoss))
                        }
                        .font(.jCaption.monospacedDigit())
                    }
                }
                Text("Lower is better. Measured on the same answers it was fitted on, so expect a little less on new inputs. Accuracy doesn't change.")
                    .font(.jCaption).foregroundStyle(.secondary)

                Toggle("Show local results calibrated in JevDK", isOn: $model.applyCalibration)
                    .disabled(model.calibrationMismatch != nil)

                Text("For your app").font(.jCaption.weight(.semibold))
                Text(c.swiftSnippet)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Export Questions…") { model.exportForApp() }
                    Button("Copy code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c.swiftSnippet, forType: .string)
                    }
                    Text("Saved with the question set (⌘S).").font(.jCaption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}
