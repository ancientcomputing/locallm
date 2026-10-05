import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKInference

/// What answers a served model's questions. jev-serve uses `OpenJevDecider` (OpenJev on MLX); tests
/// use a scripted one, so routing, auth, limits and the queue are tested without a GPU.
public protocol Decider: Sendable {
    var limits: DecisionLimits { get }
    var calibrated: Bool { get }
    /// The decision, and the input tokens it read (for `usage`).
    func decide(_ request: DecisionRequest) async throws -> (decision: Decision, inputTokens: Int?)
}

/// OpenJev on a local MLX model, with one config entry's wrapper and calibration.
public struct OpenJevDecider: Decider {
    public let provider: OpenJevDecisionProvider
    public let id: ModelID

    public init(provider: OpenJevDecisionProvider, id: ModelID) {
        self.provider = provider
        self.id = id
    }

    public var limits: DecisionLimits { provider.limits }
    public var calibrated: Bool { provider.calibration != nil }

    public func decide(_ request: DecisionRequest) async throws -> (decision: Decision, inputTokens: Int?) {
        let (decision, diagnostics) = try await provider.decideWithDiagnostics(request, using: id)
        return (decision, diagnostics.sharedPrefixTokens)
    }
}

/// One model jev-serve answers for.
public struct ServedModel: Sendable {
    public let name: String
    public let repo: String
    public let revision: String?
    public let decider: any Decider

    public init(name: String, repo: String, revision: String?, decider: any Decider) {
        self.name = name
        self.repo = repo
        self.revision = revision
        self.decider = decider
    }
}

/// The routes: hosted Jev's two decision paths, the model list, and a health check
/// (see README.md). Decisions run one at a time (one GPU) in arrival order.
public final class Service: @unchecked Sendable {
    public let models: [ServedModel]
    public let defaultModel: String
    let token: String?
    let maxStateCharacters: Int?
    let logBodies: Bool
    let log: @Sendable (String) -> Void
    private let queue: FIFOQueue

    public init(models: [ServedModel], defaultModel: String, token: String?, maxStateCharacters: Int?,
                queueLimit: Int = 32, logBodies: Bool = false, log: @escaping @Sendable (String) -> Void = jevServeLog) {
        self.models = models
        self.defaultModel = defaultModel
        self.token = token
        self.maxStateCharacters = maxStateCharacters
        self.logBodies = logBodies
        self.log = log
        self.queue = FIFOQueue(limit: queueLimit)
    }

    public static let decisionPaths = ["/api/alpha/decisions", "/v1/classifier"]

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let start = ContinuousClock.now
        var note = ""
        let response: HTTPResponse
        let path = req.path.count > 1 && req.path.hasSuffix("/") ? String(req.path.dropLast()) : req.path
        switch (req.method, path) {
        case ("GET", "/health"):
            response = .json(200, Data(#"{"status":"ok","models":[\#(models.map { jsonString($0.name) }.joined(separator: ","))]}"#.utf8))
        case (_, "/health"):
            response = Self.error(405, "Use GET.")
        case (let m, let p) where Self.decisionPaths.contains(p) || p == "/v1/models":
            if let denied = authorize(req) {
                response = denied
            } else if p == "/v1/models" {
                response = m == "GET" ? modelList() : Self.error(405, "Use GET.")
            } else if m != "POST" {
                response = Self.error(405, "Use POST with a JSON body.")
            } else {
                (response, note) = await decide(req)
            }
        default:
            response = Self.error(404, "No route for \(req.method) \(req.path). jev-serve answers POST /api/alpha/decisions, POST /v1/classifier, GET /v1/models and GET /health.", type: "not_found")
        }
        let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
        log("\(req.method) \(req.path)\(note.isEmpty ? "" : " " + note) → \(response.status) \(ms) ms")
        if logBodies {
            log("  request: \(String(decoding: req.body, as: UTF8.self))")
            log("  response: \(String(decoding: response.body, as: UTF8.self))")
        }
        return response
    }

    // MARK: Decisions

    private func decide(_ req: HTTPRequest) async -> (HTTPResponse, String) {
        let wire: JevWire.Request
        do { wire = try JevWire.decodeRequest(req.body) } catch {
            return (Self.error(400, Self.message(error)), "")
        }
        let name = wire.model ?? defaultModel
        guard let served = model(named: name) else {
            return (Self.error(404, "jev-serve doesn't serve “\(name)”. Served: \(models.map(\.name).joined(separator: ", ")).", type: "not_found"), "")
        }
        let note = "\(served.name) \(wire.request.questions.count)q"
        let l = served.decider.limits
        let limits = DecisionLimits(maxQuestions: l.maxQuestions, maxChoiceCriteria: l.maxChoiceCriteria,
                                    maxScoreLevels: l.maxScoreLevels, maxStateCharacters: maxStateCharacters ?? l.maxStateCharacters)
        do { try wire.request.validate(against: limits) } catch {
            return (Self.error(400, Self.message(error)), note)
        }
        guard await queue.acquire() else {
            return (Self.error(503, "Busy: too many requests waiting. Try again shortly.", type: "overloaded"), note)
        }
        do {
            var (decision, tokens) = try await served.decider.decide(wire.request)
            await queue.release()
            decision.usage = DecisionUsage(inputTokens: tokens, outputTokens: 0, cost: 0)
            let body = try JevWire.encodeResponse(decision, model: served.repo, request: wire.request)
            return (.json(200, body), note)
        } catch let e as DecisionError {
            await queue.release()
            switch e {
            case .invalidRequest: return (Self.error(400, Self.message(e)), note)
            case .unavailable: return (Self.error(503, Self.message(e), type: "unavailable"), note)
            default: return (Self.error(500, Self.message(e), type: "server_error"), note)
            }
        } catch {
            await queue.release()
            return (Self.error(500, Self.message(error), type: "server_error"), note)
        }
    }

    /// A served model by its config name, or by its repo id (with or without `openjev:`).
    public func model(named name: String) -> ServedModel? {
        let bare = name.hasPrefix("openjev:") ? String(name.dropFirst("openjev:".count)) : name
        return models.first { $0.name == name } ?? models.first { $0.repo == bare }
    }

    private func modelList() -> HTTPResponse {
        let items = models.map { m in
            #"{"id":\#(jsonString(m.name)),"object":"model","owned_by":"jev-serve","model":\#(jsonString(m.repo)),"#
                + #""revision":\#(m.revision.map(jsonString) ?? "null"),"calibrated":\#(m.decider.calibrated)}"#
        }
        return .json(200, Data(#"{"object":"list","data":[\#(items.joined(separator: ","))]}"#.utf8))
    }

    // MARK: Auth

    private func authorize(_ req: HTTPRequest) -> HTTPResponse? {
        guard let token else { return nil }
        let given = req.headers["authorization"].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 } ?? ""
        return Self.constantTimeEqual(given, token) ? nil
            : Self.error(401, "Send the token from jev-serve's config: Authorization: Bearer <token>.", type: "unauthorized")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) { diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return diff == 0
    }

    // MARK: Errors

    static func error(_ status: Int, _ message: String, type: String = "invalid_request") -> HTTPResponse {
        .json(status, JevWire.encodeError(message: message, type: type, code: status))
    }

    static func message(_ error: Error) -> String {
        if let e = error as? DecisionError {
            switch e {
            case .invalidRequest(let m), .malformedAnswer(let m), .backend(let m), .pairing(let m): return m
            case .noRoute(let r): return "No route “\(r)”."
            case .unavailable(let id, let a): return "\(id.rest) isn't available: \(a)"
            @unknown default: return "\(e)"
            }
        }
        return error.localizedDescription
    }
}

/// Runs one decision at a time, the rest waiting in arrival order, up to `limit` waiting.
actor FIFOQueue {
    private let limit: Int
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async -> Bool {
        if !busy { busy = true; return true }
        guard waiting.count < limit else { return false }
        await withCheckedContinuation { waiting.append($0) }
        return true                       // handed over by release(); still busy
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// A JSON string literal (slashes unescaped).
func jsonString(_ s: String) -> String {
    let e = JSONEncoder()
    e.outputFormatting = .withoutEscapingSlashes
    return String(decoding: (try? e.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
}

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// One line on stderr, with the time.
public func jevServeLog(_ line: String) {
    FileHandle.standardError.write(Data("\(logFormatter.string(from: Date())) \(line)\n".utf8))
}
