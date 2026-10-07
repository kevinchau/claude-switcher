import CoreServices
import CryptoKit
import Darwin
import Foundation
import Security

// MARK: - Disk

/// The file-system calls behind the updater's seams. Each acts only on the paths it is given.
public enum SwitcherDisk {

    public static let appName = "Claude Switcher.app"
    public static let quarantineAttribute = "com.apple.quarantine"

    static func string(fromNulTerminated buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `proc_pidpath(getpid())`: follows the running executable wherever its bundle was moved.
    public static func processExecutablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return string(fromNulTerminated: buffer)
    }

    public static func isOnReadOnlyVolume(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return true }
        return info.f_flags & UInt32(MNT_RDONLY) != 0
    }

    public static func isWritable(_ path: String) -> Bool { access(path, W_OK) == 0 }

    public static func lstatKind(_ path: String) -> FileKind? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    public static func deviceOf(_ path: String) -> dev_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }

    /// `CFBundleIdentifier`, read from the file every time — never through `Bundle`, which caches.
    public static func bundleIdentifier(ofBundleAt path: String) -> String? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String
    }

    /// `renamex_np(RENAME_SWAP)`: both paths stay occupied throughout. After a swap the first
    /// path holds what was installed — no longer a staged copy this process may remove.
    public static func swap(_ first: String, _ second: String, registry: StagedCopies = .shared) -> Int32 {
        let key = realpath(first)
        guard renamex_np(first, second, UInt32(RENAME_SWAP)) == 0 else { return errno }
        if let key { registry.forget(key) }
        return 0
    }

    public static func registerWithLaunchServices(_ path: String) {
        _ = LSRegisterURL(URL(fileURLWithPath: path) as CFURL, true)
    }

    public static func trash(_ path: String) -> Result<String, FileError> {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
            return .success(resulting?.path ?? path)
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            return .failure(FileError(Int32(truncatingIfNeeded: underlying?.domain == NSPOSIXErrorDomain ? underlying!.code : Int(EIO))))
        }
    }

    /// Moves a replaced copy to `updates/previous/<version>/Claude Switcher.app` and keeps that one
    /// version only: an older one goes to the Trash. Nothing is deleted.
    public static func moveToPrevious(_ bundle: String, version: ReleaseVersion, updatesDirectory: String,
                                      trash: (String) -> Result<String, FileError> = SwitcherDisk.trash)
        -> Result<String, FileError> {
        let previous = updatesDirectory + "/previous"
        let folder = previous + "/" + version.description
        for directory in [updatesDirectory, previous, folder] {
            let code = makeDirectory(directory)
            guard code == 0 else { return .failure(FileError(code)) }
        }
        let destination = folder + "/" + appName
        if lstatKind(destination) != nil, case .failure(let error) = trash(destination) { return .failure(error) }
        guard Darwin.rename(bundle, destination) == 0 else { return .failure(FileError(errno)) }
        for entry in listDirectory(previous) ?? []
        where entry.kind == .directory && entry.name != version.description && ReleaseVersion(string: entry.name) != nil {
            _ = trash(previous + "/" + entry.name)
        }
        return .success(destination)
    }

    /// The entries of a folder as `lstat` sees them; links are described, not followed.
    public static func listDirectory(_ path: String) -> [DirectoryEntry]? {
        guard lstatKind(path) == .directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return names.sorted().compactMap { name in
            let full = path + "/" + name
            guard let kind = lstatKind(full) else { return nil }
            let target = kind == .symlink ? try? FileManager.default.destinationOfSymbolicLink(atPath: full) : nil
            return DirectoryEntry(name: name, kind: kind, linkTarget: target)
        }
    }

    public static func fileSize(_ path: String) -> Int? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(info.st_size)
    }

    /// Streaming SHA-256, as lowercase hex.
    public static func sha256Hex(_ path: String) -> String? {
        guard lstatKind(path) == .file, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // `nil` is the end of the file; only a thrown error is a failed read.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes available on the volume holding `path` (or its nearest existing ancestor).
    public static func freeSpace(_ path: String) -> Int64? {
        var candidate = path
        while lstatKind(candidate) == nil, candidate != "/" {
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        var info = statfs()
        guard statfs(candidate, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// `mkdir` with mode 0700; an existing folder is fine, anything else at the path is not.
    public static func makeDirectory(_ path: String) -> Int32 {
        if mkdir(path, 0o700) == 0 { return 0 }
        let code = errno
        return code == EEXIST && lstatKind(path) == .directory ? 0 : code
    }

    public static func removeEmptyFolder(_ path: String) { _ = rmdir(path) }

    /// `realpath(NSTemporaryDirectory())/TemporaryItems`, where FileManager makes NSIRD folders.
    public static func temporaryItemsDirectory() -> String {
        let temporary = NSTemporaryDirectory()
        let resolved = realpath(temporary) ?? temporary
        return (resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved) + "/TemporaryItems"
    }

    /// A folder for replacing `installPath`, on its volume: `…/TemporaryItems/NSIRD_<proc>_<rand>`.
    public static func stagingDirectory(for installPath: String) -> Result<String, Refusal> {
        do {
            let url = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: URL(fileURLWithPath: installPath), create: true)
            return .success(url.path)
        } catch {
            return .failure(.transient(.copy, "no temporary folder on the same disk as this copy of Claude Switcher: "
                + error.localizedDescription))
        }
    }

    /// Copies the verified bundle into the staging folder, recording it as this process's own
    /// staged copy first, so that only it may be removed again.
    public static func copyBundle(from source: String, to destination: String, registry: StagedCopies = .shared) -> Refusal? {
        guard lstatKind(destination) == nil else {
            return .transient(.copy, "the temporary folder for the new version is not empty")
        }
        let parent = (destination as NSString).deletingLastPathComponent
        guard let resolvedParent = realpath(parent) else {
            return .transient(.copy, "the temporary folder for the new version is gone")
        }
        registry.register(resolvedParent + "/" + (destination as NSString).lastPathComponent)
        do {
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            return nil
        } catch {
            return .transient(.copy, "copying the new version failed: \(error.localizedDescription)")
        }
    }

    /// Clears `com.apple.quarantine` on the root and on everything below it, depth first, never
    /// following a link. An item without the flag is fine.
    public static func removeQuarantine(_ root: String,
                                        removeAttribute: (String) -> Int32 = clearQuarantine) -> Refusal? {
        var pending = [root]
        while let path = pending.popLast() {
            let code = removeAttribute(path)
            guard code == 0 || code == ENOATTR else {
                return .transient(.quarantine, "could not clear the quarantine flag (\(String(cString: strerror(code))))")
            }
            if lstatKind(path) == .directory, let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                pending.append(contentsOf: names.sorted().reversed().map { path + "/" + $0 })
            }
        }
        return nil
    }

    /// One item, `XATTR_NOFOLLOW` throughout: an item without the flag is left untouched — even a
    /// read-only one, where `removexattr` would say EACCES — and a read-only item that has it is
    /// made writable by its owner for that one call, then given its mode back. 0, ENOATTR or an errno.
    public static func clearQuarantine(_ path: String) -> Int32 {
        if getxattr(path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) < 0, errno == ENOATTR { return ENOATTR }
        if removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) == 0 { return 0 }
        let code = errno
        var info = stat()
        guard code == EACCES || code == EPERM, lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK,
              info.st_mode & S_IWUSR == 0
        else { return code }
        let mode = info.st_mode & 0o7777
        guard fchmodat(AT_FDCWD, path, mode | S_IWUSR, AT_SYMLINK_NOFOLLOW) == 0 else { return code }
        let result = removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) == 0 ? 0 : errno
        _ = fchmodat(AT_FDCWD, path, mode, AT_SYMLINK_NOFOLLOW)
        return result
    }

    /// Gives its owner write access to every folder in the tree at `root`, so that what is in them
    /// can be removed; links are not followed, and files are left as they are (removing one needs
    /// only its folder to be writable). Only ever called on a staged copy this process made.
    static func makeFoldersWritable(_ root: String) {
        var pending = [root]
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            if info.st_mode & S_IWUSR == 0 {
                _ = fchmodat(AT_FDCWD, path, (info.st_mode & 0o7777) | S_IWUSR, AT_SYMLINK_NOFOLLOW)
            }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                pending.append(path + "/" + name)
            }
        }
    }
}

/// The staged copies this process made and has not yet swapped into place: the only bundles
/// the updater may ever remove.
public final class StagedCopies: @unchecked Sendable {
    public static let shared = StagedCopies()

    private let lock = NSLock()
    private var paths: Set<String> = []

    public init() {}

    func register(_ realPath: String) { lock.lock(); paths.insert(realPath); lock.unlock() }
    func forget(_ realPath: String) { lock.lock(); paths.remove(realPath); lock.unlock() }

    public func contains(_ realPath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(realPath)
    }
}

/// The one recursive removal the updater has: under `realpath(<configDir>)/updates/downloads/` or
/// `…/updates/mounts/` (the path compared after resolving links), or a staged copy this process
/// made and has not swapped. Everything else is refused, whatever asked for it.
public struct RemovalScope: Sendable {
    public let updatesDirectory: String
    public let registry: StagedCopies

    public init(updatesDirectory: String, registry: StagedCopies = .shared) {
        self.updatesDirectory = updatesDirectory
        self.registry = registry
    }

    /// The resolved path to remove, or `nil` when it is not the updater's to remove.
    public func resolve(_ path: String) -> String? {
        guard let real = SwitcherDisk.realpath(path) else { return nil }
        for folder in ["downloads", "mounts"]
        where real.hasPrefix(SwitcherUpdater.ownedPrefix(folder, updatesDirectory: updatesDirectory,
                                                         canonical: SwitcherDisk.realpath)) {
            return real
        }
        return registry.contains(real) ? real : nil
    }

    /// Whether the path is gone afterwards: nothing there counts as gone.
    @discardableResult
    public func remove(_ path: String) -> Bool {
        guard SwitcherDisk.lstatKind(path) != nil else { return true }
        guard let real = resolve(path) else { return false }
        // A release built from read-only resources stages read-only folders; this process made the
        // copy, so it may make them writable to remove it again. Nothing else is ever changed.
        if registry.contains(real) { SwitcherDisk.makeFoldersWritable(real) }
        do {
            try FileManager.default.removeItem(atPath: real)
            registry.forget(real)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - One prepare at a time

/// An exclusive `flock` on `updates/prepare.lock`, never waited for. Two copies of Claude Switcher
/// can run at once — the installed one and one from a disk image or `build/` — and `hdiutil`
/// attaches one image once for both: without this, one copy's check could detach the image, or
/// delete the download, that the other is verifying, and that one would reject a good release.
public enum PrepareLock {
    public static let fileName = "prepare.lock"

    /// The way to let go, or `nil` when another copy holds it — or it cannot be taken at all,
    /// which means the same: not now.
    public static func take(at path: String) -> SwitcherUpdater.LockRelease? {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let held = Held(descriptor)
        return { held.release() }
    }

    /// Let go once, by whichever comes first: the release, or the last reference going away.
    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?

        init(_ descriptor: Int32) { self.descriptor = descriptor }

        func release() {
            lock.lock()
            let held = descriptor
            descriptor = nil
            lock.unlock()
            guard let held else { return }
            flock(held, LOCK_UN)
            close(held)
        }

        deinit { release() }
    }
}

// MARK: - Processes

/// How a process was set up, read back from the `Process` itself just before it would run.
public struct ProcessLaunch: Equatable, Sendable {
    public let executablePath: String?
    public let arguments: [String]
    public let environment: [String: String]?
    public let standardInputPath: String?
}

public enum ProcessResult: Equatable, Sendable {
    case exited(status: Int32, output: Data, errorOutput: Data)
    /// The deadline passed. The process is left to finish on its own: the updater ends no
    /// process but itself.
    case timedOut
    case couldNotStart(String)
}

/// The only way the updater runs a tool: by absolute path, with an empty environment, stdin
/// from /dev/null, and a deadline on the machine's uptime clock, which stops while it sleeps.
public enum SwitcherProcess {
    /// Told how each process is set up; returning `false` keeps it from starting.
    public typealias Observer = @Sendable (ProcessLaunch) -> Bool

    public static func run(_ executable: String, _ arguments: [String], deadline: TimeInterval,
                           observer: Observer? = nil) -> ProcessResult {
        guard executable.hasPrefix("/") else { return .couldNotStart("\(executable) is not an absolute path") }
        guard let input = FileHandle(forReadingAtPath: "/dev/null") else { return .couldNotStart("no /dev/null") }
        defer { try? input.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = input
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        let launch = ProcessLaunch(executablePath: process.executableURL?.path, arguments: process.arguments ?? [],
                                   environment: process.environment,
                                   standardInputPath: (process.standardInput as? FileHandle).flatMap(path(of:)))
        if let observer, !observer(launch) { return .couldNotStart("not started") }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let collected = Collected()
        let readers = DispatchGroup()
        do {
            try process.run()
        } catch {
            return .couldNotStart(error.localizedDescription)
        }
        DispatchQueue.global().async(group: readers) { collected.setOutput(output.fileHandleForReading.readDataToEndOfFile()) }
        DispatchQueue.global().async(group: readers) { collected.setError(errorOutput.fileHandleForReading.readDataToEndOfFile()) }

        guard finished.wait(timeout: .now() + deadline) == .success else { return .timedOut }
        _ = readers.wait(timeout: .now() + 5)
        return .exited(status: process.terminationStatus, output: collected.output, errorOutput: collected.error)
    }

    private static func path(of handle: FileHandle) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(handle.fileDescriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return SwitcherDisk.string(fromNulTerminated: buffer)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        func setOutput(_ data: Data) { lock.lock(); out = data; lock.unlock() }
        func setError(_ data: Data) { lock.lock(); err = data; lock.unlock() }
        var output: Data { lock.lock(); defer { lock.unlock() }; return out }
        var error: Data { lock.lock(); defer { lock.unlock() }; return err }
    }
}

// MARK: - hdiutil, spctl, gktool

/// The command lines and the reading of what they print.
public enum DiskImageTool {
    public static let hdiutil = "/usr/bin/hdiutil"
    public static let spctl = "/usr/sbin/spctl"
    public static let gktool = "/usr/bin/gktool"
    public static let deadline: TimeInterval = 60

    static func plist(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// From `hdiutil attach -plist`: the mount point is the entity that has one; the device to
    /// detach is the shortest `dev-entry` (the whole disk).
    public static func parseAttach(_ data: Data) -> Mount? {
        guard let entities = plist(data)?["system-entities"] as? [[String: Any]] else { return nil }
        let mountPoints = entities.compactMap { $0["mount-point"] as? String }
        let devices = entities.compactMap { $0["dev-entry"] as? String }
        guard mountPoints.count == 1, let device = devices.min(by: { $0.count < $1.count }), isDevice(device) else {
            return nil
        }
        return Mount(mountPoint: mountPoints[0], device: device)
    }

    /// From `hdiutil info -plist`.
    public static func parseInfo(_ data: Data) -> [AttachedImage]? {
        guard let images = plist(data)?["images"] as? [[String: Any]] else { return nil }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let devices = ((image["system-entities"] as? [[String: Any]]) ?? []).compactMap { $0["dev-entry"] as? String }
            return AttachedImage(imagePath: path, devices: devices.filter(isDevice))
        }
    }

    /// From `hdiutil imageinfo -plist`: whether the image carries a license agreement; `nil` when
    /// that cannot be read.
    public static func parseLicense(_ data: Data) -> Bool? {
        (plist(data)?["Properties"] as? [String: Any])?["Software License Agreement"] as? Bool
    }

    /// From `spctl --assess --raw`.
    public static func parseVerdict(_ data: Data) -> Bool? {
        plist(data)?["assessment:verdict"] as? Bool
    }

    /// `hdiutil imageinfo -plist`, read: a license, none, or a transient refusal.
    public static func license(from result: ProcessResult) -> Result<Bool, Refusal> {
        guard case .exited(0, let output, _) = result, let license = parseLicense(output) else {
            return .failure(.transient(.license, "the disk image\u{2019}s properties could not be read"))
        }
        return .success(license)
    }

    /// `hdiutil attach -plist`, read.
    public static func mount(from result: ProcessResult) -> Result<Mount, AttachFailure> {
        switch result {
        case .timedOut: return .failure(.timedOut)
        case .couldNotStart(let reason): return .failure(.failed(reason))
        case .exited(0, let output, _):
            guard let mount = parseAttach(output) else { return .failure(.failed("unreadable answer")) }
            return .success(mount)
        case .exited(let status, _, let errorOutput):
            return .failure(.failed("hdiutil exited \(status): \(firstLine(errorOutput))"))
        }
    }

    /// `spctl --assess --type execute --raw`, read: exit 0 with a true verdict is the only yes;
    /// exit 1 or 3 is Gatekeeper's no; anything else (a timeout, no answer) is not an answer.
    public static func assessment(from result: ProcessResult) -> AssessmentVerdict {
        switch result {
        case .timedOut: return .unavailable("spctl did not answer in time")
        case .couldNotStart(let reason): return .unavailable(reason)
        case .exited(0, let output, _):
            switch parseVerdict(output) {
            case true?: return .accepted
            case false?: return .rejected("its verdict is negative")
            case nil: return .unavailable("spctl\u{2019}s answer could not be read")
            }
        case .exited(let status, _, let errorOutput) where status == 1 || status == 3:
            return .rejected(firstLine(errorOutput))
        case .exited(let status, _, _):
            return .unavailable("spctl exited \(status)")
        }
    }

    /// `hdiutil detach <device>`: busy (exit 16) is tried five more times 200 ms apart, then
    /// with `-force`. Only a disk device is ever named.
    public static func detach(_ device: String, run: (String, [String]) -> ProcessResult,
                              pause: (TimeInterval) -> Void) -> Bool {
        guard isDevice(device) else { return false }
        for attempt in 0...5 {
            if attempt > 0 { pause(0.2) }
            switch run(hdiutil, ["detach", device]) {
            case .exited(0, _, _): return true
            case .exited(16, _, _): continue
            default: return false
            }
        }
        if case .exited(0, _, _) = run(hdiutil, ["detach", device, "-force"]) { return true }
        return false
    }

    /// Only a disk device is ever handed to `hdiutil detach`.
    static func isDevice(_ text: String) -> Bool { Pattern.matches("^/dev/disk[0-9]+(s[0-9]+)?$", text) }

    static func firstLine(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "no output"
    }
}

// MARK: - Downloading

/// One download of the release file, redirects checked hop by hop, size checked as it arrives.
final class AssetDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private let destination: String
    private var hops = 0
    private var refusedHost: String?
    private var tooLarge = false
    private var receivedBytes = false
    private var finishFailure: Refusal?
    private var finished = false
    private var continuation: CheckedContinuation<Refusal?, Never>?
    private let configuration: URLSessionConfiguration

    /// `configuration` is the release session's own; only a test hands in another.
    init(expected: Int, destination: String,
         configuration: URLSessionConfiguration = SwitcherReleaseFeed.sessionConfiguration(resourceTimeout: 600)) {
        self.expected = expected
        self.destination = destination
        self.configuration = configuration
    }

    func run(_ url: URL) async -> Refusal? {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
            request.httpShouldHandleCookies = false
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        hops += 1
        let hop = hops
        lock.unlock()
        if let from = response.url ?? task.currentRequest?.url, let to = request.url,
           RedirectPolicy.allows(from: from, to: to, hop: hop) {
            completionHandler(request)
        } else {
            lock.lock()
            refusedHost = request.url?.host ?? "an unnamed host"
            lock.unlock()
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        receivedBytes = true
        let over = totalBytesWritten > Int64(expected)
        if over { tooLarge = true }
        lock.unlock()
        if over { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let stop = refusedHost != nil || tooLarge
        lock.unlock()
        guard !stop else { return }
        var failure: Refusal?
        let response = downloadTask.response as? HTTPURLResponse
        if response?.statusCode != 200 {
            failure = .transient(.download, "GitHub answered \(response?.statusCode ?? 0) for the download")
        } else if let length = response?.expectedContentLength, length >= 0, length != Int64(expected) {
            failure = .transient(.download, "the download is \(length) bytes, not \(expected)")
        } else {
            do {
                try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: destination))
            } catch {
                failure = .transient(.download, "the download could not be saved: \(error.localizedDescription)")
            }
        }
        lock.lock()
        finishFailure = failure
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result: Refusal?
        if let host = refusedHost {
            result = .permanent(.download, "the download was sent to an unexpected host (\(host))")
        } else if tooLarge {
            result = .transient(.download, "the download is larger than the release says")
        } else if let error {
            // A failure before the first byte is not an attempt: nothing was tried yet.
            result = .transient(.download, "the download failed: \(error.localizedDescription)", countsAsAttempt: receivedBytes)
        } else {
            result = finishFailure
        }
        let pending = finished ? nil : continuation
        finished = true
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

/// Refuses every redirect: a moved feed is reported, never followed.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - The real environments

extension SwitcherUpdater.CheckEnvironment {
    /// One unauthenticated GET of the feed: no token, no cookie, no cache, redirects refused.
    public static func live() -> Self {
        live(configuration: { SwitcherReleaseFeed.sessionConfiguration(resourceTimeout: 60) })
    }

    /// The same, over the session configuration given: only a test hands in another. Each fetch
    /// has a session of its own, let go of as soon as it has answered.
    static func live(configuration: @escaping @Sendable () -> URLSessionConfiguration) -> Self {
        Self(
            fetch: { request in
                let session = URLSession(configuration: configuration())
                defer { session.finishTasksAndInvalidate() }
                do {
                    let (data, response) = try await session.data(for: request, delegate: RefuseRedirects())
                    guard let http = response as? HTTPURLResponse else { return .transport("no HTTP response") }
                    var headers: [String: String] = [:]
                    for (name, value) in http.allHeaderFields {
                        if let name = name as? String { headers[name] = "\(value)" }
                    }
                    return .response(status: http.statusCode, headers: headers, body: data)
                } catch {
                    return .transport(error.localizedDescription)
                }
            },
            now: { Date() })
    }
}

extension SwitcherUpdater.PrepareEnvironment {
    /// The real thing. Everything it writes is under `updatesDirectory` or in its own staging
    /// folder; its only recursive removal is ``RemovalScope``; every tool it runs goes through
    /// ``SwitcherProcess``. `processObserver` sees each process before it starts. `verifyFlags`
    /// is ``CodeSignature/validationFlags``; only a test keeps itself offline with other ones.
    public static func live(updatesDirectory: URL, store: SwitcherUpdateStore, registry: StagedCopies = .shared,
                            processObserver: SwitcherProcess.Observer? = nil,
                            verifyFlags: SecCSFlags = CodeSignature.validationFlags) -> Self {
        live(updatesDirectory: updatesDirectory, store: store, registry: registry,
             run: { SwitcherProcess.run($0, $1, deadline: DiskImageTool.deadline, observer: processObserver) },
             pause: { Thread.sleep(forTimeInterval: $0) }, verifyFlags: verifyFlags)
    }

    /// The same, with the process runner — and, for a test, the download's session — given: what
    /// the tests drive without starting anything or reaching the network.
    static func live(updatesDirectory: URL, store: SwitcherUpdateStore, registry: StagedCopies,
                     run: @escaping @Sendable (String, [String]) -> ProcessResult,
                     pause: @escaping @Sendable (TimeInterval) -> Void,
                     verifyFlags: SecCSFlags = CodeSignature.validationFlags,
                     downloadConfiguration: @escaping @Sendable () -> URLSessionConfiguration = {
                         SwitcherReleaseFeed.sessionConfiguration(resourceTimeout: 600)
                     }) -> Self {
        let updates = updatesDirectory.path
        let scope = RemovalScope(updatesDirectory: updates, registry: registry)
        var environment = Self(
            download: { url, destination, expected in
                guard url.scheme == "https", url.host == RedirectPolicy.originHost, url.port == nil, url.user == nil else {
                    return .permanent(.download, "the download address is not github.com")
                }
                return await AssetDownload(expected: expected, destination: destination,
                                           configuration: downloadConfiguration()).run(url)
            },
            fileSize: SwitcherDisk.fileSize,
            sha256Hex: SwitcherDisk.sha256Hex,
            freeSpace: SwitcherDisk.freeSpace,
            moveFile: { from, to in Darwin.rename(from, to) == 0 ? 0 : errno },
            makeDirectory: SwitcherDisk.makeDirectory,
            verify: CodeSignature.verifier(flags: verifyFlags),
            imageHasLicense: { image in DiskImageTool.license(from: run(DiskImageTool.hdiutil, ["imageinfo", "-plist", image])) },
            attach: { image, mounts in
                DiskImageTool.mount(from: run(DiskImageTool.hdiutil, ["attach", "-plist", "-nobrowse", "-readonly",
                                                                      "-noautoopen", "-mountrandom", mounts, image]))
            },
            attachedImages: {
                guard case .exited(0, let output, _) = run(DiskImageTool.hdiutil, ["info", "-plist"]) else { return nil }
                return DiskImageTool.parseInfo(output)
            },
            detach: { device in DiskImageTool.detach(device, run: run, pause: pause) },
            listDirectory: SwitcherDisk.listDirectory,
            stagingDirectory: SwitcherDisk.stagingDirectory(for:),
            copyBundle: { from, to in SwitcherDisk.copyBundle(from: from, to: to, registry: registry) },
            removeQuarantine: { SwitcherDisk.removeQuarantine($0) },
            assess: { staged in
                DiskImageTool.assessment(from: run(DiskImageTool.spctl, ["--assess", "--type", "execute", "--raw", staged]))
            },
            prewarm: { staged in
                guard FileManager.default.isExecutableFile(atPath: DiskImageTool.gktool) else { return }
                _ = run(DiskImageTool.gktool, ["scan", staged])
            },
            lstatKind: SwitcherDisk.lstatKind,
            deviceOf: SwitcherDisk.deviceOf,
            canonicalPath: SwitcherDisk.realpath,
            bundleIdentifierOnDisk: SwitcherDisk.bundleIdentifier(ofBundleAt:),
            remove: { scope.remove($0) },
            removeEmptyFolder: SwitcherDisk.removeEmptyFolder,
            moveToPrevious: { bundle, version in
                SwitcherDisk.moveToPrevious(bundle, version: version, updatesDirectory: updates)
            },
            trash: SwitcherDisk.trash,
            takePrepareLock: {
                guard SwitcherDisk.makeDirectory(updates) == 0 else { return nil }
                return PrepareLock.take(at: updates + "/" + PrepareLock.fileName)
            },
            note: { note in _ = try? await store.update(now: Date()) { $0.apply(note) } },
            now: { Date() })
        environment.verifyFlags = verifyFlags
        return environment
    }
}
