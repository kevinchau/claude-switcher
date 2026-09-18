import XCTest
@testable import ClaudeSwitcherCore

/// Reading Claude Desktop's per-profile usage history, inferring the session window, and
/// the words shown for it. Fixtures are built in memory or under a temporary directory;
/// nothing here reads the real `~/Library/Application Support`, and nothing is written
/// outside the temporary directory.
final class UsageHistoryTests: XCTestCase {

    private var directory: URL!

    /// A fixed moment; series are expressed as minute offsets from it.
    private let base = Date(timeIntervalSince1970: 1_789_600_000)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-switcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func sample(_ minutes: Double, fh: Int? = nil, sd: Int? = nil, org: String? = "org-a", extra: [String: Int] = [:]) -> UsageSample {
        var u = extra
        if let fh { u["fh"] = fh }
        if let sd { u["sd"] = sd }
        return UsageSample(sampledAt: at(minutes), org: org, utilization: u)
    }

    /// A v2 file the way the app writes it.
    private func v2(_ samples: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 2, "samples": samples])
    }

    private func entry(_ minutes: Double, _ u: [String: Any], org: Any = "org-a") -> [String: Any] {
        ["t": Int(at(minutes).timeIntervalSince1970 * 1000), "org": org, "u": u]
    }

    /// The clock-time renderer used by the text helpers: minute offsets from `base`, so the
    /// expected strings are independent of locale and time zone.
    private func minutes(_ date: Date) -> String {
        "+\(Int(date.timeIntervalSince(base) / 60))m"
    }

    // MARK: - Parsing

    func testVersionTwoSamplesDecodeWithOrgAndUtilization() throws {
        let data = try v2([entry(0, ["fh": 22, "sd": 92])])
        let samples = try XCTUnwrap(UsageHistory.samples(from: data))
        XCTAssertEqual(samples, [sample(0, fh: 22, sd: 92)])
    }

    func testVersionOneSamplesDecodeWithNullsDropped() throws {
        let file: [String: Any] = ["version": 1, "samples": [
            ["t": Int(at(0).timeIntervalSince1970 * 1000), "fh": 7, "sd": NSNull()],
        ]]
        let samples = try XCTUnwrap(UsageHistory.samples(from: try JSONSerialization.data(withJSONObject: file)))
        XCTAssertEqual(samples, [UsageSample(sampledAt: at(0), org: nil, utilization: ["fh": 7])])
    }

    func testSamplesComeBackSortedByTimeWhateverTheFileOrder() throws {
        let data = try v2([entry(30, ["fh": 5]), entry(0, ["fh": 1]), entry(15, ["fh": 3])])
        XCTAssertEqual(UsageHistory.samples(from: data)?.map { $0.utilization["fh"] }, [1, 3, 5])
    }

    func testGarbageEmptyPlistOrNonUsageJSONYieldsNil() throws {
        XCTAssertNil(UsageHistory.samples(from: Data()))
        XCTAssertNil(UsageHistory.samples(from: Data([0x00, 0xFF])))
        XCTAssertNil(UsageHistory.samples(from: Data("[1,2,3]".utf8)))
        XCTAssertNil(UsageHistory.samples(from: Data(#"{"samples": []}"#.utf8)), "no version key")
        XCTAssertNil(UsageHistory.samples(from: Data(#"{"version": 2}"#.utf8)), "no samples")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["version": 2, "samples": []], format: .xml, options: 0)
        XCTAssertNil(UsageHistory.samples(from: plist))
    }

    func testASampleWithoutATimestampIsSkippedNotFatal() throws {
        let data = try v2([["org": "org-a", "u": ["fh": 1]], entry(0, ["fh": 2])])
        XCTAssertEqual(UsageHistory.samples(from: data), [sample(0, fh: 2)])
    }

    func testNonNumericValuesAreDroppedAndTheRestClamped() throws {
        let data = try v2([entry(0, ["fh": "lots", "sd": 250, "so": -4, "sn": 33.6, "cw": true])])
        let samples = try XCTUnwrap(UsageHistory.samples(from: data))
        XCTAssertEqual(samples.first?.utilization, ["sd": 100, "so": 0, "sn": 34])
    }

    func testUnknownUtilizationKeysAreKeptVerbatim() throws {
        let data = try v2([entry(0, ["fh": 1, "zz": 9])])
        XCTAssertEqual(UsageHistory.samples(from: data)?.first?.utilization["zz"], 9)
    }

    func testMissingOrUnreadableFileReadsAsNil() throws {
        let dir = directory.appendingPathComponent("Claude-work").path
        XCTAssertNil(UsageHistory.read(userDataDir: dir))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent(UsageHistory.fileName))
        XCTAssertNil(UsageHistory.read(userDataDir: dir))
        try v2([entry(0, ["fh": 4])]).write(to: URL(fileURLWithPath: dir).appendingPathComponent(UsageHistory.fileName))
        XCTAssertEqual(UsageHistory.read(userDataDir: dir), [sample(0, fh: 4)])
    }

    func testFileURLForTheDefaultProfileIsUnderTheAppsOwnApplicationSupportFolder() {
        XCTAssertEqual(
            UsageHistory.fileURL(forUserDataDir: nil, home: "/Users/testhome").path,
            "/Users/testhome/Library/Application Support/Claude/plan-usage-history.json"
        )
    }

    func testFileURLForANamedProfileIsInsideItsNormalizedUserDataDir() {
        XCTAssertEqual(
            UsageHistory.fileURL(forUserDataDir: "~/Library/Application Support/Claude-work/", home: "/Users/testhome").path,
            "/Users/testhome/Library/Application Support/Claude-work/plan-usage-history.json"
        )
    }

    /// The reserved-directory check and the usage reader must agree on where the default
    /// profile lives; both go through `Config.defaultUserDataDir`.
    func testTheDefaultProfileDirectoryIsTheSameStringTheReservedDirectoryCheckRejects() {
        var config = Config.defaultConfig()
        let reserved = Config.defaultUserDataDir()
        XCTAssertThrowsError(try config.addProfile(Profile(id: "x", label: "X", userDataDir: reserved))) { error in
            guard case ConfigError.reservedUserDataDir = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(UsageHistory.fileURL(forUserDataDir: nil).deletingLastPathComponent().path, reserved)
    }

    func testOnlySamplesOfTheLatestOrgAreUsed() {
        let samples = [sample(0, fh: 90, org: "org-b"), sample(15, fh: 3, org: "org-a"), sample(30, fh: 5, org: "org-a")]
        XCTAssertEqual(UsageHistory.currentOrgSamples(samples).count, 2)
        // org-b's 90 must not be taken as a drop bounding org-a's window from below.
        let window = try? XCTUnwrap(SessionWindow.infer(from: UsageHistory.currentOrgSamples(samples)))
        XCTAssertEqual(window?.resetsAfter, at(30))
    }

    // MARK: - Session window inference

    func testLatestSampleAtZeroInfersNoWindow() {
        XCTAssertNil(SessionWindow.infer(from: [sample(0, fh: 40), sample(15, fh: 0)]))
        XCTAssertNil(SessionWindow.infer(from: [sample(0, sd: 50)]), "no session value at all")
    }

    func testResetIsByFiveHoursAfterTheFirstPositiveSampleOfTheRun() throws {
        let window = try XCTUnwrap(SessionWindow.infer(from: [sample(0, fh: 12), sample(15, fh: 14), sample(30, fh: 16)]))
        XCTAssertEqual(window.resetsBy, at(300))
        XCTAssertEqual(window.utilization, 16)
    }

    /// The real Christy series: 15:58 fh 40, then 16:13 fh 2 … 20:47 fh 22 — the drop ends
    /// the previous window, so this one ends after 15:58 + 5 h and by 16:13 + 5 h.
    func testADropEndsTheRunAndBoundsTheResetFromBelow() throws {
        let series = [sample(0, fh: 40), sample(15, fh: 2), sample(30, fh: 12), sample(45, fh: 14),
                      sample(60, fh: 14), sample(75, fh: 16), sample(264, fh: 20), sample(289, fh: 22)]
        let window = try XCTUnwrap(SessionWindow.infer(from: series))
        XCTAssertEqual(window.resetsAfter, at(300))
        XCTAssertEqual(window.resetsBy, at(315))
    }

    func testAZeroInsideTheRunDoesNotMoveEitherBound() throws {
        // Christy's first window: a 0 at 15:13, then 2 at 15:28. The window was running by 15:28.
        let window = try XCTUnwrap(SessionWindow.infer(from: [sample(0, fh: 0), sample(15, fh: 2), sample(30, fh: 4)]))
        XCTAssertEqual(window.resetsBy, at(315))
        XCTAssertEqual(window.resetsAfter, at(30))
    }

    /// Personal: 13:51 fh 0 after a drop, 14:03 fh 12. The zero is not proof the window had
    /// not started; the lower bound comes from the earlier window, not from the zero.
    func testAZeroBeforeTheRunIsNotTakenAsProofTheWindowHadNotStarted() throws {
        let series = [sample(0, fh: 30), sample(60, fh: 0), sample(72, fh: 12)]
        let window = try XCTUnwrap(SessionWindow.infer(from: series))
        XCTAssertEqual(window.resetsAfter, at(300), "five hours after the 30, not after the 0")
        XCTAssertEqual(window.resetsBy, at(372))
    }

    func testAGapOfFiveHoursOrMoreStartsANewRunEvenWhenUsageKeptRising() throws {
        let window = try XCTUnwrap(SessionWindow.infer(from: [sample(0, fh: 7), sample(336, fh: 13)]))
        XCTAssertEqual(window.resetsBy, at(636))
        XCTAssertEqual(window.resetsAfter, at(336), "the latest sample; the old window's +5 h is already past")
    }

    func testAThreeHourGapInsideTheWindowKeepsTheRun() throws {
        let window = try XCTUnwrap(SessionWindow.infer(from: [sample(0, fh: 5), sample(15, fh: 16), sample(195, fh: 20)]))
        XCTAssertEqual(window.resetsBy, at(300))
    }

    func testEqualConsecutiveValuesStayInOneRun() throws {
        let window = try XCTUnwrap(SessionWindow.infer(from: [sample(0, fh: 14), sample(15, fh: 14), sample(30, fh: 14)]))
        XCTAssertEqual(window.resetsBy, at(300))
    }

    func testTheLowerBoundNeverPrecedesTheLatestSample() throws {
        let window = try XCTUnwrap(SessionWindow.infer(from: [sample(0, fh: 50), sample(400, fh: 1)]))
        XCTAssertEqual(window.resetsAfter, at(400))
        XCTAssertEqual(window.resetsBy, at(700))
    }

    func testASingleSampleGivesTheFullFiveHourRange() throws {
        let window = try XCTUnwrap(SessionWindow.infer(from: [sample(0, fh: 34)]))
        XCTAssertEqual(window.resetsAfter, at(0))
        XCTAssertEqual(window.resetsBy, at(300))
    }

    // MARK: - Weekly reset (a fixed weekly schedule)

    private let day: Double = 24 * 60

    func testNoObservedDropMeansNoWeeklyReset() {
        XCTAssertNil(WeeklyReset.infer(from: [sample(0, sd: 10), sample(day, sd: 40)], now: at(2 * day)))
    }

    /// A drop between two samples brackets one reset; the schedule repeats, so the next
    /// reset is that bracket moved forward by whole weeks until it is still ahead of now.
    func testADropBracketsTheResetAndRepeatsWeekly() throws {
        let series = [sample(0, sd: 60), sample(3 * 60, sd: 2)]        // reset between +0 and +3 h
        let soon = try XCTUnwrap(WeeklyReset.infer(from: series, now: at(60)))
        XCTAssertEqual(soon.resetsAfter, at(0))
        XCTAssertEqual(soon.resetsBy, at(3 * 60), "now is inside the bracket: this occurrence may not have happened yet")
        let later = try XCTUnwrap(WeeklyReset.infer(from: series, now: at(6 * day)))
        XCTAssertEqual(later.resetsAfter, at(7 * day))
        XCTAssertEqual(later.resetsBy, at(7 * day + 3 * 60))
        let muchLater = try XCTUnwrap(WeeklyReset.infer(from: series, now: at(20 * day)))
        XCTAssertEqual(muchLater.resetsBy, at(21 * day + 3 * 60), "day 7 and day 14 have passed; day 21 is next")
    }

    /// Personal, week over week: a tight bracket one week and a wide one the next intersect
    /// to the tight one. The bound gets better the longer the app is around at reset time.
    func testEarlierWeeksNarrowTheBracketWhenTheyAgree() throws {
        let series = [
            sample(0, sd: 80), sample(15, sd: 1),                           // week 1: reset in (+0, +15 min]
            sample(7 * day - 6 * 60, sd: 70), sample(7 * day + 4 * 60, sd: 3), // week 2: (−6 h, +4 h] around the same moment
        ]
        let reset = try XCTUnwrap(WeeklyReset.infer(from: series, now: at(8 * day)))
        XCTAssertEqual(reset.resetsAfter, at(14 * day))
        XCTAssertEqual(reset.resetsBy, at(14 * day + 15))
    }

    /// An early drop that does not line up with the latest one is a re-anchoring (a plan
    /// change); it must not narrow the current schedule to nothing.
    func testAnEarlierDropThatDisagreesIsIgnored() throws {
        let series = [
            sample(0, sd: 50), sample(15, sd: 0),                            // Tuesday, say
            sample(3 * day, sd: 40), sample(3 * day + 15, sd: 0),            // plan change: Friday
            sample(10 * day, sd: 60), sample(10 * day + 15, sd: 1),          // Friday again
        ]
        let reset = try XCTUnwrap(WeeklyReset.infer(from: series, now: at(11 * day)))
        XCTAssertEqual(reset.resetsAfter, at(17 * day))
        XCTAssertEqual(reset.resetsBy, at(17 * day + 15))
    }

    func testADropWiderThanAWeekSaysNothingAboutTheSchedule() throws {
        let wide = [sample(0, sd: 90), sample(8 * day, sd: 5)]
        XCTAssertNil(WeeklyReset.infer(from: wide, now: at(9 * day)))
        // …but an earlier tight bracket is still used when the wide one is skipped.
        let series = [sample(0, sd: 80), sample(15, sd: 1), sample(2 * day, sd: 50), sample(10 * day, sd: 5)]
        let reset = try XCTUnwrap(WeeklyReset.infer(from: series, now: at(10 * day)))
        XCTAssertEqual(reset.resetsBy, at(14 * day + 15))
    }

    func testWeekRowEndsOnceAResetHasCertainlyHappenedSinceTheSample() throws {
        let series = [sample(0, sd: 60), sample(15, sd: 2), sample(day, sd: 30)]   // resets at (+0, +15] weekly
        let before = try XCTUnwrap(UsageReading.make(samples: series, now: at(7 * day)))
        XCTAssertEqual(before.rows.last?.value, .percent(30), "inside the bracket the reset may not have happened")
        let after = try XCTUnwrap(UsageReading.make(samples: series, now: at(7 * day + 15)))
        XCTAssertEqual(after.rows.last?.value, .ended)
        XCTAssertEqual(after.weekly?.resetsBy, at(14 * day + 15), "the next one is a week on")
    }

    func testWeekRowTrailingTextShowsTheResetAndTheAge() throws {
        let series = [sample(0, sd: 60), sample(15, sd: 2), sample(day, sd: 30)]
        let reading = try XCTUnwrap(UsageReading.make(samples: series, now: at(day + 45)))
        let week = try XCTUnwrap(reading.rows.last)
        XCTAssertEqual(UsageText.trailing(for: week, in: reading, time: minutes), "resets by +\(7 * 24 * 60 + 15)m (est.) \u{00B7} 45 min ago")
        XCTAssertTrue(UsageText.tooltip(reading, time: minutes).contains("at the same time every week"))
        XCTAssertTrue(UsageText.summary(reading, time: minutes).contains("week resets by +\(7 * 24 * 60 + 15)m (est.)"))
    }

    // MARK: - Reading

    func testSessionIsCurrentBeforeResetsByAndEndedAfterIt() throws {
        let series = [sample(0, fh: 12, sd: 90), sample(15, fh: 22, sd: 92)]
        let before = try XCTUnwrap(UsageReading.make(samples: series, now: at(299)))
        XCTAssertEqual(before.rows.first, .init(key: "fh", label: "5h", value: .percent(22)))
        let after = try XCTUnwrap(UsageReading.make(samples: series, now: at(300)))
        XCTAssertEqual(after.rows.first, .init(key: "fh", label: "5h", value: .ended))
        XCTAssertEqual(after.rows.last, .init(key: "sd", label: "week", value: .percent(92)), "the week is unaffected")
        XCTAssertNotNil(after.session, "the window is still described, for the tooltip")
    }

    func testWeeklyKeysReadAsEndedOnceTheSampleIsSevenDaysOld() throws {
        let series = [sample(0, sd: 40, extra: ["so": 10, "xu": 5])]
        let fresh = try XCTUnwrap(UsageReading.make(samples: series, now: at(6 * 24 * 60)))
        XCTAssertEqual(fresh.rows.map(\.value), [.percent(40), .percent(10), .percent(5)])
        let old = try XCTUnwrap(UsageReading.make(samples: series, now: at(7 * 24 * 60)))
        XCTAssertEqual(old.rows.map(\.value), [.ended, .ended, .percent(5)], "extra usage has no period")
    }

    func testRowsFollowTheTableOrderAndOnlyListPresentKeys() throws {
        let only = try XCTUnwrap(UsageReading.make(samples: [sample(0, extra: ["so": 55])], now: at(1)))
        XCTAssertEqual(only.rows.map(\.label), ["Opus"], "nothing is synthesized as week")
        let many = try XCTUnwrap(UsageReading.make(samples: [sample(0, fh: 1, sd: 2, extra: ["xu": 3, "cw": 4])], now: at(1)))
        XCTAssertEqual(many.rows.map(\.label), ["5h", "week", "Cowork", "extra"])
    }

    func testKeysWithoutARowAreReportedAsUnlisted() throws {
        let reading = try XCTUnwrap(UsageReading.make(samples: [sample(0, fh: 1, extra: ["om": 8, "zz": 9])], now: at(1)))
        XCTAssertEqual(reading.unlisted, ["om": 8, "zz": 9])
        XCTAssertEqual(reading.rows.count, 1)
    }

    func testLevelThresholdsAreEightyAndOneHundred() {
        XCTAssertEqual(UsageLevel.of(0), .normal)
        XCTAssertEqual(UsageLevel.of(79), .normal)
        XCTAssertEqual(UsageLevel.of(80), .warning)
        XCTAssertEqual(UsageLevel.of(99), .warning)
        XCTAssertEqual(UsageLevel.of(100), .limit)
    }

    func testEmptyHistoryGivesNoReading() {
        XCTAssertNil(UsageReading.make(samples: [], now: at(0)))
    }

    func testAgeIsMeasuredFromTheLatestSampleOfTheCurrentOrg() throws {
        let series = [sample(0, fh: 1, org: "org-a"), sample(50, fh: 9, org: "org-b"), sample(10, fh: 3, org: "org-a")]
        let reading = try XCTUnwrap(UsageReading.make(samples: series.sorted { $0.sampledAt < $1.sampledAt }, now: at(60)))
        XCTAssertEqual(reading.age, 10 * 60, "org-b's later sample is the current org")
        XCTAssertEqual(reading.rows.first?.percent, 9)
    }

    // MARK: - Text

    func testAgeIsOmittedUnderThirtyMinutesThenRoundsToMinutesHoursAndDays() {
        XCTAssertNil(UsageText.age(29 * 60))
        XCTAssertEqual(UsageText.age(30 * 60), "30 min ago")
        XCTAssertEqual(UsageText.age(119 * 60), "119 min ago")
        XCTAssertEqual(UsageText.age(120 * 60), "2 h ago")
        XCTAssertEqual(UsageText.age(47 * 3600), "47 h ago")
        XCTAssertEqual(UsageText.age(3 * 86400 + 5), "3 d ago")
    }

    func testResetTextShowsOnlyTheUpperBound() throws {
        let series = [sample(0, fh: 40), sample(15, fh: 2), sample(30, fh: 12)]
        let reading = try XCTUnwrap(UsageReading.make(samples: series, now: at(40)))
        let row = try XCTUnwrap(reading.rows.first)
        XCTAssertEqual(UsageText.trailing(for: row, in: reading, time: minutes), "resets by +315m (est.)")
        XCTAssertEqual(UsageText.row(row), "5h 12%")
    }

    func testTooltipStatesTheIntervalAndTheRecordingCaveat() throws {
        let series = [sample(0, fh: 40), sample(15, fh: 2), sample(30, fh: 12)]
        let tooltip = UsageText.tooltip(try XCTUnwrap(UsageReading.make(samples: series, now: at(40))), time: minutes)
        XCTAssertTrue(tooltip.contains("Estimated: the 5-hour window ends between +300m and +315m"), tooltip)
        XCTAssertTrue(tooltip.contains("records usage only while this profile is open"), tooltip)
    }

    func testEndedRowsRenderAsADashWithNoResetText() throws {
        let reading = try XCTUnwrap(UsageReading.make(samples: [sample(0, fh: 30, sd: 50)], now: at(400)))
        let session = try XCTUnwrap(reading.rows.first)
        XCTAssertEqual(UsageText.row(session), "5h \u{2014}")
        XCTAssertNil(UsageText.trailing(for: session, in: reading, time: minutes))
        XCTAssertTrue(UsageText.tooltip(reading, time: minutes).contains("has ended"))
        let week = try XCTUnwrap(reading.rows.last)
        XCTAssertEqual(UsageText.trailing(for: week, in: reading, time: minutes), "6 h ago")
    }

    func testSummaryLineForAProfileWithAndWithoutHistory() throws {
        XCTAssertEqual(UsageText.summary(nil, time: minutes), "no data yet (recorded once Claude has run on this profile)")
        let reading = try XCTUnwrap(UsageReading.make(samples: [sample(0, fh: 22, sd: 92)], now: at(10)))
        XCTAssertEqual(UsageText.summary(reading, time: minutes), "5h 22% \u{00B7} week 92% \u{00B7} resets by +300m (est.) \u{00B7} recorded +0m")
    }

    func testAccessibilityTextReadsAsOneSentence() throws {
        let reading = try XCTUnwrap(UsageReading.make(samples: [sample(0, fh: 22, sd: 92)], now: at(45)))
        XCTAssertEqual(
            UsageText.accessibilityText(reading, profileLabel: "Christy", time: minutes),
            "Christy usage: 5h 22 percent, week 92 percent, estimated reset by +300m, 45 min ago"
        )
    }
}
