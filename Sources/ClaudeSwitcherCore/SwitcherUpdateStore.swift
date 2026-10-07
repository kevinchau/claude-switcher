import Darwin
import Foundation

/// The file operations the store is built from. A file is only ever created new — never opened
/// for writing over what is there — and put in place by `rename`, so a crash or power loss
/// leaves either the old record or the new one, never a torn one.
public struct StoreFileSystem: Sendable {
    /// The file's bytes, or `nil` when it cannot be read.
    public var read: @Sendable (_ path: String) -> Data?
    /// Whether anything is at `path` (not following a final symlink).
    public var exists: @Sendable (_ path: String) -> Bool
    /// Creates `path`, which must not exist yet, writes `data`, flushes it to disk and closes it.
    /// Returns 0 or an errno.
    public var createAndFlush: @Sendable (_ path: String, _ data: Data) -> Int32
    public var rename: @Sendable (_ from: String, _ to: String) -> Int32
    public var unlink: @Sendable (_ path: String) -> Int32
    /// Creates the directory with mode 0700; an existing one is fine. Returns 0 or an errno.
    public var makeDirectory: @Sendable (_ path: String) -> Int32
    /// The names in a directory, or `nil` when it cannot be read.
    public var list: @Sendable (_ path: String) -> [String]?

    public init(read: @escaping @Sendable (String) -> Data?, exists: @escaping @Sendable (String) -> Bool,
                createAndFlush: @escaping @Sendable (String, Data) -> Int32,
                rename: @escaping @Sendable (String, String) -> Int32, unlink: @escaping @Sendable (String) -> Int32,
                makeDirectory: @escaping @Sendable (String) -> Int32,
                list: @escaping @Sendable (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) }) {
        self.read = read
        self.exists = exists
        self.createAndFlush = createAndFlush
        self.rename = rename
        self.unlink = unlink
        self.makeDirectory = makeDirectory
        self.list = list
    }

    public static let live = StoreFileSystem(
        read: { path in
            // Bounded: these records are a few kilobytes; a huge file is not one of them.
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: 4 << 20)
        },
        exists: { path in
            var info = stat()
            return lstat(path, &info) == 0
        },
        createAndFlush: { path, data in
            let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return errno }
            defer { close(descriptor) }
            var written = 0
            let failure: Int32 = data.withUnsafeBytes { buffer in
                while written < buffer.count {
                    let result = write(descriptor, buffer.baseAddress! + written, buffer.count - written)
                    if result < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    written += result
                }
                return 0
            }
            guard failure == 0 else { return failure }
            // `fsync` may leave the bytes in the drive's cache, where a power cut loses them after
            // the rename has landed; `F_FULLFSYNC` does not. A volume that cannot do it gets `fsync`.
            if fcntl(descriptor, F_FULLFSYNC) == 0 { return 0 }
            guard errno == ENOTSUP || errno == EINVAL else { return errno }
            return fsync(descriptor) == 0 ? 0 : errno
        },
        rename: { from, to in Darwin.rename(from, to) == 0 ? 0 : errno },
        unlink: { path in Darwin.unlink(path) == 0 ? 0 : errno },
        makeDirectory: { path in
            if mkdir(path, 0o700) == 0 { return 0 }
            let code = errno
            var info = stat()
            if code == EEXIST, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return 0 }
            return code
        })
}

public struct StoreError: Error, Equatable, Sendable, CustomStringConvertible {
    public let errno: Int32
    public let file: String

    public var description: String { "could not write \(file): \(String(cString: strerror(errno)))" }
}

/// The one way `state.json`, `handoff.json` and `starting.json` are read and written. An actor,
/// so the detached prepare and the main actor can never interleave two writes.
public actor SwitcherUpdateStore {

    /// `~/.config/claude-switcher/updates`, next to `config.json`.
    public static var directoryURL: URL {
        Config.configURL.deletingLastPathComponent().appendingPathComponent("updates", isDirectory: true)
    }

    public static let stateName = "state.json"
    public static let handoffName = "handoff.json"
    public static let failedHandoffName = "handoff.failed.json"
    public static let markerName = "starting.json"

    public nonisolated let directory: URL
    /// This Mac; records written by another one are ignored.
    public nonisolated let host: String
    private let files: StoreFileSystem

    public init(directory: URL = SwitcherUpdateStore.directoryURL, host: String = SwitcherHost.id(),
                files: StoreFileSystem = .live) {
        self.directory = directory
        self.host = host
        self.files = files
    }

    private nonisolated func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    // MARK: state.json

    public func read() -> RecordRead<SwitcherUpdateState> { readRecord(Self.stateName) }

    /// The state to work from. A file from another Mac is ignored (and named in Diagnostics);
    /// dates that lie more than a day ahead are dropped, so the next check is due now.
    ///
    /// Ignored, not adopted: nothing in it is acted on. One path holds one record, so this
    /// Mac's next ``save(_:)`` takes its place — the schedule and rejections are per Mac.
    public func load(now: Date) -> SwitcherUpdateState { snapshot(now: now) }

    /// The same reading as ``load(now:)``, for a reader that cannot wait on the actor and only
    /// looks — `--dry-run`, before there is an app. Safe without the actor: every write lands
    /// by `rename`, so a read sees the old record or the new one, never part of either.
    public nonisolated func snapshot(now: Date) -> SwitcherUpdateState {
        guard case .record(let state) = readRecord(Self.stateName) as RecordRead<SwitcherUpdateState> else {
            return SwitcherUpdateState()
        }
        if let recorded = state.host, recorded != host {
            var fresh = SwitcherUpdateState()
            fresh.foreignRecordsSeen = true
            return fresh
        }
        return SwitcherUpdatePolicy.sanitized(state, now: now)
    }

    public func save(_ state: SwitcherUpdateState) throws {
        var stamped = state
        stamped.format = SwitcherUpdateState.currentFormat
        stamped.host = host
        try write(stamped, to: Self.stateName)
    }

    /// Read, change and write back in one turn of the actor.
    @discardableResult
    public func update(now: Date, _ body: @Sendable (inout SwitcherUpdateState) -> Void) throws -> SwitcherUpdateState {
        var state = load(now: now)
        body(&state)
        try save(state)
        return state
    }

    // MARK: handoff.json

    public func loadHandoff() -> RecordRead<UpdateHandoff> { readRecord(Self.handoffName) }

    public func writeHandoff(_ handoff: UpdateHandoff) throws { try write(handoff, to: Self.handoffName) }

    public func deleteHandoff() throws { try remove(Self.handoffName) }

    /// Keeps the record of a failed update as `handoff.failed.json`, replacing an older one.
    public func archiveFailedHandoff() throws {
        let code = files.rename(path(Self.handoffName), path(Self.failedHandoffName))
        guard code == 0 || code == ENOENT else { throw StoreError(errno: code, file: Self.failedHandoffName) }
    }

    // MARK: starting.json

    public func loadMarker() -> RecordRead<StartMarker> { readRecord(Self.markerName) }

    public func writeMarker(_ marker: StartMarker) throws { try write(marker, to: Self.markerName) }

    public func deleteMarker() throws { try remove(Self.markerName) }

    /// The first thing a start does: counts this start, and returns how many earlier starts of
    /// this version on this Mac never got to the point where the marker is deleted.
    public func recordStart(version: ReleaseVersion?, installPath: String, now: Date) throws -> Int {
        let prior = SwitcherUpdatePolicy.abortedStarts(marker: loadMarker().value, version: version, host: host)
        try writeMarker(StartMarker(version: version, host: host, installPath: installPath, count: prior + 1, at: now))
        return prior
    }

    /// This start has got going: its marker goes. One another version or another Mac wrote —
    /// a copy started since, with a count of its own — is left alone. In the copy holding the
    /// lock, so does this Mac's finished record of the update that installed this version: it was
    /// what the crash-loop guard went by, and a version that has started once is not sent back.
    public func settleStart(version: ReleaseVersion?, isLockHolder: Bool = false) throws {
        if case .record(let marker) = loadMarker(), marker.host == host, let version, marker.version == version {
            try deleteMarker()
        }
        if isLockHolder, case .record(let handoff) = loadHandoff(),
           SwitcherUpdater.isSettledByStart(handoff, running: version, host: host) {
            try deleteHandoff()
        }
    }

    /// Takes back the count of a start that never really started: an instance launched after an
    /// update that exits because the old one still holds the lock. Such an exit is not a crash
    /// and must not count toward going back to the previous version.
    public func withdrawStart(version: ReleaseVersion?) throws {
        guard case .record(var marker) = loadMarker(), marker.host == host, let version, marker.version == version
        else { return }
        if marker.count <= 1 {
            try deleteMarker()
        } else {
            marker.count -= 1
            try writeMarker(marker)
        }
    }

    // MARK: Files

    /// A record's temporary file, as ``write(_:to:)`` names it: what a crash between creating it
    /// and putting it in place leaves behind.
    static let temporaryFilePattern = #"^\.(state|handoff|starting)\.json\.[0-9A-Fa-f-]{36}\.tmp$"#

    /// Removes the temporary files a crash left in this folder — one file at a time with `unlink`,
    /// never a folder, never anything else. For the lock holder at launch, when no write of its
    /// own is half-way: the actor finishes each write in one turn.
    public func sweepTemporaryFiles() {
        for name in files.list(directory.path) ?? [] where Pattern.matches(Self.temporaryFilePattern, name) {
            _ = files.unlink(path(name))
        }
    }

    private nonisolated func readRecord<Value: Decodable & Equatable & Sendable>(_ name: String) -> RecordRead<Value> {
        let file = path(name)
        guard files.exists(file) else { return .absent }
        guard let data = files.read(file) else { return .unreadable("\(name) could not be read") }
        do {
            return .record(try SwitcherUpdateStore.decoder.decode(Value.self, from: data))
        } catch {
            return .unreadable("\(name) is not a record this version understands")
        }
    }

    private func write<Value: Encodable>(_ value: Value, to name: String) throws {
        let directoryCode = files.makeDirectory(directory.path)
        guard directoryCode == 0 else { throw StoreError(errno: directoryCode, file: directory.lastPathComponent) }
        var data = try SwitcherUpdateStore.encoder.encode(value)
        data.append(0x0A)
        let temporary = path(".\(name).\(UUID().uuidString).tmp")
        let created = files.createAndFlush(temporary, data)
        guard created == 0 else {
            _ = files.unlink(temporary)
            throw StoreError(errno: created, file: name)
        }
        let renamed = files.rename(temporary, path(name))
        guard renamed == 0 else {
            _ = files.unlink(temporary)
            throw StoreError(errno: renamed, file: name)
        }
    }

    private func remove(_ name: String) throws {
        let code = files.unlink(path(name))
        guard code == 0 || code == ENOENT else { throw StoreError(errno: code, file: name) }
    }

    // MARK: Coding

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestampFormatter.string(from: date))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = timestampFormatter.date(from: text) ?? wholeSecondFormatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a timestamp: \(text)")
            }
            return date
        }
        return decoder
    }

    private static var timestampFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// A hand-written date usually has no fraction; it should still read.
    private static var wholeSecondFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

/// This Mac's hardware UUID (`gethostuuid(2)`), which every record carries so that a
/// `~/.config` synced between Macs never has one act on another's update.
public enum SwitcherHost {
    public static func id() -> String {
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 5, tv_nsec: 0)
        let status = withUnsafeMutablePointer(to: &uuid) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: 16) { gethostuuid($0, &wait) }
        }
        guard status == 0 else { return "unknown-host" }
        return UUID(uuid: uuid).uuidString
    }
}
