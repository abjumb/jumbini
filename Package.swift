// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jumbini",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Jumbini",
            resources: [.copy("Resources/sprites"), .copy("Resources/jumba"), .copy("Resources/Icons")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "JumbiniTests",
            dependencies: ["Jumbini"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
