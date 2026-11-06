import SwiftUI
import SwiftData

/// QLab-style renumber: all cues or the selection, from a start number by an increment.
/// Numbers already used by cues outside the range are skipped. Reordering never renumbers.
struct RenumberSheet: View {
    var playlist: Playlist
    var selected: Set<UUID>
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable, Identifiable { case all, selected; var id: String { rawValue } }
    @State private var scope: Scope = .all
    @State private var startText = "1"
    @State private var stepText = "1"

    private var start: Double? { Double(startText.replacingOccurrences(of: ",", with: ".")) }
    private var step: Double? {
        guard let v = Double(stepText.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        return v
    }
    private var cues: [Cue] { playlist.orderedCues }
    private var targets: [Cue] { scope == .all ? cues : cues.filter { selected.contains($0.id) } }
    private var preview: [String]? {
        guard let start, let step else { return nil }
        let targetIDs = Set(targets.map(\.id))
        let taken = Set(cues.filter { !targetIDs.contains($0.id) }.map(\.number))
        return CueNumbering.sequence(count: targets.count, start: start, step: step, taken: taken)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    FlatSegmented(options: [(Scope.all, "All cues"),
                                            (Scope.selected, selected.isEmpty ? "Selected" : "Selected (\(selected.count))")],
                                  selection: $scope, height: 30)
                        .disabled(selected.isEmpty)

                    HStack(spacing: 12) {
                        numberField("Start at", text: $startText, valid: start != nil)
                        numberField("Increment", text: $stepText, valid: step != nil)
                    }
                    Text("Numbers already used by other cues are skipped.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
                .hairline(.bottom)

                SectionHeader("Preview").padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                List {
                    let p = preview
                    ForEach(Array(targets.enumerated()), id: \.element.id) { i, cue in
                        HStack(spacing: 12) {
                            Text(cue.number)
                                .font(Theme.numeric(14, weight: .regular))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 52, alignment: .leading)
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                            Text(p.map { i < $0.count ? $0[i] : "–" } ?? "–")
                                .font(Theme.numeric(14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 52, alignment: .leading)
                            Text(cue.title).font(Theme.label.weight(.regular))
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .listRowBackground(Theme.surface)
                        .listRowSeparatorTint(Theme.hairline)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .background(Theme.surface)
            .navigationTitle("Renumber")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Renumber") { apply(); dismiss() }.disabled(preview == nil || targets.isEmpty)
                }
            }
            .onAppear { if !selected.isEmpty { scope = .selected; startText = selectedStart } }
        }
        .presentationDetents([.medium, .large])
    }

    private var selectedStart: String {
        cues.first(where: { selected.contains($0.id) })?.number ?? "1"
    }

    private func numberField(_ title: String, text: Binding<String>, valid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).sectionHeaderStyle()
            TextField(title, text: text)
                .font(Theme.numeric(17, weight: .medium))
                .keyboardType(.decimalPad)
                .padding(.horizontal, 10).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surfaceSunken))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(valid ? Theme.hairline : Theme.stop, lineWidth: 1))
        }
    }

    private func apply() {
        guard let numbers = preview else { return }
        if scope == .all, let start, let step, start.rounded() == start, step.rounded() == step {
            PlaylistEditor.renumber(playlist, start: Int(start), step: Int(step), context: context)
        }
        // Make the result match the preview exactly (skip rules, decimals, selection scope).
        let t = targets
        for (cue, n) in zip(t, numbers) where cue.number != n { cue.number = n }
        try? context.save()
    }
}
