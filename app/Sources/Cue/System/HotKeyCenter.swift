import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey — no Accessibility
/// permission needed. Hotkeys are grouped so whole sets can be swapped.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry { var ref: EventHotKeyRef; var group: String; var handler: () -> Void }
    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    var paused = false   // set while recording a shortcut

    private init() {}

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if status == noErr {
                let id = hk.id
                DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        guard !paused, let e = entries[id] else { return }
        e.handler()
    }

    /// Returns false if macOS refused the combo (usually: taken by another app).
    @discardableResult
    func register(_ combo: KeyCombo, group: String, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x43554521), id: id) // 'CUE!'
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        entries[id] = Entry(ref: ref, group: group, handler: handler)
        return true
    }

    func unregister(group: String) {
        for (id, e) in entries where e.group == group {
            UnregisterEventHotKey(e.ref)
            entries.removeValue(forKey: id)
        }
    }
}
