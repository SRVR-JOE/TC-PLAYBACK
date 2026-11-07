import AVFoundation
import Foundation

/// An installed system voice the operator can pick for an area.
struct CueCallVoice: Identifiable, Hashable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard = 0, enhanced = 1, premium = 2
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self { case .standard: "Standard"; case .enhanced: "Enhanced"; case .premium: "Premium" }
        }
    }
    let id: String          // AVSpeechSynthesisVoice.identifier
    let name: String
    let language: String    // the voice's own tag ("es-MX")
    let quality: Quality
    var qualityLabel: String { quality.label }
    /// "Paulina · Spanish (Mexico) · Enhanced"
    var displayName: String { "\(name) · \(CueCallLanguage.label(language)) · \(quality.label)" }
}

/// Rendered call audio.
struct CueCallAudio: Sendable {
    var samples: [Float]
    var sampleRate: Double
    /// Seconds from the start to the go word, when rendered with `renderCall`.
    var goOnset: TimeInterval?
    var duration: TimeInterval { Double(samples.count) / sampleRate }
}

/// Speaks calls offline with AVSpeechSynthesizer into memory (never to a speaker), trims the
/// silence the synthesizer leaves around speech, and levels every call the same way so comms
/// hear a consistent voice: about −16 LUFS, peaks held under −1.5 dBFS.
final class SpeechCueCallRenderer: CueCallVoiceRenderer, @unchecked Sendable {
    static let shared = SpeechCueCallRenderer()

    var targetLUFS: Double = -16
    var peakCeilingDBFS: Float = -1.5
    /// Pause between the note and the go word in `renderCall`.
    var goGap: TimeInterval = 0.18

    enum RenderError: LocalizedError {
        case noVoice(String), noAudio
        var errorDescription: String? {
            switch self {
            case .noVoice(let l): "No voice is installed for \(CueCallLanguage.label(l))."
            case .noAudio: "The voice didn't produce any audio."
            }
        }
    }

    private let gate = SynthGate()
    private let cacheLock = NSLock()
    private var cache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 96

    init() {}

    // MARK: Voices

    /// Installed voices for a language, best first: exact region before other regions,
    /// then Premium > Enhanced > Standard. Novelty and Personal Voice are left out.
    static func voices(for language: String) -> [CueCallVoice] {
        rank(AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .filter { !$0.identifier.contains("speech.synthesis") }
            .map { CueCallVoice(id: $0.identifier, name: $0.name, language: $0.language, quality: quality($0.quality)) },
             for: language)
    }

    /// Ranking used by `voices(for:)`; separate so it can be tested without installed voices.
    static func rank(_ all: [CueCallVoice], for language: String) -> [CueCallVoice] {
        let key = CueCallLanguage.key(language)
        let tag = language.replacingOccurrences(of: "_", with: "-").lowercased()
        func score(_ v: CueCallVoice) -> Int {
            var s = v.quality.rawValue * 100
            if v.language.lowercased() == tag { s += 1000 }
            if v.id.contains("eloquence") { s -= 150 }
            return s
        }
        return all.filter { CueCallLanguage.key($0.language) == key }
            .sorted { score($0) != score($1) ? score($0) > score($1) : $0.name < $1.name }
    }

    static func bestVoice(for language: String) -> CueCallVoice? { voices(for: language).first }

    /// Every language that has at least one installed voice, as voice tags.
    static var languagesWithVoices: Set<String> {
        Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))
    }

    private static func quality(_ q: AVSpeechSynthesisVoiceQuality) -> CueCallVoice.Quality {
        switch q { case .premium: .premium; case .enhanced: .enhanced; default: .standard }
    }

    static func resolveVoice(language: String, voiceID: String?) -> AVSpeechSynthesisVoice? {
        if let voiceID, let v = AVSpeechSynthesisVoice(identifier: voiceID) { return v }
        if let best = bestVoice(for: language), let v = AVSpeechSynthesisVoice(identifier: best.id) { return v }
        return AVSpeechSynthesisVoice(language: language)
    }

    // MARK: CueCallVoiceRenderer

    /// Speak `text` (already in the area's language) to levelled mono float PCM at `sampleRate`.
    /// Leading and trailing silence are trimmed: the last sample is the end of the last word.
    func render(_ text: String, language: String, voiceID: String?, rate: Float, sampleRate: Double) async throws -> [Float] {
        var x = try await dry(text, language: language, voiceID: voiceID, rate: rate, sampleRate: sampleRate)
        CueCallLoudness.level(&x, sampleRate: sampleRate, targetLUFS: targetLUFS, ceilingDBFS: peakCeilingDBFS)
        return x
    }

    /// A go call with the go word rendered on its own, so its onset is known exactly.
    /// `lead` is the note part ("Camera 3, push in…"), `goWord` the last word ("go").
    func renderCall(lead: String, goWord: String, language: String, voiceID: String?, rate: Float, sampleRate: Double) async throws -> CueCallAudio {
        let l = lead.trimmingCharacters(in: .whitespaces)
        let g = goWord.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else {
            let s = try await render(l, language: language, voiceID: voiceID, rate: rate, sampleRate: sampleRate)
            return CueCallAudio(samples: s, sampleRate: sampleRate, goOnset: nil)
        }
        let goPart = try await dry(g, language: language, voiceID: voiceID, rate: rate, sampleRate: sampleRate)
        var x: [Float] = []
        if !l.isEmpty {
            x = try await dry(l, language: language, voiceID: voiceID, rate: rate, sampleRate: sampleRate)
            x += [Float](repeating: 0, count: Int(goGap * sampleRate))
        }
        let onset = Double(x.count) / sampleRate
        x += goPart
        CueCallLoudness.level(&x, sampleRate: sampleRate, targetLUFS: targetLUFS, ceilingDBFS: peakCeilingDBFS)
        return CueCallAudio(samples: x, sampleRate: sampleRate, goOnset: onset)
    }

    /// Convenience: render a template's go call split at its go word.
    func renderGo(note: String, template: CueCallTemplate, language: String, voiceID: String?, rate: Float, sampleRate: Double) async throws -> CueCallAudio {
        let parts = template.goParts(note)
        return try await renderCall(lead: parts.lead, goWord: parts.goWord, language: language,
                                    voiceID: voiceID, rate: rate, sampleRate: sampleRate)
    }

    func clearCache() {
        cacheLock.lock(); cache = [:]; cacheOrder = []; cacheLock.unlock()
    }

    // MARK: Synthesis

    /// Trimmed, resampled, not yet levelled.
    private func dry(_ text: String, language: String, voiceID: String?, rate: Float, sampleRate: Double) async throws -> [Float] {
        guard let voice = Self.resolveVoice(language: language, voiceID: voiceID) else { throw RenderError.noVoice(language) }
        let spoken = CueCallLexicon.speakable(text, language: voice.language)
        let r = min(max(rate, 0.3), 0.65)
        let key = "\(voice.identifier)|\(r)|\(Int(sampleRate))|\(spoken)"
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        await gate.acquire()
        let raw: (samples: [Float], rate: Double)
        do { raw = try await Self.synthesize(spoken, voice: voice, rate: r) } catch { await gate.release(); throw error }
        await gate.release()

        let trimmed = Self.trimSilence(raw.samples, sampleRate: raw.rate)
        guard !trimmed.isEmpty else { throw RenderError.noAudio }
        var out = try Self.resample(trimmed, from: raw.rate, to: sampleRate)
        Self.fadeEdges(&out, sampleRate: sampleRate)

        cacheLock.lock()
        cache[key] = out
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        cacheLock.unlock()
        return out
    }

    /// AVSpeechSynthesizer.write into memory. Returns float mono at the synthesizer's rate.
    static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice, rate: Float) async throws -> (samples: [Float], rate: Double) {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.pitchMultiplier = 1
        u.volume = 1
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        u.prefersAssistiveTechnologySettings = false

        let collector = PCMCollector()
        let synth = AVSpeechSynthesizer()
        synth.write(u) { buffer in collector.add(buffer) }

        let started = Date()
        while true {
            try await Task.sleep(nanoseconds: 30_000_000)
            let s = collector.status()
            if s.done { break }
            if s.any, let last = s.last, Date().timeIntervalSince(last) > 1.0 { break }
            if Date().timeIntervalSince(started) > (s.any ? 20 : 6) { break }
        }
        withExtendedLifetime(synth) {}
        let (samples, sr) = collector.result()
        guard !samples.isEmpty, samples.contains(where: { abs($0) > 1e-4 }) else { throw RenderError.noAudio }
        return (samples, sr)
    }

    // MARK: DSP

    /// Cut leading/trailing silence: anything 45 dB under the peak. Keeps 8 ms before the
    /// first sound and 20 ms after the last so plosives and releases survive.
    static func trimSilence(_ x: [Float], sampleRate: Double, belowPeakDB: Float = 45,
                            lead: Double = 0.008, tail: Double = 0.020) -> [Float] {
        guard let r = trimBounds(x, sampleRate: sampleRate, belowPeakDB: belowPeakDB, lead: lead, tail: tail) else { return [] }
        return Array(x[r])
    }

    /// The range `trimSilence` keeps (nil = nothing audible). Renderers that know where a word
    /// starts use `lowerBound` to correct its onset for the trimmed lead-in.
    static func trimBounds(_ x: [Float], sampleRate: Double, belowPeakDB: Float = 45,
                           lead: Double = 0.008, tail: Double = 0.020) -> ClosedRange<Int>? {
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return nil }
        let thr = max(peak * powf(10, -belowPeakDB / 20), 1e-4)
        guard let first = x.firstIndex(where: { abs($0) > thr }),
              let last = x.lastIndex(where: { abs($0) > thr }) else { return nil }
        let a = max(0, first - Int(lead * sampleRate))
        let b = min(x.count - 1, last + Int(tail * sampleRate))
        return a...b
    }

    /// 3 ms fade in, 6 ms fade out, so trimmed edges don't click.
    static func fadeEdges(_ x: inout [Float], sampleRate: Double) {
        let fi = min(x.count / 2, Int(0.003 * sampleRate)), fo = min(x.count / 2, Int(0.006 * sampleRate))
        if fi > 0 { for i in 0..<fi { x[i] *= Float(i) / Float(fi) } }
        if fo > 0 { for i in 0..<fo { x[x.count - 1 - i] *= Float(i) / Float(fo) } }
    }

    static func resample(_ x: [Float], from sr: Double, to target: Double) throws -> [Float] {
        if abs(sr - target) < 0.5 || x.isEmpty { return x }
        guard let inFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let outFmt = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(x.count)) else {
            throw RenderError.noAudio
        }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { src in inBuf.floatChannelData![0].update(from: src.baseAddress!, count: x.count) }
        let cap = AVAudioFrameCount(Double(x.count) * target / sr + 2048)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { throw RenderError.noAudio }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error { throw err ?? RenderError.noAudio }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}

// MARK: - Loudness

/// ITU-R BS.1770 integrated loudness (K-weighted, gated) for mono, plus a look-ahead peak
/// limiter, so every call sits at the same level on comms.
enum CueCallLoudness {
    /// Integrated loudness in LUFS. Signals shorter than one 400 ms block are measured whole.
    static func integrated(_ x: [Float], sampleRate: Double) -> Double {
        guard !x.isEmpty else { return -.infinity }
        let k = kWeighted(x, sampleRate: sampleRate)
        let block = Int(0.4 * sampleRate), hop = Int(0.1 * sampleRate)
        func lufs(_ ms: Double) -> Double { -0.691 + 10 * log10(max(ms, 1e-20)) }
        guard k.count >= block else {
            return lufs(k.reduce(0) { $0 + Double($1) * Double($1) } / Double(k.count))
        }
        var powers: [Double] = []
        var start = 0
        while start + block <= k.count {
            var s = 0.0
            for i in start..<(start + block) { s += Double(k[i]) * Double(k[i]) }
            powers.append(s / Double(block))
            start += hop
        }
        let abs = powers.filter { lufs($0) > -70 }
        guard !abs.isEmpty else { return -.infinity }
        let relGate = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let rel = abs.filter { lufs($0) > relGate }
        guard !rel.isEmpty else { return -.infinity }
        return lufs(rel.reduce(0, +) / Double(rel.count))
    }

    /// K-weighting: high shelf +4 dB at 1.5 kHz, then high-pass at 38 Hz.
    static func kWeighted(_ x: [Float], sampleRate fs: Double) -> [Float] {
        // Pre-filter coefficients derived for any rate (libebur128 form); at 48 kHz they
        // equal the BS.1770 table exactly.
        let shelf: [Double] = {
            let g = 3.999843853973347, f = 1681.974450955533, q = 0.7071752369554196
            let k = tan(Double.pi * f / fs), vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            return [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                    2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        }()
        let hp: [Double] = {
            let f = 38.13547087602444, q = 0.5003270373238773
            let k = tan(Double.pi * f / fs), a0 = 1 + k / q + k * k
            return [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        }()
        return biquad(biquad(x, shelf), hp)
    }

    private static func biquad(_ x: [Float], _ k: [Double]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let x0 = Double(x[i])
            let y0 = k[0] * x0 + k[1] * x1 + k[2] * x2 - k[3] * y1 - k[4] * y2
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            y[i] = Float(y0)
        }
        return y
    }

    /// Gain to `targetLUFS`, then hold peaks under `ceilingDBFS` with a 1.5 ms look-ahead limiter.
    static func level(_ x: inout [Float], sampleRate: Double, targetLUFS: Double, ceilingDBFS: Float) {
        let l = integrated(x, sampleRate: sampleRate)
        guard l.isFinite else { return }
        let g = Float(pow(10, (targetLUFS - l) / 20))
        for i in x.indices { x[i] *= g }
        limit(&x, sampleRate: sampleRate, ceilingDBFS: ceilingDBFS)
    }

    static func limit(_ x: inout [Float], sampleRate: Double, ceilingDBFS: Float, lookahead: Double = 0.0015, release: Double = 0.08) {
        let c = powf(10, ceilingDBFS / 20)
        guard x.contains(where: { abs($0) > c }) else { return }
        let n = x.count, la = max(1, Int(lookahead * sampleRate))
        var need = [Float](repeating: 1, count: n)
        for i in 0..<n { let a = abs(x[i]); if a > c { need[i] = c / a } }
        // Gain envelope: ramp down over the look-ahead before each peak, recover slowly after.
        var env = need
        for i in stride(from: n - 2, through: 0, by: -1) { env[i] = min(env[i], env[i + 1] + 1 / Float(la)) }
        let rel = 1 / Float(release * sampleRate)
        for i in 1..<n { env[i] = min(env[i], env[i - 1] + rel) }
        for i in 0..<n { x[i] = max(-c, min(c, x[i] * env[i])) }
    }
}

// MARK: - Plumbing

/// One synthesizer at a time; AVSpeechSynthesizer.write doesn't like company.
private actor SynthGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Thread-safe sink for `AVSpeechSynthesizer.write` callbacks. Converts to float mono.
private final class PCMCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 22_050
    private var done = false
    private var lastAt: Date?

    func add(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.lock(); defer { lock.unlock() }
        if pcm.frameLength == 0 { done = true; return }
        sampleRate = pcm.format.sampleRate
        let n = Int(pcm.frameLength), ch = Int(pcm.format.channelCount)
        if let f = pcm.floatChannelData {
            if ch == 1 { samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n)) }
            else { for k in 0..<n { var s: Float = 0; for c in 0..<ch { s += f[c][k] }; samples.append(s / Float(ch)) } }
        } else if let i16 = pcm.int16ChannelData {
            let p = i16[0]
            for k in 0..<n { samples.append(Float(p[k]) / 32768) }
        } else if let i32 = pcm.int32ChannelData {
            let p = i32[0]
            for k in 0..<n { samples.append(Float(p[k]) / 2_147_483_648) }
        }
        lastAt = Date()
    }

    func status() -> (done: Bool, last: Date?, any: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (done, lastAt, !samples.isEmpty)
    }

    func result() -> ([Float], Double) {
        lock.lock(); defer { lock.unlock() }
        return (samples, sampleRate)
    }
}
