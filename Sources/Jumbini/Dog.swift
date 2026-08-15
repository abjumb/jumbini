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
        let v = facing.unitVector
        return CGPoint(x: v.x * 10, y: size.height * 0.32)
    }

    /// A worn item tucks behind him when he faces away from the viewer.
    var hatZOffset: CGFloat { facing.isNorthish ? -1 : 1 }

    // MARK: - Animation

    func play(_ animation: DogAnimation) {
        lastRequested = animation
        guard !celebrating else { return } // applied when the celebration ends
        apply(animation)
    }

    /// One-shot happy flourish that overlays the current animation briefly.
    func celebrate() {
        celebrating = true
        apply(.happy)
        run(.sequence([
            .wait(forDuration: 0.9),
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
