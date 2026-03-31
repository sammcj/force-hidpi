import AppKit

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

private let prefs = UserDefaults(suiteName: "com.force-hidpi")!

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let appVersion = "1.0.1"
    private var statusItem: NSStatusItem!
    private let manager = DisplayManager()
    private var isActive = false
    private var isActivating = false
    fileprivate var retainedSources: [Any] = []
    private var displayObserver: Any?
    private var profileObserver: Any?

    private var hdrMode: Bool {
        get { prefs.object(forKey: "hdrMode") as? Bool ?? true }
        set { prefs.set(newValue, forKey: "hdrMode") }
    }

    private var scaleFactor: UInt32 {
        get { UInt32(prefs.object(forKey: "scaleFactor") as? Int ?? 2) }
        set { prefs.set(Int(newValue), forKey: "scaleFactor") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        if isActive {
            if manager.findTarget() == nil {
                manager.deactivate()
                isActive = false
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
            let scaleStr = scaleFactor > 2 ? " \(scaleFactor)x" : ""
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

        // 16-bit compositing
        let hdr = NSMenuItem(title: "16-bit Compositing", action: #selector(toggleHDR), keyEquivalent: "")
        hdr.target = self
        hdr.state = hdrMode ? .on : .off
        hdr.isEnabled = !isActivating
        menu.addItem(hdr)

        // Scale factor submenu
        let scaleMenu = NSMenu()
        for s: UInt32 in [2, 3, 4] {
            let label = s == 2 ? "2x (standard)" : "\(s)x (supersample)"
            let item = NSMenuItem(title: label, action: #selector(setScale(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(s)
            item.state = scaleFactor == s ? .on : .off
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
            self.setStatusIcon(success ? .active : .inactive)
            self.rebuildMenu()
        }
    }

    @objc private func toggleActive() {
        if isActive {
            manager.deactivate()
            isActive = false
            // resetStatusItem will be called by handleDisplayChange notification
        } else {
            activate()
        }
    }

    @objc private func toggleHDR() {
        guard !isActivating else { return }
        hdrMode.toggle()
        if isActive {
            manager.deactivate()
            isActive = false
            activate()
        }
        rebuildMenu()
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        guard !isActivating else { return }
        let newScale = UInt32(sender.tag)
        guard newScale != scaleFactor else { return }
        scaleFactor = newScale
        if isActive {
            manager.deactivate()
            isActive = false
            activate()
        }
        rebuildMenu()
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
