#if DEBUG
import Foundation

/// QA flags for "Find moments" (none of them play audio):
/// `-seedMoments` shows a made-up set of suggestions on the open track,
/// `-analyzeMoments` runs the real analysis on it, `-showMoments` opens the panel,
/// `-selectMoment` selects the first section suggestion (to show Accept / Reject in the lane).
@MainActor
enum SongMomentsDebug {
    static func apply(track: Track, grid: BeatGrid?, openPanel: @escaping () -> Void) {
        let args = ProcessInfo.processInfo.arguments
        let model = SongMomentsController.shared
        if args.contains("-seedMoments") { model.seed(sample(duration: max(track.duration, 130)), trackID: track.id) }
        if args.contains("-analyzeMoments") { model.run(track: track, grid: grid) }
        if args.contains("-selectMoment") { model.selectedID = model.visible.first(where: { $0.kind == .drop })?.id }
        if args.contains("-showMoments") {
            Task { try? await Task.sleep(for: .seconds(1)); openPanel() }
        }
    }

    /// 120 BPM song shape lined up with `-seedMarks` (Verse 1 at 22 s, chorus drop at 52 s).
    static func sample(duration: TimeInterval) -> SongAnalysis {
        func m(_ t: Double, _ k: SongMoment.Kind, _ s: Double, _ l: String, group: Int? = nil, _ d: String) -> SongMoment {
            SongMoment(time: t, kind: k, strength: s, label: l, cueTypeName: k.suggestedTypeName, group: group, detail: d)
        }
        var ms: [SongMoment] = [
            m(6, .section, 1, "Intro", group: 0, "Doesn't repeat elsewhere in the song. A guess from the audio."),
            m(22, .section, 0.9, "Verse 1", group: 1, "Sounds like the other B sections (2 in all). A guess from the audio."),
            m(44, .section, 0.7, "Bridge 1", group: 2, "Doesn't repeat elsewhere in the song. A guess from the audio."),
            m(52, .section, 0.95, "Chorus 1", group: 3, "Sounds like the other D sections (2 in all). A guess from the audio."),
            m(76, .section, 0.85, "Verse 2", group: 1, "Sounds like the other B sections (2 in all). A guess from the audio."),
            m(100, .section, 0.9, "Chorus 2", group: 3, "Sounds like the other D sections (2 in all). A guess from the audio."),
            m(122, .section, 0.6, "Outro", group: 4, "Doesn't repeat elsewhere in the song. A guess from the audio."),
            m(44, .build, 0.75, "Build", "Energy rises steadily for 8 s."),
            m(52, .drop, 0.92, "Drop", "Big rise in energy after a build. About 9 dB louder."),
            m(70, .breakdown, 0.6, "Breakdown", "Energy falls by about 7 dB and stays down."),
            m(98.6, .stop, 0.8, "Stop", "The music stops for 0.8 s."),
        ]
        for (t, s) in [(6.0, 0.7), (14, 0.45), (22, 0.62), (30, 0.55), (38, 0.5), (51.0, 0.58), (60, 0.66), (68, 0.52),
                       (84, 0.6), (92, 0.55), (99.4, 0.88), (108, 0.7), (116, 0.6)] {
            ms.append(m(t, .hit, s, "Hit", "Accent that stands out from the beat around it."))
        }
        return SongAnalysis(version: SongAnalyzer.version, duration: duration,
                            grid: BeatGrid(bpm: 120, firstBeat: 0), tempoConfidence: 0.9,
                            moments: ms.sorted { $0.time < $1.time }, elapsed: 1.2, musicStart: 0.5, musicEnd: duration - 2)
    }
}
#endif
