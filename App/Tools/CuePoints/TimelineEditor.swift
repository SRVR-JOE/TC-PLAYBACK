import SwiftUI
import AVFoundation
import TCKit

/// High-resolution peaks for the timeline (the stored overview is too coarse to zoom into).
/// One value per bucket, 0…1, from the programme channel (the side without LTC).
enum TimelinePeaks {
    static let bucketsPerSecond = 100.0

    static func load(url: URL, channel: Int) async -> [Float] {
        await Task.detached(priority: .userInitiated) {
            guard let f = try? AVAudioFile(forReading: url) else { return [] }
            let fmt = f.processingFormat
            let per = max(1, Int(fmt.sampleRate / bucketsPerSecond))
            let chunk = AVAudioFrameCount(per * 512)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return [] }
            let ch = min(channel, Int(fmt.channelCount) - 1)
            var out: [Float] = []
            out.reserveCapacity(Int(Double(f.length) / Double(per)) + 1)
            var acc: Float = 0, count = 0
            while f.framePosition < f.length {
                if Task.isCancelled { return [] }
                do { try f.read(into: buf, frameCount: chunk) } catch { break }
                let n = Int(buf.frameLength)
                guard n > 0, let p = buf.floatChannelData?[ch] else { break }
                for i in 0..<n {
                    acc = max(acc, abs(p[i])); count += 1
                    if count == per { out.append(acc); acc = 0; count = 0 }
                }
            }
            if count > 0 { out.append(acc) }
            return out
        }.value
    }
}

/// Zoomable timeline: TC ruler, waveform, draggable marks and the playhead.
/// Drag a mark to move it (snaps to frames), drag elsewhere to scroll, pinch to zoom,
/// tap a mark to select it, tap empty space to put the playhead there.
struct TimelineEditor: View {
    var duration: TimeInterval
    var peaks: [Float]
    var points: [CuePoint]
    var clock: CuePointClock
    var playhead: TimeInterval
    var isPlaying: Bool
    @Binding var selected: UUID?
    var onSeek: (TimeInterval) -> Void
    var onMove: (CuePoint, TimeInterval) -> Void

    /// Visible span in seconds (zoom), owned by the parent so a zoom slider can drive it.
    @Binding var span: TimeInterval
    var beatGrid: BeatGrid? = nil // BEATGRID hook: bars/beats strip, bar lines, snap
    @State private var spanAtPinch: TimeInterval?
    /// Left edge of the view in seconds.
    @State private var origin: TimeInterval = 0
    @State private var drag: DragState?

    private enum DragState { case mark(CuePoint, TimeInterval), pan(TimeInterval), undecided }
    private let rulerH: CGFloat = 22, flagH: CGFloat = 24
    private let gutter: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            laneHeaders
            Rectangle().fill(Theme.hairline).frame(width: 1)
            canvas
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
        .onChange(of: span) { _, _ in origin = clampOrigin(origin) }
    }

    /// Track headers, editor style: marker lane and the audio lane.
    private var laneHeaders: some View {
        VStack(spacing: 0) {
            Text(clock.rate.operatorLabel).font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textTertiary).frame(height: rulerH)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("Marks").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(height: flagH)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("A1").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(maxHeight: .infinity)
        }
        .frame(width: gutter)
        .background(Theme.surface)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let pps = w / span
            Canvas { gc, size in draw(gc, size, pps: pps) }
                .background(Theme.surfaceSunken)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: w, pps: pps))
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            let base = spanAtPinch ?? span
                            if spanAtPinch == nil { spanAtPinch = span }
                            let centre = origin + span / 2
                            span = min(max(2, base / v.magnification), max(2, duration))
                            origin = clampOrigin(centre - span / 2)
                        }
                        .onEnded { _ in spanAtPinch = nil }
                )
                .onChange(of: playhead) { _, t in follow(t) }
                .onAppear { follow(playhead) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    private func clampOrigin(_ o: TimeInterval) -> TimeInterval { min(max(0, o), max(0, duration - span)) }

    /// While playing, keep the playhead at about a third of the width; when parked, only scroll
    /// if the playhead leaves the view.
    private func follow(_ t: TimeInterval) {
        guard drag == nil else { return }
        if isPlaying {
            if t < origin || t > origin + span * 0.6 { origin = clampOrigin(t - span * 0.33) }
        } else if t < origin || t > origin + span {
            origin = clampOrigin(t - span * 0.33)
        }
    }

    private func time(atX x: CGFloat, pps: CGFloat) -> TimeInterval { origin + Double(x / pps) }
    private func x(of t: TimeInterval, pps: CGFloat) -> CGFloat { CGFloat(t - origin) * pps }
    private func snap(_ t: TimeInterval) -> TimeInterval {
        let t = beatGrid?.snapped(t) ?? t // BEATGRID hook
        let f = clock.rate.fps
        return min(max(0, (t * f).rounded() / f), duration)
    }

    private func hitMark(atX px: CGFloat, pps: CGFloat) -> CuePoint? {
        points.min(by: { abs(x(of: $0.time, pps: pps) - px) < abs(x(of: $1.time, pps: pps) - px) })
            .flatMap { abs(x(of: $0.time, pps: pps) - px) <= 14 ? $0 : nil }
    }

    private func dragGesture(width: CGFloat, pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil {
                    if let m = hitMark(atX: v.startLocation.x, pps: pps) {
                        drag = .mark(m, m.time); selected = m.id
                    } else {
                        drag = .pan(origin)
                    }
                }
                switch drag {
                case .mark(let m, let t0):
                    guard abs(v.translation.width) > 3 else { return }
                    onMove(m, snap(t0 + Double(v.translation.width / pps)))
                case .pan(let o0):
                    guard abs(v.translation.width) > 3 else { return }
                    origin = clampOrigin(o0 - Double(v.translation.width / pps))
                default: break
                }
            }
            .onEnded { v in
                let tap = abs(v.translation.width) <= 3 && abs(v.translation.height) <= 3
                if tap {
                    if case .mark = drag {} else {
                        selected = nil
                        onSeek(min(max(0, time(atX: v.location.x, pps: pps)), duration))
                    }
                }
                drag = nil
            }
    }

    // MARK: Drawing

    private func draw(_ gc: GraphicsContext, _ size: CGSize, pps: CGFloat) {
        let waveTop = rulerH + flagH, waveH = size.height - waveTop
        // Ruler
        gc.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: rulerH)), with: .color(Theme.surface))
        let step = rulerStep(pps: pps)
        // Ticks on round timecode values (the start TC is rarely on a 15 s boundary).
        let startSec = clock.start.realSeconds
        var t = ((startSec + origin) / step).rounded(.down) * step - startSec
        while t <= origin + span + step {
            let px = x(of: t, pps: pps)
            gc.fill(Path(CGRect(x: px, y: rulerH - 7, width: 1, height: 7)), with: .color(Theme.textTertiary))
            gc.fill(Path(CGRect(x: px, y: rulerH, width: 1, height: size.height - rulerH)), with: .color(Theme.scopeGrid))
            let label = Text(rulerLabel(t, step: step)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            gc.draw(label, at: CGPoint(x: px + 3, y: 2), anchor: .topLeading)
            t += step
        }
        gc.fill(Path(CGRect(x: 0, y: rulerH - 0.5, width: size.width, height: 0.5)), with: .color(Theme.hairline))
        gc.fill(Path(CGRect(x: 0, y: rulerH, width: size.width, height: flagH)), with: .color(Theme.surface.opacity(0.6)))
        gc.fill(Path(CGRect(x: 0, y: rulerH + flagH, width: size.width, height: 0.5)), with: .color(Theme.hairline))

        // Waveform (mirrored peaks)
        if !peaks.isEmpty {
            let mid = waveTop + waveH / 2
            var path = Path()
            let bps = TimelinePeaks.bucketsPerSecond
            let cols = Int(size.width)
            for c in 0..<cols {
                let t0 = time(atX: CGFloat(c), pps: pps), t1 = time(atX: CGFloat(c + 1), pps: pps)
                let i0 = max(0, Int(t0 * bps)), i1 = min(peaks.count, max(i0 + 1, Int(t1 * bps)))
                guard i0 < peaks.count else { break }
                var pk: Float = 0
                for i in i0..<i1 { pk = max(pk, peaks[i]) }
                let h = CGFloat(min(1, pk)) * (waveH / 2 - 2)
                path.addRect(CGRect(x: CGFloat(c), y: mid - h, width: 1, height: max(0.5, h * 2)))
            }
            let played = x(of: playhead, pps: pps)
            gc.drawLayer { l in
                l.clip(to: Path(CGRect(x: 0, y: 0, width: max(0, played), height: size.height)))
                l.fill(path, with: .color(Theme.textSecondary))
            }
            gc.drawLayer { l in
                l.clip(to: Path(CGRect(x: max(0, played), y: 0, width: size.width, height: size.height)))
                l.fill(path, with: .color(Theme.textTertiary))
            }
        }

        // BEATGRID hook: bars/beats strip along the bottom edge, bar lines through the lanes.
        if let g = beatGrid {
            let h = BeatGridRuler.bandHeight(for: g)
            BeatGridRuler.draw(gc, grid: g, band: CGRect(x: 0, y: size.height - h, width: size.width, height: h),
                               lines: rulerH...(size.height - h), origin: origin, pps: pps, duration: duration)
        }

        // Marks
        for (i, p) in points.enumerated() {
            let px = x(of: p.time, pps: pps)
            guard px > -120, px < size.width + 4 else { continue }
            let color = Color(hexString: p.colorHex ?? "") ?? Theme.standby
            let sel = p.id == selected
            gc.fill(Path(CGRect(x: px - (sel ? 1 : 0.5), y: rulerH, width: sel ? 2 : 1, height: size.height - rulerH)),
                    with: .color(color.opacity(sel ? 1 : 0.85)))
            let text = Text("\(i + 1) \(p.name)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.background)
            let resolved = gc.resolve(text)
            let tw = min(resolved.measure(in: CGSize(width: 200, height: flagH)).width + 8, 208)
            let flag = CGRect(x: px, y: rulerH + 1, width: tw, height: flagH - 2)
            gc.fill(Path(roundedRect: flag, cornerRadius: 2), with: .color(color))
            if sel { gc.stroke(Path(roundedRect: flag.insetBy(dx: -1, dy: -1), cornerRadius: 3), with: .color(Theme.textPrimary), lineWidth: 1) }
            gc.drawLayer { l in
                l.clip(to: Path(flag))
                l.draw(resolved, at: CGPoint(x: px + 4, y: rulerH + flagH / 2), anchor: .leading)
            }
        }

        // Playhead
        let ph = x(of: playhead, pps: pps)
        gc.fill(Path(CGRect(x: ph - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.textPrimary))
        var tri = Path()
        tri.move(to: CGPoint(x: ph - 5, y: 0)); tri.addLine(to: CGPoint(x: ph + 5, y: 0)); tri.addLine(to: CGPoint(x: ph, y: 6))
        gc.fill(tri, with: .color(Theme.textPrimary))
    }

    private func rulerStep(pps: CGFloat) -> TimeInterval {
        let f = 1 / clock.rate.fps
        let steps: [TimeInterval] = [f, f * 5, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return steps.first(where: { CGFloat($0) * pps >= 80 }) ?? 600
    }

    private func rulerLabel(_ t: TimeInterval, step: TimeInterval) -> String {
        let tc = clock.timecode(at: t)
        return step < 1 ? tc.description : String(format: "%02d:%02d:%02d", tc.hours, tc.minutes, tc.seconds)
    }
}

/// Playback readout: flashes each mark as the playhead crosses it, counts down to the next.
struct TriggerReadout: View {
    var points: [CuePoint]
    var clock: CuePointClock
    var playhead: TimeInterval
    var isPlaying: Bool
    /// Fills its space with a big now/next display (editor monitor area).
    var large = false

    @State private var lastHit: (id: UUID, at: Date)?
    @State private var previous: TimeInterval = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { tl in
            let now = tl.date
            let current = points.last(where: { $0.time <= playhead + 0.0005 })
            let next = points.first(where: { $0.time > playhead + 0.0005 })
            let flashing = lastHit.map { now.timeIntervalSince($0.at) < 0.6 } ?? false
            let flashColor = current.flatMap { Color(hexString: $0.colorHex ?? "") } ?? Theme.standby
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.map { "\(index($0)) \($0.name)" } ?? "Before first mark")
                        .font(.system(size: large ? 46 : 22, weight: .semibold))
                        .foregroundStyle(flashing ? Theme.background : Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(current.map { clock.timecode(at: $0.time).description } ?? " ")
                        .font(Theme.numeric(large ? 18 : 12))
                        .foregroundStyle(flashing ? Theme.background.opacity(0.8) : Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if let next {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Next \(index(next)) \(next.name)")
                            .font(large ? .system(size: 20, weight: .medium) : Theme.label)
                            .foregroundStyle(flashing ? Theme.background : Theme.textSecondary)
                            .lineLimit(1)
                        Text(String(format: "%.1f s", max(0, next.time - playhead)))
                            .font(Theme.numeric(large ? 40 : 20, weight: .medium))
                            .foregroundStyle(flashing ? Theme.background : (next.time - playhead < 3 ? Theme.standby : Theme.textPrimary))
                    }
                }
            }
            .padding(.horizontal, large ? 24 : 14).padding(.vertical, large ? 20 : 10)
            .frame(maxWidth: .infinity, maxHeight: large ? .infinity : nil)
            .background(flashing ? flashColor : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .onChange(of: playhead) { old, new in
            defer { previous = new }
            guard isPlaying, new > old, new - old < 1 else { return }
            if let hit = points.last(where: { $0.time > old && $0.time <= new }) {
                lastHit = (hit.id, Date())
                Haptics.tick()
                CueFlash.fire(markHex: hit.colorHex)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func index(_ p: CuePoint) -> Int { (points.firstIndex(where: { $0.id == p.id }) ?? 0) + 1 }
}
