import Foundation

// MARK: - Profile

/// One switchable Claude account.
///
/// A profile is described entirely by two optional directories:
///
/// - ``userDataDir`` selects the Electron profile, and therefore the Claude
///   Desktop account for both the chat and the Code tab. `nil` means "the app's
///   own default profile" — no `--user-data-dir` argument is passed at all.
/// - ``credDir`` selects the credential slot used by the **terminal** `claude`
///   CLI via `CLAUDE_SECURESTORAGE_CONFIG_DIR`. `nil` means the default slot —
///   the variable is omitted entirely, never passed as an empty string.
///
/// `~/.claude` is intentionally never redirected: projects, history, skills,
/// agents, plugins, memory and settings stay shared across every profile.
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    /// Stable, unique, non-empty identifier. Also the key used by
    /// ``Config/activeProfileId``.
    public let id: String

    /// Human readable name shown in the menu.
    public var label: String

    /// Electron user-data directory, or `nil` for the app's default profile.
    public var userDataDir: String?

    /// Credential directory for the terminal CLI, or `nil` for the default slot.
    public var credDir: String?

    /// `true` when this profile pins neither directory, i.e. it is the
    /// out-of-the-box account. The default profile can never be removed.
    public var isDefaultProfile: Bool { userDataDir == nil && credDir == nil }

    public init(id: String, label: String, userDataDir: String? = nil, credDir: String? = nil) {
        self.id = id
        self.label = label
        self.userDataDir = userDataDir
        self.credDir = credDir
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, userDataDir, credDir
    }

    /// Tolerant decoding: hand-edited config files may omit `userDataDir` or
    /// `credDir` entirely, and an empty string is treated as "not set" so that a
    /// stray `""` never reaches the launcher as a real path.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.label = try container.decode(String.self, forKey: .label)
        self.userDataDir = Profile.emptyAsNil(try container.decodeIfPresent(String.self, forKey: .userDataDir))
        self.credDir = Profile.emptyAsNil(try container.decodeIfPresent(String.self, forKey: .credDir))
    }

    /// Writes explicit `null`s rather than omitting the keys, so the file on
    /// disk always documents both knobs.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(userDataDir, forKey: .userDataDir)
        try container.encode(credDir, forKey: .credDir)
    }

    private static func emptyAsNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - ConfigError

/// Everything that can go wrong while validating or loading the config.
public enum ConfigError: Error, LocalizedError, Equatable, Sendable {
    /// A profile with this id already exists.
    case duplicateID(String)
    /// No profile with this id exists.
    case unknownProfile(String)
    /// The default profile (neither directory set) may not be removed.
    case cannotRemoveDefaultProfile
    /// A second profile that omits `userDataDir` — there is only one default account.
    case duplicateDefaultProfile
    /// A `userDataDir` pointing at a directory Electron must never own.
    case reservedUserDataDir(String, String)
    /// The currently active profile may not be removed.
    case cannotRemoveActiveProfile(String)
    /// Another profile already points at this user-data directory.
    case duplicateUserDataDir(String)
    /// Another profile already points at this credential directory.
    case duplicateCredDir(String)
    /// The config file could not be read or understood.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateID(let id):
            return "A profile with the id “\(id)” already exists."
        case .unknownProfile(let id):
            return "There is no profile with the id “\(id)”."
        case .cannotRemoveDefaultProfile:
            return "The default profile cannot be removed."
        case .duplicateDefaultProfile:
            return "There is already a default profile. A new profile needs its own application data directory."
        case .reservedUserDataDir(let dir, let why):
            return "\(dir) cannot be used as a profile directory: it is \(why)."
        case .cannotRemoveActiveProfile(let id):
            return "“\(id)” is the active profile. Switch to another profile before removing it."
        case .duplicateUserDataDir(let dir):
            return "Another profile already uses the application data directory \(dir)."
        case .duplicateCredDir(let dir):
            return "Another profile already uses the credential directory \(dir)."
        case .malformed(let detail):
            return "The configuration file is not valid: \(detail)"
        }
    }
}

// MARK: - Config

/// The on-disk configuration, stored at `~/.config/claude-switcher/config.json`.
public struct Config: Codable, Equatable, Sendable {
    /// Path to the Claude Desktop bundle. The bundle identifier is read from its
    /// `Info.plist` at runtime; it is never hardcoded.
    public var claudeAppPath: String

    /// ``Profile/id`` of the profile the user last switched to.
    public var activeProfileId: String

    /// All configured profiles, in display order.
    public var profiles: [Profile]

    public init(claudeAppPath: String, activeProfileId: String, profiles: [Profile]) {
        self.claudeAppPath = claudeAppPath
        self.activeProfileId = activeProfileId
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey {
        case claudeAppPath, activeProfileId, profiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.claudeAppPath = try container.decode(String.self, forKey: .claudeAppPath)
        self.activeProfileId = try container.decode(String.self, forKey: .activeProfileId)
        self.profiles = try container.decode([Profile].self, forKey: .profiles)

        // Ids are the primary key for every lookup and mutation, so reject a
        // file that would make `profile(id:)` ambiguous. Directory collisions
        // are deliberately *not* fatal here — they are rejected when adding a
        // profile, but an existing odd file still loads so the user can fix it.
        var seen = Set<String>()
        for profile in profiles {
            guard !profile.id.isEmpty else {
                throw ConfigError.malformed("a profile has an empty id")
            }
            guard seen.insert(profile.id).inserted else {
                throw ConfigError.malformed("duplicate profile id \u{201C}\(profile.id)\u{201D}")
            }
        }

        // The file is meant to be hand-editable, so the rule that keeps profiles
        // distinguishable is enforced on load too, not only in `addProfile`.
        let rootless = profiles.filter { $0.userDataDir == nil }
        if rootless.count > 1 {
            let names = rootless.map { "\u{201C}\($0.id)\u{201D}" }.joined(separator: ", ")
            throw ConfigError.malformed(
                "profiles \(names) all omit userDataDir; only one profile may do so (it is the "
                + "default account). Give the others their own application data directory."
            )
        }
        for profile in profiles {
            try Config.validateReservedDirectory(profile.userDataDir)
        }
    }

    /// Resolves a symlinked destination to the file it points at, leaving other paths alone.
    static func resolvingSymlink(_ url: URL) -> URL {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
        else { return url }
        return URL(fileURLWithPath: (path as NSString).resolvingSymlinksInPath)
    }

    /// Rejects a `userDataDir` that names a directory Electron must never be pointed at.
    ///
    /// `--user-data-dir` makes Claude.app treat the directory as its own Chromium profile: it
    /// writes `Cookies`, `Local Storage/`, `IndexedDB/`, `SingletonLock` and friends into it.
    /// Aimed at `~/.claude`, that would scribble Chromium state through the very directory this
    /// tool exists to keep shared and intact. Aimed at the app's *own* default profile
    /// directory, it would put two concurrent Chromium processes on one LevelDB store, which
    /// can corrupt the user's primary Desktop login.
    static func validateReservedDirectory(_ raw: String?) throws {
        guard let raw else { return }
        let candidate = PathNormalizer.normalize(raw)
        guard !candidate.isEmpty else { return }

        let home = PathNormalizer.normalize(NSHomeDirectory())
        let reserved: [(path: String, why: String)] = [
            (home, "your home directory"),
            (PathNormalizer.normalize(home + "/.claude"),
             "the shared Claude config directory that every profile depends on"),
            (PathNormalizer.normalize(home + "/Library/Application Support/Claude"),
             "Claude.app\u{2019}s own default profile directory"),
        ]
        for entry in reserved where entry.path == candidate {
            throw ConfigError.reservedUserDataDir(candidate, entry.why)
        }
    }

    // MARK: Location

    /// `~/.config/claude-switcher/config.json`
    public static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("claude-switcher", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    // MARK: Loading & saving

    /// Reads the config file.
    ///
    /// - Returns: ``defaultConfig()`` when the file does not exist — first run is
    ///   not an error, and nothing is written to disk as a side effect.
    /// - Throws: ``ConfigError/malformed(_:)`` when the file exists but cannot be
    ///   read or decoded.
    public static func load() throws -> Config {
        try load(from: configURL)
    }

    /// Loads from an explicit location. Exists so the read/write round-trip can be tested
    /// against a temporary directory instead of the user's real `~/.config`.
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultConfig()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.malformed("could not read \(url.path): \(error.localizedDescription)")
        }

        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch let error as ConfigError {
            throw error
        } catch let error as DecodingError {
            throw ConfigError.malformed("\(url.path): \(describe(error))")
        } catch {
            throw ConfigError.malformed("\(url.path): \(error.localizedDescription)")
        }
    }

    /// Writes the config file atomically.
    ///
    /// Creates `~/.config/claude-switcher/` (with intermediate directories) if
    /// needed, writes to a temporary file in the *same* directory so the replace
    /// is a rename on one volume, and leaves the result at mode `0600`.
    public func save() throws {
        try save(to: Config.configURL)
    }

    /// Writes to an explicit location. Exists so the read/write round-trip can be tested
    /// against a temporary directory instead of the user's real `~/.config`.
    public func save(to url: URL) throws {
        // Follow a symlinked destination before writing. `replaceItemAt` fails with ENOENT on a
        // symlink, and `fileExists` follows links and reports true — so a config.json symlinked
        // into a dotfiles repo (a mainstream setup, and this file is advertised as
        // hand-editable) would take the replace branch and fail on *every* save, permanently.
        // Resolving first also keeps the atomic rename on the same volume as the real file.
        let url = Config.resolvingSymlink(url)
        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        let encoder = JSONEncoder()
        // withoutEscapingSlashes keeps paths readable ("/Applications/Claude.app"
        // rather than "\/Applications\/Claude.app") — this file is meant to be
        // hand-editable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A) // trailing newline

        let temporaryURL = directory.appendingPathComponent(".config.json.\(UUID().uuidString).tmp")
        // createFile applies the mode at creation time, so the bytes are never
        // briefly world-readable the way write()-then-chmod would leave them.
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporaryURL.path])
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }

        // replaceItemAt can carry over the previous file's metadata, so restate
        // the mode on the final path.
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    /// The configuration a fresh install starts from: the stock app path and a
    /// single default profile that pins neither directory.
    public static func defaultConfig() -> Config {
        Config(
            claudeAppPath: "/Applications/Claude.app",
            activeProfileId: "default",
            profiles: [Profile(id: "default", label: "Personal", userDataDir: nil, credDir: nil)]
        )
    }

    /// Looks up a profile by id.
    public func profile(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Renders a `DecodingError` as something a human can act on.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue)
            return keys.isEmpty ? "top level" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key “\(key.stringValue)” at \(path(context))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "missing value of type \(type) at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupted data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

// MARK: - Mutation

/// Profile mutation rules. Pure and throwing: nothing here touches disk, so the
/// caller decides when (and whether) to ``Config/save()``.
extension Config {

    /// Appends a profile.
    ///
    /// - Throws: ``ConfigError/malformed(_:)`` for an empty id,
    ///   ``ConfigError/duplicateID(_:)`` when the id is taken, or
    ///   ``ConfigError/duplicateUserDataDir(_:)`` /
    ///   ``ConfigError/duplicateCredDir(_:)`` when another profile already owns
    ///   the directory. Directories are compared after ``PathNormalizer``
    ///   normalisation, so `~/x` and `/Users/me/x/` collide as they should.
    public mutating func addProfile(_ p: Profile) throws {
        guard !p.id.isEmpty else {
            throw ConfigError.malformed("a profile id must not be empty")
        }
        guard profile(id: p.id) == nil else {
            throw ConfigError.duplicateID(p.id)
        }
        // A profile's *Desktop* identity is its userDataDir and nothing else: that argument is
        // the only thing that selects a different app login. Two profiles with no userDataDir
        // therefore both bind to the single default instance — selecting either one would
        // focus the same window while the menu reported a switch, which is precisely the
        // mis-attribution the three-valued matching exists to prevent. (It would also strand
        // an all-nil duplicate, since `removeProfile` refuses `isDefaultProfile` entries.)
        // Exactly one profile may omit userDataDir, and that one is the default account.
        if p.userDataDir == nil, profiles.contains(where: { $0.userDataDir == nil }) {
            throw ConfigError.duplicateDefaultProfile
        }

        try Config.validateReservedDirectory(p.userDataDir)

        if let newUserDataDir = Config.normalizedDir(p.userDataDir) {
            let taken = profiles.contains { Config.normalizedDir($0.userDataDir) == newUserDataDir }
            guard !taken else { throw ConfigError.duplicateUserDataDir(newUserDataDir) }
        }

        if let newCredDir = Config.normalizedDir(p.credDir) {
            let taken = profiles.contains { Config.normalizedDir($0.credDir) == newCredDir }
            guard !taken else { throw ConfigError.duplicateCredDir(newCredDir) }
        }

        profiles.append(p)
    }

    /// Removes a profile.
    ///
    /// - Throws: ``ConfigError/unknownProfile(_:)`` when no such profile exists,
    ///   ``ConfigError/cannotRemoveDefaultProfile`` for the default profile, or
    ///   ``ConfigError/cannotRemoveActiveProfile(_:)`` for the active one.
    public mutating func removeProfile(id: String) throws {
        guard let existing = profile(id: id) else {
            throw ConfigError.unknownProfile(id)
        }
        guard !existing.isDefaultProfile else {
            throw ConfigError.cannotRemoveDefaultProfile
        }
        guard id != activeProfileId else {
            throw ConfigError.cannotRemoveActiveProfile(id)
        }
        profiles.removeAll { $0.id == id }
    }

    /// Marks a profile as the active one.
    ///
    /// - Throws: ``ConfigError/unknownProfile(_:)`` when no such profile exists.
    public mutating func setActive(id: String) throws {
        guard profile(id: id) != nil else {
            throw ConfigError.unknownProfile(id)
        }
        activeProfileId = id
    }

    /// Normalises a directory for comparison, mapping "not set" and "set to an
    /// empty string" onto the same `nil`.
    private static func normalizedDir(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = PathNormalizer.normalize(raw)
        return normalized.isEmpty ? nil : normalized
    }
}
