import Testing
import Foundation
@testable import Jumbini

/// Fresh trainer over an in-memory store; the store is returned too so tests
/// can hand it to a second trainer for persistence round-trips.
private func makeTrainer(
    store: InMemoryTrickStore = InMemoryTrickStore()
) -> (trainer: TrickTrainer, store: InMemoryTrickStore) {
    (TrickTrainer(store: store), store)
}

/// One full rep: attempt immediately rewarded by a treat.
private func rep(_ trainer: TrickTrainer, _ trick: Trick, at time: TimeInterval) -> Trick? {
    trainer.recordAttempt(trick, at: time)
    return trainer.recordTreat(at: time + 1)
}

// MARK: - Defaults

@Test func allTricksStartLockedWithZeroProgress() {
    let (trainer, _) = makeTrainer()
    for trick in Trick.allCases {
        #expect(!trainer.isUnlocked(trick), "\(trick) must start locked")
        let progress = trainer.progress(trick)
        #expect(progress.reps == 0)
        #expect(progress.needed == 3)
    }
}

// MARK: - Rep counting

@Test func attemptThenTreatWithinWindowCountsARep() {
    let (trainer, _) = makeTrainer()
    trainer.recordAttempt(.shake, at: 100)
    #expect(trainer.recordTreat(at: 105) == .shake)
    #expect(trainer.progress(.shake).reps == 1)
    #expect(!trainer.isUnlocked(.shake), "one rep is not enough to unlock")
}

@Test func treatAtExactWindowBoundaryStillCounts() {
    let (trainer, _) = makeTrainer()
    trainer.recordAttempt(.shake, at: 100)
    #expect(trainer.recordTreat(at: 110) == .shake, "the 10s window is inclusive")
    #expect(trainer.progress(.shake).reps == 1)
}

@Test func treatOutsideWindowDoesNotCount() {
    let (trainer, _) = makeTrainer()
    trainer.recordAttempt(.shake, at: 100)
    #expect(trainer.recordTreat(at: 110.1) == nil)
    #expect(trainer.progress(.shake).reps == 0)
}

@Test func treatBeforeAnyAttemptDoesNotCount() {
    let (trainer, _) = makeTrainer()
    #expect(trainer.recordTreat(at: 5) == nil)
    for trick in Trick.allCases {
        #expect(trainer.progress(trick).reps == 0)
    }
}

@Test func doubleTreatAfterOneAttemptCountsOnce() {
    let (trainer, _) = makeTrainer()
    trainer.recordAttempt(.highFive, at: 0)
    #expect(trainer.recordTreat(at: 1) == .highFive)
    #expect(trainer.recordTreat(at: 2) == nil, "the attempt was already rewarded")
    #expect(trainer.progress(.highFive).reps == 1)
}

@Test func treatRewardsMostRecentUnrewardedAttempt() {
    let (trainer, _) = makeTrainer()
    trainer.recordAttempt(.shake, at: 0)
    trainer.recordAttempt(.highFive, at: 5)
    #expect(trainer.recordTreat(at: 6) == .highFive, "most recent attempt wins")
    // The older attempt is still un-rewarded and still inside its window.
    #expect(trainer.recordTreat(at: 7) == .shake)
    #expect(trainer.progress(.highFive).reps == 1)
    #expect(trainer.progress(.shake).reps == 1)
}

@Test func repeatedAttemptsEachNeedTheirOwnTreat() {
    let (trainer, _) = makeTrainer()
    trainer.recordAttempt(.rollOver, at: 0)
    trainer.recordAttempt(.rollOver, at: 2)
    #expect(trainer.recordTreat(at: 3) == .rollOver)
    #expect(trainer.progress(.rollOver).reps == 1, "one treat = one rep, however many attempts")
    #expect(trainer.recordTreat(at: 4) == .rollOver, "second treat rewards the earlier attempt")
    #expect(trainer.progress(.rollOver).reps == 2)
}

// MARK: - Unlocking

@Test func trickUnlocksAtExactlyThreeReps() {
    let (trainer, _) = makeTrainer()
    #expect(rep(trainer, .playDead, at: 0) == .playDead)
    #expect(rep(trainer, .playDead, at: 20) == .playDead)
    #expect(!trainer.isUnlocked(.playDead), "two reps must not unlock")

    #expect(rep(trainer, .playDead, at: 40) == .playDead)
    #expect(trainer.isUnlocked(.playDead))
    #expect(trainer.progress(.playDead).reps == 3)
}

@Test func unlockingOneTrickLeavesOthersLocked() {
    let (trainer, _) = makeTrainer()
    for t in stride(from: 0.0, through: 40, by: 20) {
        _ = rep(trainer, .shake, at: t)
    }
    #expect(trainer.isUnlocked(.shake))
    for trick in Trick.allCases where trick != .shake {
        #expect(!trainer.isUnlocked(trick))
        #expect(trainer.progress(trick).reps == 0)
    }
}

@Test func attemptsOnUnlockedTrickDoNotAccumulate() {
    let (trainer, _) = makeTrainer()
    for t in stride(from: 0.0, through: 40, by: 20) {
        _ = rep(trainer, .shake, at: t)
    }
    #expect(trainer.isUnlocked(.shake))

    trainer.recordAttempt(.shake, at: 60)
    #expect(trainer.recordTreat(at: 61) == nil, "performing an unlocked trick is not training")
    #expect(trainer.progress(.shake).reps == 3)
}

@Test func pendingAttemptsOfATrickAreDroppedWhenItUnlocks() {
    let (trainer, _) = makeTrainer()
    _ = rep(trainer, .shake, at: 0)
    _ = rep(trainer, .shake, at: 20)
    // Two quick attempts, then the treat that lands rep #3 and unlocks.
    trainer.recordAttempt(.shake, at: 40)
    trainer.recordAttempt(.shake, at: 41)
    #expect(trainer.recordTreat(at: 42) == .shake)
    #expect(trainer.isUnlocked(.shake))
    #expect(trainer.recordTreat(at: 43) == nil, "leftover attempts die with the unlock")
    #expect(trainer.progress(.shake).reps == 3, "reps never pass the requirement")
}

// MARK: - Persistence

@Test func progressAndUnlockSurviveANewTrainerOnTheSameStore() {
    let store = InMemoryTrickStore()
    let (first, _) = makeTrainer(store: store)
    for t in stride(from: 0.0, through: 40, by: 20) {
        _ = rep(first, .highFive, at: t)
    }
    _ = rep(first, .rollOver, at: 60)

    let (second, _) = makeTrainer(store: store)
    #expect(second.isUnlocked(.highFive), "unlock persists across launches")
    #expect(second.progress(.highFive).reps == 3)
    #expect(!second.isUnlocked(.rollOver))
    #expect(second.progress(.rollOver).reps == 1, "partial progress persists too")
    #expect(!second.isUnlocked(.shake))
}

@Test func pendingAttemptsAreNotPersisted() {
    let store = InMemoryTrickStore()
    let (first, _) = makeTrainer(store: store)
    first.recordAttempt(.shake, at: 0)

    let (second, _) = makeTrainer(store: store)
    #expect(second.recordTreat(at: 1) == nil, "an un-rewarded attempt is session-local")
    #expect(second.progress(.shake).reps == 0)
}

@Test func storeKeysAreNamespacedPerTrick() {
    let store = InMemoryTrickStore()
    let (trainer, _) = makeTrainer(store: store)
    for t in stride(from: 0.0, through: 40, by: 20) {
        _ = rep(trainer, .shake, at: t)
    }
    #expect(store.values["trick.shake.reps"] == 3)
    #expect(store.values["trick.shake.unlocked"] == 1)
}
