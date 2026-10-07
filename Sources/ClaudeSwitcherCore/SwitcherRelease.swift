import Foundation

// MARK: - Versions

/// A Claude Switcher release version, `MAJOR.MINOR.PATCH`, as its tag (`v0.8.0`) and its sealed
/// `CFBundleShortVersionString` (`0.8.0`) spell it.
///
/// Comparable, unlike ``AppVersion``: Claude's own flows only ever ask "did it change", while the
/// switcher must never install anything that is not strictly newer than what is running.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    // ASCII [0-9] only, never \d: ICU's \d also matches every other script's digits, and a
    // tag like v٠.1.0 must not become a version.
    static let tagPattern = #"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#
    static let versionPattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#

    /// `v0.8.0` — the only tag shape a release may have.
    public init?(tag: String) { self.init(text: tag, pattern: Self.tagPattern) }

    /// `0.8.0` — a bundle's `CFBundleShortVersionString`.
    public init?(string: String) { self.init(text: string, pattern: Self.versionPattern) }

    private init?(text: String, pattern: String) {
        guard let groups = Pattern.fullMatch(pattern, text), groups.count == 3,
              let major = Self.number(groups[0]), let minor = Self.number(groups[1]), let patch = Self.number(groups[2])
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    /// The value of a run of digits the pattern admitted. The pattern is the one guard on what
    /// counts as a digit; this only adds them up, refusing a number too large for `Int`.
    private static func number(_ digits: String) -> Int? {
        var value = 0
        for byte in digits.utf8 {
            let (shifted, overflowA) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflowB) = shifted.addingReportingOverflow(Int(byte) - 0x30)
            guard !overflowA, !overflowB else { return nil }
            value = sum
        }
        return value
    }

    public var tag: String { "v" + description }
    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = ReleaseVersion(string: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a version: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Whole-string matching with `NSRegularExpression`. `$` alone also matches before a final line
/// feed, so a match only counts when it spans the entire text.
enum Pattern {
    static func fullMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: whole), match.range == whole else { return nil }
        return (1..<max(match.numberOfRanges, 1)).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool { fullMatch(pattern, text) != nil }
}

// MARK: - The release the feed names

/// The latest release, as far as the feed can say: everything is still to be verified.
public struct ReleaseCandidate: Equatable, Sendable, Codable {
    public let version: ReleaseVersion
    public let tag: String
    public let assetSize: Int
    /// 64 lowercase hex digits, without the `sha256:` prefix.
    public let digestHex: String
    /// Diagnostics only: nothing is decided on it.
    public let immutable: Bool?

    public init(version: ReleaseVersion, assetSize: Int, digestHex: String, immutable: Bool?) {
        self.version = version
        self.tag = version.tag
        self.assetSize = assetSize
        self.digestHex = digestHex
        self.immutable = immutable
    }

    /// Built from the validated tag, never taken from the JSON.
    public var downloadURL: URL { SwitcherReleaseFeed.downloadURL(tag: tag) }
    public var releasePageURL: URL { SwitcherReleaseFeed.releasePageURL(tag: tag) }

    /// One release file: a new digest under the same tag is a different candidate.
    public var key: String { "\(tag)#\(digestHex)" }

    private enum CodingKeys: String, CodingKey { case version, tag, assetSize, digestHex, immutable }

    /// A candidate read back from `state.json` passes the same checks as one read from the
    /// feed: the tag is the version's own, the digest is 64 lowercase hex digits and the size is
    /// in range. A hand-edited record cannot steer the download URL or the hash comparison.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(ReleaseVersion.self, forKey: .version)
        let tag = try container.decode(String.self, forKey: .tag)
        let size = try container.decode(Int.self, forKey: .assetSize)
        let digest = try container.decode(String.self, forKey: .digestHex)
        guard tag == version.tag, size > 0, size <= SwitcherReleaseFeed.maxAssetBytes,
              Pattern.matches("^[0-9a-f]{64}$", digest)
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a release candidate"))
        }
        self.init(version: version, assetSize: size, digestHex: digest,
                  immutable: try container.decodeIfPresent(Bool.self, forKey: .immutable))
    }
}

public enum FeedError: Error, Equatable, Sendable {
    case notJSON
    case draft
    case prerelease
    case badTag(String)
    case noAsset
    case duplicateAsset
    case assetNotUploaded
    case assetSizeOutOfRange(Int)
    case badDigest

    public var reason: String {
        switch self {
        case .notJSON: return "the answer is not the release JSON it used to be"
        case .draft: return "the latest release is not marked as published"
        case .prerelease: return "the latest release is not marked as a final release"
        case .badTag(let tag): return "the tag \u{201C}\(tag)\u{201D} is not of the form vMAJOR.MINOR.PATCH"
        case .noAsset: return "the release has no \(SwitcherReleaseFeed.assetName) yet"
        case .duplicateAsset: return "the release has more than one \(SwitcherReleaseFeed.assetName)"
        case .assetNotUploaded: return "\(SwitcherReleaseFeed.assetName) is still being uploaded"
        case .assetSizeOutOfRange(let size): return "\(SwitcherReleaseFeed.assetName) has an unexpected size (\(size) bytes)"
        case .badDigest: return "\(SwitcherReleaseFeed.assetName) has no SHA-256 digest"
        }
    }
}

/// What one look at the feed came to.
public enum CheckOutcome: Equatable, Sendable, Codable {
    case candidate(ReleaseCandidate)
    case noRelease
    case rateLimited(until: Date)
    case apiRetired
    case feedMoved(String)
    case feedChanged(String)
    case serverError(Int)
    case offline(String)

    /// One line for Diagnostics or an alert; `nil` for a candidate, which is described by version.
    public var failureReason: String? {
        switch self {
        case .candidate: return nil
        case .noRelease: return "no release published (404)"
        case .rateLimited: return "GitHub rate limit"
        case .apiRetired:
            return "this version of Claude Switcher can no longer read GitHub\u{2019}s feed \u{2014} download by hand"
        case .feedMoved(let location): return "feed moved: \(location)"
        case .feedChanged(let reason): return "GitHub\u{2019}s feed changed: \(reason)"
        case .serverError(let code): return "GitHub answered \(code)"
        case .offline(let description): return "could not reach api.github.com: \(description)"
        }
    }
}

/// What the fetch seam hands back. A redirect is never followed, so a 3xx arrives as a response.
public enum FetchResult: Equatable, Sendable {
    case response(status: Int, headers: [String: String], body: Data)
    case transport(String)
}

// MARK: - The feed

/// GitHub's "latest release" for kevinchau/claude-switcher: the request, and the pure reading of
/// what comes back. No token, no cookie and no cache, ever.
public enum SwitcherReleaseFeed {

    public static let apiURL = URL(string: "https://api.github.com/repos/kevinchau/claude-switcher/releases/latest")!
    /// `scripts/dmg.sh` builds `Claude Switcher.dmg`; GitHub stores it with the space as a dot.
    public static let assetName = "Claude.Switcher.dmg"
    public static let maxAssetBytes = 50_000_000
    public static let apiVersion = "2026-03-10"
    /// The release JSON is a few kilobytes. Anything this large is not it.
    static let maxBodyBytes = 1_000_000

    public static let checkInterval: TimeInterval = 6 * 3600
    public static let retryInterval: TimeInterval = 3600
    /// No schedule this code writes, and none it reads back, lies further ahead than this.
    public static let maximumDelay: TimeInterval = 24 * 3600

    public static func request(userAgentVersion: String) -> URLRequest {
        // The version comes from our own signature; anything else is not put in a header.
        let version = ReleaseVersion(string: userAgentVersion)?.description ?? "unknown"
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClaudeSwitcher/\(version) (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Ephemeral, uncached, cookie-less and credential-less. The download uses the same, with a
    /// longer resource timeout.
    public static func sessionConfiguration(resourceTimeout: TimeInterval = 60) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    public static func downloadURL(tag: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/kevinchau/claude-switcher/releases/download/\(tag)/\(assetName)"
        return components.url!
    }

    public static func releasePageURL(tag: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/kevinchau/claude-switcher/releases/tag/\(tag)"
        return components.url!
    }

    // MARK: Reading

    private struct Release: Decodable {
        let tagName: String?
        let draft: Bool?
        let prerelease: Bool?
        let immutable: Bool?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", draft, prerelease, immutable, assets
        }

        /// Every field optional and every type checked on its own: a field of a surprising type
        /// reads as missing and is refused at its own step, not as "not JSON".
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try? container.decodeIfPresent(String.self, forKey: .tagName)
            draft = try? container.decodeIfPresent(Bool.self, forKey: .draft)
            prerelease = try? container.decodeIfPresent(Bool.self, forKey: .prerelease)
            immutable = try? container.decodeIfPresent(Bool.self, forKey: .immutable)
            assets = try? container.decodeIfPresent([Asset].self, forKey: .assets)
        }
    }

    private struct Asset: Decodable {
        let name: String?
        let state: String?
        let size: Int?
        let digest: String?

        enum CodingKeys: String, CodingKey { case name, state, size, digest }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            state = try? container.decodeIfPresent(String.self, forKey: .state)
            size = try? container.decodeIfPresent(Int.self, forKey: .size)
            digest = try? container.decodeIfPresent(String.self, forKey: .digest)
        }
    }

    /// The release JSON, checked in the order the design gives. Only `tag_name`, `draft`,
    /// `prerelease`, `immutable` and the matching asset's `name`, `state`, `size` and `digest`
    /// are read; in particular `browser_download_url` is not.
    public static func parse(_ data: Data) -> Result<ReleaseCandidate, FeedError> {
        guard data.count <= maxBodyBytes, let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return .failure(.notJSON)
        }
        guard release.draft == false else { return .failure(.draft) }
        guard release.prerelease == false else { return .failure(.prerelease) }
        guard let tag = release.tagName, let version = ReleaseVersion(tag: tag) else {
            return .failure(.badTag(release.tagName ?? ""))
        }
        let matching = (release.assets ?? []).filter { $0.name == assetName }
        guard !matching.isEmpty else { return .failure(.noAsset) }
        guard matching.count == 1, let asset = matching.first else { return .failure(.duplicateAsset) }
        guard asset.state == "uploaded" else { return .failure(.assetNotUploaded) }
        guard let size = asset.size, size > 0, size <= maxAssetBytes else {
            return .failure(.assetSizeOutOfRange(asset.size ?? 0))
        }
        guard let digest = asset.digest, let groups = Pattern.fullMatch("^sha256:([0-9a-f]{64})$", digest),
              let hex = groups.first
        else { return .failure(.badDigest) }
        return .success(ReleaseCandidate(version: version, assetSize: size, digestHex: hex, immutable: release.immutable))
    }

    /// What a response means. Every date this produces is at most 24 hours ahead of `now`.
    public static func outcome(status: Int, headers: [String: String], body: Data?, now: Date) -> CheckOutcome {
        var lowered: [String: String] = [:]
        for (name, value) in headers { lowered[name.lowercased()] = value }

        switch status {
        case 200:
            switch parse(body ?? Data()) {
            case .success(let candidate): return .candidate(candidate)
            case .failure(let error): return .feedChanged(error.reason)
            }
        case 300...399:
            return .feedMoved(movedLocation(lowered["location"]))
        case 404:
            return .noRelease
        case 403, 429:
            return .rateLimited(until: rateLimitedUntil(headers: lowered, now: now))
        case 410:
            return .apiRetired
        default:
            return .serverError(status)
        }
    }

    /// Host and path only: a query could carry anything.
    static func movedLocation(_ location: String?) -> String {
        guard let location, let url = URL(string: location), let host = url.host else { return "an unnamed location" }
        return host + url.path
    }

    /// `min(max(retry-after, x-ratelimit-reset, now + 1 h), now + 24 h)`: a forged header can
    /// postpone the next look by a day at most.
    static func rateLimitedUntil(headers: [String: String], now: Date) -> Date {
        var candidates = [now.addingTimeInterval(retryInterval)]
        if let value = headers["retry-after"], let date = retryAfter(value, now: now) {
            candidates.append(date)
        }
        if let value = headers["x-ratelimit-reset"]?.trimmingCharacters(in: .whitespaces),
           !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let seconds = Int(value) {
            candidates.append(Date(timeIntervalSince1970: TimeInterval(seconds)))
        }
        return min(candidates.max() ?? now, now.addingTimeInterval(maximumDelay))
    }

    /// `retry-after` as integer seconds up to a day, or an HTTP-date up to a day ahead; anything
    /// else is ignored.
    static func retryAfter(_ raw: String, now: Date) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
            guard value.count <= 6, let seconds = Int(value), seconds <= Int(maximumDelay) else { return nil }
            return now.addingTimeInterval(TimeInterval(seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value), date <= now.addingTimeInterval(maximumDelay) else { return nil }
        return date
    }
}

// MARK: - Redirects of the download

/// Which hops the download may take. GitHub answers the constructed `github.com` URL with a
/// redirect to its release-asset host, and that host serves the bytes.
public enum RedirectPolicy {
    public static let maxHops = 3
    public static let originHost = "github.com"
    public static let assetHosts: Set<String> = ["release-assets.githubusercontent.com", "objects.githubusercontent.com"]

    /// `hop` counts from 1 for the first redirect.
    public static func allows(from: URL, to: URL, hop: Int) -> Bool {
        guard hop >= 1, hop <= maxHops,
              from.scheme?.lowercased() == "https", to.scheme?.lowercased() == "https",
              to.port == nil, to.user == nil, to.password == nil,
              let fromHost = from.host?.lowercased(), let toHost = to.host?.lowercased()
        else { return false }
        // Only github.com may send us anywhere; an asset host's answer is the file or nothing.
        guard fromHost == originHost else { return false }
        if toHost == originHost { return hop == 1 }
        return assetHosts.contains(toHost)
    }
}
