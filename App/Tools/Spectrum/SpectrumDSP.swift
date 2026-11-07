import Accelerate
import Foundation

// Pure spectrum maths for the analyser: windowed real FFT, fractional-octave bands, averaging,
// tilt, peak finding and the dual-channel transfer function. No UI, no audio session, so it is
// unit-tested directly (AppTests/ToolsSpectrumTests.swift).

// MARK: - Window

enum SpectrumWindowKind: String, CaseIterable, Identifiable {
    case hann, blackmanHarris
    var id: String { rawValue }
    var label: String { self == .hann ? "Hann" : "Blackman-Harris" }

    /// Periodic window of `n` points (the DFT-even form used for spectral analysis).
    func coefficients(_ n: Int) -> [Float] {
        let N = Double(n)
        return (0..<n).map { i in
            let x = 2 * Double.pi * Double(i) / N
            switch self {
            case .hann: return Float(0.5 - 0.5 * cos(x))
            case .blackmanHarris: return Float(0.35875 - 0.48829 * cos(x) + 0.14128 * cos(2 * x) - 0.01168 * cos(3 * x))
            }
        }
    }

    /// Half-width of the main lobe, in bins, used to sum a tone's energy back together.
    var lobeBins: Int { self == .hann ? 2 : 3 }
}

// MARK: - FFT

/// Windowed real FFT of a fixed power-of-two size (vDSP split-complex, in place).
/// Not thread-safe: one per worker.
final class SpectrumFFT {
    let size: Int
    /// Bins 0 ..< size/2 (Nyquist is dropped).
    let bins: Int
    let windowKind: SpectrumWindowKind
    let window: [Float]
    /// Σw (coherent gain × N).
    let windowSum: Float
    /// Equivalent noise bandwidth of the window, in bins.
    let enbw: Float
    /// After `forward`: 2·X[k] for k in 1..<bins; re[0] = 2·X[0], im[0] = 2·X[N/2] (vDSP packing).
    let re: UnsafeMutablePointer<Float>
    let im: UnsafeMutablePointer<Float>

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let buf: UnsafeMutablePointer<Float>

    init?(size: Int, window kind: SpectrumWindowKind) {
        guard size >= 16, size & (size - 1) == 0 else { return nil }
        let l = vDSP_Length(log2(Double(size)).rounded())
        guard let s = vDSP_create_fftsetup(l, FFTRadix(kFFTRadix2)) else { return nil }
        self.size = size; bins = size / 2; log2n = l; setup = s; windowKind = kind
        window = kind.coefficients(size)
        var s1: Float = 0, s2: Float = 0
        vDSP_sve(window, 1, &s1, vDSP_Length(size))
        vDSP_svesq(window, 1, &s2, vDSP_Length(size))
        windowSum = s1
        enbw = Float(size) * s2 / (s1 * s1)
        buf = .allocate(capacity: size); buf.initialize(repeating: 0, count: size)
        re = .allocate(capacity: size / 2); re.initialize(repeating: 0, count: size / 2)
        im = .allocate(capacity: size / 2); im.initialize(repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        buf.deallocate(); re.deallocate(); im.deallocate()
    }

    /// Windows `size` samples of `x` and transforms them into `re` / `im`.
    func forward(_ x: UnsafePointer<Float>) {
        vDSP_vmul(x, 1, window, 1, buf, 1, vDSP_Length(size))
        var split = DSPSplitComplex(realp: re, imagp: im)
        buf.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    /// Amplitude-normalised power per bin: a sine of peak amplitude A reads A² in the bin it
    /// falls on (exactly when it is centred on a bin), so 10·log10 gives dBFS of the tone.
    func power(_ x: UnsafePointer<Float>, into p: UnsafeMutablePointer<Float>) {
        forward(x)
        let dcNy = (re[0], im[0])
        im[0] = 0
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_zvmags(&split, 1, p, 1, vDSP_Length(bins))
        var k = 1 / (windowSum * windowSum)        // |2X/Σw|² = |out/Σw|²
        vDSP_vsmul(p, 1, &k, p, 1, vDSP_Length(bins))
        p[0] = dcNy.0 * dcNy.0 * k / 4             // DC carries no factor of two
        im[0] = dcNy.1
    }

    /// Inverse of a half spectrum packed like `re` / `im` (im[0] = Nyquist), into `size` reals.
    /// Unscaled (vDSP gives 2·N times the true inverse): only the shape is used.
    func inverse(re hr: UnsafeMutablePointer<Float>, im hi: UnsafeMutablePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: hr, imagp: hi)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        out.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(bins))
        }
    }
}

// MARK: - Fractional-octave bands

/// Base-ten fractional-octave bands (IEC 61260-1 / ANSI S1.11): octave ratio G = 10^0.3,
/// mid-band frequencies 1000·G^(x/b) for odd b and 1000·G^((2x+1)/(2b)) for even b,
/// edges a half band either side. Covers 20 Hz – 20 kHz (a band is kept when its centre is
/// within a quarter band of the range, so 1/3 octave gives the familiar 31 bands).
struct OctaveBands: Equatable {
    static let G = pow(10.0, 0.3)
    let fraction: Int
    let centers: [Double]
    let lower: [Double]
    let upper: [Double]
    var count: Int { centers.count }

    init(fraction b: Int, low: Double = 20, high: Double = 20_000) {
        fraction = b
        let G = Self.G
        let tol = pow(G, 1 / (4 * Double(b)))
        let lo = Int((Double(b) * log(low / 1000) / log(G)).rounded(.down)) - 2
        let hi = Int((Double(b) * log(high / 1000) / log(G)).rounded(.up)) + 2
        var c: [Double] = []
        for x in lo...hi {
            let f = Self.center(index: x, fraction: b)
            if f >= low / tol, f <= high * tol { c.append(f) }
        }
        centers = c
        let half = pow(G, 1 / (2 * Double(b)))
        lower = c.map { $0 / half }
        upper = c.map { $0 * half }
    }

    static func center(index x: Int, fraction b: Int) -> Double {
        b % 2 == 1 ? 1000 * pow(G, Double(x) / Double(b)) : 1000 * pow(G, Double(2 * x + 1) / Double(2 * b))
    }

    static let fractions = [1, 3, 6, 12, 24, 48]
}

/// How a band's value is formed from the FFT bins under it.
enum BandMode {
    /// Mean power density across the band: fractional-octave smoothing of the spectrum
    /// (pink noise falls 3 dB per octave; a tone reads lower in a wide band).
    case smoothed
    /// Total energy in the band, as a real-time analyser: pink noise reads flat and a tone
    /// reads its true level whatever the band width.
    case energy
}

/// Precomputed band weights for one FFT size and sample rate. Bins are weighted by how much
/// of each bin's width falls inside the band; a band narrower than one bin interpolates
/// between the two nearest bins.
struct BandMap {
    let bands: OctaveBands
    let binHz: Double
    private let start: [Int]
    private let index: [Int32]
    private let weight: [Float]
    private let weightSum: [Float]
    private let enbw: Float

    init(bands: OctaveBands, binHz: Double, binCount: Int, enbw: Float) {
        self.bands = bands; self.binHz = binHz; self.enbw = enbw
        var s: [Int] = [0], ix: [Int32] = [], w: [Float] = [], ws: [Float] = []
        for b in 0..<bands.count {
            let k1 = bands.lower[b] / binHz, k2 = bands.upper[b] / binHz
            var sum: Float = 0
            if k2 - k1 >= 1 {
                let first = max(1, Int((k1 - 0.5).rounded(.down))), last = min(binCount - 1, Int((k2 + 0.5).rounded(.up)))
                if first <= last {
                    for k in first...last {
                        let o = min(Double(k) + 0.5, k2) - max(Double(k) - 0.5, k1)
                        if o > 0 { ix.append(Int32(k)); w.append(Float(o)); sum += Float(o) }
                    }
                }
            } else {
                let kc = bands.centers[b] / binHz
                let k0 = Int(kc.rounded(.down)), f = Float(kc - Double(k0))
                let width = Float(k2 - k1)
                if k0 >= 1, k0 + 1 < binCount {
                    ix.append(Int32(k0)); w.append((1 - f) * width)
                    ix.append(Int32(k0 + 1)); w.append(f * width)
                    sum = width
                }
            }
            ws.append(sum)
            s.append(ix.count)
        }
        start = s; index = ix; weight = w; weightSum = ws
    }

    var count: Int { bands.count }

    /// Linear power per band from per-bin power `p` (amplitude-normalised, see `SpectrumFFT`).
    func apply(_ p: UnsafePointer<Float>, mode: BandMode, into out: UnsafeMutablePointer<Float>) {
        index.withUnsafeBufferPointer { ix in
            weight.withUnsafeBufferPointer { w in
                for b in 0..<bands.count {
                    var acc: Float = 0
                    for j in start[b]..<start[b + 1] { acc += p[Int(ix[j])] * w[j] }
                    let ws = weightSum[b]
                    switch mode {
                    case .smoothed: out[b] = ws > 0 ? acc / ws : 0
                    case .energy: out[b] = acc / enbw
                    }
                }
            }
        }
    }

    /// Weighted mean of each band over several per-bin arrays at once (transfer function).
    func mean(_ arrays: [UnsafePointer<Float>], into outs: [UnsafeMutablePointer<Float>]) {
        for b in 0..<bands.count {
            let ws = weightSum[b]
            for (a, o) in zip(arrays, outs) {
                var acc: Float = 0
                for j in start[b]..<start[b + 1] { acc += a[Int(index[j])] * weight[j] }
                o[b] = ws > 0 ? acc / ws : 0
            }
        }
    }
}

// MARK: - Averaging, tilt, levels

enum SpectrumAveraging: String, CaseIterable, Identifiable {
    case off, fast, slow, infinite
    var id: String { rawValue }
    var label: String {
        switch self { case .off: "None"; case .fast: "Fast"; case .slow: "Slow"; case .infinite: "Infinite" }
    }
    /// Exponential time constant.
    var seconds: Double? {
        switch self { case .off: nil; case .fast: 0.25; case .slow: 1.5; case .infinite: nil }
    }
    /// Weight of the newest frame. `frames` = frames already averaged (for infinite).
    func alpha(hopSeconds: Double, frames: Int) -> Float {
        switch self {
        case .off: return 1
        case .infinite: return 1 / Float(frames + 1)
        case .fast, .slow: return Float(1 - exp(-hopSeconds / seconds!))
        }
    }
}

enum SpectrumMath {
    static let minPower: Float = 1e-14   // −140 dB

    /// avg ← avg + α·(x − avg), in place.
    static func average(_ avg: UnsafeMutablePointer<Float>, _ x: UnsafePointer<Float>, count n: Int, alpha: Float) {
        if alpha >= 1 { avg.update(from: x, count: n); return }
        var a = alpha
        vDSP_vintb(avg, 1, x, 1, &a, avg, 1, vDSP_Length(n))
    }

    /// Linear power → dB (floored at −140).
    static func toDB(_ p: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>, count n: Int) {
        var lo = minPower
        vDSP_vthr(p, 1, &lo, out, 1, vDSP_Length(n))
        var one: Float = 1
        vDSP_vdbcon(out, 1, &one, out, 1, vDSP_Length(n), 0)
    }

    /// dB added at each frequency for a slope of `dbPerOctave`, pivoting at 1 kHz.
    static func tilt(_ frequencies: [Double], dbPerOctave: Double) -> [Float] {
        frequencies.map { Float(dbPerOctave * log2($0 / 1000)) }
    }

    /// Musical note nearest `f` (A4 = 440 Hz) and the offset from it in cents.
    static func note(_ f: Double) -> (name: String, cents: Int)? {
        guard f > 8 else { return nil }
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let m = 69 + 12 * log2(f / 440)
        let n = Int(m.rounded())
        let cents = Int(((m - Double(n)) * 100).rounded())
        let octave = Int((Double(n) / 12).rounded(.down)) - 1
        return ("\(names[((n % 12) + 12) % 12])\(octave)", cents)
    }

    static func formatHz(_ f: Double) -> String {
        if f >= 10_000 { return String(format: "%.1f kHz", f / 1000) }
        if f >= 1000 { return String(format: "%.2f kHz", f / 1000) }
        if f >= 100 { return String(format: "%.0f Hz", f) }
        return String(format: "%.1f Hz", f)
    }
}

// MARK: - Peaks

struct SpectrumPeak: Equatable {
    var frequency: Double
    /// Level of the tone in dBFS: energy of the main lobe, corrected for the window, so it
    /// reads the same whether the tone sits on a bin or between two.
    var dB: Float
}

enum SpectrumPeaks {
    /// The strongest tonal peaks between `low` and `high` Hz, at least `separation` octaves
    /// apart and `prominence` dB above the spectrum around them.
    static func find(power p: UnsafePointer<Float>, bins: Int, binHz: Double, enbw: Float, lobe: Int,
                     maxCount: Int = 3, low: Double = 20, high: Double = 20_000,
                     floorDB: Float = -100, prominence: Float = 15, separation: Double = 1.0 / 6) -> [SpectrumPeak] {
        let k0 = max(lobe + 1, Int(low / binHz)), k1 = min(bins - lobe - 2, Int(high / binHz))
        guard k1 > k0 else { return [] }
        let floorP = powf(10, floorDB / 10)
        var cands: [(k: Int, v: Float)] = []
        cands.reserveCapacity(256)
        var k = k0
        while k <= k1 {
            let v = p[k]
            if v > floorP, v >= p[k - 1], v > p[k + 1], v >= p[k - 2], v > p[k + 2] { cands.append((k, v)) }
            k += 1
        }
        cands.sort { $0.v > $1.v }
        var out: [SpectrumPeak] = []
        for c in cands.prefix(48) {
            // Interpolated frequency (Gaussian fit on log power: exact for Gaussian-like lobes).
            let a = logf(max(p[c.k - 1], 1e-30)), b = logf(c.v), d = logf(max(p[c.k + 1], 1e-30))
            let den = a - 2 * b + d
            let delta = den < 0 ? max(-0.5, min(0.5, 0.5 * (a - d) / den)) : 0
            let f = (Double(c.k) + Double(delta)) * binHz
            if out.contains(where: { abs(log2($0.frequency / f)) < separation }) { continue }
            var e: Float = 0
            for j in (c.k - lobe)...(c.k + lobe) { e += p[j] }
            // Prominence: compare with the median a half octave either side (lobe excluded),
            // which ignores other tones nearby. Too few bins around it (low end of a small
            // FFT) means it can't be told from noise.
            let lo = max(1, Int(Double(c.k) / 1.414)), hi = min(bins - 1, Int(Double(c.k) * 1.414))
            var bg: [Float] = []
            bg.reserveCapacity(130)
            let stride = max(1, (hi - lo) / 128)   // a sample of the bins is enough for a median
            var j = lo
            while j <= hi { if abs(j - c.k) > lobe + 1 { bg.append(p[j]) }; j += stride }
            guard bg.count >= 6 else { continue }
            bg.sort()
            if 10 * log10f(c.v / max(bg[bg.count / 2], 1e-30)) < prominence { continue }
            out.append(SpectrumPeak(frequency: f, dB: 10 * log10f(max(e / enbw, 1e-30))))
            if out.count == maxCount { break }
        }
        return out
    }
}

// MARK: - Transfer function

/// Banded transfer function: magnitude (dB), phase (degrees, wrapped ±180) and coherence (0…1).
struct TransferBands {
    var magnitudeDB: [Float]
    var phaseDeg: [Float]
    var coherence: [Float]
}

/// Dual-channel FFT transfer function, measured (y) over reference (x), Smaart style:
/// averaged auto- and cross-spectra, H = Gxy / Gxx, coherence γ² = |Gxy|² / (Gxx·Gyy).
/// Bands are formed by complex smoothing (the spectra are averaged across the band first).
final class TransferAccumulator {
    let fft: SpectrumFFT
    private(set) var frames = 0
    let gxx, gyy, gxyRe, gxyIm: UnsafeMutablePointer<Float>
    private let xr, xi, tr, ti, tmp: UnsafeMutablePointer<Float>
    private let n: Int

    init(fft: SpectrumFFT) {
        self.fft = fft
        n = fft.bins
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: fft.bins); p.initialize(repeating: 0, count: fft.bins); return p
        }
        gxx = alloc(); gyy = alloc(); gxyRe = alloc(); gxyIm = alloc()
        xr = alloc(); xi = alloc(); tr = alloc(); ti = alloc(); tmp = alloc()
    }

    deinit { [gxx, gyy, gxyRe, gxyIm, xr, xi, tr, ti, tmp].forEach { $0.deallocate() } }

    func reset() {
        frames = 0
        for p in [gxx, gyy, gxyRe, gxyIm] { p.update(repeating: 0, count: n) }
    }

    /// One frame of reference `x` and measurement `y` (each `fft.size` samples, same moment
    /// after delay compensation). `alpha` nil = cumulative mean (infinite averaging).
    func add(x: UnsafePointer<Float>, y: UnsafePointer<Float>, alpha: Float?) {
        fft.forward(x)
        xr.update(from: fft.re, count: n); xi.update(from: fft.im, count: n); xi[0] = 0
        fft.forward(y)
        let yr = fft.re, yi = fft.im
        yi[0] = 0
        let a = alpha ?? 1 / Float(frames + 1)
        let vn = vDSP_Length(n)
        // Gxx
        vDSP_vsq(xr, 1, tr, 1, vn); vDSP_vsq(xi, 1, ti, 1, vn); vDSP_vadd(tr, 1, ti, 1, tmp, 1, vn)
        SpectrumMath.average(gxx, tmp, count: n, alpha: frames == 0 ? 1 : a)
        // Gyy
        vDSP_vsq(yr, 1, tr, 1, vn); vDSP_vsq(yi, 1, ti, 1, vn); vDSP_vadd(tr, 1, ti, 1, tmp, 1, vn)
        SpectrumMath.average(gyy, tmp, count: n, alpha: frames == 0 ? 1 : a)
        // Gxy = conj(X)·Y
        vDSP_vmul(xr, 1, yr, 1, tr, 1, vn); vDSP_vma(xi, 1, yi, 1, tr, 1, tmp, 1, vn)
        SpectrumMath.average(gxyRe, tmp, count: n, alpha: frames == 0 ? 1 : a)
        vDSP_vmul(xr, 1, yi, 1, tr, 1, vn); vDSP_vmul(xi, 1, yr, 1, ti, 1, vn); vDSP_vsub(ti, 1, tr, 1, tmp, 1, vn)
        SpectrumMath.average(gxyIm, tmp, count: n, alpha: frames == 0 ? 1 : a)
        frames += 1
    }

    func banded(_ map: BandMap) -> TransferBands {
        let c = map.count
        var sxx = [Float](repeating: 0, count: c), syy = sxx, sre = sxx, sim = sxx
        sxx.withUnsafeMutableBufferPointer { a in
            syy.withUnsafeMutableBufferPointer { b in
                sre.withUnsafeMutableBufferPointer { r in
                    sim.withUnsafeMutableBufferPointer { i in
                        map.mean([UnsafePointer(gxx), UnsafePointer(gyy), UnsafePointer(gxyRe), UnsafePointer(gxyIm)],
                                 into: [a.baseAddress!, b.baseAddress!, r.baseAddress!, i.baseAddress!])
                    }
                }
            }
        }
        var mag = [Float](repeating: -140, count: c), ph = [Float](repeating: 0, count: c), coh = [Float](repeating: 0, count: c)
        for b in 0..<c where sxx[b] > 1e-20 {
            let cross = sre[b] * sre[b] + sim[b] * sim[b]
            mag[b] = 10 * log10f(max(cross, 1e-30) / (sxx[b] * sxx[b]))
            ph[b] = atan2f(sim[b], sre[b]) * 180 / .pi
            coh[b] = syy[b] > 1e-20 ? min(1, cross / (sxx[b] * syy[b])) : 0
        }
        return TransferBands(magnitudeDB: mag, phaseDeg: ph, coherence: coh)
    }

    /// Delay of y behind x from the averaged cross-spectrum (phase-transform weighted impulse
    /// response, sub-sample peak). Range −size/2 ..< size/2 samples. nil without a clear peak.
    func impulseDelay() -> DelayFinder.Result? {
        DelayFinder.peak(fft: fft, re: gxyRe, im: gxyIm, scratchRe: tr, scratchIm: ti)
    }
}

/// Finds the delay between reference and measurement, as Smaart's delay finder: the
/// phase-transform cross-spectrum averaged over overlapping blocks, back to an impulse
/// response, whose peak is the arrival.
enum DelayFinder {
    struct Result: Equatable {
        /// y behind x, in samples (sub-sample).
        var samples: Double
        /// Peak over RMS of the impulse response, in dB. Above ~20 dB is a clean arrival.
        var clarityDB: Float
        var inverted: Bool
    }

    /// `x` and `y` cover the same span of time. Delays up to `fftSize/2` either way.
    static func find(reference x: [Float], measured y: [Float], fftSize: Int,
                     window: SpectrumWindowKind = .hann) -> Result? {
        let n = min(x.count, y.count)
        guard n >= fftSize, let fft = SpectrumFFT(size: fftSize, window: window) else { return nil }
        let acc = TransferAccumulator(fft: fft)
        let hop = fftSize / 2
        var s = 0
        x.withUnsafeBufferPointer { xp in
            y.withUnsafeBufferPointer { yp in
                while s + fftSize <= n {
                    acc.add(x: xp.baseAddress! + s, y: yp.baseAddress! + s, alpha: nil)
                    s += hop
                }
            }
        }
        return acc.impulseDelay()
    }

    static func peak(fft: SpectrumFFT, re: UnsafePointer<Float>, im: UnsafePointer<Float>,
                     scratchRe hr: UnsafeMutablePointer<Float>, scratchIm hi: UnsafeMutablePointer<Float>) -> Result? {
        let bins = fft.bins, N = fft.size
        var energy: Float = 0
        for k in 1..<bins {
            let m = (re[k] * re[k] + im[k] * im[k]).squareRoot()
            energy += m
            if m > 1e-20 { hr[k] = re[k] / m; hi[k] = im[k] / m } else { hr[k] = 0; hi[k] = 0 }
        }
        guard energy > 1e-12 else { return nil }
        hr[0] = 0; hi[0] = 0
        let h = UnsafeMutablePointer<Float>.allocate(capacity: N)
        defer { h.deallocate() }
        fft.inverse(re: hr, im: hi, into: h)
        var best = 0
        var bestV: Float = 0
        var sq: Float = 0
        for i in 0..<N {
            sq += h[i] * h[i]
            if abs(h[i]) > abs(bestV) { bestV = h[i]; best = i }
        }
        let rms = (sq / Float(N)).squareRoot()
        guard rms > 0 else { return nil }
        let clarity = 20 * log10f(abs(bestV) / rms)
        guard clarity > 18 else { return nil }
        let a = abs(h[(best - 1 + N) % N]), b = abs(bestV), c = abs(h[(best + 1) % N])
        let den = a - 2 * b + c
        let delta = abs(den) > 1e-20 ? Double(max(-0.5, min(0.5, 0.5 * (a - c) / den))) : 0
        var lag = Double(best) + delta
        if lag >= Double(N / 2) { lag -= Double(N) }
        return Result(samples: lag, clarityDB: clarity, inverted: bestV < 0)
    }
}
