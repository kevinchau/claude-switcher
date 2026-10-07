import Foundation

/// Why one step of an update did not go ahead.
///
/// A permanent refusal is about the release itself (its digest, signature, identity, version,
/// host or layout): that release file is never tried again automatically. A transient one is
/// about the moment (network, timeout, a busy disk image, disk space, a launch) and only
/// postpones the next attempt.
public struct Refusal: Error, Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable { case permanent, transient }

    public let kind: Kind
    public let step: String
    public let reason: String
    /// `false` when nothing was really tried: not enough free space, a network error before the
    /// first byte, an attach timeout whose image was cleaned up. The backoff is left as it was.
    public let countsAsAttempt: Bool

    public init(kind: Kind, step: String, reason: String, countsAsAttempt: Bool = true) {
        self.kind = kind
        self.step = step
        self.reason = reason
        self.countsAsAttempt = countsAsAttempt
    }

    public static func permanent(_ step: PrepareStep, _ reason: String) -> Refusal {
        Refusal(kind: .permanent, step: step.rawValue, reason: reason)
    }

    public static func transient(_ step: PrepareStep, _ reason: String, countsAsAttempt: Bool = true) -> Refusal {
        Refusal(kind: .transient, step: step.rawValue, reason: reason, countsAsAttempt: countsAsAttempt)
    }
}

/// The steps of a prepare, in the order they run. The order is what "got further than last time"
/// means for the backoff.
public enum PrepareStep: String, Sendable, Codable, CaseIterable {
    case versionGate, freeSpace, download, size, digest, imageSignature, imageRequirement, license, attach, layout,
         mountedSignature, mountedRequirement, mountedIdentity, copy, detach, quarantine, stagedSignature,
         stagedRequirement, stagedIdentity, assess, prewarm, volume

    public var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// The steps of a commit, by their names in the design.
public enum CommitStep: String, Sendable, Codable, CaseIterable {
    case proveTarget = "C1", versions = "C2", reverify = "C3", idleRecheck = "C3'", handoff = "C4", swap = "C5",
         verifyInstalled = "C6", register = "C7", relaunch = "C8", oldCopy = "C9", launched = "C10"
}

/// A verified copy of the new version, staged next to the installed one, waiting for its moment.
public struct PreparedUpdate: Equatable, Sendable, Codable {
    public let stagedAppPath: String
    public let dmgPath: String
    public let candidate: ReleaseCandidate
    public let verifiedIdentity: CodeIdentity
    public let verifiedAt: Date

    public init(stagedAppPath: String, dmgPath: String, candidate: ReleaseCandidate, verifiedIdentity: CodeIdentity,
                verifiedAt: Date) {
        self.stagedAppPath = stagedAppPath
        self.dmgPath = dmgPath
        self.candidate = candidate
        self.verifiedIdentity = verifiedIdentity
        self.verifiedAt = verifiedAt
    }

    public var version: ReleaseVersion { candidate.version }
}

// MARK: - state.json

public struct Rejection: Equatable, Sendable, Codable {
    public let tag: String
    public let digestHex: String
    public let reason: String
    public let at: Date

    public init(tag: String, digestHex: String, reason: String, at: Date) {
        self.tag = tag
        self.digestHex = digestHex
        self.reason = reason
        self.at = at
    }
}

/// The backoff for one release file after transient refusals.
public struct AttemptRecord: Equatable, Sendable, Codable {
    public let count: Int
    public let lastStep: String
    public let nextNotBefore: Date

    public init(count: Int, lastStep: String, nextNotBefore: Date) {
        self.count = count
        self.lastStep = lastStep
        self.nextNotBefore = nextNotBefore
    }
}

/// Where the copy that was replaced went.
public struct OldCopy: Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable { case previous, trash, staging }
    public let kind: Kind
    public let path: String

    public init(kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }
}

public struct InstallRecord: Equatable, Sendable, Codable {
    public let from: ReleaseVersion
    public let to: ReleaseVersion
    public let at: Date
    public let oldCopy: OldCopy?
    public let tag: String?
    public let digest: String?
    public let kind: UpdateHandoff.Kind?

    public init(from: ReleaseVersion, to: ReleaseVersion, at: Date, oldCopy: OldCopy?, tag: String?, digest: String?,
                kind: UpdateHandoff.Kind? = .update) {
        self.from = from
        self.to = to
        self.at = at
        self.oldCopy = oldCopy
        self.tag = tag
        self.digest = digest
        self.kind = kind
    }
}

public struct FailureRecord: Equatable, Sendable, Codable {
    public let tag: String?
    /// The release file's digest: a rejection is of one file, and a new one under the same tag
    /// is tried again.
    public let digest: String?
    public let step: String
    public let reason: String
    public let at: Date

    public init(tag: String?, digest: String? = nil, step: String, reason: String, at: Date) {
        self.tag = tag
        self.digest = digest
        self.step = step
        self.reason = reason
        self.at = at
    }
}

/// A one-shot line for the top of the menu.
public struct SwitcherNotice: Equatable, Sendable, Codable {
    public var text: String
    public var tooltip: String?
    public var shown: Bool

    public init(text: String, tooltip: String? = nil, shown: Bool = false) {
        self.text = text
        self.tooltip = tooltip
        self.shown = shown
    }
}

/// `updates/state.json`. Every field is optional: a missing one reads as "never happened".
public struct SwitcherUpdateState: Equatable, Sendable, Codable {
    public static let currentFormat = 1

    public var format: Int?
    public var host: String?
    public var installPath: String?
    public var lastCheckAt: Date?
    public var lastCheckResult: CheckOutcome?
    public var nextCheckNotBefore: Date?
    public var candidate: ReleaseCandidate?
    /// Informational: a staged copy belongs to the process that made it, and a later process
    /// prepares again rather than trust a path read from this file.
    public var prepared: PreparedUpdate?
    public var rejected: [Rejection]?
    public var consecutivePermanentRejections: Int?
    public var downloadsPaused: Bool?
    public var attempts: [String: AttemptRecord]?
    public var lastInstall: InstallRecord?
    public var lastFailure: FailureRecord?
    /// Informational; `hdiutil info` is what decides which images are ours.
    public var mounted: String?
    /// The staging folders of prepares in flight and of verified copies kept — one per copy of
    /// Claude Switcher that made one, each added and removed only by that copy
    /// (``apply(_:)``); handled at the next launch only through the NSIRD predicate.
    public var staging: [String]?
    public var notice: SwitcherNotice?
    public var relaunchFindings: [String]?
    public var foreignRecordsSeen: Bool?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case format, host, installPath, lastCheckAt, lastCheckResult, nextCheckNotBefore, candidate, prepared, rejected,
             consecutivePermanentRejections, downloadsPaused, attempts, lastInstall, lastFailure, mounted, staging, notice,
             relaunchFindings, foreignRecordsSeen
    }

    /// Field by field: a field that does not read (a hand edit, a candidate that fails its own
    /// checks) is dropped on its own instead of taking every rejection and date with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try? c.decodeIfPresent(Int.self, forKey: .format)
        host = try? c.decodeIfPresent(String.self, forKey: .host)
        installPath = try? c.decodeIfPresent(String.self, forKey: .installPath)
        lastCheckAt = try? c.decodeIfPresent(Date.self, forKey: .lastCheckAt)
        lastCheckResult = try? c.decodeIfPresent(CheckOutcome.self, forKey: .lastCheckResult)
        nextCheckNotBefore = try? c.decodeIfPresent(Date.self, forKey: .nextCheckNotBefore)
        candidate = try? c.decodeIfPresent(ReleaseCandidate.self, forKey: .candidate)
        prepared = try? c.decodeIfPresent(PreparedUpdate.self, forKey: .prepared)
        rejected = try? c.decodeIfPresent([Rejection].self, forKey: .rejected)
        consecutivePermanentRejections = try? c.decodeIfPresent(Int.self, forKey: .consecutivePermanentRejections)
        downloadsPaused = try? c.decodeIfPresent(Bool.self, forKey: .downloadsPaused)
        attempts = try? c.decodeIfPresent([String: AttemptRecord].self, forKey: .attempts)
        lastInstall = try? c.decodeIfPresent(InstallRecord.self, forKey: .lastInstall)
        lastFailure = try? c.decodeIfPresent(FailureRecord.self, forKey: .lastFailure)
        mounted = try? c.decodeIfPresent(String.self, forKey: .mounted)
        // Written as a single path before more than one copy's folder was kept.
        staging = (try? c.decodeIfPresent([String].self, forKey: .staging))
            ?? (try? c.decodeIfPresent(String.self, forKey: .staging)).map { [$0] }
        notice = try? c.decodeIfPresent(SwitcherNotice.self, forKey: .notice)
        relaunchFindings = try? c.decodeIfPresent([String].self, forKey: .relaunchFindings)
        foreignRecordsSeen = try? c.decodeIfPresent(Bool.self, forKey: .foreignRecordsSeen)
    }

    public func isRejected(_ candidate: ReleaseCandidate) -> Bool {
        isRejected(tag: candidate.tag, digest: candidate.digestHex)
    }

    public func isRejected(tag: String, digest: String) -> Bool {
        (rejected ?? []).contains { $0.tag == tag && $0.digestHex == digest }
    }

    public var rateLimitedUntil: Date? {
        if case .rateLimited(let until) = lastCheckResult { return until }
        return nil
    }
}

// MARK: - handoff.json and starting.json

/// What the process replacing itself leaves for the one it starts, written before the swap and
/// updated at each phase.
public struct UpdateHandoff: Equatable, Sendable, Codable {
    public enum Phase: String, Equatable, Sendable, Codable { case swapping, swapped, restartPending, launched, rolledBack }
    public enum Kind: String, Equatable, Sendable, Codable { case update, revert }

    public static let currentFormat = 1

    public var format: Int
    public var host: String
    public var phase: Phase
    public var kind: Kind
    public var from: ReleaseVersion
    public var to: ReleaseVersion
    /// The release concerned: for an update the new one, for a revert the one being left.
    public var tag: String
    public var digest: String
    public var installPath: String
    public var stagedPath: String?
    public var oldCopy: OldCopy?
    public var oldPid: Int32?
    public var newPid: Int32?
    public var startedAt: Date
    public var launchAtLoginWasEnabled: Bool?
    public var failure: String?

    public init(host: String, phase: Phase, kind: Kind, from: ReleaseVersion, to: ReleaseVersion, tag: String,
                digest: String, installPath: String, stagedPath: String?, oldPid: Int32?, startedAt: Date,
                launchAtLoginWasEnabled: Bool?) {
        self.format = Self.currentFormat
        self.host = host
        self.phase = phase
        self.kind = kind
        self.from = from
        self.to = to
        self.tag = tag
        self.digest = digest
        self.installPath = installPath
        self.stagedPath = stagedPath
        self.oldPid = oldPid
        self.startedAt = startedAt
        self.launchAtLoginWasEnabled = launchAtLoginWasEnabled
    }
}

/// `starting.json`: written at every start and deleted once the app has been up for a minute.
/// Its count is the number of starts of this version that never got that far.
public struct StartMarker: Equatable, Sendable, Codable {
    public static let currentFormat = 1

    public var format: Int
    public var version: ReleaseVersion?
    public var host: String
    public var installPath: String
    public var count: Int
    public var at: Date

    public init(version: ReleaseVersion?, host: String, installPath: String, count: Int, at: Date) {
        self.format = Self.currentFormat
        self.version = version
        self.host = host
        self.installPath = installPath
        self.count = count
        self.at = at
    }
}

/// A record file as read: missing, readable, or there but not understood — which is reported
/// and left alone, never acted on.
public enum RecordRead<Value: Equatable & Sendable>: Equatable, Sendable {
    case absent
    case record(Value)
    case unreadable(String)

    public var value: Value? {
        if case .record(let value) = self { return value }
        return nil
    }
}
