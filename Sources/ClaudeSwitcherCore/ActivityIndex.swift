import Darwin
import Foundation

// MARK: - Weighting

/// List prices per million tokens, from the Claude Code 2.1.286 model catalog. They are a
/// weighting of token counts, never shown as money (A4).
public struct ModelPrice: Equatable, Sendable {
    public let input: Double
    public let cacheWrite5m: Double
    public let cacheWrite1h: Double
    public let output: Double
}

/// How a call's tokens become weighted spend.
///
/// Assumed (A4): usage weight is proportional to input, output and cache-write tokens at list
/// prices, cache reads excluded — the metric that tracked both accounts' weekly figure best
/// (±2–5 points) on this Mac. Subagent and workflow lines keep the usage from the start of the
/// stream (a median of 8 output tokens), so their output is filled in with a per-model
/// constant measured from Claude Code's own session totals; a wrong constant is absorbed by
/// the calibration, which is proportional.
public enum ActivityWeights {

    struct Entry: Sendable {
        let model: String
        let price: ModelPrice
        let fillIn: Int
    }

    /// Longest id first, so `claude-opus-5-5` is never taken for `claude-opus-5`.
    static let table: [Entry] = [
        Entry(model: "claude-opus-5-5", price: ModelPrice(input: 4, cacheWrite5m: 5, cacheWrite1h: 8, output: 20), fillIn: 880),
        Entry(model: "claude-fable-5-1", price: ModelPrice(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, output: 50), fillIn: 1500),
        Entry(model: "claude-opus-4-8", price: ModelPrice(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, output: 25), fillIn: 1000),
        Entry(model: "claude-sonnet-5", price: ModelPrice(input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, output: 10), fillIn: 1000),
        Entry(model: "claude-fable-5", price: ModelPrice(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, output: 50), fillIn: 1000),
        Entry(model: "claude-opus-5", price: ModelPrice(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, output: 25), fillIn: 1500),
        Entry(model: "claude-haiku-4-5", price: ModelPrice(input: 1, cacheWrite5m: 1.25, cacheWrite1h: 2, output: 5), fillIn: 1000),
    ].sorted { $0.model.count > $1.model.count }

    /// An unknown model is weighted as Opus 5.5 and counted as unpriced.
    static let fallback = table.first { $0.model == "claude-opus-5-5" }!
    static let fallbackFillIn = 1000

    /// The table entry for a model id; a date or context suffix (`-20260901`, `[1m]`) is allowed.
    static func entry(for model: String) -> Entry? {
        let lowered = model.lowercased()
        return table.first { entry in
            guard lowered.hasPrefix(entry.model) else { return false }
            let rest = lowered.dropFirst(entry.model.count)
            return rest.isEmpty || rest.hasPrefix("-") || rest.hasPrefix("[")
        }
    }

    public static func price(for model: String) -> (price: ModelPrice, known: Bool) {
        if let entry = entry(for: model) { return (entry.price, true) }
        return (fallback.price, false)
    }

    /// Output tokens a subagent call is taken to have produced: Opus 5.5 880, Fable 5.1 1 500,
    /// Opus 5 1 500, anything else 1 000.
    public static func fillInOutput(for model: String) -> Int {
        entry(for: model)?.fillIn ?? fallbackFillIn
    }

    /// Lines whose output is at most this, on a subagent line of a main transcript, carry
    /// start-of-stream usage and are filled in.
    static let startOfStreamOutput = 50

    /// The weighted spend of one call.
    public static func spend(model: String, input: Int, cacheWrite5m: Int, cacheWrite1h: Int, output: Int) -> Double {
        let price = price(for: model).price
        return (price.input * Double(input) + price.cacheWrite5m * Double(cacheWrite5m)
                + price.cacheWrite1h * Double(cacheWrite1h) + price.output * Double(output)) / 1_000_000
    }
}

// MARK: - What a transcript line contributes

/// The numbers one transcript yields: API calls (deduplicated later, across files), the user's
/// prompts, and limit hits. Never text.
struct TranscriptReading {
    struct Call {
        /// FNV-1a of `message.id` and `requestId`: one API message is written once per content
        /// block, and copies or forks of a transcript repeat it.
        let key: UInt64
        let at: TimeInterval
        let model: String
        let input: Int
        let output: Int
        let cacheWrite5m: Int
        let cacheWrite1h: Int
        /// A subagent's line inside a main transcript.
        let isSidechain: Bool
    }

    var calls: [Call] = []
    var prompts: [TimeInterval] = []
    var anchors: [LimitAnchor] = []
    /// Bytes of complete lines read; a torn last line is left for next time.
    var consumed = 0
    /// FNV-1a of the last complete line read, its newline included, and its length: the next
    /// read checks the line is still there before it reads on (a file rewritten in place).
    var tailHash: UInt64 = 0
    var tailLength = 0

    // Prefilters, before any JSON is parsed (design §2.4): only these lines can matter.
    static let usageNeedle = Needle("\"usage\":{")
    static let quotaNeedle = Needle("\"quotaLimits\":{")
    static let userNeedle = Needle("\"type\":\"user\"")
    static let toolResultNeedle = Needle("\"tool_use_id\"")

    /// Reads the complete lines of `buffer`. `isSubagentFile`: the file is under a session's
    /// `subagents/` folder, whose user lines are the agent's instructions, not prompts.
    mutating func read(_ buffer: UnsafeRawBufferPointer, isSubagentFile: Bool) {
        guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let count = buffer.count
        var start = 0
        var lastLine: Range<Int>?
        while start < count, let found = memchr(base + start, 0x0A, count - start) {
            let end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
            let line = UnsafeBufferPointer(start: base + start, count: end - start)
            readLine(line, isSubagentFile: isSubagentFile)
            lastLine = start..<(end + 1)
            start = end + 1
        }
        consumed += start
        if let lastLine {
            tailHash = Self.hash(UnsafeBufferPointer(start: base + lastLine.lowerBound, count: lastLine.count))
            tailLength = lastLine.count
        }
    }

    /// FNV-1a over bytes.
    static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }

    private mutating func readLine(_ line: UnsafeBufferPointer<UInt8>, isSubagentFile: Bool) {
        let usage = Self.usageNeedle.occurs(in: line)
        let quota = !usage && Self.quotaNeedle.occurs(in: line)
        let prompt = !usage && !quota && !isSubagentFile
            && Self.userNeedle.occurs(in: line) && !Self.toolResultNeedle.occurs(in: line)
        guard usage || quota || prompt,
              let object = TranscriptScan.parseObject(Data(buffer: line)),
              let at = (object["timestamp"] as? String).flatMap(Self.parseTimestamp)
        else { return }

        switch object["type"] as? String {
        case "assistant":
            if (object["error"] as? String) == "rate_limit",
               let limits = object["quotaLimits"] as? [String: Any],
               (limits["status"] as? String).map({ $0 == "rejected" }) ?? true,
               let resetsAt = Self.number(limits["resetsAt"]), resetsAt > 0,
               let type = limits["rateLimitType"] as? String, !type.isEmpty {
                anchors.append(LimitAnchor(resetsAt: Date(timeIntervalSince1970: resetsAt), kind: LimitKind(rateLimitType: type),
                                           hitAt: Date(timeIntervalSince1970: at)))
            }
            guard let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>"
            else { return }
            let id = (message["id"] as? String) ?? (object["uuid"] as? String) ?? ""
            let request = (object["requestId"] as? String) ?? ""
            guard !id.isEmpty || !request.isEmpty else { return }
            let written = Self.integer(usage["cache_creation_input_tokens"])
            let split = usage["cache_creation"] as? [String: Any]
            let oneHour = min(written, Self.integer(split?["ephemeral_1h_input_tokens"]))
            calls.append(Call(
                key: Self.key(id, request), at: at, model: model,
                input: Self.integer(usage["input_tokens"]), output: Self.integer(usage["output_tokens"]),
                cacheWrite5m: written - oneHour, cacheWrite1h: oneHour,
                isSidechain: TranscriptScan.jsTruthy(object["isSidechain"])))
        case "user":
            guard !isSubagentFile, Self.isPrompt(object) else { return }
            prompts.append(at)
        default:
            return
        }
    }

    /// A line the user typed: not Claude's meta or summary lines, not a tool result, not a
    /// subagent's instructions.
    static func isPrompt(_ object: [String: Any]) -> Bool {
        for flag in ["isMeta", "isCompactSummary", "isSidechain", "isVisibleInTranscriptOnly"] where TranscriptScan.jsTruthy(object[flag]) {
            return false
        }
        guard object["toolUseResult"] == nil, let message = object["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        guard let blocks = message["content"] as? [Any], let first = blocks.first as? [String: Any] else { return false }
        return (first["type"] as? String) == "text"
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    static func integer(_ value: Any?) -> Int {
        guard let double = number(value), double > 0, double < 1e12 else { return 0 }
        return Int(double)
    }

    static func key(_ messageID: String, _ requestID: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in messageID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        hash = (hash ^ 0) &* 0x0000_0100_0000_01b3
        for byte in requestID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }

    /// A limit hit's key, beside the calls' in the same set: its kind, its reset and its hit,
    /// each to the minute. A copy of a transcript repeats the line verbatim, so the hit counts
    /// once — for the account that owns the earliest-born file, as a call does.
    static func key(_ anchor: LimitAnchor) -> UInt64 {
        func minute(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 / 60).rounded()) }
        return key("quotaLimits:" + anchor.kind.rateLimitType, "\(minute(anchor.resetsAt)):\(minute(anchor.hitAt))")
    }

    /// Every key this reading holds: its calls' and its limit hits'.
    var keys: [UInt64] { calls.map(\.key) + anchors.map(Self.key) }

    /// `2026-10-05T12:34:56.789Z` without a formatter (there are hundreds of thousands of
    /// them); anything else through `ISO8601DateFormatter`.
    static func parseTimestamp(_ text: String) -> TimeInterval? {
        var utf8 = text.utf8.makeIterator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        while let byte = utf8.next(), bytes.count < 40 { bytes.append(byte) }
        func digits(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= bytes.count else { return nil }
            var value = 0
            for index in from..<(from + count) {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        if bytes.count >= 20, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58,
           let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
           let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
           (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 {
            var index = 19
            var fraction = 0.0
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                var scale = 0.1
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                    fraction += Double(bytes[index] - 48) * scale
                    scale /= 10
                    index += 1
                }
            }
            if index == bytes.count - 1, bytes[index] == 90 {
                let days = daysFromCivil(year: year, month: month, day: day)
                return Double(days * 86400 + hour * 3600 + minute * 60 + second) + fraction
            }
        }
        return isoFallback(text)
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func isoFallback(_ text: String) -> TimeInterval? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)?.timeIntervalSince1970
    }
}

/// A Horspool search for a short byte string: the prefilter runs over every byte of every
/// transcript, so it must skip rather than compare.
struct Needle: Sendable {
    let bytes: [UInt8]
    let skip: [Int]

    init(_ text: String) {
        bytes = Array(text.utf8)
        var skip = [Int](repeating: bytes.count, count: 256)
        for index in 0..<(bytes.count - 1) { skip[Int(bytes[index])] = bytes.count - 1 - index }
        self.skip = skip
    }

    func occurs(in haystack: UnsafeBufferPointer<UInt8>) -> Bool {
        let length = bytes.count
        guard let base = haystack.baseAddress, haystack.count >= length else { return false }
        return bytes.withUnsafeBufferPointer { pattern in
            skip.withUnsafeBufferPointer { skip in
                let last = pattern[length - 1]
                var index = length - 1
                while index < haystack.count {
                    let byte = base[index]
                    if byte == last, memcmp(base + index - length + 1, pattern.baseAddress!, length - 1) == 0 { return true }
                    index += skip[Int(byte)]
                }
                return false
            }
        }
    }
}

// MARK: - Which account a transcript belongs to

/// Transcript id → account, through each profile's session records (A6).
///
/// Every Code session's record names its transcript (`cliSessionId`) and its earlier ones; a
/// record lives in the folder of the account the profile is signed in to, and Desktop runs the
/// session with that profile's own token. A subagent's transcript, under
/// `<project>/<cliSessionId>/subagents/`, belongs to its parent. Transcripts no record names —
/// terminal sessions, sessions whose record was deleted — are unattributed.
public struct ActivityAttribution: Equatable, Sendable {
    /// Profile id → its signed-in account (lowercased).
    public let accounts: [String: String]
    /// Lowercased transcript id → account. An id two accounts' records both claim is left out.
    public let claims: [String: String]

    public init(accounts: [String: String], claims: [String: String]) {
        self.accounts = accounts.mapValues { $0.lowercased() }
        self.claims = Dictionary(claims.map { ($0.key.lowercased(), $0.value.lowercased()) }, uniquingKeysWith: { $1 })
    }

    /// Reads every profile's records (the listing rule: the folder of the account Claude last
    /// recorded). Only reads.
    public static func read(profiles: [Profile], home: String) -> ActivityAttribution {
        var accounts: [String: String] = [:]
        var claims: [String: String] = [:]
        var contested = Set<String>()
        for profile in profiles {
            guard let folder = SessionStore.locate(userDataDir: profile.userDataDir, home: home).folder else { continue }
            let account = folder.accountID.lowercased()
            accounts[profile.id] = account
            for record in SessionStore.records(in: folder) {
                for id in record.claimedCliSessionIds.map({ $0.lowercased() }) {
                    if let other = claims[id], other != account { contested.insert(id) }
                    claims[id] = account
                }
            }
        }
        for id in contested { claims[id] = nil }
        return ActivityAttribution(accounts: accounts, claims: claims)
    }
}

// MARK: - The index file

/// Whether per-account activity can be used yet. While the first build runs, nothing is
/// estimated anywhere: the menu shows recorded values only.
public enum ActivityIndexState: Equatable, Sendable {
    case building
    case ready(indexedThrough: Date)
    /// The index was last brought up to date more than an hour ago (a stored index `--dry-run`
    /// reads as it is, a first render after a long sleep): spend since then is unknown, so it is
    /// treated as building — recorded values only, no advice — and says how old it is.
    case stale(indexedThrough: Date)
}

/// The switcher's own record of what it has read from the transcripts:
/// `~/.config/claude-switcher/activity-index.json`. Numbers and ids only — transcript ids,
/// model ids, plan tier ids, file identities, offsets, ten-minute sums, limit hits and hashed
/// call ids. No path, title, prompt or message text is ever stored, and the project folder name
/// is not stored in any form.
public struct ActivityIndexFile: Codable, Equatable, Sendable {
    /// 2: entries keyed below the project folder, with their birth time and last line; tiers.
    /// 3: limit hits keyed as calls are, so a copy's repeat of one counts once — an index of
    /// version 2 may hold such repeats in the copy's entry, and is rebuilt.
    static let currentVersion = 3

    var version: Int
    /// Every transcript had been read up to this moment.
    public internal(set) var updatedAt: Date
    /// Transcripts modified at or after this are indexed; earlier ones are not read yet.
    public internal(set) var coveredSince: Date
    var entries: [Entry]
    /// Sticky attribution: transcript id → account, as records last said. A session whose
    /// record is deleted keeps the account its spend was made on.
    var owners: [String: String]
    /// Account → the plan tier `~/.claude.json` last named for it, and when it replaced another
    /// (A5). The CLI names only the account it is signed in to; this remembers the rest.
    var tiers: [String: TierRecord]

    init(updatedAt: Date, coveredSince: Date, entries: [Entry] = [], owners: [String: String] = [:], tiers: [String: TierRecord] = [:]) {
        version = Self.currentVersion
        self.updatedAt = updatedAt
        self.coveredSince = coveredSince
        self.entries = entries
        self.owners = owners
        self.tiers = tiers
    }

    /// How many transcripts the index has read.
    public var transcriptCount: Int { entries.count }

    /// One account's plan tier.
    struct TierRecord: Codable, Equatable, Sendable {
        /// E.g. `default_claude_max_20x`.
        var tier: String
        /// When the index saw it replace a different tier; `nil` for the first one seen.
        var since: Date?
    }

    /// One transcript file.
    struct Entry: Codable, Equatable, Sendable {
        /// The session it belongs to (lowercased `cliSessionId`; a subagent file's parent).
        var sessionId: String
        var isSubagent: Bool
        /// FNV-1a of the path below the project folder — `<id>.jsonl`, `<id>/subagents/…` — so
        /// the project folder name is not stored in any form (a hash of it beside the session
        /// id would let anyone confirm a guessed folder). One session id under two project
        /// folders gives two entries with the same hash, told apart by file identity.
        var pathHash: UInt64
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modified: Int64
        /// Birth time (ns): the earliest-born copy of a call keeps it, across refreshes too.
        var born: Int64
        /// Read through here: the end of the last complete line.
        var bytesRead: Int64
        /// FNV-1a and length of the last complete line read, which must still be there for the
        /// next read to go on from ``bytesRead`` (a file rewritten in place is read afresh).
        var tailHash: UInt64 = 0
        var tailLength: Int64 = 0
        var buckets: [BucketRecord] = []
        var anchors: [AnchorRecord] = []
        /// The calls and limit hits this file was first to record.
        var keys: [UInt64] = []
        var unpricedCalls = 0

        private enum CodingKeys: String, CodingKey {
            case sessionId = "s", isSubagent = "sub", pathHash = "ph", device = "dev", inode = "ino", size, modified = "mt"
            case born = "bt", bytesRead = "read", tailHash = "th", tailLength = "tl"
            case buckets = "b", anchors = "a", keys = "k", unpricedCalls = "u"
        }

        init(sessionId: String, isSubagent: Bool, pathHash: UInt64, device: Int32, inode: UInt64, size: Int64, modified: Int64,
             born: Int64 = 0) {
            self.sessionId = sessionId
            self.isSubagent = isSubagent
            self.pathHash = pathHash
            self.device = device
            self.inode = inode
            self.size = size
            self.modified = modified
            self.born = born
            bytesRead = 0
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(String.self, forKey: .sessionId)
            isSubagent = try container.decode(Bool.self, forKey: .isSubagent)
            pathHash = try container.decode(UInt64.self, forKey: .pathHash)
            device = try container.decode(Int32.self, forKey: .device)
            inode = try container.decode(UInt64.self, forKey: .inode)
            size = try container.decode(Int64.self, forKey: .size)
            modified = try container.decode(Int64.self, forKey: .modified)
            born = try container.decode(Int64.self, forKey: .born)
            bytesRead = try container.decode(Int64.self, forKey: .bytesRead)
            tailHash = try container.decode(UInt64.self, forKey: .tailHash)
            tailLength = try container.decode(Int64.self, forKey: .tailLength)
            buckets = try container.decode([BucketRecord].self, forKey: .buckets)
            anchors = try container.decode([AnchorRecord].self, forKey: .anchors)
            unpricedCalls = try container.decode(Int.self, forKey: .unpricedCalls)
            guard let packed = Data(base64Encoded: try container.decode(String.self, forKey: .keys)), packed.count % 8 == 0 else {
                throw DecodingError.dataCorruptedError(forKey: .keys, in: container, debugDescription: "keys")
            }
            keys = packed.withUnsafeBytes { raw in
                (0..<(packed.count / 8)).map { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self)) }
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(isSubagent, forKey: .isSubagent)
            try container.encode(pathHash, forKey: .pathHash)
            try container.encode(device, forKey: .device)
            try container.encode(inode, forKey: .inode)
            try container.encode(size, forKey: .size)
            try container.encode(modified, forKey: .modified)
            try container.encode(born, forKey: .born)
            try container.encode(bytesRead, forKey: .bytesRead)
            try container.encode(tailHash, forKey: .tailHash)
            try container.encode(tailLength, forKey: .tailLength)
            try container.encode(buckets, forKey: .buckets)
            try container.encode(anchors, forKey: .anchors)
            try container.encode(unpricedCalls, forKey: .unpricedCalls)
            var packed = Data(capacity: keys.count * 8)
            for key in keys { withUnsafeBytes(of: key.littleEndian) { packed.append(contentsOf: $0) } }
            try container.encode(packed.base64EncodedString(), forKey: .keys)
        }

        var spend: Double { buckets.reduce(0) { $0 + $1.spend } }
    }

    /// Ten minutes of one file. Offsets are seconds into the bucket.
    struct BucketRecord: Codable, Equatable, Sendable {
        /// Seconds since 1970 / 600.
        var index: Int64
        var first: Double
        var last: Double
        var calls: Int
        var subagentCalls: Int
        var prompts: Int
        var spend: Double
        var subagentSpend: Double
        var byModel: [String: Double]

        private enum CodingKeys: String, CodingKey {
            case index = "i", first = "f", last = "l", calls = "c", subagentCalls = "sc", prompts = "p"
            case spend = "w", subagentSpend = "ws", byModel = "m"
        }

        var start: Date { Date(timeIntervalSince1970: Double(index) * ActivityLedger.bucketLength) }

        var ledgerBucket: ActivityLedger.Bucket {
            ActivityLedger.Bucket(
                start: start, first: start.addingTimeInterval(first), last: start.addingTimeInterval(last),
                spend: spend, calls: calls, subagentCalls: subagentCalls, subagentSpend: subagentSpend,
                prompts: prompts, spendByModel: byModel)
        }
    }

    struct AnchorRecord: Codable, Equatable, Sendable {
        var resetsAt: Double
        var rateLimitType: String
        var hitAt: Double

        private enum CodingKeys: String, CodingKey { case resetsAt = "r", rateLimitType = "k", hitAt = "h" }

        var anchor: LimitAnchor {
            LimitAnchor(resetsAt: Date(timeIntervalSince1970: resetsAt), kind: LimitKind(rateLimitType: rateLimitType),
                        hitAt: Date(timeIntervalSince1970: hitAt))
        }
    }
}

/// What Diagnostics says about the index.
public struct ActivityIndexSummary: Equatable, Sendable {
    public let accounts: Int
    public let transcripts: Int
    public let indexedThrough: Date
    public let coveredSince: Date
    public let attributedSpend: Double
    public let unattributedSpend: Double
    public let unpricedCalls: Int

    public var unattributedShare: Double {
        let total = attributedSpend + unattributedSpend
        return total > 0 ? unattributedSpend / total : 0
    }
}

// MARK: - Building and reading the index

/// Reads this Mac's Claude Code transcripts into per-account activity, incrementally.
///
/// Read-only over `~/.claude`: the only file written is the switcher's own index, under its
/// config directory, atomically. A transcript is re-read only from where the last read stopped,
/// and only when its identity (device, inode), size or modification time changed; one that
/// shrank or was replaced is read again from the start. The first build covers transcripts
/// modified in the last 14 days; each later refresh reaches seven days further back, up to 45.
/// Heavy: call it off the main thread.
public enum ActivityIndex {

    public static let fileName = "activity-index.json"

    /// `~/.config/claude-switcher/activity-index.json`, beside the config file.
    public static var defaultURL: URL {
        Config.configURL.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: false)
    }

    public struct Options: Sendable {
        public var firstBuildDays: Double = 14
        public var stepDays: Double = 7
        public var retentionDays: Double = 45
        /// Exact anchors are kept this long (the schedule ignores older ones).
        public var anchorDays: Double = 60
        /// Bytes read per `pread`. Measured on this Mac's own transcripts in a release build:
        /// 256 KB builds as fast as 2 MB, and the app's resident memory after the first build is
        /// about 50 MB instead of 100–125 MB — the larger buffers fragment the allocator, and a
        /// menu-bar app keeps that memory for as long as it runs. A line longer than a chunk is
        /// carried over until its newline, so the size bounds nothing but the buffer.
        public var chunkBytes = 256 << 10
        /// Transcripts parsed at once — a background build leaves the rest of the Mac alone.
        public var workers = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        public init() {}
    }

    // MARK: Disk

    /// The index on disk, or `nil` when missing, unreadable, corrupt or of another version —
    /// all of which mean "rebuild".
    public static func read(from url: URL) -> ActivityIndexFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let file = try? decoder.decode(ActivityIndexFile.self, from: data),
              file.version == ActivityIndexFile.currentVersion
        else { return nil }
        return file
    }

    /// Writes the index atomically: a private temporary file in the same folder, renamed over
    /// the old one. Creates the folder (0700) if needed; the file is 0600.
    public static func write(_ file: ActivityIndexFile, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        let temporary = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// A temporary file of ``write(_:to:)``: what a write cut short by Quit or a relaunch leaves.
    static let temporaryFilePattern = #"^\.activity-index\.json\.[0-9A-F-]{36}\.tmp$"#

    /// Removes what interrupted writes left in `directory` — regular files named as
    /// ``write(_:to:)`` names its temporary file, one at a time with `unlinkat`, never a folder
    /// or anything else — once they are `minimumAge` old, so another switcher's write in progress
    /// is never touched. For the lock holder at launch, before its first refresh. Returns how
    /// many were removed.
    @discardableResult
    public static func sweepTemporaryFiles(in directory: URL, now: Date = Date(), minimumAge: TimeInterval = 60) -> Int {
        guard let folder = try? HeldDirectory.openAnchor(directory.path, expectedOwner: getuid()),
              let names = try? folder.entries()
        else { return 0 }
        var removed = 0
        for name in names where Pattern.matches(temporaryFilePattern, name) {
            guard let status = try? folder.status(of: name), status.kind == .regular,
                  now.timeIntervalSince1970 - Double(status.modifiedNanoseconds) / 1e9 > minimumAge,
                  (try? folder.unlink(name)) != nil
            else { continue }
            removed += 1
        }
        return removed
    }

    // MARK: Refresh

    public struct Refresh: Sendable {
        public let file: ActivityIndexFile
        public let ledgers: [String: ActivityLedger]
        public let summary: ActivityIndexSummary
        /// The index file could not be written; the in-memory result is still good.
        public let writeError: String?
    }

    /// Reads the index (`previous`, or the file at `indexURL`; a corrupt one is rebuilt),
    /// brings it up to date with the transcripts, writes it back if anything changed, and
    /// returns every profile's ledger.
    public static func refresh(
        profiles: [Profile], home: String, indexURL: URL, previous: ActivityIndexFile? = nil,
        now: Date, options: Options = Options()
    ) -> Refresh {
        let attribution = ActivityAttribution.read(profiles: profiles, home: home)
        let old = previous ?? read(from: indexURL)
        var file = scan(previous: old, home: home, attribution: attribution, now: now, options: options)
        // The plan tier the CLI names for the account it is signed in to, remembered per account.
        if let signed = ClaudeConfigUsageSource.signedInTier(home: home), Set(attribution.accounts.values).contains(signed.account) {
            file.tiers = recording(tier: signed.tier, for: signed.account, in: file.tiers, now: now)
        }
        // A refresh that found nothing new changes only the time; the file is rewritten for that
        // only once it is more than ten minutes newer, so a stored index (`--dry-run`) still says
        // when it was last brought up to date without a write on every menu open.
        var unchanged = old
        unchanged?.updatedAt = file.updatedAt
        let timeMoved = old.map { file.updatedAt.timeIntervalSince($0.updatedAt) > timeRewrite } ?? true
        var writeError: String?
        if file != unchanged || timeMoved {
            do { try write(file, to: indexURL) } catch { writeError = "\(error)" }
        }
        return Refresh(file: file, ledgers: ledgers(from: file, attribution: attribution, now: now, options: options),
                       summary: summary(of: file, attribution: attribution, now: now, options: options), writeError: writeError)
    }

    /// A refresh that changed nothing but the time rewrites the file once the time has moved this much.
    static let timeRewrite: TimeInterval = 600

    /// `tiers` with `tier` recorded for `account`: a different tier than the one held is a plan
    /// change, dated now; the first one seen is not.
    static func recording(tier: String, for account: String, in tiers: [String: ActivityIndexFile.TierRecord],
                          now: Date) -> [String: ActivityIndexFile.TierRecord] {
        var tiers = tiers
        if let held = tiers[account] {
            if held.tier != tier { tiers[account] = .init(tier: tier, since: now) }
        } else {
            tiers[account] = .init(tier: tier, since: nil)
        }
        return tiers
    }

    /// What the index on disk already says, reading no transcript and writing nothing — for
    /// `--dry-run`, which must stay quick and side-effect free. `nil` when there is no usable
    /// index (it is built when the app runs).
    public static func stored(profiles: [Profile], home: String, indexURL: URL, now: Date, options: Options = Options()) -> Refresh? {
        guard let file = read(from: indexURL) else { return nil }
        let attribution = ActivityAttribution.read(profiles: profiles, home: home)
        return Refresh(file: file, ledgers: ledgers(from: file, attribution: attribution, now: now, options: options),
                       summary: summary(of: file, attribution: attribution, now: now, options: options), writeError: nil)
    }

    // MARK: Scan

    /// Brings `previous` up to date with the transcripts under `<home>/.claude/projects`.
    public static func scan(previous: ActivityIndexFile?, home: String, attribution: ActivityAttribution,
                            now: Date, options: Options = Options()) -> ActivityIndexFile {
        let day: TimeInterval = 86400
        let retentionStart = now.addingTimeInterval(-options.retentionDays * day)
        var file: ActivityIndexFile
        if let previous {
            file = previous
            // Reach back a step at a time; once the whole retention is covered, stay put.
            if previous.coveredSince > retentionStart {
                file.coveredSince = max(retentionStart, previous.coveredSince.addingTimeInterval(-options.stepDays * day))
            }
        } else {
            file = ActivityIndexFile(updatedAt: now, coveredSince: now.addingTimeInterval(-options.firstBuildDays * day))
        }
        // A transcript not indexed yet is read only if it is covered and could still hold
        // something worth keeping.
        let readFloor = Int64(max(file.coveredSince, retentionStart).timeIntervalSince1970 * 1e9)

        let projects = TranscriptLocator.projectsDirectory(home: home).path
        let listed = listTranscripts(under: projects)
        var byPath: [UInt64: [Int]] = [:]
        for (index, entry) in file.entries.enumerated() { byPath[entry.pathHash, default: []].append(index) }
        /// Which entry holds each call: the one that recorded it first, by birth.
        var holder: [UInt64: Int] = [:]
        for (index, entry) in file.entries.enumerated() { for key in entry.keys { holder[key] = index } }

        var present = Set<Int>()
        /// Each present entry's file in this listing.
        var listing: [Int: ListedTranscript] = [:]
        var work: [Work] = []
        func fresh(_ transcript: ListedTranscript) -> ActivityIndexFile.Entry {
            ActivityIndexFile.Entry(sessionId: transcript.sessionId, isSubagent: transcript.isSubagent, pathHash: transcript.pathHash,
                                    device: transcript.device, inode: transcript.inode, size: 0, modified: 0, born: transcript.born)
        }
        /// What an entry contributed is forgotten: its calls go back to whoever reads them next.
        func release(_ index: Int) {
            for key in file.entries[index].keys where holder[key] == index { holder[key] = nil }
        }
        func take(_ index: Int, _ transcript: ListedTranscript) {
            present.insert(index)
            listing[index] = transcript
            let entry = file.entries[index]
            if entry.device == transcript.device, entry.inode == transcript.inode {
                if transcript.size == entry.size, transcript.modified == entry.modified { return }
                // Grown (or changed at its size): read on from the last complete line, which the
                // read first checks is still the line it was. Smaller than when last read: rewritten.
                if transcript.size >= entry.size {
                    work.append(Work(transcript: transcript, entry: index, offset: entry.bytesRead,
                                     tail: entry.tailLength > 0 ? (entry.tailHash, entry.tailLength) : nil))
                    return
                }
            }
            // Shrank or replaced: what it contributed is forgotten and it is read afresh.
            release(index)
            file.entries[index] = fresh(transcript)
            work.append(Work(transcript: transcript, entry: index, offset: 0))
        }
        func add(_ transcript: ListedTranscript) {
            guard transcript.modified >= readFloor else { return }
            file.entries.append(fresh(transcript))
            let index = file.entries.count - 1
            byPath[transcript.pathHash, default: []].append(index)
            present.insert(index)
            listing[index] = transcript
            work.append(Work(transcript: transcript, entry: index, offset: 0))
        }

        var groups: [UInt64: [ListedTranscript]] = [:]
        var keys: [UInt64] = []
        for transcript in listed {
            if groups[transcript.pathHash] == nil { keys.append(transcript.pathHash) }
            groups[transcript.pathHash, default: []].append(transcript)
        }
        for key in keys {
            let files = groups[key]!
            let entries = byPath[key] ?? []
            if files.count == 1, entries.count <= 1 {
                if let index = entries.first { take(index, files[0]) } else { add(files[0]) }
                continue
            }
            // One session id under more than one project folder: told apart by file identity; a
            // file no entry has read is an entry of its own.
            var unmatched = entries
            for transcript in files {
                if let at = unmatched.firstIndex(where: { file.entries[$0].device == transcript.device && file.entries[$0].inode == transcript.inode }) {
                    take(unmatched.remove(at: at), transcript)
                } else {
                    add(transcript)
                }
            }
        }

        // The earliest-born copy of a call keeps it: forks and copies are younger than the
        // transcript they repeat. Within a refresh the reading order sees to it; across
        // refreshes — a copy read on the first build, its older original only when the index
        // reaches back — the younger entry gives its calls back and is read again from the
        // start, after the original. Equal birth times (setting a file's modification time
        // earlier than its birth moves the birth back too) fall back to the inode, which a
        // volume hands out in creation order, then to the key.
        func order(_ entry: ActivityIndexFile.Entry) -> (Int64, Int32, UInt64, UInt64) {
            (entry.born, entry.device, entry.inode, entry.pathHash)
        }
        func isOlder(_ a: Int, than b: Int) -> Bool {
            let x = order(file.entries[a]), y = order(file.entries[b])
            return x != y ? x < y : a < b
        }
        var generation: [Int: Int] = [:]
        var queue = work.sorted { a, b in
            let x = (a.transcript.born, a.transcript.device, a.transcript.inode, a.transcript.pathHash)
            let y = (b.transcript.born, b.transcript.device, b.transcript.inode, b.transcript.pathHash)
            return x != y ? x < y : a.entry < b.entry
        }
        let batch = max(1, options.workers * 4)
        var start = 0
        while start < queue.count {
            let slice = Array(queue[start..<min(queue.count, start + batch)])
            start += slice.count
            let readings = readConcurrently(slice, projects: projects, options: options)
            for (item, reading) in zip(slice, readings) {
                // A reading made before its entry was given back is stale.
                guard let reading, generation[item.entry, default: 0] == item.generation else { continue }
                var offset = item.offset
                if reading.restarted {
                    // The last line read is not there any more: rewritten in place, read afresh.
                    release(item.entry)
                    file.entries[item.entry] = fresh(item.transcript)
                    offset = 0
                }
                let younger = Set(reading.reading.keys.compactMap { holder[$0] })
                    .filter { $0 != item.entry && listing[$0] != nil && isOlder(item.entry, than: $0) }
                for other in younger.sorted() {
                    release(other)
                    file.entries[other] = fresh(listing[other]!)
                    generation[other, default: 0] += 1
                    queue.append(Work(transcript: listing[other]!, entry: other, offset: 0, generation: generation[other]!))
                }
                merge(reading.reading, into: &file.entries[item.entry], index: item.entry, from: offset, identity: reading.identity,
                      holder: &holder)
            }
        }

        // Retention: ten-minute sums older than 45 days, anchors older than 60, and entries with
        // nothing left that will not be read again.
        let retentionIndex = Int64((retentionStart.timeIntervalSince1970 / ActivityLedger.bucketLength).rounded(.down))
        let anchorStart = now.addingTimeInterval(-options.anchorDays * day).timeIntervalSince1970
        let retentionNanoseconds = Int64(retentionStart.timeIntervalSince1970 * 1e9)
        var kept: [ActivityIndexFile.Entry] = []
        for (index, var entry) in file.entries.enumerated() {
            entry.buckets.removeAll { $0.index < retentionIndex }
            entry.anchors.removeAll { $0.hitAt < anchorStart }
            let empty = entry.buckets.isEmpty && entry.anchors.isEmpty
            let willNotBeRead = !present.contains(index) || entry.modified < retentionNanoseconds
            if empty && willNotBeRead { continue }
            kept.append(entry)
        }
        file.entries = kept

        // Sticky attribution: what the records say now wins; what they said before stays.
        let sessions = Set(file.entries.map(\.sessionId))
        var owners = file.owners.filter { sessions.contains($0.key) }
        for id in sessions { if let account = attribution.claims[id] { owners[id] = account } }
        file.owners = owners
        file.updatedAt = now
        return file
    }

    struct Work {
        let transcript: ListedTranscript
        let entry: Int
        let offset: Int64
        /// The last complete line read before `offset` (hash, length), checked before reading on.
        var tail: (hash: UInt64, length: Int64)? = nil
        /// The entry's generation when queued; a younger copy given back is queued again.
        var generation = 0
    }

    struct Identity {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Int64
    }

    /// Folds one file's new lines into its entry (number `index`). Calls and limit hits already
    /// held by any transcript are skipped (`holder`), so each counts once, in the file that
    /// recorded it first.
    static func merge(_ reading: TranscriptReading, into entry: inout ActivityIndexFile.Entry, index: Int, from offset: Int64,
                      identity: Identity, holder: inout [UInt64: Int]) {
        var buckets: [Int64: ActivityIndexFile.BucketRecord] = [:]
        for bucket in entry.buckets { buckets[bucket.index] = bucket }
        func touch(_ at: TimeInterval, _ change: (inout ActivityIndexFile.BucketRecord) -> Void) {
            let index = Int64((at / ActivityLedger.bucketLength).rounded(.down))
            let offset = at - Double(index) * ActivityLedger.bucketLength
            var bucket = buckets[index] ?? ActivityIndexFile.BucketRecord(
                index: index, first: offset, last: offset, calls: 0, subagentCalls: 0, prompts: 0, spend: 0, subagentSpend: 0, byModel: [:])
            bucket.first = min(bucket.first, offset)
            bucket.last = max(bucket.last, offset)
            change(&bucket)
            buckets[index] = bucket
        }

        for call in reading.calls {
            guard holder[call.key] == nil else { continue }
            holder[call.key] = index
            entry.keys.append(call.key)
            if !ActivityWeights.price(for: call.model).known { entry.unpricedCalls += 1 }
            let isSubagent = entry.isSubagent || call.isSidechain
            let fillIn = ActivityWeights.fillInOutput(for: call.model)
            let output: Int
            if entry.isSubagent {
                output = max(call.output, fillIn)
            } else if call.isSidechain, call.output <= ActivityWeights.startOfStreamOutput {
                output = fillIn
            } else {
                output = call.output
            }
            let spend = ActivityWeights.spend(model: call.model, input: call.input, cacheWrite5m: call.cacheWrite5m,
                                              cacheWrite1h: call.cacheWrite1h, output: output)
            touch(call.at) { bucket in
                bucket.calls += 1
                bucket.spend += spend
                bucket.byModel[call.model, default: 0] += spend
                if isSubagent {
                    bucket.subagentCalls += 1
                    bucket.subagentSpend += spend
                }
            }
        }
        for prompt in reading.prompts { touch(prompt) { $0.prompts += 1 } }

        // Limit hits as calls: one another file recorded first is that file's (a copy's repeat of
        // it would give the copy's account the original account's limit). Repeats within this
        // file are merged below, keeping the first hit per reset.
        var anchors = entry.anchors.map(\.anchor)
        for anchor in reading.anchors {
            let key = TranscriptReading.key(anchor)
            if let held = holder[key], held != index { continue }
            if holder[key] == nil {
                holder[key] = index
                entry.keys.append(key)
            }
            anchors.append(anchor)
        }
        entry.anchors = LimitAnchor.merged(anchors).map {
            ActivityIndexFile.AnchorRecord(resetsAt: $0.resetsAt.timeIntervalSince1970, rateLimitType: $0.kind.rateLimitType,
                                           hitAt: $0.hitAt.timeIntervalSince1970)
        }
        entry.buckets = buckets.values.sorted { $0.index < $1.index }
        entry.device = identity.device
        entry.inode = identity.inode
        entry.size = identity.size
        entry.modified = identity.modified
        entry.bytesRead = offset + Int64(reading.consumed)
        if reading.tailLength > 0 {
            entry.tailHash = reading.tailHash
            entry.tailLength = Int64(reading.tailLength)
        }
    }

    // MARK: Reading transcripts

    /// Parses a batch of files on `options.workers` threads. Each file is opened by path
    /// without following a link at its name and must still be the file that was listed.
    static func readConcurrently(_ work: [Work], projects: String, options: Options) -> [Outcome?] {
        let results = ResultBox(count: work.count)
        let next = ResultBox.Counter()
        DispatchQueue.concurrentPerform(iterations: min(options.workers, work.count)) { _ in
            while let index = next.take(below: work.count) {
                let item = work[index]
                let outcome = readTranscript(projects + "/" + item.transcript.relativePath, expected: item.transcript,
                                             from: item.offset, tail: item.tail, chunkBytes: options.chunkBytes)
                results.set(index, outcome)
            }
        }
        return results.values
    }

    /// One file's new lines. `restarted`: the last line read before `offset` was not there any
    /// more, so the file was read from the start instead.
    struct Outcome {
        let reading: TranscriptReading
        let identity: Identity
        var restarted = false
    }

    static func readTranscript(_ path: String, expected: ListedTranscript, from start: Int64,
                               tail: (hash: UInt64, length: Int64)? = nil, chunkBytes: Int) -> Outcome? {
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { return nil }
        let file = HeldFile(descriptor: descriptor)
        guard let status = try? file.status(), status.kind == .regular,
              status.device == expected.device, status.inode == expected.inode
        else { return nil }
        let identity = Identity(device: status.device, inode: status.inode, size: status.size, modified: status.modifiedNanoseconds)
        var reading = TranscriptReading()
        var offset = start
        var restarted = false
        // Rewritten in place (same file, not smaller)? The last line read must still end at `offset`.
        if offset > 0, let tail, tail.length > 0, tail.length <= offset {
            let line = (try? file.read(count: Int(tail.length), at: offset - tail.length)) ?? Data()
            let same = line.count == Int(tail.length)
                && line.withUnsafeBytes { TranscriptReading.hash($0.bindMemory(to: UInt8.self)) } == tail.hash
            if !same {
                offset = 0
                restarted = true
            }
        }
        guard status.size > offset else { return Outcome(reading: reading, identity: identity, restarted: restarted) }

        var position = offset
        var pending = Data()
        while position < status.size {
            let count = Int(min(Int64(chunkBytes), status.size - position))
            guard let chunk = try? file.read(count: count, at: position), !chunk.isEmpty else { break }
            position += Int64(chunk.count)
            pending.append(chunk)
            let before = reading.consumed
            // JSONSerialization autoreleases what it builds; a worker thread would otherwise keep
            // every parsed line of every file it reads until the whole batch ends.
            autoreleasepool {
                pending.withUnsafeBytes { reading.read($0, isSubagentFile: expected.isSubagent) }
            }
            let used = reading.consumed - before
            if used > 0 { pending.removeSubrange(pending.startIndex..<(pending.startIndex + used)) }
        }
        return Outcome(reading: reading, identity: identity, restarted: restarted)
    }

    // MARK: Listing transcripts

    struct ListedTranscript {
        /// Under `~/.claude/projects`; used to open the file, never stored.
        let relativePath: String
        /// FNV-1a of the path below the project folder (see ``ActivityIndexFile/Entry/pathHash``).
        let pathHash: UInt64
        let sessionId: String
        let isSubagent: Bool
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Int64
        let born: Int64
    }

    /// Every transcript: `<project>/<id>.jsonl`, and `<project>/<id>/subagents/**/*.jsonl` for
    /// that session's subagents. Links are not followed.
    static func listTranscripts(under projects: String) -> [ListedTranscript] {
        guard let root = try? HeldDirectory.openAnchor(projects, expectedOwner: nil),
              let projectNames = try? root.entries()
        else { return [] }
        var listed: [ListedTranscript] = []

        /// `below` is the path below the project folder, the only part the key is made from.
        func add(_ directory: HeldDirectory, _ name: String, project: String, below: String, sessionId: String, isSubagent: Bool) {
            guard let (status, born) = statEntry(directory, name), status.kind == .regular else { return }
            listed.append(ListedTranscript(
                relativePath: project + "/" + below, pathHash: pathKey(below), sessionId: sessionId.lowercased(),
                isSubagent: isSubagent, device: status.device, inode: status.inode, size: status.size,
                modified: status.modifiedNanoseconds, born: born))
        }

        func walkSubagents(_ directory: HeldDirectory, project: String, below: String, sessionId: String, depth: Int) {
            guard depth < 6, let names = try? directory.entries() else { return }
            for name in names.sorted() {
                if name.hasSuffix(".jsonl") {
                    add(directory, name, project: project, below: below + "/" + name, sessionId: sessionId, isSubagent: true)
                } else if let child = try? directory.openDirectory(name, expectedOwner: nil) {
                    walkSubagents(child, project: project, below: below + "/" + name, sessionId: sessionId, depth: depth + 1)
                }
            }
        }

        for project in projectNames.sorted() {
            guard let folder = try? root.openDirectory(project, expectedOwner: nil),
                  let names = try? folder.entries()
            else { continue }
            for name in names.sorted() {
                if name.hasSuffix(".jsonl") {
                    let id = String(name.dropLast(".jsonl".count))
                    guard SessionStore.isUUID(id) else { continue }
                    add(folder, name, project: project, below: name, sessionId: id, isSubagent: false)
                } else if SessionStore.isUUID(name),
                          let session = try? folder.openDirectory(name, expectedOwner: nil),
                          let subagents = try? session.openDirectory("subagents", expectedOwner: nil) {
                    walkSubagents(subagents, project: project, below: name + "/subagents", sessionId: name, depth: 0)
                }
            }
        }
        return listed
    }

    /// The key an entry is stored under: FNV-1a of the path below the project folder
    /// (`<id>.jsonl`, `<id>/subagents/…`), never of the folder itself.
    static func pathKey(_ below: String) -> UInt64 { TranscriptReading.key(below, "") }

    /// `fstatat` without following a link, with the birth time (for "earliest copy wins").
    private static func statEntry(_ directory: HeldDirectory, _ name: String) -> (FileStatus, Int64)? {
        guard HeldDirectory.isSingleComponent(name) else { return nil }
        var info = stat()
        guard fstatat(directory.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return (FileStatus(info), FileStatus.nanoseconds(info.st_birthtimespec))
    }

    // MARK: Ledgers

    /// The account each indexed session belongs to: the records now, else the records before.
    static func owner(of sessionId: String, in file: ActivityIndexFile, attribution: ActivityAttribution) -> String? {
        attribution.claims[sessionId] ?? file.owners[sessionId]
    }

    /// Every profile's ledger. A profile without a signed-in account has none; two profiles on
    /// one account share one.
    public static func ledgers(from file: ActivityIndexFile, attribution: ActivityAttribution, now: Date,
                               options: Options = Options()) -> [String: ActivityLedger] {
        let retentionStart = now.addingTimeInterval(-options.retentionDays * 86400)
        let accounts = Set(attribution.accounts.values)
        var sessions: [String: [String: [ActivityLedger.Bucket]]] = [:]
        var anchors: [String: [LimitAnchor]] = [:]
        var unpriced: [String: Int] = [:]
        var unattributed = 0.0
        for entry in file.entries {
            let buckets = entry.buckets.filter { $0.start >= retentionStart }
            guard let account = owner(of: entry.sessionId, in: file, attribution: attribution), accounts.contains(account) else {
                unattributed += buckets.reduce(0) { $0 + $1.spend }
                continue
            }
            sessions[account, default: [:]][entry.sessionId, default: []].append(contentsOf: buckets.map(\.ledgerBucket))
            anchors[account, default: []].append(contentsOf: entry.anchors.map(\.anchor))
            unpriced[account, default: 0] += entry.unpricedCalls
        }
        var ledgers: [String: ActivityLedger] = [:]
        for (profile, account) in attribution.accounts {
            ledgers[profile] = ActivityLedger(
                sessions: sessions[account] ?? [:], anchors: anchors[account] ?? [], indexedThrough: file.updatedAt,
                unattributedSpend: unattributed, unpricedCalls: unpriced[account] ?? 0,
                coveredSince: max(file.coveredSince, retentionStart),
                tier: file.tiers[account]?.tier, tierChangedAt: file.tiers[account]?.since)
        }
        return ledgers
    }

    public static func summary(of file: ActivityIndexFile, attribution: ActivityAttribution, now: Date,
                               options: Options = Options()) -> ActivityIndexSummary {
        let retentionStart = now.addingTimeInterval(-options.retentionDays * 86400)
        let accounts = Set(attribution.accounts.values)
        var attributed = 0.0, unattributed = 0.0, unpriced = 0
        var used = Set<String>()
        for entry in file.entries {
            let spend = entry.buckets.filter { $0.start >= retentionStart }.reduce(0) { $0 + $1.spend }
            if let account = owner(of: entry.sessionId, in: file, attribution: attribution), accounts.contains(account) {
                attributed += spend
                unpriced += entry.unpricedCalls
                used.insert(account)
            } else {
                unattributed += spend
            }
        }
        return ActivityIndexSummary(accounts: used.count, transcripts: file.entries.count, indexedThrough: file.updatedAt,
                                    coveredSince: file.coveredSince, attributedSpend: attributed,
                                    unattributedSpend: unattributed, unpricedCalls: unpriced)
    }
}

/// Results of the concurrent read, slot by slot.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [ActivityIndex.Outcome?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: ActivityIndex.Outcome?) {
        lock.lock()
        slots[index] = value
        lock.unlock()
    }

    var values: [ActivityIndex.Outcome?] {
        lock.lock()
        defer { lock.unlock() }
        return slots
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0

        func take(below limit: Int) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard next < limit else { return nil }
            next += 1
            return next - 1
        }
    }
}
