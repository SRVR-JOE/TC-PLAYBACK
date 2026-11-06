import SwiftUI
import QuartzCore

// Owned by the VISUALS agent. Implementation behind `StereoMeterView` (see VisualsAPI.swift).

/// Broadcast ballistics: instant attack, 20 dB/s release; peak hold 1.5 s then 20 dB/s decay.
final class MeterBallistics {
    static let floor: Float = -60
    static let release: Float = 20       // dB/s
    static let hold: Double = 1.5        // s
    private(set) var level: [Float] = [-90, -90]
    private(set) var peak: [Float] = [-90, -90]
    private var holdUntil: [Double] = [0, 0]
    private var last: Double = 0
    /// Locally latched clip for source metering (output clip comes from the engine).
    var sourceClip = [false, false]

    func update(_ linear: (Float, Float), now: Double) {
        let dt = Float(last == 0 ? 0 : min(0.25, now - last))
        last = now
        for (i, v) in [linear.0, linear.1].enumerated() {
            if v >= 0.999 { sourceClip[i] = true }
            let db = 20 * log10f(max(v, 1e-6))
            level[i] = db >= level[i] ? db : max(db, level[i] - Self.release * dt)
            if db >= peak[i] {
                peak[i] = db
                holdUntil[i] = now + Self.hold
            } else if now > holdUntil[i] {
                peak[i] = max(db, peak[i] - Self.release * dt)
            }
        }
    }
}

/// dBFS → 0…1 along the bar. Expanded at the top where operators read.
enum MeterScale {
    static let stops: [(db: Float, pos: CGFloat)] = [(-60, 0), (-40, 0.16), (-24, 0.37), (-18, 0.49),
                                                      (-12, 0.63), (-6, 0.80), (0, 1)]
    static let ticks: [Float] = [0, -6, -12, -18, -24, -40, -60]

    static func position(_ db: Float) -> CGFloat {
        if db <= stops[0].db { return 0 }
        for i in 1..<stops.count where db <= stops[i].db {
            let a = stops[i - 1], b = stops[i]
            return a.pos + CGFloat((db - a.db) / (b.db - a.db)) * (b.pos - a.pos)
        }
        return 1
    }

    static func label(_ db: Float) -> String { db == 0 ? "0" : VisualsFormat.minus + "\(Int(-db))" }
}

struct StereoMeterContent: View {
    var axis: StereoMeterView.Axis
    var showSource: Bool

    @Environment(\.visualsDataSource) private var data
    @State private var model = MeterBallistics()

    // Fixed layout metrics (pt).
    private let lampH: CGFloat = 6, lampGap: CGFloat = 6
    private let readoutH: CGFloat = 14, labelH: CGFloat = 14
    private let scaleW: CGFloat = 26

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { gc, size in
                let snap = data.snapshot()
                let peaks = showSource ? snap.sourcePeak : snap.outputPeak
                model.update((peaks.l, peaks.r), now: tl.date.timeIntervalSinceReferenceDate)
                let clip = showSource ? (model.sourceClip[0], model.sourceClip[1]) : snap.outputClip
                switch axis {
                case .vertical: drawVertical(gc, size, clip: [clip.0, clip.1])
                case .horizontal: drawHorizontal(gc, size, clip: [clip.0, clip.1])
                }
            }
        }
        .overlay(alignment: axis == .vertical ? .top : .trailing) {
            // Clip lamps: tap to reset.
            Color.clear
                .frame(width: axis == .vertical ? nil : 52, height: axis == .vertical ? lampH + lampGap + 8 : nil)
                .contentShape(Rectangle())
                .onTapGesture { resetClip() }
                .accessibilityElement()
                .accessibilityLabel("Clip indicators")
                .accessibilityHint("Resets the clip indicators")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { resetClip() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(showSource ? "Source meters" : "Output meters")
    }

    private func resetClip() {
        model.sourceClip = [false, false]
        data.resetClip()
    }

    // MARK: Vertical

    private func drawVertical(_ gc: GraphicsContext, _ size: CGSize, clip: [Bool]) {
        let barW = max(6, min(18, (size.width - scaleW) / 2 - 4))
        let totalW = barW * 2 + scaleW
        let x0 = (size.width - totalW) / 2
        let top = lampH + lampGap
        let bottom = size.height - readoutH - labelH - 4
        guard bottom - top > 20 else { return }
        let xs = [x0, x0 + barW + scaleW]

        for i in 0..<2 {
            let well = CGRect(x: xs[i], y: top, width: barW, height: bottom - top)
            drawBar(gc, well, level: model.level[i], peak: model.peak[i], vertical: true)
            drawClipLamp(gc, CGRect(x: xs[i], y: 0, width: barW, height: lampH), on: clip[i])
            let cx = xs[i] + barW / 2
            drawReadout(gc, at: CGPoint(x: cx, y: bottom + 4 + readoutH / 2), peak: model.peak[i])
            gc.draw(Text(i == 0 ? "L" : "R").font(Theme.caption).foregroundStyle(VisualsColor.secondary),
                    at: CGPoint(x: cx, y: bottom + 4 + readoutH + labelH / 2))
        }
        // Scale between the bars.
        let sx = x0 + barW
        for db in MeterScale.ticks {
            let y = bottom - MeterScale.position(db) * (bottom - top)
            var t = Path()
            t.move(to: CGPoint(x: sx + 1, y: y)); t.addLine(to: CGPoint(x: sx + 4, y: y))
            t.move(to: CGPoint(x: sx + scaleW - 4, y: y)); t.addLine(to: CGPoint(x: sx + scaleW - 1, y: y))
            gc.stroke(t, with: .color(VisualsColor.tertiary), lineWidth: 1)
            gc.draw(Text(MeterScale.label(db)).font(Theme.numeric(9, weight: .regular)).foregroundStyle(VisualsColor.secondary),
                    at: CGPoint(x: sx + scaleW / 2, y: y))
        }
    }

    // MARK: Horizontal

    private func drawHorizontal(_ gc: GraphicsContext, _ size: CGSize, clip: [Bool]) {
        let labelW: CGFloat = 14, readW: CGFloat = 40, clipW: CGFloat = 6
        let scaleH: CGFloat = 13
        let barH = max(5, min(12, (size.height - scaleH) / 2))
        let totalH = barH * 2 + scaleH
        let y0 = (size.height - totalH) / 2
        let left = labelW + 2
        let right = size.width - readW - clipW - 8
        guard right - left > 30 else { return }
        let ys = [y0, y0 + barH + scaleH]

        for i in 0..<2 {
            let well = CGRect(x: left, y: ys[i], width: right - left, height: barH)
            drawBar(gc, well, level: model.level[i], peak: model.peak[i], vertical: false)
            drawClipLamp(gc, CGRect(x: right + 4, y: ys[i], width: clipW, height: barH), on: clip[i])
            gc.draw(Text(i == 0 ? "L" : "R").font(Theme.caption).foregroundStyle(VisualsColor.secondary),
                    at: CGPoint(x: labelW / 2, y: ys[i] + barH / 2))
            let v = model.peak[i] < MeterBallistics.floor ? -Float.infinity : model.peak[i]
            gc.draw(Text(VisualsFormat.db(v)).font(Theme.numeric(11))
                        .foregroundStyle(v > -0.05 ? Theme.stop : VisualsColor.primary),
                    at: CGPoint(x: size.width, y: ys[i] + barH / 2), anchor: .trailing)
        }
        let sy = y0 + barH
        for db in MeterScale.ticks {
            let x = left + MeterScale.position(db) * (right - left)
            var t = Path()
            t.move(to: CGPoint(x: x, y: sy + 1)); t.addLine(to: CGPoint(x: x, y: sy + 3))
            t.move(to: CGPoint(x: x, y: sy + scaleH - 3)); t.addLine(to: CGPoint(x: x, y: sy + scaleH - 1))
            gc.stroke(t, with: .color(VisualsColor.tertiary), lineWidth: 1)
            gc.draw(Text(MeterScale.label(db)).font(Theme.numeric(8, weight: .regular)).foregroundStyle(VisualsColor.secondary),
                    at: CGPoint(x: x, y: sy + scaleH / 2))
        }
    }

    // MARK: Pieces

    private func zoneColor(_ db: Float) -> Color {
        db > -6 ? Theme.meterHigh : (db > -18 ? Theme.meterMid : Theme.meterLow)
    }

    /// Segmented bar: unlit segments faintly visible, lit portion in zone colours, fine gaps.
    private func drawBar(_ gc: GraphicsContext, _ well: CGRect, level: Float, peak: Float, vertical: Bool) {
        gc.fill(Path(well), with: .color(Theme.surfaceSunken))
        let len = vertical ? well.height : well.width
        func rect(from a: CGFloat, to b: CGFloat) -> CGRect {
            vertical ? CGRect(x: well.minX, y: well.maxY - b * len, width: well.width, height: (b - a) * len)
                     : CGRect(x: well.minX + a * len, y: well.minY, width: (b - a) * len, height: well.height)
        }
        let zones: [(Float, Float, Color)] = [(-60, -18, Theme.meterLow), (-18, -6, Theme.meterMid), (-6, 0, Theme.meterHigh)]
        let lit = MeterScale.position(level)
        for (lo, hi, c) in zones {
            let a = MeterScale.position(lo), b = MeterScale.position(hi)
            gc.fill(Path(rect(from: a, to: b)), with: .color(c.opacity(0.11)))
            if lit > a { gc.fill(Path(rect(from: a, to: min(lit, b))), with: .color(c)) }
        }
        // Segment gaps (1 pt every 3 pt), drawn in the well colour.
        var gaps = Path()
        var p: CGFloat = 3
        while p < len {
            if vertical { gaps.addRect(CGRect(x: well.minX, y: well.maxY - p, width: well.width, height: 1)) }
            else { gaps.addRect(CGRect(x: well.minX + p, y: well.minY, width: 1, height: well.height)) }
            p += 3
        }
        gc.fill(gaps, with: .color(Theme.surfaceSunken))
        // Peak-hold line.
        if peak > MeterBallistics.floor {
            let pp = MeterScale.position(peak) * len
            let r = vertical ? CGRect(x: well.minX, y: well.maxY - pp - 1, width: well.width, height: 2)
                             : CGRect(x: well.minX + pp - 1, y: well.minY, width: 2, height: well.height)
            gc.fill(Path(r), with: .color(zoneColor(peak)))
        }
        gc.stroke(Path(well.insetBy(dx: -0.5, dy: -0.5)), with: .color(Theme.hairline), lineWidth: 1)
    }

    private func drawClipLamp(_ gc: GraphicsContext, _ r: CGRect, on: Bool) {
        let p = Path(roundedRect: r, cornerRadius: 1.5)
        gc.fill(p, with: .color(on ? Theme.stop : Theme.lockOff))
        gc.stroke(p, with: .color(Color.black.opacity(0.35)), lineWidth: 0.5)
    }

    private func drawReadout(_ gc: GraphicsContext, at pt: CGPoint, peak: Float) {
        let v = peak < MeterBallistics.floor ? -Float.infinity : peak
        gc.draw(Text(VisualsFormat.db(v)).font(Theme.numeric(10)).foregroundStyle(peak > -0.05 ? Theme.stop : VisualsColor.primary),
                at: pt)
    }
}
