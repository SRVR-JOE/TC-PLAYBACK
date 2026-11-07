import SwiftUI

// MARK: - Timeline-bar button

/// "Find moments" in the timeline bar: opens the review panel, shows progress while listening.
struct SongMomentsButton: View {
    var track: Track
    @Binding var grid: BeatGrid?
    var clock: CuePointClock
    var compact = false
    var onAccept: ([SongMoment]) -> Void
    var onSeek: (TimeInterval) -> Void
    @State private var showing = false
    private var model: SongMomentsController { .shared }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.magnifyingglass")
                if !compact {
                    if model.phase == .running {
                        Text("Listening \(Int(model.progress * 100))%").font(Theme.label).monospacedDigit()
                    } else {
                        Text("Find moments").font(Theme.label)
                    }
                }
            }
            .fixedSize()
            .foregroundStyle(model.analysis != nil && model.showLane ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Find moments")
        .accessibilityHint("Listens to the track and suggests hits, drops, builds, stops and sections")
        .popover(isPresented: $showing) {
            SongMomentsPanel(track: track, grid: $grid, clock: clock, onAccept: onAccept, onSeek: onSeek)
                .frame(minWidth: 380, idealWidth: 420, minHeight: 540)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .task(id: track.id) {
            model.open(track: track)
            #if DEBUG
            SongMomentsDebug.apply(track: track, grid: grid) { showing = true }
            #endif
        }
    }
}

// MARK: - Review panel

struct SongMomentsPanel: View {
    var track: Track
    @Binding var grid: BeatGrid?
    var clock: CuePointClock
    var onAccept: ([SongMoment]) -> Void
    var onSeek: (TimeInterval) -> Void
    @Environment(\.dismiss) private var dismiss
    @Bindable private var model = SongMomentsController.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Find moments").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }.font(Theme.label.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .hairline(.bottom)
            switch model.phase {
            case .idle: intro
            case .running: running
            case .failed(let why): failed(why)
            case .ready: review
            }
        }
        .background(Theme.background)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Listens to the programme side of the track (never the timecode) and suggests hits, drops, builds, breakdowns, stops and song sections. Nothing becomes a mark until you accept it.")
                .font(Theme.label).foregroundStyle(Theme.textSecondary)
            primaryButton("Find moments") { model.run(track: track, grid: grid) }
            Spacer()
        }
        .padding(16)
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Listening to the track…").font(Theme.label).foregroundStyle(Theme.textPrimary)
            ProgressView(value: model.progress).tint(Theme.textSecondary)
            Button("Cancel") { model.cancel() }.font(Theme.label)
            Spacer()
        }
        .padding(16)
    }

    private func failed(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(why).font(Theme.label).foregroundStyle(Theme.textPrimary)
            primaryButton("Try again") { model.run(track: track, grid: grid) }
            Spacer()
        }
        .padding(16)
    }

    private var review: some View {
        let shown = model.visible
        let sections = model.sectionSuggestions
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                summary(shown.count)
                HStack(spacing: 10) {
                    Text("Fewer").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    Slider(value: $model.sensitivity, in: 0...1).tint(Theme.textSecondary)
                        .accessibilityLabel("Sensitivity")
                    Text("More").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                kindFilters
            }
            .padding(16)
            .hairline(.bottom)
            List {
                if shown.isEmpty {
                    Text("Nothing at this setting. Slide towards More, or turn on more kinds.")
                        .font(Theme.label).foregroundStyle(Theme.textSecondary).listRowBackground(Theme.surface)
                }
                ForEach(shown) { m in row(m).listRowBackground(m.id == model.selectedID ? Theme.surfaceRaised : Theme.surface) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    primaryButton("Accept all shown (\(shown.count))") { accept(shown) }.disabled(shown.isEmpty)
                    if !sections.isEmpty {
                        secondaryButton("Accept sections") { acceptSections(sections) }
                    }
                }
                HStack(spacing: 14) {
                    Button("Listen again") { model.run(track: track, grid: grid) }
                    if !model.rejected.isEmpty { Button("Bring back \(model.rejected.count) rejected") { model.restoreRejected() } }
                    Spacer()
                    Toggle("Lane", isOn: $model.showLane).fixedSize()
                }
                .font(Theme.caption.weight(.medium))
                Text("These are guesses from the audio, section names and repeats most of all. Check each one before the show.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            .hairline(.top)
        }
    }

    private func summary(_ count: Int) -> some View {
        let a = model.analysis
        var parts: [String] = []
        if let g = grid ?? a?.grid { parts.append(String(format: "%.1f BPM", g.bpm)) }
        parts.append("\(count) suggestion\(count == 1 ? "" : "s") shown")
        if let a { parts.append(String(format: "found in %.1f s", a.elapsed)) }
        return Text(parts.joined(separator: " · ")).font(Theme.caption).foregroundStyle(Theme.textSecondary)
    }

    private var kindFilters: some View {
        let counts = Dictionary(grouping: model.analysis?.visible(sensitivity: model.sensitivity, rejected: model.rejected.union(model.accepted)) ?? [],
                                by: \.kind).mapValues(\.count)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(SongMoment.Kind.allCases) { k in
                let on = model.kinds.contains(k)
                Button {
                    if on { model.kinds.remove(k) } else { model.kinds.insert(k) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 13))
                        Text(k.title).font(Theme.caption.weight(.medium))
                        Text("\(counts[k] ?? 0)").font(Theme.numeric(11)).foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(k.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func row(_ m: SongMoment) -> some View {
        HStack(spacing: 10) {
            Button { audition(m) } label: {
                HStack(spacing: 10) {
                    StrengthBar(strength: m.strength).frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(m.label).font(Theme.label).foregroundStyle(Theme.textPrimary)
                            if let l = m.groupLetter { Text(l).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                        }
                        Text(m.detail).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(clock.timecode(at: m.time).description).font(Theme.numeric(13)).foregroundStyle(Theme.textPrimary)
                        Text(grid.map { "Bar \($0.barBeatLabel(at: m.time))" } ?? m.kind.singular)
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(m.label), \(m.kind.singular), \(clock.timecode(at: m.time).description). Go there")
            Button { accept([m]) } label: { Image(systemName: "checkmark") }
                .buttonStyle(.borderless).foregroundStyle(Theme.textPrimary).accessibilityLabel("Accept \(m.label)")
            Button { model.reject(m.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(Theme.textSecondary).accessibilityLabel("Reject \(m.label)")
        }
        .padding(.vertical, 2)
    }

    private func audition(_ m: SongMoment) {
        model.selectedID = m.id
        onSeek(m.time)                  // seek only: never starts playback
    }

    private func accept(_ ms: [SongMoment]) {
        onAccept(ms)
        model.markAccepted(ms.map(\.id))
    }

    /// Section marks, and the grid's sections (a new grid from the detected tempo if there's none).
    private func acceptSections(_ ms: [SongMoment]) {
        accept(ms)
        if let a = model.analysis, var g = a.gridWithSections(base: grid) {
            let keep = Set(ms.map(\.label))
            g.sections = g.sections.filter { keep.contains($0.name) }
            if let old = grid { g.snapMode = old.snapMode }
            grid = g
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.label.weight(.semibold)).foregroundStyle(Theme.background)
                .padding(.horizontal, 14).frame(height: 34)
                .background(Theme.textPrimary, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.label.weight(.medium)).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14).frame(height: 34)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Five thin steps, filled to the suggestion's strength. Flat, no colour.
private struct StrengthBar: View {
    var strength: Double
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Rectangle()
                    .fill(Double(i) < strength * 5 - 0.01 ? Theme.textSecondary : Theme.hairline)
                    .frame(width: 3, height: 5 + CGFloat(i) * 2.5)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Suggestions lane

/// Ghost marks under the cue lanes: a thin line per suggestion, taller and more opaque the
/// stronger it is, with an outlined name flag when there's room. Tap one to go there (no
/// playback); the chosen one gets Accept and Reject.
struct SongSuggestionLane: View {
    var origin: TimeInterval
    var span: TimeInterval
    var onSeek: (TimeInterval) -> Void
    var onAccept: ([SongMoment]) -> Void
    var gutter: CGFloat = 78
    var height: CGFloat = 34
    private var model: SongMomentsController { .shared }

    var body: some View {
        let shown = model.visible
        let sel = model.selectedID
        HStack(spacing: 0) {
            Text("Suggestions").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(width: gutter, height: height, alignment: .leading)
                .background(Theme.surface)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            GeometryReader { geo in
                let w = max(1, geo.size.width), pps = w / span
                Canvas { gc, size in draw(gc, size, pps: pps, shown: shown, selected: sel) }
                    .background(Theme.surfaceSunken)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { v in tap(at: v.location.x, pps: pps, shown: shown) })
                    .overlay(alignment: .trailing) { if let m = model.selected, shown.contains(m) { actions(m) } }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions, \(shown.count)")
    }

    private func x(_ t: TimeInterval, _ pps: CGFloat) -> CGFloat { CGFloat(t - origin) * pps }

    private func tap(at px: CGFloat, pps: CGFloat, shown: [SongMoment]) {
        let near = shown.min { abs(x($0.time, pps) - px) < abs(x($1.time, pps) - px) }
        if let near, abs(x(near.time, pps) - px) <= 16 {
            model.selectedID = near.id
            onSeek(near.time)
            Haptics.tick()
        } else {
            model.selectedID = nil
        }
    }

    private func draw(_ gc: GraphicsContext, _ size: CGSize, pps: CGFloat, shown: [SongMoment], selected: UUID?) {
        let visible = shown.filter { x($0.time, pps) > -160 && x($0.time, pps) < size.width + 4 }
        for (i, m) in visible.enumerated() {
            let px = x(m.time, pps)
            let on = m.id == selected
            let s = CGFloat(min(1, max(0, m.strength)))
            let h = on ? size.height : 8 + s * (size.height - 10)
            let colour = on ? Theme.textPrimary : Theme.textSecondary.opacity(0.3 + 0.6 * s)
            gc.fill(Path(CGRect(x: px - (on ? 1 : 0.5), y: size.height - h, width: on ? 2 : 1, height: h)), with: .color(colour))
            // Outlined name flag for everything but hits, when it fits before the next one.
            guard m.kind != .hit || on else { continue }
            let next = visible[(i + 1)...].first { $0.kind != .hit }.map { x($0.time, pps) } ?? .infinity
            let text = gc.resolve(Text(m.label).font(.system(size: 10, weight: .medium))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary.opacity(0.5 + 0.5 * s)))
            let tw = text.measure(in: CGSize(width: 140, height: 14)).width + 8
            guard on || px + tw + 4 < next else { continue }
            let flag = CGRect(x: px, y: 3, width: tw, height: 15)
            gc.fill(Path(roundedRect: flag, cornerRadius: 2), with: .color(Theme.surface.opacity(on ? 1 : 0.85)))
            gc.stroke(Path(roundedRect: flag, cornerRadius: 2), with: .color(on ? Theme.textPrimary : Theme.hairline), lineWidth: 1)
            gc.draw(text, at: CGPoint(x: px + 4, y: flag.midY), anchor: .leading)
        }
    }

    private func actions(_ m: SongMoment) -> some View {
        HStack(spacing: 6) {
            Text("\(m.label) · \(m.kind.singular)").font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Button("Accept") { onAccept([m]); model.markAccepted([m.id]) }
                .font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.background)
                .padding(.horizontal, 8).frame(height: 24)
                .background(Theme.textPrimary, in: RoundedRectangle(cornerRadius: 3))
            Button("Reject") { model.reject(m.id) }
                .font(Theme.caption.weight(.medium)).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8).frame(height: 24)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).frame(height: height)
        .background(Theme.surface.opacity(0.95))
    }
}
