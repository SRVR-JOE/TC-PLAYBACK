import XCTest
import AVFoundation
import TCKit
@testable import TCPlayback

/// End-to-end: a track file with real LTC on the RIGHT channel (muted in routing) → render core →
/// analysis ring → TimecodeMonitor → locked status at the right timecode.
final class IntegrationLTCTests: XCTestCase {
    func testFileLTCOnMutedRightLocks() throws {
        let rate = EngineOfflineRenderTests.rate
        let fr = FrameRate.fps25
        let start = Timecode(hours: 1, rate: fr)
        // Build the WAV: L = sine, R = LTC.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ltc-int-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(rate * 4)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let enc = LTCEncoder(sampleRate: rate, rate: fr, start: start)
        enc.render(into: UnsafeMutableBufferPointer(start: buf.floatChannelData![1], count: n))
        for i in 0..<n { buf.floatChannelData![0][i] = 0.3 * sinf(Float(i) * 2 * .pi * 440 / Float(rate)) }
        try file.write(from: buf)
        } // file closes (header finalised) here

        let test = EngineOfflineRenderTests()
        var rig = try EngineOfflineRenderTests.Rig()
        let streamer = try test.startFile(url, routing: ChannelRouting(leftEnabled: true, rightEnabled: false), rig: rig, thread: true)
        let monitor = TimecodeMonitor(analysisRing: rig.core.analysisRing, sampleRate: rate)
        monitor.start()
        defer { monitor.stop(); withExtendedLifetime(streamer) {} }
        // Render 3 s in real-ish chunks so the monitor thread keeps up with the 1 s ring.
        for _ in 0..<30 { try rig.render(Int(rate / 10), keep: true); usleep(20_000) }
        usleep(200_000)
        let out = monitor.read()
        XCTAssertEqual(out.right.state, .locked, "R reader should lock even though R is muted")
        XCTAssertEqual(out.left.state, .noSignal)
        let tc = try XCTUnwrap(out.right.timecode)
        // ~3 s in → around 01:00:03:00 (allow ±0.5 s for chunking/latency).
        XCTAssertEqual(tc.realSeconds - start.realSeconds, 3.0, accuracy: 0.5, "got \(tc)")
        XCTAssertEqual(out.right.rate?.nominalFPS, 25)
        // Muted R really is silent at the output.
        XCTAssertLessThan(rig.r.suffix(48_000).map(abs).max() ?? 1, 1e-6)
    }
}
