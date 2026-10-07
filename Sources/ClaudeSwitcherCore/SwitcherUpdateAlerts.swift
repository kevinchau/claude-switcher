import Foundation

/// The updater's sentences. "Claude" alone is Claude Desktop; the switcher names itself in full.
public enum SwitcherUpdateText {

    public static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func updated(to version: ReleaseVersion, at date: Date) -> String {
        "Claude Switcher updated itself to \(version) at \(time(date))."
    }

    public static func updatedTooltip(from: ReleaseVersion, tag: String, oldCopy: OldCopy?) -> String {
        let kept: String
        switch oldCopy?.kind {
        case .previous?: kept = "The previous copy is kept in ~/.config/claude-switcher/updates/previous."
        case .trash?: kept = "The previous copy was moved to the Trash."
        case .staging?, nil: kept = "The previous copy may still be in a temporary folder; see Diagnostics."
        }
        return "From \(from). \(kept) Release notes: github.com/kevinchau/claude-switcher/releases/tag/\(tag)"
    }

    public static func couldNotUpdate(to version: ReleaseVersion, still running: ReleaseVersion) -> String {
        "Claude Switcher could not update itself to \(version) \u{2014} still \(running). See Diagnostics\u{2026}"
    }

    public static func couldNotGoBack(to version: ReleaseVersion, still running: ReleaseVersion) -> String {
        "Claude Switcher could not go back to \(version) \u{2014} still \(running). See Diagnostics\u{2026}"
    }

    public static func reverted(bad: ReleaseVersion, back: ReleaseVersion) -> String {
        "Claude Switcher \(bad) did not start properly twice; it went back to \(back). See Diagnostics\u{2026}"
    }
}

/// An alert as the app shows it: what it says and which buttons it has.
public struct SwitcherAlert: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case updateAndRelaunch
        case openDownloadPage(URL)
        case dismiss
    }

    public struct Button: Equatable, Sendable {
        public let title: String
        public let action: Action
    }

    public let title: String
    public let message: String
    /// The first one is the default.
    public let buttons: [Button]

    public var offersDownloadPage: Bool {
        buttons.contains { if case .openDownloadPage = $0.action { return true } else { return false } }
    }

    public var offersUpdate: Bool { buttons.contains { $0.action == .updateAndRelaunch } }
}

/// What a check the user asked for ends in. Automatic paths never alert.
///
/// A version is only ever called "available", and its page only ever offered, once prepare has
/// verified the release against this copy's own team and identifier: nothing in GitHub's answer
/// alone can tell a genuine release from someone else's.
public enum SwitcherUpdateAlerts {

    private static let ok = SwitcherAlert.Button(title: "OK", action: .dismiss)

    /// `keepsVerifiedCopy`: this copy kept the verified release for "Update & Relaunch" — only the
    /// one holding the lock does; any other would only be refused. `hardBlocker`: the work in flight
    /// that a relaunch waits for even when asked, if any.
    public static func manualCheck(action: Decision.Action, prepared: Result<PreparedUpdate, Refusal>?,
                                   running: ReleaseVersion?, installability: Installability,
                                   keepsVerifiedCopy: Bool, hardBlocker: SwitcherIdle.Blocker? = nil) -> SwitcherAlert {
        let current = running?.description ?? "this version"
        switch action {
        case .upToDate(let running, _):
            return SwitcherAlert(title: "Claude Switcher is up to date",
                                 message: "\(running) is the newest release.", buttons: [ok])
        case .runningIsNewer(let running, let latest):
            return SwitcherAlert(title: "Claude Switcher is up to date",
                                 message: "\(running) is newer than the latest release, \(latest).", buttons: [ok])
        case .cannotVerify(let tag, let reason):
            return SwitcherAlert(
                title: "A newer Claude Switcher may exist",
                message: "A newer tag (\(tag)) exists on GitHub. This copy of Claude Switcher cannot verify it: \(reason).",
                buttons: [ok])
        case .checkFailed(let reason), .nothing(let reason):
            return checkFailed(reason)
        case .prepare(let candidate):
            switch prepared {
            case .success(let update)?:
                return available(update, running: current, installability: installability,
                                 keepsVerifiedCopy: keepsVerifiedCopy, hardBlocker: hardBlocker)
            case .failure(let refusal)? where refusal.kind == .permanent:
                return SwitcherAlert(
                    title: "Claude Switcher \(candidate.version) could not be verified",
                    message: "\(sentence(refusal.reason)). Nothing was changed; \(current) is unchanged. "
                        + "It will not be tried again automatically.",
                    buttons: [ok])
            case .failure(let refusal)?:
                return checkFailed(refusal.reason)
            case nil:
                return checkFailed("Claude Switcher \(candidate.version) was not checked")
            }
        }
    }

    private static func available(_ update: PreparedUpdate, running: String, installability: Installability,
                                  keepsVerifiedCopy: Bool, hardBlocker: SwitcherIdle.Blocker?) -> SwitcherAlert {
        let title = "Claude Switcher \(update.version) is available"
        switch installability {
        case .installable where !keepsVerifiedCopy:
            return SwitcherAlert(
                title: title,
                message: "You have \(running). Another Claude Switcher is running, and it is the one that updates itself "
                    + "to \(update.version); this copy does not replace itself while that one runs.",
                buttons: [ok])
        case .installable:
            var message = "You have \(running). Updating relaunches Claude Switcher \u{2014} a second or two without "
                + "the menu bar icon. Claude keeps running: nothing in Claude is quit, started or changed. "
                + "The current version is kept in Claude Switcher\u{2019}s own folder."
            if let hardBlocker {
                message += " Right now \(hardBlocker.description); Claude Switcher relaunches as soon as that is done."
            }
            return SwitcherAlert(title: title, message: message, buttons: [
                SwitcherAlert.Button(title: "Update & Relaunch", action: .updateAndRelaunch),
                SwitcherAlert.Button(title: "Later", action: .dismiss),
            ])
        case .checksOnly(let reason):
            return SwitcherAlert(
                title: title,
                message: "You have \(running). This copy never replaces itself: \(reason.message). The release was "
                    + "verified as signed by the same developer; download it and install it by hand.",
                buttons: [
                    SwitcherAlert.Button(title: "Open Download Page", action: .openDownloadPage(update.candidate.releasePageURL)),
                    ok,
                ])
        }
    }

    private static func checkFailed(_ reason: String) -> SwitcherAlert {
        SwitcherAlert(title: "Could not check for Claude Switcher updates", message: sentence(reason), buttons: [ok])
    }

    public static func commitRefused(_ reason: String, running: ReleaseVersion) -> SwitcherAlert {
        SwitcherAlert(title: "Claude Switcher did not update",
                      message: "\(sentence(reason)). \(running) is still in place and running.", buttons: [ok])
    }

    public static func relaunchFailed(_ version: ReleaseVersion, reason: String) -> SwitcherAlert {
        SwitcherAlert(title: "Claude Switcher \(version) is installed",
                      message: "It could not be relaunched: \(reason). It starts the next time Claude Switcher is launched.",
                      buttons: [ok])
    }

    /// A reason as the start of a sentence.
    private static func sentence(_ reason: String) -> String {
        guard let first = reason.first else { return reason }
        return first.uppercased() + reason.dropFirst()
    }
}
