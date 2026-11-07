import XCTest
import AVFoundation
import TCKit
@testable import TCPlayback

/// Song analyser on synthetic audio built in memory (known answers), plus an optional run on a
/// real track when one is available (`SONG_ANALYSIS_WAV`, or the Macklemore set in Downloads).
final class ToolsSongAnalyzerTests: XCTestCase {

    // MARK: Synth

    /// Tiny drum machine / pad synth at a fixed rate. Deterministic noise.
    struct Synth {
        let sr: Double
        var x: [Float]
        private var seed: UInt32 = 0x1234_5678
        init(seconds: Double, sr: Double = 11_025) { self.sr = sr; x = [Float](repeating: 0, count: Int(seconds * sr)) }

        mutating func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        private func idx(_ t: Double) -> Int { Int(t * sr) }

        mutating func kick(_ t: Double, amp: Float = 0.6) {
            let a = idx(t), n = Int(0.18 * sr)
            var ph = 0.0
            for i in 0..<n where a + i < x.count {
                let tt = Double(i) / sr
                ph += 2 * .pi * (50 + 90 * exp(-tt * 30)) / sr
                x[a + i] += amp * Float(exp(-tt * 18) * sin(ph))
            }
        }
        mutating func snare(_ t: Double, amp: Float = 0.3) {
            let a = idx(t), n = Int(0.15 * sr)
            for i in 0..<n where a + i < x.count {
                let tt = Double(i) / sr
                x[a + i] += amp * Float(exp(-tt * 25)) * (noise() * 0.8 + Float(sin(2 * .pi * 190 * tt)) * 0.4)
            }
        }
        /// High noise (first difference of white noise) with a decay.
        mutating func metal(_ t: Double, amp: Float, decay: Double) {
            let a = idx(t), n = Int(min(4, decay * 5) * sr)
            var last: Float = 0
            for i in 0..<n where a + i < x.count {
                let w = noise(), hp = w - last; last = w
                x[a + i] += amp * Float(exp(-Double(i) / sr / decay)) * hp
            }
        }
        mutating func hat(_ t: Double) { metal(t, amp: 0.06, decay: 0.02) }
        mutating func crash(_ t: Double) { metal(t, amp: 0.45, decay: 0.6) }

        /// Sustained tones (Hz) from t0 to t1, with `harmonics` partials each (brightness).
        mutating func pad(_ t0: Double, _ t1: Double, freqs: [Double], amp: Float, harmonics: Int = 1) {
            for i in idx(t0)..<min(x.count, idx(t1)) {
                let tt = Double(i) / sr
                var v = 0.0
                for f in freqs { for h in 1...harmonics where f * Double(h) < sr / 2 { v += sin(2 * .pi * f * Double(h) * tt) / Double(h) } }
                x[i] += amp * Float(v / Double(freqs.count))
            }
        }
        /// Noise whose level goes from `a0` to `a1` (linear in dB) — a riser.
        mutating func riser(_ t0: Double, _ t1: Double, a0: Float, a1: Float) {
            let s = idx(t0), e = min(x.count, idx(t1))
            let d0 = 20 * log10(Double(a0)), d1 = 20 * log10(Double(a1))
            for i in s..<e {
                let f = Double(i - s) / Double(max(1, e - s))
                x[i] += Float(pow(10, (d0 + (d1 - d0) * f) / 20)) * noise()
            }
        }

        /// Kick on 1 and 3, snare on 2 and 4, 8th hats, from t0 to t1 at `bpm`, quiet bass pad.
        mutating func groove(_ t0: Double, _ t1: Double, bpm: Double = 120, kickAmp: Float = 0.6) {
            let beat = 60 / bpm
            var n = 0
            var t = t0
            while t < t1 - 1e-9 {
                if n % 2 == 0 { kick(t, amp: kickAmp) } else { snare(t) }
                hat(t); if t + beat / 2 < t1 { hat(t + beat / 2) }
                n += 1; t = t0 + Double(n) * beat
            }
        }
    }

    // MARK: Hits

    /// 64 bars at 120 BPM with crash + kick accents on known downbeats (and two off-bar stabs).
    static func accentTrack(seconds: Double = 128) -> (Synth, [Double]) {
        var s = Synth(seconds: seconds + 2)
        s.groove(1, 1 + seconds)
        s.pad(1, 1 + seconds, freqs: [110, 165], amp: 0.05)
        var accents: [Double] = []
        var bar = 4
        while 1 + Double(bar) * 2 < seconds - 2 {
            accents.append(1 + Double(bar) * 2); bar += 4
        }
        accents += [1 + 10 * 2 + 1.5, 1 + 30 * 2 + 0.5]     // syncopated stabs (beat 4, beat 2)
        accents.sort()
        for a in accents { s.crash(a); s.kick(a, amp: 0.9) }
        return (s, accents)
    }

    func testAccentHitsFoundWithin20msAtDefaultSensitivity() throws {
        let (s, accents) = Self.accentTrack()
        let r = try SongAnalyzer.analyse(samples: s.x, sampleRate: s.sr)
        let hits = r.visible(sensitivity: 0.5, kinds: [.hit])
        let found = accents.filter { a in hits.contains { abs($0.time - a) <= 0.02 } }
        let falsePositives = hits.filter { h in !accents.contains { abs(h.time - $0) <= 0.02 } }
        let recall = Double(found.count) / Double(accents.count)
        let errors = accents.compactMap { a in hits.map { $0.time - a }.min(by: { abs($0) < abs($1) }) }.filter { abs($0) < 0.1 }
        print(String(format: "HITS recall %.2f (%d/%d) false %d, mean |err| %.1f ms, max %.1f ms, shown %d, candidates %d",
                     recall, found.count, accents.count, falsePositives.count,
                     errors.map { abs($0) }.reduce(0, +) / Double(max(1, errors.count)) * 1000,
                     (errors.map { abs($0) }.max() ?? 0) * 1000, hits.count, r.moments.filter { $0.kind == .hit }.count))
        let near = accents.map { a in r.moments.filter { $0.kind == .hit && abs($0.time - a) <= 0.02 }.map(\.strength).max() ?? 0 }
        let others = r.moments.filter { h in h.kind == .hit && !accents.contains { abs(h.time - $0) <= 0.02 } }.map(\.strength).sorted()
        print("HIT strengths at accents", near.map { String(format: "%.2f", $0) }, "others top", others.suffix(8).map { String(format: "%.2f", $0) })
        XCTAssertGreaterThanOrEqual(recall, 0.9)
        XCTAssertLessThanOrEqual(falsePositives.count, max(2, accents.count / 10), "few false positives: \(falsePositives.map(\.time))")
    }

    func testHitsSnapToExistingGrid() throws {
        let (s, accents) = Self.accentTrack(seconds: 64)
        var o = SongAnalyzer.Options()
        o.grid = BeatGrid(bpm: 120, firstBeat: 1)
        let r = try SongAnalyzer.analyse(samples: s.x, sampleRate: s.sr, options: o)
        let hits = r.visible(sensitivity: 0.5, kinds: [.hit])
        for a in accents {
            guard let h = hits.min(by: { abs($0.time - a) < abs($1.time - a) }), abs(h.time - a) < 0.05 else { continue }
            XCTAssertEqual(h.time, a, accuracy: 1e-6, "on the grid")
        }
        XCTAssertNil(r.grid, "a track with a grid isn't offered a new one")
    }

    // MARK: Energy

    func testBuildIntoDropFoundWithinOneBeat() throws {
        var s = Synth(seconds: 60)
        s.groove(0.5, 16.5, kickAmp: 0.35)
        s.pad(0.5, 16.5, freqs: [220, 330], amp: 0.03)
        s.groove(16.5, 32.5, kickAmp: 0.2)                       // drums thin out under the riser
        s.riser(16.5, 32.5, a0: 0.01, a1: 0.25)
        let drop = 32.5
        s.groove(drop, 58, kickAmp: 0.9)                          // loud full band
        s.pad(drop, 58, freqs: [55, 110, 220, 440], amp: 0.35, harmonics: 4)
        s.riser(drop, 58, a0: 0.12, a1: 0.12)
        s.crash(drop)
        let r = try SongAnalyzer.analyse(samples: s.x, sampleRate: s.sr)
        let drops = r.visible(sensitivity: 0.5, kinds: [.drop])
        let builds = r.visible(sensitivity: 0.5, kinds: [.build])
        print("DROPS", drops.map { String(format: "%.2f (%.2f)", $0.time, $0.strength) },
              "BUILDS", builds.map { String(format: "%.2f (%.2f)", $0.time, $0.strength) })
        let best = try XCTUnwrap(drops.max(by: { $0.strength < $1.strength }))
        XCTAssertEqual(best.time, drop, accuracy: 0.5, "within one beat at 120 BPM")
        XCTAssertTrue(builds.contains { $0.time > 14 && $0.time < 26 }, "the riser reads as a build")
    }

    func testBreakdownIsAnEnergyFall() throws {
        var s = Synth(seconds: 50)
        s.groove(0.5, 24.5, kickAmp: 0.9)
        s.pad(0.5, 24.5, freqs: [55, 110, 220], amp: 0.3, harmonics: 4)
        s.pad(24.5, 49, freqs: [440, 660], amp: 0.04)            // quiet pad only
        s.groove(24.5, 49, kickAmp: 0.05)
        let r = try SongAnalyzer.analyse(samples: s.x, sampleRate: s.sr)
        let bd = r.visible(sensitivity: 0.5, kinds: [.breakdown])
        print("BREAKDOWNS", bd.map { String(format: "%.2f (%.2f)", $0.time, $0.strength) })
        XCTAssertTrue(bd.contains { abs($0.time - 24.5) < 1.1 })
    }

    func testSilenceGapIsAStop() throws {
        var s = Synth(seconds: 42)
        s.groove(0.5, 20.5)
        s.pad(0.5, 20.5, freqs: [110, 220], amp: 0.1)
        s.groove(22, 41)
        s.pad(22, 41, freqs: [110, 220], amp: 0.1)
        let r = try SongAnalyzer.analyse(samples: s.x, sampleRate: s.sr)
        let stops = r.visible(sensitivity: 0.5, kinds: [.stop])
        print("STOPS", stops.map { String(format: "%.3f (%.2f)", $0.time, $0.strength) })
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(try XCTUnwrap(stops.first).time, 20.5, accuracy: 0.25)
    }

    // MARK: Sections

    func testABABStructureBoundariesAndRepeatLabels() throws {
        // Eight bars each at 120 BPM (16 s): A = soft pad and light drums, B = bright chord, big drums.
        let start = 0.5, len = 16.0
        var s = Synth(seconds: start + 4 * len + 1)
        for k in 0..<4 {
            let t0 = start + Double(k) * len, t1 = t0 + len
            if k % 2 == 0 {
                s.groove(t0, t1, kickAmp: 0.4)
                s.pad(t0, t1, freqs: [261.6, 329.6, 392.0], amp: 0.12)
            } else {
                s.groove(t0, t1, kickAmp: 0.7)
                s.pad(t0, t1, freqs: [220.0, 277.2, 349.2, 110], amp: 0.2, harmonics: 6)
                s.riser(t0, t1, a0: 0.04, a1: 0.04)
            }
        }
        let r = try SongAnalyzer.analyse(samples: s.x, sampleRate: s.sr)
        let secs = r.sections
        print("SECTIONS", secs.map { String(format: "%.2f %@ %@ (%.2f)", $0.time, $0.label, $0.groupLetter ?? "-", $0.strength) },
              "BPM", r.grid?.bpm ?? 0)
        let truth = (1...3).map { start + Double($0) * len }
        let bar = 2.0
        for t in truth {
            XCTAssertTrue(secs.contains { abs($0.time - t) <= bar + 1e-6 }, "boundary near \(t)")
        }
        // The four sections, in order, by the nearest boundary to each true start.
        let starts = [start] + truth
        let groups = starts.map { t in secs.min(by: { abs($0.time - t) < abs($1.time - t) })?.group }
        XCTAssertEqual(groups[0], groups[2]); XCTAssertEqual(groups[1], groups[3]); XCTAssertNotEqual(groups[0], groups[1])
        let labels = starts.map { t in secs.min(by: { abs($0.time - t) < abs($1.time - t) })!.label }
        XCTAssertEqual(Set(labels.map { $0.split(separator: " ").first! }).count, 2)
        XCTAssertTrue(labels[1].hasPrefix("Chorus"), "the louder repeated section is the chorus guess: \(labels)")
        XCTAssertEqual(labels, ["Verse 1", "Chorus 1", "Verse 2", "Chorus 2"])
        // Sections fill a grid when the track has none.
        let g = try XCTUnwrap(r.grid)
        XCTAssertEqual(g.sections.count, secs.count)
    }

    // MARK: LTC

    /// Writes a stereo 48 kHz WAV: `programme` (at 12 kHz, upsampled by 4) on one side, LTC on the other.
    static func writeStereo(programme: [Float], ltcOnRight: Bool) throws -> URL {
        let rate = 48_000.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("song-ltc-\(UUID()).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = programme.count * 4
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let prog = buf.floatChannelData![ltcOnRight ? 0 : 1], ltc = buf.floatChannelData![ltcOnRight ? 1 : 0]
        for i in 0..<n { prog[i] = programme[i / 4] }
        let enc = LTCEncoder(sampleRate: rate, rate: .fps25, start: Timecode(hours: 1, rate: .fps25))
        enc.render(into: UnsafeMutableBufferPointer(start: ltc, count: n))
        for i in 0..<n { ltc[i] *= 0.7 }                       // hot, as LTC usually is
        try file.write(from: buf)
        return url
    }

    func testProgrammeChannelUsedAndLTCIgnored() async throws {
        // 12 kHz synth so the 48 kHz file decimates exactly back to it.
        var s = Synth(seconds: 42, sr: 12_000)
        s.groove(1, 41)
        var accents: [Double] = []
        for b in stride(from: 4, through: 16, by: 4) { let t = 1 + Double(b) * 2; accents.append(t); s.crash(t); s.kick(t, amp: 0.9) }
        for ltcRight in [true, false] {
            let url = try Self.writeStereo(programme: s.x, ltcOnRight: ltcRight)
            defer { try? FileManager.default.removeItem(at: url) }
            let r = try await SongAnalyzer.analyse(url: url, excludingChannel: ltcRight ? 1 : 0)
            let hits = r.visible(sensitivity: 0.5, kinds: [.hit])
            let found = accents.filter { a in hits.contains { abs($0.time - a) <= 0.02 } }
            print("LTC side \(ltcRight ? "R" : "L"): moments \(r.moments.count), music \(r.musicStart)–\(r.musicEnd), hit candidates",
                  r.moments.filter { $0.kind == .hit }.sorted { $0.strength > $1.strength }.prefix(8).map { String(format: "%.3f (%.2f)", $0.time, $0.strength) })
            XCTAssertGreaterThanOrEqual(found.count, accents.count - 0, "LTC on \(ltcRight ? "right" : "left"): \(hits.map(\.time))")
            XCTAssertEqual(try XCTUnwrap(r.grid).bpm, 120, accuracy: 0.5)
        }
        // Silent programme + LTC: nothing at all is suggested.
        let quiet = [Float](repeating: 0, count: 12_000 * 30)
        let url = try Self.writeStereo(programme: quiet, ltcOnRight: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try await SongAnalyzer.analyse(url: url, excludingChannel: 1)
        XCTAssertTrue(r.moments.isEmpty, "LTC must not be heard as music: \(r.moments.map { "\($0.kind) \($0.time)" })")
    }

    // MARK: Performance

    func testFiveMinuteTrackIsFast() throws {
        var s = Synth(seconds: 300)
        s.groove(0.5, 299)
        s.pad(0.5, 299, freqs: [110, 165, 220], amp: 0.08)
        for b in stride(from: 8, to: 140, by: 8) { s.crash(0.5 + Double(b) * 2) }
        let t = Date()
        let r = try SongAnalyzer.analyse(samples: s.x, sampleRate: s.sr)
        let elapsed = Date().timeIntervalSince(t)
        print(String(format: "PERF 5 min analysed in %.2f s (%d moments)", elapsed, r.moments.count))
        XCTAssertLessThan(elapsed, 3.0)
    }

    func testCancellationStopsTheAnalysis() async throws {
        let (s, _) = Self.accentTrack(seconds: 120)
        let url = try Self.writeStereo(programme: s.x, ltcOnRight: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { try await SongAnalyzer.analyse(url: url, excludingChannel: 1) }
        task.cancel()
        do { _ = try await task.value; XCTFail("should have been cancelled") } catch is CancellationError {}
    }

    // MARK: Real tracks (optional)

    /// Reports what the analyser finds on real show WAVs (LTC on the right). Runs only when a folder
    /// of WAVs is given: `TEST_RUNNER_SONG_ANALYSIS_DIR=/path xcodebuild test …`. Not an accuracy
    /// check, there is no ground truth; it prints for a human to compare with the song.
    func testRealTracksReport() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SONG_ANALYSIS_DIR"] else { throw XCTSkip("SONG_ANALYSIS_DIR not set") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".wav") }.sorted()
        guard !files.isEmpty else { throw XCTSkip("no WAVs in \(dir)") }
        for f in files {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
            let r = try await SongAnalyzer.analyse(url: url, excludingChannel: 1)
            func ts(_ t: Double) -> String { String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
            var lines = ["REAL \(f): \(String(format: "%.2f", r.duration)) s analysed in \(String(format: "%.2f", r.elapsed)) s, "
                         + "BPM \(r.grid.map { String(format: "%.2f", $0.bpm) } ?? "none") conf \(String(format: "%.2f", r.tempoConfidence ?? 0)) "
                         + "first beat \(r.grid.map { String(format: "%.3f", $0.firstBeat) } ?? "-")"]
            lines.append("  sections: " + r.sections.map { "\(ts($0.time)) \($0.label) [\($0.groupLetter ?? "-")]" }.joined(separator: ", "))
            for k in [SongMoment.Kind.drop, .build, .breakdown, .stop] {
                lines.append("  \(k.title.lowercased()): " + r.visible(sensitivity: 0.5, kinds: [k])
                    .map { "\(ts($0.time)) (\(String(format: "%.2f", $0.strength)))" }.joined(separator: ", "))
            }
            let hits = r.visible(sensitivity: 0.5, kinds: [.hit])
            lines.append("  hits shown at default: \(hits.count); top 10: " + hits.sorted { $0.strength > $1.strength }.prefix(10)
                .sorted { $0.time < $1.time }.map { "\(ts($0.time)) (\(String(format: "%.2f", $0.strength)))" }.joined(separator: ", "))
            print(lines.joined(separator: "\n"))
        }
    }

    // MARK: Filtering, acceptance, cache

    func testSensitivityShowsMoreOrFewer() throws {
        let (s, _) = Self.accentTrack(seconds: 64)
        let r = try SongAnalyzer.analyse(samples: s.x, sampleRate: s.sr)
        let few = r.visible(sensitivity: 0).count, mid = r.visible(sensitivity: 0.5).count, many = r.visible(sensitivity: 1).count
        XCTAssertLessThanOrEqual(few, mid); XCTAssertLessThanOrEqual(mid, many)
        let rejected = Set(r.visible(sensitivity: 1).prefix(2).map(\.id))
        XCTAssertEqual(r.visible(sensitivity: 1, rejected: rejected).count, many - rejected.count)
        XCTAssertTrue(r.visible(sensitivity: 1, kinds: [.stop]).allSatisfy { $0.kind == .stop })
    }

    func testAcceptingFollowsMarkRules() {
        let track = UUID()
        let lights = CuePointType(name: "Lights", colorHex: CuePointColor.blue.rawValue)
        let types = [CuePointType.defaults[0], lights]
        // Lights already has typed cue numbers 10 and 11; Cue has "Chorus 1".
        let a = CuePoint(trackID: track, time: 10, name: "Look"); a.typeID = lights.id; a.cueID = "10"
        let b = CuePoint(trackID: track, time: 20, name: "Look 2"); b.typeID = lights.id; b.cueID = "11"
        let c = CuePoint(trackID: track, time: 5, name: "Chorus 1")
        func m(_ t: Double, _ k: SongMoment.Kind, _ l: String) -> SongMoment {
            SongMoment(time: t, kind: k, strength: 1, label: l, cueTypeName: k.suggestedTypeName)
        }
        let made = MomentAcceptance.points(for: [m(15.0123, .hit, "Hit"), m(16, .hit, "Hit"), m(30, .section, "Chorus 1"),
                                                 m(40, .section, "Verse 1"), m(15.0123, .hit, "Hit")],
                                           trackID: track, existing: [a, b, c], types: types, fps: 25, duration: 100, numberRepeats: true)
        XCTAssertEqual(made.count, 4, "the same moment twice is added once")
        XCTAssertEqual(made[0].time, 15.0, accuracy: 1e-9, "frame-snapped")
        XCTAssertEqual(made[0].typeID, lights.id)
        XCTAssertEqual(made[0].cueID, "10.5", "ripple numbering between 10 and 11")
        XCTAssertEqual(made[1].cueID, "10.8")
        XCTAssertEqual(made[0].name, "Hit"); XCTAssertEqual(made[1].name, "Hit 2")
        XCTAssertNil(made[2].typeID, "sections go to the default Cue type")
        XCTAssertEqual(made[2].name, "Chorus 2", "a taken section name gets the next number")
        XCTAssertEqual(made[3].name, "Verse 1")
    }

    func testCacheRoundTripAndKeyChangesWithFile() throws {
        let (s, _) = Self.accentTrack(seconds: 20)
        let r = try SongAnalyzer.analyse(samples: s.x, sampleRate: s.sr)
        let id = UUID()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID()).bin")
        try Data(repeating: 1, count: 1000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url); SongAnalysisCache.remove(trackID: id) }
        let k1 = SongAnalysisCache.key(url: url, trackID: id, ltcChannel: 1)
        XCTAssertEqual(k1, SongAnalysisCache.key(url: url, trackID: id, ltcChannel: 1))
        XCTAssertNotEqual(k1, SongAnalysisCache.key(url: url, trackID: id, ltcChannel: 0))
        let rej = Set(r.moments.prefix(1).map(\.id))
        SongAnalysisCache.save(.init(analysis: r, rejected: rej), key: k1)
        let back = try XCTUnwrap(SongAnalysisCache.load(k1))
        XCTAssertEqual(back.analysis, r); XCTAssertEqual(back.rejected, rej)
        try Data(repeating: 2, count: 1000).write(to: url)
        XCTAssertNotEqual(SongAnalysisCache.key(url: url, trackID: id, ltcChannel: 1), k1, "new file contents, new key")
    }
}
