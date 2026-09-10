import SwiftUI

struct RunPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.availableProviders.count > 1 {
                    Picker("Model", selection: Binding(
                        get: { model.provider }, set: { model.provider = $0 })) {
                        ForEach(model.availableProviders) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                } else if let only = model.availableProviders.first {
                    Text(only.label).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.1fs", model.elapsed))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(model.isRunning ? .primary : .secondary)
                Button(model.isRunning ? "Running…" : "Run") {
                    Task { await model.run() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isRunning || model.availableProviders.isEmpty)
            }

            TextEditor(text: Binding(get: { model.prompt }, set: { model.prompt = $0 }))
                .font(.system(size: 13))
                .frame(height: 56)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))

            if let note = model.setupNote {
                Text(note).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            ScrollView {
                Text(model.output.isEmpty ? " " : model.output)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            if !model.toolLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool calls").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(model.toolLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
    }
}
