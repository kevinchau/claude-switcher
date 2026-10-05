import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// What a step hook throws to stop a copy where it stands, as a crash would.
struct SimulatedCrash: Error {}

/// A thread-safe list of names for `@Sendable` stubs.
final class Names: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func append(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

/// The descriptors open in this process.
func openDescriptors() -> Int {
    (0..<min(getdtablesize(), 1 << 16)).filter { fcntl($0, F_GETFD) != -1 }.count
}

/// Runs `body` with the soft limit on open descriptors lowered to `headroom` above what is open
/// now — as a GUI app, which launchd gives 256, would run out.
func withDescriptorHeadroom<T>(_ headroom: Int, _ body: () throws -> T) throws -> T {
    var limit = rlimit()
    XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &limit), 0)
    let saved = limit
    limit.rlim_cur = rlim_t(openDescriptors() + headroom)
    XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limit), 0)
    defer {
        var restored = saved
        setrlimit(RLIMIT_NOFILE, &restored)
    }
    return try body()
}

/// A temporary home with two signed-in profiles — Personal (account A, the default profile)
/// and Work (account B) — and one copyable session in Personal, plus every seam a copy takes.
/// Nothing here touches the real `~/.claude`, Application Support or `~/.config`.
///
/// The session's transcript has a referenced subagent transcript, a live Remote Control
/// pointer (so the copy gets a clearing line) and a torn last line (so the copy is cut).
final class CopyFixture: @unchecked Sendable {
    let home: FakeHome
    let storeA: SessionStoreFolder
    let storeB: SessionStoreFolder
    let cwd: String
    let journalDirectory: URL

    static let personal = Profile(id: "default", label: "Personal")
    static let work = Profile(id: "work", label: "Work", userDataDir: "~/Library/Application Support/Claude-work")
    var personal: Profile { Self.personal }
    var work: Profile { Self.work }
    var profiles: [Profile] { [personal, work] }

    static let x = "c1c1c1c1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let sourceUUID = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    var x: String { Self.x }
    var sourceID: String { "local_" + Self.sourceUUID }
    var newID = UUID(uuidString: "9E9E9E9E-1234-4567-89AB-0123456789AB")!
    var y: String { newID.uuidString.lowercased() }
    let now = Date(timeIntervalSince1970: 1_759_660_000.5)
    var nowMilliseconds: Int64 { 1_759_660_000_500 }

    // Seams; a test changes them before calling `copy()`.
    var holdsLock = true
    var expectedUID = getuid()
    var freeBytes: UInt64? = 1 << 40
    var alive: @Sendable (Int32, String?) -> Bool = { _, _ in true }
    var renameExclusive: @Sendable (Int32, String, Int32, String) -> Int32 = SessionCopy.Environment.renameExclusively
    var hook: (SessionCopy.Step) throws -> Void = { _ in }
    /// An errno for a flush to fail with, or 0.
    var failFlush: (FileEvent.Flush, FileEvent.Flushed) -> Int32 = { _, _ in 0 }
    /// Stands the project folder and the target store on two volumes.
    var separateVolumes = false
    private(set) var steps: [SessionCopy.Step] = []
    private(set) var pauses: [Double] = []
    /// Every flush, create and rename, in order.
    var events: [FileEvent] = []

    static let defaultLines = [
        #"{"type":"user","sessionId":"\#(x)","uuid":"u1","message":{"role":"user","content":"Fix the build"}}"#,
        #"{"type":"assistant","sessionId":"\#(x)","uuid":"u2","toolUseResult":{"agentId":"a1","status":"completed"}}"#,
        #"{"type":"bridge-session","sessionId":"\#(x)","bridgeSessionId":"session_remote_1","lastSequenceNum":4}"#,
        #"{"type":"user","sessionId":"\#(x)","uuid":"u3","message":{"role":"user","content":"thanks"}}"#,
    ]
    static let defaultTail = #"{"type":"assistant","sessionId":"c1c1c1c1-aaaa-4aaa-8aaa-aaaaaaaaaaaa","uuid":"u4","mess"#
    static let agentLine = #"{"type":"user","agentId":"a1","message":"go"}"#

    /// Account-bound values a source record may carry. None may reach the copy's record.
    static var accountBound: [String: Any] { [
        "permissionMode": "bypassPermissions", "chromePermissionMode": "skip_all_permission_checks",
        "titleSource": "LEAK-title-source", "bridgeSessionIds": ["LEAK-bridge"], "emailAddress": "LEAK@example.com",
        "spawnSeed": "LEAK-seed", "enabledMcpTools": ["LEAK-tool": true], "remoteMcpServersConfig": ["LEAK-server": "x"],
        "envScopeId": "LEAK-scope", "spaceId": "LEAK-space", "adoptedFromOtherSurface": true, "surfaceNoticeUuid": "LEAK-notice",
        "importedFrom": "LEAK-import", "sessionPermissionUpdates": [["rule": "LEAK-rule"]], "alwaysAllowedReasons": ["LEAK-reason"],
        "lastFocusedAt": 123, "interruptedByQuitAt": 456, "rewindEdges": [["LEAK-edge": "x"]],
    ] }

    let lines: [String]
    let tail: String

    init(lines: [String] = CopyFixture.defaultLines, tail: String = CopyFixture.defaultTail,
         record extra: [String: Any] = [:], subagents: Bool = true) throws {
        home = try FakeHome()
        storeA = try home.signIn(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        storeB = try home.signIn(userDataDir: Self.work.userDataDir, account: FakeHome.accountB, org: FakeHome.orgB)
        cwd = try home.makeDirectory("work/app")
        journalDirectory = home.root.appendingPathComponent(".config/claude-switcher/copies", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        self.lines = lines
        self.tail = tail

        var fields: [String: Any] = [
            "sessionId": "local_" + Self.sourceUUID, "cliSessionId": Self.x, "cwd": cwd, "originCwd": cwd,
            "title": "Fix the build", "model": "claude-opus-5-5", "effort": "high", "isArchived": false,
            "createdAt": 1_700_000_000_000, "lastActivityAt": 1_700_000_100_000,
        ]
        for (key, value) in Self.accountBound { fields[key] = value }
        for (key, value) in extra { fields[key] = value }
        try home.writeRecord(fields, in: storeA)

        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        try sourceBytes.write(to: transcriptURL)
        // Saved tool output of the original, never copied.
        try write("out", to: projectFolder.appendingPathComponent("\(Self.x)/tool-results/r1.txt"))
        if subagents {
            try write(Self.agentLine + "\n" + #"{"type":"assist"#, to: agentURL("a1"))
            try write("{}", to: subagentsFolder.appendingPathComponent("agent-a1.meta.json"))
            try write("{\"unreferenced\":1}\n", to: agentURL("zz"))
        }
    }

    // MARK: Paths

    var projectFolder: URL {
        TranscriptLocator.projectsDirectory(home: home.home).appendingPathComponent(TranscriptLocator.projectSlug(forCwd: cwd))
    }
    var transcriptURL: URL { projectFolder.appendingPathComponent(Self.x + ".jsonl") }
    var subagentsFolder: URL { projectFolder.appendingPathComponent("\(Self.x)/subagents") }
    func agentURL(_ id: String) -> URL { subagentsFolder.appendingPathComponent("agent-\(id).jsonl") }
    var copyURL: URL { projectFolder.appendingPathComponent(y + ".jsonl") }
    var copiedAgentURL: URL { projectFolder.appendingPathComponent("\(y)/subagents/agent-a1.jsonl") }
    var recordURL: URL { storeB.url.appendingPathComponent("local_\(y).json") }
    var journalURL: URL { journalDirectory.appendingPathComponent(y + ".json") }
    var names: StagingNames { StagingNames(id: y) }
    var stagedTranscriptURL: URL { projectFolder.appendingPathComponent(names.transcript) }
    var stagingFolderURL: URL { projectFolder.appendingPathComponent(names.directory) }
    var stagedRecordURL: URL { storeB.url.appendingPathComponent(names.record) }

    /// `url` relative to the home, as ``TreeSnapshot`` names it.
    func rel(_ url: URL) -> String { String(url.path.dropFirst(home.root.path.count + 1)) }

    /// Everything a copy stages, relative to the home.
    var stagingPaths: Set<String> {
        let directory = projectFolder.appendingPathComponent(names.directory)
        return [
            rel(projectFolder.appendingPathComponent(names.transcript)), rel(directory),
            rel(directory.appendingPathComponent("subagents")), rel(directory.appendingPathComponent("subagents/agent-a1.jsonl")),
            rel(storeB.url.appendingPathComponent(names.record)),
        ]
    }

    /// The entries a successful copy adds, besides its journal.
    var finalPaths: Set<String> {
        [rel(copyURL), rel(projectFolder.appendingPathComponent(y)), rel(projectFolder.appendingPathComponent("\(y)/subagents")),
         rel(copiedAgentURL), rel(recordURL)]
    }

    // MARK: Content

    var sourceBytes: Data { Data((lines.joined(separator: "\n") + "\n" + tail).utf8) }

    /// What the copy's transcript must be: the source up to its last line feed, then one
    /// clearing line per live Remote Control pointer.
    var expectedCopy: Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
            + Data(#"{"type":"bridge-session","sessionId":"\#(Self.x)","bridgeSessionId":"","lastSequenceNum":0}"#.utf8 + [0x0A])
    }

    var sourceRecord: SessionRecord {
        get throws {
            let data = try Data(contentsOf: storeA.url.appendingPathComponent(sourceID + ".json"))
            return try XCTUnwrap(SessionStore.record(from: data, fileStem: sourceID))
        }
    }

    // MARK: Acting

    func environment() -> SessionCopy.Environment {
        var environment = SessionCopy.Environment(
            home: home.home, holdsAutomationLock: holdsLock, journalDirectory: journalDirectory,
            now: { [now] in now }, newID: { [unowned self] in self.newID }, expectedUID: expectedUID,
            isAlive: alive, freeBytes: { [unowned self] _ in self.freeBytes },
            renameExclusive: { [unowned self] a, b, c, d in self.renameExclusive(a, b, c, d) },
            pause: { [unowned self] seconds in self.pauses.append(seconds) },
            hook: { [unowned self] step in
                self.steps.append(step)
                try self.hook(step)
            })
        environment.fileEvent = { [unowned self] event in
            self.events.append(event)
            if case .flush(let kind, let what) = event { return self.failFlush(kind, what) }
            return 0
        }
        let separate = separateVolumes
        environment.sameVolume = { separate ? false : $0.device == $1.device }
        return environment
    }

    func request(cliSessionId: String? = nil, cwd: String? = nil, from source: Profile? = nil, to target: Profile? = nil) -> SessionCopy.Request {
        SessionCopy.Request(source: source ?? personal, target: target ?? work, sessionID: sourceID,
                            cliSessionId: cliSessionId ?? Self.x, cwd: cwd ?? self.cwd)
    }

    func copy(_ request: SessionCopy.Request? = nil, profiles: [Profile]? = nil) -> SessionCopy.Outcome {
        SessionCopy.copy(request ?? self.request(), allProfiles: profiles ?? self.profiles, environment: environment())
    }

    /// Copies with a hook that throws at `step`, then puts the hook back.
    func crash(at step: SessionCopy.Step) -> SessionCopy.Outcome {
        hook = { if $0 == step { throw SimulatedCrash() } }
        defer { hook = { _ in } }
        return copy()
    }

    @discardableResult
    func recover(profiles: [Profile]? = nil) -> [SessionCopy.RecoveryNote] {
        SessionCopy.recover(allProfiles: profiles ?? self.profiles, environment: environment())
    }

    func snapshot() -> TreeSnapshot { home.snapshot() }

    func journal() throws -> JournalEntry {
        try JSONDecoder().decode(JournalEntry.self, from: Data(contentsOf: journalURL))
    }

    var journalFiles: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: journalDirectory.path)) ?? []).sorted() }

    /// Rewrites the journal as JSON — for the fields a `JournalEntry` will not let a test set.
    func editJournal(_ body: (inout [String: Any]) throws -> Void) throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        try body(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: journalURL)
    }

    func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Signs Work out (Claude keeps the folder), or back in.
    func setWorkSignedIn(_ signedIn: Bool) throws {
        try home.writeConfig(["lastKnownAccountUuid": FakeHome.accountB, "windowSizeWasSignedIn": signedIn],
                             userDataDir: work.userDataDir)
    }
}

extension CopyFixture {
    /// The tree after a successful copy: exactly the copy's entries and its committed journal
    /// added, nothing removed, no existing file or folder replaced or changed — the original's
    /// transcript, its folder and the whole source store included — and the copy's bytes,
    /// modes and record as they must be.
    func assertIsASuccessfulCopy(before: TreeSnapshot, excluding excluded: String...,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let before = excluded.reduce(before) { $0.excluding($1) }
        let after = excluded.reduce(snapshot()) { $0.excluding($1) }
        let changes = after.changes(since: before)
        XCTAssertEqual(changes.added, finalPaths.union([rel(journalURL)]), after.difference(from: before), file: file, line: line)
        XCTAssertEqual(changes.removed, [], file: file, line: line)
        XCTAssertEqual(changes.changed, [], after.difference(from: before), file: file, line: line)

        XCTAssertEqual(try Data(contentsOf: copyURL), expectedCopy, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: copiedAgentURL), Data((Self.agentLine + "\n").utf8), file: file, line: line)
        let expectedRecord = CopyRecord.bytes(forCopyOf: try sourceRecord, newID: newID, now: now)
        XCTAssertEqual(try Data(contentsOf: recordURL), expectedRecord, file: file, line: line)
        XCTAssertEqual(try journal().phase, .committed, file: file, line: line)

        for path in [rel(copyURL), rel(copiedAgentURL), rel(recordURL), rel(journalURL)] {
            let entry = try XCTUnwrap(after.entry(path), path, file: file, line: line)
            XCTAssertEqual(entry.mode, 0o600, path, file: file, line: line)
            XCTAssertEqual(entry.linkCount, 1, path, file: file, line: line)
            XCTAssertEqual(entry.owner, getuid(), path, file: file, line: line)
        }
        for path in [rel(projectFolder.appendingPathComponent(y)), rel(projectFolder.appendingPathComponent("\(y)/subagents"))] {
            XCTAssertEqual(after.entry(path)?.mode, 0o700, path, file: file, line: line)
        }
    }
}
