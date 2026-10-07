import XCTest
@testable import ClaudeSwitcherCore

/// The Advisor's rules, one at a time, on forecasts made from the numbers each rule is about.
/// Costs are the judge's worked figures (short p75 2, medium 5, long first 3 h 12 / whole 30;
/// reserve 4 points) so the arithmetic in each test can be read off.
final class UsageAdvisorTests: XCTestCase {

    private typealias A = AdvisorFixtures
    private let now = AdvisorFixtures.now

    // MARK: - Fit

    /// Medium's p75 is 5: an account with 4 points of cautious headroom cannot take it, however
    /// much budget it would otherwise waste.
    func testNeverRecommendsAnAccountThatCannotFit() {
        let personal = A.forecast("personal", headroom: 4, waste: 30)
        let christy = A.forecast("christy", headroom: 50, waste: -10)
        let medium = A.advise(.medium, [personal, christy])
        XCTAssertEqual(medium.profileID, "christy", "p75 5 does not fit in 4 (p50 3 would)")
        XCTAssertEqual(medium.alternatives.first?.why, .cannotFit(left: 4))
        // Short (p75 2) fits there, and the budget that would go unused wins it.
        XCTAssertEqual(A.advise(.short, [personal, christy]).profileID, "personal")
    }

    /// H = 0 and H = 5 with a reserve of 4: a medium session would take the last of it, so
    /// nothing fits; a short one is offered as the last headroom, and said to be.
    func testNeverSpendsTheLastHeadroom() {
        let personal = A.forecast("personal", headroom: 0, waste: -40)
        let christy = A.forecast("christy", headroom: 5, waste: -30)
        let medium = A.advise(.medium, [personal, christy])
        guard case .nothingFits = medium.outcome else { return XCTFail("\(medium.outcome)") }
        let short = A.advise(.short, [personal, christy])
        XCTAssertEqual(short.outcome, .lastHeadroom(profileID: "christy"))
        XCTAssertEqual(AdvisorText.row(short, snapshot: A.snapshot([personal, christy]), labels: A.labels, clock: A.clock()).title,
                       "Short \u{2014} under an hour \u{2192} Christy (last headroom)")
    }

    /// Personal ranks first (budget that would go unused) and fits a short session, but would
    /// be left with 3 points while Christy has 3: no account would keep 4. Christy takes it and
    /// Personal stays in reserve — said once: the reason names Personal, so its clause does not
    /// follow (testReasonDoesNotNameTheSameAccountTwice).
    func testKeepsOneAccountInReserve() {
        let personal = A.forecast("personal", headroom: 5, waste: 30)
        let christy = A.forecast("christy", headroom: 3, waste: -10)
        let short = A.advise(.short, [personal, christy])
        XCTAssertEqual(short.profileID, "christy")
        XCTAssertEqual(A.reason(short), .keepsReserve(other: "personal"))
        XCTAssertEqual(short.alternatives.first?.why, .noReserve)
        XCTAssertEqual(AdvisorText.reason(short, snapshot: A.snapshot([personal, christy]), labels: A.labels, clock: A.clock()),
                       "keeps Personal in reserve")
    }

    func testPrefersBudgetThatWouldGoUnused() {
        let personal = A.forecast("personal", headroom: 40, waste: 30)
        let christy = A.forecast("christy", headroom: 90, waste: -10)
        let medium = A.advise(.medium, [personal, christy])
        XCTAssertEqual(medium.profileID, "personal")
        XCTAssertEqual(A.reason(medium), .useItOrLoseIt(points: 30, resetBy: A.personalReset))
    }

    /// Both will run out: a short session mops up the account that resets first.
    func testAllWillRunOutPrefersSoonestReset() {
        // Christy resets first here (config order would pick Personal).
        let saturday = UsageFixtures.pdt("2026-10-10 05:00")
        let personal = A.forecast("personal", headroom: 30, waste: -40, end: A.christyReset)
        let christy = A.forecast("christy", headroom: 60, waste: -20, end: saturday)
        let short = A.advise(.short, [personal, christy])
        XCTAssertEqual(short.profileID, "christy")
        XCTAssertEqual(A.reason(short), .resetsSoonest(resetBy: saturday))
        XCTAssertEqual(short.alternatives.first?.why, .projectedToRunOut)
        // Within six hours of each other the resets tie, and config order decides.
        let close = A.advise(.short, [A.forecast("personal", headroom: 30, waste: -40, end: saturday.addingTimeInterval(5 * 3600)), christy])
        XCTAssertEqual(close.profileID, "personal")
    }

    /// Medium and long go where the margin is comfortable (at least twice the p75) before the
    /// sooner reset decides; short keeps the plain sooner-reset order (A13).
    func testThinMarginRanksBehindComfortableForMedium() {
        let personal = A.forecast("personal", headroom: 9, waste: -50)
        let christy = A.forecast("christy", headroom: 100, waste: -10)
        let medium = A.advise(.medium, [personal, christy])
        XCTAssertEqual(medium.profileID, "christy")
        XCTAssertEqual(A.reason(medium), .comfortableMargin(other: "personal", otherLeft: 9))
        let short = A.advise(.short, [personal, christy])
        XCTAssertEqual(short.profileID, "personal")
        XCTAssertEqual(A.reason(short), .resetsSoonest(resetBy: A.personalReset))
        XCTAssertEqual(A.advise(.short, [A.forecast("personal", headroom: 3, waste: -50), christy]).profileID, "personal",
                       "short mops up the expiring budget even where the margin is thin (3 < 2 × 2)")
        // Twice the p75 is comfortable: then the sooner reset wins medium too.
        XCTAssertEqual(A.advise(.medium, [A.forecast("personal", headroom: 10, waste: -50), christy]).profileID, "personal")
    }

    /// Long fits on its first three hours (p75 12) where its whole p75 (30) does not, and says
    /// when it will likely stall: 20 points at a typical long session's 5 points an hour.
    func testLongFitsOnFirstThreeHoursAndReportsStall() {
        let personal = A.forecast("personal", headroom: 20, waste: -20)
        let christy = A.forecast("christy", headroom: 0, waste: -60)
        let long = A.advise(.long, [personal, christy])
        guard case .start(let id, _, nil, let stall?) = long.outcome else { return XCTFail("\(long.outcome)") }
        XCTAssertEqual(id, "personal")
        XCTAssertEqual(stall.timeIntervalSince(now), 4 * 3600, accuracy: 1)
        // At a faster pace of its own, sooner.
        let fast = A.advise(.long, [A.forecast("personal", headroom: 20, waste: -20, pace: 10), christy])
        if case .start(_, _, _, let stall?) = fast.outcome { XCTAssertEqual(stall.timeIntervalSince(now), 2 * 3600, accuracy: 1) } else { XCTFail() }
        let row = AdvisorText.row(long, snapshot: A.snapshot([personal, christy]), labels: A.labels, clock: A.clock())
        XCTAssertEqual(row.title, "Long \u{2014} over 3 hours or a workflow run \u{2192} Personal (likely hits the limit about tonight)")
        XCTAssertTrue(row.reason.hasPrefix("the first 3 hours fit"))
        // Where the whole p75 fits there is no stall.
        if case .start(_, _, _, let none) = A.advise(.long, [A.forecast("personal", headroom: 40, waste: -20), christy]).outcome {
            XCTAssertNil(none)
        }
    }

    // MARK: - Stability

    /// The tier boundary at 5 points of waste must not flip the answer: Personal stays across
    /// 6 → 3 while Christy's waste is unknown, and Christy takes over only when her waste beats
    /// Personal's by 10.
    func testWasteCrossingFiveDoesNotFlip() {
        let christy = A.forecast("christy", headroom: 90, waste: nil)
        let first = A.advise(.medium, [A.forecast("personal", headroom: 60, waste: 6), christy])
        XCTAssertEqual(first.profileID, "personal", "waste 6 ranks above unknown")

        let later = now.addingTimeInterval(1800)
        let second = A.advise(.medium, [A.forecast("personal", headroom: 60, waste: 3), christy], previous: first, at: later)
        XCTAssertEqual(second.profileID, "personal", "waste 3 is a lower tier than unknown, but not 10 points worse")
        XCTAssertEqual(A.reason(second), .unchanged(since: now, original: A.reason(first)!))
        XCTAssertTrue(AdvisorText.reason(second, snapshot: A.snapshot([christy]), labels: A.labels, clock: A.clock(later))
            .hasPrefix("still Personal \u{2014} chosen 30 min ago; nothing has changed enough to switch"))

        let third = A.advise(.medium, [A.forecast("personal", headroom: 60, waste: 3), A.forecast("christy", headroom: 90, waste: 15)],
                             previous: second, at: later.addingTimeInterval(1800))
        XCTAssertEqual(third.profileID, "christy", "15 against 3 beats by 12")
    }

    /// At twelve hours into Christy's week her pace appears and her waste goes from unknown to
    /// −5: Personal (still unknown) now ranks first, but by 5, not 10.
    func testLeavingUnknownTierKeepsPreviousChoice() {
        let personal = A.forecast("personal", headroom: 30, waste: nil)
        let first = A.advise(.medium, [personal, A.forecast("christy", headroom: 92, waste: nil)])
        XCTAssertEqual(first.profileID, "christy", "most headroom")
        let later = A.advise(.medium, [personal, A.forecast("christy", headroom: 80, waste: -5)], previous: first,
                             at: now.addingTimeInterval(3600))
        XCTAssertEqual(later.profileID, "christy")
        guard case .unchanged = A.reason(later) else { return XCTFail("\(String(describing: A.reason(later)))") }
    }

    /// A weekly reset on either account since the earlier advice releases it.
    func testResetPassingReleasesStability() {
        let before = UsageFixtures.pdt("2026-10-10 18:00")
        let after = UsageFixtures.pdt("2026-10-11 10:00")
        let christy = A.forecast("christy", headroom: 90, waste: nil)
        let previous = Advice(size: .medium, outcome: .start(profileID: "personal", reason: .mostHeadroom(points: 60),
                                                              afterWindowClearsAt: nil, stallsAbout: nil),
                              alternatives: [], basis: .recordedPlusActivity, at: before)
        let personal = A.forecast("personal", headroom: 60, waste: 3, end: UsageFixtures.pdt("2026-10-17 21:00"))
        // Before Saturday 21:00 the choice holds…
        XCTAssertEqual(A.advise(.medium, [personal, christy], previous: previous, at: UsageFixtures.pdt("2026-10-10 20:00")).profileID, "personal")
        // …after it, the accounts are ranked afresh.
        let ranked = A.advise(.medium, [personal, christy], previous: previous, at: after)
        XCTAssertEqual(ranked.profileID, "christy")
        XCTAssertEqual(A.reason(ranked), .mostHeadroom(points: 90))
    }

    /// Both accounts will run out (waste −235 and −346): neither saves any budget, so neither is
    /// "clearly better" — the earlier choice stays, though Personal now ranks first on its sooner
    /// reset. (With waste itself as the score, 111 points between two shortfalls switched it.) An
    /// account with budget that would really go unused still wins it over.
    func testBothRunningOutKeepsTheEarlierChoice() {
        let personal = A.forecast("personal", headroom: 60, waste: -235)
        let christy = A.forecast("christy", headroom: 60, waste: -346)
        XCTAssertEqual(A.advise(.medium, [personal, christy]).profileID, "personal", "ranked afresh: the sooner reset")
        let earlier = Advice(size: .medium, outcome: .start(profileID: "christy", reason: .resetsSoonest(resetBy: A.christyReset),
                                                             afterWindowClearsAt: nil, stallsAbout: nil),
                             alternatives: [], basis: .recordedPlusActivity, at: now)
        let later = now.addingTimeInterval(1800)
        let kept = A.advise(.medium, [personal, christy], previous: earlier, at: later)
        XCTAssertEqual(kept.profileID, "christy")
        XCTAssertEqual(A.reason(kept), .unchanged(since: now, original: .resetsSoonest(resetBy: A.christyReset)))
        // Twelve points that would go unused at Personal's reset are worth switching for.
        let saving = A.advise(.medium, [A.forecast("personal", headroom: 60, waste: 12), christy], previous: earlier, at: later)
        XCTAssertEqual(saving.profileID, "personal")
    }

    /// A short session's p75 is 1.0 point at the defaults. Personal, chosen at 1.9 points, dips
    /// to 0.8 and comes back to 0.9 — fractions of a point between reads — and stays chosen
    /// throughout; without the earlier choice 0.8 would not fit and Christy would take it.
    func testEarlierChoiceSurvivesAHeadroomWobble() {
        let christy = A.forecast("christy", headroom: 50, waste: -10)
        var previous = A.advise(.short, [A.forecast("personal", headroom: 1.9, waste: -30), christy], costs: .defaults)
        XCTAssertEqual(previous.profileID, "personal", "the sooner reset")
        for (minutes, headroom) in [(20.0, 0.8), (40.0, 0.9)] {
            let personal = A.forecast("personal", headroom: headroom, waste: -30)
            let moment = now.addingTimeInterval(minutes * 60)
            let advice = A.advise(.short, [personal, christy], costs: .defaults, previous: previous, at: moment)
            XCTAssertEqual(advice.profileID, "personal", "\(headroom)")
            XCTAssertEqual(A.advise(.short, [personal, christy], costs: .defaults, at: moment).profileID, "christy",
                           "\(headroom) does not fit a first choice")
            previous = advice
        }
        // More than a point short is no wobble: −0.5 spendable (a running session's commitment
        // past the cautious headroom) against 1.0.
        XCTAssertEqual(A.advise(.short, [A.forecast("personal", headroom: 0, waste: -30, committedWeek: 0.5), christy], costs: .defaults,
                                previous: previous, at: now.addingTimeInterval(3600)).profileID, "christy")
    }

    /// The previous account's window no longer fitting, while the new one's does, releases it.
    func testWindowNoLongerFittingReleasesStability() {
        let christy = A.forecast("christy", headroom: 90, waste: 8)
        let previous = A.advise(.medium, [A.forecast("personal", headroom: 60, waste: 6), christy])
        XCTAssertEqual(previous.profileID, "personal", "waste within 5 of each other: config order")
        let full = A.forecast("personal", headroom: 60, waste: 6, room: 0, clearsAt: now.addingTimeInterval(600))
        let next = A.advise(.medium, [full, christy], previous: previous, at: now.addingTimeInterval(60))
        XCTAssertEqual(next.profileID, "christy", "8 against 6 is no reason to switch; Personal's full window is")
        XCTAssertEqual(A.reason(next), .useItOrLoseIt(points: 8, resetBy: A.christyReset))
    }

    // MARK: - Windows

    /// At the same tier an account that fits now beats one whose window clears in ten minutes,
    /// even with more budget to use.
    func testReadyNowBeatsOneThatClearsSoonAtSameTier() {
        let clears = now.addingTimeInterval(600)
        let personal = A.forecast("personal", headroom: 60, waste: 40, room: 0, clearsAt: clears)
        let christy = A.forecast("christy", headroom: 60, waste: 30)
        let medium = A.advise(.medium, [personal, christy])
        XCTAssertEqual(medium.profileID, "christy")
        XCTAssertEqual(medium.alternatives.first?.why, .windowFull(until: clears, roomLeft: 0, exact: false))
        // Alone, Personal is offered after its window clears.
        let alone = A.advise(.medium, [personal, A.forecast("christy", headroom: 10, waste: -50)])
        XCTAssertEqual(alone.outcome, .start(profileID: "personal", reason: .useItOrLoseIt(points: 40, resetBy: A.personalReset),
                                             afterWindowClearsAt: clears, stallsAbout: nil))
        // Not when it clears in twenty minutes: then nothing fits until it does.
        let later = now.addingTimeInterval(1200)
        let waiting = A.advise(.medium, [A.forecast("personal", headroom: 60, waste: 40, room: 0, clearsAt: later),
                                         A.forecast("christy", headroom: 3, waste: -50)])
        XCTAssertEqual(waiting.outcome, .nothingFits(next: .init(at: later, profileID: "personal", event: .windowClears, exact: false), why: .window))
    }

    func testNoAfterTimeForShort() {
        let clears = now.addingTimeInterval(600)
        let personal = A.forecast("personal", headroom: 60, waste: 40, room: 0, clearsAt: clears)
        let christy = A.forecast("christy", headroom: 60, waste: -30)
        let short = A.advise(.short, [personal, christy])
        XCTAssertEqual(short.profileID, "christy")
        let alone = A.advise(.short, [personal, A.forecast("christy", headroom: 0, waste: -90)])
        guard case .nothingFits(let next, let why) = alone.outcome else { return XCTFail("\(alone.outcome)") }
        XCTAssertEqual(next, Advice.NextChance(at: clears, profileID: "personal", event: .windowClears, exact: false))
        XCTAssertEqual(why, .window)
    }

    /// The window's end is this Mac's estimate: the title says so, as the account's own bar
    /// note does. Recorded by Claude Code, it is said plainly.
    func testAfterTimeRowIsDisabledUntilClear() {
        let clears = UsageFixtures.pdt("2026-10-05 21:10")
        let personal = A.forecast("personal", headroom: 60, waste: 40, room: 0, clearsAt: clears)
        let christy = A.forecast("christy", headroom: 0, waste: -90)
        let at = UsageFixtures.pdt("2026-10-05 21:00")
        let medium = A.advise(.medium, [personal, christy], at: at)
        let snapshot = A.snapshot([personal, christy], advice: [.medium: medium])
        let row = AdvisorText.row(medium, snapshot: snapshot, labels: A.labels, clock: A.clock(at))
        XCTAssertEqual(row.title, "Medium \u{2014} 1 to 3 hours \u{2192} Personal after 9:10 PM (est.)")
        XCTAssertEqual(row.reason, "its 5-hour window is full until then")
        XCTAssertFalse(row.isEnabled)
        XCTAssertEqual(row.enabledFrom, clears)
        XCTAssertEqual(row.profileID, "personal")
        XCTAssertEqual(row.identifier, "claude-switcher.advisor.medium")
        XCTAssertTrue(AdvisorText.row(medium, snapshot: snapshot, labels: A.labels, clock: A.clock(clears)).isEnabled, "re-enabled once clear")
        XCTAssertEqual(DiagnosticsText.adviceRows(snapshot, labels: A.labels, clock: A.clock(at)).first.map { String($0.prefix(41)) },
                       "medium  \u{2192} Personal after Mon 21:10 (est.)")

        let recorded = A.forecast("personal", headroom: 60, waste: 40, room: 0, clearsAt: clears, windowExact: true)
        let exact = A.advise(.medium, [recorded, christy], at: at)
        let exactSnapshot = A.snapshot([recorded, christy], advice: [.medium: exact])
        XCTAssertEqual(AdvisorText.row(exact, snapshot: exactSnapshot, labels: A.labels, clock: A.clock(at)).title,
                       "Medium \u{2014} 1 to 3 hours \u{2192} Personal after 9:10 PM")
    }

    // MARK: - What an account's data allows

    func testStaleAccountNeverTakesMediumOrLong() {
        let personal = A.forecast("personal", headroom: 80, waste: nil, stale: true)
        let christy = A.forecast("christy", headroom: 3, waste: -10)
        for size in [SessionSize.medium, .long] {
            guard case .nothingFits = A.advise(size, [personal, christy]).outcome else { return XCTFail("\(size)") }
        }
        XCTAssertEqual(A.advise(.short, [personal, christy]).profileID, "christy", "short: a usable account first")
        XCTAssertEqual(A.advise(.short, [personal, A.forecast("christy", headroom: 0, waste: -90)]).profileID, "personal",
                       "a stale account takes short only when nothing else fits")
        XCTAssertEqual(A.advise(.medium, [personal, christy]).alternatives.first { $0.profileID == "personal" }?.why, .notEnoughData)
    }

    /// No reset seen and no sample this week: the Advisor says there is not enough data, and
    /// shows no number for it.
    func testInsufficientDataIsSaidNotGuessed() {
        let personal = A.forecast("personal", headroom: 70, basis: .insufficient("no reset observed yet"))
        let christy = A.forecast("christy", headroom: 50, waste: -10)
        let medium = A.advise(.medium, [personal, christy])
        XCTAssertEqual(medium.profileID, "christy")
        XCTAssertEqual(medium.alternatives, [Advice.Alternative(profileID: "personal", why: .notEnoughData)])
        let text = AdvisorText.reason(medium, snapshot: A.snapshot([personal, christy]), labels: A.labels, clock: A.clock())
        XCTAssertTrue(text.hasSuffix("; Personal: not enough usage history yet"), text)
        XCTAssertFalse(text.contains("70"))
        XCTAssertEqual(ForecastText.line(personal, indexState: .ready(indexedThrough: now), clock: A.clock()), "Reset time not known yet (est.)")
    }

    /// A profile with no history at all: short only, said to be a default, and its record of
    /// usage starts with that session.
    func testDefaultsAccountTakesShortOnly() {
        let fresh = A.forecast("personal", headroom: 0, basis: .defaults)
        let christy = A.forecast("christy", headroom: 50, waste: -10)
        let short = A.advise(.short, [fresh, christy])
        XCTAssertEqual(short.profileID, "personal")
        XCTAssertEqual(A.reason(short), .noUsageRecorded)
        XCTAssertEqual(AdvisorText.reason(short, snapshot: A.snapshot([fresh, christy]), labels: A.labels, clock: A.clock()),
                       "no usage recorded yet \u{2014} a short session records it; Christy is projected to run out")
        for size in [SessionSize.medium, .long] {
            let advice = A.advise(size, [fresh, christy])
            XCTAssertEqual(advice.profileID, "christy")
            XCTAssertEqual(advice.alternatives.first?.why, .noUsageRecorded)
        }
    }

    /// Christy's first week: a sample, no reset seen. The sample is a floor; every size may go
    /// there, and the reason says the reset time is unknown.
    func testNoScheduleAccountIsEligibleForEverySize() {
        let christy = A.forecast("christy", headroom: 80, basis: .recordedNoSchedule)
        let personal = A.forecast("personal", headroom: 3, waste: -20)
        for size in SessionSize.allCases {
            let advice = A.advise(size, [personal, christy])
            XCTAssertEqual(advice.profileID, "christy", "\(size)")
            XCTAssertEqual(A.reason(advice), .resetUnknown)
        }
    }

    func testFableBlockedAccountNeverTakesMediumOrLong() {
        let until = A.personalReset
        let personal = A.forecast("personal", headroom: 60, waste: 40, blockedUntil: until, blockReason: LimitKind(rateLimitType: "seven_day_overage_included").label)
        let christy = A.forecast("christy", headroom: 50, waste: -10)
        for size in [SessionSize.medium, .long] {
            let advice = A.advise(size, [personal, christy])
            XCTAssertEqual(advice.profileID, "christy", "\(size)")
            XCTAssertEqual(advice.alternatives.first?.why, .blocked(reason: "Fable limit", until: until))
        }
        XCTAssertEqual(A.advise(.short, [personal, christy]).profileID, "personal", "the all-models week still has room for short")
        let text = AdvisorText.alternativeText(.init(profileID: "personal", why: .blocked(reason: "Fable limit", until: until)),
                                               labels: A.labels, snapshot: A.snapshot([personal]), clock: A.clock())
        XCTAssertEqual(text, "Personal: Fable limit reached until Sat 9 PM")
    }

    /// A5: a known plan other than Max 20x on default calibration gets short sessions only.
    func testAccountOnAnotherPlanTakesShortOnlyUntilCalibrated() {
        let pro = A.forecast("personal", headroom: 90, waste: 40, plan: .named("claude_pro"))
        let christy = A.forecast("christy", headroom: 50, waste: -10)
        XCTAssertEqual(A.advise(.medium, [pro, christy]).profileID, "christy")
        XCTAssertEqual(A.advise(.short, [pro, christy]).profileID, "personal")
        let calibrated = Calibration(weekly: Calibration.defaultWeekly, window: Calibration.defaultWindow, rmse: 2, segments: 3,
                                     medianR2: 0.99, windows: 9)
        XCTAssertEqual(A.advise(.medium, [A.forecast("personal", headroom: 90, waste: 40, calibration: calibrated, plan: .named("claude_pro")),
                                          christy]).profileID, "personal", "its own history speaks for it")
    }

    /// A5: the scale gate dropped an account's calibration because it spends its limit four
    /// times faster than calibrated — a smaller plan, whose medium and long sessions cost four
    /// times the Max 20x defaults. With its plan unknown (the CLI names only the account it is
    /// signed in to), short sessions only until it recalibrates. Not when the plan is Max 20x
    /// (the defaults cannot be too small), nor for a 2.4× trip (use this Mac cannot see).
    func testFlaggedCalibrationRefusesMediumAndLongUntilCalibrated() {
        func flagged(ratio: Double) -> Calibration {
            Calibration(weekly: Calibration.defaultWeekly, window: Calibration.defaultWindow, rmse: 3, segments: 0, medianR2: nil,
                        windows: 0, flag: Calibration.planChangedFlag, tripRatio: ratio)
        }
        let personal = A.forecast("personal", headroom: 5, waste: -10)
        func christy(ratio: Double, plan: PlanLabel) -> UsageForecast {
            A.forecast("christy", headroom: 51, waste: nil, calibration: flagged(ratio: ratio), plan: plan)
        }
        let held = christy(ratio: 4, plan: .unknown)
        for size in [SessionSize.medium, .long] {
            let advice = A.advise(size, [personal, held])
            XCTAssertNotEqual(advice.profileID, "christy", "\(size)")
            XCTAssertEqual(advice.alternatives.first { $0.profileID == "christy" }?.why, .recalibrating, "\(size)")
        }
        XCTAssertEqual(A.advise(.short, [personal, held]).profileID, "christy", "short sessions still go there")
        XCTAssertEqual(AdvisorText.alternativeText(.init(profileID: "christy", why: .recalibrating), labels: A.labels, snapshot: A.snapshot([held]),
                                                   clock: A.clock()),
                       "Christy: the last recorded usage disagrees with the calibration \u{2014} short sessions only until it recalibrates")
        for allowed in [christy(ratio: 4, plan: .max20x), christy(ratio: 2.4, plan: .unknown)] {
            for size in [SessionSize.medium, .long] {
                XCTAssertEqual(A.advise(size, [personal, allowed]).profileID, "christy", "\(size), \(allowed.plan), \(allowed.calibration.tripRatio!)")
            }
        }
        // Diagnostics says where it tripped and the rule.
        XCTAssertTrue(DiagnosticsText.calibration(held, costs: A.a15).contains("tripped at 4.0\u{00D7}"), DiagnosticsText.calibration(held, costs: A.a15))
    }

    /// A5 with the plan named: `~/.claude.json` once named Personal's tier as Max 20x and now
    /// names it Pro. The index dated the change; the calibration restarts there, and with the
    /// defaults (a Max 20x account's) Pro gets short sessions only — though its numbers would fit.
    func testNamedTierChangeRestrictsMediumAndLong() {
        var account = CalibrationTests.Synthetic(start: UsageFixtures.pdt("2026-09-21 06:00"))
        account.segment(k: 1 / 13.5, spend: 30)
        account.segment(k: 1 / 13.5, spend: 30)
        let moment = account.clock
        let full = account.ledger
        func personal(tier: String, changedAt: Date?) -> UsageForecast {
            let ledger = ActivityLedger(sessions: full.sessions, anchors: [], indexedThrough: moment, tier: tier, tierChangedAt: changedAt)
            return UsageForecast.make(profileID: "personal", samples: account.samples, activity: ledger, exact: nil, busySessions: [],
                                      costs: A.a15, now: moment)
        }
        let christy = A.forecast("christy", headroom: 40, waste: -10, at: moment)
        let pro = personal(tier: "claude_pro", changedAt: moment.addingTimeInterval(-3600))
        XCTAssertEqual(pro.plan, .named("claude_pro"), "the remembered tier, the CLI signed in elsewhere")
        XCTAssertEqual(pro.calibration.flag, Calibration.planChangedFlag)
        XCTAssertTrue(pro.calibration.weeklyIsDefault)
        for size in [SessionSize.medium, .long] {
            let advice = UsageAdvisor.advise(size: size, forecasts: ["personal": pro, "christy": christy], costs: A.a15, order: A.order,
                                             previous: nil, now: moment)
            XCTAssertEqual(advice.profileID, "christy", "\(size)")
            XCTAssertEqual(advice.alternatives.first?.why, .otherPlan("claude_pro"), "\(size)")
        }
        // The same history on Max 20x, its tier never changed: calibrated, and medium goes there.
        let max = personal(tier: "default_claude_max_20x", changedAt: nil)
        XCTAssertFalse(max.calibration.weeklyIsDefault)
        XCTAssertEqual(UsageAdvisor.advise(size: .medium, forecasts: ["personal": max, "christy": christy], costs: A.a15, order: A.order,
                                           previous: nil, now: moment).profileID, "personal")
    }

    /// The reserve may be an account whose window is full but clears within the hour: Christy
    /// (50 % left, window full until 30 minutes from now) holds it, so Personal (7 % left — a
    /// medium session would leave it 2) may take a medium session. At 90 minutes she does not,
    /// and nothing fits.
    func testReserveCountsAnAccountWhoseWindowClearsWithinAnHour() {
        let personal = A.forecast("personal", headroom: 7, waste: -10)
        let soon = A.forecast("christy", headroom: 50, waste: -10, room: 0, clearsAt: now.addingTimeInterval(30 * 60))
        XCTAssertEqual(A.advise(.medium, [personal, soon]).profileID, "personal")
        let late = A.forecast("christy", headroom: 50, waste: -10, room: 0, clearsAt: now.addingTimeInterval(90 * 60))
        let advice = A.advise(.medium, [personal, late])
        guard case .nothingFits = advice.outcome else { return XCTFail("\(advice.outcome)") }
        XCTAssertEqual(advice.alternatives.first { $0.profileID == "personal" }?.why, .noReserve)
    }

    /// Five points that would go unused is the top tier, four is "will run out": against an
    /// account whose waste is unknown, 5 wins and 4 loses.
    func testWasteOfFiveIsTheTopTier() {
        let christy = A.forecast("christy", headroom: 90, waste: nil)
        XCTAssertEqual(A.advise(.medium, [A.forecast("personal", headroom: 60, waste: 5), christy]).profileID, "personal")
        XCTAssertEqual(A.advise(.medium, [A.forecast("personal", headroom: 60, waste: 4), christy]).profileID, "christy")
    }

    func testSingleAccountSaysNoReservePossible() {
        let personal = A.forecast("personal", headroom: 30, waste: -20)
        let advice = UsageAdvisor.advise(size: .medium, forecasts: ["personal": personal], costs: A.a15, order: ["personal"],
                                         previous: nil, now: now)
        XCTAssertEqual(advice.profileID, "personal", "30 − 5 leaves 25 here, above the reserve of 4")
        XCTAssertEqual(A.reason(advice), .resetsSoonest(resetBy: A.personalReset))
        let snapshot = A.snapshot([personal], advice: [.medium: advice])
        XCTAssertTrue(AdvisorText.footer(snapshot, labels: A.labels, clock: A.clock()).contains("Only one account \u{2014} no reserve is possible"))
        // With 6 left a medium session would take it below the reserve: nothing fits.
        let thin = UsageAdvisor.advise(size: .medium, forecasts: ["personal": A.forecast("personal", headroom: 6, waste: -20)], costs: A.a15,
                                       order: ["personal"], previous: nil, now: now)
        guard case .nothingFits(_, .reserve) = thin.outcome else { return XCTFail("\(thin.outcome)") }
    }

    /// Both accounts at the weekly limit: nothing fits, and the next chance is Personal's
    /// Saturday 21:00 reset, which comes before Christy's Monday one.
    func testNothingFitsNamesTheNextChance() {
        let personal = A.forecast("personal", headroom: 0, waste: -60)
        let christy = A.forecast("christy", headroom: 0, waste: -40)
        let long = A.advise(.long, [personal, christy])
        XCTAssertEqual(long.outcome, .nothingFits(next: .init(at: A.personalReset, profileID: "personal", event: .weeklyReset, exact: true),
                                                    why: .weeklyLimit), "Personal's schedule is exact and fresh")
        XCTAssertEqual(long.nextChanceAt, UsageFixtures.pdt("2026-10-10 21:00"))
        let row = AdvisorText.row(long, snapshot: A.snapshot([personal, christy]), labels: A.labels, clock: A.clock())
        XCTAssertEqual(row.title, "Long \u{2014} over 3 hours or a workflow run \u{2192} nothing fits right now")
        XCTAssertFalse(row.isEnabled)
        XCTAssertNil(row.profileID)
        XCTAssertEqual(row.reason, "both accounts are at or near the weekly limit; next chance Sat 9 PM when Personal resets")
    }

    // MARK: - Ranking details

    func testUnknownWasteRanksByHeadroomWithinTenPoints() {
        let personal = A.forecast("personal", headroom: 85, waste: nil, room: 40)
        let christy = A.forecast("christy", headroom: 92, waste: nil, room: 90)
        let medium = A.advise(.medium, [personal, christy])
        XCTAssertEqual(medium.profileID, "christy")
        XCTAssertEqual(A.reason(medium), .mostHeadroom(points: 92), "within 10 of each other: window room decided, said as headroom")
        XCTAssertEqual(A.advise(.medium, [A.forecast("personal", headroom: 60, waste: nil), christy]).profileID, "christy")
        // The margin decides: 7 points less headroom but far more window room wins…
        let roomy = A.forecast("personal", headroom: 85, waste: nil, room: 90)
        let tight = A.forecast("christy", headroom: 92, waste: nil, room: 40)
        let tie = A.advise(.medium, [roomy, tight])
        XCTAssertEqual(tie.profileID, "personal", "85 against 92 is within 10: a tie on headroom, then window room")
        XCTAssertEqual(A.reason(tie), .mostHeadroom(points: 85))
        // …22 points less does not.
        XCTAssertEqual(A.advise(.medium, [A.forecast("personal", headroom: 70, waste: nil, room: 90), tight]).profileID, "christy")
        // Equal in everything: a running account first, then config order.
        let a = A.forecast("personal", headroom: 90, waste: nil), b = A.forecast("christy", headroom: 90, waste: nil)
        XCTAssertEqual(A.advise(.medium, [a, b]).profileID, "personal")
        XCTAssertEqual(A.advise(.medium, [a, b], running: ["christy"]).profileID, "christy")
    }

    func testCommittedSessionCountsAgainstTheAccount() {
        // A long session is running on Personal with 4 points still to come: it no longer fits long.
        let personal = A.forecast("personal", headroom: 15, waste: 20, committedWeek: 4)
        let christy = A.forecast("christy", headroom: 50, waste: -20)
        let long = A.advise(.long, [personal, christy])
        XCTAssertEqual(long.profileID, "christy")
        XCTAssertEqual(long.alternatives.first?.why, .committed(points: 4))
        XCTAssertEqual(A.advise(.long, [A.forecast("personal", headroom: 15, waste: 20), christy]).profileID, "personal",
                       "without the running session it would have")
    }
}
