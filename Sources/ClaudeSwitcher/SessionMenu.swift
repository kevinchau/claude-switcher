import AppKit
import ClaudeSwitcherCore

/// Everything the menu shows about sessions, gathered in one pass off the main thread: reading
/// an account's records is tens of milliseconds of file I/O, and the menu never waits for it.
struct SessionMenuData: Equatable, Sendable {
    /// profile id -> that account's Code sessions.
    var listings: [String: SessionListing] = [:]
    /// Why a listed session cannot be copied to one particular account; absent means "offer it".
    /// Keyed by ``key(source:session:target:)``.
    var obstacles: [String: SessionCopy.Refusal] = [:]
    /// Copies made but not yet opened by the Claude they were made for.
    var pending: [SessionCopy.Pending] = []
    /// profile id -> the pending copies filed in the store that account lists — matched here,
    /// off the main thread, so building the menu compares no paths.
    var arriving: [String: [SessionCopy.Pending]] = [:]
    /// Copies whose journal is still there and that are not committed.
    var unfinished: [SessionCopy.Unfinished] = []
    /// A session-store folder that cannot be read — which refuses every copy. For Diagnostics.
    var unreadableStore: String?

    /// How many sessions an account's submenu lists. The rest are counted in its last line.
    static let visibleSessions = 20

    static func key(source: String, session: String, target: String) -> String {
        [source, session, target].joined(separator: "\u{0}")
    }

    /// Blocking; call off the main thread. Read-only.
    static func read(profiles: [Profile], environment: SessionCopy.Environment) -> SessionMenuData {
        var data = SessionMenuData()
        for profile in profiles {
            data.listings[profile.id] = SessionListing.read(profile: profile, allProfiles: profiles, environment: environment)
        }
        // Every copy proves its new id unused in every store on the Mac, so one store that
        // cannot be read refuses them all: say so on the items rather than offer them.
        data.unreadableStore = SessionCopy.unreadableStore(allProfiles: profiles, environment: environment)?.path
        for source in profiles {
            guard let listing = data.listings[source.id] else { continue }
            // Only for the rows the menu will show, and only where the session itself can be copied.
            for session in listing.sessions.prefix(visibleSessions) where session.obstacle == nil {
                for target in profiles where target.id != source.id {
                    let refusal = SessionCopy.obstacle(for: session, from: source, to: target,
                                                       allProfiles: profiles, environment: environment)
                        ?? (data.unreadableStore != nil ? .storeUnreadable : nil)
                    if let refusal {
                        data.obstacles[key(source: source.id, session: session.id, target: target.id)] = refusal
                    }
                }
            }
        }
        data.pending = SessionCopy.pending(environment: environment)
        data.arriving = arriving(data.pending, listings: data.listings)
        data.unfinished = SessionCopy.unfinished(environment: environment)
        return data
    }

    /// Each pending copy under the account whose listed store it was filed in: the same folder
    /// by device and inode, whatever the spelling (by path when either cannot be looked at).
    private static func arriving(_ pending: [SessionCopy.Pending], listings: [String: SessionListing]) -> [String: [SessionCopy.Pending]] {
        func identity(_ path: String) -> [UInt64]? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return [UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino)]
        }
        var arriving: [String: [SessionCopy.Pending]] = [:]
        for (profileID, listing) in listings {
            guard let folder = listing.location.folder else { continue }
            let listed = identity(folder.url.path)
            let mine = pending.filter { copy in
                if let listed, let filed = identity(copy.targetStore.path) { return listed == filed }
                return copy.targetStore.path == folder.url.path
            }
            if !mine.isEmpty { arriving[profileID] = mine }
        }
        return arriving
    }
}

/// What a "Copy to …" menu item carries to its action.
final class SessionCopyChoice: NSObject {
    let sourceProfileID: String
    let targetProfileID: String
    let sessionID: String
    let cliSessionId: String
    let cwd: String
    let title: String

    init(sourceProfileID: String, targetProfileID: String, sessionID: String, cliSessionId: String, cwd: String, title: String) {
        self.sourceProfileID = sourceProfileID
        self.targetProfileID = targetProfileID
        self.sessionID = sessionID
        self.cliSessionId = cliSessionId
        self.cwd = cwd
        self.title = title
    }
}

/// Builds each account's "Sessions" submenu from a ``SessionMenuData`` snapshot. Like
/// `MenuBuilder`, it reads what it is handed and performs no I/O — no path is looked at, or
/// even turned into a file URL, here.
@MainActor
enum SessionMenu {

    private nonisolated static let titleLimit = 64

    static func itemIdentifier(_ profileID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("claude-switcher.sessions.\(profileID)")
    }

    /// The "Sessions" item that sits under an account's row. Every account has one, so the
    /// account's name is in what VoiceOver reads; the title stays short. No tooltip on it, nor
    /// on the session rows: each opens a submenu, and a tooltip lands on top of a submenu that
    /// opens to the left (see `UsageMenu.advisorItem`).
    static func item(for profile: Profile, input: MenuBuilder.Input, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        item.indentationLevel = 1
        item.identifier = itemIdentifier(profile.id)
        item.setAccessibilityLabel("\(profile.label) sessions")
        item.submenu = submenu(for: profile, input: input, target: target, action: action)
        return item
    }

    /// Replaces the contents of every account's Sessions submenu in a menu that is already
    /// built — for a read that lands while the menu is open.
    static func update(in menu: NSMenu, input: MenuBuilder.Input, target: AnyObject, action: Selector) {
        for profile in input.config.profiles {
            let identifier = itemIdentifier(profile.id)
            guard let item = menu.items.first(where: { $0.identifier == identifier }) else { continue }
            item.submenu = submenu(for: profile, input: input, target: target, action: action)
        }
    }

    static func submenu(for profile: Profile, input: MenuBuilder.Input, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard let data = input.sessions, let listing = data.listings[profile.id] else {
            menu.addItem(MenuBuilder.informationalItem("Reading sessions\u{2026}"))
            return menu
        }
        guard listing.location.folder != nil else {
            menu.addItem(MenuBuilder.informationalItem(unavailableText(listing.location, label: profile.label)))
            return menu
        }

        // Copies made for this account that its Claude has not picked up yet.
        let arriving = data.arriving[profile.id] ?? []
        for copy in arriving {
            let name = copy.title.map { "\u{201C}\(shortened($0))\u{201D}" } ?? "An untitled copy"
            let item = MenuBuilder.informationalItem("\(name) \u{2014} copied \(age(copy.copiedAt, now: input.now)), not opened yet")
            item.toolTip = "It appears in \(profile.label)\u{2019}s Code tab the next time \(profile.label)\u{2019}s Claude starts. Claude Switcher will not quit Claude for you."
            menu.addItem(item)
        }
        if !arriving.isEmpty { menu.addItem(.separator()) }

        if listing.sessions.isEmpty {
            menu.addItem(MenuBuilder.informationalItem("No open sessions with a transcript on this Mac."))
        }
        let others = input.config.profiles.filter { $0.id != profile.id }
        for session in listing.sessions.prefix(SessionMenuData.visibleSessions) {
            let title = displayTitle(session)
            let row = NSMenuItem(title: shortened(title), action: nil, keyEquivalent: "")
            row.badge = NSMenuItemBadge(string: session.isRunning ? "open" : age(session.record.lastActivityAt, now: input.now))
            row.submenu = actionsMenu(for: session, title: title, source: profile, others: others,
                                      data: data, isCopying: input.copyProgress != nil || input.switcher.isCommitting,
                                      now: input.now, target: target, action: action)
            menu.addItem(row)
        }

        if let footer = footer(listing) {
            menu.addItem(.separator())
            menu.addItem(MenuBuilder.informationalItem(footer))
        }
        return menu
    }

    // MARK: - One session's actions

    private static func actionsMenu(
        for session: ListedSession, title: String, source: Profile, others: [Profile],
        data: SessionMenuData, isCopying: Bool, now: Date, target: AnyObject, action: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // The row's particulars come first, where they cover nothing.
        for line in details(session, title: title, now: now) { menu.addItem(MenuBuilder.informationalItem(line)) }
        menu.addItem(.separator())

        if let obstacle = session.obstacle {
            menu.addItem(MenuBuilder.informationalItem("Can\u{2019}t be copied"))
            menu.addItem(MenuBuilder.informationalItem(obstacle.message))
            return menu
        }
        guard let cliSessionId = session.record.cliSessionId else {
            menu.addItem(MenuBuilder.informationalItem("Can\u{2019}t be copied: it has no conversation yet."))
            return menu
        }
        if others.isEmpty {
            menu.addItem(MenuBuilder.informationalItem("Add another account to copy sessions to it."))
            return menu
        }
        for other in others {
            let refusal = data.obstacles[SessionMenuData.key(source: source.id, session: session.id, target: other.id)]
            let item = NSMenuItem(title: "Copy to \(other.label)\u{2026}", action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = SessionCopyChoice(
                sourceProfileID: source.id, targetProfileID: other.id, sessionID: session.id,
                cliSessionId: cliSessionId, cwd: session.record.cwd, title: title)
            item.isEnabled = refusal == nil && !isCopying
            item.toolTip = refusal?.message
                ?? "Makes an independent copy of this session in \(other.label). Nothing happens until you confirm."
            menu.addItem(item)
            // A disabled item's tooltip is easy to miss; say why right under it.
            if let refusal { menu.addItem(MenuBuilder.informationalItem(refusal.message)) }
        }
        return menu
    }

    // MARK: - Text

    /// String work only: `URL(fileURLWithPath:)` would look at the disk to decide whether the
    /// path is a folder — on the main thread, for every untitled row.
    static func displayTitle(_ session: ListedSession) -> String {
        if let title = session.record.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let folder = (session.record.cwd as NSString).lastPathComponent
        return folder.isEmpty || folder == "/" ? "Untitled session" : "Untitled \u{2014} \(folder)"
    }

    // MARK: - Unfinished copies and what recovery did

    /// The one line a recovery pass at launch leaves in the menu; the notes themselves go in
    /// its tooltip and in Diagnostics.
    nonisolated static func recoverySummary(_ notes: [SessionCopy.RecoveryNote]) -> String {
        let attention = notes.filter(\.needsAttention).count
        let settled = notes.count - attention
        var parts: [String] = []
        if settled > 0 { parts.append("\(settled) finished or cleaned up") }
        if attention > 0 { parts.append("\(attention) need\(attention == 1 ? "s" : "") attention") }
        return "Session copies: " + parts.joined(separator: ", ") + " \u{2014} see Diagnostics\u{2026}"
    }

    /// The line shown for as long as any copy's journal is there and not committed.
    nonisolated static func unfinishedSummary(_ unfinished: [SessionCopy.Unfinished]) -> String {
        let count = unfinished.count
        return "\(count) session cop\(count == 1 ? "y has" : "ies have") not finished \u{2014} see Diagnostics\u{2026}"
    }

    nonisolated static let unfinishedToolTip =
        "Claude Switcher tries again at each start. Diagnostics\u{2026} says what is left and where to look."

    nonisolated static func shortened(_ title: String, limit: Int = titleLimit) -> String {
        title.count > limit ? String(title.prefix(limit - 1)) + "\u{2026}" : title
    }

    /// `~` for the home folder, and the end of a long path: the part that tells folders apart.
    /// String work only, like `displayTitle`.
    nonisolated static func shortenedPath(_ path: String) -> String {
        let abbreviated = (path as NSString).abbreviatingWithTildeInPath
        return abbreviated.count > titleLimit ? "\u{2026}" + abbreviated.suffix(titleLimit - 1) : abbreviated
    }

    nonisolated static func unavailableText(_ location: SessionStoreLocation, label: String) -> String {
        switch location {
        case .none:
            return "No Code sessions here yet."
        case .otherAccountOnly:
            return "\(label)\u{2019}s Claude is signed in to a different account than the sessions saved here."
        case .ambiguous:
            return "Several accounts or organisations have used \(label)\u{2019}s Claude \u{2014} can\u{2019}t tell which sessions are current."
        case .folder:
            return ""
        }
    }

    /// One line for everything that is not listed, with only the counts that are not zero.
    static func footer(_ listing: SessionListing) -> String? {
        var parts: [String] = []
        let older = listing.sessions.count - SessionMenuData.visibleSessions
        if older > 0 { parts.append("\(older) older") }
        if listing.hidden.archived > 0 { parts.append("\(listing.hidden.archived) archived") }
        if listing.hidden.withoutTranscript > 0 { parts.append("\(listing.hidden.withoutTranscript) with no transcript on this Mac") }
        if listing.hidden.remote > 0 { parts.append("\(listing.hidden.remote) remote") }
        return parts.isEmpty ? nil : "Not listed: " + parts.joined(separator: ", ")
    }

    /// The first lines of a session's submenu: the title in full when the row had to cut it,
    /// then its folder, last activity, model and transcript size. A menu line cannot wrap, so
    /// each is kept to about the row's own width.
    static func details(_ session: ListedSession, title: String, now: Date) -> [String] {
        var lines: [String] = []
        if title.count > titleLimit { lines.append(shortened(title, limit: 2 * titleLimit)) }
        lines.append("Folder: " + shortenedPath(session.record.cwd))
        if let last = session.record.lastActivityAt {
            lines.append("Last active: \(MenuBuilder.clock(last, now: now)) (\(age(last, now: now)))")
        }
        if let model = session.record.model { lines.append("Model: \(model)") }
        lines.append("Transcript: \(ByteCountFormatter.string(fromByteCount: Int64(session.transcriptBytes), countStyle: .file))")
        if session.isRunning { lines.append("Open in Claude right now.") }
        return lines
    }

    /// "just now", "12 min ago", "3 h ago", "5 d ago" — or nothing to say for a missing date.
    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "just now"
        case ..<5400: return "\(Int((seconds / 60).rounded())) min ago"
        case ..<129_600: return "\(Int((seconds / 3600).rounded())) h ago"
        default: return "\(Int((seconds / 86_400).rounded())) d ago"
        }
    }
}

/// What the app says after a copy is confirmed — pure, so it can be tested without an alert.
enum CopyResult {

    struct Alert: Equatable {
        /// A copy is in the other account's list (now, or once recovery finished it a moment later).
        let isSuccess: Bool
        let title: String
        let message: String
    }

    /// The one alert for a copy attempt, with what the recovery pass that followed it said.
    /// A copy left for registration that recovery then finished is reported as copied.
    static func alert(for outcome: SessionCopy.Outcome, notes: [SessionCopy.RecoveryNote], title: String,
                      source: String, target: String, targetIsRunning: Bool) -> Alert {
        let quoted = "\u{201C}\(SessionMenu.shortened(title))\u{201D}"
        func copied(skipped: Int) -> String {
            var message = "\(quoted) is now also a separate session in \(target). It appears in \(target)\u{2019}s Code tab the next time \(target)\u{2019}s Claude starts."
            if targetIsRunning {
                message += "\n\n\(target)\u{2019}s Claude is running now. Quit it yourself when its sessions are idle, then open it again \u{2014} closing the window is not enough, and Claude Switcher will not quit Claude for you."
            }
            message += "\n\nKeep the original in \(source) until you have opened the copy."
            if skipped > 0 {
                message += "\n\n\(skipped) subagent transcript\(skipped == 1 ? "" : "s") could not be copied (missing or unreadable); the conversation itself is complete."
            }
            return message
        }
        func withNotes(_ message: String, _ notes: [SessionCopy.RecoveryNote]) -> String {
            notes.isEmpty ? message : message + "\n\n" + notes.map(\.message).joined(separator: "\n\n")
        }

        switch outcome {
        case .copied(let copy):
            return Alert(isSuccess: true, title: "Copied to \(target)", message: copied(skipped: copy.skippedSubagentTranscripts))
        case .refused(let refusal):
            return Alert(isSuccess: false, title: "Nothing was copied", message: withNotes(refusal.message, notes))
        case .pendingRegistration(let newSessionID, let detail):
            let own = notes.first { $0.copyID == newSessionID }
            let others = notes.filter { $0.copyID != newSessionID }
            if own?.kind == .finished {
                return Alert(isSuccess: true, title: "Copied to \(target)", message: withNotes(copied(skipped: 0), others))
            }
            return Alert(isSuccess: false, title: "The copy is not finished", message: withNotes(detail, (own.map { [$0] } ?? []) + others))
        }
    }

    /// The two accounts a confirmed copy is between, as the config says now — `nil` when either
    /// was removed or points at another data folder than when the confirmation was shown.
    /// Labels may have changed; the current ones are used.
    static func stillTheConfirmedPair(in config: Config, sourceID: String, targetID: String,
                                      confirmed: (source: Profile, target: Profile)) -> (Profile, Profile)? {
        guard let source = config.profile(id: sourceID), let target = config.profile(id: targetID),
              source.userDataDir == confirmed.source.userDataDir, target.userDataDir == confirmed.target.userDataDir
        else { return nil }
        return (source, target)
    }
}
