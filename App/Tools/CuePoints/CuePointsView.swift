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

    private let engine = PlaybackEngine.shared
    private var isPad: Bool { hSize == .regular }
    private var loaded: Bool { track.map { engine.source == .file($0.fileURL) } ?? false }

    struct ExportFile: Identifiable { let id = UUID(); let title: String; let detail: String; let url: URL }

    var body: some View {
        VStack(spacing: 0) {
            if let track {
                if blocked { blockedBanner }
                header(track)
                waveform(track)
                transport
                list
            } else {
                ContentUnavailableView("No tracks yet", systemImage: "waveform",
                                       description: Text("Import a track, then come back to mark cue points."))
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) { trackMenu }
            ToolbarItem(placement: .topBarTrailing) { exportMenu }
        }
        .onAppear(perform: initialTrack)
        .onDisappear {
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
        .padding(.horizontal, Theme.pad).padding(.vertical, 10)
    }

    // MARK: Waveform + markers

    private func waveform(_ track: Track) -> some View {
        WaveformOverviewView(overview: track.overview, channelCount: track.channelCount,
                             duration: track.duration, scrubEnabled: loaded)
            .frame(height: isPad ? 120 : 84)
            .overlay {
                GeometryReader { geo in
                    ForEach(points) { p in
                        let x = geo.size.width * CGFloat(track.duration > 0 ? p.time / track.duration : 0)
                        let color = Color(hexString: p.colorHex ?? "") ?? Theme.standby
                        Rectangle().fill(color)
                            .frame(width: 1.5, height: geo.size.height)
                            .position(x: x, y: geo.size.height / 2)
                            .allowsHitTesting(false)
                        Text("\(number(of: p))")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 3)
                            .background(color, in: RoundedRectangle(cornerRadius: 2))
                            .position(x: min(max(x, 8), geo.size.width - 8), y: 7)
                            .onTapGesture { jump(to: p) }
                    }
                }
            }
            .padding(.horizontal, Theme.pad)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 10) {
            key("backward.end", "Previous point") { stepPoint(-1) }
            key("gobackward.5", "Back 5 seconds") { nudgePlayhead(-5) }
            key(engine.transport == .playing ? "pause.fill" : "play.fill",
                engine.transport == .playing ? "Pause" : "Play") { togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
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
            .keyboardShortcut("m", modifiers: [])
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
            ForEach(points) { p in row(p).listRowBackground(Theme.surface) }
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

    private var exportMenu: some View {
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
            Label("Export", systemImage: "square.and.arrow.up")
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
        reload()
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
        rebuildExports()
    }

    private func save() {
        try? context.save()
        reload()
    }

    private func mark() {
        guard let track, loaded else { return }
        // Snap to the nearest frame so exported times line up with the console's grid.
        let f = (engine.currentTime * clock.rate.fps).rounded() / clock.rate.fps
        let n = points.count + 1
        let p = CuePoint(trackID: track.id, time: f, name: "Cue \(n)", colorHex: CuePointColor.amber.rawValue)
        context.insert(p)
        lastMarkID = p.id
        save()
        Haptics.tick()
    }

    private func togglePlay() { if loaded { engine.togglePlayPause() } }

    private func nudgePlayhead(_ s: TimeInterval) {
        guard loaded, let track else { return }
        engine.seek(to: min(max(0, engine.currentTime + s), track.duration))
    }

    private func jump(to p: CuePoint) {
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
