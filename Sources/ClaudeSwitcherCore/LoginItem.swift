import Foundation
import ServiceManagement

/// What the "Launch at Login" menu item shows.
public enum LoginItemState: Equatable, Sendable {
    /// Registered: the app opens at login. Checked.
    case enabled
    /// Not registered, but can be. Unchecked.
    case disabled
    /// Registered, but the user still has to allow it in System Settings. Mixed.
    case requiresApproval
    /// Cannot be registered from here at all (not running from an app bundle). Greyed out.
    case unavailable
}

public enum LoginItem {

    /// Maps `SMAppService.mainApp.status` onto the menu.
    ///
    /// `.notFound` is not an error here: it is what a bundle that has **never been registered**
    /// reports (verified on this project's supported macOS releases, from `/Applications` too).
    /// Rendering it as "unavailable" made the item permanently grey, so the toggle could never
    /// be turned on in the first place. It is registrable, so it is an unchecked checkbox.
    /// Only a process that is not inside an `.app` bundle — `swift run` — truly cannot register.
    public static func state(for status: SMAppService.Status, runsFromBundle: Bool) -> LoginItemState {
        guard runsFromBundle else { return .unavailable }
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Whether `bundle` is an application bundle, which login-item registration requires.
    public static func runsFromBundle(_ bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier != nil
    }
}
