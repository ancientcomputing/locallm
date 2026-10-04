import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKRemote

/// The hosted Jev backends JevDK offers, each an SDK `JevDecisionProvider` registered in the
/// lab under its own decision scheme.
enum HostedBackend: String, CaseIterable, Identifiable, Sendable {
    case featherlessDemo, featherless, openRouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .featherlessDemo: "Featherless demo"
        case .featherless: "Featherless"
        case .openRouter: "OpenRouter · TypeSafe"
        }
    }

    var blurb: String {
        switch self {
        case .featherlessDemo: "Free, no key · 2k-token context, a few requests per second · token-scored like Local"
        case .featherless: "featherless.ai key · token-scored like Local"
        case .openRouter: "OpenRouter key · TypeSafe's decision-trained Jev"
        }
    }

    var needsKey: Bool { self != .featherlessDemo }

    /// Environment / .env variable for headless runs.
    var keyVariable: String? {
        switch self {
        case .featherlessDemo: nil
        case .featherless: "FEATHERLESS_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        }
    }

    var defaultModel: String {
        switch self {
        case .featherlessDemo, .featherless: "featherless-ai/Qwen3.8-27B-classifier"
        case .openRouter: "typesafe/jev-1.13"
        }
    }

    /// The SDK config, with a scheme of its own so the demo and the keyed Featherless endpoint
    /// can both be registered in one lab.
    func config(key: String?) -> JevProviderConfig {
        var c: JevProviderConfig
        switch self {
        case .featherlessDemo: c = .featherlessDemo()
        case .featherless: c = .featherless(key: key ?? "")
        case .openRouter: c = .openRouter(key: key ?? "")
        }
        c.scheme = rawValue.lowercased()
        return c
    }

    var suggestedModels: [String] { config(key: nil).models }

    /// The free demo is rate-limited; space batch inputs out when it's on.
    var minInterval: Duration { self == .featherlessDemo ? .milliseconds(600) : .zero }

    /// The demo publishes a model list; the others don't have a Jev-specific one.
    var modelsURL: URL? {
        self == .featherlessDemo ? URL(string: "https://simple-jev-demo-api.featherless.ai/v1/models") : nil
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

/// Reads an API key from the environment or a `.env` file, never printing it. Accepts
/// `NAME=value` lines or a file holding just the key.
enum KeyFile {
    static func key(named name: String, file: URL = URL(fileURLWithPath: ".env")) -> String? {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where line.hasPrefix(name + "=") || line.hasPrefix("export " + name + "=") {
            let v = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        let bare = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return bare.count == 1 && !bare[0].contains("=") ? bare[0] : nil
    }
}
