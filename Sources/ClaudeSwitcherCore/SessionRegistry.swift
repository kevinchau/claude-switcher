import Darwin
import Foundation

/// Which Code sessions a running Claude has open right now, and which are mid-reply.
///
/// Every Claude Code process — the one Desktop runs behind each open session included —
/// registers itself in `~/.claude/sessions/<pid>.json`, shared by all profiles:
/// `{pid, sessionId (the transcript id), hostSessionId (Desktop's local_<uuid>), status, procStart, …}`.
/// It removes the file when it exits, but a crash leaves it behind, and pids are reused; an
/// entry counts only while its pid is alive *and* is still the process that wrote it
/// (`procStart`, the process's start time as `ps -o lstart=` printed it).
///
/// Advisory, and read-only: a copy's guarantee against a transcript changing under it is the
/// before-and-after `fstat` of its own read, not this.
public struct RunningSessions: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        public let pid: Int32
        /// The registry's `sessionId`: the transcript the process is writing.
        public let cliSessionId: String?
        /// Desktop's `local_<uuid>` for the session, when Desktop started the process.
        public let hostSessionId: String?
        /// Mid-turn: `busy`, or waiting on the user mid-turn. Only `idle` (or no status yet) is at rest.
        public let isBusy: Bool

        public init(pid: Int32, cliSessionId: String?, hostSessionId: String?, isBusy: Bool) {
            self.pid = pid
            self.cliSessionId = cliSessionId
            self.hostSessionId = hostSessionId
            self.isBusy = isBusy
        }
    }

    /// Entries whose process is alive. Dead and reused pids are already left out.
    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    static let directoryName = "sessions"
    private static let maximumEntryBytes = 1024 * 1024

    /// The registry entries for a record: by Desktop's id, or by the transcript it names.
    public func entries(for record: SessionRecord) -> [Entry] {
        entries.filter { entry in
            entry.hostSessionId == record.id
                || (record.cliSessionId != nil && entry.cliSessionId?.lowercased() == record.cliSessionId?.lowercased())
        }
    }

    public func isOpen(_ record: SessionRecord) -> Bool { !entries(for: record).isEmpty }
    public func isBusy(_ record: SessionRecord) -> Bool { entries(for: record).contains(where: \.isBusy) }

    public var openCliSessionIds: Set<String> { Set(entries.compactMap(\.cliSessionId)) }
    public var busyCliSessionIds: Set<String> { Set(entries.filter(\.isBusy).compactMap(\.cliSessionId)) }

    /// Reads `<home>/.claude/sessions`. Unreadable entries are skipped; nothing is written.
    public static func read(
        home: String = NSHomeDirectory(),
        isAlive: @Sendable (_ pid: Int32, _ procStart: String?) -> Bool = RunningSessions.isProcessAlive
    ) -> RunningSessions {
        let path = PathNormalizer.normalize(".claude/" + directoryName, home: home)
        guard let directory = try? HeldDirectory.openAnchor(path, expectedOwner: nil),
              let names = try? directory.entries()
        else { return RunningSessions(entries: []) }

        var entries: [Entry] = []
        for name in names.sorted() {
            guard name.hasSuffix(".json"),
                  let filePid = Int32(name.dropLast(5)), filePid > 0,
                  let file = try? directory.openRegularFile(name),
                  let data = try? file.readAll(limit: maximumEntryBytes),
                  let entry = parse(data, filePid: filePid)
            else { continue }
            guard isAlive(entry.entry.pid, entry.procStart) else { continue }
            entries.append(entry.entry)
        }
        return RunningSessions(entries: entries)
    }

    static func parse(_ data: Data, filePid: Int32) -> (entry: Entry, procStart: String?)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let pid: Int32
        if let number = root["pid"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            guard let exact = Int32(exactly: number.doubleValue), exact > 0 else { return nil }
            pid = exact
        } else {
            pid = filePid
        }
        let status = root["status"] as? String
        let entry = Entry(
            pid: pid,
            cliSessionId: (root["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            hostSessionId: (root["hostSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            // Anything but idle counts as working: an unknown status is not proof of rest.
            isBusy: root["status"] != nil && status != "idle"
        )
        return (entry, root["procStart"] as? String)
    }

    // MARK: - Is that process still the one that registered?

    /// Whether `pid` is alive and, when the entry says when its process started, is still that
    /// process. `sysctl(KERN_PROC_PID)`, never `kill(pid, 0)` (which needs permission and says
    /// nothing about reuse). A pid that cannot be checked counts as alive: "busy" must not be
    /// argued away by an error.
    public static func isProcessAlive(pid: Int32, procStart: String?) -> Bool {
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return true }
        guard size > 0 else { return false }
        guard let procStart, let recorded = startSeconds(fromProcStart: procStart) else { return true }
        return abs(recorded - Int64(info.kp_proc.p_starttime.tv_sec)) <= 1
    }

    /// Parses `procStart`: `ps -o lstart=` run with `LC_ALL=C TZ=UTC`, e.g. `Mon Oct  5 09:12:34 2026`.
    static func startSeconds(fromProcStart text: String) -> Int64? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard parts.count == 5,
              let month = months.firstIndex(of: String(parts[1])),
              let day = Int(parts[2]), let year = Int(parts[4])
        else { return nil }
        let clock = parts[3].split(separator: ":")
        guard clock.count == 3, let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Int(clock[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }
}
