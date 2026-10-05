import Foundation
import Network
import Testing
import LocalLMLabSDKCore
import LocalLMLabSDKRemote
@testable import JevServeKit

// jev-serve without a GPU: a scripted decider behind the real routes and HTTP server, and the SDK's
// own hosted-Jev client (JevDecisionProvider) as the caller. Live MLX: `jev-serve --self-check`.

/// Answers every question the same way: yes/no 0.8; a choice's first option at 0.9; a score's top
/// level. Optionally slow, failing, or with its own limits.
struct ScriptedDecider: Decider {
    var limits = DecisionLimits(maxQuestions: 64, maxChoiceCriteria: 26, maxScoreLevels: 10)
    var calibrated = true
    var delay: Duration = .zero
    var error: DecisionError?
    var order: OrderLog?

    func decide(_ request: DecisionRequest) async throws -> (decision: Decision, inputTokens: Int?) {
        if let order { await order.append(request.state) }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        var answers: [String: DecisionAnswer] = [:]
        for q in request.questions {
            switch q.kind {
            case .noul: answers[q.id] = .noul(0.8)
            case .choice(let c):
                let rest = c.count > 1 ? 0.1 / Double(c.count - 1) : 0
                let probs = Dictionary(uniqueKeysWithValues: c.enumerated().map { ($0.element.key, $0.offset == 0 ? 0.9 : rest) })
                answers[q.id] = .choice(ChoiceAnswer(choice: c[0].key, confidence: 0.9, probabilities: probs))
            case .score(let levels):
                var p = Array(repeating: 0.0, count: levels.count); p[p.count - 1] = 1
                answers[q.id] = .score(ScoreAnswer(score: Double(levels.count - 1), confidence: 1, probabilities: p, legend: levels))
            @unknown default: break
            }
        }
        return (Decision(answers: answers, modelID: ModelID("openjev:test/model")!, fidelity: .tokenScored(calibrated: calibrated),
                         latency: .milliseconds(1)), 42)
    }
}

actor OrderLog {
    private(set) var states: [DecisionState] = []
    func append(_ s: DecisionState) { states.append(s) }
}

private func service(_ decider: ScriptedDecider = ScriptedDecider(), token: String? = nil, maxState: Int? = 20_000,
                     queueLimit: Int = 32) -> Service {
    Service(models: [ServedModel(name: "support", repo: "mlx-community/Qwen3-4B-4bit", revision: "4dcb3d1abc", decider: decider)],
            defaultModel: "support", token: token, maxStateCharacters: maxState, queueLimit: queueLimit, log: { _ in })
}

private let body = #"""
{"model":"support","state":"Nothing loads, my team is stuck.","questions":{
 "team":{"type":"choice","instructions":"Which team?","criteria":{"technical":"bugs","billing":"payments","account":"login"}},
 "refund":{"type":"noul","instructions":"Refund asked?"},
 "urgency":{"type":"score","instructions":"How urgent?","criteria":["can wait","soon","now"]}}}
"""#

private func post(_ s: Service, _ path: String = "/v1/classifier", _ json: String = body, headers: [String: String] = [:]) async -> HTTPResponse {
    await s.handle(HTTPRequest(method: "POST", path: path, headers: headers, body: Data(json.utf8)))
}

private func errorMessage(_ r: HTTPResponse) -> String { JevWire.errorMessage(in: r.body) ?? "" }

@Suite struct RouteTests {
    @Test func bothDecisionPathsAnswerInHostedShape() async throws {
        let s = service()
        for path in Service.decisionPaths {
            let r = await post(s, path)
            #expect(r.status == 200)
            let obj = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
            #expect(obj["model"] as? String == "mlx-community/Qwen3-4B-4bit")
            #expect(obj["fidelity"] as? String == "tokenScored")
            #expect(obj["calibrated"] as? Bool == true)
            #expect((obj["usage"] as? [String: Any])?["input_tokens"] as? Int == 42)
            let answers = try #require(obj["answers"] as? [String: Any])
            #expect((answers["team"] as? [String: Any])?["choice"] as? String == "technical")
            #expect((answers["refund"] as? [String: Any])?["noul"] as? Double == 0.8)
        }
    }

    @Test func modelByNameRepoPrefixedOrDefault() async {
        let s = service()
        for model in ["support", "mlx-community/Qwen3-4B-4bit", "openjev:mlx-community/Qwen3-4B-4bit"] {
            #expect(await post(s, "/v1/classifier", body.replacingOccurrences(of: #""model":"support""#, with: #""model":"\#(model)""#)).status == 200)
        }
        #expect(await post(s, "/v1/classifier", body.replacingOccurrences(of: #""model":"support","#, with: "")).status == 200)
        let r = await post(s, "/v1/classifier", body.replacingOccurrences(of: #""model":"support""#, with: #""model":"gpt-9""#))
        #expect(r.status == 404)
        #expect(errorMessage(r).contains("Served: support"))
    }

    @Test func trailingSlashAndOtherRoutes() async throws {
        let s = service()
        #expect(await post(s, "/v1/classifier/").status == 200)
        #expect(await s.handle(HTTPRequest(method: "GET", path: "/v1/classifier")).status == 405)
        #expect(await s.handle(HTTPRequest(method: "GET", path: "/v1/chat/completions")).status == 404)
        #expect(await s.handle(HTTPRequest(method: "POST", path: "/health")).status == 405)
        let health = await s.handle(HTTPRequest(method: "GET", path: "/health"))
        #expect(String(decoding: health.body, as: UTF8.self) == #"{"status":"ok","models":["support"]}"#)
        let models = await s.handle(HTTPRequest(method: "GET", path: "/v1/models"))
        let text = String(decoding: models.body, as: UTF8.self)
        #expect(text.contains(#""model":"mlx-community/Qwen3-4B-4bit""#))       // slashes unescaped
        #expect(text.contains(#""revision":"4dcb3d1abc""#) && text.contains(#""calibrated":true"#))
    }

    @Test func badRequestsAre400WithAReason() async {
        let s = service(maxState: 50)
        let cases: [(String, String)] = [
            ("not json", "isn't valid JSON"),
            (#"{"state":"x"}"#, "questions"),
            (#"{"state":"x","questions":{"a":{"type":"rank","instructions":"?"}}}"#, "rank"),
            (#"{"state":"\#(String(repeating: "a", count: 60))","questions":{"a":{"type":"noul","instructions":"?"}}}"#, "at most 50"),
            (#"{"state":"x","questions":{"a":{"type":"noul","instructions":"?"},"a":{"type":"noul","instructions":"?"}}}"#, "a"),
        ]
        for (json, fragment) in cases {
            let r = await post(s, "/v1/classifier", json)
            #expect(r.status == 400, "\(json)")
            #expect(errorMessage(r).contains(fragment), "\(errorMessage(r))")
        }
        let tooMany = #"{"state":"x","questions":{"c":{"type":"choice","instructions":"?","criteria":[\#((0..<27).map { "\"k\($0)\"" }.joined(separator: ","))]}}}"#
        #expect(await post(s, "/v1/classifier", tooMany).status == 400)
    }

    @Test func deciderErrorsMapToStatuses() async {
        let unavailable = DecisionError.unavailable(ModelID("openjev:test/model")!, .notDownloaded)
        #expect(await post(service(ScriptedDecider(error: unavailable))).status == 503)
        #expect(await post(service(ScriptedDecider(error: .invalidRequest("no")))).status == 400)
        #expect(await post(service(ScriptedDecider(error: .backend("boom")))).status == 500)
    }

    @Test func uncalibratedSaysSo() async throws {
        let r = await post(service(ScriptedDecider(calibrated: false)))
        let obj = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        #expect(obj["calibrated"] as? Bool == false)
    }
}

@Suite struct AuthTests {
    @Test func tokenGuardsEverythingButHealth() async {
        let s = service(token: "secret-token")
        #expect(await post(s).status == 401)
        #expect(await post(s, headers: ["authorization": "Bearer wrong"]).status == 401)
        #expect(await post(s, headers: ["authorization": "Bearer secret-token"]).status == 200)
        #expect(await s.handle(HTTPRequest(method: "GET", path: "/v1/models")).status == 401)
        #expect(await s.handle(HTTPRequest(method: "GET", path: "/health")).status == 200)
    }

    @Test func constantTimeCompare() {
        #expect(Service.constantTimeEqual("abc", "abc"))
        #expect(!Service.constantTimeEqual("abc", "abd"))
        #expect(!Service.constantTimeEqual("abc", "abcd"))
        #expect(!Service.constantTimeEqual("", "a"))
    }
}

@Suite struct QueueTests {
    @Test func decisionsRunOneAtATimeInArrivalOrder() async throws {
        let log = OrderLog()
        let s = service(ScriptedDecider(delay: .milliseconds(30), order: log))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    _ = await post(s, "/v1/classifier", body.replacingOccurrences(of: "Nothing loads, my team is stuck.", with: "input \(i)"))
                }
                try? await Task.sleep(for: .milliseconds(5))        // arrive in order
            }
        }
        #expect(await log.states == (0..<5).map { DecisionState.text("input \($0)") })
    }

    @Test func fullQueueIs503() async {
        let s = service(ScriptedDecider(delay: .milliseconds(200)), queueLimit: 1)
        async let first = post(s)
        try? await Task.sleep(for: .milliseconds(20))
        async let second = post(s)                                  // waits
        try? await Task.sleep(for: .milliseconds(20))
        let third = await post(s)                                   // no room
        #expect(third.status == 503)
        #expect(await first.status == 200)
        #expect(await second.status == 200)
    }
}

// MARK: - Over HTTP

private func startServer(_ s: Service, maxBody: Int = 1_000_000) async throws -> (HTTPServer, URL) {
    let server = try HTTPServer(host: "127.0.0.1", port: 0, maxBodyBytes: maxBody) { await s.handle($0) }
    try await server.start()
    return (server, URL(string: "http://127.0.0.1:\(try #require(server.port))")!)
}

/// Sends raw bytes and returns the raw response (for malformed requests URLSession won't send).
private func raw(_ port: UInt16, _ bytes: Data) async throws -> String {
    let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    conn.start(queue: .global())
    defer { conn.cancel() }
    conn.send(content: bytes, completion: .idempotent)
    return try await withCheckedThrowingContinuation { cont in
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            if let error { cont.resume(throwing: error) } else { cont.resume(returning: String(decoding: data ?? Data(), as: UTF8.self)) }
        }
    }
}

@Suite(.serialized) struct HTTPTests {
    @Test func keepAliveAndJSON() async throws {
        let (server, base) = try await startServer(service())
        defer { server.stop() }
        for _ in 0..<3 {
            var req = URLRequest(url: base.appendingPathComponent("v1/classifier"))
            req.httpMethod = "POST"
            req.httpBody = Data(body.utf8)
            let (data, response) = try await URLSession.shared.data(for: req)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(JevWire.errorMessage(in: data) == nil)
        }
    }

    @Test func capsAndMalformedRequests() async throws {
        let (server, base) = try await startServer(service(), maxBody: 1_000)
        defer { server.stop() }
        let port = try #require(server.port)
        var big = URLRequest(url: base.appendingPathComponent("v1/classifier"))
        big.httpMethod = "POST"
        big.httpBody = Data(repeating: 0x61, count: 5_000)
        let (_, r413) = try await URLSession.shared.data(for: big)
        #expect((r413 as? HTTPURLResponse)?.statusCode == 413)
        #expect(try await raw(port, Data("GARBAGE\r\n\r\n".utf8)).hasPrefix("HTTP/1.1 400"))
        #expect(try await raw(port, Data("POST /v1/classifier HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)).hasPrefix("HTTP/1.1 411"))
        let hugeHeader = "GET /health HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 20_000)
        #expect(try await raw(port, Data(hugeHeader.utf8)).hasPrefix("HTTP/1.1 431"))
        #expect(try await raw(port, Data("GET /health?x=1 HTTP/1.1\r\nHost: x\r\n\r\n".utf8)).contains(#""status":"ok""#))
    }

    /// The SDK's own hosted-Jev client, pointed at jev-serve: what it gets matches what the decider
    /// answered, through HTTP and JevWire both ways, and the token and fidelity extension work.
    @Test @MainActor func sdkClientRoundTrip() async throws {
        let decider = ScriptedDecider()
        let (server, base) = try await startServer(service(decider, token: "t0ken"))
        defer { server.stop() }
        let config = JevProviderConfig(scheme: "jevserve", displayName: "jev-serve",
                                       endpoint: base.appendingPathComponent("v1/classifier"), auth: .apiKey("t0ken"),
                                       fidelity: .tokenScored(calibrated: false), responseLimits: .default, timeout: 10)
        let lab = LocalLMLab()
        try lab.models.register(decision: JevDecisionProvider(try config.validated()))
        lab.models.route(decision: "served", to: ModelID("jevserve:support")!)
        let questions: [DecisionQuestion] = [
            .choice("team", "Which team?", criteria: ["technical": "bugs", "billing": "payments", "account": "login"]),
            .noul("refund", "Refund asked?"),
            .score("urgency", "How urgent?", criteria: ["can wait", "soon", "now"]),
        ]
        let request = DecisionRequest(state: .json(#"{"subject":"Refund","amount":12}"#), questions: questions)
        let viaServer = try await lab.decide(route: "served", state: request.state, questions: questions)
        let direct = try await decider.decide(request).decision
        #expect(viaServer.answers == direct.answers)
        #expect(viaServer.fidelity == .tokenScored(calibrated: true))     // from the server, over the config's default
        #expect(viaServer.usage?.inputTokens == 42)

        // The wrong token is the provider's credential error, not a crash.
        var wrong = config
        wrong.auth = .apiKey("nope")
        lab.models.replace(decision: JevDecisionProvider(wrong))
        await #expect(throws: DecisionError.self) {
            _ = try await lab.decide(route: "served", state: .text("x"), questions: questions)
        }
    }
}
