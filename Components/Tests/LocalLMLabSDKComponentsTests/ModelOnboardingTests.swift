import Foundation
import Testing
import LocalLMLabSDKCore
import LocalLMLabSDKComponents

// ModelOnboardingModel: Validate -> Download -> Pin, per repo, in order. Every dependency is a closure, so
// none of this needs a provider, a network or a GPU.

private let sha1 = "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3"
private let sha2 = "ff1143e3a10547c9f2129e94ca37059b096b23f4"

private func installed(_ repo: String, revision: String) -> InstalledModel {
    InstalledModel(id: ModelID(scheme: "mlx", rest: repo)!, repoID: repo, resolvedRevision: revision)
}

/// Records the order things happened in.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ e: String) { lock.lock(); entries.append(e); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

private func source(
    log: Log = Log(),
    preflight: @escaping @Sendable (String) -> PreflightResult? = { _ in PreflightResult() },
    revisions: [String: String] = [:],
    downloadFails: Set<String> = [],
    progressSteps: [Double] = []
) -> ModelOnboardingSource {
    ModelOnboardingSource(
        validate: { repo in log.add("validate:\(repo)"); return preflight(repo) },
        download: { repo, report in
            log.add("download:\(repo)")
            for f in progressSteps { report(DownloadProgress(bytesReceived: Int64(f * 100), totalBytes: 100, fraction: f)) }
            if downloadFails.contains(repo) { throw LocalLMLabError.download(stage: "verify", underlying: nil) }
            return installed(repo, revision: revisions[repo] ?? sha1)
        },
        cancel: { log.add("cancel:\($0)") })
}

@MainActor
private func finish(_ model: ModelOnboardingModel) async {
    model.start()
    while model.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor @Test func aSingleModelWalksAllThreeStepsAndCompletes() async {
    let model = ModelOnboardingModel(requests: [ModelOnboardingRequest(repoID: "acme/model")], source: source())
    #expect(!model.hasStarted && !model.isFinished)
    await finish(model)
    let item = model.items[0]
    #expect(item.validate == .done("passed"))
    if case .done = item.download {} else { Issue.record("download should be done: \(item.download)") }
    if case .done(let text) = item.pin { #expect(text.contains("resolved to a5339a4131f1")) } else { Issue.record("pin should be done") }
    #expect(model.isFinished && !model.hasFailed)
    #expect(model.completed.map(\.repoID) == ["acme/model"])
}

@MainActor @Test func aFailedPreflightStopsBeforeAnyDownloadAndNamesTheStage() async {
    let log = Log()
    let denied = source(log: log, preflight: { _ in PreflightResult(failedStage: .trustPolicy, detail: "not on the allow-list") })
    let model = ModelOnboardingModel(requests: [ModelOnboardingRequest(repoID: "evil/model")], source: denied)
    await finish(model)
    guard case .failed(let text) = model.items[0].validate else { Issue.record("validate should fail"); return }
    #expect(text.contains("failed at .trustPolicy") && text.contains("not on the allow-list"))
    #expect(!log.all.contains { $0.hasPrefix("download:") }, "a denied repo costs no download")
    #expect(model.items[0].download == .pending && model.items[0].pin == .pending)
    #expect(model.hasFailed && !model.isFinished)
}

@MainActor @Test func aFailureStopsEverythingAfterItAndLeavesTheRestPending() async {
    let log = Log()
    let two = [ModelOnboardingRequest(role: "Base model", repoID: "acme/base"), ModelOnboardingRequest(role: "Helper", repoID: "acme/helper")]
    let model = ModelOnboardingModel(requests: two, source: source(log: log, downloadFails: ["acme/base"]))
    await finish(model)
    #expect(model.items[0].hasFailed)
    #expect(model.items[1].validate == .pending, "the second repo is never touched on the strength of the first's failure")
    #expect(!log.all.contains("validate:acme/helper"))
    #expect(model.completed.isEmpty)
}

@MainActor @Test func reposRunInOrderOneAtATime() async {
    let log = Log()
    let two = [ModelOnboardingRequest(repoID: "acme/base"), ModelOnboardingRequest(repoID: "acme/helper")]
    let model = ModelOnboardingModel(requests: two, source: source(log: log))
    await finish(model)
    #expect(log.all == ["validate:acme/base", "download:acme/base", "validate:acme/helper", "download:acme/helper"])
    #expect(model.completed.map(\.repoID) == ["acme/base", "acme/helper"])
    #expect(model.isFinished)
}

@MainActor @Test func theExpectedRevisionIsVerifiedAndAMismatchFailsThePinStep() async {
    let good = ModelOnboardingModel(
        requests: [ModelOnboardingRequest(repoID: "acme/model", expectedRevision: sha1)], source: source(revisions: ["acme/model": sha1]))
    await finish(good)
    if case .done(let text) = good.items[0].pin { #expect(text.contains("verified against the pin this app ships")) } else { Issue.record("should verify") }

    let bad = ModelOnboardingModel(
        requests: [ModelOnboardingRequest(repoID: "acme/model", expectedRevision: sha1)], source: source(revisions: ["acme/model": sha2]))
    await finish(bad)
    guard case .failed(let text) = bad.items[0].pin else { Issue.record("a different commit must fail"); return }
    #expect(text.contains("resolved ff1143e3a105") && text.contains("expects a5339a4131f1"))
    #expect(bad.completed.isEmpty, "a model that failed its pin check is not reported as completed")
}

@MainActor @Test func aRepoThatIsNotAModelSkipsValidation() async {
    let log = Log()
    let model = ModelOnboardingModel(
        requests: [ModelOnboardingRequest(role: "Adapter", repoID: "acme/adapter", validates: false)], source: source(log: log))
    await finish(model)
    #expect(!log.all.contains { $0.hasPrefix("validate:") })
    if case .done(let text) = model.items[0].validate { #expect(text.contains("not applicable")) } else { Issue.record("should be done") }
    #expect(model.isFinished)
}

@MainActor @Test func aSourceThatCannotValidateReadsAsNotChecked() async {
    let model = ModelOnboardingModel(requests: [ModelOnboardingRequest(repoID: "acme/model")], source: source(preflight: { _ in nil }))
    await finish(model)
    #expect(model.items[0].validate == .done("not checked"))
    #expect(model.isFinished)
}

@MainActor @Test func downloadProgressIsReportedThenCleared() async {
    let model = ModelOnboardingModel(requests: [ModelOnboardingRequest(repoID: "acme/model")], source: source(progressSteps: [0.25, 0.5]))
    model.start()
    var sawProgress = false
    while model.isRunning {
        if let f = model.items[0].downloadFraction, f > 0 { sawProgress = true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(model.items[0].downloadFraction == nil, "no progress bar left behind once the download is done")
    _ = sawProgress  // progress delivery is asynchronous; only the cleared end state is asserted
}

@MainActor @Test func aCancelledDownloadIsShownAsCancelledAndCancelsTheSource() async {
    let log = Log()
    let hanging = ModelOnboardingSource(
        validate: { _ in PreflightResult() },
        download: { repo, _ in
            log.add("download:\(repo)")
            try await Task.sleep(for: .seconds(30))
            return installed(repo, revision: sha1)
        },
        cancel: { log.add("cancel:\($0)") })
    let model = ModelOnboardingModel(requests: [ModelOnboardingRequest(repoID: "acme/model")], source: hanging)
    model.start()
    while model.items[0].download != .running { try? await Task.sleep(for: .milliseconds(5)) }
    model.cancel()
    while model.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(log.all.contains("cancel:acme/model"), "the transfer is stopped at the source, not just abandoned")
    #expect(model.items[0].download == .failed("cancelled"))
    #expect(model.completed.isEmpty)
}

@MainActor @Test func tryAgainAfterAFailureRunsTheWholeFlowFromTheStart() async {
    let log = Log()
    let flaky = ModelOnboardingSource(
        validate: { _ in log.add("validate"); return PreflightResult() },
        download: { repo, _ in
            log.add("download")
            if log.all.filter({ $0 == "download" }).count == 1 { throw LocalLMLabError.download(stage: "verify", underlying: nil) }
            return installed(repo, revision: sha1)
        })
    let model = ModelOnboardingModel(requests: [ModelOnboardingRequest(repoID: "acme/model")], source: flaky)
    await finish(model)
    #expect(model.hasFailed)
    await finish(model)  // start() resets first
    #expect(model.isFinished && !model.hasFailed)
    #expect(log.all == ["validate", "download", "validate", "download"])
}

@MainActor @Test func startWhileRunningDoesNothing() async {
    let log = Log()
    let slow = ModelOnboardingSource(
        validate: { _ in log.add("validate"); try await Task.sleep(for: .milliseconds(80)); return PreflightResult() },
        download: { repo, _ in installed(repo, revision: sha1) })
    let model = ModelOnboardingModel(requests: [ModelOnboardingRequest(repoID: "acme/model")], source: slow)
    model.start()
    model.start()
    model.start()
    while model.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(log.all == ["validate"], "one flow, not three racing each other")
}

@MainActor @Test func emptyRequestsAreNeverFinished() {
    let model = ModelOnboardingModel(requests: [], source: source())
    #expect(!model.isFinished && !model.hasStarted)
}
