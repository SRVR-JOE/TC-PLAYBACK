import Foundation
import AVFoundation
import Accelerate

/// Offline tempo and beat-phase detection for a track's programme audio.
///
/// 1. Read the file, sum every channel except the LTC one, decimate to ~11 kHz.
/// 2. Onset strength: spectral flux of log-compressed magnitude (512-point FFT, 64-sample
///    hop ≈ 5.8 ms), minus a local mean, half-wave rectified.
/// 3. Tempo in `minBPM…maxBPM`: a windowed Fourier tempogram (8 s windows, so a slightly
///    wandering tempo still scores) times an autocorrelation comb (sum of the first four lag
///    multiples) times a mild log-normal prior around 120 BPM. The Fourier term can't tell a
///    tempo from its double and the comb can't tell it from its half; their product can —
///    that's the octave correction.
/// 4. Refinement: the full-length coherent Fourier sum is swept ±1.5 BPM in 0.01 BPM steps
///    for a first tempo and phase, then a weighted least-squares line through the onset
///    peak nearest each predicted beat (sub-frame, outliers dropped) pins both.
/// 5. Downbeat: the beat-in-bar with the most low-band (kick) and overall onset energy,
///    placed at the first downbeat after the music starts.
///
/// Known limit: slow songs with loud straight 8ths (e.g. 75 BPM with 8th-note hats) can read
/// as double time; the panel's ×2 / ÷2 buttons fix that in one tap.
enum TempoDetector {
    struct Options {
        var minBPM = 70.0
        var maxBPM = 180.0
        var beatsPerBar = 4
        var targetRate = 11_025.0
        /// Analyse at most this many seconds (from the start). 0 = whole file.
        var maxSeconds: TimeInterval = 0
    }

    struct Result {
        var grid: BeatGrid
        /// 0…1. Low when the onsets are weak or another tempo scores nearly as well.
        var confidence: Double
        /// How much of the onset energy lines up with the grid (0…1, phase-coherent).
        var coherence: Double
        /// Wall time of the analysis.
        var elapsed: TimeInterval
    }

    enum Failure: LocalizedError {
        case unreadable, tooShort, noBeat
        var errorDescription: String? {
            switch self {
            case .unreadable: "The audio file couldn't be read."
            case .tooShort: "The track is too short to find a tempo."
            case .noBeat: "No steady beat was found."
            }
        }
    }

    /// Detects off the main thread. Cancelling the calling task stops the analysis.
    /// `excludingChannel` is the LTC channel index (0 left, 1 right), nil to use every channel.
    static func detect(url: URL, excludingChannel: Int?, options: Options = .init(),
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> Result {
        let task = Task.detached(priority: .userInitiated) { () throws -> Result in
            let start = Date()
            let (samples, rate) = try readProgramme(url: url, excludingChannel: excludingChannel,
                                                    targetRate: options.targetRate, maxSeconds: options.maxSeconds,
                                                    progress: { progress?($0 * 0.6) })
            var r = try analyse(samples: samples, sampleRate: rate, options: options,
                                progress: { progress?(0.6 + $0 * 0.4) })
            r.elapsed = Date().timeIntervalSince(start)
            return r
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    // MARK: Reading

    /// Mono programme mix, box-filtered and decimated to the integer factor nearest `targetRate`.
    static func readProgramme(url: URL, excludingChannel: Int?, targetRate: Double = 11_025, maxSeconds: TimeInterval = 0,
                              progress: ((Double) -> Void)? = nil) throws -> (samples: [Float], rate: Double) {
        guard let f = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let fmt = f.processingFormat
        let sr = fmt.sampleRate, chs = Int(fmt.channelCount)
        let d = max(1, Int((sr / targetRate).rounded()))
        var use = (0..<chs).filter { $0 != excludingChannel }
        if use.isEmpty { use = [0] }
        let total = maxSeconds > 0 ? min(f.length, AVAudioFramePosition(maxSeconds * sr)) : f.length
        let chunk = AVAudioFrameCount(d * 16_384)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw Failure.unreadable }
        var out = [Float](); out.reserveCapacity(Int(total) / d + 1)
        var mix = [Float](repeating: 0, count: Int(chunk))
        let filter = [Float](repeating: 1 / Float(d * use.count), count: d)
        while f.framePosition < total {
            if Task.isCancelled { throw CancellationError() }
            let want = AVAudioFrameCount(min(Int64(chunk), total - f.framePosition))
            do { try f.read(into: buf, frameCount: want) } catch { break }
            let n = Int(buf.frameLength)
            guard n > 0, let data = buf.floatChannelData else { break }
            mix.withUnsafeMutableBufferPointer { m in
                m.baseAddress!.update(from: data[use[0]], count: n)
                for c in use.dropFirst() { vDSP_vadd(m.baseAddress!, 1, data[c], 1, m.baseAddress!, 1, vDSP_Length(n)) }
            }
            let outN = n / d
            if outN > 0 {
                let base = out.count
                out.append(contentsOf: repeatElement(0, count: outN))
                out.withUnsafeMutableBufferPointer { o in
                    vDSP_desamp(mix, vDSP_Stride(d), filter, o.baseAddress! + base, vDSP_Length(outN), vDSP_Length(d))
                }
            }
            progress?(Double(f.framePosition) / Double(max(1, total)))
        }
        return (out, sr / Double(d))
    }

    // MARK: Onsets

    static let fftSize = 512
    static let hop = 64

    /// Spectral-flux onset envelope (≥ 0), the same for the band below ~200 Hz (kick drum;
    /// used to find the downbeat), and the frame rate. Frame `k` is centred at
    /// `(k·hop + fftSize/2) / rate` seconds.
    static func onsetEnvelope(samples: [Float], sampleRate: Double) throws -> (env: [Float], low: [Float], fps: Double) {
        let n = fftSize, half = n / 2, log2n = vDSP_Length(9)
        guard samples.count > n * 4 else { throw Failure.tooShort }
        let frames = (samples.count - n) / hop + 1
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw Failure.unreadable }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        // Scratch buffers as raw pointers so the in-place vDSP calls don't trip exclusivity checks.
        let frame = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let re = UnsafeMutablePointer<Float>.allocate(capacity: half), im = UnsafeMutablePointer<Float>.allocate(capacity: half)
        var mag = UnsafeMutablePointer<Float>.allocate(capacity: half), prev = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let diff = UnsafeMutablePointer<Float>.allocate(capacity: half)
        prev.initialize(repeating: 0, count: half)
        defer { for b in [frame, re, im, mag, prev, diff] { b.deallocate() } }
        var flux = [Float](repeating: 0, count: frames), lowFlux = [Float](repeating: 0, count: frames)
        let lowBins = max(2, min(half, Int(200 / (sampleRate / Double(n))) + 1))
        var count = Int32(half)
        var zero: Float = 0, gain: Float = 100
        var split = DSPSplitComplex(realp: re, imagp: im)
        let len = vDSP_Length(half)
        try samples.withUnsafeBufferPointer { s in
            for k in 0..<frames {
                if k & 4095 == 0, Task.isCancelled { throw CancellationError() }
                vDSP_vmul(s.baseAddress! + k * hop, 1, window, 1, frame, 1, vDSP_Length(n))
                frame.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, len) }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                re[0] = 0; im[0] = 0                                // drop DC (and the packed Nyquist)
                vDSP_zvabs(&split, 1, mag, 1, len)
                vDSP_vsmul(mag, 1, &gain, mag, 1, len)
                vvlog1pf(mag, mag, &count)
                vDSP_vsub(prev, 1, mag, 1, diff, 1, len)           // mag − prev
                vDSP_vthr(diff, 1, &zero, diff, 1, len)
                var sum: Float = 0
                vDSP_sve(diff, 1, &sum, len)
                var low: Float = 0
                vDSP_sve(diff + 1, 1, &low, vDSP_Length(lowBins - 1))
                flux[k] = k == 0 ? 0 : sum
                lowFlux[k] = k == 0 ? 0 : low
                swap(&prev, &mag)
            }
        }
        let fps = sampleRate / Double(hop)
        return (removeFloor(flux, fps: fps), removeFloor(lowFlux, fps: fps), fps)
    }

    /// Removes the slow floor (sustained noise, pads): subtract a ~0.25 s centred mean, clip at 0.
    private static func removeFloor(_ x: [Float], fps: Double) -> [Float] {
        let frames = x.count
        let r = max(3, Int(fps * 0.25)) / 2
        var cum = [Double](repeating: 0, count: frames + 1)
        for i in 0..<frames { cum[i + 1] = cum[i] + Double(x[i]) }
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let a = max(0, i - r), b = min(frames, i + r + 1)
            out[i] = max(0, x[i] - Float((cum[b] - cum[a]) / Double(b - a)))
        }
        return out
    }

    /// Small constant between the onset-envelope peak and the true attack (measured on clicks).
    static let latency: TimeInterval = 0.011

    // MARK: Tempo

    static func analyse(samples: [Float], sampleRate: Double, options: Options = .init(),
                        progress: ((Double) -> Void)? = nil) throws -> Result {
        let started = Date()
        let (env, lowEnv, fps) = try onsetEnvelope(samples: samples, sampleRate: sampleRate)
        progress?(0.5)
        let frames = env.count
        guard Double(frames) / fps > 4 else { throw Failure.tooShort }
        var total: Float = 0
        vDSP_sve(env, 1, &total, vDSP_Length(frames))
        guard total > 0 else { throw Failure.noBeat }

        // Autocorrelation (mean removed, normalised) out to four beats at the slowest tempo.
        let maxLag = min(frames / 2, Int(ceil(4 * 60 * fps / options.minBPM)) + 2)
        var centred = env
        var mean: Float = 0
        vDSP_meanv(env, 1, &mean, vDSP_Length(frames))
        var negMean = -mean
        vDSP_vsadd(env, 1, &negMean, &centred, 1, vDSP_Length(frames))
        var acf = [Float](repeating: 0, count: maxLag + 1)
        let p = frames - maxLag
        centred.withUnsafeBufferPointer { c in
            vDSP_conv(c.baseAddress!, 1, c.baseAddress!, 1, &acf, 1, vDSP_Length(maxLag + 1), vDSP_Length(p))
        }
        let a0 = max(acf[0], .leastNormalMagnitude)
        func acfAt(_ lag: Double) -> Double {
            let i = Int(lag), f = lag - Double(i)
            guard i + 1 <= maxLag else { return 0 }
            return (Double(acf[i]) * (1 - f) + Double(acf[i + 1]) * f) / Double(a0)
        }
        // Peak-picking ACF: the best value within ±1 frame of the lag (coarse grid tolerance).
        func acfPeak(_ lag: Double) -> Double { max(acfAt(lag - 1), acfAt(lag), acfAt(lag + 1)) }
        func comb(_ bpm: Double) -> Double {
            let l = 60 * fps / bpm
            return (1...4).reduce(0.0) { $0 + max(0, acfPeak(l * Double($1))) } / 4
        }
        func prior(_ bpm: Double) -> Double { let x = log2(bpm / 120); return exp(-0.5 * x * x) }

        // Coarse windowed Fourier tempogram.
        let winFrames = min(frames, Int(8 * fps))
        let winHop = max(1, winFrames / 2)
        var coarse: [(bpm: Double, score: Double)] = []
        var cosT = [Float](repeating: 0, count: winFrames), sinT = [Float](repeating: 0, count: winFrames)
        var bpm = options.minBPM
        while bpm <= options.maxBPM + 1e-9 {
            if Task.isCancelled { throw CancellationError() }
            phasorTable(omega: 2 * .pi * bpm / 60 / fps, count: winFrames, cos: &cosT, sin: &sinT)
            var mag = 0.0, energy = 0.0, start = 0
            while start + winFrames <= frames {
                var c: Float = 0, s: Float = 0, e: Float = 0
                env.withUnsafeBufferPointer { ep in
                    let b = ep.baseAddress! + start
                    vDSP_dotpr(b, 1, cosT, 1, &c, vDSP_Length(winFrames))
                    vDSP_dotpr(b, 1, sinT, 1, &s, vDSP_Length(winFrames))
                    vDSP_sve(b, 1, &e, vDSP_Length(winFrames))
                }
                mag += Double(hypotf(c, s)); energy += Double(e)
                start += winHop
            }
            let fourier = energy > 0 ? mag / energy : 0
            coarse.append((bpm, fourier * comb(bpm) * prior(bpm)))
            bpm += 0.5
        }
        progress?(0.75)
        guard let best = coarse.max(by: { $0.score < $1.score }), best.score > 0 else { throw Failure.noBeat }

        // Fine: coherent full-length sum, swept ±1.5 BPM.
        func coherent(_ bpm: Double) -> (mag: Double, phase: Double) {
            let omega = 2 * .pi * bpm / 60 / fps
            phasorTable(omega: omega, count: winFrames, cos: &cosT, sin: &sinT)
            var re = 0.0, im = 0.0, start = 0
            while start < frames {
                let len = min(winFrames, frames - start)
                var c: Float = 0, s: Float = 0
                env.withUnsafeBufferPointer { ep in
                    vDSP_dotpr(ep.baseAddress! + start, 1, cosT, 1, &c, vDSP_Length(len))
                    vDSP_dotpr(ep.baseAddress! + start, 1, sinT, 1, &s, vDSP_Length(len))
                }
                // Window sum is Σ o·e^{-iω(j)}; rotate by the window's start phase e^{-iω·start}.
                let ph = -omega * Double(start)
                let cr = cos(ph), sr = sin(ph)
                let wr = Double(c), wi = -Double(s)
                re += wr * cr - wi * sr; im += wr * sr + wi * cr
                start += winFrames
            }
            return (hypot(re, im), atan2(im, re))
        }
        let step = 0.01
        var sweep: [(bpm: Double, mag: Double)] = []
        var b = max(options.minBPM - 1, best.bpm - 1.5)
        while b <= min(options.maxBPM + 1, best.bpm + 1.5) + 1e-9 {
            if Task.isCancelled { throw CancellationError() }
            sweep.append((b, coherent(b).mag)); b += step
        }
        guard let bi = sweep.indices.max(by: { sweep[$0].mag < sweep[$1].mag }) else { throw Failure.noBeat }
        var tempo = sweep[bi].bpm
        if bi > 0, bi < sweep.count - 1 {
            let y0 = sweep[bi - 1].mag, y1 = sweep[bi].mag, y2 = sweep[bi + 1].mag
            let den = y0 - 2 * y1 + y2
            if den < 0 { tempo += step * 0.5 * (y0 - y2) / den }
        }
        progress?(0.95)

        // Phase: Σ o·e^{-iωk} = R·e^{-iωk0} → k0 = −φ/ω (mod period).
        let fin = coherent(tempo)
        let omega = 2 * .pi * tempo / 60 / fps
        let period = 60 * fps / tempo
        var k0 = (-fin.phase / omega).truncatingRemainder(dividingBy: period)
        if k0 < 0 { k0 += period }
        let frameZero = Double(fftSize / 2) / sampleRate + latency
        var beatLen = 60 / tempo
        var phase = k0 / fps + frameZero
        let dur = Double(samples.count) / sampleRate

        // Refine: weighted least-squares line through the onset peaks nearest each predicted
        // beat (sub-frame by parabolic interpolation). Removes the noise bias of the Fourier
        // peak and pins the phase; two passes, the second without outliers.
        let sortedEnv = env.sorted()
        let p95 = sortedEnv[min(sortedEnv.count - 1, Int(Double(sortedEnv.count) * 0.95))]
        for pass in 0..<3 {
            if Task.isCancelled { throw CancellationError() }
            var pts: [(n: Double, t: Double, w: Double)] = []
            let reach = max(2, Int(0.15 * beatLen * fps))
            var n = -((phase - frameZero) / beatLen).rounded(.down)
            while true {
                let t = phase + n * beatLen
                if t >= dur { break }
                let c = Int(((t - frameZero) * fps).rounded())
                let lo = max(1, c - reach), hi = min(frames - 2, c + reach)
                if lo <= hi {
                    var m = lo
                    for i in lo...hi where env[i] > env[m] { m = i }
                    let y1 = Double(env[m])
                    if y1 > Double(p95) * 0.2, m > lo, m < hi {
                        let y0 = Double(env[m - 1]), y2 = Double(env[m + 1])
                        let den = y0 - 2 * y1 + y2
                        let d = den < 0 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / den)) : 0
                        pts.append((n, (Double(m) + d) / fps + frameZero, y1))
                    }
                }
                n += 1
            }
            if pass == 2, pts.count >= 8 {
                // Drop points more than 3 robust deviations off the current line.
                let res = pts.map { abs($0.t - (phase + $0.n * beatLen)) }
                let mad = res.sorted()[res.count / 2] * 1.4826 + 1e-4
                pts = pts.filter { abs($0.t - (phase + $0.n * beatLen)) <= 3 * mad }
            }
            guard pts.count >= 8 else { break }
            let sw = pts.reduce(0) { $0 + $1.w }
            let mn = pts.reduce(0) { $0 + $1.w * $1.n } / sw, mt = pts.reduce(0) { $0 + $1.w * $1.t } / sw
            let sxx = pts.reduce(0) { $0 + $1.w * ($1.n - mn) * ($1.n - mn) }
            let sxy = pts.reduce(0) { $0 + $1.w * ($1.n - mn) * ($1.t - mt) }
            guard sxx > 0 else { break }
            let slope = sxy / sxx
            guard slope > 0, abs(slope - beatLen) < beatLen * 0.02 else { break }
            beatLen = slope
            phase = mt - slope * mn
        }
        tempo = 60 / beatLen
        phase = phase.truncatingRemainder(dividingBy: beatLen)
        if phase < 0 { phase += beatLen }

        func near(_ e: [Float], _ t: TimeInterval) -> Float {
            let c = Int(((t - frameZero) * fps).rounded())
            let lo = max(0, c - 2), hi = min(frames - 1, c + 2)
            guard lo <= hi else { return 0 }
            return e[lo...hi].max() ?? 0
        }
        /// Summed onset strength on every beat, by beat index modulo `m`.
        func strengths(_ e: [Float], modulo m: Int) -> [Double] {
            var acc = [Double](repeating: 0, count: m), cnt = [Double](repeating: 0, count: m)
            var t = phase, n = 0
            while t < dur { acc[n % m] += Double(near(e, t)); cnt[n % m] += 1; t += beatLen; n += 1 }
            return zip(acc, cnt).map { $1 > 0 ? $0 / $1 : 0 }
        }

        // Downbeat: the beat-in-bar with the most kick (low band), then overall, energy.
        // Near-ties (kick on 1 and 3) go to the earliest after the music starts.
        let bpb = max(1, options.beatsPerBar)
        let lowS = strengths(lowEnv, modulo: bpb), allS = strengths(env, modulo: bpb)
        let score = (0..<bpb).map { lowS[$0] / max(1e-9, lowS.max() ?? 1) + 0.5 * allS[$0] / max(1e-9, allS.max() ?? 1) }
        let top = score.max() ?? 0
        // Music start: first frame above a quarter of the 95th-percentile onset.
        let startFrame = env.firstIndex(where: { $0 > p95 * 0.25 }) ?? 0
        let musicStart = Double(startFrame) / fps + frameZero
        func firstAfterStart(_ k: Int) -> TimeInterval {
            var f = phase + Double(k) * beatLen
            while f < musicStart - beatLen * 0.5 { f += beatLen * Double(bpb) }
            return f
        }
        let first = (0..<bpb).filter { score[$0] >= top * 0.92 }.map(firstAfterStart).min() ?? phase

        // Confidence: phase coherence × how clearly this tempo beats every non-octave rival.
        let coherence = min(1, coherent(tempo).mag / Double(total))
        let rival = coarse.filter { c in
            ![1.0, 2.0, 0.5, 1.5, 2.0 / 3.0].contains(where: { abs(c.bpm / best.bpm - $0) < 0.04 * $0 })
        }.map(\.score).max() ?? 0
        let salience = max(0, 1 - rival / best.score)
        let confidence = min(1, sqrt(min(1, coherence / 0.3) * salience))

        progress?(1)
        let grid = BeatGrid(bpm: tempo, firstBeat: first, beatsPerBar: bpb, confidence: confidence)
        return Result(grid: grid, confidence: confidence, coherence: coherence, elapsed: Date().timeIntervalSince(started))
    }

    /// cos/sin of ω·j for j in 0..<count (float; phases stay small because every window restarts at 0).
    private static func phasorTable(omega: Double, count: Int, cos c: inout [Float], sin s: inout [Float]) {
        var ph = [Float](repeating: 0, count: count)
        var start: Float = 0, inc = Float(omega)
        vDSP_vramp(&start, &inc, &ph, 1, vDSP_Length(count))
        var n = Int32(count)
        vvsincosf(&s, &c, ph, &n)
    }
}
