import Foundation
import TCKit

// TEMPORARY — delete at merge once TCKit ships `LTCScanner` (or define TCKIT_HAS_SCANNER).
// Mirrors the agreed TCKit API exactly so Library code compiles against it today.
#if !TCKIT_HAS_SCANNER
public struct LTCScanResult: Sendable, Equatable {
    /// Source channel index the LTC was found on (0 = left, 1 = right).
    public var channel: Int
    public var start: Timecode
    public var rate: FrameRate
    public var levelDBFS: Float
}

public enum LTCScanner {
    /// Scan de-interleaved channels for LTC. Stub: never finds any.
    public static func scan(channels: [[Float]], sampleRate: Double) -> LTCScanResult? { nil }
}
#endif
