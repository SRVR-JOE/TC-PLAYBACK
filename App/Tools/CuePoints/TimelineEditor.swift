import SwiftUI
import UIKit
import TCKit

/// Zoomable timeline: TC ruler, one lane per visible cue type, the audio lane (A1) and the playhead.
/// Drag a mark to move it (snaps to frames; selected marks move together), drag elsewhere to
/// scroll, drag in the ruler to scrub, pinch to zoom around the fingers, tap a mark to select it,
/// tap empty space to put the playhead there (on a whole frame). Shift-tap or long-press adds to
/// the selection; with Select on (or Shift held) dragging empty lane space draws a selection box.
/// Marks in locked lanes can be selected but not dragged.
struct TimelineEditor: View {
    var duration: TimeInterval
    /// Multi-resolution waveform of the programme channel (nil = none yet).
    var waveform: TimelineWaveform?
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
    /// Which file channel the audio lane shows ("Left" / "Right"), under its A1 header.
    var audioChannel: String = ""
    /// Display-rate playhead while playing (the heard position); the 30 Hz `playhead` otherwise.
    var livePlayhead: (() -> TimeInterval)? = nil

    /// VIDEO hook: optional film-strip lane under the timeline, given the visible (origin, span).
    var videoLane: ((TimeInterval, TimeInterval) -> AnyView)? = nil

    /// Deepest zoom: two to three frames across the canvas (individual samples on iPad).
    static let minSpan: TimeInterval = 0.08
    /// While playing, the playhead rides at this fraction of the width and the timeline scrolls.
    private static let followLead = 0.33

    @Environment(\.displayScale) private var scale
    @State private var pinch: (span: TimeInterval, anchor: TimeInterval, x: CGFloat)?
    /// Left edge of the view in seconds.
    @State private var origin: TimeInterval = 0
    @State private var drag: DragState?
    @State private var gestureInfo: GestureInfo?
    @State private var marquee: CGRect?
    @State private var lastTap: (id: UUID, at: Date)?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var lastScrubFrame: Int?
    @FocusState private var renameFocus: Bool

    private enum DragState {
        case marks(hit: CuePoint, group: [(CuePoint, TimeInterval)])
        case pan(TimeInterval)
        case marquee(base: Set<UUID>)
        case scrub
    }
    private struct GestureInfo { var start: Date; var additive: Bool; var before: Set<UUID>; var wasSelected: Bool }
    private let rulerH: CGFloat = 30

    /// Vertical layout shared by the gutter and the canvas.
    private struct Layout {
        var laneH: CGFloat, lanesTop: CGFloat, count: Int, bandH: CGFloat
        /// Header column width (narrower on a phone).
        var gutter: CGFloat = 96
        var waveTop: CGFloat { lanesTop + laneH * CGFloat(count) }
        func laneY(_ i: Int) -> CGFloat { lanesTop + laneH * CGFloat(i) }
        func lane(atY y: CGFloat) -> Int? {
            guard laneH > 0, y >= lanesTop, y < waveTop else { return nil }
            return Int((y - lanesTop) / laneH)
        }
        var flagFont: CGFloat { laneH < 24 ? 11 : 12 }
    }

    /// Time ↔ x for one drawn frame. `px` snaps to device pixels so lines stay hairline-crisp.
    private struct Viewport {
        var origin: TimeInterval, pps: CGFloat, scale: CGFloat
        func x(_ t: TimeInterval) -> CGFloat { CGFloat(t - origin) * pps }
        func px(_ t: TimeInterval) -> CGFloat { (x(t) * scale).rounded() / scale }
        func time(atX x: CGFloat) -> TimeInterval { origin + Double(x / pps) }
    }

    private var laneTypes: [CuePointType] { lanes ?? [CuePointType(id: CuePointType.defaultID, name: "Marks", colorHex: CuePointColor.amber.rawValue)] }
    private var idx: CuePointIndex { index ?? CuePointIndex(points: points, types: lanes ?? CuePointType.defaults) }
    private var fps: Double { clock.rate.fps }
    private var maxSpan: TimeInterval { max(Self.minSpan, duration) }

    /// Height that fits the lanes at full size plus a comfortable audio lane.
    static func idealHeight(lanes n: Int, beatGrid: BeatGrid?) -> CGFloat {
        30 + CGFloat(max(1, n)) * 38 + 200 + (beatGrid.map(BeatGridRuler.bandHeight(for:)) ?? 0)
    }

    private func layout(height: CGFloat, width: CGFloat) -> Layout {
        var L = layout(height: height)
        L.gutter = width < 500 ? 80 : 96
        return L
    }

    private func layout(height: CGFloat) -> Layout {
        let n = laneTypes.count
        let band = beatGrid.map(BeatGridRuler.bandHeight(for:)) ?? 0
        let avail = height - rulerH - band
        guard n > 0 else { return Layout(laneH: 0, lanesTop: rulerH, count: 0, bandH: band) }
        // Lanes take up to about half the room (26…38 pt each); the audio lane gets the rest,
        // never less than 64 pt. The parent sizes the whole editor (`idealHeight`).
        var h = min(38, max(26, avail * 0.5 / CGFloat(n)))
        if avail - h * CGFloat(n) < 64 { h = max(18, (avail - 64) / CGFloat(n)) }
        return Layout(laneH: h.rounded(), lanesTop: rulerH, count: n, bandH: band)
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
            let L = layout(height: geo.size.height, width: geo.size.width)
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
        .onChange(of: span) { old, new in rezoom(from: old, to: new) }
        .onChange(of: isPlaying) { _, playing in if !playing { origin = followOrigin(playhead) } }
    }

    // MARK: Headers

    /// Track headers, editor style: colour bar, name and mark count per cue lane, then A1.
    private func laneHeaders(_ L: Layout) -> some View {
        let counts = points.reduce(into: [Int: Int]()) { c, p in if let l = lane(of: p) { c[l, default: 0] += 1 } }
        return VStack(spacing: 0) {
            HStack {
                Text("\(clock.rate.operatorLabel) fps").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: rulerH - 1)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ForEach(Array(laneTypes.enumerated()), id: \.element.id) { i, t in
                HStack(spacing: 0) {
                    Rectangle().fill(Color(hexString: t.colorHex) ?? Theme.standby).frame(width: 3)
                    HStack(spacing: 5) {
                        Text(t.name).font(.system(size: L.laneH < 24 ? 11 : 12, weight: .medium))
                            .foregroundStyle(t.locked ? Theme.textSecondary : Theme.textPrimary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        if t.locked {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                                .accessibilityLabel("Locked")
                        }
                        if L.gutter >= 90 {
                            Text("\(counts[i] ?? 0)").font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.leading, 7).padding(.trailing, 8)
                }
                .frame(height: L.laneH)
                .background(i.isMultiple(of: 2) ? Theme.surface : Theme.surfaceRaised)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth) }
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("A1").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                if !audioChannel.isEmpty {
                    Text(audioChannel).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.top, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
            if L.bandH > 0 {
                Text("Bars").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                    .frame(height: L.bandH)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth) }
            }
        }
        .frame(width: L.gutter)
        .background(Theme.surface)
    }

    // MARK: Canvas

    private var following: Bool { isPlaying && drag == nil && pinch == nil }

    private func canvas(_ L: Layout) -> some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let pps = w / span
            TimelineView(.animation(paused: !isPlaying)) { _ in
                let t = isPlaying ? (livePlayhead?() ?? playhead) : playhead
                let vp = Viewport(origin: following ? followOrigin(t) : origin, pps: pps, scale: scale)
                let _ = waveform?.version
                Canvas { gc, size in draw(gc, size, vp, playhead: t, L) }
            }
            .background(Theme.surfaceSunken)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(width: w, pps: pps, L))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if pinch == nil {
                            let x = v.startLocation.x
                            pinch = (span, origin + Double(x / pps), x)
                        }
                        guard let p = pinch else { return }
                        span = min(max(Self.minSpan, p.span / v.magnification), maxSpan)
                        // Keep the time that was under the fingers under the fingers.
                        origin = clampOrigin(p.anchor - Double(p.x / (w / span)))
                    }
                    .onEnded { _ in pinch = nil }
            )
            .overlay(alignment: .topLeading) { renameField(pps: pps, width: w, L) }
            .onChange(of: playhead) { _, t in follow(t) }
            .onAppear { follow(playhead) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    private func clampOrigin(_ o: TimeInterval) -> TimeInterval { min(max(0, o), max(0, duration - span)) }
    private func followOrigin(_ t: TimeInterval) -> TimeInterval { clampOrigin(t - span * Self.followLead) }

    /// Zoom from the slider / keys: keep the playhead still if it's in view, else the centre.
    private func rezoom(from old: TimeInterval, to new: TimeInterval) {
        guard pinch == nil, old > 0 else { origin = clampOrigin(origin); return }
        let anchor = playhead >= origin && playhead <= origin + old ? playhead : origin + old / 2
        origin = clampOrigin(anchor - (anchor - origin) * new / old)
    }

    /// While playing the timeline scrolls under a fixed playhead (drawn at display rate; this
    /// keeps the stored origin in step for hit-testing). Parked, it only scrolls if the
    /// playhead leaves the view.
    private func follow(_ t: TimeInterval) {
        guard drag == nil, pinch == nil else { return }
        if isPlaying {
            origin = followOrigin(t)
        } else if t < origin || t > origin + span {
            origin = followOrigin(t)
        }
    }

    private func time(atX x: CGFloat, pps: CGFloat) -> TimeInterval { origin + Double(x / pps) }
    private func x(of t: TimeInterval, pps: CGFloat) -> CGFloat { CGFloat(t - origin) * pps }
    private func snap(_ t: TimeInterval) -> TimeInterval {
        let t = beatGrid?.snapped(t) ?? t // BEATGRID hook
        return FrameGrid.snap(t, fps: fps, duration: duration)
    }
    /// Seek target for a tap or scrub at x: always a whole frame.
    private func seekTime(atX x: CGFloat, pps: CGFloat) -> TimeInterval {
        FrameGrid.snap(min(max(0, time(atX: x, pps: pps)), duration), fps: fps, duration: duration)
    }

    // MARK: Mark flags (shared by drawing and hit-testing)

    private struct Flag { var point: CuePoint; var lane: Int; var x: CGFloat; var rect: CGRect; var label: String; var call: Bool }

    /// Flag geometry for the visible marks: each flag runs right from its line, truncated so it
    /// stops short of the next mark in the same lane (never below the cue number).
    private func flags(_ vp: Viewport, width: CGFloat, _ L: Layout) -> [Flag] {
        let font = UIFont.systemFont(ofSize: L.flagFont, weight: .semibold)
        let byLane = Dictionary(grouping: points.compactMap { p in lane(of: p).map { (p, $0) } }, by: { $0.1 })
        var out: [Flag] = []
        let h = max(14, min(24, L.laneH - 10))
        for (l, items) in byLane {
            let sorted = items.map(\.0).sorted { $0.time < $1.time }
            for (i, p) in sorted.enumerated() {
                let px = vp.px(p.time)
                let nextX = i + 1 < sorted.count ? vp.px(sorted[i + 1].time) : .infinity
                guard px > -240, px < width + 4 else { continue }
                let call = !p.callNote.isEmpty
                let extra: CGFloat = 12 + (call ? 13 : 0) + (p.callCount > 1 ? 8 : 0)
                let room = min(220, nextX - px - 3) - extra
                let number = idx.number(of: p)
                let label = TextFit.fit(number: number, name: p.name, font: font, width: room)
                let w = ceil(TextFit.width(label, font: font)) + extra
                out.append(Flag(point: p, lane: l, x: px,
                                rect: CGRect(x: px, y: L.laneY(l) + (L.laneH - h) / 2, width: w, height: h),
                                label: label, call: call))
            }
        }
        return out.sorted { $0.point.time < $1.point.time }
    }

    /// Mark under a finger. In a lane: anywhere on its flag, or within 22 pt of its line
    /// (finger-sized, so grabbing a mark never falls through to panning the timeline). Over the
    /// audio lane: within 16 pt of any visible mark's line. Topmost (last drawn) wins.
    private func hitMark(at loc: CGPoint, pps: CGFloat, width: CGFloat, _ L: Layout) -> CuePoint? {
        let laneHit = L.lane(atY: loc.y)
        let vp = Viewport(origin: origin, pps: pps, scale: scale)
        let fl = flags(vp, width: width, L).filter { laneHit == nil || $0.lane == laneHit }
        if laneHit != nil, let onFlag = fl.last(where: { loc.x >= $0.x - 4 && loc.x <= $0.rect.maxX }) { return onFlag.point }
        let reach: CGFloat = laneHit == nil ? 16 : 22
        return fl.min(by: { abs($0.x - loc.x) < abs($1.x - loc.x) }).flatMap { abs($0.x - loc.x) <= reach ? $0.point : nil }
    }

    private func setSelection(_ s: Set<UUID>, primary: UUID?) {
        selection.wrappedValue = s
        selected = primary.flatMap { s.contains($0) ? $0 : nil } ?? points.first(where: { s.contains($0.id) })?.id
    }

    // MARK: Gestures

    private func dragGesture(width: CGFloat, pps: CGFloat, _ L: Layout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil { begin(v, pps: pps, width: width, L) }
                switch drag {
                case .marks(_, let group):
                    guard abs(v.translation.width) > 3, !group.isEmpty else { return }
                    let raw = Double(FrameGrid.nearestFrame(abs(Double(v.translation.width / pps)), fps: fps)) / fps
                        * (v.translation.width < 0 ? -1 : 1)
                    let d = CuePointSelectionMath.clampedDelta(times: group.map(\.1), by: raw, duration: duration)
                    for (p, t0) in group { onMove(p, snap(t0 + d)) }
                case .pan(let o0):
                    guard abs(v.translation.width) > 3 else { return }
                    origin = clampOrigin(o0 - Double(v.translation.width / pps))
                case .scrub:
                    let t = seekTime(atX: v.location.x, pps: pps)
                    let f = FrameGrid.nearestFrame(t, fps: fps)
                    if f != lastScrubFrame { lastScrubFrame = f; onSeek(t) }
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
                    case .scrub:
                        onSeek(seekTime(atX: v.location.x, pps: pps))
                    default:
                        if !info.additive { setSelection([], primary: nil) }
                        onSeek(seekTime(atX: v.location.x, pps: pps))
                    }
                }
                drag = nil; gestureInfo = nil; marquee = nil; lastScrubFrame = nil
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

    private func begin(_ v: DragGesture.Value, pps: CGFloat, width: CGFloat, _ L: Layout) {
        let shift = HardwareKeys.shift
        let additive = selectMode || shift
        let before = selection.wrappedValue
        if following { origin = followOrigin(livePlayhead?() ?? playhead) } // start from what's on screen
        gestureInfo = GestureInfo(start: v.time, additive: additive, before: before, wasSelected: false)
        if v.startLocation.y < rulerH {
            // The ruler scrubs the playhead, like any editor.
            drag = .scrub
            lastScrubFrame = nil
        } else if let m = hitMark(at: v.startLocation, pps: pps, width: width, L) {
            let was = before.contains(m.id)
            gestureInfo?.wasSelected = was
            if !was { setSelection(additive ? before.union([m.id]) : [m.id], primary: m.id) } else { selected = m.id }
            let ids = selection.wrappedValue
            let group = points.filter { ids.contains($0.id) && !isLocked($0) }.map { ($0, $0.time) }
            drag = .marks(hit: m, group: isLocked(m) ? [] : group)
        } else if additive, L.count > 0, v.startLocation.y >= L.lanesTop {
            drag = .marquee(base: shift ? before : [])
        } else {
            drag = .pan(origin)
        }
    }

    // MARK: Drawing

    private func draw(_ gc: GraphicsContext, _ size: CGSize, _ vp: Viewport, playhead: TimeInterval, _ L: Layout) {
        let hair = 1 / scale
        let lanesBottom = L.waveTop
        let waveRect = CGRect(x: 0, y: lanesBottom, width: size.width, height: max(0, size.height - lanesBottom - L.bandH))

        drawLanes(gc, size, L)
        drawGrid(gc, size, vp, top: rulerH, bottom: size.height - L.bandH)
        drawWave(gc, waveRect, vp, playhead: playhead)
        gc.fill(Path(CGRect(x: 0, y: lanesBottom, width: size.width, height: hair)), with: .color(Theme.hairline))

        // BEATGRID hook: bars/beats strip along the bottom edge, bar lines through the lanes.
        if let g = beatGrid {
            let h = L.bandH
            BeatGridRuler.draw(gc, grid: g, band: CGRect(x: 0, y: size.height - h, width: size.width, height: h),
                               lines: rulerH...(size.height - h), origin: vp.origin, pps: vp.pps, duration: duration)
        }

        drawMarks(gc, size, vp, L, waveRect: waveRect)

        if let r = marquee {
            gc.fill(Path(r), with: .color(Theme.textPrimary.opacity(0.06)))
            gc.stroke(Path(r), with: .color(Theme.textSecondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        drawRuler(gc, size, vp, avoid: playheadFlag(gc, size, vp, playhead: playhead)?.box)
        drawPlayhead(gc, size, vp, playhead: playhead)
    }

    /// Lane stripes (alternating shade) with hairlines between them.
    private func drawLanes(_ gc: GraphicsContext, _ size: CGSize, _ L: Layout) {
        let hair = 1 / scale
        for i in 0..<L.count {
            let y = L.laneY(i)
            gc.fill(Path(CGRect(x: 0, y: y, width: size.width, height: L.laneH)),
                    with: .color(i.isMultiple(of: 2) ? Theme.surface : Theme.surfaceRaised))
            gc.fill(Path(CGRect(x: 0, y: y + L.laneH - hair, width: size.width, height: hair)), with: .color(Theme.hairline))
        }
    }

    // MARK: Ruler

    /// What the ruler draws at the current zoom: tick spacing in TC seconds, or (zoomed in past
    /// one labelled second per ~96 pt) in frames with frame numbers.
    struct RulerPlan: Equatable {
        enum Unit: Equatable { case seconds, frames }
        var unit: Unit
        /// Labelled (full TC) step: seconds, or 1 s when `unit == .frames`.
        var majorSeconds: Int
        /// Tick steps in the unit (seconds or frames); 0 = none.
        var midStep: Int
        var minorStep: Int
        /// Frames between frame-number labels (frames unit only; 0 = none).
        var frameLabelStep: Int

        static let labelSpacing: CGFloat = 96

        /// - Parameters: `secondWidth` = points per TC second; `nominalFPS` = frames per TC second.
        static func make(secondWidth secW: CGFloat, nominalFPS nom: Int) -> RulerPlan {
            let frameW = secW / CGFloat(nom)
            if secW >= labelSpacing {
                let divs = (1...nom).filter { nom % $0 == 0 }
                let minor = divs.first { CGFloat($0) * frameW >= 6 } ?? nom
                let label = divs.first { CGFloat($0) * frameW >= 26 } ?? nom
                let mid = divs.first { CGFloat($0) * frameW >= 14 && $0 % minor == 0 } ?? nom
                return RulerPlan(unit: .frames, majorSeconds: 1, midStep: mid == nom ? 0 : mid,
                                 minorStep: minor == nom ? 0 : minor, frameLabelStep: label == nom ? 0 : label)
            }
            let majors = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
            let major = majors.first { CGFloat($0) * secW >= labelSpacing } ?? 14_400
            let subs = majors.filter { $0 < major && major % $0 == 0 }
            let minor = subs.first { CGFloat($0) * secW >= 7 } ?? 0
            let mid = subs.last { $0 % max(1, minor) == 0 && $0 > minor && CGFloat($0) * secW >= 20 } ?? 0
            return RulerPlan(unit: .seconds, majorSeconds: major, midStep: mid, minorStep: minor, frameLabelStep: 0)
        }
    }

    /// Track time of the first frame of TC second `s` (seconds since 00:00:00:00).
    private func trackTime(ofTCSecond s: Int) -> TimeInterval {
        let h = (s / 3600) % 24, m = (s / 60) % 60, sec = s % 60
        let dropped = clock.rate.isDropFrame && sec == 0 && m % 10 != 0
        let f = Timecode(hours: h, minutes: m, seconds: sec, frames: dropped ? 2 : 0, rate: clock.rate).frameNumber
        return Double(f - clock.start.frameNumber) / fps
    }

    private func tcSecond(at t: TimeInterval) -> Int {
        let tc = FrameGrid.timecode(at: max(0, t), start: clock.start)
        return tc.hours * 3600 + tc.minutes * 60 + tc.seconds
    }

    private var rulerFont: Font { .system(size: 11, weight: .regular).monospacedDigit() }

    private func drawRuler(_ gc: GraphicsContext, _ size: CGSize, _ vp: Viewport, avoid: CGRect?) {
        let hair = 1 / scale
        gc.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: rulerH)), with: .color(Theme.surface))
        let nom = clock.rate.nominalFPS
        let secW = vp.pps * CGFloat(nom) / CGFloat(fps)
        let plan = RulerPlan.make(secondWidth: secW, nominalFPS: nom)
        let t0 = vp.origin, t1 = vp.time(atX: size.width)
        let base = rulerH
        func tick(_ t: TimeInterval, _ h: CGFloat, _ c: Color) {
            gc.fill(Path(CGRect(x: vp.px(t), y: base - h, width: hair * 2, height: h)), with: .color(c))
        }
        var labels: [(String, CGFloat, Color)] = []

        switch plan.unit {
        case .frames:
            let n0 = max(0, FrameGrid.frame(containing: t0, fps: fps) - 1)
            let n1 = FrameGrid.frame(containing: t1, fps: fps) + 1
            // Frames wide enough to read as cells get a faint alternate shade.
            if vp.pps / CGFloat(fps) >= 40, n1 >= n0 {
                var cells = Path()
                for n in n0...n1 where n % 2 == 1 {
                    let a = vp.px(FrameGrid.time(ofFrame: n, fps: fps)), b = vp.px(FrameGrid.time(ofFrame: n + 1, fps: fps))
                    cells.addRect(CGRect(x: a, y: 0, width: b - a, height: base))
                }
                gc.fill(cells, with: .color(Theme.surfaceRaised))
            }
            if n1 >= n0 {
                for n in n0...n1 {
                    let tc = FrameGrid.timecode(at: FrameGrid.time(ofFrame: n, fps: fps), start: clock.start)
                    let t = FrameGrid.time(ofFrame: n, fps: fps)
                    let first = tc.frames == 0 || (clock.rate.isDropFrame && tc.seconds == 0 && tc.frames == 2 && tc.minutes % 10 != 0)
                    if first {
                        tick(t, 12, Theme.textSecondary)
                        labels.append((tc.description, vp.px(t), Theme.textSecondary))
                    } else if plan.frameLabelStep > 0, tc.frames % plan.frameLabelStep == 0 {
                        tick(t, 7, Theme.textTertiary)
                        labels.append((String(format: "%02d", tc.frames), vp.px(t), Theme.textTertiary))
                    } else if plan.midStep > 0, tc.frames % plan.midStep == 0 {
                        tick(t, 6, Theme.textTertiary)
                    } else if plan.minorStep > 0, tc.frames % plan.minorStep == 0 {
                        tick(t, 3.5, Theme.textTertiary)
                    }
                }
            }
        case .seconds:
            let step = plan.minorStep > 0 ? plan.minorStep : (plan.midStep > 0 ? plan.midStep : plan.majorSeconds)
            var s = tcSecond(at: t0)
            s -= s % step
            let end = tcSecond(at: t1) + step
            while s <= end {
                let t = trackTime(ofTCSecond: s)
                if s % plan.majorSeconds == 0 {
                    tick(t, 12, Theme.textSecondary)
                    let tc = FrameGrid.timecode(at: max(0, t), start: clock.start)
                    labels.append((tc.description, vp.px(t), Theme.textSecondary))
                } else if plan.midStep > 0, s % plan.midStep == 0 {
                    tick(t, 6, Theme.textTertiary)
                } else {
                    tick(t, 3.5, Theme.textTertiary)
                }
                s += step
            }
        }

        // Labels sit just right of their tick. Zoomed in to frames, the left edge carries the
        // full timecode when no whole second is near, so the ruler is never just frame numbers.
        var occupied: [ClosedRange<CGFloat>] = []
        if let avoid { occupied.append((avoid.minX - 4)...(avoid.maxX + 4)) }
        let hidden = { (x: CGFloat) in avoid.map { x + 4 >= $0.minX - 90 && x + 4 <= $0.maxX + 4 } ?? false }
        let pinnedFree = avoid.map { $0.minX > 110 } ?? true
        if plan.unit == .frames, pinnedFree,
           !labels.contains(where: { $0.0.count > 2 && $0.1 >= -4 && $0.1 < 110 && !hidden($0.1) }) {
            let tc = FrameGrid.timecode(at: max(0, t0), start: clock.start).description
            let text = gc.resolve(Text(tc).font(rulerFont).foregroundStyle(Theme.textSecondary))
            let w = text.measure(in: CGSize(width: 200, height: 20)).width
            gc.draw(text, at: CGPoint(x: 6, y: 4), anchor: .topLeading)
            occupied.append(0...(w + 14))
        }
        for (s, x, c) in labels {
            let text = gc.resolve(Text(s).font(rulerFont).foregroundStyle(c))
            let w = text.measure(in: CGSize(width: 200, height: 20)).width
            let r = (x + 4)...(x + 4 + w)
            guard x + 4 + w > 0, !occupied.contains(where: { $0.overlaps(r) }) else { continue }
            gc.draw(text, at: CGPoint(x: x + 4, y: 4), anchor: .topLeading)
            occupied.append((x + 2)...(x + 8 + w))
        }
        gc.fill(Path(CGRect(x: 0, y: base - hair, width: size.width, height: hair)), with: .color(Theme.hairline))
    }

    /// Faint vertical grid through the lanes and audio: every labelled second (or major step),
    /// and every frame boundary once frames are at least 10 pt wide.
    private func drawGrid(_ gc: GraphicsContext, _ size: CGSize, _ vp: Viewport, top: CGFloat, bottom: CGFloat) {
        let hair = 1 / scale
        let nom = clock.rate.nominalFPS
        let secW = vp.pps * CGFloat(nom) / CGFloat(fps)
        let plan = RulerPlan.make(secondWidth: secW, nominalFPS: nom)
        let t0 = vp.origin, t1 = vp.time(atX: size.width)
        var major = Path(), minor = Path()
        if plan.unit == .frames {
            let frameW = vp.pps / CGFloat(fps)
            let n0 = max(0, FrameGrid.frame(containing: t0, fps: fps) - 1), n1 = FrameGrid.frame(containing: t1, fps: fps) + 1
            if n1 >= n0 {
                for n in n0...n1 {
                    let t = FrameGrid.time(ofFrame: n, fps: fps)
                    let tc = FrameGrid.timecode(at: t, start: clock.start)
                    let r = CGRect(x: vp.px(t), y: top, width: hair, height: bottom - top)
                    if tc.frames == 0 { major.addRect(r) } else if frameW >= 10 { minor.addRect(r) }
                }
            }
        } else {
            var s = tcSecond(at: t0)
            s -= s % plan.majorSeconds
            let end = tcSecond(at: t1) + plan.majorSeconds
            while s <= end {
                major.addRect(CGRect(x: vp.px(trackTime(ofTCSecond: s)), y: top, width: hair, height: bottom - top))
                s += plan.majorSeconds
            }
        }
        gc.fill(minor, with: .color(Theme.scopeGrid.opacity(0.7)))
        gc.fill(major, with: .color(Theme.hairline))
    }

    // MARK: Waveform

    /// Programme waveform from the coarsest data with at least one point per device pixel:
    /// a filled min/max envelope, or, once samples are wider than a pixel, the sample curve.
    private func drawWave(_ gc: GraphicsContext, _ rect: CGRect, _ vp: Viewport, playhead: TimeInterval) {
        guard rect.height > 8 else { return }
        let hair = 1 / scale
        let mid = (rect.midY * scale).rounded() / scale
        gc.fill(Path(CGRect(x: 0, y: mid, width: rect.width, height: hair)), with: .color(Theme.hairline))
        guard let wf = waveform, !wf.levels.isEmpty else {
            gc.draw(Text("Reading audio\u{2026}").font(Theme.caption).foregroundStyle(Theme.textTertiary),
                    at: CGPoint(x: 10, y: rect.minY + 8), anchor: .topLeading)
            return
        }
        // Normalised for display (loudest peak near the lane edge), at most +12 dB.
        let gain = wf.peak > 0.001 ? min(4, 0.94 / wf.peak) : 1
        let half = rect.height / 2 - 4
        func y(_ v: Float) -> CGFloat { mid - CGFloat(max(-1, min(1, v * gain))) * half }
        let shape = WaveShape.make(wf, vp: (vp.origin, vp.pps, vp.scale), width: rect.width, duration: duration)

        let played = vp.x(playhead)
        let playedColor = Theme.scopeTrace.opacity(0.92), upcoming = Theme.textSecondary
        func paint(_ path: Path, stroke: Bool) {
            for (clipX, clipW, color) in [(CGFloat(0), max(0, played), playedColor),
                                          (max(0, played), rect.width, upcoming)] where clipW > 0 {
                gc.drawLayer { l in
                    l.clip(to: Path(CGRect(x: clipX, y: rect.minY, width: clipW, height: rect.height)))
                    if stroke { l.stroke(path, with: .color(color), lineWidth: 1.25) } else { l.fill(path, with: .color(color)) }
                }
            }
        }
        switch shape {
        case .envelope(let x0, let step, let lo, let hi):
            guard !hi.isEmpty else { return }
            var p = Path()
            let minH = hair
            p.move(to: CGPoint(x: x0, y: min(y(hi[0]), mid - minH / 2)))
            for i in 1..<hi.count { p.addLine(to: CGPoint(x: x0 + CGFloat(i) * step, y: min(y(hi[i]), y(lo[i]) - minH))) }
            for i in stride(from: lo.count - 1, through: 0, by: -1) {
                p.addLine(to: CGPoint(x: x0 + CGFloat(i) * step, y: max(y(lo[i]), y(hi[i]) + minH)))
            }
            p.closeSubpath()
            paint(p, stroke: false)
        case .samples(let pts, let dots):
            guard pts.count > 1 else { return }
            var p = Path()
            p.move(to: CGPoint(x: pts[0].x, y: y(pts[0].v)))
            for s in pts.dropFirst() { p.addLine(to: CGPoint(x: s.x, y: y(s.v))) }
            paint(p, stroke: true)
            if dots {
                var d = Path()
                for s in pts { d.addEllipse(in: CGRect(x: s.x - 1.75, y: y(s.v) - 1.75, width: 3.5, height: 3.5)) }
                paint(d, stroke: false)
            }
        case .loading:
            break
        }
    }

    // MARK: Marks

    /// Each mark: a line on its frame from its lane down through the audio, and a flag in its lane.
    private func drawMarks(_ gc: GraphicsContext, _ size: CGSize, _ vp: Viewport, _ L: Layout, waveRect: CGRect) {
        let sel = selection.wrappedValue
        let hair = 1 / scale
        for f in flags(vp, width: size.width, L) {
            let p = f.point
            let color = Color(hexString: idx.colorHex(of: p)) ?? Theme.standby
            let on = sel.contains(p.id) || p.id == selected
            let top = L.laneY(f.lane)
            let lineW: CGFloat = on ? 2 : 1
            // Solid through the lanes, lighter over the waveform so it stays readable.
            gc.fill(Path(CGRect(x: f.x, y: top, width: lineW, height: waveRect.minY - top)), with: .color(color))
            gc.fill(Path(CGRect(x: f.x, y: waveRect.minY, width: lineW, height: size.height - waveRect.minY)),
                    with: .color(color.opacity(on ? 0.9 : 0.55)))
            let flag = f.rect
            gc.fill(Path(roundedRect: flag, cornerRadius: 2), with: .color(color))
            if on {
                gc.stroke(Path(roundedRect: flag.insetBy(dx: -2, dy: -2), cornerRadius: 3.5),
                          with: .color(Theme.textPrimary), lineWidth: 1.5)
            }
            let ink = TextFit.ink(on: idx.colorHex(of: p))
            let text = gc.resolve(Text(f.label).font(.system(size: L.flagFont, weight: .semibold)).foregroundStyle(ink))
            gc.drawLayer { l in
                l.clip(to: Path(flag))
                l.draw(text, at: CGPoint(x: flag.minX + 6, y: flag.midY), anchor: .leading)
                if f.call {
                    // Speaker glyph for a call; stacked calls add a small count after it.
                    let stack = p.callCount
                    var glyph = gc.resolve(Image(systemName: "speaker.wave.1.fill"))
                    glyph.shading = .color(ink.opacity(0.75))
                    let gx = flag.maxX - (stack > 1 ? 23 : 15)
                    l.draw(glyph, in: CGRect(x: gx, y: flag.midY - 4.5, width: 9, height: 9))
                    if stack > 1 {
                        let n = gc.resolve(Text("\(min(stack, 9))").font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(ink.opacity(0.75)))
                        l.draw(n, at: CGPoint(x: gx + 11, y: flag.midY), anchor: .leading)
                    }
                }
            }
            _ = hair
        }
    }

    // MARK: Playhead

    /// A crisp line with its timecode in a flag at the top of the ruler.
    private func playheadFlag(_ gc: GraphicsContext, _ size: CGSize, _ vp: Viewport,
                              playhead: TimeInterval) -> (box: CGRect, text: GraphicsContext.ResolvedText, x: CGFloat)? {
        let x = vp.px(playhead)
        guard x > -120, x < size.width + 120 else { return nil }
        let text = gc.resolve(Text(clock.label(at: playhead)).font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.surfaceSunken))
        let ts = text.measure(in: CGSize(width: 200, height: 20))
        let w = ceil(ts.width) + 10, h: CGFloat = 18
        let fx = min(max(0, x - w / 2), max(0, size.width - w))
        return (CGRect(x: fx, y: 3, width: w, height: h), text, x)
    }

    private func drawPlayhead(_ gc: GraphicsContext, _ size: CGSize, _ vp: Viewport, playhead: TimeInterval) {
        guard let (box, text, x) = playheadFlag(gc, size, vp, playhead: playhead) else { return }
        let ink = Theme.textPrimary
        gc.fill(Path(CGRect(x: x - 0.5, y: rulerH - 6, width: 1, height: size.height - rulerH + 6)), with: .color(ink))
        gc.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(ink))
        var nib = Path()
        nib.move(to: CGPoint(x: x - 4, y: box.maxY)); nib.addLine(to: CGPoint(x: x + 4, y: box.maxY))
        nib.addLine(to: CGPoint(x: x, y: box.maxY + 4)); nib.closeSubpath()
        if x >= box.minX + 3, x <= box.maxX - 3 { gc.fill(nib, with: .color(ink)) }
        gc.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }
}

/// What the audio lane draws for one frame of the canvas.
enum WaveShape {
    /// Min/max per device-pixel column starting at `x0`, `step` points apart.
    case envelope(x0: CGFloat, step: CGFloat, lo: [Float], hi: [Float])
    /// Individual samples (sample spacing wider than a pixel); `dots` once they're ≥ 7 pt apart.
    case samples([(x: CGFloat, v: Float)], dots: Bool)
    /// Deep zoom, samples still being read.
    case loading

    /// Picks the data for the zoom: never a level coarser than one point per device pixel.
    @MainActor
    static func make(_ wf: TimelineWaveform, vp: (origin: TimeInterval, pps: CGFloat, scale: CGFloat), width: CGFloat,
                     duration: TimeInterval) -> WaveShape {
        let pxPerSec = Double(vp.pps * vp.scale)
        let cols = max(1, Int((width * vp.scale).rounded(.up)))
        let colDur = 1 / pxPerSec
        let step = 1 / vp.scale
        let end = wf.length > 0 ? min(duration, Double(wf.length) / wf.sampleRate) : duration
        if let li = WaveformPyramid.level(forPixelsPerSecond: pxPerSec, in: wf.levels) {
            let l = wf.levels[li]
            var lo: [Float] = [], hi: [Float] = []
            lo.reserveCapacity(cols); hi.reserveCapacity(cols)
            var x0: CGFloat?
            for c in 0..<cols {
                let t0 = vp.origin + Double(c) * colDur
                guard t0 + colDur > 0, t0 < end else { if x0 != nil && t0 >= end { break } else { continue } }
                let i0 = max(0, Int((t0 * l.perSecond).rounded(.down)))
                let i1 = min(l.count, max(i0 + 1, Int(((t0 + colDur) * l.perSecond).rounded(.down))))
                guard i0 < l.count else { break }
                var a = l.mins[i0], b = l.maxs[i0]
                if i1 > i0 + 1 { for i in (i0 + 1)..<i1 { a = min(a, l.mins[i]); b = max(b, l.maxs[i]) } }
                if x0 == nil { x0 = CGFloat(c) * step }
                lo.append(a); hi.append(b)
            }
            return .envelope(x0: x0 ?? 0, step: step, lo: lo, hi: hi)
        }
        // Finer than the pyramid: read the samples under the view.
        let sr = wf.sampleRate
        let t0 = max(0, vp.origin), t1 = min(end, vp.origin + Double(width / vp.pps))
        guard t1 > t0 else { return .envelope(x0: 0, step: step, lo: [], hi: []) }
        let s0 = max(0, Int((t0 * sr).rounded(.down)) - 2)
        let s1 = min(wf.length > 0 ? wf.length : Int(end * sr), Int((t1 * sr).rounded(.up)) + 2)
        guard s1 > s0, let samples = wf.samples(from: s0, count: s1 - s0) else { return .loading }
        let samplesPerPx = sr / pxPerSec
        if samplesPerPx >= 2 {
            var lo: [Float] = [], hi: [Float] = []
            var x0: CGFloat?
            for c in 0..<cols {
                let ta = vp.origin + Double(c) * colDur
                let a = Int((ta * sr).rounded(.down)) - s0, b = Int(((ta + colDur) * sr).rounded(.down)) - s0
                guard b > 0 else { continue }
                guard a < samples.count else { break }
                let lo0 = max(0, a), hi0 = min(samples.count, max(lo0 + 1, b))
                var mn = samples[lo0], mx = samples[lo0]
                for i in lo0..<hi0 { mn = min(mn, samples[i]); mx = max(mx, samples[i]) }
                if x0 == nil { x0 = CGFloat(c) * step }
                lo.append(mn); hi.append(mx)
            }
            return .envelope(x0: x0 ?? 0, step: step, lo: lo, hi: hi)
        }
        let ptsPerSample = vp.pps / CGFloat(sr)
        let pts = samples.enumerated().map { i, v in (x: CGFloat(Double(s0 + i) / sr - vp.origin) * vp.pps, v: v) }
        return .samples(pts, dots: ptsPerSample >= 7)
    }
}

/// Label fitting and ink for mark flags (main thread; widths cached per font size and string).
enum TextFit {
    nonisolated(unsafe) private static var cache: [String: CGFloat] = [:]

    static func width(_ s: String, font: UIFont) -> CGFloat {
        let key = "\(font.pointSize)|\(s)"
        if let w = cache[key] { return w }
        if cache.count > 4000 { cache.removeAll() }
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        cache[key] = w
        return w
    }

    /// "12 Chorus drop", shortened with an ellipsis to fit `width`; the cue number always stays.
    static func fit(number: String, name: String, font: UIFont, width maxWidth: CGFloat) -> String {
        let full = name.isEmpty ? number : "\(number) \(name)"
        if width(full, font: font) <= maxWidth || name.isEmpty { return full }
        var chars = Array(name)
        while !chars.isEmpty {
            chars.removeLast()
            let s = "\(number) \(String(chars).trimmingCharacters(in: .whitespaces))\u{2026}"
            if width(s, font: font) <= maxWidth { return chars.count < 2 ? number : s }
        }
        return number
    }

    /// Dark or light text, whichever reads on the flag colour.
    static func ink(on hex: String?) -> Color {
        let s = (hex ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return Color(hex: 0x111316) }
        func lin(_ c: UInt32) -> Double {
            let x = Double(c) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin((v >> 16) & 0xFF) + 0.7152 * lin((v >> 8) & 0xFF) + 0.0722 * lin(v & 0xFF)
        return l > 0.2 ? Color(hex: 0x111316) : Color(hex: 0xF4F5F7)
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
