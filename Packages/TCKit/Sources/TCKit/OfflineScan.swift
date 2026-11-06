import Foundation

/// Result of scanning a file's channels for LTC.
public struct LTCScanResult: Sendable, Equatable {
    /// Index into the `channels` array that carries LTC.
    public var channel: Int
    /// Timecode at sample 0 of the file, extrapolated back from the first decoded frame.
    public var start: Timecode
    public var rate: FrameRate
    /// Typical LTC level on that channel, dBFS (peak).
    public var levelDBFS: Float

    public init(channel: Int, start: Timecode, rate: FrameRate, levelDBFS: Float) {
        self.channel = channel; self.start = start; self.rate = rate; self.levelDBFS = levelDBFS
    }
}

public enum LTCScanner {
    /// Scan deinterleaved channels (first ~20 s is enough). Returns the channel that carries LTC, if any.
    public static func scan(channels: [[Float]], sampleRate: Double) -> LTCScanResult? {
        guard sampleRate > 0 else { return nil }
        let limit = Int(sampleRate * 20)
        var best: (result: LTCScanResult, score: Int)?
        for (index, samples) in channels.enumerated() where !samples.isEmpty {
            let decoder = LTCDecoder(sampleRate: sampleRate)
            let n = min(samples.count, limit)
            let frames = samples.withUnsafeBufferPointer { decoder.process(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            guard let run = longestRun(frames, sampleRate: sampleRate), run.count >= 10 else { continue }
            if let b = best, b.score >= run.count { continue }

            let first = frames[run.first], last = frames[run.last]
            let rate = decoder.detectedRate ?? last.timecode.rate
            let tc0 = Timecode(hours: first.timecode.hours, minutes: first.timecode.minutes,
                               seconds: first.timecode.seconds, frames: first.timecode.frames, rate: rate)
            // Measured frame length over the run (honours the file's actual speed).
            let arrivals = abs(last.timecode.frameNumber - first.timecode.frameNumber)
            let frameLen = arrivals > 0 ? Double(last.endSample - first.endSample) / Double(arrivals)
                                        : sampleRate / rate.fps
            // Frames between sample 0 and the start of `first` (which ends at endSample).
            let before = Double(first.endSample) / frameLen - 1
            let back = Int((before - 1e-3).rounded(.up))
            let start = tc0.adding(frames: first.isReverse ? back : -back)

            var levels = frames[run.first...run.last].map(\.level)
            levels.sort()
            let level = levels[levels.count / 2]
            best = (LTCScanResult(channel: index, start: start, rate: rate,
                                  levelDBFS: 20 * log10(max(level, 1e-6))), run.count)
        }
        return best?.result
    }

    /// Longest run of frames that follow each other (allowing a few missed frames).
    private static func longestRun(_ frames: [LTCFrame], sampleRate: Double) -> (first: Int, last: Int, count: Int)? {
        guard !frames.isEmpty else { return nil }
        var bestFirst = 0, bestLast = 0
        var runFirst = 0
        for i in 1..<max(1, frames.count) {
            let a = frames[i - 1], b = frames[i]
            let len = sampleRate / b.timecode.rate.fps
            let k = (Double(b.endSample - a.endSample) / len).rounded()
            var ok = a.isReverse == b.isReverse && k >= 1 && k <= 30
            if ok {
                let prev = Timecode(hours: a.timecode.hours, minutes: a.timecode.minutes, seconds: a.timecode.seconds,
                                    frames: a.timecode.frames, rate: b.timecode.rate)
                ok = prev.adding(frames: b.isReverse ? -Int(k) : Int(k)).frameNumber == b.timecode.frameNumber
            }
            if !ok { runFirst = i }
            if i - runFirst > bestLast - bestFirst { bestFirst = runFirst; bestLast = i }
        }
        return (bestFirst, bestLast, bestLast - bestFirst + 1)
    }
}
