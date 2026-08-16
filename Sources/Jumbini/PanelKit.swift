import AppKit

/// The shared look and behavior for every panel Jumbini puts on screen.
///
/// Settings, Coat Workshop and Make Your Own Dog were three separately-built
/// borderless panels that each rolled their own backdrop, header and close
/// button, and none of them could be moved: they opened where they opened and
/// stayed there, which is fine for a sheet and wrong for something you want to
/// leave open beside the dog while you work.
///
/// This file is the one place that decides what a Jumbini panel looks like —
/// a sidebar of sections on the left, grouped cards on the right — so the three
/// of them stay in agreement without anyone remembering to keep them in sync.
enum PanelTheme {
    /// Corner radius of the window itself.
    static let cornerRadius: CGFloat = 12
    /// Corner radius of the grouped cards inside the content pane.
    static let cardRadius: CGFloat = 8
    static let sidebarWidth: CGFloat = 210
    static let contentInset: CGFloat = 20
    static let cardInset: CGFloat = 12
    static let rowSpacing: CGFloat = 10

    /// Panels are designed dark, matching the rest of the app's chrome, but
    /// these stay dynamic so a light-appearance Mac gets sensible surfaces
    /// rather than black-on-black.
    static let cardBackground = dynamic(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.70),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.06)
    )
    static let cardBorder = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.08),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.08)
    )
    static let sidebarSelection = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.12)
    )
    static let sidebarHover = dynamic(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.05),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.06)
    )
    static let contentBackground = dynamic(
        light: NSColor(calibratedWhite: 0.96, alpha: 1.0),
        dark: NSColor(calibratedWhite: 0.13, alpha: 1.0)
    )

    /// `NSColor(name:dynamicProvider:)` rather than two hardcoded colors so the
    /// surfaces follow the system appearance without every call site checking.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    static func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func title(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular)
        -> NSTextField
    {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    static func subtitle(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }
}

// MARK: - Dragging

/// A view whose whole job is to hand mouse drags to the window.
///
/// `isMovableByWindowBackground` alone is unreliable here: the panel's backdrop
/// is an `NSVisualEffectView`, and controls sitting on top of it eat the events
/// before the window ever sees them. Forwarding to `performDrag(with:)` from a
/// view that is deliberately behind everything else makes the drag work from
/// any empty space, which is what people expect of a window with no title bar.
final class PanelDragArea: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// Without this the drag area would swallow clicks meant for the panel
    /// behind it in the responder chain on first click.
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Base panel

/// Borderless, floating, draggable, and it remembers where you left it.
class JumbiniPanel: NSPanel {
    /// Distinguishes this panel's saved position from the others'.
    private let autosaveName: String
    private var hasRestoredPosition = false

    init(autosaveName: String, size: NSSize) {
        self.autosaveName = autosaveName
        // Titled rather than borderless, with the title bar made transparent and
        // its text hidden. That is what the reference design actually shows: a
        // real traffic light in the top-left corner, not a drawn-on glyph in the
        // top-right. It also hands back the two things going borderless had cost
        // — the system's own window dragging, and its corner rounding — which is
        // why the panels were stuck where they opened in the first place.
        //
        // `.nonactivatingPanel` still holds, so opening one does not pull focus
        // out of whatever app the user was in.
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        // Neither means anything for a fixed-size utility panel, and a pair of
        // permanently dead buttons beside a live one looks like a bug.
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Belt and braces with PanelDragArea: this covers any bare backdrop the
        // drag area does not reach.
        isMovableByWindowBackground = true
        // Dragging a window happens in the window server, so it does not
        // necessarily come back through setFrameOrigin — the move notification
        // is the one signal that fires however the window got moved.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func panelDidMove() {
        guard hasRestoredPosition else { return }
        rememberPosition()
    }

    override var canBecomeKey: Bool { true }

    /// Wraps content in the rounded, translucent chrome every panel shares, and
    /// puts a drag area behind it so the whole window can be moved.
    func installChrome(around content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false

        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = PanelTheme.cornerRadius
        backdrop.layer?.masksToBounds = true

        let drag = PanelDragArea()
        drag.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(drag)
        backdrop.addSubview(content)

        NSLayoutConstraint.activate([
            drag.topAnchor.constraint(equalTo: backdrop.topAnchor),
            drag.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            drag.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            drag.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            content.topAnchor.constraint(equalTo: backdrop.topAnchor),
            content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
        ])
        contentView = backdrop
    }

    /// Closing now goes through the real red button in the title bar, so the
    /// only thing left to arrange is that Escape does the same and that each
    /// panel gets to tidy up on the way out.
    override func performClose(_ sender: Any?) {
        panelWillClose()
        rememberPosition()
        orderOut(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    /// Subclasses override to stop anything they started — the Coat Workshop's
    /// live preview, for instance, must not outlive the window that drives it.
    func panelWillClose() {}

    /// Centers the first time and restores the saved corner every time after.
    ///
    /// The old panels called `center()` on every open, so moving one out of the
    /// way lasted exactly until you closed it. Position is saved on close and on
    /// move, and clamped back onto a visible screen in case the display it was
    /// left on is gone.
    func presentPanel() {
        if !hasRestoredPosition {
            hasRestoredPosition = true
            if let saved = savedOrigin() {
                setFrameOrigin(clamped(saved))
            } else {
                center()
            }
        }
        orderFrontRegardless()
        makeKey()
    }

    func rememberPosition() {
        UserDefaults.standard.set(
            NSStringFromPoint(frame.origin),
            forKey: "panel.\(autosaveName).origin"
        )
    }

    private func savedOrigin() -> NSPoint? {
        guard
            let raw = UserDefaults.standard.string(forKey: "panel.\(autosaveName).origin")
        else { return nil }
        let point = NSPointFromString(raw)
        return point == .zero ? nil : point
    }

    /// A panel restored onto a monitor that is no longer attached would open
    /// off-screen and look like it failed to open at all.
    private func clamped(_ origin: NSPoint) -> NSPoint {
        let candidate = NSRect(origin: origin, size: frame.size)
        let fits = NSScreen.screens.contains { $0.visibleFrame.intersects(candidate) }
        guard !fits, let main = NSScreen.main else { return origin }
        let visible = main.visibleFrame
        return NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        )
    }

}

// MARK: - Sidebar

/// One row in the left-hand list.
struct PanelSection {
    let identifier: String
    let title: String
    let symbol: String
    let tint: NSColor
}

/// A titled group of rows, matching the "Features / Customization / System"
/// headings in the design.
struct PanelSectionGroup {
    let title: String?
    let sections: [PanelSection]
}

/// The sidebar's contents, and the search over them.
///
/// Split out from the panel so the matching rules can be tested without an
/// `NSWindow`: the panel itself is rendering and input, which this project
/// tests by hand, but "what does typing this jump to" is a pure question and
/// answering it wrong sends people to the wrong page in silence.
struct PanelSectionCatalog {
    let groups: [PanelSectionGroup]

    var sections: [PanelSection] { groups.flatMap(\.sections) }

    /// Case- and whitespace-insensitive prefix-then-substring match.
    ///
    /// Prefix wins so that typing "co" reaches Coats rather than whichever
    /// section merely contains those letters, which is the behaviour people
    /// expect from a jump field and not what a plain `contains` gives.
    func firstMatch(for query: String) -> PanelSection? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let candidates = sections
        if let prefix = candidates.first(where: { $0.title.lowercased().hasPrefix(needle) }) {
            return prefix
        }
        return candidates.first { $0.title.lowercased().contains(needle) }
    }
}

final class PanelSidebarButton: NSButton {
    var isSelectedRow = false {
        didSet { refresh() }
    }

    init(section: PanelSection, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        identifier = NSUserInterfaceItemIdentifier(section.identifier)
        title = "  " + section.title
        image = NSImage(
            systemSymbolName: section.symbol,
            accessibilityDescription: section.title
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        contentTintColor = section.tint
        imagePosition = .imageLeading
        alignment = .left
        isBordered = false
        font = .systemFont(ofSize: 13)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        setAccessibilityLabel(section.title)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func refresh() {
        layer?.backgroundColor =
            isSelectedRow ? PanelTheme.sidebarSelection.cgColor : NSColor.clear.cgColor
        setAccessibilitySelected(isSelectedRow)
    }
}

// MARK: - Content building blocks

enum PanelBuilder {
    /// A rounded, bordered container holding stacked rows — the boxes the
    /// design groups its checkboxes into.
    static func card(_ rows: [NSView], width: CGFloat) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PanelTheme.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: PanelTheme.cardInset,
            left: PanelTheme.cardInset,
            bottom: PanelTheme.cardInset,
            right: PanelTheme.cardInset
        )

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = PanelTheme.cardRadius
        container.layer?.backgroundColor = PanelTheme.cardBackground.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = PanelTheme.cardBorder.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    /// Checkbox with an optional explanatory line beneath it, indented to line
    /// up under the title rather than under the box.
    static func checkRow(
        _ checkbox: NSButton,
        title: String,
        detail: String? = nil,
        width: CGFloat
    ) -> NSView {
        checkbox.title = title
        checkbox.font = .systemFont(ofSize: 13)
        checkbox.setAccessibilityLabel(title)
        guard let detail else { return checkbox }

        checkbox.setAccessibilityHelp(detail)
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let detailRow = NSStackView(views: [
            indent, PanelTheme.subtitle(detail, width: width - 20 - PanelTheme.cardInset * 2),
        ])
        detailRow.orientation = .horizontal
        detailRow.alignment = .top
        detailRow.spacing = 0

        let stack = NSStackView(views: [checkbox, detailRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    /// Icon tile + title + subtitle + chevron: the tappable rows across the top
    /// of the design.
    static func linkRow(
        symbol: String,
        tint: NSColor,
        title: String,
        subtitle: String,
        width: CGFloat,
        target: AnyObject,
        action: Selector
    ) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 5
        tile.layer?.backgroundColor = tint.withAlphaComponent(0.20).cgColor
        tile.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        glyph.contentTintColor = tint
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 26),
            tile.heightAnchor.constraint(equalToConstant: 26),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        let labelWidth = width - 26 - 8 - 16 - PanelTheme.cardInset * 2
        let text = NSStackView(views: [
            PanelTheme.title(title, size: 13, weight: .medium),
            PanelTheme.subtitle(subtitle, width: labelWidth),
        ])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor

        let row = NSStackView(views: [tile, text, NSView(), chevron])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        // The whole row is the target, not just the title, so the click area
        // matches what the chevron implies.
        let button = NSButton(title: "", target: target, action: action)
        button.isBordered = false
        button.title = ""
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(subtitle)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(
                equalToConstant: width - PanelTheme.cardInset * 2
            ),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    /// A scrollable right-hand pane. Panels vary a lot in height, and the design
    /// scrolls rather than growing the window past the screen.
    static func scrollPane(around stack: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedClipContent()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
        ])
        scroll.documentView = flipped
        return scroll
    }
}

/// Document views scroll from the top only when they are flipped; without this
/// the content pane starts scrolled to the bottom.
final class FlippedClipContent: NSView {
    override var isFlipped: Bool { true }
}
