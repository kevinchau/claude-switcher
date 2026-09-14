import XCTest
@testable import ClaudeSwitcherCore

/// Exercises the real `save`/`load` path against a temporary directory, never the user's
/// actual `~/.config/claude-switcher/config.json`.
final class ConfigFileIOTests: XCTestCase {

    private var directory: URL!
    private var configURL: URL { directory.appendingPathComponent("config.json") }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-switcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample() -> Config {
        Config(
            claudeAppPath: "/Applications/Claude.app",
            activeProfileId: "default",
            profiles: [
                Profile(id: "default", label: "Personal", userDataDir: nil, credDir: nil),
                Profile(id: "work", label: "Work",
                        userDataDir: "/tmp/Library/Application Support/Claude-Work",
                        credDir: "/tmp/.claude-accounts/work"),
            ]
        )
    }

    func testSaveThenLoadReturnsAnIdenticalConfig() throws {
        let original = sample()
        try original.save(to: configURL)
        XCTAssertEqual(try Config.load(from: configURL), original)
    }

    func testSaveCreatesIntermediateDirectories() throws {
        let nested = directory
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("config.json")
        try sample().save(to: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    /// The file records which accounts exist and where their data lives; it should not be
    /// world-readable.
    func testSavedFileIsOwnerReadableOnly() throws {
        try sample().save(to: configURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(permissions, 0o600)
    }

    func testOverwritingAnExistingFileKeepsPermissionsAndContent() throws {
        try sample().save(to: configURL)
        var updated = sample()
        updated.activeProfileId = "work"
        try updated.save(to: configURL)

        XCTAssertEqual(try Config.load(from: configURL).activeProfileId, "work")
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testSaveLeavesNoTemporaryFilesBehind() throws {
        try sample().save(to: configURL)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0 != "config.json" }
        XCTAssertEqual(leftovers, [])
    }

    func testLoadingAMissingFileYieldsTheDefaultConfig() throws {
        XCTAssertEqual(try Config.load(from: configURL), Config.defaultConfig())
    }

    func testLoadingAMalformedFileThrowsMalformed() throws {
        try Data("{ not json".utf8).write(to: configURL)
        XCTAssertThrowsError(try Config.load(from: configURL)) { error in
            guard case ConfigError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    /// Hand-edited files that omit the optional directory keys must still load.
    func testHandEditedFileWithoutOptionalKeysLoads() throws {
        let json = """
        { "claudeAppPath": "/Applications/Claude.app",
          "activeProfileId": "default",
          "profiles": [ { "id": "default", "label": "Personal" } ] }
        """
        try Data(json.utf8).write(to: configURL)
        let loaded = try Config.load(from: configURL)
        XCTAssertNil(loaded.profiles[0].userDataDir)
        XCTAssertNil(loaded.profiles[0].credDir)
        XCTAssertTrue(loaded.profiles[0].isDefaultProfile)
    }

    /// A second all-nil profile would be indistinguishable from the default account and
    /// `removeProfile` would then refuse to delete it, stranding the user.
    func testASecondDefaultProfileIsRejected() throws {
        var config = Config.defaultConfig()
        XCTAssertThrowsError(
            try config.addProfile(Profile(id: "other", label: "Other", userDataDir: nil, credDir: nil))
        ) { error in
            guard case ConfigError.duplicateDefaultProfile = error else {
                return XCTFail("expected .duplicateDefaultProfile, got \(error)")
            }
        }
        XCTAssertEqual(config.profiles.count, 1)
    }
}

// MARK: - Desktop identity and reserved directories

extension ConfigFileIOTests {

    private func profile(_ id: String, userDataDir: String?, credDir: String? = nil) -> Profile {
        Profile(id: id, label: id.capitalized, userDataDir: userDataDir, credDir: credDir)
    }

    /// A profile's Desktop identity is its `userDataDir` alone. A second profile without one
    /// binds to the same running instance, so selecting it would focus the *other* account's
    /// window while the menu reported a successful switch.
    func testASecondProfileWithoutAUserDataDirIsRejectedEvenWithItsOwnCredDir() throws {
        var config = Config.defaultConfig()
        XCTAssertThrowsError(
            try config.addProfile(profile("cli", userDataDir: nil, credDir: "/tmp/creds-cli"))
        ) { error in
            guard case ConfigError.duplicateDefaultProfile = error else {
                return XCTFail("expected .duplicateDefaultProfile, got \(error)")
            }
        }
    }

    func testTwoProfilesWithoutUserDataDirCannotBeLoadedFromDisk() throws {
        let json = """
        { "claudeAppPath": "/Applications/Claude.app", "activeProfileId": "default",
          "profiles": [ { "id": "default", "label": "Personal" },
                        { "id": "work", "label": "Work", "credDir": "/tmp/creds-work" } ] }
        """
        try Data(json.utf8).write(to: configURL)
        XCTAssertThrowsError(try Config.load(from: configURL)) { error in
            guard case ConfigError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    /// Distinct profiles each owning a userDataDir is the supported shape.
    func testProfilesWithDistinctUserDataDirsAreAccepted() throws {
        var config = Config.defaultConfig()
        try config.addProfile(profile("work", userDataDir: "/tmp/Claude-Work", credDir: "/tmp/creds-work"))
        try config.addProfile(profile("alt", userDataDir: "/tmp/Claude-Alt", credDir: "/tmp/creds-alt"))
        XCTAssertEqual(config.profiles.count, 3)
    }

    /// Electron writes Cookies/Local Storage/SingletonLock into whatever it is handed. Pointed
    /// at ~/.claude it would scribble through the shared directory this tool exists to protect;
    /// pointed at the app's own profile dir it would put two Chromium processes on one store.
    func testReservedDirectoriesAreRejected() throws {
        let home = PathNormalizer.normalize(NSHomeDirectory())
        for reserved in [home,
                         home + "/.claude",
                         home + "/Library/Application Support/Claude"] {
            var config = Config.defaultConfig()
            XCTAssertThrowsError(try config.addProfile(profile("x", userDataDir: reserved)),
                                 "expected \(reserved) to be rejected") { error in
                guard case ConfigError.reservedUserDataDir = error else {
                    return XCTFail("expected .reservedUserDataDir for \(reserved), got \(error)")
                }
            }
        }
    }

    func testReservedDirectoryIsRejectedThroughTildeAndTrailingSlashSpellings() throws {
        var config = Config.defaultConfig()
        XCTAssertThrowsError(try config.addProfile(profile("x", userDataDir: "~/.claude/"))) { error in
            guard case ConfigError.reservedUserDataDir = error else {
                return XCTFail("expected .reservedUserDataDir, got \(error)")
            }
        }
    }

    func testANormalProfileDirectoryNearAReservedOneIsStillAllowed() throws {
        var config = Config.defaultConfig()
        // ~/.claude is reserved; ~/.claude-accounts/... and Claude-Work are not.
        try config.addProfile(profile("work",
                                      userDataDir: "~/Library/Application Support/Claude-Work",
                                      credDir: "~/.claude-accounts/work"))
        XCTAssertEqual(config.profiles.count, 2)
    }

    /// A config.json symlinked into a dotfiles repo must still be writable: `replaceItemAt`
    /// fails with ENOENT on a symlink, which would make every save fail permanently.
    func testSavingThroughASymlinkedConfigFileSucceeds() throws {
        let realFile = directory.appendingPathComponent("real-config.json")
        let link = directory.appendingPathComponent("linked-config.json")
        try sample().save(to: realFile)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        var updated = sample()
        updated.activeProfileId = "work"
        XCTAssertNoThrow(try updated.save(to: link))

        // The link survives, and the real file received the update.
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
        XCTAssertEqual(try Config.load(from: realFile).activeProfileId, "work")

        // And a second save still works — the original bug failed every time, not just once.
        updated.activeProfileId = "default"
        XCTAssertNoThrow(try updated.save(to: link))
        XCTAssertEqual(try Config.load(from: realFile).activeProfileId, "default")
    }
}
