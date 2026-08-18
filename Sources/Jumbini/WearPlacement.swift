import CoreGraphics
import Foundation

/// The places a wardrobe piece can hang off him. The catalog names a place
/// ("this is eyewear"), not a nudge ("this is 3pt lower than the hats") — which
/// is what keeps the per-item numbers down to one.
enum WearSlot: Hashable {
    case crown, eyes, neck, body
}

/// Where a worn piece goes: its size, where it sits relative to the dog's
/// centre, which way round it is drawn, and whether it is in front of him.
///
/// This was 45 lines inside `PetScene.reseatWornItem`, which needs an `SKView`
/// and a window, so none of it could be exercised — including the numbers a
/// wardrobe bug actually lives in: the slot rows, the head lean, the hat sink,
/// and the mirroring. The arithmetic never touched the scene; it only lived
/// there because the nodes it assigned to did.
///
/// The two inputs are grouped on the axis the questions come in. "Does a crown
/// sit right when he sits, or faces north-west, or is mirrored?" is one `Piece`
/// against several `Pose`s. "Does a crown hang differently from a collar?" is
/// one `Pose` against several `Piece`s.
struct WearPlacement {
    let size: CGSize
    let position: CGPoint
    let xScale: CGFloat
    let zPosition: CGFloat

    /// Everything about the thing being worn.
    struct Piece {
        /// The art's full canvas, including its transparent margin.
        let canvas: CGSize
        /// The drawn pixels inside that canvas.
        let ink: CGRect
        /// The ink width of the item's FRONT view, which fixes points-per-pixel
        /// for every direction so the side views come out narrower on their own
        /// instead of being stretched to match.
        let frontInkWidth: CGFloat
        /// How wide the front view should render, in points.
        let frontWidth: CGFloat
        let slot: WearSlot

        /// Fails when the front view has no ink, because points-per-pixel is
        /// `frontWidth / frontInkWidth` and a piece that cannot be scaled is not
        /// a piece. The scene hides the node on nil, which is what it did when
        /// this was a guard clause — the difference is that now it cannot be
        /// forgotten by the next caller.
        init?(canvas: CGSize, ink: CGRect, frontInkWidth: CGFloat, frontWidth: CGFloat, slot: WearSlot) {
            guard frontInkWidth > 0 else { return nil }
            self.canvas = canvas
            self.ink = ink
            self.frontInkWidth = frontInkWidth
            self.frontWidth = frontWidth
            self.slot = slot
        }
    }

    /// Everything about how the dog is drawn at this instant.
    struct Pose {
        /// His node's live size, which changes with the pose.
        let dogSize: CGSize
        /// The direction the art ACTUALLY faces, which is not always the
        /// direction he is logically facing — the dangle and bark poses draw him
        /// looking somewhere his facing disagrees with.
        let facing: Facing
        /// The sit and bark exports are drawn on a 68x76 canvas instead of
        /// 48x48, so he sits lower in frame and every anchor shifts with him.
        let isTallCanvas: Bool
        /// How big he is drawn relative to his baseline idle art, so a hat grows
        /// with the head it is on.
        let wearScale: CGFloat
        /// The dog's own xScale, which a child node inherits and which therefore
        /// has to be divided back out. `1` in every production call today: it is
        /// only -1 when an animation sets `flipX`, which the shipped art makes
        /// unreachable (see `MirroredArtTests`). Kept because the fallback that
        /// would set it is kept.
        let flip: CGFloat
        /// Whether this direction's art is the mirror of another direction's.
        /// Unlike `flip`, this one is live.
        let mirrored: Bool

        init(
            dogSize: CGSize,
            facing: Facing,
            isTallCanvas: Bool,
            wearScale: CGFloat,
            flip: CGFloat = 1,
            mirrored: Bool = false
        ) {
            self.dogSize = dogSize
            self.facing = facing
            self.isTallCanvas = isTallCanvas
            self.wearScale = wearScale
            self.flip = flip
            self.mirrored = mirrored
        }
    }

    init(piece: Piece, pose: Pose) {
        // Points per art pixel, fixed per item by its front view. `wearScale`
        // keeps the piece the same size on him across poses.
        let scale = piece.frontWidth / piece.frontInkWidth * pose.wearScale
        size = CGSize(width: piece.canvas.width * scale, height: piece.canvas.height * scale)

        // Where the ink sits inside the node, measured from the node centre.
        let inkX = (piece.ink.midX - piece.canvas.width / 2) * scale
        let inkCentreY = (piece.canvas.height / 2 - piece.ink.midY) * scale
        let inkBottomY = (piece.canvas.height / 2 - piece.ink.maxY) * scale

        let anchor = Self.anchor(for: piece.slot, pose: pose)
        let mirror: CGFloat = pose.mirrored ? -1 : 1

        // A hat hangs by the bottom edge of its ink (the brim lands on his
        // crown); everything else hangs by the middle of its ink.
        let y = piece.slot == .crown
            ? anchor.y - piece.ink.height * scale * Self.hatSink - inkBottomY
            : anchor.y - inkCentreY

        position = CGPoint(x: pose.flip * (anchor.x - mirror * inkX), y: y)
        xScale = mirror * pose.flip
        zPosition = pose.facing.isNorthish ? -1 : 1
    }

    /// Where a worn piece hangs, relative to the dog's centre. Uses his live
    /// node size, so the anchor tracks pose changes without the art knowing
    /// anything about poses.
    static func anchor(for slot: WearSlot, pose: Pose) -> CGPoint {
        let rows = slotRows[slot] ?? (0.5, 0.5)
        let tall = pose.isTallCanvas
        let v = pose.facing.unitVector
        return CGPoint(
            x: v.x * pose.dogSize.width * (tall ? headLean.tall : headLean.short),
            y: pose.dogSize.height * (0.5 - (tall ? rows.tall : rows.short))
        )
    }

    /// Where each slot sits, as a fraction of the art canvas measured DOWN from
    /// its top. Two columns because Jumba's art comes in two canvas families:
    /// the 48x48 poses (idle, walk, sleep, sniff…) and the taller 68x76 sit/bark
    /// exports, which draw him lower in frame. Read off idle_south and
    /// sit_south — crown is the top of his head, eyes the eye row, neck the
    /// collar line, body mid-chest.
    private static let slotRows: [WearSlot: (short: CGFloat, tall: CGFloat)] = [
        .crown: (0.14, 0.28),
        .eyes: (0.29, 0.37),
        .neck: (0.50, 0.52),
        .body: (0.62, 0.60),
    ]

    /// Sideways lean of the anchor, as a fraction of the node width: facing east
    /// or west he is drawn with his head off the canvas centre, and a hat
    /// belongs over the head, not the shoulder.
    private static let headLean: (short: CGFloat, tall: CGFloat) = (0.145, 0.10)

    /// How far a hat settles into the head, as a fraction of its own ink height.
    private static let hatSink: CGFloat = 0.15
}
