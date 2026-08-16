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

// The chrome itself is checkable without a screenshot: the reference design has
// a real traffic light in the top-left and a window you can drag, and both of
// those are properties of the window rather than of how it looks. These are the
// checks that would have caught the first version of this panel, which drew its
// own ✕ in the top-right corner and could not be moved at all.
//
// @MainActor because AppKit windows may only be touched from the main thread,
// and Swift Testing will otherwise run these wherever it likes.

@Test @MainActor func aPanelHasARealTitleBarCloseButton() {
    let panel = JumbiniPanel(autosaveName: "test.chrome", size: NSSize(width: 300, height: 200))
    #expect(panel.styleMask.contains(.titled))
    #expect(panel.styleMask.contains(.closable))
    // The traffic light itself — nil here would mean we are back to drawing one.
    #expect(panel.standardWindowButton(.closeButton) != nil)
}

@Test @MainActor func theTitleBarIsPresentButInvisible() {
    let panel = JumbiniPanel(autosaveName: "test.titlebar", size: NSSize(width: 300, height: 200))
    #expect(panel.titlebarAppearsTransparent)
    #expect(panel.titleVisibility == .hidden)
}

@Test @MainActor func allThreeTrafficLightsArePresent() {
    let panel = JumbiniPanel(autosaveName: "test.buttons", size: NSSize(width: 300, height: 200))
    // The reference design has three. An earlier version of this panel hid two
    // of them on the theory that dead controls look like a bug, which left one
    // lonely dot in a corner that is visibly not the design — the render is
    // what showed it.
    #expect(panel.standardWindowButton(.closeButton)?.isHidden == false)
    #expect(panel.standardWindowButton(.miniaturizeButton)?.isHidden == false)
    #expect(panel.standardWindowButton(.zoomButton)?.isHidden == false)
}

@Test @MainActor func aPanelCanBeDraggedAndCanTakeKey() {
    let panel = JumbiniPanel(autosaveName: "test.drag", size: NSSize(width: 300, height: 200))
    #expect(panel.isMovableByWindowBackground)
    // Borderless windows refuse key by default, which would leave Escape dead.
    #expect(panel.canBecomeKey)
}

@Test @MainActor func stayingOutOfTheWayIsNotUndoneByOpeningIt() {
    let name = "test.position"
    let key = "panel.\(name).origin"
    UserDefaults.standard.removeObject(forKey: key)
    defer { UserDefaults.standard.removeObject(forKey: key) }

    let panel = JumbiniPanel(autosaveName: name, size: NSSize(width: 300, height: 200))
    panel.setFrameOrigin(NSPoint(x: 120, y: 140))
    panel.rememberPosition()
    // The whole point of the change: a panel dragged aside stays aside.
    #expect(UserDefaults.standard.string(forKey: key) != nil)
}

@Test @MainActor func closingTidiesUpBeforeItGoes() {
    final class Probe: JumbiniPanel {
        var tidied = false
        override func panelWillClose() { tidied = true }
    }
    let panel = Probe(autosaveName: "test.close", size: NSSize(width: 300, height: 200))
    panel.performClose(nil)
    // The Coat Workshop's live preview drives the real dog, so a close that
    // skipped this would leave the overlay wearing a staged coat.
    #expect(panel.tidied)
    #expect(!panel.isVisible)
}
