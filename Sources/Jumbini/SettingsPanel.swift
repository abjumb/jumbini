import AppKit

/// Jumbini's settings surface: a sidebar of sections on the left, grouped cards
/// on the right.
///
/// This used to be one long column in a panel that could not be moved. The
/// sections below are the same settings; what changed is that they are sorted
/// into pages, so a Mac-behavior switch is not sitting three scrolls below an
/// API key, and the window can be dragged out of the dog's way.
///
/// Behavior switches save immediately. The Pixellab key is deliberately a
/// separate, explicit action: secrets go to Keychain, never UserDefaults, and
/// a half-entered key must not replace a working one as the user types.
final class SettingsPanel: JumbiniPanel {
    var onSettingsChanged: ((JumbiniSettings) -> Void)?
    /// Settings is where people go looking for the coat tools, so it offers
    /// them — but it does not own those panels, and says so by asking.
    var onOpenCoatWorkshop: (() -> Void)?
    var onOpenDogGenerator: (() -> Void)?

    private let defaults: UserDefaults
    private let loginItem: LoginItemController

    private let loginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let poopCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let reactionsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let climbingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let apiKeyField = NSSecureTextField(string: "")
    private let keyStatusLabel = NSTextField(labelWithString: "")
    private let keyFeedbackLabel = NSTextField(labelWithString: "")
    private let saveKeyButton = NSButton(title: "Save Key", target: nil, action: nil)
    private let removeKeyButton = NSButton(title: "Remove Key", target: nil, action: nil)

    private let searchField = NSSearchField()
    private var sidebarButtons: [PanelSidebarButton] = []
    private var pages: [String: NSView] = [:]
    private var pageContainer = NSView()
    private var selectedIdentifier = Section.general

    private static let panelWidth: CGFloat = 720
    private static let panelHeight: CGFloat = 480
    private static var contentWidth: CGFloat {
        panelWidth - PanelTheme.sidebarWidth - PanelTheme.contentInset * 2
    }

    private enum Section {
        static let general = "general"
        static let behavior = "behavior"
        static let windows = "windows"
        static let coats = "coats"
        static let pixellab = "pixellab"
        static let support = "support"
    }

    static let catalog = PanelSectionCatalog(groups: [
        PanelSectionGroup(
            title: nil,
            sections: [
                PanelSection(
                    identifier: Section.general, title: "General",
                    symbol: "gearshape.fill", tint: .systemGray
                )
            ]
        ),
        PanelSectionGroup(
            title: "Features",
            sections: [
                PanelSection(
                    identifier: Section.behavior, title: "Behavior",
                    symbol: "pawprint.fill", tint: .systemBlue
                ),
                PanelSection(
                    identifier: Section.windows, title: "Window Climbing",
                    symbol: "macwindow", tint: .systemTeal
                ),
            ]
        ),
        PanelSectionGroup(
            title: "Customization",
            sections: [
                PanelSection(
                    identifier: Section.coats, title: "Coats",
                    symbol: "paintbrush.fill", tint: .systemPink
                )
            ]
        ),
        PanelSectionGroup(
            title: "System",
            sections: [
                PanelSection(
                    identifier: Section.pixellab, title: "Pixellab API",
                    symbol: "key.fill", tint: .systemOrange
                ),
                PanelSection(
                    identifier: Section.support, title: "Support",
                    symbol: "lifepreserver.fill", tint: .systemGreen
                ),
            ]
        ),
    ])

    init(
        defaults: UserDefaults = .standard,
        loginItem: LoginItemController = LoginItemController()
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        super.init(
            autosaveName: "settings",
            size: NSSize(width: Self.panelWidth, height: Self.panelHeight)
        )
        setUpContent()
        reload()
    }

    // MARK: - Layout

    private func setUpContent() {
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

        installChrome(around: row)
        select(Section.general)
    }

    private func makeSidebar() -> NSView {
        searchField.placeholderString = "Search settings…"
        searchField.font = .systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search settings")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.heightAnchor.constraint(equalToConstant: 24).isActive = true

        var views: [NSView] = [searchField]
        for group in Self.catalog.groups {
            if let title = group.title {
                // Title Case here on purpose: in the reference design the
                // sidebar's group headings read "Features" while the content
                // headings above each card read "APPLICATION BASICS".
                let header = PanelTheme.title(title, size: 11, weight: .semibold)
                header.textColor = .secondaryLabelColor
                views.append(spacer(height: 6))
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
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for view in [searchField] + sidebarButtons {
            view.widthAnchor.constraint(
                equalToConstant: PanelTheme.sidebarWidth - 24
            ).isActive = true
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: PanelTheme.sidebarWidth),
            container.heightAnchor.constraint(equalToConstant: Self.panelHeight),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func makeDetail() -> NSView {
        pages = [
            Section.general: generalPage(),
            Section.behavior: behaviorPage(),
            Section.windows: windowsPage(),
            Section.coats: coatsPage(),
            Section.pixellab: pixellabPage(),
            Section.support: supportPage(),
        ]

        pageContainer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = PanelTheme.contentBackground.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pageContainer)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(
                equalToConstant: Self.panelWidth - PanelTheme.sidebarWidth - 1
            ),
            container.heightAnchor.constraint(equalToConstant: Self.panelHeight),
            pageContainer.topAnchor.constraint(equalTo: container.topAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    /// Wraps a page's sections in the scrolling pane every page shares.
    private func page(_ views: [NSView]) -> NSView {
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

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    // MARK: - Pages

    private func generalPage() -> NSView {
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginItemChanged)

        loginStatusLabel.font = .systemFont(ofSize: 11)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.maximumNumberOfLines = 4
        loginStatusLabel.lineBreakMode = .byWordWrapping
        let statusWidth = Self.contentWidth - PanelTheme.cardInset * 2 - 20
        loginStatusLabel.preferredMaxLayoutWidth = statusWidth
        loginStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        loginStatusLabel.widthAnchor.constraint(equalToConstant: statusWidth).isActive = true

        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let statusRow = NSStackView(views: [indent, loginStatusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 0

        loginCheckbox.title = "Launch Jumbini at login"
        loginCheckbox.font = .systemFont(ofSize: 13)
        loginCheckbox.setAccessibilityLabel("Launch Jumbini at login")

        return page([
            PanelTheme.sectionHeader("Application basics"),
            PanelBuilder.card([loginCheckbox, statusRow], width: Self.contentWidth),
        ])
    }

    private func behaviorPage() -> NSView {
        for checkbox in [poopCheckbox, reactionsCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(featureChanged)
        }
        return page([
            PanelTheme.sectionHeader("Jumba's routine"),
            PanelBuilder.card(
                [
                    PanelBuilder.checkRow(
                        poopCheckbox, title: "Bathroom breaks",
                        detail: "Allow hunching and piles, including after treats.",
                        width: Self.contentWidth
                    ),
                    PanelBuilder.checkRow(
                        reactionsCheckbox, title: "Mac-aware reactions",
                        detail: "React to builds, heat, battery, Focus, and time away.",
                        width: Self.contentWidth
                    ),
                ],
                width: Self.contentWidth
            ),
        ])
    }

    private func windowsPage() -> NSView {
        climbingCheckbox.target = self
        climbingCheckbox.action = #selector(featureChanged)
        return page([
            PanelTheme.sectionHeader("Window climbing"),
            PanelBuilder.card(
                [
                    PanelBuilder.checkRow(
                        climbingCheckbox, title: "Climb onto windows",
                        detail:
                            "Watch nearby windows, patrol their title bars, hop between "
                            + "neighbours, and nap on wide ones.",
                        width: Self.contentWidth
                    )
                ],
                width: Self.contentWidth
            ),
        ])
    }

    private func coatsPage() -> NSView {
        page([
            PanelTheme.sectionHeader("Coats"),
            PanelBuilder.card(
                [
                    PanelBuilder.linkRow(
                        symbol: "square.stack.3d.up.fill", tint: .systemPink,
                        title: "Coat Workshop",
                        subtitle: "Import, validate, preview and install custom coats",
                        width: Self.contentWidth, target: self,
                        action: #selector(openCoatWorkshop)
                    ),
                    PanelBuilder.linkRow(
                        symbol: "wand.and.stars", tint: .systemPurple,
                        title: "Make Your Own Dog",
                        subtitle: "Generate a coat from three photos via Pixellab",
                        width: Self.contentWidth, target: self,
                        action: #selector(openDogGenerator)
                    ),
                ],
                width: Self.contentWidth
            ),
        ])
    }

    private func pixellabPage() -> NSView {
        keyStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        keyStatusLabel.maximumNumberOfLines = 2

        let fieldWidth = Self.contentWidth - PanelTheme.cardInset * 2
        apiKeyField.placeholderString = "Paste a Pixellab API key"
        apiKeyField.setAccessibilityLabel("Pixellab API key")
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveAPIKey)
        saveKeyButton.keyEquivalent = "\r"
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeAPIKey)
        let actions = NSStackView(views: [saveKeyButton, removeKeyButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        keyFeedbackLabel.font = .systemFont(ofSize: 11)
        keyFeedbackLabel.textColor = .secondaryLabelColor
        keyFeedbackLabel.maximumNumberOfLines = 3
        keyFeedbackLabel.preferredMaxLayoutWidth = fieldWidth
        keyFeedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        keyFeedbackLabel.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        return page([
            PanelTheme.sectionHeader("Pixellab API"),
            PanelTheme.subtitle(
                "Make Your Own Dog uses your Pixellab key. It stays in your login Keychain "
                    + "and is sent only to Pixellab.",
                width: Self.contentWidth
            ),
            PanelBuilder.card(
                [keyStatusLabel, apiKeyField, actions, keyFeedbackLabel],
                width: Self.contentWidth
            ),
        ])
    }

    private func supportPage() -> NSView {
        page([
            PanelTheme.sectionHeader("About"),
            PanelBuilder.card(
                [PanelTheme.title(AppVersion.menuTitle, size: 13, weight: .medium)],
                width: Self.contentWidth
            ),
            PanelTheme.sectionHeader("Help"),
            PanelBuilder.card(
                [
                    PanelBuilder.linkRow(
                        symbol: "ladybug.fill", tint: .systemRed, title: "Report a Bug",
                        subtitle: "Help improve Jumbini by reporting issues",
                        width: Self.contentWidth, target: self, action: #selector(reportBug)
                    ),
                    PanelBuilder.linkRow(
                        symbol: "chevron.left.forwardslash.chevron.right", tint: .systemPurple,
                        title: "View Source Code",
                        subtitle: "Jumbini is open source on GitHub",
                        width: Self.contentWidth, target: self, action: #selector(viewSource)
                    ),
                ],
                width: Self.contentWidth
            ),
        ])
    }

    // MARK: - Selection

    private func select(_ identifier: String) {
        selectedIdentifier = identifier
        for button in sidebarButtons {
            button.isSelectedRow = button.identifier?.rawValue == identifier
        }
        pageContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let page = pages[identifier] else { return }
        page.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pageContainer.topAnchor, constant: 36),
            page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
        ])
    }

    @objc private func sidebarClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        select(identifier)
    }

    /// Typing jumps to the first section whose name matches. Deliberately not a
    /// content-wide index: six pages do not need one, and a search that silently
    /// missed a setting would be worse than no search at all.
    @objc private func searchChanged() {
        guard let match = Self.catalog.firstMatch(for: searchField.stringValue) else { return }
        select(match.identifier)
    }

    // MARK: - State

    private func reload() {
        // Login state is read from macOS on every open, never remembered. If
        // the user turned the item off in System Settings since last time, this
        // is where Jumbini finds out.
        apply(loginState: loginItem.currentState())
        let settings = JumbiniSettings(defaults: defaults)
        poopCheckbox.state = settings.poopEnabled ? .on : .off
        reactionsCheckbox.state = settings.systemReactionsEnabled ? .on : .off
        climbingCheckbox.state = settings.windowClimbingEnabled ? .on : .off
        apiKeyField.stringValue = ""
        keyFeedbackLabel.textColor = .secondaryLabelColor
        keyFeedbackLabel.stringValue = PixellabClient.hasEnvironmentAPIKey
            ? "PIXELLAB_API_KEY overrides a saved key for this development run."
            : "For security, a saved key is never displayed again."
        refreshKeyStatus()
    }

    private func refreshKeyStatus() {
        let stored = PixellabClient.hasStoredAPIKey
        let environment = PixellabClient.hasEnvironmentAPIKey
        switch (stored, environment) {
        case (true, true):
            keyStatusLabel.stringValue = "Key saved in Keychain · environment key active"
        case (true, false):
            keyStatusLabel.stringValue = "Key saved in Keychain"
        case (false, true):
            keyStatusLabel.stringValue = "Environment key active for this run"
        case (false, false):
            keyStatusLabel.stringValue = "No Pixellab key configured"
        }
        removeKeyButton.isEnabled = stored
    }

    /// `announcing` is true only for a state the user's own click produced.
    /// Reopening Settings runs through here too, and a panel that read its
    /// status aloud every time it opened would be noise, not feedback.
    private func apply(loginState state: LoginItemViewState, announcing: Bool = false) {
        loginCheckbox.state = state.isOn ? .on : .off
        // The status line sits beside the checkbox rather than inside it, so
        // VoiceOver would otherwise reach the control and its explanation as
        // two unrelated things — and reach the explanation only by looking for
        // it. As help, it arrives with the control.
        loginCheckbox.setAccessibilityHelp(state.message)
        loginStatusLabel.textColor = state.isFailure ? .systemRed : .secondaryLabelColor
        loginStatusLabel.stringValue = state.message
        guard announcing, state.needsAttention else { return }
        announce(state.message)
    }

    /// A refused toggle snaps the checkbox back on its own, which sighted users
    /// see and VoiceOver users would otherwise only hear as a state that did
    /// not change. Say why, at the moment it happens.
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: - Actions

    /// Registration happens now, and the row redraws from whatever macOS
    /// reports afterwards — including a refusal, which is reported inline and
    /// changes nothing else about the running app.
    @objc private func loginItemChanged() {
        apply(
            loginState: loginItem.setEnabled(loginCheckbox.state == .on),
            announcing: true
        )
    }

    @objc private func featureChanged() {
        let settings = JumbiniSettings(
            poopEnabled: poopCheckbox.state == .on,
            systemReactionsEnabled: reactionsCheckbox.state == .on,
            windowClimbingEnabled: climbingCheckbox.state == .on
        )
        settings.save(to: defaults)
        onSettingsChanged?(settings)
    }

    @objc private func saveAPIKey() {
        do {
            try PixellabClient.storeAPIKey(apiKeyField.stringValue)
            apiKeyField.stringValue = ""
            keyFeedbackLabel.textColor = .secondaryLabelColor
            keyFeedbackLabel.stringValue = "Saved securely. Make Your Own Dog is ready."
            refreshKeyStatus()
        } catch {
            keyFeedbackLabel.textColor = .systemRed
            keyFeedbackLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func removeAPIKey() {
        do {
            try PixellabClient.removeStoredAPIKey()
            apiKeyField.stringValue = ""
            keyFeedbackLabel.textColor = .secondaryLabelColor
            keyFeedbackLabel.stringValue = PixellabClient.hasEnvironmentAPIKey
                ? "Removed the Keychain key. The environment key is still active for this run."
                : "Removed the Pixellab key."
            refreshKeyStatus()
        } catch {
            keyFeedbackLabel.textColor = .systemRed
            keyFeedbackLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func openCoatWorkshop() {
        onOpenCoatWorkshop?()
    }

    @objc private func openDogGenerator() {
        onOpenDogGenerator?()
    }

    @objc private func reportBug() {
        open("https://github.com/abjumb/jumbini/issues/new")
    }

    @objc private func viewSource() {
        open("https://github.com/abjumb/jumbini")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    func present() {
        reload()
        presentPanel()
    }
}
