import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PresetsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?
    @State private var newName = ""
    @State private var capturing = false
    @State private var message: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.presets) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            Text(p.summary).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        .tag(p.id)
                    }
                    .onMove { model.presets.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 6) {
                    Button { deleteSelected() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                    Menu {
                        Button("Import…", action: importFile)
                        Button("Export All…", action: exportFile)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                }
                .padding(6)
            }
            .frame(width: 230)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                captureBox
                if let id = selection, let index = model.presets.firstIndex(where: { $0.id == id }) {
                    PresetDetail(preset: $model.presets[index])
                } else {
                    Spacer()
                    Text(model.presets.isEmpty
                         ? "Style a clip in Premiere (effects, keyframes, Motion…), select it, then capture it as a preset."
                         : "Select a preset to edit which effects and properties it applies.")
                        .foregroundColor(.secondary).frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var captureBox: some View {
        GroupBox {
            HStack {
                TextField("New preset name", text: $newName).textFieldStyle(.roundedBorder).onSubmit(capture)
                Button(capturing ? "Capturing…" : "Capture Selected Clip", action: capture)
                    .disabled(!model.bridgeState.isConnected || capturing)
            }
            if let message { Text(message).font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
        } label: {
            Label("Capture from Premiere", systemImage: "camera.metering.center.weighted")
        }
    }

    private func capture() {
        guard model.bridgeState.isConnected, !capturing else { return }
        capturing = true
        message = nil
        let name = newName
        Task { @MainActor in
            defer { capturing = false }
            do {
                let p = try await model.capturePreset(named: name)
                selection = p.id
                newName = ""
                message = "Captured \(p.summary)."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        model.presets.removeAll { $0.id == id }
        selection = nil
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Cue presets and macros.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportBundle().write(to: url) } catch { message = error.localizedDescription }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (p, m) = try model.importBundle(Data(contentsOf: url))
            message = "Imported \(p) presets and \(m) macros."
        } catch {
            message = "That file isn't a Cue export."
        }
    }
}

struct PresetDetail: View {
    @Binding var preset: Preset
    @EnvironmentObject var model: AppModel

    private var timing: Binding<String> {
        Binding(get: { preset.overrides?.keyframeTiming ?? "" },
                set: { v in var o = preset.overrides ?? PresetOverrides(); o.keyframeTiming = v.isEmpty ? nil : v; preset.overrides = o })
    }
    private var mode: Binding<String> {
        Binding(get: { preset.overrides?.keyframeMode ?? "" },
                set: { v in var o = preset.overrides ?? PresetOverrides(); o.keyframeMode = v.isEmpty ? nil : v; preset.overrides = o })
    }
    private var shortcut: Binding<KeyCombo?> {
        let id = preset.catalogItem.id
        return Binding(get: { model.usage.itemShortcuts[id] }, set: { model.setShortcut($0, for: id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $preset.name).textFieldStyle(.roundedBorder).font(.title3)
                ShortcutRecorder(combo: shortcut, requireModifier: true)
            }
            HStack(spacing: 16) {
                Picker("Timing", selection: timing) {
                    Text("Default").tag("")
                    Text("From clip start").tag("start")
                    Text("Stretch to clip").tag("stretch")
                    Text("Anchor to end").tag("end")
                }.frame(maxWidth: 240)
                Picker("Existing keyframes", selection: mode) {
                    Text("Default").tag("")
                    Text("Preserve").tag("preserve")
                    Text("Replace").tag("replace")
                }.frame(maxWidth: 240)
            }
            if let src = preset.media?["video"]?.clipName ?? preset.media?["audio"]?.clipName, !src.isEmpty {
                Text("Captured from \(src)").font(.caption).foregroundColor(.secondary)
            }
            List {
                ForEach(Array(preset.components.indices), id: \.self) { ci in
                    let c = $preset.components[ci]
                    DisclosureGroup {
                        ForEach(Array(c.wrappedValue.params.indices), id: \.self) { pi in
                            let p = c.params[pi]
                            HStack {
                                Toggle(isOn: Binding(get: { p.wrappedValue.isOn }, set: { p.wrappedValue.enabled = $0 })) {
                                    Text(p.wrappedValue.name)
                                }
                                .disabled(!c.wrappedValue.isOn)
                                Spacer()
                                Text(describe(p.wrappedValue)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            }
                        }
                    } label: {
                        Toggle(isOn: Binding(get: { c.wrappedValue.isOn }, set: { c.wrappedValue.enabled = $0 })) {
                            HStack {
                                Text(c.wrappedValue.displayName).fontWeight(.medium)
                                Text(c.wrappedValue.media == "audio" ? "Audio" : "Video").font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                if c.wrappedValue.intrinsic {
                                    Text("fixed effect").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Text("Fixed effects (Motion, Opacity, Volume) are written into the clip's own instance; only switched-on properties are applied, and keyframed ones on the target are preserved unless you choose Replace.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func describe(_ p: PresetParam) -> String {
        if let k = p.keyframes, !k.isEmpty { return "\(k.count) keyframe\(k.count == 1 ? "" : "s")" }
        guard let v = p.value, let t = v["t"]?.string else { return "" }
        let raw = v["v"]
        switch t {
        case "num":
            guard let d = raw?.double else { return "" }
            return d.rounded() == d ? String(Int(d)) : String(format: "%.2f", d)
        case "bool": return raw?.bool == true ? "On" : "Off"
        case "str": return raw?.string ?? ""
        case "point":
            let a = raw?.array ?? []
            return String(format: "%.3f, %.3f", a.first?.double ?? 0, a.dropFirst().first?.double ?? 0)
        case "color":
            let a = (raw?.array ?? []).map { $0.double ?? 0 }
            guard a.count >= 3 else { return "color" }
            let k: Double = a.prefix(3).contains(where: { $0 > 1 }) ? 1 : 255 // 0–1 or 0–255
            func c(_ x: Double) -> Int { max(0, min(255, Int((x * k).rounded()))) }
            return String(format: "#%02X%02X%02X", c(a[0]), c(a[1]), c(a[2]))
        default: return ""
        }
    }
}
