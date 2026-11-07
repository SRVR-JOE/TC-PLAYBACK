import SwiftUI
import SwiftData
import TCKit

/// Under the big clock: the cue marks on the playing (or standby) track — the mark you're in,
/// every mark as a row of chips, and a countdown to the next one. Uses the heard position
/// (render position minus speaker delay), the same reference as Cue points' triggers.
struct TrackMarksStrip: View {
    /// Phone and tight layouts drop the chip row and keep Now / Next.
    var compact = false
    @Bindable private var shell = ShellModel.shared
    @Query(sort: \CuePoint.time) private var allPoints: [CuePoint]
    @AppStorage("cuePoints.allowSpeakerDelay") private var allowSpeakerDelay = true
    private let types = CuePointTypeStore.shared
    @Bindable private var caller = CueCallerUIModel.shared

    var body: some View {
        let cue = shell.activeCue ?? shell.standbyCue
        let track = cue?.kind == .track ? cue?.track : nil
        let running = shell.isRunning && shell.activeCue != nil
        let points = track.map { t in allPoints.filter { $0.trackID == t.id } } ?? []
        let index = CuePointIndex(points: points, types: types.types)
        let clock = track.map(CuePointClock.forTrack)

        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { _ in
            let t = position(running: running, isActiveTrack: shell.activeCue?.track?.id == track?.id)
            let current = points.last { $0.time <= t + 0.0005 }
            let next = points.first { $0.time > t + 0.0005 }
            // Light the mark up for half a second as it's heard.
            let lit = running && current.map { t - $0.time < 0.5 } == true

            HStack(spacing: 12) {
            Group {
                if track == nil {
                    placeholder(cue == nil ? "No track cued" : "This cue isn't a track")
                } else if points.isEmpty {
                    HStack {
                        placeholder("No cue marks on this track")
                        Spacer()
                        Button("Add marks") { shell.showCuePoints = true }
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                            .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 12) {
                        nowBlock(current, index: index, clock: clock, lit: lit)
                            .frame(minWidth: compact ? 0 : 170, maxWidth: compact ? .infinity : 260, alignment: .leading)
                        if !compact {
                            divider
                            chipRail(points, current: current, index: index)
                            divider
                        }
                        nextBlock(next, index: index, remaining: next.map { $0.time - t }, running: running, clock: clock)
                            .frame(minWidth: compact ? 0 : 150, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            divider
            CueCallerStripControl(compact: compact, fallbackNext: nextCall(points, after: t), running: running)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: compact ? 50 : 58)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cue marks on this track")
    }

    /// Heard track time while this track is playing; the start of the track when it's on standby.
    private func position(running: Bool, isActiveTrack: Bool) -> TimeInterval {
        guard isActiveTrack else { return -1 }
        let e = PlaybackEngine.shared
        guard running else { return e.currentTime }
        return max(0, e.preciseTime - (allowSpeakerDelay ? CueTriggerClock.outputDelay : 0))
    }

    /// The next mark the caller would speak (stand-in until the engine reports its own).
    private func nextCall(_ points: [CuePoint], after t: TimeInterval) -> CueCallerUpcoming? {
        let s = caller.settings
        guard let p = points.first(where: { $0.time > t + 0.0005 && (!s.onlyMarksWithNotes || !$0.callNote.trimmingCharacters(in: .whitespaces).isEmpty) })
        else { return nil }
        let remaining = p.time - max(0, t)
        let standby = s.sayStandby && remaining > s.standbyLead
        let note = p.callNote.trimmingCharacters(in: .whitespaces)
        return CueCallerUpcoming(markID: p.id, markName: p.name, text: note.isEmpty ? p.name : note,
                                 kind: standby ? .standby : .go, secondsToGo: standby ? remaining - s.standbyLead : remaining)
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(width: Theme.hairlineWidth).padding(.vertical, 10) }

    private func placeholder(_ s: String) -> some View {
        Text(s).font(Theme.caption).foregroundStyle(Theme.textTertiary)
    }

    private func color(_ p: CuePoint, _ index: CuePointIndex) -> Color {
        Color(hexString: index.colorHex(of: p) ?? "") ?? Theme.standby
    }

    private func nowBlock(_ p: CuePoint?, index: CuePointIndex, clock: CuePointClock?, lit: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(p.map { color($0, index) } ?? Theme.hairline)
                .frame(width: 4).padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.map { "\(index.number(of: $0))  \($0.name)" } ?? "Before the first mark")
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    .foregroundStyle(lit ? Theme.background : (p == nil ? Theme.textTertiary : Theme.textPrimary))
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let p, let clock {
                    Text("\(index.type(of: p).name) · \(clock.timecode(at: p.time).description)")
                        .font(Theme.numeric(11, weight: .regular))
                        .foregroundStyle(lit ? Theme.background.opacity(0.8) : Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, lit ? 8 : 0)
        .background(lit ? p.map { color($0, index) } ?? .clear : .clear,
                    in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func chipRail(_ points: [CuePoint], current: CuePoint?, index: CuePointIndex) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(points) { p in
                        let on = p.id == current?.id
                        let passed = current.map { p.time < $0.time } ?? false
                        HStack(spacing: 5) {
                            Rectangle().fill(color(p, index)).frame(width: 3)
                            Text(p.name).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
                            if !p.callNote.isEmpty {
                                Image(systemName: "speaker.wave.1")
                                    .font(.system(size: 9, weight: .regular))
                                    .foregroundStyle(Theme.textTertiary)
                                    .accessibilityLabel("Has a call")
                            }
                        }
                        .padding(.trailing, 8)
                        .frame(height: 26)
                        .foregroundStyle(on ? Theme.textPrimary : (passed ? Theme.textTertiary : Theme.textSecondary))
                        .background(on ? Theme.surfaceRaised : Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? color(p, index) : Theme.hairline, lineWidth: on ? 1 : Theme.hairlineWidth))
                        .id(p.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: current?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func nextBlock(_ p: CuePoint?, index: CuePointIndex, remaining: TimeInterval?, running: Bool, clock: CuePointClock?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(p.map { "Next  \(index.number(of: $0))  \($0.name)" } ?? "Last mark")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if let remaining, running {
                Text(String(format: "%.1f s", max(0, remaining)))
                    .font(Theme.numeric(compact ? 18 : 22, weight: .medium))
                    .foregroundStyle(remaining < 3 ? Theme.standby : Theme.textPrimary)
                    .contentTransition(.numericText())
            } else if let p, let clock {
                // Parked: where the next mark is, as timecode.
                Text(clock.timecode(at: p.time).description)
                    .font(Theme.numeric(compact ? 15 : 17, weight: .regular)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
