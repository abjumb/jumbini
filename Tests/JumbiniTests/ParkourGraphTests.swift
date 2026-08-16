import Testing
import CoreGraphics
import Foundation
@testable import Jumbini

// `ParkourGraph` is the pure half of window parkour: given a set of ledges
// (already in scene coordinates) and a set of reach limits, which window-to-
// window hops are physically plausible? These tests build synthetic ledges and
// assert on reachability, ordering, scale, excluded areas, disappeared
// windows, and multi-step routes — the acceptance criteria the ticket names.

// MARK: - Fixtures

private let limits = ParkourLimits(rise: 160, drop: 420, gap: 240, landingInset: 24)

/// A ledge in scene coordinates. `y` is its BOTTOM edge, so the perch line
/// (the top of the title bar) is `y + height`.
private func surface(
    _ id: CGWindowID, x: CGFloat, y: CGFloat, width: CGFloat = 200, height: CGFloat = 200
) -> Surface {
    Surface(
        id: id,
        rect: CGRect(x: x, y: y, width: width, height: height),
        title: "Window \(id)",
        ownerPID: 900
    )
}

/// A comfortably high ledge at (0, 500), top edge at 700, landing interval
/// x 24…176. Most tests hop from (or relative to) this one.
private let a = surface(1, x: 0, y: 500)

// MARK: - Reachability

@Test func aHopWithinEveryLimitIsReachable() {
    // B is 120pt up (within the 160pt rise) and its ledge is 48pt of horizontal
    // gap away (within 240): a perfectly ordinary hop.
    let b = surface(2, x: 200, y: 620) // top 820
    #expect(ParkourGraph.canHop(from: a, to: b, limits: limits))
    // And the return trip is a bounded drop, so the edge is bidirectional here.
    #expect(ParkourGraph.canHop(from: b, to: a, limits: limits))
}

@Test func tooHighARiseIsNotReachable() {
    let tooHigh = surface(2, x: 200, y: 700) // top 900, a 200pt climb
    #expect(!ParkourGraph.canHop(from: a, to: tooHigh, limits: limits))
}

@Test func tooDeepADropIsNotReachable() {
    let tooDeep = surface(2, x: 200, y: 20) // top 220, a 480pt drop
    #expect(!ParkourGraph.canHop(from: a, to: tooDeep, limits: limits))
}

@Test func tooWideAGapIsNotReachable() {
    let tooFar = surface(2, x: 600, y: 500) // level with A, but 448pt of gap
    #expect(!ParkourGraph.canHop(from: a, to: tooFar, limits: limits))
}

@Test func aLevelHopWithinTheGapIsReachable() {
    let beside = surface(2, x: 180, y: 500) // same top edge, 28pt gap
    #expect(ParkourGraph.canHop(from: a, to: beside, limits: limits))
}

@Test func aWindowIsNeverReachableFromItself() {
    #expect(!ParkourGraph.canHop(from: a, to: a, limits: limits))
}

// MARK: - Ordering

@Test func edgesPreserveFrontMostFirstOrder() {
    // A row of three mutually reachable ledges; the front-most first ordering
    // of the input is what breaks the "which neighbour?" tie.
    let front = surface(1, x: 0, y: 500)
    let middle = surface(2, x: 180, y: 500)
    let back = surface(3, x: 360, y: 500)
    let graph = ParkourGraph.build(surfaces: [front, middle, back], limits: limits)

    #expect(graph.reachable(from: 1) == [2, 3], "ties break towards the front-most window")
    #expect(graph.reachable(from: 3) == [1, 2])
}

// MARK: - Scale

@Test func scalingTheLimitsDownRejectsWhatFullScaleAllowed() {
    // A 150pt climb: fine at full scale (rise 160), too much at half scale.
    let tallNeighbour = surface(2, x: 200, y: 650) // top 850
    #expect(ParkourGraph.canHop(from: a, to: tallNeighbour, limits: limits))
    #expect(!ParkourGraph.canHop(from: a, to: tallNeighbour, limits: limits.scaled(by: 0.5)))
}

@Test func scalingTheLimitsUpReachesWhatFullScaleCouldNot() {
    // A 200pt climb is out of reach at full scale, but a dog drawn 150% can
    // make it.
    let farUp = surface(2, x: 200, y: 700) // top 900, a 200pt climb
    #expect(!ParkourGraph.canHop(from: a, to: farUp, limits: limits))
    #expect(ParkourGraph.canHop(from: a, to: farUp, limits: limits.scaled(by: 1.5)))
}

// MARK: - Excluded areas

@Test func aLandingInADeadZoneIsNotReachable() {
    // Only the left 400pt is real ground; a ledge whose landing interval sits
    // entirely to the right is somewhere the dog must not be sent.
    let ground = [CGRect(x: 0, y: 0, width: 400, height: 1000)]
    let inTheVoid = surface(2, x: 380, y: 500) // interval x 404…556, over nothing

    #expect(!ParkourGraph.canHop(from: a, to: inTheVoid, limits: limits, roamableRects: ground))
    // The same geometry is fine when the scene has no holes to avoid.
    #expect(ParkourGraph.canHop(from: a, to: inTheVoid, limits: limits))
}

@Test func aLandingOverSolidGroundStaysReachable() {
    let ground = [CGRect(x: 0, y: 0, width: 400, height: 1000)]
    let onTheDisplay = surface(2, x: 180, y: 500) // interval x 204…356, on the display
    #expect(ParkourGraph.canHop(from: a, to: onTheDisplay, limits: limits, roamableRects: ground))
}

// MARK: - Disappeared windows

@Test func aWindowNotInTheCurrentListHasNoEdges() {
    let b = surface(2, x: 200, y: 620)
    let withB = ParkourGraph.build(surfaces: [a, b], limits: limits)
    let withoutB = ParkourGraph.build(surfaces: [a], limits: limits)

    #expect(withB.reachable(from: 1) == [2], "the ledge exists, so the edge exists")
    #expect(withoutB.reachable(from: 1) == [], "a closed window leaves no ghost edge")
    #expect(withoutB.reachable(from: 2) == [], "a removed id has no out-edges at all")
}

// MARK: - Multi-step routes

@Test func multiStepRoutesSpanARowOfWindows() {
    // Three ledges in a row, each ADJACENT pair hop-able but the ends out of
    // each other's horizontal reach: 1 → 2 → 3 is a genuine two-hop traversal
    // that never touches the floor.
    let tightGap = ParkourLimits(rise: 160, drop: 420, gap: 120, landingInset: 24)
    let one = surface(1, x: 0, y: 500)
    let two = surface(2, x: 180, y: 500)
    let three = surface(3, x: 360, y: 500)
    let graph = ParkourGraph.build(surfaces: [one, two, three], limits: tightGap)

    #expect(graph.reachable(from: 1) == [2], "only the adjacent ledge is in reach")
    #expect(graph.reachable(from: 1, within: 1) == [2])
    #expect(graph.reachable(from: 1, within: 2) == [2, 3])
    #expect(graph.reachable(from: 1, within: 2).contains(3), "a two-step route crosses the row")
}
