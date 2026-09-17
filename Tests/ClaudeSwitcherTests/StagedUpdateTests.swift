import XCTest
@testable import ClaudeSwitcherCore

/// Detection of a downloaded-but-not-installed Claude update, against fixture bundles and a
/// fixture installer directory under a temporary directory. Never reads the real
/// `~/Library/Caches`, never inspects a real installer (the one process-list test only checks
/// that this process is in the list), and writes nothing outside the
/// temporary directory.
final class StagedUpdateTests: XCTestCase {

    private let bundleID = "com.example.claude"
    private var directory: URL!

    private var appPath: String { directory.appendingPathComponent("Applications/Claude.app").path }
    private var shipItPath: String { directory.appendingPathComponent("ShipIt").path }
    private var stagedPath: String { shipItPath + "/update.AbC123/Claude.app" }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-switcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func makeBundle(at path: String, short: String, build: String) throws {
        let contents = URL(fileURLWithPath: path).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": short,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// A `file:` URL string the way the installer writes one: percent-encoded, trailing slash.
    private func fileURLString(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).absoluteString
    }

    private func writeState(_ fields: [String: Any]) throws {
        try FileManager.default.createDirectory(atPath: shipItPath, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: fields)
        try data.write(to: URL(fileURLWithPath: shipItPath).appendingPathComponent("ShipItState.plist"))
    }

    private func state(target: String? = nil, update: String? = nil) -> [String: Any] {
        [
            "bundleIdentifier": bundleID,
            "targetBundleURL": fileURLString(target ?? appPath),
            "updateBundleURL": fileURLString(update ?? stagedPath),
            "useUpdateBundleName": true,
            "launchAfterInstallation": false,
        ]
    }

    /// Installed 2.110.0, staged 2.110.1, and a request file pointing one at the other.
    private func stageAnUpdate() throws {
        try makeBundle(at: appPath, short: "2.110.0", build: "100")
        try makeBundle(at: stagedPath, short: "2.110.1", build: "101")
        try writeState(state())
    }

    private func probe(appPath: String? = nil, shipItDirectory: String? = nil) -> StagedUpdate? {
        UpdateProbe.stagedUpdate(
            appPath: appPath ?? self.appPath,
            bundleID: bundleID,
            shipItDirectory: shipItDirectory ?? shipItPath
        )
    }

    // MARK: - The request file

    func testStateFileIsParsedAsJSONDespiteItsPlistExtension() throws {
        let data = try JSONSerialization.data(withJSONObject: state())
        let parsed = try XCTUnwrap(UpdateProbe.parseState(data))
        XCTAssertEqual(parsed.bundleIdentifier, bundleID)
        XCTAssertEqual(parsed.targetBundleURL, fileURLString(appPath))
        XCTAssertEqual(parsed.useUpdateBundleName, true)
    }

    func testAnActualPropertyListEmptyOrGarbageStateIsRejectedRatherThanCrashing() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: state(), format: .xml, options: 0)
        XCTAssertNil(UpdateProbe.parseState(plist))
        XCTAssertNil(UpdateProbe.parseState(Data()))
        XCTAssertNil(UpdateProbe.parseState(Data([0x00, 0xFF, 0x13, 0x37])))
        XCTAssertNil(UpdateProbe.parseState(Data("[1, 2, 3]".utf8)))
    }

    func testStateMissingTheBundleIdentifierYieldsNoStagedUpdate() throws {
        try stageAnUpdate()
        var fields = state()
        fields.removeValue(forKey: "bundleIdentifier")
        try writeState(fields)
        XCTAssertNil(probe())
    }

    func testStateForADifferentBundleIdentifierIsIgnored() throws {
        try stageAnUpdate()
        var fields = state()
        fields["bundleIdentifier"] = "com.example.some-other-squirrel-app"
        try writeState(fields)
        XCTAssertNil(probe())
    }

    func testStateTargetingADifferentCopyOfTheAppIsIgnored() throws {
        try stageAnUpdate()
        let otherCopy = directory.appendingPathComponent("Elsewhere/Claude.app").path
        try makeBundle(at: otherCopy, short: "2.110.0", build: "100")
        try writeState(state(target: otherCopy))
        XCTAssertNil(probe())
    }

    func testMissingRequestFileMeansNothingIsStaged() throws {
        try makeBundle(at: appPath, short: "2.110.0", build: "100")
        XCTAssertNil(probe())
    }

    // MARK: - What counts as pending

    func testStagedUpdateIsReportedWithBothVersions() throws {
        try stageAnUpdate()
        let update = try XCTUnwrap(probe())
        XCTAssertEqual(update.installed, AppVersion(short: "2.110.0", build: "100"))
        XCTAssertEqual(update.staged, AppVersion(short: "2.110.1", build: "101"))
        XCTAssertEqual(update.updateBundlePath, UpdateProbe.canonical(stagedPath))
        XCTAssertEqual(update.staged.description, "2.110.1")
    }

    /// The installer leaves its request file behind after a successful install but removes the
    /// downloaded bundle, so a request alone must never read as "an update is waiting".
    func testLingeringStateWhoseStagedBundleIsGoneMeansNothingIsPending() throws {
        try stageAnUpdate()
        try FileManager.default.removeItem(atPath: shipItPath + "/update.AbC123")
        XCTAssertNil(probe())
    }

    func testStagedVersionEqualToInstalledMeansNothingIsPending() throws {
        try stageAnUpdate()
        try makeBundle(at: appPath, short: "2.110.1", build: "101")
        XCTAssertNil(probe())
    }

    /// A rollback is staged the same way as an upgrade, and blocks the same way.
    func testAnOlderStagedVersionIsStillPendingBecauseTheInstallerInstallsWhateverIsStaged() throws {
        try stageAnUpdate()
        try makeBundle(at: appPath, short: "2.111.0", build: "110")
        XCTAssertEqual(probe()?.staged.short, "2.110.1")
    }

    /// With `useUpdateBundleName` the installer renames the app to the downloaded bundle's
    /// name, which would move it out from under the configured path.
    func testUpdateThatWouldRenameTheAppIsNotOffered() throws {
        try makeBundle(at: appPath, short: "2.110.0", build: "100")
        let renamed = shipItPath + "/update.AbC123/Claude Next.app"
        try makeBundle(at: renamed, short: "3.0.0", build: "300")
        try writeState(state(update: renamed))
        XCTAssertNil(probe())

        var fields = state(update: renamed)
        fields["useUpdateBundleName"] = false
        try writeState(fields)
        XCTAssertEqual(probe()?.staged.short, "3.0.0")
    }

    // MARK: - Paths

    func testPercentEncodedFileURLsDecodeToRealPaths() throws {
        let spacedApp = directory.appendingPathComponent("My Applications/Claude Beta.app").path
        let spacedUpdate = shipItPath + "/update.AbC123/Claude Beta.app"
        try makeBundle(at: spacedApp, short: "1.0", build: "1")
        try makeBundle(at: spacedUpdate, short: "1.1", build: "2")
        try writeState(state(target: spacedApp, update: spacedUpdate))

        XCTAssertTrue(fileURLString(spacedApp).contains("%20"), "fixture should exercise percent-encoding")
        XCTAssertEqual(probe(appPath: spacedApp)?.staged.short, "1.1")
    }

    func testTrailingAndDuplicateSlashesInTheConfiguredAppPathAreIgnored() throws {
        try stageAnUpdate()
        let sloppy = appPath.replacingOccurrences(of: "/Applications/", with: "//Applications///") + "//"
        XCTAssertNotNil(probe(appPath: sloppy))
    }

    /// The temporary directory is reachable as both `/var/…` and `/private/var/…`; the
    /// installer and the config need not agree on the spelling.
    func testVarAndPrivateVarSpellingsOfTheSameDirectoryAgree() throws {
        try XCTSkipUnless(directory.path.hasPrefix("/var/"), "temporary directory is not under /var")
        try stageAnUpdate()
        XCTAssertNotNil(probe(appPath: "/private" + appPath, shipItDirectory: "/private" + shipItPath))
    }

    func testNonFileURLSchemesAreRejected() throws {
        try stageAnUpdate()
        var fields = state()
        fields["updateBundleURL"] = "https://example.com/Claude.app/"
        try writeState(fields)
        XCTAssertNil(probe())
        XCTAssertNil(UpdateProbe.filePath(fromURLString: "https://example.com/Claude.app/"))
        XCTAssertNil(UpdateProbe.filePath(fromURLString: "not a url at all"))
        XCTAssertNil(UpdateProbe.filePath(fromURLString: nil))
    }

    func testUpdateBundleOutsideTheInstallerDirectoryIsNotAStagedUpdate() throws {
        try stageAnUpdate()
        let outside = directory.appendingPathComponent("Downloads/Claude.app").path
        try makeBundle(at: outside, short: "9.9.9", build: "999")
        try writeState(state(update: outside))
        XCTAssertNil(probe())
    }

    func testDotDotComponentsCannotEscapeTheInstallerDirectory() throws {
        try stageAnUpdate()
        let outside = directory.appendingPathComponent("Downloads/Claude.app").path
        try makeBundle(at: outside, short: "9.9.9", build: "999")
        var fields = state()
        fields["updateBundleURL"] = "file://" + shipItPath + "/../Downloads/Claude.app/"
        try writeState(fields)
        XCTAssertNil(probe())
    }

    func testSymlinkInsideTheInstallerDirectoryCannotPointTheProbeOutsideIt() throws {
        try stageAnUpdate()
        let outside = directory.appendingPathComponent("Downloads/Claude.app").path
        try makeBundle(at: outside, short: "9.9.9", build: "999")
        let link = shipItPath + "/update.link"
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: (outside as NSString).deletingLastPathComponent)
        try writeState(state(update: link + "/Claude.app"))
        XCTAssertNil(probe())
    }

    func testInstallerDirectoryIsDerivedFromTheBundleIdentifierNeverHardcoded() {
        XCTAssertEqual(
            UpdateProbe.shipItDirectory(bundleID: "com.example.claude", home: "/Users/testhome"),
            "/Users/testhome/Library/Caches/com.example.claude.ShipIt"
        )
        XCTAssertEqual(
            UpdateProbe.shipItDirectory(bundleID: "org.other.beta", home: "/Users/testhome"),
            "/Users/testhome/Library/Caches/org.other.beta.ShipIt"
        )
    }

    // MARK: - Versions

    /// `Bundle` caches a bundle's info dictionary per path; reading through it would never
    /// notice the installer replacing the app. This read must see the change.
    func testVersionIsReadFreshFromDiskEveryTime() throws {
        try makeBundle(at: appPath, short: "2.110.0", build: "100")
        XCTAssertEqual(UpdateProbe.version(ofBundleAt: appPath)?.short, "2.110.0")
        try makeBundle(at: appPath, short: "2.110.1", build: "101")
        XCTAssertEqual(UpdateProbe.version(ofBundleAt: appPath)?.short, "2.110.1")
    }

    func testBundleWithoutAReadableInfoPlistHasNoVersion() throws {
        XCTAssertNil(UpdateProbe.version(ofBundleAt: appPath))
        try FileManager.default.createDirectory(atPath: appPath + "/Contents", withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
        XCTAssertNil(UpdateProbe.version(ofBundleAt: appPath))
    }

    func testVersionFallsBackToTheBuildNumberWhenThereIsNoShortVersion() {
        XCTAssertEqual(AppVersion(short: "", build: "4711").description, "4711")
    }

    // MARK: - The installer process

    func testInstallerIsRecognisedByExecutableNameAndJobLabel() {
        let argv = [
            "/Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt",
            "com.example.claude.ShipIt",
            "/Users/testhome/Library/Caches/com.example.claude.ShipIt/ShipItState.plist",
        ]
        XCTAssertTrue(UpdateProbe.isUpdaterCommandLine(argv, bundleID: "com.example.claude"))
    }

    func testAnotherAppsInstallerIsNotOurs() {
        let argv = [
            "/Applications/Discord.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt",
            "com.hnc.Discord.ShipIt",
            "/Users/testhome/Library/Caches/com.hnc.Discord.ShipIt/ShipItState.plist",
        ]
        XCTAssertFalse(UpdateProbe.isUpdaterCommandLine(argv, bundleID: "com.example.claude"))
    }

    func testUnreadableShortOrUnrelatedArgvIsNotAnInstaller() {
        XCTAssertFalse(UpdateProbe.isUpdaterCommandLine(nil, bundleID: bundleID))
        XCTAssertFalse(UpdateProbe.isUpdaterCommandLine([], bundleID: bundleID))
        XCTAssertFalse(UpdateProbe.isUpdaterCommandLine(["/x/ShipIt"], bundleID: bundleID))
        XCTAssertFalse(UpdateProbe.isUpdaterCommandLine(
            ["/Applications/Claude.app/Contents/MacOS/Claude", "\(bundleID).ShipIt"], bundleID: bundleID))
    }

    /// `proc_listallpids` takes a size in bytes and returns a count; mixing the two up would
    /// silently scan a quarter of the process table. This process must be in the list.
    func testProcessListIncludesThisProcess() {
        let pids = UpdateProbe.allPIDs()
        XCTAssertTrue(pids.contains(getpid()))
        XCTAssertGreaterThan(pids.count, 10)
    }

    /// Quitting every profile is only worth offering while something is there to install.
    func testStagedUpdateIsOnlyBlockedWhileAnInstallerIsAlive() {
        let staged = StagedUpdate(
            installed: AppVersion(short: "2.110.0", build: "100"),
            staged: AppVersion(short: "2.110.1", build: "101"),
            updateBundlePath: "/tmp/update/Claude.app"
        )
        XCTAssertEqual(UpdateStatus(installed: staged.installed, staged: staged, updaterIsRunning: true).blocked, staged)
        XCTAssertNil(UpdateStatus(installed: staged.installed, staged: staged, updaterIsRunning: false).blocked)
        XCTAssertNil(UpdateStatus(installed: staged.installed, staged: nil, updaterIsRunning: true).blocked)
    }
}
