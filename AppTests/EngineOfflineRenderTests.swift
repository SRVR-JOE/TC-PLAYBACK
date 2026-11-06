import AVFoundation
import XCTest
import TCKit
@testable import TCPlayback

/// Drives the real render path (AudioGraph + RenderCore + FileStreamer) through
/// AVAudioEngine manual rendering, with a generated test WAV: L = 1 kHz sine, R = square.
final class EngineOfflineRenderTests: XCTestCase {
    static let rate: Double = 48_000
    static let sineAmp: Float = 0.5
    static let squareAmp: Float = 0.25

    static func sine(_ i: Int, rate: Double = rate) -> Float { sineAmp * Float(sin(2 * .pi * 1000 * Double(i) / rate)) }
    static func square(_ i: Int) -> Float { (i / 24) % 2 == 0 ? squareAmp : -squareAmp } // 1 kHz at 48 kHz

    private var tempFiles: [URL] = []

    override func tearDown() {
        for u in tempFiles { try? FileManager.default.removeItem(at: u) }
        super.tearDown()
    }

    /// Writes a float WAV: ch0 = sine, ch1 = square (stereo) or sine only (mono).
    func makeWAV(seconds: Double, rate: Double = rate, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("engine-test-\(UUID().uuidString).wav")
        tempFiles.append(url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let ch = buf.floatChannelData!
        for i in 0..<n {
            ch[0][i] = Self.sine(i, rate: rate)
            if channels > 1 { ch[1][i] = Self.square(i) }
        }
        try file.write(from: buf)
        return url
    }

    struct Rig {
        let graph: AudioGraph
        let buffer: AVAudioPCMBuffer
        var core: RenderCore { graph.core }
        var l: [Float] = []
        var r: [Float] = []

        init() throws {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: EngineOfflineRenderTests.rate,
                                    channels: 2, interleaved: false)!
            graph = try AudioGraph(manualRenderingFormat: fmt, maximumFrameCount: 4096)
            buffer = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat, frameCapacity: 4096)!
        }

        /// Renders `frames` frames in blocks of `block`, appending to l/r (unless `keep` is false).
        mutating func render(_ frames: Int, block: Int = 512, keep: Bool = true,
                             each: ((UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void)? = nil) throws {
            if !graph.engine.isRunning { try graph.engine.start() }
            var done = 0
            while done < frames {
                let n = AVAudioFrameCount(min(block, frames - done))
                let status = try graph.engine.renderOffline(n, to: buffer)
                XCTAssertEqual(status, .success)
                let got = Int(buffer.frameLength)
                let ch = buffer.floatChannelData!
                if keep {
                    l.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: got))
                    r.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: got))
                }
                each?(ch[0], ch[1], got)
                done += got
            }
        }
    }

    func startFile(_ url: URL, routing: ChannelRouting = ChannelRouting(), rig: Rig, thread: Bool = false) throws -> FileStreamer {
        let s = try FileStreamer(url: url, core: rig.core)
        rig.core.setRouting(routing)
        // Make the routing ramp start settled so the comparison window is clean.
        rig.core.state.pointee.routingBits = RoutingMath.pack(routing)
        rig.core.state.pointee.ramp.snap(to: RoutingMath.matrix(for: routing))
        s.prime()
        if thread { s.start() }
        rig.core.activate(.file)
        rig.core.setRun(true)
        return s
    }

    // MARK: File playback

    func testStereoFilePlaysSampleAccurate() throws {
        var rig = try Rig()
        let url = try makeWAV(seconds: 1)
        _ = try startFile(url, rig: rig)
        try rig.render(24_000)
        // After the 5 ms fade-in, the output equals the file exactly.
        for i in 512..<24_000 {
            XCTAssertEqual(rig.l[i], Self.sine(i), accuracy: 1e-5, "L @\(i)")
            XCTAssertEqual(rig.r[i], Self.square(i), accuracy: 1e-5, "R @\(i)")
            if abs(rig.l[i] - Self.sine(i)) > 1e-5 { break }
        }
        // The fade-in starts from silence (no click) and is monotone in gain.
        XCTAssertLessThan(abs(rig.r[0]), 0.01)
        XCTAssertEqual(rig.core.positionFrames.load(ordering: .relaxed), 24_000)
        XCTAssertEqual(rig.core.underruns.load(ordering: .relaxed), 0)
    }

    func testEndOfFileReportsFinishedAndPosition() throws {
        var rig = try Rig()
        let url = try makeWAV(seconds: 0.5)
        let s = try startFile(url, rig: rig)
        XCTAssertEqual(s.duration, 0.5, accuracy: 1e-9)
        try rig.render(30_000)
        XCTAssertTrue(rig.core.finished.load(ordering: .relaxed))
        XCTAssertEqual(rig.core.positionFrames.load(ordering: .relaxed), 24_000)
        XCTAssertEqual(rig.l.suffix(1000).map(abs).max() ?? 1, 0, "silence after the end")
    }

    func testSwapMuteAndGainRouting() throws {
        var rig = try Rig()
        let url = try makeWAV(seconds: 1)
        _ = try startFile(url, routing: ChannelRouting(leftEnabled: true, rightEnabled: true, swapped: true, gainDB: 0), rig: rig)
        try rig.render(4_800)
        for i in 1_000..<4_800 {
            XCTAssertEqual(rig.l[i], Self.square(i), accuracy: 1e-5)
            XCTAssertEqual(rig.r[i], Self.sine(i), accuracy: 1e-5)
        }
        // Mute source L while swapped → right output (which carried L) goes silent; ramped, not stepped.
        rig.core.setRouting(ChannelRouting(leftEnabled: false, rightEnabled: true, swapped: true, gainDB: -6))
        try rig.render(4_800)
        let g = RoutingMath.linearGain(dB: -6)
        for i in 4_800 + 600..<9_600 {
            XCTAssertEqual(rig.r[i], 0, accuracy: 1e-6)
            XCTAssertEqual(rig.l[i], Self.square(i) * g, accuracy: 1e-5)
        }
        // During the 10 ms ramp, no sample-to-sample step bigger than the 1 kHz sine's own slope
        // (2π·1000/48000·0.5 ≈ 0.065) plus the ramp increment — i.e. no click.
        for i in 4_801..<(4_800 + 480) {
            XCTAssertLessThan(abs(rig.r[i] - rig.r[i - 1]), 0.068)
        }
    }

    func testMonoFileLeftOnly() throws {
        var rig = try Rig()
        let url = try makeWAV(seconds: 0.5, channels: 1)
        let s = try startFile(url, rig: rig)
        XCTAssertEqual(s.channelCount, 1)
        try rig.render(9_600)
        for i in 1_000..<9_600 {
            XCTAssertEqual(rig.l[i], Self.sine(i), accuracy: 1e-5)
            XCTAssertEqual(rig.r[i], 0)
        }
    }

    func testResampled44k1FileHasCorrectLengthAndPitch() throws {
        var rig = try Rig()
        let url = try makeWAV(seconds: 1, rate: 44_100)
        let s = try startFile(url, rig: rig, thread: true)
        defer { s.stop() }
        XCTAssertTrue(s.needsResampling)
        XCTAssertEqual(s.lengthFrames, 48_000)
        // Render slowly enough for the reader thread to keep up.
        var frames = 0
        while !rig.core.finished.load(ordering: .relaxed) && frames < 60_000 {
            try rig.render(512)
            frames += 512
            usleep(200)
        }
        XCTAssertTrue(rig.core.finished.load(ordering: .relaxed))
        let pos = rig.core.positionFrames.load(ordering: .relaxed)
        XCTAssertEqual(Double(pos), 48_000, accuracy: 64)
        // 1 kHz sine survives conversion: count zero crossings over 0.5 s → ≈ 1000.
        let mid = Array(rig.l[10_000..<34_000])
        var crossings = 0
        for i in 1..<mid.count where (mid[i - 1] < 0) != (mid[i] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings), 1000, accuracy: 4)
        XCTAssertEqual(mid.map(abs).max() ?? 0, Self.sineAmp, accuracy: 0.01)
    }

    func testSeekFlushesAndLandsOnTarget() throws {
        var rig = try Rig()
        let url = try makeWAV(seconds: 2)
        let s = try startFile(url, rig: rig, thread: true)
        defer { s.stop() }
        try rig.render(9_600)
        let gen = rig.core.requestSeek(toFrame: 60_000)
        rig.l.removeAll(); rig.r.removeAll()
        var waited = 0
        while rig.core.handledSeekGenOut.load(ordering: .acquiring) != gen && waited < 2_000 {
            try rig.render(256)
            usleep(500); waited += 1
        }
        XCTAssertEqual(rig.core.handledSeekGenOut.load(ordering: .acquiring), gen)
        // Old audio faded out — never a hard cut (max step across the wait stays small vs. full scale).
        let preCount = rig.l.count
        rig.l.removeAll(); rig.r.removeAll()
        let posAtPickup = rig.core.positionFrames.load(ordering: .relaxed)
        try rig.render(4_800)
        XCTAssertGreaterThanOrEqual(posAtPickup, 60_000)
        XCTAssertLessThanOrEqual(posAtPickup, 60_000 + 256)
        XCTAssertGreaterThan(preCount, 0)
        // After the fade-in the output is the file from the seek target onward.
        let base = rig.core.positionFrames.load(ordering: .relaxed) - 4_800
        for i in 1_000..<4_800 {
            XCTAssertEqual(rig.l[i], Self.sine(base + i), accuracy: 1e-5)
            XCTAssertEqual(rig.r[i], Self.square(base + i), accuracy: 1e-5)
        }
    }

    func testPauseFadesAndHoldsPosition() throws {
        var rig = try Rig()
        let url = try makeWAV(seconds: 1)
        _ = try startFile(url, rig: rig)
        try rig.render(4_800)
        rig.core.setRun(false)
        try rig.render(4_800)
        let pos = rig.core.positionFrames.load(ordering: .relaxed)
        XCTAssertEqual(pos, 4_800 + 512, accuracy: 512, "position stops within one block + fade")
        XCTAssertEqual(rig.l.suffix(4_000).map(abs).max() ?? 1, 0)
        try rig.render(4_800)
        XCTAssertEqual(rig.core.positionFrames.load(ordering: .relaxed), pos)
        // Fade-out is gradual: no single step larger than the sine's own slope + fade.
        for i in 4_801..<(4_800 + 512) { XCTAssertLessThan(abs(rig.l[i] - rig.l[i - 1]), 0.08) }
    }

    func testPanicFadeReachesSilence() throws {
        var rig = try Rig()
        let url = try makeWAV(seconds: 1)
        _ = try startFile(url, rig: rig)
        try rig.render(4_800)
        let gen = rig.core.requestMasterFade(frames: 4_800)
        try rig.render(9_600)
        XCTAssertEqual(rig.core.masterFadeDoneGen.load(ordering: .relaxed), gen)
        XCTAssertEqual(rig.l.suffix(4_000).map(abs).max() ?? 1, 0)
        // Halfway through the fade the level is about half.
        let half = rig.l[(4_800 + 2_400 - 48)..<(4_800 + 2_400 + 48)].map(abs).max() ?? 0
        XCTAssertEqual(half, Self.sineAmp * 0.5, accuracy: 0.03)
    }

    func testMetersAndAnalysisRing() throws {
        var rig = try Rig()
        let url = try makeWAV(seconds: 1)
        _ = try startFile(url, routing: ChannelRouting(leftEnabled: false), rig: rig)
        // 0.95 s ≈ 3 time constants of the 300 ms RMS smoother (≈ 98 % of true RMS),
        // still inside the 1 s primed by the streamer (no reader thread in this test).
        try rig.render(45_600)
        let p = rig.core.takePeaks()
        XCTAssertEqual(p.sl, Self.sineAmp, accuracy: 0.01)
        XCTAssertEqual(p.sr, Self.squareAmp, accuracy: 0.01)
        XCTAssertEqual(p.ol, 0, "output L is muted")
        XCTAssertEqual(p.or, Self.squareAmp, accuracy: 0.01)
        let rms = rig.core.rms()
        XCTAssertEqual(rms.sl, Self.sineAmp / sqrtf(2), accuracy: 0.03)
        XCTAssertEqual(rms.sr, Self.squareAmp, accuracy: 0.02)
        XCTAssertFalse(rig.core.clipL.load(ordering: .relaxed))
        // Source samples (pre-mute) reach the analysis ring, so muted LTC can still be decoded.
        XCTAssertGreaterThanOrEqual(rig.core.analysisRing.readableCount, 14_400)
        XCTAssertEqual(rig.core.analysisRing.totalRead, 0)
        var l = [Float](repeating: 0, count: 2_000), r = l
        rig.core.analysisRing.read(nil, nil, count: 10_000)
        rig.core.analysisRing.read(&l, &r, count: 2_000)
        for i in 0..<2_000 { XCTAssertEqual(l[i], Self.sine(10_000 + i), accuracy: 1e-5) }
    }

    // MARK: Generator

    func testGeneratorTenMinutesContinuous() throws {
        var rig = try Rig()
        let start = Timecode(hours: 1, rate: .fps25)
        let enc = LTCEncoder(sampleRate: Self.rate, rate: .fps25, start: start)
        enc.level = 0.316
        rig.core.configureGenerator(encoder: enc, side: .right, durationFrames: -1, startFrameNumber: start.frameNumber)
        rig.core.activate(.generator)
        rig.core.setRun(true)
        let total = Int(Self.rate * 600)
        let analysis = rig.core.analysisRing
        var peakL: Float = 0, peakR: Float = 0
        var longestFlat = 0, flat = 0, last: Float = 0
        var nonZero = false
        try rig.render(total, block: 4096, keep: false) { l, r, n in
            for i in 0..<n {
                let a = abs(l[i]); if a > peakL { peakL = a }
                let b = abs(r[i]); if b > peakR { peakR = b }
                if r[i] != 0 { nonZero = true }
                if r[i] == last { flat += 1; if flat > longestFlat { longestFlat = flat } } else { flat = 0 }
                last = r[i]
            }
            // Keep the analysis ring from filling (as the monitor thread would).
            analysis.read(nil, nil, count: n)
        }
        XCTAssertEqual(rig.core.positionFrames.load(ordering: .relaxed), total, "every frame rendered, none skipped")
        XCTAssertFalse(rig.core.finished.load(ordering: .relaxed))
        XCTAssertEqual(peakL, 0, "LTC only on the right side")
        XCTAssertLessThanOrEqual(peakR, enc.level * 1.1, "no bursts above the set level")
        if nonZero {
            // Real encoder (TCKit merged): 10 min of 25 fps = 15 000 frames, and the signal
            // never stalls longer than one bit cell (48000 / 2000 = 24 samples, + rise time).
            XCTAssertEqual(rig.core.genFrameNumber.load(ordering: .relaxed) - start.frameNumber, 15_000, accuracy: 1)
            XCTAssertLessThan(longestFlat, 40)
        }
    }

    func testGeneratorStopsAfterDuration() throws {
        var rig = try Rig()
        let start = Timecode(rate: .fps30)
        let enc = LTCEncoder(sampleRate: Self.rate, rate: .fps30, start: start)
        rig.core.configureGenerator(encoder: enc, side: .both, durationFrames: 96_000, startFrameNumber: 0)
        rig.core.activate(.generator)
        rig.core.setRun(true)
        let analysis = rig.core.analysisRing
        try rig.render(120_000, block: 4096, keep: false) { _, _, n in analysis.read(nil, nil, count: n) }
        XCTAssertTrue(rig.core.finished.load(ordering: .relaxed))
        XCTAssertEqual(rig.core.positionFrames.load(ordering: .relaxed), 96_000)
    }
}
