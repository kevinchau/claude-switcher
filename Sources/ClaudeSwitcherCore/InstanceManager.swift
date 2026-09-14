import AppKit
import Foundation

/// Which profile a running Claude.app process belongs to.
///
/// This is deliberately three-valued. "No `--user-data-dir` argument" and "we could not read
/// the argument vector" are entirely different claims: the first identifies the default
/// account, the second identifies nothing at all. Collapsing them onto `nil` would make any
/// process we lack permission to inspect masquerade as the user's default account.
public enum InstanceProfile: Equatable {
    /// Launched with no `--user-data-dir`: the app's own default profile.
    case defaultProfile
    /// Launched with `--user-data-dir=<normalized path>`.
    case directory(String)
    /// The argument vector could not be read. Matches no profile, ever.
    case unknown
}

/// One live Claude.app process, tagged with the profile it was launched against.
public struct RunningInstance: Equatable {
    public let pid: pid_t
    public let profile: InstanceProfile

    public init(pid: pid_t, profile: InstanceProfile) {
        self.pid = pid
        self.profile = profile
    }

    /// The normalized `--user-data-dir`, or `nil` for the default profile *and* for an
    /// unreadable one. Prefer ``profile`` when the difference matters.
    public var userDataDir: String? {
        if case .directory(let dir) = profile { return dir }
        return nil
    }
}

/// Errors surfaced by ``InstanceManager/launch(profile:appPath:completion:)``.
public enum InstanceManagerError: Error, LocalizedError {
    /// `NSWorkspace` reported neither a running application nor an error.
    case launchFailed(String)
    /// The matching instance exists but could not be brought to the front.
    case activationFailed(pid_t)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let path):
            return "Could not launch the application at \(path)."
        case .activationFailed(let pid):
            return "Claude is already running for this profile (pid \(pid)) but could not be brought to the front."
        }
    }
}

/// Enumerates, focuses and launches Claude.app instances, one per profile.
///
/// Claude.app has no single-instance lock, so several copies run side by side. A profile is
/// identified purely by its Electron user-data directory: an instance launched with
/// `--user-data-dir=X` is a separate app login (and therefore a separate Anthropic account)
/// for both the chat and the Code tab, while an instance with no such argument is the
/// default profile. Switching accounts is therefore launch-or-focus; nothing is ever quit.
public enum InstanceManager {

    /// The Electron flag that selects a profile directory.
    private static let userDataDirFlag = "--user-data-dir"

    // MARK: - Bundle identity

    /// The bundle identifier of the app at `appPath`, read from its own `Contents/Info.plist`.
    ///
    /// Never hardcoded: the user may point the switcher at a beta, a renamed copy, or an app
    /// in a non-standard location, and each can carry a different identifier.
    public static func bundleIdentifier(appPath: String) -> String? {
        let url = URL(fileURLWithPath: PathNormalizer.normalize(appPath))

        if let identifier = Bundle(url: url)?.bundleIdentifier, !identifier.isEmpty {
            return identifier
        }

        // Fallback for bundles `Bundle(url:)` declines to open (e.g. odd permissions):
        // read the plist directly.
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL),
              let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.isEmpty
        else { return nil }

        return identifier
    }

    // MARK: - Enumeration

    /// Every running instance of the app at `appPath`, each tagged with its profile directory.
    public static func runningInstances(appPath: String) -> [RunningInstance] {
        let normalizedAppPath = PathNormalizer.normalize(appPath)
        let identifier = bundleIdentifier(appPath: normalizedAppPath)

        let matches = NSWorkspace.shared.runningApplications.filter { app in
            if let identifier, let running = app.bundleIdentifier, running == identifier {
                return true
            }
            // Fallback for processes whose bundle identifier is unavailable, and for the
            // case where the plist could not be read at all: compare bundle locations.
            if let bundleURL = app.bundleURL,
               PathNormalizer.normalize(bundleURL.path) == normalizedAppPath {
                return true
            }
            return false
        }

        return matches.map { app in
            let pid = app.processIdentifier
            return RunningInstance(
                pid: pid,
                profile: profileBinding(fromArguments: ProcessArgs.arguments(forPID: pid))
            )
        }
    }

    /// Classifies an argument vector into the profile it identifies.
    ///
    /// Accepts both the `--user-data-dir=VALUE` and the `--user-data-dir VALUE` spellings.
    /// A `nil` vector (argv unreadable) yields ``InstanceProfile/unknown``; a vector with no
    /// such flag — or with an empty value — yields ``InstanceProfile/defaultProfile``.
    ///
    /// The arguments arrive already split by the kernel (see ``ProcessArgs``), so a value
    /// containing spaces — `.../Library/Application Support/Claude-Work` — is one element
    /// here and needs no re-parsing.
    public static func profileBinding(fromArguments arguments: [String]?) -> InstanceProfile {
        guard let arguments else { return .unknown }
        let prefix = userDataDirFlag + "="

        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix(prefix) {
                if let dir = normalizedDirectory(String(argument.dropFirst(prefix.count))) {
                    return .directory(dir)
                }
                return .defaultProfile
            }
            if argument == userDataDirFlag, index + 1 < arguments.count {
                if let dir = normalizedDirectory(arguments[index + 1]) {
                    return .directory(dir)
                }
                return .defaultProfile
            }
        }
        return .defaultProfile
    }

    /// The profile binding a given configured profile expects to match.
    public static func binding(for profile: Profile) -> InstanceProfile {
        guard let dir = normalizedDirectory(profile.userDataDir) else { return .defaultProfile }
        return .directory(dir)
    }

    // MARK: - Activation

    /// Brings the instance with `pid` to the front. Returns whether it worked.
    ///
    /// `expecting` guards against pid reuse: callers act on a snapshot taken when the menu was
    /// opened, and by the time the user clicks, that pid may belong to an unrelated process.
    /// Without the check we would focus someone else's window and report a successful switch.
    public static func activate(pid: pid_t, expecting bundleID: String? = nil) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if let bundleID, app.bundleIdentifier != bundleID { return false }
        // macOS 14+ spelling; `activate(options:)` is deprecated as of 14.0.
        return app.activate()
    }

    // MARK: - Launching

    /// Focuses the instance belonging to `profile`, launching it first if it is not running.
    ///
    /// The completion is always delivered on the main queue.
    public static func launch(
        profile: Profile,
        appPath: String,
        completion: @escaping @Sendable (Result<pid_t, Error>) -> Void
    ) {
        let normalizedAppPath = PathNormalizer.normalize(appPath)
        let target = normalizedDirectory(profile.userDataDir)
        let wanted = binding(for: profile)

        // Already running for this profile? Focus it. Launching a second copy against the
        // same user-data dir would fight over the Electron profile lock.
        // `.unknown` instances never match, so an unreadable process is never mistaken for
        // the default account.
        if let existing = runningInstances(appPath: normalizedAppPath)
            .first(where: { $0.profile == wanted }) {
            guard activate(pid: existing.pid, expecting: bundleIdentifier(appPath: normalizedAppPath)) else {
                finish(.failure(InstanceManagerError.activationFailed(existing.pid)), completion)
                return
            }
            finish(.success(existing.pid), completion)
            return
        }

        // A non-default profile needs its directory to exist before Electron is pointed at it.
        if let target {
            do {
                try FileManager.default.createDirectory(
                    atPath: target,
                    withIntermediateDirectories: true
                )
            } catch {
                finish(.failure(error), completion)
                return
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()

        // We reach here only after establishing that no instance matches this profile, so a
        // NEW process is always what we want — including for the default profile.
        //
        // This must not be conditional on `target != nil`. With
        // `createsNewApplicationInstance == false`, `openApplication` activates ANY running
        // instance of the same bundle; it cannot know that instance belongs to a different
        // Electron profile. Selecting "Personal" while only "Work" was running would then
        // bring the Work window to the front and report success, and the caller would record
        // Personal as the active account while the user stared at the other one.
        configuration.createsNewApplicationInstance = true

        // Only a named profile carries the flag. The default profile must be launched with no
        // `--user-data-dir` at all, which is what selects the app's own default profile dir.
        if let target {
            configuration.arguments = [userDataDirFlag + "=" + target]
        }

        // `configuration.environment` is deliberately left untouched. The Desktop account is
        // selected purely by `--user-data-dir`: the app injects CLAUDE_CODE_OAUTH_TOKEN into
        // the sidecar itself, so no CLAUDE_* variable belongs here. In particular
        // CLAUDE_CONFIG_DIR must never be set — ~/.claude is intentionally shared across every
        // profile so that projects, history, skills, agents and memory follow the user onto
        // each account. Setting it would defeat the entire point of the switcher.
        // (CLAUDE_SECURESTORAGE_CONFIG_DIR is likewise irrelevant here; it applies only to the
        // terminal `claude` CLI.)

        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: normalizedAppPath),
            configuration: configuration
        ) { app, error in
            if let app {
                finish(.success(app.processIdentifier), completion)
            } else {
                finish(.failure(error ?? InstanceManagerError.launchFailed(normalizedAppPath)),
                       completion)
            }
        }
    }

    // MARK: - Helpers

    /// Normalizes an optional directory, folding both `nil` and `""` into `nil`.
    ///
    /// `PathNormalizer` maps empty input to `""`; treating that as "no directory" keeps a
    /// blank config value from being launched as `--user-data-dir=`.
    private static func normalizedDirectory(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = PathNormalizer.normalize(raw)
        return normalized.isEmpty ? nil : normalized
    }

    /// Delivers a result on the main queue, uniformly asynchronously.
    private static func finish(
        _ result: Result<pid_t, Error>,
        _ completion: @escaping @Sendable (Result<pid_t, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
}
