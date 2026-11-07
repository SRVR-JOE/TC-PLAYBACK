import Foundation
import Accelerate

/// Finds the musical moments in a track's programme audio: hits, drops, builds, breakdowns,
/// stops and section changes (with a repeat-structure guess). Offline, on device, Accelerate
/// only. See docs/SONG_ANALYSIS.md for the techniques and their limits.
///
/// Passes over a mono mix of every channel except LTC, decimated to ~11 kHz:
/// 1. Tempo, phase and downbeat (`TempoDetector`), unless the track already has a grid.
/// 2. Fine STFT (512 / hop 64, ≈ 5.8 ms): SuperFlux (log-magnitude flux against a 3-bin
///    max-filtered spectrum two frames back), HFC-weighted flux, low-band flux, and level.
/// 3. Coarse STFT (4096 / hop 1024, ≈ 93 ms): loudness, bass level, spectral centroid,
///    12-bin chroma and 12 cepstral coefficients from 24 log bands (an MFCC stand-in).
/// 4. Hits from the onset curve (peaks that stand out from the beat around them), energy
///    moments from the loudness curves, sections from a beat-synchronous self-similarity
///    matrix (Foote novelty), labelled by clustering the segments.
enum SongAnalyzer {
    /// Bump when results would change, so cached analyses are redone.
    static let version = 1

    struct Options {
        var beatsPerBar = 4
        /// The track's own grid. Hits snap to it and sections are counted on it; when nil the
        /// detected tempo is used and offered as a new grid.
        var grid: BeatGrid?
        var minBPM = 70.0
        var maxBPM = 180.0
    }

    /// Reads the file and analyses it off the main thread. Cancelling the calling task stops it.
    /// `excludingChannel` is the LTC channel index (0 left, 1 right), nil to use every channel.
    static func analyse(url: URL, excludingChannel: Int?, options: Options = .init(),
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> SongAnalysis {
        let task = Task.detached(priority: .userInitiated) { () throws -> SongAnalysis in
            let start = Date()
            let (samples, rate) = try TempoDetector.readProgramme(url: url, excludingChannel: excludingChannel,
                                                                  progress: { progress?($0 * 0.35) })
            var r = try analyse(samples: samples, sampleRate: rate, options: options,
                                progress: { progress?(0.35 + $0 * 0.65) })
            r.elapsed = Date().timeIntervalSince(start)
            return r
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func analyse(samples: [Float], sampleRate sr: Double, options: Options = .init(),
                        progress: ((Double) -> Void)? = nil) throws -> SongAnalysis {
        let started = Date()
        let duration = Double(samples.count) / sr
        guard duration > 6 else { throw TempoDetector.Failure.tooShort }

        // 1. Tempo (kept only when it's believable).
        var tempoOptions = TempoDetector.Options()
        tempoOptions.beatsPerBar = options.beatsPerBar
        tempoOptions.minBPM = options.minBPM; tempoOptions.maxBPM = options.maxBPM
        let tempo = try? TempoDetector.analyse(samples: samples, sampleRate: sr, options: tempoOptions)
        try cancelled()
        progress?(0.3)
        let detected = tempo.flatMap { $0.confidence >= 0.2 ? $0.grid : nil }
        let grid = options.grid ?? detected

        // 2–3. Features.
        let fine = try finePass(samples, sr: sr)
        progress?(0.6)
        let coarse = try coarsePass(samples, sr: sr)
        progress?(0.8)

        // Where the music is.
        let level = fine.level
        let loud = percentile(level, 0.95)
        let silence = max(-62, loud - 45)
        let firstLoud = level.firstIndex(where: { $0 > silence + 6 }) ?? 0
        let lastLoud = level.lastIndex(where: { $0 > silence + 6 }) ?? max(0, level.count - 1)
        let musicStart = fine.time(firstLoud), musicEnd = min(duration, fine.time(lastLoud))

        var moments: [SongMoment] = []
        let stops = findStops(fine, silence: silence, music: musicStart...max(musicStart, musicEnd))
        moments += stops
        let builds = findBuilds(coarse, grid: grid, music: musicStart...max(musicStart, musicEnd))
        moments += builds.map(\.moment)
        moments += findDrops(coarse, fine: fine, grid: grid, builds: builds, stops: stops,
                             music: musicStart...max(musicStart, musicEnd))
        moments += findBreakdowns(coarse, grid: grid, silence: silence, stops: stops,
                                  music: musicStart...max(musicStart, musicEnd))
        moments += findHits(fine, grid: grid, music: musicStart...max(musicStart, musicEnd))
        try cancelled()
        progress?(0.9)
        moments += SongSections.find(coarse: coarse, grid: grid, music: musicStart...max(musicStart, musicEnd))
        progress?(1)

        var offered = options.grid == nil ? detected : nil
        let result = SongAnalysis(version: version, duration: duration, grid: nil, tempoConfidence: tempo?.confidence,
                                  moments: moments.sorted { $0.time < $1.time }, elapsed: Date().timeIntervalSince(started),
                                  musicStart: musicStart, musicEnd: musicEnd)
        if let g = offered { offered = result.gridWithSections(base: g) }
        var out = result
        out.grid = offered
        return out
    }

    private static func cancelled() throws { if Task.isCancelled { throw CancellationError() } }

    // MARK: - Fine pass (onsets, level)

    struct Fine {
        /// Onset strength, ≥ 0, about 1 for a strong onset (sum of three normalised curves).
        var odf: [Float]
        /// HFC-weighted flux alone (cymbals, crashes), normalised.
        var hfc: [Float]
        /// Level in dBFS of each hop (time-domain mean square).
        var level: [Float]
        var fps: Double
        var t0: Double
        func time(_ k: Int) -> TimeInterval { t0 + Double(k) / fps }
        func frame(_ t: TimeInterval) -> Int { Int(((t - t0) * fps).rounded()) }
    }

    static let fineSize = 512, fineHop = 64
    /// Onset-curve peak vs true attack, measured on synthetic clicks and drums.
    static let onsetLatency: TimeInterval = 0.008

    static func finePass(_ x: [Float], sr: Double) throws -> Fine {
        let n = fineSize, half = n / 2, hop = fineHop, log2n = vDSP_Length(9)
        guard x.count > n * 4 else { throw TempoDetector.Failure.tooShort }
        let frames = (x.count - n) / hop + 1
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw TempoDetector.Failure.unreadable }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        func buf(_ c: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: c); p.initialize(repeating: 0, count: c); return p
        }
        let frame = buf(n), re = buf(half), im = buf(half), tmp = buf(half), maxf = buf(half), diff = buf(half)
        var cur = buf(half), p1 = buf(half), p2 = buf(half)
        let weight = buf(half)
        for i in 0..<half { weight[i] = Float(i) / Float(half) }
        defer { for b in [frame, re, im, tmp, maxf, diff, cur, p1, p2, weight] { b.deallocate() } }
        var sf = [Float](repeating: 0, count: frames), hf = [Float](repeating: 0, count: frames)
        var lo = [Float](repeating: 0, count: frames), level = [Float](repeating: -120, count: frames)
        let lowBins = max(2, min(half, Int(150 / (sr / Double(n))) + 1))
        var count = Int32(half), zero: Float = 0, gain: Float = 100
        var split = DSPSplitComplex(realp: re, imagp: im)
        let len = vDSP_Length(half)
        try x.withUnsafeBufferPointer { s in
            let base = s.baseAddress!
            for k in 0..<frames {
                if k & 4095 == 0, Task.isCancelled { throw CancellationError() }
                let at = base + k * hop
                var ms: Float = 0
                vDSP_measqv(at + (n - hop) / 2, 1, &ms, vDSP_Length(hop))
                level[k] = 10 * log10f(ms + 1e-12)
                vDSP_vmul(at, 1, window, 1, frame, 1, vDSP_Length(n))
                frame.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, len) }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                re[0] = 0; im[0] = 0
                vDSP_zvabs(&split, 1, cur, 1, len)
                vDSP_vsmul(cur, 1, &gain, cur, 1, len)
                vvlog1pf(cur, cur, &count)
                if k >= 2 {
                    // SuperFlux: against the frame two back, max-filtered over ±1 bin.
                    vDSP_vmax(p2, 1, p2 + 1, 1, tmp, 1, len - 1)
                    vDSP_vmax(tmp, 1, tmp + 1, 1, maxf + 1, 1, len - 2)
                    maxf[0] = tmp[0]; maxf[half - 1] = tmp[half - 2]
                    vDSP_vsub(maxf, 1, cur, 1, diff, 1, len)
                    vDSP_vthr(diff, 1, &zero, diff, 1, len)
                    var a: Float = 0; vDSP_sve(diff, 1, &a, len); sf[k] = a
                    // Plain flux (one frame back) for HFC weighting and the low band.
                    vDSP_vsub(p1, 1, cur, 1, diff, 1, len)
                    vDSP_vthr(diff, 1, &zero, diff, 1, len)
                    var h: Float = 0; vDSP_dotpr(diff, 1, weight, 1, &h, len); hf[k] = h
                    var l: Float = 0; vDSP_sve(diff + 1, 1, &l, vDSP_Length(lowBins - 1)); lo[k] = l
                }
                let old = p2; p2 = p1; p1 = cur; cur = old
            }
        }
        let fps = sr / Double(hop)
        sf = normalised(removeFloor(sf, radius: Int(fps * 0.12)))
        hf = normalised(removeFloor(hf, radius: Int(fps * 0.12)))
        lo = normalised(removeFloor(lo, radius: Int(fps * 0.12)))
        var sum = [Float](repeating: 0, count: frames), odf = sum
        var half05: Float = 0.5
        vDSP_vadd(sf, 1, hf, 1, &sum, 1, vDSP_Length(frames))
        vDSP_vsma(lo, 1, &half05, sum, 1, &odf, 1, vDSP_Length(frames))
        return Fine(odf: odf, hfc: hf, level: level, fps: fps, t0: Double(n / 2) / sr + onsetLatency)
    }

    // MARK: - Coarse pass (loudness, timbre, harmony)

    struct Coarse {
        /// Loudness of each block, dBFS.
        var level: [Float]
        /// Level below 150 Hz, dB (relative).
        var bass: [Float]
        /// Spectral centroid, octaves above 100 Hz.
        var brightness: [Float]
        /// `dims` values per block: 12 chroma, then 12 cepstral coefficients.
        var features: [Float]
        var dims: Int
        var bps: Double
        var t0: Double
        var count: Int { level.count }
        func time(_ i: Int) -> TimeInterval { t0 + Double(i) / bps }
        func block(_ t: TimeInterval) -> Int { Int(((t - t0) * bps).rounded()) }
    }

    static let coarseSize = 4096, coarseHop = 1024, chromaDims = 12, cepstrumDims = 12, bandCount = 24

    static func coarsePass(_ x: [Float], sr: Double) throws -> Coarse {
        let n = coarseSize, half = n / 2, hop = coarseHop, log2n = vDSP_Length(12)
        guard x.count > n else { throw TempoDetector.Failure.tooShort }
        let blocks = (x.count - n) / hop + 1
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw TempoDetector.Failure.unreadable }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = sr / Double(n)

        // Chroma weights (magnitude, 80 Hz…3 kHz) and log-band weights (power, 50 Hz…5 kHz).
        var wChroma = [Float](repeating: 0, count: half * chromaDims)       // half × 12, row-major
        var wBands = [Float](repeating: 0, count: half * bandCount)          // half × 24
        var freqs = [Float](repeating: 0, count: half)
        let lowEdge = 50.0, highEdge = min(5000, sr / 2 * 0.95)
        for k in 1..<half {
            let f = Double(k) * binHz
            freqs[k] = Float(f)
            if f >= 80, f <= 3000 {
                let midi = 69 + 12 * log2(f / 440)
                let pc = Int(midi.rounded()) % 12
                // Narrow bump around each semitone centre so in-between bins count less.
                let off = abs(midi - midi.rounded())
                wChroma[k * chromaDims + (pc + 12) % 12] = Float(cos(.pi * off) * 0.5 + 0.5)
            }
            if f >= lowEdge, f < highEdge {
                let b = Int(Double(bandCount) * log(f / lowEdge) / log(highEdge / lowEdge))
                if b >= 0, b < bandCount { wBands[k * bandCount + b] = 1 }
            }
        }
        // DCT-II rows 1…12 of the 24 log bands.
        var dct = [Float](repeating: 0, count: cepstrumDims * bandCount)
        for c in 0..<cepstrumDims {
            for b in 0..<bandCount {
                dct[c * bandCount + b] = Float(cos(.pi * Double(c + 1) * (Double(b) + 0.5) / Double(bandCount)))
            }
        }
        let bassBins = max(2, Int(150 / binHz))
        let dims = chromaDims + cepstrumDims
        var level = [Float](repeating: -120, count: blocks), bass = level
        var bright = [Float](repeating: 0, count: blocks)
        var features = [Float](repeating: 0, count: blocks * dims)
        let frame = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let re = UnsafeMutablePointer<Float>.allocate(capacity: half), im = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let mag = UnsafeMutablePointer<Float>.allocate(capacity: half), pow = UnsafeMutablePointer<Float>.allocate(capacity: half)
        var chroma = [Float](repeating: 0, count: chromaDims), bandsRaw = [Float](repeating: 0, count: bandCount)
        var bands = bandsRaw, logBands = bandsRaw
        var ceps = [Float](repeating: 0, count: cepstrumDims)
        defer { for b in [frame, re, im, mag, pow] { b.deallocate() } }
        var split = DSPSplitComplex(realp: re, imagp: im)
        let len = vDSP_Length(half)
        var bandN = Int32(bandCount)
        try x.withUnsafeBufferPointer { s in
            let base = s.baseAddress!
            for i in 0..<blocks {
                if i & 511 == 0, Task.isCancelled { throw CancellationError() }
                let at = base + i * hop
                var ms: Float = 0
                vDSP_measqv(at + (n - hop) / 2, 1, &ms, vDSP_Length(hop))
                level[i] = 10 * log10f(ms + 1e-12)
                vDSP_vmul(at, 1, window, 1, frame, 1, vDSP_Length(n))
                frame.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, len) }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                re[0] = 0; im[0] = 0
                vDSP_zvmags(&split, 1, pow, 1, len)
                vvsqrtf(mag, pow, [Int32(half)])
                var total: Float = 0, low: Float = 0, fw: Float = 0
                vDSP_sve(pow, 1, &total, len)
                vDSP_sve(pow + 1, 1, &low, vDSP_Length(bassBins))
                vDSP_dotpr(pow, 1, freqs, 1, &fw, len)
                bass[i] = 10 * log10f(low + 1e-9)
                bright[i] = total > 1e-9 ? Float(log2(max(100, Double(fw / total)) / 100)) : 0
                vDSP_mmul(mag, 1, wChroma, 1, &chroma, 1, 1, vDSP_Length(chromaDims), len)
                vDSP_mmul(pow, 1, wBands, 1, &bandsRaw, 1, 1, vDSP_Length(bandCount), len)
                var eps: Float = 1e-6
                vDSP_vsadd(bandsRaw, 1, &eps, &bands, 1, vDSP_Length(bandCount))
                vvlog10f(&logBands, bands, &bandN)
                vDSP_mmul(dct, 1, logBands, 1, &ceps, 1, vDSP_Length(cepstrumDims), 1, vDSP_Length(bandCount))
                // Chroma as a distribution (level-independent).
                var csum: Float = 0
                vDSP_sve(chroma, 1, &csum, vDSP_Length(chromaDims))
                features.withUnsafeMutableBufferPointer { f in
                    let row = f.baseAddress! + i * dims
                    if csum > 1e-6 { var inv = 1 / csum; vDSP_vsmul(chroma, 1, &inv, row, 1, vDSP_Length(chromaDims)) }
                    for c in 0..<cepstrumDims { row[chromaDims + c] = ceps[c] }
                }
            }
        }
        let bps = sr / Double(hop)
        return Coarse(level: level, bass: bass, brightness: bright, features: features, dims: dims, bps: bps,
                      t0: Double(n / 2) / sr)
    }

    // MARK: - Hits

    static func findHits(_ f: Fine, grid: BeatGrid?, music: ClosedRange<TimeInterval>) -> [SongMoment] {
        let o = f.odf, N = o.count
        let w = max(2, Int(0.05 * f.fps))
        // Local maxima above a small floor.
        var peaks: [(k: Int, v: Float)] = []
        var k = w
        while k < N - w {
            let v = o[k]
            if v > 0.08 {
                var isMax = true
                for j in (k - w)...(k + w) where o[j] > v || (o[j] == v && j < k) { isMax = false; break }
                if isMax { peaks.append((k, v)); k += w; continue }
            }
            k += 1
        }
        guard peaks.count >= 4 else { return [] }
        let globalTop = max(1e-3, percentile(peaks.map(\.v), 0.99))
        let ctxFloor = max(1e-3, percentile(peaks.map(\.v), 0.5))
        // Context skips the candidate's own decay (a crash's noise tail makes onset peaks of its own).
        let reach = Int(4 * f.fps), skipBefore = Int(0.12 * f.fps), skipAfter = Int(0.6 * f.fps)
        var out: [SongMoment] = []
        var lo = 0
        for (i, p) in peaks.enumerated() {
            let t = f.time(p.k)
            guard music.contains(t) else { continue }
            while lo < peaks.count, peaks[lo].k < p.k - reach { lo += 1 }
            var ctx: [Float] = []
            var j = lo
            while j < peaks.count, peaks[j].k <= p.k + reach {
                let d = peaks[j].k - p.k
                if d < -skipBefore || d > skipAfter { ctx.append(peaks[j].v) }
                j += 1
            }
            // "The regular loud events around it": the 80th percentile of the neighbours…
            var context = max(ctxFloor * 0.5, ctx.isEmpty ? ctxFloor : percentile(ctx, 0.8))
            // …or, on the grid, what this same beat position usually sounds like two bars either side.
            if let g = grid, abs(g.snap(t, mode: .half) - t) <= 0.035 {
                let on = g.snap(t, mode: .half), r = 4
                var same: [Float] = []
                for b in [-2, -1, 1, 2] {
                    let fr = f.frame(on + Double(b) * g.barLength)
                    if fr - r >= 0, fr + r < N { same.append(o[(fr - r)...(fr + r)].max() ?? 0) }
                }
                if same.count >= 2 {
                    same.sort()
                    let mid = (same[(same.count - 1) / 2] + same[same.count / 2]) / 2
                    context = max(ctxFloor * 0.5, mid)
                }
            }
            let contrast = Double(p.v / context)
            let absolute = Double(min(1, p.v / globalTop))
            var strength = 0.7 * clamp((contrast - 1.25) / 1.25) + 0.3 * absolute
            var time = t
            var onDownbeat = false
            if let g = grid {
                let s = g.snap(t, mode: .half)
                if abs(s - t) <= 0.035 { time = s }
                if abs(g.snap(time, mode: .beat) - time) < 0.001, g.barBeat(at: time).beat == 1 { onDownbeat = true }
            }
            if onDownbeat { strength += 0.1 }
            strength = clamp(strength)
            guard strength >= 0.12 else { continue }
            let detail = onDownbeat ? "Accent on the downbeat of bar \(grid!.barBeat(at: time).bar), louder than the beat around it."
                                    : "Accent that stands out from the beat around it."
            out.append(SongMoment(time: time, kind: .hit, strength: strength, label: "Hit",
                                  cueTypeName: SongMoment.Kind.hit.suggestedTypeName, detail: detail))
        }
        return suppress(out, within: 0.15)
    }

    // MARK: - Stops

    static func findStops(_ f: Fine, silence: Float, music: ClosedRange<TimeInterval>) -> [SongMoment] {
        let lv = f.level, N = lv.count
        let minRun = Int(0.25 * f.fps)
        var out: [SongMoment] = []
        var k = 0
        while k < N {
            guard lv[k] < silence else { k += 1; continue }
            var e = k
            while e < N, lv[e] < silence + 3 { e += 1 }
            let start = f.time(k) - onsetLatency          // level frames are hop-centred
            let run = e - k
            if run >= minRun, f.time(k) > music.lowerBound + 0.5, f.time(e) < music.upperBound {
                let preA = max(0, k - Int(0.4 * f.fps)), preB = max(preA + 1, k - Int(0.05 * f.fps))
                let pre = lv[preA..<preB].max() ?? silence
                let depth = Double(pre - silence)
                let length = Double(run) / f.fps
                let strength = clamp(depth / 30) * (0.55 + 0.45 * clamp((length - 0.25) / 0.75))
                if strength >= 0.15 {
                    out.append(SongMoment(time: max(0, start), kind: .stop, strength: strength, label: "Stop",
                                          cueTypeName: SongMoment.Kind.stop.suggestedTypeName,
                                          detail: String(format: "The music stops for %.1f s.", length)))
                }
            }
            k = max(e, k + 1)
        }
        return out
    }

    // MARK: - Builds

    /// Build moments with the time each ramp ends.
    static func findBuilds(_ c: Coarse, grid: BeatGrid?, music: ClosedRange<TimeInterval>) -> [(moment: SongMoment, end: TimeInterval)] {
        let N = c.count
        guard N > 40 else { return [] }
        // Tension: loudness plus brightness (risers rise in pitch and noise), smoothed over 1 s.
        let lv = movingAverage(c.level, radius: Int(c.bps * 0.5))
        let br = movingAverage(c.brightness, radius: Int(c.bps * 0.5))
        let y = zip(lv, br).map { Double($0) + 6 * Double($1) }
        var P = [Double](repeating: 0, count: N + 1), Q = P, R = P
        for j in 0..<N { P[j + 1] = P[j] + y[j]; Q[j + 1] = Q[j] + Double(j) * y[j]; R[j + 1] = R[j] + y[j] * y[j] }
        struct Cand { var a: Int; var b: Int; var rise: Double; var fit: Double; var score: Double }
        var cands: [Cand] = []
        let durations = [3.0, 5.0, 8.0, 12.0, 20.0].map { Int($0 * c.bps) }
        let second = Int(c.bps)
        let lo = max(0, c.block(music.lowerBound)), hi = min(N, c.block(music.upperBound))
        for a in lo..<max(lo, hi) {
            var best: Cand?
            for d in durations {
                let b = a + d
                guard b <= hi else { break }
                let n = Double(d)
                let sx = n * (n - 1) / 2, sxx = (n - 1) * n * (2 * n - 1) / 6
                let sy = P[b] - P[a], sxy = Q[b] - Q[a] - Double(a) * sy, syy = R[b] - R[a]
                let den = n * sxx - sx * sx, num = n * sxy - sx * sy
                let vy = n * syy - sy * sy
                guard den > 0, vy > 1e-9 else { continue }
                let slope = num / den
                let rise = slope * (n - 1)
                let r2 = num * num / (den * vy)
                guard rise >= 5, r2 >= 0.75, slope > 0 else { continue }
                // Gradual, not a step: no single second carries more than half the rise.
                var jump = 0.0
                var j = a
                while j + second < b { jump = max(jump, y[j + second] - y[j]); j += max(1, second / 4) }
                guard jump <= rise * 0.5 else { continue }
                let score = rise * r2
                if best == nil || score > best!.score { best = Cand(a: a, b: b, rise: rise, fit: r2, score: score) }
            }
            if let best { cands.append(best) }
        }
        // Keep the strongest non-overlapping ramps; a ramp starts where its earliest strong start is.
        var taken: [Cand] = []
        for cnd in cands.sorted(by: { $0.score > $1.score }) where !taken.contains(where: { cnd.a < $0.b && $0.a < cnd.b }) {
            taken.append(cnd)
        }
        return taken.map { cnd in
            // The build starts at the low point before the climb (drums often thin out there).
            var start = cnd.a
            for j in cnd.a..<(cnd.a + (cnd.b - cnd.a) * 6 / 10) where y[j] < y[start] { start = j }
            var t = c.time(start)
            if let g = grid { t = snapMusical(t, grid: g) }
            let len = Double(cnd.b - cnd.a) / c.bps
            let m = SongMoment(time: max(0, t), kind: .build, strength: clamp(cnd.rise / 14) * cnd.fit, label: "Build",
                               cueTypeName: SongMoment.Kind.build.suggestedTypeName,
                               detail: String(format: "Energy rises steadily for %.0f s.", len))
            return (moment: m, end: c.time(cnd.b))
        }.sorted { $0.moment.time < $1.moment.time }
    }

    // MARK: - Drops

    static func findDrops(_ c: Coarse, fine: Fine, grid: BeatGrid?, builds: [(moment: SongMoment, end: TimeInterval)], stops: [SongMoment],
                          music: ClosedRange<TimeInterval>) -> [SongMoment] {
        let N = c.count
        let lv = movingAverage(c.level, radius: 2), bs = movingAverage(c.bass, radius: 2)
        let w = Int(2 * c.bps)
        guard N > 2 * w + 2 else { return [] }
        let ma = min(N - 1, max(0, c.block(music.lowerBound))), mb = max(ma + 1, min(N, c.block(music.upperBound)))
        let loudRef = percentile(Array(lv[ma..<mb]), 0.75)
        var P = [Double](repeating: 0, count: N + 1), B = P
        for j in 0..<N { P[j + 1] = P[j] + Double(lv[j]); B[j + 1] = B[j] + Double(bs[j]) }
        func mean(_ S: [Double], _ a: Int, _ b: Int) -> Double { (S[b] - S[a]) / Double(max(1, b - a)) }
        var jumps = [Double](repeating: 0, count: N), bassJ = jumps
        for i in w..<(N - w) {
            jumps[i] = mean(P, i, i + w) - mean(P, i - w, i)
            bassJ[i] = mean(B, i, i + w) - mean(B, i - w, i)
        }
        var out: [SongMoment] = []
        let near = Int(2 * c.bps)
        for i in w..<(N - w) {
            let j = jumps[i]
            guard j >= 4 else { continue }
            let lo = max(w, i - near), hi = min(N - w - 1, i + near)
            guard !(lo...hi).contains(where: { jumps[$0] > j || (jumps[$0] == j && $0 < i) }) else { continue }
            let t0 = c.time(i)
            guard music.contains(t0), mean(P, i, i + w) >= Double(loudRef) - 4 else { continue }
            // It stays up: 2–4 s later is still well above before (a crash alone decays away).
            guard i + 2 * w <= N, mean(P, i + w, i + 2 * w) - mean(P, i - w, i) >= 3 else { continue }
            // A build that was still rising within 3 s of this jump.
            let afterBuild = builds.contains { b in b.moment.time < t0 && b.end > t0 - 3 }
            let afterStop = stops.contains { $0.time < t0 && t0 - $0.time < 2.5 }
            var s = 0.6 * clamp(j / 12) + 0.2 * clamp(bassJ[i] / 15)
            if afterBuild { s += 0.2 }
            if afterStop { s += 0.1 }
            // Land on the strongest onset nearby, then on the bar (or beat) it belongs to.
            var t = strongestOnset(fine, near: t0, reach: 0.35) ?? t0
            if let g = grid { t = snapMusical(t, grid: g) }
            let why = afterBuild ? "Big rise in energy after a build." : (afterStop ? "The band comes back in hard after a stop." : "Big rise in energy.")
            out.append(SongMoment(time: max(0, t), kind: .drop, strength: clamp(s), label: "Drop",
                                  cueTypeName: SongMoment.Kind.drop.suggestedTypeName,
                                  detail: why + String(format: " About %.0f dB louder.", j)))
        }
        return suppress(out, within: 6)
    }

    // MARK: - Breakdowns

    static func findBreakdowns(_ c: Coarse, grid: BeatGrid?, silence: Float, stops: [SongMoment],
                               music: ClosedRange<TimeInterval>) -> [SongMoment] {
        let N = c.count
        let lv = movingAverage(c.level, radius: 2), bs = movingAverage(c.bass, radius: 2)
        let w = Int(4 * c.bps)
        guard N > 2 * w + 2 else { return [] }
        var P = [Double](repeating: 0, count: N + 1), B = P
        for j in 0..<N { P[j + 1] = P[j] + Double(lv[j]); B[j + 1] = B[j] + Double(bs[j]) }
        func mean(_ S: [Double], _ a: Int, _ b: Int) -> Double { (S[b] - S[a]) / Double(max(1, b - a)) }
        var falls = [Double](repeating: 0, count: N), bassF = falls
        for i in w..<(N - w) {
            falls[i] = mean(P, i, i + w) - mean(P, i - w, i)
            bassF[i] = mean(B, i, i + w) - mean(B, i - w, i)
        }
        var out: [SongMoment] = []
        let near = Int(4 * c.bps), half = Int(0.5 * c.bps)
        for i in w..<(N - w) {
            let f = falls[i]
            guard f <= -5 else { continue }
            let lo = max(w, i - near), hi = min(N - w - 1, i + near)
            guard !(lo...hi).contains(where: { falls[$0] < f || (falls[$0] == f && $0 < i) }) else { continue }
            let t0 = c.time(i)
            // A breakdown keeps playing (quieter); silence is a stop, and the song's end isn't one.
            guard music.contains(t0), t0 + 6 < music.upperBound, mean(P, i, i + w) > Double(silence) + 12 else { continue }
            guard !stops.contains(where: { abs($0.time - t0) < 1.5 }) else { continue }
            // Sharpest fall within ±1.5 s.
            var best = i, steep = 0.0
            for j in max(half, i - Int(1.5 * c.bps))...min(N - half - 1, i + Int(1.5 * c.bps)) {
                let d = Double(lv[j + half] - lv[j - half])
                if d < steep { steep = d; best = j }
            }
            var t = c.time(best)
            if let g = grid { t = snapMusical(t, grid: g) }
            let s = 0.75 * clamp(-f / 12) + 0.25 * clamp(-bassF[i] / 18)
            out.append(SongMoment(time: max(0, t), kind: .breakdown, strength: clamp(s), label: "Breakdown",
                                  cueTypeName: SongMoment.Kind.breakdown.suggestedTypeName,
                                  detail: String(format: "Energy falls by about %.0f dB and stays down.", -f)))
        }
        return suppress(out, within: 8)
    }

    // MARK: - Helpers

    /// Onto the nearest bar line when one is within a beat, else onto the nearest beat.
    static func snapMusical(_ t: TimeInterval, grid g: BeatGrid) -> TimeInterval {
        let bar = g.snap(t, mode: .bar)
        if abs(bar - t) <= g.beatLength * 1.01 { return bar }
        return g.snap(t, mode: .beat)
    }

    static func strongestOnset(_ f: Fine, near t: TimeInterval, reach: TimeInterval) -> TimeInterval? {
        let a = max(0, f.frame(t - reach)), b = min(f.odf.count - 1, f.frame(t + reach))
        guard a < b else { return nil }
        var m = a
        for k in a...b where f.odf[k] > f.odf[m] { m = k }
        return f.odf[m] > 0.1 ? f.time(m) : nil
    }

    /// Keeps the strongest of any moments closer than `within` seconds.
    static func suppress(_ ms: [SongMoment], within: TimeInterval) -> [SongMoment] {
        var kept: [SongMoment] = []
        for m in ms.sorted(by: { $0.strength > $1.strength }) where !kept.contains(where: { abs($0.time - m.time) < within }) {
            kept.append(m)
        }
        return kept.sorted { $0.time < $1.time }
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    static func percentile(_ x: [Float], _ q: Double) -> Float {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * q)))]
    }

    /// Divides by the 99th percentile of the non-zero values (robust to a few huge spikes).
    static func normalised(_ x: [Float]) -> [Float] {
        let nz = x.filter { $0 > 0 }
        guard !nz.isEmpty else { return x }
        var s = 1 / max(1e-9, percentile(nz, 0.99))
        var out = x
        vDSP_vsmul(x, 1, &s, &out, 1, vDSP_Length(x.count))
        return out
    }

    /// Subtracts a centred moving mean (radius `radius`), clipped at 0.
    static func removeFloor(_ x: [Float], radius: Int) -> [Float] {
        let m = movingAverage(x, radius: max(1, radius))
        var out = [Float](repeating: 0, count: x.count), zero: Float = 0
        vDSP_vsub(m, 1, x, 1, &out, 1, vDSP_Length(x.count))
        vDSP_vthr(out, 1, &zero, &out, 1, vDSP_Length(x.count))
        return out
    }

    static func movingAverage(_ x: [Float], radius r: Int) -> [Float] {
        let n = x.count
        guard n > 0, r > 0 else { return x }
        var cum = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { cum[i + 1] = cum[i] + Double(x[i]) }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - r), b = min(n, i + r + 1)
            out[i] = Float((cum[b] - cum[a]) / Double(b - a))
        }
        return out
    }
}
