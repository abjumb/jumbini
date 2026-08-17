import AppKit

/// The three things every panel in the app needs from accessibility, in one
/// place so they say the same thing everywhere.
///
/// Jumbini is an overlay with no window chrome, no Dock icon and a lot of its
/// state expressed as pixel art. Nearly all of that is decorative and can be
/// left alone — but the parts that report *progress* have to be spoken, and
/// the parts that *move* have to be able to stop.
enum Accessibility {

    // MARK: - Announcements

    /// Say something to VoiceOver that no control's label covers.
    ///
    /// The panels here report through status lines that sit beside the button
    /// that caused them, so a change to one is silent: nothing took focus,
    /// nothing changed value, and a screen reader user is left with a
    /// generation that either finished or didn't, minutes ago, with no way to
    /// know which. Announcing at the moment it happens is the fix.
    ///
    /// `.high` because every caller is reporting the outcome of something the
    /// user asked for and is waiting on; that outranks whatever is being read
    /// at the time.
    static func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .high) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }

    // MARK: - Reduce Motion

    /// Whether the user has asked the system for less movement.
    ///
    /// Read live rather than cached: it is a System Settings switch that can
    /// be flipped while the app is running, and everything that consults it
    /// does so at the moment it is about to animate.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Text styles

extension NSFont {
    /// A text-style font, optionally at a heavier weight.
    ///
    /// Hard-coded point sizes ignore the user's text-size preference outright,
    /// which for a panel of 10 and 11 point labels is the difference between
    /// readable and not. `preferredFont(forTextStyle:)` tracks that setting;
    /// this adds the weight, which the AppKit call has no parameter for.
    static func preferred(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        guard weight != .regular else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }
}
