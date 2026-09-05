import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKComponents
import LocalLMLabSDKRemote

// The ~30 lines of glue a host writes: `RemoteProviderDraft` (Components' UI shape) →
// `RemoteProviderConfig` (Remote's model-layer shape). Everything else — persistence,
// re-registration — is `lab.models.replace(_:)`.
//
// The SDK ships no default model ids (docs/12 §10) — that's product judgment ("gpt-4o is
// good enough" vs. chasing the newest release), and it belongs to whoever ships the app,
// with more current information than an SDK release can carry. This example doesn't fill
// in any of its own: `AIModelsSettingsView`'s built-in Add menu appends a fresh draft with
// an empty model list, and `makeConfig()` below must honor that unconditionally. Once a
// provider exists, an empty model list is a real, intentional state (the user removed every
// model via a row's trash) — not "nothing chosen yet" — so it must round-trip as zero
// models, not silently resurrect a default. A host that wants to prefill a default model on
// Add does that where it appends the new draft (see `locallmlab`'s
// `RemoteProvidersModel.add(_:)`), never inside `makeConfig()`.
extension RemoteProviderDraft {
    /// Build the model-layer config this draft describes. `nil` if it can't be used yet
    /// (no key / no base URL).
    func makeConfig() -> RemoteProviderConfig? {
        let models = self.models.map { RemoteModel(id: $0) }
        var config: RemoteProviderConfig

        switch kind {
        case .openAIChat:
            guard !apiKey.isEmpty else { return nil }
            config = .openAI(apiKey: apiKey, models: models)
        case .openAIResponses:
            guard !apiKey.isEmpty else { return nil }
            config = .openAIResponses(apiKey: apiKey, models: models)
        case .anthropic:
            guard !apiKey.isEmpty else { return nil }
            config = .anthropic(apiKey: apiKey, models: models)
        case .openRouter:
            guard !apiKey.isEmpty else { return nil }
            config = .openRouter(apiKey: apiKey, models: models)
        case .openAICompatible:
            guard let url = URL(string: baseURL), !baseURL.isEmpty else { return nil }
            config = .openAICompatible(
                scheme: scheme, displayName: displayName, baseURL: url,
                apiKey: apiKey.isEmpty ? nil : apiKey, models: models)
        }

        // Carry the panel's web-search checkbox into the provider defaults.
        if webSearchSupported {
            config.capabilities.insert(.webSearch)
            config.defaultOptions.webSearch = webSearchEnabled
            config.defaultOptions.webSearchMaxUses = maxSearches
        }
        return config
    }
}
