import AVFoundation
import Foundation
import Observation
import TCKit

/// Plays side-isolated test material through the engine so a tech can walk the system and
/// confirm patching. Reusable outside the Output Test page.
@MainActor
@Observable
final class OutputTester {
    enum Signal: Equatable {
        case ident(OutputSide)
        case sequence
        case tone(OutputSide)
        case pink(OutputSide)
        case polarity
        case ltc(OutputSide)

        var title: String {
            switch self {
            case .ident(let s): "Voice · \(OutputTester.sideName(s))"
            case .sequence: "Voice sequence"
            case .tone(let s): "1 kHz tone · \(OutputTester.sideName(s))"
            case .pink(let s): "Pink noise · \(OutputTester.sideName(s))"
            case .polarity: "Polarity · Both"
            case .ltc(let s): "LTC · \(OutputTester.sideName(s))"
            }
        }
    }

    /// One stretch of a playing file and which sides carry signal during it.
    struct Segment { var start: Double; var end: Double; var side: OutputSide }

    // MARK: State
    private(set) var voices: [VoiceOption] = []
    var selectedVoiceID: String? {
        didSet { if let v = selectedVoiceID { UserDefaults.standard.set(v, forKey: Self.voiceKey) } }
    }
    private(set) var hasRichVoice = false
    private(set) var isRendering = false
    private(set) var current: Signal?
    var errorMessage: String?
    /// Voice ident level, dBFS peak. Calibrated signals (tone, noise, clicks, LTC) ignore it.
    var voiceLevelDBFS: Float = -12 {
        didSet { UserDefaults.standard.set(voiceLevelDBFS, forKey: Self.levelKey); applyLiveLevel() }
    }
    var ltcRate: FrameRate = .fps30

    @ObservationIgnored let engine: PlaybackEngine
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var ltcConfig: GeneratorConfig?
    @ObservationIgnored private var segments: [Segment] = []
    @ObservationIgnored private var segmentsLength: Double = 0
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private let cacheDir: URL

    static let voiceKey = "outputTestVoice"
    static let levelKey = "outputTestVoiceLevel"
    /// Rendered ident files are normalised to this peak; playback gain trims to `voiceLevelDBFS`.
    static let identPeakDBFS: Float = -6
    static let ltcTestStart = Timecode(hours: 1, rate: .fps30)
    static let ltcTestSeconds: TimeInterval = 5

    init(engine: PlaybackEngine = .shared, cacheDirectory: URL = TestSignals.cacheDirectory) {
        self.engine = engine
        self.cacheDir = cacheDirectory
        if UserDefaults.standard.object(forKey: Self.levelKey) != nil {
            voiceLevelDBFS = min(0, UserDefaults.standard.float(forKey: Self.levelKey))
        }
        reloadVoices()
    }

    func reloadVoices() {
        voices = VoiceIdentRenderer.availableVoices()
        hasRichVoice = VoiceIdentRenderer.hasRichVoice(in: voices)
        let saved = UserDefaults.standard.string(forKey: Self.voiceKey)
        if let saved, voices.contains(where: { $0.id == saved }) { selectedVoiceID = saved }
        else { selectedVoiceID = VoiceIdentRenderer.bestVoiceID(in: voices) }
    }

    var selectedVoice: VoiceOption? { voices.first { $0.id == selectedVoiceID } }

    // MARK: Ownership

    /// True when the engine is running something this tester started.
    var isOurs: Bool {
        switch engine.source {
        case .file(let u): return u == currentURL && current != nil
        case .generator(let c): return c == ltcConfig && current != nil
        case .none: return false
        }
    }

    /// A show cue (anything we didn't start) is playing.
    var showCueIsPlaying: Bool { engine.transport == .playing && !isOurs && engine.source != .none }

    var isPlaying: Bool { isOurs && engine.transport == .playing }

    /// Sides carrying signal right now (drives the lamps).
    func litSides(at date: Date = Date()) -> (l: Bool, r: Bool) {
        guard isPlaying, let startedAt, !segments.isEmpty else { return (false, false) }
        var t = date.timeIntervalSince(startedAt)
        if !oneShot, segmentsLength > 0 { t = t.truncatingRemainder(dividingBy: segmentsLength) }
        guard let seg = segments.first(where: { t >= $0.start && t < $0.end }) else { return (false, false) }
        return (seg.side != .right, seg.side != .left)
    }

    // MARK: Play / stop

    func play(_ signal: Signal) async {
        stopLoop()
        errorMessage = nil
        do {
            switch signal {
            case .ident(let side):
                let (url, dur) = try await identFile(side)
                try start(signal, url: url, gainDB: identGain, segments: [Segment(start: 0, end: dur, side: side)], loop: false)
            case .sequence:
                let (url, segs, total) = try await sequenceFile()
                try start(signal, url: url, gainDB: identGain, segments: segs, loop: true, length: total)
            case .tone(let side):
                let url = try signalFile("tone-1k-18-\(side.rawValue)") {
                    TestSignals.place(TestSignals.sine(frequency: 1000, levelDBFS: -18, seconds: Self.loopSeconds), side: side)
                }
                try start(signal, url: url, gainDB: 0, segments: [Segment(start: 0, end: Self.loopSeconds, side: side)],
                          loop: true, length: Self.loopSeconds)
            case .pink(let side):
                let url = try signalFile("pink-20-\(side.rawValue)") {
                    TestSignals.place(TestSignals.pinkNoise(rmsDBFS: -20, seconds: Self.loopSeconds), side: side)
                }
                try start(signal, url: url, gainDB: 0, segments: [Segment(start: 0, end: Self.loopSeconds, side: side)],
                          loop: true, length: Self.loopSeconds)
            case .polarity:
                let url = try signalFile("polarity-6") {
                    TestSignals.place(TestSignals.polarityClicks(seconds: Self.loopSeconds), side: .both)
                }
                try start(signal, url: url, gainDB: 0, segments: [Segment(start: 0, end: Self.loopSeconds, side: .both)],
                          loop: true, length: Self.loopSeconds)
            case .ltc(let side):
                let cfg = GeneratorConfig(start: TCPad.conform(Self.ltcTestStart, to: ltcRate), rate: ltcRate,
                                          duration: Self.ltcTestSeconds, side: side, levelDBFS: -10)
                try engine.load(.generator(cfg))
                ltcConfig = cfg
                currentURL = nil
                current = signal
                segments = [Segment(start: 0, end: Self.ltcTestSeconds, side: side)]
                segmentsLength = Self.ltcTestSeconds
                startedAt = Date()
                engine.play()
                watchEnd(after: Self.ltcTestSeconds)
            }
        } catch {
            current = nil
            errorMessage = "Couldn't play the test: \(error.localizedDescription)"
        }
    }

    func stop() {
        stopLoop()
        if isOurs || current != nil { engine.stop() }
        current = nil
        currentURL = nil
        ltcConfig = nil
        segments = []
    }

    // MARK: Internals

    static let loopSeconds: Double = 20
    private var identGain: Float { min(6, voiceLevelDBFS - Self.identPeakDBFS) }

    private func routing(gainDB: Float) -> ChannelRouting { ChannelRouting(gainDB: gainDB) }

    private func applyLiveLevel() {
        guard isOurs, current == .sequence || { if case .ident = current { return true } else { return false } }() else { return }
        engine.routing.gainDB = identGain
    }

    private func start(_ signal: Signal, url: URL, gainDB: Float, segments: [Segment], loop: Bool, length: Double? = nil) throws {
        try engine.load(.file(url), routing: routing(gainDB: gainDB))
        currentURL = url
        ltcConfig = nil
        current = signal
        self.segments = segments
        segmentsLength = length ?? (segments.map(\.end).max() ?? 0)
        startedAt = Date()
        engine.play()
        if loop { startLoop(url: url, gainDB: gainDB, length: segmentsLength) } else { watchEnd(after: segmentsLength) }
    }

    /// Re-trigger a file at its end until stopped. If the engine stops early (someone pressed
    /// Stop elsewhere) or loads something else, the loop ends.
    private func startLoop(url: URL, gainDB: Float, length: Double) {
        oneShot = false
        loopTask = Task { [weak self] in
            var passStart = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.engine.source == .file(url) else { self.finish(); return }
                let elapsed = Date().timeIntervalSince(passStart)
                switch self.engine.transport {
                case .paused:
                    passStart = passStart.addingTimeInterval(0.1)
                    continue
                case .stopped where elapsed < length - 0.3:
                    self.finish(); return
                case .stopped, .playing:
                    guard elapsed >= length - 0.02 || self.engine.transport == .stopped else { continue }
                    do {
                        try self.engine.load(.file(url), routing: self.routing(gainDB: self.current == .sequence ? self.identGain : gainDB))
                        self.engine.play()
                    } catch { self.finish(); return }
                    passStart = Date()
                }
            }
        }
    }

    /// For one-shot items: clear the lamp state when the item ends.
    private func watchEnd(after seconds: Double) {
        oneShot = true
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 0.15) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // If the engine still reports a file playing past its end, stop it ourselves.
            // (The generator stops itself after its duration.)
            if self.isOurs, case .file = self.engine.source, self.engine.transport == .playing {
                self.engine.stop()
            }
            self.finish()
        }
    }

    @ObservationIgnored private var oneShot = false

    private func finish() {
        loopTask = nil
        current = nil
        segments = []
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        oneShot = false
    }

    // MARK: Files

    private func signalFile(_ name: String, make: () -> (l: [Float], r: [Float])) throws -> URL {
        let url = cacheDir.appendingPathComponent("\(name)-\(Int(Self.loopSeconds))s.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let (l, r) = make()
        try TestSignals.writeWAV(left: l, right: r, to: url)
        return url
    }

    private func identKey(_ voiceID: String) -> String {
        TestSignals.stableHash("\(voiceID)|\(VoiceIdentRenderer.renderVersion)|\(VoiceIdentRenderer.speechRate)|\(VoiceIdentRenderer.pitch)")
    }

    /// Rendered (cached) ident for a side. Returns the URL and duration in seconds.
    func identFile(_ side: OutputSide) async throws -> (URL, Double) {
        guard let voiceID = selectedVoiceID else { throw VoiceIdentRenderer.RenderError.noVoice }
        let url = cacheDir.appendingPathComponent("ident-\(side.rawValue)-\(identKey(voiceID)).wav")
        if let d = Self.duration(of: url) { return (url, d) }
        let mono = try await renderMono(side, voiceID: voiceID)
        let (l, r) = TestSignals.place(mono, side: side)
        try TestSignals.writeWAV(left: l, right: r, to: url)
        return (url, Double(mono.count) / TestSignals.sampleRate)
    }

    /// L ident, short gap, R ident, longer pause — one file, looped.
    private func sequenceFile() async throws -> (URL, [Segment], Double) {
        guard let voiceID = selectedVoiceID else { throw VoiceIdentRenderer.RenderError.noVoice }
        let key = identKey(voiceID)
        let url = cacheDir.appendingPathComponent("ident-sequence-\(key).wav")
        let metaURL = url.appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: metaURL),
           let m = try? JSONDecoder().decode([Double].self, from: data), m.count == 2 {
            return (url, Self.sequenceSegments(lDur: m[0], rDur: m[1]), Self.sequenceLength(lDur: m[0], rDur: m[1]))
        }
        let left = try await renderMono(.left, voiceID: voiceID)
        let right = try await renderMono(.right, voiceID: voiceID)
        let gap = TestSignals.silence(seconds: Self.sequenceGap)
        let tail = TestSignals.silence(seconds: Self.sequenceTail)
        let zl = [Float](repeating: 0, count: left.count), zr = [Float](repeating: 0, count: right.count)
        let lch = left + gap + zr + tail
        let rch = zl + gap + right + tail
        try TestSignals.writeWAV(left: lch, right: rch, to: url)
        let lDur = Double(left.count) / TestSignals.sampleRate, rDur = Double(right.count) / TestSignals.sampleRate
        try? JSONEncoder().encode([lDur, rDur]).write(to: metaURL)
        return (url, Self.sequenceSegments(lDur: lDur, rDur: rDur), Self.sequenceLength(lDur: lDur, rDur: rDur))
    }

    static let sequenceGap = 0.8
    static let sequenceTail = 2.0
    static func sequenceSegments(lDur: Double, rDur: Double) -> [Segment] {
        [Segment(start: 0, end: lDur, side: .left),
         Segment(start: lDur + sequenceGap, end: lDur + sequenceGap + rDur, side: .right)]
    }
    static func sequenceLength(lDur: Double, rDur: Double) -> Double { lDur + sequenceGap + rDur + sequenceTail }

    private func renderMono(_ side: OutputSide, voiceID: String) async throws -> [Float] {
        isRendering = true
        defer { isRendering = false }
        return try await VoiceIdentRenderer.renderMono(side: side, voiceID: voiceID)
    }

    static func duration(of url: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: url.path), let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// Remove cached renders (e.g. after installing a new voice).
    func clearCache() { try? FileManager.default.removeItem(at: cacheDir) }

    nonisolated static func sideName(_ s: OutputSide) -> String {
        switch s { case .left: "Left"; case .right: "Right"; case .both: "Both" }
    }
}
