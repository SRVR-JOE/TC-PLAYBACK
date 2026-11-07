import XCTest
import AVFoundation
import TCKit
@testable import TCPlayback

final class ToolsCueVideoTests: XCTestCase {
    private let sr = CueSyncFeatures.sampleRate
    private let frame30 = 1.0 / 30

    // MARK: Link and offset math

    func testLinkPersistsPerTrack() throws {
        let suite = "ToolsCueVideoTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let a = UUID(), b = UUID()
        XCTAssertNil(CueVideoStore.load(a, defaults: d))
        let link = CueVideoLink(fileName: "x.mov", offset: 37.25, rate: 1, displayName: "Rehearsal")
        CueVideoStore.save(link, for: a, defaults: d)
        XCTAssertEqual(CueVideoStore.load(a, defaults: d), link)
        XCTAssertNil(CueVideoStore.load(b, defaults: d))
        XCTAssertNotNil(d.data(forKey: "cuePoints.video.\(a.uuidString)"))
        CueVideoStore.remove(a, defaults: d, deleteFile: false)
        XCTAssertNil(CueVideoStore.load(a, defaults: d))
    }

    func testLinkDecodesMinimalJSON() throws {
        let l = try JSONDecoder().decode(CueVideoLink.self, from: Data(#"{"fileName":"a.mp4"}"#.utf8))
        XCTAssertEqual(l.offset, 0); XCTAssertEqual(l.rate, 1); XCTAssertEqual(l.title, "a.mp4")
    }

    func testOffsetMath() {
        let l = CueVideoLink(fileName: "v", offset: 10)
        XCTAssertEqual(l.videoTime(atTrackTime: 25), 15)
        XCTAssertEqual(l.videoTime(atTrackTime: 5), -5)          // before the video starts
        XCTAssertEqual(l.trackTime(atVideoTime: 15), 25)
        // Line up here: video frame at 4.0 s belongs at track 61.5 s.
        let o = CueVideoLink.offset(trackTime: 61.5, videoTime: 4)
        XCTAssertEqual(o, 57.5)
        XCTAssertEqual(CueVideoLink(fileName: "v", offset: o).videoTime(atTrackTime: 61.5), 4)
    }

    func testOffsetFormatAndParse() {
        XCTAssertEqual(CueVideoOffsetFormat.seconds(37.25), "+37.250 s")
        XCTAssertEqual(CueVideoOffsetFormat.seconds(-1.5), "−1.500 s")
        XCTAssertEqual(CueVideoOffsetFormat.framesText(37.25, rate: .fps30), "+37 s 8 f")
        XCTAssertEqual(CueVideoOffsetFormat.framesText(-0.5, rate: .fps25), "−0 s 13 f")
        XCTAssertEqual(CueVideoOffsetFormat.framesText(0, rate: .fps30), "0 s 0 f")
        XCTAssertEqual(CueVideoOffsetFormat.parse("37.25", rate: .fps30), 37.25)
        XCTAssertEqual(CueVideoOffsetFormat.parse("−2 s", rate: .fps30), -2)
        XCTAssertEqual(CueVideoOffsetFormat.parse("-00:00:01:15", rate: .fps30)!, -1.5, accuracy: 1e-9)
        XCTAssertEqual(CueVideoOffsetFormat.parse("37:15", rate: .fps30)!, 37.5, accuracy: 1e-9)
        XCTAssertNil(CueVideoOffsetFormat.parse("abc", rate: .fps30))
    }

    func testLTCOffsetUsesTrackClock() {
        let clock = CuePointClock(start: Timecode(hours: 1, rate: .fps30))
        // The video shows 01:00:40:00 at 2.5 s → track time 40 s ↔ video 2.5 s → offset 37.5.
        let found = CueVideoLTC.Found(timecode: Timecode(hours: 1, seconds: 40, rate: .fps30), videoTime: 2.5)
        XCTAssertEqual(CueVideoLTC.offset(for: found, clock: clock), 37.5, accuracy: 1e-9)
    }

    // MARK: Correlation

    func testCrossCorrelateMatchesDirect() {
        var g = Rng(seed: 3)
        let a = (0..<37).map { _ in g.gauss() }, b = (0..<90).map { _ in g.gauss() }
        let c = CueAutoSync.crossCorrelate(a, b)
        for lag in [-36, -5, 0, 7, 53, 89] {
            var direct: Float = 0
            for i in 0..<a.count where i + lag >= 0 && i + lag < b.count { direct += a[i] * b[i + lag] }
            XCTAssertEqual(c[((lag % c.count) + c.count) % c.count], direct, accuracy: 1e-3, "lag \(lag)")
        }
    }

    /// The spec case: a click/noise-burst pattern, a copy delayed by 37.25 s, quieter, with noise.
    func testAutoSyncFindsDelayedCopyWithinOneFrame() throws {
        var g = Rng(seed: 11)
        let track = burstTrack(seconds: 160, rng: &g)
        let start = 37.25
        var video = Array(track[Int(start * sr)..<Int((start + 90) * sr)])
        for i in video.indices { video[i] = video[i] * 0.3 + 0.03 * g.gauss() }   // −10 dB and hiss
        let r = try CueAutoSync.estimate(trackSamples: track, videoSamples: video)
        XCTAssertEqual(r.offset, start, accuracy: frame30, "offset \(r.offset)")
        XCTAssertEqual(r.strength, .strong, "confidence \(r.confidence) ratio \(r.peakRatio)")
        print("auto sync +37.25: found \(r.offset) err \((r.offset - start) * 1000) ms conf \(r.confidence) ratio \(r.peakRatio) refined \(r.refined)")
    }

    /// Phone in a loud room: reverb smear, crowd noise louder than the music, limiter-ish gain,
    /// and the recording starts before the track (negative offset).
    func testAutoSyncLoudRoomNegativeOffset() throws {
        var g = Rng(seed: 29)
        let track = burstTrack(seconds: 120, rng: &g)
        let lead = 12.5
        var video = [Float](repeating: 0, count: Int((lead + 100) * sr))
        for i in 0..<Int(100 * sr) { video[Int(lead * sr) + i] = track[i] }
        // Room: one-pole smear (~60 ms) plus an echo at 85 ms.
        var y: Float = 0
        let echo = Int(0.085 * sr)
        var wet = video
        for i in wet.indices {
            y = 0.998 * y + 0.03 * video[i]
            wet[i] = video[i] + 2.5 * y + (i >= echo ? 0.4 * video[i - echo] : 0)
        }
        // Crowd: slowly swelling noise, louder than the music on average; gain riding.
        for i in wet.indices {
            let t = Double(i) / sr
            let crowd = Float(0.35 + 0.25 * sin(t * 0.7)) * g.gauss()
            let gain = Float(0.5 + 0.3 * sin(t * 0.21))
            wet[i] = tanhf((wet[i] * 0.6 + crowd) * gain * 2)
        }
        let r = try CueAutoSync.estimate(trackSamples: track, videoSamples: wet)
        XCTAssertEqual(r.offset, -lead, accuracy: frame30, "offset \(r.offset)")
        XCTAssertNotEqual(r.strength, .weak, "confidence \(r.confidence) ratio \(r.peakRatio)")
        print("auto sync loud room −12.5: found \(r.offset) err \((r.offset + lead) * 1000) ms conf \(r.confidence) ratio \(r.peakRatio) refined \(r.refined)")
    }

    func testAutoSyncUnrelatedAudioIsWeak() throws {
        var g = Rng(seed: 5), h = Rng(seed: 99)
        let track = burstTrack(seconds: 90, rng: &g)
        let other = burstTrack(seconds: 60, rng: &h)
        let r = try CueAutoSync.estimate(trackSamples: track, videoSamples: other)
        XCTAssertEqual(r.strength, .weak, "confidence \(r.confidence) ratio \(r.peakRatio)")
    }

    func testAutoSyncCancels() {
        var g = Rng(seed: 1)
        let f = CueAutoSync.features(burstTrack(seconds: 30, rng: &g))
        XCTAssertThrowsError(try CueAutoSync.estimate(track: f, video: f, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    /// A tiny generated movie: it has pictures (thumbnails work) and no sound (auto sync says so).
    func testGeneratedMovieThumbnailAndNoAudio() async throws {
        let url = URL.temporaryDirectory.appending(path: "cuevideo-test-\(UUID().uuidString.prefix(6)).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await CueVideoDebugSeed.makeMovie(url: url, seconds: 2)
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        XCTAssertEqual(dur, 2, accuracy: 0.05)
        let g = AVAssetImageGenerator(asset: asset)
        let img = try await g.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        XCTAssertEqual(img.width, 320)
        do {
            _ = try await CueAutoSync.videoFeatures(url: url, progress: { _ in }, isCancelled: { false })
            XCTFail("expected no audio")
        } catch let e as CueAutoSync.Failure { XCTAssertEqual(e, .noVideoAudio) }
    }

    @MainActor func testThumbnailsGenerate() async throws {
        let url = URL.temporaryDirectory.appending(path: "cuevideo-thumbs-\(UUID().uuidString.prefix(6)).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await CueVideoDebugSeed.makeMovie(url: url, seconds: 4)
        let t = CueVideoThumbnails()
        t.reset(url: url)
        let lvl = CueVideoThumbnails.ladder.firstIndex(of: 1)!
        t.want(level: lvl, indices: 0...3)
        for _ in 0..<100 where (0...3).contains(where: { t.image(.init(level: lvl, index: $0)) == nil }) { try await Task.sleep(for: .milliseconds(50)) }
        for i in 0...3 { XCTAssertNotNil(t.image(.init(level: lvl, index: i)), "thumb \(i)") }
    }

    @MainActor func testThumbnailLadderFollowsZoom() {
        // 70 pt thumbs: zoomed right in (400 pt/s) → 0.2 s apart; whole show (0.5 pt/s) → 300 s.
        XCTAssertEqual(CueVideoThumbnails.ladder[CueVideoThumbnails.level(thumbWidth: 70, pointsPerSecond: 400)], 0.2)
        XCTAssertEqual(CueVideoThumbnails.ladder[CueVideoThumbnails.level(thumbWidth: 70, pointsPerSecond: 0.5)], 300)
        let v = CueVideoThumbnails.visible(size: CGSize(width: 700, height: 44), origin: 0, span: 70, offset: 30,
                                           videoDuration: 600, aspect: 16 / 9)
        XCTAssertEqual(v?.0, CueVideoThumbnails.ladder.firstIndex(of: 10))
        XCTAssertEqual(v?.1.lowerBound, 0)
        XCTAssertEqual(v?.1.upperBound, 4)   // video 0…40 s visible
    }

    // MARK: Signals

    /// Noise bursts and clicks at irregular times, with a little background.
    private func burstTrack(seconds: Double, rng g: inout Rng) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * sr))
        for i in x.indices { x[i] = 0.01 * g.gauss() }
        var t = 0.2
        while t < seconds - 0.5 {
            let len = Int(sr * (0.02 + 0.3 * Double(g.uniform())))
            let amp = 0.2 + 0.7 * g.uniform()
            let decay = Float(1.0 / (Double(len) * 0.4))
            let s0 = Int(t * sr)
            for k in 0..<len where s0 + k < x.count {
                x[s0 + k] += amp * expf(-Float(k) * decay) * g.gauss()
            }
            t += 0.15 + Double(g.uniform()) * 0.9
        }
        return x
    }

    private struct Rng {
        var s: UInt64
        init(seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
        mutating func gauss() -> Float {
            let u = max(1e-7, uniform()), v = uniform()
            return (-2 * logf(u)).squareRoot() * cosf(2 * .pi * v)
        }
    }
}
