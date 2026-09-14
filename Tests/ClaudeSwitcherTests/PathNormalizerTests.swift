import XCTest
@testable import ClaudeSwitcherCore

/// Pure-function tests for `PathNormalizer`. No filesystem access: normalization is
/// string arithmetic, and the home directory is always injected explicitly so these
/// tests never depend on the machine they run on.
final class PathNormalizerTests: XCTestCase {

    /// A fixed, fake home. Never `NSHomeDirectory()`.
    private let home = "/Users/testhome"

    private func norm(_ raw: String) -> String {
        PathNormalizer.normalize(raw, home: home)
    }

    /// `String ==` in Swift compares by *canonical equivalence*, so a decomposed and a
    /// precomposed string already compare equal — which means `==` cannot prove that NFC
    /// normalization actually happened. Comparing raw unicode scalars can.
    private func scalars(_ s: String) -> [UInt32] {
        s.unicodeScalars.map(\.value)
    }

    // MARK: - Tilde expansion

    func testBareTildeExpandsToHome() {
        XCTAssertEqual(norm("~"), home)
    }

    func testTildeWithTrailingSlashExpandsToHome() {
        XCTAssertEqual(norm("~/"), home)
    }

    func testTildePathExpandsToHome() {
        XCTAssertEqual(norm("~/x"), "/Users/testhome/x")
        XCTAssertEqual(norm("~/.claude-accounts/work"), "/Users/testhome/.claude-accounts/work")
    }

    func testTildeExpansionUsesTheSuppliedHomeNotTheMachineHome() throws {
        try XCTSkipIf(NSHomeDirectory() == home, "machine home collides with the fixture home")
        XCTAssertFalse(norm("~/x").hasPrefix(NSHomeDirectory()))
    }

    func testTildeInsideThePathIsNotAHomeReference() {
        // Only a *leading* tilde is a home reference.
        XCTAssertEqual(norm("/tmp/~/x"), "/tmp/~/x")
    }

    // MARK: - Trailing slashes

    func testTrailingSlashIsRemoved() {
        XCTAssertEqual(norm("/tmp/x/"), "/tmp/x")
    }

    func testMultipleTrailingSlashesAreRemoved() {
        XCTAssertEqual(norm("/tmp/x///"), "/tmp/x")
    }

    func testRootStaysRoot() {
        XCTAssertEqual(norm("/"), "/")
    }

    func testAllSlashesCollapseToRootAndNotToEmpty() {
        // Trailing-slash removal must never reduce the root to "".
        XCTAssertEqual(norm("///"), "/")
    }

    // MARK: - Duplicate slashes

    func testDuplicateSlashesAreCollapsed() {
        XCTAssertEqual(norm("/tmp//x"), "/tmp/x")
        XCTAssertEqual(norm("/tmp///x////y"), "/tmp/x/y")
    }

    func testDuplicateAndTrailingSlashesTogether() {
        XCTAssertEqual(norm("//tmp//x//"), "/tmp/x")
    }

    // MARK: - Absolute / relative / empty

    func testAlreadyNormalAbsolutePathIsUnchanged() {
        XCTAssertEqual(norm("/Users/u/Library/Application Support/Claude-Work"),
                       "/Users/u/Library/Application Support/Claude-Work")
    }

    func testPathWithSpacesIsPreserved() {
        XCTAssertEqual(norm("/Users/u/Library/Application Support/Claude-Work/"),
                       "/Users/u/Library/Application Support/Claude-Work")
    }

    func testRelativePathResolvesAgainstHome() {
        XCTAssertEqual(norm("foo/bar"), "/Users/testhome/foo/bar")
        XCTAssertEqual(norm("foo"), "/Users/testhome/foo")
    }

    func testRelativePathWithTrailingSlashResolvesAgainstHome() {
        XCTAssertEqual(norm("foo/bar/"), "/Users/testhome/foo/bar")
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(norm(""), "")
    }

    // MARK: - NFC

    func testDecomposedInputIsNormalizedToPrecomposedNFC() {
        let decomposed = "/tmp/caf\u{65}\u{301}"   // "e" + COMBINING ACUTE ACCENT
        let precomposed = "/tmp/caf\u{e9}"         // "é"

        // Sanity check on the fixtures themselves: they differ at the scalar level even
        // though Swift's `==` considers them equal.
        XCTAssertNotEqual(scalars(decomposed), scalars(precomposed))

        XCTAssertEqual(scalars(norm(decomposed)), scalars(norm(precomposed)))
        XCTAssertEqual(scalars(norm(decomposed)), scalars(precomposed),
                       "normalize() must emit NFC (precomposed) form")
    }

    func testNFCNormalizationAppliesToTheExpandedHomeToo() {
        let decomposedHome = "/Users/caf\u{65}\u{301}"
        let expected = "/Users/caf\u{e9}/x"
        XCTAssertEqual(scalars(PathNormalizer.normalize("~/x", home: decomposedHome)),
                       scalars(expected))
    }

    // MARK: - Idempotency

    func testNormalizeIsIdempotent() {
        let inputs = [
            "~",
            "~/",
            "~/x",
            "~/.claude-accounts/work",
            "/",
            "///",
            "/tmp/x",
            "/tmp/x/",
            "/tmp//x///y//",
            "/Users/u/Library/Application Support/Claude-Work/",
            "foo/bar",
            "",
            "/tmp/caf\u{65}\u{301}",
        ]
        for input in inputs {
            let once = norm(input)
            let twice = norm(once)
            XCTAssertEqual(scalars(twice), scalars(once),
                           "normalize is not idempotent for \(String(reflecting: input))")
        }
    }
}
