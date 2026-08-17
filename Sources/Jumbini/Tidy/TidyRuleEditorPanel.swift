import AppKit

/// The five things a condition can ask about, as a plain list.
///
/// `TidyCondition` carries its value with it, which is right for matching and
/// wrong for a popup: the editor has to name the *type* before it knows the
/// value. This is that name.
enum TidyConditionKind: String, CaseIterable, Equatable {
    case kind, filenameContains, extensions, modifiedMoreThanDays, largerThanMB

    var displayName: String {
        switch self {
        case .kind: return "Kind is"
        case .filenameContains: return "Name contains"
        case .extensions: return "Extension is one of"
        case .modifiedMoreThanDays: return "Older than (days)"
        case .largerThanMB: return "Larger than (MB)"
        }
    }

    var placeholder: String? {
        switch self {
        case .kind: return nil
        case .filenameContains: return "invoice"
        case .extensions: return "dmg, pkg"
        case .modifiedMoreThanDays: return "30"
        case .largerThanMB: return "2.5"
        }
    }

    static func of(_ condition: TidyCondition) -> TidyConditionKind {
        switch condition {
        case .kind: return .kind
        case .filenameContains: return .filenameContains
        case .extensions: return .extensions
        case .modifiedMoreThanDays: return .modifiedMoreThanDays
        case .largerThanMB: return .largerThanMB
        }
    }
}

/// One rule, editable: a name, all/any, a destination folder, and the conditions.
///
/// The editor holds a draft and never writes anywhere. Save validates the draft
/// against the same destination rule the planner enforces — a destination this
/// panel accepted but the planner rejected would fail the *whole* next plan, so
/// the check has to be the planner's own, not a second opinion.
final class TidyRuleEditorPanel: JumbiniPanel {
    var onSave: ((TidyRule) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var validationMessage: String?

    private var editingRule = TidyRule(
        name: "", match: .all, conditions: [], destination: ""
    )
    private var conditionKinds: [TidyConditionKind] = []
    private var conditionTexts: [String] = []
    private var conditionValues: [TidyKind] = []

    private let nameField = NSTextField(string: "")
    private let matchPopup = NSPopUpButton()
    private let destinationField = NSTextField(string: "")
    private let conditionStack = NSStackView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private static let panelWidth: CGFloat = 460
    private static let initialHeight: CGFloat = 460
    private static let contentInset: CGFloat = 16
    private static var cardWidth: CGFloat { panelWidth - contentInset * 2 }

    private static let matchTitles = ["All conditions", "Any condition"]

    init() {
        super.init(
            autosaveName: "tidyRuleEditor",
            size: NSSize(width: Self.panelWidth, height: Self.initialHeight)
        )
        setUpContent()
    }

    // MARK: - Loading

    func edit(_ rule: TidyRule) {
        editingRule = rule
        conditionKinds = rule.conditions.map(TidyConditionKind.of)
        conditionTexts = rule.conditions.map(Self.text(for:))
        conditionValues = rule.conditions.map { condition in
            if case .kind(let kind) = condition { return kind }
            return .image
        }
        validationMessage = nil
        nameField.stringValue = rule.name
        destinationField.stringValue = rule.destination
        matchPopup.selectItem(at: rule.match == .all ? 0 : 1)
        refresh()
    }

    func present(_ rule: TidyRule) {
        edit(rule)
        presentPanel()
    }

    /// A brand-new rule starts from the same shape the presets use, so the
    /// editor never opens on an empty form that cannot be saved.
    static func newRule() -> TidyRule {
        TidyRule(name: "New rule", match: .all, conditions: [.kind(.image)], destination: "Images")
    }

    // MARK: - Draft

    var draft: TidyRule {
        var rule = editingRule
        rule.name = nameField.stringValue
        rule.destination = destinationField.stringValue
        rule.match = matchPopup.indexOfSelectedItem == 1 ? .any : .all
        rule.conditions = conditionKinds.indices.map(condition(at:))
        return rule
    }

    var matchModeTitles: [String] { Self.matchTitles }
    var selectedMatchTitle: String { matchPopup.titleOfSelectedItem ?? "" }

    func conditionFieldText(at index: Int) -> String {
        conditionTexts.indices.contains(index) ? conditionTexts[index] : ""
    }

    func conditionKindTitles(at index: Int) -> [String] {
        guard conditionKinds.indices.contains(index), conditionKinds[index] == .kind else {
            return []
        }
        return TidyKind.allCases.map(\.displayName)
    }

    // MARK: - Editing

    func setName(_ name: String) {
        nameField.stringValue = name
    }

    func setDestination(_ destination: String) {
        destinationField.stringValue = destination
    }

    func setMatchMode(_ mode: TidyMatchMode) {
        matchPopup.selectItem(at: mode == .all ? 0 : 1)
    }

    func setConditionType(_ type: TidyConditionKind, at index: Int) {
        guard conditionKinds.indices.contains(index), conditionKinds[index] != type else { return }
        conditionKinds[index] = type
        conditionTexts[index] = ""
        refresh()
    }

    func setConditionText(_ text: String, at index: Int) {
        guard conditionTexts.indices.contains(index) else { return }
        conditionTexts[index] = text
        refresh()
    }

    func setConditionKind(_ kind: TidyKind, at index: Int) {
        guard conditionValues.indices.contains(index) else { return }
        conditionValues[index] = kind
        refresh()
    }

    func addCondition() {
        conditionKinds.append(.kind)
        conditionTexts.append("")
        conditionValues.append(.image)
        refresh()
    }

    func removeCondition(at index: Int) {
        guard conditionKinds.indices.contains(index) else { return }
        conditionKinds.remove(at: index)
        conditionTexts.remove(at: index)
        conditionValues.remove(at: index)
        refresh()
    }

    // MARK: - Save and cancel

    func save() {
        let rule = draft
        if let problem = Self.problem(with: rule) {
            validationMessage = problem
            refresh()
            return
        }
        validationMessage = nil
        refresh()
        onSave?(rule)
    }

    func cancel() {
        onCancel?()
    }

    /// The first thing wrong with a rule, or nil. Pure so the wording and the
    /// order of the checks are testable without a window.
    static func problem(with rule: TidyRule) -> String? {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Give the rule a name."
        }
        guard !rule.conditions.isEmpty else {
            return "Add at least one condition."
        }
        for condition in rule.conditions {
            switch condition {
            case .kind:
                continue
            case .filenameContains(let value):
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "Fill in every condition."
                }
            case .extensions(let values):
                if values.isEmpty {
                    return "Fill in every condition."
                }
            case .modifiedMoreThanDays(let days):
                if days <= 0 {
                    return "Every threshold must be greater than zero."
                }
            case .largerThanMB(let megabytes):
                if megabytes <= 0 {
                    return "Every threshold must be greater than zero."
                }
            }
        }
        do {
            try TidyPlanner.validateDestination(rule.destination)
        } catch {
            return "Use one folder name inside the chosen folder — no slashes and no leading dot."
        }
        return nil
    }

    // MARK: - Condition conversion

    private func condition(at index: Int) -> TidyCondition {
        let text = conditionTexts[index]
        switch conditionKinds[index] {
        case .kind:
            return .kind(conditionValues[index])
        case .filenameContains:
            return .filenameContains(text)
        case .extensions:
            return .extensions(Self.extensions(from: text))
        case .modifiedMoreThanDays:
            return .modifiedMoreThanDays(Int(text.trimmingCharacters(in: .whitespaces)) ?? 0)
        case .largerThanMB:
            return .largerThanMB(Double(text.trimmingCharacters(in: .whitespaces)) ?? 0)
        }
    }

    /// "ZIP , .tar" is what people type; ["zip", "tar"] is what matching wants.
    private static func extensions(from text: String) -> [String] {
        text.split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
            }
            .filter { !$0.isEmpty }
    }

    private static func text(for condition: TidyCondition) -> String {
        switch condition {
        case .kind:
            return ""
        case .filenameContains(let value):
            return value
        case .extensions(let values):
            return values.joined(separator: ", ")
        case .modifiedMoreThanDays(let days):
            return String(days)
        case .largerThanMB(let megabytes):
            return TidyRuleSummary.formatted(megabytes)
        }
    }

    // MARK: - Layout

    private func setUpContent() {
        let title = NSTextField(labelWithString: "Rule")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        nameField.placeholderString = "Screenshots"
        nameField.setAccessibilityLabel("Rule name")
        constrainWidth(nameField)

        destinationField.placeholderString = "Screenshots"
        destinationField.setAccessibilityLabel("Destination folder name")
        constrainWidth(destinationField)

        for item in Self.matchTitles {
            matchPopup.addItem(withTitle: item)
        }
        matchPopup.setAccessibilityLabel("Match all or any condition")

        conditionStack.orientation = .vertical
        conditionStack.alignment = .leading
        conditionStack.spacing = 6

        let addButton = NSButton(
            title: "Add Condition", target: self, action: #selector(addConditionClicked)
        )
        addButton.controlSize = .small

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .systemRed
        messageLabel.maximumNumberOfLines = 3
        messageLabel.preferredMaxLayoutWidth = Self.cardWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true

        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        let footer = NSStackView(views: [cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [
            title,
            PanelTheme.sectionHeader("Name"),
            PanelBuilder.card([nameField], width: Self.cardWidth),
            PanelTheme.sectionHeader("Conditions"),
            PanelBuilder.card([matchPopup, conditionStack, addButton], width: Self.cardWidth),
            PanelTheme.sectionHeader("Move into"),
            PanelBuilder.card([destinationField], width: Self.cardWidth),
            messageLabel,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: PanelTheme.titleBarInset, left: Self.contentInset,
            bottom: Self.contentInset, right: Self.contentInset
        )

        installChrome(around: stack)
        refresh()
    }

    private func constrainWidth(_ field: NSTextField) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(
            equalToConstant: Self.cardWidth - PanelTheme.cardInset * 2
        ).isActive = true
    }

    private func refresh() {
        messageLabel.stringValue = validationMessage ?? ""
        messageLabel.isHidden = validationMessage == nil
        rebuildConditionRows()
    }

    private func rebuildConditionRows() {
        conditionStack.arrangedSubviews.forEach {
            conditionStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for index in conditionKinds.indices {
            conditionStack.addArrangedSubview(conditionRow(at: index))
        }
    }

    private func conditionRow(at index: Int) -> NSView {
        let typePopup = NSPopUpButton()
        for type in TidyConditionKind.allCases {
            typePopup.addItem(withTitle: type.displayName)
        }
        typePopup.selectItem(at: TidyConditionKind.allCases.firstIndex(of: conditionKinds[index]) ?? 0)
        typePopup.target = self
        typePopup.action = #selector(conditionTypeChanged(_:))
        typePopup.tag = index
        typePopup.setAccessibilityLabel("Condition \(index + 1) type")

        let value: NSView
        if conditionKinds[index] == .kind {
            let kindPopup = NSPopUpButton()
            for kind in TidyKind.allCases {
                kindPopup.addItem(withTitle: kind.displayName)
            }
            kindPopup.selectItem(at: TidyKind.allCases.firstIndex(of: conditionValues[index]) ?? 0)
            kindPopup.target = self
            kindPopup.action = #selector(conditionKindChanged(_:))
            kindPopup.tag = index
            kindPopup.setAccessibilityLabel("Condition \(index + 1) kind")
            value = kindPopup
        } else {
            let field = NSTextField(string: conditionTexts[index])
            field.placeholderString = conditionKinds[index].placeholder
            field.target = self
            field.action = #selector(conditionTextChanged(_:))
            field.tag = index
            field.setAccessibilityLabel("Condition \(index + 1) value")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
            value = field
        }

        let remove = NSButton(title: "−", target: self, action: #selector(conditionRemoved(_:)))
        remove.tag = index
        remove.controlSize = .small
        remove.setAccessibilityLabel("Remove condition \(index + 1)")

        let row = NSStackView(views: [typePopup, value, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    // MARK: - Actions

    @objc private func conditionTypeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard TidyConditionKind.allCases.indices.contains(index) else { return }
        setConditionType(TidyConditionKind.allCases[index], at: sender.tag)
    }

    @objc private func conditionKindChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard TidyKind.allCases.indices.contains(index) else { return }
        setConditionKind(TidyKind.allCases[index], at: sender.tag)
    }

    @objc private func conditionTextChanged(_ sender: NSTextField) {
        setConditionText(sender.stringValue, at: sender.tag)
    }

    @objc private func conditionRemoved(_ sender: NSButton) {
        removeCondition(at: sender.tag)
    }

    @objc private func addConditionClicked() {
        addCondition()
    }

    @objc private func saveClicked() {
        save()
    }

    @objc private func cancelClicked() {
        cancel()
    }
}
