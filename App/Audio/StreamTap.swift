import Darwin
import Foundation
import Synchronization

/// Host-time anchor for a tapped audio stream: the host time, in seconds, of the stream's
/// sample 0 (counted in `SPSCRingBuffer.totalWritten` frames of the ring it feeds).
///
/// The producer (render callback / input tap) re-notes it every buffer from the buffer's own
/// AudioTimeStamp, so a dropped write (full ring) only shifts the origin and is corrected on
/// the next buffer. Real-time safe: one atomic store, no allocation.
final class TapClock: @unchecked Sendable {
    /// Mach host ticks → seconds (computed once, off the real-time thread).
    static let secondsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    private let originBits = Atomic<UInt64>(0)
    private let rateBits = Atomic<UInt64>(0)

    init() { _ = Self.secondsPerTick }

    /// `hostTime` is the mach host time of the first frame of the buffer about to be written at
    /// ring index `frameIndex`. Ignored when `hostTime` is 0 (no valid timestamp).
    @inline(__always)
    func note(hostTime: UInt64, frameIndex: Int, sampleRate: Double) {
        guard hostTime != 0, sampleRate > 0 else { return }
        let origin = Double(hostTime) * Self.secondsPerTick - Double(frameIndex) / sampleRate
        originBits.store(origin.bitPattern, ordering: .releasing)
        rateBits.store(sampleRate.bitPattern, ordering: .releasing)
    }

    /// Host seconds of frame 0, nil until the producer has noted a timestamp.
    var origin: Double? {
        let b = originBits.load(ordering: .acquiring)
        return b == 0 ? nil : Double(bitPattern: b)
    }

    var sampleRate: Double { Double(bitPattern: rateBits.load(ordering: .acquiring)) }

    func clear() {
        originBits.store(0, ordering: .releasing)
        rateBits.store(0, ordering: .releasing)
    }
}

/// The engine's post-mix output tap for the current audio graph: exactly what is sent to the
/// output device (after routing, gain and the master fade), with its host-time anchor.
struct OutputTapHandle {
    let ring: SPSCRingBuffer
    let clock: TapClock
    let sampleRate: Double
}
