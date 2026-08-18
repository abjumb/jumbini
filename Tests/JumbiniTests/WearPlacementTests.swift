import CoreGraphics
import Foundation
import Testing
@testable import Jumbini

// Where a worn piece goes. This arithmetic spent its life inside an SKScene
// method, so none of it had ever been checked — including the numbers a
// wardrobe bug actually lives in.
//
// The decisions are pinned exactly; everything else is asserted as a
// relationship. The slot rows, the head lean and the hat sink are tuning: if a
// test pinned their products, every nudge to the art would be a test edit and
// the suite would stop being able to disagree with the code.

/// A 16x16 canvas with 12x8 of ink centred in it, rendering 20pt wide at the
/// front. Nothing here is load-bearing — the tests vary one thing at a time.
private func piece(slot: WearSlot, ink: CGRect? = nil) -> WearPlacement.Piece {
    WearPlacement.Piece(
        canvas: CGSize(width: 16, height: 16),
        ink: ink ?? CGRect(x: 2, y: 4, width: 12, height: 8),
        frontInkWidth: 12,
        frontWidth: 20,
        slot: slot
    )!
}

private func pose(
    facing: Facing = .south,
    isTallCanvas: Bool = false,
    wearScale: CGFloat = 1,
    flip: CGFloat = 1,
    mirrored: Bool = false
) -> WearPlacement.Pose {
    WearPlacement.Pose(
        dogSize: CGSize(width: 100, height: 100),
        facing: facing,
        isTallCanvas: isTallCanvas,
        wearScale: wearScale,
        flip: flip,
        mirrored: mirrored
    )
}

// MARK: - A piece with no ink is not a piece

@Test func aFrontViewWithNoInkCannotMakeAPiece() {
    // Points-per-pixel is frontWidth / frontInkWidth, so this would divide by
    // zero. The scene hides the node on nil, as it always did — the difference
    // is that the next caller cannot forget the check.
    #expect(
        WearPlacement.Piece(
            canvas: CGSize(width: 16, height: 16),
            ink: CGRect(x: 2, y: 4, width: 12, height: 8),
            frontInkWidth: 0,
            frontWidth: 20,
            slot: .crown
        ) == nil
    )
}

// MARK: - How a piece hangs

@Test func aCrownHangsByItsInkBottomAndEverythingElseByItsMiddle() {
    // The one branch in the vertical placement: a brim lands on his crown, a
    // collar sits on the collar line.
    let crown = WearPlacement(piece: piece(slot: .crown), pose: pose())
    let neck = WearPlacement(piece: piece(slot: .neck), pose: pose())

    #expect(crown.position.y > neck.position.y, "the crown slot sits higher on him")

    // Hung by different edges of the same ink, so the same slot row would still
    // put them at different heights.
    let crownAtNeckRow = WearPlacement(piece: piece(slot: .crown), pose: pose())
    #expect(crownAtNeckRow.position.y == crown.position.y)
}

@Test func aDeeperHatSettlesFurtherIntoTheHead() {
    // The sink is a fraction of the piece's OWN ink height, so a deeper hat
    // sits lower. `maxY` is held equal on purpose: it feeds the separate
    // ink-bottom term, and letting it move too would swamp the sink — which is
    // exactly what the first version of this test did, and why it disagreed
    // with correct code.
    let shallow = WearPlacement(
        piece: piece(slot: .crown, ink: CGRect(x: 2, y: 4, width: 12, height: 4)), pose: pose()
    )
    let deep = WearPlacement(
        piece: piece(slot: .crown, ink: CGRect(x: 2, y: 0, width: 12, height: 8)), pose: pose()
    )

    #expect(deep.position.y < shallow.position.y)
}

// MARK: - How the pose moves it

@Test func aTallCanvasPoseShiftsTheAnchor() {
    // The sit and bark exports draw him lower in frame, so every anchor moves
    // with him. Which direction matters; the exact fraction is tuning.
    let short = WearPlacement.anchor(for: .crown, pose: pose(isTallCanvas: false))
    let tall = WearPlacement.anchor(for: .crown, pose: pose(isTallCanvas: true))

    #expect(tall.y < short.y, "he sits lower in the taller canvas, so his crown does too")
}

@Test func facingSidewaysLeansTheAnchorTowardTheHead() {
    // Facing east or west he is drawn with his head off the canvas centre, and
    // a hat belongs over the head, not the shoulder.
    let facingSouth = WearPlacement.anchor(for: .crown, pose: pose(facing: .south))
    let facingEast = WearPlacement.anchor(for: .crown, pose: pose(facing: .east))
    let facingWest = WearPlacement.anchor(for: .crown, pose: pose(facing: .west))

    #expect(facingSouth.x == 0, "facing the viewer, his head is on the canvas centre")
    #expect(facingEast.x > 0)
    #expect(facingWest.x < 0)
    #expect(abs(facingEast.x) == abs(facingWest.x), "the lean is symmetric")
}

@Test func aPieceGrowsWithTheHeadItIsOn() {
    // wearScale exists because the sit and bark sets render about a fifth
    // larger, and a hat has to grow with the head it is on.
    let normal = WearPlacement(piece: piece(slot: .crown), pose: pose(wearScale: 1))
    let bigger = WearPlacement(piece: piece(slot: .crown), pose: pose(wearScale: 1.2))

    #expect(bigger.size.width == normal.size.width * 1.2)
    #expect(bigger.size.height == normal.size.height * 1.2)
}

// MARK: - Which way round, and which side of him

@Test func mirroredArtFlipsThePieceAndItsOffset() {
    // Live behaviour: half the directions are drawn as the mirror of another.
    let ink = CGRect(x: 1, y: 4, width: 12, height: 8) // deliberately off-centre
    let upright = WearPlacement(piece: piece(slot: .eyes, ink: ink), pose: pose())
    let mirrored = WearPlacement(piece: piece(slot: .eyes, ink: ink), pose: pose(mirrored: true))

    #expect(mirrored.xScale == -upright.xScale)
    // The anchor is unchanged (facing .south), so the ink offset is what flips.
    #expect(mirrored.position.x == -upright.position.x)
    #expect(mirrored.position.y == upright.position.y, "mirroring is horizontal only")
}

@Test func aPieceTucksBehindHimWhenHeFacesAway() {
    for facing in Facing.allCases {
        let placement = WearPlacement(piece: piece(slot: .crown), pose: pose(facing: facing))
        #expect(
            placement.zPosition == (facing.isNorthish ? -1 : 1),
            "\(facing) put the piece on the wrong side of him"
        )
    }
}

@Test func aFlippedParentIsDividedBackOut() {
    // This pins what happens IF the mirrored path becomes reachable, and is the
    // companion to MirroredArtTests, which pins that it currently is not: the
    // dog's xScale is only -1 via SpriteLoader.yap's six-frame fallback, which
    // the shipped 8-rotation bark art makes unreachable. A child node inherits
    // its parent's transform, so the compensation has to exist for that build —
    // and reseatCarriedBall shipped without it for exactly as long as nobody
    // could see the difference.
    let ink = CGRect(x: 1, y: 4, width: 12, height: 8)
    let upright = WearPlacement(piece: piece(slot: .eyes, ink: ink), pose: pose(facing: .east))
    let flipped = WearPlacement(
        piece: piece(slot: .eyes, ink: ink), pose: pose(facing: .east, flip: -1)
    )

    #expect(flipped.position.x == -upright.position.x)
    #expect(flipped.xScale == -upright.xScale)
    #expect(flipped.position.y == upright.position.y)
    #expect(flipped.size == upright.size, "a parent flip does not resize the piece")
}
