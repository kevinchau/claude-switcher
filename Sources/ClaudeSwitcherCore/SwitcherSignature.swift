import Foundation
import Security

/// Who signed a piece of code, as its signature says.
public struct CodeIdentity: Sendable, Equatable, Codable {
    public let teamID: String?
    public let identifier: String?
    public let flags: UInt32
    /// The sealed `CFBundleShortVersionString` (`kSecCodeInfoPList`): bound by the signature, so
    /// it cannot be edited without the check failing.
    public let version: ReleaseVersion?
    public let path: String?

    public init(teamID: String?, identifier: String?, flags: UInt32, version: ReleaseVersion?, path: String?) {
        self.teamID = teamID
        self.identifier = identifier
        self.flags = flags
        self.version = version
        self.path = path
    }

    public var isAdHoc: Bool { flags & 0x2 != 0 }
    public var hasHardenedRuntime: Bool { flags & 0x10000 != 0 }
}

/// A signature check that did not pass, with the Security framework's status.
public struct SignatureRefusal: Error, Equatable, Sendable {
    public let status: Int32
    public let message: String

    public init(status: Int32, message: String) {
        self.status = status
        self.message = message
    }
}

/// Whether the running copy is notarized, as far as it could be told.
public enum NotarizationVerdict: Equatable, Sendable {
    case accepted
    case rejected
    case unknown(OSStatus)
}

/// The running copy's notarization, remembered once it is settled. A verdict that could not be
/// reached (`.unknown`) is asked again next time: one slow or offline check must not decide for
/// the life of a login item.
public struct NotarizationMemo: Equatable, Sendable {
    public private(set) var settled: NotarizationVerdict?

    public init() {}

    public mutating func verdict(_ evaluate: () -> NotarizationVerdict) -> NotarizationVerdict {
        if let settled { return settled }
        let verdict = evaluate()
        if case .unknown = verdict { return verdict }
        settled = verdict
        return verdict
    }
}

/// The Security framework calls behind every signature decision. Team and identifier always
/// come from the running copy's own signature (``SwitcherTrust``), never from a literal.
public enum CodeSignature {

    public enum RequirementError: Error, Equatable {
        case invalidTeam(String)
        case invalidIdentifier(String)
    }

    /// Every architecture, nested code, strict (no unsealed files at the bundle root), no
    /// symlink out of the bundle, no sideband data. Nothing that skips resources or the
    /// executable, and the network is left allowed so notarization and revocation are real.
    public static let validationFlags = SecCSFlags(rawValue:
        UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSStrictValidate)
            | UInt32(kSecCSRestrictSymlinks) | UInt32(kSecCSRestrictSidebandData))

    /// The same, kept off the network: only for a look that must fetch nothing — `--dry-run` and
    /// the tests. Never what a prepare, a commit or a revert checks with.
    public static let offlineFlags = SecCSFlags(rawValue: validationFlags.rawValue | SecCSFlags.noNetworkAccess.rawValue)

    /// Flags that would let a modified or unverified copy through. Never part of a check.
    public static let forbiddenFlags: UInt32 = UInt32(kSecCSDoNotValidateResources) | UInt32(kSecCSDoNotValidateExecutable)
        | UInt32(kSecCSBasicValidateOnly) | SecCSFlags.noNetworkAccess.rawValue

    /// errSecCSReqFailed: the code is valid but does not satisfy the requirement.
    public static let requirementFailed: OSStatus = -67050

    private static let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    /// Developer ID, this team, this identifier, notarized.
    public static func requirementForApp(team: String, identifier: String) throws -> String {
        developerID + " and certificate leaf[subject.OU] = \"\(try validTeam(team))\""
            + " and identifier \"\(try validIdentifier(identifier))\" and notarized"
    }

    /// The disk image is signed by the same team, under a name taken from its file; only the
    /// team is pinned.
    public static func requirementForImage(team: String) throws -> String {
        developerID + " and certificate leaf[subject.OU] = \"\(try validTeam(team))\" and notarized"
    }

    // Both go into requirement text between quotes; nothing that could close the quote passes.
    private static func validTeam(_ team: String) throws -> String {
        guard Pattern.matches("^[A-Z0-9]{10}$", team) else { throw RequirementError.invalidTeam(team) }
        return team
    }

    private static func validIdentifier(_ identifier: String) throws -> String {
        guard Pattern.matches("^[A-Za-z0-9.-]+$", identifier) else { throw RequirementError.invalidIdentifier(identifier) }
        return identifier
    }

    /// Checks the code at `path` — an app bundle or a disk image — and, when it passes, reads who
    /// signed it. Only call it on something that is not being written at the same time.
    public static func verify(bundleAt path: String, requirement: String?, flags: SecCSFlags = validationFlags)
        -> Result<CodeIdentity, SignatureRefusal> {
        var created: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &created)
        guard status == errSecSuccess, let code = created else { return .failure(refusal(status)) }

        var compiled: SecRequirement?
        if let requirement {
            var errors: Unmanaged<CFError>?
            let compileStatus = SecRequirementCreateWithStringAndErrors(requirement as CFString, [], &errors, &compiled)
            errors?.release()
            guard compileStatus == errSecSuccess, compiled != nil else { return .failure(refusal(compileStatus)) }
        }

        let validity = checkValidity(code, flags, compiled)
        guard validity == errSecSuccess else { return .failure(refusal(validity)) }

        guard let identity = identity(of: code, path: path) else {
            return .failure(SignatureRefusal(status: errSecCSInternalError, message: "its signature could not be read"))
        }
        return .success(identity)
    }

    /// A signature check, as the updater's environments hold it.
    public typealias Verify = @Sendable (_ path: String, _ requirement: String?) -> Result<CodeIdentity, SignatureRefusal>

    /// The one signature check the real prepare and commit environments both use, so that one
    /// test of it covers both: the requirement handed to it, with `flags`.
    public static func verifier(flags: SecCSFlags = validationFlags) -> Verify {
        { path, requirement in verify(bundleAt: path, requirement: requirement, flags: flags) }
    }

    /// The running process's own signature, read once at launch: after a swap `Bundle.main`
    /// names the new bundle, while this still describes the code that is running.
    public static func runningIdentity() -> CodeIdentity? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code else { return nil }
        var url: CFURL?
        let path = SecCodeCopyPath(code, [], &url) == errSecSuccess ? (url as URL?)?.path : nil
        return identity(of: code, path: path)
    }

    /// The running copy against its own team, identifier and `notarized`, in-process. A stapled
    /// release passes offline too; spctl is never run on the running copy. `--dry-run` asks with
    /// ``offlineFlags`` and nothing is fetched: a copy whose ticket is neither stapled nor cached
    /// by macOS then fails the requirement (-67050) and reads as rejected.
    public static func runningNotarization(trust: SwitcherTrust, flags: SecCSFlags = validationFlags) -> NotarizationVerdict {
        runningNotarization(trust: trust, flags: flags, check: checkValidity)
    }

    /// The one call that checks code: exactly the flags and the requirement it is handed.
    static func checkValidity(_ code: SecStaticCode, _ flags: SecCSFlags, _ requirement: SecRequirement?) -> OSStatus {
        var errors: Unmanaged<CFError>?
        defer { errors?.release() }
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &errors)
    }

    /// The same, with the validity check given: what a test watches to see which flags and which
    /// requirement reach it.
    static func runningNotarization(trust: SwitcherTrust, flags: SecCSFlags,
                                    check: (SecStaticCode, SecCSFlags, SecRequirement?) -> OSStatus) -> NotarizationVerdict {
        guard let requirement = try? requirementForApp(team: trust.teamID, identifier: trust.identifier) else {
            return .rejected
        }
        var me: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code
        else { return .unknown(errSecCSInternalError) }
        var compiled: SecRequirement?
        var compileErrors: Unmanaged<CFError>?
        let compileStatus = SecRequirementCreateWithStringAndErrors(requirement as CFString, [], &compileErrors, &compiled)
        compileErrors?.release()
        guard compileStatus == errSecSuccess, let compiled else { return .unknown(compileStatus) }
        return verdict(for: check(code, flags, compiled))
    }

    /// The code was not there to be checked — gone from under the check, as when another copy
    /// detached the disk image or removed the folder. That says nothing about the release.
    public static let vanishedStatuses: Set<Int32> = [errSecCSStaticCodeNotFound, ENOENT]

    public static func verdict(for status: OSStatus) -> NotarizationVerdict {
        switch status {
        case errSecSuccess: return .accepted
        case requirementFailed: return .rejected
        default: return .unknown(status)
        }
    }

    private static func identity(of code: SecStaticCode, path: String?) -> CodeIdentity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        let plist = dictionary[kSecCodeInfoPList as String] as? [String: Any]
        return CodeIdentity(
            teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            flags: (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0,
            version: (plist?["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init(string:)),
            path: path)
    }

    private static func refusal(_ status: OSStatus) -> SignatureRefusal {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "code signature error"
        return SignatureRefusal(status: status, message: "\(text) (\(status))")
    }
}
