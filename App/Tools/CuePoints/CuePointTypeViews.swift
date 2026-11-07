import SwiftUI
import SwiftData
import GameController

/// Modifier keys on a hardware keyboard (iPad / Mac keyboard in the simulator), read at gesture time.
enum HardwareKeys {
    /// A hardware keyboard is attached (iPad keyboard, or the Mac's in the simulator).
    static var connected: Bool { GCKeyboard.coalesced != nil }
    static var shift: Bool {
        guard let k = GCKeyboard.coalesced?.keyboardInput else { return false }
        return (k.button(forKeyCode: .leftShift)?.isPressed ?? false) || (k.button(forKeyCode: .rightShift)?.isPressed ?? false)
    }
}

/// One large pad per visible cue type; touching one drops a mark of that type at the playhead.
/// Fires on touch-down so live marks land on the beat; each drop ticks the pad briefly.
struct CueTypePads: View {
    var types: [CuePointType]
    var active: UUID
    var enabled: Bool
    /// The type that just got a mark (ticks its pad).
    var ticked: UUID? = nil
    var height: CGFloat = 50
    var showKeys = true
    var onTap: (CuePointType) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { pads(fixed: false) }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { pads(fixed: true) } }
        }
    }

    @ViewBuilder private func pads(fixed: Bool) -> some View {
        ForEach(Array(types.enumerated()), id: \.element.id) { i, t in
            pad(t, key: showKeys && i < 10 ? String((i + 1) % 10) : nil, fixed: fixed)
                .overlay(TouchDownArea(label: "Mark \(t.name)", enabled: enabled) { onTap(t) })
                .accessibilityHint(i < 10 ? "Keyboard: \((i + 1) % 10)" : "")
        }
    }

    private func pad(_ t: CuePointType, key: String?, fixed: Bool) -> some View {
        let colour = Color(hexString: t.colorHex) ?? Theme.standby
        let tick = ticked == t.id
        return HStack(spacing: 0) {
            Rectangle().fill(colour).frame(width: tick ? 10 : 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let key { Text("Key \(key)").font(Theme.caption).foregroundStyle(Theme.textTertiary) }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
            if t.id == active {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).padding(.trailing, 8)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: fixed ? 120 : 0, maxWidth: fixed ? nil : .infinity)
        .frame(height: height)
        .background(tick ? colour.opacity(0.25) : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(tick ? colour : Theme.hairline, lineWidth: 1))
    }
}

/// Non-blocking name field shown right after a drop (when "Name marks as you drop them" is on).
/// Playback and the pads keep going; a new drop moves the field to the newest mark.
/// Return saves, Escape closes, a preset names the mark and closes.
struct CueDropNameField: View {
    @Binding var text: String
    var placeholder: String
    var colorHex: String
    var focus: FocusState<Bool>.Binding
    var presets: [String]
    var onCommit: () -> Void
    var onDismiss: () -> Void
    var onPreset: (String) -> Void
    var onEditPresets: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Rectangle().fill(Color(hexString: colorHex) ?? Theme.standby).frame(width: 5, height: 30)
                TextField(placeholder, text: $text)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .focused(focus)
                    .submitLabel(.done)
                    .onSubmit(onCommit)
                    .onKeyPress(.escape) { onDismiss(); return .handled }
                Button("Save", action: onCommit).font(Theme.label.weight(.semibold))
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .foregroundStyle(Theme.textSecondary).accessibilityLabel("Close without naming")
            }
            CueLabelPresetBar(labels: presets, onPick: onPreset, onEdit: onEditPresets)
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Add, rename, recolour, reorder, hide, lock and delete cue types; renumber a type's cues.
struct CuePointTypesSheet: View {
    var store: CuePointTypeStore
    var counts: [UUID: Int]
    var onRenumber: (CuePointType) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: CuePointType?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.types) { t in row(t) }
                        .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    Button { store.add() } label: { Label("Add type", systemImage: "plus") }
                } footer: {
                    Text("Each type is a lane on the timeline and its own group when exporting. Keys 1 to 0 drop a mark of the matching visible type.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Cue types")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog(pendingDelete.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete type", role: .destructive) {
                    if let t = pendingDelete { store.delete(t.id, context: context) }
                    pendingDelete = nil
                }
            } message: {
                Text("Its marks move to \(store.type(for: nil).name).")
            }
        }
    }

    private func row(_ t: CuePointType) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(CuePointColor.allCases) { c in
                    Button { store.recolour(t.id, to: c.rawValue) } label: {
                        if c.rawValue == t.colorHex { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                    }
                }
            } label: {
                RoundedRectangle(cornerRadius: 3).fill(Color(hexString: t.colorHex) ?? Theme.standby).frame(width: 22, height: 22)
            }
            .accessibilityLabel("\(t.name) colour")
            TextField("Name", text: Binding(get: { t.name }, set: { store.rename(t.id, to: $0) }))
                .font(Theme.label).foregroundStyle(Theme.textPrimary)
            Text("\(counts[t.id] ?? 0)").font(Theme.numeric(12)).foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("\(counts[t.id] ?? 0) marks in this track")
            Menu {
                Button { onRenumber(t) } label: { Label("Renumber 1, 2, 3…", systemImage: "list.number") }
                    .disabled((counts[t.id] ?? 0) == 0)
                Toggle("Hide lane", isOn: Binding(get: { t.hidden }, set: { store.setHidden(t.id, $0) }))
                Toggle("Lock lane", isOn: Binding(get: { t.locked }, set: { store.setLocked(t.id, $0) }))
                if t.id != CuePointType.defaultID {
                    Button(role: .destructive) { pendingDelete = t } label: { Label("Delete type", systemImage: "trash") }
                }
            } label: {
                HStack(spacing: 6) {
                    if t.hidden { Image(systemName: "eye.slash").accessibilityLabel("Hidden") }
                    if t.locked { Image(systemName: "lock").accessibilityLabel("Locked") }
                    Image(systemName: "ellipsis.circle")
                }
                .font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityLabel("\(t.name) options")
        }
        .listRowBackground(Theme.surface)
    }
}
