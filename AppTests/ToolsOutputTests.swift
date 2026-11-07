import AVFoundation
import Accelerate
import XCTest
@testable import TCPlayback

final class ToolsOutputTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("outtest-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Read a WAV back through AVAudioFile (independent of our writer) as float L/R.
    private func read(_ url: URL) throws -> (l: [Float], r: [Float], sr: Double) {
        let f = try AVAudioFile(forReading: url)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)))
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        XCTAssertEqual(f.processingFormat.channelCount, 2)
        let l = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n))
        let r = Array(UnsafeBufferPointer(start: buf.floatChannelData![1], count: n))
        return (l, r, f.fileFormat.sampleRate)
    }

    private func db(_ x: Float) -> Float { 20 * log10f(max(x, 1e-12)) }

    func testToneIsMinus18dBFSOnLeftOnly() throws {
        let url = dir.appendingPathComponent("tone.wav")
        let (l, r) = TestSignals.place(TestSignals.sine(frequency: 1000, levelDBFS: -18, seconds: 2), side: .left)
        try TestSignals.writeWAV(left: l, right: r, to: url)
        let w = try read(url)
        XCTAssertEqual(w.sr, 48_000)
        let body = Array(w.l[4800..<(w.l.count - 4800)])
        // AES17: RMS referenced to a full-scale sine (+3.01 dB).
        XCTAssertEqual(db(TestSignals.rms(body)) + 3.0103, -18, accuracy: 0.1)
        XCTAssertEqual(db(TestSignals.peak(body)), -18, accuracy: 0.1)
        XCTAssertEqual(TestSignals.peak(w.r), 0)
    }

    func testPinkNoiseLevelAndSlope() throws {
        let url = dir.appendingPathComponent("pink.wav")
        let (l, r) = TestSignals.place(TestSignals.pinkNoise(rmsDBFS: -20, seconds: 6), side: .right)
        try TestSignals.writeWAV(left: l, right: r, to: url)
        let w = try read(url)
        XCTAssertEqual(TestSignals.peak(w.l), 0)
        XCTAssertEqual(db(TestSignals.rms(w.r)), -20, accuracy: 0.3)

        // Averaged power spectrum (Welch, Hann, 8192-point), then mean PSD per octave band.
        let n = 8192
        let log2n = vDSP_Length(13)
        let setup = try XCTUnwrap(vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)))
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var psd = [Double](repeating: 0, count: n / 2)
        var segments = 0
        var start = 0
        while start + n <= w.r.count {
            var x = Array(w.r[start..<(start + n)])
            vDSP_vmul(x, 1, window, 1, &x, 1, vDSP_Length(n))
            var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    x.withUnsafeBufferPointer { xp in
                        xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            for k in 1..<(n / 2) { psd[k] += Double(re[k] * re[k] + im[k] * im[k]) }
            segments += 1
            start += n / 2
        }
        XCTAssertGreaterThan(segments, 10)
        let binHz = 48_000.0 / Double(n)
        var bandDB: [Double] = []
        for lo in [125.0, 250, 500, 1000, 2000, 4000, 8000] {
            let a = Int(lo / binHz), b = Int(2 * lo / binHz)
            let mean = psd[a..<b].reduce(0, +) / Double(b - a)
            bandDB.append(10 * log10(mean))
        }
        // Per-Hz density of pink noise falls 3 dB per octave.
        let slopes = zip(bandDB.dropFirst(), bandDB).map { $0 - $1 }
        let avg = slopes.reduce(0, +) / Double(slopes.count)
        XCTAssertEqual(avg, -3, accuracy: 0.5, "slopes \(slopes)")
        for s in slopes { XCTAssertEqual(s, -3, accuracy: 1.2) }
    }

    func testPolarityClicksArePositiveAndAsymmetric() {
        let x = TestSignals.polarityClicks(seconds: 2)
        let maxV = x.max() ?? 0, minV = x.min() ?? 0
        XCTAssertEqual(db(maxV), -6, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(minV, 0)
    }

    func testVoiceRankingPrefersRichBritishMale() {
        let opts = [
            VoiceOption(id: "a", name: "Samantha", language: "en-US", quality: .enhanced, isMale: false),
            VoiceOption(id: "b", name: "Daniel", language: "en-GB", quality: .default, isMale: true),
            VoiceOption(id: "c", name: "Arthur", language: "en-GB", quality: .premium, isMale: true),
            VoiceOption(id: "d", name: "Kate", language: "en-GB", quality: .enhanced, isMale: false),
            VoiceOption(id: "e", name: "Fred", language: "en-US", quality: .default, isMale: true),
        ].sorted { VoiceIdentRenderer.score($0) > VoiceIdentRenderer.score($1) }
        XCTAssertEqual(opts.map(\.id).prefix(3), ["c", "b", "d"])
        XCTAssertTrue(VoiceIdentRenderer.hasRichVoice(in: opts))
        XCTAssertFalse(VoiceIdentRenderer.hasRichVoice(in: opts.filter { $0.id == "b" || $0.id == "a" }))
    }

    @MainActor
    func testLeftIdentHasSilentRight() async throws {
        let tester = OutputTester(engine: PlaybackEngine(), cacheDirectory: dir)
        guard tester.selectedVoiceID != nil else { throw XCTSkip("No English voice installed on this simulator") }
        let url: URL
        do { (url, _) = try await tester.identFile(.left) } catch VoiceIdentRenderer.RenderError.noAudio {
            throw XCTSkip("Speech synthesis produced no audio on this simulator")
        }
        let w = try read(url)
        XCTAssertEqual(w.sr, 48_000)
        XCTAssertGreaterThan(Double(w.l.count) / 48_000, 2)
        XCTAssertEqual(db(TestSignals.peak(w.l)), -6, accuracy: 0.2)
        XCTAssertEqual(TestSignals.peak(w.r), 0)
        // Cached: a second request returns the same file without re-rendering.
        let (again, _) = try await tester.identFile(.left)
        XCTAssertEqual(again, url)
    }

    func testFiveStudioVoicesShipAndDecode() throws {
        let voices = VoiceIdentRenderer.availableVoices()
        XCTAssertEqual(voices.count, 5)
        XCTAssertTrue(voices.allSatisfy { $0.studioKey != nil })
        XCTAssertTrue(VoiceIdentRenderer.hasRichVoice(in: voices))
        for v in voices {
            for side in OutputSide.allCases {
                let m = try VoiceIdentRenderer.loadStudio(v.studioKey!, side: side)
                let secs = Double(m.count) / TestSignals.sampleRate
                XCTAssertGreaterThan(secs, 3, "\(v.name) \(side)")
                XCTAssertLessThan(secs, 7, "\(v.name) \(side)")
                XCTAssertEqual(TestSignals.peak(m), TestSignals.dbToLinear(-6), accuracy: 0.01)
            }
        }
    }
}
