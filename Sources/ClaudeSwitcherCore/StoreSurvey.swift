import Darwin
import Foundation

/// Every session-store folder a Claude on this Mac could load: each `claude-code-sessions/*/*`
/// under every configured profile's user-data directory and under every
/// `~/Library/Application Support/Claude*` directory — configured here or not, signed in or not.
///
/// A copy's new id must be unused in all of them, and recovery must know whether any of them
/// has since registered the copy. Read-only; a store that cannot be read is an error, never
/// skipped (fail closed): the one that cannot be read could be the one that has the id. The
/// real guarantee against a clash is still the exclusive create and rename — this is the check
/// that keeps a clash from being made in the first place.
struct StoreSurvey {

    struct Store {
        let identity: FileIdentity
        let directory: HeldDirectory
    }

    let stores: [Store]

    /// Reads every store. `including` adds folders already held (the copy's own source and
    /// target, the journalled target), wherever they are. Throws
    /// ``SessionCopy/UnreadableStore`` naming the first folder that could not be read.
    static func read(profiles: [Profile], home: String, including held: [HeldDirectory] = []) throws -> StoreSurvey {
        var stores: [Store] = []
        var seenStores = Set<FileIdentity>()
        func add(_ directory: HeldDirectory) {
            if seenStores.insert(directory.status.identity).inserted {
                stores.append(Store(identity: directory.status.identity, directory: directory))
            }
        }
        /// Runs `body`, naming `path` if it fails.
        func reading<T>(_ path: String, _ body: () throws -> T) throws -> T {
            do { return try body() } catch { throw SessionCopy.UnreadableStore(path: path) }
        }
        held.forEach(add)

        var roots: [String] = profiles.map { SessionStore.userDataDirectory($0.userDataDir, home: home).path }
        let support = PathNormalizer.normalize("Library/Application Support", home: home)
        if let supportDirectory = try reading(support, { try openIfThere(support) }) {
            for name in try reading(support, { try supportDirectory.entries() }).sorted() where name.lowercased().hasPrefix("claude") {
                roots.append(support + "/" + name)
            }
        }

        var seenRoots = Set<FileIdentity>()
        for root in roots {
            // Read the way Claude reads them: the user-data directory and its
            // `claude-code-sessions` by path (a link there is followed, as Claude follows it),
            // the account and organisation folders only when they are real folders.
            let sessionsPath = root + "/" + SessionStore.directoryName
            guard let userData = try reading(root, { try openIfThere(root) }), seenRoots.insert(userData.status.identity).inserted,
                  let sessions = try reading(sessionsPath, { try openIfThere(sessionsPath) })
            else { continue }
            for account in try reading(sessionsPath, { try sessions.entries() }).sorted()
            where try reading(sessionsPath + "/" + account, { try isRealDirectory(account, in: sessions) }) {
                let accountPath = sessionsPath + "/" + account
                let accountDirectory = try reading(accountPath, { try sessions.openDirectory(account, expectedOwner: nil) })
                for organization in try reading(accountPath, { try accountDirectory.entries() }).sorted()
                where try reading(accountPath + "/" + organization, { try isRealDirectory(organization, in: accountDirectory) }) {
                    add(try reading(accountPath + "/" + organization, { try accountDirectory.openDirectory(organization, expectedOwner: nil) }))
                }
            }
        }
        return StoreSurvey(stores: stores)
    }

    /// The names a session with this id would leave in a store: its record, and the tombstones
    /// Claude writes when it is deleted (under either id form).
    static func names(for id: String) -> [String] {
        [SessionStore.recordPrefix + id + SessionStore.recordSuffix, "deleted_" + id, "deleted_local_" + id]
    }

    struct Findings: Equatable {
        /// Stores with something at `local_<id>.json`.
        var records: Set<FileIdentity> = []
        /// Stores with a tombstone for the id.
        var tombstones: Set<FileIdentity> = []
        /// Stores where absence could not be proven either way.
        var unprovable: Set<FileIdentity> = []

        var isClear: Bool { records.isEmpty && tombstones.isEmpty && unprovable.isEmpty }
    }

    /// What is at the id's names, store by store. Absence is proven only by ENOENT.
    func findings(for id: String) -> Findings {
        var findings = Findings()
        let record = SessionStore.recordPrefix + id + SessionStore.recordSuffix
        for store in stores {
            for name in Self.names(for: id) {
                guard !store.directory.proveAbsent(name) else { continue }
                do {
                    _ = try store.directory.status(of: name)
                    if name == record { findings.records.insert(store.identity) } else { findings.tombstones.insert(store.identity) }
                } catch {
                    findings.unprovable.insert(store.identity)
                }
            }
        }
        return findings
    }

    /// A directory by path, following a link, or `nil` when there is none there: nothing at
    /// the path, or something that is not a folder. Any other failure is thrown.
    private static func openIfThere(_ path: String) throws -> HeldDirectory? {
        do {
            return try HeldDirectory.openAnchor(path, expectedOwner: nil)
        } catch let error as FileSystemError where error.reason == .absent || error.code == ENOTDIR
            || error.reason == .linkOrNotDirectory {
            return nil
        }
    }

    /// A real folder, not a link to one: Claude's loader takes only those.
    private static func isRealDirectory(_ name: String, in directory: HeldDirectory) throws -> Bool {
        do {
            return try directory.status(of: name).kind == .directory
        } catch let error as FileSystemError where error.reason == .absent {
            return false
        }
    }
}
