import SwiftUI
import TCKit

/// Output Test: side-isolated voice idents and calibrated signals for walking the system.
struct OutputTestView: View {
    @State private var tester = OutputTester()
    @State private var signalSide: OutputSide = .left
    @State private var pending: OutputTester.Signal?
    @Environment(\.horizontalSizeClass) private var hSize

    private var isPad: Bool { hSize == .regular }

    var body: some View {
        GeometryReader { geo in
            content(wide: geo.size.width > 1000)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func content(wide: Bool) -> some View {
        ScrollView {
            VStack(spacing: Theme.pad) {
                statusPanel
                if wide {
                    HStack(alignment: .top, spacing: Theme.pad) {
                        VStack(spacing: Theme.pad) { identPanel; signalPanel }
                        voicePanel.frame(width: 380)
                    }
                } else {
                    identPanel
                    signalPanel
                    voicePanel
                }
            }
            .padding(Theme.pad)
        }
        .background(Theme.background.ignoresSafeArea())
        .sensoryFeedback(.impact(weight: .light), trigger: tester.current)
        .alert("A cue is playing. Stop it and run the test?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Stop and test", role: .destructive) {
                if let s = pending { tester.engine.stop(); Task { await tester.play(s) } }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        }
        .alert("Output test", isPresented: Binding(get: { tester.errorMessage != nil },
                                                   set: { if !$0 { tester.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(tester.errorMessage ?? "") }
        .onAppear(perform: debugLaunchHook)
    }

    private func run(_ s: OutputTester.Signal) {
        if tester.current == s && tester.isPlaying { tester.stop(); return }
        if tester.showCueIsPlaying { pending = s } else { Task { await tester.play(s) } }
    }

    /// DEBUG only: `-outputTestPlay left|right|both|sequence|tone` starts a test on launch.
    private func debugLaunchHook() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-outputTestPlay"), i + 1 < args.count else { return }
        let map: [String: OutputTester.Signal] = ["left": .ident(.left), "right": .ident(.right), "both": .ident(.both),
                                                  "sequence": .sequence, "tone": .tone(.left), "pink": .pink(.right)]
        if let s = map[args[i + 1]] { Task { await tester.play(s) } }
        #endif
    }

    // MARK: Status

    private var statusPanel: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let lit = tester.litSides(at: context.date)
            HStack(spacing: isPad ? 28 : 16) {
                sideLamp("L", on: lit.l)
                sideLamp("R", on: lit.r)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tester.isRendering ? "Preparing voice…" : (tester.isPlaying ? tester.current?.title ?? "Playing" : "Ready"))
                        .font(.system(size: isPad ? 20 : 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: routeIcon).font(.system(size: 12, weight: .light))
                        Text(tester.engine.outputRouteName).font(Theme.label)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                Button { tester.stop() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill").font(.system(size: 15))
                        if isPad { Text("Stop").font(.system(size: 16, weight: .semibold)) }
                    }
                    .foregroundStyle(tester.isPlaying ? Theme.stop : Theme.textTertiary)
                    .frame(minWidth: isPad ? 110 : 56, minHeight: 48)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(KeyPressStyle())
                .disabled(!tester.isPlaying)
                .accessibilityLabel("Stop test")
            }
            .padding(isPad ? 18 : 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    private var routeIcon: String {
        let r = tester.engine.outputRouteName.lowercased()
        if r.contains("headphone") { return "headphones" }
        if r.contains("usb") || r.contains("interface") { return "cable.connector" }
        if r.contains("airplay") { return "airplayaudio" }
        if r.contains("bluetooth") { return "wave.3.right" }
        return "speaker.wave.2"
    }

    private func sideLamp(_ label: String, on: Bool) -> some View {
        VStack(spacing: 6) {
            Circle()
                .fill(on ? Theme.go : Theme.lockOff)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
                .frame(width: isPad ? 26 : 20, height: isPad ? 26 : 20)
            Text(label).font(Theme.numeric(13, weight: .semibold))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label == "L" ? "Left" : "Right") \(on ? "on" : "off")")
    }

    // MARK: Idents

    private var identPanel: some View {
        Panel(title: "Voice ident") {
            let cols = isPad ? 4 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                bigButton("Left", detail: "Left side only", signal: .ident(.left))
                bigButton("Right", detail: "Right side only", signal: .ident(.right))
                bigButton("Both", detail: "Both sides", signal: .ident(.both))
                bigButton("Sequence", detail: "Left, right, repeat", signal: .sequence)
            }
        }
    }

    private func bigButton(_ title: String, detail: String, signal: OutputTester.Signal, height: CGFloat = 92) -> some View {
        let active = tester.current == signal && tester.isPlaying
        return Button { run(signal) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(active ? "Playing · tap to stop" : detail).font(Theme.caption)
                    .foregroundStyle(active ? Theme.go : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(active ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge)
                .strokeBorder(active ? Theme.go : Theme.hairline, lineWidth: active ? 2 : 1))
        }
        .buttonStyle(PadPressStyle())
        .disabled(tester.isRendering)
    }

    // MARK: Signals

    private var signalPanel: some View {
        Panel(title: "Test signals", trailing: {
            Picker("Side", selection: $signalSide) {
                Text("Left").tag(OutputSide.left)
                Text("Both").tag(OutputSide.both)
                Text("Right").tag(OutputSide.right)
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
        }) {
            let cols = isPad ? 4 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                signalButton("1 kHz tone", level: "−18 dBFS", signal: .tone(signalSide))
                signalButton("Pink noise", level: "−20 dBFS", signal: .pink(signalSide))
                signalButton("Polarity", level: "Both sides", signal: .polarity)
                signalButton("LTC", level: "\(TCPad.conform(OutputTester.ltcTestStart, to: tester.ltcRate).description) · 5 s",
                             signal: .ltc(signalSide))
            }
            HStack {
                Text("LTC frame rate").font(Theme.label).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("LTC frame rate", selection: $tester.ltcRate) {
                    ForEach(FrameRate.allCases) { Text(PadsFormat.rate($0)).tag($0) }
                }
                .tint(Theme.textPrimary)
            }
            .padding(.top, 4)
        }
    }

    private func signalButton(_ title: String, level: String, signal: OutputTester.Signal) -> some View {
        let active = tester.current == signal && tester.isPlaying
        return Button { run(signal) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(active ? "Playing" : level).font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(active ? Theme.go : Theme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(active ? Theme.surfaceRaised : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(active ? Theme.go : Theme.hairline, lineWidth: active ? 2 : 1))
        }
        .buttonStyle(PadPressStyle())
    }

    // MARK: Voice

    private var voicePanel: some View {
        Panel(title: "Voice") {
            VStack(alignment: .leading, spacing: 12) {
                if tester.voices.isEmpty {
                    Text("No English voice is installed on this device.")
                        .font(Theme.label).foregroundStyle(Theme.textSecondary)
                } else {
                    Menu {
                        Picker("Narrator", selection: Binding(get: { tester.selectedVoiceID ?? "" },
                                                              set: { tester.selectedVoiceID = $0 })) {
                            ForEach(tester.voices) { v in
                                Text("\(v.name) (\(v.regionLabel), \(v.qualityLabel))").tag(v.id)
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tester.selectedVoice?.name ?? "Choose a voice")
                                    .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                if let v = tester.selectedVoice {
                                    Text("English (\(v.regionLabel)) · \(v.qualityLabel)")
                                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 52)
                        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.corner))
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                    Text("Calm, slow documentary narration. Renders once per voice, then plays from memory.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { run(.ident(.both)) } label: {
                        HStack(spacing: 8) {
                            if tester.isRendering { ProgressView().controlSize(.small) }
                            else { Image(systemName: "play.fill").font(.system(size: 12)) }
                            Text("Preview").font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.corner))
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(KeyPressStyle())
                    .disabled(tester.isRendering)
                }

                Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Voice level").font(Theme.label).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.0f dBFS", tester.voiceLevelDBFS))
                            .font(Theme.numeric(14)).foregroundStyle(Theme.textPrimary)
                    }
                    Slider(value: $tester.voiceLevelDBFS, in: -40...0, step: 1)
                        .tint(Theme.accent)
                    Text("Tone, noise, polarity and LTC always play at their stated levels.")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !tester.hasRichVoice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").font(.system(size: 13, weight: .light))
                        Text("For the richest voice, download an Enhanced English (UK) voice in Settings › Accessibility › Spoken Content › Voices.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.corner))
                }
            }
        }
    }
}

/// Titled flat panel.
private struct Panel<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.cornerLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

extension Panel where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}
