import Foundation

/// The program Claude Desktop runs for the Code tab. It is not `Claude.app`: Desktop keeps a copy
/// per release under each account's user-data folder and starts it through its `disclaimer` tool,
/// so macOS treats it as an app in its own right. A permission given to `Claude.app` never reaches
/// it, which is why "“claude” would like to access data from other apps" keeps coming back
/// (README §2.15).
///
/// This only finds the program and says who signed it. Nothing here, or anywhere in the app,
/// changes a macOS privacy setting (hard rule 26).
public enum ClaudeHelper {

    /// One installed copy.
    public struct Location: Equatable, Sendable {
        public let version: String
        /// `…/claude-code/<version>/<build>/claude.app`
        public let bundlePath: String

        public init(version: String, bundlePath: String) {
            self.version = version
            self.bundlePath = bundlePath
        }

        public var executablePath: String { bundlePath + "/Contents/MacOS/claude" }
    }

    /// What the menu item found.
    public enum Check: Equatable, Sendable {
        /// Desktop has not installed it yet: it appears the first time the Code tab runs.
        case notInstalled
        /// Found, and not to be recommended for Full Disk Access.
        case unverified(bundlePath: String, reason: String)
        case ready(Location)
    }

    /// The Full Disk Access page of System Settings. `Privacy_AllFiles` is the name macOS 26 gives
    /// it in the Privacy & Security extension's own `TCCServiceList.plist`.
    public static let fullDiskAccessSettings =
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!

    /// Every account's user-data folder, the default account's first. An account with no folder
    /// of its own is the default account.
    public static func userDataDirs(of config: Config, home: String = NSHomeDirectory()) -> [String] {
        [Config.defaultUserDataDir(home: home)]
            + config.profiles.compactMap { profile in
                profile.userDataDir.map { PathNormalizer.normalize($0, home: home) }
            }
    }

    /// The highest version installed under any of `userDataDirs`. `.numeric` compares digit runs
    /// as numbers, so 2.1.99 sorts below 2.1.317.
    public static func newest(userDataDirs: [String], fileManager: FileManager = .default) -> Location? {
        userDataDirs
            .flatMap { copies(under: $0 + "/claude-code", fileManager: fileManager) }
            .max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    /// Finds the newest copy and proves it comes from whoever made `Claude.app`.
    ///
    /// Full Disk Access is the strongest thing macOS can give a program, and this one lives in a
    /// folder the user's own programs can write to. So it is only recommended when its signature
    /// is intact and meets a Developer ID requirement for the team that signed the configured
    /// `Claude.app`, read from that signature and never from a literal. `Claude.app` goes first:
    /// with no team to ask for, a 300 MB program need not be hashed.
    public static func check(appPath: String, userDataDirs: [String], verify: CodeSignature.Verify) -> Check {
        guard let helper = newest(userDataDirs: userDataDirs) else { return .notInstalled }

        let app: CodeIdentity
        switch verify(appPath, nil) {
        case .success(let read):
            app = read
        case .failure(let refusal):
            return .unverified(bundlePath: helper.bundlePath, reason: "Claude.app\u{2019}s signature did not check out: \(refusal.message)")
        }

        guard let requirement = requirement(forProgramOf: app) else {
            return .unverified(bundlePath: helper.bundlePath, reason: "Claude.app has no developer to compare it with")
        }

        switch verify(helper.bundlePath, requirement) {
        case .success:
            return .ready(helper)
        case .failure(let refusal) where refusal.status == CodeSignature.requirementFailed:
            return .unverified(bundlePath: helper.bundlePath, reason: "it is not signed by the developer of Claude.app")
        case .failure(let refusal):
            return .unverified(bundlePath: helper.bundlePath, reason: "its signature did not check out: \(refusal.message)")
        }
    }

    /// An ad-hoc signature, no team or text that is not a team says nothing about who made it.
    private static func requirement(forProgramOf app: CodeIdentity) -> String? {
        guard !app.isAdHoc, let team = app.teamID else { return nil }
        return try? CodeSignature.requirementForDeveloper(team: team)
    }

    /// `<version>/<build>/claude.app`, and the older `<version>/claude.app`. Only folders named
    /// as a version count: `.numeric` would rank any other name above every version.
    private static func copies(under root: String, fileManager: FileManager) -> [Location] {
        let versions = ((try? fileManager.contentsOfDirectory(atPath: root)) ?? [])
            .filter { ReleaseVersion(string: $0) != nil }
        return versions.flatMap { version -> [Location] in
            let folder = root + "/" + version
            let builds = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
            let places = [folder] + builds.sorted().map { folder + "/" + $0 }
            return places.compactMap { place -> Location? in
                let copy = Location(version: version, bundlePath: place + "/claude.app")
                return fileManager.isExecutableFile(atPath: copy.executablePath) ? copy : nil
            }
        }
    }
}
