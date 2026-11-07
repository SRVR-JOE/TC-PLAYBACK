import SwiftUI

/// Calls review: one row per mark with a call, one column per area language. Type a note in the
/// Note column (Return moves to the next mark); tap a language cell to write that language's
/// call by hand instead of the automatic translation.
struct CueCallsReviewSheet: View {
    let trackTitle: String
    let points: [CuePoint]
    let index: CuePointIndex
    let clock: CuePointClock
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Bindable private var model = CueCallerUIModel.shared
    @State private var showAll = false
    @FocusState private var focus: UUID?
    @State private var editing: EditTarget?
    @State private var editText = ""
    /// Bumps when an override changes so cells re-read it.
    @State private var revision = 0

    struct EditTarget: Identifiable, Equatable { let markID: UUID; let language: String; let note: String; var id: String { "\(markID)|\(language)" } }

    private let markW: CGFloat = 200, noteW: CGFloat = 260, langW: CGFloat = 250

    private var rows: [CuePoint] {
        let sorted = points.sorted { $0.time < $1.time }
        return showAll ? sorted : sorted.filter { !$0.callNote.trimmingCharacters(in: .whitespaces).isEmpty }
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
                    if let e = editing { model.setOverride(editText, markID: e.markID, language: e.language, note: e.note); revision += 1 }
                }
                if let e = editing, model.override(markID: e.markID, language: e.language) != nil {
                    Button("Use automatic translation") {
                        model.setOverride(nil, markID: e.markID, language: e.language, note: e.note); revision += 1
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(editing.map { "Note: \($0.note)" } ?? "")
            }
        }
        .presentationSizing(.page)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            FlatSegmented(options: [(false, "With calls"), (true, "All marks")], selection: $showAll, height: 28)
                .fixedSize()
            Spacer()
            Text("Return moves to the next mark. Tap a translation to write it by hand.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
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
                        ForEach(rows) { p in row(p) }
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
            ForEach(languages, id: \.self) { headerCell(CueCallerUIModel.languageName($0), width: langW) }
        }
        .background(Theme.surface)
        .hairline(.bottom)
    }

    private func headerCell(_ s: String, width: CGFloat) -> some View {
        Text(s).sectionHeaderStyle()
            .frame(width: width - 24, alignment: .leading)
            .padding(.horizontal, 12).frame(height: 34)
    }

    private func row(_ p: CuePoint) -> some View {
        let color = Color(hexString: index.colorHex(of: p)) ?? Theme.standby
        return HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index.number(of: p))  \(p.name)").font(Theme.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(clock.timecode(at: p.time).description).font(Theme.numeric(11, weight: .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: markW - 24, alignment: .leading)
            .padding(12)

            TextField("No call", text: Binding(get: { p.callNote }, set: { p.callNote = $0 }), axis: .vertical)
                .font(Theme.label)
                .foregroundStyle(Theme.textPrimary)
                .focused($focus, equals: p.id)
                .submitLabel(.next)
                .onSubmit { advance(from: p) }
                .lineLimit(1...3)
                .frame(width: noteW - 24, alignment: .leading)
                .padding(12)
                .background(focus == p.id ? Theme.surfaceRaised : .clear)

            ForEach(languages, id: \.self) { lang in
                CueCallTranslationCell(markID: p.id, note: p.callNote, language: lang, revision: revision) {
                    let current = model.override(markID: p.id, language: lang)
                    editText = current ?? ""
                    editing = EditTarget(markID: p.id, language: lang, note: p.callNote)
                }
                .frame(width: langW)
            }
        }
        .background(Theme.surface)
        .hairline(.bottom)
    }

    /// Return in a note: save, then move to the next row's note.
    private func advance(from p: CuePoint) {
        onChange()
        let r = rows
        if let i = r.firstIndex(where: { $0.id == p.id }), i + 1 < r.count {
            focus = r[i + 1].id
        } else {
            focus = nil
        }
    }
}

/// One language's call for one mark: the hand-written override, else the automatic translation.
private struct CueCallTranslationCell: View {
    let markID: UUID
    let note: String
    let language: String
    var revision: Int
    var onEdit: () -> Void
    @State private var automatic: String?
    private var model: CueCallerUIModel { .shared }

    var body: some View {
        let manual = model.override(markID: markID, language: language)
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 3) {
                if let manual {
                    Text(manual).font(Theme.label).foregroundStyle(Theme.textPrimary)
                    Text("Written by hand").font(Theme.caption).foregroundStyle(Theme.accent)
                } else if note.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("–").font(Theme.label).foregroundStyle(Theme.textTertiary)
                } else if let automatic {
                    Text(automatic).font(Theme.label).foregroundStyle(Theme.textPrimary)
                } else {
                    Text("Translated when called").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Write this call by hand")
        .task(id: "\(note)|\(language)|\(revision)") {
            automatic = note.isEmpty ? nil : await model.translation(of: note, to: language)
        }
    }
}
