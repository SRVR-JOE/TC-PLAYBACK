import SwiftUI
import AVFoundation
import TCKit

/// Line-up tools: auto sync by sound, line up by eye on a visible event, nudge, and (when the
/// recording carries it) line up by the timecode on the video's soundtrack.
struct CueVideoSyncSheet: View {
    let track: Track
    var clock: CuePointClock

    @Environment(\.dismiss) private var dismiss
    private var video: CueVideoController { CueVideoController.shared }
    private let engine = PlaybackEngine.shared

    @State private var offsetText = ""
    @FocusState private var offsetFocused: Bool

    // Auto sync
    @State private var syncJob: Task<Void, Never>?
    @State private var syncProgress: Double?
    @State private var syncResult: CueAutoSync.Result?
    @State private var syncMessage: String?
    @State private var undoOffset: TimeInterval?

    // Video timecode
    @State private var ltcJob: Task<Void, Never>?
    @State private var ltcProgress: Double?
    @State private var ltcMessage: String?

    private var loaded: Bool { engine.source == .file(track.fileURL) }
    private var offset: TimeInterval { video.link?.offset ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                    offsetSection
                    autoSection
                    eyeSection
                    ltcSection
                }
                .padding(Theme.pad)
            }
            .background(Theme.background)
            .navigationTitle("Line up video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .onDisappear {
            syncJob?.cancel(); ltcJob?.cancel()
            video.mode = .follow
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 8) {
            ZStack {
                CueVideoPlayerView(player: video.player)
                if video.outOfRange && video.mode == .follow {
                    ZStack { Theme.surfaceSunken; Text("No video at this time").font(Theme.label).foregroundStyle(Theme.textTertiary) }
                }
            }
            .aspectRatio(max(0.5, video.aspect), contentMode: .fit)
            .frame(maxHeight: 260)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            HStack {
                readout("Track", clock.timecode(at: engine.currentTime).description)
                Spacer()
                readout("Video", videoClock(video.mode == .free ? video.shownVideoTime : max(0, engine.currentTime - offset)))
            }
        }
    }

    private func readout(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.numeric(15)).foregroundStyle(Theme.textPrimary)
        }
    }

    /// Video position as minutes:seconds.frames on the video's own frame rate.
    private func videoClock(_ v: TimeInterval) -> String {
        let fps = max(1, video.videoFPS.rounded())
        let total = Int((max(0, v) * fps).rounded())
        let f = total % Int(fps), s = total / Int(fps)
        return String(format: "%d:%02d:%02d.%02d", s / 3600, (s / 60) % 60, s % 60, f)
    }

    // MARK: Offset

    private var offsetSection: some View {
        section("Offset") {
            HStack(alignment: .firstTextBaseline) {
                Text(CueVideoOffsetFormat.seconds(offset)).font(Theme.numeric(28)).foregroundStyle(Theme.textPrimary)
                Text(CueVideoOffsetFormat.framesText(offset, rate: clock.rate)).font(Theme.numeric(15)).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            Text(offset >= 0 ? "The video starts \(abs(offset).formatted(.number.precision(.fractionLength(3)))) s into the track."
                             : "The video starts \(abs(offset).formatted(.number.precision(.fractionLength(3)))) s before the track.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            let f = 1 / clock.rate.fps
            HStack(spacing: 6) {
                step("−1 s") { video.nudge(by: -1) }
                step("−10 f") { video.nudge(by: -10 * f) }
                step("−1 f") { video.nudge(by: -f) }
                step("+1 f") { video.nudge(by: f) }
                step("+10 f") { video.nudge(by: 10 * f) }
                step("+1 s") { video.nudge(by: 1) }
            }
            HStack(spacing: 8) {
                TextField("Offset in seconds, or s:frames", text: $offsetText)
                    .keyboardType(.numbersAndPunctuation)
                    .font(Theme.numeric(15))
                    .focused($offsetFocused)
                    .submitLabel(.done)
                    .onSubmit(applyTyped)
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
                plainButton("Set") { applyTyped() }
                    .disabled(CueVideoOffsetFormat.parse(offsetText, rate: clock.rate) == nil)
                plainButton("Zero") { video.setOffset(0) }
            }
            Text("Positive means the video starts after the track. Steps are \(clock.rate.operatorLabel) fps frames.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private func applyTyped() {
        guard let v = CueVideoOffsetFormat.parse(offsetText, rate: clock.rate) else { return }
        video.setOffset(v)
        offsetText = ""; offsetFocused = false
    }

    // MARK: Auto sync

    private var autoSection: some View {
        section("Auto sync") {
            Text("Matches the sound of the recording to the track's music. A phone recording from the room is fine; it works best with a minute or more of the show in it.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let p = syncProgress {
                HStack(spacing: 10) {
                    ProgressView(value: p).tint(Theme.textSecondary)
                    Text("Listening").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    plainButton("Cancel") { syncJob?.cancel() }
                }
            } else {
                HStack(spacing: 8) {
                    plainButton("Auto sync", prominent: true) { runAutoSync() }
                        .disabled(track.isMissing || video.link == nil)
                    if let u = undoOffset {
                        plainButton("Undo") { video.setOffset(u); undoOffset = nil; syncMessage = nil; syncResult = nil }
                    }
                    Spacer()
                }
            }
            if let r = syncResult {
                HStack(spacing: 8) {
                    IndicatorLamp(color: r.strength == .strong ? Theme.go : (r.strength == .likely ? Theme.standby : Theme.stop), isOn: true, size: 8)
                    Text(resultText(r)).font(Theme.label).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if r.strength == .weak, abs(offset - r.offset) > 0.0005 {
                        plainButton("Use anyway") { undoOffset = offset; video.setOffset(r.offset) }
                    }
                }
            }
            if let m = syncMessage { Text(m).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
        }
    }

    private func resultText(_ r: CueAutoSync.Result) -> String {
        let s = CueVideoOffsetFormat.seconds(r.offset)
        switch r.strength {
        case .strong: return "Matched at \(s). Strong match."
        case .likely: return "Matched at \(s). Likely; check a hit by eye."
        case .weak: return "Best guess \(s). Weak match."
        }
    }

    private func runAutoSync() {
        guard let link = video.link else { return }
        syncJob?.cancel()
        syncResult = nil; syncMessage = nil
        syncProgress = 0
        let trackURL = track.fileURL, videoURL = CueVideoStore.url(for: link)
        let channel = track.ltcChannel == "left" ? 1 : 0
        let work = Task.detached(priority: .userInitiated) {
            try await CueAutoSync.run(trackURL: trackURL, programChannel: channel, videoURL: videoURL) { p in
                Task { @MainActor in if syncProgress != nil { syncProgress = p } }
            }
        }
        syncJob = Task { @MainActor in
            let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            syncProgress = nil
            switch result {
            case .success(let r):
                syncResult = r
                if r.strength != .weak {
                    undoOffset = offset
                    video.setOffset(r.offset)
                } else {
                    syncMessage = "Line it up by eye below, or use this if it looks right."
                }
            case .failure(let e):
                if e is CancellationError || Task.isCancelled { syncMessage = nil } else { syncMessage = e.localizedDescription }
            }
        }
    }

    // MARK: By eye

    private var eyeSection: some View {
        section("Line up by eye") {
            Text("Find a flash, a clap or a hit in the video. Find the same moment in the track. Then line up.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(get: { video.mode == .free }, set: { video.mode = $0 ? .free : .follow })) {
                Text("Move the video on its own").font(Theme.label).foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            if video.mode == .free {
                scrubber(title: "Video", value: video.shownVideoTime, range: max(0.01, video.duration),
                         onChange: { video.scrubVideo(to: $0) }, step: { video.stepVideo(frames: $0) })
                scrubber(title: "Track", value: engine.currentTime, range: max(0.01, track.duration),
                         onChange: { if loaded { engine.seek(to: $0) } }, step: stepTrack)
                    .disabled(!loaded)
                plainButton("Line up here", prominent: true) { video.lineUpHere() }
                    .disabled(!loaded || video.player == nil)
                Text("Sets the offset so this video frame plays at this point in the track.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func stepTrack(_ frames: Int) {
        guard loaded else { return }
        if engine.transport == .playing { engine.pause() }
        let f = 1 / clock.rate.fps
        let t = ((engine.currentTime / f).rounded() + Double(frames)) * f
        engine.seek(to: min(max(0, t), track.duration))
    }

    private func scrubber(title: String, value: TimeInterval, range: TimeInterval,
                          onChange: @escaping (TimeInterval) -> Void, step: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
            Slider(value: Binding(get: { min(max(0, value), range) }, set: onChange), in: 0...range)
                .tint(Theme.textSecondary)
                .accessibilityLabel("\(title) position")
            HStack(spacing: 6) {
                self.step("−10 f") { step(-10) }
                self.step("−1 f") { step(-1) }
                self.step("+1 f") { step(1) }
                self.step("+10 f") { step(10) }
            }
        }
    }

    // MARK: Video timecode

    private var ltcSection: some View {
        section("Video timecode") {
            Text("If the recording was taken off a desk feed that carries timecode, read it and line up by timecode.")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let p = ltcProgress {
                HStack(spacing: 10) {
                    ProgressView(value: p).tint(Theme.textSecondary)
                    plainButton("Cancel") { ltcJob?.cancel() }
                }
            } else {
                HStack { plainButton("Read timecode from video") { runLTC() }.disabled(video.link == nil); Spacer() }
            }
            if let m = ltcMessage { Text(m).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
        }
    }

    private func runLTC() {
        guard let link = video.link else { return }
        ltcJob?.cancel()
        ltcMessage = nil; ltcProgress = 0
        let url = CueVideoStore.url(for: link)
        let work = Task.detached(priority: .userInitiated) {
            try await CueVideoLTC.scan(url: url, progress: { p in Task { @MainActor in if ltcProgress != nil { ltcProgress = p } } },
                                       isCancelled: { Task.isCancelled })
        }
        ltcJob = Task { @MainActor in
            let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            ltcProgress = nil
            switch result {
            case .success(let found?):
                let o = CueVideoLTC.offset(for: found, clock: clock)
                undoOffset = offset
                video.setOffset(o)
                var msg = "Read \(found.timecode.description) at \(videoClock(found.videoTime)) in the video. Offset set to \(CueVideoOffsetFormat.seconds(o))."
                if found.timecode.rate.nominalFPS != clock.rate.nominalFPS {
                    msg += " The video's timecode is \(found.timecode.rate.operatorLabel) fps; the track is \(clock.rate.operatorLabel) fps."
                }
                ltcMessage = msg
            case .success(nil):
                ltcMessage = "No timecode found in the video's sound."
            case .failure(let e):
                if !(e is CancellationError) { ltcMessage = e.localizedDescription }
            }
        }
    }

    // MARK: Parts

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func step(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Theme.numeric(12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func plainButton(_ label: String, prominent: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Theme.label.weight(.semibold))
                .foregroundStyle(prominent ? Theme.background : Theme.textPrimary)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(prominent ? Theme.textPrimary : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: prominent ? 0 : 1))
        }
        .buttonStyle(.plain)
    }
}
