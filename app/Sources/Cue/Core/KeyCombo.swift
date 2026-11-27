import AppKit
import Carbon.HIToolbox

/// A key + modifier combination, recorded from a real key press.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt          // NSEvent.ModifierFlags raw value (device-independent bits only)
    var key: String              // display text for the key, captured at record time

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
        self.key = key
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let name = Self.name(for: event.keyCode) ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !name.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, key: name)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(Self.relevant) == flags
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    /// True when the combo is usable as a global shortcut (needs a modifier or a function key).
    var isGlobalSafe: Bool {
        !flags.isEmpty || (key.hasPrefix("F") && key.count > 1)
    }

    static func name(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌅"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        default: return nil
        }
    }

    // Common defaults
    static let optionSpace = KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.option], key: "Space")
    static func plain(_ code: Int, _ key: String, _ mods: NSEvent.ModifierFlags = []) -> KeyCombo {
        KeyCombo(keyCode: UInt16(code), modifiers: mods, key: key)
    }
}

/// Keyboard actions inside the search panel. Each can be rebound in Settings › Keys.
enum PanelAction: String, Codable, CaseIterable, Identifiable {
    case moveDown, moveUp, pageDown, pageUp, nextCategory, previousCategory,
         apply, applyKeepOpen, toggleFavorite, clearOrClose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveDown: return "Next result"
        case .moveUp: return "Previous result"
        case .pageDown: return "Jump down a page"
        case .pageUp: return "Jump up a page"
        case .nextCategory: return "Next category"
        case .previousCategory: return "Previous category"
        case .apply: return "Apply and close"
        case .applyKeepOpen: return "Apply and keep open"
        case .toggleFavorite: return "Toggle favorite"
        case .clearOrClose: return "Clear search / close"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .moveDown: return .plain(kVK_ANSI_N, "N", [.control])
        case .moveUp: return .plain(kVK_ANSI_P, "P", [.control])
        case .pageDown: return .plain(kVK_PageDown, "⇟")
        case .pageUp: return .plain(kVK_PageUp, "⇞")
        case .nextCategory: return .plain(kVK_Tab, "⇥")
        case .previousCategory: return .plain(kVK_Tab, "⇥", [.shift])
        case .apply: return .plain(kVK_Return, "↩")
        case .applyKeepOpen: return .plain(kVK_Return, "↩", [.option])
        case .toggleFavorite: return .plain(kVK_ANSI_D, "D", [.command])
        case .clearOrClose: return .plain(kVK_Escape, "⎋")
        }
    }

    /// Keys that always work for this action, regardless of the custom binding.
    var builtIn: [KeyCombo] {
        switch self {
        case .moveDown: return [.plain(kVK_DownArrow, "↓")]
        case .moveUp: return [.plain(kVK_UpArrow, "↑")]
        case .apply: return [.plain(kVK_ANSI_KeypadEnter, "⌅")]
        default: return []
        }
    }
}
