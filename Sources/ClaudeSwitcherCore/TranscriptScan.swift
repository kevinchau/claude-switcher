import Foundation

/// What a transcript carries that must not follow a copy into another account, and what the
/// copy must add so it does not.
///
/// A transcript is more than the conversation. Claude Code also keeps per-session state in it
/// — last line wins, keyed by each line's `sessionId` — and restores that state when the
/// session is resumed by id. A verbatim copy resumed in another account would inherit:
///
/// - **Remote Control** (`bridge-session`): a live pointer makes the other account's Claude
///   reattach to — or, on an owner mismatch, permanently hide the history of — the original's
///   Remote Control session. Desktop's own fork appends one clearing line per live pointer;
///   this does the same, byte for byte.
/// - **A git worktree** (`worktree-state`): the copy would re-enter the original's worktree,
///   and either side could remove it with the other's uncommitted work. Refused.
/// - **An artifact comment monitor** (`artifact-comment-monitor`): the copy would watch and
///   answer the same artifact's comments under a second identity. Refused.
///
/// Every line is parsed — not only those Desktop's substring prefilter would pass — and a line
/// that does not parse but mentions one of those three types refuses the copy: whatever it
/// says cannot be checked. Pure functions over bytes; the caller cuts the snapshot after its
/// last line feed first.
enum TranscriptScan {

    static let lineFeed: UInt8 = 0x0A

    /// The row types Desktop's subagent scan accepts (`ve` in its transcript chunk).
    static let rowTypes: Set<String> = [
        "user", "assistant", "system", "result", "stream_event", "tool_use_summary",
        "tool_progress", "auth_status", "prompt_suggestion", "rate_limit_event",
    ]

    /// The three line types whose state is restored on resume and that this scan acts on.
    static let markerWords = ["bridge-session", "worktree-state", "artifact-comment-monitor"].map { Data($0.utf8) }

    struct Result: Equatable, Sendable {
        /// Session ids whose LAST `bridge-session` line has a live pointer, in the order each
        /// first appeared among valid bridge lines (JavaScript `Map` order, as Desktop's `Uy`).
        var liveBridgeSessionIds: [String] = []
        /// A live pointer under a session id that is not `[A-Za-z0-9_-]+`: no clearing line
        /// can be written for it the way Claude writes one.
        var hasUnclearableBridge = false
        /// Session ids whose last `worktree-state` line binds a worktree.
        var worktreeBoundSessionIds: [String] = []
        /// How many (session id, artifact) monitors were last seen in any state but `stopped`.
        var activeArtifactMonitors = 0
        /// A line that does not parse as a JSON object and contains a marker word.
        var hasUnreadableMarkerLine = false
        /// `toolUseResult.agentId` of qualifying rows, first-seen order, each `[A-Za-z0-9_-]+`.
        var referencedAgentIds: [String] = []

        /// The lines to append so no copied Remote Control pointer is live.
        var clearBytes: Data { TranscriptScan.clearLines(for: liveBridgeSessionIds) }

        /// Why this transcript cannot be copied, if anything it carries forbids it.
        var refusal: SessionCopy.Refusal? {
            if hasUnreadableMarkerLine { return .unreadableTranscriptLine }
            if hasUnclearableBridge { return .remoteControlUnclearable }
            if !worktreeBoundSessionIds.isEmpty { return .inWorktree }
            if activeArtifactMonitors > 0 { return .watchingArtifactComments }
            return nil
        }
    }

    /// The length of the part of `data` that ends in a line feed — everything after the last
    /// LF is a line still being written. `nil` when there is no complete line.
    static func completeLength(of data: Data) -> Int? {
        guard let last = data.lastIndex(of: lineFeed) else { return nil }
        return data.distance(from: data.startIndex, to: last) + 1
    }

    /// Scans the complete lines of `prefix`. An unterminated tail is ignored: it is not part of
    /// what a copy takes.
    static func scan(_ prefix: Data) -> Result {
        var result = Result()
        var bridge = OrderedLastValues<String, Bool>()
        var unclearable: [String: Bool] = [:]
        var worktree = OrderedLastValues<String, Bool>()
        var monitors: [MonitorKey: Bool] = [:]
        var agents = Set<String>()

        forEachLine(in: prefix) { line in
            autoreleasepool {
                guard let object = parseObject(line) else {
                    if markerWords.contains(where: { line.range(of: $0) != nil }) { result.hasUnreadableMarkerLine = true }
                    return
                }
                let type = object["type"] as? String

                switch type {
                case "bridge-session":
                    // Desktop `zy`: a string sessionId of [A-Za-z0-9_-]+, value `!!bridgeSessionId`.
                    guard let sessionId = object["sessionId"] as? String else { return }
                    let live = jsTruthy(object["bridgeSessionId"])
                    if isIdChars(sessionId) {
                        bridge.set(sessionId, live)
                    } else if !sessionId.isEmpty {
                        unclearable[sessionId] = live
                    }
                case "worktree-state":
                    // CLI loader: `gt.set(wn.sessionId, wn.worktreeSession)` for a truthy sessionId.
                    guard let key = sessionKey(object["sessionId"]) else { return }
                    let session = object["worktreeSession"]
                    worktree.set(key, session != nil && !(session is NSNull))
                case "artifact-comment-monitor":
                    guard let key = sessionKey(object["sessionId"]),
                          let artifacts = object["artifacts"] as? [String: Any]
                    else { return }
                    for (slug, entry) in artifacts {
                        let state = (entry as? [String: Any])?["state"] as? String
                        monitors[MonitorKey(session: key, artifact: slug)] = state != "stopped"
                    }
                default:
                    break
                }

                // Desktop `ve`: an accepted row type, not a compact summary or transcript-only
                // row, with `toolUseResult.agentId` of [A-Za-z0-9_-]+. The id becomes a file
                // name, so the character check is what keeps `../..` out of the path.
                if let type, rowTypes.contains(type),
                   !jsTruthy(object["isCompactSummary"]), !jsTruthy(object["isVisibleInTranscriptOnly"]),
                   let toolUseResult = object["toolUseResult"] as? [String: Any],
                   let agentId = toolUseResult["agentId"] as? String, isIdChars(agentId),
                   agents.insert(agentId).inserted {
                    result.referencedAgentIds.append(agentId)
                }
            }
        }

        result.liveBridgeSessionIds = bridge.keys.filter { bridge[$0] == true }
        result.hasUnclearableBridge = unclearable.values.contains(true)
        result.worktreeBoundSessionIds = worktree.keys.filter { worktree[$0] == true }
        result.activeArtifactMonitors = monitors.values.filter { $0 }.count
        return result
    }

    /// One clearing line per session id, exactly as Desktop's `Ry` and the CLI's own
    /// `clearBridgeSession` write it: no spaces, keys in this order, `lastSequenceNum` the number
    /// 0, each line ending in one LF. Raw bytes — `JSONSerialization` does not promise key order.
    static func clearLines(for sessionIds: [String], after prefix: Data = Data()) -> Data {
        guard !sessionIds.isEmpty else { return Data() }
        var text = (prefix.isEmpty || prefix.last == lineFeed) ? "" : "\n"
        for sessionId in sessionIds {
            precondition(isIdChars(sessionId), "a clearing line is only ever written for a checked id")
            text += "{\"type\":\"bridge-session\",\"sessionId\":\"\(sessionId)\",\"bridgeSessionId\":\"\",\"lastSequenceNum\":0}\n"
        }
        return Data(text.utf8)
    }

    // MARK: - JavaScript, faithfully

    /// `/^[A-Za-z0-9_-]+$/` without the `m` flag. Not an ICU regex: there `$` also matches
    /// before a trailing newline, so `"abc\n"` would pass.
    static func isIdChars(_ string: String) -> Bool {
        !string.isEmpty && string.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 95, 45: return true
            default: return false
            }
        }
    }

    /// `!!value`.
    static func jsTruthy(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let text as String: return !text.isEmpty
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            let double = number.doubleValue
            return double != 0 && !double.isNaN
        default: return true
        }
    }

    /// The loader keys this state by any truthy `sessionId`; a string is the only kind that can
    /// ever match a message's session id, but the others are kept apart rather than dropped.
    private static func sessionKey(_ value: Any?) -> String? {
        guard jsTruthy(value) else { return nil }
        if let text = value as? String { return "s:" + text }
        return "x:" + String(describing: value!)
    }

    /// The line as a JSON object, or `nil` (not JSON, or JSON that is not an object).
    static func parseObject(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// Each LF-terminated line, without its LF. A trailing unterminated piece is skipped.
    static func forEachLine(in data: Data, _ body: (Data) -> Void) {
        var start = data.startIndex
        while start < data.endIndex, let end = data[start...].firstIndex(of: lineFeed) {
            body(data[start..<end])
            start = data.index(after: end)
        }
    }

    private struct MonitorKey: Hashable {
        let session: String
        let artifact: String
    }
}

/// A JavaScript `Map` used as "last value wins, first insertion keeps its place".
struct OrderedLastValues<Key: Hashable, Value> {
    private(set) var keys: [Key] = []
    private var values: [Key: Value] = [:]

    mutating func set(_ key: Key, _ value: Value) {
        if values.updateValue(value, forKey: key) == nil { keys.append(key) }
    }

    subscript(key: Key) -> Value? { values[key] }
}
