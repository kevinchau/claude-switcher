import Darwin
import Foundation

/// The two version strings of an app bundle, as its `Info.plist` spells them.
public struct AppVersion: Equatable, Sendable, CustomStringConvertible {
    /// `CFBundleShortVersionString`, e.g. `2.110.1`.
    public let short: String
    /// `CFBundleVersion`, the build number.
    public let build: String

    public init(short: String, build: String) {
        self.short = short
        self.build = build
    }

    public var description: String { short.isEmpty ? build : short }
}

/// An update Claude has downloaded and handed to its installer, but which is not installed yet.
public struct StagedUpdate: Equatable, Sendable {
    public let installed: AppVersion
    public let staged: AppVersion
    /// The downloaded bundle, inside the installer's cache directory.
    public let updateBundlePath: String

    public init(installed: AppVersion, staged: AppVersion, updateBundlePath: String) {
        self.installed = installed
        self.staged = staged
        self.updateBundlePath = updateBundlePath
    }
}

/// Everything the app reports about Claude's updater, gathered in one read-only pass.
public struct UpdateStatus: Equatable, Sendable {
    public let installed: AppVersion?
    public let staged: StagedUpdate?
    /// Whether Claude's installer is alive — waiting for instances to quit, or installing.
    public let updaterIsRunning: Bool

    public init(installed: AppVersion?, staged: StagedUpdate?, updaterIsRunning: Bool) {
        self.installed = installed
        self.staged = staged
        self.updaterIsRunning = updaterIsRunning
    }

    /// The staged update, but only while an installer is there to install it. Quitting every
    /// profile for an update nothing is waiting to install would be all cost and no benefit.
    public var blocked: StagedUpdate? { updaterIsRunning ? staged : nil }
}

/// The install request Claude's updater leaves on disk. Every field is optional, so a key that
/// goes missing in a future format reads as "nothing staged"; so does a file that fails to
/// decode at all.
struct ShipItState: Decodable, Equatable {
    var bundleIdentifier: String?
    var targetBundleURL: String?
    var updateBundleURL: String?
    var useUpdateBundleName: Bool?
}

/// Read-only detection of a Claude Desktop update that is downloaded but cannot install.
///
/// Claude updates itself with Squirrel. Once an update is downloaded the app starts a helper,
/// `ShipIt`, which notes every instance of the app running at that moment, waits until all of
/// them have exited, and only then swaps the bundle. One other profile is enough to block it:
/// with two instances up, the one that quits itself to be updated is never installed over and
/// never comes back.
///
/// Everything here only reads: the installer's request file, two `Info.plist`s and the process
/// list. Nothing under the installer's cache directory is ever written, moved or deleted, and
/// the installer is never started from here.
public enum UpdateProbe {

    private static let stateFileName = "ShipItState.plist"
    private static let updaterExecutableName = "ShipIt"

    /// Squirrel's cache directory for the app with `bundleID`.
    ///
    /// Derived from the identifier read out of the configured app — never hardcoded.
    public static func shipItDirectory(bundleID: String, home: String = NSHomeDirectory()) -> String {
        PathNormalizer.normalize("Library/Caches/\(bundleID).\(updaterExecutableName)", home: home)
    }

    /// Decodes the installer's request file. Despite its `.plist` name it is JSON.
    static func parseState(_ data: Data) -> ShipItState? {
        try? JSONDecoder().decode(ShipItState.self, from: data)
    }

    /// The version of the bundle at `path`, read from `Contents/Info.plist` on every call.
    ///
    /// Deliberately not `Bundle(url:)`: `Bundle` caches its info dictionary per path, and the
    /// whole point of reading this is to notice the bundle being replaced underneath us.
    public static func version(ofBundleAt path: String) -> AppVersion? {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) else { return nil }
        let short = plist["CFBundleShortVersionString"] as? String ?? ""
        let build = plist["CFBundleVersion"] as? String ?? ""
        guard !(short.isEmpty && build.isEmpty) else { return nil }
        return AppVersion(short: short, build: build)
    }

    /// The update waiting to be installed over the app at `appPath`, if there is one.
    ///
    /// The request file outlives the install it describes, so its presence proves nothing. An
    /// update is pending only when the request names this app, the downloaded bundle it points
    /// at still exists inside the cache directory, and that bundle's version differs from the
    /// installed one.
    public static func stagedUpdate(
        appPath: String,
        bundleID: String,
        shipItDirectory: String? = nil
    ) -> StagedUpdate? {
        let directory = canonical(shipItDirectory ?? Self.shipItDirectory(bundleID: bundleID))
        let stateURL = URL(fileURLWithPath: directory).appendingPathComponent(stateFileName)

        guard let data = try? Data(contentsOf: stateURL),
              let state = parseState(data),
              state.bundleIdentifier == bundleID,
              let target = filePath(fromURLString: state.targetBundleURL),
              target == canonical(appPath),
              let update = filePath(fromURLString: state.updateBundleURL),
              update.hasPrefix(directory + "/")
        else { return nil }

        // With this flag the installer renames the app to the downloaded bundle's name. The
        // configured path would stop existing, so such an update is not ours to usher in.
        if state.useUpdateBundleName == true,
           (update as NSString).lastPathComponent != (target as NSString).lastPathComponent {
            return nil
        }

        guard let staged = version(ofBundleAt: update),
              let installed = version(ofBundleAt: target),
              staged != installed
        else { return nil }

        return StagedUpdate(installed: installed, staged: staged, updateBundlePath: update)
    }

    /// Installed version, staged update and installer liveness for the app at `appPath`.
    public static func status(appPath: String) -> UpdateStatus {
        let installed = version(ofBundleAt: PathNormalizer.normalize(appPath))
        guard let bundleID = InstanceManager.bundleIdentifier(appPath: appPath) else {
            return UpdateStatus(installed: installed, staged: nil, updaterIsRunning: false)
        }
        return UpdateStatus(
            installed: installed,
            staged: stagedUpdate(appPath: appPath, bundleID: bundleID),
            updaterIsRunning: isUpdaterRunning(bundleID: bundleID)
        )
    }

    // MARK: - The waiting installer

    /// Whether `arguments` is the command line of the installer for the app with `bundleID`.
    ///
    /// The helper runs as `…/Squirrel.framework/Resources/ShipIt <bundleID>.ShipIt <request>`.
    /// Matching the job label keeps another Squirrel app's installer from counting as ours.
    public static func isUpdaterCommandLine(_ arguments: [String]?, bundleID: String) -> Bool {
        guard let arguments, arguments.count >= 2 else { return false }
        return (arguments[0] as NSString).lastPathComponent == updaterExecutableName
            && arguments[1] == "\(bundleID).\(updaterExecutableName)"
    }

    /// Whether an installer for the app with `bundleID` is alive, i.e. waiting or installing.
    ///
    /// The helper is a launchd job, not an application, so `NSWorkspace` never lists it.
    public static func isUpdaterRunning(bundleID: String) -> Bool {
        var name = [UInt8](repeating: 0, count: 64)
        for pid in allPIDs() {
            // Cheap name check first: reading an argv allocates `kern.argmax` bytes.
            let length = proc_name(pid, &name, UInt32(name.count))
            guard length > 0,
                  String(decoding: name.prefix(Int(length)), as: UTF8.self) == updaterExecutableName
            else { continue }

            if isUpdaterCommandLine(ProcessArgs.arguments(forPID: pid), bundleID: bundleID) {
                return true
            }
        }
        return false
    }

    /// Every pid on the system. `proc_listallpids` takes a size in bytes and returns a count.
    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    // MARK: - Paths

    /// The path a `file:` URL string names, canonicalised, or `nil` for anything else.
    ///
    /// Goes through `URL` rather than stripping the scheme by hand: these strings are
    /// percent-encoded (`Grok%20Bot.app`) and usually carry a trailing slash.
    static func filePath(fromURLString string: String?) -> String? {
        guard let string, let url = URL(string: string), url.isFileURL else { return nil }
        let path = url.path
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
        return canonical(path)
    }

    /// Normalizes and resolves symlinks, so `/var/…` and `/private/var/…` compare equal.
    ///
    /// Unlike ``PathNormalizer`` this touches the filesystem, which is fine here: these paths
    /// are only compared with each other, never hashed or handed to Claude.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: PathNormalizer.normalize(path)).resolvingSymlinksInPath().path
    }
}
