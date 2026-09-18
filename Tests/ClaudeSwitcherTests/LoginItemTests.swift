import XCTest
import ServiceManagement
@testable import ClaudeSwitcherCore

/// The mapping from `SMAppService` status to the "Launch at Login" menu item. Pure: nothing here
/// registers, unregisters or queries a real login item.
final class LoginItemTests: XCTestCase {

    /// The bug this guards: a bundle that has never been registered reports `.notFound`, and
    /// showing that as "unavailable" greyed the item out forever — it could never be enabled.
    func testANeverRegisteredBundleIsOfferedAsAnUncheckedCheckbox() {
        XCTAssertEqual(LoginItem.state(for: .notFound, runsFromBundle: true), .disabled)
    }

    func testTheOtherStatusesMapDirectly() {
        XCTAssertEqual(LoginItem.state(for: .notRegistered, runsFromBundle: true), .disabled)
        XCTAssertEqual(LoginItem.state(for: .enabled, runsFromBundle: true), .enabled)
        XCTAssertEqual(LoginItem.state(for: .requiresApproval, runsFromBundle: true), .requiresApproval)
    }

    /// `swift run` executes the bare binary: no bundle, nothing launchd could register.
    func testOutsideAnAppBundleTheItemIsUnavailableWhateverTheStatus() {
        for status: SMAppService.Status in [.notFound, .notRegistered, .enabled, .requiresApproval] {
            XCTAssertEqual(LoginItem.state(for: status, runsFromBundle: false), .unavailable)
        }
    }

    func testRunsFromBundleRequiresAnAppBundleWithAnIdentifier() {
        // The test bundle is an .xctest, not an .app.
        XCTAssertFalse(LoginItem.runsFromBundle(Bundle(for: LoginItemTests.self)))
        // A real application bundle on every Mac.
        if let finder = Bundle(path: "/System/Library/CoreServices/Finder.app") {
            XCTAssertTrue(LoginItem.runsFromBundle(finder))
        }
    }
}
