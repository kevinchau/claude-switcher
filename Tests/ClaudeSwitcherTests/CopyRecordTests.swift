import XCTest
@testable import ClaudeSwitcherCore

/// The record a copy is filed under. Built field by field; nothing account-bound crosses over.
final class CopyRecordTests: XCTestCase {

    private let x = "c1c1c1c1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let sourceID = "local_11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let newID = UUID(uuidString: "ABCDEF01-2345-4678-89AB-CDEF01234567")!
    private let now = Date(timeIntervalSince1970: 1_759_660_000.123_9)

    private func source(title: String? = "Fix the build", model: String? = "claude-opus-5-5[1m]",
                        effort: String? = "high", cwd: String = "/Users/me/app") -> SessionRecord {
        SessionRecord(id: sourceID, cliSessionId: x, title: title, cwd: cwd, originCwd: cwd,
                      model: model, effort: effort, chromePermissionMode: "skip_all_permission_checks")
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The keys, in order, out of the raw bytes.
    private func keys(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        let regex = try! NSRegularExpression(pattern: "[{,]\"([A-Za-z]+)\":")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }
    }

    func testTheRecordHasExactlyTheAllowedKeysInOrder() throws {
        let data = CopyRecord.bytes(forCopyOf: source(), newID: newID, now: now)
        XCTAssertEqual(keys(data), CopyRecord.keys)
        XCTAssertEqual(Set(try object(data).keys), Set(CopyRecord.keys))
    }

    func testTheNewIdsAreTheLowercaseNewUUIDAndNothingElse() throws {
        let fields = try object(CopyRecord.bytes(forCopyOf: source(), newID: newID, now: now))
        let y = "abcdef01-2345-4678-89ab-cdef01234567"
        XCTAssertEqual(fields["sessionId"] as? String, "local_" + y)
        XCTAssertEqual(fields["cliSessionId"] as? String, y)

        // A fresh UUID from Foundation (uppercase) still comes out as a lowercase v4.
        let fresh = try object(CopyRecord.bytes(forCopyOf: source(), newID: UUID(), now: now))
        let id = try XCTUnwrap(fresh["cliSessionId"] as? String)
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression))
        XCTAssertEqual(fresh["sessionId"] as? String, "local_" + id)
    }

    /// All three timestamps are the injected clock, in whole milliseconds, as JSON integers —
    /// never rounded up into the future.
    func testTimestampsAreOneIntegerFromTheInjectedClock() throws {
        let data = CopyRecord.bytes(forCopyOf: source(), newID: newID, now: now)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["createdAt", "lastActivityAt", "indexedAt"] {
            XCTAssertTrue(text.contains("\"\(key)\":1759660000123,") || text.contains("\"\(key)\":1759660000123}"), key)
            let value = try XCTUnwrap(try object(data)[key] as? NSNumber)
            XCTAssertEqual(value.int64Value, 1_759_660_000_123)
            XCTAssertFalse(CFNumberIsFloatType(value), key)
        }
    }

    func testTheCopyStartsUnarchivedInDefaultModeWithNoGrantsInTheSameFolder() throws {
        let fields = try object(CopyRecord.bytes(forCopyOf: source(cwd: "/Users/me/app"), newID: newID, now: now))
        XCTAssertEqual(fields["isArchived"] as? Bool, false)
        XCTAssertEqual(fields["permissionMode"] as? String, "default")
        XCTAssertEqual(fields["cwd"] as? String, "/Users/me/app")
        XCTAssertEqual(fields["originCwd"] as? String, "/Users/me/app")
        XCTAssertEqual((fields["sessionPermissionUpdates"] as? [Any])?.count, 0)
        XCTAssertEqual((fields["alwaysAllowedReasons"] as? [Any])?.count, 0)
        XCTAssertEqual(fields["model"] as? String, "claude-opus-5-5[1m]")
        XCTAssertEqual(fields["effort"] as? String, "high")

        // A different origin would become the base repository for branch deletion in the
        // other account: the copy's origin is always its own working folder.
        let moved = SessionRecord(id: sourceID, cliSessionId: x, title: nil, cwd: "/Users/me/app", originCwd: "/Users/me/repo")
        let movedFields = try object(CopyRecord.bytes(forCopyOf: moved, newID: newID, now: now))
        XCTAssertEqual(movedFields["originCwd"] as? String, "/Users/me/app")
    }

    /// A source record carrying every account-bound field Claude knows: none of their values,
    /// nor the original's ids, reach the copy's bytes.
    func testNothingAccountBoundLeaksFromASourceRecordThatHasEverything() throws {
        let bound = [
            "titleSource", "chromePermissionMode", "adoptedFromOtherSurface", "surfaceNoticeUuid", "importedFrom",
            "bridgeSessionId", "bridgeSessionIds", "worktreePath", "worktreeName", "branch", "sourceBranch",
            "worktreeLazy", "keptWorktreeLeftover", "keptDirtyWorktree", "scratchFilesLeftIn", "sshConfig", "wslConfig",
            "priorCliSessionIds", "unarchivedCliSessionId", "preClearCliSessionId", "rewindEdges", "spawnSeed",
            "remoteMcpServersConfig", "enabledMcpTools", "emailAddress", "envScopeId", "spaceId", "lastFocusedAt",
            "interruptedByQuitAt", "scheduledTaskId", "spawnedFrom", "dispatchParentId", "chromeTabGroupId",
            "stagedTranscriptPath", "prs", "forkedFromSessionId", "sessionPermissionUpdatesLeak",
        ]
        var fields: [String: Any] = ["sessionId": sourceID, "cliSessionId": x, "cwd": "/Users/me/app",
                                     "originCwd": "/Users/me/app", "title": "Plan", "model": "m", "effort": "e",
                                     "isArchived": false, "permissionMode": "bypassPermissions",
                                     "sessionPermissionUpdates": [["rule": "LEAK-grant"]],
                                     "alwaysAllowedReasons": ["LEAK-reason"]]
        for key in bound { fields[key] = "LEAK-\(key)" }
        let data = try JSONSerialization.data(withJSONObject: fields)
        let record = try XCTUnwrap(SessionStore.record(from: data, fileStem: sourceID))

        let copy = CopyRecord.bytes(forCopyOf: record, newID: newID, now: now)
        let text = String(decoding: copy, as: UTF8.self)
        XCTAssertFalse(text.contains("LEAK"), text)
        XCTAssertFalse(text.contains("bypass"), text)
        XCTAssertFalse(text.lowercased().contains(x), text)
        XCTAssertFalse(text.contains("11111111-aaaa"), text)
        XCTAssertTrue(CopyRecord.isFree(copy, ofSourceCliSessionId: x, sourceRecordID: sourceID))
        for key in ["titleSource", "chromePermissionMode", "adoptedFromOtherSurface"] {
            XCTAssertFalse(text.contains("\"\(key)\""), key)
        }
    }

    func testOptionalFieldsAreLeftOutRatherThanEmpty() throws {
        for title in [nil, "", "   ", "\n\t"] as [String?] {
            let fields = try object(CopyRecord.bytes(forCopyOf: source(title: title, model: nil, effort: ""), newID: newID, now: now))
            XCTAssertNil(fields["title"], String(describing: title))
            XCTAssertNil(fields["model"])
            XCTAssertNil(fields["effort"])
            XCTAssertFalse(fields.values.contains { $0 is NSNull })
        }
    }

    // MARK: - Title

    func testTheTitleIsNumberedAsClaudesOwnForkNumbersIt() {
        XCTAssertEqual(CopyRecord.title(forCopyOf: "Plan"), "Plan (copy)")
        XCTAssertEqual(CopyRecord.title(forCopyOf: "Plan (copy)"), "Plan (copy 2)")
        XCTAssertEqual(CopyRecord.title(forCopyOf: "Plan (copy 2)"), "Plan (copy 3)")
        XCTAssertEqual(CopyRecord.title(forCopyOf: "Plan (copy 9) (copy)"), "Plan (copy 9) (copy 2)")
        XCTAssertEqual(CopyRecord.title(forCopyOf: "Plan (copy 41)"), "Plan (copy 42)")
        XCTAssertEqual(CopyRecord.title(forCopyOf: " (copy)"), " (copy 2)")
        // Not the pattern: a copy suffix is added, nothing renumbered.
        XCTAssertEqual(CopyRecord.title(forCopyOf: "Plan (copyx)"), "Plan (copyx) (copy)")
        XCTAssertEqual(CopyRecord.title(forCopyOf: "Plan (copy two)"), "Plan (copy two) (copy)")
        XCTAssertEqual(CopyRecord.title(forCopyOf: "Plan(copy)"), "Plan(copy) (copy)")
        // JavaScript's `.` stops at a line break.
        XCTAssertEqual(CopyRecord.title(forCopyOf: "Line\nbreak (copy)"), "Line\nbreak (copy) (copy)")
        XCTAssertNil(CopyRecord.title(forCopyOf: nil))
        XCTAssertNil(CopyRecord.title(forCopyOf: "  "))
    }

    /// Claude's 200-character limit, counted as JavaScript counts, with the suffix kept and no
    /// character split.
    func testTheTitleIsCappedAt200CharactersKeepingTheSuffix() {
        let long = CopyRecord.title(forCopyOf: String(repeating: "t", count: 250))!
        XCTAssertEqual(long.utf16.count, 200)
        XCTAssertTrue(long.hasSuffix("t (copy)"))

        let numbered = CopyRecord.title(forCopyOf: String(repeating: "t", count: 196) + " (copy 7)")!
        XCTAssertEqual(numbered.utf16.count, 200)
        XCTAssertTrue(numbered.hasSuffix(" (copy 8)"))

        // An emoji (two UTF-16 units) straddling the limit is dropped whole.
        let emoji = CopyRecord.title(forCopyOf: String(repeating: "t", count: 192) + "\u{1F600}\u{1F600}")!
        XCTAssertLessThanOrEqual(emoji.utf16.count, 200)
        XCTAssertEqual(emoji, String(repeating: "t", count: 192) + " (copy)")
        XCTAssertEqual(CopyRecord.title(forCopyOf: String(repeating: "t", count: 193)), String(repeating: "t", count: 193) + " (copy)")
    }

    // MARK: - Serialization

    func testTheBytesAreDeterministicAndRoundTripAnyFolderName() throws {
        let cwd = "/Users/me/\"quoted\" \\back\\ tab\there\u{1}ctl caf\u{e9} \u{1F600} a/b \u{2028}"
        let one = CopyRecord.bytes(forCopyOf: source(title: "T \"x\"", cwd: cwd), newID: newID, now: now)
        let two = CopyRecord.bytes(forCopyOf: source(title: "T \"x\"", cwd: cwd), newID: newID, now: now)
        XCTAssertEqual(one, two)
        let fields = try object(one)
        XCTAssertEqual(fields["cwd"] as? String, cwd)
        XCTAssertEqual(fields["title"] as? String, "T \"x\" (copy)")
        XCTAssertTrue(String(decoding: one, as: UTF8.self).contains("\\u0001"))
        XCTAssertTrue(String(decoding: one, as: UTF8.self).contains("a/b"), "a slash is not escaped, as in JSON.stringify")
    }

    // MARK: - The check before staging

    func testBytesNamingTheOriginalAreCaught() {
        let clean = Data("{\"cwd\":\"/Users/me/app\"}".utf8)
        XCTAssertTrue(CopyRecord.isFree(clean, ofSourceCliSessionId: x, sourceRecordID: sourceID))
        XCTAssertFalse(CopyRecord.isFree(Data("{\"a\":\"\(x)\"}".utf8), ofSourceCliSessionId: x, sourceRecordID: sourceID))
        XCTAssertFalse(CopyRecord.isFree(Data("{\"a\":\"\(x.uppercased())\"}".utf8), ofSourceCliSessionId: x, sourceRecordID: sourceID))
        XCTAssertFalse(CopyRecord.isFree(Data("{\"a\":\"\(sourceID)\"}".utf8), ofSourceCliSessionId: x, sourceRecordID: sourceID))
        XCTAssertFalse(CopyRecord.isFree(Data("11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa".utf8), ofSourceCliSessionId: x, sourceRecordID: sourceID))
        // A working folder that happens to contain the original's id is caught too.
        let named = CopyRecord.bytes(forCopyOf: source(cwd: "/Users/me/\(x)"), newID: newID, now: now)
        XCTAssertFalse(CopyRecord.isFree(named, ofSourceCliSessionId: x, sourceRecordID: sourceID))
    }
}
