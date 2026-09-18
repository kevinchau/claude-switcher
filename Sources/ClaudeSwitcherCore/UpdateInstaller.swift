import Foundation

/// What "quit everything so the update can install" means for one snapshot of instances.
public struct UpdatePlan: Equatable, Sendable {
    /// Every running instance, recognised or not: the installer waits for the ones it saw when
    /// it started, and none should be running while the bundle is replaced.
    public let quit: [RunningInstance]
    /// The configured profiles that were running, in the order they are reopened: named
    /// profiles first, the default profile last (the installer may reopen that one itself).
    public let reopen: [Profile]
    /// Instances that belong to no configured profile. They are quit too, but there is no
    /// profile to reopen them from.
    public let strays: [RunningInstance]

    public init(quit: [RunningInstance], reopen: [Profile], strays: [RunningInstance]) {
        self.quit = quit
        self.reopen = reopen
        self.strays = strays
    }
}

/// Lets a blocked Claude update install: quit every instance, wait for Claude's own installer
/// to finish, then reopen the profiles that were running.
///
/// This never installs anything itself — the Claude.app bundle is only ever touched by
/// Claude's installer. All this does is get out of its way and put things back afterwards.
///
/// Every effect goes through ``Environment`` so the sequence can be tested end to end without
/// a single real process being quit or launched.
public enum UpdateInstaller {

    // MARK: - Planning

    public static func plan(running: [RunningInstance], profiles: [Profile]) -> UpdatePlan {
        let wasRunning = profiles.filter { ProfileMatching.isRunning($0, in: running) }

        return UpdatePlan(
            quit: running,
            reopen: reopenOrder(wasRunning),
            strays: ProfileMatching.unmatched(running, profiles: profiles)
        )
    }

    /// Named profiles first, the default profile last: Claude's installer may reopen the
    /// default profile itself, and by the time we get to it that is visible.
    public static func reopenOrder(_ profiles: [Profile]) -> [Profile] {
        profiles.filter { InstanceManager.binding(for: $0) != .defaultProfile }
            + profiles.filter { InstanceManager.binding(for: $0) == .defaultProfile }
    }

    // MARK: - Effects

    /// The effects that can only ever start things. Anything that acts without the user
    /// having just asked for it is handed this, and nothing more: there is no way to quit an
    /// instance through it.
    public struct LaunchOnly: Sendable {
        public var runningInstances: @MainActor () -> [RunningInstance]
        public var installedVersion: @MainActor () -> AppVersion?
        public var updaterIsRunning: @MainActor () -> Bool
        /// Starts a profile. Fire-and-forget: success is judged by the profile appearing in
        /// `runningInstances`, because a launch callback is not guaranteed to ever arrive.
        public var launch: @MainActor (Profile) -> Void
        public var sleep: @MainActor (Duration) async -> Void

        public init(
            runningInstances: @escaping @MainActor () -> [RunningInstance],
            installedVersion: @escaping @MainActor () -> AppVersion?,
            updaterIsRunning: @escaping @MainActor () -> Bool,
            launch: @escaping @MainActor (Profile) -> Void,
            sleep: @escaping @MainActor (Duration) async -> Void
        ) {
            self.runningInstances = runningInstances
            self.installedVersion = installedVersion
            self.updaterIsRunning = updaterIsRunning
            self.launch = launch
            self.sleep = sleep
        }

        /// The real thing. `activates: false` starts profiles in the background.
        public static func live(appPath: String, bundleID: String, activates: Bool) -> LaunchOnly {
            LaunchOnly(
                runningInstances: { InstanceManager.runningInstances(appPath: appPath) },
                installedVersion: { UpdateProbe.version(ofBundleAt: PathNormalizer.normalize(appPath)) },
                updaterIsRunning: { UpdateProbe.isUpdaterRunning(bundleID: bundleID) },
                launch: { InstanceManager.launch(profile: $0, appPath: appPath, activates: activates) { _ in } },
                // The tasks running these sequences are never cancelled. If that changes, a
                // cancelled sleep returns at once and every deadline collapses — handle it first.
                sleep: { try? await Task.sleep(for: $0) }
            )
        }
    }

    /// The outside world, as the confirmed quit-and-install sequence sees it.
    public struct Environment: Sendable {
        public var runningInstances: @MainActor () -> [RunningInstance]
        /// Asks one instance to quit; returns whether the request was accepted.
        public var terminate: @MainActor (pid_t) -> Bool
        public var installedVersion: @MainActor () -> AppVersion?
        public var updaterIsRunning: @MainActor () -> Bool
        /// Starts a profile. Fire-and-forget: success is judged by the profile appearing in
        /// `runningInstances`, because a launch callback is not guaranteed to ever arrive.
        public var launch: @MainActor (Profile) -> Void
        public var sleep: @MainActor (Duration) async -> Void

        public init(
            runningInstances: @escaping @MainActor () -> [RunningInstance],
            terminate: @escaping @MainActor (pid_t) -> Bool,
            installedVersion: @escaping @MainActor () -> AppVersion?,
            updaterIsRunning: @escaping @MainActor () -> Bool,
            launch: @escaping @MainActor (Profile) -> Void,
            sleep: @escaping @MainActor (Duration) async -> Void
        ) {
            self.runningInstances = runningInstances
            self.terminate = terminate
            self.installedVersion = installedVersion
            self.updaterIsRunning = updaterIsRunning
            self.launch = launch
            self.sleep = sleep
        }

        /// Everything except the ability to quit.
        public var launchOnly: LaunchOnly {
            LaunchOnly(runningInstances: runningInstances, installedVersion: installedVersion,
                       updaterIsRunning: updaterIsRunning, launch: launch, sleep: sleep)
        }

        /// The real thing. `bundleID` is the identifier read from the app at `appPath`.
        public static func live(appPath: String, bundleID: String) -> Environment {
            Environment(
                runningInstances: { InstanceManager.runningInstances(appPath: appPath) },
                terminate: { InstanceManager.terminate(pid: $0, expecting: bundleID) },
                installedVersion: { UpdateProbe.version(ofBundleAt: PathNormalizer.normalize(appPath)) },
                updaterIsRunning: { UpdateProbe.isUpdaterRunning(bundleID: bundleID) },
                launch: { InstanceManager.launch(profile: $0, appPath: appPath) { _ in } },
                // The task running the sequence is never cancelled. If that changes, a cancelled
                // sleep returns at once and every deadline below collapses — handle it first.
                sleep: { try? await Task.sleep(for: $0) }
            )
        }
    }

    /// How long each step may take. Deadlines count requested sleep time rather than reading
    /// a clock, so a test with an instant `sleep` still reaches them.
    public struct Timing: Equatable, Sendable {
        public var poll: Duration = .milliseconds(500)
        /// Claude runs its own cleanup on quit, and may be showing a dialog of its own.
        public var quitTimeout: Duration = .seconds(60)
        /// Observed installs take about five seconds; this only bounds a wedged installer.
        public var installTimeout: Duration = .seconds(180)
        /// Once the new version is on disk only the installer's own relaunch step remains. If it
        /// lingers past this, profiles are reopened anyway — the one case where something is
        /// launched while the installer is alive, and harmless, because the swap is over.
        public var postInstallGrace: Duration = .seconds(15)
        /// How long the installer must stay gone to count as finished. A failed attempt exits
        /// and launchd restarts it within about two seconds, so one absent poll proves nothing.
        public var settle: Duration = .seconds(3)
        /// A process that has only just started can briefly have an unreadable argv.
        public var unknownGrace: Duration = .seconds(3)
        public var launchTimeout: Duration = .seconds(30)

        public init() {}
    }

    public enum Phase: Equatable, Sendable {
        case quitting([RunningInstance])
        case installing
        case reopening(Profile)
    }

    public enum Outcome: Equatable, Sendable {
        /// The running instances were no longer the ones the user agreed to quit. Nothing was quit.
        case changedSinceConfirmation
        /// No instance accepted the request to quit. Nothing was quit.
        case quitRefused
        /// Some instances were still up at the deadline. Nothing is reopened: the installer only
        /// waits for the instances it saw when it started, so it may begin the moment the last
        /// of *those* quits — and must not find a freshly started profile in its way.
        case quitTimedOut(stillRunning: [RunningInstance], closed: [Profile])
        /// The installer was still going at the deadline. Nothing was reopened, so that the
        /// bundle is never swapped underneath a freshly started instance.
        case updaterStuck
        case installed(AppVersion, notReopened: [Profile])
        /// The installer finished, or was never there, and the version did not change.
        case notInstalled(notReopened: [Profile])
    }

    // MARK: - The sequence

    /// Runs on the main actor, sleeping between polls: AppKit only refreshes its list of
    /// running applications as the main run loop turns.
    @MainActor
    public static func run(
        plan: UpdatePlan,
        environment: Environment,
        timing: Timing = Timing(),
        onPhase: @MainActor (Phase) -> Void = { _ in }
    ) async -> Outcome {
        precondition(timing.poll > .zero, "a zero poll interval would spin the main actor")

        // The confirmation dialog can sit open for minutes. Quit only what was agreed to.
        let agreed = Set(plan.quit.map(\.pid))
        guard !agreed.isEmpty,
              Set(environment.runningInstances().map(\.pid)) == agreed
        else { return .changedSinceConfirmation }

        let before = environment.installedVersion()

        onPhase(.quitting(plan.quit))
        let accepted = plan.quit.filter { environment.terminate($0.pid) }
        guard !accepted.isEmpty else { return .quitRefused }

        // Wait for every instance to go — the same condition the installer waits for.
        var elapsed = Duration.zero
        while true {
            let current = environment.runningInstances()
            if current.isEmpty { break }
            onPhase(.quitting(current))

            if elapsed >= timing.quitTimeout {
                let closed = plan.reopen.filter { !ProfileMatching.isRunning($0, in: current) }
                return .quitTimedOut(stillRunning: current, closed: closed)
            }
            await environment.sleep(timing.poll)
            elapsed += timing.poll
        }

        // Nothing is launched until the installer is done.
        onPhase(.installing)
        let steps = environment.launchOnly
        guard await installerFinished(since: before, steps, timing) else { return .updaterStuck }

        let notReopened = await reopen(plan.reopen, steps, timing, onPhase)
        if let before, let after = environment.installedVersion(), after != before {
            return .installed(after, notReopened: notReopened)
        }
        return .notInstalled(notReopened: notReopened)
    }

    /// Waits for the installer to be done. `false` means it was still going at the deadline.
    @MainActor
    static func installerFinished(
        since before: AppVersion?,
        _ environment: LaunchOnly,
        _ timing: Timing
    ) async -> Bool {
        var elapsed = Duration.zero
        var installedAt: Duration?

        while true {
            if environment.updaterIsRunning() {
                // Mid-swap the bundle briefly has no Info.plist; an unreadable version is not a new one.
                if installedAt == nil, let before, let now = environment.installedVersion(), now != before {
                    installedAt = elapsed
                }
                if let installedAt {
                    if elapsed - installedAt >= timing.postInstallGrace { return true }
                } else if elapsed >= timing.installTimeout {
                    return false
                }
                await environment.sleep(timing.poll)
                elapsed += timing.poll
            } else {
                // Gone — but for good? Only an installer that stays gone has finished.
                await environment.sleep(timing.settle)
                elapsed += timing.settle
                if !environment.updaterIsRunning() { return true }
            }
        }
    }

    /// Starts each profile that is not already up, one at a time, and returns the ones that
    /// could not be reopened.
    @MainActor
    static func reopen(
        _ profiles: [Profile],
        _ environment: LaunchOnly,
        _ timing: Timing,
        _ onPhase: @MainActor (Phase) -> Void,
        whileAllowed mayLaunch: @MainActor () -> Bool = { true }
    ) async -> [Profile] {
        var notReopened: [Profile] = []

        for (index, profile) in profiles.enumerated() {
            // Looked at again before every single launch, not once for the batch.
            guard mayLaunch() else {
                notReopened.append(contentsOf: profiles[index...])
                break
            }

            // An instance we cannot identify might be this very profile — the installer can
            // reopen the default profile itself. Never start a second process on one profile
            // directory: give a fresh process a moment to become readable, else give up.
            var current = environment.runningInstances()
            var waited = Duration.zero
            while current.contains(where: { $0.profile == .unknown }), waited < timing.unknownGrace {
                await environment.sleep(timing.poll)
                waited += timing.poll
                current = environment.runningInstances()
            }
            guard !current.contains(where: { $0.profile == .unknown }) else {
                notReopened.append(profile)
                continue
            }

            // Already back — reopened by the installer, or by the user.
            if ProfileMatching.isRunning(profile, in: current) { continue }

            onPhase(.reopening(profile))
            environment.launch(profile)

            var appeared = false
            var elapsed = Duration.zero
            while !appeared, elapsed < timing.launchTimeout {
                await environment.sleep(timing.poll)
                elapsed += timing.poll
                appeared = ProfileMatching.isRunning(profile, in: environment.runningInstances())
            }
            if !appeared { notReopened.append(profile) }
        }

        return notReopened
    }
}
