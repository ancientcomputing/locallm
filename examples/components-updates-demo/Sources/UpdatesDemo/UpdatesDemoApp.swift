import LocalLMLabSDKComponents
import LocalLMLabSDKCore
import SwiftUI

// Every source here is simulated with short sleeps, so each state of each view can be reached on demand.

private let shippedCommit = "9eba008f65cdc8aee60201be10dcd0e7858455ce"
private let newerCommit = "ff1143e3a10547c9f2129e94ca37059b096b23f4"

@main
@available(macOS 27, *)
struct UpdatesDemoApp: App {
    var body: some Scene {
        WindowGroup("Components: onboarding, updates, versions") {
            DemoView().frame(minWidth: 640, minHeight: 720)
        }
    }
}

// MARK: - Simulated sources

/// Onboarding source with switches for each way a flow can go wrong.
private struct Faults: Sendable {
    var denyPreflight = false
    var resolveDifferentCommit = false
    var failDownload = false
}

private func simulatedOnboardingSource(_ faults: Faults) -> ModelOnboardingSource {
    ModelOnboardingSource(
        validate: { repo in
            try await Task.sleep(for: .milliseconds(500))
            if faults.denyPreflight {
                return PreflightResult(failedStage: .trustPolicy, detail: "\(repo) isn't on this app's allow-list")
            }
            return PreflightResult(detail: "qwen2 · ≈ 278 MB")
        },
        download: { repo, report in
            for step in 0...10 {
                try await Task.sleep(for: .milliseconds(180))
                report(DownloadProgress(bytesReceived: Int64(step) * 27_800_000, totalBytes: 278_000_000, fraction: Double(step) / 10))
                if faults.failDownload && step == 6 { throw LocalLMLabError.download(stage: "verify", underlying: nil) }
            }
            return InstalledModel(
                id: ModelID(scheme: "mlx", rest: repo)!, repoID: repo,
                resolvedRevision: faults.resolveDifferentCommit ? newerCommit : shippedCommit)
        })
}

/// A model that is on `shippedCommit`, with `newerCommit` on offer; failures switchable.
private final class SimulatedModel: @unchecked Sendable {
    private let lock = NSLock()
    private var _current = shippedCommit
    var failNextUpdate = false
    var current: String { lock.lock(); defer { lock.unlock() }; return _current }
    func set(_ commit: String) { lock.lock(); _current = commit; lock.unlock() }
}

private func simulatedActions(_ sim: SimulatedModel) -> ModelUpdateActions {
    ModelUpdateActions(
        check: {
            try await Task.sleep(for: .milliseconds(600))
            let current = sim.current
            return ModelUpdateOffer(
                current: current, available: newerCommit,
                changes: current == newerCommit ? [] : [
                    ModelFileChange(path: "config.json", kind: .modified, oldSize: 1648, newSize: 1653),
                ])
        },
        apply: { revision, progress, beforeSwitch in
            for step in 0...10 {
                try await Task.sleep(for: .milliseconds(150))
                progress(Double(step) / 10)
            }
            if sim.failNextUpdate { sim.failNextUpdate = false; throw LocalLMLabError.download(stage: "cacheQuota", underlying: nil) }
            try await beforeSwitch()          // the host's pause point, before anything changes
            try await Task.sleep(for: .milliseconds(300))
            sim.set(revision)
        })
}

// MARK: - Demo

@available(macOS 27, *)
private struct DemoView: View {
    @State private var faults = Faults()
    @State private var onboarding: ModelOnboardingModel?

    @State private var sim = SimulatedModel()
    @State private var userChosen: ModelUpdateModel
    @State private var builtIn: ModelUpdateModel
    @State private var versions: ModelVersionsModel
    @State private var pauseNote = "idle"

    init() {
        let userSim = SimulatedModel()
        let builtInSim = SimulatedModel()
        _sim = State(initialValue: builtInSim)
        _userChosen = State(initialValue: ModelUpdateModel(
            actions: simulatedActions(userSim), ownership: .userChosen, currentRevision: shippedCommit))
        let built = ModelUpdateModel(
            actions: simulatedActions(builtInSim), ownership: .developerOffered, currentRevision: shippedCommit)
        built.shippedRevision = shippedCommit
        _builtIn = State(initialValue: built)
        _versions = State(initialValue: ModelVersionsModel(
            list: { [
                ModelVersionRow(revision: shippedCommit, isCurrent: false, freesBytes: 1_648, sharedBytes: 190_208_261),
                ModelVersionRow(revision: newerCommit, isCurrent: true, freesBytes: 1_653, sharedBytes: 190_208_261),
            ] },
            remove: { row in row.freesBytes }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("1 · Onboarding a model") {
                    Text("Validate → Download → Pin. Try the switches, then Add.").font(.caption).foregroundStyle(.secondary)
                    Toggle("preflight denies the repo (trust policy)", isOn: $faults.denyPreflight)
                    Toggle("download resolves a different commit than the app ships", isOn: $faults.resolveDifferentCommit)
                    Toggle("download fails part-way", isOn: $faults.failDownload)
                    Button("Add mlx-community/gemma-3-270m-it-4bit") {
                        onboarding = ModelOnboardingModel(
                            requests: [ModelOnboardingRequest(
                                repoID: "mlx-community/gemma-3-270m-it-4bit", expectedRevision: shippedCommit)],
                            source: simulatedOnboardingSource(faults))
                        onboarding?.start()
                    }
                    .disabled(onboarding?.isRunning == true)
                    if let onboarding {
                        ModelOnboardingView(model: onboarding, onFinished: { _ in self.onboarding = nil }, onDismiss: { self.onboarding = nil })
                    }
                }
                Divider()
                section("2 · A model you chose — you decide when to update") {
                    ModelUpdateView(model: userChosen)
                }
                Divider()
                section("3 · A built-in model — the developer's offer") {
                    Text("Pause point: \(pauseNote)").font(.caption).foregroundStyle(.secondary)
                    ModelUpdateView(model: builtIn)
                        .task {
                            builtIn.pauseInference = {
                                await MainActor.run { pauseNote = "waiting for in-flight requests to finish…" }
                                try await Task.sleep(for: .milliseconds(900))
                                await MainActor.run { pauseNote = "quiet — switching" }
                            }
                        }
                }
                Divider()
                section("4 · Something that can't be updated here") {
                    ModelUpdateView(model: ModelUpdateModel(
                        actions: simulatedActions(SimulatedModel()),
                        ownership: .fixed(reason: "Shipped with this app. It changes only with a new app version.")))
                }
                Divider()
                section("5 · Cleaning up old versions") {
                    ModelVersionsView(model: versions)
                }
            }
            .padding(24)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}
