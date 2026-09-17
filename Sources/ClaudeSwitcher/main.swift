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

private let usageText = """
claude-switcher — switch between Claude Desktop accounts from the menu bar.

USAGE
  claude-switcher             Run the menu bar app (no Dock icon, no window).
  claude-switcher --dry-run   Print the resolved launch plan for every profile, then exit.
                              Launches nothing, creates no directories, touches no state.
  claude-switcher --help      Show this message.

CONFIG
  \(Config.configURL.path)

HOW PROFILES DIFFER
  Desktop app   a separate Electron user-data dir (--user-data-dir) — its own login for
                both chat and the Code tab. Instances run side by side.
  Terminal CLI  a separate CLAUDE_SECURESTORAGE_CONFIG_DIR credential slot, applied by
                you in your shell via "Copy terminal command".

WHAT STAYS SHARED
  ~/.claude — projects, session history, skills, agents, plugins, memory, settings and
  CLAUDE.md — is shared by every profile. claude-switcher never sets CLAUDE_CONFIG_DIR,
  never sets CLAUDE_CODE_OAUTH_TOKEN, and never reads or writes Keychain secrets (it only
  checks whether a credential item exists).
"""

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
    print(Diagnostics.launchPlan(config: config, running: running, update: update))
    return 0
}

let commandLineArguments = CommandLine.arguments.dropFirst()

if commandLineArguments.contains("--help") || commandLineArguments.contains("-h") {
    print(usageText)
    exit(0)
}

if commandLineArguments.contains("--dry-run") {
    exit(runDryRun())
}

// AppDelegate is @MainActor-isolated. Top-level code in main.swift is a synchronous
// *nonisolated* context, so constructing it directly is a compile error. The process is
// single-threaded at this point and this is by definition the main thread, so asserting
// the isolation we already have is both correct and the narrowest fix.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)   // menu bar only: no Dock tile, no main window
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.run()
}
