import Foundation

/// Sessions started from other sessions, listed the way the Code tab's sidebar nests them.
///
/// Claude Desktop can start a session from inside another one (a side session, or a task the
/// first one proposed). The new session's record names the one it came from in
/// `spawnedFrom.sessionId`, and the sidebar shows it indented under that session. Such a session
/// is a session like any other — its own transcript, its own record — so only the order and the
/// indentation change here, and a copy carries no link (see ``CopyRecord``).
public enum SessionFamilies {

    /// The session a listed session was started from.
    public struct Parent: Equatable, Sendable {
        /// `local_<uuid>`.
        public let id: String
        public let title: String?
        /// It is listed too, right above its sessions; otherwise it is archived or has no
        /// transcript on this Mac, and the session is listed at the top level.
        public let isListed: Bool
        public let isArchived: Bool

        public init(id: String, title: String?, isListed: Bool, isArchived: Bool) {
            self.id = id
            self.title = title
            self.isListed = isListed
            self.isArchived = isArchived
        }
    }

    /// Orders `sessions` (newest activity first) into families: each session is followed by
    /// the listed sessions started from it, one level deeper, and so on. A family sits where
    /// its newest member's activity puts it, so a busy session never hides below an idle one
    /// that started it; sessions of one parent keep that order among themselves. A session
    /// whose parent is not listed stays at the top level; a loop of parents (which Claude would
    /// not write) is broken by listing its members at the top level. Every session appears once.
    ///
    /// `allRecords` is every record in the store, archived ones included, to name a parent
    /// that is not listed.
    public static func arrange(_ sessions: [ListedSession], allRecords: [SessionRecord]) -> [ListedSession] {
        // Ids are compared without regard to case, as everywhere else in the store.
        let listed = Dictionary(sessions.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let records = Dictionary(allRecords.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        var parentOf: [String: String] = [:]
        for session in sessions {
            if let parent = session.record.spawnedFromSessionId?.lowercased(), parent != session.id.lowercased(), listed[parent] != nil {
                parentOf[session.id.lowercased()] = parent
            }
        }
        // Every session on a loop of parents is put at the top level.
        let ids = sessions.map { $0.id.lowercased() }
        for id in ids {
            var path: [String] = [id]
            while let next = parentOf[path[path.count - 1]] {
                if let start = path.firstIndex(of: next) {
                    for member in path[start...] { parentOf[member] = nil }
                    break
                }
                path.append(next)
            }
        }

        var children: [String: [String]] = [:]
        for id in ids {
            if let parent = parentOf[id] { children[parent, default: []].append(id) }
        }

        let position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var newest: [String: Date] = [:]
        func newestActivity(_ id: String) -> Date {
            if let known = newest[id] { return known }
            var latest = listed[id]?.record.lastActivityAt ?? .distantPast
            for child in children[id] ?? [] { latest = max(latest, newestActivity(child)) }
            newest[id] = latest
            return latest
        }
        func ordered(_ ids: [String]) -> [String] {
            let keyed: [(id: String, latest: Date, position: Int)] = ids.map { ($0, newestActivity($0), position[$0] ?? 0) }
            let sorted = keyed.sorted { left, right in
                if left.latest != right.latest { return left.latest > right.latest }
                return left.position < right.position
            }
            return sorted.map(\.id)
        }

        var result: [ListedSession] = []
        result.reserveCapacity(sessions.count)
        func append(_ id: String, depth: Int) {
            guard var session = listed[id] else { return }
            session.depth = depth
            session.startedCount = children[id]?.count ?? 0
            session.startedFrom = parent(of: session.record, isListed: { listed[$0] != nil }, records: records)
            result.append(session)
            for child in ordered(children[id] ?? []) { append(child, depth: depth + 1) }
        }
        for root in ordered(ids.filter { parentOf[$0] == nil }) { append(root, depth: 0) }
        return result
    }

    private static func parent(of record: SessionRecord, isListed: (String) -> Bool, records: [String: SessionRecord]) -> Parent? {
        guard let id = record.spawnedFromSessionId?.lowercased(), id != record.id.lowercased(),
              let parent = records[id]
        else { return nil }
        return Parent(id: parent.id, title: parent.title, isListed: isListed(id), isArchived: parent.isArchived)
    }
}

// MARK: - Copying a session with the sessions started from it

extension SessionListing {
    /// The listed sessions started from the one at `index`, at any depth: the rows right after
    /// it that are deeper than it. Empty for a session nothing was started from.
    public func descendants(ofSessionAt index: Int) -> ArraySlice<ListedSession> {
        guard sessions.indices.contains(index) else { return [] }
        let depth = sessions[index].depth
        var end = index + 1
        while end < sessions.count, sessions[end].depth > depth { end += 1 }
        return sessions[(index + 1)..<end]
    }
}

extension SessionFamilies {

    /// What a family copy would take: the session, then each descendant that can be copied,
    /// in listing order (every one after the session it was started from); and each that
    /// cannot, with why.
    public struct CopyPlan: Equatable, Sendable {
        public struct LeftOut: Equatable, Sendable {
            public let session: ListedSession
            public let reason: SessionCopy.Refusal
        }

        public let members: [SessionCopy.FamilyMember]
        public let leftOut: [LeftOut]

        /// How many sessions besides the first would be copied.
        public var startedCount: Int { max(members.count - 1, 0) }
    }

    /// `obstacle` says why one session cannot be copied to the target, or `nil`; a session's own
    /// obstacle is checked first. `nil` when the session itself cannot be copied, has no
    /// transcript id, or was not started from by anything listed.
    public static func copyPlan(for session: ListedSession, descendants: ArraySlice<ListedSession>,
                                obstacle: (ListedSession) -> SessionCopy.Refusal?) -> CopyPlan? {
        guard !descendants.isEmpty, session.obstacle == nil, obstacle(session) == nil,
              let root = member(session, parent: nil)
        else { return nil }
        var members = [root]
        var leftOut: [CopyPlan.LeftOut] = []
        for descendant in descendants {
            if let reason = descendant.obstacle ?? obstacle(descendant) {
                leftOut.append(CopyPlan.LeftOut(session: descendant, reason: reason))
            } else if let member = member(descendant, parent: descendant.startedFrom?.id) {
                members.append(member)
            } else {
                leftOut.append(CopyPlan.LeftOut(session: descendant, reason: .noTranscriptYet))
            }
        }
        return CopyPlan(members: members, leftOut: leftOut)
    }

    private static func member(_ session: ListedSession, parent: String?) -> SessionCopy.FamilyMember? {
        guard let cliSessionId = session.record.cliSessionId else { return nil }
        return SessionCopy.FamilyMember(sessionID: session.id, cliSessionId: cliSessionId,
                                        cwd: session.record.cwd, parentSessionID: parent)
    }
}
