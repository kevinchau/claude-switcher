import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// The running-session registry, `~/.claude/sessions/<pid>.json`, under a temporary home.
final class SessionRegistryTests: XCTestCase {

    private let x = "c1c1c1c1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let y = "c2c2c2c2-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let local = "local_11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    private func record(id: String? = nil, cli: String?) -> SessionRecord {
        SessionRecord(id: id ?? local, cliSessionId: cli, title: nil, cwd: "/Users/me/app")
    }

    func testOpenAndBusySessionsAreReadFromTheRegistry() throws {
        let home = try FakeHome()
        try home.writeRegistry(pid: 101, ["sessionId": x, "hostSessionId": local, "status": "busy", "procStart": "Mon Oct  5 09:12:34 2026"])
        try home.writeRegistry(pid: 102, ["sessionId": y, "status": "idle"])
        let running = RunningSessions.read(home: home.home, isAlive: { _, _ in true })

        XCTAssertEqual(running.openCliSessionIds, [x, y])
        XCTAssertEqual(running.busyCliSessionIds, [x])
        XCTAssertTrue(running.isOpen(record(cli: x)))
        XCTAssertTrue(running.isBusy(record(cli: x)))
        XCTAssertTrue(running.isOpen(record(id: "local_22222222-aaaa-4aaa-8aaa-aaaaaaaaaaaa", cli: y)))
        XCTAssertFalse(running.isBusy(record(id: "local_22222222-aaaa-4aaa-8aaa-aaaaaaaaaaaa", cli: y)))
        XCTAssertFalse(running.isOpen(record(id: "local_33333333-aaaa-4aaa-8aaa-aaaaaaaaaaaa", cli: nil)))
    }

    /// Matched by Desktop's id, or by the transcript id when Desktop did not register its own.
    func testARecordMatchesByItsIdOrItsTranscript() throws {
        let home = try FakeHome()
        try home.writeRegistry(pid: 201, ["sessionId": "dddddddd-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "hostSessionId": local, "status": "busy"])
        let running = RunningSessions.read(home: home.home, isAlive: { _, _ in true })
        XCTAssertTrue(running.isBusy(record(cli: x)), "the record's own id")
        XCTAssertFalse(running.isBusy(record(id: "local_44444444-aaaa-4aaa-8aaa-aaaaaaaaaaaa", cli: x)))
        XCTAssertTrue(running.isBusy(record(id: "local_44444444-aaaa-4aaa-8aaa-aaaaaaaaaaaa", cli: "DDDDDDDD-aaaa-4aaa-8aaa-aaaaaaaaaaaa")))
    }

    /// Only `idle`, or no status yet, is at rest. Waiting on the user mid-turn, or a status this
    /// version does not know, is not.
    func testAnythingButIdleCountsAsBusy() throws {
        let home = try FakeHome()
        let cases: [(Int32, Any?, Bool)] = [(301, "busy", true), (302, "waiting", true), (303, "compacting", true),
                                             (304, "idle", false), (305, nil, false)]
        for (pid, status, _) in cases {
            var fields: [String: Any] = ["sessionId": "\(pid)ffffff-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
            if let status { fields["status"] = status }
            try home.writeRegistry(pid: pid, fields)
        }
        let running = RunningSessions.read(home: home.home, isAlive: { _, _ in true })
        for (pid, _, busy) in cases {
            XCTAssertEqual(running.entries.first { $0.pid == pid }?.isBusy, busy, "\(pid)")
        }
    }

    /// A crashed process leaves its entry behind, and pids are reused: an entry counts only
    /// while the liveness check says its pid is still the process that wrote it.
    func testEntriesOfDeadOrReusedProcessesAreIgnored() throws {
        let home = try FakeHome()
        try home.writeRegistry(pid: 401, ["sessionId": x, "status": "busy", "procStart": "Mon Oct  5 09:12:34 2026"])
        try home.writeRegistry(pid: 402, ["sessionId": y, "status": "busy", "procStart": "Tue Oct  6 10:00:00 2026"])
        let seen = Recorder()
        let running = RunningSessions.read(home: home.home, isAlive: { pid, start in
            seen.add("\(pid) \(start ?? "-")")
            return pid == 402
        })
        XCTAssertEqual(running.openCliSessionIds, [y])
        XCTAssertEqual(seen.values.sorted(), ["401 Mon Oct  5 09:12:34 2026", "402 Tue Oct  6 10:00:00 2026"])
    }

    func testWhatIsNotARegistryEntryIsSkippedWithoutHanging() throws {
        let home = try FakeHome()
        let directory = home.root.appendingPathComponent(".claude/sessions")
        try home.writeRegistry(pid: 501, ["sessionId": x, "status": "busy"])
        try Data("not json".utf8).write(to: directory.appendingPathComponent("502.json"))
        try JSONSerialization.data(withJSONObject: ["sessionId": y, "status": "busy"]).write(to: directory.appendingPathComponent("notapid.json"))
        try JSONSerialization.data(withJSONObject: ["sessionId": y, "status": "busy"]).write(to: home.root.appendingPathComponent("elsewhere.json"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("503.json"),
                                                   withDestinationURL: home.root.appendingPathComponent("elsewhere.json"))
        XCTAssertEqual(mkfifo(directory.appendingPathComponent("504.json").path, 0o600), 0)

        let started = Date()
        let running = RunningSessions.read(home: home.home, isAlive: { _, _ in true })
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(running.openCliSessionIds, [x])
    }

    func testNoRegistryMeansNothingIsRunning() throws {
        let home = try FakeHome()
        XCTAssertEqual(RunningSessions.read(home: home.home, isAlive: { _, _ in true }).entries, [])
    }

    func testReadingTheRegistryChangesNothing() throws {
        let home = try FakeHome()
        try home.writeRegistry(pid: 601, ["sessionId": x, "status": "busy"])
        let before = home.snapshot()
        _ = RunningSessions.read(home: home.home, isAlive: { _, _ in false })
        XCTAssertEqual(home.snapshot(), before)
    }

    // MARK: - Liveness

    /// `procStart` is `ps -o lstart=` under `LC_ALL=C TZ=UTC`, as the CLI records it.
    func testTheRecordedStartTimeIsParsedInUTC() {
        XCTAssertEqual(RunningSessions.startSeconds(fromProcStart: "Mon Oct  5 09:12:34 2026"), 1_791_191_554)
        XCTAssertEqual(RunningSessions.startSeconds(fromProcStart: "Thu Jan  1 00:00:00 1970"), 0)
        XCTAssertNil(RunningSessions.startSeconds(fromProcStart: "yesterday"))
        XCTAssertNil(RunningSessions.startSeconds(fromProcStart: "Mon Foo  5 09:12:34 2026"))
        XCTAssertNil(RunningSessions.startSeconds(fromProcStart: "Mon Feb 31 09:12:34 2026"))
    }

    /// Checked against this very test process, with its start time printed by `ps` exactly as
    /// the CLI asks for it.
    func testALiveProcessIsAliveOnlyWithItsOwnStartTime() throws {
        let pid = getpid()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(pid)]
        ps.environment = ["LC_ALL": "C", "TZ": "UTC"]
        let output = Pipe()
        ps.standardOutput = output
        try ps.run()
        ps.waitUntilExit()
        let procStart = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(RunningSessions.startSeconds(fromProcStart: procStart), procStart)

        XCTAssertTrue(RunningSessions.isProcessAlive(pid: pid, procStart: procStart))
        XCTAssertTrue(RunningSessions.isProcessAlive(pid: pid, procStart: nil))
        XCTAssertFalse(RunningSessions.isProcessAlive(pid: pid, procStart: "Mon Oct  5 09:12:34 2020"), "a reused pid")
        XCTAssertFalse(RunningSessions.isProcessAlive(pid: 0, procStart: nil))
        XCTAssertFalse(RunningSessions.isProcessAlive(pid: 99_999_999, procStart: nil))
    }
}

/// Collects values from `@Sendable` closures.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
