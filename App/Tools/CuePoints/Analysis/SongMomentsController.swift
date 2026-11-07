import SwiftUI
import Observation

/// State for "Find moments": the analysis of the open track, what's shown (sensitivity, kinds),
/// what's been rejected or accepted, and the suggestion under review. One per app, follows the
/// track open in Cue points. The analysis outlives the panel (closing it doesn't cancel).
@MainActor @Observable
final class SongMomentsController {
    static let shared = SongMomentsController()

    enum Phase: Equatable { case idle, running, ready, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var progress = 0.0
    private(set) var analysis: SongAnalysis?
    private(set) var trackID: UUID?
    private(set) var rejected: Set<UUID> = []
    private(set) var accepted: Set<UUID> = []
    /// The suggestion being auditioned (lane and list highlight it).
    var selectedID: UUID?
    /// Suggestions lane on the timeline.
    var showLane = true

    var sensitivity: Double {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "songMoments.sensitivity") }
    }
    var kinds: Set<SongMoment.Kind> {
        didSet { UserDefaults.standard.set(kinds.map(\.rawValue).sorted(), forKey: "songMoments.kinds") }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cacheKey: String?

    init() {
        let d = UserDefaults.standard
        sensitivity = d.object(forKey: "songMoments.sensitivity") as? Double ?? 0.5
        let saved = d.stringArray(forKey: "songMoments.kinds")?.compactMap(SongMoment.Kind.init(rawValue:))
        kinds = Set(saved ?? SongMoment.Kind.allCases)
    }

    /// Suggestions shown now, in time order.
    var visible: [SongMoment] {
        analysis?.visible(sensitivity: sensitivity, kinds: kinds, rejected: rejected.union(accepted)) ?? []
    }
    var selected: SongMoment? { selectedID.flatMap { id in analysis?.moments.first { $0.id == id } } }

    // MARK: Track

    /// Follows the track open in Cue points; picks up a cached analysis if there is one.
    func open(track: Track) {
        guard track.id != trackID else { return }
        cancel()
        trackID = track.id
        selectedID = nil
        analysis = nil; rejected = []; accepted = []; phase = .idle
        let key = SongAnalysisCache.key(url: track.fileURL, trackID: track.id, ltcChannel: BeatGridDetection.ltcChannelIndex(track))
        cacheKey = key
        if let e = SongAnalysisCache.load(key) {
            analysis = e.analysis; rejected = e.rejected; accepted = e.accepted; phase = .ready
        }
    }

    /// Analyses `track`'s programme channel. `grid` is the track's own tempo grid, if any.
    func run(track: Track, grid: BeatGrid?) {
        cancel()
        open(track: track)
        let url = track.fileURL, id = track.id, ltc = BeatGridDetection.ltcChannelIndex(track)
        var o = SongAnalyzer.Options()
        o.grid = grid
        o.beatsPerBar = grid?.beatsPerBar ?? 4
        phase = .running; progress = 0
        task = Task { @MainActor in
            do {
                let r = try await SongAnalyzer.analyse(url: url, excludingChannel: ltc, options: o) { p in
                    Task { @MainActor [weak self] in if let self, self.phase == .running { self.progress = max(self.progress, p) } }
                }
                guard self.trackID == id else { return }
                analysis = r; rejected = []; accepted = []; selectedID = nil
                phase = .ready
                persist()
            } catch is CancellationError {
                if self.trackID == id { phase = analysis == nil ? .idle : .ready }
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "The track couldn't be analysed.")
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        if phase == .running { phase = analysis == nil ? .idle : .ready }
    }

    // MARK: Review

    func reject(_ id: UUID) {
        rejected.insert(id)
        if selectedID == id { selectedID = nil }
        persist()
    }

    /// Accepted suggestions leave the lane (they're marks now).
    func markAccepted(_ ids: [UUID]) {
        accepted.formUnion(ids)
        if let s = selectedID, accepted.contains(s) { selectedID = nil }
        persist()
    }

    func restoreRejected() { rejected = []; persist() }

    var sectionSuggestions: [SongMoment] { visible.filter { $0.kind == .section } }

    private func persist() {
        guard let analysis, let cacheKey else { return }
        SongAnalysisCache.save(.init(analysis: analysis, rejected: rejected, accepted: accepted), key: cacheKey)
    }

    // MARK: Timeline

    /// The Suggestions lane for `TimelineEditor`, or nil when there's nothing to show.
    func timelineLane(onSeek: @escaping (TimeInterval) -> Void,
                      onAccept: @escaping ([SongMoment]) -> Void) -> ((TimeInterval, TimeInterval) -> AnyView)? {
        guard showLane, analysis != nil else { return nil }
        return { origin, span in AnyView(SongSuggestionLane(origin: origin, span: span, onSeek: onSeek, onAccept: onAccept)) }
    }

    #if DEBUG
    /// QA only: shows a made-up analysis (no audio is read or played).
    func seed(_ a: SongAnalysis, trackID: UUID) {
        cancel()
        self.trackID = trackID
        analysis = a; rejected = []; accepted = []; phase = .ready
        cacheKey = nil
    }
    #endif
}
