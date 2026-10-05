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

    /// Why the lock was not taken is told apart: another holder, or a file that cannot be
    /// locked at all — so a copy is not refused with "another Claude Switcher is running" when
    /// none is.
    func testTakingTheLockSaysWhyItFailed() throws {
        let url = directory.appendingPathComponent("automation.lock")
        guard case .acquired(let held) = AutomationLock.take(at: url) else { return XCTFail("not taken") }
        XCTAssertEqual(AutomationLock.take(at: url), .heldElsewhere)
        AutomationLock.release(held)

        let blocked = directory.appendingPathComponent("blocked.lock")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertEqual(AutomationLock.take(at: blocked), .unavailable(errno: EISDIR))
    }

    /// What a copy is refused with in each case.
    func testACopyWithoutTheLockSaysWhichCase() throws {
        var environment = SessionCopy.Environment(home: directory.path)
        let request = SessionCopy.Request(source: Profile(id: "a", label: "A"), target: Profile(id: "b", label: "B", userDataDir: "/x"),
                                          sessionID: "local_x", cliSessionId: "x", cwd: "/x")
        XCTAssertEqual(SessionCopy.copy(request, allProfiles: [], environment: environment), .refused(.notAutomationLockHolder))
        environment.lockFileUnavailable = true
        XCTAssertEqual(SessionCopy.copy(request, allProfiles: [], environment: environment), .refused(.lockFileUnavailable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing was looked at or made")
    }

    func testTheRealLockLivesInTheSwitchersOwnConfigDirectory() {
        XCTAssertEqual(AutomationLock.defaultURL.deletingLastPathComponent(), Config.configURL.deletingLastPathComponent())
        XCTAssertEqual(AutomationLock.defaultURL.lastPathComponent, "automation.lock")
    }
}
