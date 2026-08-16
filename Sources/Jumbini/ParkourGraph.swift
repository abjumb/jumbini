import CoreGraphics
import Foundation

// MARK: - Window parkour: the reachability graph
//
// Window climbing sends Jumba onto ONE window and back down again. Parkour is
// the signature leap on top of it: while he is already on a title bar, he can
// hop directly onto a NEIGHBOURING window instead of returning to the desktop,
// so a row of open windows becomes a connected landscape he can cross without
// ever touching the floor.
//
// This file is the pure half of that idea, and it knows nothing about AppKit,
// SpriteKit, RNG or time. `Surface` values arrive here already in scene
// coordinates and already filtered to ledges that are actually on a display
// (see `WindowSurfaceParser`). The graph answers one question: given two
// ledges, is a hop from one to the other physically plausible? Everything the
// decision needs is a set of numbers, which is what makes it unit-testable
// with no window server in sight.

/// The reach limits for a window-to-window hop, in points, measured between
/// the dog's FEET on each ledge — `footOffset` cancels out of the vertical
/// delta, so the caller hands in plain ledge-to-ledge geometry.
///
/// Every field is already scaled to the dog's current size by the caller: the
/// brain multiplies its base tuning by `dogScale` before building, which is
/// how the future size controls (ticket 05) reach in here without this file
/// knowing a scale exists.
struct ParkourLimits: Equatable {
    /// The tallest climb between ledges he'll attempt (target top above his).
    var rise: CGFloat
    /// The deepest descent between ledges he'll attempt (target top below his).
    var drop: CGFloat
    /// The widest horizontal gap he'll clear, between takeoff and landing feet.
    var gap: CGFloat
    /// How far in from a ledge corner a landing must be, so he never lands
    /// teetering half off the end.
    var landingInset: CGFloat

    /// The same limits, uniformly scaled (the dog's size control).
    func scaled(by factor: CGFloat) -> ParkourLimits {
        ParkourLimits(
            rise: rise * factor,
            drop: drop * factor,
            gap: gap * factor,
            landingInset: landingInset * factor
        )
    }
}

/// A directed graph of the hops a perched dog could make, one node per
/// `Surface` id and one edge per plausible window-to-window transition.
///
/// Pure and side-effect free: `build(surfaces:limits:roamableRects:)` is a
/// function of its arguments alone, so reachability, ordering, scale and
/// excluded-area behavior are all asserted with synthetic ledges.
struct ParkourGraph: Equatable {
    /// Out-edges per surface id, in INPUT ORDER (front-most window first), so
    /// "which neighbour should I hop to?" breaks ties towards the window the
    /// user is most likely looking at.
    private(set) var adjacency: [CGWindowID: [CGWindowID]]

    /// The windows directly reachable from this one, front-most first.
    func reachable(from id: CGWindowID) -> [CGWindowID] {
        adjacency[id] ?? []
    }

    /// Every window reachable within `maxHops` hops (not including the start),
    /// for asserting that a multi-step route exists across a row of windows.
    func reachable(from start: CGWindowID, within maxHops: Int) -> Set<CGWindowID> {
        var reached: Set<CGWindowID> = []
        var frontier: Set<CGWindowID> = [start]
        for _ in 0..<maxHops {
            var next: Set<CGWindowID> = []
            for id in frontier {
                for neighbour in adjacency[id] ?? [] where neighbour != start && !reached.contains(neighbour) {
                    next.insert(neighbour)
                }
            }
            reached.formUnion(next)
            frontier = next
            if frontier.isEmpty { break }
        }
        return reached
    }

    // MARK: Building

    /// Build the full graph over every ordered pair of surfaces. A hop from A
    /// to B is possible only when B is a distinct ledge within the vertical
    /// rise/drop limits, horizontally within the gap limit after landing
    /// insets, and (when the caller supplies real display geometry) landing on
    /// solid ground rather than a dead zone or an excluded area.
    static func build(
        surfaces: [Surface],
        limits: ParkourLimits,
        roamableRects: [CGRect] = []
    ) -> ParkourGraph {
        var adjacency: [CGWindowID: [CGWindowID]] = [:]
        for from in surfaces {
            var edges: [CGWindowID] = []
            for to in surfaces where to.id != from.id {
                if canHop(from: from, to: to, limits: limits, roamableRects: roamableRects) {
                    edges.append(to.id)
                }
            }
            adjacency[from.id] = edges
        }
        return ParkourGraph(adjacency: adjacency)
    }

    // MARK: The reachability predicate

    /// Can he hop from `from`'s ledge to `to`'s ledge?
    ///
    /// The vertical check is a bounded rise or a bounded drop (a level hop is
    /// always fine vertically). The horizontal check compares the two ledges'
    /// landing intervals after `landingInset`, so a hop is possible when SOME
    /// takeoff point on `from` and SOME landing point on `to` are within
    /// `gap` of each other — the best case, which is what a graph of surfaces
    /// (not positions) can honestly say. The caller re-checks the specific
    /// landing point at hop time.
    static func canHop(
        from: Surface,
        to: Surface,
        limits: ParkourLimits,
        roamableRects: [CGRect] = []
    ) -> Bool {
        guard from.id != to.id else { return false }

        // Vertical: rise and drop are bounded separately, in either direction.
        let dy = to.topY - from.topY
        if dy > 0, dy > limits.rise { return false }
        if dy < 0, -dy > limits.drop { return false }

        // Horizontal: the gap between the two usable landing intervals.
        let takeoff = usableInterval(from, inset: limits.landingInset)
        let landing = usableInterval(to, inset: limits.landingInset)
        let gap = max(landing.lowerBound - takeoff.upperBound,
                      takeoff.lowerBound - landing.upperBound,
                      0)
        guard gap <= limits.gap else { return false }

        // Territory: the landing interval must touch solid ground. With no
        // `roamableRects` (the single-display default) the whole scene is
        // ground, and this check is skipped.
        guard !roamableRects.isEmpty else { return true }
        let topY = to.topY
        return roamableRects.contains { rect in
            topY >= rect.minY && topY <= rect.maxY
                && landing.upperBound >= rect.minX && landing.lowerBound <= rect.maxX
        }
    }

    /// The x-interval on a ledge a dog could occupy, after the landing inset.
    /// A ledge narrower than two insets collapses to its middle, so there is
    /// still somewhere to stand.
    private static func usableInterval(_ surface: Surface, inset: CGFloat) -> ClosedRange<CGFloat> {
        let lo = surface.rect.minX + inset
        let hi = surface.rect.maxX - inset
        return lo <= hi ? lo...hi : surface.rect.midX...surface.rect.midX
    }
}
