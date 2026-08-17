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

    private let frontButton = NSButton(title: "Front photo…", target: nil, action: nil)
    private let sideButton = NSButton(title: "Side photo…", target: nil, action: nil)
    private let backButton = NSButton(title: "Back photo…", target: nil, action: nil)
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

    init() {
        super.init(width: Self.panelWidth)
        setUpContent()
    }

    private func setUpContent() {
        let title = NSTextField(labelWithString: "Make Your Own Dog")
        title.font = PanelStyle.title

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

        statusLabel.font = PanelStyle.detail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = contentWidth
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

        // The way out. Before there was one, nothing but Apply dismissed the
        // window, and abandoning a generation meant quitting the app.
        let closeButton = makeCloseButton(action: #selector(dismissPanel))
        // Let the title absorb the slack so the button lands on the far edge.
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [title, closeButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY

        let stack = NSStackView(views: [
            header, photos, progress, statusLabel, previewView, applyButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PanelStyle.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: PanelStyle.inset, left: PanelStyle.inset,
            bottom: PanelStyle.inset, right: PanelStyle.inset
        )
        // Every other row is sized by its content and left-aligned, which for
        // the title row would park the close button next to the title instead
        // of opposite it. Pin the row to the full content width so `.fill` has
        // something to spread.
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        // Height comes from the content, not from a number picked in advance.
        // The old fixed 380 left about a hundred points of nothing below the
        // Apply button — invisible against a flat grey background, obvious as
        // a slab of empty glass. Measured before the stack is handed to the
        // backdrop, where constraints tying it to the window would answer with
        // the window's height instead of the content's.
        stack.layoutSubtreeIfNeeded()
        let fittedHeight = stack.fittingSize.height

        embed(stack)
        setContentSize(NSSize(width: panelWidth, height: fittedHeight))
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
        dismissPanel()
    }

    /// Close button and Escape both land here. `orderOut` rather than `close`
    /// so the panel survives to be shown again with whatever the user had
    /// already picked still in it — the app delegate keeps the one instance.
    ///
    /// A generation in flight is left to finish. It writes the coat to disk on
    /// its own and the panel is still here to receive the preview, so closing
    /// mid-run costs nothing but the wait.
    @objc private func dismissPanel() {
        orderOut(nil)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        frontButton.isEnabled = !busy
        sideButton.isEnabled = !busy
        backButton.isEnabled = !busy
        updateGenerateState()
    }
}
