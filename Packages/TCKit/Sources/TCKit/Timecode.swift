import Foundation

// CONTRACT FILE — shared by every module. Signatures are frozen; implementations may be
// improved by the TCKit owner (with tests) but public API must not change.

/// SMPTE frame rates supported for LTC read and generate.
public enum FrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case fps23_976 = "23.976"
    case fps24 = "24"
    case fps25 = "25"
    case fps29_97ndf = "29.97"
    case fps29_97df = "29.97DF"
    case fps30 = "30"

    public var id: String { rawValue }

    /// Nominal integer frames per second used for counting (24, 25, 30).
    public var nominalFPS: Int {
        switch self {
        case .fps23_976, .fps24: return 24
        case .fps25: return 25
        case .fps29_97ndf, .fps29_97df, .fps30: return 30
        }
    }

    /// Real-time frames per second.
    public var fps: Double {
        switch self {
        case .fps23_976: return 24_000.0 / 1001.0
        case .fps24: return 24
        case .fps25: return 25
        case .fps29_97ndf, .fps29_97df: return 30_000.0 / 1001.0
        case .fps30: return 30
        }
    }

    public var isDropFrame: Bool { self == .fps29_97df }

    /// Operator-facing label, e.g. "29.97 DF".
    public var label: String {
        switch self {
        case .fps23_976: return "23.976"
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps29_97ndf: return "29.97 NDF"
        case .fps29_97df: return "29.97 DF"
        case .fps30: return "30"
        }
    }
}

/// A SMPTE timecode value. Value type, cheap to copy.
public struct Timecode: Hashable, Codable, Sendable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var rate: FrameRate

    public init(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, frames: Int = 0, rate: FrameRate) {
        self.hours = hours; self.minutes = minutes; self.seconds = seconds; self.frames = frames; self.rate = rate
    }

    public static func zero(_ rate: FrameRate) -> Timecode { Timecode(rate: rate) }

    /// "HH:MM:SS:FF" (";" before frames for drop-frame).
    public var description: String {
        let sep = rate.isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, sep, frames)
    }

    /// Parse "HH:MM:SS:FF" / "HH:MM:SS;FF" / "HHMMSSFF". Returns nil if malformed or out of range.
    public init?(string: String, rate: FrameRate) {
        // ASCII digits only: `Character.isNumber` also accepts "²", "½", Arabic-Indic digits etc.,
        // which would previously crash the force-unwrap below.
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == ":" || $0 == ";" || $0 == "." || $0 == " " }) else { return nil }
        let a = trimmed.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
        guard a.count == 8 else { return nil }
        let h = a[0] * 10 + a[1], m = a[2] * 10 + a[3], s = a[4] * 10 + a[5], f = a[6] * 10 + a[7]
        guard h < 24, m < 60, s < 60, f < rate.nominalFPS else { return nil }
        if rate.isDropFrame, s == 0, f < 2, m % 10 != 0 { return nil }
        self.init(hours: h, minutes: m, seconds: s, frames: f, rate: rate)
    }

    /// Absolute frame count since 00:00:00:00 (drop-frame aware).
    public var frameNumber: Int {
        let nom = rate.nominalFPS
        let totalMinutes = hours * 60 + minutes
        var n = ((totalMinutes * 60) + seconds) * nom + frames
        if rate.isDropFrame { n -= 2 * (totalMinutes - totalMinutes / 10) }
        return n
    }

    /// Build from an absolute frame count (wraps at 24h).
    public init(frameNumber: Int, rate: FrameRate) {
        let nom = rate.nominalFPS
        var n = frameNumber
        if rate.isDropFrame {
            let perDay = 24 * 60 * 60 * 30 - 2 * (24 * 60 - 24 * 6)
            n = ((n % perDay) + perDay) % perDay
            let per10Min = 10 * 60 * 30 - 18 // 17982
            let perMin = 60 * 30 - 2 // 1798
            let d = n / per10Min, mRem = n % per10Min
            if mRem > 1 { n += 18 * d + 2 * ((mRem - 2) / perMin) } else { n += 18 * d }
        } else {
            let perDay = 24 * 60 * 60 * nom
            n = ((n % perDay) + perDay) % perDay
        }
        frames = n % nom
        seconds = (n / nom) % 60
        minutes = (n / (nom * 60)) % 60
        hours = (n / (nom * 3600)) % 24
        self.rate = rate
    }

    /// Wall-clock seconds represented by this timecode from 00:00:00:00.
    public var realSeconds: Double { Double(frameNumber) / rate.fps }

    /// Timecode at `seconds` of real time after 00:00:00:00.
    public init(realSeconds: Double, rate: FrameRate) {
        // The small epsilon makes `Timecode(realSeconds: tc.realSeconds)` round-trip: n / fps * fps
        // is frequently n - 1e-12, which floor() used to turn into the previous frame.
        guard realSeconds.isFinite, realSeconds > 0 else { self.init(frameNumber: 0, rate: rate); return }
        let f = (realSeconds * rate.fps + 1e-6).rounded(.down)
        self.init(frameNumber: f < Double(Int.max / 2) ? Int(f) : 0, rate: rate)
    }

    public func adding(frames delta: Int) -> Timecode { Timecode(frameNumber: frameNumber + delta, rate: rate) }
    public func adding(seconds delta: Double) -> Timecode { Timecode(realSeconds: realSeconds + delta, rate: rate) }
}
