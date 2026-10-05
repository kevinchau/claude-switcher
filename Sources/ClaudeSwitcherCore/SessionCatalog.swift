import Darwin
import Foundation

// MARK: - A session, as Claude Desktop records it

/// One Code-tab session of one account, read from the record Claude Desktop keeps for it.
///
/// Claude Desktop (as of 2.19675.0) lists the Code tab's sessions from one small JSON file per
/// session inside the profile's own user-data directory, in a folder named after the signed-in
/// account and its organisation. The conversation itself — the transcript — is elsewhere, in
/// the shared `~/.claude/projects`, and the record names it by ``cliSessionId``. That is why
/// every account's transcripts sit side by side on disk while each account lists only its own
/// sessions.
///
/// Everything here only reads. Nothing in a profile's store is ever changed by listing it.
public struct SessionRecord: Equatable, Sendable, Identifiable {
    /// `local_<uuid>` — the record's file name, less `.json`.
    public let id: String
    /// Names the transcript: `~/.claude/projects/<slug of cwd>/<cliSessionId>.jsonl`. A session
    /// that has not had its first turn has none yet.
    public let cliSessionId: String?
    public let title: String?
    /// The folder the session works in, exactly as recorded.
    public let cwd: String
    public let originCwd: String?
    public let createdAt: Date?
    public let lastActivityAt: Date?
    public let isArchived: Bool
    public let model: String?
    public let effort: String?
    public let chromePermissionMode: String?
    /// The session runs somewhere else (SSH or WSL); its files are not on this Mac.
    public let isRemote: Bool
    /// The record ties the session to a git worktree or branch that Claude manages for it
    /// (`worktreePath`, `worktreeName`, `branch`, `sourceBranch`, `worktreeLazy`,
    /// `keptWorktreeLeftover`, `keptDirtyWorktree`). Deleting or archiving such a session
    /// removes the worktree or the branch — which a copy in another account would share.
    public let hasWorktree: Bool
    /// The session has had more than one transcript (after a clear, a rewind or an unarchive);
    /// ``cliSessionId`` names only the latest.
    public let hasEarlierTranscripts: Bool
    /// The earlier transcripts' ids, where the record names them. Deleting the session in
    /// Claude removes these too, so they count as claimed by this record.
    public let earlierCliSessionIds: [String]

    public init(
        id: String, cliSessionId: String?, title: String?, cwd: String, originCwd: String? = nil,
        createdAt: Date? = nil, lastActivityAt: Date? = nil, isArchived: Bool = false,
        model: String? = nil, effort: String? = nil, chromePermissionMode: String? = nil,
        isRemote: Bool = false, hasWorktree: Bool = false, hasEarlierTranscripts: Bool = false,
        earlierCliSessionIds: [String] = []
    ) {
        self.id = id
        self.cliSessionId = cliSessionId
        self.title = title
        self.cwd = cwd
        self.originCwd = originCwd
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.isArchived = isArchived
        self.model = model
        self.effort = effort
        self.chromePermissionMode = chromePermissionMode
        self.isRemote = isRemote
        self.hasWorktree = hasWorktree
        self.hasEarlierTranscripts = hasEarlierTranscripts
        self.earlierCliSessionIds = earlierCliSessionIds
    }

    /// The working folder is inside a Claude Code worktree (`…/.claude/worktrees/…`). Compared
    /// without regard to case: the data volume is case-insensitive.
    public var isInClaudeWorktreeFolder: Bool {
        let components = cwd.split(separator: "/").map { $0.lowercased() }
        return zip(components, components.dropFirst()).contains { $0 == ".claude" && $1 == "worktrees" }
    }

    /// The working folder is inside a Desktop scratch workspace
    /// (`<user-data dir>/scratch-workspaces/…`). Deleting such a session in Claude removes
    /// the folder. Wider than Claude's own pattern on purpose: any `scratch-workspaces` component.
    public var isInScratchWorkspace: Bool {
        cwd.split(separator: "/").contains { $0.lowercased() == "scratch-workspaces" }
    }

    /// Every transcript id this record would have Claude remove if the session were deleted.
    var claimedCliSessionIds: [String] {
        (cliSessionId.map { [$0] } ?? []) + earlierCliSessionIds
    }
}

// MARK: - Where a profile keeps its sessions

/// The one folder a profile's signed-in account keeps its session records in.
public struct SessionStoreFolder: Equatable, Sendable {
    public let url: URL
    public let accountID: String
    public let organizationID: String

    public init(url: URL, accountID: String, organizationID: String) {
        self.url = url
        self.accountID = accountID
        self.organizationID = organizationID
    }
}

public enum SessionStoreLocation: Equatable, Sendable {
    /// No account has ever kept sessions in this profile — never signed in, or never used the Code tab.
    case none
    /// Session folders exist, but none for the account Claude last recorded for the profile:
    /// it is signed in to a different account now. Never shown as this account's sessions.
    case otherAccountOnly
    /// Several account/organisation folders, and nothing singles one out as the current one.
    /// The count is how many there are.
    case ambiguous(Int)
    case folder(SessionStoreFolder)

    public var folder: SessionStoreFolder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }
}

/// Reads a profile's session store. Never writes to it.
public enum SessionStore {

    /// `<user-data dir>/claude-code-sessions/<account uuid>/<organisation uuid>/local_<uuid>.json`
    public static let directoryName = "claude-code-sessions"
    static let configFileName = "config.json"
    static let recordPrefix = "local_"
    static let recordSuffix = ".json"
    /// Claude itself skips a record larger than this.
    static let maxRecordBytes = 10 * 1024 * 1024
    /// Claude's `config.json` also holds an encrypted token cache; it is read only for three keys.
    static let maxConfigBytes = 32 * 1024 * 1024

    /// The user-data directory of a profile. `nil` is the default profile.
    public static func userDataDirectory(_ dir: String?, home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: dir.map { PathNormalizer.normalize($0, home: home) } ?? Config.defaultUserDataDir(home: home))
    }

    /// Finds the folder whose sessions to *show* for a profile (the lenient, listing rule).
    ///
    /// The account Claude last recorded for the profile (`lastKnownAccountUuid` in its
    /// `config.json`) picks the account's folders; one folder is the list. Between several
    /// organisation folders of that account, the organisation Claude last refreshed its
    /// extension allow-list for (`dxt:allowlistLastUpdated:<org>`) decides, if exactly one
    /// matches. Folders that exist only for some other account are
    /// ``SessionStoreLocation/otherAccountOnly``: listing them would put one account's sessions
    /// under another's name. Copying *into* a profile uses a stricter rule.
    public static func locate(userDataDir: String?, home: String = NSHomeDirectory()) -> SessionStoreLocation {
        let root = userDataDirectory(userDataDir, home: home)
        guard let directory = try? HeldDirectory.openAnchor(root.path, expectedOwner: nil) else { return .none }
        return listingLocation(StoreFacts.gather(userData: directory, url: root, strictOwner: nil))
    }

    /// The listing rule, over what the user-data directory says.
    static func listingLocation(_ facts: StoreFacts) -> SessionStoreLocation {
        let candidates = facts.accountID.map { account in facts.folders.filter { sameID($0.accountID, account) } }
            ?? facts.folders
        if candidates.count == 1 { return .folder(candidates[0]) }
        if candidates.count > 1, case .organization(let hint) = facts.organizationHint {
            let matching = candidates.filter { sameID($0.organizationID, hint) }
            if matching.count == 1 { return .folder(matching[0]) }
        }
        if candidates.isEmpty { return facts.accountID != nil && !facts.folders.isEmpty ? .otherAccountOnly : .none }
        return .ambiguous(candidates.count)
    }

    /// Why a profile cannot take a copy (the strict rule). See ``copyTarget(_:)``.
    enum TargetProblem: Error, Equatable, Sendable {
        case signedOut
        case neverSignedIn
        case noFolderForAccount
        case severalOrganisations
        case organisationHasNoFolder
        case unreadable
    }

    /// The copy-target rule, over what the user-data directory says.
    ///
    /// Stricter than the listing: a signed-out profile keeps its old folder, and Claude loads
    /// only the live account's folder, so "the only folder there is" is not good enough. The
    /// profile must be signed in (`windowSizeWasSignedIn`, or — when absent — a recorded
    /// account), the folder must belong to the account Claude last recorded, that account must
    /// have exactly one organisation folder (v1: which organisation is current is held only in
    /// an encrypted cookie), and if Claude has noted an organisation for its extension
    /// allow-list, it must be that folder's.
    static func copyTarget(_ facts: StoreFacts) -> Result<SessionStoreFolder, TargetProblem> {
        guard !facts.isIncomplete else { return .failure(.unreadable) }
        guard let account = facts.accountID else { return .failure(.neverSignedIn) }
        guard facts.isSignedIn else { return .failure(.signedOut) }
        let folders = facts.folders.filter { sameID($0.accountID, account) }
        guard !folders.isEmpty else { return .failure(.noFolderForAccount) }
        guard folders.count == 1 else { return .failure(.severalOrganisations) }
        switch facts.organizationHint {
        case .none: break
        case .organization(let hint): guard sameID(folders[0].organizationID, hint) else { return .failure(.organisationHasNoFolder) }
        case .undetermined: return .failure(.organisationHasNoFolder)
        }
        return .success(folders[0])
    }

    /// A target store, reached by the strict walk and held open.
    struct ResolvedTarget {
        let folder: SessionStoreFolder
        let userData: HeldDirectory
        let store: HeldDirectory
    }

    /// Resolves where a copy into `profile` would be filed: the strict walk from the home
    /// directory to its user-data directory (no link anywhere, every folder the user's), the
    /// copy-target rule, and the store folder held open — the user's, and writable by nobody
    /// else. Run again immediately before the record is committed. A refusal on the way names
    /// the target account (``SessionCopy/Refusal/target(_:label:)``), never the session's files.
    static func locateForCopyTarget(profile: Profile, home: String, expectedOwner: uid_t) -> Result<ResolvedTarget, SessionCopy.Refusal> {
        let root = userDataDirectory(profile.userDataDir, home: home)
        let userData: HeldDirectory
        do {
            userData = try HeldDirectory.walk(to: root.path, home: home, expectedOwner: expectedOwner)
        } catch let error as FileSystemError where error.reason == .absent {
            return .failure(.targetNeverSignedIn(target: profile.label))
        } catch {
            return .failure(.target(error, label: profile.label))
        }

        let facts = StoreFacts.gather(userData: userData, url: root, strictOwner: expectedOwner)
        let folder: SessionStoreFolder
        switch copyTarget(facts) {
        case .success(let found): folder = found
        case .failure(.unreadable):
            return .failure(facts.failure.map { .target($0, label: profile.label) } ?? .targetUnreadable(target: profile.label))
        case .failure(.signedOut): return .failure(.targetSignedOut(target: profile.label))
        case .failure(.neverSignedIn): return .failure(.targetNeverSignedIn(target: profile.label))
        case .failure(.noFolderForAccount): return .failure(.targetHasNoSessions(target: profile.label))
        case .failure(.severalOrganisations): return .failure(.targetSeveralOrganisations(target: profile.label))
        case .failure(.organisationHasNoFolder): return .failure(.targetOrganisationHasNoSessions(target: profile.label))
        }

        do {
            let store = try userData
                .openDirectory(directoryName, expectedOwner: expectedOwner)
                .openDirectory(folder.accountID, expectedOwner: expectedOwner)
                .openDirectory(folder.organizationID, expectedOwner: expectedOwner)
            try store.requireNotWritableByOthers()
            return .success(ResolvedTarget(folder: folder, userData: userData, store: store))
        } catch {
            return .failure(.target(error, label: profile.label))
        }
    }

    // MARK: Records

    /// Every readable record in a folder, newest activity first.
    ///
    /// Tolerant the way Claude's own loader is: a file that is not a regular file, is too
    /// large, does not parse, or does not name itself is skipped, never an error. Records run
    /// to 340 KB, so each is decoded only for the fields used here, and a record whose file
    /// has not changed (same inode, size and times) is not decoded again.
    public static func records(in folder: SessionStoreFolder) -> [SessionRecord] {
        guard let directory = try? HeldDirectory.openAnchor(folder.url.path, expectedOwner: nil),
              let names = try? directory.entries()
        else { return [] }
        var records: [SessionRecord] = []
        for name in names where isRecordFileName(name) {
            guard let status = try? directory.status(of: name) else { continue }
            let key = RecordCache.Key(status: status, name: name)
            if let cached = RecordCache.shared.value(for: key) {
                if let record = cached { records.append(record) }
                continue
            }
            let record = readRecord(named: name, in: directory)
            RecordCache.shared.store(record, for: key)
            if let record { records.append(record) }
        }
        return records.sorted { ($0.lastActivityAt ?? .distantPast, $0.id) > ($1.lastActivityAt ?? .distantPast, $1.id) }
    }

    static func isRecordFileName(_ name: String) -> Bool {
        name.hasPrefix(recordPrefix) && name.hasSuffix(recordSuffix) && name.count > recordPrefix.count + recordSuffix.count
    }

    /// Reads one record through a held store directory, uncached — what a copy's preflight
    /// uses, so it acts on the record as it is now and not as it was listed.
    static func readRecord(named name: String, in directory: HeldDirectory) -> SessionRecord? {
        guard isRecordFileName(name),
              let status = try? directory.status(of: name), status.kind == .regular,
              status.size > 0, status.size <= Int64(maxRecordBytes),
              let file = try? directory.openRegularFile(name),
              let data = try? file.readAll(limit: maxRecordBytes)
        else { return nil }
        return record(from: data, fileStem: String(name.dropLast(recordSuffix.count)))
    }

    /// Decodes one record. `nil` unless it is a session record that names itself the way its
    /// file does — Claude saves and deletes a record by `<sessionId>.json`, so one whose inner
    /// id disagrees with its file name is not something to build on.
    static func record(from data: Data, fileStem: String) -> SessionRecord? {
        guard let fields = try? JSONDecoder().decode(RecordFields.self, from: data),
              let id = fields.sessionId, id == fileStem,
              id.hasPrefix(recordPrefix), isUUID(String(id.dropFirst(recordPrefix.count))),
              let cwd = fields.cwd, !cwd.isEmpty
        else { return nil }

        func date(_ milliseconds: Double?) -> Date? {
            guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        let earlier = (fields.priorCliSessionIds + [fields.unarchivedCliSessionId, fields.preClearCliSessionId].compactMap { $0 })
            .filter(isUUID)

        return SessionRecord(
            id: id,
            cliSessionId: fields.cliSessionId.flatMap { isUUID($0) ? $0 : nil },
            title: fields.title.flatMap { $0.isEmpty ? nil : $0 },
            cwd: cwd,
            originCwd: fields.originCwd.flatMap { $0.isEmpty ? nil : $0 },
            createdAt: date(fields.createdAt),
            lastActivityAt: date(fields.lastActivityAt),
            isArchived: fields.isArchived,
            model: fields.model.flatMap { $0.isEmpty ? nil : $0 },
            effort: fields.effort.flatMap { $0.isEmpty ? nil : $0 },
            chromePermissionMode: fields.chromePermissionMode.flatMap { $0.isEmpty ? nil : $0 },
            isRemote: fields.isRemote,
            hasWorktree: fields.hasWorktree,
            hasEarlierTranscripts: fields.hasEarlierTranscripts,
            earlierCliSessionIds: earlier
        )
    }

    // MARK: Helpers

    /// Which store folders claim each transcript id, across every configured profile.
    ///
    /// A transcript claimed by records in two stores belongs to two accounts at once: deleting
    /// or auto-cleaning it in one removes it from the other. Such a session is never copied.
    /// Folders are told apart by identity, so two profiles spelling one directory differently
    /// count once.
    static func transcriptClaims(profiles: [Profile], home: String) -> [String: Set<FileIdentity>] {
        var claims: [String: Set<FileIdentity>] = [:]
        var seenRoots = Set<FileIdentity>()
        for profile in profiles {
            let root = userDataDirectory(profile.userDataDir, home: home)
            guard let userData = try? HeldDirectory.openAnchor(root.path, expectedOwner: nil),
                  seenRoots.insert(userData.status.identity).inserted
            else { continue }
            let facts = StoreFacts.gather(userData: userData, url: root, strictOwner: nil)
            for folder in facts.folders {
                guard let identity = FileStatus.ofPath(folder.url.path)?.identity else { continue }
                for record in records(in: folder) {
                    for id in record.claimedCliSessionIds { claims[id.lowercased(), default: []].insert(identity) }
                }
            }
        }
        return claims
    }

    static func isUUID(_ string: String) -> Bool {
        string.utf8.count == 36 && UUID(uuidString: string) != nil
    }

    static func sameID(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }
}

// MARK: - What a user-data directory says

/// The few facts about a profile's user-data directory that decide where its sessions are.
struct StoreFacts: Equatable, Sendable {
    enum OrganizationHint: Equatable, Sendable {
        case none
        case organization(String)
        /// Keys exist but the newest cannot be told: a value that is not a date, or a tie
        /// between two organisations. The copy-target rule refuses; the listing ignores it.
        case undetermined
    }

    /// `lastKnownAccountUuid`. Claude sets it whenever the live account changes and never
    /// clears it on sign-out.
    var accountID: String?
    /// `windowSizeWasSignedIn`; when absent, Claude's own startup fallback: an account is recorded.
    var isSignedIn: Bool
    /// The organisation of the newest `dxt:allowlistLastUpdated:<org>` key.
    var organizationHint: OrganizationHint
    /// Every `claude-code-sessions/<account>/<organisation>` folder, sorted.
    var folders: [SessionStoreFolder]
    /// Something that decides the answer could not be read. Only the strict rule cares.
    var isIncomplete: Bool { failure != nil || configUnreadable }
    var configUnreadable: Bool = false
    /// The first file-system refusal met in strict mode.
    var failure: FileSystemError?

    static let organizationKeyPrefix = "dxt:allowlistLastUpdated:"

    /// Reads `config.json` (three keys only) and the store's folder tree through a held
    /// user-data directory. Lenient (`strictOwner == nil`): a link or a non-directory among the
    /// account and organisation folders is simply not a store folder, as in Claude. Strict:
    /// every UUID-named entry must be a real directory owned by `strictOwner`, or the facts are
    /// incomplete — skipping one could turn two organisation folders into one.
    static func gather(userData: HeldDirectory, url: URL, strictOwner: uid_t?) -> StoreFacts {
        var facts = StoreFacts(accountID: nil, isSignedIn: false, organizationHint: .none, folders: [])
        readConfig(in: userData, into: &facts)

        let store: HeldDirectory
        do {
            store = try userData.openDirectory(SessionStore.directoryName, expectedOwner: strictOwner)
        } catch let error as FileSystemError {
            if error.reason != .absent, strictOwner != nil { facts.failure = error }
            return facts
        } catch {
            return facts
        }
        let storeURL = url.appendingPathComponent(SessionStore.directoryName, isDirectory: true)

        func uuidDirectories(in directory: HeldDirectory) -> [(String, HeldDirectory)] {
            let names: [String]
            do { names = try directory.entries() } catch let error as FileSystemError {
                if strictOwner != nil { facts.failure = facts.failure ?? error }
                return []
            } catch { return [] }
            var found: [(String, HeldDirectory)] = []
            for name in names.sorted() where SessionStore.isUUID(name) {
                do {
                    found.append((name, try directory.openDirectory(name, expectedOwner: strictOwner)))
                } catch let error as FileSystemError {
                    if strictOwner != nil { facts.failure = facts.failure ?? error }
                } catch {}
            }
            return found
        }

        for (account, accountDirectory) in uuidDirectories(in: store) {
            for (organization, _) in uuidDirectories(in: accountDirectory) {
                facts.folders.append(SessionStoreFolder(
                    url: storeURL.appendingPathComponent(account, isDirectory: true)
                        .appendingPathComponent(organization, isDirectory: true),
                    accountID: account,
                    organizationID: organization
                ))
            }
        }
        return facts
    }

    private static func readConfig(in userData: HeldDirectory, into facts: inout StoreFacts) {
        let status: FileStatus
        do {
            status = try userData.status(of: SessionStore.configFileName)
        } catch let error as FileSystemError where error.reason == .absent {
            return
        } catch {
            facts.configUnreadable = true
            return
        }
        guard status.kind == .regular,
              let file = try? userData.openRegularFile(SessionStore.configFileName),
              let data = try? file.readAll(limit: SessionStore.maxConfigBytes),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            facts.configUnreadable = true
            return
        }
        apply(config: root, to: &facts)
    }

    /// The three keys, as Claude itself reads them.
    static func apply(config root: [String: Any], to facts: inout StoreFacts) {
        facts.accountID = (root["lastKnownAccountUuid"] as? String).flatMap { SessionStore.isUUID($0) ? $0 : nil }
        // Claude: `typeof e == "boolean" ? e : ko.get("lastKnownAccountUuid") !== void 0`.
        if let flag = root["windowSizeWasSignedIn"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
            facts.isSignedIn = flag.boolValue
        } else {
            facts.isSignedIn = root["lastKnownAccountUuid"] != nil
        }
        facts.organizationHint = organizationHint(in: root)
    }

    /// `^dxt:allowlistLastUpdated:([0-9a-f-]{36})$`, newest ISO-8601 value wins.
    static func organizationHint(in root: [String: Any]) -> OrganizationHint {
        var newest: (date: Date, organizations: Set<String>)?
        for (key, value) in root where key.hasPrefix(organizationKeyPrefix) {
            let organization = String(key.dropFirst(organizationKeyPrefix.count))
            guard organization.utf8.count == 36,
                  organization.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || $0 == 45 })
            else { continue }
            guard let text = value as? String, let date = isoDate(text) else { return .undetermined }
            if newest == nil || date > newest!.date {
                newest = (date, [organization])
            } else if date == newest!.date {
                newest!.organizations.insert(organization)
            }
        }
        guard let newest else { return .none }
        return newest.organizations.count == 1 ? .organization(newest.organizations.first!) : .undetermined
    }

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - Record decoding

/// Only what the menu and the copy's preflight read. The decoder skips everything else in a
/// record without building it, and a field of an unexpected type is treated as absent rather
/// than failing the whole record.
private struct RecordFields: Decodable {
    var sessionId: String?
    var cliSessionId: String?
    var title: String?
    var cwd: String?
    var originCwd: String?
    var createdAt: Double?
    var lastActivityAt: Double?
    var isArchived = false
    var model: String?
    var effort: String?
    var chromePermissionMode: String?
    var isRemote = false
    var hasWorktree = false
    var hasEarlierTranscripts = false
    var priorCliSessionIds: [String] = []
    var unarchivedCliSessionId: String?
    var preClearCliSessionId: String?

    private enum Key: String, CodingKey {
        case sessionId, cliSessionId, title, cwd, originCwd, createdAt, lastActivityAt, isArchived
        case model, effort, chromePermissionMode, sshConfig, wslConfig
        case worktreePath, worktreeName, branch, sourceBranch, worktreeLazy, keptWorktreeLeftover, keptDirtyWorktree
        case priorCliSessionIds, unarchivedCliSessionId, preClearCliSessionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        func string(_ key: Key) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func number(_ key: Key) -> Double? { (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil }
        func truthy(_ key: Key) -> Bool { ((try? container.decodeIfPresent(JSTruthiness.self, forKey: key)) ?? nil)?.value ?? false }

        sessionId = string(.sessionId)
        cliSessionId = string(.cliSessionId)
        title = string(.title)
        cwd = string(.cwd)
        originCwd = string(.originCwd)
        createdAt = number(.createdAt)
        lastActivityAt = number(.lastActivityAt)
        isArchived = truthy(.isArchived)
        model = string(.model)
        effort = string(.effort)
        chromePermissionMode = string(.chromePermissionMode)
        // Claude acts on these by JavaScript truthiness: `""`, `null`, `false` and `0` arm nothing.
        isRemote = truthy(.sshConfig) || truthy(.wslConfig)
        hasWorktree = [.worktreePath, .worktreeName, .branch, .sourceBranch, .worktreeLazy,
                       .keptWorktreeLeftover, .keptDirtyWorktree].contains(where: truthy)
        unarchivedCliSessionId = string(.unarchivedCliSessionId)
        preClearCliSessionId = string(.preClearCliSessionId)
        let prior: [String]? = (try? container.decodeIfPresent([String].self, forKey: .priorCliSessionIds)) ?? nil
        priorCliSessionIds = prior ?? []
        // An empty list names no earlier transcript; anything else that is not a list of ids
        // still says there were some.
        let priorIsSomething = prior.map { !$0.isEmpty } ?? truthy(.priorCliSessionIds)
        hasEarlierTranscripts = priorIsSomething || truthy(.unarchivedCliSessionId) || truthy(.preClearCliSessionId)
    }
}

/// A JSON value's truthiness as JavaScript sees it: `null`, `false`, `0`, `NaN` and `""` are
/// false; every other string, number, array and object is true.
struct JSTruthiness: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = false
        } else if let flag = try? container.decode(Bool.self) {
            value = flag
        } else if let number = try? container.decode(Double.self) {
            value = number != 0 && !number.isNaN
        } else if let text = try? container.decode(String.self) {
            value = !text.isEmpty
        } else {
            value = true
        }
    }
}

/// Decoded records, by file identity and times, so refreshing an unchanged store costs a
/// directory read and one `fstatat` per record.
final class RecordCache: @unchecked Sendable {
    struct Key: Hashable {
        let identity: FileIdentity
        let size: Int64
        let modified: Int64
        let changed: Int64
        let name: String

        init(status: FileStatus, name: String) {
            identity = status.identity
            size = status.size
            modified = status.modifiedNanoseconds
            changed = status.changedNanoseconds
            self.name = name
        }
    }

    static let shared = RecordCache()
    private static let capacity = 8192
    private let lock = NSLock()
    private var entries: [Key: SessionRecord?] = [:]

    /// `.some(nil)` is a file known not to be a record.
    func value(for key: Key) -> SessionRecord?? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func store(_ record: SessionRecord?, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = .some(record)
    }
}

// MARK: - Where a session's transcript is

/// Finds the transcript a record names, in the shared `~/.claude/projects`.
public enum TranscriptLocator {

    /// The shared config directory. Always `~/.claude`: this app never sets or honours a
    /// different `CLAUDE_CONFIG_DIR`.
    public static func projectsDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: PathNormalizer.normalize(".claude/projects", home: home))
    }

    /// Longer slugs are cut here and given a hash suffix.
    static let maximumSlugLength = 200

    /// The project folder's name for a working folder: Desktop's `cliProjectDirSlug`, ported
    /// exactly (main.pretty.js `V5n`, called with "host").
    ///
    /// The raw `cwd` string, NFC-composed — never through ``PathNormalizer``, which would also
    /// collapse `//` and drop a trailing `/` and so name a different folder. Every UTF-16 unit
    /// that is not an ASCII letter or digit becomes `-` (an emoji, two units, becomes `--`).
    /// Above 200 units, the first 200 are kept and `-` plus base 36 of the absolute value of
    /// the string's 31-multiplier hash (over the NFC string, in 32-bit wrapping arithmetic,
    /// as JavaScript's `(h << 5) - h + c | 0`) is appended.
    public static func projectSlug(forCwd cwd: String) -> String {
        let composed = cwd.precomposedStringWithCanonicalMapping
        let units = Array(composed.utf16)
        let dashed = units.map { unit -> UInt8 in
            switch unit {
            case 48...57, 65...90, 97...122: return UInt8(unit)
            default: return UInt8(ascii: "-")
            }
        }
        guard dashed.count > maximumSlugLength else { return String(decoding: dashed, as: UTF8.self) }
        var hash: Int32 = 0
        for unit in units { hash = (hash &<< 5) &- hash &+ Int32(unit) }
        let magnitude = Int64(hash).magnitude
        return String(decoding: dashed.prefix(maximumSlugLength), as: UTF8.self) + "-" + String(magnitude, radix: 36)
    }

    /// Where the transcript of a session with this working folder and id is expected. Only
    /// this exact path is ever considered: a transcript found anywhere else is not one Claude
    /// would open for the record.
    public static func transcriptURL(cwd: String, cliSessionId: String, home: String = NSHomeDirectory()) -> URL {
        projectsDirectory(home: home)
            .appendingPathComponent(projectSlug(forCwd: cwd))
            .appendingPathComponent(cliSessionId + ".jsonl")
    }

    /// `<projDir>/<id>.desktop-released.json`: Claude's note that the transcript is to be reaped.
    static func releaseMarkerName(cliSessionId: String) -> String { cliSessionId + ".desktop-released.json" }
}

// MARK: - What the menu shows

/// What the menu shows for one account. Built off the main thread.
public struct SessionListing: Equatable, Sendable {
    public let location: SessionStoreLocation
    /// Non-archived local sessions with a transcript on disk, newest activity first.
    public let sessions: [ListedSession]
    public let hidden: HiddenCounts

    /// What is not listed, so the menu can say so in one line.
    public struct HiddenCounts: Equatable, Sendable {
        public let archived: Int
        /// No transcript yet, or none at the exact path Claude would open.
        public let withoutTranscript: Int
        public let remote: Int

        public init(archived: Int = 0, withoutTranscript: Int = 0, remote: Int = 0) {
            self.archived = archived
            self.withoutTranscript = withoutTranscript
            self.remote = remote
        }

        public var total: Int { archived + withoutTranscript + remote }
    }

    public init(location: SessionStoreLocation, sessions: [ListedSession], hidden: HiddenCounts) {
        self.location = location
        self.sessions = sessions
        self.hidden = hidden
    }

    /// Reads one profile's sessions. Only reads: the profile's store, the transcripts' folders,
    /// every configured profile's records (for transcripts claimed twice) and the running-session
    /// registry. Blocking; call off the main thread.
    public static func read(profile: Profile, allProfiles: [Profile], environment: SessionCopy.Environment = .live) -> SessionListing {
        let home = environment.home
        let location = SessionStore.locate(userDataDir: profile.userDataDir, home: home)
        guard let folder = location.folder else {
            return SessionListing(location: location, sessions: [], hidden: HiddenCounts())
        }

        let running = RunningSessions.read(home: home, isAlive: environment.isAlive)
        let configured = allProfiles.contains { $0.id == profile.id } ? allProfiles : allProfiles + [profile]
        let claims = SessionStore.transcriptClaims(profiles: configured, home: home)
        let store = try? HeldDirectory.openAnchor(folder.url.path, expectedOwner: nil)
        var projects = ProjectFolders(home: home, expectedOwner: environment.expectedUID)

        var sessions: [ListedSession] = []
        var archived = 0, withoutTranscript = 0, remote = 0
        for record in SessionStore.records(in: folder) {
            if record.isArchived { archived += 1; continue }
            if record.isRemote { remote += 1; continue }
            guard let cliSessionId = record.cliSessionId,
                  let transcript = FileStatus.ofPath(
                      TranscriptLocator.transcriptURL(cwd: record.cwd, cliSessionId: cliSessionId, home: home).path),
                  transcript.kind == .regular
            else { withoutTranscript += 1; continue }

            let obstacle = ListedSession.obstacle(
                for: record, cliSessionId: cliSessionId, running: running,
                claimedBy: claims[cliSessionId.lowercased()]?.count ?? 0,
                store: store, projects: &projects, expectedOwner: environment.expectedUID)
            sessions.append(ListedSession(
                record: record, transcriptBytes: Int(transcript.size),
                isRunning: running.isOpen(record), obstacle: obstacle))
        }
        return SessionListing(
            location: location, sessions: sessions,
            hidden: HiddenCounts(archived: archived, withoutTranscript: withoutTranscript, remote: remote))
    }
}

public struct ListedSession: Equatable, Sendable, Identifiable {
    public let record: SessionRecord
    public var id: String { record.id }
    public let transcriptBytes: Int
    /// The session is open in a running Claude right now (registry entry with a live pid).
    public let isRunning: Bool
    /// Why this session cannot be copied to ANY account, judged without reference to a target
    /// (worktree, several transcripts, folder missing, still replying, registered in two accounts…).
    public let obstacle: SessionCopy.Refusal?

    public init(record: SessionRecord, transcriptBytes: Int, isRunning: Bool, obstacle: SessionCopy.Refusal?) {
        self.record = record
        self.transcriptBytes = transcriptBytes
        self.isRunning = isRunning
        self.obstacle = obstacle
    }

    /// The target-independent part of preflight, cheapest and most fundamental first. The
    /// copy repeats all of it on a fresh read.
    static func obstacle(
        for record: SessionRecord, cliSessionId: String, running: RunningSessions, claimedBy stores: Int,
        store: HeldDirectory?, projects: inout ProjectFolders, expectedOwner: uid_t
    ) -> SessionCopy.Refusal? {
        if record.hasWorktree || record.isInClaudeWorktreeFolder { return .inWorktree }
        if record.isInScratchWorkspace { return .inScratchWorkspace }
        if record.hasEarlierTranscripts { return .severalTranscripts }
        guard record.cwd.hasPrefix("/") else { return .workingFolderNotAbsolute }
        if let origin = record.originCwd, origin != record.cwd { return .originFolderDiffers }
        if stores > 1 { return .claimedByTwoAccounts }
        if mentionsOwnID(record, cliSessionId: cliSessionId) { return .mentionsOwnID }
        if running.isBusy(record) { return .stillReplying }

        // Only "nothing there" is "no longer exists"; a folder that cannot be looked at (no
        // permission on one above it, say) may well exist.
        var folder = stat()
        guard stat(record.cwd, &folder) == 0 else {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? .workingFolderMissing(cwd: record.cwd)
                : .workingFolderUnreachable(cwd: record.cwd)
        }
        guard folder.st_mode & S_IFMT == S_IFDIR else { return .workingFolderMissing(cwd: record.cwd) }

        let projectDirectory: HeldDirectory
        switch projects.folder(forCwd: record.cwd) {
        case .success(let held): projectDirectory = held
        case .failure(let refusal): return refusal
        }
        do {
            let transcript = try projectDirectory.status(of: cliSessionId + ".jsonl")
            if let problem = transcriptProblem(transcript, expectedOwner: expectedOwner) { return problem }
        } catch let error as FileSystemError where error.reason == .absent {
            return .transcriptMissing
        } catch {
            return SessionCopy.Refusal(error)
        }

        // Claude has marked this session for removal: copying it would bring it back.
        guard projectDirectory.proveAbsent(TranscriptLocator.releaseMarkerName(cliSessionId: cliSessionId)) else {
            return .sessionDeleted
        }
        let uuid = String(record.id.dropFirst(SessionStore.recordPrefix.count))
        guard let store else { return .sessionChanged }
        for tombstone in ["deleted_" + cliSessionId, "deleted_" + uuid, "deleted_" + record.id]
        where !store.proveAbsent(tombstone) {
            return .sessionDeleted
        }
        return nil
    }

    /// Whether the title or the working folder — the two of the original's strings a copy's
    /// record carries — contains the session's transcript id, its record id or that id's bare
    /// UUID, in any letter case: the same test the staged record's bytes get
    /// (``CopyRecord/isFree(_:ofSourceCliSessionId:sourceRecordID:)``), made before anything is
    /// staged, so such a session is never offered. The test on the bytes stays the backstop.
    static func mentionsOwnID(_ record: SessionRecord, cliSessionId: String) -> Bool {
        [record.title, record.cwd].compactMap { $0 }.contains {
            !CopyRecord.isFree(Data($0.utf8), ofSourceCliSessionId: cliSessionId, sourceRecordID: record.id)
        }
    }

    /// What a source transcript must be, on what `fstatat`/`fstat` saw: a plain file with one
    /// name (a hard link would make the copy's source someone else's file too), the user's,
    /// and not empty. The copy applies the same test to its descriptor before and after reading.
    static func transcriptProblem(_ status: FileStatus, expectedOwner: uid_t) -> SessionCopy.Refusal? {
        guard status.kind == .regular, status.linkCount == 1 else { return .notPlainFile }
        guard status.owner == expectedOwner else { return .notOwnedByYou }
        guard status.size > 0 else { return .transcriptEmpty }
        return nil
    }
}

/// Project folders reached by the strict walk, for the length of one listing.
///
/// At most one is held at a time: a listing can span hundreds of projects, and a GUI app may
/// have only 256 descriptors. The last one is kept for the next session in the same project;
/// a folder that cannot be used is remembered by slug, as it holds no descriptor.
struct ProjectFolders {
    let home: String
    let expectedOwner: uid_t
    private var failures: [String: SessionCopy.Refusal] = [:]
    private var last: (slug: String, folder: HeldDirectory)?

    init(home: String, expectedOwner: uid_t) {
        self.home = home
        self.expectedOwner = expectedOwner
    }

    /// `~/.claude/projects/<slug>`, walked from the home directory with no link anywhere, every
    /// folder the user's, and the project folder writable by nobody else.
    mutating func folder(forCwd cwd: String) -> Result<HeldDirectory, SessionCopy.Refusal> {
        let slug = TranscriptLocator.projectSlug(forCwd: cwd)
        if let refusal = failures[slug] { return .failure(refusal) }
        if let last, last.slug == slug { return .success(last.folder) }
        last = nil
        let result = Self.open(slug: slug, home: home, expectedOwner: expectedOwner)
        switch result {
        case .success(let folder): last = (slug, folder)
        case .failure(let refusal): failures[slug] = refusal
        }
        return result
    }

    static func open(slug: String, home: String, expectedOwner: uid_t) -> Result<HeldDirectory, SessionCopy.Refusal> {
        do {
            let projects = try HeldDirectory.walk(
                to: TranscriptLocator.projectsDirectory(home: home).path, home: home, expectedOwner: expectedOwner)
            let folder = try projects.openDirectory(slug, expectedOwner: expectedOwner)
            try folder.requireNotWritableByOthers()
            return .success(folder)
        } catch let error as FileSystemError where error.reason == .absent {
            return .failure(.transcriptMissing)
        } catch {
            return .failure(SessionCopy.Refusal(error))
        }
    }
}
