import Foundation
import ClaudeSwitcherCore

// MARK: - Diagnostics

public enum Diagnostics {

    /// `--help`. Here rather than in main.swift, whose globals exist only once it runs.
    static var usageText: String {
        """
        claude-switcher — switch between Claude Desktop accounts from the menu bar.

        USAGE
          claude-switcher             Run the menu bar app (no Dock icon; a welcome window the first time).
          claude-switcher --dry-run   Print the resolved launch plan for every account, with its usage
                                      and the Advisor's advice, then exit. Launches nothing, creates
                                      no directories, touches no state.
          claude-switcher --help      Show this message.

        CONFIG
          \(Config.configURL.path)

        HOW ACCOUNTS DIFFER
          Desktop app   a separate Electron user-data dir (--user-data-dir) — its own login for
                        both chat and the Code tab. Instances run side by side.
          Terminal CLI  a separate CLAUDE_SECURESTORAGE_CONFIG_DIR credential slot, applied by
                        you in your shell via "Copy terminal command".

        WHAT STAYS SHARED
          ~/.claude — projects, session history, skills, agents, plugins, memory, settings and
          CLAUDE.md — is shared by every account. claude-switcher never sets CLAUDE_CONFIG_DIR,
          never sets CLAUDE_CODE_OAUTH_TOKEN, and never reads or writes Keychain secrets (it only
          checks whether a credential item exists). Usage shown per account is read from that
          account's own plan-usage-history.json, which Claude Desktop writes; it is never fetched.

        WHAT DOES NOT
          Conversations. Chats live with each account on claude.ai, and Claude Desktop keeps the
          Code tab's session list per account inside each user-data dir. The transcripts are in
          ~/.claude, but an account's list only shows the sessions that account started.
          The menu's Sessions submenu can copy one Code session to another account: an independent
          copy, which that account's Claude lists the next time it starts.

        USAGE AND THE ADVISOR
          The bars show what Claude recorded for each account. The grey line under them, the
          lighter part of a bar and "Start a session in\u{2026}" are estimates: this Mac's Claude Code
          transcripts (token counts and times only) are read into one index of numbers,
          ~/.config/claude-switcher/activity-index.json, and weighed against what was recorded.
          A reset time shown without "(est.)" was recorded by Claude Code; every other one is an
          estimate. --dry-run reads that index as it is and never reads a transcript.

        UPDATES
          Claude Switcher keeps itself up to date from github.com/kevinchau/claude-switcher: every
          few hours it asks GitHub for the latest release, checks that it is signed by the same
          developer team and notarized by Apple, replaces itself when nothing is going on, and
          relaunches. Only Claude Switcher \u{2014} Claude is never quit, started or updated by this.
          Menu: "Keep Claude Switcher Up to Date" (the off-switch: off means no automatic network
          request at all; config key updateSwitcherAutomatically), "Check for Claude Switcher
          Updates\u{2026}", and "Update Claude Switcher to X & Relaunch" once a verified release is
          waiting. A copy built from source, or not in /Applications or ~/Applications, never
          replaces itself; it checks only when asked.

        INTERNAL
          --after-update <pid>        Given by Claude Switcher to the copy it starts after replacing
                                      itself; not for use by hand.
        """
    }

    // MARK: Pure derivations (no I/O — safe to call from anywhere, including --dry-run)

    /// Delegates to ``LaunchPlanning`` (moved to Core so it is covered by tests).
    public static func launchArguments(for profile: Profile) -> [String] {
        LaunchPlanning.launchArguments(for: profile)
    }

    /// Delegates to ``LaunchPlanning`` (moved to Core so it is covered by tests).
    public static func terminalCommand(for profile: Profile) -> String {
        LaunchPlanning.terminalCommand(for: profile)
    }

    static func shellQuoted(_ value: String) -> String { LaunchPlanning.shellQuoted(value) }

    /// The full `--dry-run` report. Pure: builds a string from values handed to it, so it
    /// can be printed with no UI, no directory creation and nothing launched.
    static func launchPlan(
        config: Config,
        running: [RunningInstance],
        update: UpdateStatus? = nil,
        usage: UsageSnapshot? = nil,
        updateAttempts: [String: UpdateAttempt] = [:],
        updateBlocks: [String: UpdateBlock.State] = [:],
        switcher: String? = nil,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("claude-switcher launch plan (dry run — nothing was launched or created)")
        lines.append("")
        lines.append("Config file:  \(Config.configURL.path)")
        lines.append("Claude.app:   \(config.claudeAppPath)")
        // Only when there is something to say: most runs have no update staged.
        if let update, let summary = stagedUpdateSummary(update, runningCount: running.count) {
            lines.append("Update:       \(summary)")
        }
        // Claude Switcher's own updates, from state.json: one line, nothing fetched.
        if let switcher { lines.append(switcher) }
        lines.append("Shared dir:   \(sharedConfigDirectory.path) (shared by every account; CLAUDE_CONFIG_DIR is never set by this app)")
        lines.append("Active account: \(config.activeProfileId)")
        lines.append("")

        if config.profiles.isEmpty {
            lines.append("No accounts configured.")
        }

        for profile in config.profiles {
            let instance = ProfileMatching.instance(for: profile, in: running)
            lines.append("Account \"\(profile.label)\" (id: \(profile.id))\(profile.isDefaultProfile ? "  [default account]" : "")")
            if let dir = profile.userDataDir {
                let normalized = PathNormalizer.normalize(dir)
                lines.append("  user data dir:   \(normalized)")
                lines.append("  would create it: \(FileManager.default.fileExists(atPath: normalized) ? "no (already exists)" : "yes (mkdir -p at launch time)")")
            } else {
                lines.append("  user data dir:   (none — the app's own default data dir)")
                lines.append("  would create it: no")
            }
            let arguments = launchArguments(for: profile)
            lines.append("  argv:            \(arguments.isEmpty ? "(no arguments)" : arguments.map { "\"\($0)\"" }.joined(separator: " "))")
            // Always a new process when nothing matches — including for the default profile.
            // With createsNewApplicationInstance == false, openApplication would activate ANY
            // running instance of the bundle, which may belong to a different account.
            lines.append("  new instance:    " + (instance == nil
                ? "yes (createsNewApplicationInstance — never focuses another account's window)"
                : "no (an instance for this account is already running)"))
            lines.append("  environment:     (inherited — no CLAUDE_* variables are ever injected)")
            if let instance {
                lines.append("  already running: yes (pid \(instance.pid)) — would reopen its window and activate it instead of launching")
            } else {
                lines.append("  already running: no — would launch")
            }
            lines.append("  keychain item:   \(KeychainProbe.serviceName(forCredDir: profile.credDir))  (terminal CLI only; existence check only — the secret is never read)")
            lines.append("  terminal cmd:    \(terminalCommand(for: profile))")
            lines.append("  usage:           \(UsageText.summary(usage?.forecasts[profile.id]?.reading, time: clockTime))  (read from this account's plan-usage-history.json; never fetched)")
            if let usage, let forecast = usage.forecasts[profile.id] {
                let clock = UsageClock(now: now)
                lines.append("  forecast:        \(DiagnosticsText.forecast(forecast, clock: clock, indexState: usage.indexState))")
                lines.append("  schedule:        \(DiagnosticsText.schedule(forecast, clock: clock))")
                lines.append("  calibration:     \(DiagnosticsText.calibration(forecast, costs: usage.costs))")
            }
            if let attempt = updateAttempts[profile.id] {
                lines.append("  closed itself:   \(closedForUpdateSummary(attempt))")
            }
            if let block = updateBlocks[profile.id] {
                lines.append("  update block:    \(updateBlockSummary(block))")
            }
            lines.append("")
        }

        // One advice block, from the index as it is on disk: --dry-run never reads a transcript.
        if let usage, !config.profiles.isEmpty {
            lines.append(contentsOf: DiagnosticsText.dryRunAdvice(usage, labels: UsageMenu.labels(config), clock: UsageClock(now: now)))
            lines.append("")
        }

        let strays = ProfileMatching.unmatched(running, profiles: config.profiles)
        if !strays.isEmpty {
            lines.append("Running instances matching no account:")
            for instance in strays {
                lines.append("  pid \(instance.pid)  --user-data-dir=\(instance.userDataDir ?? "(none)")")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// One line on a downloaded-but-not-installed Claude update, or `nil` when none is staged.
    static func stagedUpdateSummary(_ status: UpdateStatus, runningCount: Int) -> String? {
        guard let staged = status.staged else { return nil }
        let what = "Claude \(staged.staged) is downloaded (installed: \(staged.installed))"
        guard status.updaterIsRunning else {
            return what + " — no installer is waiting; Claude asks again at its next update check"
        }
        guard runningCount > 0 else {
            return what + " — installer running, nothing in its way"
        }
        return what + " — cannot install until every instance quits (\(runningCount) running)"
    }

    /// A profile's `update-attempt` marker: it quit itself to install an update and has not
    /// been opened since.
    static func closedForUpdateSummary(_ attempt: UpdateAttempt) -> String {
        "to install an update at \(clockTime(attempt.at)) (it was on \(attempt.fromVersion)); Claude's installer reopens only the default account"
    }

    /// One line on an account's Code sessions: counts only — never a title or a folder.
    static func sessionsSummary(_ listing: SessionListing, label: String) -> String {
        guard let folder = listing.location.folder else {
            return SessionMenu.unavailableText(listing.location, label: label)
        }
        var parts = ["\(listing.sessions.count) listed"]
        if listing.hidden.archived > 0 { parts.append("\(listing.hidden.archived) archived") }
        if listing.hidden.withoutTranscript > 0 { parts.append("\(listing.hidden.withoutTranscript) with no transcript on this Mac") }
        if listing.hidden.remote > 0 { parts.append("\(listing.hidden.remote) remote") }
        let blocked = listing.sessions.filter { $0.obstacle != nil }.count
        if blocked > 0 { parts.append("\(blocked) of the listed cannot be copied") }
        return parts.joined(separator: ", ")
            + "  (account \(folder.accountID.prefix(8))\u{2026}, organisation \(folder.organizationID.prefix(8))\u{2026})"
    }

    /// The last "show your window" request of this run. A refusal is invisible anywhere else:
    /// the account is still activated, and a closed window simply stays closed.
    static func reopenSummary(_ attempt: InstanceManager.ReopenAttempt?) -> String {
        guard let attempt else {
            return "none yet this run (sent when you pick an account that is already running)"
        }
        return attempt.wasSent
            ? "sent to pid \(attempt.pid) at \(clockTime(attempt.at))"
            : "REFUSED by macOS for pid \(attempt.pid) at \(clockTime(attempt.at)) (error \(attempt.status)) \u{2014} the account was only activated, so a closed window stays closed"
    }

    static func updateBlockSummary(_ state: UpdateBlock.State) -> String {
        switch state {
        case .off: return "off \u{2014} Claude updates itself"
        case .on: return "on \u{2014} Claude's updater does not start (takes effect at this account's next start)"
        case .damaged: return "incomplete \u{2014} our policy files are half there; toggling the setting rewrites them"
        case .foreign(let why): return "left alone \u{2014} there is a policy folder this tool did not create: \(why)"
        }
    }

    /// Clock times in reports, in the user's locale, with the weekday when not today.
    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        }
        return formatter.string(from: date)
    }

    static var sharedConfigDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    // MARK: Probes (blocking I/O — always call these off the main thread)

    public struct ProfileQuery: Sendable {
        public let id: String
        public let credDir: String?
        public let userDataDir: String?
        public init(id: String, credDir: String?, userDataDir: String? = nil) {
            self.id = id
            self.credDir = credDir
            self.userDataDir = userDataDir
        }
    }

    /// The Desktop Code tab runs the *app-managed sidecar*, not the `claude` binary on
    /// your PATH — the app injects CLAUDE_CODE_OAUTH_TOKEN straight into the sidecar's
    /// environment. Both are reported so a version mismatch is visible.
    public struct CLIProbe: Sendable {
        public var pathVersion: String?
        public var pathLocation: String?
        public var sidecarVersion: String?
        public var sidecarPath: String?
        public var isResolved: Bool { pathVersion != nil || sidecarVersion != nil }
    }

    public struct Probe: Sendable {
        public var bundleIdentifier: String?
        /// Installed version, staged update and installer liveness. Read-only.
        public var update: UpdateStatus
        public var cli: CLIProbe
        /// profile id -> terminal CLI sign-in (existence check only; false on any failure).
        public var signedIn: [String: Bool]
        /// Every account's recorded usage, forecast and the Advisor's answers (``UsageQuery``).
        var usage: UsageSnapshot
        /// The switcher's activity index as of the app's last refresh; `nil` while it is built.
        var activity: ActivityIndex.Refresh?
        /// profile id -> the marker of a profile that closed itself for an update. Read-only.
        public var updateAttempts: [String: UpdateAttempt]
        /// profile id -> whether our update-block policy is in place for it.
        public var updateBlocks: [String: UpdateBlock.State]
        public var now: Date
    }

    static func probe(appPath: String, profiles: [ProfileQuery], usage: UsageQuery, activity: ActivityIndex.Refresh?) -> Probe {
        let now = Date()
        var signedIn: [String: Bool] = [:]
        var updateAttempts: [String: UpdateAttempt] = [:]
        var updateBlocks: [String: UpdateBlock.State] = [:]
        for query in profiles {
            updateAttempts[query.id] = UpdateAttemptMarker.read(userDataDir: query.userDataDir)
            updateBlocks[query.id] = UpdateBlock.state(userDataDir: query.userDataDir)
            signedIn[query.id] = KeychainProbe.isSignedIn(credDir: query.credDir)
        }
        return Probe(
            bundleIdentifier: InstanceManager.bundleIdentifier(appPath: appPath),
            update: UpdateProbe.status(appPath: appPath),
            cli: probeCLI(),
            signedIn: signedIn,
            usage: usage.read(now: now),
            activity: activity,
            updateAttempts: updateAttempts,
            updateBlocks: updateBlocks,
            now: now
        )
    }

    public static func probeCLI() -> CLIProbe {
        let location = locateOnSearchPath("claude")
        let pathVersion = firstLine(of: run("/usr/bin/env", ["claude", "--version"]))
        let sidecar = newestSidecarExecutable()
        let sidecarVersion = sidecar.flatMap { firstLine(of: run($0.path, ["--version"])) }
        return CLIProbe(
            pathVersion: pathVersion,
            pathLocation: location,
            sidecarVersion: sidecarVersion,
            sidecarPath: sidecar?.path
        )
    }

    /// The app-managed sidecar Claude Desktop uses for the Code tab:
    /// ~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude
    /// Returns the highest version present.
    static func newestSidecarExecutable() -> URL? {
        let root = URL(fileURLWithPath: Config.defaultUserDataDir())
            .appendingPathComponent("claude-code")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        let candidates: [(version: String, url: URL)] = entries.compactMap { name in
            let executable = root
                .appendingPathComponent(name)
                .appendingPathComponent("claude.app/Contents/MacOS/claude")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
            return (name, executable)
        }
        // .numeric compares digit runs as numbers, so 1.2.10 sorts above 1.2.9.
        return candidates.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }?.url
    }

    // MARK: Report

    /// What is going on with session copies: committed ones not yet opened, ones whose journal
    /// is still there, what the last recovery pass said, and a store that refuses every copy.
    /// Empty when there is nothing to say.
    static func sessionCopiesSection(sessions: SessionMenuData?, recoveryNotes: [SessionCopy.RecoveryNote]) -> [String] {
        let pending = sessions?.pending ?? []
        let unfinished = sessions?.unfinished ?? []
        let unreadable = sessions?.unreadableStore
        guard !pending.isEmpty || !unfinished.isEmpty || !recoveryNotes.isEmpty || unreadable != nil else { return [] }

        var lines = ["SESSION COPIES"]
        if !pending.isEmpty {
            lines.append("  made but not yet opened by the Claude they were made for: \(pending.count)")
            lines.append("  (a copy appears the next time that Claude starts; nothing here quits Claude)")
        }
        for copy in unfinished {
            let target = copy.targetLabel.map { "to \($0)" } ?? "(its journal could not be read)"
            let since = copy.since.map { " since \(clockTime($0))" } ?? ""
            let state: String
            switch copy.state {
            case .staging: state = "not finished, nothing in place yet"
            case .staged: state = "staged; the transcript may be in place, not yet registered"
            case .unreadable: state = "not acted on"
            }
            lines.append("  unfinished copy \(target): \(state)\(since)")
        }
        if !unfinished.isEmpty {
            lines.append("  (tried again at each start; leftovers are named .claude-switcher-* \u{2014} in the session's project")
            lines.append("   folder under ~/.claude/projects, and in the other account's session folder. Its journal is in")
            lines.append("   ~/.config/claude-switcher/copies.)")
        }
        if !recoveryNotes.isEmpty {
            lines.append("  last recovery pass:")
            for note in recoveryNotes { lines.append("    \(note.message)") }
        }
        if let unreadable {
            lines.append("  a session folder that cannot be read, so no copy is made: \(unreadable)")
        }
        lines.append("")
        return lines
    }

    /// The Advisor's three answers, the activity index and the assumptions they rest on, after
    /// the accounts. Counts and labels only. Empty with no accounts.
    static func advisorSection(config: Config, probe: Probe) -> [String] {
        var lines = DiagnosticsText.advisorSection(probe.usage, labels: UsageMenu.labels(config), summary: probe.activity?.summary,
                                                   clock: UsageClock(now: probe.now))
        guard !lines.isEmpty else { return [] }
        if let error = probe.activity?.writeError {
            lines.append("  activity index could not be written (\(error)); what was read is kept in memory until the app quits")
        }
        lines.append("")
        return lines
    }

    /// The report's GUARANTEES, one per line — what a user pastes into a bug report, so each
    /// must stay true of what the app does (README §2.12, Appendix B rules 13, 14, 16, 18 and 19).
    static let guarantees: [String] = [
        "Keychain secrets are never read, written or deleted \u{2014} existence only.",
        "CLAUDE_CODE_OAUTH_TOKEN and CLAUDE_CONFIG_DIR are never set.",
        "No CLAUDE_* variable is ever passed to Claude.app; the account comes from --user-data-dir.",
        "The Claude.app bundle is never modified, copied or duplicated.",
        "Claude is only ever asked to quit by \u{201C}Quit All & Install Update\u{2026}\u{201D}, after you confirm \u{2014} never forced.",
        DiagnosticsText.guarantee,
        "Anything this app does to Claude's processes on its own initiative only ever starts Claude for an account; it never quits one.",
        "The other automatic steps are finishing or cleaning up its own session copy, and \u{2014} unless Keep Claude Switcher "
            + "Up to Date is off \u{2014} replacing Claude Switcher itself with a newer release signed by the same developer "
            + "team and notarized by Apple; Claude is never quit, started or changed to do so.",
        "The only network requests are to GitHub for Claude Switcher's own releases, with no token, cookie or account data; "
            + "macOS may also ask Apple's servers while it checks a signature or notarization.",
        "Claude Switcher only ever deletes a new version of itself that it downloaded and never put in place; a copy that "
            + "was in use is moved to its own folder or the Trash, never deleted.",
        "The only files ever created in Claude's data are the two update-block policy files (on your toggle) and a session copy's "
            + "files (its transcript and subagent transcripts in ~/.claude/projects and one record in the other account's store), "
            + "made only when you confirm a copy; nothing Claude made is ever replaced or removed, and a policy this tool did not "
            + "create is never touched.",
        "Removing an account in this app never deletes anything on disk.",
    ]

    static func report(config: Config, running: [RunningInstance], probe: Probe, sessions: SessionMenuData? = nil,
                       recoveryNotes: [SessionCopy.RecoveryNote] = [], switcher: SwitcherFacts? = nil) -> String {
        var lines: [String] = []
        let fileManager = FileManager.default

        lines.append("claude-switcher diagnostics")
        lines.append(ISO8601DateFormatter().string(from: Date()))
        lines.append("")

        lines.append("CONFIG")
        let configPath = Config.configURL.path
        lines.append("  file:            \(configPath)\(fileManager.fileExists(atPath: configPath) ? "" : "  (not written yet — defaults in use)")")
        lines.append("  active account:  \(config.activeProfileId)")
        lines.append("  accounts:        \(config.profiles.count)")
        lines.append("")

        if let switcher { lines.append(contentsOf: switcherSection(switcher)) }

        lines.append("CLAUDE DESKTOP")
        let appExists = fileManager.fileExists(atPath: PathNormalizer.normalize(config.claudeAppPath))
        lines.append("  path:            \(config.claudeAppPath)\(appExists ? "" : "  (NOT FOUND)")")
        lines.append("  bundle id:       \(probe.bundleIdentifier ?? "(unreadable — Info.plist has no CFBundleIdentifier)")")
        lines.append("  version:         \(probe.update.installed.map { "\($0) (\($0.build))" } ?? "(unreadable)")")
        lines.append("  instances up:    \(running.count)")
        lines.append("  window request:  \(reopenSummary(InstanceManager.lastReopenAttempt))")
        lines.append("  staged update:   \(stagedUpdateSummary(probe.update, runningCount: running.count) ?? "none")")
        lines.append("  installer:       \(probe.update.updaterIsRunning ? "running (Claude's ShipIt helper — it waits for every instance to quit)" : "not running")")
        lines.append("")

        lines.append("SHARED STATE (never per-account)")
        let sharedDir = sharedConfigDirectory.path
        lines.append("  ~/.claude:       \(sharedDir)\(fileManager.fileExists(atPath: sharedDir) ? "" : "  (does not exist yet)")")
        if let inherited = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            lines.append("  CLAUDE_CONFIG_DIR: SET in this process's environment -> \(inherited)")
            lines.append("                     claude-switcher never sets or modifies it; something else in your")
            lines.append("                     environment did. While set, ~/.claude is not the shared dir.")
        } else {
            lines.append("  CLAUDE_CONFIG_DIR: unset (correct — projects, history, skills, agents, memory and")
            lines.append("                     settings stay shared by every account)")
        }
        lines.append("")

        lines.append("CLAUDE CLI")
        if let version = probe.cli.pathVersion {
            lines.append("  PATH binary:     \(version)")
        } else {
            lines.append("  PATH binary:     not found")
        }
        lines.append("  PATH location:   \(probe.cli.pathLocation ?? "(not on the search path)")")
        if let version = probe.cli.sidecarVersion {
            lines.append("  app sidecar:     \(version)")
        } else {
            lines.append("  app sidecar:     not found")
        }
        lines.append("  sidecar path:    \(probe.cli.sidecarPath ?? "(none under ~/Library/Application Support/Claude/claude-code)")")
        lines.append("  note:            the Desktop Code tab runs the app-managed sidecar, not the PATH binary.")
        lines.append("")

        lines.append("ACCOUNTS")
        for profile in config.profiles {
            let instance = ProfileMatching.instance(for: profile, in: running)
            lines.append("  \(profile.label)  (id: \(profile.id))\(profile.isDefaultProfile ? "  [default account]" : "")\(profile.id == config.activeProfileId ? "  [active]" : "")")
            if let dir = profile.userDataDir {
                lines.append("    user data dir:  \(PathNormalizer.normalize(dir))")
            } else {
                lines.append("    user data dir:  (none — launched with no --user-data-dir argument)")
            }
            if let dir = profile.credDir {
                lines.append("    cred dir:       \(PathNormalizer.normalize(dir))")
            } else {
                lines.append("    cred dir:       (none — CLAUDE_SECURESTORAGE_CONFIG_DIR is omitted entirely)")
            }
            lines.append("    keychain item:  \(KeychainProbe.serviceName(forCredDir: profile.credDir))")
            switch probe.signedIn[profile.id] {
            case .some(true):  lines.append("    terminal CLI:   signed in (a credential item exists; its contents are never read)")
            case .some(false): lines.append("    terminal CLI:   no credential item found \u{2014} run the command below once and /login (a probe failure also reports this)")
            case nil:          lines.append("    terminal CLI:   unknown (the existence check did not run)")
            }
            lines.append("    desktop app:    \(instance.map { "running (pid \($0.pid))" } ?? "not running")")
            lines.append("    argv:           \(launchArguments(for: profile).map { "\"\($0)\"" }.joined(separator: " "))")
            lines.append("    terminal cmd:   \(terminalCommand(for: profile))")
            lines.append("    usage:          \(UsageText.summary(probe.usage.forecasts[profile.id]?.reading, time: clockTime))")
            if let forecast = probe.usage.forecasts[profile.id] {
                lines.append(contentsOf: DiagnosticsText.accountLines(forecast, costs: probe.usage.costs, clock: UsageClock(now: probe.now),
                                                                      indexState: probe.usage.indexState))
            }
            if let attempt = probe.updateAttempts[profile.id] {
                lines.append("    closed itself:  \(closedForUpdateSummary(attempt))")
            }
            if let block = probe.updateBlocks[profile.id] {
                lines.append("    update block:   \(updateBlockSummary(block))")
            }
            if let listing = sessions?.listings[profile.id] {
                lines.append("    code sessions:  \(sessionsSummary(listing, label: profile.label))")
            }
            lines.append("")
        }
        lines.append(contentsOf: sessionCopiesSection(sessions: sessions, recoveryNotes: recoveryNotes))
        lines.append(contentsOf: advisorSection(config: config, probe: probe))

        let strays = ProfileMatching.unmatched(running, profiles: config.profiles)
        if !strays.isEmpty {
            lines.append("UNRECOGNIZED INSTANCES")
            for instance in strays {
                lines.append("  pid \(instance.pid)  --user-data-dir=\(instance.userDataDir ?? "(none)")")
            }
            lines.append("")
        }

        lines.append("GUARANTEES")
        lines.append(contentsOf: guarantees.map { "  " + $0 })

        return lines.joined(separator: "\n")
    }

    // MARK: Claude Switcher itself

    /// What Diagnostics knows about Claude Switcher updating itself, gathered on the main actor.
    struct SwitcherFacts {
        var running: RunningCopy
        /// `nil` until a check has asked.
        var notarization: NotarizationVerdict?
        /// Why this copy never replaces itself, whatever is still to be learnt; `nil` while it might.
        var neverReplacesItself: ChecksOnlyReason?
        var settingOn: Bool
        var isLockHolder: Bool
        var state: SwitcherUpdateState
        /// The verified release this process keeps for a commit, and the folder it is staged in.
        var ready: ReleaseVersion?
        var readyFolder: String?
        /// What holds that commit back right now, if anything does.
        var waitingFor: String?
        /// In place, starting at the next launch.
        var restartPending: ReleaseVersion?
        /// What the launch-time pass found, for this run.
        var launchFindings: [String]
        var launchAtLogin: LoginItemState
        /// Launch at Login was on before the update and is not now.
        var launchAtLoginNeedsTurningOn: Bool
        var now: Date
    }

    static let switcherNetworkLine = "GET api.github.com/repos/kevinchau/claude-switcher/releases/latest and that "
        + "release's Claude.Switcher.dmg (github.com \u{2192} release-assets.githubusercontent.com); no token, no cookie; "
        + "nothing when the toggle is off"

    /// The CLAUDE SWITCHER section: what this copy is, whether and why it replaces itself, what
    /// the last check and the last update came to, and what it left behind.
    static func switcherSection(_ facts: SwitcherFacts) -> [String] {
        func line(_ label: String, _ value: String) -> String {
            "  " + (label + ":").padding(toLength: 17, withPad: " ", startingAt: 0) + value
        }
        let identity = facts.running.identity
        let state = facts.state
        let version = identity.version
        var lines = ["CLAUDE SWITCHER"]

        lines.append(line("version", "\(version?.description ?? "(unreadable)")  (\(facts.running.bundlePath))"))

        var signed: [String] = []
        if identity.isAdHoc {
            signed.append("ad-hoc signature")
        } else if let team = identity.teamID {
            signed.append("Developer ID, team \(team) (read from this copy)")
        } else {
            signed.append("no Developer ID team")
        }
        signed.append(identity.hasHardenedRuntime ? "hardened runtime" : "no hardened runtime")
        switch facts.notarization {
        case .accepted?: signed.append("notarized: accepted")
        case .rejected?: signed.append("notarized: rejected")
        case .unknown?, nil: signed.append("notarized: not confirmed yet")
        }
        lines.append(line("signed by", signed.joined(separator: ", ")))

        let automatic: Bool
        if let reason = facts.neverReplacesItself {
            lines.append(line("updates itself", "no \u{2014} \(reason.message)"))
            automatic = false
        } else if !facts.isLockHolder {
            lines.append(line("updates itself", "no \u{2014} another Claude Switcher holds the lock"))
            automatic = false
        } else if !facts.settingOn {
            lines.append(line("updates itself", "no \u{2014} off; checks only when you ask"))
            automatic = false
        } else if case .unknown? = facts.notarization {
            lines.append(line("updates itself", "not yet \u{2014} \(ChecksOnlyReason.notarizationUnconfirmed.message)"))
            automatic = true
        } else if facts.notarization == nil {
            // Not asked yet: the first check does, and nothing is replaced before it has.
            lines.append(line("updates itself", "yes, automatically (once notarization is confirmed)"))
            automatic = true
        } else {
            lines.append(line("updates itself", "yes, automatically"))
            automatic = true
        }

        if let at = state.lastCheckAt {
            let summary = SwitcherUpdateUI.checkSummary(state, running: version, verified: facts.ready, time: clockTime)
            lines.append(line("last check", "\(clockTime(at)) \u{2014} \(summary ?? "no result")"))
        } else {
            lines.append(line("last check", "never"))
        }
        if facts.restartPending != nil {
            lines.append(line("next check", "none \u{2014} the new version starts at the next launch"))
        } else if !automatic {
            lines.append(line("next check", "only when you choose Check for Claude Switcher Updates\u{2026}"))
        } else if let next = state.nextCheckNotBefore, next > facts.now {
            lines.append(line("next check", "after \(clockTime(next))"))
        } else {
            lines.append(line("next check", "due now (looked at every 30 minutes)"))
        }

        if let pending = facts.restartPending {
            lines.append(line("waiting", "\(pending) is in place; starts at the next launch"))
        } else if let ready = facts.ready {
            let now = facts.waitingFor.map { " (now: \($0))" } ?? ""
            lines.append(line("waiting", "\(ready) downloaded and verified; relaunches when nothing is going on\(now)"))
        } else {
            lines.append(line("waiting", "\u{2014}"))
        }

        if let install = state.lastInstall {
            var text = install.kind == .revert
                ? "went back from \(install.from) to \(install.to) at \(clockTime(install.at))"
                : "\(install.from) \u{2192} \(install.to) at \(clockTime(install.at))"
            switch install.oldCopy?.kind {
            case .previous?: text += "; previous copy: \(install.oldCopy!.path)"
            case .trash?: text += "; previous copy: in the Trash (\(install.oldCopy!.path))"
            case .staging?: text += "; previous copy: left at \(install.oldCopy!.path)"
            case nil: break
            }
            lines.append(line("last update", text))
        } else {
            lines.append(line("last update", "\u{2014}"))
        }

        var failure: [String] = []
        if let last = state.lastFailure {
            var text = "\(last.tag ?? "the update") at \(clockTime(last.at)) \u{2014} \(last.step): \(last.reason)"
            // A rejection is of one release file: a new digest under the same tag is tried again.
            if let tag = last.tag, let digest = last.digest, state.isRejected(tag: tag, digest: digest) {
                text += "; not tried again automatically"
            } else if let tag = last.tag, let digest = last.digest, let attempt = state.attempts?[tag + "#" + digest] {
                text += "; tried again after \(clockTime(attempt.nextNotBefore))"
            }
            failure.append(text)
        }
        if state.downloadsPaused == true {
            failure.append("downloads paused after \(SwitcherUpdatePolicy.pauseAfterRejections) rejected releases "
                + "(a check you ask for starts them again)")
        }
        lines.append(line("last failure", failure.isEmpty ? "\u{2014}" : failure.joined(separator: "; ")))

        if let latest = state.candidate {
            let immutable = latest.immutable.map { $0 ? "yes" : "no" } ?? "not stated"
            lines.append(line("release flags", "latest \(latest.tag), immutable: \(immutable)"))
        } else {
            lines.append(line("release flags", "\u{2014}"))
        }
        lines.append(line("disk image", state.mounted.map { "may still be mounted: \($0) (detached at the next check or launch)" }
            ?? "none mounted"))
        let staging = (state.staging ?? []).map { folder in
            folder == facts.readyFolder
                ? "holds the verified \(facts.ready.map(\.description) ?? "release"): \(folder)"
                : "a folder is left at \(folder)"
        }
        for (index, text) in (staging.isEmpty ? ["clean"] : staging).enumerated() {
            lines.append(index == 0 ? line("staging", text) : String(repeating: " ", count: 19) + text)
        }
        lines.append(line("relaunch", state.relaunchFindings?.last ?? "\u{2014}"))

        let login: String
        if facts.launchAtLoginNeedsTurningOn {
            login = "needs to be turned on again"
        } else {
            switch facts.launchAtLogin {
            case .enabled: login = "enabled"
            case .disabled: login = "off"
            case .requiresApproval: login = "waiting for approval in System Settings"
            case .unavailable: login = "unavailable (not an installed app bundle)"
            }
        }
        lines.append(line("launch at login", login))

        let foreign = state.foreignRecordsSeen == true || facts.launchFindings.contains(SwitcherUpdater.foreignFinding)
        lines.append(line("other Macs", foreign ? SwitcherUpdater.foreignFinding : "\u{2014}"))
        for (index, finding) in facts.launchFindings.filter({ $0 != SwitcherUpdater.foreignFinding }).enumerated() {
            lines.append(index == 0 ? line("at launch", finding) : String(repeating: " ", count: 19) + finding)
        }
        lines.append(line("network", switcherNetworkLine))
        lines.append("")
        return lines
    }

    // MARK: - Subprocess helpers

    /// GUI apps inherit a minimal PATH, so the usual install locations are added before
    /// asking `env` to resolve `claude`. Only PATH is touched — never a CLAUDE_* variable.
    static func searchPathDirectories() -> [String] {
        let home = NSHomeDirectory()
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let common = [
            "\(home)/.claude/local",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        var seen = Set<String>()
        return (inherited + common).filter { seen.insert($0).inserted }
    }

    static func locateOnSearchPath(_ executable: String) -> String? {
        let fileManager = FileManager.default
        for directory in searchPathDirectories() {
            let candidate = (directory as NSString).appendingPathComponent(executable)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func firstLine(of output: String?) -> String? {
        guard let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    /// Runs a short-lived command and returns stdout, or nil if it fails, times out, or
    /// exits non-zero. Never throws and never blocks longer than `timeout`.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPathDirectories().joined(separator: ":")
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let watched = process
        let watchdog = DispatchWorkItem { if watched.isRunning { watched.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
