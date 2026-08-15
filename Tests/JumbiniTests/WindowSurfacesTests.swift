import Testing
import CoreGraphics
import Foundation
@testable import Jumbini

// The `WindowSurfaces` class itself talks to the window server, so it can't
// be exercised in a test process. Everything it decides can: the raw
// dictionaries go through one pure parser, and that is what these cover.
//
// Every fixture below is shaped like real `CGWindowListCopyWindowInfo`
// output — same keys, same nested bounds dictionary, same top-left-origin
// coordinates — so the filters and the coordinate flip are tested against the
// thing they actually receive.

// MARK: - Fixtures

/// A 1920×1080 single display with the scene covering all of it. Matches the
/// machine this was written on, and the simplest possible geometry.
private let screen = SurfaceGeometry(
    flipHeight: 1080,
    sceneOrigin: .zero,
    sceneSize: CGSize(width: 1920, height: 1080)
)

private let ourPID: pid_t = 501

/// One CGWindowList entry. Defaults describe a perfectly ordinary document
/// window so each test can vary exactly the one thing it cares about.
private func windowInfo(
    number: Int = 1,
    pid: Int = 900,
    owner: String = "Xcode",
    title: String? = "Untitled",
    layer: Int = 0,
    alpha: Double = 1,
    onScreen: Bool = true,
    x: Double = 400,
    y: Double = 200,
    width: Double = 640,
    height: Double = 480,
    includeBounds: Bool = true
) -> [String: Any] {
    var info: [String: Any] = [
        kCGWindowNumber as String: number,
        kCGWindowOwnerPID as String: pid,
        kCGWindowOwnerName as String: owner,
        kCGWindowLayer as String: layer,
        kCGWindowAlpha as String: alpha,
        kCGWindowIsOnscreen as String: onScreen,
    ]
    if let title { info[kCGWindowName as String] = title }
    if includeBounds {
        info[kCGWindowBounds as String] = [
            "X": NSNumber(value: x), "Y": NSNumber(value: y),
            "Width": NSNumber(value: width), "Height": NSNumber(value: height),
        ]
    }
    return info
}

private func parse(
    _ raw: [[String: Any]], geometry: SurfaceGeometry = screen
) -> [Surface] {
    WindowSurfaceParser.surfaces(from: raw, ownPID: ourPID, geometry: geometry)
}

// MARK: - Coordinate conversion

@Test func sceneRectFlipsCoreGraphicsTopLeftOriginToSceneBottomLeft() {
    // A window 200pt down from the top of a 1080pt display, 480pt tall:
    // its bottom edge is 680pt from the top, so 400pt up from the bottom.
    let converted = screen.sceneRect(from: CGRect(x: 400, y: 200, width: 640, height: 480))
    #expect(converted == CGRect(x: 400, y: 400, width: 640, height: 480))
    // And the perch line — the top of the window — is 880pt up.
    #expect(converted.maxY == 880)
}

@Test func aWindowFlushWithTheTopOfTheScreenPerchesAtTheTopOfTheScene() {
    let converted = screen.sceneRect(from: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    #expect(converted == CGRect(x: 0, y: 0, width: 1920, height: 1080))
}

@Test func theFlipIsItsOwnInverse() {
    // Round-tripping a rect through the conversion twice returns the original,
    // which is the property that makes the multi-monitor extension safe.
    let original = CGRect(x: 12, y: 34, width: 560, height: 300)
    let once = screen.sceneRect(from: original)
    let twice = screen.sceneRect(from: once)
    #expect(twice == original)
}

@Test func sceneOriginOffsetsTheResultForANonPrimaryOverlay() {
    // The extension point the multi-monitor agent uses: a second display sits
    // to the right of the primary, so its overlay's scene origin is x=1920.
    // The CG flip axis stays the PRIMARY display's height.
    let secondary = SurfaceGeometry(
        flipHeight: 1080,
        sceneOrigin: CGPoint(x: 1920, y: 0),
        sceneSize: CGSize(width: 1440, height: 900)
    )
    let converted = secondary.sceneRect(from: CGRect(x: 2000, y: 100, width: 400, height: 300))
    #expect(converted == CGRect(x: 80, y: 680, width: 400, height: 300))
}

@Test func aNegativeSceneOriginIsJustATranslation() {
    // A display left of the primary has a negative global x; nothing special
    // happens, which is the point.
    let leftOfPrimary = SurfaceGeometry(
        flipHeight: 1080,
        sceneOrigin: CGPoint(x: -1440, y: 0),
        sceneSize: CGSize(width: 1440, height: 900)
    )
    let converted = leftOfPrimary.sceneRect(from: CGRect(x: -1400, y: 80, width: 500, height: 400))
    #expect(converted == CGRect(x: 40, y: 600, width: 500, height: 400))
}

// MARK: - The happy path

@Test func anOrdinaryDocumentWindowBecomesASurface() {
    let surfaces = parse([windowInfo(number: 77, pid: 900, title: "README.md")])
    #expect(surfaces.count == 1)
    #expect(surfaces.first?.id == 77)
    #expect(surfaces.first?.ownerPID == 900)
    #expect(surfaces.first?.title == "README.md")
    #expect(surfaces.first?.rect == CGRect(x: 400, y: 400, width: 640, height: 480))
    #expect(surfaces.first?.topY == 880)
}

@Test func frontMostOrderIsPreserved() {
    // CGWindowList returns front-to-back; the dog should prefer the front.
    let surfaces = parse([
        windowInfo(number: 1, x: 0),
        windowInfo(number: 2, x: 200),
        windowInfo(number: 3, x: 400),
    ])
    #expect(surfaces.map(\.id) == [1, 2, 3])
}

@Test func aMissingTitleIsFineBecauseTitlesNeedScreenRecording() {
    // kCGWindowName is permission-gated; geometry is not. A nil title must
    // never disqualify a perch.
    let surfaces = parse([windowInfo(title: nil)])
    #expect(surfaces.count == 1)
    #expect(surfaces.first?.title == nil)
}

@Test func anEmptyWindowListYieldsNoSurfaces() {
    #expect(parse([]).isEmpty)
}

// MARK: - Filtering: us, chrome, and junk

@Test func jumbinisOwnOverlayIsNeverAPerch() {
    let surfaces = parse([windowInfo(pid: Int(ourPID), owner: "Jumbini")])
    #expect(surfaces.isEmpty, "the dog cannot stand on himself")
}

@Test func theDesktopAndWallpaperLayersAreRejected() {
    // The wallpaper sits at a large negative layer.
    let surfaces = parse([
        windowInfo(number: 1, owner: "Finder", title: "Desktop", layer: -2_147_483_603,
                   x: 0, y: 0, width: 1920, height: 1080),
        windowInfo(number: 2, owner: "Wallpaper", layer: -2_147_483_624,
                   x: 0, y: 0, width: 1920, height: 1080),
    ])
    #expect(surfaces.isEmpty)
}

@Test func theMenuBarAndDockLayersAreRejected() {
    let surfaces = parse([
        windowInfo(number: 1, owner: "Window Server", title: "Menubar", layer: 24,
                   x: 0, y: 0, width: 1920, height: 30),
        windowInfo(number: 2, owner: "Dock", title: "Dock", layer: 20,
                   x: 0, y: 1000, width: 1920, height: 80),
    ])
    #expect(surfaces.isEmpty)
}

@Test func chromeOwnersOnTheDocumentLayerAreStillRejected() {
    // Belt-and-braces: the Dock occasionally parks something on layer 0.
    let surfaces = parse([windowInfo(owner: "Dock", layer: 0)])
    #expect(surfaces.isEmpty)
}

@Test func zeroAndOnePixelWindowsAreRejected() {
    let surfaces = parse([
        windowInfo(number: 1, width: 0, height: 0),
        windowInfo(number: 2, width: 1, height: 1),
        windowInfo(number: 3, width: 640, height: 1),
    ])
    #expect(surfaces.isEmpty)
}

@Test func narrowWindowsAreNotPlausiblePerches() {
    // Just under the 120pt minimum width: nowhere to trot.
    #expect(parse([windowInfo(width: 119)]).isEmpty)
    #expect(parse([windowInfo(width: 120)]).count == 1, "exactly 120pt is wide enough")
}

@Test func invisibleWindowsAreRejected() {
    #expect(parse([windowInfo(alpha: 0)]).isEmpty)
    #expect(parse([windowInfo(alpha: 0.01)]).isEmpty)
    #expect(parse([windowInfo(alpha: 1)]).count == 1)
}

@Test func aWindowFlaggedOffscreenIsRejected() {
    #expect(parse([windowInfo(onScreen: false)]).isEmpty)
}

@Test func aMissingAlphaKeyIsTreatedAsOpaque() {
    var info = windowInfo()
    info.removeValue(forKey: kCGWindowAlpha as String)
    #expect(parse([info]).count == 1)
}

@Test func entriesMissingIdentityOrGeometryAreSkippedNotCrashed() {
    var noNumber = windowInfo()
    noNumber.removeValue(forKey: kCGWindowNumber as String)
    var noPID = windowInfo(number: 2)
    noPID.removeValue(forKey: kCGWindowOwnerPID as String)
    let noBounds = windowInfo(number: 3, includeBounds: false)
    var junkBounds = windowInfo(number: 4)
    junkBounds[kCGWindowBounds as String] = ["X": NSNumber(value: 1)] // half a rect

    #expect(parse([noNumber, noPID, noBounds, junkBounds]).isEmpty)
}

// MARK: - Filtering: off-screen and out-of-reach

@Test func aWindowDraggedOffTheRightEdgeIsRejected() {
    // Only 40pt of it overlaps the scene — less than the 60pt minimum.
    #expect(parse([windowInfo(x: 1880, width: 640)]).isEmpty)
}

@Test func aWindowMostlyOffTheLeftEdgeKeepsItsUsableStrip() {
    // 200pt of a 640pt window is still on screen: a perfectly good ledge.
    let surfaces = parse([windowInfo(x: -440, width: 640)])
    #expect(surfaces.count == 1)
    #expect(surfaces.first?.rect.minX == -440, "the rect is not clipped, only culled")
}

@Test func aWindowWhoseTopEdgeIsAboveTheSceneIsRejected() {
    // A full-screen-height window on a taller virtual display: its perch line
    // lands outside the scene, so there is nothing to stand on here.
    let surfaces = parse([windowInfo(y: -400, height: 480)])
    #expect(surfaces.isEmpty)
}

@Test func aWindowEntirelyBelowTheSceneFloorIsRejected() {
    // y=1080 on a 1080-tall display is at (or under) the bottom edge.
    #expect(parse([windowInfo(y: 1080, height: 480)]).isEmpty)
}

// MARK: - Filtering: dead zones on a multi-display desk

// One overlay spans the bounding box of every display, so the scene can
// contain regions that are on no display at all. A title bar out there is
// drawn nowhere, and a dog patrolling it has vanished — so the reachability
// test measures the top edge against the DISPLAYS, not against the scene box.
//
// `screenRects` empty means "the scene box is all screen", which is the
// single-display case and every fixture above.

/// A 1920x1080 primary with a bottom-aligned 1440x900 panel to its right.
/// Scene is 3360x1080; the top 180pt of the right-hand 1440 is dead.
private let unevenPair = SurfaceGeometry(
    flipHeight: 1080,
    sceneOrigin: .zero,
    sceneSize: CGSize(width: 3360, height: 1080),
    screenRects: [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: 1920, y: 0, width: 1440, height: 900),
    ]
)

@Test func aTitleBarOnTheSecondDisplayIsAPerch() {
    // CG y=200 on the shared flip axis -> scene y=880 for the top edge; that
    // is inside the short display, which only reaches 900.
    let surfaces = parse([windowInfo(x: 2200, y: 200, width: 640, height: 480)], geometry: unevenPair)
    #expect(surfaces.count == 1)
    #expect(surfaces.first?.topY == 880)
}

@Test func aTitleBarStrandedInADeadZoneIsNotAPerch() {
    // Same window, 100pt higher: its top edge is now at scene y=980, in the
    // strip above the short display, where nothing is drawn at all.
    #expect(parse([windowInfo(x: 2200, y: 100, width: 640, height: 480)], geometry: unevenPair).isEmpty)
}

@Test func aWindowStraddlingTheSeamIsJudgedOnTheVisiblePartOfItsTopEdge() {
    // Straddling the boundary, high up: only the 100pt over the tall display
    // is real, and 100 >= the 60pt minimum, so he can still get on it.
    let straddling = parse(
        [windowInfo(x: 1820, y: 100, width: 640, height: 480)], geometry: unevenPair
    )
    #expect(straddling.count == 1)

    // Nudged right so only 40pt of the top edge is over the tall display and
    // the rest hangs in the dead zone: not enough ledge to be worth it.
    #expect(parse(
        [windowInfo(x: 1880, y: 100, width: 640, height: 480)], geometry: unevenPair
    ).isEmpty)
}

@Test func theDeadZoneRuleAddsUpDisjointStretchesOfRealScreen() {
    // A short middle display with taller ones either side: a wide window high
    // up is visible at both ends and dead in the middle. 60pt of ledge on the
    // left plus 60 on the right is 120 — reachable.
    let valley = SurfaceGeometry(
        flipHeight: 1000,
        sceneOrigin: .zero,
        sceneSize: CGSize(width: 3000, height: 1000),
        screenRects: [
            CGRect(x: 0, y: 0, width: 1000, height: 1000),
            CGRect(x: 1000, y: 0, width: 1000, height: 600),
            CGRect(x: 2000, y: 0, width: 1000, height: 1000),
        ]
    )
    // Top edge at scene y = 1000 - 200 = 800, above the middle display.
    let surfaces = parse(
        [windowInfo(x: 940, y: 200, width: 1120, height: 480)], geometry: valley
    )
    #expect(surfaces.count == 1, "60pt on the left plus 60pt on the right clears the minimum")

    // Shrink both overhangs to 20pt each and the same window has nowhere to
    // stand: 40pt of ledge in two pieces is not a walk, it is a stumble.
    #expect(parse(
        [windowInfo(x: 980, y: 200, width: 1040, height: 480)], geometry: valley
    ).isEmpty)
}

@Test func describingTheScreensChangesNothingOnASingleDisplay() {
    let described = SurfaceGeometry(
        flipHeight: 1080,
        sceneOrigin: .zero,
        sceneSize: CGSize(width: 1920, height: 1080),
        screenRects: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    )
    #expect(parse([windowInfo()], geometry: described) == parse([windowInfo()]))
    #expect(parse([windowInfo(x: 1880, width: 640)], geometry: described).isEmpty)
    #expect(parse([windowInfo(x: -440, width: 640)], geometry: described).count == 1)
}

// MARK: - Bounds decoding

@Test func boundsDecodingMatchesTheWindowServersDictionaryShape() {
    let rect = WindowSurfaceParser.boundsRect(from: [
        "X": NSNumber(value: 10), "Y": NSNumber(value: 20),
        "Width": NSNumber(value: 30), "Height": NSNumber(value: 40),
    ])
    #expect(rect == CGRect(x: 10, y: 20, width: 30, height: 40))
    #expect(WindowSurfaceParser.boundsRect(from: nil) == nil)
    #expect(WindowSurfaceParser.boundsRect(from: "not a dictionary") == nil)
}

// MARK: - A realistic mixed list

@Test func arealWindowListDistilsToJustThePerchableWindows() {
    // Modelled on an actual CGWindowList dump from a working Mac: wallpaper,
    // menu bar, Dock, our own overlay, a tooltip, and three real windows.
    let surfaces = parse([
        windowInfo(number: 10, owner: "Window Server", title: "Menubar", layer: 24,
                   x: 0, y: 0, width: 1920, height: 30),
        windowInfo(number: 11, pid: Int(ourPID), owner: "Jumbini", title: nil, layer: 0,
                   x: 0, y: 0, width: 1920, height: 1080),
        windowInfo(number: 12, owner: "Conductor", title: "Conductor",
                   x: 0, y: 30, width: 960, height: 1050),
        windowInfo(number: 13, owner: "Xcode", title: "PetScene.swift",
                   x: 720, y: 135, width: 480, height: 632),
        windowInfo(number: 14, owner: "Xcode", title: nil, layer: 25,
                   x: 800, y: 300, width: 240, height: 60), // a tooltip
        windowInfo(number: 15, owner: "Finder", title: "nassau",
                   x: 562, y: 166, width: 1317, height: 767),
        windowInfo(number: 16, owner: "Dock", title: "Dock", layer: 20,
                   x: 0, y: 1000, width: 1920, height: 80),
        windowInfo(number: 17, owner: "Finder", title: nil, layer: -2_147_483_603,
                   x: 0, y: 0, width: 1920, height: 1080), // the desktop
    ])

    #expect(surfaces.map(\.id) == [12, 13, 15])
    // Conductor's title bar: 30pt down from the top of a 1080pt screen.
    #expect(surfaces.first?.topY == 1050)
    #expect(surfaces.map(\.title) == ["Conductor", "PetScene.swift", "nassau"])
}
