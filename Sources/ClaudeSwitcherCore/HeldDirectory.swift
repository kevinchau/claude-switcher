import Darwin
import Foundation

// The file-system layer the session copy stands on.
//
// A path is checked once and used later; anything can happen to it in between. O_NOFOLLOW
// guards only the last component: `open("a/link/b", O_NOFOLLOW)` happily follows `link`
// (verified on this Mac). So nothing below the home directory is reached by path. Each
// directory is opened one component at a time with `openat(…, O_DIRECTORY|O_NOFOLLOW)` from
// the one above it, and kept open; every later stat, create, rename and unlink is an `*at()`
// call on that held descriptor. A component swapped for a link after it was checked can then
// redirect nothing: the work happens in the directory that was checked, wherever its name
// now points.
//
// Errors carry errno and never a path or a name — nothing here may end up printing where a
// user's sessions are (spec D6).

/// Why a file-system step failed.
struct FileSystemError: Error, Equatable, Sendable, CustomStringConvertible {
    enum Reason: Equatable, Sendable {
        /// A symbolic link, or something that is not a directory, where a directory must be.
        /// (On macOS `openat(…, O_DIRECTORY|O_NOFOLLOW)` on a link fails with ENOTDIR, not ELOOP.)
        case linkOrNotDirectory
        /// A link, a FIFO, a directory… where a regular file must be.
        case notRegularFile
        /// Owned by someone other than the user we act for.
        case notOwnedByUser
        /// A directory we would create entries in that others can write to.
        case writableByOthers
        /// Not a single path component: empty, `.`, `..`, or containing `/` or NUL.
        case invalidName
        /// EEXIST on an exclusive create or rename.
        case exists
        /// ENOENT.
        case absent
        /// The volume cannot do an exclusive rename (ENOTSUP / EINVAL from `renameatx_np`).
        case renameUnsupported
        /// Fewer bytes than asked for.
        case shortTransfer
        /// Any other errno.
        case system
    }

    let reason: Reason
    /// The system call, for Diagnostics: `openat`, `fstatat`, `mkdirat`, …
    let operation: String
    let code: Int32

    init(_ reason: Reason, _ operation: String, code: Int32 = 0) {
        self.reason = reason
        self.operation = operation
        self.code = code
    }

    /// Classifies an errno from `operation`.
    static func errno(_ code: Int32, _ operation: String) -> FileSystemError {
        switch code {
        case ENOENT: return FileSystemError(.absent, operation, code: code)
        case EEXIST: return FileSystemError(.exists, operation, code: code)
        default: return FileSystemError(.system, operation, code: code)
        }
    }

    var description: String {
        code == 0 ? "\(operation): \(reason)" : "\(operation): \(reason) (\(String(cString: strerror(code))))"
    }
}

/// What `fstat`/`fstatat` saw, without following a link.
struct FileStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case regular, directory, symbolicLink, other }

    let kind: Kind
    /// Permission bits only (`& 0o7777`).
    let permissions: mode_t
    let owner: uid_t
    let device: Int32
    let inode: UInt64
    let linkCount: Int
    let size: Int64
    let modifiedNanoseconds: Int64
    let changedNanoseconds: Int64

    init(_ info: stat) {
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        permissions = info.st_mode & 0o7777
        owner = info.st_uid
        device = info.st_dev
        inode = info.st_ino
        linkCount = Int(info.st_nlink)
        size = info.st_size
        modifiedNanoseconds = Self.nanoseconds(info.st_mtimespec)
        changedNanoseconds = Self.nanoseconds(info.st_ctimespec)
    }

    /// A time in nanoseconds since 1970, held at the ends of `Int64` rather than overflowing:
    /// a file dated before 1677 or after 2262 (APFS keeps them) must not crash the app that
    /// lists it. A held value still differs from any real change, and an untouched file still
    /// compares equal to itself, which is all the times are used for.
    static func nanoseconds(_ time: timespec) -> Int64 {
        let seconds = Int64(time.tv_sec)
        let (scaled, overflowed) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflowed { return seconds < 0 ? .min : .max }
        let (total, overflowedAgain) = scaled.addingReportingOverflow(Int64(time.tv_nsec))
        if overflowedAgain { return time.tv_nsec < 0 ? .min : .max }
        return total
    }

    /// Two names for one object have the same device and inode — whatever their spelling.
    /// (The data volume is case-insensitive: `…/Claude-work` and `…/claude-WORK` are one folder.)
    var identity: FileIdentity { FileIdentity(device: device, inode: inode) }

    /// `lstat` of a whole path. Only for read-only display decisions; anything that acts goes
    /// through a ``HeldDirectory``.
    static func ofPath(_ path: String) -> FileStatus? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileStatus(info)
    }
}

/// `(st_dev, st_ino)`: the identity of a file-system object.
struct FileIdentity: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

/// `renameatx_np(fromDirectory, from, toDirectory, to, RENAME_EXCL)`: returns 0, or the errno.
/// Injectable so tests can stand in a volume without exclusive rename. There is deliberately no
/// `rename()` anywhere in this layer: a plain rename silently replaces an existing *empty
/// directory*, which is exactly what is at `<id>/` if anything is.
typealias ExclusiveRename = @Sendable (_ fromDirectory: Int32, _ from: String, _ toDirectory: Int32, _ to: String) -> Int32

enum ExclusiveRenaming {
    static let live: ExclusiveRename = { fromDirectory, from, toDirectory, to in
        renameatx_np(fromDirectory, from, toDirectory, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }
}

// MARK: - A held directory

/// A directory held open by descriptor. Closed when the last reference goes away.
final class HeldDirectory {
    let descriptor: Int32
    /// As `fstat` saw it when it was opened (or when this layer last changed its mode).
    private(set) var status: FileStatus

    private init(descriptor: Int32, status: FileStatus) {
        self.descriptor = descriptor
        self.status = status
    }

    deinit { close(descriptor) }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Wraps a freshly opened directory descriptor, closing it if it is not acceptable.
    private static func adopt(_ descriptor: Int32, expectedOwner: uid_t?) throws -> HeldDirectory {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw FileSystemError.errno(code, "fstat")
        }
        let status = FileStatus(info)
        guard status.kind == .directory else {
            close(descriptor)
            throw FileSystemError(.linkOrNotDirectory, "fstat")
        }
        if let expectedOwner, status.owner != expectedOwner {
            close(descriptor)
            throw FileSystemError(.notOwnedByUser, "fstat")
        }
        return HeldDirectory(descriptor: descriptor, status: status)
    }

    /// Opens an anchor: the home directory, or a user-data directory outside it. A link *at*
    /// the anchor is followed, as Claude itself follows one; nothing below it ever is.
    static func openAnchor(_ path: String, expectedOwner: uid_t?) throws -> HeldDirectory {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw FileSystemError(.invalidName, "open") }
        let descriptor = retryingOnInterrupt { open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw FileSystemError.errno(errno, "open") }
        return try adopt(descriptor, expectedOwner: expectedOwner)
    }

    /// Opens `path` by walking to it one component at a time from `home`, refusing a link or a
    /// non-directory at every step (spec D2: a symlinked `~/.claude` is refused too).
    /// Components above `home` are not walked. A `path` outside `home` is its own anchor — and
    /// must really be outside: one spelled outside home that leads into it is refused.
    static func walk(to path: String, home: String, expectedOwner: uid_t?) throws -> HeldDirectory {
        let (anchor, components) = try anchorAndComponents(of: path, home: home)
        var current = try openAnchor(anchor, expectedOwner: expectedOwner)
        if anchor != PathNormalizer.normalize(home, home: home) {
            try current.requireOutside(home: home)
        }
        for component in components {
            current = try current.openDirectory(component, expectedOwner: expectedOwner)
        }
        return current
    }

    /// Refuses an anchor that is the home directory or lies below it, whatever its spelling.
    ///
    /// A path spelled through a link outside home — `/tmp/x` pointing at `~/Library` — has no
    /// ancestor that *is* home, so ``anchorAndComponents(of:home:)`` makes it its own anchor,
    /// and opening it by path followed every link on the way, those below home included. Where
    /// it landed is decided on the descriptor instead: climb `..` from what was opened, by
    /// device and inode, up to the root. Never re-walked by its resolved path: the canonical
    /// spelling of the same folder is refused when a link below home is on it, so this one is
    /// refused too. (`O_SEARCH` needs only the search permission that reaching it already took.)
    private func requireOutside(home: String) throws {
        let homeIdentity = try Self.openAnchor(PathNormalizer.normalize(home, home: home), expectedOwner: nil).status.identity
        var current = self
        for _ in 0..<Int(MAXPATHLEN) {
            if current.status.identity == homeIdentity { throw FileSystemError(.linkOrNotDirectory, "openat") }
            let descriptor = retryingOnInterrupt { openat(current.descriptor, "..", O_SEARCH | O_CLOEXEC) }
            guard descriptor >= 0 else { throw FileSystemError.errno(errno, "openat") }
            let parent = try Self.adopt(descriptor, expectedOwner: nil)
            // The root is its own parent.
            if parent.status.identity == current.status.identity { return }
            current = parent
        }
        throw FileSystemError(.linkOrNotDirectory, "openat")
    }

    /// Splits `path` into the anchor it is walked from and the components below it.
    ///
    /// Whether `path` is under the home directory is decided by identity, not spelling: the
    /// data volume ignores case and Unicode normalisation, and `/private/var` is `/var`, so
    /// `/Users/ME/…` names the same folders as `/Users/me/…` — and opened as an anchor of its
    /// own, it would follow every link below home. Only a path none of whose ancestors *is* the
    /// home directory is its own anchor.
    static func anchorAndComponents(of path: String, home: String) throws -> (anchor: String, components: [String]) {
        let target = PathNormalizer.normalize(path, home: home)
        let base = PathNormalizer.normalize(home, home: home)
        guard target.hasPrefix("/"), base.hasPrefix("/") else { throw FileSystemError(.invalidName, "walk") }
        let components: [String]
        if target == base {
            components = []
        } else if base == "/" {
            components = target.split(separator: "/").map(String.init)
        } else if target.hasPrefix(base + "/") {
            components = target.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        } else if let below = componentsBelow(home: base, in: target) {
            components = below
        } else {
            return (target, [])
        }
        guard components.allSatisfy(isSingleComponent) else { throw FileSystemError(.invalidName, "walk") }
        return (base, components)
    }

    /// The components of `target` below the first of its ancestors that has the home
    /// directory's device and inode, or `nil` when none does. Each ancestor is looked at with
    /// `stat`, which follows a link: a link that leads to home stands for home, and everything
    /// below it is still walked without following anything.
    private static func componentsBelow(home: String, in target: String) -> [String]? {
        var info = stat()
        guard stat(home, &info) == 0 else { return nil }
        let homeIdentity = FileIdentity(device: info.st_dev, inode: info.st_ino)
        let parts = target.split(separator: "/").map(String.init)
        for depth in stride(from: 1, through: parts.count, by: 1) {
            let ancestor = "/" + parts.prefix(depth).joined(separator: "/")
            // Nothing deeper exists if this does not.
            guard stat(ancestor, &info) == 0 else { return nil }
            if FileIdentity(device: info.st_dev, inode: info.st_ino) == homeIdentity {
                return Array(parts.dropFirst(depth))
            }
        }
        return nil
    }

    /// One path component, and nothing that could make an `*at()` call reach elsewhere.
    static func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.utf8.contains(0) && name.utf8.count <= Int(NAME_MAX)
    }

    private func checkedName(_ name: String, _ operation: String) throws -> String {
        guard Self.isSingleComponent(name) else { throw FileSystemError(.invalidName, operation) }
        return name
    }

    // MARK: Looking

    /// `openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`.
    func openDirectory(_ name: String, expectedOwner: uid_t?) throws -> HeldDirectory {
        let name = try checkedName(name, "openat")
        let descriptor = retryingOnInterrupt { openat(self.descriptor, name, Self.directoryFlags) }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOTDIR || code == ELOOP { throw FileSystemError(.linkOrNotDirectory, "openat", code: code) }
            throw FileSystemError.errno(code, "openat")
        }
        return try Self.adopt(descriptor, expectedOwner: expectedOwner)
    }

    /// `fstatat(AT_SYMLINK_NOFOLLOW)`. Throws `.absent` on ENOENT.
    func status(of name: String) throws -> FileStatus {
        let name = try checkedName(name, "fstatat")
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FileSystemError.errno(errno, "fstatat")
        }
        return FileStatus(info)
    }

    /// True only when `fstatat` says ENOENT. Anything else — success, EACCES, ELOOP, a name
    /// that is not a single component — means something is, or may be, there.
    func proveAbsent(_ name: String) -> Bool {
        guard Self.isSingleComponent(name) else { return false }
        var info = stat()
        return fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
    }

    /// The names in this directory, without `.` and `..`. Read through a fresh descriptor so
    /// the held one keeps no directory offset.
    func entries() throws -> [String] {
        let fresh = retryingOnInterrupt { openat(descriptor, ".", Self.directoryFlags) }
        guard fresh >= 0 else { throw FileSystemError.errno(errno, "openat") }
        guard let stream = fdopendir(fresh) else {
            let code = errno
            close(fresh)
            throw FileSystemError.errno(code, "fdopendir")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            // readdir returns NULL both at the end and on error; only errno tells them apart.
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw FileSystemError.errno(errno, "readdir") }
                return names
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    /// Opens a regular file to read: `O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC`, then `fstat`.
    /// `O_NONBLOCK` is what keeps a FIFO planted at the name from hanging the caller forever.
    func openRegularFile(_ name: String) throws -> HeldFile {
        let name = try checkedName(name, "openat")
        let descriptor = retryingOnInterrupt { openat(self.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP { throw FileSystemError(.notRegularFile, "openat", code: code) }
            throw FileSystemError.errno(code, "openat")
        }
        let file = HeldFile(descriptor: descriptor)
        guard try file.status().kind == .regular else { throw FileSystemError(.notRegularFile, "fstat") }
        return file
    }

    // MARK: Creating

    /// `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC`, mode 0600 (and `fchmod` 0600, so the
    /// umask cannot leave it anything else). Fails with `.exists` on anything already at the
    /// name — a file, a directory, a dangling link.
    func createFile(_ name: String) throws -> HeldFile {
        let name = try checkedName(name, "openat")
        let descriptor = retryingOnInterrupt {
            openat(self.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw FileSystemError.errno(errno, "openat") }
        let file = HeldFile(descriptor: descriptor)
        guard fchmod(descriptor, 0o600) == 0 else { throw FileSystemError.errno(errno, "fchmod") }
        return file
    }

    /// `mkdirat` 0700, exclusive; then re-opened with `O_NOFOLLOW` (it could have been
    /// swapped for a link in between — Claude's own mkdirPrivate calls that a "plant race"),
    /// checked, and `fchmod` 0700. `afterCreating` runs in that gap; tests use it to plant, and
    /// a copy's step hook to stop there as a crash would.
    func makeDirectory(_ name: String, expectedOwner: uid_t?, afterCreating: (() throws -> Void)? = nil) throws -> HeldDirectory {
        let name = try checkedName(name, "mkdirat")
        guard mkdirat(descriptor, name, 0o700) == 0 else { throw FileSystemError.errno(errno, "mkdirat") }
        try afterCreating?()
        let made = try openDirectory(name, expectedOwner: expectedOwner)
        guard fchmod(made.descriptor, 0o700) == 0 else { throw FileSystemError.errno(errno, "fchmod") }
        var info = stat()
        guard fstat(made.descriptor, &info) == 0 else { throw FileSystemError.errno(errno, "fstat") }
        made.status = FileStatus(info)
        return made
    }

    // MARK: Removing and renaming

    /// `unlinkat(name, 0)`: one name, never a directory.
    func unlink(_ name: String) throws {
        let name = try checkedName(name, "unlinkat")
        guard unlinkat(descriptor, name, 0) == 0 else { throw FileSystemError.errno(errno, "unlinkat") }
    }

    /// `unlinkat(name, AT_REMOVEDIR)`: succeeds only on an empty directory — not even a
    /// `.DS_Store` — and never on a link. There is no recursive remove in this layer.
    func removeDirectory(_ name: String) throws {
        let name = try checkedName(name, "unlinkat")
        guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw FileSystemError.errno(errno, "unlinkat") }
    }

    /// Renames `from` in this directory to `to` in `destination` (this one by default), only if
    /// nothing is at `to`. Never falls back to `rename()`.
    func renameExclusive(_ from: String, to: String, in destination: HeldDirectory? = nil,
                         using rename: ExclusiveRename = ExclusiveRenaming.live) throws {
        let from = try checkedName(from, "renameatx_np")
        let to = try checkedName(to, "renameatx_np")
        let code = rename(descriptor, from, (destination ?? self).descriptor, to)
        switch code {
        case 0: return
        case ENOTSUP, EINVAL: throw FileSystemError(.renameUnsupported, "renameatx_np", code: code)
        default: throw FileSystemError.errno(code, "renameatx_np")
        }
    }

    // MARK: Durability and checks

    func sync() throws {
        guard fsync(descriptor) == 0 else { throw FileSystemError.errno(errno, "fsync") }
    }

    /// `fsync` does not flush the drive's cache on macOS; `F_FULLFSYNC` does.
    func fullSync() throws {
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw FileSystemError.errno(errno, "fcntl") }
    }

    func requireOwned(by owner: uid_t) throws {
        guard status.owner == owner else { throw FileSystemError(.notOwnedByUser, "fstat") }
    }

    /// For a directory this tool creates entries in: nobody but its owner may add or swap names.
    func requireNotWritableByOthers() throws {
        guard status.permissions & (S_IWGRP | S_IWOTH) == 0 else { throw FileSystemError(.writableByOthers, "fstat") }
    }

    /// Bytes available to the user on this directory's volume.
    static func freeBytes(onVolumeOf descriptor: Int32) -> UInt64? {
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { return nil }
        return UInt64(info.f_bavail) * UInt64(info.f_bsize)
    }
}

// MARK: - A held file

/// A regular file held open by descriptor. Closed when the last reference goes away.
final class HeldFile {
    let descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { close(descriptor) }

    func status() throws -> FileStatus {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw FileSystemError.errno(errno, "fstat") }
        return FileStatus(info)
    }

    /// Up to `count` bytes from `offset`, with `pread`. Fewer only at end of file — which a
    /// caller that knows the size treats as "the file changed under us".
    func read(count: Int, at offset: Int64) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var filled = 0
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            while filled < count {
                let chunk = min(count - filled, 1 << 20)
                let got = pread(descriptor, base + filled, chunk, offset + Int64(filled))
                if got < 0 {
                    if errno == EINTR { continue }
                    throw FileSystemError.errno(errno, "pread")
                }
                if got == 0 { break }
                filled += got
            }
        }
        data.count = filled
        return data
    }

    /// The whole file, if it is no larger than `limit` and does not change size while read.
    func readAll(limit: Int) throws -> Data {
        let size = try status().size
        guard size >= 0, size <= Int64(limit) else { throw FileSystemError(.shortTransfer, "fstat") }
        let data = try read(count: Int(size), at: 0)
        guard data.count == Int(size) else { throw FileSystemError(.shortTransfer, "pread") }
        return data
    }

    /// All of `data`, or an error.
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let got = Darwin.write(descriptor, base + written, buffer.count - written)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw FileSystemError.errno(errno, "write")
                }
                if got == 0 { throw FileSystemError(.shortTransfer, "write") }
                written += got
            }
        }
    }

    func sync() throws {
        guard fsync(descriptor) == 0 else { throw FileSystemError.errno(errno, "fsync") }
    }

    func fullSync() throws {
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw FileSystemError.errno(errno, "fcntl") }
    }
}

/// Retries a system call that failed with EINTR.
private func retryingOnInterrupt(_ call: () -> Int32) -> Int32 {
    var result: Int32
    repeat { result = call() } while result < 0 && errno == EINTR
    return result
}
