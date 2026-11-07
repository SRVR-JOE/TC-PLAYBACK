import Accelerate
import Foundation
import TCKit

/// Output-vs-input comparison maths for the Scope page. Pure, so it is unit-tested.
enum ScopeCompare {
    /// Frames in 24 hours at `rate` (drop-frame aware).
    static func framesPerDay(_ rate: FrameRate) -> Int {
        rate.isDropFrame ? 24 * 60 * 60 * 30 - 2 * (24 * 60 - 24 * 6) : 24 * 60 * 60 * rate.nominalFPS
    }

    /// How many frames the input is behind the output (positive = input late, negative = early),
    /// taking the shortest way round midnight. nil when the two run at different rates: frame
    /// counts at different rates can't be compared.
    static func framesLate(output: Timecode, input: Timecode) -> Int? {
        guard output.rate == input.rate else { return nil }
        let day = framesPerDay(output.rate)
        var d = (output.frameNumber - input.frameNumber) % day
        if d < 0 { d += day }
        if d > day / 2 { d -= day }
        return d
    }

    /// Everything the status line needs. Rates/timecodes are nil when absent.
    struct Inputs: Equatable {
        var outputPlaying: Bool
        var outputTC: Timecode?
        var outputRate: FrameRate?
        var inputHasSignal: Bool
        var inputTC: Timecode?
        var inputRate: FrameRate?
        /// Measured round trip, nil when the input is not a recognisable copy of the output.
        var latencyMS: Double?
        var inverted: Bool = false
    }

    /// One plain sentence for the operator.
    static func statusLine(_ c: Inputs) -> String {
        let ms = c.latencyMS.map { formatMS($0) }
        guard c.outputPlaying else {
            if let r = c.inputRate { return "Nothing playing. The input has timecode at \(r.operatorLabel)" }
            return "Nothing playing"
        }
        guard c.inputHasSignal else { return "Waiting for the device audio input" }
        guard let inRate = c.inputRate, let inTC = c.inputTC else {
            if let ms { return "No timecode on the input. Audio returns after \(ms)" + (c.inverted ? ", polarity inverted" : "") }
            return c.outputRate == nil ? "No timecode on the input or the output" : "No timecode on the input"
        }
        guard let outRate = c.outputRate, let outTC = c.outputTC else {
            return "The output has no timecode. Input is at \(inRate.operatorLabel)"
        }
        guard inRate == outRate, let late = framesLate(output: outTC, input: inTC) else {
            return "Input rate \(inRate.operatorLabel) does not match output \(outRate.operatorLabel)"
        }
        let suffix = ms.map { " (\($0))" } ?? ""
        let pol = c.inverted ? ", polarity inverted" : ""
        // Beyond a couple of seconds this is not a loop back of our output; say how far apart.
        if abs(late) > outRate.nominalFPS * 2 {
            let tc = Timecode(frameNumber: abs(late), rate: outRate).description
            return "Input timecode is \(tc) \(late > 0 ? "behind" : "ahead of") the output"
        }
        if late == 0 { return "Input matches output, in sync\(suffix)\(pol)" }
        let n = abs(late)
        return "Input matches output, \(n) frame\(n == 1 ? "" : "s") \(late > 0 ? "late" : "early")\(suffix)\(pol)"
    }

    static func formatMS(_ ms: Double) -> String {
        ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }
}

/// Finds how far one signal is delayed against another by cross-correlation (FFT, vDSP).
enum LatencyEstimator {
    struct Result: Equatable {
        /// Delay of `delayed` behind `reference`, in samples (sub-sample, parabolic peak).
        var lagSamples: Double
        /// Normalised correlation at the peak, 0…1.
        var confidence: Float
        /// The input is the output upside down (negative correlation peak).
        var inverted: Bool
    }

    /// `reference` and `delayed` cover the same span of time, sample-aligned, and must be at
    /// least `window + maxLag` long. The last `window` samples of `delayed` are searched for in
    /// the last `window + maxLag` samples of `reference`, for delays 0…maxLag.
    static func estimate(reference: [Float], delayed: [Float], window: Int, maxLag: Int) -> Result? {
        let span = window + maxLag
        guard window >= 64, maxLag >= 1, reference.count >= span, delayed.count >= window else { return nil }
        let o = Array(reference[(reference.count - span)...])
        let i = Array(delayed[(delayed.count - window)...])
        var ei: Float = 0
        vDSP_svesq(i, 1, &ei, vDSP_Length(window))
        guard ei > 1e-9 else { return nil }

        let corr = crossCorrelate(o, i, lags: maxLag + 1)
        guard corr.count == maxLag + 1 else { return nil }

        // Energy of each `window`-long slice of o, from a running sum of squares.
        var sq = [Float](repeating: 0, count: o.count)
        vDSP_vsq(o, 1, &sq, 1, vDSP_Length(o.count))
        var e = [Double](repeating: 0, count: maxLag + 1)
        var run = 0.0
        for k in 0..<window { run += Double(sq[k]) }
        e[0] = run
        if maxLag > 0 {
            for n in 1...maxLag { run += Double(sq[n + window - 1]) - Double(sq[n - 1]); e[n] = max(0, run) }
        }
        var bestN = 0
        var best: Float = 0
        var norm = [Float](repeating: 0, count: maxLag + 1)
        for n in 0...maxLag {
            let d = (e[n] * Double(ei)).squareRoot()
            norm[n] = d > 1e-12 ? Float(Double(corr[n]) / d) : 0
            if abs(norm[n]) > abs(best) { best = norm[n]; bestN = n }
        }
        guard abs(best) > 0 else { return nil }
        // Parabolic interpolation around the peak.
        var delta = 0.0
        if bestN > 0, bestN < maxLag {
            let a = Double(abs(norm[bestN - 1])), b = Double(abs(norm[bestN])), c = Double(abs(norm[bestN + 1]))
            let den = a - 2 * b + c
            if abs(den) > 1e-12 { delta = max(-0.5, min(0.5, 0.5 * (a - c) / den)) }
        }
        let n = Double(bestN) + delta
        return Result(lagSamples: Double(maxLag) - n, confidence: min(1, abs(best)), inverted: best < 0)
    }

    /// c[n] = Σ_k o[n+k]·i[k] for n in 0..<lags, via zero-padded FFT.
    static func crossCorrelate(_ o: [Float], _ i: [Float], lags: Int) -> [Float] {
        var size = 1
        while size < o.count + i.count { size <<= 1 }
        guard let dft = setup(size) else { return [] }
        var oRe = [Float](repeating: 0, count: size), iRe = oRe
        let zero = [Float](repeating: 0, count: size)
        oRe.replaceSubrange(0..<o.count, with: o)
        iRe.replaceSubrange(0..<i.count, with: i)
        var oF = (real: [Float](repeating: 0, count: size), imag: [Float](repeating: 0, count: size))
        var iF = oF
        dft.forward.transform(inputReal: oRe, inputImaginary: zero, outputReal: &oF.real, outputImaginary: &oF.imag)
        dft.forward.transform(inputReal: iRe, inputImaginary: zero, outputReal: &iF.real, outputImaginary: &iF.imag)
        // O · conj(I)
        var pRe = [Float](repeating: 0, count: size), pIm = pRe
        for k in 0..<size {
            let a = oF.real[k], b = oF.imag[k], c = iF.real[k], d = iF.imag[k]
            pRe[k] = a * c + b * d
            pIm[k] = b * c - a * d
        }
        var outRe = [Float](repeating: 0, count: size), outIm = outRe
        dft.inverse.transform(inputReal: pRe, inputImaginary: pIm, outputReal: &outRe, outputImaginary: &outIm)
        var scale = 1 / Float(size)
        var result = [Float](repeating: 0, count: lags)
        outRe.withUnsafeBufferPointer { src in
            vDSP_vsmul(src.baseAddress!, 1, &scale, &result, 1, vDSP_Length(min(lags, size)))
        }
        return result
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Int: (forward: vDSP.DiscreteFourierTransform<Float>,
                                                          inverse: vDSP.DiscreteFourierTransform<Float>)] = [:]

    private static func setup(_ size: Int) -> (forward: vDSP.DiscreteFourierTransform<Float>,
                                               inverse: vDSP.DiscreteFourierTransform<Float>)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let s = cache[size] { return s }
        guard let f = try? vDSP.DiscreteFourierTransform(count: size, direction: .forward,
                                                         transformType: .complexComplex, ofType: Float.self),
              let inv = try? vDSP.DiscreteFourierTransform(count: size, direction: .inverse,
                                                           transformType: .complexComplex, ofType: Float.self)
        else { return nil }
        cache[size] = (f, inv)
        return (f, inv)
    }
}
