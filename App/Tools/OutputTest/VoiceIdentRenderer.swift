import AVFoundation
import Foundation

/// A selectable narration voice.
struct VoiceOption: Identifiable, Hashable {
    let id: String          // AVSpeechSynthesisVoice.identifier
    let name: String
    let language: String
    let quality: AVSpeechSynthesisVoiceQuality
    let isMale: Bool

    var qualityLabel: String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }
    var regionLabel: String {
        switch language {
        case "en-GB": "UK"
        case "en-US": "US"
        case "en-AU": "Australia"
        case "en-IE": "Ireland"
        case "en-IN": "India"
        case "en-ZA": "South Africa"
        default: language
        }
    }
}

/// Picks and renders the calm, slow, low British narrator-style idents. Generic style only.
enum VoiceIdentRenderer {
    /// Bump when the script, tuning or processing changes so cached renders are rebuilt.
    static let renderVersion = "v3"

    // Delivery tuning: unhurried, low and warm.
    static let speechRate: Float = 0.42
    static let pitch: Float = 0.87

    // MARK: Voice choice

    static func availableVoices() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { !$0.identifier.contains("speech.synthesis") }   // novelty voices
            .filter { !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { VoiceOption(id: $0.identifier, name: $0.name, language: $0.language,
                               quality: $0.quality, isMale: $0.gender == .male) }
            .sorted { score($0) > score($1) || (score($0) == score($1) && $0.name < $1.name) }
    }

    /// Ranking: en-GB male Premium/Enhanced → "Daniel" → any en-GB (male first) → en-US → rest.
    static func score(_ v: VoiceOption) -> Int {
        var s = 0
        let gb = v.language == "en-GB"
        let eloquence = v.id.contains("eloquence")
        if gb { s += 1000 } else if v.language == "en-US" { s += 400 } else { s += 100 }
        if gb && v.isMale && v.quality != .default && !eloquence { s += 2000 }
        if gb && v.name == "Daniel" { s += 500 }
        if v.isMale { s += 60 }
        switch v.quality {
        case .premium: s += 40
        case .enhanced: s += 30
        default: break
        }
        if eloquence { s -= 300 }
        return s
    }

    static func bestVoiceID(in voices: [VoiceOption]) -> String? { voices.first?.id }

    /// True when an Enhanced or Premium English (UK) voice is installed.
    static func hasRichVoice(in voices: [VoiceOption]) -> Bool {
        voices.contains { $0.language == "en-GB" && $0.quality != .default && !$0.id.contains("eloquence") }
    }

    // MARK: Script

    enum Part { case say(String, rate: Float, pitch: Float), pause(Double) }

    /// "Test… one, two, three. … Left." — unhurried, with a small dramatic pause before the side.
    static func script(for side: OutputSide) -> [Part] {
        let name: String
        switch side {
        case .left: name = "Left."
        case .right: name = "Right."
        case .both: name = "Both sides."
        }
        return [
            .pause(0.15),
            .say("Test.", rate: speechRate, pitch: pitch),
            .pause(0.55),
            .say("One, two, three.", rate: speechRate, pitch: pitch),
            .pause(0.95),
            .say(name, rate: speechRate - 0.03, pitch: pitch - 0.02),
            .pause(0.25),
        ]
    }

    // MARK: Render

    enum RenderError: LocalizedError {
        case noVoice, noAudio
        var errorDescription: String? {
            switch self {
            case .noVoice: "No English voice is installed."
            case .noAudio: "The voice didn't produce any audio."
            }
        }
    }

    /// Render a side's ident as processed mono at 48 kHz, peak −6 dBFS.
    static func renderMono(side: OutputSide, voiceID: String) async throws -> [Float] {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { throw RenderError.noVoice }
        var dry: [Float] = []
        for part in script(for: side) {
            switch part {
            case .pause(let s):
                dry += TestSignals.silence(seconds: s)
            case .say(let text, let rate, let pitch):
                let seg = try await synthesize(text, voice: voice, rate: rate, pitch: pitch)
                dry += trimSilence(seg)
            }
        }
        guard TestSignals.peak(dry) > 0.001 else { throw RenderError.noAudio }
        var wet = (try? applyRoom(dry)) ?? dry
        normalize(&wet, peakDBFS: -6)
        return wet
    }

    /// Speak `text` into memory and return float mono at 48 kHz.
    static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice, rate: Float, pitch: Float) async throws -> [Float] {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.pitchMultiplier = pitch
        u.volume = 1
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0

        let collector = BufferCollector()
        let synth = AVSpeechSynthesizer()
        synth.write(u) { buffer in collector.add(buffer) }

        let started = Date()
        while true {
            try await Task.sleep(nanoseconds: 40_000_000)
            let (done, last, any) = collector.status()
            if done { break }
            if any, let last, Date().timeIntervalSince(last) > 1.2 { break }
            if Date().timeIntervalSince(started) > (any ? 20 : 6) { break }
        }
        withExtendedLifetime(synth) {}
        let (samples, sr) = collector.result()
        guard !samples.isEmpty else { throw RenderError.noAudio }
        return try resample(samples, from: sr)
    }

    /// Trim leading/trailing near-silence, keeping a short margin so consonants aren't clipped.
    static func trimSilence(_ x: [Float], threshold: Float = 0.003, margin: Double = 0.03) -> [Float] {
        guard let first = x.firstIndex(where: { abs($0) > threshold }),
              let last = x.lastIndex(where: { abs($0) > threshold }) else { return [] }
        let m = Int(margin * TestSignals.sampleRate)
        return Array(x[max(0, first - m)...min(x.count - 1, last + m)])
    }

    static func normalize(_ x: inout [Float], peakDBFS: Float) {
        let p = TestSignals.peak(x)
        guard p > 0 else { return }
        let g = TestSignals.dbToLinear(peakDBFS) / p
        for i in x.indices { x[i] *= g }
    }

    static func resample(_ x: [Float], from sr: Double) throws -> [Float] {
        if abs(sr - TestSignals.sampleRate) < 0.5 { return x }
        guard let inFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let outFmt = AVAudioFormat(standardFormatWithSampleRate: TestSignals.sampleRate, channels: 1),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(x.count)) else {
            throw RenderError.noAudio
        }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { src in inBuf.floatChannelData![0].update(from: src.baseAddress!, count: x.count) }
        let cap = AVAudioFrameCount(Double(x.count) * TestSignals.sampleRate / sr + 1024)
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

    /// Offline room + warmth: high-pass 70 Hz, low-shelf +3 dB @ 220 Hz, soft high-shelf −1.5 dB
    /// @ 9 kHz, then a medium room at 15 % wet. AVAudioEngine manual rendering, no realtime I/O.
    static func applyRoom(_ mono: [Float], tailSeconds: Double = 0.8) throws -> [Float] {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: TestSignals.sampleRate, channels: 2) else { return mono }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let hp = eq.bands[0]
        hp.filterType = .highPass; hp.frequency = 70; hp.bypass = false
        let ls = eq.bands[1]
        ls.filterType = .lowShelf; ls.frequency = 220; ls.gain = 3; ls.bypass = false
        let hs = eq.bands[2]
        hs.filterType = .highShelf; hs.frequency = 9000; hs.gain = -1.5; hs.bypass = false
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 15

        engine.attach(player); engine.attach(eq); engine.attach(reverb)
        engine.connect(player, to: eq, format: fmt)
        engine.connect(eq, to: reverb, format: fmt)
        engine.connect(reverb, to: engine.mainMixerNode, format: fmt)
        let block: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
        try engine.start()

        let total = mono.count + Int(tailSeconds * TestSignals.sampleRate)
        guard let src = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(mono.count)),
              let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block) else { return mono }
        src.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { p in
            src.floatChannelData![0].update(from: p.baseAddress!, count: mono.count)
            src.floatChannelData![1].update(from: p.baseAddress!, count: mono.count)
        }
        player.scheduleBuffer(src, at: nil)
        player.play()

        var result = [Float]()
        result.reserveCapacity(total)
        while result.count < total {
            let n = AVAudioFrameCount(min(Int(block), total - result.count))
            let status = try engine.renderOffline(n, to: out)
            guard status == .success else { break }
            let l = out.floatChannelData![0], r = out.floatChannelData![out.format.channelCount > 1 ? 1 : 0]
            for i in 0..<Int(out.frameLength) { result.append(0.5 * (l[i] + r[i])) }
        }
        player.stop(); engine.stop()
        guard TestSignals.peak(result) > 0.0005 else { return mono }
        // Fade the tail out so it ends on silence.
        let fade = min(result.count, Int(0.4 * TestSignals.sampleRate))
        for i in 0..<fade { result[result.count - 1 - i] *= Float(i) / Float(fade) }
        return result
    }
}

/// Thread-safe sink for `AVSpeechSynthesizer.write` callbacks. Converts to float mono.
private final class BufferCollector: @unchecked Sendable {
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
        let n = Int(pcm.frameLength)
        if let f = pcm.floatChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n))
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
