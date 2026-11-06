import SwiftUI
import TCKit

/// Edit one pad: label, colour, start TC (keypad entry), duration, rate, side, level, pre-roll.
struct PadEditSheet: View {
    let bank: PadBank
    let isNew: Bool
    var onSave: (TCPad) -> Void
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var pad: TCPad
    @State private var startEntry: TCEntry
    @State private var durationEntry: TCEntry
    @State private var hasDuration: Bool
    @State private var focus: Field = .start
    @FocusState private var labelFocused: Bool
    @FocusState private var keyFocus: Bool

    enum Field { case start, duration }

    init(pad: TCPad, bank: PadBank, isNew: Bool, onSave: @escaping (TCPad) -> Void,
         onDelete: (() -> Void)? = nil, onDuplicate: (() -> Void)? = nil) {
        self.bank = bank
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onDuplicate = onDuplicate
        _pad = State(initialValue: pad)
        _startEntry = State(initialValue: TCEntry(timecode: pad.startTimecode(in: bank)))
        let d = pad.duration ?? 60
        let rate = pad.rate(in: bank)
        let durTC = Timecode(hours: Int(d) / 3600, minutes: (Int(d) / 60) % 60, seconds: Int(d) % 60,
                             frames: min(rate.nominalFPS - 1, Int(((d - d.rounded(.down)) * rate.fps).rounded())), rate: rate)
        _durationEntry = State(initialValue: TCEntry(timecode: durTC))
        _hasDuration = State(initialValue: pad.duration != nil)
    }

    private var rate: FrameRate { pad.rateOverride ?? bank.rate }
    /// Durations are counted in plain frames, never drop-frame labels.
    private var durationRate: FrameRate { rate == .fps29_97df ? .fps29_97ndf : rate }
    private var startError: String? { startEntry.validationMessage(rate: rate) }
    private var durationError: String? {
        guard hasDuration else { return nil }
        if let m = durationEntry.validationMessage(rate: durationRate) { return m }
        return durationSeconds <= 0 ? "Duration must be longer than zero." : nil
    }
    private var durationSeconds: TimeInterval {
        Double(durationEntry.hours * 3600 + durationEntry.minutes * 60 + durationEntry.seconds)
            + Double(durationEntry.frames) / durationRate.fps
    }
    private var canSave: Bool { startError == nil && durationError == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $pad.label)
                        .focused($labelFocused)
                        .font(.system(size: 17, weight: .medium))
                    colourRow
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldHeader("Start", detail: PadsFormat.rate(rate))
                        TCEntryField(entry: startEntry, rate: rate, isActive: focus == .start, isValid: startError == nil)
                            .contentShape(Rectangle())
                            .onTapGesture { focus = .start; labelFocused = false; keyFocus = true }
                        if let startError { errorText(startError) }

                        Toggle("Stop after", isOn: $hasDuration.animation(.easeOut(duration: 0.15)))
                            .font(Theme.label)
                            .padding(.top, 4)
                            .onChange(of: hasDuration) { _, on in focus = on ? .duration : .start }
                        if hasDuration {
                            TCEntryField(entry: durationEntry, rate: durationRate, isActive: focus == .duration,
                                         isValid: durationError == nil, size: 26)
                                .contentShape(Rectangle())
                                .onTapGesture { focus = .duration; labelFocused = false; keyFocus = true }
                            if let durationError { errorText(durationError) }
                        }

                        TCKeypad(onDigit: { type($0) }, onDoubleZero: { edit { $0.pushDoubleZero() } },
                                 onBackspace: { edit { $0.backspace() } }, onClear: { edit { $0.clear() } })
                            .padding(.top, 6)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Type digits from the right: 1 0 0 0 0 0 0 enters 01:00:00:00.")
                }

                Section {
                    Picker("Frame rate", selection: rateBinding) {
                        Text("Bank (\(PadsFormat.rate(bank.rate)))").tag(FrameRate?.none)
                        ForEach(FrameRate.allCases) { r in Text(PadsFormat.rate(r)).tag(FrameRate?.some(r)) }
                    }
                    Picker("Output", selection: $pad.side) {
                        Text("Left").tag(OutputSide.left)
                        Text("Both").tag(OutputSide.both)
                        Text("Right").tag(OutputSide.right)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Level")
                        Slider(value: $pad.levelDBFS, in: -30...0, step: 1)
                        Text(String(format: "%.0f dBFS", pad.levelDBFS))
                            .font(Theme.numeric(14))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 84, alignment: .trailing)
                    }
                    Picker("Pre-roll", selection: $pad.preRollOverride) {
                        Text(bank.preRollSeconds > 0 ? "Bank (\(Int(bank.preRollSeconds)) s)" : "Bank (off)").tag(Double?.none)
                        ForEach(PadsPreRoll.options, id: \.self) { s in
                            Text(s == 0 ? "Off" : "\(Int(s)) s").tag(Double?.some(s))
                        }
                    }
                }

                if !isNew {
                    Section {
                        if let onDuplicate {
                            Button("Duplicate pad") { onDuplicate(); dismiss() }
                        }
                        if let onDelete {
                            Button("Delete pad", role: .destructive) { onDelete(); dismiss() }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(isNew ? "New pad" : "Edit pad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .focusable()
            .focused($keyFocus)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                guard !labelFocused else { return .ignored }
                if let d = press.characters.first?.wholeNumberValue, press.characters.first?.isASCII == true { type(d); return .handled }
                if press.key == .delete { edit { $0.backspace() }; return .handled }
                if press.key == .return, canSave { save(); return .handled }
                return .ignored
            }
            .onAppear { keyFocus = true }
        }
        .preferredColorScheme(.dark)
    }

    private var rateBinding: Binding<FrameRate?> {
        Binding(get: { pad.rateOverride }, set: { newRate in
            let oldRate = rate
            pad.rateOverride = newRate
            let r = newRate ?? bank.rate
            if r != oldRate {
                let tc = Timecode(hours: startEntry.hours, minutes: startEntry.minutes, seconds: startEntry.seconds,
                                  frames: startEntry.frames, rate: oldRate)
                startEntry = TCEntry(timecode: TCPad.conform(tc, to: r))
            }
        })
    }

    private var colourRow: some View {
        HStack(spacing: 10) {
            Text("Colour").foregroundStyle(Theme.textPrimary)
            Spacer()
            ForEach(PadColor.allCases) { c in
                Button { pad.color = c } label: {
                    ZStack {
                        if c == .none {
                            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1)
                            Image(systemName: "line.diagonal").font(.system(size: 12, weight: .light)).foregroundStyle(Theme.textTertiary)
                        } else {
                            Circle().fill(c.color)
                        }
                        if pad.color == c {
                            Circle().strokeBorder(Theme.textPrimary, lineWidth: 2).padding(-4)
                        }
                    }
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.label)
            }
        }
    }

    private func fieldHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(Theme.label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(detail).font(Theme.numeric(12)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func errorText(_ s: String) -> some View {
        Text(s).font(Theme.caption).foregroundStyle(Theme.stop).fixedSize(horizontal: false, vertical: true)
    }

    private func type(_ d: Int) { edit { $0.push(d) } }

    private func edit(_ change: (inout TCEntry) -> Void) {
        if focus == .duration && hasDuration { change(&durationEntry) } else { change(&startEntry) }
    }

    private func save() {
        guard canSave, let tc = startEntry.timecode(rate: rate) else { return }
        var p = pad
        p.start = tc
        p.duration = hasDuration ? durationSeconds : nil
        if p.label.trimmingCharacters(in: .whitespaces).isEmpty { p.label = tc.description }
        onSave(p)
        dismiss()
    }
}

enum PadsPreRoll {
    static let options: [Double] = [0, 2, 3, 5, 10]
}
