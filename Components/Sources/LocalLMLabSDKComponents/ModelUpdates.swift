import LocalLMLabSDKCore
import Observation
import SwiftUI

// Updating a model, and cleaning up the old versions an update leaves behind.
//
// These views are deliberately **decoupled from any provider**: they own presentation and state, and
// call closures the host supplies. The SDK's pin-update and cleanup APIs live on `MLXModelProvider` in
// Inference (macOS 27), which Components does not link — so the host adapts that provider to these
// value types in a few lines (README: "Adapting MLXModelProvider"), and any other provider that can
// answer the same questions works too.
//
// Two ideas the UI is built around, learned the hard way building the MLX Control Room:
//  1. **Who decides.** A model the *user* chose updates on the user's say-so, to whatever is newest. A
//     model *built into the app* is different: the developer vetted one specific version, so an update
//     is only ever to a version the developer vouches for — and the user should be told that.
//  2. **The switch is a pause point.** Downloading the new version doesn't disturb a running
//     conversation, but the moment of switching can — so the model exposes a `pauseInference` hook and a
//     `switching` state the host can use to hold off new requests.

// MARK: - Value types

/// One file that differs between two versions of a model.
public struct ModelFileChange: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case added, removed, modified }
    public var id: String { path }
    public var path: String
    public var kind: Kind
    public var oldSize: Int64?
    public var newSize: Int64?

    public init(path: String, kind: Kind, oldSize: Int64? = nil, newSize: Int64? = nil) {
        self.path = path
        self.kind = kind
        self.oldSize = oldSize
        self.newSize = newSize
    }
}

/// What "check for update" found. Nothing has been downloaded to produce this.
public struct ModelUpdateOffer: Sendable, Equatable {
    /// The version the model is on now (a commit hash, or any identifier the host prefers).
    public var current: String
    /// The version on offer.
    public var available: String
    public var changes: [ModelFileChange]

    public var isUpToDate: Bool { current == available }

    public init(current: String, available: String, changes: [ModelFileChange] = []) {
        self.current = current
        self.available = available
        self.changes = changes
    }

    /// "1 file changed (config.json)" / "3 files changed, 291 MB" — the line a user reads before agreeing.
    public var summary: String {
        guard !changes.isEmpty else { return "No file changes listed." }
        let total = changes.reduce(Int64(0)) { $0 + ($1.newSize ?? 0) }
        let count = changes.count == 1 ? "1 file changed" : "\(changes.count) files changed"
        if changes.count == 1, let only = changes.first { return "\(count) (\(only.path))" }
        return "\(count), \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}

/// Who decides when this model updates — and therefore what the UI says.
public enum ModelUpdateOwnership: Sendable, Equatable {
    /// The user picked this model, so the user decides; the offer is whatever is newest.
    case userChosen
    /// Built into the app. The developer vets versions; the offer is one the developer vouches for.
    case developerOffered
    /// Can't be updated here. `reason` is shown as-is ("changes only with a new app version").
    case fixed(reason: String)
}

/// One cached version of a model, for the cleanup list.
public struct ModelVersionRow: Sendable, Equatable, Identifiable {
    public var id: String { revision }
    public var revision: String
    /// The version in use. It cannot be removed.
    public var isCurrent: Bool
    /// `false` for a half-downloaded version.
    public var isComplete: Bool
    /// What removing this version would actually free — its own files, not ones it shares.
    public var freesBytes: Int64
    /// Bytes shared with other versions, which removing this one does **not** free.
    public var sharedBytes: Int64

    public init(revision: String, isCurrent: Bool, isComplete: Bool = true, freesBytes: Int64, sharedBytes: Int64 = 0) {
        self.revision = revision
        self.isCurrent = isCurrent
        self.isComplete = isComplete
        self.freesBytes = freesBytes
        self.sharedBytes = sharedBytes
    }
}

// MARK: - Update model

/// What the host provides. `apply` is used for updating **and** rolling back **and** returning to the
/// shipped version — they are all "move to this version", so one closure covers them.
public struct ModelUpdateActions: Sendable {
    /// Compares the current version with what is on offer. Downloads nothing.
    public var check: @Sendable () async throws -> ModelUpdateOffer
    /// Moves the model to `revision`: download and verify it, call `beforeSwitch` **once, before
    /// anything changes**, then switch. `progress` is 0...1 during the download. Throwing must leave
    /// the model on the version it was on. (`MLXModelProvider.updatePin(_:to:beforeSwitch:)` is exactly
    /// this shape.)
    public var apply: @Sendable (
        _ revision: String,
        _ progress: @escaping @Sendable (Double) -> Void,
        _ beforeSwitch: @escaping @Sendable () async throws -> Void
    ) async throws -> Void

    public init(
        check: @escaping @Sendable () async throws -> ModelUpdateOffer,
        apply: @escaping @Sendable (
            _ revision: String, _ progress: @escaping @Sendable (Double) -> Void,
            _ beforeSwitch: @escaping @Sendable () async throws -> Void
        ) async throws -> Void
    ) {
        self.check = check
        self.apply = apply
    }
}

@MainActor
@Observable
public final class ModelUpdateModel {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ModelUpdateOffer)
        /// Downloading the new version (0...1). The current version keeps working.
        case updating(Double)
        /// The new version is downloaded and verified; the host's `pauseInference` is running and the
        /// switch is about to happen. **Hosts should refuse new requests in this state.**
        case switching
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// The version the model is on, once known (after a check or an update).
    public private(set) var currentRevision: String?
    /// The version before the last update — what **Roll back** returns to (its files are normally still
    /// cached, so it needs no download).
    public private(set) var rollbackRevision: String?
    /// For a built-in model the developer has moved past what the app shipped: the version the app
    /// shipped, offered as **Back to the shipped version**.
    public var shippedRevision: String?
    public var ownership: ModelUpdateOwnership
    /// Awaited after the new version is downloaded and verified and **before** the switch. Wait here for
    /// in-flight requests on this model to finish and hold off new ones; return to let the switch
    /// happen. Throwing cancels the update, changing nothing.
    public var pauseInference: (@Sendable () async throws -> Void)?

    private let actions: ModelUpdateActions

    public init(
        actions: ModelUpdateActions, ownership: ModelUpdateOwnership, currentRevision: String? = nil,
        pauseInference: (@Sendable () async throws -> Void)? = nil
    ) {
        self.actions = actions
        self.ownership = ownership
        self.currentRevision = currentRevision
        self.pauseInference = pauseInference
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .updating, .switching: true
        default: false
        }
    }

    /// Whether the host should be refusing new requests on this model right now.
    public var isSwitching: Bool { state == .switching }

    /// Updating is offered at all only for models that aren't `fixed`.
    public var canUpdate: Bool {
        if case .fixed = ownership { return false }
        return true
    }

    public func checkForUpdate() async {
        guard canUpdate, !isBusy else { return }
        state = .checking
        do {
            let offer = try await actions.check()
            currentRevision = offer.current
            state = offer.isUpToDate ? .upToDate : .available(offer)
        } catch {
            state = .failed(Self.message(error))
        }
    }

    /// Applies the offer currently on show.
    public func update() async {
        guard case .available(let offer) = state else { return }
        await move(to: offer.available, from: offer.current)
    }

    public func rollBack() async {
        guard let target = rollbackRevision, let current = currentRevision else { return }
        await move(to: target, from: current)
    }

    public func revertToShippedVersion() async {
        guard let target = shippedRevision, let current = currentRevision, target != current else { return }
        await move(to: target, from: current)
    }

    private func move(to target: String, from previous: String) async {
        guard canUpdate, !isBusy else { return }
        state = .updating(0)
        let pause = pauseInference
        do {
            try await actions.apply(
                target,
                { [weak self] fraction in Task { @MainActor in self?.noteProgress(fraction) } },
                { [weak self] in
                    await self?.enterSwitching()
                    try await pause?()
                })
            currentRevision = target
            rollbackRevision = target == previous ? nil : previous
            state = .upToDate
        } catch is CancellationError {
            state = .failed("Cancelled — still on \(Self.short(previous)).")
        } catch {
            // Atomic by contract: a failed update leaves the model on the version it was on.
            state = .failed("\(Self.message(error)) — still on \(Self.short(previous)).")
        }
    }

    private func noteProgress(_ fraction: Double) {
        if case .updating = state { state = .updating(fraction) }
    }

    private func enterSwitching() { state = .switching }

    static func short(_ revision: String) -> String { String(revision.prefix(8)) + "…" }

    private static func message(_ error: Error) -> String {
        (error as? LocalLMLabError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Update view

@available(macOS 26.0, *)
public struct ModelUpdateView: View {
    private let model: ModelUpdateModel

    public init(model: ModelUpdateModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.canUpdate { controls }
            statusView
        }
    }

    private var explanation: String {
        switch model.ownership {
        case .userChosen:
            "You chose this model, so you decide when to update it. It stays on the version you first downloaded until you do."
        case .developerOffered:
            "Built into this app. The developer says which newer version is safe to use; nothing changes until you update."
        case .fixed(let reason):
            reason
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            Button(model.ownership == .developerOffered ? "Check for updates" : "Check for update") {
                Task { await model.checkForUpdate() }
            }
            .disabled(model.isBusy)
            if let previous = model.rollbackRevision {
                Button("Roll back to \(ModelUpdateModel.short(previous))") { Task { await model.rollBack() } }
                    .disabled(model.isBusy)
            }
            if let shipped = model.shippedRevision, shipped != model.currentRevision {
                Button("Back to the version this app shipped (\(ModelUpdateModel.short(shipped)))") {
                    Task { await model.revertToShippedVersion() }
                }
                .disabled(model.isBusy)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Label(model.ownership == .developerOffered ? "Up to date with the developer's offer" : "Up to date",
                systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
        case .available(let offer):
            VStack(alignment: .leading, spacing: 4) {
                Text("Newer version \(ModelUpdateModel.short(offer.available)) is available.").font(.callout.weight(.semibold))
                Text(offer.summary).font(.caption).foregroundStyle(.secondary)
                ForEach(offer.changes.prefix(6)) { change in
                    Text(Self.line(for: change)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                if offer.changes.count > 6 {
                    Text("…and \(offer.changes.count - 6) more").font(.caption).foregroundStyle(.secondary)
                }
                Button("Update to \(ModelUpdateModel.short(offer.available))") { Task { await model.update() } }
                    .font(.callout)
            }
        case .updating(let fraction):
            ProgressView(value: fraction) { Text("downloading… \(Int(fraction * 100))%").font(.caption) }
                .frame(maxWidth: 280)
        case .switching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("switching model version…").font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func line(for change: ModelFileChange) -> String {
        func size(_ bytes: Int64?) -> String { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—" }
        switch change.kind {
        case .added: return "+ \(change.path)  (\(size(change.newSize)))"
        case .removed: return "− \(change.path)  (\(size(change.oldSize)))"
        case .modified: return "~ \(change.path)  (\(size(change.oldSize)) → \(size(change.newSize)))"
        }
    }
}

// MARK: - Versions on disk

@MainActor
@Observable
public final class ModelVersionsModel {
    public private(set) var versions: [ModelVersionRow] = []
    public private(set) var isLoading = false
    /// The last outcome the user should see ("Freed 1.6 KB", or why a removal failed).
    public private(set) var message: String?

    private let list: @Sendable () async -> [ModelVersionRow]
    private let remove: @Sendable (ModelVersionRow) async throws -> Int64

    /// - Parameters:
    ///   - list: the cached versions of the model.
    ///   - remove: removes one and returns the bytes freed. Must refuse the current version
    ///     (`MLXModelProvider.removeSnapshot` does).
    public init(
        list: @escaping @Sendable () async -> [ModelVersionRow],
        remove: @escaping @Sendable (ModelVersionRow) async throws -> Int64
    ) {
        self.list = list
        self.remove = remove
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        versions = await list()
        isLoading = false
    }

    /// Removes an older version. The current version is refused here without calling the host — the
    /// button isn't shown for it, and this is the backstop.
    public func remove(_ row: ModelVersionRow) async {
        guard !row.isCurrent else {
            message = "That is the version in use, so it can't be removed."
            return
        }
        do {
            let freed = try await remove(row)
            message = "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))."
        } catch {
            message = "Couldn't remove it: \((error as? LocalLMLabError)?.errorDescription ?? error.localizedDescription)"
        }
        await refreshAfterRemoval()
    }

    private func refreshAfterRemoval() async {
        isLoading = false
        versions = await list()
    }
}

@available(macOS 26.0, *)
public struct ModelVersionsView: View {
    private let model: ModelVersionsModel

    public init(model: ModelVersionsModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Versions on disk").font(.callout.weight(.semibold))
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }.font(.caption).disabled(model.isLoading)
            }
            if model.versions.isEmpty { Text("None cached.").font(.caption).foregroundStyle(.tertiary) }
            ForEach(model.versions) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(String(row.revision.prefix(10)))…").font(.system(.caption, design: .monospaced))
                        Text(row.isCurrent ? "current" : (row.isComplete ? "older" : "incomplete"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(row.isCurrent ? .green : .secondary)
                        Spacer()
                        if !row.isCurrent { Button("Remove") { Task { await model.remove(row) } }.font(.caption) }
                    }
                    Text(row.isCurrent
                        ? "in use — cannot be removed"
                        : "removing frees \(Self.bytes(row.freesBytes)); it shares \(Self.bytes(row.sharedBytes)) with other versions, which stays")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("An update leaves the previous version on disk so you can roll back instantly. The app decides when to clean up — nothing is removed automatically.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.refresh() }
    }

    private static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
