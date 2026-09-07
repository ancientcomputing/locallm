import LocalLMLabSDKCore
import SwiftUI

/// One online-provider block in an "AI Models" settings panel (docs/12 §5): an API-key field,
/// a **Configured ✓ / Not configured** badge, a model-id list editor, and — once configured
/// and if the wire supports it — an **Enable web search** toggle with a **Max searches**
/// stepper.
///
/// Fully controlled: it edits a `Binding<RemoteProviderDraft>` and calls `onSave` when the
/// user commits a change (so the host can rebuild + re-register the provider and persist the
/// key), or `onRemove` to drop it.
@available(macOS 26.0, *)
public struct ProviderSettingsSection: View {
    @Binding private var draft: RemoteProviderDraft
    private let onSave: (RemoteProviderDraft) -> Void
    private let onRemove: (() -> Void)?
    private let onTest: ((RemoteProviderDraft) async -> ProviderTestOutcome)?

    @State private var newModelText = ""
    @State private var keyDraft: String
    @State private var testing = false
    @State private var testResult: ProviderTestOutcome?

    /// - Parameters:
    ///   - onTest: runs a zero-token connectivity/key/model check against the provider
    ///     (docs/12 §11) and returns the outcome. `nil` (the default) hides the "Test
    ///     connection" button — pass it once the host links `LocalLMLabSDKRemote` and can call
    ///     `RemoteModelProvider.probe(for:)`.
    public init(
        draft: Binding<RemoteProviderDraft>,
        onSave: @escaping (RemoteProviderDraft) -> Void,
        onRemove: (() -> Void)? = nil,
        onTest: ((RemoteProviderDraft) async -> ProviderTestOutcome)? = nil
    ) {
        self._draft = draft
        self.onSave = onSave
        self.onRemove = onRemove
        self.onTest = onTest
        _keyDraft = State(initialValue: draft.wrappedValue.apiKey)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let status = draft.statusText {
                Text(status).font(.caption)
                    .foregroundStyle(draft.configured ? Color.secondary : Color.red)
            }

            if draft.kind == .openAICompatible {
                labeledField("Base URL") {
                    TextField("http://localhost:1234/v1", text: $draft.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commit)
                }
            }

            labeledField(draft.kind == .anthropic ? "Anthropic API key" : "API key") {
                HStack {
                    SecureField(keyPlaceholder, text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(draft.configured ? "Update" : "Save") {
                        draft.apiKey = keyDraft
                        commit()
                    }
                    .disabled(keyDraft.isEmpty || keyDraft == draft.apiKey)
                }
            }

            labeledField("Models") {
                // Per-model rows + an "Add model" field, not a free-text box: a text buffer
                // mirroring `draft.models` needs its own local `@State`, which only tracks
                // *this* view's edits — it can't see a model removed via the row-selector's own
                // trash button elsewhere in the panel (same `draft.models`, reached through a
                // `reload()` that keeps this view's identity, so the buffer never re-syncs).
                // That desync is exactly what made a trashed model "come back": the stale
                // buffer still had it, and hitting Save re-committed the stale copy. Rows read
                // and write `draft.models` directly — there's no intermediate buffer to go
                // stale.
                VStack(alignment: .leading, spacing: 4) {
                    if draft.models.isEmpty {
                        Text("No models added yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(draft.models, id: \.self) { modelID in
                        HStack {
                            Text(modelID).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                draft.models.removeAll { $0 == modelID }
                                commit()
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Add model id…", text: $newModelText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(addModel)
                        Button("Add", action: addModel)
                            .disabled(newModelText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            if draft.configured, let onTest {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        testing = true
                        testResult = nil
                        Task {
                            testResult = await onTest(draft)
                            testing = false
                        }
                    } label: {
                        if testing {
                            ProgressView().controlSize(.small)
                        } else {
                            // Every configured model, not just the first — a valid key
                            // doesn't mean a second or third model id you just typed in is
                            // real; this is the whole point of testing at all.
                            Text(draft.models.count > 1 ? "Test connection (\(draft.models.count) models)" : "Test connection")
                        }
                    }
                    .disabled(testing)

                    if let testResult {
                        if let message = testResult.message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(testResult.results) { result in
                            Label("\(result.modelId): \(result.detail)",
                                  systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(result.ok ? Color.green : Color.red)
                                .lineLimit(2)
                        }
                    }
                }
            }

            if draft.configured && draft.webSearchSupported {
                HStack(spacing: 16) {
                    Toggle("Enable web search", isOn: $draft.webSearchEnabled)
                        .onChange(of: draft.webSearchEnabled) { _, _ in commit() }
                    if draft.webSearchEnabled {
                        Stepper("Max searches: \(draft.maxSearches)",
                                value: $draft.maxSearches, in: 1...20)
                            .onChange(of: draft.maxSearches) { _, _ in commit() }
                            .fixedSize()
                    }
                }
                if draft.kind == .openRouter {
                    Text("OpenRouter bills web results separately (~$4 per 1,000).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private var header: some View {
        HStack {
            Text(draft.displayName).font(.headline)
            Spacer()
            if draft.configured {
                Label("Configured", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Text("Not configured").font(.caption).foregroundStyle(.secondary)
            }
            if let onRemove {
                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var keyPlaceholder: String {
        switch draft.kind {
        case .anthropic: return "sk-ant-…"
        case .openRouter: return "sk-or-…"
        case .openAICompatible: return "optional"
        default: return "sk-…"
        }
    }

    private func commit() { onSave(draft) }

    private func addModel() {
        let trimmed = newModelText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        newModelText = ""
        guard !draft.models.contains(trimmed) else { return }
        draft.models.append(trimmed)
        commit()
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
