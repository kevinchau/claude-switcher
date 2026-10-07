import XCTest
@testable import ClaudeSwitcherCore

/// The weekly reset schedule: exact anchors from limit hits, brackets from drops, the vote,
/// and when the schedule may move. Fixtures are numbers only (see ``UsageFixtures``).
final class WeeklyScheduleTests: XCTestCase {

    private typealias F = UsageFixtures
    private let week: TimeInterval = 7 * 86400
    private let hour: TimeInterval = 3600

    private func pdt(_ text: String) -> Date { F.pdt(text) }

    private func sample(_ text: String, sd: Int, fh: Int? = nil) -> UsageSample {
        var u = ["sd": sd]
        if let fh { u["fh"] = fh }
        return UsageSample(sampledAt: pdt(text), org: "org", utilization: u)
    }

    private func bracket(_ by: Date, width: TimeInterval) -> WeeklySchedule.Evidence.Candidate {
        .init(after: by.addingTimeInterval(-width), by: by, recordedAt: by, isExact: false)
    }

    private func weekdayAndMinute(_ schedule: WeeklySchedule) -> (weekday: Int, minute: Int) {
        F.pdtWeekdayAndMinute(ofPhase: schedule.phase)
    }

    private func phaseWeekday(_ phase: TimeInterval?) -> Int? {
        phase.map { F.pdtWeekdayAndMinute(ofPhase: $0).weekday }
    }

    // MARK: - Exact anchors

    /// Personal's real series with the anchor Claude Code recorded on Thu 09-24 (the limit hit
    /// that said "resets Sat 21:00"): the anchor decides, to the minute, over every bracket.
    func testExactAnchorWinsOverBrackets() throws {
        let now = pdt("2026-10-05 18:47")
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: F.personal(), anchors: [F.personalWeeklyAnchors[1]], now: now))
        XCTAssertEqual(schedule.halfWidth, 0)
        XCTAssertEqual(schedule.source, .exact(anchors: 1, lastHitAt: pdt("2026-09-24 09:20")))
        XCTAssertEqual(weekdayAndMinute(schedule).weekday, 6, "Saturday")
        XCTAssertEqual(weekdayAndMinute(schedule).minute, 21 * 60)
        let next = schedule.next(after: now)
        XCTAssertEqual(next.by, pdt("2026-10-10 21:00"))
        XCTAssertEqual(next.after, next.by)
        XCTAssertNil(schedule.unconfirmedPhase, "the newest drop (the 73-hour bracket) contains Saturday 21:00")
    }

    /// All three of Personal's anchors: Sun 04:00Z exact, fresh (the newest hit is 5 days old).
    func testPersonalRegressionIsSaturdayNinePMExactAndFresh() throws {
        let now = pdt("2026-10-05 18:47")
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: F.personal(), anchors: F.personalWeeklyAnchors, now: now))
        XCTAssertEqual(schedule.source, .exact(anchors: 3, lastHitAt: pdt("2026-09-30 08:12")))
        XCTAssertEqual(schedule.phase.truncatingRemainder(dividingBy: 86400), 4 * hour, "04:00Z")
        XCTAssertTrue(schedule.isFresh(now: now))
        XCTAssertNil(schedule.reanchoredAt, "the Fri 09-04 and Tue 09-22 drops are one-offs, not a plan change")
        let reset = try XCTUnwrap(WeeklyReset.infer(from: F.personal(), anchors: F.personalWeeklyAnchors, now: now))
        XCTAssertEqual(reset.resetsBy, pdt("2026-10-10 21:00"))
        XCTAssertTrue(reset.isFresh)
    }

    /// Christy: Mon 05:00 PDT (12:00Z), from its own anchors.
    func testChristyIsMondayFiveAMExact() throws {
        let now = pdt("2026-10-05 18:47")
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: F.christy(), anchors: F.christyWeeklyAnchors, now: now))
        XCTAssertEqual(schedule.phase.truncatingRemainder(dividingBy: 86400), 12 * hour)
        XCTAssertEqual(weekdayAndMinute(schedule).weekday, 1, "Monday")
        XCTAssertEqual(schedule.next(after: now).by, pdt("2026-10-12 05:00"))
        XCTAssertNil(schedule.unconfirmedPhase)
    }

    func testNewerExactAnchorReanchorsAtOnce() throws {
        // A Saturday schedule, recorded exactly a month ago and confirmed by two drops since…
        let saturday = LimitAnchor(resetsAt: pdt("2026-09-05 21:00"), kind: .sevenDay, hitAt: pdt("2026-09-04 10:00"))
        let samples = [sample("2026-09-12 20:30", sd: 70), sample("2026-09-12 21:15", sd: 1),
                       sample("2026-09-19 20:40", sd: 80), sample("2026-09-19 21:05", sd: 0)]
        // …and then a limit hit that says the week now resets on Tuesday mornings (a plan change).
        let tuesday = LimitAnchor(resetsAt: pdt("2026-10-06 09:00"), kind: .sevenDay, hitAt: pdt("2026-10-03 14:00"))
        let now = pdt("2026-10-05 12:00")
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: samples, anchors: [saturday, tuesday], now: now))
        XCTAssertEqual(schedule.source, .exact(anchors: 1, lastHitAt: pdt("2026-10-03 14:00")))
        XCTAssertEqual(schedule.next(after: now).by, pdt("2026-10-06 09:00"), "adopted at once")
        XCTAssertEqual(schedule.reanchoredAt, pdt("2026-10-03 14:00"), "calibration from before the change no longer applies")
        XCTAssertNil(schedule.unconfirmedPhase)
    }

    func testAnchorsOlderThanSixtyDaysAreIgnored() throws {
        let old = LimitAnchor(resetsAt: pdt("2026-08-07 12:00"), kind: .sevenDay, hitAt: pdt("2026-08-05 12:00"))
        let now = pdt("2026-10-05 12:00")   // 61 days after the hit
        XCTAssertNil(WeeklySchedule.infer(samples: [], anchors: [old], now: now), "not a vote either")

        let samples = [sample("2026-09-26 19:00", sd: 90), sample("2026-09-26 21:30", sd: 0),
                       sample("2026-10-03 20:00", sd: 95), sample("2026-10-03 21:20", sd: 1)]
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: samples, anchors: [old], now: now))
        guard case .bracketed = schedule.source else { return XCTFail("an old anchor must not make the schedule exact: \(schedule.source)") }
        XCTAssertEqual(weekdayAndMinute(schedule).weekday, 6)

        let recent = LimitAnchor(resetsAt: old.resetsAt, kind: .sevenDay, hitAt: pdt("2026-08-07 11:00"))
        let atFiftyNine = pdt("2026-10-05 10:00")
        XCTAssertEqual(WeeklySchedule.infer(samples: [], anchors: [recent], now: atFiftyNine)?.isExact, true, "59 days old still decides")
    }

    /// The API's `resets_at` jitters by about a second; two weeks' anchors on either side of
    /// the minute are one schedule, exactly on the minute.
    func testRoundsAnchorToMinute() throws {
        let early = LimitAnchor(resetsAt: pdt("2026-09-26 20:59:59.716"), kind: .sevenDay, hitAt: pdt("2026-09-24 09:20"))
        let late = LimitAnchor(resetsAt: pdt("2026-10-03 21:00:00.597"), kind: .sevenDay, hitAt: pdt("2026-09-30 08:12"))
        XCTAssertEqual(early.resetsAt, pdt("2026-09-26 21:00"))
        XCTAssertEqual(late.resetsAt, pdt("2026-10-03 21:00"))
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: [], anchors: [early, late], now: pdt("2026-10-05 12:00")))
        XCTAssertEqual(schedule.source, .exact(anchors: 2, lastHitAt: pdt("2026-09-30 08:12")))
        XCTAssertEqual(schedule.phase.truncatingRemainder(dividingBy: 60), 0, "on the minute")
        XCTAssertEqual(schedule.next(after: pdt("2026-10-05 12:00")).by, pdt("2026-10-10 21:00"))
    }

    // MARK: - Brackets and the vote

    /// Personal's real drops with no anchor at all: the Fri 09-04 drop is one bracket against
    /// five that agree on Saturday evening, and the Tue 09-22 grant another. The greedy
    /// intersection this replaces said Friday.
    func testFridayOutlierDoesNotWinAgainstThreeSaturdays() throws {
        let now = pdt("2026-10-05 18:47")
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: F.personal(), anchors: [], now: now))
        XCTAssertEqual(weekdayAndMinute(schedule).weekday, 6, "Saturday")
        let next = schedule.next(after: now)
        XCTAssertEqual(next.after, pdt("2026-10-10 17:58"), "the Saturday brackets' intersection: 09-19's 17:58 …")
        XCTAssertEqual(next.by, pdt("2026-10-10 21:00"), "… and 09-26's 21:00")
        XCTAssertNil(schedule.unconfirmedPhase)
        XCTAssertEqual(schedule.outOfOrderSamples, 0)

        // The vote leans on recency: an old schedule seen twice in tight brackets loses to a newer
        // one seen three times in wider brackets. The newest drop spans both days, so only the
        // vote can decide; without the recency term the old one would win.
        let lastSaturday = pdt("2026-09-26 21:30")
        var candidates: [WeeklySchedule.Evidence.Candidate] = []
        for weeksAgo in [5.0, 4.0] { candidates.append(bracket(pdt("2026-09-25 12:15").addingTimeInterval(-weeksAgo * week), width: 900)) }
        for weeksAgo in [2.0, 1.0, 0.0] { candidates.append(bracket(lastSaturday.addingTimeInterval(-weeksAgo * week), width: 4 * hour)) }
        let later = pdt("2026-10-04 09:00")
        candidates.append(bracket(later.addingTimeInterval(-hour), width: 48 * hour))     // Fri 08:00 → Sun 08:00
        let recent = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: candidates), now: later))
        XCTAssertEqual(weekdayAndMinute(recent).weekday, 6, "Saturday, not the older Friday")
        XCTAssertNil(recent.unconfirmedPhase, "the newest drop agrees with Saturday too")
    }

    /// Fri (4 h, 3 weeks ago), a 73-hour bracket spanning Friday and Saturday (1 week ago) and
    /// Sat (3 h, now): Saturday, whatever order the evidence comes in.
    func testWideBracketBarelyVotesAndOrderDoesNotMatter() throws {
        let now = pdt("2026-10-03 23:30")
        let friday = bracket(pdt("2026-09-11 13:00"), width: 4 * hour)
        let wide = bracket(pdt("2026-09-27 08:00"), width: 73 * hour)          // Thu 07:00 → Sun 08:00
        let saturday = bracket(pdt("2026-10-03 22:00"), width: 3 * hour)
        let all = [friday, wide, saturday]
        var results: [WeeklySchedule] = []
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let schedule = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: order.map { all[$0] }), now: now))
            XCTAssertEqual(weekdayAndMinute(schedule).weekday, 6, "order \(order)")
            results.append(schedule)
        }
        XCTAssertEqual(Set(results.map { "\($0)" }).count, 1, "the same schedule for every order")

        // Between two phases each seen twice, a pile of day-wide brackets around Friday must not
        // outvote two tight Saturdays: a bracket votes min(1, 1 h / its width). The newest drop
        // spans both days, so only the vote can decide.
        let s = pdt("2026-09-26 21:30")
        let f = pdt("2026-09-25 12:30")
        let at = pdt("2026-10-04 09:00")
        let mixed: [WeeklySchedule.Evidence.Candidate] = [
            bracket(s, width: hour), bracket(s.addingTimeInterval(-week), width: hour),
            bracket(f.addingTimeInterval(-week), width: hour), bracket(f.addingTimeInterval(-2 * week), width: hour),
            bracket(f.addingTimeInterval(15 * hour), width: 30 * hour),
            bracket(f.addingTimeInterval(15 * hour + 60), width: 30 * hour),
            bracket(f.addingTimeInterval(-week + 15 * hour), width: 30 * hour),
            bracket(at.addingTimeInterval(-hour), width: 60 * hour),                    // Thu 20:00 → Sun 08:00
        ]
        let voted = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: mixed), now: at))
        XCTAssertEqual(weekdayAndMinute(voted).weekday, 6, "Saturday: the wide Friday brackets barely vote")
    }

    /// A six-day bracket spans Tuesday and Saturday alike, so it is a sighting of neither. Joined
    /// to a five-minute Tuesday grant it must not make Tuesday "established" against the one
    /// Saturday seen since — and when a second Saturday comes, nothing was overtaken: no plan
    /// change, no calibration dropped.
    func testWideBracketCannotEstablishAPhase() throws {
        let now = pdt("2026-10-03 23:30")
        let grant = bracket(pdt("2026-09-15 10:05"), width: 5 * 60)
        let wide = bracket(pdt("2026-09-27 23:00"), width: 6 * 86400)          // Mon 09-21 23:00 → Sun 09-27 23:00
        let saturday = bracket(pdt("2026-10-03 22:00"), width: 2 * hour)
        let once = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: [grant, wide, saturday]), now: now))
        XCTAssertEqual(weekdayAndMinute(once).weekday, 6, "Saturday by the vote: the wide bracket is no second sighting of Tuesday")
        XCTAssertTrue(once.unconfirmedPhase == nil || phaseWeekday(once.unconfirmedPhase) == 2, "\(String(describing: once.unconfirmedPhase))")
        XCTAssertNil(once.reanchoredAt)

        let later = pdt("2026-10-10 23:30")
        let again = bracket(pdt("2026-10-10 22:00"), width: 2 * hour)
        let twice = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: [grant, wide, saturday, again]), now: later))
        XCTAssertEqual(weekdayAndMinute(twice).weekday, 6)
        XCTAssertNil(twice.reanchoredAt, "Tuesday was never established, so nothing was overtaken")
        let ledger = F.ledger([(pdt("2026-10-10 12:00"), 13.5)])
        let timeline = UsageTimeline.build(samples: [], activity: ledger, schedule: twice, now: later)
        XCTAssertNil(Calibration.fit(timeline: timeline, activity: ledger, schedule: twice, now: later).flag, "no 'plan may have changed'")
    }

    // MARK: - When the schedule moves

    /// The 09-22 grant reset both of Personal's limits in five minutes on a Tuesday. It must
    /// not move a Saturday schedule — with the August anchor, or from the drops alone — and is
    /// reported as an unconfirmed phase.
    func testGrantResetDoesNotReanchor() throws {
        let now = pdt("2026-09-22 20:00")
        let samples = F.personal(through: now)
        let withAnchor = try XCTUnwrap(WeeklySchedule.infer(samples: samples, anchors: [F.personalWeeklyAnchors[0]], now: now))
        XCTAssertEqual(withAnchor.isExact, true)
        XCTAssertEqual(weekdayAndMinute(withAnchor).weekday, 6)
        XCTAssertEqual(weekdayAndMinute(withAnchor).minute, 21 * 60)
        XCTAssertEqual(phaseWeekday(withAnchor.unconfirmedPhase), 2, "Tuesday, reported")
        XCTAssertFalse(withAnchor.isFresh(now: now), "an unconfirmed phase keeps the hedge")
        XCTAssertNil(withAnchor.reanchoredAt)

        let fromDrops = try XCTUnwrap(WeeklySchedule.infer(samples: samples, anchors: [], now: now))
        XCTAssertEqual(weekdayAndMinute(fromDrops).weekday, 6, "Saturday, though the grant's five-minute bracket outvotes each Saturday")
        XCTAssertEqual(phaseWeekday(fromDrops.unconfirmedPhase), 2)
        XCTAssertNil(fromDrops.reanchoredAt)

        // Once the next Saturday reset is seen, the grant is history: nothing unconfirmed.
        let after = pdt("2026-09-27 12:00")
        let settled = try XCTUnwrap(WeeklySchedule.infer(samples: F.personal(through: after), anchors: [], now: after))
        XCTAssertEqual(weekdayAndMinute(settled).weekday, 6)
        XCTAssertNil(settled.unconfirmedPhase)

        // Christy's grant on Thu 09-24, against its Monday anchor.
        let christyNow = pdt("2026-09-24 12:00")
        let christy = try XCTUnwrap(WeeklySchedule.infer(samples: F.christy(through: christyNow),
                                                         anchors: [F.christyWeeklyAnchors[0]], now: christyNow))
        XCTAssertEqual(weekdayAndMinute(christy).weekday, 1)
        XCTAssertEqual(phaseWeekday(christy.unconfirmedPhase), 4, "Thursday")
    }

    func testTwoConsecutiveDisagreeingBracketsReanchor() throws {
        // Four tight Saturday resets, then the plan changes to Tuesday mornings.
        var candidates: [WeeklySchedule.Evidence.Candidate] = []
        let saturday = pdt("2026-09-05 21:10")
        for k in 0..<4 { candidates.append(bracket(saturday.addingTimeInterval(Double(k) * week), width: 900)) }
        let firstTuesday = pdt("2026-09-29 10:00")
        candidates.append(bracket(firstTuesday, width: 2 * hour))

        let once = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: candidates), now: firstTuesday.addingTimeInterval(hour)))
        XCTAssertEqual(weekdayAndMinute(once).weekday, 6, "one Tuesday is not enough")
        XCTAssertEqual(phaseWeekday(once.unconfirmedPhase), 2)

        candidates.append(bracket(firstTuesday.addingTimeInterval(week), width: 2 * hour))
        let now = firstTuesday.addingTimeInterval(week + hour)
        let twice = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: candidates), now: now))
        XCTAssertEqual(weekdayAndMinute(twice).weekday, 2, "two in a row move it, though Saturday still has the larger vote")
        XCTAssertNil(twice.unconfirmedPhase)
        XCTAssertEqual(twice.reanchoredAt, firstTuesday, "the first reset on the new schedule")
        XCTAssertEqual(twice.next(after: now).by, pdt("2026-10-13 10:00"))
    }

    /// A plan change is dated only when the new phase overtook the old one under step 4 — two
    /// sightings since the old one's last, or a newer exact anchor. After four Saturdays and two
    /// Tuesdays (dated at the first Tuesday), one Saturday again overtakes nothing, whatever the
    /// vote says; a second one does.
    func testReanchorIsDatedOnlyWhenTheNewPhaseOvertookTheOld() throws {
        var candidates: [WeeklySchedule.Evidence.Candidate] = []
        let saturday = pdt("2026-09-05 21:10")
        for k in 0..<4 { candidates.append(bracket(saturday.addingTimeInterval(Double(k) * week), width: 900)) }
        let firstTuesday = pdt("2026-09-29 10:00")
        candidates += [bracket(firstTuesday, width: 2 * hour), bracket(firstTuesday.addingTimeInterval(week), width: 2 * hour)]
        let moved = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: candidates), now: firstTuesday.addingTimeInterval(week + hour)))
        XCTAssertEqual(moved.reanchoredAt, firstTuesday)

        let back = pdt("2026-10-10 21:10")
        candidates.append(bracket(back, width: 900))
        let once = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: candidates), now: back.addingTimeInterval(hour)))
        XCTAssertEqual(weekdayAndMinute(once).weekday, 6, "the Saturdays' vote")
        XCTAssertNil(once.reanchoredAt, "one Saturday since the Tuesdays is no plan change")

        candidates.append(bracket(back.addingTimeInterval(week), width: 900))
        let twice = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: candidates), now: back.addingTimeInterval(week + hour)))
        XCTAssertEqual(weekdayAndMinute(twice).weekday, 6)
        XCTAssertEqual(twice.reanchoredAt, back, "two are: the first one is where it begins")
    }

    /// A one-point decrease is a clock correction or two samples out of order, not a reset.
    func testSmallDecreaseIsNotABracket() throws {
        let noise = [sample("2026-09-29 09:53", sd: 61), sample("2026-09-29 10:00", sd: 60)]
        let now = pdt("2026-09-30 12:00")
        XCTAssertNil(WeeklySchedule.infer(samples: noise, now: now), "no phantom Tuesday schedule")
        XCTAssertEqual(WeeklySchedule.evidence(samples: noise, anchors: [], now: now).outOfOrderSamples, 1)
        XCTAssertNil(WeeklyReset.infer(from: noise, now: now))

        let toNearlyZero = [sample("2026-09-29 09:53", sd: 60), sample("2026-09-29 10:00", sd: 2)]
        XCTAssertEqual(WeeklySchedule.evidence(samples: toNearlyZero, anchors: [], now: now).candidates.count, 1)
        let bigFall = [sample("2026-09-29 09:53", sd: 90), sample("2026-09-29 10:00", sd: 65)]
        XCTAssertEqual(WeeklySchedule.evidence(samples: bigFall, anchors: [], now: now).candidates.count, 1)
        XCTAssertEqual(WeeklySchedule.evidence(samples: bigFall, anchors: [], now: now).outOfOrderSamples, 0)
    }

    // MARK: - Constants at their edges

    /// Two brackets agree when they overlap within two minutes of slack (clock skew between this
    /// Mac and the server): 119 s apart they are one reset, 121 s apart two — either way round.
    func testBracketsAgreeWithinTwoMinutesOfSlack() {
        typealias Arc = WeeklySchedule.Arc
        let first = Arc(start: 10_000, width: 600)
        let near = Arc(start: 10_000 + 600 + 119, width: 600), far = Arc(start: 10_000 + 600 + 121, width: 600)
        XCTAssertNotNil(WeeklySchedule.intersection(first, near))
        XCTAssertNil(WeeklySchedule.intersection(first, far))
        XCTAssertNotNil(WeeklySchedule.intersection(near, first))
        XCTAssertNil(WeeklySchedule.intersection(far, first))
    }

    /// A bracket up to an hour wide votes fully; two hours wide, half.
    func testABracketVotesFullyUpToAnHourWide() throws {
        let now = pdt("2026-10-03 22:00")
        for (width, vote) in [(hour, 1.0), (2 * hour, 0.5)] {
            let schedule = try XCTUnwrap(WeeklySchedule.infer(from: .init(candidates: [bracket(now, width: width)]), now: now))
            guard case .bracketed(let support, _) = schedule.source else { return XCTFail("\(schedule.source)") }
            XCTAssertEqual(support, vote, accuracy: 1e-12, "\(width / hour) h")
        }
    }

    // MARK: - Freshness

    func testFreshnessDropsHedgeOnlyWithinFourteenDays() throws {
        let now = pdt("2026-10-05 12:00")
        let reset = pdt("2026-10-03 21:00")
        let old = LimitAnchor(resetsAt: pdt("2026-09-05 21:00"), kind: .sevenDay, hitAt: now.addingTimeInterval(-35 * 86400))
        XCTAssertEqual(WeeklySchedule.infer(samples: [], anchors: [old], now: now)?.isFresh(now: now), false, "35 days old")

        let recent = LimitAnchor(resetsAt: reset, kind: .sevenDay, hitAt: now.addingTimeInterval(-5 * 86400))
        let fresh = try XCTUnwrap(WeeklySchedule.infer(samples: [], anchors: [recent], now: now))
        XCTAssertTrue(fresh.isFresh(now: now), "5 days old")
        XCTAssertFalse(fresh.isFresh(now: now.addingTimeInterval(10 * 86400)), "15 days later")

        // A newer drop on another day leaves the phase but restores the hedge.
        let grant = [sample("2026-10-05 09:00", sd: 80, fh: 90), sample("2026-10-05 09:05", sd: 0, fh: 1)]
        let unconfirmed = try XCTUnwrap(WeeklySchedule.infer(samples: grant, anchors: [recent], now: now))
        XCTAssertNotNil(unconfirmed.unconfirmedPhase)
        XCTAssertFalse(unconfirmed.isFresh(now: now))

        // An old anchor confirmed by a recent drop that contains it is fresh again.
        let confirming = [sample("2026-10-03 20:40", sd: 90), sample("2026-10-03 21:05", sd: 0)]
        let confirmed = try XCTUnwrap(WeeklySchedule.infer(samples: confirming, anchors: [old], now: now))
        XCTAssertTrue(confirmed.isFresh(now: now))

        // A bracketed schedule is never shown without the hedge.
        let bracketed = try XCTUnwrap(WeeklySchedule.infer(samples: confirming, anchors: [], now: now))
        XCTAssertFalse(bracketed.isFresh(now: now))
    }

    // MARK: - Occurrences

    func testCycleAndCertainResetFollowThePhase() throws {
        let anchor = LimitAnchor(resetsAt: pdt("2026-10-03 21:00"), kind: .sevenDay, hitAt: pdt("2026-10-01 09:00"))
        let schedule = try XCTUnwrap(WeeklySchedule.infer(samples: [], anchors: [anchor], now: pdt("2026-10-05 12:00")))
        let cycle = schedule.cycle(containing: pdt("2026-10-05 12:00"))
        XCTAssertEqual(cycle.start, pdt("2026-10-03 21:00"))
        XCTAssertEqual(cycle.end, pdt("2026-10-10 21:00"))
        XCTAssertEqual(schedule.cycle(containing: pdt("2026-10-03 21:00")).start, pdt("2026-10-03 21:00"), "a cycle starts at its reset")
        XCTAssertTrue(schedule.hasCertainlyReset(since: pdt("2026-10-03 20:59"), now: pdt("2026-10-03 21:00")))
        XCTAssertFalse(schedule.hasCertainlyReset(since: pdt("2026-10-03 21:01"), now: pdt("2026-10-10 20:59")))
        // Claude samples at the instant an exceeded limit resets; that sample is the new week's.
        XCTAssertFalse(schedule.hasCertainlyReset(since: pdt("2026-10-03 21:00"), now: pdt("2026-10-05 12:00")))
        let reset = WeeklyReset(schedule: schedule, now: pdt("2026-10-05 12:00"))
        XCTAssertFalse(reset.hasCertainlyReset(since: pdt("2026-10-03 21:00"), now: pdt("2026-10-05 12:00")))
        XCTAssertTrue(reset.hasCertainlyReset(since: pdt("2026-10-03 20:59"), now: pdt("2026-10-05 12:00")))
        XCTAssertEqual(schedule.next(after: pdt("2026-10-10 21:00")).by, pdt("2026-10-17 21:00"), "a reset at now has happened")
    }
}
