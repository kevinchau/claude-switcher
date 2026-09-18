import Darwin
import Foundation

/// The note a Claude profile leaves when it quits *in order to install an update*.
public struct UpdateAttempt: Equatable, Sendable {
    /// The app version that was running when the profile went down.
    public let fromVersion: String
    /// What it expected to become. Carries a "Claude " prefix; shown, never compared.
    public let toVersion: String?
    public let at: Date

    public init(fromVersion: String, toVersion: String?, at: Date) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.at = at
    }
}

/// Reads `update-attempt`, the marker Claude writes into a profile's user-data directory on
/// every quit-for-update — the idle "stealth" update and "install now" — and on no other
/// quit. That profile's next launch reads and deletes it.
///
/// So a marker that is still there says precisely: this profile closed itself for an update
/// and has not been opened since. Read-only: the marker is never written, moved or deleted
/// here, and nothing else in the directory is opened (its `config.json` holds a token cache).
public enum UpdateAttemptMarker {

    public static let fileName = "update-attempt"
    private static let maximumSize = 64 * 1024

    public static func fileURL(forUserDataDir dir: String?, home: String = NSHomeDirectory()) -> URL {
        let directory = dir.map { PathNormalizer.normalize($0, home: home) } ?? Config.defaultUserDataDir(home: home)
        return URL(fileURLWithPath: directory).appendingPathComponent(fileName)
    }

    /// `nil` for anything that is not a marker: no version, no timestamp, not JSON.
    public static func parse(_ data: Data) -> UpdateAttempt? {
        guard data.count <= maximumSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let from = object["fromVersion"] as? String, !from.isEmpty,
              let milliseconds = object["ts"] as? NSNumber,
              CFGetTypeID(milliseconds) != CFBooleanGetTypeID(),
              milliseconds.doubleValue.isFinite, milliseconds.doubleValue > 0
        else { return nil }
        return UpdateAttempt(
            fromVersion: from,
            toVersion: object["toVersion"] as? String,
            at: Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        )
    }

    public static func read(userDataDir: String?, home: String = NSHomeDirectory()) -> UpdateAttempt? {
        guard let data = try? Data(contentsOf: fileURL(forUserDataDir: userDataDir, home: home)) else { return nil }
        return parse(data)
    }
}

/// Reopens profiles that closed themselves to install a Claude update.
///
/// Claude's installer relaunches the app with no arguments, so after an update only the
/// default profile comes back; a named profile stays closed until someone notices. This puts
/// it back — and that is all it can do. Its environment has no way to quit anything: the
/// switcher acts on its own initiative only ever to launch.
public enum UpdateReopen {

    public struct Environment: Sendable {
        public var steps: UpdateInstaller.LaunchOnly
        public var marker: @MainActor (Profile) -> UpdateAttempt?
        public var now: @MainActor () -> Date
        /// When the Mac last started; a marker from before that is history, not a to-do.
        public var bootTime: @MainActor () -> Date?
        /// Claims the app's one launch slot. `false` while a launch the user asked for, or the
        /// confirmed quit-and-install flow, holds it — two launchers must never both decide
        /// "not running yet" about the same profile.
        public var claimLaunching: @MainActor () -> Bool
        public var releaseLaunching: @MainActor () -> Void

        public init(
            steps: UpdateInstaller.LaunchOnly,
            marker: @escaping @MainActor (Profile) -> UpdateAttempt?,
            now: @escaping @MainActor () -> Date,
            bootTime: @escaping @MainActor () -> Date?,
            claimLaunching: @escaping @MainActor () -> Bool,
            releaseLaunching: @escaping @MainActor () -> Void
        ) {
            self.steps = steps
            self.marker = marker
            self.now = now
            self.bootTime = bootTime
            self.claimLaunching = claimLaunching
            self.releaseLaunching = releaseLaunching
        }

        /// The real thing. Profiles are started in the background, without taking focus.
        public static func live(
            appPath: String,
            bundleID: String,
            claimLaunching: @escaping @MainActor () -> Bool,
            releaseLaunching: @escaping @MainActor () -> Void
        ) -> Environment {
            Environment(
                steps: .live(appPath: appPath, bundleID: bundleID, activates: false),
                marker: { UpdateAttemptMarker.read(userDataDir: $0.userDataDir) },
                now: { Date() },
                bootTime: { UpdateReopen.systemBootTime() },
                claimLaunching: claimLaunching,
                releaseLaunching: releaseLaunching
            )
        }
    }

    public struct Timing: Equatable, Sendable {
        public var base = UpdateInstaller.Timing()
        /// Installer alive, an instance still up, version unchanged for this long: the update
        /// is blocked, and reopening would only have the profile quit itself again.
        public var blockedGrace: Duration = .seconds(10)
        public var claimTimeout: Duration = .seconds(60)
        /// How long the installer must have been gone before the *default* profile is started.
        /// Claude's installer relaunches the default profile itself, just before it exits; a
        /// default profile still absent this long afterwards was not relaunched.
        public var defaultProfileQuietPeriod: Duration = .seconds(15)
        public var maximumMarkerAge: TimeInterval = 24 * 3600

        public init() {}
    }

    public struct Reopened: Equatable, Sendable {
        public let profile: Profile
        public let attempt: UpdateAttempt
    }

    public enum Outcome: Equatable, Sendable {
        /// No profile is waiting to be reopened.
        case nothingToDo
        /// Another instance is keeping Claude's installer from starting. Nothing was launched:
        /// a profile reopened now would only quit itself for the same update again.
        case blocked
        /// The installer was still going at the deadline. Nothing was launched.
        case updaterStuck
        /// The installer is done and nothing qualifies: the update did not apply, or every
        /// profile that closed for it is already back. Nothing was launched.
        case notInstalled
        /// The launch slot stayed taken. Nothing was launched; the next trigger tries again.
        case busy
        case reopened(AppVersion, [Reopened], notReopened: [Profile])
    }

    // MARK: - Which profiles

    /// Profiles with an update marker that are still closed — whether or not the update is in.
    static func waiting(
        profiles: [Profile],
        running: [RunningInstance],
        markers: [String: UpdateAttempt],
        now: Date,
        bootTime: Date?,
        maximumAge: TimeInterval,
        handled: [String: Date]
    ) -> [Profile] {
        profiles.filter { profile in
            guard let marker = markers[profile.id],
                  !ProfileMatching.isRunning(profile, in: running),
                  handled[profile.id] != marker.at
            else { return false }
            let age = now.timeIntervalSince(marker.at)
            guard age >= -60, age <= maximumAge else { return false }   // not from the future, not stale
            if let bootTime, marker.at < bootTime { return false }
            return true
        }
    }

    /// The waiting profiles whose update has actually been installed: the version on disk is
    /// no longer the one they went down on. Named profiles first, the default profile last.
    public static func candidates(
        profiles: [Profile],
        running: [RunningInstance],
        markers: [String: UpdateAttempt],
        installed: AppVersion?,
        now: Date,
        bootTime: Date?,
        maximumAge: TimeInterval = Timing().maximumMarkerAge,
        handled: [String: Date] = [:]
    ) -> [Profile] {
        guard let installed else { return [] }
        let ready = waiting(profiles: profiles, running: running, markers: markers, now: now,
                            bootTime: bootTime, maximumAge: maximumAge, handled: handled)
            .filter { markers[$0.id]?.fromVersion != installed.short }
        return UpdateInstaller.reopenOrder(ready)
    }

    // MARK: - The sequence

    @MainActor
    public static func run(
        profiles: [Profile],
        handled: [String: Date] = [:],
        environment: Environment,
        timing: Timing = Timing()
    ) async -> Outcome {
        precondition(timing.base.poll > .zero, "a zero poll interval would spin the main actor")
        let steps = environment.steps

        func markers() -> [String: UpdateAttempt] {
            var found: [String: UpdateAttempt] = [:]
            for profile in profiles { found[profile.id] = environment.marker(profile) }
            return found
        }
        func stillWaiting() -> [Profile] {
            waiting(profiles: profiles, running: steps.runningInstances(), markers: markers(),
                    now: environment.now(), bootTime: environment.bootTime(),
                    maximumAge: timing.maximumMarkerAge, handled: handled)
        }
        func ready() -> [Profile] {
            candidates(profiles: profiles, running: steps.runningInstances(), markers: markers(),
                       installed: steps.installedVersion(), now: environment.now(),
                       bootTime: environment.bootTime(), maximumAge: timing.maximumMarkerAge, handled: handled)
        }

        // AppKit can still list an app for a moment after announcing that it quit.
        await steps.sleep(timing.base.poll)
        guard !stillWaiting().isEmpty else { return .nothingToDo }

        /// Some waiting profile went down on the version that is still installed: its update has
        /// not happened yet. (A version that cannot be read — mid-swap — is not "still the same".)
        func updateStillPending() -> Bool {
            guard let installed = steps.installedVersion() else { return false }
            let found = markers()
            return stillWaiting().contains { found[$0.id]?.fromVersion == installed.short }
        }

        // Blocked: the installer is waiting on an instance that is still up, and the update has
        // not gone in. No timer is left running — it cannot start without another instance
        // quitting, which triggers us again. An installer that is merely lingering after a
        // finished install is not "blocked"; it is waited out below.
        let baseline = steps.installedVersion()
        var held = Duration.zero
        while steps.updaterIsRunning(), !steps.runningInstances().isEmpty, updateStillPending() {
            if held >= timing.blockedGrace { return .blocked }
            await steps.sleep(timing.base.poll)
            held += timing.base.poll
        }

        // Nothing is launched until the installer has stayed gone. `installerFinished` can also
        // give up waiting on one that lingers after installing; the confirmed flow accepts
        // that, but nothing automatic launches while an installer is alive.
        guard await UpdateInstaller.installerFinished(since: baseline, steps, timing.base),
              !steps.updaterIsRunning()
        else { return .updaterStuck }

        guard let installed = steps.installedVersion(), !ready().isEmpty else { return .notInstalled }

        var waited = Duration.zero
        while !environment.claimLaunching() {
            if waited >= timing.claimTimeout { return .busy }
            await steps.sleep(timing.base.poll)
            waited += timing.base.poll
        }
        defer { environment.releaseLaunching() }

        // The world may have moved while we waited for the slot.
        guard !steps.updaterIsRunning() else { return .updaterStuck }
        let attempts = markers()
        let toOpen = ready()
        guard !toOpen.isEmpty else { return .nothingToDo }

        // Named profiles now. The default profile only after a quiet period, and only if it is
        // still absent then: the installer's own relaunch of it must always get there first.
        let named = toOpen.filter { InstanceManager.binding(for: $0) != .defaultProfile }
        var notReopened = await UpdateInstaller.reopen(named, steps, timing.base, { _ in },
                                                       whileAllowed: { !steps.updaterIsRunning() })
        if toOpen.count > named.count {
            await steps.sleep(timing.defaultProfileQuietPeriod)
            let defaults = ready().filter { InstanceManager.binding(for: $0) == .defaultProfile }
            notReopened += await UpdateInstaller.reopen(defaults, steps, timing.base, { _ in },
                                                        whileAllowed: { !steps.updaterIsRunning() })
        }
        let stillClosed = Set(ready().map(\.id)).union(notReopened.map(\.id))
        let reopened = toOpen
            .filter { !stillClosed.contains($0.id) && ProfileMatching.isRunning($0, in: steps.runningInstances()) }
            .compactMap { profile in attempts[profile.id].map { Reopened(profile: profile, attempt: $0) } }
        return .reopened(installed, reopened, notReopened: notReopened)
    }

    // MARK: - System

    /// When the Mac last booted, from `kern.boottime` (unlike uptime, it does not pause for sleep).
    public static func systemBootTime() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }
}
