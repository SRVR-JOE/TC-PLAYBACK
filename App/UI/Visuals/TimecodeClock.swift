import SwiftUI
import UIKit
import TCKit

// Owned by the VISUALS agent. Implementation behind `TimecodeClockView` (see VisualsAPI.swift).

// MARK: - Display state

/// What the operator sees, after de-glitching the raw lock state.
enum ClockDisplayState: Equatable {
    case locked, acquiring, freewheel, lost, noTimecode, generator, trackTime

    var word: String {
        switch self {
        case .locked: "Locked"
        case .acquiring: "Acquiring"
        case .freewheel: "Freewheel"
        case .lost: "Lost"
        case .noTimecode: "No timecode"
        case .generator: "Generator"
        case .trackTime: "Track time"
        }
    }

    /// Lamp colour; nil = lamp off. Always paired with `word`, never colour alone.
    var lampColor: Color? {
        switch self {
        case .locked, .generator: Theme.lockOK
        case .acquiring, .freewheel: Theme.lockWarn
        case .lost: Theme.stop
        case .noTimecode, .trackTime: nil
        }
    }

    fileprivate var hadSignal: Bool { self == .locked || self == .acquiring || self == .freewheel }
}

/// Ignores single-frame glitches (a state must persist > 2 frames), turns a real loss into
/// "Lost" (red) for 2 s, then settles on "No timecode". Holds the last good timecode meanwhile.
final class ClockStateFilter {
    private(set) var shown: ClockDisplayState?
    private var candidate: ClockDisplayState?
    private var candidateSince: Double = 0
    private var lostSince: Double = 0
    private(set) var lastTimecode: Timecode?
    static let lostHold: Double = 2

    func update(_ c: ClockStatus, now: Double) -> ClockDisplayState {
        let raw: ClockDisplayState
        switch c.source {
        case .trackTime: raw = .trackTime
        case .generator: raw = .generator
        case .decoded, .externalInput:
            switch c.lock {
            case .locked: raw = .locked
            case .acquiring: raw = .acquiring
            case .freewheel: raw = .freewheel
            case .noSignal: raw = .noTimecode
            }
        }
        if let tc = c.timecode { lastTimecode = tc }

        guard let current = shown else { shown = raw; candidate = raw; candidateSince = now; return raw }
        if raw != candidate { candidate = raw; candidateSince = now }
        let frame = 1 / (c.rate?.fps ?? 30)
        // Source changes (track time ↔ LTC ↔ generator) show at once; lock changes are debounced.
        let immediate = raw == .trackTime || raw == .generator || current == .trackTime || current == .generator
        if raw != current, immediate || now - candidateSince > 2 * frame {
            if raw == .noTimecode {
                if current.hadSignal { shown = .lost; lostSince = now }
                else if current != .lost { shown = .noTimecode }
            } else {
                shown = raw
            }
        }
        if shown == .lost, now - lostSince > Self.lostHold { shown = .noTimecode }
        return shown ?? raw
    }
}

// MARK: - Clock

struct TimecodeClockContent: View {
    var compact: Bool

    @Environment(\.visualsDataSource) private var data
    @Environment(\.colorScheme) private var scheme
    @AppStorage(SettingsKey.clockStyle) private var styleRaw = ClockStyle.mono.rawValue
    @AppStorage(SettingsKey.clockColorPreset) private var presetRaw = ClockColorPreset.white.rawValue
    @AppStorage(SettingsKey.clockCustomColorHex) private var customHex = "#F2F3F5"
    @State private var filter = ClockStateFilter()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let clock = data.clock
            let state = filter.update(clock, now: tl.date.timeIntervalSinceReferenceDate)
            let tc = displayedTimecode(clock, state)
            let df = (clock.rate ?? tc?.rate)?.isDropFrame ?? false
            let text = VisualsFormat.timecode(tc, dropFrame: df)
            let digits = ClockFace(text: text, style: ClockStyle(rawValue: styleRaw) ?? .mono,
                                   color: digitColor(state))
                .overlay(alignment: .topTrailing) {
                    if compact, state == .freewheel || state == .lost {
                        ClockStateBadge(state: state).padding(2)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Timecode \(text.replacingOccurrences(of: ";", with: ":"))")
                .accessibilityValue(state.word)

            if compact {
                digits
            } else {
                VStack(spacing: 10) {
                    digits
                    ClockStatusLine(state: state, clock: clock,
                                    elapsed: data.duration > 0 || data.currentTime > 0 ? data.currentTime : nil,
                                    remaining: data.duration > 0 ? data.currentTime - data.duration : nil)
                }
            }
        }
    }

    private func displayedTimecode(_ c: ClockStatus, _ state: ClockDisplayState) -> Timecode? {
        switch state {
        case .trackTime:
            return c.timecode ?? Timecode(realSeconds: data.currentTime, rate: c.rate ?? .fps30)
        case .locked, .acquiring, .freewheel, .lost, .generator:
            return c.timecode ?? filter.lastTimecode
        case .noTimecode:
            return c.timecode
        }
    }

    private var userColor: Color {
        let preset = ClockColorPreset(rawValue: presetRaw) ?? .white
        if preset == .custom { return Color(hexString: customHex) ?? preset.color }
        // White digits vanish on a light surface; use ink instead.
        if preset == .white, scheme == .light { return Color(hex: 0x16181B) }
        return preset.color
    }

    private func digitColor(_ s: ClockDisplayState) -> Color {
        switch s {
        case .locked, .generator, .trackTime: userColor
        case .acquiring: userColor.opacity(0.7)
        case .freewheel: Theme.lockWarn
        case .lost: Theme.stop
        case .noTimecode: userColor.opacity(0.45)
        }
    }
}

// MARK: - Face (fits the largest size into the frame)

struct ClockFace: View {
    let text: String
    let style: ClockStyle
    let color: Color

    var body: some View {
        GeometryReader { geo in
            switch style {
            case .segment:
                SevenSegmentText(text: text, color: color)
                    .frame(width: geo.size.width, height: geo.size.height)
            case .mono, .rounded:
                let m = ClockFontMetrics.metrics(for: style)
                let template = String(text.map { $0.isNumber || $0 == "-" ? "0" : $0 })
                let w100 = m.width(of: template)
                // Fit the digit cap-height (with a little air) and the full string width.
                let size = max(6, min(geo.size.width * 0.98 / w100, geo.size.height / (m.capHeight * 1.12)) * 100)
                let k = size / 100
                Text(text)
                    .font(Font(m.font(size: size) as CTFont))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
                    // Centre the cap-height glyphs, not the line box.
                    .offset(y: (m.lineHeight / 2 - (m.ascender - m.capHeight / 2)) * k)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .frame(minWidth: 40, minHeight: 14)
    }
}

/// Font metrics at 100 pt, cached per style.
struct ClockFontMetrics {
    let style: ClockStyle
    let capHeight: CGFloat, ascender: CGFloat, lineHeight: CGFloat
    private let base: UIFont
    private static var cache: [ClockStyle: ClockFontMetrics] = [:]
    private var widths: [String: CGFloat] = [:]

    static func metrics(for style: ClockStyle) -> ClockFontMetrics {
        if let m = cache[style] { return m }
        let m = ClockFontMetrics(style: style)
        cache[style] = m
        return m
    }

    private init(style: ClockStyle) {
        self.style = style
        base = Self.makeFont(style, size: 100)
        capHeight = base.capHeight; ascender = base.ascender; lineHeight = base.lineHeight
    }

    static func makeFont(_ style: ClockStyle, size: CGFloat) -> UIFont {
        switch style {
        case .rounded:
            let f = UIFont.systemFont(ofSize: size, weight: .medium)
            var d = f.fontDescriptor.withDesign(.rounded) ?? f.fontDescriptor
            // Tabular (monospaced) digits so nothing jiggles.
            d = d.addingAttributes([.featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                                                        UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]]])
            return UIFont(descriptor: d, size: size)
        default:
            return UIFont.monospacedSystemFont(ofSize: size, weight: .medium)
        }
    }

    func font(size: CGFloat) -> UIFont { Self.makeFont(style, size: size) }

    func width(of s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: base]).width
    }
}

// MARK: - Status line

struct ClockStatusLine: View {
    let state: ClockDisplayState
    let clock: ClockStatus
    let elapsed: TimeInterval?
    let remaining: TimeInterval?

    private var isLTC: Bool {
        switch clock.source { case .decoded, .externalInput: true; default: false }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(level: true, source: true, extras: true)
            line(level: true, source: true, extras: false)
            line(level: true, source: false, extras: false)
            line(level: false, source: false, extras: false)
            HStack(spacing: 10) { ClockStateBadge(state: state); Spacer(minLength: 0) }
        }
        .font(Theme.label)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func line(level: Bool, source: Bool, extras: Bool) -> some View {
        HStack(spacing: 10) {
            ClockStateBadge(state: state)
            if let r = clock.rate, state != .trackTime {
                divider
                HStack(spacing: 3) {
                    Text(VisualsFormat.rate(r)).font(Theme.numeric(13))
                    if VisualsFormat.rateNeedsUnit(r) { Text("fps") }
                }
                .foregroundStyle(Theme.textPrimary)
            }
            if source {
                divider
                Text(VisualsFormat.sourceLabel(clock.source))
            }
            if level, isLTC, state != .noTimecode, let db = clock.ltcLevelDBFS {
                divider
                LTCLevelReadout(levelDBFS: db)
            }
            if clock.isReverse, state != .noTimecode {
                divider
                Label("Reverse", systemImage: "backward")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.lockWarn)
            }
            if extras, isLTC {
                divider
                DropoutCounter(count: clock.discontinuities)
            }
            Spacer(minLength: 16)
            if let elapsed {
                Text(VisualsFormat.time(elapsed))
                    .font(Theme.numeric(13))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityLabel("Elapsed \(VisualsFormat.time(elapsed))")
            }
            if let remaining {
                Text(VisualsFormat.time(min(0, remaining)))
                    .font(Theme.numeric(13))
                    .accessibilityLabel("Remaining \(VisualsFormat.time(abs(remaining)))")
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 12)
    }
}

/// Lamp + state word.
struct ClockStateBadge: View {
    let state: ClockDisplayState
    var body: some View {
        HStack(spacing: 6) {
            IndicatorLamp(color: state.lampColor ?? Theme.lockOff, isOn: state.lampColor != nil, size: 9)
            Text(state.word)
                .font(Theme.label)
                .foregroundStyle(state == .lost ? Theme.stop : Theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "−12.4 dBFS" with a small target-band gauge; amber + "Low"/"Hot" outside −20…−10.
struct LTCLevelReadout: View {
    let levelDBFS: Float
    var body: some View {
        let band = LTCLevelBand(levelDBFS)
        let warn = band != .ok
        HStack(spacing: 6) {
            LTCLevelGauge(levelDBFS: levelDBFS)
            HStack(spacing: 3) {
                Text(VisualsFormat.db(levelDBFS)).font(Theme.numeric(13))
                    .foregroundStyle(warn ? Theme.lockWarn : Theme.textPrimary)
                Text("dBFS")
            }
            if let w = band.word {
                Text(w).foregroundStyle(Theme.lockWarn)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timecode level \(VisualsFormat.db(levelDBFS)) dBFS\(band.word.map { ", \($0)" } ?? "")")
    }
}

/// 44 × 8 pt gauge, −40…0 dBFS, the −20…−10 target band outlined, a marker at the level.
struct LTCLevelGauge: View {
    let levelDBFS: Float
    var body: some View {
        Canvas { gc, size in
            func x(_ db: Float) -> CGFloat { CGFloat((max(-40, min(0, db)) + 40) / 40) * size.width }
            let r = CGRect(origin: .zero, size: size)
            gc.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(Theme.surfaceSunken))
            let band = CGRect(x: x(-20), y: 0, width: x(-10) - x(-20), height: size.height)
            gc.fill(Path(band), with: .color(Theme.hairline))
            let warn = LTCLevelBand(levelDBFS) != .ok
            let mx = x(levelDBFS)
            gc.fill(Path(CGRect(x: mx - 1, y: 0, width: 2, height: size.height)),
                    with: .color(warn ? Theme.lockWarn : Theme.textPrimary))
            gc.stroke(Path(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), cornerRadius: 1.5),
                      with: .color(Theme.hairline), lineWidth: 0.5)
        }
        .frame(width: 44, height: 8)
    }
}

struct DropoutCounter: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("Dropouts")
            Text("\(count)").font(Theme.numeric(13))
                .foregroundStyle(count > 0 ? Theme.lockWarn : Theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Additive: standalone LTC health block (level vs. target band + dropout counter) for screens
/// that want it outside the clock status line.
struct LTCHealthView: View {
    @Environment(\.visualsDataSource) private var data
    var body: some View {
        let c = data.clock
        HStack(spacing: 10) {
            if let db = c.ltcLevelDBFS, c.lock != .noSignal {
                LTCLevelReadout(levelDBFS: db)
            } else {
                Text("No timecode").foregroundStyle(Theme.textTertiary)
            }
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 12)
            DropoutCounter(count: c.discontinuities)
        }
        .font(Theme.label)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
    }
}
