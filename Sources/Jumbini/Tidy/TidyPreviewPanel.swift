import AppKit

extension TidySkipReason {
    /// Why a file is staying put, in the words the person reading the preview
    /// would use. Skips are not failures, and the preview says so plainly rather
    /// than leaving a row unexplained.
    var displayText: String {
        switch self {
        case .unmatched: return "No rule matched"
        case .recent: return "Changed too recently"
        case .alias: return "Alias"
        case .symbolicLink: return "Symbolic link"
        case .ordinaryDirectory: return "Folder"
        case .openByAnotherProcess: return "Open in another app"
        case .unreadableMetadata: return "Could not read it"
        }
    }
}

/// Every move Tidy proposes, with both full paths, before anything moves.
///
/// This panel is the safety gate the whole feature is built around, so it makes
/// two promises in code rather than in prose: it never writes anything, and it
/// confirms exactly the rows still ticked — a row the user unticks is not passed
/// to the executor at all, and a skipped row can never be ticked in the first
/// place.
final class TidyPreviewPanel: JumbiniPanel {
    var onConfirm: ((Set<UUID>) -> Void)?
    var onCancel: (() -> Void)?

    private var plan: TidyPlan?
    private var selection: Set<UUID> = []
    private var checkboxes: [UUID: NSButton] = [:]

    private let headerLabel = NSTextField(labelWithString: "Tidy preview")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let capLabel = NSTextField(labelWithString: "")
    private let rowStack = NSStackView()
    private let confirmButton = NSButton(title: "Let Jumba tidy", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private(set) var rowAccessibilityLabels: [String] = []
    private(set) var sourcePathTexts: [String] = []
    private(set) var destinationPathTexts: [String] = []
    private(set) var skipReasonTexts: [String] = []

    private static let panelWidth: CGFloat = 640
    private static let panelHeight: CGFloat = 520
    private static let contentInset: CGFloat = 16
    private static var rowWidth: CGFloat { panelWidth - contentInset * 2 }

    init() {
        super.init(
            autosaveName: "tidyPreview",
            size: NSSize(width: Self.panelWidth, height: Self.panelHeight)
        )
        setUpContent()
    }

    // MARK: - Presenting a plan

    func show(plan: TidyPlan) {
        self.plan = plan
        selection = Set(plan.movable.map(\.id))
        rebuildRows()
        refreshFooter()
    }

    func present(plan: TidyPlan) {
        show(plan: plan)
        presentPanel()
    }

    // MARK: - Selection

    var selectedIDs: Set<UUID> { selection }

    var canConfirm: Bool { !selection.isEmpty }

    var summaryText: String { summaryLabel.stringValue }

    /// Nil unless the plan is over the cap, so callers can tell "no message" from
    /// "a message that happens to be empty".
    var capMessage: String? {
        capLabel.isHidden ? nil : capLabel.stringValue
    }

    /// Only proposed moves can be selected. A skipped row's checkbox is disabled
    /// on screen, and this refuses the same thing in code so no caller can hand
    /// the executor an ID it never planned to move.
    func setSelected(_ isSelected: Bool, for id: UUID) {
        guard plan?.movable.contains(where: { $0.id == id }) == true else { return }
        if isSelected {
            selection.insert(id)
        } else {
            selection.remove(id)
        }
        checkboxes[id]?.state = isSelected ? .on : .off
        refreshFooter()
    }

    func confirmForTesting() {
        confirm()
    }

    func cancelForTesting() {
        cancel()
    }

    private func confirm() {
        onConfirm?(selection)
    }

    private func cancel() {
        onCancel?()
    }

    // MARK: - Layout

    private func setUpContent() {
        headerLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor

        capLabel.font = .systemFont(ofSize: 12, weight: .medium)
        capLabel.textColor = .systemOrange
        capLabel.isHidden = true

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 8
        rowStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        let scroll = PanelBuilder.scrollPane(around: rowStack)

        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked)
        confirmButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        let heading = NSStackView(views: [headerLabel, summaryLabel, capLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        heading.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [cancelButton, NSView(), confirmButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        // Explicit constraints rather than one tall stack: the list is the only
        // part that may grow, and it has to give way to the footer rather than
        // push it off the bottom of the window — which is exactly what a stack
        // sized to its content did, leaving the confirm button unreachable.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(heading)
        container.addSubview(scroll)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            container.heightAnchor.constraint(equalToConstant: Self.panelHeight),

            heading.topAnchor.constraint(
                equalTo: container.topAnchor, constant: PanelTheme.titleBarInset
            ),
            heading.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Self.contentInset
            ),
            heading.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.contentInset
            ),

            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            footer.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -Self.contentInset
            ),
        ])

        installChrome(around: container)
        refreshFooter()
    }

    private func rebuildRows() {
        rowStack.arrangedSubviews.forEach {
            rowStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        checkboxes = [:]
        rowAccessibilityLabels = []
        sourcePathTexts = []
        destinationPathTexts = []
        skipReasonTexts = []
        guard let plan else { return }

        for move in plan.movable {
            rowStack.addArrangedSubview(moveRow(for: move))
        }
        guard !plan.skipped.isEmpty else { return }
        let header = PanelTheme.sectionHeader("Staying put")
        rowStack.addArrangedSubview(header)
        for item in plan.skipped {
            rowStack.addArrangedSubview(skipRow(for: item))
        }
    }

    private func moveRow(for move: TidyPlannedMove) -> NSView {
        let label = "Move \(move.source.path) to \(move.destination.path)"
        rowAccessibilityLabels.append(label)
        sourcePathTexts.append(move.source.path)
        destinationPathTexts.append(move.destination.path)

        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(rowToggled(_:)))
        checkbox.state = .on
        checkbox.identifier = NSUserInterfaceItemIdentifier(move.id.uuidString)
        checkbox.setAccessibilityLabel(label)
        checkboxes[move.id] = checkbox

        let source = pathLabel(move.source.path)
        let destination = pathLabel(move.destination.path)
        destination.textColor = .secondaryLabelColor

        let rule = PanelTheme.title(move.ruleName, size: 11)
        rule.textColor = .tertiaryLabelColor

        let text = NSStackView(views: [source, destination, rule])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [checkbox, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.setAccessibilityLabel(label)
        return row
    }

    private func skipRow(for item: TidySkippedItem) -> NSView {
        skipReasonTexts.append(item.reason.displayText)

        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.state = .off
        checkbox.isEnabled = false

        let source = pathLabel(item.source.path)
        source.textColor = .secondaryLabelColor
        let reason = PanelTheme.title(item.reason.displayText, size: 11)
        reason.textColor = .tertiaryLabelColor

        let text = NSStackView(views: [source, reason])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [checkbox, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.setAccessibilityLabel("\(item.source.path) stays put — \(item.reason.displayText)")
        return row
    }

    /// Selectable and wrapping rather than truncating: a middle-truncated path is
    /// exactly the case where two files look identical, and this is the screen
    /// where telling them apart matters.
    private func pathLabel(_ path: String) -> NSTextField {
        let label = NSTextField(labelWithString: path)
        label.font = .systemFont(ofSize: 12)
        label.isSelectable = true
        label.usesSingleLineMode = false
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = Self.rowWidth - 40
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.rowWidth - 40
        ).isActive = true
        return label
    }

    private func refreshFooter() {
        let movable = plan?.movable.count ?? 0
        summaryLabel.stringValue = movable == 0
            ? "Nothing to tidy in this folder."
            : "\(movable) file\(movable == 1 ? "" : "s") ready to move · \(selection.count) selected"
        capLabel.stringValue =
            "Jumba will stop after \(TidySafety.maximumMoves) files for safety."
        capLabel.isHidden = plan?.exceedsCap != true
        confirmButton.isEnabled = canConfirm
    }

    // MARK: - Actions

    @objc private func rowToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        setSelected(sender.state == .on, for: id)
    }

    @objc private func confirmClicked() {
        confirm()
    }

    @objc private func cancelClicked() {
        cancel()
    }
}
