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
@MainActor
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

    private let shell = PanelShell(
        catalog: catalog,
        size: CGSize(width: panelWidth, height: panelHeight),
        search: PanelShell.Search(
            placeholder: "Search settings…", accessibilityLabel: "Search settings"
        )
    )

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
        shell.setPages([
            Section.general: generalPage(),
            Section.behavior: behaviorPage(),
            Section.windows: windowsPage(),
            Section.coats: coatsPage(),
            Section.pixellab: pixellabPage(),
            Section.support: supportPage(),
        ])
        installChrome(around: shell.contentView)
        shell.show(Section.general)
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

        return PanelShell.page([
            PanelTheme.sectionHeader("Application basics"),
            PanelBuilder.card([loginCheckbox, statusRow], width: Self.contentWidth),
        ])
    }

    private func behaviorPage() -> NSView {
        for checkbox in [poopCheckbox, reactionsCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(featureChanged)
        }
        return PanelShell.page([
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
        return PanelShell.page([
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
        PanelShell.page([
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

        return PanelShell.page([
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
        PanelShell.page([
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

    /// Which section is showing. Forwarded so tests can drive the panel the
    /// way the sidebar does.
    func showSection(_ identifier: String) { shell.show(identifier) }
    var visibleSection: String { shell.visibleSection }

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
