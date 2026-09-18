// MLX Control Room — a live panel of the knobs `SessionOptions` / `MLXModelProvider` expose over an
// MLX-backed session, and gauges that prove each knob actually reaches `mlx-swift-lm` rather than being
// silently ignored.
//
// What the app does, in the order you meet it:
//   - MODEL SELECTION comes first, on a launch screen: a recommended model shipped pinned at a fixed commit,
//     a second built-in model the developer can move to a newer version without a new app release, your own
//     free-text repo id, or a curated *pair* (a speed-helper pair or an adapter pair). Every choice runs
//     validate -> download -> pin, per model, before the knobs unlock.
//   - KNOBS actually change what the next turn does: `effort`, `temperature`/`topP`/`maxOutputTokens`/
//     `seed`, `topK`/`minP`/`repetitionPenalty`/`repetitionContextSize`, and `prefillStepSize` all ride
//     `SessionOptions` into a real `GenerateParameters`. Drag temperature to the floor and the output should
//     stop varying between runs; crank repetitionPenalty up on a prompt that loops and the repeat-rate gauge
//     should visibly drop.
//   - PAIRINGS are provider-level, set with `pairDraftModel(_:with:)` / `pairAdapter(_:with:)` and re-applied
//     on every Run, so toggling one takes effect on the next generation with no restart — a live on/off
//     comparison of a speed helper (tokens/sec) or a specialization adapter (the reply's style).
//   - PINS: a model you choose is pinned to the version you first downloaded; a built-in one is pinned by the
//     app. The Model & pin panel checks for and applies updates, rolls back, and lists old versions on disk
//     with what removing each would free.
//   - ROADMAP: the KV-cache knobs don't exist on `SessionOptions` yet and are shown disabled.
//
// The gauges are the actual point: a knob only counts as "exposed" once something here reacts to it.
// tokens/sec and the repeat-rate meter are real signals off the live stream; the determinism light is a real
// seed check (same prompt + same seed, twice, byte-identical output); time-to-first-token is what
// `prefillStepSize` is supposed to move on a long prompt; the residency log comes straight from
// `MLXModelProvider.residencyEventStream`.

import Foundation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKInference
import SwiftUI

let controlRoomModelRepo = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

/// A model the "host developer" ships pinned at build time. In a real app this is a
/// compile-time constant chosen at curation time (does the fork support the architecture; does
/// it pass our own trust check); here it's the default model at the commit `main` resolved to
/// on 2026-09-18. Shipped pins live in code, never in the pin store, and always beat a captured
/// (captured) pin for the same repo.
struct ShippedModel {
    let repoID: String
    let revision: String
}

let shippedModel = ShippedModel(
    repoID: controlRoomModelRepo, revision: "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3")

/// A second built-in model, shipped pinned at the version **this build** of the app was released with
/// — deliberately *not* the newest: its developer has since reviewed a newer commit and offers it
/// through an update feed (below), so the app can move to it **without a new app release**
/// (host-managed pin updates). `gemma-3-270m-it-4bit`'s last two
/// commits differ only in `config.json` (1648 -> 1653 bytes).
let smallModel = ShippedModel(
    repoID: "mlx-community/gemma-3-270m-it-4bit", revision: "9eba008f65cdc8aee60201be10dcd0e7858455ce")

/// What a *later* build of the app would ship for `smallModel` — used by "Simulate a newer app build".
let smallModelNextBuildRevision = "ff1143e3a10547c9f2129e94ca37059b096b23f4"

/// Stand-in for the **developer's update feed**: which commit of each built-in model the developer has
/// reviewed and vouches for. In a real app this is an authenticated request to the developer's server
/// (or an MDM push); the SDK has no feed and takes no view on where the commit comes from — the host
/// names an explicit commit hash, and *authenticating that answer is the host's job*. It is never
/// "latest main": an unreviewed version must not replace the vetted one.
enum HostUpdateFeed {
    static let vouchedCommits: [String: String] = [
        smallModel.repoID: "ff1143e3a10547c9f2129e94ca37059b096b23f4",
    ]

    static func latest() async throws -> [String: String] {
        try await Task.sleep(for: .milliseconds(400))   // "the network"
        return vouchedCommits
    }
}

/// A curated pairing: a base model plus one companion — a
/// draft model for speculative decoding, or a LoRA adapter — every artifact shipped pinned like
/// `shippedModel`. Pairs are curated, not free-text: a draft must be a same-family sibling of
/// its base, and an adapter must match the architecture (and quantization) it was trained
/// against, so a free-text picker would mostly build broken pairs.
struct PairingPreset: Identifiable {
    enum Kind {
        case speedHelper(numDraftTokens: Int)
        case adapter
    }

    let id: String
    let title: String
    let summary: String
    let expectation: String
    let kind: Kind
    let base: ShippedModel
    let companionRole: String
    let companion: ShippedModel
    let suggestedPrompt: String
}

/// Pins resolved on 2026-09-18. Both pairs were run end to end; see the speed-helper sweep in
/// the README for where `numDraftTokens: 2` comes from (the SDK default of 5 was slower).
let pairingPresets: [PairingPreset] = [
    PairingPreset(
        id: "speed",
        title: "Speed pair",
        summary: "A small helper model drafts a couple of words ahead and the larger model checks them. The output is the same; it arrives sooner.",
        expectation: "In our runs: about 30–40% faster once warm (e.g. 24.6 → 31.5 words/sec; one prompt, one machine, greedy). The first run with the helper on is slower — it loads the helper — so run twice.",
        kind: .speedHelper(numDraftTokens: 2),
        base: ShippedModel(
            repoID: "mlx-community/Qwen3-4B-4bit", revision: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25"),
        companionRole: "Speed helper model",
        companion: ShippedModel(
            repoID: "mlx-community/Qwen3-0.6B-4bit", revision: "73e3e38d981303bc594367cd910ea6eb48349da8"),
        suggestedPrompt: "Explain, in three sentences, why the sky is blue."),
    PairingPreset(
        id: "adapter",
        title: "Adapter pair",
        summary: "A small add-on file (a LoRA adapter) changes how the model writes — here, it makes it write haiku.",
        expectation: "Run the same prompt with the adapter off, then on. In our runs the plain model gives a factual bullet-point overview, while the adapted one writes a short, haiku-style verse instead (not always a strict 5-7-5).",
        kind: .adapter,
        base: ShippedModel(
            repoID: "mlx-community/Qwen3-0.6B-bf16", revision: "42096995f6402fde107068cf530136fe64b604f8"),
        companionRole: "Specialization adapter",
        companion: ShippedModel(
            repoID: "stbenjam/qwen3-0.6b-haiku-mlx-lora", revision: "5cba6c46d07f4d56248f1d6078799080562bf1f0"),
        suggestedPrompt: "Write about the changing seasons."),
]

// MARK: - View model

@available(macOS 27.0, *)
@MainActor
final class ControlRoomModel: ObservableObject {
    enum State: Equatable {
        case idle
        case working
        case ready
        case failed(String)
    }

    // Knobs that are actually live on `SessionOptions` today.
    @Published var temperature: Double = 0.8
    @Published var topP: Double = 0.95
    /// Typed, not slid: a token cap has no natural upper bound (it's the model's context window),
    /// so a slider range would be arbitrary. Kept as text so partial input ("", "1") is legal
    /// while editing; `maxOutputTokens` is the validated value, `nil` while the text is invalid.
    @Published var maxOutputTokensText = "1024"
    static let maxOutputTokensLimits = 1...1_000_000

    var maxOutputTokens: Int? {
        guard let value = Int(maxOutputTokensText), Self.maxOutputTokensLimits.contains(value) else { return nil }
        return value
    }
    @Published var suppressThinking = false
    @Published var useFixedSeed = false
    @Published var seed: Double = 42
    @Published var topK: Double = 0        // 0 = disabled, matches GenerateParameters' own default
    @Published var minP: Double = 0        // 0 = disabled
    @Published var useRepetitionPenalty = false
    @Published var repetitionPenalty: Double = 1.3
    @Published var repetitionContextSize: Double = 20
    @Published var usePrefillStepSize = false
    @Published var prefillStepSize: Double = 512   // mlx-swift-lm's own default for most models

    @Published private(set) var state: State = .idle
    @Published private(set) var residencyLog: [String] = []
    @Published private(set) var lastOutput: String = ""
    @Published private(set) var tokensPerSecond: Double?
    @Published private(set) var repeatRate: Double?
    /// Time to first streamed chunk, in milliseconds — the observable `prefillStepSize`
    /// is supposed to move on a long prompt.
    @Published private(set) var timeToFirstTokenMS: Double?
    /// Set only once two consecutive runs share the same prompt + fixed seed — `true` when
    /// their output was byte-identical, `false` if it wasn't (a real finding, not a bug), `nil`
    /// before there's anything to compare.
    @Published private(set) var deterministic: Bool?

    private var previousRun: (prompt: String, seed: UInt64, output: String)?

    // Created by onboarding (see "Model selection & onboarding") once a model has been
    // validated, downloaded and pinned — nil until then.
    private var mlx: MLXModelProvider?
    private var lab: LocalLMLab?
    private var residencyTask: Task<Void, Never>?

    deinit { residencyTask?.cancel() }

    private func log(_ event: ResidencyEvent) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        switch event {
        case .warmed(let id):
            residencyLog.append("\(stamp)  ⬤ warmed  \(id)")
        case .evicted(let id, let reason):
            residencyLog.append("\(stamp)  ○ evicted \(id) (\(reason))")
        case .loadProgress(let id, let fraction):
            residencyLog.append("\(stamp)  ↻ load \(id) \(Int(fraction * 100))%")
        @unknown default:
            residencyLog.append("\(stamp)  ? unrecognized residency event")
        }
    }

    var options: SessionOptions {
        SessionOptions(
            effort: suppressThinking ? .off : nil,
            temperature: temperature,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            seed: useFixedSeed ? UInt64(seed) : nil,
            topK: topK > 0 ? Int(topK) : nil,
            minP: minP > 0 ? minP : nil,
            repetitionPenalty: useRepetitionPenalty ? repetitionPenalty : nil,
            repetitionContextSize: useRepetitionPenalty ? Int(repetitionContextSize) : nil,
            prefillStepSize: usePrefillStepSize ? Int(prefillStepSize) : nil)
    }

    func submit(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxOutputTokens != nil, !inferencePaused else { return }
        switch state {
        case .working: return
        default: break
        }
        Task { await run(trimmed) }
    }

    private func run(_ prompt: String) async {
        guard let lab else { return }
        applyPairing()
        let pairedThisRun = pairingEnabled
        state = .working
        do {
            let currentOptions = options
            let session = try lab.makeSession(route: .local, options: currentOptions)
            let start = Date()
            var firstChunkAt: Date?
            var wordCount = 0
            for try await partial in session.languageModelSession.streamResponse(to: prompt) {
                if firstChunkAt == nil, !partial.content.isEmpty { firstChunkAt = Date() }
                lastOutput = partial.content
                wordCount = partial.content.split(separator: " ").count
            }
            let elapsed = Date().timeIntervalSince(start)
            tokensPerSecond = elapsed > 0 ? Double(wordCount) / elapsed : nil
            if activePreset != nil, let rate = tokensPerSecond {
                if pairedThisRun { lastRateWithPairing = rate } else { lastRateWithoutPairing = rate }
            }
            repeatRate = Self.trigramRepeatRate(lastOutput)
            timeToFirstTokenMS = firstChunkAt.map { $0.timeIntervalSince(start) * 1000 }

            if let fixedSeed = currentOptions.seed {
                if let previous = previousRun, previous.prompt == prompt, previous.seed == fixedSeed {
                    deterministic = previous.output == lastOutput
                } else {
                    deterministic = nil
                }
                previousRun = (prompt: prompt, seed: fixedSeed, output: lastOutput)
            } else {
                previousRun = nil
                deterministic = nil
            }
            state = .ready
        } catch {
            state = .failed("Generation failed: \(error.localizedDescription)")
        }
    }

    /// Fraction of word-trigrams in `text` that are repeats of an earlier trigram — a cheap,
    /// visible proxy for "is the model looping". Should trend down as `repetitionPenalty` goes
    /// up. Splits on any non-letter/non-number boundary, not just spaces — a model looping via
    /// "go/go/go/…" or "go-go-go…" has no spaces at all, and a literal `split(separator: " ")`
    /// would see that as a single giant "word" and silently never engage (found live,
    /// the first version of this function reported 0% on exactly
    /// that output).
    static func trigramRepeatRate(_ text: String) -> Double? {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count >= 3 else { return nil }
        var seen = Set<String>()
        var repeats = 0
        var total = 0
        for i in 0...(words.count - 3) {
            let trigram = words[i...(i + 2)].joined(separator: " ")
            total += 1
            if !seen.insert(trigram).inserted { repeats += 1 }
        }
        return total > 0 ? Double(repeats) / Double(total) : nil
    }

    // MARK: - Model selection & onboarding
    //
    // The app opens on a launch screen with three ways in, all running the same
    // validate -> download -> pin flow per artifact before the control room unlocks:
    //
    //   - Recommended model (a shipped pin): shipped pinned at build time; the pin step ASSERTS the
    //     resolved commit equals the shipped one.
    //   - Your own model (a captured pin): free-text repo id; the pin step CAPTURES the resolved
    //     commit into the SDK's `MLXFilePinStore` (outside the HF cache, which `remove(_:)` wipes).
    //   - Model pairing: a curated pair (`PairingPreset`), every artifact shipped pinned. Each
    //     artifact is validated (except an adapter repo, which has no model `config.json`),
    //     downloaded under the trust policy / cache cap / hash verification, and pin-checked.
    //     At run time the SDK's executor-side fetches go through the same policy
    //     (the SDK governs the adapter/draft fetches the same way it governs `download`).
    //
    // Shipped pins beat captured ones for the same repo, keyed by repo id.

    /// One row of the onboarding stepper.
    enum Step: Equatable {
        case pending
        case running
        case done(String)
        case failed(String)
    }

    enum Phase: Equatable { case choosing, ready }
    enum LaunchMode { case card, ownModel, pairing }

    /// Where the pin that guarded the active model came from — shown in the control room.
    enum PinSource: Equatable { case shipped, captured, reused }

    /// What OK / "Use this model" / "Use this pair" asks the launch flow to prepare.
    enum Launch {
        case single(String)
        case pairing(PairingPreset)

        var baseRepo: String {
            switch self {
            case .single(let repo): repo
            case .pairing(let preset): preset.base.repoID
            }
        }

        var artifacts: [ArtifactPrep] {
            switch self {
            case .single(let repo):
                [ArtifactPrep(role: "Model", repoID: repo, isAdapter: false)]
            case .pairing(let preset):
                [
                    ArtifactPrep(role: "Base model", repoID: preset.base.repoID, isAdapter: false),
                    ArtifactPrep(
                        role: preset.companionRole, repoID: preset.companion.repoID,
                        isAdapter: { if case .adapter = preset.kind { true } else { false } }()),
                ]
            }
        }
    }

    /// Stepper state for one repo in a launch.
    struct ArtifactPrep: Identifiable, Equatable {
        var id: String { repoID }
        let role: String
        let repoID: String
        let isAdapter: Bool
        var validate: Step = .pending
        var download: Step = .pending
        var pin: Step = .pending
        var progress: Double?

        var isRunning: Bool { [validate, download, pin].contains(.running) }
        var hasFailed: Bool {
            [validate, download, pin].contains { if case .failed = $0 { true } else { false } }
        }
    }

    struct ActivePin: Identifiable {
        var id: String { repo }
        let repo: String
        let revision: String
    }

    private struct PendingActivation {
        let provider: MLXModelProvider
        let launch: Launch
        let pins: [ActivePin]
        let source: PinSource
    }

    /// Captured pins live in the SDK's `MLXFilePinStore` — a JSON file in Application
    /// Support, outside the Hugging Face cache (whose `remove(_:)` wipes a repo's whole directory,
    /// `refs/` included). The provider reads it at download time and captures into it on first
    /// sight; this app does none of that by hand.
    private let pinStore = MLXFilePinStore()
    /// Runtime advances of *shipped* pins (an update from the developer's feed) live here, each saved with
    /// the build-time pin it was made against — so an update survives a relaunch, but a newer app build
    /// (a different build-time pin) discards it and the developer's newer choice wins.
    private let managedPinStore = MLXFileManagedPinStore()
    /// Advanced: pretend this is a *newer build* of the app, which ships the newer Gemma version as its
    /// build-time pin — to watch a runtime update be superseded by the release.
    @Published var simulateNewerAppBuild = false
    /// The update from the developer's feed that is saved for the built-in small model, if any — what
    /// "simulate a newer app build" would discard. Read from the saved file each time.
    var savedFeedUpdate: MLXPinOverride? { managedPinStore.override(for: smallModel.repoID) }
    @Published private(set) var capturedPins: [ActivePin] = []
    var pinFilePath: String { pinStore.fileURL.path }

    init() { refreshCapturedPins() }

    private func refreshCapturedPins() {
        capturedPins = pinStore.allPins.sorted { $0.key < $1.key }.map { ActivePin(repo: $0.key, revision: $0.value) }
    }

    // MARK: Pin update

    /// A repo with an older, complete commit and a newer one that differ in one small file, so a user's
    /// **Check for update** has something real to find: `mlx-community/gemma-3-270m-4bit`, whose last
    /// two commits differ only in `README.md` (803 -> 817 bytes). It must NOT be one of the app's shipped
    /// models: a shipped pin always beats a captured one, so the demo's older pin would be ignored and
    /// the pin couldn't be updated by the user. (An earlier demo used Qwen3-0.6B-4bit — the Speed pair's
    /// draft model — and hit exactly that, and `gemma-3-270m-it-4bit` is now the built-in small model.)
    static let demoUpdateRepo = "mlx-community/gemma-3-270m-4bit"
    static let demoOlderCommit = "9440bb075c5439cb4774c48c8d8019b45c4c5fce"
    static let demoNewerCommit = "6d7c2cd12b03111095d38c8fb81a72b0596fe5e2"

    enum PinUpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(MLXPinUpdateCheck)
        case updating(Double)
        case failed(String)
    }

    @Published private(set) var pinUpdate: PinUpdateState = .idle
    /// True from the moment an update has been downloaded and verified until it has switched: new
    /// runs are refused and a running one is waited for, so no session can load half of a model from
    /// the old version and half from the new one (the SDK's `beforeSwitch` contract).
    @Published private(set) var inferencePaused = false

    /// The `beforeSwitch` hook: the SDK has downloaded and verified the new version and is about to
    /// move the pin. Stop new runs, let the one in flight finish, then return.
    private func pauseInferenceForSwitch() async throws {
        inferencePaused = true
        onboardingLogLine("update downloaded and verified — pausing inference to switch")
        while state == .working { try await Task.sleep(for: .milliseconds(100)) }
    }
    /// The commit the repo was on before the last update — what **Roll back** returns to. The old
    /// snapshot is still in the Hugging Face cache, so rolling back needs no download.
    @Published private(set) var rollbackRevision: String?

    /// Which kind of pin the active single model is on, if it can be updated here at all:
    /// - `.captured` — the user's own choice; the user decides, and the target is whatever `main` is now;
    /// - `.shipped` — a built-in model **the developer's feed vouches for**: the target is the commit
    ///   the feed names, never `main`. A shipped model the feed doesn't mention can't be updated here
    ///   (the recommended model and both pairs: a new app version moves them).
    var updatablePinSource: MLXPinSource? {
        guard case .single(let repo) = activeLaunch, let pin = mlx?.effectivePin(for: repo) else { return nil }
        switch pin.source {
        case .captured: return .captured
        case .shipped: return HostUpdateFeed.vouchedCommits[repo] != nil ? .shipped : nil
        @unknown default: return nil
        }
    }

    var pinUpdatable: Bool { updatablePinSource != nil }

    /// A built-in model the developer's feed has already moved past what this build shipped.
    var activeIsRuntimeOverride: Bool {
        guard case .single(let repo) = activeLaunch else { return false }
        return mlx?.effectivePin(for: repo)?.isRuntimeOverride ?? false
    }

    /// What this app build shipped for the active model — the "back to the version this app shipped" target.
    var activeBuildTimeRevision: String? {
        guard case .single(let repo) = activeLaunch else { return nil }
        return mlx?.buildTimePin(for: repo)
    }

    var isPinUpdateBusy: Bool {
        switch pinUpdate {
        case .checking, .updating: true
        default: false
        }
    }

    func checkForPinUpdate() {
        guard pinUpdatable, !isPinUpdateBusy, let mlx, case .single(let repo) = activeLaunch else { return }
        pinUpdate = .checking
        let source = updatablePinSource
        Task {
            do {
                // A shipped model is only ever checked against a commit the developer's feed names —
                // the user's click triggers the check, the developer vouches for the version.
                let target: String? = source == .shipped ? try await HostUpdateFeed.latest()[repo] : nil
                let check = try await mlx.checkPinUpdate(repo, to: target)
                pinUpdate = check.isUpToDate ? .upToDate : .available(check)
                onboardingLogLine("update check \(repo): " + (check.isUpToDate ? "up to date" : "\(check.changes.count) file(s) differ"))
            } catch {
                pinUpdate = .failed(error.localizedDescription)
            }
        }
    }

    /// Moves the pin to `revision` (the checked-for latest, or the rollback target).
    private func movePin(to revision: String?, previous: String) {
        guard pinUpdatable, !isPinUpdateBusy, let mlx, case .single(let repo) = activeLaunch else { return }
        pinUpdate = .updating(0)
        Task {
            defer { inferencePaused = false }
            do {
                for try await event in mlx.updatePin(repo, to: revision, beforeSwitch: {
                    // Strong on purpose: this runs inside the update's own Task, which already holds the
                    // model, and the update is short-lived.
                    try await self.pauseInferenceForSwitch()
                }) {
                    switch event {
                    case .progress(_, _, let fraction): pinUpdate = .updating(fraction)
                    case .completed(let model):
                        activePins = [ActivePin(repo: repo, revision: model.resolvedRevision)]
                        rollbackRevision = model.resolvedRevision == previous ? nil : previous
                        onboardingLogLine("pin for \(repo): \(previous.prefix(12))… → \(model.resolvedRevision.prefix(12))…")
                    @unknown default: break
                    }
                }
                refreshCapturedPins()
                refreshSnapshots()
                pinUpdate = .upToDate
            } catch {
                // Atomic: a failed update left the old pin and the old files exactly as they were.
                pinUpdate = .failed("\(error.localizedDescription) — still pinned to \(previous.prefix(12))…")
            }
        }
    }

    func applyPinUpdate() {
        guard case .available(let check) = pinUpdate else { return }
        movePin(to: check.latestRevision, previous: check.pinnedRevision)
    }

    /// "Back to the version this app shipped" — a built-in model the feed had advanced.
    func revertToShippedVersion() {
        guard let buildTime = activeBuildTimeRevision, let current = activePins.first?.revision else { return }
        movePin(to: buildTime, previous: current)
    }

    func rollBackPin() {
        guard let rollbackRevision, let current = activePins.first?.revision else { return }
        movePin(to: rollbackRevision, previous: current)
    }

    // MARK: Old versions on disk (the SDK's snapshot inventory + guarded removal)

    /// Every cached version of the active model(s), current one included. The **host** decides when to
    /// clean up; the SDK only lists them honestly and removes one safely (never the current version, and
    /// only the files no other version uses).
    @Published private(set) var snapshots: [MLXCachedSnapshot] = []

    private var activeRepos: [String] {
        switch activeLaunch {
        case .single(let repo)?: [repo]
        case .pairing(let preset)?: [preset.base.repoID, preset.companion.repoID]
        case nil: []
        }
    }

    func refreshSnapshots() {
        guard let mlx else { snapshots = []; return }
        snapshots = activeRepos.flatMap { mlx.snapshots(for: $0) }
    }

    func removeSnapshot(_ snapshot: MLXCachedSnapshot) {
        guard let mlx else { return }
        do {
            let freed = try mlx.removeSnapshot(snapshot.repoID, revision: snapshot.revision)
            onboardingLogLine("removed \(snapshot.repoID)@\(snapshot.revision.prefix(12))… — freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))")
        } catch {
            onboardingLogLine("could not remove that version: \(error.localizedDescription)")
        }
        refreshSnapshots()
    }

    /// Demo switch in the "choose your own model" form. In real use a pin goes stale on its own, as the
    /// repo owner publishes new versions — but that takes time, so for a demo this pretends the model
    /// was downloaded a while ago, by recording an *older* commit as the pin before the download.
    /// Offered only for `demoUpdateRepo`. The user still chose the model; only its recorded age is staged.
    @Published var pretendDownloadedEarlier = false

    var offersOlderVersionDemo: Bool {
        modelRepoInput.trimmingCharacters(in: .whitespacesAndNewlines) == Self.demoUpdateRepo
            && !allShipped.contains { $0.repoID == Self.demoUpdateRepo }
    }

    /// Forgets one captured pin. Shipped pins are code and can't be forgotten.
    func forgetPin(for repo: String) {
        pinStore.removePin(for: repo)
        refreshCapturedPins()
        onboardingLogLine("forgot the captured pin for \(repo)")
    }

    /// Toy `MLXModelTrustPolicy`: the free-text picker is limited to
    /// mlx-community/*, plus the exact artifacts this app itself ships (a curated adapter lives
    /// in another namespace — a real host's allow-list would name it too).
    private struct AllowMLXCommunityOrShipped: MLXModelTrustPolicy {
        let shippedRepoIDs: Set<String>
        func evaluate(repoID: String) async -> MLXModelTrustDecision {
            repoID.hasPrefix("mlx-community/") || shippedRepoIDs.contains(repoID)
                ? .allow
                : .deny(reason: "this demo only allow-lists mlx-community/* and this app's shipped artifacts — try a different namespace to see it denied")
        }
    }

    @Published var modelRepoInput = controlRoomModelRepo
    @Published var launchMode: LaunchMode = .card
    /// The other two `MLXSupplyChainPolicy` knobs (hash verification, cache cap), under "Advanced" on the picker.
    @Published var verificationEnabled = true
    @Published var cacheCapEnabled = false
    @Published var cacheCapMB: Double = 500
    /// Advanced: swap the shipped SHA of the launched model (or, for a pair, its companion) for
    /// a bogus one to watch a shipped pin fail hard instead of quietly falling back to `main`.
    @Published var simulateStaleShippedPin = false

    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var preps: [ArtifactPrep] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var activeRepo = controlRoomModelRepo
    @Published private(set) var activePins: [ActivePin] = []
    @Published private(set) var pinSource: PinSource?
    @Published private(set) var onboardingLog: [String] = []
    /// True while "Simulate external deletion" is running its launch flow — it gets its own
    /// screen and waits for an OK before returning to the control room.
    @Published private(set) var isRedownloadFlow = false
    @Published private var pendingActivation: PendingActivation?
    private var activeLaunch: Launch?

    // Pairing mode
    @Published private(set) var activePreset: PairingPreset?
    /// The live A/B switch: re-applied on every Run, so toggling it takes effect on the next
    /// generation with no restart.
    @Published var pairingEnabled = false
    @Published private(set) var lastRateWithoutPairing: Double?
    @Published private(set) var lastRateWithPairing: Double?
    @Published private(set) var suggestedPrompt: String?

    var showsOnboardingSteps: Bool { !preps.isEmpty }
    var onboardingFailed: Bool { preps.contains { $0.hasFailed } }
    /// Set only when the redownload flow has finished successfully and is waiting on OK.
    var awaitingRedownloadAcknowledgement: Bool { pendingActivation != nil }

    /// Clears a failed attempt's stepper (and log) so the picker is back to its resting state.
    func dismissOnboardingFailure() {
        guard !isPreparing else { return }
        preps = []
        onboardingLog.removeAll()
        isRedownloadFlow = false
    }

    /// Every artifact the app ships pinned (the recommended model and all pair members).
    private var allShipped: [ShippedModel] {
        [shippedModel, smallModel] + pairingPresets.flatMap { [$0.base, $0.companion] }
    }

    /// Shipped pins beat captured pins for the same repo. With the
    /// stale-pin toggle on, the launch's target artifact gets a bogus SHA instead.
    private func shippedPins(for launch: Launch) -> [String: String] {
        var pins = Dictionary(allShipped.map { ($0.repoID, $0.revision) }, uniquingKeysWith: { first, _ in first })
        if simulateNewerAppBuild { pins[smallModel.repoID] = smallModelNextBuildRevision }
        if simulateStaleShippedPin {
            switch launch {
            case .single(let repo) where pins[repo] != nil: pins[repo] = String(repeating: "0", count: 40)
            case .single: break
            case .pairing(let preset): pins[preset.companion.repoID] = String(repeating: "0", count: 40)
            }
        }
        return pins
    }

    /// A fresh provider every call, seeded from the persisted pin store exactly as it would be
    /// after an app relaunch. A speed pair keeps base and draft resident together.
    private func makeProvider(for launch: Launch) -> MLXModelProvider {
        var residentLimit = 1
        if case .pairing(let preset) = launch, case .speedHelper = preset.kind { residentLimit = 2 }
        return MLXModelProvider(
            residentModelLimit: residentLimit,
            pinnedRevisions: shippedPins(for: launch),
            supplyChainPolicy: MLXSupplyChainPolicy(
                verification: verificationEnabled ? .enabled : .disabled,
                trustPolicy: AllowMLXCommunityOrShipped(shippedRepoIDs: Set(allShipped.map(\.repoID))),
                cacheLimits: cacheCapEnabled
                    ? MLXCacheLimits(maxTotalCacheBytes: Int64(cacheCapMB * 1_000_000))
                    : .default),
            pinStore: pinStore,
            managedPinStore: managedPinStore)
    }

    private func onboardingLogLine(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        onboardingLog.append("\(stamp)  \(line)")
    }

    /// "Use this model" — a built-in model, shipped pinned.
    func useShippedModel() { launch(.single(shippedModel.repoID)) }
    func useBuiltIn(_ model: ShippedModel) { launch(.single(model.repoID)) }

    /// "Use this pair" — a curated pairing.
    func usePairing(_ preset: PairingPreset) { launch(.pairing(preset)) }

    /// The OK button (a free-text repo) — but any repo with a shipped pin takes the shipped path, since
    /// pins are keyed by repo id.
    func confirmModel() {
        let repo = modelRepoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, !isPreparing else { return }
        if pretendDownloadedEarlier, offersOlderVersionDemo {
            pinStore.setPin(Self.demoOlderCommit, for: repo)
            refreshCapturedPins()
            onboardingLogLine("demo: recorded an older version (\(Self.demoOlderCommit.prefix(12))…) as if downloaded earlier")
        }
        pretendDownloadedEarlier = false
        launch(.single(repo))
    }

    private func launch(_ launch: Launch) {
        guard !isPreparing else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            await prepare(launch)
        }
    }

    private func prepare(_ launch: Launch) async {
        let holdForAcknowledgement = isRedownloadFlow
        preps = launch.artifacts
        let provider = makeProvider(for: launch)
        var pins: [ActivePin] = []
        var source: PinSource = .shipped

        for index in preps.indices {
            let repo = preps[index].repoID
            guard ModelID(scheme: "mlx", rest: repo) != nil else {
                preps[index].validate = .failed("\"\(repo)\" isn't a valid repo id — expected namespace/name")
                return
            }

            // 1. validate — an adapter repo has no model config.json, so the architecture check
            // doesn't apply; the trust policy still runs, at download.
            if preps[index].isAdapter {
                preps[index].validate = .done("adapter repo — no architecture check; trust policy applies at download")
            } else {
                preps[index].validate = .running
                do {
                    let result = try await provider.validate(repo)
                    if let stage = result.failedStage {
                        preps[index].validate = .failed("failed at .\(stage.rawValue) — \(result.detail ?? "")")
                        onboardingLogLine("validate \(repo): failed at .\(stage.rawValue)")
                        return
                    }
                    preps[index].validate = .done(result.detail ?? "passed")
                    onboardingLogLine("validate \(repo): passed")
                } catch {
                    preps[index].validate = .failed(error.localizedDescription)
                    return
                }
            }

            // 2. download (a cache hit completes immediately)
            // Where a pin stands *before* this download: a captured pin means this is a reuse, none
            // means the download itself is about to capture one.
            let priorPin = provider.effectivePin(for: repo)
            preps[index].download = .running
            preps[index].progress = 0
            var revision: String?
            do {
                for try await event in provider.download(repo) {
                    switch event {
                    case .progress(_, _, let fraction):
                        preps[index].progress = fraction
                    case .completed(let model):
                        revision = model.resolvedRevision
                    @unknown default:
                        break
                    }
                }
            } catch {
                preps[index].progress = nil
                preps[index].download = .failed(error.localizedDescription)
                onboardingLogLine("download \(repo) failed: \(error.localizedDescription)")
                return
            }
            preps[index].progress = nil
            guard let revision else {
                preps[index].download = .failed("download finished without a resolved revision")
                return
            }
            preps[index].download = .done("verified" + (verificationEnabled ? "" : " (hash check off)"))

            // 3. pin — the provider applied and (for an unpinned repo) captured it during the
            // download; here we just confirm what landed matches, and say where it came from.
            preps[index].pin = .running
            guard let pin = provider.effectivePin(for: repo) else {
                preps[index].pin = .failed("no pin was recorded for \(repo) — refusing to continue")
                onboardingLogLine("no pin for \(repo) after download")
                return
            }
            guard revision == pin.revision else {
                preps[index].pin = .failed(
                    "resolved \(revision.prefix(12))… but pinned \(pin.revision.prefix(12))…")
                onboardingLogLine("pin mismatch for \(repo) — refusing to continue")
                return
            }
            switch pin.source {
            case .shipped:
                preps[index].pin = .done("verified against shipped pin \(revision.prefix(12))…")
                onboardingLogLine("pinned \(repo)@\(revision.prefix(12))… (shipped pin verified)")
            case .captured:
                let isNew = priorPin == nil
                source = isNew ? .captured : .reused
                preps[index].pin = .done(
                    isNew ? "captured \(revision.prefix(12))… → pin store" : "reused pin \(revision.prefix(12))…")
                onboardingLogLine(
                    "pinned \(repo)@\(revision.prefix(12))… (\(isNew ? "new pin captured" : "existing pin honored"))")
            @unknown default:
                preps[index].pin = .done("pinned at \(revision.prefix(12))…")
            }
            pins.append(ActivePin(repo: repo, revision: revision))
        }

        refreshCapturedPins()
        if holdForAcknowledgement {
            pendingActivation = PendingActivation(provider: provider, launch: launch, pins: pins, source: source)
        } else {
            activate(provider: provider, launch: launch, pins: pins, source: source)
        }
    }

    /// The redownload screen's OK — hand the freshly built provider over and return to the
    /// control room.
    func acknowledgeRedownload() {
        guard let pending = pendingActivation else { return }
        pendingActivation = nil
        isRedownloadFlow = false
        activate(provider: pending.provider, launch: pending.launch, pins: pending.pins, source: pending.source)
    }

    private func activate(provider: MLXModelProvider, launch: Launch, pins: [ActivePin], source: PinSource) {
        guard let id = ModelID(scheme: "mlx", rest: launch.baseRepo) else { return }
        residencyTask?.cancel()
        residencyLog.removeAll()
        resetGauges()
        mlx = provider
        let newLab = LocalLMLab(configuration: .init(providers: [provider]))
        newLab.models.route(.local, to: id)
        lab = newLab
        activeLaunch = launch
        activeRepo = launch.baseRepo
        activePins = pins
        pinSource = source
        let stream = provider.residencyEventStream
        residencyTask = Task { [weak self] in
            guard let stream else { return }
            for await event in stream {
                self?.log(event)
            }
        }
        switch launch {
        case .single:
            activePreset = nil
            suggestedPrompt = nil
        case .pairing(let preset):
            activePreset = preset
            applyPresetDefaults(preset)
        }
        pinUpdate = .idle
        rollbackRevision = nil
        refreshSnapshots()
        pairingEnabled = false
        lastRateWithoutPairing = nil
        lastRateWithPairing = nil
        applyPairing()
        state = .idle
        phase = .ready
    }

    /// Sensible starting knobs per pair — the speed pair was measured greedy with thinking off;
    /// the adapter pair with a short cap (a haiku is short).
    private func applyPresetDefaults(_ preset: PairingPreset) {
        suggestedPrompt = preset.suggestedPrompt
        switch preset.kind {
        case .speedHelper:
            temperature = 0
            suppressThinking = true
            maxOutputTokensText = "200"
        case .adapter:
            // Thinking off: with it on, the plain model spends its whole token budget inside
            // <think> and the off/on comparison looks like a truncated, broken run.
            temperature = 0.8
            suppressThinking = true
            maxOutputTokensText = "120"
        }
    }

    /// Re-applied on every Run — the live on/off switch.
    private func applyPairing() {
        guard let mlx, let preset = activePreset else { return }
        switch preset.kind {
        case .speedHelper(let numDraftTokens):
            mlx.pairDraftModel(
                pairingEnabled
                    ? SpeculativeDecodingSpec(draftRepoID: preset.companion.repoID, numDraftTokens: numDraftTokens)
                    : nil,
                with: preset.base.repoID)
        case .adapter:
            mlx.pairAdapter(
                pairingEnabled ? AdapterSpec(source: .huggingFace(repoID: preset.companion.repoID)) : nil,
                with: preset.base.repoID)
        }
    }

    private func resetGauges() {
        lastOutput = ""
        tokensPerSecond = nil
        repeatRate = nil
        timeToFirstTokenMS = nil
        deterministic = nil
        previousRun = nil
    }

    /// Back to the launch screen, keeping the pin store intact.
    func changeModel() {
        phase = .choosing
        preps = []
        onboardingLog.removeAll()
        modelRepoInput = activeRepo
        launchMode = .card
    }

    /// Resets the demo to "never downloaded": clears the whole persisted pin store (this is a
    /// demo, not a real app's model registry) so the next OK tracks `main` fresh. Shipped pins
    /// are code, not stored, and are unaffected.
    func forgetPins() {
        pinStore.removeAllPins()
        refreshCapturedPins()
        onboardingLogLine("forgot all captured pins — next OK tracks main fresh")
    }

    /// Deletes the weights out from under the running app (what an OS storage sweep or a user
    /// clearing app data does) and re-runs the launch from scratch on a brand-new provider — the
    /// pins are the only thing carried over, so the redownload must fetch the commits originally
    /// validated. For a pair, that includes the draft model or adapter.
    func simulateExternalDeletionAndRedownload() {
        guard !isPreparing, let launch = activeLaunch else { return }
        for artifact in launch.artifacts {
            guard let id = ModelID(scheme: "mlx", rest: artifact.repoID) else { continue }
            do {
                try mlx?.remove(id)
                onboardingLogLine("simulated external deletion of \(artifact.repoID) — pins untouched")
            } catch {
                onboardingLogLine("nothing local to delete for \(artifact.repoID)")
            }
        }
        isRedownloadFlow = true
        phase = .choosing
        self.launch(launch)
    }
}

// MARK: - UI

@available(macOS 27.0, *)
struct ControlRoomView: View {
    @ObservedObject var model: ControlRoomModel
    @State private var prompt = "Tell me a short story about a lighthouse keeper."

    var body: some View {
        Group {
            switch model.phase {
            case .choosing: model.isRedownloadFlow ? AnyView(redownloadScreen) : AnyView(modelPicker)
            case .ready: controlRoom
            }
        }
        .frame(
            minWidth: 780, idealWidth: 900, maxWidth: .infinity,
            minHeight: 520, idealHeight: 600, maxHeight: .infinity)
        // Belt and braces with the launch-time activation in `MLXControlRoomApp.init`: the window
        // may not exist yet when that runs.
        .onAppear { NSApplication.shared.activate() }
        .onChange(of: model.suggestedPrompt) { _, suggested in
            if let suggested { prompt = suggested }
        }
    }

    private var controlRoom: some View {
        HSplitView {
            knobPanel
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
            VStack(alignment: .leading, spacing: 16) {
                promptArea
                Divider()
                gaugePanel
            }
            .padding(20)
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var quitButton: some View {
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .font(.system(size: 13))
    }

    // MARK: Model picker (launch screen) + onboarding stepper

    private var modelPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Control Room").font(.system(size: 28, weight: .bold))
                    Spacer()
                    quitButton
                }

                switch model.launchMode {
                case .card: recommendedCard
                case .ownModel: ownModelForm
                case .pairing: pairingChooser
                }

                DisclosureGroup("Advanced — supply-chain policy") {
                    VStack(alignment: .leading, spacing: 8) {
                        toggleRow("verify content hash", isOn: $model.verificationEnabled)
                        toggleRow("cap total cache size", isOn: $model.cacheCapEnabled)
                        if model.cacheCapEnabled {
                            labeledSlider(
                                "cap (MB) — whole HF cache dir, not just this app",
                                value: $model.cacheCapMB, range: 10...20000, format: "%.0f")
                        }
                        if model.launchMode != .ownModel {
                            HStack {
                                toggleRow("simulate stale shipped pin", isOn: $model.simulateStaleShippedPin)
                                if model.simulateStaleShippedPin {
                                    Text(model.launchMode == .pairing
                                        ? "← now click \"Use this pair\" (the companion's pin goes stale)"
                                        : "← now click \"Use this model\" or \"Test a developer update\"")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        if model.launchMode == .card {
                            toggleRow("Simulate a newer app build", isOn: $model.simulateNewerAppBuild)
                            if model.simulateNewerAppBuild {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Pretends the developer released a new version of this app whose built-in Gemma is the newer one.")
                                        .font(.system(size: 14, weight: .semibold))
                                    if let saved = model.savedFeedUpdate {
                                        Text("Next: click “Test a developer update”. The update you applied earlier (to \(saved.revision.prefix(8))…) was made under the older build, so it is discarded — a new release always wins over an older runtime update. Gemma opens as “shipped with this app” at the newer version, with nothing left to update.")
                                    } else {
                                        Text("There is no earlier update to discard yet, so nothing would visibly change. To see the effect: (1) untick this, click “Test a developer update”, then Check for updates → Update in the control room; (2) click Change model; (3) come back here, tick this, and click “Test a developer update” again.")
                                    }
                                }
                                .font(.system(size: 14))
                                // Primary text on a light tint: orange text on the grey card was hard to read.
                                .foregroundStyle(.primary)
                                .padding(10)
                                .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Verification and the cap only matter on a fresh transfer — a repo already on disk is skipped file-by-file." + (model.launchMode == .ownModel ? "" : " \"Stale shipped pin\" swaps a shipped SHA for a bogus one: it should fail hard, never fall back to main."))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Divider()
                        capturedPinsSection
                    }
                    .padding(.top, 6)
                }
                .disabled(model.isPreparing)
                .focusEffectDisabled()


                if model.showsOnboardingSteps { onboardingSteps }
                logView(model.onboardingLog)
                if model.onboardingFailed {
                    Button("Dismiss") { model.dismissOnboardingFailure() }
                        .font(.system(size: 15))
                }
            }
            .padding(28)
            .frame(maxWidth: 600, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    /// The SDK's `MLXFilePinStore`, made visible: what has been captured so far.
    private var capturedPinsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Versions recorded for models you chose").font(.system(size: 13, weight: .semibold))
            Text("The exact version of each model you chose yourself (a \"pin\"), recorded the first time you downloaded it. Later downloads fetch exactly that version. Forget one and the next download records a fresh one.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.capturedPins.isEmpty {
                Text("None yet — the first download of a model you choose captures one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.capturedPins) { pin in
                HStack {
                    Text("\(pin.repo) @ \(pin.revision.prefix(12))…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget") { model.forgetPin(for: pin.repo) }
                        .font(.system(size: 12))
                }
            }
            Text("Stored in \(model.pinFilePath), outside the Hugging Face cache. Shipped pins are in code and aren't listed.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var recommendedCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Each card owns its own button, so there is one obvious action per card.
            VStack(alignment: .leading, spacing: 8) {
                Text("Recommended model").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(shippedModel.repoID).font(.system(size: 16, design: .monospaced))
                Text("pinned by this app at \(shippedModel.revision)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Use this model") { model.useShippedModel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isPreparing)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            // Why this card exists: it is the way in to the developer-update flow. The model is a real
            // small model you can also just use, but it ships at an *older* version on purpose so there
            // is something for the developer's update feed to offer.
            VStack(alignment: .leading, spacing: 8) {
                Text("Update test — a built-in model its developer can update").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(smallModel.repoID).font(.system(size: 14, design: .monospaced))
                Text("This build ships it at \(smallModel.revision.prefix(12))…, an older version. In the control room you can check the developer's feed for a newer one and move to it — no new app release needed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Test a developer update") { model.useBuiltIn(smallModel) }
                    .disabled(model.isPreparing)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Choose a different model…") {
                    // Hidden in the free-text view, so don't leave it silently armed.
                    model.simulateStaleShippedPin = false
                    model.launchMode = .ownModel
                }
                .disabled(model.isPreparing)
                Button("Model pairing…") { model.launchMode = .pairing }
                    .disabled(model.isPreparing)
                if model.isPreparing { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 15))
        }
    }

    private var ownModelForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which model do you want to use?").font(.system(size: 17))
            TextField("mlx-community/... (any repo id)", text: $model.modelRepoInput)
                .font(.system(size: 15, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .disabled(model.isPreparing)
                .onSubmit { model.confirmModel() }
            Text("This demo only allow-lists mlx-community/* — try another namespace to see the trust policy deny it before any network call. The first download records the version you got, so later downloads fetch exactly that version.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Want to try updating a model?").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Use gemma-3-270m-4bit") { model.modelRepoInput = ControlRoomModel.demoUpdateRepo }
                    .font(.system(size: 12))
                    .disabled(model.isPreparing)
            }
            if model.offersOlderVersionDemo {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $model.pretendDownloadedEarlier) {
                        Text("Demo: pretend I downloaded this a while ago").font(.system(size: 14))
                    }
                    Text("A model you download today is already the newest version, so there'd be nothing to update. This records an older version (about 280 MB to download) as the one you got, so that **Check for update** in the control room finds a newer one — a small change to its README.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("OK") { model.confirmModel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isPreparing || model.modelRepoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Back") { model.launchMode = .card }
                    .disabled(model.isPreparing)
                if model.isPreparing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Forget pins") { model.forgetPins() }
                    .font(.system(size: 12))
                    .disabled(model.isPreparing)
            }
            .font(.system(size: 15))
        }
    }

    private var pairingChooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Model pairing").font(.system(size: 17))
            Text("A curated pair: every model in it is shipped pinned, and goes through the same validate → download → pin checks as a single model.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            ForEach(pairingPresets) { preset in
                VStack(alignment: .leading, spacing: 8) {
                    Text(preset.title).font(.system(size: 16, weight: .semibold))
                    Text(preset.summary).font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 2) {
                        pairArtifactLine("Base model", preset.base)
                        pairArtifactLine(preset.companionRole, preset.companion)
                    }
                    Text(preset.expectation).font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("Use this pair") { model.usePairing(preset) }
                        .disabled(model.isPreparing)
                        .font(.system(size: 15))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Back") { model.launchMode = .card }
                    .disabled(model.isPreparing)
                if model.isPreparing { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 15))
        }
    }

    private func pairArtifactLine(_ role: String, _ artifact: ShippedModel) -> some View {
        Text("\(role): \(artifact.repoID) @ \(artifact.revision.prefix(12))…")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private var onboardingSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.preps) { prep in
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(prep.role).font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(prep.repoID).font(.system(size: 13, design: .monospaced))
                    }
                    stepRow("Validate", detail: prep.isAdapter ? "not applicable to an adapter repo" : "architecture, trust policy, reachability, cache quota", step: prep.validate)
                    stepRow("Download", detail: "trust policy, cache cap, content-hash verified", step: prep.download)
                    if let fraction = prep.progress { downloadProgressView(fraction) }
                    stepRow("Pin", detail: "shipped pin verified, or resolved commit captured outside the HF cache", step: prep.pin)
                }
                if prep.id != model.preps.last?.id { Divider() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Shown for "Simulate external deletion + redownload": the same stepper, then an explicit
    /// OK before returning to the control room.
    private var redownloadScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Simulating external deletion").font(.system(size: 28, weight: .bold))
                    Spacer()
                    quitButton
                }
                Text("The downloaded files were deleted from disk. Re-running the launch flow on a brand-new provider — only the pins carry over.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                onboardingSteps
                logView(model.onboardingLog)
                HStack {
                    if model.awaitingRedownloadAcknowledgement {
                        Button("OK") { model.acknowledgeRedownload() }
                            .keyboardShortcut(.defaultAction)
                    } else if model.onboardingFailed {
                        Button("Dismiss") { model.dismissOnboardingFailure() }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.system(size: 15))
            }
            .padding(28)
            .frame(maxWidth: 600, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func stepRow(_ title: String, detail: String, step: ControlRoomModel.Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch step {
            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                switch step {
                case .done(let text): Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
                case .failed(let text):
                    Text(text).font(.system(size: 13)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                default: Text(detail).font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var pinSummary: String {
        guard !model.activePins.isEmpty else { return "not pinned" }
        let source: String
        switch model.pinSource {
        case .shipped:
            if let buildTime = model.activeBuildTimeRevision, model.activeIsRuntimeOverride {
                source = "updated by the app's feed (this app build shipped \(buildTime.prefix(12))…)"
            } else {
                source = "shipped with this app"
            }
        case .captured: source = "the version you got when you first downloaded it"
        case .reused: source = "the version you got when you first downloaded it (reused)"
        case nil: source = "unknown"
        }
        let lines = model.activePins.map { "\($0.repo.split(separator: "/").last ?? "") @ \($0.revision.prefix(12))…" }
        return lines.joined(separator: "\n") + "\n" + source
    }

    /// What the onboarding pinned, plus the "Nth run"
    /// demo (weights deleted out from under the app).
    private var modelPanel: some View {
        groupBox("Model & pin") {
            VStack(alignment: .leading, spacing: 8) {
                Text(pinSummary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                pinUpdateSection
                Divider()
                oldVersionsSection
                Divider()
                Button("Simulate external deletion + redownload") { model.simulateExternalDeletionAndRedownload() }
                    .font(.system(size: 13))
                Text("Deletes the weights, then re-runs the launch flow on a brand-new provider — only the pins (shipped or persisted) carry over, so it must refetch the commits originally validated.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The SDK's snapshot inventory: every cached version of the active model, and a guarded Remove for
    /// the ones that aren't current. The host chooses when; the SDK guarantees only the files no other
    /// version uses are deleted.
    @ViewBuilder
    private var oldVersionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Versions on disk").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Refresh") { model.refreshSnapshots() }.font(.system(size: 12))
            }
            if model.snapshots.isEmpty {
                Text("None cached.").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(model.snapshots, id: \.revision) { snapshot in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(snapshot.repoID.split(separator: "/").last ?? "") @ \(snapshot.revision.prefix(10))…")
                            .font(.system(size: 12, design: .monospaced))
                        Text(snapshot.isCurrent ? "current" : (snapshot.isComplete ? "older" : "incomplete"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(snapshot.isCurrent ? .green : .secondary)
                        Spacer()
                        if !snapshot.isCurrent {
                            Button("Remove") { model.removeSnapshot(snapshot) }.font(.system(size: 12))
                        }
                    }
                    Text(snapshot.isCurrent
                        ? "in use — cannot be removed"
                        : "removing frees \(ByteCountFormatter.string(fromByteCount: snapshot.exclusiveBytes, countStyle: .file)); it shares \(ByteCountFormatter.string(fromByteCount: snapshot.sharedBytes, countStyle: .file)) with other versions, which stays")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Text("An update leaves the previous version on disk so you can roll back instantly. The app decides when to clean up — nothing is ever removed automatically.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Check for update / Update / Roll back — the SDK's pin update API.
    @ViewBuilder
    private var pinUpdateSection: some View {
        if model.pinUpdatable {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.updatablePinSource == .shipped
                    ? "Built into this app. The developer's update feed says which newer version is safe to use; nothing changes until you update."
                    : "You chose this model, so you decide when to update it. It stays on the version you first downloaded until you do.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.updatablePinSource == .shipped ? "Check for updates" : "Check for update") { model.checkForPinUpdate() }
                        .disabled(model.isPinUpdateBusy)
                    if model.activeIsRuntimeOverride, let shipped = model.activeBuildTimeRevision {
                        Button("Back to the version this app shipped (\(shipped.prefix(8))…)") { model.revertToShippedVersion() }
                            .disabled(model.isPinUpdateBusy)
                    }
                    if let previous = model.rollbackRevision {
                        Button("Roll back to \(previous.prefix(8))…") { model.rollBackPin() }
                            .disabled(model.isPinUpdateBusy)
                    }
                }
                .font(.system(size: 13))
                switch model.pinUpdate {
                case .idle: EmptyView()
                case .checking: ProgressView().controlSize(.small)
                case .upToDate:
                    Label(model.updatablePinSource == .shipped ? "Up to date with the developer's feed" : "Up to date with main",
                        systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(.green)
                case .available(let check):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Newer commit \(check.latestRevision.prefix(12))… is available.")
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(check.changes.prefix(6), id: \.path) { change in
                            Text(describe(change)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        if check.changes.count > 6 {
                            Text("…and \(check.changes.count - 6) more").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Button("Update to \(check.latestRevision.prefix(8))…") { model.applyPinUpdate() }
                            .font(.system(size: 13))
                    }
                case .updating(let fraction):
                    downloadProgressView(fraction)
                case .failed(let message):
                    Text(message).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("Fetches the new commit under the full policy first; the pin only moves if that succeeds. Your next Run loads the new version.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Shipped with this app. Its developer decides when it moves to a newer version, and the developer's update feed doesn't cover it — so it changes only with a new app version.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func describe(_ change: MLXFileChange) -> String {
        func size(_ bytes: Int64?) -> String { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—" }
        switch change.kind {
        case .added: return "+ \(change.path)  (\(size(change.newSize)))"
        case .removed: return "− \(change.path)  (\(size(change.oldSize)))"
        case .modified: return "~ \(change.path)  (\(size(change.oldSize)) → \(size(change.newSize)))"
        @unknown default: return change.path
        }
    }

    /// Pairing mode's live A/B switch: toggle, run, toggle, run again.
    @ViewBuilder
    private var pairingPanel: some View {
        if let preset = model.activePreset {
            groupBox(preset.title) {
                VStack(alignment: .leading, spacing: 10) {
                    switch preset.kind {
                    case .speedHelper(let numDraftTokens):
                        toggleRow("use speed helper", isOn: $model.pairingEnabled)
                        HStack(spacing: 16) {
                            rateReadout("without helper", model.lastRateWithoutPairing)
                            rateReadout("with helper", model.lastRateWithPairing)
                        }
                        Text("Run the prompt with the helper off, then on, then on again — the first run with it on loads the helper model, so it's slower; the second shows the steady state. Drafts \(numDraftTokens) words ahead (the SDK's default of 5 was slower on these models). tokens/sec is the approximate words-per-second gauge below.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    case .adapter:
                        toggleRow("use haiku adapter", isOn: $model.pairingEnabled)
                        Text("Run the prompt with the adapter off, then on. The adapted run loads its own copy of the base model with the adapter applied; expect a short, haiku-style verse in place of the plain model's factual overview (not always a strict 5-7-5).")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func activeModelLine(_ repo: String, role: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(role).font(.system(size: 12)).foregroundStyle(.tertiary)
            Text(repo).font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func rateReadout(_ label: String, _ rate: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rate.map { String(format: "%.1f", $0) } ?? "—")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("words/sec, \(label)").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    // MARK: Knobs

    private var knobPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Control Room").font(.system(size: 24, weight: .bold))
                    Spacer()
                    // Back to the launch screen (recommended model / your own / pairing).
                    Button("Change model") { model.changeModel() }
                        .font(.system(size: 13))
                    quitButton
                }
                if let preset = model.activePreset {
                    // A pair: name both models, not just the base.
                    VStack(alignment: .leading, spacing: 4) {
                        activeModelLine(preset.base.repoID, role: "Base model")
                        activeModelLine(preset.companion.repoID, role: preset.companionRole)
                    }
                } else {
                    Text(model.activeRepo)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Pairing mode's live switch lives right under the title — it's the thing being
                // demonstrated, so it shouldn't be buried below the sampling knobs.
                pairingPanel

                groupBox("Sampling") {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledSlider("temperature", value: $model.temperature, range: 0...2)
                        labeledSlider("topP", value: $model.topP, range: 0...1)
                        maxOutputTokensField
                        toggleRow("suppress thinking (effort: .off)", isOn: $model.suppressThinking)
                        Divider()
                        toggleRow("fix seed", isOn: $model.useFixedSeed)
                        if model.useFixedSeed {
                            labeledSlider("seed", value: $model.seed, range: 0...9999, format: "%.0f")
                        }
                        Text("All of these reach mlx-swift-lm's GenerateParameters. Run the same prompt twice with a fixed seed to light the determinism gauge.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                groupBox("Sampling extras") {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledSlider("topK (0 = off)", value: $model.topK, range: 0...100, format: "%.0f")
                        labeledSlider("minP (0 = off)", value: $model.minP, range: 0...1)
                        Divider()
                        toggleRow("repetitionPenalty", isOn: $model.useRepetitionPenalty)
                        if model.useRepetitionPenalty {
                            labeledSlider("penalty", value: $model.repetitionPenalty, range: 1...2)
                            labeledSlider("contextSize", value: $model.repetitionContextSize, range: 4...200, format: "%.0f")
                        }
                        Text("Pick a prompt/settings combo that loops at repetitionPenalty off, then turn it on — the repeat-rate gauge should visibly drop.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                groupBox("Prefill") {
                    VStack(alignment: .leading, spacing: 10) {
                        toggleRow("prefillStepSize", isOn: $model.usePrefillStepSize)
                        if model.usePrefillStepSize {
                            labeledSlider("chunk size", value: $model.prefillStepSize, range: 16...2048, format: "%.0f")
                        }
                        Text("Affects time-to-first-token on a long prompt, not the output text itself — watch the TTFT gauge, not repeat rate, when tuning this.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                modelPanel

                groupBox("KV cache — roadmap") {
                    VStack(alignment: .leading, spacing: 8) {
                        reservedRow("maxKVSize")
                        reservedRow("compressionAlgorithm")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        // The default scroll indicator reserves its own strip of width and, with macOS's
        // legacy "Always show scroll bars" setting, renders unconditionally even when the
        // window is tall enough that nothing needs scrolling yet — it isn't reacting to actual
        // overflow, just always occupying space and squeezing the panel's trailing edge against
        // the HSplitView divider. Content still scrolls fine via trackpad/wheel without it.
        .scrollIndicators(.hidden)
    }

    private func groupBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            content()
        } label: {
            Text(title).font(.system(size: 15, weight: .semibold))
        }
    }

    /// A typed token cap: digits only, 1...1,000,000, default 1024. Anything else is stripped as
    /// it's typed, and an empty or out-of-range value is flagged (and blocks Run) rather than
    /// silently replaced.
    private var maxOutputTokensField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("maxOutputTokens").font(.system(size: 15, design: .monospaced))
                Spacer()
                TextField("1024", text: $model.maxOutputTokensText)
                    .font(.system(size: 15, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: model.maxOutputTokensText) { _, text in
                        let digits = String(text.filter { ("0"..."9").contains($0) }.prefix(7))
                        if digits != text { model.maxOutputTokensText = digits }
                    }
            }
            if model.maxOutputTokens == nil {
                Text("Enter a whole number from 1 to 1,000,000.")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 15))
        }
    }

    private func labeledSlider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%.2f") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.system(size: 15, design: .monospaced))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    /// Compact, non-scrolling log for a demo panel nested inside `knobPanel`'s own `ScrollView`
    /// — the last few lines are enough to follow along, and a second nested `ScrollView` would
    /// fight the outer one for trackpad/wheel gestures.
    private func logView(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty {
                Text("—").font(.system(size: 13, design: .monospaced)).foregroundStyle(.tertiary)
            }
            ForEach(Array(lines.suffix(6).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A determinate download readout for the picker screen's stepper. Deliberately no cancel
    /// affordance: this is a short-lived demo download, not something worth building
    /// cancellation UI for here.
    private func downloadProgressView(_ fraction: Double) -> some View {
        ProgressView(value: fraction) {
            Text("downloading… \(Int(fraction * 100))%").font(.system(size: 13))
        }
        .frame(maxWidth: 280)
    }

    private func reservedRow(_ name: String) -> some View {
        HStack {
            Text(name).font(.system(size: 15, design: .monospaced)).foregroundStyle(.tertiary)
            Spacer()
            Text("roadmap").font(.system(size: 13)).foregroundStyle(.tertiary)
        }
    }

    // MARK: Prompt + gauges

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Prompt", text: $prompt, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submit(prompt) }
            HStack {
                Button("Run") { model.submit(prompt) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.maxOutputTokens == nil || model.inferencePaused)
                statusView
                Spacer()
            }
            .font(.system(size: 15))
            ScrollView {
                Text(model.lastOutput.isEmpty ? "Output appears here." : model.lastOutput)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .foregroundStyle(model.lastOutput.isEmpty ? .secondary : .primary)
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: 120, maxHeight: 220)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if model.inferencePaused {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("switching model version…").foregroundStyle(.secondary)
            }
        } else {
            runStatus
        }
    }

    @ViewBuilder
    private var runStatus: some View {
        switch model.state {
        case .idle: EmptyView()
        case .working: ProgressView().controlSize(.small)
        case .ready: Label("ready", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }

    private var gaugePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gauges").font(.system(size: 19, weight: .semibold))
            // A fixed HStack of 4 gauges (each >=140pt wide, plus spacing) doesn't fit a
            // narrower window and was clipping at the trailing edge instead of reflowing — an
            // adaptive grid wraps to a second row instead.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 24)], alignment: .leading, spacing: 12) {
                gauge("tokens/sec (approx.)", value: model.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—")
                gauge("repeat rate", value: model.repeatRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                gauge("TTFT (ms)", value: model.timeToFirstTokenMS.map { String(format: "%.0f", $0) } ?? "—")
                gauge(
                    "determinism",
                    value: model.deterministic.map { $0 ? "match" : "differs" } ?? "—",
                    tint: model.deterministic.map { $0 ? .green : .red })
            }
            Text("residency").font(.system(size: 17)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.residencyLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 14, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 160)
        }
    }

    private func gauge(_ label: String, value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(tint ?? .primary)
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 140, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

@available(macOS 27.0, *)
@main
struct MLXControlRoomApp: App {
    @StateObject private var model = ControlRoomModel()

    init() {
        #if LOCALLM_SDK_VERIFICATION
        // Maintainer builds only (see Verification.swift): `--verify-*` runs the SDK's real-network checks
        // headless and exits before the window opens. Compiled out of the public copy of this example.
        runVerificationModeIfRequested()
        #endif

        // Launched with `swift run` there is no app bundle, so macOS starts this as a
        // background-style process: it can show a window and take clicks, but it is never made
        // the active application, so keystrokes go to whatever app was frontmost (the terminal
        // or, here, the Claude app). Claim regular-app status and activate.
        // Only when it isn't one already: re-setting the policy of a process that already has it
        // makes macOS log "Task policy set failed: 4 (invalid argument)".
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        DispatchQueue.main.async { NSApplication.shared.activate() }
    }

    var body: some Scene {
        WindowGroup {
            ControlRoomView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}
