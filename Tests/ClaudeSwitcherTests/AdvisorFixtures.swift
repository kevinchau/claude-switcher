import Foundation
@testable import ClaudeSwitcherCore

/// Forecasts made from the numbers the Advisor's rules talk about — headroom, waste, reset,
/// window room — so each rule can be tested on its own. "Personal" resets Sat 21:00 PDT,
/// "Christy" Mon 05:00, as on this Mac. Numbers only.
enum AdvisorFixtures {

    static let now = UsageFixtures.pdt("2026-10-05 18:47")
    static let personalReset = UsageFixtures.pdt("2026-10-10 21:00")
    static let christyReset = UsageFixtures.pdt("2026-10-12 05:00")
    static let labels = ["personal": "Personal", "christy": "Christy"]
    static let order = ["personal", "christy"]

    /// The judge's worked figures (A15 as first written), as points of a Max 20x account at the
    /// default calibration, p50 / p75: short 1 / 2 (window 5 / 10), medium 3 / 5 (12 / 20), long
    /// 15 / 30 whole, 7 / 12 in its first three hours, 20 / 35 of a window in its first hour.
    /// The reserve is then 4 points.
    static let a15: SessionCosts = {
        let w = 1 / Calibration.defaultWeekly, f = 1 / Calibration.defaultWindow
        func q(_ p50: Double, _ p75: Double, _ unit: Double) -> SessionCosts.Quantiles { .init(p50: p50 * unit, p75: p75 * unit) }
        return SessionCosts(
            short: .init(whole: q(1, 2, w), fitWeek: q(1, 2, w), fitWindow: q(5, 10, f), episodes: 0),
            medium: .init(whole: q(3, 5, w), fitWeek: q(3, 5, w), fitWindow: q(12, 20, f), episodes: 0),
            long: .init(whole: q(15, 30, w), fitWeek: q(7, 12, w), fitWindow: q(20, 35, f), episodes: 0))
    }()

    /// Personal's real schedule: Sat 21:00, from its recorded weekly limit hits.
    static let saturday = WeeklySchedule.infer(samples: [], anchors: UsageFixtures.personalWeeklyAnchors, now: now)!
    static let monday = WeeklySchedule.infer(samples: [], anchors: UsageFixtures.christyWeeklyAnchors, now: now)!

    /// A forecast whose cautious headroom is `headroom` (`100 − weekUsed.high`) and cautious
    /// window room `room` (`100 − windowUsed.high`); `windowExact`: Claude Code recorded `clearsAt`.
    static func forecast(
        _ id: String, headroom: Double, waste: Int? = nil, end: Date? = nil, room: Double = 100, clearsAt: Date? = nil,
        windowExact: Bool = false,
        committedWeek: Double = 0, committedWindow: Double = 0, blockedUntil: Date? = nil, blockReason: String? = nil,
        basis: Basis = .recordedPlusActivity, stale: Bool = false, pace: Double? = nil, schedule: WeeklySchedule? = nil,
        calibration: Calibration = .defaults, plan: PlanLabel = .max20x, at moment: Date = now
    ) -> UsageForecast {
        let high = 100 - headroom
        let value = max(0, high - 6)
        let used = Estimate(value: value, low: max(0, value - 10), high: high, basis: basis)
        let reset = end ?? (id == "christy" ? christyReset : personalReset)
        let hasSchedule = basis != .recordedNoSchedule && basis != .defaults
        return UsageForecast(
            profileID: id, reading: nil, schedule: schedule ?? (hasSchedule ? (id == "christy" ? monday : saturday) : nil),
            weekUsed: used, headroom: Estimate(value: 100 - value, low: headroom, high: 100 - used.low, basis: basis),
            paceWeek: pace, paceRecent: nil, pace: pace, projectedAtReset: nil, runOutAt: nil, waste: hasSchedule ? waste : nil,
            weekStart: hasSchedule ? reset.addingTimeInterval(-WeeklySchedule.period) : nil, weekEnd: hasSchedule ? reset : nil,
            window: nil, windowUsed: Estimate(value: 100 - room, low: 0, high: 100 - room, basis: .recorded),
            windowClearsAt: clearsAt, windowExact: windowExact, committedWeek: committedWeek, committedWindow: committedWindow,
            commitments: [], blockedUntil: blockedUntil, blockReason: blockReason,
            timeline: UsageTimeline(windows: [], segments: [], cycles: [], limitHit: 0, limitHitOf: 0),
            calibration: calibration, plan: plan, stale: stale, activityKnown: true, latestWeekly: nil, anchors: [])
    }

    static func advise(_ size: SessionSize, _ forecasts: [UsageForecast], costs: SessionCosts = a15, previous: Advice? = nil,
                       running: Set<String> = [], at moment: Date = now) -> Advice {
        UsageAdvisor.advise(size: size, forecasts: Dictionary(uniqueKeysWithValues: forecasts.map { ($0.profileID, $0) }), costs: costs,
                            order: order, previous: previous, running: running, now: moment)
    }

    /// A snapshot around forecasts made by hand (for the text).
    static func snapshot(_ forecasts: [UsageForecast], costs: SessionCosts = a15, advice: [SessionSize: Advice] = [:],
                         indexState: ActivityIndexState = .ready(indexedThrough: now)) -> UsageSnapshot {
        UsageSnapshot(forecasts: Dictionary(uniqueKeysWithValues: forecasts.map { ($0.profileID, $0) }), costs: costs, advice: advice,
                      indexState: indexState, order: order.filter { id in forecasts.contains { $0.profileID == id } })
    }

    /// English, Pacific time: the words every text test checks.
    static func clock(_ moment: Date = now) -> UsageClock {
        UsageClock(now: moment, timeZone: TimeZone(identifier: "America/Los_Angeles")!, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The profile chosen, if any.
    static func chosen(_ advice: Advice) -> String? { advice.profileID }

    static func reason(_ advice: Advice) -> Advice.Reason? {
        if case .start(_, let reason, _, _) = advice.outcome { return reason }
        return nil
    }
}
