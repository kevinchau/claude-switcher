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
    /// existence probe. A missing entry renders with no badge; the menu never blocks waiting
    /// for one.
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

    /// Each account's Code sessions and what can be copied where, from the most recent
    /// background read. `nil` until the first one lands; the menu never blocks waiting for it.
    private var sessionData: SessionMenuData?
    private var isReadingSessions = false
    /// A read was asked for while one was in flight — after a copy, say — so its result may
    /// predate what it should show: read once more when it lands.
    private var sessionsRereadWanted = false
    /// Non-nil while a session is being copied to another account. One copy at a time.
    private var copyProgress: String?
    /// What recovery at launch did about copies that had not finished. Shown once, like
    /// `autoReopenNotice`, as one line with the notes in its tooltip.
    private var copyNotes: [SessionCopy.RecoveryNote] = []
    private var copyNoticeWasShown = false
    /// The notes of the last recovery pass this app ran, for Diagnostics — until a pass has
    /// nothing to say.
    private var lastRecoveryNotes: [SessionCopy.RecoveryNote] = []
    /// One delayed second look per outside trigger, for a run that ended busy or with the
    /// installer still going. Bounded: a retry never schedules another.
    private var reopenRetryAvailable = true
    /// Held for the life of the process by the one switcher allowed to act on its own
    /// initiative (see `AutomationLock`). `nil`: another switcher is running — do nothing automatic.
    private var automationLock: Int32?
    /// Without the lock because its file could not be opened or locked, not because another
    /// switcher holds it. Only changes what a refused copy says.
    private var automationLockUnavailable = false

    /// Launches are serialized: while one is in flight the profile items are disabled and
    /// re-enabled from the completion handler, success or failure.
    private var isBusy = false
    private var launchGeneration = 0
    private var isMenuOpen = false
    /// No claude CLI was found at launch — neither on the PATH nor the app's own sidecar.
    /// Said where it matters, in "Copy terminal command", not in an alert at startup.
    private var cliIsMissing = false

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

    /// The welcome window, once it has been shown; replaced each time it is shown again.
    private var welcomeWindow: WelcomeWindowController?
    private static let welcomeShownKey = "welcomeShown"

    private static let actions = MenuBuilder.Actions(
        selectProfile: #selector(selectProfile(_:)),
        copyTerminalCommand: #selector(copyTerminalCommand(_:)),
        addProfile: #selector(addProfile(_:)),
        renameProfile: #selector(renameProfile(_:)),
        removeProfile: #selector(removeProfile(_:)),
        chooseClaudeApp: #selector(chooseClaudeApp(_:)),
        revealSharedDirectory: #selector(revealSharedDirectory(_:)),
        showDiagnostics: #selector(showDiagnostics(_:)),
        showWelcome: #selector(showWelcome(_:)),
        toggleLaunchAtLogin: #selector(toggleLaunchAtLogin(_:)),
        toggleReopenAfterUpdate: #selector(toggleReopenAfterUpdate(_:)),
        toggleBlockUpdates: #selector(toggleBlockUpdates(_:)),
        installUpdate: #selector(installUpdate(_:)),
        copySession: #selector(copySession(_:)),
        quit: #selector(quit(_:))
    )

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        reloadConfig()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: WelcomeWindowController.menuBarSymbolName, accessibilityDescription: "Claude Switcher") {
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
        switch AutomationLock.take() {
        case .acquired(let descriptor): automationLock = descriptor
        case .heldElsewhere: automationLock = nil
        case .unavailable: automationLock = nil; automationLockUnavailable = true
        }
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
        recoverInterruptedCopies()
        showWelcomeOnFirstLaunch()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Opening the app again while it is running lands here. With no Dock icon, and a menu bar
    /// icon that macOS hides when the bar is full, this is the one handle on the app that
    /// always exists — so it answers with a window (or, if an alert is up, with the alert).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWelcome()
        return false
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        isMenuOpen = true
        reloadConfig()
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        // Read-only and quick: one small JSON file, two Info.plists, a process-name scan.
        blockedUpdate = UpdateProbe.status(appPath: config.claudeAppPath).blocked
        usage = Self.readUsage(for: config.profiles)
        refreshSignInStates()
        refreshSessions()
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
        if copyNoticeWasShown {
            copyNotes = []
            copyNoticeWasShown = false
        }
    }

    private func menuInput() -> MenuBuilder.Input {
        MenuBuilder.Input(
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
            autoReopenNotice: autoReopenNotice,
            cliIsMissing: cliIsMissing,
            sessions: sessionData,
            copyProgress: copyProgress,
            copyNotes: copyNotes
        )
    }

    private func rebuild(_ menu: NSMenu) {
        let input = menuInput()
        if isMenuOpen, autoReopenNotice != nil { autoReopenNoticeWasShown = true }
        if isMenuOpen, !copyNotes.isEmpty { copyNoticeWasShown = true }
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

    // MARK: - Sessions

    /// The automation lock decides more than automation: only the switcher holding it may copy
    /// a session or clean up after an interrupted copy, so two switchers can never do either at once.
    private var copyEnvironment: SessionCopy.Environment {
        var environment = SessionCopy.Environment.live
        environment.holdsAutomationLock = automationLock != nil
        environment.lockFileUnavailable = automationLockUnavailable
        return environment
    }

    /// Reads every account's session list off the main thread and caches it for the menu, the
    /// way the Keychain probe does: tens of milliseconds of file I/O that opening the menu
    /// must not wait for. Read-only.
    private func refreshSessions() {
        guard !isReadingSessions else {
            sessionsRereadWanted = true
            return
        }
        isReadingSessions = true
        sessionsRereadWanted = false
        let profiles = config.profiles
        let environment = copyEnvironment
        Task.detached(priority: .userInitiated) {
            let data = SessionMenuData.read(profiles: profiles, environment: environment)
            await MainActor.run { self.applySessions(data) }
        }
    }

    private func applySessions(_ data: SessionMenuData) {
        isReadingSessions = false
        if sessionsRereadWanted { refreshSessions() }
        guard data != sessionData else { return }
        sessionData = data
        // Only the Sessions submenus change; the rest of an open menu stays put under the cursor.
        if isMenuOpen, let menu = statusItem?.menu {
            SessionMenu.update(in: menu, input: menuInput(), target: self, action: Self.actions.copySession)
        }
    }

    /// At launch: finish or clean up what a copy that did not finish left. It acts only on what
    /// its own journal names, and does nothing in a switcher that does not hold the lock. What
    /// it did is one line in the next menu, with the notes in its tooltip and in Diagnostics.
    private func recoverInterruptedCopies() {
        guard automationLock != nil, configError == nil else { return }
        let profiles = config.profiles
        let environment = copyEnvironment
        Task.detached(priority: .utility) {
            let notes = SessionCopy.recover(allProfiles: profiles, environment: environment)
            await MainActor.run {
                self.lastRecoveryNotes = notes
                guard !notes.isEmpty else { return }
                self.copyNotes = notes
                self.copyNoticeWasShown = false
                self.rebuildIfVisible()
                self.refreshSessions()
            }
        }
    }

    /// The only way a session is ever copied: this menu item, then an explicit confirmation.
    @objc private func copySession(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SessionCopyChoice,
              copyProgress == nil, !isPresentingModal else { return }
        reloadConfig()
        guard let shownSource = config.profile(id: choice.sourceProfileID),
              let shownTarget = config.profile(id: choice.targetProfileID) else {
            NSSound.beep()   // an account was removed since the menu was built
            return
        }

        // What the copy is and when it shows up go in the alert itself; everything else it is
        // and is not goes underneath in full, scrollable rather than cut.
        let caveats = SessionCopy.confirmationCaveats(sourceLabel: shownSource.label, targetLabel: shownTarget.label, cwd: choice.cwd)
        let alert = NSAlert()
        alert.messageText = "Copy \u{201C}\(SessionMenu.shortened(choice.title))\u{201D} to \(shownTarget.label)?"
        alert.informativeText = caveats.prefix(2).joined(separator: "\n\n")
        if caveats.count > 2 {
            alert.accessoryView = Self.readingView(
                caveats.dropFirst(2).map { "\u{2022} " + $0 }.joined(separator: "\n\n"),
                size: NSSize(width: 440, height: 170))
        }
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        guard runModal(alert) == .alertFirstButtonReturn else { return }
        // Main-actor work keeps running underneath a modal; another copy may have started.
        guard copyProgress == nil else { return }
        // So does the menu: an account may have been removed, renamed or re-pointed meanwhile.
        // Copy only between the very accounts that were confirmed, under their current names.
        reloadConfig()
        guard let (source, target) = CopyResult.stillTheConfirmedPair(
                  in: config, sourceID: choice.sourceProfileID, targetID: choice.targetProfileID,
                  confirmed: (shownSource, shownTarget))
        else {
            presentAlert(style: .warning, title: "Nothing was copied",
                         message: "The accounts changed while the confirmation was open; nothing was copied.")
            return
        }

        copyProgress = "Copying \u{201C}\(SessionMenu.shortened(choice.title))\u{201D} to \(target.label)\u{2026}"
        rebuildIfVisible()

        let request = SessionCopy.Request(source: source, target: target, sessionID: choice.sessionID,
                                          cliSessionId: choice.cliSessionId, cwd: choice.cwd)
        let profiles = config.profiles
        let environment = copyEnvironment
        let title = choice.title
        Task.detached(priority: .userInitiated) {
            let outcome = SessionCopy.copy(request, allProfiles: profiles, environment: environment)
            await MainActor.run { self.copyDidFinish(outcome, title: title, source: source, target: target) }
        }
    }

    /// A scrollable block of plain text for an alert that has more to say than fits its body.
    private static func readingView(_ text: String, size: NSSize) -> NSView {
        let textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textView.textColor = .secondaryLabelColor
        textView.string = text
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    private func copyDidFinish(_ outcome: SessionCopy.Outcome, title: String, source: Profile, target: Profile) {
        switch outcome {
        case .copied:
            presentCopyResult(outcome, title: title, source: source, target: target, notes: [])
        case .refused, .pendingRegistration:
            // A refusal can leave staged files behind (one that could not be proven its own),
            // and a copy left for registration is usually finished within seconds: run recovery
            // first, off the main thread, and say all of it in one alert. The progress line
            // stays up meanwhile, so no other copy starts.
            guard automationLock != nil, configError == nil else {
                presentCopyResult(outcome, title: title, source: source, target: target, notes: [])
                return
            }
            let profiles = config.profiles
            let environment = copyEnvironment
            Task.detached(priority: .userInitiated) {
                let notes = SessionCopy.recover(allProfiles: profiles, environment: environment)
                await MainActor.run {
                    self.lastRecoveryNotes = notes
                    self.presentCopyResult(outcome, title: title, source: source, target: target, notes: notes)
                }
            }
        }
    }

    /// One alert for a finished copy attempt, with what recovery then did, if anything.
    private func presentCopyResult(_ outcome: SessionCopy.Outcome, title: String, source: Profile, target: Profile,
                                   notes: [SessionCopy.RecoveryNote]) {
        copyProgress = nil
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        rebuildIfVisible()
        refreshSessions()

        let alert = CopyResult.alert(for: outcome, notes: notes, title: title, source: source.label, target: target.label,
                                     targetIsRunning: ProfileMatching.isRunning(target, in: running))
        presentAlert(style: alert.isSuccess ? .informational : .warning, title: alert.title, message: alert.message)
    }

    /// Resolves the claude CLI two ways; if neither is present the terminal submenu says so.
    /// Note: the Desktop Code tab runs the app-managed sidecar under
    /// ~/Library/Application Support/Claude/claude-code/<version>/..., NOT the PATH binary;
    /// the PATH binary is what "Copy terminal command" drives. Startup never blocks on this.
    private func checkCLIAvailability() {
        Task.detached(priority: .utility) {
            let probe = Diagnostics.probeCLI()
            await MainActor.run { self.handleCLIProbe(probe) }
        }
    }

    /// No alert: at first launch it landed on top of the welcome window and read as an error,
    /// when switching Desktop accounts needs nothing but Claude.app.
    private func handleCLIProbe(_ probe: Diagnostics.CLIProbe) {
        let missing = !probe.isResolved
        guard missing != cliIsMissing else { return }
        cliIsMissing = missing
        rebuildIfVisible()
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
            did not report a command line, so Claude Switcher cannot tell which account \
            \(unreadable.count == 1 ? "it belongs" : "they belong") to.

            Starting \u{201C}\(profile.label)\u{201D} now could open a second window on an account that is \
            already in use. If a window for this account is already open, switch to it instead.
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
        // Not on a config that failed to load: saving would write what is in memory — the
        // last good settings, or the defaults — over the file the user is in the middle of fixing.
        guard configError == nil, config.activeProfileId != id else { return }
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
        promptToAddAccount()
    }

    /// Asks for a name, adds the account and opens Claude on it. Returns whether one was added.
    @discardableResult
    private func promptToAddAccount() -> Bool {
        // Reachable from the welcome window too, where nothing disables the button meanwhile.
        guard !isPresentingModal else { return false }
        guard !isBusy else {
            NSSound.beep()   // a launch or an update is in flight; the menu item is disabled for it
            return false
        }
        guard !refuseWhileConfigIsBroken() else { return false }

        let alert = NSAlert()
        alert.messageText = "Add an account"
        alert.informativeText = """
        Name it whatever helps you tell it apart \u{2014} Work, Second, a person\u{2019}s name. Claude then \
        opens a new window for it, where you sign in with that Claude account. It runs alongside \
        your other accounts; nothing is signed out.

        Your ~/.claude stays shared: skills, agents, plugins, memory and settings follow you \
        into every account. Chats and the Code tab\u{2019}s session list do not \u{2014} Claude keeps \
        those with the account that started them, though a Code session can be copied across \
        from the Sessions menu.

        Claude Switcher never handles your credentials.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard runModal(alert) == .alertFirstButtonReturn else { return false }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return false }

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
            return false
        }
        saveConfig(failureTitle: "Could not save the new account")
        if config.blockClaudeUpdates {
            // Before its first launch, so the new profile's updater never starts either.
            _ = try? UpdateBlock.apply(userDataDir: profile.userDataDir)
        }
        refreshSignInStates()
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)

        // Launch it right away: a brand-new profile has no login yet, so this puts the user
        // straight on its sign-in screen. That is the whole point of adding one.
        beginLaunch(profile)
        return true
    }

    /// Label only. The id and both directories are the profile's identity and never change.
    @objc private func renameProfile(_ sender: NSMenuItem) {
        // The status menu still opens while an alert is up; a nested modal would also reset
        // `isPresentingModal` while the outer one is still on screen.
        guard !isPresentingModal, !refuseWhileConfigIsBroken(),
              let id = sender.representedObject as? String,
              let profile = config.profile(id: id) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename \u{201C}\(profile.label)\u{201D}"
        alert.informativeText = "Only the name in the menu changes. The account keeps its directories, its sign-ins and its id (\(profile.id))."
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
        guard !isPresentingModal, !refuseWhileConfigIsBroken(),
              let id = sender.representedObject as? String,
              let profile = config.profile(id: id) else { return }

        var details = [
            "Claude Switcher only forgets this account. Nothing on disk is deleted \u{2014} re-adding it with the same directories restores it, still signed in."
        ]
        if let dir = profile.userDataDir {
            details.append("Desktop account data stays at:\n\(PathNormalizer.normalize(dir))")
        }
        if let dir = profile.credDir {
            details.append("Terminal CLI credential dir stays at:\n\(PathNormalizer.normalize(dir))")
        }
        details.append("Its Keychain item is left untouched, and ~/.claude is shared \u{2014} never affected.")
        if UpdateBlock.state(userDataDir: profile.userDataDir) == .on {
            details.append("The update-block policy file Claude Switcher wrote for it is removed, so that re-adding the account later does not silently keep it from updating.")
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove the account \u{201C}\(profile.label)\u{201D}?"
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: "Remove Account")
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
    /// auto-assigned directories, so it stays filesystem-safe — and its fallbacks still say
    /// "profile": they are identifiers on disk, and an account removed and added again must
    /// land on the directory it had.
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
            "Claude\u{2019}s installer only runs once every Claude instance has quit. With \(plan.quit.count == 1 ? "an account" : "\(plan.quit.count) instances") open it has been waiting \u{2014} and an account that quits itself to be updated never comes back."
        ]
        if !plan.reopen.isEmpty {
            details.append("Will quit, then reopen:  \(plan.reopen.map(\.label).joined(separator: ", "))")
        }
        if !plan.strays.isEmpty {
            details.append("Will quit and NOT reopen:  \(plan.strays.count) unrecognized instance\(plan.strays.count == 1 ? "" : "s") (no account to reopen \(plan.strays.count == 1 ? "it" : "them") from)")
        }
        details.append("Anything Claude is doing right now \u{2014} a response being written, a task running in the Code tab \u{2014} is interrupted, as with any quit.")
        details.append("Claude Switcher only asks Claude to quit, the same as \u{2318}Q. The update itself is installed by Claude\u{2019}s own installer.")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Claude on every account to install Claude \(update.staged)?"
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
            var message = "Every account quit, but Claude\u{2019}s installer finished without changing the app \u{2014} it is still \(update.installed). Claude will try again at its next update check."
            message += notReopened.isEmpty
                ? "\n\nYour accounts were reopened."
                : "\n\nCould not reopen: \(list(notReopened)). Open \(notReopened.count == 1 ? "it" : "them") from the menu."
            presentAlert(style: .warning, title: "The update did not install", message: message)

        case .quitTimedOut(let stillRunning, let closed):
            var message = "\(describe(stillRunning)) did not quit within a minute \u{2014} Claude may be showing a dialog of its own. Once it has quit, the update installs by itself."
            if !closed.isEmpty {
                message += "\n\nNothing was reopened, because the installer may start the moment that happens. Closed: \(list(closed)). Give the update a few seconds after the last account quits, then open \(closed.count == 1 ? "it" : "them") from the menu."
            }
            presentAlert(style: .warning, title: "Claude did not quit on every account", message: message)

        case .updaterStuck:
            presentAlert(
                style: .warning,
                title: "Claude\u{2019}s installer has not finished",
                message: "Every account quit, but the installer is still running after three minutes. Nothing was reopened, so the app is not replaced underneath a running account. Open your accounts from the menu once it is done \u{2014} Diagnostics shows whether the installer is still running."
            )

        case .quitRefused:
            presentAlert(
                style: .warning,
                title: "Claude did not accept the request to quit",
                message: "Nothing was quit and nothing was changed. Quit Claude on every account yourself and the update installs by itself."
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
    /// defaults. Saving anything then would write those over the user's file.
    private func refuseWhileConfigIsBroken() -> Bool {
        guard let configError else { return false }
        presentAlert(style: .warning, title: "Fix the config file first",
                     message: "\(Config.configURL.path) could not be read, so nothing was changed:\n\n\(configError)")
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
            Claude Desktop will no longer download or install updates on any account, so it will \
            stop closing itself to update. It applies the next time each account starts; nothing \
            is quit to apply it.

            What you give up until you turn this off again:
            \u{2022} Security and compatibility fixes do not arrive.
            \u{2022} The Code tab\u{2019}s claude CLI stops updating too.
            \u{2022} \u{201C}Check for Updates\u{2026}\u{201D} disappears from Claude\u{2019}s menu.
            \u{2022} An update Claude has already downloaded still installs.

            To update: turn this off and restart an account.

            How: Claude Switcher writes one small policy file, which Claude itself reads, next to \
            each account\u{2019}s data folder. It never touches a policy it did not create.
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
            title: blocked ? "Updates could not be blocked for every account" : "The block could not be lifted for every account",
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
        guard !refuseWhileConfigIsBroken() else { return }
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
                message: "It appears the first time Claude Code runs. Every account will share it."
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Welcome window

    private func showWelcomeOnFirstLaunch() {
        let defaults = UserDefaults.standard
        let decision = Onboarding.firstLaunch(alreadyShown: defaults.bool(forKey: Self.welcomeShownKey),
                                              accountCount: config.profiles.count,
                                              configLoaded: configError == nil)
        if decision.remembers { defaults.set(true, forKey: Self.welcomeShownKey) }
        if decision.showsWelcome { showWelcome() }
    }

    @objc private func showWelcome(_ sender: NSMenuItem) {
        showWelcome()
    }

    private func showWelcome() {
        // The status menu still opens while an alert is up, and so does the app from Finder.
        // The alert is what needs answering; bring it forward rather than a window behind it.
        guard !isPresentingModal else {
            NSApp.activate()
            return
        }
        reloadConfig()
        // With a config that failed to load, what is in memory is not the user's accounts:
        // say nothing about them, and do not make adding one the obvious next step.
        let configLoaded = configError == nil
        let content = WelcomeWindowController.Content(
            defaultAccountLabel: configLoaded ? config.profiles.first(where: \.isDefaultProfile)?.label : nil,
            suggestsAddingAccount: configLoaded && config.profiles.count <= 1,
            hasMenuBarSettings: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        )
        let actions = WelcomeWindowController.Actions(
            addAccount: { [weak self] in
                guard let self else { return }
                // The window may have been open a while; act on the file as it is now.
                self.reloadConfig()
                guard self.promptToAddAccount() else { return }
                // Claude is opening on the new account's sign-in screen; get out of its way.
                self.welcomeWindow?.close()
            },
            showMenu: { [weak self] view in self?.popUpMenu(under: view) }
        )
        // Rebuilt each time it is shown, so it describes the accounts as they are at that moment.
        welcomeWindow?.close()
        let controller = WelcomeWindowController(content: content, actions: actions)
        welcomeWindow = controller
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // Activation is only a request (a login-item launch, another app in front): the one
        // welcome a new install gets must not open behind whatever is on screen.
        controller.window?.orderFrontRegardless()
    }

    /// The status menu, opened somewhere other than the menu bar — for when macOS is hiding
    /// the icon. The same menu object, filled in first: a menu whose icon is hidden has by
    /// definition never been opened, and it is empty until it has been.
    private func popUpMenu(under view: NSView) {
        guard let menu = statusItem?.menu else { return }
        menuNeedsUpdate(menu)
        let below = view.isFlipped ? view.bounds.maxY + 6 : view.bounds.minY - 6
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: below), in: view)
        // Tracking has ended whether or not AppKit reported it to the delegate.
        isMenuOpen = false
    }

    @objc private func showDiagnostics(_ sender: NSMenuItem) {
        reloadConfig()
        running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        let appPath = config.claudeAppPath
        let queries = config.profiles.map { Diagnostics.ProfileQuery(id: $0.id, credDir: $0.credDir, userDataDir: $0.userDataDir) }
        let profiles = config.profiles
        let environment = copyEnvironment

        Task {
            let (probe, sessions) = await Task.detached(priority: .userInitiated) {
                (Diagnostics.probe(appPath: appPath, profiles: queries),
                 SessionMenuData.read(profiles: profiles, environment: environment))
            }.value
            self.mergeSignInStates(probe.signedIn)
            self.presentDiagnostics(Diagnostics.report(config: self.config, running: self.running, probe: probe, sessions: sessions,
                                                       recoveryNotes: self.lastRecoveryNotes))
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
