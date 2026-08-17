import AppKit
import SpriteKit

/// One wearable. Two numbers, both meaningful: `slot` is the place on him
/// the piece hangs from, `frontWidth` is how wide the front view is on
/// screen in points (he stands ~115pt tall with a ~45pt-wide head).
///
/// Everything else is derived from the art: which of the four front
/// directions to draw, where the ink sits inside its canvas, the mirror
/// for the west side. The old per-item `dy`/`lift` nudges are gone — see
/// `SpriteLibrary.WardrobeArt` for why one number still has to stay.
struct WardrobeSpec {
    let title: String
    /// Catalog name; the files are `wardrobe_<item>_<direction>.png`.
    let item: String
    let slot: Dog.WearSlot
    let frontWidth: CGFloat
}

/// What Jumba can wear, and the rules for hanging it on him.
enum Wardrobe {
    /// The wardrobe catalog, menu order.
    static let items: [WardrobeSpec] = [
        WardrobeSpec(title: "Party Hat", item: "party", slot: .crown, frontWidth: 34),
        WardrobeSpec(title: "Top Hat", item: "tophat", slot: .crown, frontWidth: 40),
        WardrobeSpec(title: "Cowboy Hat", item: "cowboy", slot: .crown, frontWidth: 52),
        WardrobeSpec(title: "Beanie", item: "beanie", slot: .crown, frontWidth: 34),
        WardrobeSpec(title: "Bandana", item: "bandana", slot: .neck, frontWidth: 42),
        WardrobeSpec(title: "Sunglasses", item: "shades", slot: .eyes, frontWidth: 40),
        WardrobeSpec(title: "Raincoat", item: "raincoat", slot: .body, frontWidth: 54),
    ]

    /// UserDefaults key holding the catalog name of the current selection.
    static let defaultsKey = "wardrobeItem"

    /// How far a hat sinks past the crown line, as a fraction of its own
    /// height — otherwise it balances on his scalp instead of being worn.
    static let hatSink: CGFloat = 0.15

    /// The four front directions the art ships in, plus whether to mirror.
    /// There is deliberately no west-side art (same as the bark frames), and
    /// no straight-from-behind art either — the north-east three-quarter view
    /// reads correctly when he's walking away.
    static func direction(for facing: Facing) -> (key: String, mirrored: Bool) {
        switch facing {
        case .south: ("s", false)
        case .southEast: ("se", false)
        case .southWest: ("se", true)
        case .east: ("e", false)
        case .west: ("e", true)
        case .northEast, .north: ("ne", false)
        case .northWest: ("ne", true)
        }
    }
}

extension PetScene {
    func applyWardrobeItem(_ item: String?) {
        wornItem?.removeFromParent()
        wornItem = nil
        currentWardrobeItem = nil
        wornDirection = nil
        guard let item, Wardrobe.items.contains(where: { $0.item == item }) else {
            UserDefaults.standard.removeObject(forKey: Wardrobe.defaultsKey)
            return
        }
        let node = SKSpriteNode()
        dog.addChild(node)
        wornItem = node
        currentWardrobeItem = item
        UserDefaults.standard.set(item, forKey: Wardrobe.defaultsKey)
        reseatWornItem()
    }

    /// Keep the worn piece seated: swap in the art for whichever way he is
    /// rendered facing, then hang it off its slot on him. Called on every
    /// turn and every frame, because the anchor moves with his node size as
    /// well as his facing (sit art is taller than idle).
    ///
    /// The dog's own xScale (±1 — the bark art is mirrored art, not a turn)
    /// is divided back out of the child's position and scale, because a child
    /// inherits its parent's transform. Same gotcha as reseatCarriedRabbit().
    func reseatWornItem() {
        guard let node = wornItem, node.parent === dog,
              let spec = Wardrobe.items.first(where: { $0.item == currentWardrobeItem })
        else { return }
        // renderedFacing, not facing: the dangle and bark poses draw him
        // looking somewhere his logical facing disagrees with.
        let facing = dog.renderedFacing
        let direction = Wardrobe.direction(for: facing)
        guard let art = SpriteLibrary.shared.wardrobe(item: spec.item, direction: direction.key),
              let front = SpriteLibrary.shared.wardrobe(item: spec.item, direction: "s"),
              front.ink.width > 0
        else {
            node.isHidden = true
            return
        }
        node.isHidden = false
        if wornDirection != direction.key {
            wornDirection = direction.key
            node.texture = art.texture
        }

        // Points per art pixel, fixed per item by its front view, so the side
        // views come out narrower on their own instead of being stretched.
        // `wearScale` keeps the piece the same size on him across poses.
        let scale = spec.frontWidth / front.ink.width * dog.wearScale
        node.size = CGSize(width: art.canvas.width * scale, height: art.canvas.height * scale)

        // Where the ink sits inside the node, measured from the node centre.
        let inkX = (art.ink.midX - art.canvas.width / 2) * scale
        let inkCentreY = (art.canvas.height / 2 - art.ink.midY) * scale
        let inkBottomY = (art.canvas.height / 2 - art.ink.maxY) * scale

        let anchor = dog.wearAnchor(spec.slot)
        let flip: CGFloat = dog.xScale < 0 ? -1 : 1
        let mirror: CGFloat = direction.mirrored ? -1 : 1
        // A hat hangs by the bottom edge of its ink (the brim lands on his
        // crown); everything else hangs by the middle of its ink.
        let y = spec.slot == .crown
            ? anchor.y - art.ink.height * scale * Wardrobe.hatSink - inkBottomY
            : anchor.y - inkCentreY
        node.position = CGPoint(x: flip * (anchor.x - mirror * inkX), y: y)
        node.xScale = mirror * flip
        node.yScale = 1
        node.zPosition = dog.wearZOffset
    }

    func wardrobeSelectionMenu() -> NSMenu {
        let menu = NSMenu()
        let nothing = NSMenuItem(title: "Nothing", action: #selector(wardrobeChosen(_:)), keyEquivalent: "")
        nothing.target = self
        nothing.representedObject = ""
        nothing.state = currentWardrobeItem == nil ? .on : .off
        menu.addItem(nothing)
        menu.addItem(.separator())
        for spec in Wardrobe.items {
            let item = NSMenuItem(title: spec.title, action: #selector(wardrobeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec.item
            item.state = currentWardrobeItem == spec.item ? .on : .off
            // The real front-view art, at a common size: every piece is drawn
            // on the same 48x48 canvas, so they line up in the menu the way
            // they line up on the dog.
            if let url = Bundle.assets.url(
                forResource: "wardrobe_\(spec.item)_s", withExtension: "png", subdirectory: "sprites"
            ), let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 26, height: 26)
                item.image = image
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc func wardrobeChosen(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? String else { return }
        applyWardrobeItem(item.isEmpty ? nil : item)
    }
}
