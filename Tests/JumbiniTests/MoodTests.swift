import Foundation
import Testing
@testable import Jumbini

private func isolatedDefaults() -> (UserDefaults, String) {
    let name = "JumbiniTests.mood.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

// MARK: - Persistence

@Test func aFreshInstallGetsJumbasExistingPersonality() {
    let (defaults, name) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    // Deliberately NOT the JumbiniSettings "everything on" convention: two of
    // these three switches are off in the personality that ships today.
    #expect(MoodSettings.load(from: defaults) == Mood())
    #expect(Mood().activity == .active)
    #expect(Mood().stayDown == false)
    #expect(Mood().roam == .wander)
}

@Test func moodRoundTripsThroughDefaults() {
    let (defaults, name) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let expected = Mood(activity: .sleepy, stayDown: true, roam: .follow)

    MoodSettings.save(expected, to: defaults)

    #expect(MoodSettings.load(from: defaults) == expected)
}

@Test func everyActivityModeSurvivesTheRoundTrip() {
    for mode in ActivityMode.allCases {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MoodSettings.save(Mood(activity: mode), to: defaults)

        #expect(MoodSettings.load(from: defaults).activity == mode)
    }
}

@Test func anUnreadableStoredModeFallsBackToTheDefault() {
    let (defaults, name) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    // A hand-edited or downgraded preferences file must never stop the dog.
    defaults.set("hyperactive", forKey: "mood.activity")
    defaults.set("teleport", forKey: "mood.roam")

    let mood = MoodSettings.load(from: defaults)

    #expect(mood.activity == .active)
    #expect(mood.roam == .wander)
}

// MARK: - Multipliers

@Test func activeIsTheIdentityInEveryColumn() {
    let active = ActivityMode.active
    #expect(active.sleepScale == 1)
    #expect(active.flourishScale == 1)
    #expect(active.zoomiesScale == 1)
    #expect(active.sniffScale == 1)
    #expect(active.idleScale == 1)
    #expect(active.zoomiesDurationScale == 1)
}

@Test func veryActiveIsHyperAndSleepyIsNot() {
    #expect(ActivityMode.veryActive.zoomiesScale > ActivityMode.active.zoomiesScale)
    #expect(ActivityMode.sleepy.zoomiesScale < ActivityMode.active.zoomiesScale)
    #expect(ActivityMode.veryActive.sleepScale < ActivityMode.active.sleepScale)
    #expect(ActivityMode.sleepy.sleepScale > ActivityMode.active.sleepScale)
    // Shorter pauses when hyper, longer when sleepy.
    #expect(ActivityMode.veryActive.idleScale < 1)
    #expect(ActivityMode.sleepy.idleScale > 1)
}

@Test func theShippingBaselineProducesTheDesignedOdds() {
    let tuning = BrainTuning()
    #expect(abs(tuning.zoomiesChance * ActivityMode.veryActive.zoomiesScale - 0.36) < 0.0001)
    #expect(abs(tuning.sleepChance * ActivityMode.veryActive.sleepScale - 0.03) < 0.0001)
    #expect(abs(tuning.zoomiesChance * ActivityMode.sleepy.zoomiesScale - 0.01) < 0.0001)
    #expect(abs(tuning.sleepChance * ActivityMode.sleepy.sleepScale - 0.45) < 0.0001)
}

// MARK: - Menu state

@Test func theMenuChecksExactlyTheChosenActivity() {
    let state = MoodMenuState(mood: Mood(activity: .sleepy))

    #expect(state.activityItems.map(\.title) == ["Very Active", "Active", "Sleepy"])
    #expect(state.activityItems.filter(\.isChecked).map(\.title) == ["Sleepy"])
}

@Test func theTogglesReportTheirOwnState() {
    let off = MoodMenuState(mood: Mood())
    #expect(off.stayDownItem == MoodMenuState.Item(title: "Stay Lying Down", isChecked: false))
    #expect(off.followItem == MoodMenuState.Item(title: "Follow My Cursor", isChecked: false))

    let on = MoodMenuState(mood: Mood(stayDown: true, roam: .follow))
    #expect(on.stayDownItem.isChecked)
    #expect(on.followItem.isChecked)
    // The hold is named apart from the momentary "Lie Down" command above it.
    #expect(on.stayDownItem.title != "Lie Down")
}

@Test func theSubmenuIsCalledMood() {
    #expect(MoodMenuState.submenuTitle == "Mood")
}
