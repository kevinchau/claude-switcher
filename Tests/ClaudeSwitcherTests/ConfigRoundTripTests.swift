import XCTest
@testable import ClaudeSwitcherCore

/// Codable round-tripping for `Config` / `Profile`.
///
/// These tests never touch `~/.config/claude-switcher/config.json`: they drive
/// `JSONEncoder`/`JSONDecoder` directly, which is exactly the coding path `save()` and
/// `load()` use.
final class ConfigRoundTripTests: XCTestCase {

    private func makeConfig() -> Config {
        Config(
            claudeAppPath: "/Applications/Claude.app",
            activeProfileId: "default",
            profiles: [
                Profile(id: "default", label: "Personal", userDataDir: nil, credDir: nil),
                Profile(id: "work",
                        label: "Work",
                        userDataDir: "/Users/me/Library/Application Support/Claude-Work",
                        credDir: "/Users/me/.claude-accounts/work"),
                // Mixed: a Desktop-only profile with no separate terminal credential slot.
                Profile(id: "desktop-only",
                        label: "Desktop Only",
                        userDataDir: "/Users/me/Library/Application Support/Claude-Alt",
                        credDir: nil),
                // Both directories set — the shape "Add Profile…" produces.
                Profile(id: "cli-only",
                        label: "CLI Only",
                        userDataDir: "/Users/me/Library/Application Support/Claude-Cli",
                        credDir: "/Users/me/.claude-accounts/cli"),
            ]
        )
    }

    private func roundTrip(_ config: Config) throws -> Config {
        let data = try JSONEncoder().encode(config)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    // MARK: - Round trip

    func testConfigWithMixedNilAndNonNilDirsRoundTrips() throws {
        let original = makeConfig()
        XCTAssertEqual(try roundTrip(original), original)
    }

    func testRoundTripPreservesProfileOrder() throws {
        let original = makeConfig()
        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded.profiles.map(\.id), original.profiles.map(\.id))
    }

    func testRoundTripIsStable() throws {
        let original = makeConfig()
        XCTAssertEqual(try roundTrip(roundTrip(original)), original)
    }

    func testEncodedJSONUsesTheDocumentedKeys() throws {
        let data = try JSONEncoder().encode(makeConfig())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["claudeAppPath", "activeProfileId", "profiles"])

        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        let work = try XCTUnwrap(profiles.first { $0["id"] as? String == "work" })
        XCTAssertEqual(work["label"] as? String, "Work")
        XCTAssertEqual(work["userDataDir"] as? String,
                       "/Users/me/Library/Application Support/Claude-Work")
        XCTAssertEqual(work["credDir"] as? String, "/Users/me/.claude-accounts/work")
    }

    // MARK: - Decoding tolerance

    func testJSONMissingDirKeysDecodesWithNils() throws {
        let json = """
        {
          "claudeAppPath": "/Applications/Claude.app",
          "activeProfileId": "default",
          "profiles": [
            { "id": "default", "label": "Personal" }
          ]
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let profile = try XCTUnwrap(config.profiles.first)

        XCTAssertNil(profile.userDataDir)
        XCTAssertNil(profile.credDir)
        XCTAssertTrue(profile.isDefaultProfile)
    }

    func testJSONWithExplicitNullDirsDecodesWithNils() throws {
        // This is the literal shape documented for the config file on disk.
        let json = """
        {
          "claudeAppPath": "/Applications/Claude.app",
          "activeProfileId": "default",
          "profiles": [
            { "id": "default", "label": "Personal", "userDataDir": null, "credDir": null },
            { "id": "work", "label": "Work",
              "userDataDir": "/Users/me/Library/Application Support/Claude-Work",
              "credDir": "/Users/me/.claude-accounts/work" }
          ]
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))

        XCTAssertEqual(config.claudeAppPath, "/Applications/Claude.app")
        XCTAssertEqual(config.activeProfileId, "default")
        XCTAssertEqual(config.profiles.count, 2)

        let defaultProfile = try XCTUnwrap(config.profile(id: "default"))
        XCTAssertNil(defaultProfile.userDataDir)
        XCTAssertNil(defaultProfile.credDir)
        XCTAssertTrue(defaultProfile.isDefaultProfile)

        let work = try XCTUnwrap(config.profile(id: "work"))
        XCTAssertEqual(work.userDataDir, "/Users/me/Library/Application Support/Claude-Work")
        XCTAssertEqual(work.credDir, "/Users/me/.claude-accounts/work")
        XCTAssertFalse(work.isDefaultProfile)
    }

    // MARK: - Lookup

    func testProfileLookup() {
        let config = makeConfig()
        XCTAssertEqual(config.profile(id: "work")?.label, "Work")
        XCTAssertNil(config.profile(id: "nope"))
    }

    // MARK: - isDefaultProfile

    func testIsDefaultProfileRequiresBothDirsNil() {
        XCTAssertTrue(Profile(id: "a", label: "A", userDataDir: nil, credDir: nil)
            .isDefaultProfile)
        XCTAssertFalse(Profile(id: "b", label: "B", userDataDir: "/tmp/b", credDir: nil)
            .isDefaultProfile)
        XCTAssertFalse(Profile(id: "c", label: "C", userDataDir: nil, credDir: "/tmp/c")
            .isDefaultProfile)
        XCTAssertFalse(Profile(id: "d", label: "D", userDataDir: "/tmp/d", credDir: "/tmp/d2")
            .isDefaultProfile)
    }

    // MARK: - defaultConfig

    func testDefaultConfigHasExactlyOneDefaultProfile() {
        let config = Config.defaultConfig()
        XCTAssertEqual(config.profiles.count, 1)
        XCTAssertTrue(config.profiles[0].isDefaultProfile)
        XCTAssertNil(config.profiles[0].userDataDir)
        XCTAssertNil(config.profiles[0].credDir)
    }

    func testDefaultConfigActiveProfileExists() {
        let config = Config.defaultConfig()
        XCTAssertEqual(config.activeProfileId, config.profiles[0].id)
        XCTAssertNotNil(config.profile(id: config.activeProfileId))
    }

    func testDefaultConfigRoundTrips() throws {
        let config = Config.defaultConfig()
        XCTAssertEqual(try roundTrip(config), config)
    }

    // MARK: - configURL (path derivation only, no I/O)

    func testConfigURLPath() {
        XCTAssertTrue(
            Config.configURL.path.hasSuffix(".config/claude-switcher/config.json"),
            "unexpected config path: \(Config.configURL.path)")
    }
}
