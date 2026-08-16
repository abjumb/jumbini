import Foundation
import ServiceManagement
import Testing
@testable import Jumbini

/// Stands in for `SMAppService.mainApp`. A test binary is not an app bundle and
/// has nothing to register, so the real service is never touched here.
private final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus
    /// What macOS reports after a *successful* register, when that is not the
    /// obvious answer — approval-gated registration, mostly.
    var statusAfterRegister: LoginItemStatus?
    /// What macOS reports after a register that *threw*. macOS can take the
    /// registration and still hand back an error.
    var statusAfterFailedRegister: LoginItemStatus?
    var registerError: Error?
    var unregisterError: Error?
    var inApplications = true
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: LoginItemStatus) {
        self.status = status
    }

    func currentStatus() -> LoginItemStatus { status }

    func register() throws {
        registerCalls += 1
        if let registerError {
            if let statusAfterFailedRegister { status = statusAfterFailedRegister }
            throw registerError
        }
        status = statusAfterRegister ?? .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func isInApplicationsFolder() -> Bool { inApplications }
}

private struct RefusedByMacOS: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

// MARK: - Status mapping

@Test func loginItemStatusMirrorsEverySMAppServiceStatus() {
    #expect(LoginItemStatus(.enabled) == .enabled)
    #expect(LoginItemStatus(.notRegistered) == .notRegistered)
    #expect(LoginItemStatus(.requiresApproval) == .requiresApproval)
}

/// The one that matters: `.notFound` is what a never-registered app reports,
/// so reading it as anything but "off, and switchable" would ship a control
/// that no new user could ever turn on.
@Test func loginItemTreatsNeverRegisteredAsSimplyOff() {
    #expect(LoginItemStatus(.notFound) == .notRegistered)
    #expect(!LoginItemViewState(status: LoginItemStatus(.notFound)).isOn)
}

@Test func loginItemCountsAnApprovalPendingItemAsRegistered() {
    #expect(LoginItemStatus.enabled.isRegistered)
    #expect(LoginItemStatus.requiresApproval.isRegistered)
    #expect(!LoginItemStatus.notRegistered.isRegistered)
}

// MARK: - Status to view state

@Test func loginItemViewStateFollowsRegistration() {
    #expect(LoginItemViewState(status: .enabled).isOn)
    #expect(!LoginItemViewState(status: .notRegistered).isOn)
    #expect(LoginItemViewState(status: .requiresApproval).isOn)
}

@Test func loginItemExplainsEveryStatusWithoutCallingItAFailure() {
    for status: LoginItemStatus in [.enabled, .notRegistered, .requiresApproval] {
        let state = LoginItemViewState(status: status)
        #expect(!state.message.isEmpty)
        #expect(!state.isFailure)
    }
}

@Test func loginItemPointsAtSystemSettingsWhenApprovalIsPending() {
    #expect(LoginItemViewState(status: .requiresApproval).message.contains("System Settings"))
}

@Test func loginItemFailureReplacesTheStatusTextAndTurnsRed() {
    let state = LoginItemViewState(status: .notRegistered, failure: "Operation not permitted")

    #expect(state.isFailure)
    #expect(state.message.contains("Operation not permitted"))
    // The control still tells the truth about macOS, not about the attempt.
    #expect(!state.isOn)
}

// MARK: - Toggling

@Test func loginItemEnablingRegistersTheApp() {
    let service = FakeLoginItemService(status: .notRegistered)
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(true)

    #expect(service.registerCalls == 1)
    #expect(service.unregisterCalls == 0)
    #expect(state == LoginItemViewState(status: .enabled))
}

@Test func loginItemDisablingUnregistersTheApp() {
    let service = FakeLoginItemService(status: .enabled)
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(false)

    #expect(service.unregisterCalls == 1)
    #expect(service.registerCalls == 0)
    #expect(state == LoginItemViewState(status: .notRegistered))
}

@Test func loginItemDisablingAlsoClearsAnApprovalPendingRegistration() {
    let service = FakeLoginItemService(status: .requiresApproval)
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(false)

    #expect(service.unregisterCalls == 1)
    #expect(state == LoginItemViewState(status: .notRegistered))
}

@Test func loginItemRegistrationCanLandOnApprovalPending() {
    let service = FakeLoginItemService(status: .notRegistered)
    service.statusAfterRegister = .requiresApproval
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(true)

    #expect(state.isOn)
    #expect(!state.isFailure)
    #expect(state.message.contains("System Settings"))
}

@Test func loginItemDoesNotReRegisterWhatMacOSAlreadyHolds() {
    let service = FakeLoginItemService(status: .enabled)
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(true)

    #expect(service.registerCalls == 0)
    #expect(service.unregisterCalls == 0)
    #expect(state == LoginItemViewState(status: .enabled))
}

@Test func loginItemDoesNotUnregisterWhatWasNeverRegistered() {
    let service = FakeLoginItemService(status: .notRegistered)
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(false)

    #expect(service.unregisterCalls == 0)
    #expect(state == LoginItemViewState(status: .notRegistered))
}

@Test func loginItemFailedRegistrationFallsBackToTheRealSystemState() {
    let service = FakeLoginItemService(status: .notRegistered)
    service.registerError = RefusedByMacOS()
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(true)

    #expect(service.registerCalls == 1)
    #expect(!state.isOn)
    #expect(state.isFailure)
    #expect(state.needsAttention)
    #expect(state.message.contains("Operation not permitted"))
}

/// macOS can keep the registration and still throw. The checkbox is then
/// legitimately on, so the message has to be the one instruction that finishes
/// the job — not a claim that adding Jumbini failed, and not advice to move it.
@Test func loginItemRegistrationThatThrewButHeldSendsUserToSystemSettings() {
    let service = FakeLoginItemService(status: .notRegistered)
    service.registerError = RefusedByMacOS()
    service.statusAfterFailedRegister = .requiresApproval
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(true)

    #expect(service.registerCalls == 1)
    #expect(state.isOn)
    #expect(state.message.contains("System Settings"))
    #expect(!state.message.contains("Applications folder"))
    #expect(!state.isFailure)
    // Not red, but still the user's move to make.
    #expect(state.needsAttention)
}

/// The mirror of the case above, which must not borrow its wording: a failed
/// *unregister* leaves the item pending approval too, and "finish turning
/// Jumbini on" answers a question this user did not ask.
@Test func loginItemFailedUnregistrationDoesNotOfferApprovalGuidance() {
    let service = FakeLoginItemService(status: .requiresApproval)
    service.unregisterError = RefusedByMacOS()
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(false)

    #expect(service.unregisterCalls == 1)
    #expect(state.isOn)
    #expect(state.isFailure)
    #expect(state.message.contains("remove"))
    #expect(!state.message.contains("System Settings"))
}

@Test func loginItemOffersRelocationOnlyToACopyOutsideApplications() {
    let outside = FakeLoginItemService(status: .notRegistered)
    outside.registerError = RefusedByMacOS()
    outside.inApplications = false

    let inside = FakeLoginItemService(status: .notRegistered)
    inside.registerError = RefusedByMacOS()
    inside.inApplications = true

    #expect(
        LoginItemController(service: outside).setEnabled(true)
            .message.contains("Applications folder")
    )
    #expect(
        !LoginItemController(service: inside).setEnabled(true)
            .message.contains("Applications folder")
    )
}

@Test func loginItemAsksForNoAttentionOnAnOrdinaryResult() {
    #expect(!LoginItemViewState(status: .enabled).needsAttention)
    #expect(!LoginItemViewState(status: .notRegistered).needsAttention)
    #expect(LoginItemViewState(status: .requiresApproval).needsAttention)
}

@Test func loginItemFailedUnregistrationLeavesTheControlOn() {
    let service = FakeLoginItemService(status: .enabled)
    service.unregisterError = RefusedByMacOS()
    let controller = LoginItemController(service: service)

    let state = controller.setEnabled(false)

    #expect(service.unregisterCalls == 1)
    #expect(state.isOn)
    #expect(state.isFailure)
    #expect(state.needsAttention)
    #expect(state.message.contains("remove"))
    // Relocation is remediation for registering, never for unregistering.
    #expect(!state.message.contains("Applications folder"))
}

@Test func loginItemCurrentStateReadsTheServiceEveryTime() {
    let service = FakeLoginItemService(status: .notRegistered)
    let controller = LoginItemController(service: service)
    #expect(!controller.currentState().isOn)

    // Something outside Jumbini — System Settings, say — flips the item.
    service.status = .enabled

    #expect(controller.currentState().isOn)
}
