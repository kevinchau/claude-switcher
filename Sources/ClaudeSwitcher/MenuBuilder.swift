import AppKit
import ClaudeSwitcherCore

/// Builds the status-item menu from a snapshot of state. Side-effect free: it reads the
/// values handed to it (including an already-computed Keychain existence cache) and never
/// performs I/O, so opening the menu can never block on a `security` call or a subprocess.
@MainActor
enum MenuBuilder {

    // MARK: - Inputs

    enum LaunchAtLogin: Sendable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    struct Actions: Sendable {
        var selectProfile: Selector
        var copyTerminalCommand: Selector
        var addProfile: Selector
        var removeProfile: Selector
        var chooseClaudeApp: Selector
        var revealSharedDirectory: Selector
        var showDiagnostics: Selector
        var toggleLaunchAtLogin: Selector
        var quit: Selector
    }

    struct Input {
        var config: Config
        var running: [RunningInstance]
        /// profile id -> terminal CLI sign-in. A missing entry renders as "unknown"
        /// rather than blocking the rebuild on a Keychain existence check.
        var signInStates: [String: Bool]
        var isBusy: Bool
        var configError: String?
        var claudeAppExists: Bool
        var launchAtLogin: LaunchAtLogin
    }

    // MARK: - Build

    static func build(_ input: Input, target: AnyObject, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(informationalItem(runningSummary(input)))

        if let error = input.configError {
            menu.addItem(informationalItem("Config problem: \(error)"))
            menu.addItem(informationalItem("Showing the last good settings. Fix \(Config.configURL.lastPathComponent) and reopen this menu."))
        }
        if !input.claudeAppExists {
            menu.addItem(informationalItem("Claude.app not found at \(input.config.claudeAppPath)"))
            menu.addItem(informationalItem("Pick it with \u{201C}Choose Claude.app\u{2026}\u{201D} below."))
        }
        if input.isBusy {
            menu.addItem(informationalItem("Starting Claude\u{2026}"))
        }

        menu.addItem(.separator())

        // MARK: Profiles
        if input.config.profiles.isEmpty {
            menu.addItem(informationalItem("No profiles configured."))
        }
        for profile in input.config.profiles {
            let item = NSMenuItem(title: profile.label, action: actions.selectProfile, keyEquivalent: "")
            item.target = target
            item.representedObject = profile.id
            item.identifier = profileItemIdentifier(profile.id)
            item.state = ProfileMatching.isRunning(profile, in: input.running) ? .on : .off
            item.isEnabled = !input.isBusy && input.claudeAppExists
            applyHint(to: item, label: profile.label, signedIn: input.signInStates[profile.id])
            item.toolTip = profileToolTip(profile, input: input)
            menu.addItem(item)
        }
        if !input.config.profiles.isEmpty {
            menu.addItem(informationalItem("\u{201C}terminal:\u{201D} is the claude CLI sign-in only \u{2014} not the Claude app."))
        }

        menu.addItem(.separator())

        // MARK: Copy terminal command
        let copyItem = NSMenuItem(title: "Copy terminal command", action: nil, keyEquivalent: "")
        let copyMenu = NSMenu()
        copyMenu.autoenablesItems = false
        if input.config.profiles.isEmpty {
            copyMenu.addItem(informationalItem("No profiles"))
        }
        for profile in input.config.profiles {
            let command = Diagnostics.terminalCommand(for: profile)
            let sub = NSMenuItem(title: profile.label, action: actions.copyTerminalCommand, keyEquivalent: "")
            sub.target = target
            sub.representedObject = profile.id
            sub.isEnabled = true
            sub.toolTip = "Copies:  \(command)\nRun it in a terminal to use the claude CLI as this profile. ~/.claude stays shared."
            copyMenu.addItem(sub)
        }
        copyItem.submenu = copyMenu
        menu.addItem(copyItem)

        // MARK: Add profile
        let addItem = NSMenuItem(title: "Add Profile\u{2026}", action: actions.addProfile, keyEquivalent: "")
        addItem.target = target
        addItem.isEnabled = !input.isBusy
        menu.addItem(addItem)

        // MARK: Remove profile
        let removeItem = NSMenuItem(title: "Remove Profile", action: nil, keyEquivalent: "")
        let removeMenu = NSMenu()
        removeMenu.autoenablesItems = false
        if input.config.profiles.isEmpty {
            removeMenu.addItem(informationalItem("No profiles"))
        }
        for profile in input.config.profiles {
            let isDefault = profile.isDefaultProfile
            let isActive = profile.id == input.config.activeProfileId
            var title = profile.label
            if isDefault {
                title += " (default profile)"
            } else if isActive {
                title += " (active)"
            }
            let sub = NSMenuItem(title: title, action: actions.removeProfile, keyEquivalent: "")
            sub.target = target
            sub.representedObject = profile.id
            sub.isEnabled = !isDefault && !isActive && !input.isBusy
            if isDefault {
                sub.toolTip = "The default profile cannot be removed."
            } else if isActive {
                sub.toolTip = "This profile is active. Switch to another profile first."
            } else {
                sub.toolTip = "Forgets the profile. Nothing on disk is deleted."
            }
            removeMenu.addItem(sub)
        }
        removeItem.submenu = removeMenu
        menu.addItem(removeItem)

        menu.addItem(.separator())

        // MARK: App-level items
        let chooseItem = NSMenuItem(title: "Choose Claude.app\u{2026}", action: actions.chooseClaudeApp, keyEquivalent: "")
        chooseItem.target = target
        chooseItem.toolTip = "Currently: \(input.config.claudeAppPath)"
        menu.addItem(chooseItem)

        let revealItem = NSMenuItem(title: "Reveal ~/.claude in Finder", action: actions.revealSharedDirectory, keyEquivalent: "")
        revealItem.target = target
        revealItem.toolTip = "Projects, session history, skills, agents, plugins, memory and settings \u{2014} shared by every profile."
        menu.addItem(revealItem)

        let diagnosticsItem = NSMenuItem(title: "Diagnostics\u{2026}", action: actions.showDiagnostics, keyEquivalent: "")
        diagnosticsItem.target = target
        menu.addItem(diagnosticsItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: actions.toggleLaunchAtLogin, keyEquivalent: "")
        loginItem.target = target
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
            loginItem.toolTip = "Available once claude-switcher is installed as an app bundle."
        }
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Claude Switcher", action: actions.quit, keyEquivalent: "q")
        quitItem.target = target
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Hints

    static func profileItemIdentifier(_ profileID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("claude-switcher.profile.\(profileID)")
    }

    static func hintText(signedIn: Bool?) -> String {
        switch signedIn {
        case .some(true):  return "terminal: signed in"
        case .some(false): return "terminal: no credentials found"
        case nil:          return "terminal: unknown"
        }
    }

    /// The hint is a trailing badge where the OS supports one (it stays legible while the
    /// item is highlighted); otherwise it is appended to the title.
    static func applyHint(to item: NSMenuItem, label: String, signedIn: Bool?) {
        let hint = hintText(signedIn: signedIn)
        if #available(macOS 14.0, *) {
            item.title = label
            item.badge = NSMenuItemBadge(string: hint)
        } else {
            item.title = "\(label)  \u{2014}  \(hint)"
        }
    }

    /// Refreshes only the sign-in hints of an already-built menu, so a Keychain probe that
    /// lands while the menu is open updates in place instead of rebuilding it underneath
    /// the user's cursor.
    static func updateHints(in menu: NSMenu, config: Config, signInStates: [String: Bool]) {
        for profile in config.profiles {
            let identifier = profileItemIdentifier(profile.id)
            guard let item = menu.items.first(where: { $0.identifier == identifier }) else { continue }
            applyHint(to: item, label: profile.label, signedIn: signInStates[profile.id])
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
            lines.append("Running (pid \(instance.pid)) \u{2014} selecting brings it to the front.")
        } else {
            lines.append("Not running \u{2014} selecting starts it alongside any other profile.")
        }
        if let dir = profile.userDataDir {
            lines.append("Desktop account data: \(PathNormalizer.normalize(dir))")
        } else {
            lines.append("Desktop account data: the app's own default profile.")
        }
        lines.append("\(hintText(signedIn: input.signInStates[profile.id])) \u{2014} this reflects the terminal claude CLI only.")
        lines.append("~/.claude (projects, history, skills, agents, memory, settings) is shared by every profile.")
        return lines.joined(separator: "\n")
    }

    static func informationalItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
