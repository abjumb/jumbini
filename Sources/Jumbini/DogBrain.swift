import Foundation
import CoreGraphics

// MARK: - Vocabulary shared between the brain (pure logic) and the scene (rendering)

enum DogAnimation: String, Equatable {
    case idle, walk, run, sit, lie, sleep, spin, carryWalk, happy, dangle, sniff, hunch
    case bark, stalk, pounce, shakePaw, highFive, playDead, rollOver, shakeToy, tug
}

/// Tricks the dog can be taught. Raw value doubles as the menu title.
enum Trick: String, CaseIterable, Equatable {
    case shake = "Shake"
    case highFive = "High Five"
    case playDead = "Play Dead"
    case rollOver = "Roll Over"
}

/// Toys beyond the fetch ball.
enum ToyKind: Equatable {
    case frisbee, squeaky, rope
}

/// Ambient machine happenings the scene layer can feed the brain.
enum SystemSignal: Equatable {
    case buildFinished, idleBegan, idleEnded, fansUp, batteryLow, batteryNormal, dndOn, dndOff
}

enum DogCommand: Equatable {
    case sit, lieDown, spin, fetch, spinForever, zoomies, relax
    case trick(Trick)
}

/// Why the dog is heading to his bed.
enum BedGoal: Equatable {
    case lie, sleep
}

enum DogState: Equatable {
    case idle
    case wandering
    case sitting
    case lyingDown
    case spinning
    case sleeping
    case goingToBed(BedGoal)
    case awaitingThrow
    case chasingBall
    case returningBall
    case chasingTreat
    case eating
    case beingPetted
    case carried
    case zoomies
    case sniffingMouse
    case hunching
    case barking
    case stalkingMouse
    case pouncing
    case performingTrick(Trick)
    case chasingFrisbee
    case shakingToy
    case tugging
}

enum DogEvent: Equatable {
    case tick
    case arrived
    case command(DogCommand)
    case ballThrown(landing: CGPoint, origin: CGPoint)
    case throwCancelled
    case treatDropped(at: CGPoint)
    case bedMoved(to: CGPoint)
    case petted
    case pickedUp
    case dropped(at: CGPoint)
    case provoked(at: CGPoint)
    case system(SystemSignal)
    case toyThrown(kind: ToyKind, landing: CGPoint, origin: CGPoint)
    case tugStarted(at: CGPoint)
    case tugMoved(to: CGPoint, force: CGFloat)
    case tugEnded
}

/// Side effects the scene applies (animations, movement, ball control).
enum DogEffect: Equatable {
    case play(DogAnimation)
    case moveTo(CGPoint, speed: CGFloat)
    case stopMoving
    case armThrow
    case disarmThrow
    case pickUpBall
    case dropBall
    case removeBall
    case eatTreat
    case showHearts
    case celebrate
    case startZoomies
    case stopZoomies
    case startSniffing
    case stopSniffing
    case removeTreat
    case playSound(String)
    case leaveDeposit
    case nudgeCursor
    case pickUpToy(ToyKind)
    case dropToy(ToyKind)
    case removeToy(ToyKind)
    case startTug
    case stopTug
}

/// All timing/probability/speed knobs, overridable in tests for determinism.
struct BrainTuning {
    var idleDuration: ClosedRange<TimeInterval> = 2...5
    var sitTimeout: TimeInterval = 60
    var lieTimeout: TimeInterval = 90
    var spinDuration: TimeInterval = 0.9
    var petDuration: TimeInterval = 1.2
    var sleepDuration: ClosedRange<TimeInterval> = 10...20
    var throwTimeout: TimeInterval = 10
    var sleepChance: Double = 0.15
    var flourishChance: Double = 0.10
    var eatDuration: TimeInterval = 1.1
    var walkSpeed: CGFloat = 90
    var runSpeed: CGFloat = 520
    var carrySpeed: CGFloat = 150
    var wanderMargin: CGFloat = 60
    var zoomiesDuration: TimeInterval = 10
    var zoomiesSpeed: CGFloat = 900
    var zoomiesChance: Double = 0.08
    var sniffDuration: ClosedRange<TimeInterval> = 100...140
    var sniffChance: Double = 0.12
    var hunchDuration: TimeInterval = 2.5
    var hunchChance: Double = 0.06
    var barkDuration: TimeInterval = 1.2
    /// Minimum gap between barks (measured bark-start to bark-start) so a
    /// hovering cursor can't machine-gun him.
    var barkCooldown: TimeInterval = 8
    /// Rare idle break: bark at the Dock / his own reflection.
    var barkAtNothingChance: Double = 0.04
    /// How far he steps toward the screen edge so the bark faces something.
    var barkEdgeStep: CGFloat = 12
    var stalkDuration: TimeInterval = 3.0
    var pounceDuration: TimeInterval = 0.5
    var trickDuration: TimeInterval = 1.5
    var shakeToyDuration: TimeInterval = 2.0
    var tugTimeout: TimeInterval = 12
}

/// Deterministic RNG for tests (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Brain

/// Pure behavior state machine. No SpriteKit — the scene feeds it events with
/// timestamps and applies the effects it returns.
final class DogBrain {
    private(set) var state: DogState = .idle

    /// Screen area the dog may roam (scene keeps this current).
    var bounds: CGSize
    /// Dog's position (scene keeps this current; brain uses it to pick targets).
    var position: CGPoint
    /// Where his bed is, if there is one — lie-down and naps route here.
    var bedPosition: CGPoint?

    let tuning: BrainTuning
    private var rng: any RandomNumberGenerator

    init(
        bounds: CGSize,
        position: CGPoint,
        tuning: BrainTuning = BrainTuning(),
        rng: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.bounds = bounds
        self.position = position
        self.tuning = tuning
        self.rng = rng
    }

    /// Deadline for the current state's timer (idle boredom, sit timeout, …).
    private var deadline: TimeInterval?
    /// Where the dog stood when the ball was thrown — the fetch return point.
    private var fetchReturnPoint: CGPoint?
    /// State to resume after a petting session (dog stays sitting/lying).
    private var petReturn: DogState?
    /// State to resume after a bark (same pattern as `petReturn`).
    private var barkReturn: DogState?
    /// When the last bark started — provocations inside `barkCooldown` are ignored.
    private var lastBark: TimeInterval?

    func handle(_ event: DogEvent, at now: TimeInterval) -> [DogEffect] {
        switch event {
        case .tick:
            return handleTick(at: now)
        case .arrived:
            return handleArrived(at: now)
        case .command(let command):
            return handleCommand(command, at: now)
        case .ballThrown(let landing, let origin):
            return handleBallThrown(landing: landing, origin: origin, at: now)
        case .throwCancelled:
            guard state == .awaitingThrow else { return [] }
            return [.disarmThrow] + enterIdle(at: now)
        case .treatDropped(let point):
            return handleTreatDropped(at: point, now: now)
        case .bedMoved(let point):
            return handleBedMoved(to: point)
        case .petted:
            return handlePetted(at: now)
        case .pickedUp:
            return handlePickedUp(at: now)
        case .dropped(let point):
            return handleDropped(at: point, now: now)
        case .provoked:
            return handleProvoked(at: now)
        case .system, .toyThrown, .tugStarted, .tugMoved, .tugEnded:
            // Vocabulary landed ahead of behavior — feature branches wire these.
            return []
        }
    }

    // MARK: - Event handling

    private func handleTick(at now: TimeInterval) -> [DogEffect] {
        // First tick after entering idle externally (initial state): start the timer.
        if state == .idle && deadline == nil {
            deadline = now + random(in: tuning.idleDuration)
            return []
        }
        guard let deadline, now >= deadline else { return [] }
        switch state {
        case .idle:
            return leaveIdleForAutonomy(at: now)
        case .sitting, .lyingDown, .spinning, .sleeping, .hunching:
            return enterIdle(at: now)
        case .eating:
            // Treats go straight through him; the hunger meter never budges.
            state = .hunching
            self.deadline = now + tuning.hunchDuration
            return [.play(.hunch)]
        case .awaitingThrow:
            return [.disarmThrow] + enterIdle(at: now)
        case .beingPetted:
            return endPetting(at: now)
        case .barking:
            return endBarking(at: now)
        case .zoomies:
            return [.stopZoomies] + enterIdle(at: now)
        case .sniffingMouse:
            return [.stopSniffing] + enterIdle(at: now)
        default:
            return []
        }
    }

    private func handleArrived(at now: TimeInterval) -> [DogEffect] {
        switch state {
        case .wandering:
            return enterIdle(at: now)
        case .chasingBall:
            state = .returningBall
            let home = fetchReturnPoint ?? position
            return [.pickUpBall, .play(.carryWalk), .moveTo(home, speed: tuning.carrySpeed)]
        case .returningBall:
            fetchReturnPoint = nil
            return [.dropBall, .celebrate] + enterIdle(at: now)
        case .goingToBed(let goal):
            switch goal {
            case .lie:
                state = .lyingDown
                deadline = now + tuning.lieTimeout
                return [.play(.lie)]
            case .sleep:
                state = .sleeping
                deadline = now + random(in: tuning.sleepDuration)
                return [.play(.sleep)]
            }
        case .chasingTreat:
            state = .eating
            deadline = now + tuning.eatDuration
            return [.eatTreat, .play(.happy), .showHearts]
        default:
            return []
        }
    }

    private func handleCommand(_ command: DogCommand, at now: TimeInterval) -> [DogEffect] {
        // No commands while he's in your arms (matches petted/treatDropped).
        guard state != .carried else { return [] }
        var effects: [DogEffect] = [.stopMoving] + interruptionCleanup()
        switch command {
        case .sit:
            state = .sitting
            deadline = now + tuning.sitTimeout
            effects.append(.play(.sit))
        case .lieDown:
            if let bed = bedPosition {
                // He has a bed — walk over and settle in.
                state = .goingToBed(.lie)
                deadline = nil
                effects.append(contentsOf: [.play(.walk), .moveTo(bed, speed: tuning.walkSpeed)])
            } else {
                state = .lyingDown
                deadline = now + tuning.lieTimeout
                effects.append(.play(.lie))
            }
        case .spin:
            state = .spinning
            deadline = now + tuning.spinDuration
            effects.append(.play(.spin))
        case .fetch:
            state = .awaitingThrow
            deadline = now + tuning.throwTimeout
            effects.append(contentsOf: [.play(.sit), .armThrow])
        case .spinForever:
            // Like .spin, but no deadline — he keeps going until interrupted.
            state = .spinning
            deadline = nil
            effects.append(.play(.spin))
        case .zoomies:
            state = .zoomies
            deadline = now + tuning.zoomiesDuration
            effects.append(contentsOf: [.play(.run), .startZoomies])
        case .relax:
            effects.append(contentsOf: enterIdle(at: now))
        case .trick:
            // Vocabulary stub — the trick-training branch wires performingTrick.
            break
        }
        return effects
    }

    private func handleBallThrown(landing: CGPoint, origin: CGPoint, at now: TimeInterval) -> [DogEffect] {
        guard state == .awaitingThrow else { return [] }
        state = .chasingBall
        deadline = nil
        fetchReturnPoint = origin
        return [.play(.run), .moveTo(landing, speed: tuning.runSpeed)]
    }

    private func handleTreatDropped(at point: CGPoint, now: TimeInterval) -> [DogEffect] {
        switch state {
        case .carried, .eating:
            // In your arms, or mouth already full.
            return []
        default:
            // Peanut butter outranks everything else, including naps and fetch.
            // keepTreat: on a re-drop the scene swaps the treat node itself.
            let cleanup = interruptionCleanup(keepTreat: true)
            petReturn = nil
            state = .chasingTreat
            deadline = nil
            return [.stopMoving] + cleanup + [.play(.run), .moveTo(point, speed: tuning.runSpeed)]
        }
    }

    private func handleBedMoved(to point: CGPoint) -> [DogEffect] {
        bedPosition = point
        if case .goingToBed = state {
            // Cancel the in-flight walk first, like every other retarget path.
            return [.stopMoving, .moveTo(point, speed: tuning.walkSpeed)]
        }
        return []
    }

    private func handlePetted(at now: TimeInterval) -> [DogEffect] {
        switch state {
        case .carried:
            return []
        case .beingPetted:
            // Keep petting: extend the session, more hearts.
            deadline = now + tuning.petDuration
            return [.showHearts]
        default:
            let cleanup = interruptionCleanup()
            petReturn = (state == .sitting || state == .lyingDown) ? state : nil
            state = .beingPetted
            deadline = now + tuning.petDuration
            return [.stopMoving, .play(.happy), .showHearts] + cleanup
        }
    }

    private func handlePickedUp(at now: TimeInterval) -> [DogEffect] {
        guard state != .carried else { return [] }
        let cleanup = interruptionCleanup()
        state = .carried
        deadline = nil
        return [.stopMoving, .play(.dangle)] + cleanup
    }

    private func handleDropped(at point: CGPoint, now: TimeInterval) -> [DogEffect] {
        guard state == .carried else { return [] }
        position = point
        return enterIdle(at: now)
    }

    /// The cursor lingered over him: bark at it, unless something that outranks
    /// barking (arms, food, a chase, affection) is in progress.
    private func handleProvoked(at now: TimeInterval) -> [DogEffect] {
        switch state {
        case .idle, .sitting, .lyingDown, .wandering:
            if let lastBark, now - lastBark < tuning.barkCooldown { return [] }
            lastBark = now
            barkReturn = (state == .sitting || state == .lyingDown) ? state : nil
            state = .barking
            deadline = now + tuning.barkDuration
            return [.stopMoving, .play(.bark), .playSound("borf")]
        default:
            return []
        }
    }

    // MARK: - Transitions

    private func enterIdle(at now: TimeInterval) -> [DogEffect] {
        state = .idle
        deadline = now + random(in: tuning.idleDuration)
        return [.play(.idle)]
    }

    /// Idle timer fired: mostly wander, sometimes nap, rarely a spin flourish.
    private func leaveIdleForAutonomy(at now: TimeInterval) -> [DogEffect] {
        let roll = Double.random(in: 0..<1, using: &rng)
        if roll < tuning.sleepChance {
            if let bed = bedPosition {
                // Naps happen in the bed when he has one.
                state = .goingToBed(.sleep)
                deadline = nil
                return [.play(.walk), .moveTo(bed, speed: tuning.walkSpeed)]
            }
            state = .sleeping
            deadline = now + random(in: tuning.sleepDuration)
            return [.play(.sleep)]
        }
        if roll < tuning.sleepChance + tuning.flourishChance {
            state = .spinning
            deadline = now + tuning.spinDuration
            return [.play(.spin)]
        }
        if roll < tuning.sleepChance + tuning.flourishChance + tuning.zoomiesChance {
            state = .zoomies
            deadline = now + tuning.zoomiesDuration
            return [.play(.run), .startZoomies]
        }
        if roll < tuning.sleepChance + tuning.flourishChance + tuning.zoomiesChance + tuning.sniffChance {
            state = .sniffingMouse
            deadline = now + random(in: tuning.sniffDuration)
            return [.play(.walk), .startSniffing]
        }
        if roll < tuning.sleepChance + tuning.flourishChance + tuning.zoomiesChance
            + tuning.sniffChance + tuning.hunchChance {
            state = .hunching
            deadline = now + tuning.hunchDuration
            return [.play(.hunch)]
        }
        if roll < tuning.sleepChance + tuning.flourishChance + tuning.zoomiesChance
            + tuning.sniffChance + tuning.hunchChance + tuning.barkAtNothingChance {
            // Something at the screen edge (the Dock? his reflection?) needs
            // telling off. A small step toward the edge turns him to face it;
            // .arrived from that hop is ignored while barking.
            lastBark = now
            barkReturn = nil
            state = .barking
            deadline = now + tuning.barkDuration
            return [.moveTo(nearestEdgeNudge(), speed: tuning.walkSpeed),
                    .play(.bark), .playSound("borf")]
        }
        state = .wandering
        deadline = nil
        let margin = tuning.wanderMargin
        let target = CGPoint(
            x: CGFloat.random(in: margin...(bounds.width - margin), using: &rng),
            y: CGFloat.random(in: margin...(bounds.height - margin), using: &rng)
        )
        return [.play(.walk), .moveTo(target, speed: tuning.walkSpeed)]
    }

    /// Bark finished: resume sitting/lying if that's what was interrupted.
    private func endBarking(at now: TimeInterval) -> [DogEffect] {
        defer { barkReturn = nil }
        switch barkReturn {
        case .sitting:
            state = .sitting
            deadline = now + tuning.sitTimeout
            return [.play(.sit)]
        case .lyingDown:
            state = .lyingDown
            deadline = now + tuning.lieTimeout
            return [.play(.lie)]
        default:
            return enterIdle(at: now)
        }
    }

    /// Petting session over: resume sitting/lying if that's what was interrupted.
    private func endPetting(at now: TimeInterval) -> [DogEffect] {
        defer { petReturn = nil }
        switch petReturn {
        case .sitting:
            state = .sitting
            deadline = now + tuning.sitTimeout
            return [.play(.sit)]
        case .lyingDown:
            state = .lyingDown
            deadline = now + tuning.lieTimeout
            return [.play(.lie)]
        default:
            return enterIdle(at: now)
        }
    }

    /// Effects needed to abandon the current activity when something interrupts it.
    /// `keepTreat` skips treat removal — a re-dropped treat swaps the node in the
    /// scene, so emitting `.removeTreat` there would delete the NEW treat.
    private func interruptionCleanup(keepTreat: Bool = false) -> [DogEffect] {
        switch state {
        case .awaitingThrow:
            return [.disarmThrow]
        case .chasingBall, .returningBall:
            fetchReturnPoint = nil
            return [.removeBall]
        case .zoomies:
            return [.stopZoomies]
        case .sniffingMouse:
            return [.stopSniffing]
        case .chasingTreat:
            return keepTreat ? [] : [.removeTreat]
        case .barking:
            barkReturn = nil // the interrupter decides what happens next
            return []
        default:
            return []
        }
    }

    // MARK: - Helpers

    /// A point a short step toward the nearest screen edge — walking there
    /// turns the dog to face whatever he's decided lives just off-screen.
    private func nearestEdgeNudge() -> CGPoint {
        let step = tuning.barkEdgeStep
        let toLeft = position.x
        let toRight = bounds.width - position.x
        let toBottom = position.y
        let toTop = bounds.height - position.y
        let nearest = min(toLeft, toRight, toBottom, toTop)
        if nearest == toLeft { return CGPoint(x: position.x - step, y: position.y) }
        if nearest == toRight { return CGPoint(x: position.x + step, y: position.y) }
        if nearest == toBottom { return CGPoint(x: position.x, y: position.y - step) }
        return CGPoint(x: position.x, y: position.y + step)
    }

    private func random(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        Double.random(in: range, using: &rng)
    }
}
