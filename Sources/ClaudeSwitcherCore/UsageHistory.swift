import Foundation

/// One reading Claude Desktop took of an account's plan usage.
public struct UsageSample: Equatable, Sendable {
    public let sampledAt: Date
    public let org: String?
    /// Utilization per limit, 0…100. Keys as the app writes them: `fh` five-hour session,
    /// `sd` seven-day, and — only for accounts that have them — `so` / `sn` (weekly Opus /
    /// Sonnet), `cw` (Cowork), `oa` (OAuth apps), `xu` (extra usage), and others.
    public let utilization: [String: Int]

    public init(sampledAt: Date, org: String?, utilization: [String: Int]) {
        self.sampledAt = sampledAt
        self.org = org
        self.utilization = utilization
    }
}

/// Reads the usage history Claude Desktop keeps in each profile's user-data directory.
///
/// The app appends a sample to `plan-usage-history.json` whenever it learns the account's
/// usage — at most every 270 s per org, about every 15 minutes in practice — **while that
/// profile is running**, and keeps 30 days of them. Everything here only reads that file. No
/// network, no token, no cookie: the numbers are whatever the app last observed.
public enum UsageHistory {

    public static let fileName = "plan-usage-history.json"

    /// The history file of a profile. `nil` is the default profile, i.e. the app's own
    /// user-data directory.
    public static func fileURL(forUserDataDir dir: String?, home: String = NSHomeDirectory()) -> URL {
        let directory = dir.map { PathNormalizer.normalize($0, home: home) } ?? Config.defaultUserDataDir(home: home)
        return URL(fileURLWithPath: directory).appendingPathComponent(fileName)
    }

    /// Decodes a history file, sorted by time. `nil` unless it is a usage history at all.
    ///
    /// Tolerant on purpose: a sample missing its timestamp is skipped, a non-numeric value is
    /// dropped, an unknown key is kept, and the legacy v1 layout (`fh`/`sd` beside `t`) reads
    /// the same as v2. Values are clamped to 0…100.
    public static func samples(from data: Data) -> [UsageSample]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              root["version"] is NSNumber,
              let raw = root["samples"] as? [[String: Any]]
        else { return nil }

        let samples = raw.compactMap { entry -> UsageSample? in
            guard let milliseconds = entry["t"] as? NSNumber else { return nil }
            let utilization: [String: Int]
            if let u = entry["u"] as? [String: Any] {
                utilization = u.compactMapValues(percent)
            } else {
                // v1 kept the two known values as top-level keys.
                utilization = ["fh": entry["fh"], "sd": entry["sd"]].compactMapValues(percent)
            }
            return UsageSample(
                sampledAt: Date(timeIntervalSince1970: milliseconds.doubleValue / 1000),
                org: entry["org"] as? String,
                utilization: utilization
            )
        }
        return samples.sorted { $0.sampledAt < $1.sampledAt }
    }

    /// The history of a profile, or `nil` when there is none (never ran, or unreadable).
    public static func read(userDataDir: String?, home: String = NSHomeDirectory()) -> [UsageSample]? {
        guard let data = try? Data(contentsOf: fileURL(forUserDataDir: userDataDir, home: home)) else { return nil }
        return samples(from: data)
    }

    /// The samples of the org the profile is currently on: the one the latest sample belongs
    /// to. An account can switch orgs; the other org's history must not colour this one.
    public static func currentOrgSamples(_ samples: [UsageSample]) -> [UsageSample] {
        guard let latest = samples.last else { return [] }
        return samples.filter { $0.org == latest.org }
    }

    private static func percent(_ value: Any?) -> Int? {
        // `value is Bool` is not the test: JSON 0 and 1 bridge to Bool too, and 0 and 1 are
        // exactly what a fresh window reads. Only a real JSON boolean is a CFBoolean.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return min(100, max(0, Int(number.doubleValue.rounded())))
    }
}

/// The five-hour session window the latest sample belongs to, with the earliest and latest
/// moments it can end. Both bounds hold under the stated model of the window (A3).
///
/// Inside one window utilization never decreases and the window lasts five hours, so the
/// longest trailing run of non-decreasing `fh` values spanning under five hours lies within
/// one window. It was already running at that run's first positive sample — so it ends no
/// later than five hours after it — and the sample before the run belongs to an earlier
/// window, so it ends no earlier than five hours after *that*. A `0` inside the run is an
/// ordinary member: a first message can round to 0 %, and the real histories on this Mac
/// show windows that had started before a sample that still read 0.
///
/// Assumed (A3): a window starts at its first message rounded down to a ten-minute mark —
/// every exact five-hour reset Claude Code has recorded on this Mac falls on one (09-05 01:10Z
/// then 06:10Z; a first message at 15:18:31 reset at 20:10). So the upper bound is the first
/// positive sample's ten-minute mark plus five hours, up to ten minutes tighter than the sample
/// itself would give. Were the assumption wrong, "resets by" could be up to ten minutes early.
public struct SessionWindow: Equatable, Sendable {
    public static let length: TimeInterval = 5 * 3600
    /// Windows start on these marks (A3).
    public static let startQuantum: TimeInterval = 600
    public static let key = "fh"

    public let utilization: Int
    /// The window ends strictly after this.
    public let resetsAfter: Date
    /// The window ends no later than this.
    public let resetsBy: Date
    /// The exact end, when Claude Code recorded it (a `five_hour` limit hit) or a fresh cached
    /// usage body says so, and it is still ahead.
    public let exactEnd: Date?
    /// When ``exactEnd`` came from a cached usage body rather than a limit hit: the moment the
    /// CLI's usage check fetched it. `nil` for a limit hit (or no exact end).
    public let exactEndCheckedAt: Date?
    /// When no sample lies inside the current window: its start as this Mac's activity shows
    /// it — the first attributed call after the previous window's latest end, at its ten-minute
    /// mark. ``resetsBy`` is then five hours after it. Use elsewhere could only have started the
    /// window earlier, so this stays an upper bound.
    public let activityStart: Date?

    public init(utilization: Int, resetsAfter: Date, resetsBy: Date, exactEnd: Date? = nil, activityStart: Date? = nil,
                exactEndCheckedAt: Date? = nil) {
        self.utilization = utilization
        self.resetsAfter = resetsAfter
        self.resetsBy = resetsBy
        self.exactEnd = exactEnd
        self.exactEndCheckedAt = exactEnd == nil ? nil : exactEndCheckedAt
        self.activityStart = activityStart
    }

    /// The exact end was reported by a cached usage check, not recorded at a limit hit.
    public var exactEndFromCache: Bool { exactEndCheckedAt != nil }

    /// The `five_hour` anchor still ahead and within one window of `now` — the open window's
    /// exact end — preferring a limit hit to a cached report of the same end.
    static func exactEndAnchor(_ anchors: [LimitAnchor], now: Date) -> LimitAnchor? {
        // Step by step rather than one chained expression: the type checker has a time limit,
        // and a slower machine can hit it on a closure that compares tuples.
        let ahead = anchors.filter { anchor in
            anchor.kind == .fiveHour && anchor.resetsAt > now && anchor.resetsAt.timeIntervalSince(now) <= length
        }
        func rank(_ anchor: LimitAnchor) -> Int { anchor.source == .transcript ? 0 : 1 }
        return ahead.min { a, b in
            if a.resetsAt != b.resetsAt { return a.resetsAt < b.resetsAt }
            return rank(a) < rank(b)
        }
    }

    /// A five-hour limit hit Claude Code recorded after the latest sample (`after`), its reset
    /// still ahead within one window: the window is full — recorded, not estimated — until then.
    /// A cached usage body is no hit.
    static func recordedHit(_ anchors: [LimitAnchor], after latestSample: Date?, now: Date) -> LimitAnchor? {
        let since: Date = latestSample ?? .distantPast
        let hits = anchors.filter { anchor in
            guard anchor.kind == .fiveHour, anchor.source == .transcript else { return false }
            guard anchor.resetsAt > now, anchor.resetsAt.timeIntervalSince(now) <= length else { return false }
            return anchor.hitAt >= since
        }
        return hits.max { a, b in a.hitAt < b.hitAt }
    }

    /// A recorded end of the sampled window that has passed: a `five_hour` reset Claude Code
    /// recorded (or a cached usage check reported) at or after the window's latest sample — so
    /// it is this window's end, not an earlier one's — no later than the window's own bound, and
    /// at or before `now`. The window ended then, whatever its bound says: the bound is floored
    /// from the first sample and can lie hours after the real end.
    static func recordedEnd(of window: SessionWindow, latestSample: Date, anchors: [LimitAnchor], now: Date) -> Date? {
        let bound: Date = window.resetsBy
        let ends: [Date] = anchors.compactMap { anchor in
            guard anchor.kind == .fiveHour else { return nil }
            guard anchor.resetsAt >= latestSample, anchor.resetsAt <= bound, anchor.resetsAt <= now else { return nil }
            return anchor.resetsAt
        }
        return ends.min()
    }

    /// This window, ended at a recorded time.
    func ended(at end: Date) -> SessionWindow {
        SessionWindow(utilization: utilization, resetsAfter: min(resetsAfter, end), resetsBy: end)
    }

    /// The ten-minute mark at or before `date`.
    public static func floorToStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / startQuantum).rounded(.down) * startQuantum)
    }

    /// The current window from the samples, a recorded exact end and this Mac's activity.
    ///
    /// - While the latest sample's window has not certainly ended, it is that window, with
    ///   ``exactEnd`` from a `five_hour` anchor (or a fresh cached end) still ahead of `now`. A
    ///   recorded end of it that has passed ends it there and then.
    /// - Otherwise the windows this account's activity shows are walked forward from the
    ///   sample's window's end — the recorded one, else its latest: each starts at the
    ///   ten-minute mark of the first call at or after the previous one's end and lasts five
    ///   hours. The one `now` lies in, if any, is returned with ``activityStart``; none means no
    ///   window is open as far as this Mac knows, and the ended sample window (for its tooltip)
    ///   or `nil` is returned.
    /// - A `five_hour` anchor still ahead with no window otherwise known is a window of its own:
    ///   the limit was hit, so it reads 100 until then.
    public static func infer(from samples: [UsageSample], anchors: [LimitAnchor], activity: ActivityLedger?, now: Date) -> SessionWindow? {
        let anchor = exactEndAnchor(anchors, now: now)
        let exactEnd = anchor?.resetsAt
        let checkedAt = anchor.flatMap { $0.source == .cachedUsage ? $0.hitAt : nil }
        let latestSample = samples.last { $0.utilization[key] != nil }?.sampledAt
        let sampled = infer(from: samples)
        let ended = sampled.flatMap { window in latestSample.flatMap { recordedEnd(of: window, latestSample: $0, anchors: anchors, now: now) } }
        if let sampled, ended == nil, now < sampled.resetsBy {
            return sampled.with(exactEnd: exactEnd, checkedAt: checkedAt)
        }

        if let activity {
            var boundary = ended ?? sampled?.resetsBy ?? latestSample ?? activity.buckets.first?.start ?? now
            while let bucket = activity.firstCallBucket(atOrAfter: floorToStart(boundary)), bucket.start <= now {
                let end = bucket.start.addingTimeInterval(length)
                if now < end {
                    // It was still open at its latest call.
                    let lastInside = activity.lastCallBucket(before: end)?.last ?? bucket.last
                    return SessionWindow(utilization: 0, resetsAfter: lastInside, resetsBy: end,
                                         exactEnd: exactEnd, activityStart: bucket.start, exactEndCheckedAt: checkedAt)
                }
                boundary = end
            }
        }
        if let exactEnd {
            return SessionWindow(utilization: 100, resetsAfter: exactEnd, resetsBy: exactEnd, exactEnd: exactEnd,
                                 exactEndCheckedAt: checkedAt)
        }
        if let sampled, let ended { return sampled.ended(at: ended) }
        return sampled
    }

    func with(exactEnd: Date?, checkedAt: Date? = nil) -> SessionWindow {
        SessionWindow(utilization: utilization, resetsAfter: resetsAfter, resetsBy: resetsBy, exactEnd: exactEnd, activityStart: activityStart,
                      exactEndCheckedAt: checkedAt)
    }

    /// `nil` when the latest sample has no session value, or reads 0 (no window to speak of).
    public static func infer(from samples: [UsageSample]) -> SessionWindow? {
        let readings = samples.compactMap { sample -> (at: Date, fh: Int)? in
            guard let fh = sample.utilization[key] else { return nil }
            return (sample.sampledAt, fh)
        }
        guard let latest = readings.last, latest.fh > 0 else { return nil }

        // Walk back while the run stays non-decreasing and within one window's length.
        var start = readings.count - 1
        while start > 0,
              readings[start - 1].fh <= readings[start].fh,
              latest.at.timeIntervalSince(readings[start - 1].at) < length {
            start -= 1
        }
        let firstPositive = readings[start...].first { $0.fh > 0 } ?? latest

        var resetsAfter = latest.at
        if start > 0 {
            resetsAfter = max(resetsAfter, readings[start - 1].at.addingTimeInterval(length))
        }
        // A3 makes the upper bound the run's first positive sample's ten-minute mark plus five
        // hours. Never below the lower bound: under A3 it cannot be, so a history where it would
        // be contradicts the assumption, and the unfloored reasoning is kept there.
        return SessionWindow(
            utilization: latest.fh,
            resetsAfter: resetsAfter,
            resetsBy: max(floorToStart(firstPositive.at).addingTimeInterval(length), resetsAfter)
        )
    }
}

/// When the weekly limit next resets, with the earliest and latest moments it can happen.
///
/// The weekly limit is assumed to reset on a fixed schedule — the same weekday and time every
/// week, moved only by a plan change (A1, A2). ``WeeklySchedule`` infers it from the drops in
/// the weekly figure and from the exact reset times Claude Code records; this is its next
/// occurrence. Both bounds hold under that assumption, not beyond it: a one-off early reset by
/// Anthropic makes the real one sooner without moving the schedule.
public struct WeeklyReset: Equatable, Sendable {
    public static let period: TimeInterval = WeeklySchedule.period
    public static let key = "sd"

    /// The reset happens strictly after this.
    public let resetsAfter: Date
    /// The reset happens no later than this.
    public let resetsBy: Date
    /// Where the schedule comes from; `nil` for a value made by hand.
    public let source: WeeklySchedule.Source?
    /// The reset time may be shown as recorded (see ``WeeklySchedule/isFresh(now:)``).
    public let isFresh: Bool

    public init(resetsAfter: Date, resetsBy: Date, source: WeeklySchedule.Source? = nil, isFresh: Bool = false) {
        self.resetsAfter = resetsAfter
        self.resetsBy = resetsBy
        self.source = source
        self.isFresh = isFresh
    }

    /// The schedule's next occurrence after `now`.
    public init(schedule: WeeklySchedule, now: Date) {
        let next = schedule.next(after: now)
        self.init(resetsAfter: next.after, resetsBy: next.by, source: schedule.source, isFresh: schedule.isFresh(now: now))
    }

    /// The next reset after `now`, or `nil` when no reset has been observed yet (a profile
    /// that has not been open across one). From the samples alone.
    public static func infer(from samples: [UsageSample], now: Date) -> WeeklyReset? {
        infer(from: samples, anchors: [], now: now)
    }

    /// The next reset after `now`, from the samples and the recorded limit hits.
    public static func infer(from samples: [UsageSample], anchors: [LimitAnchor], now: Date) -> WeeklyReset? {
        WeeklySchedule.infer(samples: samples, anchors: anchors, now: now).map { WeeklyReset(schedule: $0, now: now) }
    }

    /// Whether a reset has certainly happened between `sampledAt` and `now`: some occurrence
    /// of the schedule lies wholly inside that span.
    public func hasCertainlyReset(since sampledAt: Date, now: Date) -> Bool {
        // An exact reset (no width) at the sample's own instant came before it; a bracket
        // starting there lies after it.
        let exact = resetsAfter == resetsBy
        func follows(_ after: Date) -> Bool { exact ? after > sampledAt : after >= sampledAt }
        // Walk back from the next occurrence to the first one that could follow the sample.
        var after = resetsAfter
        var by = resetsBy
        while follows(after.addingTimeInterval(-Self.period)) {
            after = after.addingTimeInterval(-Self.period)
            by = by.addingTimeInterval(-Self.period)
        }
        return follows(after) && by <= now
    }
}

/// How close to a limit a percentage is; drives the bar colour.
public enum UsageLevel: Equatable, Sendable {
    case normal
    case warning
    case limit

    public static func of(_ percent: Int) -> UsageLevel {
        if percent >= 100 { return .limit }
        if percent >= 80 { return .warning }
        return .normal
    }
}

/// What the menu shows for one profile, derived from its history at a given moment.
public struct UsageReading: Equatable, Sendable {

    public enum Value: Equatable, Sendable {
        case percent(Int)
        /// The limit's period has certainly ended since the sample; the number is stale.
        case ended
    }

    public struct Row: Equatable, Sendable {
        public let key: String
        public let label: String
        public let value: Value

        public var percent: Int? {
            if case .percent(let n) = value { return n }
            return nil
        }
    }

    public static let weeklyLength: TimeInterval = 7 * 86400

    /// Limits that get a bar, in display order. Anything else is `unlisted`.
    public static let rowTable: [(key: String, label: String)] = [
        ("fh", "5h"), ("sd", "week"), ("so", "Opus"), ("sn", "Sonnet"),
        ("cw", "Cowork"), ("oa", "apps"), ("xu", "extra"),
    ]
    private static let weeklyKeys: Set<String> = ["sd", "so", "sn", "cw", "oa"]

    public let sampledAt: Date
    public let age: TimeInterval
    public let rows: [Row]
    /// Present whenever the latest session value is above 0 — even once the window has ended.
    public let session: SessionWindow?
    /// The next weekly reset, once one has been observed.
    public let weekly: WeeklyReset?
    /// Values the latest sample carried that get no bar.
    public let unlisted: [String: Int]

    public init(sampledAt: Date, age: TimeInterval, rows: [Row], session: SessionWindow?, weekly: WeeklyReset? = nil, unlisted: [String: Int]) {
        self.sampledAt = sampledAt
        self.age = age
        self.rows = rows
        self.session = session
        self.weekly = weekly
        self.unlisted = unlisted
    }

    /// `nil` when there is nothing to show.
    public static func make(samples all: [UsageSample], now: Date) -> UsageReading? {
        make(samples: all, anchors: [], now: now)
    }

    /// As ``make(samples:now:)``, with the limit hits Claude Code recorded for the account, so
    /// a recorded weekly reset time replaces the estimate from the samples.
    public static func make(samples all: [UsageSample], anchors: [LimitAnchor], now: Date) -> UsageReading? {
        let samples = UsageHistory.currentOrgSamples(all)
        guard let latest = samples.last else { return nil }
        let age = now.timeIntervalSince(latest.sampledAt)
        // A `five_hour` limit hit (or a fresh cached report) still ahead is the window's exact end.
        let anchor = SessionWindow.exactEndAnchor(anchors, now: now)
        let latestWindowSample = samples.last { $0.utilization[SessionWindow.key] != nil }?.sampledAt
        // A five-hour limit hit recorded after the latest sample: full until its recorded end, as
        // the forecast line says — recorded, so the row shows it rather than "—" or the older value.
        let hit = SessionWindow.recordedHit(anchors, after: latestWindowSample, now: now)
        let session: SessionWindow?
        if let hit {
            session = SessionWindow(utilization: 100, resetsAfter: hit.resetsAt, resetsBy: hit.resetsAt, exactEnd: hit.resetsAt)
        } else {
            session = SessionWindow.infer(from: samples).map { window in
                // A recorded end that has passed ended the sampled window then.
                if let at = latestWindowSample, let end = SessionWindow.recordedEnd(of: window, latestSample: at, anchors: anchors, now: now) {
                    return window.ended(at: end)
                }
                return now < window.resetsBy
                    ? window.with(exactEnd: anchor?.resetsAt, checkedAt: anchor.flatMap { $0.source == .cachedUsage ? $0.hitAt : nil })
                    : window
            }
        }
        let weekly = WeeklyReset.infer(from: samples, anchors: anchors, now: now)

        var rows: [Row] = []
        var unlisted = latest.utilization
        for (key, label) in rowTable {
            guard let percent = unlisted.removeValue(forKey: key) else { continue }
            let value: Value
            if key == SessionWindow.key, hit != nil {
                value = .percent(100)
            } else if key == SessionWindow.key, let session, now >= (session.exactEnd ?? session.resetsBy) {
                value = .ended
            } else if weeklyKeys.contains(key), age >= weeklyLength {
                value = .ended
            } else if weeklyKeys.contains(key), let weekly, weekly.hasCertainlyReset(since: latest.sampledAt, now: now) {
                value = .ended
            } else {
                value = .percent(percent)
            }
            rows.append(Row(key: key, label: label, value: value))
        }
        return UsageReading(sampledAt: latest.sampledAt, age: age, rows: rows, session: session, weekly: weekly, unlisted: unlisted)
    }
}

/// The words for a reading. `time` renders a clock time, injected so tests are locale-free.
public enum UsageText {

    /// `nil` under 30 minutes; the reading is fresh enough not to need a caveat.
    public static func age(_ interval: TimeInterval) -> String? {
        let minutes = Int(interval / 60)
        guard minutes >= 30 else { return nil }
        if minutes < 120 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }

    /// "5h 22%", or "5h —" once the period has ended.
    public static func row(_ row: UsageReading.Row) -> String {
        switch row.value {
        case .percent(let n): return "\(row.label) \(n)%"
        case .ended: return "\(row.label) \u{2014}"
        }
    }

    /// The small text after a bar: the session row says when the window ends (its certain
    /// upper bound, or the exact end Claude Code recorded), the week row when the week resets
    /// and how old the reading is.
    public static func trailing(for row: UsageReading.Row, in reading: UsageReading, time: (Date) -> String) -> String? {
        switch row.key {
        case SessionWindow.key:
            guard let session = reading.session, row.percent != nil else { return nil }
            return windowReset(session, time: time)
        case WeeklyReset.key:
            var parts: [String] = []
            if let weekly = reading.weekly, row.percent != nil { parts.append(weekReset(weekly, time: time)) }
            if let age = age(reading.age) { parts.append(age) }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
        default:
            return nil
        }
    }

    /// "resets by 9:13 PM (est.)", or "resets 9:10 PM" when Claude Code recorded the exact end
    /// (A11: the window keeps its "(est.)" unless a transcript anchor exists).
    public static func windowReset(_ session: SessionWindow, time: (Date) -> String) -> String {
        if let exact = session.exactEnd { return "resets \(time(exact))" }
        return "resets by \(time(session.resetsBy)) (est.)"
    }

    /// The week's reset: "resets Sat 9:00 PM" only when the schedule is exact and fresh (an
    /// anchor or agreeing bracket at most 14 days old, nothing newer disagreeing); an older exact
    /// time keeps "(est.)" — the weekly repeat is an assumption (A1) — and a bracketed one says
    /// "resets by" its latest moment.
    public static func weekReset(_ weekly: WeeklyReset, time: (Date) -> String) -> String {
        if weekly.isFresh { return "resets \(time(weekly.resetsBy))" }
        if weekly.resetsAfter == weekly.resetsBy { return "resets \(time(weekly.resetsBy)) (est.)" }
        return "resets by \(time(weekly.resetsBy)) (est.)"
    }

    public static func tooltip(_ reading: UsageReading, time: (Date) -> String) -> String {
        var lines: [String] = []
        lines.append(reading.rows.map(UsageText.row).joined(separator: "  \u{00B7}  "))
        if let session = reading.session {
            if reading.rows.contains(where: { $0.key == SessionWindow.key && $0.percent != nil }) {
                lines.append("Estimated: the 5-hour window ends between \(time(session.resetsAfter)) and \(time(session.resetsBy)).")
            } else {
                lines.append("The 5-hour window seen at \(time(reading.sampledAt)) has ended; nothing has been recorded since.")
            }
        }
        if !reading.unlisted.isEmpty {
            let extras = reading.unlisted.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)%" }
            lines.append("Also reported: \(extras.joined(separator: ", ")).")
        }
        if let weekly = reading.weekly {
            if reading.rows.contains(where: { $0.key == WeeklyReset.key && $0.percent != nil }) {
                lines.append("Estimated: the week resets between \(time(weekly.resetsAfter)) and \(time(weekly.resetsBy)) — at the same time every week.")
            } else if reading.rows.contains(where: { $0.key == WeeklyReset.key }) {
                lines.append("The week has reset since this was recorded; the next reset is estimated by \(time(weekly.resetsBy)).")
            }
        }
        lines.append("Reset times are estimated from this account's own history; the exact time is not recorded locally.")
        lines.append("Last recorded \(time(reading.sampledAt))\(age(reading.age).map { " (\($0))" } ?? ""). Claude Desktop records usage only while this account is open, so use from claude.ai or your phone on this account shows up only then.")
        return lines.joined(separator: "\n")
    }

    /// One sentence for VoiceOver. Its times keep the rows' suffix rule: said plainly only when
    /// recorded (an exact window end; an exact and fresh weekly schedule), "estimated" otherwise.
    public static func accessibilityText(_ reading: UsageReading, profileLabel: String, time: (Date) -> String) -> String {
        accessibilityText(reading, profileLabel: profileLabel, time: time, estimates: [:], windowNote: nil)
    }

    /// As above, with what the bars draw beyond the recording: `estimates` per row key (the
    /// lighter segment, said "estimated N percent" after the row), and `windowNote`, the words
    /// for the end of a window only this Mac's activity shows (said where a recorded window's
    /// end would be).
    static func accessibilityText(_ reading: UsageReading, profileLabel: String, time: (Date) -> String, estimates: [String: Int],
                                  windowNote: String?) -> String {
        var parts: [String] = []
        for row in reading.rows {
            switch row.value {
            case .percent(let n): parts.append("\(row.label) \(n) percent")
            case .ended: parts.append("\(row.label) ended")
            }
            if let estimate = estimates[row.key] { parts.append("estimated \(estimate) percent") }
        }
        if let session = reading.session, reading.rows.contains(where: { $0.key == SessionWindow.key && $0.percent != nil }) {
            if let exact = session.exactEnd {
                parts.append("reset at \(time(exact))")
            } else {
                parts.append("estimated reset by \(time(session.resetsBy))")
            }
        } else if let windowNote {
            parts.append(windowNote)
        }
        if let weekly = reading.weekly, reading.rows.contains(where: { $0.key == WeeklyReset.key && $0.percent != nil }) {
            if weekly.isFresh {
                parts.append("week reset at \(time(weekly.resetsBy))")
            } else if weekly.resetsAfter == weekly.resetsBy {
                parts.append("estimated week reset at \(time(weekly.resetsBy))")
            } else {
                parts.append("estimated week reset by \(time(weekly.resetsBy))")
            }
        }
        if let age = age(reading.age) { parts.append(age) }
        return "\(profileLabel) usage: \(parts.joined(separator: ", "))"
    }

    /// One line for Diagnostics and `--dry-run`.
    public static func summary(_ reading: UsageReading?, time: (Date) -> String) -> String {
        guard let reading else { return "no data yet (recorded once Claude has run on this account)" }
        var parts = reading.rows.map(UsageText.row)
        if let session = reading.session, reading.rows.contains(where: { $0.key == SessionWindow.key && $0.percent != nil }) {
            parts.append(windowReset(session, time: time))
        }
        if let weekly = reading.weekly, reading.rows.contains(where: { $0.key == WeeklyReset.key && $0.percent != nil }) {
            parts.append("week " + weekReset(weekly, time: time))
        }
        parts.append("recorded \(time(reading.sampledAt))\(age(reading.age).map { " (\($0))" } ?? "")")
        return parts.joined(separator: " \u{00B7} ")
    }
}
