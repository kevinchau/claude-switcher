import XCTest
@testable import ClaudeSwitcherCore

final class OnboardingTests: XCTestCase {

    func testAFreshInstallIsWelcomedOnce() {
        XCTAssertEqual(Onboarding.firstLaunch(alreadyShown: false, accountCount: 1, configLoaded: true),
                       .init(showsWelcome: true, remembers: true))
        XCTAssertEqual(Onboarding.firstLaunch(alreadyShown: true, accountCount: 1, configLoaded: true),
                       .init(showsWelcome: false, remembers: true))
    }

    /// Updating to the version that added the window must not put it in front of someone
    /// who has been switching accounts for weeks — now or after they remove an account.
    func testSomeoneWithAccountsAlreadySetUpIsNotWelcomed() {
        XCTAssertEqual(Onboarding.firstLaunch(alreadyShown: false, accountCount: 2, configLoaded: true),
                       .init(showsWelcome: false, remembers: true))
    }

    /// The defaults that stand in for an unreadable config look like a fresh install. Neither
    /// welcome that person as new, nor use up the one welcome a real new install gets.
    func testAConfigThatFailedToLoadDecidesNothing() {
        XCTAssertEqual(Onboarding.firstLaunch(alreadyShown: false, accountCount: 1, configLoaded: false),
                       .init(showsWelcome: false, remembers: false))
    }
}
