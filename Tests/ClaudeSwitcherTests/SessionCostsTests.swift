import XCTest
@testable import ClaudeSwitcherCore

/// Short, medium and long: one partition by duration (a workflow run counts as long), the same
/// buckets calibrate, costs kept in spend units and converted with the target account's own k.
final class SessionCostsTests: XCTestCase {

    private typealias F = UsageFixtures
    private func pdt(_ text: String) -> Date { F.pdt(text) }

    /// One episode per session: calls every ten minutes from `start` for `minutes`, `spend` in all.
    private func episode(_ session: String, start: Date, minutes: Int, spend: Double, subagentShare: Double = 0) -> [ActivityLedger.Bucket] {
        let count = minutes / 10 + 1
        return (0..<count).map { index in
            let at = start.addingTimeInterval(Double(index) * 600)
            let last = index == count - 1 ? start.addingTimeInterval(Double(minutes) * 60) : at
            let share = spend / Double(count)
            return ActivityLedger.Bucket(start: ActivityLedger.bucketStart(at), first: at, last: last, spend: share, calls: 1,
                                         subagentCalls: subagentShare > 0 ? 1 : 0, subagentSpend: share * subagentShare)
        }
    }

    private func ledger(_ episodes: [(minutes: Int, spend: Double, share: Double)], from start: Date) -> ActivityLedger {
        var sessions: [String: [ActivityLedger.Bucket]] = [:]
        for (index, e) in episodes.enumerated() {
            sessions["s\(index)"] = episode("s\(index)", start: start.addingTimeInterval(Double(index) * 86400 / 4), minutes: e.minutes,
                                            spend: e.spend, subagentShare: e.share)
        }
        return ActivityLedger(sessions: sessions, anchors: [], indexedThrough: start.addingTimeInterval(20 * 86400))
    }

    /// 59 minutes is short, 60 and 180 medium, 181 long; half the spend from subagents makes a
    /// 20-minute episode a workflow run, long. Every episode lands in one bucket.
    func testEveryEpisodeFallsInExactlyOneBucket() {
        XCTAssertEqual(SessionSize.of(duration: 59 * 60, subagentShare: 0), .short)
        XCTAssertEqual(SessionSize.of(duration: 60 * 60, subagentShare: 0), .medium)
        XCTAssertEqual(SessionSize.of(duration: 180 * 60, subagentShare: 0), .medium)
        XCTAssertEqual(SessionSize.of(duration: 181 * 60, subagentShare: 0), .long)
        XCTAssertEqual(SessionSize.of(duration: 20 * 60, subagentShare: 0.5), .long)
        XCTAssertEqual(SessionSize.of(duration: 20 * 60, subagentShare: 0.49), .short)

        let start = pdt("2026-09-20 08:00")
        let episodes = [(59, 5.0, 0.0), (60, 6.0, 0.0), (180, 7.0, 0.0), (190, 8.0, 0.0), (20, 9.0, 0.6)]
        let sized = SessionCosts.episodes(from: [ledger(episodes.map { ($0.0, $0.1, $0.2) }, from: start)], now: pdt("2026-10-05 18:47"))
        XCTAssertEqual(sized.count, episodes.count)
        XCTAssertEqual(sized.sorted { $0.episode.spend < $1.episode.spend }.map(\.size), [.short, .medium, .medium, .long, .long])
    }

    /// A size uses this Mac's own figures once it has eight episodes in the last 30 days.
    func testBucketNeedsEightEpisodesToReplaceDefaults() {
        let start = pdt("2026-09-20 08:00")
        let now = pdt("2026-10-05 18:47")
        let seven = ledger((1...7).map { (20, Double($0) * 2, 0) }, from: start)
        XCTAssertEqual(SessionCosts.calibrate(from: [seven], now: now), .defaults)
        let eight = ledger((1...8).map { (20, Double($0) * 2, 0) }, from: start)
        let costs = SessionCosts.calibrate(from: [eight, eight], now: now)
        XCTAssertEqual(costs.short.episodes, 8, "a ledger two profiles share counts once")
        XCTAssertEqual(costs.short.whole.p50, 9, accuracy: 1e-9, "2, 4, … 16: interpolated median")
        XCTAssertEqual(costs.short.whole.p75, 12.5, accuracy: 1e-9)
        XCTAssertEqual(costs.short.fitWeek, costs.short.whole)
        XCTAssertEqual(costs.medium, SessionCosts.defaults.medium)
        XCTAssertEqual(costs.long, SessionCosts.defaults.long)
        XCTAssertEqual(AdvisorText.costsSummary(costs), "Costs from your last 30 days (short 8 sessions); medium and long use defaults for Max 20x")
    }

    /// A long session is fitted on its first three hours (week) and first hour (window).
    func testLongCostsUseTheFirstHours() {
        let start = pdt("2026-09-20 08:00")
        let long = ledger((1...8).map { _ in (300, 300.0, 0) }, from: start)
        let costs = SessionCosts.calibrate(from: [long], now: pdt("2026-10-05 18:47"))
        XCTAssertEqual(costs.long.episodes, 8)
        XCTAssertEqual(costs.long.whole.p75, 300, accuracy: 1e-9)
        XCTAssertEqual(costs.long.fitWeek.p75, 300.0 * 18 / 31, accuracy: 1e-6, "18 of 31 ten-minute calls in the first 3 h")
        XCTAssertEqual(costs.long.fitWindow.p75, 300.0 * 6 / 31, accuracy: 1e-6, "6 in the first hour")
    }

    /// The same costs in two accounts' points: a Pro-like account's k is twenty times a Max 20x
    /// one's, and so are its percentages.
    func testCostsConvertWithTargetAccountK() {
        let costs = SessionCosts.defaults
        let max20x = costs.points(for: .defaults)
        let pro = costs.points(for: Calibration(weekly: 1.48, window: 6, rmse: 3, segments: 2, medianR2: 0.99, windows: 8))
        XCTAssertEqual(pro.medium.fitWeek.p75 / max20x.medium.fitWeek.p75, 1.48 * 13.5, accuracy: 1e-9)
        XCTAssertEqual(max20x.short.fitWeek.p75, 14 / 13.5, accuracy: 1e-9)
        XCTAssertEqual(max20x.reserve, 2 * 14 / 13.5, accuracy: 1e-9)
        XCTAssertEqual(pro.short.fitWindow.p75 / max20x.short.fitWindow.p75, 6 * 3.3, accuracy: 1e-9)
    }

    /// An episode still running (activity in the last half hour) or with prompts and no spend
    /// is not a session's cost.
    func testRunningAndEmptyEpisodesAreLeftOut() {
        let now = pdt("2026-10-05 18:47")
        var sessions = ["done": episode("done", start: pdt("2026-10-05 10:00"), minutes: 30, spend: 5),
                        "running": episode("running", start: pdt("2026-10-05 18:00"), minutes: 40, spend: 5)]
        sessions["copy"] = [ActivityLedger.Bucket(start: pdt("2026-10-05 12:00"), first: pdt("2026-10-05 12:01"), last: pdt("2026-10-05 12:01"),
                                                  spend: 0, calls: 0, prompts: 2)]
        sessions["old"] = episode("old", start: pdt("2026-09-01 10:00"), minutes: 30, spend: 5)
        let sized = SessionCosts.episodes(from: [ActivityLedger(sessions: sessions, anchors: [], indexedThrough: now)], now: now)
        XCTAssertEqual(sized.map(\.episode.sessionId), ["done"])
    }

    /// The defaults are this Mac's own episode table (A15), re-derived under the final sizes.
    func testDefaultsAreTheReDerivedEpisodeTable() {
        let points = SessionCosts.defaults.points(for: .defaults)
        XCTAssertEqual(points.short.whole.p50, 0.44, accuracy: 0.01)
        XCTAssertEqual(points.short.whole.p75, 1.04, accuracy: 0.01)
        XCTAssertEqual(points.medium.whole.p75, 3.11, accuracy: 0.01)
        XCTAssertEqual(points.long.whole.p75, 12.6, accuracy: 0.1)
        XCTAssertEqual(points.long.fitWeek.p75, 8.0, accuracy: 0.05)
        XCTAssertEqual(points.long.fitWindow.p75, 21.2, accuracy: 0.1)
        XCTAssertTrue(SessionSize.allCases.allSatisfy { SessionCosts.defaults[$0].isDefault })
    }
}
