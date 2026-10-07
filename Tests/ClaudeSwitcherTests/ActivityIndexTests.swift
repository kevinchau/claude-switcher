import Darwin
import XCTest
@testable import ClaudeSwitcherCore

/// A temporary home with two signed-in profiles — Personal (account A, the default profile) and
/// Work (account B) — transcripts written the way Claude Code writes them, and the switcher's
/// index under the home's own `.config`. Nothing here reads or writes the real `~/.claude`.
final class ActivityFixture {
    let home: FakeHome
    let storeA: SessionStoreFolder
    let storeB: SessionStoreFolder
    let cwd = "/Users/me/secret-project"
    let now = UsageFixtures.pdt("2026-10-05 18:47")
    var options = ActivityIndex.Options()

    static let personal = Profile(id: "default", label: "Personal")
    static let work = Profile(id: "work", label: "Work", userDataDir: "~/Library/Application Support/Claude-work")
    var profiles: [Profile] { [Self.personal, Self.work] }
    var indexURL: URL { home.root.appendingPathComponent(".config/claude-switcher/activity-index.json") }

    init() throws {
        home = try FakeHome()
        storeA = try home.signIn(userDataDir: nil, account: FakeHome.accountA, org: FakeHome.orgA)
        storeB = try home.signIn(userDataDir: Self.work.userDataDir, account: FakeHome.accountB, org: FakeHome.orgB)
        options.workers = 2
    }

    /// A session record naming `cli` (and its earlier transcripts) in `store`.
    @discardableResult
    func record(_ cli: String, in store: SessionStoreFolder, earlier: [String] = [], title: String = "Secret plan") throws -> URL {
        let id = "local_" + UUID().uuidString.lowercased()
        return try home.writeRecord(["sessionId": id, "cliSessionId": cli, "cwd": cwd, "title": title,
                                     "priorCliSessionIds": earlier], in: store)
    }

    /// A main transcript, modified a minute before `now` unless said otherwise.
    @discardableResult
    func transcript(_ cli: String, _ lines: [String], tail: String = "", modified: Date? = nil) throws -> URL {
        let url = TranscriptLocator.transcriptURL(cwd: cwd, cliSessionId: cli, home: home.home)
        try write(url, lines, tail: tail, modified: modified)
        return url
    }

    /// A subagent's transcript under `<project>/<parent>/subagents/<path>`.
    @discardableResult
    func subagent(_ parent: String, _ path: String, _ lines: [String]) throws -> URL {
        let url = TranscriptLocator.transcriptURL(cwd: cwd, cliSessionId: parent, home: home.home)
            .deletingPathExtension().appendingPathComponent("subagents").appendingPathComponent(path)
        try write(url, lines, tail: "", modified: nil)
        return url
    }

    func write(_ url: URL, _ lines: [String], tail: String, modified: Date?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.map { $0 + "\n" }.joined() + tail).utf8).write(to: url)
        setModified(url, (modified ?? now.addingTimeInterval(-60)))
    }

    func setModified(_ url: URL, _ date: Date) {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        setModified(url, nanoseconds: Int64(seconds) * 1_000_000_000 + Int64((date.timeIntervalSince1970 - seconds) * 1e9))
    }

    func setModified(_ url: URL, nanoseconds: Int64) {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
    }

    /// `-1` when there is no such file.
    func modifiedNanoseconds(_ url: URL) -> Int64 { FileStatus.ofPath(url.path)?.modifiedNanoseconds ?? -1 }

    func refresh(at moment: Date? = nil, previous: ActivityIndexFile? = nil) -> ActivityIndex.Refresh {
        ActivityIndex.refresh(profiles: profiles, home: home.home, indexURL: indexURL, previous: previous,
                              now: moment ?? now, options: options)
    }

    // MARK: Lines, as Claude Code writes them

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    static func assistant(_ id: String, at: Date, model: String = "claude-opus-5-5", input: Int = 10_000, output: Int = 8,
                          cacheWrite: Int = 100_000, cacheWrite1h: Int = 40_000, cacheRead: Int = 0, sidechain: Bool = false,
                          text: String = "The secret plan is ready", session: String = "s") -> String {
        json([
            "parentUuid": UUID().uuidString, "isSidechain": sidechain, "userType": "external", "cwd": "/Users/me/secret-project",
            "sessionId": session, "version": "2.1.286", "type": "assistant", "requestId": "req_" + id,
            "uuid": UUID().uuidString, "timestamp": iso(at),
            "message": [
                "id": "msg_" + id, "type": "message", "role": "assistant", "model": model,
                "content": [["type": "text", "text": text]],
                "usage": ["input_tokens": input, "output_tokens": output, "cache_creation_input_tokens": cacheWrite,
                          "cache_read_input_tokens": cacheRead,
                          "cache_creation": ["ephemeral_5m_input_tokens": cacheWrite - cacheWrite1h, "ephemeral_1h_input_tokens": cacheWrite1h]],
            ],
        ])
    }

    static func rateLimit(at: Date, type: String, resetsAt: Double) -> String {
        json([
            "type": "assistant", "isApiErrorMessage": true, "error": "rate_limit", "timestamp": iso(at), "uuid": UUID().uuidString,
            "message": ["id": UUID().uuidString, "model": "<synthetic>", "role": "assistant",
                        "content": [["type": "text", "text": "You've hit your limit · resets 9pm"]],
                        "usage": ["input_tokens": 0, "output_tokens": 0]],
            "quotaLimits": ["status": "rejected", "resetsAt": resetsAt, "rateLimitType": type, "overageStatus": "rejected",
                            "isUsingOverage": false],
        ])
    }

    static func prompt(at: Date, text: String) -> String {
        json(["type": "user", "timestamp": iso(at), "uuid": UUID().uuidString, "sessionId": "s",
              "message": ["role": "user", "content": text]])
    }

    static func toolResult(at: Date) -> String {
        json(["type": "user", "timestamp": iso(at), "uuid": UUID().uuidString,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]]],
              "toolUseResult": ["stdout": "ok"]])
    }

    /// The weighted spend of the default line above for Opus 5.5 with `output` output tokens:
    /// 4·10 000 + 5·60 000 + 8·40 000 + 20·output per million.
    static func opusSpend(output: Int = 8, input: Int = 10_000) -> Double {
        (4.0 * Double(input) + 5 * 60_000 + 8 * 40_000 + 20 * Double(output)) / 1_000_000
    }
}

final class ActivityIndexTests: XCTestCase {

    private typealias A = ActivityFixture
    private let x = "c1c1c1c1-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let y = "c2c2c2c2-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let z = "c3c3c3c3-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private func pdt(_ text: String) -> Date { UsageFixtures.pdt(text) }

    private func total(_ ledger: ActivityLedger?) -> Double { ledger?.buckets.reduce(0) { $0 + $1.spend } ?? -1 }

    // MARK: - Counting calls

    /// One API message is written once per content block, and a copy of the transcript in the
    /// other account repeats it: it counts once, in the transcript that recorded it first.
    func testDuplicateUsageLinesCountOnce() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.record(y, in: f.storeB)
        let m1 = A.assistant("m1", at: pdt("2026-10-05 10:00:05"))
        let m1second = A.assistant("m1", at: pdt("2026-10-05 10:00:09"), text: "tool use block")
        try f.transcript(x, [A.prompt(at: pdt("2026-10-05 10:00"), text: "go"), m1, m1second])
        // The copy, made later: the same lines, then its own reply.
        try f.transcript(y, [A.prompt(at: pdt("2026-10-05 10:00"), text: "go"), m1, m1second,
                             A.assistant("m2", at: pdt("2026-10-05 11:00"), output: 500)])
        let result = f.refresh()
        XCTAssertEqual(total(result.ledgers["default"]), A.opusSpend(), accuracy: 1e-12)
        XCTAssertEqual(result.ledgers["default"]?.buckets.first?.calls, 1)
        XCTAssertEqual(total(result.ledgers["work"]), A.opusSpend(output: 500), accuracy: 1e-12)
    }

    /// A subagent's lines keep the usage from the start of the stream; its output is taken as
    /// the per-model constant (Opus 5.5 880, Fable 5.1 1 500).
    func testSubagentOutputIsFilledIn() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.transcript(x, [A.prompt(at: pdt("2026-10-05 10:00"), text: "run the workflow")])
        try f.subagent(x, "agent-a1.jsonl", [A.assistant("s1", at: pdt("2026-10-05 10:01"), output: 8),
                                             A.assistant("s2", at: pdt("2026-10-05 10:02"), model: "claude-fable-5-1", output: 3)])
        let ledger = try XCTUnwrap(f.refresh().ledgers["default"])
        // One term per line: a single sum of eight literals took Swift 6.1's type checker
        // past its limit on GitHub's runner.
        let fableInput: Double = 10.0 * 10_000
        let fableOutput: Double = 12.5 * 60_000
        let fableCacheWrite: Double = 20.0 * 40_000
        let fableFilledIn: Double = 50.0 * 1_500
        let fableTokens: Double = fableInput + fableOutput + fableCacheWrite + fableFilledIn
        let fable: Double = fableTokens / 1_000_000
        XCTAssertEqual(total(ledger), A.opusSpend(output: 880) + fable, accuracy: 1e-12)
        XCTAssertEqual(ledger.buckets.first?.subagentCalls, 2)
        XCTAssertEqual(ledger.buckets.first?.subagentSpend ?? 0, total(ledger), accuracy: 1e-12)

        // A subagent line inside a main transcript (`isSidechain`) is filled in only when it
        // carries start-of-stream output (≤ 50 tokens).
        let g = try A()
        try g.record(x, in: g.storeA)
        try g.transcript(x, [A.assistant("t1", at: pdt("2026-10-05 10:01"), output: 12, sidechain: true),
                             A.assistant("t2", at: pdt("2026-10-05 10:02"), output: 300, sidechain: true)])
        XCTAssertEqual(total(g.refresh().ledgers["default"]), A.opusSpend(output: 880) + A.opusSpend(output: 300), accuracy: 1e-12)
    }

    func testMainThreadOutputIsNotFilledIn() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"), output: 8)])
        let ledger = try XCTUnwrap(f.refresh().ledgers["default"])
        XCTAssertEqual(total(ledger), A.opusSpend(output: 8), accuracy: 1e-12)
        XCTAssertEqual(ledger.buckets.first?.subagentCalls, 0)
    }

    func testCacheReadsAreExcludedFromSpend() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"), cacheRead: 0),
                             A.assistant("m2", at: pdt("2026-10-05 10:02"), cacheRead: 5_000_000)])
        XCTAssertEqual(total(f.refresh().ledgers["default"]), 2 * A.opusSpend(), accuracy: 1e-12)
    }

    func testUnknownModelIsWeightedAsOpusAndCounted() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"), model: "claude-novel-9"),
                             A.assistant("m2", at: pdt("2026-10-05 10:02"), model: "claude-opus-5-5-20260901")])
        let ledger = try XCTUnwrap(f.refresh().ledgers["default"])
        XCTAssertEqual(total(ledger), 2 * A.opusSpend(), accuracy: 1e-12)
        XCTAssertEqual(ledger.unpricedCalls, 1, "a dated id of a known model is priced")
        XCTAssertEqual(ActivityWeights.price(for: "claude-opus-5").price.input, 5, "not taken for Opus 5.5")
        XCTAssertEqual(ActivityWeights.fillInOutput(for: "claude-opus-5"), 1500)
    }

    // MARK: - Attribution

    func testUnmappedTranscriptIsUnattributed() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        try f.transcript(z, [A.assistant("m9", at: pdt("2026-10-05 10:05"), output: 100)])   // a terminal session
        let result = f.refresh()
        XCTAssertEqual(total(result.ledgers["default"]), A.opusSpend(), accuracy: 1e-12)
        XCTAssertEqual(total(result.ledgers["work"]), 0)
        XCTAssertEqual(result.ledgers["default"]?.unattributedSpend ?? 0, A.opusSpend(output: 100), accuracy: 1e-12)
        XCTAssertNil(result.ledgers["default"]?.sessions[z])
        XCTAssertEqual(result.summary.unattributedShare, A.opusSpend(output: 100) / (A.opusSpend() + A.opusSpend(output: 100)), accuracy: 1e-12)
        XCTAssertEqual(result.summary.transcripts, 2)
        XCTAssertEqual(result.summary.accounts, 1)
    }

    func testSubagentFolderBelongsToParentSession() throws {
        let f = try A()
        try f.record(x, in: f.storeB)
        try f.transcript(x, [A.prompt(at: pdt("2026-10-05 10:00"), text: "start")])
        try f.subagent(x, "workflows/run-1/agent-b2.jsonl", [A.assistant("s1", at: pdt("2026-10-05 10:01"), output: 900)])
        let ledger = try XCTUnwrap(f.refresh().ledgers["work"])
        XCTAssertEqual(total(ledger), A.opusSpend(output: 900), accuracy: 1e-12)
        XCTAssertEqual(Array(ledger.sessions.keys), [x])
        XCTAssertEqual(ledger.episodes().first?.subagentShare, 1)
        XCTAssertEqual(ledger.episodes().first?.prompts, 1)
    }

    /// A session cleared or rewound has had several transcripts; its record names the earlier
    /// ones, and they were spent on the same account.
    func testEarlierCliSessionIdsAttribute() throws {
        let f = try A()
        try f.record(y, in: f.storeA, earlier: [x])
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 09:01"))])
        try f.transcript(y, [A.assistant("m2", at: pdt("2026-10-05 10:01"))])
        let ledger = try XCTUnwrap(f.refresh().ledgers["default"])
        XCTAssertEqual(total(ledger), 2 * A.opusSpend(), accuracy: 1e-12)
        XCTAssertEqual(ledger.unattributedSpend, 0)
    }

    /// A deleted record does not move spend that happened: the index remembers the account.
    func testDeletedRecordKeepsItsAccount() throws {
        let f = try A()
        let record = try f.record(x, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        let first = f.refresh()
        try FileManager.default.removeItem(at: record)
        let second = f.refresh(previous: first.file)
        XCTAssertEqual(total(second.ledgers["default"]), A.opusSpend(), accuracy: 1e-12)
        XCTAssertEqual(second.ledgers["default"]?.unattributedSpend, 0)
    }

    // MARK: - Limit hits

    func testQuotaLimitsKindsAreNamed() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        let hit = pdt("2026-10-01 09:05")
        let saturday = pdt("2026-10-03 21:00").timeIntervalSince1970
        try f.transcript(x, [
            A.rateLimit(at: hit, type: "seven_day", resetsAt: saturday - 0.284),
            A.rateLimit(at: hit.addingTimeInterval(120), type: "seven_day", resetsAt: saturday + 0.597),   // the same hit, retried
            A.rateLimit(at: hit, type: "five_hour", resetsAt: pdt("2026-10-01 12:10").timeIntervalSince1970),
            A.rateLimit(at: hit, type: "seven_day_overage_included", resetsAt: saturday),
            A.rateLimit(at: hit, type: "seven_day_opus", resetsAt: saturday),
            A.rateLimit(at: hit, type: "seven_day_cowork", resetsAt: saturday),
        ])
        let anchors = try XCTUnwrap(f.refresh().ledgers["default"]?.anchors)
        XCTAssertEqual(Set(anchors.map(\.kind)), [.fiveHour, .sevenDay, .fable, .model("opus"), .other("seven_day_cowork")])
        let weekly = try XCTUnwrap(anchors.first { $0.kind == .sevenDay })
        XCTAssertEqual(anchors.filter { $0.kind == .sevenDay }.count, 1, "one per reset, at its first hit")
        XCTAssertEqual(weekly.resetsAt, pdt("2026-10-03 21:00"))
        XCTAssertEqual(weekly.hitAt, hit)
        XCTAssertEqual(LimitKind.fable.label, "Fable limit")
        XCTAssertEqual(LimitKind(rateLimitType: "seven_day_sonnet"), .model("sonnet"))
        XCTAssertEqual(LimitKind(rateLimitType: LimitKind.fable.rateLimitType), .fable, "the index round-trips the kind")
        XCTAssertEqual(total(f.refresh().ledgers["default"]), 0, "a synthetic error line is no call")
    }

    // MARK: - Copies and limit hits

    /// A session copied to Work after Personal hit its weekly limit repeats the rate-limit line
    /// verbatim. The hit is Personal's — the earliest-born file's — as a repeated call is: Work's
    /// ledger has none of it, so Work's week is neither full nor timed by Personal's schedule,
    /// and the Advisor still offers Work. Read in the other order — the copy first, its original
    /// only when the index reaches back — the original takes the hit back.
    func testCopiedTranscriptDoesNotCarryTheSourcesLimitHits() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.record(y, in: f.storeB)
        let saturday = pdt("2026-10-10 21:00")
        let lines = [A.assistant("m1", at: pdt("2026-10-05 09:59")),
                     A.rateLimit(at: pdt("2026-10-05 10:00"), type: "seven_day", resetsAt: saturday.timeIntervalSince1970)]
        try f.transcript(x, lines)
        usleep(10_000)
        try f.transcript(y, lines + [A.assistant("m2", at: pdt("2026-10-05 12:00"))])
        let refresh = f.refresh()
        let personal = try XCTUnwrap(refresh.ledgers["default"]), work = try XCTUnwrap(refresh.ledgers["work"])
        XCTAssertEqual(personal.anchors.map(\.kind), [.sevenDay])
        XCTAssertEqual(work.anchors, [], "the copy's repeat of Personal's hit")

        // Both last recorded at 09:00, before the hit: Personal's week is full; Work's is its own.
        func forecast(_ id: String, _ ledger: ActivityLedger, sd: Int) -> UsageForecast {
            UsageForecast.make(profileID: id, samples: [UsageSample(sampledAt: pdt("2026-10-05 09:00"), org: id, utilization: ["fh": 10, "sd": sd])],
                               activity: ledger, exact: nil, busySessions: [], costs: .defaults, now: f.now)
        }
        let full = forecast("default", personal, sd: 90)
        XCTAssertEqual(full.weekUsed.low, 100)
        let own = forecast("work", work, sd: 41)
        XCTAssertNil(own.schedule, "no reset of Work's own seen yet")
        XCTAssertEqual(own.weekUsed.low, 41)
        XCTAssertFalse(ForecastText.line(own, indexState: .ready(indexedThrough: f.now), clock: AdvisorFixtures.clock(f.now)).contains("limit"))
        for size in SessionSize.allCases {
            XCTAssertEqual(UsageAdvisor.advise(size: size, forecasts: ["default": full, "work": own], costs: .defaults, order: ["default", "work"],
                                               previous: nil, now: f.now).profileID, "work", "\(size)")
        }

        // The copy read first.
        let g = try A()
        try g.record(x, in: g.storeA)
        try g.record(y, in: g.storeB)
        let old = g.now.addingTimeInterval(-20 * 86400)
        let hit = A.rateLimit(at: old, type: "seven_day", resetsAt: old.addingTimeInterval(3 * 86400).timeIntervalSince1970)
        try g.transcript(x, [hit], modified: old)
        usleep(10_000)
        try g.transcript(y, [hit, A.assistant("m3", at: g.now.addingTimeInterval(-3600))])
        let first = g.refresh()
        XCTAssertEqual(first.ledgers["work"]?.anchors.count, 1, "the original is not read yet")
        let second = g.refresh(previous: first.file)
        XCTAssertEqual(second.ledgers["default"]?.anchors.count, 1, "the original's hit")
        XCTAssertEqual(second.ledgers["work"]?.anchors, [])
        XCTAssertEqual(second.ledgers["work"]?.buckets.reduce(0) { $0 + $1.calls }, 1, "the copy keeps its own call")
        XCTAssertEqual(ActivityIndex.read(from: g.indexURL), second.file)
    }

    /// The same for a five-hour hit: Personal's window is full until 8:47 PM; Work's, in the
    /// copy, is not.
    func testCopiedTranscriptDoesNotCarryTheSourcesFiveHourHit() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.record(y, in: f.storeB)
        let hitAt = f.now.addingTimeInterval(-20 * 60)
        let lines = [A.assistant("m1", at: hitAt.addingTimeInterval(-60)),
                     A.rateLimit(at: hitAt, type: "five_hour", resetsAt: f.now.addingTimeInterval(2 * 3600).timeIntervalSince1970)]
        try f.transcript(x, lines)
        usleep(10_000)
        try f.transcript(y, lines)
        let refresh = f.refresh()
        let work = try XCTUnwrap(refresh.ledgers["work"])
        XCTAssertEqual(work.anchors, [])
        func forecast(_ id: String, _ ledger: ActivityLedger?) -> UsageForecast {
            UsageForecast.make(profileID: id, samples: [UsageSample(sampledAt: f.now.addingTimeInterval(-30 * 60), org: id, utilization: ["fh": 10, "sd": 41])],
                               activity: ledger, exact: nil, busySessions: [], costs: .defaults, now: f.now)
        }
        let clock = AdvisorFixtures.clock(f.now)
        let personal = forecast("default", refresh.ledgers["default"])
        XCTAssertEqual(ForecastText.line(personal, indexState: .ready(indexedThrough: f.now), clock: clock), "5h window full \u{2014} clears 8:47 PM")
        let own = forecast("work", work)
        XCTAssertLessThan(own.windowUsed.value, 100)
        XCTAssertFalse(own.windowExact)
        XCTAssertFalse(ForecastText.line(own, indexState: .ready(indexedThrough: f.now), clock: clock).contains("5h"))
    }

    // MARK: - The index's own folder

    /// What an interrupted write left beside the index — and only that — is removed: a regular
    /// file named as the write names its temporary file, more than a minute old. Not a write in
    /// progress, the index, the updater's temporaries, a folder or a link of that name.
    func testSweepRemovesOnlyOurTemporaryFiles() throws {
        let home = try FakeHome()
        let folder = home.root.appendingPathComponent(".config/claude-switcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func path(_ name: String) -> String { folder.appendingPathComponent(name).path }
        func ours() -> String { ".\(ActivityIndex.fileName).\(UUID().uuidString).tmp" }
        func age(_ name: String) {
            let old = Int(Date().timeIntervalSince1970) - 300
            var times = [timespec(tv_sec: old, tv_nsec: 0), timespec(tv_sec: old, tv_nsec: 0)]
            XCTAssertEqual(utimensat(AT_FDCWD, path(name), &times, AT_SYMLINK_NOFOLLOW), 0, name)
        }
        let leftover = ours(), inProgress = ours(), folderNamed = ours(), linkNamed = ours()
        let others = [ActivityIndex.fileName, ".state.json.\(UUID().uuidString).tmp", ".\(ActivityIndex.fileName).not-a-uuid.tmp",
                      ".\(ActivityIndex.fileName).\(UUID().uuidString.lowercased()).tmp", "activity-index.json.\(UUID().uuidString).tmp"]
        for name in [leftover, inProgress] + others {
            XCTAssertTrue(FileManager.default.createFile(atPath: path(name), contents: Data("{}".utf8)), name)
        }
        try FileManager.default.createDirectory(atPath: path(folderNamed), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: path(linkNamed), withDestinationPath: path(leftover))
        for name in [leftover, folderNamed, linkNamed] + others { age(name) }

        XCTAssertEqual(ActivityIndex.sweepTemporaryFiles(in: folder), 1)
        XCTAssertNil(FileStatus.ofPath(path(leftover)), "the interrupted write's file")
        for name in [inProgress, folderNamed, linkNamed] + others { XCTAssertNotNil(FileStatus.ofPath(path(name)), name) }
        XCTAssertEqual(FileStatus.ofPath(path(linkNamed))?.kind, .symbolicLink)
        XCTAssertEqual(ActivityIndex.sweepTemporaryFiles(in: folder.appendingPathComponent("missing")), 0)
    }

    // MARK: - Incremental

    /// An unchanged transcript is not read again; one that grew is read from where the last
    /// read stopped.
    func testIndexIsIncrementalByIdentityAndOffset() throws {
        let f = try A()
        f.options.firstBuildDays = 45   // the whole retention at once, so the coverage does not move
        try f.record(x, in: f.storeA)
        // The tool result last: the next read checks the last line it read is still there
        // (an in-place rewrite of that line is read afresh — testInPlaceRewriteThatGrowsIsReReadFromZero),
        // so the change below is made to a line before it.
        let url = try f.transcript(x, [A.prompt(at: pdt("2026-10-05 10:00"), text: "go"),
                                       A.assistant("m1", at: pdt("2026-10-05 10:01"), input: 10_000),
                                       A.toolResult(at: pdt("2026-10-05 10:02"))])
        let first = f.refresh()
        XCTAssertEqual(total(first.ledgers["default"]), A.opusSpend(), accuracy: 1e-12)
        XCTAssertNil(first.writeError)
        // Prompts have no call id to deduplicate on: a second read of the same bytes would show.
        func prompts(_ refresh: ActivityIndex.Refresh) -> Int { refresh.ledgers["default"]?.buckets.reduce(0) { $0 + $1.prompts } ?? -1 }
        XCTAssertEqual(prompts(first), 1)

        // Rewrite the first line in place to other numbers of the same width, and put the
        // modification time back: same identity, size and time — so it must not be read.
        let stamp = f.modifiedNanoseconds(url)
        let original = try String(contentsOf: url, encoding: .utf8)
        try Data(original.replacingOccurrences(of: "\"input_tokens\":10000", with: "\"input_tokens\":90000").utf8).write(to: url)
        f.setModified(url, nanoseconds: stamp)
        let indexStamp = f.modifiedNanoseconds(f.indexURL)
        let second = f.refresh(at: f.now.addingTimeInterval(60), previous: first.file)
        XCTAssertEqual(total(second.ledgers["default"]), A.opusSpend(), accuracy: 1e-12, "not re-read")
        XCTAssertEqual(prompts(second), 1)
        XCTAssertEqual(f.modifiedNanoseconds(f.indexURL), indexStamp, "nothing changed, nothing written")

        // Append a reply: only the new bytes are read (the in-place change above stays unseen).
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((A.prompt(at: pdt("2026-10-05 10:29"), text: "more") + "\n"
                                           + A.assistant("m2", at: pdt("2026-10-05 10:30"), output: 400) + "\n").utf8))
        try handle.close()
        let third = f.refresh(at: f.now.addingTimeInterval(120), previous: second.file)
        XCTAssertEqual(total(third.ledgers["default"]), A.opusSpend() + A.opusSpend(output: 400), accuracy: 1e-12)
        XCTAssertEqual(prompts(third), 2, "the first prompt was not read twice")
        let entry = try XCTUnwrap(third.file.entries.first)
        XCTAssertEqual(entry.bytesRead, Int64(try Data(contentsOf: url).count))

        // The same from disk, as the next launch would read it.
        XCTAssertEqual(ActivityIndex.read(from: f.indexURL), third.file)
    }

    func testTruncatedFileIsReReadFromZero() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        let url = try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01")), A.assistant("m2", at: pdt("2026-10-05 10:02"))])
        let first = f.refresh()
        XCTAssertEqual(total(first.ledgers["default"]), 2 * A.opusSpend(), accuracy: 1e-12)
        let inode = try XCTUnwrap(FileStatus.ofPath(url.path)?.inode)

        // Rewritten shorter, in place (same file): what it held before is forgotten.
        try Data((A.assistant("m3", at: pdt("2026-10-05 10:05"), output: 50) + "\n").utf8).write(to: url)
        XCTAssertEqual(FileStatus.ofPath(url.path)?.inode, inode)
        let second = f.refresh(previous: first.file)
        XCTAssertEqual(total(second.ledgers["default"]), A.opusSpend(output: 50), accuracy: 1e-12)

        // Replaced by another file under the same name: read afresh as well. m3 came back with
        // it and counts once.
        let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.tmp")
        try Data((A.assistant("m3", at: pdt("2026-10-05 10:05"), output: 50) + "\n" + A.assistant("m4", at: pdt("2026-10-05 10:06")) + "\n").utf8)
            .write(to: replacement)
        XCTAssertEqual(rename(replacement.path, url.path), 0)
        let third = f.refresh(previous: second.file)
        XCTAssertEqual(total(third.ledgers["default"]), A.opusSpend(output: 50) + A.opusSpend(), accuracy: 1e-12)
    }

    /// Rewritten in place, same file, larger: a line inserted before the old end. Reading on from
    /// the old offset would lose it; the last line read is no longer where it was, so the file
    /// is read again from the start.
    func testInPlaceRewriteThatGrowsIsReReadFromZero() throws {
        let f = try A()
        f.options.firstBuildDays = 45
        try f.record(x, in: f.storeA)
        let url = try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        let first = f.refresh()
        XCTAssertEqual(total(first.ledgers["default"]), A.opusSpend(), accuracy: 1e-12)
        let inode = FileStatus.ofPath(url.path)?.inode
        let rewritten = [A.assistant("m0", at: pdt("2026-10-05 09:59"), output: 5000), A.assistant("m1", at: pdt("2026-10-05 10:01")),
                         A.assistant("m2", at: pdt("2026-10-05 10:03"))].map { $0 + "\n" }.joined()
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewritten.utf8))
        try handle.close()
        XCTAssertEqual(FileStatus.ofPath(url.path)?.inode, inode, "the same file")
        let second = f.refresh(previous: first.file)
        XCTAssertEqual(total(second.ledgers["default"]), A.opusSpend(output: 5000) + 2 * A.opusSpend(), accuracy: 1e-12, "m0, m1 and m2, m1 once")
        XCTAssertEqual(second.ledgers["default"]?.buckets.reduce(0) { $0 + $1.calls }, 3)
        // Appended to normally, it is read on from where it stopped: nothing counted twice.
        let more = try FileHandle(forWritingTo: url)
        try more.seekToEnd()
        try more.write(contentsOf: Data((A.assistant("m3", at: pdt("2026-10-05 10:05")) + "\n").utf8))
        try more.close()
        let third = f.refresh(previous: second.file)
        XCTAssertEqual(total(third.ledgers["default"]), A.opusSpend(output: 5000) + 3 * A.opusSpend(), accuracy: 1e-12)
    }

    /// Smaller than when last read but not below the offset — a torn last line cut shorter, the
    /// lines before rewritten: rewritten, read afresh. The last complete line is unchanged here,
    /// so only the size says so.
    func testShrinkAboveBytesReadIsReReadFromZero() throws {
        let f = try A()
        f.options.firstBuildDays = 45
        try f.record(x, in: f.storeA)
        let torn = String(A.assistant("m9", at: pdt("2026-10-05 10:09")).prefix(120))
        let url = try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"), input: 10_000),
                                       A.assistant("m2", at: pdt("2026-10-05 10:02"), input: 20_000)],
                                   tail: torn)
        let first = f.refresh()
        XCTAssertEqual(total(first.ledgers["default"]), A.opusSpend() + A.opusSpend(input: 20_000), accuracy: 1e-12)
        let entry = try XCTUnwrap(first.file.entries.first)
        XCTAssertLessThan(entry.bytesRead, entry.size, "the torn line is not read")
        let original = try String(contentsOf: url, encoding: .utf8)
        let shorter = original.replacingOccurrences(of: "\"input_tokens\":10000", with: "\"input_tokens\":90000").dropLast(60)
        try Data(shorter.utf8).write(to: url)
        let status = try XCTUnwrap(FileStatus.ofPath(url.path))
        XCTAssertEqual(status.inode, entry.inode)
        XCTAssertLessThan(status.size, entry.size)
        XCTAssertGreaterThanOrEqual(status.size, entry.bytesRead)
        let second = f.refresh(previous: first.file)
        XCTAssertEqual(total(second.ledgers["default"]), A.opusSpend(input: 90_000) + A.opusSpend(input: 20_000), accuracy: 1e-12,
                       "the rewritten m1; m2, the last line read, is as it was")
    }

    /// A "Copy to <account>" made today of a session last written 20 days ago: the first build
    /// (14 days) reads only the copy, which records the shared calls; when the index reaches
    /// back to the original, the original — born first — takes them back, and the copy keeps
    /// only its own.
    func testOlderOriginalReclaimsItsCallsFromACopyReadEarlier() throws {
        let f = try A()
        try f.record(x, in: f.storeA)      // the original, account A
        try f.record(y, in: f.storeB)      // the copy, account B
        let old = f.now.addingTimeInterval(-20 * 86400)
        let lines = [A.assistant("m1", at: old), A.assistant("m2", at: old.addingTimeInterval(60))]
        try f.transcript(x, lines, modified: old)
        usleep(10_000)
        try f.transcript(y, lines + [A.assistant("m3", at: f.now.addingTimeInterval(-3600))])
        let first = f.refresh()
        func calls(_ refresh: ActivityIndex.Refresh, _ profile: String) -> Int { refresh.ledgers[profile]?.buckets.reduce(0) { $0 + $1.calls } ?? -1 }
        XCTAssertEqual(calls(first, "default"), 0, "the original is not read yet")
        XCTAssertEqual(calls(first, "work"), 3)
        var refresh = f.refresh(previous: first.file)
        XCTAssertEqual(calls(refresh, "default"), 2, "the original's calls")
        XCTAssertEqual(calls(refresh, "work"), 1, "the copy's own")
        XCTAssertEqual(total(refresh.ledgers["default"]), 2 * A.opusSpend(), accuracy: 1e-12)
        XCTAssertEqual(total(refresh.ledgers["work"]), A.opusSpend(), accuracy: 1e-12)
        for _ in 0..<6 { refresh = f.refresh(previous: refresh.file) }
        XCTAssertEqual(calls(refresh, "default"), 2, "and it stays so")
        XCTAssertEqual(calls(refresh, "work"), 1)
        XCTAssertEqual(ActivityIndex.read(from: f.indexURL), refresh.file)
    }

    /// The key an entry is stored under is made from the path below the project folder only:
    /// the same transcript under two project folders has the same key, and no stored key is a
    /// hash of a path through the folder (which would let anyone confirm a guessed folder).
    func testIndexKeyDoesNotDependOnTheProjectFolder() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        let url = try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        let other = TranscriptLocator.transcriptURL(cwd: "/Users/me/another-project", cliSessionId: x, home: f.home.home)
        let projects = TranscriptLocator.projectsDirectory(home: f.home.home).path
        let file = f.refresh().file
        let stored = Set(file.entries.map(\.pathHash))
        XCTAssertEqual(stored, [ActivityIndex.pathKey(x + ".jsonl")])
        let slug = url.deletingLastPathComponent().lastPathComponent
        XCTAssertFalse(stored.contains(TranscriptReading.key(slug + "/" + x + ".jsonl", "")), "no hash through the project folder")
        try f.write(other, [A.assistant("m1", at: pdt("2026-10-05 10:01"))], tail: "", modified: nil)
        let listed = ActivityIndex.listTranscripts(under: projects)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(Set(listed.map(\.pathHash)).count, 1, "one key for both folders")
        XCTAssertNotEqual(listed[0].relativePath, listed[1].relativePath)
    }

    /// One session id under two project folders (a session moved, a copy into another folder):
    /// two files, one key — told apart by identity, two entries, each read incrementally.
    func testSameSessionIdUnderTwoProjectsKeepsTwoEntries() throws {
        let f = try A()
        f.options.firstBuildDays = 45
        try f.record(x, in: f.storeA)
        let here = try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        let there = TranscriptLocator.transcriptURL(cwd: "/Users/me/another-project", cliSessionId: x, home: f.home.home)
        try f.write(there, [A.assistant("m2", at: pdt("2026-10-05 11:01"), output: 300)], tail: "", modified: nil)
        let first = f.refresh()
        XCTAssertEqual(first.file.entries.count, 2)
        XCTAssertEqual(total(first.ledgers["default"]), A.opusSpend() + A.opusSpend(output: 300), accuracy: 1e-12)
        // Each grows; each is read on from its own offset.
        for (url, id) in [(here, "m3"), (there, "m4")] {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((A.assistant(id, at: pdt("2026-10-05 12:01")) + "\n").utf8))
            try handle.close()
        }
        let second = f.refresh(previous: first.file)
        XCTAssertEqual(second.file.entries.count, 2)
        XCTAssertEqual(total(second.ledgers["default"]), 3 * A.opusSpend() + A.opusSpend(output: 300), accuracy: 1e-12)
        let third = f.refresh(previous: second.file)
        XCTAssertEqual(third.file, { var file = second.file; file.updatedAt = third.file.updatedAt; return file }(), "nothing read twice")
    }

    /// The plan tier `~/.claude.json` names for the signed-in account is remembered per account:
    /// the first one seen is no change; a different one later is, dated; another account's
    /// sign-in leaves it as it was.
    func testIndexRemembersEachAccountsTierAndWhenItChanged() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        func signIn(_ account: String, tier: String) throws {
            try JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": account, "organizationRateLimitTier": tier]])
                .write(to: f.home.root.appendingPathComponent(".claude.json"))
        }
        try signIn(FakeHome.accountA, tier: "default_claude_max_20x")
        let first = f.refresh()
        XCTAssertEqual(first.ledgers["default"]?.tier, "default_claude_max_20x")
        XCTAssertNil(first.ledgers["default"]?.tierChangedAt, "the first tier seen is no change")
        XCTAssertNil(first.ledgers["work"]?.tier)

        try signIn(FakeHome.accountA, tier: "claude_pro")
        let later = f.now.addingTimeInterval(3600)
        let second = f.refresh(at: later, previous: first.file)
        XCTAssertEqual(second.ledgers["default"]?.tier, "claude_pro")
        XCTAssertEqual(second.ledgers["default"]?.tierChangedAt, later)
        XCTAssertEqual(ActivityIndex.read(from: f.indexURL), second.file, "written")

        try signIn(FakeHome.accountB, tier: "default_claude_max_20x")
        let third = f.refresh(at: later.addingTimeInterval(3600), previous: second.file)
        XCTAssertEqual(third.ledgers["default"]?.tier, "claude_pro", "remembered while the CLI is signed in elsewhere")
        XCTAssertEqual(third.ledgers["default"]?.tierChangedAt, later)
        XCTAssertEqual(third.ledgers["work"]?.tier, "default_claude_max_20x")
        XCTAssertNil(third.ledgers["work"]?.tierChangedAt)
        // An account no profile has is not recorded.
        try signIn("cccccccc-1111-4111-8111-111111111111", tier: "claude_pro")
        XCTAssertEqual(f.refresh(at: later.addingTimeInterval(7200), previous: third.file).file.tiers.count, 2)
    }

    /// `--dry-run` uses the index as it is: no transcript is read, nothing is written.
    func testStoredIndexIsReadWithoutScanning() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        XCTAssertNil(ActivityIndex.stored(profiles: f.profiles, home: f.home.home, indexURL: f.indexURL, now: f.now))
        let url = try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        let built = f.refresh()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((A.assistant("m2", at: pdt("2026-10-05 10:30")) + "\n").utf8))
        try handle.close()
        let before = f.home.snapshot()
        let stored = try XCTUnwrap(ActivityIndex.stored(profiles: f.profiles, home: f.home.home, indexURL: f.indexURL, now: f.now))
        XCTAssertEqual(stored.ledgers, built.ledgers, "the new line is not read")
        XCTAssertEqual(f.home.snapshot(), before)
    }

    func testCorruptIndexIsRebuilt() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        let fresh = f.refresh()
        for garbage in [Data("not json".utf8), Data(#"{"version": 99}"#.utf8), Data()] {
            try garbage.write(to: f.indexURL)
            XCTAssertNil(ActivityIndex.read(from: f.indexURL))
            let rebuilt = f.refresh()
            XCTAssertEqual(rebuilt.ledgers, fresh.ledgers)
            XCTAssertEqual(ActivityIndex.read(from: f.indexURL), rebuilt.file, "written back whole")
        }
    }

    /// A torn last line — Claude still writing it — is left for the next refresh.
    func testTornLastLineWaitsForItsEnd() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        let whole = A.assistant("m2", at: pdt("2026-10-05 10:02"), output: 70)
        let cut = whole.index(whole.startIndex, offsetBy: whole.count / 2)
        let url = try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))], tail: String(whole[..<cut]))
        let first = f.refresh()
        XCTAssertEqual(total(first.ledgers["default"]), A.opusSpend(), accuracy: 1e-12)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(whole[cut...]) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(total(f.refresh(previous: first.file).ledgers["default"]), A.opusSpend() + A.opusSpend(output: 70), accuracy: 1e-12)
    }

    /// The first build reads the last 14 days; each refresh reaches 7 days further, to 45.
    func testFirstBuildCoversFourteenDaysThenReachesBack() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.record(y, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: f.now.addingTimeInterval(-20 * 86400))], modified: f.now.addingTimeInterval(-20 * 86400))
        try f.transcript(y, [A.assistant("m2", at: f.now.addingTimeInterval(-3 * 86400))], modified: f.now.addingTimeInterval(-3 * 86400))
        let first = f.refresh()
        XCTAssertEqual(total(first.ledgers["default"]), A.opusSpend(), accuracy: 1e-12)
        XCTAssertEqual(first.file.coveredSince, f.now.addingTimeInterval(-14 * 86400))
        let second = f.refresh(previous: first.file)
        XCTAssertEqual(total(second.ledgers["default"]), 2 * A.opusSpend(), accuracy: 1e-12)
        XCTAssertEqual(second.file.coveredSince, f.now.addingTimeInterval(-21 * 86400))
        var file = second.file
        for _ in 0..<6 { file = f.refresh(previous: file).file }
        XCTAssertEqual(file.coveredSince, f.now.addingTimeInterval(-45 * 86400), "never past 45 days")

        // Complete: later refreshes find nothing to do, so nothing is written but, once more than
        // ten minutes have passed, the time; and a transcript older than the retention is never
        // read (it would only be dropped again).
        try f.transcript(z, [A.assistant("m0", at: f.now.addingTimeInterval(-50 * 86400))], modified: f.now.addingTimeInterval(-50 * 86400))
        let stamp = f.modifiedNanoseconds(f.indexURL)
        let soon = f.refresh(at: f.now.addingTimeInterval(300), previous: file)
        XCTAssertEqual(soon.file.entries.count, 2)
        XCTAssertEqual(f.modifiedNanoseconds(f.indexURL), stamp, "five minutes later nothing is written")
        let later = f.refresh(at: f.now.addingTimeInterval(3600), previous: soon.file)
        XCTAssertEqual(later.file.coveredSince, file.coveredSince, "it does not creep forward with the clock")
        XCTAssertEqual(later.file.entries.count, 2)
        var timeOnly = file
        timeOnly.updatedAt = f.now.addingTimeInterval(3600)
        XCTAssertEqual(later.file, timeOnly, "only the time changed")
        XCTAssertEqual(ActivityIndex.read(from: f.indexURL), later.file, "and an hour on, it is written")
    }

    /// A refresh that changes nothing but the time rewrites the index once the time has moved
    /// more than ten minutes, so a stored index says when it was last brought up to date
    /// (`--dry-run` judges its age by it).
    func testNoChangeRefreshAnHourLaterRewritesUpdatedAt() throws {
        let f = try A()
        f.options.firstBuildDays = 45
        try f.record(x, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        let first = f.refresh()
        let stamp = f.modifiedNanoseconds(f.indexURL)
        let tenMinutes = f.refresh(at: f.now.addingTimeInterval(600), previous: first.file)
        XCTAssertEqual(f.modifiedNanoseconds(f.indexURL), stamp, "ten minutes is not more than ten minutes")
        XCTAssertEqual(ActivityIndex.read(from: f.indexURL)?.updatedAt, f.now)
        let hour = f.refresh(at: f.now.addingTimeInterval(3600), previous: tenMinutes.file)
        XCTAssertNil(hour.writeError)
        XCTAssertEqual(ActivityIndex.read(from: f.indexURL)?.updatedAt, f.now.addingTimeInterval(3600))
        let stored = try XCTUnwrap(ActivityIndex.stored(profiles: f.profiles, home: f.home.home, indexURL: f.indexURL, now: f.now.addingTimeInterval(3700)))
        XCTAssertEqual(stored.summary.indexedThrough, f.now.addingTimeInterval(3600), "the last check, not the last change")
        XCTAssertEqual(stored.ledgers["default"]?.indexedThrough, f.now.addingTimeInterval(3600))
    }

    // MARK: - Privacy and side effects

    func testIndexHoldsNoText() throws {
        let f = try A()
        try f.record(x, in: f.storeA, title: "Secret plan for jane.doe@example.com")
        try f.transcript(x, [
            A.prompt(at: pdt("2026-10-05 10:00"), text: "Email jane.doe@example.com about the secret plan"),
            A.assistant("m1", at: pdt("2026-10-05 10:01"), text: "The secret plan is ready, jane.doe@example.com"),
            A.toolResult(at: pdt("2026-10-05 10:02")),
            A.rateLimit(at: pdt("2026-10-05 10:03"), type: "five_hour", resetsAt: pdt("2026-10-05 12:10").timeIntervalSince1970),
        ])
        try f.subagent(x, "agent-a1.jsonl", [A.assistant("s1", at: pdt("2026-10-05 10:04"), text: "secret subagent text")])
        // The CLI's config holds the signed-in user's e-mail and name beside the tier; only the tier is kept.
        try JSONSerialization.data(withJSONObject: ["oauthAccount": [
            "accountUuid": FakeHome.accountA, "organizationRateLimitTier": "default_claude_max_20x",
            "emailAddress": "jane.doe@example.com", "displayName": "Jane Secret", "organizationName": "Secret Plan Inc"]])
            .write(to: f.home.root.appendingPathComponent(".claude.json"))
        let refreshed = f.refresh()
        XCTAssertEqual(refreshed.ledgers["default"]?.tier, "default_claude_max_20x")
        let text = try String(contentsOf: f.indexURL, encoding: .utf8)
        XCTAssertFalse(text.isEmpty)
        for word in ["secret", "Secret", "jane", "Jane", "example", "plan", "Plan", "Email", "Users", "/me", "subagents", "agent-a1"] {
            XCTAssertFalse(text.contains(word), "the index holds \"\(word)\"")
        }
        let email = try NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
        XCTAssertEqual(email.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), 0)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        var keys = Set<String>()
        func collect(_ value: Any) {
            if let object = value as? [String: Any] { for (key, child) in object { keys.insert(key); collect(child) } }
            if let array = value as? [Any] { array.forEach(collect) }
        }
        collect(root)
        let modelKeys = keys.filter { $0.hasPrefix("claude-") }
        XCTAssertEqual(keys.subtracting(modelKeys).subtracting(["version", "updatedAt", "coveredSince", "entries", "owners", "tiers",
            "tier", "since", "s", "sub", "ph", "dev", "ino", "size", "mt", "bt", "read", "th", "tl", "b", "a", "k", "u", "i", "f", "l", "c",
            "sc", "p", "w", "ws", "m", "r", "h", x, FakeHome.accountA.lowercased()]),
            [], "only numbers, ids and model ids")
    }

    /// The index is the one file written, in the switcher's own folder, private; nothing under
    /// `~/.claude` or Application Support changes.
    func testOnlyTheSwitchersOwnIndexIsWritten() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.transcript(x, [A.assistant("m1", at: pdt("2026-10-05 10:01"))])
        try f.subagent(x, "agent-a1.jsonl", [A.assistant("s1", at: pdt("2026-10-05 10:04"))])
        let before = f.home.snapshot()
        _ = f.refresh()
        let after = f.home.snapshot()
        let changes = after.changes(since: before)
        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertTrue(changes.changed.isEmpty, "\(changes.changed)")
        XCTAssertEqual(changes.added, [".config", ".config/claude-switcher", ".config/claude-switcher/activity-index.json"])
        XCTAssertEqual(after.entry(".config/claude-switcher/activity-index.json")?.mode, 0o600)
        XCTAssertEqual(after.entry(".config/claude-switcher")?.mode, 0o700)
    }

    func testPromptsAndEpisodesComeFromTheTranscripts() throws {
        let f = try A()
        try f.record(x, in: f.storeA)
        try f.transcript(x, [
            A.prompt(at: pdt("2026-10-05 10:00"), text: "first"),
            A.assistant("m1", at: pdt("2026-10-05 10:01")),
            A.toolResult(at: A.dateAfter(pdt("2026-10-05 10:01"))),
            A.prompt(at: pdt("2026-10-05 10:20"), text: "second"),
            A.assistant("m2", at: pdt("2026-10-05 10:21")),
            A.prompt(at: pdt("2026-10-05 13:00"), text: "much later"),
            A.assistant("m3", at: pdt("2026-10-05 13:02")),
        ])
        let ledger = try XCTUnwrap(f.refresh().ledgers["default"])
        let episodes = ledger.episodes()
        guard episodes.count == 2 else { return XCTFail("\(episodes.count) episodes, not 2") }
        XCTAssertEqual(episodes.map(\.prompts), [2, 1], "tool results are not prompts")
        XCTAssertEqual(episodes[0].start, pdt("2026-10-05 10:00"))
        XCTAssertEqual(episodes[0].end, pdt("2026-10-05 10:21"))
        XCTAssertEqual(episodes[0].spend, 2 * A.opusSpend(), accuracy: 1e-12)
        XCTAssertEqual(ledger.indexedThrough, f.now)
    }

    func testTimestampsParseWithoutAFormatter() {
        XCTAssertEqual(TranscriptReading.parseTimestamp("2026-10-05T12:34:56.789Z") ?? 0,
                       pdt("2026-10-05 05:34:56.789").timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(TranscriptReading.parseTimestamp("2026-10-05T12:34:56Z"), pdt("2026-10-05 05:34:56").timeIntervalSince1970)
        XCTAssertEqual(TranscriptReading.parseTimestamp("2026-10-05T14:34:56+02:00"), pdt("2026-10-05 05:34:56").timeIntervalSince1970,
                       "an offset goes through the formatter")
        XCTAssertNil(TranscriptReading.parseTimestamp("yesterday"))
    }
}

extension ActivityFixture {
    static func dateAfter(_ date: Date) -> Date { date.addingTimeInterval(5) }
}
