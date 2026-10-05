import CryptoKit
import Darwin
import Foundation

// The journal of copies in flight.
//
// A copy creates files in Claude's folders under names only this tool uses, then renames them
// into place. Interrupted — a crash, a power cut, a forced quit — it leaves those names behind,
// and nothing in Claude's folders says whose they are. The journal does: one small file per
// copy in the switcher's own `~/.config/claude-switcher/copies/`, written before the first
// staged byte, naming the exact folders (path and inode) and every object the copy created
// (name and inode, recorded the moment it is created). Recovery acts on what a journal names
// and on nothing else — it never looks for names — and proves each object is still the one
// that was created before it touches it.

/// A folder named by path and inode: the path to walk to, the inode to prove it is still the
/// same folder. Not the device number, which some volumes change between mounts.
struct JournalPlace: Codable, Equatable, Sendable {
    let path: String
    let inode: UInt64
}

/// One object a copy created, as it was created.
struct StagedObject: Codable, Equatable, Sendable {
    let name: String
    let inode: UInt64
    /// Set once its bytes are written.
    var size: Int64?
    /// The record's SHA-256 in hex, set once it is written: the only proof that a record at
    /// `local_<Y>.json` is still the one this tool wrote and Claude has not rewritten it.
    var sha256: String?
}

/// The names a copy stages under. A fresh id proven unused everywhere is in each, so nothing
/// but this copy can have made them — and nothing Claude makes looks like them: none ends in
/// `.jsonl`, `.json` or `.tmp`, or matches a temporary name Claude itself uses.
struct StagingNames: Codable, Equatable, Sendable {
    /// `<projDir>/.claude-switcher-copy-<Y>.jsonl.partial` → `<Y>.jsonl`
    let transcript: String
    /// `<projDir>/.claude-switcher-copy-<Y>.dir` → `<Y>` (holding `subagents/`)
    let directory: String
    /// `<store>/.claude-switcher-record-<Y>.partial` → `local_<Y>.json`
    let record: String

    init(id: String) {
        transcript = ".claude-switcher-copy-\(id).jsonl.partial"
        directory = ".claude-switcher-copy-\(id).dir"
        record = ".claude-switcher-record-\(id).partial"
    }

    static let subagents = "subagents"

    /// `agent-<id>.jsonl` with an id of `[A-Za-z0-9_-]+`: the only names ever created in the
    /// staged `subagents/` folder, and so the only names recovery will remove from it.
    static func isAgentFileName(_ name: String) -> Bool {
        name.hasPrefix("agent-") && name.hasSuffix(".jsonl")
            && TranscriptScan.isIdChars(String(name.dropFirst(6).dropLast(6)))
            && HeldDirectory.isSingleComponent(name)
    }
}

/// Everything a copy has created so far.
struct StagedObjects: Codable, Equatable, Sendable {
    var transcript: StagedObject?
    var directory: StagedObject?
    var subagents: StagedObject?
    var agents: [StagedObject] = []
    var record: StagedObject?

    var isEmpty: Bool {
        transcript == nil && directory == nil && subagents == nil && agents.isEmpty && record == nil
    }
}

/// One copy, as its journal file records it.
struct JournalEntry: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// Objects may be staged; nothing is in place. Recovery removes what it can prove.
        case staging
        /// Everything is staged and on the drive; the renames may have begun. Recovery rolls
        /// forward once `<Y>.jsonl` exists — after that nothing is ever undone.
        case staged
        /// The copy is in place. Kept until Claude has opened the record, for the menu's
        /// "copied, not yet opened" line.
        case committed
    }

    var version = 1
    var phase: Phase
    /// Y, the copy's lowercase id.
    let id: String
    /// X, the original's transcript id, and the original's record id — for the user's eyes
    /// only if something is ever reported; nothing acts on them.
    let sourceCliSessionId: String
    let sourceSessionID: String
    /// Profile labels, for the notes recovery shows. Profiles are never named by id: one can be
    /// removed or re-added under a new id while a journal waits.
    let sourceLabel: String
    let targetLabel: String
    let projectFolder: JournalPlace
    let targetUserData: JournalPlace
    let targetStore: JournalPlace
    let names: StagingNames
    var staged = StagedObjects()
    /// The record's timestamp (epoch ms): when the copy was taken.
    var copiedAt: Int64?

    var transcriptName: String { id + ".jsonl" }
    var directoryName: String { id }
    var recordName: String { SessionStore.recordPrefix + id + SessionStore.recordSuffix }

    /// What recovery is prepared to act on: an id that is a lowercase UUID, staging names that
    /// are exactly the ones derived from it, and agent files named only as a copy names them. A
    /// journal that says anything else is not acted on — it could name one of Claude's files.
    var isWellFormed: Bool {
        guard version == 1, SessionStore.isUUID(id), id == id.lowercased(), names == StagingNames(id: id) else { return false }
        if let transcript = staged.transcript, transcript.name != names.transcript { return false }
        if let directory = staged.directory, directory.name != names.directory { return false }
        if let subagents = staged.subagents, subagents.name != StagingNames.subagents { return false }
        if let record = staged.record, record.name != names.record { return false }
        return staged.agents.allSatisfy { StagingNames.isAgentFileName($0.name) }
            && Set(staged.agents.map(\.name)).count == staged.agents.count
    }
}

// MARK: - The journal directory

/// `~/.config/claude-switcher/copies`, held open.
///
/// The switcher's own folder, so it is opened the way the app opens its config — a link at or
/// above it is followed (a dotfiles manager may well link `~/.config`) — but it must be the
/// user's and writable by nobody else: recovery acts on what the files in it say.
struct CopyJournal {
    let directory: HeldDirectory
    /// For its flushes and its renames to be seen.
    let environment: SessionCopy.Environment

    static let maximumBytes = 1 << 20

    /// The journal folder of `environment`. `nil` when there is none and `create` is false:
    /// nothing in flight.
    static func open(_ environment: SessionCopy.Environment, create: Bool) throws -> CopyJournal? {
        let url = environment.journalDirectory
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let held: HeldDirectory
        do {
            held = try HeldDirectory.openAnchor(url.path, expectedOwner: environment.expectedUID)
        } catch let error as FileSystemError where error.reason == .absent && !create {
            return nil
        }
        try held.requireNotWritableByOthers()
        return CopyJournal(directory: held, environment: environment)
    }

    static func fileName(id: String) -> String { id + ".json" }
    private static func temporaryName(id: String) -> String { "." + id + ".json.partial" }

    /// The ids of every journal file here.
    func ids() throws -> [String] {
        try directory.entries().compactMap { name -> String? in
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            let id = String(name.dropLast(5))
            return SessionStore.isUUID(id) && id == id.lowercased() ? id : nil
        }.sorted()
    }

    /// The first journal of a copy: written whole under a temporary name and on the drive, then
    /// put in place with an exclusive rename — so a crash never leaves a torn journal (`ids()`
    /// does not read temporary names), and two copies can never share one. Its name, too, is
    /// flushed past the drive's cache before this returns, and so before the first staged
    /// byte: a power cut must never keep a staged file whose journal it lost.
    ///
    /// A volume without `RENAME_EXCL` here is the switcher's own folder's, not Claude's, and is
    /// refused as that (``SessionCopy/Refusal/journalFolderCannotRename``).
    func create(_ entry: JournalEntry) throws {
        let temporary = Self.temporaryName(id: entry.id)
        let name = Self.fileName(id: entry.id)
        // Only a crash in this very function could have left one, for this very id.
        try removeOwnFile(temporary)
        let file = try directory.createFile(temporary)
        do {
            try file.write(try Self.encode(entry))
            try environment.flush(file.descriptor, .full, .journalFile)
            try directory.renameExclusive(temporary, to: name, using: environment.journalRenameExclusive)
        } catch {
            try? removeOwnFile(temporary)
            if let error = error as? FileSystemError, error.reason == .renameUnsupported {
                throw SessionCopy.Refusal.journalFolderCannotRename
            }
            throw error
        }
        environment.note(.renamed(from: temporary, to: name))
        try environment.flush(directory.descriptor, .full, .journalFolder)
    }

    /// Replaces the journal whole: a temporary file, then a rename over the old one — in the
    /// switcher's own folder, the one place a plain rename is used, because replacing is the
    /// point. `toDrive` flushes past the drive's cache (`F_FULLFSYNC`); the phase changes do.
    func save(_ entry: JournalEntry, toDrive: Bool) throws {
        let temporary = Self.temporaryName(id: entry.id)
        let name = Self.fileName(id: entry.id)
        try removeOwnFile(temporary)
        let file = try directory.createFile(temporary)
        try file.write(try Self.encode(entry))
        try environment.flush(file.descriptor, toDrive ? .full : .fsync, .journalFile)
        guard renameat(directory.descriptor, temporary, directory.descriptor, name) == 0 else {
            throw FileSystemError.errno(errno, "renameat")
        }
        environment.note(.renamed(from: temporary, to: name))
        try environment.flush(directory.descriptor, toDrive ? .full : .fsync, .journalFolder)
    }

    func read(id: String) throws -> JournalEntry {
        let file = try directory.openRegularFile(Self.fileName(id: id))
        let status = try file.status()
        guard status.owner == directory.status.owner else { throw FileSystemError(.notOwnedByUser, "fstat") }
        let entry = try JSONDecoder().decode(JournalEntry.self, from: try file.readAll(limit: Self.maximumBytes))
        guard entry.id == id else { throw FileSystemError(.invalidName, "journal") }
        return entry
    }

    func delete(id: String) throws {
        try removeOwnFile(Self.fileName(id: id))
        try removeOwnFile(Self.temporaryName(id: id))
        try environment.flush(directory.descriptor, .fsync, .journalFolder)
    }

    /// Removes one of the journal's own files, if it is one: a regular file of the user's.
    private func removeOwnFile(_ name: String) throws {
        let status: FileStatus
        do { status = try directory.status(of: name) } catch let error as FileSystemError where error.reason == .absent { return }
        guard status.kind == .regular, status.owner == directory.status.owner else { throw FileSystemError(.notRegularFile, "fstatat") }
        try directory.unlink(name)
    }

    static func encode(_ entry: JournalEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entry)
    }
}

// MARK: - Removing what a copy staged

/// Removes what a copy staged — only after proving every piece of it is still exactly what
/// the copy created: at the exact staging name, a regular file with one link, the user's, the
/// inode recorded at creation (and, for the record, the bytes written). A staging folder must
/// hold nothing but what the copy put there; a `.DS_Store`, a link or a stranger's file leaves
/// it in place. If any proof fails, nothing at all is touched. Directories are removed one
/// empty level at a time, never recursively.
///
/// A staging name with no recorded inode is not this copy's — a planted file, or the instant
/// between a create and its journal entry — and is left alone.
struct StagingCleanup {
    let projectFolder: HeldDirectory
    /// `nil` when the store could not be reached; then a staged record cannot be proven.
    let store: HeldDirectory?
    let names: StagingNames
    let staged: StagedObjects
    let environment: SessionCopy.Environment
    private var owner: uid_t { environment.expectedUID }

    init(projectFolder: HeldDirectory, store: HeldDirectory?, names: StagingNames, staged: StagedObjects,
         environment: SessionCopy.Environment) {
        self.projectFolder = projectFolder
        self.store = store
        self.names = names
        self.staged = staged
        self.environment = environment
    }

    enum Outcome: Equatable {
        /// Every staged object is gone.
        case removed
        /// Something failed a proof; nothing was touched.
        case notProven
        /// A removal failed part-way; what was removed was proven first.
        case failed
    }

    func run() -> Outcome {
        guard let plan = prove() else { return .notProven }
        do {
            if let subagents = plan.subagents {
                for agent in plan.agents { try Self.unlink(agent, in: subagents, owner: owner) }
            }
            if let staging = plan.staging {
                if plan.subagents != nil { try Self.removeDirectory(StagingNames.subagents, inode: staged.subagents!.inode, in: staging) }
                try Self.removeDirectory(names.directory, inode: staged.directory!.inode, in: projectFolder)
            }
            if plan.transcript { try Self.unlink(staged.transcript!, in: projectFolder, owner: owner) }
            if plan.record, let store { try Self.unlink(staged.record!, in: store, owner: owner) }
            try? environment.flush(projectFolder.descriptor, .fsync, .projectFolder)
            if let store { try? environment.flush(store.descriptor, .fsync, .store) }
            return .removed
        } catch {
            return .failed
        }
    }

    /// What is there to remove, every piece proven; `nil` if anything is not provably ours.
    private struct Plan {
        var transcript = false
        var record = false
        var staging: HeldDirectory?
        var subagents: HeldDirectory?
        var agents: [StagedObject] = []
    }

    private func prove() -> Plan? {
        var plan = Plan()

        if let transcript = staged.transcript {
            switch Self.proveFile(transcript, in: projectFolder, owner: owner, sha256: nil) {
            case .absent: break
            case .ours: plan.transcript = true
            case .notOurs: return nil
            }
        }
        if let record = staged.record {
            guard let store else { return nil }
            switch Self.proveFile(record, in: store, owner: owner, sha256: record.sha256) {
            case .absent: break
            case .ours: plan.record = true
            case .notOurs: return nil
            }
        }

        guard let directory = staged.directory else { return plan }
        switch Self.proveDirectory(directory, in: projectFolder, owner: owner) {
        case .absent: return plan
        case .notOurs: return nil
        case .ours(let staging):
            plan.staging = staging
            guard let entries = try? staging.entries() else { return nil }
            guard let subagents = staged.subagents else { return entries.isEmpty ? plan : nil }
            guard entries.allSatisfy({ $0 == StagingNames.subagents }) else { return nil }
            if entries.isEmpty { return plan }
            guard case .ours(let held) = Self.proveDirectory(subagents, in: staging, owner: owner),
                  let agentNames = try? held.entries()
            else { return nil }
            plan.subagents = held
            let recorded = Dictionary(uniqueKeysWithValues: staged.agents.map { ($0.name, $0) })
            for name in agentNames {
                guard let agent = recorded[name], case .ours = Self.proveFile(agent, in: held, owner: owner, sha256: nil) else {
                    return nil
                }
                plan.agents.append(agent)
            }
            return plan
        }
    }

    enum FileProof: Equatable { case absent, ours, notOurs }

    /// Whether `object` is still at its name exactly as created. `sha256` also proves the bytes:
    /// the file is then opened without following a link, and the proof is made again on what
    /// was opened — the bytes hashed must be the very file proven, not one put at the name in
    /// between. `afterLooking` runs in that gap; tests use it to swap the file.
    static func proveFile(_ object: StagedObject, in directory: HeldDirectory, owner: uid_t, sha256: String?,
                          afterLooking: (() -> Void)? = nil) -> FileProof {
        let status: FileStatus
        do {
            status = try directory.status(of: object.name)
        } catch let error as FileSystemError where error.reason == .absent {
            return .absent
        } catch {
            return .notOurs
        }
        guard isAsCreated(status, object, owner: owner) else { return .notOurs }
        if let sha256 {
            afterLooking?()
            guard let file = try? directory.openRegularFile(object.name), let opened = try? file.status(),
                  isAsCreated(opened, object, owner: owner),
                  let data = try? file.readAll(limit: CopyJournal.maximumBytes),
                  Self.sha256(data) == sha256
            else { return .notOurs }
        }
        return .ours
    }

    enum DirectoryProof { case absent, ours(HeldDirectory), notOurs }

    /// Whether `object` is still the folder created. One look, through the descriptor: the name
    /// is opened without following a link and what was opened is checked, so there is no gap
    /// between a look and a use for a swap to slip into. Absent only on ENOENT.
    static func proveDirectory(_ object: StagedObject, in parent: HeldDirectory, owner: uid_t) -> DirectoryProof {
        let held: HeldDirectory
        do {
            held = try parent.openDirectory(object.name, expectedOwner: owner)
        } catch let error as FileSystemError where error.reason == .absent {
            return .absent
        } catch {
            return .notOurs
        }
        guard isFolderAsCreated(held.status, object, owner: owner) else { return .notOurs }
        return .ours(held)
    }

    /// Unlinks a file after checking, once more and immediately before, that it is the one created.
    static func unlink(_ object: StagedObject, in directory: HeldDirectory, owner: uid_t) throws {
        guard isAsCreated(try directory.status(of: object.name), object, owner: owner) else {
            throw FileSystemError(.notRegularFile, "fstatat")
        }
        try directory.unlink(object.name)
    }

    /// Removes an empty folder after checking it is still the one created. `unlinkat(AT_REMOVEDIR)`
    /// fails on anything that is not empty.
    static func removeDirectory(_ name: String, inode: UInt64, in parent: HeldDirectory) throws {
        let status = try parent.status(of: name)
        guard status.kind == .directory, status.inode == inode else { throw FileSystemError(.linkOrNotDirectory, "fstatat") }
        try parent.removeDirectory(name)
    }

    /// A staged file is still the one created: a regular file — not a link, which `*at()` calls
    /// would act on in place of what it points to — with one name (a second name would make it
    /// someone else's file too), the user's, and the very inode recorded at its creation.
    static func isAsCreated(_ status: FileStatus, _ object: StagedObject, owner: uid_t) -> Bool {
        status.kind == .regular && status.linkCount == 1 && status.owner == owner && status.inode == object.inode
    }

    /// A staged folder is still the one created: a real folder, the user's, the recorded inode.
    static func isFolderAsCreated(_ status: FileStatus, _ object: StagedObject, owner: uid_t) -> Bool {
        status.kind == .directory && status.owner == owner && status.inode == object.inode
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
