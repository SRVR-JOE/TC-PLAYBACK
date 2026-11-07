import SwiftUI
import SwiftData
import TCKit

/// Cue points: listen to a track, tap Mark to drop points, name and tidy them, then export a
/// disguise cue table, a grandMA3 timecode show or CSV. Points are saved per track.
struct CuePointsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var hSize
    @Query(sort: \Track.title) private var tracks: [Track]
    @State private var track: Track?
    @State private var points: [CuePoint] = []
    @State private var clock = CuePointClock(start: Timecode(hours: 1, rate: .fps30))
    @State private var options = CuePointExport.DisguiseOptions()
    @State private var exports: [ExportFile] = []
    @State private var blocked = false
    @State private var editingStart = false
    @State private var startText = ""
    @State private var lastMarkID: UUID?
    @FocusState private var focusedName: UUID?
    @State private var peaks: [Float] = []
    @State private var selected: UUID?
    @State private var saveTask: Task<Void, Never>?
    @State private var span: TimeInterval = 30
    @State private var beatGrid: BeatGrid? // BEATGRID hook

    private let engine = PlaybackEngine.shared
    private var isPad: Bool { hSize == .regular }
    private var loaded: Bool { track.map { engine.source == .file($0.fileURL) } ?? false }

    struct ExportFile: Identifiable { let id = UUID(); let title: String; let detail: String; let url: URL }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 900
            VStack(spacing: 0) {
                if let track {
                    if blocked { blockedBanner }
                    if wide {
                        // Editor layout: monitor | inspector on top, full-width timeline below.
                        HStack(alignment: .top, spacing: Theme.pad) {
                            VStack(spacing: 10) {
                                header(track)
                                TriggerReadout(points: points, clock: clock, playhead: engine.currentTime,
                                               isPlaying: engine.transport == .playing, large: true)
                                transport
                            }
                            .frame(maxWidth: .infinity)
                            inspectorPanel.frame(width: min(420, geo.size.width * 0.36))
                        }
                        .padding(Theme.pad)
                        .frame(height: geo.size.height * 0.5)
                        timelineBar(track)
                        timeline(track).frame(maxHeight: .infinity)
                            .padding([.horizontal, .bottom], Theme.pad)
                    } else {
                        header(track)
                        TriggerReadout(points: points, clock: clock, playhead: engine.currentTime,
                                       isPlaying: engine.transport == .playing)
                            .padding(.horizontal, Theme.pad)
                        timelineBar(track)
                        timeline(track).frame(height: 170).padding(.horizontal, Theme.pad)
                        transport
                        inspectorPanel.padding(.horizontal, Theme.pad).padding(.bottom, 6)
                    }
                } else {
                    ContentUnavailableView("No tracks yet", systemImage: "waveform",
                                           description: Text("Import a track, then come back to mark cue points."))
                }
            }
            .background { shortcuts }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) { trackMenu }
            ToolbarItem(placement: .topBarTrailing) { exportMenu(prominent: false) }
        }
        .onAppear(perform: initialTrack)
        #if DEBUG
        .task {
            // -flashTest: fire the flash 2 s after opening (QA only).
            if ProcessInfo.processInfo.arguments.contains("-flashTest") {
                try? await Task.sleep(for: .seconds(2)); CueFlash.fire(markHex: CuePointColor.red.rawValue)
            }
        }
        #endif
        .onDisappear {
            Torch.off()
            if loaded { engine.stop() }
        }
        .onChange(of: track?.id) { _, _ in open() }
        .alert("Start timecode", isPresented: $editingStart) {
            TextField("01:00:00:00", text: $startText)
                .keyboardType(.numbersAndPunctuation)
            Button("Set") {
                if let tc = Timecode(string: startText, rate: clock.rate), let track {
                    clock = CuePointClock(start: tc); CuePointClock.save(clock, for: track); rebuildExports()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The timecode at the very start of the audio file.") }
    }

    // MARK: Header

    private func header(_ track: Track) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(clock.timecode(at: engine.currentTime).description)
                    .font(Theme.numeric(isPad ? 52 : 38, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: 10) {
                    Text(clock.trackTime(engine.currentTime).description)
                    Text("of \(clock.trackTime(track.duration).description)")
                        .foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.numeric(13))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button { startText = clock.start.description; editingStart = true } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Start").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    Text(clock.start.description).font(Theme.numeric(14)).foregroundStyle(Theme.textPrimary)
                    Text("\(clock.rate.operatorLabel) fps").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start timecode \(clock.start.description). Edit")
        }
        .padding(.horizontal, isPad ? 0 : Theme.pad).padding(.vertical, isPad ? 0 : 10)
    }

    // MARK: Timeline

    private func timeline(_ track: Track) -> some View {
        TimelineEditor(duration: track.duration, peaks: peaks, points: points, clock: clock,
                       playhead: engine.currentTime, isPlaying: engine.transport == .playing,
                       selected: $selected,
                       onSeek: { if loaded { engine.seek(to: $0) } },
                       onMove: move, span: $span,
                       beatGrid: beatGrid) // BEATGRID hook
            .id(track.id)
    }

    /// Editor-style strip above the timeline: playhead TC, marker count, zoom slider.
    private func timelineBar(_ track: Track) -> some View {
        HStack(spacing: 12) {
            if isPad {
                Text("Timeline").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Text("\(points.count) mark\(points.count == 1 ? "" : "s")").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            Button { zoom(2) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Zoom out")
            Slider(value: Binding(get: { zoomValue(track) }, set: { setZoom($0, track) }), in: 0...1)
                .frame(width: isPad ? 220 : 70)
                .tint(Theme.textSecondary)
                .accessibilityLabel("Zoom")
            Button { zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Zoom in")
            Button { span = max(2, track.duration) } label: { Text("Fit").font(Theme.label) }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Zoom to fit")
            BeatGridButton(grid: $beatGrid, track: track, clock: clock, compact: !isPad) // BEATGRID hook
            CueFlashMenu(compact: !isPad)
            exportMenu(prominent: true)
        }
        .padding(.horizontal, Theme.pad).padding(.vertical, 8)
    }

    /// Slider 0 = whole track, 1 = 2 seconds (log scale, like an editor's zoom).
    private func zoomValue(_ track: Track) -> Double {
        let maxSpan = max(2.0, track.duration)
        guard maxSpan > 2 else { return 0 }
        return 1 - log(span / 2) / log(maxSpan / 2)
    }
    private func setZoom(_ v: Double, _ track: Track) {
        let maxSpan = max(2.0, track.duration)
        span = 2 * pow(maxSpan / 2, 1 - v)
    }
    private func zoom(_ f: Double) {
        guard let track else { return }
        span = min(max(2, span * f), max(2, track.duration))
    }

    // MARK: Inspector

    @ViewBuilder private var inspectorPanel: some View {
        VStack(spacing: 0) {
            if let p = points.first(where: { $0.id == selected }) {
                inspector(p)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            list
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge).strokeBorder(Theme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge))
    }

    private func inspector(_ p: CuePoint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Mark \(number(of: p))").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(role: .destructive) { delete(p) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.stop).accessibilityLabel("Delete mark")
            }
            TextField("Name", text: Binding(get: { p.name }, set: { p.name = $0; scheduleSave() }))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .submitLabel(.done)
            HStack(spacing: 6) {
                stepButton("−1s") { shift(p, by: -1) }
                stepButton("−1f") { shift(p, by: -1 / clock.rate.fps) }
                Button { jump(to: p) } label: {
                    Text(clock.timecode(at: p.time).description).font(Theme.numeric(17)).foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to \(clock.timecode(at: p.time).description)")
                stepButton("+1f") { shift(p, by: 1 / clock.rate.fps) }
                stepButton("+1s") { shift(p, by: 1) }
            }
            HStack(spacing: 8) {
                ForEach(CuePointColor.allCases) { c in
                    let on = (p.colorHex ?? CuePointColor.amber.rawValue) == c.rawValue
                    Button { p.colorHex = c.rawValue; save() } label: {
                        Circle().fill(Color(hexString: c.rawValue) ?? .white)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(on ? Theme.textPrimary : .clear, lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.label)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
                Button("Move to playhead") { p.time = snapped(engine.currentTime); save() }
                    .font(Theme.caption.weight(.medium)).disabled(!loaded)
            }
        }
        .padding(14)
    }

    private func stepButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Theme.numeric(12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 40, height: 34)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Keyboard (Premiere-style)

    /// Invisible buttons carrying the editor shortcuts: M mark, Space play, J/K/L, ←/→ one frame
    /// (⇧ ten), ↑/↓ previous/next mark, Delete removes the selected mark, = and − zoom.
    private var shortcuts: some View {
        Group {
            Button("") { mark() }.keyboardShortcut("m", modifiers: [])
            Button("") { togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { nudgePlayhead(-5) }.keyboardShortcut("j", modifiers: [])
            Button("") { if loaded { engine.pause() } }.keyboardShortcut("k", modifiers: [])
            Button("") { if loaded { engine.play() } }.keyboardShortcut("l", modifiers: [])
            Button("") { frameStep(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { frameStep(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { frameStep(-10) }.keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { frameStep(10) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { stepPoint(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { stepPoint(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { if let p = points.first(where: { $0.id == selected }) { delete(p) } }.keyboardShortcut(.delete, modifiers: [])
            Button("") { zoom(0.5) }.keyboardShortcut("=", modifiers: [])
            Button("") { zoom(2) }.keyboardShortcut("-", modifiers: [])
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 10) {
            key("backward.end", "Previous point") { stepPoint(-1) }
            key("gobackward.5", "Back 5 seconds") { nudgePlayhead(-5) }
            key(engine.transport == .playing ? "pause.fill" : "play.fill",
                engine.transport == .playing ? "Pause" : "Play") { togglePlay() }
            key("goforward.5", "Forward 5 seconds") { nudgePlayhead(5) }
            key("forward.end", "Next point") { stepPoint(1) }
            Button(action: mark) {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                    Text("Mark").font(.system(size: 18, weight: .semibold))
                }
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Theme.standby, in: RoundedRectangle(cornerRadius: Theme.corner))
            }
            .buttonStyle(KeyPressStyle())
            .disabled(!loaded)
            .accessibilityHint("Adds a cue point at the playhead. Keyboard: M")
        }
        .padding(Theme.pad)
    }

    private func key(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(loaded ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: isPad ? 64 : 46, height: 56)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(KeyPressStyle())
        .disabled(!loaded)
        .accessibilityLabel(label)
    }

    // MARK: List

    private var list: some View {
        List {
            if points.isEmpty {
                Text("Play the track and tap Mark (or press M) at each moment you want a cue.")
                    .font(Theme.label).foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.surface)
            }
            ForEach(points) { p in row(p).listRowBackground(p.id == selected ? Theme.surfaceRaised : Theme.surface) }
                .onDelete { idx in
                    for i in idx { context.delete(points[i]) }
                    save()
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private func row(_ p: CuePoint) -> some View {
        let color = Color(hexString: p.colorHex ?? "") ?? Theme.standby
        return HStack(spacing: 12) {
            Menu {
                ForEach(CuePointColor.allCases) { c in
                    Button(c.label) { p.colorHex = c.rawValue; save() }
                }
            } label: {
                Text("\(number(of: p))")
                    .font(Theme.numeric(14, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 34, height: 28)
                    .background(color, in: RoundedRectangle(cornerRadius: 4))
            }
            .accessibilityLabel("Point \(number(of: p)) colour")

            TextField("Name", text: Binding(get: { p.name }, set: { p.name = $0 }))
                .font(Theme.label)
                .foregroundStyle(Theme.textPrimary)
                .focused($focusedName, equals: p.id)
                .submitLabel(.done)
                .onSubmit { save() }

            Button { jump(to: p) } label: {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(clock.timecode(at: p.time).description).font(Theme.numeric(14)).foregroundStyle(Theme.textPrimary)
                    Text(clock.trackTime(p.time).description).font(Theme.numeric(11)).foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to \(clock.timecode(at: p.time).description)")

            HStack(spacing: 4) {
                nudge(p, -1, "minus")
                nudge(p, 1, "plus")
            }
        }
        .padding(.vertical, 4)
    }

    private func nudge(_ p: CuePoint, _ frames: Int, _ symbol: String) -> some View {
        Button {
            p.time = max(0, p.time + Double(frames) / clock.rate.fps)
            save()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 28)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(frames < 0 ? "One frame earlier" : "One frame later")
    }

    // MARK: Menus

    private var trackMenu: some View {
        Menu {
            ForEach(tracks) { t in
                Button { track = t } label: {
                    if t.id == track?.id { Label(t.title, systemImage: "checkmark") } else { Text(t.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(track?.title ?? "Choose track").font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityLabel("Track, \(track?.title ?? "none")")
    }

    private func exportMenu(prominent: Bool) -> some View {
        Menu {
            Section("Export \(points.count) point\(points.count == 1 ? "" : "s")") {
                ForEach(exports) { f in
                    ShareLink(item: f.url) { Label { Text(f.title); Text(f.detail) } icon: { Image(systemName: "square.and.arrow.up") } }
                }
            }
            Section("disguise options") {
                Toggle("TC tag at track start", isOn: $options.tcTagAtStart)
                Toggle("Tag points as CUE numbers", isOn: $options.cueTags)
                Toggle("Section at each point", isOn: $options.sectionBreaks)
            }
        } label: {
            if prominent {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
                .font(Theme.label.weight(.semibold))
                .foregroundStyle(points.isEmpty ? Theme.textTertiary : Theme.background)
                .padding(.horizontal, 12).frame(height: 30)
                .background(points.isEmpty ? Theme.surfaceRaised : Theme.textPrimary, in: RoundedRectangle(cornerRadius: 4))
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(points.isEmpty)
        .onChange(of: options) { _, _ in rebuildExports() }
    }

    private var blockedBanner: some View {
        HStack(spacing: 10) {
            IndicatorLamp(color: Theme.standby, isOn: true, size: 9)
            Text("A cue is playing. Stop it to listen and mark here.").font(Theme.label).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Stop and mark") { engine.stop(); blocked = false; open() }.font(Theme.label.weight(.semibold))
        }
        .padding(Theme.pad)
        .background(Theme.surfaceRaised)
        .hairline(.bottom)
    }

    // MARK: Actions

    private func initialTrack() {
        if track == nil {
            track = ShellModel.shared.standbyCue?.track ?? ShellModel.shared.playlist?.orderedCues.compactMap(\.track).first ?? tracks.first
        }
        open()
    }

    private func open() {
        guard let track else { return }
        clock = CuePointClock.forTrack(track)
        beatGrid = BeatGridStore.load(trackID: track.id) // BEATGRID hook
        reload()
        peaks = []
        let url = track.fileURL, ch = track.ltcChannel == "left" ? 1 : 0
        Task { let p = await TimelinePeaks.load(url: url, channel: ch); if self.track?.fileURL == url { peaks = p } }
        if engine.transport == .playing, !loaded { blocked = true; return }
        blocked = false
        guard !loaded, !track.isMissing else { return }
        // Listen to the programme only: mute the side that carries LTC.
        var r = ChannelRouting()
        if track.ltcChannel == "right" { r.rightEnabled = false } else if track.ltcChannel == "left" { r.leftEnabled = false }
        try? engine.load(.file(track.fileURL), routing: r)
    }

    private func reload() {
        guard let track else { points = []; return }
        points = CuePoint.points(for: track.id, in: context)
        #if DEBUG
        // -seedMarks: sample marks for screenshots/QA (never plays audio).
        if points.isEmpty, ProcessInfo.processInfo.arguments.contains("-seedMarks") {
            for (t, n, c) in [(8.0, "Intro hit", CuePointColor.amber), (21.5, "Verse 1", .blue), (44.0, "Pre-chorus", .green),
                              (52.0, "Chorus drop", .red), (75.0, "Verse 2", .blue), (96.0, "Bridge", .purple)] {
                context.insert(CuePoint(trackID: track.id, time: t, name: n, colorHex: c.rawValue))
            }
            try? context.save()
            points = CuePoint.points(for: track.id, in: context)
            selected = points.dropFirst(3).first?.id
            span = 120
            engine.seek(to: 47)
        }
        #endif
        rebuildExports()
    }

    private func save() {
        try? context.save()
        reload()
    }

    private func mark() {
        guard let track, loaded else { return }
        // Snap to the nearest frame so exported times line up with the console's grid.
        let t = beatGrid?.snapped(engine.currentTime) ?? engine.currentTime // BEATGRID hook
        let f = (t * clock.rate.fps).rounded() / clock.rate.fps
        let n = points.count + 1
        let p = CuePoint(trackID: track.id, time: f, name: "Cue \(n)", colorHex: CuePointColor.amber.rawValue)
        context.insert(p)
        lastMarkID = p.id
        selected = p.id
        save()
        Haptics.tick()
    }

    private func snapped(_ t: TimeInterval) -> TimeInterval {
        let f = clock.rate.fps
        return max(0, (t * f).rounded() / f)
    }

    private func shift(_ p: CuePoint, by s: TimeInterval) {
        p.time = min(max(0, snapped(p.time + s)), track?.duration ?? .infinity)
        save()
    }

    private func delete(_ p: CuePoint) {
        if selected == p.id { selected = nil }
        context.delete(p)
        save()
    }

    private func frameStep(_ n: Int) {
        guard loaded, let track else { return }
        if engine.transport == .playing { engine.pause() }
        engine.seek(to: min(max(0, snapped(engine.currentTime) + Double(n) / clock.rate.fps), track.duration))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { try? context.save(); rebuildExports() }
        }
    }

    /// Live drag from the timeline: move now, save once the drag settles.
    private func move(_ p: CuePoint, to t: TimeInterval) {
        p.time = t
        points.sort { $0.time < $1.time }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { save() }
        }
    }

    private func togglePlay() { if loaded { engine.togglePlayPause() } }

    private func nudgePlayhead(_ s: TimeInterval) {
        guard loaded, let track else { return }
        engine.seek(to: min(max(0, engine.currentTime + s), track.duration))
    }

    private func jump(to p: CuePoint) {
        selected = p.id
        guard loaded else { return }
        engine.seek(to: p.time)
    }

    private func stepPoint(_ dir: Int) {
        let now = engine.currentTime
        let target = dir > 0 ? points.first(where: { $0.time > now + 0.05 }) : points.last(where: { $0.time < now - 0.25 })
        if let target { jump(to: target) } else if dir < 0 { engine.seek(to: 0) }
    }

    private func number(of p: CuePoint) -> Int { (points.firstIndex(where: { $0.id == p.id }) ?? 0) + 1 }

    private func rebuildExports() {
        guard let track, !points.isEmpty else { exports = []; return }
        let rows = points.enumerated().map { CuePointRow(number: $0.offset + 1, name: $0.element.name, time: $0.element.time, colorHex: $0.element.colorHex) }
        let name = track.title
        var out: [ExportFile] = []
        if let u = try? CuePointExport.write(CuePointExport.disguiseCueTable(trackName: name, rows: rows, clock: clock, options: options),
                                             name: CuePointExport.disguiseFileName(trackName: name)) {
            out.append(.init(title: "disguise cue table", detail: "objects/table · name must match the d3 track", url: u))
        }
        if let u = try? CuePointExport.write(CuePointExport.grandMA3Timecode(trackName: name, rows: rows, clock: clock, duration: track.duration),
                                             name: CuePointExport.grandMA3FileName(trackName: name)) {
            out.append(.init(title: "grandMA3 timecode (beta)", detail: "datapools/timecodes · Import Timecode", url: u))
        }
        if let u = try? CuePointExport.write(CuePointExport.csv(trackName: name, rows: rows, clock: clock),
                                             name: CuePointExport.csvFileName(trackName: name)) {
            out.append(.init(title: "CSV", detail: "Numbers, Excel, other marker tools", url: u))
        }
        exports = out
    }
}
