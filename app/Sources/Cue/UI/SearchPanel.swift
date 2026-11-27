import AppKit
import SwiftUI
import Combine

// MARK: - Panel window

/// Borderless, non-activating floating panel: it takes keyboard focus while
/// Premiere stays the active app, so the timeline selection is untouched.
final class SearchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View model

final class SearchViewModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { refresh(keepSelection: false) } } }
    @Published var category: SearchCategory = .all { didSet { if category != oldValue { refresh(keepSelection: false) } } }
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var effectiveCategory: SearchCategory = .all
    @Published var selectedIndex = 0

    let model: AppModel
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        // Publishers fire in willSet; hop to the next runloop turn to read the new values.
        Publishers.MergeMany(
            model.$catalog.map { _ in () }.eraseToAnyPublisher(),
            model.$presets.map { _ in () }.eraseToAnyPublisher(),
            model.$macros.map { _ in () }.eraseToAnyPublisher(),
            model.$usage.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refresh(keepSelection: true) }
        .store(in: &bag)
    }

    var selected: SearchResult? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }

    func refresh(keepSelection: Bool) {
        let keepID = keepSelection ? selected?.id : nil
        let r = model.search(query, in: category)
        effectiveCategory = r.category
        results = Array(r.results.prefix(400))
        if let keepID, let i = results.firstIndex(where: { $0.id == keepID }) {
            selectedIndex = i
        } else {
            selectedIndex = results.isEmpty ? 0 : min(keepSelection ? selectedIndex : 0, results.count - 1)
        }
    }

    func move(_ delta: Int, wrap: Bool = true) {
        guard !results.isEmpty else { return }
        let n = results.count
        if wrap && abs(delta) == 1 { selectedIndex = (selectedIndex + delta + n) % n }
        else { selectedIndex = max(0, min(n - 1, selectedIndex + delta)) }
    }

    func cycleCategory(_ delta: Int) {
        let all = SearchCategory.allCases
        let current = all.firstIndex(of: effectiveCategory) ?? 0
        if effectiveCategory != category, query.count >= 2, Array(query)[1] == ":" {
            query = String(query.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        category = all[(current + delta + all.count) % all.count]
    }

    func applySelected(keepOpen: Bool) {
        guard let r = selected else { NSSound.beep(); return }
        model.activate(r.item, keepOpen: keepOpen)
    }
}

// MARK: - Controller

final class SearchPanelController: NSObject, NSWindowDelegate {
    let panel = SearchPanel()
    let vm: SearchViewModel
    let field = FieldHandle()
    private let model: AppModel
    private var monitor: Any?
    private var bag = Set<AnyCancellable>()
    var openSettings: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        self.vm = SearchViewModel(model: model)
        super.init()
        panel.delegate = self
        let root = SearchView(vm: vm, field: field).environmentObject(model)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        model.$prefs.receive(on: RunLoop.main).sink { [weak self] _ in self?.layout(keepTop: true) }.store(in: &bag)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return e }
            return self.handle(e) ? nil : e
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        vm.query = ""
        vm.category = .all
        vm.refresh(keepSelection: false)
        layout(keepTop: false)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        field.focus()
        model.refreshSelection()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    static func height(for prefs: Preferences) -> CGFloat {
        let header: CGFloat = 58 * prefs.fontScale
        let cats: CGFloat = prefs.showCategoryBar ? 38 : 0
        let footer: CGFloat = 32
        return header + cats + CGFloat(max(3, prefs.visibleRows)) * SearchView.rowHeight(prefs) + footer + 2
    }

    private func layout(keepTop: Bool) {
        let p = model.prefs
        let size = NSSize(width: CGFloat(p.panelWidth), height: Self.height(for: p))
        if keepTop && panel.isVisible {
            var f = panel.frame
            f.origin.y = f.maxY - size.height
            f.size = size
            panel.setFrame(f, display: true)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - vf.height * 0.16)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(KeyCombo.relevant)
        if mods == .command, let ch = e.charactersIgnoringModifiers {
            if let n = Int(ch), (1...SearchCategory.allCases.count).contains(n) {
                vm.category = SearchCategory.allCases[n - 1]
                return true
            }
            if ch == "," { hide(); openSettings(); return true }
        }
        let prefs = model.prefs
        for action in PanelAction.allCases {
            let combos = [prefs.combo(for: action)] + action.builtIn
            if combos.contains(where: { $0.matches(e) }) {
                perform(action)
                return true
            }
        }
        return false
    }

    private func perform(_ action: PanelAction) {
        let page = max(3, model.prefs.visibleRows - 1)
        switch action {
        case .moveDown: vm.move(1)
        case .moveUp: vm.move(-1)
        case .pageDown: vm.move(page, wrap: false)
        case .pageUp: vm.move(-page, wrap: false)
        case .nextCategory: vm.cycleCategory(1)
        case .previousCategory: vm.cycleCategory(-1)
        case .apply: vm.applySelected(keepOpen: false)
        case .applyKeepOpen: vm.applySelected(keepOpen: true)
        case .toggleFavorite: if let r = vm.selected { model.toggleFavorite(r.item.id) }
        case .clearOrClose:
            if !vm.query.isEmpty { vm.query = "" }
            else if vm.category != .all { vm.category = .all }
            else { hide() }
        }
    }
}

// MARK: - Search field

final class FieldHandle {
    weak var field: NSTextField?
    func focus() {
        guard let f = field else { return }
        f.window?.makeFirstResponder(f)
        f.currentEditor()?.selectedRange = NSRange(location: f.stringValue.count, length: 0)
    }
}

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    var textColor: NSColor
    var placeholderColor: NSColor
    var handle: FieldHandle

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.isBezeled = false
        f.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        handle.field = f
        update(f)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        update(f)
    }

    private func update(_ f: NSTextField) {
        f.font = .systemFont(ofSize: fontSize, weight: .regular)
        f.textColor = textColor
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: placeholderColor, .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
        ])
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ p: SearchField) { parent = p }
        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.text = f.stringValue
        }
    }
}
