import Foundation
import SwiftData
import TCKit

/// First-launch demo show: two generated tracks (pad on L, LTC on R) and one generator cue.
@MainActor
enum DemoContent {
    static let seededKey = "TCPlayback.demoSeeded.v1"
    static let sampleRate: Double = 48_000
    static let length: TimeInterval = 60

    struct Spec: Sendable {
        var title: String
        var fileName: String
        var start: String
        var rate: FrameRate
        /// Semitone offset so the two demos sound different.
        var transpose: Double
    }

    static let specs: [Spec] = [
        Spec(title: "Demo — LTC 30 fps", fileName: "Demo LTC 30.wav", start: "01:00:00:00", rate: .fps30, transpose: 0),
        Spec(title: "Demo — LTC 25 fps", fileName: "Demo LTC 25.wav", start: "10:00:00:00", rate: .fps25, transpose: -3),
    ]

    /// Creates "Demo Show" the first time the app runs. Audio is generated in the background.
    @discardableResult
    static func seedIfNeeded(context: ModelContext, defaults: UserDefaults = .standard) -> Playlist? {
        guard !defaults.bool(forKey: seededKey) else { return nil }
        defaults.set(true, forKey: seededKey)

        let playlist = Playlist(name: "Demo Show", sortIndex: PlaylistEditor.nextSortIndex(context))
        context.insert(playlist)
        var pending: [(Track, Spec, URL)] = []
        for (i, spec) in specs.enumerated() {
            let url = TrackImporter.uniqueDestination(for: spec.fileName)
            let track = Track(title: spec.title, fileName: url.lastPathComponent, duration: length,
                              sampleRate: sampleRate, channelCount: 2)
            track.ltcChannel = "right"; track.ltcStart = spec.start; track.ltcRate = spec.rate.rawValue
            context.insert(track)
            let cue = Cue(position: i, number: String(i + 1), title: spec.title, kind: .track, track: track)
            context.insert(cue)
            playlist.cues.append(cue)
            pending.append((track, spec, url))
        }
        let gen = Cue(position: specs.count, number: String(specs.count + 1), title: "LTC Generator", kind: .generator)
        gen.genStart = "01:00:00:00"; gen.genRateRaw = FrameRate.fps29_97df.rawValue
        gen.genDuration = 5 * 60; gen.genSideRaw = OutputSide.right.rawValue
        context.insert(gen)
        playlist.cues.append(gen)
        PlaylistEditor.save(context)

        for (track, spec, url) in pending {
            Task.detached(priority: .utility) {
                do { try writeDemo(spec, to: url) } catch { return }
                await MainActor.run { TrackImporter.startAnalysis(for: track, context: context) }
            }
        }
        return playlist
    }

    // MARK: Synthesis

    /// Streams a 48 kHz 16-bit stereo WAV: L = soft chord pad, R = LTC. Writes to a temp file, then moves.
    nonisolated static func writeDemo(_ spec: Spec, to url: URL, seconds: TimeInterval = length) throws {
        let frames = Int(seconds * sampleRate)
        let tmp = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        defer { try? out.close() }
        try out.write(contentsOf: wavHeader(frames: frames, channels: 2, sampleRate: Int(sampleRate)))

        let start = Timecode(string: spec.start, rate: spec.rate) ?? .zero(spec.rate)
        let encoder = LTCEncoder(sampleRate: sampleRate, rate: spec.rate, start: start)
        let pad = PadSynth(sampleRate: sampleRate, transpose: spec.transpose, totalSeconds: seconds)
        let chunk = 4800
        var ltc = [Float](repeating: 0, count: chunk)
        var pcm = [Int16](repeating: 0, count: chunk * 2)
        var done = 0
        while done < frames {
            let n = min(chunk, frames - done)
            ltc.withUnsafeMutableBufferPointer { encoder.render(into: UnsafeMutableBufferPointer(rebasing: $0[0..<n])) }
            pcm.withUnsafeMutableBufferPointer { p in
                for i in 0..<n {
                    p[2 * i] = int16(pad.sample(at: done + i))
                    p[2 * i + 1] = int16(ltc[i])
                }
            }
            // WAV is little-endian, as are all Apple platforms.
            try pcm.withUnsafeBytes { try out.write(contentsOf: Data($0.prefix(n * 4))) }
            done += n
        }
        try out.close()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    nonisolated static func int16(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }

    nonisolated static func wavHeader(frames: Int, channels: Int, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataBytes = frames * channels * 2
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}

/// Gentle I–vi–IV–V pad: detuned sine pairs with a little 2nd harmonic, slow attack and release
/// per chord, root an octave down, about -14 dBFS peak.
struct PadSynth: Sendable {
    let sampleRate: Double
    let transpose: Double
    let totalSeconds: Double
    let chordSeconds = 3.75
    /// Angular frequencies (2πf) per chord: three voices then the root an octave down.
    private let omegas: [[Double]]

    init(sampleRate: Double, transpose: Double, totalSeconds: Double) {
        self.sampleRate = sampleRate; self.transpose = transpose; self.totalSeconds = totalSeconds
        // MIDI notes, C major: C, Am, F, G.
        let chords: [[Double]] = [[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]]
        func w(_ note: Double) -> Double { 2 * .pi * 440 * pow(2, (note + transpose - 69) / 12) }
        omegas = chords.map { c in c.map(w) + [w(c[0] - 12)] }
    }

    func sample(at frame: Int) -> Float {
        let t = Double(frame) / sampleRate
        let index = Int(t / chordSeconds)
        let local = t - Double(index) * chordSeconds
        let w = omegas[index % omegas.count]
        // Per-chord envelope: 0.7 s raised-cosine attack, 1.0 s release.
        let attack = min(1, local / 0.7), release = min(1, (chordSeconds - local) / 1.0)
        let env = 0.5 - 0.5 * cos(.pi * min(attack, release))
        // Whole-file fade in/out.
        let edge = min(1, t / 1.5, (totalSeconds - t) / 1.5)
        var v = 0.0
        for k in 0..<3 {
            let p = w[k] * t
            v += sin(p) + sin(p * 1.0015 + Double(k)) + 0.18 * sin(2 * p)
        }
        v += 1.2 * sin(w[3] * t)
        return Float(v / 9.0 * 0.2 * env * max(0, edge))
    }
}
