import Foundation
import Accelerate
import AVFoundation
import TCKit

// Auto sync: line a video's sound up with the track's programme audio.
//
// A phone in a loud room hears the PA through reverb, crowd noise and the phone's own
// limiter, so the raw waveforms barely resemble the track. What survives is *when things
// start*: drum hits, stabs, stops. Both signals are reduced to an onset curve (log-band
// spectral flux, gain-free, locally normalised), cross-correlated with an FFT over a wide
// coarse window (±10 min at 10 ms), then refined on a 1 ms onset curve around the best peak.

/// Onset curves for one signal, made from 8 kHz mono.
struct CueSyncFeatures {
    static let sampleRate = 8000.0
    /// 10 ms frames (hop 80 at 8 kHz).
    static let coarseRate = 100.0
    /// 1 ms frames (hop 8 at 8 kHz).
    static let fineRate = 1000.0

    /// Spectral flux, normalised, one value per 10 ms.
    var coarse: [Float]
    /// Broadband onset, normalised, one value per 1 ms.
    var fine: [Float]
    var duration: TimeInterval { Double(coarse.count) / Self.coarseRate }
}

/// Streams 8 kHz mono samples into `CueSyncFeatures` without keeping the audio itself.
final class CueOnsetExtractor {
    private static let n = 256, hop = 80, fineHop = 8
    private static let bandEdges: [Int] = {
        // 16 log-spaced bands, ~60 Hz…4 kHz, on a 256-point FFT at 8 kHz (31.25 Hz bins).
        var e: [Int] = []
        for k in 0...16 {
            let b = Int((2.0 * pow(127.0 / 2.0, Double(k) / 16)).rounded())
            if let last = e.last, b <= last { e.append(last + 1) } else { e.append(b) }
        }
        return e
    }()
    private static var bands: Int { bandEdges.count - 1 }

    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: CueOnsetExtractor.n)
    private var pending: [Float] = []
    private var pendingStart = 0
    private var bandEnergy: [Float] = []     // frames × bands
    private var frameCount = 0
    private var fineEnergy: [Float] = []
    private var fineAcc: Float = 0, fineCount = 0, prev: Float = 0
    private var frame = [Float](repeating: 0, count: CueOnsetExtractor.n)
    private var re = [Float](repeating: 0, count: CueOnsetExtractor.n / 2)
    private var im = [Float](repeating: 0, count: CueOnsetExtractor.n / 2)

    init() {
        setup = vDSP_create_fftsetup(8, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.n), Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func feed(_ x: UnsafeBufferPointer<Float>) {
        guard !x.isEmpty else { return }
        // Fine curve: pre-emphasised (first difference) energy per 1 ms.
        for v in x {
            let d = v - prev; prev = v
            fineAcc += d * d; fineCount += 1
            if fineCount == Self.fineHop { fineEnergy.append(fineAcc); fineAcc = 0; fineCount = 0 }
        }
        // Coarse curve: band energies per 10 ms frame.
        pending.append(contentsOf: x)
        while pending.count - pendingStart >= Self.n {
            analyseFrame(at: pendingStart)
            pendingStart += Self.hop
        }
        if pendingStart > 1 << 16 { pending.removeFirst(pendingStart); pendingStart = 0 }
    }

    func feed(_ x: [Float]) { x.withUnsafeBufferPointer { feed($0) } }

    private func analyseFrame(at start: Int) {
        let n = Self.n
        pending.withUnsafeBufferPointer { p in
            vDSP_vmul(p.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
        }
        var power = [Float](repeating: 0, count: n / 2 + 1)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 8, FFTDirection(FFT_FORWARD))
                power[0] = rp[0] * rp[0]
                power[n / 2] = ip[0] * ip[0]
                for k in 1..<(n / 2) { power[k] = rp[k] * rp[k] + ip[k] * ip[k] }
            }
        }
        let edges = Self.bandEdges
        for b in 0..<Self.bands {
            var s: Float = 0
            for k in edges[b]..<edges[b + 1] { s += power[k] }
            bandEnergy.append(s)
        }
        frameCount += 1
    }

    /// Finishes the curves. Cheap; the extractor can't be fed afterwards.
    func finish() -> CueSyncFeatures {
        let nb = Self.bands
        // Spectral flux on log band energy. The floor scales with each band's own mean, so a
        // gain change (phone limiter, distance) leaves the curve unchanged.
        var floors = [Float](repeating: 0, count: nb)
        if frameCount > 0 {
            for f in 0..<frameCount { for b in 0..<nb { floors[b] += bandEnergy[f * nb + b] } }
            for b in 0..<nb { floors[b] = max(1e-20, floors[b] / Float(frameCount) * 1e-3) }
        }
        var flux = [Float](repeating: 0, count: frameCount)
        var last = [Float](repeating: 0, count: nb)
        for f in 0..<frameCount {
            var s: Float = 0
            for b in 0..<nb {
                let l = logf(bandEnergy[f * nb + b] + floors[b])
                if f > 0 { s += max(0, l - last[b]) }
                last[b] = l
            }
            flux[f] = s
        }
        // Fine: log energy rise per 1 ms.
        let fe = fineEnergy
        var fineFloor: Float = 0
        if !fe.isEmpty { vDSP_meanv(fe, 1, &fineFloor, vDSP_Length(fe.count)) }
        fineFloor = max(1e-20, fineFloor * 1e-3)
        var fine = [Float](repeating: 0, count: fe.count)
        var lastL: Float = logf(fineFloor)
        for i in 0..<fe.count {
            // Short smoothing (3 ms) before differencing keeps sample noise out of the rise.
            let a = fe[max(0, i - 2)], b = fe[max(0, i - 1)], c = fe[i]
            let l = logf((a + b + c) / 3 + fineFloor)
            fine[i] = max(0, l - lastL); lastL = l
        }
        return CueSyncFeatures(coarse: CueAutoSync.normaliseOnsets(flux, rate: CueSyncFeatures.coarseRate),
                               fine: CueAutoSync.normaliseOnsets(fine, rate: CueSyncFeatures.fineRate))
    }
}

enum CueAutoSync {
    struct Result: Equatable {
        /// Track time − video time, seconds.
        var offset: TimeInterval
        /// 0…1. Above ~0.5 the match is clear; below ~0.25 check it by eye.
        var confidence: Double
        /// Best peak / best peak elsewhere (≥ 1).
        var peakRatio: Double
        /// True when the 1 ms refinement agreed and was used.
        var refined: Bool
        /// Seconds of the video that overlap the track at this offset.
        var overlap: TimeInterval

        enum Strength { case strong, likely, weak }
        var strength: Strength { confidence >= 0.5 ? .strong : (confidence >= 0.25 ? .likely : .weak) }
    }

    enum Failure: LocalizedError {
        case noVideoAudio, noTrackAudio, tooShort, noMatch
        var errorDescription: String? {
            switch self {
            case .noVideoAudio: "The video has no sound to match."
            case .noTrackAudio: "The track's audio couldn't be read."
            case .tooShort: "The video is too short to match. Line it up by eye instead."
            case .noMatch: "No match found within ten minutes either way."
            }
        }
    }

    // MARK: Correlation (pure, testable)

    /// Finds where `video` sits in `track`. Both are onset features at the standard rates.
    /// - Parameter searchRange: ± seconds of offset to consider.
    static func estimate(track: CueSyncFeatures, video: CueSyncFeatures, searchRange: TimeInterval = 600,
                         isCancelled: () -> Bool = { false }) throws -> Result {
        let a = video.coarse, b = track.coarse
        let rate = CueSyncFeatures.coarseRate
        guard a.count >= Int(3 * rate), b.count >= Int(3 * rate) else { throw Failure.tooShort }
        if isCancelled() { throw CancellationError() }

        let corr = crossCorrelate(a, b)
        if isCancelled() { throw CancellationError() }

        // Normalise each lag by the energy of the parts that overlap (true NCC), so a partial
        // overlap at the edges can't win just by being louder.
        let ca = cumulativeSquares(a), cb = cumulativeSquares(b)
        let na = a.count, nb = b.count
        let minOverlap = min(min(na, nb), max(Int(10 * rate), min(na, nb) / 4))
        let r = Int(searchRange * rate)
        let lo = max(-r, -(na - minOverlap)), hi = min(r, nb - minOverlap)
        guard lo <= hi else { throw Failure.noMatch }
        var ncc = [Float](repeating: 0, count: hi - lo + 1)
        let size = corr.count
        for lag in lo...hi {
            let i0 = max(0, -lag), i1 = min(na, nb - lag)  // video indices that overlap
            let ea = ca[i1] - ca[i0], eb = cb[i1 + lag] - cb[i0 + lag]
            let den = (ea * eb).squareRoot()
            let c = corr[((lag % size) + size) % size]
            ncc[lag - lo] = den > 1e-12 ? Float(Double(c) / den) : 0
        }
        if isCancelled() { throw CancellationError() }

        var best = 0
        for i in 1..<ncc.count where ncc[i] > ncc[best] { best = i }
        let peak = ncc[best]
        guard peak > 0 else { throw Failure.noMatch }
        // Strongest competitor at least 0.25 s away.
        let guardLags = Int(0.25 * rate)
        var second: Float = 0
        for i in 0..<ncc.count where abs(i - best) > guardLags { second = max(second, ncc[i]) }
        let ratio = Double(peak / max(second, peak * 1e-3))

        var lagC = Double(best + lo) + parabolic(ncc, best)
        lagC = min(max(lagC, Double(lo)), Double(hi))
        var offset = lagC / rate

        // Fine stage at 1 ms around the coarse answer.
        var refined = false
        if let f = refine(track: track.fine, video: video.fine, around: offset, window: 0.04, isCancelled: isCancelled),
           abs(f - offset) <= 0.025 {
            offset = f; refined = true
        }
        if isCancelled() { throw CancellationError() }

        let lagI = Int((offset * rate).rounded())
        let overlap = Double(max(0, min(na, nb - lagI) - max(0, -lagI))) / rate
        // Confidence from how far the peak stands above everything else, tempered by the peak
        // height itself (a lone weak peak in silence isn't a match).
        let fromRatio = min(1, max(0, (ratio - 1.05) / 0.6))
        let fromHeight = min(1, max(0, Double(peak - 0.05) / 0.25))
        let confidence = fromRatio * (0.5 + 0.5 * fromHeight)
        return Result(offset: offset, confidence: confidence, peakRatio: ratio, refined: refined, overlap: overlap)
    }

    /// Convenience for raw 8 kHz mono signals.
    static func estimate(trackSamples: [Float], videoSamples: [Float], searchRange: TimeInterval = 600) throws -> Result {
        try estimate(track: features(trackSamples), video: features(videoSamples), searchRange: searchRange)
    }

    static func features(_ samples8k: [Float]) -> CueSyncFeatures {
        let x = CueOnsetExtractor()
        // Feed in chunks like a reader would.
        var i = 0
        samples8k.withUnsafeBufferPointer { p in
            while i < p.count {
                let n = min(8192, p.count - i)
                x.feed(UnsafeBufferPointer(rebasing: p[i..<(i + n)]))
                i += n
            }
        }
        return x.finish()
    }

    /// 1 ms refinement: normalised dot product over the overlap for lags within ±`window` s.
    static func refine(track: [Float], video: [Float], around offset: TimeInterval, window: TimeInterval,
                       isCancelled: () -> Bool) -> TimeInterval? {
        let rate = CueSyncFeatures.fineRate
        let l0 = Int((offset * rate).rounded()), w = Int(window * rate)
        let na = video.count, nb = track.count
        // Use the middle of the overlap, at most four minutes of it.
        let i0 = max(0, -(l0 - w)), i1 = min(na, nb - (l0 + w))
        guard i1 - i0 > Int(2 * rate) else { return nil }
        let maxLen = Int(240 * rate)
        let mid = (i0 + i1) / 2, half = min(maxLen, i1 - i0) / 2
        let s0 = mid - half, len = half * 2
        var scores = [Float](repeating: 0, count: 2 * w + 1)
        var ea: Float = 0
        video.withUnsafeBufferPointer { vp in vDSP_svesq(vp.baseAddress! + s0, 1, &ea, vDSP_Length(len)) }
        track.withUnsafeBufferPointer { tp in
            video.withUnsafeBufferPointer { vp in
                for k in -w...w {
                    if (k & 15) == 0, isCancelled() { return }
                    let j = s0 + l0 + k
                    var dot: Float = 0, eb: Float = 0
                    vDSP_dotpr(vp.baseAddress! + s0, 1, tp.baseAddress! + j, 1, &dot, vDSP_Length(len))
                    vDSP_svesq(tp.baseAddress! + j, 1, &eb, vDSP_Length(len))
                    let den = (ea * eb).squareRoot()
                    scores[k + w] = den > 0 ? dot / den : 0
                }
            }
        }
        var best = 0
        for i in 1..<scores.count where scores[i] > scores[best] { best = i }
        guard scores[best] > 0.05, best > 0, best < scores.count - 1 else { return nil }
        return (Double(l0 + best - w) + parabolic(scores, best)) / rate
    }

    /// c[lag] = Σ a[i]·b[i + lag], returned circularly: index lag mod count.
    static func crossCorrelate(_ a: [Float], _ b: [Float]) -> [Float] {
        var log2n = 1
        while (1 << log2n) < a.count + b.count { log2n += 1 }
        let n = 1 << log2n, half = n / 2
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        func forward(_ x: [Float], _ re: inout [Float], _ im: inout [Float]) {
            var padded = x; padded.append(contentsOf: repeatElement(0, count: n - x.count))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var s = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { pp in
                        pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &s, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &s, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                }
            }
        }
        var ar = [Float](repeating: 0, count: half), ai = ar, br = ar, bi = ar
        forward(a, &ar, &ai)
        forward(b, &br, &bi)
        // conj(A)·B. Bin 0 packs DC (real) and Nyquist (imag), both real-valued.
        var cr = [Float](repeating: 0, count: half), ci = cr
        cr[0] = ar[0] * br[0]; ci[0] = ai[0] * bi[0]
        for k in 1..<half {
            cr[k] = ar[k] * br[k] + ai[k] * bi[k]
            ci[k] = ar[k] * bi[k] - ai[k] * br[k]
        }
        var out = [Float](repeating: 0, count: n)
        cr.withUnsafeMutableBufferPointer { rp in
            ci.withUnsafeMutableBufferPointer { ip in
                var s = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &s, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&s, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }
        var scale = 1 / Float(4 * n)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
        return out
    }

    /// Removes the local level and evens out loud and quiet passages, so the correlation is
    /// driven by where onsets fall rather than how big they are.
    static func normaliseOnsets(_ x: [Float], rate: Double) -> [Float] {
        guard x.count > 4 else { return x }
        let mean = movingAverage(x, radius: max(1, Int(0.25 * rate)))
        var y = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count { y[i] = max(0, x[i] - mean[i]) }
        let sq = y.map { $0 * $0 }
        let ms = movingAverage(sq, radius: max(1, Int(1.5 * rate)))
        var g: Float = 0
        vDSP_measqv(y, 1, &g, vDSP_Length(y.count))
        let floor = 0.1 * g.squareRoot() + 1e-12
        for i in 0..<y.count { y[i] /= (ms[i].squareRoot() + floor) }
        var m: Float = 0
        vDSP_meanv(y, 1, &m, vDSP_Length(y.count))
        var neg = -m
        vDSP_vsadd(y, 1, &neg, &y, 1, vDSP_Length(y.count))
        return y
    }

    static func movingAverage(_ x: [Float], radius: Int) -> [Float] {
        var c = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { c[i + 1] = c[i] + Double(x[i]) }
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let a = max(0, i - radius), b = min(x.count, i + radius + 1)
            out[i] = Float((c[b] - c[a]) / Double(b - a))
        }
        return out
    }

    private static func cumulativeSquares(_ x: [Float]) -> [Double] {
        var c = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { c[i + 1] = c[i] + Double(x[i]) * Double(x[i]) }
        return c
    }

    /// Sub-sample peak position (−0.5…0.5) from the neighbours of `i`.
    static func parabolic(_ y: [Float], _ i: Int) -> Double {
        guard i > 0, i < y.count - 1 else { return 0 }
        let a = Double(y[i - 1]), b = Double(y[i]), c = Double(y[i + 1])
        let d = a - 2 * b + c
        guard d < 0 else { return 0 }
        return min(0.5, max(-0.5, 0.5 * (a - c) / d))
    }

    // MARK: Reading audio

    /// The track's programme channel (not the LTC side), at 8 kHz.
    static func trackFeatures(url: URL, channel: Int, progress: @escaping (Double) -> Void,
                              isCancelled: @escaping () -> Bool) throws -> CueSyncFeatures {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.noTrackAudio }
        let inFmt = file.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: CueSyncFeatures.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 16384),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 8192) else { throw Failure.noTrackAudio }
        conv.channelMap = [NSNumber(value: min(max(0, channel), Int(inFmt.channelCount) - 1))]
        let x = CueOnsetExtractor()
        let length = max(1, file.length)
        var done = false
        while !done {
            if isCancelled() { throw CancellationError() }
            outBuf.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                if file.framePosition >= file.length { outStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf, frameCount: 16384) } catch { outStatus.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw Failure.noTrackAudio }
            if let p = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                x.feed(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || (status == .inputRanDry && outBuf.frameLength == 0) { done = true }
            progress(Double(file.framePosition) / Double(length))
        }
        return x.finish()
    }

    /// The video's sound, mixed to mono at 8 kHz. Index 0 = video time 0.
    static func videoFeatures(url: URL, progress: @escaping (Double) -> Void,
                              isCancelled: @escaping () -> Bool) async throws -> CueSyncFeatures {
        let x = CueOnsetExtractor()
        try await CueVideoAudioReader.read(url: url, sampleRate: CueSyncFeatures.sampleRate, channels: 1,
                                           progress: progress, isCancelled: isCancelled) { samples in
            x.feed(samples)
        }
        let f = x.finish()
        if f.coarse.isEmpty { throw Failure.noVideoAudio }
        return f
    }

    /// Reads both sides and runs the match. Call from a background task; honours cancellation.
    static func run(trackURL: URL, programChannel: Int, videoURL: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let cancelled: () -> Bool = { Task.isCancelled }
        let v = try await videoFeatures(url: videoURL, progress: { progress($0 * 0.45) }, isCancelled: cancelled)
        let t = try trackFeatures(url: trackURL, channel: programChannel, progress: { progress(0.45 + $0 * 0.45) }, isCancelled: cancelled)
        progress(0.92)
        let r = try estimate(track: t, video: v, isCancelled: cancelled)
        progress(1)
        return r
    }
}

/// Decodes a movie's sound to interleaved float PCM in chunks, padded so sample 0 is video time 0.
enum CueVideoAudioReader {
    static func read(url: URL, sampleRate: Double, channels: Int, progress: @escaping (Double) -> Void,
                     isCancelled: @escaping () -> Bool, chunk: (UnsafeBufferPointer<Float>) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw CueAutoSync.Failure.noVideoAudio }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        ]
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw CueAutoSync.Failure.noVideoAudio }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? CueAutoSync.Failure.noVideoAudio }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var first = true
        var scratch: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            if isCancelled() { throw CancellationError() }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if first {
                first = false
                // Sound that starts after the picture: pad so indices stay on the video clock.
                if pts.isFinite, pts > 0 {
                    let pad = [Float](repeating: 0, count: Int((pts * sampleRate).rounded()) * channels)
                    try pad.withUnsafeBufferPointer { try chunk($0) }
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            let ok = scratch.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard ok == kCMBlockBufferNoErr else { continue }
            try scratch.withUnsafeBufferPointer { try chunk(UnsafeBufferPointer(rebasing: $0[0..<count])) }
            if duration > 0, pts.isFinite { progress(min(1, pts / duration)) }
        }
        if reader.status == .failed { throw reader.error ?? CueAutoSync.Failure.noVideoAudio }
        progress(1)
    }
}

/// Lines a video up by the LTC on its soundtrack (a recording taken off a desk feed).
enum CueVideoLTC {
    struct Found: Equatable {
        /// Timecode at `videoTime`.
        var timecode: Timecode
        var videoTime: TimeInterval
    }

    /// Scans the video's sound in 20 s windows and returns the first timecode it reads.
    static func scan(url: URL, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) async throws -> Found? {
        let sr = 48_000.0, win = Int(sr * 20)
        var l: [Float] = [], r: [Float] = []
        l.reserveCapacity(win); r.reserveCapacity(win)
        var windowStart = 0  // in samples
        var found: Found?
        struct Stop: Error {}
        do {
            try await CueVideoAudioReader.read(url: url, sampleRate: sr, channels: 2, progress: progress,
                                               isCancelled: isCancelled) { s in
                var i = 0
                while i + 1 < s.count {
                    l.append(s[i]); r.append(s[i + 1]); i += 2
                    if l.count == win {
                        if let hit = LTCScanner.scan(channels: [l, r], sampleRate: sr) {
                            found = Found(timecode: hit.start, videoTime: Double(windowStart) / sr)
                            throw Stop()
                        }
                        windowStart += win; l.removeAll(keepingCapacity: true); r.removeAll(keepingCapacity: true)
                    }
                }
            }
            if found == nil, l.count > Int(sr * 2), let hit = LTCScanner.scan(channels: [l, r], sampleRate: sr) {
                found = Found(timecode: hit.start, videoTime: Double(windowStart) / sr)
            }
        } catch is Stop {}
        return found
    }

    /// Offset that puts the video's timecode on the same timecode in the track.
    static func offset(for found: Found, clock: CuePointClock) -> TimeInterval {
        let tc = found.timecode
        // Read the video's TC on the track's rate when they share a frame count (30 vs 29.97 ND).
        let same = tc.rate.nominalFPS == clock.rate.nominalFPS
        let secs = same ? Timecode(hours: tc.hours, minutes: tc.minutes, seconds: tc.seconds, frames: tc.frames, rate: clock.rate).realSeconds
                        : tc.realSeconds
        let trackTime = secs - clock.start.realSeconds
        return CueVideoLink.offset(trackTime: trackTime, videoTime: found.videoTime)
    }
}
