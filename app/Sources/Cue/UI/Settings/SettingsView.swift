import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            AppearanceTab().tabItem { Label("Appearance", systemImage: "paintpalette") }.tag("appearance")
            KeysTab().tabItem { Label("Keys", systemImage: "keyboard") }.tag("keys")
            ApplyTab().tabItem { Label("Applying", systemImage: "wand.and.stars") }.tag("apply")
            PresetsTab().tabItem { Label("Presets", systemImage: "slider.horizontal.3") }.tag("presets")
            MacrosTab().tabItem { Label("Macros", systemImage: "bolt") }.tag("macros")
            ConnectionTab().tabItem { Label("Connection", systemImage: "point.3.connected.trianglepath.dotted") }.tag("connection")
        }
        .frame(minWidth: 720, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .cueSelectSettingsTab)) { note in
            if let t = note.object as? String { tab = t }
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Open Cue") {
                LabeledContent("Hotkey") {
                    ShortcutRecorder(combo: $model.prefs.openHotKey.optional, requireModifier: true, allowClear: false)
                }
                if let p = model.openHotKeyProblem {
                    Text(p).font(.caption).foregroundColor(.red)
                }
                Toggle("Launch Cue at login", isOn: $model.prefs.launchAtLogin)
            }
            Section("When applying") {
                Toggle("Close the search bar after applying", isOn: $model.prefs.closeAfterApply)
                Toggle("Show a confirmation toast", isOn: $model.prefs.showHUD)
                Toggle("If nothing is selected, use the clip under the playhead", isOn: $model.prefs.fallbackToPlayhead)
            }
            Section("Results") {
                Stepper("Visible rows: \(model.prefs.visibleRows)", value: $model.prefs.visibleRows, in: 4...14)
                Stepper("Remember \(model.prefs.maxRecents) recent items", value: $model.prefs.maxRecents, in: 3...40)
                Toggle("Show internal match names", isOn: $model.prefs.showMatchNames)
                HStack {
                    Text("Tip: type v: a: t: p: m: f: or r: to jump straight to a category.")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Clear Recents") { model.clearRecents() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

struct AppearanceTab: View {
    @EnvironmentObject var model: AppModel

    private var accent: Binding<Color> {
        Binding(get: { Theme.resolve(model.prefs).accent },
                set: { model.prefs.accentHex = $0.hexString })
    }

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                    ForEach(Theme.all) { t in
                        ThemeCard(theme: t, selected: model.prefs.themeID == t.id)
                            .onTapGesture { model.prefs.themeID = t.id; model.prefs.accentHex = nil }
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    ColorPicker("Accent color", selection: accent, supportsOpacity: false)
                    if model.prefs.accentHex != nil {
                        Button("Use theme accent") { model.prefs.accentHex = nil }
                    }
                }
                Toggle("Translucent background", isOn: $model.prefs.translucent)
            }
            Section("Layout") {
                LabeledContent("Width") {
                    Slider(value: $model.prefs.panelWidth, in: 480...960, step: 20) { EmptyView() }
                        .frame(width: 240)
                    Text("\(Int(model.prefs.panelWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                LabeledContent("Text size") {
                    Slider(value: $model.prefs.fontScale, in: 0.85...1.3, step: 0.05) { EmptyView() }
                        .frame(width: 240)
                    Text("\(Int(model.prefs.fontScale * 100))%").monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                Toggle("Compact rows", isOn: $model.prefs.compactRows)
                Toggle("Show category bar", isOn: $model.prefs.showCategoryBar)
                Toggle("Show key hints in the footer", isOn: $model.prefs.showFooterHints)
            }
            Section("Preview") {
                PreviewPanel().environmentObject(model)
                    .frame(height: 170)
            }
        }
        .formStyle(.grouped)
    }
}

struct ThemeCard: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.background)
                .overlay(
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(theme.text.opacity(0.8)).frame(width: 52, height: 6)
                        RoundedRectangle(cornerRadius: 4).fill(theme.selection).frame(height: 12)
                            .overlay(alignment: .leading) { Circle().fill(theme.accent).frame(width: 7).padding(.leading, 4) }
                        RoundedRectangle(cornerRadius: 3).fill(theme.secondary.opacity(0.6)).frame(width: 40, height: 5)
                    }.padding(8)
                )
                .frame(height: 58)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? theme.accent : Color.secondary.opacity(0.25), lineWidth: selected ? 2.5 : 1))
            Text(theme.name).font(.caption.weight(selected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
    }
}

/// Static look-alike of the search panel for the Appearance tab.
struct PreviewPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let t = Theme.resolve(model.prefs)
        let scale = CGFloat(model.prefs.fontScale)
        let rowH = SearchView.rowHeight(model.prefs)
        let items: [SearchResult] = [
            SearchResult(item: CatalogItem(kind: .videoEffect, id: "1", name: "Gaussian Blur", matchName: "AE.ADBE Gaussian Blur 2", category: "Blur & Sharpen"),
                         highlights: [0, 9], isFavorite: true, isRecent: true, shortcut: nil),
            SearchResult(item: CatalogItem(kind: .transition, id: "2", name: "Cross Dissolve", matchName: "AE.ADBE Cross Dissolve New", category: "Dissolve"),
                         highlights: [], isFavorite: false, isRecent: false, shortcut: KeyCombo.plain(18, "1", [.control, .option])),
        ]
        VStack(spacing: 2) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(t.secondary)
                Text("gb").font(.system(size: 17 * scale)).foregroundColor(t.text)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 40)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                ResultRow(result: r, selected: i == 0, theme: t, height: rowH, scale: scale, showMatchName: model.prefs.showMatchNames, busy: false)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(t.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, t.isDark ? .dark : .light)
    }
}

// MARK: - Keys

struct KeysTab: View {
    @EnvironmentObject var model: AppModel
    @State private var pickingItem = false
    @State private var pending: [String] = []   // items picked but not recorded yet

    private struct Row: Identifiable { var id: String; var combo: KeyCombo? }

    private func binding(_ a: PanelAction) -> Binding<KeyCombo?> {
        Binding(get: { model.prefs.combo(for: a) },
                set: { model.prefs.panelKeys[a.rawValue] = $0 ?? a.defaultCombo })
    }

    private var rows: [Row] {
        let saved = model.usage.itemShortcuts
            .sorted { (model.item($0.key)?.name ?? $0.key) < (model.item($1.key)?.name ?? $1.key) }
            .map { Row(id: $0.key, combo: $0.value) }
        return saved + pending.filter { saved.map(\.id).contains($0) == false }.map { Row(id: $0, combo: nil) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(PanelAction.allCases) { a in
                    LabeledContent(a.title) {
                        HStack {
                            ShortcutRecorder(combo: binding(a), allowClear: false)
                            if !a.builtIn.isEmpty {
                                Text("also " + a.builtIn.map { $0.display }.joined(separator: " "))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Text("⌘1–⌘8 jump to a category · ⌘, opens Settings").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Reset to Defaults") { model.prefs.panelKeys = [:] }
                }
            } header: { Text("Search bar keys") }

            Section {
                Toggle("Only while Premiere is the frontmost app", isOn: $model.prefs.itemShortcutsOnlyInPremiere)
                if rows.isEmpty {
                    Text("Give any effect, transition, preset or macro its own shortcut to apply it without opening the search bar.")
                        .font(.callout).foregroundColor(.secondary)
                }
                ForEach(rows) { row in
                    LabeledContent {
                        ShortcutRecorder(
                            combo: Binding(get: { row.combo }, set: { c in
                                model.setShortcut(c, for: row.id)
                                pending.removeAll { $0 == row.id }
                            }),
                            requireModifier: true)
                    } label: {
                        Label(model.item(row.id)?.name ?? "Missing item", systemImage: model.item(row.id)?.kind.symbol ?? "questionmark")
                    }
                }
                Button("Add Shortcut…") { pickingItem = true }
            } header: { Text("Item shortcuts") } footer: {
                Text("Pick combos Premiere doesn't already use — while active, Cue's shortcut wins.").font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $pickingItem) {
            ItemPicker(title: "Choose an item, then record its shortcut", includeMacros: true) { item in
                pickingItem = false
                if let item, !pending.contains(item.id) { pending.append(item.id) }
            }
            .environmentObject(model)
        }
    }
}

// MARK: - Applying

struct ApplyTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Transitions") {
                Picker("Add at", selection: $model.prefs.transitionPosition) {
                    Text("Start of clip").tag("start")
                    Text("End of clip").tag("end")
                    Text("Both ends").tag("both")
                }
                .pickerStyle(.segmented)
                LabeledContent("Duration") {
                    HStack {
                        TextField("", value: $model.prefs.transitionDuration, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("seconds  (0 = Premiere's default)").foregroundColor(.secondary)
                    }
                }
                Toggle("Force single-sided", isOn: $model.prefs.transitionSingleSided)
                Text("Audio transitions aren't available to plugins yet, so Cue lists video transitions only.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Presets & keyframes") {
                Picker("Existing keyframes on the clip", selection: $model.prefs.keyframeMode) {
                    Text("Preserve — never touch them").tag("preserve")
                    Text("Replace with the preset's").tag("replace")
                }
                Text(model.prefs.keyframeMode == "preserve"
                     ? "Preset effects are added as new instances. If a Motion/Opacity/Volume property is already keyframed on the clip, Cue leaves it exactly as it is."
                     : "Keyframed Motion/Opacity/Volume properties the preset includes are cleared and replaced. Your other effects are still never modified.")
                    .font(.caption).foregroundColor(.secondary)
                Picker("Preset keyframe timing", selection: $model.prefs.keyframeTiming) {
                    Text("From clip start").tag("start")
                    Text("Stretch to clip length").tag("stretch")
                    Text("Anchor to clip end").tag("end")
                }
                Picker("If the clip already has the same effect", selection: $model.prefs.duplicateEffects) {
                    Text("Add another instance").tag("add")
                    Text("Skip it").tag("skip")
                }
                Toggle("Apply Motion / Opacity / Volume settings from presets", isOn: $model.prefs.applyFixedEffects)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Connection

struct ConnectionTab: View {
    @EnvironmentObject var model: AppModel
    @State private var portText = ""

    var body: some View {
        Form {
            Section("Status") {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(model.bridgeState.label).font(.body.weight(.medium))
                    Spacer()
                    Button("Sync Effects Now") { model.requestSync() }.disabled(!model.bridgeState.isConnected)
                }
                LabeledContent("Catalog") {
                    Text("\(model.catalog.video.count) video · \(model.catalog.audio.count) audio · \(model.catalog.transitions.count) transitions")
                        .foregroundColor(.secondary)
                }
                if let d = model.lastSync {
                    LabeledContent("Last sync") { Text(d, style: .relative).foregroundColor(.secondary) }
                }
            }
            Section {
                Toggle("Run the local bridge server", isOn: $model.prefs.serverEnabled)
                LabeledContent("Pairing code") {
                    HStack {
                        Text(model.prefs.pairingCode).font(.system(size: 18, weight: .bold, design: .monospaced)).textSelection(.enabled)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.prefs.pairingCode, forType: .string) } label: {
                            Image(systemName: "doc.on.doc")
                        }.help("Copy")
                        Button("New Code") { model.prefs.pairingCode = Preferences.newPairingCode() }
                    }
                }
                Toggle("Require pairing code", isOn: $model.prefs.requirePairing)
                Toggle("Refuse connections from web browsers", isOn: $model.prefs.blockBrowserOrigins)
                LabeledContent("Port") {
                    HStack {
                        TextField("47821", text: $portText).frame(width: 80).multilineTextAlignment(.trailing)
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort).disabled(Int(portText) == model.prefs.port)
                    }
                }
            } header: { Text("Bridge") } footer: {
                Text("Cue only listens on this Mac (localhost). If you change the port, add ws://localhost:<port> to the plugin's manifest.json and set the same port in the Cue Bridge panel.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Activity") {
                if model.activity.isEmpty { Text("Nothing yet.").foregroundColor(.secondary) }
                ForEach(model.activity.prefix(40)) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.date, style: .time).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        Text(line.text).font(.callout).foregroundColor(line.isError ? .red : .primary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(model.prefs.port) }
    }

    private func applyPort() {
        if let p = Int(portText), (1024...65535).contains(p) { model.prefs.port = p }
        else { portText = String(model.prefs.port); NSSound.beep() }
    }

    private var color: Color {
        switch model.bridgeState {
        case .connected: return .green
        case .listening: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }
}

// MARK: - Item picker

struct ItemPicker: View {
    @EnvironmentObject var model: AppModel
    var title: String
    var includeMacros: Bool
    var done: (CatalogItem?) -> Void
    @State private var query = ""
    @State private var selection: String?

    private var items: [SearchResult] {
        model.search(query, in: .all).results.filter { includeMacros || $0.item.kind != .macro }.prefix(300).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            List(items, selection: $selection) { r in
                HStack {
                    Image(systemName: r.item.kind.symbol).foregroundColor(.accentColor).frame(width: 18)
                    Text(r.item.name)
                    Spacer()
                    Text(r.item.category).foregroundColor(.secondary).font(.caption)
                }
                .tag(r.id)
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Choose") { done(selection.flatMap { model.item($0) }) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(18)
        .frame(width: 460, height: 440)
    }
}
