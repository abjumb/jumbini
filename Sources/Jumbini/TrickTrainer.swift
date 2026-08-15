import Foundation

// MARK: - Storage

/// Per-key Int storage for trick progression. UserDefaults in the app, a
/// dictionary in tests — the trainer never touches UserDefaults directly.
protocol TrickProgressStore: AnyObject {
    func int(forKey key: String) -> Int?
    func set(_ value: Int, forKey key: String)
}

/// The real store: persists across launches via UserDefaults.
final class UserDefaultsTrickStore: TrickProgressStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func int(forKey key: String) -> Int? {
        defaults.object(forKey: key) as? Int
    }

    func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Test double: same contract, no disk.
final class InMemoryTrickStore: TrickProgressStore {
    private(set) var values: [String: Int] = [:]

    func int(forKey key: String) -> Int? {
        values[key]
    }

    func set(_ value: Int, forKey key: String) {
        values[key] = value
    }
}

// MARK: - Trainer

/// Trick progression: tricks aren't free. A rep is an attempted trick followed
/// by a treat eaten within `rewardWindow`; `repsNeeded` reps unlock the trick
/// permanently (persisted via the injected store). Pure logic, explicit
/// timestamps — same testing philosophy as DogBrain.
final class TrickTrainer {
    /// Reps required to unlock a trick.
    let repsNeeded: Int
    /// A treat only rewards an attempt made at most this many seconds earlier.
    let rewardWindow: TimeInterval

    private let store: TrickProgressStore
    /// Attempts not yet rewarded by a treat, in the order they were made.
    /// Session-local on purpose: half a rep doesn't survive a relaunch.
    private var pendingAttempts: [(trick: Trick, time: TimeInterval)] = []

    init(store: TrickProgressStore, repsNeeded: Int = 3, rewardWindow: TimeInterval = 10) {
        self.store = store
        self.repsNeeded = repsNeeded
        self.rewardWindow = rewardWindow
    }

    // MARK: Queries

    func isUnlocked(_ trick: Trick) -> Bool {
        (store.int(forKey: unlockedKey(trick)) ?? 0) != 0
    }

    func progress(_ trick: Trick) -> (reps: Int, needed: Int) {
        (reps: store.int(forKey: repsKey(trick)) ?? 0, needed: repsNeeded)
    }

    // MARK: Training

    /// The dog was asked to do a (locked) trick. Unlocked tricks are just
    /// performed — showing off is not training, so nothing accumulates.
    func recordAttempt(_ trick: Trick, at now: TimeInterval) {
        guard !isUnlocked(trick) else { return }
        // Attempts too old to ever be rewarded are dead weight; drop them.
        pendingAttempts.removeAll { now - $0.time > rewardWindow }
        pendingAttempts.append((trick: trick, time: now))
    }

    /// The dog ate a treat. Rewards at most one attempt — the most recent
    /// un-rewarded one within the window — and returns the trick whose rep
    /// counted, or nil if the treat was just a treat.
    @discardableResult
    func recordTreat(at now: TimeInterval) -> Trick? {
        guard let index = pendingAttempts.indices.reversed().first(where: {
            let attempt = pendingAttempts[$0]
            return attempt.time <= now && now - attempt.time <= rewardWindow
        }) else { return nil }

        let trick = pendingAttempts.remove(at: index).trick
        let reps = min((store.int(forKey: repsKey(trick)) ?? 0) + 1, repsNeeded)
        store.set(reps, forKey: repsKey(trick))
        if reps >= repsNeeded {
            store.set(1, forKey: unlockedKey(trick))
            // The trick is learned: any leftover attempts for it are moot.
            pendingAttempts.removeAll { $0.trick == trick }
        }
        return trick
    }

    // MARK: Keys ("trick.shake.reps" / "trick.shake.unlocked")

    private func repsKey(_ trick: Trick) -> String {
        "trick.\(storageName(for: trick)).reps"
    }

    private func unlockedKey(_ trick: Trick) -> String {
        "trick.\(storageName(for: trick)).unlocked"
    }

    /// Stable storage identifier — deliberately NOT the raw value, which is a
    /// human-facing menu title that could change wording.
    private func storageName(for trick: Trick) -> String {
        switch trick {
        case .shake: return "shake"
        case .highFive: return "highFive"
        case .playDead: return "playDead"
        case .rollOver: return "rollOver"
        }
    }
}
