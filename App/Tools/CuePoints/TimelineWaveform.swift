import AVFoundation
import Observation
import SwiftUI

/// Min/max pairs (signed, −1…1) at a fixed density: one pair per 1/`perSecond` s of audio.
struct WaveLevel: Sendable, Equatable {
    let perSecond: Double
    var mins: [Float]
    var maxs: [Float]
    var count: Int { maxs.count }
}

/// Multi-resolution peaks for the timeline: 10, 100 and 1000 pairs a second, built in one pass.
/// Past 1000 points a second the timeline reads the real samples (`TimelineWaveform`), so the
/// waveform is never drawn from data coarser than the screen.
enum WaveformPyramid {
    static let densities: [Double] = [10, 100, 1000]

    /// Every level from a run of samples (the finest is built first, the rest are folded from it).
    static func build(samples: [Float], sampleRate: Double) -> [WaveLevel] {
        var b = Builder(sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { b.add($0) }
        return b.finish()
    }

    /// Accumulates the finest level sample by sample; bucket i holds samples whose
    /// index × density / sampleRate floors to i, so coarser levels fold from it exactly.
    struct Builder {
        let sampleRate: Double
        private let finest = densities.last!
        private var mins: [Float] = [], maxs: [Float] = []
        private var lo: Float = 0, hi: Float = 0, bucket = 0, index = 0, started = false

        init(sampleRate: Double) { self.sampleRate = max(1, sampleRate) }

        mutating func add(_ p: UnsafeBufferPointer<Float>) {
            let k = finest / sampleRate
            for v in p {
                let b = Int(Double(index) * k)
                if b != bucket {
                    if started { mins.append(lo); maxs.append(hi) }
                    // Silent gaps can't occur (b only ever grows by 0 or 1 per sample at ≥ 1 kHz).
                    bucket = b; lo = v; hi = v; started = true
                } else if !started {
                    lo = v; hi = v; started = true
                } else {
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
                index += 1
            }
        }

        mutating func finish() -> [WaveLevel] {
            if started { mins.append(lo); maxs.append(hi); started = false }
            let fine = WaveLevel(perSecond: finest, mins: mins, maxs: maxs)
            var levels = [fine]
            for d in densities.dropLast().reversed() {
                levels.insert(WaveformPyramid.fold(levels[0], to: d), at: 0)
            }
            return levels
        }
    }

    static func fold(_ l: WaveLevel, to density: Double) -> WaveLevel {
        let g = max(1, Int((l.perSecond / density).rounded()))
        let n = (l.count + g - 1) / g
        var mins = [Float](repeating: 0, count: n), maxs = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = i * g, b = min(l.count, a + g)
            var lo = l.mins[a], hi = l.maxs[a]
            for j in (a + 1)..<max(a + 1, b) { lo = min(lo, l.mins[j]); hi = max(hi, l.maxs[j]) }
            mins[i] = lo; maxs[i] = hi
        }
        return WaveLevel(perSecond: density, mins: mins, maxs: maxs)
    }

    /// Index of the coarsest level that still has at least one point per screen pixel at
    /// `pixelsPerSecond` (device pixels). nil = finer than every level: draw the samples.
    static func level(forPixelsPerSecond pps: Double, in levels: [WaveLevel]) -> Int? {
        levels.firstIndex(where: { $0.perSecond >= pps })
    }
}

/// Reads one channel of the audio file in fixed blocks (off the main thread).
private actor WaveformFileReader {
    private let file: AVAudioFile?
    private let channel: Int
    init(url: URL, channel: Int) {
        file = try? AVAudioFile(forReading: url)
        self.channel = channel
    }

    var sampleRate: Double { file?.processingFormat.sampleRate ?? 48_000 }
    var length: Int { Int(file?.length ?? 0) }

    func read(from start: Int, count: Int) -> [Float] {
        guard let f = file, count > 0, start < Int(f.length) else { return [] }
        let fmt = f.processingFormat
        let n = min(count, Int(f.length) - start)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return [] }
        f.framePosition = AVAudioFramePosition(start)
        do { try f.read(into: buf, frameCount: AVAudioFrameCount(n)) } catch { return [] }
        let ch = min(channel, Int(fmt.channelCount) - 1)
        guard ch >= 0, let p = buf.floatChannelData?[ch] else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(buf.frameLength)))
    }

    /// Whole-file pass for the peak pyramid.
    func pyramid() -> [WaveLevel] {
        guard let f = file else { return [] }
        let fmt = f.processingFormat
        let chunk: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return [] }
        let ch = min(channel, Int(fmt.channelCount) - 1)
        var b = WaveformPyramid.Builder(sampleRate: fmt.sampleRate)
        f.framePosition = 0
        while f.framePosition < f.length {
            if Task.isCancelled { return [] }
            do { try f.read(into: buf, frameCount: chunk) } catch { break }
            guard buf.frameLength > 0, ch >= 0, let p = buf.floatChannelData?[ch] else { break }
            b.add(UnsafeBufferPointer(start: p, count: Int(buf.frameLength)))
        }
        return b.finish()
    }
}

/// The timeline's waveform data for one track: the peak pyramid plus a small cache of real
/// sample blocks for deep zoom. Everything is read off the main thread; the canvas only ever
/// draws what's cached and asks for what's missing, so nothing is re-read while playing.
@MainActor @Observable
final class TimelineWaveform {
    let url: URL
    let channel: Int
    private(set) var levels: [WaveLevel] = []
    private(set) var sampleRate: Double = 48_000
    /// Samples in the file (0 until known).
    private(set) var length = 0
    /// Largest absolute sample value in the track (for display normalisation).
    private(set) var peak: Float = 0
    /// Bumped whenever new data arrives, so the canvas redraws.
    private(set) var version = 0

    /// Seconds per cached block of samples, and how many blocks to keep (≈ 3 MB at 48 kHz).
    static let blockSeconds = 2.0
    static let maxBlocks = 8

    @ObservationIgnored private let reader: WaveformFileReader
    @ObservationIgnored private var blocks: [Int: [Float]] = [:]
    @ObservationIgnored private var lru: [Int] = []
    @ObservationIgnored private var loading: Set<Int> = []
    @ObservationIgnored private var blockLength = 96_000
    @ObservationIgnored private var task: Task<Void, Never>?

    init(url: URL, channel: Int) {
        self.url = url
        self.channel = channel
        reader = WaveformFileReader(url: url, channel: channel)
        task = Task { [weak self, reader] in
            let sr = await reader.sampleRate
            let len = await reader.length
            let levels = await Task.detached(priority: .userInitiated) { await reader.pyramid() }.value
            guard let self, !Task.isCancelled else { return }
            self.sampleRate = sr
            self.length = len
            self.blockLength = max(1, Int(sr * Self.blockSeconds))
            self.levels = levels
            let coarse = levels.first
            self.peak = max(coarse?.maxs.max() ?? 0, -(coarse?.mins.min() ?? 0))
            self.version += 1
        }
    }

    /// Demo/test data without a file.
    init(levels: [WaveLevel], sampleRate: Double, samples: [Float]? = nil) {
        url = URL(fileURLWithPath: "/dev/null")
        channel = 0
        reader = WaveformFileReader(url: url, channel: 0)
        self.levels = levels
        self.sampleRate = sampleRate
        length = samples?.count ?? 0
        blockLength = max(1, Int(sampleRate * Self.blockSeconds))
        let coarse = levels.first
        peak = max(coarse?.maxs.max() ?? 0, -(coarse?.mins.min() ?? 0))
        if let samples {
            var i = 0, b = 0
            while i < samples.count {
                blocks[b] = Array(samples[i..<min(samples.count, i + blockLength)])
                i += blockLength; b += 1
            }
        }
    }

    deinit { task?.cancel() }

    /// Samples `start ..< start + count` if every block they touch is cached; otherwise asks for
    /// the missing blocks (and one block ahead, for playback) and returns nil until they land.
    func samples(from start: Int, count: Int) -> [Float]? {
        guard count > 0 else { return [] }
        let s0 = max(0, start), s1 = s0 + count
        let b0 = s0 / blockLength, b1 = (s1 - 1) / blockLength
        var missing = false
        for b in b0...(b1 + 1) where blocks[b] == nil {
            request(b)
            if b <= b1 { missing = true }
        }
        guard !missing else { return nil }
        var out: [Float] = []
        out.reserveCapacity(count)
        for b in b0...b1 {
            guard let blk = blocks[b] else { return nil }
            touch(b)
            let base = b * blockLength
            let a = max(s0, base) - base, z = min(s1, base + blk.count) - base
            if a < z { out.append(contentsOf: blk[a..<z]) }
        }
        return out
    }

    private func touch(_ b: Int) {
        if let i = lru.firstIndex(of: b) { lru.remove(at: i) }
        lru.append(b)
    }

    private func request(_ b: Int) {
        guard b >= 0, !loading.contains(b), url.path != "/dev/null", b * blockLength < length else { return }
        loading.insert(b)
        let start = b * blockLength, n = blockLength
        Task { [weak self, reader] in
            let data = await reader.read(from: start, count: n)
            guard let self else { return }
            self.loading.remove(b)
            guard !data.isEmpty else { return }
            self.blocks[b] = data
            self.touch(b)
            while self.lru.count > Self.maxBlocks { self.blocks[self.lru.removeFirst()] = nil }
            self.version += 1
        }
    }
}
