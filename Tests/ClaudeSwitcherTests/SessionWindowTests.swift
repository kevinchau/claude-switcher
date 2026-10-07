import XCTest
@testable import ClaudeSwitcherCore

/// The five-hour window: the ten-minute start (A3), a recorded exact end, and the start this
/// Mac's activity shows when no sample lies inside the window.
final class SessionWindowTests: XCTestCase {

    private typealias F = UsageFixtures
    private func pdt(_ text: String) -> Date { F.pdt(text) }

    private func sample(_ text: String, fh: Int) -> UsageSample {
        UsageSample(sampledAt: pdt(text), org: "org", utilization: ["fh": fh])
    }

    private func fiveHour(_ resetsAt: String, hit: String) -> LimitAnchor {
        LimitAnchor(resetsAt: pdt(resetsAt), kind: .fiveHour, hitAt: pdt(hit))
    }

    /// Christy on 09-16: first message 15:18:31, the window reset at 20:10. A sample at 15:17
    /// reading 2 % bounds the end by 20:10, not 20:17.
    func testResetsByIsFlooredToTenMinutes() throws {
        let window = try XCTUnwrap(SessionWindow.infer(from: [sample("2026-09-16 15:17", fh: 2), sample("2026-09-16 15:32", fh: 6)]))
        XCTAssertEqual(window.resetsBy, pdt("2026-09-16 20:10"))
        XCTAssertEqual(window.resetsAfter, pdt("2026-09-16 15:32"))
        XCTAssertNil(window.exactEnd)
        XCTAssertNil(window.activityStart)
        // On a mark it is the mark itself.
        XCTAssertEqual(SessionWindow.infer(from: [sample("2026-09-16 15:20", fh: 2)])?.resetsBy, pdt("2026-09-16 20:20"))
        // The reading the menu shows uses the same bound.
        let reading = try XCTUnwrap(UsageReading.make(samples: [sample("2026-09-16 15:17", fh: 2)], now: pdt("2026-09-16 20:12")))
        XCTAssertEqual(reading.rows.first?.value, .ended, "20:12 is past 20:10")
    }

    func testExactFiveHourAnchorInFutureReplacesEstimate() throws {
        let samples = [sample("2026-09-24 21:15", fh: 30), sample("2026-09-24 23:50", fh: 100)]
        let anchor = fiveHour("2026-09-25 02:10:00.38", hit: "2026-09-24 23:51")
        let now = pdt("2026-09-25 00:30")
        let window = try XCTUnwrap(SessionWindow.infer(from: samples, anchors: [anchor], activity: nil, now: now))
        XCTAssertEqual(window.exactEnd, pdt("2026-09-25 02:10"), "rounded to the minute")
        XCTAssertEqual(window.resetsBy, pdt("2026-09-25 02:10"), "the estimate, which the exact end happens to match here")
        XCTAssertEqual(window.utilization, 100)

        // With no sample inside the window at all, the recorded end still is the window.
        let alone = try XCTUnwrap(SessionWindow.infer(from: [], anchors: [anchor], activity: nil, now: now))
        XCTAssertEqual(alone.exactEnd, pdt("2026-09-25 02:10"))
        XCTAssertEqual(alone.utilization, 100, "the limit was hit")
        // Other kinds never give a window end.
        let weekly = LimitAnchor(resetsAt: pdt("2026-09-25 02:10"), kind: .sevenDay, hitAt: pdt("2026-09-24 23:51"))
        XCTAssertNil(SessionWindow.infer(from: samples, anchors: [weekly], activity: nil, now: now)?.exactEnd)
    }

    func testExactAnchorInPastIsNotUsed() throws {
        let samples = [sample("2026-09-25 03:00", fh: 4)]
        let passed = fiveHour("2026-09-25 02:10", hit: "2026-09-24 23:51")
        let window = try XCTUnwrap(SessionWindow.infer(from: samples, anchors: [passed], activity: nil, now: pdt("2026-09-25 03:05")))
        XCTAssertNil(window.exactEnd)
        XCTAssertEqual(window.resetsBy, pdt("2026-09-25 08:00"))
        XCTAssertNil(SessionWindow.infer(from: [], anchors: [passed], activity: nil, now: pdt("2026-09-25 03:05")))
    }

    /// A five-hour end more than five hours ahead cannot be this window's: the sampled bound
    /// stays. Four hours ahead it is the exact end.
    func testFiveHourAnchorMoreThanFiveHoursAheadIsNotAnExactEnd() throws {
        let now = pdt("2026-10-05 12:00")
        let samples = [sample("2026-10-05 11:00", fh: 30)]
        let far = LimitAnchor(resetsAt: now.addingTimeInterval(6 * 3600), kind: .fiveHour, hitAt: now.addingTimeInterval(-60))
        let window = try XCTUnwrap(SessionWindow.infer(from: samples, anchors: [far], activity: nil, now: now))
        XCTAssertNil(window.exactEnd)
        XCTAssertEqual(window.resetsBy, pdt("2026-10-05 16:00"), "the sampled bound")
        let near = LimitAnchor(resetsAt: now.addingTimeInterval(4 * 3600), kind: .fiveHour, hitAt: now.addingTimeInterval(-60))
        XCTAssertEqual(SessionWindow.infer(from: samples, anchors: [near], activity: nil, now: now)?.exactEnd, now.addingTimeInterval(4 * 3600))
    }

    /// Personal's last sample is from 09:05; the window it saw ended by 14:00. Calls since then
    /// started a new window at the first one's ten-minute mark.
    func testActivityStartBoundsWindowWhenNoSampleInside() throws {
        let samples = [sample("2026-10-05 09:05", fh: 40)]
        let calls = [(pdt("2026-10-05 08:30"), 3.0), (pdt("2026-10-05 13:55"), 1.0),     // inside the sampled window
                     (pdt("2026-10-05 14:23:10"), 2.0), (pdt("2026-10-05 14:41"), 5.0), (pdt("2026-10-05 15:30"), 4.0)]
        let ledger = F.ledger(calls.map { (at: $0.0, spend: $0.1) })
        let now = pdt("2026-10-05 16:00")
        let window = try XCTUnwrap(SessionWindow.infer(from: samples, anchors: [], activity: ledger, now: now))
        XCTAssertEqual(window.activityStart, pdt("2026-10-05 14:20"))
        XCTAssertEqual(window.resetsBy, pdt("2026-10-05 19:20"))
        XCTAssertEqual(window.resetsAfter, pdt("2026-10-05 15:30"), "still open at its latest call")
        XCTAssertEqual(window.utilization, 0, "nothing recorded in it")

        // Later the next window, walked forward from that one's end.
        let later = F.ledger((calls + [(pdt("2026-10-05 19:45"), 1.0)]).map { (at: $0.0, spend: $0.1) })
        let next = try XCTUnwrap(SessionWindow.infer(from: samples, anchors: [], activity: later, now: pdt("2026-10-05 20:00")))
        XCTAssertEqual(next.activityStart, pdt("2026-10-05 19:40"))
        XCTAssertEqual(next.resetsBy, pdt("2026-10-06 00:40"))

        // Idle since the activity window ended: no window is open; the ended sample window stays.
        let idle = SessionWindow.infer(from: samples, anchors: [], activity: ledger, now: pdt("2026-10-05 19:30"))
        XCTAssertNil(idle?.activityStart)
        XCTAssertEqual(idle?.resetsBy, pdt("2026-10-05 14:00"))

        // While the sample's own window runs, the sample decides.
        let inside = try XCTUnwrap(SessionWindow.infer(from: samples, anchors: [], activity: ledger, now: pdt("2026-10-05 12:00")))
        XCTAssertNil(inside.activityStart)
        XCTAssertEqual(inside.resetsBy, pdt("2026-10-05 14:00"))
    }

    /// Samples at 100 from 19:34 — the window was already full — and Claude Code recorded the
    /// limit hit at 19:40 with the window's end, 21:10. The samples alone bound the end by 00:30
    /// (19:34's ten-minute mark plus five hours). Once 21:10 has passed the window has ended: the
    /// row says "—", the line says nothing of a full window, and a call after it opens a new
    /// window at 21:10's mark — from activity only.
    func testRecordedEndThatHasPassedEndsTheSampledWindow() throws {
        let samples = ["2026-10-05 19:34", "2026-10-05 20:04", "2026-10-05 20:34"].map {
            UsageSample(sampledAt: pdt($0), org: "org", utilization: ["fh": 100, "sd": 40])
        }
        let hit = fiveHour("2026-10-05 21:10", hit: "2026-10-05 19:40")
        func forecast(_ ledger: ActivityLedger, _ now: Date) -> UsageForecast {
            UsageForecast.make(profileID: "personal", samples: samples, activity: ledger, exact: nil, busySessions: [],
                               costs: AdvisorFixtures.a15, now: now)
        }
        // Before it: full until 21:10, exactly.
        let before = pdt("2026-10-05 20:50")
        XCTAssertEqual(SessionWindow.infer(from: samples, anchors: [hit], activity: nil, now: before)?.exactEnd, pdt("2026-10-05 21:10"))
        XCTAssertEqual(ForecastText.line(forecast(F.ledger([], anchors: [hit]), before), indexState: .ready(indexedThrough: before),
                                         clock: AdvisorFixtures.clock(before)), "5h window full \u{2014} clears 9:10 PM")

        for text in ["2026-10-05 21:16", "2026-10-05 23:00", "2026-10-06 00:16"] {
            let now = pdt(text)
            let window = try XCTUnwrap(SessionWindow.infer(from: samples, anchors: [hit], activity: nil, now: now))
            XCTAssertEqual(window.resetsBy, pdt("2026-10-05 21:10"), text)
            XCTAssertNil(window.exactEnd, text)
            let reading = try XCTUnwrap(UsageReading.make(samples: samples, anchors: [hit], now: now))
            XCTAssertEqual(reading.rows.first { $0.key == "fh" }?.value, .ended, text)
            let f = forecast(F.ledger([], anchors: [hit]), now)
            XCTAssertNil(f.windowClearsAt, text)
            XCTAssertEqual(f.windowUsed.value, 0, text)
            let line = ForecastText.line(f, indexState: .ready(indexedThrough: now), clock: AdvisorFixtures.clock(now))
            XCTAssertFalse(line.contains("5h"), "\(text): \(line)")
        }

        // A call at 21:12 opens the next window at 21:10's mark, not at 00:30.
        let now = pdt("2026-10-05 21:30")
        let f = forecast(F.ledger([(pdt("2026-10-05 21:12"), 3.3)], anchors: [hit]), now)
        XCTAssertEqual(f.window?.activityStart, pdt("2026-10-05 21:10"))
        XCTAssertEqual(f.windowClearsAt, pdt("2026-10-06 02:10"))
        XCTAssertEqual(f.windowUsed.value, 1, accuracy: 0.01, "this Mac's activity only")
    }
}
