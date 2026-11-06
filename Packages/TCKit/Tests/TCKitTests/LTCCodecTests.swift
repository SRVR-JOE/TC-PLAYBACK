import XCTest
@testable import TCKit

final class LTCCodecTests: XCTestCase {

    // MARK: Helpers

    /// Asserts `frames` is an unbroken sequence (forward or reverse) and returns the number of
    /// frames that matched what the encoder sent. `expectedStart` is the encoder's first frame.
    @discardableResult
    func assertSequence(_ frames: [LTCFrame], rate: FrameRate, start: Timecode, sampleRate: Double,
                        seconds: Double, reverse: Bool = false, checkTiming: Bool = true,
                        minFraction: Double = 0.98, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let expected = Int(seconds * rate.fps)
        XCTAssertGreaterThanOrEqual(Double(frames.count), Double(expected) * minFraction,
                                    "decoded \(frames.count)/\(expected) \(rate) @\(sampleRate)", file: file, line: line)
        guard frames.count > 1 else { return 0 }
        var breaks = 0
        for i in 1..<frames.count {
            let a = frames[i - 1].timecode, b = frames[i].timecode
            let next = Timecode(hours: a.hours, minutes: a.minutes, seconds: a.seconds, frames: a.frames, rate: rate)
                .adding(frames: reverse ? -1 : 1)
            if next.hours != b.hours || next.minutes != b.minutes || next.seconds != b.seconds || next.frames != b.frames {
                breaks += 1
            }
            XCTAssertEqual(frames[i].isReverse, reverse, file: file, line: line)
        }
        XCTAssertEqual(breaks, 0, "sequence breaks \(rate) @\(sampleRate)", file: file, line: line)
        if checkTiming && !reverse {
            let spf = sampleRate / rate.fps
            let startFN = Timecode(hours: start.hours, minutes: start.minutes, seconds: start.seconds,
                                   frames: start.frames, rate: rate).frameNumber
            var maxErr = 0.0
            for f in frames {
                let tc = Timecode(hours: f.timecode.hours, minutes: f.timecode.minutes, seconds: f.timecode.seconds,
                                  frames: f.timecode.frames, rate: rate)
                let index = tc.frameNumber - startFN
                let ideal = Double(index + 1) * spf // frame `index` ends where the next one starts
                maxErr = max(maxErr, abs(Double(f.endSample) - ideal))
            }
            XCTAssertLessThanOrEqual(maxErr, 1.5, "endSample error \(rate) @\(sampleRate)", file: file, line: line)
        }
        return frames.count
    }

    // MARK: Round trips

    func testRoundTripAllRates60s() {
        let start = Timecode(hours: 0, minutes: 9, seconds: 30, frames: 0, rate: .fps30)
        var seed: UInt64 = 10
        for sr in [44_100.0, 48_000.0] {
            for rate in FrameRate.allCases {
                seed += 1
                let st = Timecode(hours: start.hours, minutes: start.minutes, seconds: start.seconds, frames: 0, rate: rate)
                let ub = UInt32(truncatingIfNeeded: SplitMix64(seed: seed).state &* 0x9E37_79B9)
                let x = LTCTest.encode(rate: rate, sampleRate: sr, seconds: 61, start: st, userBits: ub, seed: seed)
                let dec = LTCDecoder(sampleRate: sr)
                let frames = LTCTest.decode(x, sampleRate: sr, seed: seed &* 3, decoder: dec)
                assertSequence(frames, rate: rate, start: st, sampleRate: sr, seconds: 61)
                XCTAssertEqual(dec.detectedRate, rate, "detect \(rate) @\(sr)")
                XCTAssertEqual(frames.last?.timecode.rate, rate)
                XCTAssertTrue(frames.allSatisfy { $0.userBits == ub }, "user bits \(rate)")
                XCTAssertEqual(frames.last?.level ?? 0, 0.5, accuracy: 0.02)
            }
        }
    }

    func testRoundTrip96k() {
        for rate in [FrameRate.fps23_976, .fps29_97df, .fps25] {
            let st = Timecode(hours: 10, rate: rate)
            let x = LTCTest.encode(rate: rate, sampleRate: 96_000, seconds: 10, start: st)
            let frames = LTCTest.decode(x, sampleRate: 96_000)
            assertSequence(frames, rate: rate, start: st, sampleRate: 96_000, seconds: 10)
        }
    }

    func testDropFrameSequenceAndFlag() {
        let rate = FrameRate.fps29_97df
        let st = Timecode(string: "00:00:58;00", rate: rate)!
        let x = LTCTest.encode(rate: rate, sampleRate: 48_000, seconds: 4, start: st)
        let dec = LTCDecoder(sampleRate: 48_000)
        let frames = LTCTest.decode(x, sampleRate: 48_000, decoder: dec)
        assertSequence(frames, rate: rate, start: st, sampleRate: 48_000, seconds: 4)
        let labels = frames.map { "\($0.timecode.hours):\($0.timecode.minutes):\($0.timecode.seconds):\($0.timecode.frames)" }
        let i = labels.firstIndex(of: "0:0:59:29")!
        XCTAssertEqual(labels[i + 1], "0:1:0:2")
        XCTAssertEqual(dec.detectedRate, .fps29_97df)
        XCTAssertTrue(frames.allSatisfy { $0.timecode.rate.isDropFrame }, "DF flag must label every frame DF")
        XCTAssertTrue(frames.last!.timecode.description.contains(";"))
    }

    func testUserBitsRoundTrip() {
        for ub: UInt32 in [0, 0xFFFF_FFFF, 0xDEAD_BEEF, 0x1234_5678, 0x8000_0001] {
            let st = Timecode(hours: 1, rate: .fps25)
            let x = LTCTest.encode(rate: .fps25, sampleRate: 48_000, seconds: 2, start: st, userBits: ub)
            let frames = LTCTest.decode(x, sampleRate: 48_000)
            XCTAssertGreaterThan(frames.count, 45)
            XCTAssertTrue(frames.allSatisfy { $0.userBits == ub }, String(format: "%08X", ub))
        }
    }

    // MARK: Robustness

    private func robustCase(rate: FrameRate = .fps29_97df, sr: Double = 48_000, seconds: Double = 20,
                            level: Float = 0.5, transform: ([Float]) -> [Float]) -> (frames: [LTCFrame], start: Timecode) {
        let st = Timecode(hours: 1, minutes: 59, seconds: 50, frames: 0, rate: rate)
        let x = transform(LTCTest.encode(rate: rate, sampleRate: sr, seconds: seconds, start: st, level: level))
        return (LTCTest.decode(x, sampleRate: sr), st)
    }

    func testInvertedPolarity() {
        let (frames, st) = robustCase { $0.map { -$0 } }
        assertSequence(frames, rate: .fps29_97df, start: st, sampleRate: 48_000, seconds: 20)
    }

    func testLowLevelMinus36dBFS() {
        let (frames, st) = robustCase(level: LTCTest.amp(dB: -36)) { $0 }
        assertSequence(frames, rate: .fps29_97df, start: st, sampleRate: 48_000, seconds: 20)
        XCTAssertEqual(LTCTest.dB(frames.last!.level), -36, accuracy: 0.5)
    }

    func testMinus40dBFSAnd0dBFS() {
        for lvl: Float in [-40, 0] {
            let (frames, st) = robustCase(rate: .fps25, seconds: 10, level: LTCTest.amp(dB: lvl)) { $0 }
            assertSequence(frames, rate: .fps25, start: st, sampleRate: 48_000, seconds: 10)
        }
    }

    func testPositiveDCOffset() {
        let (frames, st) = robustCase(level: 0.3) { $0.map { $0 + 0.35 } }
        assertSequence(frames, rate: .fps29_97df, start: st, sampleRate: 48_000, seconds: 20)
        XCTAssertEqual(frames.last!.level, 0.3, accuracy: 0.02, "level must ignore DC")
    }

    func testWhiteNoise30dBSNR() {
        var rng = SplitMix64(seed: 99)
        let level: Float = 0.3
        let sigma = level * LTCTest.amp(dB: -30)
        let (frames, st) = robustCase(level: level) { $0.map { $0 + sigma * rng.gaussian() } }
        assertSequence(frames, rate: .fps29_97df, start: st, sampleRate: 48_000, seconds: 20)
    }

    func testWhiteNoise20dBSNRMostlyDecodes() {
        var rng = SplitMix64(seed: 7)
        let level: Float = 0.3
        let sigma = level * LTCTest.amp(dB: -20)
        let (frames, _) = robustCase(rate: .fps25, seconds: 10, level: level) { $0.map { $0 + sigma * rng.gaussian() } }
        XCTAssertGreaterThan(frames.count, 240) // ≥ 96 %
    }

    func testVarispeed() {
        for speed in [0.9, 1.1] {
            for rate in [FrameRate.fps23_976, .fps30] {
                let (frames, st) = robustCase(rate: rate, seconds: 20) { LTCTest.varispeed($0, speed: speed) }
                // 20 s of material always carries the same number of frames, whatever the speed.
                assertSequence(frames, rate: rate, start: st, sampleRate: 48_000, seconds: 20, checkTiming: false)
                // Timing follows the real (resampled) signal.
                let spf = 48_000 / rate.fps / speed
                let d = Double(frames.last!.endSample - frames.first!.endSample) / Double(frames.count - 1)
                XCTAssertEqual(d, spf, accuracy: 0.05, "speed \(speed) \(rate)")
            }
        }
    }

    func testReverse() {
        for rate in [FrameRate.fps25, .fps29_97df, .fps23_976] {
            let (frames, st) = robustCase(rate: rate, seconds: 10) { Array($0.reversed()) }
            assertSequence(frames, rate: rate, start: st, sampleRate: 48_000, seconds: 10, reverse: true)
            XCTAssertTrue(frames.allSatisfy(\.isReverse))
            XCTAssertLessThan(frames.last!.timecode.frameNumber, frames.first!.timecode.frameNumber)
        }
    }

    func testRateAutoDetect() {
        for rate in FrameRate.allCases {
            let st = Timecode(hours: 2, minutes: 0, seconds: 0, frames: 0, rate: rate)
            let x = LTCTest.encode(rate: rate, sampleRate: 48_000, seconds: 2.5, start: st)
            let dec = LTCDecoder(sampleRate: 48_000)
            var firstDetectSample: Int?
            x.withUnsafeBufferPointer { buf in
                var pos = 0
                while pos < buf.count {
                    let n = min(480, buf.count - pos)
                    _ = dec.process(UnsafeBufferPointer(rebasing: buf[pos..<(pos + n)]))
                    pos += n
                    if firstDetectSample == nil, dec.detectedRate != nil { firstDetectSample = pos }
                }
            }
            XCTAssertEqual(dec.detectedRate, rate, "\(rate)")
            XCTAssertLessThan(Double(firstDetectSample ?? .max), 2.0 * 48_000, "detect within 2 s \(rate)")
        }
        // Without frame-count evidence yet, nothing is claimed.
        let dec = LTCDecoder(sampleRate: 48_000)
        let x = LTCTest.encode(rate: .fps30, sampleRate: 48_000, seconds: 0.5, start: .zero(.fps30))
        _ = x.withUnsafeBufferPointer { dec.process($0) }
        XCTAssertNil(dec.detectedRate)
    }

    func testRateHintLabelsFrames() {
        let x = LTCTest.encode(rate: .fps30, sampleRate: 48_000, seconds: 1, start: .zero(.fps30))
        let frames = LTCTest.decode(x, sampleRate: 48_000, rateHint: .fps29_97ndf)
        XCTAssertTrue(frames.allSatisfy { $0.timecode.rate == .fps29_97ndf })
    }

    func testSilenceAndNoiseProduceNothing() {
        var rng = SplitMix64(seed: 5)
        let noise = (0..<48_000 * 5).map { _ in 0.2 * rng.gaussian() }
        XCTAssertTrue(LTCTest.decode(noise, sampleRate: 48_000).isEmpty)
        XCTAssertTrue(LTCTest.decode([Float](repeating: 0, count: 48_000), sampleRate: 48_000).isEmpty)
        let tone = (0..<48_000 * 3).map { Float(0.5 * sin(Double($0) * 2 * .pi * 1000 / 48_000)) }
        XCTAssertTrue(LTCTest.decode(tone, sampleRate: 48_000).isEmpty)
    }

    func testDecoderResetAfterSeek() {
        let dec = LTCDecoder(sampleRate: 48_000)
        let a = LTCTest.encode(rate: .fps25, sampleRate: 48_000, seconds: 2, start: Timecode(hours: 1, rate: .fps25))
        let b = LTCTest.encode(rate: .fps25, sampleRate: 48_000, seconds: 2, start: Timecode(hours: 5, rate: .fps25))
        _ = LTCTest.decode(a, sampleRate: 48_000, decoder: dec)
        dec.reset()
        XCTAssertNil(dec.detectedRate)
        let fb = LTCTest.decode(b, sampleRate: 48_000, decoder: dec)
        XCTAssertEqual(fb.first?.timecode.hours, 5)
        XCTAssertLessThan(fb.first!.endSample, 48_000 / 25 * 3) // sample count restarted
    }

    // MARK: Encoder

    func testEncoderShapeAndLevel() {
        let sr = 48_000.0
        let enc = LTCEncoder(sampleRate: sr, rate: .fps30, start: .zero(.fps30))
        enc.level = 0.25
        var buf = [Float](repeating: 0, count: 48_000)
        buf.withUnsafeMutableBufferPointer { enc.render(into: $0) }
        XCTAssertEqual(buf.max()!, 0.25, accuracy: 1e-6)
        XCTAssertEqual(buf.min()!, -0.25, accuracy: 1e-6)
        // Band-limited: every transition passes through intermediate values, none jumps rail to rail.
        var maxStep: Float = 0
        for i in 1..<buf.count { maxStep = max(maxStep, abs(buf[i] - buf[i - 1])) }
        XCTAssertLessThan(maxStep, 0.5 * 0.92, "edge must not be a raw step")
        // 10–90 % rise ≈ 25 µs: measure on a 96 kHz render (4 samples per edge) by interpolation.
        let enc96 = LTCEncoder(sampleRate: 96_000, rate: .fps30, start: .zero(.fps30))
        enc96.level = 1
        var b96 = [Float](repeating: 0, count: 9_600)
        b96.withUnsafeMutableBufferPointer { enc96.render(into: $0) }
        var rises: [Double] = []
        var i = 1
        while i < b96.count - 8 {
            if b96[i - 1] <= -0.8 && b96[i] > -0.8 {
                func crossing(_ level: Float, from: Int) -> Double? {
                    for k in from..<(from + 8) where b96[k] <= level && b96[k + 1] > level {
                        return Double(k) + Double((level - b96[k]) / (b96[k + 1] - b96[k]))
                    }
                    return nil
                }
                if let a = crossing(-0.8, from: i - 1), let b = crossing(0.8, from: i - 1) { rises.append((b - a) / 96_000) }
                i += 8
            } else { i += 1 }
        }
        let mean = rises.reduce(0, +) / Double(rises.count)
        XCTAssertEqual(mean * 1e6, 25, accuracy: 5, "rise time µs")
    }

    func testEncoderLocateAndCurrentTimecode() {
        let enc = LTCEncoder(sampleRate: 48_000, rate: .fps25, start: Timecode(hours: 1, rate: .fps25))
        XCTAssertEqual(enc.currentTimecode.description, "01:00:00:00")
        var buf = [Float](repeating: 0, count: 1920 * 3) // exactly 3 frames at 25 fps
        buf.withUnsafeMutableBufferPointer { enc.render(into: $0) }
        XCTAssertEqual(enc.currentTimecode.description, "01:00:00:03")
        enc.locate(to: Timecode(hours: 2, minutes: 30, rate: .fps25))
        XCTAssertEqual(enc.currentTimecode.description, "02:30:00:00")
        var b1 = [Float](repeating: 0, count: 1920 * 3 + 20)
        b1.withUnsafeMutableBufferPointer { enc.render(into: $0) }
        let frames = LTCTest.decode(b1, sampleRate: 48_000)
        XCTAssertEqual(frames.last?.timecode.description, "02:30:00:02")
        enc.reconfigure(rate: .fps29_97df, start: Timecode(string: "00:00:59;28", rate: .fps29_97df)!)
        XCTAssertEqual(enc.rate, .fps29_97df)
        XCTAssertEqual(enc.currentTimecode.description, "00:00:59;28")
        var b2 = [Float](repeating: 0, count: 1602 * 2 + 10)
        b2.withUnsafeMutableBufferPointer { enc.render(into: $0) }
        XCTAssertEqual(enc.currentTimecode.description, "00:01:00;02")
    }

    /// Frame boundaries stay locked to the ideal F·sr/fps over 10 minutes (no accumulation).
    func testEncoderFrameTimingDrift10Minutes() {
        for (rate, sr) in [(FrameRate.fps29_97df, 48_000.0), (.fps23_976, 44_100.0), (.fps30, 44_100.0)] {
            let enc = LTCEncoder(sampleRate: sr, rate: rate, start: .zero(rate))
            enc.level = 1
            let spf = sr / rate.fps
            let total = Int(600 * sr)
            var buf = [Float](repeating: 0, count: 4093)
            var rng = SplitMix64(seed: 77)
            var pos = 0
            var prev: Float = 0
            var nextFrame = 1
            var nextBoundary = spf
            var maxErr = 0.0, lastErr = 0.0
            var checked = 0
            while pos < total {
                let n = min(total - pos, Int.random(in: 1...buf.count, using: &rng))
                buf.withUnsafeMutableBufferPointer { enc.render(into: UnsafeMutableBufferPointer(rebasing: $0[0..<n])) }
                for k in 0..<n {
                    let s = pos + k
                    let v = buf[k]
                    if Double(s) >= nextBoundary {
                        // Every frame starts with a -1 → +1 edge centred on the boundary.
                        let x = Double(s - 1) + Double(-prev / (v - prev))
                        let err = x - nextBoundary
                        maxErr = max(maxErr, abs(err)); lastErr = err
                        checked += 1
                        nextFrame += 1
                        nextBoundary = Double(nextFrame) * spf
                    }
                    prev = v
                }
                pos += n
            }
            XCTAssertGreaterThan(checked, Int(599 * rate.fps))
            XCTAssertLessThan(maxErr, 0.1, "\(rate) @\(sr): max boundary error \(maxErr) samples")
            XCTAssertLessThan(abs(lastErr), 0.1, "\(rate) @\(sr): drift after 10 min \(lastErr) samples")
            XCTAssertEqual(enc.currentTimecode, Timecode(frameNumber: Int(Double(total) / spf), rate: rate))
        }
    }
}
