import SwiftUI

// CONTRACT FILE — owned by the APP SHELL agent (may refine values; keep names).
// Visual direction: broadcast control gear (Lawo, Riedel, Evertz, Ross). Flat graphite,
// hairline dividers, small indicator lamps, colour only for state/tally, mono only for
// numbers. NO glows, NO neon, NO gradients-as-decoration, NO pills on everything,
// NO letter-spaced all-caps mono labels, NO developer wording in the UI.

enum Theme {
    // Surfaces (dark)
    static let background = Color(hex: 0x0E0F11)
    static let surface = Color(hex: 0x16181B)
    static let surfaceRaised = Color(hex: 0x1D2024)
    static let surfaceSunken = Color(hex: 0x0A0B0D)
    static let hairline = Color(hex: 0x2A2E33)
    // Text
    static let textPrimary = Color(hex: 0xE8EAED)
    static let textSecondary = Color(hex: 0x9097A0)
    static let textTertiary = Color(hex: 0x5D636B)
    // State
    static let accent = Color(hex: 0x3D8BFD)
    static let go = Color(hex: 0x2FB85A)
    static let standby = Color(hex: 0xE5A50A)
    static let stop = Color(hex: 0xE5484D)
    static let lockOK = Color(hex: 0x2FB85A)
    static let lockWarn = Color(hex: 0xE5A50A)
    static let lockOff = Color(hex: 0x3A3F45)
    // Meters (classic broadcast segments)
    static let meterLow = Color(hex: 0x2FB85A)     // below -18 dBFS
    static let meterMid = Color(hex: 0xD9C21A)     // -18…-6
    static let meterHigh = Color(hex: 0xE5484D)    // above -6
    static let scopeTrace = Color(hex: 0xC9D1D9)
    static let scopeGrid = Color(hex: 0x23272C)

    // Metrics
    static let corner: CGFloat = 6
    static let cornerLarge: CGFloat = 10
    static let hairlineWidth: CGFloat = 1 / UIScreen.main.scale
    static let pad: CGFloat = 12

    // Type
    static func numeric(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let label = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
}

/// Timecode clock appearance — user-selectable in Settings, persisted with @AppStorage.
enum ClockStyle: String, CaseIterable, Identifiable {
    case mono      // SF Mono
    case rounded   // SF Pro Rounded, monospaced digits
    case segment   // drawn seven-segment (flat, no glow)
    var id: String { rawValue }
    var label: String { switch self { case .mono: "Mono"; case .rounded: "Rounded"; case .segment: "Segment" } }
}

/// Preset clock colours; the user can also choose any custom colour.
enum ClockColorPreset: String, CaseIterable, Identifiable {
    case white, amber, red, green, blue, custom
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .white: Color(hex: 0xF2F3F5)
        case .amber: Color(hex: 0xFFB020)
        case .red: Color(hex: 0xFF4B42)
        case .green: Color(hex: 0x3DDC6E)
        case .blue: Color(hex: 0x5AA2FF)
        case .custom: Color(hex: 0xF2F3F5)
        }
    }
}

/// @AppStorage keys shared across modules.
enum SettingsKey {
    static let clockStyle = "clockStyle"           // ClockStyle.rawValue
    static let clockColorPreset = "clockColor"     // ClockColorPreset.rawValue
    static let clockCustomColorHex = "clockCustomHex" // "#RRGGBB"
    static let appearance = "appearance"           // "dark" | "light" | "system"
    static let showLock = "showLock"               // Bool — locks editing/scrubbing during a show
    static let keepAwake = "keepAwake"             // Bool
    static let preRollSeconds = "preRoll"          // Double
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
    /// "#RRGGBB" → Color.
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
    /// Color → "#RRGGBB".
    var hexString: String {
        let c = UIColor(self).resolvedColor(with: .current)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
