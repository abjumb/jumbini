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
    /// The closure is expected to have already written the coat to disk, and
    /// to forward the pipeline's progress to the handler it is given.
    var generate: ((DogPhotos, @escaping GenerationProgress) async throws -> Data)?
    /// The user clicked Apply — select the generated coat.
    var onApply: (() -> Void)?

    private var frontData: Data?
    private var sideData: Data?
    private var backData: Data?

    private let frontButton = NSButton(title: "Front photo…", target: nil, action: nil)
    private let sideButton = NSButton(title: "Side photo…", target: nil, action: nil)
    private let backButton = NSButton(title: "Back photo…", target: nil, action: nil)
    private let generateButton = NSButton(title: "Generate", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previewView = NSImageView()
    private var isBusy = false
    /// The run in flight. Held for exactly one reason: so Cancel can stop it.
    private var generateTask: Task<Void, Never>?

    /// The width is fixed and the height is measured: the title row and the
    /// wrapping status label are both laid out against a known width, and what
    /// that produces vertically is whatever it produces. See `setUpContent`.
    private static let panelWidth: CGFloat = 340
    /// Starting height only, replaced once the content has been measured.
    private static let initialHeight: CGFloat = 380
    private static let contentInset: CGFloat = 16
    /// Liquid Glass wants a rounder corner than the 12pt square-ish radius the
    /// flat background used.
    private static let cornerRadius: CGFloat = 22

    init() {
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

    /// Borderless windows refuse key by default, which would leave the panel
    /// unable to hear a keystroke: no Escape to close it, and the Return on
    /// Generate would never fire either. `.nonactivatingPanel` still holds, so
    /// taking key here does not pull the user out of whatever app they were in.
    override var canBecomeKey: Bool { true }

    private func setUpContent() {
        let title = NSTextField(labelWithString: "Make Your Own Dog")
        title.font = .preferred(.title3, weight: .semibold)

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

        // A determinate bar, not a barber's pole. The run is six known steps
        // long and takes minutes; "something is happening" is not enough
        // information to decide whether to keep waiting.
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = Double(GenerationStep.count)
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.setAccessibilityLabel("Generation progress")
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 140).isActive = true

        // Only there while there is something to cancel. Before this, the way
        // out of a run that was going nowhere was to quit the app.
        cancelButton.target = self
        cancelButton.action = #selector(cancelGeneration)
        cancelButton.isHidden = true

        statusLabel.font = .preferred(.subheadline)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = Self.panelWidth - Self.contentInset * 2
        statusLabel.stringValue = "Pick three photos — front, side, back."
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        // The one row whose height moves: a wrapped failure message needs
        // three lines where the opening hint needs one. Reserving the tall
        // case keeps the panel a fixed size instead of jumping as it reports.
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let progress = NSStackView(views: [generateButton, cancelButton, progressBar])
        progress.orientation = .horizontal
        progress.spacing = 8

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.imageScaling = .scaleNone
        previewView.setContentHuggingPriority(.defaultLow, for: .vertical)
        // An unlabelled image view is announced as "image", which for the one
        // thing the whole panel exists to produce is not enough. Replaced with
        // the real thing once there is a dog in it.
        previewView.setAccessibilityLabel("No dog generated yet")
        NSLayoutConstraint.activate([
            previewView.widthAnchor.constraint(equalToConstant: 96),
            previewView.heightAnchor.constraint(equalToConstant: 96),
        ])

        applyButton.target = self
        applyButton.action = #selector(applyDog)
        applyButton.isEnabled = false

        // The way out. A borderless panel draws no close button of its own, so
        // before this there was none: nothing but Apply dismissed the window,
        // and abandoning a generation meant quitting the app.
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close"
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismissPanel)
        closeButton.toolTip = "Close"
        // Escape, the other half of "closeable". It only reaches us once the
        // panel is key, which happens on the first click into it — so the
        // button is the reliable route and this is the shortcut for it.
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        // A borderless button is exactly as big as its image, and an 11pt
        // glyph is a fiddly thing to hit. The glyph stays small; the target
        // around it does not.
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
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
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: Self.contentInset, left: Self.contentInset,
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

        contentView = makeBackdrop(around: stack)
        setContentSize(NSSize(width: Self.panelWidth, height: fittedHeight))
    }

    /// The panel's background.
    ///
    /// Liquid Glass refracts and tints what is behind the window, so the window
    /// itself has to stay see-through for it to have anything to work with —
    /// `isOpaque = false` and a clear `backgroundColor`, both set in `init`.
    ///
    /// The package deploys back to macOS 14, where there is no glass to ask
    /// for. `NSVisualEffectView`'s behind-window blur is the nearest thing that
    /// shipped, and every layout decision above holds either way.
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

        // Pinned explicitly in both branches. `NSGlassEffectView.contentView`
        // does place the view for us, but it promises nothing about how, and a
        // stack left at its fitting size inside a fixed-size window would sit
        // centred with the title row spilling past the glass.
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: backdrop.topAnchor),
            content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
        ])
        return backdrop
    }

    // MARK: - Photo picking

    /// Which of the three references a pick is filling.
    private enum PhotoSlot {
        case front, side, back

        var chosenTitle: String {
            switch self {
            case .front: "Front ✓"
            case .side: "Side ✓"
            case .back: "Back ✓"
            }
        }
    }

    /// The dialog has to clear this panel, which floats at `.statusBar`, and
    /// window levels are absolute — see the same note in `CoatWorkshopPanel`.
    private static let dialogLevel = NSWindow.Level(
        rawValue: NSWindow.Level.statusBar.rawValue + 1
    )

    /// Pick one reference photo and read it, without stopping the dog.
    ///
    /// Both halves used to block the main thread: `runModal` for as long as
    /// the user browsed, then `Data(contentsOf:)` on a full-resolution photo —
    /// three times over, once per slot. `begin` replaces the modal loop and
    /// the read happens on a detached task.
    ///
    /// The read failure is reported now rather than swallowed by a `try?`. A
    /// photo the app silently declined to load left the button unticked with
    /// no explanation at all.
    private func choosePhoto(for slot: PhotoSlot) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.level = Self.dialogLevel
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.readPhoto(at: url, into: slot)
        }
    }

    private func readPhoto(at url: URL, into slot: PhotoSlot) {
        Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                self?.accept(data, for: slot)
            } catch {
                self?.report(
                    "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    private func accept(_ data: Data, for slot: PhotoSlot) {
        switch slot {
        case .front:
            frontData = data
            frontButton.title = slot.chosenTitle
        case .side:
            sideData = data
            sideButton.title = slot.chosenTitle
        case .back:
            backData = data
            backButton.title = slot.chosenTitle
        }
        updateGenerateState()
    }

    @objc private func chooseFront() { choosePhoto(for: .front) }

    @objc private func chooseSide() { choosePhoto(for: .side) }

    @objc private func chooseBack() { choosePhoto(for: .back) }

    private func updateGenerateState() {
        generateButton.isEnabled = frontData != nil && sideData != nil && backData != nil && !isBusy
    }

    // MARK: - Actions

    @objc private func generateDog() {
        guard let frontData, let sideData, let backData, let generate else { return }
        setBusy(true)
        report("Starting… this can take a few minutes.")

        let photos = DogPhotos(front: frontData, side: sideData, back: backData)
        // Called from inside the pipeline, on whatever thread it is on.
        let onProgress: GenerationProgress = { [weak self] step in
            Task { @MainActor in self?.show(step) }
        }

        generateTask = Task { [weak self] in
            do {
                let preview = try await generate(photos, onProgress)
                // Cancelled in the gap between the last step finishing and
                // this line: the user asked to stop, so say so rather than
                // presenting a dog they had already given up on.
                if Task.isCancelled {
                    self?.finish(CancellationError())
                } else {
                    self?.previewView.image = NSImage(data: preview)
                    self?.previewView.imageScaling = .scaleProportionallyUpOrDown
                    self?.previewView.setAccessibilityLabel("Your generated dog, sitting idle")
                    self?.applyButton.isEnabled = true
                    self?.progressBar.doubleValue = self?.progressBar.maxValue ?? 0
                    self?.report("Done — click Apply to put him on screen.")
                }
            } catch {
                self?.finish(error)
            }
            self?.setBusy(false)
        }
    }

    /// One step of the run began.
    ///
    /// Half a step, not a whole one: the bar has to move the moment a step
    /// starts, or the longest step in the run — drawing him from the photos,
    /// which is the first — would sit at zero for a minute and read as
    /// nothing happening, which is the thing this replaced.
    private func show(_ step: GenerationStep) {
        guard isBusy else { return }
        progressBar.doubleValue = Double(step.number) - 0.5
        report("Step \(step.number) of \(GenerationStep.count): \(step.label)")
    }

    /// Cancelling is not a failure, and must not be reported as one.
    ///
    /// It arrives as either a `CancellationError` from the pipeline's own
    /// checks or a cancelled `URLError` from whichever request was in flight
    /// when the user pressed the button — both mean the same thing here.
    private func finish(_ error: Error) {
        let cancelled = error is CancellationError
            || (error as? URLError)?.code == .cancelled
        report(cancelled
            ? "Generation cancelled. Your photos are still here."
            : "Generation failed: \(error.localizedDescription)")
    }

    @objc private func cancelGeneration() {
        guard isBusy else { return }
        cancelButton.isEnabled = false
        report("Cancelling…")
        generateTask?.cancel()
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

    /// Write to the status line AND say it.
    ///
    /// Generation takes minutes and reports through a label that never takes
    /// focus, so a screen reader user who started it has no way to learn that
    /// it finished — or that it failed — short of going back and re-reading
    /// the panel on a hunch. Every outcome goes through here.
    private func report(_ message: String) {
        statusLabel.stringValue = message
        Accessibility.announce(message)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        progressBar.isHidden = !busy
        if !busy { progressBar.doubleValue = 0 }
        cancelButton.isHidden = !busy
        cancelButton.isEnabled = busy
        if !busy { generateTask = nil }
        frontButton.isEnabled = !busy
        sideButton.isEnabled = !busy
        backButton.isEnabled = !busy
        updateGenerateState()
    }

    /// Show the panel centred on the main screen.
    ///
    /// `orderFrontRegardless` keeps the no-focus-stealing behaviour for an app
    /// that has no Dock icon to activate through; `makeKey` then asks for the
    /// keyboard, which is what lets Escape close it. If the app is in the
    /// background the request simply goes unanswered until the user clicks in,
    /// which is the same moment the panel becomes key anyway.
    func present() {
        center()
        orderFrontRegardless()
        makeKey()
    }
}
