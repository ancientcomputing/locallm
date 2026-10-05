// jev-serve — hosted Jev's HTTP API, answered by OpenJev on this Mac.
//
//   jev-serve --config jev-serve.json          # the config JevDK writes (File → Export Server Config…)
//   jev-serve --model mlx-community/Qwen3-4B-4bit   # quick try: default wrapper, no calibration
//
// Options: --host 127.0.0.1  --port 8746  --no-download  --log-bodies  --self-check  --help
//
// At startup each configured model is made ready (found, verified or downloaded, pinned to the
// version in the config), the default one is loaded, and only then does it start listening.

import Foundation
import LocalLMLabSDKCore
import JevServeKit
import LocalLMLabSDKInference
import OpenJevKit

let usage = """
    jev-serve — hosted Jev's API (OpenRouter /api/alpha/decisions, Featherless /v1/classifier), on this Mac.

    Usage:
      jev-serve --config <file>     serve the models in a config written by JevDK (File → Export Server Config…)
      jev-serve --model <repo>      serve one Hugging Face MLX model, default system instructions, no calibration

    Options:
      --host <address>   listen address (default from the config, else 127.0.0.1)
      --port <number>    port (default from the config, else 8746)
      --no-download      fail instead of downloading a missing model
      --log-bodies       also log request and response bodies (they hold your inputs)
      --self-check       start on a spare port, ask every model the same questions over HTTP and directly,
                         check the answers match, and exit (0 = all match)
      --help
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("jev-serve: \(message)\n".utf8))
    exit(1)
}

// MARK: Options

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
setvbuf(stdout, nil, _IOLBF, 0)          // line-buffered, so the banner shows when piped or logged
if flag("--help") || flag("-h") { print(usage); exit(0) }
let configPath = option("--config")
let modelOption = option("--model")
let hostOption = option("--host")
let portOption = option("--port")
let noDownload = flag("--no-download")
let logBodies = flag("--log-bodies")
let selfCheck = flag("--self-check")
if let extra = args.first { fail("unknown option \(extra)\n\n\(usage)") }

// MARK: Config

var config: JevServeConfig
if let configPath {
    do { config = try JevServeConfig.read(URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)) } catch {
        fail("can't read \(configPath): \(error.localizedDescription)")
    }
    if let modelOption { fail("use --config or --model, not both (got --model \(modelOption))") }
} else if let modelOption {
    let name = modelOption.split(separator: "/").last.map { $0.lowercased() } ?? modelOption
    config = JevServeConfig(models: [.init(name: name, tuning: .init(model: ModelID(scheme: "openjev", rest: modelOption)))])
    config.upsert(config.models[0])
} else {
    print(usage)
    exit(1)
}
if let hostOption { config.listen.host = hostOption }
if let portOption {
    guard let p = Int(portOption), (1...65_535).contains(p) else { fail("--port must be 1–65535") }
    config.listen.port = p
}
guard !config.models.isEmpty else { fail("the config has no models") }
var repos: [String] = []
var pins: [String: String] = [:]
for m in config.models {
    guard let id = m.tuning.model, !id.rest.isEmpty else { fail("model “\(m.name)” has no model id (tuning.model)") }
    if !repos.contains(id.rest) { repos.append(id.rest) }
    if let r = m.tuning.revision {
        if let other = pins[id.rest], other != r {
            fail("\(id.rest) is pinned to two versions (\(other.prefix(7)), \(r.prefix(7))); one model can only be served at one version")
        }
        pins[id.rest] = r
    }
}

// MARK: Models: found, verified or downloaded, pinned

// Pinned to the versions in the config, so a download fetches exactly what was tested and
// calibrated. A model with no version is pinned on first download (trust on first use).
let mlx = MLXModelProvider(residentModelLimit: max(1, repos.count), pinnedRevisions: pins, pinStore: MLXFilePinStore())

@MainActor func ensureReady(_ repo: String) async {
    let id = ModelID(scheme: "mlx", rest: repo)!
    switch mlx.availability(for: id) {
    case .available:
        return
    case .unavailable(_, let detail):
        fail("\(repo) can't run here: \(detail)")
    case .needsCredential:
        fail("\(repo) needs a Hugging Face credential")
    case .notDownloaded:
        break
    @unknown default:
        break
    }
    let other = mlx.installed.first { $0.repoID == repo }?.resolvedRevision
    let what: String
    if let want = pins[repo], let other, other != want {
        what = "\(repo) version \(want.prefix(7)) (the one in the config) isn't on this Mac; version \(other.prefix(7)) is"
    } else {
        what = "\(repo) isn't on this Mac"
    }
    if noDownload { fail("\(what), and --no-download is set. Drop --no-download to fetch it, or download it in JevDK's Models.") }
    if other != nil { jevServeLog("\(what): fetching the configured version") }
    if let pre = try? await mlx.validate(repo), !pre.passed {
        fail("pre-flight failed for \(repo) (\(pre.failedStage?.rawValue ?? "?")): \(pre.detail ?? "")")
    }
    let version = pins[repo].map { " @ \($0.prefix(7))" } ?? ""
    jevServeLog("downloading \(repo)\(version) (a copy already in the Hugging Face cache is verified, only missing files fetched)…")
    do {
        var last = -1
        for try await event in mlx.download(repo) {
            if case .progress(_, _, let f) = event {
                let pct = Int(f * 100)
                if pct != last {
                    last = pct
                    FileHandle.standardError.write(Data("\u{1B}[2K\r  \(repo)\(version)  \(pct)%".utf8))
                }
            }
        }
        FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8))
        jevServeLog("\(repo): ready")
    } catch {
        FileHandle.standardError.write(Data("\n".utf8))
        fail("download of \(repo) failed: \(error.localizedDescription)")
    }
}

for repo in repos { await ensureReady(repo) }

// MARK: Providers

var served: [ServedModel] = []
for m in config.models {
    let repo = m.tuning.model!.rest
    var tuning = m.tuning
    let set = DecisionQuestionSet(name: m.name, questions: [], tuning: tuning)
    let probe = OpenJevDecisionProvider(mlx: mlx, tunedWith: set)
    let id = ModelID(scheme: probe.scheme, rest: repo)!
    if let why = probe.tuningMismatch(for: id) {
        jevServeLog("warning: “\(m.name)”: \(why); serving it without its calibration")
        tuning.calibration = nil
    }
    if probe.warnings(for: id).contains(.mixtureOfExperts) {
        jevServeLog("warning: \(repo) is a mixture-of-experts model; its probabilities are unstable as a decider")
    }
    let provider = OpenJevDecisionProvider(mlx: mlx, tunedWith: DecisionQuestionSet(name: m.name, questions: [], tuning: tuning))
    let revision = mlx.effectivePin(for: repo)?.revision ?? tuning.revision
        ?? mlx.installed.first { $0.repoID == repo }?.resolvedRevision
    served.append(ServedModel(name: m.name, repo: repo, revision: revision, decider: OpenJevDecider(provider: provider, id: id)))
}
let defaultName = config.defaultModel ?? served[0].name
guard let defaultModel = served.first(where: { $0.name == defaultName }) else {
    fail("defaultModel “\(defaultName)” isn't one of the models")
}
jevServeLog("loading \(defaultModel.repo)…")
if let d = defaultModel.decider as? OpenJevDecider { await d.provider.prewarm(d.id) }

// MARK: Serve

let service = Service(models: served, defaultModel: defaultName, token: config.token,
                      maxStateCharacters: config.maxStateCharacters, queueLimit: 32, logBodies: logBodies)
let server: HTTPServer
do {
    server = try HTTPServer(host: config.listen.host, port: selfCheck ? 0 : UInt16(config.listen.port), maxBodyBytes: 1_000_000) { req in
        await service.handle(req)
    }
    try await server.start()
} catch {
    fail("\(error.localizedDescription) (\(config.listen.host):\(config.listen.port); is another jev-serve running? try --port)")
}

if selfCheck { exit(await runSelfCheck(port: server.port ?? 0)) }

let base = "http://\(config.listen.host):\(config.listen.port)"
print("jev-serve on \(base)\(config.token != nil ? "  (token required)" : "")")
for m in served {
    let state = m.decider.calibrated ? "calibrated" : "not calibrated"
    print("  \(m.name)\(m.name == defaultName ? " (default)" : "")  \(m.repo)\(m.revision.map { " @ \($0.prefix(7))" } ?? "")  \(state)")
}
print("OpenRouter clients:  base URL \(base)/api   (POST /alpha/decisions)")
print("Featherless clients: base URL \(base)/v1    (POST /classifier)")
if !["127.0.0.1", "localhost", "::1"].contains(config.listen.host) {
    jevServeLog("warning: listening on \(config.listen.host): inputs\(config.token != nil ? " and the token" : "") cross the network unencrypted (plain HTTP)")
}
if logBodies { jevServeLog("warning: --log-bodies is on: request and response bodies (your inputs) are logged") }

while true { try await Task.sleep(for: .seconds(3600)) }

// MARK: Self-check

/// Asks every served model the same questions through the running server (HTTP + the wire format)
/// and directly (its decider), and checks the answers match. The live counterpart of the unit tests,
/// which can't load MLX.
@MainActor func runSelfCheck(port: UInt16) async -> Int32 {
    let questions: [DecisionQuestion] = [
        .choice("team", "Which team should handle this customer message?", criteria: [
            "billing": "payments, invoices and refunds", "technical": "bugs, outages and product errors",
            "account": "profile, login and subscription changes"]),
        .noul("refund", "Does the customer explicitly ask for money back?"),
        .score("urgency", "How urgent is it?", criteria: ["can wait", "soon", "now"]),
    ]
    let inputs = ["I see two charges for my Pro plan this month. Please refund one.",
                  "Nothing loads since this morning, my whole team is stuck."]
    var ok = true
    for m in served {
        for input in inputs {
            let request = DecisionRequest(state: .text(input), questions: questions)
            do {
                var http = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/classifier")!)
                http.httpMethod = "POST"
                http.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let t = config.token { http.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
                http.httpBody = try JevWire.encodeRequest(request, model: m.name)
                let (data, response) = try await URLSession.shared.data(for: http)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    print("FAIL \(m.name): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(JevWire.errorMessage(in: data) ?? "")")
                    ok = false; continue
                }
                let served = try JevWire.decodeResponse(data, request: request)
                let direct = try await m.decider.decide(request).decision
                let diff = maxDifference(served.answers, direct.answers)
                let same = diff < 1e-9 && served.fidelity == direct.fidelity
                ok = ok && same
                print("\(same ? "ok  " : "FAIL") \(m.name)  \(input.prefix(36))…  max difference \(diff)  \(served.fidelity.map { "\($0)" } ?? "no fidelity")")
            } catch {
                print("FAIL \(m.name): \(error.localizedDescription)")
                ok = false
            }
        }
    }
    print(ok ? "self-check passed" : "self-check FAILED")
    return ok ? 0 : 1
}

func maxDifference(_ a: [String: DecisionAnswer], _ b: [String: DecisionAnswer]) -> Double {
    func flat(_ x: [String: DecisionAnswer]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (id, ans) in x {
            switch ans {
            case .noul(let p): out[id] = p
            case .choice(let c): out["\(id).\(c.choice)"] = 1; for (k, p) in c.probabilities { out["\(id).p.\(k)"] = p }
            case .score(let sc): out["\(id).score"] = sc.score; for (i, p) in sc.probabilities.enumerated() { out["\(id).p\(i)"] = p }
            @unknown default: break
            }
        }
        return out
    }
    let x = flat(a), y = flat(b)
    guard Set(x.keys) == Set(y.keys) else { return .infinity }
    return x.map { abs($0.value - y[$0.key]!) }.max() ?? 0
}
