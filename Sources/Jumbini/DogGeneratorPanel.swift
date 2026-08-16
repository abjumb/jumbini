import AppKit
import UniformTypeIdentifiers

/// The "Make Your Own Dog" panel: pick three photos, generate, preview, apply.
///
/// A borderless, non-activating `NSPanel` like the overlay, so opening it never
/// steals focus from whatever the user is doing. It owns none of the pipeline
/// itself — it calls the `generate` closure (wired by the app delegate to the
/// real generator) and reports the result back to `onApply`.
final class DogGeneratorPanel: NSPanel {
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

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
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
        statusLabel.preferredMaxLayoutWidth = 300
        statusLabel.stringValue = "Pick three photos — front, side, back."

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

        let stack = NSStackView(views: [
            title, photos, progress, statusLabel, previewView, applyButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 12
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        contentView = container
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

    /// Show the panel centred on the main screen.
    func present() {
        center()
        orderFrontRegardless()
    }
}
