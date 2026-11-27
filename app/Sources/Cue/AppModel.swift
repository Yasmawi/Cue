import AppKit
import SwiftUI
import ServiceManagement

enum SearchCategory: String, CaseIterable, Identifiable {
    case all, video, audio, transitions, presets, macros, favorites, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .video: return "Video"
        case .audio: return "Audio"
        case .transitions: return "Transitions"
        case .presets: return "Presets"
        case .macros: return "Macros"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .video: return ItemKind.videoEffect.symbol
        case .audio: return ItemKind.audioEffect.symbol
        case .transitions: return ItemKind.transition.symbol
        case .presets: return ItemKind.preset.symbol
        case .macros: return ItemKind.macro.symbol
        case .favorites: return "star.fill"
        case .recent: return "clock"
        }
    }

    /// Typing "t:" at the start of the query jumps to a category.
    static func fromPrefix(_ p: String) -> SearchCategory? {
        switch p {
        case "v": return .video
        case "a": return .audio
        case "t": return .transitions
        case "p": return .presets
        case "m": return .macros
        case "f": return .favorites
        case "r": return .recent
        default: return nil
        }
    }
}

struct SearchResult: Identifiable {
    var item: CatalogItem
    var highlights: [Int]
    var isFavorite: Bool
    var isRecent: Bool
    var shortcut: KeyCombo?
    var id: String { item.id }
}

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let isError: Bool
}

struct SelectionStatus: Equatable {
    var sequence: String
    var video: Int
    var audio: Int

    var label: String {
        var parts: [String] = []
        if !sequence.isEmpty { parts.append(sequence) }
        if video + audio == 0 { parts.append("no clips selected") }
        else {
            if video > 0 { parts.append("\(video) video") }
            if audio > 0 { parts.append("\(audio) audio") }
        }
        return parts.joined(separator: " · ")
    }
}

/// The app's brain: catalog, user data, preferences, the bridge, hotkeys.
/// Used from the main thread only.
final class AppModel: ObservableObject {
    @Published var prefs: Preferences {
        didSet {
            guard prefs != oldValue else { return }
            Storage.save(prefs, "preferences.json")
            prefsChanged(from: oldValue)
        }
    }
    @Published private(set) var catalog: Catalog
    @Published var presets: [Preset] { didSet { Storage.save(presets, "presets.json") } }
    @Published var macros: [Macro] { didSet { Storage.save(macros, "macros.json") } }
    @Published var usage: UsageState { didSet { Storage.save(usage, "usage.json") } }
    @Published private(set) var bridgeState: BridgeState = .stopped
    @Published private(set) var selection: SelectionStatus?
    @Published private(set) var activity: [LogLine] = []
    @Published private(set) var lastSync: Date?
    @Published var openHotKeyProblem: String?
    @Published var busyItem: String?

    let bridge = BridgeServer()

    /// Set by the AppDelegate.
    var togglePanel: () -> Void = {}
    var hidePanel: () -> Void = {}
    var showHUD: (String, Bool) -> Void = { _, _ in }

    private var workspaceObserver: NSObjectProtocol?
    private var premiereFrontmost = false

    init() {
        prefs = Storage.load(Preferences.self, "preferences.json") ?? Preferences()
        catalog = Storage.load(Catalog.self, "catalog.json") ?? Catalog()
        presets = Storage.load([Preset].self, "presets.json") ?? []
        macros = Storage.load([Macro].self, "macros.json") ?? Self.sampleMacros
        usage = Storage.load(UsageState.self, "usage.json") ?? UsageState()
        Storage.save(prefs, "preferences.json") // persists a generated pairing code on first run

        bridge.onState = { [weak self] s in
            guard let self else { return }
            let was = self.bridgeState.isConnected
            self.bridgeState = s
            if s.isConnected && !was { self.log("Premiere connected") }
            if !s.isConnected { self.selection = nil }
        }
        bridge.onLog = { [weak self] s in self?.log(s) }
        bridge.onEvent = { [weak self] name, data in self?.handleEvent(name, data) }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostChanged(app)
        }
        frontmostChanged(NSWorkspace.shared.frontmostApplication)
    }

    func startServices() {
        restartServer()
        registerOpenHotKey()
        registerItemShortcuts()
    }

    // MARK: - Items

    var allItems: [CatalogItem] {
        catalog.all + presets.map { $0.catalogItem } + macros.map { $0.catalogItem }
    }

    func item(_ id: String) -> CatalogItem? { allItems.first { $0.id == id } }

    func preset(for item: CatalogItem) -> Preset? { presets.first { $0.id == item.matchName } }
    func macro(for item: CatalogItem) -> Macro? { macros.first { $0.id == item.matchName } }

    func isFavorite(_ id: String) -> Bool { usage.favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if let i = usage.favorites.firstIndex(of: id) { usage.favorites.remove(at: i) }
        else { usage.favorites.append(id) }
    }

    private func recordUse(_ id: String) {
        var u = usage
        u.recents.removeAll { $0 == id }
        u.recents.insert(id, at: 0)
        if u.recents.count > max(1, prefs.maxRecents) { u.recents = Array(u.recents.prefix(max(1, prefs.maxRecents))) }
        u.useCounts[id, default: 0] += 1
        usage = u
    }

    func clearRecents() { usage.recents = [] }

    // MARK: - Search

    func search(_ rawQuery: String, in requested: SearchCategory) -> (category: SearchCategory, results: [SearchResult]) {
        var query = rawQuery.trimmingCharacters(in: .whitespaces)
        var category = requested
        if query.count >= 2 {
            let chars = Array(query)
            if chars[1] == ":", let c = SearchCategory.fromPrefix(String(chars[0]).lowercased()) {
                category = c
                query = String(chars.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }

        let recents = usage.recents
        let recentRank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let favs = Set(usage.favorites)
        let shortcuts = usage.itemShortcuts

        var pool: [CatalogItem]
        switch category {
        case .all: pool = allItems
        case .video: pool = catalog.video
        case .audio: pool = catalog.audio
        case .transitions: pool = catalog.transitions
        case .presets: pool = presets.map { $0.catalogItem }
        case .macros: pool = macros.map { $0.catalogItem }
        case .favorites: pool = allItems.filter { favs.contains($0.id) }
        case .recent:
            let byID = Dictionary(allItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            pool = recents.compactMap { byID[$0] }
        }

        func make(_ item: CatalogItem, _ hl: [Int]) -> SearchResult {
            SearchResult(item: item, highlights: hl, isFavorite: favs.contains(item.id),
                         isRecent: recentRank[item.id] != nil, shortcut: shortcuts[item.id])
        }

        if query.isEmpty {
            if category == .recent { return (category, pool.map { make($0, []) }) }
            let sorted = pool.sorted { a, b in
                let ra = recentRank[a.id] ?? Int.max, rb = recentRank[b.id] ?? Int.max
                if ra != rb { return ra < rb }
                let fa = favs.contains(a.id), fb = favs.contains(b.id)
                if fa != fb { return fa }
                let ua = usage.useCounts[a.id] ?? 0, ub = usage.useCounts[b.id] ?? 0
                if ua != ub { return ua > ub }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return (category, sorted.map { make($0, []) })
        }

        var scored: [(SearchResult, Int)] = []
        scored.reserveCapacity(pool.count)
        for item in pool {
            guard let m = FuzzyMatcher.match(query, in: item.name, category: item.category) else { continue }
            var s = m.score
            if favs.contains(item.id) { s += 8 }
            if let r = recentRank[item.id] { s += max(0, 12 - r) }
            s += min(usage.useCounts[item.id] ?? 0, 15)
            scored.append((make(item, m.ranges), s))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.item.name < $1.0.item.name }
        return (category, scored.map { $0.0 })
    }

    // MARK: - Applying

    func activate(_ item: CatalogItem, keepOpen: Bool = false) {
        recordUse(item.id)
        if !keepOpen && prefs.closeAfterApply { hidePanel() }
        busyItem = item.id
        Task { @MainActor in
            defer { self.busyItem = nil }
            do {
                let summary = try await self.perform(item)
                self.log(summary)
                if self.prefs.showHUD { self.showHUD(summary, false) }
            } catch {
                let msg = error.localizedDescription
                self.log("\(item.name): \(msg)", error: true)
                self.showHUD(msg, true)
            }
        }
    }

    @MainActor private func perform(_ item: CatalogItem) async throws -> String {
        if item.kind == .macro {
            guard let m = macro(for: item) else { throw BridgeError(code: "MISSING", message: "That macro no longer exists.") }
            return try await run(m)
        }
        let r = try await applyRemote(item, step: nil)
        var s = "\(item.name) → \(r.applied) clip\(r.applied == 1 ? "" : "s")"
        if r.fromPlayhead { s += " under playhead" }
        if r.preserved > 0 { s += " · kept \(r.preserved) keyframed param\(r.preserved == 1 ? "" : "s")" }
        if let w = r.warnings.first { s += " · \(w)" }
        return s
    }

    @MainActor private func applyRemote(_ item: CatalogItem, step: MacroStep?) async throws -> ApplyResult {
        var params: [String: JSON] = ["item": item.payload, "options": options(for: item, step: step)]
        if item.kind == .preset {
            guard let p = preset(for: item) else { throw BridgeError(code: "MISSING", message: "That preset no longer exists.") }
            params["preset"] = try JSON.from(p)
        }
        return ApplyResult(try await bridge.request("apply", .object(params), timeout: 60))
    }

    func options(for item: CatalogItem, step: MacroStep?) -> JSON {
        var o: [String: JSON] = [
            "fallbackToPlayhead": .bool(prefs.fallbackToPlayhead),
            "transitionPosition": .string(step?.transitionPosition ?? prefs.transitionPosition),
            "transitionDuration": .number(step?.transitionDuration ?? prefs.transitionDuration),
            "transitionSingleSided": .bool(prefs.transitionSingleSided),
            "keyframeMode": .string(prefs.keyframeMode),
            "keyframeTiming": .string(prefs.keyframeTiming),
            "duplicateEffects": .string(prefs.duplicateEffects),
            "applyFixedEffects": .bool(prefs.applyFixedEffects),
        ]
        if item.kind == .preset, let ov = preset(for: item)?.overrides {
            if let t = ov.keyframeTiming { o["keyframeTiming"] = .string(t) }
            if let m = ov.keyframeMode { o["keyframeMode"] = .string(m) }
        }
        return .object(o)
    }

    @MainActor func run(_ macro: Macro) async throws -> String {
        var done = 0
        for (i, step) in macro.steps.enumerated() {
            switch step.type {
            case .wait:
                let ms = max(0, min(step.waitMs ?? 0, 30_000))
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            case .apply:
                guard let id = step.itemID, let item = self.item(id), item.kind != .macro else {
                    if macro.stopOnError { throw BridgeError(code: "MACRO", message: "Step \(i + 1): “\(step.itemName ?? "item")” is no longer available.") }
                    continue
                }
                do {
                    _ = try await applyRemote(item, step: step)
                    done += 1
                } catch {
                    if macro.stopOnError {
                        throw BridgeError(code: "MACRO", message: "\(macro.name) stopped at step \(i + 1) (\(item.name)): \(error.localizedDescription)")
                    }
                    log("\(macro.name) step \(i + 1) skipped: \(error.localizedDescription)", error: true)
                }
            }
        }
        return "\(macro.name) · \(done) step\(done == 1 ? "" : "s") applied"
    }

    // MARK: - Bridge

    func restartServer() {
        if prefs.serverEnabled {
            bridge.start(.init(port: prefs.port, pairingCode: prefs.pairingCode,
                               requirePairing: prefs.requirePairing, blockBrowserOrigins: prefs.blockBrowserOrigins))
        } else {
            bridge.stop()
        }
    }

    func requestSync() {
        Task { @MainActor in
            do {
                let data = try await self.bridge.request("catalog.get", timeout: 30)
                self.ingestCatalog(data)
            } catch {
                self.log("Sync failed: \(error.localizedDescription)", error: true)
            }
        }
    }

    func refreshSelection() {
        guard bridgeState.isConnected else { selection = nil; return }
        Task { @MainActor in
            guard let s = try? await self.bridge.request("status.get", timeout: 1.5) else { return }
            self.selection = SelectionStatus(sequence: s["sequence"]?.string ?? "",
                                             video: s["videoSelected"]?.int ?? 0,
                                             audio: s["audioSelected"]?.int ?? 0)
        }
    }

    @MainActor func capturePreset(named name: String) async throws -> Preset {
        let data = try await bridge.request("preset.capture", ["name": .string(name)], timeout: 30)
        let p = try data.decode(Preset.self)
        return addPreset(p)
    }

    @discardableResult
    func addPreset(_ incoming: Preset) -> Preset {
        var p = incoming
        let names = Set(presets.map { $0.name })
        if names.contains(p.name) {
            var n = 2
            while names.contains("\(incoming.name) \(n)") { n += 1 }
            p.name = "\(incoming.name) \(n)"
        }
        if presets.contains(where: { $0.id == p.id }) { p.id = UUID().uuidString }
        presets.append(p)
        log("Saved preset “\(p.name)”")
        return p
    }

    private func handleEvent(_ name: String, _ data: JSON) {
        switch name {
        case "catalog":
            ingestCatalog(data)
        case "preset.captured":
            if let p = try? data.decode(Preset.self) {
                let saved = addPreset(p)
                showHUD("Saved preset “\(saved.name)”", false)
            } else {
                log("Received a preset Cue couldn't read", error: true)
            }
        default:
            break
        }
    }

    private func ingestCatalog(_ data: JSON) {
        do {
            let c = try data.decode(Catalog.self)
            catalog = c
            lastSync = Date()
            Storage.save(c, "catalog.json")
            log("Synced \(c.video.count) video effects, \(c.audio.count) audio effects, \(c.transitions.count) transitions")
        } catch {
            log("Catalog from Premiere was unreadable: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: - Hotkeys

    func registerOpenHotKey() {
        HotKeyCenter.shared.unregister(group: "open")
        let ok = HotKeyCenter.shared.register(prefs.openHotKey, group: "open") { [weak self] in self?.togglePanel() }
        openHotKeyProblem = ok ? nil : "\(prefs.openHotKey.display) is taken by another app — pick a different shortcut."
    }

    func registerItemShortcuts() {
        HotKeyCenter.shared.unregister(group: "items")
        guard premiereFrontmost || !prefs.itemShortcutsOnlyInPremiere else { return }
        for (id, combo) in usage.itemShortcuts {
            HotKeyCenter.shared.register(combo, group: "items") { [weak self] in
                guard let self, let item = self.item(id) else { return }
                self.activate(item, keepOpen: true)
            }
        }
    }

    func setShortcut(_ combo: KeyCombo?, for id: String) {
        if let combo {
            usage.itemShortcuts = usage.itemShortcuts.filter { $0.value != combo }
            usage.itemShortcuts[id] = combo
        } else {
            usage.itemShortcuts.removeValue(forKey: id)
        }
        registerItemShortcuts()
    }

    private func frontmostChanged(_ app: NSRunningApplication?) {
        let isPremiere = app?.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") ?? false
        let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if isSelf { return } // our own windows don't change the answer
        if isPremiere != premiereFrontmost {
            premiereFrontmost = isPremiere
            registerItemShortcuts()
        }
    }

    // MARK: - Preferences side effects

    private func prefsChanged(from old: Preferences) {
        if old.openHotKey != prefs.openHotKey { registerOpenHotKey() }
        if old.itemShortcutsOnlyInPremiere != prefs.itemShortcutsOnlyInPremiere { registerItemShortcuts() }
        if old.port != prefs.port || old.pairingCode != prefs.pairingCode || old.requirePairing != prefs.requirePairing
            || old.serverEnabled != prefs.serverEnabled || old.blockBrowserOrigins != prefs.blockBrowserOrigins {
            restartServer()
        }
        if old.launchAtLogin != prefs.launchAtLogin { updateLoginItem() }
        if old.maxRecents != prefs.maxRecents, usage.recents.count > prefs.maxRecents {
            usage.recents = Array(usage.recents.prefix(max(1, prefs.maxRecents)))
        }
    }

    private func updateLoginItem() {
        do {
            if prefs.launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            log("Launch at login: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: - Log

    func log(_ text: String, error: Bool = false) {
        activity.insert(LogLine(text: text, isError: error), at: 0)
        if activity.count > 150 { activity.removeLast(activity.count - 150) }
    }

    // MARK: - Import / export

    func exportBundle() throws -> Data {
        struct ExportFile: Encodable { var presets: [Preset]; var macros: [Macro] }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(ExportFile(presets: presets, macros: macros))
    }

    func importBundle(_ data: Data) throws -> (Int, Int) {
        struct ImportFile: Decodable { var presets: [Preset]?; var macros: [Macro]? }
        let b = try JSONDecoder().decode(ImportFile.self, from: data)
        for p in b.presets ?? [] { addPreset(p) }
        var added = 0
        for var m in b.macros ?? [] {
            if macros.contains(where: { $0.id == m.id }) { m.id = UUID().uuidString }
            macros.append(m)
            added += 1
        }
        return (b.presets?.count ?? 0, added)
    }

    static let sampleMacros: [Macro] = [
        Macro(name: "Dissolve in & out", steps: [
            MacroStep(type: .apply, itemID: "t:AE.ADBE Cross Dissolve New", itemName: "Cross Dissolve", transitionPosition: "both"),
        ]),
    ]
}
