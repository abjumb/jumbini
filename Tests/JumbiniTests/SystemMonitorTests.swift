import Testing
import Foundation
@testable import Jumbini

// The SystemMonitor class itself talks to CoreGraphics, IOKit and pgrep, so
// it can't be exercised in a test process. Its decisions can: every source
// funnels through a small pure tracker, and those are what these cover.

// MARK: - Retry budget

@Test func aSourceSurvivesTwoFailuresAndLatchesOffOnTheThird() {
    var budget = RetryBudget()
    #expect(!budget.recordFailure())
    #expect(budget.isAvailable)
    #expect(!budget.recordFailure())
    #expect(budget.isAvailable)
    #expect(budget.recordFailure(), "the third strike is the one that latches it off")
    #expect(!budget.isAvailable)
}

@Test func aSuccessForgivesEarlierFailures() {
    var budget = RetryBudget()
    budget.recordFailure()
    budget.recordFailure()
    budget.recordSuccess()
    budget.recordFailure()
    budget.recordFailure()
    #expect(budget.isAvailable, "an intermittent source never accumulates its way off")
}

@Test func latchingOffIsPermanentAndReportedOnlyOnce() {
    var budget = RetryBudget()
    for _ in 0..<3 { budget.recordFailure() }
    #expect(!budget.recordFailure(), "already off; only the transition reports true")
    budget.recordSuccess()
    #expect(!budget.isAvailable, "a late success cannot bring a dead source back")
}

// MARK: - Idle

@Test func idleBeginsOnceQuietTimeCrossesTheThreshold() {
    var tracker = IdleTracker()
    #expect(tracker.update(idleSeconds: 5) == nil)
    #expect(tracker.update(idleSeconds: 119.9) == nil)
    #expect(tracker.update(idleSeconds: 120) == .idleBegan)
}

@Test func idleEndsOnTheFirstSampleBackUnderTheThreshold() {
    var tracker = IdleTracker()
    _ = tracker.update(idleSeconds: 200)
    #expect(tracker.update(idleSeconds: 0.2) == .idleEnded)
}

@Test func stayingIdleDoesNotRepeatTheSignal() {
    var tracker = IdleTracker()
    #expect(tracker.update(idleSeconds: 130) == .idleBegan)
    #expect(tracker.update(idleSeconds: 400) == nil)
    #expect(tracker.update(idleSeconds: 900) == nil)
}

@Test func stayingActiveIsSilentFromTheStart() {
    var tracker = IdleTracker()
    for _ in 0..<10 {
        #expect(tracker.update(idleSeconds: 1) == nil)
    }
}

@Test func launchingIntoAnAlreadyIdleMachineReportsIt() {
    var tracker = IdleTracker()
    #expect(tracker.update(idleSeconds: 3_000) == .idleBegan)
}

// MARK: - Battery

@Test func batteryGoesLowOnlyWhenUnplugged() {
    var tracker = BatteryTracker()
    #expect(tracker.update(percent: 12, isPlugged: true) == nil)
    #expect(tracker.update(percent: 12, isPlugged: false) == .batteryLow)
}

@Test func batteryLowFiresAtExactlyTheThreshold() {
    var tracker = BatteryTracker()
    #expect(tracker.update(percent: 21, isPlugged: false) == nil)
    #expect(tracker.update(percent: 20, isPlugged: false) == .batteryLow)
}

@Test func pluggingInRecoversImmediately() {
    var tracker = BatteryTracker()
    _ = tracker.update(percent: 8, isPlugged: false)
    #expect(tracker.update(percent: 8, isPlugged: true) == .batteryNormal)
}

@Test func hysteresisStopsAFlapAtTheThreshold() {
    var tracker = BatteryTracker()
    #expect(tracker.update(percent: 20, isPlugged: false) == .batteryLow)
    // Wobbling across the low threshold is not a recovery: it takes a real
    // climb to the recovery threshold to get him back on his feet.
    for percent in [21, 20, 22, 19, 23, 24] {
        #expect(tracker.update(percent: percent, isPlugged: false) == nil)
    }
    #expect(tracker.update(percent: 25, isPlugged: false) == .batteryNormal)
}

@Test func batteryDoesNotRepeatEitherSignal() {
    var tracker = BatteryTracker()
    #expect(tracker.update(percent: 5, isPlugged: false) == .batteryLow)
    #expect(tracker.update(percent: 4, isPlugged: false) == nil)
    #expect(tracker.update(percent: 3, isPlugged: false) == nil)
    #expect(tracker.update(percent: 90, isPlugged: true) == .batteryNormal)
    #expect(tracker.update(percent: 95, isPlugged: true) == nil)
}

@Test func aHealthyPluggedInMachineIsSilent() {
    var tracker = BatteryTracker()
    #expect(tracker.update(percent: 100, isPlugged: true) == nil)
    #expect(tracker.update(percent: 60, isPlugged: false) == nil)
}

// MARK: - Thermal

@Test func fansUpOnTheWayIntoAHotState() {
    var tracker = ThermalTracker()
    #expect(tracker.update(isHot: false) == nil)
    #expect(tracker.update(isHot: true) == .fansUp)
}

@Test func stayingHotDoesNotRepeatFansUp() {
    var tracker = ThermalTracker()
    #expect(tracker.update(isHot: true) == .fansUp)
    #expect(tracker.update(isHot: true) == nil)
}

@Test func coolingDownIsSilentButReArmsFansUp() {
    var tracker = ThermalTracker()
    _ = tracker.update(isHot: true)
    #expect(tracker.update(isHot: false) == nil)
    #expect(tracker.update(isHot: true) == .fansUp)
}

// MARK: - Build finished

@Test func aLongBuildThatEndsIsCelebrated() {
    var watcher = BuildWatcher()
    #expect(watcher.update(toolsRunning: true, at: 0) == nil)
    #expect(watcher.update(toolsRunning: true, at: 20) == nil)
    #expect(watcher.update(toolsRunning: false, at: 40) == .buildFinished)
}

@Test func aShortCompileIsIgnored() {
    var watcher = BuildWatcher()
    _ = watcher.update(toolsRunning: true, at: 100)
    #expect(watcher.update(toolsRunning: false, at: 105) == nil)
}

@Test func aFlurryOfShortCompilesNeverFires() {
    var watcher = BuildWatcher()
    var time: TimeInterval = 0
    for _ in 0..<20 {
        _ = watcher.update(toolsRunning: true, at: time)
        #expect(watcher.update(toolsRunning: false, at: time + 5) == nil)
        time += 10
    }
}

@Test func buildDurationIsMeasuredFromTheFirstSighting() {
    var watcher = BuildWatcher()
    // Present across many polls: the run is continuous, not restarted.
    for time in stride(from: 0.0, through: 30.0, by: 5.0) {
        #expect(watcher.update(toolsRunning: true, at: time) == nil)
    }
    #expect(watcher.update(toolsRunning: false, at: 35) == .buildFinished)
}

@Test func backToBackBuildsInsideTheCooldownOnlyGetOneParty() {
    var watcher = BuildWatcher()
    _ = watcher.update(toolsRunning: true, at: 0)
    #expect(watcher.update(toolsRunning: false, at: 40) == .buildFinished)
    // A second full-length build finishing 30s later is still the same storm.
    _ = watcher.update(toolsRunning: true, at: 45)
    #expect(watcher.update(toolsRunning: false, at: 80) == nil)
}

@Test func aBuildAfterTheCooldownCelebratesAgain() {
    var watcher = BuildWatcher()
    _ = watcher.update(toolsRunning: true, at: 0)
    #expect(watcher.update(toolsRunning: false, at: 40) == .buildFinished)
    _ = watcher.update(toolsRunning: true, at: 200)
    #expect(watcher.update(toolsRunning: false, at: 240) == .buildFinished)
}

@Test func anIdleMachineNeverFiresBuildFinished() {
    var watcher = BuildWatcher()
    for time in stride(from: 0.0, through: 500.0, by: 5.0) {
        #expect(watcher.update(toolsRunning: false, at: time) == nil)
    }
}

@Test func aBuildStillRunningStaysQuiet() {
    var watcher = BuildWatcher()
    for time in stride(from: 0.0, through: 600.0, by: 5.0) {
        #expect(watcher.update(toolsRunning: true, at: time) == nil)
    }
}

// MARK: - Do Not Disturb

@Test func doNotDisturbReportsBothEdgesOnce() {
    var tracker = DoNotDisturbTracker()
    #expect(tracker.update(isActive: false) == nil)
    #expect(tracker.update(isActive: true) == .dndOn)
    #expect(tracker.update(isActive: true) == nil)
    #expect(tracker.update(isActive: false) == .dndOff)
    #expect(tracker.update(isActive: false) == nil)
}
