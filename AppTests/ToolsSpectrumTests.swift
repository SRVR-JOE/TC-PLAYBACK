import XCTest
@testable import TCPlayback

final class ToolsSpectrumTests: XCTestCase {
    private let fs = 48_000.0

    // MARK: Signals

    private func sine(_ f: Double, dBFS: Double, count n: Int) -> [Float] {
        let a = pow(10, dBFS / 20)
        return (0..<n).map { Float(a * sin(2 * .pi * f * Double($0) / fs)) }
    }

    private func white(_ n: Int, seed: UInt32) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 1_664_525 &+ 1_013_904_223
            return Float(s >> 8) / Float(1 << 23) - 1
        }
    }

    /// Paul Kellet's refined pink filter (±0.05 dB above 9.2 Hz).
    private func pink(_ n: Int, seed: UInt32) -> [Float] {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        return white(n, seed: seed).map { w in
            b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
            let p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
            b6 = w * 0.115926
            return p * 0.05
        }
    }

    /// Infinite-averaged per-bin power over 50 %-overlapped frames.
    private func averagedPower(_ x: [Float], fft: SpectrumFFT) -> [Float] {
        var avg = [Float](repeating: 0, count: fft.bins), p = avg
        var frames = 0
        var s = 0
        x.withUnsafeBufferPointer { xp in
            while s + fft.size <= x.count {
                p.withUnsafeMutableBufferPointer { fft.power(xp.baseAddress! + s, into: $0.baseAddress!) }
                avg.withUnsafeMutableBufferPointer { a in
                    p.withUnsafeBufferPointer { SpectrumMath.average(a.baseAddress!, $0.baseAddress!, count: fft.bins,
                                                                     alpha: SpectrumAveraging.infinite.alpha(hopSeconds: 0, frames: frames)) }
                }
                frames += 1
                s += fft.size / 2
            }
        }
        return avg
    }

    private func bandDB(_ p: [Float], fft: SpectrumFFT, fraction: Int, mode: BandMode, tilt: Double) -> (OctaveBands, [Float]) {
        let bands = OctaveBands(fraction: fraction)
        let map = BandMap(bands: bands, binHz: fs / Double(fft.size), binCount: fft.bins, enbw: fft.enbw)
        var out = [Float](repeating: 0, count: bands.count)
        p.withUnsafeBufferPointer { pp in out.withUnsafeMutableBufferPointer { map.apply(pp.baseAddress!, mode: mode, into: $0.baseAddress!) } }
        let t = SpectrumMath.tilt(bands.centers, dbPerOctave: tilt)
        return (bands, out.enumerated().map { 10 * log10f($0.element) + t[$0.offset] })
    }

    // MARK: Sine

    func testSineReadsFrequencyAndLevel() throws {
        for kind in SpectrumWindowKind.allCases {
            for n in [4096, 8192, 32_768] {
                let fft = try XCTUnwrap(SpectrumFFT(size: n, window: kind))
                let x = sine(1000, dBFS: -12, count: n)
                var p = [Float](repeating: 0, count: fft.bins)
                x.withUnsafeBufferPointer { xp in p.withUnsafeMutableBufferPointer { fft.power(xp.baseAddress!, into: $0.baseAddress!) } }
                let binHz = fs / Double(n)
                // Strongest bin within ±1 bin of 1 kHz.
                let k = p.indices.max { p[$0] < p[$1] }!
                XCTAssertEqual(Double(k) * binHz, 1000, accuracy: binHz * 1.0001, "\(kind) \(n)")
                // Peak finder: interpolated frequency and window-corrected level.
                let peaks = p.withUnsafeBufferPointer {
                    SpectrumPeaks.find(power: $0.baseAddress!, bins: fft.bins, binHz: binHz, enbw: fft.enbw, lobe: kind.lobeBins)
                }
                let pk = try XCTUnwrap(peaks.first, "\(kind) \(n)")
                XCTAssertEqual(pk.frequency, 1000, accuracy: binHz, "\(kind) \(n)")
                XCTAssertEqual(pk.dB, -12, accuracy: 0.5, "\(kind) \(n)")
                // RTA (band energy) reads the tone's true level in its 1/3-octave band.
                let (bands, db) = bandDB(p, fft: fft, fraction: 3, mode: .energy, tilt: 0)
                let b = bands.centers.indices.min { abs(bands.centers[$0] - 1000) < abs(bands.centers[$1] - 1000) }!
                XCTAssertEqual(db[b], -12, accuracy: 0.5, "\(kind) \(n)")
            }
        }
    }

    func testOnBinSineIsExact() throws {
        // A tone centred on a bin reads exactly its level in that bin (amplitude normalisation).
        let n = 8192
        let fft = try XCTUnwrap(SpectrumFFT(size: n, window: .blackmanHarris))
        let f = 171 * fs / Double(n)
        let x = sine(f, dBFS: -12, count: n)
        var p = [Float](repeating: 0, count: fft.bins)
        x.withUnsafeBufferPointer { xp in p.withUnsafeMutableBufferPointer { fft.power(xp.baseAddress!, into: $0.baseAddress!) } }
        XCTAssertEqual(10 * log10f(p[171]), -12, accuracy: 0.05)
    }

    // MARK: Pink noise

    func testPinkNoiseFlatWithThreeDBTilt() throws {
        let fft = try XCTUnwrap(SpectrumFFT(size: 16_384, window: .blackmanHarris))
        let avg = averagedPower(pink(Int(fs * 24), seed: 4242), fft: fft)
        // Smoothed spectrum + 3 dB/oct tilt: flat.
        let (bands, db) = bandDB(avg, fft: fft, fraction: 3, mode: .smoothed, tilt: 3)
        let idx = bands.centers.indices.filter { bands.centers[$0] >= 50 && bands.centers[$0] <= 16_000 }
        let mean = idx.map { db[$0] }.reduce(0, +) / Float(idx.count)
        for i in idx {
            XCTAssertEqual(db[i], mean, accuracy: 1.5, "band \(Int(bands.centers[i])) Hz")
        }
        // Without the tilt the smoothed spectrum falls 3 dB per octave (125 Hz → 8 kHz = 6 octaves).
        let (_, raw) = bandDB(avg, fft: fft, fraction: 3, mode: .smoothed, tilt: 0)
        let i125 = bands.centers.firstIndex { abs($0 - 125.9) < 1 }!, i8k = bands.centers.firstIndex { abs($0 - 7943) < 5 }!
        XCTAssertEqual(raw[i8k] - raw[i125], -18, accuracy: 1.5)
        // RTA band energy reads pink noise flat with no tilt.
        let (_, rta) = bandDB(avg, fft: fft, fraction: 3, mode: .energy, tilt: 0)
        let rmean = idx.map { rta[$0] }.reduce(0, +) / Float(idx.count)
        for i in idx { XCTAssertEqual(rta[i], rmean, accuracy: 1.5, "RTA band \(Int(bands.centers[i])) Hz") }
    }

    // MARK: Bands

    func testFractionalOctaveBandEdges() {
        let third = OctaveBands(fraction: 3)
        XCTAssertEqual(third.count, 31)
        XCTAssertEqual(third.centers.first!, 19.953, accuracy: 0.01)
        XCTAssertEqual(third.centers.last!, 19_952.6, accuracy: 0.5)
        let k = third.centers.firstIndex { abs($0 - 1000) < 0.001 }!
        XCTAssertEqual(third.lower[k], 891.25, accuracy: 0.01)
        XCTAssertEqual(third.upper[k], 1122.02, accuracy: 0.01)

        let oct = OctaveBands(fraction: 1)
        XCTAssertEqual(oct.count, 10)
        XCTAssertEqual(oct.centers.first!, 31.62, accuracy: 0.01)
        let o = oct.centers.firstIndex { abs($0 - 1000) < 0.001 }!
        XCTAssertEqual(oct.lower[o], 707.95, accuracy: 0.01)
        XCTAssertEqual(oct.upper[o], 1412.54, accuracy: 0.01)

        // Even fractions: centres straddle 1 kHz (IEC 61260-1, b even).
        let sixth = OctaveBands(fraction: 6)
        XCTAssertNotNil(sixth.centers.firstIndex { abs($0 - 1059.25) < 0.01 })
        XCTAssertNotNil(sixth.centers.firstIndex { abs($0 - 944.06) < 0.01 })
        XCTAssertNil(sixth.centers.firstIndex { abs($0 - 1000) < 1 })

        for b in OctaveBands.fractions {
            let bands = OctaveBands(fraction: b)
            // Covers 20 Hz – 20 kHz to within a quarter band at each end.
            let q = pow(OctaveBands.G, 1 / (4 * Double(b)))
            XCTAssertLessThanOrEqual(bands.lower.first!, 20 * q * q, "1/\(b)")
            XCTAssertGreaterThanOrEqual(bands.upper.last!, 20_000 / (q * q), "1/\(b)")
            let ratio = pow(OctaveBands.G, 1 / Double(b))
            for i in 0..<(bands.count - 1) {
                XCTAssertEqual(bands.upper[i], bands.lower[i + 1], accuracy: bands.upper[i] * 1e-9, "1/\(b) contiguous")
                XCTAssertEqual(bands.centers[i + 1] / bands.centers[i], ratio, accuracy: 1e-9)
            }
            for i in 0..<bands.count {
                XCTAssertEqual(bands.upper[i] / bands.lower[i], ratio, accuracy: 1e-9)
                XCTAssertEqual(bands.centers[i], (bands.lower[i] * bands.upper[i]).squareRoot(), accuracy: 1e-6)
            }
        }
    }

    func testTiltAndNoteNames() {
        let t = SpectrumMath.tilt([500, 1000, 2000, 8000], dbPerOctave: 4.5)
        XCTAssertEqual(t[0], -4.5, accuracy: 1e-4); XCTAssertEqual(t[1], 0, accuracy: 1e-6)
        XCTAssertEqual(t[2], 4.5, accuracy: 1e-4); XCTAssertEqual(t[3], 13.5, accuracy: 1e-4)
        XCTAssertEqual(SpectrumMath.note(440)?.name, "A4")
        XCTAssertEqual(SpectrumMath.note(440)?.cents, 0)
        XCTAssertEqual(SpectrumMath.note(261.63)?.name, "C4")
        XCTAssertEqual(SpectrumMath.note(1000)?.name, "B5")
        XCTAssertEqual(SpectrumMath.note(1000)?.cents, 21)
    }

    // MARK: Transfer function

    /// y = 0.5 · [¼ ½ ¼] filter of x, `delay` samples late: a linear-phase low-pass with
    /// 1 sample of group delay, so the total delay is delay + 1.
    private func system(_ x: [Float], delay: Int, gain: Float) -> [Float] {
        (0..<x.count).map { n in
            func at(_ i: Int) -> Float { i >= 0 && i < x.count ? x[i] : 0 }
            return gain * (0.25 * at(n - delay) + 0.5 * at(n - delay - 1) + 0.25 * at(n - delay - 2))
        }
    }

    private func transfer(_ x: [Float], _ y: [Float], fftSize: Int) throws -> (OctaveBands, TransferBands, TransferAccumulator) {
        let fft = try XCTUnwrap(SpectrumFFT(size: fftSize, window: .hann))
        let acc = TransferAccumulator(fft: fft)
        var s = 0
        x.withUnsafeBufferPointer { xp in
            y.withUnsafeBufferPointer { yp in
                while s + fftSize <= min(x.count, y.count) {
                    acc.add(x: xp.baseAddress! + s, y: yp.baseAddress! + s, alpha: nil)
                    s += fftSize / 2
                }
            }
        }
        let bands = OctaveBands(fraction: 12)
        let map = BandMap(bands: bands, binHz: fs / Double(fftSize), binCount: fft.bins, enbw: fft.enbw)
        return (bands, acc.banded(map), acc)
    }

    func testTransferRecoversGainDelayAndCoherence() throws {
        let n = Int(fs * 4)
        let x = white(n, seed: 77)
        let y = system(x, delay: 300, gain: 0.5)

        // Delay finder: 301 samples (300 + the filter's one sample of group delay).
        let d = try XCTUnwrap(DelayFinder.find(reference: x, measured: y, fftSize: 16_384))
        XCTAssertEqual(d.samples, 301, accuracy: 0.5)
        XCTAssertFalse(d.inverted)
        XCTAssertGreaterThan(d.clarityDB, 30)

        // Compensate and measure.
        let lag = Int(d.samples.rounded())
        let xs = Array(x[0..<(n - lag)]), ys = Array(y[lag...])
        let (bands, t, acc) = try transfer(xs, ys, fftSize: 8192)
        func band(_ f: Double) -> Int { bands.centers.indices.min { abs(log(bands.centers[$0] / f)) < abs(log(bands.centers[$1] / f)) }! }
        XCTAssertEqual(t.magnitudeDB[band(100)], -6.02, accuracy: 0.3)            // the gain
        XCTAssertEqual(t.magnitudeDB[band(1000)], -6.06, accuracy: 0.3)
        // The filter: |H| = 0.5·(½ + ½cos ω); at 12 kHz (ω = π/2) that is 0.25 → −12 dB.
        XCTAssertEqual(t.magnitudeDB[band(12_000)], -12.0, accuracy: 0.6)
        XCTAssertEqual(t.phaseDeg[band(1000)], 0, accuracy: 5)
        let cohs = bands.centers.indices.filter { bands.centers[$0] >= 50 && bands.centers[$0] <= 10_000 }.map { t.coherence[$0] }
        XCTAssertGreaterThan(cohs.min()!, 0.97)
        // Nothing left to compensate.
        XCTAssertEqual(try XCTUnwrap(acc.impulseDelay()).samples, 0, accuracy: 0.5)

        // Uncompensated, the phase shows the delay: −360° × f × 301 / fs, wrapped.
        let (_, tu, _) = try transfer(x, y, fftSize: 8192)
        let f = bands.centers[band(100)]
        var expect = -360 * f * 301 / fs
        expect = expect.truncatingRemainder(dividingBy: 360)
        if expect < -180 { expect += 360 }
        XCTAssertEqual(Double(tu.phaseDeg[band(100)]), expect, accuracy: 15)
    }

    func testTransferOfUnrelatedNoiseHasLowCoherence() throws {
        let n = Int(fs * 4)
        let x = white(n, seed: 1), y = white(n, seed: 2)
        let (bands, t, _) = try transfer(x, y, fftSize: 8192)
        let cohs = bands.centers.indices.filter { bands.centers[$0] >= 100 && bands.centers[$0] <= 10_000 }.map { t.coherence[$0] }
        let mean = cohs.reduce(0, +) / Float(cohs.count)
        XCTAssertLessThan(mean, 0.15)
        XCTAssertNil(DelayFinder.find(reference: x, measured: y, fftSize: 16_384))
    }

    func testInvertedCopyIsFlaggedByDelayFinder() throws {
        let x = white(Int(fs * 2), seed: 9)
        let y = system(x, delay: 1200, gain: -0.8)
        let d = try XCTUnwrap(DelayFinder.find(reference: x, measured: y, fftSize: 16_384))
        XCTAssertEqual(d.samples, 1201, accuracy: 0.5)
        XCTAssertTrue(d.inverted)
    }

    // MARK: Averaging

    func testAveragingTimeConstants() {
        XCTAssertEqual(SpectrumAveraging.off.alpha(hopSeconds: 0.01, frames: 5), 1)
        XCTAssertEqual(SpectrumAveraging.infinite.alpha(hopSeconds: 0.01, frames: 3), 0.25)
        // After one time constant an exponential average has moved 63 %.
        let a = SpectrumAveraging.slow.alpha(hopSeconds: 0.01, frames: 0)
        var v: Float = 0
        for _ in 0..<150 { v += a * (1 - v) }
        XCTAssertEqual(v, 1 - expf(-1), accuracy: 0.01)
    }
}
