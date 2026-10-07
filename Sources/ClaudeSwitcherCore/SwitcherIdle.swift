import Foundation

/// Everything that decides whether Claude Switcher may replace itself right now, as the app sees
/// it on the main actor.
public struct SwitcherIdleSnapshot: Sendable, Equatable {
    public var isMenuOpen = false
    public var isPresentingModal = false
    public var hasPendingAlerts = false
    public var isBusy = false
    public var hasUpdateProgress = false
    public var hasCopyProgress = false
    public var isRecoveringCopies = false
    public var isConsideringReopen = false
    public var isPreparingDiagnostics = false
    public var welcomeWindowIsVisible = false
    public var hasUnshownNotice = false
    public var isCheckingSwitcherUpdate = false
    public var isPreparingSwitcherUpdate = false
    public var lastUserActivity: Date?
    public var now: Date

    public init(now: Date, lastUserActivity: Date? = nil) {
        self.now = now
        self.lastUserActivity = lastUserActivity
    }
}

/// "Nothing is going on": the updater relaunches the app only then, so the menu bar icon never
/// blinks under the user's hand or in the middle of something the app is doing.
public enum SwitcherIdle {
    public static let quietPeriod: Duration = .seconds(90)

    /// In the order they are reported; the first one is what a tooltip names.
    public enum Blocker: String, Sendable, CaseIterable {
        case menuOpen, modal, queuedAlert, launchInFlight, claudeUpdateInFlight, copyInFlight, copyRecovery,
             reopenPass, diagnostics, welcomeWindow, unshownNotice, checkInFlight, prepareInFlight, quietPeriod

        public var description: String {
            switch self {
            case .menuOpen: return "the menu is open"
            case .modal: return "a window is open"
            case .queuedAlert: return "a message is waiting to be shown"
            case .launchInFlight: return "an account is being started"
            case .claudeUpdateInFlight: return "Claude is being updated"
            case .copyInFlight: return "a session copy is running"
            case .copyRecovery: return "an interrupted session copy is being finished"
            case .reopenPass: return "accounts are being reopened after a Claude update"
            case .diagnostics: return "Diagnostics is being prepared"
            case .welcomeWindow: return "the welcome window is open"
            case .unshownNotice: return "a notice has not been seen yet"
            case .checkInFlight: return "a check for updates is running"
            case .prepareInFlight: return "the new version is being downloaded and checked"
            case .quietPeriod: return "Claude Switcher was used less than 90 seconds ago"
            }
        }
    }

    /// Work in flight that even "Update & Relaunch" waits for: relaunching would cut it off.
    public static let hard: Set<Blocker> = [.launchInFlight, .claudeUpdateInFlight, .copyInFlight, .copyRecovery,
                                            .reopenPass, .prepareInFlight]

    /// Every blocker that holds, in ``Blocker`` order. When the user asked, only the hard ones count.
    public static func blockers(_ snapshot: SwitcherIdleSnapshot, userAsked: Bool = false) -> [Blocker] {
        var found: Set<Blocker> = []
        if snapshot.isMenuOpen { found.insert(.menuOpen) }
        if snapshot.isPresentingModal { found.insert(.modal) }
        if snapshot.hasPendingAlerts { found.insert(.queuedAlert) }
        if snapshot.isBusy { found.insert(.launchInFlight) }
        if snapshot.hasUpdateProgress { found.insert(.claudeUpdateInFlight) }
        if snapshot.hasCopyProgress { found.insert(.copyInFlight) }
        if snapshot.isRecoveringCopies { found.insert(.copyRecovery) }
        if snapshot.isConsideringReopen { found.insert(.reopenPass) }
        if snapshot.isPreparingDiagnostics { found.insert(.diagnostics) }
        if snapshot.welcomeWindowIsVisible { found.insert(.welcomeWindow) }
        if snapshot.hasUnshownNotice { found.insert(.unshownNotice) }
        if snapshot.isCheckingSwitcherUpdate { found.insert(.checkInFlight) }
        if snapshot.isPreparingSwitcherUpdate { found.insert(.prepareInFlight) }
        // Bounded both ways: after the clock is set back, the last activity looks like the
        // future, and it must not hold the relaunch off until the clock catches up.
        if let last = snapshot.lastUserActivity,
           abs(snapshot.now.timeIntervalSince(last)) < TimeInterval(quietPeriod.components.seconds) {
            found.insert(.quietPeriod)
        }
        return Blocker.allCases.filter { found.contains($0) && (!userAsked || hard.contains($0)) }
    }
}
