import AppKit
import ClaudeSwitcherCore

/// What a usage read needs from the app's memory; it reads everything else itself. The one way
/// the shell reads usage — the menu, Diagnostics and `--dry-run` all call ``read(home:now:)``.
struct UsageQuery: Sendable {
    var profiles: [Profile]
    /// Each profile's activity from the switcher's own index, as of its last refresh; `nil`
    /// while it is being built (or, for `--dry-run`, when there is none on disk).
    var activity: [String: ActivityLedger]?
    var indexState: ActivityIndexState
    /// The Advisor's last answers, so a choice is kept unless another is clearly better.
    var previous: [SessionSize: Advice] = [:]
    /// The profiles whose Claude is running.
    var running: Set<String> = []

    /// The index state a read is made with: building until the first refresh lands. An index
    /// older than the hour the estimates may lean on is ``ActivityIndexState/stale(indexedThrough:)``
    /// to the snapshot — unless a refresh is under way, when it is being read: the menu then says
    /// "Reading activity…" until it lands, not how old it is.
    static func indexState(indexedThrough: Date?, refreshing: Bool, now: Date) -> ActivityIndexState {
        guard let through = indexedThrough else { return .building }
        if refreshing, now.timeIntervalSince(through) > UsageSnapshot.maximumUnread { return .building }
        return .ready(indexedThrough: through)
    }

    /// Blocking and read-only — never on the main thread: each account's
    /// plan-usage-history.json, `~/.claude.json`, and, only when there is activity to charge
    /// them against, the session registry and records for the sessions busy right now (A12).
    func read(home: String = NSHomeDirectory(), now: Date = Date()) -> UsageSnapshot {
        var busy: [String: [BusySession]] = [:]
        if let ledgers = activity, case .ready = indexState {
            let sessions = RunningSessions.read(home: home)
            if !sessions.busyCliSessionIds.isEmpty {
                busy = BusySession.attribute(running: sessions, attribution: ActivityAttribution.read(profiles: profiles, home: home),
                                             ledgers: ledgers)
            }
        }
        return UsageSnapshot.read(profiles: profiles, home: home, activity: activity, indexState: indexState, previous: previous,
                                  busy: busy, running: running, now: now)
    }
}

/// The usage under each account — its bars and the grey forecast line — and the "Start a
/// session in…" submenu, all drawn from one ``UsageSnapshot`` read off the main thread.
///
/// Like ``SessionMenu``: built with the rest of the menu from what was last read, then patched
/// in place, by identifier, when a newer snapshot lands while the menu is open — never rebuilt
/// under the cursor.
@MainActor
enum UsageMenu {

    // MARK: - Identifiers

    static let advisorIdentifier = NSUserInterfaceItemIdentifier("claude-switcher.advisor")
    static let placeholderIdentifier = NSUserInterfaceItemIdentifier("claude-switcher.advisor.placeholder")

    static func rowIdentifier(_ size: SessionSize) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(AdvisorText.identifier(size))
    }

    static func reasonIdentifier(_ size: SessionSize) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(AdvisorText.identifier(size) + ".reason")
    }

    static func footerIdentifier(_ index: Int) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("claude-switcher.advisor.footer.\(index)")
    }

    static func barsIdentifier(_ profileID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("claude-switcher.usage.\(profileID)")
    }

    static func forecastIdentifier(_ profileID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("claude-switcher.forecast.\(profileID)")
    }

    // MARK: - Shared

    /// The menu's clock at the moment it is built: "9:10 PM" today, "Sat 9:00 PM" another day.
    static func clock(_ input: MenuBuilder.Input) -> UsageClock {
        UsageClock(now: input.now, timeZone: input.timeZone, locale: input.locale)
    }

    nonisolated static func labels(_ config: Config) -> [String: String] {
        Dictionary(config.profiles.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
    }

    /// Until the first read lands there is nothing to estimate from: as while the index is built.
    static func indexState(_ input: MenuBuilder.Input) -> ActivityIndexState {
        input.usage?.indexState ?? .building
    }

    // MARK: - The account block

    /// Under an account's row: its bars, when Claude has recorded something for it, and the
    /// forecast line. Nothing until the first snapshot has been read.
    static func accountItems(for profile: Profile, input: MenuBuilder.Input) -> [NSMenuItem] {
        guard let forecast = input.usage?.forecasts[profile.id] else { return [] }
        let clock = clock(input)
        let state = indexState(input)
        let tooltip = ForecastText.tooltip(forecast, indexState: state,
                                           running: ProfileMatching.isRunning(profile, in: input.running), clock: clock)
        var items: [NSMenuItem] = []
        if let reading = forecast.reading, !reading.rows.isEmpty {
            // VoiceOver hears what is drawn: the recorded rows, the lighter estimate, the end of a
            // window only this Mac's activity shows.
            items.append(barsItem(for: profile, rows: barRows(forecast, reading: reading, clock: clock),
                                  title: ForecastText.accessibilityText(forecast, profileLabel: profile.label, clock: clock) ?? "",
                                  tooltip: tooltip))
        }
        items.append(forecastItem(for: profile, line: ForecastText.line(forecast, indexState: state, clock: clock), tooltip: tooltip))
        return items
    }

    /// One drawn row per limit: the recorded percentage, the lighter estimate above it (only
    /// once activity is read — ``UsageForecast/estimatedPercent(for:)`` is `nil` before), and
    /// the reset note, whose "(est.)" follows the suffix rule.
    static func barRows(_ forecast: UsageForecast, reading: UsageReading, clock: UsageClock) -> [UsageBarView.Row] {
        reading.rows.map { row in
            UsageBarView.Row(label: row.label, percent: row.percent, level: UsageLevel.of(row.percent ?? 0),
                             trailing: ForecastText.trailing(for: row, forecast: forecast, clock: clock),
                             estimate: forecast.estimatedPercent(for: row.key))
        }
    }

    /// A view item never draws its title, so the title carries the sentence VoiceOver reads;
    /// the view itself is not an accessibility element.
    static func barsItem(for profile: Profile, rows: [UsageBarView.Row], title: String, tooltip: String) -> NSMenuItem {
        let view = UsageBarView(rows: rows)
        view.toolTip = tooltip
        view.setAccessibilityElement(false)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = view
        item.isEnabled = false
        item.identifier = barsIdentifier(profile.id)
        return item
    }

    /// The grey line under the bars: at most 40 characters, the hedge within its first 32.
    static func forecastItem(for profile: Profile, line: String, tooltip: String) -> NSMenuItem {
        let item = MenuBuilder.informationalItem(line)
        item.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.toolTip = tooltip
        item.identifier = forecastIdentifier(profile.id)
        return item
    }

    // MARK: - "Start a session in…"

    static let advisorToolTip = "Which account to start a new session in, by how long it will run \u{2014} so no account is "
        + "left without usage and none goes to waste at its reset. Estimated from each account\u{2019}s recorded usage and this "
        + "Mac\u{2019}s Claude Code activity; hover a row for why. Choosing a row opens that account, as its row below does."

    /// Above the accounts, under the running line. `nil` with no accounts.
    static func advisorItem(_ input: MenuBuilder.Input, target: AnyObject, actions: MenuBuilder.Actions) -> NSMenuItem? {
        guard !input.config.profiles.isEmpty else { return nil }
        let item = NSMenuItem(title: AdvisorMenu.title, action: nil, keyEquivalent: "")
        item.identifier = advisorIdentifier
        item.toolTip = advisorToolTip
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for sub in advisorItems(input, target: target, actions: actions) { submenu.addItem(sub) }
        item.submenu = submenu
        return item
    }

    /// The Advisor's answers, as text; `nil` until the first snapshot has been read.
    static func model(_ input: MenuBuilder.Input) -> AdvisorMenu? {
        input.usage.map { AdvisorText.menu($0, labels: labels(input.config), clock: clock(input)) }
    }

    /// A size row can start its account when the account row could (nothing is starting, Claude.app
    /// is there), the account is still configured, and the row itself allows it now: not "nothing
    /// fits", and not before the window it waits for clears.
    static func isEnabled(_ row: AdvisorMenu.Row, input: MenuBuilder.Input) -> Bool {
        guard row.isEnabled, let id = row.profileID, input.config.profile(id: id) != nil else { return false }
        return !input.isBusy && input.claudeAppExists
    }

    /// Three rows, each with its reason under it, then the footer — or the one placeholder
    /// line while the activity index is absent, being built or too old.
    static func advisorItems(_ input: MenuBuilder.Input, target: AnyObject, actions: MenuBuilder.Actions) -> [NSMenuItem] {
        let advice = model(input)
        guard let advice, advice.placeholder == nil, !advice.rows.isEmpty else {
            let item = MenuBuilder.informationalItem(advice?.placeholder ?? ForecastText.reading)
            item.identifier = placeholderIdentifier
            return [item]
        }
        var items: [NSMenuItem] = []
        for row in advice.rows {
            let item = NSMenuItem(title: row.title, action: row.profileID == nil ? nil : actions.selectProfile, keyEquivalent: "")
            item.target = target
            item.representedObject = row.profileID
            item.identifier = rowIdentifier(row.size)
            item.isEnabled = isEnabled(row, input: input)
            item.toolTip = row.tooltip
            items.append(item)

            let reason = MenuBuilder.informationalItem("  " + row.reason)
            reason.identifier = reasonIdentifier(row.size)
            reason.toolTip = row.tooltip
            items.append(reason)
        }
        items.append(.separator())
        for (index, line) in advice.footer.enumerated() {
            let item = MenuBuilder.informationalItem(line)
            item.identifier = footerIdentifier(index)
            items.append(item)
        }
        return items
    }

    /// The next moment a disabled "after 9:10 PM" row becomes startable, if any.
    static func nextEnable(_ input: MenuBuilder.Input) -> Date? {
        model(input)?.rows.compactMap(\.enabledFrom).filter { $0 > input.now }.min()
    }

    // MARK: - Patching an open menu

    /// A newer snapshot, into a menu that is open: every account's bars and line and the
    /// Advisor's rows, found by identifier and changed in place. Items are inserted or removed
    /// only when what there is to show changes (bars appear once Claude records something).
    static func update(in menu: NSMenu, input: MenuBuilder.Input, target: AnyObject, actions: MenuBuilder.Actions) {
        for profile in input.config.profiles {
            guard let row = menu.items.firstIndex(where: { $0.identifier == MenuBuilder.accountItemIdentifier(profile.id) }) else { continue }
            let ours: Set<NSUserInterfaceItemIdentifier> = [barsIdentifier(profile.id), forecastIdentifier(profile.id)]
            let existing = menu.items.filter { $0.identifier.map(ours.contains) ?? false }
            let fresh = accountItems(for: profile, input: input)
            if existing.map(\.identifier) == fresh.map(\.identifier) {
                for (old, new) in zip(existing, fresh) { patch(old, with: new) }
            } else {
                for item in existing { menu.removeItem(item) }
                for (offset, item) in fresh.enumerated() { menu.insertItem(item, at: row + 1 + offset) }
            }
        }
        guard let submenu = menu.items.first(where: { $0.identifier == advisorIdentifier })?.submenu else { return }
        let fresh = advisorItems(input, target: target, actions: actions)
        if shape(submenu.items) == shape(fresh) {
            for (old, new) in zip(submenu.items, fresh) { patch(old, with: new) }
        } else {
            submenu.removeAllItems()
            for item in fresh { submenu.addItem(item) }
        }
    }

    /// Identifiers in order, separators included: the same shape is patched item by item.
    static func shape(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.isSeparatorItem ? "\u{2014}" : $0.identifier?.rawValue ?? "" }
    }

    static func patch(_ old: NSMenuItem, with new: NSMenuItem) {
        old.attributedTitle = nil
        old.title = new.title
        if let styled = new.attributedTitle { old.attributedTitle = styled }
        old.toolTip = new.toolTip
        old.action = new.action
        old.target = new.target
        old.representedObject = new.representedObject
        old.isEnabled = new.isEnabled
        if let view = new.view as? UsageBarView {
            if let current = old.view as? UsageBarView, current.update(rows: view.rows) {
                current.toolTip = view.toolTip
            } else {
                old.view = view
            }
        }
    }
}
