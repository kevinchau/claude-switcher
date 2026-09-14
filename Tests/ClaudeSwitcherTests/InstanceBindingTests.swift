import XCTest
@testable import ClaudeSwitcherCore

/// Covers how a live process is attributed to a profile — the logic that decides which
/// account the user is actually looking at.
final class InstanceBindingTests: XCTestCase {

    // MARK: - KERN_PROCARGS2 buffer parsing

    /// Builds a synthetic KERN_PROCARGS2 payload:
    /// `[int32 argc][execPath NUL][padding][argv0 NUL]...[argvN NUL][env...]`
    private func procargs(argc: Int32, execPath: String, padding: Int,
                          args: [String], trailing: [String] = []) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: argc) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(execPath.utf8)); bytes.append(0)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for a in args { bytes.append(contentsOf: Array(a.utf8)); bytes.append(0) }
        for e in trailing { bytes.append(contentsOf: Array(e.utf8)); bytes.append(0) }
        return bytes
    }

    func testParsesArgumentsAcrossAlignmentPadding() {
        let args = ["/Applications/Claude.app/Contents/MacOS/Claude",
                    "--user-data-dir=/Users/me/Library/Application Support/Claude-Work"]
        let buffer = procargs(argc: 2, execPath: "/Applications/Claude.app/Contents/MacOS/Claude",
                              padding: 5, args: args)
        XCTAssertEqual(ProcessArgs.parseArgumentBuffer(buffer), args)
    }

    /// The reason we read argv from the kernel instead of parsing `ps` output: a path with
    /// spaces must survive as ONE argument.
    func testArgumentContainingSpacesStaysASingleArgument() {
        let dir = "--user-data-dir=/Users/me/Library/Application Support/Claude-Work"
        let buffer = procargs(argc: 2, execPath: "/x/Claude", padding: 1, args: ["/x/Claude", dir])
        let parsed = ProcessArgs.parseArgumentBuffer(buffer)
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?.last, dir)
    }

    func testDoesNotReadPastArgcIntoTheEnvironment() {
        let buffer = procargs(argc: 2, execPath: "/x/Claude", padding: 1,
                              args: ["/x/Claude", "--flag"],
                              trailing: ["SECRET=should-not-appear"])
        let parsed = ProcessArgs.parseArgumentBuffer(buffer)
        XCTAssertEqual(parsed, ["/x/Claude", "--flag"])
        XCTAssertFalse(parsed?.contains(where: { $0.contains("SECRET") }) ?? true)
    }

    /// A truncated buffer must fail rather than invent a final argument — that value decides
    /// account attribution.
    func testTruncatedBufferFailsInsteadOfFabricatingAnArgument() {
        var buffer = procargs(argc: 2, execPath: "/x/Claude", padding: 1,
                              args: ["/x/Claude", "--user-data-dir=/Users/me/Claude-Work"])
        buffer.removeLast(6)   // chop the final NUL and some bytes
        XCTAssertNil(ProcessArgs.parseArgumentBuffer(buffer))
    }

    func testGarbageBuffersAreRejectedRatherThanCrashing() {
        XCTAssertNil(ProcessArgs.parseArgumentBuffer([]))
        XCTAssertNil(ProcessArgs.parseArgumentBuffer([1, 2]))
        XCTAssertNil(ProcessArgs.parseArgumentBuffer([0, 0, 0, 0]))              // argc == 0
        XCTAssertNil(ProcessArgs.parseArgumentBuffer([0xFF, 0xFF, 0xFF, 0xFF]))  // argc negative
    }

    // MARK: - Argument vector -> profile

    func testNoUserDataDirArgumentIsTheDefaultProfile() {
        XCTAssertEqual(InstanceManager.profileBinding(fromArguments: ["/x/Claude"]), .defaultProfile)
    }

    func testEqualsFormAndSpaceSeparatedFormAgree() {
        let dir = "/Users/me/Library/Application Support/Claude-Work"
        XCTAssertEqual(InstanceManager.profileBinding(fromArguments: ["/x/Claude", "--user-data-dir=\(dir)"]),
                       .directory(dir))
        XCTAssertEqual(InstanceManager.profileBinding(fromArguments: ["/x/Claude", "--user-data-dir", dir]),
                       .directory(dir))
    }

    func testUserDataDirIsNormalizedSoSpellingsCollapse() {
        let a = InstanceManager.profileBinding(fromArguments: ["/x", "--user-data-dir=/tmp/claude-work/"])
        let b = InstanceManager.profileBinding(fromArguments: ["/x", "--user-data-dir=/tmp//claude-work"])
        XCTAssertEqual(a, b)
    }

    /// The bug this guards: an unreadable argv must NOT be reported as "no --user-data-dir",
    /// because that is how the default account is identified.
    func testUnreadableArgvIsUnknownNotTheDefaultProfile() {
        XCTAssertEqual(InstanceManager.profileBinding(fromArguments: nil), .unknown)
        XCTAssertNotEqual(InstanceManager.profileBinding(fromArguments: nil), .defaultProfile)
    }

    // MARK: - Matching instances to profiles

    private let defaultProfile = Profile(id: "default", label: "Personal", userDataDir: nil, credDir: nil)
    private let workProfile = Profile(id: "work", label: "Work",
                                      userDataDir: "/tmp/Claude-Work", credDir: "/tmp/creds-work")

    func testDefaultProfileMatchesOnlyAnInstanceWithNoUserDataDir() {
        let running = [RunningInstance(pid: 1, profile: .defaultProfile),
                       RunningInstance(pid: 2, profile: .directory("/tmp/Claude-Work"))]
        XCTAssertEqual(ProfileMatching.instance(for: defaultProfile, in: running)?.pid, 1)
        XCTAssertEqual(ProfileMatching.instance(for: workProfile, in: running)?.pid, 2)
    }

    /// An unreadable process must never be claimed by the default profile — otherwise the menu
    /// shows the wrong account as running and "switching" focuses someone else's window.
    func testUnknownInstanceIsClaimedByNoProfile() {
        let running = [RunningInstance(pid: 42, profile: .unknown)]
        XCTAssertNil(ProfileMatching.instance(for: defaultProfile, in: running))
        XCTAssertNil(ProfileMatching.instance(for: workProfile, in: running))
        XCTAssertFalse(ProfileMatching.isRunning(defaultProfile, in: running))
        XCTAssertEqual(ProfileMatching.unmatched(running, profiles: [defaultProfile, workProfile]).count, 1)
    }

    func testInstanceForAnUnconfiguredDirectoryIsUnmatched() {
        let running = [RunningInstance(pid: 7, profile: .directory("/tmp/Claude-Gone"))]
        XCTAssertEqual(ProfileMatching.unmatched(running, profiles: [defaultProfile, workProfile]).map(\.pid), [7])
    }

    // MARK: - Launch plan derivations

    func testDefaultProfileNeverReceivesUserDataDir() {
        XCTAssertEqual(LaunchPlanning.launchArguments(for: defaultProfile), [])
    }

    func testNamedProfileReceivesExactlyOneNormalizedUserDataDirArgument() {
        let profile = Profile(id: "w", label: "W", userDataDir: "/tmp//Claude-Work/", credDir: nil)
        XCTAssertEqual(LaunchPlanning.launchArguments(for: profile), ["--user-data-dir=/tmp/Claude-Work"])
    }

    /// Omitting the variable is what selects the default credential slot; exporting an empty
    /// string is a different thing entirely and must never be emitted.
    func testDefaultProfileTerminalCommandOmitsTheVariable() {
        let command = LaunchPlanning.terminalCommand(for: defaultProfile)
        XCTAssertEqual(command, "claude")
        XCTAssertFalse(command.contains("CLAUDE_SECURESTORAGE_CONFIG_DIR"))
    }

    func testNamedProfileTerminalCommandQuotesThePath() {
        let profile = Profile(id: "w", label: "W", userDataDir: nil,
                              credDir: "/Users/me/Library/Application Support/creds")
        XCTAssertEqual(LaunchPlanning.terminalCommand(for: profile),
                       "CLAUDE_SECURESTORAGE_CONFIG_DIR=\"/Users/me/Library/Application Support/creds\" claude")
    }

    func testTerminalCommandNeverEmitsCLAUDE_CONFIG_DIR() {
        for profile in [defaultProfile, workProfile] {
            XCTAssertFalse(LaunchPlanning.terminalCommand(for: profile).contains("CLAUDE_CONFIG_DIR="))
        }
    }
}
