import SwiftUI
import SwiftData
import Observation
import TCKit

/// Operator-facing banner (import progress, import errors, playback alerts).
struct ShellBanner: Equatable, Identifiable {
    enum Kind { case progress, info, warning, error }
    var id = UUID()
    var kind: Kind
    var text: String
}

/// UI state shared across the shell: sheets, banners, GO protection, routing edits.
@MainActor
@Observable
final class ShellModel {
    static let shared = ShellModel()

    let show: ShowController
    let engine: PlaybackEngine
    init(show: ShowController = .shared, engine: PlaybackEngine = .shared) {
        self.show = show; self.engine = engine
    }

    // MARK: Presentation
    var inspectorCue: Cue?
    var showInspector = false
    var showRenumber = false
    var showPlaylists = false
    var showSettings = false
    var showChecklist = false
    var showFullClock = false
    var showImporter = false
    /// iPhone: Show mode (Layout D) as a full-screen cover.
    var showShowMode = false
    /// Offer to turn on Show Lock (entering Show mode while unlocked).
    var offerShowLock = false
    /// iPad tool screens (slots for the Pads / Output test screens).
    var showPads = false
    var showOutputTest = false
    var showInputAnalyzer = false
    /// Scope page: device input and our output side by side.
    var showScope = false
    var showCameras = false
    var showCuePoints = false
    var banner: ShellBanner?
    /// Cue whose number is being edited inline in the list.
    var editingNumberCueID: UUID?
    /// iPhone page.
    var phonePage: PhonePage = .show
    enum PhonePage: String, CaseIterable, Identifiable {
        case show, cues, pads, more
        var id: String { rawValue }
        var label: String {
            switch self { case .show: "Show"; case .cues: "Cues"; case .pads: "Pads"; case .more: "More" }
        }
    }

    /// DEBUG `-uiDemo` only: stands in for ShowController.activeCue while the engine is a stub.
    var demoActiveCue: Cue?

    // MARK: Derived show state
    var playlist: Playlist? { show.playlist }
    var activeCue: Cue? { show.activeCue ?? demoActiveCue }
    var standbyCue: Cue? { show.standbyCue }
    var isRunning: Bool { engine.transport != .stopped && activeCue != nil }

    func isPlaying(_ cue: Cue) -> Bool { isRunning && activeCue?.id == cue.id }
    func isStandby(_ cue: Cue) -> Bool { standbyCue?.id == cue.id }

    /// The cue after `cue` in the current playlist.
    func cue(after cue: Cue?) -> Cue? {
        guard let cue, let cues = playlist?.orderedCues, let i = cues.firstIndex(where: { $0.id == cue.id }),
              i + 1 < cues.count else { return nil }
        return cues[i + 1]
    }

    var elapsed: TimeInterval { engine.currentTime }
    var activeDuration: TimeInterval {
        engine.duration > 0 ? engine.duration : (activeCue?.displayDuration ?? 0)
    }
    var remaining: TimeInterval? {
        let d = activeDuration
        return d > 0 ? max(0, d - elapsed) : nil
    }

    // MARK: GO protection + recovery
    private(set) var lastGoAt: Date?
    /// True during the double-GO window (GO shows a thin red ring).
    private(set) var goGuardActive = false
    /// The cue the last GO fired; "Back one" re-arms it as standby.
    private(set) var recoverableCue: Cue?
    private var guardTask: Task<Void, Never>?

    var doubleGoWindow: Double {
        UserDefaults.standard.object(forKey: SettingsKey.doubleGoWindow) as? Double ?? 1
    }
    var panicFade: Double {
        UserDefaults.standard.object(forKey: SettingsKey.panicFadeSeconds) as? Double ?? 1
    }

    func go() {
        guard standbyCue != nil else { return }
        let window = doubleGoWindow
        let now = Date()
        if window > 0, let last = lastGoAt, now.timeIntervalSince(last) < window { return }
        lastGoAt = now
        recoverableCue = standbyCue
        show.go()
        Haptics.go()
        guardTask?.cancel()
        if window > 0 {
            goGuardActive = true
            guardTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(window))
                guard !Task.isCancelled else { return }
                self?.goGuardActive = false
            }
        }
    }

    /// Re-arm the cue that was just fired (recovery from a mis-fire).
    func backOne() {
        guard let cue = recoverableCue else { return }
        show.standby(cue)
        recoverableCue = nil
        Haptics.tick()
    }
    var canBackOne: Bool {
        guard let r = recoverableCue else { return false }
        return standbyCue?.id != r.id && playlist?.cues.contains(where: { $0.id == r.id }) == true
    }

    /// Stop. With Show Lock on this is only reached after a 1 s hold, and fades (panic).
    func stop(locked: Bool) {
        Haptics.stop()
        if locked {
            PlaybackEngine.shared.stop(fadeOut: 1.0)
        } else {
            show.stop()
        }
        demoActiveCue = nil
    }

    func pauseResume() {
        guard activeCue != nil else { return }
        engine.togglePlayPause()
    }

    // MARK: Routing (live while a cue plays, otherwise the standby cue's saved routing)

    /// The cue whose routing the routing panel shows/edits.
    var routingCue: Cue? { isRunning ? activeCue : standbyCue }
    var routing: ChannelRouting {
        if isRunning { return engine.routing }
        return standbyCue?.routing ?? ChannelRouting()
    }
    func setRouting(_ r: ChannelRouting, context: ModelContext) {
        if isRunning {
            engine.routing = r
            show.commitRoutingToActiveCue()
            // Keep the stored cue in step even before the Library implementation lands.
            if let c = activeCue, c.routing != r { c.routing = r; try? context.save() }
        } else if let c = standbyCue {
            c.routing = r
            try? context.save()
        }
    }
    /// Edits made in the inspector to the active cue go live immediately.
    func cueRoutingEdited(_ cue: Cue) {
        if isRunning, activeCue?.id == cue.id {
            engine.routing = cue.routing
            show.commitRoutingToActiveCue()
        }
    }

    // MARK: Editing helpers

    func inspect(_ cue: Cue) {
        inspectorCue = cue
        showInspector = true
    }

    func open(_ playlist: Playlist) {
        show.open(playlist)
        UserDefaults.standard.set(playlist.id.uuidString, forKey: SettingsKey.currentPlaylistID)
    }

    /// Library stubs may hand back models that were never inserted; make sure they are.
    func ensureInserted(_ playlist: Playlist, context: ModelContext) {
        if playlist.modelContext == nil {
            let all = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
            playlist.sortIndex = (all.map(\.sortIndex).max() ?? -1) + 1
            context.insert(playlist)
            try? context.save()
        }
    }

    func addGeneratorCue(context: ModelContext) {
        guard let p = playlist else { return }
        let cue = PlaylistEditor.appendGenerator(to: p, context: context)
        if cue.modelContext == nil {
            cue.position = (p.cues.map(\.position).max() ?? -1) + 1
            cue.number = CueNumbering.next(after: p.cues.map(\.number))
            context.insert(cue)
            cue.playlist = p
            try? context.save()
        }
        if standbyCue == nil { show.standby(cue) }
        inspect(cue)
    }

    // MARK: Import

    func importAudio(_ urls: [URL], context: ModelContext) {
        guard !urls.isEmpty else { return }
        let showFiles = urls.filter { ["tcshow", "zip"].contains($0.pathExtension.lowercased()) }
        let audio = urls.filter { !showFiles.contains($0) }
        let count = audio.count
        Task {
            if count > 0 {
                banner = ShellBanner(kind: .progress, text: count == 1 ? "Importing \(audio[0].lastPathComponent)…" : "Importing \(count) files…")
                let scoped = audio.map { ($0, $0.startAccessingSecurityScopedResource()) }
                defer { for (u, s) in scoped where s { u.stopAccessingSecurityScopedResource() } }
                do {
                    let tracks = try await TrackImporter.importFiles(audio, into: context)
                    if let p = playlist, !tracks.isEmpty {
                        PlaylistEditor.append(tracks: tracks, to: p, context: context)
                        if standbyCue == nil, let first = p.orderedCues.first { show.standby(first) }
                    }
                    banner = ShellBanner(kind: .info, text: tracks.count == 1 ? "Imported \(tracks[0].title)" : "Imported \(tracks.count) tracks")
                } catch {
                    banner = ShellBanner(kind: .error, text: "Import failed: \(error.localizedDescription)")
                }
            }
            for url in showFiles { await importShow(url, context: context) }
            autoDismissBanner()
        }
    }

    func importShow(_ url: URL, context: ModelContext) async {
        banner = ShellBanner(kind: .progress, text: "Importing \(url.deletingPathExtension().lastPathComponent)…")
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let p = try await PlaylistEditor.importShow(from: url, context: context)
            ensureInserted(p, context: context)
            open(p)
            banner = ShellBanner(kind: .info, text: "Opened \(p.name)")
        } catch {
            banner = ShellBanner(kind: .error, text: "Couldn’t open show: \(error.localizedDescription)")
        }
        autoDismissBanner()
    }

    func handleOpenURL(_ url: URL, context: ModelContext) {
        TrackImporter.handleOpenURL(url, context: context)
    }

    private func autoDismissBanner() {
        guard let b = banner, b.kind == .info else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if banner?.id == b.id { withAnimation(.easeOut(duration: 0.2)) { banner = nil } }
        }
    }
}

// MARK: - Formatting

enum Fmt {
    /// "3:42", "1:02:05".
    static func duration(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "–:––" }
        return clock(t)
    }
    /// "0:00"-style clock time (always a value).
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(max(0, t.isFinite ? t : 0).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// Elapsed with tenths: "1:23.4".
    static func elapsed(_ t: TimeInterval) -> String {
        let t = max(0, t.isFinite ? t : 0)
        let s = Int(t), tenths = Int((t - Double(s)) * 10)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, sec, tenths) : String(format: "%d:%02d.%d", m, sec, tenths)
    }
    static func remaining(_ t: TimeInterval?) -> String {
        guard let t else { return "–:––" }
        return "−" + clock(t.rounded(.up))
    }
    static func dB(_ v: Float) -> String {
        if v <= -60 { return "−∞ dB" }
        let s = String(format: "%+.1f dB", v)
        return s.replacingOccurrences(of: "-", with: "−")
    }
    /// Drop-frame timecode uses a semicolon before frames.
    static func timecode(_ s: String, rate: FrameRate?) -> String {
        guard rate?.isDropFrame == true, let r = s.range(of: ":", options: .backwards) else { return s }
        return s.replacingCharacters(in: r, with: ";")
    }
}

// MARK: - Cue numbering

enum CueNumbering {
    /// Next whole number after the highest numeric cue number.
    static func next(after numbers: [String]) -> String {
        let maxN = numbers.compactMap { Double($0) }.max() ?? 0
        return format(Double(Int(maxN.rounded(.down)) + 1))
    }
    static func format(_ v: Double) -> String {
        if v.rounded() == v { return String(Int(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
    /// Numbers for `count` cues from `start` by `step`, skipping any number in `taken`.
    static func sequence(count: Int, start: Double, step: Double, taken: Set<String>) -> [String] {
        var out: [String] = []
        var v = start
        var guardCount = 0
        while out.count < count && guardCount < 100_000 {
            let s = format(v)
            if !taken.contains(s) { out.append(s) }
            v += step; guardCount += 1
        }
        return out
    }
}
