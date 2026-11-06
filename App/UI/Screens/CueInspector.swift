import SwiftUI
import SwiftData
import TCKit

/// Cue inspector. Presented with `.inspector` (trailing column on iPad, sheet on iPhone).
/// Routing edits to the playing cue go live to the output.
struct CueInspector: View {
    @Bindable var cue: Cue
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false

    @State private var startText = ""
    @State private var durationText = ""

    private var rate: FrameRate { FrameRate(rawValue: cue.genRateRaw) ?? .fps30 }
    private var startValid: Bool { Timecode(string: startText, rate: rate) != nil }
    private var isLive: Bool { shell.isPlaying(cue) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if showLock {
                        Label("Show Lock is on. Unlock to edit this cue.", systemImage: "lock.fill")
                            .font(Theme.caption).foregroundStyle(Theme.standby)
                    }
                    group("Cue") { cueFields }
                    group("Follow") {
                        FlatSegmented(options: FollowMode.allCases.map { ($0, $0.label) },
                                      selection: Binding(get: { cue.follow }, set: { cue.follow = $0; save() }), height: 30)
                    }
                    group("Routing", trailing: isLive ? "Live" : nil) { routingFields }
                    if cue.kind == .generator { group("Generator") { generatorFields } }
                    if cue.kind == .track, let t = cue.track { group("File") { fileInfo(t) } }
                }
                .padding(16)
                .disabled(showLock)
            }
            .background(Theme.surface)
            .navigationTitle("Cue \(cue.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); shell.showInspector = false; dismiss() }
                }
            }
        }
        .onAppear {
            startText = Fmt.timecode(cue.genStart, rate: rate)
            durationText = cue.genDuration > 0 ? Fmt.clock(cue.genDuration) : ""
        }
        .onDisappear(perform: save)
    }

    // MARK: Sections

    private var cueFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                field("Number", width: 84) {
                    TextField("1", text: $cue.number)
                        .font(Theme.numeric(15, weight: .semibold))
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
                field("Title") {
                    TextField("Title", text: $cue.title).font(.body)
                }
            }
            field("Notes") {
                TextField("Notes for the operator", text: $cue.notes, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Colour").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    swatch(nil)
                    ForEach(CueColorTag.allCases) { swatch($0) }
                }
            }
        }
    }

    private func swatch(_ tag: CueColorTag?) -> some View {
        let on = cue.colorHex == tag?.rawValue
        return Button { cue.colorHex = tag?.rawValue; save() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tag?.color ?? Theme.surfaceSunken)
                    .frame(width: 26, height: 26)
                if tag == nil {
                    Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(on ? Theme.textPrimary : Theme.hairline, lineWidth: on ? 2 : Theme.hairlineWidth)
                    .frame(width: 32, height: 32)
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag?.label ?? "No colour")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var routingFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                latch(cue.leftEnabled ? "L  Play" : "L  Mute", on: !cue.leftEnabled, color: Theme.stop) { cue.leftEnabled.toggle() }
                latch(cue.rightEnabled ? "R  Play" : "R  Mute", on: !cue.rightEnabled, color: Theme.stop) { cue.rightEnabled.toggle() }
                latch("Swap", on: cue.swapped, color: Theme.standby) { cue.swapped.toggle() }
            }
            .frame(height: 38)
            HStack(spacing: 10) {
                Text("Gain").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                FaderSlider(value: Binding(get: { Double(max(cue.gainDB, -40)) },
                                           set: { v in cue.gainDB = abs(v) < 0.4 ? 0 : Float((v * 2).rounded() / 2); routingChanged() }),
                            range: -40...6)
                Text(Fmt.dB(cue.gainDB))
                    .font(Theme.numeric(13, weight: .regular))
                    .frame(width: 70, alignment: .trailing)
            }
            if isLive {
                Text("Changes apply to the playing cue immediately.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var generatorFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                field("Start timecode", invalid: !startValid) {
                    TextField("01:00:00:00", text: $startText)
                        .font(Theme.numeric(17, weight: .medium))
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .onChange(of: startText) { _, v in
                            if let tc = Timecode(string: v, rate: rate) { cue.genStart = tc.description; save() }
                        }
                }
                field("Duration", width: 120) {
                    TextField("Until stopped", text: $durationText)
                        .font(Theme.numeric(15, weight: .regular))
                        .keyboardType(.numbersAndPunctuation)
                        .onSubmit(commitDuration)
                        .onChange(of: durationText) { _, _ in commitDuration() }
                }
            }
            if !startValid {
                Text("Enter HH:MM:SS:FF, frames below \(rate.nominalFPS).")
                    .font(Theme.caption).foregroundStyle(Theme.stop)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Frame rate").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                FlatSegmented(options: FrameRate.allCases.map { ($0, $0.operatorLabel) },
                              selection: Binding(get: { rate }, set: { r in
                                  cue.genRateRaw = r.rawValue
                                  if let tc = Timecode(string: startText, rate: r) {
                                      cue.genStart = tc.description; startText = tc.description
                                  }
                                  save()
                              }), height: 30)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Output side").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                FlatSegmented(options: [(OutputSide.left, "Left"), (.right, "Right"), (.both, "Both")],
                              selection: Binding(get: { OutputSide(rawValue: cue.genSideRaw) ?? .right },
                                                 set: { cue.genSideRaw = $0.rawValue; save() }), height: 30)
            }
            HStack {
                Text("Level").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                // TODO(merge): Cue has no stored generator level; GeneratorConfig.levelDBFS defaults to −10.
                Text("−10.0 dBFS").font(Theme.numeric(13, weight: .regular)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func fileInfo(_ t: Track) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow("File", t.fileName, mono: false)
            infoRow("Length", Fmt.duration(t.duration))
            infoRow("Format", "\(t.channelCount == 1 ? "Mono" : "Stereo") · \(CueNumbering.format(t.sampleRate / 1000)) kHz")
            if let ch = t.ltcChannel {
                let r = t.ltcRate.flatMap(FrameRate.init(rawValue:))
                infoRow("Timecode", "\(ch == "left" ? "Left" : "Right") · \(Fmt.timecode(t.ltcStart ?? "–", rate: r)) · \(r?.operatorLabel ?? "–")")
            } else {
                infoRow("Timecode", "None detected", mono: false)
            }
        }
    }

    // MARK: Building blocks

    private func group<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title) {
                if let trailing {
                    HStack(spacing: 5) {
                        IndicatorLamp(color: Theme.go, isOn: true, size: 6)
                        Text(trailing).font(Theme.caption).foregroundStyle(Theme.go)
                    }
                }
            }
            content()
        }
    }

    private func field<C: View>(_ title: String, width: CGFloat? = nil, invalid: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            content()
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(minHeight: 38)
                .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surfaceSunken))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(invalid ? Theme.stop : Theme.hairline, lineWidth: invalid ? 1 : Theme.hairlineWidth))
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func infoRow(_ k: String, _ v: String, mono: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(Theme.caption).foregroundStyle(Theme.textSecondary).frame(width: 80, alignment: .leading)
            Text(v).font(mono ? Theme.numeric(12, weight: .regular) : Theme.caption)
                .foregroundStyle(Theme.textPrimary).lineLimit(2)
        }
    }

    private func latch(_ title: String, on: Bool, color: Color, toggle: @escaping () -> Void) -> some View {
        Button { toggle(); routingChanged(); Haptics.tick() } label: {
            Text(title).font(Theme.label)
        }
        .buttonStyle(LatchButtonStyle(isOn: on, onColor: color))
    }

    private func routingChanged() {
        shell.cueRoutingEdited(cue)
        save()
    }

    private func commitDuration() {
        let t = durationText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { cue.genDuration = 0; save(); return }
        let parts = t.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return }
        cue.genDuration = parts.reduce(0) { $0 * 60 + $1 }
        save()
    }

    private func save() { try? context.save() }
}
