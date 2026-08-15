import SpriteKit

/// The tug rope: a knotted cap at the dog's end, a knotted cap at the free
/// end the user grabs, and as many tiling middle segments as it takes to
/// span the gap. Re-laid every frame while it's being pulled, so it stays a
/// straight line between two moving points.
final class TugRope: SKNode {
    /// Length of one segment along the rope, in points.
    static let segmentLength: CGFloat = 16
    private static let thickness: CGFloat = 20

    private let dogCap: SKSpriteNode
    private let freeCap: SKSpriteNode
    private var middles: [SKSpriteNode] = []

    /// Where the free end currently is (the grab point).
    private(set) var freeEnd: CGPoint = .zero

    override init() {
        dogCap = Self.piece(named: "rope_left")
        freeCap = Self.piece(named: "rope_right")
        super.init()
        zPosition = 6 // above furniture, below the dog
        dogCap.zPosition = 1
        freeCap.zPosition = 1
        addChild(dogCap)
        addChild(freeCap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func piece(named name: String) -> SKSpriteNode {
        let size = CGSize(width: segmentLength, height: thickness)
        if let anim = SpriteLibrary.shared.singleProp(named: name) {
            let node = SKSpriteNode(texture: anim.textures[0])
            node.size = size
            return node
        }
        return SKSpriteNode(color: .brown, size: size)
    }

    /// Stretch the rope between the dog's end and the free end.
    func layout(from anchor: CGPoint, to end: CGPoint) {
        freeEnd = end
        let dx = end.x - anchor.x
        let dy = end.y - anchor.y
        let length = max(hypot(dx, dy), Self.segmentLength * 2)
        let angle = atan2(dy, dx)
        let ux = cos(angle)
        let uy = sin(angle)
        let half = Self.segmentLength / 2

        dogCap.position = CGPoint(x: anchor.x + ux * half, y: anchor.y + uy * half)
        dogCap.zRotation = angle
        freeCap.position = CGPoint(x: end.x - ux * half, y: end.y - uy * half)
        freeCap.zRotation = angle

        // Even spacing across the gap: the step never exceeds one segment, so
        // consecutive middles butt together (or overlap a hair) — no gaps.
        let span = max(0, length - Self.segmentLength * 2)
        let count = Int(ceil(span / Self.segmentLength))
        growMiddles(to: count)
        let step = count > 0 ? span / CGFloat(count) : 0
        for (index, segment) in middles.enumerated() {
            guard index < count else {
                segment.isHidden = true
                continue
            }
            segment.isHidden = false
            let along = Self.segmentLength + step * (CGFloat(index) + 0.5)
            segment.position = CGPoint(x: anchor.x + ux * along, y: anchor.y + uy * along)
            segment.zRotation = angle
        }
    }

    /// Hit region for the free end — generous, it's a grab target.
    func freeEndFrame() -> CGRect {
        CGRect(x: freeEnd.x - 16, y: freeEnd.y - 16, width: 32, height: 32)
    }

    func fadeOutAndRemove() {
        removeAllActions()
        run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
    }

    private func growMiddles(to count: Int) {
        while middles.count < count {
            let segment = Self.piece(named: "rope_mid")
            segment.zPosition = 0
            addChild(segment)
            middles.append(segment)
        }
    }
}
