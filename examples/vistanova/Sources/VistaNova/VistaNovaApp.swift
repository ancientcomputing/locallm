import SwiftUI
import AppKit
import LocalLMLabSDKCore

@main
@available(macOS 27, *)
struct VistaNovaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("VistaNova") {
            ChatView(model: model)
                .frame(minWidth: 480, minHeight: 480)
        }
        Settings {
            SettingsScreen(model: model)
                .frame(width: 480)
        }
    }
}

@available(macOS 27, *)
private struct SettingsScreen: View {
    @Bindable var model: AppModel
    @State private var showingTavilyReplace = false
    @State private var showingResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tavilySection
            Divider()
            modelSection
            Divider()
            appearanceSection
            Divider()
            historySection
            Divider()
            HStack {
                Spacer()
                Button("Done") { NSApplication.shared.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .sheet(isPresented: $showingTavilyReplace) {
            TavilySetupView(model: model)
        }
        .alert("Reset all search history?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { model.resetHistory() }
        } message: {
            Text("This removes every saved topic thread, search, and summary. It can't be undone.")
        }
    }

    // Scoped deliberately to search history only — Tavily's connection, model choices, and
    // appearance are separate settings a user asking to clear "history" didn't ask to touch.
    private var historySection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("History").font(AppFont.headline)
                Text("\(model.threads.count) topic thread(s) saved")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset…", role: .destructive) { showingResetConfirmation = true }
                .disabled(model.threads.isEmpty)
        }
        .padding(16)
    }

    // Plain dropdowns, not Components' ModelPickerView — that view's own "Downloaded models"
    // section (with its Hugging Face download field) is more than this app needs: only one
    // specific MLX model is ever offered as a summary-model choice (see AppModel.defaultSummaryModel),
    // downloaded on demand from summarize() itself rather than browsed for here.
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models").font(AppFont.headline)
            Picker("Web search", selection: Binding(
                get: { model.searchModel },
                set: { model.selectSearchModel($0) }
            )) {
                ForEach(model.availableModels, id: \.rawValue) { id in
                    Text(label(for: id)).tag(id)
                }
            }
            Picker("Summary", selection: Binding(
                get: { model.summaryModel },
                set: { model.selectSummaryModel($0) }
            )) {
                ForEach(model.summaryModelOptions, id: \.rawValue) { id in
                    Text(label(for: id)).tag(id)
                }
            }
        }
        .padding(16)
    }

    // A/B toggle — Netscape-era "Classic" chrome vs. the Modern look. Same layout either way;
    // see ClassicTheme in Theme.swift for the actual styling.
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance").font(AppFont.headline)
            Picker("", selection: $model.isClassicTheme) {
                Text("Modern").tag(false)
                Text("Classic").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(16)
    }

    private func label(for id: ModelID) -> String {
        let name = id.rest.isEmpty ? id.scheme : "\(id.scheme): \(id.rest)"
        let isReady = model.lab.models.availability(for: id).isAvailable
        return isReady ? name : "\(name) (not downloaded)"
    }

    private var tavilySection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tavily").font(AppFont.headline)
                Text(model.tavilyConnected ? "Connected" : "Not connected")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.tavilyConfigured {
                Button("Change Key…") { showingTavilyReplace = true }
                Button("Remove", role: .destructive) { model.removeTavily() }
            } else {
                Button("Connect…") { showingTavilyReplace = true }
            }
        }
        .padding(16)
    }
}
