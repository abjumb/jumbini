// swift-tools-version: 6.0
import PackageDescription

// Deliberately its own package rather than a target of the app's: adding a
// second executable to Jumbini's Package.swift would drag it into `swift
// build`, CI and bundle.sh for no benefit. The only thing shared with the app
// is the PNGs on disk and Tools/demo/animations.json, which HeroSpecTests pins.
let package = Package(
    name: "spritefilm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "spritefilm", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "spritefilmTests",
            dependencies: ["spritefilm"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
