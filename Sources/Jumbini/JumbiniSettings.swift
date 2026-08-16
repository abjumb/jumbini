import Foundation

/// User-facing behavior switches from the Settings panel.
///
/// Every feature defaults to enabled so upgrading preserves Jumbini's existing
/// personality. `object(forKey:)` is used instead of `bool(forKey:)` because a
/// missing Boolean otherwise reads as false and would silently disable new
/// features for every existing install.
struct JumbiniSettings: Equatable {
    private enum Key {
        static let poop = "features.poopEnabled"
        static let systemReactions = "features.systemReactionsEnabled"
        static let windowClimbing = "features.windowClimbingEnabled"
    }

    var poopEnabled: Bool
    var systemReactionsEnabled: Bool
    var windowClimbingEnabled: Bool

    init(
        poopEnabled: Bool = true,
        systemReactionsEnabled: Bool = true,
        windowClimbingEnabled: Bool = true
    ) {
        self.poopEnabled = poopEnabled
        self.systemReactionsEnabled = systemReactionsEnabled
        self.windowClimbingEnabled = windowClimbingEnabled
    }

    init(defaults: UserDefaults = .standard) {
        poopEnabled = Self.value(for: Key.poop, in: defaults)
        systemReactionsEnabled = Self.value(for: Key.systemReactions, in: defaults)
        windowClimbingEnabled = Self.value(for: Key.windowClimbing, in: defaults)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(poopEnabled, forKey: Key.poop)
        defaults.set(systemReactionsEnabled, forKey: Key.systemReactions)
        defaults.set(windowClimbingEnabled, forKey: Key.windowClimbing)
    }

    private static func value(for key: String, in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? true
    }
}
