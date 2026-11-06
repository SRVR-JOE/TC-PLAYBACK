import SwiftUI

// Owned by the VISUALS agent. Implementation behind `OscilloscopeView` (see VisualsAPI.swift).
// Tektronix-style: 10 × 8 graticule, rising-edge trigger with hold-off, timebase in ms/div.

final class ScopeModel {
    var gain: CGFloat = 1
    /// Recent X/Y point sets (normalised −1…1), oldest first, for persistence.
    var xyHistory: [[CGPoint]] = []
    var triggered = false
}

enum ScopeTrigger: String, CaseIterable, Identifiable {
    case auto, left, right
    var id: String { rawValue }
    var label: String { switch self { case .auto: "Auto"; case .left: "L"; case .right: "R" } }
}

struct OscilloscopeContent: View {
    @Binding var mode: OscilloscopeView.Mode

    @Environment(\.visualsDataSource) private var data
    @State private var model = ScopeModel()
    @State private var timebaseIndex = 3
    @State private var autoGain = true
    @State private var trigger: ScopeTrigger = .auto
    @State private var pinchBase: CGFloat = 1

    static let timebases: [Double] = [0.1, 0.2, 0.5, 1, 2, 4]   // ms/div
    static let holdOff: Double = 0.0003                          // s of sustained low before a valid edge
    static let traceL = Theme.scopeTrace
    static let traceR = Color(hex: 0x5E9EA8)                     // muted second channel

    private var msPerDiv: Double { Self.timebases[timebaseIndex] }

    var body: some View {
        VStack(spacing: 6) {
            controls
            TimelineView(.animation) { _ in
                Canvas(rendersAsynchronously: false) { gc, size in
                    draw(gc, size, data.snapshot())
                }
            }
            .background(Theme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { v in
                        let r = v.magnification / pinchBase
                        if r > 1.3 { step(-1); pinchBase = v.magnification }
                        else if r < 0.77 { step(1); pinchBase = v.magnification }
                    }
                    .onEnded { _ in pinchBase = 1 }
            )
            .accessibilityElement()
            .accessibilityLabel("Oscilloscope")
            .accessibilityValue("\(modeName(mode)), \(timebaseText) per division")
        }
    }

    // MARK: Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(full: true)
            controlRow(full: false)
        }
    }

    private func controlRow(full: Bool) -> some View {
        HStack(spacing: 8) {
            Picker("Display", selection: $mode) {
                ForEach(OscilloscopeView.Mode.allCases) { Text(modeName($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer(minLength: 4)
            if full {
                Menu {
                    Picker("Trigger", selection: $trigger) {
                        ForEach(ScopeTrigger.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Trigger")
                        Text(effectiveTriggerLabel).foregroundStyle(Theme.textPrimary)
                    }
                }
                .buttonStyle(VisualsKeyStyle())
                .disabled(mode == .xy)
            }
            Button { autoGain.toggle() } label: {
                HStack(spacing: 5) {
                    IndicatorLamp(color: Theme.accent, isOn: autoGain, size: 6)
                    Text(full ? "Auto gain" : "Auto")
                }
            }
            .buttonStyle(VisualsKeyStyle(isOn: autoGain))
            .accessibilityValue(autoGain ? "On" : "Off")
            HStack(spacing: 0) {
                Button { step(1) } label: { Image(systemName: "minus").frame(width: 14) }
                    .buttonStyle(VisualsKeyStyle())
                    .accessibilityLabel("Slower timebase")
                Text("\(timebaseText)/div")
                    .font(Theme.numeric(11))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 70)
                Button { step(-1) } label: { Image(systemName: "plus").frame(width: 14) }
                    .buttonStyle(VisualsKeyStyle())
                    .accessibilityLabel("Faster timebase")
            }
        }
        .font(Theme.caption)
    }

    private func modeName(_ m: OscilloscopeView.Mode) -> String {
        switch m { case .overlay: "Overlay"; case .stacked: "Stacked"; case .xy: "X/Y" }
    }

    private var timebaseText: String {
        msPerDiv < 1 ? String(format: "%.0f µs", msPerDiv * 1000) : String(format: "%.0f ms", msPerDiv)
    }

    private var triggerChannel: SourceChannel {
        switch trigger {
        case .left: return .left
        case .right: return .right
        case .auto:
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

    // MARK: Drawing

    private func draw(_ gc: GraphicsContext, _ size: CGSize, _ snap: AnalysisSnapshot) {
        let plot = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        guard plot.width > 20, plot.height > 20 else { return }
        if mode == .xy { drawXY(gc, plot, snap); return }

        drawGraticule(gc, plot, lanes: mode == .stacked ? 2 : 1)
        let l = snap.scopeL, r = snap.scopeR
        let n = min(l.count, r.count)
        guard n > 16 else { return }
        let window = min(n - 1, max(8, Int(msPerDiv / 1000 * snap.sampleRate * 10)))
        let pre = window / 10
        let trig = triggerChannel == .left ? l : r
        let start = findTrigger(trig, window: window, pre: pre, sampleRate: snap.sampleRate)
        model.triggered = start != nil
        let s0 = start.map { $0 - pre } ?? (n - window)

        // Gain: full scale = lane half-height; auto-gain fits the visible peak to ~80 %.
        var peak: Float = 0.001
        for i in s0..<(s0 + window) { peak = max(peak, abs(l[i]), abs(r[i])) }
        let target: CGFloat = autoGain ? min(40, 0.8 / CGFloat(peak)) : 1
        model.gain += (target - model.gain) * (abs(target - model.gain) > model.gain ? 1 : 0.15)

        if mode == .overlay {
            let mid = plot.midY, half = plot.height / 2
            gc.stroke(trace(r, s0, window, plot.minX, plot.width, mid, half), with: .color(Self.traceR), lineWidth: 1)
            gc.stroke(trace(l, s0, window, plot.minX, plot.width, mid, half), with: .color(Self.traceL), lineWidth: 1)
            laneLabel(gc, "L", CGPoint(x: plot.minX + 6, y: plot.minY + 8), Self.traceL)
            laneLabel(gc, "R", CGPoint(x: plot.minX + 18, y: plot.minY + 8), Self.traceR)
        } else {
            let half = plot.height / 4
            let midL = plot.minY + half, midR = plot.minY + 3 * half
            gc.stroke(trace(l, s0, window, plot.minX, plot.width, midL, half), with: .color(Self.traceL), lineWidth: 1)
            gc.stroke(trace(r, s0, window, plot.minX, plot.width, midR, half), with: .color(Self.traceR), lineWidth: 1)
            laneLabel(gc, "L", CGPoint(x: plot.minX + 6, y: plot.minY + 8), Self.traceL)
            laneLabel(gc, "R", CGPoint(x: plot.minX + 6, y: plot.midY + 8), Self.traceR)
        }

        // Trigger position marker (top) and trigger channel/level marker (right edge).
        let tx = plot.minX + plot.width / 10
        var m = Path()
        m.move(to: CGPoint(x: tx - 4, y: plot.minY - 6)); m.addLine(to: CGPoint(x: tx + 4, y: plot.minY - 6))
        m.addLine(to: CGPoint(x: tx, y: plot.minY - 1)); m.closeSubpath()
        gc.fill(m, with: .color(Theme.textTertiary))
        let ty = mode == .overlay ? plot.midY : (triggerChannel == .left ? plot.minY + plot.height / 4 : plot.minY + plot.height * 0.75)
        var a = Path()
        a.move(to: CGPoint(x: plot.maxX + 7, y: ty - 4)); a.addLine(to: CGPoint(x: plot.maxX + 7, y: ty + 4))
        a.addLine(to: CGPoint(x: plot.maxX + 2, y: ty)); a.closeSubpath()
        gc.fill(a, with: .color(triggerChannel == .left ? Self.traceL : Self.traceR))

        // Status, bottom-right.
        var status = model.triggered ? "" : "Free run"
        if autoGain { status += (status.isEmpty ? "" : "  ") + String(format: "\u{00D7}%.1f", model.gain) }
        if !status.isEmpty {
            gc.draw(Text(status).font(Theme.numeric(10, weight: .regular)).foregroundStyle(Theme.textSecondary),
                    at: CGPoint(x: plot.maxX - 4, y: plot.maxY - 8), anchor: .trailing)
        }
    }

    private func laneLabel(_ gc: GraphicsContext, _ s: String, _ p: CGPoint, _ c: Color) {
        gc.draw(Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(c), at: p, anchor: .leading)
    }

    /// Latest rising edge through 0 (with hysteresis) that follows ≥ hold-off of low signal and
    /// leaves room for a full sweep after it. For LTC this always lands on the edge after a "0"
    /// bit, so the bi-phase train stands still.
    private func findTrigger(_ s: [Float], window: Int, pre: Int, sampleRate: Double) -> Int? {
        let n = s.count
        let maxIdx = n - (window - pre)
        guard maxIdx > pre + 1 else { return nil }
        var amp: Float = 0
        for v in s { amp = max(amp, abs(v)) }
        guard amp > 0.003 else { return nil }
        let hyst = amp * 0.1
        let hold = Int(Self.holdOff * sampleRate)
        var lowRun = 0
        var found: Int?
        for i in 1..<maxIdx {
            let v = s[i]
            if v < -hyst { lowRun += 1 }
            if s[i - 1] < 0, v >= 0 {
                if lowRun >= hold, i >= pre { found = i }
                lowRun = 0
            } else if v > hyst {
                lowRun = 0
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

    private func drawGraticule(_ gc: GraphicsContext, _ r: CGRect, lanes: Int) {
        let hw = Theme.hairlineWidth
        var grid = Path()
        for i in 0...10 {
            let x = r.minX + r.width * CGFloat(i) / 10
            grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY))
        }
        for j in 0...8 {
            let y = r.minY + r.height * CGFloat(j) / 8
            grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        gc.stroke(grid, with: .color(Theme.scopeGrid), lineWidth: max(hw, 0.5))

        // Centre cross with minor ticks (5 per division).
        var cross = Path()
        let centres: [CGFloat] = lanes == 2 ? [r.minY + r.height / 4, r.minY + r.height * 0.75] : [r.midY]
        for cy in centres {
            cross.move(to: CGPoint(x: r.minX, y: cy)); cross.addLine(to: CGPoint(x: r.maxX, y: cy))
            for k in 0...50 {
                let x = r.minX + r.width * CGFloat(k) / 50
                let t: CGFloat = k % 5 == 0 ? 0 : 2.5
                if t > 0 { cross.move(to: CGPoint(x: x, y: cy - t)); cross.addLine(to: CGPoint(x: x, y: cy + t)) }
            }
        }
        cross.move(to: CGPoint(x: r.midX, y: r.minY)); cross.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        for k in 0...40 {
            let y = r.minY + r.height * CGFloat(k) / 40
            if k % 5 != 0 { cross.move(to: CGPoint(x: r.midX - 2.5, y: y)); cross.addLine(to: CGPoint(x: r.midX + 2.5, y: y)) }
        }
        if lanes == 2 {
            cross.move(to: CGPoint(x: r.minX, y: r.midY)); cross.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        }
        gc.stroke(cross, with: .color(Theme.scopeGrid.mix(with: Theme.textTertiary, by: 0.45)), lineWidth: max(hw, 0.5))
    }

    // MARK: X/Y (goniometer)

    private func drawXY(_ gc: GraphicsContext, _ plot: CGRect, _ snap: AnalysisSnapshot) {
        let side = min(plot.width, plot.height)
        let r = CGRect(x: plot.midX - side / 2, y: plot.midY - side / 2, width: side, height: side)
        let gridColor = Theme.scopeGrid
        var grid = Path()
        for i in 0...8 {
            let f = CGFloat(i) / 8
            grid.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); grid.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
            grid.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); grid.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
        }
        gc.stroke(grid, with: .color(gridColor), lineWidth: max(Theme.hairlineWidth, 0.5))
        var axes = Path()
        axes.move(to: CGPoint(x: r.minX, y: r.minY)); axes.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        axes.move(to: CGPoint(x: r.maxX, y: r.minY)); axes.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        axes.move(to: CGPoint(x: r.midX, y: r.minY)); axes.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        axes.move(to: CGPoint(x: r.minX, y: r.midY)); axes.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        gc.stroke(axes, with: .color(gridColor.mix(with: Theme.textTertiary, by: 0.45)), lineWidth: max(Theme.hairlineWidth, 0.5))
        laneLabel(gc, "L", CGPoint(x: r.minX + 4, y: r.minY + 9), Self.traceL)
        gc.draw(Text("R").font(.system(size: 10, weight: .semibold)).foregroundStyle(Self.traceR),
                at: CGPoint(x: r.maxX - 4, y: r.minY + 9), anchor: .trailing)
        gc.draw(Text("M").font(.system(size: 10, weight: .regular)).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: r.midX + 5, y: r.minY + 9), anchor: .leading)
        gc.draw(Text("S").font(.system(size: 10, weight: .regular)).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: r.maxX - 4, y: r.midY - 8), anchor: .trailing)

        let l = snap.scopeL, rr = snap.scopeR
        let n = min(l.count, rr.count)
        guard n > 0 else { return }
        let window = min(n, max(64, Int(msPerDiv / 1000 * snap.sampleRate * 10)))
        var peak: Float = 0.001
        for i in (n - window)..<n { peak = max(peak, abs(l[i]), abs(rr[i])) }
        let target: CGFloat = autoGain ? min(40, 0.7 / CGFloat(peak)) : 1
        model.gain += (target - model.gain) * 0.15

        // Rotated 45°: M = L+R up, S = R−L right. Normalised so a full-scale mono signal hits the edge.
        let stride = max(1, window / 700)
        var pts: [CGPoint] = []
        pts.reserveCapacity(window / stride + 1)
        var i = n - window
        while i < n {
            let lv = CGFloat(l[i]), rv = CGFloat(rr[i])
            pts.append(CGPoint(x: (rv - lv) * 0.7071 * model.gain, y: (lv + rv) * 0.7071 * model.gain))
            i += stride
        }
        model.xyHistory.append(pts)
        if model.xyHistory.count > 6 { model.xyHistory.removeFirst(model.xyHistory.count - 6) }

        let opacities: [Double] = [0.07, 0.12, 0.19, 0.28, 0.45, 0.9]
        let offset = opacities.count - model.xyHistory.count
        let half = side / 2
        for (k, set) in model.xyHistory.enumerated() {
            var dots = Path()
            for p in set {
                let x = r.midX + max(-1, min(1, p.x)) * half
                let y = r.midY - max(-1, min(1, p.y)) * half
                dots.addRect(CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
            }
            gc.fill(dots, with: .color(Self.traceL.opacity(opacities[k + offset])))
        }
    }
}
