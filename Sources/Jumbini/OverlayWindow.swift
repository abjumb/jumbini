import AppKit

/// Borderless, transparent panel the pet lives in, covering EVERY display.
///
/// A non-activating `NSPanel` so clicking the dog never steals focus from the
/// app the user is working in. Click-through is on by default; `PetScene`
/// flips `ignoresMouseEvents` each frame based on what's under the cursor.
///
/// The frame is the union of every display (`ScreenLayout.unionFrame`), not
/// one screen — that is what lets the dog trot off the edge of one monitor and
/// onto the next without any hand-off, because it is all one scene. Two pieces
/// of the configuration below carry that weight:
///
///   * `.canJoinAllSpaces` — with macOS's "Displays have separate Spaces" on
///     (the default), each display runs its own Space, and an ordinary window
///     would be tied to one of them. Joining all Spaces is what keeps a single
///     window drawn on every display at once.
///   * `level = .statusBar` — above ordinary windows, so the dog is not
///     clipped by whatever is full-screened on the second monitor.
final class OverlayWindow: NSPanel {
    /// - Parameter frame: global AppKit coordinates. May have a NEGATIVE
    ///   origin, which is what a display left of or below the primary looks
    ///   like; `NSWindow` is perfectly happy there.
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Never take key/main status — the pet should not interfere with typing.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
