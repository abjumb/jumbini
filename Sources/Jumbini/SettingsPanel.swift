import AppKit

/// Jumbini's small, native settings surface.
///
/// Behavior switches save immediately. The Pixellab key is deliberately a
/// separate, explicit action: secrets go to Keychain, never UserDefaults, and
/// a half-entered key must not replace a working one as the user types.
final class SettingsPanel: NSPanel {
    var onSettingsChanged: ((JumbiniSettings) -> Void)?

    private let defaults: UserDefaults
    private let poopCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let reactionsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let climbingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let apiKeyField = NSSecureTextField(string: "")
    private let keyStatusLabel = NSTextField(labelWithString: "")
    private let keyFeedbackLabel = NSTextField(labelWithString: "")
    private let saveKeyButton = NSButton(title: "Save Key", target: nil, action: nil)
    private let removeKeyButton = NSButton(title: "Remove Key", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    private static let panelWidth: CGFloat = 440
    private static let initialHeight: CGFloat = 520
    private static let inset: CGFloat = 20
    private static let cornerRadius: CGFloat = 22

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        title.font = .systemFont(ofSize: 17, weight: .semibold)
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

        keyStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
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

        keyFeedbackLabel.font = .systemFont(ofSize: 11)
        keyFeedbackLabel.textColor = .secondaryLabelColor
        keyFeedbackLabel.maximumNumberOfLines = 3
        keyFeedbackLabel.preferredMaxLayoutWidth = Self.panelWidth - Self.inset * 2
        keyFeedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        keyFeedbackLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        let stack = NSStackView(views: [
            header,
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

        let contentWidth = Self.panelWidth - Self.inset * 2
        for view in [header, featuresIntro, divider, apiIntro, keyStatusLabel, keyFeedbackLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        stack.layoutSubtreeIfNeeded()
        contentView = makeBackdrop(around: stack)
        setContentSize(NSSize(width: Self.panelWidth, height: stack.fittingSize.height))
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func detailLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
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
        checkbox.font = .systemFont(ofSize: 13, weight: .medium)
        checkbox.setAccessibilityLabel(title)
        let detailLabel = detailLabel(detail)
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let detailRow = NSStackView(views: [indent, detailLabel])
        detailRow.orientation = .horizontal
        detailRow.alignment = .top
        detailRow.spacing = 0

        let row = NSStackView(views: [checkbox, detailRow])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
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
