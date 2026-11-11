// swift-tools-version: 6.0
import PackageDescription

// The Info.plist is embedded into the Mach-O binary (__TEXT,__info_plist) so that TCC can find
// NSAudioCaptureUsageDescription even though eqtap is a bare CLI and not an .app bundle.
let infoPlistPath = Context.packageDirectory + "/Sources/eqtap/Info.plist"

let package = Package(
    name: "eqtap",
    platforms: [.macOS("14.2")],
    targets: [
        // Tiny C target: lock-free atomics usable from the real-time IO thread on macOS 14
        // (Swift's Synchronization.Atomic needs macOS 15).
        .target(name: "RTAtomics"),
        .executableTarget(
            name: "eqtap",
            dependencies: ["RTAtomics"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlistPath]),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
