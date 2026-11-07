import Foundation
import Observation
import os
import QuartzCore
import Synchronization
import TCKit

/// Input Analyzer: listens to the device audio input (built-in mic, USB / Lightning interface)
/// and reports, per channel, signal level, DC offset, clip, an LTC reader (lock, timecode,
/// rate, user bits, direction, hits) and the *measured* LTC speed from its bit transitions.
/// With LTC on both channels it also shows the offset between them.
///
/// Runs alongside playback: it is an extra consumer of the input tap and never touches the
/// show clock. Also a `VisualsDataSource`, so the stock scope and meters draw the input.
@Observable
final class InputAnalyzer: VisualsDataSource {
    struct Channel: Equatable {
        var status = TimecodeReader.Status()
        var peakDBFS: Float = -.infinity
        var rmsDBFS: Float = -.infinity
        /// DC offset as a fraction of full scale.
        var dc: Float = 0
        var clipped = false
        /// Measured LTC frame rate from the bit stream (e.g. 29.9701), nil without LTC.
        var measuredFPS: Double?
        var hasSignal: Bool { peakDBFS > -60 }
        /// Speed error against the decoded rate, parts per million.
        var speedPPM: Double? {
            guard let m = measuredFPS, let r = status.rate else { return nil }
            return (m / r.fps - 1) * 1e6
        }
    }

    private(set) var left = Channel()
    private(set) var right = Channel()
    private(set) var isRunning = false
    /// L/R phase correlation over the scope window, −1…+1 (nil when either side is silent).
    private(set) var correlation: Float?

    var info: PlaybackEngine.InputInfo? { PlaybackEngine.shared.inputInfo }
    var problem: String? { PlaybackEngine.shared.inputProblem }
    var isMono: Bool { (info?.channels ?? 2) < 2 }

    /// Right minus left, in frames, when both channels are locked at the same rate.
    var offsetFrames: Int? {
        guard isLive(left.status), isLive(right.status),
              let l = left.status.timecode, let r = right.status.timecode, l.rate == r.rate else { return nil }
        return r.frameNumber - l.frameNumber
    }

    // MARK: VisualsDataSource

    var clock: ClockStatus {
        var c = ClockStatus()
        let ch: SourceChannel? = isLive(right.status) ? .right : (isLive(left.status) ? .left : nil)
        if let ch {
            let st = ch == .left ? left.status : right.status
            c.source = .decoded(ch)
            c.timecode = st.timecode; c.lock = st.state; c.rate = st.rate
            c.isReverse = st.isReverse; c.ltcLevelDBFS = st.levelDBFS; c.userBits = st.userBits
            c.discontinuities = st.discontinuities
        } else {
            c.source = .externalInput
        }
        return c
    }
    var currentTime: TimeInterval { 0 }
    var duration: TimeInterval { 0 }
    var routing: ChannelRouting { ChannelRouting() }
    var sourceChannelCount: Int { isMono ? 1 : 2 }

    func snapshot() -> AnalysisSnapshot {
        let now = CACurrentMediaTime()
        if now - lastSnapAt > 0.004 || cachedSnap == nil {
            cachedSnap = core.snapshot()
            lastSnapAt = now
        }
        return cachedSnap!
    }
    func resetClip() { core.resetClip() }
    func seek(to time: TimeInterval) {}

    // MARK: Control

    @ObservationIgnored let core = AnalyzerCore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var cachedSnap: AnalysisSnapshot?
    @ObservationIgnored private var lastSnapAt: CFTimeInterval = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        core.start()
        PlaybackEngine.shared.attachInputAnalysis(core.ring)
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.publish() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate(); timer = nil
        PlaybackEngine.shared.detachInputAnalysis()
        core.stop()
        left = Channel(); right = Channel(); correlation = nil
    }

    /// Clears hits, clip lamps and the speed measurement.
    func reset() { core.resetAll() }

    private func publish() {
        if let rate = info?.sampleRate { core.setSampleRate(rate) }
        let out = core.read()
        if left != out.l { left = out.l }
        let r = isMono ? Channel() : out.r
        if right != r { right = r }
        let snap = snapshot()
        let c = isMono ? nil : Self.correlate(snap.scopeL, snap.scopeR)
        if correlation != c { correlation = c }
    }

    private func isLive(_ s: TimecodeReader.Status) -> Bool { s.state == .locked || s.state == .freewheel }

    static func correlate(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var ab: Float = 0, aa: Float = 0, bb: Float = 0
        for i in a.indices { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        let n = Float(a.count)
        guard aa / n > 1e-7, bb / n > 1e-7 else { return nil }
        return max(-1, min(1, ab / (aa * bb).squareRoot()))
    }
}

// MARK: - Worker

/// Drains the input ring on its own thread. Main thread reads results under a lock.
final class AnalyzerCore: @unchecked Sendable {
    /// Long enough for the spectrum analyser's largest FFT.
    static let historyLength = 32_768
    let ring = SPSCRingBuffer(channels: 2, minimumCapacity: 192_000)

    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`:
    private var outL = InputAnalyzer.Channel(), outR = InputAnalyzer.Channel()
    private var peakL: Float = 0, peakR: Float = 0          // since last snapshot
    private var clipL = false, clipR = false
    private var histL: [Float], histR: [Float]
    private var histWrite = 0
    private var rate: Double = 48_000
    private var pendingRate: Double?
    private var resetRequested = false

    // Worker-only:
    private var readerL = TimecodeReader(sampleRate: 48_000), readerR = TimecodeReader(sampleRate: 48_000)
    private var speedL = LTCSpeedMeter(sampleRate: 48_000), speedR = LTCSpeedMeter(sampleRate: 48_000)
    private var levelL = LevelTracker(), levelR = LevelTracker()
    private let stopFlag = Atomic<Bool>(false)
    private let exited = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private let chunk = 1024
    private let scratchL: UnsafeMutablePointer<Float>, scratchR: UnsafeMutablePointer<Float>

    init() {
        histL = [Float](repeating: 0, count: Self.historyLength)
        histR = histL
        scratchL = .allocate(capacity: chunk); scratchL.initialize(repeating: 0, count: chunk)
        scratchR = .allocate(capacity: chunk); scratchR.initialize(repeating: 0, count: chunk)
    }

    deinit { stop(); scratchL.deallocate(); scratchR.deallocate() }

    func start() {
        guard thread == nil else { return }
        ring.consumerDiscardAll()
        stopFlag.store(false, ordering: .sequentiallyConsistent)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "TCPlayback.InputAnalyzer"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .sequentiallyConsistent)
        _ = exited.wait(timeout: .now() + 1)
        thread = nil
    }

    func setSampleRate(_ r: Double) {
        lock.withLock { if r != rate, r > 0 { pendingRate = r } }
    }

    func resetAll() { lock.withLock { resetRequested = true; clipL = false; clipR = false } }
    func resetClip() { lock.withLock { clipL = false; clipR = false } }

    func read() -> (l: InputAnalyzer.Channel, r: InputAnalyzer.Channel) {
        lock.withLock {
            var l = outL, r = outR
            l.clipped = clipL; r.clipped = clipR
            return (l, r)
        }
    }

    func snapshot() -> AnalysisSnapshot {
        var s = AnalysisSnapshot()
        let n = AnalysisSnapshot.scopeLength
        var l = [Float](repeating: 0, count: n), r = l
        lock.withLock {
            let mask = Self.historyLength - 1
            let start = histWrite &- n
            for i in 0..<n {
                let idx = (start &+ i) & mask
                l[i] = histL[idx]; r[i] = histR[idx]
            }
            s.sourcePeak = (peakL, peakR); peakL = 0; peakR = 0
            s.sourceRMS = (outL.rmsLinear, outR.rmsLinear)
            s.outputClip = (clipL, clipR)
            s.sampleRate = rate
        }
        s.outputPeak = s.sourcePeak; s.outputRMS = s.sourceRMS
        s.scopeL = l; s.scopeR = r
        return s
    }

    private func rebuild(rate r: Double) {
        readerL = TimecodeReader(sampleRate: r); readerR = TimecodeReader(sampleRate: r)
        speedL = LTCSpeedMeter(sampleRate: r); speedR = LTCSpeedMeter(sampleRate: r)
        levelL = LevelTracker(); levelR = LevelTracker()
    }

    private func loop() {
        var lastPublish = CACurrentMediaTime()
        while !stopFlag.load(ordering: .sequentiallyConsistent) {
            var newRate: Double?, doReset = false
            lock.withLock {
                if let p = pendingRate { newRate = p; rate = p; pendingRate = nil }
                if resetRequested { doReset = true; resetRequested = false }
            }
            if let r = newRate { rebuild(rate: r); ring.consumerDiscardAll() }
            if doReset {
                readerL.reset(); readerR.reset(); speedL.reset(); speedR.reset()
            }
            var didWork = false
            while true {
                let n = ring.read(scratchL, scratchR, count: chunk)
                if n == 0 { break }
                process(n); didWork = true
            }
            let now = CACurrentMediaTime()
            if now - lastPublish > 0.03 {
                lastPublish = now
                var l = InputAnalyzer.Channel(), r = InputAnalyzer.Channel()
                fill(&l, readerL.status, levelL, speedL)
                fill(&r, readerR.status, levelR, speedR)
                lock.withLock { outL = l; outR = r }
            }
            usleep(didWork ? 1_000 : 4_000)
        }
        exited.signal()
    }

    private func fill(_ c: inout InputAnalyzer.Channel, _ st: TimecodeReader.Status, _ lv: LevelTracker, _ sp: LTCSpeedMeter) {
        c.status = st
        c.peakDBFS = lv.peakHoldDBFS
        c.rmsDBFS = lv.rmsDBFS
        c.dc = lv.dc
        let live = st.state == .locked || st.state == .freewheel
        c.measuredFPS = live ? sp.bitRate.map { $0 / 80 } : nil
    }

    private func process(_ n: Int) {
        let bl = UnsafeBufferPointer(start: scratchL, count: n)
        let br = UnsafeBufferPointer(start: scratchR, count: n)
        readerL.process(bl); readerR.process(br)
        speedL.process(bl); speedR.process(br)
        levelL.process(bl); levelR.process(br)
        var pl: Float = 0, pr: Float = 0
        for i in 0..<n { pl = max(pl, abs(bl[i])); pr = max(pr, abs(br[i])) }
        lock.withLock {
            let mask = Self.historyLength - 1
            for i in 0..<n {
                let idx = (histWrite &+ i) & mask
                histL[idx] = bl[i]; histR[idx] = br[i]
            }
            histWrite &+= n
            peakL = max(peakL, pl); peakR = max(peakR, pr)
            if pl >= 0.999 { clipL = true }
            if pr >= 0.999 { clipR = true }
        }
    }
}

extension AnalyzerCore: SpectrumFeed {
    /// The newest `count` input frames (spectrum analyser worker thread). Input only.
    func spectrumRead(count: Int, shiftSeconds: Double, into b: SpectrumBuffers) -> SpectrumFeedState {
        let n = min(count, Self.historyLength, b.capacity)
        var st = SpectrumFeedState()
        lock.withLock {
            st.sampleRate = rate
            st.inputFrames = histWrite > 0 ? histWrite : nil
            guard n > 0 else { return }
            let mask = Self.historyLength - 1
            let avail = min(n, histWrite)
            let pad = n - avail
            b.inL.withUnsafeMutableBufferPointer { l in
                b.inR.withUnsafeMutableBufferPointer { r in
                    for i in 0..<pad { l[i] = 0; r[i] = 0 }
                    for i in 0..<avail {
                        let idx = (histWrite &- avail &+ i) & mask
                        l[pad + i] = histL[idx]; r[pad + i] = histR[idx]
                    }
                }
            }
        }
        return st
    }
}

extension InputAnalyzer.Channel {
    /// Linear RMS for the meter snapshot (not displayed directly).
    var rmsLinear: Float {
        get { rmsDBFS.isFinite ? powf(10, rmsDBFS / 20) : 0 }
        set { rmsDBFS = newValue > 1e-6 ? 20 * log10f(newValue) : -.infinity }
    }
}

// MARK: - Measurements

/// Peak hold (1.5 s), 300 ms RMS and DC for one channel.
struct LevelTracker {
    private(set) var rms: Float = 0
    private(set) var dc: Float = 0
    private var meanSq: Float = 0
    private var hold: Float = 0
    private var holdAge = 0
    private let holdSamples = 72_000

    var peakHoldDBFS: Float { hold > 1e-6 ? 20 * log10f(hold) : -.infinity }
    var rmsDBFS: Float { rms > 1e-6 ? 20 * log10f(rms) : -.infinity }

    mutating func process(_ s: UnsafeBufferPointer<Float>) {
        guard !s.isEmpty else { return }
        var pk: Float = 0, sum: Float = 0, sq: Float = 0
        for v in s { pk = max(pk, abs(v)); sum += v; sq += v * v }
        let n = Float(s.count)
        let k = min(1, n / 14_400) // ~300 ms at 48 kHz
        meanSq += (sq / n - meanSq) * k
        dc += (sum / n - dc) * k
        rms = max(0, meanSq - dc * dc).squareRoot()
        holdAge += s.count
        if pk >= hold || holdAge > holdSamples { hold = pk; holdAge = 0 }
    }
}

/// Measures the true bit rate of a bi-phase-mark (LTC) signal from its transitions.
/// Every bit cell starts with a transition; a 1 adds one in the middle. Intervals are either a
/// whole cell (long) or a half cell (short). Windows open and close only on cell boundaries, so
/// the cell count is exact and the speed error comes only from edge timing (a few ppm per
/// second at 48 kHz) — enough to tell 29.97 from 30, and to see a source clock drifting.
struct LTCSpeedMeter {
    let sampleRate: Double
    /// Bits per second (2400 = 30 fps); nil until a full window has been measured.
    private(set) var bitRate: Double?

    private var mid: Float = 0
    private var env: Float = 0
    private var high = false
    private var prevV: Float = 0
    private var prevAbove = false
    private var candidate: Double = 0
    private var pos: Int = 0
    private var lastEdge: Double?
    private var cell: Double = 0
    private var warm: [Double] = []
    /// true = at a cell boundary, false = mid-cell, nil = unknown.
    private var atBoundary: Bool?
    private var winStart: Double?
    private var winCells = 0.0

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    mutating func reset() {
        self = LTCSpeedMeter(sampleRate: sampleRate)
    }

    mutating func process(_ s: UnsafeBufferPointer<Float>) {
        for v in s {
            mid += (v - mid) * 0.0002
            env = max(abs(v - mid), env * 0.9997)
            let above = v > mid
            if above != prevAbove {
                // Interpolated mid-crossing; confirmed as an edge once it clears the hysteresis.
                let d = v - prevV
                let f = d != 0 ? Double((mid - prevV) / d) : 0.5
                candidate = Double(pos - 1) + min(1, max(0, f))
            }
            prevAbove = above; prevV = v
            pos += 1
            guard env > 0.004 else { lostSignal(); continue }
            let h = env * 0.35
            if !high, v > mid + h { high = true; edge(candidate) } else if high, v < mid - h { high = false; edge(candidate) }
        }
    }

    private mutating func lostSignal() {
        lastEdge = nil; atBoundary = nil; winStart = nil; winCells = 0
    }

    private mutating func edge(_ x: Double) {
        defer { lastEdge = x }
        guard let le = lastEdge else { return }
        let iv = x - le
        guard iv > 0 else { return }
        if cell == 0 {
            warm.append(iv)
            if warm.count >= 32 { cell = warm.max() ?? 0; warm.removeAll() }
            return
        }
        if iv > cell * 1.45 || iv < cell * 0.3 {
            // Not bi-phase (programme audio, dropout, speed jump): start over.
            cell = 0; atBoundary = nil; winStart = nil; winCells = 0
            return
        }
        let isLong = iv > cell * 0.75
        cell += ((isLong ? iv : iv * 2) - cell) * 0.02
        if isLong {
            if atBoundary == false { atBoundary = nil; winStart = nil; winCells = 0; return }
            atBoundary = true
        } else if let b = atBoundary {
            atBoundary = !b
        } else {
            return
        }
        guard atBoundary != nil else { return }
        if winStart == nil {
            if atBoundary == true { winStart = x; winCells = 0 }
            return
        }
        winCells += isLong ? 1 : 0.5
        guard atBoundary == true, let ws = winStart else { return }
        let elapsed = (x - ws) / sampleRate
        if elapsed >= 2 {
            let br = winCells / elapsed
            if let old = bitRate, abs(br / old - 1) < 0.002 { bitRate = old + (br - old) * 0.5 } else { bitRate = br }
            winStart = x; winCells = 0
        }
    }
}
