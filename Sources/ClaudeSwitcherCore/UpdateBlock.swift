import Darwin
import Foundation

/// Keeps a Claude Desktop profile from updating itself, through Claude's own
/// `disableAutoUpdates` policy.
///
/// Claude reads policy from two places: a root-owned managed plist, which is none of this
/// tool's business, and a per-profile "configuration library" under
/// `<user-data dir>-3p/configLibrary`: `_meta.json` names the applied configuration, and
/// `<id>.json` holds it. Verified against a throwaway instance: with
/// `{"disableAutoUpdates": true}` applied, the updater logs "Auto-updates disabled by
/// enterprise policy" and never starts, and nothing else about the app changes.
///
/// These two files are the **only** thing this tool ever creates inside Claude's data area,
/// and only on the user's say-so. The rule that governs everything below: **a file is ours
/// only if it is a regular file we can read and it says exactly what we wrote.** Anything
/// else at either path — edited, unreadable, a directory, a symlink — is someone else's, and
/// the whole library is then left alone: not overwritten, not merged into, not removed.
/// (Claude's own setup screen saves into whichever configuration is open, so "our id" alone
/// proves nothing: the user may have put their provider settings in that very file.)
public enum UpdateBlock {

    /// The identifier of the one configuration this tool owns. Claude requires a lowercase UUID.
    public static let configID = "7c1a5e0d-3b9f-4c62-8a41-d0e5f2b6c913"
    public static let entryName = "Claude Switcher \u{2014} block auto-updates"
    public static let policyKey = "disableAutoUpdates"

    static let libraryDirectoryName = "configLibrary"
    static let metaFileName = "_meta.json"

    public enum State: Equatable, Sendable {
        /// No configuration library; Claude updates itself as usual.
        case off
        /// Both of our files are in place and say exactly what we wrote.
        case on
        /// Something here is not ours. Left alone, whatever the setting says.
        case foreign(String)
        /// Exactly one of our two files is there and the other is absent (a crash between two
        /// writes). Nothing foreign is involved, so it is safe to finish or undo.
        case damaged
    }

    /// `<user-data dir>-3p/configLibrary`. A `nil` directory is the default profile.
    public static func policyDirectory(forUserDataDir dir: String?, home: String = NSHomeDirectory()) -> URL {
        let userData = dir.map { PathNormalizer.normalize($0, home: home) } ?? Config.defaultUserDataDir(home: home)
        // As Claude does it, case-sensitively: a directory already ending in the suffix is its
        // own policy directory. (Config validation refuses such profile directories anyway.)
        let base = userData.hasSuffix(Config.policyDirectorySuffix)
            ? userData
            : userData + Config.policyDirectorySuffix
        return URL(fileURLWithPath: base).appendingPathComponent(libraryDirectoryName)
    }

    // MARK: - Reading

    /// What is at one of our two paths.
    enum Item: Equatable {
        case absent
        case ours
        case notOurs(String)
    }

    public static func state(userDataDir: String?, home: String = NSHomeDirectory()) -> State {
        let directory = policyDirectory(forUserDataDir: userDataDir, home: home)

        // We only ever work in real directories. A symlinked library (or parent) leads
        // somewhere this tool did not create.
        for url in [directory.deletingLastPathComponent(), directory] {
            switch kind(of: url) {
            case .absent, .directory: continue
            case .other(let what): return .foreign("\(url.lastPathComponent) is \(what)")
            }
        }

        let index = classify(directory.appendingPathComponent(metaFileName), isOurs: isOurIndex)
        let config = classify(directory.appendingPathComponent(configID + ".json"), isOurs: isOurConfig)

        switch (index, config) {
        case (.notOurs(let why), _):
            return .foreign(why)
        case (_, .notOurs):
            return .foreign("its configuration has been edited since this tool created it")
        case (.ours, .ours):
            return .on
        case (.ours, .absent), (.absent, .ours):
            return .damaged
        case (.absent, .absent):
            return otherFiles(in: directory).isEmpty ? .off : .foreign("it holds files this tool did not create")
        }
    }

    private enum Kind { case absent, directory, other(String) }

    private static func kind(of url: URL) -> Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .absent : .other("unreadable")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .other("a symbolic link")
        default: return .other("not a directory")
        }
    }

    /// `lstat`, never `stat`: a symlink is classified as a symlink, not as what it points at.
    /// Only "no such file" is absence; any other failure means something is there that we
    /// cannot vouch for.
    static func classify(_ url: URL, isOurs: (Data) -> Bool) -> Item {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .absent : .notOurs("\(url.lastPathComponent) could not be examined")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return .notOurs("\(url.lastPathComponent) is not a regular file")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .notOurs("\(url.lastPathComponent) could not be read")
        }
        return isOurs(data) ? .ours : .notOurs("\(url.lastPathComponent) is not what this tool wrote")
    }

    /// Our index and nothing else: our id applied, exactly our one entry, no other keys.
    static func isOurIndex(_ data: Data) -> Bool {
        guard let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(meta.keys) == ["appliedId", "entries"],
              meta["appliedId"] as? String == configID,
              let entries = meta["entries"] as? [[String: Any]],
              entries.count == 1,
              Set(entries[0].keys) == ["id", "name"],
              entries[0]["id"] as? String == configID,
              entries[0]["name"] as? String == entryName
        else { return false }
        return true
    }

    /// Our configuration and nothing else: the one key, set to `true`.
    static func isOurConfig(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == [policyKey],
              let value = object[policyKey] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return false }
        return value.boolValue
    }

    private static func otherFiles(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0 != metaFileName && $0 != configID + ".json" && $0 != ".DS_Store" }
    }

    // MARK: - Writing

    /// Turns the block on for one profile. Acts only where there is nothing, or only one of our
    /// own two files; any other state is returned untouched.
    @discardableResult
    public static func apply(userDataDir: String?, home: String = NSHomeDirectory()) throws -> State {
        let current = state(userDataDir: userDataDir, home: home)
        guard current == .off || current == .damaged else { return current }

        let directory = policyDirectory(forUserDataDir: userDataDir, home: home)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // The configuration first, then the index that points at it: the index never names a
        // file that is not there yet. Each path is looked at again right before it is written.
        let config = try JSONSerialization.data(
            withJSONObject: [policyKey: true], options: [.prettyPrinted, .sortedKeys])
        try write(config, to: directory.appendingPathComponent(configID + ".json"), isOurs: isOurConfig)

        let meta = try JSONSerialization.data(
            withJSONObject: ["appliedId": configID, "entries": [["id": configID, "name": entryName]]],
            options: [.prettyPrinted, .sortedKeys])
        try write(meta, to: directory.appendingPathComponent(metaFileName), isOurs: isOurIndex)

        return state(userDataDir: userDataDir, home: home)
    }

    /// Turns the block off for one profile. Removes only regular files that are still exactly
    /// ours, and the library directory if — and only if — that leaves it truly empty.
    @discardableResult
    public static func remove(userDataDir: String?, home: String = NSHomeDirectory()) throws -> State {
        let current = state(userDataDir: userDataDir, home: home)
        guard current == .on || current == .damaged else { return current }

        let directory = policyDirectory(forUserDataDir: userDataDir, home: home)
        // The index first, so it never points at a configuration that has gone. Each file is
        // classified again immediately before it is unlinked.
        let files: [(String, (Data) -> Bool)] = [(metaFileName, isOurIndex), (configID + ".json", isOurConfig)]
        for (name, isOurs) in files {
            let url = directory.appendingPathComponent(name)
            guard classify(url, isOurs: isOurs) == .ours else { continue }
            guard unlink(url.path) == 0 || errno == ENOENT else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        // `rmdir`, not a recursive remove: it succeeds only on a directory with nothing in it —
        // not even a `.DS_Store` — and does nothing to a symlink. The parent (`Claude-3p` for
        // the default profile) is Claude's own directory and is never touched.
        _ = rmdir(directory.path)
        return state(userDataDir: userDataDir, home: home)
    }

    /// Writes one of our files, unless something that is not ours has appeared at the path.
    private static func write(_ data: Data, to url: URL, isOurs: (Data) -> Bool) throws {
        if case .notOurs(let why) = classify(url, isOurs: isOurs) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path, NSLocalizedDescriptionKey: why])
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
