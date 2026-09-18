import XCTest
@testable import ClaudeSwitcherCore

/// Rules enforced by `Config.addProfile` / `removeProfile` / `renameProfile` / `setActive`.
/// These are pure value-type mutations — nothing here touches disk, the Keychain,
/// or launches anything.
final class ProfileMutationTests: XCTestCase {

    private let home = NSHomeDirectory()

    /// default (inactive) + "work" (active) + "spare" (removable).
    private func makeConfig() -> Config {
        Config(
            claudeAppPath: "/Applications/Claude.app",
            activeProfileId: "work",
            profiles: [
                Profile(id: "default", label: "Personal", userDataDir: nil, credDir: nil),
                Profile(id: "work",
                        label: "Work",
                        userDataDir: "/Users/me/Library/Application Support/Claude-Work",
                        credDir: "/Users/me/.claude-accounts/work"),
                Profile(id: "spare",
                        label: "Spare",
                        userDataDir: "/Users/me/Library/Application Support/Claude-Spare",
                        credDir: "/Users/me/.claude-accounts/spare"),
            ]
        )
    }

    // MARK: - addProfile: duplicate id

    func testAddProfileRejectsDuplicateID() {
        var config = makeConfig()
        let before = config
        let clash = Profile(id: "work",
                            label: "Another Work",
                            userDataDir: "/tmp/other-udd",
                            credDir: "/tmp/other-cred")

        XCTAssertThrowsError(try config.addProfile(clash)) { error in
            switch error {
            case ConfigError.duplicateID(let id):
                XCTAssertEqual(id, "work")
            default:
                XCTFail("expected ConfigError.duplicateID, got \(error)")
            }
        }
        XCTAssertEqual(config, before, "a rejected add must not mutate the config")
    }

    // MARK: - addProfile: duplicate userDataDir

    func testAddProfileRejectsDuplicateUserDataDir() {
        var config = makeConfig()
        let before = config
        let clash = Profile(id: "new",
                            label: "New",
                            userDataDir: "/Users/me/Library/Application Support/Claude-Work",
                            credDir: "/tmp/unique-cred")

        XCTAssertThrowsError(try config.addProfile(clash)) { error in
            guard case ConfigError.duplicateUserDataDir = error else {
                return XCTFail("expected ConfigError.duplicateUserDataDir, got \(error)")
            }
        }
        XCTAssertEqual(config, before, "a rejected add must not mutate the config")
    }

    func testAddProfileRejectsDuplicateUserDataDirSpelledWithATrailingSlash() {
        var config = makeConfig()
        let clash = Profile(id: "new",
                            label: "New",
                            userDataDir: "/Users/me/Library/Application Support/Claude-Work/",
                            credDir: "/tmp/unique-cred")

        XCTAssertThrowsError(try config.addProfile(clash)) { error in
            guard case ConfigError.duplicateUserDataDir = error else {
                return XCTFail("expected ConfigError.duplicateUserDataDir, got \(error)")
            }
        }
    }

    func testAddProfileRejectsDuplicateUserDataDirSpelledWithATilde() {
        var config = Config(
            claudeAppPath: "/Applications/Claude.app",
            activeProfileId: "default",
            profiles: [
                Profile(id: "default", label: "Personal", userDataDir: nil, credDir: nil),
                Profile(id: "work",
                        label: "Work",
                        userDataDir: home + "/Library/Application Support/Claude-Work",
                        credDir: nil),
            ]
        )
        let clash = Profile(id: "new",
                            label: "New",
                            userDataDir: "~/Library/Application Support/Claude-Work",
                            credDir: nil)

        XCTAssertThrowsError(try config.addProfile(clash)) { error in
            guard case ConfigError.duplicateUserDataDir = error else {
                return XCTFail("expected ConfigError.duplicateUserDataDir, got \(error)")
            }
        }
    }

    // MARK: - addProfile: duplicate credDir

    func testAddProfileRejectsDuplicateCredDir() {
        var config = makeConfig()
        let before = config
        let clash = Profile(id: "new",
                            label: "New",
                            userDataDir: "/tmp/unique-udd",
                            credDir: "/Users/me/.claude-accounts/work")

        XCTAssertThrowsError(try config.addProfile(clash)) { error in
            guard case ConfigError.duplicateCredDir = error else {
                return XCTFail("expected ConfigError.duplicateCredDir, got \(error)")
            }
        }
        XCTAssertEqual(config, before, "a rejected add must not mutate the config")
    }

    func testAddProfileRejectsDuplicateCredDirSpelledWithATrailingSlash() {
        var config = makeConfig()
        let clash = Profile(id: "new",
                            label: "New",
                            userDataDir: "/tmp/unique-udd",
                            credDir: "/Users/me/.claude-accounts/work/")

        XCTAssertThrowsError(try config.addProfile(clash)) { error in
            guard case ConfigError.duplicateCredDir = error else {
                return XCTFail("expected ConfigError.duplicateCredDir, got \(error)")
            }
        }
    }

    func testAddProfileRejectsDuplicateCredDirSpelledWithATilde() {
        var config = Config(
            claudeAppPath: "/Applications/Claude.app",
            activeProfileId: "default",
            profiles: [
                Profile(id: "default", label: "Personal", userDataDir: nil, credDir: nil),
                Profile(id: "work",
                        label: "Work",
                        userDataDir: home + "/Library/Application Support/Claude-Work",
                        credDir: home + "/.claude-accounts/work"),
            ]
        )
        let clash = Profile(id: "new",
                            label: "New",
                            userDataDir: home + "/Library/Application Support/Claude-New",
                            credDir: "~/.claude-accounts/work")

        XCTAssertThrowsError(try config.addProfile(clash)) { error in
            guard case ConfigError.duplicateCredDir = error else {
                return XCTFail("expected ConfigError.duplicateCredDir, got \(error)")
            }
        }
    }

    // MARK: - addProfile: success

    func testAddProfileAppendsAUniqueProfile() throws {
        var config = makeConfig()
        let fresh = Profile(id: "second",
                            label: "Secondary",
                            userDataDir: "/Users/me/Library/Application Support/Claude-Second",
                            credDir: "/Users/me/.claude-accounts/secondary")

        try config.addProfile(fresh)

        XCTAssertEqual(config.profiles.count, 4)
        XCTAssertEqual(config.profile(id: "second"), fresh)
        XCTAssertEqual(config.activeProfileId, "work", "adding must not change the active profile")
    }

    // MARK: - removeProfile

    func testRemoveProfileRefusesTheDefaultProfile() {
        var config = makeConfig()   // "default" is present but NOT active
        let before = config

        XCTAssertThrowsError(try config.removeProfile(id: "default")) { error in
            guard case ConfigError.cannotRemoveDefaultProfile = error else {
                return XCTFail("expected ConfigError.cannotRemoveDefaultProfile, got \(error)")
            }
        }
        XCTAssertEqual(config, before, "a rejected remove must not mutate the config")
    }

    func testRemoveProfileRefusesTheActiveProfile() {
        var config = makeConfig()   // "work" is active and is NOT the default profile
        let before = config

        XCTAssertThrowsError(try config.removeProfile(id: "work")) { error in
            switch error {
            case ConfigError.cannotRemoveActiveProfile(let id):
                XCTAssertEqual(id, "work")
            default:
                XCTFail("expected ConfigError.cannotRemoveActiveProfile, got \(error)")
            }
        }
        XCTAssertEqual(config, before, "a rejected remove must not mutate the config")
    }

    func testRemoveProfileRejectsAnUnknownID() {
        var config = makeConfig()
        let before = config

        XCTAssertThrowsError(try config.removeProfile(id: "nope")) { error in
            switch error {
            case ConfigError.unknownProfile(let id):
                XCTAssertEqual(id, "nope")
            default:
                XCTFail("expected ConfigError.unknownProfile, got \(error)")
            }
        }
        XCTAssertEqual(config, before)
    }

    func testRemoveProfileSucceedsForANonActiveNonDefaultProfile() throws {
        var config = makeConfig()

        try config.removeProfile(id: "spare")

        XCTAssertEqual(config.profiles.map(\.id), ["default", "work"])
        XCTAssertNil(config.profile(id: "spare"))
        XCTAssertEqual(config.activeProfileId, "work")
    }

    func testRemovingAProfileFreesItsDirectoriesForReuse() throws {
        var config = makeConfig()
        try config.removeProfile(id: "spare")

        let reuse = Profile(id: "spare2",
                            label: "Spare Again",
                            userDataDir: "/Users/me/Library/Application Support/Claude-Spare",
                            credDir: "/Users/me/.claude-accounts/spare")
        XCTAssertNoThrow(try config.addProfile(reuse))
    }

    // MARK: - renameProfile

    func testRenameChangesTheLabelAndNothingElse() throws {
        var config = makeConfig()
        let before = try XCTUnwrap(config.profile(id: "work"))

        try config.renameProfile(id: "work", label: "Client Work")

        let after = try XCTUnwrap(config.profile(id: "work"))
        XCTAssertEqual(after.label, "Client Work")
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.userDataDir, before.userDataDir)
        XCTAssertEqual(after.credDir, before.credDir)
        XCTAssertEqual(config.activeProfileId, "work")
        XCTAssertEqual(config.profiles.map(\.id), ["default", "work", "spare"], "order is kept")
    }

    func testRenameLeavesOtherProfilesUntouched() throws {
        var config = makeConfig()
        let others = config.profiles.filter { $0.id != "spare" }
        try config.renameProfile(id: "spare", label: "Backup")
        XCTAssertEqual(config.profiles.filter { $0.id != "spare" }, others)
    }

    func testRenameTrimsSurroundingWhitespace() throws {
        var config = makeConfig()
        try config.renameProfile(id: "work", label: "  Client Work \n")
        XCTAssertEqual(config.profile(id: "work")?.label, "Client Work")
    }

    func testRenameRejectsAnEmptyOrBlankLabelAndChangesNothing() {
        var config = makeConfig()
        let before = config
        for label in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try config.renameProfile(id: "work", label: label)) { error in
                XCTAssertEqual(error as? ConfigError, .emptyLabel)
            }
        }
        XCTAssertEqual(config, before)
    }

    func testRenameOfAnUnknownProfileThrowsAndChangesNothing() {
        var config = makeConfig()
        let before = config
        XCTAssertThrowsError(try config.renameProfile(id: "nope", label: "X")) { error in
            XCTAssertEqual(error as? ConfigError, .unknownProfile("nope"))
        }
        XCTAssertEqual(config, before)
    }

    /// Unlike removal, renaming has no reason to refuse the default or the active profile.
    func testDefaultAndActiveProfilesCanBeRenamed() throws {
        var config = makeConfig()
        try config.renameProfile(id: "default", label: "Me")
        try config.renameProfile(id: "work", label: "Day Job")
        XCTAssertEqual(config.profile(id: "default")?.label, "Me")
        XCTAssertEqual(config.profile(id: "default")?.isDefaultProfile, true)
        XCTAssertEqual(config.profile(id: "work")?.label, "Day Job")
        XCTAssertEqual(config.activeProfileId, "work")
    }

    // MARK: - setActive

    func testSetActiveThrowsUnknownProfileForAnUnknownID() {
        var config = makeConfig()
        let before = config

        XCTAssertThrowsError(try config.setActive(id: "nope")) { error in
            switch error {
            case ConfigError.unknownProfile(let id):
                XCTAssertEqual(id, "nope")
            default:
                XCTFail("expected ConfigError.unknownProfile, got \(error)")
            }
        }
        XCTAssertEqual(config, before, "a rejected setActive must not mutate the config")
    }

    func testSetActiveSucceedsForAKnownID() throws {
        var config = makeConfig()

        try config.setActive(id: "default")
        XCTAssertEqual(config.activeProfileId, "default")

        try config.setActive(id: "spare")
        XCTAssertEqual(config.activeProfileId, "spare")

        XCTAssertEqual(config.profiles.map(\.id), ["default", "work", "spare"],
                       "setActive must not reorder or alter the profile list")
    }

    func testSetActiveToTheAlreadyActiveProfileIsANoOp() throws {
        var config = makeConfig()
        let before = config

        try config.setActive(id: "work")
        XCTAssertEqual(config, before)
    }

    func testSetActiveThenTheOldActiveProfileBecomesRemovable() throws {
        var config = makeConfig()
        try config.setActive(id: "spare")
        XCTAssertNoThrow(try config.removeProfile(id: "work"))
        XCTAssertNil(config.profile(id: "work"))
    }
}
