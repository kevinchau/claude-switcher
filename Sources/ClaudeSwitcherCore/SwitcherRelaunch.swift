import Darwin
import Foundation

/// The hand-over between the copy that replaced itself and the copy it started. The automation
/// lock is the ordering: the old process holds it until the kernel releases it at exit, and the
/// new one shows nothing until it has it — so there are never two icons.
public enum SwitcherRelaunch {

    /// Internal: `--after-update <pid of the copy that started this one>`.
    public static let argument = "--after-update"
    public static let lockRetryInterval: Duration = .milliseconds(250)
    public static let lockRetryLimit: Duration = .seconds(60)
    /// How long a relaunch waits for a menu or window to close before going ahead anyway.
    public static let relaunchDeferralLimit: Duration = .seconds(300)
    public static let launchDeadline: TimeInterval = 60
    /// A start that gets this far after the status item is up deletes its start marker.
    public static let steadyStateDelay: Duration = .seconds(60)

    public static func launchArguments(oldPID: Int32) -> [String] { [argument, String(oldPID)] }

    /// The old pid from the command line, when it names one (an Int32 above 1); otherwise `nil`.
    public static func afterUpdatePID(in arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
              let pid = Int32(arguments[index + 1]), pid > 1
        else { return nil }
        return pid
    }

    public struct StartupEnvironment: Sendable {
        public var take: @MainActor () -> AutomationLock.Acquisition
        public var sleep: @MainActor (Duration) async -> Void
        public var now: @MainActor () -> Date
        /// Writes the finding into `state.json`.
        public var recordFinding: @MainActor (String) async -> Void
        /// Takes back this start's count in `starting.json` (``SwitcherUpdateStore/withdrawStart(version:)``).
        public var withdrawStart: @MainActor () async -> Void
        public var terminateSelf: @MainActor () -> Void
        public var showStatusItem: @MainActor () -> Void

        public init(take: @escaping @MainActor () -> AutomationLock.Acquisition,
                    sleep: @escaping @MainActor (Duration) async -> Void,
                    now: @escaping @MainActor () -> Date,
                    recordFinding: @escaping @MainActor (String) async -> Void,
                    withdrawStart: @escaping @MainActor () async -> Void,
                    terminateSelf: @escaping @MainActor () -> Void,
                    showStatusItem: @escaping @MainActor () -> Void) {
            self.take = take
            self.sleep = sleep
            self.now = now
            self.recordFinding = recordFinding
            self.withdrawStart = withdrawStart
            self.terminateSelf = terminateSelf
            self.showStatusItem = showStatusItem
        }
    }

    public enum StartOutcome: Equatable, Sendable {
        case lock(AutomationLock.Acquisition)
        /// Started after an update, and the copy that started it never let go of the lock: this
        /// one exits without ever showing an icon.
        case exiting(String)
    }

    /// Takes the lock — retrying for up to a minute when started after an update — and only then
    /// shows the status item. Without `--after-update` it is one take and no retry, as before.
    @MainActor
    public static func start(launchedAfterUpdate oldPID: Int32?, env: StartupEnvironment) async -> StartOutcome {
        var acquisition = env.take()
        if let oldPID {
            var waited = Duration.zero
            while acquisition == .heldElsewhere, waited < lockRetryLimit {
                await env.sleep(lockRetryInterval)
                waited += lockRetryInterval
                acquisition = env.take()
            }
            if acquisition == .heldElsewhere {
                let finding = "a relaunch at \(SwitcherUpdateText.time(env.now())) found pid \(oldPID) still running and exited"
                await env.recordFinding(finding)
                await env.withdrawStart()
                env.terminateSelf()
                return .exiting(finding)
            }
        }
        env.showStatusItem()
        return .lock(acquisition)
    }

    /// Waits for a launch whose answer arrives through a completion handler, for at most
    /// `deadline` seconds. The first answer wins; a late one is ignored.
    @MainActor
    public static func awaitLaunch(
        deadline: TimeInterval = launchDeadline,
        _ start: (@escaping @Sendable (Result<Int32, RelaunchFailure>) -> Void) -> Void
    ) async -> Result<Int32, RelaunchFailure> {
        await withCheckedContinuation { continuation in
            let once = FirstAnswer(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                once.resume(.failure(RelaunchFailure(reason: "it did not start within \(Int(deadline)) seconds")))
            }
            start { once.resume($0) }
        }
    }
}

/// Resumes a continuation once, whichever answer comes first.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
