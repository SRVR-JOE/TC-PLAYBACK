import Foundation

/// Calibrated test signals and a small stereo WAV writer. Everything is 48 kHz; the side
/// isolation is baked into the file (the unused side is digital silence).
enum TestSignals {
    static let sampleRate: Double = 48_000

    static func dbToLinear(_ db: Float) -> Float { powf(10, db / 20) }

    /// Sine. `levelDBFS` follows AES17: a full-scale sine reads 0 dBFS, so a −18 dBFS tone has
    /// a peak of −18 dBFS (raw RMS −21 dB). This is the usual broadcast alignment convention.
    static func sine(frequency: Double = 1000, levelDBFS: Float = -18, seconds: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        let amp = dbToLinear(levelDBFS)
        let w = 2 * Double.pi * frequency / sampleRate
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = amp * Float(sin(w * Double(i))) }
        applyFades(&out, seconds: 0.005)
        return out
    }

    /// Pink noise via Paul Kellet's refined filter (accurate to ±0.05 dB above 9 Hz),
    /// normalised to `rmsDBFS` raw RMS. Deterministic for a given seed.
    static func pinkNoise(rmsDBFS: Float = -20, seconds: Double, seed: UInt64 = 0x5EED_1234_ABCD) -> [Float] {
        let n = Int(seconds * sampleRate)
        var rng = SplitMix64(seed: seed)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let white = rng.nextUniform() * 2 - 1
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            out[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
        }
        // Remove DC, then scale to the target RMS.
        let mean = out.reduce(0, +) / Float(max(1, n))
        for i in 0..<n { out[i] -= mean }
        let target = dbToLinear(rmsDBFS)
        let r = rms(out)
        if r > 0 { let g = target / r; for i in 0..<n { out[i] *= g } }
        applyFades(&out, seconds: 0.01)
        return out
    }

    /// Polarity check: a train of asymmetric, positive-going clicks (fast rise, slow decay).
    /// A polarity checker or a scope at the speaker reads "+" when the path is non-inverting.
    static func polarityClicks(peakDBFS: Float = -6, interval: Double = 0.5, seconds: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: n)
        let amp = dbToLinear(peakDBFS)
        let rise = Int(0.0002 * sampleRate)            // 0.2 ms rise
        let tau = 0.0015 * sampleRate                  // 1.5 ms decay
        let len = Int(0.012 * sampleRate)
        var start = Int(0.1 * sampleRate)
        let step = Int(interval * sampleRate)
        while start + len < n {
            for k in 0..<len {
                let v: Float
                if k < rise {
                    v = amp * Float(0.5 - 0.5 * cos(Double.pi * Double(k) / Double(rise)))
                } else {
                    v = amp * Float(exp(-Double(k - rise) / tau))
                }
                out[start + k] = v
            }
            start += step
        }
        return out
    }

    static func silence(seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * sampleRate)) }

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var s: Double = 0
        for v in x { s += Double(v) * Double(v) }
        return Float(sqrt(s / Double(x.count)))
    }

    static func peak(_ x: [Float]) -> Float { x.reduce(0) { max($0, abs($1)) } }

    static func applyFades(_ x: inout [Float], seconds: Double) {
        let f = min(x.count / 2, Int(seconds * sampleRate))
        guard f > 0 else { return }
        for i in 0..<f {
            let g = Float(i) / Float(f)
            x[i] *= g
            x[x.count - 1 - i] *= g
        }
    }

    /// Place a mono signal on one side (or both); the other side is exact zero.
    static func place(_ mono: [Float], side: OutputSide) -> (l: [Float], r: [Float]) {
        let zero = [Float](repeating: 0, count: mono.count)
        switch side {
        case .left: return (mono, zero)
        case .right: return (zero, mono)
        case .both: return (mono, mono)
        }
    }

    /// Write 24-bit PCM stereo WAV at 48 kHz.
    static func writeWAV(left: [Float], right: [Float], to url: URL) throws {
        precondition(left.count == right.count)
        let frames = left.count
        let bytesPerSample = 3, channels = 2
        let dataBytes = frames * bytesPerSample * channels
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(Int(sampleRate) * channels * bytesPerSample))
        u16(UInt16(channels * bytesPerSample)); u16(24)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        var pcm = [UInt8](repeating: 0, count: dataBytes)
        var o = 0
        for i in 0..<frames {
            for v in [left[i], right[i]] {
                let c = max(-1, min(1, v))
                let s = Int32((c * 8_388_607).rounded())
                pcm[o] = UInt8(truncatingIfNeeded: s)
                pcm[o + 1] = UInt8(truncatingIfNeeded: s >> 8)
                pcm[o + 2] = UInt8(truncatingIfNeeded: s >> 16)
                o += 3
            }
        }
        d.append(contentsOf: pcm)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url, options: .atomic)
    }

    /// Caches/OutputTest/
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OutputTest", isDirectory: true)
    }

    /// Stable short hash for cache keys (FNV-1a 64).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }
}

/// Small deterministic PRNG.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0..<1
    mutating func nextUniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
