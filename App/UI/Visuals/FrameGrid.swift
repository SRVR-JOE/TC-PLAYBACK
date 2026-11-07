import Foundation
import TCKit

/// The frame grid of a timecode rate. Every way of moving a playhead goes through here so the
/// main screen and the cue points editor always land on the same whole frames.
///
/// Time ↔ frame uses the rate's real frames per second (29.97 = 30000/1001), exactly like TCKit;
/// labels count in nominal frames through `Timecode`. Positions are worked out as integer frame
/// counts, never by adding 1/fps over and over, so repeated steps can't drift.
enum FrameGrid {
    /// How close (in frames) a time must be to a frame boundary to count as on it. Seeks land on
    /// the nearest audio sample, which can be up to half a sample (≈ 0.0003 frames) off the grid.
    static let tolerance = 1e-3

    /// Index of the frame whose span contains `t` (frame n covers n/fps ..< (n+1)/fps).
    static func frame(containing t: TimeInterval, fps: Double) -> Int {
        guard t.isFinite, t > 0, fps > 0 else { return 0 }
        return Int((t * fps + tolerance).rounded(.down))
    }

    /// Nearest frame boundary to `t`.
    static func nearestFrame(_ t: TimeInterval, fps: Double) -> Int {
        guard t.isFinite, t > 0, fps > 0 else { return 0 }
        return Int((t * fps).rounded())
    }

    static func time(ofFrame n: Int, fps: Double) -> TimeInterval { fps > 0 ? Double(max(0, n)) / fps : 0 }

    /// Last whole frame that starts inside `duration` (nil = no end).
    static func lastFrame(duration: TimeInterval?, fps: Double) -> Int? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return frame(containing: duration, fps: fps)
    }

    private static func clamp(_ n: Int, duration: TimeInterval?, fps: Double) -> Int {
        let n = max(0, n)
        return lastFrame(duration: duration, fps: fps).map { min(n, $0) } ?? n
    }

    /// `t` moved to the nearest whole frame, kept inside 0…duration.
    static func snap(_ t: TimeInterval, fps: Double, duration: TimeInterval? = nil) -> TimeInterval {
        time(ofFrame: clamp(nearestFrame(t, fps: fps), duration: duration, fps: fps), fps: fps)
    }

    static func snap(_ t: TimeInterval, rate: FrameRate, duration: TimeInterval? = nil) -> TimeInterval {
        snap(t, fps: rate.fps, duration: duration)
    }

    /// Moves `frames` whole frames from `t`. On a frame boundary that is exactly n frames; between
    /// two frames, +1 lands on the next whole frame and −1 on the previous one (the frame `t` is in).
    static func step(from t: TimeInterval, frames n: Int, fps: Double, duration: TimeInterval? = nil) -> TimeInterval {
        let pos = max(0, t.isFinite ? t : 0) * fps
        let onGrid = abs(pos - pos.rounded()) < tolerance
        let base: Int
        if onGrid || n == 0 { base = Int(pos.rounded()) }
        else if n > 0 { base = Int(pos.rounded(.down)) }
        else { base = Int(pos.rounded(.up)) }
        return time(ofFrame: clamp(base + n, duration: duration, fps: fps), fps: fps)
    }

    static func step(from t: TimeInterval, frames n: Int, rate: FrameRate, duration: TimeInterval? = nil) -> TimeInterval {
        step(from: t, frames: n, fps: rate.fps, duration: duration)
    }

    /// Timecode shown for track time `t` when the track starts at `start` (frame-accurate:
    /// the start's frame number plus the whole frames elapsed).
    static func timecode(at t: TimeInterval, start: Timecode) -> Timecode {
        start.adding(frames: frame(containing: t, fps: start.rate.fps))
    }
}

extension CuePointClock {
    /// The timecode the main screen's clock shows for a track: its LTC when it has some,
    /// otherwise plain track time from 00:00:00:00 at 30 fps (what the engine's clock shows).
    static func playback(for track: Track?) -> CuePointClock {
        CuePointClock(start: track?.ltcStartTimecode ?? Timecode(rate: .fps30))
    }

    /// Whole frame at or before `t`, snapped (seek target).
    func snapped(_ t: TimeInterval, duration: TimeInterval? = nil) -> TimeInterval {
        FrameGrid.snap(t, rate: rate, duration: duration)
    }

    /// "HH:MM:SS:FF" for track time `t`.
    func label(at t: TimeInterval) -> String { FrameGrid.timecode(at: t, start: start).description }
}
