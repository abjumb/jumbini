import AppKit

/// Jumbini's small, native settings surface.
///
/// Behavior switches save immediately. The Pixellab key is deliberately a
/// separate, explicit action: secrets go to Keychain, never UserDefaults, and
/// a half-entered key must not replace a working one as the user types.
final class SettingsPanel: NSPanel {
    var onSettingsChanged: ((JumbiniSettings) -> Void)?

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
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private var contentStack: NSStackView?

    private static let panelWidth: CGFloat = 440
    private static let initialHeight: CGFloat = 520
    private static let inset: CGFloat = 20
    private static let cornerRadius: CGFloat = 22
    private static let indentWidth: CGFloat = 22
    private static let contentWidth = panelWidth - inset * 2
    private static let detailWidth = contentWidth - indentWidth

    init(
        defaults: UserDefaults = .standard,
        loginItem: LoginItemController = LoginItemController()
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        super.init(
            contentRect: NSRect(
                x: 0, y: 0, width: Self.panelWidth, height: Self.initialHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setUpContent()
        reload()
    }

    override var canBecomeKey: Bool { true }

    private func setUpContent() {
        let title = NSTextField(labelWithString: "Jumbini Settings")
        title.font = .preferred(.title2, weight: .semibold)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close settings"
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismissPanel)
        closeButton.toolTip = "Close"
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        let header = NSStackView(views: [title, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill

        let startupTitle = sectionTitle("Startup")
        loginCheckbox.title = "Open Jumbini at login"
        loginCheckbox.font = .preferred(.body, weight: .medium)
        loginCheckbox.setAccessibilityLabel("Open Jumbini at login")
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginItemChanged)

        // This line says whatever macOS just said, which is one calm sentence
        // most of the time and a wrapped refusal occasionally. Rather than park
        // four empty rows under the checkbox forever, the label sizes to its
        // text and the panel re-fits around it — see resizeToFitContent().
        loginStatusLabel.font = .preferred(.subheadline)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.maximumNumberOfLines = 4
        loginStatusLabel.lineBreakMode = .byWordWrapping
        loginStatusLabel.preferredMaxLayoutWidth = Self.detailWidth
        loginStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        loginStatusLabel.widthAnchor.constraint(
            equalToConstant: Self.detailWidth
        ).isActive = true
        let loginRow = NSStackView(views: [loginCheckbox, indented(loginStatusLabel)])
        loginRow.orientation = .vertical
        loginRow.alignment = .leading
        loginRow.spacing = 2

        let startupDivider = NSBox()
        startupDivider.boxType = .separator

        let featuresTitle = sectionTitle("Jumba's behavior")
        let featuresIntro = detailLabel(
            "Turn off the parts of his routine that do not belong on your desktop. Changes take effect immediately."
        )

        let poopRow = featureRow(
            checkbox: poopCheckbox,
            title: "Bathroom breaks",
            detail: "Allow hunching and piles, including after treats."
        )
        let reactionsRow = featureRow(
            checkbox: reactionsCheckbox,
            title: "Mac-aware reactions",
            detail: "React to builds, heat, battery, Focus, and time away."
        )
        let climbingRow = featureRow(
            checkbox: climbingCheckbox,
            title: "Window climbing",
            detail: "Watch nearby windows and patrol their title bars."
        )
        for checkbox in [poopCheckbox, reactionsCheckbox, climbingCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(featureChanged)
        }

        let divider = NSBox()
        divider.boxType = .separator

        let apiTitle = sectionTitle("Pixellab API")
        let apiIntro = detailLabel(
            "Make Your Own Dog uses your Pixellab key. It stays in your login Keychain and is sent only to Pixellab."
        )

        keyStatusLabel.font = .preferred(.callout, weight: .medium)
        keyStatusLabel.maximumNumberOfLines = 2

        apiKeyField.placeholderString = "Paste a Pixellab API key"
        apiKeyField.setAccessibilityLabel("Pixellab API key")
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.widthAnchor.constraint(
            equalToConstant: Self.panelWidth - Self.inset * 2
        ).isActive = true

        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveAPIKey)
        saveKeyButton.keyEquivalent = "\r"
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeAPIKey)
        let keyActions = NSStackView(views: [saveKeyButton, removeKeyButton])
        keyActions.orientation = .horizontal
        keyActions.spacing = 8

        keyFeedbackLabel.font = .preferred(.subheadline)
        keyFeedbackLabel.textColor = .secondaryLabelColor
        keyFeedbackLabel.maximumNumberOfLines = 3
        keyFeedbackLabel.preferredMaxLayoutWidth = Self.panelWidth - Self.inset * 2
        keyFeedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        keyFeedbackLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        let stack = NSStackView(views: [
            header,
            startupTitle,
            loginRow,
            startupDivider,
            featuresTitle,
            featuresIntro,
            poopRow,
            reactionsRow,
            climbingRow,
            divider,
            apiTitle,
            apiIntro,
            keyStatusLabel,
            apiKeyField,
            keyActions,
            keyFeedbackLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: Self.inset,
            left: Self.inset,
            bottom: Self.inset,
            right: Self.inset
        )

        let contentWidth = Self.contentWidth
        for view in [
            header, startupDivider, featuresIntro, divider, apiIntro, keyStatusLabel,
            keyFeedbackLabel,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        for separator in [startupDivider, divider] {
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }

        contentStack = stack
        contentView = makeBackdrop(around: stack)
        resizeToFitContent()
    }

    /// The panel is borderless and has no layout of its own, so it takes its
    /// height from the stack, and takes it again whenever the login status line
    /// changes length.
    private func resizeToFitContent() {
        guard let contentStack else { return }
        contentStack.layoutSubtreeIfNeeded()
        let top = frame.maxY
        setContentSize(NSSize(width: Self.panelWidth, height: contentStack.fittingSize.height))
        // While it is on screen, grow downward from a fixed top edge: a refusal
        // that wraps onto an extra line must not shove the whole panel up out
        // from under the pointer that just clicked the checkbox. Before it is
        // shown there is no position worth keeping — present() centers it.
        guard isVisible else { return }
        setFrameOrigin(NSPoint(x: frame.origin.x, y: top - frame.height))
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .preferred(.headline)
        return label
    }

    private func detailLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .preferred(.subheadline)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.panelWidth - Self.inset * 2
        return label
    }

    private func featureRow(
        checkbox: NSButton,
        title: String,
        detail: String
    ) -> NSStackView {
        checkbox.title = title
        checkbox.font = .preferred(.body, weight: .medium)
        checkbox.setAccessibilityLabel(title)
        let row = NSStackView(views: [checkbox, indented(detailLabel(detail))])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    /// Line up secondary text under the checkbox title rather than under its box.
    private func indented(_ view: NSView) -> NSStackView {
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: Self.indentWidth).isActive = true
        let row = NSStackView(views: [indent, view])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        return row
    }

    private func makeBackdrop(around content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false

        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            backdrop = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = Self.cornerRadius
            blur.layer?.masksToBounds = true
            blur.addSubview(content)
            backdrop = blur
        }

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: backdrop.topAnchor),
            content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
        ])
        return backdrop
    }

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
        resizeToFitContent()
        // A refused toggle snaps the checkbox back on its own, which sighted
        // users see and VoiceOver users would otherwise only hear as a state
        // that did not change. Say why, at the moment it happens.
        guard announcing, state.needsAttention else { return }
        Accessibility.announce(state.message)
    }

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

    @objc private func dismissPanel() {
        orderOut(nil)
    }

    func present() {
        reload()
        center()
        orderFrontRegardless()
        makeKey()
    }
}
