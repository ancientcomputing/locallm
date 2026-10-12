import Foundation
import LocalLMLabSDKCore
import Security

/// jev-serve's config file (the jev-serve example): where to listen, an optional token, and the
/// models to serve, each with the setup tested in JevDK. JevDK writes it (File → Export Server
/// Config…); jev-serve reads it. Each model's `tuning` is the SDK's `DecisionQuestionSet.Tuning`:
/// the model (`openjev:<repo>`), the revision it was tested on (jev-serve pins downloads to it),
/// the system instructions and the calibration.
public struct JevServeConfig: Codable, Hashable, Sendable {
    public static let currentFormat = 1
    public static let defaultPort = 8746

    public struct Listen: Codable, Hashable, Sendable {
        public var host: String
        public var port: Int
        public init(host: String = "127.0.0.1", port: Int = JevServeConfig.defaultPort) {
            self.host = host
            self.port = port
        }
    }

    public struct Model: Codable, Hashable, Sendable {
        /// What requests ask for in `"model"`, e.g. `support`.
        public var name: String
        public var tuning: DecisionQuestionSet.Tuning
        public init(name: String, tuning: DecisionQuestionSet.Tuning) {
            self.name = name
            self.tuning = tuning
        }
    }

    public var format: Int
    public var listen: Listen
    /// When set, every request needs `Authorization: Bearer <token>`.
    public var token: String?
    /// The model a request without `"model"` gets.
    public var defaultModel: String?
    public var maxStateCharacters: Int?
    public var models: [Model]

    public init(listen: Listen = Listen(), token: String? = nil, defaultModel: String? = nil,
                maxStateCharacters: Int? = 20_000, models: [Model] = []) {
        self.format = Self.currentFormat
        self.listen = listen
        self.token = token
        self.defaultModel = defaultModel
        self.maxStateCharacters = maxStateCharacters
        self.models = models
    }

    /// Adds `model`, or replaces the entry with the same name, keeping the others; the first model
    /// added becomes the default.
    public mutating func upsert(_ model: Model) {
        if let i = models.firstIndex(where: { $0.name == model.name }) { models[i] = model } else { models.append(model) }
        if defaultModel == nil || !models.contains(where: { $0.name == defaultModel }) { defaultModel = models.first?.name }
    }

    public static func read(_ url: URL) throws -> JevServeConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(JevServeConfig.self, from: Data(contentsOf: url))
        guard config.format <= currentFormat else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "This jev-serve config is format \(config.format); this version reads up to \(currentFormat)."])
        }
        return config
    }

    /// Writes the file readable and writable by this user only (it may hold the token).
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A random token for `Authorization: Bearer …` (32 bytes, base64url).
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
