import SwiftUI
import Observation
import QuartzCore
import TCKit

// Owned by the VISUALS agent. Additive injection point so every visual can run against the
// real engine (default, no setup) or a synthetic signal for previews / the gallery.

/// Everything the visuals read. The default is a live adapter over `PlaybackEngine.shared`.
protocol VisualsDataSource: AnyObject {
    var clock: ClockStatus { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var routing: ChannelRouting { get }
    var sourceChannelCount: Int { get }
    /// Called at display rate; must be cheap.
    func snapshot() -> AnalysisSnapshot
    func resetClip()
    func seek(to time: TimeInterval)
}

/// Forwards to the shared engine. Reads go through the engine's @Observable storage, so SwiftUI
/// observation tracking works exactly as if the views read the engine directly.
final class LiveVisualsDataSource: VisualsDataSource {
    static let shared = LiveVisualsDataSource()
    private var engine: PlaybackEngine { PlaybackEngine.shared }
    var clock: ClockStatus { engine.clock }
    var currentTime: TimeInterval { engine.currentTime }
    var duration: TimeInterval { engine.duration }
    var routing: ChannelRouting { engine.routing }
    var sourceChannelCount: Int { engine.sourceChannelCount }
    func snapshot() -> AnalysisSnapshot { engine.analysisSnapshot() }
    func resetClip() { engine.resetClip() }
    func seek(to time: TimeInterval) { engine.seek(to: time) }
}

extension EnvironmentValues {
    @Entry var visualsDataSource: any VisualsDataSource = LiveVisualsDataSource.shared
}

extension View {
    /// Point every visual below at a different data source (e.g. `DemoVisualsDataSource`).
    func visualsDataSource(_ source: any VisualsDataSource) -> some View {
        environment(\.visualsDataSource, source)
    }
}

// MARK: - Demo

/// Synthesises a realistic show signal: music-like programme on one side, a proper bi-phase
/// SMPTE LTC train (−10 dBFS) on the other, and a running clock. For previews and the gallery.
@Observable
final class DemoVisualsDataSource: VisualsDataSource {
    var clock = ClockStatus()
    var currentTime: TimeInterval = 0
    var duration: TimeInterval
    var routing = ChannelRouting()
    var sourceChannelCount = 2

    /// Force a lock state (nil = locked). `.noSignal` blanks the timecode.
    var lockOverride: TCLockState?
    var rate: FrameRate
    var clockSource: ClockSource
    var discontinuities = 0
    var isReverse = false

    @ObservationIgnored private let startTime = CACurrentMediaTime()
    @ObservationIgnored private let startOffset: TimeInterval
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let synth = DemoSignalSynth()
    @ObservationIgnored private var clip = (l: false, r: false)
    @ObservationIgnored private var cached: AnalysisSnapshot?
    @ObservationIgnored private var cachedAt: CFTimeInterval = 0
    @ObservationIgnored private let ltcSide: SourceChannel

    init(rate: FrameRate = .fps30, source: ClockSource = .decoded(.right), lock: TCLockState? = nil,
         ltcSide: SourceChannel = .right, startOffset: TimeInterval = 124, duration: TimeInterval = 225) {
        self.rate = rate
        self.clockSource = source
        self.lockOverride = lock
        self.ltcSide = ltcSide
        self.startOffset = startOffset
        self.duration = duration
        tick()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private var elapsed: TimeInterval { CACurrentMediaTime() - startTime + startOffset }

    private func tick() {
        let e = elapsed
        currentTime = e.truncatingRemainder(dividingBy: duration)
        var c = ClockStatus()
        c.source = clockSource
        c.lock = lockOverride ?? (clockSource == .trackTime ? .noSignal : .locked)
        c.rate = clockSource == .trackTime ? nil : rate
        let base = Timecode(hours: 1, rate: rate).frameNumber
        switch clockSource {
        case .trackTime:
            c.timecode = Timecode(realSeconds: currentTime, rate: rate)
        default:
            c.timecode = c.lock == .noSignal ? nil : Timecode(frameNumber: base + Int(e * rate.fps), rate: rate)
        }
        if case .decoded = clockSource, c.lock != .noSignal {
            c.ltcLevelDBFS = -12.4 + Float(sin(e * 0.7)) * 0.15
        }
        if clockSource == .externalInput, c.lock != .noSignal { c.ltcLevelDBFS = -23.6 }
        c.isReverse = isReverse
        c.discontinuities = discontinuities
        if c != clock { clock = c }
    }

    func snapshot() -> AnalysisSnapshot {
        let now = CACurrentMediaTime()
        if let cached, now - cachedAt < 0.004 { return cached }
        let n = AnalysisSnapshot.scopeLength
        let end = Int64(elapsed * 48_000)
        var music = [Float](repeating: 0, count: n)
        var ltc = [Float](repeating: 0, count: n)
        synth.render(from: end - Int64(n), music: &music, ltc: &ltc, ltcActive: lockOverride != .noSignal)
        var s = AnalysisSnapshot()
        s.sampleRate = 48_000
        s.scopeL = ltcSide == .left ? ltc : music
        s.scopeR = ltcSide == .left ? music : ltc
        if sourceChannelCount == 1 { s.scopeR = [Float](repeating: 0, count: n) }

        func stats(_ a: [Float]) -> (peak: Float, rms: Float) {
            var p: Float = 0, sum: Float = 0
            for i in (n - 800)..<n { let v = abs(a[i]); p = max(p, v); sum += v * v }
            return (p, (sum / 800).squareRoot())
        }
        let sl = stats(s.scopeL), sr = stats(s.scopeR)
        s.sourcePeak = (sl.peak, sr.peak)
        s.sourceRMS = (sl.rms, sr.rms)
        var outL: (peak: Float, rms: Float) = routing.leftEnabled ? sl : (0, 0)
        var outR: (peak: Float, rms: Float) = routing.rightEnabled ? sr : (0, 0)
        if routing.swapped { swap(&outL, &outR) }
        let g = powf(10, routing.gainDB / 20)
        s.outputPeak = (min(1, outL.peak * g), min(1, outR.peak * g))
        s.outputRMS = (outL.rms * g, outR.rms * g)
        if s.outputPeak.l >= 0.999 { clip.l = true }
        if s.outputPeak.r >= 0.999 { clip.r = true }
        s.outputClip = clip
        cached = s
        cachedAt = now
        return s
    }

    func resetClip() { clip = (false, false); cached = nil }
    func seek(to time: TimeInterval) { /* demo clock free-runs */ }

    /// A plausible overview (interleaved L,R UInt8 peaks) matching the synthetic signal.
    static func demoOverview(buckets: Int = 1800, duration: TimeInterval = 225, ltcSide: SourceChannel = .right) -> Data {
        var bytes = [UInt8](repeating: 0, count: buckets * 2)
        let synth = DemoSignalSynth()
        for b in 0..<buckets {
            let t0 = Double(b) / Double(buckets) * duration
            var p: Float = 0
            for k in 0..<48 {
                let t = t0 + Double(k) * duration / Double(buckets) / 48
                p = max(p, abs(synth.music(at: Int64(t * 48_000))))
            }
            // Intro build and a quiet bridge so the overview has some shape.
            let shape = min(1, t0 / 8) * (t0 > 150 && t0 < 166 ? 0.45 : 1) * min(1, (duration - t0) / 6)
            let musicByte = UInt8(min(255, Float(shape) * p * 255))
            let ltcByte: UInt8 = t0 < 2 ? 0 : 81
            bytes[b * 2] = ltcSide == .left ? ltcByte : musicByte
            bytes[b * 2 + 1] = ltcSide == .left ? musicByte : ltcByte
        }
        return Data(bytes)
    }
}

/// Deterministic per-sample signal generator (so consecutive windows line up).
final class DemoSignalSynth {
    let sampleRate = 48_000.0
    let fps = 30.0
    private var cachedFrame = -1
    private var bits = [UInt8](repeating: 0, count: 80)
    /// Line level at the start of each bit (after the boundary transition).
    private var startLevel = [Bool](repeating: false, count: 80)

    func render(from start: Int64, music: inout [Float], ltc: inout [Float], ltcActive: Bool) {
        var y: Float = 0
        for i in 0..<music.count {
            let s = start + Int64(i)
            music[i] = self.music(at: s)
            guard ltcActive else { ltc[i] = 0; continue }
            let x = ltcSample(at: s)
            // ~25 µs (10–90 %) rise time, like a real LTC output stage.
            y = i == 0 ? x : y + (x - y) * 0.84
            ltc[i] = y + noise(s) * 0.002
        }
    }

    func music(at s: Int64) -> Float {
        let t = Double(s) / sampleRate
        let beat = (t * 2).truncatingRemainder(dividingBy: 1)       // 120 bpm
        let bar = Int(t / 2) % 4
        let roots: [Double] = [55, 43.65, 49, 41.2]
        let root = roots[bar]
        let kickEnv = exp(-beat * 14)
        let kick = sin(2 * .pi * (48 * t + 6 * exp(-beat * 30))) * kickEnv * 0.42
        let bass = sin(2 * .pi * root * t) * 0.16 * (0.6 + 0.4 * exp(-beat * 3))
        let pad = (sin(2 * .pi * root * 4 * t) + sin(2 * .pi * root * 5.04 * t) + sin(2 * .pi * root * 6 * t)) * 0.045
        let hatPhase = (t * 4).truncatingRemainder(dividingBy: 1)
        let hat = Double(noise(s)) * exp(-hatPhase * 35) * 0.16
        let swell = 0.75 + 0.25 * sin(2 * .pi * t / 16)
        var v = (kick + bass + pad + hat) * swell
        // A short hot passage every 15 s so the clip lamp gets exercised.
        if t.truncatingRemainder(dividingBy: 15) < 0.03 { v *= 3.2 }
        return Float(max(-1, min(1, v)))
    }

    private func noise(_ s: Int64) -> Float {
        var x = UInt64(bitPattern: s) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 32
        return Float(x & 0xFFFF) / 32_768 - 1
    }

    private func ltcSample(at s: Int64) -> Float {
        let spb = sampleRate / (fps * 80)              // samples per bit (20 at 30 fps)
        let pos = Double(s) / spb
        let bitIndex = Int(pos.rounded(.down))
        let frac = pos - Double(bitIndex)
        let frame = bitIndex / 80, k = bitIndex % 80
        if frame != cachedFrame { encode(frame: frame) }
        var level = startLevel[k]
        if bits[k] == 1 && frac >= 0.5 { level.toggle() }
        return level ? 0.316 : -0.316                    // −10 dBFS peak
    }

    /// SMPTE 12M 80-bit frame for 01:00:00:00 + `frame` at 30 fps NDF.
    private func encode(frame: Int) {
        cachedFrame = frame
        let tc = Timecode(frameNumber: Timecode(hours: 1, rate: .fps30).frameNumber + frame, rate: .fps30)
        var b = [UInt8](repeating: 0, count: 80)
        func put(_ value: Int, _ at: Int, _ count: Int) { for i in 0..<count { b[at + i] = UInt8((value >> i) & 1) } }
        put(tc.frames % 10, 0, 4); put(tc.frames / 10, 8, 2)
        put(tc.seconds % 10, 16, 4); put(tc.seconds / 10, 24, 3)
        put(tc.minutes % 10, 32, 4); put(tc.minutes / 10, 40, 3)
        put(tc.hours % 10, 48, 4); put(tc.hours / 10, 56, 2)
        let sync: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
        for i in 0..<16 { b[64 + i] = sync[i] }
        // Polarity-correction bit (27 at 30 fps): make the count of zeros even, so every frame
        // starts on the same polarity.
        let zeros = b.filter { $0 == 0 }.count
        if zeros % 2 == 1 { b[27] = 1 }
        bits = b
        var level = false
        for i in 0..<80 {
            level.toggle()                               // boundary transition
            startLevel[i] = level
            if b[i] == 1 { level.toggle() }              // mid-bit transition for a one
        }
    }
}
