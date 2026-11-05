import XCTest
@testable import ClaudeSwitcherCore

/// Copying a session together with the sessions started from it. Each member is an ordinary
/// copy; what is new is the order and the link each copy's record gets. All in a temporary home.
final class FamilyCopyTests: XCTestCase {

    private var f: CopyFixture!

    override func setUpWithError() throws { f = try CopyFixture(subagents: false) }
    override func tearDown() { f = nil }

    private func uuid(_ n: Int) -> String { String(format: "%08x-bbbb-4bbb-8bbb-bbbbbbbbbbbb", n) }
    private func cli(_ n: Int) -> String { String(format: "%08x-dddd-4ddd-8ddd-dddddddddddd", n) }

    /// A session in Personal started from `parent` (a record id), with a one-line transcript.
    @discardableResult
    private func child(_ n: Int, of parent: String, cwd: String? = nil, extra: [String: Any] = [:]) throws -> String {
        let cwd = cwd ?? f.cwd
        var fields: [String: Any] = [
            "sessionId": "local_\(uuid(n))", "cliSessionId": cli(n), "cwd": cwd, "originCwd": cwd,
            "title": "Child \(n)", "lastActivityAt": 1_700_000_000_000 + n,
            "spawnedFrom": ["sessionId": parent, "taskId": "task_\(n)", "title": "Child \(n)", "sideSession": true,
                            "wakeParent": true, "sharedFolder": true],
        ]
        for (key, value) in extra { fields[key] = value }
        try f.home.writeRecord(fields, in: f.storeA)
        try f.home.writeTranscript(cwd: cwd, cliSessionId: cli(n), lines: [#"{"type":"user","uuid":"m\#(n)"}"#])
        return "local_\(uuid(n))"
    }

    private func member(_ n: Int, parent: String, cwd: String? = nil) -> SessionCopy.FamilyMember {
        SessionCopy.FamilyMember(sessionID: "local_\(uuid(n))", cliSessionId: cli(n), cwd: cwd ?? f.cwd, parentSessionID: parent)
    }

    private var root: SessionCopy.FamilyMember {
        SessionCopy.FamilyMember(sessionID: f.sourceID, cliSessionId: f.x, cwd: f.cwd, parentSessionID: nil)
    }

    /// Runs the family copy with a fresh id for each member.
    private func copyFamily(_ members: [SessionCopy.FamilyMember]) -> [SessionCopy.FamilyResult] {
        var environment = f.environment()
        let ids = IDSequence()
        environment.newID = { ids.next() }
        return SessionCopy.copyFamily(members, from: f.personal, to: f.work, allProfiles: f.profiles, environment: environment)
    }

    private func newID(_ result: SessionCopy.FamilyResult) -> String? {
        if case .copied(let success) = result.outcome { return success.newSessionID }
        return nil
    }

    /// The `spawnedFrom` of the copy filed as `id` in Work's store, as JSON.
    private func link(of id: String) throws -> [String: Any]? {
        let data = try Data(contentsOf: f.storeB.url.appendingPathComponent(id + ".json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])["spawnedFrom"] as? [String: Any]
    }

    func testEachSessionIsCopiedUnderTheCopyOfTheOneItWasStartedFrom() throws {
        let a = try child(1, of: f.sourceID)
        try child(2, of: a)
        try child(3, of: f.sourceID)
        let results = copyFamily([root, member(1, parent: f.sourceID), member(2, parent: a), member(3, parent: f.sourceID)])

        let ids = results.map(newID)
        XCTAssertEqual(ids.compactMap { $0 }.count, 4, "\(results)")
        let copiedRoot = try XCTUnwrap(ids[0]), copiedA = try XCTUnwrap(ids[1])
        XCTAssertNil(try link(of: copiedRoot), "the first session is copied as it is today")
        XCTAssertEqual(try link(of: try XCTUnwrap(ids[1]))?["sessionId"] as? String, copiedRoot)
        XCTAssertEqual(try link(of: try XCTUnwrap(ids[2]))?["sessionId"] as? String, copiedA)
        XCTAssertEqual(try link(of: try XCTUnwrap(ids[3]))?["sessionId"] as? String, copiedRoot)

        // Desktop's shape for a session started from another that is not a side session: no flag
        // of the original's link comes across, and nothing names an original session.
        let copiedLink = try XCTUnwrap(try link(of: try XCTUnwrap(ids[1])))
        XCTAssertEqual(Set(copiedLink.keys), ["sessionId", "taskId", "title"])
        XCTAssertEqual(copiedLink["title"] as? String, "Child 1 (copy)")
        for id in ids.compactMap({ $0 }) {
            let text = String(decoding: try Data(contentsOf: f.storeB.url.appendingPathComponent(id + ".json")), as: UTF8.self)
            for original in [Self.sourceUUIDPrefix, "bbbb-4bbb", "dddd-4ddd"] { XCTAssertFalse(text.contains(original), text) }
        }
    }

    private static let sourceUUIDPrefix = "11111111-aaaa"

    /// A member that is not copied does not take its own sessions out: they are filed under the
    /// copy of the nearest session above it that was copied.
    func testASessionLeftOutPassesItsSessionsUpToTheNearestCopy() throws {
        let a = try child(1, of: f.sourceID)
        let b = try child(2, of: a, extra: ["worktreePath": "/w"])
        try child(3, of: b)
        let results = copyFamily([root, member(1, parent: f.sourceID), member(2, parent: a), member(3, parent: b)])
        XCTAssertEqual(results[2].outcome, .refused(.inWorktree))
        let copiedA = try XCTUnwrap(newID(results[1]))
        XCTAssertEqual(try link(of: try XCTUnwrap(newID(results[3])))?["sessionId"] as? String, copiedA)
    }

    /// Desktop re-resolves the folder of a linked session that works elsewhere than its parent:
    /// such a member is copied as it would be on its own, at the top level.
    func testASessionInAnotherFolderIsCopiedWithoutALink() throws {
        let other = try f.home.makeDirectory("work/other")
        try child(1, of: f.sourceID, cwd: other)
        let results = copyFamily([root, member(1, parent: f.sourceID, cwd: other)])
        XCTAssertNil(try link(of: try XCTUnwrap(newID(results[1]))))
    }

    /// If the first session is not copied, nothing else is attempted and nothing is created.
    func testNothingIsCopiedWhenTheFirstSessionIsNot() throws {
        try child(1, of: f.sourceID)
        try f.home.writeRecord(["sessionId": f.sourceID, "cliSessionId": f.x, "cwd": f.cwd, "originCwd": f.cwd,
                                "worktreeName": "w"], in: f.storeA)
        let before = f.snapshot()
        let results = copyFamily([root, member(1, parent: f.sourceID)])
        XCTAssertEqual(results.map(\.outcome), [.refused(.inWorktree), .refused(.familyParentNotCopied)])
        XCTAssertEqual(f.snapshot().ignoringDirectoryTimes, before.ignoringDirectoryTimes)
    }

    /// A link may only name a copy that is in the target's store; otherwise the copy is refused
    /// before anything is put in place.
    func testALinkToARecordThatIsNotInTheTargetStoreIsRefused() throws {
        for parent in ["local_\(uuid(77))", f.sourceID, "not-a-record", "local_\(uuid(77))/../x"] {
            let before = f.snapshot()
            let request = SessionCopy.Request(source: f.personal, target: f.work, sessionID: f.sourceID,
                                              cliSessionId: f.x, cwd: f.cwd, parentSessionID: parent)
            XCTAssertEqual(f.copy(request), .refused(.familyParentNotCopied), parent)
            XCTAssertEqual(f.snapshot().ignoringDirectoryTimes, before.ignoringDirectoryTimes, parent)
            XCTAssertEqual(f.journalFiles, [], parent)
        }
    }
}

/// Distinct, lowercase-safe ids, one per call.
private final class IDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> UUID {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return UUID(uuidString: String(format: "%08X-EEEE-4EEE-8EEE-EEEEEEEEEEEE", n))!
    }
}
