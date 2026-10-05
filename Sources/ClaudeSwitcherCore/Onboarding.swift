import Foundation

/// When the welcome window opens without being asked for.
public enum Onboarding {

    public struct FirstLaunch: Equatable, Sendable {
        /// Open the welcome window now.
        public let showsWelcome: Bool
        /// Record that this decision was made, so it is not made again.
        public let remembers: Bool
    }

    /// Once, on the first launch — and not at all for someone whose accounts were set up
    /// before the window existed: they have plainly found the menu already.
    ///
    /// A config that failed to load decides nothing: what is in memory then is the defaults,
    /// which look exactly like a fresh install. Nothing is shown and nothing is remembered,
    /// so the question is asked again once the file can be read.
    public static func firstLaunch(alreadyShown: Bool, accountCount: Int, configLoaded: Bool) -> FirstLaunch {
        guard configLoaded else { return FirstLaunch(showsWelcome: false, remembers: false) }
        return FirstLaunch(showsWelcome: !alreadyShown && accountCount <= 1, remembers: true)
    }
}
