import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// A throwaway home directory laid out the way Claude Desktop lays out a profile's session
/// store and `~/.claude/projects`. Nothing here touches the real ones.
final class FakeHome {
    let root: URL
    var home: String { root.path }

    static let accountA = "aaaaaaaa-1111-4111-8111-111111111111"
    static let orgA = "aaaaaaaa-2222-4222-8222-222222222222"
    static let accountB = "bbbbbbbb-1111-4111-8111-111111111111"
    static let orgB = "bbbbbbbb-2222-4222-8222-222222222222"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-switcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Undo any chmod a test left, so the tree can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in enumerator { chmod(root.appendingPathComponent(path).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// `nil` is the default profile, as everywhere else.
    func userDataDir(_ dir: String?) -> URL {
        SessionStore.userDataDirectory(dir, home: home)
    }

    @discardableResult
    func makeStore(userDataDir dir: String?, account: String, org: String) throws -> SessionStoreFolder {
        let url = userDataDir(dir)
            .appendingPathComponent(SessionStore.directoryName, isDirectory: true)
            .appendingPathComponent(account, isDirectory: true)
            .appendingPathComponent(org, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SessionStoreFolder(url: url, accountID: account, organizationID: org)
    }

    func writeConfig(_ fields: [String: Any], userDataDir dir: String?) throws {
        let url = userDataDir(dir).appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: fields).write(to: url)
    }

    /// A profile signed in to `account`, with one store folder for it.
    @discardableResult
    func signIn(userDataDir dir: String?, account: String, org: String, extra: [String: Any] = [:]) throws -> SessionStoreFolder {
        var fields: [String: Any] = ["lastKnownAccountUuid": account, "windowSizeWasSignedIn": true]
        for (key, value) in extra { fields[key] = value }
        try writeConfig(fields, userDataDir: dir)
        return try makeStore(userDataDir: dir, account: account, org: org)
    }

    @discardableResult
    func writeRecord(_ fields: [String: Any], in folder: SessionStoreFolder, fileStem: String? = nil) throws -> URL {
        let stem = fileStem ?? (fields["sessionId"] as? String ?? "local_\(UUID().uuidString.lowercased())")
        let url = folder.url.appendingPathComponent(stem + ".json")
        try JSONSerialization.data(withJSONObject: fields).write(to: url)
        return url
    }

    @discardableResult
    func writeTranscript(cwd: String, cliSessionId: String, lines: [String]) throws -> URL {
        let url = TranscriptLocator.transcriptURL(cwd: cwd, cliSessionId: cliSessionId, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    func makeDirectory(_ path: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// `~/.claude/sessions/<pid>.json`.
    func writeRegistry(pid: Int32, _ fields: [String: Any]) throws {
        let directory = root.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var all = fields
        all["pid"] = all["pid"] ?? Int(pid)
        try JSONSerialization.data(withJSONObject: all).write(to: directory.appendingPathComponent("\(pid).json"))
    }

    /// Seams for a test: this home, the lock held, every registered pid alive unless said otherwise.
    func environment(
        holdsLock: Bool = true,
        expectedUID: uid_t = getuid(),
        alive: @escaping @Sendable (Int32, String?) -> Bool = { _, _ in true },
        freeBytes: @escaping @Sendable (Int32) -> UInt64? = { _ in 1 << 40 }
    ) -> SessionCopy.Environment {
        SessionCopy.Environment(home: home, holdsAutomationLock: holdsLock, expectedUID: expectedUID,
                                isAlive: alive, freeBytes: freeBytes, pause: { _ in })
    }

    func snapshot() -> TreeSnapshot { TreeSnapshot(of: root) }
}

final class SessionCatalogTests: XCTestCase {

    private func record(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = ["sessionId": "local_\(id)", "cwd": "/Users/me/project"]
        for (key, value) in extra { fields[key] = value }
        return fields
    }

    private let s1 = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let s2 = "22222222-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let c1 = "c1c1c1c1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let work = "~/Library/Application Support/Claude-work"
    private let work2 = "~/Library/Application Support/Claude-second"

    // MARK: - Finding the store to list

    func testAProfileThatNeverKeptSessionsHasNoStore() throws {
        let home = try FakeHome()
        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), SessionStoreLocation.none)
    }

    func testTheDefaultProfileAndANamedProfileAreFoundInTheirOwnDirectories() throws {
        let home = try FakeHome()
        let a = try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        let dir = home.root.appendingPathComponent("Library/Application Support/Claude-work").path
        let b = try home.makeStore(userDataDir: dir, account: FakeHome.accountB, org: FakeHome.orgB)

        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), .folder(a))
        XCTAssertEqual(SessionStore.locate(userDataDir: dir, home: home.home), .folder(b))
    }

    /// Two accounts have used the profile and nothing says which is current: listing either
    /// would put one account's sessions under the other's name.
    func testSeveralAccountFoldersWithNothingToChooseBetweenThemIsAmbiguous() throws {
        let home = try FakeHome()
        try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        try home.makeStore(userDataDir: nil, account: FakeHome.accountB, org: FakeHome.orgB)
        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), .ambiguous(2))
    }

    func testTheAccountClaudeLastRecordedChoosesBetweenSeveral() throws {
        let home = try FakeHome()
        try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        let b = try home.makeStore(userDataDir: nil, account: FakeHome.accountB, org: FakeHome.orgB)
        try home.writeConfig(["lastKnownAccountUuid": FakeHome.accountB.uppercased()], userDataDir: nil)

        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), .folder(b))
    }

    /// The last-known account has two organisations: still nothing to choose between them.
    func testOneAccountWithSeveralOrganisationsStaysAmbiguous() throws {
        let home = try FakeHome()
        try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgB)
        try home.writeConfig(["lastKnownAccountUuid": FakeHome.accountA], userDataDir: nil)

        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), .ambiguous(2))
    }

    /// The organisation Claude last refreshed its extension allow-list for picks between the
    /// account's organisations — for showing them; never for copying into them.
    func testTheOrganisationClaudeLastNotedChoosesBetweenTheAccountsOrganisationsForTheList() throws {
        let home = try FakeHome()
        try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        let b = try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgB)
        try home.writeConfig([
            "lastKnownAccountUuid": FakeHome.accountA,
            "dxt:allowlistLastUpdated:\(FakeHome.orgA)": "2026-10-01T10:00:00.000Z",
            "dxt:allowlistLastUpdated:\(FakeHome.orgB)": "2026-10-04T10:00:00.000Z",
        ], userDataDir: nil)
        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), .folder(b))

        // A tie says nothing.
        try home.writeConfig([
            "lastKnownAccountUuid": FakeHome.accountA,
            "dxt:allowlistLastUpdated:\(FakeHome.orgA)": "2026-10-04T10:00:00.000Z",
            "dxt:allowlistLastUpdated:\(FakeHome.orgB)": "2026-10-04T10:00:00.000Z",
        ], userDataDir: nil)
        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), .ambiguous(2))
    }

    /// Signed in to account B now, with only account A's folder on disk: those are not B's
    /// sessions, and are not listed as if they were.
    func testAFolderOfAnotherAccountIsNeverListedAsThisAccounts() throws {
        let home = try FakeHome()
        try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        try home.writeConfig(["lastKnownAccountUuid": FakeHome.accountB], userDataDir: nil)
        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), .otherAccountOnly)
    }

    /// A link is never followed into: it could point at another account's folder, or anywhere.
    func testASymlinkedAccountFolderIsNotAStore() throws {
        let home = try FakeHome()
        let real = try home.makeStore(userDataDir: home.root.appendingPathComponent("elsewhere").path,
                                      account: FakeHome.accountA, org: FakeHome.orgA)
        let store = home.userDataDir(nil).appendingPathComponent(SessionStore.directoryName)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: store.appendingPathComponent(FakeHome.accountA),
            withDestinationURL: real.url.deletingLastPathComponent())

        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), SessionStoreLocation.none)
    }

    func testFoldersNotNamedLikeAccountsAreIgnored() throws {
        let home = try FakeHome()
        let a = try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        let store = home.userDataDir(nil).appendingPathComponent(SessionStore.directoryName)
        try FileManager.default.createDirectory(at: store.appendingPathComponent("not-an-account/x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: a.url.deletingLastPathComponent().appendingPathComponent("backlog"), withIntermediateDirectories: true)

        XCTAssertEqual(SessionStore.locate(userDataDir: nil, home: home.home), .folder(a))
    }

    // MARK: - Finding the store to copy into

    private func target(_ home: FakeHome, _ dir: String?, label: String = "Work",
                        expectedOwner: uid_t = getuid()) -> Result<SessionStoreFolder, SessionCopy.Refusal> {
        SessionStore.locateForCopyTarget(profile: Profile(id: "t", label: label, userDataDir: dir),
                                         home: home.home, expectedOwner: expectedOwner).map(\.folder)
    }

    func testASignedInProfileWithOneFolderForItsAccountIsATarget() throws {
        let home = try FakeHome()
        let folder = try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB)
        XCTAssertEqual(target(home, work), .success(folder))
    }

    /// Without `windowSizeWasSignedIn`, Claude's own fallback applies: a recorded account means signed in.
    func testWithoutTheSignedInFlagARecordedAccountCountsAsSignedIn() throws {
        let home = try FakeHome()
        let folder = try home.makeStore(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB)
        try home.writeConfig(["lastKnownAccountUuid": FakeHome.accountB], userDataDir: work)
        XCTAssertEqual(target(home, work), .success(folder))
    }

    /// A signed-out profile keeps its old folder, and Claude would not load it.
    func testASignedOutProfileIsRefusedEvenWithAFolder() throws {
        let home = try FakeHome()
        try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB,
                        extra: ["windowSizeWasSignedIn": false])
        XCTAssertEqual(target(home, work), .failure(.targetSignedOut(target: "Work")))
    }

    func testAProfileNeverSignedInIsRefused() throws {
        let home = try FakeHome()
        XCTAssertEqual(target(home, work), .failure(.targetNeverSignedIn(target: "Work")))
        try home.makeStore(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB)
        XCTAssertEqual(target(home, work), .failure(.targetNeverSignedIn(target: "Work")))
    }

    /// "If exactly one folder exists, use it" is wrong for a copy: that folder can belong to the
    /// account the profile was signed in to before.
    func testTheOnlyFolderBeingAnotherAccountsIsRefused() throws {
        let home = try FakeHome()
        try home.makeStore(userDataDir: work, account: FakeHome.accountA, org: FakeHome.orgA)
        try home.writeConfig(["lastKnownAccountUuid": FakeHome.accountB, "windowSizeWasSignedIn": true], userDataDir: work)
        XCTAssertEqual(target(home, work), .failure(.targetHasNoSessions(target: "Work")))
    }

    /// v1: which organisation is current is kept only in an encrypted cookie, so an account
    /// with two organisation folders is refused — even when the allow-list key names one.
    func testTwoOrganisationFoldersUnderTheAccountAreRefused() throws {
        let home = try FakeHome()
        try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgA,
                        extra: ["dxt:allowlistLastUpdated:\(FakeHome.orgB)": "2026-10-04T10:00:00.000Z"])
        try home.makeStore(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB)
        XCTAssertEqual(target(home, work), .failure(.targetSeveralOrganisations(target: "Work")))
    }

    func testAnOrganisationHintThatNamesNoFolderIsRefused() throws {
        let home = try FakeHome()
        try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB,
                        extra: ["dxt:allowlistLastUpdated:\(FakeHome.orgA)": "2026-10-04T10:00:00.000Z"])
        XCTAssertEqual(target(home, work), .failure(.targetOrganisationHasNoSessions(target: "Work")))
    }

    func testTheNewestOrganisationHintMustNameTheFolder() throws {
        let home = try FakeHome()
        let folder = try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB, extra: [
            "dxt:allowlistLastUpdated:\(FakeHome.orgA)": "2026-09-01T10:00:00.000Z",
            "dxt:allowlistLastUpdated:\(FakeHome.orgB)": "2026-10-04T10:00:00Z",
        ])
        XCTAssertEqual(target(home, work), .success(folder))

        try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB, extra: [
            "dxt:allowlistLastUpdated:\(FakeHome.orgA)": "2026-10-05T10:00:00.000Z",
            "dxt:allowlistLastUpdated:\(FakeHome.orgB)": "2026-10-04T10:00:00.000Z",
        ])
        XCTAssertEqual(target(home, work), .failure(.targetOrganisationHasNoSessions(target: "Work")))
    }

    /// A hint that cannot be read cannot vouch for the folder.
    func testAnOrganisationHintThatCannotBeReadIsRefused() throws {
        let home = try FakeHome()
        try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB,
                        extra: ["dxt:allowlistLastUpdated:\(FakeHome.orgB)": "yesterday"])
        XCTAssertEqual(target(home, work), .failure(.targetOrganisationHasNoSessions(target: "Work")))
    }

    func testIdsAreComparedWithoutRegardToCase() throws {
        let home = try FakeHome()
        let folder = try home.makeStore(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB)
        try home.writeConfig(["lastKnownAccountUuid": FakeHome.accountB.uppercased(), "windowSizeWasSignedIn": true,
                              "dxt:allowlistLastUpdated:\(FakeHome.orgB)": "2026-10-04T10:00:00.000Z"], userDataDir: work)
        XCTAssertEqual(target(home, work), .success(folder))
    }

    func testSettingsThatCannotBeReadAreRefused() throws {
        let home = try FakeHome()
        try home.makeStore(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB)
        try FileManager.default.createDirectory(at: home.userDataDir(work).appendingPathComponent("config.json"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(target(home, work), .failure(.targetUnreadable(target: "Work")))
    }

    /// No link is followed on the way to the store: not at the user-data folder, nor at
    /// `claude-code-sessions`, the account or the organisation — and the link's target is untouched.
    func testALinkAnywhereFromHomeToTheStoreIsRefused() throws {
        let relativeStore = "Library/Application Support/Claude-work/claude-code-sessions/\(FakeHome.accountB)/\(FakeHome.orgB)"
        let parts = relativeStore.split(separator: "/").map(String.init)
        // Every component from the home directory down (spec D2).
        for depth in 1...parts.count {
            let home = try FakeHome()
            try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB)
            let linked = parts.prefix(depth).joined(separator: "/")
            let moved = home.root.appendingPathComponent("elsewhere-target")
            try FileManager.default.moveItem(at: home.root.appendingPathComponent(linked), to: moved)
            try FileManager.default.createSymbolicLink(at: home.root.appendingPathComponent(linked), withDestinationURL: moved)
            let before = TreeSnapshot(of: moved)

            XCTAssertEqual(target(home, work), .failure(.targetFolderIsLink(target: "Work")), linked)
            XCTAssertEqual(TreeSnapshot(of: moved), before, linked)
        }
    }

    func testAStoreOfAnotherOwnerIsRefused() throws {
        let home = try FakeHome()
        try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB)
        XCTAssertEqual(target(home, work, expectedOwner: getuid() + 1), .failure(.targetFolderNotYours(target: "Work")))
    }

    func testAStoreOthersCanWriteToIsRefused() throws {
        let home = try FakeHome()
        let folder = try home.signIn(userDataDir: work, account: FakeHome.accountB, org: FakeHome.orgB)
        chmod(folder.url.path, 0o777)
        XCTAssertEqual(target(home, work), .failure(.targetFolderWritableByOthers(target: "Work")))
    }

    // MARK: - Reading records

    func testRecordsAreReadNewestActivityFirst() throws {
        let home = try FakeHome()
        let folder = try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        try home.writeRecord(record(s1, ["title": "Older", "lastActivityAt": 1_000_000, "createdAt": 500_000]), in: folder)
        try home.writeRecord(record(s2, ["title": "Newer", "lastActivityAt": 2_000_000, "cliSessionId": c1,
                                         "isArchived": true, "model": "claude-x", "effort": "high"]), in: folder)

        let records = SessionStore.records(in: folder)
        XCTAssertEqual(records.map(\.title), ["Newer", "Older"])
        XCTAssertEqual(records[0].id, "local_\(s2)")
        XCTAssertEqual(records[0].cliSessionId, c1)
        XCTAssertEqual(records[0].isArchived, true)
        XCTAssertEqual(records[0].model, "claude-x")
        XCTAssertEqual(records[0].lastActivityAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(records[1].createdAt, Date(timeIntervalSince1970: 500))
        XCTAssertNil(records[1].cliSessionId)
    }

    func testWhatMakesASessionMoreThanOneLocalTranscriptIsNoticed() throws {
        let home = try FakeHome()
        let folder = try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        try home.writeRecord(record(s1, ["sshConfig": ["host": "h"], "worktreePath": "/w", "priorCliSessionIds": [c1]]), in: folder)
        try home.writeRecord(record(s2, ["sshConfig": NSNull(), "branch": "", "priorCliSessionIds": [Any]()]), in: folder)

        let records = Dictionary(uniqueKeysWithValues: SessionStore.records(in: folder).map { ($0.id, $0) })
        let flagged = try XCTUnwrap(records["local_\(s1)"])
        XCTAssertTrue(flagged.isRemote)
        XCTAssertTrue(flagged.hasWorktree)
        XCTAssertTrue(flagged.hasEarlierTranscripts)
        XCTAssertEqual(flagged.earlierCliSessionIds, [c1])
        let plain = try XCTUnwrap(records["local_\(s2)"])
        XCTAssertFalse(plain.isRemote)
        XCTAssertFalse(plain.hasWorktree)
        XCTAssertFalse(plain.hasEarlierTranscripts)
    }

    /// Each field Desktop acts on to remove a worktree or a branch marks the record — by
    /// JavaScript truthiness, as Desktop tests them.
    func testEveryWorktreeFieldDesktopActsOnIsNoticed() throws {
        for field in ["worktreePath", "worktreeName", "branch", "sourceBranch", "worktreeLazy",
                      "keptWorktreeLeftover", "keptDirtyWorktree"] {
            for (value, expected) in [(["path": "/w"] as Any, true), ("x", true), (true, true), (1, true),
                                      (false, false), ("", false), (0, false), (NSNull(), false)] {
                let data = try JSONSerialization.data(withJSONObject: record(s1, [field: value]))
                let parsed = try XCTUnwrap(SessionStore.record(from: data, fileStem: "local_\(s1)"))
                XCTAssertEqual(parsed.hasWorktree, expected, "\(field) = \(value)")
            }
        }
    }

    func testEarlierTranscriptsAreNoticedWhereverTheRecordNamesThem() throws {
        for (field, value) in [("unarchivedCliSessionId", c1 as Any), ("preClearCliSessionId", c1), ("priorCliSessionIds", [c1])] {
            let data = try JSONSerialization.data(withJSONObject: record(s1, [field: value]))
            let parsed = try XCTUnwrap(SessionStore.record(from: data, fileStem: "local_\(s1)"))
            XCTAssertTrue(parsed.hasEarlierTranscripts, field)
            XCTAssertEqual(parsed.earlierCliSessionIds, [c1], field)
        }
    }

    func testTheWorkingFolderSaysWhetherItIsAWorktreeOrAScratchWorkspace() {
        func folder(_ cwd: String) -> SessionRecord { SessionRecord(id: "local_\(s1)", cliSessionId: nil, title: nil, cwd: cwd) }
        XCTAssertTrue(folder("/Users/me/repo/.claude/worktrees/feature").isInClaudeWorktreeFolder)
        XCTAssertTrue(folder("/Users/me/repo/.Claude/Worktrees/feature").isInClaudeWorktreeFolder)
        XCTAssertFalse(folder("/Users/me/repo/.claude").isInClaudeWorktreeFolder)
        XCTAssertFalse(folder("/Users/me/repo/worktrees").isInClaudeWorktreeFolder)
        XCTAssertTrue(folder("/Users/me/Library/Application Support/Claude/scratch-workspaces/a/o/scratch-2026-10-05-abcdef").isInScratchWorkspace)
        XCTAssertFalse(folder("/Users/me/scratch").isInScratchWorkspace)
    }

    /// Tolerant like Claude's own loader: anything that is not a well-formed record of the
    /// session its file is named for is passed over, and never raises.
    func testWhatIsNotARecordIsSkipped() throws {
        let home = try FakeHome()
        let folder = try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        try home.writeRecord(record(s1, ["title": "Good"]), in: folder)

        try Data("{ not json".utf8).write(to: folder.url.appendingPathComponent("local_\(s2).json"))
        try Data().write(to: folder.url.appendingPathComponent("local_33333333-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json"))
        // Names itself as a different session than its file.
        try home.writeRecord(record(c1), in: folder, fileStem: "local_44444444-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        // No working folder: Claude's loader throws on it.
        try home.writeRecord(["sessionId": "local_55555555-aaaa-4aaa-8aaa-aaaaaaaaaaaa"], in: folder)
        // Not records at all.
        try Data("{}".utf8).write(to: folder.url.appendingPathComponent("scheduled-tasks.json"))
        try Data("1".utf8).write(to: folder.url.appendingPathComponent("deleted_\(s2)"))
        try Data("{}".utf8).write(to: folder.url.appendingPathComponent("local_\(s2).json.tmp"))
        // A link to a perfectly good record elsewhere is still not a record here.
        let elsewhere = home.root.appendingPathComponent("elsewhere.json")
        try JSONSerialization.data(withJSONObject: record("66666666-aaaa-4aaa-8aaa-aaaaaaaaaaaa")).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: folder.url.appendingPathComponent("local_66666666-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json"),
            withDestinationURL: elsewhere)
        // A folder and a pipe under a record's name; the pipe must not hang the read.
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("local_77777777-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(folder.url.appendingPathComponent("local_88888888-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json").path, 0o600), 0)
        // Larger than Claude itself would read.
        var huge = try JSONSerialization.data(withJSONObject: record("99999999-aaaa-4aaa-8aaa-aaaaaaaaaaaa", ["title": "Huge"]))
        huge.append(Data(repeating: 0x20, count: SessionStore.maxRecordBytes))
        try huge.write(to: folder.url.appendingPathComponent("local_99999999-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json"))

        let started = Date()
        XCTAssertEqual(SessionStore.records(in: folder).map(\.title), ["Good"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A field of an unexpected type is treated as absent; the record is still read.
    func testAFieldOfTheWrongTypeDoesNotLoseTheRecord() throws {
        let data = try JSONSerialization.data(withJSONObject: record(s1, ["title": 5, "createdAt": "soon", "model": ["x"]]))
        let parsed = try XCTUnwrap(SessionStore.record(from: data, fileStem: "local_\(s1)"))
        XCTAssertNil(parsed.title)
        XCTAssertNil(parsed.createdAt)
        XCTAssertNil(parsed.model)
    }

    func testAnIdThatIsNotAUUIDIsNotATranscriptName() {
        let data = try! JSONSerialization.data(withJSONObject: record(s1, ["cliSessionId": "../../etc/passwd"]))
        XCTAssertNil(SessionStore.record(from: data, fileStem: "local_\(s1)")?.cliSessionId)
        XCTAssertNil(SessionStore.record(from: data, fileStem: "local_../x"))
    }

    /// A record that changes on disk is read again, not served from the cache.
    func testAChangedRecordIsReadAgain() throws {
        let home = try FakeHome()
        let folder = try home.makeStore(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        try home.writeRecord(record(s1, ["title": "First"]), in: folder)
        XCTAssertEqual(SessionStore.records(in: folder).map(\.title), ["First"])
        try home.writeRecord(record(s1, ["title": "Second, longer"]), in: folder)
        XCTAssertEqual(SessionStore.records(in: folder).map(\.title), ["Second, longer"])
    }

    // MARK: - Finding the transcript

    /// Expected values are what Desktop's own `cliProjectDirSlug` (main.pretty.js `V5n`, run
    /// verbatim under node) returns for the same input.
    func testTheProjectFolderIsNamedExactlyAsDesktopNamesIt() {
        let slug = TranscriptLocator.projectSlug(forCwd:)
        XCTAssertEqual(slug("/Users/me/my project_v2.0"), "-Users-me-my-project-v2-0")
        // NFC first: a decomposed é is one unit, so one dash.
        XCTAssertEqual(slug("/Users/me/Cafe\u{301}"), "-Users-me-Caf-")
        XCTAssertEqual(slug("/Users/me/Caf\u{e9}"), "-Users-me-Caf-")
        // Per UTF-16 unit: an emoji is a surrogate pair, two dashes.
        XCTAssertEqual(slug("/Users/me/\u{1F600}/a"), "-Users-me----a")
        // The raw string, not PathNormalizer's: a trailing slash and a double slash count.
        XCTAssertEqual(slug("/Users/me/app/"), "-Users-me-app-")
        XCTAssertEqual(slug("/Users//me/app"), "-Users--me-app")
    }

    func testAProjectFolderNameOver200UnitsIsCutAndHashedAsDesktopDoes() {
        let slug = TranscriptLocator.projectSlug(forCwd:)
        XCTAssertEqual(slug("/" + String(repeating: "x", count: 199)), "-" + String(repeating: "x", count: 199))
        XCTAssertEqual(slug("/" + String(repeating: "x", count: 200)), "-" + String(repeating: "x", count: 199) + "-d0i18x")
        XCTAssertEqual(slug("/Users/me/" + String(repeating: "a", count: 250)),
                       "-Users-me-" + String(repeating: "a", count: 190) + "-ctfcht")
        // A negative hash: its absolute value.
        XCTAssertEqual(slug("/Users/me/" + String(repeating: "Projects/", count: 30)),
                       String(("-Users-me-" + String(repeating: "Projects-", count: 30)).prefix(200)) + "-ks4jwf")
        XCTAssertEqual(slug("/Users/me/" + String(repeating: "\u{1F600}", count: 110)),
                       "-Users-me-" + String(repeating: "-", count: 190) + "-ngzdd7")
        // NFC before counting and hashing: 210 raw units become 110, so no cut at all…
        XCTAssertEqual(slug("/Users/me/" + String(repeating: "e\u{301}", count: 100)),
                       "-Users-me-" + String(repeating: "-", count: 100))
        // …and decomposed and composed spellings hash alike.
        let composed = "-Users-me-" + String(repeating: "-", count: 190) + "-oshpup"
        XCTAssertEqual(slug("/Users/me/" + String(repeating: "e\u{301}", count: 200)), composed)
        XCTAssertEqual(slug("/Users/me/" + String(repeating: "\u{e9}", count: 200)), composed)
    }

    func testTheTranscriptIsLookedForInExactlyOnePlace() throws {
        let home = try FakeHome()
        XCTAssertEqual(
            TranscriptLocator.transcriptURL(cwd: "/Users/me/app", cliSessionId: c1, home: home.home).path,
            home.root.appendingPathComponent(".claude/projects/-Users-me-app/\(c1).jsonl").path)
    }
}
