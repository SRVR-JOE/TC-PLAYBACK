import Foundation
import Observation
import QuartzCore
import SwiftData
import TCKit

/// The cue caller: follows timecode and speaks each mark's call note over comms, per area.
///
/// API for the UI (bind to `CueCaller.shared`, main actor):
/// - `settings: CueCallerSettings` — read/write; every change is saved and the calls are rebuilt.
/// - `isEngaged: Bool` — read/write; the master toggle (`settings.enabled`).
/// - `status: CueCaller.Status` (`.idle`, `.following`, `.waitingForTimecode`, `.timecodeLost`),
///   with `status.label` for display.
/// - `lastCall: CueCall?` — the call that last started speaking.
/// - `nextCall: CueCall?` and `nextCallIn: TimeInterval?` — the next call and seconds until it
///   starts speaking (updated ~20×/s while following).
/// - `trackTitle: String?` — the track being followed.
/// - `outputChannelCount: Int` — hardware outputs available now (2 on a stereo output).
/// - `problem(for: area) -> String?` — e.g. channels that this output doesn't have.
/// - `test(area:)` — speak a sample call in that area now (works with the toggle off).
/// - `prepare(track:)` — load a track's marks and pre-render its calls (call when a track is
///   opened for editing; playback picks up the playing track on its own).
/// - `translator` / `renderer` — injected; the language part sets `AppleCueCallTranslator()` and
///   `SpeechCueCallRenderer()`. The translator returns only the translated note.
/// - `phrase: CueCallPhrase?` — optional (kind, note, language) → spoken line, e.g.
///   `{ CueCallTemplates.text($0, note: $1, language: $2) }`; nil = built-in wording.
/// - `renderStep: CueCallRenderStep?` — optional render that also reports the go word's sample
///   onset (wrap `SpeechCueCallRenderer.renderGo(note:template:…)` → `CueCallAudio.goOnset`);
///   go calls then start at mark − onset. nil = `renderer.render(text…)`, the end lands on the mark.
/// Calls start and stop with the transport (or incoming LTC) and with the toggle.
@MainActor
@Observable
final class CueCaller {
    static let shared = CueCaller()

    enum Status: Equatable {
        case idle, following, waitingForTimecode, timecodeLost
        var label: String {
            switch self {
            case .idle: "Idle"
            case .following: "Following"
            case .waitingForTimecode: "Waiting for timecode"
            case .timecodeLost: "Timecode lost"
            }
        }
    }

    var settings: CueCallerSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(defaults)
            if settings.enabled != oldValue.enabled || settings.source != oldValue.source { engagementChanged() }
            replan()
        }
    }
    var isEngaged: Bool {
        get { settings.enabled }
        set { settings.enabled = newValue }
    }
    private(set) var status: Status = .idle
    private(set) var lastCall: CueCall?
    private(set) var nextCall: CueCall?
    private(set) var nextCallIn: TimeInterval?
    private(set) var trackTitle: String?
    private(set) var outputChannelCount = 2

    @ObservationIgnored var translator: any CueCallTranslator = PassthroughCueCallTranslator()
    @ObservationIgnored var renderer: any CueCallVoiceRenderer = StubCueCallRenderer() { didSet { clearRenders() } }
    @ObservationIgnored var phrase: CueCallPhrase? { didSet { replan() } }
    @ObservationIgnored var renderStep: CueCallRenderStep? { didSet { clearRenders() } }
    /// The language call notes are written in.
    @ObservationIgnored var noteLanguage: String = Locale.current.language.minimalIdentifier
    /// Crew corrections per stacked line (the language part sets the translation store's lookup).
    @ObservationIgnored var lineOverride: CueCallLineOverride? { didSet { replan() } }
    /// Renamed cameras ("Jib", "Steadicam"), recognised at the start of a line for the short standby.
    @ObservationIgnored var cameraNames: [String] = [] { didSet { if cameraNames != oldValue { replan() } } }
    @ObservationIgnored var defaults: UserDefaults = .standard

    // MARK: Internals
    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var marks: [CueCallMark] = []
    @ObservationIgnored private var marksTrackID: UUID?
    @ObservationIgnored private var followedURL: URL?
    @ObservationIgnored private var clock: CuePointClock?
    @ObservationIgnored private var trackDuration: TimeInterval = 0
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private(set) var calls: [CueCall] = []
    @ObservationIgnored private(set) var timeline: [TimedCueCall] = []
    @ObservationIgnored private var follower = CueCallFollower()
    @ObservationIgnored private var tcClock = CueCallTimecodeClock()
    @ObservationIgnored private var planGen = 0
    @ObservationIgnored private var notes: [CueCallKey: String] = [:]
    @ObservationIgnored private var cache: [RenderKey: CueCallRenderedAudio] = [:]
    @ObservationIgnored private var cacheOrder: [RenderKey] = []
    @ObservationIgnored private var pendingRenders: [(key: RenderKey, call: CueCall, note: String, area: CueCallArea)] = []
    @ObservationIgnored private var rendering = false
    @ObservationIgnored private var renderGen = 0
    @ObservationIgnored private var failedRenders: Set<RenderKey> = []
    @ObservationIgnored private var tags: [Int: TimedCueCall] = [:]
    @ObservationIgnored private var nextTag = 1
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var lastRaw: TimeInterval = -1
    @ObservationIgnored private var lastRawAt: CFTimeInterval = 0
    @ObservationIgnored private var lastHousekeeping: CFTimeInterval = 0
    @ObservationIgnored private var renderClockSeen = -1
    @ObservationIgnored private var renderClockSeenAt: CFTimeInterval = 0
    @ObservationIgnored private var enabledInput = false
    @ObservationIgnored private var hadTimecode = false
    @ObservationIgnored private var testVoices = 0
    #if DEBUG
    /// Self-test log: every voice start/end the mixer reported.
    @ObservationIgnored var debugReports: [(call: TimedCueCall, report: CueCallMixer.Report, sampleRate: Double)] = []
    #endif

    struct RenderKey: Hashable {
        let text: String, language: String, voiceID: String?, rate: Float, sampleRate: Double
    }

    init(engine: PlaybackEngine = .shared, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        settings = CueCallerSettings.load(defaults)
        if settings.enabled { engagementChanged() }
    }

    // MARK: Public API

    /// Use this context to look tracks up (LTC follow) and re-read marks. Optional: the playing
    /// track's own context is used when there is one.
    func attach(_ context: ModelContext) { self.context = context }

    /// Load `track`'s marks and pre-render its calls.
    func prepare(track: Track) {
        if let ctx = track.modelContext { context = ctx }
        pinned = false
        load(track: track)
    }

    /// Follow these marks whenever `fileURL` is the playing item (tests and the self-test).
    func prepare(marks: [CueCallMark], fileURL: URL?, clock: CuePointClock? = nil, duration: TimeInterval = 0) {
        pinned = true
        followedURL = fileURL
        marksTrackID = nil
        self.clock = clock
        trackDuration = duration
        trackTitle = fileURL?.deletingPathExtension().lastPathComponent
        setMarks(marks)
    }

    /// Speak a sample call in `area` now, on its channels, whatever the toggle and transport.
    func test(area: CueCallArea) {
        engine.startOutputForCalls()
        let gen = planGen
        Task { [weak self] in
            guard let self else { return }
            let sample = "Camera 3, push in slow"
            let one = CueCallerSettings(enabled: true, source: .playback, standbyLead: 0, sayStandby: false,
                                        includeMarkName: false, dedicatedCallChannels: self.settings.dedicatedCallChannels,
                                        onlyMarksWithNotes: true, areas: [area])
            let built = await CueCallScheduler.prepare(marks: [CueCallMark(time: 0, note: sample)], settings: one,
                                                       noteLanguage: "en-US", translator: self.translator, phrase: self.phrase)
            guard let first = built.first, let mixer = self.engine.cueCallMixer else { return }
            let call = first.call
            let sr = mixer.sampleRate
            guard let audio = await self.renderNow(call, note: first.note, area: area, sampleRate: sr) else { return }
            let pcm = audio.samples
            _ = gen
            let tag = self.newTag(TimedCueCall(call: call, start: 0, duration: Double(pcm.count) / sr))
            if mixer.play(pcm, clock: .render, startFrame: 0, channels: self.channels(for: area),
                          gain: Float(RoutingMath.linearGain(dB: Float(area.gainDB))), tag: tag) {
                self.testVoices += 1
                self.startTimer()
            }
        }
    }

    /// Why an area may not be heard on the current output; nil when it's fine.
    func problem(for area: CueCallArea) -> String? {
        let n = engine.outputChannelCount
        let missing = area.outputChannels.filter { $0 >= n }
        if area.outputChannels.isEmpty { return "No output channels chosen." }
        if missing.count == area.outputChannels.count {
            return "This output has \(n) channels; \(area.name) is on \(Self.channelList(area.outputChannels))."
        }
        if !missing.isEmpty { return "Channels \(Self.channelList(missing)) aren't on this output (\(n) channels)." }
        return nil
    }

    /// The rate calls are rendered at (the call mixer's, else the hardware's).
    var renderSampleRate: Double { sampleRate }

    /// The marks the caller has loaded (the playing or prepared track), for "Prepare calls".
    var loadedMarks: [CueCallMark] { marks }

    /// Drop rendered audio and render again (after calls were prepared offline, so calls that
    /// fell back to the device voice pick up the prepared ones).
    func reloadRenders() { clearRenders() }

    static func channelList(_ ch: [Int]) -> String { ch.map { String($0 + 1) }.joined(separator: ", ") }

    // MARK: Engagement

    private func engagementChanged() {
        follower.reset(); tcClock.reset(); hadTimecode = false
        engine.cueCallMixer?.fadeAll()
        if settings.enabled {
            if settings.source == .ltcInput {
                if !engine.readExternalInput { engine.readExternalInput = true; enabledInput = true }
            } else {
                releaseInput()
            }
            startTimer()
        } else {
            releaseInput()
            status = .idle; nextCall = nil; nextCallIn = nil
        }
    }

    private func releaseInput() {
        if enabledInput { engine.readExternalInput = false; enabledInput = false }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 50, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastTick = CACurrentMediaTime()
    }

    private func stopTimerIfIdle() {
        guard !settings.enabled, testVoices == 0 else { return }
        timer?.invalidate(); timer = nil
    }

    // MARK: Marks and planning

    private func load(track: Track) {
        followedURL = track.fileURL
        marksTrackID = track.id
        clock = CuePointClock.forTrack(track)
        trackDuration = track.duration
        trackTitle = track.title
        if let ctx = track.modelContext ?? context {
            setMarks(CuePoint.points(for: track.id, in: ctx).map(CueCallMark.init))
        }
    }

    private func setMarks(_ m: [CueCallMark]) {
        let sorted = m.sorted { ($0.time, $0.id.uuidString) < ($1.time, $1.id.uuidString) }
        guard sorted != marks || calls.isEmpty else { return }
        marks = sorted
        replan()
    }

    /// One frame at the followed track's rate (marks this close stack into one call).
    private var frameDuration: TimeInterval { clock.map { 1 / $0.rate.fps } ?? 1.0 / 30 }

    /// The calls `marks` would make with the caller's current settings, translator, wording,
    /// corrections and cameras (also used to prepare voices offline, so the texts match).
    func preparedCalls(for marks: [CueCallMark]) async -> [PreparedCueCall] {
        await CueCallScheduler.prepare(marks: marks, settings: settings, noteLanguage: noteLanguage, translator: translator,
                                       phrase: phrase, lineOverride: lineOverride, cameraNames: cameraNames, frame: frameDuration)
    }

    private func replan() {
        planGen += 1
        let gen = planGen, marks = marks, settings = settings
        let translator = translator, lang = noteLanguage, phrase = phrase
        let lineOverride = lineOverride, cameraNames = cameraNames, frame = frameDuration
        Task { [weak self] in
            let prepared = await CueCallScheduler.prepare(marks: marks, settings: settings, noteLanguage: lang,
                                                          translator: translator, phrase: phrase, lineOverride: lineOverride,
                                                          cameraNames: cameraNames, frame: frame)
            guard let self, gen == self.planGen else { return }
            let built = prepared.map(\.call)
            self.notes = Dictionary(prepared.map { (CueCallKey(markID: $0.call.markID, areaID: $0.call.areaID, kind: $0.call.kind), $0.note) },
                                    uniquingKeysWith: { a, _ in a })
            self.calls = built
            self.rebuildTimeline()
            self.requestRenders(for: built)
        }
    }

    private var sampleRate: Double { engine.cueCallMixer?.sampleRate ?? engine.hardwareSampleRate }

    private func area(_ id: UUID) -> CueCallArea? { settings.areas.first { $0.id == id } }

    private func key(_ text: String, area: CueCallArea, sampleRate: Double) -> RenderKey {
        RenderKey(text: text, language: area.language, voiceID: area.voiceID, rate: area.rate, sampleRate: sampleRate)
    }

    private func rebuildTimeline() {
        let sr = sampleRate
        timeline = CueCallScheduler.timeline(calls, timing: { c in
            guard let a = self.area(c.areaID) else { return CueCallTiming(duration: 0, estimated: true) }
            if let audio = self.cache[self.key(c.text, area: a, sampleRate: sr)] {
                return CueCallTiming(duration: Double(audio.samples.count) / sr, goOnset: audio.goOnset.map { Double($0) / sr })
            }
            return CueCallTiming(duration: CueCallScheduler.estimatedDuration(c.text, rate: a.rate), estimated: true)
        })
    }

    /// Queue renders, soonest first. Anything missing is re-queued from the tick ≥ 10 s ahead.
    private func requestRenders(for list: [CueCall]) {
        let sr = sampleRate
        let now = currentTrackTime ?? -.infinity
        let ordered = list.sorted { a, b in
            let fa = a.at >= now, fb = b.at >= now
            return fa != fb ? fa : a.at < b.at
        }
        for c in ordered {
            guard let a = area(c.areaID) else { continue }
            let k = key(c.text, area: a, sampleRate: sr)
            if cache[k] == nil, !pendingRenders.contains(where: { $0.key == k }), !failedRenders.contains(k) {
                let note = notes[CueCallKey(markID: c.markID, areaID: c.areaID, kind: c.kind)] ?? ""
                pendingRenders.append((k, c, note, a))
            }
        }
        pumpRenders()
    }

    private func pumpRenders() {
        guard !rendering, !pendingRenders.isEmpty else { return }
        rendering = true
        let job = pendingRenders.removeFirst()
        let gen = renderGen
        Task { [weak self] in
            guard let self else { return }
            let audio = await self.render(job.call, note: job.note, area: job.area, sampleRate: job.key.sampleRate)
            self.rendering = false
            if gen == self.renderGen {
                if let audio { self.store(audio, for: job.key); self.rebuildTimeline() } else { self.failedRenders.insert(job.key) }
            }
            self.pumpRenders()
        }
    }

    /// One render through the injected step (with go onset) or the plain renderer.
    private func render(_ call: CueCall, note: String, area: CueCallArea, sampleRate sr: Double) async -> CueCallRenderedAudio? {
        let audio: CueCallRenderedAudio?
        if let step = renderStep {
            audio = try? await step(call, note, area, sr)
        } else if let pcm = try? await renderer.render(call.text, language: area.language, voiceID: area.voiceID,
                                                        rate: area.rate, sampleRate: sr) {
            audio = CueCallRenderedAudio(samples: pcm)
        } else {
            audio = nil
        }
        guard var a = audio, !a.samples.isEmpty else { return nil }
        if call.kind != .go { a.goOnset = nil }
        if let o = a.goOnset { a.goOnset = min(max(0, o), a.samples.count) }
        return a
    }

    private func renderNow(_ call: CueCall, note: String, area: CueCallArea, sampleRate sr: Double) async -> CueCallRenderedAudio? {
        let k = key(call.text, area: area, sampleRate: sr)
        if let hit = cache[k] { return hit }
        guard let a = await render(call, note: note, area: area, sampleRate: sr) else { return nil }
        store(a, for: k)
        return a
    }

    /// Drop rendered audio (the voice source changed); the next tick re-renders what's coming up.
    private func clearRenders() {
        renderGen += 1
        cache = [:]; cacheOrder = []; pendingRenders = []; failedRenders = []
        rebuildTimeline()
        requestRenders(for: calls)
    }

    private func store(_ audio: CueCallRenderedAudio, for k: RenderKey) {
        if cache[k] == nil { cacheOrder.append(k) }
        cache[k] = audio
        while cacheOrder.count > 400 { cache[cacheOrder.removeFirst()] = nil }
    }

    // MARK: Time

    /// Track time now in the active source's domain (rendered frames for playback, smoothed LTC).
    @ObservationIgnored private var currentTrackTime: TimeInterval?

    private func playbackTime(now: CFTimeInterval) -> TimeInterval? {
        guard engine.transport == .playing else { lastRaw = -1; return nil }
        let raw = engine.preciseTime
        if raw != lastRaw { lastRaw = raw; lastRawAt = now }
        return raw + min(max(0, now - lastRawAt), 0.05)
    }

    private func resolvePlaybackTrack() {
        guard case .file(let url) = engine.source else { return }
        if url == followedURL { return }
        if pinned { return }
        if let t = ShowController.shared.activeCue?.track, t.fileURL == url { load(track: t); return }
        if let ctx = context, let t = try? ctx.fetch(FetchDescriptor<Track>()).first(where: { $0.fileURL == url }) { load(track: t) }
    }

    /// Track time from incoming LTC, choosing the track whose timeline contains it.
    private func ltcTime(now: CFTimeInterval) -> TimeInterval? {
        let cs = engine.clock
        guard cs.source == .externalInput, cs.lock == .locked || cs.lock == .freewheel, !cs.isReverse,
              let tc = cs.timecode else { return nil }
        if !pinned { chooseTrack(for: tc) }
        guard let clock else { return nil }
        let reading = tc.realSeconds - clock.start.realSeconds
        if trackDuration > 0, reading < -30 || reading > trackDuration + 30 { return nil }
        return tcClock.update(reading: reading, frame: 1 / tc.rate.fps, host: now)
    }

    private func chooseTrack(for tc: Timecode) {
        func contains(_ c: CuePointClock, _ d: TimeInterval) -> Bool {
            let t = tc.realSeconds - c.start.realSeconds
            return t >= -max(settings.standbyLead, 5) && t <= d
        }
        if let c = clock, marksTrackID != nil, contains(c, trackDuration) { return }
        let ctx = context ?? ShowController.shared.playlist?.modelContext
        guard let ctx, let tracks = try? ctx.fetch(FetchDescriptor<Track>()) else { return }
        if let t = tracks.first(where: { contains(CuePointClock.forTrack($0), $0.duration) }), t.id != marksTrackID {
            context = ctx
            load(track: t)
            follower.reset(); tcClock.reset()
        }
    }

    /// Render-clock frame at which audio is heard at track time `t` (LTC follow).
    private func renderFrame(forTrackTime t: TimeInterval, now: TimeInterval, mixer: CueCallMixer, host: CFTimeInterval) -> Int {
        let rc = mixer.renderClock.load(ordering: .acquiring)
        if rc != renderClockSeen { renderClockSeen = rc; renderClockSeenAt = host }
        let renderNow = Double(rc) + min(0.05, host - renderClockSeenAt) * mixer.sampleRate
        let lead = t - now - engine.measuredOutputLatency
        return Int((renderNow + lead * mixer.sampleRate).rounded())
    }

    // MARK: Tick

    private func tick() {
        let host = CACurrentMediaTime()
        let elapsed = host - lastTick
        lastTick = host
        let mixer = engine.cueCallMixer
        if let mixer { drain(mixer) }
        if outputChannelCount != engine.outputChannelCount { outputChannelCount = engine.outputChannelCount }
        guard settings.enabled else { stopTimerIfIdle(); return }

        // Time source.
        var time: TimeInterval?
        switch settings.source {
        case .playback:
            resolvePlaybackTrack()
            if case .file(let url) = engine.source, url == followedURL { time = playbackTime(now: host) }
            setStatus(time == nil ? .idle : .following)
        case .ltcInput:
            time = ltcTime(now: host)
            if time != nil { hadTimecode = true; setStatus(.following) }
            else {
                tcClock.reset()
                setStatus(hadTimecode ? .timecodeLost : .waitingForTimecode)
            }
        }
        currentTrackTime = time

        // Housekeeping: re-read marks, keep the next 10+ s rendered.
        if host - lastHousekeeping > 1 {
            lastHousekeeping = host
            if !pinned, let id = marksTrackID, let ctx = context ?? ShowController.shared.activeCue?.track?.modelContext {
                setMarks(CuePoint.points(for: id, in: ctx).map(CueCallMark.init))
            }
            if let t = time {
                let soon = timeline.filter { $0.start >= t - 1 && $0.start <= t + 15 }.map(\.call)
                failedRenders = []
                requestRenders(for: soon)
            }
        }

        // Follow.
        for action in follower.update(time: time, elapsed: elapsed, calls: timeline) {
            switch action {
            case .cancelAll:
                mixer?.fadeAll()
            case .arm(let tc):
                guard let mixer, let t = time else { continue }
                arm(tc, mixer: mixer, now: t, host: host)
            }
        }

        // Readouts.
        if let t = time, let next = timeline.first(where: { $0.start > t }) {
            if nextCall != next.call { nextCall = next.call }
            let left = (next.start - t * 1).rounded(toPlaces: 1)
            if nextCallIn != left { nextCallIn = left }
        } else {
            if nextCall != nil { nextCall = nil }
            if nextCallIn != nil { nextCallIn = nil }
        }
    }

    private func setStatus(_ s: Status) { if status != s { status = s } }

    private func arm(_ tc: TimedCueCall, mixer: CueCallMixer, now: TimeInterval, host: CFTimeInterval) {
        guard let a = area(tc.call.areaID), a.enabled else { return }
        let sr = mixer.sampleRate
        guard let pcm = cache[key(tc.call.text, area: a, sampleRate: sr)]?.samples else { return } // not rendered in time: skip
        let clockKind: CueCallMixer.Clock = settings.source == .playback ? .track : .render
        let start: Int, fadeAt: Int?
        if clockKind == .track {
            start = Int((tc.start * sr).rounded())
            fadeAt = tc.cutAt.map { Int(($0 * sr).rounded()) }
        } else {
            start = renderFrame(forTrackTime: tc.start, now: now, mixer: mixer, host: host)
            fadeAt = tc.cutAt.map { renderFrame(forTrackTime: $0, now: now, mixer: mixer, host: host) }
        }
        let tag = newTag(tc)
        mixer.play(pcm, clock: clockKind, startFrame: start, channels: channels(for: a),
                   gain: RoutingMath.linearGain(dB: Float(a.gainDB)), fadeAt: fadeAt, tag: tag)
    }

    /// The area's channels; with shared (non-dedicated) call channels the calls also go into
    /// the program pair (outputs 1–2).
    private func channels(for a: CueCallArea) -> [Int] {
        var ch = a.outputChannels
        if !settings.dedicatedCallChannels { ch += [0, 1].filter { !ch.contains($0) } }
        return ch
    }

    private func newTag(_ tc: TimedCueCall) -> Int {
        let t = nextTag; nextTag += 1
        tags[t] = tc
        return t
    }

    private func drain(_ mixer: CueCallMixer) {
        for r in mixer.drainReports() {
            guard let tc = tags[r.tag] else { continue }
            if r.endedAt == nil {
                lastCall = tc.call
            } else {
                tags[r.tag] = nil
                if tc.start == 0 && tc.call.at == 0 && testVoices > 0 { testVoices -= 1 }
            }
            #if DEBUG
            debugReports.append((tc, r, mixer.sampleRate))
            #endif
        }
        mixer.reclaim()
        if testVoices > 0 && mixer.activeCount == 0 { testVoices = 0 }
        if testVoices == 0 { stopTimerIfIdle() }
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double { let m = pow(10, Double(p)); return (self * m).rounded() / m }
}
