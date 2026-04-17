import AppKit
import Carbon.HIToolbox

// Prevent duplicate instances via file lock
let lockPath = "/tmp/force-hidpi.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    fputs("force-hidpi: already running\n", stderr)
    exit(1)
}

// Global so it outlives NSApp's weak delegate reference
let appDelegate = AppDelegate()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = appDelegate

// Clean shutdown on SIGINT/SIGTERM
for sig: Int32 in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    appDelegate.retainedSources.append(source)
}

app.run()

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate static let appVersion = "1.3.0"
    private var statusItem: NSStatusItem!
    private let manager = DisplayManager()
    private let brightness = BrightnessController()
    private var brightnessUpHotKey: HotKey?
    private var brightnessDownHotKey: HotKey?
    private var shortcutWindowController: ShortcutWindowController?
    private var isActive = false
    private var isActivating = false
    fileprivate var retainedSources: [Any] = []
    private var displayObserver: Any?
    private var profileObserver: Any?
    /// Timestamp when activation last completed, used to ignore aftershock
    /// display-change notifications from our own reconfiguration.
    private var activationCompletedAt: Date?

    // Settings stored as a plist file (UserDefaults suiteName writes
    // silently fail on modern macOS for non-bundled executables).
    private static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.force-hidpi.plist")

    /// Brightness step applied per hotkey press (fraction of full range).
    private static let brightnessStep: Float = 0.20

    /// Default hotkeys: ⌃⌘PageUp / ⌃⌘PageDown
    private static let defaultBrightnessUp = HotKey.Combo(
        keyCode: UInt32(kVK_PageUp),
        carbonModifiers: UInt32(controlKey) | UInt32(cmdKey)
    )
    private static let defaultBrightnessDown = HotKey.Combo(
        keyCode: UInt32(kVK_PageDown),
        carbonModifiers: UInt32(controlKey) | UInt32(cmdKey)
    )

    private var _hdrMode: Bool = true
    private var _scaleFactor: Double = 2.0
    private var _brightness: Float = 1.0
    private var pendingSave: DispatchWorkItem?
    private var _brightnessUpCombo: HotKey.Combo = defaultBrightnessUp
    private var _brightnessDownCombo: HotKey.Combo = defaultBrightnessDown

    private static let scaleOptions: [Double] = [2.0, 2.25, 2.5, 3.0, 3.5, 4.0]

    private var hdrMode: Bool {
        get { _hdrMode }
        set { _hdrMode = newValue; savePrefs() }
    }

    private var scaleFactor: Double {
        get { _scaleFactor }
        set { _scaleFactor = newValue; savePrefs() }
    }

    private var brightnessLevel: Float {
        get { _brightness }
        set { _brightness = max(0, min(1, newValue)); savePrefs() }
    }

    var brightnessUpCombo: HotKey.Combo {
        get { _brightnessUpCombo }
        set { _brightnessUpCombo = newValue; savePrefs(); registerHotKeys() }
    }

    var brightnessDownCombo: HotKey.Combo {
        get { _brightnessDownCombo }
        set { _brightnessDownCombo = newValue; savePrefs(); registerHotKeys() }
    }

    private func loadPrefs() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any]
        else { return }
        if let v = dict["hdrMode"] as? Bool { _hdrMode = v }
        if let v = dict["scaleFactor"] as? Double, v >= 2.0 { _scaleFactor = v }
        if let v = dict["brightness"] as? Double { _brightness = Float(max(0, min(1, v))) }
        if let up = dict["brightnessUp"] as? [String: Any],
           let keyCode = up["keyCode"] as? Int,
           let mods = up["modifiers"] as? Int {
            _brightnessUpCombo = HotKey.Combo(keyCode: UInt32(keyCode),
                                              carbonModifiers: UInt32(mods))
        }
        if let down = dict["brightnessDown"] as? [String: Any],
           let keyCode = down["keyCode"] as? Int,
           let mods = down["modifiers"] as? Int {
            _brightnessDownCombo = HotKey.Combo(keyCode: UInt32(keyCode),
                                                carbonModifiers: UInt32(mods))
        }
    }

    private func savePrefs() {
        let dict: [String: Any] = [
            "hdrMode": _hdrMode,
            "scaleFactor": _scaleFactor,
            "brightness": Double(_brightness),
            "brightnessUp": [
                "keyCode": Int(_brightnessUpCombo.keyCode),
                "modifiers": Int(_brightnessUpCombo.modifiers),
            ],
            "brightnessDown": [
                "keyCode": Int(_brightnessDownCombo.keyCode),
                "modifiers": Int(_brightnessDownCombo.modifiers),
            ],
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
        else { return }
        try? data.write(to: Self.settingsURL, options: .atomic)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPrefs()
        registerHotKeys()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusIcon(.inactive)
        rebuildMenu()
        activate()

        // Watch for display connect/disconnect/sleep-wake
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleDisplayChange()
        }

        // Watch for colour profile changes (Night Shift, True Tone, manual ICC switch)
        profileObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.ColorSync.DisplayProfileNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleProfileChange()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = displayObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = profileObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        manager.deactivate()
    }

    // MARK: - Display change handling

    private func handleProfileChange() {
        guard isActive else { return }
        manager.rematchColourProfile()
    }

    private func handleDisplayChange() {
        // Ignore display reconfigurations we triggered ourselves (deactivate/activate cycle).
        // resetStatusItem during our own cycle crashes AppKit (menu is still on the call stack).
        guard !isActivating else { return }

        // Ignore aftershock notifications from our own reconfiguration for 2s
        // after activation completes. findTarget() can return nil transiently
        // during the display system settling, which would cause a spurious deactivate.
        let inCooldown = activationCompletedAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false
        if isActive && !inCooldown {
            if manager.findTarget() == nil {
                manager.deactivate()
                brightness.invalidate()
                isActive = false
            } else {
                // Display sleep/wake can reset gamma tables and colour profiles.
                // Re-apply so PQ correction and ICC matching survive wake cycles.
                manager.rematchColourProfile()
                // IORegistry paths can shuffle across sleep/wake on some docks,
                // so re-resolve the IOAVService for the (possibly new) target.
                if let target = manager.targetDisplay {
                    brightness.invalidate()
                    _ = brightness.resolve(displayID: target.displayID)
                }
            }
        }
        // Recreate the status item - display reconfiguration invalidates
        // the cached screen coordinates and the menu appears in the wrong place
        resetStatusItem()
    }

    private func resetStatusItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusIcon(isActivating ? .activating : (isActive ? .active : .inactive))
        rebuildMenu()
    }

    // MARK: - Status icon

    private enum IconState { case active, inactive, activating }

    private func setStatusIcon(_ state: IconState) {
        guard let button = statusItem.button else { return }

        // Draw a display icon with a coloured status dot
        let size = NSSize(width: 22, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            // Draw the display SF Symbol as template
            if let symbol = NSImage(systemSymbolName: "display",
                                    accessibilityDescription: "Force HiDPI") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                let configured = symbol.withSymbolConfiguration(config) ?? symbol
                let symbolSize = configured.size
                let origin = NSPoint(x: (rect.width - symbolSize.width) / 2,
                                     y: (rect.height - symbolSize.height) / 2)
                configured.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            // Status dot in bottom-right corner
            let dotSize: CGFloat = 6
            let dotRect = NSRect(x: rect.width - dotSize - 1, y: 1,
                                 width: dotSize, height: dotSize)
            let dotColour: NSColor
            switch state {
            case .active:     dotColour = .systemGreen
            case .inactive:   dotColour = .systemGray
            case .activating: dotColour = .systemOrange
            }
            dotColour.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        img.isTemplate = false // Keep the coloured dot
        button.image = img
        button.title = ""
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        // Status
        if isActivating {
            menu.addItem(withTitle: "Activating...", action: nil, keyEquivalent: "").isEnabled = false
        } else if isActive {
            let hdrStr = hdrMode ? " 16-bit" : ""
            let scaleStr = scaleFactor > 2.0 ? " \(Self.formatScale(scaleFactor))" : ""
            if let t = manager.targetDisplay {
                menu.addItem(withTitle: "HiDPI Active (\(t.width)x\(t.height)\(hdrStr)\(scaleStr))",
                             action: nil, keyEquivalent: "").isEnabled = false
            } else {
                menu.addItem(withTitle: "HiDPI Active", action: nil, keyEquivalent: "").isEnabled = false
            }
        } else if let err = manager.lastError {
            menu.addItem(withTitle: err, action: nil, keyEquivalent: "").isEnabled = false
        } else {
            let available = manager.findTarget() != nil
            let statusText = available ? "Inactive (4K display available)" : "No 4K display found"
            menu.addItem(withTitle: statusText, action: nil, keyEquivalent: "").isEnabled = false
        }

        menu.addItem(.separator())

        // Activate / Deactivate
        let toggleTitle = isActive ? "Deactivate" : "Activate"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleActive), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !isActivating && (isActive || manager.findTarget() != nil)
        menu.addItem(toggle)

        // 16-bit compositor pipeline (physical panel output remains 10-bit)
        let hdr = NSMenuItem(title: "16-bit Compositing", action: #selector(toggleHDR), keyEquivalent: "")
        hdr.target = self
        hdr.state = hdrMode ? .on : .off
        hdr.isEnabled = !isActivating
        menu.addItem(hdr)

        // Brightness slider (only shown when the DDC service has been matched)
        if isActive && brightness.isAvailable {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Brightness", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let sliderItem = NSMenuItem()
            let view = BrightnessSliderView(initial: _brightness) { [weak self] value in
                self?.handleBrightnessSlider(value)
            }
            sliderItem.view = view
            menu.addItem(sliderItem)

            let shortcutsTitle = "Brightness Shortcuts: \(brightnessDownCombo.displayString)  \(brightnessUpCombo.displayString)"
            let shortcutsItem = NSMenuItem(title: shortcutsTitle,
                                           action: #selector(openShortcuts),
                                           keyEquivalent: "")
            shortcutsItem.target = self
            menu.addItem(shortcutsItem)
            menu.addItem(.separator())
        }

        // Scale factor submenu
        // The scale factor is the ratio of render buffer pixels to physical pixels.
        // Mode (logical) = physical * scale / 2. Backing (render) = mode * 2 = physical * scale.
        //   2x:  logical 3840x2160, render 7680x4320  (standard HiDPI)
        //   2.5x: logical 4800x2700, render 9600x5400
        //   4x:  logical 7680x4320, render 15360x8640
        let scaleMenu = NSMenu()
        let currentScale = scaleFactor
        let physW = manager.targetDisplay.map { Double($0.width) } ?? 3840.0
        let physH = manager.targetDisplay.map { Double($0.height) } ?? 2160.0
        for s in Self.scaleOptions {
            let logW = Int((physW * s / 2.0).rounded())
            let logH = Int((physH * s / 2.0).rounded())
            let tag = Self.formatScale(s)
            let label = s == 2.0
                ? "\(tag) \(logW)x\(logH) (standard)"
                : "\(tag) \(logW)x\(logH)"
            let item = NSMenuItem(title: label, action: #selector(setScale(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(s * 100)  // encode as int: 2.25 -> 225
            item.state = abs(currentScale - s) < 0.01 ? .on : .off
            item.isEnabled = !isActivating
            scaleMenu.addItem(item)
        }
        let scaleItem = NSMenuItem(title: "Scale Factor", action: nil, keyEquivalent: "")
        scaleItem.submenu = scaleMenu
        menu.addItem(scaleItem)

        // Font smoothing submenu
        let fontMenu = NSMenu()
        let currentSmoothing = CFPreferencesCopyValue(
            "AppleFontSmoothing" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? Int
        let labels = ["0 - Off", "1 - Light", "2 - Medium", "3 - Strong"]
        for i in 0...3 {
            let item = NSMenuItem(title: labels[i], action: #selector(setFontSmoothing(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = currentSmoothing == i ? .on : .off
            fontMenu.addItem(item)
        }
        let fontItem = NSMenuItem(title: "Font Smoothing", action: nil, keyEquivalent: "")
        fontItem.submenu = fontMenu
        menu.addItem(fontItem)

        // Start at Login
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "force-hidpi v\(AppDelegate.appVersion)", action: #selector(openBlog), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit", action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Actions

    private func activate() {
        isActivating = true
        setStatusIcon(.activating)
        rebuildMenu()
        manager.activate(hdrMode: hdrMode, scaleFactor: scaleFactor) { [weak self] success in
            guard let self else { return }
            self.isActivating = false
            self.isActive = success
            self.activationCompletedAt = Date()
            if success, let target = self.manager.targetDisplay {
                if self.brightness.resolve(displayID: target.displayID) {
                    // Restore the last known brightness value to the display so
                    // it matches the slider's initial position.
                    self.brightness.setBrightness(self._brightness)
                }
            } else {
                self.brightness.invalidate()
            }
            self.setStatusIcon(success ? .active : .inactive)
            self.rebuildMenu()
        }
    }

    @objc private func toggleActive() {
        if isActive {
            manager.deactivate()
            brightness.invalidate()
            isActive = false
            // resetStatusItem will be called by handleDisplayChange notification
        } else {
            activate()
        }
    }

    @objc private func toggleHDR() {
        guard !isActivating else { return }
        hdrMode.toggle()
        if isActive { reactivate() } else { rebuildMenu() }
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        guard !isActivating else { return }
        let newScale = Double(sender.tag) / 100.0
        guard abs(newScale - scaleFactor) > 0.01 else { return }
        print("setScale: \(Self.formatScale(scaleFactor)) -> \(Self.formatScale(newScale))")
        scaleFactor = newScale
        if isActive { reactivate() } else { rebuildMenu() }
    }

    /// Format a scale factor for display, dropping unnecessary trailing zeros.
    private static func formatScale(_ s: Double) -> String {
        s.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(s))x"
            : "\(String(format: "%g", s))x"
    }

    /// Tear down and re-establish the virtual display with current settings.
    /// Inserts a delay between deactivate and activate so the display system
    /// has time to settle (findTarget relies on accurate display enumeration).
    private func reactivate() {
        isActivating = true
        setStatusIcon(.activating)
        rebuildMenu()
        manager.deactivate()
        isActive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.activate()
        }
    }

    // MARK: - Brightness

    private func handleBrightnessSlider(_ value: Float) {
        _brightness = max(0, min(1, value))
        brightness.setBrightness(_brightness)
        schedulePrefsSave()
    }

    /// Coalesce plist writes so a slider drag at 60Hz produces one save, not
    /// sixty. 300ms matches the feel of a user "settling" on a value.
    private func schedulePrefsSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePrefs() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func stepBrightness(by delta: Float) {
        guard brightness.isAvailable else { return }
        let new = max(0, min(1, _brightness + delta))
        guard new != _brightness else { return }
        _brightness = new
        brightness.setBrightness(new)
        savePrefs()
        // Reflect the change in any open menu slider immediately.
        if let menu = statusItem?.menu {
            for item in menu.items {
                if let view = item.view as? BrightnessSliderView {
                    view.setValue(new)
                    break
                }
            }
        }
    }

    func registerHotKeys() {
        brightnessUpHotKey = HotKey(combo: _brightnessUpCombo) { [weak self] in
            self?.stepBrightness(by: Self.brightnessStep)
        }
        brightnessDownHotKey = HotKey(combo: _brightnessDownCombo) { [weak self] in
            self?.stepBrightness(by: -Self.brightnessStep)
        }
    }

    @objc private func openShortcuts() {
        if shortcutWindowController == nil {
            shortcutWindowController = ShortcutWindowController(delegate: self)
        }
        shortcutWindowController?.show()
    }

    @objc private func setFontSmoothing(_ sender: NSMenuItem) {
        let value = sender.tag
        // Write to -currentHost -globalDomain (same as defaults -currentHost -g)
        let key = "AppleFontSmoothing"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["-currentHost", "write", "-g", key, "-int", "\(value)"]
        try? task.run()
        task.waitUntilExit()
        rebuildMenu()
    }

    // MARK: - Login item

    private static let plistName = "com.force-hidpi.plist"
    private static let launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    private static let plistPath = launchAgentDir.appendingPathComponent(plistName)

    private func isLoginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: Self.plistPath.path)
    }

    @objc private func toggleLoginItem() {
        let uid = getuid()
        if isLoginItemEnabled() {
            shell("/bin/launchctl", "bootout", "gui/\(uid)/com.force-hidpi")
            try? FileManager.default.removeItem(at: Self.plistPath)
            print("Login item disabled")
        } else {
            let binaryPath = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
                .resolvingSymlinksInPath().path
            let escapedPath = binaryPath
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key><string>com.force-hidpi</string>
                    <key>ProgramArguments</key><array><string>\(escapedPath)</string></array>
                    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
                    <key>StandardOutPath</key><string>/tmp/force-hidpi.log</string>
                    <key>StandardErrorPath</key><string>/tmp/force-hidpi.log</string>
                    <key>ProcessType</key><string>Interactive</string>
                </dict>
                </plist>
                """
            do {
                try FileManager.default.createDirectory(at: Self.launchAgentDir,
                                                         withIntermediateDirectories: true)
                try plist.write(to: Self.plistPath, atomically: true, encoding: .utf8)
                print("Login item enabled (will start at next login): \(binaryPath)")
            } catch {
                print("error: failed to write LaunchAgent plist: \(error.localizedDescription)")
            }
        }
        rebuildMenu()
    }

    @discardableResult
    private func shell(_ args: String...) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: args[0])
        task.arguments = Array(args.dropFirst())
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    @objc private func openBlog() {
        NSWorkspace.shared.open(URL(string: "https://smcleod.net/2026/03/new-apple-silicon-m4-m5-hidpi-limitation-on-4k-external-displays/")!)
    }

    @objc private func doQuit() {
        NSApp.terminate(nil)
    }
}
