import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// What a start does about the last one — sections 7.1, 9.4 and 9.5. The hand-off table is pure;
/// the effects run against `FakePrepare`/`FakeCommit` and a store in a temporary directory.
final class SwitcherReconcileTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private let v060 = UpdateFixture.v060, v070 = UpdateFixture.v070, v080 = UpdateFixture.v080
    private var cleanup: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
    }

    private func store() throws -> (SwitcherUpdateStore, URL) {
        let (store, directory) = try makeTemporaryStore()
        cleanup.append(directory)
        return (store, directory)
    }

    // MARK: - The hand-off table (9.4)

    private func finish(_ handoff: UpdateHandoff, running: ReleaseVersion?) -> HandoffResult {
        SwitcherUpdater.finishHandoff(handoff, running: running, host: UpdateFixture.host, now: now)
    }

    func testLaunchedSwappedOrRestartPendingWithTheNewVersionRunningIsASuccess() {
        for phase: UpdateHandoff.Phase in [.launched, .swapped, .restartPending] {
            let result = finish(UpdateFixture.handoff(phase), running: v080)
            XCTAssertEqual(result.verdict, .succeeded, "\(phase)")
            XCTAssertEqual(result.disposition, .deleteAtSettle, "\(phase)")
            XCTAssertEqual(result.deleteDownloadsFor, "v0.8.0", "\(phase)")
            XCTAssertEqual(result.notice?.text, SwitcherUpdateText.updated(to: v080, at: now), "\(phase)")
            XCTAssertNil(result.rejection, "\(phase)")
            XCTAssertEqual(result.lastInstall?.from, v070)
            XCTAssertEqual(result.lastInstall?.to, v080)
            XCTAssertEqual(result.lastInstall?.tag, "v0.8.0")
            XCTAssertEqual(result.launchAtLoginWasEnabled, true)
        }
        XCTAssertTrue(SwitcherUpdateText.updated(to: v080, at: now).hasPrefix("Claude Switcher updated itself to 0.8.0 at "))
    }

    func testTheSuccessNoticeSaysWhereThePreviousCopyIsAndWhereTheNotesAre() {
        var handoff = UpdateFixture.handoff(.launched)
        handoff.oldCopy = OldCopy(kind: .previous, path: UpdateFixture.previous(v070))
        let tooltip = finish(handoff, running: v080).notice?.tooltip ?? ""
        XCTAssertEqual(tooltip, "From 0.7.0. The previous copy is kept in ~/.config/claude-switcher/updates/previous. "
                       + "Release notes: github.com/kevinchau/claude-switcher/releases/tag/v0.8.0")
    }

    func testTheOldVersionStillRunningAfterLaunchedSwappedOrRestartPendingIsAFailure() {
        for phase: UpdateHandoff.Phase in [.launched, .swapped, .restartPending] {
            let result = finish(UpdateFixture.handoff(phase), running: v070)
            XCTAssertEqual(result.verdict, .failed, "\(phase)")
            XCTAssertEqual(result.disposition, .archiveAsFailed, "\(phase)")
            XCTAssertEqual(result.notice?.text,
                           "Claude Switcher could not update itself to 0.8.0 \u{2014} still 0.7.0. See Diagnostics\u{2026}")
            XCTAssertEqual(result.rejection?.tag, "v0.8.0", "\(phase)")
            XCTAssertEqual(result.rejection?.digestHex, UpdateFixture.digest, "\(phase)")
            XCTAssertNil(result.deleteDownloadsFor, "\(phase)")
        }
    }

    func testARolledBackRecordIsReportedNotRejected() {
        let result = finish(UpdateFixture.handoff(.rolledBack, failure: "the app in place fails its signature check"),
                            running: v070)
        XCTAssertEqual(result.verdict, .rolledBack)
        XCTAssertEqual(result.disposition, .archiveAsFailed)
        XCTAssertEqual(result.findings, ["last attempt: the app in place fails its signature check"])
        XCTAssertNil(result.rejection)
        XCTAssertNil(result.notice)
        XCTAssertNil(result.deleteDownloadsFor)
    }

    func testASwapThatWasInterruptedBeforeItHappenedAllowsARetry() {
        let result = finish(UpdateFixture.handoff(.swapping), running: v070)
        XCTAssertEqual(result.verdict, .interrupted)
        XCTAssertEqual(result.findings, ["an update to 0.8.0 was interrupted before it was installed"])
        XCTAssertNil(result.rejection)
        XCTAssertNil(result.deleteDownloadsFor, "the disk image is kept for the retry")
    }

    func testASwapThatHappenedButWasNotRecordedIsASuccessThatNamesTheStagingFolder() {
        let result = finish(UpdateFixture.handoff(.swapping), running: v080)
        XCTAssertEqual(result.verdict, .succeeded)
        XCTAssertTrue(result.findings.contains("the previous copy may still be in \(UpdateFixture.staged)"))
    }

    func testAnyOtherVersionIsUnexpectedAndTheRecordIsKept() {
        for running in [v060, ReleaseVersion(major: 0, minor: 9, patch: 0)] {
            let result = finish(UpdateFixture.handoff(.launched), running: running)
            XCTAssertEqual(result.verdict, .unexpected)
            XCTAssertEqual(result.disposition, .keep)
            XCTAssertEqual(result.findings, ["unexpected version \(running) after an update from 0.7.0 to 0.8.0"])
            XCTAssertNil(result.rejection)
            XCTAssertNil(result.notice)
        }
        XCTAssertEqual(finish(UpdateFixture.handoff(.launched), running: nil).verdict, .unexpected)
    }

    func testARecordFromAnotherMacMeansNothingHere() {
        for phase: UpdateHandoff.Phase in [.launched, .swapped, .restartPending, .rolledBack, .swapping] {
            let result = finish(UpdateFixture.handoff(phase, host: UpdateFixture.otherHost), running: v070)
            XCTAssertEqual(result.verdict, .foreign)
            XCTAssertEqual(result.disposition, .keep)
            XCTAssertNil(result.notice)
            XCTAssertNil(result.rejection)
            XCTAssertNil(result.deleteDownloadsFor)
            XCTAssertEqual(result.findings, [SwitcherUpdater.foreignFinding])
        }
    }

    func testAFinishedRevertRejectsTheBadReleaseAndSaysSo() {
        let result = finish(UpdateFixture.handoff(.launched, kind: .revert, from: v080, to: v070), running: v070)
        XCTAssertEqual(result.verdict, .succeeded)
        XCTAssertEqual(result.notice?.text,
                       "Claude Switcher 0.8.0 did not start properly twice; it went back to 0.7.0. See Diagnostics\u{2026}")
        XCTAssertEqual(result.rejection?.tag, "v0.8.0")
        XCTAssertNil(result.deleteDownloadsFor)
    }

    // MARK: - Acting on the hand-off at launch

    private func context(running: ReleaseVersion = UpdateFixture.v080, holder: Bool = true, aborted: Int = 0,
                         updates: String = UpdateFixture.updates) -> SwitcherUpdater.LaunchContext {
        let copy = UpdateFixture.runningCopy(version: running)
        let trust = SwitcherTrust(teamID: UpdateFixture.team, identifier: UpdateFixture.bundleID, runningVersion: running)
        return SwitcherUpdater.LaunchContext(running: copy, trust: trust, isLockHolder: holder, abortedStarts: aborted,
                                             updatesDirectory: updates, temporaryItems: UpdateFixture.temporaryItems,
                                             claudeAppPath: UpdateFixture.claudeApp, now: now)
    }

    /// Finished at the first start, and kept until that start has got going: the record is what
    /// the crash-loop guard goes by, and only the lock holder's settled start deletes it.
    func testASuccessfulHandoffIsFinishedByTheLockHolderAndDeletedOnceTheStartHasSettled() async throws {
        let (store, directory) = try store()
        let record = directory.appendingPathComponent("handoff.json").path
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        var stale = SwitcherUpdateState()
        stale.prepared = UpdateFixture.prepared()
        try await store.save(stale)
        let prepare = FakePrepare(), commit = FakeCommit()
        prepare.directories[UpdateFixture.updates + "/downloads"] = []
        let report = await SwitcherUpdater.reconcileAtLaunch(context(), store: store, prepare: prepare.env, commit: commit.env)

        XCTAssertEqual(report.handoff?.verdict, .succeeded)
        XCTAssertEqual(prepare.removed, [UpdateFixture.updates + "/downloads/v0.8.0"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: record), "kept until this start has got going")
        let state = await store.load(now: now)
        XCTAssertEqual(state.notice?.text, SwitcherUpdateText.updated(to: v080, at: now))
        XCTAssertEqual(state.lastInstall?.to, v080)
        XCTAssertNil(state.prepared, "a staged copy belongs to the process that made it")
        XCTAssertEqual(commit.effectCount, 0)

        try await store.settleStart(version: v080)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record), "a copy without the lock leaves it")
        try await store.settleStart(version: v070, isLockHolder: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record), "not the version it installed")
        try await store.settleStart(version: v080, isLockHolder: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record))
    }

    /// A settled start deletes only a finished record of an update to its own version: an update
    /// to another version started since, or a failed one, is not its to delete.
    func testASettledStartDeletesOnlyAFinishedRecordOfItsOwnVersion() async throws {
        let (store, directory) = try store()
        let record = directory.appendingPathComponent("handoff.json").path
        for handoff in [UpdateFixture.handoff(.swapping, from: v080, to: ReleaseVersion(major: 0, minor: 9, patch: 0)),
                        UpdateFixture.handoff(.rolledBack), UpdateFixture.handoff(.launched, host: UpdateFixture.otherHost)] {
            try await store.writeHandoff(handoff)
            try await store.settleStart(version: v080, isLockHolder: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: record), "\(handoff.phase) \(handoff.host)")
        }
    }

    // MARK: - The rules alone

    /// Each clause of the staging rule on its own refuses: the layers in front of it cannot
    /// stand in for it.
    func testTheStagingRuleNeedsEveryClause() {
        let folder = UpdateFixture.staging, app = UpdateFixture.staged
        func ours(path: String = folder, parent: String? = UpdateFixture.temporaryItems,
                  kinds: [String: FileKind] = [folder: .directory, app: .directory],
                  entries: [String]? = ["Claude Switcher.app"], bundleID: String? = UpdateFixture.bundleID,
                  running: String? = UpdateFixture.bundleID) -> Bool {
            SwitcherUpdatePolicy.stagingIsOurs(
                path: path, temporaryItems: UpdateFixture.temporaryItems,
                canonical: { ($0 as NSString).deletingLastPathComponent == UpdateFixture.temporaryItems
                    || $0 == UpdateFixture.temporaryItems ? parent : $0 },
                lstat: { kinds[$0] }, entries: { _ in entries }, bundleID: { _ in bundleID }, runningBundleID: running)
        }
        XCTAssertTrue(ours())
        XCTAssertFalse(ours(path: UpdateFixture.temporaryItems + "/Other_folder"), "the name")
        XCTAssertFalse(ours(path: UpdateFixture.temporaryItems + "/NSIRD_"), "the name")
        XCTAssertFalse(ours(parent: "/private/var/folders/zz/other/T"), "the parent")
        XCTAssertFalse(ours(parent: nil), "an unresolvable parent")
        XCTAssertFalse(ours(kinds: [folder: .symlink, app: .directory]), "a link")
        XCTAssertFalse(ours(entries: ["Claude Switcher.app", ".DS_Store"]), "a second entry")
        XCTAssertFalse(ours(entries: nil), "an unreadable folder")
        XCTAssertFalse(ours(kinds: [folder: .directory, app: .symlink]), "the app is a link")
        XCTAssertFalse(ours(bundleID: "com.example.other"), "another app")
        XCTAssertFalse(ours(bundleID: nil), "no identifier")
        XCTAssertFalse(ours(running: nil), "nothing to compare with")
        XCTAssertFalse(ours(path: "NSIRD_relative"), "a relative path")
    }

    func testOnlyThisMacsRecordOfAnUpdateToTheRunningVersionCanDriveAReturn() {
        let handoff = UpdateFixture.handoff(.launched)
        let plan = RevertPlan(from: v080, to: v070, tag: "v0.8.0", digest: UpdateFixture.digest)
        func decide(_ aborted: Int = 2, running: ReleaseVersion? = UpdateFixture.v080,
                    handoff: UpdateHandoff? = handoff) -> RevertDecision {
            SwitcherUpdatePolicy.revertDecision(abortedStarts: aborted, running: running, handoff: handoff,
                                                host: UpdateFixture.host)
        }
        XCTAssertEqual(decide(), .revert(plan))
        XCTAssertEqual(decide(1), .none)
        XCTAssertEqual(decide(running: v070), .none)
        XCTAssertEqual(decide(running: nil), .none)
        XCTAssertEqual(decide(handoff: UpdateFixture.handoff(.launched, host: UpdateFixture.otherHost)), .none)
        XCTAssertEqual(decide(handoff: UpdateFixture.handoff(.launched, kind: .revert, from: v080, to: v070)), .none,
                       "a return is never returned from")
        XCTAssertEqual(decide(handoff: UpdateFixture.handoff(.launched, from: v080, to: v060)), .none, "a record about another version")
        // Going back is only ever to an older version, whatever a record says.
        XCTAssertEqual(decide(handoff: UpdateFixture.handoff(.launched, from: ReleaseVersion(major: 0, minor: 9, patch: 0),
                                                             to: v080)), .none)
        XCTAssertEqual(decide(handoff: nil), .none, "once the record is gone the version has settled")
    }

    func testAFailedHandoffIsArchivedRejectedAndItsDownloadKept() async throws {
        let (store, directory) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        let prepare = FakePrepare(), commit = FakeCommit()
        let report = await SwitcherUpdater.reconcileAtLaunch(context(running: v070), store: store,
                                                             prepare: prepare.env, commit: commit.env)
        XCTAssertEqual(report.handoff?.verdict, .failed)
        XCTAssertFalse(prepare.removed.contains(UpdateFixture.updates + "/downloads/v0.8.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("handoff.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("handoff.failed.json").path))
        let state = await store.load(now: now)
        XCTAssertTrue(state.isRejected(tag: "v0.8.0", digest: UpdateFixture.digest))
    }

    func testAHandoffFromAnotherMacIsNamedAndLeftExactlyWhereItIs() async throws {
        let (store, directory) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched, host: UpdateFixture.otherHost))
        let record = directory.appendingPathComponent("handoff.json")
        let before = try Data(contentsOf: record)
        let prepare = FakePrepare(), commit = FakeCommit()
        let report = await SwitcherUpdater.reconcileAtLaunch(context(running: v070), store: store,
                                                             prepare: prepare.env, commit: commit.env)
        XCTAssertNil(report.handoff)
        XCTAssertTrue(report.findings.contains(SwitcherUpdater.foreignFinding))
        XCTAssertEqual(try Data(contentsOf: record), before)
        XCTAssertNil(report.state.notice)
        XCTAssertNil(report.state.rejected)
        XCTAssertEqual(report.state.foreignRecordsSeen, true)
        XCTAssertEqual(prepare.removed, [])
        XCTAssertEqual(commit.effectCount, 0)

        // Once the other Mac's record is gone, the next launch no longer names it.
        try FileManager.default.removeItem(at: record)
        let later = await SwitcherUpdater.reconcileAtLaunch(context(running: v070), store: store,
                                                            prepare: prepare.env, commit: commit.env)
        XCTAssertNil(later.state.foreignRecordsSeen)
        XCTAssertFalse(later.findings.contains(SwitcherUpdater.foreignFinding))
        XCTAssertEqual(later.state.installPath, UpdateFixture.install)
    }

    func testATornHandoffIsReportedNotActedOnAndLeftInPlace() async throws {
        let (store, directory) = try store()
        let record = directory.appendingPathComponent("handoff.json")
        try Data(#"{"format":1,"host":"11111111-2222-3333-4444-555555555555","phase":"launc"#.utf8).write(to: record)
        let before = TreeSnapshot(of: directory)
        let prepare = FakePrepare(), commit = FakeCommit()
        let report = await SwitcherUpdater.reconcileAtLaunch(context(), store: store, prepare: prepare.env, commit: commit.env)
        XCTAssertNil(report.handoff)
        XCTAssertTrue(report.findings.contains("handoff.json is not a record this version understands; it is left in place "
                                               + "(renaming it to handoff.failed.json clears this)"))
        XCTAssertEqual(TreeSnapshot(of: directory).excluding("state.json"), before)
        XCTAssertEqual(prepare.removed, [])
        XCTAssertEqual(commit.effectCount, 0)
    }

    /// A copy that does not hold the lock reads everything and changes nothing — not even with a
    /// crash-loop marker, a finished hand-off, a mounted image, stale downloads and a staging
    /// folder all waiting.
    func testACopyWithoutTheLockChangesNothing() async throws {
        let (store, directory) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        var state = SwitcherUpdateState()
        state.staging = [UpdateFixture.staging]
        state.lastInstall = InstallRecord(from: v070, to: v080, at: now, oldCopy: nil, tag: "v0.8.0", digest: UpdateFixture.digest)
        try await store.save(state)
        let before = TreeSnapshot(of: directory)

        let prepare = FakePrepare()
        prepare.otherImages = [AttachedImage(imagePath: UpdateFixture.dmg("v0.7.0"), devices: ["/dev/disk3"])]
        prepare.directories = [UpdateFixture.updates + "/downloads": [DirectoryEntry(name: "v0.7.0", kind: .directory)],
                               UpdateFixture.staging: [DirectoryEntry(name: "Claude Switcher.app", kind: .directory)],
                               UpdateFixture.updates + "/previous": [DirectoryEntry(name: "0.6.0", kind: .directory),
                                                                     DirectoryEntry(name: "0.7.0", kind: .directory)]]
        let commit = FakeCommit()
        commit.bundles = [UpdateFixture.install: v080, UpdateFixture.previous(v070): v070]

        let report = await SwitcherUpdater.reconcileAtLaunch(context(holder: false, aborted: 2), store: store,
                                                             prepare: prepare.env, commit: commit.env)
        XCTAssertEqual(prepare.effectCount, 0)
        XCTAssertEqual(commit.effectCount, 0)
        XCTAssertEqual(commit.handoffs, [])
        XCTAssertEqual(TreeSnapshot(of: directory), before)
        XCTAssertEqual(report.handoff?.verdict, .succeeded, "still read, for Diagnostics")
        XCTAssertFalse(report.findings.isEmpty)
        XCTAssertNil(report.revert)
    }

    func testTheReconcileStepsAloneDoNothingWithoutTheLock() {
        let prepare = FakePrepare()
        prepare.otherImages = [AttachedImage(imagePath: UpdateFixture.dmg("v0.7.0"), devices: ["/dev/disk3"])]
        prepare.directories = [UpdateFixture.updates + "/downloads": [DirectoryEntry(name: "v0.7.0", kind: .directory)]]
        var state = SwitcherUpdateState()
        state.staging = [UpdateFixture.staging]
        let findings = SwitcherUpdater.reconcile(state: &state, isLockHolder: false, updatesDirectory: UpdateFixture.updates,
                                                 temporaryItems: UpdateFixture.temporaryItems,
                                                 running: UpdateFixture.runningCopy(), env: prepare.env)
        XCTAssertEqual(prepare.effectCount, 0)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(state.staging, [UpdateFixture.staging])
    }

    // MARK: - The crash-loop guard (9.5)

    private func revertWorld() -> FakeCommit {
        let commit = FakeCommit()
        commit.bundles = [UpdateFixture.install: v080, UpdateFixture.previous(v070): v070]
        return commit
    }

    private func marker(_ store: SwitcherUpdateStore, version: ReleaseVersion, count: Int,
                        host: String = UpdateFixture.host) async throws {
        try await store.writeMarker(StartMarker(version: version, host: host, installPath: UpdateFixture.install,
                                                count: count, at: now))
    }

    func testTwoAbortedStartsGoBackToThePreviousCopyOnceAndTheNextStartSaysSo() async throws {
        let (store, _) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        try await marker(store, version: v080, count: 2)
        let aborted = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        XCTAssertEqual(aborted, 2)

        let commit = revertWorld()
        commit.handoffSink = { try? await store.writeHandoff($0) }
        let prepare = FakePrepare()
        let report = await SwitcherUpdater.reconcileAtLaunch(context(aborted: aborted), store: store,
                                                             prepare: prepare.env, commit: commit.env)
        XCTAssertEqual(report.revert, .launched(4300))
        XCTAssertEqual(commit.swaps, ["\(UpdateFixture.previous(v070)) <-> \(UpdateFixture.install)"])
        XCTAssertEqual(commit.launches, [UpdateFixture.install])
        XCTAssertEqual(commit.terminated, 1)
        XCTAssertEqual(prepare.removed, [])

        // The previous version starts and finishes the revert's record.
        let next = try await store.recordStart(version: v070, installPath: UpdateFixture.install, now: now)
        XCTAssertEqual(next, 0)
        let after = FakeCommit()
        let finished = await SwitcherUpdater.reconcileAtLaunch(context(running: v070, aborted: next), store: store,
                                                               prepare: FakePrepare().env, commit: after.env)
        XCTAssertEqual(finished.state.notice?.text, SwitcherUpdateText.reverted(bad: v080, back: v070))
        XCTAssertTrue(finished.state.isRejected(tag: "v0.8.0", digest: UpdateFixture.digest))
        XCTAssertEqual(after.effectCount, 0)
    }

    /// The record of the update survives a first start that never got going, so two such starts
    /// go back even though the first one already finished the record.
    func testTwoStartsThatNeverGetGoingGoBackEvenAfterTheFirstFinishedTheRecord() async throws {
        let (store, _) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        var aborted = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        let first = await SwitcherUpdater.reconcileAtLaunch(context(aborted: aborted), store: store,
                                                            prepare: FakePrepare().env, commit: revertWorld().env)
        XCTAssertEqual(first.handoff?.verdict, .succeeded)
        XCTAssertNil(first.revert)

        // It ends within the minute: no settle. The next start counts one.
        aborted = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        XCTAssertEqual(aborted, 1)
        let second = await SwitcherUpdater.reconcileAtLaunch(context(aborted: aborted), store: store,
                                                             prepare: FakePrepare().env, commit: revertWorld().env)
        XCTAssertNil(second.revert)

        aborted = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        XCTAssertEqual(aborted, 2)
        let commit = revertWorld()
        let third = await SwitcherUpdater.reconcileAtLaunch(context(aborted: aborted), store: store,
                                                            prepare: FakePrepare().env, commit: commit.env)
        XCTAssertEqual(third.revert, .launched(4300))
        XCTAssertEqual(commit.swaps, ["\(UpdateFixture.previous(v070)) <-> \(UpdateFixture.install)"])
    }

    /// Once a start of the new version has got going, the record goes, and with it the way back:
    /// two quick restarts weeks later — a logout, a force quit — never send a good release back,
    /// whatever `state.json` remembers of its install.
    func testAVersionThatHasStartedOnceIsNeverSentBack() async throws {
        let (store, directory) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        let aborted = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        _ = await SwitcherUpdater.reconcileAtLaunch(context(aborted: aborted), store: store,
                                                    prepare: FakePrepare().env, commit: revertWorld().env)
        try await store.settleStart(version: v080, isLockHolder: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("handoff.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("starting.json").path))
        let remembered = await store.load(now: now).lastInstall
        XCTAssertEqual(remembered?.to, v080, "the install is still remembered, for Diagnostics")

        try await marker(store, version: v080, count: 2)
        let later = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        XCTAssertEqual(later, 2)
        let commit = revertWorld()
        let report = await SwitcherUpdater.reconcileAtLaunch(context(aborted: later), store: store,
                                                             prepare: FakePrepare().env, commit: commit.env)
        XCTAssertNil(report.revert)
        XCTAssertEqual(commit.effectCount, 0)
        XCTAssertEqual(commit.handoffs, [])
    }

    func testOneAbortedStartIsCountedAndNothingMoves() async throws {
        let (store, _) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        try await marker(store, version: v080, count: 1)
        let aborted = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        XCTAssertEqual(aborted, 1)
        let awaited1 = await store.loadMarker().value?.count
        XCTAssertEqual(awaited1, 2)
        let commit = revertWorld()
        let report = await SwitcherUpdater.reconcileAtLaunch(context(aborted: aborted), store: store,
                                                             prepare: FakePrepare().env, commit: commit.env)
        XCTAssertNil(report.revert)
        XCTAssertEqual(commit.effectCount, 0)
        XCTAssertEqual(report.handoff?.verdict, .succeeded)
    }

    func testAMarkerFromAnotherMacOrAnotherVersionCountsForNothing() async throws {
        let (store, _) = try store()
        try await marker(store, version: v080, count: 5, host: UpdateFixture.otherHost)
        let awaited2 = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        XCTAssertEqual(awaited2, 0)
        try await marker(store, version: v070, count: 5)
        let awaited3 = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        XCTAssertEqual(awaited3, 0)
        let awaited4 = await store.loadMarker().value?.count
        XCTAssertEqual(awaited4, 1)
        XCTAssertEqual(SwitcherUpdatePolicy.abortedStarts(marker: nil, version: v080, host: UpdateFixture.host), 0)
    }

    func testAPreviousCopyThatFailsVerificationIsNotSwappedInAndTheStartGoesOn() async throws {
        let (store, _) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        let commit = revertWorld()
        commit.invalidAt[UpdateFixture.previous(v070)] = SignatureRefusal(status: -67050, message: "not ours")
        let report = await SwitcherUpdater.reconcileAtLaunch(context(aborted: 2), store: store,
                                                             prepare: FakePrepare().env, commit: commit.env)
        XCTAssertEqual(commit.swaps, [])
        XCTAssertEqual(commit.launches, [])
        guard case .refusedBeforeSwap? = report.revert else { return XCTFail("\(String(describing: report.revert))") }
        XCTAssertEqual(report.handoff?.verdict, .succeeded, "the update record is still finished")
    }

    func testWithNoPreviousCopyThereIsNothingToGoBackTo() async throws {
        let (store, _) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        let commit = FakeCommit()
        commit.bundles = [UpdateFixture.install: v080]
        let report = await SwitcherUpdater.reconcileAtLaunch(context(aborted: 3), store: store,
                                                             prepare: FakePrepare().env, commit: commit.env)
        XCTAssertEqual(commit.effectCount, 0)
        XCTAssertTrue(report.findings.contains("0.8.0 did not start properly twice, and there is no previous copy to go back to"))
    }

    func testGoingBackWhoseLaunchFailsRejectsTheBadReleaseNow() async throws {
        let (store, _) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        let commit = revertWorld()
        commit.handoffSink = { try? await store.writeHandoff($0) }
        commit.launchResult = .failure(RelaunchFailure(reason: "it did not start within 60 seconds"))
        let report = await SwitcherUpdater.reconcileAtLaunch(context(aborted: 2), store: store,
                                                             prepare: FakePrepare().env, commit: commit.env)
        XCTAssertEqual(report.revert, .restartPending("it did not start within 60 seconds"))
        XCTAssertTrue(report.state.isRejected(tag: "v0.8.0", digest: UpdateFixture.digest))
        XCTAssertNil(report.handoff, "the revert's own record is left for the next start")
        let awaited5 = await store.loadHandoff().value?.kind
        XCTAssertEqual(awaited5, .revert)
    }

    func testAnotherMacsHandoffNeverDrivesARevert() async throws {
        let (store, _) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched, host: UpdateFixture.otherHost))
        let commit = revertWorld()
        _ = await SwitcherUpdater.reconcileAtLaunch(context(aborted: 2), store: store,
                                                    prepare: FakePrepare().env, commit: commit.env)
        XCTAssertEqual(commit.effectCount, 0)
    }

    func testAnAfterUpdateInstanceThatExitsTakesItsStartBack() async throws {
        let (store, directory) = try store()
        try await marker(store, version: v080, count: 1)
        _ = try await store.recordStart(version: v080, installPath: UpdateFixture.install, now: now)
        let awaited6 = await store.loadMarker().value?.count
        XCTAssertEqual(awaited6, 2)
        try await store.withdrawStart(version: v080)
        let awaited7 = await store.loadMarker().value?.count
        XCTAssertEqual(awaited7, 1)
        try await store.withdrawStart(version: v080)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("starting.json").path))
        try await marker(store, version: v070, count: 3)
        try await store.withdrawStart(version: v080)
        let awaited8 = await store.loadMarker().value?.count
        XCTAssertEqual(awaited8, 3, "another version's marker is not ours to change")
        // On a synced ~/.config: another Mac's count is not this Mac's to take back.
        try await marker(store, version: v080, count: 2, host: UpdateFixture.otherHost)
        try await store.withdrawStart(version: v080)
        let foreign = await store.loadMarker().value
        XCTAssertEqual(foreign?.count, 2)
        XCTAssertEqual(foreign?.host, UpdateFixture.otherHost)
    }

    // MARK: - Paths read from a record

    /// A tag read from `handoff.json` is a release tag or nothing: never a path handed to remove.
    func testATagReadFromTheHandoffIsNotAPathToRemove() async throws {
        var handoff = UpdateFixture.handoff(.launched)
        handoff.tag = "v0.8.0/../../previous"
        XCTAssertNil(finish(handoff, running: v080).deleteDownloadsFor)

        let (store, _) = try store()
        try await store.writeHandoff(handoff)
        let prepare = FakePrepare(), commit = FakeCommit()
        let report = await SwitcherUpdater.reconcileAtLaunch(context(), store: store, prepare: prepare.env, commit: commit.env)
        XCTAssertEqual(report.handoff?.verdict, .succeeded)
        XCTAssertEqual(prepare.removed, [])
        XCTAssertEqual(commit.effectCount, 0)
    }

    // MARK: - Writing back what the launch pass changed

    /// The pass reads `state.json`, works for a while — hdiutil, the folders — and writes back only
    /// what it changed: a check another copy recorded meanwhile keeps its time and its candidate.
    func testTheLaunchPassKeepsWhatAConcurrentCheckRecorded() async throws {
        let (store, directory) = try store()
        try await store.writeHandoff(UpdateFixture.handoff(.launched))
        var original = SwitcherUpdateState()
        original.lastCheckAt = now.addingTimeInterval(-3600)
        original.candidate = UpdateFixture.candidate()
        original.staging = [UpdateFixture.staging]
        try await store.save(original)

        let v081 = ReleaseVersion(major: 0, minor: 8, patch: 1)
        var concurrent = original
        concurrent.host = UpdateFixture.host
        concurrent.format = SwitcherUpdateState.currentFormat
        concurrent.lastCheckAt = now.addingTimeInterval(-60)
        concurrent.candidate = UpdateFixture.candidate(v081)
        let landing = concurrent
        let file = directory.appendingPathComponent("state.json")
        let prepare = FakePrepare(), commit = FakeCommit()
        var env = prepare.env
        let images = env.attachedImages
        let written = Names()
        env.attachedImages = {
            // Another copy's check lands while this pass asks hdiutil what is attached.
            if written.values.isEmpty, let data = try? SwitcherUpdateStore.encoder.encode(landing) {
                try? data.write(to: file, options: .atomic)
                written.append("state.json")
            }
            return images()
        }
        let report = await SwitcherUpdater.reconcileAtLaunch(context(), store: store, prepare: env, commit: commit.env)
        XCTAssertEqual(written.values, ["state.json"])

        let state = await store.load(now: now)
        XCTAssertEqual(state.lastCheckAt, now.addingTimeInterval(-60))
        XCTAssertEqual(state.candidate?.version, v081, "not cleared: the pass cleared only the release it installed")
        XCTAssertEqual(state.notice?.text, SwitcherUpdateText.updated(to: v080, at: now), "the pass's own change")
        XCTAssertEqual(state.lastInstall?.to, v080)
        XCTAssertEqual(state.installPath, UpdateFixture.install)
        XCTAssertEqual(report.state, state)
    }

    /// The merge, field by field: the pass's change where nobody else changed the field, the other
    /// writer's change where it did, and the pass's added rejections on top of anyone's.
    func testTheMergeTakesOnlyThePassesOwnChanges() {
        let rejection = Rejection(tag: "v0.8.0", digestHex: UpdateFixture.digest, reason: "x", at: now)
        let other = Rejection(tag: "v0.7.5", digestHex: UpdateFixture.digest, reason: "y", at: now)
        var original = SwitcherUpdateState()
        original.staging = [UpdateFixture.staging]
        original.mounted = "/x"
        original.prepared = UpdateFixture.prepared()
        var reconciled = original
        reconciled.staging = nil
        reconciled.mounted = nil
        reconciled.notice = SwitcherNotice(text: "updated")
        reconciled.rejected = [rejection]
        reconciled.installPath = UpdateFixture.install
        var fresh = original
        fresh.mounted = "/y"
        fresh.rejected = [other]
        fresh.lastCheckAt = now
        SwitcherUpdater.merge(reconciled, readAt: original, onto: &fresh)
        XCTAssertNil(fresh.staging, "changed by the pass alone")
        XCTAssertEqual(fresh.mounted, "/y", "changed by the other writer: theirs stands")
        XCTAssertEqual(fresh.notice?.text, "updated")
        XCTAssertEqual(fresh.rejected, [other, rejection])
        XCTAssertEqual(fresh.lastCheckAt, now)
        XCTAssertEqual(fresh.installPath, UpdateFixture.install)
        XCTAssertNil(fresh.prepared)

        // A staging folder another copy put on record while the pass ran stays; the one the pass
        // dealt with goes.
        let theirs = UpdateFixture.temporaryItems + "/NSIRD_claude-switcher_OTHER"
        var meanwhile = original
        meanwhile.staging = [UpdateFixture.staging, theirs]
        SwitcherUpdater.merge(reconciled, readAt: original, onto: &meanwhile)
        XCTAssertEqual(meanwhile.staging, [theirs])
    }

    /// Every folder named is dealt with on its own: ours is tidied, another is left and named, a
    /// gone one drops off the record.
    func testEachStagingFolderNamedIsDealtWithOnItsOwn() {
        let theirs = UpdateFixture.temporaryItems + "/NSIRD_claude-switcher_OTHER"
        let notOurs = "/Users/testhome/Documents"
        let gone = UpdateFixture.temporaryItems + "/NSIRD_claude-switcher_GONE"
        let prepare = FakePrepare()
        prepare.directories = [UpdateFixture.staging: [DirectoryEntry(name: SwitcherDisk.appName, kind: .directory)],
                               theirs: [DirectoryEntry(name: SwitcherDisk.appName, kind: .directory)],
                               notOurs: [DirectoryEntry(name: SwitcherDisk.appName, kind: .directory)]]
        prepare.kinds = [UpdateFixture.staged: .directory, theirs + "/" + SwitcherDisk.appName: .directory]
        prepare.bundleIdentifiers = [UpdateFixture.staged: UpdateFixture.bundleID,
                                     theirs + "/" + SwitcherDisk.appName: UpdateFixture.bundleID]
        var state = SwitcherUpdateState()
        state.staging = [UpdateFixture.staging, notOurs, gone, theirs]
        let findings = SwitcherUpdater.reconcile(state: &state, isLockHolder: true, updatesDirectory: UpdateFixture.updates,
                                                 temporaryItems: UpdateFixture.temporaryItems,
                                                 running: UpdateFixture.runningCopy(), env: prepare.env)
        XCTAssertEqual(prepare.trashed, [UpdateFixture.staged, theirs + "/" + SwitcherDisk.appName])
        XCTAssertEqual(prepare.removedFolders, [UpdateFixture.staging, theirs])
        XCTAssertEqual(state.staging, [notOurs])
        XCTAssertTrue(findings.contains("a folder is left at \(notOurs) (not ours to remove)"), "\(findings)")

        var shown = SwitcherUpdateState()
        shown.staging = [UpdateFixture.staging, theirs]
        let read = SwitcherUpdater.reconcile(state: &shown, isLockHolder: false, updatesDirectory: UpdateFixture.updates,
                                             temporaryItems: UpdateFixture.temporaryItems,
                                             running: UpdateFixture.runningCopy(), env: FakePrepare().env)
        XCTAssertEqual(read.count, 2, "each named for Diagnostics by a copy without the lock")
        XCTAssertEqual(shown.staging, [UpdateFixture.staging, theirs])
    }

    // MARK: - What a crash left in updates/

    func testTemporaryFilesACrashLeftAreSweptAndNothingElse() async throws {
        let (store, directory) = try store()
        let names = [".state.json.\(UUID().uuidString).tmp", ".handoff.json.\(UUID().uuidString).tmp",
                     "notes.txt", ".state.json.tmp", "state.json.\(UUID().uuidString).tmp"]
        for name in names { try Data("x".utf8).write(to: directory.appendingPathComponent(name)) }
        _ = await SwitcherUpdater.reconcileAtLaunch(context(), store: store, prepare: FakePrepare().env,
                                                    commit: FakeCommit().env)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(left, Set(names.suffix(3) + ["state.json"]))

        // A copy without the lock sweeps nothing.
        let (other, otherDirectory) = try self.store()
        try Data("x".utf8).write(to: otherDirectory.appendingPathComponent(names[0]))
        _ = await SwitcherUpdater.reconcileAtLaunch(context(holder: false), store: other, prepare: FakePrepare().env,
                                                    commit: FakeCommit().env)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherDirectory.appendingPathComponent(names[0]).path))
    }

    // MARK: - Another copy checking at the same time

    /// While another copy holds the prepare lock, the launch pass detaches nothing and removes
    /// nothing under downloads/: that copy may be verifying what is there.
    func testTheLaunchPassLeavesDownloadsAndImagesAloneWhileAnotherCopyChecks() {
        let prepare = FakePrepare()
        prepare.prepareLockHeld = true
        prepare.otherImages = [AttachedImage(imagePath: UpdateFixture.dmg("v0.7.0"), devices: ["/dev/disk3"])]
        prepare.directories = [UpdateFixture.updates + "/downloads": [DirectoryEntry(name: "v0.7.0", kind: .directory)]]
        var state = SwitcherUpdateState()
        state.mounted = UpdateFixture.mountPoint
        let findings = SwitcherUpdater.reconcile(state: &state, isLockHolder: true, updatesDirectory: UpdateFixture.updates,
                                                 temporaryItems: UpdateFixture.temporaryItems,
                                                 running: UpdateFixture.runningCopy(), env: prepare.env)
        XCTAssertEqual(prepare.detached, [])
        XCTAssertEqual(prepare.removed, [])
        XCTAssertEqual(state.mounted, UpdateFixture.mountPoint)
        XCTAssertTrue(findings.contains("another Claude Switcher is checking for updates; downloads and disk images are left for now"))

        let free = FakePrepare()
        free.otherImages = prepare.otherImages
        free.directories = prepare.directories
        var tidied = SwitcherUpdateState()
        _ = SwitcherUpdater.reconcile(state: &tidied, isLockHolder: true, updatesDirectory: UpdateFixture.updates,
                                      temporaryItems: UpdateFixture.temporaryItems,
                                      running: UpdateFixture.runningCopy(), env: free.env)
        XCTAssertEqual(free.detached, ["/dev/disk3"])
        XCTAssertEqual(free.removed, [UpdateFixture.updates + "/downloads/v0.7.0"])
        XCTAssertEqual(free.lockTakes, free.lockReleases)
    }
}

// MARK: - On a real tree

/// The staging-folder rule and the tidy-up, on real folders in a temporary directory: real
/// `lstat`, `realpath`, listings, renames and the real removal scope. The Trash is a folder in
/// the temporary directory, and no process is started.
final class SwitcherReconcileTreeTests: XCTestCase {

    private var root: URL!
    private var updates: String { root.appendingPathComponent("cfg/claude-switcher/updates").path }
    private var temporaryItems: String { root.appendingPathComponent("T/TemporaryItems").path }
    private var trashFolder: String { root.appendingPathComponent("Trash").path }
    private let running = UpdateFixture.runningCopy(version: UpdateFixture.v080)
    private let effects = Names()

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: SwitcherDisk.realpath(base.path)!)
        for folder in [updates + "/downloads", updates + "/mounts", updates + "/previous", temporaryItems, trashFolder] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        // The folder as the app leaves it: the prepare lock's file is there from the first check.
        FileManager.default.createFile(atPath: updates + "/" + PrepareLock.fileName, contents: nil)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundle(at path: String, identifier: String = UpdateFixture.bundleID,
                            version: ReleaseVersion = UpdateFixture.v070) throws {
        let contents = path + "/Contents"
        try FileManager.default.createDirectory(atPath: contents + "/MacOS", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version.description]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: contents + "/Info.plist"))
        try Data("binary".utf8).write(to: URL(fileURLWithPath: contents + "/MacOS/claude-switcher"))
    }

    /// The live environment, with signatures read from the plist, the Trash a local folder, no
    /// process runner, and every effect recorded.
    private func env() -> SwitcherUpdater.PrepareEnvironment {
        let (store, _) = (SwitcherUpdateStore(directory: URL(fileURLWithPath: updates), host: UpdateFixture.host), ())
        var env = SwitcherUpdater.PrepareEnvironment.live(
            updatesDirectory: URL(fileURLWithPath: updates), store: store, registry: StagedCopies(),
            run: { _, _ in .couldNotStart("no processes in this test") }, pause: { _ in })
        let effects = self.effects, trashFolder = self.trashFolder, updates = self.updates
        // Recorded always; carried out only inside this test's own folder, whatever is asked.
        let inside = root.path + "/"
        let trash: @Sendable (String) -> Result<String, FileError> = { path in
            effects.append("trash \(path)")
            guard path.hasPrefix(inside) else { return .failure(FileError(EPERM)) }
            let destination = trashFolder + "/" + UUID().uuidString
            return rename(path, destination) == 0 ? .success(destination) : .failure(FileError(errno))
        }
        let remove = env.remove
        env.remove = { path in
            effects.append("remove \(path)")
            return path.hasPrefix(inside) ? remove(path) : false
        }
        env.trash = trash
        env.moveToPrevious = { bundle, version in
            effects.append("previous \(bundle)")
            guard bundle.hasPrefix(inside) else { return .failure(FileError(EPERM)) }
            return SwitcherDisk.moveToPrevious(bundle, version: version, updatesDirectory: updates, trash: trash)
        }
        let removeEmpty = env.removeEmptyFolder
        env.removeEmptyFolder = { path in
            effects.append("rmdir \(path)")
            if path.hasPrefix(inside) { removeEmpty(path) }
        }
        env.detach = { device in effects.append("detach \(device)"); return false }
        env.verify = { path, _ in
            let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
            let version = (plist?["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init(string:))
            return .success(UpdateFixture.identity(version))
        }
        return env
    }

    private func reconcile(staging: String?, candidate: ReleaseCandidate? = nil) -> (SwitcherUpdateState, [String]) {
        var state = SwitcherUpdateState()
        state.staging = staging.map { [$0] }
        state.candidate = candidate
        let findings = SwitcherUpdater.reconcile(state: &state, isLockHolder: true, updatesDirectory: updates,
                                                 temporaryItems: temporaryItems, running: running, env: env())
        return (state, findings)
    }

    private var movesTrashesOrRemovals: [String] {
        effects.values.filter { $0.hasPrefix("trash ") || $0.hasPrefix("previous ") || $0.hasPrefix("remove ") }
    }

    // MARK: - (f) a staging folder named in state.json

    func testAStagingPathThatIsNotAnNSIRDFolderIsNeverTouched() throws {
        let documents = root.appendingPathComponent("Documents").path
        try FileManager.default.createDirectory(atPath: documents + "/Claude Switcher.app", withIntermediateDirectories: true)
        let claude = root.appendingPathComponent("Applications/Claude.app").path
        try makeBundle(at: claude, identifier: "com.anthropic.claudefordesktop")
        let notNamedSo = temporaryItems + "/Claude Switcher-folder"
        try makeBundle(at: notNamedSo + "/Claude Switcher.app")
        for staging in ["/Applications/Claude.app", NSHomeDirectory() + "/Documents", documents, claude,
                        root.appendingPathComponent("Applications").path, notNamedSo] {
            let before = TreeSnapshot(of: root)
            let (state, findings) = reconcile(staging: staging)
            XCTAssertEqual(movesTrashesOrRemovals, [], staging)
            XCTAssertEqual(TreeSnapshot(of: root), before, staging)
            if FileManager.default.fileExists(atPath: staging) {
                XCTAssertEqual(state.staging, [staging])
                XCTAssertTrue(findings.contains("a folder is left at \(staging) (not ours to remove)"), staging)
            }
        }
    }

    func testALinkToAnNSIRDFolderIsNeverFollowed() throws {
        let real = temporaryItems + "/NSIRD_claude-switcher_real"
        try makeBundle(at: real + "/Claude Switcher.app")
        let link = temporaryItems + "/NSIRD_claude-switcher_link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let before = TreeSnapshot(of: root)
        _ = reconcile(staging: link)
        XCTAssertEqual(movesTrashesOrRemovals, [])
        XCTAssertEqual(TreeSnapshot(of: root), before)
    }

    func testAnNSIRDFolderThatHoldsAnythingElseIsLeftAlone() throws {
        let cases: [(String, (String) throws -> Void)] = [
            ("two entries", { folder in
                try self.makeBundle(at: folder + "/Claude Switcher.app")
                try Data().write(to: URL(fileURLWithPath: folder + "/notes.txt"))
            }),
            ("another app", { folder in try self.makeBundle(at: folder + "/Claude Switcher.app",
                                                            identifier: "com.example.other") }),
            ("another name", { folder in try self.makeBundle(at: folder + "/Claude.app") }),
            ("the app is a link", { folder in
                try self.makeBundle(at: self.root.appendingPathComponent("elsewhere/Claude Switcher.app").path)
                try FileManager.default.createSymbolicLink(atPath: folder + "/Claude Switcher.app",
                                                           withDestinationPath: self.root.appendingPathComponent("elsewhere/Claude Switcher.app").path)
            }),
            ("empty", { _ in }),
        ]
        for (name, populate) in cases {
            let folder = temporaryItems + "/NSIRD_claude-switcher_\(UUID().uuidString.prefix(6))"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try populate(folder)
            let before = TreeSnapshot(of: root)
            let (state, _) = reconcile(staging: folder)
            XCTAssertEqual(movesTrashesOrRemovals, [], name)
            XCTAssertEqual(TreeSnapshot(of: root), before, name)
            XCTAssertEqual(state.staging, [folder], name)
        }
    }

    func testAnNSIRDFolderOutsideTemporaryItemsIsLeftAlone() throws {
        let folder = root.appendingPathComponent("T/Other/NSIRD_claude-switcher_x").path
        try makeBundle(at: folder + "/Claude Switcher.app")
        let before = TreeSnapshot(of: root)
        _ = reconcile(staging: folder)
        XCTAssertEqual(movesTrashesOrRemovals, [])
        XCTAssertEqual(TreeSnapshot(of: root), before)
    }

    /// The one case that is acted on: the bundle is moved — the same inode, under previous/ —
    /// never removed, and the emptied folder is `rmdir`'d.
    func testOurOwnNSIRDFolderHasItsOlderCopyMovedToPreviousAndIsRemovedOnlyWhenEmpty() throws {
        let folder = temporaryItems + "/NSIRD_claude-switcher_ours"
        try makeBundle(at: folder + "/Claude Switcher.app", version: UpdateFixture.v070)
        let before = TreeSnapshot(of: root)
        let (state, findings) = reconcile(staging: folder)

        let kept = updates + "/previous/0.7.0/Claude Switcher.app"
        XCTAssertEqual(movesTrashesOrRemovals, ["previous \(folder)/Claude Switcher.app"])
        XCTAssertTrue(effects.values.contains("rmdir \(folder)"))
        XCTAssertNil(state.staging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
        XCTAssertEqual(findings, ["moved a copy left in a temporary folder to \(kept)"])
        let relative = "T/TemporaryItems/NSIRD_claude-switcher_ours/Claude Switcher.app"
        let movedPath = "cfg/claude-switcher/updates/previous/0.7.0/Claude Switcher.app"
        XCTAssertEqual(TreeSnapshot(of: root).entry(movedPath + "/Contents/MacOS/claude-switcher")?.inode,
                       before.entry(relative + "/Contents/MacOS/claude-switcher")?.inode)
    }

    func testANewerCopyLeftInStagingWasNeverInstalledAndGoesToTheTrash() throws {
        let folder = temporaryItems + "/NSIRD_claude-switcher_newer"
        try makeBundle(at: folder + "/Claude Switcher.app", version: ReleaseVersion(major: 0, minor: 9, patch: 0))
        _ = reconcile(staging: folder)
        XCTAssertEqual(movesTrashesOrRemovals, ["trash \(folder)/Claude Switcher.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: updates + "/previous/0.9.0"))
    }

    // MARK: - (e) downloads, and the removal scope

    func testStaleDownloadsAndPartialFilesGoAndTheCandidatesImageStays() throws {
        let downloads = updates + "/downloads"
        for path in [downloads + "/v0.7.0/Claude.Switcher.dmg", downloads + "/v0.8.0/Claude.Switcher.dmg",
                     downloads + "/v0.8.0/Claude.Switcher.dmg.partial", downloads + "/stray.txt"] {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        }
        _ = reconcile(staging: nil, candidate: UpdateFixture.candidate())
        let left = TreeSnapshot(of: URL(fileURLWithPath: downloads)).paths
        XCTAssertEqual(left, ["v0.8.0", "v0.8.0/Claude.Switcher.dmg"])
    }

    /// A link inside downloads/ that leads out of it: the link may not be followed to remove
    /// what it points at.
    func testTheRemovalScopeRefusesWhatALinkInDownloadsPointsAt() throws {
        let victim = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: victim.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(atPath: updates + "/downloads/v0.7.0",
                                                   withDestinationPath: victim.path)
        let before = TreeSnapshot(of: victim)
        _ = reconcile(staging: nil)
        XCTAssertEqual(TreeSnapshot(of: victim), before)
    }

    /// If `updates` itself is a link, nothing it leads to is the updater's to remove.
    func testNothingIsRemovedWhenTheUpdatesFolderIsALink() throws {
        let victim = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(atPath: victim.path + "/downloads/v0.7.0", withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: victim.appendingPathComponent("downloads/v0.7.0/Claude.Switcher.dmg"))
        let linkedUpdates = root.appendingPathComponent("cfg2/claude-switcher/updates").path
        try FileManager.default.createDirectory(atPath: (linkedUpdates as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkedUpdates, withDestinationPath: victim.path)
        let scope = RemovalScope(updatesDirectory: linkedUpdates, registry: StagedCopies())
        let before = TreeSnapshot(of: victim)
        XCTAssertFalse(scope.remove(linkedUpdates + "/downloads/v0.7.0"))
        XCTAssertNil(scope.resolve(linkedUpdates + "/downloads/v0.7.0/Claude.Switcher.dmg"))
        XCTAssertEqual(TreeSnapshot(of: victim), before)
    }

    func testTheRemovalScopeAllowsOnlyItsOwnFoldersAndAnUnswappedStagedCopy() throws {
        let registry = StagedCopies()
        let scope = RemovalScope(updatesDirectory: updates, registry: registry)
        try Data("x".utf8).write(to: URL(fileURLWithPath: updates + "/downloads/a"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: updates + "/state.json"))
        try FileManager.default.createDirectory(atPath: updates + "/previous/0.7.0/Claude Switcher.app",
                                                withIntermediateDirectories: true)
        XCTAssertNotNil(scope.resolve(updates + "/downloads/a"))
        XCTAssertNil(scope.resolve(updates + "/downloads"))
        XCTAssertNil(scope.resolve(updates + "/state.json"))
        XCTAssertNil(scope.resolve(updates + "/previous/0.7.0/Claude Switcher.app"))
        XCTAssertNil(scope.resolve(updates + "/downloads/../previous/0.7.0"))
        XCTAssertNil(scope.resolve("/Applications/Claude.app"))

        // A staged copy is removable from when it is copied until it is swapped.
        let staging = temporaryItems + "/NSIRD_claude-switcher_stage"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.app").path
        try makeBundle(at: source)
        let staged = staging + "/Claude Switcher.app"
        XCTAssertNil(SwitcherDisk.copyBundle(from: source, to: staged, registry: registry))
        XCTAssertNotNil(scope.resolve(staged))
        let installed = root.appendingPathComponent("Applications/Claude Switcher.app").path
        try makeBundle(at: installed)
        XCTAssertEqual(SwitcherDisk.swap(staged, installed, registry: registry), 0)
        XCTAssertNil(scope.resolve(staged), "after the swap the staged path holds the installed copy")
        XCTAssertNil(scope.resolve(installed))
        XCTAssertFalse(scope.remove(staged))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged))
    }

    /// The real prepare environment's only recursive removal is the removal scope: a link in
    /// downloads/ that leads out of it is not followed to what it points at.
    func testTheLivePrepareRemovesOnlyThroughTheRemovalScope() throws {
        let victim = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("Claude.Switcher.dmg"))
        try FileManager.default.createSymbolicLink(atPath: updates + "/downloads/v0.8.0", withDestinationPath: victim.path)
        let env = SwitcherUpdater.PrepareEnvironment.live(
            updatesDirectory: URL(fileURLWithPath: updates),
            store: SwitcherUpdateStore(directory: URL(fileURLWithPath: updates), host: UpdateFixture.host),
            registry: StagedCopies(), run: { _, _ in .couldNotStart("none") }, pause: { _ in })
        XCTAssertFalse(env.remove(updates + "/downloads/v0.8.0/Claude.Switcher.dmg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.appendingPathComponent("Claude.Switcher.dmg").path))

        try Data("x".utf8).write(to: URL(fileURLWithPath: updates + "/downloads/stale.dmg"))
        XCTAssertTrue(env.remove(updates + "/downloads/stale.dmg"), "its own folder is removable")
        XCTAssertTrue(env.remove(updates + "/downloads/stale.dmg"), "and nothing there is gone already")
    }

    /// Something already at the staging path is never registered as this process's staged copy,
    /// so it can never be removed as one.
    func testAnExistingDestinationIsNeverMadeRemovable() throws {
        let registry = StagedCopies()
        let existing = temporaryItems + "/NSIRD_claude-switcher_taken/Claude Switcher.app"
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: existing + "/file"))
        let source = root.appendingPathComponent("source.app").path
        try makeBundle(at: source)
        XCTAssertNotNil(SwitcherDisk.copyBundle(from: source, to: existing, registry: registry))
        let scope = RemovalScope(updatesDirectory: updates, registry: registry)
        XCTAssertNil(scope.resolve(existing))
        XCTAssertFalse(scope.remove(existing))
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing + "/file"))
    }

    /// What a copy that cannot be made says follows the naming rule (design 11.3): a temporary
    /// folder for the new version — never a "staging" folder or an "installed" copy.
    func testACopyThatCannotBeMadeSaysSoInPlainWords() throws {
        let source = root.appendingPathComponent("source.app").path
        try makeBundle(at: source)
        let taken = temporaryItems + "/NSIRD_claude-switcher_taken/Claude Switcher.app"
        try FileManager.default.createDirectory(atPath: taken, withIntermediateDirectories: true)
        let missing = temporaryItems + "/NSIRD_claude-switcher_missing/Claude Switcher.app"
        let reasons = [taken, missing].map { SwitcherDisk.copyBundle(from: source, to: $0, registry: StagedCopies())?.reason }
        XCTAssertEqual(reasons, ["the temporary folder for the new version is not empty",
                                 "the temporary folder for the new version is gone"])
    }

    /// A staged copy with read-only folders — a release built from read-only resources — is still
    /// removed by the process that made it.
    func testAReadOnlyStagedCopyIsStillRemovedByTheProcessThatMadeIt() throws {
        let registry = StagedCopies()
        let staging = temporaryItems + "/NSIRD_claude-switcher_readonly"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.app").path
        try makeBundle(at: source)
        try FileManager.default.createDirectory(atPath: source + "/Contents/Resources/locked", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: source + "/Contents/Resources/locked/file"))
        let staged = staging + "/Claude Switcher.app"
        XCTAssertNil(SwitcherDisk.copyBundle(from: source, to: staged, registry: registry))
        for folder in [staged + "/Contents/Resources/locked", staged + "/Contents/Resources"] {
            XCTAssertEqual(chmod(folder, 0o555), 0)
        }
        defer { _ = chmod(staged + "/Contents/Resources", 0o755); _ = chmod(staged + "/Contents/Resources/locked", 0o755) }
        XCTAssertTrue(RemovalScope(updatesDirectory: updates, registry: registry).remove(staged))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged))

        // Only its own staged copy: anything else read-only stays exactly as it is.
        let other = root.appendingPathComponent("other").path
        try FileManager.default.createDirectory(atPath: other + "/inner", withIntermediateDirectories: true)
        XCTAssertEqual(chmod(other, 0o555), 0)
        defer { _ = chmod(other, 0o755) }
        XCTAssertFalse(RemovalScope(updatesDirectory: updates, registry: registry).remove(other + "/inner"))
        var info = stat()
        XCTAssertEqual(lstat(other, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o555)
    }

    // MARK: - (g) one previous copy

    func testOnlyTheNewestPreviousCopyIsKeptAndTheOthersAreTrashedNotRemoved() throws {
        for version in ["0.5.0", "0.6.0", "0.7.0"] {
            try makeBundle(at: updates + "/previous/\(version)/Claude Switcher.app",
                           version: ReleaseVersion(string: version)!)
        }
        try FileManager.default.createDirectory(atPath: updates + "/previous/keep-me", withIntermediateDirectories: true)
        _ = reconcile(staging: nil)
        XCTAssertEqual(Set(movesTrashesOrRemovals), ["trash \(updates)/previous/0.5.0", "trash \(updates)/previous/0.6.0"])
        let left = try FileManager.default.contentsOfDirectory(atPath: updates + "/previous").sorted()
        XCTAssertEqual(left, ["0.7.0", "keep-me"])
    }

    func testMovingToPreviousKeepsOneVersionAndTrashesTheOlderOne() throws {
        try makeBundle(at: updates + "/previous/0.6.0/Claude Switcher.app", version: UpdateFixture.v060)
        let old = root.appendingPathComponent("old/Claude Switcher.app").path
        try makeBundle(at: old)
        let trashed = Names()
        let trashFolder = self.trashFolder
        let result = SwitcherDisk.moveToPrevious(old, version: UpdateFixture.v070, updatesDirectory: updates) { path in
            trashed.append(path)
            let destination = trashFolder + "/" + UUID().uuidString
            return rename(path, destination) == 0 ? .success(destination) : .failure(FileError(errno))
        }
        XCTAssertEqual(try result.get(), updates + "/previous/0.7.0/Claude Switcher.app")
        XCTAssertEqual(trashed.values, [updates + "/previous/0.6.0"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updates + "/previous"), ["0.7.0"])
    }
}
