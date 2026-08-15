import AppKit
import Carbon.HIToolbox
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

    // Jumbini Cam: Carbon hotkey handles, released in applicationWillTerminate.
    private var camHotKeyRef: EventHotKeyRef?
    private var camEventHandlerRef: EventHandlerRef?

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
        // Jumbini Cam block: global hotkey ⌥⇧J (Carbon; no accessibility
        // permission needed, unlike a CGEvent tap). Keep as the last line of
        // this method — self-contained, order-independent.
        registerCamHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterCamHotKey()
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
        // Jumbini Cam block: between the counters separator and Pause. Stays
        // enabled while paused — the capture renders offscreen and still works.
        let camItem = NSMenuItem(title: "Jumbini Cam", action: #selector(captureJumbiniCam), keyEquivalent: "j")
        camItem.keyEquivalentModifierMask = [.option, .shift]
        camItem.target = self
        menu.addItem(camItem)
        // Jumbini Cam block end.
        let muteItem = NSMenuItem(title: "Mute Sounds", action: #selector(toggleMute(_:)), keyEquivalent: "")
        muteItem.target = self
        muteItem.state = UserDefaults.standard.bool(forKey: "soundMuted") ? .on : .off
        menu.addItem(muteItem)
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

    @objc private func toggleMute(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        let muted = !defaults.bool(forKey: "soundMuted")
        defaults.set(muted, forKey: "soundMuted")
        sender.state = muted ? .on : .off
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

    // MARK: - Jumbini Cam

    /// 'JBCM' — identifies our hotkey in the Carbon handler.
    private static let camHotKeySignature: OSType = 0x4A42_434D

    /// Global ⌥⇧J via Carbon RegisterEventHotKey: works system-wide without
    /// accessibility permission (a CGEvent tap would prompt for it).
    private func registerCamHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C function pointer — no captures; self travels through userData.
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == AppDelegate.camHotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            // Carbon dispatches on the main thread already; the async hop is
            // cheap insurance that the SpriteKit render happens on main.
            DispatchQueue.main.async { delegate.captureJumbiniCam() }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &camEventHandlerRef
        )
        let hotKeyID = EventHotKeyID(signature: Self.camHotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_J), UInt32(optionKey | shiftKey), hotKeyID,
            GetApplicationEventTarget(), 0, &camHotKeyRef
        )
        if status != noErr {
            // Another app owns ⌥⇧J: degrade gracefully, the menu item still works.
            NSLog("Jumbini Cam: hotkey registration failed (OSStatus \(status))")
        }
    }

    private func unregisterCamHotKey() {
        if let camHotKeyRef {
            UnregisterEventHotKey(camHotKeyRef)
            self.camHotKeyRef = nil
        }
        if let camEventHandlerRef {
            RemoveEventHandler(camEventHandlerRef)
            self.camEventHandlerRef = nil
        }
    }

    /// Hotkey and menu item both land here: snapshot the dog (plus anything
    /// worn or carried), straight to the clipboard. Also works while paused:
    /// texture(from:) renders offscreen, so the hidden overlay window doesn't
    /// matter — the scene just skips the flash then.
    @objc fileprivate func captureJumbiniCam() {
        guard let image = scene?.captureJumbini() else { return }
        copyCamImageToPasteboard(image)
    }

    /// PNG first (what most apps want from a "screenshot"), then the NSImage
    /// object so anything reading via NSImage(pasteboard:)/TIFF works too.
    private func copyCamImageToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.declareTypes([.png], owner: nil)
            pasteboard.setData(png, forType: .png)
        }
        pasteboard.writeObjects([image])
    }
}
