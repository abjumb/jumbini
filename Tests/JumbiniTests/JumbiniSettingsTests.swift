import Foundation
import Testing
@testable import Jumbini

private func isolatedDefaults() -> (UserDefaults, String) {
    let name = "JumbiniTests.settings.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

@Test func newSettingsKeepEveryExistingFeatureEnabled() {
    let (defaults, name) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    #expect(JumbiniSettings(defaults: defaults) == JumbiniSettings())
}

@Test func settingsRoundTripEveryFeatureChoice() {
    let (defaults, name) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let expected = JumbiniSettings(
        poopEnabled: false,
        systemReactionsEnabled: true,
        windowClimbingEnabled: false
    )

    expected.save(to: defaults)

    #expect(JumbiniSettings(defaults: defaults) == expected)
}

@Test func appDelegateLoadsPersistedSettingsForLaunch() {
    let (defaults, name) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let expected = JumbiniSettings(
        poopEnabled: false,
        systemReactionsEnabled: false,
        windowClimbingEnabled: false
    )
    expected.save(to: defaults)

    let delegate = AppDelegate(defaults: defaults)

    #expect(delegate.settings == expected)
}
