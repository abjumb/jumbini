import Foundation
import CoreGraphics
import IOKit.ps

// MARK: - Pure transition logic
//
// Every source boils down to the same shape: sample the machine, decide
// whether the answer differs from last time, emit at most one signal. That
// decision is pure and clock-injected (callers pass `at:` the way DogBrain
// and TrickTrainer do), so it is unit-tested without a Mac underneath.
//
// All four trackers start in the calm state. A first sample that reads
// "alarming" therefore does emit (launching onto an already-hot machine is
// news), while a first calm sample stays quiet (there is nothing to wake up
// from). The brain guards wake signals on its own RestReason anyway, so a
// stray one would be harmless — this just keeps the stream honest.

/// idleBegan once quiet time crosses the threshold, idleEnded on the first
/// sample that drops back under it.
struct IdleTracker {
    /// Quiet seconds that count as "the human has wandered off".
    var threshold: TimeInterval = 120

    private(set) var isIdle = false

    mutating func update(idleSeconds: TimeInterval) -> SystemSignal? {
        let idleNow = idleSeconds >= threshold
        guard idleNow != isIdle else { return nil }
        isIdle = idleNow
        return idleNow ? .idleBegan : .idleEnded
    }
}

/// batteryLow at or under `lowThreshold` while unplugged. Recovery needs
/// either the charger or a climb past `recoveryThreshold` — the gap is the
/// hysteresis that stops a battery parked on 20% from flapping every poll.
struct BatteryTracker {
    var lowThreshold = 20
    var recoveryThreshold = 25

    private(set) var isLow = false

    mutating func update(percent: Int, isPlugged: Bool) -> SystemSignal? {
        if isLow {
            guard isPlugged || percent >= recoveryThreshold else { return nil }
            isLow = false
            return .batteryNormal
        } else {
            guard !isPlugged, percent <= lowThreshold else { return nil }
            isLow = true
            return .batteryLow
        }
    }
}

/// fansUp on the way *into* a hot thermal state. There is no cool-down
/// signal in the vocabulary, so the drop back to nominal only re-arms it.
struct ThermalTracker {
    private(set) var isHot = false

    mutating func update(isHot hotNow: Bool) -> SystemSignal? {
        guard hotNow != isHot else { return nil }
        isHot = hotNow
        return hotNow ? .fansUp : nil
    }
}

/// A build tool that stuck around long enough to be a real build, and then
/// vanished, is a finished build.
///
/// Two filters keep the dog from partying over every incremental compile:
/// the tool must have been continuously present for `minimumDuration`, and
/// two celebrations can never land closer together than `cooldown`.
struct BuildWatcher {
    /// How long a tool must run before its exit counts as "a build".
    var minimumDuration: TimeInterval = 30
    /// Quiet period after a celebration; a rebuild storm gets one party.
    var cooldown: TimeInterval = 60

    private var presentSince: TimeInterval?
    private var lastEmitted: TimeInterval?

    mutating func update(toolsRunning: Bool, at now: TimeInterval) -> SystemSignal? {
        if toolsRunning {
            // First sighting starts the clock; later ones extend the same run.
            if presentSince == nil { presentSince = now }
            return nil
        }
        guard let started = presentSince else { return nil }
        presentSince = nil
        guard now - started >= minimumDuration else { return nil }
        if let last = lastEmitted, now - last < cooldown { return nil }
        lastEmitted = now
        return .buildFinished
    }
}

/// dndOn / dndOff on transitions of an active Focus assertion.
struct DoNotDisturbTracker {
    private(set) var isOn = false

    mutating func update(isActive: Bool) -> SystemSignal? {
        guard isActive != isOn else { return nil }
        isOn = isActive
        return isOn ? .dndOn : .dndOff
    }
}

/// How many times a source may fail before it is switched off for good.
///
/// A source can fail for two very different reasons, and the old
/// one-strike-and-you-are-out rule could not tell them apart: this Mac simply
/// hasn't got the thing (a Mac mini has no battery, Focus is behind TCC), or
/// the read hiccupped once (IOKit busy, a window-server stutter, `pgrep`
/// losing a race with a fork bomb of a build). The first deserves permanent
/// silence; the second deserves another go.
///
/// Three consecutive failures is the compromise. A genuinely missing source
/// costs two extra reads before it latches off — a rounding error at a 5s poll
/// — and a transient one is forgiven. Any success resets the count, so an
/// intermittently flaky source never accumulates its way to being disabled.
struct RetryBudget {
    /// Consecutive failures that latch the source off.
    var strikes = 3

    private(set) var failures = 0
    /// Once true, never false again: the source is gone for this run.
    private(set) var isLatchedOff = false

    var isAvailable: Bool { !isLatchedOff }

    /// - Returns: true if this failure was the one that latched the source off.
    @discardableResult
    mutating func recordFailure() -> Bool {
        guard !isLatchedOff else { return false }
        failures += 1
        guard failures >= strikes else { return false }
        isLatchedOff = true
        return true
    }

    mutating func recordSuccess() {
        failures = 0
    }
}

// MARK: - The monitor

/// Watches the machine and reports the handful of happenings the dog cares
/// about. Ambient only: it never asks for permissions, never blocks, and has
/// no opinion about what the dog does with the news.
///
/// Each source is independent and individually failable. A source that can't
/// work on this machine (no battery, a sandboxed Focus database, a missing
/// `pgrep`) spends its `RetryBudget` and then degrades to permanent silence —
/// it can never crash the app or stop its neighbours from reporting. A source
/// that merely stumbles once gets its next poll as usual.
///
/// `@MainActor`: `start()`, `stop()`, every tracker and every `onSignal` call
/// live on the main actor, so none of the state below needs a lock. The only
/// work that leaves the main actor is the `pgrep` probe, a `nonisolated async`
/// function whose answer lands back here at the `await`.
@MainActor
final class SystemMonitor {
    /// Called on the main actor, once per transition.
    var onSignal: ((SystemSignal) -> Void)?

    /// One loop drives the three polled sources. 5s is fine-grained enough
    /// for a 120s idle threshold and a 30s build, and cheap enough to ignore.
    private static let pollInterval: Duration = .seconds(5)

    /// Build tools worth watching. One `pgrep -x` handles all of them: the
    /// pattern is an extended regex and `-x` anchors it to the whole name.
    private nonisolated static let buildTools = [
        "xcodebuild", "swift-build", "swift-frontend", "cargo", "ninja", "make",
    ]

    /// The one poll loop. Cancelling it is what "stopping" means: work already
    /// in flight sees `Task.isCancelled` at its next suspension point, so a
    /// probe that was mid-flight when the user switched the feature off can no
    /// longer deliver into the next run.
    private var pollTask: Task<Void, Never>?
    private var isRunning = false

    private var idle = IdleTracker()
    private var battery = BatteryTracker()
    private var thermal = ThermalTracker()
    private var build = BuildWatcher()
    private var dnd = DoNotDisturbTracker()

    // Per-source retry budgets. Each latches its source off after three
    // consecutive failures, and never re-arms it for this run.
    private var idleBudget = RetryBudget()
    private var batteryBudget = RetryBudget()
    private var buildBudget = RetryBudget()
    private var dndBudget = RetryBudget()

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Thermal is notification-driven; no polling needed.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        pollThermal()

        // The loop replaces the old Timer: no run-loop mode to get wrong, and
        // an open menu or a window drag can't stall it either. It waits first,
        // exactly like a repeating timer's first fire.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    return // cancelled mid-sleep
                }
                guard let self else { return }
                await self.poll()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        NotificationCenter.default.removeObserver(
            self,
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    deinit {
        pollTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Emission

    /// Everything here is already on the main actor, so this is only the
    /// "are we still running?" gate — a probe that finished after `stop()`
    /// must not deliver.
    private func emit(_ signal: SystemSignal?) {
        guard let signal, isRunning else { return }
        onSignal?(signal)
    }

    // MARK: Polling

    /// The polled sources, each in its own guarded step so a failure in one
    /// cannot skip the others.
    ///
    /// The build probe is awaited rather than fired and forgotten, which is
    /// what retired the old in-flight flag: a slow `pgrep` delays the next
    /// iteration instead of stacking up behind itself.
    private func poll() async {
        let now = Date.timeIntervalSinceReferenceDate
        pollIdle()
        pollBattery()
        await pollBuild(at: now)
        pollDoNotDisturb()
    }

    // MARK: User idle

    private func pollIdle() {
        guard idleBudget.isAvailable else { return }
        guard let seconds = Self.secondsSinceLastUserEvent() else {
            idleBudget.recordFailure()
            return
        }
        idleBudget.recordSuccess()
        emit(idle.update(idleSeconds: seconds))
    }

    /// Seconds since any HID event, across the whole session. nil if
    /// CoreGraphics won't answer (headless session, no window server).
    private static func secondsSinceLastUserEvent() -> TimeInterval? {
        // ~0 is kCGAnyInputEventType: "the last event of any kind".
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInput
        )
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    // MARK: Battery

    private func pollBattery() {
        guard batteryBudget.isAvailable else { return }
        guard let reading = Self.readBattery() else {
            // No internal battery (a Mac mini, a Studio): after three tries,
            // stay quiet forever rather than re-asking IOKit every five seconds.
            batteryBudget.recordFailure()
            return
        }
        batteryBudget.recordSuccess()
        emit(battery.update(percent: reading.percent, isPlugged: reading.isPlugged))
    }

    /// Charge percentage and whether we're on wall power, from the first
    /// power source that reports a sane capacity.
    private static func readBattery() -> (percent: Int, isPlugged: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
                maximum > 0
            else { continue }

            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let isPlugged = state != (kIOPSBatteryPowerValue as String)
            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return (percent, isPlugged)
        }
        return nil
    }

    // MARK: Thermal

    /// The notification can arrive on any thread, so this is `nonisolated` and
    /// hops onto the main actor before touching the tracker.
    @objc private nonisolated func thermalStateChanged() {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.pollThermal()
        }
    }

    /// The closest thing to a fan tachometer that a sandboxed app can read.
    /// Real RPM needs private SMC calls, so "the machine is thermally
    /// stressed" stands in for "the fans spun up".
    private func pollThermal() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        emit(thermal.update(isHot: hot))
    }

    // MARK: Build finished

    private func pollBuild(at now: TimeInterval) async {
        guard buildBudget.isAvailable else { return }
        let result = await Self.probeBuildTools()
        // Back on the main actor, but time has passed: the monitor may have
        // been stopped (and even restarted) while pgrep was running.
        guard isRunning, !Task.isCancelled else { return }
        guard let running = result else {
            // pgrep is missing or unrunnable three times over: give up on it.
            buildBudget.recordFailure()
            return
        }
        buildBudget.recordSuccess()
        emit(build.update(toolsRunning: running, at: now))
    }

    /// true/false if `pgrep` answered, nil if it couldn't be run at all.
    /// Exit status 0 means at least one match, 1 means none; anything else
    /// (or a throw) is a broken source.
    ///
    /// `nonisolated async`, so it runs off the main actor, and it waits on the
    /// termination handler rather than blocking a thread in `waitUntilExit()`.
    private nonisolated static func probeBuildTools() async -> Bool? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", buildTools.joined(separator: "|")]
            // Discard the pid list; the exit status is the whole answer.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                switch finished.terminationStatus {
                case 0: continuation.resume(returning: true)
                case 1: continuation.resume(returning: false)
                default: continuation.resume(returning: nil)
                }
            }
            do {
                try process.run()
            } catch {
                // run() threw, so the termination handler will never fire.
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: Do Not Disturb / Focus

    /// Focus has no public API. This is a best-effort peek at the private
    /// assertions database, which is TCC-protected on modern macOS — without
    /// Full Disk Access the reads fail, the budget runs out and the source
    /// switches itself off for good. That is the expected outcome, not a bug.
    private static let dndAssertionsPath = NSHomeDirectory()
        + "/Library/DoNotDisturb/DB/Assertions.json"

    private func pollDoNotDisturb() {
        guard dndBudget.isAvailable else { return }
        guard let active = Self.readDoNotDisturbAssertion() else {
            dndBudget.recordFailure()
            return
        }
        dndBudget.recordSuccess()
        emit(dnd.update(isActive: active))
    }

    /// true/false if the database was readable, nil if it wasn't.
    /// Shape: { "data": [ { "storeAssertionRecords": [ … ] } ] } — any
    /// record present means a Focus mode is switched on.
    private static func readDoNotDisturbAssertion() -> Bool? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dndAssertionsPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return nil }
        return entries.contains { entry in
            let records = entry["storeAssertionRecords"] as? [Any]
            return !(records ?? []).isEmpty
        }
    }
}
