import Testing
import CoreGraphics
@testable import Jumbini

/// Deterministic brain: fixed seed, fixed idle duration, autonomy branches
/// (sleep/flourish) disabled unless a test opts in.
private func makeBrain(
    seed: UInt64 = 42,
    tune: (inout BrainTuning) -> Void = { _ in }
) -> DogBrain {
    var tuning = BrainTuning()
    tuning.idleDuration = 3...3
    tuning.sleepChance = 0
    tuning.flourishChance = 0
    tuning.zoomiesChance = 0
    tuning.sniffChance = 0
    tuning.hunchChance = 0
    tuning.barkAtNothingChance = 0
    tuning.pounceChance = 0
    tuning.tugWinChance = 0
    tune(&tuning)
    return DogBrain(
        bounds: CGSize(width: 800, height: 600),
        position: CGPoint(x: 400, y: 300),
        tuning: tuning,
        rng: SplitMix64(seed: seed)
    )
}

private func moveTarget(in effects: [DogEffect]) -> (point: CGPoint, speed: CGFloat)? {
    for case let .moveTo(point, speed) in effects { return (point, speed) }
    return nil
}

// MARK: - Idle / wander loop

@Test func idleTransitionsToWanderingAfterIdleDuration() {
    let brain = makeBrain()
    #expect(brain.handle(.tick, at: 0) == [], "no transition before the idle timer fires")
    #expect(brain.handle(.tick, at: 2.9) == [])

    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)
    #expect(effects.contains(.play(.walk)), "wandering plays the walk animation, got \(effects)")
    #expect(moveTarget(in: effects) != nil, "wandering emits a movement target")
    #expect(moveTarget(in: effects)?.speed == brain.tuning.walkSpeed)
}

@Test func wanderTargetStaysInsideMargins() {
    // Many seeds: every wander target respects the screen margin.
    for seed in UInt64(1)...20 {
        let brain = makeBrain(seed: seed) { $0.idleDuration = 1...1 }
        _ = brain.handle(.tick, at: 0)
        let effects = brain.handle(.tick, at: 1.1)
        let target = moveTarget(in: effects)?.point
        #expect(target != nil, "seed \(seed): no move target")
        if let target {
            #expect((60...740).contains(target.x), "seed \(seed): x=\(target.x)")
            #expect((60...540).contains(target.y), "seed \(seed): y=\(target.y)")
        }
    }
}

@Test func arrivedWhileWanderingReturnsToIdle() {
    let brain = makeBrain()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)

    let effects = brain.handle(.arrived, at: 5)
    #expect(brain.state == .idle)
    #expect(effects.contains(.play(.idle)))
}

@Test func idleCanFallAsleepWhenChanceRollsIt() {
    let brain = makeBrain { $0.sleepChance = 1.0; $0.sleepDuration = 10...10 }
    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .sleeping)
    #expect(effects.contains(.play(.sleep)))

    // Wakes up after sleepDuration.
    _ = brain.handle(.tick, at: 5)
    let wake = brain.handle(.tick, at: 13.2)
    #expect(brain.state == .idle)
    #expect(wake.contains(.play(.idle)))
}

// MARK: - Commands

@Test func sitCommandSitsAndStopsMoving() {
    let brain = makeBrain()
    let effects = brain.handle(.command(.sit), at: 1)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.sit)))
}

@Test func sitTimesOutBackToIdle() {
    let brain = makeBrain { $0.sitTimeout = 60 }
    _ = brain.handle(.command(.sit), at: 1)
    #expect(brain.handle(.tick, at: 60.9) == [], "still sitting before timeout")
    let effects = brain.handle(.tick, at: 61.1)
    #expect(brain.state == .idle)
    #expect(effects.contains(.play(.idle)))
}

@Test func lieDownCommandAndTimeout() {
    let brain = makeBrain { $0.lieTimeout = 90 }
    let effects = brain.handle(.command(.lieDown), at: 0)
    #expect(brain.state == .lyingDown)
    #expect(effects.contains(.play(.lie)))

    _ = brain.handle(.tick, at: 89)
    #expect(brain.state == .lyingDown)
    _ = brain.handle(.tick, at: 90.1)
    #expect(brain.state == .idle)
}

@Test func spinCommandSpinsOnceThenIdles() {
    let brain = makeBrain { $0.spinDuration = 0.9 }
    let effects = brain.handle(.command(.spin), at: 10)
    #expect(brain.state == .spinning)
    #expect(effects.contains(.play(.spin)))

    #expect(brain.handle(.tick, at: 10.5) == [])
    let done = brain.handle(.tick, at: 11.0)
    #expect(brain.state == .idle)
    #expect(done.contains(.play(.idle)))
}

@Test func newCommandReplacesCurrentCommand() {
    let brain = makeBrain()
    _ = brain.handle(.command(.sit), at: 0)
    let effects = brain.handle(.command(.lieDown), at: 1)
    #expect(brain.state == .lyingDown)
    #expect(effects.contains(.play(.lie)))
}

@Test func commandInterruptsWandering() {
    let brain = makeBrain()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)

    let effects = brain.handle(.command(.sit), at: 4)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.stopMoving), "movement must be cancelled")
}

// MARK: - Fetch

@Test func fetchCommandArmsThrowAndSits() {
    let brain = makeBrain()
    let effects = brain.handle(.command(.fetch), at: 0)
    #expect(brain.state == .awaitingThrow)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.sit)), "dog sits expectantly while waiting for the throw")
    #expect(effects.contains(.armThrow))
}

@Test func fetchThrowTimesOutAndDisarms() {
    let brain = makeBrain { $0.throwTimeout = 10 }
    _ = brain.handle(.command(.fetch), at: 0)
    #expect(brain.handle(.tick, at: 9.9) == [])
    let effects = brain.handle(.tick, at: 10.1)
    #expect(brain.state == .idle)
    #expect(effects.contains(.disarmThrow))
    #expect(effects.contains(.play(.idle)))
}

@Test func ballThrownStartsChase() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    let landing = CGPoint(x: 700, y: 100)
    let effects = brain.handle(.ballThrown(landing: landing, origin: CGPoint(x: 400, y: 300)), at: 1)
    #expect(brain.state == .chasingBall)
    #expect(effects.contains(.play(.run)))
    #expect(moveTarget(in: effects)?.point == landing)
    #expect(moveTarget(in: effects)?.speed == brain.tuning.runSpeed)
}

@Test func ballThrownWhenNotAwaitingIsIgnored() {
    let brain = makeBrain()
    let effects = brain.handle(.ballThrown(landing: .zero, origin: .zero), at: 1)
    #expect(effects == [])
    #expect(brain.state == .idle)
}

@Test func reachingBallPicksItUpAndReturns() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    let origin = CGPoint(x: 400, y: 300)
    _ = brain.handle(.ballThrown(landing: CGPoint(x: 700, y: 100), origin: origin), at: 1)

    let effects = brain.handle(.arrived, at: 3)
    #expect(brain.state == .returningBall)
    #expect(effects.contains(.pickUpBall))
    #expect(effects.contains(.play(.carryWalk)))
    #expect(moveTarget(in: effects)?.point == origin)
    #expect(moveTarget(in: effects)?.speed == brain.tuning.carrySpeed)
}

@Test func returningBallDropsItAndCelebrates() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    _ = brain.handle(.ballThrown(landing: CGPoint(x: 700, y: 100), origin: CGPoint(x: 400, y: 300)), at: 1)
    _ = brain.handle(.arrived, at: 3)

    let effects = brain.handle(.arrived, at: 5)
    #expect(brain.state == .idle)
    #expect(effects.contains(.dropBall))
    #expect(effects.contains(.celebrate))
}

@Test func commandDuringChaseCancelsFetch() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    _ = brain.handle(.ballThrown(landing: CGPoint(x: 700, y: 100), origin: CGPoint(x: 400, y: 300)), at: 1)

    let effects = brain.handle(.command(.sit), at: 2)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.removeBall), "cancelled fetch cleans up the ball")
}

@Test func commandDuringAwaitingThrowDisarms() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    let effects = brain.handle(.command(.sit), at: 2)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.disarmThrow))
}

// MARK: - Petting

@Test func pettingShowsHeartsThenReturnsToIdle() {
    let brain = makeBrain { $0.petDuration = 1.2 }
    let effects = brain.handle(.petted, at: 0)
    #expect(brain.state == .beingPetted)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.happy)))
    #expect(effects.contains(.showHearts))

    #expect(brain.handle(.tick, at: 1.0) == [])
    let done = brain.handle(.tick, at: 1.3)
    #expect(brain.state == .idle)
    #expect(done.contains(.play(.idle)))
}

@Test func pettingWhileSittingReturnsToSitting() {
    let brain = makeBrain { $0.petDuration = 1.2 }
    _ = brain.handle(.command(.sit), at: 0)
    _ = brain.handle(.petted, at: 1)
    #expect(brain.state == .beingPetted)

    let done = brain.handle(.tick, at: 2.3)
    #expect(brain.state == .sitting)
    #expect(done.contains(.play(.sit)))
}

@Test func repeatPettingExtendsAndShowsMoreHearts() {
    let brain = makeBrain { $0.petDuration = 1.2 }
    _ = brain.handle(.petted, at: 0)
    let effects = brain.handle(.petted, at: 1.0)
    #expect(effects.contains(.showHearts))
    // Deadline extended: still being petted at 1.3.
    #expect(brain.handle(.tick, at: 1.3) == [])
    #expect(brain.state == .beingPetted)
    _ = brain.handle(.tick, at: 2.3)
    #expect(brain.state == .idle)
}

// MARK: - Carrying

@Test func pickedUpDangles() {
    let brain = makeBrain()
    let effects = brain.handle(.pickedUp, at: 0)
    #expect(brain.state == .carried)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.dangle)))
}

@Test func droppedLandsAtPointAndIdles() {
    let brain = makeBrain()
    _ = brain.handle(.pickedUp, at: 0)
    let spot = CGPoint(x: 123, y: 456)
    let effects = brain.handle(.dropped(at: spot), at: 2)
    #expect(brain.state == .idle)
    #expect(brain.position == spot)
    #expect(effects.contains(.play(.idle)))
}

@Test func pettingWhileCarriedIsIgnored() {
    let brain = makeBrain()
    _ = brain.handle(.pickedUp, at: 0)
    let effects = brain.handle(.petted, at: 1)
    #expect(effects == [])
    #expect(brain.state == .carried)
}

@Test func pickedUpDuringFetchRemovesBall() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    _ = brain.handle(.ballThrown(landing: CGPoint(x: 700, y: 100), origin: CGPoint(x: 400, y: 300)), at: 1)
    let effects = brain.handle(.pickedUp, at: 2)
    #expect(brain.state == .carried)
    #expect(effects.contains(.removeBall))
}

// MARK: - Bed routing

@Test func lieDownWithBedWalksToBedThenLies() {
    let brain = makeBrain()
    let bed = CGPoint(x: 120, y: 80)
    brain.bedPosition = bed

    let effects = brain.handle(.command(.lieDown), at: 0)
    #expect(brain.state == .goingToBed(.lie))
    #expect(effects.contains(.play(.walk)))
    #expect(moveTarget(in: effects)?.point == bed)
    #expect(moveTarget(in: effects)?.speed == brain.tuning.walkSpeed)

    let arrived = brain.handle(.arrived, at: 3)
    #expect(brain.state == .lyingDown)
    #expect(arrived.contains(.play(.lie)))

    _ = brain.handle(.tick, at: 3 + brain.tuning.lieTimeout + 0.1)
    #expect(brain.state == .idle)
}

@Test func autonomousSleepRoutesThroughBed() {
    let brain = makeBrain { $0.sleepChance = 1.0; $0.sleepDuration = 10...10 }
    let bed = CGPoint(x: 700, y: 500)
    brain.bedPosition = bed
    _ = brain.handle(.tick, at: 0)

    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .goingToBed(.sleep))
    #expect(effects.contains(.play(.walk)))
    #expect(moveTarget(in: effects)?.point == bed)

    let arrived = brain.handle(.arrived, at: 5)
    #expect(brain.state == .sleeping)
    #expect(arrived.contains(.play(.sleep)))

    _ = brain.handle(.tick, at: 15.2)
    #expect(brain.state == .idle)
}

@Test func bedMovedRetargetsWhileHeadingThere() {
    let brain = makeBrain()
    brain.bedPosition = CGPoint(x: 120, y: 80)
    _ = brain.handle(.command(.lieDown), at: 0)
    #expect(brain.state == .goingToBed(.lie))

    let newSpot = CGPoint(x: 600, y: 400)
    let effects = brain.handle(.bedMoved(to: newSpot), at: 1)
    #expect(brain.bedPosition == newSpot)
    #expect(effects.contains(.stopMoving), "retarget must cancel the in-flight move first")
    #expect(moveTarget(in: effects)?.point == newSpot)
    #expect(brain.state == .goingToBed(.lie))
}

@Test func bedMovedWhileIdleJustUpdatesPosition() {
    let brain = makeBrain()
    brain.bedPosition = CGPoint(x: 120, y: 80)
    let newSpot = CGPoint(x: 300, y: 300)
    let effects = brain.handle(.bedMoved(to: newSpot), at: 1)
    #expect(brain.bedPosition == newSpot)
    #expect(effects == [])
    #expect(brain.state == .idle)
}

@Test func commandInterruptsGoingToBed() {
    let brain = makeBrain()
    brain.bedPosition = CGPoint(x: 120, y: 80)
    _ = brain.handle(.command(.lieDown), at: 0)
    let effects = brain.handle(.command(.sit), at: 1)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.stopMoving))
}

// MARK: - Treats

@Test func treatDroppedStartsChase() {
    let brain = makeBrain()
    let spot = CGPoint(x: 640, y: 200)
    let effects = brain.handle(.treatDropped(at: spot), at: 1)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.play(.run)))
    #expect(moveTarget(in: effects)?.point == spot)
    #expect(moveTarget(in: effects)?.speed == brain.tuning.runSpeed)
}

@Test func reachingTreatEatsIt() {
    let brain = makeBrain { $0.eatDuration = 1.1 }
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 1)

    let effects = brain.handle(.arrived, at: 2)
    #expect(brain.state == .eating)
    #expect(effects.contains(.eatTreat))
    #expect(effects.contains(.play(.happy)))
    #expect(effects.contains(.showHearts))

    #expect(brain.handle(.tick, at: 3.0) == [])
    let done = brain.handle(.tick, at: 3.2)
    #expect(brain.state == .hunching, "a treat goes straight through him")
    #expect(done.contains(.play(.hunch)))
}

@Test func treatDigestionEndsInAPoopThenIdle() {
    let brain = makeBrain { $0.eatDuration = 1 }
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 0)
    _ = brain.handle(.arrived, at: 1)
    let poop = brain.handle(.tick, at: 2)
    #expect(brain.state == .hunching)
    #expect(poop.contains(.play(.hunch)))
    let done = brain.handle(.tick, at: 2 + brain.tuning.hunchDuration)
    #expect(brain.state == .idle)
    #expect(done.contains(.play(.idle)))
    #expect(done.contains(.leaveDeposit), "digestion ends in an actual deposit")
}

@Test func treatWakesSleepingDog() {
    let brain = makeBrain { $0.sleepChance = 1.0; $0.sleepDuration = 10...10 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .sleeping)

    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: 4)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.play(.run)))
}

@Test func treatBeatsFetchAndRemovesBall() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    _ = brain.handle(.ballThrown(landing: CGPoint(x: 700, y: 100), origin: CGPoint(x: 400, y: 300)), at: 1)

    let effects = brain.handle(.treatDropped(at: CGPoint(x: 200, y: 200)), at: 2)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.removeBall))
}

@Test func treatBeatsGoingToBed() {
    let brain = makeBrain()
    brain.bedPosition = CGPoint(x: 120, y: 80)
    _ = brain.handle(.command(.lieDown), at: 0)
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 500, y: 500)), at: 1)
    #expect(brain.state == .chasingTreat)
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 500, y: 500))
}

@Test func newTreatRetargetsChase() {
    let brain = makeBrain()
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 1)
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 400)), at: 2)
    #expect(brain.state == .chasingTreat)
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 100, y: 400))
}

@Test func treatIgnoredWhileCarried() {
    let brain = makeBrain()
    _ = brain.handle(.pickedUp, at: 0)
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: 1)
    #expect(effects == [])
    #expect(brain.state == .carried)
}

@Test func treatIgnoredWhileAlreadyEating() {
    let brain = makeBrain()
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 1)
    _ = brain.handle(.arrived, at: 2)
    #expect(brain.state == .eating)

    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: 2.5)
    #expect(effects == [])
    #expect(brain.state == .eating)
}

@Test func commandInterruptsTreatChase() {
    let brain = makeBrain()
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 1)
    let effects = brain.handle(.command(.sit), at: 2)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.removeTreat), "abandoned chase cleans up the treat")
}

@Test func pickedUpDuringTreatChaseRemovesTreat() {
    let brain = makeBrain()
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 1)
    let effects = brain.handle(.pickedUp, at: 2)
    #expect(brain.state == .carried)
    #expect(effects.contains(.removeTreat))
}

@Test func newTreatRetargetsChaseKeepsTreat() {
    let brain = makeBrain()
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 1)
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 400)), at: 2)
    #expect(brain.state == .chasingTreat)
    #expect(!effects.contains(.removeTreat), "re-drop must not delete the new treat node")
}

// MARK: - Forever spin / relax / zoomies / sniffing

@Test func spinForeverNeverTimesOut() {
    let brain = makeBrain()
    let effects = brain.handle(.command(.spinForever), at: 0)
    #expect(brain.state == .spinning)
    #expect(effects.contains(.play(.spin)))

    #expect(brain.handle(.tick, at: 10_000) == [], "forever spin has no deadline")
    #expect(brain.state == .spinning)
}

@Test func relaxEndsForeverSpin() {
    let brain = makeBrain()
    _ = brain.handle(.command(.spinForever), at: 0)
    let effects = brain.handle(.command(.relax), at: 5)
    #expect(brain.state == .idle)
    #expect(effects.contains(.play(.idle)))
}

@Test func zoomiesCommandStarts() {
    let brain = makeBrain()
    let effects = brain.handle(.command(.zoomies), at: 0)
    #expect(brain.state == .zoomies)
    #expect(effects.contains(.startZoomies))
    #expect(effects.contains(.play(.run)))
}

@Test func zoomiesEndsAfterDuration() {
    let brain = makeBrain { $0.zoomiesDuration = 10 }
    _ = brain.handle(.command(.zoomies), at: 0)
    #expect(brain.handle(.tick, at: 9.9) == [])
    let effects = brain.handle(.tick, at: 10)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopZoomies))
    #expect(effects.contains(.play(.idle)))
}

@Test func zoomiesInterruptedByPickup() {
    let brain = makeBrain()
    _ = brain.handle(.command(.zoomies), at: 0)
    let effects = brain.handle(.pickedUp, at: 1)
    #expect(brain.state == .carried)
    #expect(effects.contains(.stopZoomies))
}

@Test func treatBeatsZoomies() {
    let brain = makeBrain()
    _ = brain.handle(.command(.zoomies), at: 0)
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 200, y: 200)), at: 1)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.stopZoomies))
}

@Test func autonomousZoomies() {
    let brain = makeBrain { $0.zoomiesChance = 1.0 }
    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .zoomies)
    #expect(effects.contains(.startZoomies))
    #expect(effects.contains(.play(.run)))
}

@Test func autonomousSniffStartsAndTimesOut() {
    let brain = makeBrain { $0.sniffChance = 1.0; $0.sniffDuration = 100...140 }
    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .sniffingMouse)
    #expect(effects.contains(.startSniffing))
    #expect(effects.contains(.play(.walk)))

    // Still sniffing before the lower bound could have elapsed.
    #expect(brain.handle(.tick, at: 3.1 + 99) == [])
    #expect(brain.state == .sniffingMouse)

    // Past the upper bound the sniff has certainly ended.
    let done = brain.handle(.tick, at: 3.1 + 140.1)
    #expect(brain.state == .idle)
    #expect(done.contains(.stopSniffing))
    #expect(done.contains(.play(.idle)))
}

@Test func sniffInterruptedByCommand() {
    let brain = makeBrain { $0.sniffChance = 1.0 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .sniffingMouse)

    let effects = brain.handle(.command(.sit), at: 5)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.stopSniffing))
}

// MARK: - Review-driven hardening

@Test func commandIgnoredWhileCarried() {
    let brain = makeBrain()
    _ = brain.handle(.pickedUp, at: 0)
    let effects = brain.handle(.command(.fetch), at: 1)
    #expect(effects == [])
    #expect(brain.state == .carried)
}

@Test func droppedIgnoredWhenNotCarried() {
    let brain = makeBrain()
    _ = brain.handle(.command(.sit), at: 0)
    let before = brain.position
    let effects = brain.handle(.dropped(at: CGPoint(x: 50, y: 50)), at: 1)
    #expect(effects == [])
    #expect(brain.state == .sitting)
    #expect(brain.position == before)
}

@Test func treatBeatsAwaitingThrowAndDisarms() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    #expect(brain.state == .awaitingThrow)
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 300, y: 300)), at: 1)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.disarmThrow), "abandoning the armed throw must release the click capture")
    #expect(effects.contains(.stopMoving))
}

@Test func throwCancelledDisarmsAndIdles() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    let effects = brain.handle(.throwCancelled, at: 1)
    #expect(brain.state == .idle)
    #expect(effects.contains(.disarmThrow))
    #expect(effects.contains(.play(.idle)))
}

@Test func throwCancelledIgnoredWhenNotArmed() {
    let brain = makeBrain()
    _ = brain.handle(.command(.sit), at: 0)
    let effects = brain.handle(.throwCancelled, at: 1)
    #expect(effects == [])
    #expect(brain.state == .sitting)
}

// MARK: - Cursor hunting (sniff → stalk → pounce → catch)

/// Drive a fresh brain into .stalkingMouse. Sniff runs 3s…103s; the deadline
/// tick at 103.1 rolls pounceChance = 1 and escalates. Returns the brain and
/// the stalk start time.
private func makeStalkingBrain(seed: UInt64 = 42) -> (brain: DogBrain, stalkStart: Double) {
    let brain = makeBrain(seed: seed) {
        $0.sniffChance = 1.0
        $0.pounceChance = 1.0
        $0.sniffDuration = 100...100
    }
    _ = brain.handle(.tick, at: 0)     // arm the idle timer (3s)
    _ = brain.handle(.tick, at: 3)     // idle → sniffingMouse (deadline 103)
    _ = brain.handle(.tick, at: 103.1) // sniffingMouse → stalkingMouse
    return (brain, 103.1)
}

/// Drive a fresh brain all the way into .pouncing. Returns the brain and the
/// pounce start time.
private func makePouncingBrain(seed: UInt64 = 42) -> (brain: DogBrain, pounceStart: Double) {
    let (brain, stalkStart) = makeStalkingBrain(seed: seed)
    let pounceStart = stalkStart + brain.tuning.stalkDuration + 0.1
    _ = brain.handle(.tick, at: pounceStart) // stalkingMouse → pouncing
    return (brain, pounceStart)
}

@Test func sniffEscalatesToStalkWhenPounceChanceRollsIt() {
    let brain = makeBrain { $0.sniffChance = 1.0; $0.pounceChance = 1.0; $0.sniffDuration = 100...100 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3)
    #expect(brain.state == .sniffingMouse)

    let effects = brain.handle(.tick, at: 103.1)
    #expect(brain.state == .stalkingMouse)
    #expect(effects.contains(.play(.stalk)))
    #expect(!effects.contains(.stopSniffing), "cursor tracking must stay live through the stalk")
    #expect(!effects.contains(.play(.idle)))
}

@Test func sniffEndsQuietlyWhenPounceChanceMisses() {
    let brain = makeBrain { $0.sniffChance = 1.0; $0.pounceChance = 0.0; $0.sniffDuration = 100...100 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3)
    #expect(brain.state == .sniffingMouse)

    let effects = brain.handle(.tick, at: 103.1)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopSniffing))
    #expect(effects.contains(.play(.idle)))
    #expect(!effects.contains(.play(.stalk)))
}

@Test func stalkHoldsForStalkDurationThenPounces() {
    let (brain, stalkStart) = makeStalkingBrain()
    let stalkEnd = stalkStart + brain.tuning.stalkDuration

    #expect(brain.handle(.tick, at: stalkEnd - 0.1) == [], "still stalking before stalkDuration")
    #expect(brain.state == .stalkingMouse)

    let effects = brain.handle(.tick, at: stalkEnd + 0.1)
    #expect(brain.state == .pouncing)
    #expect(effects.contains(.play(.pounce)))
    #expect(!effects.contains(.stopSniffing), "cursor tracking must stay live through the pounce")
}

@Test func pounceEndsWithCatchThenProudIdle() {
    let (brain, pounceStart) = makePouncingBrain()
    let pounceEnd = pounceStart + brain.tuning.pounceDuration

    #expect(brain.handle(.tick, at: pounceEnd - 0.1) == [], "still mid-leap before pounceDuration")
    #expect(brain.state == .pouncing)

    let effects = brain.handle(.tick, at: pounceEnd + 0.1)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopSniffing))
    #expect(effects.contains(.nudgeCursor), "the catch jitters the real cursor")
    #expect(effects.contains(.celebrate))
    #expect(effects.contains(.play(.idle)))
}

// Interruptions during the hunt mirror the sniffing ones: anything that
// breaks in must emit .stopSniffing so the scene stops tracking the cursor.

@Test func stalkInterruptedByCommand() {
    let (brain, stalkStart) = makeStalkingBrain()
    let effects = brain.handle(.command(.sit), at: stalkStart + 1)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.stopSniffing))
    #expect(effects.contains(.play(.sit)))
}

@Test func treatBeatsStalking() {
    let (brain, stalkStart) = makeStalkingBrain()
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: stalkStart + 1)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.stopSniffing))
    #expect(effects.contains(.play(.run)))
}

@Test func pettingInterruptsStalking() {
    let (brain, stalkStart) = makeStalkingBrain()
    let effects = brain.handle(.petted, at: stalkStart + 1)
    #expect(brain.state == .beingPetted)
    #expect(effects.contains(.stopSniffing))
    #expect(effects.contains(.showHearts))
}

@Test func pickupInterruptsStalking() {
    let (brain, stalkStart) = makeStalkingBrain()
    let effects = brain.handle(.pickedUp, at: stalkStart + 1)
    #expect(brain.state == .carried)
    #expect(effects.contains(.stopSniffing))
    #expect(effects.contains(.play(.dangle)))
}

@Test func pounceInterruptedByCommand() {
    let (brain, pounceStart) = makePouncingBrain()
    let effects = brain.handle(.command(.sit), at: pounceStart + 0.2)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.stopSniffing))
}

@Test func treatBeatsPouncing() {
    let (brain, pounceStart) = makePouncingBrain()
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: pounceStart + 0.2)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.stopSniffing))
}

@Test func pettingInterruptsPouncing() {
    let (brain, pounceStart) = makePouncingBrain()
    let effects = brain.handle(.petted, at: pounceStart + 0.2)
    #expect(brain.state == .beingPetted)
    #expect(effects.contains(.stopSniffing))
}

@Test func pickupInterruptsPouncing() {
    let (brain, pounceStart) = makePouncingBrain()
    let effects = brain.handle(.pickedUp, at: pounceStart + 0.2)
    #expect(brain.state == .carried)
    #expect(effects.contains(.stopSniffing))
}

// MARK: - Tricks

private func expectedTrickAnimation(_ trick: Trick) -> DogAnimation {
    switch trick {
    case .shake: return .shakePaw
    case .highFive: return .highFive
    case .playDead: return .playDead
    case .rollOver: return .rollOver
    }
}

@Test(arguments: Trick.allCases)
func trickCommandPerformsItsAnimation(trick: Trick) {
    let brain = makeBrain()
    let effects = brain.handle(.command(.trick(trick)), at: 1)
    #expect(brain.state == .performingTrick(trick))
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(expectedTrickAnimation(trick))))
}

@Test func trickTimesOutBackToIdleAfterTrickDuration() {
    let brain = makeBrain { $0.trickDuration = 1.5 }
    _ = brain.handle(.command(.trick(.shake)), at: 10)
    #expect(brain.handle(.tick, at: 11.4) == [], "still performing before trickDuration")
    #expect(brain.state == .performingTrick(.shake))

    let done = brain.handle(.tick, at: 11.6)
    #expect(brain.state == .idle)
    #expect(done.contains(.play(.idle)))
}

@Test func trickCommandIgnoredWhileCarried() {
    let brain = makeBrain()
    _ = brain.handle(.pickedUp, at: 0)
    let effects = brain.handle(.command(.trick(.highFive)), at: 1)
    #expect(effects == [])
    #expect(brain.state == .carried)
}

@Test func trickInterruptsWandering() {
    let brain = makeBrain()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)

    let effects = brain.handle(.command(.trick(.rollOver)), at: 4)
    #expect(brain.state == .performingTrick(.rollOver))
    #expect(effects.contains(.stopMoving), "movement must be cancelled")
}

@Test func treatBeatsTrick() {
    let brain = makeBrain()
    _ = brain.handle(.command(.trick(.playDead)), at: 0)
    let spot = CGPoint(x: 200, y: 200)
    let effects = brain.handle(.treatDropped(at: spot), at: 0.5)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.play(.run)))
    #expect(moveTarget(in: effects)?.point == spot)
}

@Test func pettingInterruptsTrick() {
    let brain = makeBrain { $0.petDuration = 1.2 }
    _ = brain.handle(.command(.trick(.shake)), at: 0)
    let effects = brain.handle(.petted, at: 0.5)
    #expect(brain.state == .beingPetted)
    #expect(effects.contains(.showHearts))

    // And the session ends in idle, not back in the trick.
    _ = brain.handle(.tick, at: 2)
    #expect(brain.state == .idle)
}

@Test func pickupInterruptsTrick() {
    let brain = makeBrain()
    _ = brain.handle(.command(.trick(.rollOver)), at: 0)
    let effects = brain.handle(.pickedUp, at: 0.5)
    #expect(brain.state == .carried)
    #expect(effects.contains(.play(.dangle)))
}

@Test func newCommandReplacesTrick() {
    let brain = makeBrain()
    _ = brain.handle(.command(.trick(.highFive)), at: 0)
    let effects = brain.handle(.command(.sit), at: 0.5)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.play(.sit)))
}

// MARK: - Hunching (the poopchini special)

@Test func autonomousHunchStartsAndEnds() {
    let brain = makeBrain { $0.hunchChance = 1 }
    _ = brain.handle(.tick, at: 0) // arm idle timer (3s)
    let start = brain.handle(.tick, at: 3)
    #expect(brain.state == .hunching)
    #expect(start.contains(.play(.hunch)))
    let end = brain.handle(.tick, at: 3 + brain.tuning.hunchDuration)
    #expect(brain.state == .idle)
    #expect(end.contains(.play(.idle)))
    #expect(end.contains(.leaveDeposit), "a finished hunch leaves a pile behind")
}

@Test func commandInterruptsHunch() {
    let brain = makeBrain { $0.hunchChance = 1 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3)
    #expect(brain.state == .hunching)
    let effects = brain.handle(.command(.sit), at: 4)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.play(.sit)))
}

@Test func treatBeatsHunch() {
    let brain = makeBrain { $0.hunchChance = 1 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3)
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: 4)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.play(.run)))
}

// MARK: - Deposits (the payoff for the bottomless hunger)

@Test func depositEmittedExactlyAtAutonomousHunchEnd() {
    let brain = makeBrain { $0.hunchChance = 1 }
    _ = brain.handle(.tick, at: 0) // arm idle timer (3s)
    let start = brain.handle(.tick, at: 3)
    #expect(brain.state == .hunching)
    #expect(!start.contains(.leaveDeposit), "no deposit at hunch start")
    #expect(brain.handle(.tick, at: 4) == [], "no deposit mid-hunch")
    let end = brain.handle(.tick, at: 3 + brain.tuning.hunchDuration)
    #expect(brain.state == .idle)
    #expect(end.filter { $0 == .leaveDeposit }.count == 1, "exactly one deposit, exactly at hunch end")
}

@Test func depositEmittedExactlyAtDigestionHunchEnd() {
    let brain = makeBrain { $0.eatDuration = 1 }
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 0)
    _ = brain.handle(.arrived, at: 1)
    let hunchStart = brain.handle(.tick, at: 2)
    #expect(brain.state == .hunching)
    #expect(!hunchStart.contains(.leaveDeposit), "eating→hunching transition itself deposits nothing")
    let end = brain.handle(.tick, at: 2 + brain.tuning.hunchDuration)
    #expect(brain.state == .idle)
    #expect(end.filter { $0 == .leaveDeposit }.count == 1, "exactly one deposit when digestion completes")
}

@Test func commandInterruptedHunchDoesNotDeposit() {
    let brain = makeBrain { $0.hunchChance = 1 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3)
    #expect(brain.state == .hunching)
    let effects = brain.handle(.command(.sit), at: 4)
    #expect(brain.state == .sitting)
    #expect(!effects.contains(.leaveDeposit), "an interrupted hunch leaves nothing behind")
    // The stale hunch deadline must not sneak a deposit in later either.
    let later = brain.handle(.tick, at: 4 + brain.tuning.sitTimeout + 0.1)
    #expect(brain.state == .idle)
    #expect(!later.contains(.leaveDeposit))
}

@Test func pettingInterruptedHunchDoesNotDeposit() {
    let brain = makeBrain { $0.hunchChance = 1; $0.petDuration = 1.2 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3)
    #expect(brain.state == .hunching)
    let effects = brain.handle(.petted, at: 4)
    #expect(brain.state == .beingPetted)
    #expect(!effects.contains(.leaveDeposit))
    let done = brain.handle(.tick, at: 5.3)
    #expect(brain.state == .idle)
    #expect(!done.contains(.leaveDeposit), "ending the petting session is not a hunch end")
}

@Test func pickupInterruptedHunchDoesNotDeposit() {
    let brain = makeBrain { $0.hunchChance = 1 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3)
    #expect(brain.state == .hunching)
    let up = brain.handle(.pickedUp, at: 4)
    #expect(brain.state == .carried)
    #expect(!up.contains(.leaveDeposit))
    let down = brain.handle(.dropped(at: CGPoint(x: 100, y: 100)), at: 5)
    #expect(brain.state == .idle)
    #expect(!down.contains(.leaveDeposit), "being put down is not a hunch end")
}

// MARK: - Barking (provoked by a lingering cursor)

@Test func provokedWhileIdleBarksWithSound() {
    let brain = makeBrain { $0.barkDuration = 1.2 }
    let effects = brain.handle(.provoked(at: CGPoint(x: 410, y: 310)), at: 0)
    #expect(brain.state == .barking)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.bark)))
    #expect(effects.contains(.playSound("borf")))

    #expect(brain.handle(.tick, at: 1.0) == [], "still barking before barkDuration elapses")
    let done = brain.handle(.tick, at: 1.3)
    #expect(brain.state == .idle)
    #expect(done.contains(.play(.idle)))
}

@Test func provokedWhileSittingBarksThenResumesSitting() {
    let brain = makeBrain { $0.barkDuration = 1.2 }
    _ = brain.handle(.command(.sit), at: 0)
    _ = brain.handle(.provoked(at: .zero), at: 1)
    #expect(brain.state == .barking)

    let done = brain.handle(.tick, at: 2.3)
    #expect(brain.state == .sitting)
    #expect(done.contains(.play(.sit)))
}

@Test func provokedWhileLyingDownBarksThenResumesLying() {
    let brain = makeBrain { $0.barkDuration = 1.2 }
    _ = brain.handle(.command(.lieDown), at: 0)
    _ = brain.handle(.provoked(at: .zero), at: 1)
    #expect(brain.state == .barking)

    let done = brain.handle(.tick, at: 2.3)
    #expect(brain.state == .lyingDown)
    #expect(done.contains(.play(.lie)))
}

@Test func provokedWhileWanderingBarksThenIdles() {
    let brain = makeBrain()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)

    let effects = brain.handle(.provoked(at: .zero), at: 4)
    #expect(brain.state == .barking)
    #expect(effects.contains(.stopMoving), "the in-flight wander walk must be cancelled")

    _ = brain.handle(.tick, at: 4 + brain.tuning.barkDuration + 0.1)
    #expect(brain.state == .idle)
}

@Test func provokedIgnoredWhileCarried() {
    let brain = makeBrain()
    _ = brain.handle(.pickedUp, at: 0)
    let effects = brain.handle(.provoked(at: .zero), at: 1)
    #expect(effects == [])
    #expect(brain.state == .carried)
}

@Test func provokedIgnoredWhileEating() {
    let brain = makeBrain()
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 0)
    _ = brain.handle(.arrived, at: 1)
    #expect(brain.state == .eating)
    let effects = brain.handle(.provoked(at: .zero), at: 1.5)
    #expect(effects == [])
    #expect(brain.state == .eating)
}

@Test func provokedIgnoredWhileChasingBall() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    _ = brain.handle(.ballThrown(landing: CGPoint(x: 700, y: 100), origin: CGPoint(x: 400, y: 300)), at: 1)
    #expect(brain.state == .chasingBall)
    let effects = brain.handle(.provoked(at: .zero), at: 2)
    #expect(effects == [])
    #expect(brain.state == .chasingBall)
}

@Test func provokedIgnoredWhileBeingPetted() {
    let brain = makeBrain()
    _ = brain.handle(.petted, at: 0)
    let effects = brain.handle(.provoked(at: .zero), at: 0.5)
    #expect(effects == [])
    #expect(brain.state == .beingPetted)
}

@Test func provokedIgnoredWhileSleeping() {
    let brain = makeBrain { $0.sleepChance = 1.0; $0.sleepDuration = 10...10 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .sleeping)
    let effects = brain.handle(.provoked(at: .zero), at: 4)
    #expect(effects == [])
    #expect(brain.state == .sleeping)
}

@Test func provokedWhileBarkingIsIgnored() {
    let brain = makeBrain()
    _ = brain.handle(.provoked(at: .zero), at: 0)
    #expect(brain.state == .barking)
    let effects = brain.handle(.provoked(at: .zero), at: 0.5)
    #expect(effects == [])
    #expect(brain.state == .barking)
}

@Test func provokedDuringCooldownIsIgnoredThenWorksAgain() {
    let brain = makeBrain { $0.barkDuration = 1.2; $0.barkCooldown = 8 }
    _ = brain.handle(.provoked(at: .zero), at: 0)
    _ = brain.handle(.tick, at: 1.3)
    #expect(brain.state == .idle)

    // Hover-spam inside the cooldown window: no machine-gun barking.
    let spam = brain.handle(.provoked(at: .zero), at: 2)
    #expect(spam == [])
    #expect(brain.state == .idle)

    // Cooldown measured from the bark start: 8s later he'll bark again.
    let again = brain.handle(.provoked(at: .zero), at: 8.1)
    #expect(brain.state == .barking)
    #expect(again.contains(.play(.bark)))
    #expect(again.contains(.playSound("borf")))
}

@Test func commandInterruptsBark() {
    let brain = makeBrain()
    _ = brain.handle(.provoked(at: .zero), at: 0)
    #expect(brain.state == .barking)
    let effects = brain.handle(.command(.sit), at: 0.5)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.play(.sit)))
}

@Test func treatBeatsBark() {
    let brain = makeBrain()
    _ = brain.handle(.provoked(at: .zero), at: 0)
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: 0.5)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.play(.run)))
}

// MARK: - Barking at nothing (the Dock is suspicious)

@Test func autonomousBarkAtNothingFacesNearestEdge() {
    let brain = makeBrain { $0.barkAtNothingChance = 1.0 }
    brain.position = CGPoint(x: 100, y: 300) // left edge is nearest
    _ = brain.handle(.tick, at: 0)

    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .barking)
    #expect(effects.contains(.play(.bark)))
    #expect(effects.contains(.playSound("borf")))
    let target = moveTarget(in: effects)
    #expect(target != nil, "he takes a small step toward the edge so he faces it")
    if let target {
        #expect(target.point.x < 100, "nearest edge is the left one")
        #expect(target.point.y == 300)
        #expect(target.speed == brain.tuning.walkSpeed)
    }

    let done = brain.handle(.tick, at: 3.1 + brain.tuning.barkDuration + 0.1)
    #expect(brain.state == .idle)
    #expect(done.contains(.play(.idle)))
}

@Test func autonomousBarkPicksBottomEdgeWhenNearest() {
    let brain = makeBrain { $0.barkAtNothingChance = 1.0 }
    brain.position = CGPoint(x: 400, y: 90) // bottom edge is nearest
    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .barking)
    let target = moveTarget(in: effects)
    #expect(target?.point.x == 400)
    if let target { #expect(target.point.y < 90) }
}

@Test func autonomousBarkStartsTheProvokeCooldown() {
    let brain = makeBrain { $0.barkAtNothingChance = 1.0; $0.barkCooldown = 8 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .barking)
    _ = brain.handle(.tick, at: 3.1 + brain.tuning.barkDuration + 0.1)
    #expect(brain.state == .idle)

    // Hovering right after the autonomous bark: still inside the cooldown.
    let effects = brain.handle(.provoked(at: .zero), at: 5)
    #expect(effects == [])
    #expect(brain.state == .idle)
}

// MARK: - System reactions (he reacts to your machine)

/// Every system signal, for the "ignored wholesale" tests.
private let allSystemSignals: [SystemSignal] = [
    .buildFinished, .idleBegan, .idleEnded, .fansUp,
    .batteryLow, .batteryNormal, .dndOn, .dndOff,
]

/// Drive a fresh brain into a self-chosen (autonomous) nap at t = 3.1.
private func makeNaturallySleepingBrain() -> DogBrain {
    let brain = makeBrain { $0.sleepChance = 1.0; $0.sleepDuration = 10...10 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    precondition(brain.state == .sleeping)
    return brain
}

// buildFinished → a brief party.

@Test func buildFinishedThrowsAPartyWhileIdle() {
    let brain = makeBrain()
    let effects = brain.handle(.system(.buildFinished), at: 1)
    #expect(brain.state == .idle)
    #expect(effects == [.stopMoving, .celebrate, .showHearts, .play(.idle)])
}

@Test func buildFinishedInterruptsWandering() {
    let brain = makeBrain()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)

    let effects = brain.handle(.system(.buildFinished), at: 4)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopMoving), "the in-flight wander walk must be cancelled")
    #expect(effects.contains(.celebrate))
    #expect(effects.contains(.showHearts))
}

@Test func buildFinishedIgnoredWhileEating() {
    let brain = makeBrain()
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 0)
    _ = brain.handle(.arrived, at: 1)
    #expect(brain.state == .eating)
    let effects = brain.handle(.system(.buildFinished), at: 1.5)
    #expect(effects == [])
    #expect(brain.state == .eating)
}

@Test func buildFinishedIgnoredWhileSleeping() {
    let brain = makeNaturallySleepingBrain()
    let effects = brain.handle(.system(.buildFinished), at: 4)
    #expect(effects == [], "no party wakes a sleeping dog")
    #expect(brain.state == .sleeping)
}

@Test func buildFinishedIgnoredDuringFetchChase() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    _ = brain.handle(.ballThrown(landing: CGPoint(x: 700, y: 100), origin: CGPoint(x: 400, y: 300)), at: 1)
    #expect(brain.state == .chasingBall)
    let effects = brain.handle(.system(.buildFinished), at: 2)
    #expect(effects == [])
    #expect(brain.state == .chasingBall)
}

// idleBegan / idleEnded → nap while you're away, up when you're back.

@Test func idleBeganNapsOnTheSpotWithoutBed() {
    let brain = makeBrain { $0.sleepDuration = 10...10 }
    let effects = brain.handle(.system(.idleBegan), at: 5)
    #expect(brain.state == .sleeping)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.sleep)))

    // An idle nap uses the normal sleep duration — he can wake on his own.
    #expect(brain.handle(.tick, at: 14.9) == [])
    _ = brain.handle(.tick, at: 15.1)
    #expect(brain.state == .idle)
}

@Test func idleBeganRoutesNapThroughBed() {
    let brain = makeBrain { $0.sleepDuration = 10...10 }
    let bed = CGPoint(x: 700, y: 500)
    brain.bedPosition = bed

    let effects = brain.handle(.system(.idleBegan), at: 5)
    #expect(brain.state == .goingToBed(.sleep))
    #expect(effects.contains(.play(.walk)))
    #expect(moveTarget(in: effects)?.point == bed)
    #expect(moveTarget(in: effects)?.speed == brain.tuning.walkSpeed)

    let arrived = brain.handle(.arrived, at: 7)
    #expect(brain.state == .sleeping)
    #expect(arrived.contains(.play(.sleep)))

    // Still a normal-length nap, not the indefinite DND kind.
    _ = brain.handle(.tick, at: 17.2)
    #expect(brain.state == .idle)
}

@Test func idleEndedWakesAnIdleNap() {
    let brain = makeBrain { $0.sleepDuration = 100...100 }
    _ = brain.handle(.system(.idleBegan), at: 5)
    #expect(brain.state == .sleeping)

    let effects = brain.handle(.system(.idleEnded), at: 10)
    #expect(brain.state == .idle)
    #expect(effects.contains(.play(.idle)))
}

@Test func idleEndedCancelsWalkToBedForIdleNap() {
    let brain = makeBrain()
    brain.bedPosition = CGPoint(x: 700, y: 500)
    _ = brain.handle(.system(.idleBegan), at: 5)
    #expect(brain.state == .goingToBed(.sleep))

    let effects = brain.handle(.system(.idleEnded), at: 6)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopMoving), "the in-flight walk to bed must be cancelled")
    #expect(effects.contains(.play(.idle)))
}

@Test func idleEndedDoesNotWakeSelfChosenNap() {
    let brain = makeNaturallySleepingBrain()
    let effects = brain.handle(.system(.idleEnded), at: 4)
    #expect(effects == [], "a nap he chose on his own is not interrupted")
    #expect(brain.state == .sleeping)
}

@Test func idleEndedIgnoredWhenNotSleeping() {
    let brain = makeBrain()
    _ = brain.handle(.command(.sit), at: 0)
    let effects = brain.handle(.system(.idleEnded), at: 1)
    #expect(effects == [])
    #expect(brain.state == .sitting)
}

@Test func idleBeganIgnoredWhileAwaitingThrow() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    #expect(brain.state == .awaitingThrow)
    let effects = brain.handle(.system(.idleBegan), at: 1)
    #expect(effects == [], "no nap, and definitely no accidental disarm")
    #expect(brain.state == .awaitingThrow)
}

// fansUp → zoomies.

@Test func fansUpStartsZoomies() {
    let brain = makeBrain { $0.zoomiesDuration = 10 }
    let effects = brain.handle(.system(.fansUp), at: 1)
    #expect(brain.state == .zoomies)
    #expect(effects.contains(.play(.run)))
    #expect(effects.contains(.startZoomies))

    #expect(brain.handle(.tick, at: 10.9) == [])
    let done = brain.handle(.tick, at: 11.1)
    #expect(brain.state == .idle)
    #expect(done.contains(.stopZoomies))
}

@Test func fansUpIgnoredDuringZoomies() {
    let brain = makeBrain { $0.zoomiesDuration = 10 }
    _ = brain.handle(.command(.zoomies), at: 0)
    let effects = brain.handle(.system(.fansUp), at: 1)
    #expect(effects == [], "already zooming — no restart, no deadline extension")
    #expect(brain.state == .zoomies)
    _ = brain.handle(.tick, at: 10.1)
    #expect(brain.state == .idle, "original zoomies deadline still stands")
}

@Test func fansUpIgnoredWhileBeingPetted() {
    let brain = makeBrain()
    _ = brain.handle(.petted, at: 0)
    let effects = brain.handle(.system(.fansUp), at: 0.5)
    #expect(effects == [])
    #expect(brain.state == .beingPetted)
}

// batteryLow / batteryNormal → conserve energy lying down.

@Test func batteryLowLiesDownOnTheSpotWithoutBed() {
    let brain = makeBrain { $0.lieTimeout = 90 }
    let effects = brain.handle(.system(.batteryLow), at: 1)
    #expect(brain.state == .lyingDown)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.lie)))

    // Even without a batteryNormal he eventually gets up, like any lie-down.
    _ = brain.handle(.tick, at: 91.2)
    #expect(brain.state == .idle)
}

@Test func batteryLowRoutesThroughBed() {
    let brain = makeBrain()
    let bed = CGPoint(x: 120, y: 80)
    brain.bedPosition = bed

    let effects = brain.handle(.system(.batteryLow), at: 1)
    #expect(brain.state == .goingToBed(.lie))
    #expect(effects.contains(.play(.walk)))
    #expect(moveTarget(in: effects)?.point == bed)

    let arrived = brain.handle(.arrived, at: 3)
    #expect(brain.state == .lyingDown)
    #expect(arrived.contains(.play(.lie)))
}

@Test func batteryLowIgnoredDuringTrick() {
    let brain = makeBrain()
    _ = brain.handle(.command(.trick(.playDead)), at: 0)
    let effects = brain.handle(.system(.batteryLow), at: 0.5)
    #expect(effects == [])
    #expect(brain.state == .performingTrick(.playDead))
}

@Test func batteryNormalRaisesABatteryLie() {
    let brain = makeBrain()
    _ = brain.handle(.system(.batteryLow), at: 1)
    #expect(brain.state == .lyingDown)

    let effects = brain.handle(.system(.batteryNormal), at: 10)
    #expect(brain.state == .idle)
    #expect(effects.contains(.play(.idle)))
}

@Test func batteryNormalLeavesACommandedLieAlone() {
    let brain = makeBrain()
    _ = brain.handle(.command(.lieDown), at: 0)
    #expect(brain.state == .lyingDown)
    let effects = brain.handle(.system(.batteryNormal), at: 1)
    #expect(effects == [], "he's lying because you asked, not because of the battery")
    #expect(brain.state == .lyingDown)
}

@Test func batteryNormalCancelsWalkToBedForBatteryLie() {
    let brain = makeBrain()
    brain.bedPosition = CGPoint(x: 120, y: 80)
    _ = brain.handle(.system(.batteryLow), at: 1)
    #expect(brain.state == .goingToBed(.lie))

    let effects = brain.handle(.system(.batteryNormal), at: 2)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopMoving))
}

@Test func batteryNormalAfterCommandsReplacedBatteryLieDoesNothing() {
    // battery lie → user commands sit, then lieDown: the lie is now
    // user-caused, so batteryNormal must not raise him.
    let brain = makeBrain()
    _ = brain.handle(.system(.batteryLow), at: 1)
    _ = brain.handle(.command(.sit), at: 2)
    _ = brain.handle(.command(.lieDown), at: 3)
    #expect(brain.state == .lyingDown)

    let effects = brain.handle(.system(.batteryNormal), at: 4)
    #expect(effects == [])
    #expect(brain.state == .lyingDown)
}

@Test func barkDuringBatteryLieResumesLyingAndBatteryNormalStillRaisesHim() {
    // A bark round-trip returns him to the battery lie without erasing why
    // he's lying there.
    let brain = makeBrain { $0.barkDuration = 1.2 }
    _ = brain.handle(.system(.batteryLow), at: 1)
    _ = brain.handle(.provoked(at: .zero), at: 2)
    #expect(brain.state == .barking)
    _ = brain.handle(.tick, at: 3.3)
    #expect(brain.state == .lyingDown)

    let effects = brain.handle(.system(.batteryNormal), at: 5)
    #expect(brain.state == .idle)
    #expect(effects.contains(.play(.idle)))
}

// dndOn / dndOff → lights out until the humans say otherwise.

@Test func dndOnSleepsIndefinitelyWithoutBed() {
    let brain = makeBrain { $0.sleepDuration = 10...10 }
    let effects = brain.handle(.system(.dndOn), at: 1)
    #expect(brain.state == .sleeping)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.sleep)))

    // No wake deadline: still out cold ages later.
    #expect(brain.handle(.tick, at: 10_000) == [])
    #expect(brain.state == .sleeping)
}

@Test func dndOnRoutesThroughBedAndSleepsUntilLifted() {
    let brain = makeBrain { $0.sleepDuration = 10...10 }
    let bed = CGPoint(x: 700, y: 500)
    brain.bedPosition = bed

    let effects = brain.handle(.system(.dndOn), at: 1)
    #expect(brain.state == .goingToBed(.sleep))
    #expect(moveTarget(in: effects)?.point == bed)

    let arrived = brain.handle(.arrived, at: 3)
    #expect(brain.state == .sleeping)
    #expect(arrived.contains(.play(.sleep)))

    // The in-bed DND sleep is indefinite too, not sleepDuration-bounded.
    #expect(brain.handle(.tick, at: 10_000) == [])
    #expect(brain.state == .sleeping)

    let woke = brain.handle(.system(.dndOff), at: 10_001)
    #expect(brain.state == .idle)
    #expect(woke.contains(.play(.idle)))
}

@Test func dndOffWakesADndSleep() {
    let brain = makeBrain()
    _ = brain.handle(.system(.dndOn), at: 1)
    #expect(brain.state == .sleeping)

    let effects = brain.handle(.system(.dndOff), at: 50)
    #expect(brain.state == .idle)
    #expect(effects.contains(.play(.idle)))
}

@Test func dndOffCancelsWalkToBedForDndSleep() {
    let brain = makeBrain()
    brain.bedPosition = CGPoint(x: 700, y: 500)
    _ = brain.handle(.system(.dndOn), at: 1)
    #expect(brain.state == .goingToBed(.sleep))

    let effects = brain.handle(.system(.dndOff), at: 2)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopMoving))
}

@Test func dndOffLeavesASelfChosenNapAlone() {
    let brain = makeNaturallySleepingBrain()
    let effects = brain.handle(.system(.dndOff), at: 4)
    #expect(effects == [])
    #expect(brain.state == .sleeping)
}

@Test func dndOffAfterTreatBrokeTheDndSleepDoesNotWakeALaterNap() {
    // The treat ends the DND sleep; a later self-chosen nap must not be
    // woken by the (stale) dndOff.
    let brain = makeBrain { $0.sleepChance = 1.0; $0.sleepDuration = 10...10; $0.eatDuration = 1 }
    _ = brain.handle(.system(.dndOn), at: 0)
    #expect(brain.state == .sleeping)
    _ = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: 1)
    _ = brain.handle(.arrived, at: 2)                        // eating
    _ = brain.handle(.tick, at: 3.1)                         // hunching
    _ = brain.handle(.tick, at: 3.1 + brain.tuning.hunchDuration) // idle (3s timer)
    _ = brain.handle(.tick, at: 9)                           // idle timer fires → nap
    #expect(brain.state == .sleeping)

    let effects = brain.handle(.system(.dndOff), at: 10)
    #expect(effects == [], "this nap is his own, not DND's")
    #expect(brain.state == .sleeping)
}

@Test func dndOnIgnoredWhileStalking() {
    let (brain, stalkStart) = makeStalkingBrain()
    let effects = brain.handle(.system(.dndOn), at: stalkStart + 1)
    #expect(effects == [])
    #expect(brain.state == .stalkingMouse)
}

// The arms outrank the machine entirely.

@Test func systemSignalsIgnoredWhileCarried() {
    for signal in allSystemSignals {
        let brain = makeBrain()
        _ = brain.handle(.pickedUp, at: 0)
        let effects = brain.handle(.system(signal), at: 1)
        #expect(effects == [], "\(signal) must be ignored while carried")
        #expect(brain.state == .carried, "\(signal) must not move him out of your arms")
    }
}

// MARK: - Toy box: frisbee

/// A brain with the frisbee armed and thrown, mid-chase.
private func makeFrisbeeChase(
    landing: CGPoint = CGPoint(x: 700, y: 100),
    origin: CGPoint = CGPoint(x: 400, y: 300)
) -> DogBrain {
    let brain = makeBrain()
    _ = brain.handle(.command(.toy(.frisbee)), at: 0)
    _ = brain.handle(.toyThrown(kind: .frisbee, landing: landing, origin: origin), at: 1)
    return brain
}

@Test func frisbeeCommandArmsThrowLikeFetch() {
    let brain = makeBrain()
    let effects = brain.handle(.command(.toy(.frisbee)), at: 0)
    #expect(brain.state == .awaitingThrow)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.sit)), "he waits for the throw sitting, like fetch")
    #expect(effects.contains(.armThrow))
}

@Test func frisbeeThrownStartsChase() {
    let brain = makeBrain()
    _ = brain.handle(.command(.toy(.frisbee)), at: 0)
    let landing = CGPoint(x: 700, y: 100)
    let effects = brain.handle(
        .toyThrown(kind: .frisbee, landing: landing, origin: CGPoint(x: 400, y: 300)), at: 1
    )
    #expect(brain.state == .chasingFrisbee)
    #expect(effects.contains(.play(.run)))
    #expect(moveTarget(in: effects)?.point == landing)
    #expect(moveTarget(in: effects)?.speed == brain.tuning.runSpeed)
}

@Test func frisbeeThrownWithoutArmingIsIgnored() {
    let brain = makeBrain()
    let effects = brain.handle(
        .toyThrown(kind: .frisbee, landing: CGPoint(x: 700, y: 100), origin: .zero), at: 1
    )
    #expect(effects == [])
    #expect(brain.state == .idle)
}

@Test func ballThrownIsIgnoredWhileTheFrisbeeIsArmed() {
    // The armed state is kind-aware: a stray ball throw can't hijack it.
    let brain = makeBrain()
    _ = brain.handle(.command(.toy(.frisbee)), at: 0)
    let effects = brain.handle(.ballThrown(landing: CGPoint(x: 700, y: 100), origin: .zero), at: 1)
    #expect(effects == [])
    #expect(brain.state == .awaitingThrow)
}

@Test func frisbeeThrowTimesOutAndDisarms() {
    let brain = makeBrain { $0.throwTimeout = 10 }
    _ = brain.handle(.command(.toy(.frisbee)), at: 0)
    let effects = brain.handle(.tick, at: 10.1)
    #expect(brain.state == .idle)
    #expect(effects.contains(.disarmThrow))
    // The armed kind is cleared too: a late throw finds nothing armed.
    #expect(brain.handle(.toyThrown(kind: .frisbee, landing: .zero, origin: .zero), at: 11) == [])
}

@Test func catchingFrisbeeMidAirCarriesItHome() {
    // The signature moment: the scene sends .arrived while the disc is still
    // in flight, so the pick-up happens off the ground.
    let origin = CGPoint(x: 400, y: 300)
    let brain = makeFrisbeeChase(origin: origin)

    let effects = brain.handle(.arrived, at: 2)
    #expect(brain.state == .returningToy(.frisbee))
    #expect(effects.contains(.pickUpToy(.frisbee)))
    #expect(effects.contains(.play(.carryWalk)))
    #expect(moveTarget(in: effects)?.point == origin)
    #expect(moveTarget(in: effects)?.speed == brain.tuning.carrySpeed)
}

@Test func frisbeeMissedInTheAirIsCollectedOffTheGround() {
    // The unglamorous path: no catch, so .arrived only lands after the disc
    // has settled. Same chain, later timestamp — he grabs it like the ball.
    let origin = CGPoint(x: 400, y: 300)
    let brain = makeFrisbeeChase(origin: origin)
    #expect(brain.handle(.tick, at: 3) == [], "the chase has no deadline of its own")
    #expect(brain.state == .chasingFrisbee)

    let pickup = brain.handle(.arrived, at: 4)
    #expect(brain.state == .returningToy(.frisbee))
    #expect(pickup.contains(.pickUpToy(.frisbee)))

    let home = brain.handle(.arrived, at: 6)
    #expect(brain.state == .idle)
    #expect(home.contains(.dropToy(.frisbee)))
}

@Test func returningFrisbeeDropsItAndCelebrates() {
    let brain = makeFrisbeeChase()
    _ = brain.handle(.arrived, at: 2)

    let effects = brain.handle(.arrived, at: 4)
    #expect(brain.state == .idle)
    #expect(effects.contains(.dropToy(.frisbee)))
    #expect(effects.contains(.celebrate))
    #expect(effects.contains(.play(.idle)))
}

@Test func commandDuringFrisbeeChaseRemovesTheFrisbee() {
    let brain = makeFrisbeeChase()
    let effects = brain.handle(.command(.sit), at: 2)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.removeToy(.frisbee)), "an abandoned chase tidies the disc away")
}

@Test func pickedUpWhileCarryingTheFrisbeeRemovesIt() {
    let brain = makeFrisbeeChase()
    _ = brain.handle(.arrived, at: 2)
    #expect(brain.state == .returningToy(.frisbee))

    let effects = brain.handle(.pickedUp, at: 3)
    #expect(brain.state == .carried)
    #expect(effects.contains(.removeToy(.frisbee)))
}

// MARK: - Toy box: squeaky

/// The squeaky is lobbed by the scene (no aiming), so the chase starts
/// straight from whatever he was doing.
private func makeSqueakyChase(
    landing: CGPoint = CGPoint(x: 500, y: 380)
) -> DogBrain {
    let brain = makeBrain()
    _ = brain.handle(.toyThrown(kind: .squeaky, landing: landing, origin: CGPoint(x: 400, y: 300)), at: 1)
    return brain
}

@Test func squeakyTossStartsChaseWithoutArming() {
    let landing = CGPoint(x: 500, y: 380)
    let brain = makeSqueakyChase(landing: landing)
    #expect(brain.state == .chasingFrisbee, "the thrown-toy chase is shared")
    let effects = brain.handle(.tick, at: 1.1)
    #expect(effects == [], "the chase runs until the scene reports arrival")

    let restart = makeBrain()
    let thrown = restart.handle(
        .toyThrown(kind: .squeaky, landing: landing, origin: .zero), at: 1
    )
    #expect(thrown.contains(.stopMoving))
    #expect(thrown.contains(.play(.run)))
    #expect(moveTarget(in: thrown)?.point == landing)
    #expect(moveTarget(in: thrown)?.speed == restart.tuning.runSpeed)
}

@Test func reachingSqueakyShakesItWithASqueak() {
    let brain = makeSqueakyChase()
    let effects = brain.handle(.arrived, at: 3)
    #expect(brain.state == .shakingToy)
    #expect(effects.contains(.pickUpToy(.squeaky)))
    #expect(effects.contains(.play(.shakeToy)))
    #expect(effects.contains(.playSound("squeak")))
    #expect(!effects.contains(where: { if case .moveTo = $0 { return true }; return false }),
            "he shakes it where it landed — no trip home")
}

@Test func shakingToyEndsByDroppingIt() {
    let brain = makeSqueakyChase()
    _ = brain.handle(.arrived, at: 3)
    #expect(brain.handle(.tick, at: 3 + brain.tuning.shakeToyDuration - 0.1) == [])

    let effects = brain.handle(.tick, at: 3 + brain.tuning.shakeToyDuration + 0.1)
    #expect(brain.state == .idle)
    #expect(effects.contains(.dropToy(.squeaky)))
    #expect(effects.contains(.play(.idle)))
}

@Test func squeakyTossIsIgnoredWhileCarried() {
    let brain = makeBrain()
    _ = brain.handle(.pickedUp, at: 0)
    let effects = brain.handle(
        .toyThrown(kind: .squeaky, landing: CGPoint(x: 500, y: 380), origin: .zero), at: 1
    )
    #expect(effects == [])
    #expect(brain.state == .carried)
}

@Test func squeakyTossDuringFetchTidiesTheBallAway() {
    let brain = makeBrain()
    _ = brain.handle(.command(.fetch), at: 0)
    _ = brain.handle(.ballThrown(landing: CGPoint(x: 700, y: 100), origin: CGPoint(x: 400, y: 300)), at: 1)

    let effects = brain.handle(
        .toyThrown(kind: .squeaky, landing: CGPoint(x: 500, y: 380), origin: .zero), at: 2
    )
    #expect(brain.state == .chasingFrisbee, "the new toy wins")
    #expect(effects.contains(.removeBall))
}

@Test func pettingDuringTheShakeRemovesTheSqueaky() {
    let brain = makeSqueakyChase()
    _ = brain.handle(.arrived, at: 3)
    #expect(brain.state == .shakingToy)

    let effects = brain.handle(.petted, at: 4)
    #expect(brain.state == .beingPetted)
    #expect(effects.contains(.removeToy(.squeaky)))
}

@Test func ropeIsNeverThrown() {
    let brain = makeBrain()
    let effects = brain.handle(
        .toyThrown(kind: .rope, landing: CGPoint(x: 500, y: 380), origin: .zero), at: 1
    )
    #expect(effects == [])
    #expect(brain.state == .idle)
}

// MARK: - Toy box: tug-of-war

/// The user has the free end of the rope and is pulling.
private func makeTugging(
    winChance: Double = 0,
    seed: UInt64 = 42,
    at start: Double = 1
) -> DogBrain {
    let brain = makeBrain(seed: seed) { $0.tugWinChance = winChance }
    _ = brain.handle(.tugStarted(at: CGPoint(x: 520, y: 300)), at: start)
    return brain
}

@Test func tugStartedBracesHim() {
    let brain = makeBrain()
    let effects = brain.handle(.tugStarted(at: CGPoint(x: 520, y: 300)), at: 1)
    #expect(brain.state == .tugging)
    #expect(effects.contains(.stopMoving), "he plants his feet")
    #expect(effects.contains(.startTug))
    #expect(effects.contains(.play(.tug)))
}

@Test func tugStartedIsIgnoredWhileCarried() {
    let brain = makeBrain()
    _ = brain.handle(.pickedUp, at: 0)
    let effects = brain.handle(.tugStarted(at: CGPoint(x: 520, y: 300)), at: 1)
    #expect(effects == [])
    #expect(brain.state == .carried)
}

@Test func tugMovedKeepsHimTuggingAndIsIgnoredOtherwise() {
    let brain = makeTugging()
    let pulling = brain.handle(.tugMoved(to: CGPoint(x: 600, y: 320), force: 0.7), at: 2)
    #expect(pulling == [], "the drag is the scene's business; the brain just holds on")
    #expect(brain.state == .tugging)

    let idleBrain = makeBrain()
    #expect(idleBrain.handle(.tugMoved(to: CGPoint(x: 600, y: 320), force: 0.7), at: 1) == [])
    #expect(idleBrain.state == .idle)
}

@Test func tugMovedDoesNotResetTheTimeout() {
    // A user who keeps waggling the rope can't stall the showdown forever.
    let brain = makeTugging()
    for step in 1...5 {
        _ = brain.handle(.tugMoved(to: CGPoint(x: 600, y: 300), force: 0.5), at: 1 + Double(step))
    }
    let effects = brain.handle(.tick, at: 1 + brain.tuning.tugTimeout + 0.1)
    #expect(brain.state != .tugging, "the tugTimeout still fires, got \(effects)")
}

@Test func releasingTheRopeEndsTheTug() {
    let brain = makeTugging()
    let effects = brain.handle(.tugEnded, at: 4)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopTug))
    #expect(effects.contains(.dropToy(.rope)))
    #expect(effects.contains(.play(.idle)))
}

@Test func tugEndedIsIgnoredWhenNotTugging() {
    let brain = makeBrain()
    let effects = brain.handle(.tugEnded, at: 1)
    #expect(effects == [])
    #expect(brain.state == .idle)
}

@Test func winningTheTugTakesThePrizeForAVictoryLap() {
    let brain = makeTugging(winChance: 1.0)
    let effects = brain.handle(.tick, at: 1 + brain.tuning.tugTimeout + 0.1)
    #expect(brain.state == .returningToy(.rope))
    #expect(effects.contains(.stopTug))
    #expect(effects.contains(.pickUpToy(.rope)))
    #expect(effects.contains(.celebrate))
    #expect(moveTarget(in: effects)?.speed == brain.tuning.carrySpeed,
            "he trots off with it rather than teleporting")

    let lap = brain.handle(.arrived, at: 20)
    #expect(brain.state == .idle)
    #expect(lap.contains(.dropToy(.rope)))
}

@Test func losingTheTugDropsTheRope() {
    let brain = makeTugging(winChance: 0)
    #expect(brain.handle(.tick, at: 1 + brain.tuning.tugTimeout - 0.1) == [])

    let effects = brain.handle(.tick, at: 1 + brain.tuning.tugTimeout + 0.1)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopTug))
    #expect(effects.contains(.dropToy(.rope)))
    #expect(!effects.contains(.pickUpToy(.rope)))
}

@Test func tugOutcomeIsDeterministicAndSplitsBothWays() {
    // A coin-flip knob driven by the seeded RNG: same seed, same result;
    // across seeds, both endings show up.
    var wins = 0
    for seed in UInt64(1)...20 {
        let first = makeTugging(winChance: 0.5, seed: seed)
        _ = first.handle(.tick, at: 1 + first.tuning.tugTimeout + 0.1)
        let second = makeTugging(winChance: 0.5, seed: seed)
        _ = second.handle(.tick, at: 1 + second.tuning.tugTimeout + 0.1)
        #expect(first.state == second.state, "seed \(seed) must replay identically")
        if first.state == .returningToy(.rope) { wins += 1 }
    }
    #expect(wins > 0 && wins < 20, "a 50/50 knob should not be one-sided, got \(wins)/20")
}

@Test func victoryTrotStaysOnScreen() {
    for seed in UInt64(1)...12 {
        let brain = makeBrain(seed: seed) { $0.tugWinChance = 1.0 }
        brain.position = CGPoint(x: 70, y: 70) // wedged in a corner
        _ = brain.handle(.tugStarted(at: CGPoint(x: 120, y: 90)), at: 1)
        let effects = brain.handle(.tick, at: 1 + brain.tuning.tugTimeout + 0.1)
        let target = moveTarget(in: effects)?.point
        #expect(target != nil, "seed \(seed): the victory lap needs somewhere to go")
        if let target {
            #expect((0...800).contains(target.x), "seed \(seed): x=\(target.x)")
            #expect((0...600).contains(target.y), "seed \(seed): y=\(target.y)")
        }
    }
}

@Test func treatDuringTugStopsIt() {
    let brain = makeTugging()
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: 3)
    #expect(brain.state == .chasingTreat, "peanut butter outranks the rope")
    #expect(effects.contains(.stopTug))
    #expect(effects.contains(.removeToy(.rope)))
}

@Test func pettingDuringTugStopsIt() {
    let brain = makeTugging()
    let effects = brain.handle(.petted, at: 3)
    #expect(brain.state == .beingPetted)
    #expect(effects.contains(.stopTug))
}

@Test func pickingHimUpDuringTugStopsIt() {
    let brain = makeTugging()
    let effects = brain.handle(.pickedUp, at: 3)
    #expect(brain.state == .carried)
    #expect(effects.contains(.stopTug))
    #expect(effects.contains(.removeToy(.rope)))
}

@Test func commandDuringTugStopsIt() {
    let brain = makeTugging()
    let effects = brain.handle(.command(.sit), at: 3)
    #expect(brain.state == .sitting)
    #expect(effects.contains(.stopTug))
}
