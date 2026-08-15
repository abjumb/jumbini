import AppKit

/// Borderless, transparent, full-screen panel the pet lives in.
///
/// A non-activating `NSPanel` so clicking the dog never steals focus from the
/// app the user is working in. Click-through is on by default; `PetScene`
/// flips `ignoresMouseEvents` each frame based on what's under the cursor.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
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
