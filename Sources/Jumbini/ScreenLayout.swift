import AppKit
import CoreGraphics
import Foundation

// MARK: - The desk, as a shape
//
// Jumbini lives in ONE overlay window stretched over the bounding box of every
// display — the "union frame". That is what lets him trot off the right edge of
// one monitor and appear on the next without any hand-off: crossing a display
// boundary is just walking, because it is all one scene.
//
// The price of that simplicity is DEAD ZONES. Displays rarely tile their own
// bounding box:
//
//     ┌──────────┐
//     │          │┌────────┐   the shaded corners belong to no display, and
//     │ 1440x900 ││1280x800│   nothing drawn there is ever seen by anyone
//     │          │├────────┤
//     └──────────┘└╌╌╌╌╌╌╌╌┘   <- dead zone
//
// `ScreenLayout` is the model of that shape. It is a PURE value type built from
// plain rectangles, so every arrangement below — side by side, stacked,
// mismatched heights, a display left of the primary — is unit-testable without
// plugging anything in. `current()` is the only part that touches AppKit.
//
// TWO COORDINATE SPACES, as everywhere else in this app:
//   * GLOBAL AppKit — y-up, origin at the bottom-left of the PRIMARY display.
//     `NSScreen.frame` speaks this. Other displays can sit at negative x or y.
//   * SCENE — y-up, origin at the bottom-left of the UNION frame, which is
//     where the overlay window is. Always non-negative inside the union.
// Everything named `scene…` is the second; everything else is the first.
// (CoreGraphics' third, y-DOWN space is confined to `SurfaceGeometry`.)

/// The set of displays, their bounding box, and which points inside that box
/// are actually on a screen.
struct ScreenLayout: Equatable {
    /// Every display's frame in GLOBAL AppKit coordinates, in the order given
    /// (which for `current()` is `NSScreen.screens` order).
    let displays: [CGRect]

    /// Index into `displays` of the primary display — the one whose global
    /// origin is (0, 0), which is also the menu bar screen and the anchor for
    /// CoreGraphics' y-down window coordinates. Falls back to 0.
    let primaryIndex: Int

    /// Bounding box of every display, GLOBAL AppKit coordinates. This is the
    /// overlay window's frame; its origin is negative whenever a display sits
    /// left of or below the primary.
    let unionFrame: CGRect

    /// The same displays, translated into SCENE coordinates.
    let sceneFrames: [CGRect]

    /// True when the displays do not completely tile their own bounding box —
    /// i.e. there is somewhere inside the scene that is on no display at all.
    /// False for a single display and for any arrangement that happens to be
    /// a perfect rectangle (equal-height displays side by side, equal-width
    /// displays stacked), which is the common case and the fast path.
    let hasDeadZones: Bool

    /// Creates a layout from display frames in global AppKit coordinates.
    ///
    /// - Parameters:
    ///   - displays: the frames. Empty or degenerate rects are dropped; if
    ///     nothing is left the layout is empty and `contains` is always false.
    ///   - primaryIndex: which display is primary. Defaults to the one at the
    ///     global origin, then to the first.
    init(displays: [CGRect], primaryIndex: Int? = nil) {
        let usable = displays.filter { $0.width > 0 && $0.height > 0 }
        self.displays = usable

        if let primaryIndex, usable.indices.contains(primaryIndex) {
            self.primaryIndex = primaryIndex
        } else {
            self.primaryIndex = usable.firstIndex { $0.origin == .zero } ?? 0
        }

        let union = usable.dropFirst().reduce(usable.first ?? .zero) { $0.union($1) }
        unionFrame = union
        sceneFrames = usable.map { $0.offsetBy(dx: -union.minX, dy: -union.minY) }

        // Displays never overlap on macOS, so "do they tile their bounding
        // box?" is just an area comparison. The epsilon absorbs the fractional
        // frames that scaled (HiDPI) modes occasionally report.
        let covered = usable.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        hasDeadZones = covered < union.width * union.height - 1
    }

    /// The overlay/scene size: the union's size.
    var size: CGSize { unionFrame.size }

    /// The primary display in SCENE coordinates. Furniture that has to look
    /// right on a fresh install (the bed, the treat jar) and the Dock's trash
    /// corner belong to this rectangle, not to the whole union — a bed parked
    /// in the bottom-right of a three-monitor desk is a bed nobody can find.
    var primarySceneFrame: CGRect {
        guard sceneFrames.indices.contains(primaryIndex) else {
            return CGRect(origin: .zero, size: size)
        }
        return sceneFrames[primaryIndex]
    }

    /// The rectangles the dog may roam, for `DogBrain.roamableRects`. EMPTY
    /// when the union has no dead zones, which tells the brain "all of
    /// `bounds` is fair game" and keeps the single-display path exactly as it
    /// was before there was a layout at all.
    var roamableRects: [CGRect] { hasDeadZones ? sceneFrames : [] }

    // MARK: Containment

    /// Is this SCENE point on a real display?
    ///
    /// Edges count as inside (unlike `CGRect.contains`): clamping produces
    /// points that sit exactly on a boundary, and two displays that abut share
    /// that boundary, so a half-open test would declare the seam a dead zone.
    ///
    /// `inset` shrinks every display by that many points first — pass the dog's
    /// half-size to ask "would he be fully on a screen here?".
    func contains(_ scenePoint: CGPoint, inset: CGFloat = 0) -> Bool {
        guard !sceneFrames.isEmpty else { return false }
        return sceneFrames.contains { Self.rect(insetting: $0, by: inset).covers(scenePoint) }
    }

    /// The nearest SCENE point that is on a real display. Returns `scenePoint`
    /// unchanged when it already is one, so an entity sitting happily on the
    /// second monitor is never nudged by a clamp.
    func clamp(_ scenePoint: CGPoint, inset: CGFloat = 0) -> CGPoint {
        guard !sceneFrames.isEmpty else { return scenePoint }
        if contains(scenePoint, inset: inset) { return scenePoint }
        var best = scenePoint
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for frame in sceneFrames {
            let usable = Self.rect(insetting: frame, by: inset)
            let candidate = CGPoint(
                x: min(max(scenePoint.x, usable.minX), usable.maxX),
                y: min(max(scenePoint.y, usable.minY), usable.maxY)
            )
            let distance = hypot(candidate.x - scenePoint.x, candidate.y - scenePoint.y)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    /// The display (in scene coordinates) this point is on, if any.
    func sceneFrame(containing scenePoint: CGPoint) -> CGRect? {
        sceneFrames.first { $0.covers(scenePoint) }
    }

    /// An inset rect that never collapses: a display narrower than twice the
    /// inset degenerates to its own centre rather than to an empty rect, so
    /// `clamp` still has somewhere to put things.
    private static func rect(insetting frame: CGRect, by inset: CGFloat) -> CGRect {
        guard inset > 0 else { return frame }
        let shrunk = frame.insetBy(dx: inset, dy: inset)
        guard shrunk.width > 0, shrunk.height > 0 else {
            return CGRect(origin: CGPoint(x: frame.midX, y: frame.midY), size: .zero)
        }
        return shrunk
    }

    // MARK: Coordinate conversion

    /// GLOBAL AppKit → SCENE. Both are y-up; this is a pure translation.
    func toScene(_ globalPoint: CGPoint) -> CGPoint {
        CGPoint(x: globalPoint.x - unionFrame.minX, y: globalPoint.y - unionFrame.minY)
    }

    /// SCENE → GLOBAL AppKit.
    func toGlobal(_ scenePoint: CGPoint) -> CGPoint {
        CGPoint(x: scenePoint.x + unionFrame.minX, y: scenePoint.y + unionFrame.minY)
    }

    // MARK: The live desk

    /// The displays attached right now. Main thread only — it reads `NSScreen`.
    ///
    /// If AppKit reports no screens at all (it shouldn't, but a display asleep
    /// during a hot-plug storm is not worth crashing over) this falls back to a
    /// single nominal display so the overlay still has somewhere to be.
    static func current() -> ScreenLayout {
        let frames = NSScreen.screens.map(\.frame)
        guard !frames.isEmpty else {
            return ScreenLayout(displays: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        }
        return ScreenLayout(displays: frames)
    }
}

private extension CGRect {
    /// `contains` with the far edges included — see `ScreenLayout.contains`.
    func covers(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
