import Foundation
import CoreGraphics

// MARK: - Pure timeline logic
//
// Same shape as SystemMonitor's trackers: the decisions are pure and
// clock-injected, so they are unit-tested without a Mac underneath. The
// impure half — the timer and the scene — lives in DemoDriver at the bottom.

/// One scripted moment. Every action resolves to a call the app already
/// makes; the driver cannot express anything the dog can't already do.
struct DemoBeat: Equatable {
    enum Action: Equatable {
        case command(DogCommand)
        case system(SystemSignal)
        case cursor(CGPoint)
        case wait
    }

    let at: TimeInterval
    let action: Action
}

enum DemoParseError: Error, Equatable {
    case unknownKind(String)
    case unknownSignal(String)
    case unknownCommand(String)
    case unknownTrick(String)
    case unknownToy(String)
    case malformed(String)
}

struct DemoScript: Equatable {
    let name: String
    let duration: TimeInterval
    /// Whether the recorder should draw the pointer. Distinct from the
    /// `.cursor` beat action, which moves it.
    let showCursor: Bool
    let beats: [DemoBeat]
}

extension DemoScript {
    init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = root["name"] as? String,
              let duration = root["duration"] as? Double,
              let rawBeats = root["beats"] as? [[String: Any]] else {
            throw DemoParseError.malformed("expected name, duration and beats")
        }
        self.init(
            name: name,
            duration: duration,
            showCursor: root["showCursor"] as? Bool ?? false,
            beats: try rawBeats.map(DemoBeat.init(json:))
        )
    }
}

extension DemoBeat {
    init(json object: [String: Any]) throws {
        guard let at = object["at"] as? Double else {
            throw DemoParseError.malformed("beat without an `at`")
        }
        let kind = object["kind"] as? String ?? ""
        switch kind {
        case "wait":
            self.init(at: at, action: .wait)
        case "system":
            let name = object["signal"] as? String ?? ""
            guard let signal = SystemSignal(demoName: name) else {
                throw DemoParseError.unknownSignal(name)
            }
            self.init(at: at, action: .system(signal))
        case "command":
            let name = object["command"] as? String ?? ""
            self.init(at: at, action: .command(try DogCommand(demoName: name)))
        case "cursor":
            guard let x = object["x"] as? Double, let y = object["y"] as? Double else {
                throw DemoParseError.malformed("cursor beat without x and y")
            }
            self.init(at: at, action: .cursor(CGPoint(x: x, y: y)))
        default:
            throw DemoParseError.unknownKind(kind)
        }
    }
}

extension SystemSignal {
    /// Spelled exactly like the case names, so a script reads like the code.
    init?(demoName name: String) {
        switch name {
        case "buildFinished": self = .buildFinished
        case "idleBegan": self = .idleBegan
        case "idleEnded": self = .idleEnded
        case "fansUp": self = .fansUp
        case "batteryLow": self = .batteryLow
        case "batteryNormal": self = .batteryNormal
        case "dndOn": self = .dndOn
        case "dndOff": self = .dndOff
        default: return nil
        }
    }
}

extension DogCommand {
    /// Plain cases by name; the two with payloads as `trick:<Title>` and
    /// `toy:<kind>`. Tricks use the enum's raw value, which is the menu title.
    init(demoName name: String) throws {
        if let rest = name.dropPrefixIfPresent("trick:") {
            guard let trick = Trick(rawValue: String(rest)) else {
                throw DemoParseError.unknownTrick(String(rest))
            }
            self = .trick(trick)
            return
        }
        if let rest = name.dropPrefixIfPresent("toy:") {
            switch rest {
            case "frisbee": self = .toy(.frisbee)
            case "squeaky": self = .toy(.squeaky)
            case "rope": self = .toy(.rope)
            default: throw DemoParseError.unknownToy(String(rest))
            }
            return
        }
        switch name {
        case "sit": self = .sit
        case "lieDown": self = .lieDown
        case "spin": self = .spin
        case "fetch": self = .fetch
        case "spinForever": self = .spinForever
        case "zoomies": self = .zoomies
        case "relax": self = .relax
        default: throw DemoParseError.unknownCommand(name)
        }
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}

/// Hands out beats whose time has come. Clock-injected: the caller decides
/// what "now" means, so a test can jump straight to t=5 and a slow launch
/// can't skip a beat.
struct DemoTimeline {
    private let beats: [DemoBeat]
    private var nextIndex = 0

    init(script: DemoScript) {
        // Stable sort by time: a script author listing beats out of order
        // gets the obvious behaviour rather than a silently dropped beat.
        self.beats = script.beats.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
    }

    var isFinished: Bool { nextIndex >= beats.count }

    /// Every beat due at or before `elapsed` that hasn't been handed out yet.
    mutating func due(at elapsed: TimeInterval) -> [DemoBeat] {
        var out: [DemoBeat] = []
        while nextIndex < beats.count, beats[nextIndex].at <= elapsed {
            out.append(beats[nextIndex])
            nextIndex += 1
        }
        return out
    }
}

// MARK: - The impure half
//
// Mirrors SystemMonitor: a timer, a closure the app layer wires to the
// scene, and a stop(). Nothing here decides anything.

/// Plays a scripted timeline into the running scene. Built ONLY when
/// `JUMBINI_DEMO` names a readable, parseable script — a normal launch
/// never has one, so a normal launch never has a driver.
///
/// This exists so the landing-page footage can be re-shot on demand. Every
/// beat it plays goes through the same entry point as a menu click or a
/// SystemMonitor signal, so what gets filmed is the shipping behaviour and
/// not a special demo mode of the dog.
final class DemoDriver {
    let script: DemoScript
    /// Delivered on the main thread, like SystemMonitor.onSignal.
    var onBeat: ((DemoBeat) -> Void)?
    /// Called once when the script's duration is up.
    var onFinish: (() -> Void)?

    private var timeline: DemoTimeline
    private var timer: Timer?
    private var startedAt: Date?

    /// Beats are checked 30 times a second — fine enough that a beat lands
    /// within a frame or two of its mark at 60fps capture.
    private static let tick: TimeInterval = 1.0 / 30.0

    init(script: DemoScript) {
        self.script = script
        self.timeline = DemoTimeline(script: script)
    }

    /// The gate. A missing variable, an unreadable file, or a script that
    /// doesn't parse all mean the same thing: no driver, app behaves normally.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DemoDriver? {
        guard let path = environment["JUMBINI_DEMO"] else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let script = try? DemoScript(json: data) else { return nil }
        return DemoDriver(script: script)
    }

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            self?.fire()
        }
        // .common so the beats keep landing while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fire() {
        guard let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        for beat in timeline.due(at: elapsed) {
            onBeat?(beat)
        }
        if elapsed >= script.duration {
            stop()
            onFinish?()
        }
    }
}
