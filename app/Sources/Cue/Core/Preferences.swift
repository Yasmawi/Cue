import Foundation

/// Everything configurable in Settings. Decoding tolerates missing keys so
/// adding a setting never wipes an older settings file.
struct Preferences: Codable, Equatable {
    // General
    var openHotKey: KeyCombo = .optionSpace
    var closeAfterApply = true
    var showHUD = true
    var fallbackToPlayhead = true
    var maxRecents = 12
    var visibleRows = 8
    var launchAtLogin = false
    var itemShortcutsOnlyInPremiere = true

    // Appearance
    var themeID = "midnight"
    var accentHex: String? = nil
    var translucent = true
    var panelWidth: Double = 640
    var compactRows = false
    var fontScale: Double = 1.0
    var showCategoryBar = true
    var showFooterHints = true
    var showMatchNames = false

    // Keys
    var panelKeys: [String: KeyCombo] = [:]   // PanelAction.rawValue → combo (missing = default)

    // Apply behaviour
    var transitionPosition = "end"     // start | end | both
    var transitionDuration: Double = 0 // 0 = Premiere default
    var transitionSingleSided = false
    var keyframeMode = "preserve"      // preserve | replace
    var keyframeTiming = "start"       // start | stretch | end
    var duplicateEffects = "add"       // add | skip
    var applyFixedEffects = true

    // Connection
    var serverEnabled = true
    var port: Int = 47821
    var pairingCode: String = Preferences.newPairingCode()
    var requirePairing = true
    var blockBrowserOrigins = true

    static func newPairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    func combo(for action: PanelAction) -> KeyCombo { panelKeys[action.rawValue] ?? action.defaultCombo }

    init() {}

    init(from decoder: Decoder) throws {
        let d = Preferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T {
            if let x = try? c.decodeIfPresent(T.self, forKey: k) { return x }
            return def
        }
        openHotKey = v(.openHotKey, d.openHotKey)
        closeAfterApply = v(.closeAfterApply, d.closeAfterApply)
        showHUD = v(.showHUD, d.showHUD)
        fallbackToPlayhead = v(.fallbackToPlayhead, d.fallbackToPlayhead)
        maxRecents = v(.maxRecents, d.maxRecents)
        visibleRows = v(.visibleRows, d.visibleRows)
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        itemShortcutsOnlyInPremiere = v(.itemShortcutsOnlyInPremiere, d.itemShortcutsOnlyInPremiere)
        themeID = v(.themeID, d.themeID)
        if let hex = try? c.decodeIfPresent(String.self, forKey: .accentHex) { accentHex = hex }
        translucent = v(.translucent, d.translucent)
        panelWidth = v(.panelWidth, d.panelWidth)
        compactRows = v(.compactRows, d.compactRows)
        fontScale = v(.fontScale, d.fontScale)
        showCategoryBar = v(.showCategoryBar, d.showCategoryBar)
        showFooterHints = v(.showFooterHints, d.showFooterHints)
        showMatchNames = v(.showMatchNames, d.showMatchNames)
        panelKeys = v(.panelKeys, d.panelKeys)
        transitionPosition = v(.transitionPosition, d.transitionPosition)
        transitionDuration = v(.transitionDuration, d.transitionDuration)
        transitionSingleSided = v(.transitionSingleSided, d.transitionSingleSided)
        keyframeMode = v(.keyframeMode, d.keyframeMode)
        keyframeTiming = v(.keyframeTiming, d.keyframeTiming)
        duplicateEffects = v(.duplicateEffects, d.duplicateEffects)
        applyFixedEffects = v(.applyFixedEffects, d.applyFixedEffects)
        serverEnabled = v(.serverEnabled, d.serverEnabled)
        port = v(.port, d.port)
        pairingCode = v(.pairingCode, d.pairingCode)
        requirePairing = v(.requirePairing, d.requirePairing)
        blockBrowserOrigins = v(.blockBrowserOrigins, d.blockBrowserOrigins)
    }
}

/// Small persistent state that isn't a "setting".
struct UsageState: Codable {
    var recents: [String] = []                 // item ids, most recent first
    var favorites: [String] = []
    var useCounts: [String: Int] = [:]
    var itemShortcuts: [String: KeyCombo] = [:] // item id → combo
}

/// JSON files in ~/Library/Application Support/Cue.
enum Storage {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Cue", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = folder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = folder.appendingPathComponent(name)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
