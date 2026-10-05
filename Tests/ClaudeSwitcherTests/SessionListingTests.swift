import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// What the menu lists for an account, and why a listed session cannot be copied. All under a
/// temporary home; nothing is written by any of it.
final class SessionListingTests: XCTestCase {

    private var home: FakeHome!
    private var storeA: SessionStoreFolder!
    private var storeB: SessionStoreFolder!
    private let personal = Profile(id: "default", label: "Personal")
    private let work = Profile(id: "work", label: "Work", userDataDir: "~/Library/Application Support/Claude-work")
    private var profiles: [Profile] { [personal, work] }
    private var appFolder: String!

    override func setUpWithError() throws {
        home = try FakeHome()
        storeA = try home.signIn(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        storeB = try home.signIn(userDataDir: work.userDataDir, account: FakeHome.accountB, org: FakeHome.orgB)
        appFolder = try home.makeDirectory("work/app")
    }

    override func tearDown() { home = nil }

    private func uuid(_ n: Int) -> String { String(format: "%08x-aaaa-4aaa-8aaa-aaaaaaaaaaaa", n) }
    private func cli(_ n: Int) -> String { String(format: "%08x-cccc-4ccc-8ccc-cccccccccccc", n) }

    /// A session in account A: its record, and — unless `transcript` is nil — its transcript.
    @discardableResult
    private func session(_ n: Int, cwd: String? = nil, extra: [String: Any] = [:],
                         transcript: [String]? = ["{\"type\":\"user\"}"], in store: SessionStoreFolder? = nil) throws -> SessionRecord {
        let folder = cwd ?? appFolder!
        var fields: [String: Any] = ["sessionId": "local_\(uuid(n))", "cliSessionId": cli(n), "cwd": folder,
                                     "originCwd": folder, "title": "Session \(n)", "lastActivityAt": 1_000_000 + n]
        for (key, value) in extra { fields[key] = value }
        try home.writeRecord(fields, in: store ?? storeA)
        if let transcript { try home.writeTranscript(cwd: folder, cliSessionId: cli(n), lines: transcript) }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try XCTUnwrap(SessionStore.record(from: data, fileStem: "local_\(uuid(n))"))
    }

    private func listing(_ environment: SessionCopy.Environment? = nil) -> SessionListing {
        SessionListing.read(profile: personal, allProfiles: profiles, environment: environment ?? home.environment())
    }

    private func listed(_ n: Int, _ environment: SessionCopy.Environment? = nil) -> ListedSession? {
        listing(environment).sessions.first { $0.id == "local_\(uuid(n))" }
    }

    private func projectFolder(_ cwd: String? = nil) -> URL {
        TranscriptLocator.projectsDirectory(home: home.home).appendingPathComponent(TranscriptLocator.projectSlug(forCwd: cwd ?? appFolder))
    }

    // MARK: - What is listed

    func testOnlyLocalUnarchivedSessionsWithATranscriptAreListedAndTheRestAreCounted() throws {
        try session(1)
        try session(2, transcript: ["{\"type\":\"user\"}", "{\"type\":\"assistant\"}"])
        try session(3, extra: ["isArchived": true])
        try session(4, extra: ["sshConfig": ["host": "box"]])
        try session(5, extra: ["cliSessionId": NSNull()], transcript: nil)
        try session(6, transcript: nil)
        try session(7, transcript: nil)
        try FileManager.default.createDirectory(at: projectFolder(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: home.root.appendingPathComponent("elsewhere.jsonl"))
        try FileManager.default.createSymbolicLink(at: projectFolder().appendingPathComponent(cli(7) + ".jsonl"),
                                                   withDestinationURL: home.root.appendingPathComponent("elsewhere.jsonl"))

        let result = listing()
        XCTAssertEqual(result.location, .folder(storeA))
        XCTAssertEqual(result.sessions.map(\.id), ["local_\(uuid(2))", "local_\(uuid(1))"])
        XCTAssertEqual(result.sessions.map(\.transcriptBytes), [37, 16])
        XCTAssertEqual(result.sessions.map(\.obstacle), [nil, nil])
        XCTAssertEqual(result.sessions.map(\.isRunning), [false, false])
        XCTAssertEqual(result.hidden, .init(archived: 1, withoutTranscript: 3, remote: 1))
        XCTAssertEqual(result.hidden.total, 5)
    }

    func testAProfileWithoutItsOwnStoreListsNothing() throws {
        try FileManager.default.removeItem(at: storeA.url.deletingLastPathComponent())
        try home.makeStore(userDataDir: nil, account: FakeHome.accountB, org: FakeHome.orgB)
        let result = listing()
        XCTAssertEqual(result.location, .otherAccountOnly)
        XCTAssertEqual(result.sessions, [])
    }

    /// Reading the lists of both accounts, the registry and every obstacle leaves every entry
    /// under the home exactly as it was — times, modes, inodes and contents.
    func testListingChangesNothingOnDisk() throws {
        try session(1)
        try session(2, extra: ["isArchived": true])
        try session(3, in: storeB)
        try home.writeRegistry(pid: 77, ["sessionId": cli(1), "status": "busy"])
        let before = home.snapshot()

        let a = listing()
        _ = SessionListing.read(profile: work, allProfiles: profiles, environment: home.environment())
        for listed in a.sessions {
            _ = SessionCopy.obstacle(for: listed, from: personal, to: work, allProfiles: profiles, environment: home.environment())
        }

        XCTAssertEqual(home.snapshot(), before, home.snapshot().difference(from: before))
    }

    /// Sessions in a hundred projects list within the 256 descriptors launchd gives a GUI app:
    /// the listing holds one project folder at a time, and none when it is done.
    func testAListingOfManyProjectsHoldsOneProjectFolderAtATime() throws {
        for n in 1...100 {
            try session(n, cwd: try home.makeDirectory("src/p\(n)"))
        }
        let opened = openDescriptors()
        let result = try withDescriptorHeadroom(32) { listing() }
        XCTAssertEqual(result.sessions.count, 100)
        XCTAssertEqual(result.sessions.filter { $0.obstacle != nil }.map { "\($0.id): \(String(describing: $0.obstacle))" }, [])
        XCTAssertEqual(openDescriptors(), opened)
    }

    /// Only the exact folder Desktop would open counts. A transcript under the decomposed
    /// spelling of the path, or under PathNormalizer's version of it, is "no transcript".
    func testATranscriptUnderAnyOtherSlugIsNoTranscript() throws {
        let decomposed = home.home + "/work/Cafe\u{301}"
        try FileManager.default.createDirectory(atPath: decomposed, withIntermediateDirectories: true)
        try session(1, cwd: decomposed, transcript: nil)
        let rawSlug = String(String.UnicodeScalarView(decomposed.utf16.map { unit -> Unicode.Scalar in
            (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) ? Unicode.Scalar(UInt8(unit)) : "-"
        }))
        XCTAssertNotEqual(rawSlug, TranscriptLocator.projectSlug(forCwd: decomposed))
        let wrong = TranscriptLocator.projectsDirectory(home: home.home).appendingPathComponent(rawSlug)
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: wrong.appendingPathComponent(cli(1) + ".jsonl"))

        let trailing = appFolder + "/"
        try session(2, cwd: trailing, transcript: nil)
        try home.writeTranscript(cwd: PathNormalizer.normalize(trailing), cliSessionId: cli(2), lines: ["{}"])

        XCTAssertEqual(listing().sessions, [])
        XCTAssertEqual(listing().hidden.withoutTranscript, 2)

        // At the exact folder, both are found.
        try home.writeTranscript(cwd: decomposed, cliSessionId: cli(1), lines: ["{}"])
        try home.writeTranscript(cwd: trailing, cliSessionId: cli(2), lines: ["{}"])
        XCTAssertEqual(Set(listing().sessions.map(\.id)), ["local_\(uuid(1))", "local_\(uuid(2))"])
    }

    // MARK: - Running sessions

    func testARunningSessionIsMarkedAndOneStillReplyingCannotBeCopied() throws {
        try session(1)
        try session(2)
        try session(3)
        try home.writeRegistry(pid: 11, ["sessionId": cli(1), "hostSessionId": "local_\(uuid(1))", "status": "idle"])
        try home.writeRegistry(pid: 12, ["sessionId": cli(2), "status": "busy"])
        try home.writeRegistry(pid: 13, ["sessionId": cli(3), "status": "busy"])
        let environment = home.environment(alive: { pid, _ in pid != 13 })

        XCTAssertEqual(listed(1, environment)?.isRunning, true)
        XCTAssertNil(listed(1, environment)?.obstacle)
        XCTAssertEqual(listed(2, environment)?.isRunning, true)
        XCTAssertEqual(listed(2, environment)?.obstacle, .stillReplying)
        XCTAssertEqual(listed(3, environment)?.isRunning, false, "its process is gone")
        XCTAssertNil(listed(3, environment)?.obstacle)
    }

    // MARK: - Why a session cannot be copied anywhere

    func testEachReasonASessionCannotBeCopiedIsReported() throws {
        let worktree = try home.makeDirectory("work/repo/.claude/worktrees/feature")
        let scratch = try home.makeDirectory("Library/Application Support/Claude/scratch-workspaces/a/o/scratch-2026-10-05-abcdef")
        let gone = home.root.appendingPathComponent("work/gone").path
        let cases: [(Int, String?, [String: Any], SessionCopy.Refusal)] = [
            (1, nil, ["worktreePath": "/w"], .inWorktree),
            (2, nil, ["worktreeLazy": ["path": "/w", "root": "/r"]], .inWorktree),
            (3, nil, ["keptDirtyWorktree": true], .inWorktree),
            (4, worktree, [:], .inWorktree),
            (5, scratch, [:], .inScratchWorkspace),
            (6, nil, ["priorCliSessionIds": [cli(99)]], .severalTranscripts),
            (7, nil, ["unarchivedCliSessionId": cli(98)], .severalTranscripts),
            (8, nil, ["originCwd": "/Users/me/elsewhere"], .originFolderDiffers),
            (9, gone, [:], .workingFolderMissing(cwd: gone)),
            (10, "relative/app", [:], .workingFolderNotAbsolute),
        ]
        for (n, cwd, extra, _) in cases { try session(n, cwd: cwd, extra: extra) }

        let result = listing()
        for (n, _, _, expected) in cases {
            XCTAssertEqual(result.sessions.first { $0.id == "local_\(uuid(n))" }?.obstacle, expected, "case \(n)")
        }
    }

    /// Only "nothing there" is "no longer exists": a folder under a file is gone too, but one
    /// that cannot be looked at (no permission on a folder above it) may well exist.
    func testAWorkingFolderThatCannotBeLookedAtIsNotCalledMissing() throws {
        let parent = try home.makeDirectory("locked")
        let cwd = try home.makeDirectory("locked/app")
        try session(1, cwd: cwd)
        let underAFile = home.root.appendingPathComponent("plain-file/app").path
        try Data("x".utf8).write(to: home.root.appendingPathComponent("plain-file"))
        try session(2, cwd: underAFile)
        XCTAssertNil(listed(1)?.obstacle)
        XCTAssertEqual(listed(2)?.obstacle, .workingFolderMissing(cwd: underAFile))

        XCTAssertEqual(chmod(parent, 0o000), 0)
        defer { chmod(parent, 0o755) }
        XCTAssertEqual(listed(1)?.obstacle, .workingFolderUnreachable(cwd: cwd))
    }

    /// A title or working folder that contains the session's own id — its transcript id, its
    /// record id or that id's bare UUID, in any case — cannot be copied: the copy's record would
    /// carry it. Another session's id is no obstacle.
    func testASessionWhoseTitleOrFolderNamesItsOwnIdCannotBeCopied() throws {
        try session(1, extra: ["title": "Resume \(cli(1).uppercased())"])
        try session(2, extra: ["title": "local_\(uuid(2))"])
        try session(3, extra: ["title": "about \(uuid(3))"])
        try session(4, cwd: try home.makeDirectory("work/\(cli(4))"))
        try session(5, extra: ["title": "Follows up on \(cli(9)) and local_\(uuid(9))"])
        for n in 1...4 { XCTAssertEqual(listed(n)?.obstacle, .mentionsOwnID, "session \(n)") }
        XCTAssertNil(listed(5)?.obstacle)
    }

    /// One session folder that cannot be read refuses every copy (a copy's new id must be proven
    /// unused in every store on the Mac); which one is named, for Diagnostics.
    func testASessionFolderThatCannotBeReadIsNamed() throws {
        try session(1)
        XCTAssertNil(SessionCopy.unreadableStore(allProfiles: profiles, environment: home.environment()))
        // Not configured here, but a Claude* folder all the same.
        let other = try home.makeStore(userDataDir: "~/Library/Application Support/Claude-other",
                                       account: "cccccccc-1111-4111-8111-111111111111", org: "cccccccc-2222-4222-8222-222222222222")
        let sessions = other.url.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(chmod(sessions.path, 0o000), 0)
        defer { chmod(sessions.path, 0o755) }
        XCTAssertEqual(SessionCopy.unreadableStore(allProfiles: profiles, environment: home.environment())?.path, sessions.path)
    }

    func testATranscriptThatIsEmptyOrHardLinkedCannotBeCopied() throws {
        try session(1, transcript: nil)
        try FileManager.default.createDirectory(at: projectFolder(), withIntermediateDirectories: true)
        try Data().write(to: projectFolder().appendingPathComponent(cli(1) + ".jsonl"))
        try session(2)
        XCTAssertEqual(link(projectFolder().appendingPathComponent(cli(2) + ".jsonl").path,
                            projectFolder().appendingPathComponent("second-name").path), 0)

        XCTAssertEqual(listed(1)?.obstacle, .transcriptEmpty)
        XCTAssertEqual(listed(2)?.obstacle, .notPlainFile)
    }

    /// Claude has marked the session for removal — a tombstone in the store or a release
    /// marker next to the transcript. Copying it would bring back what was deleted.
    func testASessionClaudeHasMarkedDeletedCannotBeCopied() throws {
        try session(1)
        try session(2)
        try session(3)
        try session(4)
        try Data("1".utf8).write(to: projectFolder().appendingPathComponent(cli(1) + ".desktop-released.json"))
        try Data("1".utf8).write(to: storeA.url.appendingPathComponent("deleted_" + cli(2)))
        try Data("1".utf8).write(to: storeA.url.appendingPathComponent("deleted_" + uuid(3)))

        XCTAssertEqual(listed(1)?.obstacle, .sessionDeleted)
        XCTAssertEqual(listed(2)?.obstacle, .sessionDeleted)
        XCTAssertEqual(listed(3)?.obstacle, .sessionDeleted)
        XCTAssertNil(listed(4)?.obstacle)
    }

    /// One transcript claimed by records in two accounts' stores — by its current id or as an
    /// earlier one — cannot be copied a third time.
    func testATranscriptClaimedInTwoAccountsCannotBeCopied() throws {
        try session(1)
        try session(2)
        try session(3)
        try home.writeRecord(["sessionId": "local_\(uuid(50))", "cliSessionId": cli(1), "cwd": appFolder!, "isArchived": true], in: storeB)
        try home.writeRecord(["sessionId": "local_\(uuid(51))", "cliSessionId": cli(51), "cwd": appFolder!,
                              "priorCliSessionIds": [cli(2)]], in: storeB)

        XCTAssertEqual(listed(1)?.obstacle, .claimedByTwoAccounts)
        XCTAssertEqual(listed(2)?.obstacle, .claimedByTwoAccounts)
        XCTAssertNil(listed(3)?.obstacle)
    }

    /// Two profiles spelling one folder differently are one store, not two claims.
    func testOneFolderUnderTwoSpellingsIsOneStore() throws {
        try session(1)
        let link = home.root.appendingPathComponent("Library/Application Support/Claude-alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.userDataDir(nil))
        let alias = Profile(id: "alias", label: "Alias", userDataDir: link.path)
        let result = SessionListing.read(profile: personal, allProfiles: profiles + [alias], environment: home.environment())
        XCTAssertNil(result.sessions.first?.obstacle)
    }

    /// The listing finds the transcript the way Claude does, but a copy never goes through a
    /// link: a symlinked `~/.claude` is listed and refused (spec D2).
    func testASymlinkedClaudeFolderIsListedButCannotBeCopied() throws {
        try session(1)
        let real = home.root.appendingPathComponent("dotfiles/claude")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: home.root.appendingPathComponent(".claude"), to: real)
        try FileManager.default.createSymbolicLink(at: home.root.appendingPathComponent(".claude"), withDestinationURL: real)

        XCTAssertEqual(listed(1)?.obstacle, .linkInPath)
    }

    /// The checks on the transcript itself, on fabricated `stat` results — a file of another
    /// owner cannot be planted in the user's own folder without root.
    func testATranscriptMustBeOnePlainNonEmptyFileOfTheUser() {
        func status(mode: mode_t = S_IFREG | 0o600, links: nlink_t = 1, owner: uid_t = getuid(), size: off_t = 10) -> FileStatus {
            var info = stat()
            info.st_mode = mode
            info.st_nlink = links
            info.st_uid = owner
            info.st_size = size
            return FileStatus(info)
        }
        let me = getuid()
        XCTAssertNil(ListedSession.transcriptProblem(status(), expectedOwner: me))
        XCTAssertEqual(ListedSession.transcriptProblem(status(owner: me + 1), expectedOwner: me), .notOwnedByYou)
        XCTAssertEqual(ListedSession.transcriptProblem(status(links: 2), expectedOwner: me), .notPlainFile)
        XCTAssertEqual(ListedSession.transcriptProblem(status(mode: S_IFIFO | 0o600), expectedOwner: me), .notPlainFile)
        XCTAssertEqual(ListedSession.transcriptProblem(status(mode: S_IFLNK | 0o777), expectedOwner: me), .notPlainFile)
        XCTAssertEqual(ListedSession.transcriptProblem(status(mode: S_IFDIR | 0o700), expectedOwner: me), .notPlainFile)
        XCTAssertEqual(ListedSession.transcriptProblem(status(size: 0), expectedOwner: me), .transcriptEmpty)
    }

    func testFoldersOfAnotherOwnerOrOpenToOthersCannotBeCopiedFrom() throws {
        try session(1)
        XCTAssertEqual(listed(1, home.environment(expectedUID: getuid() + 1))?.obstacle, .notOwnedByYou)
        chmod(projectFolder().path, 0o777)
        XCTAssertEqual(listed(1)?.obstacle, .writableByOthers)
    }

    // MARK: - Whether it can go to a particular account

    private func obstacle(_ n: Int, to target: Profile? = nil, _ environment: SessionCopy.Environment? = nil) throws -> SessionCopy.Refusal? {
        let env = environment ?? home.environment()
        let item = try XCTUnwrap(listed(n, env))
        return SessionCopy.obstacle(for: item, from: personal, to: target ?? work, allProfiles: profiles, environment: env)
    }

    func testACopyableSessionHasNoObstacle() throws {
        try session(1)
        XCTAssertNil(try obstacle(1))
    }

    func testCopyingNeedsTheAutomationLock() throws {
        try session(1)
        XCTAssertEqual(try obstacle(1, home.environment(holdsLock: false)), .notAutomationLockHolder)
    }

    func testTheSessionsOwnObstacleComesFirst() throws {
        try session(1, extra: ["worktreePath": "/w"])
        XCTAssertEqual(try obstacle(1, home.environment(holdsLock: false)), .inWorktree)
    }

    /// The same profile — by id, by a link, or by a spelling the case-insensitive volume treats
    /// as the same folder — is not another account.
    func testTheSameFolderIsNeverATarget() throws {
        try session(1)
        XCTAssertEqual(try obstacle(1, to: personal), .sameProfile)

        let link = home.root.appendingPathComponent("Library/Application Support/Claude-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.userDataDir(nil))
        XCTAssertEqual(try obstacle(1, to: Profile(id: "link", label: "Link", userDataDir: link.path)), .sameProfile)

        let shouted = home.userDataDir(nil).path.replacingOccurrences(of: "Application Support/Claude", with: "application support/CLAUDE")
        guard FileManager.default.fileExists(atPath: shouted) else { throw XCTSkip("this volume is case-sensitive") }
        XCTAssertEqual(try obstacle(1, to: Profile(id: "shouted", label: "Shouted", userDataDir: shouted)), .sameProfile)
    }

    func testTheSameAccountIsNeverATarget() throws {
        try session(1)
        try FileManager.default.removeItem(at: storeB.url.deletingLastPathComponent())
        try home.signIn(userDataDir: work.userDataDir, account: FakeHome.accountA.uppercased(), org: FakeHome.orgB)
        XCTAssertEqual(try obstacle(1), .sameAccount(source: "Personal", target: "Work"))
    }

    func testATargetThatCannotTakeACopySaysWhy() throws {
        try session(1)
        try home.writeConfig(["lastKnownAccountUuid": FakeHome.accountB, "windowSizeWasSignedIn": false], userDataDir: work.userDataDir)
        XCTAssertEqual(try obstacle(1), .targetSignedOut(target: "Work"))
    }

    func testTooLittleOrUnknownFreeSpaceIsRefused() throws {
        try session(1)
        let size = UInt64(try XCTUnwrap(listed(1)).transcriptBytes)
        XCTAssertEqual(try obstacle(1, home.environment(freeBytes: { _ in size + (1 << 30) - 1 })), .notEnoughSpace)
        XCTAssertEqual(try obstacle(1, home.environment(freeBytes: { _ in nil })), .notEnoughSpace)
        XCTAssertNil(try obstacle(1, home.environment(freeBytes: { _ in size + (1 << 30) })))
    }

    // MARK: - Words

    /// One plain sentence each, naming accounts by their labels, and never an id or a path —
    /// except the session's own working folder.
    func testEveryRefusalIsOnePlainSentenceWithoutIdsOrPaths() {
        let cwd = "/Users/me/app"
        let all: [SessionCopy.Refusal] = [
            .notAutomationLockHolder, .lockFileUnavailable, .anotherCopyRunning, .sessionChanged, .sessionDeleted, .archived,
            .noTranscriptYet, .transcriptMissing, .transcriptEmpty, .stillBeingWritten, .stillReplying, .remote,
            .workingFolderNotAbsolute, .workingFolderMissing(cwd: cwd), .workingFolderUnreachable(cwd: cwd), .mentionsOwnID,
            .inWorktree, .inScratchWorkspace, .originFolderDiffers, .severalTranscripts,
            .claimedByTwoAccounts, .watchingArtifactComments, .remoteControlUnclearable, .unreadableTranscriptLine,
            .notEnoughSpace, .sameProfile, .sameAccount(source: "Personal", target: "Work"),
            .targetSignedOut(target: "Work"), .targetNeverSignedIn(target: "Work"), .targetHasNoSessions(target: "Work"),
            .targetSeveralOrganisations(target: "Work"), .targetOrganisationHasNoSessions(target: "Work"),
            .targetUnreadable(target: "Work"), .targetChanged(target: "Work"), .targetFolderIsLink(target: "Work"),
            .targetFolderNotYours(target: "Work"), .targetFolderWritableByOthers(target: "Work"), .nameTaken, .storeUnreadable,
            .linkInPath, .notPlainFile, .notOwnedByYou, .writableByOthers, .renameUnsupported, .journalFolderCannotRename,
            .recordCheckFailed, .fileSystem(errno: EACCES),
        ]
        for refusal in all {
            let message = refusal.message
            XCTAssertTrue(message.hasSuffix("."), message)
            XCTAssertEqual(message.first?.isUppercase, true, message)
            XCTAssertNil(message.range(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}", options: .regularExpression), message)
            switch refusal {
            case .workingFolderMissing, .workingFolderUnreachable:
                XCTAssertTrue(message.contains(cwd), message)
            case .lockFileUnavailable, .journalFolderCannotRename:
                // The switcher's own folder, never one of the user's sessions'.
                XCTAssertTrue(message.contains("~/.config/claude-switcher"), message)
                XCTAssertFalse(message.replacingOccurrences(of: "~/.config/claude-switcher", with: "").contains("/"), message)
            default:
                XCTAssertFalse(message.contains("/"), message)
            }
            if case .targetFolderIsLink = refusal { XCTAssertTrue(message.hasPrefix("Work"), message) }
            if case .targetFolderNotYours = refusal { XCTAssertTrue(message.hasPrefix("Work"), message) }
            if case .targetFolderWritableByOthers = refusal { XCTAssertTrue(message.hasPrefix("Work"), message) }
        }
        XCTAssertTrue(SessionCopy.Refusal.sameAccount(source: "Personal", target: "Work").message.contains("Personal"))
        XCTAssertTrue(SessionCopy.Refusal.targetSignedOut(target: "Work").message.contains("Work"))
        // The target's folders are never blamed on the session's files.
        XCTAssertFalse(SessionCopy.Refusal.targetFolderIsLink(target: "Work").message.contains("session\u{2019}s files"))
    }

    func testTheConfirmationNamesBothAccountsAndTheSharedFolder() {
        let caveats = SessionCopy.confirmationCaveats(sourceLabel: "Personal", targetLabel: "Work", cwd: "/Users/me/app")
        XCTAssertEqual(caveats.count, 9)
        XCTAssertTrue(caveats.contains { $0.contains("Personal") })
        XCTAssertTrue(caveats.contains { $0.contains("Work\u{2019}s Code tab the next time") })
        XCTAssertTrue(caveats.contains { $0.contains("(/Users/me/app)") })
        XCTAssertTrue(caveats.contains { $0.contains("Keep the original") })
        XCTAssertFalse(caveats.joined().contains("<B>"))
    }
}
