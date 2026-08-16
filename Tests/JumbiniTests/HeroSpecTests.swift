import Testing
import Foundation
import CoreGraphics
@testable import Jumbini

// spritefilm renders the landing page's hero loops from the same PNGs the app
// uses, and has to run them at the same rate — otherwise the dog on the
// website drifts out of step with the dog in the product, one release at a
// time, and nobody notices. The CLI reads animations.json; this pins that file
// to SpriteLibrary so the build fails instead of the marketing.

@Test func walkIsTheTwoRunFramesAtFourFrames() {
    #expect(
        SpriteLibrary.heroSpec(for: .walk, facing: .south)
            == AnimationSpec(frames: ["run1_south", "run2_south"], fps: 4, scale: 2.4)
    )
}

@Test func runReusesTheWalkFramesFasterRatherThanNewArt() {
    let walk = SpriteLibrary.heroSpec(for: .walk, facing: .east)
    let run = SpriteLibrary.heroSpec(for: .run, facing: .east)
    #expect(walk?.frames == run?.frames)
    #expect(run?.fps == 13)
}

@Test func sitCarriesItsOwnScaleBecauseTheArtWasExportedSmaller() {
    #expect(
        SpriteLibrary.heroSpec(for: .sit, facing: .south)
            == AnimationSpec(frames: ["sit_south"], fps: 1, scale: 2.9)
    )
}

@Test func spinCyclesAllEightIdleRotations() {
    let spec = SpriteLibrary.heroSpec(for: .spin, facing: .south)
    #expect(spec?.frames == [
        "idle_south", "idle_south-west", "idle_west", "idle_north-west",
        "idle_north", "idle_north-east", "idle_east", "idle_south-east",
    ])
    #expect(spec?.fps == 24)
}

@Test func posesWithFallbackChainsAreDeliberatelyNotHeroSpecs() {
    // .pounce, .stalk, .peek and friends resolve against what's on disk, so
    // they can't be described by a static table. Asking is nil, not a crash.
    #expect(SpriteLibrary.heroSpec(for: .pounce, facing: .south) == nil)
    #expect(SpriteLibrary.heroSpec(for: .peek, facing: .south) == nil)
}

// MARK: - The drift guard itself

private let animationsJSON: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Tools/demo/animations.json")

@Test func spritefilmsTableMatchesTheAppForEveryPoseAndDirection() throws {
    let data = try Data(contentsOf: animationsJSON)
    let table = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: [String: [String: Any]]]
    )

    let poses: [(String, DogAnimation)] = [
        ("idle", .idle), ("walk", .walk), ("run", .run), ("sit", .sit), ("spin", .spin),
    ]

    for (poseName, animation) in poses {
        let byDirection = try #require(table[poseName], "animations.json is missing \(poseName)")
        for facing in Facing.allCases {
            let expected = try #require(SpriteLibrary.heroSpec(for: animation, facing: facing))
            let actual = try #require(
                byDirection[facing.fileSuffix],
                "animations.json is missing \(poseName)/\(facing.fileSuffix)"
            )
            #expect(actual["frames"] as? [String] == expected.frames)
            #expect(actual["fps"] as? Double == expected.fps)
            #expect(CGFloat(actual["scale"] as? Double ?? -1) == expected.scale)
        }
    }
}
