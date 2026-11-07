#if DEBUG
import Foundation
import QuartzCore

/// -spectrumDemo (QA / screenshots only): a synthetic programme fed straight into the
/// spectrum views. Nothing reaches the audio output.
///
/// Output: pink noise with a 63 Hz and a 1 kHz tone. Input: the output after a pretend
/// system and room — 5.3 ms late, a low shelf, a dip at 2.5 kHz, a high roll-off, an
/// early reflection, and a little room noise.
final class SpectrumDemoFeed: SpectrumFeed {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-spectrumDemo") }

    let sampleRate = 48_000.0
    let delaySamples = 254
    var inputOnly = false

    private static let length = 131_072
    private var oL = [Float](repeating: 0, count: length), oR = [Float](repeating: 0, count: length)
    private var iL = [Float](repeating: 0, count: length), iR = [Float](repeating: 0, count: length)
    private var written = 0
    private var start: CFTimeInterval?
    private var pinkL = Pink(seed: 11), pinkR = Pink(seed: 23), hiss = Pink(seed: 5)
    private var chainL = Chain(sampleRate: 48_000), chainR = Chain(sampleRate: 48_000)
    private var phase1 = 0.0, phase2 = 0.0

    func spectrumRead(count: Int, shiftSeconds: Double, into b: SpectrumBuffers) -> SpectrumFeedState {
        generate()
        let st = SpectrumFeedState(sampleRate: sampleRate, inputFrames: written,
                                   outputFrames: inputOnly ? nil : written,
                                   roundTrip: inputOnly ? nil : Double(delaySamples) / sampleRate + 0.00004)
        let n = min(count, Self.length, b.capacity)
        guard n > 0 else { return st }
        let shift = Int((shiftSeconds * sampleRate).rounded())
        let mask = Self.length - 1
        for i in 0..<n {
            let ji = written - n + i, jo = ji - shift
            b.inL[i] = ji >= 0 ? iL[ji & mask] : 0; b.inR[i] = ji >= 0 ? iR[ji & mask] : 0
            b.outL[i] = jo >= 0 ? oL[jo & mask] : 0; b.outR[i] = jo >= 0 ? oR[jo & mask] : 0
        }
        return st
    }

    private func generate() {
        let now = CACurrentMediaTime()
        if start == nil { start = now - Double(Self.length) / sampleRate }
        let target = Int((now - start!) * sampleRate)
        let mask = Self.length - 1
        let todo = min(target - written, Self.length)
        guard todo > 0 else { return }
        if target - written > Self.length { written = target - Self.length }
        for _ in 0..<todo {
            let t1 = Float(sin(phase1)) * 0.1, t2 = Float(sin(phase2)) * 0.03
            phase1 += 2 * .pi * 63 / sampleRate; phase2 += 2 * .pi * 1000 / sampleRate
            if phase1 > 2 * .pi { phase1 -= 2 * .pi }
            if phase2 > 2 * .pi { phase2 -= 2 * .pi }
            let l = pinkL.next() * 0.12 + t1 + t2
            let r = pinkR.next() * 0.12 + t1 * 0.8
            let w = written & mask
            oL[w] = l; oR[w] = r
            let d = (written - delaySamples) & mask
            let srcL = written >= delaySamples ? oL[d] : 0, srcR = written >= delaySamples ? oR[d] : 0
            let room = hiss.next() * 0.0015
            iL[w] = chainL.process(srcL) + room
            iR[w] = chainR.process(srcR) + room
            written += 1
        }
    }

    /// Paul Kellet's refined pink noise filter over a white LCG.
    struct Pink {
        var s: UInt32
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        init(seed: UInt32) { s = seed }
        mutating func white() -> Float {
            s = s &* 1_664_525 &+ 1_013_904_223
            return Float(s >> 8) / Float(1 << 23) - 1
        }
        mutating func next() -> Float {
            let w = white()
            b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
            let p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
            b6 = w * 0.115926
            return p * 0.11
        }
    }

    /// Low shelf + dip + roll-off + one reflection.
    struct Chain {
        var shelf: Biquad, dip: Biquad, lp: Biquad
        var echo = [Float](repeating: 0, count: 64)
        var e = 0
        init(sampleRate fs: Double) {
            shelf = .lowShelf(fs: fs, f: 120, gainDB: 4)
            dip = .peak(fs: fs, f: 2500, q: 2, gainDB: -6)
            lp = .lowPass(fs: fs, f: 11_000, q: 0.7)
        }
        mutating func process(_ x: Float) -> Float {
            let y = lp.process(dip.process(shelf.process(x))) * 0.7
            let reflected = echo[e]
            echo[e] = y
            e = (e + 1) % 58               // 1.2 ms reflection
            return y + reflected * 0.25
        }
    }

    /// RBJ cookbook biquad.
    struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var z1: Float = 0, z2: Float = 0
        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
        static func make(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Biquad {
            Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0), a1: Float(a1 / a0), a2: Float(a2 / a0))
        }
        static func peak(fs: Double, f: Double, q: Double, gainDB: Double) -> Biquad {
            let A = pow(10, gainDB / 40), w = 2 * Double.pi * f / fs, al = sin(w) / (2 * q)
            return make(1 + al * A, -2 * cos(w), 1 - al * A, 1 + al / A, -2 * cos(w), 1 - al / A)
        }
        static func lowPass(fs: Double, f: Double, q: Double) -> Biquad {
            let w = 2 * Double.pi * f / fs, al = sin(w) / (2 * q), c = cos(w)
            return make((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al)
        }
        static func lowShelf(fs: Double, f: Double, gainDB: Double) -> Biquad {
            let A = pow(10, gainDB / 40), w = 2 * Double.pi * f / fs, c = cos(w)
            let al = sin(w) / 2 * sqrt(2.0), sq = 2 * sqrt(A) * al   // shelf slope 1
            return make(A * ((A + 1) - (A - 1) * c + sq), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sq),
                        (A + 1) + (A - 1) * c + sq, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sq)
        }
    }
}
#endif
