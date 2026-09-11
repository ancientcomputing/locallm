import Foundation

/// The result of a "Test connection" check on one online provider (docs/12 §11) — one
/// zero-token HTTP call **per configured model**, run by the host (Components doesn't
/// depend on `LocalLMLabSDKRemote`, so it can't run the check itself; see
/// `ProviderSettingsSection.onTest`).
///
/// Per-model, not per-provider: a provider's key can be valid while one of its several
/// configured model ids is a typo or doesn't exist — testing only the first model (an
/// earlier version of this type did exactly that) would silently never catch that on any
/// model added after the first.
public struct ProviderTestOutcome: Sendable, Equatable {
    public struct ModelResult: Sendable, Equatable, Identifiable {
        public var id: String { modelId }
        public var modelId: String
        public var ok: Bool
        /// Human-readable result — "Available." or the specific failure ("The API key was
        /// rejected.", "isn't in OpenAI's available model list.", "Couldn't reach OpenAI: …").
        public var detail: String

        public init(modelId: String, ok: Bool, detail: String) {
            self.modelId = modelId
            self.ok = ok
            self.detail = detail
        }
    }

    /// One entry per configured model, in configured order. Empty when there was nothing to
    /// test — see `message`.
    public var results: [ModelResult]
    /// Set instead of `results` when the check couldn't run at all (no models configured yet,
    /// no key, couldn't reach the helper/inference layer).
    public var message: String?

    public init(results: [ModelResult], message: String? = nil) {
        self.results = results
        self.message = message
    }

    public static func unableToRun(_ message: String) -> ProviderTestOutcome {
        .init(results: [], message: message)
    }
}
