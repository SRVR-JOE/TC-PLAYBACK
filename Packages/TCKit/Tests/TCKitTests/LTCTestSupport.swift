import Foundation
@testable import TCKit

/// Deterministic PRNG so failures reproduce.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Standard normal via Box–Muller.
    mutating func gaussian() -> Float {
        let u1 = max(Double.leastNonzeroMagnitude, Double.random(in: 0..<1, using: &self))
        let u2 = Double.random(in: 0..<1, using: &self)
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
    }
}

enum LTCTest {
    /// Render `seconds` of LTC with random render-chunk sizes.
    static func encode(rate: FrameRate, sampleRate: Double, seconds: Double, start: Timecode,
                       level: Float = 0.5, userBits: UInt32 = 0, seed: UInt64 = 1) -> [Float] {
        let enc = LTCEncoder(sampleRate: sampleRate, rate: rate, start: start)
        enc.level = level
        enc.userBits = userBits
        var rng = SplitMix64(seed: seed)
        let total = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: total)
        var pos = 0
        out.withUnsafeMutableBufferPointer { buf in
            while pos < total {
                let n = min(total - pos, Int.random(in: 1...4096, using: &rng))
                enc.render(into: UnsafeMutableBufferPointer(rebasing: buf[pos..<(pos + n)]))
                pos += n
            }
        }
        return out
    }

    /// Decode with random chunk sizes (1…16384, biased small so tiny chunks get exercised too).
    static func decode(_ samples: [Float], sampleRate: Double, rateHint: FrameRate? = nil,
                       seed: UInt64 = 2, decoder: LTCDecoder? = nil) -> [LTCFrame] {
        let dec = decoder ?? LTCDecoder(sampleRate: sampleRate, rateHint: rateHint)
        var rng = SplitMix64(seed: seed)
        var frames: [LTCFrame] = []
        var pos = 0
        samples.withUnsafeBufferPointer { buf in
            while pos < buf.count {
                let maxChunk = [1, 7, 64, 512, 4096, 16384].randomElement(using: &rng)!
                let n = min(buf.count - pos, Int.random(in: 1...maxChunk, using: &rng))
                frames += dec.process(UnsafeBufferPointer(rebasing: buf[pos..<(pos + n)]))
                pos += n
            }
        }
        return frames
    }

    /// Linear-interpolation resample: playback at `speed` × (0.9 = slower, longer output).
    static func varispeed(_ x: [Float], speed: Double) -> [Float] {
        let n = Int(Double(x.count - 1) / speed)
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = Double(i) * speed
            let j = Int(p), f = Float(p - Double(j))
            y[i] = x[j] + (x[min(j + 1, x.count - 1)] - x[j]) * f
        }
        return y
    }

    static func dB(_ x: Float) -> Float { 20 * log10(x) }
    static func amp(dB: Float) -> Float { pow(10, dB / 20) }
}
