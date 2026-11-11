// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EQApe",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "EQApe", targets: ["EQApe"]),
        .library(name: "TapKit", targets: ["TapKit"]),
        .library(name: "EQApeCore", targets: ["EQApeCore"]),
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
        .testTarget(
            name: "EQApeCoreTests",
            dependencies: ["EQApeCore", "TapKit", .product(name: "EQCore", package: "EQCore")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
