import SwiftUI

/// A trace frozen by Store A / Store B, drawn under the live one for comparison.
struct StoredTrace {
    enum Kind { case spectrum, transfer }
    var kind: Kind
    var centers: [Double]
    var level: [Float]
    var phase: [Float] = []
    var coherence: [Float] = []
    var fraction: Int
    var display: SpectrumDisplay
    var lower: [Double]
    var upper: [Double]
}

/// The spectrum analyser panel: controls and one of three views (spectrum, spectrogram,
/// transfer function). Used on the Scope page (input, output, both, transfer) and in the
/// Input analyzer (input only).
struct SpectrumPanel: View {
    enum Kind: String, CaseIterable, Identifiable {
        case spectrum, spectrogram, transfer
        var id: String { rawValue }
        var label: String { switch self { case .spectrum: "Spectrum"; case .spectrogram: "Spectrogram"; case .transfer: "Transfer" } }
    }

    @Bindable var engine: SpectrumEngine
    /// Scope page: offer Input / Output / Both and the transfer function.
    var offersOutput: Bool
    var wide: Bool
    /// Show a hold key in the panel (the Scope page has its own page-wide Hold).
    var ownHold = false
    var plotHeight: CGFloat = 320
    @Binding var kind: Kind

    @State private var storeA: StoredTrace?
    @State private var storeB: StoredTrace?
    @State private var showA = true
    @State private var showB = true
    @State private var showHold = true
    @State private var showMax = false
    @State private var blankLowCoherence = true
    @State private var cursor: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow
            settingsRow
            SpectrumPlot(engine: engine, kind: kind, storeA: showA ? storeA : nil, storeB: showB ? storeB : nil,
                         showHold: showHold, showMax: showMax, blankLowCoherence: blankLowCoherence,
                         held: engine.held, cursor: $cursor)
                .frame(height: plotHeight)
            bottomRow
        }
        .onChange(of: kind, initial: true) { _, k in
            engine.settings.transfer = k == .transfer
            engine.settings.spectrogramImage = k == .spectrogram
        }
    }

    // MARK: Rows

    @ViewBuilder private var topRow: some View {
        if wide {
            HStack(spacing: 10) {
                viewPicker.fixedSize()
                if offersOutput, kind != .transfer { sourcePicker.fixedSize() }
                Spacer(minLength: 4)
                holdAndReset
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                viewPicker
                HStack(spacing: 10) {
                    if offersOutput, kind != .transfer { sourcePicker }
                    Spacer(minLength: 4)
                    holdAndReset
                }
            }
        }
    }

    private var viewPicker: some View {
        Picker("View", selection: $kind) {
            Text("Spectrum").tag(Kind.spectrum)
            Text("Spectrogram").tag(Kind.spectrogram)
            if offersOutput { Text("Transfer").tag(Kind.transfer) }
        }
        .pickerStyle(.segmented)
    }

    private var sourcePicker: some View {
        Picker("Show", selection: $engine.settings.sources) {
            ForEach(SpectrumSources.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var holdAndReset: some View {
        HStack(spacing: 6) {
            if ownHold {
                Button { engine.held.toggle() } label: {
                    HStack(spacing: 5) {
                        IndicatorLamp(color: Theme.stop, isOn: engine.held, size: 6)
                        Text(engine.held ? "Held" : "Hold")
                    }
                }
                .buttonStyle(VisualsKeyStyle(isOn: engine.held))
            }
            if ownHold {
                Button("Reset") { engine.reset() }
                    .buttonStyle(VisualsKeyStyle())
                    .accessibilityHint("Restarts averaging and clears the peak hold and maximum")
            }
        }
    }

    private var settingsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if kind == .spectrum {
                    Picker("Display", selection: $engine.settings.display) {
                        Text("Line").tag(SpectrumDisplay.line)
                        Text("Bars").tag(SpectrumDisplay.bars)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                menu(fractionLabel(engine.settings.fraction), "Resolution") {
                    Picker("Resolution", selection: $engine.settings.fraction) {
                        ForEach(OctaveBands.fractions, id: \.self) { Text(fractionLabel($0)).tag($0) }
                    }
                }
                menu("Average: \(engine.settings.averaging.label)", "Averaging") {
                    Picker("Averaging", selection: $engine.settings.averaging) {
                        ForEach(SpectrumAveraging.allCases) { Text($0.label).tag($0) }
                    }
                }
                if kind != .transfer {
                    menu(tiltLabel(engine.settings.tilt), "Slope") {
                        Picker("Slope", selection: $engine.settings.tilt) {
                            Text("Flat").tag(0.0)
                            Text("3 dB per octave (pink)").tag(3.0)
                            Text("4.5 dB per octave").tag(4.5)
                        }
                    }
                }
                menu(engine.settings.channels.label, "Channels") {
                    Picker("Channels", selection: $engine.settings.channels) {
                        ForEach(SpectrumChannels.allCases) { Text($0.label).tag($0) }
                    }
                }
                menu("FFT \(engine.settings.fftSize / 1024)k", "FFT size") {
                    Picker("FFT size", selection: $engine.settings.fftSize) {
                        ForEach(SpectrumSettings.fftSizes, id: \.self) { n in
                            Text("\(n / 1024)k, \(resolutionText(n))").tag(n)
                        }
                    }
                }
                menu(engine.settings.window.label, "Window") {
                    Picker("Window", selection: $engine.settings.window) {
                        ForEach(SpectrumWindowKind.allCases) { Text($0.label).tag($0) }
                    }
                }
                if kind != .transfer {
                    menu("Range \(Int(engine.settings.rangeDB)) dB", "Level range") {
                        Picker("Level range", selection: $engine.settings.rangeDB) {
                            Text("60 dB").tag(Float(60)); Text("80 dB").tag(Float(80))
                            Text("100 dB").tag(Float(100)); Text("120 dB").tag(Float(120))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var bottomRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { bottomItems }
            VStack(alignment: .leading, spacing: 8) { bottomItems }
        }
    }

    @ViewBuilder private var bottomItems: some View {
        Group {
            if kind == .transfer {
                delayControls
                Spacer(minLength: 4)
                toggleKey("Hide low coherence", $blankLowCoherence)
            } else if kind == .spectrum {
                toggleKey("Peak hold", $showHold)
                toggleKey("Maximum", $showMax)
                Spacer(minLength: 4)
            } else {
                Text("Newest at the top. Colour runs from \(Int(engine.settings.topDB - engine.settings.rangeDB)) to \(Int(engine.settings.topDB)) dBFS.")
                    .font(Theme.caption).foregroundStyle(VisualsColor.secondary)
                Spacer(minLength: 4)
            }
            if kind != .spectrogram {
                storeKeys
            }
        }
    }

    private var storeKeys: some View {
        HStack(spacing: 6) {
            storeKey("A", $storeA, $showA, SpectrumPlot.storeAColor)
            storeKey("B", $storeB, $showB, SpectrumPlot.storeBColor)
        }
    }

    private func storeKey(_ name: String, _ slot: Binding<StoredTrace?>, _ show: Binding<Bool>, _ color: Color) -> some View {
        Menu {
            Button("Store live trace as \(name)") { slot.wrappedValue = capture() }
            if slot.wrappedValue != nil {
                Button(show.wrappedValue ? "Hide \(name)" : "Show \(name)") { show.wrappedValue.toggle() }
                Button("Clear \(name)", role: .destructive) { slot.wrappedValue = nil }
            }
        } label: {
            HStack(spacing: 5) {
                Rectangle().fill(slot.wrappedValue != nil && show.wrappedValue ? color : VisualsColor.tertiary)
                    .frame(width: 12, height: 2)
                Text(slot.wrappedValue == nil ? "Store \(name)" : "Trace \(name)")
            }
        } primaryAction: {
            if slot.wrappedValue == nil { slot.wrappedValue = capture() } else { show.wrappedValue.toggle() }
        }
        .menuStyle(.button)
        .buttonStyle(VisualsKeyStyle(isOn: slot.wrappedValue != nil && show.wrappedValue))
        .accessibilityHint(slot.wrappedValue == nil ? "Keeps the live trace for comparison" : "Shows or hides the stored trace. Hold for more")
    }

    private var delayControls: some View {
        let st = engine.status
        let text: String
        switch engine.settings.delay {
        case .followRoundTrip:
            text = st.roundTripMS.map { "Delay \(ms($0)), following the round trip" } ?? "No round trip measured yet"
        case .fixed(let s):
            text = "Delay \(ms(s * 1000)), found"
        }
        return HStack(spacing: 8) {
            Text(text).font(Theme.caption).foregroundStyle(VisualsColor.secondary).lineLimit(1)
            Button(st.finding ? "Finding…" : "Find delay") { engine.findDelay() }
                .buttonStyle(VisualsKeyStyle())
                .disabled(st.finding || !(st.hasInput && st.hasOutput))
                .accessibilityHint("Measures the delay from the output to the input and uses it")
            if case .fixed = engine.settings.delay {
                Button("Follow round trip") { engine.followRoundTrip() }.buttonStyle(VisualsKeyStyle())
            }
            if st.lastFind == .notFound {
                Text("No clear arrival").font(Theme.caption).foregroundStyle(Theme.standby)
            }
        }
    }

    // MARK: Helpers

    private func capture() -> StoredTrace? {
        let f = engine.frame()
        if kind == .transfer {
            guard let t = f.transfer else { return nil }
            return StoredTrace(kind: .transfer, centers: f.centers, level: t.magnitudeDB, phase: t.phaseDeg,
                               coherence: t.coherence, fraction: f.fraction, display: .line, lower: f.lower, upper: f.upper)
        }
        guard let t = f.traces.first else { return nil }
        return StoredTrace(kind: .spectrum, centers: f.centers, level: t.level, fraction: f.fraction,
                           display: f.display, lower: f.lower, upper: f.upper)
    }

    private func toggleKey(_ title: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                IndicatorLamp(color: Theme.accent, isOn: on.wrappedValue, size: 6)
                Text(title)
            }
        }
        .buttonStyle(VisualsKeyStyle(isOn: on.wrappedValue))
        .fixedSize()
    }

    private func menu<C: View>(_ title: String, _ a11y: String, @ViewBuilder _ content: () -> C) -> some View {
        Menu { content() } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(VisualsKeyStyle())
        .fixedSize()
        .accessibilityLabel("\(a11y): \(title)")
    }

    private func fractionLabel(_ b: Int) -> String { b == 1 ? "1 octave" : "1/\(b) octave" }
    private func tiltLabel(_ t: Double) -> String {
        t == 0 ? "Slope flat" : "Slope \(t == t.rounded() ? String(format: "%.0f", t) : String(format: "%.1f", t)) dB/oct"
    }
    private func resolutionText(_ n: Int) -> String {
        let fs = engine.frame().sampleRate
        return String(format: "%.1f Hz per bin", fs / Double(n))
    }
    private func ms(_ v: Double) -> String { v < 10 ? String(format: "%.2f ms", v) : String(format: "%.1f ms", v) }
}
