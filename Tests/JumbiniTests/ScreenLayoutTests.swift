import Testing
import CoreGraphics
import Foundation
@testable import Jumbini

// `ScreenLayout.current()` is the only part of the file that touches AppKit,
// and it is a two-line adapter. Everything that matters — the union frame, the
// scene translation, the dead zones — is a function of plain rectangles, so
// these tests build desks that this machine does not have: displays stacked
// vertically, displays of mismatched heights, a display left of the primary.
//
// Convention throughout, matching the source: `displays` are GLOBAL AppKit
// frames (y-up, origin at the primary's bottom-left), and anything named
// `scene…` is relative to the union frame's bottom-left.

// MARK: - Fixtures

/// The machine this was written on: one 1920x1080 display at the origin.
private let single = ScreenLayout(displays: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])

/// The classic desk: a 1440x900 laptop with an equal-height panel to its
/// right. Perfectly tiles its bounding box, so there is nowhere dead.
private let sideBySide = ScreenLayout(displays: [
    CGRect(x: 0, y: 0, width: 1440, height: 900),
    CGRect(x: 1440, y: 0, width: 1440, height: 900),
])

/// A display parked ABOVE the primary — equal widths, so again no dead zone.
private let stacked = ScreenLayout(displays: [
    CGRect(x: 0, y: 0, width: 1440, height: 900),
    CGRect(x: 0, y: 900, width: 1440, height: 900),
])

/// The awkward one: a short display to the right of a tall one, bottom-aligned.
/// The union is 3360x1080 and the top-right 1440x780 block is on no display.
private let mismatched = ScreenLayout(displays: [
    CGRect(x: 0, y: 0, width: 1920, height: 1080),
    CGRect(x: 1920, y: 0, width: 1440, height: 900),
])

/// A display to the LEFT of the primary, which is where negative global
/// coordinates come from.
private let leftOfPrimary = ScreenLayout(displays: [
    CGRect(x: 0, y: 0, width: 1920, height: 1080),
    CGRect(x: -1440, y: 0, width: 1440, height: 1080),
])

// MARK: - Single display: nothing may change

@Test func aSingleDisplayIsItsOwnUnionAndHasNoDeadZones() {
    #expect(single.unionFrame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    #expect(single.size == CGSize(width: 1920, height: 1080))
    #expect(single.hasDeadZones == false)
    #expect(single.roamableRects.isEmpty, "no dead zones means the brain keeps its plain-bounds fast path")
    #expect(single.primarySceneFrame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
}

@Test func onASingleDisplaySceneCoordinatesAreGlobalCoordinates() {
    let point = CGPoint(x: 300, y: 400)
    #expect(single.toScene(point) == point)
    #expect(single.toGlobal(point) == point)
}

@Test func onASingleDisplayEveryOnScreenPointIsContainedAndClampIsIdentity() {
    #expect(single.contains(CGPoint(x: 0, y: 0)))
    #expect(single.contains(CGPoint(x: 1920, y: 1080)), "the far edges count as on screen")
    #expect(single.contains(CGPoint(x: 960, y: 540)))
    #expect(single.clamp(CGPoint(x: 960, y: 540)) == CGPoint(x: 960, y: 540))
}

@Test func aLayoutWithNoDisplaysDegradesQuietly() {
    let empty = ScreenLayout(displays: [])
    #expect(empty.size == .zero)
    #expect(empty.contains(.zero) == false)
    #expect(empty.clamp(CGPoint(x: 5, y: 5)) == CGPoint(x: 5, y: 5), "nothing to clamp to, so nothing moves")
    #expect(empty.primarySceneFrame == CGRect(origin: .zero, size: .zero))
}

@Test func zeroSizedDisplaysAreDropped() {
    let layout = ScreenLayout(displays: [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: 1920, y: 0, width: 0, height: 0),
    ])
    #expect(layout.displays.count == 1)
    #expect(layout.hasDeadZones == false)
}

// MARK: - Side by side

@Test func sideBySideDisplaysUnionIntoOneWideSceneWithNoDeadZones() {
    #expect(sideBySide.unionFrame == CGRect(x: 0, y: 0, width: 2880, height: 900))
    #expect(sideBySide.hasDeadZones == false)
    #expect(sideBySide.roamableRects.isEmpty)
    #expect(sideBySide.sceneFrames == sideBySide.displays, "primary at the origin means scene == global")
}

@Test func theSeamBetweenTwoAbuttingDisplaysIsNotADeadZone() {
    // The whole point of the union overlay: he trots across x = 1440 without
    // anything special happening.
    #expect(sideBySide.contains(CGPoint(x: 1439, y: 450)))
    #expect(sideBySide.contains(CGPoint(x: 1440, y: 450)))
    #expect(sideBySide.contains(CGPoint(x: 1441, y: 450)))
}

@Test func theSecondDisplayIsWhereTheFirstIsNot() {
    #expect(sideBySide.sceneFrame(containing: CGPoint(x: 200, y: 450)) == sideBySide.sceneFrames[0])
    #expect(sideBySide.sceneFrame(containing: CGPoint(x: 2000, y: 450)) == sideBySide.sceneFrames[1])
}

// MARK: - Stacked

@Test func stackedDisplaysUnionIntoOneTallSceneWithNoDeadZones() {
    #expect(stacked.unionFrame == CGRect(x: 0, y: 0, width: 1440, height: 1800))
    #expect(stacked.hasDeadZones == false)
    #expect(stacked.contains(CGPoint(x: 720, y: 1700)))
    #expect(stacked.primarySceneFrame == CGRect(x: 0, y: 0, width: 1440, height: 900),
            "the primary is still the bottom one — the bed belongs there")
}

@Test func aDisplayBelowThePrimaryPushesTheSceneOriginDown() {
    let below = ScreenLayout(displays: [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 0, y: -900, width: 1440, height: 900),
    ])
    #expect(below.unionFrame == CGRect(x: 0, y: -900, width: 1440, height: 1800))
    // The primary's global bottom-left (0, 0) is 900 points up the scene.
    #expect(below.toScene(.zero) == CGPoint(x: 0, y: 900))
    #expect(below.primarySceneFrame == CGRect(x: 0, y: 900, width: 1440, height: 900))
}

// MARK: - Mismatched heights: the dead-zone case

@Test func mismatchedHeightsLeaveADeadZoneAboveTheShorterDisplay() {
    #expect(mismatched.unionFrame == CGRect(x: 0, y: 0, width: 3360, height: 1080))
    #expect(mismatched.hasDeadZones)
    #expect(mismatched.roamableRects.count == 2, "the brain must be told where the screens are")
    // Above the short display: inside the union, on no display.
    #expect(mismatched.contains(CGPoint(x: 2600, y: 1000)) == false)
    #expect(mismatched.sceneFrame(containing: CGPoint(x: 2600, y: 1000)) == nil)
    // Below the same x, on the short display: fine.
    #expect(mismatched.contains(CGPoint(x: 2600, y: 800)))
}

@Test func clampingOutOfADeadZoneTakesTheNearestRealScreen() {
    // 80 points above the short display's top edge and a long way from the
    // tall display's right edge — straight down is nearest.
    let rescued = mismatched.clamp(CGPoint(x: 2600, y: 980))
    #expect(rescued == CGPoint(x: 2600, y: 900))
    #expect(mismatched.contains(rescued))

    // Just past the tall display's right edge and high up: sideways is nearest.
    let sideways = mismatched.clamp(CGPoint(x: 1960, y: 1050))
    #expect(sideways == CGPoint(x: 1920, y: 1050))
    #expect(mismatched.contains(sideways))
}

@Test func clampLeavesAPointThatIsAlreadyOnADisplayExactlyWhereItIs() {
    // The furniture promise: a bed on the second monitor stays on the second
    // monitor, to the point, after any clamp.
    let onSecond = CGPoint(x: 3000, y: 120)
    #expect(mismatched.clamp(onSecond) == onSecond)
}

@Test func anInsetClampPullsAnEntityFullyOntoTheScreen() {
    // "Is he fully on a display?" — pass his half-size as the inset.
    #expect(mismatched.contains(CGPoint(x: 3355, y: 400), inset: 24) == false)
    #expect(mismatched.clamp(CGPoint(x: 3355, y: 400), inset: 24) == CGPoint(x: 3336, y: 400))
    #expect(mismatched.contains(CGPoint(x: 2600, y: 890), inset: 24) == false, "too near the short display's top")
    #expect(mismatched.clamp(CGPoint(x: 2600, y: 890), inset: 24) == CGPoint(x: 2600, y: 876))
}

@Test func anInsetLargerThanADisplayCollapsesToItsCentreRatherThanVanishing() {
    let tiny = ScreenLayout(displays: [CGRect(x: 0, y: 0, width: 40, height: 40)])
    #expect(tiny.clamp(CGPoint(x: 100, y: 100), inset: 60) == CGPoint(x: 20, y: 20))
}

// MARK: - A display left of the primary: negative origins

@Test func aDisplayLeftOfThePrimaryGivesTheUnionANegativeOrigin() {
    #expect(leftOfPrimary.unionFrame == CGRect(x: -1440, y: 0, width: 3360, height: 1080))
    #expect(leftOfPrimary.hasDeadZones == false)
    #expect(leftOfPrimary.primaryIndex == 0, "the primary is the display at the global origin, not the leftmost")
}

@Test func sceneCoordinatesShiftRightWhenADisplaySitsLeftOfThePrimary() {
    // The primary's global origin is 1440 points into the scene, so the bed
    // and the Dock corner move with it.
    #expect(leftOfPrimary.toScene(.zero) == CGPoint(x: 1440, y: 0))
    #expect(leftOfPrimary.toGlobal(CGPoint(x: 1440, y: 0)) == .zero)
    #expect(leftOfPrimary.primarySceneFrame == CGRect(x: 1440, y: 0, width: 1920, height: 1080))
    #expect(leftOfPrimary.sceneFrames[1] == CGRect(x: 0, y: 0, width: 1440, height: 1080))
}

@Test func theTranslationIsItsOwnInverse() {
    let point = CGPoint(x: -300, y: 700)
    #expect(leftOfPrimary.toGlobal(leftOfPrimary.toScene(point)) == point)
}

@Test func everythingInTheSceneIsOnAScreenWhenThereAreNoDeadZones() {
    for x in stride(from: CGFloat(0), through: 3360, by: 240) {
        for y in stride(from: CGFloat(0), through: 1080, by: 270) {
            #expect(leftOfPrimary.contains(CGPoint(x: x, y: y)),
                    "scene point (\(x), \(y)) should be on a display")
        }
    }
}

// MARK: - Picking the primary

@Test func thePrimaryIsTheDisplayAtTheGlobalOriginWhateverItsPosition() {
    let reordered = ScreenLayout(displays: [
        CGRect(x: -1440, y: 0, width: 1440, height: 900),
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
    ])
    #expect(reordered.primaryIndex == 1)
    #expect(reordered.primarySceneFrame == CGRect(x: 1440, y: 0, width: 1920, height: 1080))
}

@Test func withNoDisplayAtTheOriginTheFirstOneIsTreatedAsPrimary() {
    let adrift = ScreenLayout(displays: [
        CGRect(x: 100, y: 100, width: 800, height: 600),
        CGRect(x: 900, y: 100, width: 800, height: 600),
    ])
    #expect(adrift.primaryIndex == 0)
}

@Test func anExplicitPrimaryIndexWinsAndAnOutOfRangeOneIsIgnored() {
    let frames = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 1440, y: 0, width: 1440, height: 900),
    ]
    #expect(ScreenLayout(displays: frames, primaryIndex: 1).primaryIndex == 1)
    #expect(ScreenLayout(displays: frames, primaryIndex: 7).primaryIndex == 0)
}

// MARK: - Three displays

@Test func aThreeDisplayRowWithOneOddManOutStillFindsItsDeadZone() {
    let row = ScreenLayout(displays: [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: -1280, y: 0, width: 1280, height: 800),
        CGRect(x: 1920, y: 0, width: 1280, height: 1080),
    ])
    #expect(row.unionFrame == CGRect(x: -1280, y: 0, width: 4480, height: 1080))
    #expect(row.hasDeadZones, "the 1280x280 block above the short left display")
    #expect(row.contains(CGPoint(x: 100, y: 1000)) == false)
    #expect(row.contains(CGPoint(x: 100, y: 700)))
    #expect(row.contains(CGPoint(x: 4400, y: 1000)))
    #expect(row.roamableRects.count == 3)
}
