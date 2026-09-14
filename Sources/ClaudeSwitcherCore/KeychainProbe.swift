import CryptoKit
import Foundation

/// Read-only probe for the Claude Code CLI's Keychain credential slots.
///
/// ## Service-name derivation
///
/// Transcribed from the shipped `claude` binary (helper `oG`, lightly renamed):
///
/// ```js
/// oG(e = "") {
///     t = env.CLAUDE_SECURESTORAGE_CONFIG_DIR;
///     r = t !== undefined ? !t : !env.CLAUDE_CONFIG_DIR;   // "is default slot"
///     n = t !== undefined ? NFC(t) : configDir();          // string that gets hashed
///     o = r ? "" : "-" + sha256(n).hex.slice(0, 8);
///     return "Claude Code" + OAUTH_FILE_SUFFIX + e + o;
/// }
/// ```
///
/// `OAUTH_FILE_SUFFIX` is the empty string in production builds and `e` is
/// `"-credentials"` at the only call site that matters here, so:
///
/// - `credDir == nil`  -> `"Claude Code-credentials"`
/// - `credDir != nil`  -> `"Claude Code-credentials-" + <first 8 lowercase hex of
///                        sha256(utf8(normalized credDir))>`
///
/// The digest covers **exactly** the string that is handed to the CLI as
/// `CLAUDE_SECURESTORAGE_CONFIG_DIR`, which is why the path is normalized first
/// (`PathNormalizer.normalize`) and the *normalized* form is both hashed here and
/// exported to the child process. Normalizing in one place and hashing in another
/// would silently point at a different Keychain item.
///
/// ### Trap
///
/// The `r` branch keys off **definedness**, not value: `CLAUDE_SECURESTORAGE_CONFIG_DIR`
/// being *set at all* (to a non-empty string) forces the hashed form. So a profile whose
/// `credDir` is `~/.claude` — the very directory the default account uses — still yields
/// a hashed service name such as `Claude Code-credentials-<hash>`, never the plain
/// `Claude Code-credentials`. The default slot is reachable only by omitting the variable
/// entirely, which is modelled here as `credDir == nil`. Never pass an empty string.
///
/// ## Safety
///
/// This type performs **existence checks only**. It never reads, writes, copies or deletes
/// Keychain secrets, and it never passes `-w` to `security` (that flag is what prints the
/// secret material). Any failure degrades silently to "not signed in".
public enum KeychainProbe {

    /// `"Claude Code"` + `OAUTH_FILE_SUFFIX` (empty in production) + the `"-credentials"` argument.
    private static let credentialsServiceBase = "Claude Code-credentials"

    /// Upper bound on how long the `security` probe may run before it is abandoned.
    /// `find-generic-password` without `-w` is a fast attribute lookup, so this only
    /// exists so a wedged process can never pin a caller forever.
    private static let probeTimeout: TimeInterval = 5

    /// The Keychain generic-password service name for a credential slot.
    ///
    /// - Parameter dir: the directory that will be exported as
    ///   `CLAUDE_SECURESTORAGE_CONFIG_DIR`, or `nil` for the default slot (variable omitted).
    /// - Returns: `"Claude Code-credentials"` for `nil`, otherwise
    ///   `"Claude Code-credentials-"` plus the first 8 lowercase hex characters of the
    ///   SHA-256 digest of the normalized path's UTF-8 bytes.
    ///
    /// Pure: no I/O, no environment access, no Keychain access.
    public static func serviceName(forCredDir dir: String?) -> String {
        guard let dir else { return credentialsServiceBase }
        let normalized = PathNormalizer.normalize(dir)
        // An empty value is the DEFAULT slot, not a hash of "". In the CLI the `r` branch is
        // `!t`, so `CLAUDE_SECURESTORAGE_CONFIG_DIR=""` takes the unsuffixed name. Hashing ""
        // here would name a Keychain item the CLI will never look at. We never export an
        // empty value anyway — this keeps a blank config field honest rather than silently
        // pointing at a nonexistent slot.
        guard !normalized.isEmpty else { return credentialsServiceBase }
        return credentialsServiceBase + "-" + sha256Prefix8(normalized)
    }

    /// Whether a credential slot currently holds Claude Code credentials.
    ///
    /// Runs `/usr/bin/security find-generic-password -s <service> -a <user>` and reports only
    /// whether the item exists (exit status 0). Output is discarded; `-w` is never passed, so
    /// no secret material is requested, read or returned. Any thrown error, timeout, or
    /// non-zero status yields `false` — an unknown state is reported as "not signed in".
    ///
    /// - Important: this spawns a subprocess and blocks until it exits (bounded by
    ///   ``probeTimeout``). It is cheap — a few milliseconds in practice — but callers should
    ///   still invoke it **off the main thread** and publish the result back, so a stalled
    ///   `securityd` can never freeze the UI.
    public static func isSignedIn(credDir: String?) -> Bool {
        let service = serviceName(forCredDir: credDir)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // NOTE: never add "-w". That flag prints the secret; existence is all we want.
        process.arguments = ["find-generic-password", "-s", service, "-a", NSUserName()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return false
        }

        if finished.wait(timeout: .now() + probeTimeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return false
        }

        return process.terminationStatus == 0
    }

    /// First 8 lowercase hex characters (4 bytes) of the SHA-256 digest of `string`'s UTF-8 bytes.
    private static func sha256Prefix8(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        let hexDigits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                      "8", "9", "a", "b", "c", "d", "e", "f"]
        var hex = ""
        hex.reserveCapacity(8)
        for byte in digest.prefix(4) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return hex
    }
}
