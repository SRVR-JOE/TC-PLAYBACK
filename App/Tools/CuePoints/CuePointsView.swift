import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import TCKit

/// Cue points: listen to a track, tap Mark (or a type pad) to drop points, name and tidy them,
/// then export a disguise cue table, a grandMA3 timecode show or CSV. Points are saved per track;
/// cue types (lanes) are app-wide in `CuePointTypeStore`.
struct CuePointsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var hSize
    @Query(sort: \Track.title) private var tracks: [Track]
    @State private var track: Track?
    @State private var points: [CuePoint] = []
    @State private var clock = CuePointClock(start: Timecode(hours: 1, rate: .fps30))
    @State private var options = CuePointExport.DisguiseOptions()
    @State private var exports: [ExportFile] = []
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var blocked = false
    @State private var editingStart = false
    @State private var startText = ""
    @State private var lastMarkID: UUID?
    @FocusState private var field: Field?
    @State private var peaks: [Float] = []
    /// Primary selection (the inspector's mark); always inside `selection` when set.
    @State private var selected: UUID?
    @State private var selection: Set<UUID> = []
    @State private var selectMode = false
    @State private var saveTask: Task<Void, Never>?
    @State private var span: TimeInterval = 30
    @State private var beatGrid: BeatGrid? // BEATGRID hook
    @State private var showTypes = false
    // Name-as-you-drop
    @AppStorage("cuePoints.nameOnDrop") private var nameOnDrop = false
    // Live marking never stops playback unless this is turned on.
    @AppStorage("cuePoints.pauseWhileNaming") private var pauseWhileNaming = false
    @AppStorage("cuePoints.activeType") private var activeTypeRaw = ""
    @State private var naming: UUID?
    @State private var namingText = ""
    @State private var pausedForNaming = false
    @FocusState private var namingFocus: Bool
    // Live marking timing
    @AppStorage("cuePoints.tapDelayMs") private var tapDelayMs = 0.0
    @AppStorage("cuePoints.allowSpeakerDelay") private var allowSpeakerDelay = true
    @State private var droppedIDs: [UUID] = []
    @State private var undoVisible = false
    @State private var undoHideTask: Task<Void, Never>?
    @State private var tickedType: UUID?
    @State private var tickTask: Task<Void, Never>?
    // Labels
    @AppStorage("cuePoints.numberRepeats") private var numberRepeats = true
    @State private var showPresets = false
    @State private var passIndex: Int?
    @State private var passText = ""
    @FocusState private var passFocus: Bool
    // Cue caller
    @State private var showCalls = false
    @State private var showCallerSettings = false
    @State private var showCameras = false

    // VIDEO hook: optional panel shown above the timeline in both layouts (video sync builder).


    private let store = CuePointTypeStore.shared
    private let labels = CueLabelPresetStore.shared
    private let engine = PlaybackEngine.shared
    private var isPad: Bool { hSize == .regular }
    private var loaded: Bool { track.map { engine.source == .file($0.fileURL) } ?? false }
    private var index: CuePointIndex { CuePointIndex(points: points, types: store.types) }
    private var activeType: CuePointType { store.type(for: UUID(uuidString: activeTypeRaw)) }
    private var selectedPoints: [CuePoint] { points.filter { selection.contains($0.id) } }
    /// The one mark the single-mark inspector shows (nil when none or several are selected).
    private var single: CuePoint? { selection.count <= 1 ? points.first(where: { $0.id == selected }) : nil }
    private var typing: Bool { field != nil || namingFocus || passFocus }

    #if DEBUG
    private static var reseeded = false
    #endif

    private enum Field: Hashable { case row(UUID), name, cueNumber, fade, call(Int) }

    struct ExportFile: Identifiable { let id = UUID(); let format: CuePointFormat; let title: String; let detail: String; let urls: [URL] }

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
                                CueVideoPanel(track: track, clock: clock, layout: .wide) // VIDEO hook
                                TriggerReadout(points: points, clock: clock, playhead: engine.currentTime,
                                               isPlaying: engine.transport == .playing, large: true, index: index)
                                transport
                                padsOrPass
                            }
                            .frame(maxWidth: .infinity)
                            inspectorPanel.frame(width: min(420, geo.size.width * 0.36))
                        }
                        .padding(Theme.pad)
                        .frame(height: geo.size.height * 0.52)
                        // VIDEO hook: slot above the timeline (wide layout).
                        timelineBar(track)
                        timeline(track).frame(maxHeight: .infinity)
                            .padding([.horizontal, .bottom], Theme.pad)
                    } else {
                        header(track)
                        TriggerReadout(points: points, clock: clock, playhead: engine.currentTime,
                                       isPlaying: engine.transport == .playing, index: index)
                            .padding(.horizontal, Theme.pad)
                        CueVideoPanel(track: track, clock: clock, layout: .strip).padding([.horizontal, .top], Theme.pad) // VIDEO hook
                        timelineBar(track)
                        timeline(track).frame(height: 180).padding(.horizontal, Theme.pad)
                        transport
                        padsOrPass.padding(.horizontal, Theme.pad).padding(.bottom, 10)
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
            ToolbarItem(placement: .topBarTrailing) {
                CueCallerToolbarMenu(compact: !isPad, onShowCalls: { showCalls = true }, onShowSettings: { showCallerSettings = true })
            }
            ToolbarItem(placement: .topBarTrailing) { exportMenu(prominent: false) }
            ToolbarItem(placement: .topBarTrailing) { if let track { CueVideoMenu(track: track) } } // VIDEO hook
        }
        .onAppear(perform: initialTrack)
        #if DEBUG
        .task {
            if CueCallerPreviewHost.mode == "calls" {
                CueCallerPreviewHost.seedSampleAreas()
                try? await Task.sleep(for: .seconds(1)); showCalls = true
            }
            if CueCallerPreviewHost.mode == "cameras" { try? await Task.sleep(for: .seconds(1)); showCameras = true }
        }
        #endif
        #if DEBUG
        .task {
            // -flashTest: fire the flash 2 s after opening (QA only).
            if ProcessInfo.processInfo.arguments.contains("-flashTest") {
                try? await Task.sleep(for: .seconds(2)); CueFlash.fire(markHex: CuePointColor.red.rawValue)
            }
            // -liveMarkTest (with -silentOutput): play, drop 8 marks 0.25 s apart through the same
            // path as a tap, and write a report. Verifies marking never stops playback.
            if ProcessInfo.processInfo.arguments.contains("-liveMarkTest") {
                for _ in 0..<100 where !loaded { try? await Task.sleep(for: .milliseconds(100)) }
                guard loaded else { return }
                engine.seek(to: 30); engine.play()
                try? await Task.sleep(for: .seconds(1))
                var lines: [String] = ["loaded=\(loaded) nameOnDrop=\(nameOnDrop) tapDelayMs=\(tapDelayMs) speakerDelay=\(allowSpeakerDelay) latency=\(String(format: "%.4f", CueMarkTiming.sessionOutputLatency))"]
                let before = points.count
                for i in 0..<8 {
                    let ph = engine.preciseTime
                    mark(type: activeType)
                    let t = points.first(where: { $0.id == lastMarkID })?.time ?? -1
                    lines.append(String(format: "tap %d playhead %.3f mark %.3f diff %+.3f playing %@", i + 1, ph, t, t - ph,
                                        engine.transport == .playing ? "yes" : "NO"))
                    try? await Task.sleep(for: .milliseconds(250))
                }
                lines.append("marks added \(points.count - before), still playing: \(engine.transport == .playing ? "yes" : "NO"), playhead \(String(format: "%.3f", engine.currentTime))")
                // Play back over the new marks and log when each trigger fires vs when its mark is heard.
                let first = points.filter { $0.time >= 30 }.map(\.time).min() ?? 30
                CueTriggerClock.shared.debugLog = []
                engine.seek(to: max(0, first - 1)); engine.play()
                try? await Task.sleep(for: .seconds(4))
                for e in CueTriggerClock.shared.debugLog {
                    lines.append(String(format: "trigger mark %.3f  heard at fire %.3f (%+.1f ms)  heard when on screen %.3f (%+.1f ms)",
                                        e.mark, e.heardAtFire, (e.heardAtFire - e.mark) * 1000, e.heardOnGlass, (e.heardOnGlass - e.mark) * 1000))
                }
                lines.append("triggers fired \(CueTriggerClock.shared.debugLog.count)")
                engine.stop()
                let report = lines.joined(separator: "\n")
                print("LIVEMARKTEST\n" + report)
                try? report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("liveMarkTest.txt"), atomically: true, encoding: .utf8)
            }
        }
        #endif
        .onDisappear {
            Torch.off()
            if loaded { engine.stop() }
        }
        .onChange(of: track?.id) { _, _ in open() }
        .onChange(of: store.types) { _, _ in rebuildExports() }
        .sheet(isPresented: $showTypes, onDismiss: reload) {
            CuePointTypesSheet(store: store, counts: typeCounts, onRenumber: renumber)
        }
        .sheet(isPresented: $showPresets) { CueLabelPresetsSheet(store: labels) }
        .sheet(isPresented: $showCalls, onDismiss: save) {
            CueCallsReviewSheet(trackTitle: track?.title ?? "", points: points, index: index, clock: clock, onChange: { try? context.save() })
        }
        .sheet(isPresented: $showCallerSettings) { CueCallerSettingsSheet() }
        .sheet(isPresented: $showCameras) { CamerasSheet() }
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
                       // Heard position: the line crosses a mark when you hear it (speaker delay allowed for).
                       playhead: engine.transport == .playing && allowSpeakerDelay
                           ? max(0, engine.currentTime - CueTriggerClock.outputDelay) : engine.currentTime,
                       isPlaying: engine.transport == .playing,
                       selected: $selected,
                       onSeek: { if loaded { engine.seek(to: $0) } },
                       onMove: move, span: $span,
                       beatGrid: beatGrid, // BEATGRID hook
                       lanes: store.visible, index: index, selection: $selection, selectMode: selectMode,
                       onRename: { p, name in p.name = name; save() },
                       videoLane: CueVideoController.shared.timelineLane) // VIDEO hook
            .id(track.id)
            .overlay(alignment: .bottom) { namingOverlay.padding(8) }
            .overlay(alignment: .topTrailing) { undoButton.padding(.top, 26).padding(.trailing, 8) }
            .onChange(of: selected) { _, id in
                if let id { activeTypeRaw = index.type(id: points.first(where: { $0.id == id })?.typeID).id.uuidString }
            }
    }

    /// Editor-style strip above the timeline: marker count, select mode, marking options, zoom.
    private func timelineBar(_ track: Track) -> some View {
        HStack(spacing: isPad ? 12 : 8) {
            if isPad {
                Text("Timeline").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Text("\(points.count) mark\(points.count == 1 ? "" : "s")").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            barButton("Select", symbol: "rectangle.dashed", on: selectMode) { selectMode.toggle() }
                .accessibilityHint("When on, taps add marks to the selection and dragging draws a selection box")
            barButton("Label marks", symbol: "character.cursor.ibeam", on: passIndex != nil) {
                passIndex == nil ? startPass() : endPass()
            }
            .disabled(points.isEmpty)
            .accessibilityHint("Steps through the marks one by one so you can name each")
            markingMenu
            Spacer(minLength: 0)
            if isPad {
                Button { zoom(2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Zoom out")
            }
            Slider(value: Binding(get: { zoomValue(track) }, set: { setZoom($0, track) }), in: 0...1)
                .frame(width: isPad ? 160 : 56)
                .tint(Theme.textSecondary)
                .accessibilityLabel("Zoom")
            if isPad {
                Button { zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Zoom in")
            }
            Button { span = max(2, track.duration) } label: { Text("Fit").font(Theme.label).fixedSize() }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Zoom to fit")
            BeatGridButton(grid: $beatGrid, track: track, clock: clock, compact: !isPad) // BEATGRID hook
            CueFlashMenu(compact: !isPad)
            exportMenu(prominent: true)
        }
        .padding(.horizontal, Theme.pad).padding(.vertical, 8)
    }

    private func barButton(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                if isPad { Text(title) }
            }
            .font(Theme.label)
            .fixedSize()
            .foregroundStyle(on ? Theme.background : Theme.textSecondary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(on ? Theme.textPrimary : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Marking options: name on drop, pause while naming, cue types, renumbering.
    private var markingMenu: some View {
        Menu {
            Section("While marking") {
                Toggle("Name marks as you drop them", isOn: $nameOnDrop)
                Toggle("Pause while naming", isOn: $pauseWhileNaming).disabled(!nameOnDrop)
                Toggle("Number repeated labels", isOn: $numberRepeats)
            }
            Section("Timing of live marks") {
                Picker("Tap delay", selection: $tapDelayMs) {
                    ForEach([0.0, -25, -50, -75, -100, -125, -150], id: \.self) { v in
                        Text(v == 0 ? "No tap delay" : "\(Int(v)) ms").tag(v)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Allow for speaker delay", isOn: $allowSpeakerDelay)
            }
            Section {
                Button { startPass() } label: { Label("Label marks one by one", systemImage: "character.cursor.ibeam") }
                    .disabled(points.isEmpty)
                Button { showPresets = true } label: { Label("Edit label presets…", systemImage: "text.badge.plus") }
            }
            Section {
                Menu("Renumber cues") {
                    ForEach(store.types) { t in
                        Button("\(t.name) (\(typeCounts[t.id] ?? 0))") { renumber(t) }.disabled((typeCounts[t.id] ?? 0) == 0)
                    }
                }
                Button { showTypes = true } label: { Label("Cue types…", systemImage: "list.bullet.rectangle") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                if isPad { Text("Marking") }
            }
            .font(Theme.label)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .accessibilityLabel("Marking options")
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
            if selection.count > 1 {
                multiInspector
                Rectangle().fill(Theme.hairline).frame(height: 1)
            } else if let p = single {
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
        let idx = index
        let type = idx.type(of: p)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                typeMenu(current: type.id) { t in p.typeID = t.id == CuePointType.defaultID ? nil : t.id; save() }
                Text("Cue \(idx.number(of: p))").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(role: .destructive) { delete(p) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.stop).accessibilityLabel("Delete mark")
            }
            TextField("Name", text: Binding(get: { p.name }, set: { p.name = $0; scheduleSave() }))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .focused($field, equals: .name)
                .submitLabel(.done)
                .onSubmit { field = nil; save() }
            CueLabelPresetBar(labels: labels.labels, onPick: { applyLabel($0, to: [p]) }, onEdit: { showPresets = true })
            labelled(p.callCount > 1 ? "Calls" : "Call") {
                // Stacked calls, one per line, with the camera and shot keys (CueCallStackViews.swift).
                CueCallStackField(note: Binding(get: { p.callNote }, set: { p.callNote = $0; scheduleSave() }),
                                  focus: $field, lineFocus: { .call($0) }, compact: !isPad,
                                  onNextMark: { nextCallNote(after: p) }, onEditCameras: { showCameras = true })
                    .id(p.id)
            }
            HStack(alignment: .top, spacing: 10) {
                labelled("Cue number") {
                    TextField(String(idx.position(of: p)), text: Binding(get: { p.cueID }, set: { p.cueID = $0; scheduleSave() }))
                        .keyboardType(.numbersAndPunctuation).submitLabel(.done)
                        .focused($field, equals: .cueNumber)
                        .font(Theme.numeric(15)).foregroundStyle(Theme.textPrimary)
                        .fieldBox()
                }
                .frame(width: 104)
                labelled("Fade") {
                    HStack(spacing: 8) {
                        TextField("None", text: Binding(get: { p.fade }, set: { p.fade = $0; scheduleSave() }))
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .focused($field, equals: .fade)
                            .font(Theme.numeric(15)).foregroundStyle(Theme.textPrimary)
                            .fieldBox()
                            .frame(width: 70)
                        Text(fadeSummary(p)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            .lineLimit(2).minimumScaleFactor(0.8)
                    }
                }
            }
            HStack(spacing: 6) {
                stepButton("−10f") { shift(p, frames: -10) }
                stepButton("−1f") { shift(p, frames: -1) }
                Button { jump(to: p) } label: {
                    Text(clock.timecode(at: p.time).description).font(Theme.numeric(17)).foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to \(clock.timecode(at: p.time).description)")
                stepButton("+1f") { shift(p, frames: 1) }
                stepButton("+10f") { shift(p, frames: 10) }
            }
            HStack(spacing: 8) {
                colourSwatches(current: idx.colorHex(of: p)) { hex in p.colorHex = hex == type.colorHex ? nil : hex; save() }
                Spacer()
                Button("Move to playhead") { p.time = snapped(engine.currentTime); save() }
                    .font(Theme.caption.weight(.medium)).disabled(!loaded)
            }
        }
        .padding(14)
    }

    /// Several marks selected: nudge, retype, recolour, move as a block, delete.
    private var multiInspector: some View {
        let sel = selectedPoints
        let types = Set(sel.map { index.type(of: $0).id })
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(sel.count) marks selected").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Clear") { select(nil) }.font(Theme.caption.weight(.medium))
                Button(role: .destructive) { deleteSelection() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.stop).accessibilityLabel("Delete \(sel.count) marks")
            }
            HStack(spacing: 6) {
                stepButton("−10f") { nudgeSelection(frames: -10) }
                stepButton("−1f") { nudgeSelection(frames: -1) }
                Text(sel.first.map { clock.timecode(at: $0.time).description } ?? "")
                    .font(Theme.numeric(15)).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .accessibilityLabel("First selected mark at \(sel.first.map { clock.timecode(at: $0.time).description } ?? "")")
                stepButton("+1f") { nudgeSelection(frames: 1) }
                stepButton("+10f") { nudgeSelection(frames: 10) }
            }
            HStack(spacing: 10) {
                typeMenu(current: types.count == 1 ? types.first : nil) { t in
                    for p in sel { p.typeID = t.id == CuePointType.defaultID ? nil : t.id }
                    save()
                }
                Spacer()
                Button("Move first to playhead") { moveSelectionFirst(to: engine.currentTime) }
                    .font(Theme.caption.weight(.medium)).disabled(!loaded)
            }
            CueLabelPresetBar(labels: labels.labels, onPick: { applyLabel($0, to: sel) }, onEdit: { showPresets = true })
            HStack(spacing: 8) {
                let hexes = Set(sel.map { index.colorHex(of: $0) })
                colourSwatches(current: hexes.count == 1 ? hexes.first : nil) { hex in
                    for p in sel { p.colorHex = hex == index.type(of: p).colorHex ? nil : hex }
                    save()
                }
                Spacer()
            }
        }
        .padding(14)
    }

    private func labelled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func typeMenu(current: UUID?, _ pick: @escaping (CuePointType) -> Void) -> some View {
        let t = current.map { store.type(for: $0) }
        return Menu {
            ForEach(store.types) { type in
                Button { pick(type) } label: {
                    if type.id == current { Label(type.name, systemImage: "checkmark") } else { Text(type.name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(t.flatMap { Color(hexString: $0.colorHex) } ?? Theme.textTertiary)
                    .frame(width: 10, height: 10)
                Text(t?.name ?? "Mixed types").font(Theme.label).foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .accessibilityLabel("Type, \(t?.name ?? "mixed")")
    }

    private func colourSwatches(current: String?, _ pick: @escaping (String) -> Void) -> some View {
        ForEach(CuePointColor.allCases) { c in
            let on = current == c.rawValue
            Button { pick(c.rawValue) } label: {
                Circle().fill(Color(hexString: c.rawValue) ?? .white)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(on ? Theme.textPrimary : .clear, lineWidth: 2).padding(-3))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(c.label)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
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

    /// "2.0 s", "In 1.0 s, out 2.0 s", "Until next: 3.5 s"…
    private func fadeSummary(_ p: CuePoint) -> String {
        let t = p.fade.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "2, + or 1/2" }
        let f = CueFade.resolve(t, at: p.time, nextSameType: nextSameType(p)?.time)
        func s(_ v: Double) -> String { String(format: "%.1f s", v) }
        switch (f.in, f.out) {
        case (nil, nil): return t == "+" ? "No later cue of this type" : "Not a fade time"
        case let (a?, b?) where a == b: return t == "+" ? "Until next: \(s(a))" : s(a)
        case let (a, b): return "In \(a.map(s) ?? "–"), out \(b.map(s) ?? "–")"
        }
    }

    // MARK: Keyboard (Premiere-style)

    /// Invisible buttons carrying the editor shortcuts: M mark (current type), 1…9 and 0 mark the
    /// matching visible type, Space play, J/K/L, ←/→ one frame (⇧ ten), ⌥←/→ nudge the selection
    /// (⌥⇧ ten frames), ↑/↓ previous/next mark, Delete removes the selection, Esc clears it,
    /// = and − zoom, ⌘Z undoes the last mark, Return names the selected mark. Off while a text
    /// field has focus (the name fields handle Return and Escape themselves).
    private var shortcuts: some View {
        Group {
            Button("") { mark() }.keyboardShortcut("m", modifiers: [])
            ForEach(0..<10, id: \.self) { i in
                Button("") { markVisible(i) }.keyboardShortcut(KeyEquivalent(Character(String((i + 1) % 10))), modifiers: [])
            }
            Button("") { togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { nudgePlayhead(-5) }.keyboardShortcut("j", modifiers: [])
            Button("") { if loaded { engine.pause() } }.keyboardShortcut("k", modifiers: [])
            Button("") { if loaded { engine.play() } }.keyboardShortcut("l", modifiers: [])
            Button("") { frameStep(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { frameStep(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { frameStep(-10) }.keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { frameStep(10) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { nudgeSelection(frames: -1) }.keyboardShortcut(.leftArrow, modifiers: .option)
            Button("") { nudgeSelection(frames: 1) }.keyboardShortcut(.rightArrow, modifiers: .option)
            Button("") { nudgeSelection(frames: -10) }.keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
            Button("") { nudgeSelection(frames: 10) }.keyboardShortcut(.rightArrow, modifiers: [.option, .shift])
            Button("") { stepPoint(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { stepPoint(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { select(nil) }.keyboardShortcut(.escape, modifiers: [])
            Button("") { undoLastMark() }.keyboardShortcut("z", modifiers: .command)
            Button("") { if single != nil { field = .name } }.keyboardShortcut(.return, modifiers: [])
            Button("") { zoom(0.5) }.keyboardShortcut("=", modifiers: [])
            Button("") { zoom(2) }.keyboardShortcut("-", modifiers: [])
        }
        .disabled(typing)
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
            // Fires on touch-down so a live mark lands when the finger hits, not on release.
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mark").font(.system(size: 18, weight: .semibold))
                    Text(activeType.name).font(.system(size: 11, weight: .medium)).opacity(0.75).lineLimit(1)
                }
            }
            .foregroundStyle(loaded ? Theme.background : Theme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: isPad ? 56 : 64)
            .background(loaded ? Theme.standby : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.textPrimary, lineWidth: 3)
                .opacity(tickedType == activeType.id ? 1 : 0))
            .overlay(TouchDownArea(label: "Mark \(activeType.name)", enabled: loaded) { mark() })
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

    /// Type pads under the transport (always there for live marking), or the label pass.
    @ViewBuilder private var padsOrPass: some View {
        if let i = passIndex, i < points.count {
            let p = points[i]
            CueLabelPassBar(position: i + 1, count: points.count, cueLabel: index.number(of: p), colorHex: index.colorHex(of: p),
                            text: $passText, focus: $passFocus, presets: labels.labels,
                            onNext: { passStep(1) }, onBack: { passStep(-1) }, onDone: endPass,
                            onPreset: { applyLabel($0, to: [p]); passText = p.name; passStep(1, saveText: false) },
                            onEditPresets: { showPresets = true })
        } else if !store.visible.isEmpty {
            CueTypePads(types: store.visible, active: activeType.id, enabled: loaded, ticked: tickedType,
                        height: 56, showKeys: isPad) { mark(type: $0) }
        }
    }

    /// Name field over the timeline right after a drop. Doesn't block: pads keep marking.
    @ViewBuilder private var namingOverlay: some View {
        if let id = naming, let p = points.first(where: { $0.id == id }) {
            CueDropNameField(text: $namingText, placeholder: p.name, colorHex: index.colorHex(of: p), focus: $namingFocus,
                             presets: labels.labels, onCommit: commitNaming, onDismiss: dismissNaming,
                             onPreset: { applyLabel($0, to: [p]); dismissNaming() }, onEditPresets: { showPresets = true })
                .frame(maxWidth: 560)
        }
    }

    /// Appears for a few seconds after each drop.
    @ViewBuilder private var undoButton: some View {
        if undoVisible, let id = droppedIDs.last, let p = points.first(where: { $0.id == id }) {
            Button { undoLastMark() } label: {
                Label("Undo \(p.name)", systemImage: "arrow.uturn.backward")
                    .font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Keyboard: Command Z")
        }
    }

    // MARK: List

    private var list: some View {
        let idx = index
        return List {
            if points.isEmpty {
                Text("Play the track and tap Mark, a type pad, or press M or 1 to 0 at each moment you want a cue.")
                    .font(Theme.label).foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.surface)
            }
            ForEach(points) { p in
                row(p, idx).listRowBackground(selection.contains(p.id) ? Theme.surfaceRaised : Theme.surface)
            }
            .onDelete { offsets in
                for i in offsets { selection.remove(points[i].id); context.delete(points[i]) }
                if let s = selected, !selection.contains(s) { selected = nil }
                save()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private func row(_ p: CuePoint, _ idx: CuePointIndex) -> some View {
        let type = idx.type(of: p)
        let color = Color(hexString: idx.colorHex(of: p)) ?? Theme.standby
        let fade = p.fade.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 10) {
            Button { tapRow(p) } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(hexString: type.colorHex) ?? Theme.standby).frame(width: 4, height: 30)
                    Text(idx.number(of: p))
                        .font(Theme.numeric(14, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: 40, height: 28)
                        .background(color, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(type.name) cue \(idx.number(of: p)). Select")

            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: Binding(get: { p.name }, set: { p.name = $0 }))
                    .font(Theme.label)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($field, equals: .row(p.id))
                    .submitLabel(.done)
                    .onSubmit { save() }
                HStack(spacing: 5) {
                    Text(fade.isEmpty ? type.name : "\(type.name) · Fade \(fade)")
                    if !p.callLines.isEmpty {
                        Image(systemName: "speaker.wave.1").font(.system(size: 9))
                        if p.callCount > 1 { Text("\(p.callCount)").font(Theme.numeric(10, weight: .semibold)) }
                        Text(CueCallStack.summary(p.callNote)).lineLimit(1)
                    }
                }
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }

            Button { jump(to: p) } label: {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(clock.timecode(at: p.time).description).font(Theme.numeric(14)).foregroundStyle(Theme.textPrimary)
                    Text(clock.trackTime(p.time).description).font(Theme.numeric(11)).foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to \(clock.timecode(at: p.time).description)")

            if isPad {
                HStack(spacing: 4) {
                    nudge(p, -1, "minus")
                    nudge(p, 1, "plus")
                }
            }
        }
        .padding(.vertical, 2)
        .simultaneousGesture(TapGesture(count: 2).onEnded { field = .row(p.id) })
        .contextMenu {
            Button { toggleInSelection(p) } label: {
                selection.contains(p.id) ? Label("Remove from selection", systemImage: "minus.circle")
                                         : Label("Add to selection", systemImage: "plus.circle")
            }
            Button { jump(to: p) } label: { Label("Go to mark", systemImage: "arrow.right.to.line") }
            Button(role: .destructive) { delete(p) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func nudge(_ p: CuePoint, _ frames: Int, _ symbol: String) -> some View {
        Button {
            shift(p, frames: frames)
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

    static let exportGroups: [(title: String, formats: [CuePointFormat])] = [
        ("Media servers", [.disguise, .disguisePerType]),
        ("Lighting consoles", [.grandMA3Timecode, .grandMA3CueListMacro, .eosASCII, .eosCSV, .chamsys]),
        ("Audio and other", [.reaper, .audition, .qlab, .csv]),
    ]

    private func exportMenu(prominent: Bool) -> some View {
        Menu {
            ForEach(Self.exportGroups, id: \.title) { g in
                Section(g.title) {
                    ForEach(exports.filter { g.formats.contains($0.format) }) { f in
                        ShareLink(items: f.urls) { Label { Text(f.title); Text(f.detail) } icon: { Image(systemName: "square.and.arrow.up") } }
                    }
                }
            }
            Section("disguise options") {
                Toggle("TC tag at track start", isOn: $options.tcTagAtStart)
                Toggle("Tag points as CUE numbers", isOn: $options.cueTags)
                Toggle("Section at each point", isOn: $options.sectionBreaks)
            }
            Section {
                Button { showImporter = true } label: { Label("Import marks…", systemImage: "square.and.arrow.down") }
            }
        } label: {
            if prominent {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
                .font(Theme.label.weight(.semibold))
                .fixedSize()
                .foregroundStyle(points.isEmpty ? Theme.textTertiary : Theme.background)
                .padding(.horizontal, 12).frame(height: 30)
                .background(points.isEmpty ? Theme.surfaceRaised : Theme.textPrimary, in: RoundedRectangle(cornerRadius: 4))
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(track == nil)
        .onChange(of: options) { _, _ in rebuildExports() }
        .onChange(of: beatGrid) { _, _ in rebuildExports() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: CuePointImport.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.commaSeparatedText, .tabSeparatedText, .xml, .wav, .plainText],
                      allowsMultipleSelection: false) { r in
            if case .success(let urls) = r, let u = urls.first { importMarks(from: u) }
        }
        .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
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
        reload()   // drops selections that aren't in this track
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-seedMarks") { engine.seek(to: 47) }
        #endif
    }

    private func reload() {
        guard let track else { points = []; return }
        points = CuePoint.points(for: track.id, in: context)
        #if DEBUG
        // -seedMarks: sample marks across the cue types for screenshots/QA (never plays audio).
        // -seedMulti also selects three of them; -reseedMarks clears the track's marks first (once).
        if ProcessInfo.processInfo.arguments.contains("-reseedMarks"), !Self.reseeded {
            Self.reseeded = true
            for p in points { context.delete(p) }
            try? context.save(); points = []
        }
        if points.isEmpty, ProcessInfo.processInfo.arguments.contains("-seedMarks") {
            let ts = store.types
            func type(_ i: Int) -> UUID? { i < ts.count && ts[i].id != CuePointType.defaultID ? ts[i].id : nil }
            for (t, n, ty, fade) in [(8.0, "Intro hit", 0, ""), (12.0, "Blackout", 1, "0"), (21.5, "Verse 1 look", 1, "2"),
                                     (22.0, "Verse 1", 0, ""), (30.0, "Screens on", 2, "+"), (44.0, "Pre-chorus", 0, ""),
                                     (44.0, "Build", 1, "1/2"), (52.0, "Chorus drop", 0, ""), (52.0, "Gerbs", 3, ""),
                                     (52.0, "Chorus content", 2, ""), (75.0, "Verse 2", 0, ""), (96.0, "Bridge", 0, "")] {
                let p = CuePoint(trackID: track.id, time: t, name: n)
                p.typeID = type(ty); p.fade = fade
                context.insert(p)
            }
            try? context.save()
            points = CuePoint.points(for: track.id, in: context)
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-cueCallerPreview") {
                let notes = ["Intro hit": "Camera 3, push in slow", "Verse 1": "Camera 1, tight on vocal",
                             "Pre-chorus": "Jib, sweep stage left", "Chorus drop": "Wide on the band, all cameras",
                             "Screens on": "Camera 4, hold the screens", "Bridge": "Camera 2, slow pull out",
                             // Stacked: three calls on one mark, and a same-frame mark in another lane.
                             "Chorus content": "Steadicam, follow the singer"]
                for p in points { if let n = notes[p.name] { p.callNote = n } }
                if args.contains("-stackPreview"), let v = points.first(where: { $0.name == "Verse 1" }) {
                    v.callNote = "Camera 3, push in\nCamera 1, tight on vocal\nCamera 2, wide"
                }
                if let drop = points.first(where: { $0.name == "Chorus drop" }) {
                    CueCallerUIModel.shared.setOverride("Abierto a la banda, todas las cámaras", markID: drop.id, language: "es-MX", note: drop.callNote)
                }
                try? context.save()
            }
            if ProcessInfo.processInfo.arguments.contains("-seedMulti") {
                selection = Set(points.filter { $0.time >= 44 && $0.time <= 52 }.prefix(3).map(\.id)); selected = selection.first
            } else {
                let pick = args.contains("-stackPreview") ? "Verse 1" : args.contains("-cueCallerPreview") ? "Chorus drop" : "Build"
                select(points.first(where: { $0.name == pick })?.id)
            }
            span = 120
        }
        #endif
        // Drop selections of points that no longer exist.
        let ids = Set(points.map(\.id))
        selection.formIntersection(ids)
        if let s = selected, !ids.contains(s) { selected = nil }
        rebuildExports()
    }

    private func save() {
        try? context.save()
        reload()
    }

    /// Selects one mark (nil clears the selection).
    private func select(_ id: UUID?) {
        selected = id
        selection = id.map { [$0] } ?? []
    }

    private func toggleInSelection(_ p: CuePoint) {
        if selection.contains(p.id) {
            selection.remove(p.id)
            if selected == p.id { selected = points.first(where: { selection.contains($0.id) })?.id }
        } else {
            selection.insert(p.id); selected = p.id
        }
    }

    private func tapRow(_ p: CuePoint) {
        if HardwareKeys.shift || selectMode { toggleInSelection(p) } else { select(p.id) }
    }

    /// Drop a mark of the current type (M / the Mark button).
    private func mark() { mark(type: activeType) }

    /// Keys 1…9, 0: the Nth visible type.
    private func markVisible(_ i: Int) {
        let v = store.visible
        guard i < v.count else { return }
        mark(type: v[i])
    }

    /// Time for a mark made right now: playhead read at touch-down, extrapolated past the
    /// engine's 30 Hz updates, less speaker delay and tap delay while playing.
    private func captureTime() -> TimeInterval {
        let playing = engine.transport == .playing
        // While playing, read the render thread's position directly (sample-accurate) rather than
        // the 30 Hz published value, so a mark lands where the finger hit.
        let ph = playing ? engine.preciseTime : engine.currentTime
        return CueMarkTiming.markTime(playhead: ph, playing: playing, tapDelayMs: tapDelayMs,
                                      outputLatency: allowSpeakerDelay ? CueMarkTiming.sessionOutputLatency : 0,
                                      fps: clock.rate.fps, duration: track?.duration ?? 0)
    }

    /// Live-safe drop: never pauses or seeks, and saves lazily so rapid taps all land.
    private func mark(type: CuePointType) {
        let raw = captureTime()
        let f = beatGrid.map { snapped($0.snapped(raw)) } ?? raw // BEATGRID hook: snap live marks to the grid
        guard let track, loaded else { return }
        let idx = index
        let same = points.filter { idx.type(of: $0).id == type.id }
        // Ripple: once a type has typed cue numbers, a mark dropped between 10 and 11 becomes 10.5.
        var cueID = ""
        if same.contains(where: { !$0.cueID.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let prev = same.last(where: { $0.time <= f }), next = same.first(where: { $0.time > f })
            cueID = CuePointNumbering.between(prev.map(idx.number(of:)), next.map(idx.number(of:)))
        }
        let position = same.filter { $0.time <= f }.count + 1
        let p = CuePoint(trackID: track.id, time: f, name: "\(type.name) \(cueID.isEmpty ? String(position) : cueID)")
        p.typeID = type.id == CuePointType.defaultID ? nil : type.id
        p.cueID = cueID
        context.insert(p)
        points.append(p)
        points.sort { $0.time < $1.time }
        lastMarkID = p.id
        droppedIDs.append(p.id)
        activeTypeRaw = type.id.uuidString
        if field != nil { field = nil }   // keys keep marking after a drop
        select(p.id)
        scheduleSave()
        MarkHaptics.tap()
        tick(type.id)
        showUndo()
        // A new drop moves naming to the newest mark; the earlier one keeps its name.
        if nameOnDrop { beginNaming(p) }
    }

    private func tick(_ type: UUID) {
        tickedType = type
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled { tickedType = nil }
        }
    }

    private func showUndo() {
        undoVisible = true
        undoHideTask?.cancel()
        undoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { undoVisible = false }
        }
    }

    /// Removes the most recent mark dropped this session (playback carries on).
    private func undoLastMark() {
        while let id = droppedIDs.popLast() {
            guard let p = points.first(where: { $0.id == id }) else { continue }
            if naming == id { dismissNaming() }
            selection.remove(id)
            if selected == id { selected = nil }
            context.delete(p)
            points.removeAll { $0.id == id }
            scheduleSave()
            Haptics.tick()
            break
        }
        if droppedIDs.isEmpty { undoVisible = false }
    }

    private func beginNaming(_ p: CuePoint) {
        naming = p.id
        namingText = ""
        if pauseWhileNaming, engine.transport == .playing { engine.pause(); pausedForNaming = true }
        // Only grab focus with a hardware keyboard: the on-screen one would cover the pads.
        if HardwareKeys.connected { namingFocus = true }
    }

    private func commitNaming() {
        if let id = naming, let p = points.first(where: { $0.id == id }) {
            let t = namingText.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { p.name = t; scheduleSave() }
        }
        dismissNaming()
    }

    private func dismissNaming() {
        naming = nil; namingText = ""; namingFocus = false
        if pausedForNaming { pausedForNaming = false; if loaded { engine.play() } }
    }

    // MARK: Labels

    /// Names marks with a preset. With "Number repeated labels" on, a label already used in the
    /// same type gets the next number ("Chorus 2").
    private func applyLabel(_ label: String, to marks: [CuePoint]) {
        let idx = index
        let targets = Set(marks.map(\.id))
        let byType = Dictionary(grouping: marks.sorted { $0.time < $1.time }) { idx.type(of: $0).id }
        for (typeID, ps) in byType {
            let others = points.filter { idx.type(of: $0).id == typeID && !targets.contains($0.id) }.map(\.name)
            for (p, n) in zip(ps, CueLabelNaming.apply(label, count: ps.count, otherNames: others, numberRepeats: numberRepeats)) {
                p.name = n
            }
        }
        scheduleSave()
        rebuildIndexDependents()
    }

    /// Return in the Call field: save, select the next mark, keep typing its call.
    private func nextCallNote(after p: CuePoint) {
        save()
        guard let i = points.firstIndex(where: { $0.id == p.id }), i + 1 < points.count else { field = nil; return }
        let n = points[i + 1]
        select(n.id)
        if loaded { engine.seek(to: n.time) }
        Task { @MainActor in field = .call(0) }
    }

    private func startPass() {
        guard !points.isEmpty else { return }
        if engine.transport == .playing { engine.pause() }
        let start = selected.flatMap { id in points.firstIndex(where: { $0.id == id }) } ?? 0
        goPass(start)
    }

    private func goPass(_ i: Int) {
        let i = min(max(0, i), points.count - 1)
        passIndex = i
        let p = points[i]
        passText = p.name
        select(p.id)
        if loaded { engine.seek(to: p.time) }
        passFocus = true
    }

    /// Saves the typed name, then moves by `dir`; past the last mark the pass ends.
    private func passStep(_ dir: Int, saveText: Bool = true) {
        guard let i = passIndex, i < points.count else { endPass(); return }
        let p = points[i]
        if saveText {
            let t = passText.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t != p.name { p.name = t; scheduleSave() }
        }
        let n = i + dir
        if n >= points.count { endPass() } else { goPass(max(0, n)) }
    }

    private func endPass() {
        passIndex = nil; passFocus = false
        save()
    }

    /// Names live on the model objects; nudge SwiftUI to redraw dependents straight away.
    private func rebuildIndexDependents() { points = points }

    private func snapped(_ t: TimeInterval) -> TimeInterval {
        let f = clock.rate.fps
        return max(0, (t * f).rounded() / f)
    }

    /// Moves a mark by whole frames (counted on the frame grid, so repeated taps never drift).
    private func shift(_ p: CuePoint, frames n: Int) {
        let f = clock.rate.fps
        let frame = (p.time * f).rounded() + Double(n)
        p.time = min(max(0, frame / f), track?.duration ?? .infinity)
        save()
    }

    /// Selected marks move together, keeping their spacing, clamped to the track.
    private func nudgeSelection(frames: Int) {
        apply(selectedPoints) { CuePointSelectionMath.shifted($0, by: Double(frames) / clock.rate.fps, duration: $1, fps: clock.rate.fps) }
    }

    private func moveSelectionFirst(to t: TimeInterval) {
        apply(selectedPoints) { CuePointSelectionMath.movingFirst($0, to: t, duration: $1, fps: clock.rate.fps) }
    }

    private func apply(_ ps: [CuePoint], _ f: ([TimeInterval], TimeInterval) -> [TimeInterval]) {
        guard let track, !ps.isEmpty else { return }
        for (p, t) in zip(ps, f(ps.map(\.time), track.duration)) { p.time = t }
        save()
    }

    private func delete(_ p: CuePoint) {
        selection.remove(p.id)
        if selected == p.id { selected = nil }
        context.delete(p)
        save()
    }

    private func deleteSelection() {
        let ps = selectedPoints
        guard !ps.isEmpty else { return }
        for p in ps { context.delete(p) }
        select(nil)
        save()
    }

    /// Cue numbers 1, 2, 3… in time order for one type in this track.
    private func renumber(_ type: CuePointType) {
        let idx = index
        let ps = points.filter { idx.type(of: $0).id == type.id }.sorted { $0.time < $1.time }
        for (p, n) in zip(ps, CuePointNumbering.renumbered(count: ps.count)) { p.cueID = n }
        save()
    }

    private var typeCounts: [UUID: Int] {
        let idx = index
        return points.reduce(into: [:]) { $0[idx.type(of: $1).id, default: 0] += 1 }
    }

    private func nextSameType(_ p: CuePoint) -> CuePoint? {
        let idx = index, id = idx.type(of: p).id
        return points.first(where: { $0.time > p.time && idx.type(of: $0).id == id })
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
        select(p.id)
        guard loaded else { return }
        engine.seek(to: p.time)
    }

    private func stepPoint(_ dir: Int) {
        let now = engine.currentTime
        let target = dir > 0 ? points.first(where: { $0.time > now + 0.05 }) : points.last(where: { $0.time < now - 0.25 })
        if let target { jump(to: target) } else if dir < 0 { engine.seek(to: 0) }
    }

    private func rebuildExports() {
        guard let track, !points.isEmpty else { exports = []; return }
        let rows = CuePointRow.rows(for: points, index: index)
        // Single-table formats mix every type in one list, so number them across the whole track;
        // per-type formats (MA3, Eos, disguise per type) keep each type's own numbering.
        let global = rows.enumerated().map { i, r in var r = r; r.number = i + 1; return r }
        let name = track.title
        let opts = beatGrid.map { $0.disguiseOptions(options) } ?? options
        var out: [ExportFile] = []
        for f in CuePointFormat.allCases {
            let perType: Bool = switch f { case .disguisePerType, .grandMA3Timecode, .grandMA3CueListMacro, .eosASCII, .eosCSV: true; default: false }
            let use = perType ? rows : global
            var urls: [URL] = []
            if f == .disguise, let g = beatGrid, !g.sections.isEmpty {
                // With song sections, Section_Break follows the sections and Beat follows the grid's BPM.
                let text = CuePointExport.disguiseCueTable(trackName: name, rows: use, clock: clock, grid: g, options: opts)
                if let u = try? CuePointExport.write(text, name: CuePointExport.disguiseFileName(trackName: name)) { urls = [u] }
            } else {
                urls = (try? f.write(rows: use, clock: clock, trackName: name, types: store.types,
                                     duration: track.duration, disguise: opts)) ?? []
            }
            guard !urls.isEmpty else { continue }
            out.append(.init(format: f, title: f.confidence == .bestGuess ? "\(f.label) (untested)" : f.label,
                             detail: f.note, urls: urls))
        }
        exports = out
    }

    /// Adds marks from a CSV/TSV, disguise table, Reaper markers, grandMA3 timecode or WAV markers.
    private func importMarks(from url: URL) {
        guard let track else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let found = try CuePointImport.parse(data: data, filename: url.lastPathComponent, clock: clock)
            for m in found where m.time >= 0 && m.time <= track.duration {
                let p = CuePoint(trackID: track.id, time: snapped(m.time), name: m.name.isEmpty ? "Imported" : m.name,
                                 colorHex: m.colorHex)
                p.cueID = m.cueID
                if let tn = m.typeName?.trimmingCharacters(in: .whitespaces), !tn.isEmpty {
                    let t = store.types.first { $0.name.caseInsensitiveCompare(tn) == .orderedSame } ?? store.add(name: tn)
                    p.typeID = t.id == CuePointType.defaultID ? nil : t.id
                }
                context.insert(p)
            }
            save()
            importMessage = found.isEmpty ? "No marks found in \(url.lastPathComponent)." : "Added \(found.count) mark\(found.count == 1 ? "" : "s") from \(url.lastPathComponent)."
        } catch {
            importMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't read \(url.lastPathComponent)."
        }
    }
}

private extension View {
    /// Flat input box used by the inspector's short fields.
    func fieldBox() -> some View {
        padding(.horizontal, 8).frame(height: 32)
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
