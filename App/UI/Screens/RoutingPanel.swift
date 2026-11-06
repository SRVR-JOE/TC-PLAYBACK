import SwiftUI
import SwiftData

/// What a source channel carries, for the channel strip label.
enum ChannelContent: Equatable {
    case music, timecode, generator, none
    var label: String {
        switch self { case .music: "Music"; case .timecode: "Timecode"; case .generator: "Generator"; case .none: "No signal" }
    }
}

enum RoutingInfo {
    static func content(of side: SourceChannel, cue: Cue?) -> ChannelContent {
        guard let cue else { return .none }
        switch cue.kind {
        case .generator:
            let s = OutputSide(rawValue: cue.genSideRaw) ?? .right
            if s == .both { return .generator }
            return (s == .left) == (side == .left) ? .generator : .none
        case .track:
            guard let t = cue.track else { return .none }
            if side == .right && t.channelCount < 2 { return .none }
            if t.ltcChannel == side.rawValue { return .timecode }
            return .music
        }
    }

    /// Show-safety warnings for a cue's routing (timecode sharing an output with music etc).
    static func warnings(for cue: Cue?, routing: ChannelRouting) -> [String] {
        guard let cue else { return [] }
        var out: [String] = []
        switch cue.kind {
        case .generator:
            if OutputSide(rawValue: cue.genSideRaw) == .both { out.append("Timecode is sent to both outputs.") }
        case .track:
            guard let t = cue.track else { out.append("The audio file for this cue is missing."); break }
            if t.channelCount < 2, t.ltcChannel != nil {
                out.append("Mono file: timecode and music share one output.")
            }
            if t.ltcChannel != nil, routing.gainDB != 0 {
                out.append("Gain is applied to the timecode side too.")
            }
        }
        return out
    }
}

/// Shared routing actions + the Show Lock hold rule, used by every routing control.
@MainActor
struct RoutingActions {
    let shell = ShellModel.shared
    var context: ModelContext
    var showLock: Bool
    var routing: ChannelRouting { shell.routing }
    var cue: Cue? { shell.routingCue }
    /// While a cue plays under Show Lock, latching changes need press-and-hold.
    var needsHold: Bool { showLock && shell.isRunning }
    func enabled(_ side: SourceChannel) -> Bool { side == .left ? routing.leftEnabled : routing.rightEnabled }
    func toggle(_ side: SourceChannel) {
        var r = routing
        if side == .left { r.leftEnabled.toggle() } else { r.rightEnabled.toggle() }
        shell.setRouting(r, context: context)
    }
    func swap() { var r = routing; r.swapped.toggle(); shell.setRouting(r, context: context) }
    func setGain(_ db: Float) { var r = routing; r.gainDB = db; shell.setRouting(r, context: context) }
    func outputName(_ side: SourceChannel) -> String { (side == .left) != routing.swapped ? "Left" : "Right" }
}

/// Latching key that honours the Show Lock hold rule.
struct RoutingLatch<L: View>: View {
    var isOn: Bool
    var onColor: Color
    var needsHold: Bool
    var action: () -> Void
    @ViewBuilder var label: L
    var body: some View {
        if needsHold {
            HoldToConfirm(duration: 0.6, ringColor: Theme.standby, action: { action(); Haptics.tick() }) {
                label
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(isOn ? Color.white : Theme.textPrimary)
                    .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .fill(isOn ? onColor : Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .strokeBorder(isOn ? Color.clear : Theme.hairline, lineWidth: Theme.hairlineWidth))
                    .contentShape(Rectangle())
            }
        } else {
            Button { action(); Haptics.tick() } label: { label }
                .buttonStyle(LatchButtonStyle(isOn: isOn, onColor: onColor))
        }
    }
}

/// One source channel: name, what it carries, where it goes, Play/Mute.
/// `.card` for the routing panel, `.tall` for the mixer bank (with its own meter).
struct ChannelStrip: View {
    enum Style { case card, compactCard, tall }
    var side: SourceChannel
    var style: Style = .card
    @Environment(\.modelContext) private var context
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false

    var body: some View {
        let a = RoutingActions(context: context, showLock: showLock)
        let enabled = a.enabled(side)
        let content = RoutingInfo.content(of: side, cue: a.cue)
        Group {
            if style == .tall { tall(a, enabled: enabled, content: content) }
            else { card(a, enabled: enabled, content: content) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .fill(enabled ? Theme.surfaceRaised : Theme.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(enabled ? Theme.hairline : Theme.stop.opacity(0.55), lineWidth: enabled ? Theme.hairlineWidth : 1))
        .animation(.easeOut(duration: 0.15), value: enabled)
        .disabled(a.cue == nil)
    }

    private var letter: String { side == .left ? "L" : "R" }

    private func mutedLamp(_ enabled: Bool) -> some View {
        HStack(spacing: 5) {
            IndicatorLamp(color: Theme.stop, isOn: !enabled, size: 7)
            Text("Muted").font(Theme.caption)
                .foregroundStyle(enabled ? Theme.textTertiary.opacity(0.45) : Theme.stop)
        }
        .accessibilityHidden(enabled)
    }

    private func outLabel(_ a: RoutingActions) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .medium))
            Text("\(a.outputName(side)) out")
        }
        .font(Theme.caption)
        .foregroundStyle(a.routing.swapped ? Theme.standby : Theme.textSecondary)
    }

    private func key(_ a: RoutingActions, enabled: Bool) -> some View {
        RoutingLatch(isOn: !enabled, onColor: Theme.stop, needsHold: a.needsHold, action: { a.toggle(side) }) {
            HStack(spacing: 6) {
                Image(systemName: enabled ? "speaker.wave.2" : "speaker.slash")
                Text(enabled ? "Play" : "Mute")
            }
            .font(Theme.label)
        }
        .accessibilityLabel("\(side == .left ? "Left" : "Right") source, \(enabled ? "playing" : "muted")")
    }

    private func card(_ a: RoutingActions, enabled: Bool, content: ChannelContent) -> some View {
        let compact = style == .compactCard
        return VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(letter)
                    .font(.system(size: compact ? 22 : 26, weight: .semibold))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                Spacer()
                mutedLamp(enabled)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(content.label)
                    .font(Theme.label)
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                outLabel(a)
            }
            key(a, enabled: enabled).frame(height: compact ? 34 : 38)
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tall(_ a: RoutingActions, enabled: Bool, content: ChannelContent) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(letter)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                Text(content.label).font(Theme.label)
                    .foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary)
                    .lineLimit(1)
            }
            mutedLamp(enabled)
            // The strip's meter shows the output its source is routed to.
            ChannelMeter(side: (side == .left) != a.routing.swapped ? .left : .right, dimmed: !enabled)
                .frame(width: 26)
                .frame(maxHeight: .infinity)
            key(a, enabled: enabled).frame(height: 44)
            VStack(spacing: 3) {
                outLabel(a)
                Text(Fmt.dB(a.routing.gainDB)).font(Theme.numeric(12, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Swap key with a diagram that visibly crosses the outputs.
struct SwapKey: View {
    var compact = false
    var tall = false
    @Environment(\.modelContext) private var context
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false

    var body: some View {
        let a = RoutingActions(context: context, showLock: showLock)
        let swapped = a.routing.swapped
        VStack(spacing: 6) {
            CrossDiagram(swapped: swapped)
                .stroke(swapped ? Theme.standby : Theme.textTertiary,
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                .frame(width: 26, height: 26)
                .animation(.easeOut(duration: 0.18), value: swapped)
            RoutingLatch(isOn: swapped, onColor: Theme.standby, needsHold: a.needsHold, action: { a.swap() }) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .medium))
            }
            .frame(width: compact ? 38 : 42, height: tall ? 72 : (compact ? 34 : 38))
            Text(swapped ? "Swapped" : "Swap").font(Theme.caption)
                .foregroundStyle(swapped ? Theme.standby : Theme.textSecondary)
                .fixedSize()
        }
        .disabled(a.cue == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(swapped ? "Swapped. Left source plays out right." : "Swap outputs")
    }
}

/// Track gain slider in dB (double-tap the readout for 0 dB).
struct GainRow: View {
    @Environment(\.modelContext) private var context
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    var body: some View {
        let a = RoutingActions(context: context, showLock: showLock)
        HStack(spacing: 10) {
            Text("Gain").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            FaderSlider(value: Binding(
                get: { Double(max(a.routing.gainDB, -40)) },
                set: { v in a.setGain(abs(v) < 0.4 ? 0 : Float((v * 2).rounded() / 2)) }), range: -40...6)
            .disabled(a.cue == nil || a.needsHold)
            Text(Fmt.dB(a.routing.gainDB))
                .font(Theme.numeric(12, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 64, alignment: .trailing)
                .onTapGesture(count: 2) { if !a.needsHold { a.setGain(0) } }
        }
    }
}

/// Amber show-safety warnings for the routing cue.
struct RoutingWarnings: View {
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    var body: some View {
        let warnings = RoutingInfo.warnings(for: shell.routingCue, routing: shell.routing)
        if !warnings.isEmpty || (showLock && shell.isRunning) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.standby)
                }
                if showLock && shell.isRunning {
                    Text("Show Lock: hold to change routing.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

/// Routing panel: L strip · Swap · R strip, gain, warnings.
struct RoutingPanel: View {
    var compact = false
    @Bindable private var shell = ShellModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            SectionHeader("Routing") {
                if let cue = shell.routingCue {
                    Text(shell.isRunning ? "Playing \(cue.number)" : "Standby \(cue.number)")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(spacing: 0) {
                ChannelStrip(side: .left, style: compact ? .compactCard : .card)
                SwapKey(compact: compact).frame(width: compact ? 58 : 66)
                ChannelStrip(side: .right, style: compact ? .compactCard : .card)
            }
            GainRow()
            RoutingWarnings()
        }
    }
}

/// Single-channel vertical OUTPUT meter (dBFS −60…0) on the engine's analysis snapshot, for
/// the mixer bank where each strip carries its own meter.
struct ChannelMeter: View {
    var side: SourceChannel
    var dimmed = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let snap = PlaybackEngine.shared.analysisSnapshot()
            let lin = side == .left ? snap.outputPeak.l : snap.outputPeak.r
            let db: Float = lin > 0 ? max(-60, 20 * log10(lin)) : -60
            let clip = side == .left ? snap.outputClip.l : snap.outputClip.r
            Canvas { g, size in
                let segs = 48
                let gap: CGFloat = 1.5
                let h = (size.height - CGFloat(segs - 1) * gap) / CGFloat(segs)
                for i in 0..<segs {
                    let segDB = -60 + Float(i + 1) * 60 / Float(segs)
                    let y = size.height - CGFloat(i + 1) * h - CGFloat(i) * gap
                    let lit = segDB <= db + 0.01
                    let color: Color = segDB > -6 ? Theme.meterHigh : (segDB > -18 ? Theme.meterMid : Theme.meterLow)
                    g.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h)),
                           with: .color(lit ? color.opacity(dimmed ? 0.35 : 1) : Theme.lockOff.opacity(0.35)))
                }
                if clip {
                    g.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 3)), with: .color(Theme.stop))
                }
            }
        }
        .padding(3)
        .background(Theme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

/// Two lines: straight (L→L, R→R) or crossed (L→R, R→L).
struct CrossDiagram: Shape {
    var swapped: Bool
    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }
    private var t: CGFloat = 0
    init(swapped: Bool) { self.swapped = swapped; self.t = swapped ? 1 : 0 }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = rect.minY + 4, bottom = rect.maxY - 4
        let l = rect.minX + 2, r = rect.maxX - 2
        p.move(to: CGPoint(x: l, y: top))
        p.addLine(to: CGPoint(x: l + (r - l) * t, y: bottom))
        p.move(to: CGPoint(x: r, y: top))
        p.addLine(to: CGPoint(x: r - (r - l) * t, y: bottom))
        for x in [l, r] {
            p.addEllipse(in: CGRect(x: x - 1.5, y: top - 1.5, width: 3, height: 3))
            p.addEllipse(in: CGRect(x: x - 1.5, y: bottom - 1.5, width: 3, height: 3))
        }
        return p
    }
}
