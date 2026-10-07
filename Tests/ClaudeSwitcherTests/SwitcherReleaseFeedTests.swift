import XCTest
@testable import ClaudeSwitcherCore

/// The feed, read: what is asked, what an answer means, which release it names, and where its
/// file may be fetched from. Every answer here is recorded or made up; nothing is fetched.
final class SwitcherReleaseFeedTests: XCTestCase {

    /// The recorded release with one top-level field changed (`nil` removes it). A typed
    /// parameter, not a closure over an untyped literal: on Swift 6.1 the latter took the type
    /// checker past its limit inside a generic assertion.
    private func release(_ key: String, _ value: Any?) -> Data {
        ReleaseFeedFixture.release { fields in
            if let value { fields[key] = value } else { fields.removeValue(forKey: key) }
        }
    }

    /// The recorded asset with one field changed (`nil` removes it).
    private func asset(_ key: String, _ value: Any?) -> Data {
        ReleaseFeedFixture.asset { fields in
            if let value { fields[key] = value } else { fields.removeValue(forKey: key) }
        }
    }

    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func v(_ text: String) -> ReleaseVersion { ReleaseVersion(string: text)! }

    // MARK: - Parse

    func testTheRecordedV070ReleaseParses() throws {
        let candidate = try SwitcherReleaseFeed.parse(ReleaseFeedFixture.latestV070).get()
        XCTAssertEqual(candidate.tag, "v0.7.0")
        XCTAssertEqual(candidate.version, v("0.7.0"))
        XCTAssertEqual(candidate.assetSize, ReleaseFeedFixture.v070Size)
        XCTAssertEqual(candidate.digestHex, ReleaseFeedFixture.v070Digest)
        XCTAssertEqual(candidate.immutable, false)
        XCTAssertEqual(candidate.downloadURL.absoluteString,
                       "https://github.com/kevinchau/claude-switcher/releases/download/v0.7.0/Claude.Switcher.dmg")
        XCTAssertEqual(candidate.releasePageURL.absoluteString,
                       "https://github.com/kevinchau/claude-switcher/releases/tag/v0.7.0")
    }

    /// The JSON names where its file is; that is never where it is fetched from.
    func testTheDownloadURLIsBuiltFromTheTagNeverTakenFromTheJSON() throws {
        let data = ReleaseFeedFixture.asset {
            $0["browser_download_url"] = "https://evil.example/Claude.Switcher.dmg"
            $0["url"] = "https://evil.example/asset"
        }
        let candidate = try SwitcherReleaseFeed.parse(data).get()
        XCTAssertEqual(candidate.downloadURL.host, "github.com")
        XCTAssertEqual(candidate.downloadURL.absoluteString,
                       "https://github.com/kevinchau/claude-switcher/releases/download/v0.7.0/Claude.Switcher.dmg")
    }

    private func refusal(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> FeedError? {
        switch SwitcherReleaseFeed.parse(data) {
        case .success(let candidate):
            XCTFail("expected a refusal, parsed \(candidate)", file: file, line: line)
            return nil
        case .failure(let error):
            return error
        }
    }

    func testDraftsPrereleasesAndUnmarkedReleasesAreRefused() {
        XCTAssertEqual(refusal(release("draft", true)), .draft)
        XCTAssertEqual(refusal(release("prerelease", true)), .prerelease)
        XCTAssertEqual(refusal(release("draft", nil)), .draft)
        XCTAssertEqual(refusal(release("prerelease", nil)), .prerelease)
        XCTAssertEqual(refusal(release("draft", "false")), .draft)
    }

    func testOnlyAPlainVMajorMinorPatchTagIsAVersion() {
        for tag in ["v0.8", "0.8.0", "v0.8.0-rc1", "v01.0.0", "v0.08.0", "v0.8.0 ", "V0.8.0", "v0.8.0\n", "v+1.0.0",
                    "v\u{0660}.1.0", "v0.\u{0661}.0", "v0.1.\u{FF11}", "v1\u{0660}.0.0", "v0.1\u{0661}.0", "v0.0.1\u{0967}",
                    "v99999999999999999999.0.0", ""] {
            XCTAssertEqual(refusal(release("tag_name", tag)), .badTag(tag), tag)
        }
        XCTAssertEqual(refusal(release("tag_name", nil)), .badTag(""))
        XCTAssertEqual(ReleaseVersion(tag: "v10.0.12"), ReleaseVersion(major: 10, minor: 0, patch: 12))
    }

    /// ICU's `\d` matches every script's digits; the patterns must not.
    func testUnicodeDigitsAreNotDigits() {
        XCTAssertNil(ReleaseVersion(tag: "v\u{0660}.1.0"))
        XCTAssertNil(ReleaseVersion(string: "\u{0661}.0.0"))
        XCTAssertNil(ReleaseVersion(string: "0.\u{0967}.0"))
        XCTAssertNil(ReleaseVersion(tag: "v1\u{0660}.0.0"))
        XCTAssertNil(ReleaseVersion(string: "1\u{0660}.0.0"))
    }

    func testExactlyOneUploadedAssetOfTheRightNameAndSizeWithASHA256Digest() {
        XCTAssertEqual(refusal(release("assets", [Any]())), .noAsset)
        XCTAssertEqual(refusal(asset("name", "Claude Switcher.dmg")), .noAsset)
        let twice: [Any] = [ReleaseFeedFixture.recordedAsset, ReleaseFeedFixture.recordedAsset]
        XCTAssertEqual(refusal(release("assets", twice)), .duplicateAsset)
        XCTAssertEqual(refusal(asset("state", "open")), .assetNotUploaded)
        XCTAssertEqual(refusal(asset("state", nil)), .assetNotUploaded)
        // Each literal typed on its own line: a closure writing an untyped literal into a
        // `[String: Any]`, inside a generic assertion, took the type checker past its limit on a
        // slower machine (GitHub's runner).
        for size: Int in [0, 50_000_001, -1] {
            let expected: FeedError = .assetSizeOutOfRange(size)
            XCTAssertEqual(refusal(asset("size", size)), expected, "size \(size)")
        }
        let hex: String = ReleaseFeedFixture.v070Digest
        let truncated: String = String(hex.dropLast())
        let badDigests: [Any] = [NSNull(), "md5:" + hex, "sha256:" + hex.uppercased(), "sha256:" + truncated,
                                 "sha256:" + hex + "0", hex, "sha512:" + hex, "sha256:" + hex + "\n"]
        for digest in badDigests {
            XCTAssertEqual(refusal(asset("digest", digest)), .badDigest, "\(digest)")
        }
        XCTAssertEqual(refusal(asset("digest", nil)), .badDigest)
        // The largest allowed size is allowed.
        XCTAssertNoThrow(try SwitcherReleaseFeed.parse(asset("size", 50_000_000)).get())
    }

    func testAnswersThatAreNotTheReleaseJSONAreRefused() {
        XCTAssertEqual(refusal(Data("<html>".utf8)), .notJSON)
        XCTAssertEqual(refusal(Data("[]".utf8)), .notJSON)
        // The cap, on an answer that is otherwise the real release: one byte over is refused
        // before it is decoded, the cap itself still reads.
        var over = ReleaseFeedFixture.latestV070
        over.append(Data(repeating: 0x20, count: SwitcherReleaseFeed.maxBodyBytes - over.count + 1))
        XCTAssertEqual(refusal(over), .notJSON)
        var atTheCap = ReleaseFeedFixture.latestV070
        atTheCap.append(Data(repeating: 0x20, count: SwitcherReleaseFeed.maxBodyBytes - atTheCap.count))
        XCTAssertNoThrow(try SwitcherReleaseFeed.parse(atTheCap).get())
    }

    /// `state.json` holds a candidate between checks; a hand-edited one cannot point the
    /// download anywhere or change what the file is hashed against.
    func testACandidateReadBackFromStateIsCheckedLikeOneFromTheFeed() throws {
        let good = try SwitcherReleaseFeed.parse(ReleaseFeedFixture.latestV070).get()
        let data = try JSONEncoder().encode(good)
        XCTAssertEqual(try JSONDecoder().decode(ReleaseCandidate.self, from: data), good)
        for (key, value) in [("tag", "v0.7.0/../../evil"), ("tag", "v0.8.0"), ("digestHex", "ABC"),
                             ("assetSize", "0")] as [(String, String)] {
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object[key] = key == "assetSize" ? Int(value)! as Any : value
            let edited = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(ReleaseCandidate.self, from: edited), "\(key)=\(value)")
        }
    }

    // MARK: - Request

    func testTheRequestCarriesExactlyThreeHeadersAndNoCredentials() {
        let request = SwitcherReleaseFeed.request(userAgentVersion: "0.7.0")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/kevinchau/claude-switcher/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2026-03-10",
            "User-Agent": "ClaudeSwitcher/0.7.0 (macOS)",
        ])
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertNil(request.httpBody)
    }

    func testOnlyAVersionGoesIntoTheUserAgent() {
        let request = SwitcherReleaseFeed.request(userAgentVersion: "0.7.0\r\nAuthorization: token x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "ClaudeSwitcher/unknown (macOS)")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testTheSessionHasNoCacheNoCookiesAndNoCredentials() {
        let configuration = SwitcherReleaseFeed.sessionConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertNil(configuration.httpAdditionalHeaders?["Authorization"])
        XCTAssertEqual(SwitcherReleaseFeed.sessionConfiguration(resourceTimeout: 600).timeoutIntervalForResource, 600)
    }

    /// A moved feed is reported where it moved to, and not followed.
    func testARedirectIsReportedAsMovedAndNotFollowed() async {
        let requests = Names()
        let env = SwitcherUpdater.CheckEnvironment(
            fetch: { request in
                requests.append(request.url?.absoluteString ?? "")
                return .response(status: 301, headers: ["Location": "https://api.github.com/repositories/1/releases/latest?x=y"],
                                 body: Data())
            },
            now: { [now] in now })
        let outcome = await SwitcherUpdater.check(runningVersion: v("0.7.0"), env: env)
        XCTAssertEqual(outcome, .feedMoved("api.github.com/repositories/1/releases/latest"))
        XCTAssertEqual(requests.values, ["https://api.github.com/repos/kevinchau/claude-switcher/releases/latest"])
    }

    // MARK: - Outcome by status

    func testEachStatusMeansWhatTheTableSays() {
        let body = ReleaseFeedFixture.latestV070
        guard case .candidate = SwitcherReleaseFeed.outcome(status: 200, headers: [:], body: body, now: now) else {
            return XCTFail("200 with the release should be a candidate")
        }
        guard case .feedChanged = SwitcherReleaseFeed.outcome(status: 200, headers: [:], body: Data("{}".utf8), now: now) else {
            return XCTFail("200 without a release should be a changed feed")
        }
        XCTAssertEqual(SwitcherReleaseFeed.outcome(status: 404, headers: [:], body: nil, now: now), .noRelease)
        XCTAssertEqual(SwitcherReleaseFeed.outcome(status: 410, headers: [:], body: nil, now: now), .apiRetired)
        XCTAssertEqual(SwitcherReleaseFeed.outcome(status: 500, headers: [:], body: nil, now: now), .serverError(500))
        XCTAssertEqual(SwitcherReleaseFeed.outcome(status: 422, headers: [:], body: nil, now: now), .serverError(422))
        XCTAssertEqual(SwitcherReleaseFeed.outcome(status: 304, headers: [:], body: nil, now: now), .feedMoved("an unnamed location"))
        XCTAssertEqual(SwitcherReleaseFeed.outcome(status: 403, headers: [:], body: nil, now: now),
                       .rateLimited(until: now.addingTimeInterval(3600)))
    }

    func testATransportErrorIsOffline() async {
        let now = self.now
        let env = SwitcherUpdater.CheckEnvironment(fetch: { _ in .transport("The Internet connection appears to be offline.") },
                                                   now: { now })
        let outcome = await SwitcherUpdater.check(runningVersion: nil, env: env)
        XCTAssertEqual(outcome, .offline("The Internet connection appears to be offline."))
        XCTAssertEqual(outcome.failureReason, "could not reach api.github.com: The Internet connection appears to be offline.")
    }

    // MARK: - Bounds on a rate limit

    private func until(_ headers: [String: String], status: Int = 429) -> Date? {
        if case .rateLimited(let until) = SwitcherReleaseFeed.outcome(status: status, headers: headers, body: nil, now: now) {
            return until
        }
        return nil
    }

    /// A forged header can postpone the next look by a day at most.
    func testRateLimitDatesAreClampedToADay() {
        let day = now.addingTimeInterval(24 * 3600)
        let tenYears = String(Int(now.timeIntervalSince1970) + 10 * 365 * 24 * 3600)
        XCTAssertEqual(until(["X-RateLimit-Reset": tenYears]), day)
        XCTAssertEqual(until(["x-ratelimit-reset": tenYears], status: 403), day)
        XCTAssertEqual(until(["Retry-After": "999999999"]), now.addingTimeInterval(3600))
        XCTAssertEqual(until(["Retry-After": "86401"]), now.addingTimeInterval(3600))
        XCTAssertEqual(until(["Retry-After": "Fri, 31 Dec 9999 23:59:59 GMT"]), now.addingTimeInterval(3600))
        XCTAssertEqual(until(["x-ratelimit-reset": "99999999999999999999999"]), now.addingTimeInterval(3600))
    }

    func testRateLimitHonoursReasonableHeadersAndWaitsAtLeastAnHour() {
        XCTAssertEqual(until(["Retry-After": "7200"]), now.addingTimeInterval(7200))
        XCTAssertEqual(until(["Retry-After": "60"]), now.addingTimeInterval(3600))
        XCTAssertEqual(until(["x-ratelimit-reset": String(Int(now.timeIntervalSince1970) + 5400)]), now.addingTimeInterval(5400))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(until(["Retry-After": formatter.string(from: now.addingTimeInterval(3 * 3600))]),
                       now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(until(["Retry-After": "soon", "X-RateLimit-Reset": "-5"]), now.addingTimeInterval(3600))
    }

    // MARK: - Redirects of the download

    private func url(_ text: String) -> URL { URL(string: text)! }
    private let origin = URL(string: "https://github.com/kevinchau/claude-switcher/releases/download/v0.8.0/Claude.Switcher.dmg")!

    func testGitHubMaySendTheDownloadToItsAssetHosts() {
        XCTAssertTrue(RedirectPolicy.allows(from: origin, to: url("https://release-assets.githubusercontent.com/x?sig=1"), hop: 1))
        XCTAssertTrue(RedirectPolicy.allows(from: origin, to: url("https://objects.githubusercontent.com/x"), hop: 1))
        XCTAssertTrue(RedirectPolicy.allows(from: origin, to: url("https://github.com/kevinchau/claude-switcher/x"), hop: 1))
        XCTAssertTrue(RedirectPolicy.allows(from: url("https://github.com/a"), to: url("https://release-assets.githubusercontent.com/x"), hop: 2))
    }

    func testEveryOtherHopIsRefused() {
        let assets = url("https://release-assets.githubusercontent.com/x")
        // github.com → github.com only once.
        XCTAssertFalse(RedirectPolicy.allows(from: url("https://github.com/a"), to: url("https://github.com/b"), hop: 2))
        // An asset host's answer is the file or nothing.
        XCTAssertFalse(RedirectPolicy.allows(from: assets, to: url("https://objects.githubusercontent.com/x"), hop: 2))
        XCTAssertFalse(RedirectPolicy.allows(from: assets, to: url("https://github.com/x"), hop: 2))
        XCTAssertFalse(RedirectPolicy.allows(from: url("https://evil.githubusercontent.com/x"), to: assets, hop: 2))
        // Plain http, anywhere.
        XCTAssertFalse(RedirectPolicy.allows(from: origin, to: url("http://release-assets.githubusercontent.com/x"), hop: 1))
        XCTAssertFalse(RedirectPolicy.allows(from: url("http://github.com/a"), to: assets, hop: 1))
        // Look-alike hosts.
        XCTAssertFalse(RedirectPolicy.allows(from: origin, to: url("https://evil.githubusercontent.com/x"), hop: 1))
        XCTAssertFalse(RedirectPolicy.allows(from: origin, to: url("https://release-assets.githubusercontent.com.evil.com/x"), hop: 1))
        XCTAssertFalse(RedirectPolicy.allows(from: origin, to: url("https://github.com.evil.com/x"), hop: 1))
        XCTAssertFalse(RedirectPolicy.allows(from: origin, to: url("https://githubusercontent.com/x"), hop: 1))
        // Ports and user info.
        XCTAssertFalse(RedirectPolicy.allows(from: origin, to: url("https://release-assets.githubusercontent.com:8443/x"), hop: 1))
        XCTAssertFalse(RedirectPolicy.allows(from: origin, to: url("https://user:pw@release-assets.githubusercontent.com/x"), hop: 1))
        XCTAssertFalse(RedirectPolicy.allows(from: origin, to: url("https://user@release-assets.githubusercontent.com/x"), hop: 1))
        // At most three hops.
        XCTAssertFalse(RedirectPolicy.allows(from: url("https://github.com/a"), to: assets, hop: 4))
        XCTAssertFalse(RedirectPolicy.allows(from: url("https://github.com/a"), to: assets, hop: 0))
    }

    // MARK: - Versions

    func testVersionsOrderNumericallyNotAsText() {
        let ordered = ["0.7.0", "0.7.1", "0.8.0", "0.10.0", "1.0.0"].map(v)
        XCTAssertEqual(ordered, ordered.sorted())
        XCTAssertEqual(ordered.shuffled().sorted(), ordered)
        XCTAssertLessThan(v("0.9.0"), v("0.10.0"))
    }

    func testCompareNamesTheThreeCases() {
        XCTAssertEqual(SwitcherUpdatePolicy.compare(candidate: v("0.8.0"), running: v("0.7.0")), .newer)
        XCTAssertEqual(SwitcherUpdatePolicy.compare(candidate: v("0.7.0"), running: v("0.7.0")), .upToDate)
        XCTAssertEqual(SwitcherUpdatePolicy.compare(candidate: v("0.7.0"), running: v("0.9.0")), .runningIsNewer)
    }

    func testAVersionRoundTripsAsItsShortString() throws {
        let version = v("0.12.3")
        XCTAssertEqual(version.tag, "v0.12.3")
        XCTAssertEqual(try JSONDecoder().decode(ReleaseVersion.self, from: JSONEncoder().encode(version)), version)
        XCTAssertThrowsError(try JSONDecoder().decode(ReleaseVersion.self, from: Data(#""0.8""#.utf8)))
    }
}
