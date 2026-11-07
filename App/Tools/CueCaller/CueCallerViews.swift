import SwiftUI
import Translation

// Cue caller UI: the engage control on the playback screen, its quick panel, the settings
// form (sheet + Settings), the area editor and the Cue points toolbar menu. Everything reads and
// writes `CueCallerUIModel.shared` (the seam to the engine and language layer).

// MARK: - Shared bits

/// Small square indicator lamp: grey off, green following, amber waiting, red lost.
struct CueCallerLamp: View {
    var status: CueCallerStatus
    var size: CGFloat = 8
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Self.color(status))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
    static func color(_ s: CueCallerStatus) -> Color {
        switch s {
        case .off: Theme.lockOff
        case .following: Theme.go
        case .waiting: Theme.standby
        case .lost: Theme.stop
        }
    }
}

enum CueCallerText {
    /// "Outputs 1–2", "Output 3", "Outputs 1, 4, 5", "No outputs".
    static func channels(_ chs: [Int]) -> String {
        let s = Array(Set(chs)).sorted()
        guard let first = s.first, let last = s.last else { return "No outputs" }
        if s.count == 1 { return "Output \(first + 1)" }
        if last - first == s.count - 1 { return "Outputs \(first + 1)–\(last + 1)" }
        return "Outputs " + s.map { String($0 + 1) }.joined(separator: ", ")
    }

    /// "All lanes", "Lights", "Lights, Video", "Lights, Video +1".
    static func lanes(_ ids: [UUID], types: [CuePointType]) -> String {
        if ids.isEmpty { return "All lanes" }
        let names = types.filter { ids.contains($0.id) }.map(\.name)
        if names.isEmpty { return "All lanes" }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }

    static func areaSummary(_ a: CueCallArea, types: [CuePointType]) -> String {
        "\(CueCallerUIModel.languageName(a.language)) · \(channels(a.outputChannels)) · \(lanes(a.laneIDs, types: types))"
    }

    static func seconds(_ s: Double) -> String { String(format: "%.1f s", max(0, s)) }
}

private func formHeader(_ s: String) -> some View {
    Text(s).font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary).textCase(nil)
}

// MARK: - Playback screen control

/// Engage key + state for the marks strip under the big clock. The key turns the caller on and
/// off; the readout opens the quick panel (per-area toggles, settings).
struct CueCallerStripControl: View {
    var compact = false
    /// The strip's own next-mark-with-a-call, used until the engine reports `nextCall`.
    var fallbackNext: CueCallerUpcoming?
    /// Countdown only makes sense while the track is playing.
    var running = false
    @Bindable private var model = CueCallerUIModel.shared
    @State private var showPanel = false
    @State private var showSettings = false

    var body: some View {
        let status = model.status
        let next = model.nextCall ?? fallbackNext
        HStack(spacing: 8) {
            Button {
                model.isEngaged.toggle()
                Haptics.tick()
            } label: {
                Image(systemName: model.isEngaged ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(LatchButtonStyle(isOn: model.isEngaged, onColor: Theme.go))
            .frame(width: 40, height: 34)
            .accessibilityLabel("Cue caller")
            .accessibilityValue(model.isEngaged ? "On" : "Off")
            .accessibilityHint("Turns spoken calls on or off")

            Button { showPanel = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        CueCallerLamp(status: status)
                        Text(status == .off ? "Cue caller off" : status.label)
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(status == .lost ? Theme.stop : Theme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    detail(status: status, next: next)
                }
                .frame(width: compact ? 128 : 210, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cue caller, \(status.label)")
            .accessibilityHint("Shows areas and settings")
            .popover(isPresented: $showPanel) {
                CueCallerQuickPanel {
                    showPanel = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        showSettings = true
                    }
                }
                .presentationCompactAdaptation(.popover)
            }
        }
        .sheet(isPresented: $showSettings) { CueCallerSettingsSheet() }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-cueCallerPopover") { showPanel = true }
        }
        #endif
    }

    @ViewBuilder private func detail(status: CueCallerStatus, next: CueCallerUpcoming?) -> some View {
        if status == .off {
            Text(model.settings.areas.filter(\.enabled).isEmpty ? "No areas on"
                 : "\(model.settings.areas.filter(\.enabled).count) of \(model.settings.areas.count) areas ready")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        } else if let next {
            HStack(spacing: 6) {
                if running {
                    Text(next.kind == .standby ? "Standby" : "Go")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(next.kind == .go && next.secondsToGo < 3 ? Theme.standby : Theme.textSecondary)
                    Text(CueCallerText.seconds(next.secondsToGo))
                        .font(Theme.numeric(12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                } else {
                    Text("Next").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                }
                Text(next.text).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        } else {
            Text("No calls ahead").font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }
}

/// Popover from the strip: master switch, one switch per area, and the way into settings.
struct CueCallerQuickPanel: View {
    var onOpenSettings: () -> Void
    @Bindable private var model = CueCallerUIModel.shared
    private let types = CuePointTypeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cue caller").font(.headline).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        CueCallerLamp(status: model.status)
                        Text(model.status.label).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Toggle("Cue caller", isOn: $model.isEngaged).labelsHidden().tint(Theme.go)
            }
            .padding(14)
            if let last = model.lastCall {
                Text("Last: \(last.areaName) · \(last.text)")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
            SectionHeader("Areas").padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            if model.settings.areas.isEmpty {
                Text("No areas yet").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            ForEach(model.settings.areas) { a in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(Theme.label).foregroundStyle(a.enabled ? Theme.textPrimary : Theme.textSecondary)
                        Text("\(CueCallerUIModel.languageName(a.language)) · \(CueCallerText.channels(a.outputChannels))")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer()
                    Toggle(a.name, isOn: Binding(get: { model.area(a.id)?.enabled ?? false },
                                                 set: { model.setAreaEnabled(a.id, $0) }))
                        .labelsHidden().tint(Theme.go)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth).padding(.top, 8)
            Button(action: onOpenSettings) {
                HStack {
                    Text("Cue caller settings").font(Theme.label)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 330)
        .background(Theme.surface)
    }
}

// MARK: - Settings

/// The whole cue caller setup. Used inside the Settings screen and in its own sheet.
struct CueCallerSettingsForm: View {
    @Bindable private var model = CueCallerUIModel.shared
    @State private var editing: UUID?
    private let types = CuePointTypeStore.shared

    var body: some View {
        ScrollViewReader { proxy in
            form
                #if DEBUG
                .task {
                    guard CueCallerPreviewHost.mode == "keys" else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    proxy.scrollTo("voices", anchor: .top)
                }
                #endif
        }
    }

    private var form: some View {
        Form {
            Section {
                Toggle("Cue caller", isOn: $model.isEngaged).tint(Theme.go)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        CueCallerLamp(status: model.status)
                        Text(model.status.label).foregroundStyle(Theme.textSecondary)
                    }
                }
            } header: { formHeader("Cue caller") } footer: {
                Text("Speaks each mark’s call over comms, in each area’s language. Nothing is spoken until this is on.")
            }
            .listRowBackground(Theme.surface)

            Section {
                Picker("Follow", selection: $model.settings.source) {
                    ForEach(CueCallerSource.allCases) { Text($0.label).tag($0) }
                }
                Stepper(value: $model.settings.standbyLead, in: 1...20, step: 1) {
                    HStack {
                        Text("Standby lead")
                        Spacer()
                        Text(String(format: "%.0f s", model.settings.standbyLead))
                            .font(Theme.numeric(14, weight: .regular)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Toggle("Say standby before each call", isOn: $model.settings.sayStandby)
                Toggle("Only call marks with a note", isOn: $model.settings.onlyMarksWithNotes)
                Toggle("Say the mark name with the call", isOn: $model.settings.includeMarkName)
                Toggle("Keep calls off the programme outputs", isOn: $model.settings.dedicatedCallChannels)
            } header: { formHeader("Calling") } footer: {
                Text("The go lands on the mark. With LTC input, another machine is the master and this app only listens.")
            }
            .listRowBackground(Theme.surface)

            Section {
                ForEach(model.settings.areas) { a in
                    areaRow(a)
                }
                .onDelete { model.removeAreas(at: $0) }
                .onMove { model.moveAreas(from: $0, to: $1) }
                Button {
                    let a = model.addArea()
                    editing = a.id
                } label: { Label("Add area", systemImage: "plus") }
            } header: { formHeader("Areas") } footer: {
                Text("An area is one comms ring: its own language, voice and outputs. Swipe to remove.")
            }
            .listRowBackground(Theme.surface)

            CueCallVoicesSection()
                .id("voices")

            Section {
                Picker("Notes are written in", selection: $model.noteLanguage) {
                    ForEach(CueCallerUIModel.commonLanguages) { Text($0.name).tag($0.id) }
                }
                ForEach(model.areaLanguages.filter { !CueCallerUIModel.sameLanguage($0, model.noteLanguage) }, id: \.self) { lang in
                    CueCallTranslationRow(language: lang)
                }
            } header: { formHeader("Translation") } footer: {
                Text("Translations are made on this device. Download a language once and it works with no network.")
            }
            .listRowBackground(Theme.surface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .tint(Theme.accent)
        .navigationTitle("Cue caller")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editing) { id in CueCallAreaEditor(areaID: id) }
    }

    private func areaRow(_ a: CueCallArea) -> some View {
        HStack(spacing: 12) {
            Button { editing = a.id } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.name).font(.body).foregroundStyle(a.enabled ? Theme.textPrimary : Theme.textSecondary)
                        Text(CueCallerText.areaSummary(a, types: types.types))
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(a.name), \(CueCallerText.areaSummary(a, types: types.types)). Edit")
            Button("Test") { model.test(area: a) }
                .buttonStyle(OutlineButtonStyle())
                .accessibilityLabel("Test \(a.name)")
            Toggle(a.name, isOn: Binding(get: { model.area(a.id)?.enabled ?? false }, set: { model.setAreaEnabled(a.id, $0) }))
                .labelsHidden().tint(Theme.go)
        }
        .padding(.vertical, 2)
    }
}

/// The settings form in its own sheet (from the playback screen and Cue points).
struct CueCallerSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CueCallerSettingsForm()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationSizing(.page)
    }
}

/// Translation readiness for one language, with a download when it's needed.
struct CueCallTranslationRow: View {
    let language: String
    var showsName = true
    @Bindable private var model = CueCallerUIModel.shared
    @State private var status: CueCallTranslationStatus = .checking
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            if status == .unsupported {
                Text("Apple can’t translate \(CueCallerUIModel.languageName(model.noteLanguage)) into \(CueCallerUIModel.languageName(language)) on this device. Type these calls by hand in the Calls review.")
                    .font(Theme.caption).foregroundStyle(Theme.standby)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            if showsName {
                Text(CueCallerUIModel.languageName(language)).foregroundStyle(Theme.textPrimary)
            } else {
                Text("Translation").foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            Text(status.label)
                .font(Theme.caption)
                .foregroundStyle(status == .ready || status == .sameLanguage ? Theme.textSecondary
                                 : status == .downloadNeeded ? Theme.standby : Theme.textTertiary)
            if status == .downloadNeeded {
                Button("Download") {
                    config = TranslationSession.Configuration(source: Locale.Language(identifier: model.noteLanguage),
                                                              target: Locale.Language(identifier: language))
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
        .task(id: language + "|" + model.noteLanguage) { status = await model.translationStatus(for: language) }
        .translationTask(config) { session in
            try? await session.prepareTranslation()
            await MainActor.run {
                config = nil
            }
            let s = await model.translationStatus(for: language)
            await MainActor.run { status = s }
        }
    }
}

// MARK: - Area editor

struct CueCallAreaEditor: View {
    let areaID: UUID
    @Environment(\.dismiss) private var dismiss
    @Bindable private var model = CueCallerUIModel.shared
    private let types = CuePointTypeStore.shared
    @State private var channels: [CueCallOutputChannel] = []
    @State private var confirmRemove = false
    @Bindable private var voiceModel = CueCallVoicesModel.shared

    /// The account's ElevenLabs voices as area voice ids, plus the area's own if the list
    /// hasn't loaded (offline), so the picker always shows what's chosen.
    private func elevenChoices(_ a: CueCallArea) -> [(id: String, name: String)] {
        var out = voiceModel.accountVoices.map { (id: ElevenLabsVoiceID.tag($0.voiceID), name: $0.name) }
        if let cur = ElevenLabsVoiceID.parse(a.voiceID), !out.contains(where: { $0.id == a.voiceID }) {
            out.insert((id: ElevenLabsVoiceID.tag(cur), name: voiceModel.voiceName(cur)), at: 0)
        }
        return out
    }

    private var area: Binding<CueCallArea> {
        Binding(get: { model.area(areaID) ?? CueCallArea(name: "", language: model.noteLanguage) },
                set: { new in model.updateArea(areaID) { $0 = new } })
    }

    var body: some View {
        let a = area.wrappedValue
        let voices = model.voices(for: a.language)
        Form {
            Section {
                TextField("Name", text: area.name)
                Toggle("Calls on in this area", isOn: area.enabled).tint(Theme.go)
            } header: { formHeader("Area") }
            .listRowBackground(Theme.surface)

            Section {
                Picker("Language", selection: area.language) {
                    Section {
                        ForEach(CueCallerUIModel.commonLanguages) { Text($0.name).tag($0.id) }
                    }
                    Section("More languages") {
                        ForEach(CueCallerUIModel.otherLanguages) { Text($0.name).tag($0.id) }
                    }
                }
                CueCallTranslationRow(language: a.language, showsName: false)
                Picker("Voice", selection: area.voiceID) {
                    Text("Best available on this iPad").tag(String?.none)
                    if !elevenChoices(a).isEmpty {
                        Section("ElevenLabs") {
                            ForEach(elevenChoices(a), id: \.id) { v in Text(v.name).tag(Optional(v.id)) }
                        }
                    }
                    Section("On this iPad") {
                        ForEach(voices) { v in
                            Text("\(v.name) · \(v.quality)").tag(Optional(v.id))
                        }
                    }
                }
                if voiceModel.hasKey {
                    NavigationLink {
                        ElevenLabsVoiceBrowser(language: a.language) { id in area.wrappedValue.voiceID = id }
                    } label: {
                        Text("Find voices for \(CueCallerUIModel.languageName(a.language))")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Speaking rate")
                        Spacer()
                        Text(String(format: "%.2f×", a.rate / 0.5))
                            .font(Theme.numeric(14, weight: .regular)).foregroundStyle(Theme.textSecondary)
                    }
                    HStack(spacing: 10) {
                        Text("Slower").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        Slider(value: Binding(get: { Double(a.rate) }, set: { area.wrappedValue.rate = Float($0) }), in: 0.3...0.65)
                            .tint(Theme.textSecondary)
                            .accessibilityLabel("Speaking rate")
                        Text("Faster").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    Text(voices.isEmpty && !ElevenLabsVoiceID.isEleven(a.voiceID) ? "No voice installed for this language" : "Hear a test call on this area’s outputs")
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Test") { model.test(area: a) }.buttonStyle(OutlineButtonStyle(prominent: true))
                }
            } header: { formHeader("Language and voice") } footer: {
                if ElevenLabsVoiceID.isEleven(a.voiceID) {
                    Text("ElevenLabs voices speak every language on this list. If a call can’t be made during the show, the best voice on this iPad says it instead.")
                } else if !voiceModel.hasKey {
                    Text("For more natural voices, add an ElevenLabs key in Cue caller settings.")
                }
            }
            .listRowBackground(Theme.surface)
            .onChange(of: a.language) { _, _ in
                // ElevenLabs voices are multilingual; device voices belong to one language.
                if !ElevenLabsVoiceID.isEleven(area.wrappedValue.voiceID) { area.wrappedValue.voiceID = nil }
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
                    ForEach(channels) { ch in
                        let on = a.outputChannels.contains(ch.id)
                        let absent = ch.id >= model.interfaceOutputCount
                        Button {
                            var s = Set(a.outputChannels)
                            if on { s.remove(ch.id) } else { s.insert(ch.id) }
                            area.wrappedValue.outputChannels = s.sorted()
                            Haptics.tick()
                        } label: {
                            Text(ch.name).font(Theme.numeric(13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .buttonStyle(LatchButtonStyle(isOn: on, onColor: absent ? Theme.standby : Theme.accent))
                        .frame(height: 34)
                        .accessibilityLabel("Output \(ch.name)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Level")
                        Spacer()
                        Text(String(format: "%+.1f dB", a.gainDB))
                            .font(Theme.numeric(14, weight: .regular)).foregroundStyle(Theme.textSecondary)
                    }
                    FaderSlider(value: area.gainDB, range: -24...12, unity: 0)
                }
            } header: { formHeader("Outputs") } footer: {
                let missing = model.missingOutputs(a)
                if missing.isEmpty {
                    Text("Pick the interface outputs wired into this comms ring. \(CueCallerText.channels(a.outputChannels)).")
                } else {
                    Text("\(CueCallerText.channels(missing)) \(missing.count == 1 ? "isn’t" : "aren’t") on the connected interface (\(model.interfaceOutputCount) outputs). Calls on \(missing.count == 1 ? "it" : "them") won’t be heard until it’s connected.")
                        .foregroundStyle(Theme.standby)
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                laneRow(title: "All lanes", colorHex: nil, on: a.laneIDs.isEmpty) { area.wrappedValue.laneIDs = [] }
                ForEach(types.types) { t in
                    laneRow(title: t.name, colorHex: t.colorHex, on: a.laneIDs.contains(t.id)) {
                        var s = Set(a.laneIDs)
                        if s.contains(t.id) { s.remove(t.id) } else { s.insert(t.id) }
                        area.wrappedValue.laneIDs = types.types.map(\.id).filter { s.contains($0) }
                    }
                }
            } header: { formHeader("Lanes this area calls") }
            .listRowBackground(Theme.surface)

            Section {
                Button("Remove area", role: .destructive) { confirmRemove = true }
            }
            .listRowBackground(Theme.surface)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .tint(Theme.accent)
        .navigationTitle(a.name.isEmpty ? "Area" : a.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            channels = model.outputChannels(including: a.outputChannels)
            #if DEBUG
            if CueCallerPreviewHost.mode == nil { voiceModel.loadAccountVoices() }
            #else
            voiceModel.loadAccountVoices()
            #endif
        }
        .confirmationDialog("Remove \(a.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove area", role: .destructive) { model.removeArea(areaID); dismiss() }
        }
    }

    private func laneRow(title: String, colorHex: String?, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(colorHex.flatMap { Color(hexString: $0) } ?? Theme.textTertiary)
                    .frame(width: 10, height: 10)
                    .opacity(colorHex == nil ? 0 : 1)
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Cue points toolbar

/// Cue points toolbar: state lamp + "Calls"; menu with the master switch, the Calls review
/// and settings.
struct CueCallerToolbarMenu: View {
    var compact = false
    var onShowCalls: () -> Void
    var onShowSettings: () -> Void
    @Bindable private var model = CueCallerUIModel.shared

    var body: some View {
        Menu {
            Toggle("Cue caller", isOn: $model.isEngaged)
            Button { onShowCalls() } label: { Label("Calls…", systemImage: "list.bullet.rectangle") }
            Button { onShowSettings() } label: { Label("Cue caller settings…", systemImage: "slider.horizontal.3") }
        } label: {
            HStack(spacing: 6) {
                CueCallerLamp(status: model.status)
                Image(systemName: model.isEngaged ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 13, weight: .medium))
                if !compact { Text("Calls").font(Theme.label) }
            }
            .foregroundStyle(model.isEngaged ? Theme.textPrimary : Theme.textSecondary)
        }
        .accessibilityLabel("Cue caller, \(model.status.label)")
    }
}

// MARK: - Debug preview

#if DEBUG
/// DEBUG `-cueCallerPreview [area]`: fills in sample areas and opens the settings sheet (or the
/// first area's editor) for screenshots. Never speaks.
struct CueCallerPreviewHost: ViewModifier {
    @State private var show = false
    static var mode: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-cueCallerPreview") else { return nil }
        return i + 1 < a.count && !a[i + 1].hasPrefix("-") ? a[i + 1] : "settings"
    }

    static func seedSampleAreas() {
        let m = CueCallerUIModel.shared
        let types = CuePointTypeStore.shared.types
        let video = types.first { $0.name == "Video" }?.id
        let lights = types.first { $0.name == "Lights" }?.id
        m.noteLanguage = "en-US"
        m.settings.areas = [
            CueCallArea(name: "Cameras", language: "en-US", outputChannels: [2, 3], laneIDs: [CuePointType.defaultID] + [video].compactMap { $0 }),
            CueCallArea(name: "Cámaras", language: "es-MX", outputChannels: [4, 5], laneIDs: [CuePointType.defaultID]),
            CueCallArea(name: "Caméras", language: "fr-FR", outputChannels: [6], enabled: false),
            CueCallArea(name: "Lighting", language: "en-GB", outputChannels: [7], laneIDs: [lights].compactMap { $0 }, gainDB: -3),
            CueCallArea(name: "Kameras Zürich", language: "de-CH", voiceID: ElevenLabsVoiceID.tag("preview-anna"), outputChannels: [8, 9]),
            CueCallArea(name: "Kameror", language: "sv-SE", voiceID: ElevenLabsVoiceID.tag("preview-erik"), outputChannels: [10]),
        ]
        CueCallVoicesModel.shared.seedPreview()
    }

    func body(content: Content) -> some View {
        content
            .task {
                guard let mode = Self.mode, mode != "calls" else { return }
                Self.seedSampleAreas()
                if CueCallerUIModel.shared.settings.enabled == false, ProcessInfo.processInfo.arguments.contains("-cueCallerOn") {
                    CueCallerUIModel.shared.isEngaged = true
                }
                if mode == "settings" || mode == "area" || mode == "swiss" || mode == "voices" || mode == "keys" {
                    try? await Task.sleep(for: .milliseconds(600))
                    show = true
                }
            }
            .sheet(isPresented: $show) { CueCallerPreviewSheet(mode: Self.mode ?? "settings") }
    }
}

private struct CueCallerPreviewSheet: View {
    var mode: String
    @State private var path: [UUID] = []
    @State private var browse = false
    var body: some View {
        NavigationStack(path: $path) {
            CueCallerSettingsForm()
                .navigationDestination(for: UUID.self) { CueCallAreaEditor(areaID: $0) }
                .navigationDestination(isPresented: $browse) { ElevenLabsVoiceBrowser(language: "de-CH") { _ in } }
        }
        .presentationSizing(.page)
        .onAppear {
            let areas = CueCallerUIModel.shared.settings.areas
            switch mode {
            case "area": if let id = areas.dropFirst().first?.id { path = [id] }
            case "swiss": if let id = areas.first(where: { $0.language == "de-CH" })?.id { path = [id] }
            case "voices": browse = true
            default: break
            }
        }
    }
}
#endif
