import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory app: no Dock icon, no menu bar takeover. Controlled from the status item.
app.setActivationPolicy(.accessory)
app.run()
