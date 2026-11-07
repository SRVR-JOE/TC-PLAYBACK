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

/// Zoomable timeline: TC ruler, one lane per visible cue type, waveform (A1) and the playhead.
/// Drag a mark to move it (snaps to frames; selected marks move together), drag elsewhere to
/// scroll, pinch to zoom, tap a mark to select it, tap empty space to put the playhead there.
/// Shift-tap or long-press adds to the selection; with Select on (or Shift held) dragging empty
/// lane space draws a selection box. Marks in locked lanes can be selected but not dragged.
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
    /// Lanes top to bottom (visible cue types). nil = a single "Marks" lane holding every point.
    var lanes: [CuePointType]? = nil
    /// Resolved numbers/colours; built from `points` + `lanes` when not given.
    var index: CuePointIndex? = nil
    /// Multi-selection (always contains `selected` when that is set).
    var selection: Binding<Set<UUID>> = .constant([])
    /// Select mode: taps add to the selection and dragging empty lane space draws a box.
    var selectMode = false
    /// Double-tap a mark to rename it in place; nil turns that off.
    var onRename: ((CuePoint, String) -> Void)? = nil

    /// VIDEO hook: optional film-strip lane under the timeline, given the visible (origin, span).
    var videoLane: ((TimeInterval, TimeInterval) -> AnyView)? = nil
    @State private var spanAtPinch: TimeInterval?
    /// Left edge of the view in seconds.
    @State private var origin: TimeInterval = 0
    @State private var drag: DragState?
    @State private var gestureInfo: GestureInfo?
    @State private var marquee: CGRect?
    @State private var lastTap: (id: UUID, at: Date)?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocus: Bool

    private enum DragState {
        case marks(hit: CuePoint, group: [(CuePoint, TimeInterval)])
        case pan(TimeInterval)
        case marquee(base: Set<UUID>)
    }
    private struct GestureInfo { var start: Date; var additive: Bool; var before: Set<UUID>; var wasSelected: Bool }
    private let rulerH: CGFloat = 22
    private let gutter: CGFloat = 78

    /// Vertical layout shared by the gutter and the canvas.
    private struct Layout {
        var laneH: CGFloat, lanesTop: CGFloat, count: Int
        var waveTop: CGFloat { lanesTop + laneH * CGFloat(count) }
        func laneY(_ i: Int) -> CGFloat { lanesTop + laneH * CGFloat(i) }
        func lane(atY y: CGFloat) -> Int? {
            guard laneH > 0, y >= lanesTop, y < waveTop else { return nil }
            return Int((y - lanesTop) / laneH)
        }
    }

    private var laneTypes: [CuePointType] { lanes ?? [CuePointType(id: CuePointType.defaultID, name: "Marks", colorHex: CuePointColor.amber.rawValue)] }
    private var idx: CuePointIndex { index ?? CuePointIndex(points: points, types: lanes ?? CuePointType.defaults) }

    private func layout(height: CGFloat) -> Layout {
        let n = laneTypes.count
        guard n > 0 else { return Layout(laneH: 0, lanesTop: rulerH, count: 0) }
        // Lanes share what's left after a usable waveform, 16…26 pt each.
        let h = min(26, max(16, (height - rulerH - 44) / CGFloat(n)))
        return Layout(laneH: h, lanesTop: rulerH, count: n)
    }

    /// Lane of a point, or nil when its type's lane is hidden.
    private func lane(of p: CuePoint) -> Int? {
        if lanes == nil { return 0 }
        let id = idx.type(of: p).id
        return laneTypes.firstIndex(where: { $0.id == id })
    }
    private func isLocked(_ p: CuePoint) -> Bool { lane(of: p).map { laneTypes[$0].locked } ?? true }

    var body: some View {
        VStack(spacing: 0) { // VIDEO hook (wrapper)
        GeometryReader { geo in
            let L = layout(height: geo.size.height)
            HStack(spacing: 0) {
                laneHeaders(L)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                canvas(L)
            }
        }
        if let videoLane { Rectangle().fill(Theme.hairline).frame(height: 1); videoLane(origin, span) } // VIDEO hook
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
        .onChange(of: span) { _, _ in origin = clampOrigin(origin) }
    }

    /// Track headers, editor style: one per cue lane (colour chip + name) and the audio lane.
    private func laneHeaders(_ L: Layout) -> some View {
        VStack(spacing: 0) {
            Text("\(clock.rate.operatorLabel) fps").font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary).frame(height: rulerH - 1)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ForEach(laneTypes) { t in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(hexString: t.colorHex) ?? Theme.standby)
                        .frame(width: 4, height: max(8, L.laneH - 8))
                    Text(t.name).font(.system(size: L.laneH < 20 ? 10 : 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    if t.locked {
                        Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Theme.textTertiary)
                            .accessibilityLabel("Locked")
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: L.laneH)
                .accessibilityElement(children: .combine)
            }
            Rectangle().fill(Theme.hairline).frame(height: L.count > 0 ? 1 : 0)
            Text("A1").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(maxHeight: .infinity)
        }
        .frame(width: gutter)
        .background(Theme.surface)
    }

    private func canvas(_ L: Layout) -> some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let pps = w / span
            Canvas { gc, size in draw(gc, size, pps: pps, L) }
                .background(Theme.surfaceSunken)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: w, pps: pps, L))
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
                .overlay(alignment: .topLeading) { renameField(pps: pps, width: w, L) }
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

    /// Mark under a finger. In a lane: anywhere on its name flag, or within 22 pt of its line
    /// (finger-sized, so grabbing a mark never falls through to panning the timeline). Over the
    /// ruler or waveform: within 16 pt of any visible mark's line. Topmost (last drawn) wins.
    private func hitMark(at loc: CGPoint, pps: CGFloat, _ L: Layout) -> CuePoint? {
        let laneHit = L.lane(atY: loc.y)
        let candidates = points.filter { p in
            guard let l = lane(of: p) else { return false }
            return laneHit == nil || l == laneHit
        }
        if laneHit != nil {
            let fontSize: CGFloat = L.laneH < 20 ? 10 : 11
            if let onFlag = candidates.last(where: { p in
                let px = x(of: p.time, pps: pps)
                return loc.x >= px - 4 && loc.x <= px + flagWidth(p, fontSize: fontSize)
            }) { return onFlag }
        }
        let reach: CGFloat = laneHit == nil ? 16 : 22
        return candidates.min(by: { abs(x(of: $0.time, pps: pps) - loc.x) < abs(x(of: $1.time, pps: pps) - loc.x) })
            .flatMap { abs(x(of: $0.time, pps: pps) - loc.x) <= reach ? $0 : nil }
    }

    /// Width of a mark's name flag, matching `drawMarks`.
    private func flagWidth(_ p: CuePoint, fontSize: CGFloat) -> CGFloat {
        let label = "\(idx.number(of: p)) \(p.name)" as NSString
        let w = label.size(withAttributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .semibold)]).width
        return min(ceil(w) + 8, 208)
    }

    private func setSelection(_ s: Set<UUID>, primary: UUID?) {
        selection.wrappedValue = s
        selected = primary.flatMap { s.contains($0) ? $0 : nil } ?? points.first(where: { s.contains($0.id) })?.id
    }

    private func dragGesture(width: CGFloat, pps: CGFloat, _ L: Layout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil { begin(v, pps: pps, L) }
                switch drag {
                case .marks(_, let group):
                    guard abs(v.translation.width) > 3, !group.isEmpty else { return }
                    let fps = clock.rate.fps
                    let raw = (Double(v.translation.width / pps) * fps).rounded() / fps
                    let d = CuePointSelectionMath.clampedDelta(times: group.map(\.1), by: raw, duration: duration)
                    for (p, t0) in group { onMove(p, snap(t0 + d)) }
                case .pan(let o0):
                    guard abs(v.translation.width) > 3 else { return }
                    origin = clampOrigin(o0 - Double(v.translation.width / pps))
                case .marquee(let base):
                    let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                   width: abs(v.translation.width), height: abs(v.translation.height))
                    marquee = r
                    let t0 = time(atX: r.minX, pps: pps), t1 = time(atX: r.maxX, pps: pps)
                    let hits = points.filter { p in
                        guard let l = lane(of: p), p.time >= t0, p.time <= t1 else { return false }
                        let y0 = L.laneY(l)
                        return r.maxY >= y0 && r.minY <= y0 + L.laneH
                    }.map(\.id)
                    setSelection(base.union(hits), primary: selected)
                case nil: break
                }
            }
            .onEnded { v in
                let tap = abs(v.translation.width) <= 3 && abs(v.translation.height) <= 3
                let info = gestureInfo
                let long = tap && info.map { v.time.timeIntervalSince($0.start) >= 0.45 } ?? false
                if tap, let info {
                    switch drag {
                    case .marks(let m, _):
                        if long && !info.additive {
                            // Long-press: add to (or take out of) the selection made before.
                            setSelection(info.wasSelected ? info.before.subtracting([m.id]) : info.before.union([m.id]), primary: m.id)
                            Haptics.tick()
                        } else if info.additive && info.wasSelected {
                            setSelection(selection.wrappedValue.subtracting([m.id]), primary: nil)
                        } else if !info.additive {
                            setSelection([m.id], primary: m.id)
                            if let last = lastTap, last.id == m.id, v.time.timeIntervalSince(last.at) < 0.4, onRename != nil {
                                beginRename(m); lastTap = nil
                            } else {
                                lastTap = (m.id, v.time)
                            }
                        }
                    default:
                        if !info.additive { setSelection([], primary: nil) }
                        onSeek(min(max(0, time(atX: v.location.x, pps: pps)), duration))
                    }
                }
                drag = nil; gestureInfo = nil; marquee = nil
            }
    }

    // MARK: Rename in place

    private func beginRename(_ p: CuePoint) {
        renaming = p.id; renameText = p.name; renameFocus = true
    }

    private func endRename(save: Bool) {
        if save, let id = renaming, let p = points.first(where: { $0.id == id }) {
            let t = renameText.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t != p.name { onRename?(p, t) }
        }
        renaming = nil; renameFocus = false
    }

    @ViewBuilder private func renameField(pps: CGFloat, width: CGFloat, _ L: Layout) -> some View {
        if let id = renaming, let p = points.first(where: { $0.id == id }), let lane = lane(of: p) {
            let fieldW: CGFloat = 200
            let px = min(max(0, x(of: p.time, pps: pps)), max(0, width - fieldW))
            TextField("Name", text: $renameText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .focused($renameFocus)
                .submitLabel(.done)
                .onSubmit { endRename(save: true) }
                .onKeyPress(.escape) { endRename(save: false); return .handled }
                .padding(.horizontal, 6)
                .frame(width: fieldW, height: max(26, L.laneH + 4))
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.textSecondary, lineWidth: 1))
                .offset(x: px, y: L.laneY(lane) - 2)
                .onChange(of: renameFocus) { _, on in if !on { endRename(save: true) } }
        }
    }

    private func begin(_ v: DragGesture.Value, pps: CGFloat, _ L: Layout) {
        let shift = HardwareKeys.shift
        let additive = selectMode || shift
        let before = selection.wrappedValue
        if let m = hitMark(at: v.startLocation, pps: pps, L) {
            let was = before.contains(m.id)
            gestureInfo = GestureInfo(start: v.time, additive: additive, before: before, wasSelected: was)
            if !was { setSelection(additive ? before.union([m.id]) : [m.id], primary: m.id) } else { selected = m.id }
            let ids = selection.wrappedValue
            let group = points.filter { ids.contains($0.id) && !isLocked($0) }.map { ($0, $0.time) }
            drag = .marks(hit: m, group: isLocked(m) ? [] : group)
        } else {
            gestureInfo = GestureInfo(start: v.time, additive: additive, before: before, wasSelected: false)
            if additive, L.count > 0, v.startLocation.y >= L.lanesTop {
                drag = .marquee(base: shift ? before : [])
            } else {
                drag = .pan(origin)
            }
        }
    }

    // MARK: Drawing

    private func draw(_ gc: GraphicsContext, _ size: CGSize, pps: CGFloat, _ L: Layout) {
        let waveTop = L.waveTop, waveH = size.height - waveTop
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
        drawLanes(gc, size, L)

        // Waveform (mirrored peaks)
        if !peaks.isEmpty, waveH > 4 {
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

        drawMarks(gc, size, pps: pps, L)

        if let r = marquee {
            gc.fill(Path(r), with: .color(Theme.textPrimary.opacity(0.06)))
            gc.stroke(Path(r), with: .color(Theme.textSecondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        // Playhead
        let ph = x(of: playhead, pps: pps)
        gc.fill(Path(CGRect(x: ph - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.textPrimary))
        var tri = Path()
        tri.move(to: CGPoint(x: ph - 5, y: 0)); tri.addLine(to: CGPoint(x: ph + 5, y: 0)); tri.addLine(to: CGPoint(x: ph, y: 6))
        gc.fill(tri, with: .color(Theme.textPrimary))
    }

    /// Lane stripes (alternating shade) with hairlines between them.
    private func drawLanes(_ gc: GraphicsContext, _ size: CGSize, _ L: Layout) {
        for i in 0..<L.count {
            let y = L.laneY(i)
            gc.fill(Path(CGRect(x: 0, y: y, width: size.width, height: L.laneH)),
                    with: .color(Theme.surface.opacity(i.isMultiple(of: 2) ? 0.6 : 0.35)))
            gc.fill(Path(CGRect(x: 0, y: y + L.laneH - 0.5, width: size.width, height: 0.5)), with: .color(Theme.hairline))
        }
    }

    /// Each mark: a line from its lane down through the waveform, and a flag in its lane.
    private func drawMarks(_ gc: GraphicsContext, _ size: CGSize, pps: CGFloat, _ L: Layout) {
        let sel = selection.wrappedValue
        let fontSize: CGFloat = L.laneH < 20 ? 10 : 11
        for p in points {
            guard let lane = lane(of: p) else { continue }
            let px = x(of: p.time, pps: pps)
            guard px > -220, px < size.width + 4 else { continue }
            let color = Color(hexString: idx.colorHex(of: p)) ?? Theme.standby
            let on = sel.contains(p.id) || p.id == selected
            let top = L.laneY(lane)
            gc.fill(Path(CGRect(x: px - (on ? 1 : 0.5), y: top, width: on ? 2 : 1, height: size.height - top)),
                    with: .color(color.opacity(on ? 1 : 0.85)))
            let text = Text("\(idx.number(of: p)) \(p.name)").font(.system(size: fontSize, weight: .semibold)).foregroundStyle(Theme.background)
            let resolved = gc.resolve(text)
            let tw = min(resolved.measure(in: CGSize(width: 200, height: L.laneH)).width + 8, 208)
            let flag = CGRect(x: px, y: top + 1, width: tw, height: L.laneH - 2)
            gc.fill(Path(roundedRect: flag, cornerRadius: 2), with: .color(color))
            if on { gc.stroke(Path(roundedRect: flag.insetBy(dx: -1, dy: -1), cornerRadius: 3), with: .color(Theme.textPrimary), lineWidth: 1) }
            gc.drawLayer { l in
                l.clip(to: Path(flag))
                l.draw(resolved, at: CGPoint(x: px + 4, y: top + L.laneH / 2), anchor: .leading)
            }
        }
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
    /// Cue numbers and colours by type; nil = numbered by position, mark colour.
    var index: CuePointIndex? = nil

    @AppStorage("cuePoints.allowSpeakerDelay") private var allowSpeakerDelay = true
    private var trigger: CueTriggerClock { CueTriggerClock.shared }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isPlaying)) { _ in
            // While playing, show what's being heard (trigger clock); parked, the playhead.
            let playhead = isPlaying ? trigger.heardTime : self.playhead
            let current = points.last(where: { $0.time <= playhead + 0.0005 })
            let next = points.first(where: { $0.time > playhead + 0.0005 })
            let flashing = isPlaying && trigger.isFlashing()
            let flashColor = current.flatMap { Color(hexString: colorHex($0) ?? "") } ?? Theme.standby
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.map { "\(cueLabel($0)) \($0.name)" } ?? "Before first mark")
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
                        Text("Next \(cueLabel(next)) \(next.name)")
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
        // Triggers fire from the display-synced clock, on the frame where the mark is heard.
        .onAppear { syncMarks(); trigger.start(engine: .shared) }
        .onDisappear { trigger.stop() }
        .onChange(of: points.map { "\($0.id)\($0.time)\(colorHex($0) ?? "")" }) { _, _ in syncMarks() }
        .onChange(of: allowSpeakerDelay) { _, _ in syncMarks() }
        .accessibilityElement(children: .combine)
    }

    private func syncMarks() {
        trigger.compensateLatency = allowSpeakerDelay
        trigger.marks = points.sorted { $0.time < $1.time }.map { .init(id: $0.id, time: $0.time, colorHex: colorHex($0)) }
    }

    private func cueLabel(_ p: CuePoint) -> String {
        if let index { return index.number(of: p) }
        return String((points.firstIndex(where: { $0.id == p.id }) ?? 0) + 1)
    }
    private func colorHex(_ p: CuePoint) -> String? { index?.colorHex(of: p) ?? p.colorHex }
}
