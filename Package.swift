// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Roko",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Roko",
            path: "Sources/Roko",
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony. /regex/ literals, as the iPhone app's answers use.
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
        .testTarget(
            name: "RokoTests",
            dependencies: ["Roko"],
            path: "Tests/RokoTests",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ]
)
