import Darwin
import Foundation

/// Copies a Code session from one account's profile to another's.
///
/// Claude Desktop keeps each account's list of sessions apart, but every transcript lives in
/// the shared `~/.claude/projects`. A copy is a new transcript next to the original (the
/// original's bytes up to its last complete line, plus the clearing lines described in
/// ``TranscriptScan``), its referenced subagent transcripts, and a new record in the other
/// account's store (``CopyRecord``) — all under a fresh id, so the two sessions never share a
/// file Claude would write to or delete.
///
/// The rules everything here follows: create only; remove only staging names this run
/// created, after re-proving each one; never remove or replace a Claude-named path; never
/// delete recursively; reach every folder by a descriptor walk with no link anywhere below
/// the home directory (``HeldDirectory``).
public enum SessionCopy {

    // MARK: - Seams

    /// Every outside effect a copy depends on, so tests run in a temporary home with a fake
    /// clock, id source, owner, process table, disk and volume. `.live` is the real thing.
    public struct Environment: Sendable {
        /// Everything is found from here: `<home>/.claude` and the profiles' user-data directories.
        public var home: String
        /// Copying and recovery are for the one switcher process that holds the AutomationLock.
        /// The app sets this from its own lock.
        public var holdsAutomationLock: Bool
        /// Without the lock: whether that is because its file could not be opened or locked at
        /// all, rather than because another switcher holds it. Only changes what a refusal says.
        public var lockFileUnavailable = false
        /// `~/.config/claude-switcher/copies`: the journal of copies in flight, in the switcher's
        /// own directory, never in Claude's.
        public var journalDirectory: URL
        public var now: @Sendable () -> Date
        /// The new session's id. Lowercased wherever it is used.
        public var newID: @Sendable () -> UUID
        /// The user every folder and file the copy touches must belong to.
        public var expectedUID: uid_t
        /// Whether a registered Claude process is still alive and still the one that registered.
        public var isAlive: @Sendable (_ pid: Int32, _ procStart: String?) -> Bool
        /// Bytes free on the volume of a held directory; `nil` when it cannot be told.
        public var freeBytes: @Sendable (_ directoryDescriptor: Int32) -> UInt64?
        /// `renameatx_np(…, RENAME_EXCL)`: returns 0 or an errno. There is no fallback to `rename()`.
        public var renameExclusive: @Sendable (_ fromDirectory: Int32, _ from: String, _ toDirectory: Int32, _ to: String) -> Int32
        /// The wait between snapshot attempts while the source is being written.
        public var pause: @Sendable (_ seconds: Double) -> Void
        /// Called after each step; a test throws here to simulate a crash, or changes the tree.
        public var hook: @Sendable (_ step: Step) throws -> Void
        /// Told of every flush, exclusive create and rename a copy or recovery makes, in order,
        /// so a test can check the order the power-loss story rests on. A non-zero return fails
        /// that flush with the errno; for a create or a rename it is ignored.
        var fileEvent: @Sendable (_ event: FileEvent) -> Int32 = { _ in 0 }
        /// Whether two held folders are on one volume, where one `F_FULLFSYNC` covers both.
        /// Tests stand in two volumes.
        var sameVolume: @Sendable (_ first: FileStatus, _ second: FileStatus) -> Bool = { $0.device == $1.device }
        /// The exclusive rename that puts a first journal in place, in the switcher's own folder —
        /// apart from ``renameExclusive``, which stands in for Claude's volume. Tests stand in a
        /// journal folder without `RENAME_EXCL`.
        var journalRenameExclusive: ExclusiveRename = ExclusiveRenaming.live

        public init(
            home: String,
            holdsAutomationLock: Bool = false,
            journalDirectory: URL? = nil,
            now: @escaping @Sendable () -> Date = { Date() },
            newID: @escaping @Sendable () -> UUID = { UUID() },
            expectedUID: uid_t = getuid(),
            isAlive: @escaping @Sendable (_ pid: Int32, _ procStart: String?) -> Bool = RunningSessions.isProcessAlive,
            freeBytes: @escaping @Sendable (_ directoryDescriptor: Int32) -> UInt64? = Environment.volumeFreeBytes,
            renameExclusive: @escaping @Sendable (_ fromDirectory: Int32, _ from: String, _ toDirectory: Int32, _ to: String) -> Int32
                = Environment.renameExclusively,
            pause: @escaping @Sendable (_ seconds: Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
            hook: @escaping @Sendable (_ step: Step) throws -> Void = { _ in }
        ) {
            self.home = home
            self.holdsAutomationLock = holdsAutomationLock
            self.journalDirectory = journalDirectory ?? URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".config/claude-switcher/copies", isDirectory: true)
            self.now = now
            self.newID = newID
            self.expectedUID = expectedUID
            self.isAlive = isAlive
            self.freeBytes = freeBytes
            self.renameExclusive = renameExclusive
            self.pause = pause
            self.hook = hook
        }

        /// `fstatfs`: bytes available to the user on the volume of a held directory.
        public static func volumeFreeBytes(_ directoryDescriptor: Int32) -> UInt64? {
            HeldDirectory.freeBytes(onVolumeOf: directoryDescriptor)
        }

        /// `renameatx_np(…, RENAME_EXCL)`, returning 0 or the errno.
        public static func renameExclusively(_ fromDirectory: Int32, _ from: String, _ toDirectory: Int32, _ to: String) -> Int32 {
            ExclusiveRenaming.live(fromDirectory, from, toDirectory, to)
        }

        /// The real home, clock, ids, process table and volume. Holds no lock until the app says so.
        public static var live: Environment {
            Environment(
                home: NSHomeDirectory(),
                journalDirectory: Config.configURL.deletingLastPathComponent()
                    .appendingPathComponent("copies", isDirectory: true))
        }
    }

    /// The points of a copy a test can stop at or act between, in order. A hook that throws
    /// stops the copy right there, as a crash would: nothing is cleaned up, and recovery is
    /// what finishes or removes what is left.
    public enum Step: Hashable, Sendable {
        /// Both profiles resolved, the project folder and the target store not yet walked.
        case resolved
        /// The fresh record passed every check; the project folder is held.
        case preflightPassed
        /// The new id is chosen and proven unused everywhere.
        case idChosen
        case journalCreated
        /// Between reading the source and re-checking it was not touched meanwhile.
        case snapshotRead(attempt: Int)
        /// The snapshot is scanned and the referenced subagent transcripts are found.
        case scanned
        /// The staged transcript is written and flushed, not yet checked.
        case transcriptWritten
        case transcriptStaged
        /// The staging folder is made, before it is reopened and journalled.
        case stagingFolderCreated
        /// One staged subagent transcript is written and flushed, not yet checked.
        case agentWritten
        /// Reached whether or not there were any.
        case subagentsStaged
        /// The record is written, not yet read back.
        case recordStaged
        case journalStaged
        case rechecked
        /// `<Y>.jsonl` is in place: from here on nothing is undone.
        case transcriptCommitted
        /// Only when the copy has subagent transcripts.
        case directoryCommitted
        case recordCommitted
    }

    // MARK: - What the UI passes and gets back

    public struct Request: Equatable, Sendable {
        public let source: Profile
        public let target: Profile
        public let sessionID: String                 // "local_<uuid>" as listed
        public let cliSessionId: String              // as listed — a stale row is refused
        public let cwd: String                       // as listed

        public init(source: Profile, target: Profile, sessionID: String, cliSessionId: String, cwd: String) {
            self.source = source
            self.target = target
            self.sessionID = sessionID
            self.cliSessionId = cliSessionId
            self.cwd = cwd
        }
    }

    /// Every reason a copy is not made. `message` is one plain sentence for an alert or tooltip,
    /// naming accounts by the labels passed in and never containing an id or a path except the
    /// session's own working folder.
    public enum Refusal: Error, Equatable, Sendable {
        // Who may copy, and when
        case notAutomationLockHolder
        /// The lock's file in the switcher's own folder could not be opened or locked at all.
        case lockFileUnavailable
        case anotherCopyRunning
        // The session picked
        case sessionChanged
        case sessionDeleted
        case archived
        case noTranscriptYet
        case transcriptMissing
        case transcriptEmpty
        case stillBeingWritten
        case stillReplying
        case remote
        case workingFolderNotAbsolute
        /// The working folder is not there, or something that is not a folder is.
        case workingFolderMissing(cwd: String)
        /// The working folder could not be looked at (no permission on a folder above it, say).
        case workingFolderUnreachable(cwd: String)
        /// The title or the working folder contains the session's own id, which the copy's
        /// record must never carry.
        case mentionsOwnID
        case inWorktree
        case inScratchWorkspace
        case originFolderDiffers
        case severalTranscripts
        case claimedByTwoAccounts
        // What its transcript carries
        case watchingArtifactComments
        case remoteControlUnclearable
        case unreadableTranscriptLine
        // Room
        case notEnoughSpace
        // The other profile
        case sameProfile
        case sameAccount(source: String, target: String)
        case targetSignedOut(target: String)
        case targetNeverSignedIn(target: String)
        case targetHasNoSessions(target: String)
        case targetSeveralOrganisations(target: String)
        case targetOrganisationHasNoSessions(target: String)
        case targetUnreadable(target: String)
        case targetChanged(target: String)
        /// On the way to the target's data folder, from the home directory: a symbolic link,
        /// or something that is not a folder.
        case targetFolderIsLink(target: String)
        /// The target's data folder, or one on the way to it, belongs to another user.
        case targetFolderNotYours(target: String)
        /// The target's session folder can be changed by other users.
        case targetFolderWritableByOthers(target: String)
        // The new names
        case nameTaken
        case storeUnreadable
        // The file system — on the session's side
        case linkInPath
        case notPlainFile
        case notOwnedByYou
        case writableByOthers
        case renameUnsupported
        /// The switcher's own folder, where the journal goes, cannot rename exclusively.
        case journalFolderCannotRename
        case recordCheckFailed
        case fileSystem(errno: Int32)

        public var message: String {
            switch self {
            case .notAutomationLockHolder:
                return "Another Claude Switcher is running; copy sessions from that one."
            case .lockFileUnavailable:
                return "Claude Switcher could not take its lock file in ~/.config/claude-switcher, so it won\u{2019}t copy sessions."
            case .anotherCopyRunning:
                return "Another copy is still in progress; try again when it has finished."
            case .sessionChanged:
                return "This session changed since the list was read; open the menu again and retry."
            case .sessionDeleted:
                return "Claude has marked this session as deleted, so it cannot be copied."
            case .archived:
                return "This session is archived; unarchive it in Claude to copy it."
            case .noTranscriptYet:
                return "This session has no conversation yet; send it a message first."
            case .transcriptMissing:
                return "This session\u{2019}s conversation file is not where Claude keeps it."
            case .transcriptEmpty:
                return "This session\u{2019}s conversation file has no complete message yet."
            case .stillBeingWritten:
                return "This session is still being written; copy it once Claude has finished replying."
            case .stillReplying:
                return "Claude is still replying in this session; try again when it is done."
            case .remote:
                return "This session runs on another machine, so its files are not on this Mac."
            case .workingFolderNotAbsolute:
                return "This session\u{2019}s working folder is not recorded as a full path."
            case .workingFolderMissing(let cwd):
                return "This session\u{2019}s folder (\(cwd)) no longer exists."
            case .workingFolderUnreachable(let cwd):
                return "Claude Switcher cannot look at this session\u{2019}s folder (\(cwd))."
            case .mentionsOwnID:
                return "This session\u{2019}s title or folder contains its own session id, which a copy\u{2019}s record must not carry; "
                    + "rename the session in Claude to copy it."
            case .inWorktree:
                return "This session works in a git worktree, which a copy would share with the original."
            case .inScratchWorkspace:
                return "This session works in a scratch workspace, which Claude removes along with the session."
            case .originFolderDiffers:
                return "This session has moved away from the folder it started in."
            case .severalTranscripts:
                return "This session spans several conversation files (after a clear, a rewind or an unarchive)."
            case .claimedByTwoAccounts:
                return "This session is already registered in two accounts; deleting it in either would remove it from both."
            case .watchingArtifactComments:
                return "This session is watching an artifact\u{2019}s comments; stop that in the session first."
            case .remoteControlUnclearable:
                return "This session\u{2019}s Remote Control state cannot be cleared safely for a copy."
            case .unreadableTranscriptLine:
                return "Part of this session\u{2019}s conversation file could not be checked, so it is not copied."
            case .notEnoughSpace:
                return "There is not enough free disk space for the copy and 1 GB to spare."
            case .sameProfile:
                return "These two accounts use the same Claude data folder."
            case .sameAccount(let source, let target):
                return "\(source) and \(target) are signed in to the same account."
            case .targetSignedOut(let target):
                return "Claude in \(target) is signed out."
            case .targetNeverSignedIn(let target):
                return "Claude in \(target) has never been signed in."
            case .targetHasNoSessions(let target):
                return "\(target) has no Code sessions yet; start one there first."
            case .targetSeveralOrganisations(let target):
                return "\(target)\u{2019}s account has several organisations, and Claude Switcher cannot tell which is current."
            case .targetOrganisationHasNoSessions(let target):
                return "\(target)\u{2019}s current organisation has no Code sessions yet; start one there first."
            case .targetUnreadable(let target):
                return "Claude Switcher could not read \(target)\u{2019}s Claude settings."
            case .targetChanged(let target):
                return "\(target) changed account or organisation during the copy."
            case .targetFolderIsLink(let target):
                return "\(target)\u{2019}s Claude data folder is reached through a symbolic link, which Claude Switcher does not follow for copies."
            case .targetFolderNotYours(let target):
                return "\(target)\u{2019}s Claude data folder, or a folder on the way to it, belongs to another user."
            case .targetFolderWritableByOthers(let target):
                return "\(target)\u{2019}s Claude session folder can be changed by other users, so Claude Switcher won\u{2019}t file a copy there."
            case .nameTaken:
                return "Something already exists where the copy would go."
            case .storeUnreadable:
                return "Claude Switcher could not check every account\u{2019}s sessions for a clash."
            case .linkInPath:
                return "A folder on the way to the session\u{2019}s files is a symbolic link, which Claude Switcher does not follow."
            case .notPlainFile:
                return "A file the copy needs is not a plain file."
            case .notOwnedByYou:
                return "A folder or file the copy needs belongs to another user."
            case .writableByOthers:
                return "A folder the copy would write into can be changed by other users."
            case .renameUnsupported:
                return "This disk does not support the safe rename a copy relies on."
            case .journalFolderCannotRename:
                return "Claude Switcher\u{2019}s settings folder (~/.config/claude-switcher) is on a disk that cannot rename safely, so it won\u{2019}t copy sessions."
            case .recordCheckFailed:
                return "The copy\u{2019}s record did not come out as intended, so nothing was filed."
            case .fileSystem(let code):
                return "The copy stopped on a file system error: \(String(cString: strerror(code)))."
            }
        }

        /// The refusal a file-system failure amounts to, where the caller has nothing more specific.
        init(_ error: Error) {
            guard let error = error as? FileSystemError else {
                self = .fileSystem(errno: EIO)
                return
            }
            switch error.reason {
            case .linkOrNotDirectory: self = .linkInPath
            case .notRegularFile: self = .notPlainFile
            case .notOwnedByUser: self = .notOwnedByYou
            case .writableByOthers: self = .writableByOthers
            case .exists: self = .nameTaken
            case .renameUnsupported: self = .renameUnsupported
            case .invalidName: self = .fileSystem(errno: EINVAL)
            case .absent: self = .fileSystem(errno: ENOENT)
            case .shortTransfer: self = .fileSystem(errno: error.code == 0 ? EIO : error.code)
            case .system: self = .fileSystem(errno: error.code == 0 ? EIO : error.code)
            }
        }

        /// The refusal a failure on the way to the *target's* folders amounts to: it names that
        /// account and its folder, and never blames the session's files.
        static func target(_ error: Error, label: String) -> Refusal {
            switch (error as? FileSystemError)?.reason {
            case .linkOrNotDirectory?: return .targetFolderIsLink(target: label)
            case .notOwnedByUser?: return .targetFolderNotYours(target: label)
            case .writableByOthers?: return .targetFolderWritableByOthers(target: label)
            default: return .targetUnreadable(target: label)
            }
        }
    }

    public struct Success: Equatable, Sendable {
        public let newSessionID: String              // "local_<Y>"
        public let title: String?                    // the copy's title, if it has one
        public let copiedSubagentTranscripts: Int
        public let skippedSubagentTranscripts: Int
        public let transcriptBytes: Int

        public init(newSessionID: String, title: String?, copiedSubagentTranscripts: Int,
                    skippedSubagentTranscripts: Int, transcriptBytes: Int) {
            self.newSessionID = newSessionID
            self.title = title
            self.copiedSubagentTranscripts = copiedSubagentTranscripts
            self.skippedSubagentTranscripts = skippedSubagentTranscripts
            self.transcriptBytes = transcriptBytes
        }
    }

    public enum Outcome: Equatable, Sendable {
        case copied(Success)
        /// Nothing was put in place. Everything this copy staged was removed — unless a staged
        /// object could no longer be proven to be the one it created: then the staging and its
        /// journal are left as they are, and the next ``SessionCopy/recover(allProfiles:environment:)``
        /// reports it. Call `recover` after any refusal and show its notes.
        case refused(Refusal)
        /// The transcript is committed but registration did not finish; recovery completes it.
        case pendingRegistration(newSessionID: String, detail: String)
    }

    public struct RecoveryNote: Equatable, Sendable {
        /// What recovery did about one copy.
        public enum Kind: Equatable, Sendable {
            /// Put in place; it appears the next time the target's Claude starts.
            case finished
            /// Its partial files were removed; nothing was copied.
            case cleanedUp
            /// Another account had registered the transcript; no second record was filed.
            case registeredElsewhere
            /// On disk, not registered: the target no longer qualifies. Tried again at each start.
            case waiting
            /// Files it could not prove its own were left as they are, with the journal.
            case leftInPlace
            /// It could not check, and changed nothing. Tried again at each start.
            case cannotCheck
            /// A journal it could not read; nothing was changed.
            case journalUnreadable
        }

        public let message: String
        public let kind: Kind
        /// `local_<Y>` of the copy the note is about, so the app can tell its own copy's note
        /// from others'. Never shown; `nil` when the journal could not be read.
        public let copyID: String?

        public init(message: String, kind: Kind, copyID: String?) {
            self.message = message
            self.kind = kind
            self.copyID = copyID
        }

        /// Something is still left to do or to look at: the journal is kept.
        public var needsAttention: Bool {
            switch kind {
            case .finished, .cleanedUp, .registeredElsewhere: return false
            case .waiting, .leftInPlace, .cannotCheck, .journalUnreadable: return true
            }
        }
    }

    /// A copy whose journal is still there and that is not committed: staged files may be in
    /// Claude's folders under `.claude-switcher-*` names. Read-only; no path, id or title.
    public struct Unfinished: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// Pieces may be staged; nothing is in place yet.
            case staging
            /// Everything was staged; the transcript may be in place, the record not yet.
            case staged
            /// A journal file that could not be read, or says something recovery won't act on.
            case unreadable
        }

        /// The account the copy was for; `nil` when the journal could not be read.
        public let targetLabel: String?
        public let state: State
        /// When its journal was last written.
        public let since: Date?

        public init(targetLabel: String?, state: State, since: Date?) {
            self.targetLabel = targetLabel
            self.state = state
            self.since = since
        }
    }

    /// Copies that are committed but that the target's Claude has not opened yet.
    public struct Pending: Equatable, Sendable, Identifiable {
        public let id: String                        // "local_<Y>"
        public let title: String?
        public let targetStore: URL                  // the store folder it was filed in
        public let copiedAt: Date

        public init(id: String, title: String?, targetStore: URL, copiedAt: Date) {
            self.id = id
            self.title = title
            self.targetStore = targetStore
            self.copiedAt = copiedAt
        }
    }

    // MARK: - Copying

    /// Runs recovery first, then the copy. Blocking; call off the main thread.
    ///
    /// One at a time, and only in the switcher that holds the AutomationLock: a second copy, or
    /// a recovery in another process, could otherwise act on this one's half-made files. A
    /// recovery pass running in this process is waited for; only another copy refuses.
    public static func copy(_ request: Request, allProfiles: [Profile], environment: Environment = .live) -> Outcome {
        guard environment.holdsAutomationLock else {
            return .refused(environment.lockFileUnavailable ? .lockFileUnavailable : .notAutomationLockHolder)
        }
        guard CopyGate.shared.enter(.copy) else { return .refused(.anotherCopyRunning) }
        defer { CopyGate.shared.leave() }
        // Notes from this pass are not returned: what it leaves unfinished is listed by
        // ``unfinished(environment:)``, and what it finished by the menu's pending line.
        _ = CopyRecovery(profiles: allProfiles, environment: environment).run()
        return CopyRun(request: request, profiles: allProfiles, environment: environment).perform()
    }

    /// Finishes or cleans up interrupted copies. Does nothing without the automation lock.
    /// While a copy or another recovery runs in this process, it waits for it to finish and
    /// then runs — so with the lock, `[]` always means there was nothing to say. Blocking;
    /// call off the main thread.
    @discardableResult
    public static func recover(allProfiles: [Profile], environment: Environment = .live) -> [RecoveryNote] {
        guard environment.holdsAutomationLock else { return [] }
        _ = CopyGate.shared.enter(.recovery)
        defer { CopyGate.shared.leave() }
        return CopyRecovery(profiles: allProfiles, environment: environment).run()
    }

    /// Copies whose journal is still there and that are not committed — interrupted, refused
    /// with something left that could not be proven, or waiting for their target. Read-only:
    /// it reads the switcher's own journal folder and nothing in Claude's, and takes no gate.
    /// Blocking file I/O; call off the main thread.
    public static func unfinished(environment: Environment = .live) -> [Unfinished] {
        CopyRecovery.unfinished(environment: environment)
    }

    /// A session-store folder that cannot be read, which refuses every copy (a copy's new id
    /// must be proven unused in every store on the Mac). Its path is for Diagnostics only.
    public struct UnreadableStore: Error, Equatable, Sendable {
        public let path: String
    }

    /// Reads every store a copy's survey reads — each configured account's and every
    /// `~/Library/Application Support/Claude*` folder's — and returns the first that cannot
    /// be read, or `nil`. Read-only. Blocking file I/O; call off the main thread.
    public static func unreadableStore(allProfiles: [Profile], environment: Environment = .live) -> UnreadableStore? {
        do {
            _ = try StoreSurvey.read(profiles: allProfiles, home: environment.home)
            return nil
        } catch let error as UnreadableStore {
            return error
        } catch {
            return UnreadableStore(path: PathNormalizer.normalize("Library/Application Support", home: environment.home))
        }
    }

    /// Copies that are committed but that the target's Claude has not opened yet: their record
    /// is still in place with exactly the bytes written. Newest first. Read-only — recovery
    /// is what forgets the ones Claude has since opened.
    ///
    /// Blocking file I/O — the journal folder, and a walk to and a read of each committed
    /// copy's record. Call it off the main thread, never from menu-building code.
    public static func pending(environment: Environment = .live) -> [Pending] {
        CopyRecovery.pending(environment: environment)
    }

    // MARK: - Cheap preflight

    /// Room a copy must leave on the volume.
    static let freeSpaceMargin: UInt64 = 1 << 30

    /// Whether `session` could be copied into `target` right now — the read-only part of
    /// preflight that does not read the transcript, for enabling menu rows. `nil` means "offer
    /// it"; `copy` re-checks everything.
    ///
    /// Blocking file I/O, about half a millisecond a call: each call resolves both profiles
    /// again (both `config.json` files, two folder walks, the volume's free space). Call it off
    /// the main thread, once per (row, target) in the listing pass, and keep the answers —
    /// never from menu-building code.
    public static func obstacle(for session: ListedSession, from source: Profile, to target: Profile,
                                allProfiles: [Profile], environment: Environment = .live) -> Refusal? {
        if let obstacle = session.obstacle { return obstacle }
        guard environment.holdsAutomationLock else {
            return environment.lockFileUnavailable ? .lockFileUnavailable : .notAutomationLockHolder
        }
        if case .failure(let refusal) = resolvePair(source: source, target: target, environment: environment) {
            return refusal
        }
        switch ProjectFolders.open(slug: TranscriptLocator.projectSlug(forCwd: session.record.cwd),
                                   home: environment.home, expectedOwner: environment.expectedUID) {
        case .failure(let refusal):
            return refusal
        case .success(let projectDirectory):
            // The transcript only; the copy adds its subagent transcripts once it has read which.
            guard let free = environment.freeBytes(projectDirectory.descriptor),
                  free >= UInt64(max(session.transcriptBytes, 0)) + freeSpaceMargin
            else { return .notEnoughSpace }
        }
        return nil
    }

    // MARK: - Shared by the cheap preflight and the copy

    /// The two ends of a copy, held open.
    struct ResolvedPair {
        /// Read by the listing rule — the folder whose sessions the menu showed. Never written.
        let sourceFolder: SessionStoreFolder
        let sourceStore: HeldDirectory
        /// Walked to by the strict rule, every folder the user's and nothing a link.
        let target: SessionStore.ResolvedTarget
    }

    /// Resolves both profiles and refuses a pair that is really one profile or one account.
    ///
    /// Folders are compared by identity, never by path: the data volume ignores case, so
    /// `…/Claude-work` and `…/claude-WORK` are one folder, and so are a folder and a link to it.
    static func resolvePair(source: Profile, target: Profile, environment: Environment) -> Result<ResolvedPair, Refusal> {
        guard source.id != target.id else { return .failure(.sameProfile) }
        let home = environment.home
        let sourceRoot = SessionStore.userDataDirectory(source.userDataDir, home: home)
        let targetRoot = SessionStore.userDataDirectory(target.userDataDir, home: home)
        guard let sourceUserData = try? HeldDirectory.openAnchor(sourceRoot.path, expectedOwner: nil) else {
            return .failure(.sessionChanged)
        }
        if let targetUserData = try? HeldDirectory.openAnchor(targetRoot.path, expectedOwner: nil),
           targetUserData.status.identity == sourceUserData.status.identity {
            return .failure(.sameProfile)
        }

        let resolved: SessionStore.ResolvedTarget
        switch SessionStore.locateForCopyTarget(profile: target, home: home, expectedOwner: environment.expectedUID) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found): resolved = found
        }

        // The source store by the listing rule, read through the descriptor just opened.
        guard let sourceFolder = SessionStore.listingLocation(
                  StoreFacts.gather(userData: sourceUserData, url: sourceRoot, strictOwner: nil)).folder,
              let sourceStore = try? sourceUserData
                  .openDirectory(SessionStore.directoryName, expectedOwner: nil)
                  .openDirectory(sourceFolder.accountID, expectedOwner: nil)
                  .openDirectory(sourceFolder.organizationID, expectedOwner: nil)
        else { return .failure(.sessionChanged) }
        if sourceStore.status.identity == resolved.store.status.identity { return .failure(.sameProfile) }
        if SessionStore.sameID(sourceFolder.accountID, resolved.folder.accountID) {
            return .failure(.sameAccount(source: source.label, target: target.label))
        }
        return .success(ResolvedPair(sourceFolder: sourceFolder, sourceStore: sourceStore, target: resolved))
    }

    /// Whether a read of a transcript can be trusted as one moment of it: the descriptor's
    /// `fstat` the same before and after (size, modification and change times), every byte up
    /// to that size read, and the name still on the very file read. Anything rewriting the file
    /// in place, truncating, appending or replacing it during the read fails one of these.
    static func readWasUndisturbed(opened: FileStatus, closed: FileStatus, atName: FileStatus?, bytesRead: Int) -> Bool {
        guard bytesRead == Int(opened.size) else { return false }
        guard closed.size == opened.size, closed.modifiedNanoseconds == opened.modifiedNanoseconds,
              closed.changedNanoseconds == opened.changedNanoseconds, closed.identity == opened.identity
        else { return false }
        guard let atName, atName.kind == .regular, atName.identity == opened.identity else { return false }
        return true
    }

    /// `~/.claude/file-history/<id>` must not exist: Claude Code keeps a session's edit history
    /// there, and a copy must not inherit someone else's.
    static func proveNoFileHistory(for id: String, home: String, owner: uid_t) throws {
        let claude = try HeldDirectory.walk(to: PathNormalizer.normalize(".claude", home: home), home: home, expectedOwner: owner)
        let history: FileStatus
        do {
            history = try claude.status(of: "file-history")
        } catch let error as FileSystemError where error.reason == .absent {
            return
        }
        switch history.kind {
        case .symbolicLink: throw Refusal.linkInPath
        case .directory:
            guard try claude.openDirectory("file-history", expectedOwner: nil).proveAbsent(id) else { throw Refusal.nameTaken }
        case .regular, .other: throw Refusal.nameTaken
        }
    }

    /// `~/.claude/projects/<slug of cwd>`, as an absolute path for the journal.
    static func projectFolderPath(forCwd cwd: String, home: String) -> String {
        TranscriptLocator.projectsDirectory(home: home).appendingPathComponent(TranscriptLocator.projectSlug(forCwd: cwd)).path
    }

    // MARK: - The confirmation

    /// The text of the confirmation, so it is testable and in one place.
    public static func confirmationCaveats(sourceLabel: String, targetLabel: String, cwd: String) -> [String] {
        [
            "This makes an independent copy of the session as it is right now. Later messages in one are not added to the other.",
            "The copy appears in \(targetLabel)\u{2019}s Code tab the next time that Claude starts. Claude Switcher will not quit "
                + "Claude for you. Quit it yourself when its sessions are idle and open it again. Closing the window or "
                + "View > Reload is not enough.",
            "Keep the original in \(sourceLabel) until you have opened the copy in \(targetLabel). Until then nothing renews the "
                + "copy\u{2019}s files, and rewind points from before the copy only carry over if the original still exists when "
                + "the copy is first continued.",
            "Both sessions work in the same folder (\(cwd)). Each can change or undo the other\u{2019}s file edits.",
            "Saved tool outputs and uploads from before the copy still belong to the original, and disappear if the original "
                + "is deleted.",
            "The copy opens in permission mode Default; Claude Code may restore the original\u{2019}s mode on its first start. "
                + "Browser actions ask per site. Connectors, allowed-tool grants and Remote Control are not carried over; "
                + "\(targetLabel)\u{2019}s own connectors apply.",
            "If \(targetLabel)\u{2019}s plan does not include the original\u{2019}s model, the first reply shows a model error; "
                + "choose another with /model. The first reply may be slower than usual.",
            "A copy taken shortly after Claude was working may end mid-turn; that turn shows as interrupted in the copy.",
            "A session Claude has hidden from history stays hidden in the copy.",
        ]
    }
}

// MARK: - Flushes, creates and renames

/// What a copy or recovery does to the drive, as ``SessionCopy/Environment/fileEvent`` is told.
enum FileEvent: Equatable, Sendable {
    /// `fsync`, which on macOS may stop in the drive's cache, or `F_FULLFSYNC`, which does not.
    enum Flush: Equatable, Sendable { case fsync, full }
    /// What was flushed.
    enum Flushed: Equatable, Sendable { case journalFile, journalFolder, transcript, agent, record, projectFolder, store }

    case flush(Flush, Flushed)
    /// An exclusive create of a staging name or a journal's temporary file.
    case created(String)
    case renamed(from: String, to: String)
}

extension SessionCopy.Environment {
    /// Flushes a held file or folder — the one way a copy or recovery does, so the order of
    /// flushes can be tested and a failing one stood in.
    func flush(_ descriptor: Int32, _ kind: FileEvent.Flush, _ what: FileEvent.Flushed) throws {
        var code = fileEvent(.flush(kind, what))
        if code == 0 {
            switch kind {
            case .fsync: if fsync(descriptor) != 0 { code = errno }
            case .full: if fcntl(descriptor, F_FULLFSYNC) != 0 { code = errno }
            }
        }
        guard code == 0 else { throw FileSystemError.errno(code, kind == .full ? "fcntl" : "fsync") }
    }

    /// Reports a create or a rename that has happened.
    func note(_ event: FileEvent) {
        _ = fileEvent(event)
    }
}

/// One copy or recovery at a time in this process. The AutomationLock already makes this
/// process the only one that copies; this keeps a double click from starting a second copy,
/// and a recovery from acting on the half-made files of a copy still running.
///
/// A copy that finds another copy running is refused at once. Anything else waits: a copy for
/// a recovery pass (a few milliseconds of file work) to finish, a recovery for whatever runs.
final class CopyGate: @unchecked Sendable {
    enum Holder: Equatable { case copy, recovery }

    static let shared = CopyGate()
    private let condition = NSCondition()
    private var holder: Holder?

    /// Takes the gate for `kind`. `false` only for a copy while another copy holds it.
    func enter(_ kind: Holder) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while let current = holder {
            if kind == .copy, current == .copy { return false }
            condition.wait()
        }
        holder = kind
        return true
    }

    func leave() {
        condition.lock()
        holder = nil
        condition.broadcast()
        condition.unlock()
    }
}
