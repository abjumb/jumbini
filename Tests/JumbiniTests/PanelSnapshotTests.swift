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
/// The window *including* its title bar.
///
/// `contentView` stops below the title bar, so every earlier render of this
/// panel was missing the one part of the reference design that lives up there:
/// the traffic light. `contentView.superview` is the frame view that owns both,
/// which is what has to be captured to check the corner at all.
@MainActor
private func renderSettingsWindow() -> (image: NSBitmapImageRep, size: NSSize)? {
    let panel = SettingsPanel(defaults: UserDefaults(suiteName: "snapshot.window") ?? .standard)
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    guard let frame = panel.contentView?.superview else { return nil }
    frame.layoutSubtreeIfNeeded()
    let bounds = frame.bounds
    guard bounds.width > 1, bounds.height > 1,
          let rep = frame.bitmapImageRepForCachingDisplay(in: bounds)
    else { return nil }
    panel.effectiveAppearance.performAsCurrentDrawingAppearance {
        frame.cacheDisplay(in: bounds, to: rep)
    }
    return (rep, bounds.size)
}

@Test @MainActor func theCloseButtonSitsInTheTopLeftCorner() {
    let panel = SettingsPanel(defaults: UserDefaults(suiteName: "snapshot.corner") ?? .standard)
    guard let close = panel.standardWindowButton(.closeButton),
          let frame = panel.contentView?.superview
    else {
        Issue.record("no close button or frame view")
        return
    }
    let spot = close.convert(close.bounds, to: frame)
    // Top-left, in a frame view whose origin is bottom-left: near x = 0, and
    // within the title bar's height of the top edge. The design puts it there;
    // the version this replaced drew its own glyph in the opposite corner.
    #expect(spot.minX < 40, "close button x = \(spot.minX)")
    #expect(spot.maxY > frame.bounds.height - 40, "close button y = \(spot.maxY)")
}

/// Depth-first search for the first view of a given type. The panel's fields are
/// private, and `@testable` does not reach `private` — but the view hierarchy is
/// public by construction, so the geometry checks find their subject by walking it.
@MainActor
private func firstSubview<T: NSView>(of type: T.Type, under root: NSView) -> T? {
    if let hit = root as? T { return hit }
    for child in root.subviews {
        if let hit = firstSubview(of: type, under: child) { return hit }
    }
    return nil
}

@Test @MainActor func theSearchFieldClearsTheTrafficLights() {
    let panel = SettingsPanel(defaults: UserDefaults(suiteName: "snapshot.search") ?? .standard)
    guard let frame = panel.contentView?.superview,
          let content = panel.contentView,
          let close = panel.standardWindowButton(.closeButton),
          let search = firstSubview(of: NSSearchField.self, under: content)
    else {
        Issue.record("no search field, close button or frame view")
        return
    }
    frame.layoutSubtreeIfNeeded()
    let light = close.convert(close.bounds, to: frame)
    let field = search.convert(search.bounds, to: frame)
    // The title bar is transparent with its title hidden, so it is invisible —
    // and content laid out to the window's top edge runs straight underneath the
    // traffic lights that are still sitting in it. The first version of this
    // sidebar put the search field there: three dots on top of a text field.
    // Frame-view coordinates are bottom-left, so "below" is a smaller maxY.
    #expect(
        field.maxY <= light.minY,
        "search field top \(field.maxY) is above the close button's bottom \(light.minY)"
    )
}

@Test @MainActor func settingsSnapshotIsPrintedWhenAskedFor() {
    guard ProcessInfo.processInfo.environment["JUMBINI_SNAPSHOT"] == "1" else { return }
    guard let (rep, _) = renderSettingsWindow() ?? renderSettingsLayout(),
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

@Test @MainActor func theSettingsLayoutActuallyRendersDark() {
    guard let (rep, size) = renderSettingsLayout() else {
        Issue.record("settings layout produced no bitmap")
        return
    }
    // The bug this exists for: a dynamic NSColor asked for its .cgColor resolves
    // once, against whatever appearance is current at that moment. Every
    // layer-backed surface froze light while the text on top of it went dark,
    // so the card came out white with white lettering and the login checkbox
    // vanished. Nothing else here noticed — it compiled, it laid out at the
    // right size, and it had plenty of distinct colours.
    var samples: [CGFloat] = []
    for x in stride(from: 8, to: Int(size.width) - 8, by: 23) {
        for y in stride(from: 8, to: Int(size.height) - 8, by: 23) {
            guard let colour = rep.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB) else { continue }
            samples.append(
                0.299 * colour.redComponent
                    + 0.587 * colour.greenComponent
                    + 0.114 * colour.blueComponent
            )
        }
    }
    guard !samples.isEmpty else {
        Issue.record("could not sample the render")
        return
    }
    let mean = samples.reduce(0, +) / CGFloat(samples.count)
    #expect(mean < 0.5, "mean luminance \(mean) — the panel rendered light")
}
