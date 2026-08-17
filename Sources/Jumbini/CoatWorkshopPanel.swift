import AppKit
import UniformTypeIdentifiers
import SpriteKit

/// The Coat Workshop panel: import, validate, preview, adjust, install, and
/// export custom dog coats without touching Application Support by hand.
///
/// A borderless, non-activating NSPanel like the DogGeneratorPanel. It owns
/// none of the rendering — it sends pose/direction commands to the scene so
/// the preview happens on the real dog in the overlay.
final class CoatWorkshopPanel: NSPanel {
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
    /// The import or re-validation in flight. Held so a second Import cancels
    /// the first rather than letting two stagings race to the same fields.
    private var stagingTask: Task<Void, Never>?
    /// Identifies the import whose results and controls currently own the UI.
    private var stagingGeneration = UUID()

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
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private var isInstalledCoat: Bool = false

    private static let panelWidth: CGFloat = 400
    private static let initialHeight: CGFloat = 520
    private static let contentInset: CGFloat = 16
    private static let cornerRadius: CGFloat = 22

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.initialHeight),
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
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Content layout

    private func setUpContent() {
        let title = NSTextField(labelWithString: "Coat Workshop")
        title.font = .preferred(.title3, weight: .semibold)

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close"
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismissPanel)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [title, closeButton])
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
        statusLabel.font = .preferred(.subheadline)
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
        // Monospaced, because the findings are filenames — but sized from the
        // text style, so it grows with everything else in the panel.
        findingsTextView.font = .monospacedSystemFont(
            ofSize: NSFont.preferred(.caption1).pointSize, weight: .regular
        )
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
            btn.font = .preferred(.caption2)
            btn.identifier = NSUserInterfaceItemIdentifier(rawValue: "dir:" + dir.fileSuffix)
            // "NE" is two letters to read and an abbreviation to guess at.
            // The button says NE; VoiceOver says north-east.
            btn.setAccessibilityLabel(Self.directionName(dir))
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
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: Self.contentInset, left: Self.contentInset,
            bottom: Self.contentInset, right: Self.contentInset
        )

        stack.layoutSubtreeIfNeeded()
        let fittedHeight = stack.fittingSize.height

        contentView = makeBackdrop(around: stack)
        setContentSize(NSSize(width: Self.panelWidth, height: fittedHeight))
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

    // MARK: - File dialogs

    /// A file dialog opened by this panel has to sit above it, and the app has
    /// to be frontmost for the keyboard to reach it.
    ///
    /// The workshop floats at `.statusBar` so it stays over the user's other
    /// windows; window levels are absolute, so an ordinary dialog would open
    /// *underneath* the panel that asked for it. One level up puts it back on
    /// top without disturbing anything else.
    private static let dialogLevel = NSWindow.Level(
        rawValue: NSWindow.Level.statusBar.rawValue + 1
    )

    /// Run an open or save dialog WITHOUT blocking the main thread.
    ///
    /// `runModal` spins its own event loop, which stops the dog dead for as
    /// long as the user is browsing for a file — on a borderless overlay that
    /// reads as the app having hung. `begin` puts up the same dialog and hands
    /// the answer back through a completion instead. Nothing is called when
    /// the user cancels.
    private func present(_ dialog: NSSavePanel, then handle: @escaping (URL) -> Void) {
        dialog.level = Self.dialogLevel
        NSApp.activate()
        dialog.begin { response in
            guard response == .OK, let url = dialog.url else { return }
            handle(url)
        }
    }

    // MARK: - Import

    @objc private func doImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose a coat folder or zip archive."
        present(panel) { [weak self] url in self?.beginImport(from: url) }
    }

    /// Stage and validate the chosen coat off the main thread.
    ///
    /// What used to run here inline was a forked `unzip -l`, a forked `unzip`,
    /// a recursive folder copy and a CGImageSource decode of up to 136 PNGs —
    /// seconds of frozen dog. All of it now happens on a detached task, with
    /// the status line updated from the stages as they pass.
    private func beginImport(from url: URL) {
        let generation = UUID()
        stagingGeneration = generation
        clearPreview()
        stagingTask?.cancel()
        importButton.isEnabled = false
        statusLabel.stringValue = "Reading \(url.lastPathComponent)…"

        let fileManager = self.fileManager
        // Called from the staging thread, so it hops before it draws.
        let announceStage: @Sendable (CoatImportStage) -> Void = { [weak self] stage in
            Task { @MainActor in
                guard self?.stagingGeneration == generation else { return }
                self?.statusLabel.stringValue = stage.message
            }
        }

        stagingTask = Task { [weak self] in
            defer {
                if self?.stagingGeneration == generation {
                    self?.importButton.isEnabled = true
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try CoatValidator.stageImport(
                        from: url, fileManager: fileManager, progress: announceStage
                    )
                }
                let staged = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                // Superseded by a second Import: the newer one owns the fields
                // and the button now, so leave both alone.
                guard !Task.isCancelled,
                      self?.stagingGeneration == generation else { return }
                self?.accept(staged)
            } catch {
                guard !Task.isCancelled,
                      self?.stagingGeneration == generation else { return }
                self?.statusLabel.stringValue = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func accept(_ staged: StagedCoat) {
        stagingURL = staged.folder
        report = staged.report
        scaleEdits = staged.report.scales

        displayReport(staged.report)
        exportButton.isEnabled = true
        exportSource = staged.folder
        isInstalledCoat = false
        installButton.isEnabled = staged.report.canInstall
        previewButton.isEnabled = true
        installButton.title = "Install"
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
        header.font = .preferred(.subheadline, weight: .semibold)
        scaleStack.addArrangedSubview(header)

        for state in statesWithAllDirections {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6

            let label = NSTextField(labelWithString: "\(state):")
            label.font = .preferred(.subheadline)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 64).isActive = true

            let field = NSTextField()
            field.font = .preferred(.subheadline)
            field.controlSize = .small
            field.stringValue = String(format: "%.1f", scaleEdits[state] ?? SpriteLibrary.baseScale)
            field.target = self
            field.action = #selector(scaleEdited(_:))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true

            let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetScale(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.controlSize = .small
            resetBtn.font = .preferred(.caption1)
            resetBtn.identifier = NSUserInterfaceItemIdentifier(rawValue: "reset:" + state)

            let defaultLabel = NSTextField(labelWithString: "(default: \(String(format: "%.1f", SpriteLibrary.baseScale)))")
            defaultLabel.font = .preferred(.caption1)
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
              let label = row.arrangedSubviews.first as? NSTextField,
              let report else { return }
        let state = String(label.stringValue.dropLast())
        scaleEdits.removeValue(forKey: state)
        rebuildScaleStack(report: report)
        writeScaleEdits()
        if isPreviewing { refreshPreview() }
    }

    /// One small JSON file, so this stays on the main thread — but it is not
    /// allowed to fail silently. A scale override the user typed and the
    /// workshop then dropped on the floor is the kind of thing they only find
    /// out about the next time they open the coat.
    private func writeScaleEdits() {
        guard let staging = stagingURL else { return }
        let filtered = scaleEdits.filter { $0.value != SpriteLibrary.baseScale }
        var manifest: [String: Any] = ["name": report?.coatName ?? staging.lastPathComponent]
        if !filtered.isEmpty {
            manifest["scales"] = filtered.mapValues { Double($0) }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
            try data.write(to: staging.appendingPathComponent("coat.json"))
        } catch {
            statusLabel.stringValue = "Could not save the scale override: \(error.localizedDescription)"
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

    /// The same eight directions, spelled out.
    private static func directionName(_ dir: Facing) -> String {
        switch dir {
        case .south: "Facing south"
        case .southEast: "Facing south-east"
        case .east: "Facing east"
        case .northEast: "Facing north-east"
        case .north: "Facing north"
        case .northWest: "Facing north-west"
        case .west: "Facing west"
        case .southWest: "Facing south-west"
        }
    }

    // MARK: - Install

    /// Installing copies the whole coat — up to 136 files — into Application
    /// Support, so it goes off the main thread like the import does.
    @objc private func doInstall() {
        guard let staging = stagingURL, let report, report.canInstall else { return }
        let generation = stagingGeneration

        guard let coatsDirectory = CoatCatalog.defaultCoatsDirectory() else {
            statusLabel.stringValue = "Could not find coats directory."
            return
        }

        installButton.isEnabled = false
        statusLabel.stringValue = "Installing…"
        let fileManager = self.fileManager

        Task { [weak self] in
            do {
                let installedURL = try await Task.detached(priority: .userInitiated) {
                    try CoatValidator.installCoat(
                        from: staging, coatsDirectory: coatsDirectory, fileManager: fileManager
                    )
                }.value
                guard let self else { return }
                // A second Import was started and accepted while this install
                // was running — the fields are now someone else's.
                guard self.stagingGeneration == generation,
                      self.stagingURL == staging,
                      self.report?.coatID == report.coatID else { return }
                // Before the message, not after: stopPreview writes its own
                // line into the status label.
                self.stopPreview()
                self.statusLabel.stringValue = "Installed as \"\(installedURL.lastPathComponent)\"."
                self.onInstall?(installedURL.lastPathComponent)
                self.installButton.title = "Installed ✓"
                self.installButton.isEnabled = false
                self.isInstalledCoat = true
            } catch {
                guard let self else { return }
                // Same guard: a fresh Import swapped the fields under us.
                guard self.stagingGeneration == generation,
                      self.stagingURL == staging,
                      self.report?.coatID == report.coatID else { return }
                self.statusLabel.stringValue = "Install failed: \(error.localizedDescription)"
                self.installButton.isEnabled = true
            }
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
        present(panel) { [weak self] destination in
            self?.beginExport(from: source, to: destination)
        }
    }

    /// `zip -r` over a coat folder is another fork plus a full read of every
    /// sprite; the dog keeps running while it happens.
    private func beginExport(from source: URL, to destination: URL) {
        exportButton.isEnabled = false
        statusLabel.stringValue = "Exporting…"
        Task { [weak self] in
            defer { self?.exportButton.isEnabled = true }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CoatValidator.exportCoat(from: source, to: destination)
                }.value
                self?.statusLabel.stringValue = "Exported to \(destination.lastPathComponent)."
            } catch {
                self?.statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Open for an installed coat (export-only mode)

    /// Open the workshop in export-only mode for an already-installed coat.
    ///
    /// Re-validating decodes every sprite the coat has, exactly as an import
    /// does, so it takes the same detour off the main thread.
    func openForInstalledCoat(_ coat: Coat) {
        let generation = UUID()
        stagingGeneration = generation
        stagingTask?.cancel()
        importButton.isEnabled = true
        clearPreview()
        stagingURL = coat.root
        exportSource = coat.root
        isInstalledCoat = true

        guard let root = coat.root else {
            statusLabel.stringValue = "\(coat.title) is a built-in coat — export not available."
            exportButton.isEnabled = false
            findingsScroll.isHidden = true
            return
        }

        exportButton.isEnabled = true
        statusLabel.stringValue = "Checking \(coat.title)…"
        let fileManager = self.fileManager
        stagingTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                CoatValidator.validate(folder: root, fileManager: fileManager)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self,
                  self.stagingGeneration == generation else { return }
            self.report = result
            self.scaleEdits = result.scales
            self.displayReport(result)
            self.previewButton.isEnabled = true
            self.installButton.title = "Installed"
            self.installButton.isEnabled = false
            self.statusLabel.stringValue = "\(coat.title) — export or preview."
        }
    }

    // MARK: - Dismiss

    @objc private func dismissPanel() {
        if isPreviewing { stopPreview() }
        orderOut(nil)
    }

    func present() {
        center()
        orderFrontRegardless()
        makeKey()
    }
}
