import SwiftUI
import TCKit

/// Runs tempo detection for a track and hands the grid back. Lives in the timeline bar (not
/// the panel) so closing the panel doesn't lose a detection in progress.
@Observable
final class BeatGridDetection {
    private(set) var running = false
    private(set) var progress = 0.0
    private(set) var failure: String?
    private(set) var last: (bpm: Double, confidence: Double, elapsed: TimeInterval)?
    private var task: Task<Void, Never>?

    /// LTC side of a track as a channel index (the detector listens to the other side).
    static func ltcChannelIndex(_ track: Track) -> Int? {
        switch track.ltcChannel { case "left": 0; case "right": 1; default: nil }
    }

    /// `apply` gets the track id the detection ran on, so a result for a track that's no
    /// longer open can still be saved to the right place.
    @MainActor
    func start(track: Track, existing: BeatGrid?, apply: @escaping @MainActor (UUID, BeatGrid) -> Void) {
        cancel()
        let url = track.fileURL, id = track.id, ltc = Self.ltcChannelIndex(track)
        var opts = TempoDetector.Options()
        opts.beatsPerBar = existing?.beatsPerBar ?? 4
        running = true; progress = 0; failure = nil
        task = Task { @MainActor in
            do {
                let r = try await TempoDetector.detect(url: url, excludingChannel: ltc, options: opts) { p in
                    Task { @MainActor [weak self] in if let self, self.running { self.progress = max(self.progress, p) } }
                }
                var g = r.grid
                if let existing { g.sections = existing.sections; g.snapMode = existing.snapMode }
                last = (g.bpm, r.confidence, r.elapsed)
                apply(id, g)
            } catch is CancellationError {
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "Tempo detection failed."
            }
            running = false
        }
    }

    func cancel() { task?.cancel(); task = nil; running = false }
}

/// Timeline-bar button: shows the tempo (or "Tempo"), opens the panel, saves the grid per track.
struct BeatGridButton: View {
    @Binding var grid: BeatGrid?
    var track: Track
    var clock: CuePointClock
    var compact = false
    @State private var showing = false
    @State private var detection = BeatGridDetection()

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "metronome")
                if !compact {
                    if let grid { Text(String(format: "%.1f", grid.bpm)).font(Theme.numeric(13)) } else { Text("Tempo").font(Theme.label) }
                }
            }
            .foregroundStyle(grid == nil ? Theme.textSecondary : Theme.textPrimary)
            .lineLimit(1).fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(grid.map { String(format: "Tempo %.1f BPM", $0.bpm) } ?? "Tempo")
        .popover(isPresented: $showing) {
            BeatGridPanel(grid: $grid, track: track, clock: clock, detection: detection)
                .frame(minWidth: 360, idealWidth: 400, minHeight: 520)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: grid) { _, g in BeatGridStore.save(g, trackID: track.id) }
        #if DEBUG
        .task(id: track.id) {
            // QA only (never plays audio): -seedBeatGrid sample grid, -detectTempo run detection, -showTempo open the panel.
            let args = ProcessInfo.processInfo.arguments
            if grid == nil, args.contains("-seedBeatGrid") {
                grid = BeatGrid(bpm: 120, firstBeat: 0.5, sections: [.init(name: "Intro", startBar: 1), .init(name: "Verse 1", startBar: 5),
                                                                     .init(name: "Pre-chorus", startBar: 21), .init(name: "Chorus", startBar: 25)],
                                snapMode: .beat)
            }
            if args.contains("-detectTempo") {
                detection.start(track: track, existing: grid) { id, g in if id == track.id { grid = g } }
            }
            if args.contains("-showTempo") { try? await Task.sleep(for: .seconds(1)); showing = true }
        }
        #endif
    }
}

/// Tempo panel: detect, tap, nudge, metre, snap, sections. Edits the grid live.
struct BeatGridPanel: View {
    @Binding var grid: BeatGrid?
    var track: Track
    var clock: CuePointClock
    var detection: BeatGridDetection
    @Environment(\.dismiss) private var dismiss
    @State private var tap = TapTempo()
    @FocusState private var focusedSection: UUID?

    private let engine = PlaybackEngine.shared
    private var playhead: TimeInterval { engine.currentTime }
    private var frame: TimeInterval { 1 / clock.rate.fps }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tempo").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }.font(Theme.label.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .hairline(.bottom)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detectSection
                    tempoSection
                    if grid != nil {
                        downbeatSection
                        metreSection
                        sectionsSection
                        Button("Remove tempo grid", role: .destructive) { grid = nil; tap.reset() }
                            .font(Theme.label).foregroundStyle(Theme.stop)
                            .padding(.top, 4)
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.background)
    }

    // MARK: Detect

    private var detectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Detect")
            HStack(spacing: 10) {
                if detection.running {
                    ProgressView(value: detection.progress).tint(Theme.textSecondary)
                    Button("Cancel") { detection.cancel() }.font(Theme.label)
                } else {
                    Button(grid == nil ? "Detect tempo" : "Detect again") {
                        detection.start(track: track, existing: grid) { id, g in
                            if id == track.id { grid = g } else { BeatGridStore.save(g, trackID: id) }
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(prominent: grid == nil))
                    .disabled(track.isMissing)
                    Spacer(minLength: 0)
                }
            }
            if let f = detection.failure {
                Text(f).font(Theme.caption).foregroundStyle(Theme.stop)
            } else if let r = detection.last, !detection.running {
                Text(String(format: "Found %.2f BPM, confidence %d%%", r.bpm, Int((r.confidence * 100).rounded())))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            } else if grid == nil {
                Text("Finds the tempo and first beat from the programme side of the track. Or tap along below.")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Tempo

    private var tempoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Tempo")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(grid.map { String(format: "%.2f", $0.bpm) } ?? "–")
                    .font(Theme.numeric(34, weight: .regular)).foregroundStyle(Theme.textPrimary)
                Text("BPM").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                if let c = grid?.confidence {
                    Text("Detected, \(Int((c * 100).rounded()))%").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            HStack(spacing: 6) {
                step("−1") { bpm(by: -1) }
                step("−0.1") { bpm(by: -0.1) }
                step("+0.1") { bpm(by: 0.1) }
                step("+1") { bpm(by: 1) }
                step("÷2") { bpm(times: 0.5) }
                step("×2") { bpm(times: 2) }
            }
            .disabled(grid == nil)
            Button(action: tapped) {
                VStack(spacing: 2) {
                    Text("Tap").font(.system(size: 17, weight: .semibold))
                    Text(tapCaption).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                .frame(height: 54)
            }
            .buttonStyle(FlatButtonStyle())
            .frame(height: 54)
            .accessibilityHint("Tap along with the beat to set the tempo")
        }
    }

    private var tapCaption: String {
        if let b = tap.bpm { return String(format: "%d taps, %.1f BPM", tap.count, b) }
        return tap.count == 1 ? "Keep tapping" : "Tap along with the beat"
    }

    private func tapped() {
        let now = ProcessInfo.processInfo.systemUptime
        let bpm = tap.tap(at: now)
        Haptics.tick()
        let atPlayhead = playhead
        guard let bpm else { return }
        if var g = grid {
            g.setBPM(bpm, pivot: atPlayhead)
            g.confidence = nil
            // While the track runs, the tap also says where a beat is.
            if engine.transport == .playing { g.alignBeat(to: atPlayhead) }
            grid = g
        } else {
            var g = BeatGrid(bpm: bpm, firstBeat: 0)
            g.alignBeat(to: atPlayhead)
            g.firstBeat = g.firstBeat.truncatingRemainder(dividingBy: g.beatLength)
            if g.firstBeat < 0 { g.firstBeat += g.beatLength }
            grid = g
        }
    }

    private func bpm(by d: Double) { edit { $0.setBPM(($0.bpm * 10).rounded() / 10 + d, pivot: playhead) } }
    private func bpm(times f: Double) {
        edit { g in
            let new = g.bpm * f
            guard BeatGrid.bpmRange.contains(new) else { return }
            g.setBPM(new, pivot: playhead)
        }
    }

    // MARK: Downbeat

    private var downbeatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Bar 1")
            if let g = grid {
                HStack(alignment: .firstTextBaseline) {
                    Text(clock.timecode(at: g.firstBeat).description).font(Theme.numeric(17)).foregroundStyle(Theme.textPrimary)
                    Text(String(format: "%.3f s", g.firstBeat)).font(Theme.numeric(12)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text("Playhead \(g.barBeatLabel(at: playhead))").font(Theme.numeric(12)).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 6) {
                step("−10 ms") { shift(-0.010) }
                step("−1f") { shift(-frame) }
                step("+1f") { shift(frame) }
                step("+10 ms") { shift(0.010) }
            }
            Button("Set downbeat at playhead") { edit { $0.setDownbeat(at: playhead) } }
                .buttonStyle(OutlineButtonStyle())
        }
    }

    private func shift(_ s: TimeInterval) { edit { $0.firstBeat += s } }

    // MARK: Metre and snap

    private var metreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Metre and snap")
            if let g = grid {
                Stepper(value: Binding(get: { g.beatsPerBar }, set: { v in edit { $0.beatsPerBar = v } }), in: 1...12) {
                    Text("\(g.beatsPerBar) beats per bar").font(Theme.label).foregroundStyle(Theme.textPrimary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snap marks to").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    Picker("Snap marks to", selection: Binding(get: { g.snapMode }, set: { v in edit { $0.snapMode = v } })) {
                        ForEach(BeatGrid.SnapMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    // MARK: Sections

    private var sectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header("Sections")
                Spacer()
                Button("Add at playhead") { addSection() }.font(Theme.label)
            }
            if let g = grid {
                if g.sections.isEmpty {
                    Text("Name the parts of the song (Verse, Chorus). Each starts on a bar.")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(g.sortedSections) { s in sectionRow(s, grid: g) }
            }
        }
    }

    private func sectionRow(_ s: BeatGrid.Section, grid g: BeatGrid) -> some View {
        HStack(spacing: 8) {
            TextField("Name", text: Binding(get: { s.name }, set: { v in editSection(s.id) { $0.name = v } }))
                .font(Theme.label).foregroundStyle(Theme.textPrimary)
                .focused($focusedSection, equals: s.id)
                .submitLabel(.done)
            Button { editSection(s.id) { $0.startBar -= 1 } } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless).accessibilityLabel("One bar earlier")
            Text("Bar \(s.startBar)").font(Theme.numeric(13)).foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 56)
            Button { editSection(s.id) { $0.startBar += 1 } } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).accessibilityLabel("One bar later")
            Button(role: .destructive) { edit { $0.sections.removeAll { $0.id == s.id } } } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(Theme.stop).accessibilityLabel("Delete section")
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
    }

    private func addSection() {
        guard let g = grid else { return }
        let bar = g.barBeat(at: playhead + 0.05).bar
        let s = BeatGrid.Section(name: "Section \(g.sections.count + 1)", startBar: bar)
        edit { $0.sections.append(s) }
        focusedSection = s.id
    }

    private func editSection(_ id: UUID, _ f: (inout BeatGrid.Section) -> Void) {
        edit { g in if let i = g.sections.firstIndex(where: { $0.id == id }) { f(&g.sections[i]) } }
    }

    // MARK: Bits

    private func edit(_ f: (inout BeatGrid) -> Void) {
        guard var g = grid else { return }
        f(&g); grid = g
    }

    private func header(_ title: String) -> some View { Text(title).sectionHeaderStyle() }

    private func step(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Theme.numeric(12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .buttonStyle(FlatButtonStyle(tint: Theme.textSecondary))
        .frame(height: 34)
    }
}
