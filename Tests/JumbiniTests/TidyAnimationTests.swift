import Foundation
import Testing
@testable import Jumbini

// Jumba's part in a tidy is theatre.
//
// The files have already moved by the time any of this runs, so everything here
// is about not being tiresome: fifty moves must not become fifty little trips,
// Reduce Motion and a paused dog produce nothing at all, and the whole show has
// a hard ceiling on how long it can hold the screen.

@Suite struct TidyAnimationTests {
    @Test func fiftyMovesBecomeThreeIndividualCuesAndOneBatch() {
        let moves = (0..<50).map(TidyCompletedMove.fixture(index:))

        let cues = TidyAnimationBatcher.cues(for: moves, reduceMotion: false, overlayVisible: true)

        #expect(cues.count == 4)
        #expect(cues.prefix(3).allSatisfy { $0.count == 1 })
        #expect(cues.last?.count == 47)
        #expect(cues.reduce(0) { $0 + $1.duration } <= 12)
    }

    @Test func reducedMotionProducesNoCues() {
        #expect(TidyAnimationBatcher.cues(
            for: [.fixture(index: 0)], reduceMotion: true, overlayVisible: true
        ).isEmpty)
    }

    @Test func aHiddenOrPausedOverlayProducesNoCues() {
        #expect(TidyAnimationBatcher.cues(
            for: [.fixture(index: 0)], reduceMotion: false, overlayVisible: false
        ).isEmpty)
    }

    @Test func aPassThatMovedNothingHasNothingToAct() {
        #expect(TidyAnimationBatcher.cues(
            for: [], reduceMotion: false, overlayVisible: true
        ).isEmpty)
    }

    @Test func aHandfulOfMovesStaysIndividualWithNoBatch() {
        let moves = (0..<3).map(TidyCompletedMove.fixture(index:))

        let cues = TidyAnimationBatcher.cues(for: moves, reduceMotion: false, overlayVisible: true)

        #expect(cues.count == 3)
        #expect(cues.allSatisfy { $0.count == 1 })
    }

    @Test func everyCueKnowsWhichMoveItIsActingOut() {
        let moves = (0..<6).map(TidyCompletedMove.fixture(index:))

        let cues = TidyAnimationBatcher.cues(for: moves, reduceMotion: false, overlayVisible: true)

        #expect(cues.map(\.anchor) == [moves[0], moves[1], moves[2], moves[3]])
        #expect(cues.last?.count == 3)
    }

    @Test func theWholeShowIsBoundedNoMatterHowManyFilesMoved() {
        let moves = (0..<TidySafety.maximumMoves).map(TidyCompletedMove.fixture(index:))

        let cues = TidyAnimationBatcher.cues(for: moves, reduceMotion: false, overlayVisible: true)

        #expect(cues.prefix(3).allSatisfy { $0.duration <= 2.5 })
        #expect(cues.last?.duration ?? 0 <= 4)
    }

    // MARK: - Where Jumba goes

    private static let layout = ScreenLayout(displays: [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 1440, y: 0, width: 1920, height: 1080),
    ])

    @Test func theSamePathAlwaysSendsJumbaToTheSameSpot() {
        let move = TidyCompletedMove.fixture(index: 7)

        let first = TidyAnimationRegion.point(for: move, layout: Self.layout)
        let second = TidyAnimationRegion.point(for: move, layout: Self.layout)

        #expect(first == second)
    }

    @Test func differentFilesGoToDifferentSpots() {
        let points = (0..<12).map {
            TidyAnimationRegion.point(for: .fixture(index: $0), layout: Self.layout)
        }

        #expect(Set(points.map(\.debugDescription)).count > 1)
    }

    /// A plausible region, not a real one: Tidy reads no window positions and
    /// asks for no Accessibility permission, so the only promise the point makes
    /// is that it is somewhere the dog can actually stand.
    @Test func everyPointLandsWellInsideARealDisplay() {
        for index in 0..<40 {
            let point = TidyAnimationRegion.point(
                for: .fixture(index: index), layout: Self.layout
            )
            #expect(
                Self.layout.contains(point, inset: TidyAnimationRegion.displayInset - 1),
                "\(point) is not \(TidyAnimationRegion.displayInset)pt inside a display"
            )
        }
    }

    @Test func aTinyDisplayStillGetsAPointRatherThanNothing() {
        let layout = ScreenLayout(displays: [CGRect(x: 0, y: 0, width: 100, height: 60)])

        let point = TidyAnimationRegion.point(for: .fixture(index: 1), layout: layout)

        #expect(layout.contains(point))
    }

    @Test func anEmptyLayoutIsSurvivable() {
        let point = TidyAnimationRegion.point(
            for: .fixture(index: 1), layout: ScreenLayout(displays: [])
        )

        #expect(point == .zero)
    }
}
