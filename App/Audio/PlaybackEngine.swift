import AVFoundation
import Foundation
import Observation
import QuartzCore
import TCKit

// CONTRACT FILE — owned by the AUDIO ENGINE agent. Every `public`/internal declaration in
// this file is the API the UI and Library agents are coding against RIGHT NOW. Implement the
// bodies (add any private helpers / new files under App/Audio/), but do not rename, remove or
// change the signature of anything declared here. Additive changes are fine.

/// What the engine is playing.
enum EngineSource: Equatable {
    case none
    /// An audio file on disk (stereo or mono; mono is treated as L only).
    case file(URL)
    /// Generated SMPTE LTC, optionally alongside nothing else.
    case generator(GeneratorConfig)
}

struct GeneratorConfig: Equatable, Codable {
    var start: Timecode
    var rate: FrameRate
    /// nil = run until stopped.
    var duration: TimeInterval?
    /// Which output side carries the generated LTC.
    var side: OutputSide = .right
    /// Peak level in dBFS (spec typical -10…-18).
    var levelDBFS: Float = -10
}

enum OutputSide: String, Codable, CaseIterable, Identifiable {
    case left, right, both
    var id: String { rawValue }
}

/// Per-source-channel routing. Mutes follow the SOURCE channel; `swapped` crosses the pair
/// so the track's L plays out the right side and vice versa.
struct ChannelRouting: Equatable, Codable {
    var leftEnabled: Bool = true
    var rightEnabled: Bool = true
    var swapped: Bool = false
    /// Gain applied to the track in dB (−∞…+6), applied after routing.
    var gainDB: Float = 0
}

enum TransportState: Equatable {
    case stopped, playing, paused
}

/// Where the on-screen timecode comes from.
enum ClockSource: Equatable {
    /// No LTC found — the clock shows track elapsed time.
    case trackTime
    /// LTC decoded from the given source channel of the file.
    case decoded(SourceChannel)
    /// The engine's own LTC generator.
    case generator
    /// LTC read from the device audio input.
    case externalInput
}

enum SourceChannel: String, Codable { case left, right }

/// Display-ready timecode/clock state, updated on the main thread ~30×/s.
struct ClockStatus: Equatable {
    var source: ClockSource = .trackTime
    /// The timecode to draw (nil → draw "--:--:--:--").
    var timecode: Timecode?
    var lock: TCLockState = .noSignal
    var rate: FrameRate?
    var isReverse: Bool = false
    var ltcLevelDBFS: Float?
    var userBits: UInt32 = 0
    var discontinuities: Int = 0
}

/// Lock-free-ish snapshot the visuals pull at display rate. Values are linear 0…1 except
/// where noted. "source" = file channels before routing; "output" = what leaves the device.
struct AnalysisSnapshot {
    var sourcePeak: (l: Float, r: Float) = (0, 0)
    var sourceRMS: (l: Float, r: Float) = (0, 0)
    var outputPeak: (l: Float, r: Float) = (0, 0)
    var outputRMS: (l: Float, r: Float) = (0, 0)
    /// True if a channel clipped (≥ 0.999) since the last `resetClip()`.
    var outputClip: (l: Bool, r: Bool) = (false, false)
    /// Most recent N samples per SOURCE channel (oldest first), for the oscilloscope.
    /// N == `AnalysisSnapshot.scopeLength`.
    var scopeL: [Float] = []
    var scopeR: [Float] = []
    static let scopeLength = 2048
    var sampleRate: Double = 48_000
}

@Observable
final class PlaybackEngine {
    static let shared = PlaybackEngine()

    // MARK: Observable state (main thread)
    private(set) var transport: TransportState = .stopped
    private(set) var source: EngineSource = .none
    /// Seconds into the current item.
    private(set) var currentTime: TimeInterval = 0
    /// Seconds; 0 for an open-ended generator.
    private(set) var duration: TimeInterval = 0
    private(set) var clock = ClockStatus()
    /// Channel count of the loaded file (1 or 2).
    private(set) var sourceChannelCount: Int = 2
    /// Human-readable current output route, e.g. "Headphones", "USB Audio Interface".
    private(set) var outputRouteName: String = "Speaker"
    /// Last error message suitable for an operator alert; nil when fine.
    var lastError: String?

    /// Live routing for the current item. Setting it applies immediately (click-free ramp).
    var routing = ChannelRouting() {
        didSet { graph?.core.setRouting(routing) }
    }

    /// When true, LTC is decoded from both file channels and the clock follows whichever locks.
    var autoDetectTimecode: Bool = true {
        didSet { if !autoDetectTimecode { followed = nil } }
    }
    /// Read LTC from the device audio input instead of the file (shows `.externalInput`).
    var readExternalInput: Bool = false {
        didSet { if readExternalInput != oldValue { externalInputChanged() } }
    }

    /// Called on the main thread when an item reaches its end naturally (not on stop()).
    var onItemFinished: (() -> Void)?

    // MARK: Additive API (engine agent)

    /// Lock-screen / Control Centre / headset "next track". Wired by the ShowController.
    var onRemoteNext: (() -> Void)?
    /// Lock-screen / Control Centre / headset "previous track".
    var onRemotePrevious: (() -> Void)?
    /// Title shown on the lock screen (defaults to the file name / generator start TC).
    var nowPlayingTitle: String? { didSet { updateNowPlaying() } }
    /// When true (Show Lock), remote stop and scrub commands from the lock screen are refused.
    var remoteTransportLocked: Bool = false
    /// True when the loaded file's sample rate differs from the hardware rate (we resample,
    /// but crews want to know — e.g. a 44.1 kHz file on a 48 kHz interface).
    private(set) var sampleRateMismatch: Bool = false
    /// The loaded file's own sample rate (0 when no file is loaded).
    private(set) var fileSampleRate: Double = 0
    /// The rate the output device is running at.
    private(set) var hardwareSampleRate: Double = 48_000
    /// Short, time-stamped operator entries: interruptions, route losses, resumes (newest last).
    private(set) var interruptionLog: [String] = []
    /// Buffer underruns (audible dropouts) since the item was loaded.
    private(set) var dropoutCount: Int = 0

    // MARK: Internals (not observed)
    @ObservationIgnored private var graph: AudioGraph?
    @ObservationIgnored private var streamer: FileStreamer?
    @ObservationIgnored private var monitor: TimecodeMonitor?
    @ObservationIgnored private var encoder: LTCEncoder?
    @ObservationIgnored private var securedURL: URL?
    @ObservationIgnored private var setupDone = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var engineObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingSeekGen = 0
    @ObservationIgnored private var followed: SourceChannel?
    @ObservationIgnored private var followedExternal: SourceChannel?
    @ObservationIgnored private var tcOffset: Double?
    @ObservationIgnored private var tcRate: FrameRate?
    @ObservationIgnored private var followGraceUntil: CFTimeInterval = 0
    @ObservationIgnored private var fadeStopGen: Int?
    @ObservationIgnored private var outputLatency: TimeInterval = 0.01
    @ObservationIgnored private var inputLatency: TimeInterval = 0.01
    @ObservationIgnored private var cachedPeaks: (sl: Float, sr: Float, ol: Float, or: Float) = (0, 0, 0, 0)
    @ObservationIgnored private var lastPeakTake: CFTimeInterval = 0
    @ObservationIgnored private var inputEngine: AVAudioEngine?
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var routeAtPlay: String = ""
    @ObservationIgnored private var lastNowPlayingSecond = -1
    @ObservationIgnored var remoteCommandsInstalled = false

    init() {}

    // MARK: Transport
    func load(_ source: EngineSource, routing: ChannelRouting = ChannelRouting()) throws {
        ensureSetup()
        let g: AudioGraph
        do { g = try ensureGraph() } catch {
            lastError = "The audio output couldn't be started. Check the audio interface and try again."
            throw error
        }
        let core = g.core
        core.quiesce(renderActive: g.isRendering)
        streamer?.stop()
        streamer = nil
        core.clearGenerator()
        encoder = nil
        releaseSecurityScope()
        core.ring.reset()
        core.requestMasterFade(frames: 0)
        core.positionFrames.store(0, ordering: .releasing)
        fadeStopGen = nil
        pendingSeekGen = 0
        followed = nil; followedExternal = nil; tcOffset = nil; tcRate = nil
        monitor?.resetReaders()
        dropoutCount = 0
        core.underruns.store(0, ordering: .relaxed)

        self.routing = routing
        transport = .stopped
        currentTime = 0
        switch source {
        case .none:
            self.source = .none
            duration = 0; sourceChannelCount = 2; sampleRateMismatch = false; fileSampleRate = 0
        case .file(let url):
            if url.startAccessingSecurityScopedResource() { securedURL = url }
            let s: FileStreamer
            do { s = try FileStreamer(url: url, core: core) } catch {
                releaseSecurityScope()
                self.source = .none
                duration = 0
                lastError = "“\(url.lastPathComponent)” couldn't be opened. The file may be missing or in an unsupported format."
                throw error
            }
            s.renderActive = { [weak g] in g?.isRendering ?? false }
            s.prime()
            s.start()
            streamer = s
            self.source = source
            duration = s.duration
            sourceChannelCount = min(2, s.channelCount)
            fileSampleRate = s.fileRate
            sampleRateMismatch = s.needsResampling
            core.activate(.file)
        case .generator(let cfg):
            let e = LTCEncoder(sampleRate: core.sampleRate, rate: cfg.rate, start: cfg.start)
            e.level = min(1, RoutingMath.linearGain(dB: cfg.levelDBFS))
            encoder = e
            let frames = cfg.duration.map { Int(($0 * core.sampleRate).rounded()) } ?? -1
            core.configureGenerator(encoder: e, side: cfg.side, durationFrames: frames,
                                    startFrameNumber: cfg.start.frameNumber)
            self.source = source
            duration = cfg.duration ?? 0
            sourceChannelCount = 2
            sampleRateMismatch = false
            fileSampleRate = 0
            core.activate(.generator)
        }
        startEngineIfNeeded()
        updateClock()
        updateNowPlaying()
    }

    func play() {
        guard source != .none else { return }
        ensureSetup()
        guard let g = graph else { return }
        let core = g.core
        if core.finished.load(ordering: .acquiring) || (duration > 0 && currentTime >= duration - 0.001) {
            seek(to: 0)
        }
        fadeStopGen = nil
        core.requestMasterFade(frames: 0)
        activateSession()
        startEngineIfNeeded()
        core.setRun(true)
        transport = .playing
        routeAtPlay = outputRouteName
        followGraceUntil = CACurrentMediaTime() + 1.0
        updateNowPlaying()
    }

    func pause() {
        guard transport == .playing else { return }
        graph?.core.setRun(false)
        fadeStopGen = nil
        transport = .paused
        updateNowPlaying()
    }

    func stop() {
        graph?.core.setRun(false)
        fadeStopGen = nil
        if source != .none { seek(to: 0) }
        transport = .stopped
        currentTime = 0
        updateNowPlaying()
    }

    func togglePlayPause() { transport == .playing ? pause() : play() }

    func seek(to time: TimeInterval) {
        guard let core = graph?.core, source != .none else { currentTime = 0; return }
        var t = max(0, time.isFinite ? time : 0)
        if duration > 0 { t = min(t, duration) }
        switch source {
        case .file:
            pendingSeekGen = core.requestSeek(toFrame: Int((t * core.sampleRate).rounded()))
        case .generator(let cfg):
            let frames = Int((t * core.sampleRate).rounded())
            let tcFrame = cfg.start.frameNumber + Int((t * cfg.rate.fps).rounded(.down))
            core.requestGeneratorLocate(frames: frames, timecodeFrameNumber: tcFrame)
        case .none:
            break
        }
        currentTime = t
        monitor?.resetReaders()
        followGraceUntil = CACurrentMediaTime() + 1.0
        updateNowPlaying()
    }

    func skip(by delta: TimeInterval) { seek(to: max(0, currentTime + delta)) }

    /// Panic fade: ramp every output to silence over `fadeOut` seconds, then stop.
    func stop(fadeOut: TimeInterval) {
        guard transport == .playing, fadeOut > 0, let g = graph, g.isRendering else {
            stop(); return
        }
        fadeStopGen = g.core.requestMasterFade(frames: max(1, Int(fadeOut * g.core.sampleRate)))
    }

    // MARK: Analysis
    /// Called by visuals from a TimelineView/display link. Must be cheap (copy only).
    func analysisSnapshot() -> AnalysisSnapshot {
        var snap = AnalysisSnapshot()
        guard let core = graph?.core else {
            snap.scopeL = [Float](repeating: 0, count: AnalysisSnapshot.scopeLength)
            snap.scopeR = snap.scopeL
            return snap
        }
        let now = CACurrentMediaTime()
        if now - lastPeakTake > 0.004 {
            cachedPeaks = core.takePeaks()
            lastPeakTake = now
        }
        let rms = core.rms()
        snap.sourcePeak = (cachedPeaks.sl, cachedPeaks.sr)
        snap.outputPeak = (cachedPeaks.ol, cachedPeaks.or)
        snap.sourceRMS = (rms.sl, rms.sr)
        snap.outputRMS = (rms.ol, rms.or)
        snap.outputClip = (core.clipL.load(ordering: .relaxed), core.clipR.load(ordering: .relaxed))
        if let monitor {
            let (l, r) = monitor.scope(count: AnalysisSnapshot.scopeLength)
            snap.scopeL = l; snap.scopeR = r
            snap.sampleRate = monitor.read().sampleRate
        } else {
            snap.scopeL = [Float](repeating: 0, count: AnalysisSnapshot.scopeLength)
            snap.scopeR = snap.scopeL
            snap.sampleRate = core.sampleRate
        }
        return snap
    }

    func resetClip() {
        graph?.core.clipL.store(false, ordering: .relaxed)
        graph?.core.clipR.store(false, ordering: .relaxed)
    }

    // MARK: - Setup

    private func ensureSetup() {
        guard !setupDone else { return }
        setupDone = true
        configureSession(record: false)
        installSessionObservers()
        installRemoteCommands()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @discardableResult
    private func ensureGraph() throws -> AudioGraph {
        if let graph { return graph }
        let g = try AudioGraph()
        g.core.setRouting(routing)
        graph = g
        hardwareSampleRate = g.core.sampleRate
        let m = TimecodeMonitor(analysisRing: g.core.analysisRing, sampleRate: g.core.sampleRate)
        m.start()
        monitor = m
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: g.engine, queue: .main) { [weak self] _ in
                self?.handleEngineConfigurationChange()
            }
        if inputEngine != nil { restartInputEngine() }
        return g
    }

    private func startEngineIfNeeded() {
        guard let g = graph, !g.engine.isRunning else { return }
        do { try g.start() } catch {
            lastError = "The audio output couldn't be started. Check the audio interface and try again."
        }
    }

    private func releaseSecurityScope() {
        securedURL?.stopAccessingSecurityScopedResource()
        securedURL = nil
    }

    private func configureSession(record: Bool) {
        let s = AVAudioSession.sharedInstance()
        do {
            if record {
                try s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            } else {
                try s.setCategory(.playback, mode: .default, options: [])
            }
            try? s.setPreferredSampleRate(48_000)
            try? s.setPreferredIOBufferDuration(0.005)
            try s.setActive(true)
        } catch {
            lastError = "The audio session couldn't be set up. Another app may be using audio exclusively."
        }
        refreshRouteInfo()
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func refreshRouteInfo() {
        let s = AVAudioSession.sharedInstance()
        let name = AudioRoutes.name(for: s.currentRoute)
        if name != outputRouteName { outputRouteName = name }
        outputLatency = s.outputLatency + s.ioBufferDuration
        inputLatency = s.inputLatency + s.ioBufferDuration
    }

    // MARK: - 30 Hz publisher

    private func tick() {
        guard let g = graph else { return }
        let core = g.core
        // Position
        if source != .none {
            let handled = core.handledSeekGenOut.load(ordering: .acquiring)
            if pendingSeekGen == 0 || handled >= pendingSeekGen || source.isGenerator {
                let t = Double(core.positionFrames.load(ordering: .acquiring)) / core.sampleRate
                let clamped = duration > 0 ? min(t, duration) : t
                if abs(clamped - currentTime) > 0.0005 { currentTime = clamped }
            }
        }
        let u = core.underruns.load(ordering: .relaxed)
        if u != dropoutCount { dropoutCount = u }

        // Panic fade complete
        if let fg = fadeStopGen, core.masterFadeDoneGen.load(ordering: .acquiring) >= fg {
            fadeStopGen = nil
            stop()
        }

        // Natural end
        if core.finished.load(ordering: .acquiring), transport == .playing {
            core.finished.store(false, ordering: .releasing)
            core.setRun(false)
            transport = .stopped
            seek(to: 0)
            currentTime = 0
            updateNowPlaying()
            onItemFinished?()
        }

        updateClock()
        if transport == .playing {
            let sec = Int(currentTime)
            if sec != lastNowPlayingSecond && sec % 5 == 0 { lastNowPlayingSecond = sec; updateNowPlaying() }
        }
    }

    // MARK: - Clock

    private func isLive(_ s: TimecodeReader.Status) -> Bool { s.state == .locked || s.state == .freewheel }

    /// Prefer the channel already followed, then R, then L.
    private func pick(_ l: TimecodeReader.Status, _ r: TimecodeReader.Status, current: SourceChannel?) -> SourceChannel? {
        if let current, isLive(current == .left ? l : r) { return current }
        if isLive(r) { return .right }
        if isLive(l) { return .left }
        return current
    }

    private func updateClock() {
        var cs = ClockStatus()
        let playing = transport == .playing
        let mon = monitor?.read()
        if readExternalInput, let mon, mon.external {
            cs.source = .externalInput
            followedExternal = pick(mon.left, mon.right, current: followedExternal)
            let st = (followedExternal ?? .right) == .left ? mon.left : mon.right
            cs.lock = st.state
            fill(&cs, from: st)
            cs.timecode = st.timecode.map { $0.adding(seconds: st.isReverse ? -inputLatency : inputLatency) }
        } else if case .generator(let cfg) = source {
            cs.source = .generator
            cs.rate = cfg.rate
            cs.lock = playing ? .locked : .noSignal
            cs.ltcLevelDBFS = cfg.levelDBFS
            cs.userBits = encoder?.userBits ?? 0
            var fn = graph?.core.genFrameNumber.load(ordering: .acquiring) ?? cfg.start.frameNumber
            if playing { fn = max(cfg.start.frameNumber, fn - Int((outputLatency * cfg.rate.fps).rounded())) }
            cs.timecode = Timecode(frameNumber: fn, rate: cfg.rate)
        } else if case .file = source, autoDetectTimecode, let mon, !mon.external, let core = graph?.core {
            let now = CACurrentMediaTime()
            followed = pick(mon.left, mon.right, current: followed)
            var resolved = false
            if let ch = followed {
                let st = ch == .left ? mon.left : mon.right
                if isLive(st), let tc = st.timecode {
                    var shown = tc
                    if playing {
                        // Shift from "end of decoded samples" to "what is leaving the speaker now".
                        let audible = core.renderedFrames.load(ordering: .acquiring) - Int(outputLatency * core.sampleRate)
                        let delta = Double(audible - mon.decodedCount) / core.sampleRate
                        shown = tc.adding(seconds: st.isReverse ? -delta : delta)
                    }
                    cs.source = .decoded(ch)
                    fill(&cs, from: st)
                    cs.timecode = shown
                    cs.lock = st.state
                    if !st.isReverse { tcOffset = shown.realSeconds - currentTime; tcRate = shown.rate }
                    resolved = true
                } else if !playing || now < followGraceUntil, let off = tcOffset, let rate = tcRate {
                    // Paused / just seeked: hold the clock on the track's TC, estimated from the last lock.
                    cs.source = .decoded(ch)
                    fill(&cs, from: st)
                    cs.timecode = Timecode(realSeconds: currentTime + off, rate: rate)
                    cs.lock = st.state
                    cs.rate = rate
                    resolved = true
                } else if playing && st.state == .noSignal && now >= followGraceUntil {
                    followed = nil
                }
            }
            if !resolved { trackTime(&cs) }
        } else {
            trackTime(&cs)
        }
        if cs != clock { clock = cs }
    }

    private func fill(_ cs: inout ClockStatus, from st: TimecodeReader.Status) {
        cs.rate = st.rate
        cs.isReverse = st.isReverse
        cs.ltcLevelDBFS = st.levelDBFS
        cs.userBits = st.userBits
        cs.discontinuities = st.discontinuities
    }

    private func trackTime(_ cs: inout ClockStatus) {
        cs = ClockStatus()
        cs.source = .trackTime
        cs.timecode = Timecode(realSeconds: currentTime, rate: .fps30)
        cs.lock = .noSignal
    }

    // MARK: - Session events

    private func installSessionObservers() {
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
            self?.handleInterruption(n)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] n in
            self?.handleRouteChange(n)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { [weak self] _ in
            self?.handleMediaServicesReset()
        })
    }

    private func log(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        var entry = f.string(from: Date())
        if let tc = clock.timecode, clock.source != .trackTime { entry += " · TC \(tc)" }
        entry += " · " + text
        interruptionLog.append(entry)
        if interruptionLog.count > 50 { interruptionLog.removeFirst(interruptionLog.count - 50) }
    }

    private func handleInterruption(_ n: Notification) {
        guard let info = n.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = transport == .playing
            if transport == .playing {
                graph?.core.setRun(false)
                transport = .paused
            }
            log("Audio interrupted")
            lastError = "Audio was interrupted by another app or a call. Playback paused."
            updateNowPlaying()
        case .ended:
            let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            configureSession(record: readExternalInput)
            restartAfterSystemStop()
            if readExternalInput { restartInputEngine() }
            if shouldResume && wasPlayingBeforeInterruption {
                play()
                log("Interruption ended · resumed on \(outputRouteName)")
                lastError = "Playback was interrupted and has resumed on \(outputRouteName). Check the show is in the right place."
            } else {
                log("Interruption ended · output \(outputRouteName)")
                if wasPlayingBeforeInterruption {
                    lastError = "Audio was interrupted by another app or a call. Playback is paused — press GO to resume."
                }
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ n: Notification) {
        let previous = (n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
            .map { AudioRoutes.name(for: $0) } ?? outputRouteName
        refreshRouteInfo()
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            if transport == .playing {
                graph?.core.setRun(false)
                transport = .paused
                updateNowPlaying()
                lastError = "\(previous) was disconnected. Playback paused so the show doesn't play out of the \(outputRouteName)."
            }
            log("\(previous) disconnected · now \(outputRouteName)")
        case .newDeviceAvailable:
            log("Output now \(outputRouteName)")
        default:
            break
        }
    }

    private func handleEngineConfigurationChange() {
        // The system stopped the engine (route / sample-rate / category change).
        refreshRouteInfo()
        let wasPlaying = transport == .playing
        let sameRoute = outputRouteName == routeAtPlay
        restartAfterSystemStop()
        if wasPlaying && !sameRoute {
            graph?.core.setRun(false)
            transport = .paused
            updateNowPlaying()
            if lastError == nil {
                lastError = "The audio output changed to \(outputRouteName). Playback paused — press GO to continue."
            }
            log("Output changed to \(outputRouteName) · paused")
        }
    }

    private func handleMediaServicesReset() {
        log("Audio system reset")
        teardownGraph()
        configureSession(record: readExternalInput)
        rebuildPreservingPosition(resume: false)
        if readExternalInput { restartInputEngine() }
        lastError = "The audio system was reset. Playback is paused — press GO to resume."
    }

    /// Restart (or rebuild, if the hardware rate changed) after the system stopped the engine.
    private func restartAfterSystemStop() {
        guard let g = graph else { return }
        let hwRate = g.engine.outputNode.outputFormat(forBus: 0).sampleRate
        if hwRate > 0 && abs(hwRate - g.core.sampleRate) > 0.5 {
            let resume = transport == .playing
            teardownGraph()
            rebuildPreservingPosition(resume: resume)
        } else {
            startEngineIfNeeded()
        }
    }

    private func teardownGraph() {
        if let g = graph {
            g.core.quiesce(renderActive: g.isRendering)
            g.stop()
        }
        streamer?.stop(); streamer = nil
        monitor?.stop(); monitor = nil
        if let o = engineObserver { NotificationCenter.default.removeObserver(o); engineObserver = nil }
        graph = nil
    }

    private func rebuildPreservingPosition(resume: Bool) {
        let src = source, r = routing, t = currentTime, state = transport
        guard src != .none else { _ = try? ensureGraph(); startEngineIfNeeded(); return }
        do {
            try load(src, routing: r)
            seek(to: t)
            if resume { play() } else if state == .paused { transport = .paused }
        } catch {
            transport = .stopped
        }
    }

    // MARK: - External input

    private func externalInputChanged() {
        ensureSetup()
        if readExternalInput {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.readExternalInput else { return }
                    if granted {
                        self.startInput()
                    } else {
                        self.lastError = "Microphone access is off. Allow it in Settings › TC Playback to read timecode from the input."
                        self.readExternalInput = false
                    }
                }
            }
        } else {
            stopInput()
            configureSession(record: false)
            followedExternal = nil
        }
    }

    private func startInput() {
        guard inputEngine == nil else { return }
        configureSession(record: true)
        _ = try? ensureGraph()
        startEngineIfNeeded()
        restartInputEngine()
    }

    private func restartInputEngine() {
        stopInput()
        let ie = AVAudioEngine()
        let input = ie.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else {
            lastError = "No audio input is available to read timecode from."
            return
        }
        let ring = SPSCRingBuffer(channels: min(2, Int(fmt.channelCount)), minimumCapacity: Int(fmt.sampleRate))
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            ring.write(UnsafePointer(ch[0]), buffer.format.channelCount > 1 ? UnsafePointer(ch[1]) : nil, count: n)
        }
        do {
            try ie.start()
        } catch {
            input.removeTap(onBus: 0)
            lastError = "The audio input couldn't be started."
            return
        }
        inputEngine = ie
        monitor?.setExternalInput(ring, sampleRate: fmt.sampleRate)
        log("Reading timecode from \(AudioRoutes.inputName(for: AVAudioSession.sharedInstance().currentRoute))")
    }

    private func stopInput() {
        if let ie = inputEngine {
            ie.inputNode.removeTap(onBus: 0)
            ie.stop()
        }
        inputEngine = nil
        monitor?.setExternalInput(nil, sampleRate: 0)
    }
}

extension EngineSource {
    var isGenerator: Bool { if case .generator = self { return true } else { return false } }
}
