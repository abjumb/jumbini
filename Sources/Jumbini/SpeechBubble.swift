import AppKit
import SpriteKit

/// What Jumba says about a machine signal.
///
/// The words live here rather than in `DogBrain` on purpose: the brain has no
/// UI in it and no user-facing text, and `DogEffect` is deliberately
/// signal-agnostic — by the time the effects come back, nothing in them says
/// WHY he did that. `PetScene.receive(_:)` is the one place that still knows
/// the signal's name, so that is where the caption is chosen.
///
/// The switch is exhaustive over `SystemSignal` with no `default`, so a signal
/// added later is a compile error rather than a dog who silently says nothing
/// about it.
enum ReactionCaption {
    /// A short line of text, or `nil` for "say nothing at all".
    ///
    /// - Parameter acted: whether the brain acted on the signal or parked it.
    ///   Parked news is worth saying so about; an all-clear that roused nobody
    ///   is not worth saying anything about.
    static func text(for signal: SystemSignal, acted: Bool) -> String? {
        switch signal {
        case .buildFinished: acted ? "Build's done!" : busy
        case .fansUp: acted ? "Your Mac's hot!" : busy
        case .batteryLow: acted ? "Battery's low…" : busy
        case .dndOn: acted ? "Focus on. Shh." : busy
        case .idleBegan: acted ? "You've been gone a while…" : busy
        // The all-clear signals. Silent unless they genuinely got him up,
        // which is exactly what the icon version did.
        case .idleEnded: acted ? "You're back!" : nil
        case .batteryNormal: acted ? "Charging again!" : nil
        case .dndOff: acted ? "Focus off!" : nil
        }
    }

    /// News that arrived while he was mid-fetch. The brain parks it
    /// (`deferSignal`) and comes back to it; this is the dog admitting so.
    private static let busy = "Busy — one sec!"
}

/// A speech bubble with a short line of text in it — the spoken half of the
/// system-reactions feature.
///
/// `EmoteBubble` is the older, iconographic sibling and is still used for the
/// `icon_question` shrug when a command is refused. This one exists because an
/// icon cannot say WHY: a flame over his head means the machine got hot only if
/// you already knew that is what the flame meant.
///
/// Deliberately ignorant, like `EmoteBubble`: it knows nothing about
/// `SystemSignal` or about why it was asked for. The scene picks the words.
final class SpeechBubble: SKNode {
    /// Widest the bubble gets before the text wraps. He stands ~115pt tall, so
    /// much more than this stops being a bubble over a dog and starts being a
    /// dialog box with a dog under it.
    static let maxWidth: CGFloat = 180
    private static let fontSize: CGFloat = 11
    private static let padX: CGFloat = 10
    private static let padY: CGFloat = 7
    private static let corner: CGFloat = 9
    private static let tail: CGFloat = 7

    /// How long the bubble hangs there before drifting off. Scaled to the
    /// length of the line so a longer caption is actually readable, and capped
    /// so he never blocks the screen for an awkwardly long time.
    static func hold(for text: String) -> TimeInterval {
        min(1.4 + 0.05 * Double(text.count), 3.2)
    }

    /// The plate's actual width, at the scale it settles at once `play()`
    /// pops it in — NOT the scale it starts at.
    ///
    /// `init` ends by calling `setScale(0.6)` for the pop-in, and
    /// `calculateAccumulatedFrame()` reports a node's frame in its PARENT's
    /// coordinate system, which folds in whatever scale the node currently
    /// has. Measuring `self` right after construction would therefore measure
    /// the bubble at 60% of its real size — wrong for anything that needs to
    /// know how wide it actually is, like the edge clamp in
    /// `PetScene.showSpeech`. Stored here instead, at the width the plate was
    /// built to, before scale ever entered the picture.
    let plateWidth: CGFloat

    private let text: String

    init(text: String) {
        self.text = text

        let label = SKLabelNode(fontNamed: Self.fontName)
        label.text = text
        label.fontSize = Self.fontSize
        label.fontColor = NSColor(white: 0.1, alpha: 1)
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = Self.maxWidth - Self.padX * 2
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.zPosition = 1

        // Size the bubble to the text, not the other way round: "Focus off!"
        // in a 180pt plate would read as a missing string.
        let textSize = label.calculateAccumulatedFrame().size
        let width = min(textSize.width + Self.padX * 2, Self.maxWidth)
        let height = textSize.height + Self.padY * 2
        self.plateWidth = width

        super.init()

        let plate = SKShapeNode(
            rect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
            cornerRadius: Self.corner
        )
        plate.fillColor = NSColor(white: 0.98, alpha: 0.96)
        plate.strokeColor = NSColor(white: 0.35, alpha: 0.9)
        plate.lineWidth = 1
        addChild(plate)

        // A small tail so it reads as speech rather than a floating label.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -Self.tail, y: -height / 2 + 1))
        path.addLine(to: CGPoint(x: 0, y: -height / 2 - Self.tail))
        path.addLine(to: CGPoint(x: Self.tail, y: -height / 2 + 1))
        path.closeSubpath()
        let tailNode = SKShapeNode(path: path)
        tailNode.fillColor = plate.fillColor
        tailNode.strokeColor = plate.strokeColor
        tailNode.lineWidth = 1
        addChild(tailNode)

        addChild(label)

        alpha = 0
        setScale(0.6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pop in, hold, float up and fade, then take itself off the scene.
    /// The same choreography as `EmoteBubble`, so the two never look like
    /// different features.
    func play() {
        run(.sequence([
            .group([
                .fadeIn(withDuration: 0.12),
                .scale(to: 1, duration: 0.16),
            ]),
            .wait(forDuration: Self.hold(for: text)),
            .group([
                .moveBy(x: 0, y: 34, duration: 0.5),
                .fadeOut(withDuration: 0.5),
            ]),
            .removeFromParent(),
        ]))
    }

    /// The rounded system font, with Menlo and then the plain system font as
    /// fallbacks — the same ladder `PetScene.camCaptionFont` climbs, so the
    /// bubble and the cam caption are recognisably the same voice. No pixel
    /// font is bundled in the app and none is added for this.
    private static let fontName: String = {
        let system = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        if let rounded = system.fontDescriptor.withDesign(.rounded),
           let font = NSFont(descriptor: rounded, size: fontSize) {
            return font.fontName
        }
        return NSFont(name: "Menlo", size: fontSize)?.fontName ?? system.fontName
    }()
}
