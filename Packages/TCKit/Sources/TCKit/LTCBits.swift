import Foundation

// SMPTE 12M-1 linear timecode bit layout, shared by the encoder and decoder.
//
// Bit 0 is transmitted first. A frame's 64 data bits live in a UInt64 with frame bit k at bit k;
// the sync word (bits 64…79) is kept separately as a UInt16 with frame bit 64+i at bit i.
//
//   0– 3 frame units      4– 7 user group 1     8– 9 frame tens     10 drop-frame flag
//  11    colour frame    12–15 user group 2    16–19 second units  20–23 user group 3
//  24–26 second tens     27    flag (polarity at 24/30, BGF0 at 25)  28–31 user group 4
//  32–35 minute units    36–39 user group 5    40–42 minute tens   43 flag (BGF0 at 24/30, BGF2 at 25)
//  44–47 user group 6    48–51 hour units      52–55 user group 7  56–57 hour tens
//  58    BGF1            59    flag (BGF2 at 24/30, polarity at 25)  60–63 user group 8
//  64–79 sync word 0011 1111 1111 1101 (in transmission order)

enum LTCBits {
    /// Sync word with frame bit 64+i at bit i (transmission order 0,0,1×12,0,1).
    static let sync: UInt64 = 0xBFFC
    /// Number of 1 bits in the sync word.
    static let syncOnes = 13

    @inline(__always)
    static func userGroupOffset(_ g: Int) -> Int { 4 + 8 * g }

    /// Builds the 64 data bits. `polarityBit` is 27 (24/30 fps family) or 59 (25 fps); it is set
    /// so the whole 80-bit frame has an even number of ones, which makes every frame start on the
    /// same signal polarity in bi-phase mark.
    @inline(__always)
    static func dataWord(hours: Int, minutes: Int, seconds: Int, frames: Int,
                         dropFrame: Bool, userBits: UInt32, polarityBit: Int) -> UInt64 {
        var w: UInt64 = 0
        w |= UInt64(frames % 10)
        w |= UInt64(frames / 10 & 0x3) << 8
        if dropFrame { w |= 1 << 10 }
        w |= UInt64(seconds % 10) << 16
        w |= UInt64(seconds / 10 & 0x7) << 24
        w |= UInt64(minutes % 10) << 32
        w |= UInt64(minutes / 10 & 0x7) << 40
        w |= UInt64(hours % 10) << 48
        w |= UInt64(hours / 10 & 0x3) << 56
        var ub = UInt64(userBits)
        var g = 0
        while g < 8 {
            w |= (ub & 0xF) << UInt64(userGroupOffset(g))
            ub >>= 4
            g += 1
        }
        if (w.nonzeroBitCount + syncOnes) & 1 == 1 { w |= 1 << UInt64(polarityBit) }
        return w
    }

    struct Fields {
        var hours: Int, minutes: Int, seconds: Int, frames: Int
        var dropFrame: Bool
        var userBits: UInt32
    }

    /// Decodes and range-checks the data bits. Returns nil for malformed BCD.
    @inline(__always)
    static func fields(_ w: UInt64) -> Fields? {
        @inline(__always) func f(_ shift: UInt64, _ mask: UInt64) -> Int { Int((w >> shift) & mask) }
        let fu = f(0, 0xF), ft = f(8, 0x3)
        let su = f(16, 0xF), st = f(24, 0x7)
        let mu = f(32, 0xF), mt = f(40, 0x7)
        let hu = f(48, 0xF), ht = f(56, 0x3)
        guard fu <= 9, su <= 9, mu <= 9, hu <= 9 else { return nil }
        let frames = ft * 10 + fu, seconds = st * 10 + su, minutes = mt * 10 + mu, hours = ht * 10 + hu
        guard frames < 30, seconds < 60, minutes < 60, hours < 24 else { return nil }
        let df = (w >> 10) & 1 == 1
        if df, seconds == 0, frames < 2, minutes % 10 != 0 { return nil } // frames that DF never sends
        var ub: UInt32 = 0
        var g = 0
        while g < 8 {
            ub |= UInt32((w >> UInt64(userGroupOffset(g))) & 0xF) << UInt32(4 * g)
            g += 1
        }
        return Fields(hours: hours, minutes: minutes, seconds: seconds, frames: frames, dropFrame: df, userBits: ub)
    }

    /// Splits an absolute frame count into H:M:S:F without touching `Timecode`/`FrameRate`
    /// (used on the audio thread). Same algorithm as `Timecode.init(frameNumber:rate:)`.
    @inline(__always)
    static func split(frameNumber: Int, nominal: Int, dropFrame: Bool) -> (h: Int, m: Int, s: Int, f: Int) {
        var n = frameNumber
        if dropFrame {
            let d = n / 17982, r = n % 17982
            n += 18 * d + (r > 1 ? 2 * ((r - 2) / 1798) : 0)
        }
        return ((n / (nominal * 3600)) % 24, (n / (nominal * 60)) % 60, (n / nominal) % 60, n % nominal)
    }

    static func framesPerDay(nominal: Int, dropFrame: Bool) -> Int {
        dropFrame ? 24 * 60 * 60 * 30 - 2 * (24 * 60 - 24 * 6) : 24 * 60 * 60 * nominal
    }
}

/// Real-time-friendly description of a FrameRate (no String-backed enum on the audio thread).
struct RateInfo {
    let nominal: Int
    let dropFrame: Bool
    /// fps = fpsNum / fpsDen exactly.
    let fpsNum: Double
    let fpsDen: Double
    let polarityBit: Int
    let code: UInt64

    init(_ r: FrameRate) {
        switch r {
        case .fps23_976: nominal = 24; dropFrame = false; fpsNum = 24000; fpsDen = 1001; polarityBit = 27; code = 0
        case .fps24: nominal = 24; dropFrame = false; fpsNum = 24; fpsDen = 1; polarityBit = 27; code = 1
        case .fps25: nominal = 25; dropFrame = false; fpsNum = 25; fpsDen = 1; polarityBit = 59; code = 2
        case .fps29_97ndf: nominal = 30; dropFrame = false; fpsNum = 30000; fpsDen = 1001; polarityBit = 27; code = 3
        case .fps29_97df: nominal = 30; dropFrame = true; fpsNum = 30000; fpsDen = 1001; polarityBit = 27; code = 4
        case .fps30: nominal = 30; dropFrame = false; fpsNum = 30; fpsDen = 1; polarityBit = 27; code = 5
        }
    }

    static func rate(code: UInt64) -> FrameRate {
        switch code {
        case 0: return .fps23_976
        case 1: return .fps24
        case 2: return .fps25
        case 3: return .fps29_97ndf
        case 4: return .fps29_97df
        default: return .fps30
        }
    }
}
