import XCTest
@testable import ClaudeSwitcherCore

/// The "block Claude auto-updates" policy files. Everything happens under a temporary `home`;
/// the real `~/Library/Application Support` is never read or written.
final class UpdateBlockTests: XCTestCase {

    private var home: URL!
    private let named = "~/Library/Application Support/Claude-second"

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-switcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    private func library(_ userDataDir: String?) -> URL {
        UpdateBlock.policyDirectory(forUserDataDir: userDataDir, home: home.path)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// Every file under `home`, as relative paths.
    private func tree() -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: home.path)
        return (enumerator?.allObjects as? [String] ?? [])
            .filter { var isDir: ObjCBool = false
                      FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path, isDirectory: &isDir)
                      return !isDir.boolValue }
            .sorted()
    }

    // MARK: - Where

    func testTheDefaultProfileUsesClaude3pAndANamedProfileItsOwnSibling() {
        XCTAssertEqual(library(nil).path, home.path + "/Library/Application Support/Claude-3p/configLibrary")
        XCTAssertEqual(library(named).path, home.path + "/Library/Application Support/Claude-second-3p/configLibrary")
    }

    // MARK: - On

    func testTurningTheBlockOnWritesOnlyTheTwoFilesAndPointsTheIndexAtOurs() throws {
        XCTAssertEqual(UpdateBlock.state(userDataDir: named, home: home.path), .off)

        XCTAssertEqual(try UpdateBlock.apply(userDataDir: named, home: home.path), .on)

        let base = "Library/Application Support/Claude-second-3p/configLibrary/"
        XCTAssertEqual(tree(), [base + UpdateBlock.configID + ".json", base + "_meta.json"])

        let config = try json(library(named).appendingPathComponent(UpdateBlock.configID + ".json"))
        XCTAssertEqual(config.count, 1)
        XCTAssertEqual(config["disableAutoUpdates"] as? Bool, true)

        let meta = try json(library(named).appendingPathComponent("_meta.json"))
        XCTAssertEqual(meta["appliedId"] as? String, UpdateBlock.configID)
        let entries = try XCTUnwrap(meta["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["id"] as? String }, [UpdateBlock.configID])
    }

    /// Claude only accepts an applied id that is a lowercase UUID.
    func testOurConfigurationIdIsTheKindOfIdClaudeAccepts() {
        XCTAssertNotNil(UpdateBlock.configID.range(of: "^[a-f0-9-]{36}$", options: .regularExpression))
        XCTAssertNotNil(UUID(uuidString: UpdateBlock.configID))
    }

    func testFilesArePrivateToTheUser() throws {
        try UpdateBlock.apply(userDataDir: nil, home: home.path)
        for name in ["_meta.json", UpdateBlock.configID + ".json"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: library(nil).appendingPathComponent(name).path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600, name)
        }
    }

    func testApplyIsIdempotent() throws {
        try UpdateBlock.apply(userDataDir: named, home: home.path)
        let first = try Data(contentsOf: library(named).appendingPathComponent("_meta.json"))
        XCTAssertEqual(try UpdateBlock.apply(userDataDir: named, home: home.path), .on)
        XCTAssertEqual(try Data(contentsOf: library(named).appendingPathComponent("_meta.json")), first)
        XCTAssertEqual(tree().count, 2)
    }

    /// A crash between the two writes leaves our configuration without an index. That is
    /// ours to finish, in either direction.
    func testAHalfWrittenLibraryOfOursIsRepairedOrRemoved() throws {
        try write(["disableAutoUpdates": true], to: library(named).appendingPathComponent(UpdateBlock.configID + ".json"))
        XCTAssertEqual(UpdateBlock.state(userDataDir: named, home: home.path), .damaged)
        XCTAssertEqual(try UpdateBlock.apply(userDataDir: named, home: home.path), .on)

        try FileManager.default.removeItem(at: library(named).appendingPathComponent(UpdateBlock.configID + ".json"))
        XCTAssertEqual(UpdateBlock.state(userDataDir: named, home: home.path), .damaged)
        XCTAssertEqual(try UpdateBlock.remove(userDataDir: named, home: home.path), .off)
        XCTAssertEqual(tree(), [])
    }

    // MARK: - Never someone else's

    func testALibraryWeDidNotCreateIsNeverTouched() throws {
        let theirs = "0b8f2d6e-1111-4222-8333-444455556666"
        try write(["appliedId": theirs, "entries": [["id": theirs, "name": "Bedrock"]]],
                  to: library(named).appendingPathComponent("_meta.json"))
        try write(["inferenceProvider": "bedrock"], to: library(named).appendingPathComponent(theirs + ".json"))
        let before = tree().map { ($0, try? Data(contentsOf: home.appendingPathComponent($0))) }

        guard case .foreign = UpdateBlock.state(userDataDir: named, home: home.path) else { return XCTFail() }
        guard case .foreign = try UpdateBlock.apply(userDataDir: named, home: home.path) else { return XCTFail("apply") }
        guard case .foreign = try UpdateBlock.remove(userDataDir: named, home: home.path) else { return XCTFail("remove") }

        let after = tree().map { ($0, try? Data(contentsOf: home.appendingPathComponent($0))) }
        XCTAssertEqual(before.map(\.0), after.map(\.0))
        XCTAssertEqual(before.map(\.1), after.map(\.1))
    }

    func testAStrayFileInAnOtherwiseEmptyLibraryIsSomeoneElsesToo() throws {
        try write(["x": 1], to: library(nil).appendingPathComponent("draft.json"))
        guard case .foreign = try UpdateBlock.apply(userDataDir: nil, home: home.path) else { return XCTFail() }
        XCTAssertEqual(tree().count, 1)
    }

    /// An organization-managed library carries a `hybridPointer`; even with our id applied,
    /// the index is no longer exactly what we wrote.
    func testAHybridPointerIsSomeoneElses() throws {
        try write(["appliedId": UpdateBlock.configID, "hybridPointer": "https://example.com/policy"],
                  to: library(named).appendingPathComponent("_meta.json"))
        guard case .foreign = UpdateBlock.state(userDataDir: named, home: home.path) else { return XCTFail() }
        guard case .foreign = try UpdateBlock.remove(userDataDir: named, home: home.path) else { return XCTFail("remove") }
        XCTAssertEqual(tree().count, 1)
    }

    // MARK: - "Exists, but is not ours" is never treated as ours

    /// Claude's setup screen saves into whichever configuration is open — and with the block
    /// on, ours is the only one. After that, the file with our id holds the user's provider
    /// settings. It must never be rewritten (not even by the startup reconcile) or removed.
    func testAConfigurationEditedInClaudesOwnSetupScreenIsNeverOverwrittenOrRemoved() throws {
        try UpdateBlock.apply(userDataDir: named, home: home.path)
        let configURL = library(named).appendingPathComponent(UpdateBlock.configID + ".json")
        try write(["disableAutoUpdates": true, "inferenceProvider": "bedrock", "inferenceBedrockRegion": "us-west-2"], to: configURL)
        let edited = try Data(contentsOf: configURL)

        guard case .foreign = UpdateBlock.state(userDataDir: named, home: home.path) else { return XCTFail("state") }
        guard case .foreign = try UpdateBlock.apply(userDataDir: named, home: home.path) else { return XCTFail("apply") }
        XCTAssertEqual(try Data(contentsOf: configURL), edited, "apply must not put our file back over theirs")
        guard case .foreign = try UpdateBlock.remove(userDataDir: named, home: home.path) else { return XCTFail("remove") }
        XCTAssertEqual(try Data(contentsOf: configURL), edited)
        XCTAssertEqual(tree().count, 2, "both files still there")
    }

    /// Unreadable is not absent. An index we cannot read belongs to someone else.
    func testAnIndexThatCannotBeReadIsNeverReplaced() throws {
        try XCTSkipIf(getuid() == 0, "root can read anything")
        let metaURL = library(named).appendingPathComponent("_meta.json")
        try write(["appliedId": "0b8f2d6e-1111-4222-8333-444455556666"], to: metaURL)
        let original = try Data(contentsOf: metaURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: metaURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL.path) }

        guard case .foreign = UpdateBlock.state(userDataDir: named, home: home.path) else { return XCTFail("state") }
        guard case .foreign = try UpdateBlock.apply(userDataDir: named, home: home.path) else { return XCTFail("apply") }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL.path)
        XCTAssertEqual(try Data(contentsOf: metaURL), original)
        XCTAssertEqual(tree().count, 1, "our configuration was not written next to it either")
    }

    /// A directory where the index goes used to read as "nothing there"; a later "off" then
    /// deleted it recursively.
    func testADirectoryWhereTheIndexGoesIsNeverDeleted() throws {
        let inside = library(named).appendingPathComponent("_meta.json/keep-me.txt")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: inside)

        guard case .foreign = UpdateBlock.state(userDataDir: named, home: home.path) else { return XCTFail("state") }
        guard case .foreign = try UpdateBlock.apply(userDataDir: named, home: home.path) else { return XCTFail("apply") }
        guard case .foreign = try UpdateBlock.remove(userDataDir: named, home: home.path) else { return XCTFail("remove") }
        XCTAssertEqual(try String(contentsOf: inside, encoding: .utf8), "theirs")
        XCTAssertEqual(tree().count, 1)
    }

    func testADanglingSymlinkWhereTheIndexGoesIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: library(named), withIntermediateDirectories: true)
        let link = library(named).appendingPathComponent("_meta.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/elsewhere.json")

        guard case .foreign = try UpdateBlock.apply(userDataDir: named, home: home.path) else { return XCTFail("apply") }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "/nonexistent/elsewhere.json")
    }

    /// A symlinked library leads somewhere this tool did not create. Nothing is written
    /// through it, and the link itself is not removed.
    func testASymlinkedLibraryDirectoryIsLeftAlone() throws {
        let elsewhere = home.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library(named).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library(named), withDestinationURL: elsewhere)

        guard case .foreign = try UpdateBlock.apply(userDataDir: named, home: home.path) else { return XCTFail("apply") }
        guard case .foreign = try UpdateBlock.remove(userDataDir: named, home: home.path) else { return XCTFail("remove") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: library(named).path))
    }

    /// Tidying up is `rmdir`, not a recursive delete: Finder's `.DS_Store` is not ours.
    func testALibraryDirectoryThatIsNotEmptyIsKept() throws {
        try UpdateBlock.apply(userDataDir: named, home: home.path)
        let dsStore = library(named).appendingPathComponent(".DS_Store")
        try Data("finder".utf8).write(to: dsStore)
        XCTAssertEqual(try UpdateBlock.remove(userDataDir: named, home: home.path), .off)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dsStore.path))
    }

    func testAnUnreadableIndexIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: library(named), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: library(named).appendingPathComponent("_meta.json"))
        guard case .foreign = try UpdateBlock.apply(userDataDir: named, home: home.path) else { return XCTFail() }
        XCTAssertEqual(try String(contentsOf: library(named).appendingPathComponent("_meta.json"), encoding: .utf8), "{ not json")
    }

    /// Claude's own setup screen rewrites the index when the user adds a configuration. From
    /// then on it is theirs: turning our block "off" must not take their work with it.
    func testAnIndexTheAppHasSinceEditedIsLeftInPlace() throws {
        try UpdateBlock.apply(userDataDir: named, home: home.path)
        let metaURL = library(named).appendingPathComponent("_meta.json")
        var meta = try json(metaURL)
        meta["entries"] = [["id": UpdateBlock.configID, "name": "ours"], ["id": "0b8f2d6e-1111-4222-8333-444455556666", "name": "theirs"]]
        try write(meta, to: metaURL)

        guard case .foreign = try UpdateBlock.remove(userDataDir: named, home: home.path) else { return XCTFail() }
        XCTAssertEqual(tree().count, 2, "both files still there")
    }

    // MARK: - Off

    func testTurningTheBlockOffRemovesOnlyFilesThatAreStillExactlyOurs() throws {
        // Claude's own file in its own directory, as on a real Mac.
        let theirs = home.appendingPathComponent("Library/Application Support/Claude-3p/claude_desktop_config.json")
        try write(["deploymentMode": "1p"], to: theirs)

        try UpdateBlock.apply(userDataDir: nil, home: home.path)
        XCTAssertEqual(try UpdateBlock.remove(userDataDir: nil, home: home.path), .off)

        XCTAssertEqual(tree(), ["Library/Application Support/Claude-3p/claude_desktop_config.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library(nil).path), "the emptied library directory is tidied away")
    }

    /// `Claude-3p` is a directory Claude makes for itself. Even empty, it is not ours to delete.
    func testTheParentPolicyDirectoryIsNeverRemoved() throws {
        let parent = library(nil).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try UpdateBlock.apply(userDataDir: nil, home: home.path)
        try UpdateBlock.remove(userDataDir: nil, home: home.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
    }

    func testRemovingWhenNothingIsThereDoesNothing() throws {
        XCTAssertEqual(try UpdateBlock.remove(userDataDir: named, home: home.path), .off)
        XCTAssertEqual(tree(), [])
    }
}
