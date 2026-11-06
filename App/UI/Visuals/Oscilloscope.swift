import SwiftUI
import QuartzCore
import TCKit

// Owned by the VISUALS agent. Implementation behind `OscilloscopeView` (see VisualsAPI.swift).
// Instrument-grade: 10 × 8 graticule with mono labels, digital-phosphor persistence (intensity
// from hit density across the last 12 sweeps, newest sweep crisp on top), edge trigger with
// level handle / slope / source / hold-off, run-stop, LTC bit decode row, eye diagram and a
// per-channel measurement strip.

enum ScopeTrigger: String, CaseIterable, Identifiable {
    case auto, left, right
    var id: String { rawValue }
    var label: String { switch self { case .auto: "Auto"; case .left: "L"; case .right: "R" } }
}

enum ScopeSlope { case rising, falling }

/// Mutable per-view state the renderer updates every frame (kept out of SwiftUI state).
final class ScopeModel {
    var gain: CGFloat = 1
    var phosphor: [(l: Path, r: Path)] = []
    var xyPhosphor: [Path] = []
    var eyePhosphor: [Path] = []
    var historyKey = ""
    var frozen: AnalysisSnapshot?
    var triggered = false
    var correlation: Double = 0
    var analysis: (l: LTCAnalysis, r: LTCAnalysis) = (LTCAnalysis(), LTCAnalysis())
    var strip: [String] = ["", ""]
    var stripAt: Double = 0
    var eyeText = ""
    // Trigger-level mapping from the last frame (for the drag handle).
    var trigMid: CGFloat = 0
    var trigScale: CGFloat = 1
    var levelVisibleUntil: Double = 0

    static let depth = 12

    func push<T>(_ item: T, into ring: inout [T]) {
        ring.append(item)
        if ring.count > Self.depth { ring.removeFirst(ring.count - Self.depth) }
    }

    /// Phosphor intensity for a sweep `age` frames old (0 = newest). Older sweeps are faint so
    /// only repeated hits build brightness.
    static func intensity(age: Int) -> Double {
        age == 0 ? 1 : 0.26 * pow(0.84, Double(age - 1))
    }

    var ltcChannel: SourceChannel? {
        if analysis.r.isLTC { return .right }
        if analysis.l.isLTC { return .left }
        return nil
    }
}

struct OscilloscopeContent: View {
    @Binding var mode: OscilloscopeView.Mode

    @Environment(\.visualsDataSource) private var data
    @State private var model = ScopeModel()
    @State private var timebaseIndex = 3
    @State private var autoGain = true
    @State private var trigger: ScopeTrigger = .auto
    @State private var slope: ScopeSlope = .rising
    @State private var level: Float = 0
    @State private var running = true
    @State private var pinchBase: CGFloat = 1
    @State private var hasLTC = false

    static let timebases: [Double] = [0.1, 0.2, 0.5, 1, 2, 4]   // ms/div
    static let holdOff: Double = 0.0003                          // s of settled signal before a valid edge
    static let traceL = Theme.scopeTrace
    static let traceR = Color(hex: 0x5E9EA8)                     // muted second channel
    static let mono9 = Font.system(size: 9, weight: .regular, design: .monospaced)
    static let mono10 = Font.system(size: 10, weight: .regular, design: .monospaced)

    private var msPerDiv: Double { Self.timebases[timebaseIndex] }

    var body: some View {
        VStack(spacing: 6) {
            controls
            TimelineView(.animation(paused: !running)) { tl in
                Canvas(rendersAsynchronously: false) { gc, size in
                    render(gc, size, now: tl.date.timeIntervalSinceReferenceDate)
                }
            }
            .background(Theme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { autoSet() }
            .gesture(
                MagnifyGesture()
                    .onChanged { v in
                        let r = v.magnification / pinchBase
                        if r > 1.3 { step(-1); pinchBase = v.magnification }
                        else if r < 0.77 { step(1); pinchBase = v.magnification }
                    }
                    .onEnded { _ in pinchBase = 1 }
            )
            .overlay(alignment: .trailing) { levelHandle }
            .accessibilityElement()
            .accessibilityLabel("Oscilloscope")
            .accessibilityValue("\(modeName(mode)), \(timebaseText) per division\(running ? "" : ", stopped")")
            .accessibilityHint("Double-tap to auto-set")
        }
        .onChange(of: hasLTC) { _, has in if !has, mode == .eye { mode = .overlay } }
    }

    // MARK: Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { modePicker; Spacer(minLength: 4); triggerControls; gainButton; timebaseControl; runStop }
            VStack(spacing: 6) {
                HStack(spacing: 8) { modePicker; Spacer(minLength: 4); runStop }
                HStack(spacing: 8) { triggerControls; Spacer(minLength: 4); gainButton; timebaseControl }
            }
        }
        .font(Theme.caption)
    }

    private var modePicker: some View {
        Picker("Display", selection: $mode) {
            ForEach(OscilloscopeView.Mode.allCases.filter { $0 != .eye || hasLTC || mode == .eye }) {
                Text(modeName($0)).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var triggerControls: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Trigger source", selection: $trigger) {
                    ForEach(ScopeTrigger.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Trig")
                    Text(effectiveTriggerLabel).foregroundStyle(Theme.textPrimary)
                }
            }
            .buttonStyle(VisualsKeyStyle())
            .accessibilityLabel("Trigger source \(effectiveTriggerLabel)")
            Button { slope = slope == .rising ? .falling : .rising } label: {
                SlopeGlyph(rising: slope == .rising).frame(width: 14, height: 12)
            }
            .buttonStyle(VisualsKeyStyle())
            .accessibilityLabel(slope == .rising ? "Rising edge" : "Falling edge")
        }
        .disabled(mode == .xy || mode == .eye)
    }

    private var gainButton: some View {
        Button { autoGain.toggle() } label: {
            HStack(spacing: 5) {
                IndicatorLamp(color: Theme.accent, isOn: autoGain, size: 6)
                Text("Auto gain")
            }
        }
        .buttonStyle(VisualsKeyStyle(isOn: autoGain))
        .accessibilityValue(autoGain ? "On" : "Off")
    }

    private var timebaseControl: some View {
        HStack(spacing: 0) {
            Button { step(1) } label: { Image(systemName: "minus").frame(width: 12) }
                .buttonStyle(VisualsKeyStyle())
                .accessibilityLabel("Slower timebase")
            Text("\(timebaseText)/div")
                .font(Theme.numeric(11))
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 72)
            Button { step(-1) } label: { Image(systemName: "plus").frame(width: 12) }
                .buttonStyle(VisualsKeyStyle())
                .accessibilityLabel("Faster timebase")
        }
        .disabled(mode == .eye)
    }

    private var runStop: some View {
        Button {
            running.toggle()
            if !running { model.frozen = data.snapshot() } else { model.frozen = nil }
        } label: {
            HStack(spacing: 5) {
                IndicatorLamp(color: running ? Theme.go : Theme.stop, isOn: true, size: 6)
                Text(running ? "Run" : "Stop").frame(minWidth: 26, alignment: .leading)
            }
        }
        .buttonStyle(VisualsKeyStyle(isOn: true))
        .accessibilityLabel(running ? "Running" : "Stopped")
        .accessibilityHint(running ? "Freezes the display" : "Resumes the display")
    }

    /// Drag the small arrow on the right edge to set the trigger level.
    private var levelHandle: some View {
        Color.clear
            .frame(width: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard mode == .overlay || mode == .stacked else { return }
                        let l = Float((model.trigMid - v.location.y) / max(1, model.trigScale))
                        level = max(-1, min(1, l))
                        model.levelVisibleUntil = CACurrentMediaTime() + 1.5
                    }
            )
            .accessibilityHidden(true)
    }

    private func modeName(_ m: OscilloscopeView.Mode) -> String {
        switch m { case .overlay: "Overlay"; case .stacked: "Stacked"; case .xy: "X/Y"; case .eye: "Eye" }
    }

    private var timebaseText: String { Self.timeText(ms: msPerDiv) }

    static func timeText(ms: Double) -> String {
        if ms == 0 { return "0" }
        if abs(ms) < 1 { return String(format: "%.0f µs", ms * 1000) }
        return ms == ms.rounded() ? String(format: "%.0f ms", ms) : String(format: "%.1f ms", ms)
    }

    private var triggerChannel: SourceChannel {
        switch trigger {
        case .left: return .left
        case .right: return .right
        case .auto:
            if let ch = model.ltcChannel { return ch }
            if case .decoded(let ch) = data.clock.source { return ch }
            return .left
        }
    }

    private var effectiveTriggerLabel: String {
        let ch = triggerChannel == .left ? "L" : "R"
        return trigger == .auto ? "Auto \u{00B7} \(ch)" : ch
    }

    private func step(_ d: Int) {
        timebaseIndex = max(0, min(Self.timebases.count - 1, timebaseIndex + d))
    }

    /// Double-tap: lock onto LTC if present, otherwise a sensible programme view.
    private func autoSet() {
        running = true
        model.frozen = nil
        autoGain = true
        level = 0
        slope = .rising
        trigger = .auto
        timebaseIndex = model.ltcChannel != nil ? 3 : 4
    }

    // MARK: Frame

    private struct Layout {
        var plot: CGRect
        var decode: CGRect?
        var strip: CGRect
        var correlation: CGRect?
    }

    private func render(_ gc: GraphicsContext, _ size: CGSize, now: Double) {
        let snap = running ? data.snapshot() : (model.frozen ?? data.snapshot())
        if running {
            let hint = data.clock.rate
            model.analysis = (LTCAnalysis.analyze(snap.scopeL, sampleRate: snap.sampleRate, rateHint: hint),
                              LTCAnalysis.analyze(snap.scopeR, sampleRate: snap.sampleRate, rateHint: hint))
            let has = model.ltcChannel != nil
            if has != hasLTC { DispatchQueue.main.async { hasLTC = has } }
            if now - model.stripAt > 0.25 { updateStrip(snap); model.stripAt = now }
        }

        let ltc = model.ltcChannel
        let showDecode = ltc != nil && (mode == .overlay || mode == .stacked) && size.height > 150
        let stripH: CGFloat = size.height > 130 ? 30 : 0
        let decodeH: CGFloat = showDecode ? 18 : 0
        let corrH: CGFloat = mode == .xy ? 18 : 0
        let plot = CGRect(x: 10, y: 10, width: size.width - 28,
                          height: size.height - 16 - stripH - decodeH - corrH)
        guard plot.width > 40, plot.height > 40 else { return }
        let layout = Layout(
            plot: plot,
            decode: showDecode ? CGRect(x: plot.minX, y: plot.maxY + 3, width: plot.width, height: 14) : nil,
            strip: CGRect(x: plot.minX, y: size.height - stripH - 2, width: plot.width + 10, height: stripH),
            correlation: mode == .xy ? CGRect(x: plot.minX, y: plot.maxY + 4, width: plot.width, height: 12) : nil)

        let key = "\(mode)|\(Int(size.width))x\(Int(size.height))|\(timebaseIndex)"
        if key != model.historyKey {
            model.historyKey = key
            model.phosphor.removeAll(); model.xyPhosphor.removeAll(); model.eyePhosphor.removeAll()
        }

        switch mode {
        case .overlay, .stacked: drawTime(gc, layout, snap, now: now)
        case .xy: drawXY(gc, layout, snap)
        case .eye: drawEye(gc, layout, snap)
        }
        if stripH > 0 { drawStrip(gc, layout.strip) }
        if !running {
            gc.draw(Text("Stopped").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.stop),
                    at: CGPoint(x: plot.maxX - 4, y: plot.minY + 9), anchor: .trailing)
        }
    }

    // MARK: Time domain

    private func drawTime(_ gc: GraphicsContext, _ lay: Layout, _ snap: AnalysisSnapshot, now: Double) {
        let plot = lay.plot
        let stacked = mode == .stacked
        drawGraticule(gc, plot, lanes: stacked ? 2 : 1)
        let l = snap.scopeL, r = snap.scopeR
        let n = min(l.count, r.count)
        guard n > 16 else { return }
        let window = min(n - 1, max(8, Int(msPerDiv / 1000 * snap.sampleRate * 10)))
        let pre = window / 10
        let trigCh = triggerChannel
        let trig = trigCh == .left ? l : r

        // Gain: full scale = lane half-height; auto-gain fits the visible peak to ~80 %.
        let half = stacked ? plot.height / 4 : plot.height / 2
        let midL = stacked ? plot.minY + half : plot.midY
        let midR = stacked ? plot.minY + 3 * half : plot.midY

        let start = findTrigger(trig, window: window, pre: pre, sampleRate: snap.sampleRate)
        if running { model.triggered = start != nil }
        let s0 = start.map { $0 - pre } ?? (n - window)

        if running {
            var peak: Float = 0.001
            for i in s0..<(s0 + window) { peak = max(peak, abs(l[i]), abs(r[i])) }
            let target: CGFloat = autoGain ? min(40, 0.8 / CGFloat(peak)) : 1
            model.gain += (target - model.gain) * (abs(target - model.gain) > model.gain ? 1 : 0.15)
            let pl = trace(l, s0, window, plot.minX, plot.width, midL, half)
            let pr = trace(r, s0, window, plot.minX, plot.width, midR, half)
            model.push((pl, pr), into: &model.phosphor)
        }

        // Digital phosphor: older sweeps faint, overlaps build intensity; newest sweep crisp.
        gc.drawLayer { layer in
            layer.clip(to: Path(plot.insetBy(dx: -1, dy: -1)))
            let count = model.phosphor.count
            for (idx, sweep) in model.phosphor.enumerated() {
                let a = ScopeModel.intensity(age: count - 1 - idx)
                layer.stroke(sweep.r, with: .color(Self.traceR.opacity(a)), lineWidth: 1)
                layer.stroke(sweep.l, with: .color(Self.traceL.opacity(a)), lineWidth: 1)
            }
        }

        laneLabel(gc, "L", CGPoint(x: plot.minX + 6, y: plot.minY + 9), Self.traceL)
        laneLabel(gc, "R", stacked ? CGPoint(x: plot.minX + 6, y: plot.midY + 9) : CGPoint(x: plot.minX + 18, y: plot.minY + 9), Self.traceR)

        // Vertical sensitivity, top-centre-right.
        let perDiv = 1 / (model.gain * (stacked ? 2 : 4))
        gc.draw(Text(String(format: "%.3g FS/div", perDiv)).font(Self.mono9).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: plot.maxX - 4, y: plot.minY + (running ? 9 : 22)), anchor: .trailing)

        // Trigger position marker (top) and level handle (right edge).
        let tx = plot.minX + plot.width / 10
        var m = Path()
        m.move(to: CGPoint(x: tx - 4, y: plot.minY - 7)); m.addLine(to: CGPoint(x: tx + 4, y: plot.minY - 7))
        m.addLine(to: CGPoint(x: tx, y: plot.minY - 2)); m.closeSubpath()
        gc.fill(m, with: .color(model.triggered ? Theme.textSecondary : Theme.lockWarn))

        let tmid = trigCh == .left ? midL : midR
        model.trigMid = tmid
        model.trigScale = half * model.gain
        let ty = max(plot.minY, min(plot.maxY, tmid - CGFloat(level) * half * model.gain))
        let tc = trigCh == .left ? Self.traceL : Self.traceR
        var a = Path()
        a.move(to: CGPoint(x: plot.maxX + 9, y: ty - 4.5)); a.addLine(to: CGPoint(x: plot.maxX + 9, y: ty + 4.5))
        a.addLine(to: CGPoint(x: plot.maxX + 2, y: ty)); a.closeSubpath()
        gc.fill(a, with: .color(tc))
        if now < model.levelVisibleUntil {
            var dash = Path()
            dash.move(to: CGPoint(x: plot.minX, y: ty)); dash.addLine(to: CGPoint(x: plot.maxX, y: ty))
            gc.stroke(dash, with: .color(tc.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            gc.draw(Text("Level " + VisualsFormat.db(20 * log10f(max(1e-4, abs(level)))) + " dBFS")
                        .font(Self.mono9).foregroundStyle(tc),
                    at: CGPoint(x: plot.maxX - 4, y: ty - 8), anchor: .trailing)
        }
        if !model.triggered {
            gc.draw(Text("Free run").font(Theme.caption).foregroundStyle(Theme.lockWarn),
                    at: CGPoint(x: plot.minX + 34, y: plot.minY + 9), anchor: .leading)
        }

        // Time labels along the bottom, relative to the trigger point.
        for i in stride(from: 1, through: 9, by: 2) {
            let x = plot.minX + plot.width * CGFloat(i) / 10
            let t = Double(i - 1) * msPerDiv
            gc.draw(Text(Self.timeText(ms: t)).font(Self.mono9).foregroundStyle(Theme.textTertiary),
                    at: CGPoint(x: x + 3, y: plot.maxY - 7), anchor: .leading)
        }

        if let d = lay.decode, let ch = model.ltcChannel {
            drawDecodeRow(gc, d, ch == .left ? model.analysis.l : model.analysis.r, s0: Double(s0), window: Double(window),
                          color: ch == .left ? Self.traceL : Self.traceR)
        }
    }

    /// Thin row under the trace: decoded bit values aligned to their cells, sync word tinted,
    /// and the scope's own decoded timecode at the right.
    private func drawDecodeRow(_ gc: GraphicsContext, _ row: CGRect, _ a: LTCAnalysis, s0: Double, window: Double, color: Color) {
        func x(_ s: Double) -> CGFloat { row.minX + CGFloat((s - s0) / window) * row.width }
        gc.fill(Path(row), with: .color(Theme.background.opacity(0.5)))
        let zero = gc.resolve(Text("0").font(Self.mono9).foregroundStyle(Theme.textSecondary))
        let one = gc.resolve(Text("1").font(Self.mono9).foregroundStyle(Theme.textPrimary))
        var syncSet = Set<Int>()
        for r in a.syncRanges { for i in r { syncSet.insert(i) } }
        var ticks = Path()
        var tint = Path()
        gc.drawLayer { layer in
            layer.clip(to: Path(row))
            for (i, b) in a.bits.enumerated() {
                let x0 = x(b.start), x1 = x(b.end)
                guard x1 > row.minX, x0 < row.maxX else { continue }
                if syncSet.contains(i) { tint.addRect(CGRect(x: x0, y: row.minY, width: x1 - x0, height: row.height)) }
                ticks.move(to: CGPoint(x: x0, y: row.minY)); ticks.addLine(to: CGPoint(x: x0, y: row.minY + 3))
                ticks.move(to: CGPoint(x: x0, y: row.maxY - 3)); ticks.addLine(to: CGPoint(x: x0, y: row.maxY))
                if x1 - x0 >= 7 {
                    layer.draw(b.value == 1 ? one : zero, at: CGPoint(x: (x0 + x1) / 2, y: row.midY))
                } else if b.value == 1 {
                    layer.fill(Path(CGRect(x: x0 + 1, y: row.midY - 1, width: max(1, x1 - x0 - 2), height: 2)),
                               with: .color(Theme.textSecondary))
                }
            }
            layer.fill(tint, with: .color(Theme.accent.opacity(0.18)))
            layer.stroke(ticks, with: .color(Theme.textTertiary), lineWidth: 0.5)
        }
        // Timecode box at the right.
        let tcText = a.timecodeText ?? (a.isReverse ? "Reverse" : "--:--:--:--")
        let label = gc.resolve(Text(tcText).font(Self.mono10).foregroundStyle(a.timecodeText != nil ? color : Theme.textSecondary))
        let ls = label.measure(in: CGSize(width: 200, height: 20))
        let box = CGRect(x: row.maxX - ls.width - 10, y: row.minY, width: ls.width + 10, height: row.height)
        gc.fill(Path(box), with: .color(Theme.surfaceSunken))
        gc.stroke(Path(CGRect(x: box.minX, y: box.minY, width: 0.5, height: box.height)), with: .color(Theme.hairline), lineWidth: 0.5)
        gc.draw(label, at: CGPoint(x: box.midX, y: box.midY))
    }

    private func laneLabel(_ gc: GraphicsContext, _ s: String, _ p: CGPoint, _ c: Color) {
        gc.draw(Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(c), at: p, anchor: .leading)
    }

    /// Latest edge through the trigger level (with hysteresis) in the chosen slope that follows
    /// ≥ hold-off of settled signal and leaves room for a full sweep. For LTC this lands on the
    /// edge after a "0" cell, so the bi-phase train stands still.
    private func findTrigger(_ s: [Float], window: Int, pre: Int, sampleRate: Double) -> Int? {
        let n = s.count
        let maxIdx = n - (window - pre)
        guard maxIdx > pre + 1 else { return nil }
        var amp: Float = 0
        for v in s { amp = max(amp, abs(v)) }
        guard amp > 0.003 else { return nil }
        let hyst = amp * 0.1
        let hold = Int(Self.holdOff * sampleRate)
        let sign: Float = slope == .rising ? 1 : -1
        let lv = level * sign
        var settled = 0
        var found: Int?
        for i in 1..<maxIdx {
            let v = s[i] * sign, p = s[i - 1] * sign
            if v < lv - hyst { settled += 1 }
            if p < lv, v >= lv {
                if settled >= hold, i >= pre { found = i }
                settled = 0
            } else if v > lv + hyst {
                settled = 0
            }
        }
        return found
    }

    /// Polyline of `count` samples from `start`; min/max per column when denser than the pixels.
    private func trace(_ s: [Float], _ start: Int, _ count: Int, _ x0: CGFloat, _ w: CGFloat,
                       _ mid: CGFloat, _ half: CGFloat) -> Path {
        var p = Path()
        let g = model.gain * half
        func y(_ v: Float) -> CGFloat { max(mid - half * 1.05, min(mid + half * 1.05, mid - CGFloat(v) * g)) }
        let columns = Int(w)
        if count <= columns * 2 {
            let dx = w / CGFloat(max(1, count - 1))
            p.move(to: CGPoint(x: x0, y: y(s[start])))
            for i in 1..<count { p.addLine(to: CGPoint(x: x0 + CGFloat(i) * dx, y: y(s[start + i]))) }
        } else {
            for c in 0..<columns {
                let a = start + c * count / columns, b = start + (c + 1) * count / columns
                var lo = s[a], hi = s[a]
                for i in a..<b { lo = min(lo, s[i]); hi = max(hi, s[i]) }
                let x = x0 + CGFloat(c)
                if c == 0 { p.move(to: CGPoint(x: x, y: y(hi))) } else { p.addLine(to: CGPoint(x: x, y: y(hi))) }
                p.addLine(to: CGPoint(x: x, y: y(lo)))
            }
        }
        return p
    }

    private func drawGraticule(_ gc: GraphicsContext, _ r: CGRect, lanes: Int, columns: Int = 10, rows: Int = 8) {
        let hw = max(Theme.hairlineWidth, 0.5)
        var grid = Path()
        for i in 0...columns {
            let x = r.minX + r.width * CGFloat(i) / CGFloat(columns)
            grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY))
        }
        for j in 0...rows {
            let y = r.minY + r.height * CGFloat(j) / CGFloat(rows)
            grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        gc.stroke(grid, with: .color(Theme.scopeGrid), lineWidth: hw)

        // Centre axes with minor ticks (5 per division).
        var cross = Path()
        let centres: [CGFloat] = lanes == 2 ? [r.minY + r.height / 4, r.minY + r.height * 0.75] : [r.midY]
        for cy in centres {
            cross.move(to: CGPoint(x: r.minX, y: cy)); cross.addLine(to: CGPoint(x: r.maxX, y: cy))
            for k in 0...(columns * 5) where k % 5 != 0 {
                let x = r.minX + r.width * CGFloat(k) / CGFloat(columns * 5)
                cross.move(to: CGPoint(x: x, y: cy - 2.5)); cross.addLine(to: CGPoint(x: x, y: cy + 2.5))
            }
        }
        cross.move(to: CGPoint(x: r.midX, y: r.minY)); cross.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        for k in 0...(rows * 5) where k % 5 != 0 {
            let y = r.minY + r.height * CGFloat(k) / CGFloat(rows * 5)
            cross.move(to: CGPoint(x: r.midX - 2.5, y: y)); cross.addLine(to: CGPoint(x: r.midX + 2.5, y: y))
        }
        if lanes == 2 { cross.move(to: CGPoint(x: r.minX, y: r.midY)); cross.addLine(to: CGPoint(x: r.maxX, y: r.midY)) }
        gc.stroke(cross, with: .color(Theme.scopeGrid.mix(with: Theme.textTertiary, by: 0.45)), lineWidth: hw)
    }

    // MARK: Measurements

    private func updateStrip(_ snap: AnalysisSnapshot) {
        for (i, s) in [snap.scopeL, snap.scopeR].enumerated() {
            let m = ChannelMeasurement.measure(s, sampleRate: snap.sampleRate)
            let a = i == 0 ? model.analysis.l : model.analysis.r
            var parts = [i == 0 ? "L" : "R",
                         "Vpp " + VisualsFormat.db(m.vppDBFS) + " dBFS",
                         "RMS " + VisualsFormat.db(m.rmsDBFS)]
            if a.isLTC {
                parts.append(String(format: "%.0f bit/s", snap.sampleRate / a.bitPeriod))
                if let rt = a.riseTime { parts.append(String(format: "Rise %.0f µs", rt * 1e6)) }
            } else if let f = m.frequency, m.vppDBFS > -60 {
                parts.append(f >= 1000 ? String(format: "%.2f kHz", f / 1000) : String(format: "%.0f Hz", f))
            } else {
                parts.append("\u{2014} Hz")
            }
            parts.append(String(format: "DC %@%.1f %%", m.dc < 0 ? VisualsFormat.minus : "+", abs(m.dc) * 100))
            model.strip[i] = parts.joined(separator: "   ")
        }
        if let ch = model.ltcChannel {
            let a = ch == .left ? model.analysis.l : model.analysis.r
            var parts: [String] = []
            if let e = a.eyeHeight { parts.append(String(format: "Eye height %.0f %%", e * 100)) }
            if let j = a.jitterPP { parts.append(String(format: "Jitter %.1f µs p-p", j * 1e6)) }
            parts.append(String(format: "Bit %.1f µs", a.bitPeriod / snap.sampleRate * 1e6))
            model.eyeText = parts.joined(separator: "   ")
        } else {
            model.eyeText = ""
        }
    }

    private func drawStrip(_ gc: GraphicsContext, _ r: CGRect) {
        var top = Path()
        top.move(to: CGPoint(x: 0, y: r.minY - 1)); top.addLine(to: CGPoint(x: r.maxX + 20, y: r.minY - 1))
        gc.stroke(top, with: .color(Theme.hairline), lineWidth: 0.5)
        for i in 0..<2 {
            gc.draw(Text(model.strip[i]).font(Self.mono10).foregroundStyle(i == 0 ? Self.traceL : Self.traceR),
                    at: CGPoint(x: r.minX, y: r.minY + 7 + CGFloat(i) * 13), anchor: .leading)
        }
    }

    // MARK: X/Y (goniometer)

    private func drawXY(_ gc: GraphicsContext, _ lay: Layout, _ snap: AnalysisSnapshot) {
        let plot = lay.plot
        let side = min(plot.width, plot.height)
        let r = CGRect(x: plot.midX - side / 2, y: plot.midY - side / 2, width: side, height: side)
        drawGraticule(gc, r, lanes: 1, columns: 8, rows: 8)
        var axes = Path()
        axes.move(to: CGPoint(x: r.minX, y: r.minY)); axes.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        axes.move(to: CGPoint(x: r.maxX, y: r.minY)); axes.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        gc.stroke(axes, with: .color(Theme.scopeGrid.mix(with: Theme.textTertiary, by: 0.45)), lineWidth: max(Theme.hairlineWidth, 0.5))
        laneLabel(gc, "L", CGPoint(x: r.minX + 4, y: r.minY + 9), Self.traceL)
        gc.draw(Text("R").font(.system(size: 10, weight: .semibold)).foregroundStyle(Self.traceR),
                at: CGPoint(x: r.maxX - 4, y: r.minY + 9), anchor: .trailing)
        gc.draw(Text("M").font(.system(size: 10)).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: r.midX + 5, y: r.minY + 9), anchor: .leading)
        gc.draw(Text("S").font(.system(size: 10)).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: r.maxX - 4, y: r.midY - 8), anchor: .trailing)

        let l = snap.scopeL, rr = snap.scopeR
        let n = min(l.count, rr.count)
        guard n > 0 else { return }
        let window = min(n, max(64, Int(msPerDiv / 1000 * snap.sampleRate * 10)))
        if running {
            var peak: Float = 0.001
            var slr = 0.0, sll = 0.0, srr = 0.0
            for i in (n - window)..<n {
                peak = max(peak, abs(l[i]), abs(rr[i]))
                slr += Double(l[i] * rr[i]); sll += Double(l[i] * l[i]); srr += Double(rr[i] * rr[i])
            }
            let c = sll > 1e-9 && srr > 1e-9 ? slr / (sll * srr).squareRoot() : 0
            model.correlation += (c - model.correlation) * 0.12
            let target: CGFloat = autoGain ? min(40, 0.7 / CGFloat(peak)) : 1
            model.gain += (target - model.gain) * 0.15

            // Rotated 45°: M = L+R up, S = R−L right.
            let half = side / 2
            var dots = Path()
            let stride = max(1, window / 900)
            var i = n - window
            while i < n {
                let lv = CGFloat(l[i]), rv = CGFloat(rr[i])
                let x = r.midX + max(-1, min(1, (rv - lv) * 0.7071 * model.gain)) * half
                let y = r.midY - max(-1, min(1, (lv + rv) * 0.7071 * model.gain)) * half
                dots.addRect(CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
                i += stride
            }
            model.push(dots, into: &model.xyPhosphor)
        }
        let count = model.xyPhosphor.count
        for (idx, p) in model.xyPhosphor.enumerated() {
            gc.fill(p, with: .color(Self.traceL.opacity(ScopeModel.intensity(age: count - 1 - idx) * 0.9)))
        }

        if let cr = lay.correlation { drawCorrelation(gc, CGRect(x: r.minX, y: cr.minY, width: r.width, height: cr.height)) }
    }

    /// −1…+1 phase correlation bar.
    private func drawCorrelation(_ gc: GraphicsContext, _ r: CGRect) {
        let bar = CGRect(x: r.minX + 18, y: r.midY - 2.5, width: r.width - 36, height: 5)
        gc.fill(Path(bar), with: .color(Theme.background))
        gc.stroke(Path(bar), with: .color(Theme.hairline), lineWidth: 0.5)
        var ticks = Path()
        for f in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let x = bar.minX + bar.width * f
            ticks.move(to: CGPoint(x: x, y: bar.minY - 2)); ticks.addLine(to: CGPoint(x: x, y: bar.maxY + 2))
        }
        gc.stroke(ticks, with: .color(Theme.textTertiary), lineWidth: 0.5)
        gc.draw(Text(VisualsFormat.minus + "1").font(Self.mono9).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: r.minX, y: r.midY), anchor: .leading)
        gc.draw(Text("+1").font(Self.mono9).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: r.maxX, y: r.midY), anchor: .trailing)
        let c = max(-1, min(1, model.correlation))
        let x = bar.midX + CGFloat(c) * bar.width / 2
        let mc = c < 0 ? Theme.lockWarn : Theme.textPrimary
        gc.fill(Path(CGRect(x: min(x, bar.midX), y: bar.minY + 1, width: abs(x - bar.midX), height: bar.height - 2)),
                with: .color(mc.opacity(0.35)))
        gc.fill(Path(CGRect(x: x - 1, y: bar.minY - 3, width: 2, height: bar.height + 6)), with: .color(mc))
    }

    // MARK: Eye diagram

    private func drawEye(_ gc: GraphicsContext, _ lay: Layout, _ snap: AnalysisSnapshot) {
        let plot = lay.plot
        drawGraticule(gc, plot, lanes: 1)
        guard let ch = model.ltcChannel else {
            gc.draw(Text("No timecode on either channel").font(Theme.label).foregroundStyle(Theme.textSecondary),
                    at: CGPoint(x: plot.midX, y: plot.midY - 14))
            return
        }
        let a = ch == .left ? model.analysis.l : model.analysis.r
        let s = ch == .left ? snap.scopeL : snap.scopeR
        let color = ch == .left ? Self.traceL : Self.traceR
        let t = a.bitPeriod
        // One cell plus a quarter either side: −0.25 T … 1.25 T across 10 divisions.
        func x(_ u: Double) -> CGFloat { plot.minX + CGFloat((u + 0.25) / 1.5) * plot.width }
        let half = plot.height / 2
        let g = CGFloat(0.8 / max(0.01, Double(a.amplitude)))
        func y(_ v: Float) -> CGFloat { plot.midY - CGFloat(v - a.mid) * g * half }

        // Ideal transition instants.
        var ideal = Path()
        for u in [0.0, 0.5, 1.0] {
            ideal.move(to: CGPoint(x: x(u), y: plot.minY)); ideal.addLine(to: CGPoint(x: x(u), y: plot.maxY))
        }
        gc.stroke(ideal, with: .color(Theme.textTertiary.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

        if running, t > 2 {
            var p = Path()
            for b in a.bits {
                let from = Int((b.start - 0.25 * t).rounded(.down)), to = Int((b.start + 1.25 * t).rounded(.up))
                guard from >= 0, to < s.count else { continue }
                for i in from...to {
                    let pt = CGPoint(x: x((Double(i) - b.start) / t), y: y(s[i]))
                    if i == from { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            model.push(p, into: &model.eyePhosphor)
        }
        gc.drawLayer { layer in
            layer.clip(to: Path(plot))
            let count = model.eyePhosphor.count
            for (idx, p) in model.eyePhosphor.enumerated() {
                let age = count - 1 - idx
                layer.stroke(p, with: .color(color.opacity(age == 0 ? 0.55 : ScopeModel.intensity(age: age) * 0.7)), lineWidth: 1)
            }
        }
        for (u, label) in [(0.0, "0"), (0.5, "\u{00BD} bit"), (1.0, "1 bit")] {
            gc.draw(Text(label).font(Self.mono9).foregroundStyle(Theme.textTertiary),
                    at: CGPoint(x: x(u) + 3, y: plot.maxY - 7), anchor: .leading)
        }
        gc.draw(Text(model.eyeText).font(Self.mono10).foregroundStyle(color),
                at: CGPoint(x: plot.minX + 6, y: plot.minY + 9), anchor: .leading)
        gc.draw(Text(ch == .left ? "LTC \u{00B7} Left" : "LTC \u{00B7} Right").font(Theme.caption).foregroundStyle(Theme.textSecondary),
                at: CGPoint(x: plot.maxX - 4, y: plot.minY + (running ? 9 : 22)), anchor: .trailing)
    }
}

/// Edge glyph for the slope key: a step with a tick, rising or falling.
struct SlopeGlyph: View {
    var rising: Bool
    var body: some View {
        Canvas { gc, size in
            var p = Path()
            let w = size.width, h = size.height
            let lo = rising ? h - 1 : 1, hi = rising ? 1 : h - 1
            p.move(to: CGPoint(x: 0, y: lo)); p.addLine(to: CGPoint(x: w * 0.4, y: lo))
            p.addLine(to: CGPoint(x: w * 0.6, y: hi)); p.addLine(to: CGPoint(x: w, y: hi))
            gc.stroke(p, with: .color(Theme.textPrimary), lineWidth: 1.2)
        }
    }
}
