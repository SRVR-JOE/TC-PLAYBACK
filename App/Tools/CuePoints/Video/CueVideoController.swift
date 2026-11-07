import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import QuartzCore
import PhotosUI
import TCKit

/// Owns the video for the Cue points screen: the linked file, the AVPlayer and the loop that
/// keeps the picture on the track's playhead. The engine is the clock; the video never runs on
/// its own except in "pick a moment" mode while lining up.
@MainActor @Observable
final class CueVideoController {
    static let shared = CueVideoController()

    enum Mode: Equatable {
        /// The picture follows the track.
        case follow
        /// The picture is scrubbed on its own (to find a visible event while lining up).
        case free
    }

    private(set) var trackID: UUID?
    private(set) var link: CueVideoLink?
    private(set) var player: AVPlayer?
    /// Video length, seconds (0 until loaded).
    private(set) var duration: TimeInterval = 0
    /// The video's own frame rate (for frame steps in the video).
    private(set) var videoFPS: Double = 30
    /// Display aspect (width / height) after rotation.
    private(set) var aspect: CGFloat = 16 / 9
    /// The track time is outside the video ("No video at this time").
    private(set) var outOfRange = false
    /// Video time currently shown (approximately; for readouts).
    private(set) var shownVideoTime: TimeInterval = 0
    var mode: Mode = .follow {
        didSet { if mode != oldValue { modeChanged() } }
    }
    /// Video sound; off by default so the track is what you hear.
    var soundOn: Bool = UserDefaults.standard.bool(forKey: "cuePoints.video.sound") {
        didSet { UserDefaults.standard.set(soundOn, forKey: "cuePoints.video.sound"); player?.isMuted = !soundOn }
    }
    var showFilmstrip: Bool = UserDefaults.standard.object(forKey: "cuePoints.video.filmstrip") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFilmstrip, forKey: "cuePoints.video.filmstrip") }
    }
    var collapsed: Bool = UserDefaults.standard.bool(forKey: "cuePoints.video.collapsed") {
        didSet { UserDefaults.standard.set(collapsed, forKey: "cuePoints.video.collapsed") }
    }
    /// Panel height in the wide layout.
    var panelHeight: CGFloat = {
        let h = UserDefaults.standard.double(forKey: "cuePoints.video.height")
        return h > 0 ? CGFloat(h) : 240
    }() {
        didSet { UserDefaults.standard.set(Double(panelHeight), forKey: "cuePoints.video.height") }
    }
    /// The line-up sheet is open.
    var showingSync = false

    // Import
    /// 0…1 while a chosen video is being copied in; nil otherwise.
    private(set) var importProgress: Double?
    var importError: String?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importPhotoProgress: Progress?

    // Thumbnails for the timeline lane.
    let thumbnails = CueVideoThumbnails()

    // Follow loop
    @ObservationIgnored private var link_: CADisplayLink?
    @ObservationIgnored private var lastEngineTime: TimeInterval = -1
    @ObservationIgnored private var lastEngineHost: CFTimeInterval = 0
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var pendingSeek: (time: TimeInterval, exact: Bool)?
    @ObservationIgnored private var lastSeekTarget: TimeInterval = -1
    @ObservationIgnored private var lastSeekExact = true
    @ObservationIgnored private var lastTargetChange: CFTimeInterval = 0
    @ObservationIgnored private var driftSamples: [Double] = []
    @ObservationIgnored private var lastCorrection: CFTimeInterval = 0
    @ObservationIgnored private var attachCount = 0
    @ObservationIgnored private var loadGen = 0

    private let engine = PlaybackEngine.shared

    // MARK: Lifecycle

    /// Points the controller at a track (loads its video, if it has one). Safe to call repeatedly.
    func attach(trackID: UUID) {
        if self.trackID != trackID { load(trackID) }
    }

    /// Panels call these on appear / disappear; the follow loop runs while any is on screen.
    func panelAppeared() { attachCount += 1; startLoop() }
    func panelDisappeared() {
        attachCount = max(0, attachCount - 1)
        if attachCount == 0 { stopLoop(); player?.pause() }
    }

    private func load(_ id: UUID) {
        trackID = id
        mode = .follow
        setLink(CueVideoStore.load(id))
        #if DEBUG
        if link == nil, CueVideoDebugSeed.enabled {
            Task { if let l = await CueVideoDebugSeed.seedIfNeeded(trackID: id), self.trackID == id { self.setLink(l) } }
        }
        #endif
    }

    private func setLink(_ l: CueVideoLink?) {
        player?.pause()
        link = l
        loadGen += 1
        duration = 0; outOfRange = false; lastSeekTarget = -1
        thumbnails.reset(url: nil)
        guard let l else { player = nil; return }
        let url = CueVideoStore.url(for: l)
        guard FileManager.default.fileExists(atPath: url.path) else {
            player = nil; importError = "The video file is missing. Choose it again."; return
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = !soundOn
        p.automaticallyWaitsToMinimizeStalling = false
        p.actionAtItemEnd = .pause
        player = p
        thumbnails.reset(url: url)
        let gen = loadGen
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let d = (try? await asset.load(.duration).seconds) ?? 0
            var fps = 30.0, aspect: CGFloat = 16 / 9
            if let v = try? await asset.loadTracks(withMediaType: .video).first {
                if let r = try? await v.load(.nominalFrameRate), r > 1 { fps = Double(r) }
                if let s = try? await v.load(.naturalSize), let t = try? await v.load(.preferredTransform) {
                    let r = CGRect(origin: .zero, size: s).applying(t)
                    if r.height > 0 { aspect = abs(r.width) / abs(r.height) }
                }
            }
            guard let self, self.loadGen == gen else { return }
            self.duration = d.isFinite ? d : 0
            self.videoFPS = fps
            self.aspect = aspect
            self.thumbnails.aspect = aspect
            self.lastSeekTarget = -1
        }
    }

    // MARK: Offset

    func setOffset(_ o: TimeInterval) {
        guard var l = link, let id = trackID, o.isFinite else { return }
        l.offset = o
        link = l
        CueVideoStore.save(l, for: id)
        lastSeekTarget = -1
        driftSamples.removeAll()
    }

    func nudge(by s: TimeInterval) { if let l = link { setOffset(l.offset + s) } }

    /// "Line up here": the video frame on screen now belongs at the track's playhead.
    func lineUpHere() {
        let v = currentVideoTime
        setOffset(CueVideoLink.offset(trackTime: engine.currentTime, videoTime: v))
        mode = .follow
    }

    /// The picture's time right now (the seek target if a seek is under way).
    var currentVideoTime: TimeInterval {
        if let p = pendingSeek { return p.time }
        if seeking, lastSeekTarget >= 0 { return lastSeekTarget }
        return player.map { max(0, $0.currentTime().seconds.isFinite ? $0.currentTime().seconds : 0) } ?? 0
    }

    // MARK: Free scrubbing (line up by eye)

    func scrubVideo(to v: TimeInterval) {
        guard player != nil else { return }
        if mode != .follow { player?.pause() }
        let t = min(max(0, v), max(0, duration))
        shownVideoTime = t
        requestSeek(t, exact: false)
    }

    func stepVideo(frames: Int) {
        let f = 1 / max(1, videoFPS)
        let base = (currentVideoTime / f).rounded() * f
        let t = min(max(0, base + Double(frames) * f), max(0, duration))
        shownVideoTime = t
        requestSeek(t, exact: true)
    }

    private func modeChanged() {
        driftSamples.removeAll(); lastSeekTarget = -1
        if mode == .free {
            player?.pause()
            shownVideoTime = currentVideoTime
        }
    }

    // MARK: Import

    /// Copies a file chosen in Files (security-scoped) into the app, on a background task.
    func importFile(_ url: URL, for trackID: UUID) {
        cancelImport()
        importError = nil
        importProgress = 0
        let ext = url.pathExtension
        let name = url.deletingPathExtension().lastPathComponent
        importTask = Task { [weak self] in
            let dest = CueVideoStore.directory.appending(path: CueVideoStore.newFileName(for: trackID, ext: ext))
            do {
                try await CueVideoImport.copy(from: url, to: dest) { p in
                    Task { @MainActor in if self?.importProgress != nil { self?.importProgress = p } }
                }
                await MainActor.run { self?.finishImport(fileName: dest.lastPathComponent, displayName: name, for: trackID) }
            } catch {
                try? FileManager.default.removeItem(at: dest)
                await MainActor.run {
                    self?.importProgress = nil
                    if !(error is CancellationError) { self?.importError = "The video couldn't be copied. \(error.localizedDescription)" }
                }
            }
        }
    }

    /// Photos hands over a file through Transferable; its Progress drives the bar.
    func importPhoto(_ item: PhotosPickerItem, for trackID: UUID) {
        cancelImport()
        importError = nil
        importProgress = 0
        let progress = item.loadTransferable(type: CueVideoTransfer.self) { [weak self] result in
            Task { @MainActor in
                guard let self, self.importProgress != nil else {
                    // Cancelled while loading: drop the file that arrived anyway.
                    if case .success(let f?) = result { try? FileManager.default.removeItem(at: f.url) }
                    return
                }
                self.importPhotoProgress = nil
                switch result {
                case .success(let f?):
                    self.finishImport(fileName: f.url.lastPathComponent, displayName: f.displayName, for: trackID)
                case .success(nil):
                    self.importProgress = nil
                case .failure(let e):
                    self.importProgress = nil
                    if (e as NSError).code != NSUserCancelledError { self.importError = "The video couldn't be loaded from Photos. \(e.localizedDescription)" }
                }
            }
        }
        importPhotoProgress = progress
        // Poll the Progress (KVO from a background thread is noisier than it's worth here).
        importTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let p = self.importPhotoProgress else { return }
                if self.importProgress != nil { self.importProgress = p.fractionCompleted }
            }
        }
    }

    func cancelImport() {
        importTask?.cancel(); importTask = nil
        importPhotoProgress?.cancel(); importPhotoProgress = nil
        importProgress = nil
    }

    private func finishImport(fileName: String, displayName: String, for id: UUID) {
        importTask?.cancel(); importTask = nil
        importProgress = nil
        // Replacing: drop the old copy. A new recording starts at offset 0 (line it up again).
        if let old = CueVideoStore.load(id), old.fileName != fileName {
            try? FileManager.default.removeItem(at: CueVideoStore.url(for: old))
        }
        let l = CueVideoLink(fileName: fileName, offset: 0, rate: 1, displayName: displayName)
        CueVideoStore.save(l, for: id)
        if id == trackID { setLink(l); collapsed = false }
    }

    func removeVideo() {
        guard let id = trackID else { return }
        player?.pause()
        CueVideoStore.remove(id)
        mode = .follow
        setLink(nil)
    }

    // MARK: Follow loop

    private func startLoop() {
        guard link_ == nil else { return }
        let d = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.step() }, selector: #selector(DisplayLinkProxy.fire))
        d.add(to: .main, forMode: .common)
        link_ = d
    }

    private func stopLoop() { link_?.invalidate(); link_ = nil }

    /// Engine time now. The engine publishes at 30 Hz; while playing, extrapolate between ticks.
    private func engineNow(playing: Bool) -> TimeInterval {
        let t = engine.currentTime, now = CACurrentMediaTime()
        if t != lastEngineTime { lastEngineTime = t; lastEngineHost = now }
        guard playing else { return t }
        return t + min(0.1, now - lastEngineHost)
    }

    private func step() {
        guard let player, let link else { return }
        let playing = engine.transport == .playing
        let et = engineNow(playing: playing)
        if mode == .free { return }
        // What you hear is the engine position minus the output latency (matters on Bluetooth).
        let s = AVAudioSession.sharedInstance()
        let heard = playing ? et - (s.outputLatency + s.ioBufferDuration) : et
        let v = link.videoTime(atTrackTime: heard)
        let known = duration > 0
        let inRange = v >= -0.0005 && (!known || v <= duration + 0.0005)
        if outOfRange == inRange { outOfRange = !inRange }
        guard inRange else {
            if player.rate != 0 { player.pause() }
            return
        }
        let target = min(max(0, v), known ? duration : v)
        if abs(shownVideoTime - target) > 0.02 { shownVideoTime = target }
        if playing { followPlaying(player, target) } else { followParked(player, target) }
    }

    private func followPlaying(_ player: AVPlayer, _ target: TimeInterval) {
        let now = CACurrentMediaTime()
        if seeking { return }
        let pt = player.currentTime().seconds
        if player.rate == 0 {
            // Start: land a little ahead, the seek itself takes a moment.
            driftSamples.removeAll()
            requestSeek(target + 0.08, exact: true) { [weak player] in player?.rate = 1 }
            return
        }
        guard pt.isFinite else { return }
        let drift = pt - target          // + = picture ahead of the track
        driftSamples.append(drift)
        if driftSamples.count > 8 { driftSamples.removeFirst() }
        let avg = driftSamples.reduce(0, +) / Double(driftSamples.count)
        let frame = 1 / max(1, videoFPS)
        if abs(avg) > 0.4 {
            // Far out (jump, stall): reseek.
            driftSamples.removeAll()
            requestSeek(target + 0.08, exact: true) { [weak player] in player?.rate = 1 }
        } else if now - lastCorrection > 0.25, driftSamples.count >= 4 {
            lastCorrection = now
            // Within a frame: run at speed. Otherwise lean on the rate to pull it back in.
            let rate: Float = abs(avg) <= frame * 0.75 ? 1 : Float(1 - max(-0.05, min(0.05, avg * 0.5)))
            if abs(player.rate - rate) > 0.001 { player.rate = rate }
        }
    }

    private func followParked(_ player: AVPlayer, _ target: TimeInterval) {
        if player.rate != 0 { player.pause() }
        let now = CACurrentMediaTime()
        let frame = 1 / max(1, videoFPS)
        if abs(target - lastSeekTarget) > frame * 0.25 {
            // Moving: scrubbing fast decodes keyframe-near frames, then exact once it settles.
            let rapid = now - lastTargetChange < 0.08
            lastTargetChange = now
            requestSeek(target, exact: !rapid)
        } else if !lastSeekExact, now - lastTargetChange > 0.12, !seeking {
            requestSeek(target, exact: true)
        }
    }

    /// Seek, coalescing requests: while one is in flight only the newest is kept.
    private func requestSeek(_ t: TimeInterval, exact: Bool, then: (() -> Void)? = nil) {
        guard let player else { return }
        lastSeekTarget = t
        lastSeekExact = exact
        if seeking { pendingSeek = (t, exact); pendingThen = then; return }
        seeking = true
        let tol = exact ? CMTime.zero : CMTime(seconds: 0.15, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 60_000), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if let p = self.pendingSeek {
                    self.pendingSeek = nil
                    let next = self.pendingThen; self.pendingThen = nil
                    self.requestSeek(p.time, exact: p.exact, then: next)
                } else {
                    then?()
                }
            }
        }
    }
    @ObservationIgnored private var pendingThen: (() -> Void)?

    // MARK: Timeline hook

    /// The film-strip lane for `TimelineEditor`, or nil when there's no video or it's hidden.
    var timelineLane: ((TimeInterval, TimeInterval) -> AnyView)? {
        guard link != nil, showFilmstrip else { return nil }
        return { origin, span in AnyView(CueVideoFilmstripLane(origin: origin, span: span)) }
    }
}

/// CADisplayLink retains its target; this keeps the controller out of that cycle.
private final class DisplayLinkProxy: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// A movie handed over by Photos, already moved into Application Support/CueVideos.
struct CueVideoTransfer: Transferable {
    let url: URL
    var displayName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension
            let dest = CueVideoStore.directory.appending(path: "incoming-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "mov" : ext)")
            do { try FileManager.default.moveItem(at: received.file, to: dest) } catch {
                try FileManager.default.copyItem(at: received.file, to: dest)
            }
            return CueVideoTransfer(url: dest, displayName: received.file.deletingPathExtension().lastPathComponent)
        }
    }
}

enum CueVideoImport {
    static let fileTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]

    /// Chunked copy so a multi-gigabyte show recording reports progress and can be cancelled.
    static func copy(from src: URL, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let total = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let input = try FileHandle(forReadingFrom: src)
            let output = try FileHandle(forWritingTo: dest)
            defer { try? input.close(); try? output.close() }
            var done = 0.0, lastReport = 0.0
            while true {
                try Task.checkCancellation()
                let chunk = try autoreleasepool { try input.read(upToCount: 4 << 20) }
                guard let chunk, !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                done += Double(chunk.count)
                if total > 0, done - lastReport > total * 0.01 { lastReport = done; progress(min(1, done / total)) }
            }
            progress(1)
        }.value
    }
}
