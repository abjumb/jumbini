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
