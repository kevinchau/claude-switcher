import XCTest
@testable import ClaudeSwitcherCore

/// Swap and relaunch — section 8 — against `FakeCommit`. Nothing is moved, registered, launched
/// or terminated: every effect is a recorded closure, and time is virtual.
final class SwitcherCommitTests: XCTestCase {

    private let trust = UpdateFixture.trust
    private let install = UpdateFixture.install
    private let staged = UpdateFixture.staged

    private func commit(_ fake: FakeCommit, running: RunningCopy = UpdateFixture.runningCopy(),
                        claudeAppPath: String = UpdateFixture.claudeApp, userAsked: Bool = false) async -> CommitOutcome {
        await SwitcherUpdater.commit(prepared: UpdateFixture.prepared(), running: running, trust: trust,
                                     claudeAppPath: claudeAppPath, userAsked: userAsked, env: fake.env)
    }

    private func refusedBeforeSwap(_ outcome: CommitOutcome, file: StaticString = #filePath, line: UInt = #line) -> Refusal? {
        guard case .refusedBeforeSwap(let refusal) = outcome else {
            XCTFail("expected a refusal before the swap, got \(outcome)", file: file, line: line)
            return nil
        }
        return refusal
    }

    // MARK: - The whole way

    func testASuccessfulCommitSwapsRelaunchesKeepsTheOldCopyAndEnds() async throws {
        let fake = FakeCommit()
        let outcome = await commit(fake)

        XCTAssertEqual(outcome, .launched(4300))
        XCTAssertEqual(fake.steps, [.proveTarget, .versions, .reverify, .idleRecheck, .handoff, .swap, .verifyInstalled,
                                    .register, .relaunch, .oldCopy, .launched])
        XCTAssertEqual(fake.swaps, ["\(staged) <-> \(install)"])
        XCTAssertEqual(fake.bundles[install], UpdateFixture.v080)
        XCTAssertEqual(fake.registered, [install])
        XCTAssertEqual(fake.launches, [install])
        XCTAssertEqual(fake.moved, [staged], "the old copy goes from staging to previous/, never the installed one")
        XCTAssertEqual(fake.bundles[UpdateFixture.previous(UpdateFixture.v070)], UpdateFixture.v070)
        XCTAssertEqual(fake.removed, [])
        XCTAssertEqual(fake.terminated, 1)
        XCTAssertEqual(fake.handoffs.map(\.phase), [.swapping, .swapped, .launched])
        XCTAssertEqual(fake.handoffs.last?.newPid, 4300)
        XCTAssertEqual(fake.handoffs.last?.oldCopy, OldCopy(kind: .previous, path: UpdateFixture.previous(UpdateFixture.v070)))
        XCTAssertEqual(fake.handoffs.first?.oldPid, 4242)
        XCTAssertEqual(fake.handoffs.first?.launchAtLoginWasEnabled, true)
        XCTAssertEqual(fake.handoffs.first?.host, UpdateFixture.host)
        XCTAssertEqual(fake.removedFolders, [UpdateFixture.staging])
        // C3 and C6 hold the copy to this developer's notarized app, by this copy's own signature.
        XCTAssertGreaterThanOrEqual(fake.requirements.count, 2)
        XCTAssertEqual(Set(fake.requirements), [try trust.appRequirement()])
    }

    /// The record of what is about to happen is on disk before anything moves, and the process
    /// ends only once the record says the new copy is running.
    func testTheHandoffIsWrittenBeforeTheSwapAndTerminateComesLast() async throws {
        let fake = FakeCommit()
        _ = await commit(fake)
        let swapping = try XCTUnwrap(fake.events.firstIndex(of: "handoff update swapping"))
        let swap = try XCTUnwrap(fake.events.firstIndex { $0.hasPrefix("swap ") })
        let launched = try XCTUnwrap(fake.events.firstIndex(of: "handoff update launched"))
        let terminate = try XCTUnwrap(fake.events.firstIndex(of: "terminate"))
        XCTAssertLessThan(swapping, swap)
        XCTAssertLessThan(launched, terminate)
        XCTAssertEqual(terminate, fake.events.count - 1)
    }

    func testAHandoffThatCannotBeWrittenStopsBeforeTheSwap() async {
        let fake = FakeCommit()
        fake.handoffRefusal = Refusal(kind: .transient, step: "C4", reason: "could not write handoff.json")
        let outcome = await commit(fake)
        XCTAssertNotNil(refusedBeforeSwap(outcome))
        XCTAssertEqual(fake.swaps, [])
        XCTAssertEqual(fake.removed, [staged])
    }

    // MARK: - C1: the target is proven to be this copy

    private func refusesAtC1(_ fake: FakeCommit, running: RunningCopy = UpdateFixture.runningCopy(),
                             claudeAppPath: String = UpdateFixture.claudeApp, _ name: String,
                             file: StaticString = #filePath, line: UInt = #line) async {
        let before = fake.bundles
        let outcome = await commit(fake, running: running, claudeAppPath: claudeAppPath)
        let refusal = refusedBeforeSwap(outcome, file: file, line: line)
        XCTAssertEqual(refusal?.step, CommitStep.proveTarget.rawValue, name, file: file, line: line)
        XCTAssertEqual(fake.swaps, [], name, file: file, line: line)
        XCTAssertEqual(fake.launches, [], name, file: file, line: line)
        XCTAssertEqual(fake.handoffs, [], name, file: file, line: line)
        XCTAssertEqual(fake.bundles.filter { $0.key != UpdateFixture.staged },
                       before.filter { $0.key != UpdateFixture.staged }, name, file: file, line: line)
    }

    func testATargetThatIsALinkIsRefused() async {
        let fake = FakeCommit()
        fake.kinds[install] = .symlink
        await refusesAtC1(fake, "symlink")
    }

    func testATargetWithAnotherBundleIdentifierIsRefused() async {
        let fake = FakeCommit()
        fake.bundleIdentifiers[install] = "com.anthropic.claudefordesktop.invalid-test"
        await refusesAtC1(fake, "another bundle")
    }

    func testACopyMovedSinceItStartedIsRefused() async {
        let fake = FakeCommit()
        fake.processPath = "/Users/testhome/Desktop/Claude Switcher.app/Contents/MacOS/claude-switcher"
        await refusesAtC1(fake, "moved")
        let unknown = FakeCommit()
        unknown.processPath = nil
        await refusesAtC1(unknown, "unknown process path")
    }

    /// Claude.app is never modified: not at its configured path, not inside it, not around it,
    /// however the path is spelled.
    func testClaudeAppIsNeverModified() async {
        let atClaude = FakeCommit()
        atClaude.bundles = ["/Applications/Claude.app": UpdateFixture.v070, staged: UpdateFixture.v080]
        let claudeRunning = UpdateFixture.runningCopy(bundlePath: "/Applications/Claude.app")
        atClaude.processPath = claudeRunning.executablePath
        await refusesAtC1(atClaude, running: claudeRunning, claudeAppPath: "/Applications/Claude.app", "same path")

        let spelled = FakeCommit()
        spelled.bundles = ["/Applications/Claude.app": UpdateFixture.v070, staged: UpdateFixture.v080]
        spelled.processPath = claudeRunning.executablePath
        await refusesAtC1(spelled, running: claudeRunning, claudeAppPath: "//Applications/claude.APP/", "spelled differently")

        let inside = FakeCommit()
        let nested = "/Applications/Claude.app/Contents/Helpers/Claude Switcher.app"
        inside.bundles = [nested: UpdateFixture.v070, staged: UpdateFixture.v080]
        let nestedRunning = UpdateFixture.runningCopy(bundlePath: nested)
        inside.processPath = nestedRunning.executablePath
        await refusesAtC1(inside, running: nestedRunning, claudeAppPath: "/Applications/Claude.app", "inside Claude.app")

        let linked = FakeCommit()
        linked.links["/Users/testhome/Claude-link.app"] = install
        await refusesAtC1(linked, claudeAppPath: "/Users/testhome/Claude-link.app", "Claude's path is a link to this copy")

        let throughALink = FakeCommit()
        let viaLink = "/Users/testhome/Applications/Claude Switcher.app"
        throughALink.bundles = [viaLink: UpdateFixture.v070, staged: UpdateFixture.v080]
        throughALink.links[viaLink] = "/Applications/Claude.app"
        let linkedRunning = UpdateFixture.runningCopy(bundlePath: viaLink)
        throughALink.processPath = linkedRunning.executablePath
        await refusesAtC1(throughALink, running: linkedRunning, claudeAppPath: "/Applications/Claude.app",
                          "this copy's path is a link to Claude.app")

        let around = FakeCommit()
        let suite = "/Applications/Suite.app"
        around.bundles = [suite: UpdateFixture.v070, staged: UpdateFixture.v080]
        let suiteRunning = UpdateFixture.runningCopy(bundlePath: suite)
        around.processPath = suiteRunning.executablePath
        await refusesAtC1(around, running: suiteRunning, claudeAppPath: suite + "/Contents/Helpers/Claude.app",
                          "Claude.app inside the path to replace")

        let unknown = FakeCommit()
        await refusesAtC1(unknown, claudeAppPath: "", "Claude's path is not known")
    }

    func testATargetThisUserCannotReplaceIsRefused() async {
        let bundle = FakeCommit()
        bundle.notWritable = [install]
        await refusesAtC1(bundle, "bundle not writable")
        let parent = FakeCommit()
        parent.notWritable = ["/Applications"]
        await refusesAtC1(parent, "parent not writable")
    }

    func testAStagedCopyOnAnotherVolumeIsRefused() async {
        let fake = FakeCommit()
        fake.devices[staged] = 99
        await refusesAtC1(fake, "cross-device")
        let gone = FakeCommit()
        gone.bundles[staged] = nil
        await refusesAtC1(gone, "the staged copy is gone")
    }

    /// `renamex_np(RENAME_SWAP)` swaps a folder with a link as readily as with a folder: only a
    /// plain folder may take the installed copy's place.
    func testAStagedCopyThatIsALinkIsRefused() async {
        let fake = FakeCommit()
        fake.kinds[staged] = .symlink
        await refusesAtC1(fake, "the replacement is a link")
    }

    // MARK: - C2 and C3

    func testACopyInPlaceThatIsNotTheRunningVersionIsRefused() async {
        let fake = FakeCommit()
        fake.bundles[install] = UpdateFixture.v060
        let refusal = refusedBeforeSwap(await commit(fake))
        XCTAssertEqual(refusal?.step, CommitStep.versions.rawValue)
        XCTAssertEqual(fake.swaps, [])
    }

    func testAPreparedVersionNotNewerThanTheRunningOneIsRefused() async {
        let fake = FakeCommit()
        let old = UpdateFixture.prepared(UpdateFixture.candidate(UpdateFixture.v070))
        fake.bundles[staged] = UpdateFixture.v070
        let outcome = await SwitcherUpdater.commit(prepared: old, running: UpdateFixture.runningCopy(), trust: trust,
                                                   claudeAppPath: UpdateFixture.claudeApp, userAsked: true, env: fake.env)
        let refusal = refusedBeforeSwap(outcome)
        XCTAssertEqual(refusal?.kind, .permanent)
        XCTAssertEqual(refusal?.step, CommitStep.versions.rawValue, "refused at C2, before the staged copy is checked again")
        XCTAssertEqual(fake.swaps, [])
    }

    /// The staged copy is checked again right before the swap; one that changed since prepare is
    /// removed (it was never swapped) and its release rejected.
    func testAStagedCopyThatNoLongerVerifiesIsRemovedAndRejected() async {
        let fake = FakeCommit()
        fake.invalidAt[staged] = SignatureRefusal(status: -67061, message: "a sealed file was modified")
        let refusal = refusedBeforeSwap(await commit(fake))
        XCTAssertEqual(refusal?.kind, .permanent)
        XCTAssertEqual(refusal?.step, CommitStep.reverify.rawValue)
        XCTAssertEqual(fake.removed, [staged])
        XCTAssertEqual(fake.swaps, [])
    }

    // MARK: - C3′: still nothing going on

    func testASoftBlockerThatAppearsBeforeTheHandoffAbortsWithNothingMoved() async {
        let fake = FakeCommit()
        fake.onStep[.reverify] = { $0.blockers = [.menuOpen] }
        let outcome = await commit(fake)
        XCTAssertEqual(outcome, .abortedNotIdle([.menuOpen]))
        XCTAssertEqual(fake.swaps, [])
        XCTAssertEqual(fake.handoffs, [])
        XCTAssertEqual(fake.removed, [], "the verified copy stays for the next try")
    }

    func testWhenTheUserAskedOnlyHardBlockersCountAndTheCommitHasCheckedThemAlready() async {
        let fake = FakeCommit()
        fake.blockers = [.menuOpen, .modal]
        let outcome = await commit(fake, userAsked: true)
        XCTAssertEqual(outcome, .launched(4300))
    }

    // MARK: - C5 and C6

    func testASwapErrorStopsEverythingAndSaysWhy() async {
        for (code, reason) in [(EACCES, "cannot replace this copy"), (EXDEV, "staging on another volume"),
                               (ENOTSUP, "the volume cannot swap folders")] {
            let fake = FakeCommit()
            fake.swapErrnos = [code]
            let refusal = refusedBeforeSwap(await commit(fake))
            XCTAssertEqual(refusal?.reason, reason)
            XCTAssertEqual(refusal?.kind, .transient)
            XCTAssertEqual(fake.swaps.count, 1)
            XCTAssertEqual(fake.launches, [])
            XCTAssertEqual(fake.registered, [])
            XCTAssertEqual(fake.bundles[install], UpdateFixture.v070)
            // The record does not claim an interrupted update.
            XCTAssertEqual(fake.handoffs.last?.phase, .rolledBack)
            XCTAssertEqual(fake.handoffs.last?.failure, reason)
        }
    }

    /// The only swap back: the copy now in place fails its check before anything was launched.
    func testACopyThatFailsItsCheckInPlaceIsSwappedBackExactlyOnce() async {
        let fake = FakeCommit()
        fake.invalidAtInstallAfterSwap = SignatureRefusal(status: -67030, message: "Info.plist modified")
        let outcome = await commit(fake)
        guard case .rolledBack(let refusal) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(refusal.kind, .permanent)
        XCTAssertEqual(fake.swaps, ["\(staged) <-> \(install)", "\(install) <-> \(staged)"])
        XCTAssertEqual(fake.bundles[install], UpdateFixture.v070)
        XCTAssertEqual(fake.handoffs.map(\.phase), [.swapping, .rolledBack])
        XCTAssertEqual(fake.launches, [])
        XCTAssertEqual(fake.terminated, 0)
        XCTAssertEqual(fake.removed, [], "after a swap nothing is removed")
    }

    /// What is in place after the swap must be a plain folder: a link there is swapped back and
    /// nothing is launched.
    func testALinkInPlaceAfterTheSwapIsSwappedBack() async {
        let fake = FakeCommit()
        fake.onStep[.verifyInstalled] = { $0.kinds[UpdateFixture.install] = .symlink }
        let outcome = await commit(fake)
        guard case .rolledBack(let refusal) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(refusal.step, CommitStep.verifyInstalled.rawValue)
        XCTAssertEqual(fake.swaps.count, 2)
        XCTAssertEqual(fake.launches, [])
        XCTAssertEqual(fake.terminated, 0)
    }

    func testAWrongVersionInPlaceAfterTheSwapIsSwappedBack() async {
        let fake = FakeCommit()
        fake.onStep[.verifyInstalled] = { $0.bundles[UpdateFixture.install] = UpdateFixture.v060 }
        let outcome = await commit(fake)
        guard case .rolledBack = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fake.swaps.count, 2)
    }

    // MARK: - C8: the relaunch

    /// A launch that fails or never answers leaves the new version installed and this process
    /// running: nothing is swapped back, nothing removed, nothing terminated.
    func testALaunchErrorOrTimeoutLeavesTheNewVersionInPlaceAndRestartPending() async {
        for reason in ["The application cannot be opened.", "it did not start within 60 seconds"] {
            let fake = FakeCommit()
            fake.launchResult = .failure(RelaunchFailure(reason: reason))
            let outcome = await commit(fake)
            XCTAssertEqual(outcome, .restartPending(reason))
            XCTAssertEqual(fake.swaps.count, 1)
            XCTAssertEqual(fake.bundles[install], UpdateFixture.v080)
            XCTAssertEqual(fake.removed, [])
            XCTAssertEqual(fake.moved, [staged])
            XCTAssertEqual(fake.terminated, 0)
            XCTAssertEqual(fake.handoffs.last?.phase, .restartPending)
            XCTAssertEqual(fake.handoffs.last?.failure, reason)
        }
    }

    func testAnOldCopyThatCannotGoToPreviousGoesToTheTrash() async {
        let fake = FakeCommit()
        fake.moveResult = .failure(FileError(EXDEV))
        _ = await commit(fake)
        XCTAssertEqual(fake.moved, [staged])
        XCTAssertEqual(fake.trashed, [staged])
        XCTAssertEqual(fake.handoffs.last?.oldCopy?.kind, .trash)
    }

    func testAnOldCopyThatCannotBeMovedAtAllIsLeftAndNamed() async {
        let fake = FakeCommit()
        fake.moveResult = .failure(FileError(EXDEV))
        fake.trashResult = .failure(FileError(EACCES))
        let outcome = await commit(fake)
        XCTAssertEqual(outcome, .launched(4300))
        XCTAssertEqual(fake.handoffs.last?.oldCopy, OldCopy(kind: .staging, path: staged))
        XCTAssertEqual(fake.removed, [])
        XCTAssertEqual(fake.removedFolders, [], "the folder still holds the old copy")
        XCTAssertEqual(fake.bundles[staged], UpdateFixture.v070)
    }

    /// While the menu or a window is open the relaunch waits — at most five minutes.
    func testTheRelaunchWaitsForTheMenuToClose() async {
        let fake = FakeCommit()
        fake.uiOpenFor = .seconds(42)
        _ = await commit(fake)
        XCTAssertEqual(fake.launches.count, 1)
        XCTAssertEqual(fake.launchedAt, [.seconds(42)])
    }

    func testTheRelaunchGoesAheadAfterFiveMinutesRegardless() async {
        let fake = FakeCommit()
        fake.uiOpenFor = .seconds(100_000)
        _ = await commit(fake)
        XCTAssertEqual(fake.launches.count, 1)
        XCTAssertEqual(fake.launchedAt, [.seconds(300)])
    }

    func testTheRelaunchDoesNotWaitWhenNothingIsOpen() async {
        let fake = FakeCommit()
        _ = await commit(fake)
        XCTAssertEqual(fake.launchedAt, [.zero])
        XCTAssertEqual(fake.slept, .zero)
    }

    // MARK: - What a commit may remove

    func testACommitRemovesNothingButItsOwnUnswappedStagedCopy() async {
        let scripts: [(FakeCommit) -> Void] = [
            { _ in },
            { $0.kinds[UpdateFixture.install] = .symlink },
            { $0.invalidAt[UpdateFixture.staged] = SignatureRefusal(status: -67050, message: "x") },
            { $0.swapErrnos = [EXDEV] },
            { $0.invalidAtInstallAfterSwap = SignatureRefusal(status: -67054, message: "x") },
            { $0.launchResult = .failure(RelaunchFailure(reason: "x")) },
            { $0.moveResult = .failure(FileError(EXDEV)); $0.trashResult = .failure(FileError(EPERM)) },
        ]
        for script in scripts {
            let fake = FakeCommit()
            script(fake)
            _ = await commit(fake)
            XCTAssertTrue(fake.removed.allSatisfy { $0 == UpdateFixture.staged })
        }
    }

    // MARK: - Recording the outcome

    func testOnlyAnAbortedCommitKeepsTheVerifiedCopy() {
        let prepared = UpdateFixture.prepared()
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        var state = SwitcherUpdateState()
        state.prepared = prepared
        SwitcherUpdatePolicy.record(commit: .abortedNotIdle([.menuOpen]), prepared: prepared, in: &state, now: now)
        XCTAssertEqual(state.prepared, prepared)

        for outcome: CommitOutcome in [.launched(1), .restartPending("x"),
                                       .refusedBeforeSwap(Refusal(kind: .transient, step: "C1", reason: "x"))] {
            var state = SwitcherUpdateState()
            state.prepared = prepared
            SwitcherUpdatePolicy.record(commit: outcome, prepared: prepared, in: &state, now: now)
            XCTAssertNil(state.prepared, "\(outcome)")
            XCTAssertNil(state.rejected, "\(outcome)")
        }

        var rolledBack = SwitcherUpdateState()
        SwitcherUpdatePolicy.record(commit: .rolledBack(Refusal(kind: .permanent, step: "C6", reason: "x")),
                                    prepared: prepared, in: &rolledBack, now: now)
        XCTAssertTrue(rolledBack.isRejected(prepared.candidate))
    }

    // MARK: - Preconditions

    func testTheCommitPreconditions() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let idle = SwitcherIdleSnapshot(now: now)
        let prepared = UpdateFixture.prepared()
        func hold(_ snapshot: SwitcherIdleSnapshot = idle, userAsked: Bool = false,
                  installability: Installability = .installable, holder: Bool = true, on: Bool = true,
                  valid: Bool = true, prepared: PreparedUpdate? = prepared,
                  running: ReleaseVersion? = UpdateFixture.v070) -> CommitHold? {
            SwitcherUpdatePolicy.commitHold(snapshot: snapshot, userAsked: userAsked, installability: installability,
                                            isLockHolder: holder, settingOn: on, configIsValid: valid,
                                            prepared: prepared, running: running)
        }
        XCTAssertNil(hold())
        XCTAssertEqual(hold(prepared: nil), .nothingPrepared)
        XCTAssertEqual(hold(running: UpdateFixture.v080), .notNewer)
        XCTAssertEqual(hold(running: nil), .notNewer)
        XCTAssertEqual(hold(installability: .checksOnly(.adHoc)), .checksOnly(.adHoc))
        XCTAssertEqual(hold(userAsked: true, installability: .checksOnly(.adHoc)), .checksOnly(.adHoc))
        XCTAssertEqual(hold(holder: false), .notLockHolder)
        XCTAssertEqual(hold(userAsked: true, holder: false), .notLockHolder)
        XCTAssertEqual(hold(on: false), .settingOff)
        XCTAssertNil(hold(userAsked: true, on: false))
        XCTAssertEqual(hold(valid: false), .configBroken)
        XCTAssertNil(hold(userAsked: true, valid: false))
        var menu = idle
        menu.isMenuOpen = true
        XCTAssertEqual(hold(menu), .notIdle([.menuOpen]))
        XCTAssertNil(hold(menu, userAsked: true))
        var copying = idle
        copying.hasCopyProgress = true
        XCTAssertEqual(hold(copying, userAsked: true), .notIdle([.copyInFlight]))
    }

    // MARK: - Going back

    private let previous = UpdateFixture.previous(UpdateFixture.v070)
    private var badRunning: RunningCopy { UpdateFixture.runningCopy(version: UpdateFixture.v080) }
    private var badTrust: SwitcherTrust {
        SwitcherTrust(teamID: UpdateFixture.team, identifier: UpdateFixture.bundleID, runningVersion: UpdateFixture.v080)
    }
    private let plan = RevertPlan(from: UpdateFixture.v080, to: UpdateFixture.v070, tag: "v0.8.0", digest: UpdateFixture.digest)

    private func revertWorld() -> FakeCommit {
        let fake = FakeCommit()
        fake.bundles = [UpdateFixture.install: UpdateFixture.v080, previous: UpdateFixture.v070]
        return fake
    }

    private func revert(_ fake: FakeCommit, holder: Bool = true) async -> CommitOutcome {
        await SwitcherUpdater.revert(plan: plan, running: badRunning, trust: badTrust, previousPath: previous,
                                     isLockHolder: holder, claudeAppPath: UpdateFixture.claudeApp, env: fake.env)
    }

    func testGoingBackSwapsThePreviousCopyInOnceAndRelaunchesIt() async throws {
        let fake = revertWorld()
        let outcome = await revert(fake)
        XCTAssertEqual(outcome, .launched(4300))
        XCTAssertEqual(fake.swaps, ["\(previous) <-> \(UpdateFixture.install)"])
        XCTAssertEqual(fake.bundles[UpdateFixture.install], UpdateFixture.v070)
        XCTAssertEqual(fake.launches, [UpdateFixture.install])
        XCTAssertEqual(fake.trashed, [previous], "the copy that did not start is not kept as one to go back to")
        XCTAssertEqual(fake.handoffs.map(\.kind), [.revert, .revert, .revert])
        XCTAssertEqual(fake.handoffs.map(\.phase), [.swapping, .swapped, .launched])
        XCTAssertEqual(fake.handoffs.first?.from, UpdateFixture.v080)
        XCTAssertEqual(fake.handoffs.first?.to, UpdateFixture.v070)
        XCTAssertEqual(fake.handoffs.first?.tag, "v0.8.0")
        XCTAssertEqual(fake.terminated, 1)
        XCTAssertEqual(fake.removed, [])
        // The previous copy, and then what is in place, are held to this developer's notarized app.
        XCTAssertGreaterThanOrEqual(fake.requirements.count, 2)
        XCTAssertEqual(Set(fake.requirements), [try badTrust.appRequirement()])
    }

    func testAPreviousCopyThatFailsVerificationIsNeverSwappedIn() async {
        for failure in [SignatureRefusal(status: -67050, message: "not ours"), SignatureRefusal(status: -67061, message: "modified")] {
            let fake = revertWorld()
            fake.invalidAt[previous] = failure
            let outcome = await revert(fake)
            XCTAssertNotNil(refusedBeforeSwap(outcome))
            XCTAssertEqual(fake.swaps, [])
            XCTAssertEqual(fake.handoffs, [], "nothing is recorded for a revert that never started")
        }
        let wrongVersion = revertWorld()
        wrongVersion.bundles[previous] = UpdateFixture.v060
        _ = await revert(wrongVersion)
        XCTAssertEqual(wrongVersion.swaps, [])
    }

    func testGoingBackProvesTheTargetBeforeWritingAnything() async {
        let fake = revertWorld()
        fake.kinds[UpdateFixture.install] = .symlink
        _ = await revert(fake)
        XCTAssertEqual(fake.swaps, [])
        XCTAssertEqual(fake.handoffs, [])
    }

    func testGoingBackThatFailsItsCheckInPlaceIsSwappedBack() async {
        let fake = revertWorld()
        fake.invalidAtInstallAfterSwap = SignatureRefusal(status: -67054, message: "x")
        let outcome = await revert(fake)
        guard case .rolledBack = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(fake.swaps.count, 2)
        XCTAssertEqual(fake.bundles[UpdateFixture.install], UpdateFixture.v080)
        XCTAssertEqual(fake.launches, [])
    }

    func testGoingBackWhoseLaunchFailsLeavesTheSwapInPlace() async {
        let fake = revertWorld()
        fake.launchResult = .failure(RelaunchFailure(reason: "x"))
        let outcome = await revert(fake)
        XCTAssertEqual(outcome, .restartPending("x"))
        XCTAssertEqual(fake.swaps.count, 1)
        XCTAssertEqual(fake.bundles[UpdateFixture.install], UpdateFixture.v070)
        XCTAssertEqual(fake.terminated, 0)
    }

    func testOnlyTheLockHolderGoesBack() async {
        let fake = revertWorld()
        let outcome = await revert(fake, holder: false)
        XCTAssertNotNil(refusedBeforeSwap(outcome))
        XCTAssertEqual(fake.effectCount, 0)
        XCTAssertEqual(fake.handoffs, [])
    }
}
