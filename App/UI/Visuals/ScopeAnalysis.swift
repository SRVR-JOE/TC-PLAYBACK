import Foundation
import TCKit

// Owned by the VISUALS agent. The scope's own signal analysis: bi-phase LTC bit recovery (for
// the decode row and eye diagram) and per-channel measurements. Pure functions over a buffer.

struct LTCAnalysis {
    struct Bit {
        var value: UInt8
        /// Sample positions (fractional) of the cell's leading and trailing boundary.
        var start: Double
        var end: Double
    }

    var bits: [Bit] = []
    /// Index ranges into `bits` that form a sync word.
    var syncRanges: [Range<Int>] = []
    var isReverse = false
    /// Timecode decoded from the most recent complete frame in the buffer ("01:00:12:04").
    var timecodeText: String?
    /// Bit period in samples.
    var bitPeriod: Double = 0
    var mid: Float = 0
    var amplitude: Float = 0
    /// 0…1; nil if not enough cells.
    var eyeHeight: Double?
    /// Peak-to-peak boundary jitter, seconds.
    var jitterPP: Double?
    /// Mean 10–90 % rise time, seconds.
    var riseTime: Double?

    var isLTC: Bool { !syncRanges.isEmpty }

    static let syncForward: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
    static let syncReverse: [UInt8] = Array(syncForward.reversed())

    static func analyze(_ s: [Float], sampleRate: Double, rateHint: FrameRate?) -> LTCAnalysis {
        var a = LTCAnalysis()
        let n = s.count
        guard n > 64 else { return a }
        var lo = s[0], hi = s[0]
        for v in s { lo = min(lo, v); hi = max(hi, v) }
        a.mid = (hi + lo) / 2
        a.amplitude = (hi - lo) / 2
        guard a.amplitude > 0.003 else { return a }

        // Zero (mid) crossings with hysteresis, interpolated to a fraction of a sample.
        let hyst = a.amplitude * 0.3
        var crossings: [Double] = []
        crossings.reserveCapacity(256)
        var state = s[0] > a.mid ? 1 : -1
        for i in 1..<n {
            let v = s[i] - a.mid
            if state < 0, v > hyst {
                state = 1
            } else if state > 0, v < -hyst {
                state = -1
            } else { continue }
            // Walk back to the actual mid crossing.
            var j = i
            while j > 0, (s[j - 1] - a.mid) * (s[j] - a.mid) > 0 { j -= 1 }
            if j > 0 {
                let y0 = s[j - 1] - a.mid, y1 = s[j] - a.mid
                let f = y1 == y0 ? 0 : Double(-y0 / (y1 - y0))
                crossings.append(Double(j - 1) + f)
            }
        }
        guard crossings.count > 24 else { return a }

        var intervals: [Double] = []
        for i in 1..<crossings.count { intervals.append(crossings[i] - crossings[i - 1]) }
        var t0: Double
        if let r = rateHint {
            t0 = sampleRate / (r.fps * 80)
        } else {
            let sorted = intervals.sorted()
            t0 = sorted[Int(Double(sorted.count) * 0.9)]
        }
        // Refine T from the cells themselves; require a clean bi-phase interval distribution.
        var sum = 0.0, count = 0.0, clean = 0
        for d in intervals {
            if abs(d - t0) < t0 * 0.25 { sum += d; count += 1; clean += 1 }
            else if abs(d - t0 / 2) < t0 * 0.15 { sum += 2 * d; count += 1; clean += 1 }
        }
        guard count > 0, Double(clean) / Double(intervals.count) > 0.9 else { return a }
        let t = sum / count
        a.bitPeriod = t

        // Bit recovery: a long interval is a whole "0" cell; two short ones make a "1".
        guard var k = intervals.firstIndex(where: { $0 > t * 0.75 }) else { return a }
        while k < intervals.count {
            let d = intervals[k]
            if d > t * 0.75 {
                a.bits.append(Bit(value: 0, start: crossings[k], end: crossings[k + 1]))
                k += 1
            } else if k + 1 < intervals.count, intervals[k + 1] <= t * 0.75 {
                a.bits.append(Bit(value: 1, start: crossings[k], end: crossings[k + 2]))
                k += 2
            } else {
                k += 1  // lost cell alignment; resync on the next long interval
                while k < intervals.count, intervals[k] <= t * 0.75 { k += 1 }
            }
        }

        // Sync words.
        let values = a.bits.map(\.value)
        if values.count >= 16 {
            for i in 0...(values.count - 16) {
                let w = values[i..<(i + 16)]
                if w.elementsEqual(syncForward) { a.syncRanges.append(i..<(i + 16)) }
                else if w.elementsEqual(syncReverse) { a.syncRanges.append(i..<(i + 16)); a.isReverse = true }
            }
        }
        // Timecode from the latest forward frame (64 data bits before the sync word).
        if !a.isReverse, let r = a.syncRanges.last(where: { $0.lowerBound >= 64 }) {
            let f = Array(values[(r.lowerBound - 64)..<r.lowerBound])
            func bcd(_ at: Int, _ c: Int) -> Int { (0..<c).reduce(0) { $0 | (Int(f[at + $1]) << $1) } }
            let fr = bcd(0, 4) + 10 * bcd(8, 2), sec = bcd(16, 4) + 10 * bcd(24, 3)
            let mn = bcd(32, 4) + 10 * bcd(40, 3), hr = bcd(48, 4) + 10 * bcd(56, 2)
            if fr < 30, sec < 60, mn < 60, hr < 24 {
                let df = f[10] == 1
                a.timecodeText = String(format: "%02d:%02d:%02d%@%02d", hr, mn, sec, df ? ";" : ":", fr)
            }
        }

        // Eye: sample each half-cell at its centre.
        var highs: [Double] = [], lows: [Double] = []
        func sample(at x: Double) -> Double? {
            let i = Int(x)
            guard i >= 0, i + 1 < n else { return nil }
            let f = x - Double(i)
            return Double(s[i]) * (1 - f) + Double(s[i + 1]) * f
        }
        for b in a.bits {
            for q in [0.25, 0.75] {
                if let v = sample(at: b.start + q * (b.end - b.start)) {
                    if v > Double(a.mid) { highs.append(v) } else { lows.append(v) }
                }
            }
        }
        if highs.count > 4, lows.count > 4 {
            let meanH = highs.reduce(0, +) / Double(highs.count), meanL = lows.reduce(0, +) / Double(lows.count)
            let open = (highs.min()! - lows.max()!) / max(1e-6, meanH - meanL)
            a.eyeHeight = max(0, min(1, open))
        }

        // Jitter: residual of each cell boundary against a least-squares bit-clock line.
        let starts = a.bits.map(\.start)
        if starts.count > 8 {
            let m = Double(starts.count)
            let xs = (0..<starts.count).map(Double.init)
            let mx = xs.reduce(0, +) / m, my = starts.reduce(0, +) / m
            var sxy = 0.0, sxx = 0.0
            for i in 0..<starts.count { sxy += (xs[i] - mx) * (starts[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
            let slope = sxy / sxx, icpt = my - slope * mx
            var rmin = Double.infinity, rmax = -Double.infinity
            for i in 0..<starts.count {
                let r = starts[i] - (icpt + slope * xs[i])
                rmin = min(rmin, r); rmax = max(rmax, r)
            }
            a.jitterPP = (rmax - rmin) / sampleRate
        }

        // Rise time (10–90 %) on rising boundaries.
        let l10 = lo + 0.1 * (hi - lo), l90 = lo + 0.9 * (hi - lo)
        var rises: [Double] = []
        for c in crossings {
            let i = Int(c)
            guard i > 2, i + 3 < n, s[i + 1] > s[i] else { continue }
            var j = i; while j > 0, s[j] > l10 { j -= 1 }
            var k2 = i + 1; while k2 < n - 1, s[k2] < l90 { k2 += 1 }
            guard j > 0, k2 < n - 1, k2 - j < Int(t) else { continue }
            let t10 = Double(j) + Double((l10 - s[j]) / max(1e-6, s[j + 1] - s[j]))
            let t90 = Double(k2 - 1) + Double((l90 - s[k2 - 1]) / max(1e-6, s[k2] - s[k2 - 1]))
            if t90 > t10 { rises.append(t90 - t10) }
        }
        if !rises.isEmpty { a.riseTime = rises.reduce(0, +) / Double(rises.count) / sampleRate }
        return a
    }
}

/// Per-channel readouts for the measurement strip.
struct ChannelMeasurement {
    var vppDBFS: Float = -.infinity
    var rmsDBFS: Float = -.infinity
    /// DC offset as a fraction of full scale.
    var dc: Float = 0
    var frequency: Double?

    static func measure(_ s: [Float], sampleRate: Double) -> ChannelMeasurement {
        var m = ChannelMeasurement()
        guard !s.isEmpty else { return m }
        var lo = s[0], hi = s[0], sum: Float = 0, sq: Float = 0
        for v in s { lo = min(lo, v); hi = max(hi, v); sum += v; sq += v * v }
        let n = Float(s.count)
        m.dc = sum / n
        m.vppDBFS = 20 * log10f(max(1e-6, (hi - lo) / 2))
        m.rmsDBFS = 20 * log10f(max(1e-6, (sq / n - m.dc * m.dc).squareRoot()))
        // Frequency from rising mid-crossings with hysteresis.
        let mid = (hi + lo) / 2, h = (hi - lo) * 0.2
        guard h > 0.001 else { return m }
        var armed = false, first = -1, last = -1, count = 0
        for (i, v) in s.enumerated() {
            if v < mid - h { armed = true }
            if armed, v > mid + h {
                armed = false
                if first < 0 { first = i } else { count += 1; last = i }
            }
        }
        if count > 0 { m.frequency = Double(count) / (Double(last - first) / sampleRate) }
        return m
    }
}
