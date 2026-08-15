import CoreGraphics
import SpriteKit

/// The transparent scene the dog lives in. Owns per-frame mouse polling and
/// the click-through toggle, routes interactions to the brain, and applies
/// the brain's effects to the sprites.
final class PetScene: SKScene {
    weak var overlayWindow: NSWindow?

    private let dog = Dog()
    private var ball: Ball?

    // The toy box: one node per toy, nil when that toy isn't out.
    private var frisbee: Frisbee?
    private var brain: DogBrain!
    private var lastTime: TimeInterval = 0

    // Furniture.
    private var bed: SKSpriteNode!
    private var jar: SKSpriteNode!

    // Treats.
    private var treatInHand: SKSpriteNode?
    private var groundTreat: SKSpriteNode?

    // Deposits (oldest first). He is a machine: treats in, piles out.
    private var piles: [SKSpriteNode] = []
    private var draggedPile: SKSpriteNode?

    /// Trick progression, persisted under "trick.<name>.reps" / ".unlocked".
    private let trickTrainer = TrickTrainer(store: UserDefaultsTrickStore())

    // Zoomies: manual bounce integration; nil while he isn't zooming.
    private var zoomiesVelocity: CGPoint?
    /// The fur rabbit he carries during zoomies (a child of the dog).
    private var rabbit: SKSpriteNode?

    /// The wardrobe item he's wearing (a child of the dog); nil = nothing.
    private var wornItem: SKSpriteNode?
    /// Sprite file of the current wardrobe selection (mirrors UserDefaults).
    private var currentWardrobeFile: String?

    // Mouse sniffing: he tracks the cursor while the brain's timer runs.
    private var isSniffing = false
    /// Near/far sub-state so walk/sniff anims only switch on transitions.
    private var sniffingClose = false

    // Hover-to-provoke: linger over the dog long enough and he barks at you.
    /// When the cursor entered the dog's hover frame (nil while it's outside).
    private var hoverStart: TimeInterval?
    /// Continuous hover time that counts as a provocation.
    private static let hoverProvokeDelay: TimeInterval = 1.5

    /// Cached sound effects by name (Resources/audio/<name>.wav).
    private var soundCache: [String: NSSound] = [:]

    /// Fetch was chosen: the next left-click anywhere throws the ball.
    private var armedForThrow = false
    /// Which toy the armed throw will launch; nil = the fetch ball.
    private var armedToy: ToyKind?
    /// Dog arrived at the landing spot before the ball finished bouncing.
    private var pendingChaseArrival = false

    // Click-vs-drag disambiguation.
    private var mouseDownOnDog = false
    private var isCarryingDog = false
    private var draggedFurniture: SKSpriteNode?
    /// A plain press started on the jar: click = take a treat, drag = move the jar.
    private var pressedJar = false
    /// Where the current press started (drag threshold is measured from here).
    private var pressLocation: CGPoint = .zero
    /// Keeps the grab point under the cursor while carrying (no center-snap).
    private var carryGrabOffset: CGPoint = .zero

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        bed = Self.propNode(named: "bed", frameWidth: 52, fallbackColor: .systemBlue,
                            fallbackSize: CGSize(width: 156, height: 96))
        bed.position = CGPoint(x: size.width - 240, y: 150)
        bed.zPosition = 2
        addChild(bed)
        if let stored = UserDefaults.standard.object(forKey: Self.bedVariantKey) as? Int,
           Self.bedVariants.indices.contains(stored) {
            applyBedVariant(stored)
        }

        jar = Self.propNode(named: "jar", frameWidth: 22, fallbackColor: .systemGray,
                            fallbackSize: CGSize(width: 66, height: 78))
        jar.position = CGPoint(x: size.width - 70, y: 145)
        jar.zPosition = 6
        addChild(jar)

        dog.position = CGPoint(x: size.width / 2, y: size.height / 2)
        dog.zPosition = 10
        addChild(dog)
        dog.onArrived = { [weak self] in self?.dogArrived() }
        dog.onFacingChanged = { [weak self] in
            self?.reseatCarriedBall()
            self?.reseatCarriedRabbit()
            self?.reseatCarriedToy()
            self?.reseatWornItem()
        }
        if let stored = UserDefaults.standard.string(forKey: Self.wardrobeItemKey) {
            applyWardrobeItem(stored)
        }

        brain = DogBrain(bounds: size, position: dog.position)
        brain.bedPosition = bedLieSpot()
        apply(effects: [.play(.idle)])
    }

    private static func propNode(
        named name: String, frameWidth: Int, fallbackColor: NSColor, fallbackSize: CGSize
    ) -> SKSpriteNode {
        if let anim = SpriteLibrary.shared.prop(named: name, frameWidth: frameWidth, fps: 1) {
            let node = SKSpriteNode(texture: anim.textures[0])
            node.size = anim.nodeSize
            return node
        }
        return SKSpriteNode(color: fallbackColor, size: fallbackSize)
    }

    /// Where the dog settles when lying in the bed: centered on the cushion.
    private func bedLieSpot() -> CGPoint {
        CGPoint(x: bed.position.x, y: bed.position.y + 6)
    }

    // MARK: - Bed variants

    /// The imported bed catalog (Resources/sprites/bedvar_N.png), menu order.
    private static let bedVariants: [(name: String, file: String)] = [
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
    private static let bedVariantKey = "bedVariant"
    /// nil = the built-in fuzzy bed.
    private var currentBedVariant: Int?

    private func applyBedVariant(_ index: Int?) {
        currentBedVariant = index
        if let index, let anim = SpriteLibrary.shared.singleProp(named: Self.bedVariants[index].file) {
            bed.texture = anim.textures[0]
            bed.size = anim.nodeSize
            UserDefaults.standard.set(index, forKey: Self.bedVariantKey)
        } else {
            if let anim = SpriteLibrary.shared.prop(named: "bed", frameWidth: 52, fps: 1) {
                bed.texture = anim.textures[0]
                bed.size = anim.nodeSize
            }
            UserDefaults.standard.removeObject(forKey: Self.bedVariantKey)
        }
    }

    private func bedSelectionMenu() -> NSMenu {
        let menu = NSMenu()
        let classic = NSMenuItem(title: "Classic Fuzzy (built-in)", action: #selector(bedChosen(_:)), keyEquivalent: "")
        classic.target = self
        classic.representedObject = -1
        classic.state = currentBedVariant == nil ? .on : .off
        menu.addItem(classic)
        menu.addItem(.separator())
        for (index, variant) in Self.bedVariants.enumerated() {
            let item = NSMenuItem(title: variant.name, action: #selector(bedChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.state = currentBedVariant == index ? .on : .off
            if let url = Bundle.module.url(forResource: variant.file, withExtension: "png", subdirectory: "sprites"),
               let image = NSImage(contentsOf: url) {
                let height: CGFloat = 30
                image.size = NSSize(width: image.size.width / image.size.height * height, height: height)
                item.image = image
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func bedChosen(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        applyBedVariant(index >= 0 ? index : nil)
    }

    // MARK: - Wardrobe

    /// Wardrobe catalog, menu order. Seating is per-item because the pieces
    /// live at different heights: `dy` shifts the crown anchor by a fraction
    /// of the dog's height (negative = down towards face/neck), `lift` raises
    /// by a fraction of the item's own height (so hats perch on the head
    /// instead of swallowing it). All placement lives here, not in the art,
    /// so the placeholder sprites can swap for real 48x48 art untouched.
    private static let wardrobeItems:
        [(title: String, file: String, dy: CGFloat, lift: CGFloat, isEyewear: Bool)] = [
            ("Party Hat", "wardrobe_partyhat", 0, 0.30, false),
            ("Top Hat", "wardrobe_tophat", 0, 0.30, false),
            ("Cowboy Hat", "wardrobe_cowboyhat", 0.02, 0.10, false),
            ("Bandana", "wardrobe_bandana", -0.34, 0, false),
            ("Sunglasses", "wardrobe_sunglasses", -0.10, 0, true),
        ]
    private static let wardrobeItemKey = "wardrobeItem"

    private func applyWardrobeItem(_ file: String?) {
        wornItem?.removeFromParent()
        wornItem = nil
        currentWardrobeFile = nil
        guard let file, Self.wardrobeItems.contains(where: { $0.file == file }) else {
            UserDefaults.standard.removeObject(forKey: Self.wardrobeItemKey)
            return
        }
        let node: SKSpriteNode
        if let anim = SpriteLibrary.shared.singleProp(named: file) {
            node = SKSpriteNode(texture: anim.textures[0])
            node.size = anim.nodeSize
        } else {
            node = SKSpriteNode(color: .systemPink, size: CGSize(width: 36, height: 24))
        }
        dog.addChild(node)
        wornItem = node
        currentWardrobeFile = file
        UserDefaults.standard.set(file, forKey: Self.wardrobeItemKey)
        reseatWornItem()
    }

    /// Keep the worn item seated as he turns and as his node size changes
    /// between poses (sit art is taller than idle). The dog's own xScale
    /// (±1, mirrored bark art) is divided back out because a child node
    /// inherits its parent's scale — same gotcha as reseatCarriedRabbit().
    private func reseatWornItem() {
        guard let item = wornItem, item.parent === dog,
              let spec = Self.wardrobeItems.first(where: { $0.file == currentWardrobeFile })
        else { return }
        let parentFlip: CGFloat = dog.xScale < 0 ? -1 : 1
        let anchor = dog.hatOffset
        item.position = CGPoint(
            x: anchor.x * parentFlip,
            y: anchor.y + spec.dy * dog.size.height + spec.lift * item.size.height
        )
        item.zPosition = dog.hatZOffset
        // Facing away, glasses would float on the back of his head — hide
        // them; hats and the bandana still read and just tuck behind (-1).
        // renderedFacing, not facing: the dangle/bark poses draw him facing
        // somewhere his logical facing disagrees with.
        item.isHidden = spec.isEyewear && dog.renderedFacing.isNorthish
        // Any lean in the art follows the facing (and cancels the parent flip).
        let westish = dog.renderedFacing.unitVector.x < 0
        item.xScale = (westish ? -1 : 1) * parentFlip
    }

    private func wardrobeSelectionMenu() -> NSMenu {
        let menu = NSMenu()
        let nothing = NSMenuItem(title: "Nothing", action: #selector(wardrobeChosen(_:)), keyEquivalent: "")
        nothing.target = self
        nothing.representedObject = ""
        nothing.state = currentWardrobeFile == nil ? .on : .off
        menu.addItem(nothing)
        menu.addItem(.separator())
        for spec in Self.wardrobeItems {
            let item = NSMenuItem(title: spec.title, action: #selector(wardrobeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec.file
            item.state = currentWardrobeFile == spec.file ? .on : .off
            if let url = Bundle.module.url(forResource: spec.file, withExtension: "png", subdirectory: "sprites"),
               let image = NSImage(contentsOf: url) {
                // x2, not a fixed height: the items' aspects vary too much.
                image.size = NSSize(width: image.size.width * 2, height: image.size.height * 2)
                item.image = image
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func wardrobeChosen(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String else { return }
        applyWardrobeItem(file.isEmpty ? nil : file)
    }

    // MARK: - Frame loop

    override func update(_ currentTime: TimeInterval) {
        // Frame delta for the manual movers (zoomies bounce, cursor sniffing),
        // capped so a stalled frame can't teleport him.
        let dt = lastTime == 0 ? 0 : min(currentTime - lastTime, 0.1)
        lastTime = currentTime
        brain.bounds = size
        stepZoomies(dt: dt)
        stepSniffing(dt: dt)
        brain.position = dog.position
        stepFrisbeeCatch()
        send(.tick)
        trackHover(at: currentTime)
        // Every frame (cheap): the anchor depends on the dog's node size,
        // which changes with the pose (sit vs idle), not just the facing.
        reseatWornItem()
        updateClickThrough()
    }

    /// A cursor lingering over the dog for a while counts as a provocation.
    /// Resets after firing — the brain's bark cooldown governs repeats.
    private func trackHover(at now: TimeInterval) {
        // A press/drag on him is interaction, not loitering.
        guard dogHoverFrame().contains(mouseLocationInScene()),
              !mouseDownOnDog, !isCarryingDog else {
            hoverStart = nil
            return
        }
        guard let start = hoverStart else {
            hoverStart = now
            return
        }
        if now - start >= Self.hoverProvokeDelay {
            hoverStart = nil
            send(.provoked(at: mouseLocationInScene()))
        }
    }

    /// Route an event to the brain and apply what comes back.
    private func send(_ event: DogEvent) {
        apply(effects: brain.handle(event, at: lastTime))
    }

    private func dogArrived() {
        if brain.state == .chasingBall, let ball, !ball.isLanded {
            // Fast dog: wait for the ball to stop bouncing before the pickup.
            pendingChaseArrival = true
            return
        }
        if brain.state == .chasingFrisbee, let frisbee, !frisbee.isLanded {
            // He beat the disc to the landing spot without catching it —
            // wait for it to settle, then grab it off the ground.
            pendingChaseArrival = true
            return
        }
        send(.arrived)
    }

    // MARK: - Effects

    private func apply(effects: [DogEffect]) {
        for effect in effects {
            switch effect {
            case .play(let animation):
                dog.play(animation)
            case .moveTo(let point, let speed):
                dog.move(to: point, speed: speed)
            case .stopMoving:
                dog.stopMoving()
            case .armThrow:
                armedForThrow = true
            case .disarmThrow:
                armedForThrow = false
                armedToy = nil
            case .pickUpBall:
                attachBallToDog()
            case .dropBall:
                dropBallAtDog()
            case .removeBall:
                ball?.fadeOutAndRemove()
                ball = nil
                pendingChaseArrival = false
            case .eatTreat:
                eatGroundTreat()
            case .showHearts:
                showHearts()
            case .celebrate:
                dog.celebrate()
            case .startZoomies:
                startZoomies()
            case .stopZoomies:
                stopZoomies()
            case .startSniffing:
                isSniffing = true
                sniffingClose = false
            case .stopSniffing:
                isSniffing = false
                sniffingClose = false
            case .removeTreat:
                removeGroundTreat()
            case .leaveDeposit:
                spawnPile()
            case .playSound(let name):
                playSound(named: name)
            case .nudgeCursor:
                nudgeRealCursor()
            case .pickUpToy(let kind):
                attachToyToDog(kind)
            case .dropToy(let kind):
                dropToyAtDog(kind)
            case .removeToy(let kind):
                removeToy(kind)
            case .startTug, .stopTug:
                break // wired by the tug-of-war slice
            }
        }
    }

    // MARK: - Sound

    /// Play a generated effect from Resources/audio, unless the user muted us.
    /// NSSounds are cached; a re-trigger restarts the sound from the top.
    private func playSound(named name: String) {
        guard !UserDefaults.standard.bool(forKey: "soundMuted") else { return }
        let sound: NSSound
        if let cached = soundCache[name] {
            sound = cached
        } else {
            guard
                let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "audio"),
                let loaded = NSSound(contentsOf: url, byReference: true)
            else { return }
            soundCache[name] = loaded
            sound = loaded
        }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    // MARK: - Fetch plumbing

    private func throwBall(to landing: CGPoint) {
        armedForThrow = false
        armedToy = nil
        pendingChaseArrival = false
        let margin: CGFloat = 30
        let clamped = CGPoint(
            x: min(max(landing.x, margin), size.width - margin),
            y: min(max(landing.y, margin), size.height - margin)
        )

        ball?.removeFromParent()
        let ball = Ball()
        addChild(ball)
        ball.onLanded = { [weak self] in
            guard let self, self.pendingChaseArrival else { return }
            self.pendingChaseArrival = false
            self.send(.arrived)
        }
        self.ball = ball

        let origin = dog.position
        ball.throwArc(from: CGPoint(x: origin.x, y: origin.y + 20), to: clamped)
        send(.ballThrown(landing: clamped, origin: origin))
    }

    private func attachBallToDog() {
        guard let ball else { return }
        ball.removeAction(forKey: "flight")
        ball.removeFromParent()
        dog.addChild(ball)
        reseatCarriedBall()
    }

    /// Keep a carried ball at the dog's mouth as he turns.
    private func reseatCarriedBall() {
        guard let ball, ball.parent === dog else { return }
        ball.position = dog.mouthOffset
        ball.zPosition = dog.mouthZOffset
    }

    private func dropBallAtDog() {
        guard let ball else { return }
        ball.removeFromParent()
        let v = dog.facing.unitVector
        ball.position = CGPoint(x: dog.position.x + v.x * 34, y: dog.position.y + v.y * 34 - 10)
        ball.zPosition = 5
        addChild(ball)
        // The dropped ball rests a while, then tidies itself away.
        ball.run(.sequence([.wait(forDuration: 8), .fadeOut(withDuration: 0.6), .removeFromParent()]))
        self.ball = nil
    }

    // MARK: - Toy box

    /// How close his nose has to get to the disc's CURRENT position for the
    /// catch to count. Generous: the disc is 36pt wide and he is not subtle.
    private static let frisbeeCatchRadius: CGFloat = 40
    /// How long a dropped toy lies around before it tidies itself away.
    private static let toyLingerDuration: TimeInterval = 4

    private func throwFrisbee(to landing: CGPoint) {
        armedForThrow = false
        armedToy = nil
        pendingChaseArrival = false
        let margin: CGFloat = 30
        let clamped = CGPoint(
            x: min(max(landing.x, margin), size.width - margin),
            y: min(max(landing.y, margin), size.height - margin)
        )

        frisbee?.removeFromParent()
        let disc = Frisbee()
        addChild(disc)
        disc.onLanded = { [weak self] in
            // He beat the disc to the spot and it never got caught: the
            // pick-up waits for it to stop skidding (same as the ball).
            guard let self, self.pendingChaseArrival else { return }
            self.pendingChaseArrival = false
            self.send(.arrived)
        }
        frisbee = disc

        let origin = dog.position
        disc.throwArc(from: CGPoint(x: origin.x, y: origin.y + 20), to: clamped)
        send(.toyThrown(kind: .frisbee, landing: clamped, origin: origin))
    }

    /// THE moment: while the disc is still in the air, check every frame
    /// whether he has run under it. Close enough and the chase ends early —
    /// he takes it out of the sky instead of off the floor.
    private func stepFrisbeeCatch() {
        guard brain.state == .chasingFrisbee,
              let disc = frisbee, !disc.isLanded, disc.parent === self
        else { return }
        let gap = hypot(disc.position.x - dog.position.x, disc.position.y - dog.position.y)
        guard gap <= Self.frisbeeCatchRadius else { return }
        pendingChaseArrival = false
        // The brain answers with .pickUpToy + a fresh .moveTo, which replaces
        // the in-flight run action, so the stale arrival never fires.
        send(.arrived)
    }

    private func toyNode(_ kind: ToyKind) -> SKSpriteNode? {
        switch kind {
        case .frisbee: return frisbee
        case .squeaky, .rope: return nil
        }
    }

    private func attachToyToDog(_ kind: ToyKind) {
        guard let toy = toyNode(kind) else { return }
        toy.removeAction(forKey: "flight")
        if let disc = toy as? Frisbee { disc.clampInMouth() }
        toy.removeFromParent()
        dog.addChild(toy)
        reseatCarriedToy()
    }

    /// Keep a carried toy at the dog's mouth as he turns. The dog's own
    /// xScale (±1, mirrored bark art) is divided back out, same as the rabbit.
    private func reseatCarriedToy() {
        for kind in [ToyKind.frisbee] {
            guard let toy = toyNode(kind), toy.parent === dog else { continue }
            let parentFlip: CGFloat = dog.xScale < 0 ? -1 : 1
            toy.position = CGPoint(x: dog.mouthOffset.x * parentFlip, y: dog.mouthOffset.y)
            toy.zPosition = dog.mouthZOffset
            toy.xScale = parentFlip
        }
    }

    private func dropToyAtDog(_ kind: ToyKind) {
        guard let toy = toyNode(kind) else { return }
        toy.removeFromParent()
        let v = dog.facing.unitVector
        toy.position = CGPoint(x: dog.position.x + v.x * 34, y: dog.position.y + v.y * 34 - 10)
        toy.zPosition = 5
        toy.xScale = 1
        addChild(toy)
        toy.run(.sequence([
            .wait(forDuration: Self.toyLingerDuration),
            .fadeOut(withDuration: 0.6),
            .removeFromParent(),
        ]))
        forgetToy(kind)
    }

    private func removeToy(_ kind: ToyKind) {
        guard let toy = toyNode(kind) else { return }
        toy.removeAllActions()
        toy.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        forgetToy(kind)
        pendingChaseArrival = false
    }

    /// Let go of our reference — the node keeps running its own fade-out.
    private func forgetToy(_ kind: ToyKind) {
        switch kind {
        case .frisbee: frisbee = nil
        case .squeaky, .rope: break
        }
    }

    // MARK: - Zoomies

    private func startZoomies() {
        // Defensive: no stale in-flight walk fighting the manual bounce.
        dog.removeAction(forKey: "move")
        // Any angle but near-vertical, so the path reads as diagonal and bouncy.
        var angle = CGFloat.random(in: 0..<(2 * .pi))
        while abs(cos(angle)) < 0.3 {
            angle = CGFloat.random(in: 0..<(2 * .pi))
        }
        let speed = brain.tuning.zoomiesSpeed
        let velocity = CGPoint(x: cos(angle) * speed, y: sin(angle) * speed)
        zoomiesVelocity = velocity

        let rabbit = Self.propNode(named: "rabbit", frameWidth: 16, fallbackColor: .systemGray,
                                   fallbackSize: CGSize(width: 48, height: 36))
        dog.addChild(rabbit)
        self.rabbit = rabbit
        dog.face(towards: CGPoint(x: dog.position.x + velocity.x, y: dog.position.y + velocity.y))
        reseatCarriedRabbit()
    }

    private func stopZoomies() {
        zoomiesVelocity = nil
        guard let rabbit else { return }
        self.rabbit = nil
        rabbit.run(.sequence([.fadeOut(withDuration: 0.15), .removeFromParent()]))
    }

    /// Keep the carried rabbit at the dog's mouth, facing the travel direction.
    /// The dog's own xScale (±1, mirrored bark art) is divided back out because
    /// a child node inherits its parent's scale.
    private func reseatCarriedRabbit() {
        guard let rabbit, rabbit.parent === dog else { return }
        let parentFlip: CGFloat = dog.xScale < 0 ? -1 : 1
        rabbit.position = CGPoint(x: dog.mouthOffset.x * parentFlip, y: dog.mouthOffset.y)
        rabbit.zPosition = dog.mouthZOffset
        let headedWest = (zoomiesVelocity?.x ?? 1) < 0
        rabbit.xScale = (headedWest ? -1 : 1) * parentFlip
    }

    private func stepZoomies(dt: TimeInterval) {
        guard var v = zoomiesVelocity, dt > 0 else { return }
        var p = CGPoint(x: dog.position.x + v.x * CGFloat(dt), y: dog.position.y + v.y * CGFloat(dt))
        // Reflect off the walls, inset by his half-size so the art stays on screen.
        let halfW = dog.size.width / 2
        let halfH = dog.size.height / 2
        if p.x < halfW { p.x = halfW; v.x = abs(v.x) }
        if p.x > size.width - halfW { p.x = size.width - halfW; v.x = -abs(v.x) }
        if p.y < halfH { p.y = halfH; v.y = abs(v.y) }
        if p.y > size.height - halfH { p.y = size.height - halfH; v.y = -abs(v.y) }
        zoomiesVelocity = v
        dog.position = p
        dog.face(towards: CGPoint(x: p.x + v.x, y: p.y + v.y))
        // A bounce flips the rabbit even when face() already reseated it.
        reseatCarriedRabbit()
    }

    // MARK: - Mouse hunting (sniff / stalk / pounce share the cursor tracker)

    /// A whole hunt (.sniffingMouse → .stalkingMouse → .pouncing) runs under
    /// one .startSniffing/.stopSniffing pair, so `isSniffing` stays true
    /// through every stage; the brain's state picks the movement style.
    private func stepSniffing(dt: TimeInterval) {
        guard isSniffing, dt > 0 else { return }
        switch brain.state {
        case .stalkingMouse: stepStalking(dt: dt)
        case .pouncing: stepPouncing(dt: dt)
        default: stepPlainSniffing(dt: dt)
        }
    }

    private func stepPlainSniffing(dt: TimeInterval) {
        let cursor = mouseLocationInScene()
        let dx = cursor.x - dog.position.x
        let dy = cursor.y - dog.position.y
        let distance = hypot(dx, dy)
        if distance > 60 {
            // Manual stepping (not an SKAction move) so he tracks a moving
            // target; clamped in case the cursor is on another display.
            let step = min(brain.tuning.walkSpeed * 1.5 * CGFloat(dt), distance)
            dog.position = CGPoint(
                x: min(max(dog.position.x + dx / distance * step, 0), size.width),
                y: min(max(dog.position.y + dy / distance * step, 0), size.height)
            )
            dog.face(towards: cursor)
            if sniffingClose {
                sniffingClose = false
                dog.play(.walk)
            }
        } else {
            dog.face(towards: cursor)
            if !sniffingClose {
                sniffingClose = true
                dog.play(.sniff)
            }
        }
    }

    /// How close the stalk lets him get: he shadows the cursor from here.
    private static let stalkStandoff: CGFloat = 90

    /// The stalk: creep after the cursor at half the sniff approach speed,
    /// holding the standoff distance — low, slow, and just out of reach.
    /// The brain already played .stalk on entry; no animation switching here.
    private func stepStalking(dt: TimeInterval) {
        let cursor = mouseLocationInScene()
        dog.face(towards: cursor)
        let dx = cursor.x - dog.position.x
        let dy = cursor.y - dog.position.y
        let distance = hypot(dx, dy)
        guard distance > Self.stalkStandoff else { return }
        let creep = brain.tuning.walkSpeed * 0.75 // 0.5× the sniff approach (walkSpeed * 1.5)
        let step = min(creep * CGFloat(dt), distance - Self.stalkStandoff)
        dog.position = CGPoint(
            x: min(max(dog.position.x + dx / distance * step, 0), size.width),
            y: min(max(dog.position.y + dy / distance * step, 0), size.height)
        )
    }

    /// The pounce: a fast manual leap re-aimed at the cursor's *current*
    /// position every frame (like zoomies, not an SKAction), so a fleeing
    /// cursor is still chased over the brain's pounceDuration window.
    private func stepPouncing(dt: TimeInterval) {
        let cursor = mouseLocationInScene()
        let dx = cursor.x - dog.position.x
        let dy = cursor.y - dog.position.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return }
        dog.face(towards: cursor)
        let step = min(brain.tuning.runSpeed * CGFloat(dt), distance)
        dog.position = CGPoint(
            x: min(max(dog.position.x + dx / distance * step, 0), size.width),
            y: min(max(dog.position.y + dy / distance * step, 0), size.height)
        )
    }

    // MARK: - The catch

    /// The caught "prey" wriggles: jitter the real pointer a few points and
    /// put it back. CGEvent's location and CGWarpMouseCursor both use global
    /// display coordinates (top-left origin), and only relative offsets from
    /// the read position are applied, so no scene-coordinate conversion is
    /// needed. Best-effort: if the system ignores the warp (event-posting
    /// restrictions), nothing moves and the .celebrate hearts still sell it.
    private func nudgeRealCursor() {
        guard let origin = CGEvent(source: nil)?.location else { return }
        // Small hops (≤5pt from origin), ending exactly back home, ~0.3s total.
        let offsets: [CGVector] = [
            CGVector(dx: 4, dy: -3), CGVector(dx: -4, dy: 3),
            CGVector(dx: 3, dy: 4), CGVector(dx: 0, dy: 0),
        ]
        for (index, offset) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.075 * Double(index + 1)) {
                // The user yanked the mouse away mid-jitter: let go of it.
                guard let current = CGEvent(source: nil)?.location,
                      hypot(current.x - origin.x, current.y - origin.y) < 24 else { return }
                CGWarpMouseCursorPosition(CGPoint(x: origin.x + offset.dx, y: origin.y + offset.dy))
                // Re-associate so the warp doesn't suppress real mouse input.
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }

    // MARK: - Treats

    private func makeTreat(at location: CGPoint) -> SKSpriteNode {
        let treat = Self.propNode(named: "treat", frameWidth: 12, fallbackColor: .systemBrown,
                                  fallbackSize: CGSize(width: 36, height: 24))
        treat.position = location
        treat.zPosition = 15
        addChild(treat)
        return treat
    }

    private func dropTreat(at location: CGPoint) {
        guard let treat = treatInHand else { return }
        treatInHand = nil
        // Released back over (or never left) the jar: put the treat away.
        if jar.frame.insetBy(dx: -6, dy: -6).contains(location) {
            treat.removeFromParent()
            return
        }
        // One active treat: a fresh drop replaces a stale one.
        groundTreat?.removeFromParent()
        treat.zPosition = 7 // above furniture, below the dog
        groundTreat = treat
        send(.treatDropped(at: location))
        // In your arms or mouth already full: the brain ignored the drop.
        if brain.state != .chasingTreat {
            removeGroundTreat()
        }
    }

    private func eatGroundTreat() {
        guard let treat = groundTreat else { return }
        groundTreat = nil
        treat.run(.sequence([
            .group([.scale(to: 0.2, duration: 0.15), .fadeOut(withDuration: 0.15)]),
            .removeFromParent(),
        ]))
        // The menu bar's hunger meter counts these.
        NotificationCenter.default.post(name: Notification.Name("JumbiniAteTreat"), object: nil)
        // A treat soon after a trick attempt is training. recordTreat only
        // ever returns a trick that was locked when attempted, so unlocked
        // here means this very rep completed the training — celebrate.
        if let trick = trickTrainer.recordTreat(at: lastTime), trickTrainer.isUnlocked(trick) {
            dog.celebrate()
            showHearts()
        }
    }

    /// A chase was abandoned (command, petting, pickup): the treat vanishes.
    private func removeGroundTreat() {
        guard let treat = groundTreat else { return }
        groundTreat = nil
        treat.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent()]))
    }

    // MARK: - Deposits

    /// On-screen pile cap: when a 6th appears the oldest fades away.
    private static let maxPiles = 5

    /// Pile art: the roadmap's hand-made piles (deposit_1..3) win when they
    /// exist; the generated two-variant strip is the stand-in. Same
    /// drop-the-file-in upgrade path as the bed catalog.
    private static func pileNode() -> SKSpriteNode {
        if let real = SpriteLibrary.shared.singleProp(named: "deposit_\(Int.random(in: 1...3))") {
            let node = SKSpriteNode(texture: real.textures[0])
            node.size = real.nodeSize
            return node
        }
        if let anim = SpriteLibrary.shared.prop(named: "deposit", frameWidth: 12, fps: 1),
           let texture = anim.textures.randomElement() {
            let node = SKSpriteNode(texture: texture)
            node.size = anim.nodeSize
            return node
        }
        return SKSpriteNode(color: .systemBrown, size: CGSize(width: 36, height: 30))
    }

    /// The hunch finished: a pile lands just behind him, on the ground line.
    private func spawnPile() {
        let pile = Self.pileNode()
        let v = dog.facing.unitVector
        pile.position = CGPoint(
            x: min(max(dog.position.x - v.x * 34, 18), size.width - 18),
            y: min(max(dog.position.y - v.y * 34 - 10, 15), size.height - 15)
        )
        pile.zPosition = 4 // above furniture (2), below the dog (10)
        addChild(pile)
        piles.append(pile)
        if piles.count > Self.maxPiles {
            // Never evict the pile the user is currently dragging — it would
            // vanish out of their hand mid-gesture and leave mouseUp holding
            // an orphaned node. Retire the oldest one they aren't holding.
            guard let index = piles.firstIndex(where: { $0 !== draggedPile }) else { return }
            let oldest = piles.remove(at: index)
            oldest.run(.sequence([.fadeOut(withDuration: 0.4), .removeFromParent()]))
        }
    }

    /// "The trash": the Dock strip along the bottom, or Trash-can territory
    /// near the bottom-right corner.
    private func isTrashZone(_ point: CGPoint) -> Bool {
        if point.y < 90 { return true }
        return hypot(point.x - size.width, point.y) < 120
    }

    /// Dropped in the trash: a little scale-down flourish and it's gone.
    /// Dropped anywhere else: it just sits there. He's not sorry.
    private func dropPile(_ pile: SKSpriteNode, at location: CGPoint) {
        guard isTrashZone(location) else { return }
        piles.removeAll { $0 === pile }
        pile.run(.sequence([
            .group([.scale(to: 0.1, duration: 0.25), .fadeOut(withDuration: 0.25)]),
            .removeFromParent(),
        ]))
    }

    // MARK: - Petting feedback

    private func showHearts() {
        for i in 0..<3 {
            let heart: SKNode
            if let anim = SpriteLibrary.shared.prop(named: "heart", frameWidth: 8, fps: 1) {
                let sprite = SKSpriteNode(texture: anim.textures[0])
                sprite.size = CGSize(width: 20, height: 20)
                heart = sprite
            } else {
                let label = SKLabelNode(text: "❤️")
                label.fontSize = 18
                heart = label
            }
            heart.zPosition = 20
            heart.position = CGPoint(
                x: dog.position.x + CGFloat.random(in: -28...28),
                y: dog.position.y + dog.size.height / 2
            )
            addChild(heart)
            heart.run(.sequence([
                .wait(forDuration: 0.12 * Double(i)),
                .group([
                    .moveBy(x: CGFloat.random(in: -10...10), y: 60, duration: 0.9),
                    .sequence([.wait(forDuration: 0.5), .fadeOut(withDuration: 0.4)]),
                ]),
                .removeFromParent(),
            ]))
        }
    }

    // MARK: - Click-through

    /// The window ignores mouse events except while the cursor is over
    /// something interactive (or a drag/throw is in progress), so clicks land
    /// in the user's real apps everywhere else.
    private func updateClickThrough() {
        guard let window = overlayWindow else { return }
        // A held press counts too: the dog can walk out from under a stationary
        // cursor, and the window must keep the mouseUp.
        let dragging = mouseDownOnDog || isCarryingDog || pressedJar
            || treatInHand != nil || draggedFurniture != nil || draggedPile != nil
        let shouldAcceptClicks = armedForThrow || dragging
            || interactiveFrames().contains { $0.contains(mouseLocationInScene()) }
        if window.ignoresMouseEvents == shouldAcceptClicks {
            window.ignoresMouseEvents = !shouldAcceptClicks
        }
    }

    private func interactiveFrames() -> [CGRect] {
        [dogHoverFrame(), jar.frame.insetBy(dx: -6, dy: -6), bed.frame.insetBy(dx: -6, dy: -6)]
            + piles.map { $0.frame.insetBy(dx: -6, dy: -6) }
    }

    private func dogHoverFrame() -> CGRect {
        // Small inset so the hover region is slightly forgiving at pixel edges.
        dog.calculateAccumulatedFrame().insetBy(dx: -6, dy: -6)
    }

    private func mouseLocationInScene() -> CGPoint {
        guard let window = overlayWindow, let view else { return CGPoint(x: -1, y: -1) }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return view.convert(inWindow, to: self)
    }

    /// Clamp entities back on screen after a resolution change.
    func clampEntitiesOnScreen() {
        for node in ([dog, bed, jar] as [SKSpriteNode]) + piles {
            node.position.x = min(max(node.position.x, 0), size.width)
            node.position.y = min(max(node.position.y, 0), size.height)
        }
        // Through the event (not a direct assignment) so a dog mid-walk to the
        // bed retargets instead of finishing his walk off-screen.
        send(.bedMoved(to: bedLieSpot()))
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let location = event.location(in: self)
        pressLocation = location
        // Props keep priority over an armed throw so the jar/bed stay usable
        // while the dog waits for a throw (dropping a treat cancels the fetch).
        if dogHoverFrame().contains(location) {
            mouseDownOnDog = true
            carryGrabOffset = CGPoint(x: dog.position.x - location.x, y: dog.position.y - location.y)
        } else if jar.frame.insetBy(dx: -6, dy: -6).contains(location), treatInHand == nil {
            if event.modifierFlags.contains(.option) {
                draggedFurniture = jar  // ⌥-drag repositions the jar immediately
            } else {
                pressedJar = true       // click takes a treat; a drag moves the jar
            }
        } else if bed.frame.insetBy(dx: -6, dy: -6).contains(location) {
            draggedFurniture = bed
        } else if let pile = piles.last(where: { $0.frame.insetBy(dx: -6, dy: -6).contains(location) }) {
            draggedPile = pile // newest first when piles overlap
        } else if armedForThrow {
            if armedToy == .frisbee {
                throwFrisbee(to: location)
            } else {
                throwBall(to: location)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = event.location(in: self)
        if mouseDownOnDog {
            // Click-vs-carry slop measured from the press point, and the carry
            // preserves the grab offset instead of snapping his center to the cursor.
            if !isCarryingDog, hypot(location.x - pressLocation.x, location.y - pressLocation.y) > 10 {
                isCarryingDog = true
                send(.pickedUp)
            }
            if isCarryingDog {
                dog.position = CGPoint(x: location.x + carryGrabOffset.x, y: location.y + carryGrabOffset.y)
            }
        } else if pressedJar {
            // Same slop pattern as the dog: past the threshold the press
            // becomes a jar drag instead of a treat click.
            if hypot(location.x - pressLocation.x, location.y - pressLocation.y) > 8 {
                pressedJar = false
                draggedFurniture = jar
                jar.position = location
            }
        } else if let treat = treatInHand {
            treat.position = location
        } else if let furniture = draggedFurniture {
            furniture.position = location
            if furniture === bed {
                send(.bedMoved(to: bedLieSpot()))
            }
        } else if let pile = draggedPile {
            pile.position = location
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = event.location(in: self)
        defer {
            mouseDownOnDog = false
            isCarryingDog = false
            draggedFurniture = nil
            draggedPile = nil
            pressedJar = false
        }
        if mouseDownOnDog {
            if isCarryingDog {
                send(.dropped(at: CGPoint(x: location.x + carryGrabOffset.x, y: location.y + carryGrabOffset.y)))
            } else {
                send(.petted)
            }
        } else if pressedJar {
            // Released under the drag threshold: a plain click takes a treat.
            treatInHand = makeTreat(at: location)
        } else if treatInHand != nil {
            dropTreat(at: location)
        } else if let pile = draggedPile {
            dropPile(pile, at: location)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Never open the menu mid-drag: its tracking session would swallow the
        // mouseUp and wedge the drag state (stuck carry, leaked treat).
        guard !mouseDownOnDog, !pressedJar, treatInHand == nil,
              draggedFurniture == nil, draggedPile == nil else { return }
        let location = event.location(in: self)
        if armedForThrow, !dogHoverFrame().contains(location) {
            // Right-click while waiting for a throw = change your mind.
            send(.throwCancelled)
            return
        }
        if !dogHoverFrame().contains(location), bed.frame.contains(location), let view {
            // Right-click on the bed: pick a different bed from the catalog.
            NSMenu.popUpContextMenu(bedSelectionMenu(), with: event, for: view)
            return
        }
        guard dogHoverFrame().contains(location), let view else { return }
        let menu = NSMenu()
        let commands: [(String, DogCommand)] = brain.state == .spinning
            ? [
                ("Stop Spinning", .relax),
                ("Sit", .sit),
                ("Lie Down", .lieDown),
                ("Zoomies!", .zoomies),
                ("Fetch", .fetch),
            ]
            : [
                ("Sit", .sit),
                ("Lie Down", .lieDown),
                ("Spin", .spin),
                ("Spin Forever", .spinForever),
                ("Zoomies!", .zoomies),
                ("Fetch", .fetch),
            ]
        for (title, command) in commands {
            let item = NSMenuItem(title: title, action: #selector(commandChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(tricksMenuItem())
        menu.addItem(toysMenuItem())
        let wardrobe = NSMenuItem(title: "Wardrobe", action: nil, keyEquivalent: "")
        wardrobe.submenu = wardrobeSelectionMenu()
        menu.addItem(wardrobe)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// The Tricks submenu: unlocked tricks by name, locked ones as
    /// "Teach Shake (1/3)". Either way the item sends the trick command —
    /// attempting IS the training (rewarded if a treat follows).
    private func tricksMenuItem() -> NSMenuItem {
        let tricksItem = NSMenuItem(title: "Tricks", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for trick in Trick.allCases {
            let title: String
            if trickTrainer.isUnlocked(trick) {
                title = trick.rawValue
            } else {
                let progress = trickTrainer.progress(trick)
                title = "Teach \(trick.rawValue) (\(progress.reps)/\(progress.needed))"
            }
            let item = NSMenuItem(title: title, action: #selector(trickChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = trick
            submenu.addItem(item)
        }
        tricksItem.submenu = submenu
        return tricksItem
    }

    /// The Toys submenu, between Tricks and Wardrobe: fetch is one ball, this
    /// is the rest of the box. Each toy plays differently — the frisbee is
    /// aimed and thrown, the squeaky is lobbed nearby, the rope is tugged.
    private func toysMenuItem() -> NSMenuItem {
        let toysItem = NSMenuItem(title: "Toys", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, kind) in Self.toyMenuEntries {
            let item = NSMenuItem(title: title, action: #selector(toyChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ToyChoice(kind: kind)
            submenu.addItem(item)
        }
        toysItem.submenu = submenu
        return toysItem
    }

    /// `representedObject` needs a class, and ToyKind is an enum.
    private final class ToyChoice: NSObject {
        let kind: ToyKind
        init(kind: ToyKind) { self.kind = kind }
    }

    private static let toyMenuEntries: [(String, ToyKind)] = [("Frisbee", .frisbee)]

    @objc private func toyChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ToyChoice else { return }
        switch choice.kind {
        case .frisbee:
            // Arms the throw: the next left-click anywhere sails the disc there.
            armedToy = .frisbee
            send(.command(.toy(.frisbee)))
        case .squeaky, .rope:
            break // later slices of the toy box
        }
    }

    @objc private func commandChosen(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DogCommand else { return }
        send(.command(command))
    }

    @objc private func trickChosen(_ sender: NSMenuItem) {
        guard let trick = sender.representedObject as? Trick else { return }
        // recordAttempt no-ops for unlocked tricks, so this is safe for both
        // "Teach …" items and plain performances.
        trickTrainer.recordAttempt(trick, at: lastTime)
        send(.command(.trick(trick)))
    }

    // MARK: - Jumbini Cam

    /// Device pixels per scene point in the composed cam image: 2x keeps the
    /// pixel art crisp on retina displays.
    private static let camScale: CGFloat = 2

    /// Snapshot the dog onto a transparent canvas with a "Jumbini, 3:42 PM"
    /// caption below, and play the shutter flash. Worn hats and carried toys
    /// are child nodes of the dog, so texture(from:) brings them along free.
    /// Works while the view is paused too — the offscreen render doesn't need
    /// the window on screen (the flash is skipped then; see flashCamFeedback).
    /// Returns nil only if the render pipeline fails (no SKView yet, or the
    /// offscreen render came back empty).
    func captureJumbini() -> NSImage? {
        guard let view else { return nil }
        let dogFrame = dog.calculateAccumulatedFrame()
        guard dogFrame.width > 0, dogFrame.height > 0,
              let texture = view.texture(from: dog)
        else { return nil }
        guard let image = Self.composeCamImage(
            dogImage: texture.cgImage(), dogPointSize: dogFrame.size, date: Date()
        ) else { return nil }
        flashCamFeedback()
        return image
    }

    /// "Jumbini, 3:42 PM" — real current time, localized short style.
    private static func camCaption(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Jumbini, \(formatter.string(from: date))"
    }

    /// Rounded system font for the caption (Menlo, then plain system, as
    /// fallbacks). `pixelSize` is in device pixels — all cam composition
    /// happens in pixel space.
    private static func camCaptionFont(pixelSize: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: pixelSize, weight: .semibold)
        if let rounded = system.fontDescriptor.withDesign(.rounded),
           let font = NSFont(descriptor: rounded, size: pixelSize) {
            return font
        }
        return NSFont(name: "Menlo", size: pixelSize) ?? system
    }

    /// Compose dog-above-caption on a transparent canvas. Everything is laid
    /// out in device pixels (points x camScale) with nearest-neighbor
    /// sampling so the pixel art never picks up a smoothing blur; the caption
    /// is white with a 1px dark outline so it reads on any background.
    private static func composeCamImage(
        dogImage: CGImage, dogPointSize: CGSize, date: Date
    ) -> NSImage? {
        let scale = camScale
        let pad = 12 * scale
        let gap = 8 * scale
        let outlineColor = NSColor(white: 0.08, alpha: 0.9)

        let font = camCaptionFont(pixelSize: 13 * scale)
        let caption = camCaption(for: date)
        let captionFace = NSAttributedString(
            string: caption, attributes: [.font: font, .foregroundColor: NSColor.white]
        )
        let captionOutline = NSAttributedString(
            string: caption, attributes: [.font: font, .foregroundColor: outlineColor]
        )
        let textSize = captionFace.size()

        // Optional paw-print glyph before the text (skipped if the symbol is
        // unavailable). Rasterized here, then drawn via clip-to-alpha-mask so
        // it gets the same white-with-dark-outline treatment as the caption.
        let pawSide = (font.capHeight * 1.2).rounded()
        let pawGap = 5 * scale
        var pawMask: CGImage?
        if let paw = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil) {
            var pawRect = CGRect(x: 0, y: 0, width: pawSide, height: pawSide)
            pawMask = paw.cgImage(forProposedRect: &pawRect, context: nil, hints: nil)
        }

        let dogPixelSize = CGSize(
            width: (dogPointSize.width * scale).rounded(),
            height: (dogPointSize.height * scale).rounded()
        )
        let captionWidth = (pawMask != nil ? pawSide + pawGap : 0) + textSize.width.rounded(.up)
        let contentWidth = max(dogPixelSize.width, captionWidth)
        let canvasWidth = Int((contentWidth + pad * 2).rounded(.up))
        let canvasHeight = Int((pad + textSize.height + gap + dogPixelSize.height + pad).rounded(.up))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: canvasWidth, height: canvasHeight,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .none // nearest-neighbor for the pixel art
        context.setShouldSmoothFonts(false)  // no subpixel fringing on transparency

        // The dog, centered, above the caption line.
        let dogRect = CGRect(
            x: ((CGFloat(canvasWidth) - dogPixelSize.width) / 2).rounded(),
            y: (pad + textSize.height + gap).rounded(),
            width: dogPixelSize.width, height: dogPixelSize.height
        )
        context.draw(dogImage, in: dogRect)

        // Caption row, centered under the dog.
        var cursorX = ((CGFloat(canvasWidth) - captionWidth) / 2).rounded()
        if let pawMask {
            // Bottom of the glyph on the text baseline (descender is negative).
            let pawRect = CGRect(
                x: cursorX, y: (pad - font.descender).rounded(), width: pawSide, height: pawSide
            )
            drawCamGlyph(pawMask, in: pawRect, context: context, fill: outlineColor, outlinePass: true)
            drawCamGlyph(pawMask, in: pawRect, context: context, fill: .white, outlinePass: false)
            cursorX += pawSide + pawGap
        }
        let textOrigin = CGPoint(x: cursorX, y: pad)
        let appKitContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = appKitContext
        for dx: CGFloat in [-1, 0, 1] {
            for dy: CGFloat in [-1, 0, 1] where !(dx == 0 && dy == 0) {
                captionOutline.draw(at: CGPoint(x: textOrigin.x + dx, y: textOrigin.y + dy))
            }
        }
        captionFace.draw(at: textOrigin)
        NSGraphicsContext.restoreGraphicsState()

        guard let composed = context.makeImage() else { return nil }
        // Point size = pixels / camScale, so the image self-reports as retina
        // (2x) content on the pasteboard.
        return NSImage(
            cgImage: composed,
            size: NSSize(width: CGFloat(canvasWidth) / scale, height: CGFloat(canvasHeight) / scale)
        )
    }

    /// Fill `mask`'s alpha silhouette with a color — the classic clip-to-mask
    /// tinting recipe. `outlinePass` stamps the 8 one-pixel offsets (the same
    /// halo the caption text gets); otherwise a single centered fill.
    private static func drawCamGlyph(
        _ mask: CGImage, in rect: CGRect, context: CGContext, fill: NSColor, outlinePass: Bool
    ) {
        let offsets: [CGPoint] = outlinePass
            ? [CGPoint(x: -1, y: -1), CGPoint(x: -1, y: 0), CGPoint(x: -1, y: 1),
               CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1),
               CGPoint(x: 1, y: -1), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]
            : [.zero]
        for offset in offsets {
            let shifted = rect.offsetBy(dx: offset.x, dy: offset.y)
            context.saveGState()
            context.clip(to: shifted, mask: mask)
            context.setFillColor(fill.cgColor)
            context.fill(shifted)
            context.restoreGState()
        }
    }

    /// Shutter feedback: a quick white flash over everything (alpha
    /// 0 -> 0.7 -> 0 over ~0.25s). Skipped while the view is paused: SKActions
    /// don't run then, and a stale flash firing on resume would be confusing.
    /// No shutter sound for now — make_audio.py is contested by sibling
    /// branches; noted as future work.
    private func flashCamFeedback() {
        guard let view, !view.isPaused, !isPaused else { return }
        let flash = SKSpriteNode(color: .white, size: size)
        flash.anchorPoint = .zero
        flash.position = .zero
        flash.zPosition = 1_000 // above the dog (10), hearts (20), everything
        flash.alpha = 0
        addChild(flash)
        flash.run(.sequence([
            .fadeAlpha(to: 0.7, duration: 0.08),
            .fadeAlpha(to: 0, duration: 0.17),
            .removeFromParent(),
        ]))
    }
}
