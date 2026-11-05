import XCTest
@testable import ClaudeSwitcherCore

/// Sessions started from other sessions are listed under them, as the Code tab's sidebar nests them.
final class SessionFamiliesTests: XCTestCase {

    private func id(_ n: Int) -> String { String(format: "local_%08x-aaaa-4aaa-8aaa-aaaaaaaaaaaa", n) }

    private func record(_ n: Int, at activity: Double, from parent: Int? = nil, archived: Bool = false, title: String? = nil) -> SessionRecord {
        SessionRecord(id: id(n), cliSessionId: nil, title: title ?? "S\(n)", cwd: "/p",
                      lastActivityAt: Date(timeIntervalSince1970: activity), isArchived: archived,
                      spawnedFromSessionId: parent.map(id))
    }

    /// `records` newest first, as the store reads them; the archived ones are not listed.
    private func arrange(_ records: [SessionRecord]) -> [ListedSession] {
        let sorted = records.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
        let listed = sorted.filter { !$0.isArchived }.map {
            ListedSession(record: $0, transcriptBytes: 1, isRunning: false, obstacle: nil)
        }
        return SessionFamilies.arrange(listed, allRecords: sorted)
    }

    private func shape(_ sessions: [ListedSession]) -> [String] {
        sessions.map { String(repeating: "  ", count: $0.depth) + ($0.record.title ?? "") }
    }

    func testSessionsStartedFromAnotherAreListedUnderItNewestFirst() {
        let result = arrange([
            record(1, at: 100),
            record(2, at: 500),
            record(3, at: 300, from: 1),
            record(4, at: 200, from: 1),
            record(5, at: 150),
        ])
        // The family of 1 sits where its newest member (3, at 300) puts it: below 2, above 5,
        // though 1 itself is older than 5.
        XCTAssertEqual(shape(result), ["S2", "S1", "  S3", "  S4", "S5"])
        XCTAssertEqual(result.map(\.startedCount), [0, 2, 0, 0, 0])
        XCTAssertEqual(result[2].startedFrom, SessionFamilies.Parent(id: id(1), title: "S1", isListed: true, isArchived: false))
        XCTAssertNil(result[1].startedFrom)
    }

    func testSessionsStartedFromASessionStartedFromAnotherGoOneLevelDeeper() {
        let result = arrange([
            record(1, at: 100),
            record(2, at: 90, from: 1),
            record(3, at: 400, from: 2),
            record(4, at: 300),
        ])
        XCTAssertEqual(shape(result), ["S1", "  S2", "    S3", "S4"])
        XCTAssertEqual(result.map(\.startedCount), [1, 1, 0, 0])
    }

    func testASessionWhoseParentIsArchivedOrGoneIsListedAtTheTopLevelAndSaysSo() {
        let result = arrange([
            record(1, at: 100, archived: true, title: "Old plan"),
            record(2, at: 300, from: 1),
            record(3, at: 200, from: 99),
        ])
        XCTAssertEqual(shape(result), ["S2", "S3"])
        XCTAssertEqual(result[0].startedFrom, SessionFamilies.Parent(id: id(1), title: "Old plan", isListed: false, isArchived: true))
        XCTAssertNil(result[1].startedFrom, "a parent with no record in this store is not named")
    }

    func testALoopOfParentsOrASessionNamingItselfListsEverySessionOnce() {
        let result = arrange([
            record(1, at: 300, from: 2),
            record(2, at: 200, from: 1),
            record(3, at: 100, from: 3),
            record(4, at: 50, from: 2),
        ])
        XCTAssertEqual(Set(result.map(\.id)), Set([1, 2, 3, 4].map(id)))
        XCTAssertEqual(result.count, 4)
        // 1 and 2 name each other: both at the top level; 4, started from 2, stays under it.
        XCTAssertEqual(shape(result), ["S1", "S2", "  S4", "S3"])
        XCTAssertNil(result[3].startedFrom, "a session naming itself names no parent")
    }

    /// Ties included: the store's own order (newest first, then by id) is kept as it is.
    func testWithoutAnyLinksTheOrderIsUnchanged() {
        let listed = (1...30).map { n in
            ListedSession(record: record(n, at: Double(1000 - n / 3)), transcriptBytes: 1, isRunning: false, obstacle: nil)
        }
        let result = SessionFamilies.arrange(listed, allRecords: listed.map(\.record))
        XCTAssertEqual(result.map(\.id), listed.map(\.id))
        XCTAssertEqual(result, listed)
    }

    func testAParentIdInAnotherCaseStillNamesTheParent() {
        let child = SessionRecord(id: id(2), cliSessionId: nil, title: "S2", cwd: "/p",
                                  lastActivityAt: Date(timeIntervalSince1970: 50), spawnedFromSessionId: id(1).uppercased()
                                      .replacingOccurrences(of: "LOCAL_", with: "local_"))
        let result = arrange([record(1, at: 100), child])
        XCTAssertEqual(shape(result), ["S1", "  S2"])
        XCTAssertEqual(result[1].startedFrom?.id, id(1))
    }

    /// The cut never leaves a session without the sessions started from it, and what it leaves
    /// out are whole families.
    func testTheVisibleRowsEndAtTheEndOfAFamily() {
        let sessions = arrange([
            record(1, at: 500),
            record(2, at: 400),
            record(3, at: 390, from: 2),
            record(4, at: 380, from: 3),
            record(5, at: 300),
        ])
        let listing = SessionListing(location: .none, sessions: sessions, hidden: .init())
        XCTAssertEqual(shape(sessions), ["S1", "S2", "  S3", "    S4", "S5"])
        XCTAssertEqual([0, 1, 2, 3, 4, 5, 9, -1].map { listing.visibleCount(limit: $0) }, [0, 1, 4, 4, 4, 5, 5, 0])
    }

    func testAFamilyCopyTakesEveryDescendantThatCanBeCopiedAndSaysWhyNotForTheRest() {
        let sessions = arrange([
            record(1, at: 500),
            record(2, at: 400, from: 1),
            record(3, at: 390, from: 2),
            record(4, at: 380, from: 1),
            record(5, at: 300),
        ]).map { session in
            ListedSession(record: SessionRecord(id: session.record.id, cliSessionId: "c-\(session.id)", title: session.record.title,
                                                cwd: "/p", lastActivityAt: session.record.lastActivityAt,
                                                spawnedFromSessionId: session.record.spawnedFromSessionId),
                          transcriptBytes: 1, isRunning: false, obstacle: nil,
                          depth: session.depth, startedFrom: session.startedFrom, startedCount: session.startedCount)
        }
        let listing = SessionListing(location: .none, sessions: sessions, hidden: .init())
        XCTAssertEqual(listing.descendants(ofSessionAt: 0).map(\.id), [2, 3, 4].map(id))
        XCTAssertEqual(listing.descendants(ofSessionAt: 1).map(\.id), [id(3)])
        XCTAssertTrue(listing.descendants(ofSessionAt: 4).isEmpty)
        XCTAssertTrue(listing.descendants(ofSessionAt: 9).isEmpty)

        let plan = SessionFamilies.copyPlan(for: sessions[0], descendants: listing.descendants(ofSessionAt: 0)) {
            $0.id == self.id(2) ? .inWorktree : nil
        }
        XCTAssertEqual(plan?.members.map(\.sessionID), [1, 3, 4].map(id))
        XCTAssertEqual(plan?.members.map(\.parentSessionID), [nil, id(2), id(1)])
        XCTAssertEqual(plan?.leftOut.map(\.session.id), [id(2)])
        XCTAssertEqual(plan?.leftOut.map(\.reason), [.inWorktree])
        XCTAssertEqual(plan?.startedCount, 2)

        XCTAssertNil(SessionFamilies.copyPlan(for: sessions[0], descendants: listing.descendants(ofSessionAt: 0)) {
            $0.id == self.id(1) ? .stillReplying : nil
        }, "no family copy when the session itself cannot be copied")
        XCTAssertNil(SessionFamilies.copyPlan(for: sessions[4], descendants: []) { _ in nil })
    }
}
