import SwiftUI
import TCKit

// Owned by the VISUALS agent. Shared formatting and small styling helpers for the visuals.

enum VisualsFormat {
    static let minus = "\u{2212}"

    /// Operator rate label: "23.976", "24", "25", "29.97 DF", "29.97 ND", "30".
    static func rate(_ r: FrameRate) -> String {
        switch r {
        case .fps29_97ndf: return "29.97 ND"
        default: return r.label
        }
    }

    /// Whether the rate label needs a trailing "fps" (DF / ND labels already say what they are).
    static func rateNeedsUnit(_ r: FrameRate) -> Bool { !(r == .fps29_97df || r == .fps29_97ndf) }

    /// "12:04", "1:02:33"; negative values get a true minus sign.
    static func time(_ t: TimeInterval) -> String {
        let neg = t < 0
        let s = Int(abs(t).rounded(.down))
        let h = s / 3600, m = (s / 60) % 60, sec = s % 60
        let body = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        return neg ? minus + body : body
    }

    /// "1:23.4" for scrub readouts.
    static func preciseTime(_ t: TimeInterval) -> String {
        let t = max(0, t)
        let tenths = Int((t * 10).rounded(.down))
        let s = tenths / 10, m = s / 60
        return String(format: "%d:%02d.%d", m, s % 60, tenths % 10)
    }

    /// "−10.4" (dBFS number only).
    static func db(_ v: Float, decimals: Int = 1) -> String {
        guard v.isFinite, v > -120 else { return minus + "\u{221E}" }
        let r = String(format: "%.\(decimals)f", abs(v))
        if r == String(format: "%.\(decimals)f", 0.0) { return r }
        return v < 0 ? minus + r : r
    }

    /// "HH:MM:SS:FF" with ";" before frames for drop-frame; dashes when nil.
    static func timecode(_ tc: Timecode?, dropFrame: Bool) -> String {
        let sep = dropFrame ? ";" : ":"
        guard let tc else { return "--:--:--" + sep + "--" }
        return String(format: "%02d:%02d:%02d%@%02d", tc.hours, tc.minutes, tc.seconds, sep, tc.frames)
    }

    static func sourceLabel(_ s: ClockSource) -> String {
        switch s {
        case .trackTime: return "Track time"
        case .decoded(.left): return "LTC \u{00B7} Left"
        case .decoded(.right): return "LTC \u{00B7} Right"
        case .generator: return "Generator"
        case .externalInput: return "Input"
        }
    }
}

/// LTC level target band. Crews lose lock mostly on level, so this is shown at a glance.
enum LTCLevelBand {
    case low, ok, hot
    static let range: ClosedRange<Float> = -20 ... -10

    init(_ dbfs: Float) {
        let v = (dbfs * 10).rounded() / 10
        self = v < Self.range.lowerBound ? .low : (v > Self.range.upperBound ? .hot : .ok)
    }

    var word: String? {
        switch self { case .low: "Low"; case .hot: "Hot"; case .ok: nil }
    }
}

/// Small flat key used by the scope controls: hairline border, raised graphite fill.
struct VisualsKeyStyle: ButtonStyle {
    var isOn = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption.weight(.medium))
            .foregroundStyle(isOn ? VisualsColor.primary : VisualsColor.secondary)
            .padding(.horizontal, 7)
            .frame(minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isPressed ? VisualsColor.pressed : VisualsColor.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(VisualsColor.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

/// Text/chrome colours for anything the visuals draw on the HOST surface (status line, meter
/// scale, scope controls). Theme is dark-only today; these follow light/dark. Instrument wells
/// (scope screen, meter bars, waveform) stay dark in both modes and keep using Theme directly.
/// If the shell makes Theme adaptive, these can collapse back onto it.
enum VisualsColor {
    static func dynamic(_ dark: Color, light: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .light ? UIColor(Color(hex: light)) : UIColor(dark) })
    }
    static let primary = dynamic(Theme.textPrimary, light: 0x16181B)
    static let secondary = dynamic(Theme.textSecondary, light: 0x5A6068)
    static let tertiary = dynamic(Theme.textTertiary, light: 0x8C9199)
    static let hairline = dynamic(Theme.hairline, light: 0xD2D5DA)
    static let raised = dynamic(Theme.surfaceRaised, light: 0xFFFFFF)
    static let pressed = dynamic(Theme.hairline, light: 0xE4E6EA)
}
