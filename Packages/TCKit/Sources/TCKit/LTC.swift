import Foundation

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
    public var endSample: Int64
    /// Peak absolute amplitude seen across the frame (0…1), for the "LTC level" readout.
    public var level: Float

    public init(timecode: Timecode, userBits: UInt32, isReverse: Bool, endSample: Int64, level: Float) {
        self.timecode = timecode; self.userBits = userBits; self.isReverse = isReverse
        self.endSample = endSample; self.level = level
    }
}

/// Streaming SMPTE 12M LTC decoder for one mono channel of float samples.
/// Not thread-safe: feed from a single (non real-time) thread.
public final class LTCDecoder {
    public let sampleRate: Double

    /// Frame rate hint. nil = auto-detect (24/25/30 family from bit period; 29.97 vs 30 and
    /// 23.976 vs 24 from frame-arrival timing; DF from the drop-frame flag bit).
    public var rateHint: FrameRate?

    public init(sampleRate: Double, rateHint: FrameRate? = nil) {
        self.sampleRate = sampleRate
        self.rateHint = rateHint
    }

    /// Feed samples; returns every complete frame decoded from this chunk, in order.
    /// Must handle arbitrary chunk sizes (1…16384), DC offset, polarity inversion,
    /// levels from -40 dBFS to 0 dBFS, and ±10% varispeed.
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [LTCFrame] {
        return []
    }

    /// Best current estimate of the frame rate, or nil until ~1 s of clean frames.
    public var detectedRate: FrameRate? { nil }

    /// Clears all internal state (use after a seek/discontinuity).
    public func reset() {}
}

/// Streaming SMPTE 12M LTC generator. Produces a band-limited bi-phase signal
/// (rise time ≈ 25 µs per spec, not a raw square wave) at `level` peak amplitude.
public final class LTCEncoder {
    public let sampleRate: Double
    public private(set) var rate: FrameRate
    /// Peak amplitude, 0…1. Default ≈ -10 dBFS.
    public var level: Float = 0.316
    public var userBits: UInt32 = 0

    public init(sampleRate: Double, rate: FrameRate, start: Timecode) {
        self.sampleRate = sampleRate
        self.rate = rate
    }

    /// Timecode of the frame that the next rendered sample belongs to.
    public var currentTimecode: Timecode { Timecode.zero(rate) }

    /// Fill `buffer` with the next samples of the LTC stream (mono). Real-time safe:
    /// no allocation, no locks, no Objective-C/Swift runtime calls.
    public func render(into buffer: UnsafeMutableBufferPointer<Float>) {
        for i in buffer.indices { buffer[i] = 0 }
    }

    /// Jump to a new position (next render starts at the beginning of that frame).
    public func locate(to timecode: Timecode) {}

    /// Change rate (also re-locates to `start`).
    public func reconfigure(rate: FrameRate, start: Timecode) { self.rate = rate }
}

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

    public init(sampleRate: Double, rateHint: FrameRate? = nil) {
        self.sampleRate = sampleRate
    }

    /// Feed samples (non real-time thread). Returns updated status.
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>) -> Status { status }

    public private(set) var status = Status()

    public func reset() { status = Status() }
}
