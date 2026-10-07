import XCTest
@testable import ClaudeSwitcherCore

/// The one façade: every account's forecast and the Advisor's three answers at one moment.
final class UsageSnapshotTests: XCTestCase {

    private typealias F = UsageFixtures
    private typealias A = AdvisorFixtures
    private func pdt(_ text: String) -> Date { F.pdt(text) }

    private let personal = Profile(id: "personal", label: "Personal")
    private let christy = Profile(id: "christy", label: "Christy", userDataDir: "~/Library/Application Support/Claude-christy")

    /// This Mac on Mon 10-05 18:47, as the research found it: Personal's only sample this week
    /// reads 0 % from Sunday morning while its transcripts show about 62 % spent; Christy read 0 %
    /// minutes ago, 14 hours into her week.
    private func realRegime(_ state: ActivityIndexState, activity: Bool = true) -> UsageSnapshot {
        let now = A.now
        let ledgers = ["personal": F.ledger14d("p", anchors: F.personalWeeklyAnchors), "christy": F.ledger14d("c", anchors: F.christyWeeklyAnchors)]
        return UsageSnapshot.make(profiles: [personal, christy], samples: ["personal": F.personal(through: now), "christy": F.christy(through: now)],
                                  exact: [:], activity: activity ? ledgers : nil, indexState: state, previous: [:], busy: [:], now: now)
    }

    /// While the index is being built there is no advice and no estimate: the samples alone
    /// would send a long session to Personal, whose 0 % is 33 hours old and most of a week stale.
    func testIndexBuildingYieldsNoAdvice() {
        let building = realRegime(.building)
        XCTAssertTrue(building.advice.isEmpty)
        let menu = AdvisorText.menu(building, labels: A.labels, clock: A.clock())
        XCTAssertTrue(menu.rows.isEmpty)
        XCTAssertEqual(menu.placeholder, "Reading activity\u{2026}")
        for id in ["personal", "christy"] {
            let f = building.forecasts[id]!
            XCTAssertFalse(f.activityKnown)
            XCTAssertEqual(ForecastText.line(f, indexState: .building, clock: A.clock()), "Reading activity\u{2026}")
            XCTAssertNil(f.estimatedPercent(for: "sd"), "recorded values only")
        }
        XCTAssertEqual(building.forecasts["personal"]?.weekUsed.value, 0, "the recorded value, nothing added")
        XCTAssertEqual(DiagnosticsText.dryRunAdvice(building, labels: A.labels, clock: A.clock()), [DiagnosticsText.needsIndex])

        // The index says otherwise: Personal has spent most of its week.
        let ready = realRegime(.ready(indexedThrough: A.now))
        XCTAssertEqual(ready.advice[.long]?.profileID, "christy")
        XCTAssertEqual(ready.forecasts["personal"]!.weekUsed.value, 62, accuracy: 4)
    }

    /// Diagnostics and `--dry-run` keep the same rule while the index is built: recorded values
    /// and the window's bound only — no pace, no run-out, no "unused" — and they say what the
    /// estimates wait for.
    func testIndexBuildingDiagnosticsShowRecordedOnly() {
        let building = realRegime(.building)
        for id in ["personal", "christy"] {
            let f = building.forecasts[id]!
            let lines = DiagnosticsText.accountLines(f, costs: building.costs, clock: A.clock(), indexState: building.indexState)
            for line in lines {
                for word in ["pace", "runs out", "unused"] { XCTAssertFalse(line.contains(word), "\(id): \(line)") }
            }
            let forecast = DiagnosticsText.forecast(f, clock: A.clock(), indexState: building.indexState)
            XCTAssertTrue(forecast.contains("needs the activity index"), forecast)
            XCTAssertTrue(DiagnosticsText.forecast(f, clock: A.clock()).contains("needs the activity index"), "without the state too")
        }
        XCTAssertTrue(DiagnosticsText.forecast(building.forecasts["personal"]!, clock: A.clock()).hasPrefix("week 0% used (recorded)"))
    }

    /// The index on disk was last brought up to date a day ago (a `--dry-run` reading a stored
    /// index): a day's spend is unknown, so nothing is advised and nothing estimated — and it says
    /// how old the index is. Within the hour the bounds widen for the unread time instead.
    func testStaleIndexGivesNoAdvice() throws {
        let now = A.now
        let through = now.addingTimeInterval(-24 * 3600)
        let ledgers = ["personal": F.ledger14d("p", anchors: F.personalWeeklyAnchors), "christy": F.ledger14d("c", anchors: F.christyWeeklyAnchors)]
        func snapshot(readThrough: Date) -> UsageSnapshot {
            UsageSnapshot.make(profiles: [personal, christy], samples: ["personal": F.personal(through: now), "christy": F.christy(through: now)],
                               exact: [:], activity: ledgers, indexState: .ready(indexedThrough: readThrough), previous: [:], busy: [:], now: now)
        }
        let stale = snapshot(readThrough: through)
        XCTAssertTrue(stale.advice.isEmpty)
        XCTAssertEqual(stale.indexState, .stale(indexedThrough: through))
        XCTAssertEqual(DiagnosticsText.dryRunAdvice(stale, labels: A.labels, clock: A.clock()),
                       ["advice: activity last read 24 h ago \u{2014} open the Claude Switcher menu to refresh it"])
        XCTAssertEqual(AdvisorText.menu(stale, labels: A.labels, clock: A.clock()).placeholder,
                       "Activity last read 24 h ago \u{2014} open the Claude Switcher menu to refresh it")
        let p = try XCTUnwrap(stale.forecasts["personal"])
        XCTAssertFalse(p.activityKnown)
        XCTAssertEqual(p.weekUsed.value, 0, "the recorded value, nothing added")
        XCTAssertEqual(ForecastText.line(p, indexState: stale.indexState, clock: A.clock()), "Activity last read 24 h ago")
        XCTAssertTrue(DiagnosticsText.forecast(p, clock: A.clock(), indexState: stale.indexState)
            .contains("needs the activity index (last read 24 h ago \u{2014} open the Claude Switcher menu to refresh it)"))

        // Read half an hour ago: advice, with the cautious bound half an hour of its fastest
        // recent hour higher than when read just now.
        let current = snapshot(readThrough: now)
        let recent = snapshot(readThrough: now.addingTimeInterval(-1800))
        XCTAssertFalse(recent.advice.isEmpty)
        let ledger = ledgers["personal"]!
        let fastest = (0..<6).map { ledger.spend(from: ledger.indexedThrough.addingTimeInterval(-Double($0 + 1) * 3600),
                                                 to: ledger.indexedThrough.addingTimeInterval(-Double($0) * 3600)) }.max()!
        XCTAssertGreaterThan(fastest, 0)
        let before = try XCTUnwrap(current.forecasts["personal"]), after = try XCTUnwrap(recent.forecasts["personal"])
        XCTAssertEqual(after.weekUsed.high, min(100, before.weekUsed.high + before.calibration.weekly * fastest * 0.5), accuracy: 1e-9)
        XCTAssertEqual(after.headroom.low, 100 - after.weekUsed.high, accuracy: 1e-9)
        XCTAssertEqual(after.weekUsed.value, before.weekUsed.value, "the estimate itself is unchanged")
    }

    /// The design's worked example: everything goes to Christy — most headroom, her waste still
    /// unknown — and Personal is projected to run out; a long session fits on Personal only for
    /// its first three hours.
    func testWorkedExampleUnderTheRealRegime() throws {
        let snapshot = realRegime(.ready(indexedThrough: A.now))
        let p = try XCTUnwrap(snapshot.forecasts["personal"])
        let c = try XCTUnwrap(snapshot.forecasts["christy"])
        XCTAssertEqual(p.weekUsed.high, 72, accuracy: 4)
        XCTAssertLessThan(p.waste ?? 0, 0)
        XCTAssertEqual(p.weekEnd, pdt("2026-10-10 21:00"))
        XCTAssertNil(c.waste, "14 hours in, under 10 %: no pace yet")
        XCTAssertEqual(c.headroom.low, 94, accuracy: 0.5)
        for size in SessionSize.allCases {
            let advice = try XCTUnwrap(snapshot.advice[size])
            XCTAssertEqual(advice.profileID, "christy", "\(size)")
            XCTAssertEqual(A.reason(advice), .mostHeadroom(points: 93), "94 less the unseen-use allowance since the 18:19 sample, rounded down")
        }
        XCTAssertEqual(snapshot.advice[.short]?.alternatives.first?.why, .projectedToRunOut)
        let menu = AdvisorText.menu(snapshot, labels: A.labels, clock: A.clock())
        XCTAssertEqual(menu.rows.first?.reason, "most headroom (~93% left, est.); Personal is projected to run out")
        XCTAssertEqual(menu.footer.last, "Costs are defaults for Max 20x; Christy\u{2019}s plan is unknown")
        XCTAssertTrue(menu.footer.contains("Reset times: Personal exact, Christy exact \u{00B7} usage last recorded 33 h / 28 min ago"), "\(menu.footer)")
        XCTAssertEqual(menu.footer.first, "Costs from your last 30 days (short 26, long 43 sessions); medium uses defaults for Max 20x")

        // Both at 100: nothing fits until Personal's Saturday reset.
        let full = UsageSnapshot.make(
            profiles: [personal, christy],
            samples: ["personal": F.personal(through: A.now) + [UsageSample(sampledAt: A.now, org: "org-personal", utilization: ["fh": 0, "sd": 100])],
                      "christy": F.christy(through: A.now) + [UsageSample(sampledAt: A.now, org: "org-christy", utilization: ["fh": 0, "sd": 100])]],
            exact: [:], activity: ["personal": F.ledger14d("p", anchors: F.personalWeeklyAnchors), "christy": F.ledger14d("c", anchors: F.christyWeeklyAnchors)],
            indexState: .ready(indexedThrough: A.now), previous: [:], busy: [:], now: A.now)
        XCTAssertEqual(full.advice[.medium]?.nextChanceAt, pdt("2026-10-10 21:00"))
    }

    /// The façade only reads: the usage histories, the index's ledgers, `~/.claude.json`.
    func testReadOnlyReadsAndUsesTheExactSource() throws {
        let f = try ActivityFixture()
        let now = f.now
        func history(_ profile: Profile, _ samples: [(Date, Int, Int)]) throws {
            let url = UsageHistory.fileURL(forUserDataDir: profile.userDataDir, home: f.home.home)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let entries = samples.map { ["t": $0.0.timeIntervalSince1970 * 1000, "org": "o", "u": ["fh": $0.1, "sd": $0.2]] as [String: Any] }
            try JSONSerialization.data(withJSONObject: ["version": 2, "samples": entries]).write(to: url)
        }
        try history(ActivityFixture.personal, [(now.addingTimeInterval(-7200), 10, 40)])
        try history(ActivityFixture.work, [(now.addingTimeInterval(-600), 5, 12)])
        let body: [String: Any] = ["seven_day": ["utilization": 47.0, "resets_at": "2026-10-11T04:00:00.430546+00:00"]]
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": ["accountUuid": FakeHome.accountA, "organizationRateLimitTier": "default_claude_max_20x"],
            "cachedUsageUtilization": ["fetchedAtMs": (now.timeIntervalSince1970 - 120) * 1000, "accountUuid": FakeHome.accountA, "utilization": body],
        ]).write(to: f.home.root.appendingPathComponent(".claude.json"))
        let refresh = f.refresh()
        let before = f.home.snapshot()
        let snapshot = UsageSnapshot.read(profiles: f.profiles, home: f.home.home, activity: refresh.ledgers,
                                          indexState: .ready(indexedThrough: now), previous: [:], busy: [:], now: now)
        XCTAssertEqual(f.home.snapshot(), before, "nothing written")
        let personal = try XCTUnwrap(snapshot.forecasts[ActivityFixture.personal.id])
        XCTAssertEqual(personal.weekUsed.low, 47, "the cached body, two minutes old, is the latest sample")
        XCTAssertEqual(personal.plan, .max20x)
        XCTAssertTrue(personal.schedule?.isExact ?? false, "its reset time anchors the schedule")
        XCTAssertEqual(snapshot.forecasts[ActivityFixture.work.id]?.weekUsed.low, 12)
        XCTAssertEqual(snapshot.forecasts[ActivityFixture.work.id]?.plan, .unknown)
        XCTAssertEqual(snapshot.advice.count, 3)
        XCTAssertEqual(snapshot.order, f.profiles.map(\.id))
    }

    /// A busy session counts against the account whose records claim it, else the one whose
    /// ledger holds it; an idle one counts nowhere.
    func testBusySessionsAreAttributed() {
        let x = "c1c1c1c1-aaaa-4aaa-8aaa-aaaaaaaaaaaa", y = "c2c2c2c2-aaaa-4aaa-8aaa-aaaaaaaaaaaa", z = "c3c3c3c3-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let running = RunningSessions(entries: [
            .init(pid: 1, cliSessionId: x.uppercased(), hostSessionId: nil, isBusy: true),
            .init(pid: 2, cliSessionId: y, hostSessionId: nil, isBusy: true),
            .init(pid: 3, cliSessionId: z, hostSessionId: nil, isBusy: false),
        ])
        let attribution = ActivityAttribution(accounts: ["personal": "a", "work": "b"], claims: [x: "a"])
        let ledgers = ["work": F.ledger([(A.now, 1)], session: y)]
        let busy = BusySession.attribute(running: running, attribution: attribution, ledgers: ledgers)
        XCTAssertEqual(busy["personal"], [BusySession(cliSessionId: x)])
        XCTAssertEqual(busy["work"], [BusySession(cliSessionId: y)])
        XCTAssertEqual(busy.values.flatMap { $0 }.count, 2)
    }

    /// Without any accounts there is nothing to advise.
    func testNoProfilesNoAdvice() {
        let snapshot = UsageSnapshot.make(profiles: [], samples: [:], exact: [:], activity: [:], indexState: .ready(indexedThrough: A.now),
                                          previous: [:], busy: [:], now: A.now)
        XCTAssertTrue(snapshot.advice.isEmpty)
        XCTAssertTrue(snapshot.forecasts.isEmpty)
    }
}
