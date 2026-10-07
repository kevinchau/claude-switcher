import Foundation

// MARK: - Times

/// How the usage text writes times: the moment it is written for, the zone and the locale —
/// injected, so the words are the same in every test whatever the Mac's settings.
public struct UsageClock: Sendable {
    public let now: Date
    public let timeZone: TimeZone
    public let locale: Locale
    private let custom: (@Sendable (Date) -> String)?

    /// `time` overrides ``time(_:)`` (the menu passes its own formatter).
    public init(now: Date, timeZone: TimeZone = .current, locale: Locale = .current, time: (@Sendable (Date) -> String)? = nil) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        custom = time
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    private func format(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        // Recent macOS puts a narrow no-break space before "PM"; the menu text uses a plain one.
        return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func fixed(_ date: Date, _ pattern: String, zone: TimeZone? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone ?? timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func isToday(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: now) }

    /// "9:10 PM" today, "Sat 9:00 PM" on another day — the menu's own clock.
    public func time(_ date: Date) -> String {
        if let custom { return custom(date) }
        return format(date, template: isToday(date) ? "jmm" : "EEE jmm")
    }

    /// "Thu 10:08 AM", the weekday even today: a phase of the weekly schedule is a weekday and a time.
    public func weekdayTime(_ date: Date) -> String {
        format(date, template: "EEE jmm")
    }

    /// To the hour, rounded up so a "by" or "until" stays a bound: "9 PM", "Sat 9 PM".
    public func hour(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let offset = Double(timeZone.secondsFromGMT(for: date))
        let rounded = Date(timeIntervalSince1970: ((seconds + offset) / 3600).rounded(.up) * 3600 - offset)
        return format(rounded, template: isToday(rounded) ? "j" : "EEE j")
    }

    /// A coarse moment for a prediction: "Thu evening", short "Thu eve"; today "this evening"
    /// or "tonight". Small hours belong to the night before — the moment's and now's alike, so
    /// at 2 AM on Tuesday a 4 AM run-out is "tonight" and 7 AM is "this morning", not Monday's.
    public func coarse(_ date: Date, short: Bool) -> String {
        let calendar = self.calendar
        let hour = calendar.component(.hour, from: date)
        let day = hour < 5 ? date.addingTimeInterval(-6 * 3600) : date
        let part: (long: String, short: String)
        switch hour {
        case 5..<12: part = ("morning", "morn")
        case 12..<17: part = ("afternoon", "aft")
        case 17..<21: part = ("evening", "eve")
        default: part = ("night", "night")
        }
        // The night now is in: after midnight, the one that began the evening before.
        let tonight = calendar.component(.hour, from: now) < 5 ? now.addingTimeInterval(-6 * 3600) : now
        if calendar.isDate(day, inSameDayAs: part.long == "night" ? tonight : now) {
            if part.long == "night" { return "tonight" }
            return "this " + (short ? part.short : part.long)
        }
        if day.timeIntervalSince(now) > 6 * 86400 { return format(day, template: "MMM d") }
        return calendar.shortWeekdaySymbols[calendar.component(.weekday, from: day) - 1] + " " + (short ? part.short : part.long)
    }

    /// "Oct 4".
    public func day(_ date: Date) -> String { format(date, template: "MMM d") }

    /// Diagnostics: 24-hour English, "Sat 21:00".
    public func report(_ date: Date) -> String { fixed(date, "EEE HH:mm") }
    /// Diagnostics with the date: "Oct 4 09:20".
    public func reportDate(_ date: Date) -> String { fixed(date, "MMM d HH:mm") }
    /// Diagnostics in UTC (A8): "Sun 04:00 UTC".
    public func reportUTC(_ date: Date) -> String { fixed(date, "EEE HH:mm", zone: TimeZone(identifier: "UTC")!) + " UTC" }
    /// "2026-10-05 18:47".
    public func stamp(_ date: Date) -> String { fixed(date, "yyyy-MM-dd HH:mm") }

    /// "5 min", "32 h", "3 d" — an hour or more in hours, so a line's length stays bounded.
    public static func span(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h" }
        return "\(hours / 24) d"
    }
}

/// Points for text: whole, never below 0.
func pct(_ value: Double) -> Int { max(0, Int(value.rounded())) }

// MARK: - The account block

/// The forecast line under an account's bars and the sentences its tooltip adds.
///
/// The line is at most 40 characters and any hedge ("(est.)", "(default)") ends within its
/// first 32, so a menu that clips it still says the number is an estimate.
public enum ForecastText {

    public static let maximumLength = 40
    public static let hedgeWithin = 32
    public static let hedges = ["(est.)", "(default)"]
    public static let reading = "Reading activity\u{2026}"

    /// "Activity last read 26 h ago": the index on disk is older than the hour the estimates may
    /// lean on (`--dry-run` reads it as it is; the app refreshes it on every menu open).
    public static func staleIndex(_ indexedThrough: Date, now: Date) -> String {
        "Activity last read \(UsageClock.span(now.timeIntervalSince(indexedThrough))) ago"
    }

    /// The grey line under the bars.
    public static func line(_ f: UsageForecast, indexState: ActivityIndexState, clock: UsageClock) -> String {
        let now = clock.now
        if case .building = indexState { return reading }
        if case .stale(let through) = indexState { return staleIndex(through, now: now) }
        if !f.activityKnown { return reading }
        if f.weekUsed.basis == .defaults { return "No usage recorded yet (default)" }
        if let until = f.blockedUntil, until > now {
            return "\(f.blockReason ?? "Weekly limit") reached \u{2014} until \(clock.hour(until))"
        }
        if f.weekUsed.low >= 100 {
            guard let end = f.weekEnd else { return "Limit reached \u{2014} reset time unknown" }
            if f.schedule?.isFresh(now: now) == true { return "Week limit reached \u{2014} resets \(clock.hour(end))" }
            return "Limit reached \u{2014} resets (est.) \(clock.hour(end))"
        }
        if f.windowUsed.value >= 100, let clears = f.windowClearsAt {
            // Unhedged only when the fullness is recorded too (a five-hour limit hit, a sample
            // at 100): an exact end says when it clears, not that it is full.
            if f.windowExact {
                return f.windowUsed.low >= 100 ? "5h window full \u{2014} clears \(clock.time(clears))"
                    : "5h full (est.) \u{2014} clears \(clock.time(clears))"
            }
            return "5h full (est.) \u{2014} clears by \(clock.time(clears))"
        }
        switch f.weekUsed.basis {
        case .insufficient, .recordedNoSchedule: return "Reset time not known yet (est.)"
        default: break
        }
        let used = pct(f.weekUsed.value)
        if f.weekUsed.value >= 99.5 { return "~100% used (est.) \u{00B7} likely at the limit" }
        if let latest = f.latestWeekly, f.weekUsed.basis == .recordedPlusActivity,
           f.weekUsed.value - Double(latest.value) >= 5, now.timeIntervalSince(latest.at) >= 3600 {
            return "~\(used)% now (est.) \u{00B7} recorded \(latest.value)% \(UsageClock.span(now.timeIntervalSince(latest.at))) ago"
        }
        if f.weekUsed.basis == .activityOnly, f.weekUsed.value >= 5 {
            return "~\(used)% now (est.) \u{00B7} not recorded this week"
        }
        guard f.pace != nil, let projected = f.projectedAtReset, let end = f.weekEnd else {
            if let start = f.weekStart, now.timeIntervalSince(start) < UsageForecast.paceMinimumElapsed {
                return "Too early to tell \u{2014} \(UsageClock.span(now.timeIntervalSince(start))) into the week"
            }
            return "~\(used)% used (est.) \u{00B7} little use this week"
        }
        if projected.value >= 100, let out = f.runOutAt {
            return "~\(used)% used (est.) \u{00B7} out about \(clock.coarse(out, short: true))"
        }
        return "~\(pct(100 - projected.value))% unused by \(clock.hour(end)) (est.)"
    }

    /// Whether a line keeps the rule: at most 40 characters, a hedge (if any) ending by 32.
    public static func keepsTheRule(_ line: String) -> Bool {
        guard line.count <= maximumLength else { return false }
        for hedge in hedges {
            if let range = line.range(of: hedge) { return line.distance(from: line.startIndex, to: range.upperBound) <= hedgeWithin }
        }
        return true
    }

    /// The week row's reset words, from the forecast's schedule (see ``UsageText/weekReset(_:time:)``).
    public static func weekReset(_ f: UsageForecast, clock: UsageClock) -> String? {
        guard let reset = f.reading?.weekly else { return nil }
        return UsageText.weekReset(reset, time: clock.time)
    }

    /// The note after a bar. A recorded row says what ``UsageText/trailing(for:in:time:)`` says.
    /// A five-hour row whose window only this Mac's activity shows — nothing recorded in it, the
    /// lighter estimate drawn — says when that window ends: "(est.)" unless Claude Code recorded
    /// the end. Nothing is estimated before activity is read.
    public static func trailing(for row: UsageReading.Row, forecast f: UsageForecast, clock: UsageClock) -> String? {
        guard let reading = f.reading else { return nil }
        if let recorded = UsageText.trailing(for: row, in: reading, time: clock.time) { return recorded }
        guard row.key == SessionWindow.key, f.estimatedPercent(for: row.key) != nil,
              let clears = f.windowClearsAt, clears > clock.now else { return nil }
        return f.windowExact ? "resets \(clock.time(clears))" : "resets by \(clock.time(clears)) (est.)"
    }

    /// The sentence VoiceOver reads for the bars (the drawing is not an accessibility element):
    /// the recorded rows as ``UsageText/accessibilityText(_:profileLabel:time:)`` says them, each
    /// lighter segment as "estimated N percent" after its row, and — when the 5h note is the end
    /// of a window only this Mac's activity shows — that end, by the same suffix rule.
    public static func accessibilityText(_ f: UsageForecast, profileLabel: String, clock: UsageClock) -> String? {
        guard let reading = f.reading else { return nil }
        var estimates: [String: Int] = [:]
        for row in reading.rows { if let estimate = f.estimatedPercent(for: row.key) { estimates[row.key] = estimate } }
        var windowNote: String?
        if let row = reading.rows.first(where: { $0.key == SessionWindow.key }),
           UsageText.trailing(for: row, in: reading, time: clock.time) == nil,
           trailing(for: row, forecast: f, clock: clock) != nil, let clears = f.windowClearsAt {
            windowNote = f.windowExact ? "reset at \(clock.time(clears))" : "estimated reset by \(clock.time(clears))"
        }
        return UsageText.accessibilityText(reading, profileLabel: profileLabel, time: clock.time, estimates: estimates, windowNote: windowNote)
    }

    /// The bar tooltip: what was recorded, then what is estimated and on what assumptions.
    public static func tooltip(_ f: UsageForecast, indexState: ActivityIndexState, running: Bool, clock: UsageClock) -> String {
        var lines: [String] = []
        if let reading = f.reading {
            lines.append(reading.rows.map(UsageText.row).joined(separator: "  \u{00B7}  "))
            if !reading.unlisted.isEmpty {
                let extras = reading.unlisted.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)%" }
                lines.append("Also reported: \(extras.joined(separator: ", ")).")
            }
            lines.append("Last recorded \(clock.time(reading.sampledAt))\(UsageText.age(reading.age).map { " (\($0))" } ?? "").")
        } else {
            lines.append("No usage recorded yet for this account; figures are defaults until Claude records some.")
        }

        // The five-hour window.
        if let clears = f.windowClearsAt {
            if f.windowExact, let checked = f.window?.exactEndCheckedAt {
                lines.append("Claude Code\u{2019}s usage check at \(clock.time(checked)) reported the 5-hour window ends at \(clock.time(clears)).")
            } else if f.windowExact {
                lines.append("The 5-hour window ends at \(clock.time(clears)) \u{2014} Claude Code recorded it when the limit was hit.")
            } else if let start = f.window?.activityStart {
                lines.append("Estimated from this Mac\u{2019}s activity: a 5-hour window opened at \(clock.time(start)) and ends by \(clock.time(clears)).")
            } else if let window = f.window {
                lines.append("Estimated: the 5-hour window ends between \(clock.time(window.resetsAfter)) and \(clock.time(clears)).")
            }
        }
        lines.append("Assumed: a 5-hour window starts at the first message, rounded down to 10 minutes.")
        // What the lighter part of a bar is, with its number: the drawing carries no text.
        let lighter = [(SessionWindow.key, "5h"), (WeeklyReset.key, "week")].compactMap { key, label in
            f.estimatedPercent(for: key).map { "\(label) ~\($0)%" }
        }
        if !lighter.isEmpty {
            lines.append("Lighter part of a bar: this Mac\u{2019}s activity since the last recording (est.) \u{2014} " + lighter.joined(separator: ", ") + ".")
        }

        // The week now and at its end.
        if case .ready = indexState, f.activityKnown { lines.append(contentsOf: estimateLines(f, clock: clock)) }
        if case .stale(let through) = indexState {
            lines.append(staleIndex(through, now: clock.now) + "; nothing is estimated until the app reads it again (recorded values only).")
        }
        if f.timeline.limitHitWeeks.of > 0 { lines.append(historyLine(f, clock: clock)) }
        lines.append(scheduleLine(f, clock: clock))
        if case .ready = indexState {
            lines.append("Activity is read from this Mac\u{2019}s Claude Code transcripts (token counts and times only) and attributed to this account by its session records; use from claude.ai, your phone or other Macs is not seen until Claude records it \u{2014} allowed for at \(Int(UsageForecast.unseenPointsPerDay)) points/day.")
            lines.append(costsLine(f))
        }
        if f.committedWeek > 0, let biggest = f.commitments.max(by: { $0.week < $1.week }) {
            lines.append("A \(biggest.size.rawValue) session is running here (~\(pct(f.committedWeek))% of the week still committed, est.)")
        }
        var fable = "The Fable-only weekly limit is not recorded locally"
        if let hit = f.anchors.filter({ $0.kind == .fable }).max(by: { $0.hitAt < $1.hitAt }) {
            fable += "; Claude Code last reported it hit on \(clock.day(hit.hitAt)) (resets \(clock.hour(hit.resetsAt)))"
        }
        lines.append(fable + ".")
        if running, let reading = f.reading, reading.age > 24 * 3600 {
            lines.append("Right-clicking Claude\u{2019}s own menu-bar icon makes it record usage again.")
        }
        return lines.joined(separator: "\n")
    }

    static func estimateLines(_ f: UsageForecast, clock: UsageClock) -> [String] {
        let used = f.weekUsed
        var first: String
        switch used.basis {
        case .defaults:
            return ["Nothing is estimated yet: no usage has been recorded for this account (default)."]
        case .insufficient(let why):
            return ["Not enough to estimate the week: \(why)."]
        case .recorded:
            first = "Recorded: \(pct(used.value))% of the week used."
        case .activityOnly:
            first = "Estimated: ~\(pct(used.value))% of the week used (between 0% and \(pct(used.high))%), from this Mac\u{2019}s activity since the reset."
        case .recordedPlusActivity, .recordedNoSchedule:
            first = "Estimated: ~\(pct(used.value))% of the week used (between \(pct(used.low))% recorded and \(pct(used.high))%)."
        }
        var pace: [String] = []
        if let week = f.paceWeek { pace.append(String(format: "%.1f points/h this week", week)) }
        if let recent = f.paceRecent, recent > 0 { pace.append(String(format: "%.1f in the last 6 h", recent)) }
        if pace.isEmpty {
            first += " No pace yet (under 12 h or 10% into the week, and nothing in the last 6 h)."
        } else {
            first += " Pace " + pace.joined(separator: ", ") + ";"
            if let out = f.runOutAt {
                first += " at the faster pace the limit is reached about \(clock.coarse(out, short: false)), before the reset."
            } else if let waste = f.waste, let end = f.weekEnd {
                first += " at the faster pace ~\(max(0, waste))% would go unused at the \(clock.hour(end)) reset."
            } else {
                first += " the reset time is not known yet."
            }
        }
        return [first]
    }

    static func historyLine(_ f: UsageForecast, clock: UsageClock) -> String {
        let finished = f.timeline.cycles.filter { $0.end <= clock.now && ($0.hitLimitAt != nil || !$0.points.isEmpty) }.suffix(4)
        let hits = finished.compactMap(\.hitLimitAt)
        let calendar = clock.calendar
        let days = hits.map { calendar.shortWeekdaySymbols[calendar.component(.weekday, from: $0) - 1] }
        let (hit, of) = f.timeline.limitHitWeeks
        var line = "Last \(of) week\(of == 1 ? "" : "s"): reached the limit in \(hit) of \(of)"
        if !days.isEmpty { line += " (\(days.joined(separator: ", ")))" }
        let unused = finished.compactMap(\.unusedAtEnd).filter { $0 > 0 }
        if unused.count == 1 { line += "; \(unused[0])% went unused once" }
        if unused.count > 1 { line += "; " + unused.map { "\($0)%" }.joined(separator: ", ") + " went unused" }
        return line + "."
    }

    static func scheduleLine(_ f: UsageForecast, clock: UsageClock) -> String {
        let now = clock.now
        let repeatAssumption = "Assumed to repeat weekly at the same time; a plan change would move it."
        guard let schedule = f.schedule, let reset = f.reading?.weekly ?? f.weekEnd.map({ WeeklyReset(resetsAfter: $0, resetsBy: $0) }) else {
            return "No weekly reset has been seen yet, so its time is not known. " + repeatAssumption
        }
        var line: String
        var unconfirmedSaid = false
        switch schedule.source {
        case .exact(let anchors, let lastHitAt, let recordedBy):
            let agree = anchors > 1 ? " (\(anchors - 1) earlier week\(anchors == 2 ? " agrees" : "s agree"))" : ""
            // A cached usage check reported the time; no limit was hit.
            let cached = recordedBy == .cachedUsage
            let recent = now.timeIntervalSince(schedule.confirmedAt) <= WeeklySchedule.freshnessAge
            if schedule.isFresh(now: now) {
                line = cached
                    ? "Week resets \(clock.time(reset.resetsBy)) \u{2014} reported by Claude Code\u{2019}s usage check at \(clock.time(lastHitAt))\(agree). " + repeatAssumption
                    : "Week resets \(clock.time(reset.resetsBy)) \u{2014} Claude Code recorded this reset time when the weekly limit was hit on \(clock.day(lastHitAt))\(agree). " + repeatAssumption
            } else if let other = schedule.unconfirmedPhase, recent {
                // Recent enough; the hedge is back because of a reset at another time, not age.
                let source = cached ? "reported by Claude Code\u{2019}s usage check at \(clock.time(lastHitAt))" : "recorded on \(clock.day(lastHitAt))"
                line = "Week resets \(clock.time(reset.resetsBy)) (est.) \u{2014} \(source); a reset at another time (\(clock.weekdayTime(seen(other, now: now)))) is not confirmed yet: it is treated as a one-off and unconfirmed until a second one or a recorded limit hit confirms it. " + repeatAssumption
                unconfirmedSaid = true
            } else {
                line = "Week resets \(clock.time(reset.resetsBy)) (est.): assumed to repeat weekly since Claude Code last recorded it on \(clock.day(lastHitAt)); nothing in the last two weeks confirms it."
            }
        case .bracketed:
            line = "Estimated: the week resets between \(clock.time(reset.resetsAfter)) and \(clock.time(reset.resetsBy)), from the drops in the recorded figure; the exact time is not recorded locally. " + repeatAssumption
        }
        if let other = schedule.unconfirmedPhase, !unconfirmedSaid {
            line += " A reset at another time (\(clock.time(seen(other, now: now)))) is treated as a one-off and unconfirmed until a second one or a recorded limit hit confirms it."
        }
        return line
    }

    /// The latest occurrence of a phase at or before `now`.
    static func seen(_ phase: TimeInterval, now: Date) -> Date {
        Date(timeIntervalSince1970: phase + ((now.timeIntervalSince1970 - phase) / WeeklySchedule.period).rounded(.down) * WeeklySchedule.period)
    }

    static func costsLine(_ f: UsageForecast) -> String {
        let c = f.calibration
        let lead = "Costs are weighted from token counts at list prices"
        if let flag = c.flag {
            if flag == Calibration.unusualSampleFlag {
                return lead + ", using defaults while it recalibrates after an unusual sample"
            }
            if c.tripRatio == nil {
                return lead + ", using defaults \u{2014} the reset time or the plan tier changed; the plan may have changed"
            }
            return lead + ", using defaults \u{2014} the last recorded sample disagrees with the calibration; the plan may have changed"
        }
        if c.weeklyIsDefault {
            return lead + ", using defaults for Max 20x (not enough history yet)"
        }
        let fit = c.medianR2.map { String(format: "%.2f", $0) } ?? "\u{2014}"
        let error = pct(c.rmse)
        return lead + ", calibrated to this account\u{2019}s own history (\(c.segments) segments, fit \(fit), \u{00B1}\(error) point\(error == 1 ? "" : "s"))"
    }
}

// MARK: - The Advisor submenu

/// The "Start a session in…" submenu, as data the shell renders.
public struct AdvisorMenu: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let size: SessionSize
        /// `claude-switcher.advisor.<size>`, for patching the open menu.
        public let identifier: String
        public let title: String
        /// The grey line under it, indented.
        public let reason: String
        public let tooltip: String
        /// The profile the row selects, if any.
        public let profileID: String?
        /// Disabled until then (an account whose window clears shortly).
        public let enabledFrom: Date?
        /// At the clock's `now`; the shell also requires the account row's own conditions.
        public let isEnabled: Bool
    }

    public static let title = "Start a session in\u{2026}"
    public let rows: [Row]
    public let footer: [String]
    /// Shown alone while the activity index is being built.
    public let placeholder: String?
}

public enum AdvisorText {

    public static func identifier(_ size: SessionSize) -> String { "claude-switcher.advisor.\(size.rawValue)" }

    public static func menu(_ snapshot: UsageSnapshot, labels: [String: String], clock: UsageClock) -> AdvisorMenu {
        if case .stale(let through) = snapshot.indexState {
            return AdvisorMenu(rows: [], footer: [], placeholder: staleIndex(through, now: clock.now))
        }
        guard case .ready = snapshot.indexState, !snapshot.advice.isEmpty else {
            return AdvisorMenu(rows: [], footer: [], placeholder: ForecastText.reading)
        }
        let rows = SessionSize.allCases.compactMap { size in snapshot.advice[size].map { row($0, snapshot: snapshot, labels: labels, clock: clock) } }
        return AdvisorMenu(rows: rows, footer: footer(snapshot, labels: labels, clock: clock), placeholder: nil)
    }

    static func label(_ id: String, _ labels: [String: String]) -> String { labels[id] ?? id }

    /// The placeholder while the index on disk is too old to advise from. The app brings it up to
    /// date at launch and whenever its menu opens — a running app left alone does not.
    public static let refreshHint = "open the Claude Switcher menu to refresh it"

    public static func staleIndex(_ indexedThrough: Date, now: Date) -> String {
        ForecastText.staleIndex(indexedThrough, now: now) + " \u{2014} " + refreshHint
    }

    public static func row(_ advice: Advice, snapshot: UsageSnapshot, labels: [String: String], clock: UsageClock) -> AdvisorMenu.Row {
        let now = clock.now
        let head = advice.size.title + " \u{2192} "
        var title: String
        var enabledFrom: Date?
        var enabled = true
        switch advice.outcome {
        case .start(let id, _, let after, let stall):
            title = head + label(id, labels)
            if advice.size != .short, let after {
                // An estimated window end says so (a title has no length limit to keep).
                title += " after \(clock.time(after))" + (snapshot.forecasts[id]?.windowExact == true ? "" : " (est.)")
                enabledFrom = after
                enabled = now >= after
            } else if let stall {
                title += " (likely hits the limit about \(clock.coarse(stall, short: false)))"
            }
        case .lastHeadroom(let id):
            title = head + label(id, labels) + " (last headroom)"
        case .nothingFits:
            title = head + "nothing fits right now"
            enabled = false
        }
        let reasonLine = reason(advice, snapshot: snapshot, labels: labels, clock: clock)
        var tip = [reasonLine]
        if case .start(_, .unchanged(_, let original), _, _) = advice.outcome {
            tip.append("Chosen for: " + reasonText(original, chosen: advice.profileID, snapshot: snapshot, labels: labels, clock: clock) + ".")
        }
        // Every other account's clause, but the one the reason line already carries.
        let said = reasonAlternative(advice)?.profileID
        for alternative in advice.alternatives where alternative.profileID != said {
            tip.append(alternativeText(alternative, labels: labels, snapshot: snapshot, clock: clock) + ".")
        }
        tip.append("Based on " + basisText(advice.basis) + ".")
        return AdvisorMenu.Row(size: advice.size, identifier: identifier(advice.size), title: title, reason: reasonLine,
                               tooltip: tip.joined(separator: "\n"), profileID: advice.profileID, enabledFrom: enabledFrom,
                               isEnabled: enabled)
    }

    /// The reason line: what decided, and one clause on the account not chosen.
    public static func reason(_ advice: Advice, snapshot: UsageSnapshot, labels: [String: String], clock: UsageClock) -> String {
        let now = clock.now
        switch advice.outcome {
        case .start(let id, let reason, let after, let stall):
            if case .unchanged(let since, _) = reason {
                return "still \(label(id, labels)) \u{2014} chosen \(UsageClock.span(now.timeIntervalSince(since))) ago; nothing has changed enough to switch"
            }
            if after != nil, advice.size != .short {
                // "Full" only when no room is left (the cautious room, as the Advisor fits).
                let room = snapshot.forecasts[id].map { 100 - $0.windowUsed.high - $0.committedWindow } ?? 0
                return room >= 1 ? "its 5-hour window has too little room until then" : "its 5-hour window is full until then"
            }
            if let stall {
                // The account that holds the reserve: the most cautious headroom among the others.
                let reserve = advice.alternatives.compactMap { alternative in
                    snapshot.forecasts[alternative.profileID].map { (alternative.profileID, $0.headroom.low - $0.committedWeek) }
                }.max { $0.1 < $1.1 }
                // The fit is on a long session's first three hours, the stall at the faster of this
                // account's pace and a typical long session's: a stall inside those hours is said.
                let hours = stall.timeIntervalSince(now) / 3600
                let fits = hours >= 3 ? "the first 3 hours fit"
                    : hours >= 1 ? "about the first \(Int(hours.rounded(.down))) h fit" : "likely stops within the first hour"
                if let reserve, reserve.1 > 0 {
                    return "\(fits); \(label(reserve.0, labels)) keeps ~\(pct(reserve.1))% in reserve"
                }
                return "\(fits); the reserve holds here"
            }
            var line = reasonText(reason, chosen: id, snapshot: snapshot, labels: labels, clock: clock)
            if let other = reasonAlternative(advice) {
                line += "; " + alternativeText(other, labels: labels, snapshot: snapshot, clock: clock)
            }
            return line
        case .lastHeadroom:
            return "this would leave no account in reserve"
        case .nothingFits(let next, let why):
            var line = blockers(advice, why: why, snapshot: snapshot, labels: labels, clock: clock)
            if let next {
                // A weekly reset to the hour, rounded up so it stays a bound; a window end or a
                // limit's reset to the minute, as the account's own rows print it.
                let who = label(next.profileID, labels)
                let est = next.exact ? "" : " (est.)"
                switch next.event {
                case .weeklyReset: line += "; next chance \(clock.hour(next.at))\(est) when \(who) resets"
                case .windowClears: line += "; next chance \(clock.time(next.at))\(est) when \(who)\u{2019}s window clears"
                case .limitEnds(let limit): line += "; next chance \(clock.time(next.at))\(est) when \(who)\u{2019}s \(limit) resets"
                }
            }
            return line
        }
    }

    /// The one clause on another account the reason line carries, if any: an account that
    /// cannot take the session before one that fits too, never the account the reason itself
    /// names.
    static func reasonAlternative(_ advice: Advice) -> Advice.Alternative? {
        guard case .start(_, let reason, let after, let stall) = advice.outcome, stall == nil,
              after == nil || advice.size == .short
        else { return nil }
        var named: String?
        switch reason {
        case .unchanged: return nil
        case .comfortableMargin(let other, _), .keepsReserve(let other): named = other
        default: break
        }
        let others = advice.alternatives.filter { $0.profileID != named }
        return others.first { alternativeMatters($0.why) } ?? others.first
    }

    /// What is in the way when nothing fits. One thing for every account is said once ("both
    /// accounts are at or near the weekly limit"); otherwise each account's own, so a window that
    /// is full on one is never said of an account at its weekly limit.
    static func blockers(_ advice: Advice, why: Advice.Blocker, snapshot: UsageSnapshot, labels: [String: String],
                         clock: UsageClock) -> String {
        let each = advice.alternatives
        if each.isEmpty || each.allSatisfy({ blocker(of: $0.why) == why }) {
            let count = max(snapshot.forecasts.count, each.count)
            // "Full" only when no room is left in any of them.
            let full = each.allSatisfy { if case .windowFull(_, let room, _) = $0.why { return room == 0 }; return true }
            switch why {
            case .weeklyLimit:
                return count == 1 ? "the account is at or near the weekly limit"
                    : count == 2 ? "both accounts are at or near the weekly limit" : "every account is at or near the weekly limit"
            case .window:
                if count == 1 { return full ? "its 5-hour window is full" : "its 5-hour window has too little room" }
                return full ? "every 5-hour window is full" : "no 5-hour window has enough room"
            case .reserve: return "it would leave no account in reserve"
            case .blocked(let limit): return "the \(limit) is reached"
            case .notEnoughData: return "not enough usage history yet"
            }
        }
        return each.map { alternative -> String in
            let name = label(alternative.profileID, labels)
            switch alternative.why {
            case .cannotFit: return "\(name) is at or near its weekly limit"
            case .windowFull(_, let room, _):
                return room > 0 ? "\(name)\u{2019}s 5-hour window has too little room" : "\(name)\u{2019}s 5-hour window is full"
            default: return alternativeText(alternative, labels: labels, snapshot: snapshot, clock: clock)
            }
        }.joined(separator: "; ")
    }

    /// The kind of thing in an account's way, as ``Advice/Blocker`` names it; `nil` when it fits.
    static func blocker(of why: Advice.Why) -> Advice.Blocker? {
        switch why {
        case .cannotFit, .committed: return .weeklyLimit
        case .windowFull: return .window
        case .noReserve: return .reserve
        case .blocked(let reason, _): return .blocked(reason)
        case .notEnoughData, .noUsageRecorded, .otherPlan, .recalibrating: return .notEnoughData
        case .fits, .projectedToRunOut, .fitsFirstThreeHoursOnly: return nil
        }
    }

    /// Clauses about accounts that cannot take the session say more than "fits too".
    static func alternativeMatters(_ why: Advice.Why) -> Bool {
        if case .fits = why { return false }
        return true
    }

    public static func reasonText(_ reason: Advice.Reason, chosen: String?, snapshot: UsageSnapshot, labels: [String: String],
                                  clock: UsageClock) -> String {
        switch reason {
        case .useItOrLoseIt(let points, let resetBy):
            return "~\(points)% would go unused at its \(clock.hour(resetBy)) reset (est.)"
        case .resetsSoonest(let resetBy):
            // As the week row says it: a reset time from a schedule that is not exact and fresh is an estimate.
            let estimated = chosen.flatMap { snapshot.forecasts[$0]?.schedule }.map { !$0.isFresh(now: clock.now) } ?? false
            return "resets soonest (\(clock.hour(resetBy))\(estimated ? ", est." : ""))"
        case .mostHeadroom(let points):
            return "most headroom (~\(points)% left, est.)"
        case .comfortableMargin(let other, let left):
            return "comfortable margin; \(label(other, labels)) has only ~\(left)% left (est.)"
        case .onlyFit:
            return "the only account it fits"
        case .keepsReserve(let other):
            return "keeps \(label(other, labels)) in reserve"
        case .resetUnknown:
            if let id = chosen, let latest = snapshot.forecasts[id]?.latestWeekly {
                return "reset time not known yet \u{2014} recorded \(latest.value)% used \(UsageClock.span(clock.now.timeIntervalSince(latest.at))) ago"
            }
            return "reset time not known yet"
        case .noUsageRecorded:
            return "no usage recorded yet \u{2014} a short session records it"
        case .unchanged(_, let original):
            return reasonText(original, chosen: chosen, snapshot: snapshot, labels: labels, clock: clock)
        }
    }

    public static func alternativeText(_ alternative: Advice.Alternative, labels: [String: String], snapshot: UsageSnapshot,
                                       clock: UsageClock) -> String {
        let name = label(alternative.profileID, labels)
        switch alternative.why {
        case .fits(let left): return "\(name) fits too (~\(left)% left, est.)"
        case .projectedToRunOut: return "\(name) is projected to run out"
        case .fitsFirstThreeHoursOnly(let left): return "\(name) fits the first 3 h only (~\(left)% of the week left, est.)"
        case .cannotFit(let left): return "\(name) cannot fit: ~\(left)% of the week left (est.)"
        case .windowFull(let until, let room, let exact):
            // "Full" only at no room left; an estimated end says so.
            let state = room > 0 ? "\(name)\u{2019}s 5-hour window has too little room (~\(room)% left, est.)" : "\(name)\u{2019}s 5-hour window is full"
            return state + (until.map { " until \(clock.time($0))" + (exact ? "" : " (est.)") } ?? "")
        case .noReserve: return "\(name) would leave no reserve"
        case .blocked(let reason, let until): return "\(name): \(reason) reached until \(clock.hour(until))"
        case .committed(let points): return "\(name): a session is already running there (~\(points)% committed, est.)"
        case .notEnoughData: return "\(name): not enough usage history yet"
        case .noUsageRecorded: return "\(name): no usage recorded yet \u{2014} short sessions only"
        case .otherPlan(let tier): return "\(name): on \(tier), not the Max 20x the defaults assume \u{2014} short sessions only until its own history calibrates"
        case .recalibrating:
            return "\(name): the last recorded usage disagrees with the calibration \u{2014} short sessions only until it recalibrates"
        }
    }

    public static func basisText(_ basis: Basis) -> String {
        switch basis {
        case .recorded: return "recorded usage"
        case .recordedPlusActivity: return "the last recorded usage plus this Mac\u{2019}s activity since (est.)"
        case .recordedNoSchedule: return "recorded usage; the weekly reset time is not known yet (est.)"
        case .activityOnly: return "this Mac\u{2019}s activity since the weekly reset (est.)"
        case .defaults: return "defaults \u{2014} no usage recorded yet (default)"
        case .insufficient(let why): return "too little data (\(why))"
        }
    }

    public static func footer(_ snapshot: UsageSnapshot, labels: [String: String], clock: UsageClock) -> [String] {
        var lines = [costsSummary(snapshot.costs)]
        let ids = snapshot.order.filter { snapshot.forecasts[$0] != nil }
        let resets = ids.map { id -> String in
            let f = snapshot.forecasts[id]!
            guard let schedule = f.schedule else { return "\(label(id, labels)) not known yet" }
            // As the week row says it: exact only when exact and fresh.
            return "\(label(id, labels)) " + (schedule.isFresh(now: clock.now) ? "exact" : "estimated")
        }
        let ages = ids.map { id in snapshot.forecasts[id]!.reading.map { UsageClock.span(clock.now.timeIntervalSince($0.sampledAt)) } ?? "never" }
        lines.append("Reset times: " + resets.joined(separator: ", ") + " \u{00B7} usage last recorded " + ages.joined(separator: " / ")
                     + (ages.allSatisfy { $0 == "never" } ? "" : " ago"))
        if ids.count == 1 { lines.append("Only one account \u{2014} no reserve is possible") }
        let defaulted = snapshot.costs.short.isDefault || snapshot.costs.medium.isDefault || snapshot.costs.long.isDefault
        for id in ids {
            let f = snapshot.forecasts[id]!
            guard defaulted || f.calibration.weeklyIsDefault else { continue }
            let plan: String
            switch f.plan {
            case .max20x: continue
            case .unknown: plan = "unknown"
            case .named(let tier): plan = tier
            }
            // Name what is a default: the session costs, or only this account's calibration (its
            // costs may be the user's own, which the first footer line says).
            lines.append(defaulted ? "Costs are defaults for Max 20x; \(label(id, labels))\u{2019}s plan is \(plan)"
                                   : "\(label(id, labels))\u{2019}s calibration uses defaults for Max 20x; its plan is \(plan)")
        }
        return lines
    }

    /// "Costs from your last 30 days (short 32, medium 31, long 31 sessions)", or which sizes
    /// still use the defaults.
    public static func costsSummary(_ costs: SessionCosts) -> String {
        let sizes = SessionSize.allCases
        let own = sizes.filter { !costs[$0].isDefault }
        let counts = own.map { "\($0.rawValue) \(costs[$0].episodes)" }.joined(separator: ", ")
        if own.count == sizes.count { return "Costs from your last 30 days (\(counts) sessions)" }
        if own.isEmpty {
            return "Costs are defaults for Max 20x \u{2014} fewer than \(SessionCosts.minimumEpisodes) sessions of each size recorded"
        }
        let rest = sizes.filter { costs[$0].isDefault }.map(\.rawValue)
        return "Costs from your last 30 days (\(counts) sessions); \(rest.joined(separator: " and ")) \(rest.count == 1 ? "uses" : "use") defaults for Max 20x"
    }
}

// MARK: - Diagnostics and --dry-run

/// The lines Diagnostics and `--dry-run` print per account and for the Advisor.
public enum DiagnosticsText {

    public static let guarantee = "Usage numbers are read from each account\u{2019}s own plan-usage-history.json; activity (times and token counts only) from ~/.claude transcripts, session records and ~/.claude.json. Nothing is written there, nothing is fetched, no token or cookie is read. The switcher keeps one index of those numbers in ~/.config/claude-switcher."

    public static let assumptions = "assumptions: weekly reset repeats at a fixed time (A1); 5h window = first message floored to 10 min + 5 h (A3); token weighting at list prices without cache reads (A4); defaults assume a Max 20x plan (A5); unseen use allowed at \(Int(UsageForecast.unseenPointsPerDay)) points/day (A9)"

    public static let needsIndex = "advice: needs the activity index (built when the app runs)"

    /// "week ~62% used (0–72, est.) · pace 0.9 pts/h (6 h: 1.4) · runs out about Thu 18:00 (est.) · 5h 44% room, clears 21:10 (exact) · committed 0"
    ///
    /// Without the activity index (building, or too old) nothing is estimated here either: the
    /// recorded values and the window's bound, then what the estimates are waiting for.
    public static func forecast(_ f: UsageForecast, clock: UsageClock, indexState: ActivityIndexState? = nil) -> String {
        if !f.activityKnown { return recordedOnly(f, clock: clock, indexState: indexState) }
        var parts: [String] = []
        let used = f.weekUsed
        switch used.basis {
        case .defaults: parts.append("week: no usage recorded (default)")
        case .insufficient(let why): parts.append("week: insufficient \u{2014} \(why)")
        case .recorded: parts.append("week \(pct(used.value))% used (recorded)")
        default:
            parts.append("week ~\(pct(used.value))% used (\(pct(used.low))\u{2013}\(pct(used.high)), est.\(f.activityKnown ? "" : "; activity not read yet"))")
        }
        var pace = f.paceWeek.map { String(format: "pace %.1f pts/h", $0) } ?? "pace \u{2014}"
        if let recent = f.paceRecent { pace += String(format: " (6 h: %.1f)", recent) }
        parts.append(pace)
        if let out = f.runOutAt {
            parts.append("runs out about \(clock.report(out)) (est.)")
        } else if let waste = f.waste {
            parts.append("~\(max(0, waste))% unused at the reset (est.)")
        }
        if let clears = f.windowClearsAt {
            parts.append("5h \(pct(f.windowRoom))% room, clears \(clock.report(clears)) (\(windowTag(f)))")
        } else {
            parts.append("5h no window open")
        }
        parts.append(String(format: "committed %.0f", f.committedWeek))
        if f.stale { parts.append("stale (nothing recorded or read in 7 days)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "exact" only when both the end and the fullness are recorded (the line's rule).
    static func windowTag(_ f: UsageForecast) -> String {
        guard f.windowExact else { return "est." }
        return f.windowUsed.low >= 100 ? "exact" : "end exact, fullness est."
    }

    /// The forecast line without activity: "week 0% used (recorded) · 5h 14% used (recorded), clears by 21:10 (est.) · estimates: needs the activity index (…)".
    static func recordedOnly(_ f: UsageForecast, clock: UsageClock, indexState: ActivityIndexState?) -> String {
        var parts: [String] = []
        switch f.weekUsed.basis {
        case .defaults: parts.append("week: no usage recorded (default)")
        case .insufficient(let why): parts.append("week: insufficient \u{2014} \(why)")
        case .recordedNoSchedule: parts.append("week \(pct(f.weekUsed.low))% used (recorded; reset time not known yet)")
        case .activityOnly:
            parts.append("week: reset since the last sample" + (f.latestWeekly.map { " (\($0.value)% recorded \(UsageClock.span(clock.now.timeIntervalSince($0.at))) ago)" } ?? ""))
        case .recorded, .recordedPlusActivity: parts.append("week \(pct(f.weekUsed.low))% used (recorded)")
        }
        if let clears = f.windowClearsAt {
            let end = f.windowExact ? "clears \(clock.report(clears)) (exact)" : "clears by \(clock.report(clears)) (est.)"
            parts.append("5h \(pct(f.windowUsed.low))% used (recorded), \(end)")
        } else {
            parts.append("5h no window open")
        }
        if f.stale { parts.append("stale (nothing recorded in 7 days)") }
        var wait = "estimates: needs the activity index"
        if case .stale(let through) = indexState {
            wait += " (last read \(UsageClock.span(clock.now.timeIntervalSince(through))) ago \u{2014} \(AdvisorText.refreshHint))"
        } else {
            wait += " (built when the app runs)"
        }
        parts.append(wait)
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "week resets Sat 21:00 (Sun 04:00 UTC) — exact, fresh (4 anchors; last hit Oct 4 09:20) · 5h window: 10-min floor assumed (A3) · out-of-order samples 0"
    public static func schedule(_ f: UsageForecast, clock: UsageClock) -> String {
        var line: String
        if let schedule = f.schedule, let end = f.weekEnd {
            switch schedule.source {
            case .exact(let anchors, let lastHitAt, let recordedBy):
                // Why it is not fresh: a reset at another time, or age.
                let state = schedule.isFresh(now: clock.now) ? "fresh"
                    : schedule.unconfirmedPhase != nil && clock.now.timeIntervalSince(schedule.confirmedAt) <= WeeklySchedule.freshnessAge
                        ? "unconfirmed reset" : "older than 14 days, so (est.)"
                if recordedBy == .cachedUsage {
                    line = "week resets \(clock.report(end)) (\(clock.reportUTC(end))) \u{2014} exact (cached usage at \(clock.reportDate(lastHitAt))), \(state)"
                } else {
                    line = "week resets \(clock.report(end)) (\(clock.reportUTC(end))) \u{2014} exact, \(state) (\(anchors) anchor\(anchors == 1 ? "" : "s"); last hit \(clock.reportDate(lastHitAt)))"
                }
            case .bracketed(let support, let newestAt):
                line = String(format: "week resets by %@ (%@) \u{2014} estimated, \u{00B1}%.0f min (support %.2f; newest drop %@)",
                              clock.report(end), clock.reportUTC(end), schedule.halfWidth / 60, support, clock.reportDate(newestAt))
            }
            line += " (A1, A8)"
            if let other = schedule.unconfirmedPhase {
                line += " \u{00B7} unconfirmed reset at \(clock.report(ForecastText.seen(other, now: clock.now))) treated as one-off (A2)"
            }
            line += " \u{00B7} out-of-order samples \(schedule.outOfOrderSamples)"
        } else {
            line = "week reset not observed yet"
        }
        return line + " \u{00B7} 5h window: 10-min floor assumed (A3)"
    }

    /// "0.074 pts per unit (5 segments, median fit 0.99, ±1.4) · window 0.30 (n=12) · plan: Max 20x · costs: …"
    public static func calibration(_ f: UsageForecast, costs: SessionCosts) -> String {
        let c = f.calibration
        var weekly = String(format: "%.3f pts per unit", c.weekly)
        if c.weeklyIsDefault {
            var flag = c.flag.map { " \u{2014} \($0)" } ?? ""
            if let ratio = c.tripRatio {
                // A5 as built: an account whose plan is not named is held to short sessions only
                // from a 3× trip (noise this Mac cannot see trips it at about 2.4×).
                flag += String(format: "; tripped at %.1f\u{00D7}; medium and long held back only from %.0f\u{00D7}, A5",
                               ratio, UsageAdvisor.recalibratingRatio)
            }
            weekly += " (default\(flag))"
        } else {
            weekly += String(format: " (%d segments, median fit %.2f, \u{00B1}%.1f)", c.segments, c.medianR2 ?? 0, c.rmse)
        }
        let window = String(format: "window %.2f", c.window) + (c.windowIsDefault ? " (default)" : " (n=\(c.windows))")
        let plan: String
        switch f.plan {
        case .max20x: plan = "plan: Max 20x"
        case .unknown: plan = "plan: unknown (defaults assume Max 20x, A5)"
        case .named(let tier): plan = "plan: \(tier) (defaults assume Max 20x, A5)"
        }
        let points = costs.points(for: c)
        let sizes = SessionSize.allCases.map { size -> String in
            let cost = points[size]
            var text = String(format: "%@ %.1f/%.1f", size.rawValue, cost.whole.p50, cost.whole.p75)
            if size == .long { text += String(format: " (first 3 h %.1f/%.1f)", cost.fitWeek.p50, cost.fitWeek.p75) }
            return text + (cost.isDefault ? " default" : " n=\(cost.episodes)")
        }
        let total = SessionSize.allCases.reduce(0) { $0 + costs[$1].episodes }
        let source = total > 0 ? "from \(total) sessions; A15" : "defaults; A15"
        return [weekly, window, plan, "costs: " + sizes.joined(separator: ", ") + " (p50/p75 week points, \(source))"]
            .joined(separator: " \u{00B7} ")
    }

    /// "Fable limit hit Oct 1 09:05, resets Oct 3 21:00 (past) · limit reached 3 of last 4 weeks"
    public static func limits(_ f: UsageForecast, clock: UsageClock) -> String {
        var parts: [String] = []
        var newest: [String: LimitAnchor] = [:]
        for anchor in f.anchors where (newest[anchor.kind.label]?.hitAt ?? .distantPast) < anchor.hitAt { newest[anchor.kind.label] = anchor }
        for (label, anchor) in newest.sorted(by: { $0.value.hitAt > $1.value.hitAt }) {
            let when = anchor.resetsAt > clock.now ? "" : " (past)"
            parts.append("\(label.prefix(1).uppercased() + label.dropFirst()) hit \(clock.reportDate(anchor.hitAt)), resets \(clock.reportDate(anchor.resetsAt))\(when)")
        }
        if parts.isEmpty { parts.append("no limit hit recorded") }
        let (hit, of) = f.timeline.limitHitWeeks
        if of > 0 { parts.append("limit reached \(hit) of last \(of) weeks") }
        parts.append("(A7)")
        return parts.joined(separator: " \u{00B7} ")
    }

    /// One account's lines, labelled, as Diagnostics prints them after `usage:`.
    public static func accountLines(_ f: UsageForecast, costs: SessionCosts, clock: UsageClock, indent: String = "    ",
                                    indexState: ActivityIndexState? = nil) -> [String] {
        [indent + "forecast:       " + forecast(f, clock: clock, indexState: indexState),
         indent + "schedule:       " + schedule(f, clock: clock),
         indent + "calibration:    " + calibration(f, costs: costs),
         indent + "limits:         " + limits(f, clock: clock)]
    }

    /// The three advice rows: "short   → Christy    most headroom …".
    public static func adviceRows(_ snapshot: UsageSnapshot, labels: [String: String], clock: UsageClock) -> [String] {
        SessionSize.allCases.compactMap { size in
            guard let advice = snapshot.advice[size] else { return nil }
            let target: String
            switch advice.outcome {
            case .start(let id, _, let after, _):
                if advice.size != .short, let after {
                    let est = snapshot.forecasts[id]?.windowExact == true ? "" : " (est.)"
                    target = AdvisorText.label(id, labels) + " after \(clock.report(after))\(est)"
                } else {
                    target = AdvisorText.label(id, labels)
                }
            case .lastHeadroom(let id): target = AdvisorText.label(id, labels) + " (last headroom)"
            case .nothingFits: target = "nothing fits"
            }
            let name = size.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
            return "\(name) \u{2192} " + target.padding(toLength: max(target.count, 10), withPad: " ", startingAt: 0) + " "
                + AdvisorText.reason(advice, snapshot: snapshot, labels: labels, clock: clock)
        }
    }

    /// The `ADVISOR` section; empty when there are no accounts. Counts and labels only — never a
    /// session's title, prompt or path.
    public static func advisorSection(_ snapshot: UsageSnapshot, labels: [String: String], summary: ActivityIndexSummary?,
                                      clock: UsageClock) -> [String] {
        guard !snapshot.forecasts.isEmpty else { return [] }
        var lines = ["ADVISOR"]
        if case .ready = snapshot.indexState, !snapshot.advice.isEmpty {
            lines += adviceRows(snapshot, labels: labels, clock: clock).map { "  " + $0 }
            lines.append("  " + AdvisorText.costsSummary(snapshot.costs))
        } else if case .stale(let through) = snapshot.indexState {
            lines.append("  advice: none \u{2014} " + AdvisorText.staleIndex(through, now: clock.now).lowercasedFirst)
        } else {
            lines.append("  advice: none until the activity index is built (\(ForecastText.reading))")
        }
        if let summary {
            lines.append(String(format: "  activity index: %d account%@, %d transcripts, read through %@, %.1f%% of spend unattributed (A6), %d unpriced calls",
                                summary.accounts, summary.accounts == 1 ? "" : "s", summary.transcripts, clock.stamp(summary.indexedThrough),
                                summary.unattributedShare * 100, summary.unpricedCalls))
        } else {
            lines.append("  activity index: not built yet")
        }
        lines.append("  " + assumptions)
        return lines
    }

    /// `--dry-run`'s advice block (it never scans: without an index there is no advice, and an
    /// index more than an hour old is not advised from — it says how old).
    public static func dryRunAdvice(_ snapshot: UsageSnapshot, labels: [String: String], clock: UsageClock) -> [String] {
        if case .stale(let through) = snapshot.indexState {
            return ["advice: " + AdvisorText.staleIndex(through, now: clock.now).lowercasedFirst]
        }
        guard case .ready = snapshot.indexState, !snapshot.advice.isEmpty else { return [needsIndex] }
        return ["advice:"] + adviceRows(snapshot, labels: labels, clock: clock).map { "  " + $0 }
    }
}

extension String {
    /// "Activity last read…" → "activity last read…".
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
