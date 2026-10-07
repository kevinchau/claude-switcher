import Foundation

/// Exact usage figures for one account, when a local file happens to hold fresh ones.
///
/// Today's only source is `~/.claude.json`: after its own usage fetch the terminal CLI caches
/// the whole response under `cachedUsageUtilization {fetchedAtMs, accountUuid, utilization}`,
/// at most once a minute, and itself ignores it after an hour. It covers one account — the one
/// the CLI is signed in to — and is used only for the profile whose account it names, and only
/// within that hour. The plan tier (`oauthAccount.organizationRateLimitTier`) is read under the
/// same account match, whatever the cache's age. Read only; never written.
///
/// The usage response in Chromium's HTTP cache would give the same figures for every account
/// that is in use, the Fable-only weekly limit included; it is not read in this version (A11).
/// ``ExactUsageSource`` is where such a reader would plug in.
public struct ExactUsage: Equatable, Sendable {
    /// The CLI's own time-to-live for the cached body.
    public static let maximumAge: TimeInterval = 3600

    public let accountID: String
    /// E.g. `claude_max_20x`; `nil` when not recorded for this account.
    public let rateLimitTier: String?
    /// When the cached body was fetched, if it is fresh; every figure below is `nil` otherwise.
    public let fetchedAt: Date?
    public let fiveHourUtilization: Int?
    /// `nil` when no five-hour window is open (the API sends `null` at 0 %).
    public let fiveHourResetsAt: Date?
    public let sevenDayUtilization: Int?
    public let sevenDayResetsAt: Date?

    public init(accountID: String, rateLimitTier: String?, fetchedAt: Date?, fiveHourUtilization: Int? = nil,
                fiveHourResetsAt: Date? = nil, sevenDayUtilization: Int? = nil, sevenDayResetsAt: Date? = nil) {
        self.accountID = accountID
        self.rateLimitTier = rateLimitTier
        self.fetchedAt = fetchedAt
        self.fiveHourUtilization = fiveHourUtilization
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayUtilization = sevenDayUtilization
        self.sevenDayResetsAt = sevenDayResetsAt
    }

    /// The exact reset times as anchors, recorded at the fetch: a `seven_day` one anchors the
    /// weekly schedule like a limit hit's would; a `five_hour` one is the open window's end.
    /// They say who reported them (``LimitAnchor/Source/cachedUsage``): no limit was hit.
    public var anchors: [LimitAnchor] {
        guard let fetchedAt else { return [] }
        var anchors: [LimitAnchor] = []
        if let sevenDayResetsAt { anchors.append(LimitAnchor(resetsAt: sevenDayResetsAt, kind: .sevenDay, hitAt: fetchedAt, source: .cachedUsage)) }
        if let fiveHourResetsAt { anchors.append(LimitAnchor(resetsAt: fiveHourResetsAt, kind: .fiveHour, hitAt: fetchedAt, source: .cachedUsage)) }
        return anchors
    }

    /// The account the terminal CLI is signed in to and the plan tier it names for it, from
    /// `~/.claude.json`'s `oauthAccount` — whatever the cached body's age. `nil` when either is
    /// missing. The activity index remembers it per account (A5).
    public static func signedInTier(_ data: Data) -> (account: String, tier: String)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any],
              let account = (oauth["accountUuid"] as? String)?.lowercased(), !account.isEmpty,
              let tier = oauth["organizationRateLimitTier"] as? String, !tier.isEmpty
        else { return nil }
        return (account, tier)
    }

    /// What `~/.claude.json` says about `accountID`, or `nil` when it says nothing about it.
    public static func parse(_ data: Data, accountID: String, now: Date) -> ExactUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let account = accountID.lowercased()

        var tier: String?
        if let oauth = root["oauthAccount"] as? [String: Any],
           (oauth["accountUuid"] as? String)?.lowercased() == account {
            tier = (oauth["organizationRateLimitTier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        var usage: [String: Any]?
        var fetchedAt: Date?
        if let cached = root["cachedUsageUtilization"] as? [String: Any],
           (cached["accountUuid"] as? String)?.lowercased() == account,
           let milliseconds = TranscriptReading.number(cached["fetchedAtMs"]) {
            let fetched = Date(timeIntervalSince1970: milliseconds / 1000)
            let age = now.timeIntervalSince(fetched)
            if age >= -60, age <= maximumAge, let body = cached["utilization"] as? [String: Any] {
                usage = body
                fetchedAt = fetched
            }
        }
        guard tier != nil || usage != nil else { return nil }

        func window(_ key: String) -> (Int?, Date?) {
            guard let entry = usage?[key] as? [String: Any] else { return (nil, nil) }
            let percent = TranscriptReading.number(entry["utilization"]).map { min(100, max(0, Int($0.rounded()))) }
            let resets = (entry["resets_at"] as? String).flatMap(isoDate)
            return (percent, resets)
        }
        let five = window("five_hour"), seven = window("seven_day")
        return ExactUsage(accountID: account, rateLimitTier: tier, fetchedAt: fetchedAt,
                          fiveHourUtilization: five.0, fiveHourResetsAt: five.1,
                          sevenDayUtilization: seven.0, sevenDayResetsAt: seven.1)
    }

    /// `2026-10-11T04:00:00.430546+00:00` — the API writes microseconds and an offset.
    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // The formatter takes at most milliseconds; drop the rest of the fraction.
        var trimmed = text
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = text[text.index(after: dot)..<zone].prefix(3)
            trimmed = String(text[..<dot]) + "." + fraction + String(text[zone...])
        }
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Where exact figures for an account come from.
public protocol ExactUsageSource: Sendable {
    func exact(for profile: Profile, home: String, now: Date) -> ExactUsage?
}

/// `~/.claude.json`, matched to a profile through the account its session store belongs to.
public struct ClaudeConfigUsageSource: ExactUsageSource {
    /// The CLI's config holds project history too; anything larger is not read.
    static let maximumBytes = 64 << 20

    public init() {}

    public func exact(for profile: Profile, home: String, now: Date) -> ExactUsage? {
        guard let account = SessionStore.locate(userDataDir: profile.userDataDir, home: home).folder?.accountID,
              let data = Self.read(home: home)
        else { return nil }
        return ExactUsage.parse(data, accountID: account, now: now)
    }

    /// The signed-in account's tier (see ``ExactUsage/signedInTier(_:)``).
    public static func signedInTier(home: String) -> (account: String, tier: String)? {
        read(home: home).flatMap(ExactUsage.signedInTier)
    }

    static func read(home: String) -> Data? {
        let path = PathNormalizer.normalize(".claude.json", home: home)
        guard let status = FileStatus.ofPath(path), status.kind == .regular, status.size <= maximumBytes,
              let directory = try? HeldDirectory.openAnchor((path as NSString).deletingLastPathComponent, expectedOwner: nil),
              let file = try? directory.openRegularFile((path as NSString).lastPathComponent)
        else { return nil }
        return try? file.readAll(limit: maximumBytes)
    }
}
