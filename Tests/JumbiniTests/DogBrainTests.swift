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
    tuning.perchChance = 0
    tuning.parkourChance = 0
    tuning.perchNapChance = 0
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

@Test func poopSettingDisablesAutonomousHunching() {
    let brain = makeBrain { $0.hunchChance = 1 }
    brain.poopEnabled = false
    _ = brain.handle(.tick, at: 0)

    let effects = brain.handle(.tick, at: 3)

    #expect(brain.state == .wandering)
    #expect(!effects.contains(.play(.hunch)))
    #expect(!effects.contains(.leaveDeposit))
}

@Test func poopSettingSkipsThePostTreatHunch() {
    let brain = makeBrain { $0.eatDuration = 1 }
    brain.poopEnabled = false
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 0)
    _ = brain.handle(.arrived, at: 1)

    let digested = brain.handle(.tick, at: 2)

    #expect(brain.state == .idle)
    #expect(!digested.contains(.play(.hunch)))
    #expect(!digested.contains(.leaveDeposit))
}

@Test func disablingPoopMidHunchEndsTheBreakImmediately() {
    let brain = makeBrain { $0.hunchChance = 1 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3)
    #expect(brain.state == .hunching)

    let disabled = brain.disableBathroomBreaks(at: 4)

    #expect(brain.state == .idle)
    #expect(disabled.contains(.stopMoving))
    #expect(disabled.contains(.play(.idle)))

    let completed = brain.handle(.tick, at: 3 + brain.tuning.hunchDuration)

    #expect(brain.state == .idle)
    #expect(!completed.contains(.leaveDeposit))
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
    #expect(effects.contains { if case .playSound(let n) = $0 { return n.hasPrefix("bark") }; return false },
            "a provoked bark plays one of the three recorded barks")

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
    #expect(again.contains { if case .playSound(let n) = $0 { return n.hasPrefix("bark") }; return false })
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
    #expect(effects.contains(.playSound("growl")), "he growls at the Dock, not a friendly borf")
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
    #expect(effects == [.stopMoving, .celebrate, .showHearts, .playSound("yip"), .play(.idle)])
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

@Test func dndOnSleepsUntilLiftedOrTheSafetyDeadline() {
    let brain = makeBrain { $0.sleepDuration = 10...10 }
    let effects = brain.handle(.system(.dndOn), at: 1)
    #expect(brain.state == .sleeping)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.sleep)))

    // Far past a normal nap and still out cold — this is not sleepDuration.
    #expect(brain.handle(.tick, at: 100) == [])
    #expect(brain.state == .sleeping)

    // But not forever: dndOff can never arrive on a machine where the Focus
    // database is unreadable, and a state with no exit reads as a hang.
    _ = brain.handle(.tick, at: 1 + brain.tuning.dndSleepSafety + 0.1)
    #expect(brain.state == .idle)
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

@Test func disablingSystemReactionsReleasesASystemCausedRest() {
    let brain = makeBrain()
    _ = brain.handle(.system(.dndOn), at: 0)
    #expect(brain.state == .sleeping)

    let effects = brain.disableSystemReactions(at: 1)

    #expect(brain.state == .idle)
    #expect(effects.contains(.stopMoving))
    #expect(effects.contains(.play(.idle)))
}

@Test func disablingSystemReactionsPreservesTreatChaseThatInterruptedRest() {
    let brain = makeBrain()
    _ = brain.handle(.system(.dndOn), at: 0)
    _ = brain.handle(.treatDropped(at: CGPoint(x: 640, y: 200)), at: 1)
    #expect(brain.state == .chasingTreat)

    let effects = brain.disableSystemReactions(at: 2)

    #expect(brain.state == .chasingTreat)
    #expect(effects == [])
}

@Test func disablingSystemReactionsPreservesPickupThatInterruptedRest() {
    let brain = makeBrain()
    _ = brain.handle(.system(.batteryLow), at: 0)
    _ = brain.handle(.pickedUp, at: 1)
    #expect(brain.state == .carried)

    let effects = brain.disableSystemReactions(at: 2)

    #expect(brain.state == .carried)
    #expect(effects == [])
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

// MARK: - Cross-feature defects found by the brain-semantics review

@Test func retossedSqueakyDoesNotRemoveTheReplacementToy() {
    // The scene swaps the squeaky node BEFORE sending .toyThrown, exactly like
    // a re-dropped treat. Cleanup must not delete the toy that just arrived.
    let brain = makeBrain()
    _ = brain.handle(.toyThrown(kind: .squeaky, landing: CGPoint(x: 500, y: 300),
                                origin: CGPoint(x: 400, y: 300)), at: 0)
    #expect(brain.state == .chasingFrisbee)

    let retoss = brain.handle(.toyThrown(kind: .squeaky, landing: CGPoint(x: 200, y: 200),
                                         origin: CGPoint(x: 400, y: 300)), at: 1)
    #expect(brain.state == .chasingFrisbee)
    #expect(!retoss.contains(.removeToy(.squeaky)), "a re-toss swaps the node; removing it kills the NEW toy")
}

@Test func retossedSqueakyDuringTheShakeKeepsTheReplacement() {
    let brain = makeBrain { $0.shakeToyDuration = 2 }
    _ = brain.handle(.toyThrown(kind: .squeaky, landing: CGPoint(x: 500, y: 300),
                                origin: CGPoint(x: 400, y: 300)), at: 0)
    _ = brain.handle(.arrived, at: 1)
    #expect(brain.state == .shakingToy)

    let retoss = brain.handle(.toyThrown(kind: .squeaky, landing: CGPoint(x: 200, y: 200),
                                         origin: CGPoint(x: 400, y: 300)), at: 1.5)
    #expect(!retoss.contains(.removeToy(.squeaky)))
    #expect(brain.state == .chasingFrisbee)
}

@Test func frisbeeTossStillClearsAStaleSqueaky() {
    // Only the SAME kind is spared — a different toy must still be tidied away.
    let brain = makeBrain()
    _ = brain.handle(.toyThrown(kind: .squeaky, landing: CGPoint(x: 500, y: 300),
                                origin: CGPoint(x: 400, y: 300)), at: 0)
    _ = brain.handle(.command(.toy(.frisbee)), at: 1)
    let thrown = brain.handle(.toyThrown(kind: .frisbee, landing: CGPoint(x: 200, y: 200),
                                         origin: CGPoint(x: 400, y: 300)), at: 2)
    #expect(brain.state == .chasingFrisbee)
    #expect(thrown.isEmpty || !thrown.contains(.removeToy(.frisbee)))
}

@Test func autonomousBarkRespectsTheCooldownAndWandersInstead() {
    // Bark-at-nothing wrote lastBark but never read it, so a provoked bark
    // could be followed by an autonomous one well inside barkCooldown.
    let brain = makeBrain { $0.barkAtNothingChance = 1.0; $0.barkCooldown = 8 }
    _ = brain.handle(.provoked(at: CGPoint(x: 400, y: 300)), at: 0)
    #expect(brain.state == .barking)
    _ = brain.handle(.tick, at: 1.3) // bark ends -> idle, timer armed for 3s
    #expect(brain.state == .idle)

    let roll = brain.handle(.tick, at: 4.4) // inside the 8s cooldown
    #expect(brain.state != .barking, "second bark only 4.4s after the first")
    #expect(!roll.contains { if case .playSound = $0 { return true }; return false }, "no bark sound at all while cooling down")
    #expect(brain.state == .wandering, "the band falls through to a wander")
}

@Test func buildPartyDoesNotCancelTheBatteryConserve() {
    // batteryLow is edge-triggered: if the party clears restReason, the
    // conserve is lost for the whole discharge because it never re-fires.
    let brain = makeBrain()
    _ = brain.handle(.system(.batteryLow), at: 0)
    #expect(brain.state == .lyingDown)

    let party = brain.handle(.system(.buildFinished), at: 30)
    #expect(party.contains(.celebrate))
    #expect(brain.state == .lyingDown, "he celebrates from his bed, still conserving")

    let up = brain.handle(.system(.batteryNormal), at: 60)
    #expect(brain.state == .idle, "plugging in still gets him up")
    #expect(up.contains(.play(.idle)))
}

@Test func aSignalArrivingMidChaseIsDeferredNotDropped() {
    // The monitor is edge-triggered, so a dropped signal is lost forever.
    let brain = makeBrain()
    _ = brain.handle(.treatDropped(at: CGPoint(x: 600, y: 300)), at: 0)
    #expect(brain.state == .chasingTreat)

    let ignored = brain.handle(.system(.dndOn), at: 1)
    #expect(ignored.isEmpty, "nothing interrupts a treat")

    _ = brain.handle(.arrived, at: 2)          // eating
    _ = brain.handle(.tick, at: 3.2)           // -> hunching
    _ = brain.handle(.tick, at: 6)             // -> idle, now calm
    let caughtUp = brain.handle(.tick, at: 6.1)
    #expect(brain.state == .sleeping || brain.state == .goingToBed(.sleep),
            "the deferred Focus signal lands once he settles, got \(brain.state)")
    #expect(!caughtUp.isEmpty)
}

@Test func dndSleepCannotStrandHimForeverWithoutADeadline() {
    // dndOff may never arrive (the Focus DB is unreadable on some machines).
    let brain = makeBrain()
    _ = brain.handle(.system(.dndOn), at: 0)
    #expect(brain.state == .sleeping)

    let woken = brain.handle(.tick, at: brain.tuning.dndSleepSafety + 1)
    #expect(brain.state == .idle, "a safety deadline eventually releases him")
    #expect(woken.contains(.play(.idle)))
}

// MARK: - Window walking (perch / ride / fall)

/// A window in scene coordinates: `y` is its BOTTOM edge, so the perch line
/// — the top of the title bar — is at `y + height`.
private func testSurface(
    _ id: CGWindowID, x: CGFloat = 300, y: CGFloat = 120,
    width: CGFloat = 400, height: CGFloat = 300
) -> Surface {
    Surface(
        id: id,
        rect: CGRect(x: x, y: y, width: width, height: height),
        title: "Window \(id)",
        ownerPID: 900
    )
}

/// The default brain stands at (400, 300); this window's top edge is at 420,
/// a comfortable 120pt climb, and it spans x 300…700.
private let perchable = testSurface(1)

/// A brain that will take the perch branch the moment its idle timer fires.
private func makePercher(
    surfaces: [Surface] = [perchable],
    tune: @escaping (inout BrainTuning) -> Void = { _ in }
) -> DogBrain {
    let brain = makeBrain { tuning in
        tuning.perchChance = 1
        tuning.perchDuration = 30...30
        tuning.peekDuration = 1
        tune(&tuning)
    }
    brain.surfaces = surfaces
    return brain
}

@Test func windowClimbingSettingSkipsThePerchBranch() {
    let brain = makePercher()
    brain.windowClimbingEnabled = false
    _ = brain.handle(.tick, at: 0)

    let effects = brain.handle(.tick, at: 3)

    #expect(brain.state == .wandering)
    #expect(moveTarget(in: effects) != nil)
}

@Test func disablingWindowClimbingDropsAnActivePerchSafely() {
    let brain = makePerched()
    brain.windowClimbingEnabled = false
    brain.surfaces = []

    let effects = brain.handle(.tick, at: 5.1)

    #expect(brain.state == .falling)
    #expect(effects.contains { if case .startFalling = $0 { return true }; return false })
}

/// Idle → heading to the edge → hop → perched, on the fixed clock the other
/// perch tests build on. Leaves him standing on the title bar at t=5.
private func makePerched(
    surfaces: [Surface] = [perchable],
    tune: @escaping (inout BrainTuning) -> Void = { _ in }
) -> DogBrain {
    let brain = makePercher(surfaces: surfaces, tune: tune)
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)      // → .headingToSurface
    brain.position = CGPoint(x: 300, y: 300)
    _ = brain.handle(.arrived, at: 4)     // → .hoppingUp
    brain.position = CGPoint(x: 324, y: 420)
    _ = brain.handle(.arrived, at: 5)     // → .perched, first patrol leg
    return brain
}

private func fallTarget(in effects: [DogEffect]) -> CGFloat? {
    for case let .startFalling(toY) in effects { return toY }
    return nil
}

private func hopTarget(in effects: [DogEffect]) -> CGPoint? {
    for case let .hopTo(point) in effects { return point }
    return nil
}

// MARK: Choosing a window

@Test func perchAutonomyWalksToTheNearEdgeOfAWindow() {
    let brain = makePercher()
    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 3.1)

    #expect(brain.state == .headingToSurface(surfaceID: 1))
    #expect(effects.contains(.play(.walk)))
    // He stands at x=400 inside the window's 300…700 span: the left edge is
    // the near one, and the approach stays at his current height.
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 300, y: 300))
    #expect(moveTarget(in: effects)?.speed == brain.tuning.walkSpeed)
}

@Test func withoutThePerchChanceHeIgnoresYourWindowsEntirely() {
    let brain = makeBrain() // perchChance is zeroed, like every other band
    brain.surfaces = [perchable]
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)
}

@Test func thePerchBandSitsBeneathTheOlderAutonomyBands() {
    // Both bands certain: the one that was there first still wins, so adding
    // the perch can't quietly steal a nap.
    let brain = makeBrain { $0.sleepChance = 1; $0.perchChance = 1; $0.sleepDuration = 10...10 }
    brain.surfaces = [perchable]
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .sleeping)
}

@Test func withNoWindowsThePerchRollFallsThroughToWandering() {
    let brain = makePercher(surfaces: [])
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering, "no windows means the dog stays on the desktop")
}

@Test func aWindowTooHighToReachIsNotAPerch() {
    let brain = makePercher { $0.perchReach = 50 } // the fixture is a 120pt climb
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)
}

@Test func aWindowTooFarAwayIsNotAPerch() {
    let brain = makePercher { $0.perchSearchRadius = 50 }
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)
}

@Test func aWindowWhoseTopIsBelowHimIsNotAPerch() {
    // Top edge at 200, he's at 300: that's a step down, not a climb.
    let brain = makePercher(surfaces: [testSurface(9, y: 0, height: 200)])
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering)
}

@Test func heClimbsTheNearestReachableWindow() {
    // Far window first in the list (front-most), near window second: distance
    // wins over stacking order.
    let far = testSurface(1, x: 700, y: 120, width: 300, height: 300)
    let near = testSurface(2, x: 380, y: 120, width: 300, height: 300)
    let brain = makePercher(surfaces: [far, near])
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .headingToSurface(surfaceID: 2))
}

// MARK: The hop

@Test func arrivingAtTheEdgeHopsUpOntoTheTitleBar() {
    let brain = makePercher()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    brain.position = CGPoint(x: 300, y: 300)
    let effects = brain.handle(.arrived, at: 4)

    #expect(brain.state == .hoppingUp(surfaceID: 1))
    // Onto the top edge, a little in from the corner so he isn't teetering.
    #expect(hopTarget(in: effects) == CGPoint(x: 324, y: 420))
}

@Test func footOffsetKeepsHisFeetOnTheTitleBarNotHisBelly() {
    // The scene reports half his sprite height; the brain stands his CENTRE
    // that far above the perch line.
    let brain = makePercher()
    brain.footOffset = 30
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    brain.position = CGPoint(x: 300, y: 300)
    let effects = brain.handle(.arrived, at: 4)
    #expect(hopTarget(in: effects) == CGPoint(x: 324, y: 450))
}

@Test func landingTheHopStartsPatrollingTheTitleBar() {
    let brain = makePerched()
    #expect(brain.state == .perched(surfaceID: 1))
}

@Test func thePatrolTrotsToTheFarEndOfTheWindow() {
    let brain = makePercher()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    brain.position = CGPoint(x: 300, y: 300)
    _ = brain.handle(.arrived, at: 4)
    brain.position = CGPoint(x: 324, y: 420)
    let effects = brain.handle(.arrived, at: 5)

    #expect(brain.state == .perched(surfaceID: 1))
    #expect(effects.contains(.play(.walk)))
    // He landed at the left end, so he heads for the right one, same height.
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 676, y: 420))
}

@Test func reachingTheEndOfTheLedgePeeksOverIt() {
    let brain = makePerched()
    brain.position = CGPoint(x: 676, y: 420)
    let effects = brain.handle(.arrived, at: 6)
    #expect(brain.state == .perched(surfaceID: 1))
    #expect(effects.contains(.play(.peek)))
}

@Test func afterPeekingHeTrotsBackTheOtherWay() {
    let brain = makePerched()
    brain.position = CGPoint(x: 676, y: 420)
    _ = brain.handle(.arrived, at: 6)
    #expect(brain.handle(.tick, at: 6.5) == [], "the peek lasts a beat")

    let effects = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .perched(surfaceID: 1))
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 324, y: 420))
}

// MARK: Riding a moving window

@Test func draggingTheWindowCarriesHimAlongAndRetargetsThePatrol() {
    let brain = makePerched()
    // The user nudges the window 60pt right and 40pt down. The scene shifts
    // the dog by the same delta before the next tick.
    brain.surfaces = [testSurface(1, x: 360, y: 80)]
    brain.position = CGPoint(x: 384, y: 380)
    let effects = brain.handle(.tick, at: 5.5)

    #expect(brain.state == .perched(surfaceID: 1), "a gentle drag doesn't shake him off")
    #expect(effects.contains(.stopMoving), "the in-flight walk has a stale target")
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 736, y: 380))
}

@Test func aWindowYankedAcrossTheScreenShakesHimOff() {
    let brain = makePerched()
    brain.surfaces = [testSurface(1, x: 700, y: 120)] // 400pt in one poll
    let effects = brain.handle(.tick, at: 5.5)

    #expect(brain.state == .falling)
    #expect(effects.contains(.play(.fall)))
    #expect(effects.contains(.stopMoving))
}

@Test func aWindowSlidingOutFromUnderHimDropsHim() {
    let brain = makePerched()
    // Same top edge, and a slide gentle enough to ride (150pt, under the
    // 180pt limit) — but the window is narrower now, so it has slid out from
    // under him entirely and he's standing on nothing.
    brain.surfaces = [testSurface(1, x: 450, y: 120, width: 200)]
    let effects = brain.handle(.tick, at: 5.5)

    #expect(brain.state == .falling, "he trotted off the end")
    #expect(fallTarget(in: effects) != nil)
}

@Test func closingTheWindowUnderHimDropsHim() {
    let brain = makePerched()
    brain.surfaces = []
    let effects = brain.handle(.tick, at: 5.5)

    #expect(brain.state == .falling)
    #expect(effects.contains(.play(.fall)))
    #expect(effects.contains(.startFalling(toY: 300)), "back down to where he climbed from")
}

@Test func theWindowVanishingMidHopDropsHim() {
    let brain = makePercher()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    brain.position = CGPoint(x: 300, y: 300)
    _ = brain.handle(.arrived, at: 4)
    #expect(brain.state == .hoppingUp(surfaceID: 1))

    brain.surfaces = []
    brain.position = CGPoint(x: 310, y: 380) // mid-arc
    let effects = brain.handle(.tick, at: 4.2)
    #expect(brain.state == .falling)
    #expect(effects.contains(.stopMoving))
}

@Test func theWindowVanishingDuringTheApproachEndsTheAdventure() {
    let brain = makePercher()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .headingToSurface(surfaceID: 1))

    brain.surfaces = []
    let effects = brain.handle(.tick, at: 3.5)
    #expect(brain.state == .idle, "he's still on the floor; nothing to fall from")
    #expect(effects.contains(.stopMoving))
}

@Test func heEventuallyGetsBoredAndHopsDown() {
    let brain = makePerched { $0.perchDuration = 10...10 }
    #expect(brain.handle(.tick, at: 14) == [], "still patrolling")
    let effects = brain.handle(.tick, at: 15.1) // the perch began at t=5
    #expect(brain.state == .falling)
    #expect(effects.contains(.startFalling(toY: 300)))
}

// MARK: Falling and landing

@Test func aFallAimsAtALowerWindowWhenOneIsUnderHim() {
    let lower = testSurface(2, x: 200, y: 0, width: 400, height: 350) // top at 350
    let brain = makePerched(surfaces: [perchable, lower])
    brain.surfaces = [lower] // the window he was standing on closed
    let effects = brain.handle(.tick, at: 5.5)

    #expect(brain.state == .falling)
    #expect(fallTarget(in: effects) == 350, "he catches the window below instead of the floor")
}

@Test func fallingIsSilentWhileHeIsStillInTheAir() {
    let brain = makePerched()
    brain.surfaces = []
    _ = brain.handle(.tick, at: 5.5)
    brain.position = CGPoint(x: 324, y: 400)
    #expect(brain.handle(.tick, at: 5.6) == [])
    brain.position = CGPoint(x: 324, y: 340)
    #expect(brain.handle(.tick, at: 5.7) == [])
}

@Test func reachingTheGroundAbsorbsTheLandingAndReturnsToIdle() {
    let brain = makePerched()
    brain.surfaces = []
    _ = brain.handle(.tick, at: 5.5)
    #expect(brain.state == .falling)

    brain.position = CGPoint(x: 324, y: 299)
    let effects = brain.handle(.tick, at: 6)
    #expect(brain.state == .idle)
    #expect(effects.contains(.stopFalling))
    #expect(effects.contains(.absorbLanding))
    #expect(effects.contains(.play(.idle)))
}

// MARK: Interruptions

@Test func pickingHimUpOffALedgeEndsThePerchCleanly() {
    let brain = makePerched()
    _ = brain.handle(.pickedUp, at: 6)
    #expect(brain.state == .carried)

    // Nothing stale left behind: the window closing now is a non-event.
    brain.surfaces = []
    #expect(brain.handle(.tick, at: 7) == [])
    #expect(brain.state == .carried)
}

@Test func pickingHimUpMidFallStopsTheGravity() {
    let brain = makePerched()
    brain.surfaces = []
    _ = brain.handle(.tick, at: 5.5)
    let effects = brain.handle(.pickedUp, at: 6)

    #expect(brain.state == .carried)
    #expect(effects.contains(.stopFalling))
}

@Test func aTreatOutranksALedge() {
    let brain = makePerched()
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: 6)
    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.stopMoving))

    brain.surfaces = []
    #expect(brain.handle(.tick, at: 7) == [], "no ghost fall from a perch he already left")
}

@Test func aTreatDuringAFallStopsTheGravity() {
    let brain = makePerched()
    brain.surfaces = []
    _ = brain.handle(.tick, at: 5.5)
    let effects = brain.handle(.treatDropped(at: CGPoint(x: 100, y: 100)), at: 6)

    #expect(brain.state == .chasingTreat)
    #expect(effects.contains(.stopFalling))
}

@Test func pettingHimOnALedgeWorks() {
    let brain = makePerched()
    let effects = brain.handle(.petted, at: 6)
    #expect(brain.state == .beingPetted)
    #expect(effects.contains(.showHearts))
}

@Test func aCommandWhilePerchedTakesOver() {
    let brain = makePerched()
    _ = brain.handle(.command(.sit), at: 6)
    #expect(brain.state == .sitting)

    brain.surfaces = []
    #expect(brain.handle(.tick, at: 7) == [], "sitting is not falling")
}

@Test func aCommandWhileFallingStopsTheGravity() {
    let brain = makePerched()
    brain.surfaces = []
    _ = brain.handle(.tick, at: 5.5)
    let effects = brain.handle(.command(.spin), at: 6)

    #expect(brain.state == .spinning)
    #expect(effects.contains(.stopFalling))
}

// MARK: Dropped in mid-air

@Test func droppingHimOverAWindowLandsHimOnItsTitleBar() {
    let brain = makeBrain()
    brain.surfaces = [perchable] // top edge at 420
    _ = brain.handle(.pickedUp, at: 1)
    let effects = brain.handle(.dropped(at: CGPoint(x: 500, y: 560)), at: 2)

    #expect(brain.state == .falling, "let go over a window, he drops onto it")
    #expect(fallTarget(in: effects) == 420)
    #expect(effects.contains(.play(.fall)))
}

@Test func droppingHimWithNothingUnderneathLeavesHimExactlyThere() {
    // The dog roams the whole screen, so a plain drop must NOT yank him to
    // the bottom of the display — only a window under him causes a fall.
    let brain = makeBrain()
    brain.surfaces = [perchable]
    _ = brain.handle(.pickedUp, at: 1)
    let effects = brain.handle(.dropped(at: CGPoint(x: 100, y: 560)), at: 2)

    #expect(brain.state == .idle)
    #expect(effects.contains(.play(.idle)))
}

@Test func droppingHimBesideAWindowAtGroundLevelLeavesHimThere() {
    // Over the window horizontally, but already below its title bar.
    let brain = makeBrain()
    brain.surfaces = [perchable]
    _ = brain.handle(.pickedUp, at: 1)
    _ = brain.handle(.dropped(at: CGPoint(x: 500, y: 200)), at: 2)
    #expect(brain.state == .idle)
}

// MARK: The whole adventure

@Test func theWholeAdventureRunsFromDesktopToLedgeAndBack() {
    let brain = makePercher { $0.perchDuration = 20...20 }
    _ = brain.handle(.tick, at: 0)
    #expect(brain.handle(.tick, at: 3.1).contains(.play(.walk)))
    #expect(brain.state == .headingToSurface(surfaceID: 1))

    brain.position = CGPoint(x: 300, y: 300)
    _ = brain.handle(.arrived, at: 4)
    #expect(brain.state == .hoppingUp(surfaceID: 1))

    brain.position = CGPoint(x: 324, y: 420)
    _ = brain.handle(.arrived, at: 5)
    #expect(brain.state == .perched(surfaceID: 1))

    // Trot to the far end, look over the drop, trot back.
    brain.position = CGPoint(x: 676, y: 420)
    #expect(brain.handle(.arrived, at: 8).contains(.play(.peek)))
    let back = brain.handle(.tick, at: 9.5)
    #expect(moveTarget(in: back)?.point == CGPoint(x: 324, y: 420))
    brain.position = CGPoint(x: 324, y: 420)
    #expect(brain.handle(.arrived, at: 12).contains(.play(.peek)))

    // Bored: the perch began at t=5 and lasts 20 seconds.
    let down = brain.handle(.tick, at: 25.1)
    #expect(brain.state == .falling)
    #expect(down.contains(.startFalling(toY: 300)))

    // The scene walks him down; he absorbs the landing and gets on with it.
    brain.position = CGPoint(x: 324, y: 300)
    let landed = brain.handle(.tick, at: 25.6)
    #expect(landed.contains(.absorbLanding))
    #expect(brain.state == .idle)

    // And he's a normal dog again: the idle timer runs, no ghost of the perch.
    #expect(brain.handle(.tick, at: 28.0) == [], "the ordinary idle timer, ticking again")
    _ = brain.handle(.tick, at: 28.8)
    #expect(brain.state == .headingToSurface(surfaceID: 1), "and off he goes again")
}

// MARK: - Window parkour (hop between windows / perch nap)
//
// The signature leap on top of climbing: once he's on a title bar he can hop
// straight onto a NEIGHBOURING window without coming down, and occasionally
// settle into a nap on a wide ledge. `perchable` is the ledge he climbs onto;
// every neighbour below is defined relative to it.

/// A neighbour to the right of `perchable`: top edge at 500 (an 80pt rise),
/// horizontally 48pt of gap away — comfortably inside the default limits.
private let parkourNeighbour = testSurface(2, x: 700, y: 200, width: 400, height: 300)

/// A dog perched on `perchable` who has walked to the far end and finished a
/// peek — the exact moment the next move (parkour / nap / turn around) is
/// decided by the tick that follows.
private func makeDecisionPoint(
    surfaces: [Surface] = [perchable],
    tune: @escaping (inout BrainTuning) -> Void = { _ in }
) -> DogBrain {
    let brain = makePerched(surfaces: surfaces, tune: tune)
    brain.position = CGPoint(x: 676, y: 420) // far end of `perchable`
    _ = brain.handle(.arrived, at: 6)         // → peek, deadline at t=7
    return brain
}

// MARK: The hop

@Test func aPerchedDogHopsToANeighbouringWindow() {
    let brain = makeDecisionPoint(
        surfaces: [perchable, parkourNeighbour], tune: { $0.parkourChance = 1 }
    )
    let effects = brain.handle(.tick, at: 7.1)

    #expect(brain.state == .hoppingAcross(toID: 2))
    #expect(effects.contains(.play(.pounce)))
    // Lands on the neighbour's near edge, directly across from where he took off.
    #expect(hopTarget(in: effects) == CGPoint(x: 724, y: 500))
}

@Test func withoutANeighbourHeTurnsAroundAsBefore() {
    // Parkour is wanted, but there's nowhere to hop: the ordinary patrol wins.
    let brain = makeDecisionPoint(surfaces: [perchable], tune: { $0.parkourChance = 1 })
    let effects = brain.handle(.tick, at: 7.1)

    #expect(brain.state == .perched(surfaceID: 1))
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 324, y: 420))
}

@Test func anOutOfReachNeighbourDoesNotTriggerAHop() {
    // 448pt of gap is beyond the 240pt limit, so he stays put even though
    // parkour is set to always fire.
    let farNeighbour = testSurface(2, x: 1100, y: 200, width: 400, height: 300)
    let brain = makeDecisionPoint(
        surfaces: [perchable, farNeighbour], tune: { $0.parkourChance = 1 }
    )
    let effects = brain.handle(.tick, at: 7.1)

    #expect(brain.state == .perched(surfaceID: 1))
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 324, y: 420))
}

@Test func dogScaleNarrowsTheParkourReach() {
    // A 140pt climb is fine at full size but too much for a dog drawn 50%.
    let tallNeighbour = testSurface(2, x: 700, y: 260, width: 400, height: 300) // rise 140
    let full = makeDecisionPoint(
        surfaces: [perchable, tallNeighbour], tune: { $0.parkourChance = 1 }
    )
    #expect(full.handle(.tick, at: 7.1).contains(.hopTo(CGPoint(x: 724, y: 560))))
    #expect(full.state == .hoppingAcross(toID: 2))

    let small = makeDecisionPoint(
        surfaces: [perchable, tallNeighbour], tune: { $0.parkourChance = 1 }
    )
    small.dogScale = 0.5
    let effects = small.handle(.tick, at: 7.1)
    #expect(small.state == .perched(surfaceID: 1))
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 324, y: 420))
}

// MARK: The landing

@Test func landingAParkourHopPerchesOnTheNeighbour() {
    let brain = makeDecisionPoint(
        surfaces: [perchable, parkourNeighbour], tune: { $0.parkourChance = 1 }
    )
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .hoppingAcross(toID: 2))

    brain.position = CGPoint(x: 724, y: 500)
    let effects = brain.handle(.arrived, at: 8)

    #expect(brain.state == .perched(surfaceID: 2))
    #expect(effects.contains(.play(.walk)))
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 1076, y: 500),
            "he patrols the new ledge like any other")
}

@Test func heKeepsParkouringBetweenWindowsWithoutTouchingTheFloor() {
    // Two sequential hops — 1 → 2 and back — never leaving a title bar, which
    // is the ticket's "traverse without returning to the desktop" in miniature.
    let brain = makeDecisionPoint(
        surfaces: [perchable, parkourNeighbour],
        tune: { $0.parkourChance = 1; $0.perchDuration = 100...100 }
    )
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .hoppingAcross(toID: 2))

    brain.position = CGPoint(x: 724, y: 500)
    _ = brain.handle(.arrived, at: 8)
    #expect(brain.state == .perched(surfaceID: 2))

    // Patrol to the far end of window 2, peek, then hop back.
    brain.position = CGPoint(x: 1076, y: 500)
    _ = brain.handle(.arrived, at: 9)
    let back = brain.handle(.tick, at: 10.1)
    #expect(brain.state == .hoppingAcross(toID: 1))
    #expect(hopTarget(in: back) == CGPoint(x: 676, y: 420))

    brain.position = CGPoint(x: 676, y: 420)
    _ = brain.handle(.arrived, at: 11)
    #expect(brain.state == .perched(surfaceID: 1))
}

// MARK: Aborting

@Test func theNeighbourVanishingMidHopDropsHim() {
    let brain = makeDecisionPoint(
        surfaces: [perchable, parkourNeighbour], tune: { $0.parkourChance = 1 }
    )
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .hoppingAcross(toID: 2))

    brain.surfaces = [perchable] // the target closed mid-air
    let effects = brain.handle(.tick, at: 7.5)

    #expect(brain.state == .falling)
    #expect(effects.contains(.stopMoving))
    #expect(fallTarget(in: effects) == 300, "back down to the floor he climbed from")
}

// MARK: The perch nap

@Test func aWideLedgeSendsHimToSleep() {
    let brain = makeDecisionPoint(
        surfaces: [perchable], tune: { $0.perchNapChance = 1; $0.perchNapDuration = 5...5 }
    )
    let effects = brain.handle(.tick, at: 7.1)

    #expect(brain.state == .perchSleeping(surfaceID: 1))
    #expect(effects.contains(.play(.sleep)))
}

@Test func aNarrowLedgeIsNoPlaceToNap() {
    // `perchable` is 400pt wide; a 500pt nap floor turns it into a no-nap ledge.
    let brain = makeDecisionPoint(
        surfaces: [perchable], tune: { $0.perchNapChance = 1; $0.perchNapMinWidth = 500 }
    )
    let effects = brain.handle(.tick, at: 7.1)

    #expect(brain.state == .perched(surfaceID: 1))
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 324, y: 420))
}

@Test func wakingFromANapResumesPatrolling() {
    let brain = makeDecisionPoint(
        surfaces: [perchable], tune: { $0.perchNapChance = 1; $0.perchNapDuration = 5...5 }
    )
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .perchSleeping(surfaceID: 1))
    #expect(brain.handle(.tick, at: 9) == [], "still asleep before the nap ends")

    let effects = brain.handle(.tick, at: 12.2)
    #expect(brain.state == .perched(surfaceID: 1))
    #expect(effects.contains(.play(.walk)))
}

@Test func theWindowClosingUnderANapDropsHim() {
    let brain = makeDecisionPoint(
        surfaces: [perchable], tune: { $0.perchNapChance = 1; $0.perchNapDuration = 5...5 }
    )
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .perchSleeping(surfaceID: 1))

    brain.surfaces = []
    let effects = brain.handle(.tick, at: 8)

    #expect(brain.state == .falling)
    #expect(effects.contains(.play(.fall)))
}

// MARK: Interruptions

@Test func aCommandInterruptsAParkourHop() {
    let brain = makeDecisionPoint(
        surfaces: [perchable, parkourNeighbour], tune: { $0.parkourChance = 1 }
    )
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .hoppingAcross(toID: 2))

    _ = brain.handle(.command(.sit), at: 7.5)
    #expect(brain.state == .sitting)

    brain.surfaces = []
    #expect(brain.handle(.tick, at: 8) == [], "no ghost fall from a hop a command cancelled")
}

@Test func aCommandInterruptsAPerchNap() {
    let brain = makeDecisionPoint(surfaces: [perchable], tune: { $0.perchNapChance = 1 })
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .perchSleeping(surfaceID: 1))

    _ = brain.handle(.command(.sit), at: 8)
    #expect(brain.state == .sitting)

    brain.surfaces = []
    #expect(brain.handle(.tick, at: 9) == [], "no ghost fall from a nap he already left")
}

@Test func pickingHimUpOffANapEndsItCleanly() {
    let brain = makeDecisionPoint(surfaces: [perchable], tune: { $0.perchNapChance = 1 })
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .perchSleeping(surfaceID: 1))

    _ = brain.handle(.pickedUp, at: 8)
    #expect(brain.state == .carried)

    brain.surfaces = []
    #expect(brain.handle(.tick, at: 9) == [])
}

// MARK: Disabling window climbing

@Test func disablingWindowClimbingDropsAPerchNapSafely() {
    let brain = makeDecisionPoint(surfaces: [perchable], tune: { $0.perchNapChance = 1 })
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .perchSleeping(surfaceID: 1))

    brain.windowClimbingEnabled = false
    brain.surfaces = []
    let effects = brain.handle(.tick, at: 8)

    #expect(brain.state == .falling)
    #expect(effects.contains { if case .startFalling = $0 { return true }; return false })
}

@Test func disablingWindowClimbingDropsAParkourHop() {
    let brain = makeDecisionPoint(
        surfaces: [perchable, parkourNeighbour], tune: { $0.parkourChance = 1 }
    )
    _ = brain.handle(.tick, at: 7.1)
    #expect(brain.state == .hoppingAcross(toID: 2))

    brain.windowClimbingEnabled = false
    let effects = brain.handle(.tick, at: 7.5)

    #expect(brain.state == .falling)
    #expect(effects.contains { if case .startFalling = $0 { return true }; return false })
}

// MARK: - A world with holes in it (multi-monitor dead zones)
//
// On a multi-display desk the scene is the BOUNDING BOX of every display, and
// on an uneven arrangement parts of that box are on no display at all. The
// brain does not know what a display is: it is handed `roamableRects`, and
// empty (the default, and every test above) means "all of `bounds`", which is
// why nothing in this file needed changing.

/// 800x600 of `bounds`, of which only an L-shape is real: a full-height left
/// half, and a right half that stops at y = 300. Everything above (400, 300)
/// on the right is a dead zone.
private let lShapedWorld = [
    CGRect(x: 0, y: 0, width: 400, height: 600),
    CGRect(x: 400, y: 0, width: 400, height: 300),
]

private func isSomewhereReal(_ point: CGPoint, _ rects: [CGRect] = lShapedWorld) -> Bool {
    rects.contains {
        point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY
    }
}

@Test func byDefaultTheWholeOfBoundsIsRoamable() {
    let brain = makeBrain()
    #expect(brain.roamableRects.isEmpty, "the single-display default: no holes to avoid")
}

@Test func wanderNeverTargetsADeadZone() {
    for seed in UInt64(1)...40 {
        let brain = makeBrain(seed: seed)
        brain.roamableRects = lShapedWorld
        _ = brain.handle(.tick, at: 0)
        let target = moveTarget(in: brain.handle(.tick, at: 3.1))?.point
        #expect(target != nil, "seed \(seed): wandering still needs somewhere to go")
        if let target {
            #expect(isSomewhereReal(target),
                    "seed \(seed): wander target \(target) is in the dead zone")
        }
    }
}

@Test func wanderStillCoversBothHalvesOfAnLShapedWorld() {
    // Rejection sampling must not quietly collapse him onto one display.
    var onTheRight = 0
    for seed in UInt64(1)...40 {
        let brain = makeBrain(seed: seed)
        brain.roamableRects = lShapedWorld
        _ = brain.handle(.tick, at: 0)
        if let target = moveTarget(in: brain.handle(.tick, at: 3.1))?.point, target.x > 400 {
            onTheRight += 1
        }
    }
    #expect(onTheRight > 0 && onTheRight < 40,
            "he should use the whole L, got \(onTheRight)/40 on the short display")
}

@Test func aWanderTargetIsUnchangedWhenEveryRectIsRoamable() {
    // The fast path must be bit-identical: same seed, same target, whether or
    // not the scene bothered to hand over a (hole-free) set of rectangles.
    for seed in UInt64(1)...8 {
        let plain = makeBrain(seed: seed)
        let described = makeBrain(seed: seed)
        described.roamableRects = [CGRect(x: 0, y: 0, width: 800, height: 600)]
        _ = plain.handle(.tick, at: 0)
        _ = described.handle(.tick, at: 0)
        #expect(moveTarget(in: plain.handle(.tick, at: 3.1))?.point
                == moveTarget(in: described.handle(.tick, at: 3.1))?.point,
                "seed \(seed)")
    }
}

@Test func theVictoryTrotStaysOutOfTheDeadZone() {
    // Standing on the short display, being pulled from the left: the trot away
    // from the pull heads right and up, straight at the hole.
    for seed in UInt64(1)...12 {
        let brain = makeBrain(seed: seed) { $0.tugWinChance = 1.0 }
        brain.roamableRects = lShapedWorld
        brain.position = CGPoint(x: 700, y: 290)
        _ = brain.handle(.tugStarted(at: CGPoint(x: 600, y: 200)), at: 1)
        let effects = brain.handle(.tick, at: 1 + brain.tuning.tugTimeout + 0.1)
        let target = moveTarget(in: effects)?.point
        #expect(target != nil, "seed \(seed): the victory lap needs somewhere to go")
        if let target {
            #expect(isSomewhereReal(target), "seed \(seed): trotted into the void at \(target)")
        }
    }
}

@Test func theBarkNudgeStaysOutOfTheDeadZone() {
    // Two bottom-aligned monitors of *nearly* the same height — 1000 and 980,
    // which is what a pair of "1080p" panels at different scale factors looks
    // like. The 20-point strip above the shorter one is the dead zone, and to
    // a dog standing near the top of it that strip is the nearest edge of the
    // world. A bark towards it would step him straight out of existence.
    let displays = [
        CGRect(x: 0, y: 0, width: 600, height: 1000),
        CGRect(x: 600, y: 0, width: 600, height: 980),
    ]
    let brain = makeBrain { $0.barkAtNothingChance = 1.0 }
    brain.bounds = CGSize(width: 1200, height: 1000)
    brain.roamableRects = displays
    brain.position = CGPoint(x: 900, y: 975)
    _ = brain.handle(.tick, at: 0)

    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .barking)
    let target = moveTarget(in: effects)?.point
    #expect(target != nil, "he still takes a step so he faces what he's barking at")
    if let target {
        #expect(target.y > 975, "the nearest edge really is the top one, got \(target)")
        #expect(isSomewhereReal(target, displays), "nudged into the void at \(target)")
        #expect(target.y == 980, "stopped exactly at the short display's top edge")
    }
}

@Test func aWindowWhoseNearEndHangsInTheDeadZoneIsNotClimbed() {
    // A window straddling the boundary: its left half is over the tall display
    // and its right half is in the void above the short one. Standing at the
    // right-hand end, the end he'd jump to is the one that isn't there.
    let brain = makeBrain { $0.perchChance = 1.0 }
    brain.roamableRects = lShapedWorld
    brain.position = CGPoint(x: 700, y: 250)
    brain.footOffset = 20
    brain.surfaces = [Surface(
        id: 1, rect: CGRect(x: 300, y: 200, width: 480, height: 180), title: "Notes", ownerPID: 900
    )]
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .wandering, "no climbable window, so the roll becomes an ordinary wander")

    // From the other side the same window's left end is over real screen, and
    // up he goes.
    let fromTheLeft = makeBrain { $0.perchChance = 1.0 }
    fromTheLeft.roamableRects = lShapedWorld
    fromTheLeft.position = CGPoint(x: 320, y: 250)
    fromTheLeft.footOffset = 20
    fromTheLeft.surfaces = brain.surfaces
    _ = fromTheLeft.handle(.tick, at: 0)
    _ = fromTheLeft.handle(.tick, at: 3.1)
    #expect(fromTheLeft.state == .headingToSurface(surfaceID: 1))
}

@Test func thePerchApproachStaysOutOfTheDeadZone() {
    // The mirror image of the L: a full-height display on the left and a
    // TOP-aligned short one on the right, so the void is at floor level on the
    // right-hand side. He stands on the left display, low down; the window he
    // fancies is up on the right display, and the patch of floor directly
    // below its near edge does not exist. He must walk to the edge of his own
    // display instead of into the hole.
    let steppedWorld = [
        CGRect(x: 0, y: 0, width: 400, height: 600),
        CGRect(x: 400, y: 300, width: 400, height: 300),
    ]
    let brain = makeBrain { $0.perchChance = 1.0 }
    brain.roamableRects = steppedWorld
    brain.position = CGPoint(x: 380, y: 100)
    brain.footOffset = 20
    brain.surfaces = [Surface(
        id: 1, rect: CGRect(x: 450, y: 200, width: 300, height: 180), title: "Notes", ownerPID: 900
    )]
    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .headingToSurface(surfaceID: 1), "the ledge itself is over a real display")
    let target = moveTarget(in: effects)?.point
    #expect(target != nil)
    if let target {
        #expect(isSomewhereReal(target, steppedWorld),
                "approached the window from the void at \(target)")
        #expect(target == CGPoint(x: 400, y: 100), "stopped at the edge of his own display")
    }
}

// MARK: - Real audio (Alex's kit replaces the synthesized placeholder)

@Test func provokedBarkPicksOneOfTheThreeRealBarks() {
    // Three recorded barks, chosen by the injected RNG so a test can pin it.
    var heard: Set<String> = []
    for seed in UInt64(1)...24 {
        let brain = makeBrain(seed: seed)
        let effects = brain.handle(.provoked(at: CGPoint(x: 400, y: 300)), at: 0)
        let sounds = effects.compactMap { effect -> String? in
            if case .playSound(let name) = effect { return name }
            return nil
        }
        #expect(sounds.count == 1, "exactly one bark sound")
        if let s = sounds.first {
            #expect(["bark1", "bark2", "bark3"].contains(s), "unexpected bark sound \(s)")
            heard.insert(s)
        }
    }
    #expect(heard.count > 1, "the variants should actually vary across seeds, got \(heard)")
}

@Test func theSameSeedAlwaysPicksTheSameBark() {
    let a = makeBrain(seed: 7).handle(.provoked(at: .zero), at: 0)
    let b = makeBrain(seed: 7).handle(.provoked(at: .zero), at: 0)
    #expect(a == b, "bark choice must stay deterministic under a seeded RNG")
}

@Test func barkingAtNothingGrowlsInstead() {
    // He's telling off the Dock or his own reflection — a growl reads better
    // than a friendly borf at an inanimate object.
    let brain = makeBrain { $0.barkAtNothingChance = 1.0 }
    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 3.1)
    #expect(brain.state == .barking)
    #expect(effects.contains(.playSound("growl")))
}

@Test func aFinishedBuildGetsAHappyYip() {
    let brain = makeBrain()
    let effects = brain.handle(.system(.buildFinished), at: 0)
    #expect(effects.contains(.celebrate))
    #expect(effects.contains(.playSound("yip")))
}

@Test func aLowBatteryWhines() {
    let brain = makeBrain()
    let effects = brain.handle(.system(.batteryLow), at: 0)
    #expect(brain.state == .lyingDown)
    #expect(effects.contains(.playSound("whine")))
}

@Test func bracingAgainstTheRopeGrunts() {
    let brain = makeBrain()
    let effects = brain.handle(.tugStarted(at: CGPoint(x: 600, y: 300)), at: 0)
    #expect(brain.state == .tugging)
    #expect(effects.contains(.playSound("grunt")))
}
