import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// Copying a session into another account, end to end, under a temporary home. Each test
/// compares a full-tree snapshot (path, type, mode, owner, inode, links, size, time, SHA-256,
/// link target) from before and after.
final class SessionCopyTests: XCTestCase {

    private var f: CopyFixture!

    override func setUpWithError() throws { f = try CopyFixture() }
    override func tearDown() { f = nil }

    private let leftInPlace = CopyRecovery.Note.leftInPlace("Work").message
    private let cleanedUp = CopyRecovery.Note.cleanedUp("Work").message
    private let finished = CopyRecovery.Note.finished("Work").message
    private let pendingDetail = CopyRun.pendingDetail(target: "Work")

    /// `path` with the home directory's last component spelled in capitals: the same folder on
    /// a case-insensitive volume. `nil` on a case-sensitive one.
    private func caseVariant(of path: String, in f: CopyFixture) -> String? {
        let home = f.home.home
        let shouted = (home as NSString).deletingLastPathComponent + "/" + (home as NSString).lastPathComponent.uppercased()
        guard path.hasPrefix(home), FileManager.default.fileExists(atPath: shouted) else { return nil }
        return shouted + path.dropFirst(home.count)
    }

    /// The copy is refused, and nothing anywhere under the home is different afterwards.
    private func assertRefused(_ expected: SessionCopy.Refusal, _ fixture: CopyFixture? = nil, request: SessionCopy.Request? = nil,
                               profiles: [Profile]? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let f = fixture ?? self.f!
        let before = f.snapshot()
        XCTAssertEqual(f.copy(request, profiles: profiles), .refused(expected), file: file, line: line)
        let after = f.snapshot()
        XCTAssertEqual(after.ignoringDirectoryTimes, before.ignoringDirectoryTimes, after.difference(from: before), file: file, line: line)
        XCTAssertEqual(f.journalFiles, [], file: file, line: line)
    }

    // MARK: - 1, 2. Success, and the source untouched

    func testACopyAddsOnlyItsOwnEntriesAndLeavesEverythingElseIdentical() throws {
        let before = f.snapshot()
        let outcome = f.copy()
        XCTAssertEqual(outcome, .copied(SessionCopy.Success(
            newSessionID: "local_\(f.y)", title: "Fix the build (copy)", copiedSubagentTranscripts: 1,
            skippedSubagentTranscripts: 0, transcriptBytes: f.expectedCopy.count)))
        try f.assertIsASuccessfulCopy(before: before)
        // No staging name is left behind.
        XCTAssertTrue(f.snapshot().paths.allSatisfy { !$0.contains(".claude-switcher-") })
        XCTAssertEqual(f.steps.filter { if case .snapshotRead = $0 { return true }; return false }.count, 1)
    }

    /// Two profiles whose folders are one — spelled in another case, or through a link — are
    /// one profile, and nothing is written.
    func testTheSameFolderUnderAnotherNameIsRefusedWithNoChange() throws {
        let link = f.home.root.appendingPathComponent("Library/Application Support/Claude-alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.home.userDataDir(nil))
        let alias = Profile(id: "alias", label: "Alias", userDataDir: link.path)
        assertRefused(.sameProfile, request: f.request(to: alias), profiles: f.profiles + [alias])

        let shouted = f.home.userDataDir(nil).path.replacingOccurrences(of: "Application Support/Claude", with: "application support/CLAUDE")
        guard FileManager.default.fileExists(atPath: shouted) else { throw XCTSkip("this volume is case-sensitive") }
        let other = Profile(id: "shouted", label: "Shouted", userDataDir: shouted)
        assertRefused(.sameProfile, request: f.request(to: other), profiles: f.profiles + [other])
    }

    // MARK: - 3. The transcript's bytes

    /// The source up to its last line feed — the torn line Claude is still writing is left
    /// out — plus the clearing line; bytes the source gains after the read are not in the copy.
    func testTheCopyIsTheSourceUpToItsLastLineFeedPlusTheClears() throws {
        let f = self.f!
        f.hook = { [unowned f] step in
            if step == .scanned {
                let handle = try FileHandle(forWritingTo: f.transcriptURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("ing\":1}\n{\"type\":\"user\",\"late\":true}\n".utf8))
                try handle.close()
            }
        }
        guard case .copied = f.copy() else { return XCTFail("not copied") }
        XCTAssertEqual(try Data(contentsOf: f.copyURL), f.expectedCopy)
        XCTAssertFalse(String(decoding: try Data(contentsOf: f.copyURL), as: UTF8.self).contains("late"))
    }

    func testASourceWithNoCompleteLineIsRefused() throws {
        let f = try CopyFixture(lines: [], tail: #"{"type":"user","no line feed":true}"#, subagents: false)
        try Data(#"{"type":"user","no line feed":true}"#.utf8).write(to: f.transcriptURL)
        assertRefused(.transcriptEmpty, f)
    }

    // MARK: - 4. A consistent snapshot

    func testATranscriptChangedDuringTheReadIsReadAgain() throws {
        let rewritten = [#"{"type":"user","rewritten":1}"#, #"{"type":"assistant","rewritten":2}"#]
        let changes: [(String, (URL) throws -> Void)] = [
            ("truncated", { url in
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(CopyFixture.defaultLines[0].utf8.count + 1))
                try handle.close()
            }),
            ("rewritten in place, same size", { url in
                var data = try Data(contentsOf: url)
                data[2] = UInt8(ascii: "T")
                let handle = try FileHandle(forWritingTo: url)
                try handle.write(contentsOf: data)
                try handle.close()
            }),
            ("touched", { url in
                var times = [timeval(tv_sec: 1_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000, tv_usec: 0)]
                XCTAssertEqual(utimes(url.path, &times), 0)
            }),
            ("replaced", { url in
                let fresh = url.deletingLastPathComponent().appendingPathComponent("fresh")
                try Data((rewritten.joined(separator: "\n") + "\n").utf8).write(to: fresh)
                XCTAssertEqual(rename(fresh.path, url.path), 0)
            }),
        ]
        for (label, change) in changes {
            let f = try CopyFixture(subagents: false)
            f.hook = { [unowned f] step in if step == .snapshotRead(attempt: 1) { try change(f.transcriptURL) } }
            guard case .copied = f.copy() else { XCTFail(label); continue }
            XCTAssertEqual(f.pauses, [0.25], label)
            XCTAssertTrue(f.steps.contains(.snapshotRead(attempt: 2)), label)
            // What was copied is what the second read saw.
            let source = try Data(contentsOf: f.transcriptURL)
            let copy = try Data(contentsOf: f.copyURL)
            let prefix = source.prefix(through: source.lastIndex(of: 0x0A)!)
            XCTAssertEqual(copy.prefix(prefix.count), prefix, label)
        }
    }

    /// Five seconds of 250 ms retries, then a refusal — and nothing is created.
    func testATranscriptThatKeepsChangingIsRefusedWithNothingCreated() throws {
        let f = self.f!
        f.hook = { [unowned f] step in
            if case .snapshotRead = step {
                let handle = try FileHandle(forWritingTo: f.transcriptURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("x".utf8))
                try handle.close()
            }
        }
        let before = f.snapshot().excluding(f.rel(f.transcriptURL))
        XCTAssertEqual(f.copy(), .refused(.stillBeingWritten))
        XCTAssertEqual(f.pauses.count, 20)
        XCTAssertEqual(f.pauses.reduce(0, +), 5.0, accuracy: 0.000_1)
        XCTAssertEqual(f.steps.last, .snapshotRead(attempt: 21))
        let after = f.snapshot().excluding(f.rel(f.transcriptURL))
        XCTAssertEqual(after.ignoringDirectoryTimes, before.ignoringDirectoryTimes, after.difference(from: before))
    }

    /// A read is trusted only when every byte up to the size was read and nothing about the
    /// file moved: on fabricated `fstat` results, since a short read with every time unchanged
    /// cannot be made on a real file.
    func testAReadIsTrustedOnlyWhenNothingMovedAndNothingWasShort() {
        func status(size: off_t = 100, mtime: Int = 5, ctime: Int = 6, inode: ino_t = 42, mode: mode_t = S_IFREG | 0o600) -> FileStatus {
            var info = stat()
            info.st_mode = mode
            info.st_size = size
            info.st_ino = inode
            info.st_nlink = 1
            info.st_mtimespec = timespec(tv_sec: mtime, tv_nsec: 0)
            info.st_ctimespec = timespec(tv_sec: ctime, tv_nsec: 0)
            return FileStatus(info)
        }
        let settled = status()
        func trusted(_ closed: FileStatus = status(), atName: FileStatus? = status(), read: Int = 100) -> Bool {
            SessionCopy.readWasUndisturbed(opened: settled, closed: closed, atName: atName, bytesRead: read)
        }
        XCTAssertTrue(trusted())
        XCTAssertFalse(trusted(read: 99), "short read")
        XCTAssertFalse(trusted(status(size: 101)), "size")
        XCTAssertFalse(trusted(status(mtime: 7)), "modified")
        XCTAssertFalse(trusted(status(ctime: 7)), "changed")
        XCTAssertFalse(trusted(atName: status(inode: 43)), "the name is on another file")
        XCTAssertFalse(trusted(atName: nil), "the name is gone")
        XCTAssertFalse(trusted(atName: status(mode: S_IFLNK | 0o777)), "the name is a link")
    }

    // MARK: - 5. Remote Control pointers

    func testEachLivePointerGetsExactlyOneClearInFirstSeenOrderAndTheSourceIsUntouched() throws {
        let lines = [
            #"{"type":"bridge-session","sessionId":"s-b","bridgeSessionId":"remote-b","lastSequenceNum":1}"#,
            #"{"type":"bridge-session","sessionId":"s-a","bridgeSessionId":"remote-a","lastSequenceNum":1}"#,
            #"{"type":"bridge-session","sessionId":"s-c","bridgeSessionId":"remote-c","lastSequenceNum":1}"#,
            #"{"type":"bridge-session","sessionId":"s-c","bridgeSessionId":"","lastSequenceNum":0}"#,
            #"{"type":"bridge-session","sessionId":"s-b","bridgeSessionId":"remote-b2","lastSequenceNum":2}"#,
            #"{"type":"bridge-session","sessionId":"s-d\n","bridgeSessionId":"","lastSequenceNum":2}"#,
        ]
        let f = try CopyFixture(lines: lines, subagents: false)
        let source = try Data(contentsOf: f.transcriptURL)
        guard case .copied = f.copy() else { return XCTFail("not copied") }
        let clears = #"{"type":"bridge-session","sessionId":"s-b","bridgeSessionId":"","lastSequenceNum":0}"# + "\n"
            + #"{"type":"bridge-session","sessionId":"s-a","bridgeSessionId":"","lastSequenceNum":0}"# + "\n"
        XCTAssertEqual(try Data(contentsOf: f.copyURL), Data((lines.joined(separator: "\n") + "\n" + clears).utf8))
        XCTAssertEqual(try Data(contentsOf: f.transcriptURL), source)
    }

    func testNothingIsAppendedWhenEveryPointerIsAlreadyCleared() throws {
        let lines = [#"{"type":"user","n":1}"#, #"{"type":"bridge-session","sessionId":"s","bridgeSessionId":"","lastSequenceNum":0}"#]
        let f = try CopyFixture(lines: lines, subagents: false)
        guard case .copied = f.copy() else { return XCTFail("not copied") }
        XCTAssertEqual(try Data(contentsOf: f.copyURL), Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: - 6. State the transcript carries

    func testWorktreeAndMonitorStateInTheTranscriptRefusesUntilItIsCleared() throws {
        let bound = #"{"type":"worktree-state","sessionId":"s","worktreeSession":{"worktreePath":"/w"}}"#
        let unbound = #"{"type":"worktree-state","sessionId":"s","worktreeSession":null}"#
        let armed = #"{"type":"artifact-comment-monitor","v":1,"sessionId":"s","artifacts":{"a":{"state":"armed"}}}"#
        let stopped = #"{"type":"artifact-comment-monitor","v":1,"sessionId":"s","artifacts":{"a":{"state":"stopped"}}}"#
        let broken = #"{"type":"worktree-state","sessionId":"s","worktreeSession":{"#

        assertRefused(.inWorktree, try CopyFixture(lines: [bound], subagents: false))
        assertRefused(.watchingArtifactComments, try CopyFixture(lines: [armed], subagents: false))
        assertRefused(.unreadableTranscriptLine, try CopyFixture(lines: [broken, unbound], subagents: false))
        for allowed in [[bound, unbound], [armed, stopped]] {
            let f = try CopyFixture(lines: allowed, subagents: false)
            guard case .copied = f.copy() else { XCTFail("\(allowed)"); continue }
        }
    }

    // MARK: - 7. The record

    func testTheRecordHasOnlyTheAllowedKeysAndNothingOfTheOriginalsAccount() throws {
        guard case .copied = f.copy() else { return XCTFail("not copied") }
        let data = try Data(contentsOf: f.recordURL)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(CopyRecord.keys))
        XCTAssertEqual(fields["sessionId"] as? String, "local_\(f.y)")
        XCTAssertEqual(fields["cliSessionId"] as? String, f.y)
        XCTAssertEqual(fields["cwd"] as? String, f.cwd)
        XCTAssertEqual(fields["originCwd"] as? String, f.cwd)
        XCTAssertEqual(fields["permissionMode"] as? String, "default")
        XCTAssertEqual(fields["title"] as? String, "Fix the build (copy)")
        for key in ["createdAt", "lastActivityAt", "indexedAt"] {
            let value = try XCTUnwrap(fields[key] as? NSNumber, key)
            XCTAssertFalse(CFNumberIsFloatType(value), key)
            XCTAssertEqual(value.int64Value, f.nowMilliseconds, key)
        }
        let text = String(decoding: data, as: UTF8.self)
        for leak in ["LEAK", "bypassPermissions", "skip_all_permission_checks", f.x, CopyFixture.sourceUUID] {
            XCTAssertFalse(text.lowercased().contains(leak.lowercased()), leak)
        }
        XCTAssertEqual(f.recordURL.lastPathComponent, (fields["sessionId"] as? String ?? "") + ".json")
    }

    func testTheTitleIsNumberedAndLeftOutWhenTheOriginalHasNone() throws {
        let numbered = try CopyFixture(record: ["title": "Fix the build (copy)"], subagents: false)
        guard case .copied(let success) = numbered.copy() else { return XCTFail("not copied") }
        XCTAssertEqual(success.title, "Fix the build (copy 2)")

        let untitled = try CopyFixture(record: ["title": "   "], subagents: false)
        guard case .copied(let plain) = untitled.copy() else { return XCTFail("not copied") }
        XCTAssertNil(plain.title)
        XCTAssertFalse(String(decoding: try Data(contentsOf: untitled.recordURL), as: UTF8.self).contains("\"title\""))
    }

    /// The new record must not name the original anywhere — not even in a title that quotes its id.
    /// The staged record's bytes are checked whatever put the id there. A title or folder that
    /// contains it is refused before anything is staged
    /// (`testASessionWhoseTitleOrFolderNamesItsOwnIdIsRefusedBeforeAnythingIsStaged`); the
    /// model name, which that early check does not look at, reaches this backstop.
    func testARecordThatWouldNameTheOriginalIsNeverFiled() throws {
        let f = try CopyFixture(record: ["model": "claude-\(CopyFixture.x.uppercased())"])
        assertRefused(.recordCheckFailed, f)
        XCTAssertTrue(f.steps.contains(.subagentsStaged), "it was staged, then refused")
    }

    // MARK: - 8. Modes, links, inodes, times

    func testCreatedFilesArePrivateNewAndFreshWhateverTheSourceAndTheUmask() throws {
        let started = Date().addingTimeInterval(-1)
        let old = Date().addingTimeInterval(-60 * 86_400)
        for url in [f.transcriptURL, f.agentURL("a1")] {
            XCTAssertEqual(chmod(url.path, 0o644), 0)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let previous = umask(0o277)
        let outcome = f.copy()
        umask(previous)
        guard case .copied = outcome else { return XCTFail("not copied") }

        let snapshot = f.snapshot()
        let source = try XCTUnwrap(snapshot.entry(f.rel(f.transcriptURL)))
        for url in [f.copyURL, f.copiedAgentURL, f.recordURL] {
            let entry = try XCTUnwrap(snapshot.entry(f.rel(url)))
            XCTAssertEqual(entry.mode, 0o600, url.lastPathComponent)
            XCTAssertEqual(entry.linkCount, 1)
            XCTAssertEqual(entry.owner, getuid())
            XCTAssertNotEqual(entry.inode, source.inode)
            XCTAssertGreaterThanOrEqual(Double(entry.modified) / 1e9, started.timeIntervalSince1970, url.lastPathComponent)
        }
        for url in [f.projectFolder.appendingPathComponent(f.y), f.projectFolder.appendingPathComponent("\(f.y)/subagents")] {
            XCTAssertEqual(snapshot.entry(f.rel(url))?.mode, 0o700)
        }
    }

    // MARK: - 9. Subagent transcripts

    func testOnlyReferencedSubagentTranscriptsAreCopiedFromWhereDesktopLooks() throws {
        let ids = ["nested", "flat", "both", "pipe", "folder", "missing", "../../sentinel", "a/b", ".."]
        let lines = ids.map { #"{"type":"assistant","toolUseResult":{"agentId":"\#($0)"}}"# }
            + [#"{"type":"user","isCompactSummary":true,"toolUseResult":{"agentId":"summary"}}"#]
        let f = try CopyFixture(lines: lines, subagents: false)
        try f.write("{\"from\":\"nested\"}\n", to: f.agentURL("nested"))
        try f.write("{\"from\":\"flat\"}\n", to: f.projectFolder.appendingPathComponent("agent-flat.jsonl"))
        try f.write("{\"from\":\"both-nested\"}\n", to: f.agentURL("both"))
        try f.write("{\"from\":\"both-flat\"}\n", to: f.projectFolder.appendingPathComponent("agent-both.jsonl"))
        XCTAssertEqual(mkfifo(f.agentURL("pipe").path, 0o600), 0)
        try f.write("{\"from\":\"pipe-flat\"}\n", to: f.projectFolder.appendingPathComponent("agent-pipe.jsonl"))
        try FileManager.default.createDirectory(at: f.agentURL("folder"), withIntermediateDirectories: true)
        try f.write("{\"from\":\"folder-flat\"}\n", to: f.projectFolder.appendingPathComponent("agent-folder.jsonl"))
        try f.write("{\"from\":\"summary\"}\n", to: f.agentURL("summary"))
        try f.write("{}", to: f.subagentsFolder.appendingPathComponent("agent-nested.meta.json"))
        // What the rejected ids would reach if they were joined into a path.
        for sentinel in ["sentinel.jsonl", "\(f.x)/sentinel.jsonl", "agent-a/b.jsonl"] {
            try f.write("{\"sentinel\":1}\n", to: f.projectFolder.appendingPathComponent(sentinel))
        }
        try f.write("{\"sentinel\":1}\n", to: f.home.root.appendingPathComponent(".claude/sentinel.jsonl"))

        let before = f.snapshot()
        guard case .copied(let success) = f.copy() else { return XCTFail("not copied") }
        XCTAssertEqual(success.copiedSubagentTranscripts, 3)
        XCTAssertEqual(success.skippedSubagentTranscripts, 3)

        let copied = f.projectFolder.appendingPathComponent("\(f.y)/subagents")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: copied.path)),
                       ["agent-nested.jsonl", "agent-flat.jsonl", "agent-both.jsonl"])
        XCTAssertEqual(try String(contentsOf: copied.appendingPathComponent("agent-flat.jsonl"), encoding: .utf8), "{\"from\":\"flat\"}\n")
        XCTAssertEqual(try String(contentsOf: copied.appendingPathComponent("agent-both.jsonl"), encoding: .utf8), "{\"from\":\"both-nested\"}\n")
        let changes = f.snapshot().changes(since: before)
        XCTAssertEqual(changes.removed, [])
        XCTAssertEqual(changes.changed, [])
        XCTAssertTrue(changes.added.allSatisfy { $0.hasPrefix(f.rel(copied)) || $0 == f.rel(copied.deletingLastPathComponent())
                || $0 == f.rel(f.copyURL) || $0 == f.rel(f.recordURL) || $0 == f.rel(f.journalURL) }, "\(changes.added)")
    }

    /// The flat fallback is taken only when the nested path does not exist or goes through
    /// something that is not a folder.
    func testTheFlatFallbackIsTakenOnlyWhenTheNestedPathIsNotThere() throws {
        let f = try CopyFixture(lines: [#"{"type":"assistant","toolUseResult":{"agentId":"f1"}}"#], subagents: false)
        try f.write("not a folder", to: f.subagentsFolder)
        try f.write("{\"from\":\"flat\"}\n", to: f.projectFolder.appendingPathComponent("agent-f1.jsonl"))
        guard case .copied(let success) = f.copy() else { return XCTFail("not copied") }
        XCTAssertEqual(success.copiedSubagentTranscripts, 1)
        XCTAssertEqual(try String(contentsOf: f.projectFolder.appendingPathComponent("\(f.y)/subagents/agent-f1.jsonl"), encoding: .utf8),
                       "{\"from\":\"flat\"}\n")
    }

    /// A referenced subagent transcript replaced by another file between the scan and its
    /// copy is skipped, not copied: what is staged is the very file that was found.
    func testASubagentTranscriptReplacedAfterItWasFoundIsSkipped() throws {
        let f = self.f!
        f.hook = { [unowned f] step in
            guard step == .scanned else { return }
            let replacement = f.subagentsFolder.appendingPathComponent("replacement")
            try Data("{\"replaced\":1}\n".utf8).write(to: replacement)
            XCTAssertEqual(rename(replacement.path, f.agentURL("a1").path), 0)
        }
        guard case .copied(let success) = f.copy() else { return XCTFail("not copied") }
        XCTAssertEqual(success.copiedSubagentTranscripts, 0)
        XCTAssertEqual(success.skippedSubagentTranscripts, 1)
        XCTAssertFalse(f.exists(f.copiedAgentURL))
        XCTAssertFalse(f.exists(f.projectFolder.appendingPathComponent(f.y)), "no subagent folder without a subagent transcript")
        XCTAssertTrue(f.exists(f.copyURL))
    }

    func testWithoutReferencedSubagentsNoFolderIsMade() throws {
        let f = try CopyFixture(lines: [#"{"type":"user","n":1}"#])
        let before = f.snapshot()
        guard case .copied(let success) = f.copy() else { return XCTFail("not copied") }
        XCTAssertEqual(success.copiedSubagentTranscripts, 0)
        XCTAssertEqual(f.snapshot().changes(since: before).added, [f.rel(f.copyURL), f.rel(f.recordURL), f.rel(f.journalURL)])
    }

    // MARK: - 10. Preflight refusals

    func testEachReasonNotToCopyRefusesWithNoChange() throws {
        let cases: [(String, SessionCopy.Refusal, [String: Any])] = [
            ("no transcript id", .noTranscriptYet, ["cliSessionId": NSNull()]),
            ("archived", .archived, ["isArchived": true]),
            ("remote", .remote, ["sshConfig": ["host": "box"]]),
            ("wsl", .remote, ["wslConfig": ["distro": "x"]]),
            ("worktreePath", .inWorktree, ["worktreePath": "/w"]),
            ("worktreeName", .inWorktree, ["worktreeName": "w"]),
            ("branch", .inWorktree, ["branch": "b"]),
            ("sourceBranch", .inWorktree, ["sourceBranch": "main"]),
            ("worktreeLazy", .inWorktree, ["worktreeLazy": ["path": "/w"]]),
            ("keptWorktreeLeftover", .inWorktree, ["keptWorktreeLeftover": true]),
            ("keptDirtyWorktree", .inWorktree, ["keptDirtyWorktree": true]),
            ("origin", .originFolderDiffers, ["originCwd": "/Users/me/elsewhere"]),
            ("prior", .severalTranscripts, ["priorCliSessionIds": ["d1d1d1d1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]]),
            ("unarchived", .severalTranscripts, ["unarchivedCliSessionId": "d1d1d1d1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]),
            ("pre-clear", .severalTranscripts, ["preClearCliSessionId": "d1d1d1d1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]),
        ]
        for (label, refusal, extra) in cases {
            let f = try CopyFixture(record: extra)
            assertRefused(refusal, f)
            XCTAssertFalse(f.steps.contains(.idChosen), label)
        }

        // The working folder is gone.
        let missing = try CopyFixture()
        try FileManager.default.removeItem(atPath: missing.cwd)
        assertRefused(.workingFolderMissing(cwd: missing.cwd), missing)
    }

    func testATranscriptThatIsMissingHardLinkedOrAPipeIsRefused() throws {
        let missing = try CopyFixture()
        try FileManager.default.removeItem(at: missing.transcriptURL)
        assertRefused(.transcriptMissing, missing)

        let linked = try CopyFixture()
        XCTAssertEqual(link(linked.transcriptURL.path, linked.projectFolder.appendingPathComponent("second-name").path), 0)
        assertRefused(.notPlainFile, linked)

        let pipe = try CopyFixture()
        try FileManager.default.removeItem(at: pipe.transcriptURL)
        XCTAssertEqual(mkfifo(pipe.transcriptURL.path, 0o600), 0)
        let started = Date()
        assertRefused(.notPlainFile, pipe)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testASessionStillReplyingIsRefused() throws {
        try f.home.writeRegistry(pid: 4242, ["sessionId": f.x, "status": "busy"])
        assertRefused(.stillReplying)
    }

    /// The list was read a while ago: the session has since been deleted, marked for removal,
    /// or changed. The copy acts on the record as it is now.
    func testAStaleRowIsRefused() throws {
        let deleted = try CopyFixture()
        try FileManager.default.removeItem(at: deleted.storeA.url.appendingPathComponent(deleted.sourceID + ".json"))
        assertRefused(.sessionChanged, deleted)

        for tombstone in ["deleted_\(CopyFixture.x)", "deleted_\(CopyFixture.sourceUUID)", "deleted_local_\(CopyFixture.sourceUUID)"] {
            let f = try CopyFixture()
            try f.write("1", to: f.storeA.url.appendingPathComponent(tombstone))
            assertRefused(.sessionDeleted, f)
        }
        let released = try CopyFixture()
        try released.write("{}", to: released.projectFolder.appendingPathComponent("\(CopyFixture.x).desktop-released.json"))
        assertRefused(.sessionDeleted, released)

        assertRefused(.sessionChanged, request: f.request(cliSessionId: "d1d1d1d1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        assertRefused(.sessionChanged, request: f.request(cwd: f.cwd + "/other"))
    }

    func testATranscriptRegisteredInTwoAccountsIsRefused() throws {
        try f.home.writeRecord(["sessionId": "local_22222222-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "cliSessionId": f.x, "cwd": f.cwd],
                               in: f.storeB)
        assertRefused(.claimedByTwoAccounts)
    }

    func testTooLittleSpaceIsRefusedBeforeTheFirstStagedByte() throws {
        let f = try CopyFixture()
        f.freeBytes = 1 << 30
        assertRefused(.notEnoughSpace, f)
        XCTAssertFalse(f.steps.contains(.preflightPassed))

        // Room for the transcript, but not for the subagent transcripts it references. (A long
        // torn tail keeps what is copied of the transcript well under its size on disk.)
        let g = try CopyFixture(tail: #"{"type":"assistant","text":""# + String(repeating: "y", count: 4_000))
        try g.write(CopyFixture.agentLine + "\n" + String(repeating: "x", count: 100_000) + "\n", to: g.agentURL("a1"))
        let transcript = UInt64(try Data(contentsOf: g.transcriptURL).count)
        g.freeBytes = transcript + CopyRun.recordAllowance + SessionCopy.freeSpaceMargin
        assertRefused(.notEnoughSpace, g)
        XCTAssertTrue(g.steps.contains(.journalCreated))
        XCTAssertFalse(g.steps.contains(.scanned))

        let unknown = try CopyFixture()
        unknown.freeBytes = nil
        assertRefused(.notEnoughSpace, unknown)
    }

    func testCopyingNeedsTheAutomationLock() throws {
        f.holdsLock = false
        assertRefused(.notAutomationLockHolder)
        XCTAssertEqual(f.steps, [])

        // The lock's own file could not be taken: said as that, not as another switcher.
        var environment = f.environment()
        environment.lockFileUnavailable = true
        XCTAssertEqual(SessionCopy.copy(f.request(), allProfiles: f.profiles, environment: environment), .refused(.lockFileUnavailable))
        XCTAssertEqual(f.steps, [])
    }

    /// A title or working folder that contains the session's own id would put that id in the
    /// copy's record: refused before anything is staged, not after the whole copy is.
    func testASessionWhoseTitleOrFolderNamesItsOwnIdIsRefusedBeforeAnythingIsStaged() throws {
        let cases: [(String, [String: Any])] = [
            ("its transcript id, in capitals", ["title": "Notes on \(CopyFixture.x.uppercased())"]),
            ("its record id", ["title": "local_\(CopyFixture.sourceUUID)"]),
            ("its record's bare id", ["title": "see \(CopyFixture.sourceUUID) again"]),
        ]
        for (label, extra) in cases {
            let f = try CopyFixture(record: extra)
            assertRefused(.mentionsOwnID, f)
            XCTAssertFalse(f.steps.contains(.idChosen), label)
        }
        let folder = "/Users/me/\(CopyFixture.x)"
        let g = try CopyFixture(record: ["cwd": folder, "originCwd": folder])
        assertRefused(.mentionsOwnID, g, request: g.request(cwd: folder))
        XCTAssertFalse(g.steps.contains(.idChosen))
    }

    /// A second copy started while one runs is refused and changes nothing. A recovery started
    /// meanwhile waits for the copy to finish — never acting on its half-made files — and then
    /// runs, so its answer is never "nothing to do" for a pass that did not happen.
    func testOneCopyAtATime() throws {
        let f = self.f!
        var inner: SessionCopy.Outcome?
        var innerChanges: TreeSnapshot.Changes?
        var entered = false
        let recovered = expectation(description: "the recovery started during the copy ran")
        let stepsWhenRecoveryRan = Names()
        let recoveryNotes = Names()
        f.hook = { [unowned f] step in
            guard step == .transcriptStaged, !entered else { return }
            entered = true
            let before = f.snapshot()
            inner = SessionCopy.copy(f.request(), allProfiles: f.profiles, environment: f.environment())
            innerChanges = f.snapshot().changes(since: before)
            let environment = f.environment()
            let profiles = f.profiles
            Thread.detachNewThread { [unowned f] in
                let notes = SessionCopy.recover(allProfiles: profiles, environment: environment)
                f.steps.forEach { stepsWhenRecoveryRan.append("\($0)") }
                notes.forEach { recoveryNotes.append($0.message) }
                recovered.fulfill()
            }
            // The recovery is held at the gate while the copy goes on.
            Thread.sleep(forTimeInterval: 0.2)
            XCTAssertEqual(stepsWhenRecoveryRan.values, [], "recovery ran during the copy")
        }
        guard case .copied = f.copy() else { return XCTFail("the first copy did not finish") }
        XCTAssertEqual(inner, .refused(.anotherCopyRunning))
        XCTAssertEqual(innerChanges, TreeSnapshot.Changes())
        wait(for: [recovered], timeout: 10)
        XCTAssertEqual(stepsWhenRecoveryRan.values.last, "\(SessionCopy.Step.recordCommitted)", "it ran after the copy")
        XCTAssertEqual(recoveryNotes.values, [], "the copy finished, so there was nothing to say")
        XCTAssertEqual(try f.journal().phase, .committed)
    }

    /// A copy started while a recovery pass runs waits for it, instead of being told another
    /// copy is in progress.
    func testACopyWaitsForARecoveryPassInsteadOfBeingRefused() throws {
        let f = self.f!
        _ = f.crash(at: .directoryCommitted)
        let inRecovery = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var recovering = f.environment()
        let held = Names()
        recovering.fileEvent = { event in
            // Hold the pass at its first flush, with the gate taken.
            if held.values.isEmpty {
                held.append("\(event)")
                inRecovery.signal()
                release.wait()
            }
            return 0
        }
        let recoveryDone = expectation(description: "recovery finished")
        Thread.detachNewThread { [profiles = f.profiles, recovering] in
            _ = SessionCopy.recover(allProfiles: profiles, environment: recovering)
            recoveryDone.fulfill()
        }
        XCTAssertEqual(inRecovery.wait(timeout: .now() + 10), .success)

        f.newID = UUID(uuidString: "8D8D8D8D-1234-4567-89AB-0123456789AB")!
        let outcome = Names()
        let copyDone = expectation(description: "copy finished")
        let environment = f.environment()
        let request = f.request()
        Thread.detachNewThread { [profiles = f.profiles] in
            outcome.append("\(SessionCopy.copy(request, allProfiles: profiles, environment: environment))")
            copyDone.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(outcome.values, [], "the copy did not wait for the recovery pass")
        release.signal()
        wait(for: [recoveryDone, copyDone], timeout: 10)
        XCTAssertTrue(outcome.values.first?.hasPrefix("copied(") ?? false, "\(outcome.values)")
    }

    // MARK: - 11. The target

    func testATargetThatCannotTakeACopyIsRefused() throws {
        let signedOut = try CopyFixture()
        try signedOut.setWorkSignedIn(false)
        assertRefused(.targetSignedOut(target: "Work"), signedOut)

        let otherAccount = try CopyFixture()
        try otherAccount.home.writeConfig(["lastKnownAccountUuid": "cccccccc-1111-4111-8111-111111111111", "windowSizeWasSignedIn": true],
                                          userDataDir: otherAccount.work.userDataDir)
        assertRefused(.targetHasNoSessions(target: "Work"), otherAccount)

        let twoOrganisations = try CopyFixture()
        try twoOrganisations.home.makeStore(userDataDir: twoOrganisations.work.userDataDir, account: FakeHome.accountB,
                                            org: "dddddddd-2222-4222-8222-222222222222")
        assertRefused(.targetSeveralOrganisations(target: "Work"), twoOrganisations)

        let hint = try CopyFixture()
        try hint.home.writeConfig(["lastKnownAccountUuid": FakeHome.accountB, "windowSizeWasSignedIn": true,
                                   "dxt:allowlistLastUpdated:\(FakeHome.orgA)": "2026-10-04T10:00:00.000Z"],
                                  userDataDir: hint.work.userDataDir)
        assertRefused(.targetOrganisationHasNoSessions(target: "Work"), hint)
    }

    /// The target signs out while the copy is staged: refused before anything is put in place.
    func testATargetThatChangesBeforeTheCommitIsRefusedAndNothingStays() throws {
        let f = self.f!
        let config = f.rel(f.home.userDataDir(f.work.userDataDir).appendingPathComponent("config.json"))
        f.hook = { [unowned f] step in if step == .journalStaged { try f.setWorkSignedIn(false) } }
        let before = f.snapshot().excluding(config)
        XCTAssertEqual(f.copy(), .refused(.targetChanged(target: "Work")))
        let after = f.snapshot().excluding(config)
        XCTAssertEqual(after.ignoringDirectoryTimes, before.ignoringDirectoryTimes, after.difference(from: before))
    }

    /// The target signs out after the transcript is in place: the record is not filed into a
    /// folder Claude will not load; the copy waits for recovery.
    func testATargetThatChangesBeforeTheRecordRenameGetsNoRecord() throws {
        let f = self.f!
        f.hook = { [unowned f] step in if step == .transcriptCommitted { try f.setWorkSignedIn(false) } }
        XCTAssertEqual(f.copy(), .pendingRegistration(
            newSessionID: "local_\(f.y)", detail: CopyRun.pendingDetail(target: "Work")))
        XCTAssertFalse(f.exists(f.recordURL))
        XCTAssertTrue(f.exists(f.copyURL))
        XCTAssertEqual(try f.journal().phase, .staged)
    }

    // MARK: - 12. Links

    /// A link anywhere on the way to what the copy reads or writes is refused, and whatever it
    /// points to is left exactly as it was.
    func testNoLinkIsFollowed() throws {
        let workFolder: (CopyFixture) -> URL = { $0.home.userDataDir($0.work.userDataDir) }
        let targets: [(String, (CopyFixture) -> URL, ((CopyFixture) -> Profile?)?)] = [
            (".claude", { $0.home.root.appendingPathComponent(".claude") }, nil),
            ("projects", { $0.home.root.appendingPathComponent(".claude/projects") }, nil),
            ("<slug>", { $0.projectFolder }, nil),
            ("X.jsonl", { $0.transcriptURL }, nil),
            ("<X>", { $0.projectFolder.appendingPathComponent(CopyFixture.x) }, nil),
            ("subagents", { $0.subagentsFolder }, nil),
            ("agent file", { $0.agentURL("a1") }, nil),
            ("Claude-work", workFolder, nil),
            ("claude-code-sessions", { $0.home.userDataDir($0.work.userDataDir).appendingPathComponent("claude-code-sessions") }, nil),
            ("<acct>", { $0.storeB.url.deletingLastPathComponent() }, nil),
            ("<org>", { $0.storeB.url }, nil),
            // The same folder named with the home directory in other letters: still below home.
            ("Claude-work, the home spelled in capitals", workFolder, { [unowned self] f in
                self.caseVariant(of: workFolder(f).path, in: f).map { Profile(id: "work", label: "Work", userDataDir: $0) }
            }),
        ]
        for (label, path, target) in targets {
            let f = try CopyFixture()
            var profile: Profile?
            if let target {
                guard let spelled = target(f) else { continue }   // a case-sensitive volume
                profile = spelled
            }
            let original = path(f)
            let moved = f.home.root.appendingPathComponent("moved-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            let before = f.snapshot()
            let outcome = f.copy(profile.map { f.request(to: $0) }, profiles: profile.map { [f.personal, $0] })
            guard case .refused = outcome else { XCTFail("\(label): \(outcome)"); continue }
            let after = f.snapshot()
            XCTAssertEqual(after.ignoringDirectoryTimes, before.ignoringDirectoryTimes, "\(label)\n" + after.difference(from: before))
        }
    }

    /// A target folder named with the home directory in other letters is the same folder, and
    /// walked the same way: copied into without a link, refused with one — and nothing is put
    /// behind the link.
    func testATargetFolderSpelledInOtherLettersIsWalkedFromHome() throws {
        let f = self.f!
        guard let spelled = caseVariant(of: f.home.userDataDir(f.work.userDataDir).path, in: f) else {
            throw XCTSkip("this volume is case-sensitive")
        }
        let work = Profile(id: "work", label: "Work", userDataDir: spelled)
        guard case .success(let resolved) = SessionStore.locateForCopyTarget(profile: work, home: f.home.home, expectedOwner: getuid()) else {
            return XCTFail("the target does not resolve")
        }
        XCTAssertEqual(resolved.store.status.identity, FileStatus.ofPath(f.storeB.url.path)?.identity)
        guard case .copied = f.copy(f.request(to: work), profiles: [f.personal, work]) else { return XCTFail("not copied") }
        XCTAssertTrue(f.exists(f.recordURL))

        let g = try CopyFixture()
        let folder = g.home.userDataDir(g.work.userDataDir)
        let real = g.home.root.appendingPathComponent("elsewhere/Claude-work-real")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder, to: real)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: real)
        let linked = Profile(id: "work", label: "Work", userDataDir: try XCTUnwrap(caseVariant(of: folder.path, in: g)))
        let before = g.snapshot()
        XCTAssertEqual(g.copy(g.request(to: linked), profiles: [g.personal, linked]), .refused(.targetFolderIsLink(target: "Work")))
        XCTAssertFalse(g.exists(real.appendingPathComponent("claude-code-sessions/\(FakeHome.accountB)/\(FakeHome.orgB)/local_\(g.y).json")))
        XCTAssertEqual(g.snapshot().ignoringDirectoryTimes, before.ignoringDirectoryTimes, g.snapshot().difference(from: before))
    }

    /// A target folder spelled through a link that lies outside the home directory and leads
    /// to a folder below it: no ancestor of that spelling is home, but where it lands is. The
    /// same folder spelled from home is refused for the link below home on its way, so this
    /// spelling is refused too — and nothing is put behind that link.
    func testATargetSpelledThroughALinkOutsideHomeThatLeadsIntoItIsRefused() throws {
        let f = self.f!
        let fileManager = FileManager.default
        let work = f.home.userDataDir(f.work.userDataDir)
        let real = f.home.root.appendingPathComponent("elsewhere/Claude-work-real")
        try fileManager.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: work, to: real)
        try fileManager.createSymbolicLink(at: work, withDestinationURL: real)
        // Next to the home directory, not in it: a link to <home>/Library.
        let outside = f.home.root.deletingLastPathComponent().appendingPathComponent("outside-link-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: outside, withDestinationURL: f.home.root.appendingPathComponent("Library"))
        defer { try? fileManager.removeItem(at: outside) }
        let spelled = outside.path + "/Application Support/Claude-work"
        XCTAssertEqual(try HeldDirectory.anchorAndComponents(of: spelled, home: f.home.home).anchor, spelled, "spelled outside home")

        let canonical = Profile(id: "work", label: "Work", userDataDir: work.path)
        assertRefused(.targetFolderIsLink(target: "Work"), request: f.request(to: canonical), profiles: [f.personal, canonical])
        let viaLink = Profile(id: "work", label: "Work", userDataDir: spelled)
        assertRefused(.targetFolderIsLink(target: "Work"), request: f.request(to: viaLink), profiles: [f.personal, viaLink])
        let behind = real.appendingPathComponent("claude-code-sessions/\(FakeHome.accountB)/\(FakeHome.orgB)")
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: behind.path), [], "nothing behind the link below home")
    }

    /// The project folder or the target's organisation folder is swapped for a link after
    /// preflight: the copy works on the folders it holds, so nothing lands in the link's
    /// target; the re-check notices and nothing is left anywhere.
    func testAFolderSwappedForALinkAfterPreflightReceivesNothing() throws {
        for which in ["<slug>", "<org>"] {
            let f = try CopyFixture()
            let original = which == "<slug>" ? f.projectFolder : f.storeB.url
            let moved = f.home.root.appendingPathComponent("moved")
            let decoy = f.home.root.appendingPathComponent("decoy")
            try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
            f.hook = { step in
                if step == .preflightPassed {
                    try FileManager.default.moveItem(at: original, to: moved)
                    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: decoy)
                }
            }
            let decoyBefore = TreeSnapshot(of: decoy)
            let outcome = f.copy()
            guard case .refused = outcome else { XCTFail("\(which): \(outcome)"); continue }
            XCTAssertEqual(TreeSnapshot(of: decoy), decoyBefore, which)
            XCTAssertTrue(TreeSnapshot(of: moved).paths.allSatisfy { !$0.contains(f.y) }, which)
            XCTAssertEqual(f.journalFiles, [], which)
        }
    }

    // MARK: - 13. Ownership and permissions

    func testAForeignOwnerOrAFolderOthersCanWriteToIsRefused() throws {
        let foreign = try CopyFixture()
        foreign.expectedUID = getuid() + 1
        assertRefused(.targetFolderNotYours(target: "Work"), foreign)

        let openProject = try CopyFixture()
        XCTAssertEqual(chmod(openProject.projectFolder.path, 0o775), 0)
        assertRefused(.writableByOthers, openProject)

        let openStore = try CopyFixture()
        XCTAssertEqual(chmod(openStore.storeB.url.path, 0o757), 0)
        assertRefused(.targetFolderWritableByOthers(target: "Work"), openStore)
    }

    // MARK: - 14. Every create and rename is exclusive

    private enum Plant: CaseIterable { case file, emptyFolder, danglingLink }

    private func plant(_ kind: Plant, at url: URL) throws {
        switch kind {
        case .file: try Data("planted".utf8).write(to: url)
        case .emptyFolder: try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        case .danglingLink: try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/nonexistent-target")
        }
    }

    /// Something appears at a name the copy is about to create, after it proved the name free:
    /// the copy fails, the planted object is untouched, and no record is filed.
    func testSomethingPlantedAtAnyNameAfterPreflightIsNeverReplaced() throws {
        func names(_ f: CopyFixture) -> [(String, URL, SessionCopy.Step)] {
            [
                ("staged transcript", f.projectFolder.appendingPathComponent(f.names.transcript), .idChosen),
                ("staging folder", f.projectFolder.appendingPathComponent(f.names.directory), .idChosen),
                ("staged record", f.storeB.url.appendingPathComponent(f.names.record), .idChosen),
                ("<Y>.jsonl, before the re-check", f.copyURL, .idChosen),
                ("<Y>, before the re-check", f.projectFolder.appendingPathComponent(f.y), .idChosen),
                ("local_<Y>.json, before the re-check", f.recordURL, .idChosen),
                ("local_<Y>.json in the source store, before the re-check", f.storeA.url.appendingPathComponent("local_\(f.y).json"), .idChosen),
                ("<Y>.jsonl, at the rename", f.copyURL, .rechecked),
                ("<Y>, at the rename", f.projectFolder.appendingPathComponent(f.y), .rechecked),
                ("local_<Y>.json, at the rename", f.recordURL, .rechecked),
            ]
        }
        for kind in Plant.allCases {
            for index in 0..<10 {
                let f = try CopyFixture()
                let (label, url, step) = names(f)[index]
                f.hook = { [unowned self] in if $0 == step { try self.plant(kind, at: url) } }
                let outcome = f.copy()
                let planted = f.snapshot().entry(f.rel(url))
                // Caught by the re-check or the exclusive create before the transcript's rename —
                // then nothing of the copy is left — or by the exclusive rename after it.
                let committedBefore = step == .rechecked && url.path != f.copyURL.path
                if committedBefore {
                    XCTAssertEqual(outcome, .pendingRegistration(newSessionID: "local_\(f.y)",
                        detail: CopyRun.pendingDetail(target: "Work")), "\(kind) at \(label)")
                } else {
                    XCTAssertEqual(outcome, .refused(.nameTaken), "\(kind) at \(label)")
                    XCTAssertTrue(f.snapshot().paths.allSatisfy { !$0.contains(".claude-switcher-") || $0.hasPrefix(f.rel(url)) },
                                  "\(kind) at \(label)")
                    XCTAssertEqual(f.journalFiles, [], "\(kind) at \(label)")
                }
                // The planted object is exactly as planted.
                let entry = try XCTUnwrap(planted, "\(kind) at \(label)")
                switch kind {
                case .file: XCTAssertEqual(try Data(contentsOf: url), Data("planted".utf8), label)
                case .emptyFolder:
                    XCTAssertEqual(entry.type, "dir", label)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path), [], label)
                case .danglingLink: XCTAssertEqual(entry.linkTarget, "/nonexistent-target", label)
                }
                // No record of this copy was filed.
                if url.path != f.recordURL.path { XCTAssertFalse(f.exists(f.recordURL), "\(kind) at \(label)") }
            }
        }
    }

    // MARK: - 15. Collisions anywhere on the Mac

    func testTheNewIdMustBeUnusedInEveryStoreOnTheMac() throws {
        // A configured profile can live anywhere, not only under Application Support.
        let third = Profile(id: "third", label: "Third", userDataDir: "~/Profiles/third")
        let y = f.y
        let stray = "~/Library/Application Support/Claude-old"

        for name in ["local_\(y).json", "deleted_\(y)", "deleted_local_\(y)"] {
            let configured = try CopyFixture()
            let store = try configured.home.makeStore(userDataDir: third.userDataDir, account: "eeeeeeee-1111-4111-8111-111111111111",
                                                      org: "eeeeeeee-2222-4222-8222-222222222222")
            try configured.write("{}", to: store.url.appendingPathComponent(name))
            assertRefused(.nameTaken, configured, profiles: configured.profiles + [third])

            let unconfigured = try CopyFixture()
            let strayStore = try unconfigured.home.makeStore(userDataDir: stray, account: "eeeeeeee-1111-4111-8111-111111111111",
                                                             org: "eeeeeeee-2222-4222-8222-222222222222")
            try unconfigured.write("{}", to: strayStore.url.appendingPathComponent(name))
            assertRefused(.nameTaken, unconfigured)

            // Any Claude* folder, in any case.
            let lowerCase = try CopyFixture()
            let lowerStore = try lowerCase.home.makeStore(userDataDir: "~/Library/Application Support/claude-old",
                                                          account: "eeeeeeee-1111-4111-8111-111111111111",
                                                          org: "eeeeeeee-2222-4222-8222-222222222222")
            try lowerCase.write("{}", to: lowerStore.url.appendingPathComponent(name))
            assertRefused(.nameTaken, lowerCase)

            // The target's own store, wherever it is, configured or not.
            let outside = try CopyFixture()
            let outsideStore = try outside.home.signIn(userDataDir: third.userDataDir, account: "cccccccc-1111-4111-8111-111111111111",
                                                       org: "cccccccc-2222-4222-8222-222222222222")
            try outside.write("{}", to: outsideStore.url.appendingPathComponent(name))
            assertRefused(.nameTaken, outside, request: outside.request(to: third), profiles: outside.profiles)
        }

        let unreadable = try CopyFixture()
        let strayStore = try unreadable.home.makeStore(userDataDir: stray, account: "eeeeeeee-1111-4111-8111-111111111111",
                                                       org: "eeeeeeee-2222-4222-8222-222222222222")
        XCTAssertEqual(chmod(strayStore.url.path, 0o000), 0)
        assertRefused(.storeUnreadable, unreadable)
        chmod(strayStore.url.path, 0o755)

        // Readable but not searchable: what is at a name cannot be told, so it is not "absent".
        let unsearchable = try CopyFixture()
        let closedStore = try unsearchable.home.makeStore(userDataDir: stray, account: "eeeeeeee-1111-4111-8111-111111111111",
                                                          org: "eeeeeeee-2222-4222-8222-222222222222")
        XCTAssertEqual(chmod(closedStore.url.path, 0o600), 0)
        assertRefused(.storeUnreadable, unsearchable)
        chmod(closedStore.url.path, 0o755)

        for place in [".claude/file-history/\(y)", "PROJECT/\(y).desktop-released.json", "PROJECT/\(y).jsonl", "PROJECT/\(y)"] {
            let f = try CopyFixture()
            let url = place.hasPrefix("PROJECT/")
                ? f.projectFolder.appendingPathComponent(String(place.dropFirst(8)))
                : f.home.root.appendingPathComponent(place)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            assertRefused(.nameTaken, f)
        }
    }

    // MARK: - 16. No exclusive rename on the volume

    func testAVolumeWithoutExclusiveRenameIsRefusedAndStagingRemoved() throws {
        for code in [ENOTSUP, EINVAL] {
            let f = try CopyFixture()
            let calls = Counter()
            f.renameExclusive = { _, _, _, _ in calls.increment(); return code }
            assertRefused(.renameUnsupported, f)
            XCTAssertEqual(calls.value, 1, "one exclusive rename was tried, and nothing after it")
            XCTAssertFalse(f.exists(f.copyURL))
        }
    }

    // MARK: - The cheap check agrees with the copy

    func testTheMenusCheckMatchesWhatTheCopyDoes() throws {
        let listing = SessionListing.read(profile: f.personal, allProfiles: f.profiles, environment: f.environment())
        let session = try XCTUnwrap(listing.sessions.first)
        XCTAssertNil(SessionCopy.obstacle(for: session, from: f.personal, to: f.work, allProfiles: f.profiles, environment: f.environment()))
        guard case .copied = f.copy() else { return XCTFail("not copied") }
    }

    // MARK: - Proofs on the way

    /// A name the copy would stage under is already taken: refused before anything is written,
    /// not even the journal.
    func testANameTakenBeforeTheCopyStartsIsRefusedBeforeAnythingIsWritten() throws {
        for place in ["transcript", "directory", "record"] {
            let f = try CopyFixture()
            let url = place == "record" ? f.storeB.url.appendingPathComponent(f.names.record)
                : f.projectFolder.appendingPathComponent(place == "transcript" ? f.names.transcript : f.names.directory)
            try f.write("planted", to: url)
            assertRefused(.nameTaken, f)
            XCTAssertFalse(f.steps.contains(.journalCreated), place)
        }
    }

    /// The source gains a second name after preflight: the descriptor's own `fstat` refuses it.
    func testATranscriptHardLinkedAfterPreflightIsRefused() throws {
        let f = self.f!
        let second = f.projectFolder.appendingPathComponent("second-name")
        f.hook = { [unowned f] step in
            if step == .journalCreated { XCTAssertEqual(link(f.transcriptURL.path, second.path), 0) }
        }
        let before = f.snapshot().excluding(f.rel(f.transcriptURL))
        XCTAssertEqual(f.copy(), .refused(.notPlainFile))
        let after = f.snapshot().excluding(f.rel(f.transcriptURL)).excluding(f.rel(second))
        XCTAssertEqual(after.changes(since: before), TreeSnapshot.Changes(), after.difference(from: before))
        XCTAssertEqual(f.journalFiles, [])
    }

    /// The staged record is not what was written — on disk right after writing, or later,
    /// before its rename: it is never filed.
    func testARecordThatIsNotWhatWasWrittenIsNeverFiled() throws {
        func spoil(_ f: CopyFixture) throws {
            let staged = f.storeB.url.appendingPathComponent(f.names.record)
            var bytes = try Data(contentsOf: staged)
            bytes[bytes.count - 2] = UInt8(ascii: " ")
            let handle = try FileHandle(forWritingTo: staged)
            try handle.write(contentsOf: bytes)
            try handle.close()
        }
        let early = try CopyFixture()
        early.hook = { [unowned early] step in if step == .recordStaged { try spoil(early) } }
        assertRefused(.recordCheckFailed, early)

        let late = try CopyFixture()
        late.hook = { [unowned late] step in if step == .rechecked { try spoil(late) } }
        XCTAssertEqual(late.copy(), .pendingRegistration(
            newSessionID: "local_\(late.y)", detail: CopyRun.pendingDetail(target: "Work")))
        XCTAssertFalse(late.exists(late.recordURL))

        // Replaced by another file with the very same bytes: it is not the file written, so it
        // is not filed — and as it is not this copy's either, it and the journal stay.
        let swapped = try CopyFixture()
        swapped.hook = { [unowned swapped] step in
            if step == .recordStaged {
                let bytes = try Data(contentsOf: swapped.stagedRecordURL)
                try FileManager.default.removeItem(at: swapped.stagedRecordURL)
                try bytes.write(to: swapped.stagedRecordURL)
            }
        }
        XCTAssertEqual(swapped.copy(), .refused(.recordCheckFailed))
        XCTAssertFalse(swapped.exists(swapped.recordURL))
        XCTAssertEqual(swapped.journalFiles, ["\(swapped.y).json"])
        let refused = swapped.snapshot()
        XCTAssertEqual(swapped.recover().map(\.message), [leftInPlace])
        XCTAssertEqual(swapped.snapshot(), refused)
    }

    /// Something else is put at a staging name after the re-check: it is never renamed into place.
    func testAStagedObjectReplacedBeforeItsRenameIsNeverPutInPlace() throws {
        let transcript = try CopyFixture()
        transcript.hook = { [unowned transcript] step in
            if step == .rechecked {
                let staged = transcript.projectFolder.appendingPathComponent(transcript.names.transcript)
                try FileManager.default.removeItem(at: staged)
                try transcript.write("{\"someone\":\"else\"}\n", to: staged)
            }
        }
        XCTAssertEqual(transcript.copy(), .refused(.notPlainFile))
        XCTAssertFalse(transcript.exists(transcript.copyURL))
        XCTAssertEqual(try String(contentsOf: transcript.projectFolder.appendingPathComponent(transcript.names.transcript), encoding: .utf8),
                       "{\"someone\":\"else\"}\n")
        // What cannot be proven is not removed, and neither is the journal that names the rest:
        // without it the staging folder and the staged record would be orphaned in Claude's folders.
        XCTAssertEqual(transcript.journalFiles, ["\(transcript.y).json"])
        let kept = try transcript.journal()
        XCTAssertEqual(kept.phase, .staged)
        XCTAssertNotNil(kept.staged.transcript)
        XCTAssertNotNil(kept.staged.directory)
        XCTAssertNotNil(kept.staged.subagents)
        XCTAssertEqual(kept.staged.agents.map(\.name), ["agent-a1.jsonl"])
        XCTAssertNotNil(kept.staged.record)
        let refused = transcript.snapshot()
        XCTAssertEqual(transcript.recover().map(\.message), [leftInPlace])
        XCTAssertEqual(transcript.snapshot(), refused)

        let folder = try CopyFixture()
        folder.hook = { [unowned folder] step in
            if step == .rechecked {
                let staged = folder.projectFolder.appendingPathComponent(folder.names.directory)
                try FileManager.default.moveItem(at: staged, to: folder.home.root.appendingPathComponent("aside"))
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
            }
        }
        XCTAssertEqual(folder.copy(), .pendingRegistration(
            newSessionID: "local_\(folder.y)", detail: CopyRun.pendingDetail(target: "Work")))
        XCTAssertFalse(folder.exists(folder.projectFolder.appendingPathComponent(folder.y)))
        XCTAssertFalse(folder.exists(folder.recordURL))
    }

    /// The original is deleted while the copy is staged: a copy of it would bring it back.
    func testTheOriginalDeletedWhileTheCopyIsStagedIsRefused() throws {
        let f = self.f!
        let record = f.storeA.url.appendingPathComponent(f.sourceID + ".json")
        f.hook = { step in if step == .journalStaged { try FileManager.default.removeItem(at: record) } }
        let before = f.snapshot().excluding(f.rel(record))
        XCTAssertEqual(f.copy(), .refused(.sessionChanged))
        let after = f.snapshot()
        XCTAssertEqual(after.changes(since: before), TreeSnapshot.Changes(), after.difference(from: before))
        XCTAssertEqual(f.journalFiles, [])
    }

    /// Transcript, then subagent folder, then record: by the time Claude can see the record,
    /// everything it names is in place.
    func testTheRecordIsFiledLast() throws {
        let f = self.f!
        var seen: [SessionCopy.Step: (transcript: Bool, folder: Bool, record: Bool)] = [:]
        f.hook = { [unowned f] step in
            seen[step] = (f.exists(f.copyURL), f.exists(f.copiedAgentURL), f.exists(f.recordURL))
        }
        guard case .copied = f.copy() else { return XCTFail("not copied") }
        XCTAssertTrue(seen[.rechecked].map { !$0.transcript && !$0.folder && !$0.record } ?? false)
        XCTAssertTrue(seen[.transcriptCommitted].map { $0.transcript && !$0.folder && !$0.record } ?? false)
        XCTAssertTrue(seen[.directoryCommitted].map { $0.transcript && $0.folder && !$0.record } ?? false)
        XCTAssertTrue(seen[.recordCommitted].map { $0.transcript && $0.folder && $0.record } ?? false)
    }

    /// Recovery acts on what the journal says, so others must not be able to write it.
    func testAJournalFolderOthersCanWriteToIsNeitherUsedNorTrusted() throws {
        XCTAssertEqual(chmod(f.journalDirectory.path, 0o777), 0)
        assertRefused(.writableByOthers)
        let before = f.snapshot()
        XCTAssertEqual(f.recover().count, 1)
        XCTAssertEqual(f.snapshot(), before)
    }

    /// The proof that a staged object is still the one created, on fabricated `fstat` results —
    /// a file of another owner, or a link with the recorded inode, cannot be made without root.
    func testAStagedObjectIsProvenByKindLinksOwnerAndInode() {
        func status(_ mode: mode_t, links: nlink_t = 1, owner: uid_t = getuid(), inode: ino_t = 7) -> FileStatus {
            var info = stat()
            info.st_mode = mode
            info.st_nlink = links
            info.st_uid = owner
            info.st_ino = inode
            return FileStatus(info)
        }
        let object = StagedObject(name: "x", inode: 7)
        let me = getuid()
        XCTAssertTrue(StagingCleanup.isAsCreated(status(S_IFREG | 0o600), object, owner: me))
        XCTAssertFalse(StagingCleanup.isAsCreated(status(S_IFLNK | 0o777), object, owner: me), "a link")
        XCTAssertFalse(StagingCleanup.isAsCreated(status(S_IFDIR | 0o700), object, owner: me), "a folder")
        XCTAssertFalse(StagingCleanup.isAsCreated(status(S_IFREG | 0o600, links: 2), object, owner: me), "two names")
        XCTAssertFalse(StagingCleanup.isAsCreated(status(S_IFREG | 0o600, owner: me + 1), object, owner: me), "another owner")
        XCTAssertFalse(StagingCleanup.isAsCreated(status(S_IFREG | 0o600, inode: 8), object, owner: me), "another file")

        XCTAssertTrue(StagingCleanup.isFolderAsCreated(status(S_IFDIR | 0o700), object, owner: me))
        XCTAssertFalse(StagingCleanup.isFolderAsCreated(status(S_IFLNK | 0o777), object, owner: me), "a link")
        XCTAssertFalse(StagingCleanup.isFolderAsCreated(status(S_IFDIR | 0o700, owner: me + 1), object, owner: me), "another owner")
        XCTAssertFalse(StagingCleanup.isFolderAsCreated(status(S_IFDIR | 0o700, inode: 8), object, owner: me), "another folder")
    }

    // MARK: - Cleaning up after a failure: all or nothing

    /// A stranger's file joined the staging folder before the copy failed: the copy cannot
    /// prove that folder is still only its own, so it leaves everything it staged — and the
    /// journal that names it all — rather than part of it. Recovery reports it; once the
    /// stranger is gone, recovery removes the rest.
    func testAFailedCopyThatCannotProveItsStagingLeavesAllOfItForRecovery() throws {
        let f = self.f!
        let before = f.snapshot()
        f.hook = { [unowned f] step in
            if step == .journalStaged {
                try f.write("", to: f.stagingFolderURL.appendingPathComponent(".DS_Store"))
                try Data("planted".utf8).write(to: f.copyURL)   // the re-check refuses
            }
        }
        XCTAssertEqual(f.copy(), .refused(.nameTaken))
        XCTAssertEqual(f.journalFiles, ["\(f.y).json"])
        for url in [f.stagedTranscriptURL, f.stagingFolderURL, f.stagedRecordURL] { XCTAssertTrue(f.exists(url), url.lastPathComponent) }
        let refused = f.snapshot()
        XCTAssertEqual(f.recover().map(\.message), [leftInPlace])
        XCTAssertEqual(f.snapshot(), refused, f.snapshot().difference(from: refused))

        try FileManager.default.removeItem(at: f.stagingFolderURL.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(f.recover().map(\.message), [cleanedUp])
        XCTAssertEqual(f.journalFiles, [])
        let after = f.snapshot().excluding(f.rel(f.copyURL))
        XCTAssertEqual(after.changes(since: before), TreeSnapshot.Changes(), after.difference(from: before))
        XCTAssertEqual(try Data(contentsOf: f.copyURL), Data("planted".utf8))
    }

    /// The staging folder was made and swapped for a link before the copy could hold it: the
    /// folder made is this copy's but not journalled, and a link now has its name. The copy
    /// does not forget it — it keeps its journal, and touches nothing.
    func testAStagingFolderSwappedRightAfterItIsMadeKeepsTheJournal() throws {
        let f = self.f!
        let aside = f.home.root.appendingPathComponent("aside")
        f.hook = { [unowned f] step in
            if step == .stagingFolderCreated {
                try FileManager.default.moveItem(at: f.stagingFolderURL, to: aside)
                try FileManager.default.createSymbolicLink(at: f.stagingFolderURL, withDestinationURL: aside)
            }
        }
        XCTAssertEqual(f.copy(), .refused(.linkInPath))
        XCTAssertEqual(f.journalFiles, ["\(f.y).json"])
        XCTAssertTrue(f.exists(f.stagedTranscriptURL))
        let refused = f.snapshot()
        XCTAssertEqual(f.recover().map(\.message), [leftInPlace])
        XCTAssertEqual(f.snapshot(), refused, f.snapshot().difference(from: refused))
    }

    // MARK: - What is put in place is exactly what was written

    /// A staged file must hold exactly what was written, under one name — checked right after
    /// the write, and again, for size, when it is put in place.
    func testAStagedFileChangedAfterItsWriteIsNeverPutInPlace() throws {
        func truncate(_ url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 10)
            try handle.close()
        }
        let written: [(SessionCopy.Step, (CopyFixture) -> URL)] = [
            (.transcriptWritten, { $0.stagedTranscriptURL }),
            (.agentWritten, { $0.stagingFolderURL.appendingPathComponent("subagents/agent-a1.jsonl") }),
        ]
        for (step, url) in written {
            let f = try CopyFixture()
            f.hook = { [unowned f] in if $0 == step { try truncate(url(f)) } }
            assertRefused(.fileSystem(errno: EIO), f)
            XCTAssertFalse(f.exists(f.copyURL), "\(step)")
        }

        // Truncated once it is on the drive, before its rename.
        let late = try CopyFixture()
        late.hook = { [unowned late] in if $0 == .journalStaged { try truncate(late.stagedTranscriptURL) } }
        assertRefused(.notPlainFile, late)
        XCTAssertFalse(late.exists(late.copyURL))

        // Given a second name right after the write: not provably this copy's alone, so it and
        // the journal stay for recovery to report.
        let linked = try CopyFixture()
        let second = linked.home.root.appendingPathComponent("second-name")
        linked.hook = { [unowned linked] in
            if $0 == .transcriptWritten { XCTAssertEqual(link(linked.stagedTranscriptURL.path, second.path), 0) }
        }
        XCTAssertEqual(linked.copy(), .refused(.fileSystem(errno: EIO)))
        XCTAssertEqual(linked.journalFiles, ["\(linked.y).json"])
        let refused = linked.snapshot()
        XCTAssertEqual(linked.recover().map(\.message), [leftInPlace])
        XCTAssertEqual(linked.snapshot(), refused)
    }

    // MARK: - The re-check before the commit: still the same folders and the same original

    /// The project folder is replaced by a new, real folder after everything is staged: the
    /// copy would land where Claude no longer looks. Refused; nothing reaches either folder.
    func testAProjectFolderReplacedBeforeTheCommitReceivesNothing() throws {
        let f = self.f!
        let aside = f.home.root.appendingPathComponent("old-project")
        f.hook = { [unowned f] step in
            if step == .journalStaged {
                try FileManager.default.moveItem(at: f.projectFolder, to: aside)
                XCTAssertEqual(mkdir(f.projectFolder.path, 0o700), 0)
            }
        }
        XCTAssertEqual(f.copy(), .refused(.sessionChanged))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.projectFolder.path), [])
        XCTAssertTrue(TreeSnapshot(of: aside).paths.allSatisfy { !$0.contains(f.y) }, "\(TreeSnapshot(of: aside).paths)")
        XCTAssertFalse(f.exists(f.recordURL))
        XCTAssertFalse(f.exists(f.stagedRecordURL))
        XCTAssertEqual(f.journalFiles, [])
    }

    /// The target's organisation folder is replaced by a new, real folder of the same name, or
    /// the very folder held is renamed under another account or organisation: Claude would not
    /// load a record filed in the folder held. Before the commit: refused, nothing left. After
    /// the transcript's: no record, and the copy waits.
    func testATargetStoreThatIsNoLongerTheOneHeldGetsNoRecord() throws {
        let accountC = "cccccccc-1111-4111-8111-111111111111"
        let changes: [(String, (CopyFixture) throws -> Void)] = [
            ("replaced by a new folder", { f in
                try FileManager.default.moveItem(at: f.storeB.url, to: f.home.root.appendingPathComponent("old-store"))
                XCTAssertEqual(mkdir(f.storeB.url.path, 0o700), 0)
            }),
            ("renamed to another organisation", { f in
                let renamed = f.storeB.url.deletingLastPathComponent().appendingPathComponent("dddddddd-2222-4222-8222-222222222222")
                try FileManager.default.moveItem(at: f.storeB.url, to: renamed)
            }),
            ("its account folder renamed to the account Work now has", { f in
                let account = f.storeB.url.deletingLastPathComponent()
                try FileManager.default.moveItem(at: account, to: account.deletingLastPathComponent().appendingPathComponent(accountC))
                try f.home.writeConfig(["lastKnownAccountUuid": accountC, "windowSizeWasSignedIn": true], userDataDir: f.work.userDataDir)
            }),
        ]
        for (label, change) in changes {
            let early = try CopyFixture()
            early.hook = { [unowned early] in if $0 == .journalStaged { try change(early) } }
            XCTAssertEqual(early.copy(), .refused(.targetChanged(target: "Work")), label)
            let leftovers = early.snapshot().paths.filter { $0.contains(".claude-switcher-") || $0.contains(early.y) }
            XCTAssertEqual(leftovers, [], label)
            XCTAssertEqual(early.journalFiles, [], label)

            let late = try CopyFixture()
            late.hook = { [unowned late] in if $0 == .transcriptCommitted { try change(late) } }
            XCTAssertEqual(late.copy(), .pendingRegistration(newSessionID: "local_\(late.y)", detail: pendingDetail), label)
            XCTAssertEqual(late.snapshot().paths.filter { $0.hasSuffix("local_\(late.y).json") }, [], label)
            XCTAssertEqual(try late.journal().phase, .staged, label)
        }
    }

    /// The original now names another transcript, or another folder: a copy of what it was is
    /// not a copy of it. Refused, and nothing is left.
    func testTheOriginalRepointedWhileTheCopyIsStagedIsRefused() throws {
        let changes: [(String, (CopyFixture) -> [String: Any])] = [
            ("another transcript", { f in ["cliSessionId": "d1d1d1d1-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "cwd": f.cwd, "originCwd": f.cwd] }),
            ("another folder", { f in ["cliSessionId": CopyFixture.x, "cwd": f.cwd + "/elsewhere", "originCwd": f.cwd + "/elsewhere"] }),
        ]
        for (label, fields) in changes {
            let f = try CopyFixture()
            let record = f.storeA.url.appendingPathComponent(f.sourceID + ".json")
            f.hook = { [unowned f] step in
                if step == .journalStaged {
                    var all = fields(f)
                    all["sessionId"] = f.sourceID
                    try f.home.writeRecord(all, in: f.storeA)
                }
            }
            let before = f.snapshot().excluding(f.rel(record))
            XCTAssertEqual(f.copy(), .refused(.sessionChanged), label)
            let after = f.snapshot().excluding(f.rel(record))
            XCTAssertEqual(after.ignoringDirectoryTimes, before.ignoringDirectoryTimes, "\(label)\n" + after.difference(from: before))
            XCTAssertEqual(f.journalFiles, [], label)
        }
    }

    // MARK: - Descriptors

    /// A session that used hundreds of subagents copies within the 256 descriptors launchd
    /// gives a GUI app: the transcripts are opened one at a time.
    func testASessionWithHundredsOfSubagentsIsCopiedWithinAGUIAppsDescriptors() throws {
        let count = 300
        let lines = [#"{"type":"user","n":1}"#] + (0..<count).map { #"{"type":"assistant","toolUseResult":{"agentId":"b\#($0)"}}"# }
        let f = try CopyFixture(lines: lines, subagents: false)
        for i in 0..<count { try f.write(#"{"type":"user","agentId":"b\#(i)"}"# + "\n", to: f.agentURL("b\(i)")) }
        let opened = openDescriptors()
        let outcome = try withDescriptorHeadroom(32) { f.copy() }
        guard case .copied(let success) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(success.copiedSubagentTranscripts, count)
        XCTAssertEqual(success.skippedSubagentTranscripts, 0)
        XCTAssertEqual(openDescriptors(), opened)
    }

    // MARK: - Flushes, in the order a power cut needs

    /// The journal is whole on the drive before anything is staged; each staged file is flushed
    /// before the journal says "staged", which goes past the drive's cache before the first
    /// rename, as the staged transcript does (and the store, on another volume); the project
    /// folder is flushed between the transcript's rename and the record's (past the cache, on
    /// two volumes); both folders and the drive's cache after the record's, before "committed".
    func testFlushesComeInTheOrderAPowerCutNeeds() throws {
        for separate in [false, true] {
            let f = try CopyFixture()
            f.separateVolumes = separate
            guard case .copied = f.copy() else { return XCTFail("not copied") }
            let events = f.events
            let label = separate ? "two volumes" : "one volume"
            func first(_ event: FileEvent, in range: Range<Int>? = nil) -> Int? {
                events[range ?? events.indices].firstIndex(of: event)
            }

            // 4. The journal.
            let firstStaged = try XCTUnwrap(events.firstIndex {
                if case .created(let name) = $0 { return name.hasPrefix(".claude-switcher-") }
                return false
            }, label)
            let journalFlushed = try XCTUnwrap(first(.flush(.full, .journalFile)), label)
            let journalInPlace = try XCTUnwrap(first(.renamed(from: ".\(f.y).json.partial", to: "\(f.y).json")), label)
            XCTAssertLessThan(journalFlushed, journalInPlace, label)
            XCTAssertLessThan(journalInPlace, firstStaged, label)
            // Its name too, past the drive's cache, before the first staged create: a power cut
            // must not keep a staged file and lose the journal that names it.
            XCTAssertNotNil(first(.flush(.full, .journalFolder), in: journalInPlace..<firstStaged), label)

            // 7–10. Each staged file flushed before the journal's "staged", which is past the cache.
            let transcriptRename = try XCTUnwrap(first(.renamed(from: f.names.transcript, to: f.y + ".jsonl")), label)
            let stagedFolder = try XCTUnwrap(events[..<transcriptRename].lastIndex(of: .flush(.full, .journalFolder)), label)
            let stagedFile = try XCTUnwrap(events[..<stagedFolder].lastIndex(of: .flush(.full, .journalFile)), label)
            for what in [FileEvent.Flushed.transcript, .agent, .record] {
                XCTAssertLessThan(try XCTUnwrap(first(.flush(.fsync, what)), "\(label) \(what)"), stagedFile, "\(label) \(what)")
            }

            // 12. Past the cache before the first rename.
            XCTAssertLessThan(try XCTUnwrap(first(.flush(.full, .transcript)), label), transcriptRename, label)
            let storeBefore = first(.flush(.full, .store), in: 0..<transcriptRename)
            XCTAssertEqual(storeBefore != nil, separate, label)

            // The project folder between the transcript's rename and the record's.
            let recordRename = try XCTUnwrap(first(.renamed(from: f.names.record, to: "local_\(f.y).json")), label)
            XCTAssertNotNil(first(.flush(.fsync, .projectFolder), in: transcriptRename..<recordRename), label)
            XCTAssertEqual(first(.flush(.full, .projectFolder), in: transcriptRename..<recordRename) != nil, separate, label)

            // After the record's: both folders, and the drive's cache, before "committed".
            let committedFolder = try XCTUnwrap(events.lastIndex(of: .flush(.full, .journalFolder)), label)
            XCTAssertGreaterThan(committedFolder, recordRename, label)
            let committedFile = try XCTUnwrap(events[..<committedFolder].lastIndex(of: .flush(.full, .journalFile)), label)
            XCTAssertGreaterThan(committedFile, recordRename, label)
            for flush in [FileEvent.flush(.fsync, .projectFolder), .flush(.fsync, .store), .flush(.full, .store)] {
                XCTAssertNotNil(first(flush, in: recordRename..<committedFile), "\(label) \(flush)")
            }
        }
    }

    /// Recovery puts the record in place the same way: the project folder flushed first.
    func testRecoveryFlushesTheProjectFolderBeforeTheRecordsRename() throws {
        for separate in [false, true] {
            let f = try CopyFixture()
            f.separateVolumes = separate
            _ = f.crash(at: .directoryCommitted)
            f.events = []
            XCTAssertEqual(f.recover().map(\.message), [finished])
            let recordRename = try XCTUnwrap(f.events.firstIndex(of: .renamed(from: f.names.record, to: "local_\(f.y).json")))
            let before = f.events[..<recordRename]
            XCTAssertTrue(before.contains(.flush(.fsync, .projectFolder)), "\(separate)")
            XCTAssertEqual(before.contains(.flush(.full, .projectFolder)), separate)
        }
    }

    /// A flush that fails before the first rename refuses the copy, and the staging goes.
    func testAFailedFlushBeforeTheFirstRenameRefusesAndRemovesTheStaging() throws {
        f.failFlush = { kind, what in kind == .full && what == .transcript ? EIO : 0 }
        assertRefused(.fileSystem(errno: EIO))
    }

    /// A flush of the project folder that fails after the transcript's rename: the record is not
    /// put in place, and recovery finishes the copy later.
    func testAFailedFlushBetweenTheTranscriptAndTheRecordLeavesTheRecordForRecovery() throws {
        let f = self.f!
        let before = f.snapshot()
        f.separateVolumes = true
        f.failFlush = { _, what in what == .projectFolder ? EIO : 0 }
        XCTAssertEqual(f.copy(), .pendingRegistration(newSessionID: "local_\(f.y)", detail: pendingDetail))
        XCTAssertTrue(f.exists(f.copyURL))
        XCTAssertFalse(f.exists(f.recordURL))
        XCTAssertEqual(try f.journal().phase, .staged)
        f.failFlush = { _, _ in 0 }
        XCTAssertEqual(f.recover().map(\.message), [finished])
        try f.assertIsASuccessfulCopy(before: before)
    }

    // MARK: - The first journal

    /// A crash while the first journal was written leaves only its temporary file, which nothing
    /// reads: recovery says nothing about it, and copies go ahead.
    func testATornFirstJournalIsNeverRead() throws {
        let f = self.f!
        try Data(#"{"version":1,"phase":"stag"#.utf8)
            .write(to: f.journalDirectory.appendingPathComponent(".abababab-1234-4567-89ab-0123456789ab.json.partial"))
        let before = f.snapshot()
        XCTAssertEqual(f.recover(), [])
        XCTAssertEqual(f.snapshot(), before)
        guard case .copied = f.copy() else { return XCTFail("not copied") }
        try f.assertIsASuccessfulCopy(before: before)

        // Even one under the very id the next copy takes.
        let g = try CopyFixture()
        try Data(#"{"version":1,"#.utf8).write(to: g.journalDirectory.appendingPathComponent(".\(g.y).json.partial"))
        guard case .copied = g.copy() else { return XCTFail("not copied") }
        XCTAssertEqual(g.journalFiles, ["\(g.y).json"])
    }

    /// The first journal fails to reach the drive — as a crash in the middle of writing it
    /// would: nothing is under the journal's name, so nothing half-written is ever read.
    func testAFirstJournalThatFailsToReachTheDriveLeavesNoJournal() throws {
        let f = self.f!
        f.failFlush = { kind, what in kind == .full && what == .journalFile ? EIO : 0 }
        assertRefused(.fileSystem(errno: EIO))
        XCTAssertFalse(f.steps.contains(.journalCreated))
    }

    /// The switcher's own folder cannot rename exclusively (a `~/.config` linked to another
    /// kind of disk): refused as that — not as "this disk", which reads as Claude's — and
    /// nothing is left in either folder.
    func testAJournalFolderWithoutExclusiveRenameIsRefusedAsTheSwitchersOwn() throws {
        for code in [ENOTSUP, EINVAL] {
            let f = try CopyFixture()
            var environment = f.environment()
            environment.journalRenameExclusive = { _, _, _, _ in code }
            let before = f.snapshot()
            XCTAssertEqual(SessionCopy.copy(f.request(), allProfiles: f.profiles, environment: environment),
                           .refused(.journalFolderCannotRename), "\(code)")
            XCTAssertEqual(f.snapshot().ignoringDirectoryTimes, before.ignoringDirectoryTimes, f.snapshot().difference(from: before))
            XCTAssertEqual(f.journalFiles, [], "\(code)")
            XCTAssertFalse(f.steps.contains(.journalCreated), "\(code)")
        }
    }

    /// A journal already under the new id is never replaced, and nothing is staged.
    func testAJournalAlreadyUnderTheNewIdIsNeverReplaced() throws {
        let f = self.f!
        let existing = Data("{\"someone\":\"else\"}".utf8)
        try existing.write(to: f.journalURL)
        let before = f.snapshot()
        XCTAssertEqual(f.copy(), .refused(.nameTaken))
        let after = f.snapshot()
        XCTAssertEqual(after.ignoringDirectoryTimes, before.ignoringDirectoryTimes, after.difference(from: before))
        XCTAssertEqual(try Data(contentsOf: f.journalURL), existing)
        XCTAssertFalse(f.steps.contains(.journalCreated))
    }
}
