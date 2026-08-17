import AppKit
import Carbon.HIToolbox
import Sparkle
import SpriteKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?
    private var skView: SKView?
    private var scene: PetScene?
    private var statusItem: NSStatusItem?

    // Three independent reasons to stop the dog, all of which compose into
    // `isSuspended`. Only the first of them hides the overlay window; the
    // other two are cases where there is already nothing to see.
    /// The Pause menu item.
    private var isPausedByUser = false
    /// The displays have gone to sleep.
    private var screensAsleep = false
    /// The overlay is completely covered by another window.
    private var overlayHidden = false

    /// Rendering, window polling and the machine watcher all follow this.
    private var isSuspended: Bool { isPausedByUser || screensAsleep || overlayHidden }

    private var hungerItem: NSMenuItem?
    private var treatsItem: NSMenuItem?
    private var treatsEaten = 0

    // Jumbini Cam: Carbon hotkey handles, released in applicationWillTerminate.
    private var camHotKeyRef: EventHotKeyRef?
    private var camEventHandlerRef: EventHandlerRef?

    // System reactions: ambient machine watcher, stopped in applicationWillTerminate.
    private var systemMonitor: SystemMonitor?

    // Demo capture: nil on every normal launch. See DemoDriver.fromEnvironment.
    private var demoDriver: DemoDriver?

    // Auto-update: Sparkle's standard updater controller, which owns the
    // background update checks and the "Check for Updates…" UI.
    private var updaterController: SPUStandardUpdaterController?

    // Make Your Own Dog: the generation panel, kept alive while open.
    private var dogGeneratorPanel: DogGeneratorPanel?
    // Coat Workshop: import, validate, preview, and install custom coats.
    private var coatWorkshopPanel: CoatWorkshopPanel?
    // Settings: one persistent panel, reopened from the menu bar or Command-comma.
    private var settingsPanel: SettingsPanel?
    private(set) var settings: JumbiniSettings

    init(defaults: UserDefaults = .standard) {
        settings = JumbiniSettings(defaults: defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpUpdater()
        setUpStatusItem()
        setUpOverlay()
        apply(settings: settings)
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
        observeScreenSleep()
        // Demo capture block: no-op unless JUMBINI_DEMO names a script.
        startDemoDriver()
        // Demo capture block end.
        // Jumbini Cam block: global hotkey ⌥⇧J (Carbon; no accessibility
        // permission needed, unlike a CGEvent tap). Keep as the last line of
        // this method — self-contained, order-independent.
        registerCamHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        unregisterCamHotKey()
        // System reactions: drop the poll timer and the thermal observer.
        systemMonitor?.stop()
        systemMonitor = nil
        demoDriver?.stop()
        demoDriver = nil
    }

    // MARK: - Overlay

    /// ONE overlay over the union of every display, rather than one per
    /// screen. The dog then has a single continuous world to live in: walking
    /// off the right edge of one monitor and onto the next is just walking,
    /// with no hand-off of him, his hat, or whatever is in his mouth. What it
    /// costs is dead zones — the corners of that bounding box that belong to
    /// no display — and `ScreenLayout` is what keeps him out of those.
    private func setUpOverlay() {
        let layout = ScreenLayout.current()
        guard layout.size.width > 0, layout.size.height > 0 else { return }
        let window = OverlayWindow(frame: layout.unionFrame)
        let skView = SKView(frame: NSRect(origin: .zero, size: layout.size))
        skView.allowsTransparency = true
        // The opening rate only. From the first frame on, the scene drives
        // this from what the dog is doing — 60 while something is moving, a
        // quarter of that while he is asleep on a static sprite.
        skView.preferredFramesPerSecond = 60

        let scene = PetScene(layout: layout, settings: settings)
        scene.overlayWindow = window
        window.contentView = skView
        skView.presentScene(scene)
        window.orderFrontRegardless()

        self.window = window
        self.skView = skView
        self.scene = scene

        // A window nothing can see is a window nothing needs to draw.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(overlayOcclusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    /// A display was plugged in, unplugged, rearranged or had its resolution
    /// changed. Rebuild the world around the dog rather than around the app:
    /// the overlay is resized to the new union, and the scene translates and
    /// rescues everything living in it. Order matters — the window and view
    /// have to be the new size before the scene starts clamping into it.
    @objc private func screenParametersChanged() {
        guard let window, let skView, let scene else { return }
        let layout = ScreenLayout.current()
        guard layout.size.width > 0, layout.size.height > 0 else { return }
        window.setFrame(layout.unionFrame, display: true)
        skView.frame = NSRect(origin: .zero, size: layout.size)
        scene.size = layout.size
        scene.apply(layout: layout)
    }

    // MARK: - Auto-update (Sparkle)

    /// Create and start the Sparkle updater. The feed URL, public key and
    /// automatic-check behaviour all live in Info.plist (SUFeedURL,
    /// SUPublicEDKey, SUEnableAutomaticChecks); the controller just reads them.
    /// A missing key or feed only disables updating — it never stops the dog.
    private func setUpUpdater() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        // Pixel-dog icon for the menu bar, full color (16pt with a @2x rep).
        // Loaded from the SwiftPM resource bundle — NSImage(named:) can't see it.
        if let url = Bundle.assets.url(forResource: "MenuBarIcon16", withExtension: "png", subdirectory: "Icons"),
           let image = NSImage(contentsOf: url) {
            if let retinaURL = Bundle.assets.url(forResource: "MenuBarIcon32", withExtension: "png", subdirectory: "Icons"),
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
        //
        // The bar is ten block characters, which VoiceOver reads out as ten
        // block characters. The joke survives being said in words; being
        // spelled out one glyph at a time, it does not.
        let hungerItem = NSMenuItem(title: "Hunger: ██████████ 100%", action: nil, keyEquivalent: "")
        hungerItem.isEnabled = false
        hungerItem.setAccessibilityLabel(Self.hungerLabel)
        menu.addItem(hungerItem)
        let treatsItem = NSMenuItem(title: "Treats eaten: 0", action: nil, keyEquivalent: "")
        treatsItem.isEnabled = false
        treatsItem.setAccessibilityLabel(Self.treatsLabel(eaten: 0))
        menu.addItem(treatsItem)
        menu.addItem(.separator())
        // Every command from his right-click menu, reachable from the keyboard.
        // The overlay is click-through and the dog moves; hunting him with a
        // pointer to open a context menu is not a route everyone has.
        menu.addItem(jumbaCommandsItem())
        // Jumbini Cam block: between the counters separator and Pause. Stays
        // enabled while paused — the capture renders offscreen and still works.
        let camItem = NSMenuItem(title: "Jumbini Cam", action: #selector(captureJumbiniCam), keyEquivalent: "j")
        camItem.keyEquivalentModifierMask = [.option, .shift]
        camItem.target = self
        menu.addItem(camItem)
        // Jumbini Cam block end.
        let makeDogItem = NSMenuItem(title: "Make Your Own Dog", action: #selector(openDogGenerator), keyEquivalent: "")
        makeDogItem.target = self
        menu.addItem(makeDogItem)
        let workshopItem = NSMenuItem(title: "Coat Workshop…", action: #selector(openCoatWorkshop), keyEquivalent: "")
        workshopItem.target = self
        menu.addItem(workshopItem)
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        let muteItem = NSMenuItem(title: "Mute Sounds", action: #selector(toggleMute(_:)), keyEquivalent: "")
        muteItem.target = self
        muteItem.state = UserDefaults.standard.bool(forKey: "soundMuted") ? .on : .off
        // Alex's icon, colored — deliberately NOT a template image, same call
        // as the menu bar dog above: this app's art is pixel art, and macOS
        // would flatten it to a monochrome silhouette.
        if let url = Bundle.assets.url(forResource: "icon_mute", withExtension: "png", subdirectory: "sprites"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 16, height: 16)
            muteItem.image = image
        }
        menu.addItem(muteItem)
        let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause(_:)), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        // Which build this is, sitting next to the thing that changes it.
        // Nothing needs to refresh it: Sparkle relaunches the app to finish an
        // update, so the number is read fresh by the new process. No action,
        // which is what greys it out — autoenablesItems infers that much on
        // its own, and the explicit flag matches the counters above.
        let versionItem = NSMenuItem(title: AppVersion.menuTitle, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        // Auto-update: target/action point at the Sparkle controller, which
        // also toggles the item's enabled state as canCheckForUpdates changes.
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)
        let quitItem = NSMenuItem(title: "Leave Jumbini Behind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        item.menu = menu

        statusItem = item
        self.hungerItem = hungerItem
        self.treatsItem = treatsItem
    }

    /// What the two counters say out loud. The titles carry a drawn bar and a
    /// parenthetical gag; these carry the same information as a sentence.
    private static let hungerLabel = "Hunger: full, 100 percent. Bottomless."

    private static func treatsLabel(eaten: Int) -> String {
        let treats = eaten == 1 ? "1 treat" : "\(eaten) treats"
        return eaten > 0
            ? "\(treats) eaten, with no effect on his hunger."
            : "\(treats) eaten."
    }

    @objc private func jumbiniAteTreat() {
        treatsEaten += 1
        treatsItem?.title = treatsEaten > 0
            ? "Treats eaten: \(treatsEaten) (no effect)"
            : "Treats eaten: \(treatsEaten)"
        treatsItem?.setAccessibilityLabel(Self.treatsLabel(eaten: treatsEaten))
        // Hunger stays pinned at 100% forever — bottomless by design.
        hungerItem?.title = "Hunger: ██████████ 100%"
        hungerItem?.setAccessibilityLabel(Self.hungerLabel)
    }

    // MARK: - Jumba (keyboard route to his commands)

    /// The same commands his right-click menu offers, in the status bar.
    ///
    /// `PetScene.perform` is the one entry point for a command however it was
    /// chosen — the context menu, the demo driver and this all go down it —
    /// so mirroring the list here costs nothing but the titles.
    private static let jumbaCommands: [(String, DogCommand)] = [
        ("Sit", .sit),
        ("Lie Down", .lieDown),
        ("Spin", .spin),
        ("Spin Forever", .spinForever),
        ("Zoomies!", .zoomies),
        ("Fetch", .fetch),
        ("Settle Down", .relax),
    ]

    private func jumbaCommandsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Jumba", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, command) in Self.jumbaCommands {
            let entry = NSMenuItem(
                title: title, action: #selector(jumbaCommandChosen(_:)), keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = command
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func jumbaCommandChosen(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DogCommand else { return }
        scene?.perform(command)
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        let muted = !defaults.bool(forKey: "soundMuted")
        defaults.set(muted, forKey: "soundMuted")
        sender.state = muted ? .on : .off
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        isPausedByUser.toggle()
        sender.title = isPausedByUser ? "Resume" : "Pause"
        if isPausedByUser {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
            // A window that has been ordered out reads as occluded, and the
            // notification putting that right arrives a beat after this. Say
            // so now rather than leaving him frozen until it does — if he
            // really is covered, the notification will say so again.
            overlayHidden = false
        }
        applyRunState()
    }

    // MARK: - Suspending

    /// Nobody is looking: the displays went to sleep.
    ///
    /// Everything the app does while nothing is on screen is pure waste —
    /// sixty renders a second into a dark display, a window-server poll for
    /// windows nobody can see, a `pgrep` fork for a build nobody is watching.
    private func observeScreenSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification, object: nil
        )
        workspace.addObserver(
            self, selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )
    }

    @objc private func screensDidSleep() {
        screensAsleep = true
        applyRunState()
    }

    @objc private func screensDidWake() {
        screensAsleep = false
        applyRunState()
    }

    /// The overlay was fully covered, or uncovered again. Unlike Pause this
    /// leaves the window exactly where it is: it is still up, it just has
    /// nothing to contribute until something moves off it.
    @objc private func overlayOcclusionChanged() {
        guard let window, !isPausedByUser else { return }
        overlayHidden = !window.occlusionState.contains(.visible)
        applyRunState()
    }

    /// The one place that decides whether the dog is running. Called by every
    /// reason he might stop, so the three of them can't fight over the view.
    private func applyRunState() {
        let suspended = isSuspended
        skView?.isPaused = suspended
        // Window walking: stop polling the window server while he's away.
        scene?.setWindowWatching(!suspended)
        updateSystemMonitor()
    }

    // MARK: - System reactions

    /// Start watching the machine and forward what it notices to the dog.
    /// The monitor is entirely self-contained: any source that can't work on
    /// this Mac degrades to silence, so there is nothing to check here.
    private func startSystemMonitor() {
        guard systemMonitor == nil else { return }
        let monitor = SystemMonitor()
        monitor.onSignal = { [weak self] signal in
            // SystemMonitor guarantees main-thread delivery, which is what
            // the scene needs. Suspended means the view is frozen and there
            // is nothing on screen — the dog should not be reacting to
            // anything, and a signal that arrived in the gap before the
            // monitor stopped must not sneak through.
            guard let self, !self.isSuspended else { return }
            self.scene?.receive(signal)
        }
        monitor.start()
        systemMonitor = monitor
    }

    private func stopSystemMonitor() {
        systemMonitor?.onSignal = nil
        systemMonitor?.stop()
        systemMonitor = nil
    }

    private func apply(settings: JumbiniSettings) {
        self.settings = settings
        scene?.apply(settings: settings)
        updateSystemMonitor()
    }

    /// The monitor runs only when the user wants reactions AND there is a dog
    /// awake to react. Both the settings switch and every suspension route
    /// come through here.
    ///
    /// A suspension pause does NOT destroy the monitor — it stops polling
    /// without resetting the trackers, so Battery/DND don't re-fire on every
    /// wake and a running build isn't lost. The settings toggle still creates
    /// or tears down the whole monitor.
    private func updateSystemMonitor() {
        if settings.systemReactionsEnabled && !isSuspended {
            if let monitor = systemMonitor {
                monitor.resumePolling()
            } else {
                startSystemMonitor()
            }
        } else {
            systemMonitor?.pausePolling()
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if let settingsPanel {
            settingsPanel.present()
            return
        }
        let panel = SettingsPanel()
        panel.onSettingsChanged = { [weak self] settings in
            self?.apply(settings: settings)
        }
        panel.present()
        settingsPanel = panel
    }

    /// Landing-page capture only. Returns immediately on a normal launch
    /// because `fromEnvironment` finds no JUMBINI_DEMO to act on.
    private func startDemoDriver() {
        guard let driver = DemoDriver.fromEnvironment() else { return }
        driver.onBeat = { [weak self] beat in
            guard let self, let scene = self.scene else { return }
            switch beat.action {
            case .command(let command):
                scene.perform(command)
            case .system(let signal):
                scene.receive(signal)
            case .cursor(let point):
                // Warping needs no Accessibility permission, unlike posting
                // a synthetic move event. Top-left origin, like the display.
                CGWarpMouseCursorPosition(point)
            case .wait:
                break
            }
        }
        driver.onFinish = { NSApp.terminate(nil) }
        driver.start()
        demoDriver = driver
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

    // MARK: - Make Your Own Dog

    /// Open the generation panel. The panel owns the picker and progress UI;
    /// the closures here run the real pipeline and select the result, so the
    /// panel itself stays free of any Pixellab or coat-disk knowledge.
    ///
    /// Built once and kept. Now that the panel can be closed, choosing the menu
    /// item again has to reopen the existing one rather than stack a second
    /// panel on top of the first — and it means closing the window by accident
    /// does not throw away three photos the user just picked.
    @objc private func openDogGenerator() {
        if let existing = dogGeneratorPanel {
            existing.present()
            return
        }
        let panel = DogGeneratorPanel()
        panel.generate = { photos, onProgress in
            let sprites = try await DogGenerator.generate(
                photos: photos, client: PixellabClient(), onProgress: onProgress
            )
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let coatsDirectory = support.appendingPathComponent("Jumbini/coats", isDirectory: true)
            try DogGenerator.writeCoat(
                sprites,
                to: coatsDirectory.appendingPathComponent(DogGenerator.coatID, isDirectory: true)
            )
            guard let preview = sprites[.idle]?[.south] else {
                throw DogGeneratorError.missingFrame(.idle, .south)
            }
            return preview
        }
        panel.onApply = { [weak self] in
            self?.openCoatWorkshopForMyDog()
        }
        panel.present()
        dogGeneratorPanel = panel
    }

    // MARK: - Coat Workshop

    @objc private func openCoatWorkshop() {
        scene?.openCoatWorkshop()
    }

    private func openCoatWorkshopForMyDog() {
        scene?.openCoatWorkshop()
        if let coatsDir = CoatCatalog.defaultCoatsDirectory() {
            let myDogURL = coatsDir.appendingPathComponent(DogGenerator.coatID, isDirectory: true)
            let coat = CoatCatalog.coat(at: myDogURL)
            if let coat {
                scene?.openWorkshopFor(coat: coat)
            }
        }
    }
}
