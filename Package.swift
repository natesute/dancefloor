// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dancefloor",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "DancefloorCore"),
        .executableTarget(name: "Dancefloor", dependencies: ["DancefloorCore"]),
        .executableTarget(name: "bpmcheck", dependencies: ["DancefloorCore"]),
        .testTarget(name: "DancefloorCoreTests", dependencies: ["DancefloorCore"]),
    ],
    swiftLanguageModes: [.v5]
)
