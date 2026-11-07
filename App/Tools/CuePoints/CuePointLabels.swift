import SwiftUI
import Observation

/// Quick words for naming marks, user-editable, kept in UserDefaults.
@Observable
final class CueLabelPresetStore {
    static let shared = CueLabelPresetStore()
    static let key = "cuePoints.labelPresets"
    static let seed = ["Intro", "Verse", "Pre-chorus", "Chorus", "Bridge", "Drop", "Breakdown", "Outro",
                       "Hit", "Blackout", "Strobe", "Pyro", "Confetti", "Walk-in", "Walk-off"]

    private(set) var labels: [String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        labels = defaults.stringArray(forKey: Self.key) ?? Self.seed
    }

    func add(_ label: String) {
        let t = label.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !labels.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        labels.append(t); persist()
    }
    func remove(atOffsets o: IndexSet) { for i in o.sorted(by: >) { labels.remove(at: i) }; persist() }
    func move(fromOffsets o: IndexSet, toOffset to: Int) {
        let moving = o.map { labels[$0] }
        let before = o.filter { $0 < to }.count
        for i in o.sorted(by: >) { labels.remove(at: i) }
        labels.insert(contentsOf: moving, at: max(0, min(labels.count, to - before)))
        persist()
    }
    func resetToSeed() { labels = Self.seed; persist() }
    private func persist() { defaults.set(labels, forKey: Self.key) }
}

/// "Chorus" twice in one type becomes "Chorus", "Chorus 2", "Chorus 3"…
enum CueLabelNaming {
    /// `label`, or `label N` with N one more than the highest repeat already in `existing`.
    static func numbered(_ label: String, existing: [String]) -> String {
        let base = label.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return base }
        var highest = 0
        for name in existing {
            let n = name.trimmingCharacters(in: .whitespaces)
            if n.caseInsensitiveCompare(base) == .orderedSame { highest = max(highest, 1); continue }
            guard n.count > base.count + 1, n.lowercased().hasPrefix(base.lowercased() + " "),
                  let k = Int(n.dropFirst(base.count + 1)), k > 0 else { continue }
            highest = max(highest, k)
        }
        return highest == 0 ? base : "\(base) \(highest + 1)"
    }

    /// Names for `targets` (in time order) given the other names already in the same type.
    static func apply(_ label: String, count: Int, otherNames: [String], numberRepeats: Bool) -> [String] {
        let base = label.trimmingCharacters(in: .whitespaces)
        guard numberRepeats else { return Array(repeating: base, count: count) }
        var used = otherNames, out: [String] = []
        for _ in 0..<count {
            let n = numbered(base, existing: used)
            out.append(n); used.append(n)
        }
        return out
    }
}

/// A row of plain rectangular label buttons; tap applies, long-press (or the last button) edits.
struct CueLabelPresetBar: View {
    var labels: [String]
    var onPick: (String) -> Void
    var onEdit: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels, id: \.self) { l in
                    Button { onPick(l) } label: { chip(Text(l), primary: true) }
                        .buttonStyle(KeyPressStyle())
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in onEdit() })
                        .accessibilityLabel("Name \(l)")
                        .accessibilityAction(named: "Edit presets", onEdit)
                }
                Button(action: onEdit) { chip(Text("Edit presets…"), primary: false) }
                    .buttonStyle(KeyPressStyle())
            }
        }
    }

    private func chip(_ t: Text, primary: Bool) -> some View {
        t.font(.system(size: 13, weight: .medium))
            .foregroundStyle(primary ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10).frame(minHeight: 32)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Add, remove and reorder label presets.
struct CueLabelPresetsSheet: View {
    var store: CueLabelPresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var newLabel = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New label", text: $newLabel).submitLabel(.done).onSubmit(add)
                        Button("Add", action: add).disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .listRowBackground(Theme.surface)
                }
                Section {
                    ForEach(store.labels, id: \.self) { Text($0).listRowBackground(Theme.surface) }
                        .onDelete { store.remove(atOffsets: $0) }
                        .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Tap a label to name the selected marks. A label used twice in one type is numbered: Chorus, Chorus 2.")
                }
                Section {
                    Button("Restore the original list") { store.resetToSeed() }.listRowBackground(Theme.surface)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Label presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func add() { store.add(newLabel); newLabel = "" }
}

/// "Label marks" pass: one mark at a time, name field focused, presets apply and advance.
struct CueLabelPassBar: View {
    var position: Int
    var count: Int
    var cueLabel: String
    var colorHex: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var presets: [String]
    var onNext: () -> Void
    var onBack: () -> Void
    var onDone: () -> Void
    var onPreset: (String) -> Void
    var onEditPresets: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Label marks").font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary)
                Text("\(position) of \(count)").font(Theme.numeric(12)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Done", action: onDone).font(Theme.label.weight(.semibold))
            }
            HStack(spacing: 8) {
                Rectangle().fill(Color(hexString: colorHex) ?? Theme.standby).frame(width: 5, height: 30)
                Text(cueLabel).font(Theme.numeric(14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                TextField("Name", text: $text)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .focused(focus)
                    .submitLabel(.next)
                    .onSubmit(onNext)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        onBack(); return .handled
                    }
                    .onKeyPress(.escape) { onDone(); return .handled }
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .disabled(position <= 1).accessibilityLabel("Previous mark")
                Button(action: onNext) { Image(systemName: "chevron.right") }
                    .accessibilityLabel(position >= count ? "Save and finish" : "Next mark")
            }
            .padding(.horizontal, 10).frame(minHeight: 46)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
            CueLabelPresetBar(labels: presets, onPick: onPreset, onEdit: onEditPresets)
        }
    }
}
