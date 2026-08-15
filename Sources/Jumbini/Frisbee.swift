import SpriteKit

/// The frisbee: where the ball is thrown hard and bounces, the disc floats.
/// A long, flat, slow arc with real hang time — that hang is what makes the
/// mid-air catch possible, so the flight is deliberately unhurried.
final class Frisbee: SKSpriteNode {
    private(set) var isLanded = false
    /// Called when the disc finishes its skid and comes to rest.
    var onLanded: (() -> Void)?

    /// Points per second of travel — well under the ball's ~900.
    private static let cruiseSpeed: CGFloat = 320
    private static let minFlight: TimeInterval = 0.9
    private static let maxFlight: TimeInterval = 2.2

    /// Alex's spin frames. frisbee_3 is deliberately absent — it was delivered
    /// as a dither smear rather than a disc; redraw it and this becomes 4.
    /// (Tools/import_kit_props.py has the matching note.)
    private static let spinFrames = 3

    init() {
        let anim = SpriteLibrary.shared.propSequence(named: "frisbee", frames: Self.spinFrames, fps: 14)
        super.init(
            texture: anim?.textures.first,
            color: .systemOrange,
            size: CGSize(width: 36, height: 36)
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
        let flightTime = max(
            Self.minFlight, min(Self.maxFlight, TimeInterval(distance / Self.cruiseSpeed))
        )
        // Flat: roughly a quarter of the ball's arc height, hard-capped low.
        let rise = min(46, max(14, distance * 0.09))
        // It doesn't bounce — it skids to a stop in the throw direction.
        let dir: CGFloat = landing.x >= start.x ? 1 : -1
        let skidEnd = CGPoint(x: landing.x + 26 * dir, y: landing.y)

        run(.sequence([
            Self.floatArc(from: start, to: landing, height: rise, duration: flightTime),
            Self.floatArc(from: landing, to: skidEnd, height: 4, duration: 0.3),
            .run { [weak self] in
                guard let self else { return }
                self.isLanded = true
                self.onLanded?()
            },
        ]), withKey: "flight")
    }

    /// Clamp the disc edge-on in his jaws: the spin stops and the art swaps
    /// to the single-frame mouth sprite.
    func clampInMouth() {
        removeAction(forKey: "flight")
        removeAction(forKey: "spin")
        guard let anim = SpriteLibrary.shared.singleProp(named: "frisbee_mouth"),
              let texture = anim.textures.first
        else { return }
        self.texture = texture
        // The mouth sprite is square art (the disc drawn edge-on inside the
        // frame), so the node keeps its shape — no squashing to a slab.
        size = CGSize(width: 36, height: 36)
    }

    func fadeOutAndRemove() {
        removeAllActions()
        run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
    }

    /// A floaty flight path: the horizontal travel eases out (the disc loses
    /// speed as it goes), the lift is a low sine hump rather than the ball's
    /// steep parabola, and a small ripple sells the wobble of real plastic.
    private static func floatArc(
        from start: CGPoint, to end: CGPoint, height: CGFloat, duration: TimeInterval
    ) -> SKAction {
        SKAction.customAction(withDuration: duration) { node, elapsed in
            let u = CGFloat(min(1, TimeInterval(elapsed) / duration))
            let glide = pow(u, 0.85) // decelerating travel
            let hump = sin(.pi * pow(u, 0.9)) * height
            let wobble = sin(u * 6 * .pi) * 2 * (1 - u)
            node.position = CGPoint(
                x: start.x + (end.x - start.x) * glide,
                y: start.y + (end.y - start.y) * glide + hump + wobble
            )
        }
    }
}
