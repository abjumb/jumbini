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
    /// Get a toy out of the box and wait for it to be thrown (the kind-aware
    /// sibling of `.fetch`). Only the frisbee uses it today: the squeaky is
    /// tossed by the scene without aiming, and the rope needs no throw.
    case toy(ToyKind)
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
    /// Running down a thrown toy. Named for the frisbee, used by every
    /// thrown toy — `chasedToy` says which one, and decides what happens on
    /// arrival (carry the frisbee home; shake the squeaky where it lands).
    case chasingFrisbee
    case shakingToy
    case tugging
    /// Trotting back with a toy in his mouth (the frisbee's return leg, and
    /// the victory lap after he wins a tug).
    case returningToy(ToyKind)
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
    /// Odds that a finished sniff escalates into a stalk-and-pounce hunt
    /// instead of ending quietly.
    var pounceChance: Double = 0.6
    var trickDuration: TimeInterval = 1.5
    var shakeToyDuration: TimeInterval = 2.0
    var tugTimeout: TimeInterval = 12
    /// Backstop for a Do Not Disturb sleep, which otherwise has no deadline.
    /// The `dndOff` signal can never arrive (the Focus database is
    /// unreadable without Full Disk Access), and a sleep with no exit reads
    /// as a hung app.
    var dndSleepSafety: TimeInterval = 900
    /// Odds he wins when a tug-of-war goes the distance. A straight coin
    /// flip: he's a small dog with a lot of conviction.
    var tugWinChance: Double = 0.5
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
    /// Which toy the armed throw will launch (nil = the fetch ball). Keeps
    /// `.awaitingThrow` kind-aware so a ball throw can't hijack a frisbee.
    private var armedToy: ToyKind?
    /// The toy he's currently running down (set on `.toyThrown`).
    private var chasedToy: ToyKind?
    /// Where he stood when a toy was thrown — the frisbee's return point.
    private var toyReturnPoint: CGPoint?
    /// Where the tug is being pulled from (the free end of the rope).
    private var tugPullPoint: CGPoint?
    /// State to resume after a petting session (dog stays sitting/lying).
    private var petReturn: DogState?
    /// State to resume after a bark (same pattern as `petReturn`).
    private var barkReturn: DogState?
    /// When the last bark started — provocations inside `barkCooldown` are ignored.
    private var lastBark: TimeInterval?
    /// Which system signal parked him in a rest state (nap, conserve lie,
    /// DND sleep). Wake-up signals only act when their counterpart caused the
    /// state — a nap or lie-down he chose on his own is never interrupted.
    private enum RestReason { case userIdle, batteryLow, doNotDisturb }
    private var restReason: RestReason?
    /// A machine signal that arrived while he had momentum. The monitor is
    /// edge-triggered — it reports the Focus switch flipping, not that Focus
    /// is on — so dropping one loses the reaction for the whole session.
    /// Held here and replayed on the first calm tick instead.
    private var pendingSignal: SystemSignal?

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
            armedToy = nil
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
        case .system(let signal):
            return handleSystemSignal(signal, at: now)
        case .toyThrown(let kind, let landing, let origin):
            return handleToyThrown(kind: kind, landing: landing, origin: origin, at: now)
        case .tugStarted(let point):
            return handleTugStarted(at: point, now: now)
        case .tugMoved(let point, _):
            guard state == .tugging else { return [] }
            // The pull itself is the scene's problem (rope stretch, yanks).
            // The brain only notes which way it's coming from, so a win
            // sends him trotting off in the opposite direction.
            tugPullPoint = point
            return []
        case .tugEnded:
            guard state == .tugging else { return [] }
            tugPullPoint = nil
            return [.stopTug, .dropToy(.rope)] + enterIdle(at: now)
        }
    }

    // MARK: - Event handling

    private func handleTick(at now: TimeInterval) -> [DogEffect] {
        // First tick after entering idle externally (initial state): start the timer.
        if state == .idle && deadline == nil {
            deadline = now + random(in: tuning.idleDuration)
            return []
        }
        // He's settled and the machine had something to say while he was busy.
        if isCalm, let parked = pendingSignal {
            pendingSignal = nil
            return handleSystemSignal(parked, at: now)
        }
        guard let deadline, now >= deadline else { return [] }
        switch state {
        case .idle:
            return leaveIdleForAutonomy(at: now)
        case .sitting, .lyingDown, .spinning, .sleeping, .performingTrick:
            return enterIdle(at: now)
        case .hunching:
            // Hunch complete: the pile is the only thing the hunger meter
            // ever produces. Both roads lead here — the autonomous roll and
            // the eating → hunching digestion pipeline.
            return [.leaveDeposit] + enterIdle(at: now)
        case .eating:
            // Treats go straight through him; the hunger meter never budges.
            state = .hunching
            self.deadline = now + tuning.hunchDuration
            return [.play(.hunch)]
        case .awaitingThrow:
            armedToy = nil
            return [.disarmThrow] + enterIdle(at: now)
        case .shakingToy:
            // Squeaker exhausted: spit it out and wander off.
            chasedToy = nil
            return [.dropToy(.squeaky)] + enterIdle(at: now)
        case .tugging:
            return resolveTug(at: now)
        case .beingPetted:
            return endPetting(at: now)
        case .barking:
            return endBarking(at: now)
        case .zoomies:
            return [.stopZoomies] + enterIdle(at: now)
        case .sniffingMouse:
            // The trail's gone cold — or has it? Sometimes the sniff escalates
            // into a full hunt: stalk low and slow, then pounce.
            if Double.random(in: 0..<1, using: &rng) < tuning.pounceChance {
                state = .stalkingMouse
                self.deadline = now + tuning.stalkDuration
                // No .stopSniffing: the scene keeps tracking the cursor.
                return [.play(.stalk)]
            }
            return [.stopSniffing] + enterIdle(at: now)
        case .stalkingMouse:
            state = .pouncing
            self.deadline = now + tuning.pounceDuration
            return [.play(.pounce)]
        case .pouncing:
            // The catch: jitter the real cursor, celebrate, trot off proud.
            return [.stopSniffing, .nudgeCursor, .celebrate] + enterIdle(at: now)
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
                // A DND-caused bedtime has no wake deadline — he sleeps
                // until the humans lift the signal.
                deadline = restReason == .doNotDisturb ? nil : now + random(in: tuning.sleepDuration)
                return [.play(.sleep)]
            }
        case .chasingTreat:
            state = .eating
            deadline = now + tuning.eatDuration
            return [.eatTreat, .play(.happy), .showHearts]
        case .chasingFrisbee:
            return reachedThrownToy(at: now)
        case .returningToy(let kind):
            toyReturnPoint = nil
            chasedToy = nil
            return [.dropToy(kind), .celebrate] + enterIdle(at: now)
        default:
            return []
        }
    }

    /// He got to the toy — by catching the frisbee out of the air, or by
    /// picking it up off the ground once it settled (the scene decides when
    /// to send `.arrived`; the brain treats both the same).
    private func reachedThrownToy(at now: TimeInterval) -> [DogEffect] {
        let kind = chasedToy ?? .frisbee
        switch kind {
        case .squeaky:
            // The squeaky isn't retrieved, it's MURDERED. He shakes it where
            // it landed until the novelty wears off.
            state = .shakingToy
            deadline = now + tuning.shakeToyDuration
            return [.pickUpToy(.squeaky), .play(.shakeToy), .playSound("squeak")]
        case .frisbee, .rope:
            state = .returningToy(kind)
            deadline = nil
            let home = toyReturnPoint ?? position
            return [.pickUpToy(kind), .play(.carryWalk), .moveTo(home, speed: tuning.carrySpeed)]
        }
    }

    private func handleCommand(_ command: DogCommand, at now: TimeInterval) -> [DogEffect] {
        // No commands while he's in your arms (matches petted/treatDropped).
        guard state != .carried else { return [] }
        // An explicit command overrides any machine-caused rest: whatever he
        // does next is user-caused, so wake-up signals must not act on it.
        restReason = nil
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
            armedToy = nil // the plain ball
            deadline = now + tuning.throwTimeout
            effects.append(contentsOf: [.play(.sit), .armThrow])
        case .toy(let kind):
            // Same waiting pose as fetch, but the armed throw remembers which
            // toy it is so `.toyThrown`/`.ballThrown` can't cross wires.
            state = .awaitingThrow
            armedToy = kind
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
        case .trick(let trick):
            state = .performingTrick(trick)
            deadline = now + tuning.trickDuration
            effects.append(.play(Self.animation(for: trick)))
        }
        return effects
    }

    private func handleBallThrown(landing: CGPoint, origin: CGPoint, at now: TimeInterval) -> [DogEffect] {
        guard state == .awaitingThrow, armedToy == nil else { return [] }
        state = .chasingBall
        deadline = nil
        fetchReturnPoint = origin
        return [.play(.run), .moveTo(landing, speed: tuning.runSpeed)]
    }

    /// A toy is in the air. The frisbee comes out of the armed throw (aimed
    /// by the user, like fetch); the squeaky is lobbed by the scene from
    /// wherever he is, so it interrupts whatever he was doing.
    private func handleToyThrown(
        kind: ToyKind, landing: CGPoint, origin: CGPoint, at now: TimeInterval
    ) -> [DogEffect] {
        switch kind {
        case .frisbee:
            guard state == .awaitingThrow, armedToy == .frisbee else { return [] }
            armedToy = nil
            return startToyChase(kind: kind, landing: landing, origin: origin)
        case .squeaky:
            // No aiming and no armed state: the scene lobs it nearby, so the
            // toss interrupts whatever he was doing (like a dropped treat).
            guard state != .carried, state != .eating else { return [] }
            // keepToy, same reasoning as keepTreat: the scene swaps the node
            // before sending this event, so removing "the squeaky" here would
            // delete the toy that just landed, not the stale one.
            let cleanup = interruptionCleanup(keepToy: .squeaky)
            armedToy = nil
            petReturn = nil
            return [.stopMoving] + cleanup
                + startToyChase(kind: kind, landing: landing, origin: origin)
        case .rope:
            // The rope is never thrown — it's dropped and tugged.
            return []
        }
    }

    /// The user grabbed the free end of the rope and pulled. He plants his
    /// feet and holds on until someone gives — the `tugTimeout` deadline is
    /// the showdown, and it is NOT extended by pulling harder.
    private func handleTugStarted(at point: CGPoint, now: TimeInterval) -> [DogEffect] {
        // Not while he's in your arms — you can't have it both ways.
        guard state != .carried else { return [] }
        tugPullPoint = point
        guard state != .tugging else { return [] } // already braced
        let cleanup = interruptionCleanup()
        petReturn = nil
        state = .tugging
        deadline = now + tuning.tugTimeout
        return [.stopMoving] + cleanup + [.startTug, .play(.tug)]
    }

    /// Nobody let go: the rope decides it. A win means he takes the prize on
    /// a short, insufferably proud trot AWAY from whoever was pulling.
    private func resolveTug(at now: TimeInterval) -> [DogEffect] {
        let won = Double.random(in: 0..<1, using: &rng) < tuning.tugWinChance
        let pull = tugPullPoint
        tugPullPoint = nil
        guard won else {
            return [.stopTug, .dropToy(.rope)] + enterIdle(at: now)
        }
        state = .returningToy(.rope)
        deadline = nil
        toyReturnPoint = nil
        return [.stopTug, .pickUpToy(.rope), .celebrate,
                .play(.carryWalk), .moveTo(victoryTrot(from: pull), speed: tuning.carrySpeed)]
    }

    /// A short retreat directly away from the pull, kept inside the margins.
    private func victoryTrot(from pull: CGPoint?) -> CGPoint {
        var dx = position.x - (pull?.x ?? position.x + 1)
        var dy = position.y - (pull?.y ?? position.y)
        let length = hypot(dx, dy)
        if length < 0.001 {
            dx = -1; dy = 0
        } else {
            dx /= length; dy /= length
        }
        let margin = tuning.wanderMargin
        let step = Self.tugVictoryTrot
        return CGPoint(
            x: min(max(position.x + dx * step, margin), max(margin, bounds.width - margin)),
            y: min(max(position.y + dy * step, margin), max(margin, bounds.height - margin))
        )
    }

    /// How far he swaggers off with a won rope.
    private static let tugVictoryTrot: CGFloat = 60

    private func startToyChase(kind: ToyKind, landing: CGPoint, origin: CGPoint) -> [DogEffect] {
        state = .chasingFrisbee
        deadline = nil
        chasedToy = kind
        toyReturnPoint = origin
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

    // MARK: - System reactions (ambient machine status as a dog)

    /// States mellow enough for machine news to matter. Anything with
    /// momentum — chases, tricks, the arms, an armed throw — outranks the
    /// machine; sleeping is special-cased by the wake-up signals only.
    private var isCalm: Bool {
        switch state {
        case .idle, .wandering, .sitting, .lyingDown: return true
        default: return false
        }
    }

    /// Park a signal he was too busy for. Wake-ups are not parked: they only
    /// matter against a rest this same machine caused, and `riseFromRest`
    /// already no-ops when the reason doesn't match. A newer signal wins —
    /// the machine's latest word is the true one.
    private func deferSignal(_ signal: SystemSignal) -> [DogEffect] {
        switch signal {
        case .idleEnded, .batteryNormal, .dndOff:
            pendingSignal = nil // the rest it would end never happened
        default:
            pendingSignal = signal
        }
        return []
    }

    private func handleSystemSignal(_ signal: SystemSignal, at now: TimeInterval) -> [DogEffect] {
        switch signal {
        case .buildFinished:
            // Ship it! A brief party — celebrate overlays the current art.
            guard isCalm else { return deferSignal(signal) }
            // Celebrate in place while conserving: enterIdle would clear
            // restReason, and batteryLow is edge-triggered, so the conserve
            // would be lost for the rest of the discharge.
            if restReason != nil { return [.celebrate, .showHearts] }
            return [.stopMoving, .celebrate, .showHearts] + enterIdle(at: now)
        case .idleBegan:
            // Human's wandered off — nap time, same path as an autonomous nap.
            guard isCalm else { return deferSignal(signal) }
            restReason = .userIdle
            return [.stopMoving] + restfulSleep(at: now)
        case .idleEnded:
            return riseFromRest(ended: .userIdle, at: now)
        case .fansUp:
            // The machine's working hard; so should he.
            guard isCalm else { return deferSignal(signal) }
            state = .zoomies
            deadline = now + tuning.zoomiesDuration
            return [.stopMoving, .play(.run), .startZoomies]
        case .batteryLow:
            // Conserve energy: lie down (in the bed when he has one).
            guard isCalm else { return deferSignal(signal) }
            restReason = .batteryLow
            return [.stopMoving] + restfulLie(at: now)
        case .batteryNormal:
            return riseFromRest(ended: .batteryLow, at: now)
        case .dndOn:
            // Do Not Disturb means exactly that: off to bed, no wake deadline.
            guard isCalm else { return deferSignal(signal) }
            restReason = .doNotDisturb
            return [.stopMoving] + restfulSleep(at: now)
        case .dndOff:
            return riseFromRest(ended: .doNotDisturb, at: now)
        }
    }

    /// The existing sleep path (bed-aware), used by system-caused naps.
    /// A DND sleep gets no wake deadline — it lasts until the signal lifts.
    private func restfulSleep(at now: TimeInterval) -> [DogEffect] {
        if let bed = bedPosition {
            state = .goingToBed(.sleep)
            deadline = nil
            return [.play(.walk), .moveTo(bed, speed: tuning.walkSpeed)]
        }
        state = .sleeping
        // A DND sleep lasts until the signal lifts, but never forever: dndOff
        // can genuinely never arrive, and a state with no exit reads as a hang.
        deadline = restReason == .doNotDisturb
            ? now + tuning.dndSleepSafety
            : now + random(in: tuning.sleepDuration)
        return [.play(.sleep)]
    }

    /// The existing lie-down path (bed-aware), used by the battery conserve.
    private func restfulLie(at now: TimeInterval) -> [DogEffect] {
        if let bed = bedPosition {
            state = .goingToBed(.lie)
            deadline = nil
            return [.play(.walk), .moveTo(bed, speed: tuning.walkSpeed)]
        }
        state = .lyingDown
        deadline = now + tuning.lieTimeout
        return [.play(.lie)]
    }

    /// A wake-up signal arrived: get up only if its counterpart put him
    /// there. Covers the walk to bed too — the trip is cancelled mid-stride.
    private func riseFromRest(ended reason: RestReason, at now: TimeInterval) -> [DogEffect] {
        guard restReason == reason else { return [] }
        switch state {
        case .sleeping, .lyingDown:
            return enterIdle(at: now)
        case .goingToBed:
            return [.stopMoving] + enterIdle(at: now)
        default:
            // The reason is stale only until something re-idles him;
            // meanwhile he's busy with whatever interrupted the rest.
            return []
        }
    }

    // MARK: - Transitions

    private func enterIdle(at now: TimeInterval) -> [DogEffect] {
        state = .idle
        deadline = now + random(in: tuning.idleDuration)
        restReason = nil // every road back to idle ends a signal-caused rest
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
            // The cooldown is a property of barking, not of one trigger: a
            // provoked bark must silence this band too, or he double-barks.
            if lastBark.map({ now - $0 >= tuning.barkCooldown }) ?? true {
                lastBark = now
                barkReturn = nil
                state = .barking
                deadline = now + tuning.barkDuration
                return [.moveTo(nearestEdgeNudge(), speed: tuning.walkSpeed),
                        .play(.bark), .playSound("borf")]
            }
            // Still cooling down: fall through to a wander instead.
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
    private func interruptionCleanup(
        keepTreat: Bool = false, keepToy: ToyKind? = nil
    ) -> [DogEffect] {
        switch state {
        case .awaitingThrow:
            armedToy = nil
            return [.disarmThrow]
        case .chasingBall, .returningBall:
            fetchReturnPoint = nil
            return [.removeBall]
        case .chasingFrisbee:
            let kind = chasedToy ?? .frisbee
            chasedToy = nil
            toyReturnPoint = nil
            return kind == keepToy ? [] : [.removeToy(kind)]
        case .returningToy(let kind):
            chasedToy = nil
            toyReturnPoint = nil
            return kind == keepToy ? [] : [.removeToy(kind)]
        case .shakingToy:
            chasedToy = nil
            return keepToy == .squeaky ? [] : [.removeToy(.squeaky)]
        case .tugging:
            // The scene must drop the user's drag immediately, or they'd be
            // left waggling a rope he has walked away from.
            tugPullPoint = nil
            return [.stopTug, .removeToy(.rope)]
        case .zoomies:
            return [.stopZoomies]
        case .sniffingMouse, .stalkingMouse, .pouncing:
            // The whole hunt keeps cursor tracking live, so any interruption
            // at any escalation stage must switch it off.
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

    /// Which animation performs a given trick.
    private static func animation(for trick: Trick) -> DogAnimation {
        switch trick {
        case .shake: return .shakePaw
        case .highFive: return .highFive
        case .playDead: return .playDead
        case .rollOver: return .rollOver
        }
    }

    private func random(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        Double.random(in: range, using: &rng)
    }
}
