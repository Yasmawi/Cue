import SwiftUI

struct SearchView: View {
    @ObservedObject var vm: SearchViewModel
    let field: FieldHandle
    @EnvironmentObject var model: AppModel

    static func rowHeight(_ p: Preferences) -> CGFloat { (p.compactRows ? 32 : 44) * CGFloat(p.fontScale) }

    private var theme: Theme { Theme.resolve(model.prefs) }
    private var scale: CGFloat { CGFloat(model.prefs.fontScale) }

    var body: some View {
        let t = theme
        VStack(spacing: 0) {
            header(t)
            if model.prefs.showCategoryBar { categoryBar(t) }
            Rectangle().fill(t.border).frame(height: 1)
            results(t)
            Rectangle().fill(t.border).frame(height: 1)
            footer(t)
        }
        .background(background(t))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.border, lineWidth: 1))
        .environment(\.colorScheme, t.isDark ? .dark : .light)
    }

    @ViewBuilder private func background(_ t: Theme) -> some View {
        if model.prefs.translucent {
            ZStack { VisualEffect(material: t.material); t.background.opacity(0.72) }
        } else {
            t.background
        }
    }

    // MARK: header

    private func header(_ t: Theme) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18 * scale, weight: .medium))
                .foregroundColor(t.secondary)
            SearchField(text: $vm.query,
                        placeholder: placeholder,
                        fontSize: 21 * scale,
                        textColor: NSColor(t.text),
                        placeholderColor: NSColor(t.secondary.opacity(0.8)),
                        handle: field)
            if vm.effectiveCategory != .all {
                Label(vm.effectiveCategory.title, systemImage: vm.effectiveCategory.symbol)
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(t.accent.opacity(0.18)))
                    .foregroundColor(t.accent)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58 * scale)
    }

    private var placeholder: String {
        switch vm.effectiveCategory {
        case .all: return "Search effects, transitions, presets, macros…"
        default: return "Search \(vm.effectiveCategory.title.lowercased())…"
        }
    }

    // MARK: categories

    private func categoryBar(_ t: Theme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(SearchCategory.allCases.enumerated()), id: \.element) { i, c in
                    let on = vm.effectiveCategory == c
                    Button { vm.category = c } label: {
                        HStack(spacing: 5) {
                            Image(systemName: c.symbol).font(.system(size: 10, weight: .semibold))
                            Text(c.title).font(.system(size: 11.5 * scale, weight: on ? .semibold : .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(on ? t.accent : t.surface.opacity(0.9)))
                        .foregroundColor(on ? .white : t.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("⌘\(i + 1)")
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 38)
    }

    // MARK: results

    private func results(_ t: Theme) -> some View {
        let rowH = Self.rowHeight(model.prefs)
        return Group {
            if vm.results.isEmpty {
                emptyState(t)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(vm.results.enumerated()), id: \.element.id) { i, r in
                                ResultRow(result: r, selected: i == vm.selectedIndex, theme: t,
                                          height: rowH, scale: scale, showMatchName: model.prefs.showMatchNames,
                                          busy: model.busyItem == r.id)
                                    .id(r.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { vm.selectedIndex = i; vm.applySelected(keepOpen: false) }
                                    .onTapGesture { vm.selectedIndex = i }
                                    .contextMenu {
                                        Button(r.isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(r.id) }
                                        Button("Apply and Keep Open") { model.activate(r.item, keepOpen: true) }
                                    }
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    .onChange(of: vm.selectedIndex) { i in
                        guard vm.results.indices.contains(i) else { return }
                        proxy.scrollTo(vm.results[i].id, anchor: nil)
                    }
                    .onChange(of: vm.query) { _ in
                        if let first = vm.results.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
        }
        .frame(height: CGFloat(max(3, model.prefs.visibleRows)) * rowH)
    }

    private func emptyState(_ t: Theme) -> some View {
        VStack(spacing: 8) {
            Spacer()
            if model.catalog.isEmpty && vm.query.isEmpty {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 28)).foregroundColor(t.secondary)
                Text("Connect Premiere to load your effects").font(.system(size: 14, weight: .semibold)).foregroundColor(t.text)
                Text("In Premiere: Window › UXP Plugins › Cue Bridge, then enter the pairing code \(model.prefs.pairingCode).")
                    .font(.system(size: 12)).foregroundColor(t.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            } else if vm.effectiveCategory == .favorites && vm.query.isEmpty {
                Text("No favorites yet").font(.system(size: 14, weight: .semibold)).foregroundColor(t.text)
                Text("Press \(model.prefs.combo(for: .toggleFavorite).display) on any result to pin it here.").font(.system(size: 12)).foregroundColor(t.secondary)
            } else if vm.effectiveCategory == .macros && vm.query.isEmpty {
                Text("No macros yet").font(.system(size: 14, weight: .semibold)).foregroundColor(t.text)
                Text("Create one in Settings › Macros (⌘,).").font(.system(size: 12)).foregroundColor(t.secondary)
            } else if vm.effectiveCategory == .presets && vm.query.isEmpty {
                Text("No presets yet").font(.system(size: 14, weight: .semibold)).foregroundColor(t.text)
                Text("Select a styled clip and use Capture in the Cue Bridge panel or Settings › Presets.").font(.system(size: 12)).foregroundColor(t.secondary)
            } else {
                Text(vm.query.isEmpty ? "Nothing here yet" : "No matches for “\(vm.query)”").font(.system(size: 14, weight: .semibold)).foregroundColor(t.text)
                if vm.effectiveCategory != .all {
                    Text("Press \(model.prefs.combo(for: .clearOrClose).display) to search everything.").font(.system(size: 12)).foregroundColor(t.secondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: footer

    private func footer(_ t: Theme) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(statusText).font(.system(size: 11)).foregroundColor(t.secondary).lineLimit(1)
            Spacer()
            if model.prefs.showFooterHints {
                hint(model.prefs.combo(for: .apply).display, "Apply", t)
                hint(model.prefs.combo(for: .applyKeepOpen).display, "Stay", t)
                hint(model.prefs.combo(for: .nextCategory).display, "Category", t)
                hint(model.prefs.combo(for: .toggleFavorite).display, "Favorite", t)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private func hint(_ key: String, _ label: String, _ t: Theme) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(t.surface))
                .foregroundColor(t.text.opacity(0.85))
            Text(label).font(.system(size: 10.5)).foregroundColor(t.secondary)
        }
    }

    private var dotColor: Color {
        switch model.bridgeState {
        case .connected: return Color(hex: "#3ECF8E")
        case .listening: return Color(hex: "#F5A524")
        case .failed: return Color(hex: "#F2555A")
        case .stopped: return .gray
        }
    }

    private var statusText: String {
        if model.bridgeState.isConnected, let s = model.selection { return s.label }
        return model.bridgeState.label
    }
}

struct ResultRow: View {
    let result: SearchResult
    let selected: Bool
    let theme: Theme
    let height: CGFloat
    let scale: CGFloat
    let showMatchName: Bool
    let busy: Bool

    var body: some View {
        let t = theme
        let compact = height < 40 * scale
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? t.accent : t.surface)
                Image(systemName: result.item.kind.symbol)
                    .font(.system(size: (compact ? 11 : 13) * scale, weight: .semibold))
                    .foregroundColor(selected ? .white : t.accent)
            }
            .frame(width: (compact ? 22 : 28) * scale, height: (compact ? 22 : 28) * scale)

            VStack(alignment: .leading, spacing: 1) {
                highlighted(t).lineLimit(1)
                if !compact {
                    Text(subtitle).font(.system(size: 11 * scale)).foregroundColor(t.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            if result.isRecent && !selected {
                Image(systemName: "clock").font(.system(size: 10)).foregroundColor(t.secondary.opacity(0.7))
            }
            if result.isFavorite {
                Image(systemName: "star.fill").font(.system(size: 10.5)).foregroundColor(Color(hex: "#F5C451"))
            }
            if let s = result.shortcut {
                Text(s.display).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(t.surface))
                    .foregroundColor(t.secondary)
            }
            if compact {
                Text(result.item.category).font(.system(size: 11 * scale)).foregroundColor(t.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? t.selection : Color.clear))
    }

    private var subtitle: String {
        var s = "\(result.item.kind.label) · \(result.item.category)"
        if showMatchName && result.item.matchName != result.item.name && result.item.kind != .preset && result.item.kind != .macro {
            s += " · \(result.item.matchName)"
        }
        return s
    }

    /// Name with matched characters in bold accent, built from runs of Text.
    private func highlighted(_ t: Theme) -> Text {
        let hl = Set(result.highlights)
        let size = 14 * scale
        var out = Text("")
        var run = ""
        var runOn = false
        func flush() {
            guard !run.isEmpty else { return }
            let piece = Text(run).font(.system(size: size, weight: runOn ? .bold : .medium))
                .foregroundColor(runOn && !selected ? t.accent : t.text)
            out = out + piece
            run = ""
        }
        for (i, ch) in result.item.name.enumerated() {
            let on = hl.contains(i)
            if on != runOn { flush(); runOn = on }
            run.append(ch)
        }
        flush()
        return out
    }
}
