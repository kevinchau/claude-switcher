import XCTest
@testable import ClaudeSwitcherCore

/// The rules without effects: which copy may replace itself, when it is quiet enough, when the
/// next check is due, what a refusal costs, and what a check leads to.
final class SwitcherPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private let home = "/Users/testhome"
    private let v070 = UpdateFixture.v070, v080 = UpdateFixture.v080

    // MARK: - Installability (3.1)

    private func installability(_ copy: RunningCopy, _ notarization: NotarizationVerdict = .accepted) -> Installability {
        SwitcherUpdatePolicy.installability(of: copy, notarization: notarization, home: home)
    }

    func testTheInstalledReleaseCopyMayReplaceItself() {
        XCTAssertEqual(installability(UpdateFixture.runningCopy()), .installable)
        let user = UpdateFixture.runningCopy(bundlePath: home + "/Applications/Claude Switcher.app")
        XCTAssertEqual(installability(user), .installable)
    }

    func testEachRowOfTheTableMakesACopyChecksOnly() {
        let v = v070
        let rows: [(ChecksOnlyReason, RunningCopy, NotarizationVerdict)] = [
            (.noTeam, UpdateFixture.runningCopy(identity: UpdateFixture.identity(v, team: nil)), .accepted),
            (.adHoc, UpdateFixture.runningCopy(identity: UpdateFixture.identity(v, flags: 0x10002)), .accepted),
            (.noHardenedRuntime, UpdateFixture.runningCopy(identity: UpdateFixture.identity(v, flags: 0)), .accepted),
            (.identifierMismatch, UpdateFixture.runningCopy(identity: UpdateFixture.identity(v, identifier: "claude-switcher")), .accepted),
            (.identifierMismatch, UpdateFixture.runningCopy(identity: UpdateFixture.identity(v, identifier: nil)), .accepted),
            (.identifierMismatch, UpdateFixture.runningCopy(bundleIdentifier: nil), .accepted),
            (.noVersion, UpdateFixture.runningCopy(identity: UpdateFixture.identity(nil)), .accepted),
            (.notAnAppBundle, UpdateFixture.runningCopy(bundlePath: "/Applications/claude-switcher"), .accepted),
            (.translocated, UpdateFixture.runningCopy(
                bundlePath: "/private/var/folders/zz/x/T/AppTranslocation/ABC/d/Claude Switcher.app",
                isTranslocated: true), .accepted),
            (.readOnlyVolume, UpdateFixture.runningCopy(bundlePath: "/Volumes/Claude Switcher/Claude Switcher.app",
                                                        volumeIsReadOnly: true), .accepted),
            (.notInApplications("/Users/testhome/Desktop"),
             UpdateFixture.runningCopy(bundlePath: "/Users/testhome/Desktop/Claude Switcher.app"), .accepted),
            (.notInApplications("/Applications/Utilities"),
             UpdateFixture.runningCopy(bundlePath: "/Applications/Utilities/Claude Switcher.app"), .accepted),
            (.notWritable, UpdateFixture.runningCopy(bundleIsWritable: false), .accepted),
            (.notWritable, UpdateFixture.runningCopy(parentIsWritable: false), .accepted),
            (.movedSinceLaunch, UpdateFixture.runningCopy(processExecutablePath: .some("/tmp/x/claude-switcher")), .accepted),
            (.movedSinceLaunch, UpdateFixture.runningCopy(processExecutablePath: .some(nil)), .accepted),
            (.notNotarized, UpdateFixture.runningCopy(), .rejected),
            (.notarizationUnconfirmed, UpdateFixture.runningCopy(), .unknown(-67012)),
        ]
        for (reason, copy, notarization) in rows {
            XCTAssertEqual(installability(copy, notarization), .checksOnly(reason), "\(reason)")
        }
    }

    /// `build/Claude Switcher.app` is signed exactly like the installed copy; where it is decides.
    func testTheRepositorysOwnBuildIsChecksOnlyPurelyByWhereItIs() {
        let build = "/Users/kevinchau/localdev/claude-code-desktop-switcher/build/Claude Switcher.app"
        let identity = CodeIdentity(teamID: "FTHBLX7S63", identifier: "tech.local.claude-switcher", flags: 0x10000,
                                    version: v070, path: build)
        let copy = UpdateFixture.runningCopy(identity: identity, bundlePath: build)
        XCTAssertEqual(installability(copy), .checksOnly(.notInApplications((build as NSString).deletingLastPathComponent)))
        XCTAssertNotNil(SwitcherTrust(copy), "it can still check, against its own signature")
        let installed = UpdateFixture.runningCopy(identity: identity)
        XCTAssertEqual(installability(installed), .installable)
    }

    /// The running copy's folder is read with links resolved, so the allowed folders are resolved
    /// too: a home reached through a link still has its own ~/Applications.
    func testApplicationsFoldersAreComparedWithLinksResolved() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = try XCTUnwrap(SwitcherDisk.realpath(base.path))
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/real/Applications", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/linked", withDestinationPath: root + "/real")
        let copy = UpdateFixture.runningCopy(bundlePath: root + "/linked/Applications/Claude Switcher.app",
                                             parentDirectory: root + "/real/Applications")
        XCTAssertEqual(SwitcherUpdatePolicy.installability(of: copy, notarization: .accepted, home: root + "/linked"),
                       .installable)
        XCTAssertEqual(SwitcherUpdatePolicy.installability(of: copy, notarization: .accepted, home: root + "/elsewhere"),
                       .checksOnly(.notInApplications(root + "/real/Applications")))

        // A folder that does not resolve is compared as written.
        let unresolved: (String) -> String? = { _ in nil }
        XCTAssertEqual(SwitcherUpdatePolicy.installability(of: UpdateFixture.runningCopy(
            bundlePath: home + "/Applications/Claude Switcher.app"), notarization: .accepted, home: home,
            canonical: unresolved), .installable)
        XCTAssertEqual(SwitcherUpdatePolicy.installability(of: copy, notarization: .accepted, home: root + "/linked",
                                                           canonical: unresolved),
                       .checksOnly(.notInApplications(root + "/real/Applications")))
    }

    func testTheFirstReasonThatAppliesWins() {
        let copy = UpdateFixture.runningCopy(identity: UpdateFixture.identity(v070, team: nil),
                                             bundlePath: "/Users/testhome/Desktop/Claude Switcher.app", isTranslocated: true)
        XCTAssertEqual(installability(copy, .rejected), .checksOnly(.noTeam))
    }

    func testTheTrustAnchorComesOnlyFromADeveloperIDSignatureThatNamesTheBundle() {
        XCTAssertEqual(SwitcherTrust(UpdateFixture.runningCopy()), UpdateFixture.trust)
        XCTAssertNil(SwitcherTrust(UpdateFixture.runningCopy(identity: UpdateFixture.identity(v070, team: nil))))
        XCTAssertNil(SwitcherTrust(UpdateFixture.runningCopy(identity: UpdateFixture.identity(v070, flags: 0x10002))))
        XCTAssertNil(SwitcherTrust(UpdateFixture.runningCopy(identity: UpdateFixture.identity(v070, identifier: "x"))))
        XCTAssertNil(SwitcherTrust(UpdateFixture.runningCopy(bundleIdentifier: nil)))
        XCTAssertNil(SwitcherTrust(UpdateFixture.runningCopy(identity: UpdateFixture.identity(nil))))
    }

    /// One slow or offline answer must not decide for the life of a login item.
    func testAnUnconfirmedNotarizationIsAskedAgainAtTheNextCheck() {
        var memo = NotarizationMemo()
        var answers: [NotarizationVerdict] = [.unknown(-67012), .accepted, .rejected]
        var asked = 0
        func next() -> NotarizationVerdict { asked += 1; return answers.removeFirst() }

        let first = memo.verdict(next)
        XCTAssertEqual(installability(UpdateFixture.runningCopy(), first), .checksOnly(.notarizationUnconfirmed))
        let second = memo.verdict(next)
        XCTAssertEqual(installability(UpdateFixture.runningCopy(), second), .installable)
        XCTAssertEqual(memo.verdict(next), .accepted, "a settled answer is kept")
        XCTAssertEqual(asked, 2)

        var rejected = NotarizationMemo()
        XCTAssertEqual(rejected.verdict { .rejected }, .rejected)
        XCTAssertEqual(rejected.verdict { .accepted }, .rejected)
    }

    func testOnlyTheRequirementFailureMeansNotNotarized() {
        XCTAssertEqual(CodeSignature.verdict(for: errSecSuccess), .accepted)
        XCTAssertEqual(CodeSignature.verdict(for: -67050), .rejected)
        XCTAssertEqual(CodeSignature.verdict(for: -67012), .unknown(-67012))
        XCTAssertEqual(CodeSignature.verdict(for: -67062), .unknown(-67062))
    }

    // MARK: - The app's gates

    func testQuitWaitsOnlyForACommit() {
        XCTAssertTrue(SwitcherShellGate.canQuit(isCommitting: false))
        XCTAssertFalse(SwitcherShellGate.canQuit(isCommitting: true))
    }

    /// Every fact the automatic check weighs holds it back on its own.
    func testEachFactHoldsTheAutomaticCheck() {
        func runs(holder: Bool = true, valid: Bool = true, on: Bool = true, never: Bool = false, pending: Bool = false,
                  checking: Bool = false, committing: Bool = false, reconciling: Bool = false) -> Bool {
            SwitcherShellGate.automaticChecksRun(isLockHolder: holder, configIsValid: valid, settingOn: on,
                                                 neverReplaces: never, restartPending: pending, isChecking: checking,
                                                 isCommitting: committing, isReconciling: reconciling)
        }
        XCTAssertTrue(runs())
        XCTAssertFalse(runs(holder: false), "only the lock holder")
        XCTAssertFalse(runs(valid: false), "not on a config that does not read")
        XCTAssertFalse(runs(on: false), "off")
        XCTAssertFalse(runs(never: true), "a copy that never replaces itself")
        XCTAssertFalse(runs(pending: true), "a new version waits for the next launch")
        XCTAssertFalse(runs(checking: true))
        XCTAssertFalse(runs(committing: true))
        XCTAssertFalse(runs(reconciling: true), "the launch pass tidies the same folders")
    }

    func testEachFactHoldsAManualCheckAndAnInstall() {
        func manual(checking: Bool = false, committing: Bool = false, pending: Bool = false,
                    reconciling: Bool = false) -> Bool {
            SwitcherShellGate.manualCheckRuns(isChecking: checking, isCommitting: committing, restartPending: pending,
                                              isReconciling: reconciling)
        }
        XCTAssertTrue(manual())
        XCTAssertFalse(manual(checking: true))
        XCTAssertFalse(manual(committing: true))
        XCTAssertFalse(manual(pending: true))
        XCTAssertFalse(manual(reconciling: true))

        func considers(prepared: Bool = true, committing: Bool = false, pending: Bool = false, checking: Bool = false,
                       reconciling: Bool = false) -> Bool {
            SwitcherShellGate.considersInstall(hasPrepared: prepared, isCommitting: committing, restartPending: pending,
                                               isChecking: checking, isReconciling: reconciling)
        }
        XCTAssertTrue(considers())
        XCTAssertFalse(considers(prepared: false))
        XCTAssertFalse(considers(committing: true))
        XCTAssertFalse(considers(pending: true))
        XCTAssertFalse(considers(checking: true))
        XCTAssertFalse(considers(reconciling: true))
    }

    // MARK: - Requirements

    func testRequirementsAreBuiltOnlyFromAValidTeamAndIdentifier() throws {
        XCTAssertEqual(try CodeSignature.requirementForApp(team: "FTHBLX7S63", identifier: "tech.local.claude-switcher"),
                       "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate "
                       + "leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"FTHBLX7S63\" "
                       + "and identifier \"tech.local.claude-switcher\" and notarized")
        XCTAssertEqual(try CodeSignature.requirementForImage(team: "FTHBLX7S63"),
                       "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate "
                       + "leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"FTHBLX7S63\" "
                       + "and notarized")
        for team in ["fthblx7s63", "FTHBLX7S6", "FTHBLX7S633", "FTHBLX7S6\"", "FTHBLX7S6 ", "\u{FF26}THBLX7S63"] {
            XCTAssertThrowsError(try CodeSignature.requirementForImage(team: team), team)
        }
        for identifier in ["", "tech.local\" or anchor apple", "a b", "tech/local", "tech.local.é"] {
            XCTAssertThrowsError(try CodeSignature.requirementForApp(team: "FTHBLX7S63", identifier: identifier), identifier)
        }
    }

    func testTheValidationFlagsAreStrictAndNeverSkipAnything() {
        let flags = CodeSignature.validationFlags.rawValue
        for required in [kSecCSCheckAllArchitectures, kSecCSCheckNestedCode, kSecCSStrictValidate,
                         kSecCSRestrictSymlinks, kSecCSRestrictSidebandData] {
            XCTAssertNotEqual(flags & UInt32(required), 0)
        }
        XCTAssertEqual(flags & CodeSignature.forbiddenFlags, 0)
        XCTAssertNotEqual(CodeSignature.forbiddenFlags & SecCSFlags.noNetworkAccess.rawValue, 0)
        XCTAssertNotEqual(CodeSignature.forbiddenFlags & UInt32(kSecCSDoNotValidateResources), 0)
        XCTAssertNotEqual(CodeSignature.forbiddenFlags & UInt32(kSecCSDoNotValidateExecutable), 0)
        XCTAssertNotEqual(CodeSignature.forbiddenFlags & UInt32(kSecCSBasicValidateOnly), 0)
        // The offline variant is the same check kept off the network, and nothing else.
        XCTAssertEqual(CodeSignature.offlineFlags.rawValue, flags | SecCSFlags.noNetworkAccess.rawValue)
    }

    // MARK: - Idle (10.1)

    private func snapshot(_ change: (inout SwitcherIdleSnapshot) -> Void = { _ in }) -> SwitcherIdleSnapshot {
        var snapshot = SwitcherIdleSnapshot(now: now)
        change(&snapshot)
        return snapshot
    }

    func testEachFlagIsItsOwnBlocker() {
        let flags: [(SwitcherIdle.Blocker, WritableKeyPath<SwitcherIdleSnapshot, Bool>)] = [
            (.menuOpen, \.isMenuOpen), (.modal, \.isPresentingModal), (.queuedAlert, \.hasPendingAlerts),
            (.launchInFlight, \.isBusy), (.claudeUpdateInFlight, \.hasUpdateProgress), (.copyInFlight, \.hasCopyProgress),
            (.copyRecovery, \.isRecoveringCopies), (.reopenPass, \.isConsideringReopen), (.diagnostics, \.isPreparingDiagnostics),
            (.welcomeWindow, \.welcomeWindowIsVisible), (.unshownNotice, \.hasUnshownNotice),
            (.checkInFlight, \.isCheckingSwitcherUpdate), (.prepareInFlight, \.isPreparingSwitcherUpdate),
        ]
        XCTAssertEqual(SwitcherIdle.blockers(snapshot()), [])
        for (blocker, flag) in flags {
            XCTAssertEqual(SwitcherIdle.blockers(snapshot { $0[keyPath: flag] = true }), [blocker], "\(blocker)")
        }
        XCTAssertEqual(flags.count + 1, SwitcherIdle.Blocker.allCases.count)
    }

    func testTheQuietPeriodIsNinetySecondsEitherWay() {
        XCTAssertEqual(SwitcherIdle.blockers(snapshot { $0.lastUserActivity = self.now.addingTimeInterval(-89) }), [.quietPeriod])
        XCTAssertEqual(SwitcherIdle.blockers(snapshot { $0.lastUserActivity = self.now.addingTimeInterval(-90) }), [])
        XCTAssertEqual(SwitcherIdle.blockers(snapshot { $0.lastUserActivity = self.now.addingTimeInterval(-3600) }), [])
        // A clock set back must not hold the relaunch off until it catches up.
        XCTAssertEqual(SwitcherIdle.blockers(snapshot { $0.lastUserActivity = self.now.addingTimeInterval(30) }), [.quietPeriod])
        XCTAssertEqual(SwitcherIdle.blockers(snapshot { $0.lastUserActivity = self.now.addingTimeInterval(365 * 86400) }), [])
        XCTAssertEqual(SwitcherIdle.quietPeriod, .seconds(90))
    }

    func testWhenTheUserAsksOnlyWorkInFlightStillHoldsIt() {
        let everything = snapshot { s in
            s.isMenuOpen = true; s.isPresentingModal = true; s.hasPendingAlerts = true; s.isBusy = true
            s.hasUpdateProgress = true; s.hasCopyProgress = true; s.isRecoveringCopies = true; s.isConsideringReopen = true
            s.isPreparingDiagnostics = true; s.welcomeWindowIsVisible = true; s.hasUnshownNotice = true
            s.isCheckingSwitcherUpdate = true; s.isPreparingSwitcherUpdate = true
            s.lastUserActivity = self.now
        }
        XCTAssertEqual(SwitcherIdle.blockers(everything), SwitcherIdle.Blocker.allCases)
        XCTAssertEqual(SwitcherIdle.blockers(everything, userAsked: true),
                       [.launchInFlight, .claudeUpdateInFlight, .copyInFlight, .copyRecovery, .reopenPass, .prepareInFlight])
        XCTAssertEqual(SwitcherIdle.hard, [.launchInFlight, .claudeUpdateInFlight, .copyInFlight, .copyRecovery,
                                           .reopenPass, .prepareInFlight])
    }

    func testBlockersAreReportedInAStableOrder() {
        let snapshot = snapshot { $0.isPreparingSwitcherUpdate = true; $0.isMenuOpen = true; $0.hasCopyProgress = true }
        for _ in 0..<20 {
            XCTAssertEqual(SwitcherIdle.blockers(snapshot), [.menuOpen, .copyInFlight, .prepareInFlight])
        }
    }

    // MARK: - When a check is due (10.3)

    func testOffIsNeverDue() {
        XCTAssertFalse(SwitcherUpdatePolicy.isDue(state: SwitcherUpdateState(), now: now, settingOn: false))
        var corrupt = SwitcherUpdateState()
        corrupt.nextCheckNotBefore = now.addingTimeInterval(365 * 86400)
        XCTAssertFalse(SwitcherUpdatePolicy.isDue(state: corrupt, now: now, settingOn: false))
    }

    func testANormalScheduleIsKept() {
        var state = SwitcherUpdateState()
        XCTAssertTrue(SwitcherUpdatePolicy.isDue(state: state, now: now, settingOn: true))
        state.lastCheckAt = now.addingTimeInterval(-60)
        state.nextCheckNotBefore = now.addingTimeInterval(6 * 3600)
        XCTAssertFalse(SwitcherUpdatePolicy.isDue(state: state, now: now, settingOn: true))
        XCTAssertTrue(SwitcherUpdatePolicy.isDue(state: state, now: now.addingTimeInterval(6 * 3600), settingOn: true))
    }

    /// A clock that was wrong, a hand edit or a forged header can never put the next check
    /// further away than a day.
    func testADateTooFarAheadIsCorruptAndTheCheckIsDueNow() {
        var far = SwitcherUpdateState()
        far.nextCheckNotBefore = now.addingTimeInterval(365 * 86400)
        XCTAssertTrue(SwitcherUpdatePolicy.isDue(state: far, now: now, settingOn: true))

        var future = SwitcherUpdateState()
        future.lastCheckAt = now.addingTimeInterval(3600)
        future.nextCheckNotBefore = now.addingTimeInterval(3 * 3600)
        XCTAssertTrue(SwitcherUpdatePolicy.isDue(state: future, now: now, settingOn: true))

        var limited = SwitcherUpdateState()
        limited.lastCheckResult = .rateLimited(until: now.addingTimeInterval(2 * 86400))
        limited.nextCheckNotBefore = now.addingTimeInterval(3 * 3600)
        XCTAssertTrue(SwitcherUpdatePolicy.isDue(state: limited, now: now, settingOn: true))

        var day = SwitcherUpdateState()
        day.nextCheckNotBefore = now.addingTimeInterval(86400)
        XCTAssertFalse(SwitcherUpdatePolicy.isDue(state: day, now: now, settingOn: true))
    }

    func testLoadingClearsDatesTooFarAhead() async throws {
        let (store, directory) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = SwitcherUpdateState()
        state.nextCheckNotBefore = now.addingTimeInterval(365 * 86400)
        state.lastCheckAt = now.addingTimeInterval(3600)
        state.lastCheckResult = .rateLimited(until: now.addingTimeInterval(10 * 86400))
        state.attempts = ["v0.8.0#\(UpdateFixture.digest)": AttemptRecord(count: 3, lastStep: "download",
                                                                         nextNotBefore: now.addingTimeInterval(400 * 86400))]
        try await store.save(state)
        let loaded = await store.load(now: now)
        XCTAssertNil(loaded.nextCheckNotBefore)
        XCTAssertNil(loaded.lastCheckAt)
        XCTAssertNil(loaded.lastCheckResult)
        XCTAssertEqual(loaded.attempts?.values.first?.nextNotBefore, now)
        XCTAssertTrue(SwitcherUpdatePolicy.isDue(state: loaded, now: now, settingOn: true))
    }

    func testTheNextCheckFollowsTheOutcomeAndIsNeverMoreThanADayAway() {
        func next(_ outcome: CheckOutcome) -> TimeInterval {
            SwitcherUpdatePolicy.nextCheck(after: outcome, now: now).timeIntervalSince(now)
        }
        XCTAssertEqual(next(.candidate(UpdateFixture.candidate())), 6 * 3600)
        XCTAssertEqual(next(.noRelease), 6 * 3600)
        XCTAssertEqual(next(.feedMoved("x")), 6 * 3600)
        XCTAssertEqual(next(.feedChanged("x")), 6 * 3600)
        XCTAssertEqual(next(.apiRetired), 24 * 3600)
        XCTAssertEqual(next(.serverError(502)), 3600)
        XCTAssertEqual(next(.offline("x")), 3600)
        XCTAssertEqual(next(.rateLimited(until: now.addingTimeInterval(7200))), 7200)
        XCTAssertEqual(next(.rateLimited(until: now.addingTimeInterval(400 * 86400))), 24 * 3600)
        XCTAssertEqual(next(.rateLimited(until: now)), 3600)
    }

    // MARK: - Retry and rejection (10.3)

    private let candidate = UpdateFixture.candidate()

    /// Ordinary flakiness never rejects a good release: the attempts back off and stay eligible.
    func testTransientFailuresBackOffAndNeverReject() {
        var state = SwitcherUpdateState()
        var at = now
        var waits: [TimeInterval] = []
        for _ in 0..<3 {
            let decision = SwitcherUpdatePolicy.decision(
                state: state, outcome: .candidate(candidate), runningVersion: v070, trust: UpdateFixture.trust,
                installability: .installable, settingOn: true, isLockHolder: true, configIsValid: true, manual: false, now: at)
            XCTAssertEqual(decision.action, .prepare(candidate))
            SwitcherUpdatePolicy.record(.transient(.download, "the network connection was lost"), for: candidate,
                                        in: &state, now: at)
            waits.append(state.attempts![candidate.key]!.nextNotBefore.timeIntervalSince(at))
            at = at.addingTimeInterval(6 * 3600)
        }
        XCTAssertEqual(waits, [3600, 7200, 14400])
        XCTAssertNil(state.rejected)
        XCTAssertNil(state.downloadsPaused)
    }

    func testTheBackoffDoublesUpToADay() {
        var record: AttemptRecord?
        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            record = SwitcherUpdatePolicy.nextAttempt(after: .transient(.attach, "x"), attempts: record, now: now)
            waits.append(record!.nextNotBefore.timeIntervalSince(now) / 3600)
        }
        XCTAssertEqual(waits, [1, 2, 4, 8, 16, 24, 24, 24])
    }

    func testAnAttemptThatGetsFurtherStartsTheBackoffAgain() {
        var record = SwitcherUpdatePolicy.nextAttempt(after: .transient(.download, "x"), attempts: nil, now: now)
        record = SwitcherUpdatePolicy.nextAttempt(after: .transient(.download, "x"), attempts: record, now: now)
        XCTAssertEqual(record?.count, 2)
        record = SwitcherUpdatePolicy.nextAttempt(after: .transient(.assess, "x"), attempts: record, now: now)
        XCTAssertEqual(record?.count, 1)
        XCTAssertEqual(record?.nextNotBefore, now.addingTimeInterval(3600))
        // A later failure at an earlier step does not reset it.
        record = SwitcherUpdatePolicy.nextAttempt(after: .transient(.download, "x"), attempts: record, now: now)
        XCTAssertEqual(record?.count, 2)
        // A commit step is later than every prepare step.
        record = SwitcherUpdatePolicy.nextAttempt(
            after: Refusal(kind: .transient, step: CommitStep.proveTarget.rawValue, reason: "x"), attempts: record, now: now)
        XCTAssertEqual(record?.count, 1)
    }

    func testWhatWasNotReallyTriedDoesNotCount() {
        let earlier = AttemptRecord(count: 2, lastStep: "download", nextNotBefore: now.addingTimeInterval(-60))
        for refusal in [Refusal.transient(.freeSpace, "not enough free space", countsAsAttempt: false),
                        .transient(.download, "offline", countsAsAttempt: false)] {
            XCTAssertEqual(SwitcherUpdatePolicy.nextAttempt(after: refusal, attempts: earlier, now: now), earlier)
            XCTAssertNil(SwitcherUpdatePolicy.nextAttempt(after: refusal, attempts: nil, now: now))
        }
    }

    func testAnAttemptDueLaterHoldsTheAutomaticPrepare() {
        var state = SwitcherUpdateState()
        SwitcherUpdatePolicy.record(.transient(.download, "x"), for: candidate, in: &state, now: now)
        let early = decision(state, now: now.addingTimeInterval(1800))
        XCTAssertEqual(early.action, .nothing("the next attempt at 0.8.0 is due later"))
        XCTAssertEqual(early.nextCheckNotBefore, now.addingTimeInterval(3600), "the next check comes when the attempt is due")
        XCTAssertEqual(decision(state, now: now.addingTimeInterval(3600)).action, .prepare(candidate))
        XCTAssertEqual(decision(state, manual: true, now: now.addingTimeInterval(60)).action, .prepare(candidate))
    }

    func testAPermanentRefusalRejectsThatReleaseFileOnly() {
        var state = SwitcherUpdateState()
        SwitcherUpdatePolicy.record(.permanent(.digest, "mismatch"), for: candidate, in: &state, now: now)
        XCTAssertTrue(state.isRejected(candidate))
        XCTAssertEqual(decision(state).action, .nothing("0.8.0 was rejected; it is not tried again automatically"))
        // Same tag, new digest: a fresh candidate.
        let rebuilt = UpdateFixture.candidate(digest: String(repeating: "7c", count: 32))
        XCTAssertEqual(decision(state, outcome: .candidate(rebuilt)).action, .prepare(rebuilt))
        // A manual check runs a rejected one again.
        XCTAssertEqual(decision(state, manual: true).action, .prepare(candidate))
    }

    func testThreeRejectedReleasesInARowPauseAutomaticDownloadsUntilAManualCheck() {
        var state = SwitcherUpdateState()
        for byte in ["01", "02", "03"] {
            let candidate = UpdateFixture.candidate(digest: String(repeating: byte, count: 32))
            XCTAssertEqual(decision(state, outcome: .candidate(candidate)).action, .prepare(candidate))
            SwitcherUpdatePolicy.record(.permanent(.imageRequirement, "not this developer"), for: candidate, in: &state, now: now)
        }
        XCTAssertEqual(state.downloadsPaused, true)
        let fourth = UpdateFixture.candidate(digest: String(repeating: "04", count: 32))
        XCTAssertEqual(decision(state, outcome: .candidate(fourth)).action,
                       .nothing("automatic downloads paused after 3 rejected releases"))
        SwitcherUpdatePolicy.manualCheckStarted(&state)
        XCTAssertNil(state.downloadsPaused)
        XCTAssertEqual(decision(state, outcome: .candidate(fourth)).action, .prepare(fourth))
    }

    func testAReleaseThatPassesResetsTheRunOfRejectionsAndIsNoLongerRejected() {
        var state = SwitcherUpdateState()
        SwitcherUpdatePolicy.record(.permanent(.digest, "x"), for: candidate, in: &state, now: now)
        SwitcherUpdatePolicy.record(.permanent(.digest, "x"), for: UpdateFixture.candidate(digest: String(repeating: "09", count: 32)),
                                    in: &state, now: now)
        SwitcherUpdatePolicy.recordPrepared(UpdateFixture.prepared(candidate), in: &state)
        XCTAssertEqual(state.consecutivePermanentRejections, 0)
        XCTAssertFalse(state.isRejected(candidate))
        XCTAssertEqual(state.rejected?.count, 1)
    }

    // MARK: - The decision after a check

    private func decision(_ state: SwitcherUpdateState = SwitcherUpdateState(), outcome: CheckOutcome? = nil,
                          trust: SwitcherTrust? = UpdateFixture.trust, installability: Installability = .installable,
                          on: Bool = true, holder: Bool = true, valid: Bool = true, manual: Bool = false,
                          now: Date? = nil) -> Decision {
        SwitcherUpdatePolicy.decision(state: state, outcome: outcome ?? .candidate(candidate), runningVersion: v070,
                                      trust: trust, installability: installability, settingOn: on, isLockHolder: holder,
                                      configIsValid: valid, manual: manual, now: now ?? self.now)
    }

    func testOffNeverPreparesAutomatically() {
        guard case .nothing = decision(on: false).action else { return XCTFail() }
        XCTAssertEqual(decision(on: false, manual: true).action, .prepare(candidate))
    }

    func testOnlyTheLockHolderPreparesAutomatically() {
        XCTAssertEqual(decision(holder: false).action, .nothing("another Claude Switcher holds the lock"))
        XCTAssertEqual(decision(holder: false, manual: true).action, .prepare(candidate))
    }

    func testABrokenConfigStopsAutomaticPreparesButNotAManualCheck() {
        XCTAssertEqual(decision(valid: false).action, .nothing("config.json cannot be read"))
        XCTAssertEqual(decision(valid: false, manual: true).action, .prepare(candidate))
    }

    func testAChecksOnlyCopyWithATrustAnchorPreparesOnlyWhenAsked() {
        guard case .nothing = decision(installability: .checksOnly(.notInApplications("/x"))).action else { return XCTFail() }
        XCTAssertEqual(decision(installability: .checksOnly(.notInApplications("/x")), manual: true).action,
                       .prepare(candidate))
    }

    func testACopyWithNoTrustAnchorCanOnlySayANewerTagExists() {
        XCTAssertEqual(decision(trust: nil, installability: .checksOnly(.adHoc), manual: true).action,
                       .cannotVerify(tag: "v0.8.0", reason: "development build (ad-hoc signature)"))
        guard case .nothing = decision(trust: nil, installability: .checksOnly(.adHoc)).action else { return XCTFail() }
    }

    func testUpToDateAndNewerThanTheLatest() {
        let same = UpdateFixture.candidate(v070)
        XCTAssertEqual(decision(outcome: .candidate(same)).action, .upToDate(running: v070, latest: v070))
        let older = UpdateFixture.candidate(UpdateFixture.v060)
        XCTAssertEqual(decision(outcome: .candidate(older), manual: true).action,
                       .runningIsNewer(running: v070, latest: UpdateFixture.v060))
        XCTAssertEqual(decision(outcome: .offline("x"), manual: true).action, .checkFailed("could not reach api.github.com: x"))
        XCTAssertEqual(decision(outcome: .offline("x")).nextCheckNotBefore, now.addingTimeInterval(3600))
    }
}

// MARK: - A check, start to finish

/// `runCheck` with a fake feed and `FakePrepare`, recording into a store in a temporary
/// directory: what a check leads to, and which alert it may show.
final class SwitcherCheckRunTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private var directory: URL?

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func feed(_ tag: String, digest: String = UpdateFixture.digest, at: Date? = nil) -> SwitcherUpdater.CheckEnvironment {
        let body = ReleaseFeedFixture.release { release in
            release["tag_name"] = tag
            var asset = ReleaseFeedFixture.recordedAsset
            asset["digest"] = "sha256:" + digest
            asset["size"] = 791_611
            release["assets"] = [asset]
        }
        let now = at ?? self.now
        return SwitcherUpdater.CheckEnvironment(fetch: { _ in .response(status: 200, headers: [:], body: body) },
                                                now: { now })
    }

    private func context(trust: SwitcherTrust? = UpdateFixture.trust, installability: Installability = .installable,
                         holder: Bool = true, on: Bool = true, prepared: PreparedUpdate? = nil) -> SwitcherUpdater.CheckContext {
        SwitcherUpdater.CheckContext(trust: trust, runningVersion: UpdateFixture.v070, installability: installability,
                                     settingOn: on, isLockHolder: holder, configIsValid: true,
                                     installPath: UpdateFixture.install, updatesDirectory: UpdateFixture.updates,
                                     prepared: prepared)
    }

    private func run(manual: Bool, feed: SwitcherUpdater.CheckEnvironment, prepare: FakePrepare,
                     context: SwitcherUpdater.CheckContext? = nil, store: SwitcherUpdateStore? = nil,
                     preparing: @escaping @Sendable (ReleaseCandidate) async -> Void = { _ in }) async throws
        -> (SwitcherUpdater.CheckRun, SwitcherUpdateStore) {
        let store = try store ?? {
            let (store, directory) = try makeTemporaryStore()
            self.directory = directory
            return store
        }()
        let run = await SwitcherUpdater.runCheck(manual: manual, context: context ?? self.context(), store: store,
                                                 check: feed, prepare: prepare.env, preparing: preparing)
        return (run, store)
    }

    /// What the app was told was about to be prepared, and how far the prepare had got then.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var heard: [String] = []
        func add(_ value: String) { lock.lock(); heard.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return heard }
    }

    /// The alert as the app builds it after this check: "Update & Relaunch" hangs on what it kept.
    private func alert(_ run: SwitcherUpdater.CheckRun, installability: Installability = .installable,
                       hardBlocker: SwitcherIdle.Blocker? = nil) -> SwitcherAlert {
        SwitcherUpdateAlerts.manualCheck(action: run.decision.action, prepared: run.prepared,
                                         running: UpdateFixture.v070, installability: installability,
                                         keepsVerifiedCopy: run.kept != nil, hardBlocker: hardBlocker)
    }

    /// A release that fails verification is never "available", and its page is never offered.
    func testAReleaseThatFailsVerificationIsNeverOffered() async throws {
        let prepare = FakePrepare(candidate: UpdateFixture.candidate(ReleaseVersion(major: 9, minor: 9, patch: 9)))
        prepare.signatureFailures["mounted+req"] = SignatureRefusal(status: -67050, message: "not this developer")
        let (run, _) = try await self.run(manual: true, feed: feed("v9.9.9"), prepare: prepare)
        let shown = alert(run)
        XCTAssertEqual(shown.title, "Claude Switcher 9.9.9 could not be verified")
        XCTAssertFalse(shown.offersDownloadPage)
        XCTAssertFalse(shown.offersUpdate)
        XCTAssertTrue(shown.message.hasSuffix("Nothing was changed; 0.7.0 is unchanged. It will not be tried again automatically."))
        XCTAssertTrue(run.state.isRejected(tag: "v9.9.9", digest: UpdateFixture.digest))
    }

    func testACopyWithNoTrustAnchorSaysOnlyThatANewerTagExists() async throws {
        let prepare = FakePrepare()
        let (run, _) = try await self.run(manual: true, feed: feed("v0.8.0"), prepare: prepare,
                                          context: context(trust: nil, installability: .checksOnly(.adHoc)))
        let shown = alert(run, installability: .checksOnly(.adHoc))
        XCTAssertEqual(shown.title, "A newer Claude Switcher may exist")
        XCTAssertEqual(shown.message, "A newer tag (v0.8.0) exists on GitHub. This copy of Claude Switcher cannot verify it: "
                       + "development build (ad-hoc signature).")
        XCTAssertEqual(shown.buttons.map(\.title), ["OK"])
        XCTAssertEqual(prepare.downloads, 0)
    }

    func testOnlyAVerifiedReleaseIsAvailableAndAChecksOnlyCopyGetsItsPage() async throws {
        let prepare = FakePrepare()
        let reason = ChecksOnlyReason.notInApplications("/Users/testhome/Desktop")
        let (run, _) = try await self.run(manual: true, feed: feed("v0.8.0"), prepare: prepare,
                                          context: context(installability: .checksOnly(reason)))
        let shown = alert(run, installability: .checksOnly(reason))
        XCTAssertEqual(shown.title, "Claude Switcher 0.8.0 is available")
        XCTAssertEqual(shown.buttons.first?.action,
                       .openDownloadPage(URL(string: "https://github.com/kevinchau/claude-switcher/releases/tag/v0.8.0")!))
        XCTAssertNil(run.kept, "a checks-only copy keeps nothing it verified")
        XCTAssertTrue(prepare.removed.contains(UpdateFixture.staged))
        XCTAssertTrue(prepare.removed.contains(UpdateFixture.updates + "/downloads/v0.8.0"))
        XCTAssertNil(run.state.prepared)
    }

    func testAnInstallableCopyOffersUpdateAndRelaunchAndKeepsTheVerifiedCopy() async throws {
        let prepare = FakePrepare()
        let (run, _) = try await self.run(manual: true, feed: feed("v0.8.0"), prepare: prepare)
        let shown = alert(run)
        XCTAssertEqual(shown.title, "Claude Switcher 0.8.0 is available")
        XCTAssertEqual(shown.buttons.map(\.title), ["Update & Relaunch", "Later"])
        XCTAssertFalse(shown.offersDownloadPage)
        XCTAssertEqual(run.kept?.stagedAppPath, UpdateFixture.staged)
        XCTAssertFalse(prepare.removed.contains(UpdateFixture.staged))
    }

    func testANonHolderVerifiesButKeepsNothing() async throws {
        let prepare = FakePrepare()
        let (run, _) = try await self.run(manual: true, feed: feed("v0.8.0"), prepare: prepare,
                                          context: context(holder: false))
        XCTAssertNil(run.kept)
        XCTAssertTrue(prepare.removed.contains(UpdateFixture.staged))
        XCTAssertFalse(alert(run).offersUpdate, "it could only be refused: another Claude Switcher is running")
    }

    /// Two copies at once: the one holding the lock keeps a verified copy, and another copy's
    /// manual check verifies the same release in a staging folder of its own and discards it.
    /// That copy takes only its own folder off the record: the holder's stays named, so if the
    /// holder then crashes, the next launch still finds its folder and tidies it.
    func testAnotherCopysCheckLeavesTheLockHoldersStagingFolderOnRecord() async throws {
        let (store, directory) = try makeTemporaryStore()
        self.directory = directory
        /// Every note lands in the one state.json both copies share, as in the app.
        func sharing(_ fake: FakePrepare) -> SwitcherUpdater.PrepareEnvironment {
            var env = fake.env
            let heard = env.note
            env.note = { note in
                await heard(note)
                _ = try? await store.update(now: Date(timeIntervalSince1970: 1_791_000_000)) { $0.apply(note) }
            }
            return env
        }

        let holder = FakePrepare()
        let kept = await SwitcherUpdater.runCheck(manual: false, context: context(), store: store, check: feed("v0.8.0"),
                                                  prepare: sharing(holder))
        XCTAssertEqual(kept.kept?.stagedAppPath, UpdateFixture.staged)
        let before = await store.load(now: now).staging
        XCTAssertEqual(before, [UpdateFixture.staging])

        let otherFolder = UpdateFixture.temporaryItems + "/NSIRD_claude-switcher_OTHER"
        let other = FakePrepare(staging: otherFolder)
        let manual = await SwitcherUpdater.runCheck(manual: true, context: context(holder: false), store: store,
                                                    check: feed("v0.8.0"), prepare: sharing(other))
        guard case .success? = manual.prepared else { return XCTFail("\(String(describing: manual.prepared))") }
        XCTAssertNil(manual.kept)
        XCTAssertEqual(other.notes, [.staging(otherFolder), .stagingGone(otherFolder)], "its own folder, on and off the record")
        XCTAssertEqual(other.removed.filter { $0.hasPrefix(UpdateFixture.temporaryItems) }, [other.staged])
        XCTAssertEqual(other.removedFolders, [otherFolder])
        let after = await store.load(now: now)
        XCTAssertEqual(after.staging, [UpdateFixture.staging], "the holder's folder is still named")
        XCTAssertEqual(manual.state.staging, [UpdateFixture.staging])

        // The holder crashes; the next launch tidies the folder it finds named.
        var state = after
        let next = FakePrepare()
        next.directories = [UpdateFixture.staging: [DirectoryEntry(name: SwitcherDisk.appName, kind: .directory)]]
        next.kinds = [UpdateFixture.staged: .directory]
        next.bundleIdentifiers = [UpdateFixture.staged: UpdateFixture.bundleID]
        let findings = SwitcherUpdater.reconcile(state: &state, isLockHolder: true, updatesDirectory: UpdateFixture.updates,
                                                 temporaryItems: UpdateFixture.temporaryItems,
                                                 running: UpdateFixture.runningCopy(), env: next.env)
        XCTAssertEqual(next.trashed, [UpdateFixture.staged], "0.8.0 was never put in place: to the Trash, not deleted")
        XCTAssertEqual(next.removedFolders, [UpdateFixture.staging])
        XCTAssertEqual(next.removed, [], "nothing of a copy is ever removed here")
        XCTAssertNil(state.staging)
        XCTAssertTrue(findings.contains { $0.hasPrefix("moved a copy left in a temporary folder to ") }, "\(findings)")
    }

    /// Each copy adds and takes off only its own folder, whatever order they come in.
    func testANoteTakesOnlyItsOwnStagingFolderOffTheRecord() {
        let mine = UpdateFixture.staging, theirs = UpdateFixture.temporaryItems + "/NSIRD_claude-switcher_OTHER"
        var state = SwitcherUpdateState()
        state.apply(.staging(mine))
        state.apply(.staging(theirs))
        state.apply(.staging(mine))
        XCTAssertEqual(state.staging, [theirs, mine], "once each")
        state.apply(.stagingGone(theirs))
        XCTAssertEqual(state.staging, [mine])
        state.apply(.stagingGone(theirs))
        XCTAssertEqual(state.staging, [mine], "a folder not on record takes nothing else with it")
        state.apply(.stagingGone(mine))
        XCTAssertNil(state.staging)
    }

    /// "Update & Relaunch" is offered only by the copy that kept the verified release — the one
    /// holding the lock. Any other copy could only be refused, so it says which copy updates
    /// itself and offers OK alone.
    func testOnlyTheCopyThatKeptTheReleaseOffersUpdateAndRelaunch() {
        let prepared = UpdateFixture.prepared()
        func shown(keeps: Bool) -> SwitcherAlert {
            SwitcherUpdateAlerts.manualCheck(action: .prepare(prepared.candidate), prepared: .success(prepared),
                                             running: UpdateFixture.v070, installability: .installable,
                                             keepsVerifiedCopy: keeps)
        }
        let other = shown(keeps: false)
        XCTAssertEqual(other.title, "Claude Switcher 0.8.0 is available")
        XCTAssertEqual(other.message, "You have 0.7.0. Another Claude Switcher is running, and it is the one that updates "
                       + "itself to 0.8.0; this copy does not replace itself while that one runs.")
        XCTAssertEqual(other.buttons.map(\.title), ["OK"])
        XCTAssertFalse(other.offersUpdate)
        XCTAssertFalse(other.offersDownloadPage)

        let holder = shown(keeps: true)
        XCTAssertEqual(holder.buttons.map(\.title), ["Update & Relaunch", "Later"])
        XCTAssertTrue(holder.offersUpdate)
    }

    /// What holds the relaunch back is named, whichever it is — not always a session copy.
    func testTheAlertNamesTheWorkTheRelaunchWaitsFor() async throws {
        let (run, _) = try await self.run(manual: true, feed: feed("v0.8.0"), prepare: FakePrepare())
        XCTAssertFalse(alert(run).message.contains("Right now"))
        for blocker in SwitcherIdle.hard.sorted(by: { $0.rawValue < $1.rawValue }) {
            let message = alert(run, hardBlocker: blocker).message
            XCTAssertTrue(message.hasSuffix(" Right now \(blocker.description); Claude Switcher relaunches as soon as "
                                            + "that is done."), message)
        }
        XCTAssertFalse(alert(run, hardBlocker: .claudeUpdateInFlight).message.contains("session copy"))
    }

    /// The alert is built from what prepare came to, not from what the feed said.
    func testTheAlertNeverSaysAvailableFromTheFeedAlone() {
        let candidate = UpdateFixture.candidate()
        for installability: Installability in [.installable, .checksOnly(.notNotarized)] {
            let shown = SwitcherUpdateAlerts.manualCheck(action: .prepare(candidate), prepared: nil,
                                                         running: UpdateFixture.v070, installability: installability,
                                                         keepsVerifiedCopy: true)
            XCTAssertFalse(shown.title.contains("is available"))
            XCTAssertFalse(shown.offersDownloadPage)
            XCTAssertFalse(shown.offersUpdate)
            let transient = SwitcherUpdateAlerts.manualCheck(
                action: .prepare(candidate), prepared: .failure(.transient(.download, "offline")),
                running: UpdateFixture.v070, installability: installability, keepsVerifiedCopy: true)
            XCTAssertEqual(transient.title, "Could not check for Claude Switcher updates")
            XCTAssertFalse(transient.offersDownloadPage)
        }
    }

    func testThreeRejectedReleasesPauseAutomaticChecksAndAManualOneRunsAgain() async throws {
        let (store, directory) = try makeTemporaryStore()
        self.directory = directory
        for byte in ["01", "02", "03"] {
            let digest = String(repeating: byte, count: 32)
            let prepare = FakePrepare(candidate: UpdateFixture.candidate(digest: digest))
            prepare.signatureFailures["dmg+req"] = SignatureRefusal(status: -67050, message: "x")
            let (run, _) = try await self.run(manual: false, feed: feed("v0.8.0", digest: digest), prepare: prepare, store: store)
            XCTAssertEqual(prepare.downloads, 1)
            XCTAssertTrue(prepare.removed.contains(prepare.dmg), "a rejected release's image is deleted")
            XCTAssertNotNil(run.state.rejected)
        }
        let paused = FakePrepare(candidate: UpdateFixture.candidate(digest: String(repeating: "04", count: 32)))
        let (automatic, _) = try await run(manual: false, feed: feed("v0.8.0", digest: String(repeating: "04", count: 32)),
                                           prepare: paused, store: store)
        XCTAssertEqual(automatic.state.downloadsPaused, true)
        XCTAssertEqual(paused.downloads, 0)

        let (manual, _) = try await run(manual: true, feed: feed("v0.8.0", digest: String(repeating: "04", count: 32)),
                                        prepare: paused, store: store)
        XCTAssertEqual(paused.downloads, 1)
        XCTAssertNil(manual.state.downloadsPaused)
        XCTAssertNotNil(manual.kept)
    }

    // MARK: A verified copy this process already keeps

    /// The same release again — the next automatic check, or the user asking — is not fetched,
    /// attached or staged a second time; the copy already kept is the one offered.
    func testTheReleaseAlreadyKeptIsNotPreparedAgain() async throws {
        let held = UpdateFixture.prepared()
        for manual in [false, true] {
            let prepare = FakePrepare()
            prepare.keepsStagedCopyFromAnEarlierCheck()
            let heard = Heard()
            let (run, _) = try await self.run(manual: manual, feed: feed("v0.8.0"), prepare: prepare,
                                              context: context(prepared: held), preparing: { heard.add($0.tag) })
            XCTAssertEqual(prepare.steps, [], "manual: \(manual)")
            XCTAssertEqual(prepare.downloads, 0)
            XCTAssertEqual(prepare.attaches, 0)
            XCTAssertEqual(prepare.removed, [], "the kept copy stays")
            XCTAssertEqual(heard.values, [], "nothing is being prepared")
            XCTAssertEqual(run.kept, held)
            XCTAssertEqual(run.prepared, .success(held))
            XCTAssertEqual(run.state.prepared, held)
            if manual {
                XCTAssertEqual(alert(run).buttons.map(\.title), ["Update & Relaunch", "Later"])
            }
        }
    }

    /// A newer release is now the latest: the kept copy and its disk image go before the new
    /// one is fetched, and the new one is kept instead.
    func testANewerLatestReleaseReplacesTheKeptCopy() async throws {
        let v081 = ReleaseVersion(major: 0, minor: 8, patch: 1)
        let prepare = FakePrepare(candidate: UpdateFixture.candidate(v081))
        prepare.keepsStagedCopyFromAnEarlierCheck()
        let (run, _) = try await self.run(manual: false, feed: feed("v0.8.1"), prepare: prepare,
                                          context: context(prepared: UpdateFixture.prepared()))
        let removedOld = try XCTUnwrap(prepare.events.firstIndex(of: "remove \(UpdateFixture.staged)"))
        let download = try XCTUnwrap(prepare.events.firstIndex { $0.hasPrefix("download ") })
        XCTAssertLessThan(removedOld, download)
        XCTAssertTrue(prepare.removed.contains(UpdateFixture.updates + "/downloads/v0.8.0"))
        XCTAssertEqual(run.kept?.version, v081)
        XCTAssertEqual(run.state.prepared?.version, v081)
    }

    /// The kept release is no longer the latest because it was withdrawn: it is not installed.
    func testAWithdrawnReleaseIsNotKept() async throws {
        let prepare = FakePrepare()
        prepare.keepsStagedCopyFromAnEarlierCheck()
        let (store, directory) = try makeTemporaryStore()
        self.directory = directory
        try await store.update(now: now) { $0.prepared = UpdateFixture.prepared() }
        let (run, _) = try await self.run(manual: false, feed: feed("v0.7.0"), prepare: prepare,
                                          context: context(prepared: UpdateFixture.prepared()), store: store)
        XCTAssertNil(run.kept)
        XCTAssertTrue(prepare.removed.contains(UpdateFixture.staged))
        XCTAssertTrue(prepare.removed.contains(UpdateFixture.updates + "/downloads/v0.8.0"))
        XCTAssertNil(run.state.prepared)
        XCTAssertEqual(prepare.downloads, 0)
    }

    /// A check that never reached the feed says nothing about the kept release: it stays.
    func testACheckThatFailsKeepsTheKeptCopy() async throws {
        let held = UpdateFixture.prepared()
        let prepare = FakePrepare()
        prepare.keepsStagedCopyFromAnEarlierCheck()
        let now = self.now
        let offline = SwitcherUpdater.CheckEnvironment(fetch: { _ in .transport("offline") }, now: { now })
        let (run, _) = try await self.run(manual: false, feed: offline, prepare: prepare, context: context(prepared: held))
        XCTAssertEqual(run.kept, held)
        XCTAssertEqual(prepare.removed, [])
    }

    /// The app hears which release is about to be fetched before the first step of it, so its
    /// progress line can name the version.
    func testTheAppIsToldWhichReleaseIsPreparedBeforeAnythingIsFetched() async throws {
        let prepare = FakePrepare()
        let heard = Heard()
        _ = try await self.run(manual: false, feed: feed("v0.8.0"), prepare: prepare,
                               preparing: { heard.add("\($0.tag) after \(prepare.steps.count) steps") })
        XCTAssertEqual(heard.values, ["v0.8.0 after 0 steps"])
        XCTAssertEqual(prepare.downloads, 1)
    }

    /// A transient failure is retried after 1 h, then 2 h — by bringing the next check forward,
    /// since a retry only ever follows a check — not at the usual six hours.
    func testATransientFailureBringsTheNextCheckForwardToItsBackoff() async throws {
        let (store, directory) = try makeTemporaryStore()
        self.directory = directory
        var at = now
        for wait: TimeInterval in [3600, 7200] {
            let prepare = FakePrepare()
            prepare.clock = at
            prepare.downloadRefusal = .transient(.download, "the network connection was lost")
            let (run, _) = try await self.run(manual: false, feed: feed("v0.8.0", at: at), prepare: prepare, store: store)
            XCTAssertEqual(prepare.downloads, 1)
            XCTAssertEqual(run.state.nextCheckNotBefore, at.addingTimeInterval(wait))
            XCTAssertFalse(SwitcherUpdatePolicy.isDue(state: run.state, now: at.addingTimeInterval(wait - 60), settingOn: true))
            XCTAssertTrue(SwitcherUpdatePolicy.isDue(state: run.state, now: at.addingTimeInterval(wait), settingOn: true))
            at = at.addingTimeInterval(wait)
        }

        // Not really tried — no room — leaves the usual schedule alone.
        let full = FakePrepare()
        full.clock = at
        full.freeBytes = 1
        let (run, _) = try await self.run(manual: false, feed: feed("v0.8.0", at: at), prepare: full, store: store)
        XCTAssertEqual(run.state.nextCheckNotBefore, at.addingTimeInterval(6 * 3600))
    }

    func testACheckRecordsWhenItRanAndWhenTheNextIsDue() async throws {
        let prepare = FakePrepare()
        let (run, store) = try await self.run(manual: false, feed: feed("v0.7.0"), prepare: prepare)
        XCTAssertEqual(run.decision.action, .upToDate(running: UpdateFixture.v070, latest: UpdateFixture.v070))
        let state = await store.load(now: now)
        XCTAssertEqual(state.lastCheckAt, now)
        XCTAssertEqual(state.nextCheckNotBefore, now.addingTimeInterval(6 * 3600))
        XCTAssertEqual(state.candidate?.tag, "v0.7.0")
        XCTAssertEqual(state.host, UpdateFixture.host)
        XCTAssertEqual(prepare.downloads, 0)
    }
}
