import SwiftUI
import QuartzCore
import TCKit

/// Output and input drawn on one pair of traces (left lane, right lane) over the same span of
/// host time, so a loop back can be compared by eye. Optionally shifted by the measured round
/// trip so the returned signal lands on top of what was sent. Shares the page timebase.
struct ScopeOverlayView: View {
    var analyzer: ScopeAnalyzer
    @Binding var timebase: Int
    @Binding var hold: Bool
    @Binding var align: Bool

    @State private var frozen: ScopeCore.Aligned?
    @State private var gains = Gains()

    final class Gains { var l: CGFloat = 1; var r: CGFloat = 1 }

    static let outColor = Theme.scopeTrace
    static let inColor = Color(hex: 0x5E9EA8)
    private static let mono9 = Font.system(size: 9, weight: .regular, design: .monospaced)

    private var msPerDiv: Double { OscilloscopeContent.timebases[max(0, min(OscilloscopeContent.timebases.count - 1, timebase))] }

    var body: some View {
        VStack(spacing: 6) {
            controls
            TimelineView(.animation(paused: hold)) { _ in
                Canvas(rendersAsynchronously: false) { gc, size in render(gc, size) }
            }
            .background(Theme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .accessibilityElement()
            .accessibilityLabel("Output and input overlay")
            .accessibilityValue("\(OscilloscopeContent.timeText(ms: msPerDiv)) per division\(hold ? ", held" : "")")
        }
        .onChange(of: hold, initial: true) { _, h in
            frozen = h ? fetch() : nil
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            legend("Output", Self.outColor)
            legend("Input", Self.inColor)
            Spacer(minLength: 4)
            Button { align.toggle() } label: {
                HStack(spacing: 5) {
                    IndicatorLamp(color: Theme.accent, isOn: align, size: 6)
                    Text("Line up by round trip")
                }
            }
            .buttonStyle(VisualsKeyStyle(isOn: align))
            .lineLimit(1)
            .fixedSize()
            HStack(spacing: 0) {
                Button { timebase = min(OscilloscopeContent.timebases.count - 1, timebase + 1) } label: {
                    Image(systemName: "minus").frame(width: 12)
                }
                .buttonStyle(VisualsKeyStyle())
                .accessibilityLabel("Slower timebase")
                Text("\(OscilloscopeContent.timeText(ms: msPerDiv))/div")
                    .font(Theme.numeric(11))
                    .foregroundStyle(VisualsColor.primary)
                    .frame(minWidth: 72)
                Button { timebase = max(0, timebase - 1) } label: { Image(systemName: "plus").frame(width: 12) }
                    .buttonStyle(VisualsKeyStyle())
                    .accessibilityLabel("Faster timebase")
            }
        }
        .font(Theme.caption)
    }

    private func legend(_ s: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(c).frame(width: 14, height: 2)
            Text(s).foregroundStyle(VisualsColor.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func fetch() -> ScopeCore.Aligned? {
        analyzer.alignedWindow(count: AnalysisSnapshot.scopeLength * 4, alignByLatency: align)
    }

    // MARK: Drawing

    private func render(_ gc: GraphicsContext, _ size: CGSize) {
        let plot = CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20)
        guard plot.width > 40, plot.height > 40 else { return }
        drawGraticule(gc, plot)
        guard let a = frozen ?? fetch() else {
            message(gc, plot, analyzer.hasTap ? "Waiting for the device audio input" : "Nothing playing")
            return
        }
        let n = a.outL.count
        let window = min(n / 2, max(8, Int(msPerDiv / 1000 * a.sampleRate * 10)))
        // Trigger on the output (the channel with more energy) so both traces stand still together.
        let trig = energy(a.outR) > energy(a.outL) ? a.outR : a.outL
        let s0 = trigger(trig, window: window) ?? (n - window)

        let half = plot.height / 4
        let midL = plot.minY + half, midR = plot.minY + 3 * half
        func peak(_ x: [Float]) -> Float {
            var p: Float = 0.001
            for i in s0..<(s0 + window) { p = max(p, abs(x[i])) }
            return p
        }
        if !hold {
            let target = { (p: Float) -> CGFloat in min(40, 0.8 / CGFloat(p)) }
            let tl = target(max(peak(a.outL), peak(a.inL))), tr = target(max(peak(a.outR), peak(a.inR)))
            gains.l += (tl - gains.l) * (tl < gains.l * 0.8 ? 1 : 0.08)
            gains.r += (tr - gains.r) * (tr < gains.r * 0.8 ? 1 : 0.08)
        }
        gc.drawLayer { layer in
            layer.clip(to: Path(plot.insetBy(dx: -1, dy: -1)))
            if a.hasInput {
                layer.stroke(trace(a.inL, s0, window, plot, midL, half, gains.l), with: .color(Self.inColor), lineWidth: 1)
                layer.stroke(trace(a.inR, s0, window, plot, midR, half, gains.r), with: .color(Self.inColor), lineWidth: 1)
            }
            if a.hasOutput {
                layer.stroke(trace(a.outL, s0, window, plot, midL, half, gains.l), with: .color(Self.outColor.opacity(0.9)), lineWidth: 1)
                layer.stroke(trace(a.outR, s0, window, plot, midR, half, gains.r), with: .color(Self.outColor.opacity(0.9)), lineWidth: 1)
            }
        }
        lane(gc, "L", CGPoint(x: plot.minX + 6, y: plot.minY + 9))
        lane(gc, "R", CGPoint(x: plot.minX + 6, y: plot.midY + 9))
        let note: String
        if align, let l = analyzer.latency { note = "Output shifted \(ScopeCompare.formatMS(l.ms)) to line up" }
        else if align { note = "No round trip measured yet" }
        else { note = "Same moment, not lined up" }
        gc.draw(Text(note).font(Self.mono9).foregroundStyle(Theme.textTertiary),
                at: CGPoint(x: plot.maxX - 4, y: plot.minY + 9), anchor: .trailing)
        if !a.hasInput { message(gc, plot, "Waiting for the device audio input") }
        else if !a.hasOutput { message(gc, plot, "Nothing playing") }
        if hold {
            gc.draw(Text("Held").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.stop),
                    at: CGPoint(x: plot.maxX - 4, y: plot.minY + 22), anchor: .trailing)
        }
        for i in stride(from: 1, through: 9, by: 2) {
            let x = plot.minX + plot.width * CGFloat(i) / 10
            gc.draw(Text(OscilloscopeContent.timeText(ms: Double(i - 1) * msPerDiv)).font(Self.mono9).foregroundStyle(Theme.textTertiary),
                    at: CGPoint(x: x + 3, y: plot.maxY - 7), anchor: .leading)
        }
    }

    private func message(_ gc: GraphicsContext, _ plot: CGRect, _ s: String) {
        gc.draw(Text(s).font(Theme.caption).foregroundStyle(Theme.textSecondary), at: CGPoint(x: plot.midX, y: plot.midY))
    }

    private func lane(_ gc: GraphicsContext, _ s: String, _ p: CGPoint) {
        gc.draw(Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary), at: p, anchor: .leading)
    }

    private func energy(_ x: [Float]) -> Float {
        var e: Float = 0
        for v in x.suffix(4096) { e += v * v }
        return e
    }

    /// Latest rising edge through the signal's midpoint that leaves room for a full sweep.
    private func trigger(_ s: [Float], window: Int) -> Int? {
        let pre = window / 10
        let maxIdx = s.count - (window - pre)
        guard maxIdx > pre + 1 else { return nil }
        var amp: Float = 0
        for v in s { amp = max(amp, abs(v)) }
        guard amp > 0.003 else { return nil }
        let hyst = amp * 0.1
        var armed = false
        var found: Int?
        for i in 1..<maxIdx {
            if s[i] < -hyst { armed = true }
            if armed, s[i - 1] < 0, s[i] >= 0 { if i >= pre { found = i }; armed = false }
        }
        return found.map { $0 - pre }
    }

    private func trace(_ s: [Float], _ start: Int, _ count: Int, _ plot: CGRect, _ mid: CGFloat, _ half: CGFloat, _ gain: CGFloat) -> Path {
        var p = Path()
        let g = gain * half
        func y(_ v: Float) -> CGFloat { max(mid - half * 1.05, min(mid + half * 1.05, mid - CGFloat(v) * g)) }
        let columns = Int(plot.width)
        guard count > 1, start >= 0, start + count <= s.count else { return p }
        if count <= columns * 2 {
            let dx = plot.width / CGFloat(count - 1)
            p.move(to: CGPoint(x: plot.minX, y: y(s[start])))
            for i in 1..<count { p.addLine(to: CGPoint(x: plot.minX + CGFloat(i) * dx, y: y(s[start + i]))) }
        } else {
            for c in 0..<columns {
                let a = start + c * count / columns, b = max(a + 1, start + (c + 1) * count / columns)
                var lo = s[a], hi = s[a]
                for i in a..<b { lo = min(lo, s[i]); hi = max(hi, s[i]) }
                let x = plot.minX + CGFloat(c)
                if c == 0 { p.move(to: CGPoint(x: x, y: y(hi))) } else { p.addLine(to: CGPoint(x: x, y: y(hi))) }
                p.addLine(to: CGPoint(x: x, y: y(lo)))
            }
        }
        return p
    }

    private func drawGraticule(_ gc: GraphicsContext, _ r: CGRect) {
        let hw = max(Theme.hairlineWidth, 0.5)
        var grid = Path()
        for i in 0...10 {
            let x = r.minX + r.width * CGFloat(i) / 10
            grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY))
        }
        for j in 0...8 {
            let y = r.minY + r.height * CGFloat(j) / 8
            grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        gc.stroke(grid, with: .color(Theme.scopeGrid), lineWidth: hw)
        var axes = Path()
        for cy in [r.minY + r.height / 4, r.minY + r.height * 0.75] {
            axes.move(to: CGPoint(x: r.minX, y: cy)); axes.addLine(to: CGPoint(x: r.maxX, y: cy))
        }
        gc.stroke(axes, with: .color(Theme.textTertiary.opacity(0.6)), lineWidth: hw)
    }
}
