import SpriteKit

/// How the rope behaves when someone hauls on it.
///
/// The whole feel of tug-of-war is in these eight numbers: how much of the
/// pull the rope concedes, how springily the free end chases the cursor, and
/// how often he yanks it back.
enum Tug {
    /// How much of the user's pull the rope actually gives up. Under 1 means
    /// the free end never reaches the cursor: the gap IS the resistance, and
    /// the harder you pull the further behind your cursor the rope sits.
    static let resistGain: CGFloat = 0.55
    /// Spring rate of the free end chasing its resisted target (per second).
    /// Low enough to feel elastic, high enough not to feel broken.
    static let springRate: CGFloat = 11
    /// Rope length at rest, and how much further you can stretch it before
    /// `force` reads as a maximum-effort pull.
    static let ropeRestLength: CGFloat = 140
    static let ropePullSpan: CGFloat = 220
    /// Yanks: a hard pull back toward him, roughly this often, this far.
    static let yankInterval: ClosedRange<TimeInterval> = 0.9...1.7
    static let yankDuration: TimeInterval = 0.26
    static let yankDistance: CGFloat = 34
    /// Past this much of a pull (0...1) the rope is drawn strained.
    static let tautForce: CGFloat = 0.5
    /// How often the brain hears about the pull, in seconds (~10/s). The
    /// strain is redrawn every frame regardless — see `stepTug`.
    static let sendInterval: TimeInterval = 0.1
}

extension PetScene {
    /// The dog's end of the rope — his mouth, in scene coordinates.
    func ropeAnchor() -> CGPoint {
        CGPoint(x: dog.position.x + dog.mouthOffset.x, y: dog.position.y + dog.mouthOffset.y)
    }

    /// Toys > Tug Rope: the rope lands in front of him, free end out. No
    /// brain event yet — the game starts when the user grabs that end.
    func dropTugRope() {
        rope?.removeFromParent()
        draggingRope = false
        carryingRope = false
        let rope = TugRope()
        addChild(rope)
        self.rope = rope

        let anchor = ropeAnchor()
        let v = dog.facing.unitVector
        let margin: CGFloat = 30
        ropeEnd = layout.clamp(CGPoint(
            x: min(max(anchor.x + v.x * Tug.ropeRestLength, margin), size.width - margin),
            y: min(max(anchor.y + v.y * Tug.ropeRestLength, margin), size.height - margin)
        ), inset: margin)
        ropePull = ropeEnd
        rope.layout(from: anchor, to: ropeEnd)
        settleRope()
    }

    /// A rope nobody is holding lies there a while, then tidies itself away.
    /// Grabbing it again cancels the countdown (see `mouseDown`).
    func settleRope() {
        guard let rope else { return }
        rope.removeAction(forKey: "linger")
        rope.alpha = 1
        rope.run(.sequence([
            .wait(forDuration: Self.toyLingerDuration * 2),
            .fadeOut(withDuration: 0.6),
            .run { [weak self] in self?.rope = nil },
            .removeFromParent(),
        ]), withKey: "linger")
    }

    /// Per-frame rope work: resist the pull, throw the occasional yank, keep
    /// him facing whoever is pulling, and feed the brain a throttled force.
    func stepTug(dt: TimeInterval) {
        guard let rope else { return }
        let anchor = ropeAnchor()

        if carryingRope {
            // Victory lap: it trails behind him as he swaggers off. Nobody is
            // pulling any more, so it hangs slack.
            rope.setTaut(false)
            let v = dog.facing.unitVector
            ropeEnd = CGPoint(
                x: anchor.x - v.x * Tug.ropeRestLength * 0.8,
                y: anchor.y - v.y * Tug.ropeRestLength * 0.8
            )
            rope.layout(from: anchor, to: ropeEnd)
            return
        }
        guard draggingRope, dt > 0 else { return }

        // Resisted target: only a fraction of the pull is conceded.
        var target = CGPoint(
            x: anchor.x + (ropePull.x - anchor.x) * Tug.resistGain,
            y: anchor.y + (ropePull.y - anchor.y) * Tug.resistGain
        )

        // A yank drags the end back toward him for a fraction of a second.
        if lastTime >= nextYank {
            yankPhase = 1
            nextYank = lastTime + TimeInterval.random(in: Tug.yankInterval)
        }
        if yankPhase > 0 {
            yankPhase = max(0, yankPhase - CGFloat(dt / Tug.yankDuration))
            let pulse = sin(.pi * (1 - yankPhase)) * Tug.yankDistance
            let dx = target.x - anchor.x
            let dy = target.y - anchor.y
            let length = max(hypot(dx, dy), 1)
            target = CGPoint(x: target.x - dx / length * pulse, y: target.y - dy / length * pulse)
        }

        // Springy follow, so the rope arrives at the target with some give.
        let ease = min(1, CGFloat(dt) * Tug.springRate)
        ropeEnd = CGPoint(
            x: ropeEnd.x + (target.x - ropeEnd.x) * ease,
            y: ropeEnd.y + (target.y - ropeEnd.y) * ease
        )
        rope.layout(from: anchor, to: ropeEnd)
        dog.face(towards: ropeEnd) // brace against the pull

        // Every frame, not on the throttled send: the strain is what the user
        // is watching while they haul, and it should track their arm.
        let force = tugForce()
        rope.setTaut(force >= Tug.tautForce)
        if lastTime - lastTugSent >= Tug.sendInterval {
            lastTugSent = lastTime
            send(.tugMoved(to: ropeEnd, force: force))
        }
    }

    /// How hard they're pulling, 0...1: slack rope reads 0, an arm's-length
    /// haul reads 1.
    private func tugForce() -> CGFloat {
        let anchor = ropeAnchor()
        let stretch = hypot(ropePull.x - anchor.x, ropePull.y - anchor.y) - Tug.ropeRestLength
        return min(1, max(0, stretch / (Tug.ropePullSpan - Tug.ropeRestLength)))
    }

    /// `.startTug`: the brain accepted the grab.
    func beginTug() {
        nextYank = lastTime + TimeInterval.random(in: Tug.yankInterval)
        yankPhase = 0
        lastTugSent = lastTime
        rope?.removeAction(forKey: "linger")
        rope?.alpha = 1
    }

    /// `.stopTug`: the game is over however it ended. The user's drag is
    /// dropped on the spot — a won rope is his now, and there's nothing left
    /// to waggle.
    func endTug() {
        draggingRope = false
        yankPhase = 0
        rope?.setTaut(false)
    }

    func removeRope() {
        carryingRope = false
        draggingRope = false
        rope?.fadeOutAndRemove()
        rope = nil
    }
}
