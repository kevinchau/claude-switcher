import XCTest
@testable import ClaudeSwitcherCore

/// `~/.claude.json`'s cached usage body: used for the profile whose account it names, within
/// the CLI's own hour, never written.
final class ExactUsageTests: XCTestCase {

    private func pdt(_ text: String) -> Date { UsageFixtures.pdt(text) }

    private func writeClaudeJSON(_ home: FakeHome, fetchedAt: Date, account: String, tierAccount: String? = nil) throws {
        let body: [String: Any] = [
            "five_hour": ["utilization": 44.0, "resets_at": "2026-10-06T04:10:00.430526+00:00"],
            "seven_day": ["utilization": 58.0, "resets_at": "2026-10-11T04:00:00.430546+00:00"],
            "seven_day_opus": NSNull(),
            "limits": [["kind": "weekly_scoped", "percent": 56]],
        ]
        let root: [String: Any] = [
            "numStartups": 12,
            "oauthAccount": ["accountUuid": tierAccount ?? account, "organizationRateLimitTier": "claude_max_20x"],
            "cachedUsageUtilization": ["fetchedAtMs": fetchedAt.timeIntervalSince1970 * 1000, "accountUuid": account, "utilization": body],
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: home.root.appendingPathComponent(".claude.json"))
    }

    func testFreshCachedBodyIsUsedForItsOwnAccountOnly() throws {
        let f = try ActivityFixture()
        let now = pdt("2026-10-05 18:50")
        try writeClaudeJSON(f.home, fetchedAt: pdt("2026-10-05 18:47"), account: FakeHome.accountA)
        let before = f.home.snapshot()
        let source = ClaudeConfigUsageSource()
        let exact = try XCTUnwrap(source.exact(for: ActivityFixture.personal, home: f.home.home, now: now))
        XCTAssertEqual(exact.rateLimitTier, "claude_max_20x")
        XCTAssertEqual(exact.fetchedAt, pdt("2026-10-05 18:47"))
        XCTAssertEqual(exact.sevenDayUtilization, 58)
        XCTAssertEqual(exact.fiveHourUtilization, 44)
        XCTAssertEqual(exact.anchors.map(\.resetsAt), [pdt("2026-10-10 21:00"), pdt("2026-10-05 21:10")], "rounded to the minute")
        XCTAssertNil(source.exact(for: ActivityFixture.work, home: f.home.home, now: now), "another account's body says nothing about Work")
        XCTAssertEqual(f.home.snapshot(), before, "only read")

        // Its weekly reset anchors the schedule like a limit hit's.
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: [], anchors: exact.anchors, now: now))
        XCTAssertEqual(schedule.next(after: now).by, pdt("2026-10-10 21:00"))
        XCTAssertTrue(schedule.isExact)
        // Its five-hour end is the open window's exact end.
        let window = SessionWindow.infer(from: [], anchors: exact.anchors, activity: nil, now: now)
        XCTAssertEqual(window?.exactEnd, pdt("2026-10-05 21:10"))
    }

    func testStaleBodyGivesNoFiguresButTheTierStays() throws {
        let f = try ActivityFixture()
        try writeClaudeJSON(f.home, fetchedAt: pdt("2026-09-14 10:07"), account: FakeHome.accountA)
        let exact = try XCTUnwrap(ClaudeConfigUsageSource().exact(for: ActivityFixture.personal, home: f.home.home, now: pdt("2026-10-05 18:50")))
        XCTAssertNil(exact.fetchedAt)
        XCTAssertNil(exact.sevenDayUtilization)
        XCTAssertTrue(exact.anchors.isEmpty)
        XCTAssertEqual(exact.rateLimitTier, "claude_max_20x")
        // Just over the CLI's hour is stale too.
        XCTAssertNil(ExactUsage.parse(try Data(contentsOf: f.home.root.appendingPathComponent(".claude.json")), accountID: FakeHome.accountA,
                                      now: pdt("2026-09-14 11:08"))?.fetchedAt)
    }

    func testNothingForAProfileWithoutAMatchingAccountOrFile() throws {
        let f = try ActivityFixture()
        XCTAssertNil(ClaudeConfigUsageSource().exact(for: ActivityFixture.personal, home: f.home.home, now: pdt("2026-10-05 18:50")))
        try writeClaudeJSON(f.home, fetchedAt: pdt("2026-10-05 18:47"), account: FakeHome.accountB, tierAccount: FakeHome.accountB)
        XCTAssertNil(ClaudeConfigUsageSource().exact(for: ActivityFixture.personal, home: f.home.home, now: pdt("2026-10-05 18:50")))
        XCTAssertEqual(ClaudeConfigUsageSource().exact(for: ActivityFixture.work, home: f.home.home, now: pdt("2026-10-05 18:50"))?.sevenDayUtilization, 58)
    }
}
