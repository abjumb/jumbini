import Foundation

/// What version of itself the app is, for the menu to show.
///
/// Read from the bundle at runtime rather than written down here, because when
/// this source is compiled nobody knows yet: release.yml stamps
/// CFBundleShortVersionString from the git tag and CFBundleVersion from the
/// run number, so the values sitting in Scripts/Info.plist are only ever
/// placeholders left over from whichever release last touched the file. A
/// constant in the source would be wrong for every build that ships.
enum AppVersion {
    /// The menu line, e.g. `Jumbini 4.5 (14)`.
    static var menuTitle: String {
        title(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// Split out from `menuTitle` so the wording can be tested without an app
    /// bundle to read it out of.
    ///
    /// Both halves are optional and both really do go missing: a bare
    /// `swift run` binary has no Info.plist at all, and a hand-assembled one
    /// can be missing either key. None of that is worth a crash or an empty
    /// menu item, so every combination has something to say.
    static func title(short: String?, build: String?) -> String {
        switch (nonEmpty(short), nonEmpty(build)) {
        case let (version?, build?):
            // A version and a build number that read the same look like a typo
            // in a menu, so collapse them rather than print "4.5 (4.5)".
            return version == build ? "Jumbini \(version)" : "Jumbini \(version) (\(build))"
        case let (version?, nil):
            return "Jumbini \(version)"
        case let (nil, build?):
            return "Jumbini (build \(build))"
        case (nil, nil):
            return "Jumbini (development build)"
        }
    }

    /// Whitespace-only is as good as missing — PlistBuddy will happily set a
    /// key to the empty string, and " " in the menu reads as a bug.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
