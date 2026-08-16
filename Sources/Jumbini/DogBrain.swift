import Foundation
import CoreGraphics

// MARK: - Vocabulary shared between the brain (pure logic) and the scene (rendering)

enum DogAnimation: String, Equatable {
    case idle, walk, run, sit, lie, sleep, spin, carryWalk, happy, dangle, sniff, hunch
    case bark, stalk, pounce, shakePaw, highFive, playDead, rollOver, shakeToy, tug
    /// Window walking: legs out mid-air, the touchdown absorb, and the
    /// nose-over-the-edge pose at the end of a title-bar patrol.
    case fall, land, peek
}

/// A window the dog can stand on top of, in SCENE coordinates (bottom-left
/// origin) so the brain never has to think about window-server geometry.
///
/// Produced by `WindowSurfaces` (the app layer, which owns the
/// CGWindowList call and the coordinate flip) and handed to
/// `DogBrain.surfaces`, exactly the way the scene keeps `bounds`/`position`
/// current. The brain treats these as facts and only decides what to do
/// with them.
struct Surface: Equatable {
    /// The window's CGWindowID. Stable for the life of the window, which is
    /// what lets `.perched(surfaceID:)` survive a poll that reorders the list
    /// — and what makes a *missing* id mean "that window is gone".
    let id: CGWindowID
    /// The window's frame in scene coordinates. `rect.maxY` is the perch line.
    let rect: CGRect
    /// The window title when the system gives us one. On modern macOS this is
    /// gated by Screen Recording permission (the geometry is not), so it can
    /// be nil on a perfectly healthy machine — never rely on it.
    let title: String?
    let ownerPID: pid_t

    /// The y a dog's FEET rest at when standing on this window.
    var topY: CGFloat { rect.maxY }
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

    // Window walking. The four stages of climbing onto one of your windows:
    // walk to the near edge, hop up, patrol the title bar, come back down.
    /// Walking along the floor towards the near edge of a window.
    case headingToSurface(surfaceID: CGWindowID)
    /// Mid-air on the way up. The scene renders the arc.
    case hoppingUp(surfaceID: CGWindowID)
    /// Standing on a window's top edge, trotting from end to end.
    case perched(surfaceID: CGWindowID)
    /// On the way down, under gravity the scene integrates.
    case falling
    /// Mid-air between two windows — the parkour hop. Like `.hoppingUp`, the
    /// scene renders the arc; unlike it, the dog took off from a window rather
    /// than the floor, so the whole adventure shares one boredom clock.
    case hoppingAcross(toID: CGWindowID)
    /// Napping on a sufficiently wide, stable title bar.
    case perchSleeping(surfaceID: CGWindowID)
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
    /// Leap to a point along an arc (the hop onto a window's top edge). Like
    /// `.moveTo`, the scene reports `.arrived` when he gets there.
    case hopTo(CGPoint)
    /// Start integrating gravity, stopping at this scene y. The brain decides
    /// WHEN he falls and WHERE he stops; the scene owns the pixels per second
    /// in between (the `stepZoomies` pattern).
    case startFalling(toY: CGFloat)
    /// Cancel a fall in progress (mirrors `.stopZoomies`).
    case stopFalling
    /// Touchdown: a brief squash-and-recover flourish over whatever comes
    /// next, in the same one-shot spirit as `.celebrate`. Named for the
    /// landing rather than `.landed` so it can't be misread as an event.
    case absorbLanding
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

    // MARK: Window walking

    /// Rare idle break: climb onto one of your windows. Deliberately the
    /// least likely thing he does — it should feel like catching him at it.
    var perchChance: Double = 0.05
    /// How far he'll walk to reach a window's edge before deciding it isn't
    /// worth the trip.
    var perchSearchRadius: CGFloat = 700
    /// The tallest climb he'll attempt, measured from his feet to the title
    /// bar. Anything higher and the hop reads as teleporting.
    var perchReach: CGFloat = 420
    /// How far in from the corner he lands and turns around, so he's never
    /// drawn teetering half off the end.
    var perchEdgeInset: CGFloat = 24
    /// How long a perch lasts before he gets bored and hops down.
    var perchDuration: ClosedRange<TimeInterval> = 18...36
    /// The pause at the end of each patrol leg, nose over the edge.
    var peekDuration: TimeInterval = 1.4
    /// How far a window may jump between two polls while he's aboard. Under
    /// this he rides along; over it the drag is violent enough to shake him
    /// off, which is the whole joke.
    var perchRideLimit: CGFloat = 180
    /// Downward acceleration for a fall, in points per second squared. Read
    /// by the scene, which does the integrating (see `zoomiesSpeed`).
    var fallAcceleration: CGFloat = 2_000
    /// Terminal velocity, so a fall from the top of a big display still reads
    /// as a dog and not a meteor.
    var fallMaxSpeed: CGFloat = 1_400

    // MARK: Window parkour

    /// While perched, the odds he hops onto a NEIGHBOURING window instead of
    /// turning around at the end of a patrol leg. Rare on purpose: parkour is
    /// a joke you catch him at, not a commute.
    var parkourChance: Double = 0.25
    /// Base reach limits for a window-to-window hop, pre-scale. The brain
    /// multiplies by `dogScale` before building the graph.
    var parkourRise: CGFloat = 160
    var parkourDrop: CGFloat = 420
    var parkourGap: CGFloat = 240
    /// Odds a wide-enough ledge sends him to sleep instead of another lap.
    var perchNapChance: Double = 0.2
    var perchNapDuration: ClosedRange<TimeInterval> = 8...16
    /// A title bar narrower than this (pre-scale) is too skinny to nap on.
    var perchNapMinWidth: CGFloat = 320
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
    /// The parts of `bounds` that are solid ground, in the same coordinates —
    /// kept current by the scene, exactly like `bounds` and `surfaces`.
    ///
    /// EMPTY (the default) means every point inside `bounds` is fair game,
    /// which is the one-display case and therefore the overwhelming majority
    /// of the time; the code below takes the identical path it always did.
    ///
    /// Non-empty means the world has HOLES in it. On a multi-display desk the
    /// scene spans the bounding box of every display, and an uneven
    /// arrangement leaves corners of that box on no display at all — points
    /// that exist as far as arithmetic is concerned and nowhere at all as far
    /// as the user is concerned. A dog who wanders into one has vanished.
    ///
    /// Plain rectangles on purpose: the brain does not know that a hole is
    /// caused by a monitor, any more than it knows that a `Surface` is a
    /// window. The app layer's `ScreenLayout` is what fills this in.
    var roamableRects: [CGRect] = []
    /// Dog's position (scene keeps this current; brain uses it to pick targets).
    var position: CGPoint
    /// Where his bed is, if there is one — lie-down and naps route here.
    var bedPosition: CGPoint?
    /// The windows he could stand on, front-most first, in scene coordinates
    /// (the scene keeps this current from `WindowSurfaces`, exactly like
    /// `bounds` and `position`). Empty means "no windows" — every window
    /// behavior below degrades to nothing at all, and he stays on the desktop.
    var surfaces: [Surface] = []
    /// User-facing settings. These live on the brain rather than being baked
    /// into tuning so a panel change takes effect without rebuilding the scene.
    var poopEnabled = true
    var windowClimbingEnabled = true
    /// How far the dog's CENTRE sits above his feet — half his sprite height,
    /// which changes with the pose, so the scene keeps it current. Standing on
    /// a window means `position.y == surface.topY + footOffset`.
    var footOffset: CGFloat = 0
    /// The dog's current size as a scale factor (1.0 = baseline). Applied to
    /// parkour reach limits and the nap-width floor so the graph is built
    /// against the size he is now. Size controls (ticket 05) will keep this
    /// current; today it stays 1.0.
    var dogScale: CGFloat = 1.0

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

    // Window walking bookkeeping. All of it is cleared together by
    // `forgetPerch()`, which every interruption path runs.
    /// The perch window's rect as of the last tick. Comparing it with the
    /// current one is how a window drag is detected.
    private var perchAnchor: CGRect?
    /// Where the current patrol leg is headed, so a window drag can shift it.
    private var perchTarget: CGPoint?
    /// When he's had enough of this window.
    private var perchExpiry: TimeInterval?
    /// The height he climbed FROM, and therefore the height a fall returns
    /// him to. nil when he didn't climb (dropped out of the user's hand).
    private var groundY: CGFloat?
    /// Where the current fall ends. The scene integrates towards it; the
    /// brain watches `position` and calls the landing.
    private var fallTargetY: CGFloat = 0

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

    /// Stop any machine-triggered rest and forget parked machine news when
    /// the user disables Mac-aware reactions. Without this, turning the
    /// monitor off during a Focus sleep could leave him waiting for an
    /// `dndOff` edge that will never be delivered.
    func disableSystemReactions(at now: TimeInterval) -> [DogEffect] {
        pendingSignal = nil
        guard restReason != nil else { return [] }
        restReason = nil
        switch state {
        case .sleeping, .lyingDown, .goingToBed:
            return [.stopMoving] + enterIdle(at: now)
        default:
            // A treat, toy, pet, or pickup may already have interrupted the
            // rest. Preserve that foreground activity; only the reason is
            // stale, not the state the user deliberately put him in.
            return []
        }
    }

    /// Turn bathroom breaks off immediately. Eating may finish normally, but
    /// a break already in progress is cancelled instead of leaving the dog in
    /// the hunch pose until the old deadline.
    func disableBathroomBreaks(at now: TimeInterval) -> [DogEffect] {
        poopEnabled = false
        guard state == .hunching else { return [] }
        return [.stopMoving] + enterIdle(at: now)
    }

    // MARK: - Event handling

    private func handleTick(at now: TimeInterval) -> [DogEffect] {
        // First tick after entering idle externally (initial state): start the timer.
        if state == .idle && deadline == nil {
            deadline = now + random(in: tuning.idleDuration)
            return []
        }
        // Window walking is watched on EVERY tick, deadline or no deadline:
        // the window under him can be dragged, closed or minimised at any
        // moment, and a fall is driven by his position rather than a timer.
        // Physical reality first: a vanishing ledge outranks stale machine news.
        if let effects = superviseWindowWalking(at: now) { return effects }
        // He's settled and the machine had something to say while he was busy.
        // (Unreachable while window walking — none of those states are calm.)
        if isCalm, let parked = pendingSignal {
            pendingSignal = nil
            return handleSystemSignal(parked, at: now)
        }
        guard let deadline, now >= deadline else { return [] }
        switch state {
        case .idle:
            return leaveIdleForAutonomy(at: now)
        case .perched(let id):
            // The peek at the end of a patrol leg is over: turn around — or,
            // rarely, hop to a neighbour or settle down for a nap.
            guard let surface = surface(id) else { return beginFalling(at: now) }
            return decideNextMoveOn(surface, at: now)
        case .perchSleeping(let id):
            // Nap over: wake and resume patrolling. The perch expiry check on
            // the next tick still ends the adventure if he over-slept.
            guard let surface = surface(id) else { return beginFalling(at: now) }
            state = .perched(surfaceID: id)
            return startPatrolLeg(on: surface)
        case .sitting, .lyingDown, .spinning, .sleeping, .performingTrick:
            return enterIdle(at: now)
        case .hunching:
            // Hunch complete: the pile is the only thing the hunger meter
            // ever produces. Both roads lead here — the autonomous roll and
            // the eating → hunching digestion pipeline.
            return (poopEnabled ? [.leaveDeposit] : []) + enterIdle(at: now)
        case .eating:
            // Treats go straight through him; the hunger meter never budges.
            guard poopEnabled else { return enterIdle(at: now) }
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
        case .headingToSurface(let id):
            // At the near edge, looking up. The window may have moved during
            // the walk, so the hop is aimed from its CURRENT rect.
            guard let surface = surface(id) else {
                // It closed while he was walking over. Oh well — he's still
                // on the floor, so there's nothing to fall from.
                return [.stopMoving] + enterIdle(at: now)
            }
            state = .hoppingUp(surfaceID: id)
            deadline = nil
            return [.play(.pounce), .hopTo(perchLanding(on: surface))]
        case .hoppingUp(let id):
            guard let surface = surface(id) else { return beginFalling(at: now) }
            state = .perched(surfaceID: id)
            deadline = nil
            perchAnchor = surface.rect
            perchExpiry = now + random(in: tuning.perchDuration)
            return startPatrolLeg(on: surface)
        case .hoppingAcross(let id):
            guard let surface = surface(id) else { return beginFalling(at: now) }
            state = .perched(surfaceID: id)
            deadline = nil
            perchAnchor = surface.rect
            // Do NOT reset perchExpiry: the whole adventure shares one boredom
            // clock, so a parkour chain is naturally short.
            return startPatrolLeg(on: surface)
        case .perched:
            // End of a patrol leg: a beat spent looking over the edge before
            // he turns around. The tick handler starts the next leg.
            perchTarget = nil
            deadline = now + tuning.peekDuration
            return [.play(.peek)]
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
        return [.stopMoving] + cleanup + [.startTug, .play(.tug), .playSound("grunt")]
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
        return onSolidGround(CGPoint(
            x: min(max(position.x + dx * step, margin), max(margin, bounds.width - margin)),
            y: min(max(position.y + dy * step, margin), max(margin, bounds.height - margin))
        ))
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
        // Let go over one of your windows and he drops onto its title bar.
        // Only a WINDOW causes this: he roams the whole screen freely, so a
        // plain drop on empty desktop must leave him exactly where you put
        // him rather than dragging him to the bottom of the display.
        if surfaceTop(under: point) != nil {
            return beginFalling(at: now)
        }
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
            return [.stopMoving, .play(.bark), barkSound()]
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
            if restReason != nil { return [.celebrate, .showHearts, .playSound("yip")] }
            return [.stopMoving, .celebrate, .showHearts, .playSound("yip")] + enterIdle(at: now)
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
            return [.stopMoving, .playSound("whine")] + restfulLie(at: now)
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
        let activeHunchChance = poopEnabled ? tuning.hunchChance : 0
        let activePerchChance = windowClimbingEnabled ? tuning.perchChance : 0
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
            + tuning.sniffChance + activeHunchChance {
            state = .hunching
            deadline = now + tuning.hunchDuration
            return [.play(.hunch)]
        }
        if roll < tuning.sleepChance + tuning.flourishChance + tuning.zoomiesChance
            + tuning.sniffChance + activeHunchChance + tuning.barkAtNothingChance {
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
                        .play(.bark), .playSound("growl")]
            }
            // Still cooling down: fall through to a wander instead.
        }
        if roll < tuning.sleepChance + tuning.flourishChance + tuning.zoomiesChance
            + tuning.sniffChance + activeHunchChance + tuning.barkAtNothingChance
            + activePerchChance {
            // The rarest idle break: climb onto one of your windows and trot
            // along the title bar. Needs a window to climb — with none in
            // reach the roll quietly becomes an ordinary wander rather than
            // disturbing the cumulative bands below it.
            if let surface = perchableSurface() {
                return startPerchApproach(to: surface)
            }
        }
        state = .wandering
        deadline = nil
        return [.play(.walk), .moveTo(wanderTarget(), speed: tuning.walkSpeed)]
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
        case .headingToSurface, .hoppingUp, .hoppingAcross, .perched, .perchSleeping:
            // Whatever interrupted him outranks a window. He simply leaves
            // it — the interrupter's own `.moveTo` carries him off the ledge,
            // and clearing the bookkeeping here is what stops a later tick
            // deciding he's still up there and ought to fall.
            forgetPerch()
            groundY = nil
            return []
        case .falling:
            forgetPerch()
            groundY = nil
            return [.stopFalling]
        default:
            return []
        }
    }

    // MARK: - Window walking
    //
    // The division of labour, which is the whole design:
    //
    //   * The SCENE knows what the windows are doing. It polls them
    //     (`WindowSurfaces`), keeps `surfaces`, `position` and `footOffset`
    //     current, slides the dog along when the window he's on is dragged,
    //     and integrates gravity pixel by pixel during a fall.
    //   * The BRAIN knows what he's doing about it. It picks the window,
    //     sequences approach → hop → patrol, and decides — from the facts the
    //     scene reports — the moment a perch becomes a fall and the height
    //     that fall ends at.
    //
    // Nothing here touches AppKit or the window server; `Surface` is already
    // in scene coordinates by the time it arrives.

    /// Distances below this count as "the same place" — a window that hasn't
    /// really moved, or a fall that has really arrived.
    private static let perchEpsilon: CGFloat = 0.5

    /// Per-tick supervision of the four window-walking states. Returns nil
    /// when it has nothing to say and the normal deadline machinery should
    /// run; returns effects when it has taken the tick over.
    private func superviseWindowWalking(at now: TimeInterval) -> [DogEffect]? {
        if !windowClimbingEnabled {
            switch state {
            case .headingToSurface:
                return [.stopMoving] + enterIdle(at: now)
            case .hoppingUp, .hoppingAcross, .perched, .perchSleeping:
                return beginFalling(at: now)
            default:
                break
            }
        }
        switch state {
        case .headingToSurface(let id):
            // The window closed mid-walk: abandon the trip, stay on the floor.
            guard surface(id) == nil else { return nil }
            return [.stopMoving] + enterIdle(at: now)
        case .hoppingUp(let id):
            // The window closed mid-air. Gravity does the rest.
            guard surface(id) == nil else { return nil }
            return beginFalling(at: now)
        case .hoppingAcross(let id):
            // The target window closed mid-hop. Gravity does the rest.
            guard surface(id) == nil else { return nil }
            return beginFalling(at: now)
        case .perched(let id):
            return supervisePerch(surfaceID: id, at: now)
        case .perchSleeping(let id):
            return supervisePerchSleep(surfaceID: id, at: now)
        case .falling:
            // The scene has been moving him down; has he arrived?
            guard position.y <= fallTargetY + Self.perchEpsilon else { return [] }
            return land(at: now)
        default:
            return nil
        }
    }

    /// Everything that can go wrong while standing on someone's window, in
    /// the order it matters.
    private func supervisePerch(surfaceID id: CGWindowID, at now: TimeInterval) -> [DogEffect]? {
        // 1. The window closed, minimised, or went to another Space.
        guard let surface = surface(id) else { return beginFalling(at: now) }

        // 2. It moved. A gentle drag he rides along with (the scene slides
        //    him by the same delta); a violent one throws him off.
        var effects: [DogEffect] = []
        if let anchor = perchAnchor {
            let dx = surface.rect.minX - anchor.minX
            let dy = surface.rect.maxY - anchor.maxY
            let travelled = hypot(dx, dy)
            if travelled > tuning.perchRideLimit { return beginFalling(at: now) }
            if travelled > Self.perchEpsilon {
                perchAnchor = surface.rect
                // The in-flight walk is aimed at where the window USED to be.
                if let target = perchTarget {
                    let shifted = clampToLedge(
                        CGPoint(x: target.x + dx, y: target.y + dy), on: surface
                    )
                    perchTarget = shifted
                    effects += [.stopMoving, .moveTo(shifted, speed: tuning.walkSpeed)]
                }
            }
        } else {
            perchAnchor = surface.rect
        }

        // 3. He's no longer over the window at all — he trotted off the end,
        //    or it shrank/slid out from under him.
        if position.x < surface.rect.minX || position.x > surface.rect.maxX {
            return beginFalling(at: now)
        }

        // 4. Bored. A deliberate hop down, which is just a fall he chose.
        if let expiry = perchExpiry, now >= expiry { return beginFalling(at: now) }

        return effects.isEmpty ? nil : effects
    }

    /// The ledge under a napping dog. A window that vanishes or is yanked away
    /// wakes him the hard way; a gentle ride he sleeps through — same rules as
    /// a patrol, because the physics underneath him doesn't care whether his
    /// eyes are open.
    private func supervisePerchSleep(surfaceID id: CGWindowID, at now: TimeInterval) -> [DogEffect]? {
        guard let surface = surface(id) else { return beginFalling(at: now) }

        if let anchor = perchAnchor {
            let dx = surface.rect.minX - anchor.minX
            let dy = surface.rect.maxY - anchor.maxY
            let travelled = hypot(dx, dy)
            if travelled > tuning.perchRideLimit { return beginFalling(at: now) }
            if travelled > Self.perchEpsilon { perchAnchor = surface.rect }
        } else {
            perchAnchor = surface.rect
        }

        // A window that shrank or slid out from under him leaves him in the air.
        if position.x < surface.rect.minX || position.x > surface.rect.maxX {
            return beginFalling(at: now)
        }
        return nil
    }

    /// Off the edge. Works from anywhere: a perch, a hop, or the user's hand.
    private func beginFalling(at now: TimeInterval) -> [DogEffect] {
        let target = landingY(under: position)
        forgetPerch()
        state = .falling
        deadline = nil
        fallTargetY = target
        return [.stopMoving, .play(.fall), .startFalling(toY: target)]
    }

    /// Touchdown. The absorb is a one-shot flourish over the idle pose, the
    /// same way `.celebrate` works, so it needs no state of its own.
    private func land(at now: TimeInterval) -> [DogEffect] {
        groundY = nil
        return [.stopFalling, .absorbLanding] + enterIdle(at: now)
    }

    /// Where a fall from `point` ends: the highest window top underneath him,
    /// or the height he climbed from, whichever he meets first. Never above
    /// where he already is.
    private func landingY(under point: CGPoint) -> CGFloat {
        let floor = groundY ?? tuning.wanderMargin
        let candidate = max(surfaceTop(under: point) ?? -.greatestFiniteMagnitude, floor)
        return min(candidate, point.y)
    }

    /// The highest window top strictly below `point` and horizontally under
    /// it, if any. Surface-only: no floor, no memory of a climb.
    private func surfaceTop(under point: CGPoint) -> CGFloat? {
        surfaces
            .filter { $0.rect.minX <= point.x && point.x <= $0.rect.maxX }
            .map { $0.topY + footOffset }
            .filter { $0 < point.y - Self.perchEpsilon }
            .max()
    }

    /// Start a leg of the title-bar patrol: trot to whichever end of the
    /// ledge he is further from, so he always crosses the window.
    private func startPatrolLeg(on surface: Surface) -> [DogEffect] {
        let inset = tuning.perchEdgeInset
        let ledgeY = surface.topY + footOffset
        let left = CGPoint(x: surface.rect.minX + inset, y: ledgeY)
        let right = CGPoint(x: surface.rect.maxX - inset, y: ledgeY)
        let target = clampToLedge(
            abs(position.x - left.x) > abs(position.x - right.x) ? left : right,
            on: surface
        )
        perchTarget = target
        deadline = nil
        return [.play(.walk), .moveTo(target, speed: tuning.walkSpeed)]
    }

    /// Keep a patrol point on the window's top edge, and inside it. A window
    /// narrower than two insets collapses to its middle.
    private func clampToLedge(_ point: CGPoint, on surface: Surface) -> CGPoint {
        let inset = tuning.perchEdgeInset
        let lower = surface.rect.minX + inset
        let upper = surface.rect.maxX - inset
        let x = lower > upper ? surface.rect.midX : min(max(point.x, lower), upper)
        return CGPoint(x: x, y: surface.topY + footOffset)
    }

    /// Which end of the window he'd walk to from here.
    private func nearEdgeX(of surface: Surface) -> CGFloat {
        abs(position.x - surface.rect.minX) <= abs(position.x - surface.rect.maxX)
            ? surface.rect.minX
            : surface.rect.maxX
    }

    /// The spot on the floor he walks to before hopping: directly below the
    /// near edge, at the height he's already at.
    private func approachPoint(for surface: Surface) -> CGPoint {
        let margin = tuning.wanderMargin
        // Solid ground: a window can sit beside a hole in the bounding box,
        // and the floor below its near edge is then nowhere at all.
        return onSolidGround(CGPoint(
            x: min(max(nearEdgeX(of: surface), margin), max(margin, bounds.width - margin)),
            y: position.y
        ))
    }

    /// Where the hop puts him down: on the top edge, one inset in from the
    /// corner he jumped at.
    private func perchLanding(on surface: Surface) -> CGPoint {
        let inset = tuning.perchEdgeInset
        let atLeftEdge = nearEdgeX(of: surface) == surface.rect.minX
        let x = atLeftEdge ? surface.rect.minX + inset : surface.rect.maxX - inset
        return clampToLedge(CGPoint(x: x, y: 0), on: surface)
    }

    /// The closest window worth climbing, or nil if none is. A perch has to
    /// be a real climb (its top above his feet), within jumping range, and
    /// close enough to be worth walking to.
    private func perchableSurface() -> Surface? {
        var best: Surface?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for surface in surfaces {
            let rise = (surface.topY + footOffset) - position.y
            guard rise > 0, rise <= tuning.perchReach else { continue }
            // A window can straddle a dead zone on an uneven multi-display
            // desk — half of its title bar over a display and half over
            // nothing. Climbing onto the half that is nowhere is climbing out
            // of sight. The ledge point itself is tested, not where his head
            // ends up, which is legitimately above the top of a display when
            // he stands on a window near the top of one.
            guard isRoamable(CGPoint(x: perchLanding(on: surface).x, y: surface.topY)) else { continue }
            let approach = approachPoint(for: surface)
            let distance = hypot(approach.x - position.x, approach.y - position.y)
            guard distance <= tuning.perchSearchRadius else { continue }
            // Ties go to the front-most window, which is first in the list.
            if distance < bestDistance {
                best = surface
                bestDistance = distance
            }
        }
        return best
    }

    private func surface(_ id: CGWindowID) -> Surface? {
        surfaces.first { $0.id == id }
    }

    /// Set off on the climb.
    private func startPerchApproach(to surface: Surface) -> [DogEffect] {
        groundY = position.y // a fall brings him back down to here
        perchAnchor = nil
        perchTarget = nil
        perchExpiry = nil
        state = .headingToSurface(surfaceID: surface.id)
        deadline = nil
        return [.play(.walk), .moveTo(approachPoint(for: surface), speed: tuning.walkSpeed)]
    }

    /// Drop every trace of a window adventure. Run by each interruption, so
    /// nothing can arrange a ghost fall out of a perch he already left.
    private func forgetPerch() {
        perchAnchor = nil
        perchTarget = nil
        perchExpiry = nil
    }

    // MARK: - Window parkour
    //
    // The signature leap: while already on a title bar, occasionally hop
    // straight onto a NEIGHBOURING window instead of coming back down, and
    // sometimes settle into a nap on a wide, stable ledge. The decisions live
    // here (pure, testable); the reachability geometry lives in `ParkourGraph`.

    /// The reach limits for a window-to-window hop, scaled to the dog's
    /// current size.
    private var parkourLimits: ParkourLimits {
        ParkourLimits(
            rise: tuning.parkourRise * dogScale,
            drop: tuning.parkourDrop * dogScale,
            gap: tuning.parkourGap * dogScale,
            landingInset: tuning.perchEdgeInset * dogScale
        )
    }

    /// A title bar has to be at least this wide for a nap.
    private var napMinWidth: CGFloat { tuning.perchNapMinWidth * dogScale }

    /// The end of a patrol leg: turn around — or, rarely, hop to a neighbour
    /// or settle down for a nap. Parkour and nap are both rolled here, so the
    /// ordinary patrolling rhythm is what they interrupt, not the other way
    /// round.
    private func decideNextMoveOn(_ surface: Surface, at now: TimeInterval) -> [DogEffect] {
        if Double.random(in: 0..<1, using: &rng) < tuning.parkourChance,
           let neighbour = parkourTarget(from: surface) {
            return startParkourHop(from: surface, to: neighbour)
        }
        if surface.rect.width >= napMinWidth,
           Double.random(in: 0..<1, using: &rng) < tuning.perchNapChance {
            return startPerchNap(on: surface, at: now)
        }
        return startPatrolLeg(on: surface)
    }

    /// A neighbouring window reachable by one hop, if any. Front-most-first
    /// order from the graph is preserved, and the pick is uniform over the
    /// reachable set through the injected RNG.
    private func parkourTarget(from surface: Surface) -> Surface? {
        let graph = ParkourGraph.build(
            surfaces: surfaces, limits: parkourLimits, roamableRects: roamableRects
        )
        let neighbours = graph.reachable(from: surface.id).compactMap { self.surface($0) }
        guard !neighbours.isEmpty else { return nil }
        return neighbours[Int.random(in: 0..<neighbours.count, using: &rng)]
    }

    /// Leap off this ledge onto a neighbour's. Shares the takeoff pose and the
    /// arc with the floor climb; the only difference is that the adventure's
    /// boredom clock keeps running.
    private func startParkourHop(from source: Surface, to target: Surface) -> [DogEffect] {
        state = .hoppingAcross(toID: target.id)
        deadline = nil
        perchAnchor = nil // re-established on landing
        return [.play(.pounce), .hopTo(parkourLanding(from: source, on: target))]
    }

    /// Where a parkour hop lands: directly across from where he took off,
    /// clamped inside the target's landing inset.
    private func parkourLanding(from source: Surface, on target: Surface) -> CGPoint {
        let inset = tuning.perchEdgeInset * dogScale
        let lower = target.rect.minX + inset
        let upper = target.rect.maxX - inset
        let x = lower > upper ? target.rect.midX : min(max(position.x, lower), upper)
        return CGPoint(x: x, y: target.topY + footOffset)
    }

    /// Settle down for a nap on a wide, stable title bar.
    private func startPerchNap(on surface: Surface, at now: TimeInterval) -> [DogEffect] {
        state = .perchSleeping(surfaceID: surface.id)
        deadline = now + random(in: tuning.perchNapDuration)
        perchTarget = nil
        return [.play(.sleep)]
    }

    // MARK: - Solid ground

    /// How many times a wander target is re-rolled before giving up and
    /// clamping. Eight is plenty: the dead zone would have to be most of the
    /// bounding box for the odds to matter, and the clamp is a fine answer
    /// even then.
    private static let wanderTargetAttempts = 8

    /// Somewhere inside the margins to wander off to.
    ///
    /// Rejection sampling rather than "pick a rectangle, then pick a point in
    /// it": picking a rectangle first would weight every display equally and
    /// send him to a small second monitor as often as to a large main one.
    /// Sampling the bounding box and rejecting the holes keeps his roaming
    /// uniform over actual screen area, and — because the very first roll is
    /// drawn exactly as it always was — leaves the hole-free case (which is
    /// every single-display Mac) bit-for-bit unchanged.
    private func wanderTarget() -> CGPoint {
        let margin = tuning.wanderMargin
        let xRange = margin...max(margin, bounds.width - margin)
        let yRange = margin...max(margin, bounds.height - margin)
        var target = CGPoint(
            x: CGFloat.random(in: xRange, using: &rng),
            y: CGFloat.random(in: yRange, using: &rng)
        )
        guard !roamableRects.isEmpty else { return target }
        var attempts = 1
        while !isRoamable(target), attempts < Self.wanderTargetAttempts {
            target = CGPoint(
                x: CGFloat.random(in: xRange, using: &rng),
                y: CGFloat.random(in: yRange, using: &rng)
            )
            attempts += 1
        }
        return onSolidGround(target)
    }

    /// Is this somewhere he could actually be seen standing?
    /// Always true when `roamableRects` is empty — see the property's comment.
    /// Edges count as inside, so the seam between two abutting displays is
    /// ground and not a crack to fall through.
    private func isRoamable(_ point: CGPoint) -> Bool {
        guard !roamableRects.isEmpty else { return true }
        return roamableRects.contains {
            point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY
        }
    }

    /// The nearest point that is solid ground; the point itself if it already
    /// is. Every target this file computes geometrically — a trot away from a
    /// pull, a nudge towards an edge, the spot below a window — goes through
    /// here, because any of them can otherwise aim into a hole.
    private func onSolidGround(_ point: CGPoint) -> CGPoint {
        guard !roamableRects.isEmpty, !isRoamable(point) else { return point }
        var best = point
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for rect in roamableRects {
            let candidate = CGPoint(
                x: min(max(point.x, rect.minX), rect.maxX),
                y: min(max(point.y, rect.minY), rect.maxY)
            )
            let distance = hypot(candidate.x - point.x, candidate.y - point.y)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
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
        let nudged: CGPoint
        if nearest == toLeft {
            nudged = CGPoint(x: position.x - step, y: position.y)
        } else if nearest == toRight {
            nudged = CGPoint(x: position.x + step, y: position.y)
        } else if nearest == toBottom {
            nudged = CGPoint(x: position.x, y: position.y - step)
        } else {
            nudged = CGPoint(x: position.x, y: position.y + step)
        }
        // On a multi-display desk the nearest edge of the BOUNDING BOX may be
        // across a hole; barking into one would walk him out of existence.
        return onSolidGround(nudged)
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

    /// One of the three recorded barks. Picked through the injected RNG so a
    /// seeded test gets the same bark every run.
    private func barkSound() -> DogEffect {
        let take = Int.random(in: 1...3, using: &rng)
        return .playSound("bark\(take)")
    }

    private func random(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        Double.random(in: range, using: &rng)
    }
}
