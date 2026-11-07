import XCTest
import TCKit
@testable import TCPlayback

final class ToolsInputAnalyzerTests: XCTestCase {
    /// Render `seconds` of LTC at `rate`, generated as if the source clock runs at
    /// `genRate` while we analyse it at `sr` (genRate < sr ⇒ source runs fast).
    private func measure(_ rate: FrameRate, sr: Double = 48_000, genRate: Double? = nil,
                         seconds: Double = 6, level: Float = 1, noise: Float = 0) -> Double? {
        let gen = genRate ?? sr
        let n = Int(gen * seconds)
        var buf = [Float](repeating: 0, count: n)
        let enc = LTCEncoder(sampleRate: gen, rate: rate, start: Timecode(hours: 1, rate: rate))
        buf.withUnsafeMutableBufferPointer { enc.render(into: $0) }
        var seed: UInt32 = 1
        for i in buf.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            buf[i] = buf[i] * level + noise * (Float(seed >> 8) / Float(1 << 24) - 0.5) + 0.02
        }
        var m = LTCSpeedMeter(sampleRate: sr)
        buf.withUnsafeBufferPointer { b in
            var i = 0
            while i < b.count {
                let c = min(1024, b.count - i)
                m.process(UnsafeBufferPointer(rebasing: b[i..<i + c]))
                i += c
            }
        }
        return m.bitRate.map { $0 / 80 }
    }

    func testMeasuresNominalRates() throws {
        for r in [FrameRate.fps24, .fps25, .fps29_97ndf, .fps29_97df, .fps30] {
            let fps = try XCTUnwrap(measure(r), "no measurement at \(r)")
            let ppm = (fps / r.fps - 1) * 1e6
            XCTAssertLessThan(abs(ppm), 30, "\(r): measured \(fps) (\(ppm) ppm)")
        }
    }

    func testTells2997From30() throws {
        let a = try XCTUnwrap(measure(.fps29_97ndf)), b = try XCTUnwrap(measure(.fps30))
        XCTAssertEqual(a, 29.97, accuracy: 0.002)
        XCTAssertEqual(b, 30.0, accuracy: 0.002)
    }

    func testSeesSourceClockDrift() throws {
        // Source clock 100 ppm fast relative to the analyser.
        let fps = try XCTUnwrap(measure(.fps25, genRate: 48_000 / (1 + 100e-6)))
        let ppm = (fps / 25 - 1) * 1e6
        XCTAssertEqual(ppm, 100, accuracy: 25)
    }

    func testToleratesLowLevelAndNoise() throws {
        let fps = try XCTUnwrap(measure(.fps30, sr: 44_100, level: 0.05, noise: 0.004))
        XCTAssertEqual(fps, 30, accuracy: 0.003)
    }

    func testProgrammeAudioGivesNoReading() {
        var m = LTCSpeedMeter(sampleRate: 48_000)
        let sine = (0..<48_000 * 4).map { Float(0.5 * sin(Double($0) * 2 * .pi * 440 / 48_000)) }
        sine.withUnsafeBufferPointer { m.process($0) }
        // A pure tone has equal intervals; it may lock as all-zero cells but must not read as a TC rate.
        if let br = m.bitRate { XCTAssertFalse((1900...2410).contains(br), "tone read as LTC: \(br)") }
    }

    func testCorrelation() {
        let a: [Float] = (0..<512).map { sinf(Float($0) * 0.1) }
        XCTAssertEqual(InputAnalyzer.correlate(a, a) ?? 0, 1, accuracy: 1e-4)
        XCTAssertEqual(InputAnalyzer.correlate(a, a.map { -$0 }) ?? 0, -1, accuracy: 1e-4)
        XCTAssertNil(InputAnalyzer.correlate(a, [Float](repeating: 0, count: 512)))
    }
}
