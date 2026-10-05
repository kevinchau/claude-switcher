import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// The descriptor-based file-system layer. Everything happens under a temporary home.
final class HeldDirectoryTests: XCTestCase {

    private var home: URL!
    private var uid: uid_t { getuid() }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-switcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Undo any chmod a test left, so the tree can be removed.
        if let enumerator = FileManager.default.enumerator(atPath: home.path) {
            for case let path as String in enumerator {
                chmod(home.appendingPathComponent(path).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func makeDirectory(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func link(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(relative).path,
                                                   withDestinationPath: destination)
    }

    private func reason(_ body: () throws -> Void) -> FileSystemError.Reason? {
        do { try body(); return nil } catch let error as FileSystemError { return error.reason } catch { return .system }
    }

    // MARK: - The walk

    func testTheWalkReachesARealPathAndHoldsIt() throws {
        try makeDirectory(".claude/projects/-Users-me-app")
        let held = try HeldDirectory.walk(to: home.path + "/.claude/projects/-Users-me-app", home: home.path, expectedOwner: uid)
        XCTAssertEqual(held.status.kind, .directory)
        XCTAssertEqual(held.status.identity, FileStatus.ofPath(home.path + "/.claude/projects/-Users-me-app")?.identity)
    }

    /// A link at any component from the home directory down is refused — `~/.claude` included
    /// (spec D2) — and nothing is created through it.
    func testALinkAtAnyComponentBelowHomeIsRefused() throws {
        let path = ".claude/projects/-Users-me-app"
        let components = [".claude", ".claude/projects", path]
        for linked in components {
            let elsewhere = home.appendingPathComponent("elsewhere-\(components.firstIndex(of: linked)!)")
            try makeDirectory(path)
            // Move the real folder away and leave a link to it under the old name.
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let moved = elsewhere.appendingPathComponent("target")
            try FileManager.default.moveItem(at: home.appendingPathComponent(linked), to: moved)
            try link(linked, to: moved.path)
            let before = TreeSnapshot(of: home)

            XCTAssertEqual(reason { _ = try HeldDirectory.walk(to: home.path + "/" + path, home: self.home.path, expectedOwner: self.uid) },
                           .linkOrNotDirectory, linked)
            XCTAssertEqual(TreeSnapshot(of: home), before, linked)

            try FileManager.default.removeItem(at: home.appendingPathComponent(".claude"))
            try FileManager.default.removeItem(at: elsewhere)
        }
    }

    func testAFileWhereAFolderShouldBeIsRefused() throws {
        try write("x", to: ".claude")
        XCTAssertEqual(reason { _ = try HeldDirectory.walk(to: home.path + "/.claude/projects", home: self.home.path, expectedOwner: self.uid) },
                       .linkOrNotDirectory)
    }

    func testAMissingComponentIsAbsent() throws {
        XCTAssertEqual(reason { _ = try HeldDirectory.walk(to: home.path + "/.claude/projects", home: self.home.path, expectedOwner: self.uid) },
                       .absent)
    }

    /// A folder owned by anyone but the expected user is refused — the home anchor included.
    func testAForeignOwnerIsRefused() throws {
        try makeDirectory(".claude/projects")
        XCTAssertEqual(reason { _ = try HeldDirectory.walk(to: home.path + "/.claude/projects", home: self.home.path, expectedOwner: self.uid + 1) },
                       .notOwnedByUser)
        let held = try HeldDirectory.walk(to: home.path + "/.claude", home: home.path, expectedOwner: uid)
        XCTAssertEqual(reason { _ = try held.openDirectory("projects", expectedOwner: self.uid + 1) }, .notOwnedByUser)
        XCTAssertEqual(reason { try held.requireOwned(by: self.uid + 1) }, .notOwnedByUser)
    }

    func testAFolderOthersCanWriteToIsRefusedForWriting() throws {
        for mode: mode_t in [0o770, 0o707, 0o775, 0o757] {
            let folder = try makeDirectory("open-\(String(mode, radix: 8))")
            chmod(folder.path, mode)
            let held = try HeldDirectory.walk(to: folder.path, home: home.path, expectedOwner: uid)
            XCTAssertEqual(reason { try held.requireNotWritableByOthers() }, .writableByOthers, String(mode, radix: 8))
        }
        let closed = try makeDirectory("closed")
        chmod(closed.path, 0o755)
        XCTAssertNil(reason { try HeldDirectory.walk(to: closed.path, home: self.home.path, expectedOwner: self.uid).requireNotWritableByOthers() })
    }

    func testAPathOutsideHomeIsItsOwnAnchorAndDotDotIsNeverAComponent() throws {
        let outside = try HeldDirectory.anchorAndComponents(of: "/Volumes/Data/Claude-work", home: "/Users/me")
        XCTAssertEqual(outside.anchor, "/Volumes/Data/Claude-work")
        XCTAssertEqual(outside.components, [])
        let inside = try HeldDirectory.anchorAndComponents(of: "/Users/me/.claude/projects", home: "/Users/me/")
        XCTAssertEqual(inside.anchor, "/Users/me")
        XCTAssertEqual(inside.components, [".claude", "projects"])
        // "/Users/meander" is not under "/Users/me".
        XCTAssertEqual(try HeldDirectory.anchorAndComponents(of: "/Users/meander/x", home: "/Users/me").components, [])
        XCTAssertThrowsError(try HeldDirectory.anchorAndComponents(of: "/Users/me/.claude/../x", home: "/Users/me"))
    }

    /// A path under home spelled another way — the home directory in other letters, another
    /// Unicode form, `/private/var` for `/var` — is still walked from home, component by
    /// component: opened as an anchor of its own, it would follow every link below home.
    func testAPathUnderHomeSpelledAnotherWayIsStillWalkedFromHome() throws {
        try makeDirectory("Library/Application Support/Claude-work")
        let name = home.lastPathComponent
        let shouted = home.deletingLastPathComponent().appendingPathComponent(name.uppercased()).path
        if FileManager.default.fileExists(atPath: shouted) {
            let split = try HeldDirectory.anchorAndComponents(of: shouted + "/Library/Application Support/Claude-work", home: home.path)
            XCTAssertEqual(split.anchor, home.path)
            XCTAssertEqual(split.components, ["Library", "Application Support", "Claude-work"])

            // And so a link below home is refused under that spelling too.
            try link("Library/elsewhere", to: home.appendingPathComponent("Library/Application Support").path)
            XCTAssertEqual(reason { _ = try HeldDirectory.walk(to: shouted + "/Library/elsewhere/Claude-work", home: self.home.path,
                                                                 expectedOwner: self.uid) }, .linkOrNotDirectory)
        }

        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let real = String(cString: try XCTUnwrap(realpath(home.path, &resolved)))
        if real != home.path {
            let split = try HeldDirectory.anchorAndComponents(of: real + "/Library", home: home.path)
            XCTAssertEqual(split.anchor, home.path)
            XCTAssertEqual(split.components, ["Library"])
        }

        // A home whose name has an accent, named in the other Unicode form.
        let composed = try makeDirectory("caf\u{E9}/x").deletingLastPathComponent()
        let split = try HeldDirectory.anchorAndComponents(of: home.path + "/cafe\u{301}/x", home: composed.path)
        XCTAssertEqual(split.anchor, composed.path.precomposedStringWithCanonicalMapping)
        XCTAssertEqual(split.components, ["x"])
    }

    /// A path spelled through a link that lies outside the home directory and leads below it:
    /// no ancestor of the spelling is home, so it is its own anchor — and where that anchor
    /// landed is decided on the descriptor, not the spelling, so it is refused. A folder that
    /// really is outside home is still accepted, through a link outside home too.
    func testAPathSpelledOutsideHomeThatLeadsBelowItIsRefused() throws {
        try makeDirectory("Library/Application Support/Claude-work")
        let fileManager = FileManager.default
        let beside = home.deletingLastPathComponent()
        let outside = beside.appendingPathComponent("outside-link-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: outside, withDestinationURL: home.appendingPathComponent("Library"))
        defer { try? fileManager.removeItem(at: outside) }
        let spelled = outside.path + "/Application Support/Claude-work"
        XCTAssertEqual(try HeldDirectory.anchorAndComponents(of: spelled, home: home.path).anchor, spelled)
        let before = TreeSnapshot(of: home)
        XCTAssertEqual(reason { _ = try HeldDirectory.walk(to: spelled, home: self.home.path, expectedOwner: self.uid) },
                       .linkOrNotDirectory)
        XCTAssertEqual(reason { _ = try HeldDirectory.walk(to: outside.path, home: self.home.path, expectedOwner: self.uid) },
                       .linkOrNotDirectory, "the link itself, to a folder below home")
        XCTAssertEqual(TreeSnapshot(of: home), before)

        // A real folder outside home, by its own path and through a link outside home.
        let real = beside.appendingPathComponent("outside-real-\(UUID().uuidString)/Claude-work", isDirectory: true)
        try fileManager.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: real.deletingLastPathComponent()) }
        let held = try HeldDirectory.walk(to: real.path, home: home.path, expectedOwner: uid)
        XCTAssertEqual(held.status.identity, FileStatus.ofPath(real.path)?.identity)
        let toReal = beside.appendingPathComponent("outside-link-real-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: toReal, withDestinationURL: real)
        defer { try? fileManager.removeItem(at: toReal) }
        XCTAssertEqual(try HeldDirectory.walk(to: toReal.path, home: home.path, expectedOwner: uid).status.identity,
                       FileStatus.ofPath(real.path)?.identity)
    }

    /// A folder held open stays the folder that was checked: swapping its name for a link
    /// afterwards redirects nothing.
    func testAHeldFolderIsUnaffectedByItsNameBeingSwappedForALink() throws {
        let real = try makeDirectory(".claude/projects/slug")
        let held = try HeldDirectory.walk(to: real.path, home: home.path, expectedOwner: uid)
        let sentinel = try makeDirectory("sentinel")
        try FileManager.default.moveItem(at: real, to: home.appendingPathComponent("moved"))
        try link(".claude/projects/slug", to: sentinel.path)

        _ = try held.createFile("new.partial")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sentinel.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("moved/new.partial").path))
    }

    // MARK: - Names

    func testOnlySingleComponentsAreAccepted() throws {
        let held = try HeldDirectory.walk(to: try makeDirectory("d").path, home: home.path, expectedOwner: uid)
        for bad in ["", ".", "..", "a/b", "../x", "x\u{0}y", String(repeating: "n", count: 256)] {
            XCTAssertEqual(reason { _ = try held.createFile(bad) }, .invalidName, bad)
            XCTAssertEqual(reason { _ = try held.openRegularFile(bad) }, .invalidName, bad)
            XCTAssertEqual(reason { _ = try held.openDirectory(bad, expectedOwner: nil) }, .invalidName, bad)
            XCTAssertEqual(reason { try held.unlink(bad) }, .invalidName, bad)
            XCTAssertEqual(reason { try held.removeDirectory(bad) }, .invalidName, bad)
            XCTAssertFalse(held.proveAbsent(bad), bad)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("d").path), [])
    }

    // MARK: - Creating

    func testACreatedFileIsPrivateNewAndOurs() throws {
        let held = try HeldDirectory.walk(to: try makeDirectory("d").path, home: home.path, expectedOwner: uid)
        let file = try held.createFile("x.partial")
        try file.write(Data("hello\n".utf8))
        try file.sync()
        try file.fullSync()
        let status = try held.status(of: "x.partial")
        XCTAssertEqual(status.kind, .regular)
        XCTAssertEqual(status.permissions, 0o600)
        XCTAssertEqual(status.owner, uid)
        XCTAssertEqual(status.linkCount, 1)
        XCTAssertEqual(status.size, 6)
        XCTAssertEqual(try file.status().identity, status.identity)
    }

    /// Nothing already at a name is ever replaced or written through: a file, an empty folder
    /// or a dangling link all make the create fail, and are left exactly as they were.
    func testCreatingIsExclusive() throws {
        let folder = try makeDirectory("d")
        try write("theirs", to: "d/file")
        try makeDirectory("d/emptydir")
        try link("d/dangling", to: home.appendingPathComponent("nowhere").path)
        try link("d/pointing", to: home.appendingPathComponent("target").path)
        try write("sentinel", to: "target")
        let held = try HeldDirectory.walk(to: folder.path, home: home.path, expectedOwner: uid)
        let before = TreeSnapshot(of: home)

        for name in ["file", "emptydir", "dangling", "pointing"] {
            XCTAssertEqual(reason { _ = try held.createFile(name) }, .exists, name)
            XCTAssertEqual(reason { _ = try held.makeDirectory(name, expectedOwner: self.uid) }, .exists, name)
        }
        XCTAssertEqual(TreeSnapshot(of: home), before, TreeSnapshot(of: home).difference(from: before))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("nowhere").path))
    }

    /// The umask can only take bits away; the explicit `fchmod` puts back exactly 0600 / 0700.
    func testModesAreExactWhateverTheUmask() throws {
        let held = try HeldDirectory.walk(to: try makeDirectory("d").path, home: home.path, expectedOwner: uid)
        let previous = umask(0o277)
        defer { umask(previous) }
        _ = try held.createFile("f")
        let made = try held.makeDirectory("sub", expectedOwner: uid)
        XCTAssertEqual(try held.status(of: "f").permissions, 0o600)
        XCTAssertEqual(made.status.permissions, 0o700)
        XCTAssertEqual(try held.status(of: "sub").permissions, 0o700)
    }

    /// A folder swapped for a link between `mkdirat` and the re-open is refused, and nothing
    /// is created in what the link points at.
    func testAFolderSwappedForALinkRightAfterItIsMadeIsRefused() throws {
        let folder = try makeDirectory("d")
        let sentinel = try makeDirectory("sentinel")
        let held = try HeldDirectory.walk(to: folder.path, home: home.path, expectedOwner: uid)
        let planted = folder.appendingPathComponent("staging.dir")
        let sentinelBefore = TreeSnapshot(of: home.appendingPathComponent("sentinel")).entries
        let sentinelMode = FileStatus.ofPath(sentinel.path)?.permissions
        XCTAssertEqual(reason {
            _ = try held.makeDirectory("staging.dir", expectedOwner: self.uid, afterCreating: {
                try? FileManager.default.removeItem(at: planted)
                try? FileManager.default.createSymbolicLink(at: planted, withDestinationURL: sentinel)
            })
        }, .linkOrNotDirectory)
        XCTAssertEqual(TreeSnapshot(of: home.appendingPathComponent("sentinel")).entries, sentinelBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sentinel.path), [])
        XCTAssertEqual(FileStatus.ofPath(sentinel.path)?.permissions, sentinelMode, "not re-permissioned through the link")
    }

    func testAMadeDirectoryIsPrivateAndHeld() throws {
        let held = try HeldDirectory.walk(to: try makeDirectory("d").path, home: home.path, expectedOwner: uid)
        let made = try held.makeDirectory(".claude-switcher-copy-x.dir", expectedOwner: uid)
        XCTAssertEqual(made.status.permissions, 0o700)
        XCTAssertEqual(made.status.owner, uid)
        let inner = try made.makeDirectory("subagents", expectedOwner: uid)
        XCTAssertEqual(inner.status.permissions, 0o700)
        _ = try inner.createFile("agent-a.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("d/.claude-switcher-copy-x.dir/subagents/agent-a.jsonl").path))
    }

    // MARK: - Reading

    func testOpeningToReadRefusesALinkAFolderAndAPipeWithoutHanging() throws {
        let folder = try makeDirectory("d")
        try write("sentinel\n", to: "target")
        try link("d/link.jsonl", to: home.appendingPathComponent("target").path)
        try makeDirectory("d/dir.jsonl")
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("pipe.jsonl").path, 0o600), 0)
        let held = try HeldDirectory.walk(to: folder.path, home: home.path, expectedOwner: uid)

        let started = Date()
        XCTAssertEqual(reason { _ = try held.openRegularFile("pipe.jsonl") }, .notRegularFile)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(reason { _ = try held.openRegularFile("link.jsonl") }, .notRegularFile)
        XCTAssertEqual(reason { _ = try held.openRegularFile("dir.jsonl") }, .notRegularFile)
        XCTAssertEqual(reason { _ = try held.openRegularFile("missing.jsonl") }, .absent)
    }

    func testReadingIsByOffsetAndShortOnlyAtTheEnd() throws {
        try write("0123456789", to: "d/f")
        let held = try HeldDirectory.walk(to: home.path + "/d", home: home.path, expectedOwner: uid)
        let file = try held.openRegularFile("f")
        XCTAssertEqual(try file.read(count: 4, at: 3), Data("3456".utf8))
        XCTAssertEqual(try file.read(count: 20, at: 0), Data("0123456789".utf8))
        XCTAssertEqual(try file.readAll(limit: 10), Data("0123456789".utf8))
        XCTAssertEqual(reason { _ = try file.readAll(limit: 9) }, .shortTransfer)
    }

    /// APFS keeps times from before 1677 and after 2262, past what fits in nanoseconds since
    /// 1970 as an `Int64`: such a file is listed, not a crash.
    func testAFileDatedBefore1677OrAfter2262IsReadWithoutCrashing() throws {
        let fake = try FakeHome()
        let store = try fake.signIn(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        let url = try fake.writeRecord(["sessionId": "local_11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "cwd": "/tmp"], in: store)
        let held = try HeldDirectory.walk(to: store.url.path, home: fake.home, expectedOwner: uid)
        for seconds: Int in [-11_676_096_000, 9_300_000_000] {
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            XCTAssertEqual(utimes(url.path, &times), 0)
            let status = try held.status(of: url.lastPathComponent)
            XCTAssertEqual(Int(status.modifiedNanoseconds.signum()), seconds.signum(), "\(seconds)")
            XCTAssertEqual(SessionStore.records(in: store).map(\.id), ["local_11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"], "\(seconds)")
        }
    }

    func testTimesBeyondTheNanosecondRangeAreHeldAtItsEnds() {
        XCTAssertEqual(FileStatus.nanoseconds(timespec(tv_sec: 1, tv_nsec: 5)), 1_000_000_005)
        XCTAssertEqual(FileStatus.nanoseconds(timespec(tv_sec: -1, tv_nsec: 5)), -999_999_995)
        XCTAssertEqual(FileStatus.nanoseconds(timespec(tv_sec: .min, tv_nsec: 0)), .min)
        XCTAssertEqual(FileStatus.nanoseconds(timespec(tv_sec: .max, tv_nsec: 999_999_999)), .max)
        XCTAssertEqual(FileStatus.nanoseconds(timespec(tv_sec: -9_223_372_037, tv_nsec: 145_224_192)), .min)
        XCTAssertEqual(FileStatus.nanoseconds(timespec(tv_sec: 9_223_372_036, tv_nsec: 854_775_807)), .max)
        XCTAssertEqual(FileStatus.nanoseconds(timespec(tv_sec: 9_223_372_036, tv_nsec: 854_775_808)), .max)
    }

    func testStatusNeverFollowsALink() throws {
        try makeDirectory("d")
        try write("x", to: "target")
        try link("d/l", to: home.appendingPathComponent("target").path)
        let held = try HeldDirectory.walk(to: home.path + "/d", home: home.path, expectedOwner: uid)
        XCTAssertEqual(try held.status(of: "l").kind, .symbolicLink)
        XCTAssertEqual(reason { _ = try held.status(of: "nothing") }, .absent)
    }

    /// Only ENOENT proves absence. A name that cannot even be looked at is "something there".
    func testAbsenceIsProvenOnlyByNoSuchFile() throws {
        try write("x", to: "d/file")
        try makeDirectory("d/dir")
        try link("d/dangling", to: home.appendingPathComponent("nowhere").path)
        let held = try HeldDirectory.walk(to: home.path + "/d", home: home.path, expectedOwner: uid)
        XCTAssertTrue(held.proveAbsent("missing"))
        XCTAssertFalse(held.proveAbsent("file"))
        XCTAssertFalse(held.proveAbsent("dir"))
        XCTAssertFalse(held.proveAbsent("dangling"))

        let locked = try makeDirectory("locked")
        let heldLocked = try HeldDirectory.walk(to: locked.path, home: home.path, expectedOwner: uid)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        XCTAssertFalse(heldLocked.proveAbsent("anything"), "EACCES is not proof of absence")
    }

    func testEntriesAreListedAgainAndAgain() throws {
        try write("a", to: "d/a")
        try write("b", to: "d/.b")
        try makeDirectory("d/c")
        let held = try HeldDirectory.walk(to: home.path + "/d", home: home.path, expectedOwner: uid)
        XCTAssertEqual(try held.entries().sorted(), [".b", "a", "c"])
        XCTAssertEqual(try held.entries().sorted(), [".b", "a", "c"])
    }

    // MARK: - Removing and renaming

    func testRemovalIsOneNameAndNeverRecursive() throws {
        try write("x", to: "d/full/.DS_Store")
        try makeDirectory("d/empty")
        try write("x", to: "d/file")
        let held = try HeldDirectory.walk(to: home.path + "/d", home: home.path, expectedOwner: uid)

        XCTAssertNotNil(reason { try held.removeDirectory("full") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("d/full/.DS_Store").path))
        XCTAssertNotNil(reason { try held.unlink("empty") }, "unlink never removes a folder")
        try held.removeDirectory("empty")
        try held.unlink("file")
        XCTAssertEqual(try held.entries(), ["full"])
    }

    /// RENAME_EXCL: an existing empty folder or a dangling link at the destination makes the
    /// rename fail — a plain rename() would have replaced the empty folder.
    func testRenamingNeverReplacesAnything() throws {
        try write("staged", to: "d/staged.partial")
        try makeDirectory("d/emptydir")
        try link("d/dangling", to: home.appendingPathComponent("nowhere").path)
        try write("theirs", to: "d/file")
        let held = try HeldDirectory.walk(to: home.path + "/d", home: home.path, expectedOwner: uid)
        let before = TreeSnapshot(of: home)

        for destination in ["emptydir", "dangling", "file"] {
            XCTAssertEqual(reason { try held.renameExclusive("staged.partial", to: destination) }, .exists, destination)
        }
        XCTAssertEqual(TreeSnapshot(of: home), before)

        try held.renameExclusive("staged.partial", to: "final")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("d/final"), encoding: .utf8), "staged")
    }

    /// A volume without exclusive rename is refused; there is no other rename to fall back to.
    func testAVolumeWithoutExclusiveRenameIsRefusedWithNoFallback() throws {
        try write("staged", to: "d/staged.partial")
        let held = try HeldDirectory.walk(to: home.path + "/d", home: home.path, expectedOwner: uid)
        let before = TreeSnapshot(of: home)
        for code in [ENOTSUP, EINVAL] {
            let calls = Counter()
            let unsupported: ExclusiveRename = { _, _, _, _ in calls.increment(); return code }
            XCTAssertEqual(reason { try held.renameExclusive("staged.partial", to: "final", using: unsupported) },
                           .renameUnsupported)
            XCTAssertEqual(calls.value, 1)
        }
        XCTAssertEqual(TreeSnapshot(of: home), before)
    }

    // MARK: - Lifetime

    func testDescriptorsAreClosedWhenTheLastReferenceGoes() throws {
        try write("x", to: "d/f")
        var directoryDescriptor: Int32 = -1
        var fileDescriptor: Int32 = -1
        do {
            let held = try HeldDirectory.walk(to: home.path + "/d", home: home.path, expectedOwner: uid)
            let file = try held.openRegularFile("f")
            directoryDescriptor = held.descriptor
            fileDescriptor = file.descriptor
            XCTAssertNotEqual(fcntl(directoryDescriptor, F_GETFD), -1)
            XCTAssertNotEqual(fcntl(fileDescriptor, F_GETFD), -1)
        }
        XCTAssertEqual(fcntl(directoryDescriptor, F_GETFD), -1)
        XCTAssertEqual(fcntl(fileDescriptor, F_GETFD), -1)
        // A refused open leaves nothing open either.
        let opened = openDescriptorCount()
        for _ in 0..<20 {
            _ = try? HeldDirectory.walk(to: home.path + "/d/f", home: home.path, expectedOwner: uid)
            _ = try? HeldDirectory.walk(to: home.path + "/d", home: home.path, expectedOwner: uid + 1)
        }
        XCTAssertEqual(openDescriptorCount(), opened)
    }

    func testDirectoriesCanBeFlushedToTheDrive() throws {
        let held = try HeldDirectory.walk(to: try makeDirectory("d").path, home: home.path, expectedOwner: uid)
        XCTAssertNoThrow(try held.sync())
        XCTAssertNoThrow(try held.fullSync())
        XCTAssertNotNil(HeldDirectory.freeBytes(onVolumeOf: held.descriptor))
    }

    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
}

/// A thread-safe call counter for `@Sendable` stubs.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
