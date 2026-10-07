// swift-tools-version:6.0
import PackageDescription

// Layout note for contributors:
//   Sources/ClaudeSwitcherCore  -> pure, testable logic (Config, PathNormalizer,
//                                  KeychainProbe, ProcessArgs, InstanceManager,
//                                  LaunchPlanning, UpdateProbe, UpdateInstaller,
//                                  LoginItem, UsageHistory, UpdateReopen, UpdateBlock,
//                                  AutomationLock, Onboarding, SessionCatalog,
//                                  SessionRegistry, SessionCopy and its parts:
//                                  HeldDirectory, TranscriptScan, CopyRecord,
//                                  CopyJournal, CopyRun, CopyRecovery, StoreSurvey,
//                                  SwitcherUpdater and its parts: SwitcherRelease,
//                                  SwitcherRunningCopy, SwitcherSignature, SwitcherIdle,
//                                  SwitcherRelaunch, SwitcherUpdatePolicy,
//                                  SwitcherUpdateState, SwitcherUpdateStore,
//                                  SwitcherUpdateAlerts, SwitcherUpdaterLive,
//                                  the usage Advisor and its parts: WeeklySchedule,
//                                  UsageTimeline, ActivityLedger, ActivityIndex,
//                                  ExactUsage, UsageForecast, SessionCosts,
//                                  UsageAdvisor, AdvisorText, UsageSnapshot)
//   Sources/ClaudeSwitcher      -> AppKit UI shell (main.swift, AppDelegate,
//                                  MenuBuilder, SessionMenu, Diagnostics, WelcomeWindow,
//                                  UsageMenu and UsageBarView: the usage under each
//                                  account and "Start a session in…",
//                                  SwitcherUpdates: the updater's text and the real
//                                  CommitEnvironment, out of the tests' reach)
//   Tests/ClaudeSwitcherTests   -> tests, importing ClaudeSwitcherCore
//
// The executable target is deliberately thin: a test target cannot import an
// executable target cleanly across all toolchains, so every unit-testable type
// lives in the ClaudeSwitcherCore library.
//
// All targets build under the Swift 6 language mode.

let package = Package(
    name: "ClaudeSwitcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "claude-switcher", targets: ["claude-switcher"]),
        .library(name: "ClaudeSwitcherCore", targets: ["ClaudeSwitcherCore"]),
    ],
    targets: [
        .target(
            name: "ClaudeSwitcherCore",
            path: "Sources/ClaudeSwitcherCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "claude-switcher",
            dependencies: ["ClaudeSwitcherCore"],
            path: "Sources/ClaudeSwitcher",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudeSwitcherTests",
            dependencies: ["ClaudeSwitcherCore"],
            path: "Tests/ClaudeSwitcherTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
