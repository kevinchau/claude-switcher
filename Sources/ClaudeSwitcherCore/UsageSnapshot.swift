import Foundation

/// Every account's forecast and the Advisor's three answers, at one moment: the one façade the
/// menu, Diagnostics and `--dry-run` read usage through.
///
/// Cheap: the sample files are small, the ledgers come in already built (the index is refreshed
/// off the main thread), and the Advisor compares a handful of accounts. While the activity index
/// is being built there is no advice and nothing is estimated from activity: a samples-only pick
/// would send a long session to an account whose only sample this week reads 0 % after it has
/// spent most of its week. Activity is known only through the index's last read: an index more
/// than an hour old (a stored one `--dry-run` reads) is treated the same way, and within the
/// hour the cautious bounds allow for the spend not read yet.
public struct UsageSnapshot: Sendable {
    public let forecasts: [String: UsageForecast]
    public let costs: SessionCosts
    public let advice: [SessionSize: Advice]
    public let indexState: ActivityIndexState
    /// Profile ids in config order.
    public let order: [String]

    /// Activity is known only through the index's last read. Older than this, the spend since is
    /// too much to allow for: the snapshot is made as while building (``ActivityIndexState/stale(indexedThrough:)``).
    public static let maximumUnread: TimeInterval = 3600

    /// From values already read.
    public static func make(
        profiles: [Profile], samples: [String: [UsageSample]], exact: [String: ExactUsage], activity: [String: ActivityLedger]?,
        indexState: ActivityIndexState, previous: [SessionSize: Advice], busy: [String: [BusySession]],
        running: Set<String> = [], now: Date
    ) -> UsageSnapshot {
        var state = indexState
        var ready = false
        var indexedThrough = now
        if case .ready(let through) = indexState, activity != nil {
            if now.timeIntervalSince(through) > maximumUnread {
                state = .stale(indexedThrough: through)
            } else {
                ready = true
                indexedThrough = through
            }
        }
        let ledgers: [String: ActivityLedger] = ready
            ? Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, activity?[$0.id] ?? .empty(indexedThrough: indexedThrough)) })
            : [:]
        let costs = ready ? SessionCosts.calibrate(from: profiles.compactMap { ledgers[$0.id] }, now: now) : .defaults
        var forecasts: [String: UsageForecast] = [:]
        for profile in profiles {
            let forecast = UsageForecast.make(
                profileID: profile.id, samples: samples[profile.id] ?? [], activity: ledgers[profile.id], exact: exact[profile.id],
                busySessions: ready ? busy[profile.id] ?? [] : [], costs: costs, now: now)
            // Spend since the index's last read counts as nothing in the estimate; the cautious
            // bounds allow for it at the account's fastest recent hour.
            forecasts[profile.id] = ledgers[profile.id].map { forecast.widened(unread: now.timeIntervalSince(indexedThrough), activity: $0) }
                ?? forecast
        }
        var advice: [SessionSize: Advice] = [:]
        if ready, !profiles.isEmpty {
            for size in SessionSize.allCases {
                advice[size] = UsageAdvisor.advise(size: size, forecasts: forecasts, costs: costs, order: profiles.map(\.id),
                                                   previous: previous[size], running: running, now: now)
            }
        }
        return UsageSnapshot(forecasts: forecasts, costs: costs, advice: advice, indexState: state, order: profiles.map(\.id))
    }

    /// Reads every profile's samples and the exact source, and makes the snapshot. Only reads.
    public static func read(
        profiles: [Profile], home: String, activity: [String: ActivityLedger]?, indexState: ActivityIndexState,
        previous: [SessionSize: Advice], busy: [String: [BusySession]], running: Set<String> = [], now: Date,
        exactSource: any ExactUsageSource = ClaudeConfigUsageSource()
    ) -> UsageSnapshot {
        var samples: [String: [UsageSample]] = [:]
        var exact: [String: ExactUsage] = [:]
        for profile in profiles {
            samples[profile.id] = UsageHistory.read(userDataDir: profile.userDataDir, home: home) ?? []
            exact[profile.id] = exactSource.exact(for: profile, home: home, now: now)
        }
        return make(profiles: profiles, samples: samples, exact: exact, activity: activity, indexState: indexState,
                    previous: previous, busy: busy, running: running, now: now)
    }
}
