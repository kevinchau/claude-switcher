import Foundation

/// How long a session is going to be, in terms the user picks from (A10): by duration only. An
/// episode in which subagents made at least half the spend is a workflow run and counts as long,
/// as the row's title says.
public enum SessionSize: String, CaseIterable, Sendable {
    case short
    case medium
    case long

    static let shortUnder: TimeInterval = 3600
    static let longOver: TimeInterval = 3 * 3600
    static let workflowShare = 0.5

    /// Under an hour is short, one to three hours (both included) medium, over three hours long.
    public static func of(duration: TimeInterval, subagentShare: Double) -> SessionSize {
        if duration > longOver || subagentShare >= workflowShare { return .long }
        return duration < shortUnder ? .short : .medium
    }

    /// The row's title.
    public var title: String {
        switch self {
        case .short: return "Short \u{2014} under an hour"
        case .medium: return "Medium \u{2014} 1 to 3 hours"
        case .long: return "Long \u{2014} over 3 hours or a workflow run"
        }
    }
}

/// What a session of each size costs, in **spend units** (weighted tokens, A4): converted to
/// points with the target account's own calibration at the moment of the fit, so two accounts on
/// different plans each get their own percentages.
///
/// A size is calibrated from this Mac's own episodes of the last 30 days — pooled across accounts,
/// which is why spend units and not points — once it has eight of them; until then it is the
/// default measured on this Mac's two Max 20x accounts (A5, A15). A long session is fitted on its
/// first three hours (week) and its first hour (window); its whole cost says whether it will
/// likely stall.
public struct SessionCosts: Equatable, Sendable {

    public struct Quantiles: Equatable, Sendable {
        public let p50: Double
        public let p75: Double

        public init(p50: Double, p75: Double) {
            self.p50 = p50
            self.p75 = p75
        }

        func scaled(_ factor: Double) -> Quantiles { Quantiles(p50: p50 * factor, p75: p75 * factor) }
    }

    public struct Cost: Equatable, Sendable {
        /// The whole session.
        public let whole: Quantiles
        /// The stretch the weekly fit uses: the whole session, a long one's first three hours.
        public let fitWeek: Quantiles
        /// The stretch the five-hour fit uses: the whole session, a long one's first hour.
        public let fitWindow: Quantiles
        /// The episodes behind it; 0 for the defaults.
        public let episodes: Int

        public init(whole: Quantiles, fitWeek: Quantiles, fitWindow: Quantiles, episodes: Int) {
            self.whole = whole
            self.fitWeek = fitWeek
            self.fitWindow = fitWindow
            self.episodes = episodes
        }

        public var isDefault: Bool { episodes == 0 }
    }

    public static let minimumEpisodes = 8
    public static let lookback: TimeInterval = 30 * 86400

    public let short: Cost
    public let medium: Cost
    public let long: Cost

    public init(short: Cost, medium: Cost, long: Cost) {
        self.short = short
        self.medium = medium
        self.long = long
    }

    public subscript(size: SessionSize) -> Cost {
        switch size {
        case .short: return short
        case .medium: return medium
        case .long: return long
        }
    }

    /// The defaults (A15), in spend units, p50 / p75, re-derived from this Mac's own episodes of
    /// the 30 days to Oct 6, 2026 under these sizes (132 finished episodes: 49 short, 14 medium,
    /// 69 long; two Max 20x accounts). As points at the default calibration: short 0.4 / 1.0 of
    /// the week and 1.8 / 4.2 of a window; medium 2.1 / 3.1 and 8.5 / 12.7; long 6.7 / 12.6
    /// whole, 5.5 / 8.0 in its first three hours, and 12.7 / 21.2 of a window in its first hour.
    /// The research's earlier figures (short 1 / 2, medium 3 / 5, long 15 / 30) were cut by
    /// duration alone; here a workflow run counts as long whatever its length, which moves the
    /// subagent-heavy hour-or-two sessions out of medium.
    public static let defaults: SessionCosts = {
        func q(_ p50: Double, _ p75: Double) -> Quantiles { Quantiles(p50: p50, p75: p75) }
        return SessionCosts(
            short: Cost(whole: q(6, 14), fitWeek: q(6, 14), fitWindow: q(6, 14), episodes: 0),
            medium: Cost(whole: q(28, 42), fitWeek: q(28, 42), fitWindow: q(28, 42), episodes: 0),
            long: Cost(whole: q(90, 170), fitWeek: q(74, 108), fitWindow: q(42, 70), episodes: 0))
    }()

    /// The finished episodes of the last 30 days, sized. An episode still running (activity in
    /// the last half hour) or with no spend at all (prompts only) is left out.
    public static func episodes(from ledgers: [ActivityLedger], now: Date) -> [(size: SessionSize, episode: ActivityLedger.Episode)] {
        var unique: [ActivityLedger] = []
        for ledger in ledgers where !unique.contains(ledger) { unique.append(ledger) }
        return unique.flatMap { $0.episodes(idleSplit: ActivityLedger.idleSplit) }
            .filter { $0.spend > 0 && now.timeIntervalSince($0.end) > ActivityLedger.idleSplit && now.timeIntervalSince($0.end) <= lookback }
            .map { (SessionSize.of(duration: $0.duration, subagentShare: $0.subagentShare), $0) }
    }

    /// This Mac's own costs where a size has eight episodes, the defaults elsewhere. Ledgers of
    /// two profiles on one account are the same ledger and count once.
    public static func calibrate(from ledgers: [ActivityLedger], now: Date) -> SessionCosts {
        let sized = episodes(from: ledgers, now: now)
        func cost(_ size: SessionSize) -> Cost {
            let mine = sized.filter { $0.size == size }.map(\.episode)
            guard mine.count >= minimumEpisodes else { return defaults[size] }
            let whole = quantiles(mine.map(\.spend))
            switch size {
            case .long:
                return Cost(whole: whole, fitWeek: quantiles(mine.map(\.firstThreeHoursSpend)),
                            fitWindow: quantiles(mine.map(\.firstHourSpend)), episodes: mine.count)
            case .short, .medium:
                return Cost(whole: whole, fitWeek: whole, fitWindow: whole, episodes: mine.count)
            }
        }
        return SessionCosts(short: cost(.short), medium: cost(.medium), long: cost(.long))
    }

    /// p50 and p75, interpolated between ranks.
    static func quantiles(_ values: [Double]) -> Quantiles {
        Quantiles(p50: quantile(values, 0.5), p75: quantile(values, 0.75))
    }

    static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let position = q * Double(sorted.count - 1)
        let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    /// The costs in one account's points.
    public func points(for calibration: Calibration) -> SessionCostsPoints {
        func convert(_ cost: Cost) -> SessionCostsPoints.Cost {
            SessionCostsPoints.Cost(whole: cost.whole.scaled(calibration.weekly), fitWeek: cost.fitWeek.scaled(calibration.weekly),
                                    fitWindow: cost.fitWindow.scaled(calibration.window), episodes: cost.episodes)
        }
        return SessionCostsPoints(short: convert(short), medium: convert(medium), long: convert(long))
    }
}

/// ``SessionCosts`` in one account's points: `whole` and `fitWeek` of its week, `fitWindow` of its
/// five-hour window.
public struct SessionCostsPoints: Equatable, Sendable {
    public typealias Cost = SessionCosts.Cost

    public let short: Cost
    public let medium: Cost
    public let long: Cost

    public subscript(size: SessionSize) -> Cost {
        switch size {
        case .short: return short
        case .medium: return medium
        case .long: return long
        }
    }

    /// The reserve one account must keep: two short sessions' p75 (about 2 points of a Max 20x
    /// week at the defaults).
    public var reserve: Double { 2 * short.fitWeek.p75 }
}
