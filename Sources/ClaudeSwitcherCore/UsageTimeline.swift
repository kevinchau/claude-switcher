import Foundation

/// An account's history laid out three ways: every five-hour window the samples show, the
/// stretches between resets (for calibration), and the weekly cycles of the schedule (for
/// display: "reached the limit in 3 of the last 4 weeks").
public struct UsageTimeline: Equatable, Sendable {

    /// One recorded value.
    public struct Point: Equatable, Sendable {
        public let at: Date
        public let value: Int

        public init(at: Date, value: Int) {
            self.at = at
            self.value = value
        }
    }

    /// A five-hour window: a run of non-decreasing `fh` values that fits in one window, from the
    /// ten-minute mark of its first positive value (A3).
    public struct Window: Equatable, Sendable {
        /// The latest the window can have started.
        public let start: Date
        /// The latest it can have ended.
        public let endBy: Date
        public let peakFh: Int
        /// This account's weighted spend in `[start, endBy)`, when activity is known.
        public let spend: Double?
        /// The window's `fh` values, for calibrating the window weight.
        public let points: [Point]
    }

    /// A stretch of `sd` values with no reset inside: cut at every drop that is a reset —
    /// scheduled or not, the launch grants included — at every scheduled reset that certainly
    /// fell between two samples, and at gaps of a week or more. Regressing `sd` on spend inside
    /// one is sound; across a cut it is not.
    public struct Segment: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let points: [Point]
    }

    /// One week of the schedule, `[start, end)`.
    public struct Cycle: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let points: [Point]
        /// The first sample at 100, or the first recorded weekly limit hit, in the cycle.
        public let hitLimitAt: Date?
        /// For a finished cycle: 100 minus the last value when that was recorded within 3 h of
        /// the reset (0 once the limit was reached); `nil` when not known — never guessed.
        public let unusedAtEnd: Int?
    }

    public let windows: [Window]
    public let segments: [Segment]
    public let cycles: [Cycle]
    /// Over the last four finished cycles with any record: in how many the limit was reached.
    public let limitHit: Int
    public let limitHitOf: Int

    public var limitHitWeeks: (hit: Int, of: Int) { (limitHit, limitHitOf) }

    /// A finished cycle's end lies within this of its last sample for ``Cycle/unusedAtEnd``.
    static let unusedWindow: TimeInterval = 3 * 3600
    static let recentCycles = 4

    public static func build(samples all: [UsageSample], activity: ActivityLedger?, schedule: WeeklySchedule?, now: Date) -> UsageTimeline {
        let samples = UsageHistory.currentOrgSamples(all).filter { $0.sampledAt <= now }
        let weekly = samples.compactMap { sample in sample.utilization[WeeklyReset.key].map { Point(at: sample.sampledAt, value: $0) } }
        let session = samples.compactMap { sample in sample.utilization[SessionWindow.key].map { Point(at: sample.sampledAt, value: $0) } }
        let cycles = makeCycles(weekly, anchors: activity?.anchors ?? [], schedule: schedule, now: now)
        let finished = cycles.filter { $0.end <= now && ($0.hitLimitAt != nil || !$0.points.isEmpty) }.suffix(recentCycles)
        return UsageTimeline(
            windows: makeWindows(session, activity: activity),
            segments: makeSegments(weekly, schedule: schedule),
            cycles: cycles,
            limitHit: finished.filter { $0.hitLimitAt != nil }.count,
            limitHitOf: finished.count)
    }

    // MARK: Windows

    static func makeWindows(_ readings: [Point], activity: ActivityLedger?) -> [Window] {
        var windows: [Window] = []
        var run: [Point] = []
        func close() {
            defer { run = [] }
            guard let firstPositive = run.first(where: { $0.value > 0 }) else { return }
            let start = SessionWindow.floorToStart(firstPositive.at)
            let end = start.addingTimeInterval(SessionWindow.length)
            windows.append(Window(start: start, endBy: end, peakFh: run.map(\.value).max() ?? 0,
                                  spend: activity?.spend(from: start, to: end), points: run))
        }
        for reading in readings {
            if let last = run.last {
                let firstPositive = run.first { $0.value > 0 }
                let windowOver = firstPositive.map { reading.at >= SessionWindow.floorToStart($0.at).addingTimeInterval(SessionWindow.length) }
                    ?? (reading.at.timeIntervalSince(last.at) >= SessionWindow.length)
                if reading.value < last.value || windowOver { close() }
            }
            run.append(reading)
        }
        close()
        return windows
    }

    // MARK: Segments

    static func makeSegments(_ readings: [Point], schedule: WeeklySchedule?) -> [Segment] {
        var segments: [Segment] = []
        var current: [Point] = []
        func close() {
            if let first = current.first, let last = current.last {
                segments.append(Segment(start: first.at, end: last.at, points: current))
            }
            current = []
        }
        for reading in readings {
            if let last = current.last {
                let drop = WeeklySchedule.isResetDrop(from: last.value, to: reading.value)
                let scheduled = schedule?.hasCertainlyReset(since: last.at, now: reading.at) ?? false
                let gap = reading.at.timeIntervalSince(last.at) >= WeeklySchedule.period
                if drop || scheduled || gap { close() }
            }
            current.append(reading)
        }
        close()
        return segments
    }

    // MARK: Cycles

    static func makeCycles(_ readings: [Point], anchors: [LimitAnchor], schedule: WeeklySchedule?, now: Date) -> [Cycle] {
        guard let schedule, let first = readings.first?.at else { return [] }
        let weeklyHits = anchors.filter { $0.kind == .sevenDay }.map(\.hitAt)
        var cycles: [Cycle] = []
        var bounds = schedule.cycle(containing: min(first, weeklyHits.min() ?? first))
        let last = schedule.cycle(containing: now)
        while bounds.start <= last.start {
            let start = bounds.start, end = bounds.end
            let points = readings.filter { $0.at >= start && $0.at < end }
            let hits = (points.filter { $0.value >= 100 }.map(\.at) + weeklyHits.filter { $0 >= start && $0 < end })
            let hitLimitAt = hits.min()
            var unused: Int?
            if end <= now {
                if hitLimitAt != nil {
                    unused = 0
                } else if let tail = points.last, end.timeIntervalSince(tail.at) <= unusedWindow {
                    unused = 100 - tail.value
                }
            }
            cycles.append(Cycle(start: start, end: end, points: points, hitLimitAt: hitLimitAt, unusedAtEnd: unused))
            bounds = (end, end.addingTimeInterval(WeeklySchedule.period))
        }
        return cycles
    }
}
