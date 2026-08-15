import SpriteKit

/// A little thought bubble with an icon in it — the visible half of the
/// system-reactions feature.
///
/// SystemMonitor notices the machine got hot, the brain turns that into
/// zoomies, and all the user sees is a dog that suddenly lost his mind. One
/// of these floating over his head with a flame in it is the difference
/// between a bug and a joke.
///
/// Deliberately ignorant: it knows nothing about SystemSignal, or about why
/// it was asked for. The scene picks the icon; this just draws it. Modelled
/// on `PetScene.showHearts()` — appear, hold, drift up, fade, remove.
final class EmoteBubble: SKNode {
    /// Bubble side in points. He stands ~115pt tall, so this reads clearly
    /// over his head without covering him.
    private static let side: CGFloat = 46
    /// The icon's canvas, as a fraction of the bubble — the bubble art's
    /// clear interior is about 60% of its canvas, and the icons carry their
    /// own margin inside the 16x16 square.
    private static let iconFraction: CGFloat = 0.68
    /// The bubble's interior sits slightly above the canvas centre (the tail
    /// hangs off the bottom-left), so the icon rides up to match.
    private static let iconRise: CGFloat = 0.075
    /// How long it hangs there before drifting off.
    private static let hold: TimeInterval = 1.5

    /// Build a bubble around `icon` (a 16x16 file in Resources/sprites).
    /// Fails when either sprite is missing, so a missing icon is a missing
    /// bubble rather than a pink rectangle stuck to his ear.
    init?(icon: String) {
        guard
            let bubbleArt = SpriteLibrary.shared.singleProp(named: "emote_bubble"),
            let iconArt = SpriteLibrary.shared.singleProp(named: icon)
        else { return nil }
        super.init()

        let bubble = SKSpriteNode(texture: bubbleArt.textures[0])
        bubble.size = CGSize(width: Self.side, height: Self.side)
        addChild(bubble)

        let glyph = SKSpriteNode(texture: iconArt.textures[0])
        let glyphSide = Self.side * Self.iconFraction
        glyph.size = CGSize(width: glyphSide, height: glyphSide)
        glyph.position = CGPoint(x: 0, y: Self.side * Self.iconRise)
        glyph.zPosition = 1
        addChild(glyph)

        alpha = 0
        setScale(0.6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pop in, hold, float up and fade, then take itself off the scene.
    func play() {
        run(.sequence([
            .group([
                .fadeIn(withDuration: 0.12),
                .scale(to: 1, duration: 0.16),
            ]),
            .wait(forDuration: Self.hold),
            .group([
                .moveBy(x: 0, y: 34, duration: 0.5),
                .fadeOut(withDuration: 0.5),
            ]),
            .removeFromParent(),
        ]))
    }
}
