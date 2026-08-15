import AppKit
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

    /// ────────────────────────────────────────────────────────────────────
    /// THE COORDINATE CONVERSION. **MULTI-MONITOR EXTENSION POINT.**
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
    /// A multi-monitor implementation changes **only this function and the
    /// values fed into `SurfaceGeometry`**:
    ///   * `flipHeight` stays the PRIMARY display's height — the CG flip axis
    ///     is global and does not change per screen. Do not switch it to the
    ///     height of whichever screen a window happens to be on; that is the
    ///     bug this comment exists to prevent.
    ///   * `sceneOrigin` becomes the origin of the screen that this particular
    ///     scene/overlay covers (`window.frame.origin` for that screen), which
    ///     is already how it is written — so per-screen overlays work by
    ///     constructing one `SurfaceGeometry` per overlay.
    ///   * If instead you go with one giant overlay spanning every display,
    ///     `sceneOrigin` becomes the union frame's origin (which can be
    ///     NEGATIVE when a screen sits left of or below the primary) and
    ///     `sceneSize` the union size. The formula below already handles that
    ///     — it is a plain translation.
    func sceneRect(from cgRect: CGRect) -> CGRect {
        CGRect(
            x: cgRect.minX - sceneOrigin.x,
            y: (flipHeight - cgRect.maxY) - sceneOrigin.y,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    /// The geometry for an overlay covering `sceneFrame` (global AppKit
    /// coordinates). Main thread only — it reads `NSScreen`.
    ///
    /// The flip axis is the primary display: the screen whose AppKit frame
    /// origin is (0, 0). `NSScreen.screens.first` is that screen on every
    /// configuration Apple ships, but the search is explicit so a reordered
    /// screen list can't quietly flip the dog upside down.
    static func forOverlay(sceneFrame: CGRect) -> SurfaceGeometry {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.screens.first
        return SurfaceGeometry(
            flipHeight: primary?.frame.maxY ?? sceneFrame.maxY,
            sceneOrigin: sceneFrame.origin,
            sceneSize: sceneFrame.size
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

    /// Is this window's TOP EDGE actually somewhere in the scene? A window
    /// scrolled off the side, or one whose title bar sits above the scene
    /// (or below its floor), is not a perch even though it is "on screen".
    private static func isReachable(_ rect: CGRect, in geometry: SurfaceGeometry) -> Bool {
        let visibleWidth = min(rect.maxX, geometry.sceneSize.width) - max(rect.minX, 0)
        guard visibleWidth >= minimumOnScreenWidth else { return false }
        return rect.maxY > 0 && rect.maxY < geometry.sceneSize.height
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
/// Same shape as `SystemMonitor`: a modest poll on a background queue with an
/// in-flight guard, results delivered on the main thread, and a source that
/// switches itself off for good rather than ever becoming a problem. If the
/// window server won't answer, every update is an empty list and the dog
/// simply stays on the desktop floor.
///
/// No special permission is required for what this reads. `CGWindowList`
/// geometry is public information; only window *contents* (and, on modern
/// macOS, `kCGWindowName`) sit behind Screen Recording — which is exactly why
/// `Surface.title` is optional and nothing depends on it.
///
/// Main-thread class: `start()`, `stop()` and every `onUpdate` call happen
/// there. Only the CGWindowList copy and the parse leave the main thread.
final class WindowSurfaces {
    /// Called on the main thread after every poll, front-most window first.
    var onUpdate: (([Surface]) -> Void)?

    /// Where the scene is right now, evaluated on the main thread before each
    /// poll. A closure rather than a stored value because the overlay can be
    /// resized (or moved to another display) at any time.
    var geometry: () -> SurfaceGeometry

    /// 3 Hz. Fast enough that dragging a window keeps the dog aboard, slow
    /// enough that the copy (a few hundred microseconds for a dozen windows)
    /// never shows up in a profile.
    private static let pollInterval: TimeInterval = 1.0 / 3.0

    private var timer: Timer?
    private var isRunning = false
    /// Stops a slow copy from stacking up behind itself.
    private var probeInFlight = false
    /// Flips false the first time the window server refuses to answer, and
    /// never flips back — from then on the dog lives on the desktop.
    private var available = true
    private let queue = DispatchQueue(label: "com.jumbini.windowsurfaces")

    init(geometry: @escaping () -> SurfaceGeometry) {
        self.geometry = geometry
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        poll() // don't make the dog wait a third of a second for his world
        // .common mode: an open menu or a window drag must not stall polling —
        // a window drag is precisely when we most need fresh numbers.
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    // MARK: Polling

    private func poll() {
        guard available, !probeInFlight else { return }
        // AppKit is main-thread-only, so the display layout is captured here
        // and the background queue only ever sees plain numbers.
        let geometry = self.geometry()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        probeInFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            let raw = Self.copyWindowInfo()
            let surfaces = raw.map {
                WindowSurfaceParser.surfaces(from: $0, ownPID: ownPID, geometry: geometry)
            }
            DispatchQueue.main.async {
                self.probeInFlight = false
                guard let surfaces else {
                    // The window server won't talk to us: no surfaces, forever.
                    self.available = false
                    self.onUpdate?([])
                    return
                }
                self.onUpdate?(surfaces)
            }
        }
    }

    /// The raw list, or nil if the API is unavailable in this context.
    /// No private APIs and no `.optionIncludingWindow` tricks: on-screen
    /// windows only, which is all a perch could ever be.
    private static func copyWindowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
    }
}
