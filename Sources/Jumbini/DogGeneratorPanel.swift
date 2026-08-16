import AppKit
import UniformTypeIdentifiers

/// The "Make Your Own Dog" panel: pick three photos, generate, preview, apply.
///
/// A borderless, non-activating `NSPanel` like the overlay, so opening it never
/// steals focus from whatever the user is doing. It owns none of the pipeline
/// itself — it calls the `generate` closure (wired by the app delegate to the
/// real generator) and reports the result back to `onApply`.
final class DogGeneratorPanel: JumbiniPanel {
    /// Run the generation and return the `idle_south` sprite as preview data.
    /// The closure is expected to have already written the coat to disk.
    var generate: ((DogPhotos) async throws -> Data)?
    /// The user clicked Apply — select the generated coat.
    var onApply: (() -> Void)?

    private var frontData: Data?
    private var sideData: Data?
    private var backData: Data?

    private let frontButton = NSButton(title: "Front…", target: nil, action: nil)
    private let sideButton = NSButton(title: "Side…", target: nil, action: nil)
    private let backButton = NSButton(title: "Back…", target: nil, action: nil)
    private let generateButton = NSButton(title: "Generate", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previewView = NSImageView()
    private var isBusy = false

    /// The width is fixed and the height is measured: the title row and the
    /// wrapping status label are both laid out against a known width, and what
    /// that produces vertically is whatever it produces. See `setUpContent`.
    private static let panelWidth: CGFloat = 340
    /// Starting height only, replaced once the content has been measured.
    private static let initialHeight: CGFloat = 380
    private static let contentInset: CGFloat = 16

    init() {
        super.init(
            autosaveName: "dogGenerator",
            size: NSSize(width: Self.panelWidth, height: Self.initialHeight)
        )
        setUpContent()
    }

    private func setUpContent() {
        let title = NSTextField(labelWithString: "Make Your Own Dog")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        frontButton.target = self
        frontButton.action = #selector(chooseFront)
        sideButton.target = self
        sideButton.action = #selector(chooseSide)
        backButton.target = self
        backButton.action = #selector(chooseBack)

        let photos = NSStackView(views: [frontButton, sideButton, backButton])
        photos.orientation = .horizontal
        photos.spacing = 8

        generateButton.target = self
        generateButton.action = #selector(generateDog)
        generateButton.keyEquivalent = "\r"
        generateButton.isEnabled = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = Self.panelWidth - Self.contentInset * 2
        statusLabel.stringValue = "Pick three photos — front, side, back."
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        // The one row whose height moves: a wrapped failure message needs
        // three lines where the opening hint needs one. Reserving the tall
        // case keeps the panel a fixed size instead of jumping as it reports.
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let progress = NSStackView(views: [spinner, generateButton])
        progress.orientation = .horizontal
        progress.spacing = 8

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.imageScaling = .scaleNone
        previewView.setContentHuggingPriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            previewView.widthAnchor.constraint(equalToConstant: 96),
            previewView.heightAnchor.constraint(equalToConstant: 96),
        ])

        applyButton.target = self
        applyButton.action = #selector(applyDog)
        applyButton.isEnabled = false

        // Let the title absorb the slack so the button lands on the far edge.
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [title])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY

        // Grouped into the same labelled cards Settings uses, so the three
        // panels read as one app rather than three separately-built windows.
        let cardWidth = Self.panelWidth - Self.contentInset * 2
        let stack = NSStackView(views: [
            header,
            PanelTheme.sectionHeader("Photos"),
            PanelBuilder.card([photos], width: cardWidth),
            PanelTheme.sectionHeader("Generate"),
            PanelBuilder.card([progress, statusLabel], width: cardWidth),
            PanelTheme.sectionHeader("Preview"),
            PanelBuilder.card([previewView, applyButton], width: cardWidth),
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
        // Every other row is sized by its content and left-aligned, which for
        // the title row would park the close button next to the title instead
        // of opposite it. Pin the row to the full content width so `.fill` has
        // something to spread.
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(
            equalToConstant: Self.panelWidth - Self.contentInset * 2
        ).isActive = true

        // Height comes from the content, not from a number picked in advance.
        // The old fixed 380 left about a hundred points of nothing below the
        // Apply button — invisible against a flat grey background, obvious as
        // a slab of empty glass. Measured before the stack is handed to the
        // backdrop, where constraints tying it to the window would answer with
        // the window's height instead of the content's.
        stack.layoutSubtreeIfNeeded()
        let fittedHeight = stack.fittingSize.height

        installChrome(around: stack)
        setContentSize(NSSize(width: Self.panelWidth, height: fittedHeight))
    }

    // MARK: - Photo picking

    private func choosePhoto() -> Data? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }

    @objc private func chooseFront() {
        if let data = choosePhoto() {
            frontData = data
            frontButton.title = "Front ✓"
            updateGenerateState()
        }
    }

    @objc private func chooseSide() {
        if let data = choosePhoto() {
            sideData = data
            sideButton.title = "Side ✓"
            updateGenerateState()
        }
    }

    @objc private func chooseBack() {
        if let data = choosePhoto() {
            backData = data
            backButton.title = "Back ✓"
            updateGenerateState()
        }
    }

    private func updateGenerateState() {
        generateButton.isEnabled = frontData != nil && sideData != nil && backData != nil && !isBusy
    }

    // MARK: - Actions

    @objc private func generateDog() {
        guard let frontData, let sideData, let backData, let generate else { return }
        setBusy(true)
        statusLabel.stringValue = "Generating… this can take a few minutes."
        Task { [weak self] in
            do {
                let preview = try await generate(
                    DogPhotos(front: frontData, side: sideData, back: backData)
                )
                await MainActor.run {
                    self?.previewView.image = NSImage(data: preview)
                    self?.previewView.imageScaling = .scaleProportionallyUpOrDown
                    self?.applyButton.isEnabled = true
                    self?.statusLabel.stringValue = "Done — click Apply to put him on screen."
                    self?.setBusy(false)
                }
            } catch {
                await MainActor.run {
                    self?.statusLabel.stringValue =
                        "Generation failed: \(error.localizedDescription)"
                    self?.setBusy(false)
                }
            }
        }
    }

    @objc private func applyDog() {
        onApply?()
        performClose(nil)
    }

    /// The red button, Escape and Apply all end up in JumbiniPanel's
    /// `performClose`, which orders out rather than closing so the panel
    /// survives to be shown again with whatever the user had already picked
    /// still in it — the app delegate keeps the one instance.
    ///
    /// A generation in flight is left to finish. It writes the coat to disk on
    /// its own and the panel is still here to receive the preview, so closing
    /// mid-run costs nothing but the wait.

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        frontButton.isEnabled = !busy
        sideButton.isEnabled = !busy
        backButton.isEnabled = !busy
        updateGenerateState()
    }

    /// Centred the first time, then wherever the user last dragged it.
    func present() {
        presentPanel()
    }
}
