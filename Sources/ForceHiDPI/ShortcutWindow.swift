// ShortcutWindow.swift
//
// Minimal preferences window for rebinding the brightness up/down hotkeys.
// Click a recorder, then press any modifier + key combination to assign it.

import AppKit
import Carbon.HIToolbox

final class ShortcutWindowController: NSWindowController, NSWindowDelegate {
    private weak var delegate: AppDelegate?
    private var upRecorder: ShortcutRecorderView!
    private var downRecorder: ShortcutRecorderView!

    init(delegate: AppDelegate) {
        self.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Brightness Shortcuts"
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refreshFromDelegate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshFromDelegate() {
        guard let delegate else { return }
        upRecorder.combo = delegate.brightnessUpCombo
        downRecorder.combo = delegate.brightnessDownCombo
    }

    // MARK: - Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let intro = NSTextField(wrappingLabelWithString:
            "Click a shortcut, then press any modifier + key to assign it. Press Escape to cancel.")
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        intro.textColor = .secondaryLabelColor

        let upLabel = NSTextField(labelWithString: "Brightness up:")
        let downLabel = NSTextField(labelWithString: "Brightness down:")

        upRecorder = ShortcutRecorderView()
        upRecorder.onCapture = { [weak self] combo in
            self?.delegate?.brightnessUpCombo = combo
        }
        downRecorder = ShortcutRecorderView()
        downRecorder.onCapture = { [weak self] combo in
            self?.delegate?.brightnessDownCombo = combo
        }

        let resetButton = NSButton(title: "Reset to Defaults",
                                   target: self,
                                   action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded

        for v: NSView in [intro, upLabel, downLabel, upRecorder, downRecorder, resetButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            upLabel.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 16),
            upLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            upLabel.widthAnchor.constraint(equalToConstant: 120),

            upRecorder.centerYAnchor.constraint(equalTo: upLabel.centerYAnchor),
            upRecorder.leadingAnchor.constraint(equalTo: upLabel.trailingAnchor, constant: 8),
            upRecorder.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            upRecorder.heightAnchor.constraint(equalToConstant: 24),

            downLabel.topAnchor.constraint(equalTo: upLabel.bottomAnchor, constant: 12),
            downLabel.leadingAnchor.constraint(equalTo: upLabel.leadingAnchor),
            downLabel.widthAnchor.constraint(equalToConstant: 120),

            downRecorder.centerYAnchor.constraint(equalTo: downLabel.centerYAnchor),
            downRecorder.leadingAnchor.constraint(equalTo: upRecorder.leadingAnchor),
            downRecorder.trailingAnchor.constraint(equalTo: upRecorder.trailingAnchor),
            downRecorder.heightAnchor.constraint(equalToConstant: 24),

            resetButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            resetButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    @objc private func resetDefaults() {
        guard let delegate else { return }
        delegate.brightnessUpCombo = HotKey.Combo(
            keyCode: UInt32(kVK_PageUp),
            carbonModifiers: UInt32(controlKey) | UInt32(cmdKey)
        )
        delegate.brightnessDownCombo = HotKey.Combo(
            keyCode: UInt32(kVK_PageDown),
            carbonModifiers: UInt32(controlKey) | UInt32(cmdKey)
        )
        refreshFromDelegate()
    }

    func windowWillClose(_ notification: Notification) {
        upRecorder?.cancelRecording()
        downRecorder?.cancelRecording()
    }
}

// MARK: - Recorder view

final class ShortcutRecorderView: NSView {
    var combo: HotKey.Combo? {
        didSet { updateLabel() }
    }
    var onCapture: ((HotKey.Combo) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var localMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    func cancelRecording() {
        isRecording = false
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        layer?.borderColor = NSColor.separatorColor.cgColor
        updateLabel()
    }

    private func startRecording() {
        isRecording = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        label.stringValue = "Type shortcut…"

        // Intercept keyDown locally so we don't trigger other app actions
        // while the window is frontmost.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .keyDown {
                if Int(event.keyCode) == kVK_Escape {
                    self.cancelRecording()
                    return nil
                }
                let carbonMods = Self.carbonModifiers(from: event.modifierFlags)
                // Require at least one modifier to avoid grabbing raw alphanumeric keys.
                if carbonMods == 0 { return nil }
                let new = HotKey.Combo(keyCode: UInt32(event.keyCode),
                                       carbonModifiers: carbonMods)
                self.combo = new
                self.onCapture?(new)
                self.cancelRecording()
                return nil
            }
            return event
        }
    }

    private func updateLabel() {
        if let c = combo {
            label.stringValue = c.displayString
            label.textColor = .labelColor
        } else {
            label.stringValue = "Click to record"
            label.textColor = .secondaryLabelColor
        }
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }
}
