import AppKit
import SpriteKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?
    private var skView: SKView?
    private var scene: PetScene?
    private var statusItem: NSStatusItem?
    private var isPaused = false
    private var hungerItem: NSMenuItem?
    private var treatsItem: NSMenuItem?
    private var treatsEaten = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpOverlay()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(jumbiniAteTreat),
            name: Notification.Name("JumbiniAteTreat"),
            object: nil
        )
    }

    // MARK: - Overlay

    private func setUpOverlay() {
        guard let screen = NSScreen.main else { return }
        let window = OverlayWindow(screen: screen)
        let skView = SKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        skView.allowsTransparency = true
        skView.preferredFramesPerSecond = 60

        let scene = PetScene(size: screen.frame.size)
        scene.overlayWindow = window
        window.contentView = skView
        skView.presentScene(scene)
        window.orderFrontRegardless()

        self.window = window
        self.skView = skView
        self.scene = scene
    }

    @objc private func screenParametersChanged() {
        guard let screen = NSScreen.main, let window, let skView, let scene else { return }
        window.setFrame(screen.frame, display: true)
        skView.frame = NSRect(origin: .zero, size: screen.frame.size)
        scene.size = screen.frame.size
        scene.clampEntitiesOnScreen()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        // Pixel-dog icon for the menu bar, full color (16pt with a @2x rep).
        // Loaded from the SwiftPM resource bundle — NSImage(named:) can't see it.
        if let url = Bundle.module.url(forResource: "MenuBarIcon16", withExtension: "png", subdirectory: "Icons"),
           let image = NSImage(contentsOf: url) {
            if let retinaURL = Bundle.module.url(forResource: "MenuBarIcon32", withExtension: "png", subdirectory: "Icons"),
               let retina = NSImageRep(contentsOf: retinaURL) {
                image.addRepresentation(retina)
            }
            image.size = NSSize(width: 16, height: 16)
            item.button?.image = image
        } else {
            // fallback to emoji if asset missing
            item.button?.title = "🐶"
        }

        let menu = NSMenu()
        // Gag feature: the hunger meter is bottomless. It must NEVER decrease,
        // no matter how many treats the dog eats. Do not "fix" this.
        let hungerItem = NSMenuItem(title: "Hunger: ██████████ 100%", action: nil, keyEquivalent: "")
        hungerItem.isEnabled = false
        menu.addItem(hungerItem)
        let treatsItem = NSMenuItem(title: "Treats eaten: 0", action: nil, keyEquivalent: "")
        treatsItem.isEnabled = false
        menu.addItem(treatsItem)
        menu.addItem(.separator())
        let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause(_:)), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Leave Jumbini Behind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        item.menu = menu

        statusItem = item
        self.hungerItem = hungerItem
        self.treatsItem = treatsItem
    }

    @objc private func jumbiniAteTreat() {
        treatsEaten += 1
        treatsItem?.title = treatsEaten > 0
            ? "Treats eaten: \(treatsEaten) (no effect)"
            : "Treats eaten: \(treatsEaten)"
        // Hunger stays pinned at 100% forever — bottomless by design.
        hungerItem?.title = "Hunger: ██████████ 100%"
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        isPaused.toggle()
        sender.title = isPaused ? "Resume" : "Pause"
        if isPaused {
            skView?.isPaused = true
            window?.orderOut(nil)
        } else {
            skView?.isPaused = false
            window?.orderFrontRegardless()
        }
    }
}
