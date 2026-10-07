import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// `state.json`, `handoff.json` and `starting.json`: written only as a new file put in place by
/// `rename`, read tolerantly, and ignored when another Mac wrote them.
final class SwitcherStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The live file system, with every call recorded.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var renameFailure: Int32?
        func add(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return calls }

        var files: StoreFileSystem {
            let live = StoreFileSystem.live
            return StoreFileSystem(
                read: live.read, exists: live.exists,
                createAndFlush: { path, data in self.add("create \((path as NSString).lastPathComponent)"); return live.createAndFlush(path, data) },
                rename: { from, to in
                    self.add("rename \((from as NSString).lastPathComponent) -> \((to as NSString).lastPathComponent)")
                    if let failure = self.renameFailure { return failure }
                    return live.rename(from, to)
                },
                unlink: { path in self.add("unlink \((path as NSString).lastPathComponent)"); return live.unlink(path) },
                makeDirectory: live.makeDirectory)
        }
    }

    func testEveryRecordIsWrittenAsANewTemporaryFileAndRenamedIntoPlace() async throws {
        let recorder = Recorder()
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host, files: recorder.files)
        try await store.save(SwitcherUpdateState())
        try await store.writeHandoff(UpdateFixture.handoff(.swapping))
        try await store.writeMarker(StartMarker(version: UpdateFixture.v070, host: UpdateFixture.host,
                                                installPath: UpdateFixture.install, count: 1, at: now))
        _ = try await store.recordStart(version: UpdateFixture.v070, installPath: UpdateFixture.install, now: now)
        try await store.update(now: now) { $0.staging = ["/x"] }

        let finals: Set<String> = ["state.json", "handoff.json", "starting.json"]
        let calls = recorder.values
        XCTAssertEqual(calls.count, 10)
        for call in calls where call.hasPrefix("create ") {
            let name = String(call.dropFirst("create ".count))
            XCTAssertFalse(finals.contains(name), "a record is never opened for writing in place: \(call)")
            XCTAssertTrue(name.hasPrefix(".") && name.hasSuffix(".tmp"), call)
        }
        for call in calls where call.hasPrefix("rename ") {
            let parts = call.dropFirst("rename ".count).components(separatedBy: " -> ")
            XCTAssertTrue(parts[0].hasPrefix(".") && parts[0].hasSuffix(".tmp"), call)
            XCTAssertTrue(finals.contains(parts[1]), call)
        }
        // Each create is followed by its own rename.
        for (index, call) in calls.enumerated() where call.hasPrefix("create ") {
            XCTAssertTrue(calls[index + 1].hasPrefix("rename " + call.dropFirst("create ".count)), "\(calls)")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["handoff.json", "starting.json", "state.json"])
    }

    func testAWriteThatCannotBePutInPlaceLeavesTheOldRecordAndNoTemporaryFile() async throws {
        let recorder = Recorder()
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host, files: recorder.files)
        var first = SwitcherUpdateState()
        first.staging = ["/first"]
        try await store.save(first)
        let before = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        recorder.renameFailure = EIO
        var second = SwitcherUpdateState()
        second.staging = ["/second"]
        do {
            try await store.save(second)
            XCTFail("the save should fail")
        } catch let error as StoreError {
            XCTAssertEqual(error.errno, EIO)
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("state.json")), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["state.json"])
    }

    /// A temporary file that was created but could not be flushed — a full disk — is not left behind.
    func testAWriteThatCannotBeCreatedLeavesNoTemporaryFile() async throws {
        let live = StoreFileSystem.live
        let files = StoreFileSystem(read: live.read, exists: live.exists,
                                    createAndFlush: { path, data in _ = live.createAndFlush(path, data); return ENOSPC },
                                    rename: live.rename, unlink: live.unlink, makeDirectory: live.makeDirectory)
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host, files: files)
        do {
            try await store.save(SwitcherUpdateState())
            XCTFail("the save should fail")
        } catch let error as StoreError {
            XCTAssertEqual(error.errno, ENOSPC)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    /// The live create writes, flushes past the drive's cache, and closes.
    func testTheLiveCreateWritesAndFlushesANewFile() throws {
        let path = directory.appendingPathComponent(".state.json.\(UUID().uuidString).tmp").path
        XCTAssertEqual(StoreFileSystem.live.createAndFlush(path, Data("{}\n".utf8)), 0)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{}\n")
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    /// Only the store's own temporary files are swept — by name, one file at a time — and never a
    /// record, a folder, or anything that merely looks similar.
    func testTheSweepRemovesOnlyTheStoresOwnTemporaryFiles() async throws {
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        try await store.save(SwitcherUpdateState())
        let swept = [".state.json.\(UUID().uuidString).tmp", ".starting.json.\(UUID().uuidString).tmp",
                     ".handoff.json.\(UUID().uuidString.lowercased()).tmp"]
        let kept = [".config.json.\(UUID().uuidString).tmp", ".state.json.1234.tmp", "notes.tmp",
                    ".state.json.\(UUID().uuidString).tmp.bak"]
        for name in swept + kept { try Data("x".utf8).write(to: directory.appendingPathComponent(name)) }
        let folder = ".handoff.json.\(UUID().uuidString).tmp"
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: false)
        await store.sweepTemporaryFiles()
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(left, Set(kept + [folder, "state.json"]))
    }

    func testTheLiveCreateNeverOpensAnExistingFileOrFollowsALink() throws {
        let existing = directory.appendingPathComponent("existing").path
        try Data("keep".utf8).write(to: URL(fileURLWithPath: existing))
        XCTAssertEqual(StoreFileSystem.live.createAndFlush(existing, Data("new".utf8)), EEXIST)
        XCTAssertEqual(try String(contentsOfFile: existing, encoding: .utf8), "keep")
        let link = directory.appendingPathComponent("link").path
        let target = directory.appendingPathComponent("target").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertNotEqual(StoreFileSystem.live.createAndFlush(link, Data("new".utf8)), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testSavingStampsThisMacAndTheFormat() async throws {
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        try await store.save(SwitcherUpdateState())
        let state = await store.read().value
        XCTAssertEqual(state?.host, UpdateFixture.host)
        XCTAssertEqual(state?.format, 1)
    }

    func testStateWrittenOnAnotherMacIsIgnoredAndNamed() async throws {
        let other = SwitcherUpdateStore(directory: directory, host: UpdateFixture.otherHost)
        var theirs = SwitcherUpdateState()
        theirs.rejected = [Rejection(tag: "v0.8.0", digestHex: UpdateFixture.digest, reason: "x", at: now)]
        theirs.staging = [UpdateFixture.staging]
        try await other.save(theirs)
        let file = directory.appendingPathComponent("state.json")
        let before = try Data(contentsOf: file)

        let mine = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        let loaded = await mine.load(now: now)
        XCTAssertNil(loaded.rejected)
        XCTAssertNil(loaded.staging)
        XCTAssertEqual(loaded.foreignRecordsSeen, true)
        XCTAssertEqual(try Data(contentsOf: file), before, "reading changes nothing")
    }

    func testAStateFileThatDoesNotReadStartsFresh() async throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent("state.json"))
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        guard case .unreadable = await store.read() else { return XCTFail() }
        let awaited1 = await store.load(now: now)
        XCTAssertEqual(awaited1, SwitcherUpdateState())
    }

    /// A field that does not read is dropped on its own; the rejections next to it survive.
    func testOneBadFieldDoesNotTakeTheRestOfTheStateWithIt() async throws {
        let json = """
        {"format": 1, "host": "\(UpdateFixture.host)",
         "candidate": {"version": "0.8.0", "tag": "v0.8.0/../../x", "assetSize": 5, "digestHex": "\(UpdateFixture.digest)"},
         "rejected": [{"tag": "v0.8.0", "digestHex": "\(UpdateFixture.digest)", "reason": "x", "at": "2026-10-05T10:00:00Z"}],
         "nextCheckNotBefore": "yesterday",
         "staging": 42}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("state.json"))
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        let state = await store.load(now: now)
        XCTAssertNil(state.candidate)
        XCTAssertNil(state.nextCheckNotBefore)
        XCTAssertNil(state.staging)
        XCTAssertEqual(state.rejected?.first?.tag, "v0.8.0", "a hand-written date without a fraction still reads")
    }

    /// A staging folder written as one path — before each copy's folder had an entry of its own —
    /// still reads, as the one folder it names.
    func testAStagingFolderWrittenAsOnePathStillReads() async throws {
        let json = """
        {"format": 1, "host": "\(UpdateFixture.host)", "staging": "\(UpdateFixture.staging)"}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("state.json"))
        let state = await SwitcherUpdateStore(directory: directory, host: UpdateFixture.host).load(now: now)
        XCTAssertEqual(state.staging, [UpdateFixture.staging])
    }

    func testRecordsRoundTrip() async throws {
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        var state = SwitcherUpdateState()
        state.candidate = UpdateFixture.candidate()
        state.prepared = UpdateFixture.prepared()
        state.lastCheckResult = .rateLimited(until: now)
        state.lastCheckAt = now
        state.attempts = ["k": AttemptRecord(count: 2, lastStep: "attach", nextNotBefore: now)]
        state.lastInstall = InstallRecord(from: UpdateFixture.v070, to: UpdateFixture.v080, at: now,
                                          oldCopy: OldCopy(kind: .previous, path: "/p"), tag: "v0.8.0", digest: UpdateFixture.digest)
        state.notice = SwitcherNotice(text: "t", tooltip: "tt")
        try await store.save(state)
        var expected = state
        expected.host = UpdateFixture.host
        expected.format = 1
        let awaited2 = await store.load(now: now)
        XCTAssertEqual(awaited2, expected)

        let handoff = UpdateFixture.handoff(.restartPending, failure: "x")
        try await store.writeHandoff(handoff)
        let awaited3 = await store.loadHandoff()
        XCTAssertEqual(awaited3, .record(handoff))
        try await store.archiveFailedHandoff()
        let awaited4 = await store.loadHandoff()
        XCTAssertEqual(awaited4, .absent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("handoff.failed.json").path))
    }

    /// The detached prepare and the main actor write through one actor; no update is lost.
    func testConcurrentUpdatesAreSerialised() async throws {
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        let now = self.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    _ = try? await store.update(now: now) {
                        $0.consecutivePermanentRejections = ($0.consecutivePermanentRejections ?? 0) + 1
                    }
                }
            }
        }
        let awaited5 = await store.load(now: now).consecutivePermanentRejections
        XCTAssertEqual(awaited5, 40)
    }

    /// A start that got going removes its own marker, and only that: a marker another version
    /// or another Mac wrote since carries a count of its own.
    func testASettledStartRemovesOnlyItsOwnMarker() async throws {
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        _ = try await store.recordStart(version: UpdateFixture.v080, installPath: UpdateFixture.install, now: now)
        try await store.settleStart(version: UpdateFixture.v070)
        let otherVersion = await store.loadMarker().value
        XCTAssertEqual(otherVersion?.version, UpdateFixture.v080, "another version's marker is left alone")
        try await store.settleStart(version: nil)
        let noVersion = await store.loadMarker().value
        XCTAssertNotNil(noVersion, "a copy that cannot read its version settles nothing")
        try await store.settleStart(version: UpdateFixture.v080)
        let settled = await store.loadMarker()
        XCTAssertEqual(settled, .absent)

        let other = SwitcherUpdateStore(directory: directory, host: UpdateFixture.otherHost)
        _ = try await other.recordStart(version: UpdateFixture.v080, installPath: UpdateFixture.install, now: now)
        try await store.settleStart(version: UpdateFixture.v080)
        let foreign = await store.loadMarker().value
        XCTAssertEqual(foreign?.host, UpdateFixture.otherHost, "another Mac's marker is left alone")
    }

    /// `--dry-run` reads without the actor and must see exactly what the app would.
    func testTheSnapshotReadsWhatLoadReads() async throws {
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        XCTAssertEqual(store.snapshot(now: now), SwitcherUpdateState())
        var state = SwitcherUpdateState()
        state.lastCheckAt = now
        state.nextCheckNotBefore = now.addingTimeInterval(400 * 24 * 3600)
        state.candidate = UpdateFixture.candidate()
        try await store.save(state)
        let loaded = await store.load(now: now)
        XCTAssertEqual(store.snapshot(now: now), loaded)
        XCTAssertNil(store.snapshot(now: now).nextCheckNotBefore, "dates too far ahead are dropped here too")

        let mine = SwitcherUpdateStore(directory: directory, host: UpdateFixture.otherHost)
        XCTAssertEqual(mine.snapshot(now: now).foreignRecordsSeen, true)
        XCTAssertNil(mine.snapshot(now: now).candidate)
    }

    func testTheUpdatesFolderSitsBesideConfigJSON() {
        XCTAssertEqual(SwitcherUpdateStore.directoryURL.deletingLastPathComponent(), Config.configURL.deletingLastPathComponent())
        XCTAssertEqual(SwitcherUpdateStore.directoryURL.lastPathComponent, "updates")
    }

    func testThisMacHasAStableHardwareIdentifier() {
        let id = SwitcherHost.id()
        XCTAssertEqual(id, SwitcherHost.id())
        XCTAssertNotNil(UUID(uuidString: id))
    }
}

// MARK: - The relaunch and the lock (9.1, 9.2)

@MainActor
final class SwitcherRelaunchTests: XCTestCase {

    @MainActor private final class World {
        var answers: [AutomationLock.Acquisition]
        var takes = 0
        var slept = Duration.zero
        var events: [String] = []
        init(_ answers: [AutomationLock.Acquisition]) { self.answers = answers }

        var env: SwitcherRelaunch.StartupEnvironment {
            SwitcherRelaunch.StartupEnvironment(
                take: {
                    self.takes += 1
                    self.events.append("take")
                    if self.takes > 1000 {
                        XCTFail("the lock was retried without a bound")
                        return .acquired(1)
                    }
                    return self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0]
                },
                sleep: { self.slept += $0 },
                now: { Date(timeIntervalSince1970: 1_791_000_000) },
                recordFinding: { self.events.append("finding: \($0)") },
                withdrawStart: { self.events.append("withdraw start") },
                terminateSelf: { self.events.append("terminate") },
                showStatusItem: { self.events.append("status item") })
        }
    }

    func testTheOldPidIsReadOnlyWhenItIsAPlausiblePid() {
        XCTAssertEqual(SwitcherRelaunch.afterUpdatePID(in: ["claude-switcher", "--after-update", "4242"]), 4242)
        for arguments in [["--after-update"], ["--after-update", "1"], ["--after-update", "0"], ["--after-update", "-7"],
                          ["--after-update", "abc"], ["--after-update", "99999999999"], ["--dry-run"], []] {
            XCTAssertNil(SwitcherRelaunch.afterUpdatePID(in: arguments), "\(arguments)")
        }
        XCTAssertEqual(SwitcherRelaunch.launchArguments(oldPID: 4242), ["--after-update", "4242"])
    }

    func testWithoutAfterUpdateThereIsOneTakeAndNoRetry() async {
        let world = World([.heldElsewhere])
        let outcome = await SwitcherRelaunch.start(launchedAfterUpdate: nil, env: world.env)
        XCTAssertEqual(outcome, .lock(.heldElsewhere))
        XCTAssertEqual(world.takes, 1)
        XCTAssertEqual(world.slept, .zero)
        XCTAssertEqual(world.events, ["take", "status item"])
    }

    func testAfterAnUpdateTheLockIsRetriedAndTheIconAppearsOnlyOnceItIsHeld() async {
        let world = World(Array(repeating: .heldElsewhere, count: 7) + [.acquired(9)])
        let outcome = await SwitcherRelaunch.start(launchedAfterUpdate: 4242, env: world.env)
        XCTAssertEqual(outcome, .lock(.acquired(9)))
        XCTAssertEqual(world.takes, 8)
        XCTAssertEqual(world.slept, .milliseconds(250 * 7))
        XCTAssertEqual(world.events.last, "status item")
        XCTAssertEqual(world.events.filter { $0 == "status item" }.count, 1)
        XCTAssertFalse(world.events.contains("terminate"))
    }

    /// Never two icons: an instance started after an update that cannot get the lock within a
    /// minute exits without one, says why, and takes back its start.
    func testAfterAnUpdateALockHeldForTheWholeMinuteEndsThisInstanceWithoutAnIcon() async {
        let world = World([.heldElsewhere])
        let outcome = await SwitcherRelaunch.start(launchedAfterUpdate: 4242, env: world.env)
        guard case .exiting(let finding) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(finding.hasPrefix("a relaunch at "))
        XCTAssertTrue(finding.hasSuffix(" found pid 4242 still running and exited"))
        XCTAssertFalse(world.events.contains("status item"))
        XCTAssertEqual(world.slept, .seconds(60))
        XCTAssertEqual(world.takes, 241)
        XCTAssertEqual(Array(world.events.suffix(3)), ["finding: \(finding)", "withdraw start", "terminate"])
    }

    func testALockFileThatCannotBeOpenedDoesNotStopTheStart() async {
        let world = World([.unavailable(errno: EACCES)])
        let outcome = await SwitcherRelaunch.start(launchedAfterUpdate: 4242, env: world.env)
        XCTAssertEqual(outcome, .lock(.unavailable(errno: EACCES)))
        XCTAssertEqual(world.takes, 1)
        XCTAssertEqual(world.events.last, "status item")
    }

    func testALaunchThatNeverAnswersTimesOutAndALateAnswerIsIgnored() async {
        let late = Names()
        let result = await SwitcherRelaunch.awaitLaunch(deadline: 0.05) { answer in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                late.append("late")
                answer(.success(77))
            }
        }
        XCTAssertEqual(result, .failure(RelaunchFailure(reason: "it did not start within 0 seconds")))
        let quick = await SwitcherRelaunch.awaitLaunch(deadline: 5) { answer in answer(.success(4300)) }
        XCTAssertEqual(quick, .success(4300))
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(late.values, ["late"])
    }
}

// MARK: - What the updater can reach (environment hygiene)

final class SwitcherHygieneTests: XCTestCase {

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ folder: String) throws -> [(String, String)] {
        let directory = Self.repository.appendingPathComponent(folder)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }.sorted()
            .map { ($0, try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)) }
    }

    private func labels(_ value: Any) -> [String] { Mirror(reflecting: value).children.compactMap(\.label) }

    /// No seam the updater is given can name Claude, or end, signal or kill anything but itself.
    func testNoSeamCanReachClaudeOrEndAnotherProcess() {
        let environments: [(String, Any)] = [
            ("commit", FakeCommit().env), ("prepare", FakePrepare().env),
            ("check", SwitcherUpdater.CheckEnvironment(fetch: { _ in .transport("x") }, now: { Date() })),
        ]
        for (name, environment) in environments {
            let names = labels(environment)
            XCTAssertFalse(names.isEmpty, name)
            for label in names {
                let lowered = label.lowercased()
                XCTAssertFalse(lowered.contains("claude"), "\(name).\(label)")
                XCTAssertFalse(lowered.contains("kill"), "\(name).\(label)")
                XCTAssertFalse(lowered.contains("signal"), "\(name).\(label)")
                if lowered.contains("terminate") { XCTAssertEqual(label, "terminateSelf", "\(name).\(label)") }
            }
        }
        XCTAssertEqual(labels(FakeCommit().env).filter { $0.hasPrefix("launch") }, ["launch", "launchAtLoginIsEnabled"])
    }

    /// The real commit environment lives in the app target, which the tests cannot import: the
    /// tests can never swap the installed app or relaunch it.
    func testTheRealCommitEnvironmentIsNotInTheLibraryTheTestsLinkAgainst() throws {
        for (name, text) in try source("Sources/ClaudeSwitcherCore") {
            XCTAssertFalse(text.contains("extension SwitcherUpdater.CommitEnvironment"), name)
            XCTAssertFalse(text.contains("CommitEnvironment.live"), name)
            if name.hasPrefix("Switcher") { XCTAssertFalse(text.contains("NSWorkspace"), name) }
        }
    }

    /// The updater's own files start one kind of process — a tool by absolute path — and name no
    /// way to quit, signal or script anything.
    func testTheUpdatersFilesNameNoWayToQuitSignalOrScriptAnything() throws {
        var processes = 0
        for (name, text) in try source("Sources/ClaudeSwitcherCore") where name.hasPrefix("Switcher") {
            for forbidden in ["kill(", "NSRunningApplication", "InstanceManager", "forceTerminate", ".terminate(",
                              "NSAppleScript", "AEDesc", "com.anthropic", "/usr/bin/open", "/bin/sh", "posix_spawn",
                              "UpdateInstaller", "claudefordesktop"] {
                XCTAssertFalse(text.contains(forbidden), "\(name) contains \(forbidden)")
            }
            processes += text.components(separatedBy: "Process()").count - 1
        }
        XCTAssertEqual(processes, 1, "only SwitcherProcess.run starts a process")
    }

    /// An old process may keep running after the swap only because nothing is loaded lazily from
    /// its bundle, which by then holds the new version.
    func testTheAppLoadsNothingLazilyFromItsBundle() throws {
        for (name, text) in try source("Sources/ClaudeSwitcher") {
            for forbidden in ["Bundle.main.url(forResource", "Bundle.main.path(forResource", "NSImage(named",
                              "Bundle.main.infoDictionary", "Bundle.main.object(forInfoDictionaryKey",
                              "Bundle.main.localizedString", "NSLocalizedString"] {
                XCTAssertFalse(text.contains(forbidden), "\(name) contains \(forbidden)")
            }
        }
    }

    /// Every process the real prepare environment would start: an absolute path to one of three
    /// system tools, an empty environment, stdin from /dev/null. None is actually started.
    func testEveryProcessTheLivePrepareStartsIsAbsoluteWithAnEmptyEnvironmentAndNoInput() throws {
        let seen = Launches()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hygiene-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = SwitcherUpdater.PrepareEnvironment.live(
            updatesDirectory: directory, store: SwitcherUpdateStore(directory: directory, host: UpdateFixture.host),
            registry: StagedCopies(), processObserver: { seen.add($0); return false })
        _ = env.imageHasLicense(directory.path + "/x.dmg")
        _ = env.attach(directory.path + "/x.dmg", directory.path + "/mounts")
        _ = env.attachedImages()
        _ = env.detach("/dev/disk99")
        _ = env.assess(directory.path + "/x.app")
        env.prewarm(directory.path + "/x.app")
        XCTAssertFalse(env.detach("disk99; rm -rf /"), "only a disk device is ever named")

        let launches = seen.values
        XCTAssertGreaterThanOrEqual(launches.count, 5)
        for launch in launches {
            XCTAssertTrue(["/usr/bin/hdiutil", "/usr/sbin/spctl", "/usr/bin/gktool"].contains(launch.executablePath ?? ""),
                          "\(launch)")
            XCTAssertEqual(launch.environment, [:], "\(launch)")
            XCTAssertEqual(launch.standardInputPath, "/dev/null", "\(launch)")
        }
        XCTAssertEqual(launches.filter { $0.arguments.first == "attach" }.first?.arguments,
                       ["attach", "-plist", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom",
                        directory.path + "/mounts", directory.path + "/x.dmg"])
        XCTAssertEqual(launches.filter { $0.executablePath == "/usr/sbin/spctl" }.first?.arguments,
                       ["--assess", "--type", "execute", "--raw", directory.path + "/x.app"])
    }

    // MARK: - The app's wiring, pinned in its source
    //
    // The app target cannot be imported by a test target on every toolchain (Package.swift), so
    // these decisions are pinned where they are made. Each names the line a refactor must keep.

    /// The text of `func <name>(…) { … }` in `text`, braces matched.
    private func body(of name: String, in text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let signature = text.range(of: "func \(name)("),
              let open = text[signature.upperBound...].firstIndex(of: "{") else {
            XCTFail("no func \(name)", file: file, line: line)
            return ""
        }
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            default: break
            }
            index = text.index(after: index)
        }
        XCTFail("unbalanced func \(name)", file: file, line: line)
        return ""
    }

    private func shell(_ name: String) throws -> String {
        try XCTUnwrap(source("Sources/ClaudeSwitcher").first { $0.0 == name }?.1, name)
    }

    /// `--dry-run` fetches nothing: the running copy's notarization is asked offline.
    func testTheDryRunAsksForNotarizationOffline() throws {
        let main = try shell("main.swift")
        let calls = main.components(separatedBy: "runningNotarization(").dropFirst()
        XCTAssertEqual(calls.count, 1)
        for call in calls {
            XCTAssertTrue(call.prefix(80).contains("flags: CodeSignature.offlineFlags"), String(call.prefix(80)))
        }
    }

    /// The end of a commit that did not relaunch is never a cause of a Claude launch.
    func testTheEndOfACommitNeverStartsClaudesReopenPass() throws {
        let finish = body(of: "switcherCommitDidFinish", in: try shell("AppDelegate.swift"))
        XCTAssertFalse(finish.isEmpty)
        for forbidden in ["outsideTriggerForReopen", "considerReopenAfterUpdate", "UpdateReopen"] {
            XCTAssertFalse(finish.contains(forbidden), forbidden)
        }
    }

    /// Never two icons: the status item is put up only by the start-up sequence, once the lock is
    /// settled — an instance started after an update that cannot take it ends unseen.
    func testTheIconIsShownOnlyOnceTheLockIsSettled() throws {
        let app = try shell("AppDelegate.swift")
        let calls = app.components(separatedBy: "installStatusItem()").count - 1
        XCTAssertEqual(calls, 2, "its definition and one call")
        XCTAssertTrue(body(of: "startupEnvironment", in: app).contains("showStatusItem: { [weak self] in self?.installStatusItem() }"))
        XCTAssertTrue(body(of: "finishLaunching", in: app).contains("SwitcherRelaunch.start(launchedAfterUpdate: launchedAfterUpdate"))
    }

    /// Only the copy holding the lock replaces itself: the commit's preconditions are asked with
    /// the real lock, never a literal.
    func testOnlyTheLockHolderCommits() throws {
        let app = try shell("AppDelegate.swift")
        let consider = body(of: "considerSwitcherInstall", in: app)
        XCTAssertTrue(consider.contains("isLockHolder: automationLock != nil"))
        XCTAssertTrue(consider.contains("SwitcherShellGate.considersInstall("))
        XCTAssertTrue(consider.contains("isReconciling: isReconcilingSwitcherUpdates"))
        XCTAssertTrue(body(of: "requestSwitcherCommit", in: app).contains("guard automationLock != nil else"))
        for name in ["considerSwitcherInstall", "switcherCommitHoldReason"] {
            XCTAssertFalse(body(of: name, in: app).contains("isLockHolder: true"), name)
        }
    }

    /// The gates the app asks are the tested ones, with the real facts.
    func testTheChecksAreGatedByTheTestedRules() throws {
        let app = try shell("AppDelegate.swift")
        let automatic = try XCTUnwrap(app.range(of: "private var automaticSwitcherChecksRun: Bool {")).upperBound
        let gate = String(app[automatic...].prefix(600))
        XCTAssertTrue(gate.contains("SwitcherShellGate.automaticChecksRun("))
        XCTAssertTrue(gate.contains("isLockHolder: automationLock != nil"))
        XCTAssertTrue(gate.contains("isReconciling: isReconcilingSwitcherUpdates"))
        let manual = body(of: "checkForSwitcherUpdates", in: app)
        XCTAssertTrue(manual.contains("SwitcherShellGate.manualCheckRuns("))
        XCTAssertTrue(manual.contains("isReconciling: isReconcilingSwitcherUpdates"))
        // The launch pass holds them back from before it is scheduled until it has reported.
        let launch = body(of: "finishLaunching", in: app)
        let set = try XCTUnwrap(launch.range(of: "isReconcilingSwitcherUpdates = true"))
        let pass = try XCTUnwrap(launch.range(of: "reconcileSwitcherUpdates()"))
        XCTAssertLessThan(set.lowerBound, pass.lowerBound)
        XCTAssertTrue(body(of: "applyLaunchReport", in: app).contains("isReconcilingSwitcherUpdates = false"))
    }

    /// Quit waits for a commit, and every way out lets go of a verified copy kept for one.
    func testQuittingLetsGoOfAKeptCopy() throws {
        let app = try shell("AppDelegate.swift")
        let quit = body(of: "quit", in: app)
        XCTAssertTrue(quit.contains("guard SwitcherShellGate.canQuit(isCommitting: isCommittingSwitcherUpdate) else { return }"))
        let discard = try XCTUnwrap(quit.range(of: "discardKeptSwitcherUpdate()"))
        let terminate = try XCTUnwrap(quit.range(of: "NSApp.terminate(nil)"))
        XCTAssertLessThan(discard.lowerBound, terminate.lowerBound)
        XCTAssertTrue(body(of: "applicationWillTerminate", in: app).contains("discardKeptSwitcherUpdate()"))
        let kept = body(of: "discardKeptSwitcherUpdate", in: app)
        XCTAssertTrue(kept.contains("!isCommittingSwitcherUpdate"), "never the copy a commit is swapping in")
        XCTAssertTrue(kept.contains("SwitcherUpdater.discardStagedOnly(prepared, env: prepareEnvironment())"))
    }

    /// Only the lock holder's settled start deletes the record of the update.
    func testOnlyTheLockHolderSettlesTheRecordOfTheUpdate() throws {
        let settle = body(of: "settleStartAfterSteadyState", in: try shell("AppDelegate.swift"))
        XCTAssertTrue(settle.contains("settleStart(version: version, isLockHolder: self.automationLock != nil)"))
    }

    /// Both real environments check signatures through the one shared, tested verifier.
    func testBothRealEnvironmentsUseTheSharedSignatureCheck() throws {
        XCTAssertTrue(try shell("SwitcherUpdates.swift").contains("verify: CodeSignature.verifier(),"))
        for (name, text) in try source("Sources/ClaudeSwitcher") {
            XCTAssertFalse(text.contains("CodeSignature.verify(bundleAt:"), name)
        }
        let live = try XCTUnwrap(source("Sources/ClaudeSwitcherCore").first { $0.0 == "SwitcherUpdaterLive.swift" }?.1)
        XCTAssertTrue(live.contains("verify: CodeSignature.verifier(flags: verifyFlags),"))
    }

    private final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var launches: [ProcessLaunch] = []
        func add(_ launch: ProcessLaunch) { lock.lock(); launches.append(launch); lock.unlock() }
        var values: [ProcessLaunch] { lock.lock(); defer { lock.unlock() }; return launches }
    }
}
