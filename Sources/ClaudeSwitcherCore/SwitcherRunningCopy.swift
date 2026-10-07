import Darwin
import Foundation

/// The copy of Claude Switcher that is running, read once at launch and kept for the life of the
/// process: after a swap `Bundle.main` names the new bundle, while this still describes the code
/// that is running.
public struct RunningCopy: Sendable, Equatable {
    public let identity: CodeIdentity
    /// `Bundle.main.bundleURL.path`, standardized.
    public let bundlePath: String
    /// `Bundle.main.executableURL`, symlinks resolved.
    public let executablePath: String
    /// `proc_pidpath(getpid())`: where the running executable really is, which follows a move.
    public let processExecutablePath: String?
    public let bundleIdentifier: String?
    /// The folder the bundle is in, symlinks resolved.
    public let parentDirectory: String
    public let volumeIsReadOnly: Bool
    public let bundleIsWritable: Bool
    public let parentIsWritable: Bool
    public let isTranslocated: Bool

    public init(identity: CodeIdentity, bundlePath: String, executablePath: String, processExecutablePath: String?,
                bundleIdentifier: String?, parentDirectory: String, volumeIsReadOnly: Bool, bundleIsWritable: Bool,
                parentIsWritable: Bool, isTranslocated: Bool) {
        self.identity = identity
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.processExecutablePath = processExecutablePath
        self.bundleIdentifier = bundleIdentifier
        self.parentDirectory = parentDirectory
        self.volumeIsReadOnly = volumeIsReadOnly
        self.bundleIsWritable = bundleIsWritable
        self.parentIsWritable = parentIsWritable
        self.isTranslocated = isTranslocated
    }

    /// Reads this process. Call once, at launch, before anything could have moved the bundle.
    public static func current(bundle: Bundle = .main) -> RunningCopy {
        let bundlePath = bundle.bundleURL.standardizedFileURL.path
        let executable = bundle.executableURL?.path ?? ""
        let parent = (bundlePath as NSString).deletingLastPathComponent
        return RunningCopy(
            identity: CodeSignature.runningIdentity()
                ?? CodeIdentity(teamID: nil, identifier: nil, flags: 0, version: nil, path: nil),
            bundlePath: bundlePath,
            executablePath: SwitcherDisk.realpath(executable) ?? executable,
            processExecutablePath: SwitcherDisk.processExecutablePath(),
            bundleIdentifier: bundle.bundleIdentifier,
            parentDirectory: SwitcherDisk.realpath(parent) ?? parent,
            volumeIsReadOnly: SwitcherDisk.isOnReadOnlyVolume(bundlePath),
            bundleIsWritable: SwitcherDisk.isWritable(bundlePath),
            parentIsWritable: SwitcherDisk.isWritable(parent),
            isTranslocated: bundlePath.contains("/AppTranslocation/"))
    }
}

/// What a downloaded release is checked against: the running copy's own team, identifier and
/// version, read from its own signature. `nil` — no trust anchor — for a copy that has no
/// Developer ID team, is ad-hoc signed, whose signature does not name its bundle, or whose
/// version cannot be read.
public struct SwitcherTrust: Sendable, Equatable {
    public let teamID: String
    public let identifier: String
    public let runningVersion: ReleaseVersion

    public init(teamID: String, identifier: String, runningVersion: ReleaseVersion) {
        self.teamID = teamID
        self.identifier = identifier
        self.runningVersion = runningVersion
    }

    public init?(_ copy: RunningCopy) {
        guard let team = copy.identity.teamID, let identifier = copy.identity.identifier,
              let bundleIdentifier = copy.bundleIdentifier, identifier == bundleIdentifier,
              !copy.identity.isAdHoc, let version = copy.identity.version
        else { return nil }
        self.init(teamID: team, identifier: identifier, runningVersion: version)
    }

    public func appRequirement() throws -> String {
        try CodeSignature.requirementForApp(team: teamID, identifier: identifier)
    }

    public func imageRequirement() throws -> String {
        try CodeSignature.requirementForImage(team: teamID)
    }
}

/// Why a copy only ever checks and never replaces itself.
public enum ChecksOnlyReason: Equatable, Sendable {
    case noTeam
    case adHoc
    case noHardenedRuntime
    case identifierMismatch
    case noVersion
    case notAnAppBundle
    case translocated
    case readOnlyVolume
    case notInApplications(String)
    case notWritable
    case movedSinceLaunch
    case notNotarized
    case notarizationUnconfirmed

    public var message: String {
        switch self {
        case .noTeam: return "development build (no Developer ID team)"
        case .adHoc: return "development build (ad-hoc signature)"
        case .noHardenedRuntime: return "development build (no hardened runtime)"
        case .identifierMismatch: return "signature identifier does not match the bundle"
        case .noVersion: return "cannot read this copy\u{2019}s own version"
        case .notAnAppBundle: return "not running from an app bundle"
        case .translocated: return "running translocated (opened from a download without being moved)"
        case .readOnlyVolume: return "running from a read-only volume (the disk image?)"
        case .notInApplications(let parent): return "not installed in /Applications or ~/Applications (\(parent))"
        case .notWritable: return "this copy cannot be replaced by you (owned by another user?)"
        case .movedSinceLaunch: return "moved since it was started"
        case .notNotarized: return "this copy is not notarized \u{2014} a build from source"
        case .notarizationUnconfirmed: return "notarization not confirmed yet (checked again at the next check)"
        }
    }
}

public enum Installability: Equatable, Sendable {
    case installable
    case checksOnly(ChecksOnlyReason)

    public var reason: ChecksOnlyReason? {
        if case .checksOnly(let reason) = self { return reason }
        return nil
    }
}
