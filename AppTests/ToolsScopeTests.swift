import XCTest
import TCKit
@testable import TCPlayback

final class ToolsScopeTests: XCTestCase {
    // MARK: Timecode difference

    func testFramesLateSimple() {
        let out = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 10, rate: .fps30)
        let inp = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 8, rate: .fps30)
        XCTAssertEqual(ScopeCompare.framesLate(output: out, input: inp), 2)
        XCTAssertEqual(ScopeCompare.framesLate(output: inp, input: out), -2)
    }

    func testFramesLateAcrossMidnight() {
        // Output has rolled over to 00:00:00:01, input is still at 23:59:59:28 → input 3 frames late.
        let out = Timecode(hours: 0, minutes: 0, seconds: 0, frames: 1, rate: .fps30)
        let inp = Timecode(hours: 23, minutes: 59, seconds: 59, frames: 28, rate: .fps30)
        XCTAssertEqual(ScopeCompare.framesLate(output: out, input: inp), 3)
        XCTAssertEqual(ScopeCompare.framesLate(output: inp, input: out), -3)
    }

    func testFramesLateAcrossMidnightDropFrame() {
        let out = Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0, rate: .fps29_97df)
        let inp = Timecode(hours: 23, minutes: 59, seconds: 59, frames: 29, rate: .fps29_97df)
        XCTAssertEqual(ScopeCompare.framesLate(output: out, input: inp), 1)
        XCTAssertEqual(ScopeCompare.framesPerDay(.fps29_97df), 2_589_408)
        XCTAssertEqual(ScopeCompare.framesPerDay(.fps25), 2_160_000)
    }

    func testMixedRatesRefused() {
        let out = Timecode(hours: 1, rate: .fps30)
        XCTAssertNil(ScopeCompare.framesLate(output: out, input: Timecode(hours: 1, rate: .fps29_97ndf)))
        XCTAssertNil(ScopeCompare.framesLate(output: out, input: Timecode(hours: 1, rate: .fps25)))
        XCTAssertNil(ScopeCompare.framesLate(output: Timecode(hours: 1, rate: .fps29_97df),
                                             input: Timecode(hours: 1, rate: .fps29_97ndf)))
    }

    // MARK: Latency

    private func noise(_ n: Int, seed: UInt32) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 1_664_525 &+ 1_013_904_223
            return Float(s >> 8) / Float(1 << 24) - 0.5
        }
    }

    func testLatencyFindsDelayInNoise() throws {
        let n = 48_000
        let delay = 1234
        let ref = noise(n, seed: 7)
        let hiss = noise(n, seed: 99)
        var del = [Float](repeating: 0, count: n)
        for t in 0..<n { del[t] = (t >= delay ? ref[t - delay] * 0.6 : 0) + hiss[t] * 0.3 }
        let r = try XCTUnwrap(LatencyEstimator.estimate(reference: ref, delayed: del, window: 9_600, maxLag: 24_000))
        XCTAssertEqual(r.lagSamples, Double(delay), accuracy: 2)
        XCTAssertFalse(r.inverted)
        XCTAssertGreaterThan(r.confidence, 0.5)
    }

    func testLatencyOnLTCAndInvertedPolarity() throws {
        // An inverted LTC loop back (common with a swapped balanced pair), delayed 1234 samples.
        let n = 48_000
        var ltc = [Float](repeating: 0, count: n)
        let enc = LTCEncoder(sampleRate: 48_000, rate: .fps30, start: Timecode(hours: 1, rate: .fps30))
        ltc.withUnsafeMutableBufferPointer { enc.render(into: $0) }
        let hiss = noise(n, seed: 3)
        var del = [Float](repeating: 0, count: n)
        for t in 1234..<n { del[t] = -ltc[t - 1234] * 0.5 + hiss[t] * 0.1 }
        let r = try XCTUnwrap(LatencyEstimator.estimate(reference: ltc, delayed: del, window: 9_600, maxLag: 24_000))
        XCTAssertEqual(r.lagSamples, 1234, accuracy: 2)
        XCTAssertTrue(r.inverted)
    }

    func testLatencySilenceGivesNothing() {
        let z = [Float](repeating: 0, count: 40_000)
        XCTAssertNil(LatencyEstimator.estimate(reference: noise(40_000, seed: 1), delayed: z, window: 9_600, maxLag: 24_000))
    }

    // MARK: Status line

    private func inputs(out: Timecode?, inp: Timecode?, ms: Double? = nil, playing: Bool = true, signal: Bool = true) -> ScopeCompare.Inputs {
        ScopeCompare.Inputs(outputPlaying: playing, outputTC: out, outputRate: out?.rate,
                            inputHasSignal: signal, inputTC: inp, inputRate: inp?.rate, latencyMS: ms)
    }

    func testStatusLineWording() {
        let out = Timecode(hours: 1, minutes: 0, seconds: 10, frames: 2, rate: .fps30)
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: out, inp: out.adding(frames: -2), ms: 67.2)),
                       "Input matches output, 2 frames late (67 ms)")
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: out, inp: out.adding(frames: -1))),
                       "Input matches output, 1 frame late")
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: out, inp: out, ms: 4.2)),
                       "Input matches output, in sync (4.2 ms)")
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: out, inp: out.adding(frames: 1))),
                       "Input matches output, 1 frame early")
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: out, inp: Timecode(hours: 1, minutes: 0, seconds: 10, rate: .fps29_97ndf))),
                       "Input rate 29.97 ND does not match output 30")
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: out, inp: out.adding(frames: -300))),
                       "Input timecode is 00:00:10:00 behind the output")
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: nil, inp: nil, playing: false)), "Nothing playing")
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: out, inp: nil, signal: false)), "Waiting for the device audio input")
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: out, inp: nil)), "No timecode on the input")
        XCTAssertEqual(ScopeCompare.statusLine(inputs(out: out, inp: nil, ms: 12)),
                       "No timecode on the input. Audio returns after 12 ms")
    }

    // MARK: Engine tap

    /// The post-mix tap records what the render callback outputs, and only while enabled.
    func testOutputTapRecordsPostMixOnlyWhenEnabled() {
        let core = RenderCore(sampleRate: 48_000)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 512), r = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { l.deallocate(); r.deallocate() }
        core.render(frames: 512, outL: l, outR: r, hostTime: 1_000_000)
        XCTAssertEqual(core.outputTap.totalWritten, 0)
        XCTAssertNil(core.outputTapClock.origin)
        core.outputTapEnabled.store(true, ordering: .relaxed)
        core.render(frames: 512, outL: l, outR: r, hostTime: 1_000_000)
        XCTAssertEqual(core.outputTap.totalWritten, 512)
        XCTAssertNotNil(core.outputTapClock.origin)
    }
}
