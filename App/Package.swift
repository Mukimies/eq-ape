// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EQApe",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "EQApe", targets: ["EQApe"]),
        .library(name: "TapKit", targets: ["TapKit"]),
        .library(name: "EQApeCore", targets: ["EQApeCore"]),
        // Development tools (docs/UI-TESTING.md); not part of the app bundle.
        .executable(name: "eqape-uitest", targets: ["UITestDriver"]),
        .executable(name: "eqape-uidrive", targets: ["UIDrive"]),
    ],
    dependencies: [
        .package(path: "../EQCore"),
    ],
    targets: [
        // C11 atomics usable from the real-time IO thread on macOS 14
        // (Swift's Synchronization.Atomic needs macOS 15).
        .target(name: "TapAtomics"),
        // Core Audio process tap + private aggregate + one IOProc, with a lock-free processor slot.
        .target(
            name: "TapKit",
            dependencies: ["TapAtomics", .product(name: "EQCore", package: "EQCore")],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        // App logic without UI: settings, profiles, config loading + watching, device following.
        .target(
            name: "EQApeCore",
            dependencies: ["TapKit", .product(name: "EQCore", package: "EQCore")]
        ),
        // Menu bar app + headless test mode (same binary).
        .executableTarget(
            name: "EQApe",
            dependencies: ["EQApeCore", "TapKit"]
        ),
        // Driver of the app's --ui-test-control channel: launch / do / state / shot / quit / suite (App/scripts/uitest).
        .executableTarget(name: "UITestDriver"),
        // Real-input helper (Accessibility + Screen Recording of the terminal): perms / tree / click / drag / type /
        // shot with real CGEvents and pointer-safety checks (App/scripts/uidrive).
        .executableTarget(
            name: "UIDrive",
            linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "EQApeCoreTests",
            dependencies: ["EQApeCore", "TapKit", .product(name: "EQCore", package: "EQCore")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
