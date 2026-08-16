import Testing
import Foundation
@testable import Jumbini

// The menu item this feeds is the only place the app says which build it is,
// so the interesting cases are the ones where the bundle can't tell it: a
// `swift run` binary with no Info.plist, or a key that got stamped empty.

@Test func versionAndBuildReadAsAReleaseLine() {
    #expect(AppVersion.title(short: "4.5", build: "14") == "Jumbini 4.5 (14)")
}

@Test func matchingVersionAndBuildAreNotPrintedTwice() {
    #expect(AppVersion.title(short: "4.5", build: "4.5") == "Jumbini 4.5")
}

@Test func aMissingHalfStillNamesWhatItHas() {
    #expect(AppVersion.title(short: "4.5", build: nil) == "Jumbini 4.5")
    #expect(AppVersion.title(short: nil, build: "14") == "Jumbini (build 14)")
}

@Test func nothingToReadSaysSoRatherThanShowingAGap() {
    #expect(AppVersion.title(short: nil, build: nil) == "Jumbini (development build)")
}

@Test func blankKeysCountAsMissing() {
    // PlistBuddy will set a key to "" without complaint, and " " in a menu
    // reads as a bug rather than as an unreleased build.
    #expect(AppVersion.title(short: "", build: "  ") == "Jumbini (development build)")
    #expect(AppVersion.title(short: " 4.5 ", build: "\n14") == "Jumbini 4.5 (14)")
}

@Test func theBundledTitleIsNeverEmpty() {
    // Whatever Bundle.main turns out to be under the test runner, the menu
    // item must have something to show.
    #expect(!AppVersion.menuTitle.isEmpty)
    #expect(AppVersion.menuTitle.hasPrefix("Jumbini"))
}
