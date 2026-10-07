import XCTest
@testable import ClaudeSwitcherCore

/// The forecast: the week as a recorded floor plus this Mac's activity, its bounds, the pace,
/// the five-hour window, what busy sessions still commit, and the limits that block.
final class UsageForecastTests: XCTestCase {

    private typealias F = UsageFixtures
    private typealias A = AdvisorFixtures
    private func pdt(_ text: String) -> Date { F.pdt(text) }

    private func sample(_ text: String, fh: Int? = nil, sd: Int? = nil) -> UsageSample {
        var u: [String: Int] = [:]
        if let fh { u["fh"] = fh }
        if let sd { u["sd"] = sd }
        return UsageSample(sampledAt: pdt(text), org: "o", utilization: u)
    }

    private func make(_ samples: [UsageSample], _ ledger: ActivityLedger?, exact: ExactUsage? = nil, busy: [BusySession] = [],
                      costs: SessionCosts = AdvisorFixtures.a15, now: Date) -> UsageForecast {
        UsageForecast.make(profileID: "personal", samples: samples, activity: ledger, exact: exact, busySessions: busy, costs: costs, now: now)
    }

    /// Calls of `spend` units each, `every` seconds apart, ending at `end`.
    private func calls(_ count: Int, spend: Double, every: TimeInterval = 600, ending end: Date) -> [(at: Date, spend: Double)] {
        (0..<count).map { (end.addingTimeInterval(-Double(count - 1 - $0) * every), spend) }
    }

    // MARK: - The week

    /// Personal on Mon 10-05 18:47: its only sample this week read 0 % on Sunday morning, 33
    /// hours earlier; its transcripts since show most of a week spent. The sample is the floor;
    /// the estimate adds the activity (the research's worked example: about 62 %).
    func testStaleWeeklyIsAFloorPlusActivity() throws {
        let now = pdt("2026-10-05 18:47")
        let f = make(F.personal(through: now), F.ledger14d("p", anchors: F.personalWeeklyAnchors), now: now)
        XCTAssertEqual(f.weekUsed.basis, .recordedPlusActivity)
        XCTAssertEqual(f.weekUsed.low, 0)
        XCTAssertEqual(f.weekUsed.value, 62, accuracy: 4)
        XCTAssertEqual(f.weekEnd, pdt("2026-10-10 21:00"))
        XCTAssertTrue(f.schedule?.isFresh(now: now) ?? false)
        XCTAssertNotNil(f.runOutAt, "at its pace it runs out before Saturday")
        XCTAssertLessThan(f.waste ?? 0, 0)
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "~\(pct(f.weekUsed.value))% now (est.) \u{00B7} recorded 0% 33 h ago")
    }

    /// A calibration whose segments fit to about ±4 points: the margin is twice that, not the
    /// 6-point floor. Two noisy segments a week apart (no reset seen, so no schedule), then a
    /// sample half a day ago and a point of activity since.
    func testMarginGrowsWithTheFitError() throws {
        var samples: [UsageSample] = []
        var calls: [(at: Date, spend: Double)] = []
        var clock = pdt("2026-09-21 06:00")
        for _ in 0..<2 {
            var total = 0.0
            for hour in 0...11 {
                if hour > 0 {
                    calls.append((clock.addingTimeInterval(-1800), 80))
                    total += 80
                }
                samples.append(UsageSample(sampledAt: clock, org: "o",
                                           utilization: ["sd": 10 + Int((total / 13.5).rounded()) + (hour % 2 == 1 ? 8 : 0)]))
                clock = clock.addingTimeInterval(3600)
            }
            clock = clock.addingTimeInterval(8 * 86400)
        }
        let last = try XCTUnwrap(samples.last?.sampledAt)
        let now = last.addingTimeInterval(12 * 3600)
        calls.append((last.addingTimeInterval(3600), 13.5))
        let f = make(samples, F.ledger(calls), now: now)
        XCTAssertNil(f.schedule)
        XCTAssertEqual(f.calibration.segments, 2)
        XCTAssertGreaterThan(f.calibration.rmse, 3.5, "the noise")
        XCTAssertLessThan(f.calibration.rmse, 6, "so that once the error would stay under the 6-point floor")
        XCTAssertEqual(f.weekUsed.basis, .recordedNoSchedule)
        XCTAssertEqual(f.weekUsed.high, f.weekUsed.value + 2 * f.calibration.rmse + 2 * 0.5, accuracy: 1e-9)
    }

    /// The upper bound is the estimate plus a fixed margin (6, or twice the fit's error) plus 2
    /// points a day since the sample for use this Mac cannot see — not a share of the estimate.
    func testHighBoundIsAbsolute() {
        let reset = pdt("2026-10-03 21:00")
        let now = reset.addingTimeInterval(1.4 * 86400)
        let ledger = F.ledger(calls(63, spend: 13.5, every: 1800, ending: now.addingTimeInterval(-60)), anchors: F.personalWeeklyAnchors)
        let f = make([UsageSample(sampledAt: reset, org: "o", utilization: ["sd": 0])], ledger, now: now)
        XCTAssertEqual(f.weekUsed.value, 63, accuracy: 0.01)
        XCTAssertEqual(f.weekUsed.high, 63 + 6 + 2 * 1.4, accuracy: 0.01, "72, not 85")
        XCTAssertEqual(f.headroom.low, 100 - 71.8, accuracy: 0.01)
        XCTAssertEqual(f.weekUsed.basis, .recordedPlusActivity)
    }

    /// Christy's first week: samples since Wed 09-16, no reset seen until Mon 09-21. The
    /// latest sample is a floor all the same; the reset time and the waste are unknown, and
    /// the account can take any size.
    func testSampleWithoutScheduleIsAFloor() throws {
        // Thu 09-17 11:45: 77 % recorded two minutes ago, a fresh five-hour window.
        let now = pdt("2026-09-17 11:45")
        let christySamples = F.christy(through: now)
        let christy = UsageForecast.make(profileID: "christy", samples: christySamples, activity: .empty(indexedThrough: now), exact: nil,
                                         busySessions: [], costs: A.a15, now: now)
        XCTAssertNil(christy.schedule)
        XCTAssertEqual(christy.weekUsed.basis, .recordedNoSchedule)
        XCTAssertEqual(christy.weekUsed.low, Double(christySamples.last!.utilization["sd"]!))
        XCTAssertNil(christy.weekEnd)
        XCTAssertNil(christy.waste)
        let personal = make(F.personal(through: now), F.ledger([], anchors: F.personalWeeklyAnchors), now: now)
        let medium = UsageAdvisor.advise(size: .medium, forecasts: ["personal": personal, "christy": christy], costs: A.a15,
                                         order: A.order, previous: nil, now: now)
        XCTAssertEqual(medium.profileID, "christy")
        XCTAssertEqual(A.reason(medium), .resetUnknown)
        XCTAssertEqual(ForecastText.line(christy, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "Reset time not known yet (est.)")
    }

    func testNoScheduleAndNoRecentSampleIsInsufficient() {
        let now = pdt("2026-10-05 18:47")
        let ledger = F.ledger(calls(10, spend: 10, ending: now.addingTimeInterval(-3600)))
        let f = make([sample("2026-09-25 10:00", sd: 30)], ledger, now: now)
        XCTAssertEqual(f.weekUsed.basis, .insufficient("no reset observed yet"))
        XCTAssertNil(f.waste)
        XCTAssertEqual(f.weekUsed.high, 100 / 13.5 + 6 + 14, accuracy: 0.01, "what the last seven days could have used")
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "Reset time not known yet (est.)")
    }

    func testNoHistoryYieldsDefaultsLabelled() {
        let now = pdt("2026-10-05 18:47")
        let f = make([], .empty(indexedThrough: now), now: now)
        XCTAssertEqual(f.weekUsed, Estimate(value: 0, low: 0, high: 100, basis: .defaults))
        XCTAssertEqual(f.calibration, .defaults)
        XCTAssertFalse(f.stale)
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "No usage recorded yet (default)")
        XCTAssertTrue(ForecastText.tooltip(f, indexState: .ready(indexedThrough: now), running: false, clock: A.clock(now))
            .contains("using defaults for Max 20x (not enough history yet)"))
        XCTAssertTrue(DiagnosticsText.calibration(f, costs: .defaults).contains("0.074 pts per unit (default)"))
    }

    /// No sample since the reset: what this Mac has spent since it, from 0.
    func testActivityOnlyWithoutSampleThisWeek() {
        let now = pdt("2026-10-05 18:47")
        let ledger = F.ledger(calls(20, spend: 13.5, ending: now.addingTimeInterval(-600)), anchors: F.personalWeeklyAnchors)
        let f = make([sample("2026-10-02 10:00", sd: 70)], ledger, now: now)
        XCTAssertEqual(f.weekUsed.basis, .activityOnly)
        XCTAssertEqual(f.weekUsed.low, 0)
        XCTAssertEqual(f.weekUsed.value, 20, accuracy: 0.01)
        // The bound adds 2 points a day of unseen use since the Sat 21:00 reset (1.9 days).
        let days = now.timeIntervalSince(pdt("2026-10-03 21:00")) / 86400
        XCTAssertEqual(f.weekUsed.high, 20 + 6 + 2 * days, accuracy: 0.01)
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "~20% now (est.) \u{00B7} not recorded this week")
    }

    /// Three Saturdays bracket the reset between 18:00 and 21:30. The week's last sample, 85 % at
    /// 18:40, is inside that interval and did not drop: it was taken before the reset, so it is
    /// not this week's floor — the week is this Mac's activity since the reset (about 20 %), not
    /// "likely at the limit".
    func testPreResetSampleInsideTheBracketIsNotCarriedForward() throws {
        let now = pdt("2026-10-05 12:00")
        let f = make(bracketedWeek(lastSample: sample("2026-10-03 18:40", sd: 85)), bracketedActivity(), now: now)
        let schedule = try XCTUnwrap(f.schedule)
        XCTAssertEqual(schedule.next(after: now).after, pdt("2026-10-10 18:00"))
        XCTAssertEqual(schedule.next(after: now).by, pdt("2026-10-10 21:30"))
        XCTAssertEqual(f.weekUsed.basis, .activityOnly)
        XCTAssertEqual(f.weekUsed.value, 20, accuracy: 0.01)
        XCTAssertEqual(f.weekUsed.low, 0)
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "~20% now (est.) \u{00B7} not recorded this week")
        // Past the interval's middle (19:45) but still inside it and not dropped: still before the reset.
        let late = make(bracketedWeek(lastSample: sample("2026-10-03 20:30", sd: 85)), bracketedActivity(), now: now)
        XCTAssertEqual(late.weekUsed.basis, .activityOnly)
        XCTAssertEqual(late.weekUsed.value, 20, accuracy: 0.01)
    }

    /// The same week with a sample after the interval, reading 1 % at 21:40: that one is this
    /// week's floor.
    func testSampleAfterTheBracketIsThisWeeks() {
        let now = pdt("2026-10-05 12:00")
        let samples = bracketedWeek(lastSample: sample("2026-10-03 18:40", sd: 85)) + [sample("2026-10-03 21:40", sd: 1)]
        let f = make(samples, bracketedActivity(), now: now)
        XCTAssertEqual(f.weekUsed.basis, .recordedPlusActivity)
        XCTAssertEqual(f.weekUsed.low, 1)
        XCTAssertEqual(f.weekUsed.value, 21, accuracy: 0.01)
    }

    /// Saturdays 09-12, 09-19 and 09-26 reset between 18:00 and 21:30; a Thursday sample; then
    /// `lastSample`.
    private func bracketedWeek(lastSample: UsageSample) -> [UsageSample] {
        var samples: [UsageSample] = []
        for day in ["2026-09-12", "2026-09-19", "2026-09-26"] {
            samples.append(sample(day + " 18:00", sd: 80))
            samples.append(sample(day + " 21:30", sd: 1))
        }
        return samples + [sample("2026-10-01 10:00", sd: 55), lastSample]
    }

    /// Twenty points' worth (at the default weight) on Sunday 10-04.
    private func bracketedActivity() -> ActivityLedger {
        F.ledger(calls(20, spend: 13.5, every: 1800, ending: pdt("2026-10-04 19:30")))
    }

    /// A weekly limit hit Thursday, then a grant reset the week: Friday's sample reads 0. The hit
    /// is older than the sample, so the week is the sample plus activity, not full.
    func testWeeklyHitBeforeALaterSampleDoesNotFillTheWeek() {
        let now = pdt("2026-10-02 14:00")
        let hit = LimitAnchor(resetsAt: pdt("2026-10-03 21:00"), kind: .sevenDay, hitAt: pdt("2026-10-01 09:05"))
        let ledger = F.ledger([(pdt("2026-10-02 12:00"), 13.5)], anchors: [hit] + Array(F.personalWeeklyAnchors.prefix(2)))
        let f = make([sample("2026-09-30 07:00", sd: 91), sample("2026-10-02 10:00", sd: 0)], ledger, now: now)
        XCTAssertEqual(f.weekUsed.low, 0)
        XCTAssertEqual(f.weekUsed.value, 1, accuracy: 0.01)
        XCTAssertEqual(f.weekUsed.basis, .recordedPlusActivity)
        // The hit after the sample still fills it.
        let later = make([sample("2026-10-01 07:00", sd: 91)], ledger, now: now)
        XCTAssertEqual(later.weekUsed.value, 100)
    }

    /// After a one-off reset inside the week the pace counts from it. Personal on Wed 09-23
    /// 12:00: the Tue 19:16 grant reset the week; 26 % since then is 1.6 points an hour, not the
    /// 0.3 an hour of 26 % over the 87 hours since Saturday's reset — the week runs out (it was hit
    /// Thu 09-24 09:20), it does not leave 10 % unused.
    func testPaceAfterAGrantCountsFromTheGrant() throws {
        let now = pdt("2026-09-23 12:00")
        let f = make(F.personal(through: now), F.ledger14d("p", anchors: F.personalWeeklyAnchors), now: now)
        XCTAssertEqual(f.weekStart, pdt("2026-09-19 21:00"), "the scheduled week is unchanged")
        XCTAssertEqual(f.weekUsed.value, 26.4, accuracy: 0.5)
        let paceWeek = try XCTUnwrap(f.paceWeek)
        XCTAssertEqual(paceWeek, f.weekUsed.value / (now.timeIntervalSince(pdt("2026-09-22 19:21")) / 3600), accuracy: 1e-9)
        XCTAssertEqual(paceWeek, 1.6, accuracy: 0.05)
        let out = try XCTUnwrap(f.runOutAt)
        XCTAssertLessThan(out, pdt("2026-09-25 12:00"), "Friday morning at that pace, well before the Sat 21:00 reset")
        XCTAssertLessThan(f.waste ?? 0, 0)
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "~26% used (est.) \u{00B7} out about Fri morn")
    }

    /// Claude Code recorded the weekly limit hit after the latest sample: the week is full.
    func testRecordedWeeklyHitFillsTheWeek() {
        let now = pdt("2026-09-30 12:00")
        let hit = LimitAnchor(resetsAt: pdt("2026-10-03 21:00"), kind: .sevenDay, hitAt: pdt("2026-09-30 08:12"))
        let f = make([sample("2026-09-30 07:00", sd: 91)], F.ledger([], anchors: [hit]), now: now)
        XCTAssertEqual(f.weekUsed.value, 100)
        XCTAssertEqual(f.weekUsed.low, 100)
        XCTAssertNil(f.waste)
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "Week limit reached \u{2014} resets Sat 9 PM")
    }

    /// A fresh cached usage body is one more sample, at its fetch.
    func testFreshCachedBodyIsASample() {
        let now = pdt("2026-10-05 18:50")
        let exact = ExactUsage(accountID: "a", rateLimitTier: "default_claude_max_20x", fetchedAt: pdt("2026-10-05 18:47"),
                               fiveHourUtilization: 44, fiveHourResetsAt: pdt("2026-10-05 21:10"), sevenDayUtilization: 58,
                               sevenDayResetsAt: pdt("2026-10-10 21:00"))
        let f = make([sample("2026-10-04 09:43", fh: 0, sd: 0)], .empty(indexedThrough: now), exact: exact, now: now)
        XCTAssertEqual(f.weekUsed.low, 58)
        XCTAssertEqual(f.plan, .max20x)
        XCTAssertTrue(f.windowExact)
        XCTAssertEqual(f.windowClearsAt, pdt("2026-10-05 21:10"))
        XCTAssertEqual(f.windowUsed.low, 44)
        XCTAssertEqual(PlanLabel(rateLimitTier: "claude_pro"), .named("claude_pro"))
        XCTAssertEqual(PlanLabel(rateLimitTier: nil), .unknown)
    }

    func testStaleMeansNothingForSevenDays() {
        let now = pdt("2026-10-05 18:47")
        let old = [sample("2026-09-27 10:00", sd: 20)]
        XCTAssertTrue(make(old, F.ledger([], anchors: F.personalWeeklyAnchors), now: now).stale)
        XCTAssertFalse(make(old, F.ledger([(pdt("2026-10-04 12:00"), 5)], anchors: F.personalWeeklyAnchors), now: now).stale)
        XCTAssertFalse(make([sample("2026-10-01 10:00", sd: 20)], .empty(indexedThrough: now), now: now).stale)
        // At the edge: 6.9 days is not stale, 7.1 is.
        let day: TimeInterval = 86400
        let recent = UsageSample(sampledAt: now.addingTimeInterval(-6.9 * day), org: "o", utilization: ["sd": 20])
        let older = UsageSample(sampledAt: now.addingTimeInterval(-7.1 * day), org: "o", utilization: ["sd": 20])
        XCTAssertFalse(make([recent], .empty(indexedThrough: now), now: now).stale)
        XCTAssertTrue(make([older], .empty(indexedThrough: now), now: now).stale)
    }

    /// With no reset seen and no sample in a week, only the last seven days' activity is counted
    /// (some reset fell in them): a call 6.9 days ago counts, one 7.1 days ago does not.
    func testInsufficientCountsTheLastSevenDaysOfActivity() {
        let now = pdt("2026-10-05 18:47")
        let day: TimeInterval = 86400
        let ledger = F.ledger([(now.addingTimeInterval(-7.1 * day), 13.5), (now.addingTimeInterval(-6.9 * day), 13.5)])
        let f = make([sample("2026-09-25 10:00", sd: 30)], ledger, now: now)
        XCTAssertEqual(f.weekUsed.basis, .insufficient("no reset observed yet"))
        XCTAssertEqual(f.weekUsed.value, 1, accuracy: 1e-9)
    }

    /// "Recorded" means a sample under half an hour old with nothing spent since; older, it is
    /// an estimate (use elsewhere may have moved it), and the tooltip says so.
    func testRecordedBasisOnlyWithinThirtyMinutes() throws {
        let now = pdt("2026-10-05 18:47")
        let ledger = F.ledger([(pdt("2026-10-05 08:00"), 13.5)], anchors: F.personalWeeklyAnchors)
        let fresh = make([sample("2026-10-05 18:27", sd: 30)], ledger, now: now)
        XCTAssertEqual(fresh.weekUsed.basis, .recorded)
        let tooltip = { (f: UsageForecast) in ForecastText.tooltip(f, indexState: .ready(indexedThrough: now), running: false, clock: A.clock(now)) }
        XCTAssertTrue(tooltip(fresh).split(separator: "\n").contains { $0.hasPrefix("Recorded: 30% of the week used.") }, tooltip(fresh))
        let older = make([sample("2026-10-05 13:47", sd: 30)], ledger, now: now)
        XCTAssertEqual(older.weekUsed.basis, .recordedPlusActivity)
        XCTAssertEqual(older.weekUsed.value, 30, "nothing spent since")
        let lines = tooltip(older).split(separator: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Estimated: ~30% of the week used") }, tooltip(older))
        XCTAssertFalse(lines.contains { $0.hasPrefix("Recorded:") })
    }

    /// Without activity (the index not built) nothing is extrapolated: no pace, no projection,
    /// no run-out, no waste — the samples are a floor, not a measure of the week.
    func testWithoutActivityNothingIsExtrapolated() {
        for moment in ["2026-09-23 12:00", "2026-09-28 12:00"] {
            let now = pdt(moment)
            let f = make(F.personal(through: now), nil, now: now)
            XCTAssertNil(f.paceWeek, moment)
            XCTAssertNil(f.pace, moment)
            XCTAssertNil(f.projectedAtReset, moment)
            XCTAssertNil(f.runOutAt, moment)
            XCTAssertNil(f.waste, moment)
        }
    }

    // MARK: - Pace and projection

    /// Claude's own gates: no weekly pace before 12 hours or 10 points.
    func testPaceIsNilBeforeTwelveHoursOrTenPoints() {
        let ledger = F.ledger([], anchors: F.personalWeeklyAnchors)
        let reset = sample("2026-10-03 21:00", sd: 0)
        let early = make([reset, sample("2026-10-04 08:00", sd: 15)], ledger, now: pdt("2026-10-04 08:00"))
        XCTAssertNil(early.paceWeek, "11 h in")
        XCTAssertNil(early.pace, "nothing spent in the last 6 h either")
        XCTAssertNil(early.waste)
        XCTAssertEqual(ForecastText.line(early, indexState: .ready(indexedThrough: early.timeline.cycles.last!.start), clock: A.clock(pdt("2026-10-04 08:00"))),
                       "Too early to tell \u{2014} 11 h into the week")
        let light = make([reset, sample("2026-10-04 10:00", sd: 8)], ledger, now: pdt("2026-10-04 10:00"))
        XCTAssertNil(light.paceWeek, "8 points")
        let both = make([reset, sample("2026-10-04 10:00", sd: 15)], ledger, now: pdt("2026-10-04 10:00"))
        let paceAfterThirteenHours: Double = 15.0 / 13.0
        XCTAssertEqual(both.paceWeek ?? 0, paceAfterThirteenHours, accuracy: 1e-9)
        // 15 points used, 155 hours of the week still to come at that pace.
        let projected: Double = 15.0 + paceAfterThirteenHours * 155.0
        let expectedWaste: Int = Int((100.0 - projected).rounded())
        XCTAssertEqual(both.waste, expectedWaste)
    }

    /// Christy on Wed 09-30 17:17, 60 hours into her week: the week's pace alone runs out on
    /// Friday afternoon (on samples only, 41 % at 0.68 an hour, it said Sunday); the last six
    /// hours ran at about 1.4, and the limit was in fact hit Thursday 09:05. The faster pace
    /// says Thursday night.
    func testProjectionUsesFasterOfWeekAndRecentPace() throws {
        let now = pdt("2026-09-30 17:17")
        let f = UsageForecast.make(profileID: "christy", samples: F.christy(through: now),
                                   activity: F.ledger14d("c", anchors: F.christyWeeklyAnchors), exact: nil, busySessions: [],
                                   costs: A.a15, now: now)
        let paceWeek = try XCTUnwrap(f.paceWeek)
        let paceRecent = try XCTUnwrap(f.paceRecent)
        XCTAssertEqual(f.weekUsed.value, 56, accuracy: 0.5, "the 17:17 sample")
        XCTAssertEqual(paceWeek, 56 / 60.28, accuracy: 0.01)
        XCTAssertGreaterThan(paceRecent, 1.2)
        XCTAssertEqual(f.pace, paceRecent)
        let out = try XCTUnwrap(f.runOutAt)
        XCTAssertLessThan(out, pdt("2026-10-02 03:00"), "Thursday night")
        let weekOnly = now.addingTimeInterval((100 - f.weekUsed.value) / paceWeek * 3600)
        XCTAssertGreaterThan(weekOnly, pdt("2026-10-02 12:00"), "the week's pace alone says Friday afternoon")
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "~56% used (est.) \u{00B7} out about Thu night")
    }

    /// Weeks that ended at the limit are reported, not projected from: a cycle at 100 in three
    /// of its last four still projects linearly from this week's own pace.
    func testNoCalibratedRemainderTier() throws {
        var samples: [UsageSample] = []
        let weekends = ["2026-08-22", "2026-08-29", "2026-09-05", "2026-09-12", "2026-09-19", "2026-09-26"]
        for (end, peak) in zip(weekends.dropFirst(), [40, 69, 100, 100, 100]) {
            let saturday = pdt(end + " 21:00")
            samples.append(UsageSample(sampledAt: saturday.addingTimeInterval(-6 * 86400), org: "o", utilization: ["sd": 5]))
            samples.append(UsageSample(sampledAt: saturday.addingTimeInterval(-90 * 60), org: "o", utilization: ["sd": peak]))
        }
        samples.append(sample("2026-09-27 10:00", sd: 3))
        samples.append(sample("2026-09-29 18:00", sd: 58))
        let now = pdt("2026-09-29 18:00")
        let f = make(samples, F.ledger([], anchors: F.personalWeeklyAnchors), now: now)
        XCTAssertEqual(f.timeline.limitHitWeeks.hit, 3)
        XCTAssertEqual(f.timeline.limitHitWeeks.of, 4)
        let pace = try XCTUnwrap(f.paceWeek)
        XCTAssertEqual(pace, 58 / 69, accuracy: 1e-9)
        let projected = 58 + pace * 99
        XCTAssertEqual(f.projectedAtReset?.value ?? 0, projected, accuracy: 1e-9)
        XCTAssertEqual(f.waste, Int((100 - projected).rounded()))
        XCTAssertLessThan(f.waste ?? 0, 0, "it runs out; a median of past remainders would have said 41 unused")
    }

    // MARK: - Five-hour window

    func testWindowFromSampleAndActivity() {
        let now = pdt("2026-10-05 18:47")
        let ledger = F.ledger(calls(4, spend: 3.3, ending: pdt("2026-10-05 18:40")))
        let f = make([sample("2026-10-05 18:00", fh: 30, sd: 40)], ledger, now: now)
        XCTAssertEqual(f.windowUsed.low, 30)
        XCTAssertEqual(f.windowUsed.value, 34, accuracy: 0.01, "4 calls of 1 window point after the sample")
        XCTAssertEqual(f.windowClearsAt, pdt("2026-10-05 23:00"))
        XCTAssertFalse(f.windowExact)
        XCTAssertEqual(f.windowRoom, 66, accuracy: 0.01)

        // No sample inside: the window from the first call after the last one's end.
        let fromActivity = make([sample("2026-10-05 09:00", fh: 20, sd: 40)], F.ledger(calls(3, spend: 6.6, ending: pdt("2026-10-05 18:30"))), now: now)
        XCTAssertEqual(fromActivity.window?.activityStart, pdt("2026-10-05 18:10"))
        XCTAssertEqual(fromActivity.windowUsed.value, 6, accuracy: 0.01)
        XCTAssertEqual(fromActivity.windowClearsAt, pdt("2026-10-05 23:10"))
    }

    /// The window's estimate has a cautious bound, as the week's has: the five-hour fit's typical
    /// error (twice the default 5 points until eight windows calibrate it) and use this Mac
    /// cannot see — 2 points an hour since the later of the window's last recording and its
    /// start, at most 10. The Advisor fits sessions against that bound; the line and Diagnostics
    /// keep the central value.
    func testWindowHighBoundAllowsForUnseenUse() throws {
        let now = pdt("2026-10-05 18:47")
        let ledger = F.ledger(calls(4, spend: 3.3, ending: pdt("2026-10-05 18:40")), anchors: F.personalWeeklyAnchors)
        let f = make([sample("2026-10-05 18:00", fh: 30, sd: 40)], ledger, now: now)
        XCTAssertEqual(f.windowUsed.value, 34, accuracy: 0.01)
        XCTAssertEqual(f.windowUsed.high, 34 + 2 * Calibration.defaultWindowRMSE + 2 * 47.0 / 60, accuracy: 0.01)
        XCTAssertEqual(f.windowRoom, 66, accuracy: 0.01, "the central room")
        // A calibrated window weight brings its own error: 2 × 1.5 is under the 4-point floor.
        XCTAssertEqual(Calibration(weekly: 0.074, window: 0.3, rmse: 2, segments: 2, medianR2: 0.99, windows: 8, windowRMSE: 1.5).windowRMSE, 1.5)

        // No window open, the last recording a morning's: the allowance is capped.
        let idle = make([sample("2026-10-05 09:00", fh: 20, sd: 40)], F.ledger([], anchors: F.personalWeeklyAnchors), now: now)
        XCTAssertNil(idle.windowClearsAt)
        XCTAssertEqual(idle.windowUsed.value, 0)
        XCTAssertEqual(idle.windowUsed.high, 2 * Calibration.defaultWindowRMSE + UsageForecast.unseenWindowCap, accuracy: 1e-9)

        // A window just recorded at 75 %: 25 points of room by the estimate, 15 by the bound — a
        // medium session (20 at p75) does not fit it now.
        let recorded = make([sample("2026-10-05 18:46", fh: 75, sd: 40)], F.ledger([], anchors: F.personalWeeklyAnchors), now: now)
        XCTAssertEqual(recorded.windowRoom, 25, accuracy: 0.01)
        XCTAssertEqual(100 - recorded.windowUsed.high, 15, accuracy: 0.1)
        let thin = A.forecast("christy", headroom: 3, waste: -50)
        let medium = UsageAdvisor.advise(size: .medium, forecasts: ["personal": recorded, "christy": thin], costs: A.a15, order: A.order,
                                         previous: nil, now: now)
        XCTAssertNil(medium.profileID)
        guard case .windowFull(_, let room, false)? = medium.alternatives.first(where: { $0.profileID == "personal" })?.why else {
            return XCTFail("\(medium.alternatives)")
        }
        XCTAssertEqual(room, 14, "the cautious room, rounded down")
    }

    /// A `five_hour` limit hit after the latest sample: the window is full until its recorded
    /// end, and the line says so without "(est.)".
    func testFiveHourHitFillsTheWindowExactly() {
        let now = pdt("2026-10-05 20:00")
        let hit = LimitAnchor(resetsAt: pdt("2026-10-05 21:10"), kind: .fiveHour, hitAt: pdt("2026-10-05 19:51"))
        let f = make([sample("2026-10-05 19:00", fh: 80, sd: 40)], F.ledger([], anchors: [hit] + F.personalWeeklyAnchors), now: now)
        XCTAssertEqual(f.windowUsed.value, 100)
        XCTAssertTrue(f.windowExact)
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "5h window full \u{2014} clears 9:10 PM")
        XCTAssertEqual(f.reading.map { UsageText.trailing(for: $0.rows[0], in: $0, time: A.clock(now).time) }, "resets 9:10 PM")
    }

    // MARK: - Committed

    /// A busy session 70 minutes in that has spent 1 point is a medium one: it still commits
    /// the medium p75 (5) less that point. One 40 minutes in is short (2 − 1); a workflow run is
    /// long (30 − 1). A session idle for over half an hour starts over.
    func testBusySessionCommitsRemainingCost() throws {
        let now = pdt("2026-10-05 18:47")
        func committed(minutesIn: Double, subagent: Bool = false, lastCallAgo: TimeInterval = 120) -> UsageForecast {
            let start = now.addingTimeInterval(-minutesIn * 60)
            let end = now.addingTimeInterval(-lastCallAgo)
            let count = Int(end.timeIntervalSince(start) / 600) + 1
            // A call every ten minutes, 13.5 units (one point) in all.
            let ledger = F.ledger((0..<count).map { (start.addingTimeInterval(Double($0) * 600), 13.5 / Double(count)) }, session: "busy",
                                  subagent: subagent, anchors: F.personalWeeklyAnchors)
            return make([sample("2026-10-05 12:00", fh: 0, sd: 30)], ledger, busy: [BusySession(cliSessionId: "BUSY")], now: now)
        }
        let medium = committed(minutesIn: 70)
        XCTAssertEqual(medium.commitments.first?.size, .medium)
        XCTAssertEqual(medium.committedWeek, 5 - 1, accuracy: 1e-6)
        XCTAssertEqual(committed(minutesIn: 40).committedWeek, 2 - 1, accuracy: 1e-6)
        XCTAssertEqual(committed(minutesIn: 40, subagent: true).committedWeek, 30 - 1, accuracy: 1e-6)
        let restarted = committed(minutesIn: 100, lastCallAgo: 40 * 60)
        XCTAssertEqual(restarted.committedWeek, 2, accuracy: 1e-6, "a new turn after 40 idle minutes")
        XCTAssertEqual(make([sample("2026-10-05 12:00", sd: 30)], F.ledger([(now, 1)], anchors: F.personalWeeklyAnchors), now: now).committedWeek, 0)
        XCTAssertTrue(ForecastText.tooltip(medium, indexState: .ready(indexedThrough: now), running: true, clock: A.clock(now))
            .contains("A medium session is running here (~4% of the week still committed, est.)"))
        XCTAssertGreaterThan(medium.committedWindow, 0)
    }

    // MARK: - Blocks

    /// Claude Code recorded the Fable-only weekly limit (`seven_day_overage_included`): medium
    /// and long are off that account until it resets.
    func testFableHitBlocksUntilReset() {
        let now = pdt("2026-10-01 12:00")
        let fable = LimitAnchor(resetsAt: pdt("2026-10-03 21:00"), kind: LimitKind(rateLimitType: "seven_day_overage_included"),
                                hitAt: pdt("2026-10-01 09:05"))
        let f = make([sample("2026-10-01 11:00", sd: 40)], F.ledger([], anchors: [fable] + F.personalWeeklyAnchors), now: now)
        XCTAssertEqual(f.blockedUntil, pdt("2026-10-03 21:00"))
        XCTAssertEqual(f.blockReason, "Fable limit")
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "Fable limit reached \u{2014} until Sat 9 PM")
        let after = make([sample("2026-10-04 11:00", sd: 4)], F.ledger([], anchors: [fable] + F.personalWeeklyAnchors), now: pdt("2026-10-04 12:00"))
        XCTAssertNil(after.blockedUntil)
        XCTAssertNil(after.blockReason)
    }

    /// A per-model weekly limit (`seven_day_opus`) blocks medium and long the same way, until it
    /// resets.
    func testModelHitBlocksUntilReset() {
        let now = pdt("2026-10-01 12:00")
        let opus = LimitAnchor(resetsAt: pdt("2026-10-03 21:00"), kind: LimitKind(rateLimitType: "seven_day_opus"), hitAt: pdt("2026-10-01 09:05"))
        let f = make([sample("2026-10-01 11:00", sd: 40)], F.ledger([], anchors: [opus] + F.personalWeeklyAnchors), now: now)
        XCTAssertEqual(f.blockedUntil, pdt("2026-10-03 21:00"))
        XCTAssertEqual(f.blockReason, "Opus limit")
        let christy = A.forecast("christy", headroom: 40, waste: -10, at: now)
        for size in [SessionSize.medium, .long] {
            let advice = UsageAdvisor.advise(size: size, forecasts: ["personal": f, "christy": christy], costs: A.a15, order: A.order,
                                             previous: nil, now: now)
            XCTAssertEqual(advice.profileID, "christy", "\(size)")
            XCTAssertEqual(advice.alternatives.first { $0.profileID == "personal" }?.why, .blocked(reason: "Opus limit", until: pdt("2026-10-03 21:00")))
        }
        let after = make([sample("2026-10-04 11:00", sd: 4)], F.ledger([], anchors: [opus] + F.personalWeeklyAnchors), now: pdt("2026-10-04 12:00"))
        XCTAssertNil(after.blockedUntil)
    }

    // MARK: - Index state

    /// Without activity nothing is estimated: the floor is the recorded value.
    func testWithoutActivityOnlyRecordedValues() {
        let now = pdt("2026-10-05 18:47")
        let f = make(F.personal(through: now), nil, now: now)
        XCTAssertFalse(f.activityKnown)
        XCTAssertEqual(f.weekUsed.value, 0)
        XCTAssertEqual(f.weekUsed.basis, .recorded)
        XCTAssertNil(f.estimatedPercent(for: "sd"))
        XCTAssertEqual(ForecastText.line(f, indexState: .building, clock: A.clock(now)), "Reading activity\u{2026}")
        let ready = make(F.personal(through: now), F.ledger14d("p", anchors: F.personalWeeklyAnchors), now: now)
        XCTAssertEqual(ready.estimatedPercent(for: "sd"), pct(ready.weekUsed.value), "the bar's lighter part")
        XCTAssertEqual(ready.estimatedPercent(for: "fh"), pct(ready.windowUsed.value), "a window this Mac's activity opened")
        XCTAssertNotNil(ready.window?.activityStart)
    }
}
