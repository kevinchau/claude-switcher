import Foundation
import ClaudeSwitcherCore

// MARK: - Diagnostics

public enum Diagnostics {

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
    public static func launchPlan(
        config: Config,
        running: [RunningInstance],
        update: UpdateStatus? = nil,
        usage: [String: UsageReading] = [:],
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
        lines.append("Shared dir:   \(sharedConfigDirectory.path) (shared by every profile; CLAUDE_CONFIG_DIR is never set by this app)")
        lines.append("Active profile: \(config.activeProfileId)")
        lines.append("")

        if config.profiles.isEmpty {
            lines.append("No profiles configured.")
        }

        for profile in config.profiles {
            let instance = ProfileMatching.instance(for: profile, in: running)
            lines.append("Profile \"\(profile.label)\" (id: \(profile.id))\(profile.isDefaultProfile ? "  [default profile]" : "")")
            if let dir = profile.userDataDir {
                let normalized = PathNormalizer.normalize(dir)
                lines.append("  user data dir:   \(normalized)")
                lines.append("  would create it: \(FileManager.default.fileExists(atPath: normalized) ? "no (already exists)" : "yes (mkdir -p at launch time)")")
            } else {
                lines.append("  user data dir:   (none — the app's own default profile)")
                lines.append("  would create it: no")
            }
            let arguments = launchArguments(for: profile)
            lines.append("  argv:            \(arguments.isEmpty ? "(no arguments)" : arguments.map { "\"\($0)\"" }.joined(separator: " "))")
            // Always a new process when nothing matches — including for the default profile.
            // With createsNewApplicationInstance == false, openApplication would activate ANY
            // running instance of the bundle, which may belong to a different account.
            lines.append("  new instance:    " + (instance == nil
                ? "yes (createsNewApplicationInstance — never focuses another profile's window)"
                : "no (an instance for this profile is already running)"))
            lines.append("  environment:     (inherited — no CLAUDE_* variables are ever injected)")
            if let instance {
                lines.append("  already running: yes (pid \(instance.pid)) — would activate it instead of launching")
            } else {
                lines.append("  already running: no — would launch")
            }
            lines.append("  keychain item:   \(KeychainProbe.serviceName(forCredDir: profile.credDir))  (terminal CLI only; existence check only — the secret is never read)")
            lines.append("  terminal cmd:    \(terminalCommand(for: profile))")
            lines.append("  usage:           \(UsageText.summary(usage[profile.id], time: clockTime))  (read from this profile's plan-usage-history.json; never fetched)")
            lines.append("")
        }

        let strays = ProfileMatching.unmatched(running, profiles: config.profiles)
        if !strays.isEmpty {
            lines.append("Running instances matching no profile:")
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
        /// profile id -> the usage Claude Desktop last recorded, from the profile's own file.
        public var usage: [String: UsageReading]
        public var now: Date
    }

    public static func probe(appPath: String, profiles: [ProfileQuery]) -> Probe {
        let now = Date()
        var signedIn: [String: Bool] = [:]
        var usage: [String: UsageReading] = [:]
        for query in profiles {
            signedIn[query.id] = KeychainProbe.isSignedIn(credDir: query.credDir)
            if let samples = UsageHistory.read(userDataDir: query.userDataDir),
               let reading = UsageReading.make(samples: samples, now: now) {
                usage[query.id] = reading
            }
        }
        return Probe(
            bundleIdentifier: InstanceManager.bundleIdentifier(appPath: appPath),
            update: UpdateProbe.status(appPath: appPath),
            cli: probeCLI(),
            signedIn: signedIn,
            usage: usage,
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

    public static func report(config: Config, running: [RunningInstance], probe: Probe) -> String {
        var lines: [String] = []
        let fileManager = FileManager.default

        lines.append("claude-switcher diagnostics")
        lines.append(ISO8601DateFormatter().string(from: Date()))
        lines.append("")

        lines.append("CONFIG")
        let configPath = Config.configURL.path
        lines.append("  file:            \(configPath)\(fileManager.fileExists(atPath: configPath) ? "" : "  (not written yet — defaults in use)")")
        lines.append("  active profile:  \(config.activeProfileId)")
        lines.append("  profiles:        \(config.profiles.count)")
        lines.append("")

        lines.append("CLAUDE DESKTOP")
        let appExists = fileManager.fileExists(atPath: PathNormalizer.normalize(config.claudeAppPath))
        lines.append("  path:            \(config.claudeAppPath)\(appExists ? "" : "  (NOT FOUND)")")
        lines.append("  bundle id:       \(probe.bundleIdentifier ?? "(unreadable — Info.plist has no CFBundleIdentifier)")")
        lines.append("  version:         \(probe.update.installed.map { "\($0) (\($0.build))" } ?? "(unreadable)")")
        lines.append("  instances up:    \(running.count)")
        lines.append("  staged update:   \(stagedUpdateSummary(probe.update, runningCount: running.count) ?? "none")")
        lines.append("  installer:       \(probe.update.updaterIsRunning ? "running (Claude's ShipIt helper — it waits for every instance to quit)" : "not running")")
        lines.append("")

        lines.append("SHARED STATE (never per-profile)")
        let sharedDir = sharedConfigDirectory.path
        lines.append("  ~/.claude:       \(sharedDir)\(fileManager.fileExists(atPath: sharedDir) ? "" : "  (does not exist yet)")")
        if let inherited = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            lines.append("  CLAUDE_CONFIG_DIR: SET in this process's environment -> \(inherited)")
            lines.append("                     claude-switcher never sets or modifies it; something else in your")
            lines.append("                     environment did. While set, ~/.claude is not the shared dir.")
        } else {
            lines.append("  CLAUDE_CONFIG_DIR: unset (correct — projects, history, skills, agents, memory and")
            lines.append("                     settings stay shared by every profile)")
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

        lines.append("PROFILES")
        for profile in config.profiles {
            let instance = ProfileMatching.instance(for: profile, in: running)
            lines.append("  \(profile.label)  (id: \(profile.id))\(profile.isDefaultProfile ? "  [default profile]" : "")\(profile.id == config.activeProfileId ? "  [active]" : "")")
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
            lines.append("    usage:          \(UsageText.summary(probe.usage[profile.id], time: clockTime))")
            lines.append("")
        }

        let strays = ProfileMatching.unmatched(running, profiles: config.profiles)
        if !strays.isEmpty {
            lines.append("UNRECOGNIZED INSTANCES")
            for instance in strays {
                lines.append("  pid \(instance.pid)  --user-data-dir=\(instance.userDataDir ?? "(none)")")
            }
            lines.append("")
        }

        lines.append("GUARANTEES")
        lines.append("  Keychain secrets are never read, written or deleted — existence only.")
        lines.append("  CLAUDE_CODE_OAUTH_TOKEN and CLAUDE_CONFIG_DIR are never set.")
        lines.append("  No CLAUDE_* variable is ever passed to Claude.app; the account comes from --user-data-dir.")
        lines.append("  The Claude.app bundle is never modified, copied or duplicated.")
        lines.append("  Claude is only ever asked to quit by \u{201C}Quit All & Install Update\u{2026}\u{201D}, after you confirm — never forced.")
        lines.append("  Usage is read from each profile's own plan-usage-history.json — never written, never fetched, no token or cookie read.")
        lines.append("  Removing a profile in this app never deletes anything on disk.")

        return lines.joined(separator: "\n")
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
