import LocalLMLabSDKCore
import SwiftUI

/// The assembled "AI Models" settings panel (docs/12 §5): the built-in model families with
/// live availability, then one `ProviderSettingsSection` per configured online provider, then
/// an **Add provider** menu.
///
/// State the host owns: `providers` (the drafts, persisted by the host — keys to the
/// Keychain, the rest wherever it keeps app config) and the wiring in `onSave` / `onRemove`
/// that turns a draft into a `RemoteModelProvider` and calls `lab.models.replace(_:)`.
@available(macOS 26.0, *)
public struct AIModelsSettingsView: View {
    private let registry: ModelRegistry
    @Binding private var providers: [RemoteProviderDraft]
    private let onSave: (RemoteProviderDraft) -> Void
    private let onRemove: (RemoteProviderDraft) -> Void
    private let onTest: ((RemoteProviderDraft) async -> ProviderTestOutcome)?

    /// - Parameters:
    ///   - registry: `lab.models`.
    ///   - providers: the online-provider drafts, owned + persisted by the host.
    ///   - onSave: called when a draft changes — rebuild `RemoteModelProvider(config)` from it,
    ///     `lab.models.replace(_:)`, and persist (key → Keychain).
    ///   - onRemove: called when the user deletes a provider — `lab.models.removeProvider(scheme:)`
    ///     and forget its key.
    ///   - onTest: runs a zero-token connectivity/key/model check (docs/12 §11) and shows a
    ///     "Test connection" button when non-`nil`. Omit if the host doesn't link
    ///     `LocalLMLabSDKRemote` or hasn't wired `RemoteModelProvider.probe(for:)` yet.
    public init(
        registry: ModelRegistry,
        providers: Binding<[RemoteProviderDraft]>,
        onSave: @escaping (RemoteProviderDraft) -> Void,
        onRemove: @escaping (RemoteProviderDraft) -> Void,
        onTest: ((RemoteProviderDraft) async -> ProviderTestOutcome)? = nil
    ) {
        self.registry = registry
        self._providers = providers
        self.onSave = onSave
        self.onRemove = onRemove
        self.onTest = onTest
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                builtInSection
                providersSection
            }
            .padding()
        }
    }

    // MARK: built-in

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built-in").font(.headline)
            let remoteSchemes = Set(providers.map(\.scheme))
            let builtIn = registry.knownModels.filter { !remoteSchemes.contains($0.scheme) }
            if builtIn.isEmpty {
                Text("No built-in models registered.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(builtIn, id: \.rawValue) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(id.rest.isEmpty ? id.scheme : id.rest).font(.body)
                        Text(id.scheme).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    availabilityBadge(registry.availability(for: id))
                }
            }
            ForEach(registry.schemesRequiringNewerOS, id: \.self) { scheme in
                HStack {
                    Text(scheme).foregroundStyle(.secondary)
                    Spacer()
                    Text("Requires macOS 27").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: providers

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Providers").font(.headline)
                Spacer()
                Menu {
                    ForEach(RemoteProviderKind.allCases, id: \.self) { kind in
                        Button(kind.addMenuLabel) { providers.append(.new(kind)) }
                    }
                } label: {
                    Label("Add provider", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if providers.isEmpty {
                Text("No online providers. Add one to use GPT, Claude, or any OpenRouter model.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ForEach($providers) { $draft in
                ProviderSettingsSection(
                    draft: $draft,
                    onSave: onSave,
                    onRemove: { if let idx = providers.firstIndex(of: draft) {
                        let removed = providers.remove(at: idx)
                        onRemove(removed)
                    } },
                    onTest: onTest)
            }
        }
    }

    @ViewBuilder
    private func availabilityBadge(_ a: ModelAvailability) -> some View {
        switch a {
        case .available: Text("Ready").font(.caption).foregroundStyle(.green)
        case .notDownloaded: Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
        case .needsCredential: Text("Needs credential").font(.caption).foregroundStyle(.orange)
        case .unavailable(_, let detail): Text(detail).font(.caption).foregroundStyle(.red).lineLimit(1)
        @unknown default: Text("Unknown").font(.caption).foregroundStyle(.secondary)
        }
    }
}
