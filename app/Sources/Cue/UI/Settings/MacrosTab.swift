import SwiftUI

struct MacrosTab: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.macros) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).lineLimit(1)
                            Text("\(m.steps.count) step\(m.steps.count == 1 ? "" : "s")").font(.caption).foregroundColor(.secondary)
                        }
                        .tag(m.id)
                    }
                    .onMove { model.macros.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 6) {
                    Button {
                        let m = Macro(name: "New Macro")
                        model.macros.append(m)
                        selection = m.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let id = selection { model.macros.removeAll { $0.id == id }; selection = nil }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 230)

            Divider()

            Group {
                if let id = selection, let i = model.macros.firstIndex(where: { $0.id == id }) {
                    MacroEditor(macro: $model.macros[i])
                } else {
                    VStack(spacing: 6) {
                        Text("Macros chain actions together").font(.headline)
                        Text("For example: Warp Stabilizer → Lumetri look preset → Cross Dissolve at both ends. Each macro shows up in search and can have its own shortcut.")
                            .foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
        }
    }
}

struct MacroEditor: View {
    @Binding var macro: Macro
    @EnvironmentObject var model: AppModel
    @State private var picking = false
    @State private var running = false
    @State private var result: String?

    private var shortcut: Binding<KeyCombo?> {
        let id = macro.catalogItem.id
        return Binding(get: { model.usage.itemShortcuts[id] }, set: { model.setShortcut($0, for: id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Macro name", text: $macro.name).textFieldStyle(.roundedBorder).font(.title3)
                ShortcutRecorder(combo: shortcut, requireModifier: true)
            }
            Toggle("Stop if a step fails", isOn: $macro.stopOnError)

            List {
                ForEach(Array(macro.steps.indices), id: \.self) { i in
                    StepRow(step: $macro.steps[i], number: i + 1) {
                        macro.steps.remove(at: i)
                    }
                }
                .onMove { macro.steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 200)

            HStack {
                Button { picking = true } label: { Label("Add Action", systemImage: "plus") }
                Button { macro.steps.append(MacroStep(type: .wait, waitMs: 300)) } label: { Label("Add Pause", systemImage: "pause") }
                Spacer()
                if let result { Text(result).font(.caption).foregroundColor(.secondary).lineLimit(2) }
                Button(running ? "Running…" : "Test Run") { test() }
                    .disabled(running || macro.steps.isEmpty || !model.bridgeState.isConnected)
            }
        }
        .sheet(isPresented: $picking) {
            ItemPicker(title: "Add a step", includeMacros: false) { item in
                picking = false
                guard let item else { return }
                macro.steps.append(MacroStep(type: .apply, itemID: item.id, itemName: item.name))
            }
            .environmentObject(model)
        }
    }

    private func test() {
        running = true
        result = nil
        let m = macro
        Task { @MainActor in
            defer { running = false }
            do { result = try await model.run(m) } catch { result = error.localizedDescription }
        }
    }
}

struct StepRow: View {
    @Binding var step: MacroStep
    let number: Int
    let remove: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 18)
            switch step.type {
            case .wait:
                Image(systemName: "pause.circle").foregroundColor(.secondary)
                Stepper(value: Binding(get: { step.waitMs ?? 0 }, set: { step.waitMs = $0 }), in: 0...10_000, step: 100) {
                    Text("Pause \(step.waitMs ?? 0) ms")
                }
            case .apply:
                let item = step.itemID.flatMap { model.item($0) }
                Image(systemName: item?.kind.symbol ?? "exclamationmark.triangle")
                    .foregroundColor(item == nil ? .orange : .accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item?.name ?? step.itemName ?? "Missing item")
                    Text(item.map { "\($0.kind.label) · \($0.category)" } ?? "Not in the current catalog — sync Premiere")
                        .font(.caption).foregroundColor(.secondary)
                }
                if item?.kind == .transition {
                    Spacer()
                    Picker("", selection: Binding(get: { step.transitionPosition ?? "" }, set: { step.transitionPosition = $0.isEmpty ? nil : $0 })) {
                        Text("Default").tag("")
                        Text("Start").tag("start")
                        Text("End").tag("end")
                        Text("Both").tag("both")
                    }
                    .frame(width: 120)
                    TextField("sec", value: Binding(get: { step.transitionDuration ?? 0 }, set: { step.transitionDuration = $0 > 0 ? $0 : nil }),
                              format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 48)
                        .help("Duration in seconds (0 = default)")
                }
            }
            Spacer()
            Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}
