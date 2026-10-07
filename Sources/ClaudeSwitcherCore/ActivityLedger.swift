import Foundation

// MARK: - Limit hits

/// Which limit a `quotaLimits.rateLimitType` names.
///
/// `seven_day_overage_included` is the limit Claude Code itself labels "Fable limit": a weekly
/// limit on the Fable models alone that can be reached while the all-models week still has
/// room. `seven_day_opus` / `seven_day_sonnet` are per-model weekly limits. Anything else is
/// kept and counted, never used for a schedule.
public enum LimitKind: Hashable, Sendable {
    case fiveHour
    case sevenDay
    case fable
    case model(String)
    case other(String)

    public init(rateLimitType raw: String) {
        switch raw {
        case "five_hour": self = .fiveHour
        case "seven_day": self = .sevenDay
        case "seven_day_overage_included": self = .fable
        case "seven_day_opus": self = .model("opus")
        case "seven_day_sonnet": self = .model("sonnet")
        default: self = .other(raw)
        }
    }

    /// The `rateLimitType` this kind was read from (what the index stores).
    public var rateLimitType: String {
        switch self {
        case .fiveHour: return "five_hour"
        case .sevenDay: return "seven_day"
        case .fable: return "seven_day_overage_included"
        case .model(let name): return "seven_day_" + name
        case .other(let raw): return raw
        }
    }

    /// What the menu calls it.
    public var label: String {
        switch self {
        case .fiveHour: return "5-hour limit"
        case .sevenDay: return "weekly limit"
        case .fable: return "Fable limit"
        case .model(let name): return name.prefix(1).uppercased() + name.dropFirst() + " limit"
        case .other: return "another limit"
        }
    }
}

/// One limit hit Claude Code recorded: an assistant line with `"error":"rate_limit"` carrying
/// `quotaLimits {status:"rejected", rateLimitType, resetsAt}`. `resetsAt` is exact — it comes
/// from the API's own headers — and is rounded to the minute, because the API's `resets_at`
/// jitters by about a second (03:59:59.716 one week, 04:00:00.597 the next).
public struct LimitAnchor: Hashable, Sendable {
    /// Who said so. Only a transcript line is a limit hit; a fresh cached usage body in
    /// `~/.claude.json` times the reset as exactly, but nothing was refused — the words must not
    /// say a limit was hit. The index stores transcript anchors only.
    public enum Source: Hashable, Sendable {
        /// An assistant line with `"error":"rate_limit"`: Claude Code was refused. `hitAt` is the line's time.
        case transcript
        /// The CLI's own usage check, cached in `~/.claude.json`. `hitAt` is the fetch time.
        case cachedUsage
    }

    public let resetsAt: Date
    public let kind: LimitKind
    /// When the limit was first hit for this reset (the line's timestamp), or, for a cached
    /// usage body, when it was fetched.
    public let hitAt: Date
    public let source: Source

    public init(resetsAt: Date, kind: LimitKind, hitAt: Date, source: Source = .transcript) {
        self.resetsAt = Self.roundedToMinute(resetsAt)
        self.kind = kind
        self.hitAt = hitAt
        self.source = source
    }

    public static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// One anchor per (kind, reset instant), at its first hit, sorted by reset then kind. A
    /// recorded limit hit outranks a cached usage body naming the same reset.
    public static func merged(_ anchors: [LimitAnchor]) -> [LimitAnchor] {
        var first: [Key: LimitAnchor] = [:]
        for anchor in anchors {
            let key = Key(kind: anchor.kind, resetsAt: anchor.resetsAt)
            guard let held = first[key] else { first[key] = anchor; continue }
            if (anchor.source == .transcript ? 0 : 1, anchor.hitAt) < (held.source == .transcript ? 0 : 1, held.hitAt) {
                first[key] = anchor
            }
        }
        return first.values.sorted { ($0.resetsAt, $0.kind.rateLimitType) < ($1.resetsAt, $1.kind.rateLimitType) }
    }

    private struct Key: Hashable {
        let kind: LimitKind
        let resetsAt: Date
    }
}

// MARK: - The ledger

/// One account's activity as read from this Mac's Claude Code transcripts: weighted spend per
/// ten minutes, the limit hits, and the sessions it came from. Numbers and ids only.
///
/// Spend is a weighting, not money: token counts at list prices, cache reads excluded, subagent
/// output filled in (A4). One point of the weekly limit is about 13.5 units on a Max 20x plan.
/// Only spend attributed to the account through its session records is here (A6).
public struct ActivityLedger: Equatable, Sendable {

    public static let bucketLength: TimeInterval = 600

    /// Ten minutes of activity, `[start, start + 10 min)`.
    public struct Bucket: Equatable, Sendable {
        public let start: Date
        /// The first and last call or prompt inside the bucket.
        public let first: Date
        public let last: Date
        public let spend: Double
        public let calls: Int
        public let subagentCalls: Int
        public let subagentSpend: Double
        /// Prompts typed by the user (not tool results, not Claude's own meta lines).
        public let prompts: Int
        /// Spend by model id (`claude-opus-5-5`, …).
        public let spendByModel: [String: Double]

        public init(start: Date, first: Date, last: Date, spend: Double, calls: Int, subagentCalls: Int = 0,
                    subagentSpend: Double = 0, prompts: Int = 0, spendByModel: [String: Double] = [:]) {
            self.start = start
            self.first = first
            self.last = last
            self.spend = spend
            self.calls = calls
            self.subagentCalls = subagentCalls
            self.subagentSpend = subagentSpend
            self.prompts = prompts
            self.spendByModel = spendByModel
        }

        /// Two buckets of the same ten minutes, added.
        func adding(_ other: Bucket) -> Bucket {
            Bucket(start: start, first: min(first, other.first), last: max(last, other.last),
                   spend: spend + other.spend, calls: calls + other.calls,
                   subagentCalls: subagentCalls + other.subagentCalls, subagentSpend: subagentSpend + other.subagentSpend,
                   prompts: prompts + other.prompts, spendByModel: spendByModel.merging(other.spendByModel, uniquingKeysWith: +))
        }
    }

    /// A burst of activity in one session: consecutive activity no more than `idleSplit` apart.
    public struct Episode: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let spend: Double
        public let prompts: Int
        /// Share of the spend that came from subagent and workflow calls.
        public let subagentShare: Double
        /// The session's transcript id (`cliSessionId`); subagent files count toward their parent.
        public let sessionId: String
        /// Spend in the episode's first hour and first three hours, by ten-minute bucket: what a
        /// long session costs before it can be judged (the Advisor fits a long session on its
        /// first three hours, and its five-hour window on its first hour).
        public let firstHourSpend: Double
        public let firstThreeHoursSpend: Double

        public init(start: Date, end: Date, spend: Double, prompts: Int, subagentShare: Double, sessionId: String,
                    firstHourSpend: Double? = nil, firstThreeHoursSpend: Double? = nil) {
            self.start = start
            self.end = end
            self.spend = spend
            self.prompts = prompts
            self.subagentShare = subagentShare
            self.sessionId = sessionId
            self.firstHourSpend = firstHourSpend ?? spend
            self.firstThreeHoursSpend = firstThreeHoursSpend ?? spend
        }

        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// The account's buckets, every session added, sorted by start.
    public let buckets: [Bucket]
    /// Each session's own buckets, sorted, by lowercased `cliSessionId`.
    public let sessions: [String: [Bucket]]
    /// Limit hits recorded in this account's transcripts, one per (kind, reset).
    public let anchors: [LimitAnchor]
    /// The index had read every transcript up to this moment.
    public let indexedThrough: Date
    /// Spend in transcripts no profile's records claim (terminal sessions, deleted records),
    /// over the whole index: excluded from every account and counted for Diagnostics.
    public let unattributedSpend: Double
    /// Calls whose model had no known price (weighted at Opus 5.5's).
    public let unpricedCalls: Int
    /// Spend from this moment on is complete: every transcript with a line at or after it has
    /// been read (a file modified before it holds nothing later). Earlier spend may be partial,
    /// so nothing is calibrated on it. `nil`: complete throughout.
    public let coveredSince: Date?
    /// The plan tier `~/.claude.json` last named for this account (`oauthAccount
    /// .organizationRateLimitTier`), as the index remembers it — the CLI names only the account
    /// it is signed in to, so this outlives its signing in to another one.
    public let tier: String?
    /// When the index saw that tier replace a different one: a plan change. What was calibrated
    /// before it no longer applies (A5). `nil` when the tier never changed.
    public let tierChangedAt: Date?
    private let cumulative: [Double]

    public init(sessions: [String: [Bucket]], anchors: [LimitAnchor], indexedThrough: Date,
                unattributedSpend: Double = 0, unpricedCalls: Int = 0, coveredSince: Date? = nil,
                tier: String? = nil, tierChangedAt: Date? = nil) {
        var sorted: [String: [Bucket]] = [:]
        var byStart: [Date: Bucket] = [:]
        for (id, buckets) in sessions {
            sorted[id.lowercased(), default: []].append(contentsOf: buckets)
            for bucket in buckets { byStart[bucket.start] = byStart[bucket.start]?.adding(bucket) ?? bucket }
        }
        self.sessions = sorted.mapValues { Self.combined($0) }
        self.buckets = byStart.values.sorted { $0.start < $1.start }
        self.anchors = LimitAnchor.merged(anchors)
        self.indexedThrough = indexedThrough
        self.unattributedSpend = unattributedSpend
        self.unpricedCalls = unpricedCalls
        self.coveredSince = coveredSince
        self.tier = tier
        self.tierChangedAt = tierChangedAt
        var running = 0.0
        cumulative = [0] + self.buckets.map { running += $0.spend; return running }
    }

    /// Buckets of one session added per ten minutes, sorted.
    private static func combined(_ buckets: [Bucket]) -> [Bucket] {
        var byStart: [Date: Bucket] = [:]
        for bucket in buckets { byStart[bucket.start] = byStart[bucket.start]?.adding(bucket) ?? bucket }
        return byStart.values.sorted { $0.start < $1.start }
    }

    public static func bucketStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / bucketLength).rounded(.down) * bucketLength)
    }

    // MARK: Queries

    /// Weighted spend in `[from, to)`. Whole buckets inside count fully; a bucket the boundary
    /// cuts counts by how much of its first-to-last span lies inside.
    public func spend(from: Date, to: Date) -> Double {
        guard to > from, !buckets.isEmpty else { return 0 }
        let low = firstIndex(startingAtOrAfter: Self.bucketStart(from))
        let high = firstIndex(startingAtOrAfter: to)
        guard low < high else { return 0 }
        var total = cumulative[high] - cumulative[low]
        // Only the two end buckets can be cut.
        for index in Set([low, high - 1]) {
            total -= buckets[index].spend * (1 - Self.fraction(of: buckets[index], from: from, to: to))
        }
        return max(0, total)
    }

    private static func fraction(of bucket: Bucket, from: Date, to: Date) -> Double {
        if bucket.first >= from && bucket.last < to { return 1 }
        if bucket.last < from || bucket.first >= to { return 0 }
        let span = bucket.last.timeIntervalSince(bucket.first)
        guard span > 0 else { return 1 }
        let inside = min(bucket.last, to).timeIntervalSince(max(bucket.first, from))
        return min(1, max(0, inside / span))
    }

    /// The first bucket with calls whose start is at or after `date`: under A3, a five-hour
    /// window that opens with a call starts at that call's ten-minute mark.
    public func firstCallBucket(atOrAfter date: Date) -> Bucket? {
        let index = firstIndex(startingAtOrAfter: date)
        return buckets[index...].first { $0.calls > 0 }
    }

    /// The latest call or prompt in the ledger.
    public var lastActivity: Date? { buckets.last?.last }

    /// The last bucket with calls that starts before `date`.
    public func lastCallBucket(before date: Date) -> Bucket? {
        let index = firstIndex(startingAtOrAfter: date)
        return buckets[..<index].last { $0.calls > 0 }
    }

    private func firstIndex(startingAtOrAfter date: Date) -> Int {
        var low = 0, high = buckets.count
        while low < high {
            let middle = (low + high) / 2
            if buckets[middle].start < date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Bursts of activity, per session: a gap of more than `idleSplit` between one call or
    /// prompt and the next starts a new episode. Sorted by start.
    public func episodes(idleSplit: TimeInterval = 1800) -> [Episode] {
        var all: [Episode] = []
        for (id, buckets) in sessions {
            var current: [Bucket] = []
            func close() {
                guard let head = current.first, let tail = current.last else { return }
                let spend = current.reduce(0) { $0 + $1.spend }
                let subagent = current.reduce(0) { $0 + $1.subagentSpend }
                func early(_ seconds: TimeInterval) -> Double {
                    current.filter { $0.first < head.first.addingTimeInterval(seconds) }.reduce(0) { $0 + $1.spend }
                }
                all.append(Episode(start: head.first, end: tail.last, spend: spend,
                                   prompts: current.reduce(0) { $0 + $1.prompts },
                                   subagentShare: spend > 0 ? subagent / spend : 0, sessionId: id,
                                   firstHourSpend: early(3600), firstThreeHoursSpend: early(3 * 3600)))
                current = []
            }
            for bucket in buckets where bucket.calls > 0 || bucket.prompts > 0 {
                if let tail = current.last, bucket.first.timeIntervalSince(tail.last) > idleSplit { close() }
                current.append(bucket)
            }
            close()
        }
        return all.sorted { ($0.start, $0.sessionId) < ($1.start, $1.sessionId) }
    }

    /// An empty ledger: nothing attributed yet.
    public static func empty(indexedThrough: Date) -> ActivityLedger {
        ActivityLedger(sessions: [:], anchors: [], indexedThrough: indexedThrough)
    }
}
