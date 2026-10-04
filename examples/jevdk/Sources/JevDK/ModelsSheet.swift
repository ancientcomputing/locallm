import LocalLMLabSDKCore
import OpenJevKit
import SwiftUI

/// Choose a local model: what's installed, recommended deciders, a Hugging Face search, and
/// copies in the cache to verify. Everything goes through the SDK's `MLXModelProvider`: it checks a
/// repo before downloading (reachable, MLX format, supported architecture, size vs memory and
/// disk), then downloads and verifies.
struct ModelsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.installed
    @State private var query = ""
    @State private var hits: [AppModel.HubModel] = []
    @State private var searching = false
    @State private var confirmRemove: String?

    enum Tab: String, CaseIterable { case installed = "Installed", recommended = "Recommended", search = "Search Hugging Face" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models").font(.jHeadline)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .installed: installed
                case .recommended: recommended
                case .search: search
                }
            }
            .frame(minHeight: 260, alignment: .top)

            Divider()
            downloadPanel

            HStack {
                if let e = model.errorMessage { Text(e).font(.jCaption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
        .font(.jBody)
        .onAppear { model.refreshModels() }
        .confirmationDialog("Remove \(confirmRemove ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) { if let r = confirmRemove { model.remove(r) }; confirmRemove = nil }
        } message: {
            Text("Deletes its weights from disk. You can download it again later.")
        }
    }

    // MARK: Tabs

    private var installed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if model.models.isEmpty {
                    Text("No models downloaded through the SDK yet. Pick one under Recommended, or search.")
                        .font(.jCallout).foregroundStyle(.secondary)
                }
                ForEach(model.models) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.repoID).font(.system(size: 14, design: .monospaced))
                            Text("\(m.sizeText)\(m.isMoE ? " · mixture-of-experts: not recommended as a decider" : "")")
                                .font(.jCaption).foregroundStyle(m.isMoE ? .orange : .secondary)
                        }
                        Spacer()
                        if model.selectedModelID == m.id {
                            Label("In use", systemImage: "checkmark").font(.jCaption)
                        } else {
                            Button("Use") { model.selectedModelID = m.id }
                        }
                        Button(role: .destructive) { confirmRemove = m.repoID } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove from disk")
                    }
                }
                if !model.unverifiedRepos.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("In the Hugging Face cache, not yet verified by the SDK").font(.jCallout.weight(.medium))
                    Text("Fetched by another tool. Verifying checks the files and downloads only what's missing.")
                        .font(.jCaption).foregroundStyle(.secondary)
                    ForEach(model.unverifiedRepos, id: \.self) { repo in
                        HStack {
                            Text(repo).font(.system(size: 14, design: .monospaced))
                            Spacer()
                            Button("Verify") { Task { await model.download(repo) } }
                                .disabled(model.downloadProgress != nil)
                        }
                    }
                }
            }
        }
    }

    private var recommended: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Small dense instruct models suit a decider. Mixture-of-experts models gave unstable probabilities in testing.")
                .font(.jCaption).foregroundStyle(.secondary)
            ForEach(AppModel.recommended, id: \.repo) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.repo).font(.system(size: 14, design: .monospaced))
                        Text(r.note).font(.jCaption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.models.contains(where: { $0.repoID == r.repo }) {
                        Label("Installed", systemImage: "checkmark").font(.jCaption)
                    } else {
                        Button("Select") { select(r.repo) }
                    }
                }
            }
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search MLX models, e.g. “qwen3 4b” or “llama 3b instruct”", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("Search") { runSearch() }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                if searching { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(hits) { h in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(h.id).font(.system(size: 14, design: .monospaced))
                                Text("\(h.pipeline_tag ?? "?") · \(h.downloads ?? 0) downloads")
                                    .font(.jCaption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Select") { select(h.id) }
                        }
                    }
                }
            }
            Text("Text-generation models fit best; image-text models load too but run slower.")
                .font(.jCaption).foregroundStyle(.secondary)
        }
    }

    // MARK: Check → download

    private var downloadPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("org/model", text: $model.downloadRepo)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.checkRepo() } }
                    .onChange(of: model.downloadRepo) { _, _ in model.preflight = nil }
                Button("Check") { Task { await model.checkRepo() } }
                    .disabled(!model.downloadRepo.contains("/"))
                Button("Download") {
                    Task { await model.download(); tab = .installed }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.preflight?.passed != true || model.downloadProgress != nil)
            }
            HStack {
                if let p = model.preflight {
                    if let w = p.weightBytes {
                        Text("Size \(ByteCountFormatter.string(fromByteCount: w, countStyle: .file))")
                    }
                    if p.passed {
                        Label("SDK checks passed", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label(p.detail ?? "A check failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } else {
                    Text("Select a model above or type a repo id, then Check: the SDK confirms it's an MLX model this Mac can run before anything downloads.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let f = model.downloadProgress { ProgressView(value: f).frame(width: 140) }
            }
            .font(.jCaption)
        }
    }

    private func select(_ repo: String) {
        model.downloadRepo = repo
        Task { await model.checkRepo() }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            hits = await model.searchHub(q)
            searching = false
        }
    }
}
