import Foundation

/// What one check means for the app, and when the next one is due.
public struct Decision: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Download and verify this release (harmless: nothing outside `updates/` and a private
        /// staging folder is written).
        case prepare(ReleaseCandidate)
        case upToDate(running: ReleaseVersion, latest: ReleaseVersion)
        case runningIsNewer(running: ReleaseVersion, latest: ReleaseVersion)
        /// A manual check in a copy with no trust anchor: a newer tag exists and nothing can vouch for it.
        case cannotVerify(tag: String, reason: String)
        /// A manual check whose request did not produce a release.
        case checkFailed(String)
        /// An automatic check that leads to nothing, and why.
        case nothing(String)
    }

    public let action: Action
    public let nextCheckNotBefore: Date

    public init(action: Action, nextCheckNotBefore: Date) {
        self.action = action
        self.nextCheckNotBefore = nextCheckNotBefore
    }
}

public enum Comparison: Equatable, Sendable { case newer, upToDate, runningIsNewer }

/// What a start that follows two aborted starts should do.
public struct RevertPlan: Equatable, Sendable {
    /// The version that did not start properly (the running one).
    public let from: ReleaseVersion
    /// The version to go back to.
    public let to: ReleaseVersion
    /// The release that did not start properly, to be rejected.
    public let tag: String
    public let digest: String

    public init(from: ReleaseVersion, to: ReleaseVersion, tag: String, digest: String) {
        self.from = from
        self.to = to
        self.tag = tag
        self.digest = digest
    }
}

public enum RevertDecision: Equatable, Sendable {
    case none
    case revert(RevertPlan)
}

/// Why a commit may not start now. Checked in one main-actor turn, before anything is moved.
public enum CommitHold: Equatable, Sendable {
    case nothingPrepared
    case notNewer
    case checksOnly(ChecksOnlyReason)
    /// A manual install in a copy that does not hold the lock gets the app's existing
    /// "another Claude Switcher is running" message.
    case notLockHolder
    case settingOff
    case configBroken
    case notIdle([SwitcherIdle.Blocker])

    public var reason: String {
        switch self {
        case .nothingPrepared: return "no verified release is waiting"
        case .notNewer: return "the release waiting is not newer than this copy"
        case .checksOnly(let reason): return "this copy never replaces itself: \(reason.message)"
        case .notLockHolder: return "another Claude Switcher is running"
        case .settingOff: return "Keep Claude Switcher Up to Date is off"
        case .configBroken: return "config.json cannot be read"
        case .notIdle(let blockers): return blockers.first?.description ?? "something is going on"
        }
    }
}

/// The rules, without effects.
public enum SwitcherUpdatePolicy {

    public static let pauseAfterRejections = 3

    /// The first automatic check after a launch, the loop that looks whether one is due, and
    /// the pause after a wake before looking.
    public static let firstCheckDelay: Duration = .seconds(180)
    public static let dueCheckInterval: Duration = .seconds(1800)
    public static let wakeCheckDelay: Duration = .seconds(30)

    // MARK: Versions

    public static func compare(candidate: ReleaseVersion, running: ReleaseVersion) -> Comparison {
        if candidate > running { return .newer }
        if candidate == running { return .upToDate }
        return .runningIsNewer
    }

    // MARK: Installability

    /// Whether this copy may replace itself. Pure but for `canonical`, which resolves the two
    /// allowed folders the way the running copy's own folder was resolved when it was read; the
    /// first reason that applies wins.
    public static func installability(of copy: RunningCopy, notarization: NotarizationVerdict,
                                      home: String = NSHomeDirectory(),
                                      canonical: (String) -> String? = SwitcherDisk.realpath) -> Installability {
        let identity = copy.identity
        if identity.teamID == nil { return .checksOnly(.noTeam) }
        if identity.isAdHoc { return .checksOnly(.adHoc) }
        if !identity.hasHardenedRuntime { return .checksOnly(.noHardenedRuntime) }
        guard let identifier = identity.identifier, let bundleIdentifier = copy.bundleIdentifier,
              identifier == bundleIdentifier
        else { return .checksOnly(.identifierMismatch) }
        if identity.version == nil { return .checksOnly(.noVersion) }
        if (copy.bundlePath as NSString).pathExtension != "app" { return .checksOnly(.notAnAppBundle) }
        if copy.isTranslocated { return .checksOnly(.translocated) }
        if copy.volumeIsReadOnly { return .checksOnly(.readOnlyVolume) }
        // A signature cannot tell build/Claude Switcher.app from the installed copy; where it is can.
        // The parent was read with links resolved, so the allowed folders are compared resolved too:
        // a home reached through a link still has its own ~/Applications.
        let allowed = ["/Applications", PathNormalizer.normalize(home) + "/Applications"].map { folder in
            canonical(folder) ?? PathNormalizer.normalize(folder)
        }
        if !allowed.contains(copy.parentDirectory) { return .checksOnly(.notInApplications(copy.parentDirectory)) }
        if !copy.bundleIsWritable || !copy.parentIsWritable { return .checksOnly(.notWritable) }
        if copy.processExecutablePath != copy.executablePath { return .checksOnly(.movedSinceLaunch) }
        switch notarization {
        case .accepted: return .installable
        case .rejected: return .checksOnly(.notNotarized)
        case .unknown: return .checksOnly(.notarizationUnconfirmed)
        }
    }

    // MARK: Scheduling

    /// When the next automatic check may run after `outcome`. Never more than a day ahead.
    public static func nextCheck(after outcome: CheckOutcome, now: Date) -> Date {
        let delay: TimeInterval
        switch outcome {
        case .candidate, .noRelease, .feedMoved, .feedChanged: delay = SwitcherReleaseFeed.checkInterval
        case .rateLimited(let until):
            delay = max(until.timeIntervalSince(now), SwitcherReleaseFeed.retryInterval)
        case .apiRetired: delay = SwitcherReleaseFeed.maximumDelay
        case .serverError, .offline: delay = SwitcherReleaseFeed.retryInterval
        }
        return now.addingTimeInterval(min(delay, SwitcherReleaseFeed.maximumDelay))
    }

    /// Whether an automatic check is due. Off means never. A date further ahead than any this
    /// code writes — a clock that was wrong, a hand edit, a forged header — means "due now".
    public static func isDue(state: SwitcherUpdateState, now: Date, settingOn: Bool) -> Bool {
        guard settingOn else { return false }
        if hasCorruptSchedule(state, now: now) { return true }
        guard let next = state.nextCheckNotBefore else { return true }
        return now >= next
    }

    static func hasCorruptSchedule(_ state: SwitcherUpdateState, now: Date) -> Bool {
        let limit = now.addingTimeInterval(SwitcherReleaseFeed.maximumDelay)
        if let next = state.nextCheckNotBefore, next > limit { return true }
        if let last = state.lastCheckAt, last > now { return true }
        if let until = state.rateLimitedUntil, until > limit { return true }
        return false
    }

    /// The state with every date that lies too far ahead dropped. Applied whenever it is loaded.
    public static func sanitized(_ state: SwitcherUpdateState, now: Date) -> SwitcherUpdateState {
        var state = state
        let limit = now.addingTimeInterval(SwitcherReleaseFeed.maximumDelay)
        if hasCorruptSchedule(state, now: now) {
            state.nextCheckNotBefore = nil
            if let last = state.lastCheckAt, last > now { state.lastCheckAt = nil }
            if let until = state.rateLimitedUntil, until > limit { state.lastCheckResult = nil }
        }
        if let attempts = state.attempts {
            state.attempts = attempts.mapValues { record in
                record.nextNotBefore > limit
                    ? AttemptRecord(count: record.count, lastStep: record.lastStep, nextNotBefore: now) : record
            }
        }
        return state
    }

    // MARK: The decision after a check

    public static func decision(state: SwitcherUpdateState, outcome: CheckOutcome, runningVersion: ReleaseVersion?,
                                trust: SwitcherTrust?, installability: Installability, settingOn: Bool,
                                isLockHolder: Bool, configIsValid: Bool, manual: Bool, now: Date) -> Decision {
        let next = nextCheck(after: outcome, now: now)
        func decide(_ action: Decision.Action) -> Decision { Decision(action: action, nextCheckNotBefore: next) }

        guard case .candidate(let candidate) = outcome else {
            let reason = outcome.failureReason ?? "no release"
            return decide(manual ? .checkFailed(reason) : .nothing(reason))
        }
        guard let running = trust?.runningVersion ?? runningVersion else {
            return decide(manual ? .cannotVerify(tag: candidate.tag, reason: ChecksOnlyReason.noVersion.message)
                                 : .nothing(ChecksOnlyReason.noVersion.message))
        }
        switch compare(candidate: candidate.version, running: running) {
        case .upToDate: return decide(.upToDate(running: running, latest: candidate.version))
        case .runningIsNewer: return decide(.runningIsNewer(running: running, latest: candidate.version))
        case .newer: break
        }

        // Prepare is harmless, so a manual check runs it in any copy that has something to check
        // the release against — the only way to say "available" honestly.
        if manual {
            guard trust != nil else {
                return decide(.cannotVerify(tag: candidate.tag, reason: installability.reason?.message
                    ?? ChecksOnlyReason.noTeam.message))
            }
            return decide(.prepare(candidate))
        }
        guard settingOn else { return decide(.nothing("Keep Claude Switcher Up to Date is off")) }
        guard isLockHolder else { return decide(.nothing("another Claude Switcher holds the lock")) }
        guard configIsValid else { return decide(.nothing("config.json cannot be read")) }
        guard trust != nil, installability == .installable else {
            return decide(.nothing("this copy never replaces itself: "
                + (installability.reason?.message ?? ChecksOnlyReason.noTeam.message)))
        }
        if state.isRejected(candidate) {
            return decide(.nothing("\(candidate.version) was rejected; it is not tried again automatically"))
        }
        if state.downloadsPaused == true {
            return decide(.nothing("automatic downloads paused after \(pauseAfterRejections) rejected releases"))
        }
        if let attempt = state.attempts?[candidate.key], attempt.nextNotBefore > now {
            // The retry is a check, so the next one comes when the attempt is due.
            return Decision(action: .nothing("the next attempt at \(candidate.version) is due later"),
                            nextCheckNotBefore: min(next, attempt.nextNotBefore))
        }
        return decide(.prepare(candidate))
    }

    // MARK: Commit

    /// Section 8's preconditions: whether "replace and relaunch" may start now, or why not.
    /// When the user asked, the setting, a broken config and the soft blockers do not hold it.
    public static func commitHold(snapshot: SwitcherIdleSnapshot, userAsked: Bool, installability: Installability,
                                  isLockHolder: Bool, settingOn: Bool, configIsValid: Bool,
                                  prepared: PreparedUpdate?, running: ReleaseVersion?) -> CommitHold? {
        guard let prepared else { return .nothingPrepared }
        guard let running, prepared.version > running else { return .notNewer }
        if case .checksOnly(let reason) = installability { return .checksOnly(reason) }
        guard isLockHolder else { return .notLockHolder }
        if !userAsked {
            guard settingOn else { return .settingOff }
            guard configIsValid else { return .configBroken }
        }
        let blockers = SwitcherIdle.blockers(snapshot, userAsked: userAsked)
        return blockers.isEmpty ? nil : .notIdle(blockers)
    }

    // MARK: Retry and rejection

    /// The backoff after a refusal: `nil` for a permanent one (that release file is rejected
    /// instead); unchanged when nothing was really attempted; otherwise 1 h, 2 h, 4 h … at most
    /// a day, starting again at 1 h once an attempt gets further than the last one did.
    public static func nextAttempt(after refusal: Refusal, attempts: AttemptRecord?, now: Date) -> AttemptRecord? {
        guard refusal.kind == .transient else { return nil }
        guard refusal.countsAsAttempt else { return attempts }
        let reached = stepOrder(refusal.step)
        let count: Int
        if let attempts, reached <= stepOrder(attempts.lastStep) {
            count = attempts.count + 1
        } else {
            count = 1
        }
        let hours = min(pow(2, Double(min(count, 16) - 1)), SwitcherReleaseFeed.maximumDelay / 3600)
        return AttemptRecord(count: count, lastStep: refusal.step, nextNotBefore: now.addingTimeInterval(hours * 3600))
    }

    /// Prepare steps in their order, then commit steps after them.
    static func stepOrder(_ step: String) -> Int {
        if let prepare = PrepareStep(rawValue: step) { return prepare.order }
        if let commit = CommitStep(rawValue: step), let index = CommitStep.allCases.firstIndex(of: commit) {
            return PrepareStep.allCases.count + index
        }
        return -1
    }

    /// Records a refusal for `candidate`.
    public static func record(_ refusal: Refusal, for candidate: ReleaseCandidate, in state: inout SwitcherUpdateState,
                              now: Date) {
        state.lastFailure = FailureRecord(tag: candidate.tag, digest: candidate.digestHex, step: refusal.step,
                                          reason: refusal.reason, at: now)
        var attempts = state.attempts ?? [:]
        switch refusal.kind {
        case .permanent:
            if !state.isRejected(candidate) {
                state.rejected = (state.rejected ?? []) + [Rejection(tag: candidate.tag, digestHex: candidate.digestHex,
                                                                     reason: refusal.reason, at: now)]
            }
            let count = (state.consecutivePermanentRejections ?? 0) + 1
            state.consecutivePermanentRejections = count
            if count >= pauseAfterRejections { state.downloadsPaused = true }
            attempts[candidate.key] = nil
        case .transient:
            let attempt = nextAttempt(after: refusal, attempts: attempts[candidate.key], now: now)
            attempts[candidate.key] = attempt
            // A retry only ever follows a check, so the check comes when the backoff says — after
            // 1 h, 2 h, 4 h — not at the usual six hours. A check already due stays due.
            if refusal.countsAsAttempt, let due = attempt?.nextNotBefore, let next = state.nextCheckNotBefore, due < next {
                state.nextCheckNotBefore = due
            }
        }
        state.attempts = attempts.isEmpty ? nil : attempts
    }

    /// A release file that has just passed every check is no longer rejected: a manual check
    /// that re-ran it is the way back for one rejected before.
    public static func recordPrepared(_ prepared: PreparedUpdate, in state: inout SwitcherUpdateState) {
        state.prepared = prepared
        state.consecutivePermanentRejections = 0
        state.rejected = state.rejected?.filter {
            !($0.tag == prepared.candidate.tag && $0.digestHex == prepared.candidate.digestHex)
        }
        if state.rejected?.isEmpty == true { state.rejected = nil }
        state.attempts?[prepared.candidate.key] = nil
        if state.attempts?.isEmpty == true { state.attempts = nil }
    }

    /// What a commit leaves in `state.json`. The verified copy is used up by anything but a
    /// commit that found something going on; a refusal counts like a prepare's — a rejection
    /// when it is about the release, a backoff when it is about the moment.
    public static func record(commit outcome: CommitOutcome, prepared: PreparedUpdate,
                              in state: inout SwitcherUpdateState, now: Date) {
        switch outcome {
        case .abortedNotIdle:
            return
        case .launched, .restartPending:
            state.prepared = nil
        case .rolledBack(let refusal), .refusedBeforeSwap(let refusal):
            state.prepared = nil
            record(refusal, for: prepared.candidate, in: &state, now: now)
        }
    }

    /// A check the user asked for: a paused updater starts again.
    public static func manualCheckStarted(_ state: inout SwitcherUpdateState) {
        state.downloadsPaused = nil
        state.consecutivePermanentRejections = nil
    }

    // MARK: Identity

    /// Step 10: the signature passed; is it the same developer's same app, at the release's
    /// version, newer than the running one? (`mustBeNewer` is off only for going back.)
    public static func verifyBundleIdentity(_ identity: CodeIdentity, trust: SwitcherTrust, expected: ReleaseVersion,
                                            step: String = PrepareStep.mountedIdentity.rawValue,
                                            mustBeNewer: Bool = true) -> Refusal? {
        func refuse(_ reason: String) -> Refusal { Refusal(kind: .permanent, step: step, reason: reason) }
        guard identity.teamID == trust.teamID else { return refuse("it is signed by another developer team") }
        guard identity.identifier == trust.identifier else { return refuse("it is a different app (its identifier differs)") }
        guard identity.hasHardenedRuntime else { return refuse("it is not built with the hardened runtime") }
        guard !identity.isAdHoc else { return refuse("it has an ad-hoc signature") }
        guard let version = identity.version else { return refuse("its version cannot be read from its signature") }
        guard version == expected else { return refuse("its version (\(version)) is not the release\u{2019}s (\(expected))") }
        if mustBeNewer, !(version > trust.runningVersion) {
            return refuse("\(version) is not newer than the running \(trust.runningVersion)")
        }
        return nil
    }

    // MARK: The staging folder

    /// The NSIRD predicate: a staging path read from a file is acted on only if it is a folder
    /// FileManager made for replacing an item (`<tmp>/TemporaryItems/NSIRD_…`), not a link, and
    /// holding exactly one Claude Switcher bundle with the running bundle identifier.
    public static func stagingIsOurs(path: String, temporaryItems: String, canonical: (String) -> String?,
                                     lstat: (String) -> FileKind?, entries: (String) -> [String]?,
                                     bundleID: (String) -> String?, runningBundleID: String?) -> Bool {
        guard path.hasPrefix("/"), let runningBundleID, !runningBundleID.isEmpty else { return false }
        let name = (path as NSString).lastPathComponent
        guard Pattern.matches("^NSIRD_[^/]+$", name),
              let parent = canonical((path as NSString).deletingLastPathComponent), parent == temporaryItems,
              lstat(path) == .directory,
              entries(path) == [SwitcherDisk.appName]
        else { return false }
        let app = path + "/" + SwitcherDisk.appName
        return lstat(app) == .directory && bundleID(app) == runningBundleID
    }

    // MARK: Starts

    /// Earlier starts of `version` on this Mac that never reached the point where the marker is
    /// deleted. A marker from another Mac or another version counts for nothing.
    public static func abortedStarts(marker: StartMarker?, version: ReleaseVersion?, host: String) -> Int {
        guard let marker, marker.host == host, let version, marker.version == version else { return 0 }
        return max(0, marker.count)
    }

    /// Two aborted starts of the running version while this Mac's record of the update that
    /// installed it is still there: go back to the older version it came from. The record stays
    /// only until a start of the new version has got going (``SwitcherUpdateStore/settleStart(version:isLockHolder:)``);
    /// after that the version has shown it starts, and nothing — not two quick restarts weeks
    /// later — sends a good release back.
    public static func revertDecision(abortedStarts: Int, running: ReleaseVersion?, handoff: UpdateHandoff?,
                                      host: String) -> RevertDecision {
        guard abortedStarts >= 2, let running, let handoff, handoff.host == host, handoff.kind == .update,
              handoff.to == running, handoff.from < running
        else { return .none }
        return .revert(RevertPlan(from: running, to: handoff.from, tag: handoff.tag, digest: handoff.digest))
    }
}

/// The app's own gates around the updater, kept here so that every fact they weigh is tested:
/// the app only gathers the facts.
public enum SwitcherShellGate {

    /// Quit waits while Claude Switcher replaces itself: the commit ends this process itself,
    /// after the relaunch.
    public static func canQuit(isCommitting: Bool) -> Bool { !isCommitting }

    /// Only the lock holder checks on its own, with the setting on and the config read, in a copy
    /// that could ever use what it finds — and not while a check, a commit or the launch-time pass
    /// is running, nor once a new version is waiting for the next launch.
    public static func automaticChecksRun(isLockHolder: Bool, configIsValid: Bool, settingOn: Bool, neverReplaces: Bool,
                                          restartPending: Bool, isChecking: Bool, isCommitting: Bool,
                                          isReconciling: Bool) -> Bool {
        isLockHolder && configIsValid && settingOn && !neverReplaces && !restartPending && !isChecking && !isCommitting
            && !isReconciling
    }

    /// A check the user asks for runs in any copy, but not on top of another check, a commit, the
    /// launch-time pass — which tidies the same folders — or a version waiting for the next launch.
    public static func manualCheckRuns(isChecking: Bool, isCommitting: Bool, restartPending: Bool,
                                       isReconciling: Bool) -> Bool {
        !isChecking && !isCommitting && !restartPending && !isReconciling
    }

    /// Whether a kept release is looked at for a commit now. A check that is running ends by
    /// looking again with what it found; the launch-time pass ends the same way.
    public static func considersInstall(hasPrepared: Bool, isCommitting: Bool, restartPending: Bool, isChecking: Bool,
                                        isReconciling: Bool) -> Bool {
        hasPrepared && !isCommitting && !restartPending && !isChecking && !isReconciling
    }
}
