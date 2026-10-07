import AppKit
import ClaudeSwitcherCore

// claude-switcher — a menu bar switcher for multiple Claude Desktop accounts.
//
// Mechanism (empirically verified, do not re-derive):
//   * A Claude Desktop "account" is an Electron user-data dir. Passing
//     --user-data-dir=<dir> gives a separate login for BOTH chat and the Code tab.
//   * Claude.app takes no single-instance lock, so several profiles run concurrently:
//     switching is launching or focusing another instance, never quitting or logging out.
//     (The one time Claude is asked to quit is the explicit, confirmed "Quit All & Install
//     Update…" action — its installer cannot run while any instance is up.)
//   * ~/.claude (projects, history, skills, agents, plugins, memory, settings, CLAUDE.md)
//     is resolved as CLAUDE_CONFIG_DIR ?? ~/.claude, independently of --user-data-dir.
//     This app NEVER sets or modifies CLAUDE_CONFIG_DIR: keeping ~/.claude shared across
//     every account is the entire point of the product.
//   * CLAUDE_SECURESTORAGE_CONFIG_DIR is for the TERMINAL claude CLI only. It selects a
//     separate credential slot while still sharing ~/.claude, and is never passed to the app.

/// Prints the launch plan without touching anything. Returns the process exit code.
private func runDryRun() -> Int32 {
    let config: Config
    do {
        config = try Config.load()
    } catch {
        FileHandle.standardError.write(Data("""
        claude-switcher: cannot read \(Config.configURL.path)
          \(error.localizedDescription)

        """.utf8))
        return 1
    }
    // Read-only: enumerates running processes so the plan can say what is already up.
    let running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
    let update = UpdateProbe.status(appPath: config.claudeAppPath)
    let now = Date()
    var updateAttempts: [String: UpdateAttempt] = [:]
    var updateBlocks: [String: UpdateBlock.State] = [:]
    for profile in config.profiles {
        updateAttempts[profile.id] = UpdateAttemptMarker.read(userDataDir: profile.userDataDir)
        updateBlocks[profile.id] = UpdateBlock.state(userDataDir: profile.userDataDir)
    }
    // Usage and advice from the activity index as it is on disk: never a transcript scan, never
    // a write. No index (it is built when the app runs) means recorded values and no advice; one
    // more than an hour old is not advised from either.
    let stored = ActivityIndex.stored(profiles: config.profiles, home: NSHomeDirectory(), indexURL: ActivityIndex.defaultURL, now: now)
    let usage = UsageQuery(
        profiles: config.profiles, activity: stored?.ledgers,
        indexState: stored.map { .ready(indexedThrough: $0.file.updatedAt) } ?? .building,
        running: Set(config.profiles.filter { ProfileMatching.isRunning($0, in: running) }.map(\.id))
    ).read(now: now)
    print(Diagnostics.launchPlan(config: config, running: running, update: update, usage: usage,
                                 updateAttempts: updateAttempts, updateBlocks: updateBlocks,
                                 switcher: switcherDryRunLine(config: config, now: now), now: now))
    return 0
}

/// What this copy would do about updating itself, from state.json: read, never fetched. The
/// copy's own signature is checked in-process, as the app does at its first check, but off the
/// network: a stapled release still reads as notarized, while a copy whose ticket is neither
/// stapled nor cached by macOS fails the offline check (-67050) and reads as not notarized.
private func switcherDryRunLine(config: Config, now: Date) -> String {
    let copy = RunningCopy.current()
    // A copy with no trust anchor stops at an earlier reason before notarization is looked at.
    let notarization = SwitcherTrust(copy).map {
        CodeSignature.runningNotarization(trust: $0, flags: CodeSignature.offlineFlags)
    } ?? .rejected
    let installability = SwitcherUpdatePolicy.installability(of: copy, notarization: notarization)
    return SwitcherUpdateUI.dryRunLine(version: copy.identity.version, installability: installability,
                                       settingOn: config.updateSwitcherAutomatically,
                                       state: SwitcherUpdateStore().snapshot(now: now), time: Diagnostics.clockTime)
}

let commandLineArguments = CommandLine.arguments.dropFirst()

if commandLineArguments.contains("--help") || commandLineArguments.contains("-h") {
    print(Diagnostics.usageText)
    exit(0)
}

if commandLineArguments.contains("--dry-run") {
    exit(runDryRun())
}

// Started by an older copy that has just replaced itself with this one. Nothing waits here:
// AppKit starts as always, and the automation lock settles which copy carries on.
let launchedAfterUpdate = SwitcherRelaunch.afterUpdatePID(in: Array(commandLineArguments))

// AppDelegate is @MainActor-isolated. Top-level code in main.swift is a synchronous
// *nonisolated* context, so constructing it directly is a compile error. The process is
// single-threaded at this point and this is by definition the main thread, so asserting
// the isolation we already have is both correct and the narrowest fix.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)   // menu bar only: no Dock tile
    let appDelegate = AppDelegate(launchedAfterUpdate: launchedAfterUpdate)
    application.delegate = appDelegate
    application.run()
}
