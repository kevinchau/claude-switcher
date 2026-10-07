import Foundation

// MARK: - Estimates

/// What an estimate stands on, from the most to the least certain. The menu says which.
public enum Basis: Equatable, Sendable {
    /// A sample recorded this week, nothing spent since.
    case recorded
    /// The sample recorded this week plus this Mac's activity since it.
    case recordedPlusActivity
    /// A sample from the last seven days, but no weekly reset seen yet: the sample is a floor
    /// (a reset in between could only have lowered true use), the reset time is unknown.
    case recordedNoSchedule
    /// No sample since the reset: this Mac's activity since it.
    case activityOnly
    /// No history and no records at all: stated defaults.
    case defaults
    /// Not enough to say anything; the reason is shown.
    case insufficient(String)
}

/// A value with the bounds it certainly (under the stated assumptions) lies in.
public struct Estimate<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let low: Value
    public let high: Value
    public let basis: Basis

    public init(value: Value, low: Value, high: Value, basis: Basis) {
        self.value = value
        self.low = low
        self.high = high
        self.basis = basis
    }
}

/// The account's plan as `~/.claude.json` names it, for labelling defaults (A5).
public enum PlanLabel: Equatable, Sendable {
    /// Max 20x — the plan the defaults were measured on.
    case max20x
    /// Nothing recorded for this account (the terminal CLI is signed in to another one).
    case unknown
    case named(String)

    public init(rateLimitTier: String?) {
        guard let tier = rateLimitTier?.lowercased(), !tier.isEmpty else { self = .unknown; return }
        self = tier.contains("max_20x") ? .max20x : .named(rateLimitTier!)
    }
}

/// A Code session the registry reports mid-turn, attributed to an account (A12).
public struct BusySession: Equatable, Sendable {
    /// The transcript it writes (`cliSessionId`), lowercased.
    public let cliSessionId: String

    public init(cliSessionId: String) {
        self.cliSessionId = cliSessionId.lowercased()
    }

    /// The busy sessions of each profile: by the records' claims, else by the ledger that
    /// holds the transcript's spend. Two profiles on one account both get it.
    public static func attribute(running: RunningSessions, attribution: ActivityAttribution,
                                 ledgers: [String: ActivityLedger]) -> [String: [BusySession]] {
        var result: [String: [BusySession]] = [:]
        for id in running.busyCliSessionIds.map({ $0.lowercased() }).sorted() {
            let profiles: [String]
            if let account = attribution.claims[id] {
                profiles = attribution.accounts.filter { $0.value == account }.map(\.key)
            } else {
                profiles = ledgers.filter { $0.value.sessions[id] != nil }.map(\.key)
            }
            for profile in profiles { result[profile, default: []].append(BusySession(cliSessionId: id)) }
        }
        return result
    }
}

// MARK: - Calibration

/// How many points of the weekly and five-hour limits one unit of weighted spend is worth,
/// for one account, from its own history.
///
/// **Weekly (`k_w`).** The history is cut into segments at every reset — scheduled or one-off,
/// the launch grants included — so no segment straddles one (a regression across a reset is
/// meaningless). In each, the rise of `sd` since the segment's first sample is regressed through
/// the origin on the spend since it; samples at 100 are left out (the true value is censored).
/// A segment counts when it has at least 10 samples, rises 20 points and fits with R² ≥ 0.9;
/// `k_w` is the median over the counting segments of the last 45 days, once there are two.
/// Until then, the default measured on this Mac's two Max 20x accounts (A5).
///
/// **The scale gate.** On every sample inside a segment the rise the calibration predicts since
/// the previous one is compared with the recorded rise: once the prediction is at least 10
/// points and the recorded rise is under half or over twice it, the calibration is for another
/// plan. Everything before is dropped — the window weight with the weekly one — the segment
/// restarts at that sample, and the defaults return, flagged, until two new segments count. A
/// confirmed re-anchor of the weekly schedule, or a new plan tier `~/.claude.json` names for the
/// account, drops it the same way.
///
/// **Five-hour (`k_f`).** Per window, the same regression over samples no more than an hour
/// apart, rising at least 5 points with r ≥ 0.9; the median once eight windows count.
public struct Calibration: Equatable, Sendable {

    public static let defaultWeekly = 1 / 13.5
    public static let defaultWindow = 1 / 3.3
    public static let defaultRMSE = 3.0
    /// The five-hour fit's typical error before eight windows count, in points.
    public static let defaultWindowRMSE = 5.0
    /// A re-anchor, a new plan tier, or a trip at 3× / ⅓× or more: the plan may really have changed.
    public static let planChangedFlag = "plan may have changed \u{2014} recalibrating"
    /// A trip nearer 1× than that: one sample off the line (unseen use, a grant), more likely
    /// than a change of plan (``UsageAdvisor/recalibratingRatio``).
    public static let unusualSampleFlag = "recalibrating after an unusual sample"

    static let minimumSamples = 10
    static let minimumRise = 20
    static let minimumR2 = 0.9
    static let minimumSegments = 2
    static let lookback: TimeInterval = 45 * 86400
    static let gateMinimumEstimate = 10.0
    static let gateRange = 0.5...2.0
    static let windowMinimumRise = 5
    static let windowMaximumGap: TimeInterval = 3600
    static let windowMinimumR = 0.9
    static let minimumWindows = 8

    /// One segment's fit.
    public struct Fit: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let samples: Int
        public let rise: Int
        public let k: Double
        public let r2: Double
        public let rmse: Double

        public var qualifies: Bool {
            samples >= Calibration.minimumSamples && rise >= Calibration.minimumRise && r2 >= Calibration.minimumR2 && k > 0
        }
    }

    /// Points of the week per spend unit.
    public let weekly: Double
    /// Points of the five-hour window per spend unit.
    public let window: Double
    /// The typical error of the weekly fit, in points (median per-segment rmse).
    public let rmse: Double
    /// The typical error of the five-hour fit, in points (median per-window rmse); the default
    /// until ``window`` is calibrated.
    public let windowRMSE: Double
    /// Segments behind ``weekly``; 0 when it is the default.
    public let segments: Int
    public let medianR2: Double?
    /// Windows behind ``window``; 0 when it is the default.
    public let windows: Int
    /// Set when a recorded sample contradicted the calibration (or the schedule moved, or the
    /// plan tier changed).
    public let flag: String?
    /// With ``flag`` from the scale gate: the recorded rise over the predicted one at the trip.
    /// Above 1 the account spends more of its limit per unit than it was calibrated to (a
    /// smaller plan); below 1 less. `nil` when the flag came from a re-anchor or a tier change.
    public let tripRatio: Double?

    public init(weekly: Double, window: Double, rmse: Double, segments: Int, medianR2: Double?, windows: Int, flag: String? = nil,
                tripRatio: Double? = nil, windowRMSE: Double = Calibration.defaultWindowRMSE) {
        self.weekly = weekly
        self.window = window
        self.rmse = rmse
        self.windowRMSE = windowRMSE
        self.segments = segments
        self.medianR2 = medianR2
        self.windows = windows
        self.flag = flag
        self.tripRatio = flag == nil ? nil : tripRatio
    }

    public static let defaults = Calibration(weekly: defaultWeekly, window: defaultWindow, rmse: defaultRMSE,
                                             segments: 0, medianR2: nil, windows: 0)

    public var weeklyIsDefault: Bool { segments == 0 }
    public var windowIsDefault: Bool { windows == 0 }

    // MARK: Fitting

    public static func fit(timeline: UsageTimeline, activity: ActivityLedger?, schedule: WeeklySchedule?, now: Date) -> Calibration {
        guard let activity else { return .defaults }
        var restart = activity.coveredSince ?? .distantPast
        var flagged = false
        // A plan change the schedule or `~/.claude.json` shows: what came before no longer applies.
        for moved in [schedule?.reanchoredAt, activity.tierChangedAt].compactMap({ $0 }) where moved > restart {
            restart = moved
            flagged = true
        }

        let walk = walk(timeline, activity: activity, since: restart, flagged: flagged, now: now)
        let recent = walk.fits.filter { now.timeIntervalSince($0.end) <= lookback }
        // The window weight restarts with the weekly one: windows before a trip were on the old plan.
        let windowFits = windowSlopes(timeline: timeline, activity: activity, since: max(restart, walk.tripAt ?? .distantPast), now: now)
        let windowCalibrated = windowFits.count >= minimumWindows
        let window = windowCalibrated ? median(windowFits.map(\.k)) : defaultWindow
        let windowRMSE = windowCalibrated ? median(windowFits.map(\.rmse)) : defaultWindowRMSE
        let windowCount = windowCalibrated ? windowFits.count : 0
        guard recent.count >= minimumSegments else {
            return Calibration(weekly: defaultWeekly, window: window, rmse: defaultRMSE, segments: 0, medianR2: nil,
                               windows: windowCount, flag: walk.flagged ? flag(for: walk) : nil, tripRatio: walk.tripRatio,
                               windowRMSE: windowRMSE)
        }
        return Calibration(weekly: median(recent.map(\.k)), window: window, rmse: median(recent.map(\.rmse)),
                           segments: recent.count, medianR2: median(recent.map(\.r2)), windows: windowCount, flag: nil,
                           windowRMSE: windowRMSE)
    }

    /// What a standing flag is called: a plan change for a re-anchor, a new tier, or a trip of
    /// 3× / ⅓× or more; an unusual sample for a smaller trip — the gate's range is narrow enough
    /// for use this Mac cannot see to trip it (about 2.4× on Sep 21, 0.47× on Sep 22).
    static func flag(for walk: Walk) -> String {
        guard !walk.moved, let ratio = walk.tripRatio,
              ratio > 1 / UsageAdvisor.recalibratingRatio, ratio < UsageAdvisor.recalibratingRatio
        else { return planChangedFlag }
        return unusualSampleFlag
    }

    /// The weekly segments walked once, through the scale gate.
    struct Walk {
        /// The qualifying fits since the last restart.
        var fits: [Fit] = []
        /// A plan change (a trip, a re-anchor, a tier change) that two new fits have not yet answered.
        var flagged: Bool
        /// The flag stands for a re-anchor or a tier change, not only a trip.
        var moved: Bool
        /// The sample the gate last tripped at, and the recorded / predicted rise there.
        var tripAt: Date?
        var tripRatio: Double?
    }

    /// Fits every segment from `restart`, the scale gate checking each sample against the
    /// calibration so far. A trip drops every fit before it and starts the segment again at the
    /// tripping sample.
    static func walk(_ timeline: UsageTimeline, activity: ActivityLedger, since restart: Date, flagged: Bool, now: Date) -> Walk {
        var walk = Walk(flagged: flagged, moved: flagged)
        func current() -> Double { walk.fits.count >= minimumSegments ? median(walk.fits.map(\.k)) : defaultWeekly }

        for segment in timeline.segments {
            var run: [UsageTimeline.Point] = []
            func close() {
                if let fit = fitSegment(run, activity: activity), fit.qualifies {
                    walk.fits.append(fit)
                    if walk.fits.count >= minimumSegments {
                        walk.flagged = false
                        walk.moved = false
                    }
                }
                run = []
            }
            for point in segment.points where point.value < 100 && point.at >= restart && point.at <= now {
                if let previous = run.last {
                    let estimated = current() * activity.spend(from: previous.at, to: point.at)
                    let recorded = Double(point.value - previous.value)
                    if estimated >= gateMinimumEstimate, !gateRange.contains(recorded / estimated) {
                        // Another plan: what was learnt no longer applies.
                        walk.fits = []
                        walk.flagged = true
                        walk.tripAt = point.at
                        walk.tripRatio = recorded / estimated
                        run = []
                    }
                }
                run.append(point)
            }
            close()
        }
        return walk
    }

    /// Least squares through the origin of `sd(t) − sd(t0)` on the spend since `t0`.
    static func fitSegment(_ points: [UsageTimeline.Point], activity: ActivityLedger) -> Fit? {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return nil }
        let xs = points.dropFirst().map { activity.spend(from: first.at, to: $0.at) }
        let ys = points.dropFirst().map { Double($0.value - first.value) }
        guard let line = regress(xs, ys) else { return nil }
        let rise = Int(ys.max() ?? 0)
        return Fit(start: first.at, end: last.at, samples: points.count, rise: rise, k: line.k, r2: line.r2, rmse: line.rmse)
    }

    /// Slope through the origin, R² against the mean, and rmse; `nil` when there is nothing to fit.
    static func regress(_ xs: [Double], _ ys: [Double]) -> (k: Double, r2: Double, rmse: Double)? {
        let sxx = zip(xs, xs).reduce(0) { $0 + $1.0 * $1.1 }
        let sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        guard sxx > 0, !ys.isEmpty else { return nil }
        let k = sxy / sxx
        let residual = zip(xs, ys).reduce(0) { $0 + pow($1.1 - k * $1.0, 2) }
        let mean = ys.reduce(0, +) / Double(ys.count)
        let total = ys.reduce(0) { $0 + pow($1 - mean, 2) }
        guard total > 0 else { return nil }
        return (k, 1 - residual / total, (residual / Double(ys.count)).squareRoot())
    }

    /// Per five-hour window: the slope of its longest run of samples no more than an hour apart,
    /// and how far the samples fall from it (rmse, points).
    static func windowSlopes(timeline: UsageTimeline, activity: ActivityLedger, since: Date, now: Date) -> [(k: Double, rmse: Double)] {
        var slopes: [(k: Double, rmse: Double)] = []
        for window in timeline.windows where window.start >= since && now.timeIntervalSince(window.endBy) <= lookback {
            var runs: [[UsageTimeline.Point]] = [[]]
            for point in window.points where point.value < 100 {
                if let last = runs[runs.count - 1].last, point.at.timeIntervalSince(last.at) > windowMaximumGap { runs.append([]) }
                runs[runs.count - 1].append(point)
            }
            guard let run = runs.max(by: { $0.count < $1.count }), let first = run.first, run.count >= 3,
                  let last = run.last, last.value - first.value >= windowMinimumRise
            else { continue }
            let xs = run.map { activity.spend(from: first.at, to: $0.at) }
            let ys = run.map { Double($0.value - first.value) }
            guard let line = regress(xs, ys), line.k > 0, correlation(xs, ys) >= windowMinimumR else { continue }
            slopes.append((line.k, line.rmse))
        }
        return slopes
    }

    static func correlation(_ xs: [Double], _ ys: [Double]) -> Double {
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let cov = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let vx = xs.reduce(0) { $0 + pow($1 - mx, 2) }, vy = ys.reduce(0) { $0 + pow($1 - my, 2) }
        guard vx > 0, vy > 0 else { return 0 }
        return cov / (vx * vy).squareRoot()
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

// MARK: - The forecast

/// One account's usage now and to the end of its week: recorded values, what this Mac's
/// activity adds to them, the pace, the five-hour window, and what running sessions will still
/// cost. Every number is an estimate with its basis; nothing is presented as recorded that is
/// not.
public struct UsageForecast: Equatable, Sendable {

    /// Use the transcripts cannot see — claude.ai, the phone, other Macs — allowed for in the
    /// upper bound per day since the last sample (A9). Measured: Personal about 1.5, Christy 0.
    public static let unseenPointsPerDay = 2.0
    /// The upper bound's floor above the central estimate, in points.
    public static let minimumMargin = 6.0
    /// The five-hour window's: its floor above the estimate, and the use this Mac cannot see
    /// allowed for per hour since the window's last recording, up to a cap (points).
    public static let windowMinimumMargin = 4.0
    public static let unseenWindowPointsPerHour = 2.0
    public static let unseenWindowCap = 10.0
    /// Claude's own gates before it extrapolates the week: 12 hours in and 10 % used.
    static let paceMinimumElapsed: TimeInterval = 12 * 3600
    static let paceMinimumUsed = 10.0
    static let recentPaceSpan: TimeInterval = 6 * 3600
    /// A sample younger than this with nothing spent since is the value itself.
    static let recordedFreshness: TimeInterval = 30 * 60
    static let staleAge: TimeInterval = 7 * 86400

    /// A busy session's remaining cost.
    public struct Commitment: Equatable, Sendable {
        public let cliSessionId: String
        public let size: SessionSize
        public let week: Double
        public let window: Double
    }

    public let profileID: String
    public let reading: UsageReading?
    public let schedule: WeeklySchedule?
    /// Points of the week used now.
    public let weekUsed: Estimate<Double>
    /// `100 − weekUsed`: `low` is what the Advisor may spend.
    public let headroom: Estimate<Double>
    /// Points per hour since the week began (nil before 12 h or 10 points), over the last six
    /// hours of activity, and the faster of the two.
    public let paceWeek: Double?
    public let paceRecent: Double?
    public let pace: Double?
    /// Where the week ends at that pace; `nil` without a pace or a schedule.
    public let projectedAtReset: Estimate<Double>?
    /// When the week runs out at that pace, if before the reset.
    public let runOutAt: Date?
    /// Points that would go unused at the reset (negative: it runs out first).
    public let waste: Int?
    /// The week's current cycle: its start and the latest the next reset can be.
    public let weekStart: Date?
    public let weekEnd: Date?
    public let window: SessionWindow?
    public let windowUsed: Estimate<Double>
    /// When the open five-hour window clears; `nil` when none is open.
    public let windowClearsAt: Date?
    public let windowExact: Bool
    public let committedWeek: Double
    public let committedWindow: Double
    public let commitments: [Commitment]
    /// A per-model or Fable weekly limit was hit and resets then.
    public let blockedUntil: Date?
    public let blockReason: String?
    public let timeline: UsageTimeline
    public let calibration: Calibration
    public let plan: PlanLabel
    /// Neither a sample nor any activity in the last seven days.
    public let stale: Bool
    /// Activity was available (the index was ready).
    public let activityKnown: Bool
    /// The latest sample with a weekly value, as recorded.
    public let latestWeekly: UsageTimeline.Point?
    /// Every limit hit the account's transcripts recorded.
    public let anchors: [LimitAnchor]

    /// The five-hour room left: `100 − windowUsed`, central. The Advisor fits sessions against
    /// the cautious room, `100 − windowUsed.high`.
    public var windowRoom: Double { 100 - windowUsed.value }

    /// The estimate to draw as the lighter part of a bar, when above the recorded value.
    public func estimatedPercent(for key: String) -> Int? {
        guard activityKnown, let reading else { return nil }
        let recorded = reading.rows.first { $0.key == key }?.percent
        let estimate: Double
        switch key {
        case SessionWindow.key: estimate = windowUsed.value
        case WeeklyReset.key: estimate = weekUsed.value
        default: return nil
        }
        let rounded = Int(estimate.rounded())
        guard rounded > (recorded ?? 0) else { return nil }
        return min(100, rounded)
    }

    // MARK: Making one

    public static func make(profileID: String, samples all: [UsageSample], activity: ActivityLedger?, exact: ExactUsage?,
                            busySessions: [BusySession], costs: SessionCosts, now: Date) -> UsageForecast {
        var samples = UsageHistory.currentOrgSamples(all).filter { $0.sampledAt <= now }
        if let fresh = exact?.sample(org: samples.last?.org), fresh.sampledAt <= now, fresh.sampledAt > (samples.last?.sampledAt ?? .distantPast) {
            samples.append(fresh)
        }
        // Limit hits are what Claude Code recorded refusing a request; a fresh cached body's reset
        // times are exact too, but no hit — they time the schedule and the window, nothing more.
        let hits = (activity?.anchors ?? []).filter { $0.hitAt <= now }
        let anchors = LimitAnchor.merged(hits + (exact?.anchors ?? []).filter { $0.hitAt <= now })
        let reading = UsageReading.make(samples: samples, anchors: anchors, now: now)
        let schedule = WeeklySchedule.infer(samples: samples, anchors: anchors, now: now)
        let timeline = UsageTimeline.build(samples: samples, activity: activity, schedule: schedule, now: now)
        let calibration = Calibration.fit(timeline: timeline, activity: activity, schedule: schedule, now: now)
        let k = calibration.weekly
        func spend(_ from: Date, _ to: Date) -> Double { activity?.spend(from: from, to: to) ?? 0 }
        func clamp(_ x: Double) -> Double { min(100, max(0, x)) }
        func days(_ interval: TimeInterval) -> Double { max(0, interval) / 86400 }
        let margin = max(minimumMargin, 2 * calibration.rmse)

        let weeklyPoints = samples.compactMap { sample in
            sample.utilization[WeeklyReset.key].map { UsageTimeline.Point(at: sample.sampledAt, value: $0) }
        }
        let latest = weeklyPoints.last
        let lastActivity = activity?.lastActivity
        let hasHistory = !samples.isEmpty || lastActivity != nil || !anchors.isEmpty
        let stale = hasHistory
            && (latest.map { now.timeIntervalSince($0.at) > staleAge } ?? true)
            && (lastActivity.map { now.timeIntervalSince($0) > staleAge } ?? true)

        /// The sample is a floor; what this Mac spent since is added to it.
        func fromSample(_ sample: UsageTimeline.Point, plus spent: Double, now: Date, basis: Basis?) -> Estimate<Double> {
            let value = clamp(Double(sample.value) + k * spent)
            let age = now.timeIntervalSince(sample.at)
            let high = min(100, value + margin + unseenPointsPerDay * days(age))
            let chosen = basis ?? ((spent == 0 && age < recordedFreshness) || activity == nil ? .recorded : .recordedPlusActivity)
            return Estimate(value: value, low: Double(sample.value), high: high, basis: chosen)
        }

        // The week: a floor from the sample, plus what this Mac has spent since.
        var weekStart: Date?
        var weekEnd: Date?
        /// The latest moment this week's reset can have happened.
        var resetBy: Date?
        var used: Estimate<Double>
        if let schedule {
            let next = schedule.next(after: now)
            weekEnd = next.by
            let start = next.after.addingTimeInterval(-WeeklySchedule.period)
            let lastBy = next.by.addingTimeInterval(-WeeklySchedule.period)
            weekStart = start
            resetBy = lastBy
            // The sample is this week's when taken at or after the cycle's start — the middle of
            // the reset's interval, the reset itself when exact (the design's rule) — except that
            // one inside the interval that did not drop (above 5, not below the one before) was
            // taken before the reset: the week has reset since, whichever side of the middle.
            let cycleStart = start.addingTimeInterval(lastBy.timeIntervalSince(start) / 2)
            func isThisWeeks(_ sample: UsageTimeline.Point) -> Bool {
                if sample.at > start, sample.at <= lastBy {
                    let before = weeklyPoints.dropLast().last?.value
                    let dropped = sample.value <= WeeklySchedule.resetLandsAtOrBelow || before.map { sample.value < $0 } ?? false
                    if !dropped { return false }
                }
                return sample.at >= cycleStart
            }
            if let latest, isThisWeeks(latest) {
                used = fromSample(latest, plus: spend(latest.at, now), now: now, basis: nil)
            } else {
                let value = clamp(k * spend(start, now))
                used = Estimate(value: value, low: 0, high: min(100, value + margin + unseenPointsPerDay * days(now.timeIntervalSince(start))),
                                basis: .activityOnly)
            }
        } else if let latest, now.timeIntervalSince(latest.at) <= staleAge {
            used = fromSample(latest, plus: spend(latest.at, now), now: now, basis: .recordedNoSchedule)
        } else if hasHistory {
            // Some reset fell in the last seven days, so nothing older than that counts.
            let value = clamp(k * spend(now.addingTimeInterval(-staleAge), now))
            used = Estimate(value: value, low: 0, high: min(100, value + margin + unseenPointsPerDay * 7),
                            basis: .insufficient("no reset observed yet"))
        } else {
            used = Estimate(value: 0, low: 0, high: 100, basis: .defaults)
        }

        // A weekly limit hit Claude Code recorded after the latest sample: the week is full.
        if let hit = hits.filter({ $0.kind == .sevenDay && $0.resetsAt > now }).max(by: { $0.hitAt < $1.hitAt }),
           hit.hitAt >= (latest?.at ?? .distantPast) {
            used = Estimate(value: 100, low: 100, high: 100, basis: .recorded)
        }
        let headroom = Estimate(value: 100 - used.value, low: 100 - used.high, high: 100 - used.low, basis: used.basis)

        // Pace: the faster of the week so far and the last six hours (a bursty week is caught
        // by the second, a steady one by the first). Nothing is extrapolated without activity:
        // the samples alone are a floor, not a measure of the week (§2.4, index building).
        // After a one-off reset inside the week — a grant — the count started again there: the
        // week's pace runs from the start of the segment the latest sample is in, when the
        // reading before that segment was already past this week's reset.
        var paceWeek: Double?
        if activity != nil, let weekStart {
            var countFrom = weekStart
            if let latest, let resetBy, let index = timeline.segments.lastIndex(where: { $0.start <= latest.at }), index > 0 {
                let segment = timeline.segments[index]
                if segment.start > weekStart, let before = timeline.segments[index - 1].points.last, before.at >= resetBy {
                    countFrom = segment.start
                }
            }
            let elapsed = now.timeIntervalSince(countFrom)
            if elapsed >= paceMinimumElapsed, used.value >= paceMinimumUsed { paceWeek = used.value / (elapsed / 3600) }
        }
        let paceRecent: Double? = activity.map { _ in k * spend(now.addingTimeInterval(-recentPaceSpan), now) / (recentPaceSpan / 3600) }
        let fastest = max(paceWeek ?? 0, paceRecent ?? 0)
        let pace: Double? = fastest > 0 ? fastest : nil

        var projected: Estimate<Double>?
        var runOutAt: Date?
        var waste: Int?
        if let pace, let weekEnd, used.low < 100 {
            let remaining = max(0, weekEnd.timeIntervalSince(now)) / 3600
            let value = used.value + pace * remaining
            projected = Estimate(value: value, low: used.low, high: used.high + pace * remaining, basis: used.basis)
            waste = Int((100 - value).rounded())
            if value >= 100 { runOutAt = now.addingTimeInterval(max(0, 100 - used.value) / pace * 3600) }
        }

        // The five-hour window.
        let window = SessionWindow.infer(from: samples, anchors: anchors, activity: activity, now: now)
        let fhSample = samples.last { $0.utilization[SessionWindow.key] != nil }
        var fhNow = 0.0, fhLow = 0.0
        var open = false
        var windowStart: Date?
        if let window {
            if let start = window.activityStart, now < window.resetsBy {
                fhNow = calibration.window * spend(start, now)
                open = true
                windowStart = start
            } else if now < window.resetsBy, let fhSample {
                fhNow = Double(window.utilization) + calibration.window * spend(fhSample.sampledAt, now)
                fhLow = Double(window.utilization)
                open = true
                windowStart = window.resetsBy.addingTimeInterval(-SessionWindow.length)
            }
            if let end = window.exactEnd, end > now {
                open = true
                windowStart = windowStart ?? end.addingTimeInterval(-SessionWindow.length)
            }
        }
        // A five-hour limit hit recorded after the latest sample: full until its recorded end (the
        // reading's 5h row says 100 % from the same rule).
        if SessionWindow.recordedHit(hits, after: fhSample?.sampledAt, now: now) != nil {
            fhNow = 100
            fhLow = 100
            open = true
        }
        let windowValue = min(100, fhNow)
        // A cautious bound, as the week has: the five-hour fit's typical error, and use this Mac
        // cannot see since the later of the window's last recording and its start — 2 points an
        // hour, at most 10. The Advisor fits sessions against it.
        let unseenSince = [fhSample?.sampledAt, windowStart].compactMap { $0 }.max()
        let unseen = unseenSince.map { min(unseenWindowCap, unseenWindowPointsPerHour * max(0, now.timeIntervalSince($0)) / 3600) }
            ?? unseenWindowCap
        let windowHigh = min(100, windowValue + max(windowMinimumMargin, 2 * calibration.windowRMSE) + unseen)
        let windowUsed = Estimate(value: windowValue, low: min(windowValue, fhLow), high: windowHigh,
                                  basis: activity == nil || fhNow == fhLow ? .recorded : .recordedPlusActivity)
        let windowClearsAt = open ? (window?.exactEnd ?? window?.resetsBy) : nil
        let windowExact = open && window?.exactEnd != nil

        // What busy sessions will still cost (A12).
        var commitments: [Commitment] = []
        if !busySessions.isEmpty {
            let points = costs.points(for: calibration)
            let episodes = activity?.episodes() ?? []
            for busy in busySessions {
                let episode = episodes.last { $0.sessionId == busy.cliSessionId && now.timeIntervalSince($0.end) <= ActivityLedger.idleSplit }
                let elapsed = episode.map { now.timeIntervalSince($0.start) } ?? 0
                let size = SessionSize.of(duration: elapsed, subagentShare: episode?.subagentShare ?? 0)
                let spent = episode?.spend ?? 0
                let inWindow = episode.map { spend(max($0.start, windowStart ?? $0.start), now) } ?? 0
                let week = max(0, points[size].whole.p75 - k * spent)
                let windowCost = max(0, points[size].fitWindow.p75 - calibration.window * min(spent, inWindow))
                commitments.append(Commitment(cliSessionId: busy.cliSessionId, size: size, week: week, window: windowCost))
            }
        }

        // A Fable or per-model weekly limit reached: medium and long sessions are off there.
        let block = hits.filter { anchor in
            switch anchor.kind {
            case .fable, .model: return anchor.resetsAt > now
            default: return false
            }
        }.max { $0.resetsAt < $1.resetsAt }

        return UsageForecast(
            profileID: profileID, reading: reading, schedule: schedule, weekUsed: used, headroom: headroom,
            paceWeek: paceWeek, paceRecent: paceRecent, pace: pace, projectedAtReset: projected, runOutAt: runOutAt, waste: waste,
            weekStart: weekStart, weekEnd: weekEnd, window: window, windowUsed: windowUsed, windowClearsAt: windowClearsAt,
            windowExact: windowExact, committedWeek: commitments.reduce(0) { $0 + $1.week },
            committedWindow: commitments.reduce(0) { $0 + $1.window }, commitments: commitments,
            blockedUntil: block?.resetsAt, blockReason: block?.kind.label, timeline: timeline, calibration: calibration,
            // The tier the CLI names now, else the one the index remembers for this account.
            plan: PlanLabel(rateLimitTier: exact?.rateLimitTier ?? activity?.tier), stale: stale, activityKnown: activity != nil,
            latestWeekly: latest, anchors: LimitAnchor.merged(hits))
    }

    // MARK: Activity not read yet

    /// The forecast with its upper bounds widened for activity the index has not read yet:
    /// `unread` seconds at the account's fastest hour of the six before the index's last read
    /// (`activity.indexedThrough`). Spend after that counts as zero in the estimate, so the
    /// cautious headroom must allow for it.
    public func widened(unread: TimeInterval, activity: ActivityLedger) -> UsageForecast {
        guard unread > 0 else { return self }
        let through = activity.indexedThrough
        // Spelled out hour by hour: a closure over this arithmetic took the type checker past
        // its limit on a slower machine (GitHub's runner), which fails the build outright.
        let hourCount = Int(Self.recentPaceSpan / 3600)
        var fastest: Double = 0
        for hour in 0..<hourCount {
            let end: Date = through.addingTimeInterval(-3600 * Double(hour))
            let start: Date = end.addingTimeInterval(-3600)
            fastest = max(fastest, activity.spend(from: start, to: end))
        }
        guard fastest > 0 else { return self }
        let hours: Double = unread / 3600
        let extraWeek: Double = calibration.weekly * fastest * hours
        let extraWindow: Double = calibration.window * fastest * hours
        let week = Estimate(value: weekUsed.value, low: weekUsed.low, high: min(100, weekUsed.high + extraWeek),
                            basis: weekUsed.basis)
        let fiveHour = Estimate(value: windowUsed.value, low: windowUsed.low,
                                high: min(100, windowUsed.high + extraWindow), basis: windowUsed.basis)
        return UsageForecast(
            profileID: profileID, reading: reading, schedule: schedule, weekUsed: week,
            headroom: Estimate(value: headroom.value, low: 100 - week.high, high: headroom.high, basis: headroom.basis),
            paceWeek: paceWeek, paceRecent: paceRecent, pace: pace, projectedAtReset: projectedAtReset, runOutAt: runOutAt, waste: waste,
            weekStart: weekStart, weekEnd: weekEnd, window: window, windowUsed: fiveHour, windowClearsAt: windowClearsAt,
            windowExact: windowExact, committedWeek: committedWeek, committedWindow: committedWindow, commitments: commitments,
            blockedUntil: blockedUntil, blockReason: blockReason, timeline: timeline, calibration: calibration, plan: plan, stale: stale,
            activityKnown: activityKnown, latestWeekly: latestWeekly, anchors: anchors)
    }
}

extension ActivityLedger {
    /// A gap longer than this between one call or prompt and the next ends an episode.
    public static let idleSplit: TimeInterval = 1800
}

extension ExactUsage {
    /// The fresh cached figures as one more sample, recorded at the fetch.
    func sample(org: String?) -> UsageSample? {
        guard let fetchedAt else { return nil }
        var utilization: [String: Int] = [:]
        if let five = fiveHourUtilization { utilization[SessionWindow.key] = five }
        if let seven = sevenDayUtilization { utilization[WeeklyReset.key] = seven }
        guard !utilization.isEmpty else { return nil }
        return UsageSample(sampledAt: fetchedAt, org: org, utilization: utilization)
    }
}
