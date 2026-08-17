import AppKit
import SpriteKit

/// The beds Jumba can be given, and where the choice is remembered.
///
/// Data only. Everything that puts one on screen lives in the `PetScene`
/// extension below, because it needs the scene's bed node.
enum BedCatalog {
    /// The imported bed catalog (Resources/sprites/bedvar_N.png), menu order.
    static let variants: [(name: String, file: String)] = [
        ("Classic Bolster", "bedvar_1"),
        ("Round Cushion", "bedvar_2"),
        ("Cozy Tub", "bedvar_3"),
        ("Navy Lounger", "bedvar_4"),
        ("Fuzzy Donut", "bedvar_5"),
        ("Speckled Cushion", "bedvar_6"),
        ("Sherpa Tub", "bedvar_7"),
        ("Flat Mat", "bedvar_8"),
        ("Shaggy Donut", "bedvar_9"),
        ("Car Seat", "bedvar_10"),
        ("Corduroy Tub", "bedvar_11"),
        ("Wicker Basket", "bedvar_12"),
    ]

    /// UserDefaults key holding the chosen index; absent means the built-in bed.
    static let defaultsKey = "bedVariant"
}

extension PetScene {
    /// Swap the bed art. `nil` puts the built-in fuzzy bed back and forgets the
    /// stored choice.
    func applyBedVariant(_ index: Int?) {
        currentBedVariant = index
        if let index, let anim = SpriteLibrary.shared.singleProp(named: BedCatalog.variants[index].file) {
            bed.texture = anim.textures[0]
            bed.size = anim.nodeSize
            UserDefaults.standard.set(index, forKey: BedCatalog.defaultsKey)
        } else {
            if let anim = SpriteLibrary.shared.prop(named: "bed", frameWidth: 52, fps: 1) {
                bed.texture = anim.textures[0]
                bed.size = anim.nodeSize
            }
            UserDefaults.standard.removeObject(forKey: BedCatalog.defaultsKey)
        }
    }

    /// Right-clicking the bed offers the catalog, each row showing the bed it
    /// installs.
    func bedSelectionMenu() -> NSMenu {
        let menu = NSMenu()
        let classic = NSMenuItem(title: "Classic Fuzzy (built-in)", action: #selector(bedChosen(_:)), keyEquivalent: "")
        classic.target = self
        classic.representedObject = -1
        classic.state = currentBedVariant == nil ? .on : .off
        menu.addItem(classic)
        menu.addItem(.separator())
        for (index, variant) in BedCatalog.variants.enumerated() {
            let item = NSMenuItem(title: variant.name, action: #selector(bedChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.state = currentBedVariant == index ? .on : .off
            if let url = Bundle.assets.url(forResource: variant.file, withExtension: "png", subdirectory: "sprites"),
               let image = NSImage(contentsOf: url) {
                let height: CGFloat = 30
                image.size = NSSize(width: image.size.width / image.size.height * height, height: height)
                item.image = image
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc func bedChosen(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        applyBedVariant(index >= 0 ? index : nil)
    }
}
