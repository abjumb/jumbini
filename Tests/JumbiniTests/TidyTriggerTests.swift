import Foundation
import Testing
@testable import Jumbini

// When an idle pass may start, and when it must stop.
//
// Idle tidying is the one path where files move without anybody watching, so
// every reason not to start — the switch is off, the screen is locked, the
// displays are asleep, the person came back — is decided here, in a pure value,
// rather than inside a timer callback nobody can test.

@Suite struct TidyTriggerTests {
    @Test func idleTidyingIsOffUntilItIsSwitchedOn() {
        var tracker = TidyIdleTracker(threshold: 600)
        tracker.isEnabled = false

        #expect(tracker.receive(.idleBegan, at: 0) == TidyIdleTracker.Action.none)
        #expect(tracker.tick(at: 700) == TidyIdleTracker.Action.none)
    }

    @Test func lockedSessionNeverFiresIdlePass() {
        var tracker = TidyIdleTracker(threshold: 600)
        tracker.sessionAvailable = false

        #expect(tracker.receive(.idleBegan, at: 0) == TidyIdleTracker.Action.none)
        #expect(tracker.tick(at: 700) == TidyIdleTracker.Action.none)
    }

    /// `SystemMonitor` already reports idle at its own two-minute threshold, so
    /// only the rest of the configured interval is waited out — waiting the full
    /// ten minutes from the signal would make a ten-minute setting twelve.
    @Test func schedulingWaitsOnlyTheRemainderOfTheConfiguredInterval() {
        var tracker = TidyIdleTracker(threshold: 600)

        #expect(tracker.receive(.idleBegan, at: 0)
            == .schedule(after: 600 - SystemMonitor.idleSignalThreshold))
    }

    @Test func aShortIntervalNeverSchedulesNegativeTime() {
        var tracker = TidyIdleTracker(threshold: 60)

        #expect(tracker.receive(.idleBegan, at: 0) == .schedule(after: 0))
    }

    @Test func theTickBeforeTheThresholdDoesNothingAndTheOneAfterStartsAPass() {
        var tracker = TidyIdleTracker(threshold: 600)
        _ = tracker.receive(.idleBegan, at: 0)

        #expect(tracker.tick(at: 300) == TidyIdleTracker.Action.none)
        #expect(tracker.tick(at: 480) == .startPass)
    }

    @Test func oneIdleIntervalFiresExactlyOnce() {
        var tracker = TidyIdleTracker(threshold: 600)
        _ = tracker.receive(.idleBegan, at: 0)
        #expect(tracker.tick(at: 480) == .startPass)

        #expect(tracker.tick(at: 900) == TidyIdleTracker.Action.none)
        #expect(tracker.tick(at: 5_000) == TidyIdleTracker.Action.none)
    }

    @Test func comingBackEarlyCancelsTheWaitingPass() {
        var tracker = TidyIdleTracker(threshold: 600)
        _ = tracker.receive(.idleBegan, at: 0)

        #expect(tracker.receive(.idleEnded, at: 200) == .cancelPending)
        #expect(tracker.tick(at: 700) == TidyIdleTracker.Action.none)
    }

    @Test func returningDuringRunRequestsBoundaryHalt() {
        var tracker = TidyIdleTracker(threshold: 600)
        tracker.isRunningIdlePass = true

        #expect(tracker.receive(.idleEnded, at: 700) == .haltAtBoundary)
    }

    @Test func wanderingOffAgainEarnsAFreshInterval() {
        var tracker = TidyIdleTracker(threshold: 600)
        _ = tracker.receive(.idleBegan, at: 0)
        #expect(tracker.tick(at: 480) == .startPass)
        tracker.passFinished()
        _ = tracker.receive(.idleEnded, at: 500)

        #expect(tracker.receive(.idleBegan, at: 1_000)
            == .schedule(after: 600 - SystemMonitor.idleSignalThreshold))
        #expect(tracker.tick(at: 1_480) == .startPass)
    }

    @Test func lockingTheScreenCancelsAWaitingPass() {
        var tracker = TidyIdleTracker(threshold: 600)
        _ = tracker.receive(.idleBegan, at: 0)

        #expect(tracker.sessionBecameUnavailable(at: 100) == .cancelPending)
        #expect(tracker.tick(at: 700) == TidyIdleTracker.Action.none)
    }

    @Test func lockingTheScreenDuringAPassStopsItAtAFileBoundary() {
        var tracker = TidyIdleTracker(threshold: 600)
        _ = tracker.receive(.idleBegan, at: 0)
        tracker.isRunningIdlePass = true

        #expect(tracker.sessionBecameUnavailable(at: 100) == .haltAtBoundary)
    }

    /// Waking up re-arms the machinery and nothing more. A pass that started
    /// itself the moment the screens came back would be a pass running while
    /// somebody is sitting down at the Mac.
    @Test func wakingUpNeverStartsAPassByItself() {
        var tracker = TidyIdleTracker(threshold: 600)
        _ = tracker.receive(.idleBegan, at: 0)
        _ = tracker.sessionBecameUnavailable(at: 100)

        #expect(tracker.sessionBecameAvailable(at: 200) == TidyIdleTracker.Action.none)
        #expect(tracker.tick(at: 900) == TidyIdleTracker.Action.none)
        #expect(tracker.receive(.idleBegan, at: 1_000)
            == .schedule(after: 600 - SystemMonitor.idleSignalThreshold))
    }

    @Test func signalsTidyDoesNotCareAboutAreIgnored() {
        var tracker = TidyIdleTracker(threshold: 600)

        #expect(tracker.receive(.buildFinished, at: 10) == TidyIdleTracker.Action.none)
        #expect(tracker.receive(.batteryLow, at: 20) == TidyIdleTracker.Action.none)
    }

    @Test func aFinishedPassClearsTheRunningFlag() {
        var tracker = TidyIdleTracker(threshold: 600)
        _ = tracker.receive(.idleBegan, at: 0)
        #expect(tracker.tick(at: 480) == .startPass)
        #expect(tracker.isRunningIdlePass)

        tracker.passFinished()

        #expect(tracker.isRunningIdlePass == false)
    }
}
