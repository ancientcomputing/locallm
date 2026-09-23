import Foundation
import Testing
import LocalLMLabSDKCore
import LocalLMLabSDKComponents

// ModelUpdateModel and ModelVersionsModel. The host's provider is a set of closures, so the state machine,
// the pause point and the guards are tested without any provider.

private let v1 = "9eba008f65cdc8aee60201be10dcd0e7858455ce"
private let v2 = "ff1143e3a10547c9f2129e94ca37059b096b23f4"

private let oneFile = ModelUpdateOffer(
    current: v1, available: v2,
    changes: [ModelFileChange(path: "config.json", kind: .modified, oldSize: 1648, newSize: 1653)])

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ e: String) { lock.lock(); entries.append(e); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

@MainActor
private func model(
    ownership: ModelUpdateOwnership = .userChosen, log: Log = Log(),
    offer: ModelUpdateOffer = oneFile, checkFails: Bool = false, applyFails: Bool = false,
    pause: (@Sendable () async throws -> Void)? = nil
) -> ModelUpdateModel {
    ModelUpdateModel(
        actions: ModelUpdateActions(
            check: { log.add("check"); if checkFails { throw LocalLMLabError.download(stage: "resolve", underlying: nil) }; return offer },
            apply: { revision, progress, beforeSwitch in
                log.add("apply:\(revision.prefix(4))")
                progress(0.5)
                log.add("beforeSwitch-start")
                try await beforeSwitch()
                log.add("beforeSwitch-done")
                if applyFails { throw LocalLMLabError.download(stage: "cacheQuota", underlying: nil) }
            }),
        ownership: ownership, currentRevision: v1, pauseInference: pause)
}

// MARK: - The state machine

@MainActor @Test func checkingFindsAnOfferOrSaysUpToDate() async {
    let behind = model()
    await behind.checkForUpdate()
    #expect(behind.state == .available(oneFile))
    #expect(behind.currentRevision == v1)

    let current = model(offer: ModelUpdateOffer(current: v2, available: v2))
    await current.checkForUpdate()
    #expect(current.state == .upToDate)
}

@MainActor @Test func aFailedCheckShowsTheErrorAndChangesNothing() async {
    let m = model(checkFails: true)
    await m.checkForUpdate()
    if case .failed(let text) = m.state { #expect(!text.isEmpty) } else { Issue.record("should be failed") }
    #expect(m.rollbackRevision == nil)
}

@MainActor @Test func aFixedModelNeverChecksOrUpdates() async {
    let log = Log()
    let m = model(ownership: .fixed(reason: "Changes only with a new app version."), log: log)
    #expect(!m.canUpdate)
    await m.checkForUpdate()
    #expect(m.state == .idle)
    #expect(log.all.isEmpty, "the host is never even asked")
}

@MainActor @Test func updatingMovesToTheOfferedVersionAndOffersARollback() async {
    let m = model()
    await m.checkForUpdate()
    await m.update()
    #expect(m.state == .upToDate)
    #expect(m.currentRevision == v2)
    #expect(m.rollbackRevision == v1, "the previous version is what Roll back returns to")
}

@MainActor @Test func rollingBackMovesToThePreviousVersion() async {
    let log = Log()
    let m = model(log: log)
    await m.checkForUpdate(); await m.update()
    await m.rollBack()
    #expect(m.currentRevision == v1)
    #expect(m.rollbackRevision == v2, "and now the newer one is one step forward")
    #expect(log.all.filter { $0.hasPrefix("apply:") } == ["apply:ff11", "apply:9eba"])
}

@MainActor @Test func aFailedUpdateLeavesTheModelWhereItWasAndSaysSo() async {
    let m = model(applyFails: true)
    await m.checkForUpdate()
    await m.update()
    guard case .failed(let text) = m.state else { Issue.record("should be failed"); return }
    #expect(text.contains("still on 9eba008f"), "atomic: the user is told which version they are on")
    #expect(m.currentRevision == v1)
    #expect(m.rollbackRevision == nil, "nothing to roll back — nothing changed")
}

@MainActor @Test func backToTheShippedVersionAppearsOnlyWhenTheModelHasMovedPastIt() async {
    let m = model(ownership: .developerOffered)
    m.shippedRevision = v1
    await m.checkForUpdate(); await m.update()          // developer's offer moves it to v2
    #expect(m.currentRevision == v2)
    await m.revertToShippedVersion()
    #expect(m.currentRevision == v1)
    // Already on the shipped version: nothing to revert to.
    let log = Log()
    let same = model(ownership: .developerOffered, log: log)
    same.shippedRevision = v1
    await same.checkForUpdate()
    await same.revertToShippedVersion()
    #expect(!log.all.contains { $0.hasPrefix("apply:") })
}

@MainActor @Test func updateWithoutAnOfferDoesNothing() async {
    let log = Log()
    let m = model(log: log)
    await m.update()
    await m.rollBack()
    #expect(!log.all.contains { $0.hasPrefix("apply:") })
    #expect(m.state == .idle)
}

// MARK: - The pause point

@MainActor @Test func theHostsPauseRunsBeforeTheSwitchAndTheStateSaysSwitching() async {
    let log = Log()
    let m = model(log: log, pause: { log.add("pause") })
    await m.checkForUpdate()
    await m.update()
    #expect(log.all == ["check", "apply:ff11", "beforeSwitch-start", "pause", "beforeSwitch-done"],
        "the host's pause is awaited inside beforeSwitch — after the download, before anything changes")
}

@MainActor @Test func theStateIsSwitchingWhileTheHostPauses() async {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock(); private var open = false
        func release() { lock.lock(); open = true; lock.unlock() }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    }
    let gate = Gate()
    let m = model(pause: { while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) } })
    await m.checkForUpdate()
    let running = Task { await m.update() }
    while m.state != .switching { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(m.isSwitching, "hosts refuse new requests while this is true")
    #expect(m.isBusy)
    gate.release()
    await running.value
    #expect(m.state == .upToDate && !m.isSwitching)
}

@MainActor @Test func aHostVetoCancelsTheUpdateAndKeepsTheOldVersion() async {
    struct NotNow: Error {}
    let m = model(pause: { throw NotNow() })
    await m.checkForUpdate()
    await m.update()
    if case .failed = m.state {} else { Issue.record("a veto ends as a failure the user can read") }
    #expect(m.currentRevision == v1 && m.rollbackRevision == nil)
}

@MainActor @Test func aSecondActionWhileBusyIsIgnored() async {
    let log = Log()
    let m = model(log: log, pause: { try await Task.sleep(for: .milliseconds(60)) })
    await m.checkForUpdate()
    let first = Task { await m.update() }
    while !m.isBusy { try? await Task.sleep(for: .milliseconds(2)) }
    await m.update()          // a double-click
    await m.checkForUpdate()  // and a check mid-update
    await first.value
    #expect(log.all.filter { $0.hasPrefix("apply:") }.count == 1)
    #expect(log.all.filter { $0 == "check" }.count == 1)
}

// MARK: - The offer's summary line

@Test func theSummaryReadsLikeTheLineAUserDecidesOn() {
    #expect(oneFile.summary == "1 file changed (config.json)")
    let many = ModelUpdateOffer(current: v1, available: v2, changes: [
        ModelFileChange(path: "model.safetensors", kind: .modified, oldSize: 100_000_000, newSize: 100_000_100),
        ModelFileChange(path: "config.json", kind: .modified, oldSize: 1, newSize: 2),
    ])
    #expect(many.summary.hasPrefix("2 files changed, "))
    #expect(ModelUpdateOffer(current: v1, available: v2).summary == "No file changes listed.")
}

// MARK: - Versions on disk

private func row(_ rev: String, current: Bool, frees: Int64 = 1_648) -> ModelVersionRow {
    ModelVersionRow(revision: rev, isCurrent: current, freesBytes: frees, sharedBytes: 190_000_000)
}

@MainActor @Test func refreshListsTheVersions() async {
    let versions = ModelVersionsModel(list: { [row(v1, current: false), row(v2, current: true)] }, remove: { _ in 0 })
    await versions.refresh()
    #expect(versions.versions.map(\.revision) == [v1, v2])
}

@MainActor @Test func removingAnOlderVersionReportsWhatWasFreedAndRefreshes() async {
    final class Store: @unchecked Sendable {
        private let lock = NSLock(); private var rows = [row(v1, current: false), row(v2, current: true)]
        var current: [ModelVersionRow] { lock.lock(); defer { lock.unlock() }; return rows }
        func drop(_ rev: String) { lock.lock(); rows.removeAll { $0.revision == rev }; lock.unlock() }
    }
    let store = Store()
    let versions = ModelVersionsModel(list: { store.current }, remove: { r in store.drop(r.revision); return r.freesBytes })
    await versions.refresh()
    await versions.remove(versions.versions[0])
    #expect(versions.message?.hasPrefix("Freed ") == true)
    #expect(versions.versions.map(\.revision) == [v2], "the list reflects the removal")
}

@MainActor @Test func theCurrentVersionIsRefusedWithoutCallingTheHost() async {
    let log = Log()
    let versions = ModelVersionsModel(list: { [row(v2, current: true)] }, remove: { _ in log.add("remove"); return 0 })
    await versions.refresh()
    await versions.remove(versions.versions[0])
    #expect(log.all.isEmpty, "the backstop: the host is never asked to remove what is in use")
    #expect(versions.message == "That is the version in use, so it can't be removed.")
}

@MainActor @Test func aFailedRemovalIsExplainedNotSwallowed() async {
    let versions = ModelVersionsModel(
        list: { [row(v1, current: false), row(v2, current: true)] },
        remove: { _ in throw LocalLMLabError.download(stage: "currentVersion", underlying: nil) })
    await versions.refresh()
    await versions.remove(versions.versions[0])
    #expect(versions.message?.hasPrefix("Couldn't remove it") == true)
    #expect(versions.versions.count == 2, "and nothing disappeared from the list")
}
