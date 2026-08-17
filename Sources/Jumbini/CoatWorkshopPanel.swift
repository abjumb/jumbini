import AppKit
import UniformTypeIdentifiers
import SpriteKit

/// The Coat Workshop panel: import, validate, preview, adjust, install, and
/// export custom dog coats without touching Application Support by hand.
///
/// A borderless, non-activating NSPanel like the DogGeneratorPanel. It owns
/// none of the rendering — it sends pose/direction commands to the scene so
/// the preview happens on the real dog in the overlay.
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
    private let fileManager: FileManager

    // MARK: - UI elements

    private let importButton = NSButton(title: "Import Coat…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let findingsScroll = NSScrollView()
    private let findingsTextView = NSTextView()
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let statePopup = NSPopUpButton()
    private var directionSegments: [Facing: NSButton] = [:]
    private let scaleStack = NSStackView()
    private let installButton = NSButton(title: "Install", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private var isInstalledCoat: Bool = false

    private static let panelWidth: CGFloat = 400

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        super.init(width: Self.panelWidth)
        setUpContent()
    }

    // MARK: - Content layout

    private func setUpContent() {
        let title = NSTextField(labelWithString: "Coat Workshop")
        title.font = PanelStyle.title
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let closeButton = makeCloseButton(action: #selector(dismissPanel))

        let header = NSStackView(views: [title, closeButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

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
        statusLabel.font = PanelStyle.detail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = contentWidth
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

        let directionRow = NSStackView()
        directionRow.orientation = .horizontal
        directionRow.spacing = 4
        for dir in Facing.coatDirections {
            let btn = NSButton(title: directionShortLabel(dir), target: self, action: #selector(directionChosen(_:)))
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.font = .systemFont(ofSize: 9)
            btn.identifier = NSUserInterfaceItemIdentifier(rawValue: "dir:" + dir.fileSuffix)
            btn.isEnabled = false
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 32),
                btn.heightAnchor.constraint(equalToConstant: 22),
            ])
            directionRow.addView(btn, in: .center)
            directionSegments[dir] = btn
        }
        updateDirectionButtons()

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

        let stack = NSStackView(views: [
            header, importRow, statusLabel, findingsScroll,
            previewRow, directionRow, scaleStack, installButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PanelStyle.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: PanelStyle.inset, left: PanelStyle.inset,
            bottom: PanelStyle.inset, right: PanelStyle.inset
        )

        stack.layoutSubtreeIfNeeded()
        let fittedHeight = stack.fittingSize.height

        embed(stack)
        setContentSize(NSSize(width: panelWidth, height: fittedHeight))
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
        let extractDir = staging.appending(path: "extracted", directoryHint: .isDirectory)
        try CoatValidator.extractZip(at: url, to: extractDir)

        guard let coatFolder = CoatValidator.findCoatFolder(in: extractDir) else {
            statusLabel.stringValue = "No coat folder found in archive (needs \(CoatValidator.requiredSprite))."
            throw ValidationError.noCoatFolderFound
        }

        return coatFolder
    }

    private func importFolder(from url: URL, to staging: URL) throws -> URL {
        let dest = staging.appending(path: url.lastPathComponent, directoryHint: .isDirectory)
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
        let errors = report.findings.filter { $0.severity == .error }
        let warnings = report.findings.filter { $0.severity == .warning }
        let infos = report.findings.filter { $0.severity == .info }

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
        findingsScroll.isHidden = false

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
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true

            let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetScale(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.controlSize = .small
            resetBtn.font = .systemFont(ofSize: 10)
            resetBtn.identifier = NSUserInterfaceItemIdentifier(rawValue: "reset:" + state)

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

    @objc private func scaleEdited(_ sender: NSTextField) {
        guard let row = sender.superview as? NSStackView,
              let label = row.arrangedSubviews.first as? NSTextField else { return }
        let state = String(label.stringValue.dropLast())
        guard let value = Double(sender.stringValue), value > 0 else { return }
        scaleEdits[state] = CGFloat(value)

        // Write updated scales to the staging coat.json.
        writeScaleEdits()
        if isPreviewing { refreshPreview() }
    }

    @objc private func resetScale(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView,
              let label = row.arrangedSubviews.first as? NSTextField else { return }
        let state = String(label.stringValue.dropLast())
        scaleEdits.removeValue(forKey: state)
        rebuildScaleStack(report: report!)
        writeScaleEdits()
        if isPreviewing { refreshPreview() }
    }

    private func writeScaleEdits() {
        guard let staging = stagingURL else { return }
        let filtered = scaleEdits.filter { $0.value != SpriteLibrary.baseScale }
        var manifest: [String: Any] = ["name": report?.coatName ?? staging.lastPathComponent]
        if !filtered.isEmpty {
            manifest["scales"] = filtered.mapValues { Double($0) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
            try? data.write(to: staging.appending(path: "coat.json"))
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
        for btn in directionSegments.values { btn.isEnabled = isPreviewing }
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
        previewButton.title = "Preview"
        previewButton.isEnabled = false
        statePopup.isEnabled = false
        for btn in directionSegments.values { btn.isEnabled = false }
        findingsScroll.isHidden = true
        findingsTextView.string = ""
        installButton.isEnabled = false
        exportButton.isEnabled = false
    }

    @objc private func stateChanged() {
        selectedState = statePopup.titleOfSelectedItem ?? "idle"
        setPreviewPose?(selectedState, selectedDirection)
    }

    @objc private func directionChosen(_ sender: NSButton) {
        guard let dir = directionSegments.first(where: { $0.value === sender })?.key else { return }
        selectedDirection = dir
        updateDirectionButtons()
        setPreviewPose?(selectedState, selectedDirection)
    }

private func updateDirectionButtons() {
        for (dir, btn) in directionSegments {
            btn.state = dir == selectedDirection ? .on : .off
        }
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

    // MARK: - Install

    @objc private func doInstall() {
        guard let staging = stagingURL, let report, report.canInstall else { return }

        do {
            let installedURL = try CoatValidator.installCoat(
                from: staging, coatsDirectory: CoatCatalog.defaultCoatsDirectory,
                fileManager: fileManager
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
            findingsScroll.isHidden = true
            return
        }

        exportButton.isEnabled = true
        statusLabel.stringValue = "\(coat.title) — export or preview."
    }

    // MARK: - Dismiss

    @objc private func dismissPanel() {
        if isPreviewing { stopPreview() }
        orderOut(nil)
    }
}
