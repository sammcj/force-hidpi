// HotKey.swift
//
// Global hotkeys via Carbon's RegisterEventHotKey. This path, unlike
// NSEvent.addGlobalMonitorForEvents, does not require the Accessibility
// permission — the dispatcher is in-process. Carbon itself is still fully
// supported on macOS 26.x; Apple has not deprecated these functions.

import AppKit
import Carbon.HIToolbox

/// A Carbon-backed global hotkey. The handler fires on every keyDown.
final class HotKey {
    /// Encodes a key combination. `keyCode` is a Carbon virtual keycode
    /// (`kVK_*` constants); `modifiers` packs Carbon modifier flags
    /// (`cmdKey`, `controlKey`, `optionKey`, `shiftKey`).
    struct Combo: Equatable, Codable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// Convert from an NSEvent (Cocoa modifier flags + keyCode) to a Carbon
        /// combo suitable for RegisterEventHotKey.
        init(keyCode: UInt32, carbonModifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = carbonModifiers
        }

        init(keyCode: UInt16, cocoaModifiers: NSEvent.ModifierFlags) {
            self.keyCode = UInt32(keyCode)
            var mods: UInt32 = 0
            if cocoaModifiers.contains(.command)  { mods |= UInt32(cmdKey) }
            if cocoaModifiers.contains(.option)   { mods |= UInt32(optionKey) }
            if cocoaModifiers.contains(.control)  { mods |= UInt32(controlKey) }
            if cocoaModifiers.contains(.shift)    { mods |= UInt32(shiftKey) }
            self.modifiers = mods
        }
    }

    private static var nextID: UInt32 = 1
    private static var registry: [UInt32: () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?

    private var eventHotKeyRef: EventHotKeyRef?
    private let id: UInt32

    init?(combo: Combo, handler: @escaping () -> Void) {
        Self.installEventHandlerOnce()

        let id = Self.nextID
        Self.nextID += 1
        self.id = id

        // 'FHDP' FourCharCode as the signature — unique to this app.
        let hotKeyID = EventHotKeyID(signature: 0x46484450, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode,
                                         combo.modifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return nil }
        self.eventHotKeyRef = ref
        Self.registry[id] = handler
    }

    deinit {
        if let ref = eventHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        Self.registry.removeValue(forKey: id)
    }

    // MARK: - Dispatcher

    private static func installEventHandlerOnce() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(),
                            { _, event, _ -> OSStatus in
                                var hk = EventHotKeyID()
                                let rc = GetEventParameter(event,
                                                           EventParamName(kEventParamDirectObject),
                                                           EventParamType(typeEventHotKeyID),
                                                           nil,
                                                           MemoryLayout<EventHotKeyID>.size,
                                                           nil,
                                                           &hk)
                                guard rc == noErr else { return rc }
                                if let handler = HotKey.registry[hk.id] {
                                    DispatchQueue.main.async { handler() }
                                }
                                return noErr
                            },
                            1,
                            &spec,
                            nil,
                            &eventHandler)
    }
}

// MARK: - Display helpers for Combo

extension HotKey.Combo {
    /// Returns "⌃⌘⇞" style string for the menu / settings UI.
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_PageUp:        return "⇞"
        case kVK_PageDown:      return "⇟"
        case kVK_Home:          return "↖"
        case kVK_End:           return "↘"
        case kVK_UpArrow:       return "↑"
        case kVK_DownArrow:     return "↓"
        case kVK_LeftArrow:     return "←"
        case kVK_RightArrow:    return "→"
        case kVK_Return:        return "↩"
        case kVK_Space:         return "Space"
        case kVK_Escape:        return "⎋"
        case kVK_Delete:        return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Tab:           return "⇥"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2"
        case kVK_F3:  return "F3";  case kVK_F4:  return "F4"
        case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8"
        case kVK_F9:  return "F9";  case kVK_F10: return "F10"
        case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            return translateFromCurrentLayout(keyCode: UInt16(keyCode)) ?? "Key \(keyCode)"
        }
    }

    /// Ask the current keyboard layout to translate a virtual keycode to a
    /// printable character. The layout data is owned by the input source, so
    /// we keep the source retained for the entire duration of the call.
    private static func translateFromCurrentLayout(keyCode: UInt16) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let cfData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        return CFDataGetBytePtr(cfData).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var deadKey: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout,
                                        keyCode,
                                        UInt16(kUCKeyActionDisplay),
                                        0,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKey,
                                        chars.count,
                                        &length,
                                        &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
