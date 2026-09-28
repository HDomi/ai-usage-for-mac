// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIUsageNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIUsageNotch",
            path: "Sources/AIUsageNotch"
        )
    ]
)
