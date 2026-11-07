import XCTest
import AVFoundation
import TCKit
@testable import TCPlayback

final class ToolsBeatGridTests: XCTestCase {

    // MARK: Grid math

    func testBeatTimesAndBarBeat() {
        let g = BeatGrid(bpm: 120, firstBeat: 1.0)          // beat = 0.5 s, bar = 2 s
        XCTAssertEqual(g.beatLength, 0.5, accuracy: 1e-12)
        XCTAssertEqual(g.beatTime(0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(g.beatTime(5), 3.5, accuracy: 1e-12)
        XCTAssertEqual(g.beatTime(-1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(g.barTime(1), 1.0, accuracy: 1e-12)
        XCTAssertEqual(g.barTime(3), 5.0, accuracy: 1e-12)
        XCTAssertEqual(g.nearestBeat(to: 1.74), 1)
        XCTAssertEqual(g.nearestBeat(to: 1.76), 2)
        XCTAssertEqual(g.nearestBar(to: 1.9), 1)
        XCTAssertEqual(g.nearestBar(to: 2.1), 2)
        // 1-based bar.beat
        XCTAssertTrue(g.barBeat(at: 1.0) == (1, 1))
        XCTAssertTrue(g.barBeat(at: 1.49) == (1, 1))
        XCTAssertTrue(g.barBeat(at: 1.5) == (1, 2))
        XCTAssertTrue(g.barBeat(at: 2.75) == (1, 4))
        XCTAssertTrue(g.barBeat(at: 3.0) == (2, 1))
        XCTAssertTrue(g.barBeat(at: 0.6) == (0, 4), "count-in before bar 1")
        XCTAssertEqual(g.barBeatLabel(at: 5.5), "3.2")
        // A frame-rounded point on a beat still reads as that beat.
        XCTAssertTrue(g.barBeat(at: 3.0 - 1e-9) == (2, 1))
        var w = g; w.beatsPerBar = 3
        XCTAssertTrue(w.barBeat(at: 2.5) == (2, 1))
    }

    func testSnapModes() {
        var g = BeatGrid(bpm: 120, firstBeat: 0.25)
        XCTAssertEqual(g.snap(1.1, mode: .off), 1.1)
        XCTAssertEqual(g.snap(1.1, mode: .beat), 1.25, accuracy: 1e-12)
        XCTAssertEqual(g.snap(0.9, mode: .beat), 0.75, accuracy: 1e-12)
        XCTAssertEqual(g.snap(1.1, mode: .half), 1.0, accuracy: 1e-12)
        XCTAssertEqual(g.snap(1.1, mode: .quarter), 1.125, accuracy: 1e-12)
        XCTAssertEqual(g.snap(1.1, mode: .bar), 0.25, accuracy: 1e-12)
        XCTAssertEqual(g.snap(1.3, mode: .bar), 2.25, accuracy: 1e-12)
        // `snapped` follows the grid's own mode and never goes below zero.
        XCTAssertEqual(g.snapped(1.1), 1.1, "off by default")
        g.snapMode = .bar
        XCTAssertEqual(g.snapped(0.05), 0.25, accuracy: 1e-12)
        g.firstBeat = 1.9
        XCTAssertEqual(g.snapped(0.05), 0, "bar −0.1 s clamps to 0")
    }

    func testEditingKeepsMusicInPlace() {
        var g = BeatGrid(bpm: 120, firstBeat: 0.5)
        // Nudging BPM keeps the beat nearest the pivot where it was.
        let pivotBeat = g.beatTime(20)                         // 10.5 s
        g.setBPM(121, pivot: 10.4)
        XCTAssertEqual(g.bpm, 121)
        XCTAssertEqual(g.beatTime(20), pivotBeat, accuracy: 1e-9)
        // Setting a downbeat keeps bar numbering: playhead near bar 6 becomes bar 6 exactly.
        var h = BeatGrid(bpm: 120, firstBeat: 0.5)
        h.setDownbeat(at: 10.62)
        XCTAssertEqual(h.barTime(6), 10.62, accuracy: 1e-9)
        XCTAssertEqual(h.nearestBar(to: 10.62), 6)
        // Aligning a beat moves the phase by less than a beat.
        var a = BeatGrid(bpm: 100, firstBeat: 0.3)
        a.alignBeat(to: 7.0)
        XCTAssertLessThan(abs(a.firstBeat - 0.3), a.beatLength / 2 + 1e-9)
        XCTAssertEqual(a.beatTime(a.nearestBeat(to: 7.0)), 7.0, accuracy: 1e-9)
        // BPM is kept in a sane range.
        a.setBPM(1, pivot: 0); XCTAssertEqual(a.bpm, BeatGrid.bpmRange.lowerBound)
    }

    func testSectionsBreaksAndBeatValues() {
        var g = BeatGrid(bpm: 128, firstBeat: 0.2)
        g.sections = [.init(name: "Chorus", startBar: 9), .init(name: "Intro", startBar: 1), .init(name: "Pickup", startBar: -2)]
        let bar = 60.0 / 128 * 4
        XCTAssertEqual(g.sortedSections.map(\.name), ["Pickup", "Intro", "Chorus"])
        XCTAssertEqual(g.sectionBreakTimes.count, 2, "sections before the file start are dropped")
        XCTAssertEqual(g.sectionBreakTimes[0], 0.2, accuracy: 1e-9)
        XCTAssertEqual(g.sectionBreakTimes[1], 0.2 + 8 * bar, accuracy: 1e-9)
        XCTAssertEqual(g.section(at: 0.3)?.name, "Intro")
        XCTAssertEqual(g.section(at: 0.2 + 8 * bar + 0.01)?.name, "Chorus")
        // disguise counts beats from 0 s at the track BPM.
        XCTAssertEqual(g.beatValue(at: 30), 64, accuracy: 1e-9)
        XCTAssertEqual(g.musicalBeat(at: g.beatTime(7)), 7, accuracy: 1e-9)
        XCTAssertEqual(g.disguiseOptions().bpm, 128)
    }

    func testPersistenceRoundTripAndTolerantDecode() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "beatgrid-tests-\(UUID().uuidString)"))
        let id = UUID()
        XCTAssertEqual(BeatGridStore.key(id), "cuePoints.beatGrid.\(id.uuidString)")
        XCTAssertNil(BeatGridStore.load(trackID: id, defaults: d))
        var g = BeatGrid(bpm: 92.5, firstBeat: 1.234, beatsPerBar: 3, snapMode: .half, confidence: 0.8)
        g.sections = [.init(name: "Verse", startBar: 5)]
        BeatGridStore.save(g, trackID: id, defaults: d)
        XCTAssertEqual(BeatGridStore.load(trackID: id, defaults: d), g)
        BeatGridStore.save(nil, trackID: id, defaults: d)
        XCTAssertNil(BeatGridStore.load(trackID: id, defaults: d))
        // Older/smaller JSON still decodes with defaults.
        let minimal = try JSONDecoder().decode(BeatGrid.self, from: Data(#"{"bpm":100,"firstBeat":0.5}"#.utf8))
        XCTAssertEqual(minimal.beatsPerBar, 4); XCTAssertEqual(minimal.snapMode, .off); XCTAssertTrue(minimal.sections.isEmpty)
    }

    // MARK: Tap tempo

    func testTapTempo() {
        var t = TapTempo(window: 4, resetGap: 2)
        XCTAssertNil(t.tap(at: 10))
        XCTAssertEqual(t.tap(at: 10.5) ?? 0, 120, accuracy: 1e-9)
        t.tap(at: 11.0); t.tap(at: 11.5)
        XCTAssertEqual(t.bpm ?? 0, 120, accuracy: 1e-9)
        // Averages the last `window` taps only.
        t.tap(at: 12.1); t.tap(at: 12.7); t.tap(at: 13.3)
        XCTAssertEqual(t.count, 4)
        XCTAssertEqual(t.bpm ?? 0, 100, accuracy: 1e-9)
        // Jittery taps average out.
        var j = TapTempo(window: 8)
        for (i, e) in [0.0, 0.01, -0.012, 0.004, -0.006, 0.008, -0.002, 0.0].enumerated() { j.tap(at: 100 + Double(i) * 0.46875 + e) }
        XCTAssertEqual(j.bpm ?? 0, 128, accuracy: 0.5)
        // A gap longer than 2 s starts over.
        XCTAssertNil(t.tap(at: 15.6))
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.tap(at: 16.1) ?? 0, 120, accuracy: 1e-9)
        t.reset(); XCTAssertEqual(t.count, 0)
    }

    // MARK: disguise export with sections

    func testDisguiseCueTableWithSections() {
        let clock = CuePointClock(start: Timecode(hours: 1, rate: .fps30))
        var g = BeatGrid(bpm: 120, firstBeat: 0)              // bar = 2 s
        g.sections = [.init(name: "Verse", startBar: 3), .init(name: "Chorus", startBar: 6)]
        let rows = [CuePointRow(number: 1, name: "Hit", time: 4.0, colorHex: nil),
                    CuePointRow(number: 2, name: "Pyro", time: 7.0, colorHex: nil)]
        let lines = CuePointExport.disguiseCueTable(trackName: "t", rows: rows, clock: clock, grid: g).components(separatedBy: "\r\n")
        XCTAssertEqual(lines[1], "Beat\tTag\tNote\tTrack_Time\tTC_Time\tSection_Break")
        XCTAssertEqual(lines[2], "0.00000\tTC 01:00:00:00\t\t00:00:00.00\t01:00:00.00\t1")
        XCTAssertEqual(lines[3], "8.00000\tCUE 1\tHit\t00:00:04.00\t01:00:04.00\t1", "point on bar 3 starts Verse")
        XCTAssertEqual(lines[4], "14.00000\tCUE 2\tPyro\t00:00:07.00\t01:00:07.00\t0")
        XCTAssertEqual(lines[5], "20.00000\t\tChorus\t00:00:10.00\t01:00:10.00\t1", "lone section gets its own row")
        XCTAssertEqual(lines.count, 6)
        // The default exporter is unchanged by any of this.
        let plain = CuePointExport.disguiseCueTable(trackName: "t", rows: rows, clock: clock)
        XCTAssertTrue(plain.contains("4.00000\tCUE 1\tHit\t00:00:04.00\t01:00:04.00\t1"))
    }

    // MARK: Detection on synthesized audio

    /// Stereo WAV: LTC-like biphase square on `ltcSide`, clicks (accented downbeats) + noise on the other.
    private func clickTrack(bpm: Double, first: TimeInterval, seconds: TimeInterval, noise: Float, ltcSide: Int = 0,
                            sampleRate sr: Double = 48_000) throws -> URL {
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
        let n = Int(seconds * sr)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)))
        buf.frameLength = AVAudioFrameCount(n)
        let ltc = buf.floatChannelData![ltcSide], prog = buf.floatChannelData![1 - ltcSide]
        var seed: UInt32 = 0x1234_5678
        func rnd() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 23) - 1 }
        var level: Float = 0.5
        let bit = Int(sr / 2400)
        for i in 0..<n {
            if i % bit == 0 || (i % bit == bit / 2 && rnd() > 0) { level = -level }
            ltc[i] = level
            prog[i] = rnd() * noise
        }
        let beat = 60 / bpm
        let clickLen = Int(0.03 * sr)
        var t = first, k = 0
        while t < seconds {
            let s0 = Int((t * sr).rounded()), amp: Float = k % 4 == 0 ? 0.8 : 0.5
            for j in 0..<clickLen where s0 + j < n {
                let tt = Double(j) / sr
                prog[s0 + j] += amp * Float(sin(2 * .pi * 1000 * tt) * exp(-tt / 0.008))
            }
            k += 1; t = first + Double(k) * beat
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "beatgrid-\(Int(bpm))-\(UUID().uuidString).wav")
        var settings = fmt.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try f.write(from: buf)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func phaseError(_ grid: BeatGrid, trueFirst: TimeInterval, bpm: Double) -> TimeInterval {
        let beat = 60 / bpm
        var d = (grid.firstBeat - trueFirst).truncatingRemainder(dividingBy: beat)
        if d > beat / 2 { d -= beat }
        if d < -beat / 2 { d += beat }
        return abs(d)
    }

    private func assertDetects(bpm: Double, first: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async throws {
        let url = try clickTrack(bpm: bpm, first: first, seconds: 30, noise: 0.1)
        let r = try await TempoDetector.detect(url: url, excludingChannel: 0)
        print(String(format: "BeatGrid detect %.0f BPM → %.3f BPM, phase error %.2f ms, first beat %.4f s, confidence %.2f, %.3f s",
                     bpm, r.grid.bpm, phaseError(r.grid, trueFirst: first, bpm: bpm) * 1000, r.grid.firstBeat, r.confidence, r.elapsed))
        XCTAssertEqual(r.grid.bpm, bpm, accuracy: 0.5, "tempo", file: file, line: line)
        XCTAssertNotEqual(r.grid.bpm, bpm / 2, accuracy: 2, "half-tempo octave error", file: file, line: line)
        XCTAssertNotEqual(r.grid.bpm, bpm * 2, accuracy: 2, "double-tempo octave error", file: file, line: line)
        XCTAssertLessThan(phaseError(r.grid, trueFirst: first, bpm: bpm), 0.020, "phase", file: file, line: line)
        // Accented clicks mark the downbeat; bar 1 should land on the first one.
        XCTAssertEqual(r.grid.firstBeat, first, accuracy: 0.020, "downbeat", file: file, line: line)
        XCTAssertGreaterThan(r.confidence, 0.3, file: file, line: line)
    }

    func testDetects128() async throws { try await assertDetects(bpm: 128, first: 0.37) }
    func testDetects92() async throws { try await assertDetects(bpm: 92, first: 1.234) }

    func testDetectsOnRightLTCAndIgnoresIt() async throws {
        let url = try clickTrack(bpm: 110, first: 0.6, seconds: 20, noise: 0.05, ltcSide: 1)
        let r = try await TempoDetector.detect(url: url, excludingChannel: 1)
        XCTAssertEqual(r.grid.bpm, 110, accuracy: 0.5)
        XCTAssertLessThan(phaseError(r.grid, trueFirst: 0.6, bpm: 110), 0.020)
    }

    func testFiveMinuteTrackTimingAndCancel() async throws {
        let url = try clickTrack(bpm: 128, first: 0.37, seconds: 300, noise: 0.1)
        let r = try await TempoDetector.detect(url: url, excludingChannel: 0)
        print(String(format: "BeatGrid detect 5-minute track: %.3f s (%.3f BPM, phase error %.2f ms)",
                     r.elapsed, r.grid.bpm, phaseError(r.grid, trueFirst: 0.37, bpm: 128) * 1000))
        XCTAssertEqual(r.grid.bpm, 128, accuracy: 0.05)
        XCTAssertLessThan(phaseError(r.grid, trueFirst: 0.37, bpm: 128), 0.010)
        XCTAssertLessThan(r.elapsed, 15, "debug build on the simulator; release on device is much faster")

        // Cancelling the caller stops the analysis.
        let task = Task { try await TempoDetector.detect(url: url, excludingChannel: 0) }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    func testSilenceFailsCleanly() throws {
        let silent = [Float](repeating: 0, count: 11_025 * 10)
        XCTAssertThrowsError(try TempoDetector.analyse(samples: silent, sampleRate: 11_025))
        XCTAssertThrowsError(try TempoDetector.analyse(samples: [Float](repeating: 0, count: 100), sampleRate: 11_025))
    }
}
