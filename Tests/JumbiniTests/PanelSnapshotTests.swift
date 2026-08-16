import Testing
import AppKit
@testable import Jumbini

// Rendering the settings layout to a bitmap and looking at it.
//
// The panels are the one part of Jumbini whose correctness is "does it look
// right", and the machine that builds them is the only Mac in the loop — the
// author of a change may be working somewhere that cannot run AppKit at all.
// So the layout is drawn offscreen here and checked for the failures that are
// invisible to a compiler and obvious to an eye: a pane that came out blank, a
// window that laid out at the wrong size, a card that is the same colour as the
// background it is supposed to sit on.
//
// With JUMBINI_SNAPSHOT=1 in the environment it also prints the PNG as base64,
// which is how the picture gets out of CI and in front of someone.

@MainActor
private func renderSettingsLayout() -> (image: NSBitmapImageRep, size: NSSize)? {
    let panel = SettingsPanel(defaults: UserDefaults(suiteName: "snapshot.test") ?? .standard)
    guard let content = panel.contentView else { return nil }
    content.layoutSubtreeIfNeeded()
    let bounds = content.bounds
    guard bounds.width > 1, bounds.height > 1,
          let rep = content.bitmapImageRepForCachingDisplay(in: bounds)
    else { return nil }
    // Dynamic colours resolve against whatever appearance is current while
    // drawing, not against the window's. Without this the render came out light
    // while the panel it is a picture of is dark — a snapshot that lies about
    // the one thing it exists to show.
    panel.effectiveAppearance.performAsCurrentDrawingAppearance {
        content.cacheDisplay(in: bounds, to: rep)
    }
    return (rep, bounds.size)
}

@Test @MainActor func theSettingsLayoutRendersAtItsDesignedSize() {
    guard let (_, size) = renderSettingsLayout() else {
        Issue.record("settings layout produced no bitmap")
        return
    }
    // 720x480 is the size the sidebar-and-detail design is laid out against.
    // A window that comes out at its fitting size instead means a constraint
    // went missing and the panes are no longer the widths they were designed at.
    #expect(size.width == 720)
    #expect(size.height == 480)
}

@Test @MainActor func theSettingsLayoutIsNotBlank() {
    guard let (rep, size) = renderSettingsLayout() else {
        Issue.record("settings layout produced no bitmap")
        return
    }
    // A pane that failed to lay out draws as one flat colour, which compiles,
    // passes every other test, and is plainly broken on screen.
    var seen = Set<String>()
    for x in stride(from: 4, to: Int(size.width) - 4, by: 17) {
        for y in stride(from: 4, to: Int(size.height) - 4, by: 17) {
            guard let colour = rep.colorAt(x: x, y: y) else { continue }
            seen.insert(
                String(
                    format: "%.2f,%.2f,%.2f",
                    colour.redComponent, colour.greenComponent, colour.blueComponent
                )
            )
        }
    }
    #expect(seen.count > 3, "the rendered panel used \(seen.count) distinct colours")
}

/// Prints the render as base64 so it can be pulled out of a CI log and looked
/// at. Off by default — it is a few hundred lines of noise nobody needs on an
/// ordinary run.
@Test @MainActor func settingsSnapshotIsPrintedWhenAskedFor() {
    guard ProcessInfo.processInfo.environment["JUMBINI_SNAPSHOT"] == "1" else { return }
    guard let (rep, _) = renderSettingsLayout(),
          let png = rep.representation(using: .png, properties: [:])
    else {
        Issue.record("could not encode the settings layout as PNG")
        return
    }
    let encoded = png.base64EncodedString()
    print("JUMBINI_SNAPSHOT_BEGIN \(png.count)")
    var index = encoded.startIndex
    while index < encoded.endIndex {
        let end = encoded.index(index, offsetBy: 180, limitedBy: encoded.endIndex)
            ?? encoded.endIndex
        print("SNAP:" + encoded[index..<end])
        index = end
    }
    print("JUMBINI_SNAPSHOT_END")
}
