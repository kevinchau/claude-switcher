import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// Copies interrupted at every step — a step hook throws, as a crash would — and then recovered
/// by the lock holder. Recovery finishes or removes only what the journal names, proving each
/// piece first, and never removes a name Claude uses.
final class CopyRecoveryTests: XCTestCase {

    /// Every point before the transcript's rename, in order.
    private let beforeTheCommit: [SessionCopy.Step] = [
        .resolved, .preflightPassed, .idChosen, .journalCreated, .snapshotRead(attempt: 1), .scanned,
        .transcriptWritten, .transcriptStaged, .agentWritten, .subagentsStaged, .recordStaged, .journalStaged, .rechecked,
    ]
    private let afterTheCommit: [SessionCopy.Step] = [.transcriptCommitted, .directoryCommitted, .recordCommitted]

    private typealias Note = CopyRecovery.Note
    private let leftInPlace = CopyRecovery.Note.leftInPlace("Work").message
    private let cannotCheck = CopyRecovery.Note.cannotCheck("Work").message
    private let cleanedUp = CopyRecovery.Note.cleanedUp("Work").message
    private let finished = CopyRecovery.Note.finished("Work").message
    private let registeredElsewhere = CopyRecovery.Note.registeredElsewhere("Work").message
    private let journalUnreadable = CopyRecovery.Note.journalUnreadable().message

    /// What recovery removed must be this copy's staging names or its journal — never a name
    /// Claude uses, whatever the branch.
    private func assertRemovedOnlyItsOwn(_ f: CopyFixture, from crashed: TreeSnapshot, _ label: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let removed = f.snapshot().changes(since: crashed).removed
        let own = f.stagingPaths.union([f.rel(f.journalURL)])
        XCTAssertTrue(removed.isSubset(of: own), "\(label): removed \(removed.subtracting(own))", file: file, line: line)
        for kept in [f.rel(f.copyURL), f.rel(f.projectFolder.appendingPathComponent(f.y)), f.rel(f.transcriptURL)]
        where crashed.entry(kept) != nil {
            XCTAssertNotNil(f.snapshot().entry(kept), "\(label): removed \(kept)", file: file, line: line)
        }
        for path in crashed.paths where path.hasSuffix(".json") && (path as NSString).lastPathComponent.hasPrefix("local_") {
            XCTAssertNotNil(f.snapshot().entry(path), "\(label): removed \(path)", file: file, line: line)
        }
    }

    // MARK: - 17, 19. Interrupted before the transcript is in place

    func testACopyInterruptedBeforeTheCommitIsUndoneExactly() throws {
        for step in beforeTheCommit {
            let f = try CopyFixture()
            let before = f.snapshot()
            _ = f.crash(at: step)
            let crashed = f.snapshot()
            let notes = f.recover()
            let after = f.snapshot()
            XCTAssertEqual(after.ignoringDirectoryTimes, before.ignoringDirectoryTimes, "\(step)\n" + after.difference(from: before))
            XCTAssertEqual(f.journalFiles, [], "\(step)")
            assertRemovedOnlyItsOwn(f, from: crashed, "\(step)")
            let journalled = crashed.entry(f.rel(f.journalURL)) != nil
            XCTAssertEqual(notes.count, journalled ? 1 : 0, "\(step)")
        }
    }

    // MARK: - 18, 19. Interrupted after it

    func testACopyInterruptedAfterTheCommitIsCompletedToTheSameTreeAsASuccess() throws {
        for step in afterTheCommit {
            let f = try CopyFixture()
            let before = f.snapshot()
            XCTAssertEqual(f.crash(at: step), .pendingRegistration(
                newSessionID: "local_\(f.y)", detail: CopyRun.pendingDetail(target: "Work")))
            let crashed = f.snapshot()
            let notes = f.recover()
            XCTAssertEqual(notes.map(\.message), [
                "A copy to Work that had not finished has been finished; it appears in Work\u{2019}s Code tab the next time that Claude starts.",
            ], "\(step)")
            try f.assertIsASuccessfulCopy(before: before)
            assertRemovedOnlyItsOwn(f, from: crashed, "\(step)")
            // Done once is done: a second pass changes nothing.
            let settled = f.snapshot()
            XCTAssertEqual(f.recover(), [], "\(step)")
            XCTAssertEqual(f.snapshot(), settled, "\(step)")
        }
    }

    /// Recovery runs before every copy, so the next copy finishes an interrupted one first.
    func testTheNextCopyFinishesAnInterruptedOneFirst() throws {
        let f = try CopyFixture()
        _ = f.crash(at: .directoryCommitted)
        f.newID = UUID()
        _ = f.copy()
        f.newID = UUID(uuidString: "9E9E9E9E-1234-4567-89AB-0123456789AB")!
        XCTAssertTrue(f.exists(f.recordURL))
        XCTAssertEqual(try f.journal().phase, .committed)
    }

    // MARK: - 20. Another account registers the copy in the crash window

    func testACopyAnotherAccountRegisteredMeanwhileGetsNoSecondRecord() throws {
        for (step, marker) in [(SessionCopy.Step.transcriptCommitted, "local_"), (.directoryCommitted, "local_"),
                               (.transcriptCommitted, "deleted_")] {
            let f = try CopyFixture()
            _ = f.crash(at: step)
            // A third profile imports the transcript (or has registered and deleted it).
            let third = Profile(id: "third", label: "Third", userDataDir: "~/Library/Application Support/Claude-third")
            let store = try f.home.signIn(userDataDir: third.userDataDir, account: "eeeeeeee-1111-4111-8111-111111111111",
                                          org: "eeeeeeee-2222-4222-8222-222222222222")
            let adopted = store.url.appendingPathComponent(marker == "local_" ? "local_\(f.y).json" : "deleted_\(f.y)")
            try f.write("{\"imported\":true}", to: adopted)
            let crashed = f.snapshot()

            let notes = f.recover(profiles: f.profiles + [third])
            XCTAssertEqual(notes.map(\.message), [
                "A copy to Work that had not finished had meanwhile been registered by another account, so Claude Switcher did not register it again.",
            ])
            XCTAssertFalse(f.exists(f.recordURL), "no second record")
            XCTAssertFalse(f.exists(f.storeB.url.appendingPathComponent(f.names.record)), "its own record is removed")
            XCTAssertEqual(try Data(contentsOf: f.copyURL), f.expectedCopy, "the transcript stays")
            XCTAssertTrue(f.exists(f.copiedAgentURL), "the subagent folder joins it")
            XCTAssertEqual(try Data(contentsOf: adopted), Data("{\"imported\":true}".utf8))
            XCTAssertEqual(f.journalFiles, [])
            assertRemovedOnlyItsOwn(f, from: crashed, "\(step) \(marker)")
        }

        // Someone else's bytes at `local_<Y>.json` in the target store itself: a record there
        // is this copy's only if its bytes are the ones journalled. It is left alone, no
        // second record is made, and this copy's own staged record does not stay behind.
        let f = try CopyFixture()
        _ = f.crash(at: .directoryCommitted)
        let foreign = Data("{\"sessionId\":\"local_\(f.y)\",\"someoneElse\":true}".utf8)
        try foreign.write(to: f.recordURL)
        let crashed = f.snapshot()
        XCTAssertEqual(f.recover().map(\.message), [registeredElsewhere])
        XCTAssertEqual(try Data(contentsOf: f.recordURL), foreign)
        XCTAssertFalse(f.exists(f.stagedRecordURL), "its own staged record is not left in Claude's store")
        XCTAssertEqual(f.journalFiles, [])
        XCTAssertEqual(SessionCopy.pending(environment: f.environment()), [])
        assertRemovedOnlyItsOwn(f, from: crashed, "foreign record in the target store")
        let settled = f.snapshot()
        XCTAssertEqual(f.recover(), [])
        XCTAssertEqual(f.snapshot(), settled)
    }

    /// The target's Claude opened the copy — rewriting its record, as it does the first time it
    /// shows a session — before recovery marked it committed: the copy is done, and it is not
    /// "registered by another account".
    func testARecordClaudeOpenedBeforeRecoveryRanFinishesTheCopyQuietly() throws {
        func open(_ f: CopyFixture) throws -> Data {
            var text = try String(contentsOf: f.recordURL, encoding: .utf8)
            text = text.replacingOccurrences(of: "\"isArchived\":false", with: "\"isArchived\":false,\"lastFocusedAt\":1")
            try text.write(to: f.recordURL, atomically: true, encoding: .utf8)
            return Data(text.utf8)
        }
        // Every rename done, only the journal behind.
        let f = try CopyFixture()
        _ = f.crash(at: .recordCommitted)
        let opened = try open(f)
        XCTAssertEqual(f.recover(), [])
        XCTAssertEqual(try Data(contentsOf: f.recordURL), opened)
        XCTAssertTrue(f.exists(f.copiedAgentURL))
        XCTAssertEqual(f.journalFiles, [])

        // The record's rename reached the drive and the subagent folder's did not: the folder
        // still joins its transcript.
        let g = try CopyFixture()
        _ = g.crash(at: .transcriptCommitted)
        XCTAssertEqual(rename(g.stagedRecordURL.path, g.recordURL.path), 0)
        let reopened = try open(g)
        XCTAssertEqual(g.recover(), [])
        XCTAssertEqual(try Data(contentsOf: g.recordURL), reopened)
        XCTAssertTrue(g.exists(g.copiedAgentURL))
        XCTAssertFalse(g.exists(g.stagingFolderURL))
        XCTAssertEqual(g.journalFiles, [])
    }

    // MARK: - 21. Proof before every unlink

    /// Something replaced or joined what the copy staged: recovery touches nothing at all,
    /// keeps the journal and says so.
    func testRecoveryTouchesNothingItCannotProveIsItsOwn() throws {
        let interferences: [(String, (CopyFixture) throws -> Void)] = [
            ("staged transcript replaced by a link", { f in
                let staged = f.projectFolder.appendingPathComponent(f.names.transcript)
                let sentinel = f.home.root.appendingPathComponent("sentinel")
                try f.write("sentinel", to: sentinel)
                try FileManager.default.removeItem(at: staged)
                try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: sentinel)
            }),
            ("staged transcript hard-linked", { f in
                XCTAssertEqual(link(f.projectFolder.appendingPathComponent(f.names.transcript).path,
                                    f.home.root.appendingPathComponent("second-name").path), 0)
            }),
            ("staged transcript replaced by another file", { f in
                let staged = f.projectFolder.appendingPathComponent(f.names.transcript)
                try FileManager.default.removeItem(at: staged)
                try f.write("someone else's\n", to: staged)
            }),
            ("a stranger's file in the staged subagent folder", { f in
                try f.write("{}\n", to: f.projectFolder.appendingPathComponent("\(f.names.directory)/subagents/agent-zz.jsonl"))
            }),
            ("a .DS_Store in the staging folder", { f in
                try f.write("", to: f.projectFolder.appendingPathComponent("\(f.names.directory)/.DS_Store"))
            }),
            ("staged record rewritten in place", { f in
                let staged = f.storeB.url.appendingPathComponent(f.names.record)
                var bytes = try Data(contentsOf: staged)
                bytes[bytes.count - 2] = UInt8(ascii: " ")
                let handle = try FileHandle(forWritingTo: staged)
                try handle.write(contentsOf: bytes)
                try handle.close()
            }),
            ("staging folder replaced by another folder", { f in
                let staged = f.projectFolder.appendingPathComponent(f.names.directory)
                try FileManager.default.moveItem(at: staged, to: f.home.root.appendingPathComponent("elsewhere"))
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
            }),
            ("staging folder replaced by a link", { f in
                let staged = f.projectFolder.appendingPathComponent(f.names.directory)
                let elsewhere = f.home.root.appendingPathComponent("elsewhere")
                try FileManager.default.moveItem(at: staged, to: elsewhere)
                try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: elsewhere)
            }),
        ]
        for (label, interfere) in interferences {
            let f = try CopyFixture()
            _ = f.crash(at: .journalStaged)
            try interfere(f)
            let before = f.snapshot()
            let notes = f.recover()
            XCTAssertEqual(f.snapshot(), before, "\(label)\n" + f.snapshot().difference(from: before))
            XCTAssertEqual(notes.map(\.message), [
                "A copy to Work that did not finish left files Claude Switcher could not prove are still its own, so it left them in place.",
            ], label)
            XCTAssertEqual(f.journalFiles, ["\(f.y).json"], label)
        }
    }

    /// The same after the commit: what cannot be proven is not renamed, and nothing moves.
    func testRecoveryWillNotFinishWithSomethingItCannotProve() throws {
        let cases: [(String, SessionCopy.Step, (CopyFixture) throws -> Void)] = [
            ("staging folder replaced", .transcriptCommitted, { f in
                let staged = f.projectFolder.appendingPathComponent(f.names.directory)
                try FileManager.default.moveItem(at: staged, to: f.home.root.appendingPathComponent("elsewhere"))
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
            }),
            ("<Y>.jsonl replaced", .transcriptCommitted, { f in
                try FileManager.default.removeItem(at: f.copyURL)
                try f.write("{\"someone\":\"else\"}\n", to: f.copyURL)
            }),
            ("staged record rewritten in place", .directoryCommitted, { f in
                let staged = f.storeB.url.appendingPathComponent(f.names.record)
                var bytes = try Data(contentsOf: staged)
                bytes[bytes.count - 2] = UInt8(ascii: " ")
                let handle = try FileHandle(forWritingTo: staged)
                try handle.write(contentsOf: bytes)
                try handle.close()
            }),
            ("target store replaced by a new folder", .transcriptCommitted, { f in
                try FileManager.default.moveItem(at: f.storeB.url, to: f.home.root.appendingPathComponent("old-store"))
                try FileManager.default.createDirectory(at: f.storeB.url, withIntermediateDirectories: false)
            }),
            ("a store that cannot be read", .transcriptCommitted, { f in
                let stray = try f.home.makeStore(userDataDir: "~/Library/Application Support/Claude-old",
                                                 account: "eeeeeeee-1111-4111-8111-111111111111",
                                                 org: "eeeeeeee-2222-4222-8222-222222222222")
                XCTAssertEqual(chmod(stray.url.path, 0o000), 0)
            }),
            ("a store that can be listed but not searched", .transcriptCommitted, { f in
                let stray = try f.home.makeStore(userDataDir: "~/Library/Application Support/Claude-old",
                                                 account: "eeeeeeee-1111-4111-8111-111111111111",
                                                 org: "eeeeeeee-2222-4222-8222-222222222222")
                XCTAssertEqual(chmod(stray.url.path, 0o600), 0)
            }),
        ]
        for (label, step, interfere) in cases {
            let f = try CopyFixture()
            _ = f.crash(at: step)
            try interfere(f)
            let before = f.snapshot()
            XCTAssertEqual(f.recover().count, 1, label)
            XCTAssertEqual(f.snapshot(), before, "\(label)\n" + f.snapshot().difference(from: before))
            XCTAssertEqual(try f.journal().phase, .staged, label)
        }
    }

    /// A journal that names anything but this copy's own staging names is not acted on — one
    /// case per rule. Each names a real object by its real name and inode, so every proof made
    /// on the object itself would pass: only the rule stops recovery from removing it.
    func testAJournalNamingOtherFilesIsNotActedOn() throws {
        let theirSession = "55555555-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        typealias Edit = (CopyFixture, inout [String: Any]) throws -> Void
        func staged(_ body: @escaping (CopyFixture, inout [String: Any]) throws -> Void) -> Edit {
            { f, entry in
                var staged = try XCTUnwrap(entry["staged"] as? [String: Any])
                try body(f, &staged)
                entry["staged"] = staged
            }
        }
        func names(_ key: String, _ name: @escaping (CopyFixture) -> String) -> Edit {
            { f, entry in
                var names = try XCTUnwrap(entry["names"] as? [String: Any])
                names[key] = name(f)
                entry["names"] = names
            }
        }
        /// One of Work's own records, as Claude keeps it.
        func claudeRecord(_ f: CopyFixture) throws -> URL {
            try f.home.writeRecord(["sessionId": "local_33333333-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                                    "cliSessionId": "44444444-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "cwd": f.cwd], in: f.storeB)
        }
        /// Another session's folder, with a subagent transcript in it.
        func theirFolder(_ f: CopyFixture) throws -> URL {
            let folder = f.projectFolder.appendingPathComponent(theirSession)
            try f.write("{\"theirs\":1}\n", to: folder.appendingPathComponent("subagents/agent-q.jsonl"))
            return folder
        }
        func object(_ f: CopyFixture, _ url: URL) throws -> [String: Any] {
            ["name": url.lastPathComponent, "inode": try XCTUnwrap(f.inode(url))]
        }
        func theirFolderAsStaged(_ f: CopyFixture, _ staged: inout [String: Any]) throws {
            let folder = try theirFolder(f)
            staged["directory"] = try object(f, folder)
            staged["subagents"] = try object(f, folder.appendingPathComponent("subagents"))
            staged["agents"] = [try object(f, folder.appendingPathComponent("subagents/agent-q.jsonl"))]
        }

        let cases: [(String, Edit)] = [
            ("the staged transcript is the original's", staged { f, staged in
                staged["transcript"] = try object(f, f.transcriptURL)
            }),
            ("the staged record is one of Claude's", staged { f, staged in
                staged["record"] = try object(f, try claudeRecord(f))
            }),
            ("the staging folder is another session's", staged { f, staged in try theirFolderAsStaged(f, &staged) }),
            ("the staging names are not derived from Y: transcript", { f, entry in
                try names("transcript") { _ in CopyFixture.x + ".jsonl" }(f, &entry)
                try staged { f, staged in staged["transcript"] = try object(f, f.transcriptURL) }(f, &entry)
            }),
            ("the staging names are not derived from Y: folder", { f, entry in
                try names("directory") { _ in theirSession }(f, &entry)
                try staged { f, staged in try theirFolderAsStaged(f, &staged) }(f, &entry)
            }),
            ("the staging names are not derived from Y: record", { f, entry in
                let record = try claudeRecord(f)
                try names("record") { _ in record.lastPathComponent }(f, &entry)
                try staged { f, staged in staged["record"] = try object(f, record) }(f, &entry)
            }),
            ("the subagent folder is not named subagents", staged { f, staged in
                staged["subagents"] = ["name": "x", "inode": try XCTUnwrap(f.inode(f.stagingFolderURL.appendingPathComponent("subagents")))]
            }),
            ("an agent file named ../x.jsonl", staged { f, staged in
                staged["agents"] = [["name": "../x.jsonl", "inode": try XCTUnwrap(f.inode(f.stagingFolderURL.appendingPathComponent("subagents/agent-a1.jsonl")))]]
            }),
            ("an agent file named notes.txt", staged { f, staged in
                staged["agents"] = [["name": "notes.txt", "inode": try XCTUnwrap(f.inode(f.stagingFolderURL.appendingPathComponent("subagents/agent-a1.jsonl")))]]
            }),
            ("one agent file named twice", staged { _, staged in
                let agents = try XCTUnwrap(staged["agents"] as? [[String: Any]])
                staged["agents"] = agents + agents
            }),
            ("a journal of another version", { _, entry in entry["version"] = 2 }),
            ("an id in upper case in its own file", { f, entry in entry["id"] = f.y.uppercased() }),
        ]
        for (label, edit) in cases {
            let f = try CopyFixture()
            _ = f.crash(at: .journalStaged)
            try f.editJournal { try edit(f, &$0) }
            let before = f.snapshot()
            XCTAssertEqual(f.recover().map(\.message), [journalUnreadable], label)
            XCTAssertEqual(f.snapshot(), before, "\(label)\n" + f.snapshot().difference(from: before))
            XCTAssertEqual(f.journalFiles, ["\(f.y).json"], label)
        }

        // A journal file whose entry is another copy's: what it says is not this file's to act on.
        let f = try CopyFixture()
        _ = f.crash(at: .journalStaged)
        let other = f.journalDirectory.appendingPathComponent("abababab-1234-4567-89ab-0123456789ab.json")
        XCTAssertEqual(rename(f.journalURL.path, other.path), 0)
        let before = f.snapshot()
        XCTAssertEqual(f.recover().map(\.message), [journalUnreadable])
        XCTAssertEqual(f.snapshot(), before, f.snapshot().difference(from: before))

        // A file whose name is not a lower-case id is not a journal at all.
        let g = try CopyFixture()
        _ = g.crash(at: .journalStaged)
        XCTAssertEqual(rename(g.journalURL.path, g.journalDirectory.appendingPathComponent(g.y.uppercased() + ".json").path), 0)
        let renamed = g.snapshot()
        XCTAssertEqual(g.recover(), [])
        XCTAssertEqual(g.snapshot(), renamed)
    }

    /// The rules on the id itself, which the journal's file name already enforces on the way
    /// in, hold for an entry on its own too: an id that is not a lower-case UUID is not acted on
    /// even with staging names derived from it.
    func testAJournalEntryIsWellFormedOnlyWithALowerCaseUUID() throws {
        let f = try CopyFixture()
        _ = f.crash(at: .journalStaged)
        let entry = try f.journal()
        XCTAssertTrue(entry.isWellFormed)
        for id in [f.y.uppercased(), "not-a-uuid", "../" + f.y] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CopyJournal.encode(entry)) as? [String: Any])
            object["id"] = id
            object["names"] = ["transcript": StagingNames(id: id).transcript, "directory": StagingNames(id: id).directory,
                               "record": StagingNames(id: id).record]
            var staged = try XCTUnwrap(object["staged"] as? [String: Any])
            for key in ["transcript", "directory", "record"] {
                var item = try XCTUnwrap(staged[key] as? [String: Any])
                item["name"] = (object["names"] as! [String: String])[key]
                staged[key] = item
            }
            object["staged"] = staged
            let changed = try JSONDecoder().decode(JournalEntry.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertFalse(changed.isWellFormed, id)
        }
    }

    // MARK: - 14d. A crash between a create and its journal entry

    /// An exclusive create succeeded and the crash came before its journal entry: the object is
    /// this copy's, but nothing can prove it. Recovery touches nothing, keeps the journal and
    /// says so; once the name is free again, it cleans up as usual.
    func testAnObjectCreatedButNotYetJournalledIsNeitherRemovedNorForgotten() throws {
        let cases: [(String, SessionCopy.Step, (CopyFixture) -> URL, Bool)] = [
            ("staged transcript", .journalCreated, { $0.stagedTranscriptURL }, false),
            ("staging folder", .transcriptStaged, { $0.stagingFolderURL }, true),
            ("staged record", .subagentsStaged, { $0.stagedRecordURL }, false),
        ]
        for (label, step, place, isFolder) in cases {
            // Nothing there: the clean-up is the usual one.
            let clean = try CopyFixture()
            let start = clean.snapshot()
            _ = clean.crash(at: step)
            XCTAssertEqual(clean.recover().map(\.message), [cleanedUp], label)
            XCTAssertEqual(clean.snapshot().ignoringDirectoryTimes, start.ignoringDirectoryTimes, label)
            XCTAssertEqual(clean.journalFiles, [], label)

            let f = try CopyFixture()
            let before = f.snapshot()
            _ = f.crash(at: step)
            // What the create made, as it made it.
            let url = place(f)
            if isFolder {
                XCTAssertEqual(mkdir(url.path, 0o700), 0, label)
            } else {
                XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]), label)
            }
            let crashed = f.snapshot()
            XCTAssertEqual(f.recover().map(\.message), [leftInPlace], label)
            XCTAssertEqual(f.snapshot(), crashed, "\(label)\n" + f.snapshot().difference(from: crashed))
            XCTAssertEqual(f.journalFiles, ["\(f.y).json"], label)

            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(f.recover().map(\.message), [cleanedUp], label)
            XCTAssertEqual(f.snapshot().ignoringDirectoryTimes, before.ignoringDirectoryTimes, label)
            XCTAssertEqual(f.journalFiles, [], label)
        }
    }

    /// The same, reached for real: the crash comes right after the staging folder is made.
    func testACrashRightAfterTheStagingFolderIsMadeLeavesItAndItsJournal() throws {
        let f = try CopyFixture()
        let before = f.snapshot()
        _ = f.crash(at: .stagingFolderCreated)
        XCTAssertEqual(try f.journal().staged.directory, nil, "not journalled yet")
        let crashed = f.snapshot()
        XCTAssertNotNil(crashed.entry(f.rel(f.stagingFolderURL)))
        XCTAssertEqual(f.recover().map(\.message), [leftInPlace])
        XCTAssertEqual(f.snapshot(), crashed)
        XCTAssertEqual(f.journalFiles, ["\(f.y).json"])

        XCTAssertEqual(rmdir(f.stagingFolderURL.path), 0)
        XCTAssertEqual(f.recover().map(\.message), [cleanedUp])
        XCTAssertEqual(f.snapshot().ignoringDirectoryTimes, before.ignoringDirectoryTimes)
    }

    /// The same crash, and the folder the unjournalled object is in cannot be held for writing
    /// (others can write to it): recovery cannot look for the object there, so it neither
    /// removes anything nor forgets the journal. Closed again, it finds the object and leaves
    /// it; once the object is gone, it cleans up.
    func testAnUnjournalledObjectInAFolderThatCannotBeHeldIsNotForgotten() throws {
        let cases: [(String, SessionCopy.Step, (CopyFixture) -> URL, (CopyFixture) -> URL)] = [
            ("staged record, the store 0775", .subagentsStaged, { $0.stagedRecordURL }, { $0.storeB.url }),
            ("staged transcript, the project folder 0775", .journalCreated, { $0.stagedTranscriptURL }, { $0.projectFolder }),
        ]
        for (label, step, object, folder) in cases {
            let f = try CopyFixture()
            let before = f.snapshot()
            _ = f.crash(at: step)
            let url = object(f)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]), label)
            let original = try XCTUnwrap(f.snapshot().entry(f.rel(folder(f)))).mode
            XCTAssertEqual(chmod(folder(f).path, 0o775), 0, label)
            let crashed = f.snapshot()
            let notes = f.recover()
            XCTAssertEqual(notes.map(\.message), [cannotCheck], label)
            XCTAssertEqual(notes.map(\.needsAttention), [true], label)
            XCTAssertEqual(f.snapshot(), crashed, "\(label)\n" + f.snapshot().difference(from: crashed))
            XCTAssertEqual(f.journalFiles, ["\(f.y).json"], label)

            XCTAssertEqual(chmod(folder(f).path, mode_t(original)), 0, label)
            let closed = f.snapshot()
            XCTAssertEqual(f.recover().map(\.message), [leftInPlace], label)
            XCTAssertEqual(f.snapshot(), closed, "\(label)\n" + f.snapshot().difference(from: closed))
            XCTAssertEqual(f.journalFiles, ["\(f.y).json"], label)

            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(f.recover().map(\.message), [cleanedUp], label)
            XCTAssertEqual(f.journalFiles, [], label)
            XCTAssertEqual(f.snapshot().ignoringDirectoryTimes, before.ignoringDirectoryTimes, label)
        }
    }

    /// A journal whose folder is spelled through a link outside the home directory that leads
    /// back below it is not acted on: the walk refuses it as it refuses a link below home.
    func testAJournalFolderSpelledThroughALinkOutsideHomeIsNotActedOn() throws {
        let f = try CopyFixture()
        _ = f.crash(at: .transcriptCommitted)
        let library = f.home.root.appendingPathComponent("Library")
        let outside = f.home.root.deletingLastPathComponent().appendingPathComponent("outside-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: library)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertTrue(f.storeB.url.path.hasPrefix(library.path + "/"))
        let spelled = outside.path + f.storeB.url.path.dropFirst(library.path.count)
        try f.editJournal { journal in
            var store = try XCTUnwrap(journal["targetStore"] as? [String: Any])
            store["path"] = spelled
            journal["targetStore"] = store
        }
        let crashed = f.snapshot()
        XCTAssertEqual(f.recover().map(\.message), [cannotCheck])
        XCTAssertEqual(f.snapshot(), crashed, f.snapshot().difference(from: crashed))
        XCTAssertEqual(try f.journal().phase, .staged)
        XCTAssertFalse(f.exists(f.recordURL))
    }

    /// The project folder's flush before the record's rename fails: the record is not put in
    /// place (its rename could otherwise reach the drive before the transcript's), recovery says
    /// it could not check, and it finishes the copy once flushing works again.
    func testRecoveryWhoseFlushBeforeTheRecordFailsRenamesNothing() throws {
        for separate in [false, true] {
            let label = separate ? "two volumes" : "one volume"
            let f = try CopyFixture()
            f.separateVolumes = separate
            let before = f.snapshot()
            _ = f.crash(at: .directoryCommitted)
            f.failFlush = { kind, what in what == .projectFolder && kind == (separate ? .full : .fsync) ? EIO : 0 }
            f.events = []
            let crashed = f.snapshot()
            XCTAssertEqual(f.recover().map(\.message), [cannotCheck], label)
            XCTAssertTrue(f.events.contains(.flush(separate ? .full : .fsync, .projectFolder)), label)
            XCTAssertFalse(f.events.contains { if case .renamed = $0 { return true }; return false }, "\(label): \(f.events)")
            XCTAssertEqual(f.snapshot(), crashed, "\(label)\n" + f.snapshot().difference(from: crashed))
            XCTAssertTrue(f.exists(f.stagedRecordURL), label)
            XCTAssertEqual(try f.journal().phase, .staged, label)

            f.failFlush = { _, _ in 0 }
            XCTAssertEqual(f.recover().map(\.message), [finished], label)
            try f.assertIsASuccessfulCopy(before: before)
        }
    }

    // MARK: - What is left unfinished, read without acting

    /// Copies whose journal is kept and not committed are listed — by account and state, with
    /// no path, id or title — without touching anything, without the gate (a copy can be
    /// running), and not once recovery has finished them. A journal it cannot read is listed
    /// as that.
    func testUnfinishedCopiesAreListedWithoutActingOnThem() throws {
        let f = try CopyFixture()
        XCTAssertEqual(SessionCopy.unfinished(environment: f.environment()), [])
        _ = f.crash(at: .recordStaged)
        let crashed = f.snapshot()
        let staging = SessionCopy.unfinished(environment: f.environment())
        XCTAssertEqual(staging.map(\.state), [.staging])
        XCTAssertEqual(staging.map(\.targetLabel), ["Work"])
        XCTAssertNotNil(staging.first?.since)
        XCTAssertEqual(f.snapshot(), crashed, "read-only")

        let g = try CopyFixture()
        _ = g.crash(at: .transcriptCommitted)
        XCTAssertEqual(SessionCopy.unfinished(environment: g.environment()).map(\.state), [.staged])
        g.recover()
        XCTAssertEqual(SessionCopy.unfinished(environment: g.environment()), [], "finished and committed")
        try Data("{".utf8).write(to: g.journalDirectory.appendingPathComponent("abababab-1234-4567-89ab-0123456789ab.json"))
        let unreadable = SessionCopy.unfinished(environment: g.environment())
        XCTAssertEqual(unreadable.map(\.state), [.unreadable])
        XCTAssertEqual(unreadable.map(\.targetLabel), [nil])

        // While a copy runs: no wait for the gate, and the running copy's own journal listed.
        let h = try CopyFixture()
        var during: [SessionCopy.Unfinished]?
        h.hook = { [unowned h] step in
            if step == .transcriptStaged { during = SessionCopy.unfinished(environment: h.environment()) }
        }
        guard case .copied = h.copy() else { return XCTFail("not copied") }
        XCTAssertEqual(during?.map(\.state), [.staging])
        XCTAssertEqual(SessionCopy.unfinished(environment: h.environment()), [])
    }

    /// Each note says which copy it is about and whether something is still left to do.
    func testEachNoteNamesItsCopyAndWhetherItNeedsAttention() throws {
        let f = try CopyFixture()
        _ = f.crash(at: .transcriptCommitted)
        try f.setWorkSignedIn(false)
        let waiting = f.recover()
        XCTAssertEqual(waiting.map(\.kind), [.waiting])
        XCTAssertEqual(waiting.map(\.copyID), ["local_\(f.y)"])
        XCTAssertEqual(waiting.map(\.needsAttention), [true])
        try f.setWorkSignedIn(true)
        let done = f.recover()
        XCTAssertEqual(done.map(\.kind), [.finished])
        XCTAssertEqual(done.map(\.copyID), ["local_\(f.y)"])
        XCTAssertEqual(done.map(\.needsAttention), [false])
    }

    // MARK: - Recovery writes only into folders nobody else can write to

    func testRecoveryDoesNotWriteIntoAFolderOthersCanWriteTo() throws {
        let cases: [(String, SessionCopy.Step, (CopyFixture) -> URL, mode_t)] = [
            ("project folder 0777", .transcriptCommitted, { $0.projectFolder }, 0o777),
            ("project folder 0775", .transcriptCommitted, { $0.projectFolder }, 0o775),
            ("target store 0757", .transcriptCommitted, { $0.storeB.url }, 0o757),
            ("project folder 0777, before the commit", .journalStaged, { $0.projectFolder }, 0o777),
        ]
        for (label, step, folder, mode) in cases {
            let f = try CopyFixture()
            let before = f.snapshot()
            _ = f.crash(at: step)
            let url = folder(f)
            let original = try XCTUnwrap(f.snapshot().entry(f.rel(url))).mode
            XCTAssertEqual(chmod(url.path, mode), 0)
            let crashed = f.snapshot()
            XCTAssertEqual(f.recover().map(\.message), [cannotCheck], label)
            XCTAssertEqual(f.snapshot(), crashed, "\(label)\n" + f.snapshot().difference(from: crashed))
            XCTAssertEqual(try f.journal().phase, .staged, label)

            // Closed again, recovery goes ahead.
            XCTAssertEqual(chmod(url.path, mode_t(original)), 0)
            XCTAssertEqual(f.recover().count, 1, label)
            if step == .transcriptCommitted {
                try f.assertIsASuccessfulCopy(before: before)
            } else {
                XCTAssertEqual(f.snapshot().ignoringDirectoryTimes, before.ignoringDirectoryTimes, label)
                XCTAssertEqual(f.journalFiles, [], label)
            }
        }
    }

    // MARK: - Recovery's renames are exclusive too

    /// An empty folder appeared at `<Y>`: a plain rename would silently replace it.
    func testRecoveryNeverRenamesOverAnEmptyFolderAtY() throws {
        let f = try CopyFixture()
        _ = f.crash(at: .transcriptCommitted)
        let planted = f.projectFolder.appendingPathComponent(f.y)
        try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: false)
        let inode = f.inode(planted)
        XCTAssertEqual(f.recover().map(\.message), [leftInPlace])
        XCTAssertEqual(f.inode(planted), inode)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: planted.path), [])
        XCTAssertTrue(f.exists(f.stagingFolderURL), "the staging folder stays under its own name")
        XCTAssertFalse(f.exists(f.recordURL))
        XCTAssertEqual(try f.journal().phase, .staged)
    }

    /// A volume without `RENAME_EXCL`: recovery moves nothing, and tries each rename once.
    func testRecoveryOnAVolumeWithoutExclusiveRenameMovesNothing() throws {
        for code in [ENOTSUP, EINVAL] {
            for step in [SessionCopy.Step.transcriptCommitted, .directoryCommitted] {
                let f = try CopyFixture()
                _ = f.crash(at: step)
                let tried = Names()
                f.renameExclusive = { _, from, _, _ in tried.append(from); return code }
                let before = f.snapshot()
                XCTAssertEqual(f.recover().map(\.message), [leftInPlace], "\(step) \(code)")
                XCTAssertEqual(f.snapshot(), before, "\(step) \(code)\n" + f.snapshot().difference(from: before))
                XCTAssertEqual(try f.journal().phase, .staged, "\(step) \(code)")
                XCTAssertEqual(tried.values, [step == .transcriptCommitted ? f.names.directory : f.names.record], "\(step) \(code)")
            }
        }
    }

    // MARK: - The last look before each removal

    /// `unlinkat` and `rmdir` are each preceded by one more look at the name, so the object
    /// removed is the one proven a moment before — not another put in its place.
    func testTheLastLookBeforeEachRemovalRefusesAnotherObject() throws {
        let home = try FakeHome()
        let folder = URL(fileURLWithPath: try home.makeDirectory("d"))
        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
        try Data("theirs".utf8).write(to: url("f"))
        try Data("linked".utf8).write(to: url("linked"))
        XCTAssertEqual(link(url("linked").path, home.root.appendingPathComponent("second-name").path), 0)
        try FileManager.default.createSymbolicLink(at: url("link"), withDestinationURL: url("f"))
        try FileManager.default.createDirectory(at: url("sub"), withIntermediateDirectories: false)
        let held = try HeldDirectory.walk(to: folder.path, home: home.home, expectedOwner: getuid())
        func inode(_ name: String) throws -> UInt64 {
            var info = stat()
            XCTAssertEqual(lstat(url(name).path, &info), 0)
            return UInt64(info.st_ino)
        }
        let me = getuid()
        let before = home.snapshot()

        XCTAssertThrowsError(try StagingCleanup.unlink(StagedObject(name: "f", inode: try inode("f") + 1), in: held, owner: me), "another inode")
        XCTAssertThrowsError(try StagingCleanup.unlink(StagedObject(name: "f", inode: try inode("f")), in: held, owner: me + 1), "another owner")
        XCTAssertThrowsError(try StagingCleanup.unlink(StagedObject(name: "linked", inode: try inode("linked")), in: held, owner: me), "two names")
        XCTAssertThrowsError(try StagingCleanup.unlink(StagedObject(name: "link", inode: try inode("link")), in: held, owner: me), "a link")
        XCTAssertThrowsError(try StagingCleanup.removeDirectory("sub", inode: try inode("sub") + 1, in: held), "another folder")
        XCTAssertThrowsError(try StagingCleanup.removeDirectory("f", inode: try inode("f"), in: held), "a file")
        XCTAssertEqual(home.snapshot(), before)

        XCTAssertNoThrow(try StagingCleanup.unlink(StagedObject(name: "f", inode: try inode("f")), in: held, owner: me))
        XCTAssertNoThrow(try StagingCleanup.removeDirectory("sub", inode: try inode("sub"), in: held))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("f").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("sub").path))
    }

    /// The bytes hashed are the very file proven: one swapped in between the look at the name
    /// and the open — same bytes, another inode — is not ours.
    func testARecordIsProvenByTheFileOpenedNotByTheNameLookedAt() throws {
        let home = try FakeHome()
        let folder = URL(fileURLWithPath: try home.makeDirectory("store"))
        let bytes = Data("{\"sessionId\":\"x\"}".utf8)
        let staged = folder.appendingPathComponent("staged")
        try bytes.write(to: staged)
        let held = try HeldDirectory.walk(to: folder.path, home: home.home, expectedOwner: getuid())
        var info = stat()
        XCTAssertEqual(lstat(staged.path, &info), 0)
        let object = StagedObject(name: "staged", inode: UInt64(info.st_ino))
        let hash = StagingCleanup.sha256(bytes)
        XCTAssertEqual(StagingCleanup.proveFile(object, in: held, owner: getuid(), sha256: hash), .ours)
        XCTAssertEqual(StagingCleanup.proveFile(object, in: held, owner: getuid(), sha256: StagingCleanup.sha256(Data("x".utf8))), .notOurs)

        // Another file with the same bytes, put at the name after it was looked at.
        let proof = StagingCleanup.proveFile(object, in: held, owner: getuid(), sha256: hash, afterLooking: {
            let fresh = folder.appendingPathComponent("fresh")
            try? bytes.write(to: fresh)
            XCTAssertEqual(rename(fresh.path, staged.path), 0)
        })
        XCTAssertEqual(proof, .notOurs)
        // A file with the same bytes and another inode, from the start.
        var now = stat()
        XCTAssertEqual(lstat(staged.path, &now), 0)
        XCTAssertNotEqual(UInt64(now.st_ino), object.inode)
        XCTAssertEqual(StagingCleanup.proveFile(object, in: held, owner: getuid(), sha256: hash), .notOurs)
    }

    // MARK: - 22. Profiles removed or re-added; the lock

    func testRecoveryWorksByPathAndInodeWhateverTheProfilesAreNow() throws {
        let renamed = Profile(id: "work-again", label: "Work again", userDataDir: CopyFixture.work.userDataDir)
        for profiles in [[CopyFixture.personal], [CopyFixture.personal, renamed], []] {
            let finished = try CopyFixture()
            let before = finished.snapshot()
            _ = finished.crash(at: .transcriptCommitted)
            XCTAssertEqual(finished.recover(profiles: profiles).count, 1)
            try finished.assertIsASuccessfulCopy(before: before)

            let cleaned = try CopyFixture()
            let start = cleaned.snapshot()
            _ = cleaned.crash(at: .recordStaged)
            XCTAssertEqual(cleaned.recover(profiles: profiles).count, 1)
            XCTAssertEqual(cleaned.snapshot().ignoringDirectoryTimes, start.ignoringDirectoryTimes)
        }
    }

    func testRecoveryWithoutTheLockDoesNothing() throws {
        for step in [SessionCopy.Step.recordStaged, .transcriptCommitted] {
            let f = try CopyFixture()
            _ = f.crash(at: step)
            let crashed = f.snapshot()
            f.holdsLock = false
            XCTAssertEqual(f.recover(), [])
            XCTAssertEqual(f.snapshot(), crashed)
        }
    }

    /// The target signed out before recovery: the copy stays on disk, unregistered, until it
    /// is signed back in.
    func testATargetThatNoLongerQualifiesKeepsTheCopyWaiting() throws {
        let f = try CopyFixture()
        let before = f.snapshot()
        _ = f.crash(at: .transcriptCommitted)
        try f.setWorkSignedIn(false)
        XCTAssertEqual(f.recover().map(\.message), [
            "A copy to Work is on disk but was not registered, because Work is no longer signed in to the account it was copied for; Claude Switcher will try again at its next start.",
        ])
        XCTAssertFalse(f.exists(f.recordURL))
        XCTAssertTrue(f.exists(f.copyURL))
        try f.setWorkSignedIn(true)
        let config = f.rel(f.home.userDataDir(f.work.userDataDir).appendingPathComponent("config.json"))
        XCTAssertEqual(f.recover().count, 1)
        try f.assertIsASuccessfulCopy(before: before, excluding: config)
    }

    /// Work signed in to another account, with a store of its own, while the account the copy
    /// was made for still has its folder: the record goes into neither.
    func testRecoveryFilesNoRecordIntoAStoreTheTargetNoLongerLoads() throws {
        let f = try CopyFixture()
        let before = f.snapshot()
        _ = f.crash(at: .transcriptCommitted)
        let storeC = try f.home.signIn(userDataDir: f.work.userDataDir, account: "cccccccc-1111-4111-8111-111111111111",
                                       org: "cccccccc-2222-4222-8222-222222222222")
        XCTAssertEqual(f.recover().map(\.message), [CopyRecovery.Note.targetChanged("Work").message])
        XCTAssertFalse(f.exists(f.recordURL))
        XCTAssertFalse(f.exists(storeC.url.appendingPathComponent("local_\(f.y).json")))
        XCTAssertTrue(f.exists(f.stagedRecordURL))
        XCTAssertEqual(try f.journal().phase, .staged)

        try f.setWorkSignedIn(true)
        XCTAssertEqual(f.recover().map(\.message), [finished])
        let config = f.rel(f.home.userDataDir(f.work.userDataDir).appendingPathComponent("config.json"))
        try f.assertIsASuccessfulCopy(before: before, excluding: config, f.rel(storeC.url.deletingLastPathComponent()))
    }

    /// The record's rename reached the drive and the transcript's did not (two volumes, a power
    /// cut between them): the session is registered, so nothing it may need is removed.
    func testARecordInPlaceWithItsTranscriptStillStagedIsLeftAlone() throws {
        let f = try CopyFixture()
        _ = f.crash(at: .rechecked)
        XCTAssertEqual(rename(f.stagedRecordURL.path, f.recordURL.path), 0)
        let crashed = f.snapshot()
        XCTAssertEqual(f.recover().map(\.message), [cannotCheck])
        XCTAssertEqual(f.snapshot(), crashed, f.snapshot().difference(from: crashed))
        XCTAssertTrue(f.exists(f.stagedTranscriptURL))
        XCTAssertEqual(try f.journal().phase, .staged)
    }

    /// A target that is not under Application Support and is no longer configured: the store
    /// the journal names is surveyed all the same, so the record already filed there is found.
    func testRecoveryFindsARecordAlreadyFiledInATargetNoLongerConfigured() throws {
        let f = try CopyFixture()
        let third = Profile(id: "third", label: "Third", userDataDir: "~/Profiles/third")
        let store = try f.home.signIn(userDataDir: third.userDataDir, account: "cccccccc-1111-4111-8111-111111111111",
                                      org: "cccccccc-2222-4222-8222-222222222222")
        f.hook = { if $0 == .recordCommitted { throw SimulatedCrash() } }
        _ = f.copy(f.request(to: third), profiles: f.profiles + [third])
        f.hook = { _ in }
        XCTAssertTrue(f.exists(store.url.appendingPathComponent("local_\(f.y).json")))
        XCTAssertEqual(f.recover(profiles: [f.personal]).map(\.message), [CopyRecovery.Note.finished("Third").message])
        XCTAssertEqual(try f.journal().phase, .committed)
        XCTAssertEqual(SessionCopy.pending(environment: f.environment()).map(\.id), ["local_\(f.y)"])
    }

    // MARK: - 23. The "copied, not yet opened" line

    func testACommittedCopyIsPendingUntilClaudeOpensIt() throws {
        let f = try CopyFixture()
        XCTAssertEqual(SessionCopy.pending(environment: f.environment()), [])
        guard case .copied = f.copy() else { return XCTFail("not copied") }
        let pending = SessionCopy.pending(environment: f.environment())
        XCTAssertEqual(pending.map(\.id), ["local_\(f.y)"])
        XCTAssertEqual(pending.first?.title, "Fix the build (copy)")
        XCTAssertEqual(pending.first?.targetStore.path, f.storeB.url.path)
        XCTAssertEqual(pending.first?.copiedAt, f.now)
        XCTAssertEqual(f.recover(), [])
        XCTAssertEqual(f.journalFiles, ["\(f.y).json"], "kept while the record is as written")

        // Claude opens it and rewrites the record: the line goes, and recovery forgets the copy.
        try f.write("{\"sessionId\":\"local_\(f.y)\",\"rewritten\":true}", to: f.recordURL)
        XCTAssertEqual(SessionCopy.pending(environment: f.environment()), [])
        XCTAssertEqual(f.journalFiles, ["\(f.y).json"], "listing is read-only")
        XCTAssertEqual(f.recover(), [])
        XCTAssertEqual(f.journalFiles, [])
    }

    func testACommittedCopyWhoseRecordIsGoneIsForgotten() throws {
        let f = try CopyFixture()
        guard case .copied = f.copy() else { return XCTFail("not copied") }
        try FileManager.default.removeItem(at: f.recordURL)
        XCTAssertEqual(SessionCopy.pending(environment: f.environment()), [])
        f.recover()
        XCTAssertEqual(f.journalFiles, [])
        XCTAssertTrue(f.exists(f.copyURL), "forgetting the copy removes nothing of it")
    }

    func testAnInterruptedCopyIsNotPending() throws {
        let f = try CopyFixture()
        _ = f.crash(at: .recordCommitted)
        XCTAssertEqual(SessionCopy.pending(environment: f.environment()), [])
        f.recover()
        XCTAssertEqual(SessionCopy.pending(environment: f.environment()).map(\.id), ["local_\(f.y)"])
    }

    // MARK: - The journal

    /// Written before the first staged byte, and each staged object recorded as it is created.
    func testTheJournalRecordsEachObjectAsItIsCreated() throws {
        let f = try CopyFixture()
        var seen: [SessionCopy.Step: JournalEntry] = [:]
        f.hook = { [unowned f] step in
            if FileManager.default.fileExists(atPath: f.journalURL.path) { seen[step] = try f.journal() }
        }
        guard case .copied = f.copy() else { return XCTFail("not copied") }
        XCTAssertNil(seen[.idChosen])
        XCTAssertEqual(seen[.journalCreated]?.phase, .staging)
        XCTAssertEqual(seen[.journalCreated]?.staged, StagedObjects())
        XCTAssertNotNil(seen[.transcriptStaged]?.staged.transcript)
        XCTAssertEqual(seen[.subagentsStaged]?.staged.agents.map(\.name), ["agent-a1.jsonl"])
        XCTAssertNotNil(seen[.recordStaged]?.staged.record)
        XCTAssertEqual(seen[.journalStaged]?.phase, .staged)
        XCTAssertNotNil(seen[.journalStaged]?.staged.record?.sha256)
        let entry = try f.journal()
        XCTAssertEqual(entry.projectFolder.path, f.projectFolder.path)
        XCTAssertEqual(entry.targetStore.path, f.storeB.url.path)
        XCTAssertEqual(entry.sourceLabel, "Personal")
        XCTAssertEqual(entry.targetLabel, "Work")
        XCTAssertEqual(f.snapshot().entry(f.rel(f.journalURL))?.mode, 0o600)
    }

    /// The journal lives next to the app's own config, in the switcher's folder — never in
    /// Claude's — and the live seams hold no lock until the app says so.
    func testTheLiveJournalIsInTheSwitchersOwnFolder() {
        let live = SessionCopy.Environment.live
        XCTAssertEqual(live.journalDirectory.path,
                       Config.configURL.deletingLastPathComponent().appendingPathComponent("copies").path)
        XCTAssertTrue(live.journalDirectory.path.hasSuffix("/.config/claude-switcher/copies"))
        XCTAssertFalse(live.holdsAutomationLock)
    }

    func testEveryRecoveryNoteIsOnePlainSentenceWithoutIdsOrPaths() {
        typealias Note = CopyRecovery.Note
        let notes = [
            Note.cleanedUp("Work"), Note.finished("Work"), Note.registeredElsewhere("Work"), Note.targetChanged("Work"),
            Note.leftInPlace("Work"), Note.cannotCheck("Work"), Note.journalUnreadable(),
        ]
        for note in notes {
            XCTAssertTrue(note.message.hasSuffix("."), note.message)
            XCTAssertFalse(note.message.contains("/"), note.message)
            XCTAssertNil(note.message.range(of: "[0-9a-f]{8}-", options: .regularExpression), note.message)
        }
    }
}
