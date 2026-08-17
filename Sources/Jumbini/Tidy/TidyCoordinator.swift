import Dispatch
import Foundation

enum TidyCoordinatorError: Error, Equatable {
    case folderRequired
    case previewRequired
    case staleBookmark
    case recoveryBlocked(String)

    /// What to put in front of the user. Every one of these is something they
    /// can act on, so none of them is worth an alert — they go in the same
    /// popover the results do.
    var message: String {
        switch self {
        case .folderRequired:
            return "Choose a folder for Jumba to tidy first."
        case .previewRequired:
            return "Take a look at the preview before Jumba moves anything."
        case .staleBookmark:
            return "macOS withdrew access to that folder. Choose it again."
        case .recoveryBlocked(let detail):
            return detail
        }
    }
}

enum TidyNotice: Equatable {
    case completed(moved: Int, skipped: Int, capped: Bool)
    case halted(moved: Int)
    case failed(String)
    case undone(Int)

    /// One line for the status-item popover. Idle passes must not interrupt, so
    /// results are reported as text rather than as an alert.
    var message: String {
        switch self {
        case .completed(let moved, let skipped, let capped):
            let moves = "Jumba moved \(moved) file\(moved == 1 ? "" : "s")"
            let skips = skipped == 0 ? "" : ", left \(skipped) alone"
            let cap = capped ? " He stopped at \(TidySafety.maximumMoves) for safety." : ""
            return moves + skips + "." + cap
        case .halted(let moved):
            return "You came back — Jumba stopped after \(moved) file\(moved == 1 ? "" : "s")."
        case .failed(let message):
            return "Jumba stopped: \(message)"
        case .undone(let count):
            return "Jumba put \(count) file\(count == 1 ? "" : "s") back."
        }
    }
}

/// Whether an idle pass may start, and whether a running one must stop.
///
/// Pure and clock-injected, like the trackers in `SystemMonitor`: idle tidying
/// is the one path where files move with nobody watching, so every reason not to
/// start — switched off, screen locked, displays asleep, the person came back —
/// is decided in a value that can be checked without a Mac underneath.
struct TidyIdleTracker {
    enum Action: Equatable {
        case none
        case schedule(after: TimeInterval)
        case cancelPending
        case startPass
        case haltAtBoundary
    }

    /// The configured idle interval, in seconds, counted from the *user's* last
    /// activity rather than from the signal.
    var threshold: TimeInterval
    var isEnabled = true
    var sessionAvailable = true
    /// Set by `tick` when an idle pass starts and cleared by `passFinished()`.
    /// Only unattended passes are halted by the user coming back — a manual run
    /// is one they asked for while sitting there.
    var isRunningIdlePass = false

    private var dueAt: TimeInterval?
    private var hasFiredThisInterval = false

    init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    mutating func receive(_ signal: SystemSignal, at now: TimeInterval) -> Action {
        switch signal {
        case .idleBegan:
            guard isEnabled, sessionAvailable, !isRunningIdlePass else { return .none }
            hasFiredThisInterval = false
            // `SystemMonitor` reports idle at its own threshold, so only the
            // remainder of the configured interval is left to wait out.
            let remaining = max(0, threshold - SystemMonitor.idleSignalThreshold)
            dueAt = now + remaining
            return .schedule(after: remaining)

        case .idleEnded:
            let wasPending = dueAt != nil
            dueAt = nil
            hasFiredThisInterval = false
            if isRunningIdlePass { return .haltAtBoundary }
            return wasPending ? .cancelPending : .none

        default:
            return .none
        }
    }

    mutating func tick(at now: TimeInterval) -> Action {
        guard isEnabled, sessionAvailable, !isRunningIdlePass,
              !hasFiredThisInterval, let dueAt, now >= dueAt else { return .none }
        self.dueAt = nil
        hasFiredThisInterval = true
        isRunningIdlePass = true
        return .startPass
    }

    /// The screen locked, the session was switched away, or the displays went to
    /// sleep. Nothing may start, and anything running stops at a file boundary.
    mutating func sessionBecameUnavailable(at now: TimeInterval) -> Action {
        sessionAvailable = false
        let wasPending = dueAt != nil
        dueAt = nil
        hasFiredThisInterval = false
        if isRunningIdlePass { return .haltAtBoundary }
        return wasPending ? .cancelPending : .none
    }

    /// Coming back only re-arms the machinery. A pass has to be earned by a
    /// fresh idle interval, never by the screens waking up.
    mutating func sessionBecameAvailable(at now: TimeInterval) -> Action {
        sessionAvailable = true
        dueAt = nil
        hasFiredThisInterval = false
        return .none
    }

    mutating func passFinished() {
        isRunningIdlePass = false
    }
}

/// A halt request the executor can read from its own queue.
///
/// The executor checks this between files, never during one — which is what
/// "stops at a file boundary" means, and why the flag lives behind a lock rather
/// than on the main actor the request comes from.
final class TidyHaltFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() {
        lock.lock()
        defer { lock.unlock() }
        requested = true
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        requested = false
    }

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

/// What the Tidy submenu offers, as data.
///
/// The menu decides real things — whether a pass can start, whether the last one
/// can still be undone, whether the folder grant can be revoked — and none of
/// that needs AppKit to be decided or to be checked.
struct TidyMenuState: Equatable {
    var folderConfigured: Bool
    var undoCount: Int
    var idleEnabled: Bool
    var idleAvailable: Bool
    var isRunning: Bool

    init(
        folderConfigured: Bool,
        undoCount: Int,
        idleEnabled: Bool,
        idleAvailable: Bool,
        isRunning: Bool = false
    ) {
        self.folderConfigured = folderConfigured
        self.undoCount = undoCount
        self.idleEnabled = idleEnabled
        self.idleAvailable = idleAvailable
        self.isRunning = isRunning
    }

    /// A folder Tidy cannot currently reach is not a configured folder: a stale
    /// or revoked grant sends the menu back to offering setup rather than
    /// offering to tidy something it would only fail on.
    init(state: TidyCoordinator.State) {
        self.init(
            folderConfigured: state.folder != nil && state.blockingError == nil,
            undoCount: state.undoCount,
            idleEnabled: state.preferences.idleEnabled,
            idleAvailable: state.idleAvailable,
            isRunning: state.isRunning
        )
    }

    var primaryTitle: String { folderConfigured ? "Tidy Up…" : "Set Up Tidy…" }
    var undoTitle: String {
        undoCount > 0 ? "Undo Last Tidy (\(undoCount))" : "Undo Last Tidy"
    }
    var settingsTitle: String { "Tidy Settings…" }
    var idleTitle: String { "Tidy While Idle" }
    var forgetTitle: String { "Forget Folder…" }

    /// Always available: without a folder the primary item opens the picker.
    var canTidy: Bool { !isRunning }
    var canUndo: Bool { folderConfigured && undoCount > 0 && !isRunning }
    var canForgetFolder: Bool { folderConfigured && !isRunning }
    var canToggleIdle: Bool { idleAvailable && !isRunning }
    var idleIsChecked: Bool { idleEnabled && idleAvailable }
}

@MainActor
final class TidyCoordinator {
    struct State: Equatable {
        var folder: URL?
        var rules: TidyRuleSet
        var preferences: TidyPreferences
        var isRunning: Bool
        var undoCount: Int
        var blockingError: String?

        var needsPreview: Bool { preferences.needsPreview }
        var completedManualPass: Bool { preferences.completedManualPass }
        var idleAvailable: Bool {
            folder != nil
                && blockingError == nil
                && !preferences.needsPreview
                && preferences.completedManualPass
        }
    }

    struct Dependencies: @unchecked Sendable {
        let loadRules: () throws -> TidyRuleSet
        let saveRules: (TidyRuleSet) throws -> Void
        let loadPreferences: () throws -> TidyPreferences
        let savePreferences: (TidyPreferences) throws -> Void
        let saveFolder: (URL) throws -> Void
        let resolveFolder: () throws -> TidyFolderGrant?
        let forgetFolder: () throws -> Void
        let plan: (URL, [TidyRule], Int, Date) throws -> TidyPlan
        let execute: (TidyPlan, Set<UUID>, TidyTrigger, Date, @escaping () -> Bool) throws
            -> TidyPassResult
        let undo: (URL, Date) throws -> TidyUndoResult
        let startAccessing: (URL) -> Bool
        let stopAccessing: (URL) -> Void
        let now: () -> Date
    }

    private enum Block {
        case staleBookmark
        case configuration(String)

        var message: String {
            switch self {
            case .staleBookmark:
                return "The selected folder permission must be renewed."
            case .configuration(let message):
                return message
            }
        }
    }

    private let dependencies: Dependencies
    private let workQueue: DispatchQueue
    private var block: Block?
    private var preview: TidyPlan?
    private var operationInFlight = false
    /// Read by the executor between files, set here when the user comes back or
    /// the session goes away. Internal so a test can request a halt from the
    /// executor's own thread, which is where a real one arrives from.
    let haltFlag = TidyHaltFlag()
    private var idleTracker = TidyIdleTracker(threshold: 600)
    private var idleTimer: Timer?

    private(set) var state: State
    var onStateChange: ((State) -> Void)?
    var onNotice: ((TidyNotice) -> Void)?
    var onSuccessfulMoves: (([TidyCompletedMove]) -> Void)?

    convenience init(
        store: TidyStore,
        planner: TidyPlanner,
        executor: TidyExecutor,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(dependencies: Dependencies(
            loadRules: store.loadRules,
            saveRules: store.saveRules,
            loadPreferences: store.loadPreferences,
            savePreferences: store.savePreferences,
            saveFolder: store.saveFolder,
            resolveFolder: store.resolveFolder,
            forgetFolder: store.forgetFolder,
            plan: { root, rules, recencyMinutes, date in
                try planner.plan(
                    root: root,
                    rules: rules,
                    recencyMinutes: recencyMinutes,
                    now: date
                )
            },
            execute: { plan, selectedIDs, trigger, date, shouldHalt in
                try executor.execute(
                    plan: plan,
                    selectedIDs: selectedIDs,
                    trigger: trigger,
                    now: date,
                    shouldHalt: shouldHalt,
                    didMove: { _ in }
                )
            },
            undo: executor.undoLatest,
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() },
            now: now
        ))
    }

    init(
        dependencies: Dependencies,
        workQueue: DispatchQueue = DispatchQueue(label: "com.jumbini.tidy.coordinator")
    ) {
        self.dependencies = dependencies
        self.workQueue = workQueue

        var rules = TidyRuleSet.defaults
        var preferences = TidyPreferences()
        var folder: URL?
        var initialBlock: Block?

        do {
            rules = try dependencies.loadRules()
        } catch {
            initialBlock = .configuration(String(describing: error))
        }
        do {
            preferences = try dependencies.loadPreferences()
        } catch {
            initialBlock = .configuration(String(describing: error))
        }
        do {
            if let grant = try dependencies.resolveFolder() {
                if grant.isStale {
                    initialBlock = .staleBookmark
                } else {
                    folder = grant.url
                }
            }
        } catch {
            initialBlock = .staleBookmark
        }

        block = initialBlock
        state = State(
            folder: folder,
            rules: rules,
            preferences: preferences,
            isRunning: false,
            undoCount: 0,
            blockingError: initialBlock?.message
        )
        syncIdleTracker()
    }

    // MARK: - Idle triggering

    /// Forwarded from `SystemMonitor` whether or not the dog's own system
    /// reactions are switched on: idle tidying is a separate setting, and it
    /// would be a surprise for turning off emotes to turn off tidying too.
    func receive(_ signal: SystemSignal) {
        apply(idleTracker.receive(signal, at: monotonicNow()))
    }

    /// The screen locked, the session switched away, or the displays slept.
    func sessionBecameUnavailable() {
        apply(idleTracker.sessionBecameUnavailable(at: monotonicNow()))
    }

    func sessionBecameAvailable() {
        apply(idleTracker.sessionBecameAvailable(at: monotonicNow()))
    }

    private func apply(_ action: TidyIdleTracker.Action) {
        switch action {
        case .none:
            break
        case .schedule(let interval):
            scheduleIdleTick(after: interval)
        case .cancelPending:
            cancelIdleTick()
        case .startPass:
            startIdlePass()
        case .haltAtBoundary:
            requestHalt()
        }
    }

    /// Ask a running pass to stop before its next file. Nothing already moved is
    /// rolled back — a halted pass is a complete, undoable short pass — and the
    /// request is cleared when the next pass begins.
    func requestHalt() {
        haltFlag.request()
    }

    private func scheduleIdleTick(after interval: TimeInterval) {
        cancelIdleTick()
        let timer = Timer(timeInterval: max(interval, 0), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.idleTickFired() }
        }
        // `.common` so an open menu or a window drag cannot hold the tick back.
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func cancelIdleTick() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func idleTickFired() {
        idleTimer = nil
        apply(idleTracker.tick(at: monotonicNow()))
    }

    private func startIdlePass() {
        guard state.preferences.idleEnabled, state.idleAvailable, !operationInFlight else {
            idleTracker.passFinished()
            return
        }
        Task { @MainActor in
            defer { self.idleTracker.passFinished() }
            do {
                _ = try await self.runIdle()
            } catch {
                // Already surfaced as a notice by runPass; an idle pass that
                // cannot run simply does not run.
            }
        }
    }

    /// A pass nobody is watching: same plan, same executor, same cap, plus a
    /// halt check between files.
    func runIdle() async throws -> TidyPassResult {
        let root = try requireFolder()
        guard state.preferences.idleEnabled, state.idleAvailable else {
            throw TidyCoordinatorError.previewRequired
        }
        let rules = state.rules.rules
        let recencyMinutes = state.preferences.recencyMinutes
        let date = dependencies.now()
        // Read on the main actor and carried in: the work itself runs off it,
        // and reaching back for a main-actor property from there is exactly
        // what the halt flag's lock exists to avoid.
        let shouldHalt = shouldHalt
        return try await runPass(clearsPreviewGate: false) {
            try await self.performWithAccess(to: root) { dependencies in
                let plan = try dependencies.plan(root, rules, recencyMinutes, date)
                return try dependencies.execute(
                    plan,
                    Set(plan.movable.map(\.id)),
                    .idle,
                    date,
                    shouldHalt
                )
            }
        }
    }

    /// Kept in step with the stored preferences so the tracker never schedules
    /// against an interval the user has since changed.
    private func syncIdleTracker() {
        idleTracker.threshold = TimeInterval(max(state.preferences.idleMinutes, 1) * 60)
        idleTracker.isEnabled = state.preferences.idleEnabled && state.idleAvailable
        if !idleTracker.isEnabled {
            cancelIdleTick()
        }
    }

    private func monotonicNow() -> TimeInterval {
        dependencies.now().timeIntervalSinceReferenceDate
    }

    /// Read from the executor's queue, so it goes through the lock rather than
    /// the main actor.
    private var shouldHalt: @Sendable () -> Bool {
        let flag = haltFlag
        return { flag.isRequested }
    }

    func setFolder(_ url: URL) throws {
        try requireNoOperationInFlight()

        var preferences = state.preferences
        preferences.needsPreview = true
        preferences.idleEnabled = false
        preferences.completedManualPass = false
        try dependencies.savePreferences(preferences)
        preview = nil
        updateState { $0.preferences = preferences }
        syncIdleTracker()

        try dependencies.saveFolder(url)
        if case .staleBookmark? = block {
            block = nil
        }
        updateState {
            $0.folder = url
            $0.undoCount = 0
            $0.blockingError = block?.message
        }
    }

    func forgetFolder() throws {
        try requireNoOperationInFlight()
        try dependencies.forgetFolder()

        preview = nil
        block = nil
        var preferences = state.preferences
        preferences.needsPreview = true
        preferences.idleEnabled = false
        preferences.completedManualPass = false
        updateState {
            $0.folder = nil
            $0.preferences = preferences
            $0.undoCount = 0
            $0.blockingError = nil
        }
        syncIdleTracker()
        try dependencies.savePreferences(preferences)
    }

    func updateRules(_ rules: TidyRuleSet) throws {
        try requireNoOperationInFlight()

        var preferences = state.preferences
        preferences.needsPreview = true
        try dependencies.savePreferences(preferences)
        preview = nil
        updateState { $0.preferences = preferences }

        do {
            try dependencies.saveRules(rules)
        } catch {
            setBlock(.configuration(String(describing: error)))
            throw error
        }
        if case .configuration? = block {
            block = nil
        }
        updateState {
            $0.rules = rules
            $0.blockingError = block?.message
        }
    }

    func updateRecency(minutes: Int) throws {
        try requireNoOperationInFlight()

        var preferences = state.preferences
        preferences.recencyMinutes = max(minutes, 1)
        preferences.needsPreview = true
        try dependencies.savePreferences(preferences)
        preview = nil
        updateState { $0.preferences = preferences }
    }

    /// Idle tidying is a trigger, not a rule, so switching it on does not
    /// reinstate the preview gate — but it cannot be switched on at all until a
    /// reviewed manual pass has succeeded, which is what `idleAvailable` means.
    func updateIdle(enabled: Bool) throws {
        try requireNoOperationInFlight()
        guard !enabled || state.idleAvailable else {
            throw TidyCoordinatorError.previewRequired
        }
        var preferences = state.preferences
        preferences.idleEnabled = enabled
        try dependencies.savePreferences(preferences)
        updateState { $0.preferences = preferences }
        syncIdleTracker()
    }

    func updateIdle(minutes: Int) throws {
        try requireNoOperationInFlight()
        var preferences = state.preferences
        preferences.idleMinutes = max(minutes, 1)
        try dependencies.savePreferences(preferences)
        updateState { $0.preferences = preferences }
        syncIdleTracker()
    }

    func makePreview() async throws -> TidyPlan {
        let root = try requireFolder()
        try beginOperation(isPass: false)
        defer { finishOperation(isPass: false) }

        let rules = state.rules.rules
        let recencyMinutes = state.preferences.recencyMinutes
        let date = dependencies.now()
        do {
            let plan = try await performWithAccess(to: root) { dependencies in
                try dependencies.plan(root, rules, recencyMinutes, date)
            }
            preview = plan
            return plan
        } catch {
            throw handlePlanningError(error)
        }
    }

    func executePreview(selection: Set<UUID>) async throws -> TidyPassResult {
        let root = try requireFolder()
        guard let preview else {
            throw TidyCoordinatorError.previewRequired
        }
        let date = dependencies.now()
        let shouldHalt = shouldHalt
        return try await runPass(clearsPreviewGate: true) {
            try await self.performWithAccess(to: root) { dependencies in
                try dependencies.execute(preview, selection, .manual, date, shouldHalt)
            }
        }
    }

    func runManual() async throws -> TidyPassResult {
        let root = try requireFolder()
        guard !state.preferences.needsPreview else {
            throw TidyCoordinatorError.previewRequired
        }
        let rules = state.rules.rules
        let recencyMinutes = state.preferences.recencyMinutes
        let date = dependencies.now()
        let shouldHalt = shouldHalt
        return try await runPass(clearsPreviewGate: false) {
            try await self.performWithAccess(to: root) { dependencies in
                let plan = try dependencies.plan(root, rules, recencyMinutes, date)
                return try dependencies.execute(
                    plan,
                    Set(plan.movable.map(\.id)),
                    .manual,
                    date,
                    shouldHalt
                )
            }
        }
    }

    func undo() async throws -> TidyUndoResult {
        let root = try requireFolder()
        try beginOperation(isPass: true)
        defer { finishOperation(isPass: true) }

        let date = dependencies.now()
        do {
            let result = try await performWithAccess(to: root) { dependencies in
                try dependencies.undo(root, date)
            }
            updateState { $0.undoCount = 0 }
            onNotice?(.undone(result.restoredCount))
            return result
        } catch {
            let surfaced = handleOperationError(error)
            onNotice?(.failed(String(describing: surfaced)))
            throw surfaced
        }
    }

    private func runPass(
        clearsPreviewGate: Bool,
        operation: () async throws -> TidyPassResult
    ) async throws -> TidyPassResult {
        try beginOperation(isPass: true)
        defer { finishOperation(isPass: true) }
        // A halt request belongs to the pass it interrupted, never to the next.
        haltFlag.clear()

        var passReturned = false
        do {
            let result = try await operation()
            passReturned = true
            if clearsPreviewGate {
                preview = nil
            }
            publish(result)

            var preferences = state.preferences
            if clearsPreviewGate {
                preferences.needsPreview = false
            }
            if result.failures.isEmpty && !result.wasHalted {
                preferences.completedManualPass = true
            }
            let updated = preferences
            try await perform { dependencies in
                try dependencies.savePreferences(updated)
            }
            updateState { $0.preferences = preferences }
            syncIdleTracker()
            return result
        } catch {
            let surfaced: Error
            if passReturned {
                setBlock(.configuration(String(describing: error)))
                surfaced = error
            } else {
                surfaced = handleOperationError(error)
                onNotice?(.failed(String(describing: surfaced)))
            }
            throw surfaced
        }
    }

    private func publish(_ result: TidyPassResult) {
        updateState { $0.undoCount = result.moves.count }
        if !result.moves.isEmpty {
            onSuccessfulMoves?(result.moves)
        }

        if result.wasHalted {
            onNotice?(.halted(moved: result.moves.count))
        } else if !result.failures.isEmpty {
            onNotice?(.failed(result.failures.joined(separator: "\n")))
        } else {
            onNotice?(.completed(
                moved: result.moves.count,
                skipped: result.skipped.count,
                capped: result.didHitCap
            ))
        }
    }

    private func requireFolder() throws -> URL {
        if let block {
            switch block {
            case .staleBookmark:
                throw TidyCoordinatorError.staleBookmark
            case .configuration(let message):
                throw TidyCoordinatorError.recoveryBlocked(message)
            }
        }
        guard let folder = state.folder else {
            throw TidyCoordinatorError.folderRequired
        }
        return folder
    }

    private func requireNoOperationInFlight() throws {
        guard !operationInFlight else {
            throw TidyCoordinatorError.recoveryBlocked("Tidy is already running.")
        }
    }

    private func beginOperation(isPass: Bool) throws {
        try requireNoOperationInFlight()
        operationInFlight = true
        if isPass {
            updateState { $0.isRunning = true }
        }
    }

    private func finishOperation(isPass: Bool) {
        operationInFlight = false
        if isPass {
            updateState { $0.isRunning = false }
        }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (Dependencies) throws -> Value
    ) async throws -> Value {
        let dependencies = dependencies
        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                continuation.resume(with: Result {
                    try operation(dependencies)
                })
            }
        }
    }

    private func performWithAccess<Value: Sendable>(
        to root: URL,
        _ operation: @escaping @Sendable (Dependencies) throws -> Value
    ) async throws -> Value {
        try await perform { dependencies in
            guard dependencies.startAccessing(root) else {
                throw TidyCoordinatorError.staleBookmark
            }
            defer { dependencies.stopAccessing(root) }
            return try operation(dependencies)
        }
    }

    private func handlePlanningError(_ error: Error) -> Error {
        if let coordinatorError = error as? TidyCoordinatorError {
            return handleOperationError(coordinatorError)
        }
        if let planError = error as? TidyPlanError {
            switch planError {
            case .unsafeRoot:
                setBlock(.staleBookmark)
            case .unsafeDestination, .duplicateRuleID:
                setBlock(.configuration(String(describing: planError)))
            case .enumerationFailed:
                break
            }
        }
        return error
    }

    private func handleOperationError(_ error: Error) -> Error {
        if let coordinatorError = error as? TidyCoordinatorError {
            if coordinatorError == .staleBookmark {
                preview = nil
                setBlock(.staleBookmark)
                updateState { $0.folder = nil }
            }
            return coordinatorError
        }
        if error is TidyRecoveryError {
            let message = String(describing: error)
            setBlock(.configuration(message))
            return TidyCoordinatorError.recoveryBlocked(message)
        }
        return error
    }

    private func setBlock(_ block: Block?) {
        self.block = block
        updateState { $0.blockingError = block?.message }
    }

    private func updateState(_ update: (inout State) -> Void) {
        var next = state
        update(&next)
        guard next != state else { return }
        state = next
        onStateChange?(next)
    }
}
