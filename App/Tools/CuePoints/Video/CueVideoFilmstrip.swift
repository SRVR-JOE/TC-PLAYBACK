import SwiftUI
import AVFoundation
import UIKit

/// Thumbnails for the film-strip lane. Spaced on a fixed ladder of intervals (picked from the
/// zoom), so zooming in and out reuses what's already made. Generated off the main thread,
/// newest request first, and only for what's on screen.
@MainActor @Observable
final class CueVideoThumbnails {
    /// Seconds between thumbnails, finest first.
    static let ladder: [TimeInterval] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    struct Key: Hashable { var level: Int; var index: Int }

    /// Bumped when new thumbnails land, so the lane redraws.
    private(set) var version = 0
    var aspect: CGFloat = 16 / 9

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var cache: [Key: UIImage] = [:]
    @ObservationIgnored private var order: [Key] = []
    @ObservationIgnored private var queue: [Key] = []
    @ObservationIgnored private var inFlight: Set<Key> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var gen = 0
    private let limit = 600

    func reset(url: URL?) {
        worker?.cancel(); worker = nil
        gen += 1
        self.url = url
        cache = [:]; order = []; queue = []; inFlight = []
        generator = url.map { u in
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: u))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 240, height: 240)
            return g
        }
        version += 1
    }

    /// Interval (ladder level) for thumbnails `thumbWidth` points wide at `pps` points per second.
    static func level(thumbWidth: CGFloat, pointsPerSecond pps: CGFloat) -> Int {
        let ideal = Double(thumbWidth / max(pps, 0.0001))
        return ladder.firstIndex(where: { $0 >= ideal }) ?? ladder.count - 1
    }

    func image(_ k: Key) -> UIImage? { cache[k] }

    /// Asks for the thumbnails of `level` in `indices`; anything queued that isn't wanted any
    /// more is dropped.
    func want(level: Int, indices: ClosedRange<Int>) {
        guard generator != nil else { return }
        queue.removeAll { $0.level != level || !indices.contains($0.index) }
        for i in indices {
            let k = Key(level: level, index: i)
            if cache[k] == nil, !inFlight.contains(k), !queue.contains(k) { queue.append(k) }
        }
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty, let generator else { return }
        let g = gen
        let tolerance = { (lvl: Int) in CMTime(seconds: min(1, Self.ladder[lvl] / 2), preferredTimescale: 600) }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, self.gen == g, let k = self.queue.popLast() {
                self.inFlight.insert(k)
                generator.requestedTimeToleranceBefore = tolerance(k.level)
                generator.requestedTimeToleranceAfter = tolerance(k.level)
                let t = CMTime(seconds: Double(k.index) * Self.ladder[k.level], preferredTimescale: 600)
                let img = try? await generator.image(at: t).image
                guard self.gen == g else { return }
                self.inFlight.remove(k)
                if let img { self.store(UIImage(cgImage: img), k) }
            }
            self?.worker = nil
        }
    }

    private func store(_ img: UIImage, _ k: Key) {
        cache[k] = img; order.append(k)
        if order.count > limit {
            for old in order.prefix(order.count - limit) { cache[old] = nil }
            order.removeFirst(order.count - limit)
        }
        version += 1
    }

    /// Draws the strip: thumbnails where the video is, a darker band where it isn't.
    /// `origin`/`span` are the timeline's visible track times, `offset` the video offset.
    func draw(in gc: GraphicsContext, size: CGSize, origin: TimeInterval, span: TimeInterval,
              offset: TimeInterval, videoDuration: TimeInterval) {
        let pps = size.width / CGFloat(max(span, 0.001))
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.surfaceSunken))
        guard videoDuration > 0 else { return }
        let x0 = CGFloat(offset - origin) * pps, x1 = CGFloat(offset + videoDuration - origin) * pps
        let band = CGRect(x: max(0, x0), y: 0, width: max(0, min(size.width, x1) - max(0, x0)), height: size.height)
        gc.fill(Path(band), with: .color(Theme.surface))
        guard let (level, range) = Self.visible(size: size, origin: origin, span: span, offset: offset,
                                                videoDuration: videoDuration, aspect: aspect) else { return }
        let step = Self.ladder[level]
        let th = size.height - 4, tw = th * aspect
        gc.drawLayer { l in
            l.clip(to: Path(band))
            for i in range {
                let x = CGFloat(Double(i) * step + offset - origin) * pps
                let r = CGRect(x: x, y: 2, width: tw, height: th)
                if let img = cache[Key(level: level, index: i)] {
                    l.draw(Image(uiImage: img), in: r)
                } else {
                    l.fill(Path(r.insetBy(dx: 0.5, dy: 0)), with: .color(Theme.surfaceRaised))
                }
                l.fill(Path(CGRect(x: x, y: 2, width: 1, height: th)), with: .color(Theme.surfaceSunken))
            }
        }
        // Clip edges, so the start and end of the recording read clearly.
        for x in [x0, x1] where x >= 0 && x <= size.width {
            gc.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(Theme.textTertiary))
        }
    }

    /// The ladder level and thumbnail indices visible for this view.
    static func visible(size: CGSize, origin: TimeInterval, span: TimeInterval, offset: TimeInterval,
                        videoDuration: TimeInterval, aspect: CGFloat) -> (Int, ClosedRange<Int>)? {
        guard videoDuration > 0, size.width > 1, size.height > 4 else { return nil }
        let pps = size.width / CGFloat(max(span, 0.001))
        let tw = (size.height - 4) * aspect
        let level = level(thumbWidth: tw, pointsPerSecond: pps)
        let step = ladder[level]
        let v0 = max(0, origin - offset - Double(tw / pps)), v1 = min(videoDuration, origin + span - offset)
        guard v1 >= v0 else { return nil }
        let lo = Int((v0 / step).rounded(.down)), hi = max(lo, Int((v1 / step).rounded(.down)))
        return (level, lo...hi)
    }
}

/// Optional "V1" lane under the timeline: the video as a film strip, on the track's time line.
struct CueVideoFilmstripLane: View {
    var origin: TimeInterval
    var span: TimeInterval
    var gutter: CGFloat = 52
    var height: CGFloat = 44

    private var video: CueVideoController { CueVideoController.shared }

    var body: some View {
        let offset = video.link?.offset ?? 0
        let thumbs = video.thumbnails
        let version = thumbs.version     // redraw when thumbnails land
        let duration = video.duration, aspect = thumbs.aspect
        HStack(spacing: 0) {
            Text("V1").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(width: gutter, height: height)
                .background(Theme.surface)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            GeometryReader { geo in
                let size = geo.size
                Canvas { gc, sz in
                    _ = version
                    thumbs.draw(in: gc, size: sz, origin: origin, span: span, offset: offset, videoDuration: duration)
                }
                .task(id: Request(size: size, origin: origin, span: span, offset: offset, duration: duration, aspect: aspect)) {
                    // Let a fast scroll settle before asking for pictures.
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled,
                          let (level, range) = CueVideoThumbnails.visible(size: size, origin: origin, span: span, offset: offset,
                                                                          videoDuration: duration, aspect: aspect)
                    else { return }
                    thumbs.want(level: level, indices: range)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Video film strip")
    }

    private struct Request: Equatable {
        var size: CGSize, origin: TimeInterval, span: TimeInterval, offset: TimeInterval, duration: TimeInterval, aspect: CGFloat
    }
}
