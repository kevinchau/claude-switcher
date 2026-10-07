import AppKit
import ClaudeSwitcherCore

/// Builds the status-item menu from a snapshot of state. Side-effect free: it reads the
/// values handed to it (including an already-computed Keychain existence cache) and never
/// performs I/O, so opening the menu can never block on a `security` call or a subprocess.
@MainActor
enum MenuBuilder {

    // MARK: - Inputs

    struct Actions: Sendable {
        var selectProfile: Selector
        var copyTerminalCommand: Selector
        var addProfile: Selector
        var renameProfile: Selector
        var removeProfile: Selector
        var chooseClaudeApp: Selector
        var revealSharedDirectory: Selector
        var showDiagnostics: Selector
        var showWelcome: Selector
        var toggleLaunchAtLogin: Selector
        var toggleReopenAfterUpdate: Selector
        var toggleBlockUpdates: Selector
        var installUpdate: Selector
        var copySession: Selector
        var toggleUpdateSwitcherAutomatically: Selector
        var checkForSwitcherUpdates: Selector
        var installSwitcherUpdate: Selector
        var quit: Selector
    }

    /// One line of text, with what its tooltip says.
    struct MenuLine: Equatable {
        var text: String
        var toolTip: String?
    }

    /// Claude Switcher updating itself, as the menu shows it.
    struct SwitcherMenu {
        /// The setting, "Keep Claude Switcher Up to Date".
        var automatic = true
        /// Set for a copy that never replaces itself: the toggle is off and disabled.
        var checksOnlyReason: String?
        /// The toggle's last sentence: "Last checked 3:12 PM: up to date."
        var lastCheck = "Not checked yet."
        /// Checking, downloading, or replacing itself.
        var progress: String?
        /// From the decision to the relaunch: Quit and the settings wait for it.
        var isCommitting = false
        /// A check or its download is running.
        var isChecking = false
        /// A verified release this copy keeps: "Update Claude Switcher to X & Relaunch".
        var ready: ReleaseVersion?
        /// Ready and waiting for nothing to be going on, or in place for the next launch.
        var waiting: MenuLine?
        /// Shown once: it updated itself, could not, or went back.
        var notice: SwitcherNotice?
        /// The new version is in place and starts at the next launch: nothing more to check.
        var restartPending = false
    }

    struct Input {
        var config: Config
        var running: [RunningInstance]
        /// profile id -> terminal CLI sign-in. A missing entry renders with no badge
        /// rather than blocking the rebuild on a Keychain existence check.
        var signInStates: [String: Bool]
        var isBusy: Bool
        var configError: String?
        var claudeAppExists: Bool
        var launchAtLogin: LoginItemState
        /// A downloaded Claude update whose installer is waiting for every instance to quit.
        /// `nil` when nothing is staged, or when no installer is alive to install it.
        var blockedUpdate: StagedUpdate?
        /// Set for the duration of "Quit All & Install Update…"; replaces the offer with progress.
        var updateProgress: String?
        /// Every account's recorded usage, its forecast and the Advisor's answers, as last read
        /// off the main thread (``UsageQuery/read(home:now:)``). `nil`: not read yet.
        var usage: UsageSnapshot?
        /// The moment the menu is built; readings are judged against it.
        var now: Date = Date()
        /// How usage times are written: the Mac's own zone and language (fixed in tests).
        var timeZone: TimeZone = .current
        var locale: Locale = .current
        /// Set after profiles were reopened automatically; shown once so it is never silent.
        var autoReopenNotice: String?
        /// No claude CLI was found at launch; the copied commands cannot run without one.
        var cliIsMissing: Bool = false
        /// Each account's Code sessions, as last read off the main thread. `nil`: not read yet.
        var sessions: SessionMenuData?
        /// Set while a session is being copied to another account; one at a time.
        var copyProgress: String?
        /// What a recovery pass at launch did about copies that had not finished: one short line,
        /// the notes in its tooltip. Shown once so it is never silent; Diagnostics keeps them.
        var copyNotes: [SessionCopy.RecoveryNote] = []
        var switcher = SwitcherMenu()
    }

    // MARK: - Build

    static func build(_ input: Input, target: AnyObject, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(informationalItem(runningSummary(input)))
        // Which account to start a session in: above the accounts, under the running line.
        if let advisor = UsageMenu.advisorItem(input, target: target, actions: actions) {
            menu.addItem(advisor)
        }

        if let error = input.configError {
            menu.addItem(informationalItem("Config problem: \(error)"))
            menu.addItem(informationalItem("Showing the last good settings. Fix \(Config.configURL.lastPathComponent) and reopen this menu."))
        }
        if !input.claudeAppExists {
            menu.addItem(informationalItem("Claude.app not found at \(input.config.claudeAppPath)"))
            menu.addItem(informationalItem("Pick it with \u{201C}Choose Claude.app\u{2026}\u{201D} below."))
        }
        if let notice = input.autoReopenNotice {
            menu.addItem(informationalItem(notice))
        }
        if let notice = input.switcher.notice {
            let item = informationalItem(notice.text)
            item.toolTip = notice.tooltip
            menu.addItem(item)
        }
        if !input.copyNotes.isEmpty {
            let item = informationalItem(SessionMenu.recoverySummary(input.copyNotes))
            item.toolTip = input.copyNotes.map(\.message).joined(separator: "\n\n")
            menu.addItem(item)
        }
        if let progress = input.copyProgress {
            menu.addItem(informationalItem(progress))
        } else if let unfinished = input.sessions?.unfinished, !unfinished.isEmpty {
            // For as long as a journal is kept. Not while a copy runs: its own journal is one.
            let item = informationalItem(SessionMenu.unfinishedSummary(unfinished))
            item.toolTip = SessionMenu.unfinishedToolTip
            menu.addItem(item)
        }
        if let progress = input.updateProgress {
            menu.addItem(informationalItem(progress))
        } else if input.switcher.isCommitting, let progress = input.switcher.progress {
            // Replacing itself holds the launch slot; say what is happening, not "Starting Claude…".
            menu.addItem(informationalItem(progress))
        } else if input.isBusy {
            menu.addItem(informationalItem("Starting Claude\u{2026}"))
        } else if let update = input.blockedUpdate, !input.running.isEmpty {
            // Claude's installer waits for every instance of the app to quit, so with more than
            // one profile open an update can wait forever — and a profile that quits itself to
            // be updated never comes back. Say so, and offer the one way through.
            menu.addItem(informationalItem("Claude \(update.staged) is downloaded but can\u{2019}t install until Claude has quit on every account."))
            let installItem = NSMenuItem(title: "Quit All & Install Update\u{2026}", action: actions.installUpdate, keyEquivalent: "")
            installItem.target = target
            installItem.toolTip = "Asks Claude to quit on every account, waits for Claude\u{2019}s own installer to finish, then reopens the accounts that were running. Nothing happens until you confirm."
            menu.addItem(installItem)
        }
        // A check or a download runs beside whatever Claude is doing, so it never hides that.
        if !input.switcher.isCommitting, let progress = input.switcher.progress {
            menu.addItem(informationalItem(progress))
        }
        if let waiting = input.switcher.waiting {
            let item = informationalItem(waiting.text)
            item.toolTip = waiting.toolTip
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // MARK: Accounts
        // "Account" is the word on screen; `Profile` stays the type and the config key.
        if input.config.profiles.isEmpty {
            menu.addItem(informationalItem("No accounts yet."))
        }
        for profile in input.config.profiles {
            let item = NSMenuItem(title: profile.label, action: actions.selectProfile, keyEquivalent: "")
            item.target = target
            item.representedObject = profile.id
            item.state = ProfileMatching.isRunning(profile, in: input.running) ? .on : .off
            item.isEnabled = !input.isBusy && input.claudeAppExists
            item.toolTip = profileToolTip(profile, input: input)
            item.identifier = accountItemIdentifier(profile.id)
            menu.addItem(item)
            for usageItem in UsageMenu.accountItems(for: profile, input: input) { menu.addItem(usageItem) }
            menu.addItem(SessionMenu.item(for: profile, input: input, target: target, action: actions.copySession))
        }

        menu.addItem(.separator())

        // MARK: Copy terminal command
        // The terminal sign-in is shown here, not on the account rows: as a badge there it
        // read as something wrong with the account, when the Claude app signs in on its own.
        let copyItem = NSMenuItem(title: "Copy terminal command", action: nil, keyEquivalent: "")
        copyItem.identifier = terminalMenuIdentifier
        let copyMenu = NSMenu()
        copyMenu.autoenablesItems = false
        if input.config.profiles.isEmpty {
            copyMenu.addItem(informationalItem("No accounts"))
        } else {
            copyMenu.addItem(informationalItem("For the claude CLI in a terminal \u{2014} it signs in separately from the Claude app."))
        }
        if input.cliIsMissing {
            copyMenu.addItem(informationalItem("No claude CLI was found on this Mac \u{2014} these commands need it installed."))
        }
        for profile in input.config.profiles {
            let sub = NSMenuItem(title: profile.label, action: actions.copyTerminalCommand, keyEquivalent: "")
            sub.target = target
            sub.representedObject = profile.id
            sub.identifier = terminalItemIdentifier(profile.id)
            sub.isEnabled = true
            applyHint(to: sub, profile: profile, signedIn: input.signInStates[profile.id])
            copyMenu.addItem(sub)
        }
        copyItem.submenu = copyMenu
        menu.addItem(copyItem)

        // MARK: Add account
        let addItem = NSMenuItem(title: "Add Account\u{2026}", action: actions.addProfile, keyEquivalent: "")
        addItem.target = target
        addItem.isEnabled = !input.isBusy
        menu.addItem(addItem)

        // MARK: Rename account
        let renameItem = NSMenuItem(title: "Rename Account", action: nil, keyEquivalent: "")
        let renameMenu = NSMenu()
        renameMenu.autoenablesItems = false
        if input.config.profiles.isEmpty {
            renameMenu.addItem(informationalItem("No accounts"))
        }
        for profile in input.config.profiles {
            let sub = NSMenuItem(title: profile.label, action: actions.renameProfile, keyEquivalent: "")
            sub.target = target
            sub.representedObject = profile.id
            sub.isEnabled = !input.isBusy
            sub.toolTip = "Changes only the name shown in this menu. Directories, sign-ins and the account\u{2019}s id stay as they are."
            renameMenu.addItem(sub)
        }
        renameItem.submenu = renameMenu
        menu.addItem(renameItem)

        // MARK: Remove account
        let removeItem = NSMenuItem(title: "Remove Account", action: nil, keyEquivalent: "")
        let removeMenu = NSMenu()
        removeMenu.autoenablesItems = false
        if input.config.profiles.isEmpty {
            removeMenu.addItem(informationalItem("No accounts"))
        }
        for profile in input.config.profiles {
            let isDefault = profile.isDefaultProfile
            let isActive = profile.id == input.config.activeProfileId
            var title = profile.label
            if isDefault {
                title += " (default account)"
            } else if isActive {
                title += " (active)"
            }
            let sub = NSMenuItem(title: title, action: actions.removeProfile, keyEquivalent: "")
            sub.target = target
            sub.representedObject = profile.id
            sub.isEnabled = !isDefault && !isActive && !input.isBusy
            if isDefault {
                sub.toolTip = "The default account cannot be removed."
            } else if isActive {
                sub.toolTip = "This account is active. Switch to another account first."
            } else {
                sub.toolTip = "Forgets the account. Nothing on disk is deleted."
            }
            removeMenu.addItem(sub)
        }
        removeItem.submenu = removeMenu
        menu.addItem(removeItem)

        menu.addItem(.separator())

        // MARK: App-level items
        let chooseItem = NSMenuItem(title: "Choose Claude.app\u{2026}", action: actions.chooseClaudeApp, keyEquivalent: "")
        chooseItem.target = target
        chooseItem.isEnabled = input.updateProgress == nil
        chooseItem.toolTip = "Currently: \(input.config.claudeAppPath)"
        menu.addItem(chooseItem)

        let revealItem = NSMenuItem(title: "Reveal ~/.claude in Finder", action: actions.revealSharedDirectory, keyEquivalent: "")
        revealItem.target = target
        revealItem.toolTip = "Skills, agents, plugins, memory, settings and every session\u{2019}s transcript \u{2014} shared by every account."
        menu.addItem(revealItem)

        let welcomeItem = NSMenuItem(title: "Welcome\u{2026}", action: actions.showWelcome, keyEquivalent: "")
        welcomeItem.target = target
        welcomeItem.toolTip = "How Claude Switcher works, in one window. Opening Claude Switcher again while it is running shows it too."
        menu.addItem(welcomeItem)

        let diagnosticsItem = NSMenuItem(title: "Diagnostics\u{2026}", action: actions.showDiagnostics, keyEquivalent: "")
        diagnosticsItem.target = target
        menu.addItem(diagnosticsItem)

        // While Claude Switcher replaces itself, its settings wait: the copy that starts reads them.
        let settingsEnabled = !input.switcher.isCommitting

        let loginItem = NSMenuItem(title: "Launch at Login", action: actions.toggleLaunchAtLogin, keyEquivalent: "")
        loginItem.target = target
        loginItem.isEnabled = settingsEnabled
        switch input.launchAtLogin {
        case .enabled:
            loginItem.state = .on
        case .disabled:
            loginItem.state = .off
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.toolTip = "Waiting for approval in System Settings \u{203A} General \u{203A} Login Items."
        case .unavailable:
            loginItem.state = .off
            loginItem.isEnabled = false
            loginItem.toolTip = "Only an installed app bundle can open at login \u{2014} not a bare `swift run` binary."
        }
        menu.addItem(loginItem)

        let reopenItem = NSMenuItem(title: "Reopen Accounts After Claude Updates", action: actions.toggleReopenAfterUpdate, keyEquivalent: "")
        reopenItem.target = target
        reopenItem.state = input.config.reopenAfterUpdate ? .on : .off
        reopenItem.isEnabled = settingsEnabled
        reopenItem.toolTip = "When Claude updates itself it closes, and its installer only reopens the default account. With this on, the other accounts that closed for the update are started again, in the background, once the update is in. It only ever starts Claude \u{2014} nothing is quit."
        menu.addItem(reopenItem)

        let blockItem = NSMenuItem(title: "Block Claude Auto-Updates", action: actions.toggleBlockUpdates, keyEquivalent: "")
        blockItem.target = target
        blockItem.state = input.config.blockClaudeUpdates ? .on : .off
        blockItem.isEnabled = settingsEnabled
        blockItem.toolTip = input.config.blockClaudeUpdates
            ? "Claude will not update itself. No security or compatibility fixes arrive, and the Code tab\u{2019}s CLI stops updating too. Applies the next time each account starts. To update: turn this off and restart an account."
            : "Stops Claude Desktop from downloading or installing updates, so it never closes itself to update. Asks first, and tells you what you give up."
        menu.addItem(blockItem)

        // MARK: Claude Switcher itself
        menu.addItem(.separator())
        for item in switcherItems(input.switcher, target: target, actions: actions) { menu.addItem(item) }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Claude Switcher", action: actions.quit, keyEquivalent: "q")
        quitItem.target = target
        // Quitting mid-update would leave every profile closed with nothing to reopen them; and
        // while Claude Switcher replaces itself, the commit ends this process itself.
        quitItem.isEnabled = input.updateProgress == nil && !input.switcher.isCommitting
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Claude Switcher itself

    /// "Keep Claude Switcher Up to Date", "Check for Claude Switcher Updates…", and — only while a
    /// verified release is kept — "Update Claude Switcher to X & Relaunch".
    static func switcherItems(_ switcher: SwitcherMenu, target: AnyObject, actions: Actions) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let keepItem = NSMenuItem(title: SwitcherUpdateUI.keepUpToDateTitle,
                                  action: actions.toggleUpdateSwitcherAutomatically, keyEquivalent: "")
        keepItem.target = target
        if let reason = switcher.checksOnlyReason {
            keepItem.state = .off
            keepItem.isEnabled = false
            keepItem.toolTip = SwitcherUpdateUI.checksOnlyToolTip(reason)
        } else {
            keepItem.state = switcher.automatic ? .on : .off
            keepItem.isEnabled = !switcher.isCommitting
            keepItem.toolTip = switcher.automatic
                ? SwitcherUpdateUI.onToolTip(lastCheck: switcher.lastCheck) : SwitcherUpdateUI.offToolTip
        }
        items.append(keepItem)

        let checkItem = NSMenuItem(title: SwitcherUpdateUI.checkTitle, action: actions.checkForSwitcherUpdates,
                                   keyEquivalent: "")
        checkItem.target = target
        checkItem.isEnabled = !switcher.isChecking && !switcher.isCommitting && !switcher.restartPending
        checkItem.toolTip = SwitcherUpdateUI.checkToolTip
        items.append(checkItem)

        if let version = switcher.ready {
            let updateItem = NSMenuItem(title: SwitcherUpdateUI.updateTitle(version),
                                        action: actions.installSwitcherUpdate, keyEquivalent: "")
            updateItem.target = target
            updateItem.isEnabled = !switcher.isCommitting
            updateItem.toolTip = SwitcherUpdateUI.updateToolTip(version)
            items.append(updateItem)
        }
        return items
    }

    // MARK: - Times

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// "Sat 10:09 PM" — for moments on another day, such as the weekly reset.
    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        return formatter
    }()

    /// A clock time, with the weekday when it is not today.
    static func clock(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? timeFormatter.string(from: date)
            : dayTimeFormatter.string(from: date)
    }

    /// An account's own row: where its usage items go when a newer snapshot patches them in.
    static func accountItemIdentifier(_ profileID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("claude-switcher.account.\(profileID)")
    }

    // MARK: - Hints

    static let terminalMenuIdentifier = NSUserInterfaceItemIdentifier("claude-switcher.terminal")

    static func terminalItemIdentifier(_ profileID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("claude-switcher.terminal.\(profileID)")
    }

    /// The terminal CLI's sign-in for an account; `nil` until the Keychain probe has answered.
    /// "No sign-in found" and not "not signed in": the probe looks for one Keychain item, and
    /// says the same for a failed lookup or a CLI that is signed in some other way.
    static func hintText(signedIn: Bool?) -> String? {
        switch signedIn {
        case .some(true):  return "signed in"
        case .some(false): return "no sign-in found"
        case nil:          return nil
        }
    }

    /// The hint is a trailing badge (it stays legible while the item is highlighted), and the
    /// tooltip says what to do about a "no sign-in found".
    static func applyHint(to item: NSMenuItem, profile: Profile, signedIn: Bool?) {
        item.badge = hintText(signedIn: signedIn).map { NSMenuItemBadge(string: $0) }
        var lines = [
            "Copies:  \(Diagnostics.terminalCommand(for: profile))",
            "Run it in a terminal to use the claude CLI as this account. ~/.claude stays shared.",
        ]
        if signedIn == false {
            lines.append("No terminal sign-in was found for this account. That is only the terminal CLI \u{2014} the Claude app has its own sign-in. Sign in once, in the terminal, after running the command.")
        }
        item.toolTip = lines.joined(separator: "\n")
    }

    /// Refreshes only the sign-in hints of an already-built menu, so a Keychain probe that
    /// lands while the menu is open updates in place instead of rebuilding it underneath
    /// the user's cursor.
    static func updateHints(in menu: NSMenu, config: Config, signInStates: [String: Bool]) {
        guard let terminalMenu = menu.items.first(where: { $0.identifier == terminalMenuIdentifier })?.submenu else { return }
        for profile in config.profiles {
            let identifier = terminalItemIdentifier(profile.id)
            guard let item = terminalMenu.items.first(where: { $0.identifier == identifier }) else { continue }
            applyHint(to: item, profile: profile, signedIn: signInStates[profile.id])
        }
    }

    // MARK: - Pieces

    static func runningSummary(_ input: Input) -> String {
        let labels = input.config.profiles
            .filter { ProfileMatching.isRunning($0, in: input.running) }
            .map(\.label)
        let strays = ProfileMatching.unmatched(input.running, profiles: input.config.profiles).count

        if labels.isEmpty {
            return strays == 0
                ? "Claude is not running"
                : "Running: \(strays) unrecognized instance\(strays == 1 ? "" : "s")"
        }
        var summary = "Running: \(labels.joined(separator: ", "))"
        if strays > 0 {
            summary += " (+\(strays) unrecognized)"
        }
        return summary
    }

    static func profileToolTip(_ profile: Profile, input: Input) -> String {
        var lines: [String] = []
        if let instance = ProfileMatching.instance(for: profile, in: input.running) {
            lines.append("Running (pid \(instance.pid)) \u{2014} selecting brings its window to the front, reopening it if it was closed.")
        } else {
            lines.append("Not running \u{2014} selecting starts it alongside your other accounts.")
        }
        if let dir = profile.userDataDir {
            lines.append("Desktop account data: \(PathNormalizer.normalize(dir))")
        } else {
            lines.append("Desktop account data: Claude\u{2019}s own default folder.")
        }
        lines.append("~/.claude (skills, agents, memory, settings, transcripts) is shared by every account; chats and the Code tab\u{2019}s session list are not.")
        return lines.joined(separator: "\n")
    }

    static func informationalItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
