import XCTest
@testable import ClaudeSwitcherCore

// MARK: - The fake

/// A scripted stand-in for the machine: running instances, the installed version and
/// Claude's installer, advanced only by the sequence's own calls to `sleep`.
@MainActor
final class FakeClaude {

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
    /// The installer only waits for the instances it saw when IT started; one opened later
    /// does not hold it up.
    var installStartsDespiteInstances = false
    /// How long after the installer exits its relaunched instance becomes visible.
    var installerReopenDelay = Duration.zero

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

    /// Effects for the launch-only sequences. There is deliberately no `terminate` here.
    var launchOnly: UpdateInstaller.LaunchOnly {
        UpdateInstaller.LaunchOnly(
            runningInstances: { self.instances },
            installedVersion: { self.version },
            updaterIsRunning: { self.installerRunning },
            launch: { self.launch($0) },
            sleep: { self.advance(by: $0) }
        )
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

    /// An instance going away by itself (a stealth update, a user quit) — not via `terminate`.
    func quitByItself(_ pid: pid_t, after delay: Duration = .zero) {
        schedule(after: delay) { $0.instances.removeAll { $0.pid == pid } }
    }

    private func terminate(_ pid: pid_t) -> Bool {
        terminated.append(pid)
        guard !rejectsTerminate.contains(pid) else { return false }
        if !ignoresQuit.contains(pid) {
            schedule(after: quitDelay) { $0.instances.removeAll { $0.pid == pid } }
        }
        return true
    }

    /// Called on every launch, after it is recorded — lets a test change the world mid-sequence.
    var onLaunch: ((FakeClaude, Profile) -> Void)?

    private func launch(_ profile: Profile) {
        defer { onLaunch?(self, profile) }
        launched.append(profile.id)
        installerWasRunningAtLaunch.append(installerRunning)
        launchedAt.append(slept)
        guard !neverAppears.contains(profile.id) else { return }
        nextPID += 1
        let instance = RunningInstance(pid: nextPID, profile: InstanceManager.binding(for: profile))
        schedule(after: .seconds(1)) { $0.instances.append(instance) }
    }

    /// No sequence under test needs more than a few minutes of virtual time. Past this, a loop
    /// has lost its bound: fail loudly and let go of everything it could be waiting on, so a
    /// regression shows up as a failing test rather than a hung one.
    static let runawayLimit = Duration.seconds(3600)
    private(set) var ranAway = false

    private func advance(by duration: Duration) {
        slept += duration
        if slept > Self.runawayLimit, !ranAway {
            ranAway = true
            XCTFail("a sequence slept for over an hour of virtual time — a loop has no bound")
            installerRunning = false
            instances = []
            events = []
            return
        }
        fireDueEvents()
        // The installer goes to work the moment nothing is running — exactly what it waits for.
        if instances.isEmpty || installStartsDespiteInstances, installerRunning, !installStarted {
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
        if installerReopenDelay > .zero {
            schedule(after: installerReopenDelay) { $0.instances.append(reopened) }
        } else {
            instances.append(reopened)
        }
        if let delay = unknownResolvesAfter {
            schedule(after: delay) { fake in
                fake.instances = fake.instances.map {
                    $0.pid == reopened.pid ? RunningInstance(pid: $0.pid, profile: .defaultProfile) : $0
                }
            }
        }
    }
}
