import SwiftUI
import LocalLMLabSDKCore
import LocalLMLabSDKComponents

@main
@available(macOS 27, *)
struct ModelSwitchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Model Switch") {
            ChatView(model: model)
                .frame(minWidth: 520, minHeight: 460)
        }
        Settings {
            SettingsScreen(model: model)
                .frame(width: 560, height: 620)
        }
    }
}

@available(macOS 27, *)
private struct SettingsScreen: View {
    @Bindable var model: AppModel
    var body: some View {
        AIModelsSettingsView(
            registry: model.lab.models,
            providers: $model.providers,
            onSave: { model.applyDraft($0) },
            onRemove: { model.removeDraft($0) },
            onTest: { await model.testDraft($0) })
    }
}

@available(macOS 27, *)
private struct ChatView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
            Divider()
            composer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Model", selection: $model.selectedModel) {
                ForEach(model.availableModels, id: \.rawValue) { id in
                    Text(id.rest.isEmpty ? id.scheme : "\(id.scheme): \(id.rest)").tag(id)
                }
            }
            .frame(maxWidth: 320)

            Toggle("Web search", isOn: $model.webSearchThisTurn)
                .toggleStyle(.switch)

            Spacer()
            SettingsLink { Label("Providers", systemImage: "gearshape") }
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.transcript) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.role == .user ? "You" : "Assistant")
                            .font(.caption).foregroundStyle(.secondary)
                        if !line.searches.isEmpty {
                            Label(line.searches.joined(separator: " · "), systemImage: "magnifyingglass")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(line.text.isEmpty ? "…" : line.text)
                            .textSelection(.enabled)
                        if !line.citations.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(line.citations) { c in
                                    Link(c.title, destination: URL(string: c.url) ?? URL(string: "https://example.com")!)
                                        .font(.caption)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }

    private var composer: some View {
        HStack {
            TextField("Ask anything…", text: $model.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { Task { await model.send() } }
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(model.isResponding || model.input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }
}
