import SwiftUI
import TCKit

/// Input Analyzer page: what is arriving on the audio input, per channel.
struct InputAnalyzerView: View {
    @State private var analyzer = InputAnalyzer()
    @State private var scopeMode: OscilloscopeView.Mode = .stacked
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(SettingsKey.clockColorPreset) private var presetRaw = ClockColorPreset.white.rawValue
    @AppStorage(SettingsKey.clockCustomColorHex) private var customHex = "#F2F3F5"

    private var isPad: Bool { hSize == .regular }
    private var tcColor: Color {
        let p = ClockColorPreset(rawValue: presetRaw) ?? .white
        return p == .custom ? (Color(hexString: customHex) ?? p.color) : p.color
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: Theme.pad) {
                    header
                    if let p = analyzer.problem, analyzer.info == nil {
                        problemPanel(p)
                    }
                    let wide = geo.size.width > 700
                    let cards = analyzer.isMono ? [SourceChannel.left] : [.left, .right]
                    if wide {
                        HStack(alignment: .top, spacing: Theme.pad) {
                            ForEach(cards, id: \.self) { channelCard($0) }
                        }
                    } else {
                        ForEach(cards, id: \.self) { channelCard($0) }
                    }
                    if !analyzer.isMono { comparePanel }
                    scopePanel(height: wide ? 300 : 220)
                }
                .padding(Theme.pad)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .visualsDataSource(analyzer)
        .onAppear { analyzer.start() }
        .onDisappear { analyzer.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: inputIcon)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(analyzer.info?.name ?? "Opening input…")
                    .font(.system(size: isPad ? 18 : 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(formatLine)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button { analyzer.reset() } label: {
                Text("Reset")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 76, minHeight: 40)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Clears hits, clip lamps and the speed measurement")
        }
        .panel(padding: isPad ? 16 : 12)
    }

    private var formatLine: String {
        guard let i = analyzer.info else { return "Waiting for the device audio input" }
        let khz = i.sampleRate / 1000
        let rate = khz == khz.rounded() ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
        return "\(rate) · \(i.channels == 1 ? "Mono" : "\(i.channels) channels") · runs alongside playback"
    }

    private var inputIcon: String {
        let n = (analyzer.info?.name ?? "").lowercased()
        if n.contains("usb") || n.contains("interface") || n.contains("line") { return "cable.connector" }
        if n.contains("headset") || n.contains("headphone") { return "headphones" }
        return "mic"
    }

    private func problemPanel(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IndicatorLamp(color: Theme.stop, isOn: true, size: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(Theme.label).foregroundStyle(Theme.textPrimary)
                if text.contains("Settings") {
                    Button("Open Settings") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    .font(Theme.label)
                }
            }
            Spacer()
        }
        .panel()
    }

    // MARK: Channel

    private func channelCard(_ side: SourceChannel) -> some View {
        InputChannelCard(channel: side == .left ? analyzer.left : analyzer.right,
                         title: side == .left ? (analyzer.isMono ? "Input" : "Left") : "Right",
                         large: isPad, tcColor: tcColor)
    }

    // MARK: Compare

    private var comparePanel: some View {
        HStack(spacing: isPad ? 32 : 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Right vs left").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Text(offsetText)
                    .font(Theme.numeric(isPad ? 20 : 17))
                    .foregroundStyle(analyzer.offsetFrames == 0 ? Theme.go : Theme.textPrimary)
            }
            Divider().frame(height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Correlation").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Text(analyzer.correlation.map { String(format: "%+.2f", $0) } ?? "—")
                    .font(Theme.numeric(isPad ? 20 : 17))
                    .foregroundStyle((analyzer.correlation ?? 0) < -0.5 ? Theme.stop : Theme.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .panel(padding: isPad ? 16 : 14)
    }

    private var offsetText: String {
        guard let f = analyzer.offsetFrames else { return "Needs timecode on both" }
        if f == 0 { return "In sync" }
        return "\(f > 0 ? "+" : "−")\(abs(f)) frame\(abs(f) == 1 ? "" : "s")"
    }

    // MARK: Scope

    private func scopePanel(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Input scope").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("Scope mode", selection: $scopeMode) {
                    Text("Overlay").tag(OscilloscopeView.Mode.overlay)
                    Text("Stacked").tag(OscilloscopeView.Mode.stacked)
                    Text("X/Y").tag(OscilloscopeView.Mode.xy)
                    if analyzer.left.status.state == .locked || analyzer.right.status.state == .locked {
                        Text("Eye").tag(OscilloscopeView.Mode.eye)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            }
            OscilloscopeView(mode: $scopeMode)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        }
        .panel(padding: isPad ? 16 : 12)
    }

}

/// One channel of the input analysis: lamp, lock, timecode, level bar and the measurement grid.
/// Shared by the Input analyzer and the Scope page.
struct InputChannelCard: View {
    var channel: InputAnalyzer.Channel
    var title: String
    var large: Bool = false
    var tcColor: Color = Theme.textPrimary
    private var isPad: Bool { large }

    var body: some View {
        let c = channel
        let st = c.status
        let live = st.state == .locked || st.state == .freewheel
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IndicatorLamp(color: Theme.go, isOn: c.hasSignal, size: 9)
                Text(title)
                    .font(Theme.sectionHeader)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if c.clipped {
                    Text("Clip").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.stop)
                }
                LockStateLabel(state: st.state)
            }

            Text(st.timecode?.description ?? "--:--:--:--")
                .font(Theme.numeric(isPad ? 44 : 36, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(live ? tcColor : Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(st.timecode.map { "Timecode \($0.description)" } ?? "No timecode")

            LevelBar(peakDBFS: c.peakDBFS, rmsDBFS: c.rmsDBFS)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                MeasureRow("Rate", st.rate?.operatorLabel ?? "—")
                MeasureRow("Speed", speedText(c), tint: speedTint(c))
                MeasureRow("LTC level", st.levelDBFS.map { String(format: "%.1f dBFS", $0) } ?? "—")
                MeasureRow("Peak / RMS", "\(Self.db(c.peakDBFS)) / \(Self.db(c.rmsDBFS))")
                MeasureRow("DC offset", c.hasSignal ? String(format: "%+.1f %%", c.dc * 100) : "—",
                           tint: abs(c.dc) > 0.05 ? Theme.standby : nil)
                MeasureRow("Direction", live ? (st.isReverse ? "Reverse" : "Forward") : "—")
                MeasureRow("User bits", live ? userBits(st.userBits) : "—")
                MeasureRow("Hits", "\(st.discontinuities)", tint: st.discontinuities > 0 ? Theme.standby : nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: isPad ? 16 : 14)
    }

    // MARK: Format

    static func db(_ v: Float) -> String { v.isFinite && v > -100 ? String(format: "%.1f", v) : "−∞" }

    private func speedText(_ c: InputAnalyzer.Channel) -> String {
        guard let m = c.measuredFPS else { return c.status.state == .locked ? "Measuring…" : "—" }
        let fps = String(format: "%.3f fps", m)
        guard let ppm = c.speedPPM else { return fps }
        return abs(ppm) < 1000 ? "\(fps)  \(String(format: "%+.0f ppm", ppm))" : fps
    }

    private func speedTint(_ c: InputAnalyzer.Channel) -> Color? {
        guard let p = c.speedPPM else { return nil }
        return abs(p) > 500 ? Theme.standby : nil
    }

    private func userBits(_ ub: UInt32) -> String {
        let hex = String(format: "%08X", ub)
        return stride(from: 0, to: 8, by: 2).map { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[s..<hex.index(s, offsetBy: 2)])
        }.joined(separator: " ")
    }
}

/// Label / value row for the analysis grids.
struct MeasureRow: View {
    var key: String
    var value: String
    var tint: Color?
    init(_ k: String, _ v: String, tint: Color? = nil) { key = k; value = v; self.tint = tint }
    var body: some View {
        GridRow {
            Text(key).font(Theme.label).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.numeric(14)).foregroundStyle(tint ?? Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Lamp + word for a timecode reader's lock state.
struct LockStateLabel: View {
    var state: TCLockState
    var body: some View {
        let (text, color): (String, Color) = switch state {
        case .locked: ("Locked", Theme.go)
        case .freewheel: ("Freewheel", Theme.standby)
        case .acquiring: ("Acquiring", Theme.standby)
        case .noSignal: ("No timecode", Theme.textTertiary)
        }
        return HStack(spacing: 6) {
            IndicatorLamp(color: color, isOn: state != .noSignal, size: 8)
            Text(text).font(Theme.caption.weight(.medium)).foregroundStyle(state == .noSignal ? Theme.textTertiary : Theme.textPrimary)
        }
    }
}

/// Flat horizontal bar: RMS fill, peak-hold tick, −18 and −6 marks.
struct LevelBar: View {
    var peakDBFS: Float
    var rmsDBFS: Float
    var body: some View {
        Canvas { gc, size in
            func x(_ db: Float) -> CGFloat {
                guard db.isFinite else { return 0 }
                return size.width * CGFloat(max(0, min(1, (db + 60) / 60)))
            }
            gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.surfaceSunken))
            let rx = x(rmsDBFS)
            let fill: Color = rmsDBFS > -6 ? Theme.meterHigh : (rmsDBFS > -18 ? Theme.meterMid : Theme.meterLow)
            gc.fill(Path(CGRect(x: 0, y: 0, width: rx, height: size.height)), with: .color(fill.opacity(0.85)))
            for m: Float in [-18, -6] {
                gc.fill(Path(CGRect(x: x(m), y: 0, width: 1, height: size.height)), with: .color(Theme.hairline))
            }
            if peakDBFS.isFinite {
                gc.fill(Path(CGRect(x: max(0, x(peakDBFS) - 1), y: 0, width: 2, height: size.height)),
                        with: .color(Theme.textPrimary))
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityHidden(true)
    }
}
