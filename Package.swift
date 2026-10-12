// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenOff",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ScreenOffCore"),
        // One binary: menu bar app when launched normally, CLI when given arguments.
        .executableTarget(name: "ScreenOff", dependencies: ["ScreenOffCore"]),
        .testTarget(name: "ScreenOffCoreTests", dependencies: ["ScreenOffCore"]),
    ]
)
