import Foundation

/// Canonicalises user supplied directory paths.
///
/// The result of ``PathNormalizer/normalize(_:home:)`` is the single source of
/// truth for a path throughout the app: it is exactly the string handed to
/// Claude on the command line (`--user-data-dir=<normalized>`) **and** exactly
/// the string that gets SHA-256 hashed when deriving a Keychain service name.
/// Normalising in two different ways would produce two different service names
/// for the same directory, so every consumer must funnel through here.
public enum PathNormalizer {

    /// Normalises `raw` into an absolute, slash-collapsed, NFC-encoded path.
    ///
    /// The transformation, in order:
    /// 1. A leading `~` (alone) or `~/` expands to `home`.
    /// 2. A path that is still not absolute is resolved against `home`.
    /// 3. Runs of `/` collapse into a single separator.
    /// 4. Trailing separators are stripped — except that the root never
    ///    degenerates to the empty string, it stays `"/"`.
    /// 5. Unicode canonical composition (NFC) is applied **last**, so the
    ///    returned string is byte-for-byte what gets passed to Claude and hashed.
    ///
    /// Empty input is returned unchanged as `""`; callers treat `""` the same as
    /// `nil` (no directory configured / invalid).
    ///
    /// Note that `.` and `..` components are deliberately *not* resolved: doing
    /// so would require touching the filesystem, and the hash must be derivable
    /// for directories that do not exist yet.
    ///
    /// - Parameters:
    ///   - raw: The path as typed by the user or read from the config file.
    ///   - home: The home directory used for `~` expansion and for making
    ///     relative paths absolute. Injectable so tests are hermetic.
    /// - Returns: The canonical path, or `""` when `raw` is empty.
    public static func normalize(_ raw: String, home: String = NSHomeDirectory()) -> String {
        guard !raw.isEmpty else { return "" }

        var path = raw

        // 1 & 2 — tilde expansion, then absolutisation. These are mutually
        // exclusive: expanding "~" already yields an absolute path, so joining
        // `home` a second time would duplicate it.
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + "/" + path.dropFirst(2)
        } else if !path.hasPrefix("/") {
            path = home + "/" + path
        }

        // 3 & 4 — splitting on "/" while dropping empty components collapses
        // duplicate separators and strips trailing ones in a single pass; the
        // unconditional leading "/" keeps the root as "/" rather than "".
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        path = "/" + components.joined(separator: "/")

        // 5 — NFC last, so the returned bytes are final.
        return path.precomposedStringWithCanonicalMapping
    }
}
