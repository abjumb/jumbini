// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jumbini",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .executableTarget(
            name: "Jumbini",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/sprites"), .copy("Resources/jumba"),
                .copy("Resources/Icons"), .copy("Resources/audio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle links via @rpath. SwiftPM drops the framework next to the
            // built executable but does not add a runpath for it, so a plain
            // `swift run` would fail to dlopen it. @loader_path finds the
            // framework sitting beside the binary. (bundle.sh adds a separate
            // @loader_path/../Frameworks runpath for the shipped .app.)
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path"]),
            ]
        ),
        .testTarget(
            name: "JumbiniTests",
            dependencies: ["Jumbini"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The test bundle lives at Products/<config>/JumbiniTests.xctest/
            // Contents/MacOS/, while the framework sits three levels up in
            // Products/<config>/ next to the .xctest. Give the bundle a runpath
            // that reaches it so `swift test` can dlopen Sparkle too.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."]),
            ]
        ),
    ]
)
