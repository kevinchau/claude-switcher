import Darwin
import XCTest
@testable import ClaudeSwitcherCore

// MARK: - Fixed facts

/// The facts every updater test shares. The paths are names only: the fakes below never touch
/// a disk, and the tests that do use temporary directories of their own.
enum UpdateFixture {
    static let team = "FTHBLX7S63"
    static let bundleID = "tech.local.claude-switcher"
    static let v060 = ReleaseVersion(major: 0, minor: 6, patch: 0)
    static let v070 = ReleaseVersion(major: 0, minor: 7, patch: 0)
    static let v080 = ReleaseVersion(major: 0, minor: 8, patch: 0)
    static let trust = SwitcherTrust(teamID: team, identifier: bundleID, runningVersion: v070)
    static let digest = String(repeating: "5a", count: 32)
    static let host = "11111111-2222-3333-4444-555555555555"
    static let otherHost = "99999999-8888-7777-6666-555555555555"

    static let configDirectory = "/Users/testhome/.config/claude-switcher"
    static let updates = configDirectory + "/updates"
    static let install = "/Applications/Claude Switcher.app"
    static let executable = install + "/Contents/MacOS/claude-switcher"
    static let claudeApp = "/Applications/Claude.app"
    static let temporaryItems = "/private/var/folders/zz/test/T/TemporaryItems"
    static let staging = temporaryItems + "/NSIRD_claude-switcher_TEST"
    static let staged = staging + "/Claude Switcher.app"
    static let mountPoint = updates + "/mounts/dmg.AbC123"
    static let device = "/dev/disk9"
    static let dataVolume: dev_t = 16_777_232

    static func dmg(_ tag: String = "v0.8.0") -> String { updates + "/downloads/\(tag)/Claude.Switcher.dmg" }
    static func previous(_ version: ReleaseVersion) -> String { updates + "/previous/\(version)/Claude Switcher.app" }

    static func candidate(_ version: ReleaseVersion = v080, digest: String = digest, size: Int = 791_611) -> ReleaseCandidate {
        ReleaseCandidate(version: version, assetSize: size, digestHex: digest, immutable: false)
    }

    static func identity(_ version: ReleaseVersion?, team: String? = team, identifier: String? = bundleID,
                         flags: UInt32 = 0x10000, path: String? = nil) -> CodeIdentity {
        CodeIdentity(teamID: team, identifier: identifier, flags: flags, version: version, path: path)
    }

    static func runningCopy(version: ReleaseVersion? = v070, identity: CodeIdentity? = nil, bundlePath: String = install,
                            executablePath: String? = nil, processExecutablePath: String?? = nil,
                            bundleIdentifier: String? = bundleID, parentDirectory: String? = nil,
                            volumeIsReadOnly: Bool = false, bundleIsWritable: Bool = true, parentIsWritable: Bool = true,
                            isTranslocated: Bool = false) -> RunningCopy {
        let executable = executablePath ?? bundlePath + "/Contents/MacOS/claude-switcher"
        return RunningCopy(
            identity: identity ?? Self.identity(version),
            bundlePath: bundlePath, executablePath: executable,
            processExecutablePath: processExecutablePath ?? executable,
            bundleIdentifier: bundleIdentifier,
            parentDirectory: parentDirectory ?? (bundlePath as NSString).deletingLastPathComponent,
            volumeIsReadOnly: volumeIsReadOnly, bundleIsWritable: bundleIsWritable, parentIsWritable: parentIsWritable,
            isTranslocated: isTranslocated)
    }

    static func prepared(_ candidate: ReleaseCandidate = candidate()) -> PreparedUpdate {
        PreparedUpdate(stagedAppPath: staged, dmgPath: dmg(candidate.tag), candidate: candidate,
                       verifiedIdentity: identity(candidate.version), verifiedAt: Date(timeIntervalSince1970: 1_791_000_000))
    }

    static func handoff(_ phase: UpdateHandoff.Phase, kind: UpdateHandoff.Kind = .update, from: ReleaseVersion = v070,
                        to: ReleaseVersion = v080, host: String = host, failure: String? = nil) -> UpdateHandoff {
        var record = UpdateHandoff(host: host, phase: phase, kind: kind, from: from, to: to, tag: to.tag, digest: digest,
                                   installPath: install, stagedPath: staged, oldPid: 4242,
                                   startedAt: Date(timeIntervalSince1970: 1_791_000_000), launchAtLoginWasEnabled: true)
        if kind == .revert { record.tag = from.tag }
        record.failure = failure
        return record
    }
}

// MARK: - A scripted prepare

/// A stand-in for the disk, hdiutil, spctl and the network during a prepare. Every effect is
/// recorded in order; nothing outside this object changes. Its `remove` fails the test for any
/// path outside `updates/downloads/`, `updates/mounts/` or the staged copy this prepare made —
/// and for any path with a `..` in it, whatever it starts with.
final class FakePrepare: @unchecked Sendable {

    // Script
    var candidate: ReleaseCandidate
    /// A disk image of this size is already downloaded.
    var existingDMG: Int?
    var downloadRefusal: Refusal?
    var downloadedBytes: Int?
    var digestOnDisk: String?
    var freeBytes: Int64 = 1 << 36
    /// Free space by path, where it differs from `freeBytes`.
    var freeSpaceByPath: [String: Int64] = [:]
    /// Keyed by "dmg", "mounted", "staged" (the validity check) or the same with "+req".
    var signatureFailures: [String: SignatureRefusal] = [:]
    var mountedIdentity: CodeIdentity
    var stagedIdentity: CodeIdentity
    var license: Result<Bool, Refusal> = .success(false)
    var attachFailure: AttachFailure?
    /// After a failed attach, `hdiutil info` still lists the image as attached.
    var attachLeavesImageAttached = false
    var mountEntries: [DirectoryEntry] = [
        DirectoryEntry(name: "Applications", kind: .symlink, linkTarget: "/Applications"),
        DirectoryEntry(name: "Claude Switcher.app", kind: .directory),
    ]
    /// The NSIRD folder this copy stages in: another copy of Claude Switcher has its own.
    let stagingFolder: String
    var stagingResult: Result<String, Refusal>
    var copyRefusal: Refusal?
    var quarantineRefusal: Refusal?
    var verdict: AssessmentVerdict = .accepted
    var stagedDevice: dev_t = UpdateFixture.dataVolume
    var installDevice: dev_t = UpdateFixture.dataVolume
    var detachSucceeds = true
    /// Images that are not the updater's: never to be detached.
    var otherImages: [AttachedImage] = [
        AttachedImage(imagePath: "/Users/testhome/Downloads/Other.dmg", devices: ["/dev/disk4s1", "/dev/disk4"]),
    ]
    /// `listDirectory` and `lstatKind` answers for reconcile tests.
    var directories: [String: [DirectoryEntry]] = [:]
    var kinds: [String: FileKind] = [:]
    var bundleIdentifiers: [String: String] = [:]
    var versions: [String: ReleaseVersion] = [:]
    var moveResult: Result<String, FileError>?
    var trashResult: Result<String, FileError> = .success("/Users/testhome/.Trash/item")
    /// Paths `remove` cannot remove (it reports them still there).
    var removeFails: Set<String> = []
    /// Another copy of Claude Switcher holds the prepare lock.
    var prepareLockHeld = false
    var clock = Date(timeIntervalSince1970: 1_791_000_000)

    // Record
    private(set) var steps: [PrepareStep] = []
    private(set) var events: [String] = []
    private(set) var removed: [String] = []
    private(set) var removedFolders: [String] = []
    private(set) var detached: [String] = []
    private(set) var notes: [UpdateNote] = []
    private(set) var requirements: [String] = []
    private(set) var quarantined: [String] = []
    private(set) var moved: [String] = []
    private(set) var trashed: [String] = []
    private(set) var downloads = 0
    private(set) var attaches = 0
    private(set) var hashed = 0
    private(set) var lockTakes = 0
    private(set) var lockReleases = 0
    private var attached: [AttachedImage] = []
    private var downloaded = false
    private var dmgInPlace = false
    private var stagedCopyMade = false

    init(candidate: ReleaseCandidate = UpdateFixture.candidate(), staging: String = UpdateFixture.staging) {
        self.candidate = candidate
        stagingFolder = staging
        stagingResult = .success(staging)
        mountedIdentity = UpdateFixture.identity(candidate.version)
        stagedIdentity = UpdateFixture.identity(candidate.version)
    }

    var dmg: String { UpdateFixture.dmg(candidate.tag) }
    var partial: String { dmg + ".partial" }
    /// The copy staged in `stagingFolder`.
    var staged: String { stagingFolder + "/" + SwitcherDisk.appName }
    var stillAttached: [AttachedImage] { attached }
    var effectCount: Int { removed.count + removedFolders.count + detached.count + moved.count + trashed.count }

    private func log(_ event: String) { events.append(event) }

    /// An earlier check of this process staged a copy and kept it: it is this process's to remove.
    func keepsStagedCopyFromAnEarlierCheck() { stagedCopyMade = true }

    private func role(_ path: String) -> String {
        if path == dmg { return "dmg" }
        if path.hasPrefix(UpdateFixture.mountPoint + "/") { return "mounted" }
        if path.hasPrefix(stagingFolder + "/") { return "staged" }
        return path
    }

    private func remove(_ path: String) -> Bool {
        // A prefix proves nothing about a path that climbs out of it again.
        if path.split(separator: "/").contains("..") || (path as NSString).standardizingPath != path {
            XCTFail("remove of a path that is not plainly spelled: \(path)")
        }
        let allowed = path.hasPrefix(UpdateFixture.updates + "/downloads/")
            || path.hasPrefix(UpdateFixture.updates + "/mounts/")
            || (path == staged && stagedCopyMade)
        if !allowed { XCTFail("remove outside the updater's own folders: \(path)") }
        removed.append(path)
        log("remove \(path)")
        guard !removeFails.contains(path) else { return false }
        if path == staged { stagedCopyMade = false }
        if path == dmg { dmgInPlace = false; existingDMG = nil }
        if path == partial { downloaded = false }
        return true
    }

    var env: SwitcherUpdater.PrepareEnvironment {
        SwitcherUpdater.PrepareEnvironment(
            download: { url, destination, expected in
                self.downloads += 1
                self.log("download \(url.absoluteString) -> \(destination) (\(expected))")
                if let refusal = self.downloadRefusal { return refusal }
                self.downloaded = true
                return nil
            },
            fileSize: { path in
                if path == self.dmg { return self.existingDMG ?? (self.dmgInPlace ? self.candidate.assetSize : nil) }
                if path == self.partial, self.downloaded { return self.downloadedBytes ?? self.candidate.assetSize }
                return nil
            },
            sha256Hex: { path in
                self.hashed += 1
                self.log("hash \(path)")
                return self.digestOnDisk ?? self.candidate.digestHex
            },
            freeSpace: { path in self.freeSpaceByPath[path] ?? self.freeBytes },
            moveFile: { from, to in
                self.log("move \(from) -> \(to)")
                if from == self.partial, to == self.dmg { self.dmgInPlace = true; self.downloaded = false }
                return 0
            },
            makeDirectory: { _ in 0 },
            verify: { path, requirement in
                let key = self.role(path) + (requirement == nil ? "" : "+req")
                self.log("verify \(key)")
                if let requirement { self.requirements.append(requirement) }
                if let failure = self.signatureFailures[key] { return .failure(failure) }
                switch self.role(path) {
                case "dmg": return .success(UpdateFixture.identity(nil, identifier: "Claude Switcher", flags: 0))
                case "mounted": return .success(self.mountedIdentity)
                case "staged": return .success(self.stagedIdentity)
                default:
                    if let version = self.versions[path] { return .success(UpdateFixture.identity(version)) }
                    return .failure(SignatureRefusal(status: -67062, message: "not signed"))
                }
            },
            imageHasLicense: { _ in self.log("imageinfo"); return self.license },
            attach: { image, mounts in
                self.attaches += 1
                self.log("attach \(image) at \(mounts)")
                let ours = AttachedImage(imagePath: image, devices: [UpdateFixture.device + "s1", UpdateFixture.device])
                if let failure = self.attachFailure {
                    if self.attachLeavesImageAttached { self.attached.append(ours) }
                    return .failure(failure)
                }
                self.attached.append(ours)
                return .success(Mount(mountPoint: UpdateFixture.mountPoint, device: UpdateFixture.device))
            },
            attachedImages: { self.otherImages + self.attached },
            detach: { device in
                self.detached.append(device)
                self.log("detach \(device)")
                guard self.detachSucceeds else { return false }
                self.attached.removeAll { $0.devices.contains(device) }
                return true
            },
            listDirectory: { path in
                if path == UpdateFixture.mountPoint { return self.mountEntries }
                return self.directories[path]
            },
            stagingDirectory: { _ in self.log("staging folder"); return self.stagingResult },
            copyBundle: { from, to in
                self.log("copy \(from) -> \(to)")
                self.stagedCopyMade = true
                return self.copyRefusal
            },
            removeQuarantine: { path in
                self.quarantined.append(path)
                self.log("unquarantine \(path)")
                return self.quarantineRefusal
            },
            assess: { _ in self.log("spctl"); return self.verdict },
            prewarm: { _ in self.log("gktool") },
            lstatKind: { path in
                if let kind = self.kinds[path] { return kind }
                if path == self.staged { return self.stagedCopyMade ? .directory : nil }
                return self.directories[path] != nil ? .directory : nil
            },
            deviceOf: { path in
                if path == self.staged { return self.stagedDevice }
                if path == "/Applications" { return self.installDevice }
                return nil
            },
            canonicalPath: { $0 },
            bundleIdentifierOnDisk: { self.bundleIdentifiers[$0] },
            remove: { self.remove($0) },
            removeEmptyFolder: { path in
                // Not recursive, and still only ever a folder of the updater's own: a download
                // folder, or a staging folder FileManager made.
                if !(path.hasPrefix(UpdateFixture.updates + "/downloads/")
                     || path.hasPrefix(UpdateFixture.temporaryItems + "/NSIRD_")) {
                    XCTFail("rmdir outside the updater's own folders: \(path)")
                }
                self.removedFolders.append(path)
                self.log("rmdir \(path)")
            },
            moveToPrevious: { bundle, version in
                self.moved.append(bundle)
                self.log("move \(bundle) to previous/\(version)")
                return self.moveResult ?? .success(UpdateFixture.previous(version))
            },
            trash: { path in
                self.trashed.append(path)
                self.log("trash \(path)")
                return self.trashResult
            },
            takePrepareLock: {
                self.lockTakes += 1
                self.log("lock")
                guard !self.prepareLockHeld else { return nil }
                return { self.lockReleases += 1; self.log("unlock") }
            },
            note: { note in self.notes.append(note); self.log("note \(note)") },
            now: { self.clock },
            hook: { step in self.steps.append(step); self.log("step \(step.rawValue)") })
    }
}

// MARK: - A scripted commit

/// A stand-in for the install location, the swap, LaunchServices and the relaunch. `bundles`
/// says which version sits at which path; `swap` exchanges them as `renamex_np` would. Time is
/// virtual: `sleep` advances a counter. Its `remove` fails the test for anything but the staged
/// copy before any swap.
final class FakeCommit: @unchecked Sendable {

    // The world
    var bundles: [String: ReleaseVersion] = [UpdateFixture.install: UpdateFixture.v070,
                                             UpdateFixture.staged: UpdateFixture.v080]
    var kinds: [String: FileKind] = [:]
    var bundleIdentifiers: [String: String] = [:]
    var links: [String: String] = [:]
    var processPath: String? = UpdateFixture.executable
    var notWritable: Set<String> = []
    var devices: [String: dev_t] = [:]
    var invalidAt: [String: SignatureRefusal] = [:]
    /// The check at the install location fails once something has been swapped into it.
    var invalidAtInstallAfterSwap: SignatureRefusal?
    /// One errno per swap call, in order; 0 when the list runs out.
    var swapErrnos: [Int32] = []
    var handoffRefusal: Refusal?
    var blockers: [SwitcherIdle.Blocker] = []
    var onStep: [CommitStep: (FakeCommit) -> Void] = [:]
    /// The menu or a window is open until this much virtual time has passed.
    var uiOpenFor: Duration = .zero
    var launchResult: Result<Int32, RelaunchFailure> = .success(4300)
    var moveResult: Result<String, FileError>?
    var trashResult: Result<String, FileError> = .success("/Users/testhome/.Trash/Claude Switcher.app")
    var launchAtLogin = true

    // Record
    private(set) var events: [String] = []
    private(set) var steps: [CommitStep] = []
    private(set) var swaps: [String] = []
    private(set) var launches: [String] = []
    private(set) var launchedAt: [Duration] = []
    private(set) var terminated = 0
    private(set) var handoffs: [UpdateHandoff] = []
    private(set) var removed: [String] = []
    private(set) var removedFolders: [String] = []
    private(set) var moved: [String] = []
    private(set) var trashed: [String] = []
    private(set) var registered: [String] = []
    private(set) var notes: [UpdateNote] = []
    /// Every requirement a signature check was asked to hold to.
    private(set) var requirements: [String] = []
    private(set) var slept = Duration.zero
    private var swappedOnce = false
    /// Where a written hand-off goes as well, when a test reads it back through a store.
    var handoffSink: (@Sendable (UpdateHandoff) async -> Void)?

    var effectCount: Int { swaps.count + launches.count + terminated + removed.count + moved.count + trashed.count }

    private func log(_ event: String) { events.append(event) }
    private func swap(_ a: String, _ b: String) -> Int32 {
        swaps.append("\(a) <-> \(b)")
        let code = swapErrnos.isEmpty ? 0 : swapErrnos.removeFirst()
        log("swap \(a) <-> \(b) = \(code)")
        guard code == 0 else { return code }
        let first = bundles[a], second = bundles[b]
        bundles[a] = second
        bundles[b] = first
        swappedOnce = true
        return 0
    }

    var env: SwitcherUpdater.CommitEnvironment {
        SwitcherUpdater.CommitEnvironment(
            lstatKind: { path in
                if let kind = self.kinds[path] { return kind }
                return self.bundles[path] != nil ? .directory : nil
            },
            canonicalPath: { path in self.links[path] ?? path },
            bundleIdentifierOnDisk: { path in
                self.bundles[path] == nil ? nil : (self.bundleIdentifiers[path] ?? UpdateFixture.bundleID)
            },
            versionOnDisk: { path in
                self.bundles[path].map { AppVersion(short: $0.description, build: $0.description) }
            },
            processExecutablePath: { self.processPath },
            isWritable: { !self.notWritable.contains($0) },
            deviceOf: { path in self.devices[path] ?? UpdateFixture.dataVolume },
            verify: { path, requirement in
                self.log("verify \(path)\(requirement == nil ? "" : " +req")")
                if let requirement { self.requirements.append(requirement) }
                if let failure = self.invalidAt[path] { return .failure(failure) }
                if path == UpdateFixture.install, self.swappedOnce, let failure = self.invalidAtInstallAfterSwap {
                    return .failure(failure)
                }
                guard let version = self.bundles[path] else {
                    return .failure(SignatureRefusal(status: -67062, message: "nothing there"))
                }
                return .success(UpdateFixture.identity(version, path: path))
            },
            swap: { self.swap($0, $1) },
            registerWithLaunchServices: { self.registered.append($0); self.log("register \($0)") },
            moveToPrevious: { bundle, version in
                self.moved.append(bundle)
                self.log("move \(bundle) to previous/\(version)")
                if let result = self.moveResult { return result }
                self.bundles[UpdateFixture.previous(version)] = self.bundles.removeValue(forKey: bundle)
                return .success(UpdateFixture.previous(version))
            },
            trash: { path in
                self.trashed.append(path)
                self.log("trash \(path)")
                if case .success = self.trashResult { self.bundles[path] = nil }
                return self.trashResult
            },
            remove: { path in
                if path != UpdateFixture.staged || self.swappedOnce {
                    XCTFail("remove of anything but the unswapped staged copy: \(path)")
                }
                self.removed.append(path)
                self.log("remove \(path)")
                self.bundles[path] = nil
                return true
            },
            removeEmptyFolder: { path in self.removedFolders.append(path); self.log("rmdir \(path)") },
            writeHandoff: { handoff in
                self.handoffs.append(handoff)
                self.log("handoff \(handoff.kind.rawValue) \(handoff.phase.rawValue)")
                if let refusal = self.handoffRefusal { return refusal }
                await self.handoffSink?(handoff)
                return nil
            },
            note: { note in self.notes.append(note) },
            idleBlockers: { self.blockers },
            uiIsOpen: { self.slept < self.uiOpenFor },
            launch: { path, pid in
                self.launches.append(path)
                self.launchedAt.append(self.slept)
                self.log("launch \(path) --after-update \(pid)")
                return self.launchResult
            },
            terminateSelf: { self.terminated += 1; self.log("terminate") },
            sleep: { self.slept += $0 },
            launchAtLoginIsEnabled: { self.launchAtLogin },
            now: { Date(timeIntervalSince1970: 1_791_000_000) },
            host: UpdateFixture.host,
            processID: 4242,
            hook: { step in
                self.steps.append(step)
                self.log("step \(step.rawValue)")
                self.onStep[step]?(self)
            })
    }
}

// MARK: - Temporary stores

/// A store over a fresh temporary directory, with this test's fixed host.
func makeTemporaryStore(host: String = UpdateFixture.host) throws -> (SwitcherUpdateStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("switcher-updates-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (SwitcherUpdateStore(directory: directory, host: host), directory)
}
