import Foundation

/// Where to start a session of one size, and why.
public struct Advice: Equatable, Sendable {

    public indirect enum Reason: Equatable, Sendable {
        /// Budget that would go unused at this account's reset (`points` of it, est.).
        case useItOrLoseIt(points: Int, resetBy: Date)
        /// Every account will run out; this one resets first.
        case resetsSoonest(resetBy: Date)
        case mostHeadroom(points: Int)
        /// For medium and long when every account will run out: `other` has a thin margin.
        case comfortableMargin(other: String, otherLeft: Int)
        case onlyFit
        /// The account that ranked first, `other`, would have been left with no reserve.
        case keepsReserve(other: String)
        /// Recorded usage, but no weekly reset seen yet.
        case resetUnknown
        /// No history at all (defaults).
        case noUsageRecorded
        /// Kept from an earlier advice: nothing changed enough to switch.
        case unchanged(since: Date, original: Reason)
    }

    /// When nothing fits, what is in the way.
    public enum Blocker: Equatable, Sendable {
        case weeklyLimit
        case window
        case reserve
        case blocked(String)
        case notEnoughData
    }

    /// The earliest moment something may fit again.
    public struct NextChance: Equatable, Sendable {
        public enum Event: Equatable, Sendable {
            case weeklyReset
            case windowClears
            case limitEnds(String)
        }

        public let at: Date
        public let profileID: String
        public let event: Event
        /// The time was recorded: a window end or limit hit Claude Code recorded, an exact and
        /// fresh weekly schedule. Otherwise it is an estimate and says so.
        public let exact: Bool

        public init(at: Date, profileID: String, event: Event, exact: Bool) {
            self.at = at
            self.profileID = profileID
            self.event = event
            self.exact = exact
        }
    }

    public enum Outcome: Equatable, Sendable {
        case start(profileID: String, reason: Reason, afterWindowClearsAt: Date?, stallsAbout: Date?)
        /// It fits only where it would leave no account in reserve (short sessions only).
        case lastHeadroom(profileID: String)
        case nothingFits(next: NextChance?, why: Blocker)
    }

    /// One clause on each account not chosen.
    public enum Why: Equatable, Sendable {
        case fits(left: Int)
        case projectedToRunOut
        case fitsFirstThreeHoursOnly(left: Int)
        case cannotFit(left: Int)
        /// The five-hour window has too little room for the session (`roomLeft` points of it,
        /// cautious, est.; 0 when full) until it clears — at a recorded time when `exact`.
        case windowFull(until: Date?, roomLeft: Int, exact: Bool)
        case noReserve
        case blocked(reason: String, until: Date)
        case committed(points: Int)
        case notEnoughData
        case noUsageRecorded
        /// `~/.claude.json` names a plan other than the Max 20x the defaults were measured on.
        case otherPlan(String)
        /// The scale gate found the account spending its limit several times faster than its
        /// calibration said (a smaller plan, A5): short sessions only until it recalibrates.
        case recalibrating
    }

    public struct Alternative: Equatable, Sendable {
        public let profileID: String
        public let why: Why
    }

    public let size: SessionSize
    public let outcome: Outcome
    public let alternatives: [Alternative]
    public let basis: Basis
    /// When this advice was made.
    public let at: Date

    /// The account to start in, when there is one.
    public var profileID: String? {
        switch outcome {
        case .start(let id, _, _, _), .lastHeadroom(let id): return id
        case .nothingFits: return nil
        }
    }

    public var nextChanceAt: Date? {
        if case .nothingFits(let next, _) = outcome { return next?.at }
        return nil
    }
}

/// Picks the account for a short, medium or long session.
///
/// The owner's four goals, in the order they bind: never recommend an account the session
/// cannot fit (p75 cost against the cautious headroom); always keep one account with usage
/// available (the reserve); use the accounts fully (budget that would be lost at a reset
/// first); and be stable (keep an earlier choice unless another is clearly better).
public enum UsageAdvisor {

    public static let tieWaste = 5
    public static let tieReset: TimeInterval = 6 * 3600
    public static let tieRoom = 10.0
    public static let beatBy = 10
    public static let clearSoon: TimeInterval = 15 * 60
    public static let reserveClear: TimeInterval = 3600
    /// Points of headroom an earlier choice may be short of a fit and still be kept.
    public static let keepFitting = 1.0
    /// A scale-gate trip at this recorded / predicted ratio or more holds medium and long back
    /// (A5). The smallest step between plans is 4×; use this Mac cannot see tripped the gate at
    /// about 2.4× on Sep 21, and a Max 20x account's defaults then still fit.
    public static let recalibratingRatio = 3.0
    /// Points are products of floating-point factors; a value that equals its bound is inside it.
    static let epsilon = 1e-9

    /// One account as the advisor sees it for one size.
    struct Candidate {
        let id: String
        let forecast: UsageForecast
        let points: SessionCostsPoints
        let order: Int
        let running: Bool
        /// Headroom it may spend: the cautious headroom less what busy sessions will still take.
        let spendable: Double
        /// Five-hour room, as cautiously: the window's upper bound less what busy sessions will
        /// still take in it.
        let room: Double
        var waste: Int? { forecast.waste }
        var end: Date? { forecast.weekEnd }
        var clearsAt: Date? { forecast.windowClearsAt }

        var weekFits = false
        var windowFitsNow = false
        var waitsForWindow = false
        /// Why this size is not offered here at all, whatever the numbers.
        var restriction: Advice.Why?
        /// Stale or insufficient: short only when nothing else fits.
        var lastResort = false
        var reserveHolds = false

        init(id: String, forecast: UsageForecast, points: SessionCostsPoints, order: Int, running: Bool) {
            self.id = id
            self.forecast = forecast
            self.points = points
            self.order = order
            self.running = running
            spendable = forecast.headroom.low - forecast.committedWeek
            room = 100 - forecast.windowUsed.high - forecast.committedWindow
        }

        var fits: Bool { restriction == nil && weekFits && (windowFitsNow || waitsForWindow) }
        var eligible: Bool { fits && reserveHolds }

        var tier: Int {
            guard let waste else { return 1 }
            return waste >= UsageAdvisor.tieWaste ? 0 : 2
        }

        func isComfortable(for size: SessionSize) -> Bool { spendable + UsageAdvisor.epsilon >= 2 * points[size].fitWeek.p75 }
    }

    public static func advise(size: SessionSize, forecasts: [String: UsageForecast], costs: SessionCosts, order: [String],
                              previous: Advice?, running: Set<String> = [], now: Date) -> Advice {
        let ids = order.filter { forecasts[$0] != nil } + forecasts.keys.filter { !order.contains($0) }.sorted()
        var all = ids.enumerated().map { index, id in
            let forecast = forecasts[id]!
            return Candidate(id: id, forecast: forecast, points: costs.points(for: forecast.calibration), order: index,
                             running: running.contains(id))
        }

        // The account an earlier advice for this size chose, if any.
        var earlierChoice: String?
        if let previous, previous.size == size, case .start(let id, _, _, _) = previous.outcome { earlierChoice = id }

        // 1. Fit. The earlier choice keeps fitting through a wobble of under a point in its
        // headroom (stability, goal 4): estimates move by fractions of a point between reads.
        for index in all.indices {
            var c = all[index]
            let need = c.points[size]
            let hysteresis = c.id == earlierChoice ? keepFitting : 0
            c.weekFits = c.spendable + hysteresis + epsilon >= need.fitWeek.p75
            c.windowFitsNow = c.room + epsilon >= need.fitWindow.p75
            if !c.windowFitsNow, size != .short, let clears = c.clearsAt, clears.timeIntervalSince(now) <= clearSoon {
                c.waitsForWindow = true
            }
            let f = c.forecast
            switch f.weekUsed.basis {
            case .defaults:
                if size == .short { c.weekFits = true } else { c.restriction = .noUsageRecorded }
            case .insufficient:
                if size == .short { c.lastResort = true } else { c.restriction = .notEnoughData }
            default:
                if f.stale {
                    if size == .short { c.lastResort = true } else { c.restriction = .notEnoughData }
                }
            }
            if size != .short, c.restriction == nil {
                let calibration = f.calibration
                if let until = f.blockedUntil, until > now {
                    c.restriction = .blocked(reason: f.blockReason ?? "a weekly limit", until: until)
                } else if calibration.flag != nil, calibration.weeklyIsDefault, f.plan != .max20x {
                    // A5: the calibration was dropped for a plan change and the defaults are a
                    // Max 20x account's, several times too small on a smaller plan — only short
                    // sessions until the account's own segments calibrate. A plan the CLI names
                    // says so itself; an unnamed one (the second account's, usually) is held back
                    // only when the trip said "several times faster" (≥ 3×): use this Mac cannot
                    // see trips the gate at about 2.4×, and its defaults then fit. On Max 20x the
                    // defaults cannot be too small, so nothing is held back.
                    if case .named(let tier) = f.plan {
                        c.restriction = calibration.tripRatio == nil ? .otherPlan(tier) : .recalibrating
                    } else if let ratio = calibration.tripRatio, ratio >= recalibratingRatio {
                        c.restriction = .recalibrating
                    }
                }
                if c.restriction == nil, case .named(let tier) = f.plan, calibration.weeklyIsDefault {
                    // A5: the defaults are a Max 20x account's; on another plan a session's
                    // points are several times larger, so only short sessions until its own
                    // history calibrates.
                    c.restriction = .otherPlan(tier)
                }
            }
            all[index] = c
        }

        // 2. Reserve: after this session, some account still has two short sessions' worth.
        func isReserve(_ b: Candidate) -> Bool {
            guard b.spendable + epsilon >= b.points.reserve else { return false }
            if b.room + epsilon >= b.points.short.fitWindow.p75 { return true }
            return b.clearsAt.map { $0.timeIntervalSince(now) <= reserveClear } ?? false
        }
        for index in all.indices {
            let a = all[index]
            let others = all.contains { $0.id != a.id && isReserve($0) }
            all[index].reserveHolds = others || a.spendable - a.points[size].fitWeek.p75 + epsilon >= a.points.reserve
        }

        // 3. Eligible.
        var eligible = all.filter { $0.eligible && !$0.lastResort }
        if eligible.isEmpty, size == .short { eligible = all.filter { $0.eligible } }

        let alternativesFor: (String?) -> [Advice.Alternative] = { chosen in
            all.filter { $0.id != chosen }.map { Advice.Alternative(profileID: $0.id, why: why(for: $0, size: size, now: now)) }
        }

        guard !eligible.isEmpty else {
            if size == .short, let last = all.filter(\.fits).max(by: { ($0.spendable, -$0.order) < ($1.spendable, -$1.order) }) {
                return Advice(size: size, outcome: .lastHeadroom(profileID: last.id), alternatives: alternativesFor(last.id),
                              basis: last.forecast.weekUsed.basis, at: now)
            }
            let next = nextChance(all, size: size, now: now)
            let blocker = primaryBlocker(all.first { $0.id == next?.profileID } ?? all.first, size: size)
            return Advice(size: size, outcome: .nothingFits(next: next, why: blocker), alternatives: alternativesFor(nil),
                          basis: (all.first { $0.id == next?.profileID } ?? all.first)?.forecast.weekUsed.basis ?? .defaults, at: now)
        }

        // 4. Rank.
        let ranked = rank(eligible, size: size)
        var chosen = ranked.winner
        var reason = ranked.reason

        // The account that would rank first if the reserve did not matter.
        let lastResorts = eligible.contains(where: \.lastResort)
        let unreserved = rank(all.filter { $0.fits && (lastResorts || !$0.lastResort) }, size: size)
        if unreserved.winner.id != chosen.id, !unreserved.winner.reserveHolds {
            reason = .keepsReserve(other: unreserved.winner.id)
        } else if eligible.count == 1, all.count > 1 {
            reason = .onlyFit
        }
        switch chosen.forecast.weekUsed.basis {
        case .recordedNoSchedule: reason = .resetUnknown
        case .defaults: reason = .noUsageRecorded
        default: break
        }

        // 5. Stability: keep an earlier choice that is still eligible unless the new one is
        // clearly better, the earlier one's window no longer fits while the new one's does, or a
        // weekly reset has passed on either since. "Clearly better" is budget it would save from
        // going unused: a margin in saved budget means something only where there is budget to
        // save, so an account that will run out scores 0 however far short it falls (design
        // §5.5 amended — with waste itself as the score, two accounts that both run out flipped
        // back and forth on the difference between their shortfalls).
        if let previous, previous.size == size, case .start(let earlierID, let earlierReason, _, _) = previous.outcome,
           earlierID != chosen.id, let earlier = eligible.first(where: { $0.id == earlierID }) {
            func score(_ c: Candidate) -> Int { max(c.waste ?? 0, 0) }
            let beats = score(chosen) - score(earlier) >= beatBy
            let windowMoved = earlier.waitsForWindow && !chosen.waitsForWindow
            let reset = [earlier, chosen].contains { $0.forecast.schedule?.hasCertainlyReset(since: previous.at, now: now) ?? false }
            if !(beats || windowMoved || reset) {
                chosen = earlier
                if case .unchanged(let since, let original) = earlierReason {
                    reason = .unchanged(since: since, original: original)
                } else {
                    reason = .unchanged(since: previous.at, original: earlierReason)
                }
            }
        }

        // 7. A long session that will likely stall part-way: when, at the faster of its pace and
        // a typical long session's.
        var stallsAbout: Date?
        if size == .long, chosen.spendable < chosen.points.long.whole.p75 {
            let rate = max(chosen.forecast.pace ?? 0, chosen.points.long.whole.p50 / 3)
            if rate > 0 { stallsAbout = now.addingTimeInterval(max(0, chosen.spendable) / rate * 3600) }
        }

        return Advice(
            size: size,
            outcome: .start(profileID: chosen.id, reason: reason, afterWindowClearsAt: chosen.waitsForWindow ? chosen.clearsAt : nil,
                            stallsAbout: stallsAbout),
            alternatives: alternativesFor(chosen.id), basis: chosen.forecast.weekUsed.basis, at: now)
    }

    // MARK: Ranking

    /// Lexicographic, each step keeping the candidates within its tie margin of the best:
    /// tier (budget that would go unused › unknown › will run out), ready now › must wait, then
    /// within the tier more waste / more headroom / (medium and long) a comfortable margin
    /// first and then the sooner reset, then more window room, a running account, config order.
    /// The reason is the last step that set the winner apart.
    static func rank(_ candidates: [Candidate], size: SessionSize) -> (winner: Candidate, reason: Advice.Reason) {
        var pool = candidates.sorted { $0.order < $1.order }
        var decisive: (step: Step, beaten: [Candidate])?

        func narrow(_ step: Step, _ keep: ([Candidate]) -> [Candidate]) {
            guard pool.count > 1 else { return }
            let kept = keep(pool)
            guard !kept.isEmpty else { return }
            if kept.count < pool.count {
                decisive = (step, pool.filter { c in !kept.contains { $0.id == c.id } })
            }
            pool = kept
        }
        func within(_ key: @escaping (Candidate) -> Double, _ margin: Double) -> ([Candidate]) -> [Candidate] {
            { pool in
                let best = pool.map(key).max()!
                return pool.filter { best - key($0) <= margin }
            }
        }

        narrow(.tier) { pool in let best = pool.map(\.tier).min()!; return pool.filter { $0.tier == best } }
        narrow(.readiness) { pool in pool.contains { !$0.waitsForWindow } ? pool.filter { !$0.waitsForWindow } : pool }
        switch pool.first!.tier {
        case 0: narrow(.waste, within({ Double($0.waste ?? 0) }, Double(tieWaste)))
        case 1: narrow(.headroom, within(\.spendable, tieRoom))
        default:
            if size != .short {
                narrow(.comfortable) { pool in
                    pool.contains { $0.isComfortable(for: size) } ? pool.filter { $0.isComfortable(for: size) } : pool
                }
            }
            narrow(.reset) { pool in
                let ends = pool.compactMap(\.end)
                guard let soonest = ends.min() else { return pool }
                return pool.filter { $0.end.map { $0.timeIntervalSince(soonest) <= tieReset } ?? false }
            }
        }
        narrow(.room, within(\.room, tieRoom))
        narrow(.running) { pool in pool.contains(where: \.running) ? pool.filter(\.running) : pool }
        narrow(.order) { pool in [pool.min { $0.order < $1.order }!] }

        let winner = pool[0]
        let fallback: Advice.Reason
        switch winner.tier {
        case 0: fallback = .useItOrLoseIt(points: winner.waste ?? 0, resetBy: winner.end ?? .distantFuture)
        case 1: fallback = .mostHeadroom(points: Int(winner.spendable.rounded(.down)))
        default: fallback = winner.end.map { .resetsSoonest(resetBy: $0) } ?? .mostHeadroom(points: Int(winner.spendable.rounded(.down)))
        }
        guard let decisive else { return (winner, fallback) }
        switch decisive.step {
        case .comfortable:
            let thinnest = decisive.beaten.min { $0.spendable < $1.spendable }!
            return (winner, .comfortableMargin(other: thinnest.id, otherLeft: Int(max(0, thinnest.spendable).rounded(.down))))
        case .reset:
            return (winner, winner.end.map { .resetsSoonest(resetBy: $0) } ?? fallback)
        case .waste:
            return (winner, fallback)
        case .headroom:
            return (winner, .mostHeadroom(points: Int(winner.spendable.rounded(.down))))
        case .tier, .readiness, .room, .running, .order:
            return (winner, fallback)
        }
    }

    enum Step {
        case tier, readiness, waste, headroom, comfortable, reset, room, running, order
    }

    // MARK: Explaining

    static func why(for c: Candidate, size: SessionSize, now: Date) -> Advice.Why {
        let left = Int(max(0, c.spendable).rounded(.down))
        if let restriction = c.restriction { return restriction }
        if !c.weekFits {
            if c.forecast.committedWeek > 0, c.spendable + c.forecast.committedWeek + epsilon >= c.points[size].fitWeek.p75 {
                return .committed(points: Int(c.forecast.committedWeek.rounded()))
            }
            return .cannotFit(left: left)
        }
        let windowFull = Advice.Why.windowFull(until: c.clearsAt, roomLeft: Int(max(0, c.room).rounded(.down)),
                                               exact: c.forecast.windowExact)
        if !(c.windowFitsNow || c.waitsForWindow) { return windowFull }
        if c.lastResort { return .notEnoughData }
        if !c.reserveHolds { return .noReserve }
        if c.waitsForWindow { return windowFull }
        if size == .long, c.spendable < c.points.long.whole.p75 { return .fitsFirstThreeHoursOnly(left: left) }
        if let waste = c.waste, waste < 0 { return .projectedToRunOut }
        return .fits(left: left)
    }

    /// Per account, when everything in its way has lifted; the earliest across accounts.
    static func nextChance(_ all: [Candidate], size: SessionSize, now: Date) -> Advice.NextChance? {
        var best: Advice.NextChance?
        for c in all {
            // When, what, and whether that time was recorded.
            var lifts: [(Date, Advice.NextChance.Event, Bool)] = []
            switch c.restriction {
            case .blocked(let reason, let until): lifts.append((until, .limitEnds(reason), true))
            case .some: continue
            case nil: break
            }
            if !c.weekFits {
                guard let end = c.end else { continue }
                lifts.append((end, .weeklyReset, c.forecast.schedule?.isFresh(now: now) ?? false))
            }
            if !(c.windowFitsNow || c.waitsForWindow) {
                guard let clears = c.clearsAt else { continue }
                lifts.append((clears, .windowClears, c.forecast.windowExact))
            }
            guard let last = lifts.max(by: { $0.0 < $1.0 }), last.0 > now else { continue }
            if best == nil || last.0 < best!.at {
                best = Advice.NextChance(at: last.0, profileID: c.id, event: last.1, exact: last.2)
            }
        }
        return best
    }

    static func primaryBlocker(_ c: Candidate?, size: SessionSize) -> Advice.Blocker {
        guard let c else { return .notEnoughData }
        switch c.restriction {
        case .blocked(let reason, _): return .blocked(reason)
        case .some: return .notEnoughData
        case nil: break
        }
        if !c.weekFits { return .weeklyLimit }
        if !(c.windowFitsNow || c.waitsForWindow) { return .window }
        if c.lastResort { return .notEnoughData }
        return .reserve
    }
}
