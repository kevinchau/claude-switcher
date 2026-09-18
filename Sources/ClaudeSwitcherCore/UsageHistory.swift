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
/// moments it can end. Both bounds are certain, not estimates.
///
/// Inside one window utilization never decreases and the window lasts five hours, so the
/// longest trailing run of non-decreasing `fh` values spanning under five hours lies within
/// one window. It was already running at that run's first positive sample — so it ends no
/// later than five hours after it — and the sample before the run belongs to an earlier
/// window, so it ends no earlier than five hours after *that*. A `0` inside the run is an
/// ordinary member: a first message can round to 0 %, and the real histories on this Mac
/// show windows that had started before a sample that still read 0.
public struct SessionWindow: Equatable, Sendable {
    public static let length: TimeInterval = 5 * 3600
    public static let key = "fh"

    public let utilization: Int
    /// The window ends strictly after this.
    public let resetsAfter: Date
    /// The window ends no later than this.
    public let resetsBy: Date

    public init(utilization: Int, resetsAfter: Date, resetsBy: Date) {
        self.utilization = utilization
        self.resetsAfter = resetsAfter
        self.resetsBy = resetsBy
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
        return SessionWindow(
            utilization: latest.fh,
            resetsAfter: resetsAfter,
            resetsBy: firstPositive.at.addingTimeInterval(length)
        )
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
    /// Values the latest sample carried that get no bar.
    public let unlisted: [String: Int]

    public init(sampledAt: Date, age: TimeInterval, rows: [Row], session: SessionWindow?, unlisted: [String: Int]) {
        self.sampledAt = sampledAt
        self.age = age
        self.rows = rows
        self.session = session
        self.unlisted = unlisted
    }

    /// `nil` when there is nothing to show.
    public static func make(samples all: [UsageSample], now: Date) -> UsageReading? {
        let samples = UsageHistory.currentOrgSamples(all)
        guard let latest = samples.last else { return nil }
        let age = now.timeIntervalSince(latest.sampledAt)
        let session = SessionWindow.infer(from: samples)

        var rows: [Row] = []
        var unlisted = latest.utilization
        for (key, label) in rowTable {
            guard let percent = unlisted.removeValue(forKey: key) else { continue }
            let value: Value
            if key == SessionWindow.key, let session, now >= session.resetsBy {
                value = .ended
            } else if weeklyKeys.contains(key), age >= weeklyLength {
                value = .ended
            } else {
                value = .percent(percent)
            }
            rows.append(Row(key: key, label: label, value: value))
        }
        return UsageReading(sampledAt: latest.sampledAt, age: age, rows: rows, session: session, unlisted: unlisted)
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
    /// upper bound), the week row says how old the reading is.
    public static func trailing(for row: UsageReading.Row, in reading: UsageReading, time: (Date) -> String) -> String? {
        switch row.key {
        case SessionWindow.key:
            guard let session = reading.session, row.percent != nil else { return nil }
            return "resets by \(time(session.resetsBy))"
        case "sd":
            return age(reading.age)
        default:
            return nil
        }
    }

    public static func tooltip(_ reading: UsageReading, time: (Date) -> String) -> String {
        var lines: [String] = []
        lines.append(reading.rows.map(UsageText.row).joined(separator: "  \u{00B7}  "))
        if let session = reading.session {
            if reading.rows.contains(where: { $0.key == SessionWindow.key && $0.percent != nil }) {
                lines.append("The 5-hour window ends between \(time(session.resetsAfter)) and \(time(session.resetsBy)).")
            } else {
                lines.append("The 5-hour window seen at \(time(reading.sampledAt)) has ended; nothing has been recorded since.")
            }
        }
        if !reading.unlisted.isEmpty {
            let extras = reading.unlisted.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)%" }
            lines.append("Also reported: \(extras.joined(separator: ", ")).")
        }
        lines.append("Last recorded \(time(reading.sampledAt))\(age(reading.age).map { " (\($0))" } ?? ""). Claude Desktop records usage only while this profile is open, so use from claude.ai or your phone on this account shows up only then.")
        return lines.joined(separator: "\n")
    }

    /// One sentence for VoiceOver.
    public static func accessibilityText(_ reading: UsageReading, profileLabel: String, time: (Date) -> String) -> String {
        var parts = reading.rows.map { row -> String in
            switch row.value {
            case .percent(let n): return "\(row.label) \(n) percent"
            case .ended: return "\(row.label) ended"
            }
        }
        if let session = reading.session, reading.rows.contains(where: { $0.key == SessionWindow.key && $0.percent != nil }) {
            parts.append("resets by \(time(session.resetsBy))")
        }
        if let age = age(reading.age) { parts.append(age) }
        return "\(profileLabel) usage: \(parts.joined(separator: ", "))"
    }

    /// One line for Diagnostics and `--dry-run`.
    public static func summary(_ reading: UsageReading?, time: (Date) -> String) -> String {
        guard let reading else { return "no data yet (recorded once Claude has run on this profile)" }
        var parts = reading.rows.map(UsageText.row)
        if let session = reading.session, reading.rows.contains(where: { $0.key == SessionWindow.key && $0.percent != nil }) {
            parts.append("resets by \(time(session.resetsBy))")
        }
        parts.append("recorded \(time(reading.sampledAt))\(age(reading.age).map { " (\($0))" } ?? "")")
        return parts.joined(separator: " \u{00B7} ")
    }
}
