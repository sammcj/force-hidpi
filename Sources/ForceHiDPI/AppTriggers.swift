// AppTriggers.swift
//
// Watches for user-listed applications and reports when any of them is
// running, so HiDPI can be paused for apps that misbehave on the virtual
// display (games, screen recorders, colour-critical tools).

import AppKit
import UniformTypeIdentifiers

struct TriggerApp: Equatable {
    let name: String
    /// Nil for unbundled executables, which are matched by path instead.
    let bundleID: String?
    let path: String
    var enabled = true

    init?(url: URL) {
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        self.init(name: name, bundleID: bundle?.bundleIdentifier, path: url.path)
    }

    init?(running app: NSRunningApplication) {
        guard let url = app.bundleURL ?? app.executableURL else { return nil }
        self.init(name: app.localizedName ?? url.lastPathComponent,
                  bundleID: app.bundleIdentifier, path: url.path)
    }

    init?(plist: [String: Any]) {
        guard let name = plist["name"] as? String, let path = plist["path"] as? String
        else { return nil }
        self.init(name: name, bundleID: plist["bundleID"] as? String, path: path)
        enabled = plist["enabled"] as? Bool ?? true
    }

    fileprivate init?(name: String, bundleID: String?, path: String) {
        guard !path.isEmpty else { return nil }
        self.name = name
        self.bundleID = bundleID
        self.path = path
    }

    var plist: [String: Any] {
        var dict: [String: Any] = ["name": name, "path": path, "enabled": enabled]
        if let bundleID { dict["bundleID"] = bundleID }
        return dict
    }

    /// Steam, for one, runs from a different path than the one it's installed at.
    func isSameApp(as other: TriggerApp) -> Bool {
        path == other.path || (bundleID != nil && bundleID == other.bundleID)
    }

    /// Bundle ID wins so a moved or updated app still matches.
    func matches(_ app: NSRunningApplication) -> Bool {
        guard enabled else { return false }
        if let bundleID, let other = app.bundleIdentifier { return bundleID == other }
        return app.bundleURL?.path == path || app.executableURL?.path == path
    }
}

final class AppTriggerWatcher: NSObject, NSMenuDelegate {
    /// Grace before reporting the last listed app gone, so a launcher that
    /// quits and immediately relaunches the real binary stays triggered.
    private static let releaseDelay: TimeInterval = 1.0
    /// Minimum gap between a release and the next trigger. Each transition is
    /// a full display reconfiguration, so an app that keeps relaunching can't
    /// cycle the displays faster than this.
    private static let retriggerCooldown: TimeInterval = 10.0

    /// Used until the user's list is first saved; removing an entry sticks.
    /// Steam ships disabled: it usually runs in the background, which would
    /// keep HiDPI off whenever it's open rather than only during a game.
    static let defaultApps: [TriggerApp] = {
        var steam = TriggerApp(name: "Steam", bundleID: "com.valvesoftware.steam",
                               path: "/Applications/Steam.app")
        steam?.enabled = false
        let steamLink = TriggerApp(name: "Steam Link", bundleID: "com.valvesoftware.SteamLink17",
                                   path: "/Applications/Steam Link.app")
        return [steam, steamLink].compactMap { $0 }
    }()

    var apps: [TriggerApp] = defaultApps {
        didSet {
            updateObservation()
            evaluate()
        }
    }

    /// Also pause for any app declaring a games category, the declaration
    /// macOS uses for Game Mode eligibility. Unlike Game Mode itself this
    /// fires at launch, before the game goes fullscreen, so tearing down the
    /// virtual display can't knock the game out of fullscreen and loop.
    var pauseForGames = true {
        didSet {
            updateObservation()
            evaluate()
        }
    }

    /// True from the moment a listed app launches (or `retriggerCooldown`
    /// after the last release) until `releaseDelay` after the last one quits.
    private(set) var isTriggered = false
    /// Name of a matching app currently running, for the menu status line.
    private(set) var runningAppName: String?
    var onTriggerChange: ((Bool) -> Void)?
    var onSettingsChanged: (() -> Void)?
    /// A `--pause-while` wrapper asked for a pause. The handler must call
    /// `acknowledgeHolds` once HiDPI is off so the wrapper can launch.
    var onHoldRequested: (() -> Void)?

    private var observation: NSKeyValueObservation?
    private var evaluateScheduled = false
    private var pendingRelease: DispatchWorkItem?
    private var pendingTrigger: DispatchWorkItem?
    private var releasedAt: Date?
    /// Keyed by bundle URL so each app's Info.plist is read once, not on
    /// every launch event system-wide.
    private var gameCache: [URL: Bool] = [:]
    /// Wrapper PIDs, which become the game's PID after exec. Holds always
    /// trigger, whatever the list or games toggle says.
    private var holds: [pid_t: (name: String, exit: DispatchSourceProcess)] = [:]
    private var pendingAcks: Set<pid_t> = []
    private var holdObserver: Any?
    private var settleUntil = DispatchTime.now()

    override init() {
        super.init()
        updateObservation()
        evaluate()
        holdObserver = DistributedNotificationCenter.default().addObserver(
            forName: PauseHold.requestName, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.object as? String).flatMap(pid_t.init), pid > 0 else { return }
            self?.addHold(pid: pid, name: note.userInfo?["name"] as? String ?? "game")
        }
    }

    deinit {
        if let holdObserver { DistributedNotificationCenter.default().removeObserver(holdObserver) }
    }

    private func addHold(pid: pid_t, name: String) {
        pendingAcks.insert(pid)
        if holds[pid] != nil {
            onHoldRequested?()
            return
        }
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in self?.removeHold(pid) }
        exit.resume()
        // A process that died before the source was armed never fires it.
        guard kill(pid, 0) == 0 else {
            exit.cancel()
            pendingAcks.remove(pid)
            return
        }
        print("App trigger: pause requested for \(name) (pid \(pid))")
        holds[pid] = (name, exit)
        // A deliberate request, so skip the relaunch cooldown. The handler
        // runs before evaluate so it, not the app trigger, does the teardown.
        releasedAt = nil
        onHoldRequested?()
        evaluate()
    }

    private func removeHold(_ pid: pid_t) {
        holds.removeValue(forKey: pid)?.exit.cancel()
        pendingAcks.remove(pid)
        evaluate()
    }

    /// Call on every HiDPI teardown. WindowServer needs a moment afterwards,
    /// and a game launched inside it can see a half-settled display layout.
    func noteTeardown() {
        settleUntil = .now() + 1.0
    }

    /// Tells waiting wrappers HiDPI is off, once the last teardown has settled.
    func acknowledgeHolds() {
        guard !pendingAcks.isEmpty else { return }
        let pids = pendingAcks
        pendingAcks.removeAll()
        DispatchQueue.main.asyncAfter(deadline: max(settleUntil, .now())) {
            for pid in pids {
                DistributedNotificationCenter.default().postNotificationName(
                    PauseHold.ackName, object: String(pid), userInfo: nil, deliverImmediately: true)
            }
        }
    }

    private var isWatching: Bool { pauseForGames || apps.contains(where: \.enabled) }

    /// KVO on `runningApplications` covers every app, including ones that
    /// never post the NSWorkspace launch notifications. Nothing is observed
    /// while there is nothing to match, so the feature then costs nothing.
    private func updateObservation() {
        if !isWatching {
            observation = nil
        } else if observation == nil {
            observation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
                self?.scheduleEvaluate()
            }
        }
    }

    /// Launches arrive in bursts (helpers, XPC services), so collapse them
    /// into one scan on the next main-queue turn. `runningApplications` only
    /// changes while the main run loop runs, so this is always on main.
    private func scheduleEvaluate() {
        guard !evaluateScheduled else { return }
        evaluateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.evaluateScheduled = false
            self?.evaluate()
        }
    }

    private func evaluate() {
        runningAppName = holds.values.first?.name
        if runningAppName == nil, isWatching {
            for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
                if let name = triggerName(for: app) {
                    runningAppName = name
                    break
                }
            }
        }

        if runningAppName != nil {
            pendingRelease?.cancel()
            pendingRelease = nil
            let cooldownLeft = releasedAt.map { Self.retriggerCooldown - Date().timeIntervalSince($0) } ?? 0
            if cooldownLeft <= 0 {
                setTriggered(true)
            } else if !isTriggered && pendingTrigger == nil {
                print("App trigger: \(runningAppName ?? "listed app") running, deferring \(Int(cooldownLeft.rounded(.up)))s")
                // Re-checks rather than firing blind: the app may have quit.
                let trigger = DispatchWorkItem { [weak self] in
                    self?.pendingTrigger = nil
                    self?.releasedAt = nil
                    self?.evaluate()
                }
                pendingTrigger = trigger
                DispatchQueue.main.asyncAfter(deadline: .now() + cooldownLeft, execute: trigger)
            }
            return
        }
        pendingTrigger?.cancel()
        pendingTrigger = nil
        if isTriggered && pendingRelease == nil {
            let release = DispatchWorkItem { [weak self] in
                self?.pendingRelease = nil
                self?.setTriggered(false)
            }
            pendingRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDelay, execute: release)
        }
    }

    private func triggerName(for app: NSRunningApplication) -> String? {
        if let listed = apps.first(where: { $0.matches(app) }) { return listed.name }
        if pauseForGames, isGame(app) { return app.localizedName ?? "a game" }
        return nil
    }

    /// Game launchers that declare the games category but are mostly browsed.
    private static let notGames: Set<String> = ["com.apple.games"]

    /// Only regular (Dock) apps count, so a background helper that copies a
    /// game's Info.plist category can't hold the pause.
    private func isGame(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, let url = app.bundleURL,
              !Self.notGames.contains(app.bundleIdentifier ?? "")
        else { return false }
        if let cached = gameCache[url] { return cached }
        let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        // "public.app-category.games" plus its subcategories, e.g. "...action-games".
        let game = category.map {
            $0 == "public.app-category.games"
                || ($0.hasPrefix("public.app-category.") && $0.hasSuffix("-games"))
        } ?? false
        gameCache[url] = game
        return game
    }

    private func setTriggered(_ value: Bool) {
        guard value != isTriggered else { return }
        isTriggered = value
        if !value { releasedAt = Date() }
        print("App trigger: \(value ? "\(runningAppName ?? "listed app") running" : "no matching apps running")")
        onTriggerChange?(value)
    }

    /// Re-adding an existing entry enables it rather than duplicating it.
    private func add(_ app: TriggerApp) {
        if let index = apps.firstIndex(where: { $0.isSameApp(as: app) }) {
            apps[index].enabled = true
        } else {
            apps.append(app)
        }
        onSettingsChanged?()
    }

    // MARK: - Menu

    /// The submenu is filled in `menuNeedsUpdate`, so the running-app scan
    /// only happens when the user actually opens it.
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Pause For Apps", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        item.submenu = submenu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let games = NSMenuItem(title: "All Games", action: #selector(toggleGames), keyEquivalent: "")
        games.target = self
        games.state = pauseForGames ? .on : .off
        games.toolTip = "Apps that declare a games category in their Info.plist"
        menu.addItem(games)
        menu.addItem(.separator())

        let removeMenu = NSMenu()
        for (index, app) in apps.enumerated() {
            let entry = NSMenuItem(title: app.name, action: #selector(toggleApp(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = app.enabled ? .on : .off
            entry.toolTip = app.path
            menu.addItem(entry)

            let remove = NSMenuItem(title: app.name, action: #selector(removeApp(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = index
            removeMenu.addItem(remove)
        }
        if !apps.isEmpty { menu.addItem(.separator()) }

        let browse = NSMenuItem(title: "Add Application...", action: #selector(browseForApp), keyEquivalent: "")
        browse.target = self
        menu.addItem(browse)

        let runningMenu = NSMenu()
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .compactMap(TriggerApp.init(running:))
            .filter { candidate in !apps.contains { $0.isSameApp(as: candidate) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for candidate in candidates {
            let item = NSMenuItem(title: candidate.name, action: #selector(addRunningApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.path
            item.toolTip = candidate.path
            runningMenu.addItem(item)
        }
        let runningItem = NSMenuItem(title: "Add Running App", action: nil, keyEquivalent: "")
        runningItem.submenu = runningMenu
        runningItem.isEnabled = !candidates.isEmpty
        menu.addItem(runningItem)

        let removeItem = NSMenuItem(title: "Remove App", action: nil, keyEquivalent: "")
        removeItem.submenu = removeMenu
        removeItem.isEnabled = !apps.isEmpty
        menu.addItem(removeItem)

        menu.addItem(.separator())
        let steam = NSMenuItem(title: "Copy Steam Launch Option", action: #selector(copyLaunchOption),
                               keyEquivalent: "")
        steam.target = self
        steam.toolTip = "Pauses HiDPI before the game starts. Paste into Steam: game > Properties > Launch Options"
        menu.addItem(steam)
    }

    @objc private func copyLaunchOption() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PauseHold.steamLaunchOption, forType: .string)
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard apps.indices.contains(sender.tag) else { return }
        apps[sender.tag].enabled.toggle()
        onSettingsChanged?()
    }

    @objc private func removeApp(_ sender: NSMenuItem) {
        guard apps.indices.contains(sender.tag) else { return }
        apps.remove(at: sender.tag)
        onSettingsChanged?()
    }

    @objc private func toggleGames() {
        pauseForGames.toggle()
        onSettingsChanged?()
    }

    @objc private func addRunningApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let running = NSWorkspace.shared.runningApplications.first(where: {
                  ($0.bundleURL ?? $0.executableURL)?.path == path
              }),
              let app = TriggerApp(running: running)
        else { return }
        add(app)
    }

    @objc private func browseForApp() {
        let panel = NSOpenPanel()
        panel.title = "Pause HiDPI While Running"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        panel.urls.compactMap(TriggerApp.init(url:)).forEach(add)
    }
}
