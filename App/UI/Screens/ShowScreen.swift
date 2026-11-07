import SwiftUI
import SwiftData
import TCKit

/// iPad main-screen layouts (toolbar view switcher, persisted in @AppStorage("layoutMode")).
enum LayoutMode: String, CaseIterable, Identifiable {
    case console, clock, mixer, show
    var id: String { rawValue }
    var label: String {
        switch self { case .console: "Console"; case .clock: "Clock"; case .mixer: "Mixer"; case .show: "Show" }
    }
    var symbol: String {
        switch self {
        case .console: "rectangle.split.3x1"
        case .clock: "clock"
        case .mixer: "slider.vertical.3"
        case .show: "play.rectangle"
        }
    }
    /// Layouts that carry their own cue list (or none) hide the sidebar.
    var showsSidebar: Bool { self == .console }
}

/// The main "Show" area. Every layout is assembled from the same panels below.
struct ShowScreen: View {
    enum Layout { case console, clock, mixer, phonePortrait, phoneLandscape }
    var layout: Layout
    @Bindable private var shell = ShellModel.shared
    @State private var scopeMode: OscilloscopeView.Mode = .overlay

    var body: some View {
        Group {
            switch layout {
            case .console: console
            case .clock: clockForward
            case .mixer: mixer
            case .phonePortrait: phonePortrait
            case .phoneLandscape: phoneLandscape
            }
        }
        .background(Theme.background)
    }

    // MARK: A · Console

    private var console: some View {
        GeometryReader { geo in
            let tall = geo.size.height > geo.size.width
            let narrow = geo.size.width < 860
            VStack(spacing: 10) {
                ClockPanel().frame(height: max(150, geo.size.height * (tall ? 0.22 : 0.27)))
                TrackMarksStrip(compact: geo.size.width < 640)
                WaveformPanel(height: 64)
                if tall {
                    // Portrait: routing + horizontal meters in one row, scope full width below.
                    HStack(alignment: .top, spacing: 10) {
                        RoutingPanel()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .panel()
                        MeterPanel(axis: .horizontal).frame(width: geo.size.width * 0.34)
                    }
                    .frame(height: 230)
                    ScopePanel(mode: $scopeMode).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 10) {
                        ScopePanel(mode: $scopeMode).frame(minWidth: 0, maxWidth: .infinity)
                        MeterPanel(axis: .vertical).frame(width: narrow ? 88 : 104)
                        RoutingPanel()
                            .frame(maxHeight: .infinity, alignment: .top)
                            .panel()
                            .frame(width: min(340, geo.size.width * 0.44))
                    }
                    .frame(maxHeight: .infinity)
                }
                TransportBar(layout: narrow ? .compact : .regular).panel(padding: 10)
            }
            .padding(12)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    // MARK: B · Clock forward

    private var clockForward: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                ClockPanel(fill: Theme.background, bordered: false)
                    .frame(height: max(170, geo.size.height * 0.30))
                TrackMarksStrip(compact: geo.size.width < 640)
                CueStrip().frame(height: 74)
                WaveformPanel(height: 56, showsHeader: false)
                HStack(spacing: 10) {
                    ScopePanel(mode: $scopeMode).frame(maxWidth: .infinity)
                    RoutingPanel()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .panel()
                        .frame(width: min(400, geo.size.width * 0.38))
                    MeterPanel(axis: .vertical).frame(width: 104)
                }
                .frame(maxHeight: .infinity)
                TransportBar(layout: geo.size.width < 860 ? .compact : .regular).panel(padding: 10)
            }
            .padding(12)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    // MARK: C · Mixer

    private var mixer: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    MixerBank().frame(width: min(292, geo.size.width * 0.3))
                    VStack(spacing: 10) {
                        ClockPanel().frame(height: max(140, geo.size.height * 0.22))
                        TrackMarksStrip(compact: true)
                        WaveformPanel(height: 52)
                        ScopePanel(mode: $scopeMode).frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 0) {
                        SectionHeader("Cues").padding(.horizontal, 14).frame(height: 32)
                            .background(Theme.surface)
                        CueListView()
                    }
                    .frame(width: min(340, geo.size.width * 0.28))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
                }
                .frame(maxHeight: .infinity)
                TransportBar(layout: geo.size.width < 860 ? .compact : .regular).panel(padding: 10)
            }
            .padding(12)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    // MARK: iPhone

    @AppStorage("phoneScopeOpen") private var phoneScopeOpen = false

    private var phonePortrait: some View {
        ScrollView {
            VStack(spacing: 8) {
                ClockPanel().frame(height: 140)
                TrackMarksStrip(compact: true)
                WaveformPanel(height: 44)
                RoutingPanel(compact: true).panel(padding: 10)
                MeterPanel(axis: .horizontal).frame(height: 76)
                phoneScope
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TransportBar(layout: .compact)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
                .background(Theme.surface)
                .hairline(.top)
        }
    }

    private var phoneScope: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { phoneScopeOpen.toggle() }
            } label: {
                HStack {
                    Text("Scope").sectionHeaderStyle()
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(phoneScopeOpen ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if phoneScopeOpen {
                OscilloscopeView(mode: $scopeMode)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
        }
        .panel(padding: 10)
    }

    private var phoneLandscape: some View {
        HStack(spacing: 10) {
            VStack(spacing: 8) {
                ClockPanel(showsExpand: false)
                LampRow()
            }
            TransportColumn().frame(width: 230)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Panels (shared by every layout)

/// The big clock in a sunken panel; tap for the full-screen clock.
struct ClockPanel: View {
    var fill: Color = Theme.surfaceSunken
    var bordered = true
    var showsExpand = true
    @Bindable private var shell = ShellModel.shared
    var body: some View {
        Button { shell.showFullClock = true } label: {
            TimecodeClockView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if showsExpand {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .padding(8)
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .strokeBorder(bordered ? Theme.hairline : .clear, lineWidth: Theme.hairlineWidth))
        .accessibilityHint("Opens the full-screen clock")
    }
}

/// Waveform overview of the playing (or standby) cue.
struct WaveformPanel: View {
    var height: CGFloat
    var showsHeader = true
    var framed = true
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    var body: some View {
        let cue = shell.activeCue ?? shell.standbyCue
        let track = cue?.kind == .track ? cue?.track : nil
        let content = VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let cue {
                        Text(shell.activeCue != nil ? "Playing" : "Standby")
                            .font(Theme.sectionHeader)
                            .foregroundStyle(shell.activeCue != nil ? Theme.go : Theme.standby)
                        Text(cue.number).font(Theme.numeric(12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(cue.title).font(Theme.sectionHeader).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    } else {
                        Text("No cue").sectionHeaderStyle()
                    }
                    Spacer()
                    if showLock {
                        Label("Scrub locked", systemImage: "lock")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    if let cue {
                        Text(Fmt.duration(cue.displayDuration))
                            .font(Theme.numeric(12, weight: .regular)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            WaveformOverviewView(overview: track?.overview, channelCount: track?.channelCount ?? 2,
                                 duration: cue?.displayDuration ?? 0, scrubEnabled: !showLock && shell.activeCue != nil)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        if framed { content.panel(padding: showsHeader ? 10 : 6) } else { content }
    }
}

struct ScopeModePicker: View {
    @Binding var mode: OscilloscopeView.Mode
    var body: some View {
        FlatSegmented(options: [(.overlay, "Overlay"), (.stacked, "Stacked"), (.xy, "X–Y")], selection: $mode, height: 22)
    }
}

struct ScopePanel: View {
    @Binding var mode: OscilloscopeView.Mode
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Scope") { EmptyView() }
            OscilloscopeView(mode: $mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .panel()
    }
}

struct MeterPanel: View {
    var axis: StereoMeterView.Axis
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Output")
            StereoMeterView(axis: axis)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .panel(padding: 10)
    }
}

/// Mixer bank: tall L and R strips with a vertical Swap between them.
struct MixerBank: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                ChannelStrip(side: .left, style: .tall)
                VStack { Spacer(); SwapKey(tall: true); Spacer() }.frame(width: 64)
                ChannelStrip(side: .right, style: .tall)
            }
            GainRow()
            RoutingWarnings()
        }
        .panel()
    }
}

/// Horizontal cue strip: previous (dim) · playing (green) · standby (amber) · next.
struct CueStrip: View {
    @Bindable private var shell = ShellModel.shared
    var body: some View {
        let cues = shell.playlist?.orderedCues ?? []
        let active = shell.isRunning ? shell.activeCue : nil
        let standby = shell.standbyCue
        let anchor = active ?? standby
        let ai = anchor.flatMap { a in cues.firstIndex { $0.id == a.id } }
        let previous = ai.flatMap { $0 > 0 ? cues[$0 - 1] : nil }
        let next = shell.cue(after: standby)
        HStack(spacing: 10) {
            card(previous, role: .previous)
            card(active, role: .playing)
            card(standby, role: .standby)
            card(next, role: .next)
        }
    }

    enum Role { case previous, playing, standby, next }

    private func card(_ cue: Cue?, role: Role) -> some View {
        let color: Color? = role == .playing ? Theme.go : (role == .standby ? Theme.standby : nil)
        let word: String = switch role {
        case .previous: "Previous"; case .playing: "Playing"; case .standby: "Standby"; case .next: "Next"
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let cue { Text(cue.number).font(Theme.numeric(12, weight: .semibold)) }
                Text(word).font(Theme.caption)
            }
            .foregroundStyle(color ?? Theme.textTertiary)
            Text(cue?.title ?? "—")
                .font(.system(.subheadline, weight: color != nil ? .semibold : .regular))
                .foregroundStyle(role == .previous || cue == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
            if let cue {
                Text(detail(cue, role: role))
                    .font(Theme.numeric(11, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .fill(color != nil && cue != nil ? Theme.surfaceRaised : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(cue != nil ? (color ?? Theme.hairline) : Theme.hairline,
                          lineWidth: color != nil && cue != nil ? 1.5 : Theme.hairlineWidth))
        .opacity(role == .previous ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if let cue, role != .playing { shell.show.standby(cue); Haptics.tick() } }
    }

    private func detail(_ cue: Cue, role: Role) -> String {
        if role == .playing { return Fmt.elapsed(shell.elapsed) + "  " + Fmt.remaining(shell.remaining) }
        var parts: [String] = []
        if let t = cue.track, let s = t.ltcStart, t.ltcChannel != nil {
            parts.append("TC " + Fmt.timecode(s, rate: t.ltcRate.flatMap(FrameRate.init(rawValue:))))
        } else if cue.kind == .generator {
            parts.append("Gen " + cue.genStart)
        }
        parts.append(Fmt.duration(cue.displayDuration))
        return parts.joined(separator: " · ")
    }
}

/// Lock state, rate, source and level, in operator words. Shared by Show mode and the full-screen clock.
struct ShellClockStatusLine: View {
    var showsLockState = false
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    var body: some View {
        let clock = shell.engine.clock
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                IndicatorLamp(color: Self.lockColor(clock), isOn: clock.lock != .noSignal || clock.source == .generator, size: 8)
                Text(Self.lockWord(clock))
            }
            if let r = clock.rate { Text(r.operatorLabel).font(Theme.numeric(13, weight: .regular)) }
            if clock.source != .trackTime { Text(Self.sourceWord(clock.source)) }
            if let l = clock.ltcLevelDBFS {
                Text(String(format: "%.1f dBFS", l).replacingOccurrences(of: "-", with: "−"))
                    .font(Theme.numeric(13, weight: .regular))
            }
            if showsLockState && showLock {
                HStack(spacing: 6) {
                    IndicatorLamp(color: Theme.stop, isOn: true, size: 7)
                    Text("Show Lock")
                }
            }
        }
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(Theme.textSecondary)
    }

    static func lockColor(_ c: ClockStatus) -> Color {
        if c.source == .generator { return Theme.go }
        switch c.lock {
        case .locked: return Theme.lockOK
        case .freewheel, .acquiring: return Theme.lockWarn
        case .noSignal: return Theme.lockOff
        }
    }
    static func lockWord(_ c: ClockStatus) -> String {
        if c.source == .generator { return "Generating" }
        if c.source == .trackTime { return "Track time" }
        switch c.lock {
        case .locked: return "Locked"
        case .freewheel: return "Freewheel"
        case .acquiring: return "Acquiring"
        case .noSignal: return "No signal"
        }
    }
    static func sourceWord(_ s: ClockSource) -> String {
        switch s {
        case .trackTime: "Track"
        case .decoded(let ch): ch == .left ? "LTC · Left" : "LTC · Right"
        case .generator: "Generator"
        case .externalInput: "Input"
        }
    }
}

/// iPhone landscape lamp row: L/R play state, swap, current cue.
struct LampRow: View {
    @Bindable private var shell = ShellModel.shared
    var body: some View {
        let r = shell.routing
        HStack(spacing: 16) {
            lamp("L", on: r.leftEnabled)
            lamp("R", on: r.rightEnabled)
            HStack(spacing: 5) {
                IndicatorLamp(color: Theme.standby, isOn: r.swapped, size: 7)
                Text(r.swapped ? "Swapped" : "Normal").foregroundStyle(r.swapped ? Theme.standby : Theme.textSecondary)
            }
            Spacer()
            if let c = shell.activeCue ?? shell.standbyCue {
                HStack(spacing: 6) {
                    Text(c.number).font(Theme.numeric(12, weight: .semibold))
                    Text(c.title).lineLimit(1)
                }
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(Theme.caption)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .panel(padding: 0)
    }

    private func lamp(_ name: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            IndicatorLamp(color: on ? Theme.go : Theme.stop, isOn: true, size: 7)
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(on ? "Play" : "Muted").foregroundStyle(on ? Theme.textSecondary : Theme.stop)
        }
    }
}

/// iPhone landscape transport: times, GO, stop / pause, previous / next.
struct TransportColumn: View {
    @Bindable private var shell = ShellModel.shared
    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.elapsed(shell.activeCue == nil ? 0 : shell.elapsed))
                    .font(Theme.numeric(15, weight: .semibold))
                    .foregroundStyle(shell.isRunning ? Theme.textPrimary : Theme.textTertiary)
                Spacer()
                Text(Fmt.remaining(shell.activeCue == nil ? nil : shell.remaining))
                    .font(Theme.numeric(15, weight: .regular))
                    .foregroundStyle(shell.isRunning ? Theme.textSecondary : Theme.textTertiary)
            }
            .padding(.horizontal, 2)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Text("Next").foregroundStyle(Theme.textTertiary)
                if let n = shell.isRunning ? shell.standbyCue : shell.cue(after: shell.standbyCue) {
                    Text(n.number).font(Theme.numeric(12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(n.title).foregroundStyle(Theme.textSecondary).lineLimit(1)
                } else {
                    Text("End of list").foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .font(Theme.caption)
            .padding(.horizontal, 2)
            GoKey(titleSize: 26).frame(maxHeight: 132)
            HStack(spacing: 8) {
                StopKey()
                PauseKey(showsLabel: false)
            }
            .frame(height: 50)
            HStack(spacing: 8) {
                Button { shell.show.previous() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(FlatButtonStyle(tint: Theme.textSecondary))
                Button { shell.show.next() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(FlatButtonStyle(tint: Theme.textSecondary))
            }
            .frame(height: 40)
        }
    }
}

// MARK: - D · Show mode

/// Pure black, the clock and one big GO. Pairs with Show Lock.
struct ShowModeView: View {
    var onExit: (() -> Void)?
    @Bindable private var shell = ShellModel.shared
    @Environment(\.verticalSizeClass) private var vSize
    @AppStorage(SettingsKey.showLock) private var showLock = false

    var body: some View {
        GeometryReader { geo in
            let phone = UIDevice.current.userInterfaceIdiom == .phone
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                if !(phone && vSize == .compact) {
                    ShellClockStatusLine(showsLockState: true).padding(.bottom, 8)
                }
                TimecodeClockView(compact: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: min(geo.size.height * 0.34, geo.size.width * 0.2))
                    .padding(.horizontal, 24)
                times.padding(.top, 10)
                WaveformPanel(height: 48, showsHeader: false)
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .opacity(phone && vSize == .compact ? 0 : 1)
                Spacer(minLength: 8)
                bottomBar(compact: phone)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if let onExit {
                Button(action: onExit) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityLabel("Leave Show mode")
            }
        }
        .onAppear { if !showLock { shell.offerShowLock = true } }
        .confirmationDialog("Turn on Show Lock?", isPresented: $shell.offerShowLock, titleVisibility: .visible) {
            Button("Turn on Show Lock") { showLock = true }
            Button("Keep unlocked", role: .cancel) {}
        } message: {
            Text("Show Lock prevents edits and scrubbing, and Stop needs a one-second hold.")
        }
    }

    private var times: some View {
        HStack(spacing: 28) {
            HStack(spacing: 8) {
                Text("Elapsed").foregroundStyle(Theme.textSecondary)
                Text(Fmt.clock(shell.activeCue == nil ? 0 : shell.elapsed)).foregroundStyle(Theme.textPrimary)
                    .font(Theme.numeric(17, weight: .semibold))
            }
            HStack(spacing: 8) {
                Text("Remaining").foregroundStyle(Theme.textSecondary)
                Text(Fmt.remaining(shell.activeCue == nil ? nil : shell.remaining)).foregroundStyle(Theme.textPrimary)
                    .font(Theme.numeric(17, weight: .semibold))
            }
        }
        .font(.system(size: 15))
    }

    private func bottomBar(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 16) {
            VStack(alignment: .leading, spacing: 3) {
                if let a = shell.isRunning ? shell.activeCue : nil {
                    HStack(spacing: 6) {
                        Text("Playing").font(Theme.caption)
                        Text(a.number).font(Theme.numeric(12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.go)
                    Text(a.title).font(.system(compact ? .subheadline : .title3, weight: .medium))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                } else {
                    Text("Stopped").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StopKey().frame(width: compact ? 64 : 84, height: compact ? 64 : 84)
            GoKey(titleSize: compact ? 26 : 32).frame(width: compact ? 180 : 360, height: compact ? 64 : 88)
            VStack(alignment: .trailing, spacing: 3) {
                Text("Next").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                if let n = shell.isRunning ? shell.standbyCue : shell.cue(after: shell.standbyCue) {
                    HStack(spacing: 6) {
                        Text(n.number).font(Theme.numeric(13, weight: .semibold))
                        Text(n.title).lineLimit(1)
                    }
                    .font(.system(compact ? .subheadline : .body))
                    .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("End of list").font(.system(.body)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, compact ? 14 : 28)
        .padding(.vertical, compact ? 12 : 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth) }
    }
}

// MARK: - Transport keys (shared)

/// GO key: solid green with the standby cue beneath; red ring during the double-GO window.
struct GoKey: View {
    var titleSize: CGFloat = 30
    @Bindable private var shell = ShellModel.shared
    var body: some View {
        let standby = shell.standbyCue
        Button { shell.go() } label: {
            VStack(spacing: 2) {
                Text("GO").font(.system(size: titleSize, weight: .bold))
                if let s = standby {
                    HStack(spacing: 6) {
                        Text(s.number).font(Theme.numeric(12, weight: .semibold))
                        Text(s.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                    .opacity(0.92)
                } else {
                    Text("No cue in standby").font(.system(size: 12, weight: .regular))
                }
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(GoButtonStyle(armed: standby != nil))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerLarge + 3, style: .continuous)
                .strokeBorder(Theme.stop, lineWidth: 2)
                .padding(-4)
                .opacity(shell.goGuardActive ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: shell.goGuardActive)
                .allowsHitTesting(false)
        }
        .disabled(standby == nil)
        .accessibilityLabel(standby.map { "GO, cue \($0.number), \($0.title)" } ?? "GO, no cue in standby")
    }
}

/// Stop key honouring Show Lock (1 s hold with progress ring when locked, then a fade).
struct StopKey: View {
    var showsLabel = true
    @Bindable private var shell = ShellModel.shared
    @AppStorage(SettingsKey.showLock) private var showLock = false
    var body: some View {
        let label = VStack(spacing: 3) {
            Image(systemName: "stop.fill").font(.system(size: 18, weight: .regular))
            if showLock && showsLabel { Text("Hold").font(.system(size: 10, weight: .medium)) }
        }
        if showLock {
            HoldToConfirm(duration: 1.0, ringColor: Theme.stop, corner: Theme.corner, action: { shell.stop(locked: true) }) {
                label
                    .foregroundStyle(Theme.stop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Stop. Hold for one second.")
            .accessibilityAction { shell.stop(locked: true) }
        } else {
            Button { shell.stop(locked: false) } label: { label }
                .buttonStyle(FlatButtonStyle(tint: Theme.stop))
                .accessibilityLabel("Stop")
        }
    }
}

struct PauseKey: View {
    var showsLabel = true
    @Bindable private var shell = ShellModel.shared
    var body: some View {
        let paused = shell.engine.transport == .paused
        Button { shell.pauseResume() } label: {
            VStack(spacing: 3) {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 18, weight: .regular))
                if showsLabel { Text(paused ? "Resume" : "Pause").font(.system(size: 10, weight: .medium)) }
            }
        }
        .buttonStyle(LatchButtonStyle(isOn: paused, onColor: Theme.standby))
        .disabled(shell.activeCue == nil)
        .accessibilityLabel(paused ? "Resume" : "Pause")
    }
}
