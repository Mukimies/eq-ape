// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EQCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EQCore", targets: ["EQCore"]),
    ],
    targets: [
        .target(name: "EQCore"),
        .testTarget(name: "EQCoreTests", dependencies: ["EQCore"]),
    ]
)
