import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.clockStyle) private var clockStyle = ClockStyle.mono.rawValue
    @AppStorage(SettingsKey.clockColorPreset) private var clockColor = ClockColorPreset.amber.rawValue
    @AppStorage(SettingsKey.clockCustomColorHex) private var customHex = "#F2F3F5"
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.dark.rawValue
    @AppStorage(SettingsKey.theme) private var theme = AppTheme.graphite.rawValue
    @AppStorage(SettingsKey.keepAwake) private var keepAwake = true
    @AppStorage(SettingsKey.preRollSeconds) private var preRoll = 0.0
    @AppStorage(SettingsKey.showLock) private var showLock = false
    @AppStorage(SettingsKey.doubleGoWindow) private var doubleGo = 1.0
    @AppStorage(SettingsKey.panicFadeSeconds) private var panicFade = 1.0
    @AppStorage(SettingsKey.autoDetectTimecode) private var autoDetect = true
    @AppStorage(SettingsKey.readExternalInput) private var readInput = false
    @Bindable private var caller = CueCallerUIModel.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    clockPreview
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Colour").font(Theme.label).foregroundStyle(Theme.textPrimary)
                        swatches
                    }
                    .padding(.vertical, 4)
                    Picker("Style", selection: $clockStyle) {
                        ForEach(ClockStyle.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } header: { header("Clock") }
                .listRowBackground(Theme.surface)

                Section {
                    themePicker
                        .padding(.vertical, 4)
                    if theme != AppTheme.light.rawValue {
                        Toggle("Use Light when the device is in light mode", isOn: Binding(
                            get: { appearance == AppearanceMode.system.rawValue },
                            set: { appearance = $0 ? AppearanceMode.system.rawValue : AppearanceMode.dark.rawValue }))
                    }
                    Toggle("Keep screen awake while playing", isOn: $keepAwake)
                } header: { header("Display") }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Show Lock", isOn: $showLock)
                    Picker("Double-GO protection", selection: $doubleGo) {
                        Text("Off").tag(0.0)
                        Text("0.5 s").tag(0.5)
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                    }
                    Picker("Locked stop fade", selection: $panicFade) {
                        Text("0.5 s").tag(0.5)
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("3 s").tag(3.0)
                    }
                    Stepper(value: $preRoll, in: 0...10, step: 0.5) {
                        HStack {
                            Text("Pre-roll")
                            Spacer()
                            Text(preRoll == 0 ? "None" : String(format: "%.1f s", preRoll))
                                .font(Theme.numeric(14, weight: .regular))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                } header: { header("Show") } footer: {
                    Text("With Show Lock on, cues can’t be edited, reordered or scrubbed, and Stop needs a one-second hold.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Cue caller", isOn: $caller.isEngaged).tint(Theme.go)
                    NavigationLink {
                        CueCallerSettingsForm()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Areas, voices and timing")
                            Spacer()
                            CueCallerLamp(status: caller.status)
                            Text(caller.status.label).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                } header: { header("Cue caller") } footer: {
                    Text("Speaks each mark’s call over comms, in each area’s language.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Detect timecode in tracks", isOn: $autoDetect)
                    Toggle("Read timecode from audio input", isOn: $readInput)
                    LabeledContent("Output") {
                        Text(shell.engine.outputRouteName).foregroundStyle(Theme.textSecondary)
                    }
                } header: { header("Audio") }
                .listRowBackground(Theme.surface)

                Section {
                    LabeledContent("TC Playback · PIXEL HAUS") {
                        Text(version).font(Theme.numeric(13, weight: .regular)).foregroundStyle(Theme.textSecondary)
                    }
                } header: { header("About") }
                .listRowBackground(Theme.surface)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .tint(Theme.accent)
            .id(theme)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: autoDetect) { _, v in shell.engine.autoDetectTimecode = v }
            .onChange(of: readInput) { _, v in shell.engine.readExternalInput = v }
        }
    }

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Theme").font(Theme.label).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                ForEach(AppTheme.allCases) { t in
                    let p = t == .light ? ThemePalette.light : t.darkPalette
                    let on = theme == t.rawValue
                    Button {
                        theme = t.rawValue
                        AppTheme.active = t
                        appearance = t == .light ? AppearanceMode.light.rawValue
                            : (appearance == AppearanceMode.system.rawValue ? appearance : AppearanceMode.dark.rawValue)
                    } label: {
                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomLeading) {
                                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: p.background))
                                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(hex: p.surface))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: p.hairline), lineWidth: 1))
                                    .padding(6)
                                RoundedRectangle(cornerRadius: 1).fill(Color(hex: p.textPrimary)).frame(width: 18, height: 3)
                                    .padding(.leading, 12).padding(.bottom, 12)
                            }
                            .frame(height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(on ? Theme.accent : Theme.hairline, lineWidth: on ? 2 : 1).padding(-3))
                            Text(t.label).font(Theme.caption)
                                .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 3)
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary).textCase(nil)
    }

    private var clockPreview: some View {
        TimecodeClockView(compact: true)
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surfaceSunken))
            .id("\(clockStyle)-\(clockColor)-\(customHex)")
    }

    private var swatches: some View {
        HStack(spacing: 10) {
            ForEach(ClockColorPreset.allCases.filter { $0 != .custom }) { p in
                swatch(color: p.color, selected: clockColor == p.rawValue, label: p.label) {
                    clockColor = p.rawValue
                }
            }
            Rectangle().fill(Theme.hairline).frame(width: Theme.hairlineWidth, height: 26)
            ColorPicker(selection: Binding(
                get: { Color(hexString: customHex) ?? .white },
                set: { customHex = $0.hexString; clockColor = ClockColorPreset.custom.rawValue }),
                supportsOpacity: false) { EmptyView() }
                .labelsHidden()
                .frame(width: 30, height: 30)
                .overlay {
                    if clockColor == ClockColorPreset.custom.rawValue {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.textPrimary, lineWidth: 2)
                            .frame(width: 36, height: 36).allowsHitTesting(false)
                    }
                }
            Text("Custom").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func swatch(color: Color, selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color)
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Theme.textPrimary : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// Pre-show checklist: manual ticks, auto-ticked where the system can tell.
struct PreShowChecklist: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.keepAwake) private var keepAwake = true
    @AppStorage(SettingsKey.showLock) private var showLock = false
    @State private var ticks: Set<String> = []
    @State private var battery: UIDevice.BatteryState = .unknown
    @State private var level: Float = -1

    private struct Item: Identifiable { let id: String; let title: String; let detail: String; let auto: Bool? }

    private var route: String { shell.engine.outputRouteName }
    private var routeIsInterface: Bool {
        let r = route.lowercased()
        return !(r.contains("speaker") || r.contains("receiver"))
    }

    private var items: [Item] {
        let charging = battery == .charging || battery == .full
        return [
            Item(id: "dnd", title: "Do Not Disturb or a Focus is on", detail: "Stops calls and notification sounds reaching the output.", auto: nil),
            Item(id: "airplane", title: "Airplane mode", detail: "Turn Wi-Fi back on only if you need it. Airplane mode doesn’t silence local alerts.", auto: nil),
            Item(id: "power", title: "On charge", detail: battery == .unknown ? "Battery state unavailable."
                 : (charging ? "Charging" : "On battery") + (level >= 0 ? String(format: " · %d%%", Int(level * 100)) : ""),
                 auto: battery == .unknown ? nil : charging),
            Item(id: "awake", title: "Screen stays awake", detail: keepAwake ? "TC Playback keeps the screen on while playing." : "Turn on “Keep screen awake” in Settings.", auto: keepAwake),
            Item(id: "route", title: "Output is the audio interface", detail: "Current output: \(route)", auto: routeIsInterface),
            Item(id: "lock", title: "Show Lock on", detail: "Prevents edits, scrubbing and accidental stops.", auto: showLock),
            Item(id: "guided", title: "Guided Access (optional)", detail: "Settings › Accessibility › Guided Access, then triple-click the side button to keep the app in front.", auto: nil),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        let done = item.auto ?? ticks.contains(item.id)
                        Button {
                            guard item.auto == nil else { return }
                            if ticks.contains(item.id) { ticks.remove(item.id) } else { ticks.insert(item.id) }
                            Haptics.tick()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: done ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 18, weight: .regular))
                                    .foregroundStyle(done ? Theme.go : (item.auto == false ? Theme.standby : Theme.textTertiary))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.body).foregroundStyle(Theme.textPrimary)
                                    Text(item.detail).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                if item.auto != nil {
                                    Text("Automatic").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.surface)
                        .listRowSeparatorTint(Theme.hairline)
                    }
                } footer: {
                    let done = items.filter { $0.auto ?? ticks.contains($0.id) }.count
                    Text("\(done) of \(items.count) checked")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Pre-show check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            battery = UIDevice.current.batteryState
            level = UIDevice.current.batteryLevel
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            battery = UIDevice.current.batteryState; level = UIDevice.current.batteryLevel
        }
    }
}
