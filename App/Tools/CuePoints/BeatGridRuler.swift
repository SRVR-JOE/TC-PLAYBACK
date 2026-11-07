import SwiftUI

/// Draws a beat grid into the timeline canvas: a bars/beats strip (bar numbers, beat ticks,
/// labelled section bands) and faint bar lines through the lanes. Density follows the zoom so
/// the strip never clutters: bar labels thin out to every 2/4/8… bars, beat ticks appear only
/// when beats are at least 6 pt apart, subdivision ticks only when snapping to them and there's room.
enum BeatGridRuler {
    /// Strip height: one row for bars, two when there are sections to name.
    static func bandHeight(for grid: BeatGrid) -> CGFloat { grid.sections.isEmpty ? 16 : 30 }

    /// - Parameters:
    ///   - band: where the bars/beats strip goes (the timeline passes a strip at its bottom edge).
    ///   - lines: vertical extent for bar lines through the lanes (nil = none).
    ///   - origin: time at x = 0; `pps` points per second; `duration` caps the last section band.
    static func draw(_ gc: GraphicsContext, grid: BeatGrid, band: CGRect, lines: ClosedRange<CGFloat>?,
                     origin: TimeInterval, pps: CGFloat, duration: TimeInterval) {
        let w = band.width
        func x(_ t: TimeInterval) -> CGFloat { band.minX + CGFloat(t - origin) * pps }
        let tEnd = origin + Double(w / pps)

        gc.fill(Path(band), with: .color(Theme.surface))

        // Sections: alternating flat bands with the name at the left edge.
        let secs = grid.sortedSections
        for (i, s) in secs.enumerated() {
            let t0 = grid.barTime(s.startBar)
            let t1 = i + 1 < secs.count ? grid.barTime(secs[i + 1].startBar) : max(duration, t0)
            guard t1 > origin, t0 < tEnd else { continue }
            let r = CGRect(x: max(band.minX, x(t0)), y: band.minY, width: min(band.maxX, x(t1)) - max(band.minX, x(t0)), height: band.height)
            gc.fill(Path(r), with: .color(i % 2 == 0 ? Theme.surfaceRaised : Theme.surface))
            gc.fill(Path(CGRect(x: x(t0), y: band.minY, width: 1, height: band.height)), with: .color(Theme.textTertiary))
            let label = gc.resolve(Text(s.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary))
            gc.drawLayer { l in
                l.clip(to: Path(r.insetBy(dx: 1, dy: 0)))
                // Keep the name readable when the section starts off-screen.
                l.draw(label, at: CGPoint(x: max(x(t0), band.minX) + 4, y: band.minY + 1), anchor: .topLeading)
            }
        }
        gc.fill(Path(CGRect(x: band.minX, y: band.minY, width: w, height: 0.5)), with: .color(Theme.hairline))

        let ppb = CGFloat(grid.beatLength) * pps
        let bpb = max(1, grid.beatsPerBar)
        let ppBar = ppb * CGFloat(bpb)
        let every = [1, 2, 4, 8, 16, 32, 64, 128, 256].first(where: { CGFloat($0) * ppBar >= 34 }) ?? 512
        let labelY = band.maxY - 1
        let hasSectionLabels = !secs.isEmpty

        // Subdivision and beat ticks.
        if ppb >= 6 {
            let div = grid.snapMode == .quarter && ppb >= 48 ? 4 : (grid.snapMode == .half || grid.snapMode == .quarter) && ppb >= 24 ? 2 : 1
            let first = Int(floor(grid.beatPosition(at: origin))) - 1
            let last = Int(ceil(grid.beatPosition(at: tEnd))) + 1
            for n in first...last {
                for s in 0..<div {
                    let t = grid.firstBeat + (Double(n) + Double(s) / Double(div)) * grid.beatLength
                    let px = x(t)
                    guard px >= band.minX - 1, px <= band.maxX + 1 else { continue }
                    let onBar = s == 0 && ((n % bpb) + bpb) % bpb == 0
                    if onBar { continue }
                    let h: CGFloat = s == 0 ? 5 : 3
                    gc.fill(Path(CGRect(x: px, y: band.maxY - h, width: 1, height: h)), with: .color(Theme.textTertiary))
                }
            }
        }

        // Bars: tick, number, and a faint line through the lanes.
        let firstBar = Int(floor(grid.beatPosition(at: origin) / Double(bpb))) + 1
        let lastBar = Int(ceil(grid.beatPosition(at: tEnd) / Double(bpb))) + 1
        var bar = firstBar - (((firstBar - 1) % every) + every) % every
        while bar <= lastBar {
            let px = x(grid.barTime(bar))
            if px >= band.minX - 40, px <= band.maxX + 1 {
                if let lines, ppBar * CGFloat(every) >= 8 {
                    gc.fill(Path(CGRect(x: px, y: lines.lowerBound, width: 1, height: lines.upperBound - lines.lowerBound)),
                            with: .color(Theme.hairline.opacity(0.7)))
                }
                gc.fill(Path(CGRect(x: px, y: band.minY + (hasSectionLabels ? band.height / 2 : 0), width: 1,
                                    height: hasSectionLabels ? band.height / 2 : band.height)),
                        with: .color(Theme.textSecondary))
                let label = gc.resolve(Text("\(bar)").font(Theme.numeric(9)).foregroundStyle(Theme.textSecondary))
                gc.draw(label, at: CGPoint(x: px + 3, y: labelY), anchor: .bottomLeading)
            }
            bar += every
        }
    }
}
