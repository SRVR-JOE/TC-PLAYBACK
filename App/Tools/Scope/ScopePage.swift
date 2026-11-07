import SwiftUI
import TCKit

/// Wraps a visuals source so the page's Hold freezes the scope, meters and readouts together.
final class HeldSource: VisualsDataSource {
    let base: any VisualsDataSource
    var held = false { didSet { frozen = held ? base.snapshot() : nil } }
    private var frozen: AnalysisSnapshot?
    init(_ base: any VisualsDataSource) { self.base = base }
    var clock: ClockStatus { base.clock }
    var currentTime: TimeInterval { base.currentTime }
    var duration: TimeInterval { base.duration }
    var routing: ChannelRouting { base.routing }
    var sourceChannelCount: Int { base.sourceChannelCount }
    func snapshot() -> AnalysisSnapshot { frozen ?? base.snapshot() }
    func resetClip() { base.resetClip() }
    func seek(to time: TimeInterval) {}
}

/// Owns both analysers for the page's lifetime.
final class ScopePageModel {
    let input = InputAnalyzer()
    let output = ScopeAnalyzer()
    lazy var inputSource = HeldSource(input)
    lazy var outputSource = HeldSource(output)
    let spectrum = SpectrumEngine()
    #if DEBUG
    lazy var demoFeed = SpectrumDemoFeed()
    #endif

    init() {
        if isDemo { spectrum.settings.sources = .both }
    }

    var isDemo: Bool {
        #if DEBUG
        return SpectrumDemoFeed.isOn
        #else
        return false
        #endif
    }

    /// Where the spectrum analyser reads: the Scope's own host-timed input and output history.
    var spectrumFeed: SpectrumFeed {
        #if DEBUG
        if SpectrumDemoFeed.isOn { return demoFeed }
        #endif
        return output.core
    }
}

/// Everything the readouts show, captured as values so Hold can freeze it.
struct ScopeReadout {
    var inL = InputAnalyzer.Channel(), inR = InputAnalyzer.Channel()
    var inClock = ClockStatus()
    var inMono = false
    var outL = InputAnalyzer.Channel(), outR = InputAnalyzer.Channel()
    var outClock = ClockStatus()
    var engineClock = ClockStatus()
    var playing = false
    var engineSource: EngineSource = .none
    var latency: ScopeAnalyzer.Latency?
    var rateMismatch = false
    var session = ScopeAnalyzer.Session()

    var inHasSignal: Bool { inL.hasSignal || inR.hasSignal }

    /// Output timecode: what we read back from the post-mix audio, else the engine's own clock.
    var outTC: Timecode? {
        if outClock.lock == .locked || outClock.lock == .freewheel, let t = outClock.timecode { return t }
        if playing, engineClock.source != .trackTime, engineClock.source != .externalInput { return engineClock.timecode }
        return nil
    }
    var outRate: FrameRate? { outTC?.rate ?? (playing ? engineClock.rate : nil) }
    var inTC: Timecode? { inClock.lock == .locked || inClock.lock == .freewheel ? inClock.timecode : nil }
    var inRate: FrameRate? { inTC?.rate }

    var compare: ScopeCompare.Inputs {
        ScopeCompare.Inputs(outputPlaying: playing, outputTC: outTC, outputRate: outRate,
                            inputHasSignal: inHasSignal, inputTC: inTC, inputRate: inRate,
                            latencyMS: latency?.ms, inverted: latency?.inverted ?? false)
    }

    var framesLate: Int? {
        guard let o = outTC, let i = inTC else { return nil }
        return ScopeCompare.framesLate(output: o, input: i)
    }

    /// Input speed minus output speed, ppm (both measured from the LTC bit stream).
    var ppmDifference: Double? {
        func live(_ c: InputAnalyzer.Channel) -> Double? {
            c.status.state == .locked || c.status.state == .freewheel ? c.speedPPM : nil
        }
        guard let i = live(inR) ?? live(inL), let o = live(outR) ?? live(outL) else { return nil }
        return i - o
    }
}

/// Scope page: the device audio input and the app's output side by side (iPad) or switchable
/// (iPhone), each with a scope, meters and analysis, plus an output-vs-input comparison.
/// Opening it never starts playback; input capture runs only while it is on screen.
struct ScopePage: View {
    enum Pane: String, CaseIterable, Identifiable { case input, output, both; var id: String { rawValue } }
    enum ScopeStyle: String, CaseIterable, Identifiable { case separate, overlay; var id: String { rawValue } }
    enum Tab: String, CaseIterable, Identifiable { case scopes, spectrum; var id: String { rawValue } }

    @State private var model = ScopePageModel()
    @State private var hold = false
    @State private var held: ScopeReadout?
    @State private var timebase = 3
    @State private var inMode: OscilloscopeView.Mode = .stacked
    @State private var outMode: OscilloscopeView.Mode = .stacked
    @State private var pane: Pane = .both
    @State private var style: ScopeStyle = .separate
    @State private var alignOverlay = true
    @State private var tab: Tab = Self.launchTab
    @State private var spectrumKind: SpectrumPanel.Kind = Self.launchSpectrumKind
    @State private var visible = false
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(SettingsKey.clockColorPreset) private var presetRaw = ClockColorPreset.white.rawValue
    @AppStorage(SettingsKey.clockCustomColorHex) private var customHex = "#F2F3F5"

    private var engine: PlaybackEngine { PlaybackEngine.shared }
    private var input: InputAnalyzer { model.input }
    private var output: ScopeAnalyzer { model.output }
    private var tcColor: Color {
        let p = ClockColorPreset(rawValue: presetRaw) ?? .white
        return p == .custom ? (Color(hexString: customHex) ?? p.color) : p.color
    }

    private var live: ScopeReadout {
        var r = ScopeReadout()
        r.inL = input.left; r.inR = input.right; r.inClock = input.clock; r.inMono = input.isMono
        r.outL = output.left; r.outR = output.right; r.outClock = output.clock
        r.engineClock = engine.clock; r.playing = engine.transport == .playing; r.engineSource = engine.source
        r.latency = output.latency; r.rateMismatch = output.rateMismatch; r.session = output.session
        return r
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 760
            let r = held ?? live
            ScrollView {
                VStack(spacing: Theme.pad) {
                    header(r, wide: wide)
                    if let p = input.problem, input.info == nil { problemPanel(p) }
                    comparePanel(r, wide: wide)
                    if tab == .spectrum {
                        SpectrumPanel(engine: model.spectrum, offersOutput: true, wide: wide,
                                      plotHeight: wide ? min(760, max(380, geo.size.height - 360)) : 320,
                                      kind: $spectrumKind)
                            .panel(padding: wide ? 14 : 10)
                    } else if style == .overlay { overlayPanel(height: wide ? 320 : 240) }
                    if tab == .spectrum {
                        EmptyView()
                    } else if wide {
                        HStack(alignment: .top, spacing: Theme.pad) {
                            inputColumn(r, wide: true)
                            outputColumn(r, wide: true)
                        }
                    } else {
                        Picker("Show", selection: $pane) {
                            Text("Input").tag(Pane.input)
                            Text("Output").tag(Pane.output)
                            Text("Both").tag(Pane.both)
                        }
                        .pickerStyle(.segmented)
                        if pane != .output { inputColumn(r, wide: false) }
                        if pane != .input { outputColumn(r, wide: false) }
                    }
                }
                .padding(Theme.pad)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            input.start()
            output.start()
            visible = true
            updateSpectrum()
        }
        .onDisappear {
            visible = false
            updateSpectrum()
            output.stop()
            input.stop()
            setHold(false)
        }
        .onChange(of: hold) { _, h in setHold(h) }
        .onChange(of: tab) { _, _ in updateSpectrum() }
        .onChange(of: input.isMono, initial: true) { _, m in model.spectrum.settings.inputMono = m && !model.isDemo }
    }

    /// The analyser runs only while its tab is on screen.
    private func updateSpectrum() {
        if visible && tab == .spectrum { model.spectrum.start(feed: model.spectrumFeed) } else { model.spectrum.stop() }
    }

    private static var launchTab: Tab {
        let a = ProcessInfo.processInfo.arguments
        return a.contains("-spectrum") || a.contains("-spectrumDemo") || a.contains("-spectrumView") ? .spectrum : .scopes
    }

    private static var launchSpectrumKind: SpectrumPanel.Kind {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-spectrumView"), i + 1 < a.count, let k = SpectrumPanel.Kind(rawValue: a[i + 1]) { return k }
        return .spectrum
    }

    private func setHold(_ h: Bool) {
        if hold != h { hold = h }
        model.inputSource.held = h
        model.outputSource.held = h
        model.spectrum.held = h
        held = h ? live : nil
    }

    // MARK: Header

    private func header(_ r: ScopeReadout, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if wide {
                HStack(alignment: .center, spacing: 16) {
                    deviceLabel("Input", input.info?.name ?? "Opening input…", icon: "mic")
                    deviceLabel("Output", r.session.routeName, icon: "speaker.wave.2")
                    Spacer(minLength: 8)
                    tabControls
                    if tab == .scopes { styleControls }
                    holdButton
                    resetButton
                }
            } else {
                deviceLabel("Input", input.info?.name ?? "Opening input…", icon: "mic")
                deviceLabel("Output", r.session.routeName, icon: "speaker.wave.2")
                HStack(spacing: 10) {
                    tabControls
                    Spacer(minLength: 4)
                    holdButton
                    resetButton
                }
                if tab == .scopes { styleControls }
            }
        }
        .panel(padding: wide ? 14 : 12)
    }

    private func deviceLabel(_ title: String, _ name: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Text(name).font(Theme.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
        }
    }

    private var tabControls: some View {
        Picker("Page", selection: $tab) {
            Text("Scopes").tag(Tab.scopes)
            Text("Spectrum").tag(Tab.spectrum)
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var styleControls: some View {
        Picker("Scopes", selection: $style) {
            Text("Separate").tag(ScopeStyle.separate)
            Text("Overlay").tag(ScopeStyle.overlay)
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var holdButton: some View {
        Button { hold.toggle() } label: {
            HStack(spacing: 7) {
                IndicatorLamp(color: Theme.stop, isOn: hold, size: 8)
                Text(hold ? "Held" : "Hold")
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .frame(minWidth: 76, minHeight: 40)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hold ? "Held" : "Hold")
        .accessibilityHint("Freezes the scopes, meters and readings")
    }

    private var resetButton: some View {
        Button {
            input.reset(); input.resetClip()
            output.reset(); output.resetClip()
            engine.resetClip()
            model.spectrum.reset()
        } label: {
            Text("Reset")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 76, minHeight: 40)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset hits and peaks")
        .accessibilityHint("Clears hits, peaks, clip lamps, the speed and latency measurements, and restarts the spectrum average")
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

    // MARK: Compare

    private func comparePanel(_ r: ScopeReadout, wide: Bool) -> some View {
        let line = ScopeCompare.statusLine(r.compare)
        let good = line.hasPrefix("Input matches output")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                IndicatorLamp(color: good ? Theme.go : Theme.standby,
                              isOn: good || line.contains("does not match"), size: 9)
                Text(line)
                    .font(.system(size: wide ? 18 : 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            let cells = [
                ("Timecode difference", tcDiffText(r)),
                ("Round trip", latencyText(r)),
                ("Speed difference", r.ppmDifference.map { String(format: "%+.0f ppm", $0) } ?? "—"),
                ("Frame rate", rateText(r)),
            ]
            if wide {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(cells.indices, id: \.self) { i in
                        compareCell(cells[i].0, cells[i].1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    ForEach(cells.indices, id: \.self) { i in MeasureRow(cells[i].0, cells[i].1) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: wide ? 16 : 14)
    }

    private func compareCell(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k).font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
            Text(v).font(Theme.numeric(17)).foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func tcDiffText(_ r: ScopeReadout) -> String {
        guard let late = r.framesLate else { return "—" }
        if late == 0 { return "0 frames" }
        return "\(abs(late)) frame\(abs(late) == 1 ? "" : "s") \(late > 0 ? "late" : "early")"
    }

    private func latencyText(_ r: ScopeReadout) -> String {
        if r.rateMismatch { return "Sample rates differ" }
        guard let l = r.latency else { return r.playing ? "No match on the input" : "—" }
        return ScopeCompare.formatMS(l.ms) + (l.inverted ? ", inverted" : "")
    }

    private func rateText(_ r: ScopeReadout) -> String {
        switch (r.inRate, r.outRate) {
        case let (i?, o?): return i == o ? "Match, \(o.operatorLabel)" : "\(i.operatorLabel) in, \(o.operatorLabel) out"
        case let (nil, o?): return "Output \(o.operatorLabel)"
        case let (i?, nil): return "Input \(i.operatorLabel)"
        default: return "—"
        }
    }

    // MARK: Columns

    private func inputColumn(_ r: ScopeReadout, wide: Bool) -> some View {
        VStack(spacing: Theme.pad) {
            columnTitle("Input", detail: inputFormat)
            if style == .separate {
                scopePanel(mode: $inMode, source: model.inputSource, height: wide ? 280 : 220)
            }
            meterPanel(model.inputSource)
            InputChannelCard(channel: r.inL, title: r.inMono ? "Input" : "Left", large: wide, tcColor: tcColor)
            if !r.inMono {
                InputChannelCard(channel: r.inR, title: "Right", large: wide, tcColor: tcColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var inputFormat: String {
        guard let i = input.info else { return "Waiting for the device audio input" }
        return "\(khz(i.sampleRate)) · \(i.channels == 1 ? "Mono" : "\(i.channels) channels")"
    }

    private func outputColumn(_ r: ScopeReadout, wide: Bool) -> some View {
        VStack(spacing: Theme.pad) {
            columnTitle("Output", detail: output.hasTap ? "As sent to \(r.session.routeName), after routing and gain" : "Nothing playing")
            if style == .separate {
                scopePanel(mode: $outMode, source: model.outputSource, height: wide ? 280 : 220)
            }
            meterPanel(model.outputSource)
            OutputAnalysisCard(readout: r, large: wide, tcColor: tcColor)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func columnTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func scopePanel(mode: Binding<OscilloscopeView.Mode>, source: HeldSource, height: CGFloat) -> some View {
        OscilloscopeView(mode: mode, timebase: $timebase, hold: $hold)
            .frame(height: height)
            .visualsDataSource(source)
            .panel(padding: 10)
    }

    private func meterPanel(_ source: HeldSource) -> some View {
        StereoMeterView(axis: .horizontal)
            .frame(height: 46)
            .visualsDataSource(source)
            .panel(padding: 10)
    }

    private func overlayPanel(height: CGFloat) -> some View {
        ScopeOverlayView(analyzer: output, timebase: $timebase, hold: $hold, align: $alignOverlay)
            .frame(height: height)
            .panel(padding: 10)
    }

    private func khz(_ sr: Double) -> String {
        let k = sr / 1000
        return k == k.rounded() ? String(format: "%.0f kHz", k) : String(format: "%.1f kHz", k)
    }
}

// MARK: - Output card

/// What the app is sending: timecode, rate, LTC channel, level per channel, clip, route,
/// sample rate and buffer / latency.
struct OutputAnalysisCard: View {
    var readout: ScopeReadout
    var large: Bool
    var tcColor: Color

    var body: some View {
        let r = readout
        let tc = r.outTC
        let ltcL = isLive(r.outL), ltcR = isLive(r.outR)
        let lockState: TCLockState = ltcR ? r.outR.status.state : (ltcL ? r.outL.status.state : .noSignal)
        let clipped = r.outL.clipped || r.outR.clipped
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IndicatorLamp(color: Theme.go, isOn: r.outL.hasSignal || r.outR.hasSignal, size: 9)
                Text("Output").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Spacer()
                if clipped { Text("Clip").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.stop) }
                LockStateLabel(state: lockState)
            }
            Text(tc?.description ?? "--:--:--:--")
                .font(Theme.numeric(large ? 44 : 36, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(tc != nil ? tcColor : Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(tc.map { "Output timecode \($0.description)" } ?? "No output timecode")
            VStack(spacing: 5) {
                levelRow("L", r.outL)
                levelRow("R", r.outR)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                MeasureRow("Playing", sourceText)
                MeasureRow("Rate", r.outRate?.operatorLabel ?? "—")
                MeasureRow("LTC on", ltcL && ltcR ? "Both" : (ltcR ? "Right" : (ltcL ? "Left" : "Neither channel")))
                MeasureRow("Speed", speedText)
                MeasureRow("Left peak / RMS", "\(InputChannelCard.db(r.outL.peakDBFS)) / \(InputChannelCard.db(r.outL.rmsDBFS))")
                MeasureRow("Right peak / RMS", "\(InputChannelCard.db(r.outR.peakDBFS)) / \(InputChannelCard.db(r.outR.rmsDBFS))")
                MeasureRow("Clip", clipText, tint: clipped ? Theme.stop : nil)
                MeasureRow("Route", r.session.routeName)
                MeasureRow("Sample rate", r.session.sampleRate > 0 ? String(format: "%.0f Hz", r.session.sampleRate) : "—")
                MeasureRow("Buffer", ms(r.session.ioBuffer))
                MeasureRow("Output latency", r.session.sampleRate > 0 ? "\(ms(r.session.outputLatency + r.session.ioBuffer)) (device \(ms(r.session.outputLatency)) + buffer)" : "—")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: large ? 16 : 14)
    }

    private func levelRow(_ k: String, _ c: InputAnalyzer.Channel) -> some View {
        HStack(spacing: 8) {
            Text(k).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary).frame(width: 12)
            LevelBar(peakDBFS: c.peakDBFS, rmsDBFS: c.rmsDBFS)
        }
    }

    private var sourceText: String {
        guard readout.playing else { return "Nothing playing" }
        switch readout.engineSource {
        case .none: return "Nothing playing"
        case .generator(let g): return "LTC generator, \(g.side == .both ? "both sides" : g.side.rawValue.capitalized)"
        case .file(let u): return u.deletingPathExtension().lastPathComponent
        }
    }

    private var speedText: String {
        let c = isLive(readout.outR) ? readout.outR : readout.outL
        guard let m = c.measuredFPS else { return isLive(c) ? "Measuring…" : "—" }
        let fps = String(format: "%.3f fps", m)
        guard let p = c.speedPPM, abs(p) < 1000 else { return fps }
        return "\(fps)  \(String(format: "%+.0f ppm", p))"
    }

    private var clipText: String {
        switch (readout.outL.clipped, readout.outR.clipped) {
        case (true, true): "Both channels"
        case (true, false): "Left"
        case (false, true): "Right"
        default: "None"
        }
    }

    private func ms(_ t: TimeInterval) -> String { String(format: "%.1f ms", t * 1000) }
    private func isLive(_ c: InputAnalyzer.Channel) -> Bool { c.status.state == .locked || c.status.state == .freewheel }
}
