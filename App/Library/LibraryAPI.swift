import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

// CONTRACT FILE — owned by the LIBRARY agent. Implement bodies; keep signatures.

/// Imports audio into the library (copy into Documents/Tracks, read metadata, compute the
/// waveform overview and scan for LTC in the background).
@MainActor
enum TrackImporter {
    /// Audio types accepted by the file importer / drop targets.
    static let contentTypes: [UTType] = [.audio, .wav, .aiff, .mp3, .mpeg4Audio]

    /// Import one or more security-scoped URLs. Returns the created Tracks (already inserted).
    /// Analysis (overview + LTC scan) continues in the background and updates the models.
    /// Throws `LibraryError` — `.partial` when some files imported and others didn't.
    @discardableResult
    static func importFiles(_ urls: [URL], into context: ModelContext) async throws -> [Track] {
        var tracks: [Track] = []
        var failures: [(String, Error)] = []
        for url in urls {
            do {
                let p = try await prepare(url)
                let t = Track(title: p.title, fileName: p.fileName, duration: p.duration,
                              sampleRate: p.sampleRate, channelCount: p.channelCount)
                t.contentHash = p.contentHash
                context.insert(t)
                tracks.append(t)
            } catch {
                failures.append((url.lastPathComponent, error))
            }
        }
        if !tracks.isEmpty {
            PlaylistEditor.save(context)
            for t in tracks { startAnalysis(for: t, context: context) }
        }
        if let first = failures.first {
            if tracks.isEmpty && failures.count == 1 { throw first.1 }
            if tracks.isEmpty, let e = first.1 as? LibraryError, failures.allSatisfy({ ($0.1 as? LibraryError) == e }) { throw e }
            throw LibraryError.partial(imported: tracks.count, failed: failures.map(\.0))
        }
        return tracks
    }

    /// Delete a track and its file (cues referencing it are removed too).
    static func delete(_ track: Track, context: ModelContext) {
        let allCues = (try? context.fetch(FetchDescriptor<Cue>())) ?? []
        let using = allCues.filter { $0.track?.id == track.id }
        PlaylistEditor.announceDeletion(of: using)
        let ids = Set(using.map(\.id))
        let playlists = Dictionary(grouping: using.compactMap(\.playlist), by: \.id).compactMap(\.value.first)
        for cue in using { context.delete(cue) }
        for p in playlists {
            p.cues.removeAll { ids.contains($0.id) }
            PlaylistEditor.compact(p)
            p.updatedAt = .now
        }
        try? FileManager.default.removeItem(at: track.fileURL)
        context.delete(track)
        PlaylistEditor.save(context)
    }
}

/// Playlist editing operations (all save the context).
@MainActor
enum PlaylistEditor {
    static func createPlaylist(named name: String, context: ModelContext) -> Playlist {
        let p = Playlist(name: name, sortIndex: nextSortIndex(context))
        context.insert(p)
        save(context)
        return p
    }

    /// Deep copy of the cues (new ids); tracks are shared.
    static func duplicate(_ playlist: Playlist, context: ModelContext) -> Playlist {
        let p = Playlist(name: "\(playlist.name) copy", sortIndex: nextSortIndex(context))
        context.insert(p)
        for (i, c) in playlist.orderedCues.enumerated() {
            let n = copy(c, position: i, number: c.number)
            context.insert(n)
            p.cues.append(n)
        }
        save(context)
        return p
    }

    static func delete(_ playlist: Playlist, context: ModelContext) {
        announceDeletion(of: playlist.cues, playlistID: playlist.id)
        context.delete(playlist)
        save(context)
        let rest = ((try? context.fetch(FetchDescriptor<Playlist>())) ?? []).sorted { $0.sortIndex < $1.sortIndex }
        for (i, p) in rest.enumerated() where p.sortIndex != i { p.sortIndex = i }
        save(context)
    }

    /// Append track cues (number = next integer after the highest numeric cue number).
    static func append(tracks: [Track], to playlist: Playlist, context: ModelContext) {
        compact(playlist)
        var position = playlist.cues.count
        for track in tracks {
            let cue = Cue(position: position, number: nextCueNumber(in: playlist), title: track.title, kind: .track, track: track)
            context.insert(cue)
            playlist.cues.append(cue)
            position += 1
        }
        touch(playlist, context: context)
    }

    static func appendGenerator(to playlist: Playlist, context: ModelContext) -> Cue {
        compact(playlist)
        let cue = Cue(position: playlist.cues.count, number: nextCueNumber(in: playlist), title: "LTC Generator", kind: .generator)
        context.insert(cue)
        playlist.cues.append(cue)
        touch(playlist, context: context)
        return cue
    }

    /// SwiftUI `.onMove` semantics. Cue numbers never change on a move.
    static func move(in playlist: Playlist, from source: IndexSet, to destination: Int, context: ModelContext) {
        var order = playlist.orderedCues
        let valid = source.filter { $0 >= 0 && $0 < order.count }
        guard !valid.isEmpty else { return }
        let moving = valid.map { order[$0] }
        let dest = min(order.count, max(0, destination)) - valid.filter { $0 < destination }.count
        for i in valid.sorted(by: >) { order.remove(at: i) }
        order.insert(contentsOf: moving, at: max(0, min(order.count, dest)))
        compact(playlist, order: order)
        touch(playlist, context: context)
    }

    static func delete(cues: [Cue], from playlist: Playlist, context: ModelContext) {
        let ids = Set(cues.map(\.id))
        let doomed = playlist.cues.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return }
        announceDeletion(of: doomed)
        let remaining = playlist.orderedCues.filter { !ids.contains($0.id) }
        playlist.cues.removeAll { ids.contains($0.id) }
        for c in doomed { context.delete(c) }
        compact(playlist, order: remaining)
        touch(playlist, context: context)
    }

    /// Inserts a copy directly after `cue`, numbered after the highest numeric cue number.
    static func duplicate(cue: Cue, in playlist: Playlist, context: ModelContext) {
        var order = playlist.orderedCues
        guard let index = order.firstIndex(where: { $0.id == cue.id }) else { return }
        let dup = copy(cue, position: index + 1, number: nextCueNumber(in: playlist))
        context.insert(dup)
        playlist.cues.append(dup)
        order.insert(dup, at: index + 1)
        compact(playlist, order: order)
        touch(playlist, context: context)
    }

    /// Rewrite every cue number: start, start+step, … in current order (e.g. 1,2,3 or 10,20,30).
    static func renumber(_ playlist: Playlist, start: Int = 1, step: Int = 1, context: ModelContext) {
        renumber(playlist.orderedCues, in: playlist, start: start, step: step, context: context)
    }

    /// Share/backup: JSON (+ the audio files) as a single `.tcshow` package URL in tmp.
    /// The result is `<name>.tcshow.zip`.
    static func exportShow(_ playlist: Playlist) throws -> URL { try ShowPackage.export(playlist) }
    static func importShow(from url: URL, context: ModelContext) async throws -> Playlist {
        try await ShowPackage.importShow(from: url, context: context)
    }
}

/// Runs a playlist through the engine: standby/GO/next/previous, follow modes, pre-wait.
@MainActor
@Observable
final class ShowController {
    static let shared = ShowController()
    static let lastPlaylistKey = "TCPlayback.lastPlaylistID"

    private(set) var playlist: Playlist?
    /// The cue that GO will fire (the "standby" cue).
    private(set) var standbyCue: Cue?
    /// The cue currently loaded/playing in the engine.
    private(set) var activeCue: Cue?
    /// The cue fired before `activeCue` (for `backOne()`).
    private(set) var previousFiredCue: Cue?
    /// Operator message when a cue couldn't be fired (missing file etc.); UI clears it.
    var lastError: String?
    /// A second GO within this many seconds of the last one is ignored (double-tap protection).
    var goGuardInterval: TimeInterval = 1.0

    let engine: PlaybackEngine
    @ObservationIgnored private let driver: any ShowEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastGoAt: Date?
    @ObservationIgnored private var deleteObserver: NSObjectProtocol?
    /// Test hook for the GO guard clock.
    @ObservationIgnored var now: () -> Date = { Date() }

    init(engine: PlaybackEngine = .shared) {
        self.engine = engine
        self.driver = engine
        self.defaults = .standard
        wire()
    }

    /// Drive a substitute engine (tests). `engine` stays a plain PlaybackEngine for UI bindings.
    init(driver: any ShowEngine, engine: PlaybackEngine = PlaybackEngine(), defaults: UserDefaults = .standard) {
        self.engine = engine
        self.driver = driver
        self.defaults = defaults
        wire()
    }

    func open(_ playlist: Playlist) {
        self.playlist = playlist
        standbyCue = playlist.orderedCues.first
        activeCue = nil
        previousFiredCue = nil
        defaults.set(playlist.id.uuidString, forKey: Self.lastPlaylistKey)
    }
    /// Make `cue` the standby (single-tap on a row).
    func standby(_ cue: Cue) { standbyCue = cue }
    /// Fire the standby cue (load + play), then advance standby to the next cue.
    func go() {
        let t = now()
        if let last = lastGoAt, t.timeIntervalSince(last) < goGuardInterval { return }
        guard let cue = standbyCue else { return }
        lastGoAt = t
        fire(cue)
    }
    /// Load and play a specific cue immediately (double-tap on a row).
    func play(_ cue: Cue) { fire(cue) }
    func stop() { driver.stop() }
    func next() {
        guard let cues = playlist?.orderedCues, !cues.isEmpty else { return }
        guard let s = standbyCue, let i = cues.firstIndex(where: { $0.id == s.id }) else {
            standbyCue = cues.first; return
        }
        if i + 1 < cues.count { standbyCue = cues[i + 1] }
    }
    func previous() {
        guard let cues = playlist?.orderedCues, !cues.isEmpty else { return }
        guard let s = standbyCue, let i = cues.firstIndex(where: { $0.id == s.id }) else {
            standbyCue = cues.last; return
        }
        if i > 0 { standbyCue = cues[i - 1] }
    }
    /// Persist live routing changes made while a cue plays back into that cue.
    func commitRoutingToActiveCue() {
        guard let cue = activeCue else { return }
        cue.routing = driver.routing
        cue.playlist?.updatedAt = .now
        if let ctx = cue.modelContext { PlaylistEditor.save(ctx) }
    }
}

// MARK: - Additive ShowController API

extension ShowController {
    func isPlaying(_ cue: Cue) -> Bool { activeCue?.id == cue.id && driver.transport == .playing }
    func isStandby(_ cue: Cue) -> Bool { standbyCue?.id == cue.id }
    /// Seconds left in the active item; nil when nothing is loaded or it is open-ended.
    var remainingTime: TimeInterval? {
        guard activeCue != nil, driver.duration > 0 else { return nil }
        return max(0, driver.duration - driver.currentTime)
    }
    /// Title of the cue GO will fire next.
    var nextCueTitle: String? { standbyCue?.title }

    /// Re-arm the previously fired cue as standby (QLab "back one").
    func backOne() {
        if let p = previousFiredCue { standbyCue = p } else if let a = activeCue { standbyCue = a }
    }

    /// Reopen the playlist used last time (or the first playlist).
    func restore(context: ModelContext) {
        let all = ((try? context.fetch(FetchDescriptor<Playlist>())) ?? []).sorted { $0.sortIndex < $1.sortIndex }
        let saved = defaults.string(forKey: Self.lastPlaylistKey).flatMap(UUID.init(uuidString:))
        if let p = all.first(where: { $0.id == saved }) ?? all.first { open(p) }
    }

    fileprivate func fire(_ cue: Cue) {
        let source = cue.engineSource
        if source == .none || (cue.kind == .track && cue.track?.isMissing ?? true) {
            lastError = "Cue \(cue.number) can’t play: its audio file is missing."
            return
        }
        do {
            try driver.load(source, routing: cue.routing)
            driver.play()
        } catch {
            lastError = "Cue \(cue.number) can’t play: \(error.localizedDescription)"
            return
        }
        if let a = activeCue, a.id != cue.id { previousFiredCue = a }
        activeCue = cue
        standbyCue = cueAfter(cue)
    }

    fileprivate func cueAfter(_ cue: Cue) -> Cue? {
        guard let cues = playlist?.orderedCues, let i = cues.firstIndex(where: { $0.id == cue.id }) else { return nil }
        return i + 1 < cues.count ? cues[i + 1] : nil
    }

    fileprivate func itemFinished() {
        guard let cue = activeCue else { return }
        switch cue.follow {
        case .stop: break
        case .autoContinue:
            lastGoAt = nil // follow-ons are not operator double-taps
            go()
        case .loop:
            driver.seek(to: 0)
            driver.play()
        }
    }

    fileprivate func cuesWillDelete(_ ids: Set<UUID>, playlistID: UUID?) {
        if let a = activeCue, ids.contains(a.id) { driver.stop(); activeCue = nil }
        if let p = previousFiredCue, ids.contains(p.id) { previousFiredCue = nil }
        if let pid = playlistID, playlist?.id == pid {
            playlist = nil; standbyCue = nil; activeCue = nil; previousFiredCue = nil
            defaults.removeObject(forKey: Self.lastPlaylistKey)
            return
        }
        if let s = standbyCue, ids.contains(s.id) {
            let cues = playlist?.orderedCues ?? []
            if let i = cues.firstIndex(where: { $0.id == s.id }) {
                standbyCue = cues[(i + 1)...].first { !ids.contains($0.id) } ?? cues[..<i].last { !ids.contains($0.id) }
            } else {
                standbyCue = nil
            }
        }
    }

    fileprivate func wire() {
        driver.onItemFinished = { [weak self] in
            MainActor.assumeIsolated { self?.itemFinished() }
        }
        deleteObserver = NotificationCenter.default.addObserver(forName: .libraryWillDeleteCues, object: nil, queue: nil) { [weak self] note in
            let ids = note.userInfo?["ids"] as? Set<UUID> ?? []
            let pid = note.userInfo?["playlistID"] as? UUID
            MainActor.assumeIsolated { self?.cuesWillDelete(ids, playlistID: pid) }
        }
    }
}
