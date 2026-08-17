import AppKit

// `NSApplication.delegate` is a weak reference, so something has to own the
// delegate for the life of the process. This used to be a top-level `let`;
// it is a stored static now because the launch had to move inside a function:
// top-level code runs on the main thread but is not itself main-actor
// isolated, and AppDelegate is.
@MainActor
private enum Launch {
    static let delegate = AppDelegate()

    static func run() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Accessory app: no Dock icon, no menu bar takeover. Controlled from
        // the status item.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

MainActor.assumeIsolated { Launch.run() }
