import SwiftUI

// Stacked call editing: the Call field as a list of lines, the camera and shot keys under it,
// and the Cameras sheet. Used by the mark inspector and the Calls review.

/// The Call field as a stack of lines. Return in a line moves to the next mark (as before);
/// Shift-Return or "Add call" stacks another line. Lines can be deleted and dragged to reorder.
struct CueCallStackEditor<F: Hashable>: View {
    @Binding var note: String
    var focus: FocusState<F?>.Binding
    /// The focus value for line `i`.
    var lineFocus: (Int) -> F
    var placeholder = "What to say over comms"
    /// Height of one line's field (the Calls review lines up translations with it).
    var lineHeight: CGFloat = 32
    var onNextMark: () -> Void
    /// The current line changed (the review's shared keys follow it).
    var onCurrentLine: (Int) -> Void = { _ in }

    @State private var current = 0

    var body: some View {
        let lines = CueCallStack.editingLines(note)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines.indices, id: \.self) { i in
                row(i, lines: lines)
            }
            addButton(lines: lines)
        }
        .onChange(of: focus.wrappedValue) { _, f in
            guard let f, let i = lines.indices.first(where: { lineFocus($0) == f }) else { return }
            current = i
            onCurrentLine(i)
        }
    }

    private func row(_ i: Int, lines: [String]) -> some View {
        let stacked = lines.count > 1
        return HStack(spacing: 8) {
            Group {
                if stacked {
                    Text("\(i + 1)").font(Theme.numeric(12, weight: .medium)).foregroundStyle(Theme.textTertiary)
                } else {
                    Image(systemName: lines[i].isEmpty ? "speaker" : "speaker.wave.1")
                        .font(.system(size: 13, weight: .regular)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 16)
            TextField(i == 0 ? placeholder : "Next call", text: lineBinding(i))
                .font(Theme.label).foregroundStyle(Theme.textPrimary)
                .focused(focus, equals: lineFocus(i))
                .submitLabel(.next)
                .onSubmit { note = CueCallStack.tidy(note); onNextMark() }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    addLine(after: i)
                    return .handled
                }
                .accessibilityLabel(stacked ? "Call \(i + 1)" : "Call")
                .accessibilityHint("Return saves and moves to the next mark. Shift-Return adds another call.")
            if stacked {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 24, height: lineHeight)
                    .contentShape(Rectangle())
                    .draggable(CueCallLineDrag.payload(i)) {
                        Text(lines[i].isEmpty ? "Call \(i + 1)" : lines[i]).font(Theme.label)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .accessibilityLabel("Reorder")
                    .accessibilityActions {
                        if i > 0 { Button("Move up") { note = CueCallPresetEditing.moveLine(in: note, from: i, to: i - 1) } }
                        if i + 1 < lines.count { Button("Move down") { note = CueCallPresetEditing.moveLine(in: note, from: i, to: i + 1) } }
                    }
                Button { remove(i) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .frame(width: 22, height: lineHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove call \(i + 1)")
            }
        }
        .padding(.leading, 8).padding(.trailing, stacked ? 2 : 8).frame(height: lineHeight)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focus.wrappedValue == lineFocus(i) ? Theme.textTertiary : Theme.hairline, lineWidth: 1))
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap(CueCallLineDrag.index) else { return false }
            note = CueCallPresetEditing.moveLine(in: note, from: from, to: i)
            return true
        }
        .contextMenu {
            if i > 0 { Button { note = CueCallPresetEditing.moveLine(in: note, from: i, to: i - 1) } label: { Label("Move up", systemImage: "arrow.up") } }
            if i + 1 < lines.count { Button { note = CueCallPresetEditing.moveLine(in: note, from: i, to: i + 1) } label: { Label("Move down", systemImage: "arrow.down") } }
            Button(role: .destructive) { remove(i) } label: { Label("Remove call", systemImage: "trash") }
        }
    }

    private func addButton(lines: [String]) -> some View {
        Button { addLine(after: lines.count - 1) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("Add call")
            }
            .font(Theme.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lines.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        .accessibilityHint("Stacks another call on this mark")
    }

    private func lineBinding(_ i: Int) -> Binding<String> {
        Binding(get: {
            let l = CueCallStack.editingLines(note)
            return i < l.count ? l[i] : ""
        }, set: { v in
            var l = CueCallStack.editingLines(note)
            guard i < l.count else { return }
            // A pasted block of lines becomes stacked calls.
            let parts = v.components(separatedBy: .newlines)
            l.replaceSubrange(i...i, with: parts)
            note = CueCallStack.note(l)
        })
    }

    private func addLine(after i: Int) {
        let r = CueCallPresetEditing.addLine(to: note, after: i)
        note = r.note
        current = r.line
        onCurrentLine(r.line)
        Task { @MainActor in focus.wrappedValue = lineFocus(r.line) }
    }

    private func remove(_ i: Int) {
        let wasFocused = focus.wrappedValue == lineFocus(i)
        note = CueCallPresetEditing.removeLine(from: note, at: i)
        let n = CueCallStack.editingLines(note).count
        current = max(0, min(current >= i ? current - 1 : current, n - 1))
        onCurrentLine(current)
        if wasFocused { focus.wrappedValue = lineFocus(current) }
    }
}

/// A call line being dragged to a new position within one mark's stack (carried as text).
enum CueCallLineDrag {
    private static let prefix = "tcplayback.call-line:"
    static func payload(_ i: Int) -> String { prefix + String(i) }
    static func index(_ s: String) -> Int? { s.hasPrefix(prefix) ? Int(s.dropFirst(prefix.count)) : nil }
}

// MARK: - Preset keys

/// Camera keys (Cam 1–12, renamed ones by name) and shot keys. Tapping a camera starts a call
/// line or, on a full line, stacks a new one; a shot is added to the current line.
struct CueCallPresetStrip: View {
    /// The current line's text (lights the camera it starts with).
    var line: String
    var compact: Bool
    var onCamera: (String) -> Void
    var onSwapCamera: (String) -> Void
    var onShot: (String) -> Void
    var onEdit: () -> Void
    private var store: CueCameraPresetStore { .shared }

    var body: some View {
        let p = store.presets
        let active = CueCallPresetEditing.activeCamera(line: line, presets: p)
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(0..<CueCameraPresets.count, id: \.self) { i in
                            cameraKey(i, p, on: active == i).frame(width: 62)
                        }
                    }
                }
            } else {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(0..<2, id: \.self) { r in
                        GridRow {
                            ForEach(0..<6, id: \.self) { c in cameraKey(r * 6 + c, p, on: active == r * 6 + c) }
                        }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(p.shots, id: \.self) { s in
                        Button { onShot(s) } label: {
                            Text(s).font(.system(size: 13, weight: .regular)).lineLimit(1).padding(.horizontal, 10)
                        }
                        .buttonStyle(CuePresetKeyStyle())
                        .accessibilityLabel("Add \(s)")
                    }
                    Button(action: onEdit) {
                        Text("Cameras…").font(.system(size: 13, weight: .regular)).lineLimit(1).padding(.horizontal, 10)
                    }
                    .buttonStyle(CuePresetKeyStyle(secondary: true))
                }
            }
        }
    }

    private func cameraKey(_ i: Int, _ p: CueCameraPresets, on: Bool) -> some View {
        let name = p.name(i)
        return Button { onCamera(name) } label: {
            Text(p.keyLabel(i))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.6).allowsTightening(true)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(CuePresetKeyStyle(isOn: on))
        .contextMenu {
            Button { onSwapCamera(name) } label: { Label("Use on this line", systemImage: "arrow.left.arrow.right") }
            Button(action: onEdit) { Label("Rename cameras…", systemImage: "pencil") }
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction(named: "Use on this line") { onSwapCamera(name) }
    }
}

/// A flat panel key: square corners, hairline edge, lit (solid) when it's the line's camera.
struct CuePresetKeyStyle: ButtonStyle {
    var isOn = false
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Color.white : (secondary ? Theme.textSecondary : Theme.textPrimary))
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(isOn ? Theme.accent : (configuration.isPressed ? Theme.hairline : Theme.surfaceRaised)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? Color.clear : Theme.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Inspector block

/// The current line's camera and its mission from the camera brief, one line, so the director
/// remembers what that camera is for.
@MainActor @ViewBuilder func missionHint(line: String) -> some View {
    let store = CueCameraPresetStore.shared
    if let i = CueCallPresetEditing.activeCamera(line: line, presets: store.presets), let cam = store.briefCamera(i),
       case let m = cam.mission.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces), !m.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(cam.callName).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Text(m).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The inspector's Call block: the stack editor and the preset keys acting on its current line.
struct CueCallStackField<F: Hashable>: View {
    @Binding var note: String
    var focus: FocusState<F?>.Binding
    var lineFocus: (Int) -> F
    var compact: Bool
    var onNextMark: () -> Void
    var onEditCameras: () -> Void
    @State private var current = 0
    private var names: [String] { CueCameraPresetStore.shared.presets.customNames }

    var body: some View {
        let lines = CueCallStack.editingLines(note)
        VStack(alignment: .leading, spacing: 8) {
            CueCallStackEditor(note: $note, focus: focus, lineFocus: lineFocus, onNextMark: onNextMark,
                               onCurrentLine: { current = $0 })
            CueCallPresetStrip(
                line: lines[min(current, lines.count - 1)], compact: compact,
                onCamera: { name in
                    let r = CueCallPresetEditing.applyCamera(name, to: note, line: current, names: names)
                    let moved = r.line != current
                    note = r.note; current = r.line
                    // Keep typing on the new line if the keyboard was up; never pop it up otherwise.
                    if moved, focus.wrappedValue != nil { focus.wrappedValue = lineFocus(r.line) }
                },
                onSwapCamera: { name in note = CueCallPresetEditing.applySwap(name, to: note, line: current, names: names) },
                onShot: { s in note = CueCallPresetEditing.applyShot(s, to: note, line: current) },
                onEdit: onEditCameras)
            missionHint(line: lines[min(current, lines.count - 1)])
        }
        .onChange(of: lines.count) { _, n in if current >= n { current = max(0, n - 1) } }
    }
}

