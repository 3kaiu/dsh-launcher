// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DShLauncher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DShLauncher",
            path: "Sources/DShLauncher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
