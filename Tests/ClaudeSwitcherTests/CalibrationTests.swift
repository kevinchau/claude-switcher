import XCTest
@testable import ClaudeSwitcherCore

/// `k_w` and `k_f`: per-segment fits, their gates, the median, and the scale gate.
final class CalibrationTests: XCTestCase {

    private typealias F = UsageFixtures
    private func pdt(_ text: String) -> Date { F.pdt(text) }

    /// An account made to order: stretches of hourly samples whose weekly figure rises `k`
    /// points per unit of spend, each starting after a reset (a drop to 0).
    struct Synthetic {
        var samples: [UsageSample] = []
        var calls: [(at: Date, spend: Double)] = []
        var clock: Date

        init(start: Date) { clock = start }

        /// `hours` + 1 samples an hour apart, `spend` units spent in each hour, the figure at
        /// `k` points per unit (rounded, as Claude records it). `extra` adds recorded points with
        /// no spend before the sample at that hour (use the transcripts cannot see), `bulk`
        /// spends more in that hour.
        mutating func segment(k: Double, spend: Double, hours: Int = 11, extra: [Int: Int] = [:], bulk: [Int: Double] = [:]) {
            var total = 0.0
            var unseen = 0
            for hour in 0...hours {
                if hour > 0 {
                    let spent = bulk[hour] ?? spend
                    calls.append((clock.addingTimeInterval(-1800), spent))
                    total += spent
                }
                unseen += extra[hour] ?? 0
                samples.append(UsageSample(sampledAt: clock, org: "o", utilization: ["sd": min(100, Int((k * total).rounded()) + unseen)]))
                clock = clock.addingTimeInterval(3600)
            }
            clock = clock.addingTimeInterval(6 * 3600)
        }

        var ledger: ActivityLedger { UsageFixtures.ledger(calls) }

        func calibration(now: Date? = nil) -> Calibration {
            let moment = now ?? clock
            let timeline = UsageTimeline.build(samples: samples, activity: ledger, schedule: nil, now: moment)
            return Calibration.fit(timeline: timeline, activity: ledger, schedule: nil, now: moment)
        }
    }

    // MARK: - k_w

    /// Personal's 09-19 week: the Tue 09-22 grant reset the week at 94 %. Regressed across the
    /// grant, as a schedule-cut cycle would be, the fit is meaningless; cut at the drop, the
    /// grant's segment and the next week's both fit at about 0.07 points per unit.
    func testSegmentsCutAtEveryDrop() throws {
        let now = pdt("2026-10-05 18:47")
        let ledger = F.ledger14d("p", anchors: F.personalWeeklyAnchors)
        let samples = F.personal(through: now)
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: samples, anchors: F.personalWeeklyAnchors, now: now))
        let timeline = UsageTimeline.build(samples: samples, activity: ledger, schedule: schedule, now: now)
        let calibration = Calibration.fit(timeline: timeline, activity: ledger, schedule: schedule, now: now)
        XCTAssertFalse(calibration.weeklyIsDefault)
        // From the index's start (Sep 21 18:47) to the grant, the grant's two days, the next week.
        XCTAssertEqual(calibration.segments, 3)
        XCTAssertEqual(calibration.weekly, 0.072, accuracy: 0.003)
        XCTAssertGreaterThan(calibration.medianR2 ?? 0, 0.98)
        XCTAssertNil(calibration.flag)

        // The same samples cut at the schedule only: the week holding the grant does not fit.
        let covered = try XCTUnwrap(ledger.coveredSince)
        let grantWeek = try XCTUnwrap(timeline.cycles.first { $0.start == pdt("2026-09-19 21:00") })
        let points = grantWeek.points.filter { $0.value < 100 && $0.at >= covered }
        let fit = try XCTUnwrap(Calibration.fitSegment(points, activity: ledger))
        XCTAssertLessThan(fit.r2, Calibration.minimumR2)
        XCTAssertFalse(fit.qualifies)
    }

    /// Three segments at 0.05, 0.07 and 0.20 points per unit: k is their median, 0.07. A
    /// pooled fit would be pulled to the segment with the most spend (about 0.055).
    func testKIsMedianOfQualifyingSegments() {
        var account = Synthetic(start: pdt("2026-09-21 06:00"))
        account.segment(k: 0.05, spend: 70)
        account.segment(k: 0.07, spend: 36)
        account.segment(k: 0.20, spend: 14)
        let calibration = account.calibration()
        XCTAssertEqual(calibration.segments, 3)
        XCTAssertEqual(calibration.weekly, 0.07, accuracy: 0.002)
        XCTAssertNil(calibration.flag)
    }

    /// Once the week reads 100 the true figure is unknown (it is capped): those samples are left
    /// out, or spend past the limit would flatten the slope.
    func testSamplesAtTheLimitAreLeftOut() {
        var account = Synthetic(start: pdt("2026-09-21 06:00"))
        account.segment(k: 0.1, spend: 80, hours: 16)
        account.segment(k: 0.1, spend: 80, hours: 16)
        XCTAssertEqual(account.samples.filter { $0.utilization["sd"] == 100 }.count, 8, "the last four hours of each")
        let calibration = account.calibration()
        XCTAssertEqual(calibration.segments, 2)
        XCTAssertEqual(calibration.weekly, 0.1, accuracy: 0.001)
    }

    /// One segment is not a calibration; a segment that is too short, rises too little or
    /// fits badly does not count.
    func testCalibrationNeedsTwoSegmentsAndFit() {
        var account = Synthetic(start: pdt("2026-09-21 06:00"))
        account.segment(k: 0.07, spend: 36)
        XCTAssertTrue(account.calibration().weeklyIsDefault, "one segment")
        XCTAssertEqual(account.calibration().weekly, Calibration.defaultWeekly)
        account.segment(k: 0.07, spend: 50, hours: 8)
        XCTAssertTrue(account.calibration().weeklyIsDefault, "nine samples")
        account.segment(k: 0.07, spend: 20)
        XCTAssertTrue(account.calibration().weeklyIsDefault, "a rise of 15")
        account.segment(k: 0.07, spend: 36, extra: [1: 25])
        XCTAssertTrue(account.calibration().weeklyIsDefault, "25 points nobody spent: R² below 0.9")
        account.segment(k: 0.08, spend: 36)
        let calibration = account.calibration()
        XCTAssertEqual(calibration.segments, 2)
        XCTAssertEqual(calibration.weekly, 0.075, accuracy: 0.002)
        XCTAssertEqual(calibration.rmse, 0.3, accuracy: 0.3, "the rounding of the recorded figure")
    }

    /// Calibrated on a plan twenty times smaller (1.48 points per unit), the account moves to a
    /// Max 20x: 60 points predicted for one hour, 3 recorded. The calibration is for another
    /// plan — it drops to the defaults, flagged, and starts again from that sample.
    func testScaleGateDropsToDefaultsOnPlanChange() {
        var account = Synthetic(start: pdt("2026-09-21 06:00"))
        account.segment(k: 1.48, spend: 1.5)
        account.segment(k: 1.48, spend: 1.5)
        XCTAssertEqual(account.calibration().weekly, 1.48, accuracy: 0.03)
        account.segment(k: 1 / 13.5, spend: 40.5)
        let flagged = account.calibration()
        XCTAssertEqual(flagged.weekly, Calibration.defaultWeekly, "not the 20× slope")
        XCTAssertTrue(flagged.weeklyIsDefault)
        XCTAssertEqual(flagged.flag, Calibration.planChangedFlag)
        // The segments start again at that sample: one more week on the new plan calibrates it.
        account.segment(k: 1 / 13.5, spend: 40.5)
        let recalibrated = account.calibration()
        XCTAssertNil(recalibrated.flag)
        XCTAssertEqual(recalibrated.segments, 2)
        XCTAssertEqual(recalibrated.weekly, 1 / 13.5, accuracy: 0.003)
    }

    /// Use the transcripts cannot see adds to the recorded rise: 35 recorded against 20
    /// predicted is within twice the prediction, so the calibration stands.
    func testAdditiveUnseenUseDoesNotTripScaleGate() {
        var account = Synthetic(start: pdt("2026-09-21 06:00"))
        account.segment(k: 1 / 13.5, spend: 30)
        account.segment(k: 1 / 13.5, spend: 30)
        account.segment(k: 1 / 13.5, spend: 30, extra: [3: 15], bulk: [3: 270])
        let calibration = account.calibration()
        XCTAssertNil(calibration.flag)
        XCTAssertGreaterThanOrEqual(calibration.segments, 2)
        XCTAssertEqual(calibration.weekly, 1 / 13.5, accuracy: 0.004)
        // A small predicted rise is not tested at all: 1.5 predicted, 4 recorded (2.7×) is noise.
        account.segment(k: 1 / 13.5, spend: 20, hours: 30, extra: [5: 3])
        XCTAssertNil(account.calibration().flag)
    }

    /// The gate trips above twice the prediction, not at it: 150 units in an hour are 11 points
    /// at the calibrated weight; 20 recorded (1.8×) is use this Mac cannot see, 28 (2.5×) trips
    /// it — called an unusual sample, not a plan change, under the 3× at which the Advisor holds
    /// medium and long back (testSmallTripIsNotCalledAPlanChange).
    func testGateTripsOnlyAboveTwiceThePrediction() {
        func calibration(unseen: Int) -> Calibration {
            var account = Synthetic(start: pdt("2026-09-21 06:00"))
            account.segment(k: 1 / 13.5, spend: 30)
            account.segment(k: 1 / 13.5, spend: 30)
            // Hour 3 records 12 points for the 150 units (rounding) plus `unseen`.
            account.segment(k: 1 / 13.5, spend: 30, extra: [3: unseen], bulk: [3: 150])
            return account.calibration()
        }
        XCTAssertNil(calibration(unseen: 8).flag, "1.8×")
        let tripped = calibration(unseen: 16)
        XCTAssertEqual(tripped.flag, Calibration.unusualSampleFlag, "2.5×")
        XCTAssertTrue(tripped.weeklyIsDefault, "tripped all the same")
        XCTAssertEqual(tripped.tripRatio ?? 0, 28 / (150 / 13.5), accuracy: 0.1)
    }

    /// A trip is called a plan change only at 3× or more (or ⅓× or less) — the ratio at which
    /// the Advisor holds medium and long back — or after a re-anchor or a new tier; nearer 1× it
    /// is an unusual sample (on this Mac, 2.4× on Sep 21 and 0.47× on Sep 22, both use it could
    /// not see). Either way the calibration is dropped and starts again.
    func testSmallTripIsNotCalledAPlanChange() {
        func calibration(unseen: Int) -> Calibration {
            var account = Synthetic(start: pdt("2026-09-21 06:00"))
            account.segment(k: 1 / 13.5, spend: 30)
            account.segment(k: 1 / 13.5, spend: 30)
            // Hour 3: 150 units, 11.1 points predicted, 12 recorded plus `unseen`.
            account.segment(k: 1 / 13.5, spend: 30, extra: [3: unseen], bulk: [3: 150])
            return account.calibration()
        }
        for (unseen, flag, ratio) in [(16, Calibration.unusualSampleFlag, 2.5), (-7, Calibration.unusualSampleFlag, 0.45),
                                      (22, Calibration.planChangedFlag, 3.1)] {
            let tripped = calibration(unseen: unseen)
            XCTAssertTrue(tripped.weeklyIsDefault, "\(ratio)×")
            XCTAssertEqual(tripped.flag, flag, "\(ratio)×")
            XCTAssertEqual(tripped.tripRatio ?? 0, ratio, accuracy: 0.05)
        }
        // Under a third (3 recorded for 10.4 predicted): a plan change — testGateNeedsTenPredictedPoints.
    }

    /// Under ten predicted points a pair is not judged at all, however far off: 128 units (9.5
    /// points) with 2 recorded passes; 140 units (10.4) with 3 recorded trips.
    func testGateNeedsTenPredictedPoints() {
        func calibration(bulk: Double, unseen: Int) -> Calibration {
            var account = Synthetic(start: pdt("2026-09-21 06:00"))
            account.segment(k: 1 / 13.5, spend: 30)
            account.segment(k: 1 / 13.5, spend: 30)
            account.segment(k: 1 / 13.5, spend: 30, extra: [3: unseen], bulk: [3: bulk])
            return account.calibration()
        }
        XCTAssertNil(calibration(bulk: 128, unseen: -8).flag, "9.5 points predicted: too few to judge")
        let tripped = calibration(bulk: 140, unseen: -8)
        XCTAssertEqual(tripped.flag, Calibration.planChangedFlag, "10.4 predicted, 3 recorded")
        XCTAssertLessThan(tripped.tripRatio ?? 1, 0.5)
    }

    /// The trip drops the window weight with the weekly one: nine windows learnt at 0.6 window
    /// points per unit on the old plan no longer count, and eight on the new plan (1.2) are the
    /// new median.
    func testScaleGateAlsoDropsTheWindowWeight() {
        var samples: [UsageSample] = []
        var calls: [(at: Date, spend: Double)] = []
        var clock = pdt("2026-09-21 06:00")
        var sd = 0.0
        /// One five-hour window: five samples half an hour apart, `spend` units each half hour.
        func window(kw: Double, kf: Double, spend: Double) {
            var fh = 0.0
            for step in 0...4 {
                if step > 0 {
                    calls.append((clock.addingTimeInterval(-900), spend))
                    fh += kf * spend
                    sd += kw * spend
                }
                samples.append(UsageSample(sampledAt: clock, org: "o", utilization: ["fh": 1 + Int(fh.rounded()), "sd": Int(sd.rounded())]))
                clock = clock.addingTimeInterval(1800)
            }
            clock = clock.addingTimeInterval(6 * 3600)
        }
        func calibration() -> Calibration {
            let ledger = UsageFixtures.ledger(calls)
            let timeline = UsageTimeline.build(samples: samples, activity: ledger, schedule: nil, now: clock)
            return Calibration.fit(timeline: timeline, activity: ledger, schedule: nil, now: clock)
        }

        for _ in 0..<9 { window(kw: 1 / 13.5, kf: 0.6, spend: 5) }
        let before = calibration()
        XCTAssertEqual(before.windows, 9)
        XCTAssertEqual(before.window, 0.6, accuracy: 0.01)
        XCTAssertNil(before.flag)

        // The plan changes: 150 units in an hour, 11 points predicted, 44 recorded (4×).
        samples.append(UsageSample(sampledAt: clock, org: "o", utilization: ["sd": Int(sd.rounded())]))
        calls.append((clock.addingTimeInterval(1800), 150))
        clock = clock.addingTimeInterval(3600)
        sd += 4 / 13.5 * 150
        samples.append(UsageSample(sampledAt: clock, org: "o", utilization: ["sd": Int(sd.rounded())]))
        clock = clock.addingTimeInterval(6 * 3600)
        let tripped = calibration()
        XCTAssertEqual(tripped.flag, Calibration.planChangedFlag)
        XCTAssertEqual(tripped.tripRatio ?? 0, 4, accuracy: 0.1)
        XCTAssertTrue(tripped.windowIsDefault, "the window weight was learnt on the old plan too")
        XCTAssertEqual(tripped.window, Calibration.defaultWindow)

        for _ in 0..<8 { window(kw: 4 / 13.5, kf: 1.2, spend: 2) }
        let after = calibration()
        XCTAssertEqual(after.windows, 8, "only the new plan's windows")
        XCTAssertEqual(after.window, 1.2, accuracy: 0.03)
    }

    /// The gate restarts the segment at the tripping sample: six samples on the old plan, the
    /// trip, eleven more on a plan four times smaller — the one fit starts at the trip and is the
    /// new plan's.
    func testScaleGateRestartsTheSegmentAtTheTrip() throws {
        var account = Synthetic(start: pdt("2026-09-21 06:00"))
        var value = 0.0
        func sample() { account.samples.append(UsageSample(sampledAt: account.clock, org: "o", utilization: ["sd": Int(value.rounded())])) }
        func hour(_ spend: Double, k: Double) {
            account.clock = account.clock.addingTimeInterval(3600)
            account.calls.append((account.clock.addingTimeInterval(-1800), spend))
            value += k * spend
            sample()
        }
        sample()
        for _ in 0..<5 { hour(30, k: 1 / 13.5) }
        hour(150, k: 4 / 13.5)                           // 11 points predicted, 44 recorded
        let trip = account.clock
        for _ in 0..<11 { hour(8, k: 4 / 13.5) }
        let ledger = account.ledger
        let timeline = UsageTimeline.build(samples: account.samples, activity: ledger, schedule: nil, now: account.clock)
        XCTAssertEqual(timeline.segments.count, 1, "one stretch of samples, no reset in it")
        let walk = Calibration.walk(timeline, activity: ledger, since: .distantPast, flagged: false, now: account.clock)
        XCTAssertEqual(walk.tripAt, trip)
        XCTAssertEqual(walk.fits.count, 1)
        let fit = try XCTUnwrap(walk.fits.first)
        XCTAssertEqual(fit.start, trip, "the segment starts again at the tripping sample")
        XCTAssertEqual(fit.samples, 12)
        XCTAssertEqual(fit.k, 4 / 13.5, accuracy: 0.01)
    }

    /// A recalibration after a trip answers the flag even once its fits are older than the 45
    /// days that count: the defaults return, without "plan may have changed".
    func testOldRecalibrationAfterATripIsNotFlagged() {
        var account = Synthetic(start: pdt("2026-07-01 06:00"))
        account.segment(k: 1.48, spend: 1.5)
        account.segment(k: 1.48, spend: 1.5)
        account.segment(k: 1 / 13.5, spend: 40.5)            // the trip, and the new plan's first segment
        account.segment(k: 1 / 13.5, spend: 40.5)
        XCTAssertNil(account.calibration().flag)
        XCTAssertEqual(account.calibration().segments, 2)
        let late = account.calibration(now: account.clock.addingTimeInterval(50 * 86400))
        XCTAssertTrue(late.weeklyIsDefault, "nothing in the last 45 days")
        XCTAssertNil(late.flag, "the trip was answered by two segments")
    }

    /// A segment counts from R² 0.90, 10 samples and a 20-point rise — not just below.
    func testSegmentGatesAtTheirThresholds() {
        func fit(samples: Int = 10, rise: Int = 20, r2: Double = 0.9) -> Calibration.Fit {
            Calibration.Fit(start: .distantPast, end: .distantPast, samples: samples, rise: rise, k: 0.07, r2: r2, rmse: 1)
        }
        XCTAssertTrue(fit().qualifies)
        XCTAssertFalse(fit(r2: 0.89).qualifies)
        XCTAssertFalse(fit(samples: 9).qualifies)
        XCTAssertFalse(fit(rise: 19).qualifies)
    }

    /// A new plan tier named by `~/.claude.json` is a plan change: the calibration restarts at
    /// it, flagged (no trip ratio — no sample disagreed). The first tier seen changes nothing.
    func testTierChangeRestartsCalibration() {
        var account = Synthetic(start: pdt("2026-09-21 06:00"))
        account.segment(k: 0.07, spend: 36)
        account.segment(k: 0.07, spend: 36)
        let full = account.ledger
        func calibration(changedAt: Date?) -> Calibration {
            let ledger = ActivityLedger(sessions: full.sessions, anchors: [], indexedThrough: full.indexedThrough, tier: "claude_pro",
                                        tierChangedAt: changedAt)
            let timeline = UsageTimeline.build(samples: account.samples, activity: ledger, schedule: nil, now: account.clock)
            return Calibration.fit(timeline: timeline, activity: ledger, schedule: nil, now: account.clock)
        }
        XCTAssertFalse(calibration(changedAt: nil).weeklyIsDefault)
        let changed = calibration(changedAt: account.clock.addingTimeInterval(-3600))
        XCTAssertTrue(changed.weeklyIsDefault)
        XCTAssertEqual(changed.flag, Calibration.planChangedFlag)
        XCTAssertNil(changed.tripRatio)
    }

    /// The ledgers the index hands out say from when their spend is complete.
    func testLedgersCarryTheIndexCoverage() throws {
        let f = try ActivityFixture()
        let refresh = f.refresh()
        let ledger = try XCTUnwrap(refresh.ledgers[ActivityFixture.personal.id])
        XCTAssertEqual(ledger.coveredSince, refresh.file.coveredSince)
        XCTAssertEqual(ledger.coveredSince, f.now.addingTimeInterval(-14 * 86400), "a first build covers 14 days")
    }

    /// A confirmed re-anchor of the weekly schedule is a plan change: what came before no
    /// longer calibrates.
    func testReanchorResetsCalibration() {
        var account = Synthetic(start: pdt("2026-09-21 06:00"))
        account.segment(k: 0.07, spend: 36)
        account.segment(k: 0.07, spend: 36)
        let moved = WeeklySchedule(phase: 0, halfWidth: 3600, source: .bracketed(support: 1, newestAt: account.clock),
                                   confirmedAt: account.clock, reanchoredAt: account.clock.addingTimeInterval(-60))
        let timeline = UsageTimeline.build(samples: account.samples, activity: account.ledger, schedule: nil, now: account.clock)
        let calibration = Calibration.fit(timeline: timeline, activity: account.ledger, schedule: moved, now: account.clock)
        XCTAssertTrue(calibration.weeklyIsDefault)
        XCTAssertEqual(calibration.flag, Calibration.planChangedFlag)
    }

    /// Spend before the index's coverage is partial: nothing is fitted on it.
    func testNothingIsFittedBeforeTheIndexCoverage() {
        var account = Synthetic(start: pdt("2026-09-21 06:00"))
        account.segment(k: 0.07, spend: 36)
        account.segment(k: 0.07, spend: 36)
        let full = account.ledger
        let partial = ActivityLedger(sessions: full.sessions, anchors: [], indexedThrough: full.indexedThrough, coveredSince: account.clock)
        let timeline = UsageTimeline.build(samples: account.samples, activity: partial, schedule: nil, now: account.clock)
        XCTAssertTrue(Calibration.fit(timeline: timeline, activity: partial, schedule: nil, now: account.clock).weeklyIsDefault)
        XCTAssertTrue(Calibration.fit(timeline: timeline, activity: nil, schedule: nil, now: account.clock) == .defaults, "no activity, no calibration")
    }

    /// Segments older than 45 days no longer count.
    func testOnlyTheLastFortyFiveDaysCount() {
        var account = Synthetic(start: pdt("2026-08-01 06:00"))
        account.segment(k: 0.07, spend: 36)
        account.segment(k: 0.07, spend: 36)
        XCTAssertFalse(account.calibration(now: pdt("2026-09-10 00:00")).weeklyIsDefault)
        XCTAssertTrue(account.calibration(now: pdt("2026-09-20 00:00")).weeklyIsDefault)
    }

    // MARK: - k_f

    /// Eight five-hour windows rising 5 points or more on samples under an hour apart calibrate
    /// the window weight; seven do not.
    func testWindowWeightNeedsEightWindows() {
        func account(windows: Int) -> (UsageTimeline, ActivityLedger, Date) {
            var samples: [UsageSample] = []
            var calls: [(at: Date, spend: Double)] = []
            var clock = pdt("2026-09-21 06:00")
            for _ in 0..<windows {
                var spent = 0.0
                for step in 0...4 {
                    if step > 0 {
                        calls.append((clock.addingTimeInterval(-900), 10))
                        spent += 10
                    }
                    samples.append(UsageSample(sampledAt: clock, org: "o", utilization: ["fh": 2 + Int((spent / 3.3).rounded())]))
                    clock = clock.addingTimeInterval(1800)
                }
                clock = clock.addingTimeInterval(6 * 3600)
            }
            let ledger = UsageFixtures.ledger(calls)
            return (UsageTimeline.build(samples: samples, activity: ledger, schedule: nil, now: clock), ledger, clock)
        }
        let (seven, ledger7, now7) = account(windows: 7)
        XCTAssertTrue(Calibration.fit(timeline: seven, activity: ledger7, schedule: nil, now: now7).windowIsDefault)
        let (eight, ledger8, now8) = account(windows: 8)
        let calibration = Calibration.fit(timeline: eight, activity: ledger8, schedule: nil, now: now8)
        XCTAssertEqual(calibration.windows, 8)
        XCTAssertEqual(calibration.window, 1 / 3.3, accuracy: 0.01)
    }
}
