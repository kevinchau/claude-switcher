import XCTest
@testable import ClaudeSwitcherCore

/// The quit → install → reopen sequence, run end to end against `FakeClaude`.
///
/// No process is ever quit, signalled or launched here: every effect is a closure over the
/// fake, and neither `Environment.live` nor `InstanceManager.terminate` is referenced. Time is
/// virtual — `sleep` advances a counter and fires scripted events — so the minute-long
/// deadlines are reached instantly.
final class UpdateInstallerTests: XCTestCase {

    // MARK: - Fixtures

    private let personal = Profile(id: "default", label: "Personal")
    private let work = Profile(id: "work", label: "Work",
                               userDataDir: "/Users/testhome/Library/Application Support/Claude-work")
    private let client = Profile(id: "client", label: "Client",
                                 userDataDir: "/Users/testhome/Library/Application Support/Claude-client")
    private var profiles: [Profile] { [personal, work, client] }

    private let personalUp = RunningInstance(pid: 100, profile: .defaultProfile)
    private let workUp = RunningInstance(
        pid: 200, profile: .directory("/Users/testhome/Library/Application Support/Claude-work"))
    private let strayUp = RunningInstance(pid: 300, profile: .directory("/Users/testhome/removed-profile"))
    private let unknownUp = RunningInstance(pid: 400, profile: .unknown)

    private static let oldVersion = AppVersion(short: "2.110.0", build: "100")
    private static let newVersion = AppVersion(short: "2.110.1", build: "101")

    @MainActor
    private func run(_ fake: FakeClaude, plan: UpdatePlan? = nil) async -> UpdateInstaller.Outcome {
        let plan = plan ?? UpdateInstaller.plan(running: fake.instances, profiles: profiles)
        return await UpdateInstaller.run(plan: plan, environment: fake.environment) { fake.phases.append($0) }
    }

    // MARK: - Planning

    func testPlanQuitsEveryInstanceIncludingUnknownAndUnmatchedOnes() {
        let running = [personalUp, workUp, strayUp, unknownUp]
        let plan = UpdateInstaller.plan(running: running, profiles: profiles)
        XCTAssertEqual(plan.quit, running)
        XCTAssertEqual(plan.strays, [strayUp, unknownUp])
    }

    func testPlanReopensOnlyConfiguredProfilesThatWereRunning() {
        let plan = UpdateInstaller.plan(running: [workUp, strayUp], profiles: profiles)
        XCTAssertEqual(plan.reopen, [work])
    }

    /// The installer may reopen the default profile by itself, so ours goes last — by then
    /// it is either visibly back or visibly not.
    func testPlanReopensNamedProfilesFirstAndTheDefaultProfileLast() {
        let plan = UpdateInstaller.plan(running: [personalUp, workUp], profiles: profiles)
        XCTAssertEqual(plan.reopen.map(\.id), ["work", "default"])
    }

    // MARK: - Consent

    /// The confirmation can sit open for minutes. What gets quit is what was agreed to.
    @MainActor
    func testNothingIsTerminatedWhenTheRunningSetChangedSinceConfirmation() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        let plan = UpdateInstaller.plan(running: [personalUp], profiles: profiles)

        let outcome = await run(fake, plan: plan)

        XCTAssertEqual(outcome, .changedSinceConfirmation)
        XCTAssertEqual(fake.terminated, [])
        XCTAssertEqual(fake.launched, [])
    }

    @MainActor
    func testAnEmptyPlanTerminatesNothing() async {
        let fake = FakeClaude(instances: [])
        let outcome = await run(fake)
        XCTAssertEqual(outcome, .changedSinceConfirmation)
        XCTAssertEqual(fake.terminated, [])
    }

    @MainActor
    func testTerminateIsCalledExactlyOncePerSnapshotPid() async {
        let fake = FakeClaude(instances: [personalUp, workUp, strayUp])
        _ = await run(fake)
        XCTAssertEqual(fake.terminated, [100, 200, 300])
    }

    @MainActor
    func testAnInstanceStartedMidOperationIsNeverTerminated() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        let newcomer = RunningInstance(pid: 999, profile: .directory("/Users/testhome/started-by-hand"))
        fake.schedule(after: .milliseconds(500)) { $0.instances.append(newcomer) }

        let outcome = await run(fake)

        XCTAssertEqual(fake.terminated, [100, 200])
        guard case .quitTimedOut(let stillRunning, _) = outcome else {
            return XCTFail("expected the newcomer to hold the quit open, got \(outcome)")
        }
        XCTAssertEqual(stillRunning.map(\.pid), [999])
    }

    @MainActor
    func testWhenNoInstanceAcceptsTheRequestNothingElseHappens() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.rejectsTerminate = [100, 200]

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .quitRefused)
        XCTAssertEqual(fake.slept, .zero)
        XCTAssertEqual(fake.launched, [])
    }

    // MARK: - The happy path

    @MainActor
    func testProfilesAreReopenedInPlanOrderAfterASuccessfulInstall() async {
        let fake = FakeClaude(instances: [personalUp, workUp])

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .installed(Self.newVersion, notReopened: []))
        XCTAssertEqual(fake.launched, ["work", "default"])
        XCTAssertEqual(fake.instances.count, 2)
    }

    /// Starting a profile while the installer is still at work risks the bundle being
    /// replaced underneath it.
    @MainActor
    func testNothingIsLaunchedUntilTheInstallerHasExited() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        _ = await run(fake)
        XCTAssertEqual(fake.launched.count, 2)
        XCTAssertEqual(fake.installerWasRunningAtLaunch, [false, false])
    }

    @MainActor
    func testPhasesAreReportedInOrder() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        _ = await run(fake)

        var distinct: [UpdateInstaller.Phase] = []
        for phase in fake.phases where phase != distinct.last { distinct.append(phase) }
        XCTAssertEqual(distinct, [
            .quitting([personalUp, workUp]),
            .installing,
            .reopening(work),
            .reopening(personal),
        ])
    }

    @MainActor
    func testStraysAreQuitButNeverReopened() async {
        let fake = FakeClaude(instances: [workUp, strayUp])
        let outcome = await run(fake)
        XCTAssertEqual(outcome, .installed(Self.newVersion, notReopened: []))
        XCTAssertEqual(fake.launched, ["work"])
    }

    // MARK: - Someone else reopened a profile first

    @MainActor
    func testDefaultProfileAlreadyReopenedByTheInstallerIsNotLaunchedASecondTime() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.installerReopens = RunningInstance(pid: 101, profile: .defaultProfile)

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .installed(Self.newVersion, notReopened: []))
        XCTAssertEqual(fake.launched, ["work"])
    }

    /// A process that has only just started can have an unreadable argv for a moment.
    @MainActor
    func testABrieflyUnreadableNewProcessIsWaitedOutAndThenRecognised() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.installerReopens = RunningInstance(pid: 101, profile: .unknown)
        fake.unknownResolvesAfter = .seconds(1)

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .installed(Self.newVersion, notReopened: []))
        XCTAssertEqual(fake.launched, ["work"], "the default profile was already back; only Work needed starting")
    }

    /// An instance we cannot identify might be the very profile we are about to start; a
    /// second process on one profile directory can corrupt that login.
    @MainActor
    func testNothingIsReopenedWhileAnUnidentifiedInstanceIsRunning() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.installerReopens = RunningInstance(pid: 101, profile: .unknown)

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .installed(Self.newVersion, notReopened: [work, personal]))
        XCTAssertEqual(fake.launched, [])
    }

    @MainActor
    func testProfileThatNeverAppearsAfterLaunchIsReportedAsNotReopened() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.neverAppears = ["work"]

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .installed(Self.newVersion, notReopened: [work]))
        XCTAssertEqual(fake.launched, ["work", "default"])
    }

    // MARK: - Instances that will not quit

    /// The installer waits only for the instances it saw when it started, so it may begin the
    /// moment the last of those quits. Reopening a profile now could put it in the way of the
    /// swap — so nothing is reopened, and the outcome says which profiles are left closed.
    @MainActor
    func testInstanceThatRefusesToQuitTimesOutAndNothingIsReopened() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.ignoresQuit = [100]

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .quitTimedOut(stillRunning: [personalUp], closed: [work]))
        XCTAssertEqual(fake.launched, [])
        XCTAssertEqual(fake.version, Self.oldVersion)
    }

    /// If the last instance leaves right at the deadline, the install is on — wait for it.
    @MainActor
    func testLastInstanceExitingRightAtTheDeadlineContinuesToTheInstall() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.quitDelay = UpdateInstaller.Timing().quitTimeout

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .installed(Self.newVersion, notReopened: []))
        XCTAssertEqual(fake.installerWasRunningAtLaunch, [false, false])
    }

    // MARK: - Installs that do not go to plan

    @MainActor
    func testInstallerExitingWithoutAVersionChangeReopensEverythingOnTheOldVersion() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.install = .exitsWithoutInstalling

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .notInstalled(notReopened: []))
        XCTAssertEqual(fake.launched, ["work", "default"])
    }

    /// A failed attempt exits and launchd restarts the installer a moment later; the restarted
    /// one finds nothing running and installs straight away. "Not running" on one poll must
    /// not be read as "finished".
    @MainActor
    func testInstallerThatExitsAndIsRestartedIsWaitedForAgain() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.install = .failsOnceThenIsRestarted

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .installed(Self.newVersion, notReopened: []))
        XCTAssertEqual(fake.installerWasRunningAtLaunch, [false, false])
    }

    /// Without a version to compare against there is no evidence anything was installed.
    @MainActor
    func testUnreadableVersionBeforeTheInstallIsNeverReportedAsInstalled() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.version = nil
        fake.install = .exitsWithoutInstalling
        // Readable again afterwards, and unchanged: "some version, where before there was
        // none" must not count as a new version.
        fake.schedule(after: .seconds(1)) { $0.version = Self.oldVersion }

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .notInstalled(notReopened: []))
        XCTAssertEqual(fake.version, Self.oldVersion)
    }

    @MainActor
    func testWithNoInstallerAtAllEverythingIsStillReopened() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.install = .absent

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .notInstalled(notReopened: []))
        XCTAssertEqual(fake.launched, ["work", "default"])
    }

    @MainActor
    func testInstallerStillRunningAtTheDeadlineReopensNothing() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.install = .hangsBeforeInstalling

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .updaterStuck)
        XCTAssertEqual(fake.launched, [])
    }

    /// While the installer swaps the bundle there is briefly no Info.plist to read.
    @MainActor
    func testUnreadableVersionMidSwapIsNotMistakenForAFinishedInstall() async {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.install = .hangsWithTheBundleUnreadable

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .updaterStuck)
        XCTAssertEqual(fake.launched, [])
    }

    @MainActor
    func testInstallerThatLingersAfterInstallingDoesNotHoldProfilesClosedForever() async throws {
        let fake = FakeClaude(instances: [personalUp, workUp])
        fake.install = .installsThenLingers

        let outcome = await run(fake)

        XCTAssertEqual(outcome, .installed(Self.newVersion, notReopened: []))
        XCTAssertEqual(fake.launched, ["work", "default"])
        XCTAssertLessThan(fake.slept, UpdateInstaller.Timing().installTimeout)

        // …but not before giving it its grace period: quit (2 s) + install (4 s) + grace.
        let earliest = Duration.seconds(6) + UpdateInstaller.Timing().postInstallGrace
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(fake.launchedAt.first), earliest)
    }
}

// MARK: - The fake

/// A scripted stand-in for the machine: running instances, the installed version and
/// Claude's installer, advanced only by the sequence's own calls to `sleep`.
@MainActor
private final class FakeClaude {

    enum Install {
        /// Installs a few seconds after the last instance quits, then exits.
        case succeeds
        case exitsWithoutInstalling
        case absent
        case hangsBeforeInstalling
        case hangsWithTheBundleUnreadable
        case installsThenLingers
        /// Exits without installing, is restarted two seconds later, then installs.
        case failsOnceThenIsRestarted
    }

    // Script
    var install = Install.succeeds { didSet { installerRunning = install != .absent } }
    var quitDelay = Duration.seconds(2)
    var ignoresQuit: Set<pid_t> = []
    var rejectsTerminate: Set<pid_t> = []
    var neverAppears: Set<String> = []
    var installerReopens: RunningInstance?
    var unknownResolvesAfter: Duration?

    // State
    var instances: [RunningInstance]
    var version: AppVersion? = AppVersion(short: "2.110.0", build: "100")
    var installerRunning = true

    // Record
    private(set) var terminated: [pid_t] = []
    private(set) var launched: [String] = []
    private(set) var installerWasRunningAtLaunch: [Bool] = []
    private(set) var launchedAt: [Duration] = []
    private(set) var slept = Duration.zero
    var phases: [UpdateInstaller.Phase] = []

    private var events: [(due: Duration, action: (FakeClaude) -> Void)] = []
    private var installStarted = false
    private var nextPID: pid_t = 5000

    init(instances: [RunningInstance]) {
        self.instances = instances
    }

    var environment: UpdateInstaller.Environment {
        UpdateInstaller.Environment(
            runningInstances: { self.instances },
            terminate: { self.terminate($0) },
            installedVersion: { self.version },
            updaterIsRunning: { self.installerRunning },
            launch: { self.launch($0) },
            sleep: { self.advance(by: $0) }
        )
    }

    func schedule(after delay: Duration, _ action: @escaping (FakeClaude) -> Void) {
        events.append((slept + delay, action))
    }

    private func terminate(_ pid: pid_t) -> Bool {
        terminated.append(pid)
        guard !rejectsTerminate.contains(pid) else { return false }
        if !ignoresQuit.contains(pid) {
            schedule(after: quitDelay) { $0.instances.removeAll { $0.pid == pid } }
        }
        return true
    }

    private func launch(_ profile: Profile) {
        launched.append(profile.id)
        installerWasRunningAtLaunch.append(installerRunning)
        launchedAt.append(slept)
        guard !neverAppears.contains(profile.id) else { return }
        nextPID += 1
        let instance = RunningInstance(pid: nextPID, profile: InstanceManager.binding(for: profile))
        schedule(after: .seconds(1)) { $0.instances.append(instance) }
    }

    private func advance(by duration: Duration) {
        slept += duration
        fireDueEvents()
        // The installer goes to work the moment nothing is running — exactly what it waits for.
        if instances.isEmpty, installerRunning, !installStarted {
            installStarted = true
            scheduleInstall()
        }
    }

    private func fireDueEvents() {
        while let index = events.firstIndex(where: { $0.due <= slept }) {
            let event = events.remove(at: index)
            event.action(self)
        }
    }

    private func scheduleInstall() {
        let newVersion = AppVersion(short: "2.110.1", build: "101")
        switch install {
        case .succeeds:
            schedule(after: .seconds(3)) { $0.version = nil }          // mid-swap
            schedule(after: .seconds(4)) { $0.version = newVersion }
            schedule(after: .seconds(5)) { $0.finishInstall() }
        case .installsThenLingers:
            schedule(after: .seconds(4)) { $0.version = newVersion }
        case .exitsWithoutInstalling:
            schedule(after: .seconds(2)) { $0.finishInstall() }
        case .hangsWithTheBundleUnreadable:
            schedule(after: .seconds(3)) { $0.version = nil }
        case .failsOnceThenIsRestarted:
            schedule(after: .seconds(2)) { $0.installerRunning = false }
            schedule(after: .seconds(4)) { $0.installerRunning = true }
            schedule(after: .seconds(8)) { $0.version = newVersion }
            schedule(after: .seconds(9)) { $0.finishInstall() }
        case .hangsBeforeInstalling, .absent:
            break
        }
    }

    private func finishInstall() {
        installerRunning = false
        guard let reopened = installerReopens else { return }
        instances.append(reopened)
        if let delay = unknownResolvesAfter {
            schedule(after: delay) { fake in
                fake.instances = fake.instances.map {
                    $0.pid == reopened.pid ? RunningInstance(pid: $0.pid, profile: .defaultProfile) : $0
                }
            }
        }
    }
}
