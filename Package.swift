// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ledge",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Ledge",
            path: "Sources/Ledge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
