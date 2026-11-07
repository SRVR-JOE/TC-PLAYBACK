import AVFoundation
import Foundation
import Synchronization

/// Render-thread side of the cue caller: a small, fixed pool of voices mixed into the hardware
/// output channels AFTER program routing, inside the app's single AVAudioSourceNode. Because it
/// runs in the same render callback as the program, a voice scheduled on the track clock starts on
/// the exact sample the program reaches that track frame — so "go" lands on the mark as heard,
/// whatever the output latency (both go through the same path).
///
/// Two clocks:
/// - `.track`: frames of the playing item (`RenderCore.positionFrames`). Used for this app's playback.
/// - `.render`: frames rendered since the graph started. Used when following external LTC.
///
/// Main → render handshake per voice: main owns a voice while `state == free`, fills it, then
/// publishes `armed`. The render thread moves it to `playing` and then `finished`; main reclaims
/// (`finished → free`). Cancellation never touches `state` from main: it sets `fadeNow`/`fadeAt`
/// and the render thread fades the voice out (30 ms) and finishes it.
final class CueCallMixer: @unchecked Sendable {
    enum Clock: Int, Sendable { case track = 0, render = 1 }

    struct Report: Equatable, Sendable {
        var tag: Int
        var clock: Clock
        /// Frame (in the voice's clock) of the first and last sample played; nil if never started.
        var startedAt: Int?
        var endedAt: Int?
        var startedRenderFrame: Int?
        var wasFaded: Bool
    }

    static let voiceCount = 8
    static let chunk = 4096
    let sampleRate: Double
    let fadeFrames: Int

    /// Frames rendered so far (render clock). Written by the render thread once per callback.
    let renderClock = Atomic<Int>(0)

    private let voices: UnsafeMutablePointer<Unmanaged<Voice>>
    private let owned: [Voice]
    private let scratch: UnsafeMutablePointer<Float>

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fadeFrames = max(1, Int(sampleRate * 0.03))
        let vs = (0..<Self.voiceCount).map { _ in Voice() }
        owned = vs
        voices = .allocate(capacity: Self.voiceCount)
        for (i, v) in vs.enumerated() { (voices + i).initialize(to: Unmanaged.passUnretained(v)) }
        scratch = .allocate(capacity: Self.chunk)
        scratch.initialize(repeating: 0, count: Self.chunk)
    }

    deinit {
        voices.deinitialize(count: Self.voiceCount); voices.deallocate()
        scratch.deallocate()
    }

    // MARK: Main-thread API

    /// Queue `samples` (mono) to start at `startFrame` on `clock`, on the given zero-based hardware
    /// channels at linear `gain`. Returns false when every voice is busy. `fadeAt` (same clock)
    /// starts a 30 ms fade-out there (a later call in the same area taking over).
    @discardableResult
    func play(_ samples: [Float], clock: Clock, startFrame: Int, channels: [Int], gain: Float,
              fadeAt: Int? = nil, tag: Int) -> Bool {
        reclaim()
        if !owned.contains(where: { $0.state.load(ordering: .acquiring) == Voice.free }) { reclaim(force: true) }
        guard !samples.isEmpty else { return false }
        var mask: UInt64 = 0
        for c in channels where c >= 0 && c < 64 { mask |= 1 << UInt64(c) }
        guard mask != 0, let v = owned.first(where: { $0.state.load(ordering: .acquiring) == Voice.free }) else { return false }
        v.release()
        let p = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
        samples.withUnsafeBufferPointer { p.initialize(from: $0.baseAddress!, count: samples.count) }
        v.samples = p; v.count = samples.count
        v.clock = clock.rawValue; v.startFrame = startFrame; v.mask = mask; v.gain = gain; v.tag = tag
        v.fadeNow.store(false, ordering: .relaxed)
        v.fadeAt.store(fadeAt ?? Int.max, ordering: .relaxed)
        v.startedAt.store(Int.min, ordering: .relaxed)
        v.startedRender.store(Int.min, ordering: .relaxed)
        v.endedAt.store(Int.min, ordering: .relaxed)
        v.faded.store(false, ordering: .relaxed)
        v.reported = false
        v.state.store(Voice.armed, ordering: .releasing)
        return true
    }

    /// Fade out (or drop, if not yet started) every voice; `tag` limits it to one call.
    func fadeAll(tag: Int? = nil) {
        for v in owned {
            let s = v.state.load(ordering: .acquiring)
            guard s == Voice.armed || s == Voice.playing, tag == nil || v.tag == tag else { continue }
            v.fadeNow.store(true, ordering: .releasing)
        }
    }

    /// Voices armed or playing.
    var activeCount: Int {
        owned.reduce(0) { n, v in let s = v.state.load(ordering: .acquiring); return n + (s == Voice.armed || s == Voice.playing ? 1 : 0) }
    }

    /// Reports for voices that started or finished since the last call (each voice reported
    /// once when it starts, and again when it finishes).
    func drainReports() -> [Report] {
        var out: [Report] = []
        for v in owned {
            let s = v.state.load(ordering: .acquiring)
            guard s == Voice.playing || s == Voice.finished else { continue }
            let started = v.startedAt.load(ordering: .acquiring)
            let ended = v.endedAt.load(ordering: .acquiring)
            let r = Report(tag: v.tag, clock: Clock(rawValue: v.clock) ?? .track,
                           startedAt: started == Int.min ? nil : started,
                           endedAt: ended == Int.min ? nil : ended,
                           startedRenderFrame: { let x = v.startedRender.load(ordering: .relaxed); return x == Int.min ? nil : x }(),
                           wasFaded: v.faded.load(ordering: .relaxed))
            if s == Voice.playing, !v.reportedStart, r.startedAt != nil { v.reportedStart = true; out.append(r) }
            if s == Voice.finished, !v.reported {
                v.reported = true
                if !v.reportedStart { v.reportedStart = true }
                out.append(r)
            }
        }
        return out
    }

    /// Return finished voices to the pool (frees their PCM).
    func reclaim(force: Bool = false) {
        for v in owned where v.state.load(ordering: .acquiring) == Voice.finished && (v.reported || force) {
            v.release()
            v.reportedStart = false
            v.state.store(Voice.free, ordering: .releasing)
        }
    }

    // MARK: Render (REAL-TIME THREAD)

    /// Mix active voices into `abl`. `trackStart` = track frame of the first sample of this
    /// callback; `trackRunning` = the track clock advanced during it.
    func mix(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int, trackStart: Int, trackRunning: Bool) {
        let renderStart = renderClock.load(ordering: .relaxed)
        var offset = 0
        while offset < frames {
            let n = min(Self.chunk, frames - offset)
            mixChunk(abl, offset: offset, n: n, trackStart: trackStart + offset, trackRunning: trackRunning,
                     renderStart: renderStart + offset)
            offset += n
        }
        renderClock.store(renderStart &+ frames, ordering: .releasing)
    }

    private func mixChunk(_ abl: UnsafeMutableAudioBufferListPointer, offset: Int, n: Int, trackStart: Int,
                          trackRunning: Bool, renderStart: Int) {
        let channelCount = abl.count
        let step = 1 / Float(fadeFrames)
        for vi in 0..<Self.voiceCount {
            let v = voices[vi].takeUnretainedValue()
            var st = v.state.load(ordering: .acquiring)
            guard st == Voice.armed || st == Voice.playing, let samples = v.samples else { continue }
            let isTrack = v.clock == Clock.track.rawValue
            let clockStart = isTrack ? trackStart : renderStart
            var begin = 0
            if st == Voice.armed {
                if v.fadeNow.load(ordering: .acquiring) {
                    v.state.store(Voice.finished, ordering: .releasing); continue
                }
                if isTrack && !trackRunning { continue }
                let off = v.startFrame - clockStart
                if off >= n { continue }
                begin = max(0, off)
                v.pos = 0; v.fading = false; v.fadeGain = 1
                v.startedAt.store(clockStart + begin, ordering: .relaxed)
                v.startedRender.store(renderStart + begin, ordering: .relaxed)
                v.state.store(Voice.playing, ordering: .releasing)
                st = Voice.playing
            }
            let fadeAt = v.fadeAt.load(ordering: .relaxed)
            let fadeNow = v.fadeNow.load(ordering: .relaxed)
            var i = begin
            var done = false
            let gain = v.gain
            while i < n {
                if !v.fading && (fadeNow || clockStart + i >= fadeAt) {
                    v.fading = true
                    v.faded.store(true, ordering: .relaxed)
                }
                if v.fading {
                    v.fadeGain -= step
                    if v.fadeGain <= 0 { done = true; break }
                }
                scratch[i] = samples[v.pos] * gain * v.fadeGain
                v.pos += 1
                i += 1
                if v.pos >= v.count { done = true; break }
            }
            // Sum into each of the voice's channels that exist on this output.
            var m = v.mask
            while m != 0 {
                let ch = m.trailingZeroBitCount
                m &= m - 1
                guard ch < channelCount, let out = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let o = out + offset
                var k = begin
                while k < i { o[k] += scratch[k]; k += 1 }
            }
            if done {
                v.endedAt.store(clockStart + i, ordering: .relaxed)
                v.state.store(Voice.finished, ordering: .releasing)
            }
        }
    }

    // MARK: Voice

    final class Voice: @unchecked Sendable {
        static let free = 0, armed = 1, playing = 2, finished = 3
        let state = Atomic<Int>(0)
        let fadeNow = Atomic<Bool>(false)
        let fadeAt = Atomic<Int>(Int.max)
        let startedAt = Atomic<Int>(Int.min)
        let startedRender = Atomic<Int>(Int.min)
        let endedAt = Atomic<Int>(Int.min)
        let faded = Atomic<Bool>(false)
        // Written by main while free; read by render while armed/playing.
        var samples: UnsafeMutablePointer<Float>?
        var count = 0
        var clock = 0
        var startFrame = 0
        var mask: UInt64 = 0
        var gain: Float = 1
        var tag = 0
        // Render-owned.
        var pos = 0
        var fading = false
        var fadeGain: Float = 1
        // Main-owned bookkeeping.
        var reported = false
        var reportedStart = false

        func release() {
            samples?.deallocate(); samples = nil; count = 0
        }
        deinit { samples?.deallocate() }
    }
}
