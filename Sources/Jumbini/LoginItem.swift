import Foundation
import ServiceManagement

// MARK: - Pure status logic
//
// macOS owns the answer to "does Jumbini open at login?" — the registration
// lives in the user's login-item database, and System Settings can flip it
// behind the app's back at any time. So Jumbini stores nothing: no
// UserDefaults mirror, no cached Bool. Every read goes back to
// SMAppService.mainApp, which is why Settings shows the truth even after the
// user turned the item off in System Settings and never opened Jumbini again.
//
// The mapping and the toggle decision below are pure and service-injected (the
// way SystemMonitor's trackers are clock-injected), so both are unit-tested
// without a registered app bundle underneath.

/// What macOS reports about Jumbini's own login-item registration.
enum LoginItemStatus: Equatable {
    /// Registered and armed: signing in launches Jumbini.
    case enabled
    /// macOS is not holding a registration for us.
    case notRegistered
    /// Registered, but the user still has to turn it on in System Settings.
    case requiresApproval

    /// Whether macOS is holding a registration for us, approved or not. This is
    /// what the checkbox reflects: `requiresApproval` means we registered
    /// successfully and the remaining step belongs to the user, not to Jumbini.
    var isRegistered: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .notRegistered: return false
        }
    }

    /// `.notFound` is the state of every app that has never registered — it is
    /// what a fresh install reports, not an error, and it is measurably *not*
    /// the same value as `.notRegistered`, which is what an app reports after
    /// it unregisters. Both mean the same thing to a user, so both come in as
    /// `.notRegistered` here.
    ///
    /// The temptation is to read `.notFound` as "macOS cannot manage this copy"
    /// and grey the control out. It cannot be used that way: an unbundled
    /// `swift run` build reports `.notFound` too, so the two are
    /// indistinguishable from the status alone. A copy macOS genuinely will not
    /// register announces itself by throwing from `register()`, and that is
    /// where it gets explained — never by disabling the control on a guess.
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered, .notFound: self = .notRegistered
        // A status this build has never heard of is not something to act on.
        // Reporting "off" leaves the control usable, and a toggle that turns
        // out to be wrong fails loudly through the same inline path as any
        // other refusal.
        @unknown default: self = .notRegistered
        }
    }
}

/// Everything the Settings row needs, derived in one place so the control and
/// its explanation can never disagree about what macOS just said.
struct LoginItemViewState: Equatable {
    var isOn: Bool
    var message: String
    /// A failure is drawn in red; ordinary status text stays secondary.
    var isFailure: Bool
    /// Whether this result asks the user for something — a refusal to explain,
    /// or an approval still owed in System Settings. Broader than `isFailure`
    /// on purpose: pending approval is not a failure and is not drawn in red,
    /// but it is the one calm state a VoiceOver user must still be told about.
    var needsAttention: Bool

    init(status: LoginItemStatus, failure: String? = nil) {
        isOn = status.isRegistered
        if let failure {
            message = failure
            isFailure = true
        } else {
            message = Self.message(for: status)
            isFailure = false
        }
        needsAttention = isFailure || status == .requiresApproval
    }

    private static func message(for status: LoginItemStatus) -> String {
        switch status {
        case .enabled:
            return "Jumbini opens on its own when you sign in to your Mac."
        case .notRegistered:
            return "Jumbini opens only when you open it."
        case .requiresApproval:
            return "Almost there — finish turning Jumbini on in System Settings › "
                + "General › Login Items & Extensions."
        }
    }
}

// MARK: - System boundary

/// The seam over `SMAppService.mainApp`. Only `SystemLoginItemService`
/// implements it in the app; tests supply a fake, because a test binary has no
/// app bundle to register and must not touch the real login-item database.
protocol LoginItemService {
    func currentStatus() -> LoginItemStatus
    func register() throws
    func unregister() throws
    /// Where this copy of Jumbini is running from. It belongs on the same seam
    /// as the registration itself: both are questions about how macOS sees this
    /// bundle, and both have to be answerable by a fake inside a test binary
    /// that is neither registered nor in an Applications folder.
    func isInApplicationsFolder() -> Bool
}

/// macOS's own registration for this app bundle. No helper target, no separate
/// executable: `mainApp` registers Jumbini itself, which is the whole reason
/// this feature needs nothing shipped alongside it.
struct SystemLoginItemService: LoginItemService {
    func currentStatus() -> LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// Both domains count: /Applications and ~/Applications are equally valid
    /// homes, and symlinks are resolved on both sides so a copy reached through
    /// one does not read as living somewhere else.
    func isInApplicationsFolder() -> Bool {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let folders = FileManager.default.urls(
            for: .applicationDirectory,
            in: [.localDomainMask, .userDomainMask]
        )
        return folders.contains { folder in
            bundle.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        }
    }
}

/// Reads and writes the login item, and answers every question with the state
/// macOS reports *after* the write — never with what was asked for. A rejected
/// registration therefore snaps the checkbox back to reality instead of leaving
/// it lying, and nothing else in Jumbini notices either way.
struct LoginItemController {
    private let service: LoginItemService

    init(service: LoginItemService = SystemLoginItemService()) {
        self.service = service
    }

    /// State to show whenever Settings opens. Always a fresh read.
    func currentState() -> LoginItemViewState {
        LoginItemViewState(status: service.currentStatus())
    }

    /// Apply the user's toggle immediately, then report what macOS says now.
    func setEnabled(_ enabled: Bool) -> LoginItemViewState {
        let before = service.currentStatus()
        // Already what was asked for. Some macOS versions accept a redundant
        // register/unregister and some hand back an error for it; not asking is
        // correct on all of them.
        guard enabled != before.isRegistered else {
            return LoginItemViewState(status: before)
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // What macOS threw matters less than what it holds now. A throw on
            // the way to `.requiresApproval` is the case worth getting right:
            // the registration stands, the checkbox is legitimately on, and the
            // only useful thing to say is where to finish the job. Calling that
            // a failure would put a red "couldn't add Jumbini" next to a
            // checked box and bury the one instruction that resolves it.
            //
            // Only when switching *on*, though. Approval guidance handed to
            // someone whose attempt to switch it off just failed would answer a
            // question they did not ask.
            let after = service.currentStatus()
            if enabled, after == .requiresApproval {
                return LoginItemViewState(status: after)
            }
            return LoginItemViewState(
                status: after,
                failure: Self.failureMessage(
                    enabling: enabled,
                    inApplications: service.isInApplicationsFolder(),
                    error: error
                )
            )
        }
        return LoginItemViewState(status: service.currentStatus())
    }

    /// macOS's own wording for these refusals is often just an error number, so
    /// say which direction failed and add the cause that explains many of them
    /// — a copy of Jumbini living somewhere macOS will not manage.
    ///
    /// That advice is only offered to someone who has not already taken it.
    /// There is no error code that names bundle placement as the problem, so
    /// the app's own location is what decides whether relocating is plausible
    /// remediation or a red herring for a user whose copy is already in place.
    private static func failureMessage(
        enabling: Bool,
        inApplications: Bool,
        error: Error
    ) -> String {
        let reason = error.localizedDescription
        guard enabling else {
            return "macOS wouldn't remove Jumbini from your login items: \(reason)"
        }
        let failed = "macOS wouldn't add Jumbini to your login items: \(reason)"
        return inApplications
            ? failed
            : failed + " Jumbini is running from outside your Applications folder, "
                + "which is a common cause."
    }
}
