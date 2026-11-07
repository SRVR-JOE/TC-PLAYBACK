import SwiftUI

// ElevenLabs voices in the cue caller screens: the Voices section of the settings form, the
// "Prepare calls" row (settings and Calls review), and the shared voice browser.

private func voicesHeader(_ s: String) -> some View {
    Text(s).font(Theme.sectionHeader).foregroundStyle(Theme.textSecondary).textCase(nil)
}

// MARK: - Settings section

/// Key, account status, model, and offline preparation. Goes inside `CueCallerSettingsForm`.
struct CueCallVoicesSection: View {
    @Bindable private var voices = CueCallVoicesModel.shared
    @State private var keyText = ""
    @State private var replacing = false
    @State private var confirmRemove = false

    var body: some View {
        Section {
            if voices.hasKey && !replacing {
                LabeledContent("ElevenLabs") {
                    Text(voices.connection.label)
                        .font(Theme.caption)
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.trailing)
                }
                if voices.keyIsForTesting {
                    Text("Using the testing key from the launch settings.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                HStack(spacing: 10) {
                    Button("Replace key") { keyText = ""; replacing = true }.buttonStyle(OutlineButtonStyle())
                    Button("Check") { voices.refreshStatus() }.buttonStyle(OutlineButtonStyle())
                    Spacer()
                    if !voices.keyIsForTesting {
                        Button("Remove", role: .destructive) { confirmRemove = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.stop)
                    }
                }
                Picker("Model", selection: $voices.model) {
                    ForEach(ElevenLabsModel.allCases) { Text($0.label).tag($0) }
                }
            } else {
                SecureField("ElevenLabs API key", text: $keyText)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(save)
                HStack(spacing: 10) {
                    Button("Save key", action: save)
                        .buttonStyle(OutlineButtonStyle(prominent: true))
                        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if replacing { Button("Cancel") { replacing = false; keyText = "" }.buttonStyle(OutlineButtonStyle()) }
                    Spacer()
                }
                if case .failed(let m) = voices.connection {
                    Text(m).font(Theme.caption).foregroundStyle(Theme.standby)
                }
            }
        } header: { voicesHeader("Voices") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("ElevenLabs voices sound the most natural. Calls are made while you’re online and saved on this iPad, so the show runs without a network.")
                if voices.hasKey && voices.model == .flashV2_5 {
                    Text("Flash is quicker and uses fewer characters, but reads numbers less reliably than Multilingual v2.")
                }
                if !voices.hasKey {
                    Text("The key is kept in this iPad’s keychain. Find it in your ElevenLabs account under API keys.")
                }
            }
        }
        .listRowBackground(Theme.surface)
        .task { if voices.hasKey { voices.refreshStatus(); voices.loadAccountVoices() } }
        .confirmationDialog("Remove the ElevenLabs key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) { voices.removeKey() }
        } message: {
            Text("Calls already saved on this iPad still play. New calls use the device voice.")
        }

        if voices.hasKey {
            Section {
                CueCallPrepareRow()
            } header: { voicesHeader("Offline calls") } footer: {
                Text("Prepare calls before the show, while you’re online. If a call can’t be made during the show, the device voice says it instead.")
            }
            .listRowBackground(Theme.surface)
        }
    }

    private var statusColor: Color {
        switch voices.connection {
        case .connected: Theme.textSecondary
        case .failed: Theme.standby
        default: Theme.textTertiary
        }
    }

    private func save() {
        let k = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        voices.saveKey(k)
        keyText = ""
        replacing = false
    }
}

// MARK: - Prepare calls

/// "Prepare calls" with progress and "N of M calls ready offline". `marks` nil = the track the
/// caller has loaded (or the show's playing / standby track).
struct CueCallPrepareRow: View {
    var marks: [CueCallMark]? = nil
    var title: String? = nil
    var compact = false
    @Bindable private var voices = CueCallVoicesModel.shared

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .task(id: marksKey) { voices.refreshReadiness(marks: marks, title: title) }
    }

    private var marksKey: String {
        (marks ?? []).map { "\($0.id)\($0.note)" }.joined() + "|\(CueCallerUIModel.shared.settings.areas.map { "\($0.voiceID ?? "")\($0.language)\($0.enabled)\($0.rate)" }.joined())"
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(voices.prepareTrackTitle.map { "Calls for \($0)" } ?? "Calls for the current track")
                        .foregroundStyle(Theme.textPrimary)
                    Text(voices.preparing ? "Preparing \(voices.prepareDone) of \(voices.prepareTotal)…" : voices.readinessLine)
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                Spacer()
                prepareButton
            }
            if voices.preparing && voices.prepareTotal > 0 {
                ProgressView(value: Double(voices.prepareDone), total: Double(voices.prepareTotal))
                    .tint(Theme.textSecondary)
            }
            if let e = voices.prepareError {
                Text(e).font(Theme.caption).foregroundStyle(Theme.standby)
            }
            if let f = voices.fallbackLine {
                Text("\(f). Prepare calls again when you’re online.")
                    .font(Theme.caption).foregroundStyle(Theme.standby)
            }
        }
        .padding(.vertical, 2)
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            if voices.preparing {
                ProgressView(value: Double(voices.prepareDone), total: Double(max(1, voices.prepareTotal)))
                    .tint(Theme.textSecondary).frame(width: 80)
                Text("\(voices.prepareDone) of \(voices.prepareTotal)").font(Theme.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
            } else {
                Text(voices.fallbackLine ?? voices.readinessLine)
                    .font(Theme.caption)
                    .foregroundStyle(voices.fallbackLine != nil || voices.readyOffline < voices.elevenCallCount ? Theme.standby : Theme.textSecondary)
                    .lineLimit(1)
            }
            prepareButton
        }
    }

    @ViewBuilder private var prepareButton: some View {
        if voices.preparing {
            Button("Stop") { voices.cancelPrepare() }.buttonStyle(OutlineButtonStyle())
        } else {
            Button("Prepare calls") { voices.prepareCalls(marks: marks, title: title) }
                .buttonStyle(OutlineButtonStyle())
                .disabled(!voices.hasKey || voices.elevenCallCount == 0)
        }
    }
}

// MARK: - Shared voice browser

/// "Find voices for <language>": shared library voices for the area's language and accent,
/// most used first. Picking one adds it to the account and uses it for the area.
struct ElevenLabsVoiceBrowser: View {
    let language: String
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Bindable private var voices = CueCallVoicesModel.shared
    @State private var gender: String = ""

    var body: some View {
        List {
            Section {
                FlatSegmented(options: [("", "Any"), ("female", "Female"), ("male", "Male")], selection: $gender, height: 28)
                    .fixedSize()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                Text(footer)
            }
            Section {
                if voices.searching && voices.sharedVoices.isEmpty {
                    HStack { ProgressView(); Text("Looking for voices…").foregroundStyle(Theme.textSecondary) }
                }
                if let e = voices.searchError {
                    Text(e).font(Theme.caption).foregroundStyle(Theme.standby)
                }
                ForEach(voices.sharedVoices) { v in row(v) }
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Voices for \(CueCallerUIModel.languageName(language))")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: gender) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-cueCallerPreview") { return }
            #endif
            await voices.searchShared(language: language, gender: gender.isEmpty ? nil : gender)
        }
        .onDisappear { voices.stopPreview() }
    }

    private var footer: String {
        let tag = language.lowercased()
        if tag == "de-ch" {
            return "Swiss voices speak Standard German with a Swiss accent, the way Swiss crews hear calls."
        }
        return "Native speakers from the ElevenLabs voice library, most used first."
    }

    private func row(_ v: ElevenLabsSharedVoice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(v.name).font(.body).foregroundStyle(Theme.textPrimary)
                Text(Self.traits(v)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                if let d = v.description, !d.isEmpty {
                    Text(d).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if CueCallVoicesModel.canPreview, v.previewURL != nil {
                Button(voices.previewing == v.voiceID ? "Stop" : "Preview") { voices.preview(v.voiceID, url: v.previewURL) }
                    .buttonStyle(OutlineButtonStyle())
            }
            Button {
                Task {
                    if let id = await voices.add(v) { onPick(id); dismiss() }
                }
            } label: {
                if voices.adding == v.voiceID { ProgressView() } else { Text("Use") }
            }
            .buttonStyle(OutlineButtonStyle(prominent: true))
            .disabled(voices.adding != nil)
        }
        .padding(.vertical, 4)
    }

    /// "Swiss · Female · Middle aged".
    static func traits(_ v: ElevenLabsSharedVoice) -> String {
        func nice(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            let t = s.replacingOccurrences(of: "_", with: " ")
            return t.prefix(1).uppercased() + t.dropFirst()
        }
        return [nice(v.accent), nice(v.gender), nice(v.age)].compactMap { $0 }.joined(separator: " · ")
    }
}
