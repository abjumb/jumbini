import CoreGraphics
import SpriteKit

/// The transparent scene the dog lives in. Owns per-frame mouse polling and
/// the click-through toggle, routes interactions to the brain, and applies
/// the brain's effects to the sprites.
final class PetScene: SKScene {
    weak var overlayWindow: NSWindow?

    /// The shape of the desk. The scene spans the BOUNDING BOX of every
    /// display, so `size` is not the same thing as "where the user can see" —
    /// on an uneven arrangement parts of the scene are on no display at all.
    /// Anything that picks a spot for something goes through here.
    /// Kept current by `apply(layout:)` when displays come and go.
    private(set) var layout: ScreenLayout

    private let dog = Dog()
    private var ball: Ball?

    // The toy box: one node per toy, nil when that toy isn't out.
    private var frisbee: Frisbee?
    private var squeaky: SKSpriteNode?
    private var rope: TugRope?

    // Tug-of-war drag state.
    /// The user has hold of the free end.
    private var draggingRope = false
    /// He won and is trotting off with the rope trailing from his mouth.
    private var carryingRope = false
    /// Where the cursor last was during the drag (scene coords).
    private var ropePull: CGPoint = .zero
    /// The RENDERED free end, which lags the cursor — that lag is the drag.
    private var ropeEnd: CGPoint = .zero
    /// Throttle clock for `.tugMoved` (~10/s).
    private var lastTugSent: TimeInterval = 0
    /// When the next yank fires, and how far through the current one we are.
    private var nextYank: TimeInterval = 0
    private var yankPhase: CGFloat = 0
    private var brain: DogBrain!
    private var lastTime: TimeInterval = 0

    // Furniture.
    private var bed: SKSpriteNode!
    private var treatBox: SKSpriteNode!

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
    /// A plain press started on the treat box: click = take a treat,
    /// drag = move the box.
    private var pressedTreatBox = false
    /// Where the current press started (drag threshold is measured from here).
    private var pressLocation: CGPoint = .zero
    /// Keeps the grab point under the cursor while carrying (no center-snap).
    private var carryGrabOffset: CGPoint = .zero

    init(layout: ScreenLayout) {
        self.layout = layout
        super.init(size: layout.size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        // Furniture goes in the bottom-right of the PRIMARY display, not of the
        // whole desk: on a three-monitor setup the union's bottom-right corner
        // is off in someone's peripheral vision, and a fresh install should
        // look the way it always did — bed and treat box by the Dock.
        // Before anything asks for dog art: the coat decides which files that
        // resolves to, and the first pose is played at the end of this method.
        if let stored = UserDefaults.standard.string(forKey: Self.coatKey),
           let coat = Coat(rawValue: stored) {
            SpriteLibrary.shared.coat = coat
        }
        let home = layout.primarySceneFrame
        bed = Self.propNode(named: "bed", frameWidth: 52, fallbackColor: .systemBlue,
                            fallbackSize: CGSize(width: 156, height: 96))
        bed.position = CGPoint(x: home.maxX - 240, y: home.minY + 150)
        bed.zPosition = 2
        addChild(bed)
        if let stored = UserDefaults.standard.object(forKey: Self.bedVariantKey) as? Int,
           Self.bedVariants.indices.contains(stored) {
            applyBedVariant(stored)
        }

        treatBox = Self.treatBoxNode()
        treatBox.position = CGPoint(x: home.maxX - 70, y: home.minY + 145)
        treatBox.zPosition = 6
        addChild(treatBox)

        dog.position = CGPoint(x: home.midX, y: home.midY)
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
        startWatchingWindows()
    }

    override func willMove(from view: SKView) {
        windowSurfaces?.stop()
        windowSurfaces = nil
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

    // MARK: - Coat

    private static let coatKey = "coat"

    /// Swap which set of dog art SpriteLibrary resolves. The texture cache is
    /// keyed by filename so there's nothing to evict, but the dog is holding
    /// textures from the old coat — he has to be told to re-render, and the
    /// worn item re-seated in case the new pose art is a different size.
    private func applyCoat(_ coat: Coat) {
        SpriteLibrary.shared.coat = coat
        UserDefaults.standard.set(coat.rawValue, forKey: Self.coatKey)
        dog.refreshAnimation()
        reseatWornItem()
    }

    private func coatSelectionMenu() -> NSMenu {
        let menu = NSMenu()
        for coat in Coat.allCases {
            let item = NSMenuItem(title: coat.title, action: #selector(coatChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = coat.rawValue
            item.state = SpriteLibrary.shared.coat == coat ? .on : .off
            if let url = Bundle.module.url(
                forResource: "\(coat.filePrefix)idle_south", withExtension: "png", subdirectory: "jumba"
            ), let image = NSImage(contentsOf: url) {
                let height: CGFloat = 30
                image.size = NSSize(width: image.size.width / image.size.height * height, height: height)
                item.image = image
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func coatChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let coat = Coat(rawValue: raw) else { return }
        applyCoat(coat)
    }

    // MARK: - Frame loop

    override func update(_ currentTime: TimeInterval) {
        // Frame delta for the manual movers (zoomies bounce, cursor sniffing),
        // capped so a stalled frame can't teleport him.
        let dt = lastTime == 0 ? 0 : min(currentTime - lastTime, 0.1)
        lastTime = currentTime
        brain.bounds = size
        // Empty on any desk whose displays tile their own bounding box, which
        // is every single-monitor Mac and most two-monitor ones.
        brain.roamableRects = layout.roamableRects
        stepZoomies(dt: dt)
        stepFalling(dt: dt)
        stepSniffing(dt: dt)
        brain.position = dog.position
        // Half his sprite height, live: the pose changes it, and the brain
        // needs it to stand his centre on a window's top edge.
        brain.footOffset = dog.size.height / 2
        stepFrisbeeCatch()
        stepTug(dt: dt)
        send(.tick)
        updateContactShadow()
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

    /// Ambient machine news from the app layer's SystemMonitor. Goes through
    /// the same path as a click or a menu command, so the brain's own rules
    /// about what outranks what apply unchanged. Main thread only.
    func receive(_ signal: SystemSignal) {
        // The build party is the scene's to throw — the brain's `.celebrate`
        // covers every kind of good news, and only this one gets confetti.
        if signal == .buildFinished { showConfetti() }
        send(.system(signal))
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
                // Two poses come with their own puff of air. The brain sends
                // each exactly once on entering the state, so these fire once.
                switch animation {
                case .bark: showBarkPuff()
                case .pounce: showDust()
                default: break
                }
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
                // The catch. The jitter is the payoff; the sparkles sell it.
                nudgeRealCursor()
                showSparkles()
            case .pickUpToy(let kind):
                attachToyToDog(kind)
            case .dropToy(let kind):
                dropToyAtDog(kind)
            case .removeToy(let kind):
                removeToy(kind)
            case .startTug:
                beginTug()
            case .stopTug:
                endTug()
            case .hopTo(let point):
                dog.hop(to: point, height: Self.perchHopHeight, duration: Self.perchHopDuration)
            case .startFalling(let toY):
                startFalling(toY: toY)
            case .stopFalling:
                stopFalling()
            case .absorbLanding:
                dog.absorb()
                showDust()
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
        let clamped = layout.clamp(CGPoint(
            x: min(max(landing.x, margin), size.width - margin),
            y: min(max(landing.y, margin), size.height - margin)
        ), inset: margin)

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
        let clamped = layout.clamp(CGPoint(
            x: min(max(landing.x, margin), size.width - margin),
            y: min(max(landing.y, margin), size.height - margin)
        ), inset: margin)

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

    // The squeaky: no aiming, just a short hop to somewhere nearby.
    private static let squeakyHopRange: ClosedRange<CGFloat> = 130...240

    private func makeSqueakyNode() -> SKSpriteNode {
        if let anim = SpriteLibrary.shared.singleProp(named: "toy_chicken") {
            let node = SKSpriteNode(texture: anim.textures[0])
            node.size = CGSize(width: 36, height: 36)
            return node
        }
        return SKSpriteNode(color: .systemYellow, size: CGSize(width: 36, height: 36))
    }

    /// Somewhere near him and on screen. A few tries, then just clamp — a dog
    /// wedged in a corner still gets a toy, it's simply closer than usual.
    private func squeakyHopTarget() -> CGPoint {
        let margin: CGFloat = 40
        for _ in 0..<8 {
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let distance = CGFloat.random(in: Self.squeakyHopRange)
            let point = CGPoint(
                x: dog.position.x + cos(angle) * distance,
                y: dog.position.y + sin(angle) * distance
            )
            if (margin...(size.width - margin)).contains(point.x),
               (margin...(size.height - margin)).contains(point.y),
               layout.contains(point, inset: margin) {
                return point
            }
        }
        return layout.clamp(CGPoint(
            x: min(max(dog.position.x + Self.squeakyHopRange.lowerBound, margin), size.width - margin),
            y: min(max(dog.position.y, margin), size.height - margin)
        ), inset: margin)
    }

    private func tossSqueaky() {
        squeaky?.removeFromParent()
        let toy = makeSqueakyNode()
        toy.zPosition = 5
        let origin = dog.position
        let start = CGPoint(x: origin.x, y: origin.y + 20)
        toy.position = start
        addChild(toy)
        squeaky = toy

        let landing = squeakyHopTarget()
        // Same "flight" key as the disc, so attachToyToDog kills the hop if he
        // gets there before it lands.
        toy.run(Self.hopArc(from: start, to: landing, height: 70, duration: 0.5), withKey: "flight")
        send(.toyThrown(kind: .squeaky, landing: landing, origin: origin))
    }

    /// Ball.swift's parabola, for toys that don't need a node class of their own.
    private static func hopArc(
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

    // MARK: - Tug of war

    /// How much of the user's pull the rope actually gives up. Under 1 means
    /// the free end never reaches the cursor: the gap IS the resistance, and
    /// the harder you pull the further behind your cursor the rope sits.
    private static let tugResistGain: CGFloat = 0.55
    /// Spring rate of the free end chasing its resisted target (per second).
    /// Low enough to feel elastic, high enough not to feel broken.
    private static let tugSpringRate: CGFloat = 11
    /// Rope length at rest, and how much further you can stretch it before
    /// `force` reads as a maximum-effort pull.
    private static let ropeRestLength: CGFloat = 140
    private static let ropePullSpan: CGFloat = 220
    /// Yanks: a hard pull back toward him, roughly this often, this far.
    private static let yankInterval: ClosedRange<TimeInterval> = 0.9...1.7
    private static let yankDuration: TimeInterval = 0.26
    private static let yankDistance: CGFloat = 34
    /// Past this much of a pull (0...1) the rope is drawn strained.
    private static let tugTautForce: CGFloat = 0.5

    /// The dog's end of the rope — his mouth, in scene coordinates.
    private func ropeAnchor() -> CGPoint {
        CGPoint(x: dog.position.x + dog.mouthOffset.x, y: dog.position.y + dog.mouthOffset.y)
    }

    /// Toys > Tug Rope: the rope lands in front of him, free end out. No
    /// brain event yet — the game starts when the user grabs that end.
    private func dropTugRope() {
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
            x: min(max(anchor.x + v.x * Self.ropeRestLength, margin), size.width - margin),
            y: min(max(anchor.y + v.y * Self.ropeRestLength, margin), size.height - margin)
        ), inset: margin)
        ropePull = ropeEnd
        rope.layout(from: anchor, to: ropeEnd)
        settleRope()
    }

    /// A rope nobody is holding lies there a while, then tidies itself away.
    /// Grabbing it again cancels the countdown (see `mouseDown`).
    private func settleRope() {
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
    private func stepTug(dt: TimeInterval) {
        guard let rope else { return }
        let anchor = ropeAnchor()

        if carryingRope {
            // Victory lap: it trails behind him as he swaggers off. Nobody is
            // pulling any more, so it hangs slack.
            rope.setTaut(false)
            let v = dog.facing.unitVector
            ropeEnd = CGPoint(
                x: anchor.x - v.x * Self.ropeRestLength * 0.8,
                y: anchor.y - v.y * Self.ropeRestLength * 0.8
            )
            rope.layout(from: anchor, to: ropeEnd)
            return
        }
        guard draggingRope, dt > 0 else { return }

        // Resisted target: only a fraction of the pull is conceded.
        var target = CGPoint(
            x: anchor.x + (ropePull.x - anchor.x) * Self.tugResistGain,
            y: anchor.y + (ropePull.y - anchor.y) * Self.tugResistGain
        )

        // A yank drags the end back toward him for a fraction of a second.
        if lastTime >= nextYank {
            yankPhase = 1
            nextYank = lastTime + TimeInterval.random(in: Self.yankInterval)
        }
        if yankPhase > 0 {
            yankPhase = max(0, yankPhase - CGFloat(dt / Self.yankDuration))
            let pulse = sin(.pi * (1 - yankPhase)) * Self.yankDistance
            let dx = target.x - anchor.x
            let dy = target.y - anchor.y
            let length = max(hypot(dx, dy), 1)
            target = CGPoint(x: target.x - dx / length * pulse, y: target.y - dy / length * pulse)
        }

        // Springy follow, so the rope arrives at the target with some give.
        let ease = min(1, CGFloat(dt) * Self.tugSpringRate)
        ropeEnd = CGPoint(
            x: ropeEnd.x + (target.x - ropeEnd.x) * ease,
            y: ropeEnd.y + (target.y - ropeEnd.y) * ease
        )
        rope.layout(from: anchor, to: ropeEnd)
        dog.face(towards: ropeEnd) // brace against the pull

        // Every frame, not on the throttled send: the strain is what the user
        // is watching while they haul, and it should track their arm.
        let force = tugForce()
        rope.setTaut(force >= Self.tugTautForce)
        if lastTime - lastTugSent >= 0.1 { // ~10/s
            lastTugSent = lastTime
            send(.tugMoved(to: ropeEnd, force: force))
        }
    }

    /// How hard they're pulling, 0...1: slack rope reads 0, an arm's-length
    /// haul reads 1.
    private func tugForce() -> CGFloat {
        let anchor = ropeAnchor()
        let stretch = hypot(ropePull.x - anchor.x, ropePull.y - anchor.y) - Self.ropeRestLength
        return min(1, max(0, stretch / (Self.ropePullSpan - Self.ropeRestLength)))
    }

    /// `.startTug`: the brain accepted the grab.
    private func beginTug() {
        nextYank = lastTime + TimeInterval.random(in: Self.yankInterval)
        yankPhase = 0
        lastTugSent = lastTime
        rope?.removeAction(forKey: "linger")
        rope?.alpha = 1
    }

    /// `.stopTug`: the game is over however it ended. The user's drag is
    /// dropped on the spot — a won rope is his now, and there's nothing left
    /// to waggle.
    private func endTug() {
        draggingRope = false
        yankPhase = 0
        rope?.setTaut(false)
    }

    private func removeRope() {
        carryingRope = false
        draggingRope = false
        rope?.fadeOutAndRemove()
        rope = nil
    }

    private func toyNode(_ kind: ToyKind) -> SKSpriteNode? {
        switch kind {
        case .frisbee: return frisbee
        case .squeaky: return squeaky
        case .rope: return nil
        }
    }

    private func attachToyToDog(_ kind: ToyKind) {
        if kind == .rope {
            // He won it. It trails from his mouth for the victory lap.
            carryingRope = true
            draggingRope = false
            return
        }
        guard let toy = toyNode(kind) else { return }
        toy.removeAction(forKey: "flight")
        if let disc = toy as? Frisbee { disc.clampInMouth() }
        toy.removeFromParent()
        dog.addChild(toy)
        reseatCarriedToy()
        if kind == .squeaky { startSqueakySqueezing() }
    }

    /// toy_squash_0..2: the chicken being crushed and springing back. Looping
    /// it only while he has it in his jaws — which is exactly the brain's
    /// `.shakingToy` — makes the toy look worried.
    private func startSqueakySqueezing() {
        guard let squeaky,
              let anim = SpriteLibrary.shared.propSequence(named: "toy_squash", frames: 3, fps: 9)
        else { return }
        squeaky.run(
            .repeatForever(.animate(with: anim.textures, timePerFrame: 1 / anim.fps)),
            withKey: "squeeze"
        )
    }

    /// Keep a carried toy at the dog's mouth as he turns. The dog's own
    /// xScale (±1, mirrored bark art) is divided back out, same as the rabbit.
    private func reseatCarriedToy() {
        for kind in [ToyKind.frisbee, .squeaky] {
            guard let toy = toyNode(kind), toy.parent === dog else { continue }
            let parentFlip: CGFloat = dog.xScale < 0 ? -1 : 1
            toy.position = CGPoint(x: dog.mouthOffset.x * parentFlip, y: dog.mouthOffset.y)
            toy.zPosition = dog.mouthZOffset
            toy.xScale = parentFlip
        }
    }

    private func dropToyAtDog(_ kind: ToyKind) {
        if kind == .rope {
            // Dropped where it lies, and still grabbable for a rematch.
            carryingRope = false
            draggingRope = false
            settleRope()
            return
        }
        guard let toy = toyNode(kind) else { return }
        // Back to the rest pose: stopping `animate` leaves whichever squash
        // frame it was on, and the rest art is its own file now.
        toy.removeAction(forKey: "squeeze")
        if kind == .squeaky, let rest = SpriteLibrary.shared.singleProp(named: "toy_chicken") {
            toy.texture = rest.textures[0]
        }
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
        if kind == .rope {
            removeRope()
            return
        }
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
        case .squeaky: squeaky = nil
        case .rope: break
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
        // The walls are the UNION's edges: crossing from one display to the
        // next mid-zoomies is not a wall, it's the best part.
        let halfW = dog.size.width / 2
        let halfH = dog.size.height / 2
        if p.x < halfW { p.x = halfW; v.x = abs(v.x) }
        if p.x > size.width - halfW { p.x = size.width - halfW; v.x = -abs(v.x) }
        if p.y < halfH { p.y = halfH; v.y = abs(v.y) }
        if p.y > size.height - halfH { p.y = size.height - halfH; v.y = -abs(v.y) }
        // A dead zone is an interior wall. Slide along whichever axis is still
        // on a display and bounce off the other — the same reflection the
        // outer walls get, so it reads as a bounce and not as a stutter. If
        // neither axis works (a corner) he reverses out the way he came.
        if layout.hasDeadZones, !layout.contains(p) {
            let alongX = CGPoint(x: p.x, y: dog.position.y)
            let alongY = CGPoint(x: dog.position.x, y: p.y)
            if layout.contains(alongX) {
                p = alongX
                v.y = -v.y
            } else if layout.contains(alongY) {
                p = alongY
                v.x = -v.x
            } else {
                p = dog.position
                v.x = -v.x
                v.y = -v.y
            }
        }
        zoomiesVelocity = v
        dog.position = p
        dog.face(towards: CGPoint(x: p.x + v.x, y: p.y + v.y))
        // A bounce flips the rabbit even when face() already reseated it.
        reseatCarriedRabbit()
    }

    // MARK: - Window walking: your windows, as somewhere to stand

    /// Polls the window server and keeps `brain.surfaces` current. nil once
    /// the scene has been torn down.
    private var windowSurfaces: WindowSurfaces?
    /// The soft blob under his feet while he's on a ledge — or on the ground
    /// he's falling towards. nil until the first time one is needed.
    private var contactShadow: SKSpriteNode?
    /// Footprint of the shadow when he's standing right on the surface. The
    /// art is a round 32x32 blob; the node squashes it a little so it reads as
    /// ground rather than as a hole (no detail in there to smear).
    private static let contactShadowSize = CGSize(width: 48, height: 26)
    /// Matches the ellipse this replaced: the art is opaque dark grey.
    private static let contactShadowAlpha: CGFloat = 0.34
    /// A fall from this high renders the shadow at its smallest and faintest.
    private static let contactShadowFallSpan: CGFloat = 320

    private func startWatchingWindows() {
        let watcher = WindowSurfaces(geometry: { [weak self] in
            guard let self else { return SurfaceGeometry(flipHeight: 0, sceneOrigin: .zero, sceneSize: .zero) }
            // The overlay covers the union of every display, and the scene is
            // 1:1 with it (resizeFill, anchor at the origin), so the layout's
            // union frame IS the scene's frame in global AppKit coordinates —
            // and its per-display rectangles are what tell the parser which
            // title bars are somewhere a user can actually see.
            return SurfaceGeometry.forOverlay(layout: self.layout)
        })
        watcher.onUpdate = { [weak self] surfaces in self?.windowsChanged(to: surfaces) }
        watcher.start()
        windowSurfaces = watcher
    }

    /// A fresh reading of the windows on screen. Two things happen here, in
    /// this order: he rides a window that moved, and then the brain is told
    /// what the world looks like now.
    private func windowsChanged(to surfaces: [Surface]) {
        rideMovingWindow(to: surfaces)
        brain.surfaces = surfaces
    }

    /// If the window he's standing on has been dragged, slide him by the same
    /// delta so he stays on the title bar — the scene's job, because it owns
    /// the pixels. The brain sees the same delta on its next tick and decides
    /// whether it was gentle enough to survive; the shared `perchRideLimit`
    /// keeps the two answers consistent, so he is never slid somewhere the
    /// brain has already decided he fell from.
    private func rideMovingWindow(to surfaces: [Surface]) {
        guard case .perched(let id) = brain.state,
              let before = brain.surfaces.first(where: { $0.id == id }),
              let after = surfaces.first(where: { $0.id == id })
        else { return }
        let dx = after.rect.minX - before.rect.minX
        let dy = after.rect.maxY - before.rect.maxY
        guard hypot(dx, dy) <= brain.tuning.perchRideLimit else { return }
        dog.position = CGPoint(x: dog.position.x + dx, y: dog.position.y + dy)
    }

    /// A contact shadow so he reads as standing ON the title bar rather than
    /// floating over it — and, mid-fall, as being somewhere above the floor.
    /// Created once, then just moved, scaled and hidden.
    private func updateContactShadow() {
        // On a ledge: parked under his feet, full size.
        if case .perched(let id) = brain.state,
           let surface = brain.surfaces.first(where: { $0.id == id }),
           let shadow = contactShadow ?? makeContactShadow() {
            shadow.isHidden = false
            shadow.position = CGPoint(x: dog.position.x, y: surface.topY + 2)
            shadow.setScale(1)
            shadow.alpha = Self.contactShadowAlpha
            return
        }
        // Falling: it waits on the ground he's heading for and swells as he
        // arrives — the oldest trick there is for reading height.
        if fallVelocity != nil, let shadow = contactShadow ?? makeContactShadow() {
            let drop = min(1, max(0, dog.position.y - fallFloorY) / Self.contactShadowFallSpan)
            shadow.isHidden = false
            // fallFloorY is where his CENTRE comes to rest, so the ground he
            // lands on is half a sprite below it.
            shadow.position = CGPoint(x: dog.position.x, y: fallFloorY - dog.size.height / 2 + 2)
            shadow.setScale(1 - 0.55 * drop)
            shadow.alpha = Self.contactShadowAlpha * (1 - 0.7 * drop)
            return
        }
        contactShadow?.isHidden = true
    }

    /// nil if the art isn't in the bundle — a missing shadow is a better
    /// failure than a black rectangle under the dog.
    private func makeContactShadow() -> SKSpriteNode? {
        guard let anim = SpriteLibrary.shared.singleProp(named: "shadow_blob") else { return nil }
        let shadow = SKSpriteNode(texture: anim.textures[0])
        shadow.size = Self.contactShadowSize
        shadow.alpha = Self.contactShadowAlpha
        shadow.zPosition = dog.zPosition - 1
        addChild(shadow)
        contactShadow = shadow
        return shadow
    }

    /// Paused means the overlay is hidden and the dog is frozen; there is no
    /// reason to keep asking the window server what your windows are doing.
    func setWindowWatching(_ active: Bool) {
        if active { windowSurfaces?.start() } else { windowSurfaces?.stop() }
    }

    // MARK: - Window walking: the hop and the fall
    //
    // The brain decides that he climbs, and that he falls, and where the fall
    // stops. Everything here is pixels: the arc of the hop and the
    // points-per-second of the descent, integrated by hand exactly the way
    // `stepZoomies` is, so the drop accelerates like a real falling dog
    // instead of gliding at a constant SKAction speed.

    /// How high over the straight line the hop onto a ledge arcs.
    private static let perchHopHeight: CGFloat = 60
    private static let perchHopDuration: TimeInterval = 0.45

    /// Downward speed in points/second; nil when he isn't falling.
    private var fallVelocity: CGFloat?
    /// Scene y the current fall stops at (from the brain's `.startFalling`).
    private var fallFloorY: CGFloat = 0

    private func startFalling(toY: CGFloat) {
        // Defensive, like startZoomies: no stale in-flight walk or hop
        // fighting the manual integration.
        dog.removeAction(forKey: "move")
        fallFloorY = toY
        fallVelocity = 0
    }

    private func stopFalling() {
        fallVelocity = nil
    }

    private func stepFalling(dt: TimeInterval) {
        guard let v = fallVelocity, dt > 0 else { return }
        // Terminal velocity keeps a drop from the top of a large display
        // reading as a dog rather than a meteor.
        let next = min(v + brain.tuning.fallAcceleration * CGFloat(dt), brain.tuning.fallMaxSpeed)
        fallVelocity = next
        // Clamped, but NOT cleared: the brain owns the end of the fall. It
        // sees him at the floor on this frame's tick and sends `.stopFalling`.
        dog.position.y = max(dog.position.y - next * CGFloat(dt), fallFloorY)
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
            // target. The cursor may well be on another display — that is fine
            // now, he simply walks there — but the straight line to it can
            // cross a dead zone, so every step lands on solid ground.
            let step = min(brain.tuning.walkSpeed * 1.5 * CGFloat(dt), distance)
            dog.position = huntStep(by: dx / distance * step, dy / distance * step)
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
        dog.position = huntStep(by: dx / distance * step, dy / distance * step)
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
        dog.position = huntStep(by: dx / distance * step, dy / distance * step)
    }

    /// One step of a cursor hunt: inside the scene, and on a real display.
    ///
    /// The clamp is what keeps a chase across an uneven multi-display desk
    /// honest — pushed against a dead zone he slides along its boundary rather
    /// than walking into a region that is drawn nowhere. He can end up parked
    /// at an inside corner if the cursor sits directly across the void from
    /// him, which is the right amount of stupid for a dog.
    private func huntStep(by dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        layout.clamp(CGPoint(
            x: min(max(dog.position.x + dx, 0), size.width),
            y: min(max(dog.position.y + dy, 0), size.height)
        ))
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

    // MARK: - The treat box

    /// Rendered size of the box. Alex's art is 64x64 with the carton drawn
    /// inside a transparent margin; at the props' usual x3 that would be a
    /// 192pt box, twice the dog. This lands its drawn footprint at roughly the
    /// height of the peanut butter jar it replaces.
    private static let treatBoxSize = CGSize(width: 84, height: 84)

    private static func treatBoxNode() -> SKSpriteNode {
        if let anim = SpriteLibrary.shared.singleProp(named: "treat_box") {
            let node = SKSpriteNode(texture: anim.textures[0])
            node.size = treatBoxSize
            return node
        }
        return SKSpriteNode(color: .systemBrown, size: treatBoxSize)
    }

    /// The box's hit region. `frame` is the whole 84pt node, and about 12pt of
    /// each side of that is the art's transparent margin — inset back to the
    /// drawn carton (plus a couple of points of slop) or the box grabs clicks
    /// from empty desktop beside it.
    private func treatBoxFrame() -> CGRect {
        treatBox.frame.insetBy(dx: 10, dy: 2)
    }

    /// The box rocks as he digs a treat out of it: one pass through the wobble
    /// frames, then back to the resting carton.
    private func wobbleTreatBox() {
        guard
            let wobble = SpriteLibrary.shared.propSequence(
                named: "treat_box_wobble", frames: 9, fps: 18
            ),
            let rest = SpriteLibrary.shared.singleProp(named: "treat_box")
        else { return }
        treatBox.removeAction(forKey: "wobble")
        treatBox.run(.sequence([
            .animate(with: wobble.textures, timePerFrame: 1 / wobble.fps,
                     resize: false, restore: false),
            .setTexture(rest.textures[0]),
        ]), withKey: "wobble")
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
        // Released back over (or never left) the box: put the treat away.
        if treatBoxFrame().contains(location) {
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
            showSparkles()
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

    /// How long a fresh pile stays fresh. Past this it dries out — the art
    /// swaps to the pale crusted variant and the flies find it.
    private static let pileDryAge: TimeInterval = 120

    /// Pile art: one of Alex's three hand-made variants, picked at random so
    /// no two piles in a row are the same lump.
    private static func pileNode() -> SKSpriteNode {
        if let real = SpriteLibrary.shared.singleProp(named: "deposit_\(Int.random(in: 1...3))") {
            let node = SKSpriteNode(texture: real.textures[0])
            node.size = real.nodeSize
            return node
        }
        return SKSpriteNode(color: .systemBrown, size: CGSize(width: 36, height: 30))
    }

    /// How long a fresh pile steams for.
    private static let pileSteamDuration: TimeInterval = 20
    /// Gap between wisps.
    private static let pileSteamInterval: TimeInterval = 0.55

    /// It is fresh, and the desktop is cold. Wisps rise out of the pile for
    /// the first twenty seconds and then it's just a pile. The emitter is an
    /// action on the pile node, so it stops the moment the pile is binned.
    private func startSteaming(_ pile: SKSpriteNode) {
        guard let anim = SpriteLibrary.shared.propSequence(named: "steam", frames: 1, fps: 1),
              let texture = anim.textures.first
        else { return }
        let emit = SKAction.run { [weak pile] in
            guard let pile else { return }
            let wisp = SKSpriteNode(texture: texture)
            wisp.size = CGSize(width: 24, height: 24)
            wisp.zPosition = 1
            wisp.alpha = 0
            wisp.position = CGPoint(x: CGFloat.random(in: -7...7), y: 6)
            pile.addChild(wisp)
            wisp.run(.sequence([
                .group([
                    .moveBy(x: CGFloat.random(in: -7...7), y: 28, duration: 1.7),
                    .sequence([
                        .fadeAlpha(to: 0.7, duration: 0.4),
                        .wait(forDuration: 0.5),
                        .fadeOut(withDuration: 0.8),
                    ]),
                ]),
                .removeFromParent(),
            ]))
        }
        pile.run(.repeat(
            .sequence([emit, .wait(forDuration: Self.pileSteamInterval)]),
            count: Int(Self.pileSteamDuration / Self.pileSteamInterval)
        ), withKey: "steam")
    }

    /// Two minutes on the carpet and it isn't fresh any more: the pile crusts
    /// over and picks up an escort. The timer rides on the pile node itself,
    /// so a pile that gets dragged, evicted or binned takes its own schedule
    /// (and its flies, which are children) with it.
    private func startAging(_ pile: SKSpriteNode) {
        guard let dry = SpriteLibrary.shared.singleProp(named: "deposit_dry") else { return }
        pile.run(.sequence([
            .wait(forDuration: Self.pileDryAge),
            .run { [weak self] in
                pile.texture = dry.textures[0]
                pile.size = dry.nodeSize
                self?.addFlies(to: pile)
            },
        ]), withKey: "age")
    }

    /// A couple of flies orbiting an old pile, half a turn out of phase.
    private func addFlies(to pile: SKSpriteNode) {
        guard let anim = SpriteLibrary.shared.propSequence(named: "fly", frames: 2, fps: 8) else { return }
        for (index, phase) in [CGFloat(0), .pi].enumerated() {
            let fly = SKSpriteNode(texture: anim.textures[0])
            fly.size = CGSize(width: 18, height: 18)
            fly.zPosition = 1 // above the pile it's sitting on
            fly.run(.repeatForever(.animate(with: anim.textures, timePerFrame: 1 / anim.fps)))
            // A slow lopsided orbit — wider than it is tall, so it reads as a
            // circle seen at desk level rather than a spinning wheel.
            let period: TimeInterval = 2.6 + 0.4 * Double(index)
            fly.run(.repeatForever(.customAction(withDuration: period) { node, elapsed in
                let angle = phase + 2 * .pi * CGFloat(TimeInterval(elapsed) / period)
                node.position = CGPoint(x: cos(angle) * 22, y: 14 + sin(angle) * 9)
            }))
            pile.addChild(fly)
        }
    }

    /// The hunch finished: a pile lands just behind him, on the ground line.
    private func spawnPile() {
        let pile = Self.pileNode()
        let v = dog.facing.unitVector
        pile.position = layout.clamp(CGPoint(
            x: min(max(dog.position.x - v.x * 34, 18), size.width - 18),
            y: min(max(dog.position.y - v.y * 34 - 10, 15), size.height - 15)
        ), inset: 15)
        pile.zPosition = 4 // above furniture (2), below the dog (10)
        addChild(pile)
        piles.append(pile)
        startSteaming(pile)
        startAging(pile)
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
    ///
    /// Of the PRIMARY display. There is one Dock and one Trash, and they are
    /// on the menu bar screen — the bottom-right of a three-monitor bounding
    /// box is just some spot on a monitor, and dragging a pile there should
    /// leave it sitting there like every other patch of desktop.
    private func isTrashZone(_ point: CGPoint) -> Bool {
        let home = layout.primarySceneFrame
        guard point.x >= home.minX, point.x <= home.maxX, point.y >= home.minY else { return false }
        if point.y < home.minY + 90 { return true }
        return hypot(point.x - home.maxX, point.y - home.minY) < 120
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

    // MARK: - Flourishes
    //
    // Small one-shot effects, all built the same way showHearts() is: spawn a
    // node, give it an action that moves and fades it, have it delete itself.
    // Nothing here holds a reference or needs cleaning up, so nothing here can
    // leak into the next frame.

    /// One flourish sprite: numbered frames played once across `duration`
    /// while it drifts and fades, then gone. Returns nil (and does nothing) if
    /// the art isn't in the bundle.
    @discardableResult
    private func spawnFlourish(
        named name: String, frames: Int, at point: CGPoint, side: CGFloat,
        drift: CGVector, duration: TimeInterval
    ) -> SKSpriteNode? {
        guard let anim = SpriteLibrary.shared.propSequence(
            named: name, frames: frames, fps: Double(frames) / duration
        ) else { return nil }
        let node = SKSpriteNode(texture: anim.textures[0])
        node.size = CGSize(width: side, height: side)
        node.zPosition = 20 // with the hearts: above the dog and everything he owns
        node.position = point
        addChild(node)
        node.run(.animate(with: anim.textures, timePerFrame: duration / Double(frames),
                          resize: false, restore: false))
        node.run(.sequence([
            .group([
                .moveBy(x: drift.dx, y: drift.dy, duration: duration),
                .sequence([
                    .wait(forDuration: duration * 0.5),
                    .fadeOut(withDuration: duration * 0.5),
                ]),
            ]),
            .removeFromParent(),
        ]))
        return node
    }

    /// His mouth, in scene coordinates.
    private func mouthPoint() -> CGPoint {
        CGPoint(x: dog.position.x + dog.mouthOffset.x, y: dog.position.y + dog.mouthOffset.y)
    }

    /// A puff of breath leaving his mouth on a bark. `renderedFacing`, not
    /// `facing`: the bark art is east-only and mirrored, so the mouth he's
    /// actually drawn with may not be pointing where he logically is.
    private func showBarkPuff() {
        let v = dog.renderedFacing.unitVector
        spawnFlourish(
            named: "bark_puff", frames: 3, at: mouthPoint(), side: 30,
            drift: CGVector(dx: v.x * 26, dy: v.y * 14 + 6), duration: 0.45
        )
    }

    /// Dust off the floor where his paws are: a landing, or a pounce leaving
    /// the ground.
    private func showDust() {
        spawnFlourish(
            named: "dust", frames: 4,
            at: CGPoint(x: dog.position.x, y: dog.position.y - dog.size.height / 2 + 8),
            side: 46, drift: CGVector(dx: 0, dy: 10), duration: 0.5
        )
    }

    /// Sparkles over his head: the cursor caught, or a trick that just clicked.
    private func showSparkles() {
        // Varied sizes and lifetimes rather than a stagger — three identical
        // sparkles firing together read as one flash.
        for (side, duration) in [(34 as CGFloat, 0.45), (26, 0.6), (30, 0.75)] {
            spawnFlourish(
                named: "sparkle", frames: 4,
                at: CGPoint(
                    x: dog.position.x + CGFloat.random(in: -30...30),
                    y: dog.position.y + dog.size.height / 2 + CGFloat.random(in: -8...16)
                ),
                side: side, drift: CGVector(dx: CGFloat.random(in: -8...8), dy: 20),
                duration: duration
            )
        }
    }

    /// Ship it: confetti rains down over him.
    ///
    /// Two frames, not three — confetti_2 was delivered as a humanoid
    /// character sprite rather than confetti and isn't imported. See
    /// Tools/import_kit_props.py.
    private func showConfetti() {
        for _ in 0..<7 {
            spawnFlourish(
                named: "confetti", frames: 2,
                at: CGPoint(
                    x: dog.position.x + CGFloat.random(in: -54...54),
                    y: dog.position.y + dog.size.height / 2 + CGFloat.random(in: 8...48)
                ),
                side: CGFloat.random(in: 26...38),
                drift: CGVector(dx: CGFloat.random(in: -16...16), dy: CGFloat.random(in: -78...(-44))),
                duration: Double.random(in: 1.0...1.6)
            )
        }
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
        let dragging = mouseDownOnDog || isCarryingDog || pressedTreatBox
            || treatInHand != nil || draggedFurniture != nil || draggedPile != nil
            || draggingRope
        let shouldAcceptClicks = armedForThrow || dragging
            || interactiveFrames().contains { $0.contains(mouseLocationInScene()) }
        if window.ignoresMouseEvents == shouldAcceptClicks {
            window.ignoresMouseEvents = !shouldAcceptClicks
        }
    }

    private func interactiveFrames() -> [CGRect] {
        [dogHoverFrame(), treatBoxFrame(), bed.frame.insetBy(dx: -6, dy: -6)]
            + piles.map { $0.frame.insetBy(dx: -6, dy: -6) }
            // The free end of the rope is a grab target whenever it's loose.
            + (carryingRope ? [] : [rope?.freeEndFrame()].compactMap { $0 })
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

    // MARK: - Displays coming and going

    /// A display was plugged in, unplugged, moved or resized.
    ///
    /// The subtle part is the ORIGIN. Scene coordinates are measured from the
    /// bottom-left of the union frame, so unplugging a monitor that sat to the
    /// left of the primary moves that corner — and every entity would appear
    /// to leap sideways even though nothing about where they are in the world
    /// changed. Translating by the difference first keeps the dog, the bed and
    /// the treat box exactly where the user left them, on the display they left them
    /// on; only then does anything get clamped, and only if it now has nowhere
    /// to be.
    func apply(layout newLayout: ScreenLayout) {
        let shift = CGPoint(
            x: layout.unionFrame.minX - newLayout.unionFrame.minX,
            y: layout.unionFrame.minY - newLayout.unionFrame.minY
        )
        layout = newLayout
        if shift != .zero { translateWorld(by: shift) }
        clampEntitiesOnScreen()
    }

    /// Everything that lives at a fixed spot in the world.
    ///
    /// Not here, deliberately: transient flourishes (hearts, the cam flash),
    /// anything parented to the dog (his hat, whatever is in his mouth), which
    /// travels with him for free, the contact shadow, which is repositioned from
    /// scratch every frame — and the tug rope, whose own node sits at the
    /// origin while its segments hold scene coordinates, so moving it would
    /// shift the rope twice. The rope is handled through `ropeEnd` below.
    private func worldNodes() -> [SKNode] {
        var nodes: [SKNode] = [dog, bed, treatBox]
        nodes += piles
        for node in [ball, frisbee, squeaky, groundTreat, treatInHand] {
            if let node, node.parent === self { nodes.append(node) }
        }
        return nodes
    }

    /// Slide the whole world so a change of union origin doesn't teleport it.
    private func translateWorld(by shift: CGPoint) {
        for node in worldNodes() {
            node.position = CGPoint(x: node.position.x + shift.x, y: node.position.y + shift.y)
        }
        // Loose scene coordinates that aren't a node's position.
        ropeEnd = CGPoint(x: ropeEnd.x + shift.x, y: ropeEnd.y + shift.y)
        ropePull = CGPoint(x: ropePull.x + shift.x, y: ropePull.y + shift.y)
        fallFloorY += shift.y
    }

    /// Put everything back somewhere real after a resolution or arrangement
    /// change. `ScreenLayout.clamp` returns a point untouched when it is
    /// already on a display, so an entity happily sitting on the second
    /// monitor is never nudged — only the ones now hanging in a dead zone, or
    /// off the end of a display that has just been unplugged, move at all.
    func clampEntitiesOnScreen() {
        for node in worldNodes() {
            node.position = layout.clamp(node.position)
        }
        ropeEnd = layout.clamp(ropeEnd)
        ropePull = layout.clamp(ropePull)
        rope?.layout(from: ropeAnchor(), to: ropeEnd)
        // A fall in progress was aimed at a floor that may no longer exist.
        fallFloorY = layout.clamp(CGPoint(x: dog.position.x, y: fallFloorY)).y
        // Through the event (not a direct assignment) so a dog mid-walk to the
        // bed retargets instead of finishing his walk off-screen.
        send(.bedMoved(to: bedLieSpot()))
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let location = event.location(in: self)
        pressLocation = location
        // Props keep priority over an armed throw so the box/bed stay usable
        // while the dog waits for a throw (dropping a treat cancels the fetch).
        if dogHoverFrame().contains(location) {
            mouseDownOnDog = true
            carryGrabOffset = CGPoint(x: dog.position.x - location.x, y: dog.position.y - location.y)
        } else if treatBoxFrame().contains(location), treatInHand == nil {
            if event.modifierFlags.contains(.option) {
                draggedFurniture = treatBox  // ⌥-drag repositions the box immediately
            } else {
                pressedTreatBox = true       // click takes a treat; a drag moves the box
            }
        } else if bed.frame.insetBy(dx: -6, dy: -6).contains(location) {
            draggedFurniture = bed
        } else if let rope, rope.freeEndFrame().contains(location), !carryingRope {
            // Grabbing the free end starts (or restarts) the tug immediately —
            // no drag threshold: a rope you have to shake first feels dead.
            rope.removeAction(forKey: "linger")
            rope.alpha = 1
            draggingRope = true
            ropePull = location
            ropeEnd = rope.freeEnd
            send(.tugStarted(at: location))
            if brain.state != .tugging { draggingRope = false } // he declined
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
        } else if pressedTreatBox {
            // Same slop pattern as the dog: past the threshold the press
            // becomes a box drag instead of a treat click.
            if hypot(location.x - pressLocation.x, location.y - pressLocation.y) > 8 {
                pressedTreatBox = false
                draggedFurniture = treatBox
                treatBox.position = location
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
        } else if draggingRope {
            // Only the cursor is recorded here; the rope's own position is
            // resolved in stepTug, which is what makes it resist.
            ropePull = location
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = event.location(in: self)
        let wasDraggingRope = draggingRope
        defer {
            mouseDownOnDog = false
            isCarryingDog = false
            draggedFurniture = nil
            draggedPile = nil
            pressedTreatBox = false
            draggingRope = false
        }
        if wasDraggingRope {
            send(.tugEnded) // you let go, so there's no showdown to resolve
            return
        }
        if mouseDownOnDog {
            if isCarryingDog {
                // The overlay spans every display, so a determined drag can let
                // go of him over a dead zone. Put him down somewhere real.
                send(.dropped(at: layout.clamp(
                    CGPoint(x: location.x + carryGrabOffset.x, y: location.y + carryGrabOffset.y)
                )))
            } else {
                send(.petted)
            }
        } else if pressedTreatBox {
            // Released under the drag threshold: a plain click takes a treat,
            // and the box rocks as he digs one out.
            treatInHand = makeTreat(at: location)
            wobbleTreatBox()
        } else if treatInHand != nil {
            dropTreat(at: location)
        } else if let pile = draggedPile {
            dropPile(pile, at: location)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Never open the menu mid-drag: its tracking session would swallow the
        // mouseUp and wedge the drag state (stuck carry, leaked treat).
        guard !mouseDownOnDog, !pressedTreatBox, treatInHand == nil,
              draggedFurniture == nil, draggedPile == nil, !draggingRope else { return }
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
        let coat = NSMenuItem(title: "Coat", action: nil, keyEquivalent: "")
        coat.submenu = coatSelectionMenu()
        menu.addItem(coat)
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

    private static let toyMenuEntries: [(String, ToyKind)] = [
        ("Frisbee", .frisbee),
        ("Squeaky Toy", .squeaky),
        ("Tug Rope", .rope),
    ]

    @objc private func toyChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ToyChoice else { return }
        switch choice.kind {
        case .frisbee:
            // Arms the throw: the next left-click anywhere sails the disc
            // there. Only remember the kind if he actually took the toy —
            // he ignores commands while he's in your arms, and a stale
            // armedToy would turn the NEXT plain fetch into a frisbee.
            send(.command(.toy(.frisbee)))
            armedToy = brain.state == .awaitingThrow ? .frisbee : nil
        case .squeaky:
            // No aiming — it just goes somewhere near him and he goes after it.
            tossSqueaky()
        case .rope:
            // Dropped in front of him, free end out. Grab it to start.
            dropTugRope()
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
        // Only the display he's standing on. The scene spans the whole desk,
        // and whiting out three monitors to photograph one dog is a jump
        // scare, not feedback.
        let area = layout.sceneFrame(containing: dog.position)
            ?? CGRect(origin: .zero, size: size)
        let flash = SKSpriteNode(color: .white, size: area.size)
        flash.anchorPoint = .zero
        flash.position = area.origin
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
