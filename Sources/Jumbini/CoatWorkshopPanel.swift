import AppKit
import UniformTypeIdentifiers
import SpriteKit

/// The Coat Workshop panel: import, validate, preview, adjust, install, and
/// export custom dog coats without touching Application Support by hand.
///
/// A borderless, non-activating NSPanel like the DogGeneratorPanel. It owns
/// none of the rendering — it sends pose/direction commands to the scene so
/// the preview happens on the real dog in the overlay.
@MainActor
final class CoatWorkshopPanel: JumbiniPanel {
    // MARK: - Closures (wired by the scene)

    /// Ask the scene to temporarily wear a staged coat.
    var setPreviewCoat: ((Coat) -> Void)?
    /// Ask the scene to show a specific pose and direction.
    var setPreviewPose: ((String, Facing) -> Void)?
    /// Ask the scene to restore the coat it was wearing before preview.
    var restoreCoat: (() -> Void)?
    /// Install was clicked: the scene should install and select the coat.
    var onInstall: ((String) -> Void)?
    /// Export source (installed coat folder, or staging folder).
    var exportSource: URL?

    // MARK: - Private state

    private var stagingURL: URL?
    private var report: CoatValidationReport?
    private var isPreviewing = false
    private var selectedState: String = "idle"
    private var selectedDirection: Facing = .south
    private var scaleEdits: [String: CGFloat] = [:]
    /// Findings about the archive itself, which `CoatValidator.validate` never
    /// sees because it is handed a folder. Shown alongside the report.
    private var archiveFindings: [ValidationFinding] = []
    private let fileManager: FileManager

    // MARK: - UI elements

    private let importButton = NSButton(title: "Import Coat…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let findingsScroll = NSScrollView()
    private let findingsTextView = NSTextView()
    /// The Validation header and its card, kept so the whole section can come
    /// and go together. Hiding only the scroll view inside left a labelled but
    /// empty box on screen — a rounded sliver under the word VALIDATION, which
    /// reads as something that failed to load rather than something not
    /// applicable yet.
    private let validationHeader = PanelTheme.sectionHeader("Validation")
    private var validationCard: NSView?
    /// The content stack, so the window can be re-measured when a section is
    /// shown or hidden. Nothing else resizes it, so a shown section would
    /// otherwise be clipped by a window still sized for the layout without it.
    private weak var contentStack: NSStackView?
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let statePopup = NSPopUpButton()
    private let directionControl = NSSegmentedControl()
    private let scaleStack = NSStackView()
    private let installButton = NSButton(title: "Install", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private var isInstalledCoat: Bool = false

    private static let panelWidth: CGFloat = 400
    private static let initialHeight: CGFloat = 520
    private static let contentInset: CGFloat = 16
    private static let scaleFieldPrefix = "scale:"
    private static let resetButtonPrefix = "reset:"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        super.init(
            autosaveName: "coatWorkshop",
            size: NSSize(width: Self.panelWidth, height: Self.initialHeight)
        )
        setUpContent()
    }

    // MARK: - Content layout

    private func setUpContent() {
        let title = NSTextField(labelWithString: "Coat Workshop")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [title])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(
            equalToConstant: Self.panelWidth - Self.contentInset * 2
        ).isActive = true

        // Import row.
        importButton.target = self
        importButton.action = #selector(doImport)
        let importRow = NSStackView(views: [importButton, exportButton])
        importRow.orientation = .horizontal
        importRow.spacing = 8
        exportButton.target = self
        exportButton.action = #selector(doExport)
        exportButton.isEnabled = false

        // Status.
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = Self.panelWidth - Self.contentInset * 2
        statusLabel.stringValue = "Import a coat folder or zip to validate and preview."
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        // Findings.
        findingsTextView.isEditable = false
        findingsTextView.isSelectable = true
        findingsTextView.drawsBackground = false
        findingsTextView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        findingsTextView.textContainerInset = NSSize(width: 4, height: 4)
        findingsScroll.documentView = findingsTextView
        findingsScroll.hasVerticalScroller = true
        findingsScroll.borderType = .noBorder
        findingsScroll.drawsBackground = false
        findingsScroll.translatesAutoresizingMaskIntoConstraints = false
        findingsScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        findingsScroll.isHidden = true

        // Preview controls.
        previewButton.target = self
        previewButton.action = #selector(togglePreview)
        previewButton.isEnabled = false

        statePopup.target = self
        statePopup.action = #selector(stateChanged)
        for state in FullCoatState.allCases {
            statePopup.addItem(withTitle: state.rawValue)
        }
        statePopup.isEnabled = false

        // One control rather than eight buttons: a segmented control in
        // `.selectOne` mode draws the selected segment, which is the whole
        // point of the row — momentary push buttons never show their state.
        directionControl.segmentStyle = .rounded
        directionControl.trackingMode = .selectOne
        directionControl.controlSize = .small
        directionControl.font = .systemFont(ofSize: 9)
        directionControl.segmentCount = Facing.coatDirections.count
        directionControl.target = self
        directionControl.action = #selector(directionChosen(_:))
        directionControl.isEnabled = false
        // AppKit has no per-segment accessibility label, so the spelled-out
        // direction rides on the tooltip — which VoiceOver reads as help — and
        // the control names the row as a whole.
        directionControl.setAccessibilityLabel("Preview direction")
        directionControl.setAccessibilityRoleDescription("direction picker")
        for (index, dir) in Facing.coatDirections.enumerated() {
            directionControl.setLabel(directionShortLabel(dir), forSegment: index)
            directionControl.setWidth(32, forSegment: index)
            directionControl.setToolTip(directionName(dir), forSegment: index)
        }
        updateDirectionControl()

        let directionRow = NSStackView(views: [directionControl])
        directionRow.orientation = .horizontal
        directionRow.spacing = 4

        let previewRow = NSStackView(views: [previewButton, statePopup])
        previewRow.orientation = .horizontal
        previewRow.spacing = 8

        // Scale adjustment.
        scaleStack.orientation = .vertical
        scaleStack.spacing = 4
        scaleStack.isHidden = true

        // Install row.
        installButton.target = self
        installButton.action = #selector(doInstall)
        installButton.isEnabled = false
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"

        // Grouped into the same labelled cards Settings uses, so the three
        // panels read as one app rather than three separately-built windows.
        let cardWidth = Self.panelWidth - Self.contentInset * 2
        let findingsCard = PanelBuilder.card([findingsScroll], width: cardWidth)
        validationCard = findingsCard
        let stack = NSStackView(views: [
            header,
            PanelTheme.sectionHeader("Coat file"),
            PanelBuilder.card([importRow, statusLabel], width: cardWidth),
            validationHeader,
            findingsCard,
            PanelTheme.sectionHeader("Preview"),
            PanelBuilder.card([previewRow, directionRow, scaleStack], width: cardWidth),
            installButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // Top inset clears the title bar rather than matching the sides: these
        // panels have real traffic lights now, and the header would otherwise
        // be laid out underneath them.
        stack.edgeInsets = NSEdgeInsets(
            top: PanelTheme.titleBarInset, left: Self.contentInset,
            bottom: Self.contentInset, right: Self.contentInset
        )

        contentStack = stack
        showValidation(false)

        stack.layoutSubtreeIfNeeded()
        let fittedHeight = stack.fittingSize.height

        installChrome(around: stack)
        setContentSize(NSSize(width: Self.panelWidth, height: fittedHeight))
    }

    /// Show or hide the Validation section as a whole, and resize the window to
    /// whatever the layout now needs.
    private func showValidation(_ visible: Bool) {
        findingsScroll.isHidden = !visible
        validationHeader.isHidden = !visible
        validationCard?.isHidden = !visible
        // Only once the stack is in the window. During setUp it is still a
        // loose view and setUpContent does the sizing itself a few lines later.
        guard let stack = contentStack, stack.superview != nil else { return }
        stack.layoutSubtreeIfNeeded()
        let fitted = stack.fittingSize.height
        guard fitted > 1 else { return }
        setContentSize(NSSize(width: Self.panelWidth, height: fitted))
    }


    // MARK: - Import

    @objc private func doImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose a coat folder or zip archive."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        clearPreview()

        do {
            let staging = try createStagingDirectory()
            let coatFolder: URL

            if url.pathExtension.lowercased() == "zip" {
                coatFolder = try importZip(from: url, to: staging)
            } else {
                coatFolder = try importFolder(from: url, to: staging)
            }

            stagingURL = coatFolder
            let result = CoatValidator.validate(folder: coatFolder, fileManager: fileManager)
            report = result
            scaleEdits = result.scales

            displayReport(result)
            exportButton.isEnabled = true
            exportSource = coatFolder
            isInstalledCoat = false
            installButton.isEnabled = result.canInstall
            previewButton.isEnabled = true
            installButton.title = "Install"
        } catch {
            statusLabel.stringValue = "Import failed: \(error.localizedDescription)"
        }
    }

    private func importZip(from url: URL, to staging: URL) throws -> URL {
        statusLabel.stringValue = "Checking archive…"

        let entries = try CoatValidator.listZipContents(at: url)
        let safetyFindings = CoatValidator.checkZipSafety(entries)

        if safetyFindings.contains(where: { $0.severity == .error }) {
            let msgs = safetyFindings.filter { $0.severity == .error }.map(\.message).joined(separator: "\n")
            statusLabel.stringValue = msgs
            throw ValidationError.zipListingFailed
        }

        statusLabel.stringValue = "Extracting…"
        let extractDir = staging.appendingPathComponent("extracted", isDirectory: true)
        try CoatValidator.extractZip(at: url, to: extractDir)

        // Symlinks are invisible in a listing, so this is the first point the
        // archive can be checked for one. Discard the extraction on an escape
        // rather than leaving a link into the user's home in the staging dir.
        let treeFindings = CoatValidator.checkExtractedTree(at: extractDir, fileManager: fileManager)
        if treeFindings.contains(where: { $0.severity == .error }) {
            try? fileManager.removeItem(at: extractDir)
            statusLabel.stringValue = treeFindings
                .filter { $0.severity == .error }
                .map(\.message)
                .joined(separator: "\n")
            throw ValidationError.unsafeArchive
        }
        archiveFindings = treeFindings

        guard let coatFolder = CoatValidator.findCoatFolder(in: extractDir) else {
            statusLabel.stringValue = "No coat folder found in archive (needs \(CoatValidator.requiredSprite))."
            throw ValidationError.noCoatFolderFound
        }

        return coatFolder
    }

    private func importFolder(from url: URL, to staging: URL) throws -> URL {
        let dest = staging.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: url, to: dest)
        return dest
    }

    private func createStagingDirectory() throws -> URL {
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("jumbini-workshop-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    // MARK: - Report display

    private func displayReport(_ report: CoatValidationReport) {
        let findings = archiveFindings + report.findings
        let errors = findings.filter { $0.severity == .error }
        let warnings = findings.filter { $0.severity == .warning }
        let infos = findings.filter { $0.severity == .info }

        var text = ""
        text += "Coat: \(report.coatName) (\(report.coatID))\n"
        text += "Present: \(report.presentStates.count)/\(FullCoatState.allCases.count) states\n"

        if !errors.isEmpty {
            text += "\n❌ ERRORS (\(errors.count)):\n"
            for e in errors { text += "  • \(e.message)\n" }
        }
        if !warnings.isEmpty {
            text += "\n⚠️ WARNINGS (\(warnings.count)):\n"
            for w in warnings { text += "  • \(w.message)\n" }
        }
        if !infos.isEmpty {
            text += "\nℹ️ INFO (\(infos.count)):\n"
            for info in infos { text += "  • \(info.message)\n" }
        }
        if errors.isEmpty && warnings.isEmpty && infos.isEmpty {
            text += "\n✓ No issues found."
        }

        findingsTextView.string = text
        showValidation(true)

        statusLabel.stringValue = errors.isEmpty
            ? "Validation passed with \(warnings.count) warning(s), \(infos.count) info(s)."
            : "\(errors.count) error(s) must be fixed before installing."

        // Rebuild scale row for present states.
        rebuildScaleStack(report: report)
    }

    // MARK: - Scale editing

    private func rebuildScaleStack(report: CoatValidationReport) {
        scaleStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scaleStack.isHidden = report.presentStates.isEmpty

        let statesWithAllDirections = report.presentStates.filter { state in
            (report.stateDirections[state]?.count ?? 0) == Facing.coatDirections.count
        }.sorted()

        guard !statesWithAllDirections.isEmpty else { return }

        let header = NSTextField(labelWithString: "Per-state scale overrides:")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        scaleStack.addArrangedSubview(header)

        for state in statesWithAllDirections {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6

            let label = NSTextField(labelWithString: "\(state):")
            label.font = .systemFont(ofSize: 11)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 64).isActive = true

            let field = NSTextField()
            field.font = .systemFont(ofSize: 11)
            field.controlSize = .small
            field.stringValue = String(format: "%.1f", scaleEdits[state] ?? SpriteLibrary.baseScale)
            field.target = self
            field.action = #selector(scaleEdited(_:))
            field.identifier = NSUserInterfaceItemIdentifier(rawValue: Self.scaleFieldPrefix + state)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true

            let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetScale(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.controlSize = .small
            resetBtn.font = .systemFont(ofSize: 10)
            resetBtn.identifier = NSUserInterfaceItemIdentifier(rawValue: Self.resetButtonPrefix + state)

            let defaultLabel = NSTextField(labelWithString: "(default: \(String(format: "%.1f", SpriteLibrary.baseScale)))")
            defaultLabel.font = .systemFont(ofSize: 10)
            defaultLabel.textColor = .secondaryLabelColor

            row.addArrangedSubview(label)
            row.addArrangedSubview(field)
            row.addArrangedSubview(resetBtn)
            row.addArrangedSubview(defaultLabel)
            scaleStack.addArrangedSubview(row)
        }
    }

    /// Which state a scale row's control belongs to.
    ///
    /// Carried on the control itself. Recovering it by trimming the colon off
    /// the row's label meant any change to how that label reads — a unit, a
    /// prettier name — silently wrote the wrong key into the manifest.
    private func state(of control: NSView, prefix: String) -> String? {
        guard let raw = control.identifier?.rawValue, raw.hasPrefix(prefix) else { return nil }
        return String(raw.dropFirst(prefix.count))
    }

    @objc private func scaleEdited(_ sender: NSTextField) {
        guard let state = state(of: sender, prefix: Self.scaleFieldPrefix) else { return }
        guard let value = Double(sender.stringValue), value > 0 else {
            statusLabel.stringValue = "Scale for \(state) must be a positive number."
            return
        }
        scaleEdits[state] = CGFloat(value)

        // Write updated scales to the staging coat.json.
        writeScaleEdits()
        if isPreviewing { refreshPreview() }
    }

    @objc private func resetScale(_ sender: NSButton) {
        guard let state = state(of: sender, prefix: Self.resetButtonPrefix),
              let report else { return }
        scaleEdits.removeValue(forKey: state)
        rebuildScaleStack(report: report)
        writeScaleEdits()
        if isPreviewing { refreshPreview() }
    }

    /// Persist the scale edits into the staging `coat.json`.
    ///
    /// Merged into whatever manifest is already there rather than rebuilt from
    /// the two fields the workshop knows about: hand-building a dictionary of
    /// name and scales deleted every other key in the file, so opening a coat
    /// and nudging one scale quietly stripped anything its author had added.
    private func writeScaleEdits() {
        guard let staging = stagingURL else { return }

        var manifest = CoatCatalog.manifest(in: staging, fileManager: fileManager) ?? CoatManifest()
        manifest.name = report?.coatName ?? manifest.name ?? staging.lastPathComponent

        // A scale equal to the default says nothing the app doesn't already
        // assume, and an empty overrides dictionary is noise in the file.
        let overrides = scaleEdits.filter { $0.value != SpriteLibrary.baseScale }
        manifest.scales = overrides.isEmpty ? nil : overrides.mapValues { Double($0) }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent("coat.json"), options: .atomic
            )
        } catch {
            // Silently failing here left the panel showing an edit that was
            // never going to survive install.
            statusLabel.stringValue = "Could not save scales: \(error.localizedDescription)"
        }
    }

    private func refreshPreview() {
        guard let staging = stagingURL, let report else { return }
        let coat = Coat(
            id: report.coatID,
            title: report.coatName,
            root: staging,
            prefix: "",
            scales: scaleEdits
        )
        setPreviewCoat?(coat)
        setPreviewPose?(selectedState, selectedDirection)
    }

    // MARK: - Preview

    @objc private func togglePreview() {
        isPreviewing.toggle()
        if isPreviewing {
            startPreview()
        } else {
            stopPreview()
        }
        previewButton.title = isPreviewing ? "Stop Preview" : "Preview"
        statePopup.isEnabled = isPreviewing
        directionControl.isEnabled = isPreviewing
    }

    private func startPreview() {
        guard let staging = stagingURL, let report else { return }
        let coat = Coat(
            id: report.coatID,
            title: report.coatName,
            root: staging,
            prefix: "",
            scales: scaleEdits
        )
        setPreviewCoat?(coat)
        setPreviewPose?(selectedState, selectedDirection)
        statusLabel.stringValue = "Previewing on Jumba. Select states and directions below."
    }

    private func stopPreview() {
        restoreCoat?()
        statusLabel.stringValue = report?.canInstall == true
            ? "Ready to install. Adjust scales or preview again."
            : "\(report?.errors.count ?? 0) error(s) must be fixed before installing."
        // Update report/export source in case scales changed.
        if let staging = stagingURL {
            exportSource = staging
        }
    }

    private func clearPreview() {
        if isPreviewing { stopPreview() }
        isPreviewing = false
        archiveFindings = []
        previewButton.title = "Preview"
        previewButton.isEnabled = false
        statePopup.isEnabled = false
        directionControl.isEnabled = false
        showValidation(false)
        findingsTextView.string = ""
        installButton.isEnabled = false
        exportButton.isEnabled = false
    }

    @objc private func stateChanged() {
        selectedState = statePopup.titleOfSelectedItem ?? "idle"
        setPreviewPose?(selectedState, selectedDirection)
    }

    @objc private func directionChosen(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard Facing.coatDirections.indices.contains(index) else { return }
        selectedDirection = Facing.coatDirections[index]
        setPreviewPose?(selectedState, selectedDirection)
    }

    private func updateDirectionControl() {
        guard let index = Facing.coatDirections.firstIndex(of: selectedDirection) else { return }
        directionControl.selectedSegment = index
    }

    private func directionShortLabel(_ dir: Facing) -> String {
        switch dir {
        case .south: "S"
        case .southEast: "SE"
        case .east: "E"
        case .northEast: "NE"
        case .north: "N"
        case .northWest: "NW"
        case .west: "W"
        case .southWest: "SW"
        }
    }

    /// Spelled-out direction, for the tooltip and VoiceOver — "SW" is not a
    /// word, and the abbreviation is all the segment itself can fit.
    private func directionName(_ dir: Facing) -> String {
        switch dir {
        case .south: "South (facing you)"
        case .southEast: "South-east"
        case .east: "East"
        case .northEast: "North-east"
        case .north: "North (facing away)"
        case .northWest: "North-west"
        case .west: "West"
        case .southWest: "South-west"
        }
    }

    // MARK: - Install

    @objc private func doInstall() {
        guard let staging = stagingURL, let report, report.canInstall else { return }

        guard let coatsDirectory = CoatCatalog.defaultCoatsDirectory() else {
            statusLabel.stringValue = "Could not find coats directory."
            return
        }

        do {
            let installedURL = try CoatValidator.installCoat(
                from: staging, coatsDirectory: coatsDirectory, fileManager: fileManager
            )
            statusLabel.stringValue = "Installed as \"\(installedURL.lastPathComponent)\"."

            stopPreview()
            onInstall?(installedURL.lastPathComponent)
            installButton.title = "Installed ✓"
            installButton.isEnabled = false
            isInstalledCoat = true
        } catch {
            statusLabel.stringValue = "Install failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Export

    @objc private func doExport() {
        guard let source = exportSource else { return }

        let panel = NSSavePanel()
        let name = source.lastPathComponent
        panel.nameFieldStringValue = "\(name).zip"
        panel.allowedContentTypes = [.zip]
        panel.message = "Export coat as a portable zip."
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try CoatValidator.exportCoat(from: source, to: destination)
            statusLabel.stringValue = "Exported to \(destination.lastPathComponent)."
        } catch {
            statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Open for an installed coat (export-only mode)

    /// Open the workshop in export-only mode for an already-installed coat.
    func openForInstalledCoat(_ coat: Coat) {
        clearPreview()
        stagingURL = coat.root
        exportSource = coat.root
        isInstalledCoat = true

        if let root = coat.root {
            let result = CoatValidator.validate(folder: root, fileManager: fileManager)
            report = result
            scaleEdits = result.scales
            displayReport(result)
            previewButton.isEnabled = true
            installButton.title = "Installed"
            installButton.isEnabled = false
        } else {
            statusLabel.stringValue = "\(coat.title) is a built-in coat — export not available."
            exportButton.isEnabled = false
            showValidation(false)
            return
        }

        exportButton.isEnabled = true
        statusLabel.stringValue = "\(coat.title) — export or preview."
    }

    // MARK: - Dismiss

    /// The live preview drives the real dog in the overlay, so it must not
    /// outlive the window that started it — however the window went away.
    override func panelWillClose() {
        if isPreviewing { stopPreview() }
    }

    /// Centred the first time, then wherever the user last dragged it.
    func present() {
        presentPanel()
    }
}
