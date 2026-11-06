import Foundation
import TCKit

/// Right-to-left timecode entry, like a pro TC calculator: each digit pushes in from the right
/// and the field shifts left. "1", "0", "0", "0", "0", "0", "0" → 01:00:00:00.
struct TCEntry: Equatable {
    /// Eight digits, H H M M S S F F.
    private(set) var digits: [Int] = Array(repeating: 0, count: 8)
    /// Number of digits typed since the field was armed (0…8). Drives the "typed" highlight.
    private(set) var typedCount: Int = 0
    /// When true, the next digit replaces the shown value instead of shifting into it.
    private(set) var isFresh: Bool = true

    init() {}

    init(timecode: Timecode) {
        digits = TCEntry.digits(of: timecode)
        typedCount = 0
        isFresh = true
    }

    static func digits(of tc: Timecode) -> [Int] {
        [tc.hours / 10, tc.hours % 10, tc.minutes / 10, tc.minutes % 10,
         tc.seconds / 10, tc.seconds % 10, tc.frames / 10, tc.frames % 10]
    }

    var hours: Int { digits[0] * 10 + digits[1] }
    var minutes: Int { digits[2] * 10 + digits[3] }
    var seconds: Int { digits[4] * 10 + digits[5] }
    var frames: Int { digits[6] * 10 + digits[7] }

    mutating func push(_ d: Int) {
        guard (0...9).contains(d) else { return }
        if isFresh { digits = Array(repeating: 0, count: 8); typedCount = 0; isFresh = false }
        digits.removeFirst()
        digits.append(d)
        typedCount = min(8, typedCount + 1)
    }

    /// "00" key.
    mutating func pushDoubleZero() { push(0); push(0) }

    /// Remove the right-most digit (shift right, zero-fill from the left).
    mutating func backspace() {
        if isFresh { isFresh = false; typedCount = 8 }
        digits.removeLast()
        digits.insert(0, at: 0)
        typedCount = max(0, typedCount - 1)
    }

    mutating func clear() {
        digits = Array(repeating: 0, count: 8)
        typedCount = 0
        isFresh = false
    }

    /// Display string with the rate's separator ("HH:MM:SS;FF" for drop-frame).
    func display(rate: FrameRate) -> String {
        let sep = rate.isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, sep, frames)
    }

    /// The entered timecode at `rate`, or nil if it doesn't exist at that rate.
    func timecode(rate: FrameRate) -> Timecode? {
        guard validationMessage(rate: rate) == nil else { return nil }
        return Timecode(hours: hours, minutes: minutes, seconds: seconds, frames: frames, rate: rate)
    }

    /// Operator-facing reason the value is invalid at `rate`, or nil when valid.
    func validationMessage(rate: FrameRate) -> String? {
        if hours > 23 { return "Hours run 00 to 23." }
        if minutes > 59 { return "Minutes run 00 to 59." }
        if seconds > 59 { return "Seconds run 00 to 59." }
        if frames >= rate.nominalFPS {
            return String(format: "Frames run 00 to %02d at %@.", rate.nominalFPS - 1, rate.label)
        }
        if rate.isDropFrame, seconds == 0, frames < 2, minutes % 10 != 0 {
            return "29.97 DF has no frames 00 and 01 at the top of each minute, except every tenth minute."
        }
        return nil
    }
}

/// The six nudge buttons.
enum Nudge: CaseIterable, Identifiable {
    case minus10s, minus1s, minus1f, plus1f, plus1s, plus10s
    var id: Self { self }

    var label: String {
        switch self {
        case .minus10s: "−10 s"
        case .minus1s: "−1 s"
        case .minus1f: "−1 f"
        case .plus1f: "+1 f"
        case .plus1s: "+1 s"
        case .plus10s: "+10 s"
        }
    }

    /// Offset in frames at `rate`. Seconds are timecode seconds (nominal frames), so +1 s moves
    /// the seconds digit by one at every rate, including 29.97 DF.
    func frames(at rate: FrameRate) -> Int {
        switch self {
        case .minus10s: -10 * rate.nominalFPS
        case .minus1s: -rate.nominalFPS
        case .minus1f: -1
        case .plus1f: 1
        case .plus1s: rate.nominalFPS
        case .plus10s: 10 * rate.nominalFPS
        }
    }
}

/// Pure timing maths for the pads page (unit-tested).
enum PadMath {
    /// Apply a nudge. Wraps through midnight like a real TC generator.
    static func nudge(_ tc: Timecode, by nudge: Nudge) -> Timecode {
        tc.adding(frames: nudge.frames(at: tc.rate))
    }

    /// Where the generator actually starts for a cue point with pre-roll, in whole frames.
    static func generatorStart(cue: Timecode, preRoll: Double) -> Timecode {
        guard preRoll > 0 else { return cue }
        let frames = Int((preRoll * cue.rate.fps).rounded())
        return cue.adding(frames: -frames)
    }

    /// Generator run time from `start`, given the pad's cue point and duration after it.
    /// Returns nil for open-ended pads and 0 when `start` is already past the end.
    static func remainingDuration(from start: Timecode, cue: Timecode, duration: TimeInterval?) -> TimeInterval? {
        guard let duration else { return nil }
        let endFrame = cue.frameNumber + Int((duration * cue.rate.fps).rounded())
        var delta = endFrame - start.frameNumber
        // Handle a run that crosses midnight.
        let perDay = Timecode(hours: 23, minutes: 59, seconds: 59, frames: cue.rate.nominalFPS - 1, rate: cue.rate).frameNumber + 1
        if delta < -perDay / 2 { delta += perDay }
        guard delta > 0 else { return 0 }
        return Double(delta) / cue.rate.fps
    }
}
