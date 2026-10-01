// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenNotch",
    platforms: [.macOS(.v14)],
    targets: [
        // Catches Objective-C exceptions from AVFoundation (Swift can't).
        .target(name: "OpenNotchObjC", path: "Sources/OpenNotchObjC"),
        .executableTarget(
            name: "OpenNotch",
            dependencies: ["OpenNotchObjC"],
            path: "Sources/OpenNotch",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
    ]
)
