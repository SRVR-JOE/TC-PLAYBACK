import SwiftUI

/// Measurement screen for the spectrum analyser: log frequency 20 Hz – 20 kHz, dBFS, grid at
/// decades with 2–9 subdivisions and octave ticks, drawn at display rate from the engine's
/// latest frame. Drag (or point, on iPad) for a readout; double tap clears it.
struct SpectrumPlot: View {
    var engine: SpectrumEngine
    var kind: SpectrumPanel.Kind
    var storeA: StoredTrace?
    var storeB: StoredTrace?
    var showHold: Bool
    var showMax: Bool
    var blankLowCoherence: Bool
    var held: Bool
    @Binding var cursor: Double?

    static let inputColor = Color(hex: 0x5E9EA8)
    static let outputColor = Theme.scopeTrace
    static let storeAColor = Color(hex: 0x93B07A)
    static let storeBColor = Color(hex: 0xC4908A)
    static let coherenceColor = Color(hex: 0xA8706A)
    private static let small = Font.system(size: 10, weight: .regular).monospacedDigit()
    private static let fLow = 20.0, fHigh = 20_000.0
    private static let specBands = OctaveBands(fraction: SpectrumCore.spectrogramFraction)

    /// Numbers with a typographic minus.
    static func signed(_ v: Float, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f", v).replacingOccurrences(of: "-", with: "−")
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: held)) { _ in
                Canvas(rendersAsynchronously: false) { gc, size in render(gc, size) }
            }
            .background(Theme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                cursor = frequency(at: v.location.x, plot: plotRect(geo.size))
            })
            .onTapGesture(count: 2) { cursor = nil }
            .onContinuousHover { phase in
                if case .active(let p) = phase { cursor = frequency(at: p.x, plot: plotRect(geo.size)) }
            }
            .accessibilityElement()
            .accessibilityLabel(kind.label)
            .accessibilityValue(accessibilityText)
        }
    }

    private var accessibilityText: String {
        let f = engine.frame()
        if let p = f.peaks.first { return "Strongest peak \(SpectrumMath.formatHz(p.frequency)) at \(String(format: "%.0f", p.dB)) dBFS" }
        return f.hasInput || f.hasOutput ? "No clear peak" : "No signal"
    }

    // MARK: Geometry

    private func plotRect(_ size: CGSize) -> CGRect {
        let right: CGFloat = kind == .spectrogram ? 44 : (kind == .transfer ? 30 : 10)
        return CGRect(x: 38, y: 10, width: max(10, size.width - 38 - right), height: max(10, size.height - 10 - 22))
    }

    private func x(_ f: Double, _ r: CGRect) -> CGFloat {
        r.minX + CGFloat(log10(max(f, 1) / Self.fLow) / log10(Self.fHigh / Self.fLow)) * r.width
    }

    private func frequency(at px: CGFloat, plot r: CGRect) -> Double {
        let t = Double(max(0, min(1, (px - r.minX) / r.width)))
        return Self.fLow * pow(Self.fHigh / Self.fLow, t)
    }

    // MARK: Render

    private func render(_ gc: GraphicsContext, _ size: CGSize) {
        let f = engine.frame()
        let plot = plotRect(size)
        guard plot.width > 60, plot.height > 40 else { return }
        switch kind {
        case .spectrum:
            let range = levelRange
            frequencyGrid(gc, plot, labels: true)
            levelGrid(gc, plot, range)
            drawSpectrum(gc, plot, f, range)
            if let c = cursor { spectrumReadout(gc, plot, f, c, range) }
            if let m = message(f) { centred(gc, plot, m) }
        case .spectrogram:
            drawSpectrogram(gc, plot, f)
            frequencyGrid(gc, plot, labels: true, overImage: true)
            if let c = cursor { spectrogramCursor(gc, plot, c) }
            if let m = message(f) { centred(gc, plot, m) }
        case .transfer:
            drawTransfer(gc, plot, f)
        }
        if held {
            gc.draw(Text("Held").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.stop),
                    at: CGPoint(x: plot.maxX - 6, y: plot.minY + 10), anchor: .trailing)
        }
    }

    private var levelRange: (top: Float, bottom: Float) {
        let s = engine.settings
        return (s.topDB, s.topDB - s.rangeDB)
    }

    private func message(_ f: SpectrumFrame) -> String? {
        let s = engine.settings.sources
        if kind == .transfer { return f.hasInput && f.hasOutput ? nil : "Transfer needs the output playing and its return on the input" }
        if s == .output { return f.hasOutput ? nil : "Nothing playing" }
        if s == .input { return f.hasInput ? nil : "Waiting for the device audio input" }
        if !f.hasInput && !f.hasOutput { return "Waiting for the device audio input" }
        return nil
    }

    private func centred(_ gc: GraphicsContext, _ r: CGRect, _ s: String) {
        gc.draw(Text(s).font(Theme.caption).foregroundStyle(Theme.textSecondary), at: CGPoint(x: r.midX, y: r.midY))
    }

    // MARK: Grid

    private func frequencyGrid(_ gc: GraphicsContext, _ r: CGRect, labels: Bool, overImage: Bool = false) {
        let hw = max(Theme.hairlineWidth, 0.5)
        var minor = Path(), major = Path()
        var decade = 10.0
        while decade <= 10_000 {
            for m in 1...9 {
                let f = decade * Double(m)
                guard f >= Self.fLow, f <= Self.fHigh else { continue }
                let px = x(f, r)
                if m == 1 { major.move(to: CGPoint(x: px, y: r.minY)); major.addLine(to: CGPoint(x: px, y: r.maxY)) }
                else { minor.move(to: CGPoint(x: px, y: r.minY)); minor.addLine(to: CGPoint(x: px, y: r.maxY)) }
            }
            decade *= 10
        }
        if !overImage { gc.stroke(minor, with: .color(Theme.scopeGrid), lineWidth: hw) }
        gc.stroke(major, with: .color(Theme.textTertiary.opacity(overImage ? 0.35 : 0.55)), lineWidth: hw)
        // Octave ticks (ISO centres) along the bottom edge.
        var ticks = Path()
        for o in [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000] {
            let px = x(o, r)
            ticks.move(to: CGPoint(x: px, y: r.maxY - 4)); ticks.addLine(to: CGPoint(x: px, y: r.maxY))
        }
        gc.stroke(ticks, with: .color(Theme.textTertiary), lineWidth: 1)
        gc.stroke(Path(r), with: .color(Theme.hairline), lineWidth: hw)
        guard labels else { return }
        let marks: [(Double, String)] = [(20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
                                         (1000, "1k"), (2000, "2k"), (5000, "5k"), (10_000, "10k"), (20_000, "20k")]
        for (fr, s) in marks {
            let anchor: UnitPoint = fr == 20 ? .topLeading : (fr == 20_000 ? .topTrailing : .top)
            gc.draw(Text(s).font(Self.small).foregroundStyle(Theme.textTertiary), at: CGPoint(x: x(fr, r), y: r.maxY + 5), anchor: anchor)
        }
    }

    private func levelGrid(_ gc: GraphicsContext, _ r: CGRect, _ range: (top: Float, bottom: Float)) {
        let hw = max(Theme.hairlineWidth, 0.5)
        let span = range.top - range.bottom
        let step: Float = r.height / CGFloat(span / 10) < 18 ? 20 : 10
        var grid = Path()
        var db = range.top
        while db >= range.bottom - 0.01 {
            let py = y(db, r, range)
            grid.move(to: CGPoint(x: r.minX, y: py)); grid.addLine(to: CGPoint(x: r.maxX, y: py))
            gc.draw(Text(Self.signed(db)).font(Self.small).foregroundStyle(Theme.textTertiary),
                    at: CGPoint(x: r.minX - 5, y: py), anchor: .trailing)
            db -= step
        }
        gc.stroke(grid, with: .color(Theme.scopeGrid), lineWidth: hw)
        gc.draw(Text("dBFS").font(Self.small).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: r.minX - 5, y: r.maxY + 5), anchor: .topTrailing)
    }

    private func y(_ db: Float, _ r: CGRect, _ range: (top: Float, bottom: Float)) -> CGFloat {
        let t = CGFloat((range.top - db) / (range.top - range.bottom))
        return r.minY + max(0, min(1, t)) * r.height
    }

    // MARK: Spectrum

    private func traceColor(_ t: SpectrumTrace) -> Color { t.stream == .input ? Self.inputColor : Self.outputColor }

    private func drawSpectrum(_ gc: GraphicsContext, _ r: CGRect, _ f: SpectrumFrame, _ range: (top: Float, bottom: Float)) {
        gc.drawLayer { g in
            g.clip(to: Path(r))
            for (store, color) in [(storeA, Self.storeAColor), (storeB, Self.storeBColor)] {
                guard let s = store, s.kind == .spectrum else { continue }
                g.stroke(curve(s.centers, s.lower, s.upper, s.level, r, range, bars: s.display == .bars),
                         with: .color(color.opacity(0.9)), lineWidth: 1.2)
            }
            let bars = f.display == .bars
            for (i, t) in f.traces.enumerated() {
                let c = traceColor(t)
                let dash: [CGFloat] = t.channel == 1 ? [5, 3] : []
                if bars && i == 0 {
                    var fill = Path()
                    for b in 0..<f.centers.count where t.level[b] > range.bottom {
                        let x0 = x(f.lower[b], r) + 0.5, x1 = x(f.upper[b], r) - 0.5
                        let top = y(t.level[b], r, range)
                        fill.addRect(CGRect(x: x0, y: top, width: max(0.5, x1 - x0), height: r.maxY - top))
                    }
                    g.fill(fill, with: .color(c.opacity(0.28)))
                }
                if showMax {
                    g.stroke(curve(f.centers, f.lower, f.upper, t.max, r, range, bars: bars),
                             with: .color(c.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2.5]))
                }
                if showHold {
                    if bars {
                        var ticks = Path()
                        for b in 0..<f.centers.count where t.hold[b] > range.bottom {
                            let py = y(t.hold[b], r, range)
                            ticks.move(to: CGPoint(x: x(f.lower[b], r) + 0.5, y: py))
                            ticks.addLine(to: CGPoint(x: x(f.upper[b], r) - 0.5, y: py))
                        }
                        g.stroke(ticks, with: .color(c.opacity(0.7)), lineWidth: 1)
                    } else {
                        g.stroke(curve(f.centers, f.lower, f.upper, t.hold, r, range, bars: false),
                                 with: .color(c.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: dash))
                    }
                }
                g.stroke(curve(f.centers, f.lower, f.upper, t.level, r, range, bars: bars),
                         with: .color(c), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: dash))
            }
        }
        let top = legend(gc, r, f)
        peakLabels(gc, r, f, range, below: top)
    }

    /// Line through the band centres, or a stepped outline across the band edges.
    private func curve(_ c: [Double], _ lo: [Double], _ hi: [Double], _ v: [Float], _ r: CGRect,
                       _ range: (top: Float, bottom: Float), bars: Bool) -> Path {
        var p = Path()
        let n = min(c.count, v.count)
        guard n > 1 else { return p }
        for b in 0..<n {
            let py = y(v[b], r, range)
            if bars {
                let x0 = x(lo[b], r), x1 = x(hi[b], r)
                if b == 0 { p.move(to: CGPoint(x: x0, y: py)) } else { p.addLine(to: CGPoint(x: x0, y: py)) }
                p.addLine(to: CGPoint(x: x1, y: py))
            } else {
                let pt = CGPoint(x: x(c[b], r), y: py)
                if b == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
        return p
    }

    /// Returns the bottom of the legend.
    private func legend(_ gc: GraphicsContext, _ r: CGRect, _ f: SpectrumFrame) -> CGFloat {
        var items: [(String, Color, Bool)] = []
        for t in f.traces {
            let side = f.midSide ? (t.channel == 0 ? "mid" : "side") : (t.channel == 0 ? "left" : "right")
            let mono = t.stream == .input && engine.settings.inputMono
            let name = (t.stream == .input ? "Input" : "Output") + (mono ? "" : " \(side)")
            items.append((name, traceColor(t), t.channel == 1))
        }
        if let s = storeA, s.kind == .spectrum { items.append(("Trace A", Self.storeAColor, false)) }
        if let s = storeB, s.kind == .spectrum { items.append(("Trace B", Self.storeBColor, false)) }
        var px = r.minX + 8, py = r.minY + 10
        for (name, c, dashed) in items {
            let text = gc.resolve(Text(name).font(Theme.caption).foregroundStyle(Theme.textSecondary))
            let sz = text.measure(in: CGSize(width: 300, height: 30))
            if px + 19 + sz.width > r.maxX - 4, px > r.minX + 8 { px = r.minX + 8; py += sz.height + 3 }
            var line = Path()
            line.move(to: CGPoint(x: px, y: py)); line.addLine(to: CGPoint(x: px + 14, y: py))
            gc.stroke(line, with: .color(c), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 2] : []))
            gc.draw(text, at: CGPoint(x: px + 19, y: py), anchor: .leading)
            px += 19 + sz.width + 14
        }
        return py + 8
    }

    private func peakLabels(_ gc: GraphicsContext, _ r: CGRect, _ f: SpectrumFrame, _ range: (top: Float, bottom: Float), below legendBottom: CGFloat) {
        guard cursor == nil else { return }
        var used: [CGRect] = []
        for p in f.peaks where p.frequency >= Self.fLow && p.frequency <= Self.fHigh {
            let px = x(p.frequency, r)
            let py = y(p.dB, r, range)
            var mark = Path()
            mark.move(to: CGPoint(x: px, y: py - 2)); mark.addLine(to: CGPoint(x: px, y: py - 9))
            gc.stroke(mark, with: .color(Theme.textSecondary), lineWidth: 1)
            let text = gc.resolve(Text("\(SpectrumMath.formatHz(p.frequency))  \(Self.signed(p.dB, decimals: 1))")
                .font(Self.small).foregroundStyle(Theme.textPrimary))
            let sz = text.measure(in: CGSize(width: 200, height: 20))
            var box = CGRect(x: px - sz.width / 2, y: py - 12 - sz.height, width: sz.width, height: sz.height)
            box.origin.x = max(r.minX + 2, min(r.maxX - sz.width - 2, box.minX))
            box.origin.y = max(legendBottom + 4, box.minY)
            while used.contains(where: { $0.insetBy(dx: -4, dy: -1).intersects(box) }) { box.origin.y += sz.height + 2 }
            used.append(box)
            gc.fill(Path(roundedRect: box.insetBy(dx: -3, dy: -1), cornerRadius: 2), with: .color(Theme.surfaceSunken.opacity(0.85)))
            gc.draw(text, in: box)
        }
    }

    private func readoutBox(_ gc: GraphicsContext, _ r: CGRect, _ lines: [String]) {
        let text = gc.resolve(Text(lines.joined(separator: "\n")).font(Theme.numeric(11, weight: .regular)).foregroundStyle(Theme.textPrimary))
        let sz = text.measure(in: CGSize(width: 400, height: 200))
        let box = CGRect(x: r.maxX - sz.width - 14, y: r.minY + 24, width: sz.width + 8, height: sz.height + 6)
        gc.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(Theme.surface.opacity(0.92)))
        gc.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(Theme.hairline), lineWidth: 1)
        gc.draw(text, in: box.insetBy(dx: 4, dy: 3))
    }

    private func cursorLine(_ gc: GraphicsContext, _ r: CGRect, _ fr: Double) {
        var l = Path()
        let px = x(fr, r)
        l.move(to: CGPoint(x: px, y: r.minY)); l.addLine(to: CGPoint(x: px, y: r.maxY))
        gc.stroke(l, with: .color(Theme.textSecondary.opacity(0.8)), lineWidth: 1)
    }

    private func noteText(_ fr: Double) -> String {
        guard let n = SpectrumMath.note(fr) else { return "" }
        return n.cents == 0 ? n.name : "\(n.name) \(n.cents > 0 ? "+" : "−")\(abs(n.cents)) cents"
    }

    private func nearestBand(_ f: SpectrumFrame, _ fr: Double) -> Int? {
        guard !f.centers.isEmpty else { return nil }
        var best = 0
        for i in f.centers.indices where abs(log(f.centers[i] / fr)) < abs(log(f.centers[best] / fr)) { best = i }
        return best
    }

    private func spectrumReadout(_ gc: GraphicsContext, _ r: CGRect, _ f: SpectrumFrame, _ fr: Double, _ range: (top: Float, bottom: Float)) {
        cursorLine(gc, r, fr)
        var lines = ["\(SpectrumMath.formatHz(fr))  \(noteText(fr))"]
        if let b = nearestBand(f, fr) {
            for t in f.traces {
                let side = f.midSide ? (t.channel == 0 ? "mid" : "side") : (t.channel == 0 ? "left" : "right")
                lines.append("\(t.stream == .input ? "Input" : "Output") \(side)  \("\(Self.signed(t.level[b], decimals: 1)) dB")")
                let py = y(t.level[b], r, range)
                gc.fill(Path(ellipseIn: CGRect(x: x(f.centers[b], r) - 3, y: py - 3, width: 6, height: 6)), with: .color(traceColor(t)))
            }
            for (s, name) in [(storeA, "Trace A"), (storeB, "Trace B")] {
                guard let s, s.kind == .spectrum, let i = s.centers.indices.min(by: { abs(log(s.centers[$0] / fr)) < abs(log(s.centers[$1] / fr)) })
                else { continue }
                lines.append("\(name)  \("\(Self.signed(s.level[i], decimals: 1)) dB")")
            }
        }
        readoutBox(gc, r, lines)
    }

    // MARK: Spectrogram

    private func drawSpectrogram(_ gc: GraphicsContext, _ r: CGRect, _ f: SpectrumFrame) {
        gc.fill(Path(r), with: .color(Color(hex: 0x0A0B0D)))
        if let img = f.spectrogram {
            let b = Self.specBands
            let x0 = x(b.lower.first ?? 20, r), x1 = x(b.upper.last ?? 20_000, r)
            gc.drawLayer { g in
                g.clip(to: Path(r))
                g.draw(Image(decorative: img, scale: 1).interpolation(.medium), in: CGRect(x: x0, y: r.minY, width: x1 - x0, height: r.height))
            }
        }
        // Time scale (seconds ago) on the left.
        let secs = f.spectrogramSeconds
        if secs > 0 {
            let step = secs > 8 ? 4.0 : (secs > 4 ? 2.0 : 1.0)
            var t = 0.0
            while t <= secs + 0.001 {
                let py = r.minY + CGFloat(t / secs) * r.height
                gc.draw(Text(t == 0 ? "Now" : String(format: "−%.0f s", t)).font(Self.small).foregroundStyle(Theme.textTertiary),
                        at: CGPoint(x: r.minX - 5, y: py), anchor: .trailing)
                t += step
            }
        }
        // Colour scale on the right.
        let bar = CGRect(x: r.maxX + 8, y: r.minY, width: 8, height: r.height)
        let lut = SpectrumCore.makeLUT()
        let steps = 48
        for i in 0..<steps {
            let v = lut[Int(Double(steps - 1 - i) / Double(steps - 1) * 255)]
            let c = Color(.sRGB, red: Double(v & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double((v >> 16) & 0xFF) / 255)
            gc.fill(Path(CGRect(x: bar.minX, y: bar.minY + bar.height * CGFloat(i) / CGFloat(steps), width: bar.width,
                                height: bar.height / CGFloat(steps) + 0.5)), with: .color(c))
        }
        gc.stroke(Path(bar), with: .color(Theme.hairline), lineWidth: 1)
        let range = levelRange
        gc.draw(Text(Self.signed(range.top)).font(Self.small).foregroundStyle(Theme.textTertiary), at: CGPoint(x: bar.maxX + 3, y: bar.minY), anchor: .topLeading)
        gc.draw(Text(Self.signed(range.bottom)).font(Self.small).foregroundStyle(Theme.textTertiary), at: CGPoint(x: bar.maxX + 3, y: bar.maxY), anchor: .bottomLeading)
    }

    private func spectrogramCursor(_ gc: GraphicsContext, _ r: CGRect, _ fr: Double) {
        cursorLine(gc, r, fr)
        readoutBox(gc, r, ["\(SpectrumMath.formatHz(fr))  \(noteText(fr))"])
    }

    // MARK: Transfer

    private func drawTransfer(_ gc: GraphicsContext, _ r: CGRect, _ f: SpectrumFrame) {
        let gap: CGFloat = 26
        let magH = (r.height - gap) * 0.62
        let mag = CGRect(x: r.minX, y: r.minY, width: r.width, height: magH)
        let ph = CGRect(x: r.minX, y: mag.maxY + gap, width: r.width, height: r.height - magH - gap)
        let magRange: (top: Float, bottom: Float) = (24, -24)
        let phRange: (top: Float, bottom: Float) = (180, -180)

        frequencyGrid(gc, mag, labels: false)
        frequencyGrid(gc, ph, labels: true)
        let hw = max(Theme.hairlineWidth, 0.5)
        var g1 = Path()
        for db in stride(from: magRange.top, through: magRange.bottom, by: -6) {
            let py = y(db, mag, magRange)
            g1.move(to: CGPoint(x: mag.minX, y: py)); g1.addLine(to: CGPoint(x: mag.maxX, y: py))
            if Int(db) % 12 == 0 {
                gc.draw(Text(db > 0 ? "+\(Int(db))" : Self.signed(db)).font(Self.small).foregroundStyle(Theme.textTertiary),
                        at: CGPoint(x: mag.minX - 5, y: py), anchor: .trailing)
            }
        }
        var g2 = Path()
        for d in stride(from: phRange.top, through: phRange.bottom, by: -90) {
            let py = y(d, ph, phRange)
            g2.move(to: CGPoint(x: ph.minX, y: py)); g2.addLine(to: CGPoint(x: ph.maxX, y: py))
            gc.draw(Text("\(Self.signed(d))°").font(Self.small).foregroundStyle(Theme.textTertiary), at: CGPoint(x: ph.minX - 5, y: py), anchor: .trailing)
        }
        gc.stroke(g1, with: .color(Theme.scopeGrid), lineWidth: hw)
        gc.stroke(g2, with: .color(Theme.scopeGrid), lineWidth: hw)
        // 0 dB reference line.
        var zero = Path()
        zero.move(to: CGPoint(x: mag.minX, y: y(0, mag, magRange))); zero.addLine(to: CGPoint(x: mag.maxX, y: y(0, mag, magRange)))
        gc.stroke(zero, with: .color(Theme.textTertiary.opacity(0.7)), lineWidth: hw)
        // Coherence scale (right of the magnitude plot).
        for (v, s) in [(1.0, "1"), (0.5, "0.5"), (0.0, "0")] {
            gc.draw(Text(s).font(Self.small).foregroundStyle(Self.coherenceColor.opacity(0.9)),
                    at: CGPoint(x: mag.maxX + 4, y: mag.minY + CGFloat(1 - v) * mag.height), anchor: .leading)
        }
        gc.draw(Text("Magnitude, dB").font(Theme.caption).foregroundStyle(Theme.textSecondary), at: CGPoint(x: mag.minX + 8, y: mag.minY + 10), anchor: .leading)
        gc.draw(Text("Phase").font(Theme.caption).foregroundStyle(Theme.textSecondary), at: CGPoint(x: ph.minX + 8, y: ph.minY + 10), anchor: .leading)
        gc.draw(Text("Coherence").font(Theme.caption).foregroundStyle(Self.coherenceColor), at: CGPoint(x: mag.maxX - 8, y: mag.minY + 10), anchor: .trailing)

        for (store, color) in [(storeA, Self.storeAColor), (storeB, Self.storeBColor)] {
            guard let s = store, s.kind == .transfer else { continue }
            gc.drawLayer { g in
                g.clip(to: Path(mag))
                g.stroke(tfPath(s.centers, s.level, s.coherence, mag, magRange, wrap: false, minCoh: blankLowCoherence ? 0.3 : 0, maxCoh: 1.01),
                         with: .color(color.opacity(0.85)), lineWidth: 1.2)
            }
            gc.drawLayer { g in
                g.clip(to: Path(ph))
                g.stroke(tfPath(s.centers, s.phase, s.coherence, ph, phRange, wrap: true, minCoh: blankLowCoherence ? 0.3 : 0, maxCoh: 1.01),
                         with: .color(color.opacity(0.85)), lineWidth: 1)
            }
        }

        guard let t = f.transfer, f.hasInput, f.hasOutput else {
            centred(gc, mag, "Transfer needs the output playing and its return on the input")
            return
        }
        // Coherence trace, 0…1 over the magnitude plot height.
        var coh = Path()
        for b in f.centers.indices {
            let pt = CGPoint(x: x(f.centers[b], mag), y: mag.minY + CGFloat(1 - t.coherence[b]) * mag.height)
            if b == 0 { coh.move(to: pt) } else { coh.addLine(to: pt) }
        }
        gc.drawLayer { g in
            g.clip(to: Path(mag))
            g.stroke(coh, with: .color(Self.coherenceColor.opacity(0.8)), lineWidth: 1)
            // Full strength where coherence is good, dimmed where doubtful, blank where poor.
            let lo: Float = blankLowCoherence ? 0.3 : 0
            g.stroke(tfPath(f.centers, t.magnitudeDB, t.coherence, mag, magRange, wrap: false, minCoh: lo, maxCoh: 0.7),
                     with: .color(Self.inputColor.opacity(0.45)), lineWidth: 1.5)
            g.stroke(tfPath(f.centers, t.magnitudeDB, t.coherence, mag, magRange, wrap: false, minCoh: 0.7, maxCoh: 1.01),
                     with: .color(Self.inputColor), lineWidth: 1.6)
        }
        gc.drawLayer { g in
            g.clip(to: Path(ph))
            let lo: Float = blankLowCoherence ? 0.3 : 0
            g.stroke(tfPath(f.centers, t.phaseDeg, t.coherence, ph, phRange, wrap: true, minCoh: lo, maxCoh: 0.7),
                     with: .color(Self.inputColor.opacity(0.45)), lineWidth: 1.2)
            g.stroke(tfPath(f.centers, t.phaseDeg, t.coherence, ph, phRange, wrap: true, minCoh: 0.7, maxCoh: 1.01),
                     with: .color(Self.inputColor), lineWidth: 1.4)
        }
        if let c = cursor, let b = nearestBand(f, c) {
            cursorLine(gc, mag, c); cursorLine(gc, ph, c)
            readoutBox(gc, mag, ["\(SpectrumMath.formatHz(c))  \(noteText(c))",
                                 String(format: "Magnitude  %+.1f dB", t.magnitudeDB[b]),
                                 String(format: "Phase  %+.0f°", t.phaseDeg[b]),
                                 String(format: "Coherence  %.2f", t.coherence[b])])
        }
    }

    /// Segments of the trace whose coherence (the lower of the two ends) lies in
    /// [minCoh, maxCoh). Phase breaks where it wraps.
    private func tfPath(_ c: [Double], _ v: [Float], _ coh: [Float], _ r: CGRect, _ range: (top: Float, bottom: Float),
                        wrap: Bool, minCoh: Float, maxCoh: Float) -> Path {
        var p = Path()
        let n = min(c.count, v.count, coh.count)
        guard n > 1 else { return p }
        for b in 1..<n {
            let m = min(coh[b - 1], coh[b])
            guard m >= minCoh, m < maxCoh, !(wrap && abs(v[b] - v[b - 1]) > 180) else { continue }
            p.move(to: CGPoint(x: x(c[b - 1], r), y: y(v[b - 1], r, range)))
            p.addLine(to: CGPoint(x: x(c[b], r), y: y(v[b], r, range)))
        }
        return p
    }
}
