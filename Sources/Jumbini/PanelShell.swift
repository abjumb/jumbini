import AppKit

/// The sidebar-and-pages chrome the settings-style panels share: a list of
/// sections on the left, the selected one's page on the right.
///
/// `PanelSectionCatalog` was already split out so the matching rules could be
/// tested, but the ~130 lines that turn a catalog into a sidebar, a page
/// container and a selection were copy-pasted between the only two panels using
/// it — constraint for constraint, down to the separator's width and the stack's
/// spacing. The copies had already drifted in three ways: the selection method
/// was `select` in one and `showSection` in the other, one was `private` and one
/// internal (which is the only reason a test could reach one of them), and one
/// remembered the selection while the other recomputed it from button state.
///
/// The seam is between *what the sections are and which one is showing* — this
/// type — and *what is on a page*, which stays with the panel.
@MainActor
final class PanelShell: NSObject {
    /// The search field's copy, when a panel wants one. Tidy has three sections
    /// and does not.
    struct Search {
        let placeholder: String
        /// Deliberately separate from the placeholder: the placeholder ends in
        /// an ellipsis, which VoiceOver would read out.
        let accessibilityLabel: String
    }

    private let catalog: PanelSectionCatalog
    private let size: CGSize
    private let searchField: NSSearchField?
    private var sidebarButtons: [PanelSidebarButton] = []
    private var pages: [String: NSView] = [:]
    private let pageContainer = NSView()

    /// Which section's page is on screen. Both panels needed this and only one
    /// of them kept it.
    private(set) var visibleSection = ""

    /// Sidebar, separator and page container, laid out and ready for
    /// `installChrome(around:)`.
    let contentView: NSView

    init(catalog: PanelSectionCatalog, size: CGSize, search: Search? = nil) {
        self.catalog = catalog
        self.size = size
        self.searchField = search.map { _ in NSSearchField() }
        self.contentView = NSView()
        super.init()

        if let search, let field = searchField {
            field.placeholderString = search.placeholder
            field.font = .systemFont(ofSize: 12)
            field.target = self
            field.action = #selector(searchChanged)
            field.setAccessibilityLabel(search.accessibilityLabel)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        build()
    }

    /// Hand over each section's page. Call before `show(_:)`.
    func setPages(_ pages: [String: NSView]) {
        self.pages = pages
    }

    /// Put `identifier`'s page on screen.
    ///
    /// The lookup happens BEFORE the container is cleared. It used to happen
    /// after, so an identifier with no page emptied the content area and left
    /// its sidebar row highlighted — a panel that looks broken rather than one
    /// that did nothing. Nothing enforces that a catalog and a page dictionary
    /// agree, so this is reachable by a mismatch alone.
    func show(_ identifier: String) {
        guard let page = pages[identifier] else { return }
        visibleSection = identifier
        for button in sidebarButtons {
            button.isSelectedRow = button.identifier?.rawValue == identifier
        }
        pageContainer.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(
                equalTo: pageContainer.topAnchor, constant: PanelTheme.titleBarInset
            ),
            page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
        ])
    }

    /// Wraps a page's sections in the scrolling pane every page shares.
    static func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: PanelTheme.contentInset,
            left: PanelTheme.contentInset,
            bottom: PanelTheme.contentInset,
            right: PanelTheme.contentInset
        )
        return PanelBuilder.scrollPane(around: stack)
    }

    static func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    // MARK: - Layout

    private func build() {
        let sidebar = makeSidebar()
        let detail = makeDetail()

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let row = NSStackView(views: [sidebar, divider, detail])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    private func makeSidebar() -> NSView {
        var views: [NSView] = searchField.map { [$0] } ?? []
        for group in catalog.groups {
            if let title = group.title {
                // Title Case here on purpose: in the reference design the
                // sidebar's group headings read "Features" while the content
                // headings above each card read "APPLICATION BASICS".
                let header = PanelTheme.title(title, size: 11, weight: .semibold)
                header.textColor = .secondaryLabelColor
                views.append(Self.spacer(height: 6))
                views.append(header)
            }
            for section in group.sections {
                let button = PanelSidebarButton(
                    section: section, target: self, action: #selector(sidebarClicked(_:))
                )
                sidebarButtons.append(button)
                views.append(button)
            }
        }
        views.append(NSView())

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        // The window's own title bar is invisible but still there, so the top
        // of the sidebar has to clear the traffic lights. Applied here and on
        // the page container in `show`, which is the whole of it — it used to be
        // applied independently in each panel.
        stack.edgeInsets = NSEdgeInsets(
            top: PanelTheme.titleBarInset, left: 12, bottom: 12, right: 12
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        for view in (searchField.map { [$0 as NSView] } ?? []) + sidebarButtons {
            view.widthAnchor.constraint(
                equalToConstant: PanelTheme.sidebarWidth - 24
            ).isActive = true
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: PanelTheme.sidebarWidth),
            container.heightAnchor.constraint(equalToConstant: size.height),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func makeDetail() -> NSView {
        pageContainer.translatesAutoresizingMaskIntoConstraints = false

        let container = PanelSurfaceView()
        container.fill = PanelTheme.contentBackground
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pageContainer)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(
                equalToConstant: size.width - PanelTheme.sidebarWidth - 1
            ),
            container.heightAnchor.constraint(equalToConstant: size.height),
            pageContainer.topAnchor.constraint(equalTo: container.topAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    // MARK: - Input

    @objc private func sidebarClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        show(identifier)
    }

    /// Typing jumps to the first section whose name matches. Deliberately not a
    /// content-wide index: a handful of pages do not need one, and a search that
    /// silently missed a setting would be worse than no search at all.
    @objc private func searchChanged() {
        guard let field = searchField,
              let match = catalog.firstMatch(for: field.stringValue) else { return }
        show(match.identifier)
    }
}
