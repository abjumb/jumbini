import CoreGraphics
import Foundation

// MARK: - Coordinate geometry
//
// Two coordinate systems meet in this file, and getting them confused is the
// classic way to end up with a dog walking on the ceiling:
//
//   * CGWindowList speaks GLOBAL DISPLAY coordinates with a TOP-LEFT origin,
//     anchored at the top-left of the PRIMARY display. Y grows downwards.
//   * The scene speaks its own coordinates with a BOTTOM-LEFT origin, anchored
//     at the bottom-left of the overlay window. Y grows upwards.
//
// Everything below the parser is pure: it takes the raw dictionaries and a
// `SurfaceGeometry` describing where the scene sits, and returns `Surface`
// values. No live system call, which is what makes it unit-testable.

/// Everything the conversion needs to know about the display layout, captured
/// on the main thread and passed into the pure parser.
struct SurfaceGeometry: Equatable {
    /// The height of the flip axis: CoreGraphics measures global window
    /// coordinates down from the top of the PRIMARY display, AppKit measures
    /// up from its bottom, so `appKitY = flipHeight - cgY`.
    ///
    /// On a single-display Mac this is simply the screen height.
    var flipHeight: CGFloat

    /// The scene's origin (its bottom-left corner) in GLOBAL AppKit
    /// coordinates — i.e. the overlay window's `frame.origin`. Zero on a
    /// single-display Mac, where the overlay covers the primary screen.
    var sceneOrigin: CGPoint

    /// The scene's size in points; used to cull windows that don't overlap it.
    var sceneSize: CGSize

    /// Where the real displays are inside the scene, in SCENE coordinates.
    ///
    /// EMPTY — the default, and every single-display Mac — means "the whole
    /// scene box is screen", which is exactly how this file behaved before
    /// there was such a thing as a second monitor.
    ///
    /// Non-empty matters because the union overlay spans the BOUNDING BOX of
    /// every display, and an uneven arrangement leaves parts of that box on no
    /// display. A title bar out there is drawn nowhere at all, so it is not
    /// somewhere a dog can stand, however wide it is. `ScreenLayout.sceneFrames`
    /// is what fills this in.
    var screenRects: [CGRect] = []

    /// ────────────────────────────────────────────────────────────────────
    /// THE COORDINATE CONVERSION. The only copy of the flip in the codebase.
    /// ────────────────────────────────────────────────────────────────────
    ///
    /// Turns one CGWindowList rect (global, top-left origin, y-down) into a
    /// scene rect (scene-local, bottom-left origin, y-up). Every window in the
    /// app goes through exactly this function — there is no second copy of the
    /// flip anywhere in the codebase, on purpose.
    ///
    /// The maths, in two steps:
    ///   1. CG global (y-down)  →  AppKit global (y-up):
    ///        appKitMinY = flipHeight - cgRect.maxY
    ///      (`cgRect.maxY` is the window's *bottom* edge in CG's flipped space,
    ///      which becomes its minY once y points up.)
    ///   2. AppKit global  →  scene-local: subtract `sceneOrigin`.
    ///
    /// Multi-monitor did not change this function at all, only what is fed to
    /// it — which was the point of writing it this way. There is ONE overlay,
    /// spanning the union of every display, so:
    ///   * `flipHeight` is the PRIMARY display's height. The CG flip axis is
    ///     global and does not change per screen. Do NOT switch it to the
    ///     height of whichever screen a window happens to be on; that is the
    ///     bug this comment exists to prevent, and there is a test named
    ///     `theFlipAxisStaysThePrimaryDisplayHoweverTallTheDeskGets` guarding
    ///     it.
    ///   * `sceneOrigin` is the union frame's origin, which is NEGATIVE when a
    ///     screen sits left of or below the primary. The formula below handles
    ///     that without noticing — it is a plain translation.
    ///   * `sceneSize` is the union size, and `screenRects` says which parts of
    ///     that box are really a display.
    func sceneRect(from cgRect: CGRect) -> CGRect {
        CGRect(
            x: cgRect.minX - sceneOrigin.x,
            y: (flipHeight - cgRect.maxY) - sceneOrigin.y,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    /// The geometry for the one overlay spanning every display. Pure — the
    /// layout has already done all the `NSScreen` reading, which is why there
    /// is a single factory here and not one per caller.
    ///
    /// `flipHeight` is the PRIMARY display's height and nothing else — see the
    /// warning on `sceneRect(from:)`. `sceneOrigin` is the union's origin,
    /// which goes negative the moment a display sits left of or below the
    /// primary, and that is fine because the conversion is a translation.
    ///
    /// `ScreenLayout` finds the primary by looking for the display at the
    /// global origin, so a reordered screen list can't quietly flip the dog
    /// upside down; the fallback to the union frame only fires for a layout
    /// with no displays at all.
    static func forOverlay(layout: ScreenLayout) -> SurfaceGeometry {
        let primary = layout.displays.indices.contains(layout.primaryIndex)
            ? layout.displays[layout.primaryIndex]
            : layout.unionFrame
        return SurfaceGeometry(
            flipHeight: primary.maxY,
            sceneOrigin: layout.unionFrame.origin,
            sceneSize: layout.unionFrame.size,
            screenRects: layout.sceneFrames
        )
    }
}

// MARK: - Pure parsing

/// Turns raw CGWindowList dictionaries into perchable `Surface` values.
///
/// Pure and side-effect free: `surfaces(from:ownPID:geometry:)` is a function
/// of its arguments alone, so the whole filter/convert pipeline is tested with
/// synthetic dictionaries and no window server in sight.
enum WindowSurfaceParser {
    /// Narrower than this and there is nowhere to trot — a tooltip, a badge,
    /// a sliver of a palette. Also the cheapest way to throw away the junk
    /// windows every Mac has floating around.
    static let minimumWidth: CGFloat = 120
    /// Zero/one-pixel windows (offscreen scratch buffers, shadow helpers).
    static let minimumHeight: CGFloat = 40
    /// Fully or nearly transparent windows aren't there as far as a dog is
    /// concerned, even when the window server still lists them.
    static let minimumAlpha: Double = 0.05
    /// How much of the top edge must actually be over the scene for the perch
    /// to be reachable, in points.
    static let minimumOnScreenWidth: CGFloat = 60

    /// Only the normal document layer is a perch. This single check disposes
    /// of the desktop/wallpaper (large negative layers), the menu bar and the
    /// Dock (high positive layers), Notification Center, Spotlight and every
    /// other piece of system chrome, which is why there is no sprawling
    /// deny-list here.
    static let perchableLayer = 0

    /// Belt-and-braces for the handful of processes that do put things on
    /// layer 0 that nobody should stand on. Matched against
    /// `kCGWindowOwnerName`.
    static let ignoredOwners: Set<String> = [
        "Dock", "Window Server", "WindowServer", "Wallpaper", "Screen Saver",
    ]

    /// The perchable windows, FRONT-MOST FIRST — CGWindowList's own ordering,
    /// preserved deliberately so "the window he is most likely to mean" comes
    /// first and ties break towards the front.
    ///
    /// - Parameters:
    ///   - raw: `CGWindowListCopyWindowInfo` output, or synthetic equivalents.
    ///   - ownPID: Jumbini's own process id; his overlay is never a perch.
    ///   - geometry: display layout for the coordinate flip.
    static func surfaces(
        from raw: [[String: Any]],
        ownPID: pid_t,
        geometry: SurfaceGeometry
    ) -> [Surface] {
        raw.compactMap { surface(from: $0, ownPID: ownPID, geometry: geometry) }
    }

    /// One dictionary → one `Surface`, or nil if it isn't somewhere a dog
    /// could plausibly stand.
    static func surface(
        from info: [String: Any],
        ownPID: pid_t,
        geometry: SurfaceGeometry
    ) -> Surface? {
        // Identity. A window with no number can't be tracked across polls,
        // and tracking is the whole basis of "ride the window as it moves".
        guard let number = info[kCGWindowNumber as String] as? Int else { return nil }
        let ownerPID = pid_t((info[kCGWindowOwnerPID as String] as? Int) ?? -1)
        guard ownerPID > 0, ownerPID != ownPID else { return nil }

        // Chrome filters.
        guard (info[kCGWindowLayer as String] as? Int) == perchableLayer else { return nil }
        let owner = info[kCGWindowOwnerName as String] as? String
        if let owner, ignoredOwners.contains(owner) { return nil }
        // Alpha is optional in the dictionary; a missing one means opaque.
        let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
        guard alpha > minimumAlpha else { return nil }
        // `.optionOnScreenOnly` already implies this, but the key is cheap to
        // honour and synthetic input may set it false.
        if let onScreen = info[kCGWindowIsOnscreen as String] as? Bool, !onScreen { return nil }

        // Geometry.
        guard let cgRect = boundsRect(from: info[kCGWindowBounds as String]) else { return nil }
        guard cgRect.width >= minimumWidth, cgRect.height >= minimumHeight else { return nil }
        let rect = geometry.sceneRect(from: cgRect)
        guard isReachable(rect, in: geometry) else { return nil }

        return Surface(
            id: CGWindowID(truncatingIfNeeded: number),
            rect: rect,
            title: info[kCGWindowName as String] as? String,
            ownerPID: ownerPID
        )
    }

    /// Is this window's TOP EDGE actually somewhere a dog could stand? A window
    /// scrolled off the side, one whose title bar sits above the scene (or
    /// below its floor), or — on an uneven multi-display desk — one whose title
    /// bar hangs in a region that belongs to no display, is not a perch even
    /// though it is "on screen".
    private static func isReachable(_ rect: CGRect, in geometry: SurfaceGeometry) -> Bool {
        guard rect.maxY > 0, rect.maxY < geometry.sceneSize.height else { return false }
        return visibleTopEdgeWidth(of: rect, in: geometry) >= minimumOnScreenWidth
    }

    /// How many points of the window's top edge are over something the user
    /// can actually see.
    ///
    /// With no `screenRects` this is the scene box, unchanged. With them it is
    /// the total across every display whose vertical span covers the top edge
    /// — a total, because a window can straddle two displays with a dead zone
    /// between them and still offer a walkable ledge at each end. Displays
    /// never overlap, so summing cannot double-count.
    private static func visibleTopEdgeWidth(
        of rect: CGRect, in geometry: SurfaceGeometry
    ) -> CGFloat {
        guard !geometry.screenRects.isEmpty else {
            return min(rect.maxX, geometry.sceneSize.width) - max(rect.minX, 0)
        }
        let topY = rect.maxY
        return geometry.screenRects.reduce(0) { total, screen in
            guard topY >= screen.minY, topY <= screen.maxY else { return total }
            return total + max(0, min(rect.maxX, screen.maxX) - max(rect.minX, screen.minX))
        }
    }

    /// CGWindowList stores bounds as a nested dictionary of X/Y/Width/Height
    /// in CG global (top-left origin) coordinates.
    static func boundsRect(from value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any],
              let x = (dict["X"] as? NSNumber)?.doubleValue,
              let y = (dict["Y"] as? NSNumber)?.doubleValue,
              let width = (dict["Width"] as? NSNumber)?.doubleValue,
              let height = (dict["Height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - The provider

/// Watches the windows on screen and reports the ones the dog could stand on.
///
/// Same shape as `SystemMonitor`: a modest poll loop that awaits its own work
/// (so it can never stack up behind itself), results delivered on the main
/// actor, and a source that spends a `RetryBudget` and then switches itself
/// off for good rather than ever becoming a problem. If the window server
/// won't answer at all, every update is an empty list and the dog simply stays
/// on the desktop floor.
///
/// No special permission is required for what this reads. `CGWindowList`
/// geometry is public information; only window *contents* (and, on modern
/// macOS, `kCGWindowName`) sit behind Screen Recording — which is exactly why
/// `Surface.title` is optional and nothing depends on it.
///
/// `@MainActor`: `start()`, `stop()` and every `onUpdate` call live there.
/// Only the CGWindowList copy and the parse leave the main actor, in one
/// `nonisolated async` function.
@MainActor
final class WindowSurfaces {
    /// Called on the main actor after every poll, front-most window first.
    var onUpdate: (([Surface]) -> Void)?

    /// Where the scene is right now, evaluated on the main actor before each
    /// poll. A closure rather than a stored value because the overlay can be
    /// resized (or moved to another display) at any time.
    var geometry: () -> SurfaceGeometry

    /// 3 Hz. Fast enough that dragging a window keeps the dog aboard, slow
    /// enough that the copy (a few hundred microseconds for a dozen windows)
    /// never shows up in a profile.
    private static let pollInterval: Duration = .milliseconds(1000 / 3)

    /// The poll loop. Cancelling it is what "stopping" means.
    private var pollTask: Task<Void, Never>?
    private var isRunning = false
    /// Three refusals from the window server and the dog lives on the desktop
    /// for the rest of the run. One refusal is just a skipped frame.
    private var budget = RetryBudget()

    init(geometry: @escaping () -> SurfaceGeometry) {
        self.geometry = geometry
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Polls straight away — the dog shouldn't wait a third of a second for
        // his world — and the loop awaits each poll, so a slow copy delays the
        // next one instead of stacking up behind it. No run-loop mode to get
        // wrong either: a window drag is precisely when we need fresh numbers.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    return // cancelled mid-sleep
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
    }

    deinit { pollTask?.cancel() }

    // MARK: Polling

    private func poll() async {
        guard budget.isAvailable else { return }
        // AppKit is main-actor-only, so the display layout is captured here
        // and the parse off the main actor only ever sees plain numbers.
        let geometry = self.geometry()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let surfaces = await Self.readSurfaces(ownPID: ownPID, geometry: geometry)
        guard isRunning, !Task.isCancelled else { return }
        guard let surfaces else {
            // The window server won't talk to us. A single refusal just skips
            // this frame — the dog keeps the perch he's already on; only a
            // budget spent in full means no surfaces, forever.
            if budget.recordFailure() { onUpdate?([]) }
            return
        }
        budget.recordSuccess()
        onUpdate?(surfaces)
    }

    /// The copy and the parse, off the main actor. nil if the window server
    /// wouldn't answer.
    private nonisolated static func readSurfaces(
        ownPID: pid_t, geometry: SurfaceGeometry
    ) async -> [Surface]? {
        guard let raw = copyWindowInfo() else { return nil }
        return WindowSurfaceParser.surfaces(from: raw, ownPID: ownPID, geometry: geometry)
    }

    /// The raw list, or nil if the API is unavailable in this context.
    /// No private APIs and no `.optionIncludingWindow` tricks: on-screen
    /// windows only, which is all a perch could ever be.
    private nonisolated static func copyWindowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    }
}
