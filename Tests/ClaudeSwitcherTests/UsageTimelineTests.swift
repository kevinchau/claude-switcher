import XCTest
@testable import ClaudeSwitcherCore

/// The ledger's queries and the timeline built from samples, activity and the schedule.
final class UsageTimelineTests: XCTestCase {

    private typealias F = UsageFixtures
    private func pdt(_ text: String) -> Date { F.pdt(text) }

    private func sample(_ text: String, fh: Int? = nil, sd: Int? = nil) -> UsageSample {
        var u: [String: Int] = [:]
        if let fh { u["fh"] = fh }
        if let sd { u["sd"] = sd }
        return UsageSample(sampledAt: pdt(text), org: "org", utilization: u)
    }

    private var saturdayNinePM: WeeklySchedule {
        WeeklySchedule.infer(samples: [], anchors: [F.personalWeeklyAnchors[1]], now: pdt("2026-09-25 00:00"))!
    }

    // MARK: - Ledger

    func testSpendCountsWholeBucketsAndProratesTheEdges() {
        let ledger = F.ledger([(pdt("2026-10-05 10:01"), 2), (pdt("2026-10-05 10:05"), 4),
                               (pdt("2026-10-05 10:12"), 8), (pdt("2026-10-05 10:31"), 16)])
        XCTAssertEqual(ledger.buckets.count, 3, "10:00, 10:10, 10:30")
        XCTAssertEqual(ledger.spend(from: pdt("2026-10-05 09:00"), to: pdt("2026-10-05 11:00")), 30)
        XCTAssertEqual(ledger.spend(from: pdt("2026-10-05 10:10"), to: pdt("2026-10-05 10:31")), 8, "the 10:31 call is at the end, outside")
        // 10:01–10:05 is one bucket's span; from 10:03 half of it is inside.
        XCTAssertEqual(ledger.spend(from: pdt("2026-10-05 10:03"), to: pdt("2026-10-05 10:20")), 3 + 8, accuracy: 1e-9)
        XCTAssertEqual(ledger.spend(from: pdt("2026-10-05 10:40"), to: pdt("2026-10-05 12:00")), 0)
        XCTAssertEqual(ledger.firstCallBucket(atOrAfter: pdt("2026-10-05 10:20"))?.start, pdt("2026-10-05 10:30"))
    }

    func testEpisodesSplitAtThirtyMinutesIdle() throws {
        let calls = [(pdt("2026-10-05 10:00"), 1.0), (pdt("2026-10-05 10:20"), 1.0), (pdt("2026-10-05 10:50"), 1.0),
                     (pdt("2026-10-05 11:20:01"), 1.0), (pdt("2026-10-05 11:40"), 1.0)]
        let main = F.ledger(calls.map { (at: $0.0, spend: $0.1) }, session: "A", prompts: [pdt("2026-10-05 09:59")])
        let episodes = main.episodes()
        guard episodes.count == 2 else { return XCTFail("\(episodes.count) episodes: a gap of exactly 30 min keeps the episode; 30 min 1 s splits it") }
        XCTAssertEqual(episodes[0].start, pdt("2026-10-05 09:59"), "the prompt opens it")
        XCTAssertEqual(episodes[0].end, pdt("2026-10-05 10:50"))
        XCTAssertEqual(episodes[0].spend, 3)
        XCTAssertEqual(episodes[0].prompts, 1)
        XCTAssertEqual(episodes[1].duration, 19 * 60 + 59)
        XCTAssertEqual(episodes[1].sessionId, "a")

        // Two sessions at once are two episodes; subagent spend is the share that says "workflow".
        let worker = ActivityLedger.Bucket(start: pdt("2026-10-05 10:00"), first: pdt("2026-10-05 10:02"), last: pdt("2026-10-05 10:08"),
                                           spend: 6, calls: 3, subagentCalls: 2, subagentSpend: 4.5)
        let both = ActivityLedger(sessions: ["A": main.sessions["a"]!, "B": [worker]], anchors: [], indexedThrough: pdt("2026-10-05 12:00"))
        let b = try XCTUnwrap(both.episodes().first { $0.sessionId == "b" })
        XCTAssertEqual(b.subagentShare, 0.75)
        XCTAssertEqual(both.episodes().count, 3)
        XCTAssertEqual(both.spend(from: pdt("2026-10-05 10:00"), to: pdt("2026-10-05 10:10")), 1 + 6)
    }

    /// The 14-day ledger fixture reproduces the research's worked example: Personal had spent
    /// about 62 % of its week since the Saturday reset while its only sample this week read 0.
    func testFourteenDayLedgerFixtureMatchesTheResearch() {
        let personal = F.ledger14d("p")
        let end = pdt("2026-10-05 18:47")
        let spent = personal.spend(from: pdt("2026-10-03 21:00"), to: end)
        XCTAssertEqual(spent, 887, accuracy: 1)
        XCTAssertEqual(spent / 858, 1, accuracy: 0.05, "within 5 % of the research's independent count")
        XCTAssertEqual(spent / 13.8, 62, accuracy: 3, "points at the research's calibration")
        XCTAssertEqual(F.ledger14d("c").spend(from: pdt("2026-10-05 05:00"), to: end), 0)
        XCTAssertGreaterThan(F.ledger14d("c").spend(from: pdt("2026-09-30 11:17"), to: pdt("2026-09-30 17:17")), 0, "Christy's 09-30 burst")
        XCTAssertGreaterThan(personal.episodes().count, 20)
    }

    // MARK: - Segments

    /// Personal's 09-19 week: the Tue 09-22 grant reset the week at 94 %. A regression of `sd`
    /// on spend across that drop is meaningless, so a segment ends there — as at every reset.
    func testSegmentsCutAtEveryDrop() throws {
        let now = pdt("2026-09-26 21:30")
        let timeline = UsageTimeline.build(samples: F.personal(through: now), activity: nil, schedule: saturdayNinePM, now: now)
        let starts = timeline.segments.map(\.start)
        XCTAssertTrue(starts.contains(pdt("2026-09-19 21:09")), "the scheduled reset")
        XCTAssertTrue(starts.contains(pdt("2026-09-22 19:21")), "the grant")
        XCTAssertTrue(starts.contains(pdt("2026-09-26 21:00")), "the next scheduled reset")
        for segment in timeline.segments {
            let values = segment.points.map(\.value)
            for (a, b) in zip(values, values.dropFirst()) {
                XCTAssertFalse(WeeklySchedule.isResetDrop(from: a, to: b), "a reset inside the segment from \(segment.start)")
            }
            XCTAssertFalse(saturdayNinePM.hasCertainlyReset(since: segment.start, now: segment.end), "a scheduled reset inside")
        }
        let grantWeek = try XCTUnwrap(timeline.segments.first { $0.start == pdt("2026-09-19 21:09") })
        XCTAssertEqual(grantWeek.end, pdt("2026-09-22 19:16"))
        XCTAssertEqual(grantWeek.points.last?.value, 94)

        // A scheduled reset between two samples cuts even when the value rose across it.
        let rising = [sample("2026-09-26 18:00", sd: 40), sample("2026-09-27 15:00", sd: 45), sample("2026-09-27 16:00", sd: 47)]
        let cut = UsageTimeline.build(samples: rising, activity: nil, schedule: saturdayNinePM, now: pdt("2026-09-28 00:00"))
        XCTAssertEqual(cut.segments.map(\.points.count), [1, 2])
    }

    /// A week or more without a sample cuts a segment even with no drop and no schedule (a reset
    /// surely fell in it); six days do not.
    func testGapOfAWeekCutsASegment() {
        let eightDays = UsageTimeline.build(samples: [sample("2026-09-20 10:00", sd: 30), sample("2026-09-28 10:00", sd: 40)],
                                            activity: nil, schedule: nil, now: pdt("2026-09-29 00:00"))
        XCTAssertEqual(eightDays.segments.map(\.points.count), [1, 1])
        let sixDays = UsageTimeline.build(samples: [sample("2026-09-20 10:00", sd: 30), sample("2026-09-26 10:00", sd: 40)],
                                          activity: nil, schedule: nil, now: pdt("2026-09-29 00:00"))
        XCTAssertEqual(sixDays.segments.map(\.points.count), [2])
    }

    // MARK: - Cycles

    func testLimitHitWeeksCountsTheLastFourFinishedCycles() throws {
        // Five Saturday-to-Saturday weeks: the limit reached in the last three, the week before
        // ended at 69 % recorded at 19:30, and the first one has no sample near its end.
        var samples: [UsageSample] = []
        let weekends = ["2026-08-22", "2026-08-29", "2026-09-05", "2026-09-12", "2026-09-19", "2026-09-26"]
        let peaks = [40, 69, 100, 100, 100]
        for (end, peak) in zip(weekends.dropFirst(), peaks) {
            let saturday = pdt(end + " 21:00")
            samples.append(UsageSample(sampledAt: saturday.addingTimeInterval(-6 * 86400), org: "o", utilization: ["sd": 5]))
            samples.append(UsageSample(sampledAt: saturday.addingTimeInterval(peak == 40 ? -10 * 3600 : -90 * 60), org: "o", utilization: ["sd": peak]))
        }
        samples.append(UsageSample(sampledAt: pdt("2026-09-27 10:00"), org: "o", utilization: ["sd": 3]))
        let now = pdt("2026-09-28 12:00")
        let timeline = UsageTimeline.build(samples: samples, activity: nil, schedule: saturdayNinePM, now: now)
        XCTAssertEqual(timeline.limitHitWeeks.hit, 3, "the last four finished cycles: 69, 100, 100, 100")
        XCTAssertEqual(timeline.limitHitWeeks.of, 4)
        let finished = timeline.cycles.filter { $0.end <= now }
        XCTAssertEqual(finished.map(\.unusedAtEnd), [nil, 31, 0, 0, 0], "40 % recorded 10 h before the reset says nothing")
        XCTAssertNil(timeline.cycles.last?.unusedAtEnd, "the running week is not finished")

        // A recorded weekly limit hit marks its week even when no sample read 100: Claude Code
        // saw the refusal, the samples only 80 % an hour before the reset.
        let hitWeek = [UsageSample(sampledAt: pdt("2026-09-13 10:00"), org: "o", utilization: ["sd": 10]),
                       UsageSample(sampledAt: pdt("2026-09-19 20:00"), org: "o", utilization: ["sd": 80])]
        let refusal = LimitAnchor(resetsAt: pdt("2026-09-19 21:00"), kind: .sevenDay, hitAt: pdt("2026-09-18 16:40"))
        let marked = UsageTimeline.build(samples: hitWeek, activity: F.ledger([], anchors: [refusal]), schedule: saturdayNinePM,
                                         now: pdt("2026-09-20 12:00"))
        XCTAssertEqual(marked.cycles.first?.hitLimitAt, pdt("2026-09-18 16:40"))
        XCTAssertEqual(marked.cycles.first?.unusedAtEnd, 0, "not the 20 % the last sample would suggest")
        XCTAssertEqual(marked.limitHitWeeks.hit, 1)

        // Christy's real cycles: the limit reached in every one of its three finished weeks.
        let christyNow = pdt("2026-10-05 18:47")
        let christySchedule = try XCTUnwrap(WeeklySchedule.infer(samples: F.christy(), anchors: F.christyWeeklyAnchors, now: christyNow))
        let christy = UsageTimeline.build(samples: F.christy(), activity: F.ledger([], anchors: F.christyWeeklyAnchors),
                                          schedule: christySchedule, now: christyNow)
        XCTAssertEqual(christy.limitHitWeeks.hit, christy.limitHitWeeks.of)
        XCTAssertEqual(christy.limitHitWeeks.of, 3)
        let thursday = try XCTUnwrap(christy.cycles.first { $0.start == pdt("2026-09-28 05:00") })
        XCTAssertEqual(thursday.hitLimitAt, pdt("2026-10-01 09:05"), "the recorded hit, before any sample read 100")
    }

    func testNoScheduleMeansNoCycles() {
        let timeline = UsageTimeline.build(samples: [sample("2026-09-16 15:13", sd: 0), sample("2026-09-17 09:00", sd: 20)],
                                           activity: nil, schedule: nil, now: pdt("2026-09-18 00:00"))
        XCTAssertTrue(timeline.cycles.isEmpty)
        XCTAssertEqual(timeline.limitHitWeeks.of, 0)
        XCTAssertEqual(timeline.segments.count, 1)
    }

    // MARK: - Windows

    /// Every window in the series, walked the way the current one is: a drop in `fh` or the end
    /// of the five hours starts the next.
    func testWindowsWalkTheWholeSeries() throws {
        let samples = [sample("2026-10-05 09:05", fh: 0), sample("2026-10-05 09:17", fh: 4), sample("2026-10-05 11:00", fh: 30),
                       sample("2026-10-05 14:05", fh: 61), sample("2026-10-05 14:15", fh: 3), sample("2026-10-05 18:00", fh: 9),
                       sample("2026-10-05 19:20", fh: 12), sample("2026-10-06 08:00", fh: 0)]
        let ledger = F.ledger([(pdt("2026-10-05 09:12"), 5), (pdt("2026-10-05 13:00"), 7), (pdt("2026-10-05 14:12"), 1)])
        let timeline = UsageTimeline.build(samples: samples, activity: ledger, schedule: nil, now: pdt("2026-10-06 09:00"))
        XCTAssertEqual(timeline.windows.map(\.start), [pdt("2026-10-05 09:10"), pdt("2026-10-05 14:10"), pdt("2026-10-05 19:20")])
        XCTAssertEqual(timeline.windows.map(\.endBy), [pdt("2026-10-05 14:10"), pdt("2026-10-05 19:10"), pdt("2026-10-06 00:20")])
        XCTAssertEqual(timeline.windows.map(\.peakFh), [61, 9, 12])
        XCTAssertEqual(timeline.windows.first?.spend, 12)
        XCTAssertEqual(timeline.windows.first?.points.count, 4, "the 0 before the first positive value is part of the run")
    }
}
