import XCTest
@testable import TCKit

final class TimecodeReaderTests: XCTestCase {
    let sr = 48_000.0

    struct Sample { var pos: Int; var status: TimecodeReader.Status }

    /// Feeds `x` in fixed chunks and records the status after each one.
    func run(_ reader: TimecodeReader, _ x: [Float], chunk: Int = 256, offset: Int = 0) -> [Sample] {
        var out: [Sample] = []
        x.withUnsafeBufferPointer { buf in
            var pos = 0
            while pos < buf.count {
                let n = min(chunk, buf.count - pos)
                let st = reader.process(UnsafeBufferPointer(rebasing: buf[pos..<(pos + n)]))
                pos += n
                out.append(Sample(pos: pos + offset, status: st))
            }
        }
        return out
    }

    func testLockAfterFiveFramesAndInterpolation() {
        let rate = FrameRate.fps25
        let st = Timecode(hours: 3, rate: rate)
        let x = LTCTest.encode(rate: rate, sampleRate: sr, seconds: 4, start: st, level: 0.1)
        let reader = TimecodeReader(sampleRate: sr)
        let log = run(reader, x, chunk: 64)
        let spf = sr / rate.fps
        XCTAssertEqual(log.first?.status.state, .noSignal)
        let firstLocked = log.first { $0.status.state == .locked }!
        // Frames 0…4 end at 1…5 frame periods; lock on the 5th.
        XCTAssertGreaterThanOrEqual(Double(firstLocked.pos), 5 * spf)
        XCTAssertLessThan(Double(firstLocked.pos), 5 * spf + 64 + 2)
        XCTAssertTrue(log.contains { $0.status.state == .acquiring })
        // From lock on, the clock equals the frame the encoder is sending at that sample (±1 frame
        // around boundaries, exact almost always).
        var exact = 0, total = 0
        for s in log where s.pos > firstLocked.pos {
            XCTAssertEqual(s.status.state, .locked)
            let truth = st.adding(frames: Int(Double(s.pos) / spf))
            let got = s.status.timecode!
            XCTAssertLessThanOrEqual(abs(got.frameNumber - truth.frameNumber), 1)
            if got == truth { exact += 1 }
            total += 1
        }
        XCTAssertGreaterThan(Double(exact) / Double(total), 0.97)
        let last = log.last!.status
        XCTAssertEqual(last.levelDBFS ?? 0, -20, accuracy: 0.5)
        XCTAssertEqual(last.rate, .fps25)
        XCTAssertEqual(last.discontinuities, 0)
        XCTAssertFalse(last.isReverse)
    }

    func testFreewheelAcrossShortDropoutThenRelock() {
        let rate = FrameRate.fps29_97df
        let st = Timecode(hours: 1, rate: rate)
        var x = LTCTest.encode(rate: rate, sampleRate: sr, seconds: 6, start: st)
        let spf = sr / rate.fps
        let dropStart = Int(3 * sr), dropLen = Int(6 * spf) // 6 frames < freewheelFrames (10)
        for i in dropStart..<(dropStart + dropLen) { x[i] = 0 }
        let reader = TimecodeReader(sampleRate: sr)
        let log = run(reader, x)
        let during = log.filter { $0.pos > dropStart + Int(2 * spf) && $0.pos < dropStart + dropLen }
        XCTAssertFalse(during.isEmpty)
        for s in during {
            XCTAssertEqual(s.status.state, .freewheel)
            let truth = st.adding(frames: Int(Double(s.pos) / spf))
            XCTAssertLessThanOrEqual(abs(s.status.timecode!.frameNumber - truth.frameNumber), 1, "freewheel keeps running")
        }
        let after = log.filter { $0.pos > dropStart + dropLen + Int(3 * spf) }
        XCTAssertTrue(after.allSatisfy { $0.status.state == .locked })
        XCTAssertEqual(log.last!.status.discontinuities, 0, "seamless resume is not a jump")
    }

    func testLongDropoutGoesToNoSignal() {
        let rate = FrameRate.fps30
        var x = LTCTest.encode(rate: rate, sampleRate: sr, seconds: 4, start: .zero(rate))
        let dropStart = Int(2 * sr)
        for i in dropStart..<x.count { x[i] = 0 }
        let reader = TimecodeReader(sampleRate: sr)
        reader.freewheelFrames = 10
        let log = run(reader, x)
        let spf = sr / rate.fps
        let noSig = log.first { $0.pos > dropStart && $0.status.state == .noSignal }!
        // Out of freewheel ~freewheelFrames after the last good frame.
        XCTAssertEqual(Double(noSig.pos - dropStart) / spf, 10, accuracy: 1.5)
        XCTAssertNil(noSig.status.timecode)
        XCTAssertNil(noSig.status.levelDBFS)
        XCTAssertTrue(log.contains { $0.pos > dropStart && $0.status.state == .freewheel })
    }

    func testJumpCountsDiscontinuityAndRelocks() {
        let rate = FrameRate.fps25
        let enc = LTCEncoder(sampleRate: sr, rate: rate, start: Timecode(hours: 1, rate: rate))
        enc.level = 0.4
        let reader = TimecodeReader(sampleRate: sr)
        var buf = [Float](repeating: 0, count: 480)
        var states: [(Int, TimecodeReader.Status)] = []
        var pos = 0
        for block in 0..<(5 * 100) { // 5 s
            if block == 200 { enc.locate(to: Timecode(hours: 7, minutes: 30, rate: rate)) }
            if block == 350 { enc.locate(to: Timecode(hours: 9, rate: rate)) }
            buf.withUnsafeMutableBufferPointer { enc.render(into: $0) }
            let st = buf.withUnsafeBufferPointer { reader.process($0) }
            pos += buf.count
            states.append((pos, st))
        }
        XCTAssertEqual(states.last!.1.discontinuities, 2)
        XCTAssertEqual(states.last!.1.state, .locked)
        XCTAssertEqual(states.last!.1.timecode?.hours, 9)
        // Right after the first jump the reader free-wheels the old timeline, then relocks on the new.
        let afterJump = states[(203)...(215)].map(\.1)
        XCTAssertTrue(afterJump.contains { $0.state == .freewheel && $0.timecode?.hours == 1 })
        XCTAssertTrue(states[230].1.state == .locked && states[230].1.timecode?.hours == 7)
    }

    func testReverseReader() {
        let rate = FrameRate.fps24
        let x = LTCTest.encode(rate: rate, sampleRate: sr, seconds: 3, start: Timecode(hours: 4, rate: rate))
        let reader = TimecodeReader(sampleRate: sr)
        let log = run(reader, Array(x.reversed()))
        let st = log.last!.status
        XCTAssertEqual(st.state, .locked)
        XCTAssertTrue(st.isReverse)
        // Played backwards from 04:00:03:00; the last frame read is 04:00:00:00, so "now" is the
        // frame before it.
        XCTAssertEqual(st.timecode?.description, "03:59:59:23")
    }

    func testResetClearsEverything() {
        let x = LTCTest.encode(rate: .fps25, sampleRate: sr, seconds: 1, start: .zero(.fps25))
        let reader = TimecodeReader(sampleRate: sr)
        _ = run(reader, x)
        XCTAssertEqual(reader.status.state, .locked)
        reader.reset()
        XCTAssertEqual(reader.status, TimecodeReader.Status())
    }
}

final class LTCScannerTests: XCTestCase {
    func testFindsLTCChannelAndExtrapolatesStart() {
        let sr = 48_000.0
        let rate = FrameRate.fps29_97ndf
        var rng = SplitMix64(seed: 3)
        let music = (0..<Int(sr * 12)).map { i in Float(0.3 * sin(Double(i) * 0.05)) + 0.05 * rng.gaussian() }
        let offset = 12_345
        let ltcStart = Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: rate)
        let ltc = [Float](repeating: 0, count: offset)
            + LTCTest.encode(rate: rate, sampleRate: sr, seconds: 12 - Double(offset) / sr, start: ltcStart, level: 0.2)
        let r = LTCScanner.scan(channels: [music, ltc], sampleRate: sr)
        XCTAssertEqual(r?.channel, 1)
        XCTAssertEqual(r?.rate, rate)
        // Sample 0 is 12345 / 1601.6 = 7.7 frames before the LTC's first frame → inside frame −8.
        XCTAssertEqual(r?.start, ltcStart.adding(frames: -8))
        XCTAssertEqual(r?.levelDBFS ?? 0, LTCTest.dB(0.2), accuracy: 0.5)
    }

    func testStartAtSampleZero() {
        for rate in [FrameRate.fps25, .fps29_97df, .fps23_976] {
            let st = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, rate: rate)
            let ltc = LTCTest.encode(rate: rate, sampleRate: 44_100, seconds: 5, start: st)
            let r = LTCScanner.scan(channels: [ltc, [Float](repeating: 0, count: ltc.count)], sampleRate: 44_100)
            XCTAssertEqual(r?.channel, 0)
            XCTAssertEqual(r?.start, st, "\(rate)")
            XCTAssertEqual(r?.rate, rate)
        }
    }

    func testNoLTC() {
        var rng = SplitMix64(seed: 4)
        let a = (0..<48_000 * 3).map { _ in 0.3 * rng.gaussian() }
        XCTAssertNil(LTCScanner.scan(channels: [a, []], sampleRate: 48_000))
        XCTAssertNil(LTCScanner.scan(channels: [], sampleRate: 48_000))
    }
}

final class LTCPerformanceTests: XCTestCase {
    /// Target: one 48 kHz channel in < 1 % of a core (optimised build). Debug builds get headroom.
    func testDecoderCPU() {
        let sr = 48_000.0
        let x = LTCTest.encode(rate: .fps29_97df, sampleRate: sr, seconds: 60, start: .zero(.fps29_97df))
        let dec = LTCDecoder(sampleRate: sr)
        var frames = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        x.withUnsafeBufferPointer { buf in
            var pos = 0
            while pos < buf.count {
                let n = min(1024, buf.count - pos)
                frames += dec.process(UnsafeBufferPointer(rebasing: buf[pos..<(pos + n)])).count
                pos += n
            }
        }
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let load = secs / 60 * 100
        print(String(format: "LTCDecoder: 60 s @48k in %.1f ms = %.3f %% of one core (%d frames)", secs * 1000, load, frames))
        XCTAssertGreaterThan(frames, 1790)
        #if DEBUG
        XCTAssertLessThan(load, 10)
        #else
        XCTAssertLessThan(load, 1)
        #endif
    }

    func testEncoderCPU() {
        let enc = LTCEncoder(sampleRate: 48_000, rate: .fps29_97df, start: .zero(.fps29_97df))
        var buf = [Float](repeating: 0, count: 256)
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<(48_000 * 60 / 256) { buf.withUnsafeMutableBufferPointer { enc.render(into: $0) } }
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        print(String(format: "LTCEncoder: 60 s @48k in %.1f ms = %.3f %% of one core", secs * 1000, secs / 60 * 100))
        #if DEBUG
        XCTAssertLessThan(secs / 60 * 100, 10)
        #else
        XCTAssertLessThan(secs / 60 * 100, 1)
        #endif
    }

    func testDecoderMeasure() {
        let x = LTCTest.encode(rate: .fps25, sampleRate: 48_000, seconds: 10, start: .zero(.fps25))
        measure {
            let dec = LTCDecoder(sampleRate: 48_000)
            _ = x.withUnsafeBufferPointer { dec.process($0) }
        }
    }
}
