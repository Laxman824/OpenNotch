// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenNotch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates (EdDSA-signed appcast attached to GitHub Releases).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Catches Objective-C exceptions from AVFoundation (Swift can't).
        .target(name: "OpenNotchObjC", path: "Sources/OpenNotchObjC"),
        .executableTarget(
            name: "OpenNotch",
            dependencies: ["OpenNotchObjC", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/OpenNotch",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
    ]
)
