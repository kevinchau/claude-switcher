import Darwin
import Foundation

/// One copy, from resolving the two profiles to the last rename (the judgement's steps 1–13).
///
/// Everything below the anchors happens through descriptors held from the start: the project
/// folder and the target store are walked to once, with no link anywhere, and every create,
/// stat, rename and unlink afterwards is an `*at()` call on them. Nothing is ever written to
/// the source store, and nothing in a project folder but the staging names and, at the end,
/// `<Y>.jsonl` and `<Y>/`.
///
/// The transcript's rename is the point of no return. Before it, any failure removes exactly
/// what this run staged (each object re-proven) and the journal — all of it, or, when any
/// piece can no longer be proven to be the one created, none of it: the journal is kept, and
/// recovery reports it. After it, nothing is undone: a failed rename is tried once more, and
/// otherwise the journal is left at `staged` for recovery to finish.
final class CopyRun {
    private let request: SessionCopy.Request
    private let profiles: [Profile]
    private let environment: SessionCopy.Environment
    private var owner: uid_t { environment.expectedUID }
    private var home: String { environment.home }

    /// How many times the snapshot is retried, and how long to wait in between: more than two
    /// of the CLI's 100 ms flush intervals each time, five seconds in all.
    static let snapshotRetries = 20
    static let snapshotWait = 0.25
    /// What the record and the file-system bookkeeping need besides the copied bytes.
    static let recordAllowance: UInt64 = 64 * 1024

    // Resolved and held for the whole run.
    private var pair: SessionCopy.ResolvedPair!
    private var projectFolder: HeldDirectory!
    private var record: SessionRecord!
    private var x = ""
    private var newID = UUID()
    private var y = ""
    private var names: StagingNames!
    private var journal: CopyJournal?
    private var entry: JournalEntry!

    // What this run has created.
    private var staged = StagedObjects()
    /// Every staging name this run has tried to create, less those whose exclusive create
    /// found the name taken (which made nothing). One not in `staged` may hold an object this
    /// run made but could not journal — a failure after the create and before its entry.
    private var attempted: Set<String> = []
    private var transcriptFile: HeldFile?
    private var transcriptBytes = 0
    private var copiedSubagents = 0
    private var skippedSubagents = 0
    private var title: String?
    private var transcriptCommitted = false

    /// Thrown by a step hook: the run stops where it stands, as a crash would, with nothing
    /// cleaned up.
    private struct Interrupted: Error {}

    init(request: SessionCopy.Request, profiles: [Profile], environment: SessionCopy.Environment) {
        self.request = request
        var all = profiles
        for profile in [request.source, request.target] where !all.contains(where: { $0.id == profile.id }) {
            all.append(profile)
        }
        self.profiles = all
        self.environment = environment
    }

    func perform() -> SessionCopy.Outcome {
        do {
            return try run()
        } catch is Interrupted {
            // Only a test's hook gets here. The staged files and the journal stay for recovery.
            return transcriptCommitted ? pendingRegistration : .refused(.fileSystem(errno: EINTR))
        } catch {
            // Before the point of no return: remove what this run staged.
            removeStaging()
            return .refused((error as? SessionCopy.Refusal) ?? SessionCopy.Refusal(error))
        }
    }

    private func step(_ step: SessionCopy.Step) throws {
        do { try environment.hook(step) } catch { throw Interrupted() }
    }

    private func run() throws -> SessionCopy.Outcome {
        pair = try SessionCopy.resolvePair(source: request.source, target: request.target, environment: environment).get()
        try step(.resolved)
        try preflight()
        try step(.preflightPassed)
        try chooseID()
        try step(.idChosen)
        try startJournal()
        try step(.journalCreated)
        let prefix = try snapshot()
        let scan = TranscriptScan.scan(prefix)
        if let refusal = scan.refusal { throw refusal }
        let sources = try findSubagentSources(scan.referencedAgentIds)
        try requireSpace(bytes: UInt64(prefix.count + scan.clearBytes.count) + sources.reduce(0) { $0 + UInt64(max($1.size, 0)) })
        try step(.scanned)
        try stageTranscript(prefix + scan.clearBytes)
        try step(.transcriptStaged)
        try stageSubagents(sources)
        try step(.subagentsStaged)
        try stageRecord()
        try step(.recordStaged)
        try verifyStagedRecord()
        entry.phase = .staged
        entry.staged = staged
        try journal!.save(entry, toDrive: true)
        try step(.journalStaged)
        try recheck()
        try step(.rechecked)
        return try commit()
    }

    // MARK: 2. Preflight, on a fresh read of the record

    private func preflight() throws {
        guard let fresh = SessionStore.readRecord(named: request.sessionID + SessionStore.recordSuffix, in: pair.sourceStore) else {
            throw SessionCopy.Refusal.sessionChanged
        }
        guard let cliSessionId = fresh.cliSessionId else { throw SessionCopy.Refusal.noTranscriptYet }
        guard cliSessionId == request.cliSessionId, fresh.cwd == request.cwd else { throw SessionCopy.Refusal.sessionChanged }
        if fresh.isArchived { throw SessionCopy.Refusal.archived }
        if fresh.isRemote { throw SessionCopy.Refusal.remote }
        record = fresh
        x = cliSessionId

        let claims = SessionStore.transcriptClaims(profiles: profiles, home: home)[x.lowercased()]?.count ?? 0
        let running = RunningSessions.read(home: home, isAlive: environment.isAlive)
        var projects = ProjectFolders(home: home, expectedOwner: owner)
        if let obstacle = ListedSession.obstacle(
            for: fresh, cliSessionId: x, running: running, claimedBy: claims,
            store: pair.sourceStore, projects: &projects, expectedOwner: owner) {
            throw obstacle
        }
        projectFolder = try projects.folder(forCwd: fresh.cwd).get()
        // The early, cheap part of the space check, so the usual "disk full" refuses before
        // anything is written; the full one follows the scan.
        try requireSpace(bytes: UInt64(max(try projectFolder.status(of: x + ".jsonl").size, 0)))
    }

    private func requireSpace(bytes: UInt64) throws {
        guard let free = environment.freeBytes(projectFolder.descriptor),
              free >= bytes + Self.recordAllowance + SessionCopy.freeSpaceMargin
        else { throw SessionCopy.Refusal.notEnoughSpace }
    }

    // MARK: 3. A new id, unused everywhere

    private func chooseID() throws {
        newID = environment.newID()
        y = newID.uuidString.lowercased()
        names = StagingNames(id: y)
        try proveNewNamesAbsent()
        for name in [names.transcript, names.directory] where !projectFolder.proveAbsent(name) {
            throw SessionCopy.Refusal.nameTaken
        }
        guard pair.target.store.proveAbsent(names.record) else { throw SessionCopy.Refusal.nameTaken }
    }

    /// The copy's final names, and every name that would make Claude treat Y as taken: next to
    /// the transcript, in Claude Code's file history, and in every session store on the Mac.
    /// Proven absent only by ENOENT.
    private func proveNewNamesAbsent() throws {
        for name in [y + ".jsonl", y, TranscriptLocator.releaseMarkerName(cliSessionId: y)] where !projectFolder.proveAbsent(name) {
            throw SessionCopy.Refusal.nameTaken
        }
        try SessionCopy.proveNoFileHistory(for: y, home: home, owner: owner)
        let survey: StoreSurvey
        do {
            survey = try StoreSurvey.read(profiles: profiles, home: home, including: [pair.target.store, pair.sourceStore])
        } catch {
            throw SessionCopy.Refusal.storeUnreadable
        }
        let findings = survey.findings(for: y)
        if !findings.unprovable.isEmpty { throw SessionCopy.Refusal.storeUnreadable }
        if !findings.isClear { throw SessionCopy.Refusal.nameTaken }
    }

    // MARK: 4. The journal, before the first staged byte

    private func startJournal() throws {
        let journal = try CopyJournal.open(environment, create: true)!
        entry = JournalEntry(
            phase: .staging, id: y, sourceCliSessionId: x, sourceSessionID: record.id,
            sourceLabel: request.source.label, targetLabel: request.target.label,
            projectFolder: JournalPlace(path: SessionCopy.projectFolderPath(forCwd: record.cwd, home: home),
                                        inode: projectFolder.status.inode),
            targetUserData: JournalPlace(path: SessionStore.userDataDirectory(request.target.userDataDir, home: home).path,
                                         inode: pair.target.userData.status.inode),
            targetStore: JournalPlace(path: pair.target.folder.url.path, inode: pair.target.store.status.inode),
            names: names)
        try journal.create(entry)
        self.journal = journal
    }

    /// Records a newly created object in the journal at once, so that recovery can prove it is
    /// this copy's. A plain flush: the phase changes are the ones taken to the drive.
    private func journalCreated(_ update: (inout StagedObjects) -> Void) throws {
        update(&staged)
        entry.staged = staged
        try journal!.save(entry, toDrive: false)
    }

    /// Runs one exclusive create of a staging name, keeping track of whether it may have made
    /// something: an exclusive create that found the name taken made nothing, and the run
    /// knows that whatever is there is not its own.
    private func creating<Created>(_ name: String, _ create: () throws -> Created) throws -> Created {
        attempted.insert(name)
        do {
            let created = try create()
            environment.note(.created(name))
            return created
        } catch let error as FileSystemError where error.reason == .exists {
            attempted.remove(name)
            throw error
        }
    }

    // MARK: 5. A consistent snapshot of the source

    /// The source's bytes up to its last line feed, from a read nothing touched: the same
    /// descriptor's `fstat` before and after, and the name still on that file. A transcript
    /// being written is read again after a pause; one that never settles is refused.
    private func snapshot() throws -> Data {
        let name = x + ".jsonl"
        for attempt in 1...(Self.snapshotRetries + 1) {
            if attempt > 1 { environment.pause(Self.snapshotWait) }
            let file: HeldFile
            do {
                file = try projectFolder.openRegularFile(name)
            } catch let error as FileSystemError where error.reason == .absent {
                throw SessionCopy.Refusal.transcriptMissing
            }
            let opened = try file.status()
            if let problem = ListedSession.transcriptProblem(opened, expectedOwner: owner) { throw problem }
            let data = try file.read(count: Int(opened.size), at: 0)
            try step(.snapshotRead(attempt: attempt))
            let closed = try file.status()
            let atName = try? projectFolder.status(of: name)
            guard SessionCopy.readWasUndisturbed(opened: opened, closed: closed, atName: atName, bytesRead: data.count) else {
                continue
            }
            guard let complete = TranscriptScan.completeLength(of: data) else { throw SessionCopy.Refusal.transcriptEmpty }
            return Data(data.prefix(complete))
        }
        throw SessionCopy.Refusal.stillBeingWritten
    }

    // MARK: 6. The subagent transcripts it references

    /// A referenced subagent transcript, as found: where, how large, which file. Not held open —
    /// a session can reference hundreds, and a GUI app may have only 256 descriptors. Each is
    /// opened when it is staged, and must then still be this file.
    struct SubagentSource {
        let id: String
        /// `<X>/subagents`, held for the run, or the project folder.
        let directory: HeldDirectory
        let size: Int64
        let inode: UInt64

        var name: String { "agent-\(id).jsonl" }
    }

    /// Finds each referenced subagent transcript where Desktop looks for it: nested
    /// `<X>/subagents/agent-<id>.jsonl`, or — only when that path does not exist — flat
    /// `<projDir>/agent-<id>.jsonl`. A link anywhere on either path refuses the copy; anything
    /// else unusable (a pipe, a folder, no permission) is skipped and counted, as Desktop skips it.
    private func findSubagentSources(_ ids: [String]) throws -> [SubagentSource] {
        guard !ids.isEmpty else { return [] }
        var nested: HeldDirectory?
        if let session = try openDirectoryIfThere(x, in: projectFolder) {
            nested = try openDirectoryIfThere(StagingNames.subagents, in: session)
        }
        var sources: [SubagentSource] = []
        for id in ids {
            let name = "agent-\(id).jsonl"
            guard StagingNames.isAgentFileName(name) else { skippedSubagents += 1; continue }
            var lookup = Lookup.notThere
            var directory = projectFolder!
            if let nested {
                lookup = try lookUp(name, in: nested)
                directory = nested
            }
            if case .notThere = lookup {
                lookup = try lookUp(name, in: projectFolder)
                directory = projectFolder
            }
            switch lookup {
            case .found(let status):
                sources.append(SubagentSource(id: id, directory: directory, size: status.size, inode: status.inode))
            case .notThere, .unusable: skippedSubagents += 1
            }
        }
        return sources
    }

    private enum Lookup {
        case found(FileStatus)
        /// ENOENT (or, for the nested folders, ENOTDIR): the only cases that fall back to flat.
        case notThere
        case unusable
    }

    private func lookUp(_ name: String, in directory: HeldDirectory) throws -> Lookup {
        let status: FileStatus
        do {
            status = try directory.status(of: name)
        } catch let error as FileSystemError where error.reason == .absent {
            return .notThere
        } catch {
            return .unusable
        }
        switch status.kind {
        case .symbolicLink: throw SessionCopy.Refusal.linkInPath
        case .regular: return .found(status)
        case .directory, .other: return .unusable
        }
    }

    /// A folder below `parent`, held; `nil` when nothing is there or it is not a folder (the
    /// ENOENT/ENOTDIR of a path through it). A link refuses.
    private func openDirectoryIfThere(_ name: String, in parent: HeldDirectory) throws -> HeldDirectory? {
        let status: FileStatus
        do {
            status = try parent.status(of: name)
        } catch let error as FileSystemError where error.reason == .absent {
            return nil
        }
        switch status.kind {
        case .symbolicLink: throw SessionCopy.Refusal.linkInPath
        case .directory: return try parent.openDirectory(name, expectedOwner: owner)
        case .regular, .other: return nil
        }
    }

    // MARK: 7. Staging the transcript

    private func stageTranscript(_ bytes: Data) throws {
        let file = try creating(names.transcript) { try projectFolder.createFile(names.transcript) }
        let created = try file.status()
        try journalCreated { $0.transcript = StagedObject(name: names.transcript, inode: created.inode) }
        try file.write(bytes)
        try environment.flush(file.descriptor, .fsync, .transcript)
        try step(.transcriptWritten)
        try requireWritten(file, size: bytes.count)
        staged.transcript?.size = Int64(bytes.count)
        transcriptFile = file
        transcriptBytes = bytes.count
    }

    /// A staged file holds exactly what was written, under one name: nothing truncated or
    /// extended it, and nothing gave it a second name, between the write and now.
    private func requireWritten(_ file: HeldFile, size: Int) throws {
        let written = try file.status()
        guard written.size == Int64(size), written.linkCount == 1 else { throw SessionCopy.Refusal.fileSystem(errno: EIO) }
    }

    // MARK: 8. Staging the subagent transcripts

    /// Each one opened, read, staged and closed before the next. A source that is no longer the
    /// file found (another inode at its name) is skipped, as one that cannot be opened is.
    private func stageSubagents(_ sources: [SubagentSource]) throws {
        var subagents: HeldDirectory?
        for source in sources {
            guard let file = try? source.directory.openRegularFile(source.name), let opened = try? file.status(),
                  opened.inode == source.inode
            else { skippedSubagents += 1; continue }
            let data = try file.read(count: Int(max(opened.size, 0)), at: 0)
            guard let complete = TranscriptScan.completeLength(of: data) else { skippedSubagents += 1; continue }
            if subagents == nil {
                let staging = try creating(names.directory) {
                    try projectFolder.makeDirectory(names.directory, expectedOwner: owner) { try self.step(.stagingFolderCreated) }
                }
                try journalCreated { $0.directory = StagedObject(name: self.names.directory, inode: staging.status.inode) }
                let made = try creating(StagingNames.subagents) { try staging.makeDirectory(StagingNames.subagents, expectedOwner: owner) }
                try journalCreated { $0.subagents = StagedObject(name: StagingNames.subagents, inode: made.status.inode) }
                subagents = made
            }
            let name = source.name
            let copy = try creating(name) { try subagents!.createFile(name) }
            let created = try copy.status()
            try journalCreated { $0.agents.append(StagedObject(name: name, inode: created.inode)) }
            try copy.write(data.prefix(complete))
            try environment.flush(copy.descriptor, .fsync, .agent)
            try step(.agentWritten)
            try requireWritten(copy, size: complete)
            staged.agents[staged.agents.count - 1].size = Int64(complete)
            copiedSubagents += 1
        }
    }

    // MARK: 9. Staging the record

    private var recordBytes = Data()

    private func stageRecord() throws {
        let now = environment.now()
        recordBytes = CopyRecord.bytes(forCopyOf: record, newID: newID, now: now)
        guard CopyRecord.isFree(recordBytes, ofSourceCliSessionId: x, sourceRecordID: record.id) else {
            throw SessionCopy.Refusal.recordCheckFailed
        }
        let file = try creating(names.record) { try pair.target.store.createFile(names.record) }
        let created = try file.status()
        try journalCreated { $0.record = StagedObject(name: names.record, inode: created.inode) }
        try file.write(recordBytes)
        try environment.flush(file.descriptor, .fsync, .record)
        entry.copiedAt = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        title = CopyRecord.title(forCopyOf: record.title)
    }

    /// Reads back what is on disk under the staging name, through a new descriptor, and keeps
    /// the hash of exactly those bytes: from here on they are what proves the record is ours.
    private func verifyStagedRecord() throws {
        guard let back = try? pair.target.store.openRegularFile(names.record),
              (try? back.status())?.inode == staged.record?.inode,
              (try? back.readAll(limit: CopyJournal.maximumBytes)) == recordBytes
        else { throw SessionCopy.Refusal.recordCheckFailed }
        staged.record?.size = Int64(recordBytes.count)
        staged.record?.sha256 = StagingCleanup.sha256(recordBytes)
    }

    // MARK: 11. The re-check before anything is put in place

    private func recheck() throws {
        try requireTargetUnchanged()
        // The project folder is still where Claude will look for the copy.
        switch ProjectFolders.open(slug: TranscriptLocator.projectSlug(forCwd: record.cwd), home: home, expectedOwner: owner) {
        case .failure(let refusal): throw refusal
        case .success(let again):
            guard again.status.identity == projectFolder.status.identity else { throw SessionCopy.Refusal.sessionChanged }
        }
        // The original is still there: a copy of a session deleted meanwhile would bring it back.
        guard let again = SessionStore.readRecord(named: request.sessionID + SessionStore.recordSuffix, in: pair.sourceStore),
              again.cliSessionId == x, again.cwd == record.cwd
        else { throw SessionCopy.Refusal.sessionChanged }
        try proveNewNamesAbsent()
    }

    /// The target still resolves, by the copy-target rule, to the very folder held.
    private func requireTargetUnchanged() throws {
        guard case .success(let again) = SessionStore.locateForCopyTarget(profile: request.target, home: home, expectedOwner: owner),
              again.store.status.identity == pair.target.store.status.identity,
              SessionStore.sameID(again.folder.accountID, pair.target.folder.accountID),
              SessionStore.sameID(again.folder.organizationID, pair.target.folder.organizationID)
        else { throw SessionCopy.Refusal.targetChanged(target: request.target.label) }
    }

    // MARK: 12. Commit

    private func commit() throws -> SessionCopy.Outcome {
        let store = pair.target.store
        let separateVolumes = !environment.sameVolume(projectFolder.status, store.status)
        // Everything staged to the drive, past its cache, before the first rename. (The
        // journal's own flush covered its volume; the store may be on another.)
        try environment.flush(transcriptFile!.descriptor, .full, .transcript)
        if separateVolumes { try environment.flush(store.descriptor, .full, .store) }

        // (1) The transcript: the point of no return.
        try renameStaged(staged.transcript!, in: projectFolder, to: y + ".jsonl")
        transcriptCommitted = true
        try step(.transcriptCommitted)

        // (2) The subagent folder, if there is one.
        if let directory = staged.directory {
            guard twice({ try self.renameStagedDirectory(directory) }) else { return pendingRegistration }
            try step(.directoryCommitted)
        }

        // The renames above on the drive before the record's: on another volume the record
        // could otherwise reach its drive first, and a power cut leave a registered session
        // whose transcript is still under its staging name. A failed flush is not retried.
        do {
            try environment.flush(projectFolder.descriptor, .fsync, .projectFolder)
            if separateVolumes { try environment.flush(projectFolder.descriptor, .full, .projectFolder) }
        } catch {
            return pendingRegistration
        }

        // (3) The record — only into the folder the target's Claude will load now.
        guard twice({
            try self.requireTargetUnchanged()
            try self.renameStaged(self.staged.record!, in: store, to: self.entry.recordName)
        }) else { return pendingRegistration }
        try step(.recordCommitted)

        try? environment.flush(projectFolder.descriptor, .fsync, .projectFolder)
        try? environment.flush(store.descriptor, .fsync, .store)
        try? environment.flush(store.descriptor, .full, .store)
        entry.phase = .committed
        entry.staged = staged
        // If this fails the journal stays at `staged`, and recovery finds the record in place
        // with the journalled bytes and marks it committed.
        try? journal!.save(entry, toDrive: true)
        return .copied(SessionCopy.Success(
            newSessionID: SessionStore.recordPrefix + y, title: title, copiedSubagentTranscripts: copiedSubagents,
            skippedSubagentTranscripts: skippedSubagents, transcriptBytes: transcriptBytes))
    }

    private var pendingRegistration: SessionCopy.Outcome {
        .pendingRegistration(newSessionID: SessionStore.recordPrefix + y,
                             detail: Self.pendingDetail(target: request.target.label))
    }

    /// What the result of a copy left for recovery says: recovery is tried at once, and again
    /// at each start until it can act.
    static func pendingDetail(target: String) -> String {
        "The copy is on disk but is not yet in \(target)\u{2019}s list. Claude Switcher will finish registering it \u{2014} "
            + "now if it can, otherwise at its next start."
    }

    /// After the point of no return a failed step is tried once more, and then left to recovery.
    private func twice(_ body: () throws -> Void) -> Bool {
        if (try? body()) != nil { return true }
        return (try? body()) != nil
    }

    /// `renameatx_np(RENAME_EXCL)` of a staged file, after checking the staging name is still
    /// the file created and still the size it was written at (cleanup removes a file of ours
    /// whatever its size; only what is put in place must be exactly what was written). Never a
    /// plain rename.
    private func renameStaged(_ object: StagedObject, in directory: HeldDirectory, to final: String) throws {
        guard StagingCleanup.proveFile(object, in: directory, owner: owner, sha256: object.sha256) == .ours,
              object.size == nil || (try? directory.status(of: object.name))?.size == object.size
        else { throw SessionCopy.Refusal.notPlainFile }
        try directory.renameExclusive(object.name, to: final, using: environment.renameExclusive)
        environment.note(.renamed(from: object.name, to: final))
    }

    private func renameStagedDirectory(_ object: StagedObject) throws {
        guard case .ours = StagingCleanup.proveDirectory(object, in: projectFolder, owner: owner) else {
            throw SessionCopy.Refusal.notPlainFile
        }
        try projectFolder.renameExclusive(object.name, to: y, using: environment.renameExclusive)
        environment.note(.renamed(from: object.name, to: y))
    }

    // MARK: 13. Failure before the point of no return

    /// Removes what this run staged — each object re-proven — and then its journal. Anything
    /// that fails a proof leaves everything in place and the journal kept, for recovery to
    /// report: all or nothing, so the journal always names everything still staged.
    ///
    /// So does a staging name the run created but could not journal (a failure between the
    /// create and its entry) unless the name is provably free again: forgetting the journal
    /// would forget the object. A name whose exclusive create found it taken is not this run's.
    private func removeStaging() {
        guard let journal, !transcriptCommitted else { return }
        var unjournalled: [(folder: HeldDirectory, name: String)] = []
        if staged.transcript == nil { unjournalled.append((projectFolder, names.transcript)) }
        if staged.directory == nil { unjournalled.append((projectFolder, names.directory)) }
        if staged.record == nil { unjournalled.append((pair.target.store, names.record)) }
        let nothingUnjournalled = unjournalled.allSatisfy { !attempted.contains($0.name) || $0.folder.proveAbsent($0.name) }
        let cleanup = StagingCleanup(projectFolder: projectFolder, store: pair.target.store, names: names,
                                     staged: staged, environment: environment)
        if nothingUnjournalled, cleanup.run() == .removed {
            try? journal.delete(id: y)
        } else {
            entry.staged = staged
            try? journal.save(entry, toDrive: true)
        }
    }
}
