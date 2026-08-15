import SpriteKit

/// The fetch ball: flies in a parabolic arc to the throw point, takes a couple
/// of small bounces, then rests until the dog picks it up.
final class Ball: SKSpriteNode {
    private(set) var isLanded = false
    /// Called when the ball comes to rest after its bounces.
    var onLanded: (() -> Void)?

    init() {
        let anim = SpriteLibrary.shared.prop(named: "ball", frameWidth: 8, fps: 10)
        super.init(
            texture: anim?.textures.first,
            color: .systemGreen,
            size: CGSize(width: 24, height: 24)
        )
        zPosition = 5
        if let anim {
            // Own key so flight-path changes (which clear "flight") don't kill it.
            run(.repeatForever(.animate(with: anim.textures, timePerFrame: 1 / anim.fps)),
                withKey: "spin")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func throwArc(from start: CGPoint, to landing: CGPoint) {
        removeAction(forKey: "flight")
        isLanded = false
        position = start
        isHidden = false

        let distance = hypot(landing.x - start.x, landing.y - start.y)
        let flightTime = max(0.35, min(0.9, TimeInterval(distance / 900)))
        let arcHeight = min(160, max(40, distance * 0.35))
        // Small bounces continuing in the throw direction.
        let dir: CGFloat = landing.x >= start.x ? 1 : -1
        let hop1End = CGPoint(x: landing.x + 24 * dir, y: landing.y)
        let hop2End = CGPoint(x: hop1End.x + 10 * dir, y: hop1End.y)

        run(.sequence([
            Self.parabola(from: start, to: landing, height: arcHeight, duration: flightTime),
            Self.parabola(from: landing, to: hop1End, height: 22, duration: 0.2),
            Self.parabola(from: hop1End, to: hop2End, height: 8, duration: 0.14),
            .run { [weak self] in
                guard let self else { return }
                self.isLanded = true
                self.onLanded?()
            },
        ]), withKey: "flight")
    }

    func fadeOutAndRemove() {
        removeAllActions()
        run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
    }

    /// Manual parabola: linear interpolation plus a 4u(1-u) vertical lift.
    private static func parabola(
        from start: CGPoint, to end: CGPoint, height: CGFloat, duration: TimeInterval
    ) -> SKAction {
        SKAction.customAction(withDuration: duration) { node, elapsed in
            let u = CGFloat(min(1, TimeInterval(elapsed) / duration))
            node.position = CGPoint(
                x: start.x + (end.x - start.x) * u,
                y: start.y + (end.y - start.y) * u + height * 4 * u * (1 - u)
            )
        }
    }
}
