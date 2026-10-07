import AppKit
import ServiceManagement
import ClaudeSwitcherCore

// MARK: - What the app says about updating itself

/// The menu's, Diagnostics' and `--dry-run`'s sentences about Claude Switcher updating itself.
/// Pure: built from the values handed to it. "Claude" alone is Claude Desktop; the switcher names
/// itself in full, and its verbs are "relaunch" and "updated itself" — never "install".
enum SwitcherUpdateUI {

    static let keepUpToDateTitle = "Keep Claude Switcher Up to Date"
    static let checkTitle = "Check for Claude Switcher Updates\u{2026}"

    static func updateTitle(_ version: ReleaseVersion) -> String {
        "Update Claude Switcher to \(version) & Relaunch"
    }

    // Progress, in the slot Claude's own progress uses.
    static let checkingLine = "Checking for Claude Switcher updates\u{2026}"

    static func downloadingLine(_ version: ReleaseVersion) -> String { "Downloading Claude Switcher \(version)\u{2026}" }

    static func updatingLine(_ version: ReleaseVersion) -> String {
        "Updating Claude Switcher to \(version) \u{2014} it relaunches in a moment\u{2026}"
    }

    // Waiting.
    static func readyLine(_ version: ReleaseVersion) -> String {
        "Claude Switcher \(version) is ready \u{2014} it relaunches when nothing is going on"
    }

    static func inPlaceLine(_ version: ReleaseVersion) -> String {
        "Claude Switcher \(version) is in place \u{2014} it starts the next time Claude Switcher is launched"
    }

    // Tooltips.
    static func onToolTip(lastCheck: String) -> String {
        "Checks github.com/kevinchau/claude-switcher for a newer Claude Switcher every few hours, replaces itself "
            + "when nothing is going on, and relaunches. Only Claude Switcher \u{2014} Claude is never quit, started or "
            + "updated by this. \(lastCheck)"
    }

    static let offToolTip = "Claude Switcher makes no network request unless you choose Check for Claude Switcher Updates\u{2026}"

    static func checksOnlyToolTip(_ reason: String) -> String {
        "This copy never replaces itself: \(reason). It can still check."
    }

    static let checkToolTip = "Asks github.com/kevinchau/claude-switcher for the latest Claude Switcher now and says what it found."

    static func updateToolTip(_ version: ReleaseVersion) -> String {
        "Replaces this copy with the verified \(version) and relaunches it \u{2014} a second or two without the menu bar "
            + "icon. Claude keeps running: nothing in Claude is quit, started or changed."
    }

    /// What the last check found, in a few words. A newer release is only called "available"
    /// once this copy has verified it (`verified`): the feed alone cannot vouch for anything.
    static func checkSummary(_ state: SwitcherUpdateState, running: ReleaseVersion?, verified: ReleaseVersion?,
                             time: (Date) -> String) -> String? {
        guard let result = state.lastCheckResult else { return nil }
        switch result {
        case .candidate(let latest):
            guard let running else { return "the latest release is \(latest.tag)" }
            switch SwitcherUpdatePolicy.compare(candidate: latest.version, running: running) {
            case .upToDate:
                return "up to date"
            case .runningIsNewer:
                return "up to date (\(running) is newer than the latest release, \(latest.version))"
            case .newer:
                if verified == latest.version { return "\(latest.version) available" }
                if let rejection = state.rejected?.last(where: { $0.tag == latest.tag && $0.digestHex == latest.digestHex }) {
                    return "\(latest.tag) could not be verified: \(rejection.reason)"
                }
                return "\(latest.tag) is newer, not verified yet"
            }
        case .rateLimited(let until):
            return "GitHub rate limit; next check after \(time(until))"
        default:
            return result.failureReason
        }
    }

    /// The toggle's last sentence: "Last checked 3:12 PM: up to date."
    static func lastCheckSentence(_ state: SwitcherUpdateState, running: ReleaseVersion?, verified: ReleaseVersion?,
                                  time: (Date) -> String) -> String {
        guard let at = state.lastCheckAt else { return "Not checked yet." }
        let summary = checkSummary(state, running: running, verified: verified, time: time) ?? "no result"
        return "Last checked \(time(at)): \(summary)."
    }

    /// `--dry-run`'s one line, from `state.json` alone: a dry run fetches nothing.
    static func dryRunLine(version: ReleaseVersion?, installability: Installability, settingOn: Bool,
                           state: SwitcherUpdateState, time: (Date) -> String) -> String {
        let does: String
        if let reason = installability.reason {
            does = "\(reason.message); never replaces itself"
        } else if !settingOn {
            does = "Keep Claude Switcher Up to Date is off; checks only when you ask"
        } else {
            does = "updates itself automatically"
        }
        let checked = state.lastCheckAt.map {
            "last checked \(time($0)): \(checkSummary(state, running: version, verified: nil, time: time) ?? "no result")"
        } ?? "never checked"
        return "Claude Switcher: \(version?.description ?? "(version unreadable)") \u{2014} \(does); \(checked) "
            + "(a dry run fetches nothing)"
    }
}

// MARK: - The real commit environment

extension SwitcherUpdater.CommitEnvironment {
    /// The real swap and relaunch. It lives in the app target, where the tests cannot reach it.
    /// It can start one process — a new copy of Claude Switcher, by path — and end one: this one.
    /// Every removal goes through ``RemovalScope``, which allows only the updater's own folders
    /// and a staged copy this process made and has not swapped.
    @MainActor
    static func live(updatesDirectory: URL, store: SwitcherUpdateStore, registry: StagedCopies = .shared,
                     idleBlockers: @escaping @MainActor () -> [SwitcherIdle.Blocker],
                     uiIsOpen: @escaping @MainActor () -> Bool) -> Self {
        let updates = updatesDirectory.path
        let scope = RemovalScope(updatesDirectory: updates, registry: registry)
        return Self(
            lstatKind: SwitcherDisk.lstatKind,
            canonicalPath: SwitcherDisk.realpath,
            bundleIdentifierOnDisk: SwitcherDisk.bundleIdentifier(ofBundleAt:),
            versionOnDisk: UpdateProbe.version(ofBundleAt:),
            processExecutablePath: SwitcherDisk.processExecutablePath,
            isWritable: SwitcherDisk.isWritable,
            deviceOf: SwitcherDisk.deviceOf,
            verify: CodeSignature.verifier(),
            swap: { first, second in SwitcherDisk.swap(first, second, registry: registry) },
            registerWithLaunchServices: SwitcherDisk.registerWithLaunchServices,
            moveToPrevious: { bundle, version in
                SwitcherDisk.moveToPrevious(bundle, version: version, updatesDirectory: updates)
            },
            trash: SwitcherDisk.trash,
            remove: { scope.remove($0) },
            removeEmptyFolder: SwitcherDisk.removeEmptyFolder,
            writeHandoff: { handoff in
                do {
                    try await store.writeHandoff(handoff)
                    return nil
                } catch {
                    return Refusal(kind: .transient, step: CommitStep.handoff.rawValue,
                                   reason: "the hand-off record could not be written (\(error))")
                }
            },
            note: { note in _ = try? await store.update(now: Date()) { $0.apply(note) } },
            idleBlockers: idleBlockers,
            uiIsOpen: uiIsOpen,
            launch: { bundlePath, oldPID in
                await SwitcherRelaunch.awaitLaunch { finish in
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    configuration.activates = false
                    configuration.arguments = SwitcherRelaunch.launchArguments(oldPID: oldPID)
                    // The completion arrives on a queue of its own; `awaitLaunch` takes the first answer.
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundlePath),
                                                       configuration: configuration) { application, error in
                        if let application {
                            finish(.success(application.processIdentifier))
                        } else {
                            finish(.failure(RelaunchFailure(reason: error?.localizedDescription ?? "macOS did not start it")))
                        }
                    }
                }
            },
            terminateSelf: { NSApp.terminate(nil) },
            sleep: { duration in try? await Task.sleep(for: duration) },
            launchAtLoginIsEnabled: { SMAppService.mainApp.status == .enabled },
            now: { Date() },
            host: store.host,
            processID: getpid())
    }
}
