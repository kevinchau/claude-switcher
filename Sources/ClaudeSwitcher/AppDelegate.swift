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

    /// profile id -> the usage Claude Desktop last recorded for that profile, read from its
    /// own `plan-usage-history.json` when the menu opens. Read-only; never fetched.
    private var usage: [String: UsageReading] = [:]

    /// Reopening profiles after Claude updates itself — the one thing this app does on its own
    /// initiative, and it can only launch (see `UpdateReopen`). Single-flight: a trigger that
    /// arrives mid-run re-arms one more pass rather than starting a second.
    private var isConsideringReopen = false
    private var reopenRearmed = false
    /// profile id -> timestamp of the update marker already acted on, so none is acted on twice.
    private var handledAttempts: [String: Date] = [:]
    /// Shown once, on the next menu open, so an automatic reopen is never silent.
    private var autoReopenNotice: String?
    private var autoReopenNoticeWasShown = false
    /// One delayed second look per outside trigger, for a run that ended busy or with the
    /// installer still going. Bounded: a retry never schedules another.
    private var reopenRetryAvailable = true
    /// Held for the life of the process by the one switcher allowed to act on its own
    /// initiative (see `AutomationLock`). `nil`: another switcher is running — do nothing automatic.
    private var automationLock: Int32?

    /// Launches are serialized: while one is in flight the profile items are disabled and
    /// re-enabled from the completion handler, success or failure.
    private var isBusy = false
    private var launchGeneration = 0
    private var isMenuOpen = false
    private var didWarnAboutMissingCLI = false

    /// A downloaded Claude update whose installer is waiting on the running instances, as of
    /// the last time the menu opened.
    private var blockedUpdate: StagedUpdate?
    /// Non-nil for the duration of "Quit All & Install Update…". `isBusy` is held throughout,
    /// so no profile can be launched into the middle of it.
    private var updateProgress: String?

    /// Alerts are serialized. A background probe can finish while the user is in the open
    /// panel or a confirmation sheet, and stacking modals on top of each other is a trap.
    private var isPresentingModal = false
    private var pendingAlerts: [PendingAlert] = []

    private static let actions = MenuBuilder.Actions(
        selectProfile: #selector(selectProfile(_:)),
        copyTerminalCommand: #selector(copyTerminalCommand(_:)),
        addProfile: #selector(addProfile(_:)),
        renameProfile: #selector(renameProfile(_:)),
        removeProfile: #selector(removeProfile(_:)),
        chooseClaudeApp: #selector(chooseClaudeApp(_:)),
        revealSharedDirectory: #selector(revealSharedDirectory(_:)),
        showDiagnostics: #selector(showDiagnostics(_:)),
        toggleLaunchAtLogin: #selector(toggleLaunchAtLogin(_:)),
        toggleReopenAfterUpdate: #selector(toggleReopenAfterUpdate(_:)),
        toggleBlockUpdates: #selector(toggleBlockUpdates(_:)),
        installUpdate: #selector(installUpdate(_:)),
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

        // Claude's installer relaunches it with no arguments, so after an update only the
        // default profile comes back. Watch for instances going away, and for wake (a missed
        // notification), and look once now in case the update happened before we started.
        // Delivered on the main queue by request: where AppKit posts these is convention, not
        // contract, and an off-main delivery into main-actor code would trap.
        automationLock = AutomationLock.acquire()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.applicationDidTerminate(bundleID: bundleID) }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outsideTriggerForReopen() }
        }

        refreshSignInStates()
        checkCLIAvailability()
        promptForClaudeAppIfMissing()
        reconcileUpdateBlock()
        outsideTriggerForReopen()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        isMenuOpen = true
        reloadConfig()
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        // Read-only and quick: one small JSON file, two Info.plists, a process-name scan.
        blockedUpdate = UpdateProbe.status(appPath: config.claudeAppPath).blocked
        usage = Self.readUsage(for: config.profiles)
        refreshSignInStates()
        rebuild(menu)
    }

    /// Each profile's history is a small JSON file (about 27 KB after a month); reading them
    /// all is well under a millisecond, in the same class as the other read-only probes here.
    private static func readUsage(for profiles: [Profile]) -> [String: UsageReading] {
        let now = Date()
        var readings: [String: UsageReading] = [:]
        for profile in profiles {
            guard let samples = UsageHistory.read(userDataDir: profile.userDataDir),
                  let reading = UsageReading.make(samples: samples, now: now) else { continue }
            readings[profile.id] = reading
        }
        return readings
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if autoReopenNoticeWasShown {   // only once it has actually been on screen
            autoReopenNotice = nil
            autoReopenNoticeWasShown = false
        }
    }

    private func rebuild(_ menu: NSMenu) {
        let input = MenuBuilder.Input(
            config: config,
            running: running,
            signInStates: signInStates,
            isBusy: isBusy,
            configError: configError,
            claudeAppExists: FileManager.default.fileExists(atPath: PathNormalizer.normalize(config.claudeAppPath)),
            launchAtLogin: launchAtLoginState(),
            blockedUpdate: blockedUpdate,
            updateProgress: updateProgress,
            usage: usage,
            now: Date(),
            autoReopenNotice: autoReopenNotice
        )
        if isMenuOpen, autoReopenNotice != nil { autoReopenNoticeWasShown = true }
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

    @discardableResult
    private func saveConfig(failureTitle: String) -> Bool {
        do {
            try config.save()
            return true
        } catch {
            presentAlert(
                style: .warning,
                title: failureTitle,
                message: "Could not write \(Config.configURL.path).\n\n\(error.localizedDescription)"
            )
            return false
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
            // Main-actor work keeps running underneath a modal: an update install may have
            // started while this one was up, and nothing may be launched into the middle of it.
            guard !isBusy else { return }
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
        if config.blockClaudeUpdates {
            // Before its first launch, so the new profile's updater never starts either.
            _ = try? UpdateBlock.apply(userDataDir: profile.userDataDir)
        }
        refreshSignInStates()
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)

        // Launch it right away: a brand-new profile has no login yet, so this puts the user
        // straight on its sign-in screen. That is the whole point of adding one.
        beginLaunch(profile)
    }

    /// Label only. The id and both directories are the profile's identity and never change.
    @objc private func renameProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = config.profile(id: id) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename \u{201C}\(profile.label)\u{201D}"
        alert.informativeText = "Only the name in the menu changes. The profile keeps its directories, its sign-ins and its id (\(profile.id))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = profile.label
        field.placeholderString = profile.label
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard runModal(alert) == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != profile.label else { return }

        do {
            try config.renameProfile(id: id, label: label)
        } catch {
            presentAlert(style: .warning, title: "Could not rename \u{201C}\(profile.label)\u{201D}", message: error.localizedDescription)
            return
        }
        saveConfig(failureTitle: "Could not save the new name")
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
        if UpdateBlock.state(userDataDir: profile.userDataDir) == .on {
            details.append("The update-block policy file Claude Switcher wrote for it is removed, so that re-adding the profile later does not silently keep it from updating.")
        }

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
        usage.removeValue(forKey: id)
        // Ours to clean up — and only if it is still exactly ours. Everything else stays.
        _ = try? UpdateBlock.remove(userDataDir: profile.userDataDir)
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
        // `Claude-<slug>` must not end in "-3p": Claude keeps policy files in such directories,
        // and `Claude-3p` is the default profile's.
        if slug == "3p" || slug.hasSuffix("-3p") { slug += "-profile" }

        guard config.profile(id: slug) != nil else { return slug }
        var suffix = 2
        while config.profile(id: "\(slug)-\(suffix)") != nil { suffix += 1 }
        return "\(slug)-\(suffix)"
    }

    // MARK: - Actions: blocked update

    /// The only path by which this app ever asks Claude to quit: this menu item, then an
    /// explicit confirmation. Nothing that quits anything runs on its own initiative — the one
    /// automatic behaviour in this app, `considerReopenAfterUpdate`, can only launch.
    @objc private func installUpdate(_ sender: NSMenuItem) {
        // The status menu still opens while an alert is up, so this can be reached from inside
        // another modal — including its own confirmation.
        guard !isBusy, updateProgress == nil, !isPresentingModal else { return }
        let appPath = config.claudeAppPath

        guard let bundleID = InstanceManager.bundleIdentifier(appPath: appPath),
              let update = UpdateProbe.status(appPath: appPath).blocked else {
            blockedUpdate = nil
            presentAlert(
                style: .informational,
                title: "No update is waiting any more",
                message: "Claude\u{2019}s installer is no longer waiting on a downloaded update, so there is nothing to make room for. Nothing was quit."
            )
            return
        }

        running = InstanceManager.runningInstances(appPath: appPath)
        let plan = UpdateInstaller.plan(running: running, profiles: config.profiles)
        guard !plan.quit.isEmpty else { return }

        var details = [
            "Claude\u{2019}s installer only runs once every Claude instance has quit. With \(plan.quit.count == 1 ? "a profile" : "\(plan.quit.count) instances") open it has been waiting \u{2014} and a profile that quits itself to be updated never comes back."
        ]
        if !plan.reopen.isEmpty {
            details.append("Will quit, then reopen:  \(plan.reopen.map(\.label).joined(separator: ", "))")
        }
        if !plan.strays.isEmpty {
            details.append("Will quit and NOT reopen:  \(plan.strays.count) unrecognized instance\(plan.strays.count == 1 ? "" : "s") (no profile to reopen \(plan.strays.count == 1 ? "it" : "them") from)")
        }
        details.append("Anything Claude is doing right now \u{2014} a response being written, a task running in the Code tab \u{2014} is interrupted, as with any quit.")
        details.append("Claude Switcher only asks Claude to quit, the same as \u{2318}Q. The update itself is installed by Claude\u{2019}s own installer.")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit every Claude profile to install Claude \(update.staged)?"
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: "Quit All & Install")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard runModal(alert) == .alertFirstButtonReturn else { return }
        // Main-actor work keeps running underneath a modal; something may have started meanwhile.
        guard !isBusy else { return }

        isBusy = true
        // Retire any launch watchdog still sleeping: it clears `isBusy` for its own generation.
        launchGeneration &+= 1
        setUpdateProgress("Installing update\u{2026}")

        let environment = UpdateInstaller.Environment.live(appPath: appPath, bundleID: bundleID)
        Task { @MainActor in
            let outcome = await UpdateInstaller.run(plan: plan, environment: environment) { phase in
                self.setUpdateProgress(self.progressText(for: phase, update: update))
            }
            self.updateDidFinish(outcome, update: update)
        }
    }

    /// Rebuilds only when the text changes: the quitting phase reports on every poll, and a
    /// menu must not be rebuilt twice a second underneath the user's cursor.
    private func setUpdateProgress(_ text: String?) {
        guard text != updateProgress else { return }
        updateProgress = text
        rebuildIfVisible()
    }

    private func progressText(for phase: UpdateInstaller.Phase, update: StagedUpdate) -> String {
        switch phase {
        case .quitting(let instances):
            return "Installing update: waiting for \(describe(instances)) to quit\u{2026}"
        case .installing:
            return "Installing Claude \(update.staged)\u{2026}"
        case .reopening(let profile):
            return "Reopening \u{201C}\(profile.label)\u{201D}\u{2026}"
        }
    }

    /// "Personal, Christy" where the instances map to profiles, a count otherwise.
    private func describe(_ instances: [RunningInstance]) -> String {
        let labels = config.profiles
            .filter { ProfileMatching.isRunning($0, in: instances) }
            .map(\.label)
        let others = instances.count - labels.count
        var parts = labels
        if others > 0 { parts.append("\(others) unrecognized instance\(others == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private func updateDidFinish(_ outcome: UpdateInstaller.Outcome, update: StagedUpdate) {
        isBusy = false
        updateProgress = nil
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        blockedUpdate = UpdateProbe.status(appPath: config.claudeAppPath).blocked
        rebuildIfVisible()

        func list(_ profiles: [Profile]) -> String { profiles.map(\.label).joined(separator: ", ") }

        switch outcome {
        case .installed(_, let notReopened) where notReopened.isEmpty:
            break   // Claude is back, updated. Nothing to add.

        case .installed(let version, let notReopened):
            presentAlert(
                style: .warning,
                title: "Claude updated to \(version), but not everything reopened",
                message: "Could not reopen: \(list(notReopened)). Open \(notReopened.count == 1 ? "it" : "them") from the menu."
            )

        case .notInstalled(let notReopened):
            var message = "Every profile quit, but Claude\u{2019}s installer finished without changing the app \u{2014} it is still \(update.installed). Claude will try again at its next update check."
            message += notReopened.isEmpty
                ? "\n\nYour profiles were reopened."
                : "\n\nCould not reopen: \(list(notReopened)). Open \(notReopened.count == 1 ? "it" : "them") from the menu."
            presentAlert(style: .warning, title: "The update did not install", message: message)

        case .quitTimedOut(let stillRunning, let closed):
            var message = "\(describe(stillRunning)) did not quit within a minute \u{2014} Claude may be showing a dialog of its own. Once it has quit, the update installs by itself."
            if !closed.isEmpty {
                message += "\n\nNothing was reopened, because the installer may start the moment that happens. Closed: \(list(closed)). Give the update a few seconds after the last profile quits, then open \(closed.count == 1 ? "it" : "them") from the menu."
            }
            presentAlert(style: .warning, title: "Not every Claude profile quit", message: message)

        case .updaterStuck:
            presentAlert(
                style: .warning,
                title: "Claude\u{2019}s installer has not finished",
                message: "Every profile quit, but the installer is still running after three minutes. Nothing was reopened, so the app is not replaced underneath a running profile. Open your profiles from the menu once it is done \u{2014} Diagnostics shows whether the installer is still running."
            )

        case .quitRefused:
            presentAlert(
                style: .warning,
                title: "Claude did not accept the request to quit",
                message: "Nothing was quit and nothing was changed. Quit every Claude profile yourself and the update installs by itself."
            )

        case .changedSinceConfirmation:
            presentAlert(
                style: .informational,
                title: "Nothing was quit",
                message: "The set of running Claude instances changed while the confirmation was open. Open the menu and try again."
            )
        }

        // A profile that had already closed itself for this update was not running when the
        // flow was confirmed, so it was not in the plan. Its marker is still there.
        outsideTriggerForReopen()
    }

    // MARK: - Reopening after Claude's own update (launch-only)

    private func applicationDidTerminate(bundleID: String?) {
        guard let bundleID, bundleID == InstanceManager.bundleIdentifier(appPath: config.claudeAppPath) else { return }
        outsideTriggerForReopen()
    }

    /// Something happened in the world: a Claude instance quit, the Mac woke, we started, the
    /// confirmed update flow finished. Each such event earns one delayed retry.
    private func outsideTriggerForReopen() {
        reopenRetryAvailable = true
        considerReopenAfterUpdate()
    }

    /// Reopens profiles that closed themselves to install a Claude update, once it is in.
    /// Everything it is handed can only start things; there is no way to quit from here.
    private func considerReopenAfterUpdate() {
        guard !isConsideringReopen else {
            reopenRearmed = true
            return
        }
        reloadConfig()
        // Only the switcher holding the lock acts on its own. Never on a config that failed to
        // load: what is in memory then is the defaults, not what the user asked for. And the
        // confirmed quit-and-install flow reopens what it closed; stay out of its way.
        guard automationLock != nil, configError == nil, config.reopenAfterUpdate, updateProgress == nil,
              let bundleID = InstanceManager.bundleIdentifier(appPath: config.claudeAppPath)
        else { return }

        isConsideringReopen = true
        let profiles = config.profiles
        let environment = UpdateReopen.Environment.live(
            appPath: config.claudeAppPath,
            bundleID: bundleID,
            claimLaunching: { [weak self] in self?.claimLaunchSlot() ?? false },
            releaseLaunching: { [weak self] in self?.releaseLaunchSlot() }
        )
        Task { @MainActor in
            let outcome = await UpdateReopen.run(profiles: profiles, handled: self.handledAttempts, environment: environment)
            self.reopenDidFinish(outcome)
        }
    }

    /// One launcher at a time: the menu, the confirmed update flow and this all decide "is it
    /// running yet?", and two of them deciding at once could start a profile twice.
    private func claimLaunchSlot() -> Bool {
        // The setting may have been turned off while the run was waiting.
        guard config.reopenAfterUpdate, !isBusy, updateProgress == nil, !isPresentingModal else { return false }
        isBusy = true
        launchGeneration &+= 1   // retire any launch watchdog still sleeping
        rebuildIfVisible()
        return true
    }

    private func releaseLaunchSlot() {
        isBusy = false
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        rebuildIfVisible()
    }

    private func reopenDidFinish(_ outcome: UpdateReopen.Outcome) {
        isConsideringReopen = false
        if case .reopened(let version, let reopened, _) = outcome, !reopened.isEmpty {
            for item in reopened { handledAttempts[item.profile.id] = item.attempt.at }
            let names = reopened.map { "\u{201C}\($0.profile.label)\u{201D}" }.joined(separator: ", ")
            autoReopenNotice = "Reopened \(names) after Claude updated to \(version) at \(MenuBuilder.clock(Date(), now: Date()))."
            autoReopenNoticeWasShown = false
            rebuildIfVisible()   // the slot's release rebuilt the menu before this was set
        }
        // Busy (a dialog was up) or the installer still going: look once more in a minute.
        // The retry itself earns no further retry, so this cannot loop.
        if outcome == .busy || outcome == .updaterStuck, reopenRetryAvailable {
            reopenRetryAvailable = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                self.considerReopenAfterUpdate()
            }
        }
        // No alerts from here: nobody asked for this just now, and a dialog over someone's
        // work is worse than a line in the menu.
        if reopenRearmed {
            reopenRearmed = false
            considerReopenAfterUpdate()
        }
    }

    /// A config that failed to load is showing "the last good settings" — at first launch, the
    /// defaults. Saving a toggle then would write those over the user's file.
    private func refuseWhileConfigIsBroken() -> Bool {
        guard let configError else { return false }
        presentAlert(style: .warning, title: "Fix the config file first",
                     message: "\(Config.configURL.path) could not be read, so this setting was not changed:\n\n\(configError)")
        return true
    }

    @objc private func toggleReopenAfterUpdate(_ sender: NSMenuItem) {
        guard !isPresentingModal, !refuseWhileConfigIsBroken() else { return }
        config.reopenAfterUpdate.toggle()
        guard saveConfig(failureTitle: "Could not save the setting") else {
            config.reopenAfterUpdate.toggle()
            return
        }
        if config.reopenAfterUpdate { outsideTriggerForReopen() }
    }

    // MARK: - Blocking Claude's auto-updates

    @objc private func toggleBlockUpdates(_ sender: NSMenuItem) {
        guard !isPresentingModal, !refuseWhileConfigIsBroken() else { return }
        if !config.blockClaudeUpdates {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Stop Claude from updating itself?"
            alert.informativeText = """
            Claude Desktop will no longer download or install updates on any profile, so it will \
            stop closing itself to update. It applies the next time each profile starts; nothing \
            is quit to apply it.

            What you give up until you turn this off again:
            \u{2022} Security and compatibility fixes do not arrive.
            \u{2022} The Code tab\u{2019}s claude CLI stops updating too.
            \u{2022} \u{201C}Check for Updates\u{2026}\u{201D} disappears from Claude\u{2019}s menu.
            \u{2022} An update Claude has already downloaded still installs.

            To update: turn this off and restart a profile.

            How: Claude Switcher writes one small policy file, which Claude itself reads, next to \
            each profile\u{2019}s data folder. It never touches a policy it did not create.
            """
            alert.addButton(withTitle: "Block Updates")
            alert.addButton(withTitle: "Cancel")
            guard runModal(alert) == .alertFirstButtonReturn else { return }
        }
        config.blockClaudeUpdates.toggle()
        // Files follow the saved setting, never the other way round: a block in place with the
        // setting reading "off" is a state nothing would ever reconcile.
        guard saveConfig(failureTitle: "Could not save the setting") else {
            config.blockClaudeUpdates.toggle()
            return
        }
        applyUpdateBlock(config.blockClaudeUpdates)
    }

    /// Writes (or removes) our policy file for every profile and reports the ones left alone.
    private func applyUpdateBlock(_ blocked: Bool) {
        var leftAlone: [String] = []
        for profile in config.profiles {
            do {
                let state = blocked
                    ? try UpdateBlock.apply(userDataDir: profile.userDataDir)
                    : try UpdateBlock.remove(userDataDir: profile.userDataDir)
                if case .foreign(let why) = state {
                    leftAlone.append("\u{201C}\(profile.label)\u{201D}: its policy folder was left alone because \(why).")
                }
            } catch {
                leftAlone.append("\u{201C}\(profile.label)\u{201D}: \(error.localizedDescription)")
            }
        }
        guard !leftAlone.isEmpty else { return }
        presentAlert(
            style: .warning,
            title: blocked ? "Updates could not be blocked for every profile" : "The block could not be lifted for every profile",
            message: leftAlone.joined(separator: "\n\n") + "\n\nClaude Switcher only ever writes or removes a policy it created itself."
        )
    }

    /// At startup, finish anything half-written and cover profiles added by hand. Only ever
    /// applies: a config that failed to load reads as "off", and that must not lift a block.
    private func reconcileUpdateBlock() {
        guard automationLock != nil, configError == nil, config.blockClaudeUpdates else { return }
        for profile in config.profiles { _ = try? UpdateBlock.apply(userDataDir: profile.userDataDir) }
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
        let queries = config.profiles.map { Diagnostics.ProfileQuery(id: $0.id, credDir: $0.credDir, userDataDir: $0.userDataDir) }

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

    private func launchAtLoginState() -> LoginItemState {
        LoginItem.state(for: SMAppService.mainApp.status, runsFromBundle: LoginItem.runsFromBundle())
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
                message: "\(error.localizedDescription)\n\nLogin items require Claude Switcher to be installed as an app bundle, e.g. in /Applications."
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
