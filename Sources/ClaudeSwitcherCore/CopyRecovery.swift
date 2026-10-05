import Darwin
import Foundation

/// Finishes or cleans up copies that were interrupted (the judgement's step 14), and lists the
/// ones Claude has not opened yet.
///
/// Runs at launch and before each copy, only in the switcher holding the AutomationLock — so
/// nothing can be in flight, and every journal is handled at once. It acts on journals and on
/// nothing else: it never looks for names. Each journal names its folders by path and inode
/// (never a profile, which may since have been removed or re-added) and each object it created
/// by name and inode; every one is re-proven before it is touched.
///
/// Before the transcript's rename only staging names are removed. After it, recovery only
/// moves forward — renaming staged objects into place — or, when another account has already
/// registered the transcript, removes its own record and stops. No branch removes `<Y>.jsonl`,
/// `<Y>/` or any `local_*.json`. Anything that fails a proof, or a store that cannot be read,
/// leaves everything as it is and the journal kept, with a note.
struct CopyRecovery {
    let profiles: [Profile]
    let environment: SessionCopy.Environment
    private var owner: uid_t { environment.expectedUID }
    private var home: String { environment.home }

    init(profiles: [Profile], environment: SessionCopy.Environment) {
        self.profiles = profiles
        self.environment = environment
    }

    func run() -> [SessionCopy.RecoveryNote] {
        let journal: CopyJournal
        let ids: [String]
        do {
            guard let found = try CopyJournal.open(environment, create: false) else {
                return []
            }
            journal = found
            ids = try journal.ids()
        } catch {
            return [Note.journalUnreadable()]
        }
        return ids.compactMap { id in
            handle(id: id, in: journal).map {
                SessionCopy.RecoveryNote(message: $0.message, kind: $0.kind, copyID: SessionStore.recordPrefix + id)
            }
        }
    }

    private func handle(id: String, in journal: CopyJournal) -> SessionCopy.RecoveryNote? {
        guard let entry = try? journal.read(id: id), entry.isWellFormed else { return Note.journalUnreadable() }
        let target = entry.targetLabel

        // e. Committed: kept only for the "not yet opened" line, until Claude opens the record.
        if entry.phase == .committed {
            switch Self.place(entry.targetStore, home: home, owner: owner) {
            case .gone:
                try? journal.delete(id: id)
            case .held(let store):
                if Self.committedRecord(of: entry, in: store) == nil { try? journal.delete(id: id) }
            case .unreachable:
                break
            }
            return nil
        }

        let projectPlace = Self.place(entry.projectFolder, home: home, owner: owner, forWriting: true)
        let storePlace = Self.place(entry.targetStore, home: home, owner: owner, forWriting: true)

        // a. Nothing journalled as staged: there is nothing to undo — once the names a crash
        //    between a create and its journal entry would have left are proven free.
        if entry.staged.isEmpty {
            if let note = unjournalledNote(entry, projectFolder: projectPlace, store: storePlace) { return note }
            try? journal.delete(id: id)
            return Note.cleanedUp(target)
        }

        guard case .held(let projectFolder) = projectPlace else { return Note.cannotCheck(target) }
        var store: HeldDirectory?
        if case .held(let held) = storePlace { store = held }

        // a. Still staging, or the transcript never reached its final name — it is still under
        //    its staging name as created (with one name, it cannot also be at `<Y>.jsonl`), or
        //    `<Y>.jsonl` is not there: remove the proven staging names and forget the copy.
        let transcriptStillStaged = entry.staged.transcript.map {
            StagingCleanup.proveFile($0, in: projectFolder, owner: owner, sha256: nil) == .ours
        } ?? false
        if entry.phase == .staging || transcriptStillStaged || projectFolder.proveAbsent(entry.transcriptName) {
            // The record may have been renamed into place with the transcript's rename lost —
            // two volumes, and a power cut between them. Then the session is registered, and
            // nothing it may need is removed.
            if entry.phase == .staged, let store, !store.proveAbsent(entry.recordName) { return Note.cannotCheck(target) }
            if let note = unjournalledNote(entry, projectFolder: projectPlace, store: storePlace) { return note }
            let cleanup = StagingCleanup(projectFolder: projectFolder, store: store, names: entry.names,
                                         staged: entry.staged, environment: environment)
            guard cleanup.run() == .removed else { return Note.leftInPlace(target) }
            try? journal.delete(id: id)
            return Note.cleanedUp(target)
        }

        // `<Y>.jsonl` is there. It must be the transcript this copy staged.
        guard let transcript = entry.staged.transcript,
              StagingCleanup.proveFile(StagedObject(name: entry.transcriptName, inode: transcript.inode),
                                       in: projectFolder, owner: owner, sha256: nil) == .ours,
              let store
        else { return Note.cannotCheck(target) }

        let findings: StoreSurvey.Findings
        do {
            findings = try StoreSurvey.read(profiles: profiles, home: home, including: [store]).findings(for: entry.id)
        } catch {
            return Note.cannotCheck(target)
        }
        guard findings.unprovable.isEmpty else { return Note.cannotCheck(target) }

        // c. The record was put in place and only the journal was not updated.
        if findings.records.contains(store.status.identity), Self.committedRecord(of: entry, in: store) != nil {
            guard finishDirectory(entry, in: projectFolder) else { return Note.leftInPlace(target) }
            return markCommitted(entry, in: journal) ? Note.finished(target) : nil
        }

        // c. The record was put in place, and the target's Claude has already opened it — it
        //    rewrites a record the first time it shows the session — before the journal was
        //    updated: the record at `local_<Y>.json` is the only one on the Mac and this copy's
        //    own is no longer under its staging name. The copy is done.
        if findings.records == [store.status.identity], findings.tombstones.isEmpty, store.proveAbsent(entry.names.record) {
            guard finishDirectory(entry, in: projectFolder) else { return Note.leftInPlace(target) }
            try? journal.delete(id: id)
            return nil
        }

        // c. Another profile registered the transcript meanwhile (an import), something else is
        //    at `local_<Y>.json`, or a session with this id has been deleted: never a second
        //    record. Only this copy's own record is removed — proven by its bytes — and the
        //    subagent folder joins its transcript.
        if !findings.records.isEmpty || !findings.tombstones.isEmpty {
            let ownRecord = StagedObjects(record: entry.staged.record)
            guard StagingCleanup(projectFolder: projectFolder, store: store, names: entry.names, staged: ownRecord,
                                 environment: environment).run() == .removed,
                  finishDirectory(entry, in: projectFolder)
            else { return Note.leftInPlace(target) }
            try? journal.delete(id: id)
            return Note.registeredElsewhere(target)
        }

        // b. Roll forward: the subagent folder, then — if the target is still signed in to the
        //    account it was copied for — the record, once the renames before it are on the drive
        //    (on two volumes the record's could otherwise get there first).
        guard finishDirectory(entry, in: projectFolder) else { return Note.leftInPlace(target) }
        guard targetStillQualifies(entry, store: store) else { return Note.targetChanged(target) }
        guard let record = entry.staged.record, record.sha256 != nil,
              StagingCleanup.proveFile(record, in: store, owner: owner, sha256: record.sha256) == .ours
        else { return Note.leftInPlace(target) }
        do {
            try environment.flush(projectFolder.descriptor, .fsync, .projectFolder)
            if !environment.sameVolume(projectFolder.status, store.status) {
                try environment.flush(projectFolder.descriptor, .full, .projectFolder)
            }
        } catch {
            return Note.cannotCheck(target)
        }
        do {
            try store.renameExclusive(record.name, to: entry.recordName, using: environment.renameExclusive)
        } catch {
            return Note.leftInPlace(target)
        }
        environment.note(.renamed(from: record.name, to: entry.recordName))
        try? environment.flush(projectFolder.descriptor, .fsync, .projectFolder)
        try? environment.flush(store.descriptor, .fsync, .store)
        try? environment.flush(store.descriptor, .full, .store)
        return markCommitted(entry, in: journal) ? Note.finished(target) : nil
    }

    /// Whether the names a copy creates in Claude's folders that its journal does not name are
    /// free. A crash between an exclusive create and its journal entry leaves an object there
    /// that is this copy's but cannot be proven so — and forgetting the journal would forget
    /// it. A folder that is gone holds nothing of this copy's; one that cannot be reached
    /// cannot be checked. `nil` when all is clear, otherwise the note to give.
    private func unjournalledNote(_ entry: JournalEntry, projectFolder: Place, store: Place) -> SessionCopy.RecoveryNote? {
        var names: [(place: Place, name: String)] = []
        if entry.staged.transcript == nil { names.append((projectFolder, entry.names.transcript)) }
        if entry.staged.directory == nil { names.append((projectFolder, entry.names.directory)) }
        if entry.staged.record == nil { names.append((store, entry.names.record)) }
        var unreachable = false
        for (place, name) in names {
            switch place {
            case .gone: continue
            case .unreachable: unreachable = true
            case .held(let folder): if !folder.proveAbsent(name) { return Note.leftInPlace(entry.targetLabel) }
            }
        }
        return unreachable ? Note.cannotCheck(entry.targetLabel) : nil
    }

    /// Renames the staged subagent folder to `<Y>` if it is still there and still the one
    /// created. `false` when it is there but cannot be proven or renamed.
    private func finishDirectory(_ entry: JournalEntry, in projectFolder: HeldDirectory) -> Bool {
        guard let directory = entry.staged.directory else { return true }
        switch StagingCleanup.proveDirectory(directory, in: projectFolder, owner: owner) {
        case .absent: return true
        case .notOurs: return false
        case .ours:
            do {
                try projectFolder.renameExclusive(directory.name, to: entry.directoryName, using: environment.renameExclusive)
                environment.note(.renamed(from: directory.name, to: entry.directoryName))
                try? environment.flush(projectFolder.descriptor, .fsync, .projectFolder)
                return true
            } catch {
                return false
            }
        }
    }

    /// The copy-target rule again, on the journalled folders: signed in to the account the copy
    /// was filed for, and resolving to the very store folder journalled.
    private func targetStillQualifies(_ entry: JournalEntry, store: HeldDirectory) -> Bool {
        let profile = Profile(id: "journal", label: entry.targetLabel, userDataDir: entry.targetUserData.path)
        guard case .success(let resolved) = SessionStore.locateForCopyTarget(profile: profile, home: home, expectedOwner: owner),
              resolved.userData.status.inode == entry.targetUserData.inode,
              resolved.store.status.identity == store.status.identity
        else { return false }
        return true
    }

    private func markCommitted(_ entry: JournalEntry, in journal: CopyJournal) -> Bool {
        var committed = entry
        committed.phase = .committed
        return (try? journal.save(committed, toDrive: true)) != nil
    }

    // MARK: - Shared with the pending list

    enum Place {
        case held(HeldDirectory)
        /// Not there any more, or something else is at the path now.
        case gone
        /// Could not be reached: a link, another owner, no permission.
        case unreachable
    }

    /// A journalled folder, walked to again from the home directory with no link anywhere, and
    /// required to be the very folder journalled.
    static func place(_ place: JournalPlace, home: String, owner: uid_t, forWriting: Bool = false) -> Place {
        let held: HeldDirectory
        do {
            held = try HeldDirectory.walk(to: place.path, home: home, expectedOwner: owner)
        } catch let error as FileSystemError where error.reason == .absent {
            return .gone
        } catch {
            return .unreachable
        }
        guard held.status.inode == place.inode else { return .gone }
        if forWriting, (try? held.requireNotWritableByOthers()) == nil { return .unreachable }
        return .held(held)
    }

    /// The committed record's bytes, if `local_<Y>.json` still holds exactly what was written —
    /// Claude rewrites it the first time it shows the session.
    static func committedRecord(of entry: JournalEntry, in store: HeldDirectory) -> Data? {
        guard let sha256 = entry.staged.record?.sha256,
              let file = try? store.openRegularFile(entry.recordName),
              let data = try? file.readAll(limit: CopyJournal.maximumBytes),
              StagingCleanup.sha256(data) == sha256
        else { return nil }
        return data
    }

    /// Every journal that is not committed, read and never acted on: the journal folder and its
    /// files only — nothing in Claude's folders, no gate. Oldest first.
    static func unfinished(environment: SessionCopy.Environment) -> [SessionCopy.Unfinished] {
        let journal: CopyJournal
        let ids: [String]
        do {
            guard let found = try CopyJournal.open(environment, create: false) else { return [] }
            journal = found
            ids = try journal.ids()
        } catch {
            return [SessionCopy.Unfinished(targetLabel: nil, state: .unreadable, since: nil)]
        }
        var unfinished: [SessionCopy.Unfinished] = []
        for id in ids {
            let since = (try? journal.directory.status(of: CopyJournal.fileName(id: id)))
                .map { Date(timeIntervalSince1970: Double($0.modifiedNanoseconds) / 1_000_000_000) }
            guard let entry = try? journal.read(id: id), entry.isWellFormed else {
                unfinished.append(SessionCopy.Unfinished(targetLabel: nil, state: .unreadable, since: since))
                continue
            }
            switch entry.phase {
            case .committed: continue
            case .staging: unfinished.append(SessionCopy.Unfinished(targetLabel: entry.targetLabel, state: .staging, since: since))
            case .staged: unfinished.append(SessionCopy.Unfinished(targetLabel: entry.targetLabel, state: .staged, since: since))
            }
        }
        return unfinished.sorted { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }
    }

    static func pending(environment: SessionCopy.Environment) -> [SessionCopy.Pending] {
        guard let journal = try? CopyJournal.open(environment, create: false),
              let ids = try? journal.ids()
        else { return [] }
        var pending: [SessionCopy.Pending] = []
        for id in ids {
            guard let entry = try? journal.read(id: id), entry.isWellFormed, entry.phase == .committed,
                  case .held(let store) = place(entry.targetStore, home: environment.home, owner: environment.expectedUID),
                  let data = committedRecord(of: entry, in: store)
            else { continue }
            pending.append(SessionCopy.Pending(
                id: SessionStore.recordPrefix + id,
                title: SessionStore.record(from: data, fileStem: SessionStore.recordPrefix + id)?.title,
                targetStore: URL(fileURLWithPath: entry.targetStore.path, isDirectory: true),
                copiedAt: Date(timeIntervalSince1970: Double(entry.copiedAt ?? 0) / 1000)))
        }
        return pending.sorted { ($0.copiedAt, $0.id) > ($1.copiedAt, $1.id) }
    }

    // MARK: - What recovery says

    /// One plain sentence each, naming the account by its label; never a path, id or title.
    /// None assumes the user saw an interruption: recovery also runs seconds after a copy that
    /// only failed a rename or a flush, and before every copy.
    enum Note {
        static func cleanedUp(_ target: String, id: String? = nil) -> SessionCopy.RecoveryNote {
            .init(message: "A copy to \(target) did not finish; its partial files were removed and nothing was copied.",
                  kind: .cleanedUp, copyID: id)
        }
        static func finished(_ target: String, id: String? = nil) -> SessionCopy.RecoveryNote {
            .init(message: "A copy to \(target) that had not finished has been finished; it appears in \(target)\u{2019}s Code tab the next time that Claude starts.",
                  kind: .finished, copyID: id)
        }
        static func registeredElsewhere(_ target: String, id: String? = nil) -> SessionCopy.RecoveryNote {
            .init(message: "A copy to \(target) that had not finished had meanwhile been registered by another account, so Claude Switcher did not register it again.",
                  kind: .registeredElsewhere, copyID: id)
        }
        static func targetChanged(_ target: String, id: String? = nil) -> SessionCopy.RecoveryNote {
            .init(message: "A copy to \(target) is on disk but was not registered, because \(target) is no longer signed in to the account it was copied for; Claude Switcher will try again at its next start.",
                  kind: .waiting, copyID: id)
        }
        static func leftInPlace(_ target: String, id: String? = nil) -> SessionCopy.RecoveryNote {
            .init(message: "A copy to \(target) that did not finish left files Claude Switcher could not prove are still its own, so it left them in place.",
                  kind: .leftInPlace, copyID: id)
        }
        static func cannotCheck(_ target: String, id: String? = nil) -> SessionCopy.RecoveryNote {
            .init(message: "Claude Switcher could not check a copy to \(target) that did not finish; it changed nothing and will try again at its next start.",
                  kind: .cannotCheck, copyID: id)
        }
        static func journalUnreadable(id: String? = nil) -> SessionCopy.RecoveryNote {
            .init(message: "Claude Switcher could not read its record of a copy in progress, so it changed nothing.",
                  kind: .journalUnreadable, copyID: id)
        }
    }
}
