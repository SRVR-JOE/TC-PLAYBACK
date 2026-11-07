import Accelerate
import AVFoundation
import Foundation
import Observation
import os
import QuartzCore
import Synchronization
import TCKit

/// Scope page, output side: analyses what the engine is actually sending to the output device
/// (the post-mix tap: after routing, gain and the master fade) and lines it up against the
/// device input in host time, to measure the round trip when the input is a loop back.
///
/// Never starts playback or builds an audio graph itself: it only switches the engine's output
/// tap on and adds a host-timed input consumer while `start()`ed.
/// Also a `VisualsDataSource`, so the stock scope and meters can draw the output.
@Observable
final class ScopeAnalyzer: VisualsDataSource {
    struct Latency: Equatable {
        var ms: Double
        var samples: Double
        var confidence: Float
        var inverted: Bool
    }

    struct Session: Equatable {
        var routeName = "—"
        var sampleRate: Double = 0
        var ioBuffer: TimeInterval = 0
        var outputLatency: TimeInterval = 0
        var inputLatency: TimeInterval = 0
    }

    private(set) var left = InputAnalyzer.Channel()
    private(set) var right = InputAnalyzer.Channel()
    private(set) var latency: Latency?
    /// True when the input and output run at different sample rates (no latency measurement).
    private(set) var rateMismatch = false
    private(set) var session = Session()
    private(set) var hasTap = false
    private(set) var isRunning = false

    /// Which output channel(s) carry LTC, read back from the post-mix audio.
    var ltcChannels: (left: Bool, right: Bool) { (isLive(left.status), isLive(right.status)) }

    // MARK: VisualsDataSource (the output)

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
            c.source = .trackTime
        }
        return c
    }
    var currentTime: TimeInterval { 0 }
    var duration: TimeInterval { 0 }
    var routing: ChannelRouting { ChannelRouting() }
    var sourceChannelCount: Int { 2 }

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

    /// Output and input over the same span of host time, for the overlay trace. With
    /// `alignByLatency` the output is taken one measured round trip earlier, so a loop back
    /// lands on top of what was sent.
    func alignedWindow(count: Int, alignByLatency: Bool) -> ScopeCore.Aligned? {
        core.aligned(count: count, shiftSeconds: alignByLatency ? (latency.map { $0.ms / 1000 } ?? 0) : 0)
    }

    // MARK: Control

    @ObservationIgnored let core = ScopeCore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var cachedSnap: AnalysisSnapshot?
    @ObservationIgnored private var lastSnapAt: CFTimeInterval = 0
    @ObservationIgnored private var lastSessionAt: CFTimeInterval = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let engine = PlaybackEngine.shared
        engine.setOutputAnalysis(true)
        core.start()
        engine.attachInputCompare(core.inputRing, clock: core.inputClock)
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.publish() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        publish()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate(); timer = nil
        let engine = PlaybackEngine.shared
        engine.detachInputCompare()
        engine.setOutputAnalysis(false)
        core.stop()
        core.setOutput(nil)
        left = InputAnalyzer.Channel(); right = InputAnalyzer.Channel()
        latency = nil; hasTap = false
    }

    /// Clears hits, clip lamps, peaks, the speed measurement and the latency estimate.
    func reset() {
        core.resetAll()
        latency = nil
    }

    private func publish() {
        let engine = PlaybackEngine.shared
        let tap = engine.outputTap
        core.setOutput(tap)
        if hasTap != (tap != nil) { hasTap = tap != nil }
        let out = core.read()
        if left != out.l { left = out.l }
        if right != out.r { right = out.r }
        let lat = out.latency.map { r -> Latency in
            Latency(ms: r.lagSamples / out.sampleRate * 1000, samples: r.lagSamples, confidence: r.confidence, inverted: r.inverted)
        }
        if latency != lat { latency = lat }
        if rateMismatch != out.rateMismatch { rateMismatch = out.rateMismatch }

        let now = CACurrentMediaTime()
        if now - lastSessionAt > 0.5 {
            lastSessionAt = now
            let s = AVAudioSession.sharedInstance()
            let outs = s.currentRoute.outputs.map(\.portName)
            var info = Session()
            info.routeName = outs.isEmpty ? engine.outputRouteName : outs.joined(separator: " + ")
            info.sampleRate = s.sampleRate
            info.ioBuffer = s.ioBufferDuration
            info.outputLatency = s.outputLatency
            info.inputLatency = s.inputLatency
            if session != info { session = info }
        }
    }

    private func isLive(_ s: TimecodeReader.Status) -> Bool { s.state == .locked || s.state == .freewheel }
}

// MARK: - Worker

/// Drains the engine's post-mix output tap and a host-timed copy of the input on its own
/// thread: per-channel LTC read / speed / level for the output, long histories of both, and a
/// cross-correlation latency estimate twice a second. Main thread reads under a lock.
final class ScopeCore: @unchecked Sendable {
    struct Aligned {
        var outL: [Float], outR: [Float], inL: [Float], inR: [Float]
        var sampleRate: Double
        var hasOutput: Bool, hasInput: Bool
    }

    struct Output {
        var l = InputAnalyzer.Channel(), r = InputAnalyzer.Channel()
        var latency: LatencyEstimator.Result?
        var sampleRate: Double = 48_000
        var rateMismatch = false
    }

    /// Long history per stream (power of two). ~2.7 s at 48 kHz.
    static let historyLength = 131_072
    /// Correlation window and the longest round trip searched for.
    static let windowSeconds = 0.2
    static let maxLagSeconds = 0.5

    let inputRing = SPSCRingBuffer(channels: 2, minimumCapacity: 192_000)
    let inputClock = TapClock()

    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`:
    private var outRing: SPSCRingBuffer?
    private var outClock: TapClock?
    private var outRate: Double = 48_000
    private var outChanged = false
    private var result = Output()
    private var peakL: Float = 0, peakR: Float = 0
    private var clipL = false, clipR = false
    private var oL: [Float], oR: [Float], iL: [Float], iR: [Float]
    /// Absolute ring index of the next sample to be stored (= frames consumed so far).
    private var outCount = 0, inCount = 0
    private var outStored = 0, inStored = 0
    private var resetRequested = false

    // Worker-only:
    private var readerL = TimecodeReader(sampleRate: 48_000), readerR = TimecodeReader(sampleRate: 48_000)
    private var speedL = LTCSpeedMeter(sampleRate: 48_000), speedR = LTCSpeedMeter(sampleRate: 48_000)
    private var levelL = LevelTracker(), levelR = LevelTracker()
    private var workerRing: SPSCRingBuffer?
    private var recent: [LatencyEstimator.Result] = []
    private let stopFlag = Atomic<Bool>(false)
    private let exited = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private let chunk = 1024
    private let scratchL: UnsafeMutablePointer<Float>, scratchR: UnsafeMutablePointer<Float>

    init() {
        oL = [Float](repeating: 0, count: Self.historyLength)
        oR = oL; iL = oL; iR = oL
        scratchL = .allocate(capacity: chunk); scratchL.initialize(repeating: 0, count: chunk)
        scratchR = .allocate(capacity: chunk); scratchR.initialize(repeating: 0, count: chunk)
    }

    deinit { stop(); scratchL.deallocate(); scratchR.deallocate() }

    func start() {
        guard thread == nil else { return }
        inputRing.consumerDiscardAll()
        lock.withLock { inCount = inputRing.totalRead; inStored = 0; outChanged = true }
        stopFlag.store(false, ordering: .sequentiallyConsistent)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "TCPlayback.Scope"
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

    /// Main thread: the current output tap (or nil). A new graph means a new ring.
    func setOutput(_ tap: OutputTapHandle?) {
        lock.withLock {
            if tap?.ring !== outRing {
                outRing = tap?.ring; outClock = tap?.clock
                outRate = tap?.sampleRate ?? outRate
                outChanged = true
            }
        }
    }

    func resetAll() {
        lock.withLock { resetRequested = true; clipL = false; clipR = false; result.latency = nil }
    }
    func resetClip() { lock.withLock { clipL = false; clipR = false } }

    func read() -> Output {
        lock.withLock {
            var o = result
            o.l.clipped = clipL; o.r.clipped = clipR
            return o
        }
    }

    func snapshot() -> AnalysisSnapshot {
        var s = AnalysisSnapshot()
        let n = AnalysisSnapshot.scopeLength
        var l = [Float](repeating: 0, count: n), r = l
        lock.withLock {
            copy(oL, oR, end: outCount, stored: outStored, count: n, into: &l, &r)
            s.sourcePeak = (peakL, peakR); peakL = 0; peakR = 0
            s.sourceRMS = (result.l.rmsLinear, result.r.rmsLinear)
            s.outputClip = (clipL, clipR)
            s.sampleRate = outRate
        }
        s.outputPeak = s.sourcePeak; s.outputRMS = s.sourceRMS
        s.scopeL = l; s.scopeR = r
        return s
    }

    /// `count` samples of output and input ending at the same host time (the later of the two
    /// streams is cut back to the earlier one). The output is shifted `shiftSeconds` earlier.
    func aligned(count n: Int, shiftSeconds: Double) -> Aligned? {
        var a = Aligned(outL: [Float](repeating: 0, count: n), outR: [Float](repeating: 0, count: n),
                        inL: [Float](repeating: 0, count: n), inR: [Float](repeating: 0, count: n),
                        sampleRate: 48_000, hasOutput: false, hasInput: false)
        lock.withLock {
            let sr = outRate
            a.sampleRate = sr
            let oO = outClock?.origin, iO = inputClock.origin
            let inRate = inputClock.sampleRate
            let hasOut = outRing != nil && outStored > 0
            let hasIn = inStored > 0
            a.hasOutput = hasOut; a.hasInput = hasIn
            if hasOut, hasIn, let oO, let iO, abs(inRate - sr) < 0.5 {
                let tEnd = min(oO + Double(outCount) / sr, iO + Double(inCount) / sr)
                let jo = Int(((tEnd - shiftSeconds - oO) * sr).rounded())
                let ji = Int(((tEnd - iO) * sr).rounded())
                copy(oL, oR, end: min(jo, outCount), stored: outStored - (outCount - min(jo, outCount)), count: n, into: &a.outL, &a.outR)
                copy(iL, iR, end: min(ji, inCount), stored: inStored - (inCount - min(ji, inCount)), count: n, into: &a.inL, &a.inR)
            } else {
                if hasOut { copy(oL, oR, end: outCount, stored: outStored, count: n, into: &a.outL, &a.outR) }
                if hasIn { copy(iL, iR, end: inCount, stored: inStored, count: n, into: &a.inL, &a.inR) }
            }
        }
        guard a.hasOutput || a.hasInput else { return nil }
        return a
    }

    /// Copies the `count` samples ending at absolute index `end` (exclusive). Caller holds the lock.
    private func copy(_ hl: [Float], _ hr: [Float], end: Int, stored: Int, count n: Int,
                      into l: inout [Float], _ r: inout [Float]) {
        let mask = Self.historyLength - 1
        let avail = max(0, min(n, stored, Self.historyLength))
        let pad = n - avail
        for i in 0..<avail {
            let idx = (end - avail + i) & mask
            l[pad + i] = hl[idx]; r[pad + i] = hr[idx]
        }
    }

    // MARK: Loop

    private func rebuild(rate r: Double) {
        readerL = TimecodeReader(sampleRate: r); readerR = TimecodeReader(sampleRate: r)
        speedL = LTCSpeedMeter(sampleRate: r); speedR = LTCSpeedMeter(sampleRate: r)
        levelL = LevelTracker(); levelR = LevelTracker()
    }

    private func loop() {
        var lastPublish = CACurrentMediaTime()
        var lastEstimate = lastPublish
        while !stopFlag.load(ordering: .sequentiallyConsistent) {
            var changed = false, doReset = false
            var ring: SPSCRingBuffer?, rate = 48_000.0
            lock.withLock {
                if outChanged { changed = true; outChanged = false }
                if resetRequested { doReset = true; resetRequested = false }
                ring = outRing; rate = outRate
            }
            if changed {
                workerRing = ring
                rebuild(rate: rate)
                recent.removeAll()
                ring?.consumerDiscardAll()
                let start = ring?.totalRead ?? 0
                lock.withLock { outCount = start; outStored = 0; result = Output(); result.sampleRate = rate }
            }
            if doReset {
                readerL.reset(); readerR.reset(); speedL.reset(); speedR.reset()
                recent.removeAll()
            }

            var didWork = false
            if let ring = workerRing {
                while true {
                    let n = ring.read(scratchL, scratchR, count: chunk)
                    if n == 0 { break }
                    processOutput(n); didWork = true
                }
            }
            while true {
                let n = inputRing.read(scratchL, scratchR, count: chunk)
                if n == 0 { break }
                storeInput(n); didWork = true
            }

            let now = CACurrentMediaTime()
            if now - lastPublish > 0.03 {
                lastPublish = now
                var l = InputAnalyzer.Channel(), r = InputAnalyzer.Channel()
                fill(&l, readerL.status, levelL, speedL)
                fill(&r, readerR.status, levelR, speedR)
                lock.withLock { result.l = l; result.r = r }
            }
            if now - lastEstimate > 0.5 {
                lastEstimate = now
                estimateLatency()
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

    private func processOutput(_ n: Int) {
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
                let idx = (outCount &+ i) & mask
                oL[idx] = bl[i]; oR[idx] = br[i]
            }
            outCount &+= n; outStored = min(Self.historyLength, outStored + n)
            peakL = max(peakL, pl); peakR = max(peakR, pr)
            if pl >= 0.999 { clipL = true }
            if pr >= 0.999 { clipR = true }
        }
    }

    private func storeInput(_ n: Int) {
        lock.withLock {
            let mask = Self.historyLength - 1
            for i in 0..<n {
                let idx = (inCount &+ i) & mask
                iL[idx] = scratchL[i]; iR[idx] = scratchR[i]
            }
            inCount &+= n; inStored = min(Self.historyLength, inStored + n)
        }
    }

    /// Cross-correlates the mono sum of output and input over the same host-time span.
    private func estimateLatency() {
        var ref: [Float] = [], del: [Float] = []
        var window = 0, maxLag = 0
        var mismatch = false
        lock.withLock {
            let sr = outRate
            guard outRing != nil, let oO = outClock?.origin, let iO = inputClock.origin else { return }
            if abs(inputClock.sampleRate - sr) > 0.5 { mismatch = true; return }
            window = Int(Self.windowSeconds * sr)
            maxLag = Int(Self.maxLagSeconds * sr)
            let span = window + maxLag
            let tEnd = min(oO + Double(outCount) / sr, iO + Double(inCount) / sr)
            let jo = Int(((tEnd - oO) * sr).rounded()), ji = Int(((tEnd - iO) * sr).rounded())
            guard jo - span >= outCount - outStored, ji - span >= inCount - inStored,
                  jo <= outCount, ji <= inCount else { return }
            let mask = Self.historyLength - 1
            ref = [Float](repeating: 0, count: span); del = ref
            for k in 0..<span {
                let a = (jo - span + k) & mask, b = (ji - span + k) & mask
                ref[k] = oL[a] + oR[a]
                del[k] = iL[b] + iR[b]
            }
        }
        if mismatch {
            lock.withLock { result.rateMismatch = true; result.latency = nil }
            return
        }
        guard !ref.isEmpty else {
            lock.withLock { result.rateMismatch = false }
            return
        }
        // Skip silence: correlation of noise against nothing is meaningless.
        var rms: Float = 0
        vDSP_rmsqv(ref, 1, &rms, vDSP_Length(ref.count))
        let est = rms > 0.001 ? LatencyEstimator.estimate(reference: ref, delayed: del, window: window, maxLag: maxLag) : nil
        if let e = est, e.confidence > 0.35 {
            recent.append(e)
            if recent.count > 5 { recent.removeFirst(recent.count - 5) }
        } else {
            recent.removeAll()
        }
        // Median of the last few accepted estimates, so one bad window doesn't jump the readout.
        let shown: LatencyEstimator.Result? = recent.count >= 2
            ? recent.sorted { $0.lagSamples < $1.lagSamples }[recent.count / 2]
            : nil
        lock.withLock { result.rateMismatch = false; result.latency = shown }
    }
}

// MARK: - Spectrum feed

extension ScopeCore: SpectrumFeed {
    /// Latest output and input over the same span of host time, the output `shiftSeconds`
    /// earlier (the spectrum's delay compensation). Worker thread of the spectrum analyser.
    func spectrumRead(count n: Int, shiftSeconds: Double, into b: SpectrumBuffers) -> SpectrumFeedState {
        let n = min(n, Self.historyLength, b.capacity)
        var st = SpectrumFeedState()
        lock.withLock {
            let hasOut = outRing != nil && outStored > 0
            let hasIn = inStored > 0
            let inRate = inputClock.sampleRate
            st.sampleRate = hasOut || inRate <= 0 ? outRate : inRate
            st.inputFrames = hasIn ? inCount : nil
            st.outputFrames = hasOut ? outCount : nil
            st.roundTrip = result.latency.map { $0.lagSamples / outRate }
            guard n > 0 else { return }
            for p in [\SpectrumBuffers.inL, \.inR, \.outL, \.outR] {
                b[keyPath: p].withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            }
            let sr = outRate
            if hasOut, hasIn, let oO = outClock?.origin, let iO = inputClock.origin, abs(inRate - sr) < 0.5 {
                let tEnd = min(oO + Double(outCount) / sr, iO + Double(inCount) / sr)
                let jo = min(outCount, Int(((tEnd - shiftSeconds - oO) * sr).rounded()))
                let ji = min(inCount, Int(((tEnd - iO) * sr).rounded()))
                copy(oL, oR, end: jo, stored: outStored - (outCount - jo), count: n, into: &b.outL, &b.outR)
                copy(iL, iR, end: ji, stored: inStored - (inCount - ji), count: n, into: &b.inL, &b.inR)
            } else {
                if hasOut { copy(oL, oR, end: outCount, stored: outStored, count: n, into: &b.outL, &b.outR) }
                if hasIn { copy(iL, iR, end: inCount, stored: inStored, count: n, into: &b.inL, &b.inR) }
            }
        }
        return st
    }
}
