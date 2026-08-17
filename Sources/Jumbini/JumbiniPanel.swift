import AppKit

/// The numbers every Jumbini panel is built from.
///
/// Three panels grew independently and drifted: 16pt of padding here, 20 there,
/// a 22pt close button beside a 24pt one, hard-coded 11pt and 15pt type. None of
/// the differences meant anything. They live here now so a change to the look of
/// one panel is a change to the look of all of them.
enum PanelStyle {
    static let cornerRadius: CGFloat = 22
    static let inset: CGFloat = 20
    static let spacing: CGFloat = 10
    static let closeButtonSide: CGFloat = 22

    /// Panel titles. Semantic rather than a point size, so the panels follow the
    /// system text size instead of pinning themselves to whatever looked right
    /// on one Mac — kept semibold, which is the weight all three already used.
    static var title: NSFont {
        let base = NSFont.preferredFont(forTextStyle: .title3)
        return .systemFont(ofSize: base.pointSize, weight: .semibold)
    }

    /// Secondary explanatory text: the grey line under a control.
    static var detail: NSFont { .preferredFont(forTextStyle: .caption1) }
}

/// The window every Jumbini panel is.
///
/// Borderless, non-activating, floating above full-screen apps, and blurred
/// behind its content. Opening one never steals focus from whatever the user is
/// doing, and each subclass supplies only its width and its content.
class JumbiniPanel: NSPanel {
    /// The fixed width the subclass asked for. Height is always measured from
    /// content, so subclasses size themselves against this rather than `frame`,
    /// which is still the placeholder until the first `setContentSize`.
    let panelWidth: CGFloat

    /// Width available between the insets.
    var contentWidth: CGFloat { panelWidth - PanelStyle.inset * 2 }

    /// Replaced by every subclass the moment its content has been measured;
    /// nothing is ever drawn at this height.
    private static let placeholderHeight: CGFloat = 400

    init(width: CGFloat) {
        panelWidth = width
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: Self.placeholderHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Liquid Glass refracts and tints what is behind the window, so the
        // window itself has to stay see-through for it to have anything to work
        // with — hence the clear background and `isOpaque = false`.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Borderless means no title bar to grab, which left all three panels
        // nailed to the centre of the screen with no way to move them off
        // whatever they had landed on top of. The background is the title bar.
        isMovableByWindowBackground = true
    }

    /// Borderless windows refuse key by default, which would leave a panel
    /// unable to hear a keystroke: no Escape to close it, and no Return on the
    /// default button either. `.nonactivatingPanel` still holds, so taking key
    /// here does not pull the user out of whatever app they were in.
    override var canBecomeKey: Bool { true }

    /// Install `content` as the panel's content view, wrapped in the blurred,
    /// rounded backdrop.
    ///
    /// The package deploys back to macOS 14, where there is no glass to ask for.
    /// `NSVisualEffectView`'s behind-window blur is the nearest thing that
    /// shipped, and every layout decision holds either way.
    func embed(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false

        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = PanelStyle.cornerRadius
            glass.contentView = content
            backdrop = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = PanelStyle.cornerRadius
            blur.layer?.masksToBounds = true
            blur.addSubview(content)
            backdrop = blur
        }

        // Pinned explicitly in both branches. `NSGlassEffectView.contentView`
        // does place the view for us, but it promises nothing about how, and a
        // stack left at its fitting size inside a fixed-size window would sit
        // centred with the title row spilling past the glass.
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: backdrop.topAnchor),
            content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
        ])
        contentView = backdrop
    }

    /// The way out. A borderless panel draws no close button of its own, so
    /// without this there is none — nothing but the panel's own primary action
    /// would dismiss it.
    ///
    /// A borderless button is exactly as big as its image, and an 11pt glyph is
    /// a fiddly thing to hit: the glyph stays small, the target around it does
    /// not. Escape is the other half of "closeable", and only reaches the panel
    /// once it is key, so the button stays the reliable route.
    func makeCloseButton(action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close"
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Close"
        button.keyEquivalent = "\u{1b}"
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: PanelStyle.closeButtonSide),
            button.heightAnchor.constraint(equalToConstant: PanelStyle.closeButtonSide),
        ])
        return button
    }

    /// Show the panel, centred the first time.
    ///
    /// Centring is skipped once it is on screen: a panel the user has dragged
    /// somewhere, or reopened from the menu while it was already up, should not
    /// jump back to the middle of the display.
    ///
    /// `orderFrontRegardless` keeps the no-focus-stealing behaviour for an app
    /// that has no Dock icon to activate through; `makeKey` then asks for the
    /// keyboard, which is what lets Escape close it. If the app is in the
    /// background the request simply goes unanswered until the user clicks in,
    /// which is the same moment the panel becomes key anyway.
    func present() {
        if !isVisible { center() }
        orderFrontRegardless()
        makeKey()
    }

    /// A refused toggle snaps its checkbox back on its own, which sighted users
    /// see and VoiceOver users would otherwise only hear as a state that did not
    /// change. Say why, at the moment it happens.
    func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
