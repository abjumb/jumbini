import SpriteKit

/// The dog sprite: plays whatever animation the brain asks for in whichever
/// of the 8 directions he's heading, walks/runs to targets, and reports
/// arrival. Rendering only — no behavior decisions.
final class Dog: SKSpriteNode {
    /// Called when a `move(to:speed:)` completes.
    var onArrived: (() -> Void)?
    /// Called when the facing direction changes (used to re-seat a carried ball).
    var onFacingChanged: (() -> Void)?

    private(set) var facing: Facing = .south
    private var lastRequested: DogAnimation = .idle
    private var celebrating = false

    /// Tint fallback per animation if a sprite file is missing.
    private static let placeholderTints: [DogAnimation: NSColor] = [
        .idle: .systemOrange, .walk: .systemYellow, .run: .systemRed,
        .sit: .systemBlue, .lie: .systemPurple, .sleep: .systemGray,
        .spin: .systemGreen, .carryWalk: .systemBrown, .happy: .systemPink,
        .dangle: .systemTeal, .sniff: .systemIndigo, .hunch: .brown,
    ]

    init() {
        super.init(texture: nil, color: .systemOrange, size: CGSize(width: 96, height: 96))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Where a carried ball sits, relative to the dog (his mouth, roughly).
    var mouthOffset: CGPoint {
        let v = facing.unitVector
        return CGPoint(x: v.x * 30, y: v.y * 24 - 10)
    }

    /// A carried ball hides behind him when he faces away from the viewer.
    var mouthZOffset: CGFloat { facing.isNorthish ? -1 : 1 }

    /// Where a worn wardrobe item sits, relative to the dog (the crown of his
    /// head). Uses the live node size so the anchor tracks pose changes
    /// (sit art renders taller than idle) — positioning stays in code, never
    /// baked into the item art.
    var hatOffset: CGPoint {
        let v = renderedFacing.unitVector
        return CGPoint(x: v.x * 10, y: size.height * 0.32)
    }

    /// A worn item tucks behind him when he faces away from the viewer.
    var hatZOffset: CGFloat { renderedFacing.isNorthish ? -1 : 1 }

    /// The direction the art on screen ACTUALLY faces, which is not always the
    /// logical `facing`: the dangle pose always draws `sit_south`, and the
    /// bark/happy art only exists facing east (mirrored for westish facings).
    /// Wardrobe placement keys off this, so sunglasses don't vanish while he's
    /// dangling from the cursor looking straight at you.
    var renderedFacing: Facing {
        switch lastRequested {
        case .dangle:
            return .south
        case .happy, .bark:
            // Matches SpriteLibrary's mirror rule for the east-only bark art.
            return facing.unitVector.x < 0 ? .west : .east
        default:
            return facing
        }
    }

    // MARK: - Animation

    func play(_ animation: DogAnimation) {
        lastRequested = animation
        guard !celebrating else { return } // applied when the celebration ends
        apply(animation)
    }

    /// One-shot happy flourish that overlays the current animation briefly.
    func celebrate() { flourish(.happy, duration: 0.9) }

    /// One-shot touchdown absorb after a fall: he crumples for a moment, then
    /// picks up whatever the brain asked for next.
    func absorb() { flourish(.land, duration: 0.35) }

    /// Play `animation` over the top of the current one, then snap back to
    /// whatever `play(_:)` was last asked for (which may have changed while
    /// the flourish was running).
    private func flourish(_ animation: DogAnimation, duration: TimeInterval) {
        celebrating = true
        apply(animation)
        run(.sequence([
            .wait(forDuration: duration),
            .run { [weak self] in
                guard let self else { return }
                self.celebrating = false
                self.apply(self.lastRequested)
            },
        ]), withKey: "celebrate")
    }

    private func apply(_ animation: DogAnimation) {
        removeAction(forKey: "anim")
        if let anim = SpriteLibrary.shared.animation(for: animation, facing: facing) {
            size = anim.nodeSize
            xScale = anim.flipX ? -1 : 1
            yScale = 1
            if anim.textures.count == 1 {
                texture = anim.textures[0]
            } else {
                run(
                    .repeatForever(.animate(
                        with: anim.textures,
                        timePerFrame: 1 / anim.fps,
                        resize: false,
                        restore: false
                    )),
                    withKey: "anim"
                )
            }
        } else {
            texture = nil
            xScale = 1
            color = Self.placeholderTints[animation] ?? .systemOrange
        }
    }

    // MARK: - Movement

    func move(to point: CGPoint, speed: CGFloat) {
        face(towards: point)
        let distance = hypot(point.x - position.x, point.y - position.y)
        guard distance > 1 else {
            // Already there — make sure no stale in-flight move keeps driving
            // the node after we report arrival.
            removeAction(forKey: "move")
            onArrived?()
            return
        }
        let move = SKAction.move(to: point, duration: TimeInterval(distance / speed))
        let done = SKAction.run { [weak self] in self?.onArrived?() }
        run(.sequence([move, done]), withKey: "move")
    }

    /// A leap along an arc — the hop onto a window's top edge. Shares the
    /// "move" key with `move(to:speed:)`, so the two can never run at once
    /// and `stopMoving()` cancels either of them.
    func hop(to point: CGPoint, height: CGFloat, duration: TimeInterval) {
        face(towards: point)
        let start = position
        let arc = SKAction.customAction(withDuration: duration) { node, elapsed in
            let u = CGFloat(min(1, TimeInterval(elapsed) / duration))
            node.position = CGPoint(
                x: start.x + (point.x - start.x) * u,
                y: start.y + (point.y - start.y) * u + height * 4 * u * (1 - u)
            )
        }
        let done = SKAction.run { [weak self] in self?.onArrived?() }
        run(.sequence([arc, done]), withKey: "move")
    }

    func stopMoving() {
        removeAction(forKey: "move")
    }

    /// Turn towards a point: pick the matching 8-direction art.
    func face(towards point: CGPoint) {
        let newFacing = Facing.from(dx: point.x - position.x, dy: point.y - position.y)
        guard newFacing != facing else { return }
        facing = newFacing
        if !celebrating {
            apply(lastRequested)
        }
        onFacingChanged?()
    }
}
