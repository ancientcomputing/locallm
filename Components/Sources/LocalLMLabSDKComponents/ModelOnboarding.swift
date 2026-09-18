import LocalLMLabSDKCore
import Observation
import SwiftUI

// Onboarding a model: Validate -> Download -> Pin, one block per repo. Built on Core's
// `DownloadableModelProvider` only (`validate`, `download`, `InstalledModel.resolvedRevision`) —
// no Inference dependency — so it works with the published Core.
//
// Why a stepper and not just a progress bar: a host that lets people pick a model needs each step's
// outcome to be *visible* — "failed at .trustPolicy" or "resolved a commit that isn't the one this app
// ships" is the difference between a working flow and a mysterious spinner. The steps mirror the SDK's
// supply-chain flow (docs/mlx-security.md): a preflight (architecture, trust policy, size, quota), a
// content-verified download, and the resolved commit checked against the pin the host ships.

/// One repo to onboard.
public struct ModelOnboardingRequest: Sendable, Equatable, Identifiable {
    public var id: String { repoID }
    /// What this repo is in the flow — "Model", "Base model", "Speed helper model", "Adapter"…
    public var role: String
    public var repoID: String
    /// The commit the host ships or vouches for. When set, the Pin step **verifies** the download
    /// resolved to exactly this commit and fails if not. When `nil` the Pin step just reports the
    /// commit that was resolved (the host may be recording it as a pin for later).
    public var expectedRevision: String?
    /// `false` for a repo that isn't a model — an adapter, say, which has no model `config.json` for the
    /// architecture check to read. The Validate step then reads "not applicable".
    public var validates: Bool

    public init(role: String = "Model", repoID: String, expectedRevision: String? = nil, validates: Bool = true) {
        self.role = role
        self.repoID = repoID
        self.expectedRevision = expectedRevision
        self.validates = validates
    }
}

/// Where the onboarding flow gets its work done. Built from a provider or from `lab.models`; a host (or a
/// test) can supply its own closures.
public struct ModelOnboardingSource: Sendable {
    /// Returns the preflight result, or `nil` if this source cannot validate (the step reads "not checked").
    public var validate: @Sendable (String) async throws -> PreflightResult?
    public var download: @Sendable (String, @escaping @Sendable (DownloadProgress) -> Void) async throws -> InstalledModel
    public var cancel: @Sendable (String) -> Void

    public init(
        validate: @escaping @Sendable (String) async throws -> PreflightResult?,
        download: @escaping @Sendable (String, @escaping @Sendable (DownloadProgress) -> Void) async throws -> InstalledModel,
        cancel: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.validate = validate
        self.download = download
        self.cancel = cancel
    }

    /// Straight from a provider: its own `validate(_:)` and `download(_:)` stream.
    public init(provider: any DownloadableModelProvider) {
        self.init(
            validate: { try await provider.validate($0) },
            download: { repoID, report in
                for try await event in provider.download(repoID) {
                    switch event {
                    case .progress(let received, let total, let fraction):
                        report(DownloadProgress(bytesReceived: received, totalBytes: total, fraction: fraction))
                    case .completed(let model):
                        return model
                    @unknown default:
                        break
                    }
                }
                throw ModelRegistryError.noDownloadableProvider  // stream ended without .completed (the R9 contract forbids it)
            },
            cancel: { provider.cancelDownload($0) })
    }

    /// Through the registry: validates with its first downloadable provider, then downloads via
    /// `registry.startDownload`, so `registry.downloads` (which other views observe) keeps updating.
    @MainActor
    public init(registry: ModelRegistry) {
        self.init(
            validate: { repoID in try await MainActor.run { registry.downloadableProviders.first }?.validate(repoID) },
            download: { repoID, report in
                // `startDownload` reports through `registry.downloads`, not a callback: sample it while it runs.
                let sampler = Task { @MainActor in
                    while !Task.isCancelled {
                        if let progress = registry.downloads.first(where: { $0.key.rest == repoID })?.value { report(progress) }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                defer { sampler.cancel() }
                return try await registry.startDownload(repoID)
            },
            cancel: { repoID in Task { @MainActor in registry.cancelDownload(repoID) } })
    }
}

/// The state of one step.
public enum ModelOnboardingStepState: Sendable, Equatable {
    case pending
    case running
    case done(String)
    case failed(String)
}

/// One repo's progress through the flow.
public struct ModelOnboardingItem: Sendable, Equatable, Identifiable {
    public var id: String { request.repoID }
    public var request: ModelOnboardingRequest
    public var validate: ModelOnboardingStepState = .pending
    public var download: ModelOnboardingStepState = .pending
    public var pin: ModelOnboardingStepState = .pending
    /// 0...1 while downloading, `nil` otherwise.
    public var downloadFraction: Double?
    public var downloadedBytes: Int64 = 0
    public var totalBytes: Int64 = 0

    public var hasFailed: Bool { [validate, download, pin].contains { if case .failed = $0 { true } else { false } } }
    public var isComplete: Bool { if case .done = pin { true } else { false } }
}

/// Runs the flow, in order, one repo at a time: a failure stops everything after it and leaves the rest
/// `pending`, so nothing later is downloaded on the strength of an earlier failure.
@MainActor
@Observable
public final class ModelOnboardingModel {
    public private(set) var items: [ModelOnboardingItem]
    public private(set) var isRunning = false
    /// The models that completed all three steps, in request order — what the host uses on `Done`.
    public private(set) var completed: [InstalledModel] = []

    private let source: ModelOnboardingSource
    private var task: Task<Void, Never>?

    public init(requests: [ModelOnboardingRequest], source: ModelOnboardingSource) {
        self.items = requests.map { ModelOnboardingItem(request: $0) }
        self.source = source
    }

    public var hasFailed: Bool { items.contains { $0.hasFailed } }
    public var isFinished: Bool { !isRunning && !items.isEmpty && items.allSatisfy(\.isComplete) }
    public var hasStarted: Bool { items.contains { $0.validate != .pending } }

    /// Begins the flow. No effect while one is running.
    public func start() {
        guard !isRunning else { return }
        reset()
        isRunning = true
        task = Task { await run(); isRunning = false; task = nil }
    }

    /// Stops the flow. The download in flight is cancelled at the source; the item shows it as cancelled.
    public func cancel() {
        guard isRunning else { return }
        if let active = items.first(where: { $0.download == .running }) { source.cancel(active.request.repoID) }
        task?.cancel()
    }

    /// Back to the start — for "Try again" after a failure or a cancel.
    public func reset() {
        guard !isRunning else { return }
        items = items.map { ModelOnboardingItem(request: $0.request) }
        completed = []
    }

    private func update(_ index: Int, _ change: (inout ModelOnboardingItem) -> Void) { change(&items[index]) }

    private static func message(for error: Error) -> String {
        (error as? LocalLMLabError)?.errorDescription ?? error.localizedDescription
    }

    private func run() async {
        for index in items.indices {
            let request = items[index].request

            // 1. Validate
            if !request.validates {
                update(index) { $0.validate = .done("not applicable to this kind of repo") }
            } else {
                update(index) { $0.validate = .running }
                do {
                    if let result = try await source.validate(request.repoID) {
                        if let stage = result.failedStage {
                            update(index) { $0.validate = .failed("failed at .\(stage.rawValue) — \(result.detail ?? "")") }
                            return
                        }
                        update(index) { $0.validate = .done(result.detail ?? "passed") }
                    } else {
                        update(index) { $0.validate = .done("not checked") }
                    }
                } catch {
                    update(index) { $0.validate = .failed(Self.message(for: error)) }
                    return
                }
            }
            if Task.isCancelled { update(index) { $0.download = .failed("cancelled") }; return }

            // 2. Download
            update(index) { $0.download = .running; $0.downloadFraction = 0 }
            let installed: InstalledModel
            do {
                installed = try await source.download(request.repoID) { [weak self] progress in
                    Task { @MainActor in
                        self?.update(index) {
                            $0.downloadFraction = progress.fraction
                            $0.downloadedBytes = progress.bytesReceived
                            $0.totalBytes = progress.totalBytes
                        }
                    }
                }
            } catch is CancellationError {
                update(index) { $0.downloadFraction = nil; $0.download = .failed("cancelled") }
                return
            } catch {
                update(index) { $0.downloadFraction = nil; $0.download = .failed(Self.message(for: error)) }
                return
            }
            update(index) { $0.downloadFraction = nil; $0.download = .done("downloaded and verified") }

            // 3. Pin — the resolved commit, verified against the pin the host ships when it gave one.
            update(index) { $0.pin = .running }
            let short = String(installed.resolvedRevision.prefix(12))
            if let expected = request.expectedRevision {
                guard installed.resolvedRevision == expected else {
                    update(index) { $0.pin = .failed("resolved \(short)… but this app expects \(String(expected.prefix(12)))…") }
                    return
                }
                update(index) { $0.pin = .done("verified against the pin this app ships (\(short)…)") }
            } else {
                update(index) { $0.pin = .done("resolved to \(short)…") }
            }
            completed.append(installed)
        }
    }
}

/// The stepper. Bind it to a `ModelOnboardingModel`; it shows one block per repo and the controls that
/// make sense for the state (Start, Cancel, Try again, Done).
@available(macOS 26.0, *)
public struct ModelOnboardingView: View {
    private let model: ModelOnboardingModel
    private let showsDownloadProgress: Bool
    private let onFinished: (([InstalledModel]) -> Void)?
    private let onDismiss: (() -> Void)?

    /// - Parameters:
    ///   - showsDownloadProgress: `false` when another view already shows the download's progress
    ///     (as `ModelPickerView` does), so it isn't drawn twice.
    ///   - onFinished: called with the completed models when the user presses Done.
    ///   - onDismiss: when set, a **Dismiss** button is offered after a failure so the host can clear the
    ///     flow and return to its resting state.
    public init(
        model: ModelOnboardingModel, showsDownloadProgress: Bool = true,
        onFinished: (([InstalledModel]) -> Void)? = nil, onDismiss: (() -> Void)? = nil
    ) {
        self.model = model
        self.showsDownloadProgress = showsDownloadProgress
        self.onFinished = onFinished
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.hasStarted {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.request.role).font(.caption).foregroundStyle(.secondary)
                                Text(item.request.repoID).font(.system(.callout, design: .monospaced))
                            }
                            stepRow("Validate", detail: "architecture, trust policy, reachability, cache quota", item.validate)
                            stepRow("Download", detail: "content-hash verified", item.download)
                            if showsDownloadProgress, let fraction = item.downloadFraction {
                                ProgressView(value: fraction) {
                                    Text("downloading… \(Int(fraction * 100))%").font(.caption)
                                }
                                .frame(maxWidth: 280)
                            }
                            stepRow("Pin", detail: "the resolved commit, checked against the pin this app ships", item.pin)
                        }
                        if item.id != model.items.last?.id { Divider() }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            controls
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if model.isRunning {
                Button("Cancel") { model.cancel() }
            } else if model.isFinished {
                Button("Done") { onFinished?(model.completed) }
                    .keyboardShortcut(.defaultAction)
            } else if model.hasFailed {
                Button("Try again") { model.start() }
                if let onDismiss { Button("Dismiss") { onDismiss() } }
            } else {
                Button("Start") { model.start() }
                    .keyboardShortcut(.defaultAction)
            }
            if model.isRunning { ProgressView().controlSize(.small) }
        }
    }

    private func stepRow(_ title: String, detail: String, _ state: ModelOnboardingStepState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch state {
            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                switch state {
                case .done(let text): Text(text).font(.caption).foregroundStyle(.secondary)
                case .failed(let text):
                    Text(text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                default: Text(detail).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
