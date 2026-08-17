import AppKit

/// What a rule does, in words rather than enum cases.
///
/// The rules list has one line per rule and no room for the editor's controls,
/// so this is the only place most people will read what a rule actually matches.
/// It is pure so the wording can be tested without a window.
enum TidyRuleSummary {
    static func text(for rule: TidyRule) -> String {
        guard !rule.conditions.isEmpty else { return "No conditions yet" }
        let prefix = rule.match == .all ? "All of: " : "Any of: "
        return prefix + rule.conditions.map(text(for:)).joined(separator: ", ")
    }

    static func text(for condition: TidyCondition) -> String {
        switch condition {
        case .kind(let kind):
            return kind.pluralName
        case .filenameContains(let value):
            return "name contains “\(value)”"
        case .extensions(let values):
            let names = values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            return "extension " + names.joined(separator: " or ")
        case .modifiedMoreThanDays(let days):
            return "older than \(days) day\(days == 1 ? "" : "s")"
        case .largerThanMB(let megabytes):
            return "larger than \(formatted(megabytes)) MB"
        }
    }

    /// Whole numbers read as "2 MB", not "2.0 MB", but 2.5 must keep its half.
    static func formatted(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }
}

extension TidyKind {
    /// Singular for a popup item, plural for a sentence about what matches.
    var displayName: String {
        switch self {
        case .image: return "Image"
        case .screenshot: return "Screenshot"
        case .document: return "Document"
        case .archive: return "Archive"
        case .installer: return "Installer"
        case .video: return "Video"
        case .audio: return "Audio"
        case .other: return "Other"
        }
    }

    var pluralName: String {
        switch self {
        case .other: return "anything else"
        default: return displayName.lowercased() + "s"
        }
    }
}

/// Tidy's own settings window: which folder, which rules, and when.
///
/// It renders `TidyCoordinator.State` and reports intent back through closures;
/// it never touches the filesystem, the store, or the rules on disk itself. That
/// keeps the one place a user can change what Tidy will move free of any way to
/// move something, and it is why every control here can be exercised in a test
/// without a folder grant.
final class TidySettingsPanel: JumbiniPanel {
    var onChooseFolder: (() -> Void)?
    var onForgetFolder: (() -> Void)?
    var onRulesChanged: ((TidyRuleSet) -> Void)?
    var onRecencyChanged: ((Int) -> Void)?
    var onIdleChanged: ((Bool) -> Void)?
    var onIdleMinutesChanged: ((Int) -> Void)?
    var onAddRule: (() -> Void)?
    var onEditRule: ((TidyRule) -> Void)?

    private var ruleSet = TidyRuleSet.defaults
    private var folder: URL?
    private var blockingError: String?
    private var needsPreview = true

    private(set) var recencyMinutes = 5
    private(set) var idleMinutes = 10
    private(set) var idleIsEnabled = false
    private(set) var idleIsAvailable = false

    private let folderLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let chooseFolderButton = NSButton(title: "Choose Folder…", target: nil, action: nil)
    private let forgetFolderButton = NSButton(title: "Forget Folder…", target: nil, action: nil)
    private let ruleStack = NSStackView()
    private let recencyStepper = NSStepper()
    private let recencyLabel = NSTextField(labelWithString: "")
    private let idleCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let idleStepper = NSStepper()
    private let idleLabel = NSTextField(labelWithString: "")
    private let idleHintLabel = NSTextField(labelWithString: "")

    private var sidebarButtons: [PanelSidebarButton] = []
    private var pages: [String: NSView] = [:]
    private let pageContainer = NSView()

    private static let panelWidth: CGFloat = 720
    private static let panelHeight: CGFloat = 480
    private static var contentWidth: CGFloat {
        panelWidth - PanelTheme.sidebarWidth - PanelTheme.contentInset * 2
    }

    /// Section identifiers, shared with the sidebar catalog and reachable by
    /// name so a caller — or a snapshot — can open the panel on a given page.
    enum Section {
        static let overview = "overview"
        static let rules = "rules"
        static let automation = "automation"
    }

    static let catalog = PanelSectionCatalog(groups: [
        PanelSectionGroup(
            title: nil,
            sections: [
                PanelSection(
                    identifier: Section.overview, title: "Overview",
                    symbol: "folder.fill", tint: .systemBlue
                )
            ]
        ),
        PanelSectionGroup(
            title: "Tidying",
            sections: [
                PanelSection(
                    identifier: Section.rules, title: "Rules",
                    symbol: "list.bullet.rectangle", tint: .systemPurple
                ),
                PanelSection(
                    identifier: Section.automation, title: "Automation",
                    symbol: "clock.fill", tint: .systemTeal
                ),
            ]
        ),
    ])

    init() {
        super.init(
            autosaveName: "tidySettings",
            size: NSSize(width: Self.panelWidth, height: Self.panelHeight)
        )
        setUpContent()
        refresh()
    }

    // MARK: - Rendering

    func render(state: TidyCoordinator.State) {
        ruleSet = state.rules
        folder = state.folder
        blockingError = state.blockingError
        needsPreview = state.preferences.needsPreview
        recencyMinutes = max(state.preferences.recencyMinutes, 1)
        idleMinutes = max(state.preferences.idleMinutes, 1)
        idleIsAvailable = state.idleAvailable
        idleIsEnabled = state.preferences.idleEnabled && idleIsAvailable
        refresh()
    }

    func present(state: TidyCoordinator.State) {
        render(state: state)
        presentPanel()
    }

    // MARK: - Read-back for callers and tests

    var rules: [TidyRule] { ruleSet.rules }
    var ruleRowNames: [String] { ruleSet.rules.map(\.name) }
    var ruleRowDestinations: [String] { ruleSet.rules.map(\.destination) }
    var ruleRowSummaries: [String] { ruleSet.rules.map(TidyRuleSummary.text(for:)) }
    var folderSummary: String { folderLabel.stringValue }
    var statusText: String { statusLabel.stringValue }
    var canForgetFolder: Bool { folder != nil }

    // MARK: - Rule edits
    //
    // Every one of these reports the *whole* reordered set rather than a delta:
    // the coordinator persists rules as one document and reinstates the preview
    // gate on any change, and a partial update would be a way to skip that gate.

    func moveRule(at index: Int, by offset: Int) {
        let destination = index + offset
        guard ruleSet.rules.indices.contains(index),
              ruleSet.rules.indices.contains(destination) else { return }
        ruleSet.rules.swapAt(index, destination)
        reportRules()
    }

    func removeRule(at index: Int) {
        guard ruleSet.rules.indices.contains(index) else { return }
        ruleSet.rules.remove(at: index)
        reportRules()
    }

    func setRuleEnabled(_ isEnabled: Bool, at index: Int) {
        guard ruleSet.rules.indices.contains(index) else { return }
        ruleSet.rules[index].isEnabled = isEnabled
        reportRules()
    }

    /// Replaces a rule the editor handed back, matched by identity so a
    /// reordering between opening the editor and saving cannot move the edit
    /// onto a different rule.
    func replaceRule(_ rule: TidyRule) {
        guard let index = ruleSet.rules.firstIndex(where: { $0.id == rule.id }) else {
            ruleSet.rules.append(rule)
            reportRules()
            return
        }
        ruleSet.rules[index] = rule
        reportRules()
    }

    func editRule(at index: Int) {
        guard ruleSet.rules.indices.contains(index) else { return }
        onEditRule?(ruleSet.rules[index])
    }

    /// Adding a rule is the delegate's job — it owns the editor panel, and a
    /// half-built rule must not reach the stored set on the way there.
    func addRule() {
        onAddRule?()
    }

    func chooseFolder() {
        onChooseFolder?()
    }

    func forgetFolder() {
        guard canForgetFolder else { return }
        onForgetFolder?()
    }

    func setRecencyMinutes(_ minutes: Int) {
        recencyMinutes = max(minutes, 1)
        refreshAutomation()
        onRecencyChanged?(recencyMinutes)
    }

    func setIdleMinutes(_ minutes: Int) {
        idleMinutes = max(minutes, 1)
        refreshAutomation()
        onIdleMinutesChanged?(idleMinutes)
    }

    /// Idle tidying cannot be switched on before one reviewed manual pass has
    /// succeeded, so the control refuses rather than reporting a change the
    /// coordinator would have to reject.
    func setIdleEnabled(_ isEnabled: Bool) {
        guard idleIsAvailable else {
            idleIsEnabled = false
            refreshAutomation()
            return
        }
        idleIsEnabled = isEnabled
        refreshAutomation()
        onIdleChanged?(isEnabled)
    }

    private func reportRules() {
        rebuildRuleRows()
        onRulesChanged?(ruleSet)
    }

    // MARK: - Layout

    private func setUpContent() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let row = NSStackView(views: [makeSidebar(), divider, makeDetail()])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = 0

        installChrome(around: row)
        showSection(Section.overview)
    }

    private func makeSidebar() -> NSView {
        var views: [NSView] = []
        for group in Self.catalog.groups {
            if let title = group.title {
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
        stack.edgeInsets = NSEdgeInsets(
            top: PanelTheme.titleBarInset, left: 12, bottom: 12, right: 12
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        for button in sidebarButtons {
            button.widthAnchor.constraint(
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
            Section.overview: overviewPage(),
            Section.rules: rulesPage(),
            Section.automation: automationPage(),
        ]
        pageContainer.translatesAutoresizingMaskIntoConstraints = false

        let container = PanelSurfaceView()
        container.fill = PanelTheme.contentBackground
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

    private func overviewPage() -> NSView {
        folderLabel.font = .systemFont(ofSize: 13, weight: .medium)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setAccessibilityLabel("Folder Jumba tidies")

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        let statusWidth = Self.contentWidth - PanelTheme.cardInset * 2
        statusLabel.preferredMaxLayoutWidth = statusWidth
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(equalToConstant: statusWidth).isActive = true

        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolderClicked)
        forgetFolderButton.target = self
        forgetFolderButton.action = #selector(forgetFolderClicked)

        let buttons = NSStackView(views: [chooseFolderButton, forgetFolderButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        return page([
            PanelTheme.sectionHeader("Folder"),
            PanelTheme.subtitle(
                "Tidy only ever touches the one folder you choose, only its immediate "
                    + "contents, and only files a rule matches.",
                width: Self.contentWidth
            ),
            PanelBuilder.card([folderLabel, buttons, statusLabel], width: Self.contentWidth),
        ])
    }

    private func rulesPage() -> NSView {
        ruleStack.orientation = .vertical
        ruleStack.alignment = .leading
        ruleStack.spacing = PanelTheme.rowSpacing

        let addButton = NSButton(title: "Add Rule…", target: self, action: #selector(addRuleClicked))

        return page([
            PanelTheme.sectionHeader("Rules"),
            PanelTheme.subtitle(
                "Rules are checked from the top down and the first match wins. "
                    + "Files no rule matches are left exactly where they are.",
                width: Self.contentWidth
            ),
            PanelBuilder.card([ruleStack], width: Self.contentWidth),
            addButton,
        ])
    }

    private func automationPage() -> NSView {
        recencyStepper.minValue = 1
        recencyStepper.maxValue = 240
        recencyStepper.increment = 1
        recencyStepper.valueWraps = false
        recencyStepper.target = self
        recencyStepper.action = #selector(recencyStepped)
        recencyStepper.setAccessibilityLabel("Leave files newer than, in minutes")
        recencyLabel.font = .systemFont(ofSize: 13)

        idleStepper.minValue = 1
        idleStepper.maxValue = 240
        idleStepper.increment = 1
        idleStepper.valueWraps = false
        idleStepper.target = self
        idleStepper.action = #selector(idleStepped)
        idleStepper.setAccessibilityLabel("Idle for, in minutes")
        idleLabel.font = .systemFont(ofSize: 13)

        idleCheckbox.target = self
        idleCheckbox.action = #selector(idleToggled)

        idleHintLabel.font = .systemFont(ofSize: 11)
        idleHintLabel.textColor = .secondaryLabelColor
        idleHintLabel.maximumNumberOfLines = 3
        let hintWidth = Self.contentWidth - PanelTheme.cardInset * 2
        idleHintLabel.preferredMaxLayoutWidth = hintWidth
        idleHintLabel.translatesAutoresizingMaskIntoConstraints = false
        idleHintLabel.widthAnchor.constraint(equalToConstant: hintWidth).isActive = true

        let recencyRow = NSStackView(views: [recencyLabel, recencyStepper])
        recencyRow.orientation = .horizontal
        recencyRow.spacing = 8

        let idleRow = NSStackView(views: [idleLabel, idleStepper])
        idleRow.orientation = .horizontal
        idleRow.spacing = 8

        return page([
            PanelTheme.sectionHeader("Safety"),
            PanelBuilder.card([recencyRow], width: Self.contentWidth),
            PanelTheme.sectionHeader("While you are away"),
            PanelBuilder.card(
                [
                    PanelBuilder.checkRow(
                        idleCheckbox, title: "Tidy while idle",
                        detail: "Off until you have watched one tidy through yourself.",
                        width: Self.contentWidth
                    ),
                    idleRow,
                    idleHintLabel,
                ],
                width: Self.contentWidth
            ),
        ])
    }

    // MARK: - Selection

    func showSection(_ identifier: String) {
        for button in sidebarButtons {
            button.isSelectedRow = button.identifier?.rawValue == identifier
        }
        pageContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let page = pages[identifier] else { return }
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

    // MARK: - Refresh

    private func refresh() {
        folderLabel.stringValue = folder?.path ?? "No folder chosen yet."
        forgetFolderButton.isEnabled = canForgetFolder
        chooseFolderButton.title = folder == nil ? "Choose Folder…" : "Choose Another Folder…"
        statusLabel.stringValue = statusMessage()
        statusLabel.textColor = blockingError == nil ? .secondaryLabelColor : .systemRed
        rebuildRuleRows()
        refreshAutomation()
    }

    private func statusMessage() -> String {
        if let blockingError { return blockingError }
        if folder == nil { return "Choose a folder to let Jumba tidy it." }
        if needsPreview { return "Jumba will show you a preview before anything moves." }
        return "Jumba is ready to tidy this folder."
    }

    private func refreshAutomation() {
        recencyStepper.integerValue = recencyMinutes
        recencyLabel.stringValue = "Leave files changed in the last "
            + "\(recencyMinutes) minute\(recencyMinutes == 1 ? "" : "s")"
        idleStepper.integerValue = idleMinutes
        idleStepper.isEnabled = idleIsAvailable
        idleLabel.stringValue = "Wait until you have been away for "
            + "\(idleMinutes) minute\(idleMinutes == 1 ? "" : "s")"
        idleCheckbox.state = idleIsEnabled ? .on : .off
        idleCheckbox.isEnabled = idleIsAvailable
        idleHintLabel.stringValue = idleIsAvailable
            ? "Coming back stops Jumba after the file being moved, never during one."
            : "Run one tidy yourself first — idle tidying unlocks after that."
    }

    private func rebuildRuleRows() {
        ruleStack.arrangedSubviews.forEach {
            ruleStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !ruleSet.rules.isEmpty else {
            ruleStack.addArrangedSubview(
                PanelTheme.title("No rules yet — add one to tell Jumba what to move.", size: 12)
            )
            return
        }
        for (index, rule) in ruleSet.rules.enumerated() {
            ruleStack.addArrangedSubview(ruleRow(for: rule, at: index))
        }
    }

    private func ruleRow(for rule: TidyRule, at index: Int) -> NSView {
        let enabled = NSButton(checkboxWithTitle: "", target: self, action: #selector(ruleToggled(_:)))
        enabled.tag = index
        enabled.state = rule.isEnabled ? .on : .off
        enabled.setAccessibilityLabel("Use the rule \(rule.name)")

        let title = PanelTheme.title(rule.name, size: 13, weight: .medium)
        let arrow = PanelTheme.title("→ \(rule.destination)", size: 12)
        arrow.textColor = .secondaryLabelColor
        arrow.setAccessibilityLabel("Moves into \(rule.destination)")

        let summary = PanelTheme.title(TidyRuleSummary.text(for: rule), size: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail

        let heading = NSStackView(views: [title, arrow])
        heading.orientation = .horizontal
        heading.spacing = 6

        let text = NSStackView(views: [heading, summary])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let controls = [
            symbolButton("chevron.up", label: "Move \(rule.name) up", action: #selector(ruleMovedUp(_:)), tag: index),
            symbolButton("chevron.down", label: "Move \(rule.name) down", action: #selector(ruleMovedDown(_:)), tag: index),
        ]
        let edit = NSButton(title: "Edit", target: self, action: #selector(ruleEdited(_:)))
        edit.tag = index
        edit.controlSize = .small
        edit.setAccessibilityLabel("Edit the rule \(rule.name)")
        let remove = NSButton(title: "Remove", target: self, action: #selector(ruleRemoved(_:)))
        remove.tag = index
        remove.controlSize = .small
        remove.setAccessibilityLabel("Remove the rule \(rule.name)")

        let row = NSStackView(views: [enabled, text, NSView()] + controls + [edit, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(
            equalToConstant: Self.contentWidth - PanelTheme.cardInset * 2
        ).isActive = true
        return row
    }

    private func symbolButton(
        _ symbol: String, label: String, action: Selector, tag: Int
    ) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                ?? NSImage(size: NSSize(width: 12, height: 12)),
            target: self,
            action: action
        )
        button.tag = tag
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel(label)
        return button
    }

    // MARK: - Actions

    @objc private func sidebarClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        showSection(identifier)
    }

    @objc private func chooseFolderClicked() {
        chooseFolder()
    }

    @objc private func forgetFolderClicked() {
        forgetFolder()
    }

    @objc private func addRuleClicked() {
        addRule()
    }

    @objc private func ruleToggled(_ sender: NSButton) {
        setRuleEnabled(sender.state == .on, at: sender.tag)
    }

    @objc private func ruleMovedUp(_ sender: NSButton) {
        moveRule(at: sender.tag, by: -1)
    }

    @objc private func ruleMovedDown(_ sender: NSButton) {
        moveRule(at: sender.tag, by: 1)
    }

    @objc private func ruleEdited(_ sender: NSButton) {
        editRule(at: sender.tag)
    }

    @objc private func ruleRemoved(_ sender: NSButton) {
        removeRule(at: sender.tag)
    }

    @objc private func recencyStepped() {
        setRecencyMinutes(recencyStepper.integerValue)
    }

    @objc private func idleStepped() {
        setIdleMinutes(idleStepper.integerValue)
    }

    @objc private func idleToggled() {
        setIdleEnabled(idleCheckbox.state == .on)
    }
}
