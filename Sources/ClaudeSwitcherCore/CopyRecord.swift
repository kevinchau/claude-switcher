import Foundation

/// The record a copy is filed under in the other account's store.
///
/// Built field by field, never copied from the source: a source record carries ids, worktree
/// and branch bindings, Remote Control sessions, scheduled tasks and grants that belong to the
/// original account — and each of them arms something in the other one (reaping the original's
/// transcript on delete, removing a shared worktree, archiving Remote Control sessions with the
/// other account's token). The only keys are these, in this order:
///
/// `sessionId, cliSessionId, cwd, originCwd, createdAt, lastActivityAt, indexedAt, isArchived,
/// title?, permissionMode, model?, effort?, sessionPermissionUpdates, alwaysAllowedReasons`
///
/// Serialized by hand so the bytes are the same every time — the journal keeps their hash.
enum CopyRecord {

    /// Claude's own limit for a session title.
    static let maximumTitleLength = 200

    static let keys = [
        "sessionId", "cliSessionId", "cwd", "originCwd", "createdAt", "lastActivityAt", "indexedAt",
        "isArchived", "title", "permissionMode", "model", "effort", "sessionPermissionUpdates", "alwaysAllowedReasons",
    ]

    /// The record's bytes for a copy of `source` under the new id `newID`.
    ///
    /// - `newID` is lowercased here: Claude's ids and file names are lowercase UUIDs, and
    ///   Foundation's `uuidString` is uppercase.
    /// - All three timestamps are `now` in whole epoch milliseconds, rounded down so they are
    ///   never in the future. A later delete of the copy is refused by Claude if
    ///   `lastActivityAt` is older than the copy's last line, so it must be taken after the
    ///   transcript is staged.
    /// - `originCwd` is `cwd`: a different origin becomes the base repository for branch
    ///   deletion and a worktree fallback in the other account.
    /// - `permissionMode` is `default`; no grant crosses accounts.
    static func bytes(forCopyOf source: SessionRecord, newID: UUID, now: Date) -> Data {
        let id = newID.uuidString.lowercased()
        let milliseconds = String(Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))

        var fields: [(String, String)] = [
            ("sessionId", jsonString(SessionStore.recordPrefix + id)),
            ("cliSessionId", jsonString(id)),
            ("cwd", jsonString(source.cwd)),
            ("originCwd", jsonString(source.cwd)),
            ("createdAt", milliseconds),
            ("lastActivityAt", milliseconds),
            ("indexedAt", milliseconds),
            ("isArchived", "false"),
        ]
        if let title = title(forCopyOf: source.title) { fields.append(("title", jsonString(title))) }
        fields.append(("permissionMode", jsonString("default")))
        if let model = source.model, !model.isEmpty { fields.append(("model", jsonString(model))) }
        if let effort = source.effort, !effort.isEmpty { fields.append(("effort", jsonString(effort))) }
        fields.append(("sessionPermissionUpdates", "[]"))
        fields.append(("alwaysAllowedReasons", "[]"))

        return Data(("{" + fields.map { jsonString($0.0) + ":" + $0.1 }.joined(separator: ",") + "}").utf8)
    }

    /// The copy's title — only when the source has one with something other than whitespace.
    ///
    /// Numbered as Claude's own fork numbers: `T` gives `T (copy)`; `T (copy)` gives
    /// `T (copy 2)`; `T (copy N)` gives `T (copy N+1)`. The base is shortened so the whole
    /// title fits Claude's 200 characters (UTF-16 units, as JavaScript counts) with its suffix
    /// intact, never splitting a character.
    static func title(forCopyOf source: String?) -> String? {
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let (base, number) = numbering(of: source)
        let suffix = number.map { " (copy \($0))" } ?? " (copy)"
        var trimmed = base
        while trimmed.utf16.count + suffix.utf16.count > maximumTitleLength, !trimmed.isEmpty {
            trimmed.removeLast()
        }
        return trimmed + suffix
    }

    /// `/^(.*) \(copy(?: (\d+))?\)$/`: the base and the next number, or the whole title and `nil`.
    /// JavaScript's `.` matches no line terminator, so a base containing one is no match.
    private static func numbering(of title: String) -> (base: String, next: Int?) {
        let unchanged = (title, Int?.none)
        guard title.hasSuffix(")"), let open = title.range(of: " (copy", options: .backwards) else { return unchanged }
        let base = String(title[..<open.lowerBound])
        let inside = title[open.upperBound..<title.index(before: title.endIndex)]
        guard !base.unicodeScalars.contains(where: { [0x0A, 0x0D, 0x2028, 0x2029].contains($0.value) }) else { return unchanged }
        if inside.isEmpty { return (base, 2) }
        guard inside.hasPrefix(" ") else { return unchanged }
        let digits = inside.dropFirst()
        guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let number = Int(digits), number < Int.max
        else { return unchanged }
        return (base, number + 1)
    }

    /// True when `data` contains neither the source's transcript id nor its record id, in any
    /// letter case. Either one in the new record would point the other account at the original's
    /// files — deleting the copy would then reap the original.
    static func isFree(_ data: Data, ofSourceCliSessionId cliSessionId: String, sourceRecordID recordID: String) -> Bool {
        let haystack = Array(data).map(lowercasedASCII)
        for needle in [cliSessionId, recordID, String(recordID.dropFirst(SessionStore.recordPrefix.count))] where !needle.isEmpty {
            let pattern = Array(needle.utf8).map(lowercasedASCII)
            guard pattern.count <= haystack.count else { continue }
            for start in 0...(haystack.count - pattern.count) where haystack[start] == pattern[0] {
                if haystack[start..<start + pattern.count].elementsEqual(pattern) { return false }
            }
        }
        return true
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    /// A JSON string literal as JavaScript's `JSON.stringify` writes it: `"` and `\` escaped,
    /// `\b \f \n \r \t` short, other control characters as `\u00xx`, everything else verbatim.
    static func jsonString(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += "\\u00" + (scalar.value < 0x10 ? "0" : "") + String(scalar.value, radix: 16)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
