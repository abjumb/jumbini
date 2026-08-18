import Foundation

/// How much energy Jumba has, as multipliers over `BrainTuning`.
///
/// `.active` is the identity in every column. That is the point: an existing
/// install, a default launch, and every test written before moods existed all
/// take arithmetic that is bit-for-bit what it always was.
enum ActivityMode: String, CaseIterable, Equatable {
    case veryActive, active, sleepy

    /// Multiplier on `BrainTuning.sleepChance`.
    var sleepScale: Double {
        switch self {
        case .veryActive: 0.2
        case .active: 1
        case .sleepy: 3
        }
    }

    /// Multiplier on `BrainTuning.flourishChance` (the idle spin).
    var flourishScale: Double {
        switch self {
        case .veryActive: 1.5
        case .active: 1
        case .sleepy: 0.5
        }
    }

    /// Multiplier on `BrainTuning.zoomiesChance`. Very Active is defined by
    /// this number: 8% becomes 36%, which is what "a lot of zoomies" means.
    var zoomiesScale: Double {
        switch self {
        case .veryActive: 4.5
        case .active: 1
        case .sleepy: 0.125
        }
    }

    /// Multiplier on `BrainTuning.sniffChance` (the cursor hunt).
    var sniffScale: Double {
        switch self {
        case .veryActive: 1.5
        case .active: 1
        case .sleepy: 0.5
        }
    }

    /// Multiplier on the pause between activities. Below 1 means he gets bored
    /// sooner and therefore does more things per minute.
    var idleScale: Double {
        switch self {
        case .veryActive: 0.5
        case .active: 1
        case .sleepy: 2
        }
    }

    /// Multiplier on how long a zoomies burst lasts, wherever it started —
    /// the autonomous roll, the hot-fans reaction, or the explicit command.
    var zoomiesDurationScale: Double {
        switch self {
        case .veryActive: 1.5
        case .active: 1
        case .sleepy: 1
        }
    }

    var menuTitle: String {
        switch self {
        case .veryActive: "Very Active"
        case .active: "Active"
        case .sleepy: "Sleepy"
        }
    }
}

/// What an ordinary walk aims at: a random spot, or your cursor.
enum RoamMode: String, Equatable {
    case wander, follow
}

/// The three persistent switches from Jumba's right-click menu.
///
/// Deliberately NOT part of `JumbiniSettings`, and not for tidiness:
/// `SettingsPanel.featureChanged()` builds a fresh `JumbiniSettings` out of its
/// three checkboxes, so a mood field living there would be reset to its default
/// every time somebody toggled any Settings checkbox. Separate structs with
/// separate owners make that bug impossible instead of merely avoided.
struct Mood: Equatable {
    var activity: ActivityMode
    var stayDown: Bool
    var roam: RoamMode

    init(
        activity: ActivityMode = .active,
        stayDown: Bool = false,
        roam: RoamMode = .wander
    ) {
        self.activity = activity
        self.stayDown = stayDown
        self.roam = roam
    }
}

/// `UserDefaults` storage for a `Mood`.
///
/// Unlike `JumbiniSettings`, a missing key means the DEFAULT rather than
/// `true`: two of these three switches are off in the personality that ships
/// today, so an upgrading user must find Jumba exactly as they left him.
/// An unrecognised raw string also means the default — a hand-edited or
/// downgraded preferences file must never be able to stop the dog starting.
enum MoodSettings {
    private enum Key {
        static let activity = "mood.activity"
        static let stayDown = "mood.stayDown"
        static let roam = "mood.roam"
    }

    static func load(from defaults: UserDefaults = .standard) -> Mood {
        var mood = Mood()
        if let raw = defaults.string(forKey: Key.activity),
           let activity = ActivityMode(rawValue: raw) {
            mood.activity = activity
        }
        mood.stayDown = (defaults.object(forKey: Key.stayDown) as? Bool) ?? false
        if let raw = defaults.string(forKey: Key.roam),
           let roam = RoamMode(rawValue: raw) {
            mood.roam = roam
        }
        return mood
    }

    static func save(_ mood: Mood, to defaults: UserDefaults = .standard) {
        defaults.set(mood.activity.rawValue, forKey: Key.activity)
        defaults.set(mood.stayDown, forKey: Key.stayDown)
        defaults.set(mood.roam.rawValue, forKey: Key.roam)
    }
}

/// What the Mood submenu offers, as data.
///
/// Which item carries a checkmark is a decision, and decisions do not need
/// AppKit to be made or to be checked. Follows `TidyMenuState`.
struct MoodMenuState: Equatable {
    struct Item: Equatable {
        var title: String
        var isChecked: Bool
    }

    static let submenuTitle = "Mood"

    var mood: Mood

    init(mood: Mood) {
        self.mood = mood
    }

    /// In declaration order — most energetic first, which is also menu order.
    var activityItems: [Item] {
        ActivityMode.allCases.map {
            Item(title: $0.menuTitle, isChecked: $0 == mood.activity)
        }
    }

    /// Named apart from the momentary "Lie Down" command sitting above it in
    /// the same menu: one is an order, this one is a hold.
    var stayDownItem: Item {
        Item(title: "Stay Lying Down", isChecked: mood.stayDown)
    }

    var followItem: Item {
        Item(title: "Follow My Cursor", isChecked: mood.roam == .follow)
    }
}
