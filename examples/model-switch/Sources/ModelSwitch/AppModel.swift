import Foundation
import Observation
import LocalLMLabSDKCore
import LocalLMLabSDKComponents
import LocalLMLabSDKRemote

@available(macOS 27, *)
@MainActor
@Observable
final class AppModel {
    let lab: LocalLMLab

    /// Online-provider drafts, persisted by the app: API keys in the Keychain
    /// (`Keychain.swift`), everything else in `UserDefaults` (`persist()`/`restore()`).
    var providers: [RemoteProviderDraft] = [] {
        didSet { persist() }
    }

    /// The model the next turn will use. Any id from `availableModels`.
    var selectedModel: ModelID = .system

    // chat
    var transcript: [ChatLine] = []
    var input: String = ""
    var webSearchThisTurn = false
    var isResponding = false
    var lastError: String?

    struct ChatLine: Identifiable {
        let id = UUID()
        var role: Role
        var text: String
        var searches: [String] = []
        var citations: [Citation] = []
        enum Role { case user, assistant }
    }

    init() {
        lab = LocalLMLab(configuration: .init(providers: [SystemModelProvider()]))
        restore()
    }

    var availableModels: [ModelID] {
        lab.models.knownModels.filter { lab.models.availability(for: $0).isAvailable }
    }

    // MARK: provider config

    func applyDraft(_ draft: RemoteProviderDraft) {
        guard let idx = providers.firstIndex(where: { $0.scheme == draft.scheme }) else { return }
        var updated = draft
        if let config = draft.makeConfig() {
            // `RemoteModelProvider.init(_:)` always validates — this config's
            // baseURL/apiKey came straight from the settings panel.
            do {
                lab.models.replace(try RemoteModelProvider(config))
                updated.configured = true
                updated.statusText = "\(config.models.count) model(s) available."
            } catch {
                lab.models.removeProvider(scheme: draft.scheme)
                updated.configured = false
                updated.statusText = error.localizedDescription
            }
        } else {
            lab.models.removeProvider(scheme: draft.scheme)
            updated.configured = false
            updated.statusText = "Enter an API key to enable."
        }
        providers[idx] = updated
    }

    func removeDraft(_ draft: RemoteProviderDraft) {
        lab.models.removeProvider(scheme: draft.scheme)
        if selectedModel.scheme == draft.scheme { selectedModel = .system }
    }

    /// "Test connection" — in-process here since this example links Remote
    /// directly. A host split across two binaries (a macOS 26 app plus a macOS 27 helper)
    /// would round-trip this call through the helper instead.
    ///
    /// Every configured model, not just the first — a valid key doesn't mean a second or
    /// third model id the user just typed in is real.
    func testDraft(_ draft: RemoteProviderDraft) async -> ProviderTestOutcome {
        guard let config = draft.makeConfig(), !config.models.isEmpty else {
            return .unableToRun("Add a model id and an API key first.")
        }
        let provider: RemoteModelProvider
        do {
            provider = try RemoteModelProvider(config)
        } catch {
            return .unableToRun(error.localizedDescription)
        }
        var results: [ProviderTestOutcome.ModelResult] = []
        for model in config.models {
            guard let modelID = ModelID(scheme: config.scheme, rest: model.id) else {
                results.append(.init(modelId: model.id, ok: false, detail: "isn't a valid model id."))
                continue
            }
            let availability = await provider.probe(for: modelID)
            let detail: String
            switch availability {
            case .available: detail = "Available."
            case .needsCredential: detail = "The API key was rejected."
            case .unavailable(_, let d): detail = d
            default: detail = "Unknown status."
            }
            results.append(.init(modelId: model.id, ok: availability.isAvailable, detail: detail))
        }
        return ProviderTestOutcome(results: results)
    }

    // MARK: chat

    func send() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }
        input = ""
        lastError = nil
        transcript.append(.init(role: .user, text: prompt))
        var line = ChatLine(role: .assistant, text: "")
        transcript.append(line)
        let lineID = line.id
        isResponding = true
        defer { isResponding = false }

        do {
            lab.models.route("chat", to: selectedModel)
            let session = try lab.makeSession(
                route: "chat",
                instructions: "You are a helpful assistant. Be concise.",
                options: .init(webSearch: webSearchThisTurn))

            let events = Task { [weak self] in
                for await event in session.events {
                    guard let self else { return }
                    if case .serverToolCall(let a) = event, case .webSearch(let q, _) = a.kind {
                        self.update(lineID) { $0.searches.append(contentsOf: q) }
                    }
                }
            }

            let answer = try await session.respond(to: prompt)
            events.cancel()
            line.text = answer
            update(lineID) { $0.text = answer; $0.citations = session.citations }
        } catch {
            let message = (error as? LocalLMLabError)?.errorDescription ?? "\(error)"
            lastError = message
            update(lineID) { $0.text = "⚠️ \(message)" }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout ChatLine) -> Void) {
        guard let idx = transcript.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transcript[idx])
    }

    // MARK: persistence
    //
    // API keys go in the Keychain (`Keychain.swift`), keyed by the
    // provider's `scheme` — never in `UserDefaults`, which is a plaintext plist. Everything
    // else about a provider draft (base URL, model list, web-search settings) isn't a secret
    // and stays in `UserDefaults` as before.

    private static let key = "modelswitch.providers.v1"

    private func persist() {
        let plain = providers.map { d -> [String: String] in
            Keychain.set(d.apiKey.isEmpty ? nil : d.apiKey, for: d.scheme)
            return ["scheme": d.scheme, "displayName": d.displayName, "kind": d.kind.rawValue,
                    "baseURL": d.baseURL,
                    "models": d.models.joined(separator: "\n"),
                    "webSearchSupported": String(d.webSearchSupported),
                    "webSearchEnabled": String(d.webSearchEnabled),
                    "maxSearches": String(d.maxSearches)]
        }
        UserDefaults.standard.set(plain, forKey: Self.key)
    }

    private func restore() {
        let rows = UserDefaults.standard.array(forKey: Self.key) as? [[String: String]] ?? []
        providers = rows.compactMap { r in
            guard let scheme = r["scheme"], let kindRaw = r["kind"],
                  let kind = RemoteProviderKind(rawValue: kindRaw) else { return nil }
            var d = RemoteProviderDraft(
                scheme: scheme, displayName: r["displayName"] ?? scheme, kind: kind,
                baseURL: r["baseURL"] ?? "", apiKey: Keychain.string(for: scheme) ?? "",
                models: (r["models"] ?? "").split(whereSeparator: \.isNewline).map(String.init),
                webSearchSupported: r["webSearchSupported"] == "true",
                webSearchEnabled: r["webSearchEnabled"] == "true",
                maxSearches: Int(r["maxSearches"] ?? "5") ?? 5)
            if let config = d.makeConfig(), let provider = try? RemoteModelProvider(config) {
                lab.models.replace(provider)
                d.configured = true
            }
            return d
        }
    }
}
