import XCTest
@testable import ClaudeSwitcherCore

/// The lock that lets only one switcher process act on its own initiative. Uses a lock file
/// under a temporary directory — never the real one in `~/.config/claude-switcher`.
final class AutomationLockTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-switcher-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `flock` belongs to the open file description, so a second open of the same file is
    /// refused exactly as a second process would be.
    func testOnlyOneHolderAtATime() throws {
        let url = directory.appendingPathComponent("nested/automation.lock")
        let first = try XCTUnwrap(AutomationLock.acquire(at: url), "creates the directory and takes the lock")
        XCTAssertNil(AutomationLock.acquire(at: url), "a second switcher must not get it")

        AutomationLock.release(first)
        let second = try XCTUnwrap(AutomationLock.acquire(at: url), "free again once the holder lets go")
        AutomationLock.release(second)
    }

    /// No lock, no automatic behaviour: failing to take it must read as "someone else has it".
    func testALockThatCannotBeTakenReadsAsNotOurs() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A directory where the lock file should be: `open(O_RDWR)` fails.
        let url = directory.appendingPathComponent("automation.lock")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertNil(AutomationLock.acquire(at: url))
    }

    func testTheRealLockLivesInTheSwitchersOwnConfigDirectory() {
        XCTAssertEqual(AutomationLock.defaultURL.deletingLastPathComponent(), Config.configURL.deletingLastPathComponent())
        XCTAssertEqual(AutomationLock.defaultURL.lastPathComponent, "automation.lock")
    }
}
