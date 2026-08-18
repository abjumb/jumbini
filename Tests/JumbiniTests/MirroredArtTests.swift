import Testing
import Foundation
@testable import Jumbini

// Three reseat methods in PetScene divide the dog's own xScale back out of a
// child node's transform. That compensation is dormant: xScale is only ±1 when
// an animation sets `flipX`, and the only place that happens is
// `SpriteLoader.yap`'s fallback to the old six-frame east-only bark strip,
// mirrored for the west-ish facings. The bundled art has `bark_<facing>` and
// `idle_<facing>` for all eight rotations, so `yap` always takes the real path
// and the fallback never fires.
//
// That fact is load-bearing in both directions. While it holds, a missing flip
// is invisible — which is exactly how `reseatCarriedBall` went without one for
// so long. If it stops holding, three pieces of compensation and their comments
// go live at once and a fourth had better be there too. So it is pinned here
// rather than left as something a reader has to re-derive from the asset folder.

@MainActor
@Test func mirroredArtIsUnreachableOnTheShippedSpriteSet() {
    for facing in Facing.allCases {
        let bark = SpriteLibrary.shared.animation(for: .bark, facing: facing)
        #expect(bark != nil, "no bark animation for \(facing)")
        #expect(
            bark?.flipX == false,
            """
            \(facing) resolved to the mirrored six-frame fallback, so the dog's \
            xScale can now be -1. Every reseat* method in PetScene that divides \
            parentFlip back out is suddenly load-bearing — check they all still \
            do it.
            """
        )
    }
}

@MainActor
@Test func everyFacingHasItsOwnBarkAndIdleArt() {
    // The precondition for the test above: yap() needs both files per rotation
    // before it will take the real path. Losing one of these is what would flip
    // that facing back to the mirrored strip.
    for facing in Facing.allCases {
        let suffix = facing.fileSuffix
        for name in ["bark_\(suffix)", "idle_\(suffix)"] {
            #expect(
                Bundle.assets.url(forResource: name, withExtension: "png", subdirectory: "jumba") != nil,
                "\(name).png is missing from the bundled jumba art"
            )
        }
    }
}
