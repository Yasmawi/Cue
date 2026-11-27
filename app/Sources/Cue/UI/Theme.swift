import SwiftUI
import AppKit

struct Theme: Identifiable, Equatable {
    var id: String
    var name: String
    var isDark: Bool
    var background: Color
    var surface: Color
    var text: Color
    var secondary: Color
    var accent: Color
    var selection: Color
    var border: Color
    var material: NSVisualEffectView.Material

    static let all: [Theme] = [
        Theme(id: "midnight", name: "Midnight", isDark: true,
              background: Color(hex: "#15161C"), surface: Color(hex: "#1F2029"), text: Color(hex: "#ECECF1"),
              secondary: Color(hex: "#8B8D9C"), accent: Color(hex: "#7C5CFF"), selection: Color(hex: "#7C5CFF").opacity(0.22),
              border: Color.white.opacity(0.08), material: .hudWindow),
        Theme(id: "graphite", name: "Graphite", isDark: true,
              background: Color(hex: "#232323"), surface: Color(hex: "#2D2D2D"), text: Color(hex: "#E6E6E6"),
              secondary: Color(hex: "#9A9A9A"), accent: Color(hex: "#2D8CEB"), selection: Color(hex: "#2D8CEB").opacity(0.25),
              border: Color.white.opacity(0.07), material: .menu),
        Theme(id: "ember", name: "Ember", isDark: true,
              background: Color(hex: "#1B1512"), surface: Color(hex: "#271E19"), text: Color(hex: "#F4E9E1"),
              secondary: Color(hex: "#A8958A"), accent: Color(hex: "#FF7A3D"), selection: Color(hex: "#FF7A3D").opacity(0.22),
              border: Color.white.opacity(0.07), material: .hudWindow),
        Theme(id: "aurora", name: "Aurora", isDark: true,
              background: Color(hex: "#0F1B1C"), surface: Color(hex: "#162728"), text: Color(hex: "#E3F4F1"),
              secondary: Color(hex: "#86A7A2"), accent: Color(hex: "#2FD3A5"), selection: Color(hex: "#2FD3A5").opacity(0.2),
              border: Color.white.opacity(0.07), material: .hudWindow),
        Theme(id: "daylight", name: "Daylight", isDark: false,
              background: Color(hex: "#F7F7F9"), surface: Color(hex: "#FFFFFF"), text: Color(hex: "#1C1C22"),
              secondary: Color(hex: "#6E6E7A"), accent: Color(hex: "#5B4BDB"), selection: Color(hex: "#5B4BDB").opacity(0.14),
              border: Color.black.opacity(0.08), material: .popover),
    ]

    static func resolve(_ prefs: Preferences) -> Theme {
        var t = all.first(where: { $0.id == prefs.themeID }) ?? all[0]
        if let hex = prefs.accentHex, !hex.isEmpty {
            t.accent = Color(hex: hex)
            t.selection = Color(hex: hex).opacity(t.isDark ? 0.22 : 0.14)
        }
        return t
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = material
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
