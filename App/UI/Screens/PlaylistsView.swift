import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreTransferable

/// A playlist exported as a single show file, produced lazily when shared.
struct ShowExport: Transferable {
    let playlist: Playlist
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { item in
            let url = try await MainActor.run { try PlaylistEditor.exportShow(item.playlist) }
            return SentTransferredFile(url)
        }
    }
}

enum ShowFileTypes {
    static var importable: [UTType] {
        var t: [UTType] = [.zip]
        if let show = UTType(filenameExtension: "tcshow") { t.insert(show, at: 0) }
        return t
    }
}

/// Playlists manager: create, rename, duplicate, delete, reorder, switch, export, import.
struct PlaylistsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    @Query(sort: \Playlist.sortIndex) private var playlists: [Playlist]
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @State private var confirmDelete: Playlist?
    @State private var importingShow = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(playlists) { p in
                    row(p)
                        .listRowBackground(p.id == shell.playlist?.id ? Theme.surfaceRaised : Theme.surface)
                        .listRowSeparatorTint(Theme.hairline)
                        .contentShape(Rectangle())
                        .onTapGesture { shell.open(p); dismiss() }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !showLock {
                                Button(role: .destructive) { confirmDelete = p } label: { Label("Delete", systemImage: "trash") }
                                Button { duplicate(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                    .tint(Theme.textTertiary)
                            }
                        }
                        .contextMenu {
                            Button { shell.open(p); dismiss() } label: { Label("Open", systemImage: "arrow.right") }
                            if !showLock {
                                Button { renameText = p.name; renaming = p } label: { Label("Rename…", systemImage: "pencil") }
                                Button { duplicate(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            }
                            ShareLink(item: ShowExport(playlist: p), preview: SharePreview(p.name)) {
                                Label("Export show file…", systemImage: "square.and.arrow.up")
                            }
                            if ExportDrive.shared.isReady {
                                Button {
                                    ExportDrive.shared.save(ExportDriveItem(id: "show", title: p.name) { [try PlaylistEditor.exportShow(p)] })
                                } label: { Label("Save show file to \(ExportDrive.shared.name)", systemImage: "externaldrive") }
                            } else {
                                Button { ExportDrive.shared.requestPicker() } label: {
                                    Label(ExportDrive.shared.hasChoice ? "\(ExportDrive.shared.name) isn’t plugged in – choose drive…" : "Choose USB drive…",
                                          systemImage: "externaldrive.badge.plus")
                                }
                            }
                            if !showLock {
                                Divider()
                                Button(role: .destructive) { confirmDelete = p } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .moveDisabled(showLock)
                }
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button { create() } label: { Label("New playlist", systemImage: "plus") }
                        Button { importingShow = true } label: { Label("Import show file…", systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "plus") }
                    .disabled(showLock)
                }
            }
            .exportDriveSupport()
            .onAppear { ExportDrive.shared.refresh() }
            .fileImporter(isPresented: $importingShow, allowedContentTypes: ShowFileTypes.importable) { result in
                if case .success(let url) = result {
                    Task { await shell.importShow(url, context: context); dismiss() }
                }
            }
            .alert("Rename playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let p = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        p.name = renameText.trimmingCharacters(in: .whitespaces); p.updatedAt = .now
                        try? context.save()
                    }
                    renaming = nil
                }
            }
            .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("Delete playlist", role: .destructive) { if let p = confirmDelete { delete(p) } }
            } message: {
                Text("The cues are removed. Imported audio stays in the library.")
            }
        }
    }

    private func row(_ p: Playlist) -> some View {
        let current = p.id == shell.playlist?.id
        return HStack(spacing: 12) {
            Rectangle().fill(current ? Theme.accent : .clear).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.system(.body, weight: current ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    Text(p.cues.count == 1 ? "1 cue" : "\(p.cues.count) cues")
                    Text("·")
                    Text(Fmt.clock(p.cues.reduce(0) { $0 + $1.displayDuration })).font(Theme.numeric(12, weight: .regular))
                    Text("·")
                    Text(p.updatedAt, format: .dateTime.day().month(.abbreviated).year())
                }
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if current { Text("Open").font(Theme.caption).foregroundStyle(Theme.textTertiary) }
        }
        .padding(.vertical, 6)
    }

    private func create() {
        let p = PlaylistEditor.createPlaylist(named: "Playlist \(playlists.count + 1)", context: context)
        shell.ensureInserted(p, context: context)
        renameText = p.name; renaming = p
    }

    private func duplicate(_ p: Playlist) {
        let copy = PlaylistEditor.duplicate(p, context: context)
        shell.ensureInserted(copy, context: context)
    }

    private func delete(_ p: Playlist) {
        let wasCurrent = p.id == shell.playlist?.id
        PlaylistEditor.delete(p, context: context)
        if wasCurrent, let next = playlists.first(where: { $0.id != p.id }) { shell.open(next) }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        guard !showLock else { return }
        var ordered = playlists
        ordered.move(fromOffsets: from, toOffset: to)
        for (i, p) in ordered.enumerated() where p.sortIndex != i { p.sortIndex = i }
        try? context.save()
    }
}
