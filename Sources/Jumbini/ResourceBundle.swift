import Foundation

extension Bundle {
    /// The SwiftPM resource bundle (sprites, jumba, Icons, audio), found wherever
    /// it actually landed.
    ///
    /// Use this instead of `Bundle.module`. The accessor SwiftPM generates for a
    /// `swift build` executable looks in exactly two places: beside
    /// `Bundle.main.bundleURL`, and the absolute `.build` path of the machine that
    /// compiled the binary. Neither one exists in a shipped app. Inside a .app,
    /// `Bundle.main.bundleURL` *is* `Jumbini.app`, so it looks for
    /// `Jumbini.app/Jumbini_Jumbini.bundle` — and the bundle cannot be moved there
    /// to satisfy it, because `codesign` refuses a bundle with anything outside
    /// `Contents` ("unsealed contents present in the bundle root"). The build path
    /// belongs to a GitHub Actions runner and is meaningless on a user's Mac. So
    /// `Bundle.module` traps on first access in every released build, and the
    /// lookup has to come to the resources rather than the other way around.
    static let assets: Bundle = {
        let name = "Jumbini_Jumbini.bundle"

        let candidates = [
            // A shipped .app: bundle.sh copies the resource bundle into
            // Contents/Resources, which is where Apple's layout requires it.
            Bundle.main.resourceURL,
            // `swift run` / `.build/release/Jumbini`: beside the executable.
            Bundle.main.bundleURL,
        ]

        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(name),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }

        // `swift test`, where Bundle.main is the xctest runner and the resources
        // sit next to the .xctest bundle. The generated accessor knows that
        // layout; let it answer, and trap loudly if even it comes up empty.
        return .module
    }()
}
