import CryptoKit
import Darwin
import XCTest
@testable import ClaudeSwitcherCore

// MARK: - Processes and tools

/// The process runner and the readers of what hdiutil and spctl print. The processes started
/// here are harmless system tools (`env`, `cat`, `sleep`); no app is started.
final class SwitcherToolTests: XCTestCase {

    func testAProcessGetsAnEmptyEnvironment() {
        guard case .exited(0, let output, _) = SwitcherProcess.run("/usr/bin/env", [], deadline: 10) else {
            return XCTFail("env did not run")
        }
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "")
    }

    func testAProcessReadsNothingFromItsInput() {
        let started = Date()
        guard case .exited(0, let output, _) = SwitcherProcess.run("/bin/cat", [], deadline: 10) else {
            return XCTFail("cat did not run")
        }
        XCTAssertEqual(output, Data())
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testOnlyAnAbsolutePathIsRun() {
        XCTAssertEqual(SwitcherProcess.run("hdiutil", ["info"], deadline: 1), .couldNotStart("hdiutil is not an absolute path"))
    }

    func testADeadlineIsKeptAndTheProcessIsNotEnded() {
        let started = Date()
        XCTAssertEqual(SwitcherProcess.run("/bin/sleep", ["3"], deadline: 0.2), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTheObserverSeesTheProcessBeforeItStartsAndCanStopIt() {
        let seen = Names()
        let result = SwitcherProcess.run("/usr/bin/env", ["-0"], deadline: 1) { launch in
            seen.append("\(launch.executablePath ?? "") \(launch.arguments) \(launch.environment ?? ["x": "x"]) \(launch.standardInputPath ?? "")")
            return false
        }
        XCTAssertEqual(result, .couldNotStart("not started"))
        XCTAssertEqual(seen.values, ["/usr/bin/env [\"-0\"] [:] /dev/null"])
    }

    // MARK: hdiutil

    /// Recorded from `hdiutil attach -plist` of the v0.7.0 image on 2026-10-05.
    private let attachPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>system-entities</key><array>
    <dict><key>content-hint</key><string>Apple_HFS</string><key>dev-entry</key><string>/dev/disk18s1</string>
    <key>mount-point</key><string>/tmp/u/mounts/dmg.clFfV8</string><key>potentially-mountable</key><true/>
    <key>volume-kind</key><string>hfs</string></dict>
    <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk18</string>
    <key>potentially-mountable</key><false/></dict>
    </array></dict></plist>
    """

    func testTheMountPointAndTheWholeDiskAreReadFromHdiutilsAnswer() {
        XCTAssertEqual(DiskImageTool.parseAttach(Data(attachPlist.utf8)),
                       Mount(mountPoint: "/tmp/u/mounts/dmg.clFfV8", device: "/dev/disk18"))
        XCTAssertNil(DiskImageTool.parseAttach(Data("garbage".utf8)))
        let twoMounts = attachPlist.replacingOccurrences(of: "<key>potentially-mountable</key><false/>",
                                                         with: "<key>mount-point</key><string>/x</string>")
        XCTAssertNil(DiskImageTool.parseAttach(Data(twoMounts.utf8)))
        let notADisk = attachPlist.replacingOccurrences(of: "<string>/dev/disk18</string>", with: "<string>/etc/passwd</string>")
            .replacingOccurrences(of: "<string>/dev/disk18s1</string>", with: "<string>/dev/x</string>")
        XCTAssertNil(DiskImageTool.parseAttach(Data(notADisk.utf8)))
    }

    func testHdiutilInfoIsReadImageByImage() throws {
        let info: [String: Any] = ["images": [
            ["image-path": "/a/downloads/v0.8.0/Claude.Switcher.dmg",
             "system-entities": [["dev-entry": "/dev/disk9s1"], ["dev-entry": "/dev/disk9"]]],
            ["image-path": "/b/other.dmg", "system-entities": [["dev-entry": "/dev/disk4"], ["dev-entry": "nonsense"]]],
            ["no-path": true],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let images = try XCTUnwrap(DiskImageTool.parseInfo(data))
        XCTAssertEqual(images, [AttachedImage(imagePath: "/a/downloads/v0.8.0/Claude.Switcher.dmg",
                                              devices: ["/dev/disk9s1", "/dev/disk9"]),
                                AttachedImage(imagePath: "/b/other.dmg", devices: ["/dev/disk4"])])
        XCTAssertEqual(images[0].detachDevice, "/dev/disk9")
    }

    func testOnlyADiskDeviceIsEverNamedToDetach() {
        for device in ["/dev/disk9", "/dev/disk12s3"] { XCTAssertTrue(DiskImageTool.isDevice(device), device) }
        for device in ["/dev/disk", "disk9", "/dev/disk9 -force", "/dev/rdisk9", "/dev/disk9s", "/dev/disk9\n", "/"] {
            XCTAssertFalse(DiskImageTool.isDevice(device), device)
        }
    }

    func testABusyDetachIsTriedFiveMoreTimesThenForced() {
        let calls = Names()
        let pauses = Names()
        let detached = DiskImageTool.detach("/dev/disk9", run: { tool, arguments in
            calls.append(([tool] + arguments).joined(separator: " "))
            return arguments.last == "-force" ? .exited(status: 0, output: Data(), errorOutput: Data())
                                              : .exited(status: 16, output: Data(), errorOutput: Data("Resource busy".utf8))
        }, pause: { pauses.append("\($0)") })
        XCTAssertTrue(detached)
        XCTAssertEqual(calls.values.count, 7)
        XCTAssertEqual(calls.values.last, "/usr/bin/hdiutil detach /dev/disk9 -force")
        XCTAssertEqual(Set(calls.values.dropLast()), ["/usr/bin/hdiutil detach /dev/disk9"])
        XCTAssertEqual(pauses.values, Array(repeating: "0.2", count: 5))
    }

    func testADetachThatFailsForAnotherReasonIsNotForced() {
        let calls = Names()
        XCTAssertFalse(DiskImageTool.detach("/dev/disk9", run: { _, arguments in
            calls.append(arguments.joined(separator: " "))
            return .exited(status: 1, output: Data(), errorOutput: Data())
        }, pause: { _ in }))
        XCTAssertEqual(calls.values, ["detach /dev/disk9"])
        XCTAssertFalse(DiskImageTool.detach("/dev/disk9; ls", run: { _, _ in XCTFail("ran"); return .timedOut }, pause: { _ in }))
    }

    func testTheLicenseIsReadFromImageInfo() throws {
        func info(_ license: Bool) throws -> ProcessResult {
            let plist = ["Properties": ["Software License Agreement": license]]
            return .exited(status: 0, output: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                           errorOutput: Data())
        }
        XCTAssertEqual(DiskImageTool.license(from: try info(false)), .success(false))
        XCTAssertEqual(DiskImageTool.license(from: try info(true)), .success(true))
        for result: ProcessResult in [.timedOut, .couldNotStart("x"), .exited(status: 1, output: Data(), errorOutput: Data()),
                                      .exited(status: 0, output: Data("{}".utf8), errorOutput: Data())] {
            guard case .failure(let refusal) = DiskImageTool.license(from: result) else { return XCTFail("\(result)") }
            XCTAssertEqual(refusal.kind, .transient)
        }
    }

    func testAnAttachThatTimesOutIsToldApartFromOneThatFailed() {
        XCTAssertEqual(DiskImageTool.mount(from: .timedOut), .failure(.timedOut))
        XCTAssertEqual(DiskImageTool.mount(from: .exited(status: 1, output: Data(), errorOutput: Data("hdiutil: attach canceled\n".utf8))),
                       .failure(.failed("hdiutil exited 1: hdiutil: attach canceled")))
        XCTAssertEqual(DiskImageTool.mount(from: .exited(status: 0, output: Data(attachPlist.utf8), errorOutput: Data())),
                       .success(Mount(mountPoint: "/tmp/u/mounts/dmg.clFfV8", device: "/dev/disk18")))
    }

    // MARK: spctl

    private func verdict(_ value: Bool) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["assessment:verdict": value], format: .xml, options: 0)
    }

    func testOnlyAnExplicitYesFromGatekeeperIsAcceptance() throws {
        XCTAssertEqual(DiskImageTool.assessment(from: .exited(status: 0, output: try verdict(true), errorOutput: Data())), .accepted)
        XCTAssertEqual(DiskImageTool.assessment(from: .exited(status: 0, output: try verdict(false), errorOutput: Data())),
                       .rejected("its verdict is negative"))
        XCTAssertEqual(DiskImageTool.assessment(from: .exited(status: 0, output: Data(), errorOutput: Data())),
                       .unavailable("spctl\u{2019}s answer could not be read"))
    }

    func testGatekeepersNoIsPermanentAndAnythingElseIsNotAnAnswer() {
        for status: Int32 in [1, 3] {
            guard case .rejected = DiskImageTool.assessment(from: .exited(status: status, output: Data(), errorOutput: Data("rejected".utf8)))
            else { return XCTFail("exit \(status)") }
        }
        for result: ProcessResult in [.timedOut, .couldNotStart("x"), .exited(status: 2, output: Data(), errorOutput: Data()),
                                      .exited(status: 4, output: Data(), errorOutput: Data())] {
            guard case .unavailable = DiskImageTool.assessment(from: result) else { return XCTFail("\(result)") }
        }
    }
}

// MARK: - The disk

final class SwitcherDiskTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: SwitcherDisk.realpath(base.path)!)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func quarantine(_ path: String) {
        let value = "0083;6700f000;Safari;"
        _ = value.withCString { setxattr(path, SwitcherDisk.quarantineAttribute, $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }

    private func isQuarantined(_ path: String) -> Bool {
        getxattr(path, SwitcherDisk.quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// The flag is cleared on the bundle and everything in it, links included, without following
    /// a link out of the bundle.
    func testTheQuarantineFlagIsClearedOnEveryItemAndNoLinkIsFollowed() throws {
        let app = root.appendingPathComponent("Claude Switcher.app").path
        let outside = root.appendingPathComponent("outside.txt").path
        try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: app + "/Contents/MacOS/claude-switcher"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(atPath: app + "/Contents/link", withDestinationPath: outside)
        let items = [app, app + "/Contents", app + "/Contents/MacOS", app + "/Contents/MacOS/claude-switcher",
                     app + "/Contents/Info.plist", app + "/Contents/link"]
        for item in items + [outside] { quarantine(item) }
        XCTAssertTrue(items.allSatisfy(isQuarantined))

        XCTAssertNil(SwitcherDisk.removeQuarantine(app))
        for item in items { XCTAssertFalse(isQuarantined(item), item) }
        XCTAssertTrue(isQuarantined(outside), "the link's target is not ours")
        XCTAssertNil(SwitcherDisk.removeQuarantine(app), "no flag left is fine")
    }

    func testTheStripIsInvokedOnTheRootAndEveryItemAndAnyOtherErrorRefuses() throws {
        let app = root.appendingPathComponent("A.app").path
        try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        let visited = Names()
        XCTAssertNil(SwitcherDisk.removeQuarantine(app) { visited.append($0); return ENOATTR })
        XCTAssertEqual(Set(visited.values), [app, app + "/Contents", app + "/Contents/MacOS", app + "/Contents/Info.plist"])
        let refusal = SwitcherDisk.removeQuarantine(app) { $0.hasSuffix("Info.plist") ? EPERM : 0 }
        XCTAssertEqual(refusal?.kind, .transient)
        XCTAssertEqual(refusal?.step, PrepareStep.quarantine.rawValue)
    }

    func testFileFactsAreReadWithoutFollowingLinks() throws {
        let file = root.appendingPathComponent("f").path
        try Data("abc".utf8).write(to: URL(fileURLWithPath: file))
        let link = root.appendingPathComponent("l").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
        XCTAssertEqual(SwitcherDisk.lstatKind(file), .file)
        XCTAssertEqual(SwitcherDisk.lstatKind(link), .symlink)
        XCTAssertEqual(SwitcherDisk.lstatKind(root.path), .directory)
        XCTAssertNil(SwitcherDisk.lstatKind(root.appendingPathComponent("none").path))
        XCTAssertEqual(SwitcherDisk.fileSize(file), 3)
        XCTAssertNil(SwitcherDisk.fileSize(link))
        XCTAssertEqual(SwitcherDisk.sha256Hex(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNil(SwitcherDisk.sha256Hex(link))
        XCTAssertEqual(SwitcherDisk.listDirectory(root.path),
                       [DirectoryEntry(name: "f", kind: .file), DirectoryEntry(name: "l", kind: .symlink, linkTarget: file)])
        XCTAssertNil(SwitcherDisk.listDirectory(link))
        XCTAssertNotNil(SwitcherDisk.freeSpace(root.appendingPathComponent("not/yet").path))
        XCTAssertEqual(SwitcherDisk.makeDirectory(root.appendingPathComponent("d").path), 0)
        XCTAssertEqual(SwitcherDisk.makeDirectory(root.appendingPathComponent("d").path), 0)
        XCTAssertEqual(SwitcherDisk.makeDirectory(file), EEXIST)
        // A link to a folder is not the folder: the updater would write and mount through it.
        let linkToADirectory = root.appendingPathComponent("linked-d").path
        try FileManager.default.createSymbolicLink(atPath: linkToADirectory, withDestinationPath: root.appendingPathComponent("d").path)
        XCTAssertNotEqual(SwitcherDisk.makeDirectory(linkToADirectory), 0)
    }

    // MARK: Read-only items and the quarantine flag

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        _ = lstat(path, &info)
        return info.st_mode & 0o7777
    }

    /// A read-only item without the flag is left alone: `removexattr` there would say EACCES and
    /// stop a release that holds one from ever being installed.
    func testAReadOnlyItemWithoutTheFlagIsLeftAlone() throws {
        let app = root.appendingPathComponent("A.app").path
        try FileManager.default.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
        let file = app + "/Contents/locked.txt"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(chmod(file, 0o444), 0)
        let before = changed(file)
        XCTAssertNil(SwitcherDisk.removeQuarantine(app))
        XCTAssertEqual(mode(file), 0o444)
        XCTAssertEqual(changed(file), before, "not even its mode was touched on the way")
    }

    /// When the item's inode last changed: a chmod, even one undone, moves it.
    private func changed(_ path: String) -> [Int] {
        var info = stat()
        _ = lstat(path, &info)
        return [info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]
    }

    /// A read-only item that carries the flag has it cleared and keeps its mode.
    func testAReadOnlyItemWithTheFlagIsClearedAndKeepsItsMode() throws {
        let app = root.appendingPathComponent("B.app").path
        let folder = app + "/Contents/Resources"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let file = folder + "/locked.txt"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        for item in [app, folder, file] { quarantine(item) }
        XCTAssertEqual(chmod(file, 0o444), 0)
        XCTAssertEqual(chmod(folder, 0o555), 0)
        defer { _ = chmod(folder, 0o755) }
        XCTAssertNil(SwitcherDisk.removeQuarantine(app))
        for item in [app, folder, file] { XCTAssertFalse(isQuarantined(item), item) }
        XCTAssertEqual(mode(file), 0o444)
        XCTAssertEqual(mode(folder), 0o555)
    }

    // MARK: Facts read at launch

    /// A copy macOS runs from a randomised read-only place, because it was opened where it was
    /// downloaded, is seen as such.
    func testATranslocatedBundleIsSeenAsTranslocated() throws {
        let path = root.appendingPathComponent("AppTranslocation/ABC/d/Claude Switcher.app").path
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "tech.local.claude-switcher", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        XCTAssertTrue(RunningCopy.current(bundle: try XCTUnwrap(Bundle(path: path))).isTranslocated)
        XCTAssertFalse(RunningCopy.current(bundle: Bundle(for: SwitcherDiskTests.self)).isTranslocated)
    }

    /// A volume that cannot be asked counts as read-only: unknown is never "may replace itself".
    func testAVolumeThatCannotBeReadCountsAsReadOnly() {
        XCTAssertTrue(SwitcherDisk.isOnReadOnlyVolume(root.appendingPathComponent("no/such/path").path))
        XCTAssertFalse(SwitcherDisk.isOnReadOnlyVolume(root.path))
    }

    // MARK: One prepare at a time

    /// `flock` belongs to the open file description, so a second take in this process is refused
    /// exactly as another copy's would be — and succeeds once the first lets go.
    func testThePrepareLockIsHeldByOneCopyAtATime() throws {
        let updates = root.appendingPathComponent("cfg/claude-switcher/updates")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        let path = updates.appendingPathComponent(PrepareLock.fileName).path
        let first = try XCTUnwrap(PrepareLock.take(at: path))
        XCTAssertNil(PrepareLock.take(at: path), "another copy is checking")
        first()
        first()   // letting go twice is letting go once
        let second = try XCTUnwrap(PrepareLock.take(at: path))
        second()

        // The real environment takes the same lock, in its own updates folder.
        let env = SwitcherUpdater.PrepareEnvironment.live(
            updatesDirectory: updates, store: SwitcherUpdateStore(directory: updates, host: UpdateFixture.host),
            registry: StagedCopies(), run: { _, _ in .couldNotStart("none") }, pause: { _ in })
        let held = try XCTUnwrap(env.takePrepareLock())
        XCTAssertNil(PrepareLock.take(at: path))
        XCTAssertNil(env.takePrepareLock())
        held()
        let again = try XCTUnwrap(env.takePrepareLock(), "free again once the holder lets go")
        again()

        // A link where the lock file goes is not followed.
        let elsewhere = root.appendingPathComponent("elsewhere.lock").path
        let linked = root.appendingPathComponent("linked.lock").path
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: elsewhere)
        XCTAssertNil(PrepareLock.take(at: linked))
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere))
    }

    /// FileManager's replacement folder for an item in /Applications-like places is under
    /// `realpath(NSTemporaryDirectory())/TemporaryItems` — what the staging rule expects.
    func testTheStagingFolderIsAnNSIRDFolderUnderTemporaryItemsOnTheSameVolume() throws {
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications.appendingPathComponent("Claude Switcher.app"),
                                                withIntermediateDirectories: true)
        let staging = try SwitcherDisk.stagingDirectory(for: applications.appendingPathComponent("Claude Switcher.app").path).get()
        defer { _ = rmdir(staging) }
        let resolved = try XCTUnwrap(SwitcherDisk.realpath(staging))
        XCTAssertEqual((resolved as NSString).deletingLastPathComponent, SwitcherDisk.temporaryItemsDirectory())
        XCTAssertTrue((resolved as NSString).lastPathComponent.hasPrefix("NSIRD_"))
        XCTAssertEqual(SwitcherDisk.deviceOf(staging), SwitcherDisk.deviceOf(applications.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging), [])
    }
}

// MARK: - The network seams, against a stub protocol

/// Answers requests from a script; nothing leaves the process.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case redirect(String)
        case body(status: Int, data: Data, contentLength: Int?)
        case failure(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func script(_ replies: [String: Reply]) {
        lock.lock(); self.replies = replies; requests = []; lock.unlock()
    }

    static var seen: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    static func configuration(resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = SwitcherReleaseFeed.sessionConfiguration(resourceTimeout: resourceTimeout)
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.replies[url.absoluteString]
        Self.lock.unlock()
        switch reply {
        case .redirect(let target)?:
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .body(let status, let data, let length)?:
            var headers: [String: String] = [:]
            if let length { headers["Content-Length"] = String(length) }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code)?:
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
    }

    override func stopLoading() {}
}

final class SwitcherNetworkSeamTests: XCTestCase {

    private let origin = "https://github.com/kevinchau/claude-switcher/releases/download/v0.8.0/Claude.Switcher.dmg"
    private let assets = "https://release-assets.githubusercontent.com/github-production-release-asset/1/x"
    private let bytes = Data((0..<4096).map { UInt8($0 % 251) })
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        StubProtocol.script([:])
    }

    private var destination: String { directory.appendingPathComponent("Claude.Switcher.dmg.partial").path }

    private func download(expected: Int? = nil) async -> Refusal? {
        await AssetDownload(expected: expected ?? bytes.count, destination: destination,
                            configuration: StubProtocol.configuration(resourceTimeout: 30)).run(URL(string: origin)!)
    }

    func testTheFileIsFetchedThroughGitHubsAssetHost() async {
        StubProtocol.script([origin: .redirect(assets), assets: .body(status: 200, data: bytes, contentLength: bytes.count)])
        let refusal = await download()
        XCTAssertNil(refusal)
        XCTAssertEqual(FileManager.default.contents(atPath: destination), bytes)
        XCTAssertEqual(StubProtocol.seen.compactMap(\.url?.host), ["github.com", "release-assets.githubusercontent.com"])
        XCTAssertTrue(StubProtocol.seen.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertTrue(StubProtocol.seen.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    func testARedirectAnywhereElseIsRefusedForGoodAndNothingIsKept() async {
        for target in ["https://evil.example/x", "http://release-assets.githubusercontent.com/x",
                       "https://release-assets.githubusercontent.com.evil.com/x"] {
            StubProtocol.script([origin: .redirect(target), target: .body(status: 200, data: bytes, contentLength: bytes.count)])
            let refusal = await download()
            XCTAssertEqual(refusal?.kind, .permanent, target)
            XCTAssertTrue(refusal?.reason.contains("unexpected host") ?? false, target)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination), target)
            XCTAssertFalse(StubProtocol.seen.contains { $0.url?.absoluteString == target }, "never fetched: \(target)")
        }
    }

    func testAnAssetHostMayNotRedirectFurther() async {
        StubProtocol.script([origin: .redirect(assets), assets: .redirect("https://objects.githubusercontent.com/y")])
        let refusal = await download()
        XCTAssertEqual(refusal?.kind, .permanent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    func testMoreBytesThanTheReleaseSaysAreRefused() async {
        StubProtocol.script([origin: .body(status: 200, data: bytes + bytes, contentLength: nil)])
        let refusal = await download()
        XCTAssertEqual(refusal?.kind, .transient)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    func testAContentLengthOtherThanTheReleasesIsRefused() async {
        StubProtocol.script([origin: .body(status: 200, data: bytes, contentLength: bytes.count)])
        let refusal = await download(expected: bytes.count + 1)
        XCTAssertEqual(refusal?.kind, .transient)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    func testAnErrorStatusIsTransient() async {
        StubProtocol.script([origin: .body(status: 503, data: Data(), contentLength: 0)])
        let refusal = await download()
        XCTAssertEqual(refusal?.kind, .transient)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    /// Only a final 200 is the file: an error page of exactly the right length is not kept.
    func testANon200AnswerOfTheRightLengthIsNotKept() async {
        StubProtocol.script([origin: .body(status: 404, data: bytes, contentLength: bytes.count)])
        let refusal = await download()
        XCTAssertEqual(refusal?.kind, .transient)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    /// The real environment fetches only from https://github.com, whatever URL it is handed: any
    /// other is refused before a request is made.
    func testTheLiveDownloadStartsOnlyAtGitHub() async {
        StubProtocol.script([:])
        let updates = directory.appendingPathComponent("updates")
        let env = SwitcherUpdater.PrepareEnvironment.live(
            updatesDirectory: updates, store: SwitcherUpdateStore(directory: updates, host: UpdateFixture.host),
            registry: StagedCopies(), run: { _, _ in .couldNotStart("none") }, pause: { _ in },
            downloadConfiguration: { StubProtocol.configuration(resourceTimeout: 30) })
        for address in ["https://evil.example/x", "http://github.com/x", "https://github.com:8443/x",
                        "https://user@github.com/x"] {
            let refusal = await env.download(URL(string: address)!, destination, bytes.count)
            XCTAssertEqual(refusal?.kind, .permanent, address)
            XCTAssertEqual(refusal?.reason, "the download address is not github.com", address)
        }
        XCTAssertEqual(StubProtocol.seen, [], "nothing was requested")

        // The same environment does reach the session it was given for github.com.
        let refusal = await env.download(URL(string: origin)!, destination, bytes.count)
        XCTAssertEqual(refusal?.kind, .transient)
        XCTAssertEqual(StubProtocol.seen.compactMap(\.url?.absoluteString), [origin])
    }

    func testAFailureBeforeTheFirstByteIsNotAnAttempt() async {
        StubProtocol.script([origin: .failure(.notConnectedToInternet)])
        let refusal = await download()
        XCTAssertEqual(refusal?.kind, .transient)
        XCTAssertEqual(refusal?.countsAsAttempt, false)
    }

    func testTheFeedIsFetchedOnceWithItsHeadersAndARedirectIsNotFollowed() async {
        let api = SwitcherReleaseFeed.apiURL.absoluteString
        StubProtocol.script([api: .redirect("https://api.github.com/repositories/1/releases/latest"),
                             "https://api.github.com/repositories/1/releases/latest":
                                .body(status: 200, data: ReleaseFeedFixture.latestV070, contentLength: nil)])
        let env = SwitcherUpdater.CheckEnvironment.live(configuration: { StubProtocol.configuration(resourceTimeout: 30) })
        let outcome = await SwitcherUpdater.check(runningVersion: UpdateFixture.v070, env: env)
        XCTAssertEqual(outcome, .feedMoved("api.github.com/repositories/1/releases/latest"))
        XCTAssertEqual(StubProtocol.seen.count, 1)
        let request = StubProtocol.seen.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "ClaudeSwitcher/0.7.0 (macOS)")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))
    }

    func testTheFeedsAnswerIsReadThroughTheLiveSession() async {
        let api = SwitcherReleaseFeed.apiURL.absoluteString
        StubProtocol.script([api: .body(status: 200, data: ReleaseFeedFixture.latestV070, contentLength: nil)])
        let env = SwitcherUpdater.CheckEnvironment.live(configuration: { StubProtocol.configuration(resourceTimeout: 30) })
        let outcome = await SwitcherUpdater.check(runningVersion: UpdateFixture.v070, env: env)
        guard case .candidate(let candidate) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(candidate.digestHex, ReleaseFeedFixture.v070Digest)
    }

    /// Each fetch of the feed has a session of its own, let go of once it has answered: the app
    /// builds an environment per check, and nothing is kept from one check to the next.
    func testEachFetchOfTheFeedHasASessionOfItsOwn() async {
        let api = SwitcherReleaseFeed.apiURL.absoluteString
        StubProtocol.script([api: .body(status: 200, data: ReleaseFeedFixture.latestV070, contentLength: nil)])
        let made = Names()
        let env = SwitcherUpdater.CheckEnvironment.live(configuration: {
            made.append("session")
            return StubProtocol.configuration(resourceTimeout: 30)
        })
        XCTAssertEqual(made.values, [], "nothing is made before a fetch")
        for _ in 0..<2 {
            guard case .candidate = await SwitcherUpdater.check(runningVersion: UpdateFixture.v070, env: env) else {
                return XCTFail("no answer")
            }
        }
        XCTAssertEqual(made.values, ["session", "session"])
        XCTAssertEqual(StubProtocol.seen.count, 2)
    }
}

// MARK: - The real release, read-only

/// The notarized v0.7.0 app in `build/` and its disk image, copied into a temporary directory
/// and checked with the real Security framework and the real hdiutil. Skipped where they are
/// absent. Signature checks here add `kSecCSNoNetworkAccess` so the test stays offline; the
/// release is stapled, which is what makes that possible.
final class SwitcherRealReleaseTests: XCTestCase {

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let builtApp = repository.appendingPathComponent("build/Claude Switcher.app").path
    private let offline = SecCSFlags(rawValue: CodeSignature.validationFlags.rawValue | SecCSFlags.noNetworkAccess.rawValue)
    private var root: URL!
    private var updates: String { root.appendingPathComponent("cfg/claude-switcher/updates").path }

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("release-\(UUID().uuidString)")
        // The config folder exists before the updater runs: the automation lock lives in it.
        try FileManager.default.createDirectory(at: base.appendingPathComponent("cfg/claude-switcher"),
                                                withIntermediateDirectories: true)
        root = URL(fileURLWithPath: SwitcherDisk.realpath(base.path)!)
    }

    override func tearDownWithError() throws {
        // Whatever this test attached is detached, and only that — found without the code under
        // test, so that no change to it can reach another image on this Mac.
        for device in Self.devicesAttached(under: root.path) {
            if case .exited(0, _, _) = SwitcherProcess.run(DiskImageTool.hdiutil, ["detach", device], deadline: 60) { continue }
            _ = SwitcherProcess.run(DiskImageTool.hdiutil, ["detach", device, "-force"], deadline: 60)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// The whole-disk devices of the images whose file is under `folder`, read straight from
    /// `hdiutil info -plist`.
    static func devicesAttached(under folder: String) -> Set<String> {
        guard case .exited(0, let output, _) = SwitcherProcess.run(DiskImageTool.hdiutil, ["info", "-plist"], deadline: 60),
              let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return [] }
        var devices: Set<String> = []
        for image in images {
            guard let path = image["image-path"] as? String,
                  (SwitcherDisk.realpath(path) ?? path).hasPrefix(folder + "/") else { continue }
            let entries = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
            if let whole = entries.min(by: { $0.count < $1.count }) { devices.insert(whole) }
        }
        return devices
    }

    private func copyOfTheBuiltApp() throws -> String {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.builtApp), "no notarized build in build/")
        let copy = root.appendingPathComponent("Claude Switcher.app").path
        try FileManager.default.copyItem(atPath: Self.builtApp, toPath: copy)
        return copy
    }

    private func releaseImage() throws -> String {
        let scratch = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_TEST_DMG"]
        let candidates = [scratch, Self.repository.appendingPathComponent("build/Claude Switcher.dmg").path].compactMap { $0 }
        guard let source = candidates.first(where: { path in
            SwitcherDisk.fileSize(path) == ReleaseFeedFixture.v070Size
                && SwitcherDisk.sha256Hex(path) == ReleaseFeedFixture.v070Digest
        }) else { throw XCTSkip("the published v0.7.0 disk image is not here") }
        let copy = root.appendingPathComponent("release.dmg").path
        try FileManager.default.copyItem(atPath: source, toPath: copy)
        return copy
    }

    func testTheBuiltAppIsThisTeamsNotarizedApp() throws {
        let app = try copyOfTheBuiltApp()
        let identity = try CodeSignature.verify(bundleAt: app, requirement: nil, flags: offline).get()
        XCTAssertEqual(identity.teamID, "FTHBLX7S63")
        XCTAssertEqual(identity.identifier, "tech.local.claude-switcher")
        XCTAssertTrue(identity.hasHardenedRuntime)
        XCTAssertFalse(identity.isAdHoc)
        XCTAssertEqual(identity.version, UpdateFixture.v070)
        let requirement = try CodeSignature.requirementForApp(team: "FTHBLX7S63", identifier: "tech.local.claude-switcher")
        XCTAssertNoThrow(try CodeSignature.verify(bundleAt: app, requirement: requirement, flags: offline).get())
    }

    /// The real environment's own signature check — the one prepare and commit both use — holds
    /// to the requirement it is handed and to strict validation. Built with the flags the app uses
    /// unless told otherwise, and kept offline here.
    func testTheLiveEnvironmentsCheckHoldsToTheRequirementAndIsStrict() throws {
        let directory = URL(fileURLWithPath: updates)
        let store = SwitcherUpdateStore(directory: directory, host: UpdateFixture.host)
        let standard = SwitcherUpdater.PrepareEnvironment.live(updatesDirectory: directory, store: store,
                                                                registry: StagedCopies(), processObserver: { _ in false })
        XCTAssertEqual(standard.verifyFlags, CodeSignature.validationFlags)

        let app = try copyOfTheBuiltApp()
        let env = SwitcherUpdater.PrepareEnvironment.live(updatesDirectory: directory, store: store, registry: StagedCopies(),
                                                           processObserver: { _ in false }, verifyFlags: offline)
        XCTAssertEqual(env.verifyFlags, offline)
        XCTAssertEqual(try env.verify(app, nil).get().teamID, "FTHBLX7S63")
        let otherTeam = try CodeSignature.requirementForApp(team: "ABCDEFGHIJ", identifier: "tech.local.claude-switcher")
        guard case .failure(let refusal) = env.verify(app, otherTeam) else { return XCTFail("another team's requirement passed") }
        XCTAssertEqual(refusal.status, -67050)
        guard case .failure(let shared) = CodeSignature.verifier(flags: offline)(app, otherTeam) else {
            return XCTFail("the shared verifier let another team's requirement pass")
        }
        XCTAssertEqual(shared.status, -67050)

        try Data("x".utf8).write(to: URL(fileURLWithPath: app + "/extra.txt"))
        guard case .failure = env.verify(app, nil) else { return XCTFail("an unsealed file passed") }
    }

    /// A requirement that does not compile fails the check: it never falls back to checking with
    /// no requirement at all.
    func testARequirementThatDoesNotCompileFailsClosed() throws {
        let app = try copyOfTheBuiltApp()
        let broken = "identifier \"unterminated"
        guard case .failure = CodeSignature.verify(bundleAt: app, requirement: broken, flags: offline) else {
            return XCTFail("a requirement that does not compile passed")
        }
    }

    /// The same without the release: a copy of a signed system tool passes with no requirement and
    /// fails at the requirement that does not compile.
    func testARequirementThatDoesNotCompileFailsClosedOnAnySignedCode() throws {
        let tool = root.appendingPathComponent("true").path
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: tool)
        XCTAssertNoThrow(try CodeSignature.verify(bundleAt: tool, requirement: nil, flags: offline).get())
        guard case .failure(let refusal) = CodeSignature.verify(bundleAt: tool, requirement: "identifier \"unterminated",
                                                                 flags: offline) else {
            return XCTFail("a requirement that does not compile passed")
        }
        XCTAssertEqual(refusal.status, -67052)
    }

    /// What `--dry-run` asks, offline: this test process is not Claude Switcher, so it is not this
    /// team's notarized app.
    func testTheRunningCopysNotarizationIsAskedOffline() {
        XCTAssertEqual(CodeSignature.runningNotarization(trust: UpdateFixture.trust, flags: CodeSignature.offlineFlags),
                       .rejected)
        // The flags asked for are the ones the check runs with, against this team's notarized app.
        let seen = Names()
        let verdict = CodeSignature.runningNotarization(trust: UpdateFixture.trust, flags: CodeSignature.offlineFlags) {
            _, flags, requirement in
            var text: CFString?
            if let requirement { _ = SecRequirementCopyString(requirement, [], &text) }
            seen.append("\(flags.rawValue) \((text as String?) ?? "none")")
            return errSecSuccess
        }
        XCTAssertEqual(verdict, .accepted)
        XCTAssertEqual(seen.values.count, 1)
        XCTAssertTrue(seen.values.first?.hasPrefix("\(CodeSignature.offlineFlags.rawValue) ") ?? false, "\(seen.values)")
        XCTAssertTrue(seen.values.first?.contains("notarized") ?? false, "\(seen.values)")
        XCTAssertTrue(seen.values.first?.contains("FTHBLX7S63") ?? false, "\(seen.values)")
    }

    func testAnotherTeamOrIdentifierIsARequirementFailure() throws {
        let app = try copyOfTheBuiltApp()
        for requirement in [try CodeSignature.requirementForApp(team: "ABCDEFGHIJ", identifier: "tech.local.claude-switcher"),
                            try CodeSignature.requirementForApp(team: "FTHBLX7S63", identifier: "tech.local.other")] {
            guard case .failure(let refusal) = CodeSignature.verify(bundleAt: app, requirement: requirement, flags: offline) else {
                return XCTFail("passed: \(requirement)")
            }
            XCTAssertEqual(refusal.status, -67050)
        }
    }

    /// A file added at the top of the bundle is caught only by strict validation.
    func testAFileAddedToTheBundleFailsTheStrictCheck() throws {
        let app = try copyOfTheBuiltApp()
        try Data("x".utf8).write(to: URL(fileURLWithPath: app + "/extra.txt"))
        guard case .failure(let refusal) = CodeSignature.verify(bundleAt: app, requirement: nil, flags: offline) else {
            return XCTFail("an unsealed file passed")
        }
        XCTAssertNotEqual(refusal.status, 0)
    }

    func testAnEditedInfoPlistFails() throws {
        let app = try copyOfTheBuiltApp()
        let plist = app + "/Contents/Info.plist"
        var text = try String(contentsOfFile: plist, encoding: .utf8)
        text = text.replacingOccurrences(of: "<string>0.7.0</string>", with: "<string>9.9.9</string>")
        try text.write(toFile: plist, atomically: false, encoding: .utf8)
        guard case .failure = CodeSignature.verify(bundleAt: app, requirement: nil, flags: offline) else {
            return XCTFail("an edited version passed")
        }
    }

    func testTheReleaseImageIsThisTeamsAndAFlippedByteIsNot() throws {
        let image = try releaseImage()
        let requirement = try CodeSignature.requirementForImage(team: "FTHBLX7S63")
        XCTAssertNoThrow(try CodeSignature.verify(bundleAt: image, requirement: requirement, flags: offline).get())
        var bytes = try Data(contentsOf: URL(fileURLWithPath: image))
        bytes[bytes.count / 2] ^= 0xFF
        let flipped = root.appendingPathComponent("flipped.dmg").path
        try bytes.write(to: URL(fileURLWithPath: flipped))
        guard case .failure = CodeSignature.verify(bundleAt: flipped, requirement: requirement, flags: offline) else {
            return XCTFail("a flipped image passed")
        }
    }

    /// Download (a local copy), hash, verify, mount with the real hdiutil, copy into a real
    /// staging folder, strip, verify again, detach — then discard. Gatekeeper's assessment is
    /// left out (spctl may ask Apple's servers); its reading is tested above.
    func testTheRealReleasePreparesEndToEndAndLeavesNothingMounted() async throws {
        let image = try releaseImage()
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications.appendingPathComponent("Claude Switcher.app"),
                                                withIntermediateDirectories: true)
        let install = applications.appendingPathComponent("Claude Switcher.app").path
        let store = SwitcherUpdateStore(directory: URL(fileURLWithPath: updates), host: UpdateFixture.host)
        let registry = StagedCopies()
        let launches = Names()
        let root = self.root.path
        var env = SwitcherUpdater.PrepareEnvironment.live(
            updatesDirectory: URL(fileURLWithPath: updates), store: store, registry: registry,
            processObserver: { launch in
                launches.append(launch.arguments.first ?? "")
                guard launch.executablePath == DiskImageTool.hdiutil else { return false }
                // Only an image this test attached may be detached, whatever the code under test asks.
                if launch.arguments.first == "detach" {
                    return launch.arguments.count >= 2
                        && Self.devicesAttached(under: root).contains(launch.arguments[1])
                }
                return true
            }, verifyFlags: offline)
        env.download = { _, destination, _ in
            (try? FileManager.default.copyItem(atPath: image, toPath: destination)) == nil
                ? .transient(.download, "copy failed") : nil
        }
        env.assess = { _ in .accepted }
        env.prewarm = { _ in }
        let candidate = ReleaseCandidate(version: UpdateFixture.v070, assetSize: ReleaseFeedFixture.v070Size,
                                         digestHex: ReleaseFeedFixture.v070Digest, immutable: false)
        let trust = SwitcherTrust(teamID: "FTHBLX7S63", identifier: "tech.local.claude-switcher", runningVersion: UpdateFixture.v060)

        let prepared = try await SwitcherUpdater.prepare(candidate: candidate, trust: trust, installPath: install,
                                                         updatesDirectory: updates, env: env).get()
        XCTAssertEqual(prepared.verifiedIdentity.version, UpdateFixture.v070)
        XCTAssertEqual(prepared.dmgPath, updates + "/downloads/v0.7.0/Claude.Switcher.dmg")
        let staging = (prepared.stagedAppPath as NSString).deletingLastPathComponent
        XCTAssertEqual((SwitcherDisk.realpath(staging)! as NSString).deletingLastPathComponent,
                       SwitcherDisk.temporaryItemsDirectory())
        XCTAssertTrue(SwitcherUpdatePolicy.stagingIsOurs(
            path: staging, temporaryItems: SwitcherDisk.temporaryItemsDirectory(), canonical: SwitcherDisk.realpath,
            lstat: SwitcherDisk.lstatKind, entries: { SwitcherDisk.listDirectory($0)?.map(\.name) },
            bundleID: SwitcherDisk.bundleIdentifier(ofBundleAt:), runningBundleID: "tech.local.claude-switcher"))
        XCTAssertEqual(launches.values, ["imageinfo", "attach", "detach", "info"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updates + "/mounts"), [])
        XCTAssertEqual(Self.devicesAttached(under: root), [])
        let state = await store.load(now: Date())
        XCTAssertEqual(state.staging, [staging])

        await SwitcherUpdater.discard(prepared, updatesDirectory: updates, env: env)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging))
        XCTAssertFalse(FileManager.default.fileExists(atPath: updates + "/downloads/v0.7.0"))
        let after = await store.load(now: Date())
        XCTAssertNil(after.staging)
    }
}
