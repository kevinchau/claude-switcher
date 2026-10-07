import XCTest
@testable import ClaudeSwitcherCore

/// The words: the forecast line (≤ 40 characters, hedge by 32), the week row's suffix rule,
/// the tooltip, the Advisor submenu, Diagnostics and `--dry-run` — and every owner assumption
/// surfaced where the design says.
final class AdvisorTextTests: XCTestCase {

    private typealias F = UsageFixtures
    private typealias A = AdvisorFixtures
    private func pdt(_ text: String) -> Date { F.pdt(text) }
    private let ready = ActivityIndexState.ready(indexedThrough: AdvisorFixtures.now)

    /// A forecast for the line, every field the line reads set by hand.
    private func forecast(
        used: Double = 40, low: Double = 30, high: Double = 50, basis: Basis = .recordedPlusActivity, latest: (String, Int)? = nil,
        pace: Double? = 1, projected: Double? = 80, runOut: Date? = nil, weekStart: Date? = nil, weekEnd: Date? = nil,
        schedule: WeeklySchedule? = AdvisorFixtures.saturday, window: Double = 0, windowLow: Double = 0, clearsAt: Date? = nil,
        exact: Bool = false, blocked: Date? = nil, reason: String? = nil, calibration: Calibration = .defaults,
        now: Date = AdvisorFixtures.now
    ) -> UsageForecast {
        let end = weekEnd ?? A.personalReset
        return UsageForecast(
            profileID: "personal", reading: nil, schedule: schedule, weekUsed: Estimate(value: used, low: low, high: high, basis: basis),
            headroom: Estimate(value: 100 - used, low: 100 - high, high: 100 - low, basis: basis), paceWeek: pace, paceRecent: nil, pace: pace,
            projectedAtReset: projected.map { Estimate(value: $0, low: low, high: $0 + 10, basis: basis) }, runOutAt: runOut,
            waste: projected.map { Int((100 - $0).rounded()) }, weekStart: weekStart ?? end.addingTimeInterval(-WeeklySchedule.period),
            weekEnd: schedule == nil ? nil : end, window: nil, windowUsed: Estimate(value: window, low: windowLow, high: window, basis: .recorded),
            windowClearsAt: clearsAt, windowExact: exact, committedWeek: 0, committedWindow: 0, commitments: [],
            blockedUntil: blocked, blockReason: reason, timeline: UsageTimeline(windows: [], segments: [], cycles: [], limitHit: 0, limitHitOf: 0),
            calibration: calibration, plan: .max20x, stale: false, activityKnown: true,
            latestWeekly: latest.map { UsageTimeline.Point(at: pdt($0.0), value: $0.1) }, anchors: [])
    }

    // MARK: - The forecast line

    /// Every branch, at its widest (a two-digit hour on another day, 100 %), keeps the rule.
    func testForecastLineIsAtMost40CharactersWithHedgeInFirst32() {
        let now = A.now
        let clock = A.clock()
        let wed = pdt("2026-10-07 12:00"), wedLate = pdt("2026-10-07 23:59")
        let cases: [(UsageForecast, ActivityIndexState, String)] = [
            (forecast(), .building, "Reading activity\u{2026}"),
            (forecast(used: 0, low: 0, high: 100, basis: .defaults), ready, "No usage recorded yet (default)"),
            (forecast(blocked: wed, reason: "Sonnet limit"), ready, "Sonnet limit reached \u{2014} until Wed 12 PM"),
            (forecast(used: 100, low: 100, high: 100, weekEnd: wed, schedule: WeeklySchedule.infer(samples: [], anchors: [
                LimitAnchor(resetsAt: wed, kind: .sevenDay, hitAt: now.addingTimeInterval(-3600))], now: now)),
             ready, "Week limit reached \u{2014} resets Wed 12 PM"),
            (forecast(used: 100, low: 100, high: 100, weekEnd: wedLate, schedule: WeeklySchedule.infer(samples: F.personal(through: now), now: now)),
             ready, "Limit reached \u{2014} resets (est.) Thu 12 AM"),
            (forecast(window: 100, windowLow: 100, clearsAt: pdt("2026-10-06 00:10"), exact: true), ready, "5h window full \u{2014} clears Tue 12:10 AM"),
            (forecast(window: 100, windowLow: 70, clearsAt: pdt("2026-10-06 00:10"), exact: true), ready, "5h full (est.) \u{2014} clears Tue 12:10 AM"),
            (forecast(window: 100, clearsAt: pdt("2026-10-06 00:10")), ready, "5h full (est.) \u{2014} clears by Tue 12:10 AM"),
            (forecast(basis: .recordedNoSchedule, schedule: nil), ready, "Reset time not known yet (est.)"),
            (forecast(basis: .insufficient("no reset observed yet"), schedule: nil), ready, "Reset time not known yet (est.)"),
            (forecast(used: 99.6, low: 94, high: 100), ready, "~100% used (est.) \u{00B7} likely at the limit"),
            (forecast(used: 99, low: 94, latest: ("2026-10-03 19:48", 94)), ready, "~99% now (est.) \u{00B7} recorded 94% 46 h ago"),
            (forecast(used: 99, low: 94, latest: ("2026-10-05 17:00", 94)), ready, "~99% now (est.) \u{00B7} recorded 94% 1 h ago"),
            (forecast(used: 99, low: 0, basis: .activityOnly), ready, "~99% now (est.) \u{00B7} not recorded this week"),
            (forecast(used: 9, pace: nil, projected: nil, weekStart: now.addingTimeInterval(-11.9 * 3600)), ready,
             "Too early to tell \u{2014} 11 h into the week"),
            (forecast(used: 9, pace: nil, projected: nil), ready, "~9% used (est.) \u{00B7} little use this week"),
            (forecast(used: 98, projected: 140, runOut: pdt("2026-10-07 23:00")), ready, "~98% used (est.) \u{00B7} out about Wed night"),
            (forecast(used: 58, projected: 140, runOut: pdt("2026-10-05 22:00")), ready, "~58% used (est.) \u{00B7} out about tonight"),
            (forecast(used: 0, low: 0, projected: 0, weekEnd: wed), ready, "~100% unused by Wed 12 PM (est.)"),
            (forecast(used: 40, projected: 69, weekEnd: pdt("2026-10-10 20:13")), ready, "~31% unused by Sat 9 PM (est.)"),
        ]
        for (f, state, expected) in cases {
            let line = ForecastText.line(f, indexState: state, clock: clock)
            XCTAssertEqual(line, expected)
            XCTAssertLessThanOrEqual(line.count, ForecastText.maximumLength, line)
            XCTAssertTrue(ForecastText.keepsTheRule(line), line)
        }
        // Every line that shows an estimate carries the hedge.
        for (f, state, _) in cases where state == ready {
            let line = ForecastText.line(f, indexState: state, clock: clock)
            if line.contains("~") || line.contains("by ") || line.contains("not known") {
                XCTAssertTrue(ForecastText.hedges.contains { line.contains($0) }, line)
            }
        }
        XCTAssertFalse(ForecastText.keepsTheRule("recorded 0% 32 h ago \u{00B7} ~62% now (est.)"), "the hedge ends at 38")
    }

    /// In the small hours "today" is still the night that began the evening before: at 2:16 AM
    /// on Tuesday a 4:02 AM run-out is tonight — not "Mon night", a time already past — 7 AM is
    /// this morning, and 3 AM on Wednesday is Tuesday night.
    func testCoarseInTheSmallHoursSaysTonight() {
        let now = pdt("2026-10-06 02:16")
        let clock = A.clock(now)
        XCTAssertEqual(clock.coarse(pdt("2026-10-06 04:02"), short: true), "tonight")
        XCTAssertEqual(clock.coarse(pdt("2026-10-06 07:00"), short: true), "this morn")
        XCTAssertEqual(clock.coarse(pdt("2026-10-06 19:00"), short: false), "this evening")
        XCTAssertEqual(clock.coarse(pdt("2026-10-06 23:00"), short: true), "Tue night")
        XCTAssertEqual(clock.coarse(pdt("2026-10-07 03:00"), short: true), "Tue night")
        XCTAssertEqual(ForecastText.line(forecast(used: 98, projected: 140, runOut: pdt("2026-10-06 04:02"), now: now), indexState: ready, clock: clock),
                       "~98% used (est.) \u{00B7} out about tonight")
        // From an evening, as before.
        let evening = A.clock(pdt("2026-10-05 20:00"))
        XCTAssertEqual(evening.coarse(pdt("2026-10-06 02:00"), short: true), "tonight")
        XCTAssertEqual(evening.coarse(pdt("2026-10-06 07:00"), short: false), "Tue morning")
    }

    // MARK: - The week row

    /// Claude Code recorded the reset five days ago and two earlier weeks agree: the row says the
    /// time without "(est.)", and the tooltip says where it comes from and what is assumed (A1).
    func testExactFreshScheduleDropsEstSuffixAndNamesSource() throws {
        let now = A.now
        let f = UsageForecast.make(profileID: "personal", samples: F.personal(through: now), activity: F.ledger14d("p", anchors: F.personalWeeklyAnchors),
                                   exact: nil, busySessions: [], costs: A.a15, now: now)
        let reading = try XCTUnwrap(f.reading)
        let week = try XCTUnwrap(reading.rows.first { $0.key == "sd" })
        XCTAssertEqual(UsageText.trailing(for: week, in: reading, time: A.clock().time), "resets Sat 9:00 PM \u{00B7} 33 h ago")
        let tooltip = ForecastText.tooltip(f, indexState: ready, running: false, clock: A.clock())
        XCTAssertTrue(tooltip.contains("Week resets Sat 9:00 PM \u{2014} Claude Code recorded this reset time when the weekly limit was hit on Sep 30 (2 earlier weeks agree). Assumed to repeat weekly at the same time; a plan change would move it."), tooltip)
        XCTAssertFalse(tooltip.contains("the exact time is not recorded locally"))
        XCTAssertTrue(UsageText.summary(reading, time: A.clock().time).contains("week resets Sat 9:00 PM \u{00B7}"))
    }

    /// The only exact anchor is 35 days old: the time is exact but its repeat is an assumption,
    /// so "(est.)" stays and the tooltip says since when.
    func testOldAnchorKeepsEstSuffix() throws {
        let now = pdt("2026-09-25 12:00")
        let f = UsageForecast.make(profileID: "personal", samples: [UsageSample(sampledAt: pdt("2026-09-25 10:00"), org: "o", utilization: ["sd": 50])],
                                   activity: F.ledger([], anchors: [F.personalWeeklyAnchors[0]]), exact: nil, busySessions: [], costs: A.a15, now: now)
        let reading = try XCTUnwrap(f.reading)
        let week = try XCTUnwrap(reading.rows.first { $0.key == "sd" })
        XCTAssertEqual(UsageText.trailing(for: week, in: reading, time: A.clock(now).time), "resets Sat 9:00 PM (est.) \u{00B7} 2 h ago")
        let tooltip = ForecastText.tooltip(f, indexState: .ready(indexedThrough: now), running: false, clock: A.clock(now))
        XCTAssertTrue(tooltip.contains("Week resets Sat 9:00 PM (est.): assumed to repeat weekly since Claude Code last recorded it on Aug 21; nothing in the last two weeks confirms it."), tooltip)
        // A bracketed schedule says "resets by", always with "(est.)".
        let bracketed = UsageReading.make(samples: F.personal(through: pdt("2026-09-25 12:00")), now: pdt("2026-09-25 12:00"))!
        XCTAssertTrue(UsageText.trailing(for: bracketed.rows.first { $0.key == "sd" }!, in: bracketed, time: A.clock(now).time)!.hasPrefix("resets by "))
    }

    /// VoiceOver hears the rows' suffix rule: a recorded time plainly, every other "estimated" —
    /// "by" its latest moment when only bracketed.
    func testAccessibilityTextFollowsTheSuffixRule() {
        let clock = A.clock()
        let end = pdt("2026-10-05 21:10"), reset = A.personalReset
        let rows = [UsageReading.Row(key: "fh", label: "5h", value: .percent(44)), UsageReading.Row(key: "sd", label: "week", value: .percent(58))]
        func sentence(window: SessionWindow, week: WeeklyReset) -> String {
            let reading = UsageReading(sampledAt: A.now, age: 0, rows: rows, session: window, weekly: week, unlisted: [:])
            return UsageText.accessibilityText(reading, profileLabel: "Personal", time: clock.time)
        }
        let exactWindow = SessionWindow(utilization: 44, resetsAfter: pdt("2026-10-05 19:00"), resetsBy: end, exactEnd: end)
        let estimatedWindow = SessionWindow(utilization: 44, resetsAfter: pdt("2026-10-05 19:00"), resetsBy: end)
        let fresh = WeeklyReset(resetsAfter: reset, resetsBy: reset, isFresh: true)
        let exactNotFresh = WeeklyReset(resetsAfter: reset, resetsBy: reset, isFresh: false)
        let bracketed = WeeklyReset(resetsAfter: reset.addingTimeInterval(-3600), resetsBy: reset)
        XCTAssertEqual(sentence(window: exactWindow, week: fresh),
                       "Personal usage: 5h 44 percent, week 58 percent, reset at 9:10 PM, week reset at Sat 9:00 PM")
        XCTAssertEqual(sentence(window: estimatedWindow, week: exactNotFresh),
                       "Personal usage: 5h 44 percent, week 58 percent, estimated reset by 9:10 PM, estimated week reset at Sat 9:00 PM")
        XCTAssertEqual(sentence(window: estimatedWindow, week: bracketed),
                       "Personal usage: 5h 44 percent, week 58 percent, estimated reset by 9:10 PM, estimated week reset by Sat 9:00 PM")

        // A five-hour limit hit Claude Code recorded after the sampled window had ended: the row
        // is 100 %, recorded, and its end said plainly — never "5h ended" beside a line that
        // says the window is full.
        let afterHit = pdt("2026-10-06 00:31")
        let hit = LimitAnchor(resetsAt: pdt("2026-10-06 02:10"), kind: .fiveHour, hitAt: pdt("2026-10-06 00:26"))
        let full = UsageReading.make(samples: [UsageSample(sampledAt: pdt("2026-10-05 18:00"), org: "o", utilization: ["fh": 30, "sd": 58])],
                                     anchors: [hit], now: afterHit)!
        XCTAssertEqual(UsageText.accessibilityText(full, profileLabel: "Personal", time: A.clock(afterHit).time),
                       "Personal usage: 5h 100 percent, week 58 percent, reset at 2:10 AM, 6 h ago")
    }

    /// The bars draw more than was recorded — a lighter segment up to the estimate, and the end
    /// of a window only this Mac's activity shows — and VoiceOver hears it, by the suffix rule:
    /// recorded 0 %, estimated 40 %.
    func testAccessibilityTextSaysTheEstimate() {
        let clock = A.clock()
        let rows = [UsageReading.Row(key: "fh", label: "5h", value: .percent(0)), UsageReading.Row(key: "sd", label: "week", value: .percent(58))]
        let reading = UsageReading(sampledAt: A.now, age: 0, rows: rows, session: nil,
                                   weekly: WeeklyReset(resetsAfter: A.personalReset, resetsBy: A.personalReset, isFresh: true), unlisted: [:])
        func f(exact: Bool, known: Bool = true) -> UsageForecast {
            UsageForecast(
                profileID: "personal", reading: reading, schedule: A.saturday, weekUsed: Estimate(value: 58, low: 58, high: 64, basis: .recorded),
                headroom: Estimate(value: 42, low: 36, high: 42, basis: .recorded), paceWeek: nil, paceRecent: nil, pace: nil,
                projectedAtReset: nil, runOutAt: nil, waste: nil, weekStart: nil, weekEnd: A.personalReset, window: nil,
                windowUsed: Estimate(value: 40, low: 0, high: 50, basis: .recordedPlusActivity), windowClearsAt: pdt("2026-10-05 22:10"),
                windowExact: exact, committedWeek: 0, committedWindow: 0, commitments: [], blockedUntil: nil, blockReason: nil,
                timeline: UsageTimeline(windows: [], segments: [], cycles: [], limitHit: 0, limitHitOf: 0), calibration: .defaults,
                plan: .max20x, stale: false, activityKnown: known, latestWeekly: nil, anchors: [])
        }
        XCTAssertEqual(ForecastText.accessibilityText(f(exact: false), profileLabel: "Personal", clock: clock),
                       "Personal usage: 5h 0 percent, estimated 40 percent, week 58 percent, estimated reset by 10:10 PM, week reset at Sat 9:00 PM")
        XCTAssertEqual(ForecastText.accessibilityText(f(exact: true), profileLabel: "Personal", clock: clock),
                       "Personal usage: 5h 0 percent, estimated 40 percent, week 58 percent, reset at 10:10 PM, week reset at Sat 9:00 PM")
        // Before activity is read nothing is drawn beyond the recording, and nothing is said.
        XCTAssertEqual(ForecastText.accessibilityText(f(exact: false, known: false), profileLabel: "Personal", clock: clock),
                       UsageText.accessibilityText(reading, profileLabel: "Personal", time: clock.time))
    }

    /// Personal at 18:47: nothing recorded in a five-hour window since Sunday, but this Mac's
    /// activity opened one at 5:10 PM — the row draws the estimate and says when that window ends,
    /// hedged. Before activity is read, the row says nothing it cannot know; a recorded window
    /// keeps its own note, and an exact end drops the hedge.
    func testEstimatedWindowRowSaysWhenItEnds() throws {
        let now = A.now
        let clock = A.clock()
        func row(_ f: UsageForecast) throws -> UsageReading.Row { try XCTUnwrap(f.reading?.rows.first { $0.key == "fh" }) }
        let ledger = F.ledger14d("p", anchors: F.personalWeeklyAnchors)
        let estimated = UsageForecast.make(profileID: "personal", samples: F.personal(through: now), activity: ledger, exact: nil,
                                           busySessions: [], costs: A.a15, now: now)
        XCTAssertEqual(try row(estimated).percent, 0)
        XCTAssertNotNil(estimated.estimatedPercent(for: "fh"))
        XCTAssertEqual(ForecastText.trailing(for: try row(estimated), forecast: estimated, clock: clock), "resets by 10:10 PM (est.)")

        let building = UsageForecast.make(profileID: "personal", samples: F.personal(through: now), activity: nil, exact: nil,
                                          busySessions: [], costs: A.a15, now: now)
        XCTAssertNil(ForecastText.trailing(for: try row(building), forecast: building, clock: clock))

        // The same forecast with the end recorded by Claude Code: said plainly. And with activity
        // not read (no estimate to draw): nothing, even though the window's end is known.
        func copy(_ f: UsageForecast, windowExact: Bool, activityKnown: Bool) -> UsageForecast {
            UsageForecast(
                profileID: f.profileID, reading: f.reading, schedule: f.schedule, weekUsed: f.weekUsed, headroom: f.headroom,
                paceWeek: f.paceWeek, paceRecent: f.paceRecent, pace: f.pace, projectedAtReset: f.projectedAtReset, runOutAt: f.runOutAt,
                waste: f.waste, weekStart: f.weekStart, weekEnd: f.weekEnd, window: f.window, windowUsed: f.windowUsed,
                windowClearsAt: f.windowClearsAt, windowExact: windowExact, committedWeek: f.committedWeek, committedWindow: f.committedWindow,
                commitments: f.commitments, blockedUntil: f.blockedUntil, blockReason: f.blockReason, timeline: f.timeline,
                calibration: f.calibration, plan: f.plan, stale: f.stale, activityKnown: activityKnown, latestWeekly: f.latestWeekly,
                anchors: f.anchors)
        }
        let reported = copy(estimated, windowExact: true, activityKnown: true)
        XCTAssertEqual(ForecastText.trailing(for: try row(reported), forecast: reported, clock: clock), "resets 10:10 PM")
        let unread = copy(estimated, windowExact: false, activityKnown: false)
        XCTAssertNotNil(unread.windowClearsAt)
        XCTAssertNil(ForecastText.trailing(for: try row(unread), forecast: unread, clock: clock))
        // A window that has already ended says nothing.
        XCTAssertNil(ForecastText.trailing(for: try row(estimated), forecast: estimated, clock: A.clock(pdt("2026-10-05 22:11"))))

        // A window with something recorded in it keeps the recorded note.
        let samples = F.personal(through: now) + [UsageSample(sampledAt: pdt("2026-10-05 18:00"), org: "org-personal", utilization: ["fh": 30, "sd": 60])]
        let recorded = UsageForecast.make(profileID: "personal", samples: samples, activity: ledger, exact: nil, busySessions: [], costs: A.a15, now: now)
        let reading = try XCTUnwrap(recorded.reading)
        XCTAssertEqual(ForecastText.trailing(for: try row(recorded), forecast: recorded, clock: clock),
                       UsageText.trailing(for: try row(recorded), in: reading, time: clock.time))
        XCTAssertNotNil(UsageText.trailing(for: try row(recorded), in: reading, time: clock.time))
    }

    /// The lighter part of a bar is a number the drawing does not print: the tooltip says what it
    /// is and gives it, labelled. Nothing drawn, nothing said.
    func testTooltipNamesTheLighterSegment() throws {
        let now = A.now
        let f = UsageForecast.make(profileID: "personal", samples: F.personal(through: now), activity: F.ledger14d("p", anchors: F.personalWeeklyAnchors),
                                   exact: nil, busySessions: [], costs: A.a15, now: now)
        let fh = try XCTUnwrap(f.estimatedPercent(for: "fh")), sd = try XCTUnwrap(f.estimatedPercent(for: "sd"))
        let tooltip = ForecastText.tooltip(f, indexState: ready, running: false, clock: A.clock())
        XCTAssertTrue(tooltip.contains("Lighter part of a bar: this Mac\u{2019}s activity since the last recording (est.) \u{2014} 5h ~\(fh)%, week ~\(sd)%."), tooltip)
        let building = UsageForecast.make(profileID: "personal", samples: F.personal(through: now), activity: nil, exact: nil,
                                          busySessions: [], costs: A.a15, now: now)
        XCTAssertFalse(ForecastText.tooltip(building, indexState: .building, running: false, clock: A.clock()).contains("Lighter part"))
    }

    /// A2: the 09-22 grant reset, not yet confirmed — the tooltip says it is treated as a
    /// one-off, and the week row keeps "(est.)".
    func testUnconfirmedResetIsShownAndRestoresTheHedge() throws {
        let now = pdt("2026-09-23 12:00")
        let f = UsageForecast.make(profileID: "personal", samples: F.personal(through: now),
                                   activity: F.ledger([], anchors: Array(F.personalWeeklyAnchors.prefix(1))), exact: nil, busySessions: [],
                                   costs: A.a15, now: now)
        XCTAssertNotNil(f.schedule?.unconfirmedPhase)
        let tooltip = ForecastText.tooltip(f, indexState: .ready(indexedThrough: now), running: false, clock: A.clock(now))
        XCTAssertTrue(tooltip.contains("is treated as a one-off and unconfirmed"), tooltip)
        let reading = try XCTUnwrap(f.reading)
        XCTAssertTrue(UsageText.trailing(for: reading.rows.first { $0.key == "sd" }!, in: reading, time: A.clock(now).time)!.contains("(est.)"))
        XCTAssertTrue(DiagnosticsText.schedule(f, clock: A.clock(now)).contains("unconfirmed reset at Tue 19:"), DiagnosticsText.schedule(f, clock: A.clock(now)))
    }

    /// Christy on Thu 09-24 12:00: the Sep 20 anchor is four days old — recent — but the grant at
    /// 10:01–10:16 is an unconfirmed reset at another time. The hedge is back for that reason,
    /// and the words say so: not "older than 14 days", not "nothing in the last two weeks
    /// confirms it". The footer says "estimated", as the week row does.
    func testUnconfirmedResetOnAFreshAnchorNamesTheCause() throws {
        let now = pdt("2026-09-24 12:00")
        let f = UsageForecast.make(profileID: "christy", samples: F.christy(through: now), activity: F.ledger([], anchors: [F.christyWeeklyAnchors[0]]),
                                   exact: nil, busySessions: [], costs: A.a15, now: now)
        let schedule = try XCTUnwrap(f.schedule)
        XCTAssertNotNil(schedule.unconfirmedPhase)
        XCTAssertFalse(schedule.isFresh(now: now))
        let clock = A.clock(now)
        let tooltip = ForecastText.tooltip(f, indexState: .ready(indexedThrough: now), running: false, clock: clock)
        XCTAssertTrue(tooltip.contains("Week resets Mon 5:00 AM (est.) \u{2014} recorded on Sep 20; a reset at another time (Thu 10:08 AM) is not confirmed yet"), tooltip)
        XCTAssertFalse(tooltip.contains("nothing in the last two weeks confirms it"), tooltip)
        let diagnostics = DiagnosticsText.schedule(f, clock: clock)
        XCTAssertTrue(diagnostics.contains("exact, unconfirmed reset (1 anchor; last hit Sep 20 17:55)"), diagnostics)
        XCTAssertFalse(diagnostics.contains("older than 14 days"), diagnostics)
        let footer = AdvisorText.footer(A.snapshot([f]), labels: A.labels, clock: clock)
        XCTAssertTrue(footer.contains { $0.hasPrefix("Reset times: Christy estimated") }, "\(footer)")
        let reading = try XCTUnwrap(f.reading)
        XCTAssertTrue(UsageText.trailing(for: reading.rows.first { $0.key == "sd" }!, in: reading, time: clock.time)!.contains("(est.)"))
        // Fifteen days on, with nothing newer, age is the cause again.
        let old = UsageForecast.make(profileID: "christy", samples: F.christy(through: now), activity: F.ledger([], anchors: [F.christyWeeklyAnchors[0]]),
                                     exact: nil, busySessions: [], costs: A.a15, now: pdt("2026-10-06 12:00"))
        XCTAssertTrue(DiagnosticsText.schedule(old, clock: A.clock(pdt("2026-10-06 12:00"))).contains("older than 14 days"))
    }

    /// The five-hour end is exact (a cached usage check said 9:10 PM) but "full" is 70 % recorded
    /// plus 33 points estimated from activity: the line keeps its hedge. A recorded hit does not.
    func testEstimatedFullWindowKeepsTheHedgeEvenWithAnExactEnd() {
        let now = pdt("2026-10-05 19:30")
        let exact = ExactUsage(accountID: "a", rateLimitTier: "default_claude_max_20x", fetchedAt: pdt("2026-10-05 18:47"),
                               fiveHourUtilization: 70, fiveHourResetsAt: pdt("2026-10-05 21:10"), sevenDayUtilization: 40,
                               sevenDayResetsAt: pdt("2026-10-10 21:00"))
        let calls = (0..<11).map { (at: pdt("2026-10-05 18:50").addingTimeInterval(Double($0) * 200), spend: 10.0) }
        let ledger = F.ledger(calls, anchors: F.personalWeeklyAnchors)
        let f = UsageForecast.make(profileID: "personal", samples: [UsageSample(sampledAt: pdt("2026-10-05 16:00"), org: "o", utilization: ["fh": 20, "sd": 30])],
                                   activity: ledger, exact: exact, busySessions: [], costs: A.a15, now: now)
        XCTAssertTrue(f.windowExact)
        XCTAssertEqual(f.windowUsed.value, 100)
        XCTAssertEqual(f.windowUsed.low, 70)
        XCTAssertEqual(ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "5h full (est.) \u{2014} clears 9:10 PM")
        XCTAssertTrue(DiagnosticsText.forecast(f, clock: A.clock(now)).contains("clears Mon 21:10 (end exact, fullness est.)"), DiagnosticsText.forecast(f, clock: A.clock(now)))

        // Claude Code recorded the five-hour limit hit: full is recorded, and so is the end.
        let hit = LimitAnchor(resetsAt: pdt("2026-10-05 21:10"), kind: .fiveHour, hitAt: pdt("2026-10-05 19:20"))
        let recorded = UsageForecast.make(profileID: "personal", samples: [UsageSample(sampledAt: pdt("2026-10-05 16:00"), org: "o", utilization: ["fh": 20, "sd": 30])],
                                          activity: F.ledger(calls, anchors: F.personalWeeklyAnchors + [hit]), exact: exact, busySessions: [],
                                          costs: A.a15, now: now)
        XCTAssertEqual(recorded.windowUsed.low, 100)
        XCTAssertEqual(ForecastText.line(recorded, indexState: .ready(indexedThrough: now), clock: A.clock(now)), "5h window full \u{2014} clears 9:10 PM")
        XCTAssertTrue(DiagnosticsText.forecast(recorded, clock: A.clock(now)).contains("clears Mon 21:10 (exact)"))
    }

    /// A fresh cached usage body times both resets exactly, but nothing was refused: the words
    /// say the CLI's usage check reported them, never that a limit was hit. The week row still
    /// drops "(est.)" (exact and fresh); the limits line still says no limit hit is recorded.
    func testCachedBodyIsNotCalledALimitHit() throws {
        let now = pdt("2026-10-05 19:00")
        let exact = ExactUsage(accountID: "a", rateLimitTier: "default_claude_max_20x", fetchedAt: pdt("2026-10-05 18:47"),
                               fiveHourUtilization: 44, fiveHourResetsAt: pdt("2026-10-05 21:10"), sevenDayUtilization: 58,
                               sevenDayResetsAt: pdt("2026-10-10 21:00"))
        let f = UsageForecast.make(profileID: "christy", samples: [UsageSample(sampledAt: pdt("2026-10-05 10:00"), org: "o", utilization: ["fh": 10, "sd": 50])],
                                   activity: F.ledger([(pdt("2026-10-05 18:55"), 5)]), exact: exact, busySessions: [], costs: A.a15, now: now)
        let clock = A.clock(now)
        let tooltip = ForecastText.tooltip(f, indexState: .ready(indexedThrough: now), running: false, clock: clock)
        XCTAssertTrue(tooltip.contains("Claude Code\u{2019}s usage check at 6:47 PM reported the 5-hour window ends at 9:10 PM."), tooltip)
        XCTAssertTrue(tooltip.contains("Week resets Sat 9:00 PM \u{2014} reported by Claude Code\u{2019}s usage check at 6:47 PM."), tooltip)
        XCTAssertFalse(tooltip.contains("limit was hit"), tooltip)
        XCTAssertEqual(f.window?.exactEndFromCache, true)
        let schedule = DiagnosticsText.schedule(f, clock: clock)
        XCTAssertTrue(schedule.contains("exact (cached usage at Oct 5 18:47)"), schedule)
        XCTAssertFalse(schedule.contains("last hit"), schedule)
        XCTAssertEqual(DiagnosticsText.limits(f, clock: clock), "no limit hit recorded \u{00B7} (A7)")
        let reading = try XCTUnwrap(f.reading)
        XCTAssertEqual(UsageText.trailing(for: reading.rows.first { $0.key == "sd" }!, in: reading, time: clock.time), "resets Sat 9:00 PM",
                       "exact and fresh: no suffix")
        // A transcript hit naming the same reset is a hit, and outranks the cached report.
        let hit = LimitAnchor(resetsAt: pdt("2026-10-10 21:00"), kind: .sevenDay, hitAt: pdt("2026-10-05 18:50"))
        let both = UsageForecast.make(profileID: "christy", samples: [UsageSample(sampledAt: pdt("2026-10-05 10:00"), org: "o", utilization: ["fh": 10, "sd": 50])],
                                      activity: F.ledger([(pdt("2026-10-05 18:55"), 5)], anchors: [hit]), exact: exact, busySessions: [],
                                      costs: A.a15, now: now)
        XCTAssertEqual(both.schedule?.source, .exact(anchors: 1, lastHitAt: pdt("2026-10-05 18:50"), recordedBy: .transcript))
    }

    /// "~X% now (est.) · recorded Y% … ago" replaces the plain line once the estimate is 5 points
    /// above the recorded value and the sample is an hour old — not at 4.9 points or 59 minutes.
    func testRecordedLineSwitchesAtFivePointsAndAnHour() {
        let twoHours = "2026-10-05 16:47", hour = "2026-10-05 17:47", almost = "2026-10-05 17:48"
        XCTAssertEqual(ForecastText.line(forecast(used: 44.9, low: 40, latest: (twoHours, 40)), indexState: ready, clock: A.clock()),
                       "~20% unused by Sat 9 PM (est.)")
        XCTAssertEqual(ForecastText.line(forecast(used: 45, low: 40, latest: (twoHours, 40)), indexState: ready, clock: A.clock()),
                       "~45% now (est.) \u{00B7} recorded 40% 2 h ago")
        XCTAssertEqual(ForecastText.line(forecast(used: 50, low: 40, latest: (almost, 40)), indexState: ready, clock: A.clock()),
                       "~20% unused by Sat 9 PM (est.)")
        XCTAssertEqual(ForecastText.line(forecast(used: 50, low: 40, latest: (hour, 40)), indexState: ready, clock: A.clock()),
                       "~50% now (est.) \u{00B7} recorded 40% 1 h ago")
    }

    func testDefaultsCarryDefaultSuffix() {
        let now = A.now
        let f = UsageForecast.make(profileID: "personal", samples: [], activity: .empty(indexedThrough: now), exact: nil, busySessions: [],
                                   costs: .defaults, now: now)
        XCTAssertTrue(ForecastText.line(f, indexState: ready, clock: A.clock()).hasSuffix("(default)"))
        let calibration = DiagnosticsText.calibration(f, costs: .defaults)
        XCTAssertTrue(calibration.hasPrefix("0.074 pts per unit (default) \u{00B7} window 0.30 (default) \u{00B7} plan: unknown (defaults assume Max 20x, A5)"), calibration)
        XCTAssertTrue(calibration.contains("short 0.4/1.0 default"), calibration)
        XCTAssertTrue(calibration.hasSuffix("(p50/p75 week points, defaults; A15)"), calibration)
        XCTAssertEqual(AdvisorText.costsSummary(.defaults), "Costs are defaults for Max 20x \u{2014} fewer than 8 sessions of each size recorded")
        let footer = AdvisorText.footer(A.snapshot([f], costs: .defaults), labels: A.labels, clock: A.clock())
        XCTAssertTrue(footer.contains("Costs are defaults for Max 20x; Personal\u{2019}s plan is unknown"), "\(footer)")
        XCTAssertTrue(footer.contains("Reset times: Personal not known yet \u{00B7} usage last recorded never"), "\(footer)")
    }

    /// "1 earlier week agrees", "2 earlier weeks agree"; "±1 point", "±2 points".
    func testScheduleLinePlurals() {
        let now = A.now
        let two = UsageForecast.make(profileID: "personal", samples: F.personal(through: now),
                                     activity: F.ledger14d("p", anchors: Array(F.personalWeeklyAnchors.suffix(2))), exact: nil,
                                     busySessions: [], costs: A.a15, now: now)
        let line = ForecastText.scheduleLine(two, clock: A.clock())
        XCTAssertTrue(line.contains("(1 earlier week agrees)"), line)
        func calibrated(_ rmse: Double) -> Calibration {
            Calibration(weekly: 0.072, window: 0.35, rmse: rmse, segments: 3, medianR2: 0.999, windows: 9)
        }
        XCTAssertTrue(ForecastText.costsLine(forecast(calibration: calibrated(1.2))).hasSuffix("(3 segments, fit 1.00, \u{00B1}1 point)"))
        XCTAssertTrue(ForecastText.costsLine(forecast(calibration: calibrated(2.4))).hasSuffix("(3 segments, fit 1.00, \u{00B1}2 points)"))
    }

    /// The account's costs are the user's own (the first footer line says so) but its
    /// calibration is a default: the footer says that, not that the costs are defaults.
    func testFooterDoesNotCallOwnCostsDefaults() {
        func own(_ cost: SessionCosts.Cost, _ episodes: Int) -> SessionCosts.Cost {
            .init(whole: cost.whole, fitWeek: cost.fitWeek, fitWindow: cost.fitWindow, episodes: episodes)
        }
        let costs = SessionCosts(short: own(A.a15.short, 65), medium: own(A.a15.medium, 17), long: own(A.a15.long, 27))
        let unknown = A.forecast("personal", headroom: 40, waste: -10, plan: .unknown)
        XCTAssertTrue(unknown.calibration.weeklyIsDefault)
        let footer = AdvisorText.footer(A.snapshot([unknown], costs: costs), labels: A.labels, clock: A.clock())
        XCTAssertEqual(footer.first, "Costs from your last 30 days (short 65, medium 17, long 27 sessions)")
        XCTAssertTrue(footer.contains("Personal\u{2019}s calibration uses defaults for Max 20x; its plan is unknown"), "\(footer)")
        XCTAssertFalse(footer.contains { $0.hasPrefix("Costs are defaults") }, "\(footer)")
        let pro = A.forecast("personal", headroom: 40, waste: -10, plan: .named("claude_pro"))
        XCTAssertTrue(AdvisorText.footer(A.snapshot([pro], costs: costs), labels: A.labels, clock: A.clock())
            .contains("Personal\u{2019}s calibration uses defaults for Max 20x; its plan is claude_pro"))
        // A calibrated account says nothing about defaults.
        let calibrated = A.forecast("personal", headroom: 40, waste: -10, calibration: Calibration(weekly: 0.072, window: 0.35, rmse: 1,
                                                                                                 segments: 3, medianR2: 0.99, windows: 9), plan: .unknown)
        XCTAssertFalse(AdvisorText.footer(A.snapshot([calibrated], costs: costs), labels: A.labels, clock: A.clock()).contains { $0.contains("defaults") })
    }

    /// A trip of the scale gate under 3× (and over ⅓×) is called what it most likely is — an
    /// unusual sample — not a plan change; Diagnostics says where it tripped and from when medium
    /// and long are held back.
    func testDiagnosticsCallASmallTripAnUnusualSample() {
        func flagged(_ flag: String, _ ratio: Double) -> UsageForecast {
            A.forecast("personal", headroom: 40, waste: -10, calibration: Calibration(
                weekly: Calibration.defaultWeekly, window: Calibration.defaultWindow, rmse: 3, segments: 0, medianR2: nil, windows: 0,
                flag: flag, tripRatio: ratio))
        }
        let unusual = flagged(Calibration.unusualSampleFlag, 0.47)
        let diagnostics = DiagnosticsText.calibration(unusual, costs: A.a15)
        XCTAssertTrue(diagnostics.hasPrefix("0.074 pts per unit (default \u{2014} recalibrating after an unusual sample; tripped at 0.5\u{00D7}; medium and long held back only from 3\u{00D7}, A5)"), diagnostics)
        XCTAssertEqual(ForecastText.costsLine(unusual), "Costs are weighted from token counts at list prices, using defaults while it recalibrates after an unusual sample")
        XCTAssertFalse(ForecastText.tooltip(unusual, indexState: ready, running: false, clock: A.clock()).contains("plan may have changed"))
        let changed = flagged(Calibration.planChangedFlag, 4)
        XCTAssertTrue(DiagnosticsText.calibration(changed, costs: A.a15)
            .contains("(default \u{2014} plan may have changed \u{2014} recalibrating; tripped at 4.0\u{00D7}; medium and long held back only from 3\u{00D7}, A5)"))
        XCTAssertTrue(ForecastText.costsLine(changed).hasSuffix("disagrees with the calibration; the plan may have changed"))
    }

    // MARK: - Diagnostics

    func testDiagnosticsLinesForTheRealRegime() throws {
        let now = A.now
        let f = UsageForecast.make(profileID: "personal", samples: F.personal(through: now), activity: F.ledger14d("p", anchors: F.personalWeeklyAnchors),
                                   exact: nil, busySessions: [], costs: A.a15, now: now)
        let clock = A.clock()
        let forecast = DiagnosticsText.forecast(f, clock: clock)
        XCTAssertTrue(forecast.hasPrefix("week ~\(pct(f.weekUsed.value))% used (0\u{2013}\(pct(f.weekUsed.high)), est.) \u{00B7} pace "), forecast)
        XCTAssertTrue(forecast.contains("runs out about"), forecast)
        XCTAssertEqual(DiagnosticsText.schedule(f, clock: clock),
                       "week resets Sat 21:00 (Sun 04:00 UTC) \u{2014} exact, fresh (3 anchors; last hit Sep 30 08:12) (A1, A8) \u{00B7} out-of-order samples 0 \u{00B7} 5h window: 10-min floor assumed (A3)")
        let calibration = DiagnosticsText.calibration(f, costs: A.a15)
        XCTAssertTrue(calibration.hasPrefix("0.072 pts per unit (3 segments, median fit 1.00, \u{00B1}1.0) \u{00B7} window 0.35 (n=9)"), calibration)
        XCTAssertEqual(DiagnosticsText.limits(f, clock: clock), "Weekly limit hit Sep 30 08:12, resets Oct 3 21:00 (past) \u{00B7} limit reached 2 of last 4 weeks \u{00B7} (A7)")
        XCTAssertEqual(DiagnosticsText.accountLines(f, costs: A.a15, clock: clock).map { String($0.prefix(20)) },
                       ["    forecast:       ", "    schedule:       ", "    calibration:    ", "    limits:         "])
    }

    /// The ADVISOR section shows counts and labels — never a session's title, prompt or folder.
    func testDiagnosticsAdvisorSectionShowsCountsNotTitles() throws {
        let f = try ActivityFixture()
        let cli = "c1c1c1c1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        try f.record(cli, in: f.storeA, title: "Secret plan for the merger")
        try f.transcript(cli, [ActivityFixture.prompt(at: f.now.addingTimeInterval(-3000), text: "Draft the secret merger memo"),
                               ActivityFixture.assistant("1", at: f.now.addingTimeInterval(-2900), session: cli)])
        let refresh = f.refresh()
        let profiles = f.profiles
        let snapshot = UsageSnapshot.make(profiles: profiles, samples: [:], exact: [:], activity: refresh.ledgers,
                                          indexState: .ready(indexedThrough: f.now), previous: [:], busy: [:], now: f.now)
        let labels = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.label) })
        let section = DiagnosticsText.advisorSection(snapshot, labels: labels, summary: refresh.summary, clock: A.clock(f.now))
        let text = section.joined(separator: "\n")
        XCTAssertEqual(section.first, "ADVISOR")
        XCTAssertEqual(section.count, 1 + 3 + 1 + 1 + 1)
        XCTAssertTrue(section[1].hasPrefix("  short   \u{2192} "), section[1])
        XCTAssertTrue(text.contains("activity index: 1 account, 1 transcripts, read through 2026-10-05 18:47, 0.0% of spend unattributed (A6), 0 unpriced calls"), text)
        XCTAssertTrue(text.contains("(A1)") && text.contains("(A3)") && text.contains("(A4)") && text.contains("(A5)") && text.contains("(A9)"))
        for secret in ["Secret", "secret", "merger", cli, "c1c1c1c1", "/Users/me"] { XCTAssertFalse(text.contains(secret), secret) }
        XCTAssertTrue(DiagnosticsText.advisorSection(A.snapshot([]), labels: [:], summary: nil, clock: A.clock()).isEmpty, "no accounts, no section")
    }

    /// `--dry-run` never scans: without an index it says so instead of advising.
    func testDryRunAdviceNeedsTheIndex() {
        let personal = A.forecast("personal", headroom: 40, waste: 30)
        let building = A.snapshot([personal], indexState: .building)
        XCTAssertEqual(DiagnosticsText.dryRunAdvice(building, labels: A.labels, clock: A.clock()), ["advice: needs the activity index (built when the app runs)"])
        var advice: [SessionSize: Advice] = [:]
        for size in SessionSize.allCases { advice[size] = A.advise(size, [personal, A.forecast("christy", headroom: 90, waste: -10)]) }
        let lines = DiagnosticsText.dryRunAdvice(A.snapshot([personal, A.forecast("christy", headroom: 90, waste: -10)], advice: advice),
                                                 labels: A.labels, clock: A.clock())
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "advice:")
        XCTAssertEqual(lines[1], "  short   \u{2192} Personal   ~30% would go unused at its Sat 9 PM reset (est.); Christy is projected to run out")
    }

    // MARK: - The submenu

    func testSubmenuRowsAndFooter() {
        let personal = A.forecast("personal", headroom: 28, waste: -60)
        let christy = A.forecast("christy", headroom: 92, waste: nil)
        var advice: [SessionSize: Advice] = [:]
        for size in SessionSize.allCases { advice[size] = A.advise(size, [personal, christy]) }
        let menu = AdvisorText.menu(A.snapshot([personal, christy], advice: advice), labels: A.labels, clock: A.clock())
        XCTAssertNil(menu.placeholder)
        XCTAssertEqual(menu.rows.map(\.title), ["Short \u{2014} under an hour \u{2192} Christy", "Medium \u{2014} 1 to 3 hours \u{2192} Christy",
                                                "Long \u{2014} over 3 hours or a workflow run \u{2192} Christy"])
        XCTAssertEqual(menu.rows[0].reason, "most headroom (~92% left, est.); Personal is projected to run out")
        XCTAssertEqual(menu.rows[2].reason, "most headroom (~92% left, est.); Personal fits the first 3 h only (~28% of the week left, est.)")
        XCTAssertTrue(menu.rows.allSatisfy { $0.isEnabled && $0.profileID == "christy" })
        XCTAssertTrue(menu.rows[0].tooltip.contains("Based on the last recorded usage plus this Mac\u{2019}s activity since (est.)."))
        XCTAssertEqual(menu.footer, ["Costs are defaults for Max 20x \u{2014} fewer than 8 sessions of each size recorded",
                                     "Reset times: Personal exact, Christy exact \u{00B7} usage last recorded never / never"])
        XCTAssertEqual(AdvisorMenu.title, "Start a session in\u{2026}")
    }

    /// The reason names Personal for its thin margin; Personal's own clause does not follow it
    /// in the line (it would say the same account twice) — it stays in the tooltip, where it
    /// says more.
    func testReasonDoesNotNameTheSameAccountTwice() {
        let personal = A.forecast("personal", headroom: 9, waste: -50)
        let christy = A.forecast("christy", headroom: 100, waste: -10)
        let medium = A.advise(.medium, [personal, christy])
        XCTAssertEqual(A.reason(medium), .comfortableMargin(other: "personal", otherLeft: 9))
        let row = AdvisorText.row(medium, snapshot: A.snapshot([personal, christy], advice: [.medium: medium]), labels: A.labels, clock: A.clock())
        XCTAssertEqual(row.reason, "comfortable margin; Personal has only ~9% left (est.)")
        XCTAssertTrue(row.tooltip.contains("\nPersonal is projected to run out.\n"), row.tooltip)
    }

    /// The tooltip is the reason line, then the clauses the line does not already carry.
    func testTooltipDoesNotRepeatTheReasonsClause() {
        let personal = A.forecast("personal", headroom: 28, waste: -60)
        let christy = A.forecast("christy", headroom: 92, waste: nil)
        let short = A.advise(.short, [personal, christy])
        let row = AdvisorText.row(short, snapshot: A.snapshot([personal, christy]), labels: A.labels, clock: A.clock())
        XCTAssertEqual(row.reason, "most headroom (~92% left, est.); Personal is projected to run out")
        XCTAssertEqual(row.tooltip, "most headroom (~92% left, est.); Personal is projected to run out\n"
                       + "Based on the last recorded usage plus this Mac\u{2019}s activity since (est.).")
    }

    /// Personal is at its weekly limit and Christy's window has 5 % room: each account's own
    /// blocker is named — not "every 5-hour window is full" from the account that sets the next
    /// chance. One blocker for both is said once (testNothingFitsNamesTheNextChance).
    func testNothingFitsNamesEachAccountsBlocker() {
        let clears = pdt("2026-10-05 20:22")
        let personal = A.forecast("personal", headroom: 0, waste: -60)
        for (room, state) in [(5.0, "has too little room"), (0.0, "is full")] {
            let christy = A.forecast("christy", headroom: 60, waste: -10, room: room, clearsAt: clears)
            let medium = A.advise(.medium, [personal, christy])
            XCTAssertEqual(medium.outcome, .nothingFits(next: .init(at: clears, profileID: "christy", event: .windowClears, exact: false), why: .window))
            XCTAssertEqual(AdvisorText.reason(medium, snapshot: A.snapshot([personal, christy]), labels: A.labels, clock: A.clock()),
                           "Personal is at or near its weekly limit; Christy\u{2019}s 5-hour window \(state); next chance 8:22 PM (est.) when Christy\u{2019}s window clears")
        }
    }

    /// "Full" only when no room is left: 24 % is too little for a long session's first hour, not
    /// full. The room is the cautious one, labelled.
    func testWindowWithRoomIsNotCalledFull() {
        let clears = pdt("2026-10-05 20:22")
        let personal = A.forecast("personal", headroom: 40, waste: -10)
        let christy = A.forecast("christy", headroom: 60, waste: -10, room: 24, clearsAt: clears)
        let long = A.advise(.long, [personal, christy])
        XCTAssertEqual(long.profileID, "personal")
        let why = long.alternatives.first { $0.profileID == "christy" }?.why
        XCTAssertEqual(why, .windowFull(until: clears, roomLeft: 24, exact: false))
        func text(_ why: Advice.Why) -> String {
            AdvisorText.alternativeText(.init(profileID: "christy", why: why), labels: A.labels, snapshot: A.snapshot([christy]), clock: A.clock())
        }
        XCTAssertEqual(text(why!), "Christy\u{2019}s 5-hour window has too little room (~24% left, est.) until 8:22 PM (est.)")
        XCTAssertEqual(text(.windowFull(until: clears, roomLeft: 0, exact: false)), "Christy\u{2019}s 5-hour window is full until 8:22 PM (est.)")
        // Neither account's window has room enough, neither is full.
        let both = A.advise(.long, [A.forecast("personal", headroom: 40, waste: -10, room: 30, clearsAt: pdt("2026-10-05 21:00")), christy])
        XCTAssertEqual(AdvisorText.reason(both, snapshot: A.snapshot([personal, christy]), labels: A.labels, clock: A.clock()),
                       "no 5-hour window has enough room; next chance 8:22 PM (est.) when Christy\u{2019}s window clears")
        // A row that waits for a window with a little room left: not "full" either.
        let thin = A.forecast("christy", headroom: 0, waste: -90)
        for (room, words) in [(5.0, "its 5-hour window has too little room until then"), (0.0, "its 5-hour window is full until then")] {
            let waiting = A.forecast("personal", headroom: 60, waste: 40, room: room, clearsAt: A.now.addingTimeInterval(600))
            XCTAssertEqual(AdvisorText.reason(A.advise(.medium, [waiting, thin]), snapshot: A.snapshot([waiting, thin]), labels: A.labels,
                                              clock: A.clock()), words)
        }
    }

    /// A window clears at 8:22 PM: the next chance is 8:22 PM, as the bar note says — not "9 PM"
    /// (rounded up, as only a weekly reset is). An estimated time says so; a weekly reset from a
    /// schedule that is not exact and fresh too.
    func testNextChanceWindowTimeIsNotRoundedUp() {
        let clears = pdt("2026-10-05 20:22")
        let personal = A.forecast("personal", headroom: 0, waste: -60)
        for exact in [false, true] {
            let christy = A.forecast("christy", headroom: 60, waste: -10, room: 0, clearsAt: clears, windowExact: exact)
            let reason = AdvisorText.reason(A.advise(.medium, [personal, christy]), snapshot: A.snapshot([personal, christy]),
                                            labels: A.labels, clock: A.clock())
            XCTAssertTrue(reason.hasSuffix("; next chance 8:22 PM\(exact ? "" : " (est.)") when Christy\u{2019}s window clears"), reason)
        }
        let atLimit = A.forecast("christy", headroom: 0, waste: -40)
        XCTAssertTrue(AdvisorText.reason(A.advise(.long, [personal, atLimit]), snapshot: A.snapshot([personal, atLimit]), labels: A.labels,
                                         clock: A.clock()).hasSuffix("; next chance Sat 9 PM when Personal resets"))
        let old = WeeklySchedule.infer(samples: [], anchors: [F.personalWeeklyAnchors[0]], now: A.now)!
        XCTAssertFalse(old.isFresh(now: A.now))
        let estimated = A.forecast("personal", headroom: 0, waste: -60, schedule: old)
        XCTAssertTrue(AdvisorText.reason(A.advise(.long, [estimated, atLimit]), snapshot: A.snapshot([estimated, atLimit]), labels: A.labels,
                                         clock: A.clock()).hasSuffix("; next chance Sat 9 PM (est.) when Personal resets"))
    }

    /// Every window time the Advisor prints — a row's "after", a clause's "until", the next
    /// chance, Diagnostics' rows — carries "(est.)" unless Claude Code recorded it, as the
    /// account's own bar note does.
    func testEstimatedWindowTimesInAdvisorTextCarryEst() {
        let at = pdt("2026-10-05 21:00")
        let clock = A.clock(at)
        let thin = A.forecast("christy", headroom: 0, waste: -90)
        let ready = A.forecast("christy", headroom: 60, waste: 30)
        for exact in [false, true] {
            let waiting = A.forecast("personal", headroom: 60, waste: 40, room: 0, clearsAt: pdt("2026-10-05 21:10"), windowExact: exact)
            let later = A.forecast("personal", headroom: 60, waste: 40, room: 0, clearsAt: pdt("2026-10-05 21:40"), windowExact: exact)
            var texts: [String] = []
            for forecasts in [[waiting, thin], [waiting, ready], [later, thin]] {
                let advice = A.advise(.medium, forecasts, at: at)
                let snapshot = A.snapshot(forecasts, advice: [.medium: advice])
                let row = AdvisorText.row(advice, snapshot: snapshot, labels: A.labels, clock: clock)
                texts += [row.title, row.reason, row.tooltip] + DiagnosticsText.adviceRows(snapshot, labels: A.labels, clock: clock)
            }
            let all = texts.joined(separator: "\n")
            for time in ["9:10 PM", "9:40 PM", "21:10"] { XCTAssertTrue(all.contains(time), "\(time) in \(all)") }
            func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
            for text in texts {
                for time in ["9:10 PM", "9:40 PM", "21:10", "21:40"] {
                    // Every mention of the time is hedged, or none is.
                    XCTAssertEqual(count(time + " (est.)", in: text), exact ? 0 : count(time, in: text), "\(time): \(text)")
                }
            }
        }
    }

    /// The fit is on a long session's first three hours; the stall at the faster of the
    /// account's pace and a typical long session's. At 8.6 points and 2.93 an hour it stalls in
    /// about 2.9 hours: the reason does not say the first three hours fit.
    func testStallInsideThreeHoursDoesNotSayTheFirstThreeHoursFit() {
        let personal = A.forecast("personal", headroom: 8.6, waste: -20, pace: 2.93)
        let christy = A.forecast("christy", headroom: 5, waste: -60)
        let long = A.advise(.long, [personal, christy], costs: .defaults)
        guard case .start("personal", _, nil, let stall?) = long.outcome else { return XCTFail("\(long.outcome)") }
        XCTAssertEqual(stall.timeIntervalSince(A.now) / 3600, 8.6 / 2.93, accuracy: 0.01)
        let snapshot = A.snapshot([personal, christy], costs: .defaults)
        let row = AdvisorText.row(long, snapshot: snapshot, labels: A.labels, clock: A.clock())
        XCTAssertEqual(row.reason, "about the first 2 h fit; Christy keeps ~5% in reserve")
        let fast = A.advise(.long, [A.forecast("personal", headroom: 8.6, waste: -20, pace: 10), christy], costs: .defaults)
        XCTAssertEqual(AdvisorText.reason(fast, snapshot: snapshot, labels: A.labels, clock: A.clock()),
                       "likely stops within the first hour; Christy keeps ~5% in reserve")
    }

    // MARK: - Owner assumptions

    /// A1–A15, each where the design says the owner sees it.
    func testEveryOwnerAssumptionIsSurfaced() throws {
        let now = A.now
        let clock = A.clock()
        let busy = BusySession(cliSessionId: "busy")
        let ledger = ActivityLedger(
            sessions: F.ledger14d("p").sessions.merging(F.ledger([(now.addingTimeInterval(-4000), 5), (now.addingTimeInterval(-600), 5)], session: "busy").sessions) { $1 },
            anchors: F.personalWeeklyAnchors + [LimitAnchor(resetsAt: pdt("2026-10-03 21:00"), kind: .fable, hitAt: pdt("2026-10-01 09:05"))],
            indexedThrough: now, unattributedSpend: 10, coveredSince: pdt("2026-09-21 18:47"))
        let f = UsageForecast.make(profileID: "personal", samples: F.personal(through: now), activity: ledger, exact: nil, busySessions: [busy],
                                   costs: A.a15, now: now)
        let tooltip = ForecastText.tooltip(f, indexState: ready, running: true, clock: clock)
        let diagnostics = DiagnosticsText.accountLines(f, costs: A.a15, clock: clock).joined(separator: "\n")
        let summary = ActivityIndexSummary(accounts: 2, transcripts: 412, indexedThrough: now, coveredSince: pdt("2026-08-21 18:47"),
                                           attributedSpend: 990, unattributedSpend: 10, unpricedCalls: 0)
        let section = DiagnosticsText.advisorSection(A.snapshot([f]), labels: A.labels, summary: summary, clock: clock).joined(separator: "\n")

        // A1
        XCTAssertTrue(tooltip.contains("Assumed to repeat weekly at the same time; a plan change would move it"))
        XCTAssertTrue(diagnostics.contains("(A1, A8)") && section.contains("(A1)"))
        // A2 — see testUnconfirmedResetIsShownAndRestoresTheHedge.
        // A3
        XCTAssertTrue(tooltip.contains("Assumed: a 5-hour window starts at the first message, rounded down to 10 minutes."))
        XCTAssertTrue(diagnostics.contains("(A3)"))
        // A4
        XCTAssertTrue(tooltip.contains("Costs are weighted from token counts at list prices, calibrated to this account\u{2019}s own history (3 segments, fit 1.00, \u{00B1}1 point)"), tooltip)
        XCTAssertTrue(diagnostics.contains("median fit") && section.contains("(A4)"))
        // A5
        XCTAssertTrue(diagnostics.contains("plan: unknown (defaults assume Max 20x, A5)"))
        // A6
        XCTAssertTrue(section.contains("1.0% of spend unattributed (A6)"))
        // A7: limit hits by kind.
        XCTAssertTrue(diagnostics.contains("Fable limit hit Oct 1 09:05, resets Oct 3 21:00 (past)") && diagnostics.contains("Weekly limit hit Sep 30 08:12"), diagnostics)
        // A8: UTC beside local.
        XCTAssertTrue(diagnostics.contains("Sat 21:00 (Sun 04:00 UTC)"))
        // A9
        XCTAssertTrue(tooltip.contains("allowed for at 2 points/day"))
        XCTAssertTrue(section.contains("unseen use allowed at 2 points/day (A9)"))
        // A10: the row titles.
        XCTAssertEqual(SessionSize.allCases.map(\.title), ["Short \u{2014} under an hour", "Medium \u{2014} 1 to 3 hours", "Long \u{2014} over 3 hours or a workflow run"])
        // A11: the window keeps "(est.)" without an anchor; the Fable-only limit is not recorded.
        XCTAssertTrue(tooltip.contains("The Fable-only weekly limit is not recorded locally; Claude Code last reported it hit on Oct 1 (resets Sat 9 PM)."), tooltip)
        XCTAssertEqual(UsageText.windowReset(SessionWindow(utilization: 30, resetsAfter: now, resetsBy: pdt("2026-10-05 21:13")), time: clock.time),
                       "resets by 9:13 PM (est.)")
        // A12
        XCTAssertTrue(tooltip.contains("A short session is running here (~2% of the week still committed, est.)"), tooltip)
        // A13
        XCTAssertEqual(AdvisorText.reasonText(.resetsSoonest(resetBy: A.personalReset), chosen: nil, snapshot: A.snapshot([]), labels: A.labels, clock: clock),
                       "resets soonest (Sat 9 PM)")
        XCTAssertEqual(AdvisorText.reasonText(.comfortableMargin(other: "personal", otherLeft: 9), chosen: nil, snapshot: A.snapshot([]), labels: A.labels, clock: clock),
                       "comfortable margin; Personal has only ~9% left (est.)")
        // A14 — see UsageAdvisorTests.testLongFitsOnFirstThreeHoursAndReportsStall ("likely hits the limit about").
        // A15: the quantile and its source.
        XCTAssertTrue(diagnostics.contains("(p50/p75 week points, defaults; A15)"))
        // The right-click hint, for a running account whose last sample is over a day old.
        XCTAssertTrue(tooltip.contains("Right-clicking Claude\u{2019}s own menu-bar icon makes it record usage again."))
        XCTAssertEqual(DiagnosticsText.guarantee.contains("Nothing is written there, nothing is fetched, no token or cookie is read."), true)
    }
}
