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

/// Identifies one continuous start/stop lifetime. Asynchronous work keeps the
/// token it began with, so stopping or restarting the monitor invalidates
/// every completion and notification already queued for the previous run.
final class MonitorLifecycle {
    private let lock = NSLock()
    private var running = false
    private var currentToken: UInt = 0

    var isRunning: Bool {
        withLock { running }
    }

    var token: UInt {
        withLock { currentToken }
    }

    func start() -> UInt {
        withLock {
            guard !running else { return currentToken }
            currentToken &+= 1
            running = true
            return currentToken
        }
    }

    func stop() {
        withLock {
            guard running else { return }
            running = false
            currentToken &+= 1
        }
    }

    func accepts(_ candidate: UInt) -> Bool {
        withLock { running && candidate == currentToken }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

// MARK: - The monitor

/// Watches the machine and reports the handful of happenings the dog cares
/// about. Ambient only: it never asks for permissions, never blocks, and has
/// no opinion about what the dog does with the news.
///
/// Each source is independent and individually failable. A source that can't
/// work on this machine (no battery, a sandboxed Focus database, a missing
/// `pgrep`) latches itself off and degrades to permanent silence — it can
/// never crash the app or stop its neighbours from reporting.
///
/// Main-thread class: `start()`, `stop()`, and every `onSignal` call happen
/// there. The only work that leaves the main thread is the `pgrep` probe,
/// which hops its answer back before touching any state.
final class SystemMonitor {
    /// Called on the main thread, once per transition.
    var onSignal: ((SystemSignal) -> Void)?

    /// One timer drives the three polled sources. 5s is fine-grained enough
    /// for a 120s idle threshold and a 30s build, and cheap enough to ignore.
    private static let pollInterval: TimeInterval = 5

    /// Build tools worth watching. One `pgrep -x` handles all of them: the
    /// pattern is an extended regex and `-x` anchors it to the whole name.
    private static let buildTools = [
        "xcodebuild", "swift-build", "swift-frontend", "cargo", "ninja", "make",
    ]

    private var timer: Timer?
    private let lifecycle = MonitorLifecycle()

    private var idle = IdleTracker()
    private var battery = BatteryTracker()
    private var thermal = ThermalTracker()
    private var build = BuildWatcher()
    private var dnd = DoNotDisturbTracker()

    // Per-source kill switches. Each flips false the first time its source
    // proves unavailable, and never flips back.
    private var idleAvailable = true
    private var batteryAvailable = true
    private var buildAvailable = true
    private var dndAvailable = true

    /// `pgrep` runs off the main thread; this stops a slow probe from
    /// stacking up behind itself.
    private var buildProbeInFlight = false
    private let buildQueue = DispatchQueue(label: "com.jumbini.systemmonitor.build")

    // MARK: Lifecycle

    func start() {
        guard !lifecycle.isRunning else { return }
        _ = lifecycle.start()

        // Thermal is notification-driven; no polling needed.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        pollThermal()

        // .common mode: an open menu or a window drag must not stall polling.
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard lifecycle.isRunning else { return }
        lifecycle.stop()
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(
            self,
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Emission

    /// Always delivers on the main thread; the background build probe is the
    /// one caller that needs the hop.
    private func emit(_ signal: SystemSignal?, token: UInt? = nil) {
        guard let signal else { return }
        let deliveryToken = token ?? lifecycle.token
        if Thread.isMainThread {
            guard lifecycle.accepts(deliveryToken) else { return }
            onSignal?(signal)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifecycle.accepts(deliveryToken) else { return }
                self.onSignal?(signal)
            }
        }
    }

    // MARK: Polling

    /// The polled sources, each in its own guarded step so a failure in one
    /// cannot skip the others.
    private func poll() {
        let now = Date.timeIntervalSinceReferenceDate
        pollIdle()
        pollBattery()
        pollBuild(at: now)
        pollDoNotDisturb()
    }

    // MARK: User idle

    private func pollIdle() {
        guard idleAvailable, let seconds = Self.secondsSinceLastUserEvent() else { return }
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
        guard batteryAvailable else { return }
        guard let reading = Self.readBattery() else {
            // No internal battery (a Mac mini, a Studio): stay quiet forever
            // rather than re-asking IOKit every five seconds.
            batteryAvailable = false
            return
        }
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

    @objc private func thermalStateChanged() {
        // The notification can arrive on any thread; the tracker lives on main.
        let token = lifecycle.token
        if Thread.isMainThread {
            guard lifecycle.accepts(token) else { return }
            pollThermal(token: token)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifecycle.accepts(token) else { return }
                self.pollThermal(token: token)
            }
        }
    }

    /// The closest thing to a fan tachometer that a sandboxed app can read.
    /// Real RPM needs private SMC calls, so "the machine is thermally
    /// stressed" stands in for "the fans spun up".
    private func pollThermal(token: UInt? = nil) {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        emit(thermal.update(isHot: hot), token: token)
    }

    // MARK: Build finished

    private func pollBuild(at now: TimeInterval) {
        guard buildAvailable, !buildProbeInFlight else { return }
        buildProbeInFlight = true
        let token = lifecycle.token
        buildQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.probeBuildTools()
            DispatchQueue.main.async {
                self.buildProbeInFlight = false
                guard self.lifecycle.accepts(token) else { return }
                guard let running = result else {
                    // pgrep is missing or unrunnable: give up on this source.
                    self.buildAvailable = false
                    return
                }
                self.emit(self.build.update(toolsRunning: running, at: now), token: token)
            }
        }
    }

    /// true/false if `pgrep` answered, nil if it couldn't be run at all.
    /// Exit status 0 means at least one match, 1 means none; anything else
    /// (or a throw) is a broken source.
    private static func probeBuildTools() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", buildTools.joined(separator: "|")]
        // Discard the pid list; the exit status is the whole answer.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        switch process.terminationStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    // MARK: Do Not Disturb / Focus

    /// Focus has no public API. This is a best-effort peek at the private
    /// assertions database, which is TCC-protected on modern macOS — without
    /// Full Disk Access the very first read fails and the source switches
    /// itself off for good. That is the expected outcome, not a bug.
    private static let dndAssertionsPath = NSHomeDirectory()
        + "/Library/DoNotDisturb/DB/Assertions.json"

    private func pollDoNotDisturb() {
        guard dndAvailable else { return }
        guard let active = Self.readDoNotDisturbAssertion() else {
            dndAvailable = false
            return
        }
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
