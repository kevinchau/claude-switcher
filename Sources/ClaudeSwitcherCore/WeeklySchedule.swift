import Foundation

/// When the weekly limit resets: one instant a week, at a fixed phase, inferred from the drops
/// in the recorded weekly figure and from the exact reset times Claude Code writes down when a
/// limit is hit.
///
/// The model is an assumption, stated as one (A1): the weekly limit resets at the same weekday
/// and time every week, and only a plan change moves it. One-off resets — Anthropic's launch
/// grants on Tue 09-22 and Thu 09-24, the Fri 09-04 drop — do not move it (A2). The phase is a
/// UTC instant, not a local wall-clock time (A8).
///
/// Every observed reset votes for a phase on a circle one week round:
///
/// - **An exact anchor** — `resetsAt` of a `seven_day` limit hit, rounded to the minute, or a
///   fresh cached `seven_day.resets_at` — is a bracket of width zero. Any anchor recorded in
///   the last 60 days decides the schedule outright; the newest one sets the phase.
/// - **A drop in the weekly figure** between two consecutive samples brackets one reset
///   between them. It votes `1 / max(1, age in weeks) × min(1, 1 h / its width)`: a recent,
///   tight bracket counts fully, an old one or a 73-hour one barely. A decrease that neither
///   lands at 5 or below nor falls by 20 points is a sample out of order (a clock correction,
///   say), not a reset.
///
/// Brackets are clustered narrowest first, so the answer never depends on the order they were
/// seen in. The schedule moves only on a newer exact anchor that disagrees, or on the two
/// newest sample brackets both disagreeing with it and agreeing with each other; a single
/// disagreeing bracket is reported as ``unconfirmedPhase`` and changes nothing.
///
/// Inferred afresh from all the evidence each time, "moves only when" is kept by one more rule:
/// a phase seen in a single sample bracket never outranks a phase seen in two or more. The vote
/// alone would not keep it — the 09-22 grant was seen within five minutes (vote 1.0) while
/// Saturday's scheduled resets fell in brackets of three to eight hours, and four of them
/// (0.44–0.68 together) would lose to it for two weeks. Only a *sighting* counts towards
/// that: an exact anchor, or a bracket narrower than a day. A wider one is consistent with
/// every phase it spans — a six-day bracket "sees" Tuesday and Saturday alike — so it votes
/// (barely) but establishes nothing, and a phase it joined is not overtaken when it loses.
public struct WeeklySchedule: Equatable, Sendable {

    public static let period: TimeInterval = 7 * 86400
    /// Two brackets agree when their shifted intervals overlap within this. API jitter is under
    /// a second; the slack covers clock skew between this Mac and the server.
    static let slack: TimeInterval = 120
    /// An exact anchor older than this no longer decides anything (it is not even a vote).
    public static let exactAnchorMaximumAge: TimeInterval = 60 * 86400
    /// The schedule is fresh — its reset time may be shown without "(est.)" — only while the
    /// newest agreeing evidence is at most this old.
    public static let freshnessAge: TimeInterval = 14 * 86400
    /// A bracket this wide or narrower votes with its full weight.
    static let fullWeightWidth: TimeInterval = 3600
    /// A bracket narrower than this pins the weekday: it is a sighting of one phase.
    static let sightingWidth: TimeInterval = 86400
    /// A decrease is a reset only if it lands at or below this…
    static let resetLandsAtOrBelow = 5
    /// …or falls by at least this many points.
    static let resetFallsByAtLeast = 20

    public enum Source: Equatable, Sendable {
        /// Claude Code recorded the reset time: `anchors` exact anchors agree, the newest
        /// recorded at `lastHitAt` — a limit hit, or (`recordedBy` ``LimitAnchor/Source/cachedUsage``)
        /// the CLI's cached usage check fetched then, when no limit was hit.
        case exact(anchors: Int, lastHitAt: Date, recordedBy: LimitAnchor.Source = .transcript)
        /// Estimated from the drops in the samples; `support` is the winning cluster's vote,
        /// `newestAt` the end of its newest bracket.
        case bracketed(support: Double, newestAt: Date)
    }

    /// Seconds into a 604 800-second period counted from the Unix epoch (UTC): the middle of
    /// the reset interval.
    public let phase: TimeInterval
    /// Half the width of the reset interval; 0 when exact.
    public let halfWidth: TimeInterval
    public let source: Source
    /// The phase of the newest observed reset when it disagrees with ``phase`` and has not been
    /// confirmed (a one-off grant, or the first week of a plan change).
    public let unconfirmedPhase: TimeInterval?
    /// The newest evidence that agrees with the phase: an exact anchor's hit time, or the end
    /// of a sample bracket that contains the phase.
    public let confirmedAt: Date
    /// When the schedule has moved off an earlier, disagreeing one (a plan change): the first
    /// moment known to be on this phase. Calibration taken before it no longer applies.
    public let reanchoredAt: Date?
    /// Weekly decreases too small to be a reset (see the type's doc), for Diagnostics.
    public let outOfOrderSamples: Int

    public init(
        phase: TimeInterval, halfWidth: TimeInterval, source: Source, unconfirmedPhase: TimeInterval? = nil,
        confirmedAt: Date, reanchoredAt: Date? = nil, outOfOrderSamples: Int = 0
    ) {
        self.phase = Self.wrap(phase)
        self.halfWidth = max(0, halfWidth)
        self.source = source
        self.unconfirmedPhase = unconfirmedPhase.map(Self.wrap)
        self.confirmedAt = confirmedAt
        self.reanchoredAt = reanchoredAt
        self.outOfOrderSamples = outOfOrderSamples
    }

    public var isExact: Bool {
        if case .exact = source { return true }
        return false
    }

    // MARK: Occurrences

    /// The first occurrence that has not certainly happened by `now`: it happens strictly after
    /// `after` and no later than `by`, and `by > now`.
    public func next(after now: Date) -> (after: Date, by: Date) {
        let t = now.timeIntervalSince1970
        var k = ((t - phase - halfWidth) / Self.period).rounded(.down) + 1
        // Guard the floating-point edge: the occurrence before must already be due.
        if phase + (k - 1) * Self.period + halfWidth > t { k -= 1 }
        return occurrence(k)
    }

    /// The weekly cycle `now` lies in, cut at the middle of the reset interval (exact when the
    /// schedule is): `[start, end)`, `end − start` one week.
    public func cycle(containing now: Date) -> (start: Date, end: Date) {
        let k = ((now.timeIntervalSince1970 - phase) / Self.period).rounded(.down)
        let start = phase + k * Self.period
        return (Date(timeIntervalSince1970: start), Date(timeIntervalSince1970: start + Self.period))
    }

    /// Whether a reset has certainly happened between `since` and `now`: some occurrence lies
    /// wholly inside `(since, now]`. An exact reset at the very instant of `since` is not
    /// after it — Claude samples at the instant an exceeded limit resets, and that sample is
    /// already the new week's.
    public func hasCertainlyReset(since: Date, now: Date) -> Bool {
        let k = ((now.timeIntervalSince1970 - phase - halfWidth) / Self.period).rounded(.down)
        let latest = occurrence(k)
        return latest.by <= now && (halfWidth > 0 ? latest.after >= since : latest.by > since)
    }

    /// Whether the reset time may be shown as recorded rather than estimated: the schedule is
    /// exact, nothing newer disagrees, and the newest agreeing evidence is at most 14 days old.
    /// A bracketed schedule is never fresh — its "resets by" stays an estimate.
    public func isFresh(now: Date) -> Bool {
        isExact && unconfirmedPhase == nil && now.timeIntervalSince(confirmedAt) <= Self.freshnessAge
    }

    private func occurrence(_ k: Double) -> (after: Date, by: Date) {
        let middle = phase + k * Self.period
        return (Date(timeIntervalSince1970: middle - halfWidth), Date(timeIntervalSince1970: middle + halfWidth))
    }

    // MARK: Evidence

    /// The resets observed: zero-width brackets for exact anchors, `(after, by]` for drops.
    public struct Evidence: Equatable, Sendable {
        public struct Candidate: Equatable, Sendable {
            public let after: Date
            public let by: Date
            /// When it was recorded: a sample bracket's `by`, an anchor's hit time. Ages count from here.
            public let recordedAt: Date
            public let isExact: Bool
            /// An exact anchor from a cached usage body rather than a limit hit.
            public let isCached: Bool

            public init(after: Date, by: Date, recordedAt: Date, isExact: Bool, isCached: Bool = false) {
                self.after = after
                self.by = by
                self.recordedAt = recordedAt
                self.isExact = isExact
                self.isCached = isExact && isCached
            }

            public var width: TimeInterval { by.timeIntervalSince(after) }

            /// It pins one phase: exact, or a bracket narrower than a day.
            public var isSighting: Bool { isExact || width < WeeklySchedule.sightingWidth }
        }

        public let candidates: [Candidate]
        /// Decreases in the weekly figure too small to be a reset.
        public let outOfOrderSamples: Int

        public init(candidates: [Candidate], outOfOrderSamples: Int = 0) {
            self.candidates = candidates
            self.outOfOrderSamples = outOfOrderSamples
        }
    }

    /// Whether a decrease from `previous` to `current` is a reset rather than noise.
    public static func isResetDrop(from previous: Int, to current: Int) -> Bool {
        current < previous && (current <= resetLandsAtOrBelow || previous - current >= resetFallsByAtLeast)
    }

    /// Collects the brackets: one per qualifying `sd` drop narrower than a week, one per
    /// `seven_day` anchor recorded in the last 60 days (one per reset instant, its first hit).
    public static func evidence(samples: [UsageSample], anchors: [LimitAnchor], now: Date) -> Evidence {
        var candidates: [Evidence.Candidate] = []
        var outOfOrder = 0
        var previous: (at: Date, value: Int)?
        for sample in samples {
            guard let value = sample.utilization[WeeklyReset.key] else { continue }
            if let previous, value < previous.value {
                if isResetDrop(from: previous.value, to: value) {
                    if sample.sampledAt.timeIntervalSince(previous.at) < period {
                        candidates.append(.init(after: previous.at, by: sample.sampledAt, recordedAt: sample.sampledAt, isExact: false))
                    }
                } else {
                    outOfOrder += 1
                }
            }
            previous = (sample.sampledAt, value)
        }

        // One per reset instant: its first limit hit, else (no hit) the first cached report of it.
        var first: [Date: LimitAnchor] = [:]
        for anchor in anchors where anchor.kind == .sevenDay {
            guard now.timeIntervalSince(anchor.hitAt) <= exactAnchorMaximumAge,
                  anchor.resetsAt.timeIntervalSince(anchor.hitAt) <= period + slack
            else { continue }
            func rank(_ a: LimitAnchor) -> (Int, Date) { (a.source == .transcript ? 0 : 1, a.hitAt) }
            if let held = first[anchor.resetsAt], rank(held) <= rank(anchor) { continue }
            first[anchor.resetsAt] = anchor
        }
        for (resetsAt, anchor) in first {
            candidates.append(.init(after: resetsAt, by: resetsAt, recordedAt: anchor.hitAt, isExact: true,
                                    isCached: anchor.source == .cachedUsage))
        }
        return Evidence(candidates: candidates, outOfOrderSamples: outOfOrder)
    }

    // MARK: Inference

    /// The schedule, or `nil` while no reset has been observed (and no recent anchor exists).
    public static func infer(samples: [UsageSample], anchors: [LimitAnchor] = [], now: Date) -> WeeklySchedule? {
        infer(from: evidence(samples: samples, anchors: anchors, now: now), now: now)
    }

    public static func infer(from evidence: Evidence, now: Date) -> WeeklySchedule? {
        let candidates = evidence.candidates
        guard !candidates.isEmpty else { return nil }
        let arcs = candidates.map { Arc(start: wrap($0.after.timeIntervalSince1970), width: $0.width) }

        // Narrowest first; the rest only makes the order total, so the input order never matters.
        let order = candidates.indices.sorted { a, b in
            let x = candidates[a], y = candidates[b]
            if x.width != y.width { return x.width < y.width }
            if x.isExact != y.isExact { return x.isExact }
            if x.recordedAt != y.recordedAt { return x.recordedAt > y.recordedAt }
            if x.after != y.after { return x.after < y.after }
            return x.by < y.by
        }
        var clusters: [Cluster] = []
        for index in order {
            if let joined = clusters.firstIndex(where: { intersection($0.arc, arcs[index]) != nil }) {
                clusters[joined].arc = intersection(clusters[joined].arc, arcs[index])!
                clusters[joined].members.append(index)
            } else {
                clusters.append(Cluster(arc: arcs[index], members: [index]))
            }
        }

        func weight(_ index: Int) -> Double {
            let candidate = candidates[index]
            let weeks = now.timeIntervalSince(candidate.recordedAt) / period
            let recency = 1 / max(1, weeks)
            let width = candidate.width > 0 ? min(1, fullWeightWidth / candidate.width) : 1
            return recency * width
        }
        func newest(_ indices: [Int]) -> Int? {
            indices.max { (candidates[$0].recordedAt, candidates[$0].isExact ? 1 : 0) < (candidates[$1].recordedAt, candidates[$1].isExact ? 1 : 0) }
        }

        var arc: Arc
        var source: Source
        let exact = candidates.indices.filter { candidates[$0].isExact }
        let newestExact = newest(exact)
        /// Seen exactly, or in two or more sample brackets that each pin the weekday. A bracket
        /// a day wide or more sees every phase it spans; it is no sighting of this one.
        func isEstablished(_ cluster: Cluster) -> Bool {
            cluster.members.contains { candidates[$0].isExact }
                || cluster.members.filter { !candidates[$0].isExact && candidates[$0].isSighting }.count >= 2
        }

        if let newestExact {
            // A recent exact anchor decides; the newest one sets the phase.
            let cluster = clusters.first { $0.members.contains(newestExact) }!
            arc = Arc(start: arcs[newestExact].start, width: 0)
            source = .exact(anchors: cluster.members.filter { candidates[$0].isExact }.count,
                            lastHitAt: candidates[newestExact].recordedAt,
                            recordedBy: candidates[newestExact].isCached ? .cachedUsage : .transcript)
        } else {
            // An established phase first, then the vote, then the newest evidence.
            let supports = clusters.map { $0.members.reduce(0) { $0 + weight($1) } }
            let standing = clusters.map(isEstablished)
            let pool = standing.contains(true) ? clusters.indices.filter { standing[$0] } : Array(clusters.indices)
            let best = pool.map { supports[$0] }.max()!
            let tied = pool.filter { best - supports[$0] <= 1e-9 * max(1, best) }
            let chosen = tied.max { a, b in
                candidates[newest(clusters[a].members)!].recordedAt < candidates[newest(clusters[b].members)!].recordedAt
            }!
            arc = clusters[chosen].arc
            source = .bracketed(support: supports[chosen], newestAt: candidates[newest(clusters[chosen].members)!].recordedAt)
        }

        // Rule (b): the two newest sample brackets both disagree with the schedule and agree
        // with each other — two weeks in a row on a new phase. Against an exact schedule they
        // must both be newer than its newest anchor, or the anchor has already confirmed it.
        let brackets = candidates.indices.filter { !candidates[$0].isExact }.sorted {
            (candidates[$0].recordedAt, candidates[$0].after) > (candidates[$1].recordedAt, candidates[$1].after)
        }
        if brackets.count >= 2 {
            let n1 = brackets[0], n2 = brackets[1]
            let afterAnchors = newestExact.map { candidates[n2].recordedAt > candidates[$0].recordedAt } ?? true
            if afterAnchors,
               intersection(arc, arcs[n1]) == nil, intersection(arc, arcs[n2]) == nil,
               let both = intersection(arcs[n1], arcs[n2]) {
                arc = both
                source = .bracketed(support: weight(n1) + weight(n2), newestAt: candidates[n1].recordedAt)
            }
        }

        // The newest observed reset, if it disagrees, is reported and not adopted.
        var unconfirmed: TimeInterval?
        if let latest = newest(Array(candidates.indices)), intersection(arc, arcs[latest]) == nil {
            unconfirmed = arcs[latest].middle
        }
        let agreeing = candidates.indices.filter { intersection(arc, arcs[$0]) != nil }
        let confirmedAt = agreeing.map { candidates[$0].recordedAt }.max() ?? candidates[newest(Array(candidates.indices))!].recordedAt

        // A plan change: another established phase was seen, and this one overtook it as step 4
        // allows — by a newer exact anchor, or by two sightings since that one's last (rule (b)).
        // The first sighting of this phase after the last of that one is where it begins. A
        // phase only ever "seen" by a wide bracket was never established, so it is overtaken by
        // nothing.
        var reanchoredAt: Date?
        let superseded = clusters.filter { isEstablished($0) && intersection(arc, $0.arc) == nil }
            .flatMap(\.members).filter { candidates[$0].isSighting }.map { candidates[$0].recordedAt }.max()
        if let superseded {
            let since = agreeing.filter { candidates[$0].isSighting && candidates[$0].recordedAt > superseded }
            if since.contains(where: { candidates[$0].isExact }) || since.count >= 2 {
                reanchoredAt = since.map { candidates[$0].recordedAt }.min()
            }
        }

        return WeeklySchedule(
            phase: arc.middle, halfWidth: arc.width / 2, source: source, unconfirmedPhase: unconfirmed,
            confirmedAt: confirmedAt, reanchoredAt: reanchoredAt, outOfOrderSamples: evidence.outOfOrderSamples)
    }

    // MARK: The circle

    static func wrap(_ seconds: TimeInterval) -> TimeInterval {
        let r = seconds.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }

    /// An interval on the one-week circle: `[start, start + width]`, `start` in `[0, period)`.
    struct Arc: Equatable {
        var start: TimeInterval
        var width: TimeInterval
        var middle: TimeInterval { WeeklySchedule.wrap(start + width / 2) }
    }

    private struct Cluster {
        var arc: Arc
        var members: [Int]
    }

    /// Where two arcs overlap, allowing ``slack``; `nil` when they do not. Two arcs that only
    /// touch within the slack meet at the middle of the gap, with width zero.
    static func intersection(_ x: Arc, _ y: Arc) -> Arc? {
        let d = wrap(y.start - x.start)
        var best: Arc?
        // `y` starts inside `x`.
        if d <= x.width + slack {
            let low = d, high = min(x.width, d + y.width)
            best = low <= high ? Arc(start: wrap(x.start + low), width: high - low)
                : Arc(start: wrap(x.start + (low + x.width) / 2), width: 0)
        }
        // `x` starts inside `y`.
        let e = period - d
        if d > 0, e <= y.width + slack {
            let high = min(x.width, y.width - e)
            let arc = high >= 0 ? Arc(start: x.start, width: high) : Arc(start: wrap(x.start + high / 2), width: 0)
            if best == nil || arc.width > best!.width { best = arc }
        }
        return best
    }
}
