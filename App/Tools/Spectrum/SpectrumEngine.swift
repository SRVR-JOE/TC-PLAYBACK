import Accelerate
import CoreGraphics
import Foundation
import Observation
import os
import QuartzCore
import Synchronization

// MARK: - Settings

enum SpectrumStream: String, CaseIterable, Identifiable {
    case input, output
    var id: String { rawValue }
}

/// What the analyser shows: one stream, the other, or both overlaid.
enum SpectrumSources: String, CaseIterable, Identifiable {
    case input, output, both
    var id: String { rawValue }
    var label: String { switch self { case .input: "Input"; case .output: "Output"; case .both: "Both" } }
    func includes(_ s: SpectrumStream) -> Bool { self == .both || rawValue == s.rawValue }
}

enum SpectrumChannels: String, CaseIterable, Identifiable {
    case leftRight, midSide, left, right, mid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .leftRight: "Left and right"; case .midSide: "Mid and side"
        case .left: "Left"; case .right: "Right"; case .mid: "Mid (L+R)"
        }
    }
    var isMidSide: Bool { self == .midSide || self == .mid }
    /// Whether the second trace of the pair (right / side) is drawn.
    var showsSecond: Bool { self == .leftRight || self == .midSide || self == .right }
    var showsFirst: Bool { self != .right }
}

enum SpectrumDisplay: String, CaseIterable, Identifiable {
    /// Fractional-octave bars, band energy (RTA).
    case bars
    /// Smoothed line, mean density (spectrum).
    case line
    var id: String { rawValue }
}

enum SpectrumDelayMode: Equatable {
    /// Follow the Scope page's round-trip measurement.
    case followRoundTrip
    /// A delay found by Find delay (seconds).
    case fixed(Double)
}

struct SpectrumSettings: Equatable {
    var fftSize = 16_384
    var window: SpectrumWindowKind = .blackmanHarris
    var fraction = 12
    var display: SpectrumDisplay = .line
    var averaging: SpectrumAveraging = .fast
    var tilt: Double = 0
    var channels: SpectrumChannels = .leftRight
    var sources: SpectrumSources = .input
    var delay: SpectrumDelayMode = .followRoundTrip
    var transfer = false
    var spectrogramImage = false
    /// Top and bottom of the level scale (also the spectrogram colour range).
    var topDB: Float = 0
    var rangeDB: Float = 100
    var inputMono = false

    static let fftSizes = [4096, 8192, 16_384, 32_768]
}

// MARK: - Feed

/// Preallocated sample buffers the feed copies into.
final class SpectrumBuffers {
    var inL: [Float], inR: [Float], outL: [Float], outR: [Float]
    init(capacity n: Int) {
        inL = [Float](repeating: 0, count: n); inR = inL; outL = inL; outR = inL
    }
    var capacity: Int { inL.count }
}

struct SpectrumFeedState: Equatable {
    var sampleRate: Double = 48_000
    /// Frames received so far per stream (nil = stream absent). Used to tell new data.
    var inputFrames: Int?
    var outputFrames: Int?
    /// The Scope page's measured round trip (output → input), seconds.
    var roundTrip: Double?
}

/// Something holding recent input and/or output audio. Called on the analyser's worker thread.
protocol SpectrumFeed: AnyObject {
    /// Copies the latest `count` frames of each present stream (zero-padded at the start
    /// when less is stored). With both streams the windows end at the same host time and the
    /// output is taken `shiftSeconds` earlier, so a delayed loop back lines up.
    func spectrumRead(count: Int, shiftSeconds: Double, into buffers: SpectrumBuffers) -> SpectrumFeedState
}

// MARK: - Frame

struct SpectrumTrace {
    var stream: SpectrumStream
    /// 0 = left / mid, 1 = right / side.
    var channel: Int
    var level: [Float]
    var hold: [Float]
    var max: [Float]
}

struct SpectrumFrame {
    var centers: [Double] = []
    var lower: [Double] = []
    var upper: [Double] = []
    var fraction = 12
    var display: SpectrumDisplay = .line
    var midSide = false
    var traces: [SpectrumTrace] = []
    var peaks: [SpectrumPeak] = []
    var peakStream: SpectrumStream?
    var transfer: TransferBands?
    /// Delay used to line the output up with the input, seconds.
    var compensation: Double?
    var spectrogram: CGImage?
    /// Seconds of history the spectrogram covers.
    var spectrogramSeconds: Double = 0
    var sampleRate: Double = 48_000
    var fftSize = 16_384
    var updatesPerSecond: Double = 0
    var hasInput = false
    var hasOutput = false
    var generation = 0
}

// MARK: - Engine

/// Real-time spectrum analyser. All FFT work happens on its own thread; the views read the
/// latest `SpectrumFrame` (a handful of small arrays) each display refresh.
///
/// Analysis runs at hop = max(N/8, sampleRate/60): 60 updates a second up to 4k, ~12 at 32k,
/// each on the newest N samples (so the windows overlap 80–97 %). Averaging time constants
/// are in seconds, so they do not change with the FFT size.
@Observable
final class SpectrumEngine {
    var settings = SpectrumSettings() { didSet { if settings != oldValue { core.setSettings(settings) } } }
    /// Freezes the display (the page's Hold).
    var held = false { didSet { core.setHeld(held) } }
    /// Published a few times a second for the controls.
    private(set) var status = Status()
    private(set) var isRunning = false

    struct Status: Equatable {
        var hasInput = false
        var hasOutput = false
        var compensationMS: Double?
        var roundTripMS: Double?
        var finding = false
        var lastFind: FindResult?
    }

    enum FindResult: Equatable { case found(Double), notFound }

    @ObservationIgnored let core = SpectrumCore()
    @ObservationIgnored private var timer: Timer?

    func start(feed: SpectrumFeed) {
        guard !isRunning else { return }
        isRunning = true
        core.setSettings(settings)
        core.start(feed: feed)
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.publish() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate(); timer = nil
        core.stop()
    }

    func frame() -> SpectrumFrame { core.frame() }
    func reset() { core.requestReset() }

    /// Measures the output-to-input delay from the impulse response (≈ 2.7 s of audio) and
    /// uses it from then on.
    func findDelay() { core.requestFindDelay(); status.finding = true; status.lastFind = nil }
    func followRoundTrip() { settings.delay = .followRoundTrip; status.lastFind = nil }

    private func publish() {
        var s = status
        let f = core.frame()
        s.hasInput = f.hasInput; s.hasOutput = f.hasOutput
        s.compensationMS = f.compensation.map { $0 * 1000 }
        s.roundTripMS = core.roundTrip.map { $0 * 1000 }
        if let r = core.takeFindResult() {
            s.finding = false
            switch r {
            case .some(let sec): settings.delay = .fixed(sec); s.lastFind = .found(sec * 1000)
            case .none: s.lastFind = .notFound
            }
        }
        if s != status { status = s }
    }
}

/// Worker for `SpectrumEngine`. Main thread talks to it only under `lock`.
final class SpectrumCore: @unchecked Sendable {
    static let spectrogramRows = 240
    static let spectrogramFraction = 48
    static let findLength = 131_072

    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`:
    private var pending: SpectrumSettings?
    private var published = SpectrumFrame()
    private var heldFlag = false
    private var resetFlag = false
    private var findFlag = false
    private var findResult: Double??
    private var lastRoundTrip: Double?

    // Worker-only:
    private weak var feed: SpectrumFeed?
    private var s = SpectrumSettings()
    private var rate: Double = 0
    private var fft: SpectrumFFT?
    private var map: BandMap?
    private var specMap: BandMap?
    private var tiltDB: [Float] = []
    private var specTilt: [Float] = []
    private var buffers = SpectrumBuffers(capacity: 32_768)
    private var findBuffers: SpectrumBuffers?
    private var a = [Float](), b = [Float]()
    private var power = [Float]()
    /// Averaged per-bin power, [stream][channel].
    private var avg: [[[Float]]] = []
    private var avgFrames = 0
    private var bandLin = [Float](), bandDB = [Float]()
    private var hold: [[[Float]]] = [], holdAge: [[[Float]]] = [], maxTrace: [[[Float]]] = []
    private var transfer: TransferAccumulator?
    private var tfX = [Float](), tfY = [Float]()
    private var specRows: [UInt8] = []
    private var specWrite = 0
    private var specFilled = 0
    private var specWidth = 0
    private var specBand = [Float]()
    private var lut: [UInt32] = SpectrumCore.makeLUT()
    private var lastAnalysis: CFTimeInterval = 0
    private var lastFrames: (Int?, Int?) = (nil, nil)
    private var updates: [CFTimeInterval] = []
    private var generation = 0
    private let stopFlag = Atomic<Bool>(false)
    private let exited = DispatchSemaphore(value: 0)
    private var thread: Thread?

    deinit { stop() }

    func start(feed f: SpectrumFeed) {
        guard thread == nil else { return }
        feed = f
        rate = 0
        stopFlag.store(false, ordering: .sequentiallyConsistent)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "TCPlayback.Spectrum"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() {
        guard thread != nil else { return }
        stopFlag.store(true, ordering: .sequentiallyConsistent)
        _ = exited.wait(timeout: .now() + 1)
        thread = nil
        lock.withLock { published = SpectrumFrame() }
    }

    func setSettings(_ n: SpectrumSettings) { lock.withLock { pending = n } }
    func setHeld(_ h: Bool) { lock.withLock { heldFlag = h } }
    func requestReset() { lock.withLock { resetFlag = true } }
    func requestFindDelay() { lock.withLock { findFlag = true; findResult = nil } }
    func frame() -> SpectrumFrame { lock.withLock { published } }
    var roundTrip: Double? { lock.withLock { lastRoundTrip } }
    /// nil = nothing new; .some(nil) = not found; .some(x) = found x seconds.
    func takeFindResult() -> Double?? {
        lock.withLock { let r = findResult; findResult = nil; return r }
    }

    // MARK: Loop

    private func loop() {
        while !stopFlag.load(ordering: .sequentiallyConsistent) {
            var newSettings: SpectrumSettings?, doReset = false, doFind = false
            lock.withLock {
                newSettings = pending; pending = nil
                doReset = resetFlag; resetFlag = false
                doFind = findFlag; findFlag = false
            }
            if let n = newSettings {
                let structural = n.fftSize != s.fftSize || n.window != s.window || n.fraction != s.fraction
                    || n.display != s.display || n.channels != s.channels || n.tilt != s.tilt
                let tfChanged = n.delay != s.delay || n.transfer != s.transfer
                let avgChanged = n.averaging != s.averaging || n.sources != s.sources
                s = n
                if structural { rebuild() } else if avgChanged { resetAverages() }
                if tfChanged { transfer?.reset() }
            }
            if doReset { resetAverages(); transfer?.reset() }
            guard let feed else { usleep(10_000); continue }
            if doFind { runFindDelay(feed) }

            let now = CACurrentMediaTime()
            let hopSec = rate > 0 ? Double(hop) / rate : 1.0 / 60
            if now - lastAnalysis < hopSec * 0.98 {
                usleep(useconds_t(max(1_000, min(8_000, (hopSec - (now - lastAnalysis)) * 1e6))))
                continue
            }
            analyse(feed, now: now)
            #if DEBUG
            probe(start: now)
            #endif
        }
        exited.signal()
    }

    private var hop: Int { max(s.fftSize / 8, Int((rate > 0 ? rate : 48_000) / 60)) }

    private func rebuild() {
        let n = s.fftSize
        fft = SpectrumFFT(size: n, window: s.window)
        guard let fft, rate > 0 else { return }
        if buffers.capacity < n { buffers = SpectrumBuffers(capacity: n) }
        a = [Float](repeating: 0, count: n); b = a; tfX = a; tfY = a
        power = [Float](repeating: 0, count: fft.bins)
        let binHz = rate / Double(n)
        let bands = OctaveBands(fraction: s.fraction)
        map = BandMap(bands: bands, binHz: binHz, binCount: fft.bins, enbw: fft.enbw)
        let sb = OctaveBands(fraction: Self.spectrogramFraction)
        specMap = BandMap(bands: sb, binHz: binHz, binCount: fft.bins, enbw: fft.enbw)
        tiltDB = SpectrumMath.tilt(bands.centers, dbPerOctave: s.tilt)
        specTilt = SpectrumMath.tilt(sb.centers, dbPerOctave: s.tilt)
        bandLin = [Float](repeating: 0, count: bands.count); bandDB = bandLin
        specBand = [Float](repeating: 0, count: sb.count)
        if specWidth != sb.count {
            specWidth = sb.count
            specRows = [UInt8](repeating: 0, count: sb.count * Self.spectrogramRows * 4)
            specWrite = 0; specFilled = 0
        }
        transfer = TransferAccumulator(fft: fft)
        resetAverages()
    }

    private func resetAverages() {
        guard let fft, let map else { return }
        let z = [Float](repeating: 0, count: fft.bins)
        avg = Array(repeating: Array(repeating: z, count: 2), count: 2)
        avgFrames = 0
        let lo = [Float](repeating: -200, count: map.count), zero = [Float](repeating: 0, count: map.count)
        hold = Array(repeating: Array(repeating: lo, count: 2), count: 2)
        holdAge = Array(repeating: Array(repeating: zero, count: 2), count: 2)
        maxTrace = hold
    }

    #if DEBUG
    /// -spectrumProbe: logs updates per second and the worker's cost per analysis (QA only).
    private static let probeOn = ProcessInfo.processInfo.arguments.contains("-spectrumProbe")
    private var probeCost: Double = 0, probeCount = 0, probeAt: CFTimeInterval = 0
    private func probe(start: CFTimeInterval) {
        guard Self.probeOn else { return }
        let end = CACurrentMediaTime()
        probeCost += end - start; probeCount += 1
        if end - probeAt > 2 {
            NSLog("%@", String(format: "spectrum probe: %.1f updates/s, %.2f ms per analysis, FFT %d, %d traces, %d rows, %d written",
                         Double(probeCount) / max(0.001, end - probeAt), probeCost / Double(max(1, probeCount)) * 1000,
                         s.fftSize, frame().traces.count, specFilled, specWrite))
            probeCost = 0; probeCount = 0; probeAt = end
        }
    }
    #endif

    // MARK: Analysis

    private func compensation(_ st: SpectrumFeedState) -> Double {
        switch s.delay {
        case .followRoundTrip: return st.roundTrip ?? 0
        case .fixed(let v): return v
        }
    }

    private func analyse(_ feed: SpectrumFeed, now: CFTimeInterval) {
        // Read the round trip first (shift for this read), then the audio.
        var probe = feed.spectrumRead(count: 0, shiftSeconds: 0, into: buffers)
        if probe.sampleRate > 0, abs(probe.sampleRate - rate) > 0.5 { rate = probe.sampleRate; rebuild() }
        guard let fft, let map, let specMap else { usleep(10_000); return }
        let n = fft.size
        let comp = compensation(probe)
        probe = feed.spectrumRead(count: n, shiftSeconds: comp, into: buffers)
        lock.withLock { lastRoundTrip = probe.roundTrip }
        let frames = (probe.inputFrames, probe.outputFrames)
        let hasIn = probe.inputFrames != nil, hasOut = probe.outputFrames != nil
        if hasIn || hasOut, frames.0 == lastFrames.0, frames.1 == lastFrames.1 {
            // Nothing new arrived since the last analysis: keep the last frame.
            lastAnalysis = now
            return
        }
        let dt = lastAnalysis > 0 ? min(0.5, now - lastAnalysis) : Double(hop) / rate
        lastAnalysis = now
        lastFrames = frames
        let alpha = s.averaging.alpha(hopSeconds: dt, frames: avgFrames)

        var out = SpectrumFrame()
        out.centers = map.bands.centers; out.lower = map.bands.lower; out.upper = map.bands.upper
        out.fraction = s.fraction; out.display = s.display; out.midSide = s.channels.isMidSide
        out.sampleRate = rate; out.fftSize = n
        out.hasInput = hasIn; out.hasOutput = hasOut
        out.compensation = hasIn && hasOut ? comp : nil
        let mode: BandMode = s.display == .bars ? .energy : .smoothed
        var specSource: [Float]?
        var peakSource: (SpectrumStream, Int)?

        for stream in SpectrumStream.allCases {
            let present = stream == .input ? hasIn : hasOut
            guard present, s.sources.includes(stream) else { continue }
            let si = stream == .input ? 0 : 1
            let mono = stream == .input && s.inputMono
            fillChannels(stream, mono: mono)
            for ch in 0..<2 {
                // A mono input has one trace whatever the channel choice (its side is silence).
                let wanted = mono ? ch == 0 : (ch == 0 ? s.channels.showsFirst : s.channels.showsSecond)
                if !wanted { continue }
                (ch == 0 ? a : b).withUnsafeBufferPointer { x in
                    power.withUnsafeMutableBufferPointer { p in fft.power(x.baseAddress!, into: p.baseAddress!) }
                }
                if specSource == nil { specSource = power }
                avg[si][ch].withUnsafeMutableBufferPointer { av in
                    power.withUnsafeBufferPointer { p in
                        SpectrumMath.average(av.baseAddress!, p.baseAddress!, count: fft.bins, alpha: avgFrames == 0 ? 1 : alpha)
                    }
                }
                avg[si][ch].withUnsafeBufferPointer { av in
                    bandLin.withUnsafeMutableBufferPointer { bl in map.apply(av.baseAddress!, mode: mode, into: bl.baseAddress!) }
                    if peakSource == nil {
                        peakSource = (stream, ch)
                        out.peakStream = stream
                        out.peaks = SpectrumPeaks.find(power: av.baseAddress!, bins: fft.bins, binHz: rate / Double(n),
                                                       enbw: fft.enbw, lobe: fft.windowKind.lobeBins,
                                                       floorDB: s.topDB - s.rangeDB + 10)
                    }
                }
                bandLin.withUnsafeBufferPointer { bl in
                    bandDB.withUnsafeMutableBufferPointer { bd in SpectrumMath.toDB(bl.baseAddress!, into: bd.baseAddress!, count: map.count) }
                }
                vDSP_vadd(bandDB, 1, tiltDB, 1, &bandDB, 1, vDSP_Length(map.count))
                updateHold(si, ch, dt: Float(dt))
                out.traces.append(SpectrumTrace(stream: stream, channel: ch, level: bandDB, hold: hold[si][ch], max: maxTrace[si][ch]))
            }
        }
        avgFrames += 1

        updates.append(now)
        updates.removeAll { now - $0 > 1 }
        out.updatesPerSecond = Double(updates.count)
        if let sp = specSource { appendSpectrogramRow(sp, specMap) }
        if s.spectrogramImage { out.spectrogram = makeSpectrogramImage() }
        // One row per analysis: the time scale follows the measured row rate.
        let rowRate = updates.count >= 3 ? Double(updates.count) : rate / Double(hop)
        out.spectrogramSeconds = Double(Self.spectrogramRows) / max(1, rowRate)

        if s.transfer, hasIn, hasOut, let tf = transfer {
            transferChannel(into: &tfX, buffers.outL, buffers.outR)
            transferChannel(into: &tfY, buffers.inL, s.inputMono ? buffers.inL : buffers.inR)
            let tfAlpha: Float? = s.averaging == .infinite ? nil
                : (s.averaging == .off ? SpectrumAveraging.fast : s.averaging).alpha(hopSeconds: dt, frames: 0)
            tfX.withUnsafeBufferPointer { x in tfY.withUnsafeBufferPointer { y in tf.add(x: x.baseAddress!, y: y.baseAddress!, alpha: tfAlpha) } }
            out.transfer = tf.banded(map)   // tilt applies to spectra only
        }

        generation += 1
        out.generation = generation
        lock.withLock { if !heldFlag { published = out } }
    }

    /// Fills `a`, `b` with L/R or M/S of one stream (the newest `fftSize` samples).
    private func fillChannels(_ stream: SpectrumStream, mono: Bool) {
        let n = s.fftSize
        let l = stream == .input ? buffers.inL : buffers.outL
        let r = mono ? l : (stream == .input ? buffers.inR : buffers.outR)
        if s.channels.isMidSide {
            var half: Float = 0.5
            vDSP_vadd(l, 1, r, 1, &a, 1, vDSP_Length(n)); vDSP_vsmul(a, 1, &half, &a, 1, vDSP_Length(n))
            vDSP_vsub(r, 1, l, 1, &b, 1, vDSP_Length(n)); vDSP_vsmul(b, 1, &half, &b, 1, vDSP_Length(n))
        } else {
            a.withUnsafeMutableBufferPointer { d in l.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: n) } }
            b.withUnsafeMutableBufferPointer { d in r.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: n) } }
        }
    }

    private func transferChannel(into dst: inout [Float], _ l: [Float], _ r: [Float]) {
        let n = s.fftSize
        switch s.channels {
        case .left: dst.withUnsafeMutableBufferPointer { d in l.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: n) } }
        case .right: dst.withUnsafeMutableBufferPointer { d in r.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: n) } }
        default:
            var half: Float = 0.5
            vDSP_vadd(l, 1, r, 1, &dst, 1, vDSP_Length(n)); vDSP_vsmul(dst, 1, &half, &dst, 1, vDSP_Length(n))
        }
    }

    private func updateHold(_ si: Int, _ ch: Int, dt: Float) {
        let holdTime: Float = 1.5, decay: Float = 20  // dB per second after the hold time
        for i in 0..<bandDB.count {
            let v = bandDB[i]
            if v >= hold[si][ch][i] { hold[si][ch][i] = v; holdAge[si][ch][i] = 0 } else {
                holdAge[si][ch][i] += dt
                if holdAge[si][ch][i] > holdTime { hold[si][ch][i] = max(v, hold[si][ch][i] - decay * dt) }
            }
            if v > maxTrace[si][ch][i] { maxTrace[si][ch][i] = v }
        }
    }

    // MARK: Spectrogram

    /// Dark to amber to warm white. Sober: no rainbow, no neon.
    static func makeLUT() -> [UInt32] {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (10, 11, 13)), (0.30, (38, 30, 22)), (0.55, (120, 72, 20)),
            (0.78, (214, 142, 40)), (0.92, (245, 205, 120)), (1.00, (255, 246, 226)),
        ]
        return (0..<256).map { i in
            let t = Double(i) / 255
            var j = 0
            while j < stops.count - 2, t > stops[j + 1].0 { j += 1 }
            let (t0, c0) = stops[j], (t1, c1) = stops[j + 1]
            let f = max(0, min(1, (t - t0) / (t1 - t0)))
            let r = UInt32(c0.0 + (c1.0 - c0.0) * f), g = UInt32(c0.1 + (c1.1 - c0.1) * f), b = UInt32(c0.2 + (c1.2 - c0.2) * f)
            return r | (g << 8) | (b << 16) | (255 << 24)   // RGBA bytes, little-endian
        }
    }

    private func appendSpectrogramRow(_ p: [Float], _ m: BandMap) {
        guard specWidth == m.count, specWidth > 0 else { return }
        p.withUnsafeBufferPointer { pp in
            specBand.withUnsafeMutableBufferPointer { sb in m.apply(pp.baseAddress!, mode: .smoothed, into: sb.baseAddress!) }
        }
        specBand.withUnsafeMutableBufferPointer { sb in SpectrumMath.toDB(sb.baseAddress!, into: sb.baseAddress!, count: m.count) }
        let bottom = s.topDB - s.rangeDB, span = max(1, s.rangeDB)
        let row = specWrite % Self.spectrogramRows
        specRows.withUnsafeMutableBytes { raw in
            let px = raw.baseAddress!.assumingMemoryBound(to: UInt32.self) + row * specWidth
            for i in 0..<specWidth {
                let v = (specBand[i] + specTilt[i] - bottom) / span
                px[i] = lut[Int(max(0, min(255, v * 255)))]
            }
        }
        specWrite += 1
        specFilled = min(Self.spectrogramRows, specFilled + 1)
    }

    /// Newest row at the top.
    private func makeSpectrogramImage() -> CGImage? {
        let w = specWidth, h = Self.spectrogramRows
        guard w > 0, specFilled > 0 else { return nil }
        var data = Data(count: w * h * 4)
        data.withUnsafeMutableBytes { dst in
            specRows.withUnsafeBytes { src in
                let rowBytes = w * 4
                for y in 0..<h {
                    let d = dst.baseAddress! + y * rowBytes
                    if y < specFilled {
                        let r = ((specWrite - 1 - y) % h + h) % h
                        d.copyMemory(from: src.baseAddress! + r * rowBytes, byteCount: rowBytes)
                    } else {
                        let px = d.assumingMemoryBound(to: UInt32.self)
                        for i in 0..<w { px[i] = lut[0] }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Find delay

    private func runFindDelay(_ feed: SpectrumFeed) {
        let n = Self.findLength
        if findBuffers == nil { findBuffers = SpectrumBuffers(capacity: n) }
        guard let fb = findBuffers else { return }
        let st = feed.spectrumRead(count: n, shiftSeconds: 0, into: fb)
        var found: Double?
        if st.inputFrames != nil, st.outputFrames != nil, st.sampleRate > 0 {
            var x = [Float](repeating: 0, count: n), y = x
            vDSP_vadd(fb.outL, 1, fb.outR, 1, &x, 1, vDSP_Length(n))
            vDSP_vadd(fb.inL, 1, s.inputMono ? fb.inL : fb.inR, 1, &y, 1, vDSP_Length(n))
            if let r = DelayFinder.find(reference: x, measured: y, fftSize: 32_768), r.samples >= 0 {
                found = r.samples / st.sampleRate
            }
        }
        lock.withLock { findResult = .some(found) }
    }
}
