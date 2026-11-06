import Foundation

/// 2×2 routing matrix. `ll` = source L → out L, `rl` = source R → out L,
/// `lr` = source L → out R, `rr` = source R → out R.
struct GainMatrix: Equatable {
    var ll: Float = 1, rl: Float = 0, lr: Float = 0, rr: Float = 1
    static let identity = GainMatrix()
    static let silent = GainMatrix(ll: 0, rl: 0, lr: 0, rr: 0)
}

/// Pure routing math, shared by the render thread and the tests.
enum RoutingMath {
    /// dB → linear. Anything at or below -120 dB (incl. -inf / NaN) is silence.
    static func linearGain(dB: Float) -> Float {
        guard dB.isFinite, dB > -120 else { return 0 }
        return powf(10, min(dB, 24) / 20)
    }

    static func dBFS(_ linear: Float) -> Float {
        linear > 0 ? 20 * log10f(linear) : -.infinity
    }

    /// Mute follows the SOURCE channel; `swapped` crosses the pair; gain applies to both.
    static func matrix(for r: ChannelRouting) -> GainMatrix {
        let g = linearGain(dB: r.gainDB)
        let l: Float = r.leftEnabled ? g : 0
        let rt: Float = r.rightEnabled ? g : 0
        if r.swapped {
            return GainMatrix(ll: 0, rl: rt, lr: l, rr: 0)
        }
        return GainMatrix(ll: l, rl: 0, lr: 0, rr: rt)
    }

    /// Packs routing into 64 bits so it can be published to the render thread atomically.
    static func pack(_ r: ChannelRouting) -> UInt64 {
        var flags: UInt64 = 0
        if r.leftEnabled { flags |= 1 }
        if r.rightEnabled { flags |= 2 }
        if r.swapped { flags |= 4 }
        return (UInt64(r.gainDB.bitPattern) << 32) | flags
    }

    static func unpack(_ bits: UInt64) -> ChannelRouting {
        ChannelRouting(leftEnabled: bits & 1 != 0,
                       rightEnabled: bits & 2 != 0,
                       swapped: bits & 4 != 0,
                       gainDB: Float(bitPattern: UInt32(truncatingIfNeeded: bits >> 32)))
    }
}

/// Linear ramp of all four matrix coefficients toward a target over a fixed number of frames.
/// A value type with no allocation; safe to keep in render-thread state.
struct GainRamp {
    private(set) var current: GainMatrix
    private(set) var target: GainMatrix
    private var step = GainMatrix.silent
    private(set) var remaining = 0
    let rampFrames: Int

    init(rampFrames: Int, initial: GainMatrix = .identity) {
        self.rampFrames = max(1, rampFrames)
        current = initial
        target = initial
    }

    var isSettled: Bool { remaining == 0 }

    mutating func setTarget(_ m: GainMatrix) {
        guard m != target || remaining > 0 else { return }
        target = m
        let n = Float(rampFrames)
        step = GainMatrix(ll: (m.ll - current.ll) / n, rl: (m.rl - current.rl) / n,
                          lr: (m.lr - current.lr) / n, rr: (m.rr - current.rr) / n)
        remaining = rampFrames
    }

    /// Jump straight to `m` (no ramp).
    mutating func snap(to m: GainMatrix) {
        current = m; target = m; remaining = 0
    }

    /// out[L/R] = matrix · src[L/R]. In-place is allowed (out may alias src).
    mutating func process(srcL: UnsafePointer<Float>, srcR: UnsafePointer<Float>,
                          outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, count: Int) {
        var i = 0
        while i < count && remaining > 0 {
            current.ll += step.ll; current.rl += step.rl; current.lr += step.lr; current.rr += step.rr
            remaining -= 1
            if remaining == 0 { current = target }
            let l = srcL[i], r = srcR[i]
            outL[i] = current.ll * l + current.rl * r
            outR[i] = current.lr * l + current.rr * r
            i += 1
        }
        let m = current
        while i < count {
            let l = srcL[i], r = srcR[i]
            outL[i] = m.ll * l + m.rl * r
            outR[i] = m.lr * l + m.rr * r
            i += 1
        }
    }
}

/// Linear scalar ramp (transport fades, panic fade).
struct ScalarRamp {
    private(set) var value: Float
    private(set) var target: Float
    private var step: Float = 0
    private(set) var remaining = 0

    init(_ value: Float) { self.value = value; target = value }

    var isSettled: Bool { remaining == 0 }

    mutating func ramp(to t: Float, frames: Int) {
        guard t != target || remaining > 0 else { return }
        target = t
        let n = max(1, frames)
        step = (t - value) / Float(n)
        remaining = n
    }

    mutating func snap(to t: Float) { value = t; target = t; remaining = 0 }

    /// Multiplies `count` samples of both buffers by the ramping gain.
    mutating func apply(_ a: UnsafeMutablePointer<Float>, _ b: UnsafeMutablePointer<Float>, count: Int) {
        if remaining == 0 {
            let g = value
            if g == 1 { return }
            for i in 0..<count { a[i] *= g; b[i] *= g }
            return
        }
        for i in 0..<count {
            if remaining > 0 {
                value += step
                remaining -= 1
                if remaining == 0 { value = target }
            }
            a[i] *= value; b[i] *= value
        }
    }
}
