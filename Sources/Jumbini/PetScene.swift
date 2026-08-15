import SpriteKit

/// The transparent scene the dog lives in. Owns per-frame mouse polling and
/// the click-through toggle, routes interactions to the brain, and applies
/// the brain's effects to the sprites.
final class PetScene: SKScene {
    weak var overlayWindow: NSWindow?

    private let dog = Dog()
    private var ball: Ball?
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

    // Zoomies: manual bounce integration; nil while he isn't zooming.
    private var zoomiesVelocity: CGPoint?
    /// The fur rabbit he carries during zoomies (a child of the dog).
    private var rabbit: SKSpriteNode?

    // Mouse sniffing: he tracks the cursor while the brain's timer runs.
    private var isSniffing = false
    /// Near/far sub-state so walk/sniff anims only switch on transitions.
    private var sniffingClose = false

    /// Fetch was chosen: the next left-click anywhere throws the ball.
    private var armedForThrow = false
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
        send(.tick)
        updateClickThrough()
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
            case .playSound, .nudgeCursor,
                 .pickUpToy, .dropToy, .removeToy, .startTug, .stopTug:
                break // vocabulary stubs — wired by feature branches
            }
        }
    }

    // MARK: - Fetch plumbing

    private func throwBall(to landing: CGPoint) {
        armedForThrow = false
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

    // MARK: - Mouse sniffing

    private func stepSniffing(dt: TimeInterval) {
        guard isSniffing, dt > 0 else { return }
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
            let oldest = piles.removeFirst()
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
            throwBall(to: location)
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
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func commandChosen(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DogCommand else { return }
        send(.command(command))
    }
}
