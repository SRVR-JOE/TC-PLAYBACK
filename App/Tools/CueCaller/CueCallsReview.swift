import SwiftUI

/// Calls review: one row per mark with a call, one column per area language. Type a note in the
/// Note column (Return moves to the next mark, Shift-Return stacks another call, the camera and
/// shot keys at the bottom act on the line being typed); tap a language cell to write that
/// line's call by hand instead of the automatic translation.
struct CueCallsReviewSheet: View {
    let trackTitle: String
    let points: [CuePoint]
    let index: CuePointIndex
    let clock: CuePointClock
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Bindable private var model = CueCallerUIModel.shared
    @State private var showAll = false
    @FocusState private var focus: LineFocus?
    @State private var currentLine = 0
    @State private var showCameras = false
    @State private var editing: EditTarget?
    @State private var editText = ""
    /// Bumps when an override changes so cells re-read it.
    @State private var revision = 0
    /// Languages Apple can't translate into from the note language: the crew types those calls.
    @State private var handOnly: Set<String> = []

    struct LineFocus: Hashable { let mark: UUID; let line: Int }
    struct EditTarget: Identifiable, Equatable {
        let markID: UUID; let language: String; let line: String
        var id: String { "\(markID)|\(language)|\(line)" }
    }

    private let markW: CGFloat = 200, noteW: CGFloat = 300, langW: CGFloat = 250, lineH: CGFloat = 40

    private var rows: [CuePoint] {
        let sorted = points.sorted { $0.time < $1.time }
        return showAll ? sorted : sorted.filter { !$0.callLines.isEmpty || focus?.mark == $0.id }
    }
    private var languages: [String] {
        model.areaLanguages.filter { !CueCallerUIModel.sameLanguage($0, model.noteLanguage) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label("No calls yet", systemImage: "speaker.wave.2")
                    } description: {
                        Text("Type a call in a mark’s Call field, or show all marks here and type them in order.")
                    } actions: {
                        Button("Show all marks") { showAll = true }.buttonStyle(OutlineButtonStyle())
                    }
                } else {
                    table
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { filterBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { presetBar }
            .background(Theme.background)
            .navigationTitle("Calls · \(trackTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onChange(); dismiss() } }
            }
            .alert(editing.map { "\(CueCallerUIModel.languageName($0.language)) call" } ?? "",
                   isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Call", text: $editText)
                Button("Save") {
                    if let e = editing { model.setOverride(editText, markID: e.markID, language: e.language, line: e.line); revision += 1 }
                }
                if let e = editing, model.override(markID: e.markID, language: e.language, line: e.line) != nil {
                    Button("Use automatic translation") {
                        model.setOverride(nil, markID: e.markID, language: e.language, line: e.line); revision += 1
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(editing.map { "Call: \($0.line)" } ?? "")
            }
            .sheet(isPresented: $showCameras) { CamerasSheet() }
        }
        .presentationSizing(.page)
        .task(id: languages.joined() + model.noteLanguage) {
            var out = Set<String>()
            for l in languages where await model.translationStatus(for: l) == .unsupported { out.insert(l) }
            handOnly = out
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            FlatSegmented(options: [(false, "With calls"), (true, "All marks")], selection: $showAll, height: 28)
                .fixedSize()
            Spacer()
            Text("Return moves to the next mark, Shift-Return stacks another call. Tap a translation to write it by hand.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            if CueCallVoicesModel.shared.hasKey {
                CueCallPrepareRow(marks: points.map(CueCallMark.init), title: trackTitle, compact: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.background)
        .hairline(.bottom)
    }

    private var table: some View {
        ScrollView(.horizontal) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        let early = model.earlyStarts(points.map(CueCallMark.init), frame: 1 / clock.rate.fps)
                        ForEach(rows) { p in row(p, early: early[p.id]) }
                    } header: { header }
                }
            }
        }
        .scrollIndicators(.visible)
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerCell("Mark", width: markW)
            headerCell("Note · \(CueCallerUIModel.languageName(model.noteLanguage))", width: noteW)
            ForEach(languages, id: \.self) { lang in
                headerCell(CueCallerUIModel.languageName(lang) + (handOnly.contains(lang) ? " · type by hand" : ""), width: langW)
            }
        }
        .background(Theme.surface)
        .hairline(.bottom)
    }

    private func headerCell(_ s: String, width: CGFloat) -> some View {
        Text(s).sectionHeaderStyle()
            .frame(width: width - 24, alignment: .leading)
            .padding(.horizontal, 12).frame(height: 34)
    }

    private func row(_ p: CuePoint, early: TimeInterval?) -> some View {
        let color = Color(hexString: index.colorHex(of: p)) ?? Theme.standby
        let lines = CueCallStack.editingLines(p.callNote)
        return HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index.number(of: p))  \(p.name)").font(Theme.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(clock.timecode(at: p.time).description).font(Theme.numeric(11, weight: .regular))
                        .foregroundStyle(Theme.textTertiary)
                    if let early {
                        Text("Starts early: \(String(format: "%.1f", early)) s call")
                            .font(Theme.caption).foregroundStyle(Theme.standby)
                            .accessibilityLabel("Starts early, the call is \(String(format: "%.1f", early)) seconds long")
                    }
                }
            }
            .frame(width: markW - 24, alignment: .leading)
            .padding(12)

            CueCallStackEditor(note: Binding(get: { p.callNote }, set: { p.callNote = $0 }), focus: $focus,
                               lineFocus: { LineFocus(mark: p.id, line: $0) }, placeholder: "No call", lineHeight: lineH,
                               onNextMark: { advance(from: p) }, onCurrentLine: { currentLine = $0 })
                .frame(width: noteW - 24, alignment: .leading)
                .padding(12)

            ForEach(languages, id: \.self) { lang in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines.indices, id: \.self) { i in
                        CueCallTranslationCell(markID: p.id, line: lines[i], language: lang, revision: revision) {
                            editText = model.override(markID: p.id, language: lang, line: lines[i]) ?? ""
                            editing = EditTarget(markID: p.id, language: lang, line: lines[i])
                        }
                        .frame(height: lineH)
                    }
                }
                .frame(width: langW - 24, alignment: .leading)
                .padding(12)
            }
        }
        .background(Theme.surface)
        .hairline(.bottom)
    }

    /// Camera and shot keys for the line being typed (hidden until a note line has focus).
    @ViewBuilder private var presetBar: some View {
        if let f = focus, let p = points.first(where: { $0.id == f.mark }) {
            let lines = CueCallStack.editingLines(p.callNote)
            let names = CueCameraPresetStore.shared.presets.customNames
            let line = min(currentLine, lines.count - 1)
            CueCallPresetStrip(
                line: lines[line], compact: true,
                onCamera: { name in
                    let r = CueCallPresetEditing.applyCamera(name, to: p.callNote, line: line, names: names)
                    p.callNote = r.note
                    if r.line != line { currentLine = r.line; focus = LineFocus(mark: p.id, line: r.line) }
                },
                onSwapCamera: { name in p.callNote = CueCallPresetEditing.applySwap(name, to: p.callNote, line: line, names: names) },
                onShot: { s in p.callNote = CueCallPresetEditing.applyShot(s, to: p.callNote, line: line) },
                onEdit: { showCameras = true })
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.background)
            .hairline(.top)
        }
    }

    /// Return in a note: save, then move to the next row's note.
    private func advance(from p: CuePoint) {
        onChange()
        let r = rows
        if let i = r.firstIndex(where: { $0.id == p.id }), i + 1 < r.count {
            focus = LineFocus(mark: r[i + 1].id, line: 0)
        } else {
            focus = nil
        }
    }
}

/// One language's call for one line of a mark: the hand-written correction, else the automatic
/// translation.
private struct CueCallTranslationCell: View {
    let markID: UUID
    let line: String
    let language: String
    var revision: Int
    var onEdit: () -> Void
    @State private var automatic: String?
    private var model: CueCallerUIModel { .shared }

    var body: some View {
        let text = line.trimmingCharacters(in: .whitespaces)
        let manual = text.isEmpty ? nil : model.override(markID: markID, language: language, line: text)
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 1) {
                if let manual {
                    Text(manual).font(Theme.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text("Written by hand").font(Theme.caption).foregroundStyle(Theme.accent)
                } else if text.isEmpty {
                    Text("–").font(Theme.label).foregroundStyle(Theme.textTertiary)
                } else if let automatic {
                    Text(automatic).font(Theme.label).foregroundStyle(Theme.textPrimary).lineLimit(2).minimumScaleFactor(0.85)
                } else {
                    Text("Translated when called").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
        .accessibilityHint("Write this call by hand")
        .task(id: "\(text)|\(language)|\(revision)") {
            automatic = text.isEmpty ? nil : await model.translation(of: text, to: language)
        }
    }
}
