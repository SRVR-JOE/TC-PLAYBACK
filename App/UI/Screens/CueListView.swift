import SwiftUI
import SwiftData
import TCKit

/// Colour tags offered for cue rows (muted, legible on both appearances).
enum CueColorTag: String, CaseIterable, Identifiable {
    case red = "#D9534F", orange = "#E08A3C", yellow = "#D8B935", green = "#4FA765",
         teal = "#3AA6A0", blue = "#4A86D8", purple = "#8D6BD1", grey = "#8A9098"
    var id: String { rawValue }
    var label: String { String(describing: self).capitalized }
    var color: Color { Color(hexString: rawValue) ?? .gray }
}

/// The cue list for the current playlist. Used as the iPad sidebar and the iPhone "Cues" page.
struct CueListView: View {
    @Environment(\.modelContext) private var context
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var dropTargeted = false

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        Group {
            if let playlist = shell.playlist {
                content(playlist)
            } else {
                Color.clear
            }
        }
        .background(Theme.surface)
        .environment(\.editMode, $editMode)
        .onChange(of: showLock) { _, locked in if locked { editMode = .inactive; selection.removeAll() } }
        .sheet(isPresented: $shell.showRenumber) {
            if let p = shell.playlist {
                RenumberSheet(playlist: p, selected: selection)
            }
        }
    }

    @ViewBuilder
    private func content(_ playlist: Playlist) -> some View {
        let cues = playlist.orderedCues
        VStack(spacing: 0) {
            ListHeader(playlist: playlist, cues: cues, locked: showLock, isEditing: isEditing) {
                withAnimation(.easeOut(duration: 0.2)) {
                    editMode = isEditing ? .inactive : .active
                    selection.removeAll()
                }
            }
            if cues.isEmpty {
                EmptyCueList()
            } else {
                list(playlist, cues: cues)
            }
            if isEditing { editBar(playlist, cues: cues) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !showLock else { return false }
            shell.importAudio(urls, context: context)
            return true
        } isTargeted: { dropTargeted = $0 && !showLock }
    }

    private func list(_ playlist: Playlist, cues: [Cue]) -> some View {
        List(selection: isEditing ? $selection : nil) {
            ForEach(cues) { cue in
                CueRow(cue: cue, isEditing: isEditing)
                    .tag(cue.id)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(rowBackground(cue))
                    .listRowSeparatorTint(Theme.hairline)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if !isEditing { shell.show.play(cue); Haptics.go() } }
                    .onTapGesture { if !isEditing { shell.show.standby(cue); Haptics.tick() } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !showLock {
                            Button(role: .destructive) { delete([cue], from: playlist) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { PlaylistEditor.duplicate(cue: cue, in: playlist, context: context) } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            .tint(Theme.textTertiary)
                        }
                    }
                    .contextMenu { contextMenu(cue, playlist: playlist) }
                    .moveDisabled(showLock)
                    .deleteDisabled(true)
            }
            .onMove { from, to in
                guard !showLock else { return }
                PlaylistEditor.move(in: playlist, from: from, to: to, context: context)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 52)
    }

    private func rowBackground(_ cue: Cue) -> Color {
        if shell.isPlaying(cue) || shell.isStandby(cue) { return Theme.surfaceRaised }
        return Theme.surface
    }

    @ViewBuilder
    private func contextMenu(_ cue: Cue, playlist: Playlist) -> some View {
        Button { shell.show.play(cue); Haptics.go() } label: { Label("Play", systemImage: "play") }
        Button { shell.show.standby(cue) } label: { Label("Standby", systemImage: "arrow.right.to.line") }
        if !showLock {
            Divider()
            Button { shell.inspect(cue) } label: { Label("Edit cue…", systemImage: "slider.horizontal.3") }
            Button { shell.editingNumberCueID = cue.id } label: { Label("Edit number", systemImage: "number") }
            Button { PlaylistEditor.duplicate(cue: cue, in: playlist, context: context) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Menu {
                ForEach(CueColorTag.allCases) { tag in
                    Button {
                        cue.colorHex = tag.rawValue; try? context.save()
                    } label: {
                        Label(tag.label, systemImage: cue.colorHex == tag.rawValue ? "checkmark.circle.fill" : "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(tag.color)
                    }
                }
                Divider()
                Button("No colour") { cue.colorHex = nil; try? context.save() }
            } label: { Label("Colour", systemImage: "paintpalette") }
            Divider()
            Button(role: .destructive) { delete([cue], from: playlist) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func editBar(_ playlist: Playlist, cues: [Cue]) -> some View {
        HStack(spacing: 12) {
            Button(selection.count == cues.count ? "Select none" : "Select all") {
                selection = selection.count == cues.count ? [] : Set(cues.map(\.id))
            }
            Spacer()
            Button("Renumber…") { shell.showRenumber = true }
            Button(role: .destructive) {
                delete(cues.filter { selection.contains($0.id) }, from: playlist)
                selection.removeAll()
            } label: {
                Text(selection.isEmpty ? "Delete" : "Delete \(selection.count)")
            }
            .disabled(selection.isEmpty)
            .foregroundStyle(selection.isEmpty ? Theme.textTertiary : Theme.stop)
        }
        .font(Theme.label)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.surfaceRaised)
        .hairline(.top)
    }

    private func delete(_ cues: [Cue], from playlist: Playlist) {
        guard !showLock, !cues.isEmpty else { return }
        PlaylistEditor.delete(cues: cues, from: playlist, context: context)
    }
}

// MARK: - Header

private struct ListHeader: View {
    var playlist: Playlist
    var cues: [Cue]
    var locked: Bool
    var isEditing: Bool
    var toggleEdit: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(cues.count == 1 ? "1 cue" : "\(cues.count) cues")
            Text("·").foregroundStyle(Theme.textTertiary)
            Text(Fmt.clock(cues.reduce(0) { $0 + $1.displayDuration }))
                .font(Theme.numeric(12, weight: .regular))
            Spacer()
            if locked {
                Label("Show mode", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.standby)
            } else if !cues.isEmpty {
                Button(isEditing ? "Done" : "Edit", action: toggleEdit)
                    .font(.system(.caption, weight: isEditing ? .semibold : .medium))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Theme.surface)
        .hairline(.bottom)
    }
}

// MARK: - Row

struct CueRow: View {
    var cue: Cue
    var isEditing: Bool
    @Environment(\.modelContext) private var context
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false

    private var playing: Bool { shell.isPlaying(cue) }
    private var standby: Bool { shell.isStandby(cue) }
    private var missing: Bool {
        guard cue.kind == .track else { return false }
        guard let t = cue.track else { return true }
        return !FileManager.default.fileExists(atPath: t.fileURL.path)
    }
    private var stateColor: Color {
        if missing { return Theme.stop }
        if playing { return Theme.go }
        if standby { return Theme.standby }
        return .clear
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(stateColor).frame(width: 4)
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(cue.colorHex.flatMap(Color.init(hexString:)) ?? .clear)
                    .frame(width: 3, height: 30)
                CueNumberField(cue: cue, isEditing: isEditing)
                    .frame(width: 46, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(cue.title.isEmpty ? "Untitled" : cue.title)
                            .font(.system(.body, weight: standby || playing ? .semibold : .regular))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.duration(cue.displayDuration))
                            .font(Theme.numeric(13, weight: .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    detailLine
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
        }
        .frame(minHeight: 52)
        .opacity(missing ? 0.85 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityHint(standby ? "Standby. Double-tap to play." : "")
    }

    @ViewBuilder
    private var detailLine: some View {
        HStack(spacing: 6) {
            Image(systemName: cue.kind == .track ? "waveform" : "clock")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14)
            if missing {
                Text("File missing").font(Theme.caption).foregroundStyle(Theme.stop)
            } else if playing {
                Text(Fmt.elapsed(shell.elapsed))
                    .font(Theme.numeric(12, weight: .semibold))
                    .foregroundStyle(Theme.go)
                Text(Fmt.remaining(shell.remaining))
                    .font(Theme.numeric(12, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
            } else if let tc = tcStart {
                Text(tc)
                    .font(Theme.numeric(12, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(cue.kind == .track ? "No timecode" : "Generator")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            if !cue.leftEnabled || !cue.rightEnabled || cue.swapped {
                Text(routingSummary)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            FollowGlyph(mode: cue.follow)
        }
    }

    private var tcStart: String? {
        switch cue.kind {
        case .track:
            guard let t = cue.track, t.ltcChannel != nil, let s = t.ltcStart else { return nil }
            let rate = t.ltcRate.flatMap(FrameRate.init(rawValue:))
            return Fmt.timecode(s, rate: rate) + (rate.map { "  " + $0.operatorLabel } ?? "")
        case .generator:
            let rate = FrameRate(rawValue: cue.genRateRaw)
            return Fmt.timecode(cue.genStart, rate: rate) + (rate.map { "  " + $0.operatorLabel } ?? "")
        }
    }

    private var routingSummary: String {
        var parts: [String] = []
        if cue.swapped { parts.append("Swapped") }
        if !cue.leftEnabled { parts.append("L muted") }
        if !cue.rightEnabled { parts.append("R muted") }
        return parts.joined(separator: " · ")
    }
}

/// Follow-mode glyph used in rows and the transport.
struct FollowGlyph: View {
    var mode: FollowMode
    var body: some View {
        Image(systemName: Self.symbol(mode))
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(mode == .stop ? Theme.textTertiary : Theme.textSecondary)
            .frame(width: 16)
            .accessibilityLabel(mode.label)
    }
    static func symbol(_ mode: FollowMode) -> String {
        switch mode {
        case .stop: "stop"
        case .autoContinue: "arrow.down.to.line"
        case .loop: "repeat"
        }
    }
}

/// Cue number: plain mono text, or an inline field while editing.
private struct CueNumberField: View {
    var cue: Cue
    var isEditing: Bool
    @Environment(\.modelContext) private var context
    @Bindable private var shell = ShellModel.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var inline: Bool { isEditing || shell.editingNumberCueID == cue.id }

    var body: some View {
        if inline {
            TextField("#", text: $draft)
                .font(Theme.numeric(15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceSunken))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Theme.accent : Theme.hairline, lineWidth: 1))
                .onAppear {
                    draft = cue.number
                    if shell.editingNumberCueID == cue.id { focused = true }
                }
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
        } else {
            Text(cue.number)
                .font(Theme.numeric(15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func commit() {
        let v = draft.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty, v != cue.number { cue.number = v; try? context.save() }
        if shell.editingNumberCueID == cue.id { shell.editingNumberCueID = nil }
    }
}

// MARK: - Empty state

private struct EmptyCueList: View {
    @Environment(\.modelContext) private var context
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No cues yet")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Import a show track from Files, or add a timecode generator cue. On iPad you can also drop audio files here.")
                .font(Theme.label.weight(.regular))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { shell.showImporter = true } label: {
                    Label("Import audio", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(OutlineButtonStyle(prominent: true))
                Button { shell.addGeneratorCue(context: context) } label: {
                    Label("Add generator cue", systemImage: "clock")
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .padding(.top, 4)
            .disabled(showLock)
        }
        .padding(24)
        .frame(maxWidth: 420, maxHeight: .infinity, alignment: .center)
        .frame(maxWidth: .infinity)
    }
}
