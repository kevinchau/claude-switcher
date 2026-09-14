import XCTest
@testable import ClaudeSwitcherCore

/// Tests ONLY the pure service-name derivation. `isSignedIn` shells out to
/// `security(1)` and is deliberately never called here — no Keychain access,
/// no subprocesses, no network.
final class KeychainProbeTests: XCTestCase {

    private let defaultName = "Claude Code-credentials"
    private let hashedPrefix = "Claude Code-credentials-"

    // MARK: - Default slot

    func testNilCredDirYieldsTheDefaultServiceName() {
        XCTAssertEqual(KeychainProbe.serviceName(forCredDir: nil), defaultName)
    }

    // MARK: - Known-good vectors
    //
    // Each expected suffix is the first 8 lowercase hex characters of
    // sha256(NFC-normalized path).

    func testKnownGoodVectors() {
        let vectors: [(dir: String, expected: String)] = [
            ("/Users/example/.claude-accounts/secondary",       "Claude Code-credentials-f656dede"),
            ("/Users/example/.claude-accounts/work",            "Claude Code-credentials-ce139327"),
            ("/tmp/x",                                           "Claude Code-credentials-2e56aa36"),
            ("/Users/u/Library/Application Support/Claude-Work", "Claude Code-credentials-d3bccdd1"),
        ]
        for vector in vectors {
            XCTAssertEqual(KeychainProbe.serviceName(forCredDir: vector.dir),
                           vector.expected,
                           "wrong service name for \(vector.dir)")
        }
    }

    // MARK: - Shape of a hashed name

    func testHashedNameIsPrefixPlusEightLowercaseHexCharacters() {
        let name = KeychainProbe.serviceName(forCredDir: "/tmp/x")
        XCTAssertTrue(name.hasPrefix(hashedPrefix), "unexpected prefix in \(name)")

        let suffix = String(name.dropFirst(hashedPrefix.count))
        XCTAssertEqual(suffix.count, 8, "hash suffix must be exactly 8 characters")
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                      "hash suffix must be lowercase hex, got \(suffix)")
    }

    // MARK: - Normalization happens before hashing

    func testTrailingSlashYieldsTheSameServiceName() {
        XCTAssertEqual(KeychainProbe.serviceName(forCredDir: "/tmp/x/"),
                       KeychainProbe.serviceName(forCredDir: "/tmp/x"))
        XCTAssertEqual(KeychainProbe.serviceName(forCredDir: "/tmp/x/"),
                       "Claude Code-credentials-2e56aa36")
    }

    func testDuplicateSlashesYieldTheSameServiceName() {
        XCTAssertEqual(KeychainProbe.serviceName(forCredDir: "//tmp//x"),
                       "Claude Code-credentials-2e56aa36")
    }

    func testDecomposedAndPrecomposedPathsHashIdentically() {
        // The hash covers the NFC-normalized string, so these must collide.
        XCTAssertEqual(KeychainProbe.serviceName(forCredDir: "/tmp/caf\u{65}\u{301}"),
                       KeychainProbe.serviceName(forCredDir: "/tmp/caf\u{e9}"))
    }

    func testTildeSpellingMatchesTheAbsoluteSpelling() {
        let absolute = NSHomeDirectory() + "/.claude-accounts/work"
        XCTAssertEqual(KeychainProbe.serviceName(forCredDir: "~/.claude-accounts/work"),
                       KeychainProbe.serviceName(forCredDir: absolute))
    }

    // MARK: - The documented trap

    func testCredDirPointingAtDotClaudeStillHashes() {
        // The shipped derivation branches on whether CLAUDE_SECURESTORAGE_CONFIG_DIR is
        // *defined*, not on its value. So a profile explicitly pointed at ~/.claude gets a
        // HASHED service name — it does NOT collapse back to the default slot.
        let dotClaude = NSHomeDirectory() + "/.claude"
        let name = KeychainProbe.serviceName(forCredDir: dotClaude)

        XCTAssertNotEqual(name, defaultName,
                          "a non-nil credDir must never produce the default service name")
        XCTAssertTrue(name.hasPrefix(hashedPrefix))
        XCTAssertEqual(name, KeychainProbe.serviceName(forCredDir: "~/.claude"))
    }

    func testEveryDistinctDirectoryGetsADistinctServiceName() {
        let names = Set([
            KeychainProbe.serviceName(forCredDir: nil),
            KeychainProbe.serviceName(forCredDir: "/tmp/x"),
            KeychainProbe.serviceName(forCredDir: "/tmp/y"),
            KeychainProbe.serviceName(forCredDir: "/Users/example/.claude-accounts/work"),
            KeychainProbe.serviceName(forCredDir: "/Users/example/.claude-accounts/secondary"),
        ])
        XCTAssertEqual(names.count, 5)
    }
}
