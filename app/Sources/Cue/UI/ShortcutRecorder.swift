import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click, then press a key combination. Esc cancels; ⌫ clears.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var requireModifier = false
    var placeholder = "Record shortcut"
    var allowClear = true

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Press keys…" : (combo?.display ?? placeholder))
                    .font(.system(size: 12, weight: combo == nil ? .regular : .semibold, design: .rounded))
                    .foregroundColor(recording ? .accentColor : (combo == nil ? .secondary : .primary))
                    .frame(minWidth: 110)
            }
            if allowClear, combo != nil, !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Remove shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        HotKeyCenter.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection(KeyCombo.relevant)
            if mods.isEmpty && e.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if mods.isEmpty && (e.keyCode == UInt16(kVK_Delete) || e.keyCode == UInt16(kVK_ForwardDelete)) && allowClear {
                combo = nil; stop(); return nil
            }
            guard let c = KeyCombo(event: e) else { return nil }
            if requireModifier && !c.isGlobalSafe { NSSound.beep(); return nil }
            combo = c
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        HotKeyCenter.shared.paused = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

extension Binding where Value == KeyCombo {
    /// Adapts a non-optional combo for ShortcutRecorder (clearing is ignored).
    var optional: Binding<KeyCombo?> {
        Binding<KeyCombo?>(get: { self.wrappedValue }, set: { if let v = $0 { self.wrappedValue = v } })
    }
}
