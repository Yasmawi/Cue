import Foundation

// MARK: - Catalog

enum ItemKind: String, Codable, CaseIterable {
    case videoEffect, audioEffect, transition, preset, macro

    var label: String {
        switch self {
        case .videoEffect: return "Video Effect"
        case .audioEffect: return "Audio Effect"
        case .transition: return "Transition"
        case .preset: return "Preset"
        case .macro: return "Macro"
        }
    }

    var symbol: String {
        switch self {
        case .videoEffect: return "wand.and.stars"
        case .audioEffect: return "waveform"
        case .transition: return "square.split.2x1"
        case .preset: return "slider.horizontal.3"
        case .macro: return "bolt.fill"
        }
    }
}

struct CatalogItem: Codable, Identifiable, Hashable {
    var kind: ItemKind
    var id: String
    var name: String
    var matchName: String
    var category: String

    /// What the plugin needs to identify the item.
    var payload: JSON {
        ["kind": .string(kind.rawValue), "id": .string(id), "name": .string(name), "matchName": .string(matchName)]
    }
}

struct Catalog: Codable {
    var video: [CatalogItem] = []
    var audio: [CatalogItem] = []
    var transitions: [CatalogItem] = []
    var premiereVersion: String? = nil
    var generatedAt: String? = nil

    var all: [CatalogItem] { video + audio + transitions }
    var isEmpty: Bool { video.isEmpty && audio.isEmpty && transitions.isEmpty }
}

// MARK: - Presets (format owned by the Premiere plugin; we only edit flags)

struct PresetMedia: Codable, Hashable {
    var duration: Double?
    var clipName: String?
}

struct PresetParam: Codable, Hashable, Identifiable {
    var index: Int
    var name: String
    var enabled: Bool?
    var value: JSON?
    var keyframes: [JSON]?

    var id: String { "\(index):\(name)" }
    var isOn: Bool { enabled ?? true }
}

struct PresetComponent: Codable, Hashable, Identifiable {
    var media: String
    var matchName: String
    var displayName: String
    var intrinsic: Bool
    var enabled: Bool?
    var params: [PresetParam]

    var id: String { "\(media):\(matchName):\(displayName)" }
    var isOn: Bool { enabled ?? true }
}

struct PresetOverrides: Codable, Hashable {
    var keyframeTiming: String?   // start | stretch | end
    var keyframeMode: String?     // preserve | replace
}

struct Preset: Codable, Identifiable, Hashable {
    var format: Int?
    var id: String
    var name: String
    var createdAt: String?
    var media: [String: PresetMedia]?
    var components: [PresetComponent]
    var overrides: PresetOverrides?

    var summary: String {
        let on = components.filter { $0.isOn }
        let animated = on.flatMap { $0.params }.filter { $0.isOn && !($0.keyframes ?? []).isEmpty }.count
        var s = on.map { $0.displayName }.joined(separator: " + ")
        if animated > 0 { s += " · \(animated) animated" }
        return s.isEmpty ? "No effects enabled" : s
    }

    var catalogItem: CatalogItem {
        let cat = (media?["audio"] != nil && media?["video"] == nil) ? "Audio Presets" : "Presets"
        return CatalogItem(kind: .preset, id: "p:\(id)", name: name, matchName: id, category: cat)
    }
}

// MARK: - Macros

struct MacroStep: Codable, Identifiable, Hashable {
    enum StepType: String, Codable { case apply, wait }
    var id = UUID().uuidString
    var type: StepType
    var itemID: String?
    var itemName: String?          // remembered for display if the item disappears
    var waitMs: Int?
    var transitionPosition: String?
    var transitionDuration: Double?
}

struct Macro: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var steps: [MacroStep] = []
    var stopOnError = true

    var catalogItem: CatalogItem {
        CatalogItem(kind: .macro, id: "m:\(id)", name: name, matchName: id, category: "Macros")
    }
}

// MARK: - Apply result

struct ApplyResult {
    var applied: Int
    var fromPlayhead: Bool
    var preserved: Int
    var warnings: [String]

    init(_ json: JSON) {
        applied = json["applied"]?.int ?? json["clips"]?.int ?? 0
        fromPlayhead = json["fromPlayhead"]?.bool ?? false
        preserved = json["paramsPreserved"]?.int ?? 0
        warnings = (json["warnings"]?.array ?? []).compactMap { $0.string }
    }
}
