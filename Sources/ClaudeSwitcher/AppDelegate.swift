import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import ClaudeSwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var config: Config = .defaultConfig()
    private var configError: String?
    private var running: [RunningInstance] = []

    /// profile id -> terminal CLI sign-in, from the most recent background Keychain
    /// existence probe. A missing entry renders as "terminal: unknown"; the menu never
    /// blocks waiting for one.
    private var signInStates: [String: Bool] = [:]
    private var isProbingSignIn = false

    /// Launches are serialized: while one is in flight the profile items are disabled and
    /// re-enabled from the completion handler, success or failure.
    private var isBusy = false
    private var launchGeneration = 0
    private var isMenuOpen = false
    private var didWarnAboutMissingCLI = false

    /// Alerts are serialized. A background probe can finish while the user is in the open
    /// panel or a confirmation sheet, and stacking modals on top of each other is a trap.
    private var isPresentingModal = false
    private var pendingAlerts: [PendingAlert] = []

    private static let actions = MenuBuilder.Actions(
        selectProfile: #selector(selectProfile(_:)),
        copyTerminalCommand: #selector(copyTerminalCommand(_:)),
        addProfile: #selector(addProfile(_:)),
        removeProfile: #selector(removeProfile(_:)),
        chooseClaudeApp: #selector(chooseClaudeApp(_:)),
        revealSharedDirectory: #selector(revealSharedDirectory(_:)),
        showDiagnostics: #selector(showDiagnostics(_:)),
        toggleLaunchAtLogin: #selector(toggleLaunchAtLogin(_:)),
        quit: #selector(quit(_:))
    )

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        reloadConfig()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Claude Switcher") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Claude"
            }
            button.toolTip = "Claude Switcher"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item

        refreshSignInStates()
        checkCLIAvailability()
        promptForClaudeAppIfMissing()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        isMenuOpen = true
        reloadConfig()
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        refreshSignInStates()
        rebuild(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func rebuild(_ menu: NSMenu) {
        let input = MenuBuilder.Input(
            config: config,
            running: running,
            signInStates: signInStates,
            isBusy: isBusy,
            configError: configError,
            claudeAppExists: FileManager.default.fileExists(atPath: PathNormalizer.normalize(config.claudeAppPath)),
            launchAtLogin: launchAtLoginState()
        )
        let built = MenuBuilder.build(input, target: self, actions: Self.actions)
        // An NSMenuItem belongs to one menu, so detach before re-parenting.
        let items = built.items
        built.removeAllItems()
        menu.removeAllItems()
        for item in items { menu.addItem(item) }
        menu.autoenablesItems = false
    }

    private func rebuildIfVisible() {
        guard isMenuOpen, let menu = statusItem?.menu else { return }
        rebuild(menu)
    }

    // MARK: - Config

    private func reloadConfig() {
        do {
            config = try Config.load()
            configError = nil
        } catch {
            // Keep the last good config so a hand-edit typo cannot empty the menu.
            configError = error.localizedDescription
        }
    }

    private func saveConfig(failureTitle: String) {
        do {
            try config.save()
        } catch {
            presentAlert(
                style: .warning,
                title: failureTitle,
                message: "Could not write \(Config.configURL.path).\n\n\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Background probes

    /// Keychain existence checks shell out, so they run off the main thread and are cached
    /// for the menu to read. Existence only: no secret is ever read.
    private func refreshSignInStates() {
        guard !isProbingSignIn else { return }
        isProbingSignIn = true
        let queries = config.profiles.map { Diagnostics.ProfileQuery(id: $0.id, credDir: $0.credDir) }
        Task.detached(priority: .utility) {
            var states: [String: Bool] = [:]
            for query in queries {
                states[query.id] = KeychainProbe.isSignedIn(credDir: query.credDir)
            }
            // Bind an immutable copy before the actor hop: capturing the mutable `var`
            // is rejected under the Swift 6 language mode this package uses.
            let snapshot = states
            await MainActor.run { self.applySignInStates(snapshot) }
        }
    }

    private func applySignInStates(_ states: [String: Bool]) {
        isProbingSignIn = false
        mergeSignInStates(states)
    }

    private func mergeSignInStates(_ states: [String: Bool]) {
        guard states != signInStates else { return }
        signInStates = states
        // Update hints in place rather than rebuilding a menu the user is pointing at.
        if isMenuOpen, let menu = statusItem?.menu {
            MenuBuilder.updateHints(in: menu, config: config, signInStates: signInStates)
        }
    }

    /// Resolves the claude CLI two ways and warns once per run if neither is present.
    /// Note: the Desktop Code tab runs the app-managed sidecar under
    /// ~/Library/Application Support/Claude/claude-code/<version>/..., NOT the PATH binary;
    /// the PATH binary is what "Copy terminal command" drives. Startup never blocks on this.
    private func checkCLIAvailability() {
        Task.detached(priority: .utility) {
            let probe = Diagnostics.probeCLI()
            await MainActor.run { self.handleCLIProbe(probe) }
        }
    }

    private func handleCLIProbe(_ probe: Diagnostics.CLIProbe) {
        guard !probe.isResolved, !didWarnAboutMissingCLI else { return }
        didWarnAboutMissingCLI = true
        presentAlert(
            style: .informational,
            title: "Claude CLI not found",
            message: """
            No claude binary was found on your PATH, and no app-managed sidecar was found under \
            ~/Library/Application Support/Claude/claude-code.

            Switching Claude Desktop profiles still works \u{2014} that only needs Claude.app. The \
            copied terminal commands will not run until the claude CLI is installed.
            """
        )
    }

    // MARK: - Actions: profiles

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard !isBusy,
              let id = sender.representedObject as? String,
              let profile = config.profile(id: id) else { return }
        beginLaunch(profile)
    }

    /// Focuses this profile's instance, or launches one. Shared by the profile list and by
    /// "Add Profile…", which launches the new profile straight away so the user lands on its
    /// sign-in screen instead of having to find it in the menu afterwards.
    private func beginLaunch(_ profile: Profile) {
        guard !isBusy else { return }
        let id = profile.id

        // Already up for this profile: focus it. Never launch a second copy against the same
        // user-data dir — two Electron processes would fight over the profile lock.
        if let instance = ProfileMatching.instance(for: profile, in: running),
           InstanceManager.activate(pid: instance.pid,
                                    expecting: InstanceManager.bundleIdentifier(appPath: config.claudeAppPath)) {
            markActive(id)
            return
        }

        // If some running instance's argv could not be read, we cannot prove it is NOT this
        // profile's. Launching anyway risks a second Electron process on the same user-data
        // dir — two Chromium processes over one LevelDB store, which can corrupt that login.
        // Rare, so ask rather than refuse.
        let unreadable = running.filter { $0.profile == .unknown }
        if !unreadable.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Claude is running, but one instance could not be identified"
            alert.informativeText = """
            \(unreadable.count == 1 ? "A running Claude process" : "\(unreadable.count) running Claude processes") \
            did not report a command line, so Claude Switcher cannot tell which profile \
            \(unreadable.count == 1 ? "it belongs" : "they belong") to.

            Starting \u{201C}\(profile.label)\u{201D} now could open a second window on a profile that is \
            already in use. If a window for this profile is already open, switch to it instead.
            """
            alert.addButton(withTitle: "Start Anyway")
            alert.addButton(withTitle: "Cancel")
            guard runModal(alert) == .alertFirstButtonReturn else { return }
        }

        isBusy = true
        launchGeneration &+= 1
        let generation = launchGeneration
        rebuildIfVisible()
        startLaunchWatchdog(for: generation)

        let label = profile.label   // captured as a String: nothing non-Sendable crosses
        InstanceManager.launch(profile: profile, appPath: config.claudeAppPath) { result in
            let outcome: LaunchOutcome
            switch result {
            case .success(let pid):
                outcome = LaunchOutcome(generation: generation, profileID: id, profileLabel: label, pid: pid, errorMessage: nil)
            case .failure(let error):
                outcome = LaunchOutcome(generation: generation, profileID: id, profileLabel: label, pid: nil, errorMessage: error.localizedDescription)
            }
            Task { @MainActor in self.launchDidFinish(outcome) }
        }
    }

    /// If a completion handler never arrives, the menu must not stay disabled forever.
    private func startLaunchWatchdog(for generation: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard self.isBusy, self.launchGeneration == generation else { return }
            self.isBusy = false
            self.rebuildIfVisible()
        }
    }

    private struct LaunchOutcome: Sendable {
        let generation: Int
        let profileID: String
        let profileLabel: String
        let pid: pid_t?
        let errorMessage: String?
    }

    private func launchDidFinish(_ outcome: LaunchOutcome) {
        // Ignore a completion from a launch the watchdog already gave up on (or that a newer
        // launch superseded). Without this, a late arrival would clear `isBusy` in the middle
        // of the *current* launch and mark the wrong profile active.
        guard outcome.generation == launchGeneration else { return }
        isBusy = false
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        rebuildIfVisible()

        if let message = outcome.errorMessage {
            presentAlert(
                style: .warning,
                title: "Could not start \u{201C}\(outcome.profileLabel)\u{201D}",
                message: message
            )
        } else {
            markActive(outcome.profileID)
        }
    }

    private func markActive(_ id: String) {
        guard config.activeProfileId != id else { return }
        do {
            try config.setActive(id: id)
            try config.save()
        } catch {
            // Remembering the last profile is a convenience; a failure must not interrupt.
            configError = error.localizedDescription
        }
    }

    @objc private func copyTerminalCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = config.profile(id: id) else { return }
        let command = Diagnostics.terminalCommand(for: profile)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @objc private func addProfile(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Add a profile"
        alert.informativeText = """
        A profile is a separate Claude Desktop login \u{2014} its own account for both chat and the \
        Code tab \u{2014} that runs alongside your other profiles.

        Your ~/.claude stays shared: projects, session history, skills, agents, plugins, memory \
        and settings follow you into every profile.

        Claude opens on this profile as soon as you add it, so you can sign in to the account \
        you want to use. Claude Switcher never handles your credentials.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard runModal(alert) == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }

        let slug = uniqueSlug(for: label)
        let home = NSHomeDirectory()
        let profile = Profile(
            id: slug,
            label: label,
            userDataDir: PathNormalizer.normalize("\(home)/Library/Application Support/Claude-\(slug)"),
            credDir: PathNormalizer.normalize("\(home)/.claude-accounts/\(slug)")
        )

        do {
            try config.addProfile(profile)
        } catch {
            presentAlert(style: .warning, title: "Could not add \u{201C}\(label)\u{201D}", message: error.localizedDescription)
            return
        }
        saveConfig(failureTitle: "Could not save the new profile")
        refreshSignInStates()
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)

        // Launch it right away: a brand-new profile has no login yet, so this puts the user
        // straight on its sign-in screen. That is the whole point of adding one.
        beginLaunch(profile)
    }

    @objc private func removeProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = config.profile(id: id) else { return }

        var details = [
            "Claude Switcher only forgets this profile. Nothing on disk is deleted \u{2014} re-adding it with the same directories restores it, still signed in."
        ]
        if let dir = profile.userDataDir {
            details.append("Desktop account data stays at:\n\(PathNormalizer.normalize(dir))")
        }
        if let dir = profile.credDir {
            details.append("Terminal CLI credential dir stays at:\n\(PathNormalizer.normalize(dir))")
        }
        details.append("Its Keychain item is left untouched, and ~/.claude is shared \u{2014} never affected.")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove the profile \u{201C}\(profile.label)\u{201D}?"
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: "Remove Profile")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard runModal(alert) == .alertFirstButtonReturn else { return }

        do {
            try config.removeProfile(id: id)
        } catch {
            presentAlert(style: .warning, title: "Could not remove \u{201C}\(profile.label)\u{201D}", message: error.localizedDescription)
            return
        }
        saveConfig(failureTitle: "Could not save the change")
        signInStates.removeValue(forKey: id)
    }

    /// Lowercased, dash-separated, unique against the existing ids. The slug also names the
    /// auto-assigned directories, so it stays filesystem-safe.
    private func uniqueSlug(for label: String) -> String {
        var slug = ""
        var lastWasDash = true
        for scalar in label.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "profile" }

        guard config.profile(id: slug) != nil else { return slug }
        var suffix = 2
        while config.profile(id: "\(slug)-\(suffix)") != nil { suffix += 1 }
        return "\(slug)-\(suffix)"
    }

    // MARK: - Actions: app level

    private func promptForClaudeAppIfMissing() {
        guard !FileManager.default.fileExists(atPath: PathNormalizer.normalize(config.claudeAppPath)) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Claude.app not found"
        alert.informativeText = "Nothing is at \(config.claudeAppPath). Choose where Claude is installed."
        alert.addButton(withTitle: "Choose\u{2026}")
        alert.addButton(withTitle: "Later")
        guard runModal(alert) == .alertFirstButtonReturn else { return }
        chooseClaudeApp(nil)
    }

    @objc private func chooseClaudeApp(_ sender: NSMenuItem?) {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude.app"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        let response = withModal { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        config.claudeAppPath = PathNormalizer.normalize(url.path)
        saveConfig(failureTitle: "Could not save the Claude.app location")
    }

    @objc private func revealSharedDirectory(_ sender: NSMenuItem) {
        // Always ~/.claude: this app never sets or honors a different CLAUDE_CONFIG_DIR.
        let url = Diagnostics.sharedConfigDirectory
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentAlert(
                style: .informational,
                title: "~/.claude does not exist yet",
                message: "It appears the first time Claude Code runs. Every profile will share it."
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func showDiagnostics(_ sender: NSMenuItem) {
        reloadConfig()
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        let appPath = config.claudeAppPath
        let queries = config.profiles.map { Diagnostics.ProfileQuery(id: $0.id, credDir: $0.credDir) }

        Task {
            let probe = await Task.detached(priority: .userInitiated) {
                Diagnostics.probe(appPath: appPath, profiles: queries)
            }.value
            self.mergeSignInStates(probe.signedIn)
            self.presentDiagnostics(Diagnostics.report(config: self.config, running: self.running, probe: probe))
        }
    }

    private func presentDiagnostics(_ report: String) {
        let size = NSSize(width: 660, height: 420)
        let textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = report
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        let alert = NSAlert()
        alert.messageText = "Diagnostics"
        alert.informativeText = "Sign-in lines are existence checks only \u{2014} no Keychain secret is ever read."
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")

        if runModal(alert) == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    // MARK: - Actions: launch at login

    private func launchAtLoginState() -> MenuBuilder.LaunchAtLogin {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        case .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            presentAlert(
                style: .warning,
                title: "Could not change Launch at Login",
                message: "\(error.localizedDescription)\n\nLogin items require claude-switcher to be installed as an app bundle."
            )
            return
        }
        if SMAppService.mainApp.status == .requiresApproval {
            presentAlert(
                style: .informational,
                title: "Approval needed",
                message: "Enable claude-switcher in System Settings \u{203A} General \u{203A} Login Items."
            )
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private struct PendingAlert {
        let style: NSAlert.Style
        let title: String
        let message: String
    }

    /// Runs a modal with the app frontmost, holding back queued alerts until it returns.
    private func withModal<T>(_ body: () -> T) -> T {
        isPresentingModal = true
        NSApp.activate()
        defer {
            isPresentingModal = false
            drainPendingAlerts()
        }
        return body()
    }

    @discardableResult
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        withModal { alert.runModal() }
    }

    private func presentAlert(style: NSAlert.Style, title: String, message: String) {
        pendingAlerts.append(PendingAlert(style: style, title: title, message: message))
        drainPendingAlerts()
    }

    private func drainPendingAlerts() {
        guard !isPresentingModal else { return }
        while !pendingAlerts.isEmpty {
            let pending = pendingAlerts.removeFirst()
            let alert = NSAlert()
            alert.alertStyle = pending.style
            alert.messageText = pending.title
            alert.informativeText = pending.message
            alert.addButton(withTitle: "OK")
            isPresentingModal = true
            NSApp.activate()
            alert.runModal()
            isPresentingModal = false
        }
    }
}
