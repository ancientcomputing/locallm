import AppKit
import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKRemote

/// The hosted backends JevDK offers, each an SDK `JevDecisionProvider` registered in the lab under
/// its own decision scheme: hosted Jev (Featherless, TypeSafe on OpenRouter) and OpenAI's Decisions
/// API (SDK 2.3, a different wire format behind the same provider), plus a decisionformer server the
/// developer runs (hosted Jev's wire on `/v1/systemone`, at a URL set in Backends). The Mac App Store build has no free Featherless demo: every
/// hosted backend there runs on the user's own account and key, and the demo isn't in its binary
/// at all (guideline 2.5.19: no dormant features).
enum HostedBackend: String, CaseIterable, Identifiable, Sendable {
    #if !MAS_BUILD
    case featherlessDemo
    #endif
    case featherless, openRouter, openAI, decisionformer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        #if !MAS_BUILD
        case .featherlessDemo: "Featherless demo"
        #endif
        case .featherless: "Featherless"
        case .openRouter: "OpenRouter · TypeSafe"
        case .openAI: "OpenAI"
        case .decisionformer: "decisionformer"
        }
    }

    var blurb: String {
        switch self {
        #if !MAS_BUILD
        case .featherlessDemo: "Free, no key · 2k-token context, a few requests per second · token-scored like Local"
        #endif
        case .featherless: "featherless.ai key · token-scored like Local"
        case .openRouter: "OpenRouter key · TypeSafe's decision-trained Jev"
        case .openAI: "OpenAI key · GPT-6 Luna through OpenAI's Decisions API · may decline a question"
        case .decisionformer: "Your own decisionformer serve · a fine-tuned decider · key only if started with one"
        }
    }

    /// Featherless's free demo service (not in the Mac App Store build).
    var isDemo: Bool {
        #if MAS_BUILD
        false
        #else
        self == .featherlessDemo
        #endif
    }

    var needsKey: Bool { !isDemo && self != .decisionformer }

    /// A key field in Backends: required for the hosted services, optional for decisionformer
    /// (sent only when its server was started with `--api-key-env`).
    var acceptsKey: Bool { needsKey || self == .decisionformer }

    /// Whether requests go to a URL the developer sets in Backends rather than a fixed service.
    var hasEditableEndpoint: Bool { self == .decisionformer }

    /// Who receives the text a run sends, for the consent question (AIDataConsent).
    var dataRecipient: String {
        switch self {
        #if !MAS_BUILD
        case .featherlessDemo: "Featherless's free demo service (featherless.ai)"
        #endif
        case .featherless: "Featherless (featherless.ai)"
        case .openRouter: "OpenRouter (openrouter.ai), which passes it to TypeSafe's Jev model"
        case .openAI: "OpenAI (openai.com)"
        case .decisionformer: "your decisionformer server (\(Self.decisionformerEndpoint.host ?? "unknown host"))"
        }
    }

    #if !MAS_BUILD
    /// Environment variable checked when no key is saved in the Keychain (CI, headless runs). Not
    /// in the Mac App Store build, whose keys come only from Backends.
    var keyVariable: String? {
        switch self {
        case .featherlessDemo: nil
        case .featherless: "FEATHERLESS_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .decisionformer: "DECISIONFORMER_API_KEY"
        }
    }
    #endif

    var defaultModel: String {
        switch self {
        #if !MAS_BUILD
        case .featherlessDemo: "featherless-ai/Qwen3.8-27B-classifier"
        #endif
        case .featherless: "featherless-ai/Qwen3.8-27B-classifier"
        case .openRouter: "typesafe/jev-1.13"
        case .openAI: "gpt-6-luna"
        // The server ignores the model field and answers with the one it loaded; Refresh list
        // reads that one's name from its /v1/models.
        case .decisionformer: "decisionformer"
        }
    }

    /// The SDK config, with a scheme of its own so the demo and the keyed Featherless endpoint
    /// can both be registered in one lab.
    func config(key: String?) -> JevProviderConfig {
        var c: JevProviderConfig
        switch self {
        #if !MAS_BUILD
        case .featherlessDemo: c = .featherlessDemo()
        #endif
        case .featherless: c = .featherless(key: key ?? "")
        case .openRouter: c = .openRouter(key: key ?? "")
        case .openAI: c = .openAI(key: key ?? "")
        case .decisionformer:
            // `.native`: a decisionformer checkpoint is trained (and calibrated) to decide. Its
            // server refuses what it can't fit with a 422 rather than truncating, so Jev's limits.
            c = JevProviderConfig(scheme: "decisionformer", displayName: "decisionformer",
                                  endpoint: Self.decisionformerEndpoint,
                                  auth: key.map { $0.isEmpty ? .none : .apiKey($0) } ?? .none,
                                  fidelity: .native)
        }
        c.scheme = rawValue.lowercased()
        return c
    }

    var suggestedModels: [String] { config(key: nil).models }

    /// The free demo is rate-limited; space batch inputs out when it's on.
    var minInterval: Duration { isDemo ? .milliseconds(600) : .zero }

    /// The demo and decisionformer publish a model list; the others don't have a Jev-specific one.
    var modelsURL: URL? {
        if self == .decisionformer {
            return Self.decisionformerEndpoint.deletingLastPathComponent().appendingPathComponent("models")
        }
        #if MAS_BUILD
        return nil
        #else
        return isDemo ? URL(string: "https://simple-jev-demo-api.featherless.ai/v1/models") : nil
        #endif
    }

    // MARK: decisionformer's endpoint

    static let decisionformerDefaultEndpoint = "http://127.0.0.1:8000/v1/systemone"
    static let decisionformerEndpointKey = "remote.decisionformer.url"

    /// Where decisionformer requests go: the URL saved in Backends, else (not in the Mac App Store
    /// build) `DECISIONFORMER_URL` for headless runs, else `decisionformer serve`'s default.
    static var decisionformerEndpointString: String {
        if let s = UserDefaults.standard.string(forKey: decisionformerEndpointKey), !s.isEmpty { return s }
        #if !MAS_BUILD
        if let s = ProcessInfo.processInfo.environment["DECISIONFORMER_URL"], !s.isEmpty { return s }
        #endif
        return decisionformerDefaultEndpoint
    }

    static var decisionformerEndpoint: URL {
        URL(string: decisionformerEndpointString) ?? URL(string: decisionformerDefaultEndpoint)!
    }

    /// Why the decisionformer URL can't be used, or nil: the SDK's own check (https, or plain http
    /// only to localhost or a .local name), so a typo never sends text somewhere unexpected.
    static func decisionformerEndpointProblem() -> String? {
        guard let url = URL(string: decisionformerEndpointString), url.scheme != nil, url.host != nil else {
            return "decisionformer: “\(decisionformerEndpointString)” isn't a URL. Set it in Backends."
        }
        do { _ = try HostedBackend.decisionformer.config(key: nil).validated(); return nil } catch {
            return "decisionformer: \(url.absoluteString) can't be used: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    /// Why the decisionformer server isn't answering, or nil: one quick `GET /health` (next to
    /// `/v1/systemone`) before a run. The SDK's session waits for connectivity, so a server that
    /// isn't running would otherwise hold every input for minutes before failing.
    static func decisionformerUnreachable() async -> String? {
        let endpoint = decisionformerEndpoint
        let health = endpoint.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("health")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(from: health)
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                return "decisionformer: \(health.absoluteString) answered \(status). Is this a decisionformer server?"
            }
            return nil
        } catch {
            return "decisionformer isn't answering at \(endpoint.absoluteString). Start it with `decisionformer serve <model>`, or fix the URL in Backends."
        }
    }

    func listModels() async -> [String] {
        guard let url = modelsURL,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]]
        else { return suggestedModels }
        return list.compactMap { $0["id"] as? String }
    }

    func modelID(_ model: String) -> ModelID? { ModelID(scheme: rawValue.lowercased(), rest: model) }

    func label(model: String) -> String {
        "\(displayName) · \(model.split(separator: "/").last.map(String.init) ?? model)"
    }
}

/// The API key for a hosted backend: the one saved in the Keychain from **Backends**, else (not in
/// the Mac App Store build) the environment variable, for CI and headless runs. Never printed.
/// There is no key file: a key in a file next to the code is too easy to commit or share.
enum APIKeys {
    static func key(for backend: HostedBackend) -> String? {
        if let k = Keychain.get(account(backend)), !k.isEmpty { return k }
        #if MAS_BUILD
        return nil
        #else
        guard let name = backend.keyVariable, let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
        return v
        #endif
    }

    static func account(_ backend: HostedBackend) -> String { "key.\(backend.rawValue)" }
}

/// Asks before a hosted backend is turned on, in the Mac App Store build (App Review guideline
/// 5.1.2(i): name the AI service and what it receives, and get permission first). Asked every time
/// one is turned on, so turning it off is how to withdraw. Other builds don't ask: the Backends
/// sheet already says what hosted backends receive.
@MainActor
enum AIDataConsent {
    static func ask(_ backend: HostedBackend) -> Bool {
        #if MAS_BUILD
        let alert = NSAlert()
        alert.messageText = "Send your text to \(backend.displayName)?"
        alert.informativeText = "While \(backend.displayName) is on, every input you run and your questions "
            + "(with their instructions and options) are sent to \(backend.dataRecipient) to be answered. "
            + "Their terms and privacy policy apply. The Local backend keeps everything on this Mac.\n\n"
            + "Turn the backend off in Backends to stop sending."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
        #else
        true
        #endif
    }
}
