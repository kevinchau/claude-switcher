import XCTest
@testable import ClaudeSwitcherCore

/// The scan of a transcript snapshot: Remote Control pointers to clear, state that refuses a
/// copy, and the subagent transcripts it references. Pure: bytes in, facts out.
final class TranscriptScanTests: XCTestCase {

    private func bytes(_ lines: [String]) -> Data { Data(lines.map { $0 + "\n" }.joined().utf8) }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func bridge(_ sessionId: String, _ pointer: Any) -> String {
        json(["type": "bridge-session", "sessionId": sessionId, "bridgeSessionId": pointer, "lastSequenceNum": 3])
    }

    private func clear(_ sessionId: String) -> String {
        "{\"type\":\"bridge-session\",\"sessionId\":\"\(sessionId)\",\"bridgeSessionId\":\"\",\"lastSequenceNum\":0}\n"
    }

    // MARK: - The cut

    func testOnlyCompleteLinesArePartOfASnapshot() {
        XCTAssertEqual(TranscriptScan.completeLength(of: Data("a\nb".utf8)), 2)
        XCTAssertEqual(TranscriptScan.completeLength(of: Data("a\nb\n".utf8)), 4)
        XCTAssertNil(TranscriptScan.completeLength(of: Data("{\"type\":\"user\"}".utf8)))
        XCTAssertNil(TranscriptScan.completeLength(of: Data()))
        let slice = Data("xx\nyy\nzz".utf8).dropFirst(3)
        XCTAssertEqual(TranscriptScan.completeLength(of: slice), 3)
    }

    // MARK: - Remote Control pointers

    /// One clear per session id whose LAST bridge line is live, in the order each id first
    /// appeared, byte for byte what Desktop and the CLI write.
    func testEachSessionWhoseLastPointerIsLiveGetsExactlyOneClearInFirstSeenOrder() {
        let scan = TranscriptScan.scan(bytes([
            bridge("s1", "cse_1"),
            bridge("s2", "cse_2"),
            json(["type": "user", "sessionId": "s1", "message": ["content": "hi"]]),
            bridge("s1", ""),              // cleared…
            bridge("s3", "cse_3"),
            bridge("s1", "cse_4"),         // …and live again: keeps its first place
            bridge("s4", "cse_5"),
            bridge("s4", NSNull()),        // last line wins
        ]))
        XCTAssertEqual(scan.liveBridgeSessionIds, ["s1", "s2", "s3"])
        XCTAssertEqual(scan.clearBytes, Data((clear("s1") + clear("s2") + clear("s3")).utf8))
        XCTAssertNil(scan.refusal)
    }

    func testNothingIsAppendedWhenEveryPointerIsAlreadyCleared() {
        let scan = TranscriptScan.scan(bytes([bridge("s1", "cse_1"), String(clear("s1").dropLast())]))
        XCTAssertEqual(scan.liveBridgeSessionIds, [])
        XCTAssertEqual(scan.clearBytes, Data())
    }

    /// `!!bridgeSessionId`, as JavaScript decides it.
    func testAPointerIsLiveByJavaScriptTruthiness() {
        for (value, live) in [("x" as Any, true), (1, true), (true, true), ([String: Any](), true), ([Any](), true),
                              ("", false), (0, false), (false, false), (NSNull(), false)] {
            let scan = TranscriptScan.scan(bytes([bridge("s1", value)]))
            XCTAssertEqual(scan.liveBridgeSessionIds, live ? ["s1"] : [], "\(value)")
        }
        let missing = TranscriptScan.scan(bytes([json(["type": "bridge-session", "sessionId": "s1"])]))
        XCTAssertEqual(missing.liveBridgeSessionIds, [])
    }

    /// An id with a trailing newline (which an ICU `$` would accept) or any character outside
    /// `[A-Za-z0-9_-]` is not matched — and a live pointer under one refuses the copy.
    func testASessionIdOutsideTheIdCharacterSetIsNotMatched() {
        for bad in ["s4\n", "s 5", "s/6", "caf\u{e9}", "a.b", "s7\r"] {
            let scan = TranscriptScan.scan(bytes([bridge(bad, "cse_x"), bridge("ok_1-A", "cse_y")]))
            XCTAssertEqual(scan.liveBridgeSessionIds, ["ok_1-A"], bad)
            XCTAssertEqual(scan.clearBytes, Data(clear("ok_1-A").utf8), bad)
            XCTAssertEqual(scan.refusal, .remoteControlUnclearable, bad)

            let cleared = TranscriptScan.scan(bytes([bridge(bad, "cse_x"), bridge(bad, "")]))
            XCTAssertNil(cleared.refusal, bad)
        }
        XCTAssertFalse(TranscriptScan.isIdChars(""))
        XCTAssertTrue(TranscriptScan.isIdChars("0-_aZ"))
    }

    /// Every line is parsed: a bridge line in another key order — which Desktop's substring
    /// prefilter would miss but the CLI's loader would restore — is cleared too.
    func testABridgeLineInAnyKeyOrderIsSeen() {
        let line = "{\"sessionId\":\"s9\",\"bridgeSessionId\":\"cse_9\",\"type\":\"bridge-session\"}"
        XCTAssertEqual(TranscriptScan.scan(bytes([line])).liveBridgeSessionIds, ["s9"])
        let spaced = "{\"type\": \"bridge-session\", \"sessionId\": \"s8\", \"bridgeSessionId\": \"cse_8\"}"
        XCTAssertEqual(TranscriptScan.scan(bytes([spaced])).liveBridgeSessionIds, ["s8"])
    }

    /// Only a top-level bridge line counts; one quoted inside a message does not.
    func testABridgeObjectInsideAnotherRowIsNotABridgeLine() {
        let nested = json(["type": "user", "message": ["type": "bridge-session", "sessionId": "s1", "bridgeSessionId": "cse"]])
        let scan = TranscriptScan.scan(bytes([nested]))
        XCTAssertEqual(scan.liveBridgeSessionIds, [])
        XCTAssertNil(scan.refusal)
    }

    func testAClearAfterATornTailStartsOnItsOwnLine() {
        XCTAssertEqual(TranscriptScan.clearLines(for: ["s1"], after: Data("{\"a\":1}".utf8)), Data(("\n" + clear("s1")).utf8))
        XCTAssertEqual(TranscriptScan.clearLines(for: ["s1"], after: Data("{\"a\":1}\n".utf8)), Data(clear("s1").utf8))
        XCTAssertEqual(TranscriptScan.clearLines(for: [], after: Data("x".utf8)), Data())
    }

    /// The unterminated tail is not part of the copy, so nothing in it is acted on.
    func testAnUnterminatedTailIsIgnored() {
        var data = bytes([bridge("s1", "cse_1")])
        data.append(Data(bridge("s2", "cse_2").utf8))
        XCTAssertEqual(TranscriptScan.scan(data).liveBridgeSessionIds, ["s1"])
    }

    // MARK: - State that refuses a copy

    func testAWorktreeBindingRefusesUntilALaterLineClearsIt() {
        let bound = json(["type": "worktree-state", "sessionId": "s1",
                          "worktreeSession": ["worktreePath": "/r/.claude/worktrees/x", "worktreeBranch": "b"]])
        let cleared = json(["type": "worktree-state", "sessionId": "s1", "worktreeSession": NSNull()])
        XCTAssertEqual(TranscriptScan.scan(bytes([bound])).refusal, .inWorktree)
        XCTAssertNil(TranscriptScan.scan(bytes([bound, cleared])).refusal)
        XCTAssertEqual(TranscriptScan.scan(bytes([cleared, bound])).refusal, .inWorktree)
        // Per session id: clearing one does not clear another.
        let other = json(["type": "worktree-state", "sessionId": "s2", "worktreeSession": ["worktreePath": "/w"]])
        XCTAssertEqual(TranscriptScan.scan(bytes([other, bound, cleared])).refusal, .inWorktree)
        // No key at all is "undefined": nothing to restore.
        XCTAssertNil(TranscriptScan.scan(bytes([json(["type": "worktree-state", "sessionId": "s1"])])).refusal)
        // The CLI ignores a line without a session id.
        XCTAssertNil(TranscriptScan.scan(bytes([json(["type": "worktree-state", "worktreeSession": ["worktreePath": "/w"]])])).refusal)
    }

    func testAnArtifactCommentMonitorRefusesUnlessItsLastStateIsStopped() {
        func monitor(_ artifacts: [String: Any], session: String = "s1") -> String {
            json(["type": "artifact-comment-monitor", "v": 1, "sessionId": session, "artifacts": artifacts])
        }
        let armed = monitor(["deck": ["state": "armed", "writtenAtMs": 1]])
        let stopped = monitor(["deck": ["state": "stopped", "writtenAtMs": 2]])
        XCTAssertEqual(TranscriptScan.scan(bytes([armed])).refusal, .watchingArtifactComments)
        XCTAssertNil(TranscriptScan.scan(bytes([armed, stopped])).refusal)
        XCTAssertEqual(TranscriptScan.scan(bytes([stopped, armed])).refusal, .watchingArtifactComments)
        // Per (session, artifact).
        XCTAssertEqual(TranscriptScan.scan(bytes([monitor(["page": ["state": "armed"]]), stopped])).refusal,
                       .watchingArtifactComments)
        XCTAssertEqual(TranscriptScan.scan(bytes([armed, monitor(["deck": ["state": "stopped"]], session: "s2")])).refusal,
                       .watchingArtifactComments)
        // Anything but "stopped" — an unknown state, no state, not an object — is not proof of rest.
        XCTAssertEqual(TranscriptScan.scan(bytes([monitor(["deck": ["state": "paused"]])])).refusal, .watchingArtifactComments)
        XCTAssertEqual(TranscriptScan.scan(bytes([monitor(["deck": [String: Any]()])])).refusal, .watchingArtifactComments)
        XCTAssertEqual(TranscriptScan.scan(bytes([monitor(["deck": "armed"])])).refusal, .watchingArtifactComments)
    }

    /// A line that cannot be read, but names a type whose state follows a copy, refuses: what
    /// it says cannot be checked.
    func testAnUnreadableLineNamingRestoredStateRefuses() {
        for marker in ["bridge-session", "worktree-state", "artifact-comment-monitor"] {
            let torn = "{\"type\":\"\(marker)\",\"sessionId\":\"s1\",\"bridgeSess"
            let scan = TranscriptScan.scan(bytes([json(["type": "user"]), torn]))
            XCTAssertTrue(scan.hasUnreadableMarkerLine, marker)
            XCTAssertEqual(scan.refusal, .unreadableTranscriptLine, marker)
            // A JSON value that is not an object counts as unreadable too.
            XCTAssertEqual(TranscriptScan.scan(bytes(["\"\(marker)\""])).refusal, .unreadableTranscriptLine, marker)
        }
        // Unreadable lines without a marker, and readable lines that merely mention one, are fine.
        XCTAssertNil(TranscriptScan.scan(bytes(["{\"type\":\"user\",\"mess", ""])).refusal)
        XCTAssertNil(TranscriptScan.scan(bytes([json(["type": "user", "message": ["content": "what is a bridge-session?"]])])).refusal)
    }

    // MARK: - Referenced subagents

    private func row(_ type: String, agentId: Any?, extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": type, "uuid": UUID().uuidString]
        if let agentId { object["toolUseResult"] = ["agentId": agentId, "status": "completed"] }
        for (key, value) in extra { object[key] = value }
        return json(object)
    }

    /// Ids come only from `toolUseResult.agentId` on Desktop's accepted row types, first-seen
    /// order, once each.
    func testReferencedSubagentsAreTakenAsDesktopTakesThem() {
        let scan = TranscriptScan.scan(bytes([
            row("user", agentId: "a1"),
            row("assistant", agentId: "a2"),
            row("user", agentId: "a1"),
            row("attachment", agentId: "a3"),                                     // not an accepted type
            row("user", agentId: "a4", extra: ["isCompactSummary": true]),
            row("user", agentId: "a5", extra: ["isVisibleInTranscriptOnly": true]),
            row("user", agentId: "a6", extra: ["isCompactSummary": false]),
            row("user", agentId: 7),                                              // not a string
            json(["type": "user", "toolUseResult": "agentId a8"]),
            json(["type": "user", "agentId": "a9"]),                              // not inside toolUseResult
            row("system", agentId: "a_10-X"),
        ]))
        XCTAssertEqual(scan.referencedAgentIds, ["a1", "a2", "a6", "a_10-X"])
    }

    /// An agent id becomes a file name: anything that could walk out of the subagents folder
    /// is never taken.
    func testAnAgentIdThatCouldNameAnotherPathIsNeverTaken() {
        let scan = TranscriptScan.scan(bytes(["../../x", "a/b", "..", ".", "", "a\nb", "a b", "x.jsonl"].map { row("user", agentId: $0) }))
        XCTAssertEqual(scan.referencedAgentIds, [])
    }

    func testTheRowTypesAreDesktopsTen() {
        XCTAssertEqual(TranscriptScan.rowTypes, ["user", "assistant", "system", "result", "stream_event", "tool_use_summary",
                                                 "tool_progress", "auth_status", "prompt_suggestion", "rate_limit_event"])
    }
}
