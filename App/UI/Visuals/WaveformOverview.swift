import SwiftUI

// Owned by the VISUALS agent. Implementation behind `WaveformOverviewView` (see VisualsAPI.swift).

struct WaveformOverviewContent: View {
    var overview: Data?
    var channelCount: Int
    var duration: TimeInterval
    var scrubEnabled: Bool

    @Environment(\.visualsDataSource) private var data
    @State private var dragX: CGFloat?

    private static let played = Theme.scopeTrace.opacity(0.9)
    private static let upcoming = Theme.textTertiary

    private var length: TimeInterval { duration > 0 ? duration : data.duration }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let playX = dragX ?? (length > 0 ? CGFloat(min(1, max(0, data.currentTime / length))) * w : 0)
            Canvas { gc, size in
                draw(gc, size, playX: playX)
            }
            .overlay(alignment: .topLeading) {
                if let dragX, length > 0 {
                    let t = Double(dragX / max(1, w)) * length
                    Text(VisualsFormat.preciseTime(t))
                        .font(Theme.numeric(11))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceRaised))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hairline, lineWidth: 1))
                        .fixedSize()
                        .alignmentGuide(.leading) { d in
                            -min(max(0, dragX - d.width / 2), max(0, w - d.width))
                        }
                        .offset(y: 3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(scrubEnabled && length > 0 ? scrub(width: w) : nil)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue(length > 0 ? "\(VisualsFormat.time(data.currentTime)) of \(VisualsFormat.time(length))" : "Empty")
        .accessibilityAdjustableAction { dir in
            guard scrubEnabled, length > 0 else { return }
            let step: TimeInterval = dir == .increment ? 5 : -5
            data.seek(to: min(length, max(0, data.currentTime + step)))
        }
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in dragX = min(width, max(0, v.location.x)) }
            .onEnded { v in
                let x = min(width, max(0, v.location.x))
                data.seek(to: Double(x / max(1, width)) * length)
                dragX = nil
            }
    }

    private func draw(_ gc: GraphicsContext, _ size: CGSize, playX: CGFloat) {
        let r = CGRect(origin: .zero, size: size)
        gc.fill(Path(r), with: .color(Theme.surfaceSunken))
        let mid = r.midY

        var centre = Path()
        centre.move(to: CGPoint(x: 0, y: mid)); centre.addLine(to: CGPoint(x: size.width, y: mid))

        guard let overview, overview.count >= 2 else {
            gc.stroke(centre, with: .color(Theme.hairline), lineWidth: 1)
            gc.draw(Text("Analysing\u{2026}").font(Theme.caption).foregroundStyle(Theme.textSecondary),
                    at: CGPoint(x: 8, y: mid - 9), anchor: .leading)
            return
        }

        let stereo = channelCount > 1
        let laneH = stereo ? size.height / 2 - 2 : size.height / 2 - 2
        let routing = data.routing
        var pathL = Path(), pathR = Path()
        overview.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let buckets = bytes.count / 2
            let columns = max(1, Int(size.width.rounded()))
            for c in 0..<columns {
                let a = c * buckets / columns
                let b = max(a + 1, (c + 1) * buckets / columns)
                var pl: UInt8 = 0, pr: UInt8 = 0
                for k in a..<min(b, buckets) { pl = max(pl, bytes[k * 2]); pr = max(pr, bytes[k * 2 + 1]) }
                let x = CGFloat(c)
                let hl = max(0.5, CGFloat(pl) / 255 * laneH)
                if stereo {
                    let hr = max(0.5, CGFloat(pr) / 255 * laneH)
                    pathL.addRect(CGRect(x: x, y: mid - hl, width: 1, height: hl))
                    pathR.addRect(CGRect(x: x, y: mid, width: 1, height: hr))
                } else {
                    pathL.addRect(CGRect(x: x, y: mid - hl, width: 1, height: hl * 2))
                }
            }
        }

        let lOpacity = routing.leftEnabled ? 1.0 : 0.25
        let rOpacity = routing.rightEnabled ? 1.0 : 0.25
        for (path, op) in [(pathL, lOpacity), (pathR, rOpacity)] {
            gc.drawLayer { l in
                l.clip(to: Path(CGRect(x: 0, y: 0, width: playX, height: size.height)))
                l.fill(path, with: .color(Self.played.opacity(op)))
            }
            gc.drawLayer { l in
                l.clip(to: Path(CGRect(x: playX, y: 0, width: size.width - playX, height: size.height)))
                l.fill(path, with: .color(Self.upcoming.opacity(op)))
            }
        }
        gc.stroke(centre, with: .color(Theme.hairline), lineWidth: Theme.hairlineWidth)

        // Lane labels, with the LTC tag where the clock is decoding from.
        var ltcLane: SourceChannel?
        if case .decoded(let ch) = data.clock.source { ltcLane = ch }
        laneTag(gc, "L", ltc: ltcLane == .left, at: CGPoint(x: 6, y: 9), muted: !routing.leftEnabled)
        if stereo {
            laneTag(gc, "R", ltc: ltcLane == .right, at: CGPoint(x: 6, y: size.height - 9), muted: !routing.rightEnabled)
        }

        // Playhead.
        let px = min(size.width - 0.5, max(0.5, playX))
        var ph = Path()
        ph.move(to: CGPoint(x: px, y: 0)); ph.addLine(to: CGPoint(x: px, y: size.height))
        gc.stroke(ph, with: .color(Theme.textPrimary), lineWidth: 1)
    }

    private func laneTag(_ gc: GraphicsContext, _ name: String, ltc: Bool, at p: CGPoint, muted: Bool) {
        let c = muted ? Theme.textTertiary : Theme.textSecondary
        gc.draw(Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(c), at: p, anchor: .leading)
        guard ltc else { return }
        let text = gc.resolve(Text("LTC").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textPrimary))
        let ts = text.measure(in: CGSize(width: 100, height: 20))
        let box = CGRect(x: p.x + 12, y: p.y - ts.height / 2 - 1.5, width: ts.width + 8, height: ts.height + 3)
        gc.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(Theme.surfaceRaised))
        gc.stroke(Path(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(Theme.textTertiary), lineWidth: 1)
        gc.draw(text, at: CGPoint(x: box.midX, y: box.midY))
    }
}
