import Testing
import AppKit
@testable import Jumbini

// The panels themselves are rendering and input, which this project verifies by
// hand. What is worth testing is the sidebar catalog underneath them: a
// duplicated identifier silently points two rows at the same page, and a search
// that jumps somewhere unexpected is the kind of bug nobody reports because it
// just looks like they mistyped.

@Test func everySettingsSectionHasItsOwnIdentifier() {
    let identifiers = SettingsPanel.catalog.sections.map(\.identifier)
    #expect(identifiers.count == Set(identifiers).count)
    #expect(identifiers.allSatisfy { !$0.isEmpty })
}

@Test func everySettingsSectionHasATitleAndASymbol() {
    for section in SettingsPanel.catalog.sections {
        #expect(!section.title.isEmpty)
        // A missing SF Symbol renders as nothing at all, so the row would come
        // out as a floating label with a gap where its icon should be.
        #expect(NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) != nil)
    }
}

@Test func searchJumpsToASectionByName() {
    let match = SettingsPanel.catalog.firstMatch(for: "coats")
    #expect(match?.title == "Coats")
}

@Test func searchIgnoresCaseAndSurroundingSpace() {
    #expect(SettingsPanel.catalog.firstMatch(for: "  BEHAVIOR ")?.title == "Behavior")
}

@Test func searchPrefersAPrefixOverAMerelyContainingMatch() {
    // "Window Climbing" starts with it; nothing should beat that to it.
    #expect(SettingsPanel.catalog.firstMatch(for: "win")?.title == "Window Climbing")
}

@Test func aPartialWordStillFindsTheSection() {
    #expect(SettingsPanel.catalog.firstMatch(for: "pixel")?.title == "Pixellab API")
}

@Test func anEmptyQueryMatchesNothingRatherThanTheFirstRow() {
    // Clearing the field must not yank the user to General mid-read.
    #expect(SettingsPanel.catalog.firstMatch(for: "") == nil)
    #expect(SettingsPanel.catalog.firstMatch(for: "   ") == nil)
}

@Test func nonsenseMatchesNothing() {
    #expect(SettingsPanel.catalog.firstMatch(for: "zzzz") == nil)
}

@Test func groupsCoverEverySectionExactlyOnce() {
    let grouped = SettingsPanel.catalog.groups.flatMap(\.sections).count
    #expect(grouped == SettingsPanel.catalog.sections.count)
}
