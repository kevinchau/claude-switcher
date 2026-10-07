import Darwin
import Foundation
import Security

// MARK: - What the seams speak

public enum FileKind: String, Equatable, Sendable { case directory, file, symlink, other }

public struct DirectoryEntry: Equatable, Sendable {
    public let name: String
    public let kind: FileKind
    /// For a link, what it says — read, never followed.
    public let linkTarget: String?

    public init(name: String, kind: FileKind, linkTarget: String? = nil) {
        self.name = name
        self.kind = kind
        self.linkTarget = linkTarget
    }
}

/// A disk image attached by this prepare.
public struct Mount: Equatable, Sendable {
    public let mountPoint: String
    /// The whole disk (the shortest `dev-entry`), which is what gets detached.
    public let device: String

    public init(mountPoint: String, device: String) {
        self.mountPoint = mountPoint
        self.device = device
    }
}

public enum AttachFailure: Error, Equatable, Sendable {
    case timedOut
    case failed(String)
}

/// One image `hdiutil info` lists.
public struct AttachedImage: Equatable, Sendable {
    public let imagePath: String
    public let devices: [String]

    public init(imagePath: String, devices: [String]) {
        self.imagePath = imagePath
        self.devices = devices
    }

    public var detachDevice: String? { devices.min { $0.count < $1.count } }
}

public enum AssessmentVerdict: Equatable, Sendable {
    case accepted
    /// spctl said no (exit 1 or 3, or a verdict of false).
    case rejected(String)
    /// spctl could not be run, or did not answer in time.
    case unavailable(String)
}

/// An errno from a move.
public struct FileError: Error, Equatable, Sendable {
    public let code: Int32
    public init(_ code: Int32) { self.code = code }
}

public struct RelaunchFailure: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// What a prepare or a commit tells `state.json` while it runs.
public enum UpdateNote: Equatable, Sendable {
    /// A staging folder this process has made.
    case staging(String)
    /// This process's own staging folder is gone or emptied.
    case stagingGone(String)
    /// A disk image this prepare attached and could not detach; informational.
    case stillMounted(String?)
}

extension SwitcherUpdateState {
    /// A note, applied. Two copies of Claude Switcher can each have a staging folder — the one
    /// holding the lock keeps a verified copy for hours while another's manual check stages and
    /// discards its own — so each is recorded beside the others, and a copy only ever takes its
    /// own folder off the record: never the one the lock holder still needs found after a crash.
    public mutating func apply(_ note: UpdateNote) {
        switch note {
        case .staging(let folder):
            staging = (staging ?? []).filter { $0 != folder } + [folder]
        case .stagingGone(let folder):
            let left = (staging ?? []).filter { $0 != folder }
            staging = left.isEmpty ? nil : left
        case .stillMounted(let path):
            // Any image noted sends the next check to sweep every image of ours: one note
            // standing in for another loses nothing.
            mounted = path
        }
    }
}

public enum CommitOutcome: Equatable, Sendable {
    /// The new copy is running; this process has asked to end.
    case launched(Int32)
    /// The new copy is in place but could not be started; it starts at the next launch, and this
    /// process keeps running. Nothing was swapped back or deleted.
    case restartPending(String)
    /// The copy in place failed its check right after the swap and was swapped back.
    case rolledBack(Refusal)
    /// Nothing was moved.
    case refusedBeforeSwap(Refusal)
    /// Something started meanwhile; nothing was moved, and the commit is tried again later.
    case abortedNotIdle([SwitcherIdle.Blocker])
}

/// The new instance's reading of `handoff.json`.
public struct HandoffResult: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable { case succeeded, failed, rolledBack, interrupted, unexpected, foreign }
    public enum Disposition: Equatable, Sendable {
        /// Finished, and kept until this start has got going (``SwitcherUpdateStore/settleStart(version:isLockHolder:)``):
        /// until then it is what sends a version that never starts back to the one before it.
        case deleteAtSettle
        case archiveAsFailed
        case keep
    }

    public var verdict: Verdict
    public var notice: SwitcherNotice?
    public var findings: [String] = []
    public var rejection: Rejection?
    public var lastInstall: InstallRecord?
    public var lastFailure: FailureRecord?
    /// The tag whose download folder is no longer needed.
    public var deleteDownloadsFor: String?
    public var disposition: Disposition
    public var launchAtLoginWasEnabled: Bool?

    public init(verdict: Verdict, disposition: Disposition) {
        self.verdict = verdict
        self.disposition = disposition
    }
}

/// What the launch-time pass did, for Diagnostics and the menu.
public struct LaunchReport: Equatable, Sendable {
    public var handoff: HandoffResult?
    public var revert: CommitOutcome?
    public var findings: [String] = []
    public var state: SwitcherUpdateState
}

/// Claude Switcher replacing itself with a newer release of itself.
///
/// The only process anything here can start is a new copy of Claude Switcher, and the only one
/// it can end is its own: none of the environments has a field that could reach Claude.
public enum SwitcherUpdater {

    public static let foreignFinding = "ignoring update records written on another Mac (synced ~/.config?)"

    // MARK: - Seams

    /// Lets go of a lock taken by ``PrepareEnvironment/takePrepareLock``.
    public typealias LockRelease = @Sendable () -> Void

    public struct CheckEnvironment: Sendable {
        public var fetch: @Sendable (URLRequest) async -> FetchResult
        public var now: @Sendable () -> Date

        public init(fetch: @escaping @Sendable (URLRequest) async -> FetchResult, now: @escaping @Sendable () -> Date) {
            self.fetch = fetch
            self.now = now
        }
    }

    /// Everything a prepare touches. Blocking: run it off the main actor.
    public struct PrepareEnvironment: Sendable {
        /// Fetches `url` into the file at the second argument, at most the given number of bytes.
        public var download: @Sendable (_ url: URL, _ destination: String, _ expectedBytes: Int) async -> Refusal?
        public var fileSize: @Sendable (String) -> Int?
        public var sha256Hex: @Sendable (String) -> String?
        public var freeSpace: @Sendable (String) -> Int64?
        public var moveFile: @Sendable (_ from: String, _ to: String) -> Int32
        public var makeDirectory: @Sendable (String) -> Int32
        public var verify: @Sendable (_ path: String, _ requirement: String?) -> Result<CodeIdentity, SignatureRefusal>
        public var imageHasLicense: @Sendable (String) -> Result<Bool, Refusal>
        public var attach: @Sendable (_ image: String, _ mountsDirectory: String) -> Result<Mount, AttachFailure>
        /// `hdiutil info`: `nil` when it could not be read.
        public var attachedImages: @Sendable () -> [AttachedImage]?
        public var detach: @Sendable (_ device: String) -> Bool
        public var listDirectory: @Sendable (String) -> [DirectoryEntry]?
        public var stagingDirectory: @Sendable (_ installPath: String) -> Result<String, Refusal>
        public var copyBundle: @Sendable (_ from: String, _ to: String) -> Refusal?
        public var removeQuarantine: @Sendable (String) -> Refusal?
        public var assess: @Sendable (String) -> AssessmentVerdict
        public var prewarm: @Sendable (String) -> Void
        public var lstatKind: @Sendable (String) -> FileKind?
        public var deviceOf: @Sendable (String) -> dev_t?
        public var canonicalPath: @Sendable (String) -> String?
        public var bundleIdentifierOnDisk: @Sendable (String) -> String?
        /// Recursive; permitted only under `updates/downloads/`, `updates/mounts/`, or on a staged
        /// copy this process made and has not swapped. Whether the path is gone afterwards.
        public var remove: @Sendable (String) -> Bool
        /// `rmdir`: a folder that is not empty stays.
        public var removeEmptyFolder: @Sendable (String) -> Void
        public var moveToPrevious: @Sendable (_ bundle: String, _ version: ReleaseVersion) -> Result<String, FileError>
        public var trash: @Sendable (String) -> Result<String, FileError>
        /// One prepare at a time across every copy of Claude Switcher on this Mac, never waited
        /// for: the way to let go, or `nil` when another copy holds it. Held while anything under
        /// `updates/downloads/` or `updates/mounts/` is fetched, verified, detached or removed, so
        /// one copy never pulls a disk image or a download out from under another's check.
        public var takePrepareLock: @Sendable () -> LockRelease?
        public var note: @Sendable (UpdateNote) async -> Void
        public var now: @Sendable () -> Date
        public var hook: @Sendable (PrepareStep) -> Void
        /// The flags the real signature check was built with; `nil` for an environment of test
        /// closures. Never anything but ``CodeSignature/validationFlags`` in the app.
        public var verifyFlags: SecCSFlags?

        public init(
            download: @escaping @Sendable (URL, String, Int) async -> Refusal?,
            fileSize: @escaping @Sendable (String) -> Int?,
            sha256Hex: @escaping @Sendable (String) -> String?,
            freeSpace: @escaping @Sendable (String) -> Int64?,
            moveFile: @escaping @Sendable (String, String) -> Int32,
            makeDirectory: @escaping @Sendable (String) -> Int32,
            verify: @escaping @Sendable (String, String?) -> Result<CodeIdentity, SignatureRefusal>,
            imageHasLicense: @escaping @Sendable (String) -> Result<Bool, Refusal>,
            attach: @escaping @Sendable (String, String) -> Result<Mount, AttachFailure>,
            attachedImages: @escaping @Sendable () -> [AttachedImage]?,
            detach: @escaping @Sendable (String) -> Bool,
            listDirectory: @escaping @Sendable (String) -> [DirectoryEntry]?,
            stagingDirectory: @escaping @Sendable (String) -> Result<String, Refusal>,
            copyBundle: @escaping @Sendable (String, String) -> Refusal?,
            removeQuarantine: @escaping @Sendable (String) -> Refusal?,
            assess: @escaping @Sendable (String) -> AssessmentVerdict,
            prewarm: @escaping @Sendable (String) -> Void,
            lstatKind: @escaping @Sendable (String) -> FileKind?,
            deviceOf: @escaping @Sendable (String) -> dev_t?,
            canonicalPath: @escaping @Sendable (String) -> String?,
            bundleIdentifierOnDisk: @escaping @Sendable (String) -> String?,
            remove: @escaping @Sendable (String) -> Bool,
            removeEmptyFolder: @escaping @Sendable (String) -> Void,
            moveToPrevious: @escaping @Sendable (String, ReleaseVersion) -> Result<String, FileError>,
            trash: @escaping @Sendable (String) -> Result<String, FileError>,
            takePrepareLock: @escaping @Sendable () -> LockRelease?,
            note: @escaping @Sendable (UpdateNote) async -> Void,
            now: @escaping @Sendable () -> Date,
            hook: @escaping @Sendable (PrepareStep) -> Void = { _ in }
        ) {
            self.download = download
            self.fileSize = fileSize
            self.sha256Hex = sha256Hex
            self.freeSpace = freeSpace
            self.moveFile = moveFile
            self.makeDirectory = makeDirectory
            self.verify = verify
            self.imageHasLicense = imageHasLicense
            self.attach = attach
            self.attachedImages = attachedImages
            self.detach = detach
            self.listDirectory = listDirectory
            self.stagingDirectory = stagingDirectory
            self.copyBundle = copyBundle
            self.removeQuarantine = removeQuarantine
            self.assess = assess
            self.prewarm = prewarm
            self.lstatKind = lstatKind
            self.deviceOf = deviceOf
            self.canonicalPath = canonicalPath
            self.bundleIdentifierOnDisk = bundleIdentifierOnDisk
            self.remove = remove
            self.removeEmptyFolder = removeEmptyFolder
            self.moveToPrevious = moveToPrevious
            self.trash = trash
            self.takePrepareLock = takePrepareLock
            self.note = note
            self.now = now
            self.hook = hook
        }
    }

    /// Everything a commit or a revert touches. There is no field that can start, quit or signal
    /// any process other than this one and the new copy of itself. The real one is built in the
    /// app target, out of reach of the tests.
    public struct CommitEnvironment: Sendable {
        public var lstatKind: @Sendable (String) -> FileKind?
        public var canonicalPath: @Sendable (String) -> String?
        public var bundleIdentifierOnDisk: @Sendable (String) -> String?
        public var versionOnDisk: @Sendable (String) -> AppVersion?
        public var processExecutablePath: @Sendable () -> String?
        public var isWritable: @Sendable (String) -> Bool
        public var deviceOf: @Sendable (String) -> dev_t?
        public var verify: @Sendable (_ path: String, _ requirement: String?) -> Result<CodeIdentity, SignatureRefusal>
        /// `renamex_np(RENAME_SWAP)`: 0 or an errno.
        public var swap: @Sendable (String, String) -> Int32
        public var registerWithLaunchServices: @Sendable (String) -> Void
        public var moveToPrevious: @Sendable (_ bundle: String, _ version: ReleaseVersion) -> Result<String, FileError>
        public var trash: @Sendable (String) -> Result<String, FileError>
        /// Only ever the staged copy, and only before the swap. Whether it is gone afterwards.
        public var remove: @Sendable (String) -> Bool
        public var removeEmptyFolder: @Sendable (String) -> Void
        public var writeHandoff: @Sendable (UpdateHandoff) async -> Refusal?
        public var note: @Sendable (UpdateNote) async -> Void
        public var idleBlockers: @MainActor () -> [SwitcherIdle.Blocker]
        public var uiIsOpen: @MainActor () -> Bool
        /// Starts the bundle at the path as a new instance, telling it this process's pid.
        public var launch: @MainActor (_ bundlePath: String, _ oldPID: Int32) async -> Result<Int32, RelaunchFailure>
        public var terminateSelf: @MainActor () -> Void
        public var sleep: @MainActor (Duration) async -> Void
        public var launchAtLoginIsEnabled: @MainActor () -> Bool
        public var now: @Sendable () -> Date
        public var host: String
        public var processID: Int32
        public var hook: @Sendable (CommitStep) -> Void

        public init(
            lstatKind: @escaping @Sendable (String) -> FileKind?,
            canonicalPath: @escaping @Sendable (String) -> String?,
            bundleIdentifierOnDisk: @escaping @Sendable (String) -> String?,
            versionOnDisk: @escaping @Sendable (String) -> AppVersion?,
            processExecutablePath: @escaping @Sendable () -> String?,
            isWritable: @escaping @Sendable (String) -> Bool,
            deviceOf: @escaping @Sendable (String) -> dev_t?,
            verify: @escaping @Sendable (String, String?) -> Result<CodeIdentity, SignatureRefusal>,
            swap: @escaping @Sendable (String, String) -> Int32,
            registerWithLaunchServices: @escaping @Sendable (String) -> Void,
            moveToPrevious: @escaping @Sendable (String, ReleaseVersion) -> Result<String, FileError>,
            trash: @escaping @Sendable (String) -> Result<String, FileError>,
            remove: @escaping @Sendable (String) -> Bool,
            removeEmptyFolder: @escaping @Sendable (String) -> Void,
            writeHandoff: @escaping @Sendable (UpdateHandoff) async -> Refusal?,
            note: @escaping @Sendable (UpdateNote) async -> Void,
            idleBlockers: @escaping @MainActor () -> [SwitcherIdle.Blocker],
            uiIsOpen: @escaping @MainActor () -> Bool,
            launch: @escaping @MainActor (String, Int32) async -> Result<Int32, RelaunchFailure>,
            terminateSelf: @escaping @MainActor () -> Void,
            sleep: @escaping @MainActor (Duration) async -> Void,
            launchAtLoginIsEnabled: @escaping @MainActor () -> Bool,
            now: @escaping @Sendable () -> Date,
            host: String,
            processID: Int32,
            hook: @escaping @Sendable (CommitStep) -> Void = { _ in }
        ) {
            self.lstatKind = lstatKind
            self.canonicalPath = canonicalPath
            self.bundleIdentifierOnDisk = bundleIdentifierOnDisk
            self.versionOnDisk = versionOnDisk
            self.processExecutablePath = processExecutablePath
            self.isWritable = isWritable
            self.deviceOf = deviceOf
            self.verify = verify
            self.swap = swap
            self.registerWithLaunchServices = registerWithLaunchServices
            self.moveToPrevious = moveToPrevious
            self.trash = trash
            self.remove = remove
            self.removeEmptyFolder = removeEmptyFolder
            self.writeHandoff = writeHandoff
            self.note = note
            self.idleBlockers = idleBlockers
            self.uiIsOpen = uiIsOpen
            self.launch = launch
            self.terminateSelf = terminateSelf
            self.sleep = sleep
            self.launchAtLoginIsEnabled = launchAtLoginIsEnabled
            self.now = now
            self.host = host
            self.processID = processID
            self.hook = hook
        }
    }

    // MARK: - Where the updater's own folders are

    /// `realpath(<configDir>)/updates/<folder>/`: the prefix under which a path is the updater's
    /// own. The config folder is resolved, `updates` and `<folder>` are not — so if either of
    /// them is a link, nothing resolves under the prefix and nothing there is ours.
    public static func ownedPrefix(_ folder: String, updatesDirectory: String,
                                   canonical: (String) -> String?) -> String {
        let configDirectory = (updatesDirectory as NSString).deletingLastPathComponent
        let resolved = canonical(configDirectory) ?? configDirectory
        return resolved + "/" + (updatesDirectory as NSString).lastPathComponent + "/" + folder + "/"
    }

    // MARK: - Check

    public static func check(runningVersion: ReleaseVersion?, env: CheckEnvironment) async -> CheckOutcome {
        let request = SwitcherReleaseFeed.request(userAgentVersion: runningVersion?.description ?? "unknown")
        switch await env.fetch(request) {
        case .transport(let description):
            return .offline(description)
        case .response(let status, let headers, let body):
            return SwitcherReleaseFeed.outcome(status: status, headers: headers, body: body, now: env.now())
        }
    }

    /// The facts a check is decided on, as the app knows them when it starts one.
    public struct CheckContext: Sendable {
        public var trust: SwitcherTrust?
        public var runningVersion: ReleaseVersion?
        public var installability: Installability
        public var settingOn: Bool
        public var isLockHolder: Bool
        public var configIsValid: Bool
        public var installPath: String
        public var updatesDirectory: String
        /// The verified copy this process already keeps for a commit, if any. A check that finds
        /// the same release keeps it instead of fetching and staging it again; a check that finds
        /// another release removes it, since it is no longer the latest.
        public var prepared: PreparedUpdate?

        public init(trust: SwitcherTrust?, runningVersion: ReleaseVersion?, installability: Installability,
                    settingOn: Bool, isLockHolder: Bool, configIsValid: Bool, installPath: String,
                    updatesDirectory: String, prepared: PreparedUpdate? = nil) {
            self.trust = trust
            self.runningVersion = runningVersion
            self.installability = installability
            self.settingOn = settingOn
            self.isLockHolder = isLockHolder
            self.configIsValid = configIsValid
            self.installPath = installPath
            self.updatesDirectory = updatesDirectory
            self.prepared = prepared
        }
    }

    /// One check, and the prepare it leads to.
    public struct CheckRun: Equatable, Sendable {
        public var outcome: CheckOutcome
        public var decision: Decision
        /// What prepare came to, when it ran — or the copy already kept, when the check found
        /// that same release. The only thing an alert may call "available".
        public var prepared: Result<PreparedUpdate, Refusal>?
        /// The verified copy kept for a commit after this check: only ever in an installable copy
        /// holding the lock. The one the context held, unless the check removed it.
        public var kept: PreparedUpdate?
        public var state: SwitcherUpdateState
    }

    /// Looks at the feed, decides, and prepares when the decision says so. Everything it records
    /// goes through `store` in one read-modify-write at the end. A copy that may not replace
    /// itself (checks only, or not the lock holder) removes the staged copy and the disk image
    /// it verified again at once. `preparing` hears which release is about to be fetched and
    /// checked, before anything is, so the app can say so.
    public static func runCheck(manual: Bool, context: CheckContext, store: SwitcherUpdateStore,
                                check checkEnv: CheckEnvironment, prepare prepareEnv: PrepareEnvironment,
                                preparing: @Sendable (ReleaseCandidate) async -> Void = { _ in }) async -> CheckRun {
        let running = context.runningVersion ?? context.trust?.runningVersion
        let outcome = await check(runningVersion: running, env: checkEnv)
        let now = checkEnv.now()
        var state = await store.load(now: now)
        if manual { SwitcherUpdatePolicy.manualCheckStarted(&state) }
        let decision = SwitcherUpdatePolicy.decision(
            state: state, outcome: outcome, runningVersion: running, trust: context.trust,
            installability: context.installability, settingOn: context.settingOn, isLockHolder: context.isLockHolder,
            configIsValid: context.configIsValid, manual: manual, now: now)

        var kept = context.prepared
        var dropped = false
        // The latest release is no longer the one kept — a newer one, or the kept one withdrawn:
        // what is kept is not installed. A check that did not reach the feed changes nothing.
        if let held = kept, case .candidate(let latest) = outcome, latest.key != held.candidate.key {
            await discard(held, updatesDirectory: context.updatesDirectory, env: prepareEnv)
            kept = nil
            dropped = true
        }

        var prepared: Result<PreparedUpdate, Refusal>?
        if case .prepare(let candidate) = decision.action, let trust = context.trust {
            if let held = kept, held.candidate.key == candidate.key {
                // Verified and staged by this process already: not fetched or staged again.
                prepared = .success(held)
            } else {
                await preparing(candidate)
                let result = await prepare(candidate: candidate, trust: trust, installPath: context.installPath,
                                           updatesDirectory: context.updatesDirectory, env: prepareEnv)
                prepared = result
                if case .success(let update) = result {
                    if context.installability == .installable, context.isLockHolder {
                        kept = update
                    } else {
                        await discard(update, updatesDirectory: context.updatesDirectory, env: prepareEnv)
                    }
                }
            }
        }

        let finished = prepareEnv.now()
        let result = prepared, keeps = kept != nil, wasDropped = dropped
        let recorded = (try? await store.update(now: finished) { state in
            if manual { SwitcherUpdatePolicy.manualCheckStarted(&state) }
            state.installPath = context.installPath
            state.lastCheckAt = now
            state.lastCheckResult = outcome
            state.nextCheckNotBefore = decision.nextCheckNotBefore
            if case .candidate(let candidate) = outcome { state.candidate = candidate }
            if wasDropped, !keeps { state.prepared = nil }
            guard case .prepare(let candidate) = decision.action, let result else { return }
            switch result {
            case .failure(let refusal):
                SwitcherUpdatePolicy.record(refusal, for: candidate, in: &state, now: finished)
            case .success(let update):
                SwitcherUpdatePolicy.recordPrepared(update, in: &state)
                if !keeps { state.prepared = nil }
            }
        }) ?? state
        return CheckRun(outcome: outcome, decision: decision, prepared: prepared, kept: kept, state: recorded)
    }

    // MARK: - Prepare

    /// Downloads, verifies and stages `candidate` next to `installPath`, in the order of the
    /// design's section 7. Writes only under `updatesDirectory` and in its own staging folder;
    /// whatever it staged and refused, it removes again itself.
    public static func prepare(candidate: ReleaseCandidate, trust: SwitcherTrust, installPath: String,
                               updatesDirectory: String, env: PrepareEnvironment) async -> Result<PreparedUpdate, Refusal> {
        let downloads = updatesDirectory + "/downloads"
        let folder = downloads + "/" + candidate.tag
        let dmg = folder + "/" + SwitcherReleaseFeed.assetName
        let partial = dmg + ".partial"
        let mounts = updatesDirectory + "/mounts"
        let installParent = (installPath as NSString).deletingLastPathComponent

        /// A release file refused for what it is, is not kept — nor the folder that held only it.
        func refuse(_ refusal: Refusal) -> Result<PreparedUpdate, Refusal> {
            if refusal.kind == .permanent {
                _ = env.remove(partial)
                _ = env.remove(dmg)
                env.removeEmptyFolder(folder)
            }
            return .failure(refusal)
        }

        // Another copy of Claude Switcher may be checking this very release: nothing here is
        // fetched, attached, detached or removed until it is done.
        guard let release = env.takePrepareLock() else {
            return .failure(.transient(.attach, "another Claude Switcher is checking", countsAsAttempt: false))
        }
        defer { release() }

        // Never download what is not strictly newer: a replayed or back-ported release stops here.
        env.hook(.versionGate)
        guard candidate.version > trust.runningVersion else {
            return refuse(.permanent(.versionGate, "\(candidate.version) is not newer than the running \(trust.runningVersion)"))
        }
        guard let imageRequirement = try? trust.imageRequirement(), let appRequirement = try? trust.appRequirement() else {
            return .failure(.transient(.versionGate, "this copy\u{2019}s own signature cannot be checked against",
                                       countsAsAttempt: false))
        }

        env.hook(.freeSpace)
        let needed = Int64(candidate.assetSize) * 10 + 50_000_000
        guard let here = env.freeSpace(updatesDirectory), let there = env.freeSpace(installParent),
              here >= needed, there >= needed
        else { return .failure(.transient(.freeSpace, "not enough free space", countsAsAttempt: false)) }

        if let existing = env.fileSize(dmg) {
            // Downloaded before: hashed again rather than fetched again.
            env.hook(.size)
            guard existing == candidate.assetSize else {
                _ = env.remove(dmg)
                return .failure(.transient(.size, "the downloaded file has \(existing) bytes, not \(candidate.assetSize)"))
            }
            env.hook(.digest)
            guard env.sha256Hex(dmg) == candidate.digestHex else {
                return refuse(.permanent(.digest, "the downloaded file does not match the release\u{2019}s SHA-256 digest"))
            }
        } else {
            for directory in [updatesDirectory, downloads, folder] where env.makeDirectory(directory) != 0 {
                return .failure(.transient(.download, "could not create Claude Switcher\u{2019}s download folder"))
            }
            _ = env.remove(partial)

            env.hook(.download)
            if let refusal = await env.download(candidate.downloadURL, partial, candidate.assetSize) {
                _ = env.remove(partial)
                return refuse(refusal)
            }
            env.hook(.size)
            let size = env.fileSize(partial)
            guard size == candidate.assetSize else {
                _ = env.remove(partial)
                return .failure(.transient(.size, "the download has \(size ?? 0) bytes, not \(candidate.assetSize)"))
            }
            env.hook(.digest)
            guard env.sha256Hex(partial) == candidate.digestHex else {
                return refuse(.permanent(.digest, "the download does not match the release\u{2019}s SHA-256 digest"))
            }
            guard env.moveFile(partial, dmg) == 0 else {
                _ = env.remove(partial)
                return .failure(.transient(.digest, "the download could not be put in place"))
            }
        }

        env.hook(.imageSignature)
        if case .failure(let failure) = env.verify(dmg, nil) {
            return refuse(.permanent(.imageSignature, "the disk image\u{2019}s signature is not valid: \(failure.message)"))
        }
        env.hook(.imageRequirement)
        if case .failure(let failure) = env.verify(dmg, imageRequirement) {
            return refuse(.permanent(.imageRequirement,
                                     "the disk image is not signed by this developer and notarized: \(failure.message)"))
        }
        env.hook(.license)
        switch env.imageHasLicense(dmg) {
        case .failure(let refusal): return refuse(refusal)
        case .success(true): return refuse(.permanent(.license, "the disk image asks for a license to be accepted"))
        case .success(false): break
        }

        guard env.makeDirectory(updatesDirectory) == 0, env.makeDirectory(mounts) == 0 else {
            return .failure(.transient(.attach, "could not create Claude Switcher\u{2019}s mount folder"))
        }
        env.hook(.attach)
        let mount: Mount
        switch env.attach(dmg, mounts) {
        case .success(let attached):
            mount = attached
        case .failure(let failure):
            // hdiutil may have attached it anyway; `hdiutil info` says what is ours.
            let detached = detachOurs(env: env, updatesDirectory: updatesDirectory)
            switch failure {
            case .timedOut:
                let cleaned = detached.contains(env.canonicalPath(dmg) ?? dmg)
                // hdiutil is left to finish — the updater ends no process but itself — and may
                // still attach the image: noted, so the next check or launch looks for it.
                if !cleaned { await env.note(.stillMounted(dmg)) }
                return .failure(.transient(.attach, "attaching the disk image timed out", countsAsAttempt: !cleaned))
            case .failed(let detail):
                return .failure(.transient(.attach, "the disk image could not be attached: \(detail)"))
            }
        }

        let detacher = Detacher(mount: mount, dmg: dmg, updatesDirectory: updatesDirectory, env: env)
        let result = await prepareMounted(mount, dmg: dmg, candidate: candidate, trust: trust,
                                          appRequirement: appRequirement, installPath: installPath,
                                          detacher: detacher, env: env)
        // Every path out of the mounted part ends here, attached or not.
        detacher.detach()
        if detacher.stillMounted { await env.note(.stillMounted(mount.mountPoint)) }
        if case .failure(let refusal) = result { return refuse(refusal) }
        return result
    }

    /// Detaches the image once, then whatever else of ours `hdiutil info` still lists.
    private final class Detacher {
        let mount: Mount
        let dmg: String
        let updatesDirectory: String
        let env: PrepareEnvironment
        private var done = false
        private(set) var stillMounted = false

        init(mount: Mount, dmg: String, updatesDirectory: String, env: PrepareEnvironment) {
            self.mount = mount
            self.dmg = dmg
            self.updatesDirectory = updatesDirectory
            self.env = env
        }

        func detach() {
            guard !done else { return }
            done = true
            env.hook(.detach)
            let detached = env.detach(mount.device)
            let swept = SwitcherUpdater.detachOurs(env: env, updatesDirectory: updatesDirectory)
            stillMounted = !detached && !swept.contains(env.canonicalPath(dmg) ?? dmg)
        }
    }

    /// Steps 7 to 17, with the image attached. Its caller detaches whatever happens here.
    private static func prepareMounted(_ mount: Mount, dmg: String, candidate: ReleaseCandidate, trust: SwitcherTrust,
                                       appRequirement: String, installPath: String, detacher: Detacher,
                                       env: PrepareEnvironment) async -> Result<PreparedUpdate, Refusal> {
        let installParent = (installPath as NSString).deletingLastPathComponent

        env.hook(.layout)
        guard let entries = env.listDirectory(mount.mountPoint), isReleaseLayout(entries) else {
            return .failure(.permanent(.layout, "the disk image does not hold just Claude Switcher"))
        }
        let mountedApp = mount.mountPoint + "/" + SwitcherDisk.appName
        if case .failure(let refusal) = verifyApp(mountedApp, requirement: appRequirement, trust: trust,
                                                   expected: candidate.version,
                                                   steps: (.mountedSignature, .mountedRequirement, .mountedIdentity),
                                                   hook: env.hook, verify: env.verify) {
            return .failure(refusal)
        }

        env.hook(.copy)
        let staging: String
        switch env.stagingDirectory(installPath) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let path): staging = path
        }
        await env.note(.staging(staging))
        let staged = staging + "/" + SwitcherDisk.appName

        /// Only before any swap, and only the copy this prepare made. A copy that could not be
        /// removed stays named in `state.json`.
        func discardStaged() async {
            guard env.remove(staged) else { return }
            env.removeEmptyFolder(staging)
            await env.note(.stagingGone(staging))
        }

        if let refusal = env.copyBundle(mountedApp, staged) {
            await discardStaged()
            return .failure(refusal)
        }
        detacher.detach()

        env.hook(.quarantine)
        if let refusal = env.removeQuarantine(staged) {
            await discardStaged()
            return .failure(refusal)
        }

        let identity: CodeIdentity
        switch verifyApp(staged, requirement: appRequirement, trust: trust, expected: candidate.version,
                         steps: (.stagedSignature, .stagedRequirement, .stagedIdentity), hook: env.hook, verify: env.verify) {
        case .failure(let refusal):
            await discardStaged()
            return .failure(refusal)
        case .success(let verified):
            identity = verified
        }

        env.hook(.assess)
        switch env.assess(staged) {
        case .accepted: break
        case .rejected(let detail):
            await discardStaged()
            return .failure(.permanent(.assess, "Gatekeeper does not accept it: \(detail)"))
        case .unavailable(let detail):
            await discardStaged()
            return .failure(.transient(.assess, "Gatekeeper could not assess it: \(detail)"))
        }

        env.hook(.prewarm)
        env.prewarm(staged)

        env.hook(.volume)
        guard env.lstatKind(staged) == .directory, let stagedDevice = env.deviceOf(staged),
              let installDevice = env.deviceOf(installParent), stagedDevice == installDevice
        else {
            await discardStaged()
            return .failure(.permanent(.volume, "staging folder is on another volume"))
        }

        return .success(PreparedUpdate(stagedAppPath: staged, dmgPath: dmg, candidate: candidate,
                                       verifiedIdentity: identity, verifiedAt: env.now()))
    }

    /// Steps 8, 9 and 10 on one copy: valid, this developer's notarized app, and the release's version.
    static func verifyApp(_ path: String, requirement: String, trust: SwitcherTrust, expected: ReleaseVersion,
                          mustBeNewer: Bool = true, steps: (PrepareStep, PrepareStep, PrepareStep),
                          hook: (PrepareStep) -> Void, verify: (String, String?) -> Result<CodeIdentity, SignatureRefusal>)
        -> Result<CodeIdentity, Refusal> {
        /// A copy that was not there to check — the image detached, the folder removed from under
        /// the check — says nothing about the release: tried again, never rejected.
        func refusal(_ step: PrepareStep, _ failure: SignatureRefusal, _ reason: String) -> Refusal {
            CodeSignature.vanishedStatuses.contains(failure.status)
                ? .transient(step, "the app was gone before it could be checked: \(failure.message)")
                : .permanent(step, reason)
        }
        hook(steps.0)
        if case .failure(let failure) = verify(path, nil) {
            return .failure(refusal(steps.0, failure, "the app\u{2019}s signature is not valid: \(failure.message)"))
        }
        hook(steps.1)
        let identity: CodeIdentity
        switch verify(path, requirement) {
        case .failure(let failure):
            return .failure(refusal(steps.1, failure,
                                    "the app is not signed by this developer and notarized: \(failure.message)"))
        case .success(let verified):
            identity = verified
        }
        hook(steps.2)
        if let refusal = SwitcherUpdatePolicy.verifyBundleIdentity(identity, trust: trust, expected: expected,
                                                                    step: steps.2.rawValue, mustBeNewer: mustBeNewer) {
            return .failure(refusal)
        }
        return .success(identity)
    }

    /// The release image holds the app and, for dragging it, a link to /Applications — read,
    /// never followed (`scripts/dmg.sh` puts it there). Anything else is not a release.
    static func isReleaseLayout(_ entries: [DirectoryEntry]) -> Bool {
        let apps = entries.filter { $0.name == SwitcherDisk.appName }
        guard apps.count == 1, apps[0].kind == .directory else { return false }
        let others = entries.filter { $0.name != SwitcherDisk.appName }
        if others.isEmpty { return true }
        return others.count == 1 && others[0].name == "Applications" && others[0].kind == .symlink
            && others[0].linkTarget == "/Applications"
    }

    /// Detaches every image whose file is under `updates/downloads/` and nothing else, and
    /// returns their paths. `hdiutil info` is the single source of truth for what is ours.
    @discardableResult
    public static func detachOurs(env: PrepareEnvironment, updatesDirectory: String) -> [String] {
        guard let images = env.attachedImages() else { return [] }
        let root = ownedPrefix("downloads", updatesDirectory: updatesDirectory, canonical: env.canonicalPath)
        var detached: [String] = []
        for image in images {
            let path = env.canonicalPath(image.imagePath) ?? image.imagePath
            guard path.hasPrefix(root), let device = image.detachDevice else { continue }
            if env.detach(device) { detached.append(path) }
        }
        return detached
    }

    /// A verified copy this process will not install — a checks-only copy, or one not holding
    /// the lock — is removed again: the staged copy (it was never swapped) and the disk image.
    /// The image only under the prepare lock: another copy may be checking the same release, and
    /// what is left is tidied at the next launch.
    public static func discard(_ prepared: PreparedUpdate, updatesDirectory: String, env: PrepareEnvironment) async {
        if discardStagedOnly(prepared, env: env) {
            await env.note(.stagingGone((prepared.stagedAppPath as NSString).deletingLastPathComponent))
        }
        underPrepareLock(env) { _ = env.remove(updatesDirectory + "/downloads/" + prepared.candidate.tag) }
    }

    /// The staged copy alone — this process's own, never swapped — and its emptied folder, at
    /// once: what quitting does with a verified copy it kept, so that nothing is left for the next
    /// launch to put in the Trash. The disk image stays for the next check; the folder's entry in
    /// `state.staging` goes at the next launch, which finds the folder gone. Whether the copy is gone.
    @discardableResult
    public static func discardStagedOnly(_ prepared: PreparedUpdate, env: PrepareEnvironment) -> Bool {
        guard env.remove(prepared.stagedAppPath) else { return false }
        env.removeEmptyFolder((prepared.stagedAppPath as NSString).deletingLastPathComponent)
        return true
    }

    /// Runs `body` holding the prepare lock, or not at all when another copy holds it. Whether it ran.
    @discardableResult
    static func underPrepareLock(_ env: PrepareEnvironment, _ body: () -> Void) -> Bool {
        guard let release = env.takePrepareLock() else { return false }
        defer { release() }
        body()
        return true
    }

    /// A disk image noted as possibly still attached — an attach that timed out, a detach that
    /// failed — is looked for again and detached, under the prepare lock, before an automatic
    /// check decides anything. The updated state, or `nil` when there was nothing to do or another
    /// copy holds the lock.
    public static func detachLeftoverImages(updatesDirectory: String, store: SwitcherUpdateStore,
                                            env: PrepareEnvironment) async -> SwitcherUpdateState? {
        guard let noted = await store.load(now: env.now()).mounted,
              underPrepareLock(env, { detachOurs(env: env, updatesDirectory: updatesDirectory) })
        else { return nil }
        // Informational only: `hdiutil info` is what decides which images are ours. Cleared only
        // while it still says what this sweep went by: a prepare in another copy may have taken
        // the lock as soon as it was let go, and its note stands.
        return try? await store.update(now: env.now()) { if $0.mounted == noted { $0.mounted = nil } }
    }

    /// Records what a commit came to, and deletes the disk image of a release it refused for
    /// what it is.
    @discardableResult
    public static func afterCommit(_ outcome: CommitOutcome, prepared: PreparedUpdate, updatesDirectory: String,
                                   store: SwitcherUpdateStore, env: PrepareEnvironment) async -> SwitcherUpdateState? {
        let now = env.now()
        switch outcome {
        case .rolledBack(let refusal) where refusal.kind == .permanent,
             .refusedBeforeSwap(let refusal) where refusal.kind == .permanent:
            underPrepareLock(env) { _ = env.remove(updatesDirectory + "/downloads/" + prepared.candidate.tag) }
        default:
            break
        }
        return try? await store.update(now: now) {
            SwitcherUpdatePolicy.record(commit: outcome, prepared: prepared, in: &$0, now: now)
        }
    }

    // MARK: - Commit

    /// Replaces the running copy with `prepared` and relaunches. Runs off the main actor; the
    /// idle re-check, the relaunch and the final terminate hop to it.
    public static func commit(prepared: PreparedUpdate, running: RunningCopy, trust: SwitcherTrust,
                              claudeAppPath: String, userAsked: Bool, env: CommitEnvironment) async -> CommitOutcome {
        let install = running.bundlePath
        let staged = prepared.stagedAppPath
        let staging = (staged as NSString).deletingLastPathComponent

        /// Nothing was moved: the staged copy is still this process's own, unswapped. One that
        /// could not be removed stays named in `state.json`.
        func refused(_ step: CommitStep, _ reason: String, _ kind: Refusal.Kind = .transient) async -> CommitOutcome {
            if env.remove(staged) {
                env.removeEmptyFolder(staging)
                await env.note(.stagingGone(staging))
            }
            return .refusedBeforeSwap(Refusal(kind: kind, step: step.rawValue, reason: reason))
        }

        env.hook(.proveTarget)
        if let reason = proveTarget(install: install, replacement: staged, running: running,
                                    claudeAppPath: claudeAppPath, env: env) {
            return await refused(.proveTarget, reason)
        }

        env.hook(.versions)
        guard let short = env.versionOnDisk(install)?.short, let onDisk = ReleaseVersion(string: short),
              onDisk == running.identity.version
        else { return await refused(.versions, "the copy in place is not the one that is running") }
        guard prepared.version > trust.runningVersion else {
            return await refused(.versions, "\(prepared.version) is not newer than the running \(trust.runningVersion)",
                                 .permanent)
        }

        env.hook(.reverify)
        guard let requirement = try? trust.appRequirement() else {
            return await refused(.reverify, "this copy\u{2019}s own signature cannot be checked against")
        }
        if case .failure(let refusal) = verifyApp(staged, requirement: requirement, trust: trust,
                                                   expected: prepared.version,
                                                   steps: (.stagedSignature, .stagedRequirement, .stagedIdentity),
                                                   hook: { _ in }, verify: env.verify) {
            return await refused(.reverify, refusal.reason, .permanent)
        }

        env.hook(.idleRecheck)
        if !userAsked {
            let soft = await env.idleBlockers().filter { !SwitcherIdle.hard.contains($0) }
            guard soft.isEmpty else { return .abortedNotIdle(soft) }
        }

        env.hook(.handoff)
        var handoff = UpdateHandoff(
            host: env.host, phase: .swapping, kind: .update, from: trust.runningVersion, to: prepared.version,
            tag: prepared.candidate.tag, digest: prepared.candidate.digestHex, installPath: install, stagedPath: staged,
            oldPid: env.processID, startedAt: env.now(), launchAtLoginWasEnabled: await env.launchAtLoginIsEnabled())
        if let refusal = await env.writeHandoff(handoff) {
            return await refused(.handoff, refusal.reason)
        }

        env.hook(.swap)
        let swapped = env.swap(staged, install)
        guard swapped == 0 else {
            // Nothing moved; the record says what happened instead of "interrupted".
            handoff.phase = .rolledBack
            handoff.failure = swapFailure(swapped)
            _ = await env.writeHandoff(handoff)
            return await refused(.swap, swapFailure(swapped))
        }

        // From here on nothing is removed: the staged path holds the copy that is running.
        env.hook(.verifyInstalled)
        if let reason = verifyInstalled(install, expected: prepared.version, requirement: requirement, env: env) {
            let back = env.swap(install, staged)
            handoff.phase = .rolledBack
            handoff.failure = back == 0 ? reason : "\(reason); swapping back failed (\(String(cString: strerror(back))))"
            _ = await env.writeHandoff(handoff)
            return .rolledBack(Refusal(kind: .permanent, step: CommitStep.verifyInstalled.rawValue, reason: reason))
        }

        env.hook(.register)
        env.registerWithLaunchServices(install)
        handoff.phase = .swapped
        _ = await env.writeHandoff(handoff)

        env.hook(.relaunch)
        let launched = await relaunch(install, env: env)

        env.hook(.oldCopy)
        let oldCopy = keepOldCopy(staged, version: trust.runningVersion, env: env)
        handoff.oldCopy = oldCopy
        if oldCopy.kind != .staging {
            env.removeEmptyFolder(staging)
            await env.note(.stagingGone(staging))
        }

        switch launched {
        case .failure(let failure):
            handoff.phase = .restartPending
            handoff.failure = failure.reason
            _ = await env.writeHandoff(handoff)
            return .restartPending(failure.reason)
        case .success(let pid):
            env.hook(.launched)
            handoff.phase = .launched
            handoff.newPid = pid
            _ = await env.writeHandoff(handoff)
            await env.terminateSelf()
            return .launched(pid)
        }
    }

    /// C1: the path about to be replaced is this very copy, still where it was started, not
    /// Claude, replaceable by this user, and on the same volume as its replacement.
    static func proveTarget(install: String, replacement: String, running: RunningCopy, claudeAppPath: String,
                            env: CommitEnvironment) -> String? {
        let parent = (install as NSString).deletingLastPathComponent
        guard env.lstatKind(install) == .directory else { return "the app in place is not a plain folder" }
        guard let bundleID = running.bundleIdentifier, env.bundleIdentifierOnDisk(install) == bundleID else {
            return "the app in place is not this Claude Switcher"
        }
        guard let processPath = env.processExecutablePath(), processPath == running.executablePath else {
            return "this copy was moved since it was started"
        }
        // Claude.app is never modified: not the configured path, nothing inside it, nothing
        // around it — compared as written and with links resolved, ignoring case.
        let claude = PathNormalizer.normalize(claudeAppPath)
        guard !claude.isEmpty else { return "the path to Claude is not known" }
        let targets = [PathNormalizer.normalize(install), env.canonicalPath(install)].compactMap { $0?.lowercased() }
        let claudes = [claude, env.canonicalPath(claude)].compactMap { $0?.lowercased() }
        for target in targets {
            for claude in claudes where target == claude || target.hasPrefix(claude + "/") || claude.hasPrefix(target + "/") {
                return "the path to replace is Claude\u{2019}s"
            }
        }
        guard env.isWritable(install), env.isWritable(parent) else { return "cannot replace this copy" }
        guard env.lstatKind(replacement) == .directory, let a = env.deviceOf(replacement), let b = env.deviceOf(install),
              a == b
        else { return "staging on another volume" }
        return nil
    }

    /// C6: what is now in place is the release, intact.
    static func verifyInstalled(_ install: String, expected: ReleaseVersion, requirement: String,
                                env: CommitEnvironment) -> String? {
        guard env.lstatKind(install) == .directory else { return "the app in place is not a plain folder after the swap" }
        guard let short = env.versionOnDisk(install)?.short, ReleaseVersion(string: short) == expected else {
            return "the app in place does not read as \(expected) after the swap"
        }
        switch env.verify(install, requirement) {
        case .failure(let failure): return "the app in place fails its signature check after the swap: \(failure.message)"
        case .success(let identity) where identity.version != expected:
            return "the app in place is not \(expected) after the swap"
        case .success: return nil
        }
    }

    static func swapFailure(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: return "cannot replace this copy"
        case EXDEV: return "staging on another volume"
        case ENOTSUP: return "the volume cannot swap folders"
        default: return "the swap failed (\(String(cString: strerror(code))))"
        }
    }

    /// C8: waits while a menu or window is open — at most five minutes — then starts the new copy.
    @MainActor
    static func relaunch(_ install: String, env: CommitEnvironment) async -> Result<Int32, RelaunchFailure> {
        var waited = Duration.zero
        let poll = Duration.seconds(1)
        while env.uiIsOpen(), waited < SwitcherRelaunch.relaunchDeferralLimit {
            await env.sleep(poll)
            waited += poll
        }
        return await env.launch(install, env.processID)
    }

    /// C9: the replaced copy goes to `updates/previous/`, else the Trash, else stays where it is.
    /// It is never deleted.
    static func keepOldCopy(_ path: String, version: ReleaseVersion, env: CommitEnvironment) -> OldCopy {
        if case .success(let kept) = env.moveToPrevious(path, version) { return OldCopy(kind: .previous, path: kept) }
        if case .success(let trashed) = env.trash(path) { return OldCopy(kind: .trash, path: trashed) }
        return OldCopy(kind: .staging, path: path)
    }

    // MARK: - Revert

    /// Goes back to the verified previous copy after the running version failed to start twice.
    /// The same proof, swap, check and launch as an update, with the roles reversed; only the
    /// lock holder may.
    public static func revert(plan: RevertPlan, running: RunningCopy, trust: SwitcherTrust, previousPath: String,
                              isLockHolder: Bool, claudeAppPath: String, env: CommitEnvironment) async -> CommitOutcome {
        func refused(_ step: String, _ reason: String, _ kind: Refusal.Kind = .transient) -> CommitOutcome {
            .refusedBeforeSwap(Refusal(kind: kind, step: step, reason: reason))
        }
        guard isLockHolder else { return refused("revert", "another Claude Switcher holds the lock") }
        let install = running.bundlePath
        guard let requirement = try? trust.appRequirement() else {
            return refused("revert", "this copy\u{2019}s own signature cannot be checked against")
        }
        if case .failure(let refusal) = verifyApp(previousPath, requirement: requirement, trust: trust, expected: plan.to,
                                                   mustBeNewer: false,
                                                   steps: (.stagedSignature, .stagedRequirement, .stagedIdentity),
                                                   hook: { _ in }, verify: env.verify) {
            return refused("revert", "the previous copy: \(refusal.reason)", .permanent)
        }
        // Proven before anything is recorded: a refusal here leaves no record behind.
        if let reason = proveTarget(install: install, replacement: previousPath, running: running,
                                    claudeAppPath: claudeAppPath, env: env) {
            return refused(CommitStep.proveTarget.rawValue, reason)
        }

        var handoff = UpdateHandoff(
            host: env.host, phase: .swapping, kind: .revert, from: plan.from, to: plan.to, tag: plan.tag,
            digest: plan.digest, installPath: install, stagedPath: previousPath, oldPid: env.processID,
            startedAt: env.now(), launchAtLoginWasEnabled: await env.launchAtLoginIsEnabled())
        if let refusal = await env.writeHandoff(handoff) { return .refusedBeforeSwap(refusal) }

        let swapped = env.swap(previousPath, install)
        guard swapped == 0 else {
            handoff.phase = .rolledBack
            handoff.failure = swapFailure(swapped)
            _ = await env.writeHandoff(handoff)
            return refused(CommitStep.swap.rawValue, swapFailure(swapped))
        }
        if let reason = verifyInstalled(install, expected: plan.to, requirement: requirement, env: env) {
            let back = env.swap(install, previousPath)
            handoff.phase = .rolledBack
            handoff.failure = back == 0 ? reason : "\(reason); swapping back failed (\(String(cString: strerror(back))))"
            _ = await env.writeHandoff(handoff)
            return .rolledBack(Refusal(kind: .permanent, step: CommitStep.verifyInstalled.rawValue, reason: reason))
        }
        env.registerWithLaunchServices(install)
        handoff.phase = .swapped
        // The copy that did not start now sits where the previous one was. It is not kept as a
        // version to go back to: it goes to the Trash, or stays there, named.
        if case .success(let trashed) = env.trash(previousPath) {
            handoff.oldCopy = OldCopy(kind: .trash, path: trashed)
            env.removeEmptyFolder((previousPath as NSString).deletingLastPathComponent)
        } else {
            handoff.oldCopy = OldCopy(kind: .staging, path: previousPath)
        }
        _ = await env.writeHandoff(handoff)

        switch await relaunch(install, env: env) {
        case .failure(let failure):
            handoff.phase = .restartPending
            handoff.failure = failure.reason
            _ = await env.writeHandoff(handoff)
            return .restartPending(failure.reason)
        case .success(let pid):
            handoff.phase = .launched
            handoff.newPid = pid
            _ = await env.writeHandoff(handoff)
            await env.terminateSelf()
            return .launched(pid)
        }
    }

    // MARK: - Hand-off

    /// What the record left by the previous process means, given the version that is running.
    /// Pure: the lock holder acts on the result, anyone else only shows it.
    public static func finishHandoff(_ handoff: UpdateHandoff, running: ReleaseVersion?, host: String,
                                     now: Date) -> HandoffResult {
        guard handoff.host == host else {
            var result = HandoffResult(verdict: .foreign, disposition: .keep)
            result.findings = [foreignFinding]
            return result
        }
        let from = handoff.from, to = handoff.to
        guard let running, running == from || running == to else {
            var result = HandoffResult(verdict: .unexpected, disposition: .keep)
            result.findings = ["unexpected version \(running?.description ?? "(unreadable)") after an update from \(from) to \(to)"]
            return result
        }

        switch (handoff.phase, running == to) {
        case (.launched, true), (.swapped, true), (.restartPending, true), (.swapping, true):
            var result = HandoffResult(verdict: .succeeded, disposition: .deleteAtSettle)
            result.launchAtLoginWasEnabled = handoff.launchAtLoginWasEnabled
            result.lastInstall = InstallRecord(from: from, to: to, at: now, oldCopy: handoff.oldCopy, tag: handoff.tag,
                                               digest: handoff.digest, kind: handoff.kind)
            switch handoff.kind {
            case .update:
                if ReleaseVersion(tag: handoff.tag) != nil { result.deleteDownloadsFor = handoff.tag }
                result.notice = SwitcherNotice(text: SwitcherUpdateText.updated(to: to, at: now),
                                               tooltip: SwitcherUpdateText.updatedTooltip(from: from, tag: handoff.tag,
                                                                                          oldCopy: handoff.oldCopy))
            case .revert:
                result.notice = SwitcherNotice(text: SwitcherUpdateText.reverted(bad: from, back: to))
                result.rejection = Rejection(tag: handoff.tag, digestHex: handoff.digest,
                                             reason: "\(from) did not start properly twice", at: now)
                result.findings.append("\(from) did not start properly twice; went back to \(to)")
            }
            if handoff.phase == .swapping, let staged = handoff.stagedPath {
                result.findings.append("the previous copy may still be in \(staged)")
            }
            return result

        case (.launched, false), (.swapped, false), (.restartPending, false):
            var result = HandoffResult(verdict: .failed, disposition: .archiveAsFailed)
            let reason = handoff.failure ?? "\(to) did not take over from \(from)"
            result.lastFailure = FailureRecord(tag: handoff.tag, digest: handoff.digest, step: CommitStep.relaunch.rawValue,
                                               reason: reason, at: now)
            switch handoff.kind {
            case .update:
                result.notice = SwitcherNotice(text: SwitcherUpdateText.couldNotUpdate(to: to, still: from))
                result.rejection = Rejection(tag: handoff.tag, digestHex: handoff.digest,
                                             reason: "\(to) did not take over from \(from)", at: now)
            case .revert:
                result.notice = SwitcherNotice(text: SwitcherUpdateText.couldNotGoBack(to: to, still: from))
                result.rejection = Rejection(tag: handoff.tag, digestHex: handoff.digest,
                                             reason: "\(from) did not start properly twice", at: now)
            }
            result.findings.append("last attempt: \(reason)")
            return result

        case (.rolledBack, false):
            var result = HandoffResult(verdict: .rolledBack, disposition: .archiveAsFailed)
            let reason = handoff.failure ?? "the new copy failed its check after the swap"
            result.lastFailure = FailureRecord(tag: handoff.tag, digest: handoff.digest,
                                               step: CommitStep.verifyInstalled.rawValue, reason: reason, at: now)
            result.findings.append("last attempt: \(reason)")
            return result

        case (.swapping, false):
            var result = HandoffResult(verdict: .interrupted, disposition: .archiveAsFailed)
            result.findings.append(handoff.kind == .update
                ? "an update to \(to) was interrupted before it was installed"
                : "going back to \(to) was interrupted before it happened")
            return result

        case (.rolledBack, true):
            var result = HandoffResult(verdict: .unexpected, disposition: .keep)
            result.findings = ["\(to) is running although the update from \(from) was rolled back"]
            return result
        }
    }

    /// Whether `handoff` is this Mac's finished record of an update — or a return — to the running
    /// version: the record a start that has got going deletes.
    public static func isSettledByStart(_ handoff: UpdateHandoff, running: ReleaseVersion?, host: String) -> Bool {
        finishHandoff(handoff, running: running, host: host, now: .distantPast).disposition == .deleteAtSettle
    }

    // MARK: - Launch-time reconcile

    /// The launch pass of section 7.1: read the records, go back after two aborted starts, finish
    /// the hand-off, then tidy the updater's own folders. Only the lock holder changes anything;
    /// anyone else gets the same findings for Diagnostics.
    public struct LaunchContext: Sendable {
        public var running: RunningCopy
        public var trust: SwitcherTrust?
        public var isLockHolder: Bool
        /// From ``SwitcherUpdateStore/recordStart(version:installPath:now:)``.
        public var abortedStarts: Int
        public var updatesDirectory: String
        /// `realpath(NSTemporaryDirectory())/TemporaryItems`.
        public var temporaryItems: String
        public var claudeAppPath: String
        public var now: Date

        public init(running: RunningCopy, trust: SwitcherTrust?, isLockHolder: Bool, abortedStarts: Int,
                    updatesDirectory: String, temporaryItems: String, claudeAppPath: String, now: Date) {
            self.running = running
            self.trust = trust
            self.isLockHolder = isLockHolder
            self.abortedStarts = abortedStarts
            self.updatesDirectory = updatesDirectory
            self.temporaryItems = temporaryItems
            self.claudeAppPath = claudeAppPath
            self.now = now
        }
    }

    public static func reconcileAtLaunch(_ context: LaunchContext, store: SwitcherUpdateStore,
                                         prepare env: PrepareEnvironment, commit: CommitEnvironment) async -> LaunchReport {
        let loaded = await store.load(now: context.now)
        var state = loaded
        var report = LaunchReport(state: state)
        // Seen at this launch, or not at all: a flag saved by an earlier launch says nothing now.
        let stateWasForeign = state.foreignRecordsSeen == true && state.host == nil
        state.foreignRecordsSeen = stateWasForeign ? true : nil
        state.installPath = context.running.bundlePath
        if stateWasForeign { report.findings.append(foreignFinding) }

        // (a) The records. One from another Mac, or one that does not read, is named and left alone.
        var handoff: UpdateHandoff?
        switch await store.loadHandoff() {
        case .absent: break
        case .unreadable(let why):
            report.findings.append("\(why); it is left in place (renaming it to \(SwitcherUpdateStore.failedHandoffName) "
                + "clears this)")
        case .record(let record):
            if record.host == store.host {
                handoff = record
            } else {
                state.foreignRecordsSeen = true
                if !report.findings.contains(foreignFinding) { report.findings.append(foreignFinding) }
            }
        }

        // (b) Two starts of this version never got going: go back to the one before it.
        let running = context.running.identity.version
        var finishRecord = true
        if context.isLockHolder, let trust = context.trust,
           case .revert(let plan) = SwitcherUpdatePolicy.revertDecision(
               abortedStarts: context.abortedStarts, running: running, handoff: handoff, host: store.host) {
            let previous = context.updatesDirectory + "/previous/\(plan.to)/" + SwitcherDisk.appName
            if commit.lstatKind(previous) == .directory {
                let outcome = await revert(plan: plan, running: context.running, trust: trust, previousPath: previous,
                                           isLockHolder: true, claudeAppPath: context.claudeAppPath, env: commit)
                report.revert = outcome
                switch outcome {
                case .launched:
                    // This process is on its way out; the copy it started finishes the record.
                    return report
                case .restartPending(let reason):
                    report.findings.append("\(plan.from) did not start properly twice; \(plan.to) is back in place "
                        + "but could not be started (\(reason)); it starts at the next launch")
                    if !state.isRejected(tag: plan.tag, digest: plan.digest) {
                        state.rejected = (state.rejected ?? []) + [Rejection(
                            tag: plan.tag, digestHex: plan.digest, reason: "\(plan.from) did not start properly twice",
                            at: context.now)]
                    }
                case .rolledBack(let refusal), .refusedBeforeSwap(let refusal):
                    report.findings.append("\(plan.from) did not start properly twice; going back to \(plan.to) "
                        + "was not possible: \(refusal.reason)")
                case .abortedNotIdle:
                    break
                }
                // A revert that wrote its own record leaves it for the next start to finish.
                finishRecord = await store.loadHandoff().value == handoff
            } else {
                report.findings.append("\(plan.from) did not start properly twice, and there is no previous copy to go back to")
            }
        }

        // (c) The hand-off.
        if finishRecord, let handoff {
            let result = finishHandoff(handoff, running: running, host: store.host, now: context.now)
            report.handoff = result
            report.findings += result.findings
            if context.isLockHolder {
                if let notice = result.notice { state.notice = notice }
                if let install = result.lastInstall { state.lastInstall = install }
                if let failure = result.lastFailure { state.lastFailure = failure }
                if let rejection = result.rejection, !state.isRejected(tag: rejection.tag, digest: rejection.digestHex) {
                    state.rejected = (state.rejected ?? []) + [rejection]
                }
                if let tag = result.deleteDownloadsFor, ReleaseVersion(tag: tag) != nil,
                   underPrepareLock(env, { _ = env.remove(context.updatesDirectory + "/downloads/" + tag) }),
                   state.candidate?.tag == tag {
                    state.candidate = nil
                }
                switch result.disposition {
                // Kept until this start has got going: the crash-loop guard goes by it until then.
                case .deleteAtSettle: break
                case .archiveAsFailed: try? await store.archiveFailedHandoff()
                case .keep: break
                }
            }
        }

        // (d) – (g)
        report.findings += reconcile(state: &state, isLockHolder: context.isLockHolder,
                                     updatesDirectory: context.updatesDirectory, temporaryItems: context.temporaryItems,
                                     running: context.running, env: env)
        if context.isLockHolder {
            // A write a crash left half-way is never put in place; its temporary file goes.
            await store.sweepTemporaryFiles()
            // A staged copy belongs to the process that made it; a later one prepares again.
            state.prepared = nil
            // Only what this pass changed is written, onto the record as it is now: a check that
            // ran meanwhile — in another copy — keeps what it recorded.
            let reconciled = state
            if let merged = try? await store.update(now: context.now, {
                merge(reconciled, readAt: loaded, onto: &$0)
            }) {
                state = merged
            }
        }
        report.state = state
        return report
    }

    /// Puts what the launch pass changed onto `fresh`, the record as it is when the pass ends. A
    /// field is taken from the pass only when the pass changed it and nobody else did meanwhile;
    /// rejections the pass added are added; the staging folders the pass dealt with go, and one
    /// another copy recorded meanwhile stays; where this copy is, and that no staged copy is kept,
    /// are always this pass's to say.
    static func merge(_ reconciled: SwitcherUpdateState, readAt original: SwitcherUpdateState,
                      onto fresh: inout SwitcherUpdateState) {
        func adopt<Value: Equatable>(_ field: WritableKeyPath<SwitcherUpdateState, Value>) {
            guard reconciled[keyPath: field] != original[keyPath: field],
                  fresh[keyPath: field] == original[keyPath: field]
            else { return }
            fresh[keyPath: field] = reconciled[keyPath: field]
        }
        fresh.installPath = reconciled.installPath
        fresh.foreignRecordsSeen = reconciled.foreignRecordsSeen
        fresh.prepared = nil
        adopt(\.notice)
        adopt(\.lastInstall)
        adopt(\.lastFailure)
        adopt(\.candidate)
        adopt(\.mounted)
        let dealtWith = Set(original.staging ?? []).subtracting(reconciled.staging ?? [])
        let staging = (fresh.staging ?? []).filter { !dealtWith.contains($0) }
        fresh.staging = staging.isEmpty ? nil : staging
        for rejection in reconciled.rejected ?? []
        where !(original.rejected ?? []).contains(rejection) && !fresh.isRejected(tag: rejection.tag, digest: rejection.digestHex) {
            fresh.rejected = (fresh.rejected ?? []) + [rejection]
        }
    }

    /// Steps (d) to (g): detach our images, drop partial and stale downloads, deal with a staging
    /// folder left by a crash, keep one previous copy. Bundles are moved, never removed.
    public static func reconcile(state: inout SwitcherUpdateState, isLockHolder: Bool, updatesDirectory: String,
                                 temporaryItems: String, running: RunningCopy, env: PrepareEnvironment) -> [String] {
        var findings: [String] = []
        guard isLockHolder else {
            for staging in state.staging ?? [] {
                findings.append("a folder is left at \(staging) (the Claude Switcher holding the lock looks after it)")
            }
            return findings
        }
        let downloads = updatesDirectory + "/downloads"

        // (d) and (e), only while no other copy is checking: its image and download are in use.
        let candidateTag = state.candidate?.tag
        var detached: [String] = []
        let tidied = underPrepareLock(env) {
            // (d)
            detached = detachOurs(env: env, updatesDirectory: updatesDirectory)
            // (e)
            for entry in env.listDirectory(downloads) ?? [] {
                let path = downloads + "/" + entry.name
                if entry.kind == .directory, entry.name == candidateTag {
                    for inner in env.listDirectory(path) ?? [] where inner.name.hasSuffix(".partial") {
                        _ = env.remove(path + "/" + inner.name)
                    }
                } else {
                    _ = env.remove(path)
                }
            }
        }
        if tidied {
            if !detached.isEmpty { findings.append("detached a disk image an earlier attempt left mounted") }
            state.mounted = nil
        } else {
            findings.append("another Claude Switcher is checking for updates; downloads and disk images are left for now")
        }

        // (f) Every staging folder named, whichever copy of Claude Switcher recorded it.
        var left: [String] = []
        for staging in state.staging ?? [] where env.lstatKind(staging) != nil {
            guard SwitcherUpdatePolicy.stagingIsOurs(
                path: staging, temporaryItems: temporaryItems, canonical: env.canonicalPath, lstat: env.lstatKind,
                entries: { env.listDirectory($0)?.map(\.name) }, bundleID: env.bundleIdentifierOnDisk,
                runningBundleID: running.bundleIdentifier)
            else {
                findings.append("a folder is left at \(staging) (not ours to remove)")
                left.append(staging)
                continue
            }
            let bundle = staging + "/" + SwitcherDisk.appName
            let version = (try? env.verify(bundle, nil).get())?.version
            var kept: String?
            // An older copy is the one to go back to; anything else was never installed.
            if let version, let current = running.identity.version, version < current,
               case .success(let path) = env.moveToPrevious(bundle, version) {
                kept = path
            } else if case .success(let path) = env.trash(bundle) {
                kept = path
            }
            if let kept {
                env.removeEmptyFolder(staging)
                findings.append("moved a copy left in a temporary folder to \(kept)")
            } else {
                findings.append("a folder is left at \(staging) (it could not be moved)")
                left.append(staging)
            }
        }
        state.staging = left.isEmpty ? nil : left

        // (g)
        let previous = updatesDirectory + "/previous"
        let versions = (env.listDirectory(previous) ?? []).compactMap { entry -> (ReleaseVersion, String)? in
            guard entry.kind == .directory, let version = ReleaseVersion(string: entry.name) else { return nil }
            return (version, entry.name)
        }
        if let newest = versions.map(\.0).max() {
            for (version, name) in versions where version != newest {
                _ = env.trash(previous + "/" + name)
            }
        }
        return findings
    }
}
