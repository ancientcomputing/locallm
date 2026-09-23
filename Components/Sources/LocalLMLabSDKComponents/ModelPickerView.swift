import LocalLMLabSDKCore
import SwiftUI

// Prebuilt model surface (docs/sdk-guide.md §11). Binds directly to
// `lab.models` — an `@Observable` `ModelRegistry` — so availability, install state, and live
// download progress all come from observable properties, never by polling a provider.
//
// The "downloaded models / add from Hugging Face / progress" section renders only when a
// `DownloadableModelProvider` is registered (i.e. the host linked LocalLMLabSDKInference).
// A C2-absent build compiles and shows the picker without that section.

@available(macOS 26.0, *)
public struct ModelPickerView: View {
    private let registry: ModelRegistry
    @Binding private var selection: ModelID?
    private let show27OnlyModels: Bool

    @State private var addRepoID = ""
    /// The Validate -> Download -> Pin flow for the repo being added; `nil` when nothing is being added.
    @State private var onboarding: ModelOnboardingModel?

    /// - Parameters:
    ///   - registry: `lab.models`.
    ///   - selection: the currently chosen model (e.g. bind to what you'll route).
    ///   - show27OnlyModels: on macOS 26, show the macOS-27-only model families
    ///     (Private Cloud Compute, Claude, open-weight/MLX) as disabled "Requires macOS 27"
    ///     rows rather than omitting them. Default `true`. No effect on macOS 27.
    public init(registry: ModelRegistry, selection: Binding<ModelID?>, show27OnlyModels: Bool = true) {
        self.registry = registry
        self._selection = selection
        self.show27OnlyModels = show27OnlyModels
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                availableSection
                if !registry.downloadableProviders.isEmpty {
                    Divider()
                    downloadedSection
                }
            }
            .padding()
        }
    }

    // MARK: available models

    private static func label(forScheme scheme: String) -> String {
        switch scheme {
        case "pcc": return "Private Cloud Compute"
        case "claude": return "Claude"
        case "mlx": return "Open-weight models (MLX)"
        default: return scheme
        }
    }

    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models").font(.headline)
            if registry.knownModels.isEmpty && !(show27OnlyModels && !registry.schemesRequiringNewerOS.isEmpty) {
                Text("No models available. Register a provider.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            ForEach(registry.knownModels, id: \.rawValue) { id in
                row(for: id)
            }
            if show27OnlyModels {
                ForEach(registry.schemesRequiringNewerOS, id: \.self) { scheme in
                    HStack {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                        Text(Self.label(forScheme: scheme)).foregroundStyle(.secondary)
                        Spacer()
                        Text("Requires macOS 27").font(.caption).foregroundStyle(.secondary)
                    }
                    .opacity(0.6)
                }
            }
        }
    }

    private func row(for id: ModelID) -> some View {
        let availability = registry.availability(for: id)
        return Button {
            selection = id
        } label: {
            HStack {
                Image(systemName: selection == id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selection == id ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(id.rest.isEmpty ? id.scheme : id.rest).font(.body)
                    Text(id.scheme).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                badge(availability)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled({ if case .unavailable = availability { return true } else { return false } }())
    }

    @ViewBuilder
    private func badge(_ availability: ModelAvailability) -> some View {
        switch availability {
        case .available:
            Text("Ready").font(.caption).foregroundStyle(.green)
        case .notDownloaded:
            Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
        case .needsCredential:
            Text("Needs credential").font(.caption).foregroundStyle(.orange)
        case .unavailable(_, let detail):
            Text(detail).font(.caption).foregroundStyle(.red).lineLimit(1)
        @unknown default:
            Text("Unknown").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: downloaded models (C2 only)

    private var downloadedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloaded models").font(.headline)

            if registry.installedModels.isEmpty {
                Text("None yet.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(registry.installedModels) { model in
                HStack {
                    Text(model.repoID)
                    Spacer()
                    if let bytes = model.sizeBytes {
                        Text("\(bytes / 1_000_000) MB").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(registry.downloads.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key.rawValue) { id, progress in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Downloading \(id.rest)").font(.caption)
                        Spacer()
                        Button("Cancel") { registry.cancelDownload(id.rest) }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress.fraction)
                    if progress.totalBytes > 0 {
                        Text("\(Self.byteCount(progress.bytesReceived)) of \(Self.byteCount(progress.totalBytes)) — \(Int(progress.fraction * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                TextField("namespace/model-id from Hugging Face", text: $addRepoID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(onboarding != nil)
                Button("Add") { startAdd() }
                    .disabled(addRepoID.trimmingCharacters(in: .whitespaces).isEmpty || onboarding != nil)
            }
            // A failed preflight (trust policy, architecture, size, quota) now says which stage and why,
            // instead of a bare error line. The download row above already shows progress, so the
            // stepper doesn't draw a second bar.
            if let onboarding {
                ModelOnboardingView(
                    model: onboarding, showsDownloadProgress: false,
                    onFinished: { _ in
                        addRepoID = ""
                        self.onboarding = nil
                    },
                    onDismiss: { self.onboarding = nil })
            }
        }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func startAdd() {
        let repoID = addRepoID.trimmingCharacters(in: .whitespaces)
        guard !repoID.isEmpty else { return }
        let model = ModelOnboardingModel(
            requests: [ModelOnboardingRequest(repoID: repoID)], source: ModelOnboardingSource(registry: registry))
        onboarding = model
        model.start()
    }
}

// MARK: - Claude auth

/// API-key entry for `ClaudeModelProvider`. The value is handed to the host via the
/// binding — Components does **not** persist it. Production on a real device uses App Attest
/// (`ClaudeModelProvider.Auth.appAttest`) instead of a key.
@available(macOS 26.0, *)
public struct ClaudeAuthField: View {
    @Binding private var apiKey: String
    private let onCommit: () -> Void

    public init(apiKey: Binding<String>, onCommit: @escaping () -> Void = {}) {
        self._apiKey = apiKey
        self.onCommit = onCommit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Anthropic API key").font(.headline)
            SecureField("sk-ant-…", text: $apiKey, onCommit: onCommit)
                .textFieldStyle(.roundedBorder)
            Text("Used for prototyping. Handed to your app to pass into ClaudeModelProvider — not stored by this view. On a shipped app, use App Attest instead.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
