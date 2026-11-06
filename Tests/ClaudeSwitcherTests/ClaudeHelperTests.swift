import XCTest
@testable import ClaudeSwitcherCore

final class ClaudeHelperTests: XCTestCase {

    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "ClaudeHelperTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: home)
    }

    /// Lays out a copy; `executable: false` leaves the file there but not runnable.
    @discardableResult
    private func install(_ relative: String, account: String = "Claude", executable: Bool = true) throws -> String {
        let bundle = "\(home!)/\(account)/claude-code/\(relative)/claude.app"
        let folder = bundle + "/Contents/MacOS"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let file = folder + "/claude"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(executable ? 0o755 : 0o644))],
                                              ofItemAtPath: file)
        return bundle
    }

    private func dir(_ account: String = "Claude") -> String { "\(home!)/\(account)" }

    private func identity(team: String?, flags: UInt32 = 0) -> CodeIdentity {
        CodeIdentity(teamID: team, identifier: "x", flags: flags, version: nil, path: nil)
    }

    // MARK: Finding it

    /// The layout on a Mac today, which Diagnostics had stopped finding: a folder per build
    /// inside the folder per version.
    func testFindsACopyInsideItsBuildFolder() throws {
        let bundle = try install("2.1.317/91184d3d9ba3")
        XCTAssertEqual(ClaudeHelper.newest(userDataDirs: [dir()]), .init(version: "2.1.317", bundlePath: bundle))
    }

    func testStillFindsTheOlderLayout() throws {
        let bundle = try install("2.1.100")
        XCTAssertEqual(ClaudeHelper.newest(userDataDirs: [dir()])?.bundlePath, bundle)
    }

    func testVersionsCompareAsNumbersNotText() throws {
        try install("2.1.99/aaa")
        let newest = try install("2.1.317/bbb")
        XCTAssertEqual(ClaudeHelper.newest(userDataDirs: [dir()])?.bundlePath, newest)
    }

    /// Each account keeps its own copies, and they lag behind one another.
    func testTheNewestCopyOfAnyAccountWins() throws {
        try install("2.1.309/aaa", account: "Claude-work")
        let newest = try install("2.1.317/bbb", account: "Claude")
        XCTAssertEqual(ClaudeHelper.newest(userDataDirs: [dir("Claude-work"), dir("Claude")])?.bundlePath, newest)
    }

    /// A half-installed newer copy must not hide the one that runs.
    func testAFolderWithNoRunnableProgramIsPassedOver() throws {
        let working = try install("2.1.309/aaa")
        try install("2.1.317/bbb", executable: false)
        XCTAssertEqual(ClaudeHelper.newest(userDataDirs: [dir()])?.bundlePath, working)
    }

    /// `.numeric` ranks `latest` above every version, so it must not be in the running.
    func testAFolderNotNamedAsAVersionIsPassedOver() throws {
        let working = try install("2.1.9/aaa")
        try install("latest/bbb")
        try install("2.1.317-beta/ccc")
        XCTAssertEqual(ClaudeHelper.newest(userDataDirs: [dir()])?.bundlePath, working)
    }

    func testAnAccountThatNeverRanTheCodeTabHasNoCopy() {
        XCTAssertNil(ClaudeHelper.newest(userDataDirs: [dir("Claude-nothing-here")]))
    }

    /// Otherwise a copy left in the default folder is missed by someone who only uses a named
    /// account, or the other way round.
    func testEveryAccountIsLookedInAndTheDefaultComesFirst() {
        var config = Config.defaultConfig()
        config.profiles = [Profile(id: "a", label: "Default"),
                           Profile(id: "b", label: "Work", userDataDir: "~/Library/Application Support/Claude-work")]
        XCTAssertEqual(ClaudeHelper.userDataDirs(of: config, home: "/Users/me"),
                       ["/Users/me/Library/Application Support/Claude", "/Users/me/Library/Application Support/Claude-work"])
    }

    func testTheExecutableIsWhereTheBundleSaysItIs() {
        XCTAssertEqual(ClaudeHelper.Location(version: "1", bundlePath: "/a/claude.app").executablePath,
                       "/a/claude.app/Contents/MacOS/claude")
    }

    // MARK: Who signed it

    private let team = "AAAAAAAAAA"
    private let app = "/Applications/Claude.app"
    private let altered = SignatureRefusal(status: -67061, message: "a sealed resource is missing")
    private let wrongSigner = SignatureRefusal(status: CodeSignature.requirementFailed, message: "the requirement was not met")

    /// Answers by path: `helper` for anything inside `claude-code`, `claudeApp` for the rest.
    private func verifier(helper: Result<CodeIdentity, SignatureRefusal>,
                          claudeApp: Result<CodeIdentity, SignatureRefusal>) -> CodeSignature.Verify {
        { path, _ in path.contains("/claude-code/") ? helper : claudeApp }
    }

    func testNothingInstalled() {
        let check = ClaudeHelper.check(appPath: app, userDataDirs: [dir()],
                                       verify: verifier(helper: .failure(altered), claudeApp: .failure(altered)))
        XCTAssertEqual(check, .notInstalled)
    }

    func testASignedCopyFromTheSameTeamIsReady() throws {
        let bundle = try install("2.1.317/bbb")
        let check = ClaudeHelper.check(appPath: app, userDataDirs: [dir()],
                                       verify: verifier(helper: .success(identity(team: team)), claudeApp: .success(identity(team: team))))
        XCTAssertEqual(check, .ready(.init(version: "2.1.317", bundlePath: bundle)))
    }

    /// The case the whole check exists for: something else sitting where the program should be.
    func testACopyThatFailsTheRequirementIsNotRecommended() throws {
        let bundle = try install("2.1.317/bbb")
        let check = ClaudeHelper.check(appPath: app, userDataDirs: [dir()],
                                       verify: verifier(helper: .failure(wrongSigner), claudeApp: .success(identity(team: team))))
        XCTAssertEqual(check, .unverified(bundlePath: bundle, reason: "it is not signed by the developer of Claude.app"))
    }

    func testAnAlteredCopyIsNotRecommended() throws {
        let bundle = try install("2.1.317/bbb")
        let check = ClaudeHelper.check(appPath: app, userDataDirs: [dir()],
                                       verify: verifier(helper: .failure(altered), claudeApp: .success(identity(team: team))))
        XCTAssertEqual(check, .unverified(bundlePath: bundle, reason: "its signature did not check out: a sealed resource is missing"))
    }

    /// With nothing to compare against, the copy is not vouched for.
    func testAnUnreadableClaudeAppVouchesForNothing() throws {
        let bundle = try install("2.1.317/bbb")
        let check = ClaudeHelper.check(appPath: app, userDataDirs: [dir()],
                                       verify: verifier(helper: .success(identity(team: team)), claudeApp: .failure(altered)))
        XCTAssertEqual(check, .unverified(bundlePath: bundle, reason: "Claude.app\u{2019}s signature did not check out: a sealed resource is missing"))
    }

    /// No team, an empty one, text that is not a team, or an ad-hoc signature: there is no
    /// developer to ask for, and the program is not even hashed.
    func testAClaudeAppWithNoDeveloperVouchesForNothing() throws {
        let bundle = try install("2.1.317/bbb")
        let adHoc: UInt32 = 0x2
        for identity in [identity(team: nil), identity(team: ""), identity(team: "not a team"), identity(team: team, flags: adHoc)] {
            let seen = VerifyLog()
            let verify: CodeSignature.Verify = { path, requirement in
                seen.add(path, requirement)
                return .success(identity)
            }
            let check = ClaudeHelper.check(appPath: app, userDataDirs: [dir()], verify: verify)
            XCTAssertEqual(check, .unverified(bundlePath: bundle, reason: "Claude.app has no developer to compare it with"))
            XCTAssertEqual(seen.paths, [app])
        }
    }

    /// `Claude.app` is read first, with no requirement; the program must then meet one naming
    /// the team that signature gave.
    func testTheProgramIsHeldToARequirementForClaudeAppsTeam() throws {
        let bundle = try install("2.1.317/bbb")
        let seen = VerifyLog()
        let verify: CodeSignature.Verify = { [team] path, requirement in
            seen.add(path, requirement)
            return .success(CodeIdentity(teamID: team, identifier: "x", flags: 0, version: nil, path: nil))
        }
        _ = ClaudeHelper.check(appPath: app, userDataDirs: [dir()], verify: verify)
        XCTAssertEqual(seen.paths, [app, bundle])
        let expected: [String?] = [nil, try CodeSignature.requirementForDeveloper(team: team)]
        XCTAssertEqual(seen.requirements, expected)
    }

    func testTheRequirementPinsDeveloperIDAndTheTeam() throws {
        XCTAssertEqual(try CodeSignature.requirementForDeveloper(team: team),
                       "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
                           + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
                           + "and certificate leaf[subject.OU] = \"AAAAAAAAAA\"")
    }

    func testTheRequirementTakesNothingThatCouldCloseItsQuote() {
        XCTAssertThrowsError(try CodeSignature.requirementForDeveloper(team: "AAAAAAAAA\""))
    }

    /// Against a real signature, Apple's own `true`: the text compiles, and code from anyone
    /// else fails as a requirement, which is what names the developer in the alert.
    func testARealSignatureFromElsewhereFailsTheRequirement() throws {
        let requirement = try CodeSignature.requirementForDeveloper(team: team)
        let result = CodeSignature.verify(bundleAt: "/usr/bin/true", requirement: requirement, flags: CodeSignature.offlineFlags)
        guard case .failure(let refusal) = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertEqual(refusal.status, CodeSignature.requirementFailed)
    }

    // MARK: System Settings

    /// A typo here opens Privacy & Security's front page and the instructions stop matching.
    func testTheLinkNamesTheFullDiskAccessPage() {
        let link = ClaudeHelper.fullDiskAccessSettings
        XCTAssertEqual(link.scheme, "x-apple.systempreferences")
        XCTAssertTrue(link.absoluteString.hasSuffix("com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"))
    }
}

private final class VerifyLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var paths: [String] = []
    private(set) var requirements: [String?] = []

    func add(_ path: String, _ requirement: String?) {
        lock.lock()
        defer { lock.unlock() }
        paths.append(path)
        requirements.append(requirement)
    }
}
