import SwiftUI
import UIKit
import TCKit

// CONTRACT FILE — owned by the APP SHELL agent (may refine values; keep names).
// Visual direction: broadcast control gear (Lawo, Riedel, Evertz, Ross). Flat graphite,
// hairline dividers, small indicator lamps, colour only for state/tally, mono only for
// numbers. NO glows, NO neon, NO gradients-as-decoration, NO pills on everything,
// NO letter-spaced all-caps mono labels, NO developer wording in the UI.
//
// Every colour is dynamic: the dark value is the design spec, the light value is a matched
// "daylight" variant (same hierarchy, state colours deepened for contrast on white).

enum Theme {
    // Surfaces
    static let background = Color(token: \.background)
    static let surface = Color(token: \.surface)
    static let surfaceRaised = Color(token: \.surfaceRaised)
    static let surfaceSunken = Color(token: \.surfaceSunken)
    static let hairline = Color(token: \.hairline)
    // Text
    static let textPrimary = Color(token: \.textPrimary)
    static let textSecondary = Color(token: \.textSecondary)
    static let textTertiary = Color(token: \.textTertiary)
    // State
    static let accent = Color(token: \.accent)
    static let go = Color(token: \.go)
    static let standby = Color(token: \.standby)
    static let stop = Color(token: \.stop)
    static let lockOK = Color(token: \.go)
    static let lockWarn = Color(token: \.standby)
    static let lockOff = Color(token: \.lockOff)
    // Meters (classic broadcast segments)
    static let meterLow = Color(token: \.go)          // below -18 dBFS
    static let meterMid = Color(token: \.meterMid)    // -18…-6
    static let meterHigh = Color(token: \.stop)       // above -6
    static let scopeTrace = Color(token: \.scopeTrace)
    static let scopeGrid = Color(token: \.scopeGrid)

    // Metrics
    static let corner: CGFloat = 6
    static let cornerLarge: CGFloat = 10
    static let hairlineWidth: CGFloat = 1 / UIScreen.main.scale
    static let pad: CGFloat = 12

    // Type
    static func numeric(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Scales with Dynamic Type (13 pt at the default size).
    static let label = Font.system(.subheadline, weight: .medium)
    /// Scales with Dynamic Type (12 pt at the default size).
    static let caption = Font.system(.caption, weight: .regular)
    /// Section header: SF Pro 12 semibold, sentence case, secondary colour.
    static let sectionHeader = Font.system(.caption, weight: .semibold)
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
        case .white: Color(dark: 0xF2F3F5, light: 0x14161A)
        case .amber: Color(hex: 0xFFB020)
        case .red: Color(hex: 0xFF4B42)
        case .green: Color(hex: 0x3DDC6E)
        case .blue: Color(hex: 0x5AA2FF)
        case .custom: Color(hex: 0xF2F3F5)
        }
    }
}

/// App colour theme (Settings › Theme). Graphite is the design spec; Light is the daylight
/// variant. Every `Theme` colour resolves from the active theme at draw time.
enum AppTheme: String, CaseIterable, Identifiable {
    case graphite, midnight, trueBlack, light
    var id: String { rawValue }
    var label: String {
        switch self { case .graphite: "Graphite"; case .midnight: "Midnight"; case .trueBlack: "True Black"; case .light: "Light" }
    }
    /// The theme in use; kept in step with @AppStorage(SettingsKey.theme) by the root view.
    static var active: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: SettingsKey.theme) ?? "") ?? .graphite
    /// The dark palette used when the interface is dark (Light falls back to Graphite).
    var darkPalette: ThemePalette {
        switch self {
        case .graphite, .light: .graphite
        case .midnight: .midnight
        case .trueBlack: .trueBlack
        }
    }
}

struct ThemePalette {
    var background, surface, surfaceRaised, surfaceSunken, hairline: UInt32
    var textPrimary, textSecondary, textTertiary: UInt32
    var accent, go, standby, stop, lockOff, meterMid, scopeTrace, scopeGrid: UInt32

    static let graphite = ThemePalette(
        background: 0x0E0F11, surface: 0x16181B, surfaceRaised: 0x1D2024, surfaceSunken: 0x0A0B0D, hairline: 0x2A2E33,
        textPrimary: 0xE8EAED, textSecondary: 0x9097A0, textTertiary: 0x5D636B,
        accent: 0x3D8BFD, go: 0x2FB85A, standby: 0xE5A50A, stop: 0xE5484D, lockOff: 0x3A3F45,
        meterMid: 0xD9C21A, scopeTrace: 0xC9D1D9, scopeGrid: 0x23272C)
    static let midnight = ThemePalette(
        background: 0x0B0F17, surface: 0x121826, surfaceRaised: 0x182032, surfaceSunken: 0x080B11, hairline: 0x232C3D,
        textPrimary: 0xE3E8F2, textSecondary: 0x8D97AA, textTertiary: 0x566175,
        accent: 0x4C8DFF, go: 0x2FB85A, standby: 0xE5A50A, stop: 0xE5484D, lockOff: 0x2E3748,
        meterMid: 0xD9C21A, scopeTrace: 0xC8D2E2, scopeGrid: 0x1B2333)
    static let trueBlack = ThemePalette(
        background: 0x000000, surface: 0x0A0A0B, surfaceRaised: 0x121315, surfaceSunken: 0x000000, hairline: 0x1C1D20,
        textPrimary: 0xE8EAED, textSecondary: 0x8C9199, textTertiary: 0x585C63,
        accent: 0x3D8BFD, go: 0x2FB85A, standby: 0xE5A50A, stop: 0xE5484D, lockOff: 0x2C2F33,
        meterMid: 0xD9C21A, scopeTrace: 0xC9D1D9, scopeGrid: 0x17181B)
    static let light = ThemePalette(
        background: 0xEEEFF1, surface: 0xFFFFFF, surfaceRaised: 0xF6F7F8, surfaceSunken: 0xE4E6E9, hairline: 0xD3D6DA,
        textPrimary: 0x14161A, textSecondary: 0x5B616A, textTertiary: 0x949AA2,
        accent: 0x1F6FE5, go: 0x1E9E48, standby: 0xC88A00, stop: 0xD7353B, lockOff: 0xC4C8CD,
        meterMid: 0xC2A800, scopeTrace: 0x2A3038, scopeGrid: 0xD2D5D9)
}

/// App appearance. Default is dark; "system" switches to the Light theme when the device is light.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String { switch self { case .dark: "Dark"; case .light: "Light"; case .system: "System" } }
    var colorScheme: ColorScheme? { switch self { case .dark: .dark; case .light: .light; case .system: nil } }
}

/// @AppStorage keys shared across modules.
enum SettingsKey {
    static let clockStyle = "clockStyle"           // ClockStyle.rawValue
    static let clockColorPreset = "clockColor"     // ClockColorPreset.rawValue
    static let clockCustomColorHex = "clockCustomHex" // "#RRGGBB"
    static let appearance = "appearance"           // "dark" | "light" | "system"
    static let theme = "theme"                     // AppTheme.rawValue (default graphite)
    static let layoutMode = "layoutMode"           // iPad main screen: console | clock | mixer | show
    static let showLock = "showLock"               // Bool — locks editing/scrubbing during a show
    static let keepAwake = "keepAwake"             // Bool
    static let preRollSeconds = "preRoll"          // Double
    // Additive (shell):
    static let doubleGoWindow = "doubleGoWindow"   // Double seconds, 0 = off (default 1)
    static let panicFadeSeconds = "panicFade"      // Double seconds (default 1)
    static let autoDetectTimecode = "autoDetectTC" // Bool (default true)
    static let readExternalInput = "readInputTC"   // Bool (default false)
    static let currentPlaylistID = "currentPlaylistID" // UUID string
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
    /// Theme token resolved at draw time from the active theme and the interface style.
    init(token: KeyPath<ThemePalette, UInt32>) {
        self.init(uiColor: UIColor { traits in
            let palette = traits.userInterfaceStyle == .light ? ThemePalette.light : AppTheme.active.darkPalette
            return UIColor(hex: palette[keyPath: token])
        })
    }
    /// Dynamic colour: `dark` in dark appearance, `light` in light appearance.
    init(dark: UInt32, light: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .light ? light : dark)
        })
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
        let clamp = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension FrameRate {
    /// Operator-facing label: "23.976 / 24 / 25 / 29.97 DF / 29.97 ND / 30".
    var operatorLabel: String {
        switch self {
        case .fps29_97ndf: return "29.97 ND"
        case .fps29_97df: return "29.97 DF"
        default: return rawValue
        }
    }
}
