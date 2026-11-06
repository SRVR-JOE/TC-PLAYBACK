import Foundation
import Synchronization

// CONTRACT FILE — public API is frozen. The TCKit owner replaces the stub bodies with real
// implementations (and may add internal/private helpers and more files). Do not rename or
// change any public signature: the app is being built against these in parallel.

/// One decoded LTC frame.
public struct LTCFrame: Sendable, Equatable {
    public var timecode: Timecode
    /// 32 user bits, group 1 in the low nibble.
    public var userBits: UInt32
    /// True when the sync word was read backwards (tape/track playing in reverse).
    public var isReverse: Bool
    /// Absolute sample index (in the stream fed to the decoder) where this frame's sync word ended.
    /// (For reverse playback: where the frame's last-arriving bit, bit 0, ended.)
    public var endSample: Int64
    /// Peak absolute amplitude seen across the frame (0…1), for the "LTC level" readout.
    /// Measured as half the peak-to-peak swing, so a DC offset does not inflate it.
    public var level: Float

    public init(timecode: Timecode, userBits: UInt32, isReverse: Bool, endSample: Int64, level: Float) {
        self.timecode = timecode; self.userBits = userBits; self.isReverse = isReverse
        self.endSample = endSample; self.level = level
    }
}

// MARK: - Decoder

/// Streaming SMPTE 12M LTC decoder for one mono channel of float samples.
/// Not thread-safe: feed from a single (non real-time) thread.
public final class LTCDecoder {
    public let sampleRate: Double

    /// Frame rate hint. nil = auto-detect (24/25/30 family from bit period; 29.97 vs 30 and
    /// 23.976 vs 24 from frame-arrival timing; DF from the drop-frame flag bit).
    /// When set, decoded frames are labelled with this rate; `detectedRate` still reports
    /// what the signal measures as.
    public var rateHint: FrameRate?

    // Front end: envelope-tracking Schmitt trigger with interpolated mid-level crossings.
    private var primed = false
    private var envHi: Float = 0
    private var envLo: Float = 0
    private var prevD: Float = 0
    private var high = false
    private var cross: Double = 0
    private var crossValid = false
    private var levelMin: Float = 0
    private var levelMax: Float = 0
    private var sampleIndex: Int64 = 0
    private let envDecay: Float
    private let minSpan: Float
    private static let hysteresis: Float = 0.125 // of peak-to-peak span (= 25% of peak amplitude)

    // Bit slicer (all times in samples).
    private var lastEdge: Double = -1e12
    private var bitLen: Double = 0
    private var haveBitLen = false
    private var pendingShort = false
    private var shortLen: Double = 0
    private var cleanBits = 0
    private var errorRun = 0
    private let longMinAbs: Double, longMaxAbs: Double
    private let shortMinAbs: Double, shortMaxAbs: Double

    // 80-bit windows. fwd: newest bit enters at position 79 (frame bit k at k after a forward frame).
    // rev: newest bit enters at position 0 (frame bit k at k after a reversed frame).
    private var fwdLo: UInt64 = 0, fwdHi: UInt64 = 0
    private var revLo: UInt64 = 0, revHi: UInt64 = 0

    // Rate detection.
    private var maxFrameSeen = -1
    private var wrapNominal = 0
    private var lastDF = false
    private var prevValid = false
    private var prevTime: Double = 0
    private var prevFields = LTCBits.Fields(hours: 0, minutes: 0, seconds: 0, frames: 0, dropFrame: false, userBits: 0)
    private var prevReverse = false
    private var anchorTime: Double = 0
    private var runFrames = 0
    private var measuredFPS: Double = 0
    private var detected: FrameRate?

    public init(sampleRate: Double, rateHint: FrameRate? = nil) {
        self.sampleRate = sampleRate
        self.rateHint = rateHint
        // ±13% around the slowest (23.976) and fastest (30) bit rates.
        let minBitRate = 24_000.0 / 1001.0 * 80 * 0.87
        let maxBitRate = 30.0 * 80 * 1.13
        longMinAbs = sampleRate / maxBitRate
        longMaxAbs = sampleRate / minBitRate
        shortMinAbs = longMinAbs * 0.5
        shortMaxAbs = longMaxAbs * 0.5
        // Envelope time constant ≈ 10 ms; the gate ignores anything under -50 dBFS peak.
        envDecay = Float(1.0 / (2.0 * 0.010 * sampleRate))
        minSpan = 2 * 0.00316
    }

    /// Feed samples; returns every complete frame decoded from this chunk, in order.
    /// Must handle arbitrary chunk sizes (1…16384), DC offset, polarity inversion,
    /// levels from -40 dBFS to 0 dBFS, and ±10% varispeed.
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [LTCFrame] {
        var out: [LTCFrame] = []
        guard let base = samples.baseAddress, samples.count > 0 else { return out }
        let n = samples.count
        if !primed {
            primed = true
            envHi = base[0]; envLo = base[0]; levelMin = base[0]; levelMax = base[0]
        }
        var hi = envHi, lo = envLo, pd = prevD, isHigh = high
        var cr = cross, crValid = crossValid
        var lmin = levelMin, lmax = levelMax
        var idx = sampleIndex
        let k = envDecay, gate = minSpan, hystFrac = LTCDecoder.hysteresis

        var i = 0
        while i < n {
            let x = base[i]
            if x > lmax { lmax = x }
            if x < lmin { lmin = x }
            let decay = (hi - lo) * k
            let h2 = hi - decay, l2 = lo + decay
            hi = x > h2 ? x : h2
            lo = x < l2 ? x : l2
            let span = hi - lo
            let d = x - (hi + lo) * 0.5
            if (d >= 0) != (pd >= 0) {
                let den = pd - d
                cr = Double(idx - 1) + (den != 0 ? Double(pd / den) : 0)
                crValid = true
            }
            pd = d
            if span >= gate {
                let hyst = span * hystFrac
                var edge = false
                if isHigh { if d < -hyst { isHigh = false; edge = true } } else if d > hyst { isHigh = true; edge = true }
                if edge {
                    let t = crValid ? cr : Double(idx)
                    crValid = false
                    if let frame = edgeDetected(at: t, level: (lmax - lmin) * 0.5) {
                        out.append(frame)
                        lmin = x; lmax = x
                    }
                }
            }
            idx += 1
            i += 1
        }
        envHi = hi; envLo = lo; prevD = pd; high = isHigh
        cross = cr; crossValid = crValid
        levelMin = lmin; levelMax = lmax
        sampleIndex = idx
        return out
    }

    /// Best current estimate of the frame rate, or nil until ~1 s of clean frames.
    public var detectedRate: FrameRate? { detected }

    /// Clears all internal state (use after a seek/discontinuity).
    public func reset() {
        primed = false; envHi = 0; envLo = 0; prevD = 0; high = false; cross = 0; crossValid = false
        levelMin = 0; levelMax = 0; sampleIndex = 0
        lastEdge = -1e12; bitLen = 0; haveBitLen = false; pendingShort = false; shortLen = 0
        cleanBits = 0; errorRun = 0
        fwdLo = 0; fwdHi = 0; revLo = 0; revHi = 0
        maxFrameSeen = -1; wrapNominal = 0; lastDF = false; prevValid = false; prevTime = 0
        prevReverse = false; anchorTime = 0; runFrames = 0; measuredFPS = 0
        detected = nil
    }

    // MARK: Internals (also used by TimecodeReader / LTCScanner)

    /// Current bit-period estimate in samples (0 until acquired).
    var bitPeriod: Double { haveBitLen ? bitLen : 0 }
    /// Total samples consumed so far.
    var samplesProcessed: Int64 { sampleIndex }

    @inline(__always)
    private func slicerError() {
        cleanBits = 0
        pendingShort = false
        errorRun += 1
        if errorRun > 24 { haveBitLen = false; errorRun = 0 }
    }

    @inline(__always)
    private func adapt(_ measured: Double) {
        if haveBitLen {
            bitLen += 0.05 * (measured - bitLen)
            if bitLen < longMinAbs * 0.95 || bitLen > longMaxAbs * 1.05 { haveBitLen = false }
        } else if measured >= longMinAbs && measured <= longMaxAbs {
            bitLen = measured
            haveBitLen = true
        }
    }

    private func edgeDetected(at t: Double, level: Float) -> LTCFrame? {
        let d = t - lastEdge
        lastEdge = t
        // 0 = short (half bit), 1 = long (whole bit), 2 = invalid
        let kind: Int
        if haveBitLen {
            let r = d / bitLen
            kind = r < 0.3 ? 2 : (r < 0.75 ? 0 : (r < 1.4 ? 1 : 2))
        } else if d >= shortMinAbs && d <= shortMaxAbs {
            kind = 0
        } else if d >= longMinAbs && d <= longMaxAbs {
            kind = 1
        } else {
            kind = 2
        }
        switch kind {
        case 0:
            if pendingShort {
                pendingShort = false
                adapt(shortLen + d)
                return pushBit(1, t: t, level: level)
            }
            pendingShort = true
            shortLen = d
            return nil
        case 1:
            if pendingShort { slicerError() } // lost half-bit phase; this long is still a valid 0
            adapt(d)
            return pushBit(0, t: t, level: level)
        default:
            slicerError()
            return nil
        }
    }

    @inline(__always)
    private func pushBit(_ b: UInt64, t: Double, level: Float) -> LTCFrame? {
        fwdLo = (fwdLo >> 1) | ((fwdHi & 1) << 63)
        fwdHi = (fwdHi >> 1) | (b << 15)
        revHi = ((revHi << 1) | (revLo >> 63)) & 0xFFFF
        revLo = (revLo << 1) | b
        cleanBits += 1
        if cleanBits >= 32 { errorRun = 0 }
        guard cleanBits >= 80 else { return nil }
        if fwdHi == LTCBits.sync, let f = decodeFrame(fwdLo, reverse: false, t: t, level: level) {
            cleanBits = 0
            return f
        }
        if revHi == LTCBits.sync, let f = decodeFrame(revLo, reverse: true, t: t, level: level) {
            cleanBits = 0
            return f
        }
        return nil
    }

    private func familyNominal() -> Int {
        if lastDF { return 30 }
        if wrapNominal != 0 && maxFrameSeen < wrapNominal { return wrapNominal }
        if maxFrameSeen >= 25 { return 30 }
        // Fall back to the bit rate (exact at nominal speed; ambiguous 24/25 under heavy varispeed).
        var nom = 30
        if haveBitLen {
            let fps = sampleRate / (bitLen * 80)
            nom = fps < 24.5 ? 24 : (fps < 27.5 ? 25 : 30)
        }
        if maxFrameSeen >= nom { nom = maxFrameSeen >= 25 ? 30 : 25 }
        return nom
    }

    private func provisionalRate(nominal: Int) -> FrameRate {
        switch nominal {
        case 24: return .fps24
        case 25: return .fps25
        default: return lastDF ? .fps29_97df : .fps30
        }
    }

    private func decodeFrame(_ data: UInt64, reverse: Bool, t: Double, level: Float) -> LTCFrame? {
        guard let fl = LTCBits.fields(data) else { return nil }
        lastDF = fl.dropFrame
        if fl.frames > maxFrameSeen { maxFrameSeen = fl.frames }

        // Frame-arrival bookkeeping: how many frame periods since the previous good frame?
        let frameDur = (haveBitLen ? bitLen : sampleRate / 2400) * 80
        var gap = 0
        if prevValid {
            let dt = t - prevTime
            let k = (dt / frameDur).rounded()
            if k >= 1, k <= 60, abs(dt - k * frameDur) < 0.3 * frameDur { gap = Int(k) }
        }
        // Observe the frame-count wrap at a seconds boundary: (N-1) → 0 forward, 0 → (N-1) reverse.
        if gap == 1, reverse == prevReverse {
            let p = prevFields
            if !reverse, fl.frames == 0, p.frames >= 23, fl.seconds == (p.seconds + 1) % 60 {
                wrapNominal = p.frames + 1
            } else if reverse, p.frames == 0, fl.frames >= 23, p.seconds == (fl.seconds + 1) % 60 {
                wrapNominal = fl.frames + 1
            }
        }
        let nominal = familyNominal()
        // Counting rate for the sequence check (frame numbering only depends on nominal + DF).
        let counting = provisionalRate(nominal: nominal)
        let fn = Timecode(hours: fl.hours, minutes: fl.minutes, seconds: fl.seconds, frames: fl.frames, rate: counting).frameNumber

        // 29.97 vs 30 and 23.976 vs 24: count sequential frames against the sample clock.
        var sequential = false
        if gap > 0, reverse == prevReverse {
            let perDay = LTCBits.framesPerDay(nominal: counting.nominalFPS, dropFrame: counting.isDropFrame)
            let prevTC = Timecode(hours: prevFields.hours, minutes: prevFields.minutes, seconds: prevFields.seconds,
                                  frames: prevFields.frames, rate: counting)
            let expect = ((prevTC.frameNumber + (reverse ? -gap : gap)) % perDay + perDay) % perDay
            sequential = expect == fn
        }
        if sequential {
            runFrames += gap
            let span = t - anchorTime
            if span >= sampleRate {
                measuredFPS = Double(runFrames) * sampleRate / span
                updateDetected(nominal: nominal)
            }
        } else {
            anchorTime = t
            runFrames = 0
        }
        prevValid = true
        prevTime = t
        prevFields = fl
        prevReverse = reverse

        let label: FrameRate
        if let h = rateHint {
            label = h
        } else if let d = detected, d.nominalFPS == nominal, d.isDropFrame == lastDF {
            label = d
        } else {
            label = counting
        }
        let tc = Timecode(hours: fl.hours, minutes: fl.minutes, seconds: fl.seconds, frames: fl.frames, rate: label)
        return LTCFrame(timecode: tc, userBits: fl.userBits, isReverse: reverse,
                        endSample: Int64(t.rounded()), level: min(1, max(0, level)))
    }

    private func updateDetected(nominal: Int) {
        guard measuredFPS > 0 else { return }
        switch nominal {
        case 24: detected = measuredFPS / 24 < 0.9995 ? .fps23_976 : .fps24
        case 25: detected = .fps25
        default:
            if lastDF { detected = .fps29_97df } else { detected = measuredFPS / 30 < 0.9995 ? .fps29_97ndf : .fps30 }
        }
    }
}

// MARK: - Encoder

/// Streaming SMPTE 12M LTC generator. Produces a band-limited bi-phase signal
/// (rise time ≈ 25 µs per spec, not a raw square wave) at `level` peak amplitude.
///
/// `level`, `userBits`, `locate` and `reconfigure` may be called from any thread while
/// `render` runs on the audio thread; changes are handed over through atomics and take
/// effect at the next `render` (user bits: at the next frame).
public final class LTCEncoder {
    public let sampleRate: Double
    public private(set) var rate: FrameRate
    /// Peak amplitude, 0…1. Default ≈ -10 dBFS.
    public var level: Float {
        get { Float(bitPattern: levelBits.load(ordering: .relaxed)) }
        set { levelBits.store((newValue.isFinite ? min(1, max(0, newValue)) : 0).bitPattern, ordering: .relaxed) }
    }
    public var userBits: UInt32 {
        get { userBitsStore.load(ordering: .relaxed) }
        set { userBitsStore.store(newValue, ordering: .relaxed) }
    }

    private let levelBits = Atomic<UInt32>(Float(0.316).bitPattern)
    private let userBitsStore = Atomic<UInt32>(0)
    /// Pending locate/reconfigure: bit 63 set | rate code << 40 | frame number. 0 = none.
    private let pending = Atomic<UInt64>(0)
    /// Rate code << 40 | frame number of the next sample to render.
    private let published = Atomic<UInt64>(0)

    // Audio-thread state.
    private var info: RateInfo
    private var perDay: Int
    private var frameNumber: Int = 0
    private var epochFrames: Int64 = 0
    private var epochSamples: Int64 = 0
    private var frameStart: Double = 0
    private var nextFrameStart: Double = 0
    private var samplesPerFrame: Double = 0
    private var srDen: Double = 0
    private var halfCell: Double = 0
    private var invHalfCell: Double = 0
    private let edgeLen: Double
    private let halfEdge: Double
    private let invEdgeLen: Double
    /// 160 half-cell levels (±1) of the current frame.
    private let cells: UnsafeMutablePointer<Float>
    /// Raised-cosine edge shape 0…1, 257 points.
    private let edgeLUT: UnsafeMutablePointer<Float>

    public init(sampleRate: Double, rate: FrameRate, start: Timecode) {
        self.sampleRate = sampleRate
        self.rate = rate
        info = RateInfo(rate)
        perDay = LTCBits.framesPerDay(nominal: info.nominal, dropFrame: info.dropFrame)
        // Raised cosine 0.5−0.5·cos(πu): 10–90 % takes 0.5903 of its length. 25 µs rise → 42.35 µs.
        edgeLen = max(1.0, 25e-6 / 0.590_334 * sampleRate)
        halfEdge = edgeLen * 0.5
        invEdgeLen = 1 / edgeLen
        cells = .allocate(capacity: 160)
        cells.initialize(repeating: 1, count: 160)
        edgeLUT = .allocate(capacity: 257)
        for i in 0...256 { edgeLUT[i] = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / 256)) }
        apply(code: info.code, frameNumber: Self.frameNumber(of: start, in: rate))
    }

    deinit {
        cells.deallocate()
        edgeLUT.deallocate()
    }

    /// Timecode of the frame that the next rendered sample belongs to.
    public var currentTimecode: Timecode {
        let p = pending.load(ordering: .acquiring)
        let v = p != 0 ? p : published.load(ordering: .acquiring)
        return Timecode(frameNumber: Int(v & 0xFFFF_FFFF), rate: RateInfo.rate(code: (v >> 40) & 0xFF))
    }

    /// Fill `buffer` with the next samples of the LTC stream (mono). Real-time safe:
    /// no allocation, no locks, no Objective-C/Swift runtime calls.
    public func render(into buffer: UnsafeMutableBufferPointer<Float>) {
        guard let out = buffer.baseAddress else { return }
        let p = pending.exchange(0, ordering: .acquiringAndReleasing)
        if p != 0 { apply(code: (p >> 40) & 0xFF, frameNumber: Int(p & 0xFFFF_FFFF)) }
        // Nothing of this frame has gone out yet: pick up user bits set since init/locate.
        if epochSamples == 0 { buildCells() }
        let amp = Float(bitPattern: levelBits.load(ordering: .relaxed))
        let n = buffer.count
        let c = cells, lut = edgeLUT
        let hc = halfCell, invHC = invHalfCell, he = halfEdge, invE = invEdgeLen
        var s = epochSamples
        var fs = frameStart
        var next = nextFrameStart
        var i = 0
        while i < n {
            let t = Double(s) - fs
            let x = t * invHC
            var j = Int(x)
            if j > 159 { j = 159 } else if j < 0 { j = 0 }
            let pos = t - Double(j) * hc // samples into half-cell j
            let cur = c[j]
            var v = cur
            if pos < he {
                // Edge at the start of cell j; before frame start the level is always -1 (parity bit).
                let prev: Float = j == 0 ? -1 : c[j - 1]
                if prev != cur { v = prev + (cur - prev) * Self.shape(lut, (pos + he) * invE) }
            } else if hc - pos < he {
                let next: Float = j == 159 ? 1 : c[j + 1]
                if next != cur { v = cur + (next - cur) * Self.shape(lut, (pos - hc + he) * invE) }
            }
            out[i] = v * amp
            s += 1
            if Double(s) >= next {
                advanceFrame()
                fs = frameStart
                next = nextFrameStart
            }
            i += 1
        }
        epochSamples = s
        published.store(info.code << 40 | UInt64(frameNumber), ordering: .releasing)
    }

    /// Jump to a new position (next render starts at the beginning of that frame).
    public func locate(to timecode: Timecode) {
        let fn = Self.frameNumber(of: timecode, in: rate)
        pending.store(1 << 63 | RateInfo(rate).code << 40 | UInt64(fn), ordering: .releasing)
    }

    /// Change rate (also re-locates to `start`).
    public func reconfigure(rate: FrameRate, start: Timecode) {
        self.rate = rate
        locate(to: start)
    }

    // MARK: Internals

    @inline(__always)
    private static func shape(_ lut: UnsafeMutablePointer<Float>, _ u: Double) -> Float {
        let x = Float(u < 0 ? 0 : (u > 1 ? 1 : u)) * 256
        var k = Int(x)
        if k > 255 { k = 255 }
        let fr = x - Float(k)
        return lut[k] + (lut[k + 1] - lut[k]) * fr
    }

    private static func frameNumber(of tc: Timecode, in rate: FrameRate) -> Int {
        let t = Timecode(hours: tc.hours, minutes: tc.minutes, seconds: tc.seconds, frames: tc.frames, rate: rate)
        return Timecode(frameNumber: t.frameNumber, rate: rate).frameNumber // normalise / wrap
    }

    private func apply(code: UInt64, frameNumber fn: Int) {
        info = RateInfo(RateInfo.rate(code: code))
        perDay = LTCBits.framesPerDay(nominal: info.nominal, dropFrame: info.dropFrame)
        srDen = sampleRate * info.fpsDen
        samplesPerFrame = srDen / info.fpsNum
        halfCell = samplesPerFrame / 160
        invHalfCell = 1 / halfCell
        frameNumber = ((fn % perDay) + perDay) % perDay
        epochFrames = 0
        epochSamples = 0
        frameStart = 0
        nextFrameStart = samplesPerFrame
        buildCells()
        published.store(info.code << 40 | UInt64(frameNumber), ordering: .releasing)
    }

    @inline(__always)
    private func advanceFrame() {
        epochFrames += 1
        // Frame boundaries come from one exact product (no accumulated rounding): F·sr·den / num.
        frameStart = nextFrameStart
        nextFrameStart = Double(epochFrames + 1) * srDen / info.fpsNum
        frameNumber += 1
        if frameNumber >= perDay { frameNumber = 0 }
        buildCells()
    }

    @inline(__always)
    private func buildCells() {
        let f = LTCBits.split(frameNumber: frameNumber, nominal: info.nominal, dropFrame: info.dropFrame)
        let data = LTCBits.dataWord(hours: f.h, minutes: f.m, seconds: f.s, frames: f.f, dropFrame: info.dropFrame,
                                    userBits: userBitsStore.load(ordering: .relaxed), polarityBit: info.polarityBit)
        var lvl: Float = -1
        var b = 0
        while b < 80 {
            let bit = b < 64 ? (data >> UInt64(b)) & 1 : (LTCBits.sync >> UInt64(b - 64)) & 1
            lvl = -lvl
            cells[2 * b] = lvl
            if bit == 1 { lvl = -lvl }
            cells[2 * b + 1] = lvl
            b += 1
        }
    }
}

// MARK: - Reader

/// Lock status for one channel's timecode reader.
public enum TCLockState: String, Sendable {
    /// No valid LTC seen.
    case noSignal
    /// Frames are decoding but not yet consistently sequential.
    case acquiring
    /// ≥ 5 consecutive sequential frames.
    case locked
    /// Was locked; frames stopped or jumped within the last ~1 s (free-wheeling).
    case freewheel
}

/// High-level reader: wraps an LTCDecoder for one channel and turns raw frames into a
/// smooth, display-ready clock (interpolates between frames, free-wheels across dropouts
/// for up to `freewheelFrames`, flags jumps).
public final class TimecodeReader {
    public struct Status: Sendable, Equatable {
        public var state: TCLockState
        /// Display timecode, interpolated to "now" (the end of the last processed sample).
        public var timecode: Timecode?
        public var rate: FrameRate?
        public var isReverse: Bool
        /// Signal level of LTC in dBFS (e.g. -10.2), nil when no signal.
        public var levelDBFS: Float?
        public var userBits: UInt32
        /// Count of discontinuities (jumps/drops) since reset — shown as a "hits" counter.
        public var discontinuities: Int

        public init(state: TCLockState = .noSignal, timecode: Timecode? = nil, rate: FrameRate? = nil,
                    isReverse: Bool = false, levelDBFS: Float? = nil, userBits: UInt32 = 0, discontinuities: Int = 0) {
            self.state = state; self.timecode = timecode; self.rate = rate; self.isReverse = isReverse
            self.levelDBFS = levelDBFS; self.userBits = userBits; self.discontinuities = discontinuities
        }
    }

    public let sampleRate: Double
    public var freewheelFrames: Int = 10

    private let decoder: LTCDecoder
    private let rateHint: FrameRate?
    /// Frames needed for lock.
    private static let lockCount = 5

    private var now: Int64 = 0
    private var last: LTCFrame?
    private var seq = 0
    /// Frame the display is extrapolated from (last frame while acquiring/locked; last locked
    /// frame while free-wheeling).
    private var ref: LTCFrame?
    private var frameLen: Double = 0
    private var levelLin: Float = 0

    public init(sampleRate: Double, rateHint: FrameRate? = nil) {
        self.sampleRate = sampleRate
        self.rateHint = rateHint
        decoder = LTCDecoder(sampleRate: sampleRate, rateHint: rateHint)
    }

    /// Feed samples (non real-time thread). Returns updated status.
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>) -> Status {
        let frames = decoder.process(samples)
        for f in frames {
            checkTimeouts(at: f.endSample)
            ingest(f)
        }
        now += Int64(samples.count)
        checkTimeouts(at: now)
        publish()
        return status
    }

    public private(set) var status = Status()

    public func reset() {
        decoder.reset()
        now = 0; last = nil; seq = 0; ref = nil; frameLen = 0; levelLin = 0
        status = Status()
    }

    // MARK: Internals

    private func nominalFrameLen(_ f: LTCFrame) -> Double { sampleRate / f.timecode.rate.fps }

    private func ingest(_ f: LTCFrame) {
        var sequential = false
        if let p = last, p.isReverse == f.isReverse {
            let len = frameLen > 0 ? frameLen : nominalFrameLen(f)
            let dt = Double(f.endSample - p.endSample)
            let k = (dt / len).rounded()
            if k >= 1, abs(dt - k * len) < 0.35 * len {
                let prevTC = Timecode(hours: p.timecode.hours, minutes: p.timecode.minutes, seconds: p.timecode.seconds,
                                      frames: p.timecode.frames, rate: f.timecode.rate)
                let expect = prevTC.adding(frames: f.isReverse ? -Int(k) : Int(k))
                sequential = expect.frameNumber == f.timecode.frameNumber
                if sequential, k == 1 {
                    frameLen = frameLen > 0 ? frameLen + 0.1 * (dt - frameLen) : dt
                }
            }
        }
        if frameLen <= 0 { frameLen = nominalFrameLen(f) }
        levelLin = levelLin > 0 ? levelLin + 0.3 * (f.level - levelLin) : f.level

        if sequential {
            seq += 1
            switch status.state {
            case .noSignal, .acquiring:
                status.state = seq >= Self.lockCount ? .locked : .acquiring
                ref = f
            case .locked:
                ref = f
            case .freewheel:
                if seq >= Self.lockCount { status.state = .locked; ref = f }
            }
        } else {
            seq = 1
            switch status.state {
            case .locked, .freewheel:
                // A jump: keep the old timeline running until the new one proves itself.
                status.discontinuities += 1
                status.state = .freewheel
            case .noSignal, .acquiring:
                status.state = .acquiring
                ref = f
            }
        }
        last = f
    }

    private func checkTimeouts(at t: Int64) {
        guard frameLen > 0 else { return }
        switch status.state {
        case .noSignal:
            break
        case .acquiring:
            if let l = last, Double(t - l.endSample) > 2.5 * frameLen {
                status.state = .noSignal; seq = 0; ref = nil
            }
        case .locked:
            if let l = last, Double(t - l.endSample) > 1.6 * frameLen {
                status.state = .freewheel // dropout: bridge it (not counted; only jumps are)
            }
        case .freewheel:
            guard let r = ref else { status.state = .noSignal; return }
            if Double(t - r.endSample) > Double(max(1, freewheelFrames)) * frameLen {
                if let l = last, Double(t - l.endSample) <= 1.6 * frameLen {
                    status.state = .acquiring // a new run is in progress
                    ref = l
                } else {
                    status.state = .noSignal; seq = 0; ref = nil
                }
            }
        }
    }

    private func publish() {
        guard status.state != .noSignal, let r = ref else {
            status.timecode = nil; status.levelDBFS = nil; status.rate = nil; status.isReverse = false
            return
        }
        let elapsed = max(0, Double(now - r.endSample)) / max(1, frameLen)
        let step = 1 + Int(elapsed.rounded(.down))
        status.timecode = r.timecode.adding(frames: r.isReverse ? -step : step)
        status.isReverse = r.isReverse
        status.userBits = (last ?? r).userBits
        status.rate = decoder.detectedRate ?? rateHint
        status.levelDBFS = 20 * log10(max(levelLin, 1e-6))
    }
}
